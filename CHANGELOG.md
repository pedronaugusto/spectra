# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The Rust dialect's parser: a pattern into an `Ast` whose every node carries its span, groups and nested classes read
  with explicit stacks bounded by `Limits.nesting`, every count and code point checked before use, the pattern taken
  as `aegis.input.Untrusted`.
- The ECMAScript dialect (`Syntax.dialect = .ecmascript`, `u` by `Syntax.unicode`, `v` by `Syntax.unicode_sets`):
  ECMA-262's pattern grammar with modifiers, duplicate group names in separate alternatives and `v`'s class set
  expressions and `\q{...}` strings; Annex B's grammar without `u` or `v`. Lookarounds and backreferences are read into
  the `Ast` (`lookaround`, `backreference`), to be refused at translation where spectra cannot run them.
- `ecmascript.validate(gpa, pattern, flags, limits, diagnostic)`: whether a pattern is valid ECMA-262 whatever spectra
  runs; `\p{...}` held to ECMA-262's tables exactly, by xenoglyph's names.
