//! Every test of spectra, run by `bay dev test`.
test {
    _ = @import("spectra.zig");
    _ = @import("syntax/parse_test.zig");
    _ = @import("syntax/ecma_test.zig");
    _ = @import("hir/ranges_test.zig");
    _ = @import("hir/translate_test.zig");
    _ = @import("hir/literals_test.zig");
    _ = @import("nfa/compile_test.zig");
    _ = @import("regex_test.zig");
    _ = @import("regex_suite_test.zig");
    _ = @import("ecma_verdicts_test.zig");
    _ = @import("testing/ecma.zig");
}
