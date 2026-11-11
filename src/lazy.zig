//! The lazy DFA, regex-automata's hybrid: the NFA determinized on demand. A DFA state is what
//! the PikeVM's threads at a position grow from, its seeds: the automaton's start, or the states
//! the byte before led to, in preference order. It is built the first time a search needs it
//! into the caller's `Cache` and read from there after, one transition per byte. It finds where
//! the leftmost-first match ends; where it starts and its captures are the PikeVM's, run over
//! the span cut at that end.
//!
//! Assertions: a state knows what the byte before it was (its `Context`) and a transition knows
//! the byte after, so the transition on a byte runs the seeds' closure with every look decided,
//! the very closure the PikeVM runs at that position, and steps its threads in order: the first
//! at the match makes the next state a match and drops the threads after it (leftmost-first).
//! A match is therefore seen one byte late, and a search takes one transition past its span (on
//! the byte after it, or the haystack's end) to see a match that ends there. A look that needs
//! more than one byte of context (Unicode's word characters, ECMA-262's U+2028 and U+2029) makes
//! every byte past 0x7f a quit byte: the search stops with `error.Quit`, as regex-automata's does.
//!
//! The closure is never cut in two: one stopped at a look and resumed from it at the transition
//! would not see what the threads before the look entered, and so would enter again a state the
//! PikeVM passes over (`(?:\b|a)*` on "a": the loop back to the alternation outranking the
//! match). With ECMAScript's empty checks a closure's threads are states with their bit
//! (pikevm.zig; Barrière and Pit-Claudel, PLDI 2024 §4.1); a seed has just read a byte, or is
//! the start, and its bit is set either way, so a seed is its state alone.
//!
//! The cache has a fixed capacity, allocated once, and is cleared when full; the state being
//! left is kept across the clear. A pattern whose DFA outgrows the capacity would clear on
//! almost every byte, so after three clears a search that read fewer than ten bytes per state
//! built since the last clear gives up (`error.GaveUp`), RE2's and regex-automata's rule. On a
//! quit or a give-up the caller runs the PikeVM over the whole span from its start: the work
//! is the lazy DFA's (a byte builds at most one transition, which costs one closure over the
//! automaton, as the PikeVM's step does) and then the PikeVM's, linear both.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const Nfa = @import("nfa/Nfa.zig");
const Look = Nfa.Look;
const LookSet = Nfa.LookSet;
const look_zig = @import("nfa/look.zig");
const pikevm = @import("pikevm.zig");
const SparseSet = @import("SparseSet.zig");
const Key = SparseSet.Key;

pub const Input = pikevm.Input;

pub const Error = error{
    /// A byte past 0x7f where an assertion needs more than one byte of context.
    Quit,
    /// The cache cleared too often for the bytes read.
    GaveUp,
};

/// The byte before a position, as the automaton's assertions tell bytes apart: none (the
/// haystack's start), a line feed, a carriage return, a word byte, or another.
pub const Context = enum(u3) { start, lf, cr, word, other };

/// The byte after a position: the same, or the haystack's end.
const Ahead = enum(u3) { end, lf, cr, word, other };

const contexts = @typeInfo(Context).@"enum".field_names.len;

/// Clears before a search may give up, and the bytes per state built it must read after them.
const min_clears = 3;
const min_bytes_per_state = 10;

/// The fewest states a cache holds: the dead state, the state left across a clear and the one
/// built, and a start.
const min_states = 4;

const unknown: u32 = std.math.maxInt(u32);
/// The state with no seeds and no match: every transition from it comes back to it.
const dead: u32 = 0;

/// Looks decided by more than one byte of context.
const wide: LookSet = .initMany(&.{ .start_line_ecma, .end_line_ecma, .word_unicode, .not_word_unicode, .word_ecma_folded, .not_word_ecma_folded, .word_start_unicode, .word_end_unicode, .word_start_half_unicode, .word_end_half_unicode });
const words: LookSet = .initMany(&.{ .word_ascii, .not_word_ascii, .word_unicode, .not_word_unicode, .word_ecma_folded, .not_word_ecma_folded, .word_start_ascii, .word_end_ascii, .word_start_unicode, .word_end_unicode, .word_start_half_ascii, .word_end_half_ascii, .word_start_half_unicode, .word_end_half_unicode });
const lines: LookSet = .initMany(&.{ .start_line_lf, .end_line_lf, .start_line_crlf, .end_line_crlf, .start_line_ecma, .end_line_ecma });
const returns: LookSet = .initMany(&.{ .start_line_crlf, .end_line_crlf, .start_line_ecma, .end_line_ecma });

/// What an automaton's lazy DFA is, worked out once at compile: its alphabet, what each byte is
/// to the assertions, and how its cache divides. Immutable; every state lives in a `Cache`.
pub const Dfa = struct {
    /// Each byte's class: bytes that no transition and no assertion tells apart.
    classes: [256]u8,
    /// A row's length: the classes, and the haystack's end.
    stride: u32,
    /// The class of every byte past 0x7f, when an assertion needs more than one byte.
    quit: ?u8,
    /// What each byte is to the assertions, before a position or after it.
    kinds: [256]Context,
    /// What the haystack's start is to them.
    start: Context,
    /// States and key entries a cache holds.
    states: u32,
    keys: u32,
    /// Slots of the cache's table from a state's seeds to its id: a power of two.
    slots: u32,
    /// Threads of the automaton: its states, twice with empty checks.
    threads: u32,
    /// Entries of a closure's stack.
    stack: u32,

    /// The bytes a `Cache` allocates: the store, within `capacity`, and the scratch a state is
    /// built in, which grows with the automaton.
    pub fn bytes(d: *const Dfa) usize {
        const store = @as(usize, d.states) * d.stride * @sizeOf(u32) + @as(usize, d.states) * @sizeOf(Rec) +
            @as(usize, d.keys) * @sizeOf(Key) + @as(usize, d.slots) * @sizeOf(u32);
        const scratch = 2 * @as(usize, d.threads) * SparseSet.bytesPer + @as(usize, d.threads) * @sizeOf(Key) +
            @as(usize, d.stack) * @sizeOf(Explore);
        return store + scratch;
    }
};

/// The lazy DFA of `nfa` with a store of `capacity` bytes, or null when that cannot hold the
/// fewest states a search needs: the pattern then has no lazy DFA (`Regex.engines`).
pub fn build(nfa: *const Nfa, capacity: usize) ?Dfa {
    var d: Dfa = undefined;
    const quit = nfa.looks.intersectWith(wide).count() > 0;
    const word = nfa.looks.intersectWith(words).count() > 0;
    const lf = nfa.looks.intersectWith(lines).count() > 0;
    const cr = nfa.looks.intersectWith(returns).count() > 0;
    var bounds: std.StaticBitSet(257) = .empty;
    for (nfa.states) |s| switch (s) {
        .byte_range => |t| mark(&bounds, t.lo, t.hi, quit),
        .sparse => |slice| for (nfa.transitionsOf(slice)) |t| mark(&bounds, t.lo, t.hi, quit),
        else => {},
    };
    if (lf) mark(&bounds, '\n', '\n', quit);
    if (cr) mark(&bounds, '\r', '\r', quit);
    if (word) for ([_][2]u8{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } }) |r| mark(&bounds, r[0], r[1], quit);
    if (quit) bounds.set(0x80);
    var class: u32 = 0;
    for (0..256) |b| {
        if (b > 0 and bounds.isSet(b)) class += 1;
        d.classes[b] = @intCast(class);
        d.kinds[b] = if (lf and b == '\n') .lf else if (cr and b == '\r') .cr else if (word and look_zig.isWordByte(@intCast(b))) .word else .other;
    }
    d.stride = class + 2;
    d.quit = if (quit) d.classes[0x80] else null;
    // The start is a line's start and no word byte: a line feed, unless `\A` tells them apart.
    d.start = if (nfa.looks.contains(.start_text)) .start else if (lf) .lf else .other;

    const lanes = pikevm.lanes(nfa);
    d.threads = @intCast(nfa.states.len * lanes);
    d.stack = @intCast((nfa.states.len + nfa.alternatives.len) * lanes + 1);
    const half = capacity / 2;
    const per_state = d.stride * @sizeOf(u32) + @sizeOf(Rec) + 4 * @sizeOf(u32);
    const states = half / per_state;
    const keys = half / @sizeOf(Key);
    // The state left across a clear and the one built, each at most every state as a seed.
    if (states < min_states or keys < 2 * nfa.states.len) return null;
    d.states = @intCast(@min(states, std.math.maxInt(u32) / 4));
    d.keys = @intCast(@min(keys, std.math.maxInt(u32)));
    d.slots = std.math.ceilPowerOfTwoAssert(u32, 2 * d.states);
    return d;
}

/// Bytes `lo` to `hi` apart from their neighbours; past 0x7f nothing is told apart when those
/// bytes quit.
fn mark(bounds: *std.StaticBitSet(257), lo: u8, hi: u8, quit: bool) void {
    if (!quit or lo < 0x80) bounds.set(lo);
    if (!quit or hi < 0x80) bounds.set(@as(usize, hi) + 1);
}

/// Whether `look` holds between a byte of kind `before` and one of kind `ahead`. Bytes past
/// 0x7f never reach here where a look reads them, so the Unicode and ECMAScript looks are their
/// ASCII parts.
fn holds(look: Look, before: Context, ahead: Ahead) bool {
    const line_before = before == .start or before == .lf;
    const word_before = before == .word;
    const word_ahead = ahead == .word;
    return switch (look) {
        .start_text => before == .start,
        .end_text => ahead == .end,
        .start_line_lf => line_before,
        .end_line_lf => ahead == .end or ahead == .lf,
        .start_line_crlf => line_before or (before == .cr and ahead != .lf),
        .end_line_crlf => ahead == .end or ahead == .cr or (ahead == .lf and before != .cr),
        .start_line_ecma => line_before or before == .cr,
        .end_line_ecma => ahead == .end or ahead == .lf or ahead == .cr,
        .word_ascii, .word_unicode, .word_ecma_folded => word_before != word_ahead,
        .not_word_ascii, .not_word_unicode, .not_word_ecma_folded => word_before == word_ahead,
        .word_start_ascii, .word_start_unicode => !word_before and word_ahead,
        .word_end_ascii, .word_end_unicode => word_before and !word_ahead,
        .word_start_half_ascii, .word_start_half_unicode => !word_before,
        .word_end_half_ascii, .word_end_half_unicode => !word_ahead,
    };
}

fn aheadOf(kind: Context) Ahead {
    return switch (kind) {
        .start => unreachable,
        .lf => .lf,
        .cr => .cr,
        .word => .word,
        .other => .other,
    };
}

/// A state as the cache keeps it: its seeds (`keys[start..][0..len]`, state ids), the byte before
/// it, and whether a match ended at the position before the byte that led to it.
const Rec = struct {
    start: u32,
    len: u32,
    hash: u32,
    context: Context,
    match: bool,
};

const Explore = struct { id: Nfa.StateId, read: bool };

/// Where every state of one automaton's lazy DFA lives, owned by the caller: a fixed store,
/// allocated once and cleared when full, and the scratch states are built in.
pub const Cache = struct {
    /// Each state's row of transitions by class, `unknown` until built.
    rows: []u32,
    recs: []Rec,
    keys: []Key,
    /// From a state's seeds to its id plus one, by hash; zero is empty.
    table: []u32,
    /// The start state for each context, anchored or not.
    starts: [contexts * 2]u32,
    len: u32 = 0,
    keys_len: u32 = 0,
    /// A transition's closure, its threads keyed as the PikeVM keys them.
    a: SparseSet,
    /// The seeds it steps into, by state id.
    b: SparseSet,
    /// A state's seeds kept across a clear.
    source: []Key,
    stack: []Explore,
    /// The automaton it was made for, by its threads: a cache of another is refused.
    threads: u32,
    /// Clears since the cache was made, and bytes read and states built since the last.
    clears: u32 = 0,
    bytes_since: usize = 0,
    built_since: usize = 0,
    /// The last search's work: bytes read and threads entered building transitions.
    visited: usize = 0,

    /// Allocates what `d.bytes()` counts, which `Limits.cache` has bounded at compile.
    pub fn init(gpa: Allocator, d: *const Dfa) Allocator.Error!Cache {
        const rows = try gpa.alloc(u32, @as(usize, d.states) * d.stride);
        errdefer gpa.free(rows);
        const recs = try gpa.alloc(Rec, d.states);
        errdefer gpa.free(recs);
        const keys = try gpa.alloc(Key, d.keys);
        errdefer gpa.free(keys);
        const table = try gpa.alloc(u32, d.slots);
        errdefer gpa.free(table);
        var a: SparseSet = try .init(gpa, d.threads);
        errdefer a.deinit(gpa);
        var b: SparseSet = try .init(gpa, d.threads);
        errdefer b.deinit(gpa);
        const source = try gpa.alloc(Key, d.threads);
        errdefer gpa.free(source);
        const stack = try gpa.alloc(Explore, d.stack);
        var c: Cache = .{ .rows = rows, .recs = recs, .keys = keys, .table = table, .starts = undefined, .a = a, .b = b, .source = source, .stack = stack, .threads = d.threads };
        c.reset(d);
        return c;
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.rows);
        gpa.free(c.recs);
        gpa.free(c.keys);
        gpa.free(c.table);
        c.a.deinit(gpa);
        c.b.deinit(gpa);
        gpa.free(c.source);
        gpa.free(c.stack);
        c.* = undefined;
    }

    /// Empties the store but for the dead state.
    fn reset(c: *Cache, d: *const Dfa) void {
        c.len = 1;
        c.keys_len = 0;
        @memset(c.table, 0);
        @memset(&c.starts, unknown);
        c.recs[dead] = .{ .start = 0, .len = 0, .hash = 0, .context = .other, .match = false };
        @memset(c.rows[0..d.stride], dead);
    }

    /// The id of the state of these seeds, built if new. A full store is cleared first, and
    /// `from`, the state being left, kept across it under its new id.
    fn intern(c: *Cache, d: *const Dfa, from: ?*u32, context: Context, match: bool, keys: []const Key) Error!u32 {
        const h = hashOf(context, match, keys);
        if (c.find(d, h, context, match, keys)) |id| return id;
        if (c.len == d.states or c.keys_len + keys.len > d.keys) {
            try c.clear(d, from);
            // The state left may be the one built: a loop back to itself.
            if (c.find(d, h, context, match, keys)) |id| return id;
        }
        return c.add(d, h, context, match, keys);
    }

    fn clear(c: *Cache, d: *const Dfa, from: ?*u32) Error!void {
        if (c.clears >= min_clears and c.bytes_since < min_bytes_per_state * c.built_since) return error.GaveUp;
        c.clears += 1;
        c.bytes_since = 0;
        c.built_since = 0;
        const f = from orelse return c.reset(d);
        const r = c.recs[f.*];
        @memcpy(c.source[0..r.len], c.keys[r.start..][0..r.len]);
        c.reset(d);
        f.* = c.add(d, r.hash, r.context, r.match, c.source[0..r.len]);
    }

    fn add(c: *Cache, d: *const Dfa, h: u32, context: Context, match: bool, keys: []const Key) u32 {
        const id = c.len;
        c.len += 1;
        @memcpy(c.keys[c.keys_len..][0..keys.len], keys);
        c.recs[id] = .{ .start = c.keys_len, .len = @intCast(keys.len), .hash = h, .context = context, .match = match };
        c.keys_len += @intCast(keys.len);
        @memset(c.rows[@as(usize, id) * d.stride ..][0..d.stride], unknown);
        const mask = d.slots - 1;
        var slot = h & mask;
        while (c.table[slot] != 0) slot = (slot + 1) & mask;
        c.table[slot] = id + 1;
        c.built_since += 1;
        return id;
    }

    fn find(c: *const Cache, d: *const Dfa, h: u32, context: Context, match: bool, keys: []const Key) ?u32 {
        const mask = d.slots - 1;
        var slot = h & mask;
        while (c.table[slot] != 0) : (slot = (slot + 1) & mask) {
            const id = c.table[slot] - 1;
            const r = c.recs[id];
            if (r.hash == h and r.context == context and r.match == match and std.mem.eql(Key, c.keys[r.start..][0..r.len], keys)) return id;
        }
        return null;
    }
};

fn hashOf(context: Context, match: bool, keys: []const Key) u32 {
    const seed = @as(u64, @intFromEnum(context)) * 2 + @intFromBool(match);
    return @truncate(std.hash.Wyhash.hash(seed, std.mem.sliceAsBytes(keys)));
}

/// Where the leftmost-first match in `input` ends, or with `earliest` where some match ends;
/// in UTF-8, an empty match that would split a code point is passed over, as the PikeVM does.
pub fn search(nfa: *const Nfa, d: *const Dfa, c: *Cache, input: Input) Error!?usize {
    aegis.assert.invariant(c.threads == d.threads and c.rows.len == @as(usize, d.states) * d.stride, "a cache searches the automaton it was made for");
    aegis.assert.invariant(input.span.start <= input.span.end and input.span.end <= input.haystack.len, "a span lies in its haystack");
    c.visited = 0;
    var end = try searchOnce(nfa, d, c, input) orelse return null;
    if (!(nfa.utf8 and nfa.empty_ok)) return end;
    var again = input;
    while (!pikevm.isBoundary(input.haystack, end)) {
        if (input.anchored) return null;
        again.span.start += 1;
        end = try searchOnce(nfa, d, c, again) orelse return null;
    }
    return end;
}

fn searchOnce(nfa: *const Nfa, d: *const Dfa, c: *Cache, input: Input) Error!?usize {
    if (input.span.start > input.span.end) return null;
    const anchored = input.anchored or nfa.start_anchored == nfa.start_unanchored;
    var s = try startState(nfa, d, c, input, anchored);
    var found: ?usize = null;
    var at = input.span.start;
    while (at < input.span.end) : (at += 1) {
        if (s == dead) return found;
        const byte = input.haystack[at];
        const class = d.classes[byte];
        if (d.quit == class) return error.Quit;
        c.visited += 1;
        c.bytes_since += 1;
        const t = c.rows[@as(usize, s) * d.stride + class];
        s = if (t != unknown) t else try next(nfa, d, c, s, byte);
        if (c.recs[s].match) {
            found = at;
            if (input.earliest) return at;
        }
    }
    if (s == dead) return found;
    // The byte after the span, or the haystack's end, decides a match that ends at its end.
    const after: ?u8 = if (input.span.end < input.haystack.len) input.haystack[input.span.end] else null;
    const class: u32 = if (after) |b| d.classes[b] else d.stride - 1;
    if (after) |b| if (d.quit == d.classes[b]) return error.Quit;
    const t = c.rows[@as(usize, s) * d.stride + class];
    s = if (t != unknown) t else try next(nfa, d, c, s, after);
    if (c.recs[s].match) found = input.span.end;
    return found;
}

fn startState(nfa: *const Nfa, d: *const Dfa, c: *Cache, input: Input, anchored: bool) Error!u32 {
    const at = input.span.start;
    const context: Context = if (at == 0) d.start else blk: {
        const b = input.haystack[at - 1];
        if (d.quit != null and b >= 0x80) return error.Quit;
        break :blk d.kinds[b];
    };
    const index = @as(usize, @intFromEnum(context)) * 2 + @intFromBool(anchored);
    if (c.starts[index] != unknown) return c.starts[index];
    const seed: Key = (if (anchored) nfa.start_anchored else nfa.start_unanchored).raw();
    const id = try c.intern(d, null, context, false, &.{seed});
    c.starts[index] = id;
    return id;
}

/// Builds the transition from `from` on `unit` (null: the haystack's end) and returns where it
/// goes: the PikeVM's step at that position. The seeds' closure, every look decided by the byte
/// before and `unit`; then each thread in order reads `unit` and its target is a seed of the next
/// state, once; the first thread at the match makes the next state a match and drops every
/// thread after it (leftmost-first).
fn next(nfa: *const Nfa, d: *const Dfa, c: *Cache, from_id: u32, unit: ?u8) Error!u32 {
    var from = from_id;
    const rec = c.recs[from];
    const decide: Decide = .{ .before = rec.context, .ahead = if (unit) |b| aheadOf(d.kinds[b]) else .end };
    c.a.len = 0;
    // A seed has just read a byte, or is the start: its bit is set.
    for (c.keys[rec.start..][0..rec.len]) |seed| closure(nfa, c, @fromBackingInt(seed), decide);
    c.b.len = 0;
    var match = false;
    for (c.a.items()) |key| {
        const target: ?Nfa.StateId = switch (nfa.state(pikevm.stateOf(nfa, key))) {
            .match => {
                match = true;
                break;
            },
            .byte_range => |t| if (unit) |b| (if (t.contains(b)) t.next else null) else null,
            .sparse => |slice| if (unit) |b| stepSparse(nfa, slice, b) else null,
            else => null,
        };
        // The PikeVM's closure from a target entered before enters nothing.
        if (target) |t| _ = c.b.insert(t.raw());
    }
    const class: u32 = if (unit) |b| d.classes[b] else d.stride - 1;
    const seeds = c.b.items();
    const to = if (seeds.len == 0 and !match) dead else try c.intern(d, &from, if (unit) |b| d.kinds[b] else .other, match, seeds);
    c.rows[@as(usize, from) * d.stride + class] = to;
    return to;
}

fn stepSparse(nfa: *const Nfa, slice: Nfa.Slice, byte: u8) ?Nfa.StateId {
    for (nfa.transitionsOf(slice)) |t| {
        if (byte < t.lo) return null;
        if (byte <= t.hi) return t.next;
    }
    return null;
}

const Decide = struct { before: Context, ahead: Ahead };

/// Adds to `c.a` every thread reachable from `from` by epsilon, in preference order, each look
/// decided and followed where it holds: the PikeVM's closure, without slots.
fn closure(nfa: *const Nfa, c: *Cache, from: Nfa.StateId, decide: Decide) void {
    var depth: usize = 0;
    c.stack[depth] = .{ .id = from, .read = true };
    depth += 1;
    while (depth > 0) {
        depth -= 1;
        var id = c.stack[depth].id;
        var read = c.stack[depth].read;
        while (true) {
            if (!c.a.insert(pikevm.keyOf(nfa, id, read))) break;
            c.visited += 1;
            switch (nfa.state(id)) {
                .byte_range, .sparse, .match, .fail => break,
                .look => |l| {
                    if (!holds(l.look, decide.before, decide.ahead)) break;
                    id = l.next;
                },
                .binary => |b| {
                    push(c, &depth, .{ .id = b.second, .read = read });
                    id = b.first;
                },
                .alternation => |slice| {
                    const alts = nfa.alternativesOf(slice);
                    var k = alts.len;
                    while (k > 1) {
                        k -= 1;
                        push(c, &depth, .{ .id = alts[k], .read = read });
                    }
                    id = alts[0];
                },
                .capture => |cap| id = cap.next,
                .clear => |cl| id = cl.next,
                .loop_begin => |next_id| {
                    read = false;
                    id = next_id;
                },
                // An iteration past the minimum that read nothing fails.
                .loop_end => |next_id| {
                    if (!read) break;
                    id = next_id;
                },
            }
        }
    }
}

fn push(c: *Cache, depth: *usize, e: Explore) void {
    aegis.assert.invariant(depth.* < c.stack.len, "a closure pushes at most once per state and alternative");
    c.stack[depth.*] = e;
    depth.* += 1;
}
