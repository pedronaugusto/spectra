//! A pattern with its sugar gone: flags applied, classes as sets, escapes resolved, adjacent
//! literals joined. What the compiler reads, whichever dialect wrote it. Nodes live in one
//! array and refer to each other by index, a parent after its children.

const Hir = @This();

nodes: []const Node,
children: []const Index,
root: Index,
/// How many capturing groups, as the pattern's.
captures: u32,

pub const Index = enum(u32) { _ };

pub const Node = union(enum) {
    /// Matches the empty string.
    empty,
    /// These bytes, one or more: UTF-8, or without `u` and with `Syntax.utf8 = false` any bytes.
    literal: []const u8,
    /// One code point of the sorted ranges (surrogates dropped where it is compiled), or none:
    /// an empty class never matches.
    unicode_class: []const [2]u21,
    /// One byte of the sorted ranges.
    byte_class: []const [2]u8,
    look: Look,
    repetition: Repetition,
    capture: Capture,
    /// The children, a slice of `children`, at least two.
    concat: Slice,
    /// The children, first preferred.
    alternation: Slice,
    /// ECMAScript's `(?=...)` and `(?!...)`, which the derivative engine runs.
    lookahead: Lookahead,
};

pub const Slice = struct { start: u32, len: u32 };

pub const Repetition = struct {
    min: u32,
    /// Null: no upper bound.
    max: ?u32,
    greedy: bool,
    sub: Index,
};

pub const Capture = struct {
    /// From 1, the group's number.
    index: u32,
    name: ?[]const u8,
    sub: Index,
};

pub const Lookahead = struct {
    negated: bool,
    sub: Index,
};

/// A zero-width assertion, each the exact test it makes.
pub const Look = enum {
    start_text,
    end_text,
    /// After `\n`, or at the start.
    start_line_lf,
    /// Before `\n`, or at the end.
    end_line_lf,
    /// Rust's `R`: lines end in `\r` or `\n`, and never between a `\r\n`.
    start_line_crlf,
    end_line_crlf,
    /// ECMAScript's `m`: after or before `\n`, `\r`, U+2028 or U+2029.
    start_line_ecma,
    end_line_ecma,
    word_ascii,
    not_word_ascii,
    word_unicode,
    not_word_unicode,
    /// ECMAScript's `\b` under `u` or `v` with `i`: `[0-9A-Za-z_]`, U+017F and U+212A.
    word_ecma_folded,
    not_word_ecma_folded,
    word_start_ascii,
    word_end_ascii,
    word_start_unicode,
    word_end_unicode,
    word_start_half_ascii,
    word_end_half_ascii,
    word_start_half_unicode,
    word_end_half_unicode,
};

pub fn node(hir: *const Hir, index: Index) Node {
    return hir.nodes[@backingInt(index)];
}

pub fn childrenOf(hir: *const Hir, slice: Slice) []const Index {
    return hir.children[slice.start..][0..slice.len];
}
