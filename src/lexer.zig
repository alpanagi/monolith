const std = @import("std");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    tokens: std.ArrayList(token.Token) = .empty,
    location: token.Location = .{ .row = 1, .column = 1 },

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn deinit(self: *Lexer, allocator: std.mem.Allocator) void {
        self.tokens.deinit(allocator);
    }

    pub fn lex(self: *Lexer, allocator: std.mem.Allocator) LexError!void {
        if (self.peek(0) == ' ') return error.UnexpectedCharacter;
        try self.tokens.append(allocator, .{
            .kind = token.TokenKind{ .indent = 0 },
            .location = self.location,
        });

        const lexers = [_]*const fn (*Lexer, std.mem.Allocator) LexError!bool{
            lexIndentation,
            lexWhitespace,
            lexWord,
            lexSymbols,
        };

        lexing: while (self.offset < self.source.len) {
            for (lexers) |lexer| {
                if (try lexer(self, allocator)) continue :lexing;
            }
            return error.UnexpectedCharacter;
        }

        try self.tokens.append(allocator, .{
            .kind = .eof,
            .location = self.location,
        });
    }

    fn peek(self: *const Lexer, distance: usize) ?u8 {
        if (distance >= self.source.len - self.offset) return null;
        return self.source[self.offset + distance];
    }
};

pub const LexError = error{ OutOfMemory, UnexpectedCharacter };

fn lexIndentation(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] != '\n' and state.source[state.offset] != '\r') return false;
    if (state.source[state.offset] == '\r' and state.peek(1) != '\n') return false;

    state.offset += if (state.source[state.offset] == '\r') 2 else 1;
    state.location.row += 1;
    state.location.column = 1;

    const start = state.offset;
    const location = state.location;
    while (state.offset < state.source.len and state.source[state.offset] == ' ') state.offset += 1;
    const depth = state.offset - start;
    state.location.column += depth;

    try state.tokens.append(allocator, .{
        .kind = token.TokenKind{ .indent = depth },
        .location = location,
    });
    return true;
}

fn lexWhitespace(state: *Lexer, _: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] != ' ') return false;

    const start = state.offset;
    while (state.offset < state.source.len and state.source[state.offset] == ' ') state.offset += 1;
    state.location.column += state.offset - start;
    return true;
}

fn lexWord(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    const first = state.source[state.offset];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    const start = state.offset;
    const location = state.location;
    state.offset += 1;
    while (state.offset < state.source.len) : (state.offset += 1) {
        const byte = state.source[state.offset];
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') break;
    }

    const word = state.source[start..state.offset];
    state.location.column += word.len;

    const keywords = [_]struct { text: []const u8, kind: token.TokenKind }{
        .{ .text = "fn", .kind = .keyword_fn },
        .{ .text = "noop", .kind = .keyword_noop },
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, word, keyword.text)) {
            try state.tokens.append(allocator, .{
                .kind = keyword.kind,
                .location = location,
            });
            return true;
        }
    }

    try state.tokens.append(allocator, .{
        .kind = token.TokenKind{ .identifier = word },
        .location = location,
    });
    return true;
}

fn lexSymbols(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    const kind: token.TokenKind = switch (state.source[state.offset]) {
        ':' => .colon,
        '(' => .left_parenthesis,
        ')' => .right_parenthesis,
        else => return false,
    };

    const location = state.location;
    state.offset += 1;
    state.location.column += 1;
    try state.tokens.append(allocator, .{
        .kind = kind,
        .location = location,
    });
    return true;
}

test "Lexer.lex: lexes a function signature" {
    var lexer = Lexer.init("fn main(): noop");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(8, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .indent);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expect(lexer.tokens.items[2].kind == .identifier);
    try std.testing.expect(lexer.tokens.items[3].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[4].kind == .right_parenthesis);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expect(lexer.tokens.items[6].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[7].kind == .eof);
}

test "Lexer.lex: emits indentation and eof for empty source" {
    var lexer = Lexer.init("");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(2, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expect(lexer.tokens.items[1].kind == .eof);
}

test "Lexer.lex: rejects indentation on the first line" {
    var lexer = Lexer.init("  noop");
    defer lexer.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(std.testing.allocator));
    try std.testing.expectEqual(0, lexer.offset);
}

test "Lexer.lex: tracks row and column of each token" {
    var lexer = Lexer.init("fn main():\n  noop\n");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.tokens.items[1].location);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.tokens.items[7].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, lexer.tokens.items[8].location);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
}

test "Lexer.lex: rejects tab characters" {
    var lexer = Lexer.init("fn main():\n\tnoop\n");
    defer lexer.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(std.testing.allocator));
    try std.testing.expectEqual(11, lexer.offset);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.location);
}

test "Lexer.lex: rejects lone carriage return" {
    var lexer = Lexer.init("\r");
    defer lexer.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(std.testing.allocator));
    try std.testing.expectEqual(0, lexer.offset);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.location);
}

test "Lexer.lex: tracks position on unexpected character" {
    var lexer = Lexer.init("fn main():\r\n  @");
    defer lexer.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(std.testing.allocator));
    try std.testing.expectEqual(14, lexer.offset);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.location);
}

test "lexIndentation: recognizes indented noop body" {
    var lexer = Lexer.init("fn main():\n    noop\n");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(10, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expect(lexer.tokens.items[2].kind == .identifier);
    try std.testing.expect(lexer.tokens.items[3].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[4].kind == .right_parenthesis);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
}

test "lexIndentation: handles carriage return line feed" {
    var lexer = Lexer.init("fn main():\r\n  noop\r\n");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(10, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expect(lexer.tokens.items[2].kind == .identifier);
    try std.testing.expect(lexer.tokens.items[3].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[4].kind == .right_parenthesis);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[6].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
}

test "lexIndentation: recognizes blank line indentation" {
    var lexer = Lexer.init("noop\n\nnoop");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(6, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[2].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[2].kind.indent);
    try std.testing.expect(lexer.tokens.items[3].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[3].kind.indent);
    try std.testing.expect(lexer.tokens.items[4].kind == .keyword_noop);

    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.tokens.items[1].location);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[2].location);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, lexer.tokens.items[3].location);
}

test "lexIndentation: preserves leading spaces per line" {
    var lexer = Lexer.init("fn main():\n    noop\n  noop\n");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(12, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[8].kind.indent);
}

test "lexIndentation: handles pure indentation stream" {
    var lexer = Lexer.init("\n    \n  \n");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expect(lexer.tokens.items[1].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[1].kind.indent);
}

test "lexWord: distinguishes keyword from identifier" {
    var lexer = Lexer.init("fn noop fnx noop2 _fn noop_name");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(8, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expect(lexer.tokens.items[2].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[3].kind == .identifier);
    try std.testing.expectEqualStrings("fnx", lexer.tokens.items[3].kind.identifier);
    try std.testing.expect(lexer.tokens.items[4].kind == .identifier);
    try std.testing.expectEqualStrings("noop2", lexer.tokens.items[4].kind.identifier);
    try std.testing.expect(lexer.tokens.items[5].kind == .identifier);
    try std.testing.expectEqualStrings("_fn", lexer.tokens.items[5].kind.identifier);
    try std.testing.expect(lexer.tokens.items[6].kind == .identifier);
    try std.testing.expectEqualStrings("noop_name", lexer.tokens.items[6].kind.identifier);
    try std.testing.expect(lexer.tokens.items[7].kind == .eof);
}

test "lexWord: rejects leading digit" {
    var lexer = Lexer.init("2fast");
    defer lexer.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(std.testing.allocator));
    try std.testing.expectEqual(0, lexer.offset);
}

test "lexSymbols: lexes adjacent symbols" {
    var lexer = Lexer.init(":(");
    defer lexer.deinit(std.testing.allocator);
    try lexer.lex(std.testing.allocator);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .colon);
    try std.testing.expect(lexer.tokens.items[2].kind == .left_parenthesis);
}
