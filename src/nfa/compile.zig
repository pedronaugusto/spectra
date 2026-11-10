//! The HIR into a Thompson NFA over bytes, by regex-automata's compiler: the same fragments for
//! each node, the same preference order in every alternative (a lazy repetition prefers to
//! leave), `x*` compiled as `(x+)?` when `x` can match empty so that preference stays Perl's,
//! and a UTF-8 class compiled as a minimal byte automaton by Daciuk's algorithm over its
//! sequences in order, each finished state shared with any equal one. Surrogates are dropped
//! there: UTF-8 encodes none.
//!
//! The tree is walked on an explicit stack. A repetition compiles its operand once and copies
//! the states it made for each further time, rather than compiling it again, so `\pL{1000}`
//! does the class's work once.
//!
//! Every state, transition and alternative is charged to `Limits.nfa` before it is allocated,
//! the copies a repetition makes among them, so neither the memory nor the work outgrows what
//! the limit implies: past it the pattern is refused (`TooLarge`, `nfa_too_large`). What the
//! pattern's own shape needs (a stack, a property per node) is linear in the HIR. The automaton
//! is charged apart from the sets translation made; both are bounded by the same limit.
//!
//! In ECMAScript (`Options.ecma`) a repetition means what ECMA-262's RepeatMatcher says, chosen
//! in one place (`Repeats`): each iteration of a quantified atom that holds groups starts by
//! clearing their captures (a `clear` state heads each time the atom may be taken more than
//! once), and an iteration past the minimum that matches empty fails (each such time of an
//! atom that can match empty is bracketed by `loop_begin` and `loop_end`, after Barrière and
//! Pit-Claudel, "Linear Matching of JavaScript Regular Expressions", PLDI 2024, §4.1). Neither
//! `(x+)?` nor the clamp of an atom that matches only empty to one time is ECMAScript's.
//!
//! ECMAScript's lookahead runs on the derivative engine, not on this automaton; until that is
//! built a pattern holding one is refused (`Unsupported`, `unsupported_lookahead`).
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Hir = @import("../hir/Hir.zig");
const Limits = @import("../Limits.zig");
const Charged = @import("../Charged.zig");
const Ast = @import("../syntax/Ast.zig");
const diagnostic_zig = @import("../syntax/diagnostic.zig");
const Nfa = @import("Nfa.zig");
const utf8 = @import("utf8.zig");
const Diagnostic = diagnostic_zig.Diagnostic;
const Reason = diagnostic_zig.Reason;

pub const Error = error{ OutOfMemory, Unsupported, TooLarge };

pub const Options = struct {
    limits: Limits = .{},
    /// `Syntax.utf8`: whether an empty match may split a code point, which the search reads.
    utf8: bool = true,
    /// Where a refusal points. The HIR keeps no spans: the pattern's whole span.
    span: Ast.Span = .{ .start = 0, .end = 0 },
    /// ECMA-262's iterations: each clears the captures of the groups in its atom, and one past
    /// the minimum that matches empty fails.
    ecma: bool = false,
};

/// The automaton of `hir`, owned by the caller (`Nfa.deinit`).
pub fn compile(gpa: Allocator, hir: *const Hir, options: Options, diagnostic: ?*Diagnostic) Error!Nfa {
    var spent: usize = 0;
    return compileCounted(gpa, hir, options, diagnostic, &spent);
}

/// `compile`, and in `spent` the bytes it was charged for, refused or not.
pub fn compileCounted(gpa: Allocator, hir: *const Hir, options: Options, diagnostic: ?*Diagnostic, spent: *usize) Error!Nfa {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const limit = options.limits.nfa.raw();
    var charged: Charged = .{ .child = scratch.allocator(), .left = limit };
    defer spent.* = limit - charged.left;
    var c: Compiler = .{ .scratch = scratch.allocator(), .b = .{ .gpa = charged.allocator() }, .hir = hir, .repeats = .{ .ecma = options.ecma } };
    const starts = c.run() catch |err| switch (err) {
        error.OutOfMemory => if (charged.over)
            return refuse(diagnostic, options.span, .nfa_too_large, error.TooLarge)
        else
            return error.OutOfMemory,
        error.TooLarge => return refuse(diagnostic, options.span, .nfa_too_large, error.TooLarge),
        error.Unsupported => return refuse(diagnostic, options.span, .unsupported_lookahead, error.Unsupported),
    };
    return c.b.finish(gpa, c.scratch, starts, hir, options.utf8);
}

fn refuse(diagnostic: ?*Diagnostic, span: Ast.Span, reason: Reason, err: Error) Error {
    if (diagnostic) |d| d.* = .{ .span = span, .reason = reason };
    return err;
}

const BuildError = error{ OutOfMemory, TooLarge, Unsupported };

/// No state yet: a fragment's end before its parent joins it to what follows.
const unset = std.math.maxInt(u32);

const Fragment = struct { start: u32, end: u32 };

const Starts = struct { anchored: u32, unanchored: u32, empty_ok: bool };

const Trans = struct { lo: u8, hi: u8, next: u32 };

const Union = struct {
    start: u32,
    len: u32,
    filled: u32,
    /// Filled from the last alternative back, so what is joined first is preferred last.
    lazy: bool,
};

const BState = union(enum) {
    empty: u32,
    byte_range: Trans,
    sparse: Nfa.Slice,
    look: struct { look: Hir.Look, next: u32 },
    alternation: Union,
    capture: struct { group: u32, slot: u32, next: u32 },
    clear: struct { first: u32, end: u32, next: u32 },
    loop_begin: u32,
    loop_end: u32,
    fail,
    match,
};

/// What a repetition means, which the dialect chooses: here, and nowhere else.
const Repeats = struct {
    /// ECMA-262's RepeatMatcher; otherwise regex-automata's (Rust's).
    ecma: bool,

    /// The times kept of a repetition of what matches only the empty string. Rust takes it
    /// at most once, as regex-syntax does. In ECMAScript every time past the minimum fails, so
    /// it is taken its minimum, at most once, since one empty time is as good as many.
    fn clamp(r: Repeats, min: u32, max: ?u32) struct { min: u32, max: u32 } {
        if (r.ecma) return .{ .min = @min(min, 1), .max = @min(min, 1) };
        return .{ .min = @min(min, 1), .max = @min(max orelse 1, 1) };
    }

    /// Whether each time past the minimum of an operand is bracketed by `loop_begin` and
    /// `loop_end`: in ECMAScript, where the operand can match empty.
    fn checks(r: Repeats, empty_ok: bool) bool {
        return r.ecma and empty_ok;
    }

    /// Whether `x*` over an `x` that can match empty is `(x+)?`, so that once `x` has matched
    /// empty the loop prefers to stop (regex issue 779): Rust's.
    fn plusQuestion(r: Repeats, empty_ok: bool) bool {
        return !r.ecma and empty_ok;
    }

    /// Whether each time of an atom that may be taken more than once clears its groups first.
    fn clears(r: Repeats) bool {
        return r.ecma;
    }
};

/// What a node can match, read once per node, children first.
const Prop = struct {
    /// It can match the empty string.
    empty_ok: bool,
    /// It matches nothing but the empty string.
    only_empty: bool,
    /// Every match begins at the haystack's start.
    anchored: bool,
    /// The lowest and highest group it holds: a node's groups are numbered in a run.
    groups: ?[2]u32 = null,
};

fn joinGroups(a: ?[2]u32, b: ?[2]u32) ?[2]u32 {
    const x = a orelse return b;
    const y = b orelse return a;
    return .{ @min(x[0], y[0]), @max(x[1], y[1]) };
}

const Frame = struct {
    node: Hir.Index,
    /// The first state of this node's fragment: what a repetition copies starts here.
    lo: u32,
    step: u32 = 0,
    acc: Fragment = .{ .start = unset, .end = unset },
    min: u32 = 0,
    max: ?u32 = null,
    /// The `clear` heading each time of an ECMAScript repetition, or `unset`.
    clear: u32 = unset,
};

const Step = union(enum) { descend: Hir.Index, finished: Fragment };

/// A state of the UTF-8 compiler not yet finished: its transitions so far and the last one,
/// whose target is not known until the next sequence diverges from it.
const Utf8Node = struct {
    trans: [256]Trans = undefined,
    n: u32 = 0,
    last: ?utf8.Range = null,

    fn setLast(node: *Utf8Node, next: u32) void {
        const last = node.last orelse return;
        aegis.assert.invariant(node.n < node.trans.len, "a state's byte ranges are apart");
        node.trans[node.n] = .{ .lo = last.lo, .hi = last.hi, .next = next };
        node.n += 1;
        node.last = null;
    }
};

const Compiler = struct {
    scratch: Allocator,
    b: Builder,
    hir: *const Hir,
    repeats: Repeats,
    props: []Prop = &.{},
    frames: std.ArrayList(Frame) = .empty,
    utf8_nodes: [5]Utf8Node = @splat(.{}),
    utf8_depth: usize = 0,
    /// Finished states of the class being compiled, by their transitions' hash.
    cache: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn run(c: *Compiler) BuildError!Starts {
        try c.properties();
        const s0 = try c.b.add(.{ .capture = .{ .group = 0, .slot = 0, .next = unset } });
        const body = try c.walk(c.hir.root);
        const e0 = try c.b.add(.{ .capture = .{ .group = 0, .slot = 1, .next = unset } });
        const m = try c.b.add(.match);
        c.b.patch(s0, body.start);
        c.b.patch(body.end, e0);
        c.b.patch(e0, m);
        const root = c.props[@backingInt(c.hir.root)];
        if (root.anchored) return .{ .anchored = s0, .unanchored = s0, .empty_ok = root.empty_ok };
        const loop = try c.b.addUnion(2, true);
        const any = try c.b.add(.{ .byte_range = .{ .lo = 0, .hi = 0xff, .next = loop } });
        c.b.patch(loop, any);
        c.b.patch(loop, s0);
        return .{ .anchored = s0, .unanchored = loop, .empty_ok = root.empty_ok };
    }

    fn properties(c: *Compiler) BuildError!void {
        const nodes = c.hir.nodes;
        c.props = try c.scratch.alloc(Prop, nodes.len);
        for (nodes, 0..) |node, i| {
            c.props[i] = switch (node) {
                .empty => .{ .empty_ok = true, .only_empty = true, .anchored = false },
                .literal, .unicode_class, .byte_class => .{ .empty_ok = false, .only_empty = false, .anchored = false },
                .look => |l| .{ .empty_ok = true, .only_empty = true, .anchored = l == .start_text },
                .repetition => |r| blk: {
                    const sub = c.prop(r.sub, i);
                    break :blk .{ .empty_ok = r.min == 0 or sub.empty_ok, .only_empty = sub.only_empty or r.max == 0, .anchored = r.min > 0 and sub.anchored, .groups = sub.groups };
                },
                .capture => |cap| blk: {
                    var p = c.prop(cap.sub, i);
                    p.groups = joinGroups(p.groups, .{ cap.index, cap.index });
                    break :blk p;
                },
                .concat => |slice| blk: {
                    var p: Prop = .{ .empty_ok = true, .only_empty = true, .anchored = false };
                    for (c.hir.childrenOf(slice), 0..) |child, k| {
                        const sub = c.prop(child, i);
                        p.empty_ok = p.empty_ok and sub.empty_ok;
                        p.only_empty = p.only_empty and sub.only_empty;
                        p.groups = joinGroups(p.groups, sub.groups);
                        if (k == 0) p.anchored = sub.anchored;
                    }
                    break :blk p;
                },
                .alternation => |slice| blk: {
                    var p: Prop = .{ .empty_ok = false, .only_empty = true, .anchored = slice.len > 0 };
                    for (c.hir.childrenOf(slice)) |child| {
                        const sub = c.prop(child, i);
                        p.empty_ok = p.empty_ok or sub.empty_ok;
                        p.only_empty = p.only_empty and sub.only_empty;
                        p.groups = joinGroups(p.groups, sub.groups);
                        p.anchored = p.anchored and sub.anchored;
                    }
                    break :blk p;
                },
                .lookahead => return error.Unsupported,
            };
        }
    }

    fn prop(c: *const Compiler, child: Hir.Index, parent: usize) Prop {
        aegis.assert.invariant(@backingInt(child) < parent, "a child comes before its parent");
        return c.props[@backingInt(child)];
    }

    fn walk(c: *Compiler, root: Hir.Index) BuildError!Fragment {
        c.frames.clearRetainingCapacity();
        var done: ?Fragment = try c.enter(root);
        while (c.frames.items.len > 0) {
            const got = done;
            done = null;
            switch (try c.advance(c.frames.items.len - 1, got)) {
                .descend => |child| done = try c.enter(child),
                .finished => |fragment| {
                    _ = c.frames.pop();
                    done = fragment;
                },
            }
        }
        return done orelse aegis.assert.never("the root compiles to a fragment");
    }

    /// A leaf's fragment, or null with a frame pushed for a node that has children.
    fn enter(c: *Compiler, first: Hir.Index) BuildError!?Fragment {
        var index = first;
        while (true) {
            var frame: Frame = .{ .node = index, .lo = c.b.len() };
            switch (c.hir.node(index)) {
                .empty => return try c.empty(),
                .literal => |bytes| return try c.literal(bytes),
                .unicode_class => |r| return try c.unicodeClass(r),
                .byte_class => |r| return try c.byteClass(r),
                .look => |l| {
                    const id = try c.b.add(.{ .look = .{ .look = l, .next = unset } });
                    return .{ .start = id, .end = id };
                },
                .capture => {},
                .concat => |slice| switch (slice.len) {
                    0 => return try c.empty(),
                    1 => {
                        index = c.hir.childrenOf(slice)[0];
                        continue;
                    },
                    else => {},
                },
                .alternation => |slice| switch (slice.len) {
                    0 => return try c.fail(),
                    1 => {
                        index = c.hir.childrenOf(slice)[0];
                        continue;
                    },
                    else => {},
                },
                .repetition => |r| {
                    // What matches only the empty string matches it once as well as many times.
                    var min = r.min;
                    var max = r.max;
                    if (c.props[@backingInt(r.sub)].only_empty) {
                        const kept = c.repeats.clamp(min, max);
                        min = kept.min;
                        max = kept.max;
                    }
                    if (max == 0) return try c.empty();
                    if (min == 1 and max == 1) {
                        index = r.sub;
                        continue;
                    }
                    frame.min = min;
                    frame.max = max;
                },
                .lookahead => return error.Unsupported,
            }
            try c.frames.append(c.scratch, frame);
            return null;
        }
    }

    fn advance(c: *Compiler, at: usize, got: ?Fragment) BuildError!Step {
        const f = &c.frames.items[at];
        switch (c.hir.node(f.node)) {
            .capture => |cap| {
                const slot = std.math.mul(u32, cap.index, 2) catch return error.TooLarge;
                if (got) |inner| {
                    const end = try c.b.add(.{ .capture = .{ .group = cap.index, .slot = slot + 1, .next = unset } });
                    c.b.patch(f.acc.start, inner.start);
                    c.b.patch(inner.end, end);
                    return .{ .finished = .{ .start = f.acc.start, .end = end } };
                }
                f.acc.start = try c.b.add(.{ .capture = .{ .group = cap.index, .slot = slot, .next = unset } });
                return .{ .descend = cap.sub };
            },
            .concat => |slice| {
                const children = c.hir.childrenOf(slice);
                if (got) |part| {
                    if (f.step == 1) {
                        f.acc = part;
                    } else {
                        c.b.patch(f.acc.end, part.start);
                        f.acc.end = part.end;
                    }
                }
                if (f.step < children.len) {
                    f.step += 1;
                    return .{ .descend = children[f.step - 1] };
                }
                return .{ .finished = f.acc };
            },
            .alternation => |slice| {
                const children = c.hir.childrenOf(slice);
                if (got) |part| {
                    c.b.patch(f.acc.start, part.start);
                    c.b.patch(part.end, f.acc.end);
                } else {
                    const start = try c.b.addUnion(children.len, false);
                    f.acc = .{ .start = start, .end = try c.b.add(.{ .empty = unset }) };
                }
                if (f.step < children.len) {
                    f.step += 1;
                    return .{ .descend = children[f.step - 1] };
                }
                return .{ .finished = f.acc };
            },
            .repetition => |r| {
                if (got) |operand| {
                    // The clear heads the operand, inside what the copies copy.
                    var template = operand;
                    if (f.clear != unset) {
                        c.b.patch(f.clear, operand.start);
                        template.start = f.clear;
                    }
                    return .{ .finished = try c.repeat(f.*, r, template) };
                }
                if (c.repeats.clears() and (f.max orelse 2) > 1) if (c.props[@backingInt(r.sub)].groups) |g| {
                    const first = std.math.mul(u32, g[0], 2) catch return error.TooLarge;
                    const end = std.math.add(u32, std.math.mul(u32, g[1], 2) catch return error.TooLarge, 2) catch return error.TooLarge;
                    f.clear = try c.b.add(.{ .clear = .{ .first = first, .end = end, .next = unset } });
                };
                return .{ .descend = r.sub };
            },
            else => aegis.assert.never("only a node with children has a frame"),
        }
    }

    /// `frame`'s repetition of `template`, the operand's states just made, which nothing has
    /// joined yet: each further time is a copy of them, all made before any is joined. Where
    /// `Repeats.checks`, each time past the minimum is bracketed by `loop_begin` and `loop_end`,
    /// and an unbounded loop goes round a copy of its own, apart from the mandatory times.
    fn repeat(c: *Compiler, frame: Frame, r: Hir.Repetition, template: Fragment) BuildError!Fragment {
        const lo = frame.lo;
        const hi = c.b.len();
        const empty_ok = c.props[@backingInt(r.sub)].empty_ok;
        const checked = c.repeats.checks(empty_ok);
        const count: u32 = frame.max orelse if (checked) frame.min + 1 else @max(frame.min, 1);
        var copies: u32 = 1;
        while (copies < count) : (copies += 1) try c.b.copy(lo, hi);
        const times: Times = .{ .template = template, .width = hi - lo };
        const lazy = !r.greedy;
        const max = frame.max orelse {
            if (checked) {
                // Round and round a time that must read something: `loop_end` stops one that
                // read nothing, and the loop's other way leaves.
                const loop = try c.b.addUnion(2, lazy);
                const body = try c.checkedTime(times.at(frame.min));
                c.b.patch(loop, body.start);
                c.b.patch(body.end, loop);
                if (frame.min == 0) return .{ .start = loop, .end = loop };
                const prefix = c.chain(times, 0, frame.min);
                c.b.patch(prefix.end, loop);
                return .{ .start = prefix.start, .end = loop };
            }
            if (frame.min == 0) {
                if (!c.repeats.plusQuestion(empty_ok)) {
                    const loop = try c.b.addUnion(2, lazy);
                    c.b.patch(loop, template.start);
                    c.b.patch(template.end, loop);
                    return .{ .start = loop, .end = loop };
                }
                // `(x+)?`: `x*` with its alternatives in this order would prefer, once `x` has
                // matched empty, to stop (regex issue 779).
                const plus = try c.b.addUnion(2, lazy);
                c.b.patch(template.end, plus);
                c.b.patch(plus, template.start);
                const question = try c.b.addUnion(2, lazy);
                const end = try c.b.add(.{ .empty = unset });
                c.b.patch(question, template.start);
                c.b.patch(question, end);
                c.b.patch(plus, end);
                return .{ .start = question, .end = end };
            }
            const prefix = c.chain(times, 0, frame.min);
            const last = times.at(frame.min - 1);
            const loop = try c.b.addUnion(2, lazy);
            c.b.patch(last.end, loop);
            c.b.patch(loop, last.start);
            return .{ .start = prefix.start, .end = loop };
        };
        if (frame.min == max) return c.chain(times, 0, max);
        // The optional times each leave straight to the end, so taking one closes over two
        // states, not every later one.
        var start: u32 = unset;
        var prev: u32 = unset;
        if (frame.min > 0) {
            const prefix = c.chain(times, 0, frame.min);
            start = prefix.start;
            prev = prefix.end;
        }
        const end = try c.b.add(.{ .empty = unset });
        var j = frame.min;
        while (j < max) : (j += 1) {
            const option = try c.b.addUnion(2, lazy);
            if (prev == unset) start = option else c.b.patch(prev, option);
            const time = if (checked) try c.checkedTime(times.at(j)) else times.at(j);
            c.b.patch(option, time.start);
            c.b.patch(option, end);
            prev = time.end;
        }
        c.b.patch(prev, end);
        return .{ .start = start, .end = end };
    }

    /// `time` bracketed by `loop_begin` and `loop_end`: a time past the minimum, which fails if
    /// it reads nothing.
    fn checkedTime(c: *Compiler, time: Fragment) BuildError!Fragment {
        const begin = try c.b.add(.{ .loop_begin = unset });
        const end = try c.b.add(.{ .loop_end = unset });
        c.b.patch(begin, time.start);
        c.b.patch(time.end, end);
        return .{ .start = begin, .end = end };
    }

    /// Times `from` to `to` of a repetition, joined one after another.
    fn chain(c: *Compiler, times: Times, from: u32, to: u32) Fragment {
        var j = from + 1;
        while (j < to) : (j += 1) c.b.patch(times.at(j - 1).end, times.at(j).start);
        return .{ .start = times.at(from).start, .end = times.at(to - 1).end };
    }

    fn empty(c: *Compiler) BuildError!Fragment {
        const id = try c.b.add(.{ .empty = unset });
        return .{ .start = id, .end = id };
    }

    fn fail(c: *Compiler) BuildError!Fragment {
        const id = try c.b.add(.fail);
        return .{ .start = id, .end = id };
    }

    fn literal(c: *Compiler, bytes: []const u8) BuildError!Fragment {
        if (bytes.len == 0) return c.empty();
        var fragment: Fragment = .{ .start = unset, .end = unset };
        for (bytes) |byte| {
            const id = try c.b.add(.{ .byte_range = .{ .lo = byte, .hi = byte, .next = unset } });
            if (fragment.start == unset) fragment.start = id else c.b.patch(fragment.end, id);
            fragment.end = id;
        }
        return fragment;
    }

    /// One state reading any byte of the ranges: they are apart, so none is preferred.
    fn byteClass(c: *Compiler, ranges: []const [2]u8) BuildError!Fragment {
        aegis.assert.invariant(ranges.len <= 256, "a class's byte ranges are apart");
        const end = try c.b.add(.{ .empty = unset });
        var list: [256]Trans = undefined;
        for (ranges, 0..) |r, i| list[i] = .{ .lo = r[0], .hi = r[1], .next = end };
        return .{ .start = try c.b.addSparse(list[0..ranges.len]), .end = end };
    }

    fn unicodeClass(c: *Compiler, ranges: []const [2]u21) BuildError!Fragment {
        if (ranges.len == 0 or ranges[ranges.len - 1][1] <= 0x7f) {
            var bytes: [128][2]u8 = undefined;
            for (ranges, 0..) |r, i| bytes[i] = .{ @intCast(r[0]), @intCast(r[1]) };
            return c.byteClass(bytes[0..ranges.len]);
        }
        const target = try c.b.add(.{ .empty = unset });
        c.cache.clearRetainingCapacity();
        c.utf8_nodes[0] = .{};
        c.utf8_depth = 1;
        for (ranges) |r| {
            var sequences: utf8.Sequences = .init(r[0], r[1]);
            while (sequences.next()) |sequence| try c.utf8Add(sequence.slice(), target);
        }
        try c.utf8CompileFrom(0, target);
        aegis.assert.invariant(c.utf8_depth == 1 and c.utf8_nodes[0].last == null, "every sequence is finished");
        const root = &c.utf8_nodes[0];
        return .{ .start = try c.utf8Compile(root.trans[0..root.n]), .end = target };
    }

    fn utf8Add(c: *Compiler, ranges: []const utf8.Range, target: u32) BuildError!void {
        var prefix: usize = 0;
        while (prefix < ranges.len and prefix < c.utf8_depth) : (prefix += 1) {
            const last = c.utf8_nodes[prefix].last orelse break;
            if (!last.eql(ranges[prefix])) break;
        }
        aegis.assert.invariant(prefix < ranges.len, "no sequence in order is a prefix of the next");
        try c.utf8CompileFrom(prefix, target);
        const top = &c.utf8_nodes[c.utf8_depth - 1];
        aegis.assert.invariant(top.last == null, "the deepest kept state has no pending transition");
        top.last = ranges[prefix];
        for (ranges[prefix + 1 ..]) |r| {
            aegis.assert.invariant(c.utf8_depth < c.utf8_nodes.len, "a sequence is at most four ranges");
            c.utf8_nodes[c.utf8_depth] = .{ .last = r };
            c.utf8_depth += 1;
        }
    }

    /// Finishes every pending state deeper than `from`: the next sequence leaves them.
    fn utf8CompileFrom(c: *Compiler, from: usize, target: u32) BuildError!void {
        var next = target;
        while (from + 1 < c.utf8_depth) {
            c.utf8_depth -= 1;
            const node = &c.utf8_nodes[c.utf8_depth];
            node.setLast(next);
            next = try c.utf8Compile(node.trans[0..node.n]);
        }
        c.utf8_nodes[c.utf8_depth - 1].setLast(next);
    }

    /// The state with these transitions: one already made if it is equal, or a new one.
    fn utf8Compile(c: *Compiler, list: []const Trans) BuildError!u32 {
        var hasher: std.hash.Wyhash = .init(0);
        for (list) |t| {
            hasher.update(&.{ t.lo, t.hi });
            hasher.update(std.mem.asBytes(&t.next));
        }
        const slot = try c.cache.getOrPut(c.b.gpa, hasher.final());
        if (slot.found_existing and c.b.sameSparse(slot.value_ptr.*, list)) return slot.value_ptr.*;
        const id = try c.b.addSparse(list);
        slot.value_ptr.* = id;
        return id;
    }
};

/// The times of a repetition: the template and its copies, laid out one after another.
const Times = struct {
    template: Fragment,
    width: u32,

    fn at(t: Times, j: u32) Fragment {
        const shift = j * t.width;
        return .{ .start = t.template.start + shift, .end = t.template.end + shift };
    }
};

const Builder = struct {
    /// Charged to `Limits.nfa`.
    gpa: Allocator,
    states: std.ArrayList(BState) = .empty,
    trans: std.ArrayList(Trans) = .empty,
    alts: std.ArrayList(u32) = .empty,

    fn len(b: *const Builder) u32 {
        return @intCast(b.states.items.len);
    }

    fn room(have: usize, more: usize) error{TooLarge}!void {
        if (more >= unset - have) return error.TooLarge;
    }

    fn add(b: *Builder, s: BState) BuildError!u32 {
        try room(b.states.items.len, 1);
        const id = b.len();
        try b.states.append(b.gpa, s);
        return id;
    }

    fn addUnion(b: *Builder, n: usize, lazy: bool) BuildError!u32 {
        try room(b.alts.items.len, n);
        const start: u32 = @intCast(b.alts.items.len);
        try b.alts.appendNTimes(b.gpa, unset, n);
        return b.add(.{ .alternation = .{ .start = start, .len = @intCast(n), .filled = 0, .lazy = lazy } });
    }

    fn addSparse(b: *Builder, list: []const Trans) BuildError!u32 {
        try room(b.trans.items.len, list.len);
        const start: u32 = @intCast(b.trans.items.len);
        try b.trans.appendSlice(b.gpa, list);
        return b.add(.{ .sparse = .{ .start = start, .len = @intCast(list.len) } });
    }

    fn sameSparse(b: *const Builder, id: u32, list: []const Trans) bool {
        const slice = switch (b.states.items[id]) {
            .sparse => |s| s,
            else => return false,
        };
        if (slice.len != list.len) return false;
        for (b.trans.items[slice.start..][0..slice.len], list) |x, y| {
            if (x.lo != y.lo or x.hi != y.hi or x.next != y.next) return false;
        }
        return true;
    }

    /// Joins `from`'s open end to `to`: its next state, or its next unfilled alternative.
    fn patch(b: *Builder, from: u32, to: u32) void {
        switch (b.states.items[from]) {
            .empty => |*next| next.* = to,
            .byte_range => |*t| t.next = to,
            .look => |*l| l.next = to,
            .capture => |*cap| cap.next = to,
            .clear => |*cl| cl.next = to,
            .loop_begin, .loop_end => |*next| next.* = to,
            .alternation => |*u| {
                aegis.assert.invariant(u.filled < u.len, "an alternation is joined to as many states as it holds");
                const slot = if (u.lazy) u.len - 1 - u.filled else u.filled;
                b.alts.items[u.start + slot] = to;
                u.filled += 1;
            },
            // Nothing follows what never matches.
            .fail => {},
            .sparse, .match => aegis.assert.never("a fragment ends where it can be joined"),
        }
    }

    /// Appends a copy of states `lo` to `hi`, each reference moved with them.
    fn copy(b: *Builder, lo: u32, hi: u32) BuildError!void {
        try room(b.states.items.len, hi - lo);
        const shift = b.len() - lo;
        const move: Move = .{ .lo = lo, .hi = hi, .shift = shift };
        for (lo..hi) |i| {
            const moved: BState = switch (b.states.items[i]) {
                .empty => |next| .{ .empty = move.id(next) },
                .byte_range => |t| .{ .byte_range = .{ .lo = t.lo, .hi = t.hi, .next = move.id(t.next) } },
                .look => |l| .{ .look = .{ .look = l.look, .next = move.id(l.next) } },
                .capture => |cap| .{ .capture = .{ .group = cap.group, .slot = cap.slot, .next = move.id(cap.next) } },
                .clear => |cl| .{ .clear = .{ .first = cl.first, .end = cl.end, .next = move.id(cl.next) } },
                .loop_begin => |next| .{ .loop_begin = move.id(next) },
                .loop_end => |next| .{ .loop_end = move.id(next) },
                .sparse => |slice| blk: {
                    try room(b.trans.items.len, slice.len);
                    const start: u32 = @intCast(b.trans.items.len);
                    for (slice.start..slice.start + slice.len) |k| {
                        const t = b.trans.items[k];
                        try b.trans.append(b.gpa, .{ .lo = t.lo, .hi = t.hi, .next = move.id(t.next) });
                    }
                    break :blk .{ .sparse = .{ .start = start, .len = slice.len } };
                },
                .alternation => |u| blk: {
                    try room(b.alts.items.len, u.len);
                    const start: u32 = @intCast(b.alts.items.len);
                    for (u.start..u.start + u.len) |k| {
                        const alt = b.alts.items[k];
                        try b.alts.append(b.gpa, move.id(alt));
                    }
                    break :blk .{ .alternation = .{ .start = start, .len = u.len, .filled = u.filled, .lazy = u.lazy } };
                },
                .fail => .fail,
                .match => .match,
            };
            try b.states.append(b.gpa, moved);
        }
    }

    /// The automaton: empty states gone, each reference to one taken to the state it leads to.
    fn finish(b: *Builder, gpa: Allocator, scratch: Allocator, starts: Starts, hir: *const Hir, utf8_mode: bool) Error!Nfa {
        const states = b.states.items;
        const remap = try scratch.alloc(u32, states.len);
        var count: u32 = 0;
        var transitions: usize = 0;
        var alternatives: usize = 0;
        var looks: Nfa.LookSet = .empty;
        var loop_checks = false;
        for (states, remap) |s, *r| {
            switch (s) {
                .empty => {
                    r.* = unset;
                    continue;
                },
                .sparse => |slice| if (slice.len >= 2) {
                    transitions += slice.len;
                },
                .alternation => |u| if (u.len >= 3) {
                    alternatives += u.len;
                },
                .look => |l| looks.insert(l.look),
                .loop_begin, .loop_end => loop_checks = true,
                else => {},
            }
            r.* = count;
            count += 1;
        }
        // A chain of empty states leads to one that is not: the compiler never closes a loop
        // of them, since every loop it makes passes an alternation.
        for (states, 0..) |s, i| {
            if (s != .empty or remap[i] != unset) continue;
            var target = i;
            var steps: usize = 0;
            while (states[target] == .empty and remap[target] == unset) : (steps += 1) {
                aegis.assert.invariant(steps < states.len, "no loop of empty states");
                target = states[target].empty;
                aegis.assert.invariant(target != unset, "every empty state is joined to what follows");
            }
            const final = remap[target];
            var k = i;
            while (states[k] == .empty and remap[k] == unset) {
                remap[k] = final;
                k = states[k].empty;
            }
        }

        const out_states = try gpa.alloc(Nfa.State, count);
        errdefer gpa.free(out_states);
        const out_trans = try gpa.alloc(Nfa.Transition, transitions);
        errdefer gpa.free(out_trans);
        const out_alts = try gpa.alloc(Nfa.StateId, alternatives);
        errdefer gpa.free(out_alts);
        const map: Remap = .{ .remap = remap };
        var t_at: u32 = 0;
        var a_at: u32 = 0;
        for (states, remap) |s, r| {
            const out: Nfa.State = switch (s) {
                .empty => continue,
                .byte_range => |t| .{ .byte_range = .{ .lo = t.lo, .hi = t.hi, .next = map.id(t.next) } },
                .sparse => |slice| switch (slice.len) {
                    0 => .fail,
                    1 => blk: {
                        const t = b.trans.items[slice.start];
                        break :blk .{ .byte_range = .{ .lo = t.lo, .hi = t.hi, .next = map.id(t.next) } };
                    },
                    else => blk: {
                        const start = t_at;
                        for (b.trans.items[slice.start..][0..slice.len], out_trans[start..][0..slice.len]) |t, *o| {
                            o.* = .{ .lo = t.lo, .hi = t.hi, .next = map.id(t.next) };
                        }
                        t_at += slice.len;
                        break :blk .{ .sparse = .{ .start = start, .len = slice.len } };
                    },
                },
                .look => |l| .{ .look = .{ .look = l.look, .next = map.id(l.next) } },
                .alternation => |u| blk: {
                    aegis.assert.invariant(u.filled == u.len and u.len >= 2, "an alternation holds two or more states");
                    const alts = b.alts.items[u.start..][0..u.len];
                    if (u.len == 2) break :blk .{ .binary = .{ .first = map.id(alts[0]), .second = map.id(alts[1]) } };
                    const start = a_at;
                    for (alts, out_alts[start..][0..u.len]) |alt, *o| o.* = map.id(alt);
                    a_at += u.len;
                    break :blk .{ .alternation = .{ .start = start, .len = u.len } };
                },
                .capture => |cap| .{ .capture = .{ .group = cap.group, .slot = cap.slot, .next = map.id(cap.next) } },
                .clear => |cl| .{ .clear = .{ .first = cl.first, .end = cl.end, .next = map.id(cl.next) } },
                .loop_begin => |next| .{ .loop_begin = map.id(next) },
                .loop_end => |next| .{ .loop_end = map.id(next) },
                .fail => .fail,
                .match => .match,
            };
            out_states[r] = out;
        }

        const groups = hir.captures + 1;
        const names = try gpa.alloc(?[]const u8, groups);
        errdefer gpa.free(names);
        @memset(names, null);
        var name_len: usize = 0;
        for (hir.nodes) |node| switch (node) {
            .capture => |cap| if (cap.name) |name| {
                name_len += name.len;
            },
            else => {},
        };
        const name_bytes = try gpa.alloc(u8, name_len);
        errdefer gpa.free(name_bytes);
        var n_at: usize = 0;
        for (hir.nodes) |node| switch (node) {
            .capture => |cap| if (cap.name) |name| {
                aegis.assert.invariant(cap.index < groups, "a group's number is one the pattern counts");
                @memcpy(name_bytes[n_at..][0..name.len], name);
                names[cap.index] = name_bytes[n_at..][0..name.len];
                n_at += name.len;
            },
            else => {},
        };

        return .{
            .states = out_states,
            .transitions = out_trans,
            .alternatives = out_alts,
            .start_anchored = map.id(starts.anchored),
            .start_unanchored = map.id(starts.unanchored),
            .groups = groups,
            .names = names,
            .name_bytes = name_bytes,
            .looks = looks,
            .utf8 = utf8_mode,
            .empty_ok = starts.empty_ok,
            .loop_checks = loop_checks,
        };
    }
};

const Move = struct {
    lo: u32,
    hi: u32,
    shift: u32,

    fn id(m: Move, state: u32) u32 {
        if (state == unset) return unset;
        aegis.assert.invariant(state >= m.lo and state < m.hi, "a fragment refers only to its own states");
        return state + m.shift;
    }
};

const Remap = struct {
    remap: []const u32,

    fn id(m: Remap, state: u32) Nfa.StateId {
        aegis.assert.invariant(state != unset, "every state is joined to what follows");
        const r = m.remap[state];
        aegis.assert.invariant(r != unset, "an empty state leads to one that is kept");
        return @fromBackingInt(r);
    }
};
