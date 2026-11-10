//! spectra: regular expressions in linear time. See README.md and docs/design.md.
pub const Syntax = @import("Syntax.zig");
pub const Limits = @import("Limits.zig");
/// A compiled pattern and its searches.
pub const Regex = @import("Regex.zig");
pub const syntax = struct {
    pub const Ast = @import("syntax/Ast.zig");
    pub const parse = @import("syntax/parse.zig").parse;
    pub const Diagnostic = @import("syntax/parse.zig").Diagnostic;
    pub const Reason = @import("syntax/parse.zig").Reason;
    pub const Error = @import("syntax/parse.zig").Error;
};
/// ECMA-262's patterns apart from what spectra runs.
pub const ecmascript = struct {
    pub const validate = @import("syntax/ecma.zig").validate;
};

test {
    _ = syntax;
    _ = ecmascript;
    _ = Regex;
}
