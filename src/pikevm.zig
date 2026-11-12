//! The PikeVM: the NFA simulated one byte at a time over every thread at once, regex-automata's.
//! Threads are kept in order of preference, so the first to reach the match state is the
//! leftmost-first match, and each carries its capture slots. Each state is entered at most once
//! per position, so a search visits at most (states × positions) states whatever the pattern:
//! counted in every build and checked in safe ones.
//!
//! An automaton with ECMAScript's empty checks (`Nfa.loop_checks`) has threads that are a state
//! and a bit, whether the thread read a byte since its innermost `loop_begin`: two threads at one
//! state with different bits have different futures, so each pair is entered once per position
//! (Barrière and Pit-Claudel's two copies of the automaton, PLDI 2024 §4.1), twice the states.
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
    /// Only a match that covers the span counts: anchored at its start, ending at its end.
    whole: bool = false,

    /// Whether a match must start where the span does.
    pub fn startAnchored(input: Input) bool {
        return input.anchored or input.whole;
    }

    pub fn of(haystack: []const u8) Input {
        return .{ .haystack = haystack, .span = .{ .start = 0, .end = haystack.len } };
    }
};

/// A thread: a state, and with empty checks its bit, as one index (`state × lanes + bit`).
const Key = SparseSet.Key;

const SparseSet = @import("SparseSet.zig");

/// The threads at one position: which, and each one's slots.
const Active = struct {
    set: SparseSet,
    /// `stride` slots per thread, and one row more of absent slots for a thread just started.
    table: []?usize,

    fn init(gpa: Allocator, threads: usize, slots: usize) Allocator.Error!Active {
        var set: SparseSet = try .init(gpa, threads);
        errdefer set.deinit(gpa);
        return .{ .set = set, .table = try gpa.alloc(?usize, (threads + 1) * slots) };
    }

    fn deinit(a: *Active, gpa: Allocator) void {
        a.set.deinit(gpa);
        gpa.free(a.table);
    }

    fn row(a: *Active, stride: usize, key: Key) []?usize {
        return a.table[key * stride ..][0..stride];
    }

    fn absent(a: *Active, stride: usize) []?usize {
        const rows = a.set.dense.len;
        const r = a.table[rows * stride ..][0..stride];
        @memset(r, null);
        return r;
    }
};

const Follow = union(enum) {
    explore: struct { id: Nfa.StateId, read: bool },
    restore: struct { slot: u32, value: ?usize },
};

/// What a `Cache` holds for an automaton, counted: the one figure both the compiler's refusal
/// (`Limits.cache`) and `Cache.init`'s allocations are made from.
pub const Sizes = struct {
    /// Entries of each thread set, and rows of its slot table but the absent row: the states,
    /// twice over with empty checks.
    threads: usize,
    /// Slots per thread.
    slots: usize,
    /// Entries of the closure's stack.
    stack: usize,

    /// The bytes they come to, or null past `usize`.
    pub fn bytes(s: Sizes) ?usize {
        const set = mul(s.threads, SparseSet.bytesPer) orelse return null;
        const table = mul(mul(add(s.threads, 1) orelse return null, s.slots) orelse return null, @sizeOf(?usize)) orelse return null;
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

/// What a `Cache` for `nfa` holds. Within one position each thread is entered once, and pushes
/// at most one restore or alternative per state, or its alternatives past the first; a clear
/// pushes a restore per slot it empties. With empty checks every state is two threads.
pub fn sizes(nfa: *const Nfa) Sizes {
    var cleared: usize = 0;
    for (nfa.states) |s| switch (s) {
        .clear => |cl| cleared += cl.end - cl.first,
        else => {},
    };
    const n = lanes(nfa);
    return .{ .threads = nfa.states.len * n, .slots = nfa.slots(), .stack = (nfa.states.len + nfa.alternatives.len + cleared) * n + 1 };
}

/// Threads per state: two with empty checks, a bit each, else one.
pub fn lanes(nfa: *const Nfa) u32 {
    return if (nfa.loop_checks) 2 else 1;
}

/// A thread's key: its state, and with empty checks its bit.
pub fn keyOf(nfa: *const Nfa, id: Nfa.StateId, read: bool) Key {
    return if (nfa.loop_checks) id.raw() * 2 + @intFromBool(read) else id.raw();
}

pub fn stateOf(nfa: *const Nfa, key: Key) Nfa.StateId {
    return @fromBackingInt(if (nfa.loop_checks) key / 2 else key);
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
    /// The pattern whose match the last search found: 0 but in a set.
    pattern: u32 = 0,

    /// Allocates what `sizes(nfa)` counts, which `Limits.cache` has bounded at compile.
    pub fn init(gpa: Allocator, nfa: *const Nfa) Allocator.Error!Cache {
        const size = sizes(nfa);
        var curr: Active = try .init(gpa, size.threads, size.slots);
        errdefer curr.deinit(gpa);
        var next: Active = try .init(gpa, size.threads, size.slots);
        errdefer next.deinit(gpa);
        const stack = try gpa.alloc(Follow, size.stack);
        errdefer gpa.free(stack);
        const slots = try gpa.alloc(?usize, size.slots);
        return .{ .curr = curr, .next = next, .stack = stack, .slots = slots, .states = nfa.states.len };
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
        if (input.startAnchored()) return null;
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
    const anchored = input.startAnchored() or nfa.start_anchored == nfa.start_unanchored;
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
            closure(nfa, cache, curr, next.absent(stride), input.haystack, at, start, true);
        }
        if (nexts(nfa, cache, curr, next, input, at, slots)) found = at;
        if (input.earliest and found != null) break;
        std.mem.swap(*Active, &curr, &next);
        next.set.len = 0;
    }
    if (std.debug.runtime_safety) {
        const positions = input.span.end - input.span.start + 1;
        aegis.assert.invariant(cache.visited - visited_before <= 2 * nfa.states.len * lanes(nfa) * positions, "a search enters each thread at most once per position and step");
    }
    return found;
}

/// Steps every thread over the byte at `at`, in order, into `next`: the first to reach the
/// match state wins, and every thread after it is dropped.
fn nexts(nfa: *const Nfa, cache: *Cache, curr: *Active, next: *Active, input: Input, at: usize, slots: []?usize) bool {
    const stride = slots.len;
    for (curr.set.items()) |key| {
        cache.visited += 1;
        const id = stateOf(nfa, key);
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
            .match => |pattern| {
                // Short of the span's end, a whole match is no match, and the threads after
                // this one go on.
                if (input.whole and at != input.span.end) continue;
                @memcpy(slots, curr.row(stride, key));
                cache.pattern = pattern;
                return true;
            },
            else => null,
        };
        // A thread that read a byte has read one since its innermost `loop_begin`.
        if (target) |t| closure(nfa, cache, next, curr.row(stride, key), input.haystack, at + 1, t, true);
    }
    return false;
}

/// Every pattern with a match in `input`, each pattern's matches on their own (the all kind:
/// no thread is dropped at a match), as bits of `out` set: how many patterns were new. The scan
/// goes to the span's end, or until every pattern has matched. Each thread is entered at most
/// once per position, as in `search`. In UTF-8, where a match may be empty, one that ends
/// inside a code point's encoding is not counted, as `search` passes it over.
pub fn searchAll(nfa: *const Nfa, cache: *Cache, input: Input, out: *std.DynamicBitSetUnmanaged) usize {
    aegis.assert.invariant(cache.states == nfa.states.len, "a cache searches the automaton it was made for");
    aegis.assert.invariant(out.bit_length == nfa.patterns, "a pattern set holds a bit per pattern");
    aegis.assert.invariant(input.span.start <= input.span.end and input.span.end <= input.haystack.len, "a span lies in its haystack");
    cache.visited = 0;
    const anchored = input.startAnchored() or nfa.start_anchored == nfa.start_unanchored;
    var curr = &cache.curr;
    var next = &cache.next;
    curr.set.len = 0;
    next.set.len = 0;
    var found: usize = 0;
    var have = out.count();
    var at = input.span.start;
    while (at <= input.span.end and have < nfa.patterns) : (at += 1) {
        if (curr.set.len == 0 and anchored and at > input.span.start) break;
        if (!anchored or at == input.span.start) closure(nfa, cache, curr, next.absent(0), input.haystack, at, nfa.start_anchored, true);
        for (curr.set.items()) |key| {
            cache.visited += 1;
            const id = stateOf(nfa, key);
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
                .match => |pattern| blk: {
                    if (input.whole and at != input.span.end) break :blk null;
                    // regex-automata's rule, as `search` keeps it: where a match may be empty,
                    // one ending inside a code point's encoding is not counted.
                    if (nfa.utf8 and nfa.empty_ok and !isBoundary(input.haystack, at)) break :blk null;
                    if (!out.isSet(pattern)) {
                        out.set(pattern);
                        found += 1;
                        have += 1;
                    }
                    break :blk null;
                },
                else => null,
            };
            if (target) |t| closure(nfa, cache, next, next.absent(0), input.haystack, at + 1, t, true);
        }
        std.mem.swap(*Active, &curr, &next);
        next.set.len = 0;
    }
    if (std.debug.runtime_safety) {
        const positions = input.span.end - input.span.start + 1;
        aegis.assert.invariant(cache.visited <= 2 * nfa.states.len * lanes(nfa) * positions, "a search enters each thread at most once per position and step");
    }
    return found;
}

/// Adds to `into` every thread reachable from `from` by epsilon at `at`, in preference order,
/// each with `slots` as the path to it wrote them. `slots` is put back as it was. `read` is the
/// thread's bit: whether it read a byte since its innermost `loop_begin`.
fn closure(nfa: *const Nfa, cache: *Cache, into: *Active, slots: []?usize, haystack: []const u8, at: usize, from: Nfa.StateId, from_read: bool) void {
    const stride = slots.len;
    var depth: usize = 0;
    cache.stack[depth] = .{ .explore = .{ .id = from, .read = from_read } };
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        switch (cache.stack[depth]) {
            .restore => |r| slots[r.slot] = r.value,
            .explore => |first| {
                var id = first.id;
                var read = first.read;
                while (into.set.insert(keyOf(nfa, id, read))) {
                    cache.visited += 1;
                    switch (nfa.state(id)) {
                        .byte_range, .sparse, .match, .fail => {
                            @memcpy(into.row(stride, keyOf(nfa, id, read)), slots);
                            break;
                        },
                        .look => |l| {
                            if (!look.holds(l.look, haystack, at)) break;
                            id = l.next;
                        },
                        .binary => |b| {
                            push(cache, &depth, .{ .explore = .{ .id = b.second, .read = read } });
                            id = b.first;
                        },
                        .alternation => |slice| {
                            const alts = nfa.alternativesOf(slice);
                            var k = alts.len;
                            while (k > 1) {
                                k -= 1;
                                push(cache, &depth, .{ .explore = .{ .id = alts[k], .read = read } });
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
                        .loop_begin => |next| {
                            read = false;
                            id = next;
                        },
                        // An iteration past the minimum that read nothing fails.
                        .loop_end => |next| {
                            if (!read) break;
                            id = next;
                        },
                        .check => aegis.assert.never("the PikeVM answers lookaround once the main expression's phase is in"),
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
