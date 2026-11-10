//! Every test of spectra, run by `bay dev test`.
test {
    _ = @import("spectra.zig");
    _ = @import("syntax/parse_test.zig");
    _ = @import("syntax/ecma_test.zig");
    _ = @import("hir/ranges_test.zig");
    _ = @import("hir/translate_test.zig");
    _ = @import("hir/literals_test.zig");
}
