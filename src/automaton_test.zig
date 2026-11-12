//! The stepping automaton: a walk asks what a whole search asks, a dead state has no match ahead,
//! and the recipe for `Stale` and `GaveUp` (Automaton.zig's doc) keeps a walker's answers those of
//! an unbounded store.
const std = @import("std");
const shakedown = @import("shakedown");
const Regex = @import("Regex.zig");
const Set = @import("Set.zig");
const Automaton = @import("Automaton.zig");
const Syntax = @import("Syntax.zig");
const grammar = @import("testing/grammar.zig");
const testing = std.testing;
const fuzzing = @import("builtin").fuzz;
const gpa = testing.allocator;

/// Whether `path` matches whole: what `isMatch(stepEnd(state))` answers.
fn matchesWhole(re: *const Regex, c: *Regex.Cache, path: []const u8) !bool {
    return (try re.find(c, .{ .haystack = path, .span = .{ .start = 0, .end = path.len }, .whole = true })) != null;
}

test "a walk asks whether the bytes so far match, keeping the longer alternatives" {
    var re = try Regex.compile(gpa, .init("a|ab"), .{});
    defer re.deinit();
    const a = re.automaton().?;
    var c = try a.cache(gpa);
    defer c.deinit(gpa);
    var s = try a.start(&c, .{});
    try testing.expect(!Automaton.isMatch(try a.stepEnd(&c, s)));
    s = try a.step(&c, s, 'a');
    try testing.expect(Automaton.isMatch(try a.stepEnd(&c, s)));
    s = try a.step(&c, s, 'b');
    // Leftmost-first would have dropped `ab` once `a` matched.
    try testing.expect(Automaton.isMatch(try a.stepEnd(&c, s)));
    // A match is seen one byte late: "ab" ended where 'c' began.
    s = try a.step(&c, s, 'c');
    try testing.expect(Automaton.isMatch(s));
    try testing.expect(Automaton.isDead(s));
    try testing.expect(!Automaton.isMatch(try a.stepEnd(&c, s)));

    // Looks at the end are decided by `stepEnd`.
    var end = try Regex.compile(gpa, .init("(?-u)foo\\b"), .{});
    defer end.deinit();
    const e = end.automaton().?;
    var ec = try e.cache(gpa);
    defer ec.deinit(gpa);
    var t = try e.start(&ec, .{});
    for ("foo") |b| t = try e.step(&ec, t, b);
    try testing.expect(Automaton.isMatch(try e.stepEnd(&ec, t)));
    try testing.expect(!Automaton.isMatch(try e.step(&ec, try e.step(&ec, t, 'x'), 'y')));

    // A Unicode word boundary reads more than one byte: no automaton.
    var wide = try Regex.compile(gpa, .init("\\bx"), .{});
    defer wide.deinit();
    try testing.expectEqual(null, wide.automaton());
}

test "a set's walk says which patterns match" {
    const sources = [_]@import("aegis").input.Untrusted([]const u8){ .init("a*"), .init("ab"), .init("b") };
    var set = try Set.compile(gpa, &sources, .{});
    defer set.deinit();
    const a = set.automaton().?;
    var c = try a.cache(gpa);
    defer c.deinit(gpa);
    var s = try a.start(&c, .{});
    s = try a.step(&c, s, 'a');
    s = try a.step(&c, s, 'b');
    const end = try a.stepEnd(&c, s);
    try testing.expectEqualSlices(u32, &.{1}, a.patterns(&c, end));
    const at_start = try a.stepEnd(&c, try a.start(&c, .{}));
    try testing.expectEqualSlices(u32, &.{0}, a.patterns(&c, at_start));
}

// Random walks against whole searches.

var walked: struct { prefixes: usize = 0, matched: usize = 0, dead: usize = 0, extensions: usize = 0, ecma: usize = 0 } = .{};

fn anyWalk(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    // ASCII word boundaries, so the automaton exists; bytes, so `.` may take any.
    const syntax: Syntax = if (shakedown.gen.boolean(s)) .{ .unicode = false, .utf8 = false } else .{ .dialect = .ecmascript };
    var text: std.ArrayList(u8) = .empty;
    try grammar.write(s, &text, a, 3);
    var re = Regex.compile(case.gpa, .init(text.items), .{ .syntax = syntax }) catch |err| switch (err) {
        error.TooLarge => return,
        else => return err,
    };
    defer re.deinit();
    const auto = re.automaton() orelse return;
    var rc = try re.cache(case.gpa);
    defer rc.deinit(case.gpa);
    var c = try auto.cache(case.gpa);
    defer c.deinit(case.gpa);
    if (syntax.dialect == .ecmascript) walked.ecma += 1;
    var path: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 0, 8)) |_| try path.append(a, "ab "[shakedown.gen.intRange(s, usize, 0, 2)]);
    var st = try auto.start(&c, .{});
    for (0..path.items.len + 1) |k| {
        if (k > 0) st = try auto.step(&c, st, path.items[k - 1]);
        const prefix = path.items[0..k];
        const got = Automaton.isMatch(try auto.stepEnd(&c, st));
        try testing.expectEqual(try matchesWhole(&re, &rc, prefix), got);
        walked.prefixes += 1;
        if (got) walked.matched += 1;
        // A dead state: no extension matches.
        if (Automaton.isDead(st)) {
            walked.dead += 1;
            for (0..4) |_| {
                var longer: std.ArrayList(u8) = .empty;
                try longer.appendSlice(a, prefix);
                for (0..shakedown.gen.intRange(s, usize, 1, 4)) |_| try longer.append(a, "ab "[shakedown.gen.intRange(s, usize, 0, 2)]);
                try testing.expect(!try matchesWhole(&re, &rc, longer.items));
                walked.extensions += 1;
            }
        }
    }
}

test "fuzz: a walk with stepEnd at every prefix answers what a whole search answers, and a dead state has no match ahead" {
    walked = .{};
    try shakedown.check(gpa, {}, anyWalk, .{ .cases = 3000, .seed = 0xa70 });
    if (fuzzing) return;
    errdefer std.debug.print("{any}\n", .{walked});
    try testing.expect(walked.prefixes > 10000 and walked.matched > 3000 and walked.dead > 500 and walked.extensions > 2000 and walked.ecma > 1000);
}

// The recipe, driven: a walker over a trie of words that keeps a state per byte of the path it
// stands on, in a store of the fewest states, against a walker on an unbounded store.

const Walker = struct {
    auto: Automaton,
    cache: *Automaton.Cache,
    re: *const Regex,
    rc: *Regex.Cache,
    /// The state at each point of the path: `states[0]` the start, `states[k]` after `path[k-1]`.
    states: std.ArrayList(Automaton.State) = .empty,
    path: std.ArrayList(u8) = .empty,
    /// Bytes the walk stepped, and bytes its re-walks read.
    stepped: usize = 0,
    rewalked: usize = 0,
    /// The walk does not fit the store: answered by the searches from here on.
    searching: bool = false,
    stales: usize = 0,
    gave_up: usize = 0,

    fn begin(w: *Walker, a: std.mem.Allocator) !void {
        try w.states.append(a, w.auto.start(w.cache, .{}) catch |err| return w.fail(err));
    }

    fn fail(w: *Walker, err: Automaton.StepError) void {
        switch (err) {
            error.Stale => w.stales += 1,
            error.GaveUp => w.gave_up += 1,
        }
        w.searching = true;
    }

    /// Recipe 1: re-walk the path from `start`; past ten times the bytes stepped, or stale or given
    /// up again, recipe 2.
    fn rewalk(w: *Walker) void {
        w.stales += 1;
        w.rewalked += w.path.items.len;
        if (w.rewalked > 10 * w.stepped) {
            w.searching = true;
            return;
        }
        w.states.items[0] = w.auto.start(w.cache, .{}) catch |err| return w.fail(err);
        for (w.path.items, 1..) |b, k| {
            w.states.items[k] = w.auto.step(w.cache, w.states.items[k - 1], b) catch |err| return w.fail(err);
        }
    }

    fn push(w: *Walker, a: std.mem.Allocator, b: u8) !void {
        try w.path.append(a, b);
        w.stepped += 1;
        if (w.searching) return;
        const top = w.states.items[w.states.items.len - 1];
        const next = w.auto.step(w.cache, top, b) catch |err| retry: {
            if (err == error.GaveUp) return w.fail(err);
            w.path.items.len -= 1;
            w.rewalk();
            w.path.items.len += 1;
            if (w.searching) return;
            break :retry w.auto.step(w.cache, w.states.items[w.states.items.len - 1], b) catch |again| return w.fail(again);
        };
        try w.states.append(a, next);
    }

    fn pop(w: *Walker) void {
        w.path.items.len -= 1;
        if (!w.searching) w.states.items.len -= 1;
    }

    /// Whether the path so far matches: the end transition, or recipe 2's whole search.
    fn matches(w: *Walker) !bool {
        if (!w.searching) found: {
            const end = w.auto.stepEnd(w.cache, w.states.items[w.states.items.len - 1]) catch |err| retry: {
                if (err == error.GaveUp) {
                    w.fail(err);
                    break :found;
                }
                w.rewalk();
                if (w.searching) break :found;
                break :retry w.auto.stepEnd(w.cache, w.states.items[w.states.items.len - 1]) catch |again| {
                    w.fail(again);
                    break :found;
                };
            };
            return Automaton.isMatch(end);
        }
        return matchesWhole(w.re, w.rc, w.path.items);
    }
};

/// The answer for each word, in order, walked as a trie: down from the common prefix with the
/// word before.
fn walkWords(a: std.mem.Allocator, re: *const Regex, store: usize, words: []const []const u8, out: []bool, w_out: *Walker) !void {
    _ = store;
    var rc = try re.cache(gpa);
    defer rc.deinit(gpa);
    const auto = re.automaton().?;
    var c = try auto.cache(gpa);
    defer c.deinit(gpa);
    var w: Walker = .{ .auto = auto, .cache = &c, .re = re, .rc = &rc };
    try w.begin(a);
    var prev: []const u8 = "";
    for (words, out) |word, *answer| {
        const common = std.mem.indexOfDiff(u8, prev, word) orelse @min(prev.len, word.len);
        while (w.path.items.len > common) w.pop();
        for (word[common..]) |b| try w.push(a, b);
        answer.* = try w.matches();
        prev = word;
    }
    w_out.* = w;
    w_out.states = .empty;
    w_out.path = .empty;
}

test "the recipe for Stale and GaveUp keeps a walker's answers those of an unbounded store" {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7a1c);
    const random = prng.random();
    // The DFA of `(a|b)*a(a|b){5}` needs 2^6 states: a store of the fewest clears all along.
    const patterns = [_][]const u8{ "(a|b)*a(a|b){5}", "(?:a|b)*b(?:ab|ba){3}(?:a|b)*" };
    var stales: usize = 0;
    var gave_up: usize = 0;
    for (patterns) |pattern| {
        for ([_]usize{ 40, 300 }) |length| {
            var words: std.ArrayList([]const u8) = .empty;
            for (0..200) |_| {
                const word = try a.alloc(u8, random.uintLessThan(usize, length));
                for (word) |*b| b.* = "ab"[random.uintLessThan(usize, 2)];
                try words.append(a, word);
            }
            std.mem.sort([]const u8, words.items, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.less);
            var big = try Regex.compile(gpa, .init(pattern), .{});
            defer big.deinit();
            var small = try Regex.compile(gpa, .init(pattern), .{ .limits = .{ .lazy_dfa = .literal("2KiB") } });
            defer small.deinit();
            const want = try a.alloc(bool, words.items.len);
            const got = try a.alloc(bool, words.items.len);
            var big_walk: Walker = undefined;
            var small_walk: Walker = undefined;
            try walkWords(a, &big, 0, words.items, want, &big_walk);
            try walkWords(a, &small, 0, words.items, got, &small_walk);
            try testing.expectEqualSlices(bool, want, got);
            // The unbounded store never needs the recipe.
            try testing.expectEqual(0, big_walk.stales + big_walk.gave_up);
            // And each answer is the whole search's.
            var rc = try big.cache(gpa);
            defer rc.deinit(gpa);
            for (words.items, want) |word, answer| try testing.expectEqual(try matchesWhole(&big, &rc, word), answer);
            stales += small_walk.stales;
            gave_up += small_walk.gave_up + @intFromBool(small_walk.searching);
        }
    }
    // Both recoveries were driven.
    errdefer std.debug.print("stales {d}, gave up {d}\n", .{ stales, gave_up });
    try testing.expect(stales >= 5 and gave_up >= 5);
}
