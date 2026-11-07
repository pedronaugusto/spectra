//! A parsed pattern: every node with its span in the pattern, so an error, and later every
//! translation, points at the bytes that caused it. Nodes live in one array and refer to each
//! other by index; text (a Unicode property's name) is borrowed from the pattern.

const Ast = @This();

nodes: []const Node,
/// Class items, which a bracketed class's `items` and a set operation's operands slice.
class_items: []const ClassItem,
/// The concatenations' and alternations' children.
children: []const Index,
root: Index,
/// How many capturing groups: group `n` is the `n`th opening parenthesis that captures, from 1.
captures: u32,

pub const Index = enum(u32) { _ };

/// A byte range of the pattern.
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Node = struct {
    span: Span,
    kind: Kind,
};

pub const Kind = union(enum) {
    /// Matches the empty string: an empty pattern, an empty alternative or group.
    empty,
    /// One code point (or, with `Syntax.utf8 = false`, one byte, written `\xFF`).
    literal: u21,
    /// `.`
    dot,
    assertion: Assertion,
    perl: Perl,
    unicode: Unicode,
    /// `[...]`: its items, a slice of `class_items`.
    bracketed: Bracketed,
    repetition: Repetition,
    group: Group,
    /// `(?flags)` alone: the flags it sets for the rest of its group.
    flags: Flags,
    /// Children are a slice of `children`.
    alternation: Slice,
    concat: Slice,
};

pub const Slice = struct { start: u32, len: u32 };

pub const Assertion = enum {
    /// `^`: the start of the haystack, or of a line under `m`.
    start_line,
    /// `$`
    end_line,
    /// `\A`
    start_text,
    /// `\z`
    end_text,
    /// `\b`
    word_boundary,
    /// `\B`
    not_word_boundary,
    /// `\<` or `\b{start}`
    word_start,
    /// `\>` or `\b{end}`
    word_end,
    /// `\b{start-half}`
    word_start_half,
    /// `\b{end-half}`
    word_end_half,
};

/// `\d`, `\s`, `\w` and their negations.
pub const Perl = struct {
    class: enum { digit, space, word },
    negated: bool,
};

/// `\pN`, `\p{Greek}`, `\p{sc=Greek}`, `\p{^Greek}`, `\PN`: names borrowed from the pattern,
/// resolved against xenoglyph's properties when translated.
pub const Unicode = struct {
    /// The property, or the value alone (`Greek`, `L`).
    name: []const u8,
    /// The value after `=` or `:` (`\p{sc=Greek}`), else null.
    value: ?[]const u8,
    negated: bool,
};

pub const Bracketed = struct {
    negated: bool,
    items: ItemSlice,
};

pub const ItemSlice = struct { start: u32, len: u32 };

pub const ClassItem = union(enum) {
    literal: u21,
    /// `a-z`, its ends inclusive and in order.
    range: [2]u21,
    perl: Perl,
    unicode: Unicode,
    /// `[:alpha:]` and its negation `[:^alpha:]`.
    ascii: Ascii,
    /// A class inside a class.
    nested: Bracketed,
    /// `lhs && rhs`, `lhs -- rhs`, `lhs ~~ rhs`: each side the union of its items.
    operation: Operation,
};

pub const Ascii = struct {
    class: AsciiClass,
    negated: bool,
};

pub const AsciiClass = enum { alnum, alpha, ascii, blank, cntrl, digit, graph, lower, print, punct, space, upper, word, xdigit };

pub const Operation = struct {
    op: enum { intersection, difference, symmetric_difference },
    lhs: ItemSlice,
    rhs: ItemSlice,
};

pub const Repetition = struct {
    min: u32,
    /// Null: no upper bound.
    max: ?u32,
    greedy: bool,
    sub: Index,
};

pub const Group = struct {
    kind: union(enum) {
        /// Its number (from 1) and its name, borrowed from the pattern.
        capture: struct { index: u32, name: ?[]const u8 },
        /// `(?:...)` or `(?flags:...)`: the flags it sets inside.
        non_capturing: Flags,
    },
    sub: Index,
};

/// The inline flags a group or `(?flags)` sets and clears.
pub const Flags = struct {
    set: Set = .{},
    clear: Set = .{},

    pub const Set = packed struct(u8) {
        case_insensitive: bool = false,
        multi_line: bool = false,
        dot_matches_new_line: bool = false,
        swap_greed: bool = false,
        unicode: bool = false,
        ignore_whitespace: bool = false,
        crlf: bool = false,
        _: u1 = 0,
    };
};

pub fn node(ast: *const Ast, index: Index) Node {
    return ast.nodes[@intFromEnum(index)];
}

pub fn childrenOf(ast: *const Ast, slice: Slice) []const Index {
    return ast.children[slice.start..][0..slice.len];
}

pub fn itemsOf(ast: *const Ast, slice: ItemSlice) []const ClassItem {
    return ast.class_items[slice.start..][0..slice.len];
}
