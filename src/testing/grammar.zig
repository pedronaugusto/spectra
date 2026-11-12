//! Random patterns from a small grammar that reaches what the engines find hardest: groups,
//! captured or not, that can match empty, nested and quantified, and alternatives with an empty
//! branch. Every pattern is valid in both dialects.
const std = @import("std");
const shakedown = @import("shakedown");

/// A pattern from a small grammar that reaches what the empty check is about: groups, captured
/// or not, that can match empty, nested and quantified, alternatives with an empty branch.
pub fn write(s: anytype, out: *std.ArrayList(u8), a: std.mem.Allocator, depth: u32) !void {
    const leaves = [_][]const u8{ "a", "b", "", "a?", "b*", "\\b", "^", "$", ".", "[ab]", "\\w" };
    const quantifiers = [_][]const u8{ "", "*", "+", "?", "{0,2}", "{1,3}", "{2}", "*?", "+?", "??", "{0,}" };
    switch (if (depth == 0) 0 else shakedown.gen.intRange(s, usize, 0, 3)) {
        0 => try out.appendSlice(a, leaves[shakedown.gen.intRange(s, usize, 0, leaves.len - 1)]),
        1 => {
            try out.appendSlice(a, if (shakedown.gen.boolean(s)) "(" else "(?:");
            try write(s, out, a, depth - 1);
            try out.appendSlice(a, ")");
            try out.appendSlice(a, quantifiers[shakedown.gen.intRange(s, usize, 0, quantifiers.len - 1)]);
        },
        2 => {
            try write(s, out, a, depth - 1);
            try out.appendSlice(a, "|");
            try write(s, out, a, depth - 1);
        },
        else => {
            try write(s, out, a, depth - 1);
            try write(s, out, a, depth - 1);
        },
    }
}


/// A pattern of the ECMAScript dialect from the grammar above with lookarounds among its atoms:
/// lookahead and lookbehind, positive and negative, nested, with groups inside them and around
/// them, quantified or not.
pub fn writeLookaround(s: anytype, out: *std.ArrayList(u8), a: std.mem.Allocator, depth: u32) !void {
    const leaves = [_][]const u8{ "a", "b", "", "a?", "b*", "\\b", "^", "$", ".", "[ab]", " " };
    const quantifiers = [_][]const u8{ "", "*", "+", "?", "{0,2}", "*?", "+?" };
    const opens = [_][]const u8{ "(?=", "(?!", "(?<=", "(?<!" };
    switch (if (depth == 0) 0 else shakedown.gen.intRange(s, usize, 0, 4)) {
        0 => try out.appendSlice(a, leaves[shakedown.gen.intRange(s, usize, 0, leaves.len - 1)]),
        1 => {
            try out.appendSlice(a, if (shakedown.gen.boolean(s)) "(" else "(?:");
            try writeLookaround(s, out, a, depth - 1);
            try out.appendSlice(a, ")");
            try out.appendSlice(a, quantifiers[shakedown.gen.intRange(s, usize, 0, quantifiers.len - 1)]);
        },
        2 => {
            try writeLookaround(s, out, a, depth - 1);
            try out.appendSlice(a, "|");
            try writeLookaround(s, out, a, depth - 1);
        },
        3 => {
            try out.appendSlice(a, opens[shakedown.gen.intRange(s, usize, 0, opens.len - 1)]);
            try writeLookaround(s, out, a, depth - 1);
            try out.appendSlice(a, ")");
        },
        else => {
            try writeLookaround(s, out, a, depth - 1);
            try writeLookaround(s, out, a, depth - 1);
        },
    }
}
