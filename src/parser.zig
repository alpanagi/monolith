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
        if (indentation.kind.indent != 0) return self.fail(offset.*, error.UnexpectedIndentation);
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
        const parameters = try self.parseParameters(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const return_type = try self.parseReturnType(&position);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position);

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .parameters = parameters,
            .return_type = return_type,
            .body = body,
            .location = keyword.location,
        };
    }

    fn parseParameters(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.Parameter {
        var position = offset.*;
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        while (self.tokens[position].kind != .right_parenthesis) {
            try parameters.append(allocator, try self.parseParameter(&position));
            if (self.match(&position, .comma) == null) break;
        }

        offset.* = position;
        return parameters.items;
    }

    fn parseParameter(self: *Parser, offset: *usize) ParseError!ast.Parameter {
        var position = offset.*;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const parameter_type = try self.parseType(&position);

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .parameter_type = parameter_type,
            .location = name.location,
        };
    }

    fn parseType(self: *Parser, offset: *usize) ParseError!ast.Type {
        const type_keyword = try self.expect(offset, .primitive_type, error.ExpectedType);
        return .{
            .primitive_type = type_keyword.kind.primitive_type,
            .location = type_keyword.location,
        };
    }

    fn parseReturnType(self: *Parser, offset: *usize) ParseError!ast.Type {
        if (self.tokens[offset.*].kind == .primitive_type) return self.parseType(offset);
        return .{ .primitive_type = .void, .location = self.tokens[offset.*].location };
    }

    fn parseBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.Statement {
        if (self.tokens[offset.*].kind == .indent) {
            return self.parseIndentedBlock(allocator, offset);
        }
        return self.parseInlineBlock(allocator, offset);
    }

    fn parseIndentedBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.Statement {
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
            if (current.kind != .indent or current.kind.indent == 0) break;
            if (current.kind.indent < depth) {
                return self.fail(position, error.InconsistentIndentation);
            }
            if (current.kind.indent > depth) {
                return self.fail(position, error.UnexpectedIndentation);
            }
            position += 1;
            const statement = (try self.parseStatement(allocator, &position)) orelse {
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
    ) ParseError![]ast.Statement {
        const statement = (try self.parseStatement(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedStatement);
        };
        return allocator.dupe(ast.Statement, &.{statement});
    }

    fn parseStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        if (self.match(offset, .keyword_noop)) |keyword| {
            return .{ .kind = .noop, .location = keyword.location };
        }
        if (try self.parseReturn(allocator, offset)) |statement| return statement;
        if (try self.parseDiscard(allocator, offset)) |statement| return statement;
        return self.parseCallStatement(allocator, offset);
    }

    fn parseReturn(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_return) orelse return null;
        var value: ?ast.Expression = null;
        const next = self.tokens[position].kind;
        if (next != .indent and next != .eof) {
            value = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
        }

        offset.* = position;
        return .{ .kind = .{ .@"return" = value }, .location = keyword.location };
    }

    fn parseDiscard(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const underscore = self.match(&position, .underscore) orelse return null;
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const call = (try self.parseCall(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedCall);
        };

        offset.* = position;
        return .{ .kind = .{ .discard = call }, .location = underscore.location };
    }

    fn parseCallStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        const call = (try self.parseCall(allocator, offset)) orelse return null;
        return .{ .kind = .{ .expression = call }, .location = call.location };
    }

    fn parseExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        if (try self.parseCall(allocator, offset)) |call| return call;

        const current = self.tokens[offset.*];
        const kind: ast.ExpressionKind = switch (current.kind) {
            .integer => |literal| .{ .integer = literal },
            .float => |literal| .{ .float = literal },
            .keyword_true => .{ .boolean = true },
            .keyword_false => .{ .boolean = false },
            .identifier => |name| .{ .identifier = .{ .name = name } },
            else => return null,
        };
        offset.* += 1;
        return .{ .kind = kind, .location = current.location };
    }

    fn parseCall(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const name = self.match(&position, .identifier) orelse return null;
        if (self.match(&position, .left_parenthesis) == null) return null;
        const arguments = try self.parseArguments(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return .{
            .kind = .{ .call = .{ .name = name.kind.identifier, .arguments = arguments } },
            .location = name.location,
        };
    }

    fn parseArguments(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.Expression {
        var position = offset.*;
        var arguments: std.ArrayList(ast.Expression) = .empty;
        while (self.tokens[position].kind != .right_parenthesis) {
            const argument = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
            try arguments.append(allocator, argument);
            if (self.match(&position, .comma) == null) break;
        }

        offset.* = position;
        return arguments.items;
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
    ExpectedType,
    ExpectedEquals,
    ExpectedStatement,
    ExpectedExpression,
    ExpectedCall,
    ExpectedBlock,
    UnexpectedIndentation,
    InconsistentIndentation,
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

test "parseTopLevelFunction: rejects indentation at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
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

test "parseParameters: parses each parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: u8) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.functions[0].parameters;
    try std.testing.expectEqual(2, parameters.len);
    try std.testing.expectEqualStrings("left", parameters[0].name);
    try std.testing.expectEqual(token.PrimitiveType.i32, parameters[0].parameter_type.primitive_type);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parameters[0].location);
    try std.testing.expectEqualStrings("right", parameters[1].name);
    try std.testing.expectEqual(token.PrimitiveType.u8, parameters[1].parameter_type.primitive_type);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parameters[1].parameter_type.location);
}

test "parseParameters: accepts a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32,) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.functions[0].parameters.len);
}

test "parseParameter: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left i32) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location);
}

test "parseParameter: rejects an underscore as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f(_: i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, parser.failure.?.location);
}

test "parseType: rejects a missing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: ) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location);
}

test "parseReturnType: reads a written return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(token.PrimitiveType.i32, module.functions[0].return_type.primitive_type);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, module.functions[0].return_type.location);
}

test "parseReturnType: defaults to void at the colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(token.PrimitiveType.void, module.functions[0].return_type.primitive_type);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, module.functions[0].return_type.location);
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

test "parseIndentedBlock: rejects a dedent that matches no outer level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n  noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InconsistentIndentation, parser.parse(&arena));
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

test "parseReturn: parses return with a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() u8:\n    return 42\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.functions[0].body[0];
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
    const value = statement.kind.@"return".?;
    try std.testing.expectEqualStrings("42", value.kind.integer.text);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, value.location);
}

test "parseReturn: parses return without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    return\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.functions[0].body[0].kind == .@"return");
    try std.testing.expectEqual(null, module.functions[0].body[0].kind.@"return");
}

test "parseReturn: rejects return followed by a non-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): return fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location);
}

test "parseDiscard: parses a discarded call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.functions[0].body[0];
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, statement.location);
    const call = statement.kind.discard.kind.call;
    try std.testing.expectEqualStrings("add", call.name);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseDiscard: rejects a missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location);
}

test "parseDiscard: rejects a discarded literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = 5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCall, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location);
}

test "parseCallStatement: parses a call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    log(1, true)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.functions[0].body[0].kind.expression.kind.call;
    try std.testing.expectEqualStrings("log", call.name);
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("1", call.arguments[0].kind.integer.text);
    try std.testing.expectEqual(true, call.arguments[1].kind.boolean);
}

test "parseCallStatement: rejects a name that is not called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location);
}

test "parseExpression: parses each literal kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() u8: return 0xff_u8\nfn two() f64: return 2.5\nfn three() bool: return true\nfn four() bool: return false");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const integer = module.functions[0].body[0].kind.@"return".?.kind.integer;
    try std.testing.expectEqualStrings("0xff", integer.text);
    try std.testing.expectEqual(token.PrimitiveType.u8, integer.suffix);
    try std.testing.expectEqualStrings("2.5", module.functions[1].body[0].kind.@"return".?.kind.float.text);
    try std.testing.expectEqual(true, module.functions[2].body[0].kind.@"return".?.kind.boolean);
    try std.testing.expectEqual(false, module.functions[3].body[0].kind.@"return".?.kind.boolean);
}

test "parseExpression: parses a parameter reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn same(value: i32) i32: return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("value", module.functions[0].body[0].kind.@"return".?.kind.identifier.name);
}

test "parseCall: parses nested calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(add(1, 2))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.functions[0].body[0].kind.expression.kind.call;
    try std.testing.expectEqualStrings("log", outer.name);
    const inner = outer.arguments[0].kind.call;
    try std.testing.expectEqualStrings("add", inner.name);
    try std.testing.expectEqual(2, inner.arguments.len);
}

test "parseCall: rejects a missing closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location);
}

test "parseArguments: accepts a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1, 2,)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.functions[0].body[0].kind.expression.kind.call.arguments.len);
}

test "parseArguments: rejects a missing argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1, , 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location);
}
