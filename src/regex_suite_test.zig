//! regex's own test suite (regex 1.13.1's testdata/*.toml, vendored in testdata/regex), read
//! through strand's TOML and run as regex runs it on its own engine: each test as is-match,
//! every match in turn, and every match's captures. What spectra does not offer is passed over
//! and counted by reason: more than one pattern (sets come later), the overlapping and earliest
//! searches, leftmost-longest matching, and a line terminator other than `\n`.
//!
//! regex bounds a repetition only by the automaton's size, so the suite compiles with
//! `Limits.repetition` at its largest. Every test run must agree, on every engine path: each is
//! run with the lazy DFA and again without it (`Limits.lazy_dfa` of nothing), and which path
//! answered each search is counted.
const std = @import("std");
const strand = @import("strand");
const regex_suite = @import("regex_suite");
const nfa_dump = @import("testing/nfa_dump.zig");
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

const Tally = struct {
    run: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped_sets: usize = 0,
    skipped_search_kind: usize = 0,
    skipped_match_kind: usize = 0,
    skipped_line_terminator: usize = 0,
    /// Every compiled pattern's automaton, written out (testing/nfa_dump.zig) and hashed in
    /// order with its pattern: the Rust dialect's automata, pinned, so a change made for another
    /// dialect that moves one byte of them shows.
    automata: u64 = 0,
    /// Patterns with no lazy DFA at the default `Limits.lazy_dfa`.
    no_lazy_dfa: usize = 0,
    /// Searches answered on each path (`Regex.Cache.Path`).
    path_pikevm: usize = 0,
    path_lazy_dfa: usize = 0,
    path_lazy_dfa_fell_back: usize = 0,
    path_reverse_anchored: usize = 0,
    path_literal: usize = 0,
    path_reverse_suffix: usize = 0,
    path_reverse_inner: usize = 0,
    path_whole: usize = 0,
    /// Searches where the lazy DFA's prefilter skipped ahead.
    prefiltered: usize = 0,
    /// Patterns with a lazy DFA but no reverse one.
    no_reverse_dfa: usize = 0,
    /// Matches found whose start each way found (`Regex.Cache.Start`).
    start_pikevm: usize = 0,
    start_reverse_dfa: usize = 0,
    start_reverse_dfa_fell_back: usize = 0,
    start_prefilter: usize = 0,
    /// Captures found, by the engine that wrote them (`Regex.Cache.Slots`).
    slots_pikevm: usize = 0,
    slots_backtrack: usize = 0,
    slots_backtrack_fell_back: usize = 0,
    slots_onepass: usize = 0,

    fn countStart(tally: *Tally, start: Regex.Cache.Start) void {
        switch (start) {
            .pikevm => tally.start_pikevm += 1,
            .reverse_dfa => tally.start_reverse_dfa += 1,
            .reverse_dfa_fell_back => tally.start_reverse_dfa_fell_back += 1,
            .prefilter => tally.start_prefilter += 1,
        }
    }

    fn count(tally: *Tally, path: Regex.Cache.Path) void {
        switch (path) {
            .pikevm => tally.path_pikevm += 1,
            .lazy_dfa => tally.path_lazy_dfa += 1,
            .lazy_dfa_fell_back => tally.path_lazy_dfa_fell_back += 1,
            .reverse_anchored => tally.path_reverse_anchored += 1,
            .literal => tally.path_literal += 1,
            .reverse_suffix => tally.path_reverse_suffix += 1,
            .reverse_inner => tally.path_reverse_inner += 1,
            .whole => tally.path_whole += 1,
        }
    }
};

/// The engines a run asks for: the default ones, or the PikeVM alone.
const Engines = enum { default, pikevm };

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
    for ([_]Engines{ .default, .pikevm }) |engines| {
        if (!try runWith(a, file, name, t, pattern, engines, tally)) return;
    }
    tally.passed += 1;
}

/// Runs a test on one engine path: whether it agreed, the failure counted where not. A pattern
/// the test expects refused is counted passed and not run again.
fn runWith(a: std.mem.Allocator, file: []const u8, name: []const u8, t: Value, pattern: []const u8, engines: Engines, tally: *Tally) !bool {
    var haystack = text(t, "haystack").?;
    if (flag(t, "unescape", false)) haystack = try unescape(a, haystack);
    const syntax: Syntax = .{
        .unicode = flag(t, "unicode", true),
        .utf8 = flag(t, "utf8", true),
        .case_insensitive = flag(t, "case-insensitive", false),
    };
    var d: Regex.Diagnostic = .{};
    var limits: @import("Limits.zig") = .{ .repetition = .literal(100_000) };
    if (engines == .pikevm) {
        limits.lazy_dfa = .fromRaw(0);
        limits.backtrack = .fromRaw(0);
        limits.onepass = .fromRaw(0);
    }
    var re = Regex.compile(testing.allocator, .init(pattern), .{ .syntax = syntax, .limits = limits, .diagnostic = &d, .prefilter = engines != .pikevm }) catch |err| {
        if (flag(t, "compiles", true)) {
            std.debug.print("{s}/{s}: /{s}/ refused: {t} {t}\n", .{ file, name, pattern, err, d.reason });
            tally.failed += 1;
        } else tally.passed += 1;
        return false;
    };
    defer re.deinit();
    if (engines == .default) {
        tally.automata = std.hash.Wyhash.hash(tally.automata, pattern);
        tally.automata = std.hash.Wyhash.hash(tally.automata, try nfa_dump.dump(a, &re.nfa));
        if (!re.engines().lazy_dfa) tally.no_lazy_dfa += 1;
        if (re.engines().lazy_dfa and !re.engines().reverse_dfa) tally.no_reverse_dfa += 1;
    } else if (re.engines().lazy_dfa or re.engines().reverse_dfa or re.engines().backtrack or re.engines().onepass or re.engines().prefilter) {
        std.debug.print("{s}/{s}: /{s}/ has a lazy DFA in no store\n", .{ file, name, pattern });
        tally.failed += 1;
        return false;
    }
    if (!flag(t, "compiles", true)) {
        std.debug.print("{s}/{s}: /{s}/ compiled, regex refuses it\n", .{ file, name, pattern });
        tally.failed += 1;
        return false;
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
        const got = (try re.isMatch(&cache, haystack));
        tally.count(cache.last);
        if (got != (want.matches.len > 0)) {
            std.debug.print("{s}/{s}: /{s}/ {t}: is-match {}\n", .{ file, name, pattern, engines, want.matches.len == 0 });
            tally.failed += 1;
            return false;
        }
    }
    // Every match, then every match's groups.
    var it = re.findAllIn(&cache, input);
    var k: usize = 0;
    while (k < limit) : (k += 1) {
        const found = (try it.next());
        tally.count(cache.last);
        if (cache.lazy) |l| if (l.candidates > 0) {
            tally.prefiltered += 1;
        };
        const m = found orelse break;
        tally.countStart(cache.last_start);
        if (k >= want.matches.len or !std.meta.eql(want.matches[k][0], @as(?Span, m))) {
            std.debug.print("{s}/{s}: /{s}/ {t}: find {d}: {any}, want {any}\n", .{ file, name, pattern, engines, k, m, if (k < want.matches.len) want.matches[k][0] else null });
            tally.failed += 1;
            return false;
        }
    }
    if (k != @min(limit, want.matches.len)) {
        std.debug.print("{s}/{s}: /{s}/ {t}: find: {d} matches, want {d}\n", .{ file, name, pattern, engines, k, want.matches.len });
        tally.failed += 1;
        return false;
    }
    const groups = try a.alloc(?Span, re.captureCount());
    var caps = re.findAllIn(&cache, input);
    k = 0;
    while (k < limit and (try caps.nextCaptures(groups))) : (k += 1) {
        tally.count(cache.last);
        switch (cache.last_slots) {
            .pikevm => tally.slots_pikevm += 1,
            .backtrack => tally.slots_backtrack += 1,
            .backtrack_fell_back => tally.slots_backtrack_fell_back += 1,
            .onepass => tally.slots_onepass += 1,
        }
        const w = want.matches[k];
        const compared = if (want.groups_given) groups else groups[0..1];
        if (w.len != compared.len or !std.meta.eql(w, compared) and !spansEql(w, compared)) {
            std.debug.print("{s}/{s}: /{s}/ {t}: captures {d}: {any}, want {any}\n", .{ file, name, pattern, engines, k, compared, w });
            tally.failed += 1;
            return false;
        }
    }
    return true;
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
    errdefer std.debug.print("{any}\n", .{tally});
    try testing.expectEqual(@as(usize, 0), tally.failed);
    // Counted, so a test quietly passed over shows: every one run agrees.
    try testing.expectEqual(Tally{
        .run = 1076,
        .passed = 1076,
        .skipped_sets = 53,
        .skipped_search_kind = 50,
        .skipped_match_kind = 4,
        .skipped_line_terminator = 11,
        .automata = 3201477359050160620,
        // Each search on both paths: the PikeVM alone, and the lazy DFA, which quits on a byte
        // past 0x7f where a Unicode `\b` reads code points, the PikeVM answering those.
        .no_lazy_dfa = 0,
        .path_pikevm = 4531,
        .path_lazy_dfa = 4148,
        .path_lazy_dfa_fell_back = 145,
        // A pattern whose every match ends at the end is read back from there alone; a literal,
        // by the prefilter alone; elsewhere the prefilter skips ahead for the lazy DFA.
        .path_reverse_anchored = 85,
        .path_literal = 110,
        .path_reverse_suffix = 16,
        .path_reverse_inner = 27,
        .prefiltered = 112,
        // Each match's start: the reverse lazy DFA's where the lazy DFA found its end, else the
        // PikeVM's (the PikeVM's own run, and the searches the lazy DFA quit).
        .no_reverse_dfa = 0,
        .start_pikevm = 1567,
        .start_reverse_dfa = 1448,
        .start_reverse_dfa_fell_back = 0,
        .start_prefilter = 41,
        // Captures: the backtracker's on the default path, the PikeVM's on its own.
        .slots_pikevm = 1528,
        .slots_backtrack = 609,
        .slots_backtrack_fell_back = 0,
        .slots_onepass = 919,
    }, tally);
}
