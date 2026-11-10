//! Sets of code points or of bytes, as sorted ranges, none touching another: what a class
//! becomes. Every operation leaves the set in that form. The set operations run in time linear
//! in the ranges they read, and closing under case in the orbits its ranges hold; `fromRanges`
//! and `add`, which take ranges in any order, sort them.
//!
//! A code point set spans U+0000 to U+10FFFF, surrogates included: the ECMAScript dialect can
//! name one. A set is held to scalar values where it is compiled to UTF-8.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const Allocator = std.mem.Allocator;
const case = xenoglyph.case;

pub const CodePoints = Set(u21, 0x10ffff);
pub const Bytes = Set(u8, 0xff);

/// How a class closes under case.
pub const Folding = enum {
    /// Simple case folding (CaseFolding.txt C and S), as Rust's regex and ECMA-262 under `u`
    /// and `v` match without case.
    simple,
    /// ASCII's letters alone, as Rust's regex does without Unicode.
    ascii,
    /// ECMA-262's Canonicalize without `u` or `v`: two UTF-16 code units are one when their
    /// full uppercase mappings are the same single code unit, but one past U+007F never meets
    /// one in ASCII. Code points past U+FFFF are two code units, each its own.
    ecma_uppercase,
};

pub fn Set(comptime T: type, comptime max: T) type {
    return struct {
        const Self = @This();
        pub const Range = [2]T;
        pub const last = max;

        /// Sorted by start, apart: each range's start is past the previous range's end + 1.
        ranges: std.ArrayList(Range) = .empty,

        pub fn deinit(s: *Self, gpa: Allocator) void {
            s.ranges.deinit(gpa);
            s.* = undefined;
        }

        pub fn clone(s: *const Self, gpa: Allocator) Allocator.Error!Self {
            return .{ .ranges = try s.ranges.clone(gpa) };
        }

        /// The set of `ranges`, in any order, overlapping or not, each `first <= last`.
        pub fn fromRanges(gpa: Allocator, ranges: []const Range) Allocator.Error!Self {
            var s: Self = .{};
            errdefer s.deinit(gpa);
            try s.ranges.appendSlice(gpa, ranges);
            s.canonicalize();
            return s;
        }

        /// The set of the ranges in `list`, which it takes over: in any order, overlapping or
        /// not, each `first <= last`.
        pub fn fromList(list: std.ArrayList(Range)) Self {
            var s: Self = .{ .ranges = list };
            s.canonicalize();
            return s;
        }

        pub fn items(s: *const Self) []const Range {
            return s.ranges.items;
        }

        pub fn isEmpty(s: *const Self) bool {
            return s.ranges.items.len == 0;
        }

        pub fn contains(s: *const Self, value: T) bool {
            var low: usize = 0;
            var high: usize = s.ranges.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                const r = s.ranges.items[mid];
                if (value < r[0]) high = mid else if (value > r[1]) low = mid + 1 else return true;
            }
            return false;
        }

        /// How many values the set holds.
        pub fn count(s: *const Self) u32 {
            var n: u32 = 0;
            for (s.ranges.items) |r| n += @as(u32, r[1]) - r[0] + 1;
            return n;
        }

        pub fn eql(s: *const Self, other: *const Self) bool {
            if (s.ranges.items.len != other.ranges.items.len) return false;
            // Value by value: a `u21` in memory has bits past its own, which nothing defines.
            for (s.ranges.items, other.ranges.items) |a, b| {
                if (a[0] != b[0] or a[1] != b[1]) return false;
            }
            return true;
        }

        /// Adds `range`, then puts the set back in order.
        pub fn add(s: *Self, gpa: Allocator, range: Range) Allocator.Error!void {
            aegis.assert.invariant(range[0] <= range[1], "a range runs first to last");
            try s.ranges.append(gpa, range);
            s.canonicalize();
        }

        /// Sorts and merges the ranges, in place.
        fn canonicalize(s: *Self) void {
            const list = s.ranges.items;
            if (list.len == 0) return;
            std.mem.sort(Range, list, {}, struct {
                fn less(_: void, a: Range, b: Range) bool {
                    return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
                }
            }.less);
            var out: usize = 0;
            for (list[1..]) |r| {
                const current = &list[out];
                // Overlapping or touching: one range.
                if (@as(u32, r[0]) <= @as(u32, current[1]) + 1) {
                    current[1] = @max(current[1], r[1]);
                } else {
                    out += 1;
                    list[out] = r;
                }
            }
            s.ranges.shrinkRetainingCapacity(out + 1);
        }

        /// Every value of `s` or `other`: the two in order, merged.
        pub fn unionWith(s: *Self, gpa: Allocator, other: *const Self) Allocator.Error!void {
            if (other.ranges.items.len == 0) return;
            var out: std.ArrayList(Range) = try .initCapacity(gpa, s.ranges.items.len + other.ranges.items.len);
            errdefer out.deinit(gpa);
            const a = s.ranges.items;
            const b = other.ranges.items;
            var i: usize = 0;
            var j: usize = 0;
            while (i < a.len or j < b.len) {
                const next = if (j == b.len or (i < a.len and a[i][0] <= b[j][0])) blk: {
                    i += 1;
                    break :blk a[i - 1];
                } else blk: {
                    j += 1;
                    break :blk b[j - 1];
                };
                const written = out.items;
                // Overlapping or touching the last: one range.
                if (written.len != 0 and @as(u32, next[0]) <= @as(u32, written[written.len - 1][1]) + 1) {
                    written[written.len - 1][1] = @max(written[written.len - 1][1], next[1]);
                } else out.appendAssumeCapacity(next);
            }
            s.ranges.deinit(gpa);
            s.ranges = out;
        }

        /// Every value of both.
        pub fn intersect(s: *Self, gpa: Allocator, other: *const Self) Allocator.Error!void {
            var out: std.ArrayList(Range) = .empty;
            errdefer out.deinit(gpa);
            const a = s.ranges.items;
            const b = other.ranges.items;
            var i: usize = 0;
            var j: usize = 0;
            while (i < a.len and j < b.len) {
                const low = @max(a[i][0], b[j][0]);
                const high = @min(a[i][1], b[j][1]);
                if (low <= high) try out.append(gpa, .{ low, high });
                if (a[i][1] < b[j][1]) i += 1 else j += 1;
            }
            s.ranges.deinit(gpa);
            s.ranges = out;
        }

        /// Every value of `s` not in `other`.
        pub fn subtract(s: *Self, gpa: Allocator, other: *const Self) Allocator.Error!void {
            var complement = try other.clone(gpa);
            defer complement.deinit(gpa);
            try complement.negate(gpa);
            try s.intersect(gpa, &complement);
        }

        /// Every value of one and not the other.
        pub fn symmetricDifference(s: *Self, gpa: Allocator, other: *const Self) Allocator.Error!void {
            var both = try s.clone(gpa);
            defer both.deinit(gpa);
            try both.intersect(gpa, other);
            try s.unionWith(gpa, other);
            try s.subtract(gpa, &both);
        }

        /// Every value from 0 to `max` not in the set.
        pub fn negate(s: *Self, gpa: Allocator) Allocator.Error!void {
            var out: std.ArrayList(Range) = .empty;
            errdefer out.deinit(gpa);
            var next: u32 = 0;
            for (s.ranges.items) |r| {
                if (r[0] > next) try out.append(gpa, .{ @intCast(next), r[0] - 1 });
                next = @as(u32, r[1]) + 1;
            }
            if (next <= max) try out.append(gpa, .{ @intCast(next), max });
            s.ranges.deinit(gpa);
            s.ranges = out;
        }

        /// Adds every value that matches one of the set's without case, by `folding`.
        pub fn closeUnderCase(s: *Self, gpa: Allocator, folding: Folding) Allocator.Error!void {
            const held = s.ranges.items.len;
            for (0..held) |i| {
                const r = s.ranges.items[i];
                switch (folding) {
                    .ascii => {
                        try addAsciiCase(s, gpa, r, 'A', 'Z', 'a' - 'A', true);
                        try addAsciiCase(s, gpa, r, 'a', 'z', 'a' - 'A', false);
                    },
                    .simple, .ecma_uppercase => if (T == u8) {
                        // A byte set closes under ASCII's case alone: no byte is a code point
                        // past U+007F.
                        try addAsciiCase(s, gpa, r, 'A', 'Z', 'a' - 'A', true);
                        try addAsciiCase(s, gpa, r, 'a', 'z', 'a' - 'A', false);
                    } else {
                        var next = case.nextFolding(r[0]);
                        while (next) |cp| : (next = if (cp == 0x10ffff) null else case.nextFolding(cp + 1)) {
                            if (cp > r[1]) break;
                            for (case.simpleFoldOrbit(cp)) |member| {
                                if (folding == .ecma_uppercase and (cp > 0xffff or member > 0xffff or ecmaCanonicalize(member) != ecmaCanonicalize(cp))) continue;
                                try s.ranges.append(gpa, .{ member, member });
                            }
                        }
                    },
                }
            }
            s.canonicalize();
        }

        fn addAsciiCase(s: *Self, gpa: Allocator, r: Range, first: u8, end: u8, delta: u8, up: bool) Allocator.Error!void {
            const low = @max(@as(u32, r[0]), first);
            const high = @min(@as(u32, r[1]), end);
            if (low > high) return;
            const shift: u32 = delta;
            if (up) {
                try s.ranges.append(gpa, .{ @intCast(low + shift), @intCast(high + shift) });
            } else {
                try s.ranges.append(gpa, .{ @intCast(low - shift), @intCast(high - shift) });
            }
        }
    };
}

/// ECMA-262's Canonicalize without `u` or `v`, of one code unit: its full uppercase mapping
/// where that is one code unit and does not take it from past U+007F into ASCII, else itself.
pub fn ecmaCanonicalize(unit: u21) u21 {
    if (unit > 0xffff) return unit;
    // A surrogate alone has no case.
    if (unit >= 0xd800 and unit <= 0xdfff) return unit;
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(unit, &bytes) catch aegis.assert.never("a code unit past the surrogates is a scalar value");
    var buffer: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    // A full uppercase mapping is at most three code points: twelve bytes.
    case.write(.upper, bytes[0..n], &w, .{}) catch aegis.assert.never("a code point's uppercase fits sixteen bytes");
    const upper = w.buffered();
    const length = std.unicode.utf8ByteSequenceLength(upper[0]) catch aegis.assert.never("xenoglyph writes UTF-8");
    if (length != upper.len) return unit;
    const cu = std.unicode.utf8Decode(upper) catch aegis.assert.never("xenoglyph writes UTF-8");
    if (cu > 0xffff) return unit;
    if (unit >= 0x80 and cu < 0x80) return unit;
    return cu;
}
