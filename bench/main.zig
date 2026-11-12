//! spectra's benchmark rows (spectra.md §8), timed: `zig build bench [-- --smoke] [-- --json]
//! [-- <workload>...]`. CI only compiles this file; timings are wall-clock on the machine that runs
//! it, and none are claimed from a development machine.
//!
//! - search: rebar's shapes over a synthetic text (literals, a literal alternation, a Unicode
//!   class, words, dates, emails, a pattern that makes backtrackers exponential), find and
//!   every match;
//! - compile: compile time for literal, Unicode-class-heavy and large alternation patterns;
//! - set: `matches` over sets of 10, 100 and 1000 patterns;
//! - lookaround: zod's patterns, is-match over many values; a lookbehind's find;
//! - replace: replace and split over the text.
const std = @import("std");
const spectra = @import("spectra");
const Regex = spectra.Regex;
const Set = spectra.Set;

const Allocator = std.mem.Allocator;

const Report = struct {
    w: *std.Io.Writer,
    json: bool,
    io: std.Io,

    fn line(r: Report, workload: []const u8, name: []const u8, metric: []const u8, value: f64, unit_name: []const u8) !void {
        if (r.json) {
            try r.w.print("{{\"workload\":\"{s}\",\"name\":\"{f}\",\"metric\":\"{s}\",\"value\":{d:.3},\"unit\":\"{s}\"}}\n", .{ workload, std.zig.fmtString(name), metric, value, unit_name });
        } else {
            try r.w.print("{s:<12} {s:<40} {s:<10} {d:>12.2} {s}\n", .{ workload, name, metric, value, unit_name });
        }
    }

    fn now(r: Report) std.Io.Timestamp {
        return std.Io.Clock.awake.now(r.io);
    }
};

fn nsBetween(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @floatFromInt(start.durationTo(end).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var smoke = false;
    var json = false;
    var selected: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--json")) json = true else if (!std.mem.startsWith(u8, arg, "--")) try selected.append(a, arg) else return error.UnknownArgument;
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const r: Report = .{ .w = &stdout.interface, .json = json, .io = init.io };
    // The rows are the output: whichever of the run and the flush fails is reported, the run's first.
    const ran = workloads(r, gpa, a, selected.items, smoke);
    const flushed = r.w.flush();
    try ran;
    try flushed;
}

fn workloads(r: Report, gpa: Allocator, a: Allocator, selected: []const []const u8, smoke: bool) !void {
    const text = try corpus(a, if (smoke) 4 << 10 else 4 << 20);
    if (wanted(selected, "search")) try search(r, gpa, text);
    if (wanted(selected, "compile")) try compile(r, gpa, if (smoke) 1 else 200);
    if (wanted(selected, "set")) for (if (smoke) &[_]usize{10} else &[_]usize{ 10, 100, 1000 }) |n| try sets(r, gpa, a, text, n);
    if (wanted(selected, "lookaround")) try lookaround(r, gpa, a, text, smoke);
    if (wanted(selected, "replace")) try replace(r, gpa, text);
}

/// Whether `workload` was asked for; no names means all of them.
fn wanted(selected: []const []const u8, workload: []const u8) bool {
    if (selected.len == 0) return true;
    for (selected) |name| if (std.mem.eql(u8, name, workload)) return true;
    return false;
}

/// A synthetic English-like text with dates, emails, numbers and some non-ASCII words, the same
/// for a seed: rebar's corpora are not vendored, so its shapes run over this.
fn corpus(a: Allocator, len: usize) ![]const u8 {
    const words = [_][]const u8{ "the", "of", "and", "Sherlock", "Holmes", "Watson", "said", "street", "in", "a", "was", "Baker", "which", "école", "Ωμέγα", "2026-11-12", "ann@example.com", "42", "Moriarty", "\n" };
    var prng: std.Random.DefaultPrng = .init(0x5bec);
    const random = prng.random();
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len < len) {
        try out.appendSlice(a, words[random.uintLessThan(usize, words.len)]);
        try out.append(a, ' ');
    }
    return out.items;
}

const searches = [_]struct { []const u8, spectra.Syntax }{
    .{ "Sherlock", .{} },
    .{ "Sherlock|Holmes|Watson|Moriarty", .{} },
    .{ "(?i)sherlock holmes", .{} },
    .{ "\\p{Greek}+", .{} },
    .{ "\\w+\\s+Holmes", .{} },
    .{ "\\d{4}-\\d{2}-\\d{2}", .{} },
    .{ "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", .{} },
    .{ "(a|a)*b", .{} },
    .{ "\\b\\w+\\b", .{} },
};

fn search(r: Report, gpa: Allocator, text: []const u8) !void {
    for (searches) |case| {
        var re = try Regex.compile(gpa, .init(case[0]), .{ .syntax = case[1] });
        defer re.deinit();
        var c = try re.cache(gpa);
        defer c.deinit(gpa);
        const t0 = r.now();
        _ = try re.find(&c, .of(text));
        const find_ns = nsBetween(t0, r.now());
        const t1 = r.now();
        const count = try countAll(&re, &c, text);
        const all_ns = nsBetween(t1, r.now());
        const mb = @as(f64, @floatFromInt(text.len)) / (1 << 20);
        try r.line("search", case[0], "find", find_ns, "ns");
        try r.line("search", case[0], "all", all_ns / 1e6 / mb, "ms/MiB");
        try r.line("search", case[0], "matches", @floatFromInt(count), "matches");
    }
}

noinline fn countAll(re: *const Regex, c: *Regex.Cache, text: []const u8) !usize {
    var it = re.findAll(c, text);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

fn compile(r: Report, gpa: Allocator, rounds: usize) !void {
    const patterns = [_]struct { []const u8, []const u8 }{
        .{ "literal", "Sherlock Holmes" },
        .{ "unicode-classes", "[\\p{L}\\p{N}]+\\p{Greek}*\\w+" },
        .{ "alternation", "Sherlock|Holmes|Watson|Moriarty|Baker|street|Lestrade|Hudson|Adler|Mycroft|Gregson|Hopkins" },
        .{ "lookaround", "^(?!\\.)(?!.*\\.\\.)[\\w.+-]*@\\w+\\.[a-z]{2,}$" },
    };
    for (patterns) |p| {
        const syntax: spectra.Syntax = if (std.mem.eql(u8, p[0], "lookaround")) .{ .dialect = .ecmascript } else .{};
        const t0 = r.now();
        for (0..rounds) |_| {
            var re = try Regex.compile(gpa, .init(p[1]), .{ .syntax = syntax });
            re.deinit();
        }
        try r.line("compile", p[0], "compile", nsBetween(t0, r.now()) / @as(f64, @floatFromInt(rounds)), "ns");
    }
}

fn sets(r: Report, gpa: Allocator, a: Allocator, text: []const u8, n: usize) !void {
    const sources = try a.alloc(@import("aegis").input.Untrusted([]const u8), n);
    for (sources, 0..) |*s, i| s.* = .init(try std.fmt.allocPrint(a, "word{d}|Holmes{d}", .{ i, i }));
    var set = try Set.compile(gpa, sources, .{});
    defer set.deinit();
    var c = try set.cache(gpa);
    defer c.deinit(gpa);
    var out = try set.patterns(gpa);
    defer out.deinit(gpa);
    const t0 = r.now();
    _ = try set.matches(&c, .of(text), &out);
    const name = try std.fmt.allocPrint(a, "{d}-patterns", .{n});
    try r.line("set", name, "matches", nsBetween(t0, r.now()) / 1e6, "ms");
}

fn lookaround(r: Report, gpa: Allocator, a: Allocator, text: []const u8, smoke: bool) !void {
    const zod = "^(?!\\.)(?!.*\\.\\.)([A-Za-z0-9_'+\\-\\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\\-]*\\.)+[A-Za-z]{2,}$";
    var re = try Regex.compile(gpa, .init(zod), .{ .syntax = .{ .dialect = .ecmascript } });
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    const values = [_][]const u8{ "ann@example.com", ".ann@example.com", "ann..lee@example.com", "a.b+c@sub.example.org" };
    const rounds: usize = if (smoke) 10 else 100_000;
    var matched: usize = 0;
    const t0 = r.now();
    for (0..rounds) |i| matched += @intFromBool(try re.isMatch(&c, values[i % values.len]));
    try r.line("lookaround", "zod-email", "is-match", nsBetween(t0, r.now()) / @as(f64, @floatFromInt(rounds)), "ns/value");
    try r.line("lookaround", "zod-email", "matched", @floatFromInt(matched), "values");
    var behind = try Regex.compile(gpa, .init("(?<=Baker )street"), .{ .syntax = .{ .dialect = .ecmascript } });
    defer behind.deinit();
    var bc = try behind.cache(gpa);
    defer bc.deinit(gpa);
    const t1 = r.now();
    const count = try countAll(&behind, &bc, text);
    _ = a;
    try r.line("lookaround", "(?<=Baker )street", "all", nsBetween(t1, r.now()) / 1e6, "ms");
    try r.line("lookaround", "(?<=Baker )street", "matches", @floatFromInt(count), "matches");
}

fn replace(r: Report, gpa: Allocator, text: []const u8) !void {
    var re = try Regex.compile(gpa, .init("(\\w+)@(\\w+)\\.com"), .{});
    defer re.deinit();
    var c = try re.cache(gpa);
    defer c.deinit(gpa);
    var groups: [3]?Regex.Span = undefined;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const t0 = r.now();
    const n = try re.replace(&c, &discard.writer, text, .{ .template = "$2 at $1" }, &groups, null);
    try r.line("replace", "(\\w+)@(\\w+)\\.com", "replace", nsBetween(t0, r.now()) / 1e6, "ms");
    try r.line("replace", "(\\w+)@(\\w+)\\.com", "replaced", @floatFromInt(n), "matches");
    var space = try Regex.compile(gpa, .init("\\s+"), .{});
    defer space.deinit();
    var sc = try space.cache(gpa);
    defer sc.deinit(gpa);
    var none: [1]?Regex.Span = undefined;
    const t1 = r.now();
    var it = space.split(&sc, text, &none, null);
    var pieces: usize = 0;
    while (try it.next()) |_| pieces += 1;
    try r.line("replace", "\\s+", "split", nsBetween(t1, r.now()) / 1e6, "ms");
    try r.line("replace", "\\s+", "pieces", @floatFromInt(pieces), "pieces");
}
