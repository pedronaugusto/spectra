//! A set of small integers with constant-time insert, membership and clear, kept in insertion
//! order (Briggs and Torczon's): the engines' sets of threads, where order is preference.
const SparseSet = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A thread: an automaton state, with empty checks with its bit, as one index.
pub const Key = u32;

/// The bytes one entry of capacity costs.
pub const bytesPer = @sizeOf(Key) + @sizeOf(u32);

dense: []Key,
sparse: []u32,
len: u32 = 0,

pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!SparseSet {
    const dense = try gpa.alloc(Key, capacity);
    errdefer gpa.free(dense);
    const sparse = try gpa.alloc(u32, capacity);
    @memset(sparse, 0);
    return .{ .dense = dense, .sparse = sparse };
}

pub fn deinit(s: *SparseSet, gpa: Allocator) void {
    gpa.free(s.dense);
    gpa.free(s.sparse);
}

/// Adds `key`, and whether it was not there.
pub fn insert(s: *SparseSet, key: Key) bool {
    const i = s.sparse[key];
    if (i < s.len and s.dense[i] == key) return false;
    s.dense[s.len] = key;
    s.sparse[key] = s.len;
    s.len += 1;
    return true;
}

/// Whether `key` is in the set.
pub fn contains(s: *const SparseSet, key: Key) bool {
    const i = s.sparse[key];
    return i < s.len and s.dense[i] == key;
}

pub fn items(s: *const SparseSet) []const Key {
    return s.dense[0..s.len];
}
