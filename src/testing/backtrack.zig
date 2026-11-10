//! A bounded backtracker over the automaton, regex-automata's in its simplest form: the
//! alternatives in order, each (state, position) explored once, so the first match it reaches
//! is the leftmost-first one, with its captures. Tests only: it allocates a bit per state and
//! position. Every engine is checked against it on random patterns and haystacks.
const std = @import("std");
const Nfa = @import("../nfa/Nfa.zig");
const look = @import("../nfa/look.zig");

pub const Span = struct { start: usize, end: usize };

const Job = union(enum) {
    explore: struct { id: Nfa.StateId, at: usize },
    restore: struct { slot: u32, value: ?usize },
};

pub fn step(nfa: *const Nfa, s: Nfa.State, byte: u8) ?Nfa.StateId {
    switch (s) {
        .byte_range => |t| return if (t.contains(byte)) t.next else null,
        .sparse => |slice| {
            for (nfa.transitionsOf(slice)) |t| if (t.contains(byte)) return t.next;
            return null;
        },
        else => return null,
    }
}

fn at(gpa: std.mem.Allocator, nfa: *const Nfa, haystack: []const u8, span: Span, start: usize, slots: []?usize) !?usize {
    const width = span.end - start + 1;
    var visited = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nfa.states.len * width);
    defer visited.deinit(gpa);
    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(gpa);
    @memset(slots, null);
    try jobs.append(gpa, .{ .explore = .{ .id = nfa.start_anchored, .at = start } });
    while (jobs.pop()) |job| switch (job) {
        .restore => |back| slots[back.slot] = back.value,
        .explore => |e| {
            var id = e.id;
            var pos = e.at;
            while (true) {
                const bit = id.raw() * width + (pos - start);
                if (visited.isSet(bit)) break;
                visited.set(bit);
                switch (nfa.state(id)) {
                    .byte_range, .sparse => {
                        if (pos == span.end) break;
                        id = step(nfa, nfa.state(id), haystack[pos]) orelse break;
                        pos += 1;
                    },
                    .look => |l| {
                        if (!look.holds(l.look, haystack, pos)) break;
                        id = l.next;
                    },
                    .binary => |b| {
                        try jobs.append(gpa, .{ .explore = .{ .id = b.second, .at = pos } });
                        id = b.first;
                    },
                    .alternation => |slice| {
                        const alts = nfa.alternativesOf(slice);
                        var k = alts.len;
                        while (k > 1) {
                            k -= 1;
                            try jobs.append(gpa, .{ .explore = .{ .id = alts[k], .at = pos } });
                        }
                        id = alts[0];
                    },
                    .capture => |cap| {
                        if (cap.slot < slots.len) {
                            try jobs.append(gpa, .{ .restore = .{ .slot = cap.slot, .value = slots[cap.slot] } });
                            slots[cap.slot] = pos;
                        }
                        id = cap.next;
                    },
                    .clear => |cl| {
                        var slot = cl.first;
                        while (slot < @min(cl.end, slots.len)) : (slot += 1) {
                            if (slots[slot] == null) continue;
                            try jobs.append(gpa, .{ .restore = .{ .slot = slot, .value = slots[slot] } });
                            slots[slot] = null;
                        }
                        id = cl.next;
                    },
                    .fail => break,
                    .match => return pos,
                }
            }
        },
    };
    return null;
}

fn once(gpa: std.mem.Allocator, nfa: *const Nfa, haystack: []const u8, span: Span, anchored: bool, slots: []?usize) !?usize {
    if (span.start > span.end) return null;
    var start = span.start;
    while (start <= span.end) : (start += 1) {
        if (try at(gpa, nfa, haystack, span, start, slots)) |end| return end;
        if (anchored or nfa.start_unanchored == nfa.start_anchored) return null;
    }
    return null;
}

/// Where the leftmost-first match in `span` ends, with its slots written; in UTF-8 an empty
/// match that splits a code point is passed over, as every engine does.
pub fn search(gpa: std.mem.Allocator, nfa: *const Nfa, haystack: []const u8, span: Span, anchored: bool, slots: []?usize) !?usize {
    var end = try once(gpa, nfa, haystack, span, anchored, slots) orelse return null;
    if (!(nfa.utf8 and nfa.empty_ok)) return end;
    var again = span;
    while (!(end == haystack.len or (end < haystack.len and (haystack[end] < 0x80 or haystack[end] >= 0xc0)))) {
        if (anchored) return null;
        again.start += 1;
        end = try once(gpa, nfa, haystack, again, anchored, slots) orelse return null;
    }
    return end;
}
