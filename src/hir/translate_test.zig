//! Translation: each dialect's flags, classes and assertions, and what is refused, by name.
const std = @import("std");
const shakedown = @import("shakedown");
const Ast = @import("../syntax/Ast.zig");
const parse_mod = @import("../syntax/parse.zig");
const Syntax = @import("../Syntax.zig");
const Hir = @import("Hir.zig");
const translate_mod = @import("translate.zig");
const xenoglyph = @import("xenoglyph");
const Limits = @import("../Limits.zig");
const testing = std.testing;

const ecma: Syntax = .{ .dialect = .ecmascript };
const annex_b: Syntax = .{ .dialect = .ecmascript, .unicode = false };
const sets: Syntax = .{ .dialect = .ecmascript, .unicode_sets = true };

fn with(base: Syntax, case_insensitive: bool) Syntax {
    var s = base;
    s.case_insensitive = case_insensitive;
    return s;
}

const State = struct {
    arena_state: std.heap.ArenaAllocator = .init(testing.allocator),
    fn arena(s: *State) std.mem.Allocator {
        return s.arena_state.allocator();
    }
    fn deinit(s: *State) void {
        s.arena_state.deinit();
    }
};

fn hirOf(a: std.mem.Allocator, pattern: []const u8, syntax: Syntax, d: ?*parse_mod.Diagnostic) !Hir {
    const ast = try parse_mod.parse(a, .init(pattern), syntax, .{}, d);
    const held = try a.create(Ast);
    held.* = ast;
    return translate_mod.translate(a, held, syntax, .{}, d);
}

fn text(a: std.mem.Allocator, pattern: []const u8, syntax: Syntax) ![]const u8 {
    const hir = try hirOf(a, pattern, syntax, null);
    var out: std.Io.Writer.Allocating = .init(a);
    try write(&hir, hir.root, &out.writer);
    return out.written();
}

fn write(hir: *const Hir, index: Hir.Index, w: *std.Io.Writer) anyerror!void {
    switch (hir.node(index)) {
        .empty => try w.writeAll("()"),
        .literal => |bytes| {
            try w.writeAll("\"");
            for (bytes) |b| if (b < 0x80) try w.writeByte(b) else try w.print("\\x{x}", .{b});
            try w.writeAll("\"");
        },
        .unicode_class => |r| {
            try w.writeAll("[");
            for (r, 0..) |x, i| try w.print("{s}{x}-{x}", .{ if (i == 0) "" else " ", x[0], x[1] });
            try w.writeAll("]");
        },
        .byte_class => |r| {
            try w.writeAll("b[");
            for (r, 0..) |x, i| try w.print("{s}{x}-{x}", .{ if (i == 0) "" else " ", x[0], x[1] });
            try w.writeAll("]");
        },
        .look => |l| try w.print("@{t}", .{l}),
        .repetition => |r| {
            try write(hir, r.sub, w);
            if (r.max) |max| try w.print("{{{d},{d}}}", .{ r.min, max }) else try w.print("{{{d},}}", .{r.min});
            if (!r.greedy) try w.writeAll("?");
        },
        .capture => |c| {
            try w.print("(#{d}:", .{c.index});
            try write(hir, c.sub, w);
            try w.writeAll(")");
        },
        .concat => |s| {
            try w.writeAll("<");
            for (hir.childrenOf(s), 0..) |c, i| {
                if (i != 0) try w.writeAll(" ");
                try write(hir, c, w);
            }
            try w.writeAll(">");
        },
        .alternation => |s| for (hir.childrenOf(s), 0..) |c, i| {
            if (i != 0) try w.writeAll("|");
            try write(hir, c, w);
        },
        .lookahead => |l| {
            try w.print("(ahead{s}:", .{if (l.negated) "!" else ""});
            try write(hir, l.sub, w);
            try w.writeAll(")");
        },
    }
}

fn expectText(pattern: []const u8, syntax: Syntax, want: []const u8) !void {
    var s: State = .{};
    defer s.deinit();
    const got = try text(s.arena(), pattern, syntax);
    testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("/{s}/\n", .{pattern});
        return err;
    };
}

/// Whether the class `pattern` translates to takes `cp`.
fn takes(pattern: []const u8, syntax: Syntax, cp: u21) !bool {
    var s: State = .{};
    defer s.deinit();
    const hir = try hirOf(s.arena(), pattern, syntax, null);
    return switch (hir.node(hir.root)) {
        .unicode_class => |r| for (r) |x| {
            if (cp >= x[0] and cp <= x[1]) break true;
        } else false,
        .literal => |bytes| blk: {
            var buffer: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buffer);
            break :blk std.mem.eql(u8, bytes, buffer[0..n]);
        },
        else => error.NotAClass,
    };
}

fn expectRefused(pattern: []const u8, syntax: Syntax, err: anyerror, reason: parse_mod.Reason) !void {
    var s: State = .{};
    defer s.deinit();
    var d: parse_mod.Diagnostic = .{};
    testing.expectError(err, hirOf(s.arena(), pattern, syntax, &d)) catch |e| {
        std.debug.print("/{s}/\n", .{pattern});
        return e;
    };
    testing.expectEqual(reason, d.reason) catch |e| {
        std.debug.print("/{s}/\n", .{pattern});
        return e;
    };
}

test "Rust: flags apply to the rest of their group, literals join, repetitions simplify" {
    try expectText("abc", .{}, "\"abc\"");
    try expectText("(?:ab)c", .{}, "\"abc\"");
    try expectText("(?i)k", .{}, "[4b-4b 6b-6b 212a-212a]");
    try expectText("(?-u)(?i)k", .{}, "b[4b-4b 6b-6b]");
    try expectText("(?i)1a(?-i)b", .{}, "<\"1\" [41-41 61-61] \"b\">");
    try expectText("(?:(?i)a)b", .{}, "<[41-41 61-61] \"b\">");
    try expectText("(?i)a|b", .{}, "[41-41 61-61]|[42-42 62-62]");
    try expectText("(a)|(?P<n>b)", .{}, "(#1:\"a\")|(#2:\"b\")");
    try expectText("a{1}", .{}, "\"a\"");
    try expectText("a{0}", .{}, "()");
    try expectText("a{2,3}?", .{}, "\"a\"{2,3}?");
    try expectText("(?U)a*", .{}, "\"a\"{0,}?");
    try expectText("(?U)a*?", .{}, "\"a\"{0,}");
    try expectText("", .{}, "()");
}

test "Rust: dot and the assertions, by flag" {
    try expectText(".", .{}, "[0-9 b-10ffff]");
    try expectText("(?s).", .{}, "[0-10ffff]");
    try expectText("(?R).", .{}, "[0-9 b-c e-10ffff]");
    try expectText("(?-u:.)", .{ .utf8 = false }, "b[0-9 b-ff]");
    try expectRefused("(?-u:.)", .{}, error.Invalid, .invalid_utf8_class);
    try expectText("^$", .{}, "<@start_text @end_text>");
    try expectText("(?m)^$", .{}, "<@start_line_lf @end_line_lf>");
    try expectText("(?mR)^$", .{}, "<@start_line_crlf @end_line_crlf>");
    try expectText("\\A\\z", .{}, "<@start_text @end_text>");
    try expectText("\\b\\B", .{}, "<@word_unicode @not_word_unicode>");
    try expectText("(?-u)\\b\\B", .{}, "<@word_ascii @not_word_ascii>");
    try expectText("\\b{start}\\b{end}\\b{start-half}\\b{end-half}", .{}, "<@word_start_unicode @word_end_unicode @word_start_half_unicode @word_end_half_unicode>");
    try expectText("(?-u)\\<\\>", .{}, "<@word_start_ascii @word_end_ascii>");
}

test "Rust: classes, Unicode's and ASCII's, and bytes" {
    try expectText("[a-c&&[^b]]", .{}, "[61-61 63-63]");
    try expectText("[a-c--b]", .{}, "[61-61 63-63]");
    try expectText("[a-c~~b-d]", .{}, "[61-61 64-64]");
    try expectText("[[:digit:]]", .{}, "[30-39]");
    try expectText("[[:^digit:]x]", .{}, "[0-2f 3a-10ffff]");
    try expectText("(?-u)\\d", .{}, "b[30-39]");
    try expectText("(?-u)\\s", .{}, "b[9-d 20-20]");
    try expectText("(?-u)\\w", .{}, "b[30-39 41-5a 5f-5f 61-7a]");
    try expectRefused("(?-u)\\W", .{}, error.Invalid, .invalid_utf8_class);
    try expectText("(?-u)\\W", .{ .utf8 = false }, "b[0-2f 3a-40 5b-5e 60-60 7b-ff]");
    try expectRefused("(?-u)[^a]", .{}, error.Invalid, .invalid_utf8_class);
    // `\xNN` is the byte without `u`, the code point with it; a typed character is the character.
    try expectText("\\xFF", .{}, "\"\\xc3\\xbf\"");
    try expectText("(?-u)\\xFF", .{ .utf8 = false }, "\"\\xff\"");
    try expectRefused("(?-u)\\xFF", .{}, error.Invalid, .invalid_utf8_class);
    try expectText("(?-u)\u{e9}", .{}, "\"\\xc3\\xa9\"");
    try expectText("(?-u)[\\xE0-\\xFF]", .{ .utf8 = false }, "b[e0-ff]");
    try expectRefused("(?-u)[\u{e9}]", .{}, error.Invalid, .unicode_not_allowed);
    try expectRefused("(?-u)\\pL", .{}, error.Invalid, .unicode_not_allowed);
    // regex-syntax refuses, matching UTF-8, a class of bytes past ASCII where it is made: each
    // `\xNN`, each Perl or ASCII class and each bracket after its own complement.
    try expectRefused("(?-u)[^\\x80-\\xFF]", .{}, error.Invalid, .invalid_utf8_class);
    try expectText("(?-u)[^\\x80-\\xFF]", .{ .utf8 = false }, "b[0-7f]");
    try expectRefused("(?-u)[^\\W]", .{}, error.Invalid, .invalid_utf8_class);
    try expectRefused("(?-u)[^[^a]]", .{}, error.Invalid, .invalid_utf8_class);
    try expectRefused("(?-u)[^[:^alpha:]]", .{}, error.Invalid, .invalid_utf8_class);
    try expectText("(?-u)[^[:^alpha:]]", .{ .utf8 = false }, "b[41-5a 61-7a]");
    try expectText("(?-u)[\\x41-\\x43]", .{}, "b[41-43]");
    try testing.expect(try takes("\\d", .{}, 0x660));
    try testing.expect(try takes("\\s", .{}, 0x2028));
    try testing.expect(try takes("\\w", .{}, 0x300));
    try testing.expect(try takes("\\w", .{}, 0x200d));
    try testing.expect(!try takes("\\W", .{}, 'a'));
}

test "Rust: Unicode names compare loosely, a script alone is its extensions, and folding comes before the complement" {
    try testing.expect(try takes("\\p{Greek}", .{}, 0x3b1));
    // U+0342 is Inherited, and Greek by its extensions.
    try testing.expect(try takes("\\p{Greek}", .{}, 0x342));
    try testing.expect(!try takes("\\p{sc=Greek}", .{}, 0x342));
    try testing.expect(try takes("\\p{scx=Greek}", .{}, 0x342));
    try testing.expect(try takes("\\p{  is_greek }", .{}, 0x3b1));
    try testing.expect(try takes("\\pL", .{}, 'a'));
    try testing.expect(try takes("\\p{lu}", .{}, 'A'));
    try testing.expect(try takes("\\p{uppercase-letter}", .{}, 'A'));
    try testing.expect(try takes("\\p{gc=Lu}", .{}, 'A'));
    try testing.expect(try takes("\\p{sc}", .{}, '$'));
    try testing.expect(try takes("\\p{Alphabetic}", .{}, 'a'));
    try testing.expect(try takes("\\p{any}", .{}, 0x10ffff));
    try testing.expect(try takes("\\p{ascii}", .{}, 'a'));
    try testing.expect(!try takes("\\p{ascii}", .{}, 0xe9));
    try testing.expect(!try takes("\\p{assigned}", .{}, 0x378));
    try testing.expect(try takes("(?i)\\p{Lu}", .{}, 'a'));
    try testing.expect(!try takes("(?i)\\P{Lu}", .{}, 'a'));
    try testing.expect(!try takes("(?i)\\P{Lu}", .{}, 'A'));
    try expectRefused("\\p{Klingon}", .{}, error.Invalid, .unicode_property_unknown);
    try expectRefused("\\p{gc=Klingon}", .{}, error.Invalid, .unicode_property_unknown);
    try expectRefused("\\p{Script}", .{}, error.Invalid, .unicode_property_unknown);
    try expectRefused("\\p{age=3.0}", .{}, error.Unsupported, .unsupported_unicode_property);
    try expectRefused("\\p{wb=Numeric}", .{}, error.Unsupported, .unsupported_unicode_property);
    // Any, ASCII and Assigned are General_Category's values too, and a leading `is` is dropped
    // from every name, as regex-syntax reads them.
    try testing.expect(try takes("\\p{gc=Any}", .{}, 0x10ffff));
    try testing.expect(try takes("\\p{gc=ASCII}", .{}, 'a'));
    try testing.expect(!try takes("\\p{general_category=assigned}", .{}, 0x378));
    try testing.expect(try takes("\\p{IsAny}", .{}, 0x10ffff));
    try testing.expect(try takes("\\p{is_ascii}", .{}, 'a'));
    try testing.expect(!try takes("\\p{isAssigned}", .{}, 0x378));
    try expectRefused("\\p{isage=3.0}", .{}, error.Unsupported, .unsupported_unicode_property);
    try expectRefused("\\p{gc=Klingon}", .{}, error.Invalid, .unicode_property_unknown);
}

test "ECMAScript: the classes and the assertions are ECMA-262's, in each mode" {
    try expectText("\\d", ecma, "[30-39]");
    try expectText("\\w", ecma, "[30-39 41-5a 5f-5f 61-7a]");
    for ([_]Syntax{ ecma, annex_b, sets }) |syntax| {
        for ([_]u21{ 9, 0xb, 0xc, ' ', 0xa0, 0xfeff, 0x2003, '\n', '\r', 0x2028, 0x2029 }) |cp| try testing.expect(try takes("\\s", syntax, cp));
        try testing.expect(!try takes("\\s", syntax, 0x85));
        try testing.expect(!try takes("\\d", syntax, 0x660));
        try testing.expect(!try takes(".", syntax, 0x2028));
        try testing.expect(try takes(".", syntax, 0x85));
    }
    // Under `u` or `v` with `i`, `\w` takes U+017F and U+212A, and `\W` leaves them and what folds with them.
    for ([_]Syntax{ ecma, sets }) |syntax| {
        const i = with(syntax, true);
        try testing.expect(try takes("\\w", i, 0x17f));
        try testing.expect(try takes("\\w", i, 0x212a));
        try testing.expect(!try takes("\\W", i, 0x17f));
        try testing.expect(!try takes("\\W", i, 'S'));
        try testing.expect(!try takes("\\W", i, 'k'));
        try testing.expect(!try takes("\\w", syntax, 0x17f));
    }
    try testing.expect(!try takes("\\w", with(annex_b, true), 0x17f));
    try expectText("^$", ecma, "<@start_text @end_text>");
    try expectText("^$", blk: {
        var m = ecma;
        m.multi_line = true;
        break :blk m;
    }, "<@start_line_ecma @end_line_ecma>");
    try expectText("\\b\\B", ecma, "<@word_ascii @not_word_ascii>");
    try expectText("\\b\\B", with(ecma, true), "<@word_ecma_folded @not_word_ecma_folded>");
    try expectText("\\b", with(annex_b, true), "@word_ascii");
    try expectText("[]", ecma, "[]");
    try expectText("[^]", ecma, "[0-10ffff]");
    try expectText("(?i:a)b", ecma, "<[41-41 61-61] \"b\">");
    try expectText("(?-i:a)b", with(ecma, true), "<\"a\" [42-42 62-62]>");
}

test "ECMAScript: i closes by Canonicalize without u, by simple folding with it" {
    try expectText("k", with(annex_b, true), "[4b-4b 6b-6b]");
    try expectText("k", with(ecma, true), "[4b-4b 6b-6b 212a-212a]");
    try expectText("[^k]", with(annex_b, true), "[0-4a 4c-6a 6c-10ffff]");
    // `u`: the complement is taken, then closed; `v`: closed, then complemented.
    try testing.expect(try takes("\\P{Lu}", with(ecma, true), 'A'));
    try testing.expect(try takes("\\P{Lu}", with(ecma, true), 'a'));
    try testing.expect(!try takes("\\P{Lu}", with(sets, true), 'A'));
    try testing.expect(!try takes("\\P{Lu}", with(sets, true), 'a'));
    try testing.expect(try takes("[\\P{Lu}]", with(ecma, true), 'A'));
    try testing.expect(!try takes("[^\\P{Lu}]", with(ecma, true), 'A'));
    try testing.expect(try takes("\\p{Lu}", with(ecma, true), 'a'));
    try testing.expect(try takes("\\p{L}", ecma, 'a'));
    try testing.expect(try takes("\\p{Script=Greek}", ecma, 0x3b1));
    try testing.expect(!try takes("\\p{sc=Greek}", ecma, 0x342));
    try testing.expect(try takes("\\p{scx=Greek}", ecma, 0x342));
    try testing.expect(try takes("\\p{Any}", ecma, 0x10ffff));
    try testing.expect(!try takes("\\p{Assigned}", ecma, 0x378));
    try testing.expect(try takes("\\p{ASCII}", ecma, 'a'));
    try testing.expect(try takes("\\p{White_Space}", ecma, ' '));
    try testing.expect(try takes("\\p{space}", ecma, ' '));
}

test "ECMAScript: what it cannot run is refused by name, and a lookahead is kept" {
    try expectRefused("(a)\\1", ecma, error.Unsupported, .unsupported_backreference);
    try expectRefused("(?<n>a)\\k<n>", ecma, error.Unsupported, .unsupported_backreference);
    try expectRefused("(?<=a)b", ecma, error.Unsupported, .unsupported_lookbehind);
    try expectRefused("(?<!a)b", ecma, error.Unsupported, .unsupported_lookbehind);
    try expectRefused("(?=(?=a))", ecma, error.Unsupported, .unsupported_nested_lookaround);
    try expectRefused("(?!(?<=a))", ecma, error.Unsupported, .unsupported_lookbehind);
    try expectRefused("(?=(?!a))", ecma, error.Unsupported, .unsupported_nested_lookaround);
    try expectRefused("\\p{RGI_Emoji}", sets, error.Unsupported, .unsupported_unicode_property);
    try expectRefused("[\\p{RGI_Emoji}]", sets, error.Unsupported, .unsupported_unicode_property);
    try expectText("(?=a)(?!b)c", ecma, "<(ahead:\"a\") (ahead!:\"b\") \"c\">");
    try expectText("(?=(a))(?=(b))", ecma, "<(ahead:(#1:\"a\")) (ahead:(#2:\"b\"))>");
}

test "ECMAScript without u: a code point past U+FFFF is whole or refused" {
    try expectText("\u{1F600}", annex_b, "\"\\xf0\\x9f\\x98\\x80\"");
    try expectText("\\uD83D\\uDE00", annex_b, "\"\\xf0\\x9f\\x98\\x80\"");
    try expectText("a\u{1F600}b", annex_b, "\"a\\xf0\\x9f\\x98\\x80b\"");
    try expectRefused("\u{1F600}+", annex_b, error.Unsupported, .unsupported_code_unit_split);
    try expectRefused("\\uD83D", annex_b, error.Unsupported, .unsupported_code_unit_split);
    try expectRefused("[\u{1F600}]", annex_b, error.Unsupported, .unsupported_code_unit_split);
    try expectRefused("[\\uD800-\\uDBFF]", annex_b, error.Unsupported, .unsupported_code_unit_split);
    // With `u` it is one code point, and a lone surrogate one no text holds.
    try expectText("\u{1F600}+", ecma, "\"\\xf0\\x9f\\x98\\x80\"{1,}");
    try expectText("\\uD83D", ecma, "[]");
}

test "v: strings, longest first, the class at its own length, the empty string last" {
    try expectText("[\\q{abc|d|}x]", sets, "\"abc\"|[64-64 78-78]|()");
    try expectText("[\\q{ab|abc}]", sets, "\"abc\"|\"ab\"");
    try expectText("[\\q{ab}]", sets, "\"ab\"");
    try expectText("[\\q{abc|d}--\\q{abc}]", sets, "\"d\"");
    try expectText("[\\q{abc|d}&&\\q{abc}]", sets, "\"abc\"");
    try expectText("[[a-z]--[aeiou]]", sets, "[62-64 66-68 6a-6e 70-74 76-7a]");
    try expectText("[\\q{AB}]", with(sets, true), "<[41-41 61-61] [42-42 62-62]>");
    try expectText("[\\q{ab}--\\q{AB}]", with(sets, true), "[]");
}

test "chains as long as the pattern are walked, not recursed" {
    var s: State = .{};
    defer s.deinit();
    const a = s.arena();
    var pattern: std.ArrayList(u8) = .empty;
    try pattern.append(a, 'a');
    for (0..20_000) |_| try pattern.appendSlice(a, "{1}");
    _ = try hirOf(a, pattern.items, .{}, null);
    pattern.clearRetainingCapacity();
    try pattern.appendSlice(a, "[a");
    for (0..20_000) |_| try pattern.appendSlice(a, "&&a");
    try pattern.append(a, ']');
    try testing.expectEqualStrings("\"a\"", try text(a, pattern.items, .{}));
    pattern.clearRetainingCapacity();
    for (0..1000) |_| try pattern.appendSlice(a, "(?:");
    try pattern.append(a, 'a');
    for (0..1000) |_| try pattern.append(a, ')');
    const ast = try parse_mod.parse(a, .init(pattern.items), .{}, .{ .nesting = .literal(1024) }, null);
    _ = try translate_mod.translate(a, &ast, .{}, .{}, null);
}

const alphabet = "ab()[]{}|*+?^$.\\-&~:<>=!,019dDsSwWpPbBkqxuLniU_ ";

fn anyTranslation(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const n = shakedown.gen.intRange(s, usize, 0, 32);
    const pattern = try case.gpa.alloc(u8, n);
    for (pattern) |*b| b.* = alphabet[shakedown.gen.intRange(s, usize, 0, alphabet.len - 1)];
    const options = [_]Syntax{ .{}, .{ .unicode = false }, .{ .utf8 = false, .unicode = false }, .{ .case_insensitive = true }, ecma, annex_b, sets, with(ecma, true), with(annex_b, true), with(sets, true) };
    const syntax = options[shakedown.gen.intRange(s, usize, 0, options.len - 1)];
    case.note("/{s}/ {any}", .{ pattern, syntax });
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var d: parse_mod.Diagnostic = .{};
    const ast = parse_mod.parse(a, .init(pattern), syntax, .{}, &d) catch |err| switch (err) {
        error.Invalid, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    d = .{};
    const hir = translate_mod.translate(a, &ast, syntax, .{}, &d) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => {
            try testing.expect(d.reason != .none);
            return;
        },
        error.OutOfMemory => return err,
    };
    // Every child comes before its parent, and every class is sorted and apart.
    for (hir.nodes, 0..) |node, i| switch (node) {
        .unicode_class => |r| for (r, 0..) |x, j| {
            try testing.expect(x[0] <= x[1]);
            if (j > 0) try testing.expect(@as(u32, x[0]) > @as(u32, r[j - 1][1]) + 1);
        },
        .repetition => |r| try testing.expect(@backingInt(r.sub) < i),
        .capture => |c| try testing.expect(@backingInt(c.sub) < i),
        else => {},
    };
}

test "fuzz: any pattern that parses translates or is refused by name" {
    try shakedown.check(testing.allocator, {}, anyTranslation, .{ .cases = 5000, .seed = 0x41b5 });
}

/// The HIR's own bytes: its nodes, its children, and what its literals and classes hold.
fn hirBytes(hir: *const Hir) usize {
    var n: usize = hir.nodes.len * @sizeOf(Hir.Node) + hir.children.len * @sizeOf(Hir.Index);
    for (hir.nodes) |node| switch (node) {
        .literal => |b| n += b.len,
        .unicode_class => |r| n += r.len * @sizeOf([2]u21),
        .byte_class => |r| n += r.len * @sizeOf([2]u8),
        else => {},
    };
    return n;
}

const Charge = struct { spent: usize, out: usize, refused: ?anyerror };

/// What translating `pattern` was charged, and the bytes of the HIR it made (0 if refused).
fn charge(pattern: []const u8, syntax: Syntax, limits: Limits) !Charge {
    var s: State = .{};
    defer s.deinit();
    const a = s.arena();
    const ast = try parse_mod.parse(a, .init(pattern), syntax, .{}, null);
    var spent: usize = 0;
    var d: parse_mod.Diagnostic = .{};
    const hir = translate_mod.translateCounted(a, &ast, syntax, limits, &d, &spent) catch |err| {
        if (err == error.TooLarge) try testing.expectEqual(.nfa_too_large, d.reason);
        return .{ .spent = spent, .out = 0, .refused = err };
    };
    return .{ .spent = spent, .out = hirBytes(&hir), .refused = null };
}

/// A pattern of `count` copies of `item` inside `open` and `close`.
fn repeated(a: std.mem.Allocator, open: []const u8, item: []const u8, count: usize, close: []const u8) ![]const u8 {
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(a, open);
    for (0..count) |_| try p.appendSlice(a, item);
    try p.appendSlice(a, close);
    return p.items;
}

// Work, counted as the bytes translation is charged: each set operation writes what it reads
// into a charged list, and a sort runs over a charged one. The bound is linear in what the
// pattern names (its bytes, and the ranges of each property it names) and what the HIR holds.
const per_byte = 32;

test "a class of many characters costs what it names and holds, in any order" {
    var s: State = .{};
    defer s.deinit();
    var p: std.ArrayList(u8) = .empty;
    try p.append(s.arena(), '[');
    // Apart and descending: each before every one already read.
    var cp: u21 = 0x20000 + 2 * 15_000;
    while (cp > 0x20000) : (cp -= 2) {
        var b: [4]u8 = undefined;
        try p.appendSlice(s.arena(), b[0..try std.unicode.utf8Encode(cp, &b)]);
    }
    try p.append(s.arena(), ']');
    const c = try charge(p.items, .{}, .{});
    try testing.expectEqual(null, c.refused);
    try testing.expect(c.spent <= per_byte * (p.items.len + c.out));
}

test "a class naming one property many times costs what it names, and past the limit is refused" {
    var s: State = .{};
    defer s.deinit();
    const a = s.arena();
    const letters = xenoglyph.properties.generalCategoryGroupRanges(.letter).len;
    for ([_]struct { open: []const u8, item: []const u8, syntax: Syntax }{
        .{ .open = "[", .item = "\\p{L}", .syntax = with(sets, true) },
        .{ .open = "(?i)[", .item = "\\pL", .syntax = .{} },
        .{ .open = "[", .item = "\\P{L}", .syntax = with(ecma, true) },
    }) |shape| {
        const few = try repeated(a, shape.open, shape.item, 100, "]");
        const c = try charge(few, shape.syntax, .{});
        try testing.expectEqual(null, c.refused);
        const named = few.len + 100 * letters * @sizeOf([2]u21);
        try testing.expect(c.spent <= per_byte * (named + c.out));
        // The pattern at its longest: past the limit, refused for what it was charged so far.
        const many = try repeated(a, shape.open, shape.item, (64 * 1024 - 8) / shape.item.len, "]");
        const big = try charge(many, shape.syntax, .{});
        try testing.expectEqual(@as(?anyerror, error.TooLarge), big.refused);
        try testing.expect(big.spent <= (Limits{}).nfa.raw());
    }
}

test "a property alone, closed under case each time it is written, is charged each time" {
    var s: State = .{};
    defer s.deinit();
    const a = s.arena();
    const many = try repeated(a, "(?i)", "\\pL", (64 * 1024 - 8) / 3, "");
    const big = try charge(many, .{}, .{});
    try testing.expectEqual(@as(?anyerror, error.TooLarge), big.refused);
    try testing.expect(big.spent <= (Limits{}).nfa.raw());
    const c = try charge(try repeated(a, "(?i)", "\\pL", 10, ""), .{}, .{});
    try testing.expectEqual(null, c.refused);
    try testing.expect(c.spent <= per_byte * (40 + c.out));
}

test "a limit smaller than a class refuses it" {
    const c = try charge("\\p{L}", ecma, .{ .nfa = .literal("1KiB") });
    try testing.expectEqual(@as(?anyerror, error.TooLarge), c.refused);
    try testing.expect(c.spent <= 1024);
}
