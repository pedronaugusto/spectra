//! Literals a pattern's matches start or end with, for the prefilters: regex-syntax's
//! extraction (`hir::literal`), read from the `Hir` on an explicit stack.
//!
//! A `Seq` is the literals every match starts with (prefixes) or ends with (suffixes), or
//! infinite: any string may. Each literal is exact, the whole of a match, or inexact, only its
//! start or end. A finite empty `Seq` means no match is possible. Prefixes keep the pattern's
//! preference order; suffixes do not.
//!
//! Exact speaks of the bytes alone. A look assertion or an ECMAScript lookahead reads as the
//! empty string, as regex-syntax reads a look: `^ab` and `(?=ab)ab` give an exact `ab`, which
//! holds only where the assertion does. A strategy that answers from literals without running
//! an automaton must first see that the pattern asserts nothing.
//!
//! Every limit bounds what is made: a class past `limit_class` code points or bytes, a
//! sequence past `limit_total` literals or a literal past `limit_literal_len` bytes is cut or
//! made infinite, so each `Seq` holds at most `limit_total` literals of `limit_literal_len`
//! bytes. Literal bytes are shared between sequences, never written once made.
//!
//! Which literals make a good prefilter (byte frequencies, the preference optimization) is the
//! prefilters' choice, with them; a required inner literal is the meta engine's, reading these.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Hir = @import("Hir.zig");

pub const Literal = struct {
    bytes: []const u8,
    /// The whole of a match, not only its start or end.
    exact: bool,

    pub fn eql(a: Literal, b: Literal) bool {
        return a.exact == b.exact and std.mem.eql(u8, a.bytes, b.bytes);
    }

    /// Its first `len` bytes, inexact if that cut it.
    fn keepFirst(lit: *Literal, len: usize) void {
        if (len >= lit.bytes.len) return;
        lit.exact = false;
        lit.bytes = lit.bytes[0..len];
    }

    /// Its last `len` bytes, inexact if that cut it.
    fn keepLast(lit: *Literal, len: usize) void {
        if (len >= lit.bytes.len) return;
        lit.exact = false;
        lit.bytes = lit.bytes[lit.bytes.len - len ..];
    }
};

pub const Seq = struct {
    /// Null: infinite, any string.
    list: ?std.ArrayList(Literal),

    pub const infinite: Seq = .{ .list = null };
    pub const empty: Seq = .{ .list = .empty };

    pub fn singleton(arena: Allocator, lit: Literal) Allocator.Error!Seq {
        var list: std.ArrayList(Literal) = .empty;
        try list.append(arena, lit);
        return .{ .list = list };
    }

    /// A finite sequence of `lits`, each exact.
    pub fn exactOf(arena: Allocator, lits: []const []const u8) Allocator.Error!Seq {
        var list: std.ArrayList(Literal) = try .initCapacity(arena, lits.len);
        for (lits) |bytes| list.appendAssumeCapacity(.{ .bytes = bytes, .exact = true });
        return .{ .list = list };
    }

    /// The literals, or null where the sequence is infinite.
    pub fn literals(seq: *const Seq) ?[]const Literal {
        return if (seq.list) |list| list.items else null;
    }

    pub fn clone(seq: *const Seq, arena: Allocator) Allocator.Error!Seq {
        return .{ .list = if (seq.list) |list| try list.clone(arena) else null };
    }

    pub fn isFinite(seq: *const Seq) bool {
        return seq.list != null;
    }

    pub fn len(seq: *const Seq) ?usize {
        return if (seq.list) |list| list.items.len else null;
    }

    /// Finite, and every literal exact.
    pub fn isExact(seq: *const Seq) bool {
        const lits = seq.literals() orelse return false;
        for (lits) |lit| if (!lit.exact) return false;
        return true;
    }

    /// Infinite, or no literal exact: nothing put after it can add to it.
    pub fn isInexact(seq: *const Seq) bool {
        const lits = seq.literals() orelse return true;
        for (lits) |lit| if (lit.exact) return false;
        return true;
    }

    pub fn minLiteralLen(seq: *const Seq) ?usize {
        const lits = seq.literals() orelse return null;
        if (lits.len == 0) return null;
        var min: usize = std.math.maxInt(usize);
        for (lits) |lit| min = @min(min, lit.bytes.len);
        return min;
    }

    /// Adds `lit` at the end, unless it is the last one already.
    pub fn push(seq: *Seq, arena: Allocator, lit: Literal) Allocator.Error!void {
        const list = &(seq.list orelse return);
        if (list.items.len != 0 and list.items[list.items.len - 1].eql(lit)) return;
        try list.append(arena, lit);
    }

    pub fn makeInexact(seq: *Seq) void {
        const list = &(seq.list orelse return);
        for (list.items) |*lit| lit.exact = false;
    }

    pub fn makeInfinite(seq: *Seq) void {
        seq.list = null;
    }

    pub fn keepFirstBytes(seq: *Seq, n: usize) void {
        const list = &(seq.list orelse return);
        for (list.items) |*lit| lit.keepFirst(n);
    }

    pub fn keepLastBytes(seq: *Seq, n: usize) void {
        const list = &(seq.list orelse return);
        for (list.items) |*lit| lit.keepLast(n);
    }

    /// Removes each literal equal in bytes to the one before it; where one of the two was
    /// inexact, the one kept is.
    pub fn dedup(seq: *Seq) void {
        const list = &(seq.list orelse return);
        if (list.items.len == 0) return;
        var out: usize = 0;
        for (list.items[1..]) |lit| {
            const kept = &list.items[out];
            if (std.mem.eql(u8, kept.bytes, lit.bytes)) {
                if (kept.exact != lit.exact) kept.exact = false;
            } else {
                out += 1;
                list.items[out] = lit;
            }
        }
        list.shrinkRetainingCapacity(out + 1);
    }

    /// `seq` then `other`: infinite if either is.
    pub fn unionWith(seq: *Seq, arena: Allocator, other: *const Seq) Allocator.Error!void {
        const theirs = other.literals() orelse {
            seq.makeInfinite();
            return;
        };
        const list = &(seq.list orelse return);
        try list.appendSlice(arena, theirs);
        seq.dedup();
    }

    /// Each exact literal of `seq` followed by each of `other`'s; an inexact one is kept as it
    /// is. Where `other` is infinite, `seq` is infinite if it held the empty string, else
    /// inexact.
    pub fn crossForward(seq: *Seq, arena: Allocator, other: *const Seq) Allocator.Error!void {
        const theirs = seq.crossPreamble(other) orelse return;
        const mine = seq.list.?.items;
        var out: std.ArrayList(Literal) = try .initCapacity(arena, mine.len *| @max(theirs.len, 1));
        for (mine) |lit| {
            if (!lit.exact) {
                try out.append(arena, lit);
                continue;
            }
            for (theirs) |next| try out.append(arena, .{ .bytes = try join(arena, lit.bytes, next.bytes), .exact = next.exact });
        }
        seq.list = out;
        seq.dedup();
    }

    /// Each of `other`'s literals followed by each exact literal of `seq` (suffixes, read
    /// backwards); an inexact one of `seq` is kept once.
    pub fn crossReverse(seq: *Seq, arena: Allocator, other: *const Seq) Allocator.Error!void {
        const theirs = seq.crossPreamble(other) orelse return;
        const mine = seq.list.?.items;
        var out: std.ArrayList(Literal) = try .initCapacity(arena, mine.len *| @max(theirs.len, 1));
        for (theirs, 0..) |before, i| {
            for (mine) |lit| {
                if (!lit.exact) {
                    if (i == 0) try out.append(arena, lit);
                    continue;
                }
                try out.append(arena, .{ .bytes = try join(arena, before.bytes, lit.bytes), .exact = before.exact });
            }
        }
        seq.list = out;
        seq.dedup();
    }

    /// The finite literals of `other` where both are finite; else what crossing with an
    /// infinite one leaves `seq`, and null.
    fn crossPreamble(seq: *Seq, other: *const Seq) ?[]const Literal {
        const theirs = other.literals() orelse {
            if (seq.minLiteralLen() == 0) seq.makeInfinite() else seq.makeInexact();
            return null;
        };
        if (seq.list == null) return null;
        return theirs;
    }

    /// Removes each literal an earlier one is a prefix of: under leftmost-first, the earlier
    /// one always matches first. Unless `keep_exact`, the earlier one becomes inexact.
    pub fn minimizeByPreference(seq: *Seq, arena: Allocator, keep_exact: bool) Allocator.Error!void {
        const list = &(seq.list orelse return);
        var trie: PreferenceTrie = .{};
        var out: usize = 0;
        var weakened: std.ArrayList(usize) = .empty;
        for (list.items) |lit| {
            if (try trie.insert(arena, lit.bytes, out)) |earlier| {
                if (!keep_exact) try weakened.append(arena, earlier);
            } else {
                list.items[out] = lit;
                out += 1;
            }
        }
        list.shrinkRetainingCapacity(out);
        for (weakened.items) |i| list.items[i].exact = false;
    }

    /// The bytes every literal starts with, or null where the sequence is infinite or empty.
    pub fn longestCommonPrefix(seq: *const Seq) ?[]const u8 {
        const lits = seq.literals() orelse return null;
        if (lits.len == 0) return null;
        var common = lits[0].bytes;
        for (lits[1..]) |lit| {
            var n: usize = 0;
            while (n < common.len and n < lit.bytes.len and common[n] == lit.bytes[n]) n += 1;
            common = common[0..n];
        }
        return common;
    }

    /// The bytes every literal ends with, or null where the sequence is infinite or empty.
    pub fn longestCommonSuffix(seq: *const Seq) ?[]const u8 {
        const lits = seq.literals() orelse return null;
        if (lits.len == 0) return null;
        var common = lits[0].bytes;
        for (lits[1..]) |lit| {
            var n: usize = 0;
            while (n < common.len and n < lit.bytes.len and common[common.len - 1 - n] == lit.bytes[lit.bytes.len - 1 - n]) n += 1;
            common = common[common.len - n ..];
        }
        return common;
    }
};

fn join(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    const out = try arena.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// The literals kept so far, by their bytes: whether one is a prefix of a new one.
const PreferenceTrie = struct {
    /// Each state's transitions, sorted by byte.
    states: std.ArrayList(std.ArrayList(Edge)) = .empty,
    /// Per state, the position of the kept literal ending there.
    ends: std.ArrayList(?usize) = .empty,

    const Edge = struct { byte: u8, to: u32 };

    /// Adds `bytes` as the literal kept at `position`, or returns the position of an earlier
    /// literal that is a prefix of it (itself included), adding nothing.
    fn insert(trie: *PreferenceTrie, arena: Allocator, bytes: []const u8, position: usize) Allocator.Error!?usize {
        if (trie.states.items.len == 0) _ = try trie.state(arena);
        var at: u32 = 0;
        if (trie.ends.items[at]) |earlier| return earlier;
        for (bytes) |b| {
            const edges = &trie.states.items[at];
            var low: usize = 0;
            var high: usize = edges.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (edges.items[mid].byte < b) low = mid + 1 else high = mid;
            }
            if (low < edges.items.len and edges.items[low].byte == b) {
                at = edges.items[low].to;
                if (trie.ends.items[at]) |earlier| return earlier;
            } else {
                const next = try trie.state(arena);
                try trie.states.items[at].insert(arena, low, .{ .byte = b, .to = next });
                at = next;
            }
        }
        trie.ends.items[at] = position;
        return null;
    }

    fn state(trie: *PreferenceTrie, arena: Allocator) Allocator.Error!u32 {
        const id: u32 = @intCast(trie.states.items.len);
        try trie.states.append(arena, .empty);
        try trie.ends.append(arena, null);
        return id;
    }
};

pub const Kind = enum { prefix, suffix };

/// regex-syntax's extractor and its default limits.
pub const Extractor = struct {
    kind: Kind = .prefix,
    /// The most code points or bytes a class may hold and still be read as its literals.
    limit_class: u32 = 10,
    /// The most times a repetition is crossed with itself.
    limit_repeat: u32 = 10,
    /// The longest literal kept.
    limit_literal_len: u32 = 100,
    /// The most literals a sequence holds.
    limit_total: u32 = 250,

    const Frame = struct {
        node: Hir.Index,
        /// Children read so far.
        at: u32 = 0,
        acc: Seq = .infinite,
    };

    /// The literals of `hir`'s matches, made in `arena`; nothing is freed before it is.
    pub fn extract(e: Extractor, arena: Allocator, hir: *const Hir) Allocator.Error!Seq {
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(arena, .{ .node = hir.root });
        // The last finished frame's sequence, for its parent.
        var done: Seq = .infinite;
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            const finished: ?Seq = switch (hir.node(frame.node)) {
                .empty, .look, .lookaround => try Seq.singleton(arena, .{ .bytes = &.{}, .exact = true }),
                .literal => |bytes| blk: {
                    var seq = try Seq.singleton(arena, .{ .bytes = bytes, .exact = true });
                    e.enforceLen(&seq);
                    break :blk seq;
                },
                .unicode_class => |r| try e.unicodeClass(arena, r),
                .byte_class => |r| try e.byteClass(arena, r),
                .capture => |c| if (frame.at == 0) blk: {
                    frame.at = 1;
                    try stack.append(arena, .{ .node = c.sub });
                    break :blk null;
                } else done,
                .repetition => |r| if (frame.at == 0) blk: {
                    frame.at = 1;
                    try stack.append(arena, .{ .node = r.sub });
                    break :blk null;
                } else try e.repetition(arena, r, &done),
                .concat => |s| blk: {
                    const kids = hir.childrenOf(s);
                    if (frame.at == 0) {
                        frame.acc = try Seq.singleton(arena, .{ .bytes = &.{}, .exact = true });
                    } else try e.cross(arena, &frame.acc, &done);
                    // Once nothing in it is exact, nothing after can add to it.
                    if (frame.acc.isInexact() or frame.at == kids.len) break :blk frame.acc;
                    const next = switch (e.kind) {
                        .prefix => kids[frame.at],
                        .suffix => kids[kids.len - 1 - frame.at],
                    };
                    frame.at += 1;
                    try stack.append(arena, .{ .node = next });
                    break :blk null;
                },
                .alternation => |s| blk: {
                    // Always first to last, the order of preference, whichever the kind.
                    const kids = hir.childrenOf(s);
                    if (frame.at == 0) {
                        frame.acc = .empty;
                    } else try e.union_(arena, &frame.acc, &done);
                    if (!frame.acc.isFinite() or frame.at == kids.len) break :blk frame.acc;
                    frame.at += 1;
                    try stack.append(arena, .{ .node = kids[frame.at - 1] });
                    break :blk null;
                },
            };
            if (finished) |seq| {
                done = seq;
                _ = stack.pop();
            }
        }
        return done;
    }

    fn repetition(e: Extractor, arena: Allocator, r: Hir.Repetition, sub: *Seq) Allocator.Error!Seq {
        if (r.min == 0) {
            // `a?` is `a|` and keeps its exactness; `a*` does not.
            if (r.max != 1) sub.makeInexact();
            var nothing = try Seq.singleton(arena, .{ .bytes = &.{}, .exact = true });
            if (r.greedy) {
                try e.union_(arena, sub, &nothing);
                return sub.*;
            }
            try e.union_(arena, &nothing, sub);
            return nothing;
        }
        var seq = try Seq.singleton(arena, .{ .bytes = &.{}, .exact = true });
        for (0..@min(r.min, e.limit_repeat)) |_| {
            if (seq.isInexact()) break;
            var again = try sub.clone(arena);
            try e.cross(arena, &seq, &again);
        }
        // `a{n}` is exact if all of it was crossed; `a{n,m}` and `a{n,}` never are.
        if (r.max == null or r.max.? != r.min or r.min > e.limit_repeat) seq.makeInexact();
        return seq;
    }

    fn unicodeClass(e: Extractor, arena: Allocator, ranges: []const [2]u21) Allocator.Error!Seq {
        // Surrogates match nothing: they are dropped where a class is compiled.
        var count: u64 = 0;
        for (ranges) |r| {
            count += @as(u64, r[1]) - r[0] + 1;
            const low = @max(r[0], 0xd800);
            const high = @min(r[1], 0xdfff);
            if (low <= high) count -= @as(u64, high) - low + 1;
            if (count > e.limit_class) return .infinite;
        }
        var seq: Seq = .empty;
        for (ranges) |r| {
            var cp: u21 = r[0];
            while (true) : (cp += 1) {
                if (cp < 0xd800 or cp > 0xdfff) {
                    var buffer: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buffer) catch aegis.assert.never("a code point past the surrogates is a scalar value");
                    try seq.push(arena, .{ .bytes = try arena.dupe(u8, buffer[0..n]), .exact = true });
                }
                if (cp == r[1]) break;
            }
        }
        e.enforceLen(&seq);
        return seq;
    }

    fn byteClass(e: Extractor, arena: Allocator, ranges: []const [2]u8) Allocator.Error!Seq {
        var count: u32 = 0;
        for (ranges) |r| {
            count += @as(u32, r[1]) - r[0] + 1;
            if (count > e.limit_class) return .infinite;
        }
        var seq: Seq = .empty;
        for (ranges) |r| {
            var b: u8 = r[0];
            while (true) : (b += 1) {
                try seq.push(arena, .{ .bytes = try arena.dupe(u8, &.{b}), .exact = true });
                if (b == r[1]) break;
            }
        }
        e.enforceLen(&seq);
        return seq;
    }

    /// `seq` crossed with `other`, where the product stays within `limit_total`; past it,
    /// crossed with an infinite sequence.
    fn cross(e: Extractor, arena: Allocator, seq: *Seq, other: *Seq) Allocator.Error!void {
        if (seq.len()) |a| if (other.len()) |b| if (a *| b > e.limit_total) other.makeInfinite();
        switch (e.kind) {
            .prefix => try seq.crossForward(arena, other),
            .suffix => try seq.crossReverse(arena, other),
        }
        aegis.assert.invariant((seq.len() orelse 0) <= e.limit_total, "a sequence holds at most limit_total literals");
        e.enforceLen(seq);
    }

    /// `seq` then `other`, where both fit `limit_total`; past it, each cut to four bytes (what
    /// a Teddy search takes) to make room, and if that is not enough, infinite.
    fn union_(e: Extractor, arena: Allocator, seq: *Seq, other: *Seq) Allocator.Error!void {
        if (seq.len()) |a| if (other.len()) |b| if (a +| b > e.limit_total) {
            switch (e.kind) {
                .prefix => {
                    seq.keepFirstBytes(4);
                    other.keepFirstBytes(4);
                },
                .suffix => {
                    seq.keepLastBytes(4);
                    other.keepLastBytes(4);
                },
            }
            seq.dedup();
            other.dedup();
            if (seq.len().? +| other.len().? > e.limit_total) other.makeInfinite();
        };
        try seq.unionWith(arena, other);
        aegis.assert.invariant((seq.len() orelse 0) <= e.limit_total, "a sequence holds at most limit_total literals");
    }

    fn enforceLen(e: Extractor, seq: *Seq) void {
        switch (e.kind) {
            .prefix => seq.keepFirstBytes(e.limit_literal_len),
            .suffix => seq.keepLastBytes(e.limit_literal_len),
        }
    }
};
