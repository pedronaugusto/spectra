//! The Rust dialect's parser (regex-syntax's grammar): a pattern into an `Ast`. Groups are
//! parsed with an explicit stack, bounded by `Limits.nesting`, and so are classes inside
//! classes; nothing recurses on the pattern's shape.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Syntax = @import("../Syntax.zig");
const Limits = @import("../Limits.zig");

pub const Error = error{ OutOfMemory, Invalid, TooLarge };

/// Why a pattern was refused, and where.
pub const Diagnostic = struct {
    span: Ast.Span = .{ .start = 0, .end = 0 },
    reason: Reason = .none,
};

pub const Reason = enum {
    none,
    pattern_too_long,
    nesting_too_deep,
    invalid_utf8,
    unclosed_group,
    unopened_group,
    unclosed_class,
    empty_class,
    class_range_out_of_order,
    class_range_bad_end,
    repetition_missing,
    repetition_count_invalid,
    repetition_count_too_large,
    repetition_count_out_of_order,
    escape_unexpected_end,
    escape_unrecognized,
    escape_hex_invalid,
    code_point_invalid,
    assertion_in_class,
    unicode_class_invalid,
    flag_unrecognized,
    flag_repeated,
    flag_dangling_negation,
    flags_empty,
    group_name_invalid,
    group_name_duplicate,
    ascii_class_invalid,
};

/// Parses `pattern`, its nodes in `arena`, which the `Ast` borrows, and the pattern too.
pub fn parse(arena: Allocator, pattern: aegis.input.Untrusted([]const u8), syntax: Syntax, limits: Limits, diagnostic: ?*Diagnostic) Error!Ast {
    return pattern.parse(Context{ .arena = arena, .syntax = syntax, .limits = limits, .diagnostic = diagnostic }, parseTrusted);
}

const Context = struct {
    arena: Allocator,
    syntax: Syntax,
    limits: Limits,
    diagnostic: ?*Diagnostic,
};

fn parseTrusted(c: Context, pattern: []const u8) Error!Ast {
    if (pattern.len > c.limits.pattern.raw()) {
        if (c.diagnostic) |d| d.* = .{ .span = .{ .start = 0, .end = 0 }, .reason = .pattern_too_long };
        return error.TooLarge;
    }
    var p: Parser = .{ .arena = c.arena, .pattern = pattern, .limits = c.limits, .diagnostic = c.diagnostic };
    return p.run(c.syntax.ignore_whitespace);
}

const Frame = struct {
    /// Where the group opened (its `(`), and what it is; null for the pattern itself.
    open: u32,
    group: ?Pending,
    /// The alternatives finished so far, and the items of the one being read.
    alternatives: std.ArrayList(Ast.Index) = .empty,
    items: std.ArrayList(Ast.Index) = .empty,
    /// Where the alternative being read began.
    alternative_start: u32,
    /// `x`, which changes how the group's text is read.
    ignore_whitespace: bool,
};

const Pending = union(enum) {
    capture: struct { index: u32, name: ?[]const u8 },
    non_capturing: Ast.Flags,
};

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    limits: Limits,
    diagnostic: ?*Diagnostic,
    at: u32 = 0,
    nodes: std.ArrayList(Ast.Node) = .empty,
    class_items: std.ArrayList(Ast.ClassItem) = .empty,
    children: std.ArrayList(Ast.Index) = .empty,
    captures: u32 = 0,
    names: std.ArrayList([]const u8) = .empty,

    fn fail(p: *Parser, start: u32, stop: u32, reason: Reason) error{Invalid} {
        if (p.diagnostic) |d| d.* = .{ .span = .{ .start = start, .end = stop }, .reason = reason };
        return error.Invalid;
    }

    fn tooLarge(p: *Parser, start: u32, reason: Reason) error{TooLarge} {
        if (p.diagnostic) |d| d.* = .{ .span = .{ .start = start, .end = p.at }, .reason = reason };
        return error.TooLarge;
    }

    fn atEnd(p: *const Parser) bool {
        return p.at >= p.pattern.len;
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.atEnd()) null else p.pattern[p.at];
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

    /// Under `x`: whitespace and `#` comments to the end of the line go.
    fn skipIgnored(p: *Parser, ignore_whitespace: bool) void {
        if (!ignore_whitespace) return;
        while (p.peek()) |b| {
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0b or b == 0x0c) {
                p.at += 1;
            } else if (b == '#') {
                while (p.peek()) |c| : (p.at += 1) if (c == '\n') break;
            } else break;
        }
    }

    fn add(p: *Parser, start: u32, kind: Ast.Kind) Error!Ast.Index {
        const index: Ast.Index = @enumFromInt(p.nodes.items.len);
        try p.nodes.append(p.arena, .{ .span = .{ .start = start, .end = p.at }, .kind = kind });
        return index;
    }

    /// The items read, as one node: nothing is `empty`, one is itself, more a concatenation.
    fn sequence(p: *Parser, start: u32, items: []const Ast.Index) Error!Ast.Index {
        if (items.len == 0) return p.add(start, .empty);
        if (items.len == 1) return items[0];
        const slice: Ast.Slice = .{ .start = @intCast(p.children.items.len), .len = @intCast(items.len) };
        try p.children.appendSlice(p.arena, items);
        return p.add(start, .{ .concat = slice });
    }

    /// The frame's alternatives, as one node.
    fn finish(p: *Parser, frame: *Frame, start: u32) Error!Ast.Index {
        const last = try p.sequence(frame.alternative_start, frame.items.items);
        if (frame.alternatives.items.len == 0) return last;
        try frame.alternatives.append(p.arena, last);
        const slice: Ast.Slice = .{ .start = @intCast(p.children.items.len), .len = @intCast(frame.alternatives.items.len) };
        try p.children.appendSlice(p.arena, frame.alternatives.items);
        return p.add(start, .{ .alternation = slice });
    }

    fn run(p: *Parser, ignore_whitespace: bool) Error!Ast {
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(p.arena, .{ .open = 0, .group = null, .alternative_start = 0, .ignore_whitespace = ignore_whitespace });
        while (true) {
            const frame = &stack.items[stack.items.len - 1];
            p.skipIgnored(frame.ignore_whitespace);
            const start = p.at;
            const b = p.peek() orelse break;
            switch (b) {
                '(' => {
                    if (stack.items.len > p.limits.nesting.raw()) return p.tooLarge(start, .nesting_too_deep);
                    p.at += 1;
                    if (try p.groupOpening(start, frame)) |opened| {
                        try stack.append(p.arena, opened);
                    }
                },
                ')' => {
                    if (stack.items.len == 1) return p.fail(start, start + 1, .unopened_group);
                    p.at += 1;
                    var closed = stack.pop().?;
                    const sub = try p.finish(&closed, closed.open + 1);
                    const group: Ast.Group = switch (closed.group.?) {
                        .capture => |cap| .{ .kind = .{ .capture = .{ .index = cap.index, .name = cap.name } }, .sub = sub },
                        .non_capturing => |set| .{ .kind = .{ .non_capturing = set }, .sub = sub },
                    };
                    const parent = &stack.items[stack.items.len - 1];
                    const node = try p.add(closed.open, .{ .group = group });
                    try parent.items.append(p.arena, node);
                },
                '|' => {
                    p.at += 1;
                    try frame.alternatives.append(p.arena, try p.sequence(frame.alternative_start, frame.items.items));
                    frame.items.clearRetainingCapacity();
                    frame.alternative_start = p.at;
                },
                '*', '+', '?', '{' => try p.repetition(frame),
                '[' => {
                    const bracketed = try p.class(frame.ignore_whitespace);
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
                '\\' => {
                    const kind = try p.escape(false);
                    try frame.items.append(p.arena, try p.add(start, kind));
                },
                else => {
                    const cp = try p.take();
                    try frame.items.append(p.arena, try p.add(start, .{ .literal = cp }));
                },
            }
        }
        if (stack.items.len > 1) {
            const open = stack.items[stack.items.len - 1].open;
            return p.fail(open, open + 1, .unclosed_group);
        }
        const root = try p.finish(&stack.items[0], 0);
        return .{
            .nodes = try p.nodes.toOwnedSlice(p.arena),
            .class_items = try p.class_items.toOwnedSlice(p.arena),
            .children = try p.children.toOwnedSlice(p.arena),
            .root = root,
            .captures = p.captures,
        };
    }

    /// After `(`: a capture, a named capture, a non-capturing group (with flags or none), or
    /// `(?flags)` alone, which sets them for the rest of `frame` and opens nothing.
    fn groupOpening(p: *Parser, start: u32, frame: *Frame) Error!?Frame {
        if (p.peek() != '?') {
            p.captures += 1;
            return .{ .open = start, .group = .{ .capture = .{ .index = p.captures, .name = null } }, .alternative_start = p.at, .ignore_whitespace = frame.ignore_whitespace };
        }
        p.at += 1;
        if (p.startsWith("P<") or p.peek() == '<') {
            p.at += if (p.peek() == 'P') 2 else 1;
            const name_start = p.at;
            while (p.peek()) |c| : (p.at += 1) if (c == '>') break;
            if (p.atEnd()) return p.fail(name_start, p.at, .group_name_invalid);
            const name = p.pattern[name_start..p.at];
            p.at += 1;
            if (!validName(name)) return p.fail(name_start, p.at - 1, .group_name_invalid);
            for (p.names.items) |known| if (std.mem.eql(u8, known, name)) return p.fail(name_start, p.at - 1, .group_name_duplicate);
            try p.names.append(p.arena, name);
            p.captures += 1;
            return .{ .open = start, .group = .{ .capture = .{ .index = p.captures, .name = name } }, .alternative_start = p.at, .ignore_whitespace = frame.ignore_whitespace };
        }
        const read = try p.flags(start);
        var inside = frame.ignore_whitespace;
        if (read.set.ignore_whitespace) inside = true;
        if (read.clear.ignore_whitespace) inside = false;
        if (p.peek() == ')') {
            p.at += 1;
            frame.ignore_whitespace = inside;
            try frame.items.append(p.arena, try p.add(start, .{ .flags = read }));
            return null;
        }
        // `flags` stopped at `:` or `)`; only these two end it.
        p.at += 1;
        return .{ .open = start, .group = .{ .non_capturing = read }, .alternative_start = p.at, .ignore_whitespace = inside };
    }

    /// The flags after `(?`, up to `:` or `)`, which is left.
    fn flags(p: *Parser, start: u32) Error!Ast.Flags {
        var out: Ast.Flags = .{};
        var negating = false;
        var any_after_negation = false;
        var seen: Ast.Flags.Set = .{};
        while (true) {
            const at = p.at;
            const c = p.peek() orelse return p.fail(start, p.at, .unclosed_group);
            if (c == ':' or c == ')') {
                if (negating and !any_after_negation) return p.fail(at - 1, at, .flag_dangling_negation);
                if (c == ')' and @as(u8, @bitCast(out.set)) == 0 and @as(u8, @bitCast(out.clear)) == 0 and !negating) return p.fail(start, at + 1, .flags_empty);
                return out;
            }
            p.at += 1;
            if (c == '-') {
                if (negating) return p.fail(at, at + 1, .flag_repeated);
                negating = true;
                continue;
            }
            var one: Ast.Flags.Set = .{};
            switch (c) {
                'i' => one.case_insensitive = true,
                'm' => one.multi_line = true,
                's' => one.dot_matches_new_line = true,
                'U' => one.swap_greed = true,
                'u' => one.unicode = true,
                'x' => one.ignore_whitespace = true,
                'R' => one.crlf = true,
                else => return p.fail(at, at + 1, .flag_unrecognized),
            }
            const bit: u8 = @bitCast(one);
            if (@as(u8, @bitCast(seen)) & bit != 0) return p.fail(at, at + 1, .flag_repeated);
            seen = @bitCast(@as(u8, @bitCast(seen)) | bit);
            if (negating) {
                any_after_negation = true;
                out.clear = @bitCast(@as(u8, @bitCast(out.clear)) | bit);
            } else out.set = @bitCast(@as(u8, @bitCast(out.set)) | bit);
        }
    }

    fn validName(name: []const u8) bool {
        if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']')) return false;
        }
        return true;
    }

    /// `*`, `+`, `?` or `{n}`, `{n,}`, `{n,m}`, then `?` for lazy, applied to the last item.
    fn repetition(p: *Parser, frame: *Frame) Error!void {
        const start = p.at;
        const c = p.peek().?;
        p.at += 1;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => {},
            '+' => min = 1,
            '?' => max = 1,
            '{' => {
                p.skipIgnored(frame.ignore_whitespace);
                min = try p.count(start);
                p.skipIgnored(frame.ignore_whitespace);
                if (p.peek() == ',') {
                    p.at += 1;
                    p.skipIgnored(frame.ignore_whitespace);
                    max = if (p.peek() == '}') null else try p.count(start);
                } else max = min;
                p.skipIgnored(frame.ignore_whitespace);
                if (p.peek() != '}') return p.fail(start, p.at, .repetition_count_invalid);
                p.at += 1;
                if (max) |m| if (m < min) return p.fail(start, p.at, .repetition_count_out_of_order);
            },
            else => aegis.assert.never("only *, +, ? and { reach repetition"),
        }
        var greedy = true;
        if (p.peek() == '?') {
            p.at += 1;
            greedy = false;
        }
        const target = frame.items.pop() orelse return p.fail(start, p.at, .repetition_missing);
        const target_node = p.nodes.items[@intFromEnum(target)];
        if (target_node.kind == .flags) return p.fail(start, p.at, .repetition_missing);
        try frame.items.append(p.arena, try p.add(target_node.span.start, .{ .repetition = .{ .min = min, .max = max, .greedy = greedy, .sub = target } }));
    }

    fn count(p: *Parser, start: u32) Error!u32 {
        const digits = p.at;
        var value: u64 = 0;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            value = value * 10 + (c - '0');
            if (value > p.limits.repetition.raw()) return p.tooLarge(start, .repetition_count_too_large);
            p.at += 1;
        }
        if (p.at == digits) return p.fail(start, p.at, .repetition_count_invalid);
        return @intCast(value);
    }

    /// After `\`: a literal, an assertion, a Perl class or a Unicode class. In a class, an
    /// assertion is refused.
    fn escape(p: *Parser, in_class: bool) Error!Ast.Kind {
        const start = p.at;
        p.at += 1;
        const c = p.peek() orelse return p.fail(start, p.at, .escape_unexpected_end);
        p.at += 1;
        const kind: Ast.Kind = switch (c) {
            'a' => .{ .literal = 0x07 },
            'f' => .{ .literal = 0x0c },
            't' => .{ .literal = '\t' },
            'n' => .{ .literal = '\n' },
            'r' => .{ .literal = '\r' },
            'v' => .{ .literal = 0x0b },
            'x' => .{ .literal = try p.hex(start, 2) },
            'u' => .{ .literal = try p.hex(start, 4) },
            'U' => .{ .literal = try p.hex(start, 8) },
            'd', 'D' => .{ .perl = .{ .class = .digit, .negated = c == 'D' } },
            's', 'S' => .{ .perl = .{ .class = .space, .negated = c == 'S' } },
            'w', 'W' => .{ .perl = .{ .class = .word, .negated = c == 'W' } },
            'p', 'P' => .{ .unicode = try p.unicodeClass(start, c == 'P') },
            'A' => .{ .assertion = .start_text },
            'z' => .{ .assertion = .end_text },
            'B' => .{ .assertion = .not_word_boundary },
            '<' => .{ .assertion = .word_start },
            '>' => .{ .assertion = .word_end },
            'b' => .{ .assertion = try p.wordBoundary() },
            else => blk: {
                // Any other ASCII punctuation, or a space, stands for itself.
                if (c < 0x80 and !std.ascii.isAlphanumeric(c) and c != '<' and c != '>') break :blk .{ .literal = c };
                return p.fail(start, p.at, .escape_unrecognized);
            },
        };
        if (in_class and kind == .assertion) return p.fail(start, p.at, .assertion_in_class);
        return kind;
    }

    /// `\b`, or `\b{start}`, `\b{end}`, `\b{start-half}`, `\b{end-half}`.
    fn wordBoundary(p: *Parser) Error!Ast.Assertion {
        if (p.peek() != '{') return .word_boundary;
        const names = [_]struct { []const u8, Ast.Assertion }{
            .{ "{start}", .word_start }, .{ "{end}", .word_end }, .{ "{start-half}", .word_start_half }, .{ "{end-half}", .word_end_half },
        };
        for (names) |entry| if (p.startsWith(entry[0])) {
            p.at += @intCast(entry[0].len);
            return entry[1];
        };
        // `\b` then a counted repetition, as `\b{2}`: the brace is the repetition's.
        return .word_boundary;
    }

    /// A code point in hexadecimal: `fixed` digits, or any count in braces.
    fn hex(p: *Parser, start: u32, fixed: u32) Error!u21 {
        var value: u32 = 0;
        if (p.peek() == '{') {
            p.at += 1;
            const digits = p.at;
            while (p.peek()) |c| {
                if (c == '}') break;
                const d = std.fmt.charToDigit(c, 16) catch return p.fail(start, p.at + 1, .escape_hex_invalid);
                value = value * 16 + d;
                if (value > 0x10ffff) return p.fail(start, p.at + 1, .code_point_invalid);
                p.at += 1;
            }
            if (p.atEnd() or p.at == digits) return p.fail(start, p.at, .escape_hex_invalid);
            p.at += 1;
        } else {
            var n: u32 = 0;
            while (n < fixed) : (n += 1) {
                const c = p.peek() orelse return p.fail(start, p.at, .escape_hex_invalid);
                const d = std.fmt.charToDigit(c, 16) catch return p.fail(start, p.at + 1, .escape_hex_invalid);
                value = value * 16 + d;
                p.at += 1;
            }
            if (value > 0x10ffff) return p.fail(start, p.at, .code_point_invalid);
        }
        if (value >= 0xd800 and value <= 0xdfff) return p.fail(start, p.at, .code_point_invalid);
        return @intCast(value);
    }

    /// After `\p` or `\P`: one letter, or a name in braces, `^` negating, `=`, `:` or `!=` before
    /// a value.
    fn unicodeClass(p: *Parser, start: u32, upper: bool) Error!Ast.Unicode {
        var negated = upper;
        if (p.peek() != '{') {
            const c = p.peek() orelse return p.fail(start, p.at, .unicode_class_invalid);
            if (!std.ascii.isAlphabetic(c)) return p.fail(start, p.at + 1, .unicode_class_invalid);
            p.at += 1;
            return .{ .name = p.pattern[p.at - 1 .. p.at], .value = null, .negated = negated };
        }
        p.at += 1;
        const body_start = p.at;
        while (p.peek()) |c| : (p.at += 1) if (c == '}') break;
        if (p.atEnd()) return p.fail(start, p.at, .unicode_class_invalid);
        var body = p.pattern[body_start..p.at];
        p.at += 1;
        if (body.len != 0 and body[0] == '^') {
            negated = !negated;
            body = body[1..];
        }
        if (std.mem.indexOf(u8, body, "!=")) |i| {
            if (i == 0 or i + 2 == body.len) return p.fail(start, p.at, .unicode_class_invalid);
            return .{ .name = body[0..i], .value = body[i + 2 ..], .negated = !negated };
        }
        if (std.mem.indexOfAny(u8, body, "=:")) |i| {
            if (i == 0 or i + 1 == body.len) return p.fail(start, p.at, .unicode_class_invalid);
            return .{ .name = body[0..i], .value = body[i + 1 ..], .negated = negated };
        }
        if (body.len == 0) return p.fail(start, p.at, .unicode_class_invalid);
        return .{ .name = body, .value = null, .negated = negated };
    }

    /// One class level being read: its items so far, and the operation they are the
    /// right-hand side of, if any.
    const Level = struct {
        start: u32,
        negated: bool,
        items: std.ArrayList(Ast.ClassItem) = .empty,
        /// The union before an operator, and the operator, while its right side is read.
        lhs: ?Ast.ItemSlice = null,
        op: @FieldType(Ast.Operation, "op") = .intersection,
        first: bool = true,
    };

    /// `[...]`, its nested classes read with an explicit stack.
    fn class(p: *Parser, ignore_whitespace: bool) Error!Ast.Bracketed {
        var levels: std.ArrayList(Level) = .empty;
        try p.openLevel(&levels);
        while (true) {
            const level = &levels.items[levels.items.len - 1];
            if (!level.first) p.skipIgnored(ignore_whitespace);
            const at = p.at;
            const c = p.peek() orelse return p.fail(levels.items[0].start, p.at, .unclosed_class);
            // A `]` first stands for itself.
            if (c == ']' and !level.first) {
                p.at += 1;
                const done = try p.closeLevel(level);
                _ = levels.pop();
                if (levels.items.len == 0) return done;
                const parent = &levels.items[levels.items.len - 1];
                try parent.items.append(p.arena, .{ .nested = done });
                continue;
            }
            level.first = false;
            if (p.startsWith("&&") or p.startsWith("--") or p.startsWith("~~")) {
                const op: @FieldType(Ast.Operation, "op") = switch (c) {
                    '&' => .intersection,
                    '-' => .difference,
                    else => .symmetric_difference,
                };
                p.at += 2;
                try p.combine(level);
                level.lhs = try p.flush(level);
                level.op = op;
                continue;
            }
            if (c == '[') {
                if (try p.asciiClass()) |ascii| {
                    try level.items.append(p.arena, .{ .ascii = ascii });
                    continue;
                }
                if (levels.items.len >= p.limits.nesting.raw()) return p.tooLarge(at, .nesting_too_deep);
                try p.openLevel(&levels);
                continue;
            }
            const first = try p.classAtom();
            // `a-z`, unless the `-` ends the class or begins an operator.
            if (first == .literal and p.peek() == '-' and p.peekAt(1) != ']' and p.peekAt(1) != '-' and p.peekAt(1) != null) {
                p.at += 1;
                const end_at = p.at;
                const last = try p.classAtom();
                if (last != .literal) return p.fail(end_at, p.at, .class_range_bad_end);
                if (last.literal < first.literal) return p.fail(at, p.at, .class_range_out_of_order);
                try level.items.append(p.arena, .{ .range = .{ first.literal, last.literal } });
                continue;
            }
            try level.items.append(p.arena, first);
        }
    }

    fn openLevel(p: *Parser, levels: *std.ArrayList(Level)) Error!void {
        const start = p.at;
        p.at += 1;
        var negated = false;
        if (p.peek() == '^') {
            p.at += 1;
            negated = true;
        }
        try levels.append(p.arena, .{ .start = start, .negated = negated });
    }

    /// The items read so far, appended to the class items, as their slice.
    fn flush(p: *Parser, level: *Level) Error!Ast.ItemSlice {
        const slice: Ast.ItemSlice = .{ .start = @intCast(p.class_items.items.len), .len = @intCast(level.items.items.len) };
        try p.class_items.appendSlice(p.arena, level.items.items);
        level.items.clearRetainingCapacity();
        return slice;
    }

    /// An operation pending on `level`, folded with what was read since into one item.
    fn combine(p: *Parser, level: *Level) Error!void {
        const lhs = level.lhs orelse return;
        const rhs = try p.flush(level);
        try level.items.append(p.arena, .{ .operation = .{ .op = level.op, .lhs = lhs, .rhs = rhs } });
        level.lhs = null;
    }

    fn closeLevel(p: *Parser, level: *Level) Error!Ast.Bracketed {
        try p.combine(level);
        if (level.items.items.len == 0) return p.fail(level.start, p.at, .empty_class);
        return .{ .negated = level.negated, .items = try p.flush(level) };
    }

    /// `[:name:]` or `[:^name:]` at the cursor, taken; null where the `[` is something else.
    fn asciiClass(p: *Parser) Error!?Ast.Ascii {
        if (!p.startsWith("[:")) return null;
        const rest = p.pattern[p.at + 2 ..];
        const close = std.mem.indexOf(u8, rest, ":]") orelse return null;
        var name = rest[0..close];
        var negated = false;
        if (name.len != 0 and name[0] == '^') {
            negated = true;
            name = name[1..];
        }
        const class_kind = std.meta.stringToEnum(Ast.AsciiClass, name) orelse return null;
        p.at += @intCast(2 + close + 2);
        return .{ .class = class_kind, .negated = negated };
    }

    /// One item of a class: a literal (escaped or not), a Perl or Unicode class.
    fn classAtom(p: *Parser) Error!Ast.ClassItem {
        if (p.peek() == '\\') {
            return switch (try p.escape(true)) {
                .literal => |cp| .{ .literal = cp },
                .perl => |perl| .{ .perl = perl },
                .unicode => |unicode| .{ .unicode = unicode },
                else => aegis.assert.never("in a class, escape gives a literal or a class"),
            };
        }
        return .{ .literal = try p.take() };
    }
};
