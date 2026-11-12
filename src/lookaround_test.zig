//! Lookaround through the public engine (spectra.md §3.1, the main expression's phase): find,
//! captures, is-match and every match of patterns with lookarounds, against ECMA-262's own
//! matcher (testing/ecma.zig), which evaluates each lookaround afresh wherever a path reaches it;
//! the oracle's limit refused by name before a byte is read; zod's patterns.
const std = @import("std");
const shakedown = @import("shakedown");
const aegis = @import("aegis");
const Regex = @import("Regex.zig");
const Set = @import("Set.zig");
const Syntax = @import("Syntax.zig");
const Ast = @import("syntax/Ast.zig");
const parse_mod = @import("syntax/parse.zig");
const translate_mod = @import("hir/translate.zig");
const spec = @import("testing/ecma.zig");
const grammar = @import("testing/grammar.zig");
const testing = std.testing;
const fuzzing = @import("builtin").fuzz;
const gpa = testing.allocator;

const ecma: Syntax = .{ .dialect = .ecmascript, .unicode = true };

fn span(start: usize, end: usize) ?Regex.Span {
    return .{ .start = start, .end = end };
}

test "lookahead and lookbehind, positive and negative, nested, through every search" {
    const cases = [_]struct { pattern: []const u8, haystack: []const u8, want: ?Regex.Span }{
        .{ .pattern = "a(?=b)", .haystack = "aab", .want = span(1, 2) },
        .{ .pattern = "a(?!b)", .haystack = "aba", .want = span(2, 3) },
        .{ .pattern = "(?<=\\$)\\d+", .haystack = "cost $42", .want = span(6, 8) },
        .{ .pattern = "(?<!\\$)\\b\\d+", .haystack = "$1 and 23", .want = span(7, 9) },
        .{ .pattern = "(?<=a(?=b)b)c", .haystack = "acabc", .want = span(4, 5) },
        .{ .pattern = "(?=a(?<!xa)b)\\w+", .haystack = "xab ab", .want = span(4, 6) },
        .{ .pattern = "(?<=^|,)\\w+(?=,|$)", .haystack = "a,bc,d", .want = span(0, 1) },
        .{ .pattern = "q(?=u)", .haystack = "qatar", .want = null },
        // Unbounded bodies, both ways.
        .{ .pattern = "(?<=a.*)z", .haystack = "zz a z", .want = span(5, 6) },
        .{ .pattern = "\\w(?=.*!$)", .haystack = "ab!", .want = span(0, 1) },
    };
    for (cases) |case| {
        errdefer std.debug.print("/{s}/ on {s}\n", .{ case.pattern, case.haystack });
        var re = try Regex.compile(gpa, .init(case.pattern), .{ .syntax = ecma });
        defer re.deinit();
        var c = try re.cache(gpa);
        defer c.deinit(gpa);
        try testing.expectEqual(case.want, try re.find(&c, .of(case.haystack)));
        try testing.expectEqual(Regex.Cache.Path.lookaround_lazy_dfa, c.last);
        try testing.expectEqual(case.want != null, try re.isMatch(&c, case.haystack));
        try testing.expectEqual(Regex.Cache.Path.lookaround_scan, c.last);
    }
    // Every match in turn: the rows built once for the haystack.
    var re = try Regex.compile(gpa, .init("(?<=,)\\w+"), .{ .syntax = ecma });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    var it = re.findAll(&c, "a,bc,,d");
    try testing.expectEqual(span(2, 4), try it.next());
    try testing.expectEqual(span(6, 7), try it.next());
    try testing.expectEqual(null, try it.next());
}

test "zod's email pattern: every lookahead streams, so is-match stores nothing" {
    const zod = "^(?!\\.)(?!.*\\.\\.)([A-Za-z0-9_'+\\-\\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$";
    var re = try Regex.compile(gpa, .init(zod), .{ .syntax = .{ .dialect = .ecmascript } });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    try testing.expectEqual(null, re.longestHaystack(.is_match));
    try testing.expect(try re.isMatch(&c, "ann.lee@example.com"));
    try testing.expect(!try re.isMatch(&c, ".ann@example.com"));
    try testing.expect(!try re.isMatch(&c, "ann..lee@example.com"));
    try testing.expect(!try re.isMatch(&c, "ann@example"));
    // `find` stores the rows of both lookaheads.
    try testing.expect(re.longestHaystack(.find) != null);
    try testing.expectEqual(span(0, 19), try re.find(&c, .of("ann.lee@example.com")));
}

test "a haystack whose rows pass Limits.oracle is refused by name, before a byte is read" {
    const tiny: @import("Limits.zig") = .{ .oracle = .fromRaw(@sizeOf(usize)) };
    // One stored row of one word: 64 positions, 63 bytes.
    const fits: [@bitSizeOf(usize) - 1]u8 = @splat('a');
    const long: [@bitSizeOf(usize)]u8 = @splat('a');
    var groups: [1]?Regex.Span = undefined;

    // A lookahead is read the other way from find's scan: stored, and refused past the limit.
    var ahead = try Regex.compile(gpa, .init("a(?=b)"), .{ .syntax = ecma, .limits = tiny });
    defer ahead.deinit();
    var ac = try ahead.cache(gpa);
    defer ac.deinit(gpa);
    try testing.expectEqual(@as(?usize, @bitSizeOf(usize) - 1), ahead.longestHaystack(.find));
    try testing.expectEqual(null, try ahead.find(&ac, .of(&fits)));
    try testing.expectError(error.HaystackTooLong, ahead.find(&ac, .of(&long)));
    try testing.expectError(error.HaystackTooLong, ahead.captures(&ac, .of(&long), &groups));
    // Is-match reads backward and streams it: no limit.
    try testing.expectEqual(null, ahead.longestHaystack(.is_match));
    try testing.expect(!try ahead.isMatch(&ac, &long));

    // A lookbehind streams beside find's PikeVM: no limit there; every match in turn stores it.
    var behind = try Regex.compile(gpa, .init("(?<=a)b"), .{ .syntax = ecma, .limits = tiny });
    defer behind.deinit();
    var bc = try behind.cache(gpa);
    defer bc.deinit(gpa);
    try testing.expectEqual(null, behind.longestHaystack(.find));
    try testing.expectEqual(null, behind.longestHaystack(.is_match));
    try testing.expectEqual(@as(?usize, @bitSizeOf(usize) - 1), behind.longestHaystack(.find_all));
    var longer: [@bitSizeOf(usize) + 1]u8 = @splat('a');
    longer[longer.len - 1] = 'b';
    try testing.expectEqual(span(longer.len - 1, longer.len), try behind.find(&bc, .of(&longer)));
    try testing.expect(try behind.captures(&bc, .of(&longer), &groups));
    try testing.expect(try behind.isMatch(&bc, &longer));
    var it = behind.findAll(&bc, &longer);
    try testing.expectError(error.HaystackTooLong, it.next());
}

fn expectGroups(pattern: []const u8, haystack: []const u8, want: []const ?Regex.Span) !void {
    errdefer std.debug.print("/{s}/ on {s}\n", .{ pattern, haystack });
    var re = try Regex.compile(gpa, .init(pattern), .{ .syntax = ecma });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    const groups = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(groups);
    try testing.expect(try re.captures(&c, .of(haystack), groups));
    try testing.expectEqualSlices(?Regex.Span, want, groups);
}

test "a positive lookaround's groups are its first success's, read its way; a negative one's never take part" {
    // /(?=(a+))/.exec("baaabac"): "" at 1, its group the lookahead's greedy first success.
    try expectGroups("(?=(a+))", "baaabac", &.{ span(1, 1), span(1, 4) });
    // Lookbehind reads backward: the second group, read first, takes as much as it can.
    try expectGroups("(?<=(\\d+)(\\d+))$", "1053", &.{ span(4, 4), span(0, 1), span(1, 4) });
    try expectGroups("(?<=\\$(\\d+)\\.)\\d+", "cost $10.99", &.{ span(9, 11), span(6, 8) });
    // Nested both ways: the inner groups rebuilt from the outer run.
    try expectGroups("(?=(a)(?<=(a)))a", "a", &.{ span(0, 1), span(0, 1), span(0, 1) });
    // Inside a quantifier, the last taking defines them; an iteration clears them first.
    try expectGroups("(?:(?=(\\w))\\w)+", "abc", &.{ span(0, 3), span(2, 3) });
    var d: Regex.Diagnostic = .{};
    var re = try Regex.compile(gpa, .init("(?!(a))(\\w)"), .{ .syntax = ecma });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    var groups: [3]?Regex.Span = undefined;
    try testing.expect(try re.captures(&c, .of("ab"), &groups));
    try testing.expectEqual(span(1, 2), groups[0]);
    try testing.expectEqual(null, groups[1]);
    try testing.expectEqual(span(1, 2), groups[2]);

    // A set searches without rows: refused by name, the pattern named.
    const sources = [_]aegis.input.Untrusted([]const u8){ .init("a"), .init("(?=b)b") };
    try testing.expectError(error.Unsupported, Set.compile(gpa, &sources, .{ .syntax = ecma, .diagnostic = &d }));
    try testing.expectEqual(.unsupported_lookaround_in_set, d.reason);
    try testing.expectEqual(1, d.pattern.?);
}

test "the lazy DFA reads up to four stored rows as columns, and past that the PikeVM answers, counted" {
    // Five lookaheads, each stored for find: past four columns.
    var five = try Regex.compile(gpa, .init("(?=a)(?=\\w)(?=[a-z])(?!b)(?!c)a"), .{ .syntax = ecma });
    defer five.deinit();
    var fc = try five.cache(gpa);
    defer fc.deinit(gpa);
    try testing.expectEqual(span(1, 2), try five.find(&fc, .of("ba")));
    try testing.expectEqual(Regex.Cache.Path.pikevm_columns, fc.last);
    // Four: the lazy DFA.
    var four = try Regex.compile(gpa, .init("(?=a)(?=\\w)(?=[a-z])(?!b)a"), .{ .syntax = ecma });
    defer four.deinit();
    var gc = try four.cache(gpa);
    defer gc.deinit(gpa);
    try testing.expectEqual(span(1, 2), try four.find(&gc, .of("ba")));
    try testing.expectEqual(Regex.Cache.Path.lookaround_lazy_dfa, gc.last);
}

test "a search starting past the haystack's start runs the streamed lanes alone up to it, on the lazy DFA" {
    var re = try Regex.compile(gpa, .init("(?<=a.*)b"), .{ .syntax = ecma });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    // The a lies before the span: the lanes read it.
    const input: Regex.Input = .{ .haystack = "axxb", .span = .{ .start = 2, .end = 4 } };
    try testing.expectEqual(span(3, 4), try re.find(&c, input));
    try testing.expectEqual(Regex.Cache.Path.lookaround_lazy_dfa, c.last);
    const none: Regex.Input = .{ .haystack = "xxxb", .span = .{ .start = 2, .end = 4 } };
    try testing.expectEqual(null, try re.find(&c, none));
}

test "where the lazy DFA's store keeps clearing, it gives up and the PikeVM finds the same match" {
    // `(?:a|b)*a(?:a|b){5}` needs 2^6 states; a small store clears all along.
    const pattern = "(?<=x)(?:a|b)*a(?:a|b){5}(?=y)";
    var prng: std.Random.DefaultPrng = .init(0x6a1e);
    const random = prng.random();
    var hay: [4000]u8 = undefined;
    for (&hay) |*b| b.* = "ab"[random.uintLessThan(usize, 2)];
    hay[0] = 'x';
    hay[hay.len - 1] = 'y';
    var small = try Regex.compile(gpa, .init(pattern), .{ .syntax = ecma, .limits = .{ .lazy_dfa = .literal("8KiB") } });
    defer small.deinit();
    var sc = try small.cache(gpa);
    defer sc.deinit(gpa);
    var alone = try Regex.compile(gpa, .init(pattern), .{ .syntax = ecma, .limits = .{ .lazy_dfa = .fromRaw(0) } });
    defer alone.deinit();
    var ac = try alone.cache(gpa);
    defer ac.deinit(gpa);
    try testing.expectEqual(try alone.find(&ac, .of(&hay)), try small.find(&sc, .of(&hay)));
    try testing.expectEqual(Regex.Cache.Path.lookaround_lazy_dfa_fell_back, sc.last);
    try testing.expectEqual(Regex.Cache.Path.lookaround_pikevm, ac.last);
}

// Every search against ECMA-262's matcher.

var reached: struct {
    patterns: usize = 0,
    matched: usize = 0,
    groups: usize = 0,
    inside: usize = 0,
    scans_storing: usize = 0,
    find_streaming: usize = 0,
    budget: usize = 0,
    /// How `find` was answered, and searches started past 0 against the PikeVM alone.
    lazy_dfa: usize = 0,
    fell_back: usize = 0,
    pikevm: usize = 0,
    columns: usize = 0,
    spans: usize = 0,
} = .{};

fn anySearch(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var text: std.ArrayList(u8) = .empty;
    // One case in four reads five stored rows before the rest: past the lazy DFA's columns.
    if (shakedown.gen.intRange(s, usize, 0, 3) == 0) try text.appendSlice(a, "(?=.?)(?!c)(?=.*)(?!cc)(?=[^c]*)");
    try grammar.writeLookaround(s, &text, a, 4);
    const ast = try a.create(Ast);
    ast.* = parse_mod.parse(a, .init(text.items), ecma, .{}, null) catch return;
    const hir = translate_mod.translate(a, ast, ecma, .{}, null) catch return;
    if (hir.lookarounds == 0) return;
    var d: Regex.Diagnostic = .{};
    var re = Regex.compile(case.gpa, .init(text.items), .{ .syntax = ecma, .diagnostic = &d }) catch |err| switch (err) {
        error.TooLarge => return,
        else => return err,
    };
    if (re.look.?.bodies.len > 0) for (re.look.?.bodies) |b| if (b != null) {
        reached.inside += 1;
        break;
    };
    defer re.deinit();
    var c = try re.cache(case.gpa);
    defer c.deinit(case.gpa);
    var hay: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 0, 8)) |_| try hay.append(a, "ab \n"[shakedown.gen.intRange(s, usize, 0, 3)]);
    const want = spec.exec(a, &hir, hay.items, 50_000) catch |err| switch (err) {
        error.Budget => {
            reached.budget += 1;
            return;
        },
        else => return err,
    };
    reached.patterns += 1;
    if (re.longestHaystack(.is_match) != null) reached.scans_storing += 1;
    if (hay.items.len > 1) {
        var alone = try Regex.compile(case.gpa, .init(text.items), .{ .syntax = ecma, .limits = .{ .lazy_dfa = .fromRaw(0) } });
        defer alone.deinit();
        var ac = try alone.cache(case.gpa);
        defer ac.deinit(case.gpa);
        try spanAgrees(&re, &c, &alone, &ac, hay.items, shakedown.gen.intRange(s, usize, 1, hay.items.len));
        // A store of the fewest states over a longer haystack clears and gives up: the PikeVM
        // takes over, and the match is the same.
        var small = Regex.compile(case.gpa, .init(text.items), .{ .syntax = ecma, .limits = .{ .lazy_dfa = .fromRaw(1600) } }) catch |err| switch (err) {
            error.TooLarge => return,
            else => return err,
        };
        defer small.deinit();
        var sc = try small.cache(case.gpa);
        defer sc.deinit(case.gpa);
        var long: std.ArrayList(u8) = .empty;
        for (0..30) |_| try long.appendSlice(a, hay.items);
        const want_long = try alone.find(&ac, .of(long.items));
        try testing.expectEqual(want_long, try small.find(&sc, .of(long.items)));
        if (sc.last == .lookaround_lazy_dfa_fell_back) reached.fell_back += 1;
    }
    // Find streams the main expression's lookbehinds beside the PikeVM.
    if (re.look.?.stream.stored < re.look.?.search.stored) reached.find_streaming += 1;
    errdefer std.debug.print("/{s}/ on {any}: ECMA-262 {any}\n", .{ text.items, hay.items, want });
    try testing.expectEqual(want != null, try re.isMatch(&c, hay.items));
    const groups = try a.alloc(?Regex.Span, re.captureCount());
    const found = try re.captures(&c, .of(hay.items), groups);
    try testing.expectEqual(want != null, found);
    const w = want orelse return;
    reached.matched += 1;
    for (groups, w) |g, x| {
        try testing.expectEqual(x == null, g == null);
        if (g) |got| {
            try testing.expectEqual(x.?.start, got.start);
            try testing.expectEqual(x.?.end, got.end);
        }
    }
    if (groups.len > 1) reached.groups += 1;
    try testing.expectEqual(groups[0], try re.find(&c, .of(hay.items)));
    switch (c.last) {
        .lookaround_lazy_dfa => reached.lazy_dfa += 1,
        .lookaround_lazy_dfa_fell_back => reached.fell_back += 1,
        .lookaround_pikevm => reached.pikevm += 1,
        .pikevm_columns => reached.columns += 1,
        else => unreachable,
    }
}

/// A search over a span that starts past 0, on the lazy DFA (its lanes run up to the start) and
/// on the PikeVM alone: the same match.
fn spanAgrees(re: *const Regex, c: *Regex.Cache, alone: *const Regex, ac: *Regex.Cache, haystack: []const u8, start: usize) !void {
    const input: Regex.Input = .{ .haystack = haystack, .span = .{ .start = start, .end = haystack.len } };
    try testing.expectEqual(try alone.find(ac, input), try re.find(c, input));
    reached.spans += 1;
}

test "fuzz: every search of a pattern with lookarounds is what ECMA-262's matcher finds, nested both ways" {
    reached = .{};
    try shakedown.check(gpa, {}, anySearch, .{ .cases = 4000, .seed = 0x10a4 });
    if (fuzzing) return;
    errdefer std.debug.print("{any}\n", .{reached});
    try testing.expect(reached.patterns > 1000 and reached.matched > 500 and reached.groups > 100 and reached.inside > 200 and reached.scans_storing > 100 and reached.find_streaming > 300);
    try testing.expect(reached.lazy_dfa > 500 and reached.spans > 1000 and reached.columns > 300);
}
