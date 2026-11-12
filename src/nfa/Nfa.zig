//! A Thompson NFA over bytes, regex-automata's: states that read one byte of a range, epsilon
//! states (alternatives in order of preference, look assertions, capture slots), and the match.
//! Every engine reads this one automaton. A UTF-8 class is a byte automaton here, minimal for
//! the class's sequences, so no engine knows about code points.
//!
//! Immutable once built. State ids are branded with this type; which automaton an id belongs
//! to is the engine's to keep.
const Nfa = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Hir = @import("../hir/Hir.zig");

pub const StateId = aegis.handle.Index(Nfa, u32);
pub const Look = Hir.Look;
pub const LookSet = std.EnumSet(Look);

states: []const State,
/// Where `sparse` states keep their transitions.
transitions: []const Transition,
/// Where `alternation` states keep their alternatives.
alternatives: []const StateId,
/// Where an anchored search starts: the whole match's capture.
start_anchored: StateId,
/// Where an unanchored search starts: a lazy `(?s-u:.)*?` before the pattern, or the anchored
/// start when every match of the pattern begins at the haystack's start.
start_unanchored: StateId,
/// Capture groups, the whole match (group 0) among them. Group `g` writes slots `2g` and `2g+1`.
groups: u32,
/// Each group's name, by its number.
names: []const ?[]const u8,
/// The bytes the names hold.
name_bytes: []const u8,
/// Every assertion a state makes.
looks: LookSet,
/// An empty match must not split a code point (`Syntax.utf8`): the search's rule, kept here.
utf8: bool,
/// Some match is empty: a search in UTF-8 checks where such a match ends.
empty_ok: bool,
/// Every match ends at the haystack's end (`\z`, or a `$` that is no line's).
end_anchored: bool,
/// Some state is a `loop_begin` or `loop_end`: each thread carries whether it read a byte since
/// its innermost `loop_begin`, and is told apart by it.
loop_checks: bool,
/// The patterns whose matches it tells apart: 1 but for a set's automaton.
patterns: u32 = 1,
/// Some state is a `check`: a search needs the oracle's rows.
checks: bool = false,

pub const Transition = struct {
    lo: u8,
    hi: u8,
    next: StateId,

    pub fn contains(t: Transition, byte: u8) bool {
        return t.lo <= byte and byte <= t.hi;
    }
};

pub const Slice = struct { start: u32, len: u32 };

pub const State = union(enum) {
    /// One byte of the range.
    byte_range: Transition,
    /// One byte, by the first transition whose range holds it: ranges sorted and apart.
    sparse: Slice,
    /// If the assertion holds where the search is, `next`.
    look: struct { look: Look, next: StateId },
    /// Two alternatives, the first preferred.
    binary: struct { first: StateId, second: StateId },
    /// Three or more alternatives, in order of preference.
    alternation: Slice,
    /// Writes the search's position into `slot`, then `next`.
    capture: struct { group: u32, slot: u32, next: StateId },
    /// Empties slots `first` to `end`, then `next`: ECMA-262's iteration, which starts with the
    /// captures of every group in its atom cleared.
    clear: struct { first: u32, end: u32, next: StateId },
    /// ECMA-262's iteration that must not match empty begins, then `next`: the thread has read
    /// nothing in it yet. Brackets each time past a repetition's minimum of an atom that can
    /// match empty, with `loop_end`.
    loop_begin: StateId,
    /// That iteration ends, and goes on to `next` only if the thread read a byte since its
    /// innermost `loop_begin`: an iteration past the minimum that matched empty fails
    /// (RepeatMatcher's step 2.b). Quantifiers nest, so one bit a thread carries answers it.
    loop_end: StateId,
    /// Lookaround `row` (its number) holds where the search is, or with `negated` does not:
    /// then `next`. Answered by the oracle (oracle.zig), which builds each row before a scan reads
    /// it.
    check: struct { row: u32, negated: bool, next: StateId },
    /// Matches nothing: an empty class.
    fail,
    /// A match of pattern `match`: always 0 but in a set's automaton, which holds one match
    /// state per pattern.
    match: u32,
};

pub fn state(nfa: *const Nfa, id: StateId) State {
    return nfa.states[id.raw()];
}

/// A `sparse` state's transitions.
pub fn transitionsOf(nfa: *const Nfa, slice: Slice) []const Transition {
    return nfa.transitions[slice.start..][0..slice.len];
}

/// An `alternation` state's alternatives.
pub fn alternativesOf(nfa: *const Nfa, slice: Slice) []const StateId {
    return nfa.alternatives[slice.start..][0..slice.len];
}

/// Capture slots a search fills: two per group.
pub fn slots(nfa: *const Nfa) u32 {
    return nfa.groups * 2;
}

/// The bytes the automaton holds.
pub fn memory(nfa: *const Nfa) usize {
    return nfa.states.len * @sizeOf(State) + nfa.transitions.len * @sizeOf(Transition) +
        nfa.alternatives.len * @sizeOf(StateId) + nfa.names.len * @sizeOf(?[]const u8) + nfa.name_bytes.len;
}

pub fn deinit(nfa: *Nfa, gpa: Allocator) void {
    gpa.free(nfa.states);
    gpa.free(nfa.transitions);
    gpa.free(nfa.alternatives);
    gpa.free(nfa.names);
    gpa.free(nfa.name_bytes);
    nfa.* = undefined;
}
