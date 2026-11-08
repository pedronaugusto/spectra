//! Range sets: every operation agrees with a set of values held one by one, and leaves the
//! ranges sorted and apart; closing under case adds exactly what each folding matches.
const std = @import("std");
const shakedown = @import("shakedown");
const xenoglyph = @import("xenoglyph");
const ranges = @import("ranges.zig");
const testing = std.testing;
const CodePoints = ranges.CodePoints;
const Bytes = ranges.Bytes;

fn expectCanonical(comptime S: type, s: *const S) !void {
    for (s.items(), 0..) |r, i| {
        try testing.expect(r[0] <= r[1]);
        if (i > 0) try testing.expect(@as(u32, r[0]) > @as(u32, s.items()[i - 1][1]) + 1);
    }
}

fn randomBytes(gpa: std.mem.Allocator, case: *shakedown.Case, model: *[256]bool) !Bytes {
    const n = shakedown.gen.intRange(case.source, usize, 0, 6);
    var list: [6]Bytes.Range = undefined;
    model.* = @splat(false);
    for (list[0..n]) |*r| {
        const a = shakedown.gen.intRange(case.source, u8, 0, 255);
        const b = shakedown.gen.intRange(case.source, u8, a, @min(255, @as(u16, a) + 40));
        r.* = .{ a, b };
        for (a..@as(usize, b) + 1) |v| model[v] = true;
    }
    return Bytes.fromRanges(gpa, list[0..n]);
}

fn expectModel(s: *const Bytes, model: *const [256]bool) !void {
    try expectCanonical(Bytes, s);
    for (model, 0..) |want, v| try testing.expectEqual(want, s.contains(@intCast(v)));
    var n: u32 = 0;
    for (model) |want| n += @intFromBool(want);
    try testing.expectEqual(n, s.count());
}

fn operations(_: void, case: *shakedown.Case) !void {
    const gpa = case.gpa;
    var ma: [256]bool = undefined;
    var mb: [256]bool = undefined;
    var a = try randomBytes(gpa, case, &ma);
    defer a.deinit(gpa);
    var b = try randomBytes(gpa, case, &mb);
    defer b.deinit(gpa);
    try expectModel(&a, &ma);
    const which = shakedown.gen.intRange(case.source, u8, 0, 4);
    var want: [256]bool = undefined;
    for (&want, ma, mb) |*w, x, y| w.* = switch (which) {
        0 => x or y,
        1 => x and y,
        2 => x and !y,
        3 => x != y,
        else => !x,
    };
    switch (which) {
        0 => try a.unionWith(gpa, &b),
        1 => try a.intersect(gpa, &b),
        2 => try a.subtract(gpa, &b),
        3 => try a.symmetricDifference(gpa, &b),
        else => try a.negate(gpa),
    }
    try expectModel(&a, &want);
}

test "property: union, intersection, difference, symmetric difference and negation agree with a model" {
    try shakedown.check(testing.allocator, {}, operations, .{ .cases = 3000, .seed = 0x5e75 });
}

test "a code point set spans U+0000 to U+10FFFF, and negating twice gives it back" {
    const gpa = testing.allocator;
    var s = try CodePoints.fromRanges(gpa, &.{ .{ 'a', 'z' }, .{ 0x10ffff, 0x10ffff }, .{ 'b', 'c' }, .{ 0, 0 } });
    defer s.deinit(gpa);
    try testing.expectEqualSlices(CodePoints.Range, &.{ .{ 0, 0 }, .{ 'a', 'z' }, .{ 0x10ffff, 0x10ffff } }, s.items());
    try s.negate(gpa);
    try testing.expectEqualSlices(CodePoints.Range, &.{ .{ 1, 'a' - 1 }, .{ 'z' + 1, 0x10fffe } }, s.items());
    try s.negate(gpa);
    try testing.expectEqualSlices(CodePoints.Range, &.{ .{ 0, 0 }, .{ 'a', 'z' }, .{ 0x10ffff, 0x10ffff } }, s.items());
    var empty: CodePoints = .{};
    defer empty.deinit(gpa);
    try empty.negate(gpa);
    try testing.expectEqualSlices(CodePoints.Range, &.{.{ 0, 0x10ffff }}, empty.items());
}

fn closed(gpa: std.mem.Allocator, set: []const CodePoints.Range, folding: ranges.Folding) !CodePoints {
    var s = try CodePoints.fromRanges(gpa, set);
    errdefer s.deinit(gpa);
    try s.closeUnderCase(gpa, folding);
    try expectCanonical(CodePoints, &s);
    return s;
}

fn expectClosure(set: []const CodePoints.Range, folding: ranges.Folding, want: []const CodePoints.Range) !void {
    var s = try closed(testing.allocator, set, folding);
    defer s.deinit(testing.allocator);
    try testing.expectEqualSlices(CodePoints.Range, want, s.items());
}

test "closing under case: simple folding, ASCII's, and ECMA-262's uppercase without u" {
    // Simple folding: k with K and the Kelvin sign, s with S and the long s.
    try expectClosure(&.{.{ 'k', 'k' }}, .simple, &.{ .{ 'K', 'K' }, .{ 'k', 'k' }, .{ 0x212a, 0x212a } });
    try expectClosure(&.{.{ 'a', 'z' }}, .simple, &.{ .{ 'A', 'Z' }, .{ 'a', 'z' }, .{ 0x17f, 0x17f }, .{ 0x212a, 0x212a } });
    try expectClosure(&.{.{ 0x3c3, 0x3c3 }}, .simple, &.{ .{ 0x3a3, 0x3a3 }, .{ 0x3c2, 0x3c3 } });
    try expectClosure(&.{.{ 0x10400, 0x10400 }}, .simple, &.{ .{ 0x10400, 0x10400 }, .{ 0x10428, 0x10428 } });
    try expectClosure(&.{.{ '1', '9' }}, .simple, &.{.{ '1', '9' }});
    // ASCII: letters alone.
    try expectClosure(&.{.{ 'a', 'z' }}, .ascii, &.{ .{ 'A', 'Z' }, .{ 'a', 'z' } });
    try expectClosure(&.{.{ 0x3c3, 0x3c3 }}, .ascii, &.{.{ 0x3c3, 0x3c3 }});
    // ECMA-262 without u: no Kelvin sign and no long s (they would meet ASCII), sigma's three,
    // theta without U+03F4 (whose uppercase is itself), sharp s alone, and past U+FFFF no case.
    try expectClosure(&.{.{ 'k', 'k' }}, .ecma_uppercase, &.{ .{ 'K', 'K' }, .{ 'k', 'k' } });
    try expectClosure(&.{.{ 'a', 'z' }}, .ecma_uppercase, &.{ .{ 'A', 'Z' }, .{ 'a', 'z' } });
    try expectClosure(&.{.{ 0x3c3, 0x3c3 }}, .ecma_uppercase, &.{ .{ 0x3a3, 0x3a3 }, .{ 0x3c2, 0x3c3 } });
    try expectClosure(&.{.{ 0x3b8, 0x3b8 }}, .ecma_uppercase, &.{ .{ 0x398, 0x398 }, .{ 0x3b8, 0x3b8 }, .{ 0x3d1, 0x3d1 } });
    try expectClosure(&.{.{ 0xdf, 0xdf }}, .ecma_uppercase, &.{.{ 0xdf, 0xdf }});
    try expectClosure(&.{.{ 0x10400, 0x10400 }}, .ecma_uppercase, &.{.{ 0x10400, 0x10400 }});
    // U+1F80's uppercase is two code points, so it is its own.
    try testing.expectEqual(@as(u21, 0x1f80), ranges.ecmaCanonicalize(0x1f80));
    try testing.expectEqual(@as(u21, 'K'), ranges.ecmaCanonicalize('k'));
    try testing.expectEqual(@as(u21, 0x17f), ranges.ecmaCanonicalize(0x17f));
}

test "a byte set closes under ASCII's case whatever the folding" {
    const gpa = testing.allocator;
    var s = try Bytes.fromRanges(gpa, &.{ .{ 'x', 'z' }, .{ 0xe0, 0xe0 } });
    defer s.deinit(gpa);
    try s.closeUnderCase(gpa, .simple);
    try testing.expectEqualSlices(Bytes.Range, &.{ .{ 'X', 'Z' }, .{ 'x', 'z' }, .{ 0xe0, 0xe0 } }, s.items());
}

test "closing the whole code space under case leaves it whole, and closing is idempotent" {
    const gpa = testing.allocator;
    inline for (.{ ranges.Folding.simple, .ecma_uppercase, .ascii }) |folding| {
        var all = try closed(gpa, &.{.{ 0, 0x10ffff }}, folding);
        defer all.deinit(gpa);
        try testing.expectEqualSlices(CodePoints.Range, &.{.{ 0, 0x10ffff }}, all.items());
        var letters = try closed(gpa, &.{ .{ 'a', 'z' }, .{ 0x370, 0x3ff }, .{ 0x10400, 0x1044f } }, folding);
        defer letters.deinit(gpa);
        var again = try letters.clone(gpa);
        defer again.deinit(gpa);
        try again.closeUnderCase(gpa, folding);
        try testing.expect(again.eql(&letters));
    }
}

fn foldsOne(_: void, case: *shakedown.Case) !void {
    const cp = shakedown.gen.intRange(case.source, u21, 0, 0x1ffff);
    case.note("U+{X:0>4}", .{cp});
    var s = try closed(case.gpa, &.{.{ cp, cp }}, .simple);
    defer s.deinit(case.gpa);
    const orbit = xenoglyph.case.simpleFoldOrbit(cp);
    if (orbit.len == 0) {
        try testing.expectEqualSlices(CodePoints.Range, &.{.{ cp, cp }}, s.items());
    } else {
        try testing.expectEqual(@as(u32, @intCast(orbit.len)), s.count());
        for (orbit) |member| try testing.expect(s.contains(member));
    }
}

test "property: one code point closes to its simple folding orbit" {
    try shakedown.check(testing.allocator, {}, foldsOne, .{ .cases = 3000, .seed = 0xf01d });
}
