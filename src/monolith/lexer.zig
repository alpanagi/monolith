const std = @import("std");
const core = @import("core");
const name = @import("name.zig");
const token = core.token;

const Failure = core.Failure;

pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    tokens: std.ArrayList(token.Token) = .empty,
    location: token.Location = .{ .row = 1, .column = 1 },
    failure: ?Failure = null,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn lex(self: *Lexer, arena: *std.heap.ArenaAllocator) LexError!void {
        const allocator = arena.allocator();

        if (self.peek(self.offset) == ' ') {
            return self.fail(self.offset, error.UnexpectedCharacter);
        }

        try self.tokens.append(allocator, .{
            .kind = token.TokenKind{ .indent = 0 },
            .location = self.location,
        });

        const lexers = [_]*const fn (*Lexer, std.mem.Allocator) LexError!bool{
            lexIndentation,
            lexWhitespace,
            lexWord,
            lexNumber,
            lexString,
            lexSymbols,
        };

        lexing: while (self.offset < self.source.len) {
            for (lexers) |lexer| if (try lexer(self, allocator)) continue :lexing;

            if (self.source[self.offset] == '\t') {
                return self.fail(self.offset, error.UnexpectedTab);
            }
            return self.fail(self.offset, error.UnexpectedCharacter);
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

    fn fail(self: *Lexer, offset: usize, lex_error: LexError) LexError {
        const column = self.location.column + offset - self.offset;
        self.failure = .{
            .location = .{ .row = self.location.row, .column = column },
            .message = describeError(lex_error),
        };
        return lex_error;
    }
};

pub const LexError = error{
    OutOfMemory,
    UnexpectedCharacter,
    UnexpectedTab,
    InvalidEscape,
    UnterminatedString,
};

fn describeError(lex_error: LexError) []const u8 {
    return switch (lex_error) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedCharacter => "unexpected character",
        error.UnexpectedTab => "tabs are not allowed, use spaces",
        error.InvalidEscape => "unknown escape sequence",
        error.UnterminatedString => "unterminated string",
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

    try state.tokens.append(allocator, .{
        .kind = token.TokenKind{ .indent = depth },
        .location = .{ .row = row, .column = 1 },
    });
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
    if (base == 10 and state.peek(position) == '.') {
        const after_point = state.peek(position + 1) orelse ' ';
        if (after_point != '.' and after_point != '_' and !std.ascii.isAlphabetic(after_point)) {
            position += 1;
            is_float = true;
            if (isDigit(state.peek(position), 10)) try consumeDigits(state, &position, 10);
        }
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
                'n', 't', '\\', '"' => position += 2,
                '\n', '\r', 0 => return state.fail(state.offset, error.UnterminatedString),
                else => return state.fail(position, error.InvalidEscape),
            },
            '\n', '\r' => return state.fail(state.offset, error.UnterminatedString),
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
    const kind: token.TokenKind = switch (state.source[state.offset]) {
        ':' => .colon,
        '(' => .left_parenthesis,
        ')' => .right_parenthesis,
        ',' => .comma,
        '.' => .dot,
        '=' => .equals,
        else => return false,
    };

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
        return state.fail(offset.*, error.UnexpectedCharacter);
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

test "Lexer.lex: emits indentation and eof for empty source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("");
    try lexer.lex(&arena);

    try std.testing.expectEqual(2, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expect(lexer.tokens.items[1].kind == .eof);
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
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("noop\n\nnoop");
    try lexer.lex(&arena);

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n    noop\n  noop\n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(12, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[6].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[6].kind.indent);
    try std.testing.expect(lexer.tokens.items[7].kind == .keyword_noop);
    try std.testing.expect(lexer.tokens.items[8].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[8].kind.indent);
}

test "lexIndentation: handles pure indentation stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\n    \n  \n");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[0].kind == .indent);
    try std.testing.expectEqual(0, lexer.tokens.items[0].kind.indent);
    try std.testing.expect(lexer.tokens.items[1].kind == .indent);
    try std.testing.expectEqual(4, lexer.tokens.items[1].kind.indent);
    try std.testing.expect(lexer.tokens.items[2].kind == .indent);
    try std.testing.expectEqual(2, lexer.tokens.items[2].kind.indent);
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
    var lexer = Lexer.init("i32 Bool String");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("i32", lexer.tokens.items[1].kind.identifier);
    try std.testing.expectEqualStrings("Bool", lexer.tokens.items[2].kind.identifier);
    try std.testing.expectEqualStrings("String", lexer.tokens.items[3].kind.identifier);
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
    var lexer = Lexer.init("5. 5.0 1e10 2.5e-3 3E+2 0.5");
    try lexer.lex(&arena);

    try std.testing.expectEqual(8, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .float_literal);
    try std.testing.expectEqualStrings("5.", lexer.tokens.items[1].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .float_literal);
    try std.testing.expectEqualStrings("5.0", lexer.tokens.items[2].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .float_literal);
    try std.testing.expectEqualStrings("1e10", lexer.tokens.items[3].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[4].kind == .float_literal);
    try std.testing.expectEqualStrings("2.5e-3", lexer.tokens.items[4].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[5].kind == .float_literal);
    try std.testing.expectEqualStrings("3E+2", lexer.tokens.items[5].kind.float_literal.text);
    try std.testing.expect(lexer.tokens.items[6].kind == .float_literal);
    try std.testing.expectEqualStrings("0.5", lexer.tokens.items[6].kind.float_literal.text);
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

test "lexNumber: does not read a point followed by a letter as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5.a");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.integer_literal.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .dot);
    try std.testing.expectEqualStrings("a", lexer.tokens.items[3].kind.identifier);
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
    var lexer = Lexer.init("\"a\\nb\\tc\\\\d\\\"e\"");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("a\\nb\\tc\\\\d\\\"e", lexer.tokens.items[1].kind.string_literal);
}

test "lexString: rejects an unknown escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\\qb\"");

    try std.testing.expectError(error.InvalidEscape, lexer.lex(&arena));
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

test "lexString: keeps any other byte as text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\"a\tb\x01c\xc3\xa9\xff\" x");
    try lexer.lex(&arena);

    try std.testing.expectEqualStrings("a\tb\x01c\xc3\xa9\xff", lexer.tokens.items[1].kind.string_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, lexer.tokens.items[2].location);
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
