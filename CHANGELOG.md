# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The Rust dialect's parser: a pattern into an `Ast` whose every node carries its span, groups and nested classes read
  with explicit stacks bounded by `Limits.nesting`, every count and code point checked before use, the pattern taken
  as `aegis.input.Untrusted`.
