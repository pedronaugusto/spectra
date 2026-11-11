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
//! alternation in index order, leftmost-first. All are the PikeVM's, linear in the haystack and
//! the set's automaton.
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
    if ((pikevm.sizes(&nfa).bytes() orelse std.math.maxInt(usize)) > options.limits.cache.raw()) {
        if (options.diagnostic) |d| d.* = .{ .reason = .cache_too_large };
        return error.TooLarge;
    }
    return .{ .gpa = gpa, .nfa = nfa, .id = takeId() };
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
    /// The set it was made for.
    set: u64,

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.pike.deinit(gpa);
        c.* = undefined;
    }
};

pub fn cache(set: *const Set, gpa: Allocator) Allocator.Error!Cache {
    return .{ .pike = try .init(gpa, &set.nfa), .set = set.id };
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
    earliest.earliest = !input.whole;
    return pikevm.search(&set.nfa, &c.pike, earliest, &.{}) != null;
}

/// Every pattern with a match in `input`, each pattern's matches taken on their own, in `out`
/// (cleared first); whether any did. With `input.whole`, only a match covering the span counts.
/// `error.HaystackTooLong` never occurs: a set stores no rows.
pub fn matches(set: *const Set, c: *Cache, input: Input, out: *Patterns) SearchError!bool {
    set.checkCache(c);
    aegis.assert.invariant(out.set == set.id, "a pattern set is filled by the set it was made for");
    out.bits.unsetAll();
    return pikevm.searchAll(&set.nfa, &c.pike, input, &out.bits) > 0;
}

/// The leftmost-first match over the set, as if its patterns were one alternation in index
/// order, and the pattern it belongs to. `error.HaystackTooLong` never occurs: a set stores no
/// rows.
pub fn first(set: *const Set, c: *Cache, input: Input) SearchError!?Match {
    set.checkCache(c);
    var slots: [2]?usize = undefined;
    _ = pikevm.search(&set.nfa, &c.pike, input, &slots) orelse return null;
    return .{ .span = .{ .start = slots[0].?, .end = slots[1].? }, .index = @fromBackingInt(c.pike.pattern), .set = set.id };
}

fn checkCache(set: *const Set, c: *const Cache) void {
    aegis.assert.invariant(c.set == set.id, "a cache searches the set it was made for");
}
