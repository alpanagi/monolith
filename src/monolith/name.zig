const std = @import("std");
const core = @import("core");
const token = core.token;

pub const keywords = std.StaticStringMap(token.TokenKind).initComptime(.{
    .{ "fn", .keyword_fn },
    .{ "external", .keyword_external },
    .{ "const", .keyword_const },
    .{ "many", .keyword_many },
    .{ "var", .keyword_var },
    .{ "struct", .keyword_struct },
    .{ "typeclass", .keyword_typeclass },
    .{ "instance", .keyword_instance },
    .{ "for", .keyword_for },
    .{ "in", .keyword_in },
    .{ "import", .keyword_import },
    .{ "as", .keyword_as },
    .{ "noop", .keyword_noop },
    .{ "return", .keyword_return },
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "while", .keyword_while },
    .{ "break", .keyword_break },
    .{ "continue", .keyword_continue },
    .{ "and", .keyword_and },
    .{ "or", .keyword_or },
    .{ "orelse", .keyword_orelse },
    .{ "true", .keyword_true },
    .{ "false", .keyword_false },
    .{ "undefined", .keyword_undefined },
    .{ "null", .keyword_null },
    .{ "comptime", .keyword_comptime },
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
    try std.testing.expect(!isName("var"));
    try std.testing.expect(!isName("undefined"));
    try std.testing.expect(!isName("if"));
    try std.testing.expect(!isName("else"));
    try std.testing.expect(!isName("break"));
    try std.testing.expect(!isName("continue"));
    try std.testing.expect(!isName("as"));
    try std.testing.expect(!isName("in"));
    try std.testing.expect(!isName("_"));
}

test "isName: rejects words that are not names" {
    try std.testing.expect(!isName(""));
    try std.testing.expect(!isName("2fast"));
    try std.testing.expect(!isName("my-module"));
    try std.testing.expect(!isName("my module"));
}
