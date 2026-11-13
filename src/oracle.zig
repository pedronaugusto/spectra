//! Lookaround's rows (Barrière and Pit-Claudel, "Linear Matching of JavaScript Regular
//! Expressions", PLDI 2024, §4.3.1; spectra.md §3.1, phase 1): each lookaround's truth at every
//! position of the haystack, built before the scan that reads it, so that a `check` state is a
//! lookup and every engine's search keeps the uniform futures it is linear by.
//!
//! A lookbehind holds at p exactly where a match of its body ends at p: a forward scan of
//! `.*?body` that writes a 1 at every position where it accepts, and never stops at a match,
//! finds them all, since the simulation keeps a path to every (state, position) any path
//! reaches and merges only paths with the same futures. A lookahead holds at p exactly where a
//! match of its body starts at p, which is where a match of the body reversed ends when the
//! haystack is read backwards: a backward scan of `.*?rev(body)` from the end, writing a 1 at
//! every position where it accepts. Only which strings match counts, so the automata are the
//! strings-only ones (no groups, no ECMAScript empty checks, which prune ways of matching, not
//! strings: nfa/compile.zig's doc).
//!
//! A lookaround inside a body is a `check` state there. Read the same way as the scan that
//! queries it (a lookbehind in a forward scan, a lookahead in a backward one), it is **streamed**
//! (§4.4, and its mirror): its own automaton runs in lockstep with that scan, closed at each
//! position before the states that query it, so whether it accepted at the position is its
//! truth there, known from what the scan has read. Read the other way, it is **stored**: its row
//! is built in full first, innermost first, which is from the highest number down (lookarounds
//! are numbered in preorder). A scan keeps each lane's seeds, the states the last byte led to,
//! and closes them at each position deepest lane first, so a stream's bit is set before any
//! check reads it. Each scan enters each lane's states at most once per position, so a row costs
//! O(‖body‖·n) for its body and its streams, and all the rows together O(|r|·n). Stored rows
//! hold one bit per position each, in a store sized once (`Cache.init`): a haystack whose rows
//! would pass it is refused before a byte is read (`error.HaystackTooLong`), never built in
//! pieces. A streamed lookaround costs one bit, at the position being read.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Hir = @import("Hir.zig");
const Nfa = @import("Nfa.zig");
const compile_mod = @import("nfa/compile.zig");
const look_zig = @import("nfa/look.zig");
const SparseSet = @import("SparseSet.zig");
const Limits = @import("Limits.zig");
const Diagnostic = @import("syntax/diagnostic.zig").Diagnostic;
const Ast = @import("syntax/Ast.zig");

pub const Error = error{
    /// The rows of this haystack would pass the store's capacity.
    HaystackTooLong,
};

/// What scan builds a lookaround's row.
pub const Scan = enum {
    /// A lookbehind's: forward over `.*?body`.
    forward,
    /// A lookahead's: backward over `.*?rev(body)`.
    backward,
};

/// A lookaround's automaton, how it is scanned, and whether its row is stored or streamed.
pub const Row = struct {
    scan: Scan,
    nfa: Nfa,
    /// The lookaround whose body holds it; null at the top, in the main expression.
    parent: ?u32,
    /// Stored: its slot in the store. Null: streamed in the scan that queries it.
    slot: ?u32,
};

/// Every lookaround's automaton, by its number, and which rows are stored: worked out once.
pub const Plan = struct {
    rows: []Row,
    /// How many rows are stored: what the store holds per position.
    stored: u32,
    /// Whether the automata are this plan's to free; a view (`view`) shares another's.
    owns: bool = true,

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        if (p.owns) for (p.rows) |*r| r.nfa.deinit(gpa);
        gpa.free(p.rows);
        p.* = undefined;
    }

    /// The same automata with rows stored or streamed as `layout` says: a plan for another kind
    /// of search, freed before `p`.
    pub fn view(p: *const Plan, gpa: Allocator, layout: Layout) Allocator.Error!Plan {
        const rows = try gpa.dupe(Row, p.rows);
        return .{ .rows = rows, .stored = assign(rows, layout), .owns = false };
    }

    /// Whether lookaround `row` is streamed in the scan of `of` (a lookaround, or null for the
    /// main expression): its chain of parents up to `of` streamed all the way.
    pub fn streamedIn(p: *const Plan, row: u32, of: ?u32) bool {
        var at = row;
        while (true) {
            const r = p.rows[at];
            if (r.slot != null) return false;
            if (r.parent == of) return true;
            at = r.parent orelse return false;
        }
    }
};

/// Which rows a plan stores and which it streams.
pub const Layout = struct {
    /// The way the main expression's scan reads, which streams the lookarounds it queries
    /// directly that read the same way; null stores them all (no main scan streams).
    main: ?Scan = null,
    /// Every lookaround inside another stored: the runs that rebuild a lookaround's groups read
    /// the rows of the ones inside it at any position.
    store_nested: bool = false,
};

pub const PlanOptions = struct {
    limits: Limits = .{},
    utf8: bool = true,
    span: Ast.Span = .{ .start = 0, .end = 0 },
    layout: Layout = .{},
};

/// Streamed where its querying scan reads its way, else stored: each stored row's slot, and how
/// many.
fn assign(rows: []Row, layout: Layout) u32 {
    var stored: u32 = 0;
    for (rows) |*r| {
        const querying: ?Scan = if (r.parent) |up| rows[up].scan else layout.main;
        if ((layout.store_nested and r.parent != null) or querying != r.scan) {
            r.slot = stored;
            stored += 1;
        } else r.slot = null;
    }
    return stored;
}

/// Each lookaround's automaton, from the pattern's HIR, and which rows are stored. Each automaton
/// is charged to `Limits.nfa` on its own, as a pattern is.
pub fn plan(gpa: Allocator, hir: *const Hir, options: PlanOptions, diagnostic: ?*Diagnostic) compile_mod.Error!Plan {
    const rows = try gpa.alloc(Row, hir.lookarounds);
    // Each lookaround's parent: the nearest lookaround around it, found by walking down from
    // each body (children come before parents in the nodes, so a pass from the end finds every
    // parent before its children).
    const parents = try gpa.alloc(?u32, hir.lookarounds);
    defer gpa.free(parents);
    @memset(parents, null);
    const owner = try gpa.alloc(?u32, hir.nodes.len);
    defer gpa.free(owner);
    @memset(owner, null);
    var i = hir.nodes.len;
    while (i > 0) {
        i -= 1;
        const inside = owner[i];
        switch (hir.nodes[i]) {
            .lookaround => |la| {
                parents[la.index] = inside;
                owner[@backingInt(la.sub)] = la.index;
            },
            .repetition => |r| owner[@backingInt(r.sub)] = inside,
            .capture => |cap| owner[@backingInt(cap.sub)] = inside,
            .concat, .alternation => |slice| for (hir.childrenOf(slice)) |child| {
                owner[@backingInt(child)] = inside;
            },
            else => {},
        }
    }
    var made: usize = 0;
    errdefer {
        for (rows[0..made]) |*r| r.nfa.deinit(gpa);
        gpa.free(rows);
    }
    // Rows are kept by number; the nodes come in any order, each number once.
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, hir.lookarounds);
    defer seen.deinit(gpa);
    for (hir.nodes) |node| switch (node) {
        .lookaround => |la| {
            aegis.assert.invariant(la.index < hir.lookarounds and !seen.isSet(la.index), "each lookaround has a number of its own");
            var body = hir.*;
            body.root = la.sub;
            const scan: Scan = switch (la.kind) {
                .behind => .forward,
                .ahead => .backward,
            };
            const nfa = try compile_mod.compile(gpa, &body, .{
                .limits = options.limits,
                .utf8 = options.utf8,
                .span = options.span,
                .strings = true,
                .lookaround = true,
                .reverse = scan == .backward,
                .reverse_unanchored = scan == .backward,
            }, diagnostic);
            rows[la.index] = .{ .scan = scan, .nfa = nfa, .parent = parents[la.index], .slot = null };
            seen.set(la.index);
            made += 1;
        },
        else => {},
    };
    aegis.assert.invariant(made == hir.lookarounds, "every lookaround has a row");
    return .{ .rows = rows, .stored = assign(rows, options.layout) };
}

/// One lane of a scan: a lookaround's automaton, the states the last byte led to (its seeds),
/// and the states closed from them at the position being read.
pub const Lane = struct {
    seeds: SparseSet,
    closed: SparseSet,
};

/// The stored rows of one haystack and the scratch they are built with, allocated once.
pub const Cache = struct {
    /// One bit per stored row per position: slot `i`'s at `i * stride` words.
    bits: []usize,
    /// Words per row for the haystack the rows were last built for.
    stride: usize = 0,
    /// The haystack's positions the rows cover: its length plus one.
    positions: usize = 0,
    /// A lane per lookaround, by its number.
    lanes: []Lane,
    /// Each streamed lookaround's truth at the position being read.
    /// Each streamed lookaround's truth at the last two positions closed, by parity: a scan reads
    /// the position it is closing; the PikeVM, stepping, reads the next one too.
    ring: [2]std.DynamicBitSetUnmanaged,
    /// The main expression's stream runner (`advance`): the next position it closes.
    runner_next: usize = 0,
    /// The lanes of the scan being run, deepest first, the target last.
    order: []u32,
    stack: []Nfa.StateId,
    /// States entered by the last `fill`, over every row.
    visited: usize = 0,

    /// A store of `capacity` bytes for the stored rows, a lane for each lookaround, and one for
    /// `main` where a scan of the main expression runs on it (`isMatch`).
    pub fn init(gpa: Allocator, p: *const Plan, main: ?*const Nfa, capacity: usize) Allocator.Error!Cache {
        const bits = try gpa.alloc(usize, capacity / @sizeOf(usize));
        errdefer gpa.free(bits);
        const lanes = try gpa.alloc(Lane, p.rows.len + 1);
        var made: usize = 0;
        errdefer {
            for (lanes[0..made]) |*l| {
                l.seeds.deinit(gpa);
                l.closed.deinit(gpa);
            }
            gpa.free(lanes);
        }
        for (lanes, 0..) |*l, i| {
            const states = if (i < p.rows.len) p.rows[i].nfa.states.len else if (main) |m| m.states.len else 0;
            var seeds: SparseSet = try .init(gpa, states);
            errdefer seeds.deinit(gpa);
            l.* = .{ .seeds = seeds, .closed = try .init(gpa, states) };
            made += 1;
        }
        var even = try std.DynamicBitSetUnmanaged.initEmpty(gpa, p.rows.len);
        errdefer even.deinit(gpa);
        var odd = try std.DynamicBitSetUnmanaged.initEmpty(gpa, p.rows.len);
        errdefer odd.deinit(gpa);
        const order = try gpa.alloc(u32, p.rows.len + 1);
        errdefer gpa.free(order);
        var stack_len: usize = 1;
        for (p.rows) |r| stack_len = @max(stack_len, r.nfa.states.len + r.nfa.alternatives.len + 1);
        if (main) |m| stack_len = @max(stack_len, m.states.len + m.alternatives.len + 1);
        const stack = try gpa.alloc(Nfa.StateId, stack_len);
        return .{ .bits = bits, .lanes = lanes, .ring = .{ even, odd }, .order = order, .stack = stack };
    }

    /// The bytes `init` allocates for `p`, `main` and `capacity`: what `Limits.cache` bounds.
    pub fn bytes(p: *const Plan, main: ?*const Nfa, capacity: usize) usize {
        var total = capacity / @sizeOf(usize) * @sizeOf(usize);
        var stack_len: usize = 1;
        for (p.rows) |r| {
            total += 2 * r.nfa.states.len * SparseSet.bytes_per;
            stack_len = @max(stack_len, r.nfa.states.len + r.nfa.alternatives.len + 1);
        }
        if (main) |m| {
            total += 2 * m.states.len * SparseSet.bytes_per;
            stack_len = @max(stack_len, m.states.len + m.alternatives.len + 1);
        }
        total += (p.rows.len + 1) * @sizeOf(Lane) + 2 * ((p.rows.len + 63) / 64 * 8) + (p.rows.len + 1) * @sizeOf(u32);
        return total + stack_len * @sizeOf(Nfa.StateId);
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.bits);
        for (c.lanes) |*l| {
            l.seeds.deinit(gpa);
            l.closed.deinit(gpa);
        }
        gpa.free(c.lanes);
        c.ring[0].deinit(gpa);
        c.ring[1].deinit(gpa);
        gpa.free(c.order);
        gpa.free(c.stack);
        c.* = undefined;
    }

    /// Whether stored row `slot` holds at position `at`: the lookaround itself, before any
    /// negation.
    pub fn holds(c: *const Cache, slot: u32, at: usize) bool {
        aegis.assert.invariant(at < c.positions, "a row is read at a position of its haystack");
        const word = c.bits[slot * c.stride + at / @bitSizeOf(usize)];
        return (word >> @intCast(at % @bitSizeOf(usize))) & 1 != 0;
    }

    /// Writes stored row `slot` as holding at `at`: a row's scan, NFA or lazy DFA.
    pub fn mark(c: *Cache, slot: u32, at: usize) void {
        c.set(slot, at);
    }

    fn set(c: *Cache, slot: u32, at: usize) void {
        c.bits[slot * c.stride + at / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(at % @bitSizeOf(usize));
    }

    /// The longest haystack whose stored rows for `p` fit: null where `p` stores none.
    pub fn longest(c: *const Cache, p: *const Plan) ?usize {
        if (p.stored == 0) return null;
        const words = c.bits.len / p.stored;
        return if (words == 0) null else words * @bitSizeOf(usize) - 1;
    }

    /// Whether lookaround `row` holds at `at`, stored or streamed: a streamed one only at the
    /// position its scan is reading.
    fn truth(c: *const Cache, p: *const Plan, row: u32, at: usize) bool {
        return if (p.rows[row].slot) |slot| c.holds(slot, at) else c.ring[at & 1].isSet(row);
    }

    /// Whether lookaround `row` holds at `at`, for an engine's `check`: stored, or streamed by the
    /// runner, which has closed `at` and at most one position past it.
    pub fn truthAt(c: *const Cache, p: *const Plan, row: u32, at: usize) bool {
        if (p.rows[row].slot) |slot| return c.holds(slot, at);
        aegis.assert.invariant(at < c.runner_next and at + 2 >= c.runner_next, "a streamed lookaround is read at a position its runner has just closed");
        return c.ring[at & 1].isSet(row);
    }

    /// Starts the main expression's stream runner afresh where a search will need position
    /// `from` and it has passed it.
    pub fn begin(c: *Cache, p: *const Plan, from: usize) void {
        if (c.runner_next <= from) return;
        c.runner_next = 0;
        for (c.lanes[0..p.rows.len], 0..) |*l, row| if (p.streamedIn(@intCast(row), null)) {
            l.seeds.len = 0;
        };
    }

    /// Runs the main expression's streams (every lookaround streamed in it, deepest first) up to
    /// and including position `to`: from the haystack's start, since a lookbehind's truth is
    /// what lies before. Each position is closed once per run, so the runner's work over a search
    /// is O(Σ‖body‖·n).
    pub fn advance(c: *Cache, p: *const Plan, haystack: []const u8, to: usize) void {
        while (c.runner_next <= to) {
            const at = c.runner_next;
            var row = p.rows.len;
            while (row > 0) {
                row -= 1;
                if (!p.streamedIn(@intCast(row), null)) continue;
                const accepted = closeLane(p, c, &p.rows[row].nfa, &c.lanes[row], haystack, at);
                c.ring[at & 1].setValue(row, accepted);
            }
            if (at < haystack.len) {
                row = 0;
                while (row < p.rows.len) : (row += 1) {
                    if (p.streamedIn(@intCast(row), null)) stepLane(c, &p.rows[row].nfa, &c.lanes[row], haystack[at]);
                }
            }
            c.runner_next = at + 1;
        }
    }
};

/// Closes `lane`'s seeds, and its start, at `at`: whether it accepts there.
fn closeLane(p: *const Plan, c: *Cache, nfa: *const Nfa, lane: *Lane, haystack: []const u8, at: usize) bool {
    lane.closed.len = 0;
    // The lazy `.*?` before the body starts a match at every position.
    closure(p, c, nfa, &lane.closed, nfa.start_unanchored, haystack, at);
    for (lane.seeds.items()) |seed| closure(p, c, nfa, &lane.closed, nfa.stateAt(seed), haystack, at);
    var accepted = false;
    for (lane.closed.items()) |key| {
        if (nfa.state(nfa.stateAt(key)) == .match) accepted = true;
    }
    return accepted;
}

/// `lane`'s closed states read `byte`: its seeds at the next position.
fn stepLane(c: *Cache, nfa: *const Nfa, lane: *Lane, byte: u8) void {
    lane.seeds.len = 0;
    for (lane.closed.items()) |key| {
        c.visited += 1;
        const to: ?Nfa.StateId = switch (nfa.state(nfa.stateAt(key))) {
            .byte_range => |t| if (t.contains(byte)) t.next else null,
            .sparse => |slice| stepSparse(nfa, slice, byte),
            else => null,
        };
        if (to) |t| _ = lane.seeds.insert(t.raw());
    }
}

/// Whether some match of the main expression is in `haystack`: the stored rows built, then one
/// scan of `main` (`.*?` and the main expression, read the way `scan` says: forward, or backward
/// over the reversed one) with the lookarounds streamed in it, stopping at its first accept.
/// With `splits` (UTF-8, and a match may be empty), an accept inside a code point's encoding
/// does not count, as the searches pass such a match over.
pub fn isMatch(p: *const Plan, c: *Cache, main: *const Nfa, scan: Scan, haystack: []const u8, splits: bool) Error!bool {
    try fill(p, c, haystack);
    return scanMain(p, c, main, scan, haystack, splits);
}

/// `isMatch`'s scan of the main expression, the stored rows built already.
pub fn scanMain(p: *const Plan, c: *Cache, main: *const Nfa, scan: Scan, haystack: []const u8, splits: bool) bool {
    return scanLanes(p, c, .{ .main = .{ .nfa = main, .splits = splits } }, scan, haystack);
}

/// Whether, with `splits`, an accept at `at` counts: not inside a code point's encoding.
pub fn counts(haystack: []const u8, at: usize, splits: bool) bool {
    return !splits or isBoundary(haystack, at);
}

/// The longest haystack whose stored rows for `p` fit `capacity` bytes: null where `p` stores
/// none, so every haystack does.
pub fn longestFor(p: *const Plan, capacity: usize) ?usize {
    if (p.stored == 0) return null;
    const words = capacity / @sizeOf(usize) / p.stored;
    return if (words == 0) 0 else words * @bitSizeOf(usize) - 1;
}

fn isBoundary(haystack: []const u8, at: usize) bool {
    if (at >= haystack.len) return at == haystack.len;
    return haystack[at] < 0x80 or haystack[at] >= 0xc0;
}

/// Builds every stored row of `p` over `haystack`, innermost first, with their streams;
/// refused before a byte is read where the stored rows would pass the store.
pub fn fill(p: *const Plan, c: *Cache, haystack: []const u8) Error!void {
    try prepare(p, c, haystack);
    var row = p.rows.len;
    while (row > 0) {
        row -= 1;
        if (p.rows[row].slot != null) scanRow(p, c, @intCast(row), haystack);
    }
}

/// The store sized and emptied for `haystack`'s stored rows, before any is built (innermost
/// first, by `scanRow` or a lazy DFA's scan writing `mark`); refused before a byte is read where
/// they would pass it.
pub fn prepare(p: *const Plan, c: *Cache, haystack: []const u8) Error!void {
    const positions = haystack.len + 1;
    const stride = positions / @bitSizeOf(usize) + @intFromBool(positions % @bitSizeOf(usize) != 0);
    if (p.stored > 0 and (std.math.mul(usize, stride, p.stored) catch return error.HaystackTooLong) > c.bits.len) return error.HaystackTooLong;
    c.stride = stride;
    c.positions = positions;
    c.visited = 0;
    // The main expression's streams start afresh over a new haystack.
    c.runner_next = std.math.maxInt(usize);
    c.begin(p, 0);
    @memset(c.bits[0 .. stride * p.stored], 0);
}

/// One stored row: the scan of its automaton, with every lookaround streamed in it as a lane
/// before it, writing a 1 at every position it accepts.
pub fn scanRow(p: *const Plan, c: *Cache, row: u32, haystack: []const u8) void {
    _ = scanLanes(p, c, .{ .row = row }, p.rows[row].scan, haystack);
}

/// What a scan is for: a stored row, written at every accept, or the main expression, whose
/// first accept ends the scan.
const Target = union(enum) { row: u32, main: struct { nfa: *const Nfa, splits: bool } };

/// A scan of `target`'s automaton, read the way `scan` says, with each lookaround streamed in it
/// as a lane before it. For the main expression, whether it accepted anywhere.
fn scanLanes(p: *const Plan, c: *Cache, target: Target, scan: Scan, haystack: []const u8) bool {
    // Lanes deepest first: a higher number is never an ancestor of a lower one. The main lane is
    // number `p.rows.len`.
    const of: ?u32 = switch (target) {
        .row => |r| r,
        .main => null,
    };
    const self: u32 = switch (target) {
        .row => |r| r,
        .main => @intCast(p.rows.len),
    };
    var count: usize = 0;
    var k = p.rows.len;
    const lowest: usize = if (of) |r| r + 1 else 0;
    while (k > lowest) {
        k -= 1;
        if (p.streamedIn(@intCast(k), of)) {
            c.order[count] = @intCast(k);
            count += 1;
        }
    }
    c.order[count] = self;
    count += 1;
    const lanes = c.order[0..count];
    const visited_before = c.visited;
    for (lanes) |l| c.lanes[l].seeds.len = 0;
    const n = haystack.len;
    var states: usize = 0;
    for (lanes) |l| states += laneNfa(p, target, l).states.len;
    var step: usize = 0;
    while (step <= n) : (step += 1) {
        // Forward the positions go up from 0; backward down from the end.
        const at = if (scan == .forward) step else n - step;
        for (lanes) |l| {
            const nfa = laneNfa(p, target, l);
            aegis.assert.invariant(!nfa.loop_checks and (l == self or p.rows[l].scan == scan), "a scan's lanes are strings-only automata read its way");
            const accepted = closeLane(p, c, nfa, &c.lanes[l], haystack, at);
            if (l == self) switch (target) {
                .row => |row| if (accepted) c.set(p.rows[row].slot.?, at),
                .main => |m| if (accepted and (!m.splits or isBoundary(haystack, at))) return true,
            } else c.ring[at & 1].setValue(l, accepted);
        }
        // Each lane reads the byte the scan reads next.
        const unit: ?u8 = switch (scan) {
            .forward => if (at < n) haystack[at] else null,
            .backward => if (at > 0) haystack[at - 1] else null,
        };
        for (lanes) |l| {
            const lane = &c.lanes[l];
            const b = unit orelse {
                lane.seeds.len = 0;
                continue;
            };
            stepLane(c, laneNfa(p, target, l), lane, b);
        }
    }
    if (std.debug.runtime_safety) {
        aegis.assert.invariant(c.visited - visited_before <= 2 * states * (n + 1), "a scan enters each lane's states at most once per position and step");
    }
    return false;
}

fn laneNfa(p: *const Plan, target: Target, lane: u32) *const Nfa {
    if (lane < p.rows.len) return &p.rows[lane].nfa;
    return target.main.nfa;
}

fn stepSparse(nfa: *const Nfa, slice: Nfa.Slice, byte: u8) ?Nfa.StateId {
    for (nfa.transitionsOf(slice)) |t| {
        if (byte < t.lo) return null;
        if (byte <= t.hi) return t.next;
    }
    return null;
}

/// Adds to `into` every state reachable from `from` by epsilon at `at`: each look decided by the
/// haystack there, each `check` by its row, which is built already (it is numbered higher).
fn closure(p: *const Plan, c: *Cache, nfa: *const Nfa, into: *SparseSet, from: Nfa.StateId, haystack: []const u8, at: usize) void {
    var depth: usize = 0;
    c.stack[depth] = from;
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        var id = c.stack[depth];
        while (into.insert(id.raw())) {
            c.visited += 1;
            switch (nfa.state(id)) {
                .byte_range, .sparse, .match, .fail => break,
                .look => |l| {
                    if (!look_zig.holds(l.look, haystack, at)) break;
                    id = l.next;
                },
                .check => |k| {
                    aegis.assert.invariant(k.row < p.rows.len, "a check reads a row of the plan");
                    if (c.truth(p, k.row, at) == k.negated) break;
                    id = k.next;
                },
                .binary => |b| {
                    push(c, &depth, b.second);
                    id = b.first;
                },
                .alternation => |slice| {
                    const alts = nfa.alternativesOf(slice);
                    var j = alts.len;
                    while (j > 1) {
                        j -= 1;
                        push(c, &depth, alts[j]);
                    }
                    id = alts[0];
                },
                .capture => |cap| id = cap.next,
                .clear => |cl| id = cl.next,
                .loop_begin, .loop_end => aegis.assert.never("a row's automaton has no empty checks"),
            }
        }
    }
}

fn push(c: *Cache, depth: *usize, id: Nfa.StateId) void {
    aegis.assert.invariant(depth.* < c.stack.len, "a closure pushes at most once per state and alternative");
    c.stack[depth.*] = id;
    depth.* += 1;
}
