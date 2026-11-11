# spectra

spectra is regular expressions for Zig in linear time, for every pattern and every input, guaranteed rather than
hoped: a lazy DFA to search, an NFA for captures, Unicode classes from xenoglyph, and nothing that backtracks without
a bound. It reads Rust regex's syntax and an ECMAScript dialect with lookahead for JSON Schema's `pattern`, searches
bytes or UTF-8, matches sets of patterns in one pass, and compiles patterns known at build time to tables, with no
compiler in the binary. What isn't regular (backreferences, lookbehind) is refused by name at compile, never run
slowly.

## Status

Under construction, in stages, each landed whole. In: the Rust dialect's parser and the ECMAScript dialect with its
validity check, the HIR with Unicode classes, the Thompson NFA, and the engines under the public `Regex` (is-match,
find, captures, every match in turn): the PikeVM, the lazy DFA forward and reversed with a fixed cache and a give-up
rule, the bounded backtracker and the one-pass DFA for captures, and a meta engine that picks how they are put
together, every engine's work counted linear in the tests. The ECMAScript dialect matches what V8 matches, spans and
captures, on every case of its verdicts but three where V8 reads UTF-16 code units. Checked against regex's own test
suite, V8's verdicts, ECMA-262's semantics as written, and a backtracker over the automaton. To come: the prefilters,
lookahead by derivatives, then sets, dense DFAs and the build step. Nothing is released until every stage is in.

## License

MIT.

src/hir/suffix.zig and src/hir/inner.zig include code translated from the Rust regex project (MIT OR Apache-2.0); see LICENSES/.
