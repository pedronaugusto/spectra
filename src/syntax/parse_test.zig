//! The Rust dialect's parser: the grammar's every form, every refusal with its reason and span,
//! the limits, and any bytes refused by name or parsed, never a crash.
const std = @import("std");
const shakedown = @import("shakedown");
const Ast = @import("Ast.zig");
const parse_mod = @import("parse.zig");
const Syntax = @import("../Syntax.zig");
const Limits = @import("../Limits.zig");
const testing = std.testing;

fn parse(arena: std.mem.Allocator, pattern: []const u8, syntax: Syntax, limits: Limits, diagnostic: ?*parse_mod.Diagnostic) parse_mod.Error!Ast {
    return parse_mod.parse(arena, .init(pattern), syntax, limits, diagnostic);
}

/// The AST of `pattern` written back as a canonical text, so each case states its shape.
fn shape(arena: std.mem.Allocator, pattern: []const u8, syntax: Syntax) ![]const u8 {
    const ast = try parse(arena, pattern, syntax, .{}, null);
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&ast, ast.root, &out.writer);
    return out.written();
}

fn write(ast: *const Ast, index: Ast.Index, w: *std.Io.Writer) !void {
    switch (ast.node(index).kind) {
        .empty => try w.writeAll("()"),
        .literal => |cp| try w.print("'{u}'", .{cp}),
        .dot => try w.writeAll("."),
        .assertion => |a| try w.print("@{t}", .{a}),
        .perl => |p| try w.print("\\{s}{t}", .{ if (p.negated) "!" else "", p.class }),
        .unicode => |u| try w.print("\\p{{{s}{s}{s}{s}}}", .{ if (u.negated) "^" else "", u.name, if (u.value != null) "=" else "", u.value orelse "" }),
        .bracketed => |b| try writeClass(ast, b, w),
        .repetition => |r| {
            try write(ast, r.sub, w);
            if (r.max) |max| try w.print("{{{d},{d}}}", .{ r.min, max }) else try w.print("{{{d},}}", .{r.min});
            if (!r.greedy) try w.writeAll("?");
        },
        .group => |g| switch (g.kind) {
            .capture => |c| {
                try w.print("(#{d}{s}{s}:", .{ c.index, if (c.name != null) " " else "", c.name orelse "" });
                try write(ast, g.sub, w);
                try w.writeAll(")");
            },
            .non_capturing => |f| {
                try w.print("(?{x}-{x}:", .{ @as(u8, @bitCast(f.set)), @as(u8, @bitCast(f.clear)) });
                try write(ast, g.sub, w);
                try w.writeAll(")");
            },
        },
        .flags => |f| try w.print("(?{x}-{x})", .{ @as(u8, @bitCast(f.set)), @as(u8, @bitCast(f.clear)) }),
        .alternation => |s| for (ast.childrenOf(s), 0..) |child, i| {
            if (i != 0) try w.writeAll("|");
            try write(ast, child, w);
        },
        .concat => |s| {
            try w.writeAll("[");
            for (ast.childrenOf(s)) |child| try write(ast, child, w);
            try w.writeAll("]");
        },
        // The ECMAScript dialect's alone: ecma_test.zig writes them.
        .lookaround, .backreference => return error.NotRustSyntax,
    }
}

fn writeClass(ast: *const Ast, b: Ast.Bracketed, w: *std.Io.Writer) !void {
    try w.writeAll(if (b.negated) "[^" else "[");
    try writeItems(ast, ast.itemsOf(b.items), w);
    try w.writeAll("]");
}

fn writeItems(ast: *const Ast, items: []const Ast.ClassItem, w: *std.Io.Writer) anyerror!void {
    for (items) |item| switch (item) {
        .literal => |cp| try w.print("{u}", .{cp}),
        .range => |r| try w.print("{u}-{u}", .{ r[0], r[1] }),
        .perl => |p| try w.print("\\{s}{t}", .{ if (p.negated) "!" else "", p.class }),
        .unicode => |u| try w.print("\\p{{{s}}}", .{u.name}),
        .ascii => |a| try w.print("[:{s}{t}:]", .{ if (a.negated) "^" else "", a.class }),
        .nested => |n| try writeClass(ast, n, w),
        .operation => |o| {
            try w.writeAll("(");
            try writeItems(ast, ast.itemsOf(o.lhs), w);
            try w.print(" {t} ", .{o.op});
            try writeItems(ast, ast.itemsOf(o.rhs), w);
            try w.writeAll(")");
        },
        .strings => return error.NotRustSyntax,
    };
}

test "the grammar's forms parse to their shapes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "()" },
        .{ "a", "'a'" },
        .{ "ab", "['a''b']" },
        .{ "a|b", "'a'|'b'" },
        .{ "a|", "'a'|()" },
        .{ "a*b+c?", "['a'{0,}'b'{1,}'c'{0,1}]" },
        .{ "a*?", "'a'{0,}?" },
        .{ "a{3}", "'a'{3,3}" },
        .{ "a{2,}", "'a'{2,}" },
        .{ "a{2,5}?", "'a'{2,5}?" },
        .{ "(a)(?:b)(?<n>c)(?P<m>d)", "[(#1:'a')(?0-0:'b')(#2 n:'c')(#3 m:'d')]" },
        .{ "(?i)a", "[(?1-0)'a']" },
        .{ "(?i-s:a)", "(?1-4:'a')" },
        .{ ".^$", "[.@start_line@end_line]" },
        .{ "\\A\\z\\b\\B\\<\\>", "[@start_text@end_text@word_boundary@not_word_boundary@word_start@word_end]" },
        .{ "\\b{start}\\b{end-half}", "[@word_start@word_end_half]" },
        .{ "\\d\\S\\w", "[\\digit\\!space\\word]" },
        .{ "\\pL\\p{Greek}\\P{sc=Han}\\p{^Lu}", "[\\p{L}\\p{Greek}\\p{^sc=Han}\\p{^Lu}]" },
        .{ "\\x41\\x{1F600}\\u00e9\\U0001F600", "['A''😀''é''😀']" },
        .{ "\\.\\*\\-\\ ", "['.''*''-'' ']" },
        .{ "[a-z0]", "[a-z0]" },
        .{ "[^]a]", "[^]a]" },
        .{ "[]a]", "[]a]" },
        .{ "[a-]", "[a-]" },
        .{ "[[:alpha:][:^digit:]]", "[[:alpha:][:^digit:]]" },
        .{ "[a[b-c]]", "[a[b-c]]" },
        .{ "[a-z&&[^aeiou]]", "[(a-z intersection [^aeiou])]" },
        .{ "[a-z--b~~c]", "[((a-z difference b) symmetric_difference c)]" },
        .{ "[\\d\\pL]", "[\\digit\\p{L}]" },
        .{ "é", "'é'" },
    };
    for (cases) |case| {
        const got = shape(a, case[0], .{}) catch |err| {
            std.debug.print("pattern {s}: {t}\n", .{ case[0], err });
            return err;
        };
        testing.expectEqualStrings(case[1], got) catch |err| {
            std.debug.print("pattern {s}\n", .{case[0]});
            return err;
        };
    }
}

test "x ignores whitespace and comments, in groups that set it and in classes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("['a''b']", try shape(a, " a  b # a comment\n", .{ .ignore_whitespace = true }));
    try testing.expectEqualStrings("[(?20-0)'a''b'' ']", try shape(a, "(?x) a b \\ ", .{}));
    try testing.expectEqualStrings("['a'(?20-0:['b''c'])' ''d']", try shape(a, "a(?x: b c ) d", .{}));
    try testing.expectEqualStrings("'a'{2,3}", try shape(a, "a{ 2 , 3 }", .{ .ignore_whitespace = true }));
}

test "every refusal names its reason and points at its span" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, parse_mod.Reason, u32 }{
        .{ "(a", .unclosed_group, 0 },
        .{ "a)", .unopened_group, 1 },
        .{ "[a", .unclosed_class, 0 },
        .{ "[]", .unclosed_class, 0 },
        .{ "[z-a]", .class_range_out_of_order, 1 },
        .{ "[a-\\d]", .class_range_bad_end, 3 },
        .{ "*", .repetition_missing, 0 },
        .{ "(?i)*", .repetition_missing, 4 },
        .{ "a{", .repetition_count_invalid, 1 },
        .{ "a{,2}", .repetition_count_invalid, 1 },
        .{ "a{3,2}", .repetition_count_out_of_order, 1 },
        .{ "\\", .escape_unexpected_end, 0 },
        .{ "\\q", .escape_unrecognized, 0 },
        .{ "\\xZZ", .escape_hex_invalid, 0 },
        .{ "\\x{110000}", .code_point_invalid, 0 },
        .{ "\\u{d800}", .code_point_invalid, 0 },
        .{ "[\\b]", .assertion_in_class, 1 },
        .{ "\\p{}", .unicode_class_invalid, 0 },
        .{ "\\p{=x}", .unicode_class_invalid, 0 },
        .{ "(?q)", .flag_unrecognized, 2 },
        .{ "(?ii)", .flag_repeated, 3 },
        .{ "(?i-)", .flag_dangling_negation, 3 },
        .{ "(?)", .flags_empty, 0 },
        .{ "(?<1a>x)", .group_name_invalid, 3 },
        .{ "(?<a>x)(?<a>y)", .group_name_duplicate, 10 },
        .{ "\xff", .invalid_utf8, 0 },
    };
    for (cases) |case| {
        var d: parse_mod.Diagnostic = .{};
        const result = parse(a, case[0], .{}, .{}, &d);
        testing.expectError(error.Invalid, result) catch |err| {
            std.debug.print("pattern {s}: expected Invalid\n", .{case[0]});
            return err;
        };
        testing.expectEqual(case[1], d.reason) catch |err| {
            std.debug.print("pattern {s}: reason {t}\n", .{ case[0], d.reason });
            return err;
        };
        testing.expectEqual(case[2], d.span.start) catch |err| {
            std.debug.print("pattern {s}: span {d}..{d}\n", .{ case[0], d.span.start, d.span.end });
            return err;
        };
    }
}

test "the limits refuse a long pattern, deep nesting and a large count before anything is built" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: parse_mod.Diagnostic = .{};
    const limits: Limits = .{ .pattern = .fromRaw(8), .nesting = .literal(3), .repetition = .literal(10) };
    try testing.expectError(error.TooLarge, parse(a, "aaaaaaaaa", .{}, limits, &d));
    try testing.expectEqual(parse_mod.Reason.pattern_too_long, d.reason);
    try testing.expectError(error.TooLarge, parse(a, "((((a))))", .{}, .{ .nesting = .literal(3) }, &d));
    try testing.expectEqual(parse_mod.Reason.nesting_too_deep, d.reason);
    try testing.expectError(error.TooLarge, parse(a, "[[[[a]]]]", .{}, .{ .nesting = .literal(3) }, &d));
    try testing.expectEqual(parse_mod.Reason.nesting_too_deep, d.reason);
    try testing.expectError(error.TooLarge, parse(a, "a{11}", .{}, .{ .repetition = .literal(10) }, &d));
    try testing.expectEqual(parse_mod.Reason.repetition_count_too_large, d.reason);
    // 250 deep is the default's edge, and parses.
    const deep = try a.alloc(u8, 250 * 2 + 1);
    @memset(deep[0..250], '(');
    deep[250] = 'a';
    @memset(deep[251..], ')');
    _ = try parse(a, deep, .{}, .{}, null);
}

const alphabet = "ab()[]{}|*+?^$.\\-&~:<>=!,0123456789dDsSwWpPbBAzxuUnt PLi";

fn anyPattern(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const n = shakedown.gen.intRange(s, usize, 0, 48);
    const pattern = try case.gpa.alloc(u8, n);
    for (pattern) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    case.note("/{s}/", .{pattern});
    var arena_state: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena_state.deinit();
    var d: parse_mod.Diagnostic = .{};
    if (parse(arena_state.allocator(), pattern, .{}, .{}, &d)) |ast| {
        // Every node's span lies in the pattern, its start before its end.
        for (ast.nodes) |node| {
            try testing.expect(node.span.start <= node.span.end);
            try testing.expect(node.span.end <= pattern.len);
        }
    } else |err| switch (err) {
        error.Invalid, error.TooLarge => {
            try testing.expect(d.reason != .none);
            try testing.expect(d.span.start <= d.span.end and d.span.end <= pattern.len);
        },
        error.OutOfMemory => return err,
    }
}

test "fuzz: any pattern of regex syntax parses or is refused by name, its spans in the pattern" {
    try shakedown.check(testing.allocator, {}, anyPattern, .{ .cases = 5000, .seed = 0x5bec });
}
