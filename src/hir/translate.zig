//! An `Ast` into the `Hir`, by its dialect's rules: regex-syntax's for Rust and ECMA-262's for
//! ECMAScript. Flags are applied here, classes become sets, Unicode names their ranges. Both
//! the tree and a class's items are walked on explicit stacks: a chain of repetitions or of
//! class operators is as long as its pattern, whatever `Limits.nesting` says.
//!
//! What ECMA-262 means and spectra cannot run is refused by name, `error.Unsupported`:
//! backreferences, lookbehind, a lookaround inside a lookaround, a property with no data.
//!
//! Without `u` or `v` ECMA-262 reads UTF-16 code units, and the haystack here is UTF-8. A code
//! point past U+FFFF written whole is matched whole. Half of one named alone (`\uD83D`, or a
//! quantifier on the second half, `😀+`) has no meaning over UTF-8 and is refused, never left
//! to match nothing. `.` and a negated class take one code point, where a UTF-16 engine takes
//! half of one past U+FFFF.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const Allocator = std.mem.Allocator;
const Ast = @import("../syntax/Ast.zig");
const diagnostic_zig = @import("../syntax/diagnostic.zig");
const Syntax = @import("../Syntax.zig");
const Hir = @import("Hir.zig");
const ranges = @import("ranges.zig");
const properties = xenoglyph.properties;
const CodePoints = ranges.CodePoints;
const Diagnostic = diagnostic_zig.Diagnostic;
const Reason = diagnostic_zig.Reason;

pub const Error = error{ OutOfMemory, Invalid, Unsupported };

const Dialect = enum { rust, annex_b, unicode, sets };

const Flags = struct {
    case_insensitive: bool,
    multi_line: bool,
    dot_matches_new_line: bool,
    swap_greed: bool,
    unicode: bool,
    crlf: bool,

    fn apply(f: *Flags, ast_flags: Ast.Flags) void {
        inline for (.{ "case_insensitive", "multi_line", "dot_matches_new_line", "swap_greed", "unicode", "crlf" }) |name| {
            if (@field(ast_flags.set, name)) @field(f, name) = true;
            if (@field(ast_flags.clear, name)) @field(f, name) = false;
        }
    }
};

/// The translation of `ast`, in `arena`, which the `Hir` borrows.
pub fn translate(arena: Allocator, ast: *const Ast, syntax: Syntax, diagnostic: ?*Diagnostic) Error!Hir {
    var t: Translator = .{
        .arena = arena,
        .ast = ast,
        .utf8 = syntax.utf8,
        .diagnostic = diagnostic,
        .dialect = switch (syntax.dialect) {
            .rust => .rust,
            .ecmascript => if (syntax.unicode_sets) .sets else if (syntax.unicode) .unicode else .annex_b,
        },
        .flags = .{
            .case_insensitive = syntax.case_insensitive,
            .multi_line = syntax.multi_line,
            .dot_matches_new_line = syntax.dot_matches_new_line,
            .swap_greed = syntax.swap_greed,
            .unicode = syntax.unicode or syntax.unicode_sets,
            .crlf = false,
        },
    };
    return t.run();
}

const Work = union(enum) {
    visit: Ast.Index,
    /// Two code units that are one code point.
    pair: struct { cp: u21, span: Ast.Span },
    concat: u32,
    alternation: u32,
    repetition: Ast.Repetition,
    group: struct { capture: ?Capture, saved: Flags },
    lookahead: struct { negated: bool },
};

/// A class being evaluated: its code points, and under `v` its strings of other than one.
const Value = struct {
    set: CodePoints = .{},
    /// UTF-32 of each string, as bytes.
    strings: std.StringHashMapUnmanaged(void) = .empty,
};

const Done = union(enum) {
    root,
    /// A nested class, finished then added to its parent.
    nested: bool,
    lhs: Ast.Operation,
    rhs: struct { op: @FieldType(Ast.Operation, "op"), lhs: Value },
};

const ClassFrame = struct {
    items: []const Ast.ClassItem,
    at: usize = 0,
    value: Value = .{},
    done: Done,
};

const Capture = struct { index: u32, name: ?[]const u8 };

const surrogates: [2]u21 = .{ 0xd800, 0xdfff };

const Translator = struct {
    arena: Allocator,
    ast: *const Ast,
    utf8: bool,
    diagnostic: ?*Diagnostic,
    dialect: Dialect,
    flags: Flags,
    nodes: std.ArrayList(Hir.Node) = .empty,
    children: std.ArrayList(Hir.Index) = .empty,
    /// Lookarounds open around what is being read.
    lookaround: u32 = 0,

    fn fail(t: *Translator, span: Ast.Span, reason: Reason) error{Invalid} {
        if (t.diagnostic) |d| d.* = .{ .span = span, .reason = reason };
        return error.Invalid;
    }

    fn unsupported(t: *Translator, span: Ast.Span, reason: Reason) error{Unsupported} {
        if (t.diagnostic) |d| d.* = .{ .span = span, .reason = reason };
        return error.Unsupported;
    }

    fn add(t: *Translator, n: Hir.Node) Error!Hir.Index {
        const index: Hir.Index = @fromBackingInt(@intCast(t.nodes.items.len));
        try t.nodes.append(t.arena, n);
        return index;
    }

    /// Whether classes hold code points: false is Rust without `u`, whose classes hold bytes.
    fn codePoints(t: *const Translator) bool {
        return t.dialect != .rust or t.flags.unicode;
    }

    fn folding(t: *const Translator) ranges.Folding {
        return switch (t.dialect) {
            .rust => if (t.flags.unicode) .simple else .ascii,
            .annex_b => .ecma_uppercase,
            .unicode, .sets => .simple,
        };
    }

    fn run(t: *Translator) Error!Hir {
        var work: std.ArrayList(Work) = .empty;
        var results: std.ArrayList(Hir.Index) = .empty;
        try work.append(t.arena, .{ .visit = t.ast.root });
        while (work.pop()) |w| switch (w) {
            .visit => |index| try t.visit(index, &work, &results),
            .pair => |p| try results.append(t.arena, try t.literal(p.cp, p.span)),
            .concat => |n| {
                const at = results.items.len - n;
                const joined = try t.concat(results.items[at..]);
                results.shrinkRetainingCapacity(at);
                try results.append(t.arena, joined);
            },
            .alternation => |n| {
                const at = results.items.len - n;
                const alternatives = try t.slice(results.items[at..]);
                results.shrinkRetainingCapacity(at);
                try results.append(t.arena, try t.add(.{ .alternation = alternatives }));
            },
            .repetition => |r| {
                const sub = results.pop().?;
                const greedy = r.greedy != t.flags.swap_greed;
                try results.append(t.arena, if (r.min == 1 and r.max == 1)
                    sub
                else if (r.max == 0)
                    try t.add(.empty)
                else
                    try t.add(.{ .repetition = .{ .min = r.min, .max = r.max, .greedy = greedy, .sub = sub } }));
            },
            .group => |g| {
                t.flags = g.saved;
                if (g.capture) |c| {
                    const sub = results.pop().?;
                    try results.append(t.arena, try t.add(.{ .capture = .{ .index = c.index, .name = c.name, .sub = sub } }));
                }
            },
            .lookahead => |l| {
                t.lookaround -= 1;
                const sub = results.pop().?;
                try results.append(t.arena, try t.add(.{ .lookahead = .{ .negated = l.negated, .sub = sub } }));
            },
        };
        aegis.assert.invariant(results.items.len == 1, "every node left one result");
        return .{
            .nodes = try t.nodes.toOwnedSlice(t.arena),
            .children = try t.children.toOwnedSlice(t.arena),
            .root = results.items[0],
            .captures = t.ast.captures,
        };
    }

    fn slice(t: *Translator, items: []const Hir.Index) Error!Hir.Slice {
        const out: Hir.Slice = .{ .start = @intCast(t.children.items.len), .len = @intCast(items.len) };
        try t.children.appendSlice(t.arena, items);
        return out;
    }

    /// `items` in order: empties gone, nested concatenations opened, adjacent literals joined.
    fn concat(t: *Translator, items: []const Hir.Index) Error!Hir.Index {
        var flat: std.ArrayList(Hir.Index) = .empty;
        for (items) |kid| switch (t.nodes.items[@backingInt(kid)]) {
            .empty => {},
            .concat => |s| try flat.appendSlice(t.arena, t.children.items[s.start..][0..s.len]),
            else => try flat.append(t.arena, kid),
        };
        var out: std.ArrayList(Hir.Index) = .empty;
        var run_start: usize = 0;
        while (run_start < flat.items.len) {
            var run_end = run_start + 1;
            if (t.nodes.items[@backingInt(flat.items[run_start])] != .literal) {
                try out.append(t.arena, flat.items[run_start]);
                run_start = run_end;
                continue;
            }
            var bytes: usize = t.nodes.items[@backingInt(flat.items[run_start])].literal.len;
            while (run_end < flat.items.len and t.nodes.items[@backingInt(flat.items[run_end])] == .literal) : (run_end += 1) {
                bytes += t.nodes.items[@backingInt(flat.items[run_end])].literal.len;
            }
            if (run_end == run_start + 1) {
                try out.append(t.arena, flat.items[run_start]);
            } else {
                const joined = try t.arena.alloc(u8, bytes);
                var at: usize = 0;
                for (flat.items[run_start..run_end]) |kid| {
                    const part = t.nodes.items[@backingInt(kid)].literal;
                    @memcpy(joined[at..][0..part.len], part);
                    at += part.len;
                }
                try out.append(t.arena, try t.add(.{ .literal = joined }));
            }
            run_start = run_end;
        }
        if (out.items.len == 0) return t.add(.empty);
        if (out.items.len == 1) return out.items[0];
        return t.add(.{ .concat = try t.slice(out.items) });
    }

    fn visit(t: *Translator, index: Ast.Index, work: *std.ArrayList(Work), results: *std.ArrayList(Hir.Index)) Error!void {
        const n = t.ast.node(index);
        switch (n.kind) {
            .empty => try results.append(t.arena, try t.add(.empty)),
            .literal => |cp| try results.append(t.arena, try t.literal(cp, n.span)),
            .byte => |b| try results.append(t.arena, try t.byte(b, n.span)),
            .dot => try results.append(t.arena, try t.dot(n.span)),
            .assertion => |a| try results.append(t.arena, try t.add(.{ .look = t.look(a) })),
            .perl => |p| {
                var value: Value = .{};
                try t.perl(&value, p);
                if (t.dialect != .rust) try t.close(&value.set);
                try results.append(t.arena, try t.emit(&value, n.span));
            },
            .unicode => |u| {
                var value: Value = .{};
                try t.unicode(&value, u, n.span);
                if (t.dialect != .rust) try t.close(&value.set);
                try results.append(t.arena, try t.emit(&value, n.span));
            },
            .bracketed => |b| {
                var value = try t.class(b, n.span);
                try results.append(t.arena, try t.emit(&value, n.span));
            },
            .repetition => |r| {
                try work.append(t.arena, .{ .repetition = r });
                try work.append(t.arena, .{ .visit = r.sub });
            },
            .group => |g| {
                const saved = t.flags;
                var capture: ?Capture = null;
                switch (g.kind) {
                    .capture => |c| capture = .{ .index = c.index, .name = c.name },
                    .non_capturing => |f| t.flags.apply(f),
                }
                try work.append(t.arena, .{ .group = .{ .capture = capture, .saved = saved } });
                try work.append(t.arena, .{ .visit = g.sub });
            },
            .flags => |f| {
                t.flags.apply(f);
                try results.append(t.arena, try t.add(.empty));
            },
            .alternation => |s| {
                const kids = t.ast.childrenOf(s);
                try work.append(t.arena, .{ .alternation = s.len });
                var i = kids.len;
                while (i > 0) {
                    i -= 1;
                    try work.append(t.arena, .{ .visit = kids[i] });
                }
            },
            .concat => |s| try t.concatWork(t.ast.childrenOf(s), work),
            .lookaround => |l| {
                if (l.direction == .behind) return t.unsupported(n.span, .unsupported_lookbehind);
                if (t.lookaround != 0) return t.unsupported(n.span, .unsupported_nested_lookaround);
                t.lookaround += 1;
                try work.append(t.arena, .{ .lookahead = .{ .negated = l.negated } });
                try work.append(t.arena, .{ .visit = l.sub });
            },
            .backreference => return t.unsupported(n.span, .unsupported_backreference),
        }
    }

    /// A concatenation's children to visit, in order; without `u` or `v`, the two halves of a
    /// code point past U+FFFF, side by side, are one.
    fn concatWork(t: *Translator, kids: []const Ast.Index, work: *std.ArrayList(Work)) Error!void {
        var items: std.ArrayList(Work) = .empty;
        var i: usize = 0;
        while (i < kids.len) : (i += 1) {
            if (t.dialect == .annex_b and i + 1 < kids.len) {
                const a = t.ast.node(kids[i]);
                const b = t.ast.node(kids[i + 1]);
                if (a.kind == .literal and b.kind == .literal and isLead(a.kind.literal) and isTrail(b.kind.literal)) {
                    const cp: u21 = @intCast(0x10000 + ((@as(u32, a.kind.literal) - 0xd800) << 10) + (b.kind.literal - 0xdc00));
                    try items.append(t.arena, .{ .pair = .{ .cp = cp, .span = .{ .start = a.span.start, .end = b.span.end } } });
                    i += 1;
                    continue;
                }
            }
            try items.append(t.arena, .{ .visit = kids[i] });
        }
        try work.append(t.arena, .{ .concat = @intCast(items.items.len) });
        var at = items.items.len;
        while (at > 0) {
            at -= 1;
            try work.append(t.arena, items.items[at]);
        }
    }

    fn encoded(t: *Translator, cp: u21) Error!Hir.Index {
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buffer) catch aegis.assert.never("a literal encoded is a scalar value");
        return t.add(.{ .literal = try t.arena.dupe(u8, buffer[0..n]) });
    }

    fn literal(t: *Translator, cp: u21, span: Ast.Span) Error!Hir.Index {
        if (cp >= surrogates[0] and cp <= surrogates[1]) {
            if (t.dialect == .annex_b) return t.unsupported(span, .unsupported_code_unit_split);
            // Under `u` or `v` a lone surrogate is a code point that well-formed text never holds.
            return t.add(.{ .unicode_class = &.{} });
        }
        if (!t.flags.case_insensitive) return t.encoded(cp);
        if (!t.codePoints() and cp > 0x7f) return t.encoded(cp);
        var value: Value = .{};
        try value.set.add(t.arena, .{ cp, cp });
        try value.set.closeUnderCase(t.arena, t.folding());
        if (value.set.count() == 1) return t.encoded(cp);
        return t.add(.{ .unicode_class = value.set.items() });
    }

    fn byte(t: *Translator, b: u8, span: Ast.Span) Error!Hir.Index {
        if (t.flags.unicode) return t.literal(b, span);
        if (t.utf8) return t.fail(span, .invalid_utf8_class);
        return t.add(.{ .literal = try t.arena.dupe(u8, &.{b}) });
    }

    fn dot(t: *Translator, span: Ast.Span) Error!Hir.Index {
        var value: Value = .{};
        const s = &value.set;
        try t.addFull(s);
        if (!t.flags.dot_matches_new_line) {
            const excepted: []const [2]u21 = switch (t.dialect) {
                .rust => if (t.flags.crlf) &.{ .{ '\n', '\n' }, .{ '\r', '\r' } } else &.{.{ '\n', '\n' }},
                else => &.{ .{ '\n', '\n' }, .{ '\r', '\r' }, .{ 0x2028, 0x2029 } },
            };
            var out = try CodePoints.fromRanges(t.arena, excepted);
            if (!t.codePoints()) try intersectBytes(t.arena, &out);
            try s.subtract(t.arena, &out);
        }
        return t.emit(&value, span);
    }

    fn addFull(t: *Translator, s: *CodePoints) Error!void {
        try s.add(t.arena, .{ 0, if (t.codePoints()) 0x10ffff else 0xff });
    }

    fn look(t: *const Translator, a: Ast.Assertion) Hir.Look {
        const uni = t.dialect == .rust and t.flags.unicode;
        return switch (a) {
            .start_text => .start_text,
            .end_text => .end_text,
            .start_line => if (!t.flags.multi_line) .start_text else switch (t.dialect) {
                .rust => if (t.flags.crlf) .start_line_crlf else .start_line_lf,
                else => .start_line_ecma,
            },
            .end_line => if (!t.flags.multi_line) .end_text else switch (t.dialect) {
                .rust => if (t.flags.crlf) .end_line_crlf else .end_line_lf,
                else => .end_line_ecma,
            },
            .word_boundary => if (t.ecmaFoldedWord()) .word_ecma_folded else if (uni) .word_unicode else .word_ascii,
            .not_word_boundary => if (t.ecmaFoldedWord()) .not_word_ecma_folded else if (uni) .not_word_unicode else .not_word_ascii,
            .word_start => if (uni) .word_start_unicode else .word_start_ascii,
            .word_end => if (uni) .word_end_unicode else .word_end_ascii,
            .word_start_half => if (uni) .word_start_half_unicode else .word_start_half_ascii,
            .word_end_half => if (uni) .word_end_half_unicode else .word_end_half_ascii,
        };
    }

    /// ECMA-262's WordCharacters under `u` or `v` with `i` takes U+017F and U+212A.
    fn ecmaFoldedWord(t: *const Translator) bool {
        return (t.dialect == .unicode or t.dialect == .sets) and t.flags.case_insensitive;
    }

    fn close(t: *Translator, s: *CodePoints) Error!void {
        if (t.flags.case_insensitive) try s.closeUnderCase(t.arena, t.folding());
    }

    fn negate(t: *Translator, s: *CodePoints) Error!void {
        try s.negate(t.arena);
        if (!t.codePoints()) try intersectBytes(t.arena, s);
    }

    fn perl(t: *Translator, value: *Value, p: Ast.Perl) Error!void {
        var set: CodePoints = .{};
        if (t.dialect != .rust) {
            switch (p.class) {
                .digit => try addAll(t.arena, &set, &.{.{ '0', '9' }}),
                .space => {
                    try addAll(t.arena, &set, &.{ .{ 9, 13 }, .{ ' ', ' ' }, .{ 0xa0, 0xa0 }, .{ 0x2028, 0x2029 }, .{ 0xfeff, 0xfeff } });
                    try addAll(t.arena, &set, properties.generalCategoryRanges(.space_separator));
                },
                .word => {
                    try addAll(t.arena, &set, &ascii_word);
                    if (t.ecmaFoldedWord()) try addAll(t.arena, &set, &.{ .{ 0x17f, 0x17f }, .{ 0x212a, 0x212a } });
                },
            }
            if (t.dialect == .sets) try t.close(&set);
        } else if (t.flags.unicode) {
            switch (p.class) {
                .digit => try addAll(t.arena, &set, properties.generalCategoryRanges(.decimal_number)),
                .space => try addAll(t.arena, &set, properties.whiteSpaceRanges()),
                .word => {
                    try addAll(t.arena, &set, properties.binaryRanges(.alphabetic));
                    try addAll(t.arena, &set, properties.generalCategoryGroupRanges(.mark));
                    try addAll(t.arena, &set, properties.generalCategoryRanges(.decimal_number));
                    try addAll(t.arena, &set, properties.generalCategoryRanges(.connector_punctuation));
                    try addAll(t.arena, &set, properties.binaryRanges(.join_control));
                },
            }
        } else switch (p.class) {
            .digit => try addAll(t.arena, &set, &.{.{ '0', '9' }}),
            .space => try addAll(t.arena, &set, &.{ .{ 9, 13 }, .{ ' ', ' ' } }),
            .word => try addAll(t.arena, &set, &ascii_word),
        }
        if (p.negated) try t.negate(&set);
        try value.set.unionWith(t.arena, &set);
    }

    fn unicode(t: *Translator, value: *Value, u: Ast.Unicode, span: Ast.Span) Error!void {
        if (!t.codePoints()) return t.fail(span, .unicode_not_allowed);
        var set: CodePoints = .{};
        if (t.dialect == .rust) try t.rustProperty(&set, u, span) else try t.ecmaProperty(&set, u, span);
        // Rust and `v` fold what is named and take its complement; `u` complements first, and
        // the class closes after.
        if (t.dialect == .rust or t.dialect == .sets) try t.close(&set);
        if (u.negated) try t.negate(&set);
        try value.set.unionWith(t.arena, &set);
    }

    /// regex-syntax's order: `name=value`; alone, a binary property, a general category (with
    /// Any, ASCII and Assigned), then a script, by its Script_Extensions. Names compare loosely.
    fn rustProperty(t: *Translator, set: *CodePoints, u: Ast.Unicode, span: Ast.Span) Error!void {
        if (u.value) |v| {
            const property = properties.propertyNamed(u.name, .loose) orelse {
                if (unsupportedByValue(u.name)) return t.unsupported(span, .unsupported_unicode_property);
                return t.fail(span, .unicode_property_unknown);
            };
            switch (property) {
                .general_category => if (!try t.category(set, v, .loose)) return t.fail(span, .unicode_property_unknown),
                .script => try addAll(t.arena, set, properties.scriptRanges(properties.scriptNamed(v, .loose) orelse return t.fail(span, .unicode_property_unknown))),
                .script_extensions => try addAll(t.arena, set, properties.scriptExtensionRanges(properties.scriptNamed(v, .loose) orelse return t.fail(span, .unicode_property_unknown))),
                .binary => return t.fail(span, .unicode_property_unknown),
            }
            return;
        }
        if (properties.binaryNamed(u.name, .loose)) |b| return addAll(t.arena, set, properties.binaryRanges(b));
        if (try t.special(set, u.name, .loose)) return;
        if (try t.category(set, u.name, .loose)) return;
        const script = properties.scriptNamed(u.name, .loose) orelse return t.fail(span, .unicode_property_unknown);
        try addAll(t.arena, set, properties.scriptExtensionRanges(script));
    }

    /// The parser has held the name to ECMA-262's tables: what is left is finding it.
    fn ecmaProperty(t: *Translator, set: *CodePoints, u: Ast.Unicode, span: Ast.Span) Error!void {
        if (u.value) |v| {
            const property = properties.propertyNamed(u.name, .exact) orelse aegis.assert.never("the parser held the property to ECMA-262's table");
            switch (property) {
                .general_category => _ = try t.category(set, v, .exact),
                .script => try addAll(t.arena, set, properties.scriptRanges(properties.scriptNamed(v, .exact).?)),
                .script_extensions => try addAll(t.arena, set, properties.scriptExtensionRanges(properties.scriptNamed(v, .exact).?)),
                .binary => aegis.assert.never("the parser held `name=value` to the three properties that take a value"),
            }
            return;
        }
        if (try t.special(set, u.name, .exact)) return;
        if (try t.category(set, u.name, .exact)) return;
        if (properties.binaryNamed(u.name, .exact)) |b| return addAll(t.arena, set, properties.binaryRanges(b));
        // A property of strings: no sequences are tabulated here.
        return t.unsupported(span, .unsupported_unicode_property);
    }

    fn special(t: *Translator, set: *CodePoints, name: []const u8, match: properties.NameMatch) Error!bool {
        if (nameIs(name, "Any", match)) {
            try set.add(t.arena, .{ 0, 0x10ffff });
        } else if (nameIs(name, "ASCII", match)) {
            try set.add(t.arena, .{ 0, 0x7f });
        } else if (nameIs(name, "Assigned", match)) {
            try addAll(t.arena, set, properties.generalCategoryRanges(.unassigned));
            try set.negate(t.arena);
        } else return false;
        return true;
    }

    fn category(t: *Translator, set: *CodePoints, name: []const u8, match: properties.NameMatch) Error!bool {
        switch (properties.generalCategoryNamed(name, match) orelse return false) {
            .category => |c| try addAll(t.arena, set, properties.generalCategoryRanges(c)),
            .group => |g| try addAll(t.arena, set, properties.generalCategoryGroupRanges(g)),
        }
        return true;
    }

    fn asciiClass(t: *Translator, value: *Value, a: Ast.Ascii) Error!void {
        var set: CodePoints = .{};
        try addAll(t.arena, &set, asciiRanges(a.class));
        try t.close(&set);
        if (a.negated) try t.negate(&set);
        try value.set.unionWith(t.arena, &set);
    }

    fn scalarItem(t: *Translator, cp: u21, hex: bool, span: Ast.Span) Error!u21 {
        if (t.dialect == .annex_b and cp >= surrogates[0] and cp <= surrogates[1]) return t.unsupported(span, .unsupported_code_unit_split);
        if (t.codePoints() or cp <= 0x7f) return cp;
        if (hex) return cp;
        return t.fail(span, .unicode_not_allowed);
    }

    fn item(t: *Translator, value: *Value, it: Ast.ClassItem, span: Ast.Span) Error!void {
        switch (it) {
            .literal => |cp| {
                const c = try t.scalarItem(cp, false, span);
                try t.addLeaf(value, .{ c, c });
            },
            .byte => |b| {
                const c = try t.scalarItem(b, true, span);
                try t.addLeaf(value, .{ c, c });
            },
            .range => |r| try t.addLeaf(value, .{ try t.scalarItem(r[0], false, span), try t.scalarItem(r[1], false, span) }),
            .hex_range => |r| try t.addLeaf(value, .{ try t.scalarItem(r.ends[0], r.hex[0], span), try t.scalarItem(r.ends[1], r.hex[1], span) }),
            .perl => |p| try t.perl(value, p),
            .unicode => |u| try t.unicode(value, u, span),
            .ascii => |a| try t.asciiClass(value, a),
            .strings => |s| try t.strings(value, s),
            .nested, .operation => aegis.assert.never("the class walk opens nested classes and operations"),
        }
    }

    /// A range or character. Under `v` with `i` each closes as it is added: its operations
    /// are between sets already folded.
    fn addLeaf(t: *Translator, value: *Value, range: [2]u21) Error!void {
        if (t.dialect == .sets and t.flags.case_insensitive) {
            var set: CodePoints = .{};
            try set.add(t.arena, range);
            try t.close(&set);
            try value.set.unionWith(t.arena, &set);
        } else try value.set.add(t.arena, range);
    }

    fn strings(t: *Translator, value: *Value, slice_of: Ast.Slice) Error!void {
        for (t.ast.stringsOf(slice_of)) |s| {
            const original = t.ast.codePointsOf(s);
            if (original.len == 1) {
                try t.addLeaf(value, .{ original[0], original[0] });
                continue;
            }
            const folded = try t.arena.dupe(u21, original);
            if (t.flags.case_insensitive) for (folded) |*cp| {
                cp.* = xenoglyph.case.simpleFold(cp.*);
            };
            try value.strings.put(t.arena, std.mem.sliceAsBytes(folded), {});
        }
    }

    /// `[...]`, on a stack of its nested classes and operations.
    fn class(t: *Translator, b: Ast.Bracketed, span: Ast.Span) Error!Value {
        var stack: std.ArrayList(ClassFrame) = .empty;
        try stack.append(t.arena, .{ .items = t.ast.itemsOf(b.items), .done = .root });
        while (true) {
            const frame = &stack.items[stack.items.len - 1];
            if (frame.at < frame.items.len) {
                const it = frame.items[frame.at];
                frame.at += 1;
                switch (it) {
                    .nested => |n| try stack.append(t.arena, .{ .items = t.ast.itemsOf(n.items), .done = .{ .nested = n.negated } }),
                    .operation => |o| try stack.append(t.arena, .{ .items = t.ast.itemsOf(o.lhs), .done = .{ .lhs = o } }),
                    else => try t.item(&frame.value, it, span),
                }
                continue;
            }
            var value = frame.value;
            const done = frame.done;
            _ = stack.pop();
            switch (done) {
                .root => {
                    try t.close(&value.set);
                    if (b.negated) try t.negate(&value.set);
                    return value;
                },
                .nested => |negated| {
                    try t.close(&value.set);
                    if (negated) try t.negate(&value.set);
                    try merge(t.arena, &stack.items[stack.items.len - 1].value, &value);
                },
                .lhs => |o| {
                    try t.close(&value.set);
                    try stack.append(t.arena, .{ .items = t.ast.itemsOf(o.rhs), .done = .{ .rhs = .{ .op = o.op, .lhs = value } } });
                },
                .rhs => |r| {
                    try t.close(&value.set);
                    var left = r.lhs;
                    try combine(t.arena, &left, &value, r.op);
                    try merge(t.arena, &stack.items[stack.items.len - 1].value, &left);
                },
            }
        }
    }

    /// A finished class as a node: its strings longest first, the class at its own length of
    /// one, and the empty string last.
    fn emit(t: *Translator, value: *Value, span: Ast.Span) Error!Hir.Index {
        const set_node = try t.setNode(&value.set, span);
        if (value.strings.count() == 0) return set_node;
        var list: std.ArrayList([]const u21) = .empty;
        var it = value.strings.keyIterator();
        var empty_string = false;
        while (it.next()) |key| {
            if (key.len == 0) {
                empty_string = true;
                continue;
            }
            const copy = try t.arena.alloc(u21, key.len / @sizeOf(u21));
            @memcpy(std.mem.sliceAsBytes(copy), key.*);
            try list.append(t.arena, copy);
        }
        std.mem.sort([]const u21, list.items, {}, longerFirst);
        var alternatives: std.ArrayList(Hir.Index) = .empty;
        for (list.items) |string| try alternatives.append(t.arena, try t.stringNode(string, span));
        if (!value.set.isEmpty()) try alternatives.append(t.arena, set_node);
        if (empty_string) try alternatives.append(t.arena, try t.add(.empty));
        if (alternatives.items.len == 1) return alternatives.items[0];
        return t.add(.{ .alternation = try t.slice(alternatives.items) });
    }

    fn stringNode(t: *Translator, string: []const u21, span: Ast.Span) Error!Hir.Index {
        var parts: std.ArrayList(Hir.Index) = .empty;
        for (string) |cp| try parts.append(t.arena, try t.literal(cp, span));
        return t.concat(parts.items);
    }

    fn setNode(t: *Translator, set: *const CodePoints, span: Ast.Span) Error!Hir.Index {
        const items = set.items();
        if (t.codePoints()) {
            if (items.len == 1 and items[0][0] == items[0][1] and !(items[0][0] >= surrogates[0] and items[0][0] <= surrogates[1])) return t.encoded(items[0][0]);
            return t.add(.{ .unicode_class = items });
        }
        if (t.utf8 and items.len != 0 and items[items.len - 1][1] > 0x7f) return t.fail(span, .invalid_utf8_class);
        if (items.len == 1 and items[0][0] == items[0][1]) return t.add(.{ .literal = try t.arena.dupe(u8, &.{@intCast(items[0][0])}) });
        const bytes = try t.arena.alloc([2]u8, items.len);
        for (bytes, items) |*out, r| out.* = .{ @intCast(r[0]), @intCast(r[1]) };
        return t.add(.{ .byte_class = bytes });
    }
};

const ascii_word = [_][2]u21{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };

fn asciiRanges(class: Ast.AsciiClass) []const [2]u21 {
    return switch (class) {
        .alnum => &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } },
        .alpha => &.{ .{ 'A', 'Z' }, .{ 'a', 'z' } },
        .ascii => &.{.{ 0, 0x7f }},
        .blank => &.{ .{ '\t', '\t' }, .{ ' ', ' ' } },
        .cntrl => &.{ .{ 0, 0x1f }, .{ 0x7f, 0x7f } },
        .digit => &.{.{ '0', '9' }},
        .graph => &.{.{ '!', '~' }},
        .lower => &.{.{ 'a', 'z' }},
        .print => &.{.{ ' ', '~' }},
        .punct => &.{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } },
        .space => &.{ .{ '\t', '\r' }, .{ ' ', ' ' } },
        .upper => &.{.{ 'A', 'Z' }},
        .word => &ascii_word,
        .xdigit => &.{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } },
    };
}

fn addAll(arena: Allocator, set: *CodePoints, list: []const [2]u21) Allocator.Error!void {
    var other = try CodePoints.fromRanges(arena, list);
    try set.unionWith(arena, &other);
}

fn intersectBytes(arena: Allocator, set: *CodePoints) Allocator.Error!void {
    var bytes = try CodePoints.fromRanges(arena, &.{.{ 0, 0xff }});
    try set.intersect(arena, &bytes);
}

fn merge(arena: Allocator, into: *Value, from: *const Value) Allocator.Error!void {
    try into.set.unionWith(arena, &from.set);
    var it = from.strings.keyIterator();
    while (it.next()) |key| try into.strings.put(arena, key.*, {});
}

/// `left` op `right`, into `left`.
fn combine(arena: Allocator, left: *Value, right: *Value, op: @FieldType(Ast.Operation, "op")) Allocator.Error!void {
    switch (op) {
        .intersection => try left.set.intersect(arena, &right.set),
        .difference => try left.set.subtract(arena, &right.set),
        .symmetric_difference => try left.set.symmetricDifference(arena, &right.set),
    }
    var doomed: std.ArrayList([]const u8) = .empty;
    var it = left.strings.keyIterator();
    while (it.next()) |key| {
        const in_right = right.strings.contains(key.*);
        if ((op == .intersection and !in_right) or (op == .difference and in_right)) try doomed.append(arena, key.*);
    }
    for (doomed.items) |key| _ = left.strings.remove(key);
}

fn longerFirst(_: void, a: []const u21, b: []const u21) bool {
    if (a.len != b.len) return a.len > b.len;
    return std.mem.order(u21, a, b) == .lt;
}

fn isLead(cp: u21) bool {
    return cp >= 0xd800 and cp <= 0xdbff;
}

fn isTrail(cp: u21) bool {
    return cp >= 0xdc00 and cp <= 0xdfff;
}

/// The properties Rust's regex takes `name=value` for that have no data here.
fn unsupportedByValue(name: []const u8) bool {
    for ([_][]const u8{ "age", "gcb", "graphemeclusterbreak", "wb", "wordbreak", "sb", "sentencebreak" }) |known| {
        if (looseIs(name, known)) return true;
    }
    return false;
}

fn nameIs(name: []const u8, wanted: []const u8, match: properties.NameMatch) bool {
    return switch (match) {
        .exact => std.mem.eql(u8, name, wanted),
        .loose => looseIs(name, wanted),
    };
}

/// `name` equal to `wanted` ignoring case, spaces, hyphens and underscores.
fn looseIs(name: []const u8, wanted: []const u8) bool {
    var i: usize = 0;
    for (name) |c| {
        if (c == ' ' or c == '_' or c == '-') continue;
        if (i == wanted.len or std.ascii.toLower(c) != std.ascii.toLower(wanted[i])) return false;
        i += 1;
    }
    return i == wanted.len;
}
