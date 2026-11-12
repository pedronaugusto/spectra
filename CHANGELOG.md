# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Lookaround's first phase, not yet searched: the ECMAScript translation keeps lookahead and lookbehind, positive
  and negative and nested, numbered in preorder, and the oracle builds each one's row (its truth at every position,
  innermost first, by a scan that writes every match). A pattern holding one is still refused, by one reason,
  `unsupported_lookaround`, which replaces `unsupported_lookahead`, `unsupported_lookbehind` and
  `unsupported_nested_lookaround`.
- `Automaton`, the stepping automaton over a pattern's or a set's forward lazy DFA of the all kind (`Regex.automaton`,
  `Set.automaton`): `start`, `step`, `stepEnd` (whether the bytes so far match, a match being seen one byte late),
  `isMatch`, `isDead` and `patterns`, in a `Cache` of the walker's. `error.Stale` refuses a state built before the
  store's last clear and `error.GaveUp` follows the give-up rule; the doc gives the walker's recipe for each (re-walk
  from `start` within ten times the bytes stepped, else the whole-string searches). Null where the DFA has quit
  bytes (a Unicode word boundary).
- `Set`: many patterns compiled together into one automaton (a match state per pattern) and searched in one pass:
  `isMatch`, `matches` (every pattern with a match, each pattern's matches on their own, into a caller-allocated
  `Set.Patterns`), and `first` (the leftmost-first match over the patterns as one alternation, with its pattern).
  Pattern indexes are branded, and a match is checked against the set that found it. A refused pattern is named by
  `Diagnostic.pattern`. Two lazy DFAs answer a set: one of the all kind (no thread dropped at a match, a state's
  match the set of patterns it reached) for `matches`, `isMatch` and whole searches, and one leftmost-first for
  where `first`'s match ends; the PikeVM where either quits, gives up or is absent (`Set.engines`,
  `Set.Cache.last`).
- `Input.whole`: only a match covering the span counts. `Regex` searches it on the PikeVM (`Cache.Path.whole`).
- `Regex.SearchError` (`error.HaystackTooLong`): every search (`isMatch`, `find`, `captures`, and `Matches.next` and
  `nextCaptures`) returns it, for lookaround's stored rows to come, which a search past `Limits.oracle` refuses by
  name. No pattern stores rows yet, so no search returns it. `Regex.longestHaystack(search)` says the limit up
  front; null today.
- The Rust dialect's parser: a pattern into an `Ast` whose every node carries its span, groups and nested classes read
  with explicit stacks bounded by `Limits.nesting`, every count and code point checked before use, the pattern taken
  as `aegis.input.Untrusted`.
- The ECMAScript dialect (`Syntax.dialect = .ecmascript`, `u` by `Syntax.unicode`, `v` by `Syntax.unicode_sets`):
  ECMA-262's pattern grammar with modifiers, duplicate group names in separate alternatives and `v`'s class set
  expressions and `\q{...}` strings; Annex B's grammar without `u` or `v`. Lookarounds and backreferences are read into
  the `Ast` (`lookaround`, `backreference`), to be refused at translation where spectra cannot run them.
- `ecmascript.validate(gpa, pattern, flags, limits, diagnostic)`: whether a pattern is valid ECMA-262 whatever spectra
  runs; `\p{...}` held to ECMA-262's tables exactly, by xenoglyph's names.
- The HIR's range sets (`hir/ranges.zig`), of code points and of bytes: sorted ranges kept apart, union,
  intersection, difference, symmetric difference and negation in time linear in the ranges, and closing under case
  three ways: simple case folding (Rust's regex, ECMA-262 under `u` and `v`), ASCII's letters, and ECMA-262's
  Canonicalize without `u` or `v` (full uppercase to one code unit, never from past U+007F into ASCII), orbit by orbit
  through xenoglyph's `case.nextFolding`.
- The HIR and the translation of both dialects into it (`hir/Hir.zig`, `hir/translate.zig`): flags applied, classes as
  sets, Unicode names resolved (Rust's loosely, in regex-syntax's order; ECMA-262's exactly), each dialect's own `.`, `\d`,
  `\s`, `\w`, `\b` and case rules. Refused by name as `Unsupported`: backreferences, lookbehind, a lookaround in a
  lookaround, `v`'s properties of strings, and without `u` or `v` half of a code point past U+FFFF named alone; `.` and a
  negated class there take one code point, where a UTF-16 engine takes half of one. Walked on explicit stacks.
- Literal extraction (`hir/literals.zig`): the literals every match starts or ends with, exact or not, regex-syntax's
  extractor with its limits, read on an explicit stack.
- The Thompson NFA over bytes (`nfa/compile.zig`): regex-automata's fragments and preference order, UTF-8 classes as
  minimal byte automata, a repetition's further times copied rather than compiled again, every state charged to
  `Limits.nfa` before it is allocated; reversed (`Options.reverse`) for the reverse searches.
- The public engine, `Regex`: `compile(gpa, pattern, .{ syntax, limits, diagnostic, prefilter })`, `cache`, `isMatch`,
  `find`, `captures`, `captureCount`, `captureIndex`, `findAll` and `findAllIn` over a span, anchored or not, with
  `Matches.next` and `nextCaptures`; `engines()` says which engines a pattern has. A `Regex` is immutable and shared;
  each thread searches with a `Cache` of its own, sized once within `Limits.cache`, and no search allocates.
- ECMAScript's repetition semantics: each iteration clears its atom's captures, and an iteration past the minimum that
  matches empty fails (ECMA-262's RepeatMatcher), in linear time by a bit each thread carries (Barrière and
  Pit-Claudel, PLDI 2024, §4.1).
- The engines: the PikeVM; the lazy DFA, forward and reversed, in a fixed store with RE2's give-up rule and quit bytes
  for assertions that read code points; the bounded backtracker (`Limits.backtrack`); the one-pass DFA
  (`Limits.onepass`); each checked against a backtracker over the automaton and the PikeVM.
- The meta strategies (`strategy.zig`): the forward lazy DFA for the end, the reverse one for the start, captures over
  the match alone; reading back from the end for a pattern anchored there; the literal strategy; reverse suffix and
  reverse inner, each taken only where a proof shows the literal's order is the matches' order.
- Prefilters (`Limits.prefilter`): memchr for the bytes literals start with, a rare-byte-pair search for one literal,
  Aho-Corasick for many, Teddy for up to 64 on SSSE3, AVX2 or NEON as [ladar](https://github.com/pedronaugusto/ladar)
  detects them.
- Every property (parsers, translation, compilation, every engine against its oracle, any bytes as a pattern) runs
  under Zig's fuzzer with `bay test --fuzz`, and in the release tier's `hardened-fuzz`.
