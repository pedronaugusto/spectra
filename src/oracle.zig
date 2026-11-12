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
//! A lookaround inside a body is a `check` state there, answered by its own row, built first:
//! rows are built innermost first, which is from the highest number down (lookarounds are
//! numbered in preorder). Each scan enters each automaton state at most once per position, so a
//! row costs O(‖body‖·n), its body's states without the bodies inside it, and all the rows
//! together O(|r|·n). The rows hold one bit per row per position, in a store sized once
//! (`Cache.init`): a haystack whose rows would pass it is refused before a byte is read
//! (`error.HaystackTooLong`), never built in pieces.
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

/// A lookaround's row automaton and how it is scanned.
pub const Row = struct {
    scan: Scan,
    nfa: Nfa,
};

/// Every lookaround's row automaton, by its number: worked out once, at compile.
pub const Plan = struct {
    rows: []Row,

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        for (p.rows) |*r| r.nfa.deinit(gpa);
        gpa.free(p.rows);
        p.* = undefined;
    }

    /// The most states of any row automaton: what a scan's sets hold.
    pub fn widest(p: *const Plan) usize {
        var most: usize = 0;
        for (p.rows) |r| most = @max(most, r.nfa.states.len);
        return most;
    }
};

pub const PlanOptions = struct {
    limits: Limits = .{},
    utf8: bool = true,
    span: Ast.Span = .{ .start = 0, .end = 0 },
};

/// Each lookaround's row automaton, from the pattern's HIR. Each is charged to `Limits.nfa` on
/// its own, as a pattern is.
pub fn plan(gpa: Allocator, hir: *const Hir, options: PlanOptions, diagnostic: ?*Diagnostic) compile_mod.Error!Plan {
    const rows = try gpa.alloc(Row, hir.lookarounds);
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
            rows[la.index] = .{ .scan = scan, .nfa = nfa };
            seen.set(la.index);
            made += 1;
        },
        else => {},
    };
    aegis.assert.invariant(made == hir.lookarounds, "every lookaround has a row");
    return .{ .rows = rows };
}

/// The rows of one haystack and the scratch they are built with, allocated once.
pub const Cache = struct {
    /// One bit per row per position: row `i`'s at `i * stride` words.
    bits: []usize,
    /// Words per row for the haystack the rows were last built for.
    stride: usize = 0,
    /// The haystack's positions the rows cover: its length plus one.
    positions: usize = 0,
    curr: SparseSet,
    next: SparseSet,
    stack: []Nfa.StateId,
    /// States entered by the last `fill`, over every row.
    visited: usize = 0,

    /// A store of `capacity` bytes for the rows, and scratch for `p`'s widest automaton.
    pub fn init(gpa: Allocator, p: *const Plan, capacity: usize) Allocator.Error!Cache {
        const widest = p.widest();
        const bits = try gpa.alloc(usize, capacity / @sizeOf(usize));
        errdefer gpa.free(bits);
        var curr: SparseSet = try .init(gpa, widest);
        errdefer curr.deinit(gpa);
        var next: SparseSet = try .init(gpa, widest);
        errdefer next.deinit(gpa);
        var stack_len: usize = 1;
        for (p.rows) |r| stack_len = @max(stack_len, r.nfa.states.len + r.nfa.alternatives.len + 1);
        const stack = try gpa.alloc(Nfa.StateId, stack_len);
        return .{ .bits = bits, .curr = curr, .next = next, .stack = stack };
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.bits);
        c.curr.deinit(gpa);
        c.next.deinit(gpa);
        gpa.free(c.stack);
        c.* = undefined;
    }

    /// Whether row `row` holds at position `at`: the lookaround itself, before any negation.
    pub fn holds(c: *const Cache, row: u32, at: usize) bool {
        aegis.assert.invariant(at < c.positions, "a row is read at a position of its haystack");
        const word = c.bits[row * c.stride + at / @bitSizeOf(usize)];
        return word >> @intCast(at % @bitSizeOf(usize)) & 1 != 0;
    }

    fn set(c: *Cache, row: u32, at: usize) void {
        c.bits[row * c.stride + at / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(at % @bitSizeOf(usize));
    }

    /// The longest haystack whose rows for `p` fit: null where `p` has none.
    pub fn longest(c: *const Cache, p: *const Plan) ?usize {
        if (p.rows.len == 0) return null;
        const words = c.bits.len / p.rows.len;
        return if (words == 0) null else words * @bitSizeOf(usize) - 1;
    }
};

/// Builds every row of `p` over `haystack`, innermost first; refused before a byte is read
/// where the rows would pass the store.
pub fn fill(p: *const Plan, c: *Cache, haystack: []const u8) Error!void {
    const positions = haystack.len + 1;
    const stride = std.math.divCeil(usize, positions, @bitSizeOf(usize)) catch unreachable;
    if (p.rows.len > 0 and (std.math.mul(usize, stride, p.rows.len) catch return error.HaystackTooLong) > c.bits.len) return error.HaystackTooLong;
    c.stride = stride;
    c.positions = positions;
    c.visited = 0;
    @memset(c.bits[0 .. stride * p.rows.len], 0);
    var row = p.rows.len;
    while (row > 0) {
        row -= 1;
        scanRow(p, c, @intCast(row), haystack);
    }
}

/// One row: the scan over its automaton that writes a 1 at every position it accepts.
fn scanRow(p: *const Plan, c: *Cache, row: u32, haystack: []const u8) void {
    const r = &p.rows[row];
    const nfa = &r.nfa;
    aegis.assert.invariant(!nfa.loop_checks, "a row's automaton is a strings-only one");
    const visited_before = c.visited;
    c.curr.len = 0;
    c.next.len = 0;
    const n = haystack.len;
    var curr = &c.curr;
    var next = &c.next;
    var k: usize = 0;
    while (k <= n) : (k += 1) {
        // Forward the positions go up from 0; backward down from the end.
        const at = if (r.scan == .forward) k else n - k;
        // The lazy `.*?` before the body starts a match at every position.
        closure(p, c, nfa, curr, nfa.start_unanchored, haystack, at);
        for (curr.items()) |key| {
            c.visited += 1;
            const id: Nfa.StateId = @fromBackingInt(key);
            const unit: ?u8 = switch (r.scan) {
                .forward => if (at < n) haystack[at] else null,
                .backward => if (at > 0) haystack[at - 1] else null,
            };
            const target: ?Nfa.StateId = switch (nfa.state(id)) {
                .match => {
                    c.set(row, at);
                    continue;
                },
                .byte_range => |t| if (unit) |b| (if (t.contains(b)) t.next else null) else null,
                .sparse => |slice| if (unit) |b| stepSparse(nfa, slice, b) else null,
                else => null,
            };
            if (target) |t| closure(p, c, nfa, next, t, haystack, if (r.scan == .forward) at + 1 else at - 1);
        }
        std.mem.swap(*SparseSet, &curr, &next);
        next.len = 0;
    }
    if (std.debug.runtime_safety) {
        aegis.assert.invariant(c.visited - visited_before <= 2 * nfa.states.len * (n + 1), "a row's scan enters each state at most once per position and step");
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
                    if (c.holds(k.row, at) == k.negated) break;
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
