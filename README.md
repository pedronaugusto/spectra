# spectra

spectra is regular expressions for Zig in linear time, for every pattern and every input, guaranteed rather than
hoped: a lazy DFA to search, NFA simulations for captures, Unicode classes from
[xenoglyph](https://github.com/pedronaugusto/xenoglyph), and nothing that backtracks without a bound. It reads Rust
regex's syntax and ECMAScript's (JavaScript's, and JSON Schema's `pattern`), searches bytes or UTF-8, and refuses by
name at compile what it cannot run in linear time, never running it slowly.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/spectra`, then obtain the
`spectra` module through `b.dependency` and add it to your executable's imports. spectra depends on
[aegis](https://github.com/pedronaugusto/aegis), [xenoglyph](https://github.com/pedronaugusto/xenoglyph) (Unicode
data) and [ladar](https://github.com/pedronaugusto/ladar) (which SIMD instructions the CPU has). See
[the design](docs/design.md) for the engines, their bounds and how they are tested.

## Usage

A `Regex` is compiled once and immutable; each thread searches with a `Cache` of its own, allocated once, and no
search allocates:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const spectra = @import("spectra");

// Compiled once, searched by any number of threads, each with a cache of its own.
var re = try spectra.Regex.compile(gpa, .init("(\\w+)@(\\w+)\\.com"), .{});
defer re.deinit();
var cache = try re.cache(gpa);
defer cache.deinit(gpa);
const haystack = "write to ann@example.com or bob@test.com";
std.debug.assert(try re.isMatch(&cache, haystack));
const m = (try re.find(&cache, .of(haystack))).?;
std.debug.assert(std.mem.eql(u8, haystack[m.start..m.end], "ann@example.com"));
// Each group's span, the whole match first; null where a group took no part.
var groups: [3]?spectra.Regex.Span = undefined;
std.debug.assert(try re.captures(&cache, .of(haystack), &groups));
std.debug.assert(std.mem.eql(u8, haystack[groups[2].?.start..groups[2].?.end], "example"));
// Every match in turn.
var it = re.findAll(&cache, haystack);
var count: usize = 0;
while (try it.next()) |_| count += 1;
std.debug.assert(count == 2);
```
<!-- END GENERATED -->

The ECMAScript dialect follows ECMA-262 2025, including its rule that an iteration matching the empty string fails:

<!-- BEGIN GENERATED zig build docs -- ecmascript -->
```zig
const spectra = @import("spectra");

// ECMAScript's dialect, as JSON Schema's `pattern` and JavaScript read it: an iteration
// that matches empty fails, as ECMA-262 says, so `(|a)+` on "a" is "a", as in V8.
var re = try spectra.Regex.compile(gpa, .init("(|a)+"), .{ .syntax = .{ .dialect = .ecmascript, .unicode = true } });
defer re.deinit();
var cache = try re.cache(gpa);
defer cache.deinit(gpa);
const m = (try re.find(&cache, .of("a"))).?;
std.debug.assert(m.start == 0);
std.debug.assert(m.end == 1);
// Whether a pattern is valid ECMA-262, whatever spectra runs.
std.debug.assert(try spectra.ecmascript.validate(gpa, .init("(?<year>\\d{4})-\\k<year>"), "u", .{}, null));
```
<!-- END GENERATED -->

A pattern spectra cannot run in linear time is refused with the reason and the span:

<!-- BEGIN GENERATED zig build docs -- refusal -->
```zig
const spectra = @import("spectra");

// What spectra cannot run in linear time is refused by name, with where: here an
// ECMAScript backreference, valid ECMA-262 but not regular.
var d: spectra.Regex.Diagnostic = .{};
const got = spectra.Regex.compile(gpa, .init("(a)\\1"), .{ .syntax = .{ .dialect = .ecmascript }, .diagnostic = &d });
std.debug.assert(got == error.Unsupported);
std.debug.assert(d.reason == .unsupported_backreference);
std.debug.assert(d.span.start == 3);
std.debug.assert(d.span.end == 5);
```
<!-- END GENERATED -->

## Scope

- **Dialects.** Rust's `regex` 1.13 syntax (every flag, Unicode classes and properties, `(?-u)` bytes) and ECMAScript
  (ECMA-262 2025: `u`, `v` with class set operations and `\q{}`, `i`, `m`, `s`, modifiers, named groups; Annex B's
  grammar without `u` or `v`). `ecmascript.validate` says whether a pattern is valid ECMA-262 whatever spectra runs.
- **Matching.** Leftmost-first, as Rust's `regex` and backtracking engines report it: is-match, find, captures and
  every match in turn, replace (a template in the dialect's `$` syntax, literal bytes, or a function, written to a
  writer) and split (by each dialect's rules), over a span of the haystack with assertions seeing the whole of it,
  anchored or not. Sets of
  patterns searched in one pass (`Set`), and a stepping automaton for walking a trie or a path (`Automaton`).
- **Lookaround** in the ECMAScript dialect: lookahead and lookbehind, positive and negative, nested, with any body,
  in linear time by the method of Barrière and Pit-Claudel ("Linear Matching of JavaScript Regular Expressions", PLDI
  2024): each lookaround's truth at every position is built before the search reads it, or computed beside it where
  the scan reads the haystack the lookaround's way. Rows that must be stored take a bit per position each, bounded by
  `Limits.oracle`: a longer haystack is refused by name (`error.HaystackTooLong`, said up front by
  `Regex.longestHaystack`), never searched slowly. Groups inside a positive lookaround are its first success's, as
  ECMA-262 says (a lookbehind's read backward). The lazy DFA finds where a match ends, its lookarounds
  folded into its states or read as up to four columns; past that, the PikeVM.
- **Refused by name.** Backreferences (not regular); in the ECMAScript dialect without `u` or `v`, half of a code
  point past U+FFFF named alone (spectra reads UTF-8, not UTF-16 code units); `v`'s properties of strings. Every
  limit (`Limits`: pattern length, nesting, repetition counts, automaton size, cache size) refuses past it, before
  allocating.
- **Linear time, and its limits.** Every search is linear in the haystack times the automaton: each engine either is
  (the PikeVM, the bounded backtracker, the one-pass DFA) or hands the search to one that is when its own bound
  would break (the lazy DFAs give up after too many cache clears, the reverse strategies never read a byte twice).
  Iterating every match is linear where each search stops near its match; where a preferred branch outlives the
  matches it does not take (`\w+X|\w` over word characters with no `X`) it is quadratic in the run, in every
  leftmost-first engine; `Regex.findAll`'s documentation shows the case. Memory is fixed at compile by `Limits`.
- **Differences from V8** in the ECMAScript dialect: three cases of V8's verdicts where V8 reads UTF-16 code units
  and spectra reads code points.
- **Not yet.** Dense DFAs built ahead, compiling patterns to tables at build time, leftmost-longest matching.

## Stability

spectra is unreleased; 0.1.0 is its first release. From then, a 0.x minor version may change the API and says how in
the CHANGELOG; a patch never does. What a pattern matches is fixed by its dialect's reference, Rust's `regex` 1.13
for the Rust dialect and ECMA-262 2025 (checked against V8) for ECMAScript: a difference from it is a bug, fixed in a
patch, whatever code relied on it. `Limits`' defaults may grow in a minor version; which engine answers a search, and
the `Cache`'s layout, are not part of the API.

## Platforms

Every target Zig supports, with the same answers. The prefilters' Teddy kernels use SSSE3 or AVX2 on x86-64 where the
CPU has them and NEON on AArch64; elsewhere, and on CPUs without them, portable code finds the same matches.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [bay](https://github.com/pedronaugusto/bay) runs spectra's development. [preflight](https://github.com/pedronaugusto/preflight)
  (the source checks, the tests and CI), [shakedown](https://github.com/pedronaugusto/shakedown) (the properties and
  fuzz targets) and [strand](https://github.com/pedronaugusto/strand) (reading regex's TOML suite) are dev dependencies
  through bay, which a project that depends on spectra never sees.

## Testing

`bay test` runs the suite and the usage example. Rust's `regex` test suite (the files regex 1.13.1 loads, vendored in
`testdata/regex` with its licenses) runs through the Rust dialect on every engine path, the PikeVM alone and the
default engines, each path counted; V8's verdicts on 9,480 ECMAScript cases (`testdata/v8`, generated by
`testdata/v8/generate.mjs` under Node) run the same way, beside ECMA-262's semantics written as a test-only matcher
over the HIR. A bounded backtracker over the automaton is the oracle for random patterns and haystacks in both
dialects: the PikeVM, the lazy DFAs forward and reversed, the bounded backtracker, the one-pass DFA, every prefilter
and every strategy are checked against it or against the PikeVM. The linear bound is counted, not timed, on the
shapes that make backtracking exponential. test262's RegExp lookaround cases (every file that writes a
lookaround) are transcribed with their expected answers, V8's verdicts include lookaround patterns and replace and
split, and RE2's search tests run against the test backtracker. Every property runs seeded in `bay test`, and under `bay test --fuzz`
Zig's fuzzer searches further; the release tier's `bay hardened-fuzz` runs them under the fuzzer with safety on.

## License

MIT.

src/hir/suffix.zig and src/hir/inner.zig include code translated from the Rust regex project (MIT OR Apache-2.0); see
LICENSES/.
src/test262_test.zig transcribes test cases from test262, the ECMAScript test suite (BSD-3-Clause); its licence is
LICENSES/test262-BSD.txt.
src/re2_search_test.zig holds the pattern and text table of RE2's search tests (BSD-3-Clause); its licence is
LICENSES/re2-BSD.txt.
