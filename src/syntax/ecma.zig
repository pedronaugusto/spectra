//! The ECMAScript dialect: ECMA-262's RegExp pattern grammar (the 2025 edition, with modifiers,
//! duplicate group names in separate alternatives, and `v`'s class set expressions) into the
//! same `Ast` the Rust dialect gives. Without `u` or `v` it reads Annex B's grammar, as every
//! web engine does and test262's annexB cases check: `]`, `{` and `}` alone stand for
//! themselves, so do an unknown escape and `\8`, and `\N` past the pattern's groups is an octal
//! escape. Backreferences, lookbehind and lookarounds inside lookarounds are read into the
//! `Ast` like everything else; what spectra cannot run is refused when the `Ast` is translated.
//! So a pattern this reads is a valid ECMA-262 pattern, which is what `validate` asks.
//!
//! The pattern is UTF-8, where ECMA-262's source text is UTF-16: a lone surrogate cannot be
//! written but as an escape. Without `u` or `v`, ECMA-262 reads a code point past U+FFFF as its
//! two UTF-16 code units; so does this, as two literals.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Limits = @import("../Limits.zig");
const diagnostic_zig = @import("diagnostic.zig");
const Diagnostic = diagnostic_zig.Diagnostic;
const Reason = diagnostic_zig.Reason;
const Error = diagnostic_zig.Error;
const properties = xenoglyph.properties;

/// The grammar the flags ask for: `u`'s, `v`'s, or without either, Annex B's.
pub const Mode = enum { annex_b, unicode, unicode_sets };

/// Reads `pattern`, whose length the caller has checked, for compiling: a repetition's count
/// past `limits.repetition` is too large. Nodes are in `arena`, which the `Ast` borrows.
pub fn read(arena: Allocator, pattern: []const u8, mode: Mode, limits: Limits, diagnostic: ?*Diagnostic) Error!Ast {
    var p: Parser = .init(arena, pattern, mode, limits, diagnostic, false);
    return p.run();
}

/// Whether `pattern`, with `flags` (any of `dgimsuvy`, each once, not both `u` and `v`), is a
/// valid ECMA-262 pattern, whether or not spectra can run it. A count is any count, as ECMA-262
/// has it; `limits.pattern` and `limits.nesting` still bound what is read, and past them the
/// answer is `error.TooLarge`, not a verdict. A refusal's reason and span go to `diagnostic`;
/// for `regexp_flag_invalid` the span is in `flags`.
pub fn validate(gpa: Allocator, pattern: aegis.input.Untrusted([]const u8), flags: []const u8, limits: Limits, diagnostic: ?*Diagnostic) error{ OutOfMemory, TooLarge }!bool {
    const mode = readFlags(flags, diagnostic) orelse return false;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const context: Validation = .{ .arena = arena_state.allocator(), .mode = mode, .limits = limits, .diagnostic = diagnostic };
    _ = pattern.parse(context, validateTrusted) catch |err| switch (err) {
        error.Invalid => return false,
        error.OutOfMemory, error.TooLarge => |e| return e,
    };
    return true;
}

const Validation = struct {
    arena: Allocator,
    mode: Mode,
    limits: Limits,
    diagnostic: ?*Diagnostic,
};

/// A pattern `validate` has read: its `Ast`, kept no longer than the call.
const Valid = struct { ast: Ast };

fn validateTrusted(c: Validation, pattern: []const u8) Error!Valid {
    if (pattern.len > c.limits.pattern.raw()) {
        if (c.diagnostic) |d| d.* = .{ .span = .{ .start = 0, .end = 0 }, .reason = .pattern_too_long };
        return error.TooLarge;
    }
    var p: Parser = .init(c.arena, pattern, c.mode, c.limits, c.diagnostic, true);
    return .{ .ast = try p.run() };
}

/// The mode `flags` ask for, or null (and the diagnostic) where they are not RegExp flags.
fn readFlags(flags: []const u8, diagnostic: ?*Diagnostic) ?Mode {
    const known = "dgimsuvy";
    var seen: [known.len]bool = @splat(false);
    for (flags, 0..) |c, i| {
        const at: u32 = @intCast(@min(i, std.math.maxInt(u32) - 1));
        const index = std.mem.indexOfScalar(u8, known, c) orelse return flagFailure(diagnostic, at);
        if (seen[index]) return flagFailure(diagnostic, at);
        seen[index] = true;
    }
    const u = seen[std.mem.indexOfScalar(u8, known, 'u').?];
    const v = seen[std.mem.indexOfScalar(u8, known, 'v').?];
    if (u and v) return flagFailure(diagnostic, @intCast(@min(std.mem.lastIndexOfAny(u8, flags, "uv").?, std.math.maxInt(u32) - 1)));
    return if (v) .unicode_sets else if (u) .unicode else .annex_b;
}

fn flagFailure(diagnostic: ?*Diagnostic, at: u32) ?Mode {
    if (diagnostic) |d| d.* = .{ .span = .{ .start = at, .end = at + 1 }, .reason = .regexp_flag_invalid };
    return null;
}

const Pending = union(enum) {
    capture: struct { index: u32, name: ?[]const u8 },
    non_capturing: Ast.Flags,
    lookaround: struct { direction: @FieldType(Ast.Lookaround, "direction"), negated: bool },
};

const Names = std.StringHashMapUnmanaged(void);

const Frame = struct {
    /// Where the group opened (its `(`), and what it is; null for the pattern itself.
    open: u32,
    group: ?Pending,
    alternatives: std.ArrayList(Ast.Index) = .empty,
    items: std.ArrayList(Ast.Index) = .empty,
    alternative_start: u32,
    /// The group names of the alternative being read, and of those before it: a name may be
    /// given again only where the two cannot both take part in a match, in another alternative.
    current: Names = .empty,
    finished: Names = .empty,
};

const Quantifier = struct { min: u32, max: ?u32 };

/// One class atom outside `v`: a character, or a class escape.
const ClassAtom = union(enum) {
    char: u21,
    class: Ast.ClassItem,
};

/// `\p{...}` read: the class, and whether it holds strings (a property of strings, under `v`).
const Property = struct { unicode: Ast.Unicode, strings: bool };

const Reference = struct { name: []const u8, span: Ast.Span };

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    mode: Mode,
    limits: Limits,
    diagnostic: ?*Diagnostic,
    /// Reading for `validate`: counts are any size.
    validating: bool,
    at: u32 = 0,
    nodes: std.ArrayList(Ast.Node) = .empty,
    class_items: std.ArrayList(Ast.ClassItem) = .empty,
    children: std.ArrayList(Ast.Index) = .empty,
    strings: std.ArrayList(Ast.Slice) = .empty,
    code_points: std.ArrayList(u21) = .empty,
    captures: u32 = 0,
    /// Every capturing group of the pattern, counted before it is read: Annex B reads `\N` past
    /// them as an octal escape, and `u` refuses it.
    total_captures: u32,
    /// The pattern names a group, so `\k` is a reference without `u` or `v` too.
    named: bool,
    /// Every group name, for the references, which may come before the group.
    names: Names = .empty,
    references: std.ArrayList(Reference) = .empty,
    /// Outside `v`, a class's code point past U+FFFF without `u` is two code units: the second,
    /// read next.
    trail: ?u21 = null,

    fn init(arena: Allocator, pattern: []const u8, mode: Mode, limits: Limits, diagnostic: ?*Diagnostic, validating: bool) Parser {
        const counted = prescan(pattern, mode);
        return .{
            .arena = arena,
            .pattern = pattern,
            .mode = mode,
            .limits = limits,
            .diagnostic = diagnostic,
            .validating = validating,
            .total_captures = counted.captures,
            .named = counted.named or mode != .annex_b,
        };
    }

    fn unicode(p: *const Parser) bool {
        return p.mode != .annex_b;
    }

    fn fail(p: *Parser, start: u32, stop: u32, reason: Reason) error{Invalid} {
        if (p.diagnostic) |d| d.* = .{ .span = .{ .start = start, .end = @min(stop, @as(u32, @intCast(p.pattern.len))) }, .reason = reason };
        return error.Invalid;
    }

    fn tooLarge(p: *Parser, start: u32, reason: Reason) error{TooLarge} {
        if (p.diagnostic) |d| d.* = .{ .span = .{ .start = start, .end = p.at }, .reason = reason };
        return error.TooLarge;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.at >= p.pattern.len) null else p.pattern[p.at];
    }

    fn peekAt(p: *const Parser, offset: u32) ?u8 {
        const i = @as(usize, p.at) + offset;
        return if (i >= p.pattern.len) null else p.pattern[i];
    }

    fn startsWith(p: *const Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, p.pattern[p.at..], text);
    }

    /// The code point at the cursor, decoded and taken.
    fn take(p: *Parser) Error!u21 {
        const start = p.at;
        const n = std.unicode.utf8ByteSequenceLength(p.pattern[p.at]) catch return p.fail(start, start + 1, .invalid_utf8);
        if (@as(usize, p.at) + n > p.pattern.len) return p.fail(start, @intCast(p.pattern.len), .invalid_utf8);
        const cp = std.unicode.utf8Decode(p.pattern[p.at..][0..n]) catch return p.fail(start, start + n, .invalid_utf8);
        p.at += n;
        return cp;
    }

    fn add(p: *Parser, start: u32, kind: Ast.Kind) Error!Ast.Index {
        const index: Ast.Index = @fromBackingInt(@intCast(p.nodes.items.len));
        try p.nodes.append(p.arena, .{ .span = .{ .start = start, .end = p.at }, .kind = kind });
        return index;
    }

    /// A code point as the literals it reads as: itself, or without `u` or `v` and past U+FFFF,
    /// its two UTF-16 code units.
    fn literal(p: *Parser, items: *std.ArrayList(Ast.Index), start: u32, cp: u21) Error!void {
        if (cp > 0xffff and !p.unicode()) {
            const units = surrogates(cp);
            try items.append(p.arena, try p.add(start, .{ .literal = units[0] }));
            try items.append(p.arena, try p.add(start, .{ .literal = units[1] }));
            return;
        }
        try items.append(p.arena, try p.add(start, .{ .literal = cp }));
    }

    fn sequence(p: *Parser, start: u32, items: []const Ast.Index) Error!Ast.Index {
        if (items.len == 0) return p.add(start, .empty);
        if (items.len == 1) return items[0];
        const slice: Ast.Slice = .{ .start = @intCast(p.children.items.len), .len = @intCast(items.len) };
        try p.children.appendSlice(p.arena, items);
        return p.add(start, .{ .concat = slice });
    }

    fn finish(p: *Parser, frame: *Frame, start: u32) Error!Ast.Index {
        const last = try p.sequence(frame.alternative_start, frame.items.items);
        if (frame.alternatives.items.len == 0) return last;
        try frame.alternatives.append(p.arena, last);
        const slice: Ast.Slice = .{ .start = @intCast(p.children.items.len), .len = @intCast(frame.alternatives.items.len) };
        try p.children.appendSlice(p.arena, frame.alternatives.items);
        return p.add(start, .{ .alternation = slice });
    }

    fn merge(p: *Parser, into: *Names, from: Names) Error!void {
        var it = from.keyIterator();
        while (it.next()) |name| try into.put(p.arena, name.*, {});
    }

    fn run(p: *Parser) Error!Ast {
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(p.arena, .{ .open = 0, .group = null, .alternative_start = 0 });
        while (true) {
            const frame = &stack.items[stack.items.len - 1];
            const start = p.at;
            const b = p.peek() orelse break;
            switch (b) {
                '(' => {
                    if (stack.items.len > p.limits.nesting.raw()) return p.tooLarge(start, .nesting_too_deep);
                    p.at += 1;
                    const opened = try p.groupOpening(start, stack.items);
                    try stack.append(p.arena, opened);
                },
                ')' => {
                    if (stack.items.len == 1) return p.fail(start, start + 1, .unopened_group);
                    p.at += 1;
                    var closed = stack.pop().?;
                    const sub = try p.finish(&closed, closed.open + 1);
                    const parent = &stack.items[stack.items.len - 1];
                    try p.merge(&parent.current, closed.finished);
                    try p.merge(&parent.current, closed.current);
                    const kind: Ast.Kind = switch (closed.group.?) {
                        .capture => |cap| .{ .group = .{ .kind = .{ .capture = .{ .index = cap.index, .name = cap.name } }, .sub = sub } },
                        .non_capturing => |set| .{ .group = .{ .kind = .{ .non_capturing = set }, .sub = sub } },
                        .lookaround => |look| .{ .lookaround = .{ .direction = look.direction, .negated = look.negated, .sub = sub } },
                    };
                    try parent.items.append(p.arena, try p.add(closed.open, kind));
                },
                '|' => {
                    p.at += 1;
                    try frame.alternatives.append(p.arena, try p.sequence(frame.alternative_start, frame.items.items));
                    frame.items.clearRetainingCapacity();
                    frame.alternative_start = p.at;
                    try p.merge(&frame.finished, frame.current);
                    frame.current.clearRetainingCapacity();
                },
                '*', '+', '?' => {
                    p.at += 1;
                    const q: Quantifier = switch (b) {
                        '*' => .{ .min = 0, .max = null },
                        '+' => .{ .min = 1, .max = null },
                        else => .{ .min = 0, .max = 1 },
                    };
                    try p.quantify(frame, start, q);
                },
                '{' => {
                    if (try p.braced()) |q| {
                        try p.quantify(frame, start, q);
                    } else {
                        if (p.unicode()) return p.fail(start, start + 1, .lone_syntax_character);
                        p.at += 1;
                        try frame.items.append(p.arena, try p.add(start, .{ .literal = '{' }));
                    }
                },
                '}', ']' => {
                    if (p.unicode()) return p.fail(start, start + 1, .lone_syntax_character);
                    p.at += 1;
                    try frame.items.append(p.arena, try p.add(start, .{ .literal = b }));
                },
                '[' => {
                    const bracketed = if (p.mode == .unicode_sets) try p.classSet() else try p.class();
                    try frame.items.append(p.arena, try p.add(start, .{ .bracketed = bracketed }));
                },
                '.' => {
                    p.at += 1;
                    try frame.items.append(p.arena, try p.add(start, .dot));
                },
                '^' => {
                    p.at += 1;
                    try frame.items.append(p.arena, try p.add(start, .{ .assertion = .start_line }));
                },
                '$' => {
                    p.at += 1;
                    try frame.items.append(p.arena, try p.add(start, .{ .assertion = .end_line }));
                },
                '\\' => try p.atomEscape(frame),
                else => try p.literal(&frame.items, start, try p.take()),
            }
        }
        if (stack.items.len > 1) {
            const open = stack.items[stack.items.len - 1].open;
            return p.fail(open, open + 1, .unclosed_group);
        }
        for (p.references.items) |reference| {
            if (!p.names.contains(reference.name)) return p.fail(reference.span.start, reference.span.end, .backreference_undefined);
        }
        const root = try p.finish(&stack.items[0], 0);
        return .{
            .nodes = try p.nodes.toOwnedSlice(p.arena),
            .class_items = try p.class_items.toOwnedSlice(p.arena),
            .children = try p.children.toOwnedSlice(p.arena),
            .root = root,
            .captures = p.captures,
            .strings = try p.strings.toOwnedSlice(p.arena),
            .code_points = try p.code_points.toOwnedSlice(p.arena),
        };
    }

    /// After `(`: a capture, named or not, a non-capturing group with modifiers or none, or a
    /// lookaround. A group's name joins the alternative it is read in.
    fn groupOpening(p: *Parser, start: u32, stack: []Frame) Error!Frame {
        if (p.peek() != '?') {
            p.captures += 1;
            return .{ .open = start, .group = .{ .capture = .{ .index = p.captures, .name = null } }, .alternative_start = p.at };
        }
        p.at += 1;
        const c = p.peek() orelse return p.fail(start, p.at, .unclosed_group);
        switch (c) {
            ':' => {
                p.at += 1;
                return .{ .open = start, .group = .{ .non_capturing = .{} }, .alternative_start = p.at };
            },
            '=', '!' => {
                p.at += 1;
                return .{ .open = start, .group = .{ .lookaround = .{ .direction = .ahead, .negated = c == '!' } }, .alternative_start = p.at };
            },
            '<' => {
                if (p.peekAt(1) == '=' or p.peekAt(1) == '!') {
                    const negated = p.peekAt(1) == '!';
                    p.at += 2;
                    return .{ .open = start, .group = .{ .lookaround = .{ .direction = .behind, .negated = negated } }, .alternative_start = p.at };
                }
                p.at += 1;
                const name_start = p.at;
                const name = try p.groupName();
                for (stack) |*f| if (f.current.contains(name)) return p.fail(name_start, p.at - 1, .group_name_duplicate);
                try stack[stack.len - 1].current.put(p.arena, name, {});
                try p.names.put(p.arena, name, {});
                p.captures += 1;
                return .{ .open = start, .group = .{ .capture = .{ .index = p.captures, .name = name } }, .alternative_start = p.at };
            },
            'i', 'm', 's', '-' => {
                const set = try p.modifiers(start);
                return .{ .open = start, .group = .{ .non_capturing = set }, .alternative_start = p.at };
            },
            else => return p.fail(start, p.at + 1, .group_opening_invalid),
        }
    }

    /// `ims-ims:` after `(?`: each flag once, not both sides empty.
    fn modifiers(p: *Parser, start: u32) Error!Ast.Flags {
        var out: Ast.Flags = .{};
        var seen: Ast.Flags.Set = .{};
        var removing = false;
        while (true) {
            const at = p.at;
            const c = p.peek() orelse return p.fail(start, p.at, .unclosed_group);
            p.at += 1;
            if (c == ':') {
                if (removing and @as(u8, @bitCast(out.set)) == 0 and @as(u8, @bitCast(out.clear)) == 0) return p.fail(start, p.at, .flags_empty);
                return out;
            }
            if (c == '-') {
                if (removing) return p.fail(at, at + 1, .flag_repeated);
                removing = true;
                continue;
            }
            var one: Ast.Flags.Set = .{};
            switch (c) {
                'i' => one.case_insensitive = true,
                'm' => one.multi_line = true,
                's' => one.dot_matches_new_line = true,
                else => return p.fail(at, at + 1, .flag_unrecognized),
            }
            const bit: u8 = @bitCast(one);
            if (@as(u8, @bitCast(seen)) & bit != 0) return p.fail(at, at + 1, .flag_repeated);
            seen = @bitCast(@as(u8, @bitCast(seen)) | bit);
            if (removing) out.clear = @bitCast(@as(u8, @bitCast(out.clear)) | bit) else out.set = @bitCast(@as(u8, @bitCast(out.set)) | bit);
        }
    }

    /// A group name and its `>`: an identifier (ID_Start, `$` or `_`, then ID_Continue, `$`,
    /// ZWNJ or ZWJ), any of its code points written `\u` as under `u`. Borrowed from the pattern
    /// where it has no escape, else written out in the arena.
    fn groupName(p: *Parser) Error![]const u8 {
        const name_start = p.at;
        var written: ?std.ArrayList(u8) = null;
        var first = true;
        while (true) {
            const at = p.at;
            const b = p.peek() orelse return p.fail(name_start, p.at, .group_name_invalid);
            if (b == '>') break;
            var escaped = false;
            const cp = if (b == '\\') blk: {
                p.at += 1;
                if (p.peek() != 'u') return p.fail(at, p.at, .group_name_invalid);
                escaped = true;
                break :blk try p.unicodeEscape(true) orelse return p.fail(at, p.at + 1, .group_name_invalid);
            } else try p.take();
            const fits = if (first)
                cp == '$' or cp == '_' or properties.core(cp).id_start
            else
                cp == '$' or cp == 0x200c or cp == 0x200d or properties.core(cp).id_continue;
            if (!fits) return p.fail(at, p.at, .group_name_invalid);
            if (escaped and written == null) {
                written = .empty;
                try written.?.appendSlice(p.arena, p.pattern[name_start..at]);
            }
            if (written) |*w| {
                if (!escaped) try w.appendSlice(p.arena, p.pattern[at..p.at]) else {
                    var bytes: [4]u8 = undefined;
                    // A surrogate is no identifier's: `fits` refused it.
                    const n = std.unicode.utf8Encode(cp, &bytes) catch aegis.assert.never("an identifier's code point is a scalar value");
                    try w.appendSlice(p.arena, bytes[0..n]);
                }
            }
            first = false;
        }
        if (first) return p.fail(name_start, p.at + 1, .group_name_invalid);
        const name = if (written) |w| w.items else p.pattern[name_start..p.at];
        p.at += 1;
        return name;
    }

    /// `{n}`, `{n,}` or `{n,m}` at the cursor, taken; null, the cursor left, where the brace
    /// begins none.
    fn braced(p: *Parser) Error!?Quantifier {
        const start = p.at;
        const min_end = digitsEnd(p.pattern, start + 1);
        if (min_end == start + 1) return null;
        const min_digits = p.pattern[start + 1 .. min_end];
        var max_digits: ?[]const u8 = min_digits;
        var close = min_end;
        if (close < p.pattern.len and p.pattern[close] == ',') {
            const max_end = digitsEnd(p.pattern, close + 1);
            max_digits = if (max_end == close + 1) null else p.pattern[close + 1 .. max_end];
            close = max_end;
        }
        if (close >= p.pattern.len or p.pattern[close] != '}') return null;
        p.at = close + 1;
        if (max_digits) |m| if (lessDigits(m, min_digits)) return p.fail(start, p.at, .repetition_count_out_of_order);
        const min = try p.count(start, min_digits);
        const max = if (max_digits) |m| try p.count(start, m) else null;
        return .{ .min = min, .max = max };
    }

    /// A count: compiling, refused past the limit; validating, any count, held to `maxInt(u32)`.
    fn count(p: *Parser, start: u32, digits: []const u8) Error!u32 {
        var value: u64 = 0;
        for (digits) |d| {
            value = @min(value * 10 + (d - '0'), std.math.maxInt(u32));
            if (!p.validating and value > p.limits.repetition.raw()) return p.tooLarge(start, .repetition_count_too_large);
        }
        return @intCast(value);
    }

    /// Applies a quantifier read from `start` (with a `?` after it for lazy) to the last item.
    /// An assertion, a lookbehind or a repetition takes none; a lookahead only under Annex B.
    fn quantify(p: *Parser, frame: *Frame, start: u32, q: Quantifier) Error!void {
        var greedy = true;
        if (p.peek() == '?') {
            p.at += 1;
            greedy = false;
        }
        const target = frame.items.getLastOrNull() orelse return p.fail(start, p.at, .repetition_missing);
        const node = p.nodes.items[@backingInt(target)];
        const quantifiable = switch (node.kind) {
            .assertion, .repetition => false,
            .lookaround => |look| look.direction == .ahead and !p.unicode(),
            else => true,
        };
        if (!quantifiable) return p.fail(start, p.at, .repetition_missing);
        _ = frame.items.pop();
        try frame.items.append(p.arena, try p.add(node.span.start, .{ .repetition = .{ .min = q.min, .max = q.max, .greedy = greedy, .sub = target } }));
    }

    /// After `\` outside a class.
    fn atomEscape(p: *Parser, frame: *Frame) Error!void {
        const start = p.at;
        p.at += 1;
        const c = p.peek() orelse return p.fail(start, p.at, .escape_unexpected_end);
        switch (c) {
            'b', 'B' => {
                p.at += 1;
                try frame.items.append(p.arena, try p.add(start, .{ .assertion = if (c == 'b') .word_boundary else .not_word_boundary }));
            },
            '1'...'9' => {
                const digits = p.at;
                p.at = digitsEnd(p.pattern, digits);
                const n = saturated(p.pattern[digits..p.at]);
                if (n <= p.total_captures) {
                    try frame.items.append(p.arena, try p.add(start, .{ .backreference = .{ .number = n } }));
                    return;
                }
                if (p.unicode()) return p.fail(start, p.at, .backreference_undefined);
                // Annex B: past the groups, an octal escape, or `\8` and `\9` themselves.
                p.at = digits;
                try p.literal(&frame.items, start, try p.characterEscape(start, false));
            },
            'k' => {
                if (!p.named) {
                    p.at += 1;
                    try frame.items.append(p.arena, try p.add(start, .{ .literal = 'k' }));
                    return;
                }
                p.at += 1;
                if (p.peek() != '<') return p.fail(start, p.at, .named_reference_invalid);
                p.at += 1;
                const name = try p.groupName();
                try p.references.append(p.arena, .{ .name = name, .span = .{ .start = start, .end = p.at } });
                try frame.items.append(p.arena, try p.add(start, .{ .backreference = .{ .name = name } }));
            },
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.at += 1;
                try frame.items.append(p.arena, try p.add(start, .{ .perl = perl(c) }));
            },
            'p', 'P' => {
                if (p.unicode()) {
                    const property = try p.propertyEscape(start);
                    try frame.items.append(p.arena, try p.add(start, .{ .unicode = property.unicode }));
                    return;
                }
                p.at += 1;
                try frame.items.append(p.arena, try p.add(start, .{ .literal = c }));
            },
            else => try p.literal(&frame.items, start, try p.characterEscape(start, false)),
        }
    }

    /// A CharacterEscape, the cursor after its `\` at `start`: a control, `\cX`, `\0`, `\xHH`,
    /// `\u`, or an identity escape; under Annex B a legacy octal escape too. Annex B's `\c`
    /// before what it cannot take is the backslash alone, the `c` left to be read.
    fn characterEscape(p: *Parser, start: u32, in_class: bool) Error!u21 {
        const c = p.peek() orelse return p.fail(start, p.at, .escape_unexpected_end);
        switch (c) {
            'f', 'n', 'r', 't', 'v' => {
                p.at += 1;
                return switch (c) {
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => 0x0b,
                };
            },
            'c' => {
                const next = p.peekAt(1);
                if (next != null and std.ascii.isAlphabetic(next.?)) {
                    p.at += 2;
                    return next.? % 32;
                }
                if (in_class and !p.unicode() and next != null and (std.ascii.isDigit(next.?) or next.? == '_')) {
                    p.at += 2;
                    return next.? % 32;
                }
                if (p.unicode()) return p.fail(start, p.at + 1, .escape_unrecognized);
                return '\\';
            },
            '0' => {
                const next = p.peekAt(1);
                if (next == null or !std.ascii.isDigit(next.?)) {
                    p.at += 1;
                    return 0;
                }
                if (p.unicode()) return p.fail(start, p.at + 2, .escape_unrecognized);
                return p.octal();
            },
            '1'...'9' => {
                if (p.unicode()) return p.fail(start, p.at + 1, .escape_unrecognized);
                if (c <= '7') return p.octal();
                p.at += 1;
                return c;
            },
            'x' => {
                if (hexValue(p.pattern, p.at + 1, 2)) |v| {
                    p.at += 3;
                    return v;
                }
                if (p.unicode()) return p.fail(start, p.at + 1, .escape_hex_invalid);
                p.at += 1;
                return 'x';
            },
            'u' => {
                if (try p.unicodeEscape(p.unicode())) |v| return v;
                if (p.unicode()) return p.fail(start, p.at + 1, .escape_hex_invalid);
                p.at += 1;
                return 'u';
            },
            else => {
                if (p.unicode()) {
                    if (std.mem.indexOfScalar(u8, "^$\\.*+?()[]{}|/", c) == null) return p.fail(start, p.at + 1, .escape_unrecognized);
                    p.at += 1;
                    return c;
                }
                if (c == 'k' and p.named) return p.fail(start, p.at + 1, .escape_unrecognized);
                return p.take();
            },
        }
    }

    /// Annex B's LegacyOctalEscapeSequence: up to three octal digits, no more than `\377`.
    fn octal(p: *Parser) u21 {
        const first = p.peek().? - '0';
        var value: u21 = first;
        p.at += 1;
        const most: u32 = if (first <= 3) 3 else 2;
        var n: u32 = 1;
        while (n < most) : (n += 1) {
            const d = p.peek() orelse break;
            if (d < '0' or d > '7') break;
            value = value * 8 + (d - '0');
            p.at += 1;
        }
        return value;
    }

    /// `\u` at the cursor (on the `u`): `uHHHH`, and as `u` reads them (`unicode`), `u{H...}`
    /// and a surrogate pair `uHHHH\uHHHH` as one code point. Null, the cursor left, where it is
    /// none of these.
    fn unicodeEscape(p: *Parser, unicode_mode: bool) Error!?u21 {
        const start = p.at;
        if (unicode_mode and p.peekAt(1) == '{') {
            var i: usize = p.at + 2;
            var value: u32 = 0;
            while (i < p.pattern.len and p.pattern[i] != '}') : (i += 1) {
                const d = std.fmt.charToDigit(p.pattern[i], 16) catch return null;
                value = value * 16 + d;
                if (value > 0x10ffff) return p.fail(start - 1, @intCast(i + 1), .code_point_invalid);
            }
            if (i >= p.pattern.len or i == p.at + 2) return null;
            p.at = @intCast(i + 1);
            return @intCast(value);
        }
        const value = hexValue(p.pattern, p.at + 1, 4) orelse return null;
        p.at += 5;
        if (unicode_mode and value >= 0xd800 and value <= 0xdbff and p.startsWith("\\u")) {
            if (hexValue(p.pattern, p.at + 2, 4)) |trail| if (trail >= 0xdc00 and trail <= 0xdfff) {
                p.at += 6;
                return @intCast(0x10000 + ((@as(u32, value) - 0xd800) << 10) + (trail - 0xdc00));
            };
        }
        return value;
    }

    /// `\p{...}` or `\P{...}`, the cursor on the `p`: `Name=Value` or a lone name or value, held
    /// to ECMA-262's tables exactly.
    fn propertyEscape(p: *Parser, start: u32) Error!Property {
        const negated = p.peek() == 'P';
        p.at += 1;
        if (p.peek() != '{') return p.fail(start, p.at, .unicode_class_invalid);
        p.at += 1;
        const name_start = p.at;
        while (p.peek()) |c| : (p.at += 1) if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
        const name = p.pattern[name_start..p.at];
        var value: ?[]const u8 = null;
        if (p.peek() == '=') {
            p.at += 1;
            const value_start = p.at;
            while (p.peek()) |c| : (p.at += 1) if (!(std.ascii.isAlphanumeric(c) or c == '_')) break;
            value = p.pattern[value_start..p.at];
        }
        if (p.peek() != '}' or name.len == 0 or (value != null and value.?.len == 0)) return p.fail(start, p.at + 1, .unicode_class_invalid);
        p.at += 1;
        const out: Property = .{ .unicode = .{ .name = name, .value = value, .negated = negated }, .strings = false };
        if (value) |v| {
            const known = if (std.mem.eql(u8, name, "General_Category") or std.mem.eql(u8, name, "gc"))
                properties.generalCategoryNamed(v, .exact) != null
            else if (std.mem.eql(u8, name, "Script") or std.mem.eql(u8, name, "sc") or std.mem.eql(u8, name, "Script_Extensions") or std.mem.eql(u8, name, "scx"))
                properties.scriptNamed(v, .exact) != null
            else
                false;
            if (!known) return p.fail(start, p.at, .unicode_property_unknown);
            return out;
        }
        if (properties.generalCategoryNamed(name, .exact) != null or binaryProperty(name)) return out;
        if (p.mode == .unicode_sets and stringProperty(name)) {
            if (negated) return p.fail(start, p.at, .class_strings_negated);
            return .{ .unicode = out.unicode, .strings = true };
        }
        return p.fail(start, p.at, .unicode_property_unknown);
    }

    // -------------------------------------------------------------------------------------
    // Classes without `v`

    /// `[...]`: atoms and ranges. Without `u`, a range's end that is a class stands for itself,
    /// and so does the `-` between.
    fn class(p: *Parser) Error!Ast.Bracketed {
        const start = p.at;
        p.at += 1;
        var negated = false;
        if (p.peek() == '^') {
            p.at += 1;
            negated = true;
        }
        var items: std.ArrayList(Ast.ClassItem) = .empty;
        while (true) {
            if (p.trail == null) {
                const b = p.peek() orelse return p.fail(start, p.at, .unclosed_class);
                if (b == ']') {
                    p.at += 1;
                    break;
                }
            }
            const atom_start = p.at;
            const first = try p.classAtom();
            if (p.trail == null and p.peek() == '-' and p.peekAt(1) != null and p.peekAt(1) != ']') {
                p.at += 1;
                const last = try p.classAtom();
                if (first == .class or last == .class) {
                    if (p.unicode()) return p.fail(atom_start, p.at, .class_range_bad_end);
                    try items.append(p.arena, classItem(first));
                    try items.append(p.arena, .{ .literal = '-' });
                    try items.append(p.arena, classItem(last));
                    continue;
                }
                if (last.char < first.char) return p.fail(atom_start, p.at, .class_range_out_of_order);
                try items.append(p.arena, .{ .range = .{ first.char, last.char } });
                continue;
            }
            try items.append(p.arena, classItem(first));
        }
        const slice: Ast.ItemSlice = .{ .start = @intCast(p.class_items.items.len), .len = @intCast(items.items.len) };
        try p.class_items.appendSlice(p.arena, items.items);
        return .{ .negated = negated, .items = slice };
    }

    fn classAtom(p: *Parser) Error!ClassAtom {
        if (p.trail) |t| {
            p.trail = null;
            return .{ .char = t };
        }
        if (p.peek() != '\\') return .{ .char = p.unit(try p.take()) };
        const start = p.at;
        p.at += 1;
        const c = p.peek() orelse return p.fail(start, p.at, .escape_unexpected_end);
        switch (c) {
            'b' => {
                p.at += 1;
                return .{ .char = 0x08 };
            },
            '-' => {
                p.at += 1;
                return .{ .char = '-' };
            },
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.at += 1;
                return .{ .class = .{ .perl = perl(c) } };
            },
            'p', 'P' => if (p.unicode()) return .{ .class = .{ .unicode = (try p.propertyEscape(start)).unicode } },
            else => {},
        }
        return .{ .char = p.unit(try p.characterEscape(start, true)) };
    }

    /// A class's code point as its first code unit without `u`, the second kept for next.
    fn unit(p: *Parser, cp: u21) u21 {
        if (cp <= 0xffff or p.unicode()) return cp;
        const units = surrogates(cp);
        p.trail = units[1];
        return units[0];
    }

    // -------------------------------------------------------------------------------------
    // Classes under `v`

    const Shape = enum { none, union_, intersection, difference };

    /// One class level under `v`: a union, or a chain of one operator, never both.
    const SetLevel = struct {
        start: u32,
        negated: bool,
        items: std.ArrayList(Ast.ClassItem) = .empty,
        lhs: ?Ast.ItemSlice = null,
        shape: Shape = .none,
        operands: u32 = 0,
        first_is_range: bool = false,
        /// After an operator, before its right operand.
        awaiting: bool = false,
        /// MayContainStrings, by the shape's rule so far.
        strings: bool = false,
    };

    fn classSet(p: *Parser) Error!Ast.Bracketed {
        var levels: std.ArrayList(SetLevel) = .empty;
        try p.openSetLevel(&levels);
        while (true) {
            const level = &levels.items[levels.items.len - 1];
            const at = p.at;
            const b = p.peek() orelse return p.fail(levels.items[0].start, p.at, .unclosed_class);
            if (b == ']') {
                if (level.awaiting) return p.fail(at, at + 1, .class_set_operand_missing);
                p.at += 1;
                try p.combine(level);
                if (level.negated and level.strings) return p.fail(level.start, p.at, .class_strings_negated);
                const done: Ast.Bracketed = .{ .negated = level.negated, .items = try p.flush(level) };
                const strings = level.strings;
                const nested_start = level.start;
                _ = levels.pop();
                if (levels.items.len == 0) return done;
                try p.setOperand(&levels.items[levels.items.len - 1], nested_start, .{ .nested = done }, strings, false);
                continue;
            }
            if (p.startsWith("&&") or p.startsWith("--")) {
                p.at += 2;
                const shape: Shape = if (b == '&') .intersection else .difference;
                if (level.operands == 0 or level.awaiting) return p.fail(at, p.at, .class_set_operand_missing);
                switch (level.shape) {
                    .none => if (level.first_is_range) return p.fail(at, p.at, .class_set_operation_mixed),
                    .union_ => return p.fail(at, p.at, .class_set_operation_mixed),
                    .intersection, .difference => if (level.shape != shape) return p.fail(at, p.at, .class_set_operation_mixed),
                }
                if (shape == .intersection and p.peek() == '&') return p.fail(p.at, p.at + 1, .class_set_character_reserved);
                level.shape = shape;
                try p.combine(level);
                level.lhs = try p.flush(level);
                level.awaiting = true;
                continue;
            }
            if (b == '[') {
                if (levels.items.len >= p.limits.nesting.raw()) return p.tooLarge(at, .nesting_too_deep);
                try p.openSetLevel(&levels);
                continue;
            }
            if (p.startsWith("\\q{")) {
                const read_strings = try p.stringDisjunction();
                try p.setOperand(level, at, .{ .strings = read_strings.slice }, read_strings.any_not_single, false);
                continue;
            }
            if (b == '\\') if (p.peekAt(1)) |c| switch (c) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    p.at += 2;
                    try p.setOperand(level, at, .{ .perl = perl(c) }, false, false);
                    continue;
                },
                'p', 'P' => {
                    p.at += 1;
                    const property = try p.propertyEscape(at);
                    try p.setOperand(level, at, .{ .unicode = property.unicode }, property.strings, false);
                    continue;
                },
                else => {},
            };
            const first = try p.classSetCharacter(levels.items[0].start);
            if (p.peek() == '-' and p.peekAt(1) != '-') {
                p.at += 1;
                const last = try p.classSetCharacter(levels.items[0].start);
                if (last < first) return p.fail(at, p.at, .class_range_out_of_order);
                try p.setOperand(level, at, .{ .range = .{ first, last } }, false, true);
                continue;
            }
            try p.setOperand(level, at, .{ .literal = first }, false, false);
        }
    }

    fn openSetLevel(p: *Parser, levels: *std.ArrayList(SetLevel)) Error!void {
        const start = p.at;
        p.at += 1;
        var negated = false;
        if (p.peek() == '^') {
            p.at += 1;
            negated = true;
        }
        try levels.append(p.arena, .{ .start = start, .negated = negated });
    }

    /// An operand (or a range, in a union) joins its level, as the level's shape allows.
    fn setOperand(p: *Parser, level: *SetLevel, start: u32, item: Ast.ClassItem, strings: bool, range: bool) Error!void {
        switch (level.shape) {
            .intersection, .difference => {
                if (!level.awaiting or range) return p.fail(start, p.at, .class_set_operation_mixed);
                level.awaiting = false;
                if (level.shape == .intersection) level.strings = level.strings and strings;
            },
            .none, .union_ => {
                if (level.operands == 0) {
                    level.first_is_range = range;
                    level.strings = strings;
                } else {
                    level.shape = .union_;
                    level.strings = level.strings or strings;
                }
            },
        }
        level.operands += 1;
        try level.items.append(p.arena, item);
    }

    fn flush(p: *Parser, level: *SetLevel) Error!Ast.ItemSlice {
        const slice: Ast.ItemSlice = .{ .start = @intCast(p.class_items.items.len), .len = @intCast(level.items.items.len) };
        try p.class_items.appendSlice(p.arena, level.items.items);
        level.items.clearRetainingCapacity();
        return slice;
    }

    /// The operation pending on `level`, folded with its right operand into one item.
    fn combine(p: *Parser, level: *SetLevel) Error!void {
        const lhs = level.lhs orelse return;
        const rhs = try p.flush(level);
        const op: @FieldType(Ast.Operation, "op") = switch (level.shape) {
            .intersection => .intersection,
            .difference => .difference,
            .none, .union_ => aegis.assert.never("an operation's level has an operator's shape"),
        };
        try level.items.append(p.arena, .{ .operation = .{ .op = op, .lhs = lhs, .rhs = rhs } });
        level.lhs = null;
    }

    /// A ClassSetCharacter: a code point that is no syntax character and begins no reserved
    /// double punctuator, or an escape.
    fn classSetCharacter(p: *Parser, class_start: u32) Error!u21 {
        const at = p.at;
        const b = p.peek() orelse return p.fail(class_start, p.at, .unclosed_class);
        if (b == '\\') {
            p.at += 1;
            const c = p.peek() orelse return p.fail(at, p.at, .escape_unexpected_end);
            if (c == 'b') {
                p.at += 1;
                return 0x08;
            }
            if (std.mem.indexOfScalar(u8, "&-!#%,:;<=>@`~", c) != null) {
                p.at += 1;
                return c;
            }
            return p.characterEscape(at, true);
        }
        if (std.mem.indexOfScalar(u8, "&!#$%*+,.:;<=>?@^`~", b) != null and p.peekAt(1) == b) return p.fail(at, at + 2, .class_set_character_reserved);
        if (std.mem.indexOfScalar(u8, "()[]{}/-\\|", b) != null) return p.fail(at, at + 1, .class_set_character_reserved);
        return p.take();
    }

    /// `\q{...}`: its strings, `|` apart, and whether any is not one code point long.
    fn stringDisjunction(p: *Parser) Error!struct { slice: Ast.Slice, any_not_single: bool } {
        const start = p.at;
        p.at += 3;
        const first = p.strings.items.len;
        var any_not_single = false;
        while (true) {
            const begin = p.code_points.items.len;
            while (true) {
                const b = p.peek() orelse return p.fail(start, p.at, .unclosed_class);
                if (b == '|' or b == '}') break;
                try p.code_points.append(p.arena, try p.classSetCharacter(start));
            }
            const len = p.code_points.items.len - begin;
            if (len != 1) any_not_single = true;
            try p.strings.append(p.arena, .{ .start = @intCast(begin), .len = @intCast(len) });
            const end = p.peek().?;
            p.at += 1;
            if (end == '}') break;
        }
        return .{ .slice = .{ .start = @intCast(first), .len = @intCast(p.strings.items.len - first) }, .any_not_single = any_not_single };
    }
};

fn perl(c: u8) Ast.Perl {
    return switch (c) {
        'd', 'D' => .{ .class = .digit, .negated = c == 'D' },
        's', 'S' => .{ .class = .space, .negated = c == 'S' },
        'w', 'W' => .{ .class = .word, .negated = c == 'W' },
        else => aegis.assert.never("perl takes d, s, w and their capitals"),
    };
}

fn classItem(atom: ClassAtom) Ast.ClassItem {
    return switch (atom) {
        .char => |cp| .{ .literal = cp },
        .class => |item| item,
    };
}

fn surrogates(cp: u21) [2]u21 {
    const v = cp - 0x10000;
    return .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
}

fn digitsEnd(pattern: []const u8, from: usize) u32 {
    var i = from;
    while (i < pattern.len and std.ascii.isDigit(pattern[i])) i += 1;
    return @intCast(i);
}

/// A decimal number, held to `maxInt(u32)`.
fn saturated(digits: []const u8) u32 {
    var value: u64 = 0;
    for (digits) |d| value = @min(value * 10 + (d - '0'), std.math.maxInt(u32));
    return @intCast(value);
}

/// Whether the number `a`'s digits write is less than `b`'s, at any length.
fn lessDigits(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimStart(u8, a, "0");
    const y = std.mem.trimStart(u8, b, "0");
    if (x.len != y.len) return x.len < y.len;
    return std.mem.order(u8, x, y) == .lt;
}

/// `n` hexadecimal digits at `from`, or null.
fn hexValue(pattern: []const u8, from: usize, n: usize) ?u21 {
    if (from + n > pattern.len) return null;
    var value: u21 = 0;
    for (pattern[from..][0..n]) |c| value = value * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    return value;
}

/// What the pattern holds before it is read: its capturing groups, and whether any is named.
/// Escapes and classes are stepped over; under `v` classes nest.
fn prescan(pattern: []const u8, mode: Mode) struct { captures: u32, named: bool } {
    var captures: u32 = 0;
    var named = false;
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => {
                if (depth == 0 or mode == .unicode_sets) depth += 1;
            },
            ']' => depth -|= 1,
            '(' => if (depth == 0) {
                if (i + 1 >= pattern.len or pattern[i + 1] != '?') {
                    captures +|= 1;
                } else if (i + 2 < pattern.len and pattern[i + 2] == '<' and (i + 3 >= pattern.len or (pattern[i + 3] != '=' and pattern[i + 3] != '!'))) {
                    captures +|= 1;
                    named = true;
                }
            },
            else => {},
        }
    }
    return .{ .captures = captures, .named = named };
}

/// ECMA-262's binary properties (its table of them), by the names and aliases it lists, which
/// xenoglyph's names all hold, but `Any`, `ASCII` and `Assigned`, which are ECMA-262's own.
pub const binary_names = [_][]const u8{
    "Any",                          "ASCII",                   "Assigned",
    "ASCII_Hex_Digit",              "AHex",                    "Alphabetic",
    "Alpha",                        "Bidi_Control",            "Bidi_C",
    "Bidi_Mirrored",                "Bidi_M",                  "Case_Ignorable",
    "CI",                           "Cased",                   "Changes_When_Casefolded",
    "CWCF",                         "Changes_When_Casemapped", "CWCM",
    "Changes_When_Lowercased",      "CWL",                     "Changes_When_NFKC_Casefolded",
    "CWKCF",                        "Changes_When_Titlecased", "CWT",
    "Changes_When_Uppercased",      "CWU",                     "Dash",
    "Default_Ignorable_Code_Point", "DI",                      "Deprecated",
    "Dep",                          "Diacritic",               "Dia",
    "Emoji",                        "Emoji_Component",         "EComp",
    "Emoji_Modifier",               "EMod",                    "Emoji_Modifier_Base",
    "EBase",                        "Emoji_Presentation",      "EPres",
    "Extended_Pictographic",        "ExtPict",                 "Extender",
    "Ext",                          "Grapheme_Base",           "Gr_Base",
    "Grapheme_Extend",              "Gr_Ext",                  "Hex_Digit",
    "Hex",                          "IDS_Binary_Operator",     "IDSB",
    "IDS_Trinary_Operator",         "IDST",                    "ID_Continue",
    "IDC",                          "ID_Start",                "IDS",
    "Ideographic",                  "Ideo",                    "Join_Control",
    "Join_C",                       "Logical_Order_Exception", "LOE",
    "Lowercase",                    "Lower",                   "Math",
    "Noncharacter_Code_Point",      "NChar",                   "Pattern_Syntax",
    "Pat_Syn",                      "Pattern_White_Space",     "Pat_WS",
    "Quotation_Mark",               "QMark",                   "Radical",
    "Regional_Indicator",           "RI",                      "Sentence_Terminal",
    "STerm",                        "Soft_Dotted",             "SD",
    "Terminal_Punctuation",         "Term",                    "Unified_Ideograph",
    "UIdeo",                        "Uppercase",               "Upper",
    "Variation_Selector",           "VS",                      "White_Space",
    "space",                        "XID_Continue",            "XIDC",
    "XID_Start",                    "XIDS",
};

/// ECMA-262's properties of strings, which only `\p` under `v` names.
pub const string_names = [_][]const u8{
    "Basic_Emoji",            "Emoji_Keycap_Sequence",  "RGI_Emoji_Modifier_Sequence", "RGI_Emoji_Flag_Sequence",
    "RGI_Emoji_Tag_Sequence", "RGI_Emoji_ZWJ_Sequence", "RGI_Emoji",
};

fn binaryProperty(name: []const u8) bool {
    for (binary_names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}

fn stringProperty(name: []const u8) bool {
    for (string_names) |known| if (std.mem.eql(u8, known, name)) return true;
    return false;
}
