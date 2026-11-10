//! V8's verdicts on ECMAScript patterns (testdata/v8/matches.json, written by generate.mjs
//! under Node): what `exec` finds from the haystack's start, each group's span in UTF-8 bytes,
//! against what spectra's ECMAScript dialect finds.
const std = @import("std");
const strand = @import("strand");
const v8_verdicts = @import("v8_verdicts");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const testing = std.testing;

const Case = struct {
    pattern: []const u8,
    flags: []const u8,
    haystack: []const u8,
    match: ?[]const ?[2]usize,
};

const File = struct {
    node: []const u8,
    cases: []const Case,
};

fn syntaxOf(flags: []const u8) Syntax {
    var s: Syntax = .{ .dialect = .ecmascript, .unicode = false };
    for (flags) |f| switch (f) {
        'u' => s.unicode = true,
        'v' => s.unicode_sets = true,
        'i' => s.case_insensitive = true,
        'm' => s.multi_line = true,
        's' => s.dot_matches_new_line = true,
        else => unreachable,
    };
    return s;
}

const Tally = struct {
    cases: usize = 0,
    agree: usize = 0,
    /// Without `u` or `v`, half a code point past U+FFFF named alone: refused by name.
    refused_code_unit_split: usize = 0,
    /// Without `u` or `v`, over a haystack past U+FFFF: V8 reads UTF-16 code units, spectra a
    /// whole code point (`.`, a negated class).
    differ_code_units: usize = 0,
    /// A quantified group whose iteration can match empty: ECMA-262 fails such an iteration
    /// (RepeatMatcher's empty check), which spectra does not yet do. Every difference left is
    /// one: /(a*)*/, /(a*|b)*/, /(|a)+/, /(a*)?/ and patterns holding them.
    differ_repetition_span: usize = 0,
    differ_repetition_groups: usize = 0,
    /// Whether a match exists, outside the code unit cases: always V8's.
    is_match_differ: usize = 0,
};

fn codeUnits(case: Case) bool {
    if (std.mem.indexOfAny(u8, case.flags, "uv") != null) return false;
    for (case.haystack) |b| if (b >= 0xf0) return true;
    return false;
}

/// A group under a quantifier: `)` followed by `*`, `+`, `?` or `{`.
fn quantifiedGroup(pattern: []const u8) bool {
    for (pattern[0..pattern.len -| 1], 1..) |c, i| {
        if (c == ')' and std.mem.indexOfScalar(u8, "*+?{", pattern[i]) != null) return true;
    }
    return false;
}

fn spansEql(groups: []const ?Regex.Span, want: []const ?[2]usize) bool {
    if (groups.len != want.len) return false;
    for (groups, want) |g, w| {
        if ((g == null) != (w == null)) return false;
        if (g) |x| if (x.start != w.?[0] or x.end != w.?[1]) return false;
    }
    return true;
}

test "V8's verdicts, through the ECMAScript dialect" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const file = try strand.json.parseLeaky(File, a, v8_verdicts.bytes, .{});
    var tally: Tally = .{};
    // Cases of one pattern and flags come together: each is compiled once.
    var held: ?struct { case: Case, re: Regex, cache: Regex.Cache } = null;
    defer if (held) |*h| {
        h.cache.deinit(testing.allocator);
        h.re.deinit();
    };
    for (file.cases) |case| {
        tally.cases += 1;
        if (held) |*h| if (!std.mem.eql(u8, h.case.pattern, case.pattern) or !std.mem.eql(u8, h.case.flags, case.flags)) {
            h.cache.deinit(testing.allocator);
            h.re.deinit();
            held = null;
        };
        if (held == null) {
            var d: Regex.Diagnostic = .{};
            var re = Regex.compile(testing.allocator, .init(case.pattern), .{ .syntax = syntaxOf(case.flags), .diagnostic = &d }) catch |err| {
                if (err == error.Unsupported and d.reason == .unsupported_code_unit_split) {
                    tally.refused_code_unit_split += 1;
                    continue;
                }
                std.debug.print("/{s}/{s}: refused, {t} {t}\n", .{ case.pattern, case.flags, err, d.reason });
                return error.TestUnexpectedResult;
            };
            errdefer re.deinit();
            held = .{ .case = case, .re = re, .cache = try re.cache(testing.allocator) };
        }
        const re = &held.?.re;
        const cache = &held.?.cache;
        const groups = try a.alloc(?Regex.Span, re.captureCount());
        const found = re.captures(cache, .of(case.haystack), groups);
        const units = codeUnits(case);
        if (!units and found != (case.match != null)) tally.is_match_differ += 1;
        const same_span = if (case.match) |w| found and groups[0].?.start == w[0].?[0] and groups[0].?.end == w[0].?[1] else !found;
        if (same_span and (case.match == null or spansEql(groups, case.match.?))) {
            tally.agree += 1;
        } else if (units) {
            tally.differ_code_units += 1;
        } else if (quantifiedGroup(case.pattern)) {
            if (same_span) tally.differ_repetition_groups += 1 else tally.differ_repetition_span += 1;
        } else {
            std.debug.print("/{s}/{s} on {any}: {any}, V8 {any}\n", .{ case.pattern, case.flags, case.haystack, if (found) groups else null, case.match });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqualStrings("v26.10.0", file.node);
    // Counted, so a change in either direction shows. Captures clear per iteration (17 cases
    // came to agree); the empty check awaits its design.
    try testing.expectEqual(Tally{
        .cases = 9480,
        .agree = 9220,
        .refused_code_unit_split = 55,
        .differ_code_units = 8,
        .differ_repetition_span = 38,
        .differ_repetition_groups = 159,
        .is_match_differ = 0,
    }, tally);
}
