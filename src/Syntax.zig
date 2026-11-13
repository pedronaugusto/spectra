//! How a pattern is read: its dialect and the flags it starts with.

dialect: Dialect = .rust,
/// Classes and `.` over code points, and Unicode classes and case folding; false: ASCII's.
unicode: bool = true,
case_insensitive: bool = false,
/// `^` and `$` at line ends too.
multi_line: bool = false,
/// `.` takes `\n` too.
dot_matches_new_line: bool = false,
/// Greedy repetitions lazy, and lazy ones greedy.
swap_greed: bool = false,
/// Whitespace and `#` comments in the pattern are ignored.
ignore_whitespace: bool = false,
/// ECMAScript's `v`: class set expressions (`&&`, `--`, nested classes, `\q{...}`) and
/// properties of strings. The ECMAScript dialect only; it reads as `v` whatever `unicode` is.
unicode_sets: bool = false,
/// The haystack is UTF-8 and a match never splits a code point; false: any bytes, `.` takes one.
utf8: bool = true,

pub const Dialect = enum {
    /// Rust regex's syntax (RE2's family).
    rust,
    /// ECMA-262's, for JSON Schema's `pattern`.
    ecmascript,
};
