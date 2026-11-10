//! Why a pattern was refused, and where: what every dialect's parser reports.
const Ast = @import("Ast.zig");

pub const Error = error{ OutOfMemory, Invalid, TooLarge };

/// Why a pattern was refused, and where.
pub const Diagnostic = struct {
    span: Ast.Span = .{ .start = 0, .end = 0 },
    reason: Reason = .none,
};

pub const Reason = enum {
    none,
    pattern_too_long,
    nesting_too_deep,
    invalid_utf8,
    unclosed_group,
    unopened_group,
    unclosed_class,
    empty_class,
    class_range_out_of_order,
    class_range_bad_end,
    repetition_missing,
    repetition_count_invalid,
    repetition_count_too_large,
    repetition_count_out_of_order,
    escape_unexpected_end,
    escape_unrecognized,
    escape_hex_invalid,
    code_point_invalid,
    assertion_in_class,
    unicode_class_invalid,
    flag_unrecognized,
    flag_repeated,
    flag_dangling_negation,
    flags_empty,
    group_name_invalid,
    group_name_duplicate,
    ascii_class_invalid,
    /// A `Syntax` flag the dialect has no meaning for: `ignore_whitespace` or `swap_greed` in
    /// the ECMAScript dialect, `unicode_sets` in the Rust one.
    syntax_not_in_dialect,
    /// ECMAScript under `u` or `v`: `]`, `{` or `}` alone.
    lone_syntax_character,
    /// ECMAScript: `(?` before what opens no group.
    group_opening_invalid,
    /// ECMAScript: `\N` past the groups under `u` or `v`, or `\k<name>` naming none.
    backreference_undefined,
    /// ECMAScript: `\k` without its `<name>` where the pattern names groups.
    named_reference_invalid,
    /// ECMAScript under `v`: a class mixing a union, `&&` and `--`, or a range as an operand.
    class_set_operation_mixed,
    /// ECMAScript under `v`: an operator without an operand on a side.
    class_set_operand_missing,
    /// ECMAScript under `v`: a syntax character or a reserved double punctuator unescaped.
    class_set_character_reserved,
    /// ECMAScript under `v`: a class that may hold strings, negated.
    class_strings_negated,
    /// ECMAScript: `\p{...}` naming no property or value of ECMA-262's tables.
    unicode_property_unknown,
    /// Rust without `u`: a Unicode class, or a non-ASCII character in a class of bytes.
    unicode_not_allowed,
    /// Rust without `u`, matching UTF-8: what could match a byte past ASCII alone.
    invalid_utf8_class,
    /// ECMAScript constructs spectra refuses to run, by name.
    unsupported_backreference,
    unsupported_lookbehind,
    unsupported_nested_lookaround,
    /// A property with no data here: Age and the break properties, and `v`'s properties of strings.
    unsupported_unicode_property,
    /// ECMAScript without `u` or `v`: half of a code point past U+FFFF named alone. A UTF-16
    /// engine matches half a character; a UTF-8 haystack has no halves.
    unsupported_code_unit_split,
    /// The pattern's classes, or the sets made on the way to them, past `Limits.nfa`: each range
    /// a class holds is at least one transition of the automaton it becomes.
    nfa_too_large,
    /// `ecmascript.validate`'s flags: one not of `dgimsuvy`, one given twice, or `u` with `v`.
    regexp_flag_invalid,
};
