//! Literal extraction: regex-syntax's own cases (hir/literal.rs), read through spectra's
//! translation, prefixes and suffixes; then what is spectra's own, and the work it does.
const std = @import("std");
const testing = std.testing;
const parse_mod = @import("../syntax/parse.zig");
const Ast = @import("../syntax/Ast.zig");
const Syntax = @import("../Syntax.zig");
const Hir = @import("../Hir.zig");
const translate_mod = @import("translate.zig");
const literals = @import("literals.zig");
const Seq = literals.Seq;
const Extractor = literals.Extractor;

/// As regex-syntax's tests parse: bytes allowed.
const bytes_ok: Syntax = .{ .utf8 = false };

fn hirOf(a: std.mem.Allocator, pattern: []const u8, syntax: Syntax) !Hir {
    const ast = try parse_mod.parse(a, .init(pattern), syntax, .{}, null);
    const held = try a.create(Ast);
    held.* = ast;
    return translate_mod.translate(a, held, syntax, .{}, null);
}

/// `inf`, or each literal as `E:` (exact) or `I:` (inexact) and its bytes, `\xNN` past ASCII.
fn show(a: std.mem.Allocator, seq: *const Seq) ![]const u8 {
    const lits = seq.literals() orelse return "inf";
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("[");
    for (lits, 0..) |lit, i| {
        if (i != 0) try out.writer.writeAll(" ");
        try out.writer.writeAll(if (lit.exact) "E:" else "I:");
        for (lit.bytes) |b| if (b < 0x80 and b > 0x20) try out.writer.writeByte(b) else try out.writer.print("\\x{x:0>2}", .{b});
    }
    try out.writer.writeAll("]");
    return out.written();
}

fn extracted(a: std.mem.Allocator, pattern: []const u8, extractor: Extractor) ![]const u8 {
    const hir = try hirOf(a, pattern, bytes_ok);
    const seq = try extractor.extract(a, &hir);
    return show(a, &seq);
}

/// Prefixes then suffixes of `pattern`, as `show` writes them, with regex-syntax's limits
/// unless `extractor` says otherwise.
fn expectBoth(pattern: []const u8, prefixes: []const u8, suffixes: []const u8) !void {
    return expectWith(.{}, pattern, prefixes, suffixes);
}

fn expectWith(extractor: Extractor, pattern: []const u8, prefixes: []const u8, suffixes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = extractor;
    e.kind = .prefix;
    const got_prefixes = try extracted(a, pattern, e);
    e.kind = .suffix;
    const got_suffixes = try extracted(a, pattern, e);
    testing.expectEqualStrings(prefixes, got_prefixes) catch |err| {
        std.debug.print("prefixes of /{s}/\n", .{pattern});
        return err;
    };
    testing.expectEqualStrings(suffixes, got_suffixes) catch |err| {
        std.debug.print("suffixes of /{s}/\n", .{pattern});
        return err;
    };
}

/// The same sequence both ways.
fn expectSame(pattern: []const u8, both: []const u8) !void {
    return expectBoth(pattern, both, both);
}

test "literal" {
    try expectSame("a", "[E:a]");
    try expectSame("aaaaa", "[E:aaaaa]");
    try expectSame("(?i-u)a", "[E:A E:a]");
    try expectSame("(?i-u)ab", "[E:AB E:Ab E:aB E:ab]");
    try expectSame("ab(?i-u)c", "[E:abC E:abc]");
    try expectSame("(?-u:\\xFF)", "[E:\\xff]");
    try expectSame("\u{2603}", "[E:\\xe2\\x98\\x83]");
    try expectSame("(?i)\u{2603}", "[E:\\xe2\\x98\\x83]");
    try expectSame("(?i)\u{394}", "[E:\\xce\\x94 E:\\xce\\xb4]");
    try expectSame("(?i)s", "[E:S E:s E:\\xc5\\xbf]");
}

test "class" {
    try expectSame("[abc]", "[E:a E:b E:c]");
    try expectSame("a[123]b", "[E:a1b E:a2b E:a3b]");
    try expectSame("[\u{3b5}\u{3b4}]", "[E:\\xce\\xb4 E:\\xce\\xb5]");
    try expectSame("(?i)[\u{3b5}\u{3b4}]", "[E:\\xce\\x94 E:\\xce\\x95 E:\\xce\\xb4 E:\\xce\\xb5 E:\\xcf\\xb5]");
}

test "look" {
    for ([_][]const u8{
        "a\\Ab", "a\\zb", "a(?m:^)b", "a(?m:$)b", "a\\bb", "a\\Bb", "a(?-u:\\b)b", "a(?-u:\\B)b",
        "^ab",   "$ab",   "(?m:^)ab", "(?m:$)ab", "\\bab", "\\Bab", "(?-u:\\b)ab", "(?-u:\\B)ab",
        "ab^",   "ab$",   "ab(?m:^)", "ab(?m:$)", "ab\\b", "ab\\B", "ab(?-u:\\b)", "ab(?-u:\\B)",
    }) |pattern| try expectSame(pattern, "[E:ab]");
    try expectBoth("^aZ*b", "[I:aZ E:ab]", "[I:Zb E:ab]");
}

test "repetition" {
    try expectSame("a?", "[E:a E:]");
    try expectSame("a??", "[E: E:a]");
    try expectSame("a*", "[I:a E:]");
    try expectSame("a*?", "[E: I:a]");
    try expectSame("a+", "[I:a]");
    try expectSame("(a+)+", "[I:a]");
    try expectSame("aZ{0}b", "[E:ab]");
    try expectSame("aZ?b", "[E:aZb E:ab]");
    try expectSame("aZ??b", "[E:ab E:aZb]");
    try expectBoth("aZ*b", "[I:aZ E:ab]", "[I:Zb E:ab]");
    try expectBoth("aZ*?b", "[E:ab I:aZ]", "[E:ab I:Zb]");
    try expectBoth("aZ+b", "[I:aZ]", "[I:Zb]");
    try expectBoth("aZ+?b", "[I:aZ]", "[I:Zb]");
    try expectSame("aZ{2}b", "[E:aZZb]");
    try expectBoth("aZ{2,3}b", "[I:aZZ]", "[I:ZZb]");
    try expectSame("(abc)?", "[E:abc E:]");
    try expectSame("(abc)??", "[E: E:abc]");
    try expectBoth("a*b", "[I:a E:b]", "[I:ab E:b]");
    try expectBoth("a*?b", "[E:b I:a]", "[E:b I:ab]");
    try expectBoth("ab+", "[I:ab]", "[I:b]");
    try expectBoth("a*b+", "[I:a I:b]", "[I:b]");
    // regex-syntax's own note: the suffixes' order is not preference order, and is not used as one.
    try expectBoth("a*b*c", "[I:a I:b E:c]", "[I:bc I:ac E:c]");
    try expectBoth("(a+)?(b+)?c", "[I:a I:b E:c]", "[I:bc I:ac E:c]");
    try expectBoth("(a+|)(b+|)c", "[I:a I:b E:c]", "[I:bc I:ac E:c]");
    try expectBoth("a*b*c*", "[I:a I:b I:c E:]", "[I:c I:b I:a E:]");
    try expectBoth("a*b*c+", "[I:a I:b I:c]", "[I:c]");
    try expectBoth("a*b+c", "[I:a I:b]", "[I:bc]");
    try expectBoth("a*b+c*", "[I:a I:b]", "[I:c I:b]");
    try expectBoth("ab*", "[I:ab E:a]", "[I:b E:a]");
    try expectBoth("ab*c", "[I:ab E:ac]", "[I:bc E:ac]");
    try expectBoth("ab+c", "[I:ab]", "[I:bc]");
    try expectBoth("z*azb", "[I:z E:azb]", "[I:zazb E:azb]");
    try expectSame("[ab]{3}", "[E:aaa E:aab E:aba E:abb E:baa E:bab E:bba E:bbb]");
    try expectSame("[ab]{3,4}", "[I:aaa I:aab I:aba I:abb I:baa I:bab I:bba I:bbb]");
}

test "concat" {
    try expectSame("abc()xyz", "[E:abcxyz]");
    try expectSame("(abc)(xyz)", "[E:abcxyz]");
    try expectSame("abc()mno()xyz", "[E:abcmnoxyz]");
    try expectSame("abc[a&&b]xyz", "[]");
    try expectSame("abc[a&&b]*xyz", "[E:abcxyz]");
}

test "alternation" {
    try expectSame("abc|mno|xyz", "[E:abc E:mno E:xyz]");
    try expectBoth("abc|mZ*o|xyz", "[E:abc I:mZ E:mo E:xyz]", "[E:abc I:Zo E:mo E:xyz]");
    try expectSame("abc|M[a&&b]N|xyz", "[E:abc E:xyz]");
    try expectSame("abc|M[a&&b]*N|xyz", "[E:abc E:MN E:xyz]");
    try expectSame("(?:|aa)aaa", "[E:aaa E:aaaaa]");
    try expectBoth("(?:|aa)(?:aaa)*", "[I:aaa E: I:aaaaa E:aa]", "[I:aaa E: E:aa]");
    try expectBoth("(?:|aa)(?:aaa)*?", "[E: I:aaa E:aa I:aaaaa]", "[E: I:aaa E:aa]");
    try expectSame("a|b*", "[E:a I:b E:]");
    try expectSame("a|b+", "[E:a I:b]");
    try expectBoth("a*b|c", "[I:a E:b E:c]", "[I:ab E:b E:c]");
    try expectSame("a|(?:b|c*)", "[E:a E:b I:c E:]");
    try expectBoth("(a|b)*c|(a|ab)*c", "[I:a I:b E:c I:a I:ab E:c]", "[I:ac I:bc E:c I:ac I:abc E:c]");
    try expectSame("(ab|cd)(ef|gh)", "[E:abef E:abgh E:cdef E:cdgh]");
    try expectSame("(ab|cd)(ef|gh)(ij|kl)", "[E:abefij E:abefkl E:abghij E:abghkl E:cdefij E:cdefkl E:cdghij E:cdghkl]");
    try expectSame("(ab){2}", "[E:abab]");
    try expectSame("(ab){2,3}", "[I:abab]");
    try expectSame("(ab){2,}", "[I:abab]");
}

test "impossible" {
    for ([_][]const u8{ "[a&&b]", "a[a&&b]", "[a&&b]b", "a[a&&b]b" }) |pattern| try expectSame(pattern, "[]");
    for ([_][]const u8{ "a|[a&&b]|b", "a|c[a&&b]|b", "a|[a&&b]d|b", "a|c[a&&b]d|b" }) |pattern| try expectSame(pattern, "[E:a E:b]");
    try expectSame("[a&&b]*", "[E:]");
    try expectSame("M[a&&b]*N", "[E:MN]");
}

test "anything" {
    for ([_][]const u8{ ".", "(?s).", "[A-Za-z]", "[A-Z]", "[A-Z]?", "[A-Z]*", "[A-Z]+", "[A-Z]+123[A-Z]+", "1|[A-Z]|3" }) |pattern| try expectSame(pattern, "inf");
    try expectSame("[A-Z]{0}", "[E:]");
    try expectBoth("1[A-Z]", "[I:1]", "inf");
    try expectBoth("1[A-Z]2", "[I:1]", "[I:2]");
    try expectBoth("[A-Z]+123", "inf", "[I:123]");
    try expectBoth("1|2[A-Z]|3", "[E:1 I:2 E:3]", "inf");
    try expectBoth("1|[A-Z]2|3", "inf", "[E:1 I:2 E:3]");
    try expectBoth("1|2[A-Z]3|4", "[E:1 I:2 E:4]", "[E:1 I:3 E:4]");
    try expectBoth("(?:|1)[A-Z]2", "inf", "[I:2]");
    try expectBoth("a.z", "[I:a]", "[I:z]");
}

test "anything, with small limits" {
    const small: Extractor = .{ .limit_total = 10 };
    try expectWith(small, "[ab]{3}{3}", "[I:aaa I:aab I:aba I:abb I:baa I:bab I:bba I:bbb]", "[I:aaa I:aab I:aba I:abb I:baa I:bab I:bba I:bbb]");
    try expectWith(small, "ab|cd|ef|gh|ij|kl|mn|op|qr|st|uv|wx|yz", "inf", "inf");
}

test "empty" {
    for ([_][]const u8{ "", "^", "$", "(?m:^)", "(?m:$)", "\\b", "\\B", "(?-u:\\b)", "(?-u:\\B)" }) |pattern| try expectSame(pattern, "[E:]");
}

test "odds and ends" {
    try expectBoth(".a", "inf", "[I:a]");
    try expectBoth("a.", "[I:a]", "inf");
    try expectSame("a|.", "inf");
    try expectSame(".|a", "inf");
    try expectBoth(
        "M[ou]'?am+[ae]r .*([AEae]l[- ])?[GKQ]h?[aeu]+([dtz][dhz]?)+af[iy]",
        "[I:Mo'am I:Moam I:Mu'am I:Muam]",
        "[I:ddafi I:ddafy I:dhafi I:dhafy I:dzafi I:dzafy I:dafi I:dafy I:tdafi I:tdafy I:thafi I:thafy I:tzafi I:tzafy I:tafi I:tafy I:zdafi I:zdafy I:zhafi I:zhafy I:zzafi I:zzafy I:zafi I:zafy]",
    );
}

test "ECMAScript: a lookahead reads as the empty string, and a surrogate matches nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ecma: Syntax = .{ .dialect = .ecmascript };
    const ahead = try hirOf(a, "(?=ab)ab", ecma);
    try testing.expectEqualStrings("[E:ab]", try show(a, &try (Extractor{}).extract(a, &ahead)));
    // `[\uD800-\uDBFFa]` under u: the surrogates are no code point a haystack holds.
    const lone = try hirOf(a, "[\\uD800-\\uDBFFa]", ecma);
    try testing.expectEqualStrings("[E:a]", try show(a, &try (Extractor{}).extract(a, &lone)));
}

test "minimizing by preference drops what an earlier literal starts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seq = try Seq.exactOf(a, &.{ "ab", "abc", "b", "a", "ba" });
    try seq.minimizeByPreference(a, false);
    // `abc` starts with `ab` and `ba` with `b`: each later one goes, and the earlier one is inexact.
    try testing.expectEqualStrings("[I:ab I:b E:a]", try show(a, &seq));
    var kept = try Seq.exactOf(a, &.{ "ab", "abc", "", "z" });
    try kept.minimizeByPreference(a, true);
    try testing.expectEqualStrings("[E:ab E:]", try show(a, &kept));
}

test "common prefixes and suffixes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const seq = try Seq.exactOf(a, &.{ "foobar", "foozbar", "fobar" });
    try testing.expectEqualStrings("fo", seq.longestCommonPrefix().?);
    try testing.expectEqualStrings("bar", seq.longestCommonSuffix().?);
    try testing.expectEqual(null, Seq.infinite.longestCommonPrefix());
    try testing.expectEqual(null, Seq.empty.longestCommonSuffix());
}

/// An allocator that counts the bytes asked of it.
const Counting = struct {
    child: std.mem.Allocator,
    bytes: usize = 0,
    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = std.mem.Allocator.noFree } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.bytes += len;
        return c.child.rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) c.bytes += new_len - memory.len;
        return c.child.rawResize(memory, alignment, new_len, ret);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) c.bytes += new_len - memory.len;
        return c.child.rawRemap(memory, alignment, new_len, ret);
    }
};

/// The bytes extracting both ways from `pattern` asks for.
fn workOf(pattern: []const u8) !usize {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const hir = try hirOf(arena.allocator(), pattern, bytes_ok);
    var counting: Counting = .{ .child = arena.allocator() };
    _ = try (Extractor{ .kind = .prefix }).extract(counting.allocator(), &hir);
    _ = try (Extractor{ .kind = .suffix }).extract(counting.allocator(), &hir);
    return counting.bytes;
}

fn repeated(a: std.mem.Allocator, item: []const u8, count: usize) ![]const u8 {
    var p: std.ArrayList(u8) = .empty;
    for (0..count) |_| try p.appendSlice(a, item);
    return p.items;
}

// Work, counted as the bytes extraction asks for. Each node's sequence holds at most
// `limit_total` literals of `limit_literal_len` bytes, so the work is linear in the pattern
// whatever its shape; on these shapes it is at most 182 bytes per pattern byte (measured), and
// the bound is held at 256. Chains as long as the pattern are walked, not recursed.
test "extraction's work is linear in the pattern, whatever its shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const per_byte = 256;
    for ([_][]const u8{
        try repeated(a, "a\\b", 20_000),
        try repeated(a, "(?:|)", 12_000),
        try std.mem.concat(a, u8, &.{ "a", try repeated(a, "{2}", 20_000) }),
        try std.mem.concat(a, u8, &.{ "[ab]", try repeated(a, "{1,2}", 12_000) }),
        try std.mem.concat(a, u8, &.{ try repeated(a, "ab|", 20_000), "c" }),
        try std.mem.concat(a, u8, &.{ try repeated(a, "(?:", 200), "[a-j][a-j]", try repeated(a, ")", 200) }),
    }) |pattern| {
        const work = try workOf(pattern);
        testing.expect(work <= per_byte * pattern.len) catch |err| {
            std.debug.print("{d} bytes for a pattern of {d}\n", .{ work, pattern.len });
            return err;
        };
    }
}
