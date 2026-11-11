//! Teddy's scan on AVX2's VPSHUFB, two 16-byte lanes at once. Built with AVX2; entered where
//! the CPU has it.
const teddy = @import("kernels_teddy");

const V = @Vector(32, u8);

inline fn shuffle(table: V, index: V) V {
    return asm ("vpshufb %[index], %[table], %[r]"
        : [r] "=x" (-> V),
        : [table] "x" (table),
          [index] "x" (index),
    );
}

pub fn find(t: *const teddy.Teddy, haystack: []const u8, start: usize) ?usize {
    return teddy.find(32, shuffle, t, haystack, start);
}
