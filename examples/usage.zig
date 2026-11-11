const std = @import("std");
const spectra = @import("spectra");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // --- README:usage ---
    // Compiled once, searched by any number of threads, each with a cache of its own.
    var re = try spectra.Regex.compile(gpa, .init("(\\w+)@(\\w+)\\.com"), .{});
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    const haystack = "write to ann@example.com or bob@test.com";
    std.debug.assert(re.isMatch(&cache, haystack));
    const m = re.find(&cache, .of(haystack)).?;
    std.debug.assert(std.mem.eql(u8, haystack[m.start..m.end], "ann@example.com"));
    // Each group's span, the whole match first; null where a group took no part.
    var groups: [3]?spectra.Regex.Span = undefined;
    std.debug.assert(re.captures(&cache, .of(haystack), &groups));
    std.debug.assert(std.mem.eql(u8, haystack[groups[2].?.start..groups[2].?.end], "example"));
    // Every match in turn.
    var it = re.findAll(&cache, haystack);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    std.debug.assert(count == 2);
    // --- README:usage ---
    try dialects(gpa);
    try refusals(gpa);
}

fn dialects(gpa: std.mem.Allocator) !void {
    // --- README:ecmascript ---
    // ECMAScript's dialect, as JSON Schema's `pattern` and JavaScript read it: an iteration
    // that matches empty fails, as ECMA-262 says, so `(|a)+` on "a" is "a", as in V8.
    var re = try spectra.Regex.compile(gpa, .init("(|a)+"), .{ .syntax = .{ .dialect = .ecmascript, .unicode = true } });
    defer re.deinit();
    var cache = try re.cache(gpa);
    defer cache.deinit(gpa);
    const m = re.find(&cache, .of("a")).?;
    std.debug.assert(m.start == 0 and m.end == 1);
    // Whether a pattern is valid ECMA-262, whatever spectra runs.
    std.debug.assert(try spectra.ecmascript.validate(gpa, .init("(?<year>\\d{4})-\\k<year>"), "u", .{}, null));
    // --- README:ecmascript ---
}

fn refusals(gpa: std.mem.Allocator) !void {
    // --- README:refusal ---
    // What spectra cannot run in linear time is refused by name, with where: here an
    // ECMAScript backreference, valid ECMA-262 but not regular.
    var d: spectra.Regex.Diagnostic = .{};
    const got = spectra.Regex.compile(gpa, .init("(a)\\1"), .{ .syntax = .{ .dialect = .ecmascript }, .diagnostic = &d });
    std.debug.assert(got == error.Unsupported);
    std.debug.assert(d.reason == .unsupported_backreference);
    std.debug.assert(d.span.start == 3 and d.span.end == 5);
    // --- README:refusal ---
}
