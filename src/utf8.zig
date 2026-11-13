//! One UTF-8 sequence's code point. std's `utf8Decode` takes a slice of any length and is
//! deprecated for it; here the length is the sequence's, which the caller measured.
const std = @import("std");

/// Why a sequence is no code point: a byte that should continue it does not, an overlong or
/// surrogate encoding, a value past U+10FFFF, or a length no sequence has.
pub const DecodeError = error{
    Utf8ExpectedContinuation,
    Utf8OverlongEncoding,
    Utf8EncodesSurrogateHalf,
    Utf8CodepointTooLarge,
    Utf8InvalidLength,
};

/// The code point the one sequence `bytes` encodes, its length the lead byte's.
pub fn decode(bytes: []const u8) DecodeError!u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => error.Utf8InvalidLength,
    };
}

test "a sequence decodes to its code point, and a broken one is refused" {
    try std.testing.expectEqual(@as(u21, 'a'), try decode("a"));
    try std.testing.expectEqual(@as(u21, 0xE9), try decode("\xC3\xA9"));
    try std.testing.expectEqual(@as(u21, 0x20AC), try decode("\xE2\x82\xAC"));
    try std.testing.expectEqual(@as(u21, 0x1F600), try decode("\xF0\x9F\x98\x80"));
    try std.testing.expectError(error.Utf8OverlongEncoding, decode("\xC0\x80"));
    try std.testing.expectError(error.Utf8InvalidLength, decode(""));
}
