//! A compiled pattern: is-match, find, captures and every match in turn. Immutable once
//! compiled, so any number of threads search it, each with a `Cache` of its own.
//!
//! The PikeVM answers every search for now: linear in the haystack and the automaton for any
//! pattern. The faster engines join behind this interface, each tested against it.
const Regex = @This();
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Syntax = @import("Syntax.zig");
const Limits = @import("Limits.zig");
const Ast = @import("syntax/Ast.zig");
const parse_mod = @import("syntax/parse.zig");
const diagnostic_zig = @import("syntax/diagnostic.zig");
const translate_mod = @import("hir/translate.zig");
const Nfa = @import("nfa/Nfa.zig");
const compile_mod = @import("nfa/compile.zig");
const pikevm = @import("pikevm.zig");

pub const Span = pikevm.Span;
pub const Input = pikevm.Input;
pub const Diagnostic = diagnostic_zig.Diagnostic;

gpa: Allocator,
nfa: Nfa,

pub const Options = struct {
    syntax: Syntax = .{},
    limits: Limits = .{},
    /// Where a refused pattern was refused, and why.
    diagnostic: ?*Diagnostic = null,
};

pub const CompileError = error{ OutOfMemory, Invalid, Unsupported, TooLarge };

pub fn compile(gpa: Allocator, pattern: aegis.input.Untrusted([]const u8), options: Options) CompileError!Regex {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const ast = try a.create(Ast);
    ast.* = try parse_mod.parse(a, pattern, options.syntax, options.limits, options.diagnostic);
    const hir = try translate_mod.translate(a, ast, options.syntax, options.limits, options.diagnostic);
    const whole = ast.node(ast.root).span;
    const nfa = try compile_mod.compile(gpa, &hir, .{ .limits = options.limits, .utf8 = options.syntax.utf8, .span = whole }, options.diagnostic);
    return .{ .gpa = gpa, .nfa = nfa };
}

pub fn deinit(re: *Regex) void {
    re.nfa.deinit(re.gpa);
    re.* = undefined;
}

/// What one task's searches of this pattern need, allocated once.
pub const Cache = struct {
    pike: pikevm.Cache,

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.pike.deinit(gpa);
    }
};

pub fn cache(re: *const Regex, gpa: Allocator) Allocator.Error!Cache {
    return .{ .pike = try .init(gpa, &re.nfa) };
}

/// Capture groups, the whole match (group 0) among them.
pub fn captureCount(re: *const Regex) u32 {
    return re.nfa.groups;
}

/// The number of the group named `name`.
pub fn captureIndex(re: *const Regex, name: []const u8) ?u32 {
    for (re.nfa.names, 0..) |n, i| {
        if (n) |got| if (std.mem.eql(u8, got, name)) return @intCast(i);
    }
    return null;
}

pub fn isMatch(re: *const Regex, c: *Cache, haystack: []const u8) bool {
    var input: Input = .of(haystack);
    input.earliest = true;
    return pikevm.search(&re.nfa, &c.pike, input, &.{}) != null;
}

/// The leftmost-first match.
pub fn find(re: *const Regex, c: *Cache, input: Input) ?Span {
    var slots: [2]?usize = undefined;
    _ = pikevm.search(&re.nfa, &c.pike, input, &slots) orelse return null;
    return .{ .start = slots[0].?, .end = slots[1].? };
}

/// The leftmost-first match with each group's span in `out`, null where a group took no part.
/// `out.len == captureCount()` is the caller's contract.
pub fn captures(re: *const Regex, c: *Cache, input: Input, out: []?Span) bool {
    aegis.assert.invariant(out.len == re.nfa.groups, "a capture slice holds one span per group");
    const slots = c.pike.slots;
    _ = pikevm.search(&re.nfa, &c.pike, input, slots) orelse return false;
    for (out, 0..) |*span, g| {
        span.* = if (slots[2 * g]) |start| .{ .start = start, .end = slots[2 * g + 1].? } else null;
    }
    return true;
}

/// Every match in turn, leftmost first and apart; an empty match right after the one before is
/// passed over, so the search always moves on.
pub fn findAll(re: *const Regex, c: *Cache, haystack: []const u8) Matches {
    return re.findAllIn(c, .of(haystack));
}

/// `findAll` over a span, or anchored: each match then starts where the one before ended.
pub fn findAllIn(re: *const Regex, c: *Cache, input: Input) Matches {
    return .{ .re = re, .cache = c, .input = input };
}

pub const Matches = struct {
    re: *const Regex,
    cache: *Cache,
    input: Input,
    last_end: ?usize = null,

    pub fn next(m: *Matches) ?Span {
        if (m.input.span.start > m.input.span.end) return null;
        var found = m.re.find(m.cache, m.input) orelse return null;
        if (found.start == found.end and m.last_end == found.end) {
            if (m.input.span.start >= m.input.span.end) return null;
            m.input.span.start += 1;
            found = m.re.find(m.cache, m.input) orelse return null;
        }
        m.input.span.start = found.end;
        m.last_end = found.end;
        return found;
    }

    /// The next match as `next` finds it, with each group's span in `out`.
    pub fn nextCaptures(m: *Matches, out: []?Span) bool {
        if (m.input.span.start > m.input.span.end) return false;
        if (!m.re.captures(m.cache, m.input, out)) return false;
        if (out[0].?.start == out[0].?.end and m.last_end == out[0].?.end) {
            if (m.input.span.start >= m.input.span.end) return false;
            m.input.span.start += 1;
            if (!m.re.captures(m.cache, m.input, out)) return false;
        }
        m.input.span.start = out[0].?.end;
        m.last_end = out[0].?.end;
        return true;
    }
};
