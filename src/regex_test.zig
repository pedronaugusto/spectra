//! The public engine: compile, is-match, find, captures and iteration; the PikeVM agreeing with
//! the test backtracker on any pattern and haystack; and its work counted linear on the patterns
//! that make a backtracker exponential.
const std = @import("std");
const shakedown = @import("shakedown");
const Regex = @import("Regex.zig");
const Limits = @import("Limits.zig");
const Syntax = @import("Syntax.zig");
const pikevm = @import("pikevm.zig");
const backtrack = @import("testing/backtrack.zig");
const bounded = @import("backtrack.zig");
const onepass = @import("onepass.zig");
const lazy = @import("lazy.zig");
const grammar = @import("testing/grammar.zig");
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

test "an ECMAScript iteration past the minimum that matches empty fails; Rust's is taken" {
    const none: Regex.Span = .{ .start = 0, .end = 0 };
    // Node's verdicts on each.
    try expectGroups("(a*)*", ecma, "b", &.{ none, null });
    try expectGroups("(a*)*", .{}, "b", &.{ none, none });
    // The minimum's iteration is not checked.
    try expectGroups("(a*)+", ecma, "", &.{ none, none });
    // The empty alternative fails past the first time, so the next takes `a`.
    try expectGroups("(|a)+", ecma, "a", &.{ .{ .start = 0, .end = 1 }, .{ .start = 0, .end = 1 } });
    try expectGroups("(a?)?", ecma, "", &.{ none, null });
    try expectGroups("(?:a?){1,3}", ecma, "a", &.{.{ .start = 0, .end = 1 }});
    // The third time would match `b?` empty, so it fails and the second's captures stand,
    // the inner group cleared at its start.
    try expectGroups("((a)|b?)*", ecma, "ab", &.{ .{ .start = 0, .end = 2 }, .{ .start = 1, .end = 2 }, null });
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
    // The lazy DFA's store, small enough at times that it clears and gives up.
    const stores = [_]usize{ 2 << 20, 64 << 10, 16 << 10, 8 << 10 };
    const store = stores[shakedown.gen.intRange(s, usize, 0, stores.len - 1)];
    // The backtracker's bits and stack, small enough at times that a span is too long for them
    // or the stack fills.
    const budgets = [_]usize{ 256 << 10, 4 << 10, 512, 160, 128 };
    const budget = budgets[shakedown.gen.intRange(s, usize, 0, budgets.len - 1)];
    var re = Regex.compile(case.gpa, .init(pattern), .{ .syntax = syntax, .limits = .{ .lazy_dfa = .fromRaw(store), .backtrack = .fromRaw(budget) } }) catch |err| switch (err) {
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
    // The one-pass DFA, anchored, finds the same, every slot.
    if (re.onepass) |*d| if (anchored) {
        try testing.expectEqual(want_end, onepass.search(d, input, got));
        if (want_end != null) try testing.expectEqualSlices(?usize, want, got);
        agreed.onepass += 1;
    };
    // The bounded backtracker finds the same, every slot, where the span fits its bits, or its
    // stack fills.
    if (re.backtracker) |b| if (hi - lo <= b.longest().?) {
        if (bounded.search(&re.nfa, &cache.back.?, input, got)) |ended| {
            try testing.expectEqual(want_end, ended);
            if (ended != null) try testing.expectEqualSlices(?usize, want, got);
            agreed.backtracked += 1;
        } else |_| agreed.deep += 1;
    } else {
        agreed.too_long += 1;
    };
    // The lazy DFA finds the same end, or quits or gives up; with `earliest`, whether one exists.
    if (re.dfa) |*d| {
        if (lazy.search(&re.nfa, d, &cache.lazy.?, input)) |ended| try testing.expectEqual(want_end, ended) else |_| {}
        if (lazy.search(&re.nfa, d, &cache.lazy.?, earliest)) |any| try testing.expectEqual(want_end != null, any != null) else |_| {}
    }
    // And the public engine, on whichever path it takes: the match, and every group's span.
    if (re.find(&cache, input)) |m| {
        try testing.expectEqual(want_end, m.end);
        try testing.expectEqual(want[0], m.start);
    } else try testing.expectEqual(null, want_end);
    const groups = try case.gpa.alloc(?Regex.Span, re.captureCount());
    defer case.gpa.free(groups);
    if (re.captures(&cache, input, groups)) {
        try testing.expect(want_end != null);
        for (groups, 0..) |g, k| {
            const w: ?Regex.Span = if (want[2 * k]) |start| .{ .start = start, .end = want[2 * k + 1].? } else null;
            try testing.expectEqual(w, g);
        }
    } else try testing.expectEqual(null, want_end);
}

/// What the fuzz above reached of the bounded backtracker.
var agreed: struct { backtracked: usize = 0, deep: usize = 0, too_long: usize = 0, onepass: usize = 0 } = .{};

test "fuzz: the PikeVM's match and captures are the backtracker's" {
    agreed = .{};
    try shakedown.check(gpa, {}, anyAgreement, .{ .cases = 5000, .seed = 0x91e });
    errdefer std.debug.print("{any}\n", .{agreed});
    // Spans here are short: the one too long for the bits is the test below's.
    try testing.expect(agreed.backtracked > 1000 and agreed.deep > 100 and agreed.onepass > 300);
}

// The lazy DFA against the PikeVM.

/// What the fuzz below reached, so a change that stops it reaching them shows.
var reached: struct {
    answered: usize = 0,
    cleared: usize = 0,
    gave_up: usize = 0,
    quit: usize = 0,
    checked: usize = 0,
    /// The reverse lazy DFA's start, against the PikeVM's: found, with empty checks forward, and
    /// given up.
    reversed: usize = 0,
    reversed_checked: usize = 0,
    reverse_gave_up: usize = 0,
    /// Reversed, a look forward never has may quit: ECMAScript keeps no time of `(?:^)*`, Rust's
    /// shape one.
    reverse_quit: usize = 0,
} = .{};

fn anyLazy(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try grammar.write(s, &out, a, 4);
    const options = [_]Syntax{ .{}, .{ .multi_line = true }, .{ .unicode = false }, ecma, .{ .dialect = .ecmascript, .multi_line = true }, .{ .dialect = .ecmascript, .unicode = false } };
    const syntax = options[shakedown.gen.intRange(s, usize, 0, options.len - 1)];
    const stores = [_]usize{ 2 << 20, 4 << 10, 2 << 10, 1 << 10 };
    const store = stores[shakedown.gen.intRange(s, usize, 0, stores.len - 1)];
    var haystack: std.ArrayList(u8) = .empty;
    const bits = [_][]const u8{ "a", "b", "a", "b", "\n", "_", " ", "\u{e9}" };
    for (0..shakedown.gen.intRange(s, usize, 0, 24)) |_| try haystack.appendSlice(a, bits[shakedown.gen.intRange(s, usize, 0, bits.len - 1)]);
    case.note("/{s}/ {any} store {d} on {any}", .{ out.items, syntax, store, haystack.items });
    var re = Regex.compile(case.gpa, .init(out.items), .{ .syntax = syntax, .limits = .{ .lazy_dfa = .fromRaw(store) } }) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    defer re.deinit();
    const d = &(re.dfa orelse return);
    var cache = try re.cache(case.gpa);
    defer cache.deinit(case.gpa);
    const h = haystack.items;
    // One cache over many searches: its states, clears and give-up carry from one to the next.
    for (0..8) |_| {
        var lo = shakedown.gen.intRange(s, usize, 0, h.len);
        var hi = shakedown.gen.intRange(s, usize, 0, h.len);
        if (lo > hi) std.mem.swap(usize, &lo, &hi);
        if (shakedown.gen.boolean(s)) lo = 0;
        if (shakedown.gen.boolean(s)) hi = h.len;
        var input: pikevm.Input = .{ .haystack = h, .span = .{ .start = lo, .end = hi }, .anchored = shakedown.gen.intRange(s, u8, 0, 3) == 0 };
        var slots: [2]?usize = undefined;
        const want = pikevm.search(&re.nfa, &cache.pike, input, &slots);
        var from: usize = undefined;
        if (lazy.searchFrom(&re.nfa, d, &cache.lazy.?, input, &from, if (re.prefilter) |*p| p else null)) |got| {
            try testing.expectEqual(want, got);
            reached.answered += 1;
            if (re.nfa.loop_checks) reached.checked += 1;
            // Read back from the end, the earliest start of a match ending there is the
            // leftmost-first match's: forward with ECMAScript's empty checks, reversed without.
            if (got) |end| if (re.reverse) |*r| {
                var back = input;
                back.span = .{ .start = from, .end = end };
                if (lazy.searchReverse(&r.nfa, &r.dfa, &cache.reverse.?, back)) |start| {
                    try testing.expectEqual(slots[0], start);
                    reached.reversed += 1;
                    if (re.nfa.loop_checks) reached.reversed_checked += 1;
                } else |err| switch (err) {
                    error.Quit => reached.reverse_quit += 1,
                    error.GaveUp => reached.reverse_gave_up += 1,
                }
            };
        } else |err| switch (err) {
            error.Quit => reached.quit += 1,
            error.GaveUp => reached.gave_up += 1,
        }
        input.earliest = true;
        if (lazy.search(&re.nfa, d, &cache.lazy.?, input)) |got| try testing.expectEqual(want != null, got != null) else |_| {}
    }
    reached.cleared += cache.lazy.?.clears;
}

test "fuzz: the lazy DFA's match ends are the PikeVM's, in both dialects, through clears and give-ups" {
    reached = .{};
    try shakedown.check(gpa, {}, anyLazy, .{ .cases = 4000, .seed = 0x1a2d });
    errdefer std.debug.print("{any}\n", .{reached});
    try testing.expect(reached.answered > 10_000 and reached.checked > 1_000);
    try testing.expect(reached.cleared > 100 and reached.gave_up > 10 and reached.quit > 100);
    try testing.expect(reached.reversed > 5_000 and reached.reversed_checked > 1_000 and reached.reverse_gave_up > 0);
}

test "the lazy DFA runs a position's closure whole, as the PikeVM does: an alternation a loop returns to is entered once" {
    // Rust's `(?:\b|a)*` on "a": `\b` holds at 0, so the first time is empty and the loop
    // returns to the alternation, already entered: the empty match outranks reading `a`.
    // The fuzz found it where a closure stopped at the look and resumed from it alone.
    const cases = [_]struct { pattern: []const u8, haystack: []const u8 }{
        .{ .pattern = "(?:\\b|a)*", .haystack = "a" },
        .{ .pattern = "(?:^|a)*", .haystack = "a" },
        .{ .pattern = "(?:\\b|a)*?b", .haystack = "ab" },
        .{ .pattern = "(?:(?:\\b|$)|a)+", .haystack = "aa" },
    };
    for (cases) |case| for ([_]Syntax{ .{}, ecma }) |syntax| {
        var re = try compiled(case.pattern, syntax);
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        const want = pikevm.search(&re.nfa, &cache.pike, .of(case.haystack), &.{});
        try testing.expectEqual(want, try lazy.search(&re.nfa, &re.dfa.?, &cache.lazy.?, .of(case.haystack)));
    };
    var re = try compiled("(?:\\b|a)*", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 0, .end = 0 }, re.find(&cache, .of("a")).?);
    try testing.expectEqual(.lazy_dfa, cache.last);
}

// The linear bound, counted.

/// A search's work, every engine's: the lazy DFA's bytes read and threads entered building
/// transitions, and the PikeVM's threads entered.
fn visited(pattern: []const u8, syntax: Syntax, haystack: []const u8) !struct { visited: usize, threads: usize } {
    var re = try compiled(pattern, syntax);
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    _ = re.find(&cache, .of(haystack));
    return .{ .visited = cache.pike.visited + cache.lazy.?.visited + cache.reverse.?.visited + cache.back.?.explored, .threads = pikevm.sizes(&re.nfa).threads };
}

test "a search's work is linear in the haystack on what makes a backtracker exponential" {
    const cases = [_]struct { pattern: []const u8, syntax: Syntax = .{}, fill: u8, checked: bool = false }{
        .{ .pattern = "(a*)*b", .fill = 'a' },
        .{ .pattern = "(a|a)*b", .fill = 'a' },
        .{ .pattern = "(x+x+)+y", .fill = 'x' },
        .{ .pattern = "(?:a?){32}a{32}", .fill = 'a' },
        .{ .pattern = "(\\w+\\s?)+$", .fill = 'w' },
        // ECMAScript's empty checks: each thread a state and a bit, twice the threads, and
        // still linear.
        .{ .pattern = "(a*)*b", .syntax = ecma, .fill = 'a', .checked = true },
        .{ .pattern = "(a?)*b", .syntax = ecma, .fill = 'a', .checked = true },
        .{ .pattern = "((a|)*)*b", .syntax = ecma, .fill = 'a', .checked = true },
        .{ .pattern = "(|a)+b", .syntax = ecma, .fill = 'a', .checked = true },
        .{ .pattern = "(?:a?){0,32}a{32}", .syntax = ecma, .fill = 'a', .checked = true },
    };
    const big = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(big);
    for (cases) |case| {
        @memset(big, case.fill);
        const small = try visited(case.pattern, case.syntax, big[0 .. 16 * 1024]);
        const large = try visited(case.pattern, case.syntax, big);
        errdefer std.debug.print("/{s}/: {d} then {d}\n", .{ case.pattern, small.visited, large.visited });
        var re = try compiled(case.pattern, case.syntax);
        defer re.deinit();
        try testing.expectEqual(case.checked, re.nfa.loop_checks);
        // Each position enters each thread at most twice in the PikeVM, and once more in a
        // state the lazy DFA builds, which reads each byte once more.
        try testing.expect(large.visited <= 3 * large.threads * (big.len + 1) + big.len);
        // Four times the haystack is four times the work, give or take the ends.
        try testing.expect(large.visited <= 4 * small.visited + 4 * large.threads);
    }
}

test "a cache holds what Limits.cache bounds: counted once, refused at compile past it" {
    // What Cache.init allocates is the figure the compiler checked, byte for byte.
    var re = try Regex.compile(testing.allocator, .init("(a)(b)+(?:c|d|e)\\w{3}"), .{});
    defer re.deinit();
    const want = re.cacheBytes();
    try testing.expect(re.engines().lazy_dfa);
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var cache = try re.cache(counting.allocator());
    try testing.expectEqual(want, counting.allocated_bytes);
    cache.deinit(counting.allocator());

    // At the figure it compiles; a byte under it is refused by name.
    const at: Limits = .{ .cache = .fromRaw(want) };
    var held = try Regex.compile(testing.allocator, .init("(a)(b)+(?:c|d|e)\\w{3}"), .{ .limits = at });
    held.deinit();
    var d: Regex.Diagnostic = .{};
    const under: Limits = .{ .cache = .fromRaw(want - 1) };
    try testing.expectError(error.TooLarge, Regex.compile(testing.allocator, .init("(a)(b)+(?:c|d|e)\\w{3}"), .{ .limits = under, .diagnostic = &d }));
    try testing.expectEqual(.cache_too_large, d.reason);

    // Many groups in a row: the slot tables grow as states times groups. 300 fit the default,
    // 500 do not.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var few = try Regex.compile(testing.allocator, .init(try repeatText(a.allocator(), "(a)", 300)), .{});
    few.deinit();
    try testing.expectError(error.TooLarge, Regex.compile(testing.allocator, .init(try repeatText(a.allocator(), "(a)", 500)), .{ .diagnostic = &d }));
    try testing.expectEqual(.cache_too_large, d.reason);
}

fn repeatText(a: std.mem.Allocator, unit: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, unit.len * n);
    for (0..n) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
    return out;
}

// The lazy DFA's paths: answered, quit, given up, absent.

test "a lazy DFA that clears too often gives up, the PikeVM searches the span from its start, and the work stays linear" {
    // (a|b)*a(a|b){20} has a DFA state for each of the last 21 bytes' a and b: on random a and b
    // nearly every byte builds one, and a store of 64 KiB holds some hundreds.
    const pattern = "(a|b)*a(a|b){20}";
    var re = try Regex.compile(gpa, .init(pattern), .{ .limits = .{ .lazy_dfa = .literal("64KiB") } });
    defer re.deinit();
    var alone = try Regex.compile(gpa, .init(pattern), .{ .limits = .{ .lazy_dfa = .fromRaw(0), .backtrack = .fromRaw(0), .onepass = .fromRaw(0) }, .prefilter = false });
    defer alone.deinit();
    try testing.expect(re.engines().lazy_dfa and !alone.engines().lazy_dfa);
    var alone_cache = try alone.cache(gpa);
    defer alone_cache.deinit(gpa);
    const big = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(big);
    var prng: std.Random.DefaultPrng = .init(0x9a7e);
    for (big) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';
    var work: [2]struct { lazy: usize, pike: usize } = undefined;
    for ([_]usize{ 16 * 1024, big.len }, 0..) |n, i| {
        // A cache of its own: one that gave up already gives up at its next clear.
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        const got = re.find(&cache, .of(big[0..n]));
        try testing.expectEqual(.lazy_dfa_fell_back, cache.last);
        try testing.expectEqual(alone.find(&alone_cache, .of(big[0..n])), got);
        work[i] = .{ .lazy = cache.lazy.?.visited, .pike = cache.pike.visited };
    }
    // The give-up comes at the same byte whatever follows: the lazy DFA's work does not grow.
    try testing.expectEqual(work[0].lazy, work[1].lazy);
    // Four times the haystack is four times the work, both engines' together.
    errdefer std.debug.print("{any}\n", .{work});
    try testing.expect(work[1].lazy + work[1].pike <= 4 * (work[0].lazy + work[0].pike));
    try testing.expect(work[1].pike >= 3 * work[0].pike);
}

test "a reverse lazy DFA that gives up leaves the start to the PikeVM, over the span cut at the end, and the work stays linear" {
    // Forward, (a|b){20}a(a|b)* counts to twenty and is small; read back from the end, every match
    // counts, so the state holds which of the last twenty-one bytes read were an a: on random a
    // and b nearly every byte builds one.
    const pattern = "(a|b){20}a(a|b)*";
    var re = try Regex.compile(gpa, .init(pattern), .{ .limits = .{ .lazy_dfa = .literal("64KiB") } });
    defer re.deinit();
    try testing.expectEqual(Regex.Engines{ .lazy_dfa = true, .reverse_dfa = true, .backtrack = true, .onepass = true, .prefilter = true }, re.engines());
    const big = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(big);
    var prng: std.Random.DefaultPrng = .init(0x7e5e);
    for (big) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';
    big[20] = 'a';
    var work: [2]struct { reverse: usize, pike: usize } = undefined;
    for ([_]usize{ 16 * 1024, big.len }, 0..) |n, i| {
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        try testing.expectEqual(Regex.Span{ .start = 0, .end = n }, re.find(&cache, .of(big[0..n])).?);
        try testing.expectEqual(.lazy_dfa, cache.last);
        try testing.expectEqual(.reverse_dfa_fell_back, cache.last_start);
        work[i] = .{ .reverse = cache.reverse.?.visited, .pike = cache.pike.visited };
    }
    errdefer std.debug.print("{any}\n", .{work});
    // The give-up comes after about as many bytes read back, whatever the haystack's length.
    try testing.expect(work[1].reverse <= 2 * work[0].reverse);
    try testing.expect(work[1].reverse + work[1].pike <= 4 * (work[0].reverse + work[0].pike));
}

test "the reverse lazy DFA finds where the leftmost-first match starts, with each look read the other way" {
    const cases = [_]struct { pattern: []const u8, syntax: Syntax = .{}, haystack: []const u8, want: Regex.Span }{
        .{ .pattern = "abc", .haystack = "xxabcxx", .want = .{ .start = 2, .end = 5 } },
        .{ .pattern = "a+", .haystack = "baaab", .want = .{ .start = 1, .end = 4 } },
        .{ .pattern = "\\bfoo\\b", .haystack = "afoo foo", .want = .{ .start = 5, .end = 8 } },
        .{ .pattern = "\\Bo+", .haystack = "o foo", .want = .{ .start = 3, .end = 5 } },
        .{ .pattern = "(?m)^b$", .haystack = "a\nb\nc", .want = .{ .start = 2, .end = 3 } },
        .{ .pattern = "(?Rm)^b$", .haystack = "a\r\nb\r\nc", .want = .{ .start = 3, .end = 4 } },
        .{ .pattern = "\\Ab|c\\z", .haystack = "bc", .want = .{ .start = 0, .end = 1 } },
        .{ .pattern = "\\p{Greek}+\\d", .haystack = "x\u{3b1}\u{3b2}7", .want = .{ .start = 1, .end = 6 } },
        .{ .pattern = "[\u{e9}\u{10000}-\u{10ffff}]+", .haystack = "a\u{e9}\u{1f600}b", .want = .{ .start = 1, .end = 7 } },
        .{ .pattern = "(?:a?)*b", .syntax = ecma, .haystack = "xaab", .want = .{ .start = 1, .end = 4 } },
        .{ .pattern = "(a*)*b", .syntax = ecma, .haystack = "cb", .want = .{ .start = 1, .end = 2 } },
    };
    for (cases) |case| {
        // No prefilter: a literal pattern would be the prefilter's alone.
        var re = try Regex.compile(gpa, .init(case.pattern), .{ .syntax = case.syntax, .prefilter = false });
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        errdefer std.debug.print("/{s}/ on {s}\n", .{ case.pattern, case.haystack });
        try testing.expectEqual(case.want, re.find(&cache, .of(case.haystack)).?);
        try testing.expectEqual(.reverse_dfa, cache.last_start);
    }
}

test "a look that needs more than a byte quits the lazy DFA on a byte past 0x7f, and the PikeVM answers" {
    const cases = [_]struct { pattern: []const u8, syntax: Syntax = .{}, ascii: []const u8, wide: []const u8, want: [2]Regex.Span }{
        .{ .pattern = "\\bb\\b", .ascii = "a b c", .wide = "\u{e9} b c", .want = .{ .{ .start = 2, .end = 3 }, .{ .start = 3, .end = 4 } } },
        .{ .pattern = "^b", .syntax = .{ .dialect = .ecmascript, .multi_line = true }, .ascii = "a\nb", .wide = "a\u{2028}b", .want = .{ .{ .start = 2, .end = 3 }, .{ .start = 4, .end = 5 } } },
    };
    for (cases) |case| {
        // No prefilter: it would skip to the candidate past the wide byte, and nothing would quit.
        var re = try Regex.compile(gpa, .init(case.pattern), .{ .syntax = case.syntax, .prefilter = false });
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        try testing.expectEqual(case.want[0], re.find(&cache, .of(case.ascii)).?);
        try testing.expectEqual(.lazy_dfa, cache.last);
        try testing.expectEqual(case.want[1], re.find(&cache, .of(case.wide)).?);
        try testing.expectEqual(.lazy_dfa_fell_back, cache.last);
    }
    // ASCII's `\b` reads one byte: no quit.
    var re = try compiled("(?-u:\\b)b", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 3, .end = 4 }, re.find(&cache, .of("\u{e9} b")).?);
    try testing.expectEqual(.lazy_dfa, cache.last);
}

test "a store too small for the fewest states leaves the pattern no lazy DFA, and says so" {
    var re = try Regex.compile(gpa, .init("a+b"), .{ .limits = .{ .lazy_dfa = .fromRaw(64) } });
    defer re.deinit();
    try testing.expectEqual(Regex.Engines{ .lazy_dfa = false, .reverse_dfa = false, .backtrack = true, .onepass = true, .prefilter = false }, re.engines());
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 1, .end = 4 }, re.find(&cache, .of("xaab")).?);
    try testing.expectEqual(.pikevm, cache.last);
    var roomy = try Regex.compile(gpa, .init("a+b"), .{});
    defer roomy.deinit();
    try testing.expectEqual(Regex.Engines{ .lazy_dfa = true, .reverse_dfa = true, .backtrack = true, .onepass = true, .prefilter = false }, roomy.engines());
}

// Every match in turn, counted.

const Iteration = struct { work: usize, matches: usize };

/// Every engine's work over `findAll`, summed over its searches.
fn iterationWork(pattern: []const u8, haystack: []const u8) !Iteration {
    var re = try compiled(pattern, .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    var it = re.findAll(&cache, haystack);
    var total: Iteration = .{ .work = 0, .matches = 0 };
    while (true) {
        const m = it.next();
        total.work += cache.pike.visited + (if (cache.lazy) |l| l.visited else 0) + (if (cache.reverse) |r| r.visited else 0) + (if (cache.back) |b| b.explored else 0);
        if (m == null) break;
        total.matches += 1;
    }
    return total;
}

test "every match in turn is linear over many matches and near misses, and quadratic where a preferred branch outlives each match" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Many matches and near misses: each search reads to its match and stops there.
    const unit = "abxab abc ";
    for ([_][]const u8{ "abc", "a[bx]c|b", "\\babc\\b" }) |pattern| {
        const small = try iterationWork(pattern, try repeatText(a, unit, 1000));
        const large = try iterationWork(pattern, try repeatText(a, unit, 4000));
        errdefer std.debug.print("/{s}/: {any} then {any}\n", .{ pattern, small, large });
        try testing.expectEqual(4 * small.matches, large.matches);
        try testing.expect(large.work <= 4 * small.work + 64);
    }
    // `\w+X|\w` over word bytes and no X: each match is one byte, but the preferred `\w+X` lives to
    // the haystack's end, so each search reads the rest of it. Twice the haystack is four times
    // the work: the iteration is quadratic, in every leftmost-first engine (regex's too), and
    // `Regex.findAll` says so.
    const small = try iterationWork("\\w+X|\\w", try repeatText(a, "w", 1000));
    const large = try iterationWork("\\w+X|\\w", try repeatText(a, "w", 2000));
    try testing.expectEqual(@as(usize, 1000), small.matches);
    try testing.expect(large.work >= 3 * small.work and large.work <= 5 * small.work);
}

// The strategies.

test "a pattern whose every match ends at the haystack's end is read back from there, and never forward" {
    const Strategy = @import("strategy.zig").Strategy;
    const chosen = [_]struct { pattern: []const u8, syntax: Syntax = .{}, want: Strategy }{
        .{ .pattern = "\\w+\\z", .want = .reverse_anchored },
        .{ .pattern = "a$|b\\z", .want = .reverse_anchored },
        .{ .pattern = "a$", .syntax = ecma, .want = .reverse_anchored },
        .{ .pattern = "(?m)a$", .want = .core },
        .{ .pattern = "a$|b", .want = .core },
        .{ .pattern = "^a$", .want = .core },
        .{ .pattern = "a", .want = .core },
    };
    for (chosen) |case| {
        var re = try compiled(case.pattern, case.syntax);
        defer re.deinit();
        errdefer std.debug.print("/{s}/\n", .{case.pattern});
        try testing.expectEqual(case.want, re.strategy);
    }
    var re = try compiled("(\\w+)\\z", .{});
    defer re.deinit();
    // The work is the tail's, whatever comes before it: the states built and the bytes read, each
    // in a cache of its own.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var work: [2]usize = undefined;
    for ([_]usize{ 1000, 4000 }, 0..) |n, i| {
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        const h = try std.mem.concat(arena.allocator(), u8, &.{ try repeatText(arena.allocator(), "ab ", n), "end" });
        try testing.expectEqual(Regex.Span{ .start = h.len - 3, .end = h.len }, re.find(&cache, .of(h)).?);
        try testing.expectEqual(.reverse_anchored, cache.last);
        try testing.expectEqual(0, cache.lazy.?.visited + cache.pike.visited + cache.back.?.explored);
        work[i] = cache.reverse.?.visited;
        var groups: [2]?Regex.Span = undefined;
        try testing.expect(re.captures(&cache, .of(h), &groups));
        try testing.expectEqual(Regex.Span{ .start = h.len - 3, .end = h.len }, groups[1].?);
        // A span short of the end holds no match; anchored, the match starts at the span's start.
        try testing.expectEqual(null, re.find(&cache, .{ .haystack = h, .span = .{ .start = 0, .end = h.len - 1 } }));
        try testing.expectEqual(null, re.find(&cache, .{ .haystack = h, .span = .{ .start = h.len - 4, .end = h.len }, .anchored = true }));
        try testing.expectEqual(Regex.Span{ .start = h.len - 2, .end = h.len }, re.find(&cache, .{ .haystack = h, .span = .{ .start = h.len - 2, .end = h.len }, .anchored = true }).?);
    }
    try testing.expectEqual(work[0], work[1]);
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expect(re.isMatch(&cache, "x end") and !re.isMatch(&cache, "end "));
    // A quit reading back goes on as the core strategy, which says how it went.
    var wide = try compiled("\\Bfoo\\z", .{});
    defer wide.deinit();
    var wide_cache = try wide.cache(gpa);
    defer wide_cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 2, .end = 5 }, wide.find(&wide_cache, .of("\u{e9}foo")).?);
    try testing.expectEqual(.lazy_dfa_fell_back, wide_cache.last);
}

test "captures are the backtracker's over the match alone where the lazy DFAs found it" {
    // Not one-pass: `a` leads two ways.
    var re = try compiled("(a|ab)(c|bcd)?", .{});
    defer re.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var work: [2]usize = undefined;
    for ([_]usize{ 1000, 4000 }, 0..) |n, i| {
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        const h = try std.mem.concat(arena.allocator(), u8, &.{ try repeatText(arena.allocator(), "x", n), "abcd" });
        var groups: [3]?Regex.Span = undefined;
        try testing.expect(re.captures(&cache, .of(h), &groups));
        try testing.expectEqual(.reverse_dfa, cache.last_start);
        try testing.expectEqual(.backtrack, cache.last_slots);
        try testing.expectEqualSlices(?Regex.Span, &.{ .{ .start = n, .end = n + 4 }, .{ .start = n, .end = n + 1 }, .{ .start = n + 1, .end = n + 4 } }, &groups);
        try testing.expectEqual(0, cache.pike.visited);
        work[i] = cache.back.?.explored;
    }
    // The backtracker reads the match, not what comes before it.
    try testing.expectEqual(work[0], work[1]);
}

// The bounded backtracker.

test "the bounded backtracker explores each state and position once, and leaves longer spans and deep stacks to the PikeVM" {
    // Work: at most one exploration per (state, bit, position), whatever the pattern.
    for ([_]struct { pattern: []const u8, syntax: Syntax = .{} }{
        .{ .pattern = "(a*)*b" },
        .{ .pattern = "(a|a)*b" },
        .{ .pattern = "(x+x+)+y" },
        .{ .pattern = "(a*)*b", .syntax = ecma },
    }) |case| {
        var re = try compiled(case.pattern, case.syntax);
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        const fill = case.pattern[1];
        var h: [200]u8 = undefined;
        @memset(&h, fill);
        var slots: [4]?usize = undefined;
        try testing.expectEqual(null, try bounded.search(&re.nfa, &cache.back.?, .of(&h), &slots));
        try testing.expect(cache.back.?.explored <= re.backtracker.?.threads * (h.len + 1));
    }
    // A span longer than the bits hold is the PikeVM's; one that fits, the backtracker's.
    var re = try Regex.compile(gpa, .init("(a|ab)+"), .{ .limits = .{ .backtrack = .literal("4KiB") } });
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    const longest = re.backtracker.?.longest().?;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    var groups: [2]?Regex.Span = undefined;
    const short = try repeatText(a.allocator(), "a", 4);
    try testing.expect(re.captures(&cache, .of(short), &groups));
    try testing.expectEqual(.backtrack, cache.last_slots);
    const long = try repeatText(a.allocator(), "a", longest + 1);
    try testing.expect(re.captures(&cache, .of(long), &groups));
    try testing.expectEqual(.pikevm, cache.last_slots);
    try testing.expectEqual(Regex.Span{ .start = long.len - 1, .end = long.len }, groups[1].?);
    // `(a|ab)*` waits on two alternatives per a: past the stack, the PikeVM answers.
    var deep = try Regex.compile(gpa, .init("(a|ab)*"), .{ .limits = .{ .backtrack = .literal("4KiB") } });
    defer deep.deinit();
    var deep_cache = try deep.cache(gpa);
    defer deep_cache.deinit(gpa);
    const run = try repeatText(a.allocator(), "a", @min(deep.backtracker.?.longest().?, 1000));
    try testing.expect(deep.captures(&deep_cache, .of(run), &groups));
    try testing.expectEqual(.backtrack_fell_back, deep_cache.last_slots);
    try testing.expectEqual(Regex.Span{ .start = run.len - 1, .end = run.len }, groups[1].?);
}

// The one-pass DFA.

test "a one-pass pattern's captures follow one path; a pattern where a byte leads two ways has no one-pass DFA" {
    for ([_]struct { pattern: []const u8, syntax: Syntax = .{}, onepass: bool }{
        .{ .pattern = "(\\w+)-(\\d+)", .onepass = true },
        .{ .pattern = "a+b", .onepass = true },
        .{ .pattern = "(a)(b)?", .onepass = true },
        .{ .pattern = "(?i)([a-z]+)@([a-z]+)\\.com", .onepass = true },
        .{ .pattern = "\\bfoo\\b", .onepass = true },
        .{ .pattern = "(a|ab)", .onepass = false },
        .{ .pattern = "\\ba|a", .onepass = false },
        .{ .pattern = "(a*)*", .onepass = false },
        .{ .pattern = "(\\w+)(\\d+)", .onepass = false },
        // ECMAScript's iterations clear their captures: not a path's alone.
        .{ .pattern = "(a)*", .syntax = ecma, .onepass = false },
        .{ .pattern = "(a)*", .onepass = true },
    }) |case| {
        var re = try compiled(case.pattern, case.syntax);
        defer re.deinit();
        errdefer std.debug.print("/{s}/\n", .{case.pattern});
        try testing.expectEqual(case.onepass, re.engines().onepass);
    }
    // Leftmost-first: greedy, the b is taken over the match; lazy, the match wins.
    for ([_]struct { pattern: []const u8, end: usize }{ .{ .pattern = "ab?", .end = 2 }, .{ .pattern = "ab??", .end = 1 } }) |case| {
        var re = try compiled(case.pattern, .{});
        defer re.deinit();
        var slots: [2]?usize = undefined;
        try testing.expectEqual(case.end, onepass.search(&re.onepass.?, .of("ab"), &slots).?);
    }
    // Through the public engine: the lazy DFAs find the match, the one-pass DFA its groups.
    var re = try compiled("(\\w+)-(\\d+)", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    var groups: [3]?Regex.Span = undefined;
    try testing.expect(re.captures(&cache, .of("id: abc-123!"), &groups));
    try testing.expectEqual(.onepass, cache.last_slots);
    try testing.expectEqualSlices(?Regex.Span, &.{ .{ .start = 4, .end = 11 }, .{ .start = 4, .end = 7 }, .{ .start = 8, .end = 11 } }, &groups);
}

// The prefilters.

const prefilter = @import("prefilter.zig");
const literals = @import("hir/literals.zig");

fn anyPrefilter(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    // Literals over a small alphabet, so they occur; a rare byte among them, so a prefilter is chosen.
    const alphabet_ = "abc\x00\x01xyz";
    var lits: std.ArrayList([]const u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 1, 8)) |_| {
        const lit = try a.alloc(u8, shakedown.gen.intRange(s, usize, 1, 5));
        for (lit) |*b| b.* = alphabet_[shakedown.gen.intRange(s, usize, 0, alphabet_.len - 1)];
        try lits.append(a, lit);
    }
    const seq = try literals.Seq.exactOf(a, lits.items);
    // Teddy where this CPU has its kernel, or Aho-Corasick: both reached.
    const kernel = if (shakedown.gen.boolean(s)) prefilter.teddyKernel() else null;
    var p = try prefilter.chooseWith(case.gpa, &seq, 1 << 20, kernel) orelse return;
    defer p.deinit(case.gpa);
    const h = try a.alloc(u8, shakedown.gen.intRange(s, usize, 0, 80));
    for (h) |*b| b.* = alphabet_[shakedown.gen.intRange(s, usize, 0, alphabet_.len - 1)];
    const start = shakedown.gen.intRange(s, usize, 0, h.len);
    const end = shakedown.gen.intRange(s, usize, start, h.len);
    case.note("{any} in {any} [{d}, {d})", .{ lits.items, h, start, end });
    // A plain scan: the first position where a literal starts (bytes) or is whole (pair).
    var want: ?usize = null;
    var at = start;
    scan: while (at < end) : (at += 1) for (lits.items) |lit| switch (p) {
        .bytes => if (h[at] == lit[0]) {
            want = at;
            break :scan;
        },
        .pair, .aho, .teddy => if (at + lit.len <= end and std.mem.eql(u8, h[at..][0..lit.len], lit)) {
            want = at;
            break :scan;
        },
    };
    try testing.expectEqual(want, p.find(h, start, end));
    reached_prefilter[@intFromEnum(p)] += 1;
}

var reached_prefilter: [4]usize = .{ 0, 0, 0, 0 };

test "fuzz: a prefilter finds the first place a literal starts, as a plain scan does" {
    reached_prefilter = .{ 0, 0, 0, 0 };
    try shakedown.check(gpa, {}, anyPrefilter, .{ .cases = 6000, .seed = 0x9fe });
    errdefer std.debug.print("{any}\n", .{reached_prefilter});
    try testing.expect(reached_prefilter[0] > 300 and reached_prefilter[1] > 300 and reached_prefilter[2] > 300);
    // Teddy where this CPU has a kernel for it.
    if (prefilter.teddyKernel() != null) try testing.expect(reached_prefilter[3] > 300);
}

test "a prefilter skips what cannot start a match, the literal strategy answers alone, and one that stops every few bytes is set aside" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // `needle\d+` over text: the lazy DFA reads a few bytes per candidate, not the haystack.
    const h = try std.mem.concat(a, u8, &.{ try repeatText(a, "a quiet line of text, no match here. ", 400), "needle42" });
    var re = try compiled("needle\\d+", .{});
    defer re.deinit();
    try testing.expect(re.engines().prefilter);
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = h.len - 8, .end = h.len }, re.find(&cache, .of(h)).?);
    try testing.expectEqual(.lazy_dfa, cache.last);
    try testing.expect(cache.lazy.?.candidates >= 1 and cache.lazy.?.skipped >= h.len - 8 - 64);
    var off = try Regex.compile(gpa, .init("needle\\d+"), .{ .prefilter = false });
    defer off.deinit();
    var off_cache = try off.cache(gpa);
    defer off_cache.deinit(gpa);
    try testing.expectEqual(re.find(&cache, .of(h)), off.find(&off_cache, .of(h)));
    try testing.expect(cache.lazy.?.visited * 10 < off_cache.lazy.?.visited);
    // A literal, and single bytes: the prefilter alone, the leftmost one's.
    for ([_]struct { pattern: []const u8, haystack: []const u8, want: ?Regex.Span }{
        .{ .pattern = "needle", .haystack = "hay needle hay", .want = .{ .start = 4, .end = 10 } },
        .{ .pattern = "(needle)", .haystack = "hay needle", .want = .{ .start = 4, .end = 10 } },
        .{ .pattern = "x|y|z", .haystack = "abzyx", .want = .{ .start = 2, .end = 3 } },
        .{ .pattern = "needle", .haystack = "hay", .want = null },
    }) |case| {
        var lit = try compiled(case.pattern, .{});
        defer lit.deinit();
        var lit_cache = try lit.cache(gpa);
        defer lit_cache.deinit(gpa);
        const Strategy = @import("strategy.zig").Strategy;
        try testing.expectEqual(Strategy.literal, lit.strategy);
        try testing.expectEqual(case.want, lit.find(&lit_cache, .of(case.haystack)));
        try testing.expectEqual(case.want != null, lit.isMatch(&lit_cache, case.haystack));
    }
    // Many literals: Aho-Corasick finds where one starts.
    var many = try compiled("(?:apple|banana|cherry|damson|elder)\\d", .{});
    defer many.deinit();
    if (prefilter.teddyKernel() != null) try testing.expect(many.prefilter.? == .teddy) else try testing.expect(many.prefilter.? == .aho);
    var many_cache = try many.cache(gpa);
    defer many_cache.deinit(gpa);
    const fruit = try std.mem.concat(a, u8, &.{ try repeatText(a, "a quiet line of text. ", 500), "cherry7" });
    try testing.expectEqual(Regex.Span{ .start = fruit.len - 7, .end = fruit.len }, many.find(&many_cache, .of(fruit)).?);
    try testing.expect(many_cache.lazy.?.skipped >= fruit.len - 7 - 64);
    // `\x00y` over zeros: a candidate at every byte, so after sixteen it is set aside.
    var zeros = try compiled("(?-u:\\x00)y", .{});
    defer zeros.deinit();
    var zeros_cache = try zeros.cache(gpa);
    defer zeros_cache.deinit(gpa);
    const z = try a.alloc(u8, 4096);
    @memset(z, 0);
    try testing.expectEqual(null, zeros.find(&zeros_cache, .of(z)));
    try testing.expect(zeros_cache.lazy.?.candidates <= 16);
}

// The reverse suffix strategy.

test "the reverse suffix strategy leads only where the suffix's order is the matches' order" {
    const Strategy = @import("strategy.zig").Strategy;
    for ([_]struct { pattern: []const u8, haystack: []const u8, want: ?Regex.Span, strategy: Strategy }{
        // An earlier-starting match can end past the first z: not taken, and the answer stands.
        .{ .pattern = "[0-9a-q][^x]*zz|bz", .haystack = "abzz", .want = .{ .start = 0, .end = 4 }, .strategy = .core },
        // Q's length is fixed.
        .{ .pattern = "[A-Z][0-9]XYZ", .haystack = "a1XYZ B2XYZ", .want = .{ .start = 6, .end = 11 }, .strategy = .reverse_suffix },
        // Q cannot read X.
        .{ .pattern = "\\d+XYZ", .haystack = "XYZ 12XYZ", .want = .{ .start = 4, .end = 9 }, .strategy = .reverse_suffix },
        // \\s+ ends Q and shares nothing with \\w or the suffix.
        .{ .pattern = "\\w+\\s+Holmes", .haystack = "Mr Sherlock  Holmes", .want = .{ .start = 3, .end = 19 }, .strategy = .reverse_suffix },
        // \\s begins Q and shares nothing with the rest.
        .{ .pattern = "\\s[A-Za-z]{0,12}ing", .haystack = "a thing sing", .want = .{ .start = 1, .end = 7 }, .strategy = .reverse_suffix },
        .{ .pattern = "\\d+XYZ", .haystack = "XYZ", .want = null, .strategy = .reverse_suffix },
    }) |case| {
        var re = try compiled(case.pattern, .{});
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        errdefer std.debug.print("/{s}/ on {s}\n", .{ case.pattern, case.haystack });
        try testing.expectEqual(case.strategy, re.strategy);
        try testing.expectEqual(case.want, re.find(&cache, .of(case.haystack)));
        if (case.strategy == .reverse_suffix and case.want != null) try testing.expectEqual(.reverse_suffix, cache.last);
    }
    // Reading back from one occurrence after another never reads a byte twice: where it would,
    // the core strategy answers.
    var re = try compiled("\\d+XYZ", .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 0, .end = 7 }, re.find(&cache, .of("1234XYZ")).?);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const digits = try std.mem.concat(arena.allocator(), u8, &.{ try repeatText(arena.allocator(), "1", 2000), "XYZXYZ" });
    try testing.expectEqual(Regex.Span{ .start = 0, .end = 2003 }, re.find(&cache, .of(digits)).?);
}

fn anySuffixed(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    // Q then a literal: some proofs hold, some do not, and the strategy is checked either way.
    const qs = [_][]const u8{ "[0-9a-q]", "[^x]*", "\\w+", "\\s+", "\\d", "[a-z]{2}", "zz", "b", "(?:ab|cd)", "[A-Z]?", "x+", "\\s" };
    const ls = [_][]const u8{ "zz", "XYZ", "ab", "z", "bz", "x" };
    var out: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 1, 2)) |alt| {
        if (alt > 0) try out.append(a, '|');
        for (0..shakedown.gen.intRange(s, usize, 1, 3)) |_| try out.appendSlice(a, qs[shakedown.gen.intRange(s, usize, 0, qs.len - 1)]);
        try out.appendSlice(a, ls[shakedown.gen.intRange(s, usize, 0, ls.len - 1)]);
    }
    var h: std.ArrayList(u8) = .empty;
    const bits = [_][]const u8{ "a", "b", "z", "zz", "x", "XYZ", " ", "1", "q", "cd" };
    for (0..shakedown.gen.intRange(s, usize, 0, 12)) |_| try h.appendSlice(a, bits[shakedown.gen.intRange(s, usize, 0, bits.len - 1)]);
    case.note("/{s}/ on {s}", .{ out.items, h.items });
    var re = Regex.compile(case.gpa, .init(out.items), .{}) catch return;
    defer re.deinit();
    var alone = try Regex.compile(case.gpa, .init(out.items), .{ .limits = .{ .lazy_dfa = .fromRaw(0), .backtrack = .fromRaw(0), .onepass = .fromRaw(0) }, .prefilter = false });
    defer alone.deinit();
    var cache = try re.cache(case.gpa);
    defer cache.deinit(case.gpa);
    var alone_cache = try alone.cache(case.gpa);
    defer alone_cache.deinit(case.gpa);
    const lo = shakedown.gen.intRange(s, usize, 0, h.items.len);
    const input: Regex.Input = .{ .haystack = h.items, .span = .{ .start = lo, .end = h.items.len } };
    try testing.expectEqual(alone.find(&alone_cache, input), re.find(&cache, input));
    if (re.strategy == .reverse_suffix) suffixed.taken += 1 else suffixed.refused += 1;
}

var suffixed: struct { taken: usize = 0, refused: usize = 0 } = .{};

test "fuzz: the reverse suffix strategy finds what the PikeVM finds, where it leads and where it is refused" {
    suffixed = .{};
    try shakedown.check(gpa, {}, anySuffixed, .{ .cases = 4000, .seed = 0x5ff });
    errdefer std.debug.print("{any}\n", .{suffixed});
    try testing.expect(suffixed.taken > 500 and suffixed.refused > 500);
}

// The reverse inner strategy.

test "the reverse inner strategy leads only where the inner literals' order is the matches' order" {
    const Strategy = @import("strategy.zig").Strategy;
    for ([_]struct { pattern: []const u8, haystack: []const u8, want: ?Regex.Span, strategy: Strategy }{
        // \w reads no @: the occurrence cannot lie inside an earlier match's \w+. (With a
        // literal end, `\w+@\w+\.com`, the reverse suffix strategy leads instead.)
        .{ .pattern = "\\w+@\\w+", .haystack = "mail me: ann@example or", .want = .{ .start = 9, .end = 20 }, .strategy = .reverse_inner },
        .{ .pattern = "\\w+@\\w+", .haystack = "a@ @b", .want = null, .strategy = .reverse_inner },
        // P is one alternation that reads z: nothing proves it, so not taken.
        .{ .pattern = "(?:[0-9a-q][^x]*z|b)z+", .haystack = "abzz", .want = .{ .start = 0, .end = 4 }, .strategy = .core },
    }) |case| {
        var re = try compiled(case.pattern, .{});
        defer re.deinit();
        var cache = try re.cache(gpa);
        defer cache.deinit(gpa);
        errdefer std.debug.print("/{s}/ on {s}\n", .{ case.pattern, case.haystack });
        try testing.expectEqual(case.strategy, re.strategy);
        try testing.expectEqual(case.want, re.find(&cache, .of(case.haystack)));
        if (case.strategy == .reverse_inner and case.want != null) try testing.expectEqual(.reverse_inner, cache.last);
    }
}

fn anyInner(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    // P, an inner literal, and what follows: some proofs hold, some do not.
    const ps = [_][]const u8{ "[0-9a-q]", "[^x]*", "\\w+", "\\s+", "\\d", "[a-z]{2}", "b", "(?:ab|cd)", "x+", "\\s", "(?:a|bz)" };
    const ls = [_][]const u8{ "@", "zz", "XY", "z", "-" };
    const xs = [_][]const u8{ "", "\\w+", "\\d*", "[a-z]", "(?:q|zz)" };
    var out: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 1, 3)) |_| try out.appendSlice(a, ps[shakedown.gen.intRange(s, usize, 0, ps.len - 1)]);
    try out.appendSlice(a, ls[shakedown.gen.intRange(s, usize, 0, ls.len - 1)]);
    try out.appendSlice(a, xs[shakedown.gen.intRange(s, usize, 0, xs.len - 1)]);
    var h: std.ArrayList(u8) = .empty;
    const bits = [_][]const u8{ "a", "b", "z", "zz", "x", "XY", " ", "1", "q", "cd", "@", "-" };
    for (0..shakedown.gen.intRange(s, usize, 0, 14)) |_| try h.appendSlice(a, bits[shakedown.gen.intRange(s, usize, 0, bits.len - 1)]);
    case.note("/{s}/ on {s}", .{ out.items, h.items });
    var re = Regex.compile(case.gpa, .init(out.items), .{}) catch return;
    defer re.deinit();
    var alone = try Regex.compile(case.gpa, .init(out.items), .{ .limits = .{ .lazy_dfa = .fromRaw(0), .backtrack = .fromRaw(0), .onepass = .fromRaw(0) }, .prefilter = false });
    defer alone.deinit();
    var cache = try re.cache(case.gpa);
    defer cache.deinit(case.gpa);
    var alone_cache = try alone.cache(case.gpa);
    defer alone_cache.deinit(case.gpa);
    const lo = shakedown.gen.intRange(s, usize, 0, h.items.len);
    const input: Regex.Input = .{ .haystack = h.items, .span = .{ .start = lo, .end = h.items.len } };
    try testing.expectEqual(alone.find(&alone_cache, input), re.find(&cache, input));
    if (re.strategy == .reverse_inner) inner_reached.taken += 1 else inner_reached.refused += 1;
}

var inner_reached: struct { taken: usize = 0, refused: usize = 0 } = .{};

test "fuzz: the reverse inner strategy finds what the PikeVM finds, where it leads and where it is refused" {
    inner_reached = .{};
    try shakedown.check(gpa, {}, anyInner, .{ .cases = 4000, .seed = 0x1a3e });
    errdefer std.debug.print("{any}\n", .{inner_reached});
    try testing.expect(inner_reached.taken > 500 and inner_reached.refused > 500);
}
