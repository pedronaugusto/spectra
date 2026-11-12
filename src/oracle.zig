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
const Hir = @import("hir/Hir.zig");
const Nfa = @import("nfa/Nfa.zig");
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

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        for (p.rows) |*r| r.nfa.deinit(gpa);
        gpa.free(p.rows);
        p.* = undefined;
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

pub const PlanOptions = struct {
    limits: Limits = .{},
    utf8: bool = true,
    span: Ast.Span = .{ .start = 0, .end = 0 },
    /// The way the main expression's scan reads, which streams the lookarounds it queries
    /// directly that read the same way; null stores them all (no main scan streams).
    main: ?Scan = null,
};

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
    // Streamed where its querying scan reads its way, else stored.
    var stored: u32 = 0;
    for (rows) |*r| {
        const querying: ?Scan = if (r.parent) |up| rows[up].scan else options.main;
        if (querying != r.scan) {
            r.slot = stored;
            stored += 1;
        }
    }
    return .{ .rows = rows, .stored = stored };
}

/// One lane of a scan: a lookaround's automaton, the states the last byte led to (its seeds),
/// and the states closed from them at the position being read.
const Lane = struct {
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
    streams: std.DynamicBitSetUnmanaged,
    /// The lanes of the scan being run, deepest first, the target last.
    order: []u32,
    stack: []Nfa.StateId,
    /// States entered by the last `fill`, over every row.
    visited: usize = 0,

    /// A store of `capacity` bytes for the stored rows, and a lane for each lookaround.
    pub fn init(gpa: Allocator, p: *const Plan, capacity: usize) Allocator.Error!Cache {
        const bits = try gpa.alloc(usize, capacity / @sizeOf(usize));
        errdefer gpa.free(bits);
        const lanes = try gpa.alloc(Lane, p.rows.len);
        var made: usize = 0;
        errdefer {
            for (lanes[0..made]) |*l| {
                l.seeds.deinit(gpa);
                l.closed.deinit(gpa);
            }
            gpa.free(lanes);
        }
        for (lanes, p.rows) |*l, r| {
            var seeds: SparseSet = try .init(gpa, r.nfa.states.len);
            errdefer seeds.deinit(gpa);
            l.* = .{ .seeds = seeds, .closed = try .init(gpa, r.nfa.states.len) };
            made += 1;
        }
        var streams = try std.DynamicBitSetUnmanaged.initEmpty(gpa, p.rows.len);
        errdefer streams.deinit(gpa);
        const order = try gpa.alloc(u32, p.rows.len);
        errdefer gpa.free(order);
        var stack_len: usize = 1;
        for (p.rows) |r| stack_len = @max(stack_len, r.nfa.states.len + r.nfa.alternatives.len + 1);
        const stack = try gpa.alloc(Nfa.StateId, stack_len);
        return .{ .bits = bits, .lanes = lanes, .streams = streams, .order = order, .stack = stack };
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.bits);
        for (c.lanes) |*l| {
            l.seeds.deinit(gpa);
            l.closed.deinit(gpa);
        }
        gpa.free(c.lanes);
        c.streams.deinit(gpa);
        gpa.free(c.order);
        gpa.free(c.stack);
        c.* = undefined;
    }

    /// Whether stored row `slot` holds at position `at`: the lookaround itself, before any
    /// negation.
    pub fn holds(c: *const Cache, slot: u32, at: usize) bool {
        aegis.assert.invariant(at < c.positions, "a row is read at a position of its haystack");
        const word = c.bits[slot * c.stride + at / @bitSizeOf(usize)];
        return word >> @intCast(at % @bitSizeOf(usize)) & 1 != 0;
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
        return if (p.rows[row].slot) |slot| c.holds(slot, at) else c.streams.isSet(row);
    }
};

/// Builds every stored row of `p` over `haystack`, innermost first, with their streams;
/// refused before a byte is read where the stored rows would pass the store.
pub fn fill(p: *const Plan, c: *Cache, haystack: []const u8) Error!void {
    const positions = haystack.len + 1;
    const stride = std.math.divCeil(usize, positions, @bitSizeOf(usize)) catch unreachable;
    if (p.stored > 0 and (std.math.mul(usize, stride, p.stored) catch return error.HaystackTooLong) > c.bits.len) return error.HaystackTooLong;
    c.stride = stride;
    c.positions = positions;
    c.visited = 0;
    @memset(c.bits[0 .. stride * p.stored], 0);
    var row = p.rows.len;
    while (row > 0) {
        row -= 1;
        if (p.rows[row].slot != null) scanRow(p, c, @intCast(row), haystack);
    }
}

/// One stored row: the scan of its automaton, with every lookaround streamed in it as a lane
/// before it, writing a 1 at every position it accepts.
fn scanRow(p: *const Plan, c: *Cache, row: u32, haystack: []const u8) void {
    // Lanes deepest first: a higher number is never an ancestor of a lower one.
    var count: usize = 0;
    var k = p.rows.len;
    while (k > row + 1) {
        k -= 1;
        if (p.streamedIn(@intCast(k), row)) {
            c.order[count] = @intCast(k);
            count += 1;
        }
    }
    c.order[count] = row;
    count += 1;
    const lanes = c.order[0..count];
    const scan = p.rows[row].scan;
    const visited_before = c.visited;
    for (lanes) |l| c.lanes[l].seeds.len = 0;
    const n = haystack.len;
    var states: usize = 0;
    for (lanes) |l| states += p.rows[l].nfa.states.len;
    var step: usize = 0;
    while (step <= n) : (step += 1) {
        // Forward the positions go up from 0; backward down from the end.
        const at = if (scan == .forward) step else n - step;
        for (lanes) |l| {
            const nfa = &p.rows[l].nfa;
            aegis.assert.invariant(!nfa.loop_checks and p.rows[l].scan == scan, "a scan's lanes are strings-only automata read its way");
            const lane = &c.lanes[l];
            lane.closed.len = 0;
            // The lazy `.*?` before the body starts a match at every position.
            closure(p, c, nfa, &lane.closed, nfa.start_unanchored, haystack, at);
            for (lane.seeds.items()) |seed| closure(p, c, nfa, &lane.closed, @fromBackingInt(seed), haystack, at);
            var accepted = false;
            for (lane.closed.items()) |key| {
                if (nfa.state(@fromBackingInt(key)) == .match) accepted = true;
            }
            if (l == row) {
                if (accepted) c.set(p.rows[row].slot.?, at);
            } else c.streams.setValue(l, accepted);
        }
        // Each lane reads the byte the scan reads next.
        const unit: ?u8 = switch (scan) {
            .forward => if (at < n) haystack[at] else null,
            .backward => if (at > 0) haystack[at - 1] else null,
        };
        for (lanes) |l| {
            const nfa = &p.rows[l].nfa;
            const lane = &c.lanes[l];
            lane.seeds.len = 0;
            const b = unit orelse continue;
            for (lane.closed.items()) |key| {
                c.visited += 1;
                const target: ?Nfa.StateId = switch (nfa.state(@fromBackingInt(key))) {
                    .byte_range => |t| if (t.contains(b)) t.next else null,
                    .sparse => |slice| stepSparse(nfa, slice, b),
                    else => null,
                };
                if (target) |t| _ = lane.seeds.insert(t.raw());
            }
        }
    }
    if (std.debug.runtime_safety) {
        aegis.assert.invariant(c.visited - visited_before <= 2 * states * (n + 1), "a scan enters each lane's states at most once per position and step");
    }
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
