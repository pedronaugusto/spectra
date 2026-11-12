# Architecture

spectra owns regular expressions: two dialects (Rust regex's and ECMAScript's), compiled to one
automaton and searched by engines whose work is linear in the haystack for every pattern. Its runtime
closure is spectra → aegis, xenoglyph, ladar → std. Nothing takes `std.Io`: compiling allocates from
the caller's allocator under `Limits`, a `Cache` allocates once, and searching allocates nothing.

This describes the implementation in this repository. Change it with the code when an owner, an
invariant or a decision changes. regex-automata (the Rust regex project) is the reference for the
pipeline and the engines; where spectra's code follows it closely the file says so and carries its
notice (`LICENSES/regex-MIT.txt`).

## Layers and owners

[ci/layers.zig](../ci/layers.zig) checks the production import graph. Layers are listed lowest first;
imports stay within a layer or go downward. Paths are under `src/`.

| Layer | Files | Holds |
|---|---|---|
| teddy, kernels | `kernels/teddy.zig`, `kernels/x86_ssse3.zig`, `kernels/x86_avx2.zig`, `kernels/arm_neon.zig` | Teddy's search, and one file per instruction set holding its byte shuffle |
| vocabulary | `Syntax.zig`, `Limits.zig`, `Charged.zig`, `SparseSet.zig` | dialects and flags, limits, a charging allocator, sparse sets |
| syntax | `syntax/Ast.zig`, `syntax/diagnostic.zig`, `syntax/parse.zig`, `syntax/ecma.zig` | the parser for each dialect, ECMA-262 validity, diagnostics |
| hir | `hir/ranges.zig`, `hir/Hir.zig`, `hir/translate.zig`, `hir/literals.zig`, `hir/suffix.zig`, `hir/inner.zig` | range sets, the HIR, translation, literal extraction, the reverse strategies' proofs |
| nfa | `nfa/utf8.zig`, `nfa/Nfa.zig`, `nfa/look.zig`, `nfa/compile.zig` | the Thompson automaton over bytes, forward and reversed; assertions |
| prefilters | `prefilter/rank.zig`, `prefilter.zig` | byte rarity, memchr, the rare pair, Teddy, Aho-Corasick |
| engines | `pikevm.zig`, `lazy.zig`, `backtrack.zig`, `onepass.zig` | each engine |
| meta | `Regex.zig`, `strategy.zig` | the public engine and how each pattern is searched |
| public | `spectra.zig` | public names |

The kernels are build modules of their own, each compiled with the CPU features its instructions need
(`ci/layers.zig` `modules`). Tests live beside the code (`*_test.zig`) and under `testing/`;
shakedown, strand and preflight are lazy test or build dependencies, outside a consumer's closure.

## Pipeline

1. **Parse** (`syntax/`) the pattern of a dialect into an AST whose nodes carry spans, so every error
   names a span of the pattern and a reason. The parser is iterative with an explicit stack, bounded
   by `Limits.nesting`.
2. **Translate** (`hir/translate.zig`) to the HIR: classes become sorted ranges of code points (or
   bytes, with `utf8 = false`), case-insensitivity becomes closure under simple case folding, and
   Unicode properties become their ranges, all from xenoglyph. Set operations on classes happen here.
3. **Extract literals** (`hir/literals.zig`): the prefixes every match starts with, the suffixes every
   match ends with, and the prefixes of each part of the top concatenation, for the prefilters and the
   reverse strategies.
4. **Compile** (`nfa/compile.zig`) the HIR to a Thompson NFA over bytes. UTF-8 classes become byte
   automata with shared suffixes; assertions (`^ $ \A \z`, line anchors, word boundaries, half
   boundaries) are states that `nfa/look.zig` tests against the whole haystack. The reversed automaton
   is compiled from the same HIR read backwards, without captures; it decides only which strings
   match, so a repetition takes the same shape in either dialect there. ECMAScript's rule that an iteration past its minimum
   that matched empty fails is compiled as empty checks on the loop's states (`Nfa.loop_checks`).
5. **Choose** (`strategy.zig`, `Regex.compile`) the engines the pattern has and the strategy that
   searches it, once, from what the automata and the literals say.

Translation charges its sets and the compiler its automaton to `Limits.nfa` through `Charged`, so a
pattern that would pass it is refused with `error.TooLarge` before the memory is held, not after.

## Engines

- **PikeVM** (`pikevm.zig`): every thread in lockstep, one step per byte, captures in slots. Always
  present. O(m·n) for m states and n bytes.
- **Lazy DFA** (`lazy.zig`): states built on demand from sets of NFA states into a store of fixed size
  (`Limits.lazy_dfa`) in the `Cache`, cleared when full and never grown; the state being left survives
  the clear. After three clears, a search that read fewer than ten bytes per state built since the last
  clear gives up (`error.GaveUp`), and the PikeVM searches the span instead. Bytes the DFA cannot decide
  alone (past 0x7f where a Unicode word boundary is asserted) are quit bytes (`error.Quit`), with the
  same fallback. A forward DFA finds where the leftmost-first match ends.
- **Reverse lazy DFA**: the same engine over the reversed automaton, reading back from a match's end to
  its start, so `find` needs no PikeVM.
- **Bounded backtracker** (`backtrack.zig`): depth first in the alternatives' order, each (state,
  position) visited once by a bitset, so linear by construction. Three quarters of `Limits.backtrack`
  are its bits, which bounds the spans it takes; a quarter is its stack, and a search that outgrows
  either is the PikeVM's.
- **One-pass DFA** (`onepass.zig`): for patterns where at most one thread is alive at each byte, a
  table that writes captures as it goes, built at compile under `Limits.onepass`. It runs over the
  match the lazy DFAs found.
- **Prefilters** (`prefilter.zig`): memchr for the one to three bytes every literal starts with; for a
  single literal, a search on its two rarest bytes (`prefilter/rank.zig`) confirmed by the whole
  literal; Teddy for up to 64 literals where the CPU has the byte shuffle; Aho-Corasick otherwise, a
  DFA over the literals' byte classes under `Limits.prefilter`.

Which engines a pattern has is `Regex.engines`; which answered the last search is in
`Cache.last`, `Cache.last_start` and `Cache.last_slots`, which the tests read to count every path.

## Strategies

A strategy is chosen once per pattern; each falls back to `core` (and `core` to the PikeVM) on a quit,
a give-up, or a guard, so no strategy can make a search slower than linear.

- **pikevm**: no lazy DFA (its fewest states do not fit the store).
- **core**: the lazy DFA finds the end, the reverse lazy DFA the start, and captures come from the
  one-pass DFA, the backtracker or the PikeVM over the match alone. A prefilter, where the pattern's
  prefixes give one, skips to where a match may start.
- **reverse_anchored**: every match ends at the haystack's end and the pattern is not anchored at its
  start: the reverse lazy DFA reads back from the end, and nothing reads forward.
- **literal**: every match is one literal the prefilter confirms whole, and the pattern asserts
  nothing: the prefilter alone answers.
- **reverse_suffix**: every match ends with one literal L and the pattern has no prefilter of its own.
  The prefilter finds L, the reverse DFA reads back to the earliest start of a match ending there (s),
  and the forward DFA, anchored at s, finds the end.
- **reverse_inner**: the top concatenation splits as P·X where every match of X starts with one of a
  few literals. The prefilter finds one, P's reverse DFA reads back to s, and a forward search from s
  confirms or not.

**When the reverse strategies may lead.** Taken plainly, reverse suffix is wrong: in
`[0-9a-q][^x]*zz|bz` on `abzz` the first `z` gives `bz` at 1 and the answer [1,4], where the
leftmost-first match is [0,4] (pinned in the tests). Each strategy is right exactly where no match
starts before s, and the danger is a match that starts before s and runs past the occurrence. spectra
takes a reverse strategy only where one of these closes it; the arguments are written out at the head
of `hir/suffix.zig` and `hir/inner.zig`, and the code follows them:

- the part before the literal has a fixed length, so no match starts earlier and ends later;
- (one literal only) some byte of the literal is read by no part before it, so an occurrence inside an
  earlier match, or running into its literal at a shift, is impossible;
- the last reading part before the literal is a class read at least once that shares nothing with the
  literal or any other part, so an earlier match's run of it would cross the occurrence;
- the first reading part is such a class, so an earlier match's run followed by the rest of the match
  at s would be a match starting before s, against s being the earliest.

Neither strategy reads a byte twice: a reverse scan never reads back past the previous occurrence
(`error.Quadratic`), and reverse inner stops where an occurrence falls before the last forward scan's
end; both hand the search to `core` there.

## Bounds

Every limit is checked before what it bounds is allocated, and a pattern past one is refused, or loses
the engine the limit governs, never runs slowly.

| Limit | Default | Bounds |
|---|---|---|
| `pattern` | 64 KiB | the pattern's length |
| `nesting` | 250 | groups, and classes in classes |
| `repetition` | 1000 | the largest `{n,m}` bound |
| `nfa` | 10 MiB | the HIR's sets and the automaton |
| `cache` | 32 MiB | everything one `Cache` holds |
| `lazy_dfa` | 2 MiB | each lazy DFA's store, within `cache` |
| `backtrack` | 256 KiB | the backtracker's bits and stack, within `cache` |
| `onepass` | 1 MiB | the one-pass table, in the `Regex` |
| `prefilter` | 1 MiB | a prefilter's table, in the `Regex` |

Linear time holds by these: the PikeVM and the backtracker visit each (state, position) at most once,
the lazy DFAs give up to the PikeVM when their store churns, the prefilters only skip, and the reverse
strategies never rescan.

## Refused by name

What cannot be searched in linear time, or is not built yet, is refused at compile with
`error.Unsupported`, a reason and the construct's span: backreferences, a lookaround in a `Set`, and
the ECMAScript forms spectra does not run.

## Lookaround

ECMAScript's lookarounds run by the oracle method of Barrière and Pit-Claudel (PLDI 2024, §4.3 and
§4.4; `oracle.zig`). A lookaround's truth at a position depends on the position alone, so a `check`
state that reads it keeps the uniform futures every linear engine relies on. Each lookaround's **row**,
its truth at every position, is built by a scan that writes every accept and never stops: forward over
`.*?body` for a lookbehind, backward over `.*?rev(body)` for a lookahead, on strings-only automata.
A lookaround read the same way as the scan that queries it is **streamed**, its automaton a lane in
lockstep with that scan; one read the other way is **stored**, built first, innermost first. `find`,
`captures` and `findAll` store every row the main expression queries and run the PikeVM over the main
automaton; `isMatch` scans the strings-only main expression the way that streams most of its
lookarounds (all of zod's patterns read backward and store nothing). Stored rows take a bit per
position each, within `Limits.oracle`; a haystack past it is refused before a byte is read
(`error.HaystackTooLong`, `Regex.longestHaystack`). A positive lookaround's groups are rebuilt after
the match: the main automaton writes the last position the path took each one at into its first
group's start slot (cleared with the enclosing quantifier's groups, as ECMA-262 clears them), and one
anchored run of its body, read its way (a lookbehind's compiled in ECMA-262's backward direction),
gives its first success's groups; an outer lookaround's run sets its inner ones'. The lazy DFAs, the
backtracker, the one-pass DFA and the literal strategies do not run such patterns yet. `ecmascript.validate` reads the whole ECMA-262 grammar, these included, and
says whether a pattern is valid whether or not spectra runs it.

## CPU dispatch

Kernels that need more than the target's baseline are chosen at run time from
[ladar](https://github.com/pedronaugusto/ladar)'s answer: Teddy's shuffle needs SSSE3 or AVX2 on x86-64
(NEON is AArch64's baseline). A feature the target guarantees is chosen at compile time. Each kernel
file holds nothing but its instruction's wrapper, inline assembly on vector registers, in a module built
with that feature, so no other code is compiled with features the CPU may lack. memchr, the rare pair
and Aho-Corasick need only the baseline.

## Safety

- The pattern is `aegis.input.Untrusted`; parsing, translation and compiling are bounded by `Limits`
  before allocating.
- A caller's mistake (a capture slice of the wrong length) is `aegis.assert.invariant`, checked in
  every build.
- A `Regex` is immutable and shared by any number of threads; a `Cache` belongs to one.

## Validation

- **regex's suite**: regex 1.13.1's `testdata/*.toml`, vendored and read through strand's TOML, run as
  regex runs it (is-match, every match, every match's captures), each test with the lazy DFA and again
  without it; what spectra does not offer (sets, overlapping and earliest searches, leftmost-longest,
  other line terminators) is passed over and counted by reason.
- **V8's verdicts**: ECMAScript patterns run under Node (`testdata/v8`), compared span for span.
- **Oracles**: a bounded backtracker over the automaton (`testing/backtrack.zig`) and ECMA-262's
  matcher semantics written as the specification writes them (`testing/ecma.zig`), against which every
  engine and strategy is checked on random patterns and haystacks.
- **Engine agreement**: every engine against the PikeVM alone on whatever the meta engine could choose,
  with the prefilter on and off, so each path is reached and counted.
- **Fuzz**: each parser on arbitrary bytes in every dialect and flag set, and compile plus search on
  fuzzed pattern and haystack pairs, as std.testing.fuzz targets: seeded in `bay test`, searched further by Zig's fuzzer under
  `bay test --fuzz`, and with safety on in `bay hardened-fuzz`.

## Not built yet

Lookaround on the lazy DFAs, leftmost-longest matching,
replacement and split, the dense DFA (`Limits.dense_dfa` is reserved for it) and the build step that
writes dense DFAs as a Zig module. Until then each is absent, and a pattern that needs one is refused
by name.
