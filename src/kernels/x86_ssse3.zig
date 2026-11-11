//! Teddy's scan on SSSE3's PSHUFB. Built with SSSE3; entered where the CPU has it.
const teddy = @import("kernels_teddy");

const V = @Vector(16, u8);

inline fn shuffle(table: V, index: V) V {
    return asm ("pshufb %[index], %[r]"
        : [r] "=x" (-> V),
        : [table] "0" (table),
          [index] "x" (index),
    );
}

pub fn find(t: *const teddy.Teddy, haystack: []const u8, start: usize) ?usize {
    return teddy.find(16, shuffle, t, haystack, start);
}
