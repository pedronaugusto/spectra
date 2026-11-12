//! ECMA-262's pattern semantics (§22.2.2) written as the specification writes them, over the
//! HIR: each node a matcher that takes a state and a continuation and returns the state the
//! whole match ends in, or failure. A quantifier is RepeatMatcher, with its two rules: the
//! atom's captures are cleared before each iteration, and an iteration past the minimum that
//! matched empty fails. A lookaround stops at its first success and keeps that success's
//! captures. A lookbehind's body is matched in the backward direction (§22.2.2's `direction`):
//! a concatenation's terms right to left, each character read before the position, a group's
//! range from where it ends back to where it began. Nothing here reads the automaton, so it is
//! what the engines' ECMAScript matching is checked against.
//!
//! It reads the haystack's code points, ECMAScript's reading with `u` or `v`, and without them
//! the same wherever no code point is past U+FFFF. Flags are already in the HIR: case folding
//! in its sets, `s` in its dot, `m` in its line assertions. Tests only: it backtracks without
//! memory, exponential in the worst case, so it counts its steps and gives up at a budget.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Hir = @import("../hir/Hir.zig");

pub const Span = struct { start: usize, end: usize };

pub const Error = Allocator.Error || error{
    /// More steps than the budget.
    Budget,
    /// A node ECMAScript never writes: a byte class, or one of Rust's assertions.
    Unsupported,
    /// The haystack is not UTF-8.
    InvalidUtf8,
};

/// What `exec` finds from the haystack's start, as `RegExpBuiltinExec` without the sticky
/// flag: each group's span in bytes, group 0 the whole match; null where nothing matches.
/// `budget` bounds the matcher calls.
pub fn exec(arena: Allocator, hir: *const Hir, haystack: []const u8, budget: usize) Error!?[]const ?Span {
    var points: std.ArrayList(u21) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < haystack.len) {
        const n = std.unicode.utf8ByteSequenceLength(haystack[i]) catch return error.InvalidUtf8;
        if (i + n > haystack.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(haystack[i..][0..n]) catch return error.InvalidUtf8;
        try points.append(arena, cp);
        try offsets.append(arena, i);
        i += n;
    }
    try offsets.append(arena, haystack.len);
    var m: Matcher = .{ .arena = arena, .hir = hir, .input = points.items, .left = budget };
    const none = try arena.alloc(?[2]usize, hir.captures + 1);
    @memset(none, null);
    var start: usize = 0;
    while (start <= m.input.len) : (start += 1) {
        const found = try m.match(hir.root, .{ .end = start, .caps = none }, &.done, .forward) orelse continue;
        const spans = try arena.alloc(?Span, hir.captures + 1);
        spans[0] = .{ .start = offsets.items[start], .end = offsets.items[found.end] };
        for (spans[1..], found.caps[1..]) |*s, c| s.* = if (c) |r| .{ .start = offsets.items[r[0]], .end = offsets.items[r[1]] } else null;
        return spans;
    }
    return null;
}

/// Whether lookaround `node` holds at byte `at` of `haystack`, as ECMA-262 evaluates it there:
/// its body matched forward from `at` for a lookahead, backward from `at` for a lookbehind, to
/// a first success; before `negated`. `at` begins a code point. `budget` bounds the matcher
/// calls.
pub fn lookaroundHolds(arena: Allocator, hir: *const Hir, node: Hir.Index, haystack: []const u8, at: usize, budget: usize) Error!bool {
    const la = hir.node(node).lookaround;
    var points: std.ArrayList(u21) = .empty;
    var start: ?usize = null;
    var i: usize = 0;
    while (i <= haystack.len) {
        if (i == at) start = points.items.len;
        if (i == haystack.len) break;
        const n = std.unicode.utf8ByteSequenceLength(haystack[i]) catch return error.InvalidUtf8;
        if (i + n > haystack.len) return error.InvalidUtf8;
        try points.append(arena, std.unicode.utf8Decode(haystack[i..][0..n]) catch return error.InvalidUtf8);
        i += n;
    }
    var m: Matcher = .{ .arena = arena, .hir = hir, .input = points.items, .left = budget };
    const none = try arena.alloc(?[2]usize, hir.captures + 1);
    @memset(none, null);
    const found = try m.match(la.sub, .{ .end = start orelse return error.InvalidUtf8, .caps = none }, &.done, switch (la.kind) {
        .ahead => .forward,
        .behind => .backward,
    });
    return found != null;
}

/// The specification's MatchState: where the input is read to, and each group's captured
/// range, by code point. A state is never changed once made; a capture makes a new one.
const State = struct {
    end: usize,
    caps: []const ?[2]usize,
};

/// The specification's `direction`: forward, or backward inside a lookbehind.
pub const Dir = enum { forward, backward };

/// The specification's MatcherContinuation, one closure per case.
const Cont = union(enum) {
    /// The pattern's end, and a lookaround's: success, in the state reached.
    done,
    /// The rest of a concatenation, then `next`: the terms still to match, in the order the
    /// direction matches them.
    rest: struct { nodes: []const Hir.Index, dir: Dir, next: *const Cont },
    /// A group's close: its range between `start` and where it ends, then `next`.
    close: struct { group: u32, start: usize, dir: Dir, next: *const Cont },
    /// RepeatMatcher's `d`: one iteration matched from `from`; the rest of the quantifier.
    repeat: struct { rep: Hir.Repetition, min: u32, max: ?u32, from: usize, parens: Parens, dir: Dir, next: *const Cont },
};

/// The groups inside a quantified atom: `parenIndex + 1` to `parenIndex + parenCount`.
const Parens = struct { first: u32, end: u32 };

const Matcher = struct {
    arena: Allocator,
    hir: *const Hir,
    input: []const u21,
    left: usize,

    fn step(m: *Matcher) Error!void {
        if (m.left == 0) return error.Budget;
        m.left -= 1;
    }

    /// The code point the direction reads next from `at`, and where the read leaves it.
    fn read(m: *const Matcher, at: usize, dir: Dir) ?struct { cp: u21, to: usize } {
        return switch (dir) {
            .forward => if (at < m.input.len) .{ .cp = m.input[at], .to = at + 1 } else null,
            .backward => if (at > 0) .{ .cp = m.input[at - 1], .to = at - 1 } else null,
        };
    }

    /// The node's matcher, run on `x` with continuation `c`, in direction `dir`.
    fn match(m: *Matcher, index: Hir.Index, x: State, c: *const Cont, dir: Dir) Error!?State {
        try m.step();
        switch (m.hir.node(index)) {
            .empty => return m.proceed(c, x),
            .literal => |bytes| {
                var points: std.ArrayList(u21) = .empty;
                var view = (std.unicode.Utf8View.init(bytes) catch return error.Unsupported).iterator();
                while (view.nextCodepoint()) |cp| try points.append(m.arena, cp);
                // Each character its own term: backward, the last is read first.
                if (dir == .backward) std.mem.reverse(u21, points.items);
                var at = x.end;
                for (points.items) |cp| {
                    const r = m.read(at, dir) orelse return null;
                    if (r.cp != cp) return null;
                    at = r.to;
                }
                return m.proceed(c, .{ .end = at, .caps = x.caps });
            },
            .unicode_class => |ranges| {
                const r = m.read(x.end, dir) orelse return null;
                for (ranges) |range| if (range[0] <= r.cp and r.cp <= range[1]) return m.proceed(c, .{ .end = r.to, .caps = x.caps });
                return null;
            },
            .byte_class => return error.Unsupported,
            .look => |look| return if (try m.holds(look, x.end)) m.proceed(c, x) else null,
            .concat => |slice| {
                const nodes = m.hir.childrenOf(slice);
                return switch (dir) {
                    .forward => m.match(nodes[0], x, &.{ .rest = .{ .nodes = nodes[1..], .dir = dir, .next = c } }, dir),
                    .backward => m.match(nodes[nodes.len - 1], x, &.{ .rest = .{ .nodes = nodes[0 .. nodes.len - 1], .dir = dir, .next = c } }, dir),
                };
            },
            .alternation => |slice| {
                for (m.hir.childrenOf(slice)) |alt| if (try m.match(alt, x, c, dir)) |r| return r;
                return null;
            },
            .capture => |cap| return m.match(cap.sub, x, &.{ .close = .{ .group = cap.index, .start = x.end, .dir = dir, .next = c } }, dir),
            .lookaround => |la| {
                const r = try m.match(la.sub, x, &.done, switch (la.kind) {
                    .ahead => .forward,
                    .behind => .backward,
                });
                if (la.negated) return if (r == null) m.proceed(c, x) else null;
                const y = r orelse return null;
                return m.proceed(c, .{ .end = x.end, .caps = y.caps });
            },
            .repetition => |rep| return m.repeat(rep, rep.min, rep.max, x, c, m.parensOf(rep.sub), dir),
        }
    }

    /// RepeatMatcher(m, min, max, greedy, x, c, parenIndex, parenCount).
    fn repeat(m: *Matcher, rep: Hir.Repetition, min: u32, max: ?u32, x: State, c: *const Cont, parens: Parens, dir: Dir) Error!?State {
        try m.step();
        if (max == 0) return m.proceed(c, x);
        const d: Cont = .{ .repeat = .{ .rep = rep, .min = min, .max = max, .from = x.end, .parens = parens, .dir = dir, .next = c } };
        const caps = try m.arena.dupe(?[2]usize, x.caps);
        for (caps[parens.first..parens.end]) |*k| k.* = null;
        const xr: State = .{ .end = x.end, .caps = caps };
        if (min != 0) return m.match(rep.sub, xr, &d, dir);
        if (!rep.greedy) {
            if (try m.proceed(c, x)) |z| return z;
            return m.match(rep.sub, xr, &d, dir);
        }
        if (try m.match(rep.sub, xr, &d, dir)) |z| return z;
        return m.proceed(c, x);
    }

    /// Calls continuation `c` on `y`.
    fn proceed(m: *Matcher, c: *const Cont, y: State) Error!?State {
        try m.step();
        switch (c.*) {
            .done => return y,
            .rest => |r| {
                if (r.nodes.len == 0) return m.proceed(r.next, y);
                return switch (r.dir) {
                    .forward => m.match(r.nodes[0], y, &.{ .rest = .{ .nodes = r.nodes[1..], .dir = r.dir, .next = r.next } }, r.dir),
                    .backward => m.match(r.nodes[r.nodes.len - 1], y, &.{ .rest = .{ .nodes = r.nodes[0 .. r.nodes.len - 1], .dir = r.dir, .next = r.next } }, r.dir),
                };
            },
            .close => |cl| {
                const caps = try m.arena.dupe(?[2]usize, y.caps);
                caps[cl.group] = switch (cl.dir) {
                    .forward => .{ cl.start, y.end },
                    .backward => .{ y.end, cl.start },
                };
                return m.proceed(cl.next, .{ .end = y.end, .caps = caps });
            },
            .repeat => |d| {
                // An iteration past the minimum that matched empty fails.
                if (d.min == 0 and y.end == d.from) return null;
                const min = if (d.min == 0) 0 else d.min - 1;
                const max = if (d.max) |n| n - 1 else null;
                return m.repeat(d.rep, min, max, y, d.next, d.parens, d.dir);
            },
        }
    }

    /// The groups a quantified atom holds: the lowest and past the highest index under it.
    fn parensOf(m: *Matcher, sub: Hir.Index) Parens {
        var p: Parens = .{ .first = std.math.maxInt(u32), .end = 0 };
        m.walk(sub, &p);
        return if (p.end == 0) .{ .first = 0, .end = 0 } else p;
    }

    fn walk(m: *Matcher, index: Hir.Index, p: *Parens) void {
        switch (m.hir.node(index)) {
            .capture => |cap| {
                p.first = @min(p.first, cap.index);
                p.end = @max(p.end, cap.index + 1);
                m.walk(cap.sub, p);
            },
            .repetition => |rep| m.walk(rep.sub, p),
            .lookaround => |la| m.walk(la.sub, p),
            .concat, .alternation => |slice| for (m.hir.childrenOf(slice)) |child| m.walk(child, p),
            else => {},
        }
    }

    /// The assertions ECMAScript writes, as §22.2.2.6 states them.
    fn holds(m: *Matcher, look: Hir.Look, at: usize) Error!bool {
        const input = m.input;
        return switch (look) {
            .start_text => at == 0,
            .end_text => at == input.len,
            .start_line_ecma => at == 0 or lineTerminator(input[at - 1]),
            .end_line_ecma => at == input.len or lineTerminator(input[at]),
            .word_ascii => m.wordBefore(at, false) != m.wordAfter(at, false),
            .not_word_ascii => m.wordBefore(at, false) == m.wordAfter(at, false),
            .word_ecma_folded => m.wordBefore(at, true) != m.wordAfter(at, true),
            .not_word_ecma_folded => m.wordBefore(at, true) == m.wordAfter(at, true),
            else => error.Unsupported,
        };
    }

    fn wordBefore(m: *const Matcher, at: usize, folded: bool) bool {
        return at > 0 and wordChar(m.input[at - 1], folded);
    }

    fn wordAfter(m: *const Matcher, at: usize, folded: bool) bool {
        return at < m.input.len and wordChar(m.input[at], folded);
    }
};

/// LineTerminator: LF, CR, LS and PS.
fn lineTerminator(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

/// IsWordChar: WordCharacters, `[0-9A-Za-z_]`, and with `u` or `v` and `i` the two code points
/// that fold into them, U+017F (to `s`) and U+212A (to `k`).
fn wordChar(cp: u21, folded: bool) bool {
    return switch (cp) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        0x017f, 0x212a => folded,
        else => false,
    };
}

const testing = std.testing;

/// The spans `exec` gives `pattern` on `haystack`, flattened: start and end of each group,
/// `null` for an unset one, in `arena`.
fn spansOf(arena: Allocator, pattern: []const u8, haystack: []const u8) !?[]const ?[2]usize {
    const Syntax = @import("../Syntax.zig");
    const syntax: Syntax = .{ .dialect = .ecmascript, .unicode = false };
    const ast = try arena.create(@import("../syntax/Ast.zig"));
    ast.* = try @import("../syntax/parse.zig").parse(arena, .init(pattern), syntax, .{}, null);
    const hir = try @import("../hir/translate.zig").translate(arena, ast, syntax, .{}, null);
    const spans = try exec(arena, &hir, haystack, 100_000) orelse return null;
    const out = try arena.alloc(?[2]usize, spans.len);
    for (out, spans) |*o, s| o.* = if (s) |x| .{ x.start, x.end } else null;
    return out;
}

test "an iteration past the minimum that matches empty fails, as RepeatMatcher's check says" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // V8: /(|a)+/.exec("a") is ["a", "a"]: the second iteration's empty alternative fails.
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 0, 1 }, .{ 0, 1 } }), try spansOf(a, "(|a)+", "a"));
    // /(a*)*/.exec("b") is ["", undefined]: the one iteration matched empty, so none counts.
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 0, 0 }, null }), try spansOf(a, "(a*)*", "b"));
    // /(a*|b)*/.exec("b") is ["b", "b"]: a* matches empty and fails, b is taken.
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 0, 1 }, .{ 0, 1 } }), try spansOf(a, "(a*|b)*", "b"));
    // /(a*)?/.exec("") is ["", undefined].
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 0, 0 }, null }), try spansOf(a, "(a*)?", ""));
}

test "an iteration clears its atom's captures, and a lookahead keeps its first success's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // /(?:(a)|b)+/.exec("ab") is ["ab", undefined].
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 0, 2 }, null }), try spansOf(a, "(?:(a)|b)+", "ab"));
    // /(?=(a+))/.exec("baaabac") is ["", "aaa"] at 1: the lookahead's first success, greedy,
    // and no backtracking into it.
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 1, 1 }, .{ 1, 4 } }), try spansOf(a, "(?=(a+))", "baaabac"));
    // /(?=(a+))a*b/.exec("baaabac") is ["aaab", "aaa"].
    try testing.expectEqualDeep(@as(?[]const ?[2]usize, &.{ .{ 1, 5 }, .{ 1, 4 } }), try spansOf(a, "(?=(a+))a*b", "baaabac"));
}
