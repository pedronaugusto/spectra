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
    addSourceImports(b, p, module, target, optimize);
    return module;
}

/// What spectra's sources import: aegis, xenoglyph, ladar, and the prefilter kernels that need
/// instructions beyond the target's baseline, each a module of its own built with them (Zig sets
/// CPU features per module), entered only where ladar says the CPU has them. `kernels_teddy` is
/// the scan they share, generic and inline, so each compiles it with its own instructions.
fn addSourceImports(b: *std.Build, p: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    module.addImport("aegis", p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis"));
    module.addImport("xenoglyph", p.dependency("xenoglyph", .{ .target = target, .optimize = optimize }).module("xenoglyph"));
    module.addImport("ladar", p.dependency("ladar", .{ .target = target, .optimize = optimize }).module("ladar"));
    const teddy = b.createModule(.{ .root_source_file = p.path("src/kernels/teddy.zig"), .target = target, .optimize = optimize });
    module.addImport("kernels_teddy", teddy);
    const Kernel = struct { name: []const u8, source: []const u8, features: std.Target.Cpu.Feature.Set };
    const kernels: []const Kernel = switch (target.result.cpu.arch) {
        .aarch64 => comptime &.{
            .{ .name = "kernels_arm_neon", .source = "arm_neon", .features = std.Target.aarch64.featureSet(&.{.neon}) },
        },
        .x86_64 => comptime &.{
            .{ .name = "kernels_x86_ssse3", .source = "x86_ssse3", .features = std.Target.x86.featureSet(&.{.ssse3}) },
            .{ .name = "kernels_x86_avx2", .source = "x86_avx2", .features = std.Target.x86.featureSet(&.{.avx2}) },
        },
        else => &.{},
    };
    for (kernels) |k| {
        var query = std.Target.Query.fromTarget(&target.result);
        query.cpu_features_sub.removeFeatureSet(k.features);
        query.cpu_features_add.addFeatureSet(k.features);
        const kernel = b.createModule(.{
            .root_source_file = p.path(b.fmt("src/kernels/{s}.zig", .{k.source})),
            .target = b.resolveTargetQuery(query),
            .optimize = optimize,
            .imports = &.{.{ .name = "kernels_teddy", .module = teddy }},
        });
        module.addImport(k.name, kernel);
    }
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
    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shakedown", .module = shakedown.module("shakedown") },
            .{ .name = "strand", .module = strand.module("strand") },
            .{ .name = "regex_suite", .module = regexSuite(b, p) },
            .{ .name = "v8_verdicts", .module = embedded(b, p, "testdata/v8/matches.json") },
            .{ .name = "v8_replace", .module = embedded(b, p, "testdata/v8/replace.json") },
        },
    });
    addSourceImports(b, p, test_module, target, optimize);
    const tests = b.addTest(.{ .name = "spectra-tests", .filters = filters, .root_module = test_module });
    const check = b.step("check", "Compile the tests without running them");
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&tests.step);
    // The README's examples, run as part of the tests.
    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{ .root_source_file = p.path("examples/usage.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "spectra", .module = package.module("spectra") }} }),
    });
    const examples = b.step("examples", "Build and run the usage example");
    examples.dependOn(&b.addRunArtifact(example).step);
    test_step.dependOn(examples);
    check.dependOn(&example.step);
    b.getInstallStep().dependOn(&tests.step);
    // The release tier runs every property under Zig's fuzzer (each shakedown property is a
    // fuzz target: the parsers, translation, compilation and every engine against its oracle)
    // and the suite with safety on.
    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "test", .tsan_step = "test" },
        // The benchmark rows (spectra.md §8): CI compiles them; timings are the running machine's.
        .bench = .{
            .programs = &.{.{ .name = "bench", .source = "bench/main.zig" }},
            .imports = tools.preflight.Bench.importsFrom(benchImports),
            .target = target,
            .optimize = optimize,
        },
    });
}

/// spectra again, in the mode a benchmark builds in: an imported module keeps its own mode, so a
/// ReleaseFast benchmark over the Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("spectra", .{ .target = target, .optimize = optimize }).builder;
    const module = b.createModule(.{ .root_source_file = p.path("src/spectra.zig"), .target = target, .optimize = optimize });
    addSourceImports(b, p, module, target, optimize);
    const aegis = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    return b.allocator.dupe(std.Build.Module.Import, &.{ .{ .name = "spectra", .module = module }, .{ .name = "aegis", .module = aegis } }) catch @panic("OOM");
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
