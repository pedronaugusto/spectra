//! The public engine: compile, is-match, find, captures and iteration; the PikeVM agreeing with
//! the test backtracker on any pattern and haystack; and its work counted linear on the patterns
//! that make a backtracker exponential.
const std = @import("std");
const shakedown = @import("shakedown");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const pikevm = @import("pikevm.zig");
const backtrack = @import("testing/backtrack.zig");
const testing = std.testing;
const gpa = testing.allocator;

const ecma: Syntax = .{ .dialect = .ecmascript };

fn compiled(pattern: []const u8, syntax: Syntax) !Regex {
    return Regex.compile(gpa, .init(pattern), .{ .syntax = syntax });
}

test "is-match, find, captures and names" {
    var re = try compiled("(?<year>\\d{4})-(\\d{2})(x)?", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expect(re.isMatch(&cache, "on 2026-11 then"));
    try testing.expect(!re.isMatch(&cache, "on 26-11"));
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 3, .end = 10 }), re.find(&cache, .of("on 2026-11 then")));
    try testing.expectEqual(@as(u32, 4), re.captureCount());
    try testing.expectEqual(@as(?u32, 1), re.captureIndex("year"));
    try testing.expectEqual(@as(?u32, null), re.captureIndex("month"));
    var groups: [4]?Regex.Span = undefined;
    try testing.expect(re.captures(&cache, .of("on 2026-11 then"), &groups));
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 3, .end = 10 }), groups[0]);
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 3, .end = 7 }), groups[1]);
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 8, .end = 10 }), groups[2]);
    try testing.expectEqual(@as(?Regex.Span, null), groups[3]);
}

test "a span of the haystack is searched, its assertions seeing the whole haystack" {
    var re = try compiled("^a|b$", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    // `^` holds at the haystack's start only, not the span's.
    try testing.expectEqual(@as(?Regex.Span, null), re.find(&cache, .{ .haystack = "xab", .span = .{ .start = 1, .end = 2 } }));
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 2, .end = 3 }), re.find(&cache, .{ .haystack = "xab", .span = .{ .start = 1, .end = 3 } }));
    var anchored = try compiled("b", .{});
    defer anchored.deinit();
    var c2 = try anchored.cache(gpa);
    defer c2.deinit(gpa);
    try testing.expectEqual(@as(?Regex.Span, null), anchored.find(&c2, .{ .haystack = "ab", .span = .{ .start = 0, .end = 2 }, .anchored = true }));
    try testing.expectEqual(@as(?Regex.Span, .{ .start = 1, .end = 2 }), anchored.find(&c2, .{ .haystack = "ab", .span = .{ .start = 1, .end = 2 }, .anchored = true }));
}

fn expectAll(pattern: []const u8, syntax: Syntax, haystack: []const u8, want: []const [2]usize) !void {
    var re = try compiled(pattern, syntax);
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    var it = re.findAll(&cache, haystack);
    var got: std.ArrayList([2]usize) = .empty;
    defer got.deinit(gpa);
    while (it.next()) |m| try got.append(gpa, .{ m.start, m.end });
    errdefer std.debug.print("/{s}/ on \"{s}\": {any}\n", .{ pattern, haystack, got.items });
    try testing.expectEqualSlices([2]usize, want, got.items);
}

test "every match in turn: an empty match right after another is passed over, and none splits a code point" {
    try expectAll("a*", .{}, "baaab", &.{ .{ 0, 0 }, .{ 1, 4 }, .{ 5, 5 } });
    try expectAll("|b", .{}, "abc", &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } });
    try expectAll("b|", .{}, "abc", &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 3, 3 } });
    // U+2603 is three bytes: no empty match inside it.
    try expectAll("", .{}, "\u{2603}", &.{ .{ 0, 0 }, .{ 3, 3 } });
    try expectAll("", .{ .utf8 = false }, "\u{2603}", &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } });
    try expectAll("\\b", .{}, "ab cd", &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 3, 3 }, .{ 5, 5 } });
    try expectAll("\\B", .{}, "\u{e9}", &.{});
    try expectAll("^", .{ .dialect = .ecmascript, .multi_line = true }, "a\u{2028}b\rc", &.{ .{ 0, 0 }, .{ 4, 4 }, .{ 6, 6 } });
    try expectAll("$", .{ .dialect = .ecmascript, .multi_line = true }, "a\u{2028}b", &.{ .{ 1, 1 }, .{ 5, 5 } });
    try expectAll("(?Rm)^", .{}, "a\r\nb\rc", &.{ .{ 0, 0 }, .{ 3, 3 }, .{ 5, 5 } });
}

fn expectGroups(pattern: []const u8, syntax: Syntax, haystack: []const u8, want: []const ?Regex.Span) !void {
    var re = try compiled(pattern, syntax);
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    const got = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(got);
    try testing.expect(re.captures(&cache, .of(haystack), got));
    errdefer std.debug.print("/{s}/ on \"{s}\": {any}\n", .{ pattern, haystack, got });
    try testing.expectEqualSlices(?Regex.Span, want, got);
}

test "an ECMAScript iteration starts with its atom's captures cleared; Rust's keep the last" {
    const ab: Regex.Span = .{ .start = 0, .end = 2 };
    try expectGroups("(?:(a)|b)+", ecma, "ab", &.{ ab, null });
    try expectGroups("(?:(a)|b)+", .{}, "ab", &.{ ab, .{ .start = 0, .end = 1 } });
    try expectGroups("(?:(a)|(b))+", ecma, "ab", &.{ ab, null, .{ .start = 1, .end = 2 } });
    try expectGroups("((a)|b)*", ecma, "ab", &.{ ab, .{ .start = 1, .end = 2 }, null });
    // One iteration only: nothing to clear, and the group stays.
    try expectGroups("(?:(a)|b)?b", ecma, "ab", &.{ ab, .{ .start = 0, .end = 1 } });
    try expectGroups("(?:(a)|b){2}", ecma, "ab", &.{ ab, null });
}

test "a refused pattern says where and why" {
    var d: Regex.Diagnostic = .{};
    try testing.expectError(error.Invalid, Regex.compile(gpa, .init("a(b"), .{ .diagnostic = &d }));
    try testing.expect(d.reason != .none);
    d = .{};
    try testing.expectError(error.Unsupported, Regex.compile(gpa, .init("a(?=b)"), .{ .syntax = ecma, .diagnostic = &d }));
    try testing.expectEqual(Regex.Diagnostic{ .span = .{ .start = 0, .end = 6 }, .reason = .unsupported_lookahead }, d);
    d = .{};
    try testing.expectError(error.TooLarge, Regex.compile(gpa, .init("(?:\\pL{1000}){1000}"), .{ .diagnostic = &d }));
}

// The PikeVM against the backtracker.

const alphabet = "ab()[]{}|*+?^$.\\-&:<>=!,019dDsSwWpPbBkqxuLniUmR_ ";
const pieces = [_][]const u8{ "a", "b", "1", "_", " ", "\n", "\r", "\u{e9}", "\u{212a}", "\u{2028}", "\u{1f600}", "\xff", "\x80" };

fn anyAgreement(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const n = shakedown.gen.intRange(s, usize, 0, 20);
    const pattern = try case.gpa.alloc(u8, n);
    defer case.gpa.free(pattern);
    for (pattern) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    const options = [_]Syntax{ .{}, .{ .unicode = false }, .{ .utf8 = false, .unicode = false }, .{ .utf8 = false }, .{ .case_insensitive = true }, .{ .multi_line = true }, ecma, .{ .dialect = .ecmascript, .unicode = false }, .{ .dialect = .ecmascript, .unicode_sets = true, .case_insensitive = true } };
    const syntax = options[shakedown.gen.intRange(s, usize, 0, options.len - 1)];
    var haystack: std.ArrayList(u8) = .empty;
    defer haystack.deinit(case.gpa);
    for (0..shakedown.gen.intRange(s, usize, 0, 8)) |_| try haystack.appendSlice(case.gpa, pieces[shakedown.gen.intRange(s, usize, 0, pieces.len - 1)]);
    case.note("/{s}/ {any} on {any}", .{ pattern, syntax, haystack.items });
    var re = Regex.compile(case.gpa, .init(pattern), .{ .syntax = syntax }) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    defer re.deinit();
    var cache = try re.cache(case.gpa);
    defer cache.deinit(case.gpa);
    const h = haystack.items;
    var lo = shakedown.gen.intRange(s, usize, 0, h.len);
    var hi = shakedown.gen.intRange(s, usize, 0, h.len);
    if (lo > hi) std.mem.swap(usize, &lo, &hi);
    const anchored = shakedown.gen.boolean(s);
    const input: pikevm.Input = .{ .haystack = h, .span = .{ .start = lo, .end = hi }, .anchored = anchored };
    const slots = re.nfa.slots();
    const want = try case.gpa.alloc(?usize, slots);
    defer case.gpa.free(want);
    const want_end = try backtrack.search(case.gpa, &re.nfa, h, .{ .start = lo, .end = hi }, anchored, want);
    const got = cache.pike.slots;
    const got_end = pikevm.search(&re.nfa, &cache.pike, input, got);
    try testing.expectEqual(want_end, got_end);
    if (got_end != null) try testing.expectEqualSlices(?usize, want, got);
    // Is-match agrees, and stops no later than the match.
    var earliest = input;
    earliest.earliest = true;
    try testing.expectEqual(want_end != null, pikevm.search(&re.nfa, &cache.pike, earliest, &.{}) != null);
}

test "fuzz: the PikeVM's match and captures are the backtracker's" {
    try shakedown.check(gpa, {}, anyAgreement, .{ .cases = 5000, .seed = 0x91e });
}

// The linear bound, counted.

fn visited(pattern: []const u8, haystack: []const u8) !struct { visited: usize, states: usize } {
    var re = try compiled(pattern, .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    _ = re.find(&cache, .of(haystack));
    return .{ .visited = cache.pike.visited, .states = re.nfa.states.len };
}

test "a search's work is linear in the haystack on what makes a backtracker exponential" {
    const cases = [_]struct { pattern: []const u8, fill: u8 }{
        .{ .pattern = "(a*)*b", .fill = 'a' },
        .{ .pattern = "(a|a)*b", .fill = 'a' },
        .{ .pattern = "(x+x+)+y", .fill = 'x' },
        .{ .pattern = "(?:a?){32}a{32}", .fill = 'a' },
        .{ .pattern = "(\\w+\\s?)+$", .fill = 'w' },
    };
    const big = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(big);
    for (cases) |case| {
        @memset(big, case.fill);
        const small = try visited(case.pattern, big[0 .. 16 * 1024]);
        const large = try visited(case.pattern, big);
        // Each position enters each state at most twice: once in a closure, once stepped.
        try testing.expect(large.visited <= 2 * large.states * (big.len + 1));
        // Four times the haystack is four times the work, give or take the ends.
        errdefer std.debug.print("/{s}/: {d} then {d}\n", .{ case.pattern, small.visited, large.visited });
        try testing.expect(large.visited <= 4 * small.visited + 4 * large.states);
    }
}
