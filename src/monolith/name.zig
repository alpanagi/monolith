const std = @import("std");
const core = @import("core");
const token = core.token;

pub const keywords = std.StaticStringMap(token.TokenKind).initComptime(.{
    .{ "fn", .keyword_fn },
    .{ "external", .keyword_external },
    .{ "const", .keyword_const },
    .{ "struct", .keyword_struct },
    .{ "noop", .keyword_noop },
    .{ "return", .keyword_return },
    .{ "true", .keyword_true },
    .{ "false", .keyword_false },
    .{ "_", .underscore },
});

pub fn isName(word: []const u8) bool {
    if (word.len == 0 or !isWordStart(word[0])) return false;
    for (word[1..]) |byte| {
        if (!isWordCharacter(byte)) return false;
    }
    return !keywords.has(word);
}

pub fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

pub fn isWordCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "isName: accepts a name" {
    try std.testing.expect(isName("hello_world2"));
    try std.testing.expect(isName("_hidden"));
}

test "isName: rejects keywords and the discard symbol" {
    try std.testing.expect(!isName("const"));
    try std.testing.expect(!isName("_"));
}

test "isName: rejects words that are not names" {
    try std.testing.expect(!isName(""));
    try std.testing.expect(!isName("2fast"));
    try std.testing.expect(!isName("my-module"));
    try std.testing.expect(!isName("my module"));
}
