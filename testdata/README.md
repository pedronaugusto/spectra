# spectra's test data

- `regex/`: regex's own engine-independent test suite, the files regex 1.13.1 loads in its
  `tests/lib.rs` (its `testdata/`, from github.com/rust-lang/regex at tag 1.13.1, unchanged),
  under regex's licenses (`regex/LICENSE-MIT`, `regex/LICENSE-APACHE`). Run by
  `src/regex_suite_test.zig` through the Rust dialect.
- `v8/`: V8's verdicts on ECMAScript patterns, `matches.json`, written by `generate.mjs` under
  Node (the version is in the file). Run by `src/ecma_verdicts_test.zig`.

Neither is part of the package: the development build embeds them in the tests.
