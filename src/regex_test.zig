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
    var re = Regex.compile(case.gpa, .init(pattern), .{ .syntax = syntax, .limits = .{ .lazy_dfa = .fromRaw(store) } }) catch |err| switch (err) {
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
    // The lazy DFA finds the same end, or quits or gives up; with `earliest`, whether one exists.
    if (re.dfa) |*d| {
        if (lazy.search(&re.nfa, d, &cache.lazy.?, input)) |ended| try testing.expectEqual(want_end, ended) else |_| {}
        if (lazy.search(&re.nfa, d, &cache.lazy.?, earliest)) |any| try testing.expectEqual(want_end != null, any != null) else |_| {}
    }
    // And the public engine, on whichever path it takes.
    if (re.find(&cache, input)) |m| {
        try testing.expectEqual(want_end, m.end);
        try testing.expectEqual(want[0], m.start);
    } else try testing.expectEqual(null, want_end);
}

test "fuzz: the PikeVM's match and captures are the backtracker's" {
    try shakedown.check(gpa, {}, anyAgreement, .{ .cases = 5000, .seed = 0x91e });
}

// The lazy DFA against the PikeVM.

/// What the fuzz below reached, so a change that stops it reaching them shows.
var reached: struct { answered: usize = 0, cleared: usize = 0, gave_up: usize = 0, quit: usize = 0, checked: usize = 0 } = .{};

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
        const want = pikevm.search(&re.nfa, &cache.pike, input, &.{});
        if (lazy.search(&re.nfa, d, &cache.lazy.?, input)) |got| {
            try testing.expectEqual(want, got);
            reached.answered += 1;
            if (re.nfa.loop_checks) reached.checked += 1;
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
    return .{ .visited = cache.pike.visited + cache.lazy.?.visited, .threads = pikevm.sizes(&re.nfa).threads };
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
    var alone = try Regex.compile(gpa, .init(pattern), .{ .limits = .{ .lazy_dfa = .fromRaw(0) } });
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

test "a look that needs more than a byte quits the lazy DFA on a byte past 0x7f, and the PikeVM answers" {
    const cases = [_]struct { pattern: []const u8, syntax: Syntax = .{}, ascii: []const u8, wide: []const u8, want: [2]Regex.Span }{
        .{ .pattern = "\\bb\\b", .ascii = "a b c", .wide = "\u{e9} b c", .want = .{ .{ .start = 2, .end = 3 }, .{ .start = 3, .end = 4 } } },
        .{ .pattern = "^b", .syntax = .{ .dialect = .ecmascript, .multi_line = true }, .ascii = "a\nb", .wide = "a\u{2028}b", .want = .{ .{ .start = 2, .end = 3 }, .{ .start = 4, .end = 5 } } },
    };
    for (cases) |case| {
        var re = try compiled(case.pattern, case.syntax);
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
    try testing.expectEqual(Regex.Engines{ .lazy_dfa = false }, re.engines());
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 1, .end = 4 }, re.find(&cache, .of("xaab")).?);
    try testing.expectEqual(.pikevm, cache.last);
    var roomy = try Regex.compile(gpa, .init("a+b"), .{});
    defer roomy.deinit();
    try testing.expectEqual(Regex.Engines{ .lazy_dfa = true }, roomy.engines());
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
        total.work += cache.pike.visited + if (cache.lazy) |l| l.visited else 0;
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
