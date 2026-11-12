//! Replace and split (spectra.md §4.3): each dialect's templates, the literal and call forms, the
//! limit's three meanings, each dialect's split, and every search after the first seeing the text
//! before where it starts.
const std = @import("std");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const testing = std.testing;
const gpa = testing.allocator;

const ecma: Syntax = .{ .dialect = .ecmascript };

fn replaced(pattern: []const u8, syntax: Syntax, haystack: []const u8, with: Regex.Replacement, limit: ?usize) ![]u8 {
    var re = try Regex.compile(gpa, .init(pattern), .{ .syntax = syntax });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    const groups = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(groups);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try re.replace(&c, &out.writer, haystack, with, groups, limit);
    return out.toOwnedSlice();
}

fn expectReplaced(want: []const u8, pattern: []const u8, syntax: Syntax, haystack: []const u8, with: Regex.Replacement, limit: ?usize) !void {
    const got = try replaced(pattern, syntax, haystack, with, limit);
    defer gpa.free(got);
    errdefer std.debug.print("/{s}/ on {s}\n", .{ pattern, haystack });
    try testing.expectEqualStrings(want, got);
}

test "Rust's templates: $n, $name, ${...}, $$, and what names nothing" {
    const t = struct {
        fn t(s: []const u8) Regex.Replacement {
            return .{ .template = s };
        }
    }.t;
    try expectReplaced("b@a d@c", "(\\w+)@(\\w+)", .{}, "a@b c@d", t("$2@$1"), null);
    try expectReplaced("11/2026", "(?P<y>\\d{4})-(?P<m>\\d{2})", .{}, "2026-11", t("$m/$y"), null);
    try expectReplaced("11x", "(?P<y>\\d{4})-(?P<m>\\d{2})", .{}, "2026-11", t("${m}x"), null);
    // `$mx` names a group "mx", which there is not: empty.
    try expectReplaced("", "(?P<y>\\d{4})-(?P<m>\\d{2})", .{}, "2026-11", t("$mx"), null);
    // The longest name: `$1a` is the group named "1a", not group 1.
    try expectReplaced("", "(a)", .{}, "a", t("$1a"), null);
    try expectReplaced("$ $", "a", .{}, "a", t("$ $$"), null);
    try expectReplaced("", "(a)", .{}, "a", t("$9"), null);
    try expectReplaced("${", "a", .{}, "a", t("${"), null);
    try expectReplaced("[]b", "(x)?b", .{}, "b", t("[$1]b"), null);
}

test "ECMAScript's templates: GetSubstitution's forms" {
    const t = struct {
        fn t(s: []const u8) Regex.Replacement {
            return .{ .template = s };
        }
    }.t;
    try expectReplaced("b@a", "(\\w+)@(\\w+)", ecma, "a@b", t("$2@$1"), null);
    try expectReplaced("x [a@b] y", "(\\w+)@(\\w+)", ecma, "x a@b y", t("[$&]"), null);
    try expectReplaced("x [x ] y", "(\\w+)@(\\w+)", ecma, "x a@b y", t("[$`]"), null);
    try expectReplaced("x [ y] y", "(\\w+)@(\\w+)", ecma, "x a@b y", t("[$']"), null);
    try expectReplaced("$", "a", ecma, "a", t("$$"), null);
    // `$0` is literal; `$10` with two groups is group 1 then "0"; `$01` is group 1.
    try expectReplaced("$0", "(a)(b)", ecma, "ab", t("$0"), null);
    try expectReplaced("a0", "(a)(b)", ecma, "ab", t("$10"), null);
    try expectReplaced("a", "(a)(b)", ecma, "ab", t("$01"), null);
    try expectReplaced("$3", "(a)(b)", ecma, "ab", t("$3"), null);
    try expectReplaced("b-a", "(?<x>a)(?<y>b)", ecma, "ab", t("$<y>-$<x>"), null);
    try expectReplaced("", "(?<x>a)(?<y>b)", ecma, "ab", t("$<z>"), null);
    // Without named groups, `$<` is literal.
    try expectReplaced("$<x>", "(a)(b)", ecma, "ab", t("$<x>"), null);
    try expectReplaced("$<x", "(?<x>a)", ecma, "a", t("$<x"), null);
    try expectReplaced("[]b", "(x)?b", ecma, "b", t("[$1]b"), null);
}

test "the literal and call forms, and the limit: null all, 0 none, n the first n" {
    try expectReplaced("$1-$1", "a", .{}, "a-a", .{ .literal = "$1" }, null);
    const Upper = struct {
        fn write(_: ?*anyopaque, haystack: []const u8, groups: []const ?Regex.Span, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const g = groups[1].?;
            for (haystack[g.start..g.end]) |b| try writer.writeByte(std.ascii.toUpper(b));
        }
    };
    try expectReplaced("AB-CD", "(\\w+)", .{}, "ab-cd", .{ .call = .{ .context = null, .write = Upper.write } }, null);
    try expectReplaced("x-x-x", "a", .{}, "a-a-a", .{ .literal = "x" }, null);
    try expectReplaced("a-a-a", "a", .{}, "a-a-a", .{ .literal = "x" }, 0);
    try expectReplaced("x-x-a", "a", .{}, "a-a-a", .{ .literal = "x" }, 2);
    // Empty matches, as `findAll` gives them.
    try expectReplaced("-a-b-", "", .{}, "ab", .{ .literal = "-" }, null);

    var re = try Regex.compile(gpa, .init("a"), .{});
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    var groups: [1]?Regex.Span = undefined;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(2, try re.replace(&c, &out.writer, "a-a-a", .{ .literal = "x" }, &groups, 2));
}

fn pieces(pattern: []const u8, syntax: Syntax, haystack: []const u8, limit: ?usize) ![]?[]const u8 {
    var re = try Regex.compile(gpa, .init(pattern), .{ .syntax = syntax });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    const groups = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(groups);
    var list: std.ArrayList(?[]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = re.split(&c, haystack, groups, limit);
    while (try it.next()) |p| try list.append(gpa, p.text);
    return list.toOwnedSlice(gpa);
}

fn expectPieces(want: []const ?[]const u8, pattern: []const u8, syntax: Syntax, haystack: []const u8, limit: ?usize) !void {
    const got = try pieces(pattern, syntax, haystack, limit);
    defer gpa.free(got);
    errdefer std.debug.print("/{s}/ on {s}: {any}\n", .{ pattern, haystack, got });
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w == null, g == null);
        if (w) |x| try testing.expectEqualStrings(x, g.?);
    }
}

test "Rust's split: the pieces between matches, the last the rest under a limit" {
    try expectPieces(&.{ "a", "b", "", "c" }, ",", .{}, "a,b,,c", null);
    try expectPieces(&.{ "", "a", "b", "c", "" }, "", .{}, "abc", null);
    try expectPieces(&.{ "a", "b,,c" }, ",", .{}, "a,b,,c", 2);
    try expectPieces(&.{}, ",", .{}, "a,b", 0);
    try expectPieces(&.{""}, ",", .{}, "", null);
    try expectPieces(&.{ "", "" }, ",", .{}, ",", null);
}

test "ECMAScript's split: SplitMatcher's pieces, groups among them, found leftmost-first" {
    try expectPieces(&.{ "a", "b", "c" }, "(?:)", ecma, "abc", null);
    try expectPieces(&.{ "a", "1", "b", "2", "c" }, "(\\d)", ecma, "a1b2c", null);
    try expectPieces(&.{ "a", null, "" }, "(x)?b", ecma, "ab", null);
    try expectPieces(&.{""}, "a", ecma, "", null);
    try expectPieces(&.{}, "(?:)", ecma, "", null);
    try expectPieces(&.{ "a", "1" }, "(\\d)", ecma, "a1b2c", 2);
    try expectPieces(&.{}, "(\\d)", ecma, "a1b", 0);
    try expectPieces(&.{ "a", "b", "", "c" }, ",", ecma, "a,b,,c", null);
    // A match at the very end is no split: "ab".split(/b/) is ["a", ""].
    try expectPieces(&.{ "a", "" }, "b", ecma, "ab", null);
}

test "every search after the first sees the text before where it starts" {
    // A lookbehind across a split boundary: the y's lookbehind reads the x the first match took.
    try expectPieces(&.{ "", "", "" }, "(?<=x)y|x", ecma, "xy", null);
    // And across a replace boundary.
    try expectReplaced("--", "(?<=x)y|x", ecma, "xy", .{ .literal = "-" }, null);
    // `\b` in Rust's dialect: after the a, a b in the middle of a word is no word's start.
    try expectReplaced("-b", "\\bb|a", .{}, "ab", .{ .literal = "-" }, null);
    try expectPieces(&.{ "", "b" }, "\\bb|a", .{}, "ab", null);
}
