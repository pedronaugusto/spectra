//! A range of code points as the UTF-8 byte sequences that encode it, regex-syntax's
//! `Utf8Sequences`: each sequence is one to four byte ranges, and a string of bytes is the
//! encoding of a code point of the range exactly when one sequence matches it range by range.
//! Surrogates are left out, since UTF-8 encodes none, and sequences come out in the order of
//! their bytes, which the compiler's suffix sharing needs.
const std = @import("std");
const aegis = @import("aegis");

pub const Range = struct {
    lo: u8,
    hi: u8,

    pub fn eql(a: Range, b: Range) bool {
        return a.lo == b.lo and a.hi == b.hi;
    }
};

pub const Sequence = struct {
    ranges: [4]Range,
    len: u8,

    pub fn slice(s: *const Sequence) []const Range {
        return s.ranges[0..s.len];
    }
};

const Scalars = struct { lo: u32, hi: u32 };

/// The sequences of one range of code points, in byte order.
pub const Sequences = struct {
    /// Pieces still to split, last first. Each split leaves at most one piece behind per byte
    /// of encoding and per length, so a few suffice.
    stack: [stack_capacity]Scalars = undefined,
    len: usize = 0,

    const stack_capacity = 16;

    pub fn init(lo: u21, hi: u21) Sequences {
        var s: Sequences = .{};
        s.push(lo, hi);
        return s;
    }

    fn push(s: *Sequences, lo: u32, hi: u32) void {
        aegis.assert.invariant(s.len < stack_capacity, "a range splits into a few pieces at once");
        s.stack[s.len] = .{ .lo = lo, .hi = hi };
        s.len += 1;
    }

    pub fn next(s: *Sequences) ?Sequence {
        top: while (s.len > 0) {
            s.len -= 1;
            var r = s.stack[s.len];
            inner: while (true) {
                if (r.lo < 0xe000 and r.hi > 0xd7ff) {
                    s.push(0xe000, r.hi);
                    r.hi = 0xd7ff;
                    continue :inner;
                }
                if (r.lo > r.hi) continue :top;
                for ([_]u32{ 0x7f, 0x7ff, 0xffff }) |max| {
                    if (r.lo <= max and max < r.hi) {
                        s.push(max + 1, r.hi);
                        r.hi = max;
                        continue :inner;
                    }
                }
                if (r.hi <= 0x7f) {
                    var one: Sequence = .{ .ranges = undefined, .len = 1 };
                    one.ranges[0] = .{ .lo = @intCast(r.lo), .hi = @intCast(r.hi) };
                    return one;
                }
                for (1..4) |i| {
                    const m: u32 = (@as(u32, 1) << @intCast(6 * i)) - 1;
                    if ((r.lo & ~m) != (r.hi & ~m)) {
                        if ((r.lo & m) != 0) {
                            s.push((r.lo | m) + 1, r.hi);
                            r.hi = r.lo | m;
                            continue :inner;
                        }
                        if ((r.hi & m) != m) {
                            s.push(r.hi & ~m, r.hi);
                            r.hi = (r.hi & ~m) - 1;
                            continue :inner;
                        }
                    }
                }
                var lo_bytes: [4]u8 = undefined;
                var hi_bytes: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(r.lo), &lo_bytes) catch aegis.assert.never("a piece holds no surrogate");
                const n_hi = std.unicode.utf8Encode(@intCast(r.hi), &hi_bytes) catch aegis.assert.never("a piece holds no surrogate");
                aegis.assert.invariant(n == n_hi, "a piece's ends encode in as many bytes");
                var out: Sequence = .{ .ranges = undefined, .len = @intCast(n) };
                for (0..n) |i| out.ranges[i] = .{ .lo = lo_bytes[i], .hi = hi_bytes[i] };
                return out;
            }
        }
        return null;
    }
};
