//! test262's RegExp cases that write a lookaround, their expected answers transcribed by hand
//! from the test files of test262 commit 2e58f87 (tc39/test262, BSD-3-Clause, the text in
//! LICENSES/test262-BSD.txt): test/built-ins/RegExp/lookBehind/*, test/built-ins/RegExp's
//! S15.10.2.8 and S15.10.2.13 lookahead cases, lookahead-quantifier-match-groups,
//! named-groups/lookbehind, unicode_restricted_quantifiable_assertion,
//! test/annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind and the twelve
//! test/language/literals/regexp/*lookahead*/*lookbehind* early errors: every one of the 52
//! files that writes a lookaround, property escapes aside. Each case names its file.
//!
//! What a case says is what its file asserts: each group's text (null for undefined) and, where
//! the file says, the match's index; null; whether `test` holds; every match of a global
//! `match`; a global regex's successive `exec` results; a named group's text; or an early error.
//! A case with a backreference is refused by name (`unsupported_backreference`), as spectra
//! refuses every backreference, and its pattern is still valid ECMA-262 to `ecmascript.validate`;
//! such a pattern is listed once for its file, whatever haystacks the file tries it on.
const std = @import("std");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const ecmascript = @import("syntax/ecma.zig");
const testing = std.testing;
const gpa = testing.allocator;

const Expect = union(enum) {
    /// `match` or `exec` without `g`: each group's text, null where undefined; and where the file
    /// asserts it, the index (UTF-16, here ASCII, so bytes).
    groups: struct { texts: []const ?[]const u8, at: ?usize = null },
    /// No match: `match` or `exec` gives null.
    none,
    /// `test`.
    any: bool,
    /// `match` with `g`: every match's text.
    matches: []const []const u8,
    /// A global regex's successive `exec` calls: each one's groups.
    execs: []const []const ?[]const u8,
    /// A named group's text.
    named: struct { name: []const u8, text: []const u8 },
    /// The groups' names, in order.
    names: []const []const u8,
    /// A backreference: refused by name; test262's answer is kept in the file's assertion.
    backreference,
    /// An early error: a `SyntaxError` before anything runs.
    invalid,
};

const Case = struct {
    file: []const u8,
    pattern: []const u8,
    flags: []const u8 = "",
    haystack: []const u8 = "",
    expect: Expect,
};

fn g(texts: []const ?[]const u8) Expect {
    return .{ .groups = .{ .texts = texts } };
}

fn gAt(texts: []const ?[]const u8, at: usize) Expect {
    return .{ .groups = .{ .texts = texts, .at = at } };
}

const lb = "test/built-ins/RegExp/lookBehind/";
const re = "test/built-ins/RegExp/";
const lit = "test/language/literals/regexp/";
const named_lb = "test/built-ins/RegExp/named-groups/lookbehind.js";
const restricted = "test/built-ins/RegExp/unicode_restricted_quantifiable_assertion.js";

const cases = [_]Case{
    // lookBehind/alternations.js
    .{ .file = lb ++ "alternations.js", .pattern = ".*(?<=(..|...|....))(.*)", .haystack = "xabcd", .expect = g(&.{ "xabcd", "cd", "" }) },
    .{ .file = lb ++ "alternations.js", .pattern = ".*(?<=(xx|...|....))(.*)", .haystack = "xabcd", .expect = g(&.{ "xabcd", "bcd", "" }) },
    .{ .file = lb ++ "alternations.js", .pattern = ".*(?<=(xx|...))(.*)", .haystack = "xxabcd", .expect = g(&.{ "xxabcd", "bcd", "" }) },
    .{ .file = lb ++ "alternations.js", .pattern = ".*(?<=(xx|xxx))(.*)", .haystack = "xxabcd", .expect = g(&.{ "xxabcd", "xx", "abcd" }) },
    // lookBehind/back-references-to-captures.js
    .{ .file = lb ++ "back-references-to-captures.js", .pattern = "(?<=\\1(\\w))d", .flags = "i", .haystack = "abcCd", .expect = .backreference },
    .{ .file = lb ++ "back-references-to-captures.js", .pattern = "(?<=\\1([abx]))d", .haystack = "abxxd", .expect = .backreference },
    .{ .file = lb ++ "back-references-to-captures.js", .pattern = "(?<=\\1(\\w+))c", .haystack = "ababc", .expect = .backreference },
    .{ .file = lb ++ "back-references-to-captures.js", .pattern = "(?<=(\\w+)\\1)c", .haystack = "ababc", .expect = .backreference },
    // lookBehind/back-references.js
    .{ .file = lb ++ "back-references.js", .pattern = "(.)(?<=(\\1\\1))", .haystack = "abb", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(.)(?<=(\\1\\1))", .flags = "i", .haystack = "abB", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "((\\w)\\w)(?<=\\1\\2\\1)", .flags = "i", .haystack = "aabAaBa", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(\\w(\\w))(?<=\\1\\2\\1)", .flags = "i", .haystack = "aabAaBa", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(?=(\\w))(?<=(\\1)).", .flags = "i", .haystack = "abaBbAa", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(?<=(.))(\\w+)(?=\\1)", .haystack = "  'foo'  ", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(.)(?<=\\1\\1\\1)", .haystack = "abbb", .expect = .backreference },
    .{ .file = lb ++ "back-references.js", .pattern = "(..)(?<=\\1\\1\\1)", .haystack = "fababab", .expect = .backreference },
    // lookBehind/captures-negative.js
    .{ .file = lb ++ "captures-negative.js", .pattern = "(?<!(^|[ab]))\\w{2}", .haystack = "abcdef", .expect = g(&.{ "de", null }) },
    // lookBehind/captures.js
    .{ .file = lb ++ "captures.js", .pattern = "(?<=(c))def", .haystack = "abcdef", .expect = g(&.{ "def", "c" }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=(\\w{2}))def", .haystack = "abcdef", .expect = g(&.{ "def", "bc" }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=(\\w(\\w)))def", .haystack = "abcdef", .expect = g(&.{ "def", "bc", "c" }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=(\\w){3})def", .haystack = "abcdef", .expect = g(&.{ "def", "a" }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=(bc)|(cd)).", .haystack = "abcdef", .expect = g(&.{ "d", "bc", null }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=([ab]{1,2})\\D|(abc))\\w", .haystack = "abcdef", .expect = g(&.{ "c", "a", null }) },
    .{ .file = lb ++ "captures.js", .pattern = "\\D(?<=([ab]+))(\\w)", .haystack = "abcdef", .expect = g(&.{ "ab", "a", "b" }) },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=b|c)\\w", .haystack = "abcdef", .expect = .{ .matches = &.{ "c", "d" } } },
    .{ .file = lb ++ "captures.js", .pattern = "(?<=[b-e])\\w{2}", .haystack = "abcdef", .expect = .{ .matches = &.{ "cd", "ef" } } },
    // lookBehind/do-not-backtrack.js
    .{ .file = lb ++ "do-not-backtrack.js", .pattern = "(?<=([abc]+)).\\1", .haystack = "abcdbc", .expect = .backreference },
    // lookBehind/greedy-loop.js
    .{ .file = lb ++ "greedy-loop.js", .pattern = "(?<=(b+))c", .haystack = "abbbbbbc", .expect = g(&.{ "c", "bbbbbb" }) },
    .{ .file = lb ++ "greedy-loop.js", .pattern = "(?<=(b\\d+))c", .haystack = "ab1234c", .expect = g(&.{ "c", "b1234" }) },
    .{ .file = lb ++ "greedy-loop.js", .pattern = "(?<=((?:b\\d{2})+))c", .haystack = "ab12b23b34c", .expect = g(&.{ "c", "b12b23b34" }) },
    // lookBehind/misc.js
    .{ .file = lb ++ "misc.js", .pattern = "(?<=$abc)def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "misc.js", .pattern = "^f.o(?<=foo)$", .haystack = "fno", .expect = .none },
    .{ .file = lb ++ "misc.js", .pattern = "^foo(?<!foo)$", .haystack = "foo", .expect = .none },
    .{ .file = lb ++ "misc.js", .pattern = "^f.o(?<!foo)$", .haystack = "foo", .expect = .none },
    .{ .file = lb ++ "misc.js", .pattern = "^foo(?<=foo)$", .haystack = "foo", .expect = g(&.{"foo"}) },
    .{ .file = lb ++ "misc.js", .pattern = "^f.o(?<=foo)$", .haystack = "foo", .expect = g(&.{"foo"}) },
    .{ .file = lb ++ "misc.js", .pattern = "^f.o(?<!foo)$", .haystack = "fno", .expect = g(&.{"fno"}) },
    .{ .file = lb ++ "misc.js", .pattern = "^foooo(?<=fo+)$", .haystack = "foooo", .expect = g(&.{"foooo"}) },
    .{ .file = lb ++ "misc.js", .pattern = "^foooo(?<=fo*)$", .haystack = "foooo", .expect = g(&.{"foooo"}) },
    .{ .file = lb ++ "misc.js", .pattern = "(abc\\1)", .haystack = "abc", .expect = .backreference },
    .{ .file = lb ++ "misc.js", .pattern = "(abc\\1)", .flags = "i", .haystack = "abc", .expect = .backreference },
    // lookBehind/mutual-recursive.js
    .{ .file = lb ++ "mutual-recursive.js", .pattern = "(?<=a(.\\2)b(\\1)).{4}", .haystack = "aabcacbc", .expect = .backreference },
    .{ .file = lb ++ "mutual-recursive.js", .pattern = "(?<=a(\\2)b(..\\1))b", .haystack = "aacbacb", .expect = .backreference },
    .{ .file = lb ++ "mutual-recursive.js", .pattern = "(?<=(?:\\1b)(aa)).", .haystack = "aabaax", .expect = .backreference },
    .{ .file = lb ++ "mutual-recursive.js", .pattern = "(?<=(?:\\1|b)(aa)).", .haystack = "aaaax", .expect = .backreference },
    // lookBehind/negative.js
    .{ .file = lb ++ "negative.js", .pattern = "(?<!abc)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"abc"}) },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a.c)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"abc"}) },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a\\wc)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"abc"}) },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a[a-z])\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"abc"}) },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a[a-z]{2})\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"abc"}) },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!abc)def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a.c)def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a\\wc)def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a[a-z][a-z])def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a[a-z]{2})def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a{1}b{1})cde", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "negative.js", .pattern = "(?<!a{1}[a-z]{2})def", .haystack = "abcdef", .expect = .none },
    // lookBehind/nested-lookaround.js
    .{ .file = lb ++ "nested-lookaround.js", .pattern = "(?<=ab(?=c)\\wd)\\w\\w", .haystack = "abcdef", .expect = g(&.{"ef"}) },
    .{ .file = lb ++ "nested-lookaround.js", .pattern = "(?<=a(?=([^a]{2})d)\\w{3})\\w\\w", .haystack = "abcdef", .expect = g(&.{ "ef", "bc" }) },
    .{ .file = lb ++ "nested-lookaround.js", .pattern = "(?<=a(?=([bc]{2}(?<!a{2}))d)\\w{3})\\w\\w", .haystack = "abcdef", .expect = g(&.{ "ef", "bc" }) },
    .{ .file = lb ++ "nested-lookaround.js", .pattern = "^faaao?(?<=^f[oa]+(?=o))", .haystack = "faaao", .expect = g(&.{"faaa"}) },
    .{ .file = lb ++ "nested-lookaround.js", .pattern = "(?<=a(?=([bc]{2}(?<!a*))d)\\w{3})\\w\\w", .haystack = "abcdef", .expect = .none },
    // lookBehind/simple-fixed-length.js
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^.(?<=a)", .haystack = "b", .expect = .none },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^f\\w\\w(?<=\\woo)", .haystack = "boo", .expect = .none },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^f\\w\\w(?<=\\woo)", .haystack = "fao", .expect = .none },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^f\\w\\w(?<=\\woo)", .haystack = "foa", .expect = .none },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^.(?<=a)", .haystack = "a", .expect = g(&.{"a"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^f..(?<=.oo)", .haystack = "foo1", .expect = g(&.{"foo"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "^f\\w\\w(?<=\\woo)", .haystack = "foo2", .expect = g(&.{"foo"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=abc)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a.c)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a\\wc)\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a[a-z])\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"cde"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a[a-z][a-z])\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a[a-z]{2})\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a{1})\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"bcd"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a{1}b{1})\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"cde"}) },
    .{ .file = lb ++ "simple-fixed-length.js", .pattern = "(?<=a{1}[a-z]{2})\\w\\w\\w", .haystack = "abcdef", .expect = g(&.{"def"}) },
    // lookBehind/sliced-strings.js
    .{ .file = lb ++ "sliced-strings.js", .pattern = "(?=(abcdefghijklmn))(?<=\\1)a", .flags = "i", .haystack = "abcdefghijklmn", .expect = .backreference },
    .{ .file = lb ++ "sliced-strings.js", .pattern = "(?=(abcdefghijklmn))(?<=\\1)a", .haystack = "abcdefghijklmn", .expect = .backreference },
    .{ .file = lb ++ "sliced-strings.js", .pattern = "(?=(abcdefg))(?<=\\1)", .haystack = "bcdefgabcdefg", .expect = .backreference },
    // lookBehind/start-of-line.js
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^[^a-c]{3})def", .haystack = "abcdef", .expect = .none },
    .{ .file = lb ++ "start-of-line.js", .pattern = "\"^foooo(?<=^o+)$", .haystack = "foooo", .expect = .none },
    .{ .file = lb ++ "start-of-line.js", .pattern = "\"^foooo(?<=^o*)$", .haystack = "foooo", .expect = .none },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^abc)def", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^[a-c]{3})def", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^[a-c]{3})def", .flags = "m", .haystack = "xyz\nabcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^)\\w+", .flags = "m", .haystack = "ab\ncd\nefg", .expect = .{ .matches = &.{ "ab", "cd", "efg" } } },
    .{ .file = lb ++ "start-of-line.js", .pattern = "\\w+(?<=$)", .flags = "m", .haystack = "ab\ncd\nefg", .expect = .{ .matches = &.{ "ab", "cd", "efg" } } },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^)\\w+(?<=$)", .flags = "m", .haystack = "ab\ncd\nefg", .expect = .{ .matches = &.{ "ab", "cd", "efg" } } },
    .{ .file = lb ++ "start-of-line.js", .pattern = "^foo(?<=^fo+)$", .haystack = "foo", .expect = g(&.{"foo"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "^foooo(?<=^fo*)", .haystack = "foooo", .expect = g(&.{"foooo"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "^(f)oo(?<=^\\1o+)$", .haystack = "foo", .expect = .backreference },
    .{ .file = lb ++ "start-of-line.js", .pattern = "^(f)oo(?<=^\\1o+)$", .flags = "i", .haystack = "foo", .expect = .backreference },
    .{ .file = lb ++ "start-of-line.js", .pattern = "^(f)oo(?<=^\\1o+).$", .flags = "i", .haystack = "foo\u{1234}", .expect = .backreference },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^\\w+)def", .haystack = "abcdefdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "start-of-line.js", .pattern = "(?<=^\\w+)def", .haystack = "abcdefdef", .expect = .{ .matches = &.{ "def", "def" } } },
    // lookBehind/sticky.js
    .{ .file = lb ++ "sticky.js", .pattern = "(?<=^(\\w+))def", .haystack = "abcdefdef", .expect = .{ .execs = &.{ &.{ "def", "abc" }, &.{ "def", "abcdef" } } } },
    .{ .file = lb ++ "sticky.js", .pattern = "\\Bdef", .haystack = "abcdefdef", .expect = .{ .execs = &.{ &.{"def"}, &.{"def"} } } },
    // lookBehind/variable-length.js
    .{ .file = lb ++ "variable-length.js", .pattern = "(?<=[a|b|c]*)[^a|b|c]{3}", .haystack = "abcdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "variable-length.js", .pattern = "(?<=\\w*)[^a|b|c]{3}", .haystack = "abcdef", .expect = g(&.{"def"}) },
    // lookBehind/word-boundary.js
    .{ .file = lb ++ "word-boundary.js", .pattern = "(?<=\\b)[d-f]{3}", .haystack = "abc def", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "word-boundary.js", .pattern = "(?<=\\B)\\w{3}", .haystack = "ab cdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "word-boundary.js", .pattern = "(?<=\\B)(?<=c(?<=\\w))\\w{3}", .haystack = "ab cdef", .expect = g(&.{"def"}) },
    .{ .file = lb ++ "word-boundary.js", .pattern = "(?<=\\b)[d-f]{3}", .haystack = "abcdef", .expect = .none },
    // named-groups/lookbehind.js, with `u` and without.
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){3})f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", "c" }) },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){3})f", .flags = "u", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "c" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){4})f", .flags = "u", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "b" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w)+)f", .flags = "u", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "a" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){6})f", .flags = "u", .haystack = "abcdef", .expect = .none },
    .{ .file = named_lb, .pattern = "((?<=\\w{3}))f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", "" }) },
    .{ .file = named_lb, .pattern = "(?<a>(?<=\\w{3}))f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", "" }) },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\d){3})f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\D){3})f", .flags = "u", .haystack = "abcdef", .expect = .none },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\D){3})f|f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<a>(?<!\\D{3}))f|f", .flags = "u", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){3})f", .haystack = "abcdef", .expect = g(&.{ "f", "c" }) },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){3})f", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "c" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){4})f", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "b" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w)+)f", .haystack = "abcdef", .expect = .{ .named = .{ .name = "a", .text = "a" } } },
    .{ .file = named_lb, .pattern = "(?<=(?<a>\\w){6})f", .haystack = "abcdef", .expect = .none },
    .{ .file = named_lb, .pattern = "((?<=\\w{3}))f", .haystack = "abcdef", .expect = g(&.{ "f", "" }) },
    .{ .file = named_lb, .pattern = "(?<a>(?<=\\w{3}))f", .haystack = "abcdef", .expect = g(&.{ "f", "" }) },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\d){3})f", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\D){3})f", .haystack = "abcdef", .expect = .none },
    .{ .file = named_lb, .pattern = "(?<!(?<a>\\D){3})f|f", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<a>(?<!\\D{3}))f|f", .haystack = "abcdef", .expect = g(&.{ "f", null }) },
    .{ .file = named_lb, .pattern = "(?<=(?<fst>.)|(?<snd>.))", .flags = "u", .haystack = "abcd", .expect = .{ .names = &.{ "fst", "snd" } } },
    // annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind.js: without `u` and
    // without named groups, `\k` is an identity escape.
    .{ .file = "test/annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind.js", .pattern = "\\k<a>(?<=>)a", .haystack = "k<a>a", .expect = .{ .any = true } },
    .{ .file = "test/annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind.js", .pattern = "(?<=>)\\k<a>", .haystack = ">k<a>", .expect = .{ .any = true } },
    .{ .file = "test/annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind.js", .pattern = "\\k<a>(?<!a)a", .haystack = "k<a>a", .expect = .{ .any = true } },
    .{ .file = "test/annexB/built-ins/RegExp/named-groups/non-unicode-malformed-lookbehind.js", .pattern = "(?<!a>)\\k<a>", .haystack = "k<a>", .expect = .{ .any = true } },
    // lookahead-quantifier-match-groups.js
    .{ .file = re ++ "lookahead-quantifier-match-groups.js", .pattern = "(?:(?=(abc)))a", .haystack = "abc", .expect = g(&.{ "a", "abc" }) },
    .{ .file = re ++ "lookahead-quantifier-match-groups.js", .pattern = "(?:(?=(abc)))?a", .haystack = "abc", .expect = g(&.{ "a", null }) },
    .{ .file = re ++ "lookahead-quantifier-match-groups.js", .pattern = "(?:(?=(abc))){1,1}a", .haystack = "abc", .expect = g(&.{ "a", "abc" }) },
    .{ .file = re ++ "lookahead-quantifier-match-groups.js", .pattern = "(?:(?=(abc))){0,1}a", .haystack = "abc", .expect = g(&.{ "a", null }) },
    // S15.10.2.13 and S15.10.2.8: lookahead.
    .{ .file = re ++ "S15.10.2.13_A1_T3.js", .pattern = "q[ax-zb](?=\\s+)", .haystack = "qYqy ", .expect = gAt(&.{"qy"}, 2) },
    .{ .file = re ++ "S15.10.2.13_A1_T4.js", .pattern = "q[ax-zb](?=\\s+)", .haystack = "tqaqy ", .expect = gAt(&.{"qy"}, 3) },
    .{ .file = re ++ "S15.10.2.13_A1_T5.js", .pattern = "q[ax-zb](?=\\s+)", .haystack = "tqa\t  qy ", .expect = gAt(&.{"qa"}, 1) },
    .{ .file = re ++ "S15.10.2.8_A1_T1.js", .pattern = "(?=(a+))", .haystack = "baaabac", .expect = gAt(&.{ "", "aaa" }, 1) },
    .{ .file = re ++ "S15.10.2.8_A1_T2.js", .pattern = "(?=(a+))a*b\\1", .haystack = "baaabac", .expect = .backreference },
    .{ .file = re ++ "S15.10.2.8_A1_T3.js", .pattern = "[Jj]ava([Ss]cript)?(?=\\:)", .haystack = "just Javascript: the way af jedi", .expect = gAt(&.{ "Javascript", "script" }, 5) },
    .{ .file = re ++ "S15.10.2.8_A1_T4.js", .pattern = "[Jj]ava([Ss]cript)?(?=\\:)", .haystack = "taste of java: the cookbook ", .expect = gAt(&.{ "java", null }, 9) },
    .{ .file = re ++ "S15.10.2.8_A1_T5.js", .pattern = "[Jj]ava([Ss]cript)?(?=\\:)", .haystack = "rhino is JavaScript engine", .expect = .{ .any = false } },
    .{ .file = re ++ "S15.10.2.8_A2_T1.js", .pattern = "(.*?)a(?!(a+)b\\2c)\\2(.*)", .haystack = "baaabaac", .expect = .backreference },
    .{ .file = re ++ "S15.10.2.8_A2_T2.js", .pattern = "Java(?!Script)([A-Z]\\w*)", .haystack = "using of JavaBeans technology", .expect = gAt(&.{ "JavaBeans", "Beans" }, 9) },
    .{ .file = re ++ "S15.10.2.8_A2_T3.js", .pattern = "Java(?!Script)([A-Z]\\w*)", .haystack = "using of Java language", .expect = .{ .any = false } },
    .{ .file = re ++ "S15.10.2.8_A2_T4.js", .pattern = "Java(?!Script)([A-Z]\\w*)", .haystack = "i'm a JavaScripter ", .expect = .{ .any = false } },
    .{ .file = re ++ "S15.10.2.8_A2_T5.js", .pattern = "Java(?!Script)([A-Z]\\w*)", .haystack = "JavaScr oops ipt ", .expect = gAt(&.{ "JavaScr", "Scr" }, 0) },
    .{ .file = re ++ "S15.10.2.8_A2_T6.js", .pattern = "(\\.(?!com|org)|\\/)", .haystack = "ah.info", .expect = gAt(&.{ ".", "." }, 2) },
    .{ .file = re ++ "S15.10.2.8_A2_T7.js", .pattern = "(\\.(?!com|org)|\\/)", .haystack = "ah/info", .expect = gAt(&.{ "/", "/" }, 2) },
    .{ .file = re ++ "S15.10.2.8_A2_T8.js", .pattern = "(\\.(?!com|org)|\\/)", .haystack = "ah.com", .expect = .{ .any = false } },
    .{ .file = re ++ "S15.10.2.8_A2_T9.js", .pattern = "(?!a|b)|c", .haystack = "", .expect = gAt(&.{""}, 0) },
    .{ .file = re ++ "S15.10.2.8_A2_T10.js", .pattern = "(?!a|b)|c", .haystack = "bc", .expect = gAt(&.{""}, 1) },
    .{ .file = re ++ "S15.10.2.8_A2_T11.js", .pattern = "(?!a|b)|c", .haystack = "d", .expect = gAt(&.{""}, 0) },
    // unicode_restricted_quantifiable_assertion.js: with `u`, no lookahead is quantifiable.
    .{ .file = restricted, .pattern = "(?=.)*", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.)+", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.)?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1,}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1,2}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.)*?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.)+?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.)??", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1}?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1,}?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?=.){1,2}?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)*", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)+", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1,}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1,2}", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)*?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)+?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.)??", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1}?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1,}?", .flags = "u", .expect = .invalid },
    .{ .file = restricted, .pattern = "(?!.){1,2}?", .flags = "u", .expect = .invalid },
    // test/language/literals/regexp: a lookbehind is never quantifiable; with `u`, nor a
    // lookahead.
    .{ .file = lit ++ "invalid-optional-lookbehind.js", .pattern = ".(?<=.)?", .expect = .invalid },
    .{ .file = lit ++ "invalid-optional-negative-lookbehind.js", .pattern = ".(?<!.)?", .expect = .invalid },
    .{ .file = lit ++ "invalid-range-lookbehind.js", .pattern = ".(?<=.){2,3}", .expect = .invalid },
    .{ .file = lit ++ "invalid-range-negative-lookbehind.js", .pattern = ".(?<!.){2,3}", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-optional-lookahead.js", .pattern = ".(?=.)?", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-optional-lookbehind.js", .pattern = ".(?<=.)?", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-optional-negative-lookahead.js", .pattern = ".(?!.)?", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-optional-negative-lookbehind.js", .pattern = ".(?<!.)?", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-range-lookahead.js", .pattern = ".(?=.){2,3}", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-range-lookbehind.js", .pattern = ".(?<=.){2,3}", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-range-negative-lookahead.js", .pattern = ".(?!.){2,3}", .flags = "u", .expect = .invalid },
    .{ .file = lit ++ "u-invalid-range-negative-lookbehind.js", .pattern = ".(?<!.){2,3}", .flags = "u", .expect = .invalid },
};

fn syntaxOf(flags: []const u8) Syntax {
    var s: Syntax = .{ .dialect = .ecmascript, .unicode = false };
    for (flags) |f| switch (f) {
        'u' => s.unicode = true,
        'i' => s.case_insensitive = true,
        'm' => s.multi_line = true,
        's' => s.dot_matches_new_line = true,
        else => unreachable,
    };
    return s;
}

fn text(haystack: []const u8, span: ?Regex.Span) ?[]const u8 {
    const sp = span orelse return null;
    return haystack[sp.start..sp.end];
}

fn expectTexts(want: []const ?[]const u8, haystack: []const u8, got: []const ?Regex.Span) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, sp| {
        const t = text(haystack, sp);
        try testing.expectEqual(w == null, t == null);
        if (w) |x| try testing.expectEqualStrings(x, t.?);
    }
}

const Tally = struct { cases: usize = 0, searched: usize = 0, refused_backreference: usize = 0, invalid: usize = 0, files: usize = 0 };

fn run(case: Case, tally: *Tally) !void {
    tally.cases += 1;
    var d: Regex.Diagnostic = .{};
    const valid = try ecmascript.validate(gpa, .init(case.pattern), case.flags, .{}, null);
    const compiled = Regex.compile(gpa, .init(case.pattern), .{ .syntax = syntaxOf(case.flags), .diagnostic = &d });
    switch (case.expect) {
        .invalid => {
            try testing.expect(!valid);
            try testing.expectError(error.Invalid, compiled);
            tally.invalid += 1;
            return;
        },
        .backreference => {
            try testing.expect(valid);
            try testing.expectError(error.Unsupported, compiled);
            try testing.expectEqual(.unsupported_backreference, d.reason);
            tally.refused_backreference += 1;
            return;
        },
        else => {},
    }
    try testing.expect(valid);
    var r = try compiled;
    defer r.deinit();
    var c = try r.cache(gpa);
    defer c.deinit(gpa);
    const groups = try gpa.alloc(?Regex.Span, r.captureCount());
    defer gpa.free(groups);
    const h = case.haystack;
    switch (case.expect) {
        .groups => |want| {
            try testing.expect(try r.captures(&c, .of(h), groups));
            try expectTexts(want.texts, h, groups);
            if (want.at) |at| try testing.expectEqual(at, groups[0].?.start);
            try testing.expect(try r.isMatch(&c, h));
        },
        .none => {
            try testing.expect(!try r.captures(&c, .of(h), groups));
            try testing.expect(!try r.isMatch(&c, h));
        },
        .any => |want| try testing.expectEqual(want, try r.isMatch(&c, h)),
        .matches => |want| {
            var it = r.findAll(&c, h);
            for (want) |w| try testing.expectEqualStrings(w, text(h, try it.next()).?);
            try testing.expectEqual(null, try it.next());
        },
        .execs => |want| {
            var it = r.findAll(&c, h);
            for (want) |w| {
                try testing.expect(try it.nextCaptures(groups));
                try expectTexts(w, h, groups);
            }
        },
        .named => |want| {
            try testing.expect(try r.captures(&c, .of(h), groups));
            const index = r.captureIndex(want.name).?;
            try testing.expectEqualStrings(want.text, text(h, groups[index]).?);
        },
        .names => |want| for (want, 1..) |name, i| try testing.expectEqual(@as(?u32, @intCast(i)), r.captureIndex(name)),
        .invalid, .backreference => unreachable,
    }
    tally.searched += 1;
}

test "test262's lookaround cases, transcribed: each file's expected answers" {
    var tally: Tally = .{};
    var last: []const u8 = "";
    for (cases) |case| {
        errdefer std.debug.print("{s}: /{s}/{s} on {any}\n", .{ case.file, case.pattern, case.flags, case.haystack });
        try run(case, &tally);
        if (!std.mem.eql(u8, case.file, last)) tally.files += 1;
        last = case.file;
    }
    errdefer std.debug.print("{any}\n", .{tally});
    // Every one of the 52 files; a backreference refused by name, an early error invalid.
    try testing.expectEqual(Tally{ .cases = cases.len, .searched = 128, .refused_backreference = 27, .invalid = 36, .files = 52 }, tally);
}
