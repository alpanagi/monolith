const std = @import("std");
const core = @import("core");
const name = @import("name.zig");
const token = core.token;
const types = core.types;

const Failure = core.Failure;

pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    tokens: std.ArrayList(token.Token) = .empty,
    location: token.Location = .{ .row = 1, .column = 1 },
    nesting: usize = 0,
    failure: ?Failure = null,

    pub fn init(source: []const u8) Lexer {
        const byte_order_mark = "\xEF\xBB\xBF";
        if (std.mem.startsWith(u8, source, byte_order_mark)) {
            return .{ .source = source[byte_order_mark.len..] };
        }
        return .{ .source = source };
    }

    pub fn lex(self: *Lexer, arena: *std.heap.ArenaAllocator) LexError!void {
        const allocator = arena.allocator();

        var position = self.offset;
        while (self.peek(position) == ' ') position += 1;
        if (self.startsCode(position)) {
            if (position != self.offset) return self.fail(self.offset, error.UnexpectedCharacter);
            try self.tokens.append(allocator, .{
                .kind = token.TokenKind{ .indent = 0 },
                .location = self.location,
            });
        }

        const lexers = [_]*const fn (*Lexer, std.mem.Allocator) LexError!bool{
            lexIndentation,
            lexWhitespace,
            lexComment,
            lexWord,
            lexNumber,
            lexString,
            lexCharacter,
            lexSymbols,
        };

        lexing: while (self.offset < self.source.len) {
            for (lexers) |lexer| if (try lexer(self, allocator)) continue :lexing;

            if (self.source[self.offset] == '\t') {
                return self.fail(self.offset, error.UnexpectedTab);
            }
            return self.failUnexpected(self.offset);
        }

        try self.tokens.append(allocator, .{
            .kind = .eof,
            .location = self.location,
        });
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        if (offset >= self.source.len) return null;
        return self.source[offset];
    }

    fn startsCode(self: *const Lexer, offset: usize) bool {
        const byte = self.peek(offset) orelse return false;
        return byte != '\n' and byte != '\r' and byte != '#';
    }

    fn fail(self: *Lexer, offset: usize, lex_error: LexError) LexError {
        const column = self.location.column + offset - self.offset;
        self.failure = .{
            .location = .{ .row = self.location.row, .column = column },
            .message = describeError(lex_error),
        };
        return lex_error;
    }

    fn failUnexpected(self: *Lexer, offset: usize) LexError {
        const byte = self.peek(offset) orelse 0;
        if (byte < 0x80) return self.fail(offset, error.UnexpectedCharacter);
        const length = measureCodePoint(self.source, offset) orelse {
            return self.fail(offset, error.InvalidCharacter);
        };
        if (isDirectionControl(self.source[offset..][0..length])) {
            return self.fail(offset, error.UnexpectedDirectionControl);
        }
        return self.fail(offset, error.UnexpectedCharacter);
    }
};

pub const LexError = error{
    OutOfMemory,
    UnexpectedCharacter,
    InvalidCharacter,
    UnexpectedTab,
    UnexpectedTabInString,
    UnexpectedTabInCharacter,
    UnexpectedDirectionControl,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidScalarValue,
    UnterminatedString,
    UnterminatedCharacter,
    NotOneCharacter,
    PrefixedFloat,
};

fn describeError(lex_error: LexError) []const u8 {
    return switch (lex_error) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedCharacter => "unexpected character",
        error.InvalidCharacter => "invalid UTF-8",
        error.UnexpectedTab => "tabs are not allowed, use spaces",
        error.UnexpectedTabInString => "tabs are not allowed in strings, use \\t",
        error.UnexpectedTabInCharacter => "tabs are not allowed in characters, use \\t",
        error.UnexpectedDirectionControl => "Unicode direction control characters are not allowed",
        error.InvalidEscape => "unknown escape sequence",
        error.InvalidUnicodeEscape => "a Unicode escape takes one to six hexadecimal digits in braces",
        error.InvalidScalarValue => "a Unicode escape must be a Unicode scalar value",
        error.UnterminatedString => "unterminated string",
        error.UnterminatedCharacter => "unterminated character",
        error.NotOneCharacter => "a character literal holds exactly one character",
        error.PrefixedFloat => "a float cannot have a base prefix",
    };
}

fn lexIndentation(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    var position = state.offset;
    const first = state.source[position];
    if (first != '\n' and first != '\r') return false;
    if (first == '\r' and state.peek(position + 1) != '\n') return false;

    position += if (first == '\r') 2 else 1;
    const start = position;
    while (state.peek(position) == ' ') position += 1;
    const depth = position - start;
    const row = state.location.row + 1;

    if (state.nesting == 0 and state.startsCode(position)) {
        try state.tokens.append(allocator, .{
            .kind = token.TokenKind{ .indent = depth },
            .location = .{ .row = row, .column = 1 },
        });
    }
    state.location = .{ .row = row, .column = 1 + depth };
    state.offset = position;
    return true;
}

fn lexWhitespace(state: *Lexer, _: std.mem.Allocator) LexError!bool {
    var position = state.offset;
    if (state.source[position] != ' ') return false;

    while (state.peek(position) == ' ') position += 1;
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexComment(state: *Lexer, _: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] != '#') return false;

    var position = state.offset + 1;
    while (state.peek(position)) |byte| {
        if (byte == '\n' or byte == '\r') break;
        if (byte == '\t') return state.fail(position, error.UnexpectedTab);
        if (byte >= 0x80) {
            try consumeCodePoint(state, &position);
        } else {
            position += 1;
        }
    }
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexWord(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (!name.isWordStart(state.source[state.offset])) return false;

    var position = state.offset + 1;
    while (state.peek(position)) |byte| {
        if (!name.isWordCharacter(byte)) break;
        position += 1;
    }
    const word = state.source[state.offset..position];

    const kind = name.keywords.get(word) orelse token.TokenKind{ .identifier = word };

    try state.tokens.append(allocator, .{
        .kind = kind,
        .location = state.location,
    });
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexNumber(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (!isDigit(state.peek(state.offset), 10)) return false;

    var position = state.offset;
    var base: u8 = 10;
    if (state.source[position] == '0') {
        const next = state.peek(position + 1);
        if (isDigit(next, 10) or next == '_') {
            return state.fail(position + 1, error.UnexpectedCharacter);
        }
        base = switch (next orelse ' ') {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 10,
        };
    }
    if (base != 10) position += 2;
    try consumeDigits(state, &position, base);

    var is_float = false;
    if (base == 10 and state.peek(position) == '.' and isDigit(state.peek(position + 1), 10)) {
        position += 1;
        is_float = true;
        try consumeDigits(state, &position, 10);
    }
    if (base == 10 and (state.peek(position) == 'e' or state.peek(position) == 'E')) {
        position += 1;
        if (state.peek(position) == '+' or state.peek(position) == '-') position += 1;
        try consumeDigits(state, &position, 10);
        is_float = true;
    }
    const text = state.source[state.offset..position];

    const after_separator = state.peek(position + 1) orelse ' ';
    if (state.peek(position) == '_' and std.ascii.isAlphabetic(after_separator)) position += 1;
    const suffix = consumeSuffix(state, &position);
    if (state.peek(position)) |next| {
        if (std.ascii.isAlphanumeric(next) or next == '_') {
            return state.fail(position, error.UnexpectedCharacter);
        }
    }
    if (isFloatSuffix(suffix)) {
        if (base != 10) return state.fail(state.offset, error.PrefixedFloat);
        is_float = true;
    }

    const literal = token.NumberLiteral{ .text = text, .suffix = suffix };
    try state.tokens.append(allocator, .{
        .kind = if (is_float) .{ .float_literal = literal } else .{ .integer_literal = literal },
        .location = state.location,
    });
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexString(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] != '"') return false;

    var position = state.offset + 1;
    while (true) {
        const byte = state.peek(position) orelse {
            return state.fail(state.offset, error.UnterminatedString);
        };
        switch (byte) {
            '"' => break,
            '\\' => switch (state.peek(position + 1) orelse 0) {
                'n', 't', 'r', '0', '\\', '\'', '"' => position += 2,
                'u' => try consumeUnicodeEscape(state, &position),
                '\n', '\r', 0 => return state.fail(state.offset, error.UnterminatedString),
                '\t' => return state.fail(position + 1, error.UnexpectedTabInString),
                0x80...0xFF => {
                    var escaped = position + 1;
                    try consumeCodePoint(state, &escaped);
                    return state.fail(position, error.InvalidEscape);
                },
                else => return state.fail(position, error.InvalidEscape),
            },
            '\n', '\r' => return state.fail(state.offset, error.UnterminatedString),
            '\t' => return state.fail(position, error.UnexpectedTabInString),
            0x80...0xFF => try consumeCodePoint(state, &position),
            else => position += 1,
        }
    }
    const text = state.source[state.offset + 1 .. position];
    position += 1;

    try state.tokens.append(allocator, .{
        .kind = .{ .string_literal = text },
        .location = state.location,
    });
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexCharacter(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] != '\'') return false;

    var position = state.offset + 1;
    const first = state.peek(position) orelse {
        return state.fail(state.offset, error.UnterminatedCharacter);
    };
    switch (first) {
        '\'' => return state.fail(state.offset, error.NotOneCharacter),
        '\\' => switch (state.peek(position + 1) orelse 0) {
            'n', 't', 'r', '0', '\\', '\'', '"' => position += 2,
            'u' => try consumeUnicodeEscape(state, &position),
            '\n', '\r', 0 => return state.fail(state.offset, error.UnterminatedCharacter),
            '\t' => return state.fail(position + 1, error.UnexpectedTabInCharacter),
            0x80...0xFF => {
                var escaped = position + 1;
                try consumeCodePoint(state, &escaped);
                return state.fail(position, error.InvalidEscape);
            },
            else => return state.fail(position, error.InvalidEscape),
        },
        '\n', '\r' => return state.fail(state.offset, error.UnterminatedCharacter),
        '\t' => return state.fail(position, error.UnexpectedTabInCharacter),
        0x80...0xFF => try consumeCodePoint(state, &position),
        else => position += 1,
    }
    if (state.peek(position) != '\'') {
        while (state.peek(position)) |byte| {
            if (byte == '\'') return state.fail(state.offset, error.NotOneCharacter);
            if (byte == '\n' or byte == '\r') break;
            if (byte >= 0x80) {
                try consumeCodePoint(state, &position);
            } else {
                position += 1;
            }
        }
        return state.fail(state.offset, error.UnterminatedCharacter);
    }
    const text = state.source[state.offset + 1 .. position];
    position += 1;

    try state.tokens.append(allocator, .{
        .kind = .{ .character_literal = text },
        .location = state.location,
    });
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexSymbols(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    if (state.source[state.offset] == ':' and state.peek(state.offset + 1) == ':') {
        try state.tokens.append(allocator, .{
            .kind = .double_colon,
            .location = state.location,
        });
        state.location.column += 2;
        state.offset += 2;
        return true;
    }
    if (state.source[state.offset] == '.' and state.peek(state.offset + 1) == '.') {
        try state.tokens.append(allocator, .{
            .kind = .dot_dot,
            .location = state.location,
        });
        state.location.column += 2;
        state.offset += 2;
        return true;
    }
    if (state.source[state.offset] == '-' and state.peek(state.offset + 1) == '>') {
        try state.tokens.append(allocator, .{
            .kind = .arrow,
            .location = state.location,
        });
        state.location.column += 2;
        state.offset += 2;
        return true;
    }
    const kind: token.TokenKind = switch (state.source[state.offset]) {
        ':' => .colon,
        '(' => .left_parenthesis,
        ')' => .right_parenthesis,
        '[' => .left_bracket,
        ']' => .right_bracket,
        '{' => .left_brace,
        '}' => .right_brace,
        ',' => .comma,
        '.' => .dot,
        '=' => .equals,
        '-' => .minus,
        '*' => .asterisk,
        '?' => .question_mark,
        else => return false,
    };
    switch (kind) {
        .left_parenthesis, .left_bracket, .left_brace => state.nesting += 1,
        .right_parenthesis, .right_bracket, .right_brace => state.nesting -|= 1,
        else => {},
    }

    try state.tokens.append(allocator, .{
        .kind = kind,
        .location = state.location,
    });
    state.location.column += 1;
    state.offset += 1;
    return true;
}

fn isDigit(byte: ?u8, base: u8) bool {
    const digit = byte orelse return false;
    _ = std.fmt.charToDigit(digit, base) catch return false;
    return true;
}

fn consumeDigits(state: *Lexer, offset: *usize, base: u8) LexError!void {
    if (!isDigit(state.peek(offset.*), base)) {
        return state.failUnexpected(offset.*);
    }
    offset.* += 1;
    while (true) {
        if (isDigit(state.peek(offset.*), base)) {
            offset.* += 1;
        } else if (state.peek(offset.*) == '_' and isDigit(state.peek(offset.* + 1), base)) {
            offset.* += 2;
        } else {
            return;
        }
    }
}

fn consumeSuffix(state: *Lexer, offset: *usize) ?[]const u8 {
    const first = state.peek(offset.*) orelse return null;
    if (!std.ascii.isAlphabetic(first)) return null;
    const start = offset.*;
    while (state.peek(offset.*)) |byte| {
        if (!name.isWordCharacter(byte)) break;
        offset.* += 1;
    }
    return state.source[start..offset.*];
}

fn isFloatSuffix(suffix: ?[]const u8) bool {
    const text = suffix orelse return false;
    const number = types.findNumberType(text) orelse return false;
    return switch (number) {
        .f16, .f32, .f64, .f128 => true,
        else => false,
    };
}

fn consumeUnicodeEscape(state: *Lexer, offset: *usize) LexError!void {
    const start = offset.*;
    if (state.peek(start + 2) != '{') return state.fail(start, error.InvalidUnicodeEscape);
    var position = start + 3;
    while (isDigit(state.peek(position), 16)) position += 1;
    const digits = state.source[start + 3 .. position];
    if (digits.len == 0 or digits.len > 6 or state.peek(position) != '}') {
        return state.fail(start, error.InvalidUnicodeEscape);
    }
    const value = std.fmt.parseInt(u24, digits, 16) catch unreachable;
    if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) {
        return state.fail(start, error.InvalidScalarValue);
    }
    offset.* = position + 1;
}

fn consumeCodePoint(state: *Lexer, offset: *usize) LexError!void {
    const length = measureCodePoint(state.source, offset.*) orelse {
        return state.fail(offset.*, error.InvalidCharacter);
    };
    if (isDirectionControl(state.source[offset.*..][0..length])) {
        return state.fail(offset.*, error.UnexpectedDirectionControl);
    }
    offset.* += length;
}

fn measureCodePoint(source: []const u8, offset: usize) ?usize {
    const length = std.unicode.utf8ByteSequenceLength(source[offset]) catch return null;
    const end = offset + length;
    if (end > source.len) return null;
    _ = std.unicode.utf8Decode(source[offset..end]) catch return null;
    return length;
}

fn isDirectionControl(sequence: []const u8) bool {
    const code_point = std.unicode.utf8Decode(sequence) catch unreachable;
    return (code_point >= 0x202A and code_point <= 0x202E) or (code_point >= 0x2066 and code_point <= 0x2069);
}

test "Lexer.init: skips a byte order mark at the start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\xEF\xBB\xBFfn main(): noop");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.tokens.items[1].location);
}

test "Lexer.lex: lexes a function signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main(): noop");
    try lexer.lex(&arena);

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

test "Lexer.lex: emits only eof for empty source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("");
    try lexer.lex(&arena);

    try std.testing.expectEqual(1, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .eof);
}

test "Lexer.lex: leaves out a blank first line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("  \nnoop");
    try lexer.lex(&arena);

    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[0].location);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_noop);
}

test "Lexer.lex: leaves out a first line that holds only a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("# note\nnoop");
    try lexer.lex(&arena);

    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[0].location);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_noop);
}

test "Lexer.lex: rejects indentation on the first line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("  noop");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "Lexer.lex: tracks row and column of each token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n  noop\n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.tokens.items[1].location);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.tokens.items[7].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, lexer.tokens.items[8].location);
    try std.testing.expect(lexer.tokens.items[8].kind == .eof);
}

test "Lexer.lex: rejects lone carriage return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\r");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "Lexer.lex: tracks position on unexpected character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\r\n  @");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.failure.?.location.?);
}

test "Lexer.lex: rejects an invalid byte outside a comment or string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn \x80");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "Lexer.lex: rejects a valid character that is not allowed there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn \xc3\xa9");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
}

test "Lexer.lex: rejects a direction control character outside a comment or string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop \u{202E}");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, lexer.failure.?.location.?);
}

test "Lexer.lex: rejects tab characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n\tnoop\n");

    try std.testing.expectError(error.UnexpectedTab, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.failure.?.location.?);
}

test "lexIndentation: handles carriage return line feed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\r\n  noop\r\n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(9, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_fn);
    try std.testing.expect(lexer.tokens.items[2].kind == .identifier);
    try std.testing.expect(lexer.tokens.items[3].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[4].kind == .right_parenthesis);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[6].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .eof);
}

test "lexIndentation: leaves out blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n\n    \r\n    noop\n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(9, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .eof);
}

test "lexIndentation: rejects a lone carriage return after the indentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop\n  \rnoop");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.failure.?.location.?);
}

test "lexIndentation: preserves leading spaces per line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n    noop\n  noop\n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(11, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[8].kind.indent);
}

test "lexIndentation: ignores line breaks inside brackets and parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("f(x[\n    ..\n])\nx");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[2].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[4].kind == .left_bracket);
    try std.testing.expect(lexer.tokens.items[5].kind == .dot_dot);
    try std.testing.expect(lexer.tokens.items[6].kind == .right_bracket);
    try std.testing.expect(lexer.tokens.items[7].kind == .right_parenthesis);
    try std.testing.expectEqual(0, lexer.tokens.items[8].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, lexer.tokens.items[5].location);
}

test "lexIndentation: ignores line breaks inside braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("f({\n    1,\n    2,\n})\nx");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[2].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[3].kind == .left_brace);
    try std.testing.expect(lexer.tokens.items[4].kind == .integer_literal);
    try std.testing.expect(lexer.tokens.items[5].kind == .comma);
    try std.testing.expect(lexer.tokens.items[6].kind == .integer_literal);
    try std.testing.expect(lexer.tokens.items[7].kind == .comma);
    try std.testing.expect(lexer.tokens.items[8].kind == .right_brace);
    try std.testing.expect(lexer.tokens.items[9].kind == .right_parenthesis);
    try std.testing.expectEqual(0, lexer.tokens.items[10].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, lexer.tokens.items[6].location);
}

test "lexIndentation: leaves out a line that holds only a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n    # first\n# second\n    noop");
    try lexer.lex(&arena);

    try std.testing.expectEqual(9, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[5].kind == .colon);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 1 }, lexer.tokens.items[6].location);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
}

test "lexComment: ends a comment at the end of the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop # done\r\nnoop");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_noop);
    try std.testing.expectEqual(0, lexer.tokens.items[2].kind.indent);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.tokens.items[2].location);
    try std.testing.expect(lexer.tokens.items[3].kind == .keyword_noop);
}

test "lexComment: keeps any character other than a line end or a tab in a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop #a\x01\xc3\xa9\"\nnoop");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[3].kind == .keyword_noop);
}

test "lexComment: rejects a carriage return on its own in a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop # a\rb");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, lexer.failure.?.location.?);
}

test "lexComment: rejects an invalid byte in a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop # a\xffb");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, lexer.failure.?.location.?);
}

test "lexComment: rejects a tab in a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop # a\tb");

    try std.testing.expectError(error.UnexpectedTab, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, lexer.failure.?.location.?);
}

test "lexComment: rejects a direction control character in a comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("# a\u{2066}b");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "lexWord: distinguishes keyword from identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn noop fnx noop2 _fn noop_name i32x");
    try lexer.lex(&arena);

    try std.testing.expectEqual(9, lexer.tokens.items.len);
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
    try std.testing.expect(lexer.tokens.items[7].kind == .identifier);
    try std.testing.expectEqualStrings("i32x", lexer.tokens.items[7].kind.identifier);
    try std.testing.expect(lexer.tokens.items[8].kind == .eof);
}

test "lexWord: recognizes the external keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("external fn");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_external);
    try std.testing.expect(lexer.tokens.items[2].kind == .keyword_fn);
}

test "lexWord: recognizes the const keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("const constant");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_const);
    try std.testing.expectEqualStrings("constant", lexer.tokens.items[2].kind.identifier);
}

test "lexWord: recognizes the many keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("many manyfold");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_many);
    try std.testing.expectEqualStrings("manyfold", lexer.tokens.items[2].kind.identifier);
}

test "lexWord: recognizes the struct keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("struct structure");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_struct);
    try std.testing.expectEqualStrings("structure", lexer.tokens.items[2].kind.identifier);
}

test "lexWord: recognizes return and boolean keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return true false");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_return);
    try std.testing.expect(lexer.tokens.items[2].kind == .keyword_true);
    try std.testing.expect(lexer.tokens.items[3].kind == .keyword_false);
}

test "lexWord: recognizes the null keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("null nullable");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .keyword_null);
    try std.testing.expectEqualStrings("nullable", lexer.tokens.items[2].kind.identifier);
}

test "lexWord: recognizes a lone underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("_ _value");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .underscore);
    try std.testing.expect(lexer.tokens.items[2].kind == .identifier);
    try std.testing.expectEqualStrings("_value", lexer.tokens.items[2].kind.identifier);
}

test "lexWord: lexes type names as identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("i32 bool string");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("i32", lexer.tokens.items[1].kind.identifier);
    try std.testing.expectEqualStrings("bool", lexer.tokens.items[2].kind.identifier);
    try std.testing.expectEqualStrings("string", lexer.tokens.items[3].kind.identifier);
}

test "lexNumber: lexes an integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return 42");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[2].kind == .integer_literal);
    try std.testing.expectEqualStrings("42", lexer.tokens.items[2].kind.integer_literal.text);
    try std.testing.expectEqual(null, lexer.tokens.items[2].kind.integer_literal.suffix);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.tokens.items[2].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, lexer.tokens.items[3].location);
}

test "lexNumber: keeps separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1_000_000");
    try lexer.lex(&arena);

    try std.testing.expectEqual(3, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer_literal);
    try std.testing.expectEqualStrings("1_000_000", lexer.tokens.items[1].kind.integer_literal.text);
}

test "lexNumber: lexes base prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0xff_FF 0b1010_0000 0o755");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer_literal);
    try std.testing.expectEqualStrings("0xff_FF", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .integer_literal);
    try std.testing.expectEqualStrings("0b1010_0000", lexer.tokens.items[2].kind.integer_literal.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .integer_literal);
    try std.testing.expectEqualStrings("0o755", lexer.tokens.items[3].kind.integer_literal.text);
}

test "lexNumber: lexes float literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5.0 1e10 2.5e-3 3E+2 0.5");
    try lexer.lex(&arena);

    try std.testing.expectEqual(7, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .float_literal);
    try std.testing.expectEqualStrings("5.0", lexer.tokens.items[1].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .float_literal);
    try std.testing.expectEqualStrings("1e10", lexer.tokens.items[2].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .float_literal);
    try std.testing.expectEqualStrings("2.5e-3", lexer.tokens.items[3].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[4].kind == .float_literal);
    try std.testing.expectEqualStrings("3E+2", lexer.tokens.items[4].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[5].kind == .float_literal);
    try std.testing.expectEqualStrings("0.5", lexer.tokens.items[5].kind.float_literal.text);
}

test "lexNumber: lexes type suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5u8 1_000_u32 2.5f32 1.0_f64");
    try lexer.lex(&arena);

    try std.testing.expectEqual(6, lexer.tokens.items.len);
    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expectEqualStrings("u8", lexer.tokens.items[1].kind.integer_literal.suffix.?);
    try std.testing.expectEqualStrings("1_000", lexer.tokens.items[2].kind.integer_literal.text);
    try std.testing.expectEqualStrings("u32", lexer.tokens.items[2].kind.integer_literal.suffix.?);
    try std.testing.expectEqualStrings("2.5", lexer.tokens.items[3].kind.float_literal.text);
    try std.testing.expectEqualStrings("f32", lexer.tokens.items[3].kind.float_literal.suffix.?);
    try std.testing.expectEqualStrings("1.0", lexer.tokens.items[4].kind.float_literal.text);
    try std.testing.expectEqualStrings("f64", lexer.tokens.items[4].kind.float_literal.suffix.?);
}

test "lexNumber: reads a float suffix as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5f32 1_000_f128 5u8 5x32");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .float_literal);
    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .float_literal);
    try std.testing.expectEqualStrings("1_000", lexer.tokens.items[2].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .integer_literal);
    try std.testing.expect(lexer.tokens.items[4].kind == .integer_literal);
}

test "lexNumber: rejects a float suffix after a binary prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("x 0b1f32");

    try std.testing.expectError(error.PrefixedFloat, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects a float suffix after an octal prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0o7_f64");

    try std.testing.expectError(error.PrefixedFloat, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexNumber: reads a float suffix after a hexadecimal prefix as digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0x5f32");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .integer_literal);
    try std.testing.expectEqualStrings("0x5f32", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expectEqual(null, lexer.tokens.items[1].kind.integer_literal.suffix);
}

test "lexNumber: does not read a point followed by a letter as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5.a");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .dot);
    try std.testing.expectEqualStrings("a", lexer.tokens.items[3].kind.identifier);
}

test "lexNumber: does not read a point without a digit after it as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5. ");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .dot);
}

test "lexNumber: accepts a zero on its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0");
    try lexer.lex(&arena);

    try std.testing.expectEqual(3, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer_literal);
    try std.testing.expectEqualStrings("0", lexer.tokens.items[1].kind.integer_literal.text);
}

test "lexNumber: rejects leading zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("007");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects separator after leading zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0_1");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexNumber: keeps any word after the digits as the suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("2fast 5Bool");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("2", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expectEqualStrings("fast", lexer.tokens.items[1].kind.integer_literal.suffix.?);
    try std.testing.expectEqualStrings("Bool", lexer.tokens.items[2].kind.integer_literal.suffix.?);
}

test "lexNumber: rejects trailing separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1_");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects double separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1__0");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects prefix without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0x");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects an invalid byte where a digit is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0x\xff");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects digit outside the base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0b102");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 5 }, lexer.failure.?.location.?);
}

test "lexNumber: rejects exponent without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1e");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexNumber: leaves the position untouched on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("12__x");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
    try std.testing.expectEqual(0, lexer.offset);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.location);
}

test "lexString: lexes a string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return \"hello\"");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expectEqualStrings("hello", lexer.tokens.items[2].kind.string_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.tokens.items[2].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, lexer.tokens.items[3].location);
}

test "lexString: keeps escapes as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\nb\\tc\\\\d\\\"e\\'f\\rg\\0h\"");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("a\\nb\\tc\\\\d\\\"e\\'f\\rg\\0h", lexer.tokens.items[1].kind.string_literal);
}

test "lexString: rejects an unknown escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\qb\"");

    try std.testing.expectError(error.InvalidEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexString: rejects an invalid byte after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\\xffb\"");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "lexString: rejects a tab after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\\tb\"");

    try std.testing.expectError(error.UnexpectedTabInString, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "lexString: rejects a direction control character after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\\u{202E}\"");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexString: rejects a string without a closing quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return \"hello");

    try std.testing.expectError(error.UnterminatedString, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.failure.?.location.?);
}

test "lexString: rejects a backslash at the end of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"abc\\");

    try std.testing.expectError(error.UnterminatedString, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexString: rejects a line break inside a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"hello\nworld\"");

    try std.testing.expectError(error.UnterminatedString, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexString: keeps any other character as text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"ab\x01c\xc3\xa9\" x");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("ab\x01c\xc3\xa9", lexer.tokens.items[1].kind.string_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, lexer.tokens.items[2].location);
}

test "lexString: rejects a tab in a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"ab\tc\"");

    try std.testing.expectError(error.UnexpectedTabInString, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "lexString: rejects an invalid byte in a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"ab\xff\"");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "lexString: rejects a direction control character in a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\u{202A}\"");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexString: keeps a number sign as text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a # b\"");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("a # b", lexer.tokens.items[1].kind.string_literal);
}

test "lexString: keeps the braces of a unicode escape out of the nesting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("{\"\\u{41}\", '\\u{42}'}\nx");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("\\u{41}", lexer.tokens.items[2].kind.string_literal);
    try std.testing.expectEqualStrings("\\u{42}", lexer.tokens.items[4].kind.character_literal);
    try std.testing.expect(lexer.tokens.items[5].kind == .right_brace);
    try std.testing.expectEqual(0, lexer.tokens.items[6].kind.indent);
}

test "lexCharacter: lexes a character literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return 'a'");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expectEqualStrings("a", lexer.tokens.items[2].kind.character_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.tokens.items[2].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, lexer.tokens.items[3].location);
}

test "lexCharacter: keeps escapes as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\'' '\\\"' '\\r' '\\0'");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("\\'", lexer.tokens.items[1].kind.character_literal);
    try std.testing.expectEqualStrings("\\\"", lexer.tokens.items[2].kind.character_literal);
    try std.testing.expectEqualStrings("\\r", lexer.tokens.items[3].kind.character_literal);
    try std.testing.expectEqualStrings("\\0", lexer.tokens.items[4].kind.character_literal);
}

test "lexCharacter: keeps a unicode escape as one character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\u{1F600}'");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("\\u{1F600}", lexer.tokens.items[1].kind.character_literal);
}

test "lexCharacter: keeps a character of several bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\xc3\xa9' x");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("\xc3\xa9", lexer.tokens.items[1].kind.character_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, lexer.tokens.items[2].location);
}

test "lexCharacter: rejects an empty character literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("''");

    try std.testing.expectError(error.NotOneCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects more than one character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'ab'");

    try std.testing.expectError(error.NotOneCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a character without a closing quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return 'a");

    try std.testing.expectError(error.UnterminatedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a quote at the end of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'");

    try std.testing.expectError(error.UnterminatedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a line break inside a character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\n'");

    try std.testing.expectError(error.UnterminatedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects an unknown escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\q'");

    try std.testing.expectError(error.InvalidEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects an invalid byte after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\\xff'");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a tab after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\\t'");

    try std.testing.expectError(error.UnexpectedTabInCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a direction control character after a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\\\u{202C}'");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a tab in a character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\t'");

    try std.testing.expectError(error.UnexpectedTabInCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects an invalid byte in a character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\xff'");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a direction control character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'\u{2069}'");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "lexCharacter: rejects a direction control character after the first character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("'a\u{202E}'");

    try std.testing.expectError(error.UnexpectedDirectionControl, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?.location.?);
}

test "lexSymbols: lexes adjacent symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init(":(,.=)");
    try lexer.lex(&arena);

    try std.testing.expectEqual(8, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .colon);
    try std.testing.expect(lexer.tokens.items[2].kind == .left_parenthesis);
    try std.testing.expect(lexer.tokens.items[3].kind == .comma);
    try std.testing.expect(lexer.tokens.items[4].kind == .dot);
    try std.testing.expect(lexer.tokens.items[5].kind == .equals);
    try std.testing.expect(lexer.tokens.items[6].kind == .right_parenthesis);
}

test "lexSymbols: lexes two colons as one symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("std::stdout:");
    try lexer.lex(&arena);

    try std.testing.expectEqual(6, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[2].kind == .double_colon);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.tokens.items[2].location);
    try std.testing.expectEqualStrings("stdout", lexer.tokens.items[3].kind.identifier);
    try std.testing.expect(lexer.tokens.items[4].kind == .colon);
}

test "lexSymbols: lexes brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("[]");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .left_bracket);
    try std.testing.expect(lexer.tokens.items[2].kind == .right_bracket);
}

test "lexSymbols: lexes braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("{}");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .left_brace);
    try std.testing.expect(lexer.tokens.items[2].kind == .right_brace);
}

test "lexSymbols: lexes two dots as one symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("[..]");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[2].kind == .dot_dot);
    try std.testing.expect(lexer.tokens.items[3].kind == .right_bracket);
}

test "lexSymbols: lexes a dash and a greater-than sign as one symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init(") -> i32");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[2].kind == .arrow);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.tokens.items[2].location);
    try std.testing.expectEqualStrings("i32", lexer.tokens.items[3].kind.identifier);
}

test "lexSymbols: lexes a dash without a greater-than sign as a minus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init(") - i32");
    try lexer.lex(&arena);

    try std.testing.expectEqual(token.TokenKind.minus, lexer.tokens.items[2].kind);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.tokens.items[2].location);
}

test "lexSymbols: lexes an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("*bool");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .asterisk);
    try std.testing.expectEqualStrings("bool", lexer.tokens.items[2].kind.identifier);
}

test "lexSymbols: lexes a question mark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("??i32");
    try lexer.lex(&arena);

    try std.testing.expect(lexer.tokens.items[1].kind == .question_mark);
    try std.testing.expect(lexer.tokens.items[2].kind == .question_mark);
    try std.testing.expectEqualStrings("i32", lexer.tokens.items[3].kind.identifier);
}

test "consumeUnicodeEscape: keeps a unicode escape as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\u{1F600}b\"");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("a\\u{1F600}b", lexer.tokens.items[1].kind.string_literal);
}

test "consumeUnicodeEscape: accepts the largest scalar value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{10FFFF}\"");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("\\u{10FFFF}", lexer.tokens.items[1].kind.string_literal);
}

test "consumeUnicodeEscape: rejects a unicode escape without braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u41\"");

    try std.testing.expectError(error.InvalidUnicodeEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects a unicode escape without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{}\"");

    try std.testing.expectError(error.InvalidUnicodeEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects more than six digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{0000041}\"");

    try std.testing.expectError(error.InvalidUnicodeEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects an underscore between digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{1F_600}\"");

    try std.testing.expectError(error.InvalidUnicodeEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects a unicode escape without a closing brace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{41\"");

    try std.testing.expectError(error.InvalidUnicodeEscape, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects a value above the largest scalar value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{110000}\"");

    try std.testing.expectError(error.InvalidScalarValue, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "consumeUnicodeEscape: rejects a surrogate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"\\u{D800}\"");

    try std.testing.expectError(error.InvalidScalarValue, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?.location.?);
}

test "measureCodePoint: rejects a sequence cut off by the end of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("# a\xc3");

    try std.testing.expectError(error.InvalidCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?.location.?);
}

test "isDirectionControl: covers exactly the two ranges" {
    try std.testing.expect(!isDirectionControl("\u{2029}"));
    try std.testing.expect(isDirectionControl("\u{202A}"));
    try std.testing.expect(isDirectionControl("\u{202E}"));
    try std.testing.expect(!isDirectionControl("\u{202F}"));
    try std.testing.expect(!isDirectionControl("\u{2065}"));
    try std.testing.expect(isDirectionControl("\u{2066}"));
    try std.testing.expect(isDirectionControl("\u{2069}"));
    try std.testing.expect(!isDirectionControl("\u{206A}"));
}
