//! RE2's search tests (re2/testing/search_test.cc, `simple_tests`, RE2 commit 2da0056; RE2 is
//! BSD-3-Clause, its licence in LICENSES/re2-BSD.txt): every pattern and text of that table, as
//! RE2's tester runs them, through the Rust dialect, which reads RE2's syntax but for `\C` (any
//! byte) and RE2's octal escapes, refused as Invalid and counted. RE2's table gives no answers, its
//! engines are checked against each other and a backtracker; here every pattern spectra compiles,
//! in Unicode, case-insensitive and bytes modes, is searched over its text and over the text with
//! a byte off either end (assertions still seeing the whole), anchored and not, and the public
//! engine's match and groups, the PikeVM alone's and is-match are checked against the test
//! backtracker's. The table was read out of the C source by a text parse, its escapes undone.
const std = @import("std");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const backtrack = @import("testing/backtrack.zig");
const testing = std.testing;
const gpa = testing.allocator;

const cases = [_]struct { []const u8, []const u8 }{
    .{ "a", "a" },
    .{ "a", "zyzzyva" },
    .{ "a+", "aa" },
    .{ "(a+|b)+", "ab" },
    .{ "ab|cd", "xabcdx" },
    .{ "h.*od?", "hello\x0agoodbye\x0a" },
    .{ "h.*o", "hello\x0agoodbye\x0a" },
    .{ "h.*o", "goodbye\x0ahello\x0a" },
    .{ "h.*o", "hello world" },
    .{ "h.*o", "othello, world" },
    .{ "[^\\s\\S]", "aaaaaaa" },
    .{ "a", "aaaaaaa" },
    .{ "a*", "aaaaaaa" },
    .{ "a*", "" },
    .{ "ab|cd", "xabcdx" },
    .{ "a", "cab" },
    .{ "a*b", "cab" },
    .{ "((((((((((((((((((((x))))))))))))))))))))", "x" },
    .{ "[abcd]", "xxxabcdxxx" },
    .{ "[^x]", "xxxabcdxxx" },
    .{ "[abcd]+", "xxxabcdxxx" },
    .{ "[^x]+", "xxxabcdxxx" },
    .{ "(fo|foo)", "fo" },
    .{ "(foo|fo)", "foo" },
    .{ "aa", "aA" },
    .{ "a", "Aa" },
    .{ "a", "A" },
    .{ "ABC", "abc" },
    .{ "abc", "XABCY" },
    .{ "ABC", "xabcy" },
    .{ "foo|bar|[A-Z]", "foo" },
    .{ "^(foo|bar|[A-Z])", "foo" },
    .{ "(foo|bar|[A-Z])$", "foo\x0a" },
    .{ "(foo|bar|[A-Z])$", "foo" },
    .{ "^(foo|bar|[A-Z])$", "foo\x0a" },
    .{ "^(foo|bar|[A-Z])$", "foo" },
    .{ "^(foo|bar|[A-Z])$", "bar" },
    .{ "^(foo|bar|[A-Z])$", "X" },
    .{ "^(foo|bar|[A-Z])$", "XY" },
    .{ "^(fo|foo)$", "fo" },
    .{ "^(fo|foo)$", "foo" },
    .{ "^^(fo|foo)$", "fo" },
    .{ "^^(fo|foo)$", "foo" },
    .{ "^$", "" },
    .{ "^$", "x" },
    .{ "^^$", "" },
    .{ "^$$", "" },
    .{ "^^$", "x" },
    .{ "^$$", "x" },
    .{ "^^$$", "" },
    .{ "^^$$", "x" },
    .{ "^^^^^^^^$$$$$$$$", "" },
    .{ "^", "x" },
    .{ "$", "x" },
    .{ "\\bfoo\\b", "nofoo foo that" },
    .{ "a\\b", "faoa x" },
    .{ "\\bbar", "bar x" },
    .{ "\\bbar", "foo\x0abar x" },
    .{ "bar\\b", "foobar" },
    .{ "bar\\b", "foobar\x0axxx" },
    .{ "(foo|bar|[A-Z])\\b", "foo" },
    .{ "(foo|bar|[A-Z])\\b", "foo\x0a" },
    .{ "\\b", "" },
    .{ "\\b", "x" },
    .{ "\\b(foo|bar|[A-Z])", "foo" },
    .{ "\\b(foo|bar|[A-Z])\\b", "X" },
    .{ "\\b(foo|bar|[A-Z])\\b", "XY" },
    .{ "\\b(foo|bar|[A-Z])\\b", "bar" },
    .{ "\\b(foo|bar|[A-Z])\\b", "foo" },
    .{ "\\b(foo|bar|[A-Z])\\b", "foo\x0a" },
    .{ "\\b(foo|bar|[A-Z])\\b", "ffoo bbar N x" },
    .{ "\\b(fo|foo)\\b", "fo" },
    .{ "\\b(fo|foo)\\b", "foo" },
    .{ "\\b\\b", "" },
    .{ "\\b\\b", "x" },
    .{ "\\b$", "" },
    .{ "\\b$", "x" },
    .{ "\\b$", "y x" },
    .{ "\\b.$", "x" },
    .{ "^\\b(fo|foo)\\b", "fo" },
    .{ "^\\b(fo|foo)\\b", "foo" },
    .{ "^\\b", "" },
    .{ "^\\b", "x" },
    .{ "^\\b\\b", "" },
    .{ "^\\b\\b", "x" },
    .{ "^\\b$", "" },
    .{ "^\\b$", "x" },
    .{ "^\\b.$", "x" },
    .{ "^\\b.\\b$", "x" },
    .{ "^^^^^^^^\\b$$$$$$$", "" },
    .{ "^^^^^^^^\\b.$$$$$$", "x" },
    .{ "^^^^^^^^\\b$$$$$$$", "x" },
    .{ "\\Bfoo\\B", "n foo xfoox that" },
    .{ "a\\B", "faoa x" },
    .{ "\\Bbar", "bar x" },
    .{ "\\Bbar", "foo\x0abar x" },
    .{ "bar\\B", "foobar" },
    .{ "bar\\B", "foobar\x0axxx" },
    .{ "(foo|bar|[A-Z])\\B", "foox" },
    .{ "(foo|bar|[A-Z])\\B", "foo\x0a" },
    .{ "\\B", "" },
    .{ "\\B", "x" },
    .{ "\\B(foo|bar|[A-Z])", "foo" },
    .{ "\\B(foo|bar|[A-Z])\\B", "xXy" },
    .{ "\\B(foo|bar|[A-Z])\\B", "XY" },
    .{ "\\B(foo|bar|[A-Z])\\B", "XYZ" },
    .{ "\\B(foo|bar|[A-Z])\\B", "abara" },
    .{ "\\B(foo|bar|[A-Z])\\B", "xfoo_" },
    .{ "\\B(foo|bar|[A-Z])\\B", "xfoo\x0a" },
    .{ "\\B(foo|bar|[A-Z])\\B", "foo bar vNx" },
    .{ "\\B(fo|foo)\\B", "xfoo" },
    .{ "\\B(foo|fo)\\B", "xfooo" },
    .{ "\\B\\B", "" },
    .{ "\\B\\B", "x" },
    .{ "\\B$", "" },
    .{ "\\B$", "x" },
    .{ "\\B$", "y x" },
    .{ "\\B.$", "x" },
    .{ "^\\B(fo|foo)\\B", "fo" },
    .{ "^\\B(fo|foo)\\B", "foo" },
    .{ "^\\B", "" },
    .{ "^\\B", "x" },
    .{ "^\\B\\B", "" },
    .{ "^\\B\\B", "x" },
    .{ "^\\B$", "" },
    .{ "^\\B$", "x" },
    .{ "^\\B.$", "x" },
    .{ "^\\B.\\B$", "x" },
    .{ "^^^^^^^^\\B$$$$$$$", "" },
    .{ "^^^^^^^^\\B.$$$$$$", "x" },
    .{ "^^^^^^^^\\B$$$$$$$", "x" },
    .{ "\\bx\\b", "x" },
    .{ "\\bx\\b", "x>" },
    .{ "\\bx\\b", "<x" },
    .{ "\\bx\\b", "<x>" },
    .{ "\\bx\\b", "ax" },
    .{ "\\bx\\b", "xb" },
    .{ "\\bx\\b", "axb" },
    .{ "\\bx\\b", "\xc2\xabx" },
    .{ "\\bx\\b", "x\xc2\xbb" },
    .{ "\\bx\\b", "\xc2\xabx\xc2\xbb" },
    .{ "\\bx\\b", "axb" },
    .{ "\\bx\\b", "\xc3\xa1x\xce\xb2" },
    .{ "\\Bx\\B", "axb" },
    .{ "\\Bx\\B", "\xc3\xa1x\xce\xb2" },
    .{ "^$^$", "" },
    .{ "^$^", "" },
    .{ "$^$", "" },
    .{ "^$^$", "x" },
    .{ "^$^", "x" },
    .{ "$^$", "x" },
    .{ "^$^$", "x\x0ay" },
    .{ "^$^", "x\x0ay" },
    .{ "$^$", "x\x0ay" },
    .{ "^$^$", "x\x0a\x0ay" },
    .{ "^$^", "x\x0a\x0ay" },
    .{ "$^$", "x\x0a\x0ay" },
    .{ "^(foo\\$)$", "foo$bar" },
    .{ "(foo\\$)", "foo$bar" },
    .{ "^...$", "abc" },
    .{ "^\xe6\x9c\xac$", "\xe6\x9c\xac" },
    .{ "^...$", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" },
    .{ "^...$", ".\xe6\x9c\xac." },
    .{ "^\\C\\C\\C$", "\xe6\x9c\xac" },
    .{ "^\\C$", "\xe6\x9c\xac" },
    .{ "^\\C\\C\\C$", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" },
    .{ "^...$", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" },
    .{ "^.........$", "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" },
    .{ "^...$", ".\xe6\x9c\xac." },
    .{ "^.....$", ".\xe6\x9c\xac." },
    .{ "\\B(fo|foo)\\B", "xfooo" },
    .{ "(fo|foo)", "foo" },
    .{ "\\141", "a" },
    .{ "\\060", "0" },
    .{ "\\0600", "00" },
    .{ "\\608", "08" },
    .{ "\\01", "\x01" },
    .{ "\\018", "\x018" },
    .{ "\\x{61}", "a" },
    .{ "\\x61", "a" },
    .{ "\\x{00000061}", "a" },
    .{ "\\p{Greek}+", "a\xce\xb1\xce\xb2b" },
    .{ "\\P{Greek}+", "a\xce\xb1\xce\xb2b" },
    .{ "\\p{^Greek}+", "a\xce\xb1\xce\xb2b" },
    .{ "\\P{^Greek}+", "a\xce\xb1\xce\xb2b" },
    .{ "[^0-9]+", "abc123" },
    .{ "\\p{Nd}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\p{^Nd}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\P{Nd}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\P{^Nd}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\pN+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\p{N}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\p{^N}+", "abc123\xc2\xb2\xc2\xb3\xc2\xbc\xc2\xbd\xc2\xbe\xe2\x82\x80\xe2\x82\x89" },
    .{ "\\p{Any}+", "abc123" },
    .{ "(?i)[@-A]+", "@AaB" },
    .{ "(?i)[A-Z]+", "aAzZ" },
    .{ "(?i)[^\\\\]+", "Aa\\" },
    .{ "(?i)[\\\\]+", "Aa" },
    .{ "(?i)[acegikmoqsuwy]+", "acegikmoqsuwyACEGIKMOQSUWY" },
    .{ "[@-A]+", "@AaB" },
    .{ "[A-Z]+", "aAzZ" },
    .{ "[^\\\\]+", "Aa\\" },
    .{ "[acegikmoqsuwy]+", "acegikmoqsuwyACEGIKMOQSUWY" },
    .{ "^abc", "abcdef" },
    .{ "^abc", "aabcdef" },
    .{ "^[ay]*[bx]+c", "abcdef" },
    .{ "^[ay]*[bx]+c", "aabcdef" },
    .{ "def$", "abcdef" },
    .{ "def$", "abcdeff" },
    .{ "d[ex][fy]$", "abcdef" },
    .{ "d[ex][fy]$", "abcdeff" },
    .{ "[dz][ex][fy]$", "abcdef" },
    .{ "[dz][ex][fy]$", "abcdeff" },
    .{ "(?m)^abc", "abcdef" },
    .{ "(?m)^abc", "aabcdef" },
    .{ "(?m)^[ay]*[bx]+c", "abcdef" },
    .{ "(?m)^[ay]*[bx]+c", "aabcdef" },
    .{ "(?m)def$", "abcdef" },
    .{ "(?m)def$", "abcdeff" },
    .{ "(?m)d[ex][fy]$", "abcdef" },
    .{ "(?m)d[ex][fy]$", "abcdeff" },
    .{ "(?m)[dz][ex][fy]$", "abcdef" },
    .{ "(?m)[dz][ex][fy]$", "abcdeff" },
    .{ "^", "a" },
    .{ "^^", "a" },
    .{ "a", "a" },
    .{ "ab*", "a" },
    .{ "a\\C*", "a" },
    .{ "a\\C+", "a" },
    .{ "a\\C?", "a" },
    .{ "a\\C*?", "a" },
    .{ "a\\C+?", "a" },
    .{ "a\\C??", "a" },
    .{ "a\\C*|ba\\C", "baba" },
    .{ "\\w*I\\w*", "Inc." },
    .{ "(?:|a)*", "aaa" },
    .{ "(?:|a)+", "aaa" },
};

const Tally = struct {
    patterns: usize = 0,
    compiled: usize = 0,
    invalid: usize = 0,
    unsupported: usize = 0,
    searches: usize = 0,
    matched: usize = 0,
};

fn check(pattern: []const u8, syntax: Syntax, text: []const u8, tally: *Tally) !void {
    var re = Regex.compile(gpa, .init(pattern), .{ .syntax = syntax }) catch |err| switch (err) {
        error.Invalid => {
            tally.invalid += 1;
            return;
        },
        error.Unsupported => {
            tally.unsupported += 1;
            return;
        },
        else => return err,
    };
    defer re.deinit();
    var alone = try Regex.compile(gpa, .init(pattern), .{ .syntax = syntax, .prefilter = false, .limits = .{ .lazy_dfa = .fromRaw(0), .backtrack = .fromRaw(0), .onepass = .fromRaw(0) } });
    defer alone.deinit();
    tally.compiled += 1;
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    var ac = try alone.cache(gpa);
    defer ac.deinit(gpa);
    const slots = try gpa.alloc(?usize, re.nfa.slots());
    defer gpa.free(slots);
    const groups = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(groups);
    const alone_groups = try gpa.alloc(?Regex.Span, re.captureCount());
    defer gpa.free(alone_groups);
    // The text, and the text with a byte off either end.
    const spans = [_][2]usize{ .{ 0, text.len }, .{ @min(1, text.len), text.len }, .{ 0, text.len -| 1 } };
    for (spans) |sp| for ([_]bool{ false, true }) |anchored| {
        const input: Regex.Input = .{ .haystack = text, .span = .{ .start = sp[0], .end = sp[1] }, .anchored = anchored };
        const want = try backtrack.search(gpa, &re.nfa, text, .{ .start = sp[0], .end = sp[1] }, anchored, slots);
        tally.searches += 1;
        const found = try re.captures(&c, input, groups);
        try testing.expectEqual(want != null, found);
        try testing.expectEqual(found, try alone.captures(&ac, input, alone_groups));
        if (want) |end| {
            tally.matched += 1;
            try testing.expectEqual(end, groups[0].?.end);
            for (groups, 0..) |g, i| {
                try testing.expectEqual(slots[2 * i], if (g) |x| x.start else null);
                try testing.expectEqual(slots[2 * i + 1], if (g) |x| x.end else null);
            }
            try testing.expectEqualSlices(?Regex.Span, groups, alone_groups);
        }
        try testing.expectEqual(want, if (try re.find(&c, input)) |m| m.end else null);
        if (sp[0] == 0 and sp[1] == text.len and !anchored) try testing.expectEqual(want != null, try re.isMatch(&c, text));
    };
}

test "RE2's search tests, through the Rust dialect, against the test backtracker" {
    var tally: Tally = .{};
    const syntaxes = [_]Syntax{ .{}, .{ .case_insensitive = true }, .{ .unicode = false, .utf8 = false } };
    for (cases) |case| {
        tally.patterns += 1;
        for (syntaxes) |syntax| {
            errdefer std.debug.print("/{s}/ {any} on {any}\n", .{ case[0], syntax, case[1] });
            try check(case[0], syntax, case[1], &tally);
        }
    }
    errdefer std.debug.print("{any}\n", .{tally});
    // 237 patterns in three modes. The 60 refusals are what Rust's syntax refuses too, each as
    // Invalid: `\C` (any byte), RE2's octal escapes (`\01`, `\141`, ...), and Unicode classes in
    // bytes mode. Every search of the rest agrees with the test backtracker.
    try testing.expectEqual(Tally{ .patterns = 237, .compiled = 651, .invalid = 60, .unsupported = 0, .searches = 3906, .matched = 1651 }, tally);
}
