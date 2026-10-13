const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const Parser = struct {
    tokens: []const token.Token,
    offset: usize = 0,
    failure: ?token.Token = null,
    functions: std.ArrayList(ast.Function) = .empty,

    pub fn init(tokens: []const token.Token) Parser {
        return .{ .tokens = tokens };
    }

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) ParseError!ast.Module {
        const allocator = arena.allocator();

        while (true) {
            self.skipBlankLines(&self.offset);
            if (self.tokens[self.offset].kind == .eof) break;
            if (try self.parseTopLevelFunction(allocator, &self.offset)) continue;
            return self.fail(self.offset, error.UnexpectedToken);
        }

        return .{ .functions = self.functions.items };
    }

    fn skipBlankLines(self: *Parser, offset: *usize) void {
        while (self.tokens[offset.*].kind == .indent) {
            switch (self.tokens[offset.* + 1].kind) {
                .indent, .eof => offset.* += 1,
                else => return,
            }
        }
    }

    fn parseTopLevelFunction(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!bool {
        var position = offset.*;
        const indentation = self.match(&position, .indent) orelse return false;
        if (indentation.kind.indent != 0) return false;
        const function = (try self.parseFunction(allocator, &position)) orelse return false;
        try self.functions.append(allocator, function);
        offset.* = position;
        return true;
    }

    fn parseFunction(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Function {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_fn) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position);

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .body = body,
            .location = keyword.location,
        };
    }

    fn parseBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]const ast.Statement {
        if (self.tokens[offset.*].kind == .indent) {
            return self.parseIndentedBlock(allocator, offset);
        }
        return self.parseInlineBlock(allocator, offset);
    }

    fn parseIndentedBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]const ast.Statement {
        var position = offset.*;
        self.skipBlankLines(&position);
        const first = self.tokens[position];
        if (first.kind != .indent or first.kind.indent == 0) {
            return self.fail(position, error.ExpectedBlock);
        }
        const depth = first.kind.indent;

        var statements: std.ArrayList(ast.Statement) = .empty;
        while (true) {
            self.skipBlankLines(&position);
            const current = self.tokens[position];
            if (current.kind != .indent or current.kind.indent < depth) break;
            if (current.kind.indent > depth) {
                return self.fail(position, error.UnexpectedIndentation);
            }
            position += 1;
            const statement = self.parseStatement(&position) orelse {
                return self.fail(position, error.ExpectedStatement);
            };
            try statements.append(allocator, statement);
        }

        offset.* = position;
        return statements.items;
    }

    fn parseInlineBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]const ast.Statement {
        const statement = self.parseStatement(offset) orelse {
            return self.fail(offset.*, error.ExpectedStatement);
        };
        return allocator.dupe(ast.Statement, &.{statement});
    }

    fn parseStatement(self: *Parser, offset: *usize) ?ast.Statement {
        const keyword = self.match(offset, .keyword_noop) orelse return null;
        return .{ .kind = .noop, .location = keyword.location };
    }

    fn expect(
        self: *Parser,
        offset: *usize,
        tag: std.meta.Tag(token.TokenKind),
        parse_error: ParseError,
    ) ParseError!token.Token {
        return self.match(offset, tag) orelse self.fail(offset.*, parse_error);
    }

    fn match(self: *Parser, offset: *usize, tag: std.meta.Tag(token.TokenKind)) ?token.Token {
        const current = self.tokens[offset.*];
        if (std.meta.activeTag(current.kind) != tag) return null;
        offset.* += 1;
        return current;
    }

    fn fail(self: *Parser, offset: usize, parse_error: ParseError) ParseError {
        self.failure = self.tokens[offset];
        return parse_error;
    }
};

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    ExpectedIdentifier,
    ExpectedLeftParenthesis,
    ExpectedRightParenthesis,
    ExpectedColon,
    ExpectedStatement,
    ExpectedBlock,
    UnexpectedIndentation,
};

test "Parser.parse: parses several functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.functions.len);
    try std.testing.expectEqualStrings("one", module.functions[0].name);
    try std.testing.expectEqualStrings("two", module.functions[1].name);
}

test "Parser.parse: skips blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("\nfn one():\n\n    noop\n\n    noop\n\nfn two(): noop\n\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.functions.len);
    try std.testing.expectEqualStrings("one", module.functions[0].name);
    try std.testing.expectEqual(2, module.functions[0].body.len);
    try std.testing.expectEqualStrings("two", module.functions[1].name);
    try std.testing.expectEqual(1, module.functions[1].body.len);
}

test "Parser.parse: rejects statement at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\nnoop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location);
}

test "Parser.parse: rejects indentation at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location);
}

test "parseFunction: parses an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.functions.len);
    try std.testing.expectEqualStrings("main", module.functions[0].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, module.functions[0].location);
    try std.testing.expectEqual(1, module.functions[0].body.len);
    try std.testing.expect(module.functions[0].body[0].kind == .noop);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, module.functions[0].body[0].location);
}

test "parseFunction: parses an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.functions.len);
    try std.testing.expectEqualStrings("main", module.functions[0].name);
    try std.testing.expectEqual(1, module.functions[0].body.len);
    try std.testing.expect(module.functions[0].body[0].kind == .noop);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, module.functions[0].body[0].location);
}

test "parseFunction: rejects missing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parser.failure.?.location);
}

test "parseIndentedBlock: rejects line deeper than the first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n  noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location);
}

test "parseIndentedBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n    fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location);
}

test "parseIndentedBlock: rejects empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one():\nfn two(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location);
}

test "parseInlineBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location);
}
