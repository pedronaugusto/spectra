//! spectra: regular expressions in linear time. See README.md and docs/design.md.
pub const Syntax = @import("Syntax.zig");
pub const Limits = @import("Limits.zig");
pub const syntax = struct {
    pub const Ast = @import("syntax/Ast.zig");
    pub const parse = @import("syntax/parse.zig").parse;
    pub const Diagnostic = @import("syntax/parse.zig").Diagnostic;
    pub const Reason = @import("syntax/parse.zig").Reason;
    pub const Error = @import("syntax/parse.zig").Error;
};

test {
    _ = syntax;
}
