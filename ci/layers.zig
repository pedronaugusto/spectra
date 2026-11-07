//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "vocabulary", .patterns = &.{ "src/Syntax.zig", "src/Limits.zig" } },
    .{ .name = "syntax", .patterns = &.{ "src/syntax/Ast.zig", "src/syntax/diagnostic.zig", "src/syntax/parse.zig", "src/syntax/ecma.zig" } },
    .{ .name = "public", .patterns = &.{"src/spectra.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{
        .name = "named dependencies",
        .unresolved_only = true,
        .except_targets = &.{ "std", "aegis", "xenoglyph", "shakedown", "builtin" },
    },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

/// A family package is reached through its module name, never by a path into it.
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// Every production source, so a file added without a layer is refused.
pub const required = [_][]const u8{
    "src/Syntax.zig",
    "src/Limits.zig",
    "src/syntax/Ast.zig",
    "src/syntax/diagnostic.zig",
    "src/syntax/parse.zig",
    "src/syntax/ecma.zig",
    "src/spectra.zig",
};
