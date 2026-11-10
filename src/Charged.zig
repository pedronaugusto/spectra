//! An allocator that takes each allocation's bytes from what is left before it allocates, and
//! refuses one past it as out of memory, marking `over`. Nothing freed is given back: the
//! charge bounds the work as well as what is held. Translation charges its sets to
//! `Limits.nfa` through one, and the compiler its automaton.
const Charged = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

child: Allocator,
left: usize,
over: bool = false,

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
    if (!c.take(len)) return null;
    return c.child.rawAlloc(len, alignment, ret);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and !c.take(new_len - memory.len)) return false;
    return c.child.rawResize(memory, alignment, new_len, ret);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    if (new_len > memory.len and !c.take(new_len - memory.len)) return null;
    return c.child.rawRemap(memory, alignment, new_len, ret);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
    const c: *Charged = @ptrCast(@alignCast(ctx));
    c.child.rawFree(memory, alignment, ret);
}
