const std = @import("std");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    offset: usize = 0,
    tokens: std.ArrayList(token.Token) = .empty,
    location: token.Location = .{ .row = 1, .column = 1 },
    failure: ?token.Location = null,

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
            lexSymbols,
        };

        lexing: while (self.offset < self.source.len) {
            for (lexers) |lexer| {
                if (try lexer(self, allocator)) continue :lexing;
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
        self.failure = .{
            .row = self.location.row,
            .column = self.location.column + offset - self.offset,
        };
        return lex_error;
    }
};

pub const LexError = error{ OutOfMemory, UnexpectedCharacter };

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
    const first = state.source[state.offset];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    var position = state.offset + 1;
    while (state.peek(position)) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') break;
        position += 1;
    }
    const word = state.source[state.offset..position];

    const keywords = [_]struct { text: []const u8, kind: token.TokenKind }{
        .{ .text = "fn", .kind = .keyword_fn },
        .{ .text = "noop", .kind = .keyword_noop },
        .{ .text = "return", .kind = .keyword_return },
        .{ .text = "true", .kind = .keyword_true },
        .{ .text = "false", .kind = .keyword_false },
        .{ .text = "i8", .kind = .{ .primitive_type = .i8 } },
        .{ .text = "i16", .kind = .{ .primitive_type = .i16 } },
        .{ .text = "i32", .kind = .{ .primitive_type = .i32 } },
        .{ .text = "i64", .kind = .{ .primitive_type = .i64 } },
        .{ .text = "u8", .kind = .{ .primitive_type = .u8 } },
        .{ .text = "u16", .kind = .{ .primitive_type = .u16 } },
        .{ .text = "u32", .kind = .{ .primitive_type = .u32 } },
        .{ .text = "u64", .kind = .{ .primitive_type = .u64 } },
        .{ .text = "f32", .kind = .{ .primitive_type = .f32 } },
        .{ .text = "f64", .kind = .{ .primitive_type = .f64 } },
        .{ .text = "bool", .kind = .{ .primitive_type = .bool } },
    };

    const kind: token.TokenKind = for (keywords) |keyword| {
        if (std.mem.eql(u8, word, keyword.text)) break keyword.kind;
    } else .{ .identifier = word };

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
    const suffix = try consumeSuffix(state, &position, is_float);
    if (state.peek(position)) |next| {
        if (std.ascii.isAlphanumeric(next) or next == '_') {
            return state.fail(position, error.UnexpectedCharacter);
        }
    }

    const literal = token.NumberLiteral{ .text = text, .suffix = suffix };
    try state.tokens.append(allocator, .{
        .kind = if (is_float) .{ .float = literal } else .{ .integer = literal },
        .location = state.location,
    });
    state.location.column += position - state.offset;
    state.offset = position;
    return true;
}

fn lexSymbols(state: *Lexer, allocator: std.mem.Allocator) LexError!bool {
    const kind: token.TokenKind = switch (state.source[state.offset]) {
        ':' => .colon,
        '(' => .left_parenthesis,
        ')' => .right_parenthesis,
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

fn consumeSuffix(state: *Lexer, offset: *usize, is_float: bool) LexError!?token.PrimitiveType {
    var length: usize = 0;
    while (state.peek(offset.* + length)) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) break;
        length += 1;
    }
    if (length == 0) return null;

    const name = state.source[offset.*..][0..length];
    const suffix = std.meta.stringToEnum(token.PrimitiveType, name);
    const is_number_type = suffix != null and suffix != .bool and suffix != .void;
    const is_float_type = suffix == .f32 or suffix == .f64;
    const valid = is_number_type and is_float == is_float_type;
    if (!valid) return state.fail(offset.*, error.UnexpectedCharacter);
    offset.* += length;
    return suffix;
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
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?);
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

test "Lexer.lex: rejects tab characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\n\tnoop\n");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, lexer.failure.?);
}

test "Lexer.lex: rejects lone carriage return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("\r");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.failure.?);
}

test "Lexer.lex: tracks position on unexpected character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("fn main():\r\n  @");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 3 }, lexer.failure.?);
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

test "lexWord: recognizes primitive types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool");
    try lexer.lex(&arena);

    const expected = [_]token.PrimitiveType{ .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64, .bool };
    try std.testing.expectEqual(expected.len + 2, lexer.tokens.items.len);
    for (expected, lexer.tokens.items[1 .. expected.len + 1]) |primitive_type, lexed| {
        try std.testing.expect(lexed.kind == .primitive_type);
        try std.testing.expectEqual(primitive_type, lexed.kind.primitive_type);
    }
}

test "lexNumber: lexes an integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("return 42");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[2].kind == .integer);
    try std.testing.expectEqualStrings("42", lexer.tokens.items[2].kind.integer.text);
    try std.testing.expectEqual(null, lexer.tokens.items[2].kind.integer.suffix);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, lexer.tokens.items[2].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, lexer.tokens.items[3].location);
}

test "lexNumber: keeps separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1_000_000");
    try lexer.lex(&arena);

    try std.testing.expectEqual(3, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer);
    try std.testing.expectEqualStrings("1_000_000", lexer.tokens.items[1].kind.integer.text);
}

test "lexNumber: lexes base prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0xff_FF 0b1010_0000 0o755");
    try lexer.lex(&arena);

    try std.testing.expectEqual(5, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer);
    try std.testing.expectEqualStrings("0xff_FF", lexer.tokens.items[1].kind.integer.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .integer);
    try std.testing.expectEqualStrings("0b1010_0000", lexer.tokens.items[2].kind.integer.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .integer);
    try std.testing.expectEqualStrings("0o755", lexer.tokens.items[3].kind.integer.text);
}

test "lexNumber: lexes float literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5. 5.0 1e10 2.5e-3 3E+2 0.5");
    try lexer.lex(&arena);

    try std.testing.expectEqual(8, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .float);
    try std.testing.expectEqualStrings("5.", lexer.tokens.items[1].kind.float.text);
    try std.testing.expect(lexer.tokens.items[2].kind == .float);
    try std.testing.expectEqualStrings("5.0", lexer.tokens.items[2].kind.float.text);
    try std.testing.expect(lexer.tokens.items[3].kind == .float);
    try std.testing.expectEqualStrings("1e10", lexer.tokens.items[3].kind.float.text);
    try std.testing.expect(lexer.tokens.items[4].kind == .float);
    try std.testing.expectEqualStrings("2.5e-3", lexer.tokens.items[4].kind.float.text);
    try std.testing.expect(lexer.tokens.items[5].kind == .float);
    try std.testing.expectEqualStrings("3E+2", lexer.tokens.items[5].kind.float.text);
    try std.testing.expect(lexer.tokens.items[6].kind == .float);
    try std.testing.expectEqualStrings("0.5", lexer.tokens.items[6].kind.float.text);
}

test "lexNumber: lexes type suffixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5u8 1_000_u32 2.5f32 1.0_f64");
    try lexer.lex(&arena);

    try std.testing.expectEqual(6, lexer.tokens.items.len);
    try std.testing.expectEqualStrings("5", lexer.tokens.items[1].kind.integer.text);
    try std.testing.expectEqual(.u8, lexer.tokens.items[1].kind.integer.suffix);
    try std.testing.expectEqualStrings("1_000", lexer.tokens.items[2].kind.integer.text);
    try std.testing.expectEqual(.u32, lexer.tokens.items[2].kind.integer.suffix);
    try std.testing.expectEqualStrings("2.5", lexer.tokens.items[3].kind.float.text);
    try std.testing.expectEqual(.f32, lexer.tokens.items[3].kind.float.suffix);
    try std.testing.expectEqualStrings("1.0", lexer.tokens.items[4].kind.float.text);
    try std.testing.expectEqual(.f64, lexer.tokens.items[4].kind.float.suffix);
}

test "lexNumber: does not read a point followed by a letter as a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5.a");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: accepts a zero on its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0");
    try lexer.lex(&arena);

    try std.testing.expectEqual(3, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .integer);
    try std.testing.expectEqualStrings("0", lexer.tokens.items[1].kind.integer.text);
}

test "lexNumber: rejects leading zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("007");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects separator after leading zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0_1");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects letter after digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("2fast");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects trailing separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1_");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects double separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1__0");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects prefix without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0x");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?);
}

test "lexNumber: rejects digit outside the base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0b102");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 5 }, lexer.failure.?);
}

test "lexNumber: rejects exponent without digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1e");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 3 }, lexer.failure.?);
}

test "lexNumber: rejects integer suffix on float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("2.5u8");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?);
}

test "lexNumber: rejects float suffix on integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1f64");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects float suffix on binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("0b1_f64");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 5 }, lexer.failure.?);
}

test "lexNumber: rejects bool suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5bool");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: rejects void suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("5void");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 2 }, lexer.failure.?);
}

test "lexNumber: leaves the position untouched on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("12_x");

    try std.testing.expectError(error.UnexpectedCharacter, lexer.lex(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, lexer.failure.?);
    try std.testing.expectEqual(0, lexer.offset);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, lexer.location);
}

test "lexSymbols: lexes adjacent symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init(":(");
    try lexer.lex(&arena);

    try std.testing.expectEqual(4, lexer.tokens.items.len);
    try std.testing.expect(lexer.tokens.items[1].kind == .colon);
    try std.testing.expect(lexer.tokens.items[2].kind == .left_parenthesis);
}
