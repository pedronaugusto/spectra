//! The compiler: each fragment's shape and preference order, what the automaton matches (read
//! by a bounded backtracker over it, here only), UTF-8 classes checked code point by code point
//! and minimal, what is charged and refused, and any pattern compiled whole.
const std = @import("std");
const shakedown = @import("shakedown");
const Ast = @import("../syntax/Ast.zig");
const parse_mod = @import("../syntax/parse.zig");
const Syntax = @import("../Syntax.zig");
const Limits = @import("../Limits.zig");
const Hir = @import("../hir/Hir.zig");
const translate_mod = @import("../hir/translate.zig");
const Nfa = @import("Nfa.zig");
const compile_mod = @import("compile.zig");
const utf8 = @import("utf8.zig");
const backtrack = @import("../testing/backtrack.zig");
const testing = std.testing;

const ecma: Syntax = .{ .dialect = .ecmascript };

const Compiled = struct {
    arena_state: std.heap.ArenaAllocator,
    hir: Hir,
    nfa: Nfa,

    fn deinit(c: *Compiled) void {
        c.nfa.deinit(testing.allocator);
        c.arena_state.deinit();
    }
};

fn hirOf(a: std.mem.Allocator, pattern: []const u8, syntax: Syntax) !Hir {
    const ast = try a.create(Ast);
    ast.* = try parse_mod.parse(a, .init(pattern), syntax, .{}, null);
    return translate_mod.translate(a, ast, syntax, .{}, null);
}

fn compiled(pattern: []const u8, syntax: Syntax) !Compiled {
    var c: Compiled = .{ .arena_state = .init(testing.allocator), .hir = undefined, .nfa = undefined };
    errdefer c.arena_state.deinit();
    c.hir = try hirOf(c.arena_state.allocator(), pattern, syntax);
    c.nfa = try compile_mod.compile(testing.allocator, &c.hir, .{ .utf8 = syntax.utf8 }, null);
    return c;
}

fn dump(a: std.mem.Allocator, nfa: *const Nfa) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (nfa.states, 0..) |s, i| {
        const id: Nfa.StateId = @fromBackingInt(@as(u32, @intCast(i)));
        try w.print("{d}{s}{s}: ", .{ i, if (id == nfa.start_anchored) ">" else "", if (id == nfa.start_unanchored) "^" else "" });
        switch (s) {
            .byte_range => |t| try writeTransition(w, t),
            .sparse => |slice| {
                try w.writeAll("sparse(");
                for (nfa.transitionsOf(slice), 0..) |t, k| {
                    if (k > 0) try w.writeAll(", ");
                    try writeTransition(w, t);
                }
                try w.writeAll(")");
            },
            .look => |l| try w.print("look({t}) => {d}", .{ l.look, l.next.raw() }),
            .binary => |b| try w.print("alt({d}, {d})", .{ b.first.raw(), b.second.raw() }),
            .alternation => |slice| {
                try w.writeAll("alt(");
                for (nfa.alternativesOf(slice), 0..) |alt, k| try w.print("{s}{d}", .{ if (k == 0) "" else ", ", alt.raw() });
                try w.writeAll(")");
            },
            .capture => |cap| try w.print("slot({d}) => {d}", .{ cap.slot, cap.next.raw() }),
            .fail => try w.writeAll("fail"),
            .match => try w.writeAll("match"),
        }
        try w.writeAll("\n");
    }
    return out.written();
}

fn writeTransition(w: *std.Io.Writer, t: Nfa.Transition) !void {
    if (t.lo == t.hi) try w.print("{x:0>2} => {d}", .{ t.lo, t.next.raw() }) else try w.print("{x:0>2}-{x:0>2} => {d}", .{ t.lo, t.hi, t.next.raw() });
}

fn expectDump(pattern: []const u8, syntax: Syntax, expected: []const u8) !void {
    var c = try compiled(pattern, syntax);
    defer c.deinit();
    const got = try dump(c.arena_state.allocator(), &c.nfa);
    try testing.expectEqualStrings(expected, got);
}

test "each fragment's shape: alternatives in order, a lazy repetition preferring to leave" {
    try expectDump("a", .{},
        \\0>: slot(0) => 1
        \\1: 61 => 2
        \\2: slot(1) => 3
        \\3: match
        \\4^: alt(0, 5)
        \\5: 00-ff => 4
        \\
    );
    try expectDump("^a|^b|^c", .{},
        \\0>^: slot(0) => 1
        \\1: alt(2, 4, 6)
        \\2: look(start_text) => 3
        \\3: 61 => 8
        \\4: look(start_text) => 5
        \\5: 62 => 8
        \\6: look(start_text) => 7
        \\7: 63 => 8
        \\8: slot(1) => 9
        \\9: match
        \\
    );
    try expectDump("^a*", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 3
        \\2: 61 => 3
        \\3: alt(2, 4)
        \\4: slot(1) => 5
        \\5: match
        \\
    );
    try expectDump("^a*?", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 3
        \\2: 61 => 3
        \\3: alt(4, 2)
        \\4: slot(1) => 5
        \\5: match
        \\
    );
    // `(?:a?)*` is `(?:(?:a?)+)?`: 5 enters the operand or leaves, and after it 4 goes round
    // again or leaves, each preferring the operand.
    try expectDump("^(?:a?)*", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 5
        \\2: 61 => 4
        \\3: alt(2, 4)
        \\4: alt(3, 6)
        \\5: alt(3, 6)
        \\6: slot(1) => 7
        \\7: match
        \\
    );
    // `a{2,4}`: the operand and its three copies (2 to 5), then each optional time leaves
    // straight to the end.
    try expectDump("^a{2,4}", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 2
        \\2: 61 => 3
        \\3: 61 => 6
        \\4: 61 => 7
        \\5: 61 => 8
        \\6: alt(4, 8)
        \\7: alt(5, 8)
        \\8: slot(1) => 9
        \\9: match
        \\
    );
    try expectDump("^(a)(?<n>b)", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 2
        \\2: slot(2) => 3
        \\3: 61 => 4
        \\4: slot(3) => 5
        \\5: slot(4) => 6
        \\6: 62 => 7
        \\7: slot(5) => 8
        \\8: slot(1) => 9
        \\9: match
        \\
    );
    try expectDump("^[a-cx]", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 2
        \\2: sparse(61-63 => 3, 78 => 3)
        \\3: slot(1) => 4
        \\4: match
        \\
    );
    // An empty class never matches, and nothing after it is reached.
    try expectDump("^[^\\x00-\\x{10FFFF}]a", .{},
        \\0>^: slot(0) => 1
        \\1: look(start_text) => 2
        \\2: fail
        \\3: 61 => 4
        \\4: slot(1) => 5
        \\5: match
        \\
    );
}

test "a group's number and name, and the looks the automaton asks" {
    var c = try compiled("(?<first>a)(b)(?<third>c)\\b", .{});
    defer c.deinit();
    try testing.expectEqual(@as(u32, 4), c.nfa.groups);
    try testing.expectEqual(@as(u32, 8), c.nfa.slots());
    try testing.expect(c.nfa.names[0] == null);
    try testing.expectEqualStrings("first", c.nfa.names[1].?);
    try testing.expect(c.nfa.names[2] == null);
    try testing.expectEqualStrings("third", c.nfa.names[3].?);
    try testing.expect(c.nfa.looks.contains(.word_unicode));
    try testing.expectEqual(@as(usize, 1), c.nfa.looks.count());
}

/// The leftmost-first match and its groups' spans, read by the test backtracker.
fn search(gpa: std.mem.Allocator, nfa: *const Nfa, haystack: []const u8, slots: []?usize) !bool {
    return try backtrack.search(gpa, nfa, haystack, .{ .start = 0, .end = haystack.len }, false, slots) != null;
}

fn step(nfa: *const Nfa, s: Nfa.State, byte: u8) ?Nfa.StateId {
    return backtrack.step(nfa, s, byte);
}

const Case = struct {
    pattern: []const u8,
    haystack: []const u8,
    /// Each group's span, the whole match first; empty: no match.
    spans: []const ?[2]usize,
    syntax: Syntax = .{},
};

fn expectSearch(case: Case) !void {
    var c = try compiled(case.pattern, case.syntax);
    defer c.deinit();
    const slots = try testing.allocator.alloc(?usize, c.nfa.slots());
    defer testing.allocator.free(slots);
    const found = try search(testing.allocator, &c.nfa, case.haystack, slots);
    errdefer std.debug.print("/{s}/ on \"{s}\": {any}\n", .{ case.pattern, case.haystack, slots });
    try testing.expectEqual(case.spans.len > 0, found);
    if (!found) return;
    try testing.expectEqual(case.spans.len, c.nfa.groups);
    for (case.spans, 0..) |span, g| {
        if (span) |s| {
            try testing.expectEqual(@as(?usize, s[0]), slots[2 * g]);
            try testing.expectEqual(@as(?usize, s[1]), slots[2 * g + 1]);
        } else {
            try testing.expectEqual(@as(?usize, null), slots[2 * g]);
        }
    }
}

test "what the automaton matches: leftmost-first, Perl's preference, with captures" {
    const cases = [_]Case{
        .{ .pattern = "a", .haystack = "xay", .spans = &.{.{ 1, 2 }} },
        .{ .pattern = "a*", .haystack = "aaa", .spans = &.{.{ 0, 3 }} },
        .{ .pattern = "a*?", .haystack = "aaa", .spans = &.{.{ 0, 0 }} },
        .{ .pattern = "a+?", .haystack = "aaa", .spans = &.{.{ 0, 1 }} },
        .{ .pattern = "a{2,4}", .haystack = "aaaaa", .spans = &.{.{ 0, 4 }} },
        .{ .pattern = "a{2,4}?", .haystack = "aaaaa", .spans = &.{.{ 0, 2 }} },
        .{ .pattern = "a{2,}", .haystack = "aaaaa", .spans = &.{.{ 0, 5 }} },
        .{ .pattern = "a{3,}?", .haystack = "aaaaa", .spans = &.{.{ 0, 3 }} },
        .{ .pattern = "a{3}", .haystack = "aa", .spans = &.{} },
        .{ .pattern = "xa{0}y", .haystack = "xy", .spans = &.{.{ 0, 2 }} },
        .{ .pattern = "(a|ab)(c|bcd)(d*)", .haystack = "abcd", .spans = &.{ .{ 0, 4 }, .{ 0, 1 }, .{ 1, 4 }, .{ 4, 4 } } },
        // regex issue 779: once the operand matched empty, `*` still prefers another time.
        .{ .pattern = "(a*)*", .haystack = "b", .spans = &.{ .{ 0, 0 }, .{ 0, 0 } } },
        .{ .pattern = "(a*)+", .haystack = "b", .spans = &.{ .{ 0, 0 }, .{ 0, 0 } } },
        .{ .pattern = "(a*|b)*", .haystack = "b", .spans = &.{ .{ 0, 0 }, .{ 0, 0 } } },
        .{ .pattern = "(?:)*", .haystack = "", .spans = &.{.{ 0, 0 }} },
        .{ .pattern = "(?:)+x", .haystack = "ax", .spans = &.{.{ 1, 2 }} },
        .{ .pattern = "(?:a?)+", .haystack = "aa", .spans = &.{.{ 0, 2 }} },
        .{ .pattern = "(?:a*)*b", .haystack = "aab", .spans = &.{.{ 0, 3 }} },
        .{ .pattern = "(?:^)*a", .haystack = "ba", .spans = &.{.{ 1, 2 }} },
        .{ .pattern = "|b", .haystack = "abc", .spans = &.{.{ 0, 0 }} },
        .{ .pattern = "b|", .haystack = "bc", .spans = &.{.{ 0, 1 }} },
        .{ .pattern = "(a)|b", .haystack = "b", .spans = &.{ .{ 0, 1 }, null } },
        .{ .pattern = "^a", .haystack = "ba", .spans = &.{} },
        .{ .pattern = "a$", .haystack = "ab", .spans = &.{} },
        .{ .pattern = "a$", .haystack = "ba", .spans = &.{.{ 1, 2 }} },
        .{ .pattern = "(?m)^b$", .haystack = "a\nb\nc", .spans = &.{.{ 2, 3 }} },
        .{ .pattern = "(foo|foobar){2}", .haystack = "foofoobar", .spans = &.{ .{ 0, 6 }, .{ 3, 6 } } },
        .{ .pattern = "(a){0,2}?b", .haystack = "aab", .spans = &.{ .{ 0, 3 }, .{ 1, 2 } } },
        // Classes over UTF-8.
        .{ .pattern = "\\pL+", .haystack = "1\u{3b1}\u{3b2}2", .spans = &.{.{ 1, 5 }} },
        .{ .pattern = ".", .haystack = "\u{e9}", .spans = &.{.{ 0, 2 }} },
        .{ .pattern = "[^a]", .haystack = "a\u{1f600}", .spans = &.{.{ 1, 5 }} },
        .{ .pattern = "(?i)k", .haystack = "\u{212a}", .spans = &.{.{ 0, 3 }} },
        .{ .pattern = "(?-u:.)", .haystack = "\u{e9}", .spans = &.{.{ 0, 1 }}, .syntax = .{ .utf8 = false } },
        .{ .pattern = "(?-u:[\\xE9])", .haystack = "\u{e9}\xe9", .spans = &.{.{ 2, 3 }}, .syntax = .{ .utf8 = false } },
        .{ .pattern = "\\x{10000}-\\x{10FFFF}", .haystack = "a", .spans = &.{} },
        .{ .pattern = "[\\x{10000}-\\x{10FFFF}]", .haystack = "a\u{10ffff}", .spans = &.{.{ 1, 5 }} },
        // ECMAScript.
        .{ .pattern = "(?<y>\\d{4})-(?<m>\\d{2})", .haystack = "on 2026-11", .spans = &.{ .{ 3, 10 }, .{ 3, 7 }, .{ 8, 10 } }, .syntax = ecma },
        .{ .pattern = "[^]", .haystack = "\n", .spans = &.{.{ 0, 1 }}, .syntax = ecma },
        .{ .pattern = "^\\u{1F600}$", .haystack = "\u{1f600}", .spans = &.{.{ 0, 4 }}, .syntax = ecma },
    };
    for (cases) |case| try expectSearch(case);
}

test "lookahead is refused by name until the derivative engine runs it" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const hir = try hirOf(state.allocator(), "a(?=b)", ecma);
    var d: parse_mod.Diagnostic = .{};
    try testing.expectError(error.Unsupported, compile_mod.compile(testing.allocator, &hir, .{ .span = .{ .start = 0, .end = 6 } }, &d));
    try testing.expectEqual(parse_mod.Reason.unsupported_lookahead, d.reason);
    try testing.expectEqual(@as(u32, 6), d.span.end);
}

// UTF-8 classes.

fn sequencesOf(a: std.mem.Allocator, lo: u21, hi: u21) ![]const []const utf8.Range {
    var list: std.ArrayList([]const utf8.Range) = .empty;
    var it: utf8.Sequences = .init(lo, hi);
    while (it.next()) |seq| try list.append(a, try a.dupe(utf8.Range, seq.slice()));
    return list.items;
}

fn r(lo: u8, hi: u8) utf8.Range {
    return .{ .lo = lo, .hi = hi };
}

test "a range's UTF-8 sequences, as regex-syntax splits them" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    // regex-syntax's `bmp` test.
    const bmp = try sequencesOf(a, 0, 0xffff);
    const want = [_][]const utf8.Range{
        &.{r(0x0, 0x7f)},
        &.{ r(0xc2, 0xdf), r(0x80, 0xbf) },
        &.{ r(0xe0, 0xe0), r(0xa0, 0xbf), r(0x80, 0xbf) },
        &.{ r(0xe1, 0xec), r(0x80, 0xbf), r(0x80, 0xbf) },
        &.{ r(0xed, 0xed), r(0x80, 0x9f), r(0x80, 0xbf) },
        &.{ r(0xee, 0xef), r(0x80, 0xbf), r(0x80, 0xbf) },
    };
    try testing.expectEqual(want.len, bmp.len);
    for (want, bmp) |w, got| try testing.expectEqualSlices(utf8.Range, w, got);
    // One code point is one sequence of its own bytes; surrogates alone are none.
    for ([_]u21{ 0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff }) |cp| {
        const seqs = try sequencesOf(a, cp, cp);
        try testing.expectEqual(@as(usize, 1), seqs.len);
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try testing.expectEqual(n, seqs[0].len);
        for (seqs[0], buf[0..n]) |range, byte| try testing.expectEqual(r(byte, byte), range);
    }
    try testing.expectEqual(@as(usize, 0), (try sequencesOf(a, 0xd800, 0xdfff)).len);
}

fn sequenceTakes(seq: []const utf8.Range, bytes: []const u8) bool {
    if (seq.len != bytes.len) return false;
    for (seq, bytes) |range, byte| if (byte < range.lo or byte > range.hi) return false;
    return true;
}

fn anyRange(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const ends = [_]u21{ 0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xd800, 0xdfff, 0xe000, 0xffff, 0x10000, 0x10ffff };
    var x = if (shakedown.gen.boolean(s)) ends[shakedown.gen.intRange(s, usize, 0, ends.len - 1)] else shakedown.gen.intRange(s, u21, 0, 0x10ffff);
    var y = if (shakedown.gen.boolean(s)) ends[shakedown.gen.intRange(s, usize, 0, ends.len - 1)] else shakedown.gen.intRange(s, u21, 0, 0x10ffff);
    if (x > y) std.mem.swap(u21, &x, &y);
    case.note("U+{X}-U+{X}", .{ x, y });
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const seqs = try sequencesOf(state.allocator(), x, y);
    var prev: [4]u8 = undefined;
    var prev_len: usize = 0;
    for (seqs) |seq| {
        var lo: [4]u8 = undefined;
        for (seq, 0..) |range, i| lo[i] = range.lo;
        if (prev_len > 0) try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, prev[0..prev_len], lo[0..seq.len]));
        prev = lo;
        prev_len = seq.len;
    }
    // Code points in and around the range, each taken by one sequence exactly when it is a
    // scalar value in the range.
    var buf: [4]u8 = undefined;
    for (0..64) |_| {
        const cp = shakedown.gen.intRange(s, u21, x -| 2, @min(y + 2, 0x10ffff));
        if (cp >= 0xd800 and cp <= 0xdfff) continue;
        const n = try std.unicode.utf8Encode(cp, &buf);
        var takers: usize = 0;
        for (seqs) |seq| {
            if (sequenceTakes(seq, buf[0..n])) takers += 1;
        }
        try testing.expectEqual(@as(usize, @intFromBool(cp >= x and cp <= y)), takers);
    }
}

test "fuzz: a range's sequences take its scalar values and nothing else, in byte order" {
    try shakedown.check(testing.allocator, {}, anyRange, .{ .cases = 3000, .seed = 0x5e9 });
}

fn byteState(nfa: *const Nfa, id: Nfa.StateId) Nfa.StateId {
    var at = id;
    while (true) switch (nfa.state(at)) {
        .capture => |cap| at = cap.next,
        else => return at,
    };
}

/// Whether the anchored automaton of a lone class takes exactly `bytes`.
fn classTakes(nfa: *const Nfa, bytes: []const u8) bool {
    var at = byteState(nfa, nfa.start_anchored);
    for (bytes) |byte| at = byteState(nfa, step(nfa, nfa.state(at), byte) orelse return false);
    return nfa.state(at) == .match;
}

fn expectClassExact(pattern: []const u8, syntax: Syntax) !void {
    var c = try compiled(pattern, syntax);
    defer c.deinit();
    const ranges = switch (c.hir.node(c.hir.root)) {
        .unicode_class => |x| x,
        else => return error.NotAClass,
    };
    var k: usize = 0;
    var buf: [4]u8 = undefined;
    var cp: u21 = 0;
    while (true) : (cp += 1) {
        while (k < ranges.len and ranges[k][1] < cp) k += 1;
        const member = k < ranges.len and ranges[k][0] <= cp;
        const surrogate = cp >= 0xd800 and cp <= 0xdfff;
        if (surrogate) {
            // What would encode one, were UTF-8 to: never taken.
            buf = .{ 0xed, @intCast(0xa0 | ((cp >> 6) & 0x1f)), @intCast(0x80 | (cp & 0x3f)), 0 };
            try testing.expect(!classTakes(&c.nfa, buf[0..3]));
        } else {
            const n = try std.unicode.utf8Encode(cp, &buf);
            if (member != classTakes(&c.nfa, buf[0..n])) {
                std.debug.print("/{s}/ at U+{X}: member {}\n", .{ pattern, cp, member });
                return error.TestUnexpectedResult;
            }
        }
        if (cp == 0x10ffff) break;
    }
    try expectMinimal(&c.nfa);
}

/// No two states that read a byte read the same ranges into the same states: the class's
/// automaton is acyclic with one end, so that is minimal.
fn expectMinimal(nfa: *const Nfa) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var keys: std.heap.ArenaAllocator = .init(testing.allocator);
    defer keys.deinit();
    defer seen.deinit(testing.allocator);
    for (nfa.states) |s| {
        var one: [1]Nfa.Transition = undefined;
        const list: []const Nfa.Transition = switch (s) {
            .byte_range => |t| blk: {
                one[0] = t;
                break :blk &one;
            },
            .sparse => |slice| nfa.transitionsOf(slice),
            else => continue,
        };
        var key: std.ArrayList(u8) = .empty;
        for (list) |t| try key.print(keys.allocator(), "{d}-{d}>{d},", .{ t.lo, t.hi, t.next.raw() });
        const got = try seen.getOrPut(testing.allocator, key.items);
        try testing.expect(!got.found_existing);
    }
}

test "a UTF-8 class takes the encoding of each of its code points and nothing else, minimally" {
    try expectClassExact("\\pL", .{});
    try expectClassExact("\\w", .{});
    try expectClassExact("(?s).", .{});
    try expectClassExact("[^\\p{Greek}\\d]", .{});
}

test "the automaton of any scalar refuses every byte string that is not UTF-8" {
    var c = try compiled("(?s).", .{});
    defer c.deinit();
    var buf: [4]u8 = undefined;
    for (0..256) |x| {
        buf[0] = @intCast(x);
        try testing.expectEqual(x < 0x80, classTakes(&c.nfa, buf[0..1]));
    }
    for (0..0x10000) |x| {
        buf[0] = @intCast(x >> 8);
        buf[1] = @intCast(x & 0xff);
        try testing.expectEqual(valid(buf[0..2]), classTakes(&c.nfa, buf[0..2]));
    }
    for (0xe0..0xf0) |b0| for (0..0x10000) |x| {
        buf = .{ @intCast(b0), @intCast(x >> 8), @intCast(x & 0xff), 0 };
        try testing.expectEqual(valid(buf[0..3]), classTakes(&c.nfa, buf[0..3]));
    };
    const edges = [_]u8{ 0x7f, 0x80, 0x8f, 0x90, 0xbf, 0xc0 };
    for (0xf0..0xf8) |b0| for (edges) |b1| for (edges) |b2| for (edges) |b3| {
        buf = .{ @intCast(b0), b1, b2, b3 };
        try testing.expectEqual(valid(&buf), classTakes(&c.nfa, &buf));
    };
}

fn valid(bytes: []const u8) bool {
    const n = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (n != bytes.len) return false;
    _ = std.unicode.utf8Decode(bytes) catch return false;
    return true;
}

// What is charged.

fn charge(pattern: []const u8, limits: Limits) !struct { spent: usize, memory: usize, refused: ?anyerror, reason: parse_mod.Reason } {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const hir = try hirOf(state.allocator(), pattern, .{});
    var spent: usize = 0;
    var d: parse_mod.Diagnostic = .{};
    var nfa = compile_mod.compileCounted(testing.allocator, &hir, .{ .limits = limits }, &d, &spent) catch |err|
        return .{ .spent = spent, .memory = 0, .refused = err, .reason = d.reason };
    defer nfa.deinit(testing.allocator);
    return .{ .spent = spent, .memory = nfa.memory(), .refused = null, .reason = d.reason };
}

test "the automaton is charged before it is allocated, a repetition's copies among it" {
    const one = try charge("\\pL", .{});
    try testing.expectEqual(@as(?anyerror, null), one.refused);
    // What is charged stays within a small factor of what is kept: lists grow by doubling and
    // a builder's state is larger than the automaton's (measured: 6 times, 80 KB for 13 KB).
    try testing.expect(one.spent <= 8 * one.memory + 64 * 1024);
    const ten = try charge("\\pL{10}", .{});
    try testing.expectEqual(@as(?anyerror, null), ten.refused);
    try testing.expect(ten.memory >= 10 * (one.memory - 1024));
    try testing.expect(ten.spent <= 8 * ten.memory + 64 * 1024);

    // A thousand times a thousand copies of a class is refused once its charge passes the limit.
    const nested = try charge("(?:\\pL{1000}){1000}", .{});
    try testing.expectEqual(@as(?anyerror, error.TooLarge), nested.refused);
    try testing.expectEqual(parse_mod.Reason.nfa_too_large, nested.reason);
    try testing.expect(nested.spent <= (Limits{}).nfa.raw());

    const small = try charge("\\pL", .{ .nfa = .literal("1KiB") });
    try testing.expectEqual(@as(?anyerror, error.TooLarge), small.refused);
    const literals = try charge("a{1000}{1000}", .{});
    try testing.expectEqual(@as(?anyerror, error.TooLarge), literals.refused);
}

// Any pattern.

const alphabet = "ab()[]{}|*+?^$.\\-&:<>=!,019dDsSwWpPbBkqxuLniU_ ";

fn anyCompile(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const n = shakedown.gen.intRange(s, usize, 0, 24);
    const pattern = try case.gpa.alloc(u8, n);
    for (pattern) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    const options = [_]Syntax{ .{}, .{ .unicode = false }, .{ .utf8 = false, .unicode = false }, .{ .case_insensitive = true }, ecma, .{ .dialect = .ecmascript, .unicode = false }, .{ .dialect = .ecmascript, .unicode_sets = true } };
    const syntax = options[shakedown.gen.intRange(s, usize, 0, options.len - 1)];
    case.note("/{s}/ {any}", .{ pattern, syntax });
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    const ast = parse_mod.parse(a, .init(pattern), syntax, .{}, null) catch |err| switch (err) {
        error.Invalid, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    const hir = translate_mod.translate(a, &ast, syntax, .{}, null) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    var d: parse_mod.Diagnostic = .{};
    var nfa = compile_mod.compile(case.gpa, &hir, .{ .utf8 = syntax.utf8 }, &d) catch |err| switch (err) {
        error.Unsupported, error.TooLarge => {
            try testing.expect(d.reason != .none);
            return;
        },
        error.OutOfMemory => return err,
    };
    defer nfa.deinit(case.gpa);
    try expectWellFormed(&nfa);

    const slots = try case.gpa.alloc(?usize, nfa.slots());
    var haystack: [8]u8 = undefined;
    const len = shakedown.gen.intRange(s, usize, 0, haystack.len);
    for (haystack[0..len]) |*b| b.* = "ab\n1_ "[shakedown.gen.intRange(s, usize, 0, 5)];
    if (try search(case.gpa, &nfa, haystack[0..len], slots)) {
        try testing.expect(slots[0].? <= slots[1].?);
        for (0..nfa.groups) |g| if (slots[2 * g]) |start| try testing.expect(start <= slots[2 * g + 1].?);
    }
}

fn expectWellFormed(nfa: *const Nfa) !void {
    const n = nfa.states.len;
    try testing.expect(nfa.start_anchored.raw() < n and nfa.start_unanchored.raw() < n);
    var matches: usize = 0;
    for (nfa.states) |s| switch (s) {
        .byte_range => |t| try testing.expect(t.lo <= t.hi and t.next.raw() < n),
        .sparse => |slice| {
            const list = nfa.transitionsOf(slice);
            try testing.expect(list.len >= 2);
            for (list, 0..) |t, k| {
                try testing.expect(t.lo <= t.hi and t.next.raw() < n);
                if (k > 0) try testing.expect(t.lo > list[k - 1].hi);
            }
        },
        .look => |l| try testing.expect(l.next.raw() < n),
        .binary => |b| try testing.expect(b.first.raw() < n and b.second.raw() < n),
        .alternation => |slice| {
            try testing.expect(slice.len >= 3);
            for (nfa.alternativesOf(slice)) |alt| try testing.expect(alt.raw() < n);
        },
        .capture => |cap| try testing.expect(cap.slot < nfa.slots() and cap.slot / 2 == cap.group and cap.next.raw() < n),
        .fail => {},
        .match => matches += 1,
    };
    try testing.expectEqual(@as(usize, 1), matches);
}

test "fuzz: any pattern that translates compiles to a well-formed automaton or is refused by name" {
    try shakedown.check(testing.allocator, {}, anyCompile, .{ .cases = 3000, .seed = 0x4e46 });
}
