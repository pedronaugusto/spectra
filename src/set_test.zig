//! Sets: each pattern's own answer is its bit in `matches`, `first` is the leftmost-first match of
//! the patterns as one alternation, and a whole search counts only a match covering the span.
const std = @import("std");
const shakedown = @import("shakedown");
const Regex = @import("Regex.zig");
const Set = @import("Set.zig");
const Syntax = @import("Syntax.zig");
const grammar = @import("testing/grammar.zig");
const testing = std.testing;
const fuzzing = @import("builtin").fuzz;
const gpa = testing.allocator;

fn untrusted(comptime patterns: []const []const u8) [patterns.len]@import("aegis").input.Untrusted([]const u8) {
    var out: [patterns.len]@import("aegis").input.Untrusted([]const u8) = undefined;
    for (patterns, &out) |p, *o| o.* = .init(p);
    return out;
}

test "a set says which patterns match, whether any does, and the leftmost-first match with its pattern" {
    const patterns = untrusted(&.{ "a+", "b", "(?i)C", "z" });
    var set = try Set.compile(gpa, &patterns, .{});
    defer set.deinit();
    try testing.expectEqual(4, set.len());
    var cache = try set.cache(gpa);
    defer cache.deinit(gpa);
    var out = try set.patterns(gpa);
    defer out.deinit(gpa);

    try testing.expect(try set.matches(&cache, .of("xbaac"), &out));
    try testing.expectEqual(3, out.count());
    try testing.expect(out.contains(@fromBackingInt(0)) and out.contains(@fromBackingInt(1)) and out.contains(@fromBackingInt(2)));
    try testing.expect(!out.contains(@fromBackingInt(3)));
    try testing.expectEqual(0, out.first().?.raw());
    try testing.expectEqual(2, out.last().?.raw());
    var it = out.iterator();
    var seen: usize = 0;
    while (it.next()) |p| : (seen += 1) try testing.expect(p.raw() < 3);
    try testing.expectEqual(3, seen);

    try testing.expect(try set.isMatch(&cache, .of("xbaac")));
    try testing.expect(!try set.isMatch(&cache, .of("xyw")));
    try testing.expect(!try set.matches(&cache, .of("xyw"), &out));
    try testing.expectEqual(0, out.count());

    // Leftmost first: "b" at 1 comes before "a+" at 2, whatever their order in the set.
    const m = (try set.first(&cache, .of("xbaac"))).?;
    try testing.expectEqual(Set.Span{ .start = 1, .end = 2 }, m.span);
    try testing.expectEqual(1, set.pattern(m).raw());
    // At one start, the earlier pattern is preferred, as in an alternation.
    const both = untrusted(&.{ "ab", "a" });
    var pair = try Set.compile(gpa, &both, .{});
    defer pair.deinit();
    var pair_cache = try pair.cache(gpa);
    defer pair_cache.deinit(gpa);
    const ab = (try pair.first(&pair_cache, .of("ab"))).?;
    try testing.expectEqual(0, pair.pattern(ab).raw());
    try testing.expectEqual(Set.Span{ .start = 0, .end = 2 }, ab.span);
}

test "a whole search counts only a match that covers the span" {
    const patterns = untrusted(&.{ "a", "ab", "a|ab", "b*" });
    var set = try Set.compile(gpa, &patterns, .{});
    defer set.deinit();
    var cache = try set.cache(gpa);
    defer cache.deinit(gpa);
    var out = try set.patterns(gpa);
    defer out.deinit(gpa);
    const whole: Set.Input = .{ .haystack = "ab", .span = .{ .start = 0, .end = 2 }, .whole = true };
    try testing.expect(try set.matches(&cache, whole, &out));
    // "a|ab" covers "ab" by its second branch, though leftmost-first prefers the first.
    try testing.expect(!out.contains(@fromBackingInt(0)) and out.contains(@fromBackingInt(1)) and out.contains(@fromBackingInt(2)) and !out.contains(@fromBackingInt(3)));
    try testing.expectEqual(Set.Cache.Path.lazy_dfa, cache.last);
    const m = (try set.first(&cache, whole)).?;
    try testing.expectEqual(1, set.pattern(m).raw());
    try testing.expectEqual(Set.Span{ .start = 0, .end = 2 }, m.span);
    // Regex's whole search agrees.
    var re = try Regex.compile(gpa, .init("a|ab"), .{});
    defer re.deinit();
    var rc = try re.cache(gpa);
    defer rc.deinit(gpa);
    try testing.expectEqual(Regex.Span{ .start = 0, .end = 2 }, (try re.find(&rc, whole)).?);
    try testing.expectEqual(Regex.Cache.Path.whole, rc.last);
    try testing.expectEqual(null, try re.find(&rc, .{ .haystack = "abc", .span = .{ .start = 0, .end = 3 }, .whole = true }));
}

test "a refused pattern is named by its index, and a set too large names none" {
    var diagnostic: Regex.Diagnostic = .{};
    const patterns = untrusted(&.{ "a", "(b", "c" });
    try testing.expectError(error.Invalid, Set.compile(gpa, &patterns, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(1, diagnostic.pattern.?);
    try testing.expectEqual(.unclosed_group, diagnostic.reason);

    var big: Regex.Diagnostic = .{};
    const many = untrusted(&.{ "\\pL{100}", "\\pL{100}" });
    try testing.expectError(error.TooLarge, Set.compile(gpa, &many, .{ .diagnostic = &big, .limits = .{ .nfa = .literal("64KiB") } }));
    try testing.expectEqual(null, big.pattern);
}

// Random sets against each pattern alone and against their alternation.

var reached: struct {
    sets: usize = 0,
    matched: usize = 0,
    firsts: usize = 0,
    wholes: usize = 0,
    ecma: usize = 0,
    /// Searches each path answered, over the three ways each set is compiled.
    lazy_dfa: usize = 0,
    fell_back: usize = 0,
    pikevm: usize = 0,
} = .{};

fn countPath(path: Set.Cache.Path) void {
    switch (path) {
        .lazy_dfa => reached.lazy_dfa += 1,
        .lazy_dfa_fell_back => reached.fell_back += 1,
        .pikevm => reached.pikevm += 1,
    }
}

/// The same set with the lazy DFAs in a store of the fewest states, which clears and gives up,
/// and with none, the PikeVM alone: every answer the same.
fn sameOnEveryPath(a: std.mem.Allocator, patterns: []const @import("aegis").input.Untrusted([]const u8), syntax: Syntax, haystack: []const u8, want: *const Set.Patterns, want_whole: *const Set.Patterns, want_first: ?Set.Match, first_index: ?u32) !void {
    // A longer haystack, the case's repeated, so the small store clears and gives up: its answers
    // are the PikeVM's alone (`store` 0, run first).
    var long: std.ArrayList(u8) = .empty;
    for (0..40) |_| try long.appendSlice(a, haystack);
    var long_want: ?std.DynamicBitSetUnmanaged = null;
    defer if (long_want) |*w| w.deinit(gpa);
    for ([_]usize{ 0, 1200 }) |store| {
        var set = Set.compile(gpa, patterns, .{ .syntax = syntax, .limits = .{ .lazy_dfa = .fromRaw(store) } }) catch |err| switch (err) {
            error.TooLarge => continue,
            else => return err,
        };
        defer set.deinit();
        var cache = try set.cache(gpa);
        defer cache.deinit(gpa);
        var out = try set.patterns(gpa);
        defer out.deinit(gpa);
        _ = try set.matches(&cache, .of(haystack), &out);
        countPath(cache.last);
        try testing.expect(out.bits.eql(want.bits));
        const whole: Set.Input = .{ .haystack = haystack, .span = .{ .start = 0, .end = haystack.len }, .whole = true };
        _ = try set.matches(&cache, whole, &out);
        countPath(cache.last);
        try testing.expect(out.bits.eql(want_whole.bits));
        const m = try set.first(&cache, .of(haystack));
        countPath(cache.last);
        try testing.expectEqual(want_first == null, m == null);
        if (m) |got| {
            try testing.expectEqual(want_first.?.span, got.span);
            try testing.expectEqual(first_index.?, set.pattern(got).raw());
        }
        try testing.expectEqual(want.count() > 0, try set.isMatch(&cache, .of(haystack)));
        countPath(cache.last);
        _ = try set.matches(&cache, .of(long.items), &out);
        countPath(cache.last);
        if (long_want) |w| try testing.expect(out.bits.eql(w)) else long_want = try out.bits.clone(gpa);
    }
}

fn anySet(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    const syntax: Syntax = if (shakedown.gen.boolean(s)) .{} else .{ .dialect = .ecmascript };
    const n = shakedown.gen.intRange(s, usize, 1, 4);
    const texts = try a.alloc([]const u8, n);
    const patterns = try a.alloc(@import("aegis").input.Untrusted([]const u8), n);
    for (texts, patterns) |*t, *p| {
        var out: std.ArrayList(u8) = .empty;
        try grammar.write(s, &out, a, 3);
        t.* = out.items;
        p.* = .init(t.*);
    }
    var hay: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 0, 8)) |_| try hay.append(a, "ab "[shakedown.gen.intRange(s, usize, 0, 2)]);
    const haystack = hay.items;

    var set = Set.compile(case.gpa, patterns, .{ .syntax = syntax }) catch |err| switch (err) {
        error.TooLarge => return,
        else => return err,
    };
    defer set.deinit();
    var cache = try set.cache(case.gpa);
    defer cache.deinit(case.gpa);
    var out = try set.patterns(case.gpa);
    defer out.deinit(case.gpa);
    var whole_out = try set.patterns(case.gpa);
    defer whole_out.deinit(case.gpa);
    const whole: Set.Input = .{ .haystack = haystack, .span = .{ .start = 0, .end = haystack.len }, .whole = true };
    const any = try set.matches(&cache, .of(haystack), &out);
    countPath(cache.last);
    _ = try set.matches(&cache, whole, &whole_out);
    countPath(cache.last);
    try testing.expectEqual(any, try set.isMatch(&cache, .of(haystack)));
    const set_first = try set.first(&cache, .of(haystack));
    countPath(cache.last);
    try sameOnEveryPath(a, patterns, syntax, haystack, &out, &whole_out, set_first, if (set_first) |m| set.pattern(m).raw() else null);
    reached.sets += 1;
    if (syntax.dialect == .ecmascript) reached.ecma += 1;
    if (any) reached.matched += 1;

    // Each pattern alone: its bit, and its whole bit.
    var top = try a.alloc(u32, n);
    var group: u32 = 1;
    for (texts, 0..) |text, i| {
        var re = try Regex.compile(case.gpa, .init(text), .{ .syntax = syntax });
        defer re.deinit();
        var rc = try re.cache(case.gpa);
        defer rc.deinit(case.gpa);
        const pattern: Set.Pattern = @fromBackingInt(@as(u32, @intCast(i)));
        try testing.expectEqual(try re.isMatch(&rc, haystack), out.contains(pattern));
        const covers = (try re.find(&rc, whole)) != null;
        try testing.expectEqual(covers, whole_out.contains(pattern));
        if (covers) reached.wholes += 1;
        top[i] = group;
        group += re.captureCount();
    }

    // The alternation, each pattern in a group of its own: the group that took part is the
    // pattern `first` names, and the match is the same.
    var alt: std.ArrayList(u8) = .empty;
    for (texts, 0..) |text, i| {
        if (i > 0) try alt.append(a, '|');
        try alt.append(a, '(');
        try alt.appendSlice(a, text);
        try alt.append(a, ')');
    }
    var re = try Regex.compile(case.gpa, .init(alt.items), .{ .syntax = syntax });
    defer re.deinit();
    var rc = try re.cache(case.gpa);
    defer rc.deinit(case.gpa);
    const groups = try a.alloc(?Regex.Span, re.captureCount());
    const found = try set.first(&cache, .of(haystack));
    if (!try re.captures(&rc, .of(haystack), groups)) {
        try testing.expectEqual(null, found);
        return;
    }
    const m = found.?;
    try testing.expectEqual(groups[0].?, m.span);
    const index = set.pattern(m).raw();
    try testing.expect(groups[top[index]] != null);
    for (top[0..index]) |g| try testing.expectEqual(null, groups[g]);
    reached.firsts += 1;
}

test "fuzz: a set's matches are each pattern's own, and its first is the alternation's leftmost-first match" {
    reached = .{};
    try shakedown.check(gpa, {}, anySet, .{ .cases = 3000, .seed = 0x5e7 });
    if (fuzzing) return;
    errdefer std.debug.print("{any}\n", .{reached});
    try testing.expect(reached.sets > 2500 and reached.matched > 1000 and reached.firsts > 1000 and reached.wholes > 300 and reached.ecma > 1000);
    try testing.expect(reached.lazy_dfa > 5000 and reached.fell_back > 50 and reached.pikevm > 5000);
}
