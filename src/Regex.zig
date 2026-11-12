//! A compiled pattern: is-match, find, captures and every match in turn. Immutable once
//! compiled, so any number of threads search it, each with a `Cache` of its own.
//!
//! Engines (`strategy.zig` chooses how they are put together): the lazy DFA finds whether there
//! is a match and where the leftmost-first one ends; the reverse lazy DFA, read back from that
//! end, where it starts; the one-pass DFA where the pattern is one-pass, else the bounded
//! backtracker, or the PikeVM where the match is longer than the backtracker's bits hold,
//! anchored over the match, its captures. Where the reverse
//! lazy DFA quits or gives up, the PikeVM searches the span cut at the end; where the lazy DFA
//! does, the whole span from its start; a pattern with no lazy DFA (`engines`) is the PikeVM's
//! alone. A pattern whose every match ends at the haystack's end is read back from there and
//! never forward. Each engine is linear in the haystack and the automaton, and is tested
//! against the others.
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
const Hir = @import("hir/Hir.zig");
const Nfa = @import("nfa/Nfa.zig");
const compile_mod = @import("nfa/compile.zig");
const pikevm = @import("pikevm.zig");
const lazy = @import("lazy.zig");
const strategy_mod = @import("strategy.zig");
const backtrack = @import("backtrack.zig");
const onepass_mod = @import("onepass.zig");
const prefilter_mod = @import("prefilter.zig");
const literals_mod = @import("hir/literals.zig");
const suffix_mod = @import("hir/suffix.zig");
const inner_mod = @import("hir/inner.zig");
const Automaton = @import("Automaton.zig");
const oracle = @import("oracle.zig");

pub const Span = pikevm.Span;
pub const Input = pikevm.Input;
pub const Diagnostic = diagnostic_zig.Diagnostic;

gpa: Allocator,
nfa: Nfa,
/// The lazy DFA's alphabet and cache sizes; null when `Limits.lazy_dfa` holds too few states.
dfa: ?lazy.Dfa,
/// The automaton of the matches read backwards and its lazy DFA; null without a forward lazy
/// DFA, or where either is past its limit.
reverse: ?Reverse,
/// How searches put the engines together, chosen from the automaton and the engines it has.
strategy: strategy_mod.Strategy,
/// The bounded backtracker's bits and stack; null where `Limits.backtrack` holds no position.
backtracker: ?backtrack.Sizes,
/// The one-pass DFA; null where the pattern is not one-pass or its table passes
/// `Limits.onepass`.
onepass: ?onepass_mod.Dfa,
/// Where a match may start, from the literals every match starts with; null where none helps
/// or `Options.prefilter` is off.
prefilter: ?prefilter_mod.Prefilter,
/// The literal every match ends with and its prefilter, where `Strategy.reverse_suffix` leads.
suffix: ?Suffix,

/// The literals X's matches start with, where `Strategy.reverse_inner` leads: their prefilter,
/// and P's reverse automaton and lazy DFA.
inner: ?Inner,
/// The forward lazy DFA of the all kind, for the stepping automaton: worked out at compile, its
/// states in an `Automaton.Cache` of the walker's; null where `Limits.lazy_dfa` is too small.
stepper: ?lazy.Dfa = null,
/// Lookaround's oracle (spectra.md §3.1), where the pattern holds a lookaround: null otherwise.
look: ?Look = null,

/// What a pattern with lookaround searches with. `find`, `captures` and `findAll` run the PikeVM
/// over the main automaton's `check` states, answered by rows stored before it reads a byte
/// (`search`: every lookaround the main expression queries stored). `isMatch` runs one scan of
/// the strings-only main automaton (`match_nfa`) read the way that streams the lookarounds it
/// queries directly (`match`), so it stores only the ones nested the other way. The lazy DFAs,
/// the backtracker, the one-pass DFA and the literal strategies do not run such patterns yet.
const Look = struct {
    search: oracle.Plan,
    match: oracle.Plan,
    match_nfa: Nfa,
    match_scan: oracle.Scan,
    /// `Limits.oracle`: each store's capacity, where its plan stores rows.
    capacity: usize,
    /// For each positive lookaround holding groups, by number, the automaton of its body with
    /// its groups, read its way (`backward` for a lookbehind): what rebuilds its groups from the
    /// position the main match last took it at. Null for the others.
    bodies: []?Body,

    const Body = struct { nfa: Nfa, scan: oracle.Scan, slot: u32, groups: [2]u32 };

    fn deinit(l: *Look, gpa: Allocator) void {
        l.search.deinit(gpa);
        l.match.deinit(gpa);
        l.match_nfa.deinit(gpa);
        for (l.bodies) |*b| if (b.*) |*body| body.nfa.deinit(gpa);
        gpa.free(l.bodies);
    }

    fn searchCapacity(l: *const Look) usize {
        return if (l.search.stored > 0) l.capacity else 0;
    }

    fn matchCapacity(l: *const Look) usize {
        return if (l.match.stored > 0) l.capacity else 0;
    }
};

const Suffix = struct { prefilter: prefilter_mod.Prefilter, len: usize };

const Inner = struct {
    prefilter: prefilter_mod.Prefilter,
    nfa: Nfa,
    dfa: lazy.Dfa,

    fn deinit(i: *Inner, gpa: Allocator) void {
        i.prefilter.deinit(gpa);
        i.nfa.deinit(gpa);
    }
};

const Reverse = struct { nfa: Nfa, dfa: lazy.Dfa };

pub const Options = struct {
    syntax: Syntax = .{},
    limits: Limits = .{},
    /// Where a refused pattern was refused, and why.
    diagnostic: ?*Diagnostic = null,
    /// Whether searches skip ahead with a prefilter where the pattern's literals give one: off
    /// only to compare the paths.
    prefilter: bool = true,
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
    if (hir.lookarounds > 0) return compileLookaround(gpa, a, &hir, options, whole);
    const nfa = try compile_mod.compile(gpa, &hir, .{
        .limits = options.limits,
        .utf8 = options.syntax.utf8,
        .span = whole,
        .ecma = options.syntax.dialect == .ecmascript,
    }, options.diagnostic);
    errdefer {
        var held = nfa;
        held.deinit(gpa);
    }
    const dfa = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .forward, .leftmost_first);
    var reverse: ?Reverse = if (dfa == null) null else try compileReverse(gpa, &hir, options, whole);
    errdefer if (reverse) |*r| r.nfa.deinit(gpa);
    var one = try onepass_mod.build(gpa, &nfa, options.limits.onepass.raw());
    errdefer if (one) |*d| d.deinit(gpa);
    const sizes = backtrack.sizes(&nfa, options.limits.backtrack.raw());
    const backtracker: ?backtrack.Sizes = if (sizes.longest() != null) sizes else null;
    const prefixes = try (literals_mod.Extractor{}).extract(a, &hir);
    var prefilter = if (options.prefilter) try prefilter_mod.choose(gpa, &prefixes, options.limits.prefilter.raw()) else null;
    errdefer if (prefilter) |*p| p.deinit(gpa);
    var suffix: ?Suffix = if (options.prefilter and prefilter == null and dfa != null and reverse != null) try suffixOf(gpa, a, &hir, options.limits.prefilter.raw()) else null;
    errdefer if (suffix) |*s| s.prefilter.deinit(gpa);
    var strategy = strategy_mod.choose(&nfa, dfa != null, reverse != null, prefilter != null and prefilter.?.exactLen() != null and literalAlone(&nfa, &prefixes), suffix != null);
    if (strategy != .reverse_suffix) if (suffix) |*s| {
        s.prefilter.deinit(gpa);
        suffix = null;
    };
    // Reverse inner where nothing better leads: no prefilter, no suffix, anchored at neither end.
    var inner: ?Inner = if (options.prefilter and strategy == .core and prefilter == null) try innerOf(gpa, a, &hir, options, whole) else null;
    errdefer if (inner) |*i| i.deinit(gpa);
    if (inner != null) strategy = .reverse_inner;
    // What each search's cache would hold, refused before any is made.
    if ((cacheBytesOf(&nfa, if (dfa) |*d| d else null, if (reverse) |*r| &r.dfa else null, backtracker, if (inner) |*i| &i.dfa else null) orelse std.math.maxInt(usize)) > options.limits.cache.raw()) {
        if (options.diagnostic) |d| d.* = .{ .span = whole, .reason = .cache_too_large };
        return error.TooLarge;
    }
    const stepper = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .forward, .all);
    return .{ .gpa = gpa, .nfa = nfa, .dfa = dfa, .reverse = reverse, .strategy = strategy, .backtracker = backtracker, .onepass = one, .prefilter = prefilter, .suffix = suffix, .inner = inner, .stepper = stepper };
}

/// A pattern with lookaround: the main automaton with `check` states, on the PikeVM alone, the
/// oracle's plans, and each positive lookaround's body with its groups (`Look`).
fn compileLookaround(gpa: Allocator, arena: Allocator, hir: *const Hir, options: Options, whole: Ast.Span) CompileError!Regex {
    const ecma = options.syntax.dialect == .ecmascript;
    var nfa = try compile_mod.compile(gpa, hir, .{ .limits = options.limits, .utf8 = options.syntax.utf8, .span = whole, .ecma = ecma, .lookaround = true }, options.diagnostic);
    errdefer nfa.deinit(gpa);
    const plan_options: oracle.PlanOptions = .{ .limits = options.limits, .utf8 = options.syntax.utf8, .span = whole };
    var search_options = plan_options;
    search_options.store_all = true;
    var search = try oracle.plan(gpa, hir, search_options, options.diagnostic);
    errdefer search.deinit(gpa);
    const bodies = try bodiesOf(gpa, arena, hir, options, whole);
    errdefer {
        for (bodies) |*b| if (b.*) |*body| body.nfa.deinit(gpa);
        gpa.free(bodies);
    }
    // `isMatch` reads the way most of the lookarounds the main expression queries read, so they
    // stream: all lookaheads, as zod's patterns are, read backward and store nothing.
    var ahead: usize = 0;
    var behind: usize = 0;
    for (search.rows) |r| if (r.parent == null) switch (r.scan) {
        .backward => ahead += 1,
        .forward => behind += 1,
    };
    const scan: oracle.Scan = if (ahead > behind) .backward else .forward;
    var match_options = plan_options;
    match_options.main = scan;
    var match = try oracle.plan(gpa, hir, match_options, options.diagnostic);
    errdefer match.deinit(gpa);
    var match_nfa = try compile_mod.compile(gpa, hir, .{ .limits = options.limits, .utf8 = options.syntax.utf8, .span = whole, .strings = true, .lookaround = true, .reverse = scan == .backward, .reverse_unanchored = scan == .backward }, options.diagnostic);
    errdefer match_nfa.deinit(gpa);
    const look: Look = .{ .search = search, .match = match, .match_nfa = match_nfa, .match_scan = scan, .capacity = options.limits.oracle.raw(), .bodies = bodies };
    var re: Regex = .{ .gpa = gpa, .nfa = nfa, .dfa = null, .reverse = null, .strategy = .pikevm, .backtracker = null, .onepass = null, .prefilter = null, .suffix = null, .inner = null, .look = look };
    if ((re.cacheBytesChecked() orelse std.math.maxInt(usize)) > options.limits.cache.raw()) {
        if (options.diagnostic) |d| d.* = .{ .span = whole, .reason = .cache_too_large };
        return error.TooLarge;
    }
    return re;
}

/// Each positive lookaround holding groups, by number: its body's automaton with its groups,
/// read its way, and the slots its groups take (`Look.Body`).
fn bodiesOf(gpa: Allocator, arena: Allocator, hir: *const Hir, options: Options, whole: Ast.Span) CompileError![]?Look.Body {
    const bodies = try gpa.alloc(?Look.Body, hir.lookarounds);
    @memset(bodies, null);
    errdefer {
        for (bodies) |*b| if (b.*) |*body| body.nfa.deinit(gpa);
        gpa.free(bodies);
    }
    const groups = try groupsUnder(arena, hir);
    for (hir.nodes) |node| switch (node) {
        .lookaround => |la| {
            if (la.negated) continue;
            const range = groups[@backingInt(la.sub)] orelse continue;
            var body = hir.*;
            body.root = la.sub;
            const scan: oracle.Scan = if (la.kind == .ahead) .forward else .backward;
            const nfa = try compile_mod.compile(gpa, &body, .{
                .limits = options.limits,
                .utf8 = options.syntax.utf8,
                .span = whole,
                .ecma = options.syntax.dialect == .ecmascript,
                .lookaround = true,
                .body = true,
                .backward = scan == .backward,
            }, options.diagnostic);
            bodies[la.index] = .{ .nfa = nfa, .scan = scan, .slot = range[0] * 2, .groups = range };
        },
        else => {},
    };
    return bodies;
}

/// The lowest and highest group under each node: nodes come children first, so one pass up.
fn groupsUnder(arena: Allocator, hir: *const Hir) Allocator.Error![]?[2]u32 {
    const out = try arena.alloc(?[2]u32, hir.nodes.len);
    for (hir.nodes, out) |node, *o| {
        o.* = switch (node) {
            .capture => |cap| join(out[@backingInt(cap.sub)], .{ cap.index, cap.index }),
            .repetition => |r| out[@backingInt(r.sub)],
            .lookaround => |la| out[@backingInt(la.sub)],
            .concat, .alternation => |slice| blk: {
                var acc: ?[2]u32 = null;
                for (hir.childrenOf(slice)) |child| acc = join(acc, out[@backingInt(child)]);
                break :blk acc;
            },
            else => null,
        };
    }
    return out;
}

fn join(a: ?[2]u32, b: ?[2]u32) ?[2]u32 {
    const x = a orelse return b;
    const y = b orelse return a;
    return .{ @min(x[0], y[0]), @max(x[1], y[1]) };
}

/// The split of `hir`'s top concatenation P·X at the first child after the first whose
/// matches start with literals a prefilter finds, with P's reverse automaton and its lazy DFA,
/// where hir/inner.zig proves the split may lead; null otherwise.
fn innerOf(gpa: Allocator, arena: Allocator, hir: *const Hir, options: Options, whole: Ast.Span) Allocator.Error!?Inner {
    const kids = inner_mod.topConcat(hir) orelse return null;
    for (1..kids.len) |at| {
        const view = inner_mod.rootedAt(hir, kids[at]);
        var seq = try (literals_mod.Extractor{}).extract(arena, &view);
        const lits = seq.literals() orelse continue;
        // Prefixes of X's first part only: the literals start a match of X, not end one.
        if (seq.list) |*list| for (list.items) |*lit| {
            lit.exact = false;
        };
        var p = try prefilter_mod.choose(gpa, &seq, options.limits.prefilter.raw()) orelse continue;
        errdefer p.deinit(gpa);
        if (!try inner_mod.leads(arena, hir, kids, at, lits)) {
            p.deinit(gpa);
            return null;
        }
        const prefix = try inner_mod.prefix(arena, hir, kids, at);
        var nfa = compile_mod.compile(gpa, &prefix, .{
            .limits = options.limits,
            .utf8 = options.syntax.utf8,
            .span = whole,
            .ecma = options.syntax.dialect == .ecmascript,
            .reverse = true,
        }, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => {
                p.deinit(gpa);
                return null;
            },
            error.Unsupported => aegis.assert.never("what compiles forward compiles reversed"),
        };
        const dfa = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .reverse, .leftmost_first) orelse {
            nfa.deinit(gpa);
            p.deinit(gpa);
            return null;
        };
        return .{ .prefilter = p, .nfa = nfa, .dfa = dfa };
    }
    return null;
}

/// The literal every match of `hir` ends with, its longest such, with its prefilter, where
/// hir/suffix.zig proves it may lead the search; null otherwise.
fn suffixOf(gpa: Allocator, arena: Allocator, hir: *const Hir, limit: usize) Allocator.Error!?Suffix {
    const seq = try (literals_mod.Extractor{ .kind = .suffix }).extract(arena, hir);
    const lits = seq.literals() orelse return null;
    if (lits.len == 0) return null;
    var common = lits[0].bytes;
    for (lits[1..]) |lit| {
        var n: usize = 0;
        while (n < common.len and n < lit.bytes.len and common[common.len - 1 - n] == lit.bytes[lit.bytes.len - 1 - n]) n += 1;
        common = common[common.len - n ..];
    }
    if (common.len == 0 or common.len > prefilter_mod.max_literal) return null;
    if (!try suffix_mod.leads(arena, hir, common)) return null;
    const one = try literals_mod.Seq.singleton(arena, .{ .bytes = common, .exact = false });
    const p = try prefilter_mod.choose(gpa, &one, limit) orelse return null;
    return .{ .prefilter = p, .len = common.len };
}

/// Whether the prefilter chosen from `prefixes` finds each match whole: the pattern asserts
/// nothing, and its matches are one exact literal the prefilter keeps, or exact single bytes.
fn literalAlone(nfa: *const Nfa, prefixes: *const literals_mod.Seq) bool {
    if (nfa.looks.count() != 0) return false;
    const lits = prefixes.literals() orelse return false;
    for (lits) |lit| if (!lit.exact) return false;
    if (lits.len == 1) return lits[0].bytes.len <= prefilter_mod.max_literal;
    for (lits) |lit| if (lit.bytes.len != 1) return false;
    return true;
}

/// The reverse automaton and its lazy DFA, or null where the automaton passes `Limits.nfa` (a
/// UTF-8 class reversed is larger than forward) or the store cannot hold its fewest states: the
/// PikeVM then finds where a match starts.
fn compileReverse(gpa: Allocator, hir: *const Hir, options: Options, whole: Ast.Span) Allocator.Error!?Reverse {
    var nfa = compile_mod.compile(gpa, hir, .{
        .limits = options.limits,
        .utf8 = options.syntax.utf8,
        .span = whole,
        .ecma = options.syntax.dialect == .ecmascript,
        .reverse = true,
    }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return null,
        error.Unsupported => aegis.assert.never("what compiles forward compiles reversed"),
    };
    const dfa = lazy.build(&nfa, options.limits.lazy_dfa.raw(), .reverse, .leftmost_first) orelse {
        nfa.deinit(gpa);
        return null;
    };
    return .{ .nfa = nfa, .dfa = dfa };
}

fn cacheBytesOf(nfa: *const Nfa, dfa: ?*const lazy.Dfa, reverse: ?*const lazy.Dfa, backtracker: ?backtrack.Sizes, inner: ?*const lazy.Dfa) ?usize {
    const pike = pikevm.sizes(nfa).bytes() orelse return null;
    const lazy_bytes = if (dfa) |d| d.bytes() else 0;
    const reverse_bytes = (if (reverse) |d| d.bytes() else 0) + (if (inner) |d| d.bytes() else 0);
    const back_bytes = if (backtracker) |b| b.bytes() else 0;
    const dfas = std.math.add(usize, lazy_bytes, reverse_bytes) catch return null;
    return std.math.add(usize, pike, std.math.add(usize, dfas, back_bytes) catch return null) catch null;
}

/// The bytes a `Cache` of this pattern allocates, every engine's: what `Limits.cache` bounded.
pub fn cacheBytes(re: *const Regex) usize {
    return re.cacheBytesChecked().?;
}

fn cacheBytesChecked(re: *const Regex) ?usize {
    const engines_bytes = cacheBytesOf(&re.nfa, if (re.dfa) |*d| d else null, if (re.reverse) |*r| &r.dfa else null, re.backtracker, if (re.inner) |*i| &i.dfa else null) orelse return null;
    const l = if (re.look) |*l| l else return engines_bytes;
    var stores = oracle.Cache.bytes(&l.search, null, l.searchCapacity()) + oracle.Cache.bytes(&l.match, &l.match_nfa, l.matchCapacity());
    for (l.bodies) |b| if (b) |body| {
        stores = std.math.add(usize, stores, pikevm.sizes(&body.nfa).bytes() orelse return null) catch return null;
    };
    return std.math.add(usize, engines_bytes, stores) catch null;
}

/// The longest haystack `search` takes on this pattern, or null where it takes any: where the
/// pattern holds a lookaround that search stores rows for, what `Limits.oracle` holds.
pub fn longestHaystack(re: *const Regex, search: Search) ?usize {
    const l = if (re.look) |*l| l else return null;
    return switch (search) {
        .is_match => oracle.longestFor(&l.match, l.capacity),
        .find, .captures, .find_all => oracle.longestFor(&l.search, l.capacity),
    };
}

/// The engines the compiled pattern has. The PikeVM always; the lazy DFA unless its store
/// (`Limits.lazy_dfa`) cannot hold the fewest states a search needs; the reverse lazy DFA with
/// it, unless its automaton passes `Limits.nfa` or its store is as short; the bounded
/// backtracker unless `Limits.backtrack` holds no position; the one-pass DFA where the pattern
/// is one-pass and its table fits `Limits.onepass`; a prefilter where the pattern's literals
/// give one.
pub const Engines = struct {
    pikevm: bool = true,
    lazy_dfa: bool,
    reverse_dfa: bool,
    backtrack: bool,
    onepass: bool,
    prefilter: bool,
};

/// The stepping automaton over the pattern (Automaton.zig); null where it has no lazy DFA, or one
/// with quit bytes (a Unicode word boundary). `re` stays where it is while the automaton is used.
pub fn automaton(re: *const Regex) ?Automaton {
    return Automaton.of(&re.nfa, if (re.stepper) |*d| d else return null);
}

pub fn engines(re: *const Regex) Engines {
    return .{ .lazy_dfa = re.dfa != null, .reverse_dfa = re.reverse != null, .backtrack = re.backtracker != null, .onepass = re.onepass != null, .prefilter = re.prefilter != null };
}

pub fn deinit(re: *Regex) void {
    re.nfa.deinit(re.gpa);
    if (re.reverse) |*r| r.nfa.deinit(re.gpa);
    if (re.onepass) |*d| d.deinit(re.gpa);
    if (re.prefilter) |*p| p.deinit(re.gpa);
    if (re.suffix) |*s| s.prefilter.deinit(re.gpa);
    if (re.inner) |*i| i.deinit(re.gpa);
    if (re.look) |*l| l.deinit(re.gpa);
    re.* = undefined;
}

/// What one task's searches of this pattern need, allocated once.
pub const Cache = struct {
    pike: pikevm.Cache,
    lazy: ?lazy.Cache,
    reverse: ?lazy.Cache,
    back: ?backtrack.Cache,
    /// P's reverse lazy DFA's store, for `Strategy.reverse_inner`.
    inner: ?lazy.Cache,
    /// Lookaround's stores: the rows `find`, `captures` and `findAll` read, and `isMatch`'s.
    look_search: ?oracle.Cache = null,
    look_match: ?oracle.Cache = null,
    /// A PikeVM's store for each lookaround body whose groups are rebuilt, by number.
    look_bodies: []?pikevm.Cache = &.{},
    /// How the last search was answered, for the tests that count each engine's work.
    last: Path = .pikevm,
    last_start: Start = .pikevm,
    /// Which engine wrote the last `find`'s or `captures`' slots, where one was asked.
    last_slots: Slots = .pikevm,

    pub const Path = enum {
        /// The PikeVM alone: no lazy DFA.
        pikevm,
        /// The lazy DFA, and the PikeVM over the span cut at the match's end where a start or
        /// captures were asked.
        lazy_dfa,
        /// The lazy DFA quit or gave up, and the PikeVM searched the span from its start.
        lazy_dfa_fell_back,
        /// `Strategy.reverse_anchored`: the reverse lazy DFA from the end, and nothing forward
        /// (and the PikeVM over the match where captures were asked). Where it quits or gives
        /// up, the search goes on as `core`, and says so in its own path.
        reverse_anchored,
        /// `Strategy.literal`: the prefilter alone.
        literal,
        /// `Strategy.reverse_suffix`: the suffix's prefilter, the reverse lazy DFA from an
        /// occurrence, and the lazy DFA anchored at the start it found.
        reverse_suffix,
        /// `Strategy.reverse_inner`: the inner literals' prefilter, P's reverse lazy DFA from
        /// an occurrence, and the lazy DFA anchored at the start it found.
        reverse_inner,
        /// `Input.whole`: the PikeVM over the span, a match counted only at its end.
        whole,
        /// A pattern with lookaround: the PikeVM over the main automaton, its `check` states
        /// answered by the rows stored before it read a byte.
        lookaround_pikevm,
        /// A pattern with lookaround, `isMatch`: one scan of the main expression with the
        /// lookarounds it queries streamed beside it.
        lookaround_scan,
    };

    /// How the last `find` or `captures` found where its match starts.
    pub const Start = enum {
        /// The PikeVM, over the span cut at the match's end.
        pikevm,
        /// The reverse lazy DFA, read back from the match's end.
        reverse_dfa,
        /// The reverse lazy DFA quit or gave up, and the PikeVM found it.
        reverse_dfa_fell_back,
        /// The prefilter, which found the match whole.
        prefilter,
    };

    pub const Slots = enum {
        /// The PikeVM: no backtracker, or a span longer than its bits hold.
        pikevm,
        /// The bounded backtracker.
        backtrack,
        /// The backtracker's stack filled, and the PikeVM searched.
        backtrack_fell_back,
        /// The one-pass DFA, over the match the lazy DFAs found.
        onepass,
    };

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.pike.deinit(gpa);
        if (c.lazy) |*l| l.deinit(gpa);
        if (c.reverse) |*r| r.deinit(gpa);
        if (c.back) |*b| b.deinit(gpa);
        if (c.inner) |*i| i.deinit(gpa);
        if (c.look_search) |*l| l.deinit(gpa);
        if (c.look_match) |*l| l.deinit(gpa);
        for (c.look_bodies) |*b| if (b.*) |*body| body.deinit(gpa);
        if (c.look_bodies.len > 0) gpa.free(c.look_bodies);
    }
};

pub fn cache(re: *const Regex, gpa: Allocator) Allocator.Error!Cache {
    var pike: pikevm.Cache = try .init(gpa, &re.nfa);
    errdefer pike.deinit(gpa);
    var forward: ?lazy.Cache = if (re.dfa) |*d| try lazy.Cache.init(gpa, d) else null;
    errdefer if (forward) |*f| f.deinit(gpa);
    var reverse: ?lazy.Cache = if (re.reverse) |*r| try lazy.Cache.init(gpa, &r.dfa) else null;
    errdefer if (reverse) |*r| r.deinit(gpa);
    var back: ?backtrack.Cache = if (re.backtracker) |b| try backtrack.Cache.init(gpa, b) else null;
    errdefer if (back) |*b| b.deinit(gpa);
    var inner: ?lazy.Cache = if (re.inner) |*i| try lazy.Cache.init(gpa, &i.dfa) else null;
    errdefer if (inner) |*i| i.deinit(gpa);
    var look_search: ?oracle.Cache = if (re.look) |*l| try .init(gpa, &l.search, null, l.searchCapacity()) else null;
    errdefer if (look_search) |*l| l.deinit(gpa);
    var look_match: ?oracle.Cache = if (re.look) |*l| try .init(gpa, &l.match, &l.match_nfa, l.matchCapacity()) else null;
    errdefer if (look_match) |*l| l.deinit(gpa);
    var look_bodies: []?pikevm.Cache = &.{};
    if (re.look) |*l| {
        look_bodies = try gpa.alloc(?pikevm.Cache, l.bodies.len);
        @memset(look_bodies, null);
        errdefer {
            for (look_bodies) |*b| if (b.*) |*body| body.deinit(gpa);
            gpa.free(look_bodies);
        }
        for (l.bodies, look_bodies) |b, *out| if (b) |body| {
            out.* = try .init(gpa, &body.nfa);
        };
    }
    return .{ .pike = pike, .lazy = forward, .reverse = reverse, .back = back, .inner = inner, .look_search = look_search, .look_match = look_match, .look_bodies = look_bodies };
}

/// What the PikeVM searches: the input cut at the match's end where the lazy DFA found one, null
/// where it found none, and the input whole where there is no lazy DFA or it quit or gave up.
/// Cut there, the PikeVM's leftmost-first match is the same: no match starts earlier, and the
/// preferred one from its start ends at the cut; assertions still see the whole haystack. The
/// cut starts where the lazy DFA's last search began: past the span's start where an empty
/// match there split a code point.
fn narrowed(re: *const Regex, c: *Cache, input: Input) ?Input {
    const d = if (re.dfa) |*d| d else {
        c.last = .pikevm;
        return input;
    };
    var from: usize = undefined;
    const found = lazy.searchFrom(&re.nfa, d, &c.lazy.?, input, &from, if (re.prefilter) |*p| p else null) catch {
        c.last = .lazy_dfa_fell_back;
        return input;
    };
    c.last = .lazy_dfa;
    const end = found orelse return null;
    var cut = input;
    cut.span = .{ .start = from, .end = end };
    return cut;
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

/// Where the leftmost-first match in `input` is: nowhere, the span itself where the lazy DFAs
/// found both ends, or a span the PikeVM must search for it.
const Located = union(enum) {
    none,
    span: Span,
    search: Input,
};

fn locate(re: *const Regex, c: *Cache, input: Input) Located {
    c.pike.visited = 0;
    if (c.lazy) |*l| l.visited = 0;
    if (c.reverse) |*r| r.visited = 0;
    if (c.back) |*b| b.explored = 0;
    c.last_start = .pikevm;
    if (re.look != null) {
        c.last = .lookaround_pikevm;
        return .{ .search = input };
    }
    if (input.whole) {
        c.last = .whole;
        return .{ .search = input };
    }
    if (re.strategy == .literal) {
        const p = &re.prefilter.?;
        c.last = .literal;
        c.last_start = .prefilter;
        const at = p.find(input.haystack, input.span.start, input.span.end) orelse return .none;
        if (input.anchored and at != input.span.start) return .none;
        return .{ .span = .{ .start = at, .end = at + p.exactLen().? } };
    }
    if (re.strategy == .reverse_suffix and !input.anchored) {
        if (re.reverseSuffix(c, input)) |found| {
            c.last = .reverse_suffix;
            c.last_start = .reverse_dfa;
            return if (found) |span| .{ .span = span } else .none;
        } else |_| {}
    }
    if (re.strategy == .reverse_inner and !input.anchored) {
        if (re.reverseInner(c, input)) |found| {
            c.last = .reverse_inner;
            c.last_start = .reverse_dfa;
            return if (found) |span| .{ .span = span } else .none;
        } else |_| {}
    }
    if (re.strategy == .reverse_anchored) {
        const r = &re.reverse.?;
        if (strategy_mod.reverseAnchored(&r.nfa, &r.dfa, &c.reverse.?, input)) |found| {
            c.last = .reverse_anchored;
            c.last_start = .reverse_dfa;
            return if (found) |span| .{ .span = span } else .none;
        } else |_| {}
    }
    const cut = re.narrowed(c, input) orelse return .none;
    if (c.last == .lazy_dfa) if (re.reverse) |*r| {
        // The match the lazy DFA found ends at the cut and starts in it: the reverse lazy DFA
        // finds that start, the earliest of any match ending there.
        if (lazy.searchReverse(&r.nfa, &r.dfa, &c.reverse.?, cut)) |start| {
            c.last_start = .reverse_dfa;
            return .{ .span = .{ .start = start orelse aegis.assert.never("a match ending at the cut starts in it"), .end = cut.span.end } };
        } else |_| c.last_start = .reverse_dfa_fell_back;
    };
    return .{ .search = cut };
}

/// `Strategy.reverse_suffix`'s search: occurrence by occurrence, read back from its end; at
/// the first with a match ending there, the leftmost-first match from where the earliest
/// starts (hir/suffix.zig says why it is the leftmost-first match).
fn reverseSuffix(re: *const Regex, c: *Cache, input: Input) (lazy.LimitedError)!?Span {
    const s = &re.suffix.?;
    const r = &re.reverse.?;
    var from = input.span.start;
    var min_start = input.span.start;
    while (true) {
        const at = s.prefilter.find(input.haystack, from, input.span.end) orelse return null;
        const end = at + s.len;
        var back = input;
        back.span = .{ .start = input.span.start, .end = end };
        if (try lazy.searchReverseLimited(&r.nfa, &r.dfa, &c.reverse.?, back, min_start)) |start| {
            var ahead = input;
            ahead.span = .{ .start = start, .end = input.span.end };
            ahead.anchored = true;
            const last = try lazy.search(&re.nfa, &re.dfa.?, &c.lazy.?, ahead);
            return .{ .start = start, .end = last orelse aegis.assert.never("a match read back from the suffix is found forward") };
        }
        from = at + 1;
        min_start = end;
    }
}

/// `Strategy.reverse_inner`'s search: occurrence by occurrence, read back with P's reverse
/// automaton to where P's earliest match ending there starts, and search forward from there;
/// the first confirmed is the leftmost-first match (hir/inner.zig says why). No byte is read
/// back twice (each reverse scan stops at the occurrence before) nor forward twice (an
/// occurrence before where the last forward scan stopped is `error.Quadratic`). The loop's
/// structure, with its two limits, follows regex-automata 0.4.18's meta/strategy.rs
/// `ReverseInner::try_search_full` (MIT OR Apache-2.0; LICENSES/regex-MIT.txt).
fn reverseInner(re: *const Regex, c: *Cache, input: Input) lazy.LimitedError!?Span {
    const i = &re.inner.?;
    var from = input.span.start;
    var back_limit = input.span.start;
    var ahead_limit = input.span.start;
    while (true) {
        const at = i.prefilter.find(input.haystack, from, input.span.end) orelse return null;
        if (at < ahead_limit) return error.Quadratic;
        var back = input;
        back.span = .{ .start = input.span.start, .end = at };
        if (try lazy.searchReverseLimited(&i.nfa, &i.dfa, &c.inner.?, back, back_limit)) |start| {
            var ahead = input;
            ahead.span = .{ .start = start, .end = input.span.end };
            ahead.anchored = true;
            if (try lazy.search(&re.nfa, &re.dfa.?, &c.lazy.?, ahead)) |end| return .{ .start = start, .end = end };
            ahead_limit = c.lazy.?.stopped;
        }
        from = at + 1;
        back_limit = at;
    }
}

/// Why a search is refused: `error.HaystackTooLong`, only where the compiled pattern holds a
/// lookaround it stores rows for in that kind of search and the haystack passes `Limits.oracle`
/// (`longestHaystack` says the limit up front), before a byte is read. Never otherwise.
pub const SearchError = error{HaystackTooLong};

/// The kinds of search, which may store different rows.
pub const Search = enum { is_match, find, captures, find_all };


/// Whether some match is in `haystack`. `error.HaystackTooLong` only as `SearchError` says,
/// never otherwise.
pub fn isMatch(re: *const Regex, c: *Cache, haystack: []const u8) SearchError!bool {
    if (re.look) |*l| {
        c.last = .lookaround_scan;
        return oracle.isMatch(&l.match, &c.look_match.?, &l.match_nfa, l.match_scan, haystack, re.nfa.utf8 and re.nfa.empty_ok);
    }
    var input: Input = .of(haystack);
    if (re.strategy == .reverse_anchored or re.strategy == .literal or re.strategy == .reverse_suffix or re.strategy == .reverse_inner) return re.findSpan(c, input) != null;
    input.earliest = true;
    c.pike.visited = 0;
    const cut = re.narrowed(c, input) orelse return false;
    if (c.last == .lazy_dfa) return true;
    return pikevm.search(&re.nfa, &c.pike, cut, &.{}) != null;
}

/// The leftmost-first match. `error.HaystackTooLong` only as `SearchError` says, never
/// otherwise.
pub fn find(re: *const Regex, c: *Cache, input: Input) SearchError!?Span {
    try re.rows(c, input.haystack);
    return re.findSpan(c, input);
}

/// The groups inside positive lookarounds (spectra.md §3.1, phase 3; PLDI 2024 §4.3.3): for each
/// that the match took, from the last position it took it at (its slot), one anchored run of its
/// body, read its way, whose preferred match is ECMA-262's first success, its groups copied in.
/// Only that last taking can define them: each earlier one lay in an earlier iteration of an
/// enclosing quantifier, whose next iteration cleared them (Capture Reset). Lookarounds come in
/// preorder, so an outer one's run sets the slot of each inner one it took before that one is
/// reached; each runs at most once, so the work is O(|r|·n).
fn rebuild(re: *const Regex, c: *Cache, haystack: []const u8, slots: []?usize) void {
    const l = &re.look.?;
    for (l.bodies, c.look_bodies) |maybe, *cache_slot| {
        const body = maybe orelse continue;
        const at = slots[body.slot] orelse continue;
        const bc = &cache_slot.*.?;
        bc.rows = c.pike.rows;
        const scratch = bc.slots;
        @memset(scratch, null);
        const ended = switch (body.scan) {
            .forward => pikevm.search(&body.nfa, bc, .{ .haystack = haystack, .span = .{ .start = at, .end = haystack.len }, .anchored = true }, scratch),
            .backward => pikevm.searchBackward(&body.nfa, bc, .{ .haystack = haystack, .span = .{ .start = 0, .end = at } }, scratch),
        };
        aegis.assert.invariant(ended != null, "a lookaround the match took holds where it took it");
        const lo = body.groups[0] * 2;
        const hi = body.groups[1] * 2 + 2;
        @memcpy(slots[lo..hi], scratch[lo..hi]);
    }
}

/// Lookaround's stored rows over `haystack`, before a search of a pattern with lookaround reads
/// a byte; nothing to do for any other.
fn rows(re: *const Regex, c: *Cache, haystack: []const u8) SearchError!void {
    const l = if (re.look) |*l| l else return;
    try oracle.fill(&l.search, &c.look_search.?, haystack);
    c.pike.rows = .{ .plan = &l.search, .cache = &c.look_search.? };
}

fn findSpan(re: *const Regex, c: *Cache, input: Input) ?Span {
    var slots: [2]?usize = undefined;
    const cut = switch (re.locate(c, input)) {
        .none => return null,
        .span => |span| return span,
        .search => |cut| cut,
    };
    _ = re.slotted(c, cut, &slots) orelse return null;
    return .{ .start = slots[0].?, .end = slots[1].? };
}

/// The leftmost-first match in `input` with `slots` written, as the PikeVM's `search`: by the
/// bounded backtracker where the span fits its bits and its stack holds, else the PikeVM.
fn slotted(re: *const Regex, c: *Cache, input: Input, slots: []?usize) ?usize {
    c.last_slots = .pikevm;
    // The backtracker takes the first match it reaches; a whole search wants the first that ends
    // at the span's end.
    if (re.backtracker) |b| if (!input.whole and input.span.len() <= b.longest().?) {
        if (backtrack.search(&re.nfa, &c.back.?, input, slots)) |end| {
            c.last_slots = .backtrack;
            return end;
        } else |_| c.last_slots = .backtrack_fell_back;
    };
    return pikevm.search(&re.nfa, &c.pike, input, slots);
}

/// The leftmost-first match with each group's span in `out`, null where a group took no part.
/// `out.len == captureCount()` is the caller's contract. Where the lazy DFAs found the match,
/// the one-pass DFA, the backtracker or the PikeVM searches it alone, anchored at its start: the
/// preferred match from there ends where they said, so its captures are the leftmost-first
/// match's. `error.HaystackTooLong` only as `SearchError` says, never otherwise.
pub fn captures(re: *const Regex, c: *Cache, input: Input, out: []?Span) SearchError!bool {
    try re.rows(c, input.haystack);
    return re.capturesOf(c, input, out);
}

fn capturesOf(re: *const Regex, c: *Cache, input: Input, out: []?Span) bool {
    aegis.assert.invariant(out.len == re.nfa.groups, "a capture slice holds one span per group");
    const slots = c.pike.slots;
    const located = re.locate(c, input);
    const cut = switch (located) {
        .none => return false,
        .span => |span| blk: {
            var only = input;
            only.span = span;
            only.anchored = true;
            break :blk only;
        },
        .search => |cut| cut,
    };
    const end = (if (located == .span) if (re.onepass) |*d| blk: {
        c.last_slots = .onepass;
        break :blk onepass_mod.search(d, cut, slots);
    } else re.slotted(c, cut, slots) else re.slotted(c, cut, slots)) orelse {
        aegis.assert.invariant(located != .span, "the match the lazy DFAs found is found again");
        return false;
    };
    if (located == .span) aegis.assert.invariant(end == located.span.end and slots[0].? == located.span.start, "the match found again is the one the lazy DFAs found");
    if (re.look != null) re.rebuild(c, input.haystack, slots);
    for (out, 0..) |*span, g| {
        span.* = if (slots[2 * g]) |start| .{ .start = start, .end = slots[2 * g + 1].? } else null;
    }
    return true;
}

/// Every match in turn, leftmost first and apart; an empty match right after the one before is
/// passed over, so the search always moves on.
///
/// Each search is linear, and each starts where the last match ended, so the iteration is linear
/// where each search stops near its match: over many matches and near misses alike. It is not
/// where a preferred branch outlives the matches it does not take: in `\w+X|\w` over a run of
/// word bytes with no X, each match is one byte but `\w+X` keeps each search reading to the end
/// of the run, so the iteration is quadratic in the run (counted in the tests: twice the run,
/// four times the work). Leftmost-first matching is like this in every engine, regex's among
/// them; a caller iterating over untrusted haystacks bounds them by span.
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
    /// Lookaround's rows are built once for the haystack, before the first match.
    rows: bool = false,

    fn prepare(m: *Matches) SearchError!void {
        if (m.rows) return;
        try m.re.rows(m.cache, m.input.haystack);
        m.rows = true;
    }

    /// The next match. `error.HaystackTooLong` only as `SearchError` says, never otherwise.
    pub fn next(m: *Matches) SearchError!?Span {
        try m.prepare();
        if (m.input.span.start > m.input.span.end) return null;
        var found = m.re.findSpan(m.cache, m.input) orelse return null;
        if (found.start == found.end and m.last_end == found.end) {
            if (m.input.span.start >= m.input.span.end) return null;
            m.input.span.start += 1;
            found = m.re.findSpan(m.cache, m.input) orelse return null;
        }
        m.input.span.start = found.end;
        m.last_end = found.end;
        return found;
    }

    /// The next match as `next` finds it, with each group's span in `out`.
    /// `error.HaystackTooLong` only as `SearchError` says, never otherwise.
    pub fn nextCaptures(m: *Matches, out: []?Span) SearchError!bool {
        try m.prepare();
        if (m.input.span.start > m.input.span.end) return false;
        if (!m.re.capturesOf(m.cache, m.input, out)) return false;
        if (out[0].?.start == out[0].?.end and m.last_end == out[0].?.end) {
            if (m.input.span.start >= m.input.span.end) return false;
            m.input.span.start += 1;
            if (!m.re.capturesOf(m.cache, m.input, out)) return false;
        }
        m.input.span.start = out[0].?.end;
        m.last_end = out[0].?.end;
        return true;
    }
};
