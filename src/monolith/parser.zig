const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;

const Failure = core.Failure;

pub const Parser = struct {
    tokens: []const token.Token,
    offset: usize = 0,
    declarations: std.ArrayList(ast.Declaration) = .empty,
    failure: ?Failure = null,

    pub fn init(tokens: []const token.Token) Parser {
        return .{ .tokens = tokens };
    }

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) ParseError!ast.Module {
        const allocator = arena.allocator();

        while (true) {
            self.skipBlankLines(&self.offset);
            if (self.tokens[self.offset].kind == .eof) break;
            if (try self.parseTopLevelStatement(allocator, &self.offset)) continue;
            return self.fail(self.offset, error.UnexpectedToken);
        }

        return .{ .declarations = self.declarations.items };
    }

    fn parseTopLevelStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!bool {
        var position = offset.*;
        const indentation = self.match(&position, .indent) orelse return false;
        if (indentation.kind.indent != 0) return self.fail(offset.*, error.UnexpectedIndentation);
        const declaration = (try self.parseDeclaration(allocator, &position)) orelse return false;
        try self.declarations.append(allocator, declaration);
        offset.* = position;
        return true;
    }

    fn parseDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Declaration {
        const location = self.tokens[offset.*].location;
        const kind: ast.DeclarationKind = kind: {
            if (try self.parseFunctionDeclaration(allocator, offset)) |function_declaration| {
                break :kind .{ .function_declaration = function_declaration };
            }
            if (try self.parseFunctionDefinition(allocator, offset)) |function| {
                break :kind .{ .function_definition = function };
            }
            if (try self.parseConstantDeclaration(allocator, offset)) |constant| {
                break :kind .{ .constant_declaration = constant };
            }
            return null;
        };
        return .{ .kind = kind, .location = location };
    }

    fn parseFunctionDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.FunctionSignature {
        var position = offset.*;
        _ = self.match(&position, .keyword_external) orelse return null;
        const signature = (try self.parseFunctionSignature(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedFunctionKeyword);
        };
        if (self.tokens[position].kind == .colon) {
            return self.fail(position, error.ExternalFunctionBody);
        }

        offset.* = position;
        return signature;
    }

    fn parseFunctionDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.FunctionDefinition {
        var position = offset.*;
        const signature = (try self.parseFunctionSignature(allocator, &position)) orelse {
            return null;
        };
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position);

        offset.* = position;
        return .{ .signature = signature, .body = body };
    }

    fn parseFunctionSignature(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.FunctionSignature {
        var position = offset.*;
        _ = self.match(&position, .keyword_fn) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        const parameters = try self.parseParameters(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const return_type = try self.parseReturnType(allocator, &position);

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .parameters = parameters,
            .return_type = return_type,
        };
    }

    fn parseParameters(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.TypedName {
        var position = offset.*;
        var parameters: std.ArrayList(ast.TypedName) = .empty;
        while (self.tokens[position].kind != .right_parenthesis) {
            const parameter = (try self.parseTypedName(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
            try parameters.append(allocator, parameter);
            if (self.match(&position, .comma) == null) break;
        }

        offset.* = position;
        return parameters.items;
    }

    fn parseReturnType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Expression {
        const next = self.tokens[offset.*];
        switch (next.kind) {
            .colon, .indent, .eof => {
                const kind: ast.ExpressionKind = .{ .identifier = .{ .name = "void" } };
                return .{ .kind = kind, .location = next.location };
            },
            else => {},
        }
        return (try self.parseExpression(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedType);
        };
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
        const depth = try self.expectBlock(position);
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (try self.matchBlockLine(&position, depth)) {
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
        return .{ .kind = .{ .call = call }, .location = call.location };
    }

    fn parseConstantDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.ConstantDeclaration {
        var position = offset.*;
        _ = self.match(&position, .keyword_const) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const value = (try self.parseStruct(allocator, &position)) orelse
            (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .value = value };
    }

    fn parseStruct(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_struct) orelse return null;
        var fields: []ast.TypedName = &.{};
        if (self.match(&position, .colon) != null) {
            fields = try self.parseFields(allocator, &position);
        }

        offset.* = position;
        return .{ .kind = .{ .@"struct" = .{ .fields = fields } }, .location = keyword.location };
    }

    fn parseFields(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.TypedName {
        var position = offset.*;
        const depth = try self.expectBlock(position);
        var fields: std.ArrayList(ast.TypedName) = .empty;
        while (try self.matchBlockLine(&position, depth)) {
            const field = (try self.parseTypedName(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedField);
            };
            try fields.append(allocator, field);
        }

        offset.* = position;
        return fields.items;
    }

    fn parseTypedName(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypedName {
        var position = offset.*;
        const name = self.match(&position, .identifier) orelse return null;
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const name_type = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .type = name_type, .location = name.location };
    }

    fn expectBlock(self: *Parser, offset: usize) ParseError!usize {
        const first = self.tokens[offset];
        if (first.kind != .indent or first.kind.indent == 0 or self.isBlankLine(offset)) {
            return self.fail(offset, error.ExpectedBlock);
        }
        return first.kind.indent;
    }

    fn matchBlockLine(self: *Parser, offset: *usize, depth: usize) ParseError!bool {
        self.skipBlankLines(offset);
        const current = self.tokens[offset.*];
        if (current.kind != .indent or current.kind.indent == 0) return false;
        if (current.kind.indent < depth) {
            return self.fail(offset.*, error.InconsistentIndentation);
        }
        if (current.kind.indent > depth) {
            return self.fail(offset.*, error.UnexpectedIndentation);
        }
        offset.* += 1;
        return true;
    }

    fn skipBlankLines(self: *Parser, offset: *usize) void {
        while (self.isBlankLine(offset.*)) offset.* += 1;
    }

    fn isBlankLine(self: *Parser, offset: usize) bool {
        if (self.tokens[offset].kind != .indent) return false;
        const next = self.tokens[offset + 1].kind;
        return next == .indent or next == .eof;
    }

    fn parseExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        if (try self.parseCall(allocator, offset)) |call| return call;
        if (try self.parseNameExpression(allocator, offset)) |name| return name;
        return self.parseLiteral(offset);
    }

    fn parseCall(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const first = self.match(&position, .identifier) orelse return null;
        const callee = try self.parseName(allocator, &position, first);
        if (self.match(&position, .left_parenthesis) == null) return null;
        const arguments = try self.parseArguments(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return .{
            .kind = .{ .call = .{ .callee = callee, .arguments = arguments } },
            .location = first.location,
        };
    }

    fn parseNameExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const first = self.match(&position, .identifier) orelse return null;
        const name = try self.parseName(allocator, &position, first);

        offset.* = position;
        const kind: ast.ExpressionKind = switch (name) {
            .identifier => |identifier| .{ .identifier = identifier },
            .path_expression => |path_expression| .{ .path_expression = path_expression },
        };
        return .{ .kind = kind, .location = first.location };
    }

    fn parseName(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        first: token.Token,
    ) ParseError!ast.Name {
        const path = try self.parsePath(allocator, offset, first);
        if (path.len == 1) return .{ .identifier = .{ .name = first.kind.identifier } };
        return .{ .path_expression = .{ .path = path } };
    }

    fn parsePath(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        first: token.Token,
    ) ParseError!ast.Path {
        var position = offset.*;
        var path: std.ArrayList([]const u8) = .empty;
        try path.append(allocator, first.kind.identifier);
        while (self.match(&position, .double_colon) != null) {
            const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
            try path.append(allocator, name.kind.identifier);
        }

        offset.* = position;
        return path.items;
    }

    fn parseLiteral(self: *Parser, offset: *usize) ?ast.Expression {
        const current = self.tokens[offset.*];
        const kind: ast.ExpressionKind = switch (current.kind) {
            .integer_literal => |literal| .{ .integer_literal = literal },
            .float_literal => |literal| .{ .float_literal = literal },
            .keyword_true => .{ .boolean_literal = true },
            .keyword_false => .{ .boolean_literal = false },
            .string_literal => |text| .{ .string_literal = text },
            else => return null,
        };
        offset.* += 1;
        return .{ .kind = kind, .location = current.location };
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
        self.failure = .{
            .location = self.tokens[offset].location,
            .message = describeError(parse_error),
        };
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
    ExpectedFunctionKeyword,
    ExternalFunctionBody,
    ExpectedType,
    ExpectedEquals,
    ExpectedStatement,
    ExpectedExpression,
    ExpectedCall,
    ExpectedField,
    ExpectedBlock,
    UnexpectedIndentation,
    InconsistentIndentation,
};

fn describeError(parse_error: ParseError) []const u8 {
    return switch (parse_error) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedToken => "unexpected token",
        error.ExpectedIdentifier => "expected an identifier",
        error.ExpectedLeftParenthesis => "expected '('",
        error.ExpectedRightParenthesis => "expected ')'",
        error.ExpectedColon => "expected ':'",
        error.ExpectedFunctionKeyword => "expected 'fn'",
        error.ExternalFunctionBody => "external functions have no body",
        error.ExpectedType => "expected a type",
        error.ExpectedEquals => "expected '='",
        error.ExpectedStatement => "expected a statement",
        error.ExpectedExpression => "expected an expression",
        error.ExpectedCall => "expected a call",
        error.ExpectedField => "expected a field",
        error.ExpectedBlock => "expected an indented block",
        error.UnexpectedIndentation => "unexpected indentation",
        error.InconsistentIndentation => "indentation does not match any outer level",
    };
}

test "Parser.parse: parses several functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    try std.testing.expectEqualStrings("one", module.declarations[0].kind.function_definition.signature.name);
    try std.testing.expectEqualStrings("two", module.declarations[1].kind.function_definition.signature.name);
}

test "Parser.parse: skips blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("\nfn one():\n    noop\n\n    noop\n\nfn two(): noop\n\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    try std.testing.expectEqualStrings("one", module.declarations[0].kind.function_definition.signature.name);
    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.body.len);
    try std.testing.expectEqualStrings("two", module.declarations[1].kind.function_definition.signature.name);
    try std.testing.expectEqual(1, module.declarations[1].kind.function_definition.body.len);
}

test "Parser.parse: rejects statement at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\nnoop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseTopLevelStatement: rejects indentation at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseTopLevelStatement: parses constants between functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const one = two\nfn main(): noop\nconst three = four");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(3, module.declarations.len);
    try std.testing.expectEqualStrings("one", module.declarations[0].kind.constant_declaration.name);
    try std.testing.expectEqualStrings("main", module.declarations[1].kind.function_definition.signature.name);
    try std.testing.expectEqualStrings("three", module.declarations[2].kind.constant_declaration.name);
}

test "parseFunctionDeclaration: parses an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn stdout_write(text: String)\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const declaration = module.declarations[0];
    try std.testing.expectEqualStrings("stdout_write", declaration.kind.function_declaration.name);
    try std.testing.expectEqual(1, declaration.kind.function_declaration.parameters.len);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, declaration.location);
}

test "parseFunctionDeclaration: rejects a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn log(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExternalFunctionBody, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseFunctionDeclaration: rejects external without fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external log()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedFunctionKeyword, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, parser.failure.?.location.?);
}

test "parseFunctionDefinition: parses an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations.len);
    try std.testing.expectEqualStrings("main", module.declarations[0].kind.function_definition.signature.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, module.declarations[0].location);
    try std.testing.expectEqual(1, module.declarations[0].kind.function_definition.body.len);
    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind == .noop);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, module.declarations[0].kind.function_definition.body[0].location);
}

test "parseFunctionDefinition: parses an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations.len);
    try std.testing.expectEqualStrings("main", module.declarations[0].kind.function_definition.signature.name);
    try std.testing.expectEqual(1, module.declarations[0].kind.function_definition.body.len);
    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind == .noop);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, module.declarations[0].kind.function_definition.body[0].location);
}

test "parseFunctionSignature: rejects missing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parser.failure.?.location.?);
}

test "parseParameters: parses each parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: u8) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(2, parameters.len);
    try std.testing.expectEqualStrings("left", parameters[0].name);
    try std.testing.expectEqualStrings("i32", parameters[0].type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parameters[0].location);
    try std.testing.expectEqualStrings("right", parameters[1].name);
    try std.testing.expectEqualStrings("u8", parameters[1].type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parameters[1].type.location);
}

test "parseParameters: accepts a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32,) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.signature.parameters.len);
}

test "parseParameters: rejects an underscore as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f(_: i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, parser.failure.?.location.?);
}

test "parseReturnType: reads a written return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const return_type = module.declarations[0].kind.function_definition.signature.return_type;
    try std.testing.expectEqualStrings("i32", return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, return_type.location);
}

test "parseReturnType: returns void when no type is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const return_type = module.declarations[0].kind.function_definition.signature.return_type;
    try std.testing.expectEqualStrings("void", return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, return_type.location);
}

test "parseIndentedBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n    fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "parseInlineBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseReturn: parses return with a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() u8:\n    return 42\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
    const value = statement.kind.@"return".?;
    try std.testing.expectEqualStrings("42", value.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, value.location);
}

test "parseReturn: parses return without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    return\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind == .@"return");
    try std.testing.expectEqual(null, module.declarations[0].kind.function_definition.body[0].kind.@"return");
}

test "parseReturn: rejects return followed by a non-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): return fn");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseDiscard: parses a discarded call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, statement.location);
    const call = statement.kind.discard.kind.call;
    try std.testing.expectEqualStrings("add", call.callee.identifier.name);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseDiscard: rejects a missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseDiscard: rejects a discarded literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = 5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCall, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseCallStatement: parses a call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    log(1, true)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqualStrings("log", call.callee.identifier.name);
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("1", call.arguments[0].kind.integer_literal.text);
    try std.testing.expectEqual(true, call.arguments[1].kind.boolean_literal);
}

test "parseCallStatement: rejects a name that is not called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseConstantDeclaration: parses a path as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const stdout = std::stdout");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("stdout", constant.name);
    try std.testing.expectEqual(2, constant.value.kind.path_expression.path.len);
    try std.testing.expectEqualStrings("std", constant.value.kind.path_expression.path[0]);
    try std.testing.expectEqualStrings("stdout", constant.value.kind.path_expression.path[1]);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, module.declarations[0].location);
}

test "parseConstantDeclaration: parses a name as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write = mn_stdout_write");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("mn_stdout_write", constant.value.kind.identifier.name);
}

test "parseConstantDeclaration: parses a literal as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const limit = 5i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("5", constant.value.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, constant.value.location);
}

test "parseConstantDeclaration: rejects a missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write mn_stdout_write");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseConstantDeclaration: rejects a missing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write =\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseStruct: parses fields in an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Point = struct:\n    x: i32\n    y: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    const fields = value.kind.@"struct".fields;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, value.location);
    try std.testing.expectEqual(2, fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqualStrings("i32", fields[0].type.kind.identifier.name);
    try std.testing.expectEqualStrings("y", fields[1].name);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, fields[1].location);
}

test "parseStruct: parses a struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Marker = struct\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqual(0, value.kind.@"struct".fields.len);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseStruct: rejects a struct that is not the value of a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(point: struct): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseFields: rejects a field on the line of the colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Meters = struct: value: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, parser.failure.?.location.?);
}

test "parseFields: rejects a line that is not a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Point = struct:\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left i32) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a name without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Point = struct:\n    x:\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: ) i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "expectBlock: rejects empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one():\nfn two(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "expectBlock: rejects a blank line before the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "expectBlock: rejects a blank indented line before the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Point = struct:\n    \n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "matchBlockLine: rejects line deeper than the first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n  noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "matchBlockLine: rejects a dedent that matches no outer level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop\n  noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InconsistentIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseExpression: parses each literal kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() u8: return 0xff_u8\nfn two() f64: return 2.5\nfn three() Bool: return true\nfn four() Bool: return false");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const integer = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.integer_literal;
    try std.testing.expectEqualStrings("0xff", integer.text);
    try std.testing.expectEqualStrings("u8", integer.suffix.?);
    try std.testing.expectEqualStrings("2.5", module.declarations[1].kind.function_definition.body[0].kind.@"return".?.kind.float_literal.text);
    try std.testing.expectEqual(true, module.declarations[2].kind.function_definition.body[0].kind.@"return".?.kind.boolean_literal);
    try std.testing.expectEqual(false, module.declarations[3].kind.function_definition.body[0].kind.@"return".?.kind.boolean_literal);
}

test "parseExpression: parses a string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn greeting() String: return \"hello\"");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("hello", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.string_literal);
}

test "parseExpression: parses a parameter reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn same(value: i32) i32: return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("value", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.identifier.name);
}

test "parseCall: parses nested calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(add(1, 2))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqualStrings("log", outer.callee.identifier.name);
    const inner = outer.arguments[0].kind.call;
    try std.testing.expectEqualStrings("add", inner.callee.identifier.name);
    try std.testing.expectEqual(2, inner.arguments.len);
}

test "parseCall: parses a path as the callee" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): std::stdout::write(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const expression = module.declarations[0].kind.function_definition.body[0].kind.call;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, expression.location);
    const call = expression.kind.call;
    const path = call.callee.path_expression.path;
    try std.testing.expectEqual(3, path.len);
    try std.testing.expectEqualStrings("std", path[0]);
    try std.testing.expectEqualStrings("stdout", path[1]);
    try std.testing.expectEqualStrings("write", path[2]);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseCall: rejects a missing closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseNameExpression: parses a path used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() i32: return utils::value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const path_expression = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.path_expression;
    try std.testing.expectEqual(2, path_expression.path.len);
    try std.testing.expectEqualStrings("utils", path_expression.path[0]);
    try std.testing.expectEqualStrings("value", path_expression.path[1]);
}

test "parsePath: rejects a separator without a name after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const stdout = std::");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseArguments: accepts a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1, 2,)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments.len);
}

test "parseArguments: rejects a missing argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1, , 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}
