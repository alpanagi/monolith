const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;

const Failure = core.Failure;

const comparison_operators: []const OperatorToken = &.{
    .{ .equals_equals, .equal },
    .{ .exclamation_mark_equals, .not_equal },
    .{ .less_than, .less_than },
    .{ .less_than_equals, .less_than_or_equal },
    .{ .greater_than, .greater_than },
    .{ .greater_than_equals, .greater_than_or_equal },
};

pub const Parser = struct {
    tokens: []const token.Token,
    offset: usize = 0,
    declarations: std.ArrayList(ast.Declaration) = .empty,
    methods: std.ArrayList(ast.Declaration) = .empty,
    failure: ?Failure = null,

    pub fn init(tokens: []const token.Token) Parser {
        return .{ .tokens = tokens };
    }

    pub fn parse(self: *Parser, arena: *std.heap.ArenaAllocator) ParseError!ast.Module {
        const allocator = arena.allocator();

        while (true) {
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
        try self.declarations.appendSlice(allocator, self.methods.items);
        self.methods.clearRetainingCapacity();
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
            if (try self.parseFunctionDefinition(allocator, offset, null, 0)) |function| {
                break :kind .{ .function_definition = function };
            }
            if (try self.parseConstantDeclaration(allocator, offset)) |constant| {
                break :kind .{ .constant_declaration = constant };
            }
            if (try self.parseStructDefinition(allocator, offset)) |definition| {
                break :kind .{ .struct_definition = definition };
            }
            if (try self.parseTraitDefinition(allocator, offset)) |definition| {
                break :kind .{ .trait_definition = definition };
            }
            if (try self.parseImplementation(allocator, offset)) |implementation| {
                break :kind .{ .implementation = implementation };
            }
            if (try self.parseImport(allocator, offset)) |import| break :kind .{ .import = import };
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
        const signature = (try self.parseFunctionSignature(allocator, &position, null)) orelse {
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
        receiver: ?ast.Expression,
        depth: usize,
    ) ParseError!?ast.FunctionDefinition {
        var position = offset.*;
        const signature = (try self.parseFunctionSignature(allocator, &position, receiver)) orelse {
            return null;
        };
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);

        offset.* = position;
        return .{ .signature = signature, .body = body };
    }

    fn parseFunctionSignature(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ?ast.Expression,
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
            .receiver = receiver,
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
            const parameter = (try self.parseParameter(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
            try parameters.append(allocator, parameter);
            if (self.match(&position, .comma) == null) break;
        }

        offset.* = position;
        return parameters.items;
    }

    fn parseParameter(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypedName {
        var position = offset.*;
        const underscore = self.match(&position, .underscore);
        const parameter = if (underscore) |discarded|
            try self.parseNameType(allocator, &position, "_", discarded.location)
        else
            (try self.parseTypedName(allocator, &position)) orelse return null;
        if (self.tokens[position].kind == .equals) {
            return self.fail(position, error.ParameterDefault);
        }

        offset.* = position;
        return parameter;
    }

    fn parseReturnType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Expression {
        const next = self.tokens[offset.*];
        if (self.match(offset, .arrow) == null) {
            if (self.isTypeStart(offset.*)) return self.fail(offset.*, error.ExpectedArrow);
            const kind: ast.ExpressionKind = .{ .identifier = .{ .name = "void" } };
            return .{ .kind = kind, .location = next.location };
        }
        return (try self.parseExpression(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedType);
        };
    }

    fn parseBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        outer: usize,
    ) ParseError![]ast.Statement {
        if (self.tokens[offset.*].kind == .indent) {
            return self.parseIndentedBlock(allocator, offset, outer);
        }
        return self.parseInlineBlock(allocator, offset, outer);
    }

    fn parseIndentedBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        outer: usize,
    ) ParseError![]ast.Statement {
        var position = offset.*;
        const depth = try self.expectBlock(position, outer);
        var statements: std.ArrayList(ast.Statement) = .empty;
        while (try self.matchBlockLine(&position, depth, outer)) {
            const statement = (try self.parseStatement(allocator, &position, depth)) orelse {
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
        outer: usize,
    ) ParseError![]ast.Statement {
        const statement = (try self.parseStatement(allocator, offset, outer)) orelse {
            return self.fail(offset.*, error.ExpectedStatement);
        };
        return allocator.dupe(ast.Statement, &.{statement});
    }

    fn parseStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError!?ast.Statement {
        const location = self.tokens[offset.*].location;
        if (self.match(offset, .keyword_noop) != null) {
            return .{ .kind = .noop, .location = location };
        }
        if (try self.parseReturn(allocator, offset)) |statement| return statement;
        if (try self.parseWhile(allocator, offset, depth)) |statement| return statement;
        if (try self.parseDiscard(allocator, offset)) |statement| return statement;
        if (try self.parseConstantDeclaration(allocator, offset)) |constant| {
            return .{ .kind = .{ .constant_declaration = constant }, .location = location };
        }
        if (try self.parseVariableDeclaration(allocator, offset)) |variable| {
            return .{ .kind = .{ .variable_declaration = variable }, .location = location };
        }
        if (try self.parseAssignment(allocator, offset)) |statement| return statement;
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

    fn parseWhile(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_while) orelse return null;
        const condition = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);

        offset.* = position;
        const loop: ast.While = .{ .condition = condition, .body = body };
        return .{ .kind = .{ .@"while" = loop }, .location = keyword.location };
    }

    fn parseDiscard(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const underscore = self.match(&position, .underscore) orelse return null;
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const start = position;
        const discarded = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(start, error.ExpectedCallOrName);
        };
        if (discarded.kind != .call and discarded.kind != .method_call and
            discarded.kind != .identifier)
        {
            return self.fail(start, error.ExpectedCallOrName);
        }

        offset.* = position;
        return .{ .kind = .{ .discard = discarded }, .location = underscore.location };
    }

    fn parseVariableDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.VariableDeclaration {
        var position = offset.*;
        _ = self.match(&position, .keyword_var) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const written_type = try self.parseWrittenType(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .type = written_type, .value = value };
    }

    fn parseAssignment(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const target = (try self.parseExpression(allocator, &position)) orelse return null;
        if (self.match(&position, .equals) == null) return null;
        switch (target.kind) {
            .identifier, .field_access, .index, .dereference => {},
            else => return self.fail(offset.*, error.ExpectedTarget),
        }
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        const assignment: ast.Assignment = .{ .target = target, .value = value };
        return .{ .kind = .{ .assignment = assignment }, .location = target.location };
    }

    fn parseCallStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const call = (try self.parseExpression(allocator, &position)) orelse return null;
        if (call.kind != .call and call.kind != .method_call) return null;

        offset.* = position;
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
        const written_type = try self.parseWrittenType(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const receiver = buildIdentifierExpression(name);
        const anonymous_struct = if (written_type == null)
            try self.parseAnonymousStruct(allocator, &position, receiver)
        else
            null;
        const value = anonymous_struct orelse
            (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .type = written_type, .value = value };
    }

    fn parseWrittenType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        if (self.match(offset, .colon) == null) return null;
        const written_type = (try self.parseExpression(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedType);
        };
        return written_type;
    }

    fn parseAnonymousStruct(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ast.Expression,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_struct) orelse return null;
        const body = try self.parseStructBody(allocator, &position, receiver);

        offset.* = position;
        return .{ .kind = .{ .@"struct" = body }, .location = keyword.location };
    }

    fn parseStructDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.StructDefinition {
        var position = offset.*;
        _ = self.match(&position, .keyword_struct) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const receiver = buildIdentifierExpression(name);
        const body = try self.parseStructBody(allocator, &position, receiver);

        offset.* = position;
        return .{ .name = name.kind.identifier, .body = body };
    }

    fn parseStructBody(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ast.Expression,
    ) ParseError!ast.Struct {
        if (self.match(offset, .colon) == null) return .{ .fields = &.{} };
        return .{ .fields = try self.parseMembers(allocator, offset, receiver) };
    }

    fn parseMembers(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ast.Expression,
    ) ParseError![]ast.Field {
        var position = offset.*;
        const depth = try self.expectBlock(position, 0);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (try self.matchBlockLine(&position, depth, 0)) {
            const location = self.tokens[position].location;
            const method = try self.parseFunctionDefinition(allocator, &position, receiver, depth);
            if (method) |function| {
                const kind: ast.DeclarationKind = .{ .function_definition = function };
                try self.methods.append(allocator, .{ .kind = kind, .location = location });
                continue;
            }
            const field = (try self.parseField(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedField);
            };
            try fields.append(allocator, field);
        }

        offset.* = position;
        return fields.items;
    }

    fn parseField(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Field {
        var position = offset.*;
        const typed_name = (try self.parseTypedName(allocator, &position)) orelse return null;
        var default: ?ast.Expression = null;
        if (self.match(&position, .equals) != null) {
            default = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
        }

        offset.* = position;
        return .{
            .name = typed_name.name,
            .type = typed_name.type,
            .default = default,
            .location = typed_name.location,
        };
    }

    fn parseTypedName(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypedName {
        var position = offset.*;
        const name = self.match(&position, .identifier) orelse return null;
        const typed_name = try self.parseNameType(
            allocator,
            &position,
            name.kind.identifier,
            name.location,
        );

        offset.* = position;
        return typed_name;
    }

    fn parseNameType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        name: []const u8,
        location: token.Location,
    ) ParseError!ast.TypedName {
        var position = offset.*;
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const name_type = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };

        offset.* = position;
        return .{ .name = name, .type = name_type, .location = location };
    }

    fn parseTraitDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TraitDefinition {
        var position = offset.*;
        _ = self.match(&position, .keyword_trait) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        var functions: std.ArrayList(ast.FunctionSignature) = .empty;
        if (self.match(&position, .colon) != null) {
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const parsed = try self.parseFunctionSignature(allocator, &position, null);
                const signature = parsed orelse {
                    return self.fail(position, error.ExpectedFunctionKeyword);
                };
                if (self.tokens[position].kind == .colon) {
                    return self.fail(position, error.TraitFunctionBody);
                }
                try functions.append(allocator, signature);
            }
        }

        offset.* = position;
        return .{ .name = name.kind.identifier, .functions = functions.items };
    }

    fn parseImplementation(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Implementation {
        var position = offset.*;
        _ = self.match(&position, .keyword_impl) orelse return null;
        const trait = (try self.parseNameExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedIdentifier);
        };
        _ = try self.expect(&position, .keyword_for, error.ExpectedFor);
        const implemented = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };
        var count: usize = 0;
        if (self.match(&position, .colon) != null) {
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const location = self.tokens[position].location;
                const definition = try self.parseFunctionDefinition(
                    allocator,
                    &position,
                    implemented,
                    depth,
                );
                var function = definition orelse {
                    return self.fail(position, error.ExpectedFunctionKeyword);
                };
                function.signature.trait = trait;
                const kind: ast.DeclarationKind = .{ .function_definition = function };
                try self.methods.append(allocator, .{ .kind = kind, .location = location });
                count += 1;
            }
        }

        offset.* = position;
        return .{ .trait = trait, .type = implemented, .functions = count };
    }

    fn parseImport(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Import {
        var position = offset.*;
        _ = self.match(&position, .keyword_import) orelse return null;
        const trait = (try self.parseNameExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedIdentifier);
        };

        offset.* = position;
        return .{ .trait = trait };
    }

    fn expectBlock(self: *Parser, offset: usize, outer: usize) ParseError!usize {
        const first = self.tokens[offset];
        if (first.kind != .indent or first.kind.indent <= outer) {
            return self.fail(offset, error.ExpectedBlock);
        }
        return first.kind.indent;
    }

    fn matchBlockLine(self: *Parser, offset: *usize, depth: usize, outer: usize) ParseError!bool {
        const current = self.tokens[offset.*];
        if (current.kind != .indent) return false;
        if (current.kind.indent < depth) {
            if (current.kind.indent <= outer) return false;
            return self.fail(offset.*, error.InconsistentIndentation);
        }
        if (current.kind.indent > depth) {
            return self.fail(offset.*, error.UnexpectedIndentation);
        }
        offset.* += 1;
        return true;
    }

    fn parseExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .keyword_or, .@"or" }};
        return self.parseBinary(allocator, offset, operators, parseAnd);
    }

    fn parseAnd(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .keyword_and, .@"and" }};
        return self.parseBinary(allocator, offset, operators, parseComparison);
    }

    fn parseComparison(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const left = (try self.parseOrElse(allocator, &position)) orelse return null;
        const operator_token = self.tokens[position];
        const operator = findOperator(comparison_operators, operator_token.kind) orelse {
            offset.* = position;
            return left;
        };
        position += 1;
        const right = (try self.parseOrElse(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        if (findOperator(comparison_operators, self.tokens[position].kind) != null) {
            return self.fail(position, error.ChainedComparison);
        }

        offset.* = position;
        return try buildBinary(allocator, operator, operator_token.location, left, right);
    }

    fn parseOrElse(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .keyword_orelse, .@"orelse" }};
        return self.parseBinary(allocator, offset, operators, parseBitwiseOr);
    }

    fn parseBitwiseOr(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .pipe, .bitwise_or }};
        return self.parseBinary(allocator, offset, operators, parseBitwiseExclusiveOr);
    }

    fn parseBitwiseExclusiveOr(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .caret, .bitwise_exclusive_or }};
        return self.parseBinary(allocator, offset, operators, parseBitwiseAnd);
    }

    fn parseBitwiseAnd(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .ampersand, .bitwise_and }};
        return self.parseBinary(allocator, offset, operators, parseShift);
    }

    fn parseShift(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{
            .{ .shift_left, .shift_left },
            .{ .shift_right, .shift_right },
        };
        return self.parseBinary(allocator, offset, operators, parseAdditive);
    }

    fn parseAdditive(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{ .{ .plus, .add }, .{ .minus, .subtract } };
        return self.parseBinary(allocator, offset, operators, parseMultiplicative);
    }

    fn parseMultiplicative(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{
            .{ .asterisk, .multiply },
            .{ .slash, .divide },
            .{ .percent, .remainder },
        };
        return self.parseBinary(allocator, offset, operators, parsePrefix);
    }

    fn parseBinary(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        comptime operators: []const OperatorToken,
        comptime parseStronger: fn (
            *Parser,
            std.mem.Allocator,
            *usize,
        ) ParseError!?ast.Expression,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        var left = (try parseStronger(self, allocator, &position)) orelse return null;
        while (findOperator(operators, self.tokens[position].kind)) |operator| {
            const location = self.tokens[position].location;
            position += 1;
            const right = (try parseStronger(self, allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
            left = try buildBinary(allocator, operator, location, left, right);
        }

        offset.* = position;
        return left;
    }

    fn parsePrefix(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const current = self.tokens[position];
        const operator = findUnaryOperator(current.kind);
        if (operator == null and current.kind != .ampersand) {
            return self.parsePostfix(allocator, offset);
        }
        const next = self.tokens[position + 1].kind;
        const literal = next == .integer_literal or next == .float_literal;
        if (operator == .negate and literal) return self.parsePostfix(allocator, offset);
        position += 1;
        const operand = try allocator.create(ast.Expression);
        operand.* = (try self.parsePrefix(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        const unary_operator = operator orelse {
            return .{ .kind = .{ .address_of = operand }, .location = current.location };
        };
        const unary: ast.Unary = .{ .operator = unary_operator, .operand = operand };
        return .{ .kind = .{ .unary = unary }, .location = current.location };
    }

    fn parsePostfix(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        var expression = (try self.parseOperand(allocator, &position)) orelse return null;
        while (true) {
            if (isLiteralType(expression) and self.tokens[position].kind == .left_brace) {
                const literal_type = try allocator.create(ast.Expression);
                literal_type.* = expression;
                expression = try self.parseCompositeLiteral(allocator, &position, literal_type);
            } else if (self.match(&position, .dot) != null) {
                expression = try self.parseMember(allocator, &position, expression);
            } else if (try self.parseSubscript(allocator, &position, expression)) |subscript| {
                expression = subscript;
            } else break;
        }

        offset.* = position;
        return expression;
    }

    fn parseOperand(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        if (try self.parseStructLiteral(allocator, offset)) |literal| return literal;
        if (self.tokens[offset.*].kind == .left_brace) {
            return try self.parseCompositeLiteral(allocator, offset, null);
        }
        if (try self.parseBrackets(allocator, offset)) |expression| return expression;
        if (try self.parseParentheses(allocator, offset)) |expression| return expression;
        if (try self.parsePointerType(allocator, offset)) |pointer_type| return pointer_type;
        if (try self.parseOptionalType(allocator, offset)) |optional_type| return optional_type;
        if (try self.parseFunctionType(allocator, offset)) |function_type| return function_type;
        if (try self.parseCall(allocator, offset)) |call| return call;
        if (try self.parseNameExpression(allocator, offset)) |name| return name;
        if (try self.parseNegation(allocator, offset)) |negation| return negation;
        return self.parseLiteral(offset);
    }

    fn parseStructLiteral(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const dot = self.match(&position, .dot) orelse return null;
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        const arguments = try self.parseArguments(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return .{
            .kind = .{ .struct_literal = .{ .arguments = arguments } },
            .location = dot.location,
        };
    }

    fn parseCompositeLiteral(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        literal_type: ?*ast.Expression,
    ) ParseError!ast.Expression {
        var position = offset.*;
        const brace = try self.expect(&position, .left_brace, error.ExpectedLeftBrace);
        var elements: std.ArrayList(ast.Expression) = .empty;
        while (self.tokens[position].kind != .right_brace) {
            const element = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
            try elements.append(allocator, element);
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_brace, error.ExpectedRightBrace);

        offset.* = position;
        const location = if (literal_type) |written| written.location else brace.location;
        const literal: ast.CompositeLiteral = .{ .type = literal_type, .elements = elements.items };
        return .{ .kind = .{ .composite_literal = literal }, .location = location };
    }

    fn parseBrackets(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const bracket = self.match(&position, .left_bracket) orelse return null;
        if (self.match(&position, .underscore) != null) {
            _ = try self.expect(&position, .right_bracket, error.ExpectedRightBracket);
            const array_type = try self.parseArrayType(allocator, &position, null);
            offset.* = position;
            return .{ .kind = .{ .array_type = array_type }, .location = bracket.location };
        }
        if (self.match(&position, .right_bracket) != null) {
            const constant = self.match(&position, .keyword_const) != null;
            const slice_type = try self.parseSliceType(allocator, &position, constant);
            offset.* = position;
            return .{ .kind = .{ .slice_type = slice_type }, .location = bracket.location };
        }
        const length = try allocator.create(ast.Expression);
        length.* = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedArrayLength);
        };
        if (self.tokens[position].kind == .comma) {
            return self.fail(offset.* + 1, error.ExpectedArrayLength);
        }
        _ = try self.expect(&position, .right_bracket, error.ExpectedRightBracket);
        const array_type = try self.parseArrayType(allocator, &position, length);

        offset.* = position;
        return .{ .kind = .{ .array_type = array_type }, .location = bracket.location };
    }

    fn parseParentheses(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const parenthesis = self.match(&position, .left_parenthesis) orelse return null;
        var elements: std.ArrayList(ast.Expression) = .empty;
        var trailing_comma = false;
        while (self.tokens[position].kind != .right_parenthesis) {
            const element = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
            try elements.append(allocator, element);
            trailing_comma = self.match(&position, .comma) != null;
            if (!trailing_comma) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        if (elements.items.len == 1 and !trailing_comma) {
            offset.* = position;
            return elements.items[0];
        }
        if (elements.items.len < 2) return self.fail(offset.*, error.TooFewTupleElements);

        offset.* = position;
        const tuple_type: ast.TupleType = .{ .elements = elements.items };
        return .{ .kind = .{ .tuple_type = tuple_type }, .location = parenthesis.location };
    }

    fn parseArrayType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        length: ?*ast.Expression,
    ) ParseError!ast.ArrayType {
        const element = try allocator.create(ast.Expression);
        element.* = (try self.parseOperand(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedType);
        };
        return .{ .length = length, .element = element };
    }

    fn isTypeStart(self: *Parser, offset: usize) bool {
        return switch (self.tokens[offset].kind) {
            .identifier, .asterisk, .question_mark, .left_parenthesis => true,
            .keyword_fn => self.tokens[offset + 1].kind == .left_parenthesis,
            .left_bracket => self.tokens[offset + 1].kind != .dot_dot,
            else => false,
        };
    }

    fn parseSliceType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        constant: bool,
    ) ParseError!ast.SliceType {
        const element = try allocator.create(ast.Expression);
        element.* = (try self.parseOperand(allocator, offset)) orelse {
            return self.fail(offset.*, error.ExpectedType);
        };
        return .{ .constant = constant, .element = element };
    }

    fn parsePointerType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const asterisk = self.match(&position, .asterisk) orelse return null;
        const many = self.match(&position, .keyword_many) != null;
        const constant = self.match(&position, .keyword_const) != null;
        const target = try allocator.create(ast.Expression);
        target.* = (try self.parseOperand(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };
        const pointer_type: ast.PointerType = .{
            .many = many,
            .constant = constant,
            .target = target,
        };

        offset.* = position;
        return .{ .kind = .{ .pointer_type = pointer_type }, .location = asterisk.location };
    }

    fn parseOptionalType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const question_mark = self.match(&position, .question_mark) orelse return null;
        const child = try allocator.create(ast.Expression);
        child.* = (try self.parseOperand(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };

        offset.* = position;
        const optional_type: ast.OptionalType = .{ .child = child };
        return .{ .kind = .{ .optional_type = optional_type }, .location = question_mark.location };
    }

    fn parseFunctionType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_fn) orelse return null;
        _ = self.match(&position, .left_parenthesis) orelse return null;
        var parameters: std.ArrayList(ast.Expression) = .empty;
        while (self.tokens[position].kind != .right_parenthesis) {
            const parameter = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
            try parameters.append(allocator, parameter);
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const return_type = try allocator.create(ast.Expression);
        return_type.* = try self.parseReturnType(allocator, &position);

        offset.* = position;
        const function_type: ast.FunctionType = .{
            .parameters = parameters.items,
            .return_type = return_type,
        };
        return .{ .kind = .{ .function_type = function_type }, .location = keyword.location };
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
        const path = try self.parsePath(allocator, &position, first);

        offset.* = position;
        return buildNameExpression(path, first.location);
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

    fn parseNegation(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const minus = self.match(&position, .minus) orelse return null;
        const operand = self.parseLiteral(&position) orelse {
            return self.fail(position, error.ExpectedNumber);
        };
        if (operand.kind != .integer_literal and operand.kind != .float_literal) {
            return self.fail(position - 1, error.ExpectedNumber);
        }
        const stored = try allocator.create(ast.Expression);
        stored.* = operand;
        offset.* = position;
        return .{ .kind = .{ .negation = stored }, .location = minus.location };
    }

    fn parseLiteral(self: *Parser, offset: *usize) ?ast.Expression {
        const current = self.tokens[offset.*];
        const kind: ast.ExpressionKind = switch (current.kind) {
            .integer_literal => |literal| .{ .integer_literal = literal },
            .float_literal => |literal| .{ .float_literal = literal },
            .keyword_true => .{ .boolean_literal = true },
            .keyword_false => .{ .boolean_literal = false },
            .keyword_undefined => .undefined,
            .keyword_null => .null,
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
    ) ParseError![]ast.Argument {
        var position = offset.*;
        var arguments: std.ArrayList(ast.Argument) = .empty;
        while (self.tokens[position].kind != .right_parenthesis) {
            try arguments.append(allocator, try self.parseArgument(allocator, &position));
            if (self.match(&position, .comma) == null) break;
        }

        offset.* = position;
        return arguments.items;
    }

    fn parseArgument(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Argument {
        var position = offset.*;
        const first = self.tokens[position];
        var name: ?[]const u8 = null;
        if (first.kind == .identifier and self.tokens[position + 1].kind == .equals) {
            name = first.kind.identifier;
            position += 2;
        }
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name, .value = value, .location = first.location };
    }

    fn parseMember(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        value: ast.Expression,
    ) ParseError!ast.Expression {
        const stored = try allocator.create(ast.Expression);
        stored.* = value;
        if (self.match(offset, .asterisk) != null) {
            return .{ .kind = .{ .dereference = stored }, .location = value.location };
        }
        if (self.match(offset, .question_mark) != null) {
            return .{ .kind = .{ .unwrap = stored }, .location = value.location };
        }
        const field = try self.expect(offset, .identifier, error.ExpectedIdentifier);
        if (self.match(offset, .left_parenthesis) != null) {
            const arguments = try self.parseArguments(allocator, offset);
            _ = try self.expect(offset, .right_parenthesis, error.ExpectedRightParenthesis);
            const call: ast.MethodCall = .{
                .receiver = stored,
                .name = field.kind.identifier,
                .name_location = field.location,
                .arguments = arguments,
            };
            return .{ .kind = .{ .method_call = call }, .location = value.location };
        }
        const access: ast.FieldAccess = .{
            .value = stored,
            .field = field.kind.identifier,
            .field_location = field.location,
        };
        return .{ .kind = .{ .field_access = access }, .location = value.location };
    }

    fn parseSubscript(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        value: ast.Expression,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        _ = self.match(&position, .left_bracket) orelse return null;
        const start = try self.parseBound(allocator, &position);
        const stored = try allocator.create(ast.Expression);
        stored.* = value;
        if (self.match(&position, .dot_dot) == null) {
            const index = start orelse return self.fail(position, error.ExpectedExpression);
            _ = try self.expect(&position, .right_bracket, error.ExpectedRightBracket);
            offset.* = position;
            const indexing: ast.Index = .{ .value = stored, .index = index };
            return .{ .kind = .{ .index = indexing }, .location = value.location };
        }
        const end = try self.parseBound(allocator, &position);
        _ = try self.expect(&position, .right_bracket, error.ExpectedRightBracket);

        offset.* = position;
        const slice: ast.Slice = .{ .value = stored, .start = start, .end = end };
        return .{ .kind = .{ .slice = slice }, .location = value.location };
    }

    fn parseBound(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?*ast.Expression {
        const bound = (try self.parseExpression(allocator, offset)) orelse return null;
        const stored = try allocator.create(ast.Expression);
        stored.* = bound;
        return stored;
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
    TraitFunctionBody,
    ExpectedFor,
    ExpectedArrow,
    ExpectedType,
    ExpectedEquals,
    ExpectedStatement,
    ExpectedExpression,
    ExpectedNumber,
    ExpectedCallOrName,
    ExpectedTarget,
    ExpectedRightBracket,
    ExpectedLeftBrace,
    ExpectedRightBrace,
    ExpectedArrayLength,
    TooFewTupleElements,
    ExpectedField,
    ParameterDefault,
    ExpectedBlock,
    UnexpectedIndentation,
    InconsistentIndentation,
    ChainedComparison,
};

const OperatorToken = struct {
    std.meta.Tag(token.TokenKind),
    ast.BinaryOperator,
};

fn findOperator(operators: []const OperatorToken, kind: token.TokenKind) ?ast.BinaryOperator {
    for (operators) |operator| {
        if (operator[0] == std.meta.activeTag(kind)) return operator[1];
    }
    return null;
}

fn findUnaryOperator(kind: token.TokenKind) ?ast.UnaryOperator {
    return switch (kind) {
        .minus => .negate,
        .exclamation_mark => .not,
        .tilde => .bitwise_not,
        else => null,
    };
}

fn buildBinary(
    allocator: std.mem.Allocator,
    operator: ast.BinaryOperator,
    operator_location: token.Location,
    left: ast.Expression,
    right: ast.Expression,
) std.mem.Allocator.Error!ast.Expression {
    const stored_left = try allocator.create(ast.Expression);
    stored_left.* = left;
    const stored_right = try allocator.create(ast.Expression);
    stored_right.* = right;
    const binary: ast.Binary = .{
        .operator = operator,
        .operator_location = operator_location,
        .left = stored_left,
        .right = stored_right,
    };
    return .{ .kind = .{ .binary = binary }, .location = left.location };
}

fn isLiteralType(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .array_type, .tuple_type, .identifier, .path_expression => true,
        else => false,
    };
}

fn buildIdentifierExpression(name: token.Token) ast.Expression {
    const identifier: ast.Identifier = .{ .name = name.kind.identifier };
    return .{ .kind = .{ .identifier = identifier }, .location = name.location };
}

fn buildNameExpression(path: ast.Path, location: token.Location) ast.Expression {
    if (path.len == 1) {
        return .{ .kind = .{ .identifier = .{ .name = path[0] } }, .location = location };
    }
    return .{ .kind = .{ .path_expression = .{ .path = path } }, .location = location };
}

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
        error.TraitFunctionBody => "functions of a trait have no body",
        error.ExpectedFor => "expected 'for'",
        error.ExpectedArrow => "expected '->'",
        error.ExpectedType => "expected a type",
        error.ExpectedEquals => "expected '='",
        error.ExpectedStatement => "expected a statement",
        error.ExpectedExpression => "expected an expression",
        error.ExpectedNumber => "expected a number after '-'",
        error.ExpectedCallOrName => "expected a call or a name",
        error.ExpectedTarget => "expected a name, a field, an element or a dereference before '='",
        error.ExpectedRightBracket => "expected ']'",
        error.ExpectedLeftBrace => "expected '{'",
        error.ExpectedRightBrace => "expected '}'",
        error.ExpectedArrayLength => "expected one array length",
        error.TooFewTupleElements => "a tuple has at least two elements",
        error.ExpectedField => "expected a field or a function",
        error.ParameterDefault => "parameters cannot have default values, use a struct parameter with field defaults",
        error.ExpectedBlock => "expected an indented block",
        error.UnexpectedIndentation => "unexpected indentation",
        error.InconsistentIndentation => "indentation does not match any outer level",
        error.ChainedComparison => "comparisons cannot be chained, use and",
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
    var lexer = @import("lexer.zig").Lexer.init("external fn stdout_write(text: []const u8)\nfn main(): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: u8) -> i32: return 1");
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
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32,) -> i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.signature.parameters.len);
}

test "parseParameter: parses an underscore as a discarded parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f(_: i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqualStrings("_", parameter.name);
    try std.testing.expectEqualStrings("i32", parameter.type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, parameter.location);
}

test "parseParameter: rejects a default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn draw(width: i32 = 1): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseParameter: rejects a default value of an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn draw(width: i32 = 1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, parser.failure.?.location.?);
}

test "parseReturnType: reads a written return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() -> i32: return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const return_type = module.declarations[0].kind.function_definition.signature.return_type;
    try std.testing.expectEqualStrings("i32", return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, return_type.location);
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

test "parseReturnType: rejects an arrow without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() ->: return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a type without an arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a slice type without an arrow in a function without a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn read() []u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a pointer type without an arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn read() *u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects an optional type without an arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn find() ?i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a tuple type without an arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn pair() (i32, bool)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
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

test "parseIndentedBlock: ends nested blocks at the depth of an enclosing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while one:\n        while two:\n            step()\n    done()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const inner = body[0].kind.@"while".body[0].kind.@"while";
    try std.testing.expectEqualStrings("two", inner.condition.kind.identifier.name);
    try std.testing.expectEqual(1, inner.body.len);
    try std.testing.expect(body[1].kind == .call);
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

test "parseStatement: parses a constant inside a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const limit: i32 = 5\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const constant = statement.kind.constant_declaration;
    try std.testing.expectEqualStrings("limit", constant.name);
    try std.testing.expectEqualStrings("i32", constant.type.?.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseReturn: parses return with a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() -> u8:\n    return 42\n");
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

test "parseWhile: parses a condition and an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running:\n        step()\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const loop = statement.kind.@"while";
    try std.testing.expectEqualStrings("running", loop.condition.kind.identifier.name);
    try std.testing.expectEqual(2, loop.body.len);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseWhile: parses an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): while running: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expectEqual(1, loop.body.len);
    try std.testing.expect(loop.body[0].kind == .call);
}

test "parseWhile: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): while running step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
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

test "parseDiscard: parses a discarded name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: i32): _ = value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("value", discarded.kind.identifier.name);
}

test "parseDiscard: parses a discarded method call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = card.count()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("count", discarded.kind.method_call.name);
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

    try std.testing.expectError(error.ExpectedCallOrName, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseDiscard: rejects a discarded field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = make().x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCallOrName, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseVariableDeclaration: parses a variable with a written type and undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    var count: i32 = undefined\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const variable = module.declarations[0].kind.function_definition.body[0].kind.variable_declaration;
    try std.testing.expectEqualStrings("count", variable.name);
    try std.testing.expectEqualStrings("i32", variable.type.?.kind.identifier.name);
    try std.testing.expect(variable.value.kind == .undefined);
}

test "parseVariableDeclaration: rejects a missing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): var count: i32 =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, parser.failure.?.location.?);
}

test "parseAssignment: parses an assignment to a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): point.x = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const assignment = module.declarations[0].kind.function_definition.body[0].kind.assignment;
    try std.testing.expectEqualStrings("x", assignment.target.kind.field_access.field);
    try std.testing.expectEqualStrings("1", assignment.value.kind.integer_literal.text);
}

test "parseAssignment: parses an assignment to an element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): values[0] = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const target = module.declarations[0].kind.function_definition.body[0].kind.assignment.target;
    try std.testing.expectEqualStrings("values", target.kind.index.value.kind.identifier.name);
    try std.testing.expectEqualStrings("0", target.kind.index.index.kind.integer_literal.text);
}

test "parseAssignment: parses an assignment through a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): pointer.* = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const target = module.declarations[0].kind.function_definition.body[0].kind.assignment.target;
    try std.testing.expectEqualStrings("pointer", target.kind.dereference.kind.identifier.name);
}

test "parseAssignment: rejects a call as the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): make() = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseAssignment: rejects an unwrap as the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): maybe.? = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
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
    try std.testing.expectEqualStrings("1", call.arguments[0].value.kind.integer_literal.text);
    try std.testing.expectEqual(true, call.arguments[1].value.kind.boolean_literal);
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

test "parseCallStatement: rejects a field access as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): make().x");
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
    var lexer = @import("lexer.zig").Lexer.init("const write = mn_runtime_stdout_write");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("mn_runtime_stdout_write", constant.value.kind.identifier.name);
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

test "parseConstantDeclaration: parses a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const limit: i32 = 5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("i32", constant.type.?.kind.identifier.name);
    try std.testing.expectEqualStrings("5", constant.value.kind.integer_literal.text);
}

test "parseConstantDeclaration: rejects a colon without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const limit: = 5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseConstantDeclaration: rejects an anonymous struct with a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Point: type = struct:\n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseConstantDeclaration: rejects a missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write mn_runtime_stdout_write");
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

test "parseAnonymousStruct: parses fields in an indented block" {
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
    try std.testing.expectEqualStrings("y", fields[1].name);
}

test "parseAnonymousStruct: parses a struct without fields" {
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

test "parseAnonymousStruct: rejects a struct that is not the value of a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(point: struct): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseStructDefinition: parses fields in an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: i32\n    y: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.struct_definition;
    const fields = definition.body.fields;
    try std.testing.expectEqualStrings("Point", definition.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, module.declarations[0].location);
    try std.testing.expectEqual(2, fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqualStrings("i32", fields[0].type.kind.identifier.name);
    try std.testing.expectEqualStrings("y", fields[1].name);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, fields[1].location);
}

test "parseStructDefinition: parses a struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Marker\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(0, module.declarations[0].kind.struct_definition.body.fields.len);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseStructDefinition: rejects a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct:\n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 7 }, parser.failure.?.location.?);
}

test "parseMembers: rejects a field on the line of the colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Meters: value: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseMembers: rejects a line that is not a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseMembers: lists a method of a struct as a declaration on the struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card:\n    question: []const u8\n\n    fn show(self: Self) -> []const u8: return self.question");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations[0].kind.struct_definition.body.fields.len);
    const function = module.declarations[1].kind.function_definition;
    try std.testing.expectEqualStrings("Card", function.signature.receiver.?.kind.identifier.name);
    try std.testing.expectEqualStrings("show", function.signature.name);
    const parameter = function.signature.parameters[0];
    try std.testing.expectEqualStrings("self", parameter.name);
    try std.testing.expectEqualStrings("Self", parameter.type.kind.identifier.name);
    const value = function.body[0].kind.@"return".?.kind.field_access.value;
    try std.testing.expectEqualStrings("self", value.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, module.declarations[1].location);
}

test "parseMembers: parses a field after a method with an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card:\n    fn show(self: Self) -> []const u8:\n        return self.question\n    question: []const u8\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations[0].kind.struct_definition.body.fields.len);
    try std.testing.expectEqual(1, module.declarations[1].kind.function_definition.body.len);
    try std.testing.expectEqualStrings("main", module.declarations[2].kind.function_definition.signature.name);
}

test "parseMembers: lists a method of an anonymous struct as a declaration on the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Card = struct:\n    fn new() -> Card: return Card()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const signature = module.declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", signature.receiver.?.kind.identifier.name);
    try std.testing.expectEqualStrings("new", signature.name);
}

test "parseField: parses a default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: i32 = 0\n    y: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const fields = module.declarations[0].kind.struct_definition.body.fields;
    try std.testing.expectEqualStrings("0", fields[0].default.?.kind.integer_literal.text);
    try std.testing.expectEqual(null, fields[1].default);
}

test "parseField: rejects an equals sign without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: i32 =\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left i32) -> i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a name without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x:\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: ) -> i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseTraitDefinition: parses the functions of a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("trait Shape:\n    fn area(self: Self) -> i32\n    fn grow(self: Self, amount: i32) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.trait_definition;
    try std.testing.expectEqualStrings("Shape", definition.name);
    try std.testing.expectEqual(2, definition.functions.len);
    try std.testing.expectEqualStrings("self", definition.functions[1].parameters[0].name);
    try std.testing.expectEqualStrings("amount", definition.functions[1].parameters[1].name);
    try std.testing.expectEqual(null, definition.functions[0].receiver);
}

test "parseTraitDefinition: parses a function without a Self parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("trait Shape:\n    fn new() -> Self");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[0].kind.trait_definition.functions[0];
    try std.testing.expectEqual(0, function.parameters.len);
    try std.testing.expectEqualStrings("Self", function.return_type.kind.identifier.name);
}

test "parseTraitDefinition: rejects a function with a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("trait Shape:\n    fn area(self: Self) -> i32: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.TraitFunctionBody, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 31 }, parser.failure.?.location.?);
}

test "parseImplementation: lists the functions of an implementation as declarations on its type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("impl Shape for []const u8:\n    fn area(self: Self) -> i32: return 0");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const implementation = module.declarations[0].kind.implementation;
    try std.testing.expectEqualStrings("Shape", implementation.trait.kind.identifier.name);
    try std.testing.expect(implementation.type.kind.slice_type.constant);
    try std.testing.expectEqual(1, implementation.functions);
    const signature = module.declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Shape", signature.trait.?.kind.identifier.name);
    try std.testing.expect(signature.receiver.?.kind == .slice_type);
}

test "parseImplementation: rejects a missing for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("impl Shape Square:");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedFor, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseImport: parses the path of a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import shapes::Shape");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const path = module.declarations[0].kind.import.trait.kind.path_expression.path;
    try std.testing.expectEqualStrings("shapes", path[0]);
    try std.testing.expectEqualStrings("Shape", path[1]);
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

test "expectBlock: rejects a nested block that is not indented more than its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running:\n    step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
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

test "matchBlockLine: rejects a dedent between two nested levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running:\n        step()\n      stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InconsistentIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 1 }, parser.failure.?.location.?);
}

test "parseExpression: parses each literal kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() -> u8: return 0xff_u8\nfn two() -> f64: return 2.5\nfn three() -> bool: return true\nfn four() -> bool: return false");
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
    var lexer = @import("lexer.zig").Lexer.init("fn greeting() -> []const u8: return \"hello\"");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("hello", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.string_literal);
}

test "parseExpression: parses null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn nothing() -> ?i32: return null");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expect(value.kind == .null);
}

test "parseExpression: parses a parameter reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn same(value: i32) -> i32: return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("value", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.identifier.name);
}

test "parseExpression: binds and tighter than or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return a or b and c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"or", value.kind.binary.operator);
    try std.testing.expectEqualStrings("a", value.kind.binary.left.kind.identifier.name);
    try std.testing.expectEqual(ast.BinaryOperator.@"and", value.kind.binary.right.kind.binary.operator);
}

test "parseExpression: parses operators in conditions, arguments and literal elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while a < b: log(a + b, {a * b})");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expectEqual(ast.BinaryOperator.less_than, loop.condition.kind.binary.operator);
    const arguments = loop.body[0].kind.call.kind.call.arguments;
    try std.testing.expectEqual(ast.BinaryOperator.add, arguments[0].value.kind.binary.operator);
    const element = arguments[1].value.kind.composite_literal.elements[0];
    try std.testing.expectEqual(ast.BinaryOperator.multiply, element.kind.binary.operator);
}

test "parseAnd: binds a prefix operator tighter than and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return !a and b");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"and", value.kind.binary.operator);
    try std.testing.expectEqual(ast.UnaryOperator.not, value.kind.binary.left.kind.unary.operator);
    try std.testing.expectEqualStrings("b", value.kind.binary.right.kind.identifier.name);
}

test "parseComparison: binds bitwise operators tighter than a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return a | b == c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.equal, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, value.kind.binary.operator_location);
}

test "parseComparison: binds orelse tighter than a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return a orelse b == c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.equal, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.left.kind.binary.operator);
}

test "parseComparison: rejects a chained comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return a < b < c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ChainedComparison, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, parser.failure.?.location.?);
}

test "parseComparison: rejects a chained equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return a == b != c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ChainedComparison, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, parser.failure.?.location.?);
}

test "parseComparison: parses a comparison in parentheses as an operand of a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return (a < b) == c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.equal, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.less_than, value.kind.binary.left.kind.binary.operator);
}

test "parseOrElse: rejects return as the fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a orelse return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, parser.failure.?.location.?);
}

test "parseOrElse: binds bitwise or tighter than orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a | b orelse c | d");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.right.kind.binary.operator);
}

test "parseOrElse: groups a chain of orelse from the left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a orelse b orelse c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
}

test "parseBitwiseOr: binds exclusive or tighter than or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a | b ^ c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_exclusive_or, value.kind.binary.right.kind.binary.operator);
}

test "parseBitwiseExclusiveOr: binds and tighter than exclusive or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a ^ b & c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_exclusive_or, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_and, value.kind.binary.right.kind.binary.operator);
}

test "parseBitwiseAnd: binds shifts tighter than and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a & b << c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_and, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.shift_left, value.kind.binary.right.kind.binary.operator);
}

test "parseShift: binds addition tighter than a shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a + b >> c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.shift_right, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
}

test "parseAdditive: binds multiplication tighter than addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a + b * c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.operator);
    try std.testing.expectEqualStrings("a", value.kind.binary.left.kind.identifier.name);
    try std.testing.expectEqual(ast.BinaryOperator.multiply, value.kind.binary.right.kind.binary.operator);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, value.location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, value.kind.binary.operator_location);
}

test "parseAdditive: groups operators of one level from the left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a - b - c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.subtract, value.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
    const inner = value.kind.binary.left.kind.binary;
    try std.testing.expectEqualStrings("a", inner.left.kind.identifier.name);
    try std.testing.expectEqualStrings("b", inner.right.kind.identifier.name);
}

test "parseMultiplicative: binds a prefix operator tighter than multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -a * b % c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.remainder, value.kind.binary.operator);
    const product = value.kind.binary.left.kind.binary;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, product.operator);
    try std.testing.expectEqual(ast.UnaryOperator.negate, product.left.kind.unary.operator);
}

test "parseBinary: rejects an operator without a right operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a +\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parsePrefix: parses a minus before a name as a negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -limit");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.UnaryOperator.negate, value.kind.unary.operator);
    try std.testing.expectEqualStrings("limit", value.kind.unary.operand.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, value.location);
}

test "parsePrefix: keeps a minus before a number as part of the literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a - -5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.subtract, value.kind.binary.operator);
    try std.testing.expectEqualStrings("5", value.kind.binary.right.kind.negation.kind.integer_literal.text);
}

test "parsePrefix: parses a prefix operator on a prefix operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return ~-a");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.UnaryOperator.bitwise_not, value.kind.unary.operator);
    try std.testing.expectEqual(ast.UnaryOperator.negate, value.kind.unary.operand.kind.unary.operator);
}

test "parsePrefix: binds a field access tighter than a prefix operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -point.x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.UnaryOperator.negate, value.kind.unary.operator);
    try std.testing.expectEqualStrings("x", value.kind.unary.operand.kind.field_access.field);
}

test "parsePrefix: parses an ampersand before a name as an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> *i32: return &value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("value", value.kind.address_of.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
}

test "parsePrefix: takes the address of an element instead of indexing an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> *i32: return &values[1]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const element = value.kind.address_of.kind.index;
    try std.testing.expectEqualStrings("values", element.value.kind.identifier.name);
}

test "parsePrefix: binds indexing tighter than a minus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -values[1]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.UnaryOperator.negate, value.kind.unary.operator);
    try std.testing.expectEqualStrings("values", value.kind.unary.operand.kind.index.value.kind.identifier.name);
}

test "parsePrefix: parses an ampersand after a bitwise and as an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return mask & &value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_and, value.kind.binary.operator);
    try std.testing.expectEqualStrings("value", value.kind.binary.right.kind.address_of.kind.identifier.name);
}

test "parsePrefix: applies a method call after a negative literal to the literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -5.abs()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const call = value.kind.method_call;
    try std.testing.expectEqualStrings("abs", call.name);
    try std.testing.expectEqualStrings("5", call.receiver.kind.negation.kind.integer_literal.text);
}

test "parsePrefix: rejects an operator without an operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool: return !");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parsePostfix: parses a chain of field accesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(line.start.x)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, outer.location);
    try std.testing.expectEqualStrings("x", outer.kind.field_access.field);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, outer.kind.field_access.field_location);
    const inner = outer.kind.field_access.value.kind.field_access;
    try std.testing.expectEqualStrings("start", inner.field);
    try std.testing.expectEqualStrings("line", inner.value.kind.identifier.name);
}

test "parsePostfix: parses a field access on a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(make().x)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const access = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.field_access;
    try std.testing.expectEqualStrings("x", access.field);
    try std.testing.expectEqualStrings("make", access.value.kind.call.callee.identifier.name);
}

test "parsePostfix: parses an element of an element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return grid[1][2]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("2", value.kind.index.index.kind.integer_literal.text);
    const inner = value.kind.index.value.kind.index;
    try std.testing.expectEqualStrings("grid", inner.value.kind.identifier.name);
    try std.testing.expectEqualStrings("1", inner.index.kind.integer_literal.text);
}

test "parsePostfix: parses a field of an element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return points[1].x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("x", value.kind.field_access.field);
    try std.testing.expectEqualStrings("points", value.kind.field_access.value.kind.index.value.kind.identifier.name);
}

test "parsePostfix: parses a field after a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return pointer.*.x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("x", value.kind.field_access.field);
    try std.testing.expectEqualStrings("pointer", value.kind.field_access.value.kind.dereference.kind.identifier.name);
}

test "parsePostfix: binds an unwrap tighter than a prefix operator and before a field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return -value.?.count");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const access = value.kind.unary.operand.kind.field_access;
    try std.testing.expectEqualStrings("count", access.field);
    try std.testing.expectEqualStrings("value", access.value.kind.unwrap.kind.identifier.name);
}

test "parseStructLiteral: parses the fields of a struct literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Point: return .(x = 1, y = 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.kind.struct_literal.arguments.len);
    try std.testing.expectEqualStrings("y", value.kind.struct_literal.arguments[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, value.location);
}

test "parseStructLiteral: rejects a dot without a parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Point: return .x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, parser.failure.?.location.?);
}

test "parseCompositeLiteral: parses an array literal over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values: [2]i32 = {\n    1,\n    2,\n}\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(null, literal.type);
    try std.testing.expectEqual(2, literal.elements.len);
    try std.testing.expectEqualStrings("2", literal.elements[1].kind.integer_literal.text);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseCompositeLiteral: parses the array type written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values = [3]i32{1, 2, 3}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    const literal = value.kind.composite_literal;
    try std.testing.expectEqualStrings("3", literal.type.?.kind.array_type.length.?.kind.integer_literal.text);
    try std.testing.expectEqual(3, literal.elements.len);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, value.location);
}

test "parseCompositeLiteral: parses the tuple type written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const pair = (i32, bool){1, true}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(2, literal.type.?.kind.tuple_type.elements.len);
    try std.testing.expectEqual(true, literal.elements[1].kind.boolean_literal);
}

test "parseCompositeLiteral: parses empty braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values: [0]i32 = {}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(0, literal.elements.len);
}

test "parseCompositeLiteral: parses an array literal followed by a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take([2]i32{1, 2}[..])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    const slice = call.arguments[0].value.kind.slice;
    try std.testing.expectEqual(2, slice.value.kind.composite_literal.elements.len);
}

test "parseCompositeLiteral: rejects a missing closing brace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values: [2]i32 = {1, 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBrace, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, parser.failure.?.location.?);
}

test "parseCompositeLiteral: parses a name written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Values: return Values{1, 2}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Values", value.kind.composite_literal.type.?.kind.identifier.name);
    try std.testing.expectEqual(2, value.kind.composite_literal.elements.len);
}

test "parseCompositeLiteral: parses a path written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> pairs::Pair: return pairs::Pair{1, true}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.kind.composite_literal.type.?.kind.path_expression.path.len);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, value.location);
}

test "parseBrackets: parses an array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const cards: [2]Card = other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const array_type = module.declarations[0].kind.constant_declaration.type.?.kind.array_type;
    try std.testing.expectEqualStrings("2", array_type.length.?.kind.integer_literal.text);
    try std.testing.expectEqualStrings("Card", array_type.element.kind.identifier.name);
}

test "parseBrackets: parses an array type with a length to infer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const cards: [_]Card = other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const array_type = module.declarations[0].kind.constant_declaration.type.?.kind.array_type;
    try std.testing.expectEqual(null, array_type.length);
    try std.testing.expectEqualStrings("Card", array_type.element.kind.identifier.name);
}

test "parseBrackets: rejects an array type with two lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [1, 2]i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrayLength, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects a missing closing bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [2 i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBracket, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseBrackets: parses a slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const slice_type = parameter.type.kind.slice_type;
    try std.testing.expect(!slice_type.constant);
    try std.testing.expectEqualStrings("u8", slice_type.element.kind.identifier.name);
}

test "parseBrackets: parses a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []const u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const slice_type = parameter.type.kind.slice_type;
    try std.testing.expect(slice_type.constant);
    try std.testing.expectEqualStrings("u8", slice_type.element.kind.identifier.name);
}

test "parseBrackets: parses an array of pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [2]*i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const array_type = parameter.type.kind.array_type;
    try std.testing.expectEqualStrings("i32", array_type.element.kind.pointer_type.target.kind.identifier.name);
}

test "parseParentheses: parses a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: (i32, bool,)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const tuple_type = parameter.type.kind.tuple_type;
    try std.testing.expectEqual(2, tuple_type.elements.len);
    try std.testing.expectEqualStrings("bool", tuple_type.elements[1].kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parameter.type.location);
}

test "parseParentheses: reads one type in parentheses as that type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: (i32)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqualStrings("i32", parameter.type.kind.identifier.name);
}

test "parseParentheses: groups an expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return (a + b) * c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.left.kind.binary.operator);
}

test "parseParentheses: rejects a tuple of one element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: (i32,)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.TooFewTupleElements, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseParentheses: rejects empty parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ()): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.TooFewTupleElements, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parsePointerType: parses a pointer to a single value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *bool): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const pointer_type = parameter.type.kind.pointer_type;
    try std.testing.expect(!pointer_type.many);
    try std.testing.expect(!pointer_type.constant);
    try std.testing.expectEqualStrings("bool", pointer_type.target.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parsePointerType: parses a read-only pointer to multiple values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: *many const i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const pointer_type = parameter.type.kind.pointer_type;
    try std.testing.expect(pointer_type.many);
    try std.testing.expect(pointer_type.constant);
    try std.testing.expectEqualStrings("i32", pointer_type.target.kind.identifier.name);
}

test "parsePointerType: parses a pointer to a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: **const u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const outer = parameter.type.kind.pointer_type;
    try std.testing.expect(!outer.constant);
    try std.testing.expect(outer.target.kind.pointer_type.constant);
}

test "parsePointerType: rejects a pointer without a target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseOptionalType: parses an optional type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ?i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqualStrings("i32", parameter.type.kind.optional_type.child.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parseOptionalType: parses an optional of an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ??*i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const inner = parameter.type.kind.optional_type.child.kind.optional_type;
    try std.testing.expectEqualStrings("i32", inner.child.kind.pointer_type.target.kind.identifier.name);
}

test "parseOptionalType: rejects a question mark without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ?): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseFunctionType: parses the parameter types and the return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32, bool,) -> u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const function_type = parameter.type.kind.function_type;
    try std.testing.expectEqual(2, function_type.parameters.len);
    try std.testing.expectEqualStrings("bool", function_type.parameters[1].kind.identifier.name);
    try std.testing.expectEqualStrings("u8", function_type.return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parameter.type.location);
}

test "parseFunctionType: returns void when no return type is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32), other: i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqualStrings("void", parameters[0].type.kind.function_type.return_type.kind.identifier.name);
    try std.testing.expectEqualStrings("other", parameters[1].name);
}

test "parseFunctionType: parses an optional function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: ?fn(i32) -> i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const function_type = parameter.type.kind.optional_type.child.kind.function_type;
    try std.testing.expectEqualStrings("i32", function_type.return_type.kind.identifier.name);
}

test "parseFunctionType: rejects a function type with a type but no arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32) i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, parser.failure.?.location.?);
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
    const inner = outer.arguments[0].value.kind.call;
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
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> i32: return utils::value");
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

test "parseNegation: wraps a number literal in a negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> i32: return -5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("5", value.kind.negation.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, value.location);
}

test "parseNegation: allows a space before the number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> f64: return - 2.5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("2.5", value.kind.negation.kind.float_literal.text);
}

test "parseNegation: rejects a minus before a literal that is not a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *-true): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedNumber, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
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

test "parseArgument: parses named arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(Point(x = 1, y = 2), 3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(null, outer.arguments[1].name);
    const inner = outer.arguments[0].value.kind.call;
    try std.testing.expectEqualStrings("x", inner.arguments[0].name.?);
    try std.testing.expectEqualStrings("1", inner.arguments[0].value.kind.integer_literal.text);
    try std.testing.expectEqualStrings("y", inner.arguments[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, inner.arguments[1].location);
}

test "parseArgument: rejects a name without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(Point(x = ))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
}

test "parseMember: parses a method call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): card.show(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.method_call;
    try std.testing.expectEqualStrings("card", call.receiver.kind.identifier.name);
    try std.testing.expectEqualStrings("show", call.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, call.name_location);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseMember: parses a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return pointer.*");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("pointer", value.kind.dereference.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, value.location);
}

test "parseMember: parses an optional unwrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return value.?");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("value", value.kind.unwrap.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, value.location);
}

test "parseMember: rejects a dot without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(point.)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, parser.failure.?.location.?);
}

test "parseSubscript: parses an index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return values[position]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("values", value.kind.index.value.kind.identifier.name);
    try std.testing.expectEqualStrings("position", value.kind.index.index.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, value.location);
}

test "parseSubscript: parses a slice of a whole array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(buffer[..])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    const slice = call.arguments[0].value;
    try std.testing.expectEqualStrings("buffer", slice.kind.slice.value.kind.identifier.name);
    try std.testing.expectEqual(null, slice.kind.slice.start);
    try std.testing.expectEqual(null, slice.kind.slice.end);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, slice.location);
}

test "parseSubscript: parses a slice with a start and an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[1..3])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqualStrings("1", slice.start.?.kind.integer_literal.text);
    try std.testing.expectEqualStrings("3", slice.end.?.kind.integer_literal.text);
}

test "parseSubscript: parses a slice with only a start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[start..])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqualStrings("start", slice.start.?.kind.identifier.name);
    try std.testing.expectEqual(null, slice.end);
}

test "parseSubscript: parses a slice with only an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[..end])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqual(null, slice.start);
    try std.testing.expectEqualStrings("end", slice.end.?.kind.identifier.name);
}

test "parseSubscript: parses a slice of a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[1..][..2])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqualStrings("2", slice.end.?.kind.integer_literal.text);
    try std.testing.expectEqualStrings("1", slice.value.kind.slice.start.?.kind.integer_literal.text);
}

test "parseSubscript: rejects a missing closing bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(buffer[..)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBracket, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
}

test "parseSubscript: rejects brackets without an index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, parser.failure.?.location.?);
}

test "parseBound: parses an operation as a bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): take(values[start + 1..end])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqual(ast.BinaryOperator.add, slice.start.?.kind.binary.operator);
    try std.testing.expectEqualStrings("end", slice.end.?.kind.identifier.name);
}
