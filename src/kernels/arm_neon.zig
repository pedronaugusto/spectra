//! Teddy's scan on NEON's TBL, AArch64's baseline.
const teddy = @import("kernels_teddy");

const V = @Vector(16, u8);

inline fn shuffle(table: V, index: V) V {
    return asm ("tbl %[r].16b, {%[table].16b}, %[index].16b"
        : [r] "=w" (-> V),
        : [table] "w" (table),
          [index] "w" (index),
    );
}

pub fn find(t: *const teddy.Teddy, haystack: []const u8, start: usize) ?usize {
    return teddy.find(16, shuffle, t, haystack, start);
}
