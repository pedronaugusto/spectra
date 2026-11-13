//! The one-pass DFA, regex-automata's: for a pattern where, from every state, each byte leads
//! one way at most, an anchored search follows a single path and needs no threads and no
//! backtracking, captures included. Each DFA state is an automaton state a byte led to (or the
//! start); its transition on a byte class names the next one and carries what the path between
//! them crossed without reading: the capture slots it wrote and the assertions it passed, all at
//! the position before the byte. A state that reaches the match by such a path says so, with its
//! own slots and assertions.
//!
//! Leftmost-first: within one state's paths, those before the match in preference order are
//! taken over matching there, and a transition found after it is marked `match_wins`: where the
//! match holds, the search stops rather than take it.
//!
//! Built at compile, immutable, in the `Regex`. A pattern is not one-pass, and has none, where
//! one state's paths conflict: two reach one automaton state, or two lead the same byte to
//! different places or with different slots or assertions, or two reach the match. Nor where
//! ECMAScript's iterations clear captures or check for empty ones (their effects are not a
//! path's alone), where it has more than 32 slots, or where the table passes
//! `Limits.onepass`.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Nfa = @import("Nfa.zig");
const look = @import("nfa/look.zig");
const pikevm = @import("pikevm.zig");

pub const Input = pikevm.Input;

/// What a path crossed without reading: the slots it wrote and the assertions it passed.
const Epsilons = struct {
    slots: u32 = 0,
    looks: Nfa.LookSet = .empty,

    fn eql(a: Epsilons, b: Epsilons) bool {
        return a.slots == b.slots and a.looks.eql(b.looks);
    }
};

const none: u32 = std.math.maxInt(u32);

const Transition = struct {
    next: u32 = none,
    /// Found after the match in preference order: where the match holds, it wins.
    match_wins: bool = false,
    epsilons: Epsilons = .{},

    fn eql(a: Transition, b: Transition) bool {
        return a.next == b.next and a.match_wins == b.match_wins and a.epsilons.eql(b.epsilons);
    }
};

pub const Dfa = struct {
    classes: [256]u8,
    stride: u32,
    /// `stride` transitions per state.
    transitions: []Transition,
    /// Each state's way to the match, if it has one.
    matches: []?Epsilons,
    /// An empty match must not split a code point, and some match is empty (`Nfa.utf8`,
    /// `Nfa.empty_ok`): a match ending inside an encoding is no match, anchored as it is.
    utf8_empty: bool,

    pub fn deinit(d: *Dfa, gpa: Allocator) void {
        gpa.free(d.transitions);
        gpa.free(d.matches);
        d.* = undefined;
    }

    pub fn bytes(d: *const Dfa) usize {
        return d.transitions.len * @sizeOf(Transition) + d.matches.len * @sizeOf(?Epsilons);
    }
};

/// The one-pass DFA of `nfa` in at most `limit` bytes, or null where the pattern is not one-pass
/// or the table is larger.
pub fn build(gpa: Allocator, nfa: *const Nfa, limit: usize) Allocator.Error!?Dfa {
    if (nfa.loop_checks or nfa.checks or nfa.slots() > 32) return null;
    for (nfa.states) |s| if (s == .clear) return null;
    var b: Builder = .{ .gpa = gpa, .nfa = nfa, .limit = limit };
    defer b.deinit();
    b.classify();
    return b.run();
}

const Explore = struct { id: Nfa.StateId, epsilons: Epsilons };

const Builder = struct {
    gpa: Allocator,
    nfa: *const Nfa,
    limit: usize,
    classes: [256]u8 = undefined,
    stride: u32 = 0,
    transitions: std.ArrayList(Transition) = .empty,
    matches: std.ArrayList(?Epsilons) = .empty,
    /// Each automaton state's DFA state, `none` until a byte leads to it.
    ids: []u32 = &.{},
    /// The automaton state of each DFA state, in the order they are built.
    sources: std.ArrayList(Nfa.StateId) = .empty,
    seen: std.DynamicBitSetUnmanaged = .{},
    stack: std.ArrayList(Explore) = .empty,

    fn deinit(b: *Builder) void {
        b.transitions.deinit(b.gpa);
        b.matches.deinit(b.gpa);
        b.gpa.free(b.ids);
        b.sources.deinit(b.gpa);
        b.seen.deinit(b.gpa);
        b.stack.deinit(b.gpa);
    }

    /// Byte classes: bytes no transition tells apart.
    fn classify(b: *Builder) void {
        var bounds: std.StaticBitSet(257) = .empty;
        for (b.nfa.states) |s| switch (s) {
            .byte_range => |t| {
                bounds.set(t.lo);
                bounds.set(@as(usize, t.hi) + 1);
            },
            .sparse => |slice| for (b.nfa.transitionsOf(slice)) |t| {
                bounds.set(t.lo);
                bounds.set(@as(usize, t.hi) + 1);
            },
            else => {},
        };
        var class: u32 = 0;
        for (0..256) |byte| {
            if (byte > 0 and bounds.isSet(byte)) class += 1;
            b.classes[byte] = @intCast(class);
        }
        b.stride = class + 1;
    }

    fn run(b: *Builder) Allocator.Error!?Dfa {
        b.ids = try b.gpa.alloc(u32, b.nfa.states.len);
        @memset(b.ids, none);
        b.seen = try .initEmpty(b.gpa, b.nfa.states.len);
        _ = try b.add(b.nfa.start_anchored) orelse return null;
        var i: usize = 0;
        while (i < b.sources.items.len) : (i += 1) {
            if (!try b.compile(@intCast(i))) return null;
        }
        const transitions = try b.transitions.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(transitions);
        return .{ .classes = b.classes, .stride = b.stride, .transitions = transitions, .matches = try b.matches.toOwnedSlice(b.gpa), .utf8_empty = b.nfa.utf8 and b.nfa.empty_ok };
    }

    /// The DFA state of automaton state `id`, made if new; null past the limit.
    fn add(b: *Builder, id: Nfa.StateId) Allocator.Error!?u32 {
        if (b.ids[id.raw()] != none) return b.ids[id.raw()];
        const states = b.sources.items.len + 1;
        if (states * (b.stride * @sizeOf(Transition) + @sizeOf(?Epsilons)) > b.limit) return null;
        const dfa_id: u32 = @intCast(b.sources.items.len);
        try b.sources.append(b.gpa, id);
        try b.transitions.appendNTimes(b.gpa, .{}, b.stride);
        try b.matches.append(b.gpa, null);
        b.ids[id.raw()] = dfa_id;
        return dfa_id;
    }

    /// State `i`'s transitions and match, from every path its automaton state starts; false
    /// where they conflict or the table passes the limit.
    fn compile(b: *Builder, i: u32) Allocator.Error!bool {
        const nfa = b.nfa;
        b.seen.unsetAll();
        b.stack.clearRetainingCapacity();
        try b.stack.append(b.gpa, .{ .id = b.sources.items[i], .epsilons = .{} });
        var matched = false;
        while (b.stack.pop()) |e| {
            var id = e.id;
            var epsilons = e.epsilons;
            while (true) {
                // Two paths to one state: the byte after cannot tell which was taken.
                if (b.seen.isSet(id.raw())) return false;
                b.seen.set(id.raw());
                switch (nfa.state(id)) {
                    .byte_range => |t| {
                        if (!try b.transition(i, t.lo, t.hi, t.next, epsilons, matched)) return false;
                        break;
                    },
                    .sparse => |slice| {
                        for (nfa.transitionsOf(slice)) |t| {
                            if (!try b.transition(i, t.lo, t.hi, t.next, epsilons, matched)) return false;
                        }
                        break;
                    },
                    .match => {
                        if (b.matches.items[i] != null) return false;
                        b.matches.items[i] = epsilons;
                        matched = true;
                        break;
                    },
                    .look => |l| {
                        epsilons.looks.insert(l.look);
                        id = l.next;
                    },
                    .capture => |cap| {
                        epsilons.slots |= @as(u32, 1) << @intCast(cap.slot);
                        id = cap.next;
                    },
                    .binary => |bin| {
                        try b.stack.append(b.gpa, .{ .id = bin.second, .epsilons = epsilons });
                        id = bin.first;
                    },
                    .alternation => |slice| {
                        const alts = nfa.alternativesOf(slice);
                        var k = alts.len;
                        while (k > 1) {
                            k -= 1;
                            try b.stack.append(b.gpa, .{ .id = alts[k], .epsilons = epsilons });
                        }
                        id = alts[0];
                    },
                    .fail => break,
                    .clear, .loop_begin, .loop_end, .check => aegis.assert.never("a one-pass automaton has no clear, no empty check and no lookaround"),
                }
            }
        }
        return true;
    }

    fn transition(b: *Builder, i: u32, lo: u8, hi: u8, target: Nfa.StateId, epsilons: Epsilons, match_wins: bool) Allocator.Error!bool {
        const next = try b.add(target) orelse return false;
        const t: Transition = .{ .next = next, .match_wins = match_wins, .epsilons = epsilons };
        var class = b.classes[lo];
        while (class <= b.classes[hi]) : (class += 1) {
            const slot = &b.transitions.items[@as(usize, i) * b.stride + class];
            if (slot.next != none and !slot.eql(t)) return false;
            slot.* = t;
        }
        return true;
    }
};

fn looksHold(looks: Nfa.LookSet, haystack: []const u8, at: usize) bool {
    var it = looks.iterator();
    while (it.next()) |l| if (!look.holds(l, haystack, at)) return false;
    return true;
}

/// The leftmost-first match starting at `input.span.start`, anchored whatever `input` says:
/// where it ends, with as many slots as `slots` holds written. In UTF-8 a match that would end
/// inside an encoding is none, as the PikeVM's anchored search says.
pub fn search(d: *const Dfa, input: Input, slots: []?usize) ?usize {
    aegis.assert.invariant(input.span.start <= input.span.end and input.span.end <= input.haystack.len, "a span lies in its haystack");
    aegis.assert.invariant(slots.len <= 32, "a one-pass automaton has at most 32 slots");
    const h = input.haystack;
    var work: [32]?usize = @splat(null);
    var state: u32 = 0;
    var at = input.span.start;
    var found: ?usize = null;
    while (true) {
        if (d.matches[state]) |m| if (looksHold(m.looks, h, at)) {
            found = at;
            for (slots, 0..) |*slot, k| slot.* = if (m.slots & (@as(u32, 1) << @intCast(k)) != 0) at else work[k];
        };
        if (at == input.span.end) break;
        const t = d.transitions[@as(usize, state) * d.stride + d.classes[h[at]]];
        if (t.next == none) break;
        if (t.match_wins and found == at) break;
        if (!looksHold(t.epsilons.looks, h, at)) break;
        var bits = t.epsilons.slots;
        while (bits != 0) : (bits &= bits - 1) work[@ctz(bits)] = at;
        state = t.next;
        at += 1;
    }
    if (d.utf8_empty) if (found) |end| if (!pikevm.isBoundary(h, end)) return null;
    return found;
}
