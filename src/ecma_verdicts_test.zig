//! V8's verdicts on ECMAScript patterns (testdata/v8/matches.json, written by generate.mjs
//! under Node): what `exec` finds from the haystack's start, each group's span in UTF-8 bytes,
//! against what spectra's ECMAScript dialect finds.
const std = @import("std");
const strand = @import("strand");
const shakedown = @import("shakedown");
const v8_verdicts = @import("v8_verdicts");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const parse = @import("syntax/parse.zig");
const translate = @import("hir/translate.zig");
const Hir = @import("hir/Hir.zig");
const ecma = @import("testing/ecma.zig");
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
    /// Whether a match exists, outside the code unit cases: always V8's.
    is_match_differ: usize = 0,
    /// ECMA-262's semantics as written (testing/ecma.zig) against V8: every case agrees but
    /// the code unit ones, which it reads as code points too.
    oracle_agree: usize = 0,
    oracle_code_units: usize = 0,
    /// Its budget spent: never, at these sizes.
    oracle_budget: usize = 0,
};

fn codeUnits(case: Case) bool {
    if (std.mem.indexOfAny(u8, case.flags, "uv") != null) return false;
    for (case.haystack) |b| if (b >= 0xf0) return true;
    return false;
}

fn spansEql(groups: anytype, want: []const ?[2]usize) bool {
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
    var held: ?struct { case: Case, re: Regex, cache: Regex.Cache, hir: Hir } = null;
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
            const ast = try a.create(@import("syntax/Ast.zig"));
            ast.* = try parse.parse(a, .init(case.pattern), syntaxOf(case.flags), .{}, null);
            const hir = try translate.translate(a, ast, syntaxOf(case.flags), .{}, null);
            held = .{ .case = case, .re = re, .cache = try re.cache(testing.allocator), .hir = hir };
        }
        const re = &held.?.re;
        const cache = &held.?.cache;
        const groups = try a.alloc(?Regex.Span, re.captureCount());
        const found = re.captures(cache, .of(case.haystack), groups);
        const units = codeUnits(case);
        if (ecma.exec(a, &held.?.hir, case.haystack, 1_000_000)) |said| {
            const same = if (said) |g| case.match != null and spansEql(g, case.match.?) else case.match == null;
            if (same) {
                tally.oracle_agree += 1;
            } else if (units) {
                tally.oracle_code_units += 1;
            } else {
                std.debug.print("oracle: /{s}/{s} on {any}: {any}, V8 {any}\n", .{ case.pattern, case.flags, case.haystack, said, case.match });
                return error.TestUnexpectedResult;
            }
        } else |err| switch (err) {
            error.Budget => tally.oracle_budget += 1,
            else => return err,
        }
        if (!units and found != (case.match != null)) tally.is_match_differ += 1;
        const same_span = if (case.match) |w| found and groups[0].?.start == w[0].?[0] and groups[0].?.end == w[0].?[1] else !found;
        if (same_span and (case.match == null or spansEql(groups, case.match.?))) {
            tally.agree += 1;
        } else if (units) {
            tally.differ_code_units += 1;
        } else {
            std.debug.print("/{s}/{s} on {any}: {any}, V8 {any}\n", .{ case.pattern, case.flags, case.haystack, if (found) groups else null, case.match });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqualStrings("v26.10.0", file.node);
    // Counted, so a change in either direction shows. Captures clear per iteration (17 cases
    // came to agree) and an iteration past the minimum that matched empty fails (the rest): the
    // engine now says what the oracle says on every case, and differs from V8 only where V8
    // reads code units.
    try testing.expectEqual(Tally{
        .cases = 9480,
        .agree = 9422,
        .refused_code_unit_split = 55,
        .differ_code_units = 3,
        .is_match_differ = 0,
        .oracle_agree = 9422,
        .oracle_code_units = 3,
        .oracle_budget = 0,
    }, tally);
}

// The ECMAScript dialect against ECMA-262 as written, on any small pattern.

const pieces = [_][]const u8{ "a", "a", "a", "b", "b", "_", " ", "\n", "\u{e9}", "\u{2028}", "\u{1f600}" };

/// A pattern from a small grammar that reaches what the empty check is about: groups, captured
/// or not, that can match empty, nested and quantified, alternatives with an empty branch.
fn write(s: anytype, out: *std.ArrayList(u8), a: std.mem.Allocator, depth: u32) !void {
    const leaves = [_][]const u8{ "a", "b", "", "a?", "b*", "\\b", "^", "$", ".", "[ab]", "\\w" };
    const quantifiers = [_][]const u8{ "", "*", "+", "?", "{0,2}", "{1,3}", "{2}", "*?", "+?", "??", "{0,}" };
    switch (if (depth == 0) 0 else shakedown.gen.intRange(s, usize, 0, 3)) {
        0 => try out.appendSlice(a, leaves[shakedown.gen.intRange(s, usize, 0, leaves.len - 1)]),
        1 => {
            try out.appendSlice(a, if (shakedown.gen.boolean(s)) "(" else "(?:");
            try write(s, out, a, depth - 1);
            try out.appendSlice(a, ")");
            try out.appendSlice(a, quantifiers[shakedown.gen.intRange(s, usize, 0, quantifiers.len - 1)]);
        },
        2 => {
            try write(s, out, a, depth - 1);
            try out.appendSlice(a, "|");
            try write(s, out, a, depth - 1);
        },
        else => {
            try write(s, out, a, depth - 1);
            try write(s, out, a, depth - 1);
        },
    }
}

fn anyOracle(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try write(s, &out, a, 4);
    const pattern = out.items;
    const options = [_][]const u8{ "", "u", "v", "i", "m", "s", "ui", "vi" };
    const flags = options[shakedown.gen.intRange(s, usize, 0, options.len - 1)];
    var haystack: std.ArrayList(u8) = .empty;
    for (0..shakedown.gen.intRange(s, usize, 0, 6)) |_| try haystack.appendSlice(a, pieces[shakedown.gen.intRange(s, usize, 0, pieces.len - 1)]);
    case.note("/{s}/{s} on {any}", .{ pattern, flags, haystack.items });
    var re = Regex.compile(case.gpa, .init(pattern), .{ .syntax = syntaxOf(flags) }) catch |err| switch (err) {
        error.Invalid, error.Unsupported, error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    defer re.deinit();
    var cache = try re.cache(case.gpa);
    defer cache.deinit(case.gpa);
    const ast = try a.create(@import("syntax/Ast.zig"));
    ast.* = try parse.parse(a, .init(pattern), syntaxOf(flags), .{}, null);
    const hir = try translate.translate(a, ast, syntaxOf(flags), .{}, null);
    const said = ecma.exec(a, &hir, haystack.items, 100_000) catch |err| switch (err) {
        error.Budget => return,
        else => return err,
    };
    const groups = try a.alloc(?Regex.Span, re.captureCount());
    const found = re.captures(&cache, .of(haystack.items), groups);
    try testing.expectEqual(said != null, found);
    if (said) |want| for (want, groups) |w, g| {
        try testing.expectEqual(w == null, g == null);
        if (w) |x| try testing.expect(x.start == g.?.start and x.end == g.?.end);
    };
}

test "fuzz: the ECMAScript dialect's match and captures are ECMA-262's" {
    try shakedown.check(testing.allocator, {}, anyOracle, .{ .cases = 5000, .seed = 0xec3a });
}
