//! V8's verdicts on replace and split (testdata/v8/replace.json, written by replace.mjs under
//! Node v26.10.0, a dev-time tool outside the build): ECMAScript patterns, lookaround and empty
//! matches among them, over every GetSubstitution form, a literal replacer, global or once, and
//! split with and without a limit, against what spectra's ECMAScript dialect gives.
const std = @import("std");
const strand = @import("strand");
const v8_replace = @import("v8_replace");
const Regex = @import("Regex.zig");
const Syntax = @import("Syntax.zig");
const testing = std.testing;

const Replace = struct {
    pattern: []const u8,
    flags: []const u8,
    haystack: []const u8,
    template: []const u8,
    literal: bool,
    global: bool,
    out: []const u8,
};

const Split = struct {
    pattern: []const u8,
    flags: []const u8,
    haystack: []const u8,
    limit: ?usize,
    pieces: []const ?[]const u8,
};

const File = struct {
    node: []const u8,
    replaces: []const Replace,
    splits: []const Split,
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

const Held = struct {
    pattern: []const u8,
    flags: []const u8,
    re: Regex,
    cache: Regex.Cache,
    groups: []?Regex.Span,

    fn deinit(h: *Held) void {
        testing.allocator.free(h.groups);
        h.cache.deinit(testing.allocator);
        h.re.deinit();
    }
};

/// The pattern compiled once for each run of cases that share it.
fn hold(held: *?Held, pattern: []const u8, flags: []const u8) !*Held {
    if (held.*) |*h| {
        if (std.mem.eql(u8, h.pattern, pattern) and std.mem.eql(u8, h.flags, flags)) return h;
        h.deinit();
        held.* = null;
    }
    var re = try Regex.compile(testing.allocator, .init(pattern), .{ .syntax = syntaxOf(flags) });
    errdefer re.deinit();
    var cache = try re.cache(testing.allocator);
    errdefer cache.deinit(testing.allocator);
    held.* = .{ .pattern = pattern, .flags = flags, .re = re, .cache = cache, .groups = try testing.allocator.alloc(?Regex.Span, re.captureCount()) };
    return &held.*.?;
}

test "V8's verdicts on replace and split, through the ECMAScript dialect" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const file = try strand.json.parseLeaky(File, a, v8_replace.bytes, .{});
    try testing.expectEqualStrings("v26.10.0", file.node);
    var held: ?Held = null;
    defer if (held) |*h| h.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (file.replaces) |case| {
        const h = try hold(&held, case.pattern, case.flags);
        out.clearRetainingCapacity();
        const with: Regex.Replacement = if (case.literal) .{ .literal = case.template } else .{ .template = case.template };
        _ = try h.re.replace(&h.cache, &out.writer, case.haystack, with, h.groups, if (case.global) null else 1);
        if (!std.mem.eql(u8, case.out, out.written())) {
            std.debug.print("/{s}/{s}{s} on {any} with {s}: {any}, V8 {any}\n", .{ case.pattern, case.flags, if (case.global) "g" else "", case.haystack, case.template, out.written(), case.out });
            return error.TestUnexpectedResult;
        }
    }
    for (file.splits) |case| {
        const h = try hold(&held, case.pattern, case.flags);
        var it = h.re.split(&h.cache, case.haystack, h.groups, case.limit);
        var k: usize = 0;
        while (try it.next()) |piece| : (k += 1) {
            const same = k < case.pieces.len and if (case.pieces[k]) |w| (piece.text != null and std.mem.eql(u8, w, piece.text.?)) else piece.text == null;
            if (!same) {
                std.debug.print("/{s}/{s} split {any} limit {any}: piece {d} {any}, V8 {any}\n", .{ case.pattern, case.flags, case.haystack, case.limit, k, piece.text, case.pieces });
                return error.TestUnexpectedResult;
            }
        }
        if (k != case.pieces.len) {
            std.debug.print("/{s}/{s} split {any} limit {any}: {d} pieces, V8 {any}\n", .{ case.pattern, case.flags, case.haystack, case.limit, k, case.pieces });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(12550, file.replaces.len);
    try testing.expectEqual(7668, file.splits.len);
}
