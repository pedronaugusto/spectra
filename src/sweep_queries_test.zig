//! The acceptance test for sets and the stepping automaton: sweep's five set queries (`any`,
//! `first`/`last`/`all`, `leadsTo`, `ancestors`) written on spectra's API alone, as sweep's move
//! onto spectra will write them, over globs translated by hand. Each query is a few calls, with
//! no workaround; the answers are checked against each pattern searched alone.
const std = @import("std");
const aegis = @import("aegis");
const Regex = @import("Regex.zig");
const Set = @import("Set.zig");
const Automaton = @import("Automaton.zig");
const testing = std.testing;
const gpa = testing.allocator;

/// Globs, as sweep would translate them: `*` is `[^/]*`, `**/` is `(?:.*/)?`, a trailing `/**`
/// is `/.*`, and a glob matches a whole subject (`Input.whole`, no anchors written).
const globs = [_]struct { glob: []const u8, regex: []const u8 }{
    .{ .glob = "*.zig", .regex = "[^/]*\\.zig" },
    .{ .glob = "src/**", .regex = "src/.*" },
    .{ .glob = "**/test_*.zig", .regex = "(?:.*/)?test_[^/]*\\.zig" },
    .{ .glob = "docs/*/index.md", .regex = "docs/[^/]*/index\\.md" },
    .{ .glob = "build", .regex = "build" },
};

const Queries = struct {
    set: *const Set,
    cache: *Set.Cache,
    out: *Set.Patterns,
    auto: Automaton,
    walk: *Automaton.Cache,

    fn whole(subject: []const u8) Set.Input {
        return .{ .haystack = subject, .span = .{ .start = 0, .end = subject.len }, .whole = true };
    }

    /// sweep's `any`: whether any entry matches.
    fn any(q: Queries, subject: []const u8) !bool {
        return q.set.isMatch(q.cache, whole(subject));
    }

    /// sweep's `first`, `last` and `all`: one `matches`, then the bits.
    fn first(q: Queries, subject: []const u8) !?u32 {
        _ = try q.set.matches(q.cache, whole(subject), q.out);
        return if (q.out.first()) |p| p.raw() else null;
    }

    fn last(q: Queries, subject: []const u8) !?u32 {
        _ = try q.set.matches(q.cache, whole(subject), q.out);
        return if (q.out.last()) |p| p.raw() else null;
    }

    fn all(q: Queries, a: std.mem.Allocator, subject: []const u8) ![]const u32 {
        _ = try q.set.matches(q.cache, whole(subject), q.out);
        var list: std.ArrayList(u32) = .empty;
        var it = q.out.iterator();
        while (it.next()) |p| try list.append(a, p.raw());
        return list.items;
    }

    /// sweep's `leadsTo`: whether some subject `dir`, a separator, then anything could match;
    /// `""` is the root. On `GaveUp` the recipe stops pruning: true.
    fn leadsTo(q: Queries, dir: []const u8) bool {
        var s = q.auto.start(q.walk, .{}) catch return true;
        for (dir) |b| s = q.auto.step(q.walk, s, b) catch return true;
        if (dir.len > 0) s = q.auto.step(q.walk, s, '/') catch return true;
        return !Automaton.isDead(s);
    }

    /// One step of sweep's `ancestors`: the prefix `subject[0..end]`, the last entry matching it,
    /// and whether something below it could match.
    const Step = struct { end: usize, last: ?u32, leads: bool };

    /// sweep's `ancestors`: one pass over `subject`, stopping at each separator and at the end.
    /// A state is a value, so probing the separator below a prefix leaves the walk where it is.
    fn ancestors(q: Queries, a: std.mem.Allocator, subject: []const u8) ![]const Step {
        var steps: std.ArrayList(Step) = .empty;
        var s = try q.auto.start(q.walk, .{});
        var at: usize = 0;
        while (true) {
            const end = std.mem.findScalarPos(u8, subject, at, '/') orelse subject.len;
            for (subject[at..end]) |b| s = try q.auto.step(q.walk, s, b);
            const ended = try q.auto.stepEnd(q.walk, s);
            const matched = q.auto.patterns(q.walk, ended);
            const below = if (end == 0) s else try q.auto.step(q.walk, s, '/');
            try steps.append(a, .{ .end = end, .last = if (matched.len > 0) matched[matched.len - 1] else null, .leads = !Automaton.isDead(below) });
            if (end == subject.len) return steps.items;
            s = try q.auto.step(q.walk, s, '/');
            at = end + 1;
        }
    }
};

test "sweep's five set queries are a few calls each on spectra's sets and stepping automaton" {
    var state: std.heap.ArenaAllocator = .init(gpa);
    defer state.deinit();
    const a = state.allocator();
    var sources: [globs.len]aegis.input.Untrusted([]const u8) = undefined;
    for (globs, &sources) |g, *s| s.* = .init(g.regex);
    var set = try Set.compile(gpa, &sources, .{});
    defer set.deinit();
    var cache = try set.cache(gpa);
    defer cache.deinit(gpa);
    var out = try set.patterns(gpa);
    defer out.deinit(gpa);
    const auto = set.automaton().?;
    var walk = try auto.cache(gpa);
    defer walk.deinit(gpa);
    const q: Queries = .{ .set = &set, .cache = &cache, .out = &out, .auto = auto, .walk = &walk };

    // any, first, last, all.
    try testing.expect(try q.any("main.zig"));
    try testing.expect(!try q.any("lib/main.zig"));
    try testing.expectEqual(@as(?u32, 0), try q.first("test_set.zig"));
    try testing.expectEqual(@as(?u32, 2), try q.last("test_set.zig"));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, try q.all(a, "src/x/test_a.zig"));
    try testing.expectEqual(@as(?u32, null), try q.first("docs/a/b/index.md"));
    try testing.expectEqual(@as(?u32, 3), try q.first("docs/guide/index.md"));

    // leadsTo.
    try testing.expect(q.leadsTo(""));
    try testing.expect(q.leadsTo("src"));
    try testing.expect(q.leadsTo("docs"));
    try testing.expect(q.leadsTo("docs/guide"));
    // `**/test_*.zig` reaches below every directory.
    try testing.expect(q.leadsTo("anything/at/all"));

    // Without it, walking prunes: nothing lies below `lib` or `docs/guide/deeper`.
    const narrow_sources = [_]aegis.input.Untrusted([]const u8){ .init("src/.*"), .init("docs/[^/]*/index\\.md") };
    var narrow = try Set.compile(gpa, &narrow_sources, .{});
    defer narrow.deinit();
    var narrow_cache = try narrow.cache(gpa);
    defer narrow_cache.deinit(gpa);
    var narrow_out = try narrow.patterns(gpa);
    defer narrow_out.deinit(gpa);
    const narrow_auto = narrow.automaton().?;
    var narrow_walk = try narrow_auto.cache(gpa);
    defer narrow_walk.deinit(gpa);
    const n: Queries = .{ .set = &narrow, .cache = &narrow_cache, .out = &narrow_out, .auto = narrow_auto, .walk = &narrow_walk };
    try testing.expect(n.leadsTo("") and n.leadsTo("src") and n.leadsTo("src/deep/er") and n.leadsTo("docs") and n.leadsTo("docs/guide"));
    try testing.expect(!n.leadsTo("lib") and !n.leadsTo("docs/guide/deeper") and !n.leadsTo("sr"));
    const pruned = try n.ancestors(a, "lib/x/y");
    try testing.expectEqual(Queries.Step{ .end = 3, .last = null, .leads = false }, pruned[0]);

    // ancestors: the last entry at each prefix, and whether something lies below it.
    const steps = try q.ancestors(a, "src/build/test_x.zig");
    try testing.expectEqual(3, steps.len);
    try testing.expectEqual(Queries.Step{ .end = 3, .last = null, .leads = true }, steps[0]);
    try testing.expectEqual(Queries.Step{ .end = 9, .last = 1, .leads = true }, steps[1]);
    try testing.expectEqual(Queries.Step{ .end = 20, .last = 2, .leads = true }, steps[2]);
    const at_root = try q.ancestors(a, "build");
    try testing.expectEqual(Queries.Step{ .end = 5, .last = 4, .leads = true }, at_root[0]);

    // Every prefix of every subject, against each pattern searched whole on its own.
    const subjects = [_][]const u8{ "", "build", "src", "src/a.zig", "docs/x/index.md", "a/b/test_c.zig", "docs/x/y/index.md", "main.zig/x" };
    var alone: [globs.len]Regex = undefined;
    var caches: [globs.len]Regex.Cache = undefined;
    for (globs, &alone, &caches) |g, *re, *rc| {
        re.* = try Regex.compile(gpa, .init(g.regex), .{});
        rc.* = try re.cache(gpa);
    }
    defer for (&alone, &caches) |*re, *rc| {
        rc.deinit(gpa);
        re.deinit();
    };
    for (subjects) |subject| {
        for (try q.ancestors(a, subject)) |step| {
            const prefix = subject[0..step.end];
            var want: ?u32 = null;
            for (&alone, &caches, 0..) |*re, *rc, i| {
                if ((try re.find(rc, Queries.whole(prefix))) != null) want = @intCast(i);
            }
            try testing.expectEqual(want, step.last);
            try testing.expectEqual(want, try q.last(prefix));
        }
    }
}
