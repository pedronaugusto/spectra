# Design

spectra is regular expressions in linear time. It reads two dialects, Rust regex's and
ECMAScript's, compiles a pattern to one byte automaton, and searches it with engines whose work is
linear in the haystack for every pattern. What cannot be searched in linear time is refused at
compile, by name, never run slowly.

Its runtime closure is spectra → aegis, xenoglyph, ladar → std. No call takes `std.Io`: compiling
allocates from the caller's allocator under `Limits`, a `Cache` allocates once, and a search
allocates nothing (`replace` writes to a `*std.Io.Writer` the caller owns).

regex-automata (the Rust regex project) is the reference for the pipeline, the engines and the meta
strategies. Where spectra's code follows it closely, the file says so and carries its notice
(`LICENSES/regex-MIT.txt`). Change this document with the code when an owner, an invariant or a
decision changes.

## Layers

`ci/layers.zig` checks the production import graph and refuses a source file that has no layer.
Imports stay within a layer or go down. From the bottom:

- **teddy, kernels**: `src/kernels/teddy.zig` holds Teddy's scan, generic over the vector width and
  the shuffle. `x86_ssse3.zig`, `x86_avx2.zig` and `arm_neon.zig` each hold one instruction's
  wrapper. Each is a build module of its own (`ci/layers.zig` `modules`).
- **vocabulary**: `Syntax.zig` (dialect and flags), `Limits.zig`, `Charged.zig` (a charging
  allocator), `SparseSet.zig`, `utf8.zig`.
- **syntax**: `syntax/Ast.zig`, `syntax/diagnostic.zig`, `syntax/parse.zig` (Rust),
  `syntax/ecma.zig` (ECMAScript, and ECMA-262 validity).
- **hir**: `hir/ranges.zig` (range sets), `Hir.zig`, `hir/translate.zig`, `hir/literals.zig`,
  and `hir/suffix.zig` and `hir/inner.zig`, the proofs behind the reverse strategies.
- **nfa**: `nfa/utf8.zig`, `Nfa.zig`, `nfa/look.zig` (assertions), `nfa/compile.zig`.
- **prefilters**: `prefilter/rank.zig` (byte rarity), `prefilter.zig`.
- **engines**: `pikevm.zig`, `lazy.zig`, `backtrack.zig`, `onepass.zig`, `oracle.zig`
  (lookaround's rows).
- **meta**: `Regex.zig`, `Set.zig`, `Automaton.zig`, `strategy.zig`.
- **public**: `spectra.zig`.

All paths are under `src/`. Tests live beside the code (`*_test.zig`) and under `src/testing/`.
shakedown, strand and preflight are dev dependencies, outside a consumer's closure.

## Pipeline

1. **Parse** (`syntax/`) the pattern into an AST whose every node carries its span, so every
   refusal names a span and a `Reason` (`syntax/diagnostic.zig`). The parsers are iterative, with
   explicit stacks bounded by `Limits.nesting`. The pattern arrives as `aegis.input.Untrusted`.
2. **Translate** (`hir/translate.zig`) to the HIR. Classes become sorted ranges of code points (or
   of bytes, with `utf8 = false`), case-insensitivity becomes closure under the dialect's case
   rule, and Unicode properties become their ranges, all from xenoglyph. Class set operations
   happen here, in time linear in the ranges.
3. **Extract literals** (`hir/literals.zig`, regex-syntax's extractor): the literals every match
   starts with and ends with, and the prefixes of each part of the top concatenation. The
   prefilters and the literal strategies read them.
4. **Compile** (`nfa/compile.zig`) to a Thompson NFA over bytes. UTF-8 classes become minimal byte
   automata (Daciuk's algorithm, finished states shared). Assertions are states that
   `nfa/look.zig` tests against the whole haystack, whatever span is searched. A repetition
   compiles its operand once and copies the states for each further time. Other compile modes give
   the reversed automaton (no captures), a strings-only automaton (only which strings match), and
   a lookbehind body read in ECMA-262's backward direction.
5. **Choose** (`Regex.compile`, `strategy.zig`) the engines the pattern has and the strategy that
   searches it, once, from what the automata and the literals say.

Translation charges every set it makes, and the compiler every state, to `Limits.nfa` through
`Charged`, before allocating. A pattern past the limit is refused with `error.TooLarge`
(`nfa_too_large`) before the memory is held. The charge follows the caller's sequence of sizes,
not whether the allocator grew in place, so a pattern's charge is the same on every machine.

## Dialects

Each dialect means what its reference says: Rust's `regex` 1.13 for `.rust`, ECMA-262 for
`.ecmascript`. A difference is a bug. Repetition is chosen in one place (`Repeats` in
`nfa/compile.zig`):

- Rust: `x*` over an `x` that can match empty compiles as `(x+)?`, so the loop prefers to stop
  once `x` matched empty, as regex does.
- ECMAScript (RepeatMatcher): each iteration clears its atom's groups (a `clear` state), and an
  iteration past the minimum that matches empty fails. The second rule is kept linear by a bit per
  thread, whether it read a byte since its innermost `loop_begin` (`Nfa.loop_checks`; Barrière and
  Pit-Claudel, PLDI 2024, §4.1). The PikeVM, the backtracker and the lazy DFA carry that bit.

ECMAScript's classes are ECMA-262's, not Rust's. `\d` is `[0-9]` and `\w` is `[A-Za-z0-9_]` in
every mode. `\s` is WhiteSpace plus LineTerminator. Under `u` or `v` with `i`, `\w` and `\b` also
take U+017F and U+212A, whose simple case folds are `s` and `k`. Without `u` or `v`, case closure is
ECMA-262's Canonicalize.

`ecmascript.validate(gpa, pattern, flags, limits, diagnostic)` reads the whole ECMA-262 pattern
grammar and says whether a pattern is valid, whether or not spectra runs it. JSON Schema's
`format: regex` needs that answer for patterns spectra refuses.

**Refused by name** with `error.Unsupported`, a `Reason` and the construct's span:

- backreferences (`unsupported_backreference`). They break uniform futures (see Lookaround), and
  matching with them is NP-hard;
- properties with no data here, such as Age and `v`'s properties of strings
  (`unsupported_unicode_property`);
- in ECMAScript without `u` or `v`, half of a code point past U+FFFF named alone
  (`unsupported_code_unit_split`). spectra reads UTF-8, which has no halves;
- a lookaround in a `Set` (`unsupported_lookaround_in_set`).

Rust's syntax has no lookaround.

## Engines

- **PikeVM** (`pikevm.zig`): every thread in lockstep, one step per byte, captures in slots. Each
  state is entered at most once per position, so the work is O(m·n) for m states and n bytes. That
  count is kept in every build and checked in safe ones. Every pattern has a PikeVM.
- **Lazy DFA** (`lazy.zig`): states built on demand into a fixed store (`Limits.lazy_dfa`) in the
  `Cache`. The store is cleared when full and never grows, and the state being left survives the
  clear. After three clears, a search that read fewer than ten bytes per state built since the last
  clear gives up (`error.GaveUp`), the rule RE2 and regex-automata use. An assertion that needs
  more than one byte of context (Unicode word characters, ECMA-262's U+2028 and U+2029) makes every
  byte past 0x7f a quit byte (`error.Quit`). On either error the PikeVM searches the span from its
  start, so the bound holds whatever the store's size. A match is seen one byte late. The forward
  DFA finds where the leftmost-first match ends.
- **Reverse lazy DFA**: the same engine over the reversed automaton. It reads back from a match's
  end to the earliest start of a match ending there, which is the leftmost-first match's start, so
  `find` needs no PikeVM.
- **Bounded backtracker** (`backtrack.zig`): depth first in preference order, each (state, position)
  explored once, marked by a bit, so it is linear by construction. Three quarters of
  `Limits.backtrack` are its bits, which bounds the spans it takes. A quarter is its stack. A
  search that is too long or too deep goes to the PikeVM.
- **One-pass DFA** (`onepass.zig`): for patterns where each byte leads one way at most from every
  state. It is a table built at compile under `Limits.onepass` that writes captures as it goes. It
  runs only over a match whose two ends the lazy DFAs (or a strategy) already found. ECMAScript
  iterations that clear or check, and more than 32 slots, rule it out.
- **Prefilters** (`prefilter.zig`): only where every literal is nonempty, so they can say no.
  - memchr for the one to three bytes every literal starts with;
  - for one literal, a search on its two rarest bytes (`prefilter/rank.zig`), confirmed by the
    whole literal;
  - Teddy for up to 64 literals where the CPU has the byte shuffle;
  - Aho-Corasick otherwise, a DFA over the literals' byte classes under `Limits.prefilter`.

  A prefilter whose candidates come too often (fewer than 4 bytes skipped on average over 16) is
  set aside for the rest of the search.

`Regex.engines()` says which engines a pattern has. `Cache.last`, `last_start`, `last_slots` and
`strategy_fell_back` say which answered the last search, so the tests can count every path.

## Strategies

A strategy is chosen once per pattern. Each falls back to `core` (and `core` to the PikeVM) on a
quit, a give-up or a guard, so no strategy can make a search worse than linear. An anchored search
does not use the reverse suffix or reverse inner strategy.

- **pikevm**: the pattern has no lazy DFA (its fewest states do not fit the store).
- **core**: the lazy DFA finds the end, and the reverse lazy DFA finds the start. Captures come
  from the one-pass DFA, the backtracker or the PikeVM, run over the match alone. A prefilter,
  where the prefixes give one, skips to where a match may start.
- **reverse_anchored**: every match ends at the haystack's end and the pattern is not anchored at
  its start. The reverse lazy DFA reads back from the end, and nothing reads forward.
- **literal**: every match is one exact literal (or one of several single bytes) that the
  prefilter confirms whole, and the pattern asserts nothing. The prefilter alone answers.
- **reverse_suffix**: every match ends with one literal L, and the pattern has no prefilter of its
  own. The prefilter finds L, the reverse DFA reads back to the earliest start s of a match ending
  there, and the forward DFA, anchored at s, finds the end.
- **reverse_inner**: chosen where none of the above leads and there is no prefilter. The top
  concatenation splits as P·X, where every match of X starts with one of a few literals. The
  prefilter finds one, P's reverse DFA reads back to s, and a forward search from s confirms or
  not.

**When the reverse strategies may lead.** Taken plainly, reverse suffix is wrong. In
`[0-9a-q][^x]*zz|bz` on `abzz`, the first `z` gives `bz` at 1 and the answer [1,4], where the
leftmost-first match is [0,4]. The tests pin this case. Each strategy is right exactly where no
match starts before s, and the danger is a match that starts before s and runs past the occurrence.
spectra takes a reverse strategy only where one of these rules that out:

- the part before the literal has a fixed length, so no match starts earlier and ends later;
- (one literal only) some byte of the literal is read by no part before it, so an occurrence
  inside an earlier match, or running into its literal at a shift, is impossible;
- the last reading part before the literal is a class read at least once that shares nothing with
  the literal or any other part, so an earlier match's run of it would cross the occurrence;
- the first reading part is such a class, so an earlier match's run, followed by the rest of the
  match at s, would be a match starting before s, against s being the earliest.

The arguments are written out at the head of `hir/suffix.zig` and `hir/inner.zig`. Each check
over-approximates what a part reads, so a proof never rests on a byte a part might read after all.
Where a proof fails, the strategy is not taken.

Neither strategy reads a byte twice. A reverse scan never reads back past the previous occurrence
(`error.Quadratic`). Reverse inner stops where an occurrence falls before the last forward scan's
end. Either way the search goes to `core`.

## Lookaround

ECMAScript's lookarounds run by Barrière and Pit-Claudel's oracle method ("Linear Matching of
JavaScript Regular Expressions", PLDI 2024, §4.3 and §4.4; `oracle.zig`).

Every linear engine relies on **uniform futures**: two paths at the same state and position have
the same futures, so the engine keeps the preferred one. A lookaround's truth at a position depends
on the position alone, so a `check` state that reads it keeps that property. This is why lookaround
can be linear and backreferences cannot: a backreference's future depends on what the path
captured.

**Rows.** A lookaround's **row** is its truth at every position. A scan that writes every accept
and never stops builds it: forward over `.*?body` for a lookbehind, and backward over `.*?rev(body)`
for a lookahead. These scans run on strings-only automata.

**Streamed and stored.** A lookaround read the same way as the scan that queries it is
**streamed**: its automaton is a lane in lockstep with that scan, closed before the states that
read it. One read the other way is **stored**: its row is built first, innermost first. Each search
uses them as follows:

- `find` and `captures` run the PikeVM over the main automaton. The main expression's lookbehinds
  stream beside it, their bits one position ahead of its step, and its lookaheads are stored.
- `findAll`, and therefore `replace` and `split`, store every row once per haystack. Their searches
  restart along the haystack, and a stream restarted at each match would make the iteration
  quadratic.
- `isMatch` scans the strings-only main expression in whichever direction streams most of its
  lookarounds. zod's patterns are all lookahead, so they read backward and store nothing.

**Memory.** Stored rows take one bit per row per position, within `Limits.oracle`. A haystack past
it is refused before a byte is read (`error.HaystackTooLong`). Rows are never rebuilt in pieces, and
no search falls back to a slower path. `Regex.longestHaystack(search)` gives the limit for each kind
of search, and null where that search stores nothing.

**One error set for every pattern.** Every search (`isMatch`, `find`, `captures`, `Matches.next`,
`nextCaptures`, `Splits.next`) returns `SearchError`, for every pattern. Each search's doc says the
error occurs only where the pattern stores rows for that search and the haystack passes the limit.
A caller whose pattern stores nothing writes `catch unreachable` with that reason. There is one
function name per job, with no try-twins.

**Groups inside a positive lookaround** are its first success's, as ECMA-262 says, because
lookaround is atomic. The main automaton writes the last position the path took each one at into
its first group's start slot. That slot is cleared with the enclosing quantifier's groups, as
ECMA-262 clears them. After the match, one anchored run of the body, read its way, gives its groups.
A lookbehind's body is compiled in ECMA-262's backward direction and run on a backward PikeVM. Only
the last taking can define the groups, so each body runs at most once and the work stays O(|r|·n).

**Lazy DFAs.** The lazy DFA finds where a match ends. Streamed lanes are folded into its states
(lanes first in the seeds, so a lane's accept settles before a `check` reads it), and its
transitions are keyed by the byte's class and the **column**: the bits of up to four stored rows.
Past four columns the PikeVM answers (`Cache.Path.pikevm_columns`), and where the DFA quits or gives
up, the PikeVM searches the span. The start and the groups come from the PikeVM over the span cut at
the end. The row scans and `isMatch`'s scan run on lazy DFAs that report every accept, with the
NFA's lanes as their fallback.

The reverse lazy DFA, the backtracker, the one-pass DFA, the prefilters and the stepping automaton
do not run patterns with lookaround.

## Sets and the stepping automaton

**Sets.** `Set.compile` parses and translates each pattern alone, so a refusal names the pattern
(`Diagnostic.pattern`) and its span. It then compiles them into one automaton with one match state
per pattern. `Limits` bound the whole set: `nfa` the automaton, `cache` a `Set.Cache`, and
`pattern` each pattern. As in regex's `RegexSet`, a set has no groups. A caller compiles the
pattern that matched alone to get its captures. Each query is one pass:

- `isMatch`: whether some pattern matches.
- `matches(out)`: every pattern with a match, each pattern's matches taken on their own, into a
  `Set.Patterns` the caller allocates once (`set.patterns(gpa)`). `Patterns.first` and `last`
  give the lowest and highest.
- `first`: the leftmost-first match over the patterns as one alternation in index order, with its
  pattern.

Two lazy DFAs answer a set. One is of the **all** kind: no thread is dropped at a match, and a
state's match is the set of patterns it reached. It serves `matches`, `isMatch` (stopping at the
first match) and whole searches. The other is leftmost-first, for where `first`'s match ends, and
then the PikeVM over the cut span finds its start and pattern. The PikeVM answers wherever a DFA
quits, gives up or is absent. Sets have no prefilter.

A pattern index is `Set.Pattern`, an `aegis.handle.Index(Set, u32)`. Each set takes a process-wide
identity at compile. `Set.Match`, `Set.Cache` and `Set.Patterns` carry that identity, and
`set.pattern(m)`, the searches and `matches` check it in every build. One set's index is never read
against another set.

**The stepping automaton.** `Regex.automaton()` and `Set.automaton()` give an `Automaton`, a view
of the forward lazy DFA of the all kind. It steps one byte at a time, for a caller that walks its
own structure (a trie of terms, the components of a path). It uses the all kind because a walker
asks whether the bytes so far match, and leftmost-first would drop `ab` in `a|ab` after "a". It is
null where the pattern has no such DFA, where the DFA has quit bytes (a step cannot quit), or where
the pattern has lookaround. Its states live in an `Automaton.Cache` of the walker's, sized by
`Limits.lazy_dfa`.

Its calls are `start`, `step`, `stepEnd`, `isMatch`, `isDead` and `patterns`. A match is seen one
byte late, so "the bytes so far match" is `isMatch(stepEnd(state))`, and the walker goes on
stepping from `state`. `isDead` means no further byte leads to a new match, so the walker can prune.

Each `State` carries the store's generation, and a state built before the last clear is refused
with `error.Stale`. This is a returned error, not an invariant, because a branching walker
legitimately holds states across steps that may clear. `error.GaveUp` follows the searches'
give-up rule. `Automaton.zig`'s doc gives the recovery recipe, and the tests drive it. On `Stale`,
re-walk the path from `start` while the re-walks stay within ten times the bytes stepped. Otherwise,
and on `GaveUp`, answer with whole searches (`Input.whole`) and stop pruning. The automaton runs on
the searches' transition code, not on a second DFA.

## Replace and split

`replace` writes the haystack to the caller's writer with each match replaced, and returns how many
matches it replaced. What replaces a match is one parameter, a `Replacement`:

- `.template`: the dialect's `$` syntax (regex's `Captures::expand`, or ECMA-262's
  GetSubstitution), read at each match with no compile step;
- `.literal`: bytes written as they are;
- `.call`: a function given the haystack, the groups and the writer.

`limit` null replaces every match, 0 replaces none, and n replaces the first n. regex's `replacen`
reads 0 as all; spectra deliberately does not. `Regex.expand` is the template step on its own.

`split` iterates the pieces between matches by the dialect's rules. In Rust these are regex's
`split`/`splitn`. In ECMAScript this is ECMA-262's SplitMatcher, with each match's groups among the
pieces (`Piece.text == null` for a group that took no part). spectra finds the split points
leftmost-first rather than trying each position, so the split stays linear.

Matches come as `findAll` gives them. In Rust, an empty match right after the previous match is
passed over, as regex does. In ECMAScript, the next search after an empty match starts one
character on, as a global `exec` does. Every search runs over the whole haystack from a position,
never over a slice, so lookbehinds and `\b` see the text before it. Neither function allocates: the
caller passes the group slice (`captureCount()` long, checked in every build) and owns the writer.

## Bounds

Every limit is checked before what it bounds is allocated. A pattern past a limit is refused, or
loses the engine the limit governs, and never runs slowly. The defaults (`Limits.zig`):

- `pattern` 64 KiB: the pattern's length;
- `nesting` 250: groups, and classes in classes;
- `repetition` 1000: the largest `{n,m}` bound;
- `nfa` 10 MiB: the HIR's sets and the automaton;
- `cache` 32 MiB: everything one `Cache` holds, refused at compile (`cache_too_large`);
- `lazy_dfa` 2 MiB: each lazy DFA's store, within `cache`; too small, and there is no lazy DFA;
- `backtrack` 256 KiB: the backtracker's bits and stack, within `cache`;
- `onepass` 1 MiB: the one-pass table, kept in the `Regex`;
- `prefilter` 1 MiB: a prefilter's table, kept in the `Regex`;
- `oracle` 2 MiB: lookaround's stored rows, within `cache`; past it, the search is refused;
- `dense_dfa` 2 MiB: read by nothing, since spectra has no dense DFA.

Linear time holds because of these limits. The PikeVM and the backtracker visit each (state,
position) at most once. The lazy DFAs give up to the PikeVM when their store churns. The prefilters
only skip. The reverse strategies never rescan.

Iterating every match is linear where each search stops near its match. It is quadratic where a
preferred branch outlives the matches it does not take (`\w+X|\w` over word bytes with no `X`), as
in every leftmost-first engine. `Regex.findAll`'s doc shows the case, and a test counts it.

## CPU dispatch

Only Teddy needs instructions past the baseline: a byte shuffle (SSSE3 or AVX2 on x86-64, and
NEON's TBL, which is AArch64's baseline). `prefilter.teddyKernel` picks the widest kernel at run
time from ladar's answer, and on x86-64 a CPU with neither gets no Teddy. memchr, the rare pair and
Aho-Corasick use 16-byte vectors every baseline has.

Each kernel file holds nothing but its instruction's wrapper, written as inline assembly on vector
registers. Each file is a module built with that feature, so no other code is compiled with
features the CPU may lack. The wrappers use inline assembly, not LLVM intrinsics, so the engine does
not depend on the backend. Teddy's scan is `inline` in `kernels/teddy.zig` and compiled into each
kernel module with that module's instructions.

## Safety

- The pattern is `aegis.input.Untrusted`. Parsing, translation and compiling are bounded by
  `Limits` before allocating.
- A caller's mistake is `aegis.assert.invariant`, checked in every build. Examples: a capture or
  group slice of the wrong length, a cache or a `Set.Patterns` of another set or automaton, or a
  match read against another set.
- A `Regex` or `Set` is immutable and shared by any number of threads. A `Cache` belongs to one
  thread. Each cache keeps the allocator that made it, and its `deinit` takes none.
- NFA state ids are `aegis.handle.Index(Nfa, u32)`.

## Validation

- **regex's suite**: regex 1.13.1's `testdata/*.toml`, vendored in `testdata/regex` and read
  through strand's TOML. Each test runs as regex runs it (is-match, every match, every match's
  captures), once with the lazy DFA and once without, and multi-pattern tests run on a `Set`. What
  spectra does not offer is passed over and counted by reason: earliest searches, overlapping
  searches of a single pattern, leftmost-longest matching, other line terminators, and empty sets.
- **V8's verdicts**: ECMAScript patterns run under Node (`testdata/v8/generate.mjs` and
  `replace.mjs`) and compared span for span, including lookaround patterns, replace and split.
- **RE2's search tests**: the pattern and text table of `re2/testing/search_test.cc`. Each runs in
  Unicode, case-insensitive and bytes modes, over each text and the text with a byte off either
  end, anchored and not, against the test backtracker.
- **test262**: the 52 RegExp test files that write a lookaround, with their expected answers
  transcribed (`src/test262_test.zig`). Backreferences in them are refused by name and still valid
  to `ecmascript.validate`.
- **Oracles**: a bounded backtracker over the automaton (`testing/backtrack.zig`), and ECMA-262's
  matcher written as the specification writes it, lookbehind's backward direction included
  (`testing/ecma.zig`). Every engine, strategy, lookaround row and lookaround search is checked
  against them, or against the PikeVM, on random patterns (`testing/grammar.zig`) and haystacks.
- **Engine agreement**: any bytes as a pattern, in both dialects and with `u`, `v` and bytes
  modes, are either refused with a reason and a span inside the pattern, or give the same answers
  as the PikeVM alone with no prefilter. The prefilters, and Teddy on the kernel the CPU runs, are
  checked against a plain scan.
- **Linear bound**: work is counted, not timed, on the shapes that make backtracking exponential
  (`(a*)*b`, `(a|a)*b`, `(x+x+)+y`, and ECMAScript's empty-check forms). The test checks that
  quadrupling the haystack quadruples the work, and that the work stays within the states times
  the positions.
- **Sets and walks**: a set's `matches` against each pattern alone, `first` against the
  alternation, a walk with `stepEnd` at every prefix against a whole search, and sweep's five set
  queries written on the public API (`sweep_queries_test.zig`).
- **Fuzz**: every property is a `std.testing.fuzz` target. They run seeded in `bay test`, searched
  further by Zig's fuzzer under `bay test --fuzz`, and run with safety on in `bay hardened-fuzz`.
  The release tier also runs the suite under ThreadSanitizer, and runs the Teddy test on the AVX2
  kernel, failing unless that kernel ran.

## Not offered

spectra does not offer leftmost-longest matching, dense DFAs built ahead or written as tables at
build time, streaming search across chunks of a reader, or grapheme clusters (`\X`) and UTS #18
level 2. Backreferences, recursion, conditionals and atomic groups are not regular. Backreferences
are refused by name, and spectra never runs them on an unbounded backtracker.
