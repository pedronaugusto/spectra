//! The PikeVM: the NFA simulated one byte at a time over every thread at once, regex-automata's.
//! Threads are kept in order of preference, so the first to reach the match state is the
//! leftmost-first match, and each carries its capture slots. Each state is entered at most once
//! per position, so a search visits at most (states × positions) states whatever the pattern:
//! counted in every build and checked in safe ones.
//!
//! A search allocates nothing: what it needs is the `Cache`, sized to the automaton once.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Nfa = @import("nfa/Nfa.zig");
const look = @import("nfa/look.zig");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn len(s: Span) usize {
        return s.end - s.start;
    }
};

/// What a search reads: a span of the haystack, and whether a match must start where it does.
/// Assertions see the whole haystack.
pub const Input = struct {
    haystack: []const u8,
    span: Span,
    anchored: bool = false,
    /// Stop at the first match found, which is not then the leftmost-first one's end: whether
    /// any match exists is all it answers.
    earliest: bool = false,

    pub fn of(haystack: []const u8) Input {
        return .{ .haystack = haystack, .span = .{ .start = 0, .end = haystack.len } };
    }
};

const SparseSet = struct {
    dense: []Nfa.StateId,
    sparse: []u32,
    len: u32 = 0,

    fn init(gpa: Allocator, capacity: usize) Allocator.Error!SparseSet {
        const dense = try gpa.alloc(Nfa.StateId, capacity);
        errdefer gpa.free(dense);
        const sparse = try gpa.alloc(u32, capacity);
        @memset(sparse, 0);
        return .{ .dense = dense, .sparse = sparse };
    }

    fn deinit(s: *SparseSet, gpa: Allocator) void {
        gpa.free(s.dense);
        gpa.free(s.sparse);
    }

    /// Adds `id`, and whether it was not there.
    fn insert(s: *SparseSet, id: Nfa.StateId) bool {
        const i = s.sparse[id.raw()];
        if (i < s.len and s.dense[i] == id) return false;
        s.dense[s.len] = id;
        s.sparse[id.raw()] = s.len;
        s.len += 1;
        return true;
    }

    fn items(s: *const SparseSet) []const Nfa.StateId {
        return s.dense[0..s.len];
    }
};

/// The threads at one position: which states, and each one's slots.
const Active = struct {
    set: SparseSet,
    /// `stride` slots per state, and one row more of absent slots for a thread just started.
    table: []?usize,

    fn init(gpa: Allocator, states: usize, slots: usize) Allocator.Error!Active {
        var set: SparseSet = try .init(gpa, states);
        errdefer set.deinit(gpa);
        return .{ .set = set, .table = try gpa.alloc(?usize, (states + 1) * slots) };
    }

    fn deinit(a: *Active, gpa: Allocator) void {
        a.set.deinit(gpa);
        gpa.free(a.table);
    }

    fn row(a: *Active, stride: usize, id: Nfa.StateId) []?usize {
        return a.table[id.raw() * stride ..][0..stride];
    }

    fn absent(a: *Active, stride: usize) []?usize {
        const rows = a.set.dense.len;
        const r = a.table[rows * stride ..][0..stride];
        @memset(r, null);
        return r;
    }
};

const Follow = union(enum) {
    explore: Nfa.StateId,
    restore: struct { slot: u32, value: ?usize },
};

/// What a `Cache` holds for an automaton, counted: the one figure both the compiler's refusal
/// (`Limits.cache`) and `Cache.init`'s allocations are made from.
pub const Sizes = struct {
    /// Entries of each thread set, and rows of its slot table but the absent row.
    states: usize,
    /// Slots per thread.
    slots: usize,
    /// Entries of the closure's stack.
    stack: usize,

    /// The bytes they come to, or null past `usize`.
    pub fn bytes(s: Sizes) ?usize {
        const set = mul(s.states, @sizeOf(Nfa.StateId) + @sizeOf(u32)) orelse return null;
        const table = mul(mul(add(s.states, 1) orelse return null, s.slots) orelse return null, @sizeOf(?usize)) orelse return null;
        const active = add(set, table) orelse return null;
        const both = mul(active, 2) orelse return null;
        const stack = mul(s.stack, @sizeOf(Follow)) orelse return null;
        const slots = mul(s.slots, @sizeOf(?usize)) orelse return null;
        return add(add(both, stack) orelse return null, slots);
    }

    fn mul(x: usize, y: usize) ?usize {
        return std.math.mul(usize, x, y) catch null;
    }

    fn add(x: usize, y: usize) ?usize {
        return std.math.add(usize, x, y) catch null;
    }
};

/// What a `Cache` for `nfa` holds. Within one position each state is entered once, and pushes
/// at most one restore or alternative per state, or its alternatives past the first; a clear
/// pushes a restore per slot it empties.
pub fn sizes(nfa: *const Nfa) Sizes {
    var cleared: usize = 0;
    for (nfa.states) |s| switch (s) {
        .clear => |cl| cleared += cl.end - cl.first,
        else => {},
    };
    return .{ .states = nfa.states.len, .slots = nfa.slots(), .stack = nfa.states.len + nfa.alternatives.len + cleared + 1 };
}

/// What one automaton's searches need, made once: no search allocates.
pub const Cache = struct {
    curr: Active,
    next: Active,
    stack: []Follow,
    /// Every slot of the automaton, for a search that wants them all.
    slots: []?usize,
    /// The automaton it was made for, by its states: a cache of another is refused.
    states: usize,
    /// States entered by the last search, summed over its positions.
    visited: usize = 0,

    /// Allocates what `sizes(nfa)` counts, which `Limits.cache` has bounded at compile.
    pub fn init(gpa: Allocator, nfa: *const Nfa) Allocator.Error!Cache {
        const size = sizes(nfa);
        var curr: Active = try .init(gpa, size.states, size.slots);
        errdefer curr.deinit(gpa);
        var next: Active = try .init(gpa, size.states, size.slots);
        errdefer next.deinit(gpa);
        const stack = try gpa.alloc(Follow, size.stack);
        errdefer gpa.free(stack);
        const slots = try gpa.alloc(?usize, size.slots);
        return .{ .curr = curr, .next = next, .stack = stack, .slots = slots, .states = size.states };
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.curr.deinit(gpa);
        c.next.deinit(gpa);
        gpa.free(c.stack);
        gpa.free(c.slots);
        c.* = undefined;
    }
};

/// The leftmost-first match in `input`: where it ends, with as many slots as `slots` holds
/// written (group `g`'s start and end at `2g` and `2g+1`, null where it took no part). In UTF-8,
/// an empty match that would split a code point is passed over for the next one.
pub fn search(nfa: *const Nfa, cache: *Cache, input: Input, slots: []?usize) ?usize {
    aegis.assert.invariant(cache.states == nfa.states.len, "a cache searches the automaton it was made for");
    aegis.assert.invariant(slots.len <= nfa.slots(), "a search writes the slots the automaton has");
    aegis.assert.invariant(input.span.start <= input.span.end and input.span.end <= input.haystack.len, "a span lies in its haystack");
    cache.visited = 0;
    var end = searchOnce(nfa, cache, input, slots) orelse return null;
    if (!(nfa.utf8 and nfa.empty_ok)) return end;
    // regex-automata's `skip_splits_fwd`: an anchored search has no later match to take.
    var again = input;
    while (!isBoundary(input.haystack, end)) {
        if (input.anchored) return null;
        again.span.start += 1;
        end = searchOnce(nfa, cache, again, slots) orelse return null;
    }
    return end;
}

/// Whether `at` begins a code point's encoding, or is the haystack's end.
pub fn isBoundary(haystack: []const u8, at: usize) bool {
    if (at >= haystack.len) return at == haystack.len;
    return haystack[at] < 0x80 or haystack[at] >= 0xc0;
}

fn searchOnce(nfa: *const Nfa, cache: *Cache, input: Input, slots: []?usize) ?usize {
    if (input.span.start > input.span.end) return null;
    const stride = slots.len;
    const start = nfa.start_anchored;
    const anchored = input.anchored or nfa.start_anchored == nfa.start_unanchored;
    var curr = &cache.curr;
    var next = &cache.next;
    curr.set.len = 0;
    next.set.len = 0;
    var found: ?usize = null;
    var at = input.span.start;
    const visited_before = cache.visited;
    while (at <= input.span.end) : (at += 1) {
        if (curr.set.len == 0) {
            if (found != null) break;
            if (anchored and at > input.span.start) break;
        }
        // A thread started here comes after every thread started before: leftmost first.
        if (found == null and (!anchored or at == input.span.start)) {
            closure(nfa, cache, curr, next.absent(stride), input.haystack, at, start);
        }
        if (nexts(nfa, cache, curr, next, input, at, slots)) found = at;
        if (input.earliest and found != null) break;
        std.mem.swap(*Active, &curr, &next);
        next.set.len = 0;
    }
    if (std.debug.runtime_safety) {
        const positions = input.span.end - input.span.start + 1;
        aegis.assert.invariant(cache.visited - visited_before <= 2 * nfa.states.len * positions, "a search enters each state at most once per position and step");
    }
    return found;
}

/// Steps every thread over the byte at `at`, in order, into `next`: the first to reach the
/// match state wins, and every thread after it is dropped.
fn nexts(nfa: *const Nfa, cache: *Cache, curr: *Active, next: *Active, input: Input, at: usize, slots: []?usize) bool {
    const stride = slots.len;
    for (curr.set.items()) |id| {
        cache.visited += 1;
        const target: ?Nfa.StateId = switch (nfa.state(id)) {
            .byte_range => |t| if (at < input.span.end and t.contains(input.haystack[at])) t.next else null,
            .sparse => |slice| blk: {
                if (at >= input.span.end) break :blk null;
                const byte = input.haystack[at];
                for (nfa.transitionsOf(slice)) |t| {
                    if (byte < t.lo) break :blk null;
                    if (byte <= t.hi) break :blk t.next;
                }
                break :blk null;
            },
            .match => {
                @memcpy(slots, curr.row(stride, id));
                return true;
            },
            else => null,
        };
        if (target) |t| closure(nfa, cache, next, curr.row(stride, id), input.haystack, at + 1, t);
    }
    return false;
}

/// Adds to `into` every state reachable from `from` by epsilon at `at`, in preference order,
/// each with `slots` as the path to it wrote them. `slots` is put back as it was.
fn closure(nfa: *const Nfa, cache: *Cache, into: *Active, slots: []?usize, haystack: []const u8, at: usize, from: Nfa.StateId) void {
    const stride = slots.len;
    var depth: usize = 0;
    cache.stack[depth] = .{ .explore = from };
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        switch (cache.stack[depth]) {
            .restore => |r| slots[r.slot] = r.value,
            .explore => |first| {
                var id = first;
                while (into.set.insert(id)) {
                    cache.visited += 1;
                    switch (nfa.state(id)) {
                        .byte_range, .sparse, .match, .fail => {
                            @memcpy(into.row(stride, id), slots);
                            break;
                        },
                        .look => |l| {
                            if (!look.holds(l.look, haystack, at)) break;
                            id = l.next;
                        },
                        .binary => |b| {
                            push(cache, &depth, .{ .explore = b.second });
                            id = b.first;
                        },
                        .alternation => |slice| {
                            const alts = nfa.alternativesOf(slice);
                            var k = alts.len;
                            while (k > 1) {
                                k -= 1;
                                push(cache, &depth, .{ .explore = alts[k] });
                            }
                            id = alts[0];
                        },
                        .capture => |cap| {
                            if (cap.slot < stride) {
                                push(cache, &depth, .{ .restore = .{ .slot = cap.slot, .value = slots[cap.slot] } });
                                slots[cap.slot] = at;
                            }
                            id = cap.next;
                        },
                        .clear => |cl| {
                            var slot = cl.first;
                            while (slot < @min(cl.end, stride)) : (slot += 1) {
                                if (slots[slot] == null) continue;
                                push(cache, &depth, .{ .restore = .{ .slot = slot, .value = slots[slot] } });
                                slots[slot] = null;
                            }
                            id = cl.next;
                        },
                    }
                }
            },
        }
    }
}

fn push(cache: *Cache, depth: *usize, follow: Follow) void {
    aegis.assert.invariant(depth.* < cache.stack.len, "a closure pushes at most once per state and alternative");
    cache.stack[depth.*] = follow;
    depth.* += 1;
}
