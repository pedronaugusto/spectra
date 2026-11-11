//! Teddy, Hyperscan's SIMD search for a few dozen literals, as the aho-corasick crate has it:
//! the literals split into eight buckets, and for each of their first `n` bytes (one to three)
//! two tables say which buckets have a literal whose byte there has a given low nibble, or high
//! nibble. A byte shuffle looks each haystack byte's nibbles up in them, and where every one of
//! the first `n` bytes agrees on a bucket, that bucket's literals are checked whole.
//!
//! The scan is generic over the vector width and the shuffle, and `inline`, so it is compiled
//! in each kernel module that instantiates it, with that module's instructions: one file per
//! instruction set holds the shuffle, the only instruction it needs that the baseline may lack.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_literals = 64;
const buckets = 8;

pub const Teddy = struct {
    /// How many of each literal's first bytes are looked up: the shortest literal's length, at
    /// most three.
    n: u8,
    lo: [3][16]u8,
    hi: [3][16]u8,
    /// The literals' bytes, back to back.
    bytes: []u8,
    /// Each literal's start in `bytes` and length, bucket by bucket.
    literals: []Literal,
    /// Each bucket's literals: `literals[first[b]..first[b + 1]]`.
    first: [buckets + 1]u32,

    pub const Literal = struct { start: u32, len: u32 };

    pub fn deinit(t: *Teddy, gpa: Allocator) void {
        gpa.free(t.bytes);
        gpa.free(t.literals);
        t.* = undefined;
    }

    /// The tables of `lits`: at most `max_literals`, each nonempty.
    pub fn build(gpa: Allocator, lits: []const []const u8) Allocator.Error!Teddy {
        std.debug.assert(lits.len > 0 and lits.len <= max_literals);
        var t: Teddy = .{ .n = 3, .lo = @splat(@splat(0)), .hi = @splat(@splat(0)), .bytes = &.{}, .literals = &.{}, .first = undefined };
        var total: usize = 0;
        for (lits) |lit| {
            std.debug.assert(lit.len > 0);
            t.n = @intCast(@min(t.n, lit.len));
            total += lit.len;
        }
        t.bytes = try gpa.alloc(u8, total);
        errdefer gpa.free(t.bytes);
        t.literals = try gpa.alloc(Literal, lits.len);
        var at: u32 = 0;
        var k: usize = 0;
        for (0..buckets) |b| {
            t.first[b] = @intCast(k);
            var i = b;
            while (i < lits.len) : (i += buckets) {
                const lit = lits[i];
                @memcpy(t.bytes[at..][0..lit.len], lit);
                t.literals[k] = .{ .start = at, .len = @intCast(lit.len) };
                at += @intCast(lit.len);
                k += 1;
                const bit = @as(u8, 1) << @intCast(b);
                for (0..t.n) |j| {
                    t.lo[j][lit[j] & 0x0f] |= bit;
                    t.hi[j][lit[j] >> 4] |= bit;
                }
            }
        }
        t.first[buckets] = @intCast(k);
        return t;
    }

    /// Whether a literal of a bucket in `mask` is whole at `at` in `haystack`.
    fn verify(t: *const Teddy, haystack: []const u8, at: usize, mask: u8) bool {
        var m = mask;
        while (m != 0) : (m &= m - 1) {
            const b = @ctz(m);
            for (t.literals[t.first[b]..t.first[b + 1]]) |lit| {
                const bytes = t.bytes[lit.start..][0..lit.len];
                if (at + bytes.len <= haystack.len and std.mem.eql(u8, haystack[at..][0..bytes.len], bytes)) return true;
            }
        }
        return false;
    }
};

/// The first position at or after `start` where a literal is whole in `haystack`. `width` is
/// the vector's bytes (16, or 32 where the shuffle works in two 16-byte lanes), `shuffle(table,
/// index)` the byte shuffle.
pub inline fn find(comptime width: usize, comptime shuffle: anytype, t: *const Teddy, haystack: []const u8, start: usize) ?usize {
    const V = @Vector(width, u8);
    var lo: [3]V = undefined;
    var hi: [3]V = undefined;
    for (0..3) |j| {
        var l: [width]u8 = undefined;
        var h: [width]u8 = undefined;
        for (0..width) |i| {
            l[i] = t.lo[j][i % 16];
            h[i] = t.hi[j][i % 16];
        }
        lo[j] = l;
        hi[j] = h;
    }
    const nibble: V = @splat(0x0f);
    const four: @Vector(width, u3) = @splat(4);
    const zero: V = @splat(0);
    var at = start;
    while (at + width + 2 <= haystack.len) : (at += width) {
        var res: V = @splat(0xff);
        inline for (0..3) |j| if (j < t.n) {
            const v: V = haystack[at + j ..][0..width].*;
            res &= shuffle(lo[j], v & nibble) & shuffle(hi[j], v >> four);
        };
        const found: [width]u8 = res;
        var mask: @Int(.unsigned, width) = @bitCast(res != zero);
        while (mask != 0) : (mask &= mask - 1) {
            const i = @ctz(mask);
            if (t.verify(haystack, at + i, found[i])) return at + i;
        }
    }
    while (at < haystack.len) : (at += 1) {
        if (t.verify(haystack, at, 0xff)) return at;
    }
    return null;
}
