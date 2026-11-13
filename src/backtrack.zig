//! The bounded backtracker, regex-automata's: the automaton's alternatives tried depth first in
//! order of preference, so the first match reached is the leftmost-first one, with its captures,
//! and each (state, position) explored at most once, so a search is linear: a bit per state and
//! position, set when first explored, ends every later path through it. A path that failed from
//! one start fails from every later one (where it goes depends on the state and position alone),
//! so the bits are kept across starts.
//!
//! The bits bound what it searches: a span of `Sizes.longest` bytes or fewer. Faster than the
//! PikeVM there (one path at a time, no thread sets), it takes the short searches, the match a
//! lazy DFA found among them; the PikeVM takes the rest. With ECMAScript's empty checks a path
//! carries its bit (pikevm.zig), and a (state, bit, position) is what is explored once.
//!
//! Its stack is fixed too: the paths not yet tried, and the captures to put back. A search that
//! would push past it stops with `error.Deep`, and the caller asks the PikeVM, so neither memory
//! nor work outgrows what `Limits.backtrack` says. The stack fills where many alternatives wait
//! at once, one per byte of a long loop (`(a)*` over a run of a's) among them.
//!
//! A search allocates nothing: what it needs is the `Cache`, sized once.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Nfa = @import("Nfa.zig");
const look = @import("nfa/look.zig");
const pikevm = @import("pikevm.zig");

pub const Span = pikevm.Span;
pub const Input = pikevm.Input;

pub const Error = error{
    /// The paths waiting outgrew the stack.
    Deep,
};

const Job = union(enum) {
    explore: struct { id: Nfa.StateId, read: bool, at: usize },
    restore: struct { slot: u32, value: ?usize },
};

/// What a cache of `budget` bytes holds: three quarters bits, one quarter stack.
pub const Sizes = struct {
    words: usize,
    stack: usize,
    /// States times lanes: the bits one position takes.
    threads: usize,

    pub fn bytes(s: Sizes) usize {
        return s.words * @sizeOf(usize) + s.stack * @sizeOf(Job);
    }

    /// The longest span it searches, or null where the bits hold no position.
    pub fn longest(s: Sizes) ?usize {
        const positions = s.words * @bitSizeOf(usize) / s.threads;
        if (positions == 0 or s.stack == 0) return null;
        return positions - 1;
    }
};

pub fn sizes(nfa: *const Nfa, budget: usize) Sizes {
    return .{
        .words = budget / 4 * 3 / @sizeOf(usize),
        .stack = budget / 4 / @sizeOf(Job),
        .threads = nfa.states.len * pikevm.lanes(nfa),
    };
}

pub const Cache = struct {
    visited: []usize,
    stack: []Job,
    threads: usize,
    /// The last search's work: (state, bit, position) explored, over every start.
    explored: usize = 0,

    /// Allocates what `size.bytes()` counts, which `Limits.cache` has bounded at compile.
    pub fn init(gpa: Allocator, size: Sizes) Allocator.Error!Cache {
        const visited = try gpa.alloc(usize, size.words);
        errdefer gpa.free(visited);
        return .{ .visited = visited, .stack = try gpa.alloc(Job, size.stack), .threads = size.threads };
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.visited);
        gpa.free(c.stack);
        c.* = undefined;
    }

    fn push(c: *Cache, depth: *usize, job: Job) Error!void {
        if (depth.* == c.stack.len) return error.Deep;
        c.stack[depth.*] = job;
        depth.* += 1;
    }
};

/// The leftmost-first match in `input`: where it ends, with as many slots as `slots` holds
/// written, as the PikeVM's `search`. In UTF-8 an empty match that would split a code point is
/// passed over for the next one. The span is at most `Sizes.longest` bytes: the caller's
/// contract.
pub fn search(nfa: *const Nfa, c: *Cache, input: Input, slots: []?usize) Error!?usize {
    aegis.assert.invariant(c.threads == nfa.states.len * pikevm.lanes(nfa), "a cache searches the automaton it was made for");
    aegis.assert.invariant(input.span.start <= input.span.end and input.span.end <= input.haystack.len, "a span lies in its haystack");
    aegis.assert.invariant((input.span.len() + 1) * c.threads <= c.visited.len * @bitSizeOf(usize), "a span is no longer than the bits hold");
    c.explored = 0;
    var end = try searchOnce(nfa, c, input, slots) orelse return null;
    if (!(nfa.utf8 and nfa.empty_ok)) return end;
    var again = input;
    while (!pikevm.isBoundary(input.haystack, end)) {
        if (input.anchored) return null;
        again.span.start += 1;
        end = try searchOnce(nfa, c, again, slots) orelse return null;
    }
    return end;
}

fn searchOnce(nfa: *const Nfa, c: *Cache, input: Input, slots: []?usize) Error!?usize {
    if (input.span.start > input.span.end) return null;
    const width = input.span.len() + 1;
    @memset(c.visited[0 .. std.math.divCeil(usize, c.threads * width, @bitSizeOf(usize)) catch unreachable], 0);
    // A failed start puts back every slot it wrote: they stay empty between starts.
    @memset(slots, null);
    const anchored = input.anchored or nfa.start_anchored == nfa.start_unanchored;
    var start = input.span.start;
    while (true) : (start += 1) {
        if (try from(nfa, c, input, width, start, slots)) |end| return end;
        if (anchored or start == input.span.end) return null;
    }
}

/// Every path from the anchored start at `start`, in order, until one reaches the match.
fn from(nfa: *const Nfa, c: *Cache, input: Input, width: usize, start: usize, slots: []?usize) Error!?usize {
    const lanes = pikevm.lanes(nfa);
    const h = input.haystack;
    var depth: usize = 0;
    try c.push(&depth, .{ .explore = .{ .id = nfa.start_anchored, .read = true, .at = start } });
    while (depth > 0) {
        depth -= 1;
        switch (c.stack[depth]) {
            .restore => |back| slots[back.slot] = back.value,
            .explore => |e| {
                var id = e.id;
                var pos = e.at;
                var read = e.read;
                while (true) {
                    const lane: usize = if (lanes == 2) @intFromBool(read) else 0;
                    const bit = (id.raw() * lanes + lane) * width + (pos - input.span.start);
                    const word = &c.visited[bit / @bitSizeOf(usize)];
                    const mask = @as(usize, 1) << @intCast(bit % @bitSizeOf(usize));
                    if (word.* & mask != 0) break;
                    word.* |= mask;
                    c.explored += 1;
                    switch (nfa.state(id)) {
                        .byte_range => |t| {
                            if (pos == input.span.end or !t.contains(h[pos])) break;
                            id = t.next;
                            pos += 1;
                            read = true;
                        },
                        .sparse => |slice| {
                            if (pos == input.span.end) break;
                            id = stepSparse(nfa, slice, h[pos]) orelse break;
                            pos += 1;
                            read = true;
                        },
                        .look => |l| {
                            if (!look.holds(l.look, h, pos)) break;
                            id = l.next;
                        },
                        .binary => |b| {
                            try c.push(&depth, .{ .explore = .{ .id = b.second, .read = read, .at = pos } });
                            id = b.first;
                        },
                        .alternation => |slice| {
                            const alts = nfa.alternativesOf(slice);
                            var k = alts.len;
                            while (k > 1) {
                                k -= 1;
                                try c.push(&depth, .{ .explore = .{ .id = alts[k], .read = read, .at = pos } });
                            }
                            id = alts[0];
                        },
                        .capture => |cap| {
                            if (cap.slot < slots.len) {
                                try c.push(&depth, .{ .restore = .{ .slot = cap.slot, .value = slots[cap.slot] } });
                                slots[cap.slot] = pos;
                            }
                            id = cap.next;
                        },
                        .clear => |cl| {
                            var slot = cl.first;
                            while (slot < @min(cl.end, slots.len)) : (slot += 1) {
                                if (slots[slot] == null) continue;
                                try c.push(&depth, .{ .restore = .{ .slot = slot, .value = slots[slot] } });
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
                        .check => aegis.assert.never("the backtracker is given no automaton with lookaround"),
                        .fail => break,
                        .match => return pos,
                    }
                }
            },
        }
    }
    return null;
}

fn stepSparse(nfa: *const Nfa, slice: Nfa.Slice, byte: u8) ?Nfa.StateId {
    for (nfa.transitionsOf(slice)) |t| {
        if (byte < t.lo) return null;
        if (byte <= t.hi) return t.next;
    }
    return null;
}
