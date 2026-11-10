//! An automaton written out state by state, as the compiler's tests pin shapes: each state's
//! number, `>` for the anchored start and `^` for the unanchored one, and where it goes.
const std = @import("std");
const Nfa = @import("../nfa/Nfa.zig");

pub fn dump(a: std.mem.Allocator, nfa: *const Nfa) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (nfa.states, 0..) |s, i| {
        const id: Nfa.StateId = @fromBackingInt(@as(u32, @intCast(i)));
        try w.print("{d}{s}{s}: ", .{ i, if (id == nfa.start_anchored) ">" else "", if (id == nfa.start_unanchored) "^" else "" });
        switch (s) {
            .byte_range => |t| try writeTransition(w, t),
            .sparse => |slice| {
                try w.writeAll("sparse(");
                for (nfa.transitionsOf(slice), 0..) |t, k| {
                    if (k > 0) try w.writeAll(", ");
                    try writeTransition(w, t);
                }
                try w.writeAll(")");
            },
            .look => |l| try w.print("look({t}) => {d}", .{ l.look, l.next.raw() }),
            .binary => |b| try w.print("alt({d}, {d})", .{ b.first.raw(), b.second.raw() }),
            .alternation => |slice| {
                try w.writeAll("alt(");
                for (nfa.alternativesOf(slice), 0..) |alt, k| try w.print("{s}{d}", .{ if (k == 0) "" else ", ", alt.raw() });
                try w.writeAll(")");
            },
            .capture => |cap| try w.print("slot({d}) => {d}", .{ cap.slot, cap.next.raw() }),
            .clear => |cl| try w.print("clear({d}..{d}) => {d}", .{ cl.first, cl.end, cl.next.raw() }),
            .fail => try w.writeAll("fail"),
            .match => try w.writeAll("match"),
        }
        try w.writeAll("\n");
    }
    return out.written();
}

fn writeTransition(w: *std.Io.Writer, t: Nfa.Transition) !void {
    if (t.lo == t.hi) try w.print("{x:0>2} => {d}", .{ t.lo, t.next.raw() }) else try w.print("{x:0>2}-{x:0>2} => {d}", .{ t.lo, t.hi, t.next.raw() });
}
