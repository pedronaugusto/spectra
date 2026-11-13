//! The ECMAScript dialect: ECMA-262's grammar under each of Annex B, `u` and `v`, every case's
//! verdict as a conforming engine gives it, the shapes it reads to, its refusals with their
//! reasons, and any bytes read or refused by name, never a crash.
const std = @import("std");
const shakedown = @import("shakedown");
const Ast = @import("Ast.zig");
const parse_mod = @import("parse.zig");
const ecma = @import("ecma.zig");
const Syntax = @import("../Syntax.zig");
const testing = std.testing;

fn validate(pattern: []const u8, flags: []const u8, diagnostic: ?*parse_mod.Diagnostic) !bool {
    return ecma.validate(testing.allocator, .init(pattern), flags, .{}, diagnostic);
}

/// Each pattern with its flags, and whether ECMA-262 takes it: the verdicts are V8's
/// (`new RegExp(pattern, flags)` in Node 26) but where V8 departs from the standard, noted.
const cases = [_]struct { []const u8, []const u8, bool }{
    .{ "", "", true },
    .{ "a", "", true },
    .{ "a|b|", "", true },
    .{ "(a)(?:b)(?<n>c)", "", true },
    .{ "a*b+c?d{2}e{2,}f{2,3}g*?h+?i??j{2}?", "", true },
    .{ "a{3,2}", "", false },
    .{ "a{99999999999999999999}", "", true },
    .{ "a{2,99999999999999999999}", "", true },
    .{ "a{99999999999999999999,2}", "", false },
    .{ "a{,5}", "", true },
    .{ "a{,5}", "u", false },
    .{ "{", "", true },
    .{ "{", "u", false },
    .{ "}", "", true },
    .{ "}", "u", false },
    .{ "]", "", true },
    .{ "]", "u", false },
    .{ "a{", "", true },
    .{ "a{1", "", true },
    .{ "a{1,", "", true },
    .{ "{1}", "", false },
    .{ "x|{1}", "", false },
    .{ "a**", "", false },
    .{ "a{2}{3}", "", false },
    .{ "*a", "", false },
    .{ "+", "", false },
    .{ "?", "", false },
    .{ "^*", "", false },
    .{ "$+", "", false },
    .{ "\\b*", "", false },
    .{ "\\B{2}", "", false },
    .{ "(?=a)*", "", true },
    .{ "(?=a)*", "u", false },
    .{ "(?!a){2}", "", true },
    .{ "(?!a){2}", "v", false },
    .{ "(?<=a)*", "", false },
    .{ "(?<!a)+", "", false },
    .{ "(?<=a)", "", true },
    .{ "(?<!a)b", "", true },
    .{ "(?=(?=a))", "", true },
    .{ "(?<=(?<!a))", "", true },
    .{ "(?:", "", false },
    .{ "(", "", false },
    .{ ")", "", false },
    .{ "a)", "", false },
    .{ "((a)", "", false },
    .{ "(?i:a)", "", true },
    .{ "(?-i:a)", "", true },
    .{ "(?i-m:a)", "", true },
    .{ "(?ims-:a)", "", true },
    .{ "(?-:a)", "", false },
    .{ "(?ii:a)", "", false },
    .{ "(?i-i:a)", "", false },
    .{ "(?x:a)", "", false },
    .{ "(?i)a", "", false },
    .{ "(?P<n>a)", "", false },
    .{ "(?<n>a)\\k<n>", "", true },
    .{ "(?<n>a)\\k<m>", "", false },
    .{ "\\k<n>(?<n>a)", "", true },
    .{ "\\k<n>", "", true },
    .{ "\\k<n>", "u", false },
    .{ "\\k", "", true },
    .{ "\\k", "u", false },
    .{ "\\ka(?<n>b)", "", false },
    .{ "(?<a>x)(?<a>y)", "", false },
    .{ "(?<a>x)|(?<a>y)", "", true },
    .{ "(?:(?<a>x)|(?<a>y))(?<a>z)", "", false },
    .{ "(?:(?<a>x)|(?<a>y))\\k<a>", "", true },
    .{ "(?<a>(?<a>x))", "", false },
    .{ "((?<a>x))|(?<a>y)", "", true },
    .{ "(?<a>x)|((?<a>y)|(?<a>z))", "", true },
    .{ "(?<a>x)|(?<b>y)(?<a>z)", "", true },
    .{ "(?<$>a)", "", true },
    .{ "(?<_a1>a)", "", true },
    .{ "(?<1a>a)", "", false },
    .{ "(?<>a)", "", false },
    .{ "(?<a-b>a)", "", false },
    .{ "(?<a>a)\\k<a>", "", true },
    .{ "(?<\\u{61}>a)", "", true },
    .{ "(?<\\u{61}>a)", "u", true },
    .{ "(?<a\u{200c}>a)", "", true },
    .{ "(?<\u{3c0}>a)\\k<\u{3c0}>", "", true },
    .{ "(?<\u{1d49c}>a)", "", true },
    .{ "(?<\\ud835>a)", "", false },
    .{ "(?<a", "", false },
    .{ "\\1", "", true },
    .{ "\\1", "u", false },
    .{ "(a)\\1", "", true },
    .{ "(a)\\1", "u", true },
    .{ "(a)\\2", "", true },
    .{ "(a)\\2", "u", false },
    .{ "\\8", "", true },
    .{ "\\8", "u", false },
    .{ "\\9", "", true },
    .{ "\\10", "", true },
    .{ "(((((((((((a)))))))))))\\11", "", true },
    .{ "\\0", "", true },
    .{ "\\0", "u", true },
    .{ "\\00", "", true },
    .{ "\\00", "u", false },
    .{ "\\01", "", true },
    .{ "\\07", "", true },
    .{ "\\012", "", true },
    .{ "\\377", "", true },
    .{ "\\400", "", true },
    .{ "\\c", "", true },
    .{ "\\c", "u", false },
    .{ "\\cA", "", true },
    .{ "\\cA", "u", true },
    .{ "\\c1", "", true },
    .{ "\\c_", "", true },
    .{ "[\\c1]", "", true },
    .{ "[\\c_]", "", true },
    .{ "[\\c1]", "u", false },
    .{ "[\\c]", "", true },
    .{ "[\\c*]", "", true },
    .{ "\\x", "", true },
    .{ "\\x", "u", false },
    .{ "\\x4", "", true },
    .{ "\\x41", "", true },
    .{ "\\x41", "u", true },
    .{ "\\u", "", true },
    .{ "\\u", "u", false },
    .{ "\\u123", "", true },
    .{ "A", "", true },
    .{ "A", "u", true },
    .{ "\\u{41}", "", true },
    .{ "\\u{41}", "u", true },
    .{ "\\u{110000}", "u", false },
    .{ "\\u{10FFFF}", "u", true },
    .{ "\\u{0000000041}", "u", true },
    .{ "\\u{}", "u", false },
    .{ "\u{1f600}", "u", true },
    .{ "\\ud83d", "u", true },
    .{ "\\a", "", true },
    .{ "\\a", "u", false },
    .{ "\\e", "", true },
    .{ "\\-", "", true },
    .{ "\\-", "u", false },
    .{ "\\/", "u", true },
    .{ "\\.", "u", true },
    .{ "\\_", "", true },
    .{ "\\_", "u", false },
    .{ "\\\u{e9}", "", true },
    .{ "\\\u{e9}", "u", false },
    .{ "\\p", "", true },
    .{ "\\p", "u", false },
    .{ "\\p{L}", "", true },
    .{ "\\p{L}", "u", true },
    .{ "\\p{Lu}", "u", true },
    .{ "\\p{lu}", "u", false },
    .{ "\\p{Uppercase_Letter}", "u", true },
    .{ "\\p{digit}", "u", true },
    .{ "\\p{punct}", "u", true },
    .{ "\\p{Combining_Mark}", "u", true },
    .{ "\\p{gc=Lu}", "u", true },
    .{ "\\p{General_Category=Lu}", "u", true },
    .{ "\\p{General_Category=Greek}", "u", false },
    .{ "\\p{sc=Greek}", "u", true },
    .{ "\\p{sc=Grek}", "u", true },
    .{ "\\p{Script=Qaai}", "u", true },
    .{ "\\p{scx=Grek}", "u", true },
    .{ "\\p{Script_Extensions=Latin}", "u", true },
    .{ "\\p{Greek}", "u", false },
    .{ "\\p{Script}", "u", false },
    .{ "\\p{sc}", "u", false },
    .{ "\\p{Alphabetic}", "u", true },
    .{ "\\p{Alpha}", "u", true },
    .{ "\\p{Any}", "u", true },
    .{ "\\p{ASCII}", "u", true },
    .{ "\\p{Assigned}", "u", true },
    .{ "\\p{space}", "u", true },
    // V8 takes any of ICU's aliases of a property it supports; ECMA-262's table gives White_Space
    // `space` alone, not PropertyAliases.txt's `WSpace`.
    .{ "\\p{WSpace}", "u", false },
    .{ "\\p{White_Space}", "u", true },
    .{ "\\p{Other_Alphabetic}", "u", false },
    .{ "\\p{Hyphen}", "u", false },
    .{ "\\p{Emoji}", "u", true },
    .{ "\\p{Bidi_M}", "u", true },
    .{ "\\p{CWKCF}", "u", true },
    .{ "\\p{RGI_Emoji}", "u", false },
    .{ "\\p{RGI_Emoji}", "v", true },
    .{ "\\P{RGI_Emoji}", "v", false },
    .{ "\\p{Basic_Emoji}", "v", true },
    .{ "\\p{L", "u", false },
    .{ "\\p{}", "u", false },
    .{ "\\p{=L}", "u", false },
    .{ "\\p{gc=}", "u", false },
    .{ "\\pL", "u", false },
    .{ "\\P{L}", "u", true },
    .{ "\\p{^L}", "u", false },
    .{ "\\p{L}+", "u", true },
    .{ "[\\p{L}]", "u", true },
    .{ "[^\\p{L}]", "u", true },
    .{ "[\\p{L}-z]", "u", false },
    .{ "[\\p{L}-z]", "", false },
    .{ "[a-z]", "", true },
    .{ "[z-a]", "", false },
    .{ "[z-a]", "u", false },
    .{ "[a-]", "", true },
    .{ "[-a]", "", true },
    .{ "[a-b-c]", "", true },
    .{ "[--a]", "", true },
    .{ "[a-\\d]", "", true },
    .{ "[a-\\d]", "u", false },
    .{ "[\\d-z]", "", true },
    .{ "[\\d-z]", "u", false },
    .{ "[\\w-\\d]", "", true },
    .{ "[]", "", true },
    .{ "[^]", "", true },
    .{ "[]", "u", true },
    .{ "[^]", "u", true },
    .{ "[]]", "", true },
    .{ "[[]", "", true },
    .{ "[[]", "u", true },
    .{ "[a", "", false },
    .{ "[\\]]", "", true },
    .{ "[\\b]", "", true },
    .{ "[\\B]", "", true },
    .{ "[\\B]", "u", false },
    .{ "[\\-]", "", true },
    .{ "[\\-]", "u", true },
    .{ "[\\1]", "", true },
    .{ "[\\1]", "u", false },
    .{ "[\\8]", "", true },
    .{ "[\\8]", "u", false },
    .{ "[\\0]", "u", true },
    .{ "[\\00]", "u", false },
    .{ "[\\k]", "", true },
    .{ "[\\k](?<n>a)", "", false },
    .{ "[\\k]", "u", false },
    .{ "[\\q]", "", true },
    .{ "[\\q{a}]", "u", false },
    .{ "[\\q{a}]", "v", true },
    .{ "[a&&b]", "", true },
    .{ "[a&&b]", "u", true },
    .{ "[a&&b]", "v", true },
    .{ "[a&&&b]", "v", false },
    .{ "[&&a]", "v", false },
    .{ "[a&&]", "v", false },
    .{ "[a--b]", "v", true },
    .{ "[a--b--c]", "v", true },
    .{ "[a&&b--c]", "v", false },
    .{ "[a--b&&c]", "v", false },
    .{ "[ab&&c]", "v", false },
    .{ "[a&&bc]", "v", false },
    .{ "[a-z&&b]", "v", false },
    .{ "[[a-z]&&b]", "v", true },
    .{ "[[a-z]--[aeiou]]", "v", true },
    .{ "[\\w&&\\d]", "v", true },
    .{ "[\\w--\\d]", "v", true },
    .{ "[\\p{L}&&\\p{Lu}]", "v", true },
    .{ "[a-z]", "v", true },
    .{ "[z-a]", "v", false },
    .{ "[a-]", "v", false },
    .{ "[-a]", "v", false },
    .{ "[a-b-c]", "v", false },
    .{ "[(]", "v", false },
    .{ "[)]", "v", false },
    .{ "[{]", "v", false },
    .{ "[}]", "v", false },
    .{ "[/]", "v", false },
    .{ "[|]", "v", false },
    .{ "[\\(]", "v", true },
    .{ "[\\-]", "v", true },
    .{ "[\\&]", "v", true },
    .{ "[\\!]", "v", true },
    .{ "[\\q{abc|d|}]", "v", true },
    .{ "[^\\q{abc}]", "v", false },
    .{ "[^\\q{a|b}]", "v", true },
    .{ "[^\\q{}]", "v", false },
    .{ "[^\\q{a}]", "v", true },
    .{ "[\\q{abc}&&a]", "v", true },
    .{ "[^[\\q{ab}]]", "v", false },
    .{ "[^[\\q{ab}]&&a]", "v", true },
    .{ "[^\\q{ab}--a]", "v", false },
    .{ "[^a--\\q{ab}]", "v", true },
    .{ "[^\\q{ab}&&\\q{cd}]", "v", false },
    .{ "[^\\q{ab}&&a]", "v", true },
    .{ "[\\q{a\\|b}]", "v", true },
    .{ "[\\q{a]", "v", false },
    .{ "[\\p{RGI_Emoji}]", "v", true },
    .{ "[^\\p{RGI_Emoji}]", "v", false },
    .{ "[^[^\\p{RGI_Emoji}]]", "v", false },
    .{ "[\\p{RGI_Emoji}--\\q{x}]", "v", true },
    .{ "[^\\p{RGI_Emoji}--\\q{x}]", "v", false },
    .{ "[^\\p{L}--\\p{RGI_Emoji}]", "v", true },
    .{ "[aa]", "v", true },
    .{ "[a&&a]", "v", true },
    .{ "[!!]", "v", false },
    .{ "[##]", "v", false },
    .{ "[a!!b]", "v", false },
    .{ "[!]", "v", true },
    .{ "[$$]", "v", false },
    .{ "[a^^]", "v", false },
    .{ "[^^^]", "v", false },
    .{ "[^]", "v", true },
    .{ "[]", "v", true },
    .{ "[[]]", "v", true },
    .{ "[[[[a]]]]", "v", true },
    .{ "[a[b]c]", "v", true },
    .{ "[[a]&&[b]]", "v", true },
    .{ "[a&&[b]]", "v", true },
    .{ "[\\d-a]", "v", false },
    .{ "[a-\\d]", "v", false },
    .{ "[\\b]", "v", true },
    .{ "[\\b-z]", "v", true },
    .{ "\\b", "v", true },
    .{ ".", "v", true },
    .{ "x{1,2}?", "v", true },
    .{ "(?i:[a])", "v", true },
    .{ "\u{1f600}+", "", true },
    .{ "\u{1f600}+", "u", true },
    .{ "[\u{1f600}]", "", true },
    .{ "[\u{1f600}]", "u", true },
    .{ "[\u{1f600}-\u{1f602}]", "", false },
    .{ "[\u{1f600}-\u{1f602}]", "u", true },
    .{ "[a-\u{1f600}]", "", true },
    .{ "\\\u{1f600}", "", true },
    .{ "\\\u{1f600}", "u", false },
    .{ "a\\", "", false },
    .{ "a\\", "u", false },
    .{ "[\\", "", false },
};

test "every case is valid or not as ECMA-262 has it" {
    var wrong: usize = 0;
    for (cases) |case| {
        var d: parse_mod.Diagnostic = .{};
        const valid = try validate(case[0], case[1], &d);
        if (valid != case[2]) {
            std.debug.print("/{s}/{s}: expected {}, got {} ({t})\n", .{ case[0], case[1], case[2], valid, d.reason });
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

fn syntaxOf(flags: []const u8) Syntax {
    return .{
        .dialect = .ecmascript,
        .unicode = std.mem.findScalar(u8, flags, 'u') != null,
        .unicode_sets = std.mem.findScalar(u8, flags, 'v') != null,
    };
}

/// The AST of `pattern` written back as a canonical text.
fn shape(arena: std.mem.Allocator, pattern: []const u8, flags: []const u8) ![]const u8 {
    const ast = try parse_mod.parse(arena, .init(pattern), syntaxOf(flags), .{}, null);
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(&ast, ast.root, &out.writer);
    return out.written();
}

fn write(ast: *const Ast, index: Ast.Index, w: *std.Io.Writer) !void {
    switch (ast.node(index).kind) {
        .empty => try w.writeAll("()"),
        .literal => |cp| try w.print("{x}", .{cp}),
        .byte => return error.NotEcmaScript,
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
        .flags => try w.writeAll("(?flags)"),
        .alternation => |s| for (ast.childrenOf(s), 0..) |child, i| {
            if (i != 0) try w.writeAll("|");
            try write(ast, child, w);
        },
        .concat => |s| {
            try w.writeAll("<");
            for (ast.childrenOf(s), 0..) |child, i| {
                if (i != 0) try w.writeAll(" ");
                try write(ast, child, w);
            }
            try w.writeAll(">");
        },
        .lookaround => |l| {
            try w.print("({t}{s}:", .{ l.direction, if (l.negated) "!" else "" });
            try write(ast, l.sub, w);
            try w.writeAll(")");
        },
        .backreference => |r| switch (r) {
            .number => |n| try w.print("\\{d}", .{n}),
            .name => |name| try w.print("\\k<{s}>", .{name}),
        },
    }
}

fn writeClass(ast: *const Ast, b: Ast.Bracketed, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(if (b.negated) "[^" else "[");
    try writeItems(ast, ast.itemsOf(b.items), w);
    try w.writeAll("]");
}

fn writeItems(ast: *const Ast, items: []const Ast.ClassItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeAll(" ");
        switch (item) {
            .literal => |cp| try w.print("{x}", .{cp}),
            .byte, .hex_range => return error.WriteFailed,
            .range => |r| try w.print("{x}-{x}", .{ r[0], r[1] }),
            .perl => |p| try w.print("\\{s}{t}", .{ if (p.negated) "!" else "", p.class }),
            .unicode => |u| try w.print("\\p{{{s}{s}}}", .{ if (u.negated) "^" else "", u.name }),
            .ascii => |a| try w.print("[:{t}:]", .{a.class}),
            .nested => |n| try writeClass(ast, n, w),
            .operation => |o| {
                try w.writeAll("(");
                try writeItems(ast, ast.itemsOf(o.lhs), w);
                try w.print(" {t} ", .{o.op});
                try writeItems(ast, ast.itemsOf(o.rhs), w);
                try w.writeAll(")");
            },
            .strings => |s| {
                try w.writeAll("q{");
                for (ast.stringsOf(s), 0..) |string, j| {
                    if (j != 0) try w.writeAll("|");
                    for (ast.codePointsOf(string)) |cp| try w.print("{x},", .{cp});
                }
                try w.writeAll("}");
            },
        }
    }
}

test "the dialect's forms read to their shapes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const expect = struct {
        fn f(arena: std.mem.Allocator, pattern: []const u8, flags: []const u8, want: []const u8) !void {
            const got = try shape(arena, pattern, flags);
            if (!std.mem.eql(u8, got, want)) {
                std.debug.print("/{s}/{s}: {s}\n", .{ pattern, flags, got });
                return error.TestExpectedEqual;
            }
        }
    }.f;
    try expect(a, "(?=a)(?!b)(?<=c)(?<!d)", "", "<(ahead:61) (ahead!:62) (behind:63) (behind!:64)>");
    try expect(a, "(?<n>a)\\k<n>\\1", "u", "<(#1 n:61) \\k<n> \\1>");
    try expect(a, "(?<\\u0061b>.)\\k<ab>", "", "<(#1 ab:.) \\k<ab>>");
    try expect(a, "(?i-s:a)", "", "(?1-4:61)");
    // Annex B: past the groups, octal; `\8` itself; `]` and `{` themselves; `\c` alone a backslash.
    try expect(a, "(a)\\2\\8]{\\c", "", "<(#1:61) 2 38 5d 7b 5c 63>");
    try expect(a, "\\u{41}", "", "75{41,41}");
    try expect(a, "\\u{41}", "u", "41");
    try expect(a, "\\ud83d\\ude00", "u", "1f600");
    try expect(a, "\\ud83d\\ude00", "", "<d83d de00>");
    // Without `u`, a code point past U+FFFF is two code units, and a quantifier takes the second.
    try expect(a, "\u{1F600}+", "", "<d83d de00{1,}>");
    try expect(a, "\u{1F600}+", "u", "1f600{1,}");
    try expect(a, "[\u{1F600}]", "", "[d83d de00]");
    try expect(a, "[a-\u{1F600}]", "", "[61-d83d de00]");
    try expect(a, "[\\d-z]", "", "[\\digit 2d 7a]");
    try expect(a, "[]", "", "[]");
    try expect(a, "[^]", "u", "[^]");
    try expect(a, "(?=a)*", "", "(ahead:61){0,}");
}

test "validating takes a count of any size; compiling holds it to the limit" {
    try testing.expect(try validate("a{2,99999999999999999999}", "", null));
    try testing.expect(!try validate("a{99999999999999999999,99999999999999999998}", "", null));
    try testing.expect(try validate("a{099,100}", "", null));
}

test "v's class set expressions read to operations, nested classes and strings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("[([61-7a] difference [61 65 69 6f 75])]", try shape(a, "[[a-z]--[aeiou]]", "v"));
    try testing.expectEqualStrings("[(([\\word] intersection \\p{L}) intersection [^61])]", try shape(a, "[[\\w]&&\\p{L}&&[^a]]", "v"));
    try testing.expectEqualStrings("[q{61,62,63,|64,|} 78-79]", try shape(a, "[\\q{abc|d|}x-y]", "v"));
    try testing.expectEqualStrings("[q{61,7c,62,}]", try shape(a, "[\\q{a\\|b}]", "v"));
}

test "every refusal names its reason and points at its span" {
    const Case = struct { []const u8, []const u8, parse_mod.Reason, u32, u32 };
    const refusals = [_]Case{
        .{ "a{3,2}", "", .repetition_count_out_of_order, 1, 6 },
        .{ "a**", "", .repetition_missing, 2, 3 },
        .{ "(?<=a)*", "", .repetition_missing, 6, 7 },
        .{ "(?=a)*", "u", .repetition_missing, 5, 6 },
        .{ "]", "u", .lone_syntax_character, 0, 1 },
        .{ "a{", "u", .lone_syntax_character, 1, 2 },
        .{ "(?P<n>a)", "", .group_opening_invalid, 0, 3 },
        .{ "(?-:a)", "", .flags_empty, 0, 4 },
        .{ "(?ii:a)", "", .flag_repeated, 3, 4 },
        .{ "(?x:a)", "", .group_opening_invalid, 0, 3 },
        .{ "(?ix:a)", "", .flag_unrecognized, 3, 4 },
        .{ "(?<a>x)(?<a>y)", "", .group_name_duplicate, 10, 11 },
        .{ "(?<1a>x)", "", .group_name_invalid, 3, 4 },
        .{ "\\k<n>(?<m>a)", "", .backreference_undefined, 0, 5 },
        .{ "(a)\\2", "u", .backreference_undefined, 3, 5 },
        .{ "\\k", "u", .named_reference_invalid, 0, 2 },
        .{ "\\a", "u", .escape_unrecognized, 0, 2 },
        .{ "\\x4", "u", .escape_hex_invalid, 0, 2 },
        .{ "\\u{110000}", "u", .code_point_invalid, 0, 9 },
        .{ "\\p{Klingon}", "u", .unicode_property_unknown, 0, 11 },
        .{ "\\p{sc=Greeek}", "u", .unicode_property_unknown, 0, 13 },
        .{ "\\p{L", "u", .unicode_class_invalid, 0, 4 },
        .{ "[z-a]", "", .class_range_out_of_order, 1, 4 },
        .{ "[\\d-z]", "u", .class_range_bad_end, 1, 5 },
        .{ "[a", "", .unclosed_class, 0, 2 },
        .{ "[ab&&c]", "v", .class_set_operation_mixed, 3, 5 },
        .{ "[a&&b--c]", "v", .class_set_operation_mixed, 5, 7 },
        .{ "[a-z&&b]", "v", .class_set_operation_mixed, 4, 6 },
        .{ "[&&a]", "v", .class_set_operand_missing, 1, 3 },
        .{ "[a&&]", "v", .class_set_operand_missing, 4, 5 },
        .{ "[a&&&b]", "v", .class_set_character_reserved, 4, 5 },
        .{ "[!!]", "v", .class_set_character_reserved, 1, 3 },
        .{ "[(]", "v", .class_set_character_reserved, 1, 2 },
        .{ "[^\\q{ab}]", "v", .class_strings_negated, 0, 9 },
        .{ "\\P{RGI_Emoji}", "v", .class_strings_negated, 0, 13 },
        .{ "(a", "", .unclosed_group, 0, 1 },
        .{ "a)", "", .unopened_group, 1, 2 },
        .{ "a\\", "", .escape_unexpected_end, 1, 2 },
        .{ "\xff", "", .invalid_utf8, 0, 1 },
    };
    for (refusals) |case| {
        var d: parse_mod.Diagnostic = .{};
        try testing.expect(!try validate(case[0], case[1], &d));
        testing.expectEqual(case[2], d.reason) catch |err| {
            std.debug.print("/{s}/{s}\n", .{ case[0], case[1] });
            return err;
        };
        testing.expectEqual(Ast.Span{ .start = case[3], .end = case[4] }, d.span) catch |err| {
            std.debug.print("/{s}/{s}\n", .{ case[0], case[1] });
            return err;
        };
    }
}

test "validate's flags are RegExp's: dgimsuvy, each once, not u with v" {
    var d: parse_mod.Diagnostic = .{};
    try testing.expect(try validate("a", "dgimsuy", null));
    try testing.expect(try validate("a", "v", null));
    try testing.expect(!try validate("a", "uv", &d));
    try testing.expectEqual(parse_mod.Reason.regexp_flag_invalid, d.reason);
    try testing.expectEqual(Ast.Span{ .start = 1, .end = 2 }, d.span);
    try testing.expect(!try validate("a", "gg", &d));
    try testing.expectEqual(Ast.Span{ .start = 1, .end = 2 }, d.span);
    try testing.expect(!try validate("a", "x", &d));
    try testing.expectEqual(Ast.Span{ .start = 0, .end = 1 }, d.span);
}

test "the limits: a long pattern or deep nesting is too large, not invalid; a count only when compiling" {
    var d: parse_mod.Diagnostic = .{};
    try testing.expectError(error.TooLarge, ecma.validate(testing.allocator, .init("aaaaaaaaa"), "", .{ .pattern = .fromRaw(8) }, &d));
    try testing.expectEqual(parse_mod.Reason.pattern_too_long, d.reason);
    try testing.expectError(error.TooLarge, ecma.validate(testing.allocator, .init("((((a))))"), "", .{ .nesting = .literal(3) }, &d));
    try testing.expectError(error.TooLarge, ecma.validate(testing.allocator, .init("[[[[a]]]]"), "v", .{ .nesting = .literal(3) }, &d));
    try testing.expect(try ecma.validate(testing.allocator, .init("a{1001}"), "", .{}, null));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.TooLarge, parse_mod.parse(arena_state.allocator(), .init("a{1001}"), syntaxOf(""), .{}, &d));
    try testing.expectEqual(parse_mod.Reason.repetition_count_too_large, d.reason);
    try testing.expectError(error.Invalid, parse_mod.parse(arena_state.allocator(), .init("a"), .{ .dialect = .ecmascript, .ignore_whitespace = true }, .{}, &d));
    try testing.expectEqual(parse_mod.Reason.syntax_not_in_dialect, d.reason);
    try testing.expectError(error.Invalid, parse_mod.parse(arena_state.allocator(), .init("a"), .{ .unicode_sets = true }, .{}, &d));
}

const alphabet = "ab()[]{}|*+?^$.\\-&!:<>=,0123456789dDsSwWpPbBkqcxuLn_ ";
const flag_sets = [_][]const u8{ "", "u", "v" };

fn anyPattern(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const n = shakedown.gen.intRange(s, usize, 0, 40);
    const pattern = try case.gpa.alloc(u8, n);
    defer case.gpa.free(pattern);
    // Mostly the grammar's own characters; at times any bytes.
    const raw = shakedown.gen.intRange(s, u8, 0, 3) == 0;
    for (pattern) |*b| b.* = if (raw) shakedown.gen.intRange(s, u8, 0, 255) else alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    const flags = flag_sets[shakedown.gen.intRange(s, usize, 0, flag_sets.len - 1)];
    case.note("/{s}/{s}", .{ pattern, flags });
    var d: parse_mod.Diagnostic = .{};
    const valid = try ecma.validate(case.gpa, .init(pattern), flags, .{ .nesting = .literal(1024) }, &d);
    if (!valid) {
        try testing.expect(d.reason != .none);
        try testing.expect(d.span.start <= d.span.end and d.span.end <= pattern.len);
    }
    // Compiling reads what validating reads, but for counts past the limit.
    var arena_state: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena_state.deinit();
    if (parse_mod.parse(arena_state.allocator(), .init(pattern), syntaxOf(flags), .{ .nesting = .literal(1024), .repetition = .literal(100_000) }, &d)) |ast| {
        try testing.expect(valid);
        for (ast.nodes) |node| try testing.expect(node.span.start <= node.span.end and node.span.end <= pattern.len);
    } else |err| switch (err) {
        error.Invalid => try testing.expect(!valid),
        error.TooLarge => try testing.expectEqual(parse_mod.Reason.repetition_count_too_large, d.reason),
        error.OutOfMemory => return err,
    }
}

test "fuzz: any pattern of regex syntax is valid or refused by name, and compiling agrees" {
    try shakedown.check(testing.allocator, {}, anyPattern, .{ .cases = 5000, .seed = 0xec3a });
}
