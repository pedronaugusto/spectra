//! Parts of this file follow regex-automata 0.4.18 (the Rust regex project), meta/reverse_inner.rs:
//! the order `leads` tries its proofs in (one literal against P's reading, then a fixed length,
//! then a separator) is `has_no_earlier_match`'s, and splitting at the top concatenation's first
//! child after the first whose prefixes give a prefilter follows `InnerPrefilter::new`. Copyright
//! (c) 2014 The Rust Project Developers, MIT OR Apache-2.0; the MIT text is in
//! LICENSES/regex-MIT.txt. The arguments below and the prefix-pattern construction are
//! spectra's own.
//!
//! Whether an inner literal can lead the search: the reverse inner strategy, which splits the
//! pattern's top concatenation as P·X where every match of X starts with one of a few literals,
//! scans for them, reads back from each occurrence with P's reverse automaton to where the
//! earliest match of P ending there starts (s), and from s searches forward for the whole
//! pattern. This file proves, conservatively, when the first occurrence at which that search
//! confirms a match gives the leftmost-first match; where a proof fails, the strategy is not
//! taken.
//!
//! The setting. Occurrences are tried in the order they start. Every match is a match p of P
//! ending where a match x of X begins, at an occurrence. At the occurrence l the answer is the
//! leftmost-first match from s, right exactly where no match starts before s. A match M' = p'x'
//! starting before s whose x' begins at an earlier occurrence b' is no danger: there, reading
//! back found an s0 at or before M''s start, and P's match [s0, b'] followed by x' is a match
//! from s0, so the forward search confirmed at b' and the strategy never reached l. One whose
//! x' begins at l starts no earlier than s. The danger is an M' starting before s whose x'
//! begins after l, so the occurrence at l lies inside p', or across p' and the literal x'
//! starts with. Any one of these closes it:
//!
//! - There is one literal L, and some byte of L no part of P reads (`suffix.containsAll` false).
//!   Inside p', p' holds every byte of L; across into x''s L at shift d < |L|, L[i] = L[i + d]
//!   makes its first d bytes, which p' holds, every byte L has. With several literals the second
//!   case fails (an occurrence may run into a different literal), so this needs one.
//!
//! - P has a fixed length k (`suffix.fixedLength`): s = l - k, and M' starts at b' - k, later.
//!
//! - P's last reading part is a class S read at least once that shares nothing with any literal
//!   or any other part of P (`suffix.separated`, against every literal at once). The character
//!   before l is S's in P's match at s; in M' it lies inside p' and only S reads it, so S's run
//!   goes on unbroken to b', past l, where a literal's first character is no character of S.
//!
//! - P's first reading part is such an S. M''s S run covers the character at s (inside p') and
//!   stops where P's match at s leaves S, so M''s run followed by the rest of P's match at s is
//!   a match of P from M''s start to l, against s being the earliest.
//!
//! The search also never reads a byte back twice (each reverse scan stops at the occurrence
//! before) nor forward twice (an occurrence starting before where the last forward scan
//! stopped ends the attempt); either way the core strategy answers, so the work stays linear.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Hir = @import("Hir.zig");
const suffix = @import("suffix.zig");
const literals = @import("literals.zig");

/// The children of the pattern's top concatenation, through capture groups, or null where
/// the pattern is not one.
pub fn topConcat(hir: *const Hir) ?[]const Hir.Index {
    var at = hir.root;
    while (true) switch (hir.node(at)) {
        .capture => |c| at = c.sub,
        .concat => |slice| return hir.childrenOf(slice),
        else => return null,
    };
}

/// The pattern rooted at node `index` instead: the same nodes, another root.
pub fn rootedAt(hir: *const Hir, index: Hir.Index) Hir {
    var view = hir.*;
    view.root = index;
    return view;
}

/// The pattern P: the top concatenation's first `at` children, as a pattern of its own (its
/// nodes, and one concatenation of them where there are two or more).
pub fn prefix(arena: Allocator, hir: *const Hir, kids: []const Hir.Index, at: usize) Allocator.Error!Hir {
    std.debug.assert(at >= 1 and at < kids.len);
    if (at == 1) return rootedAt(hir, kids[0]);
    const nodes = try arena.alloc(Hir.Node, hir.nodes.len + 1);
    @memcpy(nodes[0..hir.nodes.len], hir.nodes);
    const children = try arena.alloc(Hir.Index, hir.children.len + at);
    @memcpy(children[0..hir.children.len], hir.children);
    @memcpy(children[hir.children.len..], kids[0..at]);
    nodes[hir.nodes.len] = .{ .concat = .{ .start = @intCast(hir.children.len), .len = @intCast(at) } };
    return .{ .nodes = nodes, .children = children, .root = @enumFromInt(hir.nodes.len), .captures = hir.captures };
}

/// Whether, split before child `at` with X's matches starting with `lits`, the first
/// occurrence at which the forward search confirms gives the leftmost-first match.
pub fn leads(arena: Allocator, hir: *const Hir, kids: []const Hir.Index, at: usize, lits: []const literals.Literal) Allocator.Error!bool {
    if (lits.len == 0) return false;
    for (lits) |lit| if (lit.bytes.len == 0) return false;
    const p = try arena.alloc(suffix.Part, at);
    for (p, kids[0..at]) |*part, kid| part.* = .{ .node = kid };
    if (lits.len == 1 and !suffix.containsAll(hir, p, lits[0].bytes)) return true;
    if (suffix.fixedLength(hir, p)) return true;
    // One separator apart from every literal: apart from their bytes all together.
    var all: std.ArrayList(u8) = .empty;
    for (lits) |lit| try all.appendSlice(arena, lit.bytes);
    return suffix.separated(arena, hir, p, all.items);
}
