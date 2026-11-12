//! Many patterns compiled together and searched in one pass: which of them match, whether any
//! does, and the leftmost-first match over them all with the pattern it belongs to. Immutable
//! once compiled, searched by any number of threads, each with a `Cache` of its own.
//!
//! Each pattern is parsed and translated alone, so a refusal names the pattern (its index in
//! `Diagnostic.pattern`) and its span, and the patterns are compiled into one automaton with a
//! match state each (nfa/compile.zig `compileSet`). There are no groups but the whole match, as
//! in regex-automata's `RegexSet`: a caller compiles the pattern that matched alone for its
//! captures. `Limits` bound the set as a whole: `nfa` the automaton, `cache` what a `Cache`
//! holds; `pattern` each pattern.
//!
//! `matches` takes each pattern's matches on their own (the all kind: no thread is dropped at a
//! match, regex's `RegexSet::matches`); `isMatch` and `first` take the patterns as one
//! alternation in index order, leftmost-first. Two lazy DFAs answer them: one of the all kind,
//! for `matches` and every whole search, and one leftmost-first, for where `first`'s match ends,
//! the PikeVM then searching the span cut there for its start and pattern. Where a lazy DFA quits
//! or gives up, or the set has none (`Limits.lazy_dfa` too small for its fewest states), the
//! PikeVM answers the whole span. Every path is linear in the haystack and the set's automaton,
//! and `Cache.last` says which answered.
const Set = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Regex = @import("Regex.zig");
const Ast = @import("syntax/Ast.zig");
const parse_mod = @import("syntax/parse.zig");
const translate_mod = @import("hir/translate.zig");
const Hir = @import("hir/Hir.zig");
const Nfa = @import("nfa/Nfa.zig");
const compile_mod = @import("nfa/compile.zig");
const pikevm = @import("pikevm.zig");
const lazy = @import("lazy.zig");

pub const Span = Regex.Span;
pub const Input = Regex.Input;
pub const Options = Regex.Options;
pub const CompileError = Regex.CompileError;
pub const SearchError = Regex.SearchError;

/// A pattern of the set, by its index in the slice `compile` was given.
pub const Pattern = aegis.handle.Index(Set, u32);

/// A match, the pattern it belongs to, and which set found it.
pub const Match = struct {
    span: Span,
    /// Read through `Set.pattern`, which checks the match is this set's.
    index: Pattern,
    set: u64,
};

gpa: Allocator,
nfa: Nfa,
/// The lazy DFA of the all kind; null where `Limits.lazy_dfa` holds too few states.
all: ?lazy.Dfa,
/// The leftmost-first lazy DFA; null alike.
leftmost: ?lazy.Dfa,
/// This set's identity: no two sets compiled in a process share it.
id: u64,

/// A set's identity, as the atomic cell holds it.
const Serial = enum(u64) { _ };

/// Each compile takes the next.
var next_id: aegis.Atomic(Serial) = .init(@fromBackingInt(0));

fn takeId() u64 {
    var seen = next_id.load(.monotonic);
    while (next_id.cmpxchgWeak(seen, @fromBackingInt(@backingInt(seen) +% 1), .monotonic, .monotonic)) |now| seen = now;
    return @backingInt(seen);
}

/// The set of the patterns in `sources`, in their order. A pattern refused stops the compile, with
/// `options.diagnostic` naming it (`pattern`), where in it, and why; a set too large as a whole
/// names no pattern.
pub fn compile(gpa: Allocator, sources: []const aegis.input.Untrusted([]const u8), options: Options) CompileError!Set {
    aegis.assert.invariant(sources.len > 0, "a set holds a pattern");
    aegis.assert.invariant(sources.len <= std.math.maxInt(u32), "a set's patterns are counted in 32 bits");
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const hirs = try a.alloc(Hir, sources.len);
    for (sources, hirs, 0..) |source, *hir, i| {
        errdefer if (options.diagnostic) |d| {
            d.pattern = @intCast(i);
        };
        const ast = try a.create(Ast);
        ast.* = try parse_mod.parse(a, source, options.syntax, options.limits, options.diagnostic);
        hir.* = try translate_mod.translate(a, ast, options.syntax, options.limits, options.diagnostic);
    }
    var nfa = try compile_mod.compileSet(gpa, hirs, .{
        .limits = options.limits,
        .utf8 = options.syntax.utf8,
        .ecma = options.syntax.dialect == .ecmascript,
    }, options.diagnostic);
    errdefer nfa.deinit(gpa);
    const all = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .forward, .all);
    const leftmost = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .forward, .leftmost_first);
    if ((cacheBytesOf(&nfa, all, leftmost) orelse std.math.maxInt(usize)) > options.limits.cache.raw()) {
        if (options.diagnostic) |d| d.* = .{ .reason = .cache_too_large };
        return error.TooLarge;
    }
    return .{ .gpa = gpa, .nfa = nfa, .all = all, .leftmost = leftmost, .id = takeId() };
}

/// What a `Cache` of the set allocates, or null past `usize`: what `Limits.cache` bounds.
fn cacheBytesOf(nfa: *const Nfa, all: ?lazy.Dfa, leftmost: ?lazy.Dfa) ?usize {
    var total = pikevm.sizes(nfa).bytes() orelse return null;
    if (all) |d| total = std.math.add(usize, total, d.bytes()) catch return null;
    if (leftmost) |d| total = std.math.add(usize, total, d.bytes()) catch return null;
    const bits = (nfa.patterns + 63) / 64 * 8;
    return std.math.add(usize, total, bits) catch null;
}

/// The engines the set has: the PikeVM always, and each lazy DFA unless its store cannot hold the
/// fewest states a search needs.
pub const Engines = struct { pikevm: bool = true, all: bool, leftmost: bool };

pub fn engines(set: *const Set) Engines {
    return .{ .all = set.all != null, .leftmost = set.leftmost != null };
}

pub fn deinit(set: *Set) void {
    set.nfa.deinit(set.gpa);
    set.* = undefined;
}

/// How many patterns the set holds.
pub fn len(set: *const Set) u32 {
    return set.nfa.patterns;
}

/// The pattern `m` matched. `m` is this set's, checked in every build.
pub fn pattern(set: *const Set, m: Match) Pattern {
    aegis.assert.invariant(m.set == set.id, "a match is read against the set that found it");
    return m.index;
}

/// What one task's searches of the set need, allocated once: no search allocates.
pub const Cache = struct {
    pike: pikevm.Cache,
    all: ?lazy.Cache,
    leftmost: ?lazy.Cache,
    /// A bit per pattern, for a search that asks which matched without a caller's set.
    scratch: std.DynamicBitSetUnmanaged,
    /// The set it was made for.
    set: u64,
    /// How the last search was answered, for the tests that count each path.
    last: Path = .pikevm,

    pub const Path = enum {
        /// The PikeVM alone: the set has no lazy DFA for the search.
        pikevm,
        /// A lazy DFA, and for `first` the PikeVM over the span cut at the match's end.
        lazy_dfa,
        /// The lazy DFA quit or gave up, and the PikeVM searched the span.
        lazy_dfa_fell_back,
    };

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.pike.deinit(gpa);
        if (c.all) |*l| l.deinit(gpa);
        if (c.leftmost) |*l| l.deinit(gpa);
        c.scratch.deinit(gpa);
        c.* = undefined;
    }
};

pub fn cache(set: *const Set, gpa: Allocator) Allocator.Error!Cache {
    var pike: pikevm.Cache = try .init(gpa, &set.nfa);
    errdefer pike.deinit(gpa);
    var all: ?lazy.Cache = if (set.all) |*d| try .init(gpa, d) else null;
    errdefer if (all) |*l| l.deinit(gpa);
    var leftmost: ?lazy.Cache = if (set.leftmost) |*d| try .init(gpa, d) else null;
    errdefer if (leftmost) |*l| l.deinit(gpa);
    return .{ .pike = pike, .all = all, .leftmost = leftmost, .scratch = try .initEmpty(gpa, set.len()), .set = set.id };
}

/// Which patterns matched: a bit per pattern, allocated once by the caller (`Set.patterns`) and
/// filled by `matches`.
pub const Patterns = struct {
    bits: std.DynamicBitSetUnmanaged,
    set: u64,

    pub fn deinit(p: *Patterns, gpa: Allocator) void {
        p.bits.deinit(gpa);
        p.* = undefined;
    }

    pub fn contains(p: *const Patterns, index: Pattern) bool {
        return p.bits.isSet(index.raw());
    }

    pub fn count(p: *const Patterns) usize {
        return p.bits.count();
    }

    /// The lowest pattern that matched.
    pub fn first(p: *const Patterns) ?Pattern {
        const at = p.bits.findFirstSet() orelse return null;
        return @fromBackingInt(@as(u32, @intCast(at)));
    }

    /// The highest pattern that matched (gitignore's last match).
    pub fn last(p: *const Patterns) ?Pattern {
        const at = p.bits.findLastSet() orelse return null;
        return @fromBackingInt(@as(u32, @intCast(at)));
    }

    /// The patterns that matched, lowest first.
    pub fn iterator(p: *const Patterns) Iterator {
        return .{ .inner = p.bits.iterator(.{}) };
    }

    pub const Iterator = struct {
        inner: std.DynamicBitSetUnmanaged.Iterator(.{}),

        pub fn next(it: *Iterator) ?Pattern {
            const at = it.inner.next() orelse return null;
            return @fromBackingInt(@as(u32, @intCast(at)));
        }
    };
};

/// A bit per pattern of the set, for `matches` to fill.
pub fn patterns(set: *const Set, gpa: Allocator) Allocator.Error!Patterns {
    return .{ .bits = try .initEmpty(gpa, set.len()), .set = set.id };
}

/// Whether some pattern matches in `input`. `error.HaystackTooLong` never occurs: a set holds
/// no lookaround (refused at compile), so it stores no rows.
pub fn isMatch(set: *const Set, c: *Cache, input: Input) SearchError!bool {
    set.checkCache(c);
    var earliest = input;
    earliest.earliest = true;
    c.scratch.unsetAll();
    return set.searchAll(c, earliest, &c.scratch) > 0;
}

/// Every pattern with a match in `input`, each pattern's matches taken on their own, in `out`
/// (cleared first); whether any did. With `input.whole`, only a match covering the span counts.
/// `error.HaystackTooLong` never occurs: a set stores no rows.
pub fn matches(set: *const Set, c: *Cache, input: Input, out: *Patterns) SearchError!bool {
    set.checkCache(c);
    aegis.assert.invariant(out.set == set.id, "a pattern set is filled by the set it was made for");
    out.bits.unsetAll();
    return set.searchAll(c, input, &out.bits) > 0;
}

/// The all kind on the lazy DFA, or the PikeVM where it has none, quits or gives up: how many
/// patterns `out` holds after (callers clear it first).
fn searchAll(set: *const Set, c: *Cache, input: Input, out: *std.DynamicBitSetUnmanaged) usize {
    if (set.all) |*d| {
        if (lazy.searchAll(&set.nfa, d, &c.all.?, input, out)) |found| {
            c.last = .lazy_dfa;
            return found;
        } else |_| c.last = .lazy_dfa_fell_back;
    } else c.last = .pikevm;
    // The bits set before the fallback are matches, enough for an earliest search; the PikeVM
    // finds every pattern's again otherwise.
    const before = out.count();
    if (input.earliest and before > 0) return before;
    _ = pikevm.searchAll(&set.nfa, &c.pike, input, out);
    return out.count();
}

/// The leftmost-first match over the set, as if its patterns were one alternation in index
/// order, and the pattern it belongs to. `error.HaystackTooLong` never occurs: a set stores no
/// rows.
pub fn first(set: *const Set, c: *Cache, input: Input) SearchError!?Match {
    set.checkCache(c);
    if (input.whole) {
        // Every match covers the span, and the alternation prefers the lowest pattern.
        c.scratch.unsetAll();
        if (set.searchAll(c, input, &c.scratch) == 0) return null;
        const lowest: u32 = @intCast(c.scratch.findFirstSet().?);
        return .{ .span = input.span, .index = @fromBackingInt(lowest), .set = set.id };
    }
    var cut = input;
    if (set.leftmost) |*d| {
        var from: usize = undefined;
        if (lazy.searchFrom(&set.nfa, d, &c.leftmost.?, input, &from, null)) |found| {
            c.last = .lazy_dfa;
            const end = found orelse return null;
            // Cut at the end, the PikeVM's leftmost-first match is the same: no match starts
            // earlier, and the preferred one from its start ends there.
            cut.span = .{ .start = from, .end = end };
        } else |_| c.last = .lazy_dfa_fell_back;
    } else c.last = .pikevm;
    var slots: [2]?usize = undefined;
    _ = pikevm.search(&set.nfa, &c.pike, cut, &slots) orelse {
        aegis.assert.invariant(c.last != .lazy_dfa, "the match the lazy DFA found is found again");
        return null;
    };
    return .{ .span = .{ .start = slots[0].?, .end = slots[1].? }, .index = @fromBackingInt(c.pike.pattern), .set = set.id };
}

fn checkCache(set: *const Set, c: *const Cache) void {
    aegis.assert.invariant(c.set == set.id, "a cache searches the set it was made for");
}
