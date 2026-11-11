//! How a compiled pattern is searched, chosen once at compile from what its automata say:
//! regex-automata's meta strategies, those that need no prefilter (the literal ones, reverse
//! suffix and reverse inner, come with the prefilters).
const Nfa = @import("nfa/Nfa.zig");
const pikevm = @import("pikevm.zig");
const lazy = @import("lazy.zig");

pub const Span = pikevm.Span;
pub const Input = pikevm.Input;

pub const Strategy = enum {
    /// The PikeVM alone: the pattern has no lazy DFA.
    pikevm,
    /// The lazy DFA finds where the leftmost-first match ends, the reverse lazy DFA read back
    /// from there where it starts, and the PikeVM its captures over the match alone; each falls
    /// back as `Regex` says.
    core,
    /// Every match ends at the haystack's end and the pattern is not anchored at its start: the
    /// reverse lazy DFA reads back from the end, and the earliest start of a match ending there
    /// is the leftmost-first match's, since every match from the leftmost start ends there too.
    /// Nothing reads forward, so a search reads the tail its match needs, not the haystack. On
    /// a quit or a give-up, `core`.
    reverse_anchored,
    /// Every match is one literal the prefilter confirms whole (one literal, or single bytes)
    /// and the pattern asserts nothing: the prefilter alone finds the match, the leftmost
    /// literal's.
    literal,
};

/// The strategy for a pattern of automaton `nfa` with the lazy DFAs it has, and whether its
/// prefilter finds its matches whole.
pub fn choose(nfa: *const Nfa, forward: bool, reverse: bool, literal: bool) Strategy {
    if (literal) return .literal;
    if (!forward) return .pikevm;
    const anchored = nfa.start_anchored == nfa.start_unanchored;
    if (reverse and nfa.end_anchored and !anchored) return .reverse_anchored;
    return .core;
}

/// `reverse_anchored`'s search: the leftmost-first match in `input`, or null. `nfa`, `d` and `c`
/// are the reverse automaton's. A span that stops short of the haystack's end holds no match,
/// and the reverse automaton's `\z` says so at its first step; anchored, the match must start
/// at the span's start.
pub fn reverseAnchored(nfa: *const Nfa, d: *const lazy.Dfa, c: *lazy.Cache, input: Input) lazy.Error!?Span {
    const start = try lazy.searchReverse(nfa, d, c, input) orelse return null;
    if (input.anchored and start != input.span.start) return null;
    return .{ .start = start, .end = input.span.end };
}
