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
const grammar = @import("testing/grammar.zig");
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
    /// How each case was answered (`Regex.Cache.Path`); every case is answered again by the
    /// PikeVM alone, and must say the same.
    path_lazy_dfa: usize = 0,
    path_lazy_dfa_fell_back: usize = 0,
    path_reverse_anchored: usize = 0,
    path_literal: usize = 0,
    no_lazy_dfa: usize = 0,
    /// Each case's match found again by `find`, its start each way (`Regex.Cache.Start`), and
    /// the same span as the captures' group 0.
    start_reverse_dfa: usize = 0,
    start_reverse_dfa_fell_back: usize = 0,
    start_pikevm: usize = 0,
    start_prefilter: usize = 0,
    no_reverse_dfa: usize = 0,
    /// Which engine wrote each case's captures (`Regex.Cache.Slots`).
    slots_backtrack: usize = 0,
    slots_backtrack_fell_back: usize = 0,
    slots_pikevm: usize = 0,
    slots_onepass: usize = 0,
};

fn codeUnits(case: Case) bool {
    if (std.mem.indexOfAny(u8, case.flags, "uv") != null) return false;
    for (case.haystack) |b| if (b >= 0xf0) return true;
    return false;
}

fn spansEqlBoth(x: []const ?Regex.Span, y: []const ?Regex.Span) bool {
    for (x, y) |p, q| if (!std.meta.eql(p, q)) return false;
    return true;
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
    var held: ?struct { case: Case, re: Regex, cache: Regex.Cache, alone: Regex, alone_cache: Regex.Cache, hir: Hir } = null;
    defer if (held) |*h| {
        h.cache.deinit(testing.allocator);
        h.re.deinit();
        h.alone_cache.deinit(testing.allocator);
        h.alone.deinit();
    };
    for (file.cases) |case| {
        tally.cases += 1;
        if (held) |*h| if (!std.mem.eql(u8, h.case.pattern, case.pattern) or !std.mem.eql(u8, h.case.flags, case.flags)) {
            h.cache.deinit(testing.allocator);
            h.re.deinit();
            h.alone_cache.deinit(testing.allocator);
            h.alone.deinit();
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
            if (!re.engines().lazy_dfa) tally.no_lazy_dfa += 1;
            if (!re.engines().reverse_dfa) tally.no_reverse_dfa += 1;
            var alone = try Regex.compile(testing.allocator, .init(case.pattern), .{ .syntax = syntaxOf(case.flags), .limits = .{ .lazy_dfa = .fromRaw(0), .backtrack = .fromRaw(0), .onepass = .fromRaw(0) }, .prefilter = false });
            errdefer alone.deinit();
            try testing.expect(!alone.engines().lazy_dfa and !alone.engines().backtrack and !alone.engines().onepass and !alone.engines().prefilter);
            const ast = try a.create(@import("syntax/Ast.zig"));
            ast.* = try parse.parse(a, .init(case.pattern), syntaxOf(case.flags), .{}, null);
            const hir = try translate.translate(a, ast, syntaxOf(case.flags), .{}, null);
            var c = try re.cache(testing.allocator);
            errdefer c.deinit(testing.allocator);
            held = .{ .case = case, .re = re, .cache = c, .alone = alone, .alone_cache = try alone.cache(testing.allocator), .hir = hir };
        }
        const re = &held.?.re;
        const cache = &held.?.cache;
        const groups = try a.alloc(?Regex.Span, re.captureCount());
        const found = re.captures(cache, .of(case.haystack), groups);
        if (found) switch (cache.last_slots) {
            .pikevm => tally.slots_pikevm += 1,
            .backtrack => tally.slots_backtrack += 1,
            .backtrack_fell_back => tally.slots_backtrack_fell_back += 1,
            .onepass => tally.slots_onepass += 1,
        };
        switch (cache.last) {
            .pikevm => {},
            .lazy_dfa => tally.path_lazy_dfa += 1,
            .lazy_dfa_fell_back => tally.path_lazy_dfa_fell_back += 1,
            .reverse_anchored => tally.path_reverse_anchored += 1,
            .literal => tally.path_literal += 1,
        }
        const span = re.find(cache, .of(case.haystack));
        if (found != (span != null) or (found and !std.meta.eql(groups[0].?, span.?))) {
            std.debug.print("/{s}/{s} on {any}: find {any}, captures {any}\n", .{ case.pattern, case.flags, case.haystack, span, groups[0] });
            return error.TestUnexpectedResult;
        }
        if (span != null) switch (cache.last_start) {
            .pikevm => tally.start_pikevm += 1,
            .reverse_dfa => tally.start_reverse_dfa += 1,
            .reverse_dfa_fell_back => tally.start_reverse_dfa_fell_back += 1,
            .prefilter => tally.start_prefilter += 1,
        };
        const alone_groups = try a.alloc(?Regex.Span, re.captureCount());
        if (held.?.alone.captures(&held.?.alone_cache, .of(case.haystack), alone_groups) != found or (found and !std.meta.eql(groups, alone_groups) and !spansEqlBoth(groups, alone_groups))) {
            std.debug.print("/{s}/{s} on {any}: {any}, the PikeVM alone {any}\n", .{ case.pattern, case.flags, case.haystack, groups, alone_groups });
            return error.TestUnexpectedResult;
        }
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
    errdefer std.debug.print("{any}\n", .{tally});
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
        // The lazy DFA answers the rest; it quits on a byte past 0x7f where `\b` or `m`'s lines
        // read code points, and the PikeVM answers those.
        .path_lazy_dfa = 8090,
        .path_lazy_dfa_fell_back = 161,
        .path_reverse_anchored = 116,
        .path_literal = 1058,
        .no_lazy_dfa = 0,
        // `find` says what the captures' group 0 says on every case; the reverse lazy DFA finds
        // each start where the lazy DFA found the end, through ECMAScript's empty checks forward.
        .start_reverse_dfa = 3081,
        .start_reverse_dfa_fell_back = 0,
        .start_pikevm = 40,
        .start_prefilter = 120,
        .no_reverse_dfa = 0,
        // Every case's captures are the one-pass DFA's or the backtracker's, the PikeVM alone
        // saying the same.
        .slots_backtrack = 837,
        .slots_backtrack_fell_back = 0,
        .slots_pikevm = 0,
        .slots_onepass = 2404,
    }, tally);
}

// The ECMAScript dialect against ECMA-262 as written, on any small pattern.

const pieces = [_][]const u8{ "a", "a", "a", "b", "b", "_", " ", "\n", "\u{e9}", "\u{2028}", "\u{1f600}" };

fn anyOracle(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var state: std.heap.ArenaAllocator = .init(case.gpa);
    defer state.deinit();
    const a = state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try grammar.write(s, &out, a, 4);
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
