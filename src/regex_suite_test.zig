//! regex's own test suite (regex 1.13.1's testdata/*.toml, vendored in testdata/regex), read
//! through strand's TOML and run as regex runs it on its own engine: each test as is-match,
//! every match in turn, and every match's captures. What spectra does not offer is passed over
//! and counted by reason: more than one pattern (sets come later), the overlapping and earliest
//! searches, leftmost-longest matching, and a line terminator other than `\n`.
//!
//! regex bounds a repetition only by the automaton's size, so the suite compiles with
//! `Limits.repetition` at its largest. The break properties (Grapheme_Cluster_Break,
//! Word_Break, Sentence_Break) are xenoglyph's gap: it answers them for one code point and
//! holds no ranges of them. Until it does, the tests naming them must be refused by name,
//! `unsupported_unicode_property`, and nothing else may fail.
const std = @import("std");
const strand = @import("strand");
const regex_suite = @import("regex_suite");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const testing = std.testing;
const Value = strand.toml.Value;

const Span = Regex.Span;

const Expected = struct {
    /// Each match's groups, the whole match first; a span-only file gives the whole match alone.
    matches: []const []const ?Span,
    groups_given: bool,
};

/// regex's tests that name a break property, refused until xenoglyph holds their ranges.
const break_property_tests = [_][]const u8{
    "class-gcb1",            "class-gcb2",            "class-gcb3",            "class-gcb5",
    "class-gcb6",            "class-word-break1",     "class-word-break2",     "class-word-break3",
    "class-word-break4",     "class-word-break5",     "class-sentence-break1", "class-sentence-break2",
    "class-sentence-break3", "class-sentence-break4", "class-sentence-break5",
};

fn awaitsBreakProperties(file: []const u8, name: []const u8) bool {
    if (!std.mem.eql(u8, file, "unicode")) return false;
    for (break_property_tests) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const Tally = struct {
    run: usize = 0,
    passed: usize = 0,
    refused_break_property: usize = 0,
    failed: usize = 0,
    skipped_sets: usize = 0,
    skipped_search_kind: usize = 0,
    skipped_match_kind: usize = 0,
    skipped_line_terminator: usize = 0,
};

fn field(test_value: Value, key: []const u8) ?Value {
    return test_value.get(key);
}

fn flag(test_value: Value, key: []const u8, default: bool) bool {
    const v = field(test_value, key) orelse return default;
    return v.boolean;
}

fn text(test_value: Value, key: []const u8) ?[]const u8 {
    const v = field(test_value, key) orelse return null;
    return v.string;
}

fn int(v: Value) usize {
    return @intCast(v.integer);
}

fn spanOf(v: Value) ?Span {
    switch (v) {
        .array => |pair| {
            if (pair.len == 0) return null;
            return .{ .start = int(pair[0]), .end = int(pair[1]) };
        },
        .table => return .{ .start = int(v.get("start").?), .end = int(v.get("end").?) },
        else => unreachable,
    }
}

/// regex-test's unescaping of a haystack: `\xNN`, `\n`, `\r`, `\t`, `\0` and `\\`.
fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 == s.len) {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'x' => {
                try out.append(a, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
                i += 2;
            },
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            '0' => try out.append(a, 0),
            '\\' => try out.append(a, '\\'),
            else => try out.appendSlice(a, s[i - 1 .. i + 1]),
        }
    }
    return out.items;
}

fn expected(a: std.mem.Allocator, matches: []const Value) !Expected {
    var list: std.ArrayList([]const ?Span) = .empty;
    var groups_given = false;
    for (matches) |m| {
        // [s, e]; [[s, e], [], ...]; { id, span }; { id, spans }.
        const groups: []const Value, const one: bool = switch (m) {
            .array => |items| if (items.len > 0 and items[0] == .integer) .{ &.{m}, true } else .{ items, false },
            .table => if (m.get("spans")) |spans| .{ spans.array, false } else .{ &.{m.get("span").?}, true },
            else => unreachable,
        };
        if (!one) groups_given = true;
        const spans = try a.alloc(?Span, groups.len);
        for (groups, spans) |g, *s| s.* = spanOf(g);
        try list.append(a, spans);
    }
    return .{ .matches = list.items, .groups_given = groups_given };
}

fn runOne(a: std.mem.Allocator, file: []const u8, t: Value, tally: *Tally) !void {
    const name = text(t, "name").?;
    const pattern: []const u8 = switch (field(t, "regex").?) {
        .string => |s| s,
        .array => |list| if (list.len == 1) list[0].string else {
            tally.skipped_sets += 1;
            return;
        },
        else => unreachable,
    };
    if (text(t, "search-kind")) |kind| if (!std.mem.eql(u8, kind, "leftmost")) {
        tally.skipped_search_kind += 1;
        return;
    };
    if (text(t, "match-kind")) |kind| if (!std.mem.eql(u8, kind, "leftmost-first")) {
        tally.skipped_match_kind += 1;
        return;
    };
    if (text(t, "line-terminator")) |term| if (!std.mem.eql(u8, term, "\n")) {
        tally.skipped_line_terminator += 1;
        return;
    };
    tally.run += 1;
    var haystack = text(t, "haystack").?;
    if (flag(t, "unescape", false)) haystack = try unescape(a, haystack);
    const syntax: Syntax = .{
        .unicode = flag(t, "unicode", true),
        .utf8 = flag(t, "utf8", true),
        .case_insensitive = flag(t, "case-insensitive", false),
    };
    var d: Regex.Diagnostic = .{};
    const limits: @import("Limits.zig") = .{ .repetition = .literal(100_000) };
    var re = Regex.compile(testing.allocator, .init(pattern), .{ .syntax = syntax, .limits = limits, .diagnostic = &d }) catch |err| {
        if (awaitsBreakProperties(file, name) and err == error.Unsupported and d.reason == .unsupported_unicode_property) {
            tally.refused_break_property += 1;
            return;
        }
        if (flag(t, "compiles", true)) {
            std.debug.print("{s}/{s}: /{s}/ refused: {t} {t}\n", .{ file, name, pattern, err, d.reason });
            tally.failed += 1;
        } else tally.passed += 1;
        return;
    };
    defer re.deinit();
    if (awaitsBreakProperties(file, name)) {
        std.debug.print("{s}/{s}: /{s}/ compiled: take it off the break property list\n", .{ file, name, pattern });
        tally.failed += 1;
        return;
    }
    if (!flag(t, "compiles", true)) {
        std.debug.print("{s}/{s}: /{s}/ compiled, regex refuses it\n", .{ file, name, pattern });
        tally.failed += 1;
        return;
    }
    var cache = try re.cache(testing.allocator);
    defer cache.deinit(testing.allocator);
    const want = try expected(a, field(t, "matches").?.array);
    var input: Regex.Input = .of(haystack);
    if (field(t, "bounds")) |b| input.span = spanOf(b).?;
    input.anchored = flag(t, "anchored", false);
    const limit: usize = if (field(t, "match-limit")) |l| int(l) else std.math.maxInt(usize);

    // Is-match, over the whole haystack as regex asks it, when the test does not bound it.
    if (input.span.start == 0 and input.span.end == haystack.len and !input.anchored) {
        if (re.isMatch(&cache, haystack) != (want.matches.len > 0)) {
            std.debug.print("{s}/{s}: /{s}/ is-match {}\n", .{ file, name, pattern, want.matches.len == 0 });
            tally.failed += 1;
            return;
        }
    }
    // Every match, then every match's groups.
    var it = re.findAllIn(&cache, input);
    var k: usize = 0;
    while (k < limit) : (k += 1) {
        const m = it.next() orelse break;
        if (k >= want.matches.len or !std.meta.eql(want.matches[k][0], @as(?Span, m))) {
            std.debug.print("{s}/{s}: /{s}/ find {d}: {any}, want {any}\n", .{ file, name, pattern, k, m, if (k < want.matches.len) want.matches[k][0] else null });
            tally.failed += 1;
            return;
        }
    }
    if (k != @min(limit, want.matches.len)) {
        std.debug.print("{s}/{s}: /{s}/ find: {d} matches, want {d}\n", .{ file, name, pattern, k, want.matches.len });
        tally.failed += 1;
        return;
    }
    const groups = try a.alloc(?Span, re.captureCount());
    var caps = re.findAllIn(&cache, input);
    k = 0;
    while (k < limit and caps.nextCaptures(groups)) : (k += 1) {
        const w = want.matches[k];
        const compared = if (want.groups_given) groups else groups[0..1];
        if (w.len != compared.len or !std.meta.eql(w, compared) and !spansEql(w, compared)) {
            std.debug.print("{s}/{s}: /{s}/ captures {d}: {any}, want {any}\n", .{ file, name, pattern, k, compared, w });
            tally.failed += 1;
            return;
        }
    }
    tally.passed += 1;
}

fn spansEql(a: []const ?Span, b: []const ?Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

test "regex's own test suite, through the Rust dialect" {
    var tally: Tally = .{};
    for (regex_suite.files) |file| {
        var state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer state.deinit();
        const a = state.allocator();
        const doc = try strand.toml.parseLeaky(Value, a, file.bytes, .{});
        const tests = (doc.get("test") orelse continue).array;
        for (tests) |t| try runOne(a, file.name, t, &tally);
    }
    try testing.expectEqual(@as(usize, 0), tally.failed);
    // Counted, so a test quietly passed over shows: 1076 run, 1061 agree, 15 await xenoglyph.
    try testing.expectEqual(Tally{
        .run = 1076,
        .passed = 1061,
        .refused_break_property = 15,
        .skipped_sets = 53,
        .skipped_search_kind = 50,
        .skipped_match_kind = 4,
        .skipped_line_terminator = 11,
    }, tally);
}
