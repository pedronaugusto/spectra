const std = @import("std");

/// What a project that depends on spectra builds: the `spectra` module.
/// The tests, checks and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = spectraModule(b, b, target, optimize);
}

fn spectraModule(b: *std.Build, p: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.addModule("spectra", .{ .root_source_file = p.path("src/spectra.zig"), .target = target, .optimize = optimize });
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("xenoglyph", p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph"));
    return module;
}

/// spectra's development: its tests and checks under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("spectra", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters = if (test_filter) |filter| &.{filter} else &.{};
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize });
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .name = "spectra-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
                .{ .name = "xenoglyph", .module = p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph") },
                .{ .name = "shakedown", .module = shakedown.module("shakedown") },
                .{ .name = "strand", .module = strand.module("strand") },
                .{ .name = "regex_suite", .module = regexSuite(b, p) },
                .{ .name = "v8_verdicts", .module = embedded(b, p, "testdata/v8/matches.json") },
            },
        }),
    });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    b.getInstallStep().dependOn(&tests.step);
    tools.preflight.addCi(b, p, .{ .tests = test_step, .portable_tests = true });
}

/// regex's own test suite: the files regex 1.13.1 loads, its testdata vendored in testdata/regex.
const regex_suite = [_][]const u8{
    "anchored",        "bytes",                 "crazy",        "crlf",               "earliest",
    "empty",           "expensive",             "flags",        "iter",               "leftmost-all",
    "line-terminator", "misc",                  "multiline",    "no-unicode",         "overlapping",
    "regression",      "set",                   "substring",    "unicode",            "utf8",
    "word-boundary",   "word-boundary-special", "fowler/basic", "fowler/nullsubexpr", "fowler/repetition",
};

/// A module that embeds each file of regex's suite: `files`, its names and bytes.
fn regexSuite(b: *std.Build, p: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, "pub const files = [_]struct { name: []const u8, bytes: []const u8 }{\n") catch @panic("out of memory");
    for (regex_suite) |name| {
        _ = files.addCopyFile(p.path(b.fmt("testdata/regex/{s}.toml", .{name})), b.fmt("{s}.toml", .{name}));
        source.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .bytes = @embedFile(\"{s}.toml\") }},\n", .{ name, name })) catch @panic("out of memory");
    }
    source.appendSlice(b.allocator, "};\n") catch @panic("out of memory");
    return b.createModule(.{ .root_source_file = files.add("regex_suite.zig", source.items) });
}

/// A module whose `bytes` are one file's.
fn embedded(b: *std.Build, p: *std.Build, path: []const u8) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(p.path(path), "data");
    return b.createModule(.{ .root_source_file = files.add("embedded.zig", "pub const bytes = @embedFile(\"data\");\n") });
}
