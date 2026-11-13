//! What each assertion tests at a position of the haystack, regex-automata's `LookMatcher` for
//! Rust's and ECMA-262's for its own. An assertion sees the whole haystack, whatever span is
//! searched: `^` holds at the haystack's start, not the span's.
//!
//! Unicode word characters are regex-syntax's `\w`: Alphabetic, the marks, decimal numbers,
//! connector punctuation and Join_Control. Bytes that do not decode are no word character. `\B`
//! and the half boundaries with Unicode never hold inside an encoding or beside bytes that do
//! not decode, so an empty match there never splits a code point; `\b` needs a word character
//! on one side, which is a whole one.
const std = @import("std");
const utf8 = @import("../utf8.zig");
const xenoglyph = @import("xenoglyph");
const Look = @import("../Hir.zig").Look;

pub fn holds(look: Look, haystack: []const u8, at: usize) bool {
    return switch (look) {
        .start_text => at == 0,
        .end_text => at == haystack.len,
        .start_line_lf => at == 0 or haystack[at - 1] == '\n',
        .end_line_lf => at == haystack.len or haystack[at] == '\n',
        .start_line_crlf => at == 0 or haystack[at - 1] == '\n' or
            (haystack[at - 1] == '\r' and (at >= haystack.len or haystack[at] != '\n')),
        .end_line_crlf => at == haystack.len or haystack[at] == '\r' or
            (haystack[at] == '\n' and (at == 0 or haystack[at - 1] != '\r')),
        .start_line_ecma => at == 0 or ecmaTerminatorBefore(haystack, at),
        .end_line_ecma => at == haystack.len or ecmaTerminatorAfter(haystack, at),
        .word_ascii => asciiWordBefore(haystack, at) != asciiWordAfter(haystack, at),
        .not_word_ascii => asciiWordBefore(haystack, at) == asciiWordAfter(haystack, at),
        .word_unicode => unicodeWordBefore(haystack, at) != unicodeWordAfter(haystack, at),
        .not_word_unicode => decodesBefore(haystack, at) and decodesAfter(haystack, at) and
            unicodeWordBefore(haystack, at) == unicodeWordAfter(haystack, at),
        .word_ecma_folded => ecmaWordBefore(haystack, at) != ecmaWordAfter(haystack, at),
        .not_word_ecma_folded => ecmaWordBefore(haystack, at) == ecmaWordAfter(haystack, at),
        .word_start_ascii => !asciiWordBefore(haystack, at) and asciiWordAfter(haystack, at),
        .word_end_ascii => asciiWordBefore(haystack, at) and !asciiWordAfter(haystack, at),
        .word_start_unicode => !unicodeWordBefore(haystack, at) and unicodeWordAfter(haystack, at),
        .word_end_unicode => unicodeWordBefore(haystack, at) and !unicodeWordAfter(haystack, at),
        .word_start_half_ascii => !asciiWordBefore(haystack, at),
        .word_end_half_ascii => !asciiWordAfter(haystack, at),
        .word_start_half_unicode => decodesBefore(haystack, at) and !unicodeWordBefore(haystack, at),
        .word_end_half_unicode => decodesAfter(haystack, at) and !unicodeWordAfter(haystack, at),
    };
}

/// regex-syntax's Unicode `\w`.
pub fn isWordChar(cp: u21) bool {
    if (cp < 0x80) return isWordByte(@intCast(cp));
    if (cp == 0x200c or cp == 0x200d) return true;
    if (xenoglyph.properties.core(cp).alphabetic) return true;
    return switch (xenoglyph.properties.generalCategory(cp)) {
        .nonspacing_mark, .spacing_mark, .enclosing_mark, .decimal_number, .connector_punctuation => true,
        else => false,
    };
}

pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn asciiWordBefore(haystack: []const u8, at: usize) bool {
    return at > 0 and isWordByte(haystack[at - 1]);
}

fn asciiWordAfter(haystack: []const u8, at: usize) bool {
    return at < haystack.len and isWordByte(haystack[at]);
}

/// The code point that ends at `at`, if the bytes before it decode as one.
pub fn decodeBefore(haystack: []const u8, at: usize) ?u21 {
    if (at == 0) return null;
    var start = at - 1;
    const floor = at -| 4;
    while (start > floor and haystack[start] & 0xc0 == 0x80) start -= 1;
    const n = std.unicode.utf8ByteSequenceLength(haystack[start]) catch return null;
    if (start + n != at) return null;
    return utf8.decode(haystack[start..at]) catch null;
}

/// The code point that starts at `at`, if the bytes there decode as one.
pub fn decodeAfter(haystack: []const u8, at: usize) ?u21 {
    if (at >= haystack.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(haystack[at]) catch return null;
    if (at + n > haystack.len) return null;
    return utf8.decode(haystack[at..][0..n]) catch null;
}

fn decodesBefore(haystack: []const u8, at: usize) bool {
    return at == 0 or decodeBefore(haystack, at) != null;
}

fn decodesAfter(haystack: []const u8, at: usize) bool {
    return at == haystack.len or decodeAfter(haystack, at) != null;
}

fn unicodeWordBefore(haystack: []const u8, at: usize) bool {
    const cp = decodeBefore(haystack, at) orelse return false;
    return isWordChar(cp);
}

fn unicodeWordAfter(haystack: []const u8, at: usize) bool {
    const cp = decodeAfter(haystack, at) orelse return false;
    return isWordChar(cp);
}

/// ECMA-262's WordCharacters under `u` or `v` with `i`: `[0-9A-Za-z_]`, U+017F and U+212A.
fn isEcmaFoldedWord(cp: u21) bool {
    return (cp < 0x80 and isWordByte(@intCast(cp))) or cp == 0x17f or cp == 0x212a;
}

fn ecmaWordBefore(haystack: []const u8, at: usize) bool {
    const cp = decodeBefore(haystack, at) orelse return false;
    return isEcmaFoldedWord(cp);
}

fn ecmaWordAfter(haystack: []const u8, at: usize) bool {
    const cp = decodeAfter(haystack, at) orelse return false;
    return isEcmaFoldedWord(cp);
}

/// ECMA-262's LineTerminator: `\n`, `\r`, U+2028 and U+2029.
fn isEcmaTerminator(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

fn ecmaTerminatorBefore(haystack: []const u8, at: usize) bool {
    const cp = decodeBefore(haystack, at) orelse return false;
    return isEcmaTerminator(cp);
}

fn ecmaTerminatorAfter(haystack: []const u8, at: usize) bool {
    const cp = decodeAfter(haystack, at) orelse return false;
    return isEcmaTerminator(cp);
}
