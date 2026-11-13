//! The stepping automaton: a pattern's (or a set's) forward lazy DFA, one byte at a time, for a
//! caller that walks its own structure (a trie of terms, the components of a path) and asks at
//! each point whether the bytes so far match and whether any longer string could.
//!
//! It is the all kind: no thread is dropped at a match, so after "a" the pattern `a|ab` still
//! reaches "ab" (leftmost-first would have dropped it). A state's match is seen one byte late,
//! as the searches see it: `isMatch(state)` says a match ended where the last byte stepped
//! began; whether the bytes so far match is `isMatch(stepEnd(state))`, the transition at the end
//! of a haystack, where `$`, `\z` and `\b` at the end are decided. A walker keeps stepping from
//! `state`, not from the end state.
//!
//! States live in the caller's `Cache`, a fixed store cleared when full, as the searches' are.
//! Each `State` carries the store's clear count, so one built before a clear is refused
//! (`error.Stale`), never read; and after three clears with fewer than ten bytes stepped per state
//! built since, a step gives up (`error.GaveUp`).
//!
//! What a walker does on them, so its answers stay the unbounded store's:
//! 1. On `Stale`, re-walk the path (the bytes from the walk's root to where it stands) from
//!    `start` into the same cache, and go on from the state that gives. Count the bytes the
//!    re-walks read: while they stay within ten times the bytes the walk itself stepped, the walk
//!    costs at most eleven times its steps. A re-walk that is itself `Stale`, or a count past ten
//!    times, means the walk does not fit the store: go to 2.
//! 2. On `GaveUp` (or from 1), answer with the whole-string searches. "The bytes so far match" is
//!    `find(cache, .{ .haystack = path, .span = .{ .start = 0, .end = path.len }, .whole = true })`
//!    not null, or for a set `matches` with that input, which says which patterns. `isDead` has no
//!    search twin: stop pruning and treat every state as live, which changes no answer, only the
//!    work saved. Each search is linear in the path.
const Automaton = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Nfa = @import("Nfa.zig");
const lazy = @import("lazy.zig");

nfa: *const Nfa,
dfa: *const lazy.Dfa,

pub const StepError = error{
    /// The store cleared too often for the bytes stepped: answer by the searches (the recipe).
    GaveUp,
    /// The state was built before the store's last clear: re-walk from `start` (the recipe).
    Stale,
};

/// Where a walk starts: anchored (a match must start there) or not, and the byte before it for
/// the looks (null at a text's start).
pub const Start = struct {
    anchored: bool = true,
    before: ?u8 = null,
};

/// A state of the walk: which, in which store generation, and what it holds.
pub const State = struct {
    id: u32,
    generation: u32,
    match: bool,
    dead: bool,
};

/// The store states live in, allocated once, for one walker at a time.
pub const Cache = struct {
    lazy: lazy.Cache,
    /// The automaton it was made for.
    dfa: *const lazy.Dfa,

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.lazy.deinit(gpa);
        c.* = undefined;
    }

    /// Clears since the cache was made: a state of an older generation is stale.
    pub fn generation(c: *const Cache) u32 {
        return c.lazy.clears;
    }
};

/// The automaton over `nfa` and its lazy DFA of the all kind; null where that DFA has quit bytes
/// (a Unicode word boundary reads more than one byte, which a step cannot).
pub fn of(nfa: *const Nfa, dfa: *const lazy.Dfa) ?Automaton {
    aegis.assert.invariant(dfa.direction == .forward and dfa.kind == .all, "the stepping automaton is a forward lazy DFA of the all kind");
    if (dfa.quit != null) return null;
    return .{ .nfa = nfa, .dfa = dfa };
}

pub fn cache(a: Automaton, gpa: Allocator) Allocator.Error!Cache {
    return .{ .lazy = try .init(gpa, a.dfa), .dfa = a.dfa };
}

pub fn start(a: Automaton, c: *Cache, at: Start) StepError!State {
    a.check(c);
    const id = lazy.stepStart(a.nfa, a.dfa, &c.lazy, at.before, at.anchored) catch return error.GaveUp;
    return stateOf(c, id);
}

/// The state after `state` reads `byte`.
pub fn step(a: Automaton, c: *Cache, state: State, byte: u8) StepError!State {
    a.check(c);
    if (state.generation != c.generation()) return error.Stale;
    const id = lazy.stepByte(a.nfa, a.dfa, &c.lazy, state.id, byte) catch return error.GaveUp;
    return stateOf(c, id);
}

/// The state after `state` at the end of a haystack: `isMatch` on it says whether the bytes
/// stepped match.
pub fn stepEnd(a: Automaton, c: *Cache, state: State) StepError!State {
    a.check(c);
    if (state.generation != c.generation()) return error.Stale;
    const id = lazy.stepEnd(a.nfa, a.dfa, &c.lazy, state.id) catch return error.GaveUp;
    return stateOf(c, id);
}

/// A match ended where the last byte stepped began, or at the end after `stepEnd`.
pub fn isMatch(state: State) bool {
    return state.match;
}

/// No further byte leads to a match beyond those `state` holds: a walker prunes here.
pub fn isDead(state: State) bool {
    return state.dead;
}

/// Which patterns' matches `state` holds, ascending: a set's indexes, or 0 for a pattern.
/// `state` is of the cache's current generation.
pub fn patterns(a: Automaton, c: *const Cache, state: State) []const u32 {
    a.check(c);
    aegis.assert.invariant(state.generation == c.generation(), "a state is read in the generation that built it");
    return c.lazy.patternsOf(state.id);
}

fn stateOf(c: *const Cache, id: u32) State {
    return .{ .id = id, .generation = c.generation(), .match = lazy.matchOf(&c.lazy, id), .dead = lazy.deadOf(&c.lazy, id) };
}

fn check(a: Automaton, c: *const Cache) void {
    aegis.assert.invariant(c.dfa == a.dfa, "a cache steps the automaton it was made for");
}
