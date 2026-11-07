//! Every test of spectra, run by `bay dev test`.
test {
    _ = @import("spectra.zig");
    _ = @import("syntax/parse_test.zig");
}
