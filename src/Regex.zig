//! A compiled pattern: is-match, find, captures and every match in turn. Immutable once
//! compiled, so any number of threads search it, each with a `Cache` of its own.
//!
//! Engines: the lazy DFA finds whether there is a match and where the leftmost-first one ends;
//! the PikeVM, over the span cut at that end, finds where it starts and its captures. Where the
//! lazy DFA quits or gives up, the PikeVM searches the whole span from its start; a pattern with
//! no lazy DFA (`engines`) is the PikeVM's alone. Each engine is linear in the haystack and the
//! automaton, and is tested against the others.
const Regex = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Syntax = @import("Syntax.zig");
const Limits = @import("Limits.zig");
const Ast = @import("syntax/Ast.zig");
const parse_mod = @import("syntax/parse.zig");
const diagnostic_zig = @import("syntax/diagnostic.zig");
const translate_mod = @import("hir/translate.zig");
const Nfa = @import("nfa/Nfa.zig");
const compile_mod = @import("nfa/compile.zig");
const pikevm = @import("pikevm.zig");
const lazy = @import("lazy.zig");

pub const Span = pikevm.Span;
pub const Input = pikevm.Input;
pub const Diagnostic = diagnostic_zig.Diagnostic;

gpa: Allocator,
nfa: Nfa,
/// The lazy DFA's alphabet and cache sizes; null when `Limits.lazy_dfa` holds too few states.
dfa: ?lazy.Dfa,

pub const Options = struct {
    syntax: Syntax = .{},
    limits: Limits = .{},
    /// Where a refused pattern was refused, and why.
    diagnostic: ?*Diagnostic = null,
};

pub const CompileError = error{ OutOfMemory, Invalid, Unsupported, TooLarge };

pub fn compile(gpa: Allocator, pattern: aegis.input.Untrusted([]const u8), options: Options) CompileError!Regex {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const ast = try a.create(Ast);
    ast.* = try parse_mod.parse(a, pattern, options.syntax, options.limits, options.diagnostic);
    const hir = try translate_mod.translate(a, ast, options.syntax, options.limits, options.diagnostic);
    const whole = ast.node(ast.root).span;
    const nfa = try compile_mod.compile(gpa, &hir, .{
        .limits = options.limits,
        .utf8 = options.syntax.utf8,
        .span = whole,
        .ecma = options.syntax.dialect == .ecmascript,
    }, options.diagnostic);
    errdefer {
        var held = nfa;
        held.deinit(gpa);
    }
    const dfa = lazy.build(&nfa, options.limits.lazy_dfa.raw());
    // What each search's cache would hold, refused before any is made.
    if ((cacheBytesOf(&nfa, if (dfa) |*d| d else null) orelse std.math.maxInt(usize)) > options.limits.cache.raw()) {
        if (options.diagnostic) |d| d.* = .{ .span = whole, .reason = .cache_too_large };
        return error.TooLarge;
    }
    return .{ .gpa = gpa, .nfa = nfa, .dfa = dfa };
}

fn cacheBytesOf(nfa: *const Nfa, dfa: ?*const lazy.Dfa) ?usize {
    const pike = pikevm.sizes(nfa).bytes() orelse return null;
    const lazy_bytes = if (dfa) |d| d.bytes() else 0;
    return std.math.add(usize, pike, lazy_bytes) catch null;
}

/// The bytes a `Cache` of this pattern allocates, every engine's: what `Limits.cache` bounded.
pub fn cacheBytes(re: *const Regex) usize {
    return cacheBytesOf(&re.nfa, if (re.dfa) |*d| d else null).?;
}

/// The engines the compiled pattern has. The PikeVM always; the lazy DFA unless its store
/// (`Limits.lazy_dfa`) cannot hold the fewest states a search needs.
pub const Engines = struct {
    pikevm: bool = true,
    lazy_dfa: bool,
};

pub fn engines(re: *const Regex) Engines {
    return .{ .lazy_dfa = re.dfa != null };
}

pub fn deinit(re: *Regex) void {
    re.nfa.deinit(re.gpa);
    re.* = undefined;
}

/// What one task's searches of this pattern need, allocated once.
pub const Cache = struct {
    pike: pikevm.Cache,
    lazy: ?lazy.Cache,
    /// How the last search was answered, for the tests that count each engine's work.
    last: Path = .pikevm,

    pub const Path = enum {
        /// The PikeVM alone: no lazy DFA.
        pikevm,
        /// The lazy DFA, and the PikeVM over the span cut at the match's end where a start or
        /// captures were asked.
        lazy_dfa,
        /// The lazy DFA quit or gave up, and the PikeVM searched the span from its start.
        lazy_dfa_fell_back,
    };

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.pike.deinit(gpa);
        if (c.lazy) |*l| l.deinit(gpa);
    }
};

pub fn cache(re: *const Regex, gpa: Allocator) Allocator.Error!Cache {
    var pike: pikevm.Cache = try .init(gpa, &re.nfa);
    errdefer pike.deinit(gpa);
    return .{ .pike = pike, .lazy = if (re.dfa) |*d| try lazy.Cache.init(gpa, d) else null };
}

/// What the PikeVM searches: the input cut at the match's end where the lazy DFA found one, null
/// where it found none, and the input whole where there is no lazy DFA or it quit or gave up.
/// Cut there, the PikeVM's leftmost-first match is the same: no match starts earlier, and the
/// preferred one from its start ends at the cut; assertions still see the whole haystack.
fn narrowed(re: *const Regex, c: *Cache, input: Input) ?Input {
    c.pike.visited = 0;
    const d = if (re.dfa) |*d| d else {
        c.last = .pikevm;
        return input;
    };
    const found = lazy.search(&re.nfa, d, &c.lazy.?, input) catch {
        c.last = .lazy_dfa_fell_back;
        return input;
    };
    c.last = .lazy_dfa;
    const end = found orelse return null;
    var cut = input;
    cut.span.end = end;
    return cut;
}

/// Capture groups, the whole match (group 0) among them.
pub fn captureCount(re: *const Regex) u32 {
    return re.nfa.groups;
}

/// The number of the group named `name`.
pub fn captureIndex(re: *const Regex, name: []const u8) ?u32 {
    for (re.nfa.names, 0..) |n, i| {
        if (n) |got| if (std.mem.eql(u8, got, name)) return @intCast(i);
    }
    return null;
}

pub fn isMatch(re: *const Regex, c: *Cache, haystack: []const u8) bool {
    var input: Input = .of(haystack);
    input.earliest = true;
    const cut = re.narrowed(c, input) orelse return false;
    if (c.last == .lazy_dfa) return true;
    return pikevm.search(&re.nfa, &c.pike, cut, &.{}) != null;
}

/// The leftmost-first match.
pub fn find(re: *const Regex, c: *Cache, input: Input) ?Span {
    var slots: [2]?usize = undefined;
    const cut = re.narrowed(c, input) orelse return null;
    _ = pikevm.search(&re.nfa, &c.pike, cut, &slots) orelse return null;
    return .{ .start = slots[0].?, .end = slots[1].? };
}

/// The leftmost-first match with each group's span in `out`, null where a group took no part.
/// `out.len == captureCount()` is the caller's contract.
pub fn captures(re: *const Regex, c: *Cache, input: Input, out: []?Span) bool {
    aegis.assert.invariant(out.len == re.nfa.groups, "a capture slice holds one span per group");
    const slots = c.pike.slots;
    const cut = re.narrowed(c, input) orelse return false;
    _ = pikevm.search(&re.nfa, &c.pike, cut, slots) orelse return false;
    for (out, 0..) |*span, g| {
        span.* = if (slots[2 * g]) |start| .{ .start = start, .end = slots[2 * g + 1].? } else null;
    }
    return true;
}

/// Every match in turn, leftmost first and apart; an empty match right after the one before is
/// passed over, so the search always moves on.
///
/// Each search is linear, and each starts where the last match ended, so the iteration is linear
/// where each search stops near its match: over many matches and near misses alike. It is not
/// where a preferred branch outlives the matches it does not take: in `\w+X|\w` over a run of
/// word bytes with no X, each match is one byte but `\w+X` keeps each search reading to the end
/// of the run, so the iteration is quadratic in the run (counted in the tests: twice the run,
/// four times the work). Leftmost-first matching is like this in every engine, regex's among
/// them; a caller iterating over untrusted haystacks bounds them by span.
pub fn findAll(re: *const Regex, c: *Cache, haystack: []const u8) Matches {
    return re.findAllIn(c, .of(haystack));
}

/// `findAll` over a span, or anchored: each match then starts where the one before ended.
pub fn findAllIn(re: *const Regex, c: *Cache, input: Input) Matches {
    return .{ .re = re, .cache = c, .input = input };
}

pub const Matches = struct {
    re: *const Regex,
    cache: *Cache,
    input: Input,
    last_end: ?usize = null,

    pub fn next(m: *Matches) ?Span {
        if (m.input.span.start > m.input.span.end) return null;
        var found = m.re.find(m.cache, m.input) orelse return null;
        if (found.start == found.end and m.last_end == found.end) {
            if (m.input.span.start >= m.input.span.end) return null;
            m.input.span.start += 1;
            found = m.re.find(m.cache, m.input) orelse return null;
        }
        m.input.span.start = found.end;
        m.last_end = found.end;
        return found;
    }

    /// The next match as `next` finds it, with each group's span in `out`.
    pub fn nextCaptures(m: *Matches, out: []?Span) bool {
        if (m.input.span.start > m.input.span.end) return false;
        if (!m.re.captures(m.cache, m.input, out)) return false;
        if (out[0].?.start == out[0].?.end and m.last_end == out[0].?.end) {
            if (m.input.span.start >= m.input.span.end) return false;
            m.input.span.start += 1;
            if (!m.re.captures(m.cache, m.input, out)) return false;
        }
        m.input.span.start = out[0].?.end;
        m.last_end = out[0].?.end;
        return true;
    }
};
