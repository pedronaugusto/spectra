# spectra

spectra is regular expressions for Zig in linear time, for every pattern and every input, guaranteed rather than hoped:
a lazy DFA to search, an NFA for captures, Unicode classes from xenoglyph, and no backtracking engine at all. It reads
Rust regex's syntax and an ECMAScript dialect with lookahead for JSON Schema's `pattern`, searches bytes or UTF-8,
matches sets of patterns in one pass, and compiles patterns known at build time to tables, with no compiler in the
binary. What isn't regular (backreferences, lookbehind) is refused by name at compile, never run slowly.

## Status

Under construction, in stages, each landed whole. In: the Rust dialect's parser and the ECMAScript dialect with its
validity check, the HIR with Unicode classes, the Thompson NFA, and the PikeVM with its linear bound tested under the
public `Regex` (is-match, find, captures, every match in turn), checked against regex's own test suite and V8's
verdicts. To come: the lazy and reverse DFAs with the meta engine, the prefilters, lookahead by derivatives, then
sets, dense DFAs and the build step. Nothing is released until every stage is in.

Known difference from V8, to be closed before any release: in the ECMAScript dialect, where a quantified group can
match the empty string (`(a*)*`, `(|a)+`, `(a*)?`), ECMA-262 fails an iteration that matched empty and spectra does
not yet, so `find` and `captures` can differ from V8 there (`(|a)+` on `a` is `0..1` in V8, `0..0` here). Whether a
pattern matches is the same.

## License

MIT.
