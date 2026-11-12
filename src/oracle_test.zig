//! Lookaround's rows (oracle.zig): each stored row at every position is what ECMA-262's own
//! matcher (testing/ecma.zig) says the lookaround is there, on random patterns with lookarounds
//! nested both ways; a lookaround nested the same way as its parent is streamed, not stored, and
//! its parent's row, which reads it, is still ECMA-262's; each scan stays within its lanes'
//! states times positions.
const std = @import("std");
const shakedown = @import("shakedown");
const Syntax = @import("Syntax.zig");
const Ast = @import("syntax/Ast.zig");
const parse_mod = @import("syntax/parse.zig");
const translate_mod = @import("hir/translate.zig");
const Hir = @import("hir/Hir.zig");
const oracle = @import("oracle.zig");
const spec = @import("testing/ecma.zig");
const grammar = @import("testing/grammar.zig");
const testing = std.testing;
const fuzzing = @import("builtin").fuzz;
const gpa = testing.allocator;

const ecma: Syntax = .{ .dialect = .ecmascript, .unicode = true };

fn hirOf(a: std.mem.Allocator, pattern: []const u8) !Hir {
    const ast = try a.create(Ast);
    ast.* = try parse_mod.parse(a, .init(pattern), ecma, .{}, null);
    return translate_mod.translate(a, ast, ecma, .{}, null);
}

/// Row `row` of `pattern` over `haystack`, as a string of 0s and 1s, one per position.
fn rowText(a: std.mem.Allocator, pattern: []const u8, haystack: []const u8, row: u32) ![]const u8 {
    const hir = try hirOf(a, pattern);
    var p = try oracle.plan(gpa, &hir, .{}, null);
    defer p.deinit(gpa);
    var c = try oracle.Cache.init(gpa, &p, null, 4096);
    defer c.deinit(gpa);
    try oracle.fill(&p, &c, haystack);
    const out = try a.alloc(u8, haystack.len + 1);
    for (out, 0..) |*o, at| o.* = if (c.holds(p.rows[row].slot.?, at)) '1' else '0';
    return out;
}

test "a lookbehind holds where its body ends, a lookahead where it starts, inner rows first" {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    // Positions 0..5 of "xabab".
    try testing.expectEqualStrings("000101", try rowText(a, "(?<=ab)", "xabab", 0));
    try testing.expectEqualStrings("010100", try rowText(a, "(?=ab)", "xabab", 0));
    try testing.expectEqualStrings("011110", try rowText(a, "(?=a|b)", "xabab", 0));
    // Unbounded bodies.
    try testing.expectEqualStrings("010100", try rowText(a, "(?=a.*b$)", "xabab", 0));
    try testing.expectEqualStrings("011111", try rowText(a, "(?<=^x.*)", "xabab", 0));
    // The row is the lookaround's own truth; a negation is the check's.
    try testing.expectEqualStrings("010100", try rowText(a, "(?!ab)", "xabab", 0));
    // Nested: `(?=a(?<!xa)b)` takes the ab whose a has no x before it. The lookbehind's row is
    // built first, and holds where "xa" ends.
    try testing.expectEqualStrings("000100", try rowText(a, "(?=a(?<!xa)b)", "xabab", 0));
    try testing.expectEqualStrings("001000", try rowText(a, "(?=a(?<!xa)b)", "xabab", 1));
    // Nested the same way: streamed in the parent's scan, which reads it at each position.
    try testing.expectEqualStrings("010100", try rowText(a, "(?=a(?=b))", "xabab", 0));
    try testing.expectEqualStrings("000101", try rowText(a, "(?<=(?<=a)b)", "xabab", 0));
    // Both in one body: the inner lookbehind streamed, the inner lookahead stored.
    try testing.expectEqualStrings("000100", try rowText(a, "(?<=(?<=xa)b(?=a))", "xabab", 0));
}

test "a lookaround read the way of the scan that queries it is streamed; the other way, stored" {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const hir = try hirOf(state.allocator(), "(?=a(?=b)(?<=a))(?<=c(?<=d(?=e)))");
    var p = try oracle.plan(gpa, &hir, .{}, null);
    defer p.deinit(gpa);
    // 0 ahead (top: stored), 1 ahead in an ahead (streamed), 2 behind in an ahead (stored),
    // 3 behind (top: stored), 4 behind in a behind (streamed), 5 ahead in a behind (stored).
    const want = [_]bool{ true, false, true, true, false, true };
    for (p.rows, want) |r, stored| try testing.expectEqual(stored, r.slot != null);
    try testing.expectEqual(4, p.stored);
    // With a forward main scan, the top lookbehind streams there too.
    var forward = try oracle.plan(gpa, &hir, .{ .main = .forward }, null);
    defer forward.deinit(gpa);
    try testing.expectEqual(null, forward.rows[3].slot);
    try testing.expectEqual(3, forward.stored);
}

test "rows are refused before a byte is read where they would pass the store" {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const hir = try hirOf(state.allocator(), "(?=a)(?<=b)");
    var p = try oracle.plan(gpa, &hir, .{}, null);
    defer p.deinit(gpa);
    // Two rows of one word each: 64 positions, a haystack of 63 bytes.
    var c = try oracle.Cache.init(gpa, &p, null, 2 * @sizeOf(usize));
    defer c.deinit(gpa);
    try testing.expectEqual(@as(?usize, @bitSizeOf(usize) - 1), c.longest(&p));
    const long: [@bitSizeOf(usize) - 1]u8 = @splat('a');
    try oracle.fill(&p, &c, &long);
    const longer: [@bitSizeOf(usize)]u8 = @splat('a');
    try testing.expectError(error.HaystackTooLong, oracle.fill(&p, &c, &longer));
}

var reached: struct { patterns: usize = 0, rows: usize = 0, ahead: usize = 0, behind: usize = 0, nested: usize = 0, streamed: usize = 0, held: usize = 0, budget: usize = 0 } = .{};

fn anyRows(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var text: std.ArrayList(u8) = .empty;
    try grammar.writeLookaround(s, &text, a, 4);
    const ast = try a.create(Ast);
    ast.* = parse_mod.parse(a, .init(text.items), ecma, .{}, null) catch return;
    const hir = translate_mod.translate(a, ast, ecma, .{}, null) catch return;
    if (hir.lookarounds == 0) return;
    var hay: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 0, 8)) |_| try hay.append(a, "ab \n"[shakedown.gen.intRange(s, usize, 0, 3)]);
    var p = oracle.plan(case.gpa, &hir, .{}, null) catch |err| switch (err) {
        error.TooLarge => return,
        else => return err,
    };
    defer p.deinit(case.gpa);
    var c = try oracle.Cache.init(case.gpa, &p, null, 1 << 12);
    defer c.deinit(case.gpa);
    try oracle.fill(&p, &c, hay.items);
    reached.patterns += 1;
    for (hir.nodes, 0..) |node, i| switch (node) {
        .lookaround => |la| {
            reached.rows += 1;
            switch (la.kind) {
                .ahead => reached.ahead += 1,
                .behind => reached.behind += 1,
            }
            if (la.index > 0) reached.nested += 1;
            // A streamed row is checked through its parent's, which reads it.
            const slot = p.rows[la.index].slot orelse {
                reached.streamed += 1;
                continue;
            };
            for (0..hay.items.len + 1) |at| {
                const want = spec.lookaroundHolds(a, &hir, @enumFromInt(i), hay.items, at, 20_000) catch |err| switch (err) {
                    error.Budget => {
                        reached.budget += 1;
                        continue;
                    },
                    else => return err,
                };
                if (want != c.holds(slot, at)) {
                    std.debug.print("/{s}/ on {any}: row {d} at {d}: {}, ECMA-262 {}\n", .{ text.items, hay.items, la.index, at, c.holds(slot, at), want });
                    return error.TestUnexpectedResult;
                }
                if (want) reached.held += 1;
            }
        },
        else => {},
    };
}

test "fuzz: every lookaround's row is ECMA-262's answer at every position, nested both ways" {
    reached = .{};
    try shakedown.check(gpa, {}, anyRows, .{ .cases = 4000, .seed = 0x0ac1e });
    if (fuzzing) return;
    errdefer std.debug.print("{any}\n", .{reached});
    try testing.expect(reached.patterns > 1500 and reached.ahead > 1000 and reached.behind > 1000 and reached.nested > 500 and reached.streamed > 200 and reached.held > 3000);
}
