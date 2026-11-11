//! Writes src/prefilter/rank.zig: each byte's rank by how often it occurs in a corpus of code
//! and English, 0 the rarest. The prefilters search for a literal's rarest bytes.
//!
//! Usage: zig run tools/byte_rank.zig -- <file or directory>... > src/prefilter/rank.zig
//! The table committed was made from Zig 0.17.0's `lib/std` (its .zig files) and its
//! `doc/langref.html`, weighted equally: code and prose.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var totals: [256]f64 = @splat(0);
    while (args.next()) |path| {
        var counts: [256]u64 = @splat(0);
        try countPath(gpa, io, path, &counts);
        var sum: u64 = 0;
        for (counts) |c| sum += c;
        // Each argument weighs the same, whatever its size.
        for (counts, 0..) |c, b| totals[b] += @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(@max(sum, 1)));
    }
    var order: [256]u8 = undefined;
    for (&order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u8, &order, &totals, struct {
        fn less(t: *const [256]f64, a: u8, b: u8) bool {
            return t[a] < t[b] or (t[a] == t[b] and a < b);
        }
    }.less);
    var rank: [256]u8 = undefined;
    for (order, 0..) |b, r| rank[b] = @intCast(r);
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    try w.writeAll(
        \\//! Each byte's rank by how often it occurs, 0 the rarest: measured by tools/byte_rank.zig
        \\//! over Zig 0.17.0's standard library sources and its language reference, code and prose
        \\//! weighted equally. The prefilters search for a literal's rarest bytes.
        \\
        \\pub const rank = [256]u8{
        \\
    );
    for (0..16) |row| {
        try w.writeAll("   ");
        for (0..16) |col| try w.print(" {d},", .{rank[row * 16 + col]});
        try w.writeAll("\n");
    }
    try w.writeAll("};\n");
    try w.flush();
}

fn countPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8, counts: *[256]u64) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    if (stat.kind != .directory) return countFile(gpa, io, cwd, path, counts);
    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try countFile(gpa, io, dir, entry.path, counts);
    }
}

fn countFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, counts: *[256]u64) !void {
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    for (bytes) |b| counts[b] += 1;
}
