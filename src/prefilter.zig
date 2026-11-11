//! Prefilters: a fast scan for where a match may start, from the literals every match starts
//! with (hir/literals.zig), so the lazy DFA skips what cannot start one. regex-automata's:
//! memchr for the one to three bytes every literal starts with, and for a single literal a
//! search on its two rarest bytes (by `rank`) confirmed by the whole literal, both sixteen bytes
//! a step in vectors that every target's baseline has (SSE2, NEON, or Zig's lowering elsewhere),
//! with no run-time check; and for more literals Aho-Corasick, a DFA over the literals' byte
//! classes whose every state knows the longest literal ending there.
//!
//! Aho-Corasick finds literals by where they end, and the prefilter wants the leftmost start:
//! it keeps the earliest start seen and reads on until no literal starting before it could
//! still end, at most the longest literal's length past it.
//!
//! A prefilter is chosen only where it can say no: every literal nonempty, so a match can only
//! start where a literal does. A byte too common to skip much (`common`) is no prefilter.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const literals = @import("hir/literals.zig");
const rank = @import("prefilter/rank.zig").rank;

const width = 16;
const Chunk = @Vector(width, u8);

/// A byte ranked this common or more is not worth a memchr alone: most text is full of it.
const common = 245;

/// The longest literal a pair prefilter keeps to confirm.
pub const max_literal = 100;

pub const Prefilter = union(enum) {
    /// Every literal starts with one of these bytes.
    bytes: struct { set: [3]u8, len: u8 },
    /// One literal: its two rarest bytes at their offsets, then the whole literal confirmed.
    pair: Pair,
    /// Any number of literals, each found whole.
    aho: Aho,

    pub fn deinit(p: *Prefilter, gpa: Allocator) void {
        switch (p.*) {
            .aho => |*a| a.deinit(gpa),
            else => {},
        }
        p.* = undefined;
    }

    /// The bytes it holds beyond itself.
    pub fn memory(p: *const Prefilter) usize {
        return switch (p.*) {
            .aho => |a| a.next.len * @sizeOf(u32) + a.longest.len,
            else => 0,
        };
    }

    /// The first position in `haystack[start..end]` where a match may start, or null where none
    /// can: a literal starts there, and for `pair` it is there whole, within `end`.
    pub fn find(p: *const Prefilter, haystack: []const u8, start: usize, end: usize) ?usize {
        aegis.assert.invariant(start <= end and end <= haystack.len, "a span lies in its haystack");
        return switch (p.*) {
            .bytes => |b| findBytes(haystack[0..end], start, b.set[0..b.len]),
            .pair => |*pair| pair.find(haystack[0..end], start),
            .aho => |*a| a.find(haystack[0..end], start),
        };
    }

    /// The length of the match at a position `find` gave, where the prefilter knows it whole.
    pub fn exactLen(p: *const Prefilter) ?usize {
        return switch (p.*) {
            .bytes => 1,
            .pair => |pair| pair.len,
            .aho => null,
        };
    }
};

pub const Aho = struct {
    classes: [256]u8,
    stride: u32,
    /// Each state's next state by class, failures resolved: a DFA.
    next: []u32,
    /// The longest literal ending at each state, zero for none.
    longest: []u8,
    /// The longest literal.
    max_len: u8,

    fn deinit(a: *Aho, gpa: Allocator) void {
        gpa.free(a.next);
        gpa.free(a.longest);
    }

    fn find(a: *const Aho, haystack: []const u8, start: usize) ?usize {
        var state: u32 = 0;
        var best: ?usize = null;
        var at = start;
        while (at < haystack.len) : (at += 1) {
            state = a.next[@as(usize, state) * a.stride + a.classes[haystack[at]]];
            const len = a.longest[state];
            if (len != 0) {
                const s = at + 1 - len;
                if (best == null or s < best.?) best = s;
            }
            // A literal starting before `best` ends before here.
            if (best) |b| if (at + 1 >= b + a.max_len) return b;
        }
        return best;
    }

    /// The automaton of `lits`, or null where its table passes `limit` bytes.
    fn build(gpa: Allocator, lits: []const literals.Literal, limit: usize) Allocator.Error!?Aho {
        var a: Aho = .{ .classes = undefined, .stride = 0, .next = &.{}, .longest = &.{}, .max_len = 0 };
        var bounds: std.StaticBitSet(257) = .empty;
        for (lits) |lit| for (lit.bytes) |b| {
            bounds.set(b);
            bounds.set(@as(usize, b) + 1);
        };
        var class: u32 = 0;
        for (0..256) |b| {
            if (b > 0 and bounds.isSet(b)) class += 1;
            a.classes[b] = @intCast(class);
        }
        a.stride = class + 1;
        var nodes: usize = 1;
        for (lits) |lit| nodes += @min(lit.bytes.len, max_literal);
        if (nodes * (a.stride * @sizeOf(u32) + 1) > limit) return null;
        const none = std.math.maxInt(u32);
        var next: std.ArrayList(u32) = .empty;
        errdefer next.deinit(gpa);
        var longest: std.ArrayList(u8) = .empty;
        errdefer longest.deinit(gpa);
        try next.appendNTimes(gpa, none, a.stride);
        try longest.append(gpa, 0);
        // The trie.
        for (lits) |lit| {
            const bytes_ = lit.bytes[0..@min(lit.bytes.len, max_literal)];
            var state: u32 = 0;
            for (bytes_) |b| {
                const slot = @as(usize, state) * a.stride + a.classes[b];
                if (next.items[slot] == none) {
                    next.items[slot] = @intCast(longest.items.len);
                    try next.appendNTimes(gpa, none, a.stride);
                    try longest.append(gpa, 0);
                }
                state = next.items[slot];
            }
            longest.items[state] = @max(longest.items[state], @as(u8, @intCast(bytes_.len)));
            a.max_len = @max(a.max_len, @as(u8, @intCast(bytes_.len)));
        }
        // Failures, breadth first, folded into the table: a missing transition goes where the
        // longest proper suffix's would, and a state's longest literal is its own or its
        // failure's.
        const states = longest.items.len;
        const fail = try gpa.alloc(u32, states);
        defer gpa.free(fail);
        const queue = try gpa.alloc(u32, states);
        defer gpa.free(queue);
        var head: usize = 0;
        var tail: usize = 0;
        for (0..a.stride) |c| {
            const t = next.items[c];
            if (t == none) {
                next.items[c] = 0;
            } else {
                fail[t] = 0;
                queue[tail] = t;
                tail += 1;
            }
        }
        while (head < tail) : (head += 1) {
            const s = queue[head];
            longest.items[s] = @max(longest.items[s], longest.items[fail[s]]);
            for (0..a.stride) |c| {
                const slot = @as(usize, s) * a.stride + c;
                const t = next.items[slot];
                const via_fail = next.items[@as(usize, fail[s]) * a.stride + c];
                if (t == none) {
                    next.items[slot] = via_fail;
                } else {
                    fail[t] = via_fail;
                    queue[tail] = t;
                    tail += 1;
                }
            }
        }
        a.next = try next.toOwnedSlice(gpa);
        errdefer gpa.free(a.next);
        a.longest = try longest.toOwnedSlice(gpa);
        return a;
    }
};

pub const Pair = struct {
    literal: [max_literal]u8,
    len: u8,
    /// The offsets of its rarest byte and its second rarest, apart.
    first: u8,
    second: u8,

    fn find(p: *const Pair, haystack: []const u8, start: usize) ?usize {
        const lit = p.literal[0..p.len];
        if (haystack.len < lit.len or start > haystack.len - lit.len) return null;
        const last = haystack.len - lit.len;
        const b1: Chunk = @splat(lit[p.first]);
        const b2: Chunk = @splat(lit[p.second]);
        const reach = @max(p.first, p.second);
        var at = start;
        while (at + reach + width <= haystack.len and at + width - 1 <= last) : (at += width) {
            const v1: Chunk = haystack[at + p.first ..][0..width].*;
            const v2: Chunk = haystack[at + p.second ..][0..width].*;
            var mask: u16 = @bitCast((v1 == b1) & (v2 == b2));
            while (mask != 0) : (mask &= mask - 1) {
                const k = at + @ctz(mask);
                if (std.mem.eql(u8, haystack[k..][0..lit.len], lit)) return k;
            }
        }
        while (at <= last) : (at += 1) {
            if (haystack[at + p.first] == lit[p.first] and haystack[at + p.second] == lit[p.second] and
                std.mem.eql(u8, haystack[at..][0..lit.len], lit)) return at;
        }
        return null;
    }
};

fn findBytes(haystack: []const u8, start: usize, set: []const u8) ?usize {
    var at = start;
    while (at + width <= haystack.len) : (at += width) {
        const v: Chunk = haystack[at..][0..width].*;
        var hit: @Vector(width, bool) = @splat(false);
        for (set) |b| hit = hit | (v == @as(Chunk, @splat(b)));
        const mask: u16 = @bitCast(hit);
        if (mask != 0) return at + @ctz(mask);
    }
    while (at < haystack.len) : (at += 1) {
        if (std.mem.indexOfScalar(u8, set, haystack[at]) != null) return at;
    }
    return null;
}

/// The prefilter for a pattern whose matches start with `prefixes`, or null where none helps;
/// an Aho-Corasick table is at most `limit` bytes.
pub fn choose(gpa: Allocator, prefixes: *const literals.Seq, limit: usize) Allocator.Error!?Prefilter {
    const lits = prefixes.literals() orelse return null;
    if (lits.len == 0) return null;
    for (lits) |lit| if (lit.bytes.len == 0) return null;
    if (lits.len == 1 and lits[0].bytes.len >= 2) return pairOf(lits[0].bytes);
    var set: [3]u8 = undefined;
    var len: u8 = 0;
    for (lits) |lit| {
        const b = lit.bytes[0];
        if (std.mem.indexOfScalar(u8, set[0..len], b) != null) continue;
        if (len == 3) {
            const a = try Aho.build(gpa, lits, limit) orelse return null;
            return .{ .aho = a };
        }
        set[len] = b;
        len += 1;
    }
    var rare = false;
    for (set[0..len]) |b| rare = rare or rank[b] < common;
    if (!rare) return null;
    return .{ .bytes = .{ .set = set, .len = len } };
}

fn pairOf(bytes: []const u8) Prefilter {
    const lit = bytes[0..@min(bytes.len, max_literal)];
    var first: usize = 0;
    for (lit, 0..) |b, k| if (rank[b] < rank[lit[first]]) {
        first = k;
    };
    var second: usize = if (first == 0) 1 else 0;
    for (lit, 0..) |b, k| if (k != first and rank[b] < rank[lit[second]]) {
        second = k;
    };
    var p: Pair = .{ .literal = undefined, .len = @intCast(lit.len), .first = @intCast(first), .second = @intCast(second) };
    @memcpy(p.literal[0..lit.len], lit);
    return .{ .pair = p };
}
