//! An allocator that takes each allocation's bytes from what is left before it allocates, and
//! refuses one past it as out of memory, marking `over`. Nothing freed is given back: the
//! charge bounds the work as well as what is held. Translation charges its sets to
//! `Limits.nfa` through one, and the compiler its automaton.
//!
//! A growth is charged what it adds, whether the child grows the memory in place or the caller
//! moves it: a growth the child refuses costs nothing then, and the allocation the caller makes
//! instead, of the length the growth asked for, is charged only what it adds. So the charge
//! follows the caller's own sequence of sizes, never whether the child had room, which depends
//! on what else it holds and on the machine's page size.
const Charged = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

child: Allocator,
left: usize,
over: bool = false,
/// A growth the child refused: the length it was, and the length it asked for, which the
/// caller's next allocation of that length moves to.
refused: ?struct { from: usize, to: usize } = null,

pub fn allocator(c: *Charged) Allocator {
    return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn take(c: *Charged, bytes: usize) bool {
    if (bytes > c.left) {
        c.over = true;
        return false;
    }
    c.left -= bytes;
    return true;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    // The move of a refused growth costs what the growth adds.
    const moved = if (c.refused) |r| r.to == len else false;
    const bytes = if (moved) len - c.refused.?.from else len;
    c.refused = null;
    if (!c.take(bytes)) return null;
    return c.child.rawAlloc(len, alignment, ret);
}

/// Charges a growth the child made, or remembers one it refused.
fn grown(c: *Charged, memory: []u8, new_len: usize, granted: bool) void {
    c.refused = null;
    if (new_len <= memory.len) return;
    if (granted) {
        c.left -= new_len - memory.len;
    } else c.refused = .{ .from = memory.len, .to = new_len };
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and new_len - memory.len > c.left) {
        c.refused = null;
        c.over = true;
        return false;
    }
    const granted = c.child.rawResize(memory, alignment, new_len, ret);
    c.grown(memory, new_len, granted);
    return granted;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and new_len - memory.len > c.left) {
        c.refused = null;
        c.over = true;
        return null;
    }
    const moved = c.child.rawRemap(memory, alignment, new_len, ret);
    c.grown(memory, new_len, moved != null);
    return moved;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    c.child.rawFree(memory, alignment, ret);
}

test "a growth costs the same whether the child had room for it or not" {
    var charges: [2]usize = undefined;
    for (&charges, [_]bool{ false, true }) |*charge, crowded| {
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        var c: Charged = .{ .child = fixed.allocator(), .left = buffer.len };
        const a = c.allocator();
        var list: std.ArrayList(u32) = .empty;
        try list.append(a, 0);
        // Something held after the list: its next growth cannot be in place, so it moves.
        if (crowded) _ = try fixed.allocator().alloc(u8, 1);
        for (1..100) |i| try list.append(a, @intCast(i));
        charge.* = buffer.len - c.left;
    }
    try std.testing.expectEqual(charges[0], charges[1]);
}
