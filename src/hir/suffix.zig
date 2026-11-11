//! Parts of this file are translated from regex-automata 0.4.18 (the Rust regex project):
//! `strip` and `stripNode` follow meta/reverse_suffix.rs (`strip_literal_suffix`,
//! `strip_literal_suffix_at`, `strip_repetition_literal_suffix`), and the containment and
//! separator checks (`containsAll`, `separated` and the helpers below them) follow
//! meta/prefix.rs. Copyright (c) 2014 The Rust Project Developers, MIT OR Apache-2.0; the MIT
//! text is in LICENSES/regex-MIT.txt. The arguments below, the length arithmetic and the parts
//! representation are spectra's own.
//!
//! Whether a pattern's literal suffix can lead the search: the reverse suffix strategy, which
//! scans for the suffix and reads back from each occurrence, finds the leftmost-first match only
//! where no earlier-starting match can end past the occurrence it stops at. This file proves
//! that from the pattern, conservatively: where a proof fails, the strategy is not taken.
//!
//! The setting. Every match ends with the literal L, and the pattern is Q·L: Q is what is left
//! when L is taken off its end (`strip`), so every match is a match of Q then L. The strategy
//! tries L's occurrences in the order they start; for each it reads back from the occurrence's
//! end e and finds s, the earliest start of a match ending at e, and at the first occurrence
//! that has one it answers the leftmost-first match from s. That is the right one exactly where
//! no match starts before s. A match M' = q'·L starting before s and ending at an earlier or
//! the same occurrence would have been found first (the reverse search from that end sees it),
//! so the only danger is an M' starting before s and ending after e: it starts at or before
//! the occurrence [p, e) and ends past it, so that occurrence lies inside M' before M''s own
//! final L, inside q' or across q' and the final L. Any one of these closes it:
//!
//! - Q has a fixed length (`fixedLength`). Every match is then as long as every other, and M'
//!   cannot both start earlier and end later than the match at s.
//!
//! - Some byte of L can be read by no part of Q (`containsAll` false). If the occurrence lies
//!   inside q', q' holds every byte of L. If it crosses into the final L at p' (p < p' < e), L
//!   overlaps itself at shift d = p' - p, so L[i] = L[i + d] and its first d bytes, which q'
//!   holds, are every byte L has. Either way Q would read every byte of L.
//!
//! - Q's last part that reads anything is a class S, or a repetition of S at least once, that
//!   shares no character with L or with any other part of Q (`separated`). In the match at s,
//!   the character just before p is S's. In M' it lies inside q', and only S reads S's
//!   characters, so S reads it there; S being Q's last reading part, its run goes on unbroken to
//!   p', past p, whose character is L's and so no character of S.
//!
//! - Q's first reading part is such an S. In M', the character at s lies inside q' and is S's
//!   (the match at s begins with S's run), so M''s S run, which begins Q, covers it, and goes on
//!   to the first character that is not S's: where the match at s leaves S too. From there the
//!   two may differ, so the match at s with M''s run in front of it, from M''s start to e, is
//!   also a match. It starts before s and ends at e, against s being the earliest.
//!
//! Characters are code points under Unicode classes and bytes under byte classes; a literal
//! that is not UTF-8 is never shown apart from a Unicode class. A part's reading is
//! over-approximated (a byte past 0x7f may be read by any Unicode class), so a proof never
//! rests on a byte a part might read after all.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Hir = @import("Hir.zig");

/// A part of Q, the pattern with its literal suffix taken off: a node of the pattern, the bytes
/// left of a literal, or a repetition left with fewer times.
pub const Part = union(enum) {
    node: Hir.Index,
    bytes: []const u8,
    repeat: struct { sub: Hir.Index, min: u32, max: ?u32 },
};

/// Whether the reverse suffix strategy on `suffix` finds `hir`'s leftmost-first match: Q is
/// found, and one of the file's proofs holds for it.
pub fn leads(arena: Allocator, hir: *const Hir, suffix: []const u8) Allocator.Error!bool {
    if (suffix.len == 0) return false;
    const q = try strip(arena, hir, suffix) orelse return false;
    if (fixedLength(hir, q)) return true;
    if (!containsAll(hir, q, suffix)) return true;
    return try separated(arena, hir, q, suffix);
}

/// Q: the parts of a concatenation such that `hir` is Q followed by `suffix`, in order; null
/// where the pattern does not end with the suffix as its plain bytes (an alternation, a class,
/// an assertion or an optional repetition in the way).
pub fn strip(arena: Allocator, hir: *const Hir, suffix: []const u8) Allocator.Error!?[]Part {
    var reversed: std.ArrayList(Part) = .empty;
    const left = try stripNode(arena, hir, hir.root, suffix, suffix.len, &reversed) orelse return null;
    if (left != 0) return null;
    std.mem.reverse(Part, reversed.items);
    return reversed.items;
}

/// Takes `suffix[0..cursor]`'s tail off the end of node `index`, appending what is left of it
/// to `out` last part first; returns how much of the suffix is still to take, which is short
/// of `cursor` (the node gave some up) and nonzero only where the node gave up everything.
fn stripNode(arena: Allocator, hir: *const Hir, index: Hir.Index, suffix: []const u8, cursor: usize, out: *std.ArrayList(Part)) Allocator.Error!?usize {
    switch (hir.node(index)) {
        .literal => |bytes| {
            var taken: usize = 0;
            while (taken < bytes.len and taken < cursor and bytes[bytes.len - 1 - taken] == suffix[cursor - 1 - taken]) taken += 1;
            // Either the literal is taken whole, or the suffix is used up inside it.
            if (taken == 0 or (taken < bytes.len and taken < cursor)) return null;
            if (taken < bytes.len) try out.append(arena, .{ .bytes = bytes[0 .. bytes.len - taken] });
            return cursor - taken;
        },
        .capture => |c| return stripNode(arena, hir, c.sub, suffix, cursor, out),
        .concat => |slice| {
            const kids = hir.childrenOf(slice);
            var left = cursor;
            var i = kids.len;
            while (i > 0) {
                i -= 1;
                const after = try stripNode(arena, hir, kids[i], suffix, left, out) orelse return null;
                // A part that gave up nothing (an assertion, an empty string) breaks adjacency.
                if (after == left) return null;
                left = after;
                if (left == 0) {
                    var k = i;
                    while (k > 0) {
                        k -= 1;
                        try out.append(arena, .{ .node = kids[k] });
                    }
                    return 0;
                }
            }
            return left;
        },
        .repetition => |r| {
            var min = r.min;
            var max = r.max;
            var left = cursor;
            while (left > 0) {
                // A time that may not be there cannot be counted on to end with the suffix.
                if (min == 0) return null;
                const after = try stripNode(arena, hir, r.sub, suffix, left, out) orelse return null;
                if (after == left) return null;
                min -= 1;
                if (max) |m| max = m - 1;
                left = after;
            }
            if (max == null or max.? > 0) try out.append(arena, .{ .repeat = .{ .sub = r.sub, .min = min, .max = max } });
            return 0;
        },
        else => return null,
    }
}

const Len = struct { min: usize, max: ?usize };

fn nodeLen(hir: *const Hir, index: Hir.Index) Len {
    return switch (hir.node(index)) {
        .empty, .look, .lookahead => .{ .min = 0, .max = 0 },
        .literal => |bytes| .{ .min = bytes.len, .max = bytes.len },
        .byte_class => .{ .min = 1, .max = 1 },
        .unicode_class => |ranges| if (ranges.len == 0) .{ .min = 1, .max = 1 } else .{ .min = utf8Len(ranges[0][0]), .max = utf8Len(ranges[ranges.len - 1][1]) },
        .capture => |c| nodeLen(hir, c.sub),
        .repetition => |r| repeatLen(nodeLen(hir, r.sub), r.min, r.max),
        .concat => |slice| blk: {
            var total: Len = .{ .min = 0, .max = 0 };
            for (hir.childrenOf(slice)) |kid| total = add(total, nodeLen(hir, kid));
            break :blk total;
        },
        .alternation => |slice| blk: {
            const kids = hir.childrenOf(slice);
            if (kids.len == 0) break :blk .{ .min = 0, .max = 0 };
            var out = nodeLen(hir, kids[0]);
            for (kids[1..]) |kid| {
                const l = nodeLen(hir, kid);
                out.min = @min(out.min, l.min);
                out.max = if (out.max != null and l.max != null) @max(out.max.?, l.max.?) else null;
            }
            break :blk out;
        },
    };
}

fn utf8Len(cp: u21) usize {
    return if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
}

fn add(a: Len, b: Len) Len {
    return .{ .min = a.min +| b.min, .max = if (a.max != null and b.max != null) a.max.? +| b.max.? else null };
}

fn repeatLen(sub: Len, min: u32, max: ?u32) Len {
    return .{
        .min = sub.min *| min,
        .max = if (max) |m| (if (sub.max) |s| s *| m else null) else if (sub.max == 0) 0 else null,
    };
}

fn partLen(hir: *const Hir, part: Part) Len {
    return switch (part) {
        .node => |n| nodeLen(hir, n),
        .bytes => |b| .{ .min = b.len, .max = b.len },
        .repeat => |r| repeatLen(nodeLen(hir, r.sub), r.min, r.max),
    };
}

/// Whether every match of Q has one length.
pub fn fixedLength(hir: *const Hir, q: []const Part) bool {
    var total: Len = .{ .min = 0, .max = 0 };
    for (q) |part| total = add(total, partLen(hir, part));
    return total.max != null and total.max.? == total.min;
}

/// Whether some part of Q may read each byte of `lit`: false proves no match of Q holds them all.
pub fn containsAll(hir: *const Hir, q: []const Part, lit: []const u8) bool {
    for (lit) |b| {
        var read = false;
        for (q) |part| read = read or partReads(hir, part, b);
        if (!read) return false;
    }
    return true;
}

fn partReads(hir: *const Hir, part: Part, b: u8) bool {
    return switch (part) {
        .node => |n| nodeReads(hir, n, b),
        .bytes => |bytes| std.mem.indexOfScalar(u8, bytes, b) != null,
        .repeat => |r| nodeReads(hir, r.sub, b),
    };
}

/// Whether node `index` may read byte `b`: over-approximated, a byte past 0x7f by any Unicode
/// class.
fn nodeReads(hir: *const Hir, index: Hir.Index, b: u8) bool {
    return switch (hir.node(index)) {
        .empty, .look => false,
        .lookahead => true,
        .literal => |bytes| std.mem.indexOfScalar(u8, bytes, b) != null,
        .byte_class => |ranges| inRanges(u8, ranges, b),
        .unicode_class => |ranges| b >= 0x80 or inRanges(u21, ranges, b),
        .capture => |c| nodeReads(hir, c.sub, b),
        .repetition => |r| nodeReads(hir, r.sub, b),
        .concat, .alternation => |slice| for (hir.childrenOf(slice)) |kid| {
            if (nodeReads(hir, kid, b)) break true;
        } else false,
    };
}

fn inRanges(comptime T: type, ranges: []const [2]T, v: T) bool {
    for (ranges) |r| if (r[0] <= v and v <= r[1]) return true;
    return false;
}

/// A class of either kind, as the separator proofs compare them.
const Class = union(enum) { unicode: []const [2]u21, bytes: []const [2]u8 };

/// Whether Q's first or last reading part is a class every other part and `lit` share nothing
/// with, read at least once.
pub fn separated(arena: Allocator, hir: *const Hir, q: []const Part, lit: []const u8) Allocator.Error!bool {
    // Q's parts, a concatenation inside them laid out flat.
    var parts: std.ArrayList(Part) = .empty;
    for (q) |part| switch (part) {
        .node => |n| switch (hir.node(n)) {
            .concat => |slice| for (hir.childrenOf(slice)) |kid| try parts.append(arena, .{ .node = kid }),
            else => try parts.append(arena, part),
        },
        else => try parts.append(arena, part),
    };
    const ps = parts.items;
    if (ps.len < 2) return false;
    var first: ?usize = null;
    var last: usize = 0;
    for (ps, 0..) |part, i| if (partLen(hir, part).max != 0) {
        if (first == null) first = i;
        last = i;
    };
    const f = first orelse return false;
    return separatorAt(hir, ps, last, lit) or (f != last and separatorAt(hir, ps, f, lit));
}

fn separatorAt(hir: *const Hir, parts: []const Part, at: usize, lit: []const u8) bool {
    const class = requiredClass(hir, parts[at]) orelse return false;
    if (!classApartFromLiteral(class, lit)) return false;
    for (parts, 0..) |part, i| {
        if (i == at) continue;
        const apart = switch (part) {
            .node => |n| nodeApart(hir, n, class),
            .bytes => |bytes| classApartFromLiteral(class, bytes),
            .repeat => |r| nodeApart(hir, r.sub, class),
        };
        if (!apart) return false;
    }
    return true;
}

/// The class a part reads at least once and nothing else: a class, or a repetition of one with
/// a minimum.
fn requiredClass(hir: *const Hir, part: Part) ?Class {
    return switch (part) {
        .bytes => null,
        .repeat => |r| if (r.min > 0) classOf(hir, r.sub) else null,
        .node => |n| switch (hir.node(uncapture(hir, n))) {
            .repetition => |r| if (r.min > 0) classOf(hir, r.sub) else null,
            else => classOf(hir, n),
        },
    };
}

fn uncapture(hir: *const Hir, index: Hir.Index) Hir.Index {
    var at = index;
    while (true) switch (hir.node(at)) {
        .capture => |c| at = c.sub,
        else => return at,
    };
}

fn classOf(hir: *const Hir, index: Hir.Index) ?Class {
    return switch (hir.node(uncapture(hir, index))) {
        .unicode_class => |r| .{ .unicode = r },
        .byte_class => |r| .{ .bytes = r },
        else => null,
    };
}

/// Whether node `index` reads no character of `class`.
fn nodeApart(hir: *const Hir, index: Hir.Index, class: Class) bool {
    return switch (hir.node(index)) {
        .empty, .look => true,
        .lookahead => false,
        .literal => |bytes| classApartFromLiteral(class, bytes),
        .unicode_class => |r| classesApart(class, .{ .unicode = r }),
        .byte_class => |r| classesApart(class, .{ .bytes = r }),
        .capture => |c| nodeApart(hir, c.sub, class),
        .repetition => |r| nodeApart(hir, r.sub, class),
        .concat, .alternation => |slice| for (hir.childrenOf(slice)) |kid| {
            if (!nodeApart(hir, kid, class)) break false;
        } else true,
    };
}

/// Two classes of one kind with no character in common; classes of different kinds are never
/// shown apart.
fn classesApart(a: Class, b: Class) bool {
    return switch (a) {
        .unicode => |x| switch (b) {
            .unicode => |y| rangesApart(u21, x, y),
            .bytes => false,
        },
        .bytes => |x| switch (b) {
            .bytes => |y| rangesApart(u8, x, y),
            .unicode => false,
        },
    };
}

fn rangesApart(comptime T: type, a: []const [2]T, b: []const [2]T) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i][1] < b[j][0]) {
            i += 1;
        } else if (b[j][1] < a[i][0]) {
            j += 1;
        } else return false;
    }
    return true;
}

/// Whether no character of `lit` is in `class`: its bytes under a byte class, its code points
/// under a Unicode class (a literal that is not UTF-8 is not shown apart).
fn classApartFromLiteral(class: Class, lit: []const u8) bool {
    switch (class) {
        .bytes => |r| {
            for (lit) |b| if (inRanges(u8, r, b)) return false;
            return true;
        },
        .unicode => |r| {
            var it = (std.unicode.Utf8View.init(lit) catch return false).iterator();
            while (it.nextCodepoint()) |cp| if (inRanges(u21, r, cp)) return false;
            return true;
        },
    }
}
