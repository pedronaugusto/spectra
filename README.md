# spectra

spectra is regular expressions for Zig in linear time, for every pattern and every input, guaranteed rather than hoped:
a lazy DFA to search, an NFA for captures, Unicode classes from xenoglyph, and no backtracking engine at all. It reads
Rust regex's syntax and an ECMAScript dialect with lookahead for JSON Schema's `pattern`, searches bytes or UTF-8,
matches sets of patterns in one pass, and compiles patterns known at build time to tables, with no compiler in the
binary. What isn't regular (backreferences, lookbehind) is refused by name at compile, never run slowly.

## Status

Under construction, in stages, each landed whole: the Rust dialect's parser (this stage), the ECMAScript dialect and
its validity check, the HIR with Unicode classes, the Thompson NFA, the PikeVM with its linear bound tested, the lazy
and reverse DFAs with the meta engine, the prefilters, lookahead by derivatives, then sets, dense DFAs and the build
step. Nothing is released until every stage is in.

## License

MIT.
