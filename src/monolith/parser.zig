const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

const findKeywordName = @import("name.zig").findKeywordName;

const comparison_operators: []const OperatorToken = &.{
    .{ .equals_equals, .equal },
    .{ .exclamation_mark_equals, .not_equal },
    .{ .less_than, .less_than },
    .{ .less_than_equals, .less_than_or_equal },
    .{ .greater_than, .greater_than },
    .{ .greater_than_equals, .greater_than_or_equal },
};

const compound_operators: []const OperatorToken = &.{
    .{ .plus_equals, .add },
    .{ .minus_equals, .subtract },
    .{ .asterisk_equals, .multiply },
    .{ .slash_equals, .divide },
    .{ .percent_equals, .remainder },
    .{ .ampersand_equals, .bitwise_and },
    .{ .pipe_equals, .bitwise_or },
    .{ .caret_equals, .bitwise_exclusive_or },
    .{ .shift_left_equals, .shift_left },
    .{ .shift_right_equals, .shift_right },
};

pub const Parser = struct {
    tokens: []const token.Token,
    offset: usize = 0,
    declarations: std.ArrayList(ast.Declaration) = .empty,
    methods: std.ArrayList(ast.Declaration) = .empty,
    paths: std.ArrayList(ast.Path) = .empty,
    has_range: bool = false,
    same_line_block: ?usize = null,
    line_if: ?usize = null,
    branch_block: bool = false,
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

        return .{ .declarations = self.declarations.items, .paths = self.paths.items, .has_range = self.has_range };
    }

    fn parseTopLevelStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!bool {
        var position = offset.*;
        const indentation = self.match(&position, .indent) orelse return false;
        if (indentation.kind.indent != 0) return self.fail(offset.*, error.UnexpectedIndentation);
        if (try self.parseImport(allocator, &position)) |imports| {
            try self.declarations.appendSlice(allocator, imports);
            offset.* = position;
            return true;
        }
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
        const private = try self.matchPrivate(offset);
        var kind: ast.DeclarationKind = kind: {
            if (private and self.tokens[offset.*].kind == .keyword_instance) return self.fail(offset.*, error.PrivateInstance);
            if (private and self.tokens[offset.*].kind == .keyword_import) return self.fail(offset.* - 1, error.MisplacedPrivate);
            if (try self.parseFunctionDeclaration(allocator, offset)) |function_declaration| {
                break :kind .{ .function_declaration = function_declaration };
            }
            if (try self.parseFunctionDefinition(allocator, offset, null, 0)) |function| {
                break :kind .{ .function_definition = function };
            }
            if (try self.parseConstantDeclaration(allocator, offset, 0)) |constant| {
                break :kind .{ .constant_declaration = constant };
            }
            if (try self.parseStructDefinition(allocator, offset, self.topSink(), self.declarations.items.len)) |definition| {
                break :kind .{ .struct_definition = definition };
            }
            if (try self.parseEnumDefinition(allocator, offset, self.topSink(), self.declarations.items.len)) |definition| {
                break :kind .{ .enum_definition = definition };
            }
            if (try self.parseTypeclassDefinition(allocator, offset)) |definition| {
                break :kind .{ .typeclass_definition = definition };
            }
            if (try self.parseInstance(allocator, offset)) |instance_declaration| {
                break :kind .{ .instance_declaration = instance_declaration };
            }
            if (private) return self.fail(offset.*, error.MisplacedPrivate);
            return null;
        };
        switch (kind) {
            .function_declaration => |*signature| signature.private = private,
            .function_definition => |*definition| definition.signature.private = private,
            .constant_declaration, .struct_definition, .enum_definition, .typeclass_definition, .instance_declaration, .import => {},
        }
        return .{ .kind = kind, .location = location, .private = private };
    }

    fn matchPrivate(self: *Parser, offset: *usize) ParseError!bool {
        _ = self.match(offset, .keyword_private) orelse return false;
        if (self.tokens[offset.*].kind == .keyword_private) return self.fail(offset.*, error.RepeatedPrivate);
        return true;
    }

    fn matchPrivateMember(self: *Parser, offset: *usize) ParseError!bool {
        if (self.tokens[offset.*].kind != .keyword_private) return false;
        const next = self.tokens[offset.* + 1].kind;
        if (next == .keyword_private) return self.fail(offset.* + 1, error.RepeatedPrivate);
        if (next != .keyword_fn and next != .keyword_inline and !self.isTypeDeclaration(offset.* + 1)) return false;
        offset.* += 1;
        return true;
    }

    fn parseFunctionDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.FunctionSignature {
        var position = offset.*;
        if (self.isTypeDeclaration(position)) return null;
        _ = self.match(&position, .keyword_external) orelse return null;
        if (self.tokens[position].kind == .keyword_inline) return self.fail(position, error.InlineExternal);
        const signature = (try self.parseFunctionSignature(allocator, &position, null)) orelse {
            return self.fail(position, error.ExpectedFunctionKeyword);
        };
        const next = self.tokens[position].kind;
        if (next == .colon or next == .equals or self.opensBlock(position)) {
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
        if (self.isTypeDeclaration(position)) return null;
        const inlined = self.match(&position, .keyword_inline) != null;
        if (inlined and self.tokens[position].kind == .keyword_external) return self.fail(position, error.InlineExternal);
        var signature = (try self.parseFunctionSignature(allocator, &position, receiver)) orelse {
            if (inlined) return self.fail(position, error.ExpectedFunctionKeyword);
            return null;
        };
        signature.@"inline" = inlined;
        const body = (try self.parseFunctionBody(allocator, &position, depth)) orelse {
            return self.fail(position, error.ExpectedBlock);
        };

        offset.* = position;
        return .{ .signature = signature, .body = body };
    }

    fn parseFunctionBody(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError!?[]ast.Statement {
        if (self.match(offset, .equals) != null) return try self.parseEqualsBody(allocator, offset, depth);
        if (!try self.opensHeaderBlock(offset.*)) return null;
        return try self.parseHeaderBlock(allocator, offset, depth);
    }

    fn parseEqualsBody(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError![]ast.Statement {
        const caller_same_line_block = self.same_line_block;
        defer self.same_line_block = caller_same_line_block;
        self.same_line_block = null;
        const owner = switch (self.tokens[offset.*].kind) {
            .keyword_while, .keyword_for, .at_sign => false,
            else => true,
        };
        const statement = try self.parseBlockLine(allocator, offset, depth, owner);
        return allocator.dupe(ast.Statement, &.{statement});
    }

    fn parseFunctionSignature(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ?ast.Expression,
    ) ParseError!?ast.FunctionSignature {
        var position = offset.*;
        _ = self.match(&position, .keyword_fn) orelse return null;
        const declared = try self.parseTypeParameters(allocator, &position, false);
        const name = try self.expectName(&position);
        var parameters: []ast.TypedName = &.{};
        if (self.match(&position, .left_parenthesis) != null) {
            parameters = try self.parseParameters(allocator, &position);
            _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        }
        var inferred_error_set: ?token.Location = null;
        var return_type: ast.Expression = undefined;
        const return_own = self.tokens[position].kind == .arrow and self.tokens[position + 1].kind == .keyword_own;
        if (return_own) position += 1;
        if (return_own and self.tokens[position + 1].kind != .exclamation_mark) {
            position += 1;
            return_type = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
        } else if ((return_own or self.tokens[position].kind == .arrow) and self.tokens[position + 1].kind == .exclamation_mark) {
            inferred_error_set = self.tokens[position + 1].location;
            position += 2;
            return_type = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
        } else {
            return_type = try self.parseReturnType(allocator, &position);
        }

        offset.* = position;
        return .{
            .receiver = receiver,
            .name = name,
            .declared = declared,
            .parameters = parameters,
            .return_type = return_type,
            .inferred_error_set = inferred_error_set,
            .return_own = return_own,
        };
    }

    fn parseParameters(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.TypedName {
        var position = offset.*;
        var parameters: std.ArrayList(ast.TypedName) = .empty;
        var defaulted = false;
        while (self.tokens[position].kind != .right_parenthesis) {
            const start = position;
            const parameter = (try self.parseParameter(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
            if (parameter.default != null) {
                defaulted = true;
            } else if (defaulted) {
                return self.fail(start, error.ParameterDefaultNotTrailing);
            }
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
        var parameter = (try self.parseParameterForm(allocator, &position)) orelse return null;
        if (self.tokens[position].kind == .equals) {
            if (parameter.own) return self.fail(position, error.OwnParameterDefault);
            if (parameter.kind == .type) return self.fail(position, error.TypeParameterDefault);
            if (parameter.kind == .compile_time) return self.fail(position, error.ComptimeParameterDefault);
            parameter.default = try self.parseDefault(allocator, &position);
        }

        offset.* = position;
        return parameter;
    }

    fn parseParameterForm(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypedName {
        if (try self.parseTypeParameter(allocator, offset)) |parameter| return parameter;
        if (self.parseAnyParameter(offset)) |parameter| return parameter;
        return self.parseValueParameter(allocator, offset);
    }

    fn parseValueParameter(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypedName {
        var position = offset.*;
        const owned = self.match(&position, .keyword_own);
        const marker = self.match(&position, .keyword_comptime);
        const underscore = self.match(&position, .underscore);
        var parameter = if (underscore) |discarded|
            try self.parseNameType(allocator, &position, "_", discarded.location)
        else if (try self.parseTypedName(allocator, &position)) |typed_name|
            typed_name
        else if (marker != null or owned != null)
            return self.fail(position, error.ExpectedIdentifier)
        else
            return null;
        if (marker != null) parameter.kind = .compile_time;
        parameter.own = owned != null;

        offset.* = position;
        return parameter;
    }

    fn parseDefault(self: *Parser, allocator: std.mem.Allocator, offset: *usize) ParseError!*ast.Expression {
        var position = offset.* + 1;
        const default = try allocator.create(ast.Expression);
        default.* = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return default;
    }

    fn parseAnyParameter(self: *Parser, offset: *usize) ?ast.TypedName {
        const name = self.tokens[offset.*];
        const written = switch (name.kind) {
            .identifier => |identifier| identifier,
            .underscore => "_",
            else => return null,
        };
        if (self.tokens[offset.* + 1].kind != .colon) return null;
        const marker = self.tokens[offset.* + 2];
        if (marker.kind != .keyword_any) return null;
        offset.* += 3;
        const kind: ast.ExpressionKind = .{ .identifier = .{ .name = "any" } };
        return .{
            .name = written,
            .type = .{ .kind = kind, .location = marker.location },
            .location = name.location,
            .kind = .any,
        };
    }

    fn parseTypeParameter(self: *Parser, allocator: std.mem.Allocator, offset: *usize) ParseError!?ast.TypedName {
        var position = offset.*;
        const marker = self.tokens[position];
        if (marker.kind != .identifier or !std.mem.eql(u8, marker.kind.identifier, "type")) return null;
        const name = self.tokens[position + 1];
        if (name.kind != .identifier) return null;
        position += 2;
        const requirements = try self.parseRequirements(allocator, &position);
        const kind: ast.ExpressionKind = .{ .identifier = .{ .name = "type" } };

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .type = .{ .kind = kind, .location = marker.location },
            .location = name.location,
            .kind = .type,
            .requirements = requirements,
        };
    }

    fn parseRequirements(self: *Parser, allocator: std.mem.Allocator, offset: *usize) ParseError![]ast.Expression {
        var position = offset.*;
        if (self.match(&position, .colon) == null) return &.{};
        var requirements: std.ArrayList(ast.Expression) = .empty;
        while (true) {
            const first = self.tokens[position];
            const written = (try self.parsePathStart(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
            if (self.match(&position, .left_parenthesis) != null) {
                const arguments = try self.parseArguments(allocator, &position);
                _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
                try requirements.append(allocator, .{
                    .kind = .{ .call = .{ .callee = buildName(written), .arguments = arguments } },
                    .location = first.location,
                });
            } else {
                try requirements.append(allocator, buildNameExpression(written, first.location));
            }
            if (self.match(&position, .keyword_and) == null) break;
        }

        offset.* = position;
        return requirements.items;
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

    fn parseHeaderBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        outer: usize,
    ) ParseError![]ast.Statement {
        try self.expectHeaderEnd(offset.*);
        const caller_same_line_block = self.same_line_block;
        defer self.same_line_block = caller_same_line_block;
        self.same_line_block = null;
        return self.parseIndentedBlock(allocator, offset, outer);
    }

    fn parseSameLineBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        outer: usize,
        clause: bool,
    ) ParseError![]ast.Statement {
        const caller_same_line_block = self.same_line_block;
        defer self.same_line_block = caller_same_line_block;
        self.same_line_block = if (clause) offset.* else null;
        return self.parseInlineBlock(allocator, offset, outer);
    }

    fn opensBlock(self: *const Parser, offset: usize) bool {
        const indentation = self.findLineIndentation(offset);
        var position = offset;
        while (true) : (position += 1) {
            switch (self.tokens[position].kind) {
                .indent => |next| return next > indentation,
                .eof => return false,
                else => {},
            }
        }
    }

    fn opensHeaderBlock(self: *Parser, offset: usize) ParseError!bool {
        if (self.tokens[offset].kind == .colon) return self.fail(offset, error.HeaderColon);
        return self.opensBlock(offset);
    }

    fn expectHeaderEnd(self: *Parser, offset: usize) ParseError!void {
        switch (self.tokens[offset].kind) {
            .indent => {},
            .colon => return self.fail(offset, error.HeaderColon),
            else => return self.fail(offset, error.UnexpectedToken),
        }
    }

    fn openSameLineHeader(self: *Parser, offset: *usize, keyword: usize) ParseError!void {
        if (self.match(offset, .left_parenthesis) != null) return;
        if (self.findHeaderColon(offset.*)) |colon| return self.fail(colon, error.HeaderColon);
        const branching = self.tokens[keyword].kind == .keyword_if;
        if (branching and self.opensBlock(offset.*)) return self.fail(keyword, error.MisplacedBranching);
        return self.fail(offset.*, error.ExpectedLeftParenthesis);
    }

    fn findHeaderColon(self: *const Parser, offset: usize) ?usize {
        var depth: usize = 0;
        var position = offset;
        while (true) : (position += 1) {
            switch (self.tokens[position].kind) {
                .indent, .eof => return null,
                .left_parenthesis, .left_bracket, .left_brace => depth += 1,
                .right_parenthesis, .right_bracket, .right_brace => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                .colon => if (depth == 0) return position,
                else => {},
            }
        }
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
            const start = position;
            const statement = try self.parseBlockLine(allocator, &position, depth, true);
            if (statement.kind == .value and self.continuesBlock(position, depth)) {
                return self.fail(start, error.ExpectedStatement);
            }
            try statements.append(allocator, statement);
        }

        offset.* = position;
        return statements.items;
    }

    fn parseBlockLine(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        owner: bool,
    ) ParseError!ast.Statement {
        if (try self.parseHandedValue(allocator, offset)) |statement| return statement;
        if (try self.parseStatement(allocator, offset, depth, owner)) |statement| return statement;
        var position = offset.*;
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(offset.*, error.ExpectedStatement);
        };
        if (!self.endsValueLine(position)) return self.fail(offset.*, error.ExpectedStatement);

        offset.* = position;
        return .{ .kind = .{ .value = value }, .location = value.location };
    }

    fn parseHandedValue(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        if (!self.branch_block) return null;
        var position = offset.*;
        _ = self.match(&position, .keyword_own) orelse return null;
        var value = (try self.parseExpression(allocator, &position)) orelse return null;
        if (isCallOrTriedCall(value) or !self.endsValueLine(position)) return null;
        value.handed = true;

        offset.* = position;
        return .{ .kind = .{ .value = value }, .location = value.location };
    }

    fn endsValueLine(self: *const Parser, offset: usize) bool {
        return switch (self.tokens[offset].kind) {
            .indent, .eof, .keyword_else => true,
            .right_parenthesis, .right_bracket, .right_brace, .comma => self.line_if != null,
            else => false,
        };
    }

    fn continuesBlock(self: *const Parser, offset: usize, depth: usize) bool {
        const current = self.tokens[offset];
        return current.kind == .indent and current.kind.indent >= depth;
    }

    fn parseInlineBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        outer: usize,
    ) ParseError![]ast.Statement {
        const statement = try self.parseBlockLine(allocator, offset, outer, false);
        return allocator.dupe(ast.Statement, &.{statement});
    }

    fn parseStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        owner: bool,
    ) ParseError!?ast.Statement {
        const location = self.tokens[offset.*].location;
        if (self.match(offset, .keyword_noop) != null) {
            return .{ .kind = .noop, .location = location };
        }
        if (self.isTypeDeclaration(offset.*)) return self.fail(offset.*, error.MisplacedTypeDeclaration);
        if (self.match(offset, .keyword_with) != null) return try self.parseWithStatement(allocator, offset, location);
        const value_depth: ?usize = if (owner) depth else null;
        if (try self.parseReturn(allocator, offset, value_depth)) |statement| return statement;
        const else_depth: ?usize = if (owner) depth else null;
        if (try self.parseIf(allocator, offset, depth, else_depth, owner)) |statement| return statement;
        if (self.isColonLabel(offset.*)) return self.fail(offset.*, error.LabelWithoutSigil);
        if (try self.parseWhile(allocator, offset, depth, else_depth, owner)) |statement| return statement;
        if (try self.parseFor(allocator, offset, depth, else_depth, owner)) |statement| return statement;
        if (try self.parseMatch(allocator, offset, depth, owner)) |statement| return statement;
        if (value_depth) |owner_depth| {
            if (try self.parseTriedMatch(allocator, offset, owner_depth)) |tried| {
                return .{ .kind = .{ .call = tried }, .location = location };
            }
        }
        if (try self.parseJump(offset)) |statement| return statement;
        if (try self.parseDefer(allocator, offset, value_depth)) |statement| return statement;
        if (try self.parseDiscard(allocator, offset)) |statement| return statement;
        if (try self.parseTupleDeclaration(allocator, offset, value_depth)) |declaration| {
            return .{ .kind = .{ .tuple_declaration = declaration }, .location = location };
        }
        if (try self.parseConstantDeclaration(allocator, offset, value_depth)) |constant| {
            return .{ .kind = .{ .constant_declaration = constant }, .location = location };
        }
        if (try self.parseVariableDeclaration(allocator, offset, value_depth)) |variable| {
            return .{ .kind = .{ .variable_declaration = variable }, .location = location };
        }
        if (try self.parseAssignment(allocator, offset, value_depth)) |statement| return statement;
        return self.parseCallStatement(allocator, offset);
    }

    fn parseReturn(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_return) orelse return null;
        var value: ?ast.Expression = null;
        switch (self.tokens[position].kind) {
            .indent, .eof, .keyword_else, .right_parenthesis, .comma => {},
            else => value = (try self.parseValue(allocator, &position, depth)) orelse {
                return self.fail(position, error.ExpectedExpression);
            },
        }

        offset.* = position;
        return .{ .kind = .{ .@"return" = value }, .location = keyword.location };
    }

    fn parseValue(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.Expression {
        const owner_depth = depth orelse return self.parseExpression(allocator, offset);
        if (try self.parseTriedMatch(allocator, offset, owner_depth)) |tried| return tried;
        const keyword = self.tokens[offset.*];
        const parsed = if (keyword.kind == .keyword_if)
            try self.parseIf(allocator, offset, owner_depth, owner_depth, true)
        else
            try self.parseMatch(allocator, offset, owner_depth, true);
        const branching = parsed orelse return self.parseExpression(allocator, offset);
        const statement = try allocator.create(ast.Statement);
        statement.* = branching;
        return .{ .kind = .{ .branching = statement }, .location = keyword.location };
    }

    fn parseTriedMatch(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError!?ast.Expression {
        if (self.tokens[offset.*].kind != .keyword_try or self.tokens[offset.* + 1].kind != .keyword_match) return null;
        var position = offset.* + 1;
        const location = self.tokens[position].location;
        const statement = try allocator.create(ast.Statement);
        statement.* = (try self.parseMatch(allocator, &position, depth, true)).?;
        const operand = try allocator.create(ast.Expression);
        operand.* = .{ .kind = .{ .branching = statement }, .location = location };
        const keyword = self.tokens[offset.*];

        offset.* = position;
        return .{ .kind = .{ .@"try" = operand }, .location = keyword.location };
    }

    fn parseLineIf(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const keyword = self.tokens[offset.*];
        const caller_line_if = self.line_if;
        self.line_if = offset.*;
        defer self.line_if = caller_line_if;
        const statement = try allocator.create(ast.Statement);
        statement.* = (try self.parseIf(allocator, offset, 0, null, false)).?;
        return .{ .kind = .{ .branching = statement }, .location = keyword.location };
    }

    fn parseIf(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
        owner: bool,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const start = position;
        const keyword = self.match(&position, .keyword_if) orelse return null;
        const caller_branch_block = self.branch_block;
        defer self.branch_block = caller_branch_block;
        self.branch_block = true;
        const block = owner and self.opensBlock(position);
        if (!block) try self.openSameLineHeader(&position, start);
        const marker = self.match(&position, .keyword_own);
        const condition = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        const naming = try self.parseConditionNames(allocator, &position);
        if (!block) {
            _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
            try self.expectSameLineIf(start);
        }
        const body = if (block)
            try self.parseHeaderBlock(allocator, &position, depth)
        else
            try self.parseSameLineBlock(allocator, &position, depth, true);
        var else_body: ?[]ast.Statement = null;
        const same_line_else = self.match(&position, .keyword_else) != null;
        const next_line_else = !same_line_else and self.matchElse(&position, else_depth);
        if (same_line_else or next_line_else) {
            if (try self.parseIf(allocator, &position, depth, else_depth, next_line_else)) |chained| {
                else_body = try allocator.dupe(ast.Statement, &.{chained});
            } else {
                else_body = try self.parseElseBlock(allocator, &position, depth, next_line_else);
            }
        }

        offset.* = position;
        const conditional: ast.If = .{
            .condition = condition,
            .marker = if (marker) |own| own.location else null,
            .names = naming.names,
            .own = naming.own,
            .tuple = naming.tuple,
            .body = body,
            .else_body = else_body,
        };
        return .{ .kind = .{ .@"if" = conditional }, .location = keyword.location };
    }

    fn expectSameLineIf(self: *Parser, keyword: usize) ParseError!void {
        const start = self.same_line_block orelse return;
        if (isBracketed(self.tokens[start..keyword])) return;
        return self.fail(keyword, error.NestedSameLineIf);
    }

    fn parseWhile(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
        owner: bool,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const location = self.tokens[position].location;
        const label = self.parseLabel(&position);
        const keyword = position;
        if (self.match(&position, .keyword_while) == null) return null;
        const caller_branch_block = self.branch_block;
        defer self.branch_block = caller_branch_block;
        self.branch_block = false;
        const block = owner and self.opensBlock(position);
        if (!block) try self.openSameLineHeader(&position, keyword);
        const marker = self.match(&position, .keyword_own);
        const condition = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        const naming = try self.parseConditionNames(allocator, &position);
        if (!block) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const body = if (block)
            try self.parseHeaderBlock(allocator, &position, depth)
        else
            try self.parseSameLineBlock(allocator, &position, depth, true);
        var else_body: ?[]ast.Statement = null;
        if (self.matchElse(&position, else_depth)) {
            else_body = try self.parseElseBlock(allocator, &position, depth, true);
        }

        offset.* = position;
        const loop: ast.While = .{
            .label = label,
            .condition = condition,
            .marker = if (marker) |own| own.location else null,
            .names = naming.names,
            .own = naming.own,
            .tuple = naming.tuple,
            .body = body,
            .else_body = else_body,
        };
        return .{ .kind = .{ .@"while" = loop }, .location = location };
    }

    fn parseConditionNames(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ValueNames {
        if (self.match(offset, .keyword_as) == null) return .{};
        return self.parseValueNames(allocator, offset);
    }

    fn parseValueNames(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ValueNames {
        var position = offset.*;
        const own = self.match(&position, .keyword_own) != null;
        const start = position;
        if (self.tokens[position].kind == .left_parenthesis) return self.fail(position, error.ParenthesizedPattern);
        const tuple = self.tokens[position].kind == .left_brace;
        const names = if (tuple)
            try self.parseElementNames(allocator, &position)
        else
            try allocator.dupe(ast.ElementName, &.{try self.parseValueName(&position)});
        if (own) {
            for (self.tokens[start..position], start..) |item, index| {
                if (item.kind == .asterisk) return self.fail(index, error.ExpectedIdentifier);
            }
        }

        offset.* = position;
        return .{ .names = names, .own = own, .tuple = tuple };
    }

    fn parseFor(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
        owner: bool,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const location = self.tokens[position].location;
        const label = self.parseLabel(&position);
        const keyword = position;
        if (self.match(&position, .keyword_for) == null) return null;
        const caller_branch_block = self.branch_block;
        defer self.branch_block = caller_branch_block;
        self.branch_block = false;
        const block = owner and self.opensBlock(position);
        if (!block) try self.openSameLineHeader(&position, keyword);
        const tuple = self.tokens[position].kind == .left_brace;
        const names = try self.parseElementNames(allocator, &position);
        _ = try self.expect(&position, .keyword_in, error.ExpectedIn);
        const sequence = try self.parseSequence(allocator, &position);
        if (!block) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const body = if (block)
            try self.parseHeaderBlock(allocator, &position, depth)
        else
            try self.parseSameLineBlock(allocator, &position, depth, true);
        var else_body: ?[]ast.Statement = null;
        if (self.matchElse(&position, else_depth)) {
            else_body = try self.parseElseBlock(allocator, &position, depth, true);
        }

        offset.* = position;
        const loop: ast.For = .{
            .label = label,
            .names = names,
            .tuple = tuple,
            .sequence = sequence,
            .body = body,
            .else_body = else_body,
        };
        return .{ .kind = .{ .@"for" = loop }, .location = location };
    }

    fn parseElementNames(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.ElementName {
        var position = offset.*;
        if (self.tokens[position].kind == .left_parenthesis) return self.fail(position, error.ParenthesizedPattern);
        if (self.match(&position, .left_brace) == null) {
            const name = try self.parseElementName(&position);
            offset.* = position;
            return allocator.dupe(ast.ElementName, &.{name});
        }
        var names: std.ArrayList(ast.ElementName) = .empty;
        while (true) {
            try names.append(allocator, try self.parseElementName(&position));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_brace, error.ExpectedRightBrace);

        offset.* = position;
        return names.items;
    }

    fn parseElementName(self: *Parser, offset: *usize) ParseError!ast.ElementName {
        var position = offset.*;
        const location = self.tokens[position].location;
        const pointer = self.match(&position, .asterisk) != null;
        const name = switch (self.tokens[position].kind) {
            .identifier => |identifier| identifier,
            .underscore => "_",
            else => return self.fail(position, error.ExpectedIdentifier),
        };
        if (pointer and ast.isDiscardedName(name)) return self.fail(position, error.ExpectedIdentifier);

        offset.* = position + 1;
        return .{ .name = name, .pointer = pointer, .location = location };
    }

    fn parseSequence(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Sequence {
        var position = offset.*;
        const value = (try self.parseOperation(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        const sequence: ast.Sequence = if (self.match(&position, .dot_dot) == null)
            .{ .value = value }
        else
            .{ .range = .{ .start = value, .end = try self.parseOperation(allocator, &position) } };

        offset.* = position;
        return sequence;
    }

    fn parseMatch(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        owner: bool,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_match) orelse return null;
        const caller_branch_block = self.branch_block;
        defer self.branch_block = caller_branch_block;
        self.branch_block = true;
        const marker = self.match(&position, .keyword_own);
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        if (self.tokens[position].kind == .colon) return self.fail(position, error.HeaderColon);
        if (!owner or !self.opensBlock(position)) return self.fail(position, error.ExpectedBlock);
        try self.expectHeaderEnd(position);
        var branches: std.ArrayList(ast.Branch) = .empty;
        var names: std.ArrayList(ast.ElementName) = .empty;
        const branch_depth = try self.expectBlock(position, depth);
        while (try self.matchBlockLine(&position, branch_depth, depth)) {
            const count = branches.items.len;
            if (count > 0 and branches.items[count - 1].cases.len == 0) {
                return self.fail(position, error.ElseNotLast);
            }
            const branch = try self.parseBranch(allocator, &position, branch_depth, &names);
            try branches.append(allocator, branch);
        }

        offset.* = position;
        const matching: ast.Match = .{ .value = value, .marker = if (marker) |own| own.location else null, .branches = branches.items, .names = names.items };
        return .{ .kind = .{ .match = matching }, .location = keyword.location };
    }

    fn parseBranch(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        names: *std.ArrayList(ast.ElementName),
    ) ParseError!ast.Branch {
        var position = offset.*;
        const location = self.tokens[position].location;
        var cases: std.ArrayList(ast.BranchCase) = .empty;
        var value_names: ValueNames = .{ .names = try allocator.dupe(ast.ElementName, &.{.{ .name = "_", .location = location }}) };
        var naming: ast.Naming = .none;
        const block = self.opensBlock(position);
        if (self.match(&position, .keyword_else) == null) {
            const keyword = position;
            _ = try self.expect(&position, .keyword_case, error.ExpectedCaseOrElse);
            if (!block) try self.openSameLineHeader(&position, keyword);
            while (true) {
                try cases.append(allocator, try self.parseBranchCase(allocator, &position));
                if (self.tokens[position].kind == .left_brace) {
                    if (cases.items.len > 1) return self.fail(position, error.NamedCases);
                    value_names = try self.parseCaseNames(allocator, &position);
                    naming = .payload;
                    if (self.tokens[position].kind == .comma) return self.fail(position, error.NamedCases);
                }
                if (self.match(&position, .comma) == null) break;
            }
            if (naming == .none and self.tokens[position].kind == .keyword_as) {
                if (cases.items.len > 1) return self.fail(position, error.NamedCases);
                position += 1;
                value_names = try self.parseValueNames(allocator, &position);
                naming = .value;
            }
            if (!block) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        } else if (try self.parseRemainingNames(allocator, &position, block)) |remaining| {
            value_names = remaining;
            naming = .value;
        }
        const body = if (block)
            try self.parseHeaderBlock(allocator, &position, depth)
        else
            try self.parseBranchLine(allocator, &position, depth);
        const first_name = names.items.len;
        try names.appendSlice(allocator, value_names.names);

        offset.* = position;
        return .{
            .cases = cases.items,
            .naming = naming,
            .own = value_names.own,
            .tuple = value_names.tuple,
            .first_name = first_name,
            .name_count = value_names.names.len,
            .body = body,
            .location = location,
        };
    }

    fn parseRemainingNames(self: *Parser, allocator: std.mem.Allocator, offset: *usize, block: bool) ParseError!?ValueNames {
        var position = offset.*;
        if (!block and self.match(&position, .left_parenthesis) == null) return null;
        if (self.match(&position, .underscore) == null) return null;
        if (self.match(&position, .keyword_as) == null) return null;
        const value_names = try self.parseValueNames(allocator, &position);
        if (!block) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return value_names;
    }

    fn parseBranchLine(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
    ) ParseError![]ast.Statement {
        if (self.tokens[offset.*].kind == .colon) return self.fail(offset.*, error.HeaderColon);
        return self.parseSameLineBlock(allocator, offset, depth, false);
    }

    fn parseBranchCase(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.BranchCase {
        var position = offset.*;
        if (try self.parseNameExpression(allocator, &position)) |name| {
            if (self.tokens[position].kind == .left_brace) {
                offset.* = position;
                return .{ .pattern = name };
            }
            position = offset.*;
        }
        const pattern = (try self.parseOperation(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedBranch);
        };
        if (pattern.kind == .case_literal) return self.fail(offset.*, error.BranchCaseWithColons);
        var case: ast.BranchCase = .{ .pattern = pattern };
        if (self.match(&position, .dot_dot) != null) {
            case.range = true;
            case.end = try self.parseOperation(allocator, &position);
        }

        offset.* = position;
        return case;
    }

    fn parseCaseNames(self: *Parser, allocator: std.mem.Allocator, offset: *usize) ParseError!ValueNames {
        var position = offset.*;
        _ = try self.expect(&position, .left_brace, error.ExpectedLeftBrace);
        var names: std.ArrayList(ast.ElementName) = .empty;
        var owned: ?bool = null;
        while (true) {
            const start = position;
            const own = self.match(&position, .keyword_own) != null;
            const name = try self.parseElementName(&position);
            if (own and name.pointer) return self.fail(start + 1, error.ExpectedIdentifier);
            if (!ast.isDiscardedName(name.name)) {
                if (owned) |previous| {
                    if (previous != own) return self.fail(start, error.MixedOwnNames);
                }
                owned = own;
            }
            try names.append(allocator, name);
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_brace, error.ExpectedRightBrace);

        offset.* = position;
        return .{ .names = names.items, .own = owned orelse false };
    }

    fn parseValueName(self: *Parser, offset: *usize) ParseError!ast.ElementName {
        const start = offset.*;
        const name = try self.parseElementName(offset);
        if (ast.isDiscardedName(name.name)) return self.fail(start, error.DiscardedValueName);
        return name;
    }

    fn parseLabel(self: *Parser, offset: *usize) ?[]const u8 {
        if (self.tokens[offset.*].kind != .at_sign) return null;
        const name = self.tokens[offset.* + 1];
        if (name.kind != .identifier) return null;
        offset.* += 2;
        return name.kind.identifier;
    }

    fn isColonLabel(self: *const Parser, offset: usize) bool {
        if (self.tokens[offset].kind != .identifier or self.tokens[offset + 1].kind != .colon) return false;
        const keyword = self.tokens[offset + 2].kind;
        return keyword == .keyword_while or keyword == .keyword_for;
    }

    fn matchElse(self: *Parser, offset: *usize, else_depth: ?usize) bool {
        const depth = else_depth orelse return false;
        const indentation = self.tokens[offset.*];
        if (indentation.kind != .indent or indentation.kind.indent != depth) return false;
        if (self.tokens[offset.* + 1].kind != .keyword_else) return false;
        offset.* += 2;
        return true;
    }

    fn parseElseBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        owner: bool,
    ) ParseError![]ast.Statement {
        if (self.tokens[offset.*].kind == .colon) return self.fail(offset.*, error.HeaderColon);
        if (owner and self.opensBlock(offset.*)) return self.parseHeaderBlock(allocator, offset, depth);
        return self.parseSameLineBlock(allocator, offset, depth, true);
    }

    fn parseJump(self: *Parser, offset: *usize) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.tokens[position];
        if (keyword.kind != .keyword_break and keyword.kind != .keyword_continue) return null;
        position += 1;
        if (self.tokens[position].kind == .identifier) return self.fail(position, error.LabelWithoutSigil);
        var jump: ast.Jump = .{};
        if (self.match(&position, .at_sign) != null) {
            jump.label = (try self.expect(&position, .identifier, error.ExpectedIdentifier)).kind.identifier;
        }

        offset.* = position;
        const kind: ast.StatementKind = if (keyword.kind == .keyword_break)
            .{ .@"break" = jump }
        else
            .{ .@"continue" = jump };
        return .{ .kind = kind, .location = keyword.location };
    }

    fn parseDefer(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.tokens[position];
        if (keyword.kind != .keyword_defer and keyword.kind != .keyword_errdefer) return null;
        position += 1;
        const start = position;
        const statement = (try self.parseDiscard(allocator, &position)) orelse
            (try self.parseAssignment(allocator, &position, depth)) orelse
            (try self.parseCallStatement(allocator, &position)) orelse
            return self.fail(start, error.ExpectedDeferredStatement);
        const inner = try allocator.create(ast.Statement);
        inner.* = statement;

        offset.* = position;
        const deferred: ast.Defer = .{ .statement = inner, .on_error = keyword.kind == .keyword_errdefer };
        return .{ .kind = .{ .@"defer" = deferred }, .location = keyword.location };
    }

    fn parseDiscard(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const underscore = self.match(&position, .underscore) orelse return null;
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const discarded = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .kind = .{ .discard = discarded }, .location = underscore.location };
    }

    fn parseVariableDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.VariableDeclaration {
        var position = offset.*;
        _ = self.match(&position, .keyword_var) orelse return null;
        const owned = self.match(&position, .keyword_own);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const written_type = try self.parseWrittenType(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const moved = self.match(&position, .keyword_own);
        const value = (try self.parseValue(allocator, &position, depth)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .type = written_type, .value = value, .own = owned != null, .moved = moved != null };
    }

    fn parseAssignment(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const target = (try self.parseExpression(allocator, &position)) orelse return null;
        const operator_token = self.tokens[position];
        const operator: ?ast.CompoundOperator = if (findOperator(compound_operators, operator_token.kind)) |found|
            .{ .operator = found, .location = operator_token.location }
        else
            null;
        if (operator == null and operator_token.kind != .equals) return null;
        position += 1;
        switch (target.kind) {
            .identifier, .field_access, .index, .dereference => {},
            .case_literal => return self.fail(offset.*, error.CaseWithoutEnum),
            else => return self.fail(offset.*, error.ExpectedTarget),
        }
        const moved = self.match(&position, .keyword_own);
        const value = (try self.parseValue(allocator, &position, depth)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        const assignment: ast.Assignment = .{ .target = target, .operator = operator, .value = value, .moved = moved != null };
        return .{ .kind = .{ .assignment = assignment }, .location = target.location };
    }

    fn parseCallStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        if (self.tokens[position].kind == .keyword_own) return self.fail(position, error.MisplacedOwn);
        const call = (try self.parseExpression(allocator, &position)) orelse return null;
        if (!isCallOrTriedCall(call)) return null;

        offset.* = position;
        return .{ .kind = .{ .call = call }, .location = call.location };
    }

    fn parseTupleDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.TupleDeclaration {
        var position = offset.*;
        const keyword = self.tokens[position].kind;
        if (keyword != .keyword_const and keyword != .keyword_var) return null;
        if (self.isConstantPointerStart(position)) return null;
        position += 1;
        const own = self.match(&position, .keyword_own) != null;
        const opening = self.tokens[position].kind;
        if (opening == .left_parenthesis) return self.fail(position, error.ParenthesizedPattern);
        if (opening != .left_brace) return null;
        const names = try self.parseElementNames(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const moved = self.match(&position, .keyword_own) != null;
        const value = (try self.parseValue(allocator, &position, depth)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .names = names, .value = value, .variable = keyword == .keyword_var, .own = own, .moved = moved };
    }

    fn parseConstantDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: ?usize,
    ) ParseError!?ast.ConstantDeclaration {
        var position = offset.*;
        if (self.isConstantPointerStart(position)) return null;
        _ = self.match(&position, .keyword_const) orelse return null;
        const owned = self.match(&position, .keyword_own);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const written_type = try self.parseWrittenType(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const moved = self.match(&position, .keyword_own);
        const value = (try self.parseValue(allocator, &position, depth)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .name = name.kind.identifier, .type = written_type, .value = value, .own = owned != null, .moved = moved != null };
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

    fn topSink(self: *Parser) Sink {
        return .{ .list = &self.methods, .base = self.declarations.items.len + 1 };
    }

    fn parseStructDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        sink: Sink,
        own: usize,
    ) ParseError!?ast.StructDefinition {
        var position = offset.*;
        const outer = self.findLineIndentation(position);
        const start = position;
        const inlined = self.match(&position, .keyword_inline) != null;
        const external = self.match(&position, .keyword_external) != null;
        if (external and inlined) return self.fail(start, error.InlineExternalStruct);
        if (external and self.tokens[position].kind == .keyword_inline) return self.fail(position, error.InlineExternalStruct);
        _ = self.match(&position, .keyword_struct) orelse return null;
        const name_location = self.tokens[position].location;
        const name = try self.expectName(&position);
        var fields: []ast.Field = &.{};
        if (try self.opensHeaderBlock(position)) {
            try self.expectHeaderEnd(position);
            const receiver = try buildReceiverExpression(allocator, name, name_location);
            fields = try self.parseMembers(allocator, &position, receiver, outer, sink, own, null);
        }
        if (inlined) try self.expectInlineField(start, fields);

        offset.* = position;
        return .{ .name = name, .external = external, .@"inline" = inlined, .fields = fields };
    }

    fn expectInlineField(self: *Parser, offset: usize, fields: []const ast.Field) ParseError!void {
        if (fields.len != 1) return self.fail(offset, error.InlineStructFieldCount);
        if (fields[0].own) return self.failAt(fields[0].location, error.InlineStructOwnField);
    }

    fn parseEnumDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        sink: Sink,
        own: usize,
    ) ParseError!?ast.EnumDefinition {
        var position = offset.*;
        const outer = self.findLineIndentation(position);
        const kind: types.EnumKind = switch (self.tokens[position].kind) {
            .keyword_enum => .enumeration,
            .keyword_error => .error_set,
            else => return null,
        };
        position += 1;
        const name_location = self.tokens[position].location;
        const name = try self.expectName(&position);
        var cases: std.ArrayList(ast.EnumCase) = .empty;
        if (try self.opensHeaderBlock(position)) {
            try self.expectHeaderEnd(position);
            const receiver = try buildReceiverExpression(allocator, name, name_location);
            const depth = try self.expectBlock(position, outer);
            while (try self.matchBlockLine(&position, depth, outer)) {
                const location = self.tokens[position].location;
                if (kind == .error_set) {
                    if (self.isTypeDeclaration(position)) return self.fail(position, error.MisplacedTypeDeclaration);
                    try cases.append(allocator, try self.parseCase(allocator, &position, error.ExpectedErrorCase));
                    continue;
                }
                const private = try self.matchPrivate(&position);
                if (try self.parseNestedType(allocator, &position, sink, own, private)) continue;
                if (try self.parseFunctionDefinition(allocator, &position, receiver, depth)) |parsed| {
                    var function = parsed;
                    function.signature.self_parameter = findSelfParameter(function.signature, "Self");
                    function.signature.private = private;
                    const method: ast.DeclarationKind = .{ .function_definition = function };
                    try sink.list.append(allocator, .{ .kind = method, .location = location, .owner = own, .private = private });
                    continue;
                }
                if (private) return self.fail(position - 1, error.MisplacedPrivate);
                try cases.append(allocator, try self.parseCase(allocator, &position, error.ExpectedCase));
            }
        }

        offset.* = position;
        return .{ .name = name, .kind = kind, .cases = cases.items };
    }

    fn parseCase(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        missing_error: ParseError,
    ) ParseError!ast.EnumCase {
        var position = offset.*;
        const case_name = try self.expect(&position, .identifier, missing_error);
        var case_type: ?ast.Expression = null;
        if (self.match(&position, .colon) != null) {
            case_type = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
        }

        offset.* = position;
        return .{ .name = case_name.kind.identifier, .type = case_type, .location = case_name.location };
    }

    fn parseMembers(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        receiver: ast.Expression,
        outer: usize,
        sink: Sink,
        owner: ?usize,
        functions: ?*std.ArrayList(ast.Declaration),
    ) ParseError![]ast.Field {
        var position = offset.*;
        const depth = try self.expectBlock(position, outer);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (try self.matchBlockLine(&position, depth, outer)) {
            const location = self.tokens[position].location;
            const private = try self.matchPrivateMember(&position);
            if (try self.parseNestedType(allocator, &position, sink, owner, private)) continue;
            const method = try self.parseFunctionDefinition(allocator, &position, receiver, depth);
            if (method) |parsed| {
                var function = parsed;
                function.signature.self_parameter = findSelfParameter(function.signature, "Self");
                function.signature.private = private;
                const kind: ast.DeclarationKind = .{ .function_definition = function };
                const declaration: ast.Declaration = .{ .kind = kind, .location = location, .owner = owner, .private = private };
                if (functions) |list| {
                    try list.append(allocator, declaration);
                } else {
                    try sink.list.append(allocator, declaration);
                }
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

    fn parseNestedType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        sink: Sink,
        owner: ?usize,
        private: bool,
    ) ParseError!bool {
        if (!self.isTypeDeclaration(offset.*)) return false;
        const location = self.tokens[offset.*].location;
        const slot = sink.list.items.len;
        try sink.list.append(allocator, undefined);
        const own = sink.base + slot;
        const kind: ast.DeclarationKind = if (try self.parseStructDefinition(allocator, offset, sink, own)) |definition|
            .{ .struct_definition = definition }
        else
            .{ .enum_definition = (try self.parseEnumDefinition(allocator, offset, sink, own)).? };
        sink.list.items[slot] = .{ .kind = kind, .location = location, .owner = owner, .private = private };
        return true;
    }

    fn isTypeDeclaration(self: *const Parser, offset: usize) bool {
        return switch (self.tokens[offset].kind) {
            .keyword_struct => self.tokens[offset + 1].kind == .identifier,
            .keyword_enum, .keyword_error => self.tokens[offset + 1].kind == .identifier,
            .keyword_external => self.isStructAfter(offset + 1, .keyword_inline),
            .keyword_inline => self.isStructAfter(offset + 1, .keyword_external),
            else => false,
        };
    }

    fn isStructAfter(self: *const Parser, offset: usize, other: std.meta.Tag(token.TokenKind)) bool {
        const kind = std.meta.activeTag(self.tokens[offset].kind);
        return kind == .keyword_struct or (kind == other and self.tokens[offset + 1].kind == .keyword_struct);
    }

    fn parseField(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Field {
        var position = offset.*;
        const private = self.match(&position, .keyword_private);
        const owned = self.match(&position, .keyword_own);
        const typed_name = (try self.parseTypedName(allocator, &position)) orelse {
            if (owned != null or private != null) return self.fail(position, error.ExpectedIdentifier);
            return null;
        };
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
            .own = owned != null,
            .private = private != null,
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

    fn parseTypeclassDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TypeclassDefinition {
        var position = offset.*;
        _ = self.match(&position, .keyword_typeclass) orelse return null;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        var parameters: std.ArrayList(ast.TypeclassParameter) = .empty;
        while (true) {
            try parameters.append(allocator, try self.parseTypeclassParameter(allocator, &position));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        var functions: std.ArrayList(ast.FunctionSignature) = .empty;
        var defaults: std.ArrayList(?ast.Default) = .empty;
        if (try self.opensHeaderBlock(position)) {
            try self.parseTypeclassFunctions(allocator, &position, parameters.items, &functions, &defaults);
        }

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .parameters = parameters.items,
            .functions = functions.items,
            .defaults = defaults.items,
        };
    }

    fn parseTypeclassFunctions(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        parameters: []const ast.TypeclassParameter,
        functions: *std.ArrayList(ast.FunctionSignature),
        defaults: *std.ArrayList(?ast.Default),
    ) ParseError!void {
        var position = offset.*;
        try self.expectHeaderEnd(position);
        const outer = self.findLineIndentation(position);
        const depth = try self.expectBlock(position, outer);
        while (try self.matchBlockLine(&position, depth, outer)) {
            const start = position;
            const private = try self.matchPrivate(&position);
            if (self.isTypeDeclaration(position)) return self.fail(position, error.MisplacedTypeDeclaration);
            const inlined = self.match(&position, .keyword_inline) != null;
            const parsed = try self.parseFunctionSignature(allocator, &position, null);
            var signature = parsed orelse {
                return self.fail(position, error.ExpectedFunctionKeyword);
            };
            signature.self_parameter = findTypeclassSelfParameter(signature, parameters);
            signature.@"inline" = inlined;
            signature.private = private;
            try functions.append(allocator, signature);
            const body = (try self.parseFunctionBody(allocator, &position, depth)) orelse {
                if (inlined) return self.fail(start, error.InlineSignature);
                try defaults.append(allocator, null);
                continue;
            };
            const definition: ast.FunctionDefinition = .{ .signature = signature, .body = body };
            const template = try ast.cloneFunctionDefinition(allocator, definition);
            try defaults.append(allocator, .{ .body = body, .template = template });
        }

        offset.* = position;
    }

    fn parseTypeclassParameter(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.TypeclassParameter {
        var position = offset.*;
        try self.expectTypeMarker(&position);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        var arity: usize = 0;
        if (self.match(&position, .left_parenthesis) != null) {
            while (true) {
                try self.expectTypeMarker(&position);
                arity += 1;
                if (self.match(&position, .comma) == null) break;
            }
            _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        }
        const requirements = try self.parseRequirements(allocator, &position);

        offset.* = position;
        return .{ .name = name.kind.identifier, .arity = arity, .requirements = requirements, .location = name.location };
    }

    fn expectTypeMarker(self: *Parser, offset: *usize) ParseError!void {
        const marker = self.tokens[offset.*];
        if (marker.kind != .identifier or !std.mem.eql(u8, marker.kind.identifier, "type")) {
            return self.fail(offset.*, error.ExpectedTypeParameter);
        }
        offset.* += 1;
    }

    fn parseInstance(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.InstanceDeclaration {
        var position = offset.*;
        _ = self.match(&position, .keyword_instance) orelse return null;
        const parameters = try self.parseTypeParameters(allocator, &position, true);
        const typeclass = (try self.parseNameExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedIdentifier);
        };
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        var arguments: std.ArrayList(ast.Expression) = .empty;
        while (true) {
            const argument = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedType);
            };
            try arguments.append(allocator, argument);
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        var count: usize = 0;
        if (try self.opensHeaderBlock(position)) {
            try self.expectHeaderEnd(position);
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const location = self.tokens[position].location;
                if (self.isTypeDeclaration(position)) return self.fail(position, error.MisplacedTypeDeclaration);
                const definition = try self.parseFunctionDefinition(allocator, &position, null, depth);
                var function = definition orelse {
                    return self.fail(position, error.ExpectedFunctionKeyword);
                };
                function.signature.typeclass = typeclass;
                const kind: ast.DeclarationKind = .{ .function_definition = function };
                try self.methods.append(allocator, .{ .kind = kind, .location = location });
                count += 1;
            }
        }

        offset.* = position;
        return .{
            .typeclass = typeclass,
            .parameters = parameters,
            .arguments = arguments.items,
            .functions = count,
        };
    }

    fn parseTypeParameters(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        takes_length: bool,
    ) ParseError![]ast.InstanceParameter {
        var position = offset.*;
        if (self.match(&position, .left_parenthesis) == null) return &.{};
        var parameters: std.ArrayList(ast.InstanceParameter) = .empty;
        while (true) {
            if (takes_length and self.tokens[position].kind == .keyword_comptime) {
                try parameters.append(allocator, try self.parseLengthParameter(&position));
            } else {
                try parameters.append(allocator, try self.parseInstanceParameter(allocator, &position));
            }
            if (!takes_length and self.tokens[position].kind == .equals) return self.fail(position, error.TypeParameterDefault);
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return parameters.items;
    }

    fn parseLengthParameter(self: *Parser, offset: *usize) ParseError!ast.InstanceParameter {
        var position = offset.* + 1;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const written = self.tokens[position];
        if (written.kind != .identifier or !std.mem.eql(u8, written.kind.identifier, "usize")) return self.fail(position, error.LengthParameterType);

        offset.* = position + 1;
        return .{ .name = name.kind.identifier, .is_length = true, .location = name.location };
    }

    fn parseInstanceParameter(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.InstanceParameter {
        var position = offset.*;
        try self.expectTypeMarker(&position);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const requirements = try self.parseRequirements(allocator, &position);

        offset.* = position;
        return .{ .name = name.kind.identifier, .requirements = requirements, .location = name.location };
    }

    fn parseImport(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?[]ast.Declaration {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_import) orelse return null;
        const first = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const prefix = try self.parseSegments(allocator, &position, first.kind.identifier, true);
        if (self.match(&position, .double_colon) == null) {
            const import = try self.parseImportName(&position, offset.*, prefix);
            offset.* = position;
            return try allocator.dupe(ast.Declaration, &.{.{ .kind = .{ .import = import }, .location = keyword.location }});
        }
        const crossing = try self.matchCrossing(&position, .double_colon);
        _ = try self.expect(&position, .left_brace, error.ExpectedLeftBrace);
        var declarations: std.ArrayList(ast.Declaration) = .empty;
        while (true) {
            try declarations.append(allocator, try self.parseImportItem(allocator, &position, prefix, crossing));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_brace, error.ExpectedRightBrace);

        offset.* = position;
        return declarations.items;
    }

    fn parseImportItem(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        prefix: ast.PathExpression,
        crossing: bool,
    ) ParseError!ast.Declaration {
        var position = offset.*;
        const start = position;
        const item = self.tokens[start];
        if (item.kind == .keyword_private) return self.fail(start, error.MisplacedPrivate);
        const written: ast.PathExpression = written: {
            if (item.kind == .identifier and std.mem.eql(u8, item.kind.identifier, "self")) {
                if (crossing) return self.fail(start, error.MisplacedPrivate);
                position += 1;
                break :written prefix;
            }
            const name = try self.expectName(&position);
            const path = try std.mem.concat(allocator, []const u8, &.{ prefix.path, &.{name} });
            if (!crossing and prefix.crossings.len == 0) break :written .{ .path = path };
            const crossings = try allocator.alloc(bool, path.len);
            @memset(crossings, false);
            @memcpy(crossings[0..prefix.crossings.len], prefix.crossings);
            crossings[prefix.path.len] = crossing;
            break :written .{ .path = path, .crossings = crossings };
        };
        const import = try self.parseImportName(&position, start, written);

        offset.* = position;
        return .{ .kind = .{ .import = import }, .location = item.location };
    }

    fn parseImportName(
        self: *Parser,
        offset: *usize,
        start: usize,
        written: ast.PathExpression,
    ) ParseError!ast.Import {
        var position = offset.*;
        const path = written.path;
        if (path.len > 1 and std.mem.eql(u8, path[0], "module")) return self.fail(start, error.ReservedImport);
        var name = path[path.len - 1];
        if (self.match(&position, .keyword_as) != null) {
            name = (try self.expect(&position, .identifier, error.ExpectedIdentifier)).kind.identifier;
        }

        offset.* = position;
        return .{ .path = path, .crossings = written.crossings, .name = name };
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
        var position = offset.*;
        const start = (try self.parseOperation(allocator, &position)) orelse return null;
        if (self.match(&position, .dot_dot) == null) {
            offset.* = position;
            return start;
        }
        const end = try self.parseOperation(allocator, &position);
        const range = try allocator.create(ast.Range);
        range.* = .{ .start = start, .end = end };
        self.has_range = true;

        offset.* = position;
        return .{ .kind = .{ .range = range }, .location = start.location };
    }

    fn parseOperation(
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
        const operators: []const OperatorToken = &.{ .{ .keyword_orelse, .@"orelse" }, .{ .keyword_catch, .@"catch" } };
        return self.parseBinary(allocator, offset, operators, parseResultType);
    }

    fn parseResultType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{.{ .exclamation_mark, .result }};
        return self.parseBinary(allocator, offset, operators, parseBitwiseOr);
    }

    fn parseBitwiseOr(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        const operators: []const OperatorToken = &.{ .{ .pipe, .bitwise_or }, .{ .pipe_pipe, .combine } };
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
            if (left.kind == .range) return self.fail(offset.*, error.RangeOperand);
            const location = self.tokens[position].location;
            position += 1;
            const right_start = position;
            const right = (try parseStronger(self, allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
            if (right.kind == .range) return self.fail(right_start, error.RangeOperand);
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
        if (current.kind == .keyword_try) return self.parseTry(allocator, offset);
        if (try self.parseJumpExpression(allocator, offset)) |jump| return jump;
        const operator = findUnaryOperator(current.kind);
        if (operator == null and current.kind != .ampersand) {
            return self.parsePostfix(allocator, offset);
        }
        const next = self.tokens[position + 1].kind;
        const literal = next == .integer_literal or next == .float_literal;
        if (operator == .negate and literal) return self.parsePostfix(allocator, offset);
        position += 1;
        const operand_start = position;
        const operand = try allocator.create(ast.Expression);
        operand.* = (try self.parsePrefix(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        if (operand.kind == .range) return self.fail(operand_start, error.RangeOperand);

        offset.* = position;
        const unary_operator = operator orelse {
            return .{ .kind = .{ .address_of = operand }, .location = current.location };
        };
        const unary: ast.Unary = .{ .operator = unary_operator, .operand = operand };
        return .{ .kind = .{ .unary = unary }, .location = current.location };
    }

    fn parseTry(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_try) orelse return null;
        const operand_start = position;
        const operand = try allocator.create(ast.Expression);
        operand.* = (try self.parsePrefix(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        if (operand.kind == .range) return self.fail(operand_start, error.RangeOperand);

        offset.* = position;
        return .{ .kind = .{ .@"try" = operand }, .location = keyword.location };
    }

    fn parseJumpExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.tokens[position];
        const parsed = if (keyword.kind == .keyword_return)
            try self.parseReturnExpression(allocator, &position)
        else
            try self.parseJump(&position);
        const jump = parsed orelse return null;
        const statement = try allocator.create(ast.Statement);
        statement.* = jump;

        offset.* = position;
        return .{ .kind = .{ .jump = statement }, .location = keyword.location };
    }

    fn parseReturnExpression(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_return) orelse return null;
        const value = try self.parseExpression(allocator, &position);

        offset.* = position;
        return .{ .kind = .{ .@"return" = value }, .location = keyword.location };
    }

    fn parsePostfix(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        if (self.tokens[position].kind == .left_parenthesis and self.tokens[position + 1].kind == .keyword_own) {
            return self.fail(position, error.ParenthesizedOwnReceiver);
        }
        var expression = (try self.parseOperand(allocator, &position)) orelse return null;
        if (expression.kind == .range and isPostfixStart(self.tokens[position].kind)) return self.fail(offset.*, error.RangeOperand);
        while (true) {
            if (isLiteralType(expression) and self.tokens[position].kind == .left_brace) {
                const literal_type = try allocator.create(ast.Expression);
                literal_type.* = expression;
                expression = try self.parseCompositeLiteral(allocator, &position, literal_type);
            } else if ((expression.kind == .call or expression.kind == .member) and self.match(&position, .double_colon) != null) {
                expression = try self.parseMemberCall(allocator, &position, expression);
            } else if (self.match(&position, .dot) != null) {
                expression = try self.parseMember(allocator, &position, expression);
            } else if (try self.parseSubscript(allocator, &position, expression)) |subscript| {
                expression = subscript;
            } else break;
        }
        try self.parseWithValue(allocator, &position, &expression);

        offset.* = position;
        return expression;
    }

    fn parseWithValue(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        expression: *ast.Expression,
    ) ParseError!void {
        const takes_value = expression.kind == .call or expression.kind == .method_call or (expression.kind == .case_literal and expression.kind.case_literal.called);
        if (!takes_value) return;
        if (self.match(offset, .keyword_with) == null) return;
        const value = try allocator.create(ast.Expression);
        value.* = (try self.parsePrefix(allocator, offset)) orelse return self.fail(offset.*, error.ExpectedExpression);
        switch (expression.kind) {
            .call => |*call| call.with_value = value,
            .method_call => |*call| call.with_value = value,
            .case_literal => |*literal| literal.with_value = value,
            else => unreachable,
        }
    }

    fn parseWithStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        location: token.Location,
    ) ParseError!ast.Statement {
        const current = self.tokens[offset.*].kind;
        if (current == .identifier and std.mem.eql(u8, current.identifier, ast.allocator_name) and self.endsValueLine(offset.* + 1)) {
            offset.* += 1;
            const value: ast.Expression = .{ .kind = .{ .identifier = .{ .name = ast.allocator_parameter } }, .location = location };
            return .{ .kind = .{ .constant_declaration = .{ .name = ast.allocator_name, .value = value, .with = true } }, .location = location };
        }
        const start = offset.*;
        const value = (try self.parseExpression(allocator, offset)) orelse return self.fail(start, error.ExpectedExpression);
        if (!self.endsValueLine(offset.*)) return self.fail(offset.*, error.ExpectedStatement);
        return .{ .kind = .{ .constant_declaration = .{ .name = ast.context_local, .value = value, .context = true } }, .location = location };
    }

    fn parseOperand(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        if (self.tokens[offset.*].kind == .keyword_any) return self.fail(offset.*, error.MisplacedAny);
        if (self.tokens[offset.*].kind == .keyword_const) return try self.parseConstantPointer(allocator, offset);
        if (self.tokens[offset.*].kind == .keyword_many) return self.fail(offset.*, error.MisplacedMany);
        const keyword = self.tokens[offset.*].kind;
        if (keyword == .keyword_match) return self.fail(offset.*, error.MisplacedBranching);
        if (keyword == .keyword_if) return self.parseLineIf(allocator, offset);
        if (self.tokens[offset.*].kind == .left_brace) {
            return try self.parseCompositeLiteral(allocator, offset, null);
        }
        if (keyword == .double_colon) return try self.parseCaseLiteral(allocator, offset);
        if (try self.parseBrackets(allocator, offset)) |expression| return expression;
        if (try self.parseParentheses(allocator, offset)) |expression| return expression;
        if (try self.parsePointerType(allocator, offset, false)) |pointer_type| return pointer_type;
        if (try self.parseOptionalType(allocator, offset)) |optional_type| return optional_type;
        if (try self.parseFunctionType(allocator, offset)) |function_type| return function_type;
        if (try self.parseStructType(allocator, offset)) |struct_type| return struct_type;
        if (try self.parseCall(allocator, offset)) |call| return call;
        if (try self.parseNameExpression(allocator, offset)) |name| return name;
        if (try self.parseNegation(allocator, offset)) |negation| return negation;
        return self.parseLiteral(offset);
    }

    fn parseCaseLiteral(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Expression {
        var position = offset.* + 1;
        const location = self.tokens[offset.*].location;
        const crossing = try self.matchCrossing(&position, .double_colon);
        var literal: ast.CaseLiteral = .{ .name = try self.expectName(&position), .crossing = crossing };
        if (self.match(&position, .left_parenthesis) != null) {
            literal.arguments = try self.parseArguments(allocator, &position);
            literal.called = true;
            _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        } else if (self.tokens[position].kind == .left_brace) {
            const values = try self.parseCompositeLiteral(allocator, &position, null);
            literal.arguments = values.kind.composite_literal.elements;
            literal.braced = true;
        }
        const next = self.tokens[position].kind;
        if (next == .double_colon or next == .left_brace) return self.fail(offset.*, error.CaseWithoutEnum);

        offset.* = position;
        return .{ .kind = .{ .case_literal = literal }, .location = location };
    }

    fn parseStructType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const start = position;
        const inlined = self.match(&position, .keyword_inline) != null;
        if (inlined and self.tokens[position].kind == .keyword_external) return self.fail(position, error.InlineExternalStruct);
        const keyword = self.match(&position, .keyword_struct) orelse return null;
        if (!try self.opensHeaderBlock(position)) return self.fail(position, error.ExpectedBlock);
        try self.expectHeaderEnd(position);
        const receiver: ast.Expression = .{ .kind = .{ .identifier = .{ .name = "Self" } }, .location = keyword.location };
        var functions: std.ArrayList(ast.Declaration) = .empty;
        var nested: std.ArrayList(ast.Declaration) = .empty;
        const outer = self.findLineIndentation(offset.*);
        const fields = try self.parseMembers(allocator, &position, receiver, outer, .{ .list = &nested, .base = 0 }, null, &functions);
        if (inlined) try self.expectInlineField(start, fields);
        const struct_type = try allocator.create(ast.StructType);
        struct_type.* = .{ .@"inline" = inlined, .fields = fields, .functions = functions.items, .types = nested.items };

        offset.* = position;
        return .{ .kind = .{ .struct_type = struct_type }, .location = keyword.location };
    }

    fn findLineIndentation(self: *const Parser, offset: usize) usize {
        var position = offset;
        while (position > 0) {
            position -= 1;
            if (self.tokens[position].kind == .indent) return self.tokens[position].kind.indent;
        }
        return 0;
    }

    fn parseCompositeLiteral(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        literal_type: ?*ast.Expression,
    ) ParseError!ast.Expression {
        var position = offset.*;
        const brace = try self.expect(&position, .left_brace, error.ExpectedLeftBrace);
        var elements: std.ArrayList(ast.Argument) = .empty;
        while (self.tokens[position].kind != .right_brace) {
            try elements.append(allocator, try self.parseElement(allocator, &position));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_brace, error.ExpectedRightBrace);

        offset.* = position;
        const location = if (literal_type) |written| written.location else brace.location;
        const literal: ast.CompositeLiteral = .{ .type = literal_type, .elements = elements.items };
        return .{ .kind = .{ .composite_literal = literal }, .location = location };
    }

    fn parseElement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Argument {
        var position = offset.*;
        const crossing = try self.matchCrossing(&position, .dot);
        if (crossing and self.tokens[position].kind != .identifier) return self.fail(position, error.ExpectedIdentifier);
        var element = try self.parseArgument(allocator, &position);
        element.crossing = crossing;

        offset.* = position;
        return element;
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
        var elements: std.ArrayList(ast.Expression) = .empty;
        var trailing_comma = false;
        while (self.tokens[position].kind != .right_bracket) {
            const element = (try self.parseExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedExpression);
            };
            try elements.append(allocator, element);
            trailing_comma = self.match(&position, .comma) != null;
            if (!trailing_comma) break;
        }
        _ = try self.expect(&position, .right_bracket, error.ExpectedRightBracket);
        const empty = elements.items.len == 0;
        if (empty and self.tokens[position].kind == .keyword_const and !self.isQualifier(position, .keyword_const)) return self.fail(position, error.ConstPointerSyntax);
        if (empty and self.tokens[position].kind == .keyword_many) return self.fail(position, error.MisplacedMany);
        const has_comma = elements.items.len > 1 or trailing_comma;
        if (has_comma or !self.isTypeStart(position)) {
            offset.* = position;
            const tuple_type: ast.TupleType = .{ .elements = elements.items };
            return .{ .kind = .{ .tuple_type = tuple_type }, .location = bracket.location };
        }
        if (empty) return self.fail(offset.*, error.MisplacedSlice);
        const length = try allocator.create(ast.Expression);
        length.* = elements.items[0];
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
        _ = self.match(&position, .left_parenthesis) orelse return null;
        const inner = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return inner;
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
            .identifier, .asterisk, .question_mark, .left_parenthesis, .keyword_any => true,
            .keyword_fn, .keyword_const, .keyword_many => self.tokens[offset + 1].kind == .left_parenthesis,
            .left_bracket => self.tokens[offset + 1].kind != .dot_dot,
            else => false,
        };
    }

    fn isSliceStart(self: *Parser, offset: usize) bool {
        if (self.tokens[offset].kind != .left_bracket or self.tokens[offset + 1].kind != .right_bracket) return false;
        return switch (self.tokens[offset + 2].kind) {
            .keyword_const, .keyword_many => true,
            else => self.isTypeStart(offset + 2),
        };
    }

    fn parseSliceType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        constant: bool,
    ) ParseError!ast.SliceType {
        offset.* += 2;
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
        constant: bool,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const asterisk = self.match(&position, .asterisk) orelse return null;
        if (self.tokens[position].kind == .keyword_const) {
            if (!self.isQualifier(position, .keyword_const)) return self.fail(position, error.ConstPointerSyntax);
            if (self.tokens[position + 2].kind != .asterisk) return self.fail(position, error.ConstInsidePointer);
        }
        if (self.tokens[position].kind == .keyword_many) return self.fail(position, error.ManyPointerSyntax);
        const many = self.isManyStart(position);
        if (many) position += 3;
        if (!many and self.isSliceStart(position)) {
            const slice_type = try self.parseSliceType(allocator, &position, constant);
            offset.* = position;
            return .{ .kind = .{ .slice_type = slice_type }, .location = asterisk.location };
        }
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

    fn isConstantPointerStart(self: *const Parser, offset: usize) bool {
        return self.isQualifier(offset, .keyword_const) and self.tokens[offset + 2].kind == .asterisk;
    }

    fn isManyStart(self: *const Parser, offset: usize) bool {
        if (self.tokens[offset].kind != .left_bracket or self.tokens[offset + 1].kind != .keyword_many) return false;
        return self.tokens[offset + 2].kind == .right_bracket;
    }

    fn parseConstantPointer(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.Expression {
        var position = offset.*;
        const keyword = self.tokens[position];
        if (!self.isQualifier(position, .keyword_const)) return self.fail(position, error.ConstPointerSyntax);
        position += 2;
        if (self.tokens[position].kind != .asterisk) return self.fail(offset.*, error.ConstWithoutPointer);
        var pointer = (try self.parsePointerType(allocator, &position, true)).?;
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        pointer.location = keyword.location;

        offset.* = position;
        return pointer;
    }

    fn isQualifier(self: *const Parser, offset: usize, keyword: std.meta.Tag(token.TokenKind)) bool {
        if (std.meta.activeTag(self.tokens[offset].kind) != keyword) return false;
        return self.tokens[offset + 1].kind == .left_parenthesis;
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
        var parameters: std.ArrayList(ast.Expression) = .empty;
        if (self.match(&position, .left_parenthesis) != null) {
            while (self.tokens[position].kind != .right_parenthesis) {
                const parameter = (try self.parseExpression(allocator, &position)) orelse {
                    return self.fail(position, error.ExpectedType);
                };
                try parameters.append(allocator, parameter);
                if (self.match(&position, .comma) == null) break;
            }
            _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        }
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
        const first = self.tokens[position];
        const written = (try self.parsePathStart(allocator, &position)) orelse return null;
        const callee = buildName(written);
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
        const first = self.tokens[position];
        const written = (try self.parsePathStart(allocator, &position)) orelse return null;

        offset.* = position;
        return buildNameExpression(written, first.location);
    }

    fn parsePathStart(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.PathExpression {
        const first = self.tokens[offset.*];
        if (first.kind != .identifier) return null;
        if (!std.mem.eql(u8, first.kind.identifier, "module") or self.tokens[offset.* + 1].kind != .double_colon) {
            offset.* += 1;
            const written = try self.parsePath(allocator, offset, first);
            if (written.path.len > 1) try self.recordPath(allocator, written.path);
            return written;
        }
        var position = offset.* + 1;
        const written = try self.parseSegments(allocator, &position, ast.module_root, false);

        offset.* = position;
        return written;
    }

    fn recordPath(self: *Parser, allocator: std.mem.Allocator, path: ast.Path) std.mem.Allocator.Error!void {
        for (self.paths.items) |recorded| {
            if (recorded.len != path.len) continue;
            for (recorded, path) |recorded_name, name| {
                if (!std.mem.eql(u8, recorded_name, name)) break;
            } else return;
        }
        try self.paths.append(allocator, path);
    }

    fn parsePath(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        first: token.Token,
    ) ParseError!ast.PathExpression {
        return self.parseSegments(allocator, offset, first.kind.identifier, false);
    }

    fn parseSegments(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        first: []const u8,
        before_group: bool,
    ) ParseError!ast.PathExpression {
        var position = offset.*;
        var path: std.ArrayList([]const u8) = .empty;
        var crossings: std.ArrayList(bool) = .empty;
        var crossed = false;
        try path.append(allocator, first);
        try crossings.append(allocator, false);
        while (self.tokens[position].kind == .double_colon) {
            if (before_group and self.isGroupStart(position + 1)) break;
            position += 1;
            const crossing = try self.matchCrossing(&position, .double_colon);
            crossed = crossed or crossing;
            try crossings.append(allocator, crossing);
            try path.append(allocator, try self.expectName(&position));
        }

        offset.* = position;
        return .{ .path = path.items, .crossings = if (crossed) crossings.items else &.{} };
    }

    fn isGroupStart(self: *const Parser, offset: usize) bool {
        if (self.tokens[offset].kind == .left_brace) return true;
        if (self.tokens[offset].kind != .keyword_private or self.tokens[offset + 1].kind != .double_colon) return false;
        return self.tokens[offset + 2].kind == .left_brace;
    }

    fn matchCrossing(self: *Parser, offset: *usize, separator: std.meta.Tag(token.TokenKind)) ParseError!bool {
        if (self.tokens[offset.*].kind != .keyword_private) return false;
        const next = self.tokens[offset.* + 1].kind;
        if (next == .keyword_private) return self.fail(offset.* + 1, error.RepeatedPrivate);
        if (std.meta.activeTag(next) != separator) return self.fail(offset.*, error.MisplacedPrivate);
        offset.* += 2;
        if (self.tokens[offset.*].kind == .keyword_private) return self.fail(offset.*, error.RepeatedPrivate);
        return true;
    }

    fn expectName(self: *Parser, offset: *usize) ParseError![]const u8 {
        const current = self.tokens[offset.*];
        offset.* += 1;
        if (current.kind == .identifier) return current.kind.identifier;
        const name = findKeywordName(current.kind) orelse return self.fail(offset.* - 1, error.ExpectedIdentifier);
        return name;
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
        if (first.kind == .underscore and isArgumentEnd(self.tokens[position + 1].kind)) {
            offset.* = position + 1;
            return .{ .name = null, .value = .{ .kind = .{ .inferred_type = .{} }, .location = first.location }, .location = first.location };
        }
        if (first.kind == .identifier and self.tokens[position + 1].kind == .equals) {
            name = first.kind.identifier;
            position += 2;
        }
        const owned = self.match(&position, .keyword_own);
        if (owned != null and (self.tokens[position].kind == .comma or self.tokens[position].kind == .right_parenthesis)) {
            return self.fail(position - 1, error.MisplacedOwnReceiver);
        }
        var value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        value.handed = owned != null and value.kind == .address_of;

        offset.* = position;
        return .{ .name = name, .value = value, .location = first.location, .own = owned != null };
    }

    fn parseMemberCall(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        owner: ast.Expression,
    ) ParseError!ast.Expression {
        var position = offset.*;
        const stored = try allocator.create(ast.Expression);
        stored.* = owner;
        const crossing = try self.matchCrossing(&position, .double_colon);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const member: ast.Member = .{ .owner = stored, .name = name.kind.identifier, .crossing = crossing };
        if (self.match(&position, .left_parenthesis) == null) {
            offset.* = position;
            return .{ .kind = .{ .member = member }, .location = owner.location };
        }
        const arguments = try self.parseArguments(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const call: ast.Call = .{ .callee = .{ .member = member }, .arguments = arguments };

        offset.* = position;
        return .{ .kind = .{ .call = call }, .location = owner.location };
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
        const crossing = try self.matchCrossing(offset, .dot);
        const field = try self.expect(offset, .identifier, error.ExpectedIdentifier);
        if (self.match(offset, .left_parenthesis) != null) {
            const receiver_own = self.matchOwnReceiver(offset);
            const arguments = try self.parseArguments(allocator, offset);
            _ = try self.expect(offset, .right_parenthesis, error.ExpectedRightParenthesis);
            const call: ast.MethodCall = .{
                .receiver = stored,
                .name = field.kind.identifier,
                .name_location = field.location,
                .crossing = crossing,
                .arguments = arguments,
                .receiver_own = receiver_own,
            };
            return .{ .kind = .{ .method_call = call }, .location = value.location };
        }
        const access: ast.FieldAccess = .{
            .value = stored,
            .field = field.kind.identifier,
            .field_location = field.location,
            .crossing = crossing,
        };
        return .{ .kind = .{ .field_access = access }, .location = value.location };
    }

    fn matchOwnReceiver(self: *Parser, offset: *usize) bool {
        const position = offset.*;
        if (self.tokens[position].kind != .keyword_own) return false;
        const next = self.tokens[position + 1].kind;
        if (next == .right_parenthesis) {
            offset.* = position + 1;
            return true;
        }
        if (next != .comma) return false;
        offset.* = position + 2;
        return true;
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
        const bound = (try self.parseOperation(allocator, offset)) orelse return null;
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
        if (self.findUnclosedParenthesis(offset)) |opening| {
            return self.failAt(self.tokens[opening].location, error.UnclosedParenthesis);
        }
        const reported = switch (self.tokens[offset].kind) {
            .keyword_private => if (parse_error == error.RepeatedPrivate) parse_error else error.MisplacedPrivate,
            else => parse_error,
        };
        self.failure = .{
            .location = self.tokens[offset].location,
            .message = describeError(reported),
        };
        return reported;
    }

    fn failAt(self: *Parser, location: token.Location, parse_error: ParseError) ParseError {
        self.failure = .{ .location = location, .message = describeError(parse_error) };
        return parse_error;
    }

    fn findUnclosedParenthesis(self: *const Parser, offset: usize) ?usize {
        var closed: usize = 0;
        var opened: usize = 0;
        for (self.tokens[offset..]) |item| {
            if (isOpening(item.kind)) {
                opened += 1;
            } else if (isClosing(item.kind)) {
                if (opened == 0) {
                    closed += 1;
                } else {
                    opened -= 1;
                }
            }
        }
        var depth: usize = 0;
        var position = offset;
        while (position > 0) {
            position -= 1;
            const item = self.tokens[position];
            if (isClosing(item.kind)) {
                depth += 1;
            } else if (isOpening(item.kind)) {
                if (depth > 0) {
                    depth -= 1;
                } else if (closed > 0) {
                    closed -= 1;
                } else {
                    break;
                }
            }
        } else return null;
        const opening = self.tokens[position];
        if (opening.kind != .left_parenthesis) return null;
        const failing = self.tokens[offset];
        if (failing.kind != .eof and failing.location.row == opening.location.row) return null;
        return position;
    }
};

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    ExpectedIdentifier,
    ExpectedLeftParenthesis,
    ExpectedRightParenthesis,
    UnclosedParenthesis,
    ExpectedColon,
    ExpectedFunctionKeyword,
    ExternalFunctionBody,
    ExpectedTypeParameter,
    ExpectedCase,
    ExpectedErrorCase,
    ExpectedArrow,
    ExpectedType,
    ConstPointerSyntax,
    ManyPointerSyntax,
    MisplacedMany,
    MisplacedSlice,
    ConstWithoutPointer,
    ConstInsidePointer,
    MisplacedBranching,
    NestedSameLineIf,
    MisplacedTypeDeclaration,
    HeaderColon,
    ExpectedEquals,
    ExpectedStatement,
    ExpectedExpression,
    ExpectedNumber,
    ExpectedTarget,
    ExpectedRightBracket,
    ExpectedLeftBrace,
    ExpectedRightBrace,
    ExpectedField,
    ParameterDefaultNotTrailing,
    OwnParameterDefault,
    TypeParameterDefault,
    ComptimeParameterDefault,
    BranchCaseWithColons,
    LengthParameterType,
    ReservedImport,
    CaseWithoutEnum,
    ExpectedBlock,
    UnexpectedIndentation,
    InconsistentIndentation,
    ChainedComparison,
    ExpectedIn,
    ExpectedBranch,
    ExpectedCaseOrElse,
    ElseNotLast,
    NamedCases,
    LabelWithoutSigil,
    MisplacedAny,
    InlineExternal,
    InlineExternalStruct,
    InlineStructFieldCount,
    InlineStructOwnField,
    InlineSignature,
    RangeOperand,
    DiscardedValueName,
    ExpectedDeferredStatement,
    MisplacedOwn,
    MisplacedOwnReceiver,
    ParenthesizedOwnReceiver,
    ParenthesizedPattern,
    MixedOwnNames,
    MisplacedPrivate,
    RepeatedPrivate,
    PrivateInstance,
};

const Sink = struct {
    list: *std.ArrayList(ast.Declaration),
    base: usize,
};

const OperatorToken = struct {
    std.meta.Tag(token.TokenKind),
    ast.BinaryOperator,
};

const ValueNames = struct {
    names: []ast.ElementName = &.{},
    own: bool = false,
    tuple: bool = false,
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

fn isOpening(kind: token.TokenKind) bool {
    return kind == .left_parenthesis or kind == .left_bracket or kind == .left_brace;
}

fn isClosing(kind: token.TokenKind) bool {
    return kind == .right_parenthesis or kind == .right_bracket or kind == .right_brace;
}

fn isArgumentEnd(kind: token.TokenKind) bool {
    return kind == .comma or kind == .right_parenthesis or kind == .right_brace;
}

fn isPostfixStart(kind: token.TokenKind) bool {
    return kind == .dot or kind == .left_bracket or kind == .double_colon or kind == .left_brace;
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

fn findTypeclassSelfParameter(signature: ast.FunctionSignature, parameters: []const ast.TypeclassParameter) ast.SelfParameter {
    if (parameters.len == 0 or parameters[0].arity != 0) return .none;
    return findSelfParameter(signature, parameters[0].name);
}

fn findSelfParameter(signature: ast.FunctionSignature, self_name: []const u8) ast.SelfParameter {
    if (signature.parameters.len == 0) return .none;
    var first = signature.parameters[0].type;
    var self_parameter: ast.SelfParameter = .value;
    if (first.kind == .pointer_type) {
        const pointer_type = first.kind.pointer_type;
        if (pointer_type.many) return .none;
        self_parameter = if (pointer_type.constant) .constant_pointer else .pointer;
        first = pointer_type.target.*;
    }
    if (first.kind != .identifier or !std.mem.eql(u8, first.kind.identifier.name, self_name)) return .none;
    return self_parameter;
}

fn isLiteralType(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .array_type, .tuple_type, .identifier, .path_expression, .call => true,
        else => false,
    };
}

fn buildReceiverExpression(allocator: std.mem.Allocator, name: []const u8, location: token.Location) std.mem.Allocator.Error!ast.Expression {
    if (!std.mem.eql(u8, name, "void") and !std.mem.eql(u8, name, "Self")) {
        return .{ .kind = .{ .identifier = .{ .name = name } }, .location = location };
    }
    const path = try allocator.dupe([]const u8, &.{ ast.module_root, name });
    return .{ .kind = .{ .path_expression = .{ .path = path } }, .location = location };
}

fn isCallOrTriedCall(expression: ast.Expression) bool {
    const call = if (expression.kind == .@"try") expression.kind.@"try".* else expression;
    return call.kind == .call or call.kind == .method_call;
}

fn isBracketed(tokens: []const token.Token) bool {
    var depth: isize = 0;
    for (tokens) |item| {
        switch (item.kind) {
            .left_parenthesis, .left_bracket, .left_brace => depth += 1,
            .right_parenthesis, .right_bracket, .right_brace => depth -= 1,
            else => {},
        }
    }
    return depth > 0;
}

fn buildName(written: ast.PathExpression) ast.Name {
    if (written.path.len == 1) return .{ .identifier = .{ .name = written.path[0] } };
    return .{ .path_expression = written };
}

fn buildNameExpression(written: ast.PathExpression, location: token.Location) ast.Expression {
    if (written.path.len == 1) {
        return .{ .kind = .{ .identifier = .{ .name = written.path[0] } }, .location = location };
    }
    return .{ .kind = .{ .path_expression = written }, .location = location };
}

fn describeError(parse_error: ParseError) []const u8 {
    return switch (parse_error) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedToken => "unexpected token",
        error.ExpectedIdentifier => "expected an identifier",
        error.ExpectedLeftParenthesis => "expected '('",
        error.ExpectedRightParenthesis => "expected ')'",
        error.UnclosedParenthesis => "this '(' has no matching ')'; a line break inside parentheses does not end the statement",
        error.ExpectedColon => "expected ':'",
        error.ExpectedFunctionKeyword => "expected 'fn' or 'struct'",
        error.ExternalFunctionBody => "external functions have no body",
        error.ExpectedTypeParameter => "expected a type parameter, e.g. type T",
        error.ExpectedCase => "expected a case or a function",
        error.ExpectedErrorCase => "expected a case",
        error.ExpectedArrow => "expected '->'",
        error.ExpectedType => "expected a type",
        error.ConstPointerSyntax => "write const(*T) instead of *const T or const *T, with the pointer in parentheses",
        error.ManyPointerSyntax => "write *[many]T instead of *many(T), with many in brackets",
        error.MisplacedMany => "many is written only in brackets directly after *, e.g. *[many]T or const(*[many]T)",
        error.MisplacedSlice => "[]T is allowed only directly after *, since a slice is a pointer: write *[]T or const(*[]T), e.g. *[]u8 instead of []u8",
        error.ConstWithoutPointer => "const(...) is written only around a pointer: const(*T), const(*[N]T), const(*[]T) or const(*[many]T); an optional read-only pointer is ?const(*T)",
        error.ConstInsidePointer => "write const(*T) instead of *const(T), with const around the whole pointer",
        error.HeaderColon => "a block has no ':' before it; write the header alone with the block indented below, e.g. `if count > limit`, or one statement on the same line, e.g. `if (count > limit) trim(list)`, `else 20` or `fn one -> u8 = 1`",
        error.MisplacedTypeDeclaration => "a struct, enum or error set can be declared only at the top level of a module or in the block of a struct or an enum",
        error.NestedSameLineIf => "an if with its block on the same line cannot be in the same-line block of another if, an else or a loop; write else if, or put the inner if in parentheses",
        error.MisplacedBranching => "a match, or an if whose blocks are not all on one line, used as a value must end its statement: after = in a declaration or assignment, after return, as the last line of a function body, or as a branch's value",
        error.ExpectedEquals => "expected '='",
        error.ExpectedStatement => "expected a statement",
        error.ExpectedExpression => "expected an expression",
        error.ExpectedNumber => "expected a number after '-'",
        error.ExpectedTarget => "expression cannot be assigned",
        error.ExpectedRightBracket => "expected ']'",
        error.ExpectedLeftBrace => "expected '{'",
        error.ExpectedRightBrace => "expected '}'",
        error.ExpectedField => "expected a field or a function",
        error.ParameterDefaultNotTrailing => "a parameter after one with a default needs a default too, since only trailing arguments can be left out",
        error.OwnParameterDefault => "an own parameter cannot have a default, since a default is a constant and an own argument hands over a value the caller owns",
        error.TypeParameterDefault => "a type parameter cannot have a default",
        error.ComptimeParameterDefault => "a comptime parameter cannot have a default",
        error.BranchCaseWithColons => "a case of a match is written without a leading ::",
        error.LengthParameterType => "a compile-time parameter of an instance is an array length, written comptime N: usize",
        error.ReservedImport => "an import path cannot start with module::, which names the current module; a directory named module has to be renamed",
        error.CaseWithoutEnum => ast.case_without_enum_message,
        error.ExpectedBlock => "expected an indented block",
        error.UnexpectedIndentation => "unexpected indentation",
        error.InconsistentIndentation => "indentation does not match any outer level",
        error.ChainedComparison => "comparisons cannot be chained, use and",
        error.ExpectedIn => "expected 'in'",
        error.ExpectedBranch => "expected a case",
        error.ExpectedCaseOrElse => "expected 'case' or 'else'",
        error.ElseNotLast => "'else' must be the last branch",
        error.NamedCases => "a branch with several cases cannot name a value",
        error.LabelWithoutSigil => "a label is written '@' and a name, e.g. '@outer while'",
        error.MisplacedAny => "'any' can only be the type of a parameter",
        error.InlineExternal => "an external function cannot be inline",
        error.InlineExternalStruct => "an external struct cannot be inline, since C gives it its layout",
        error.InlineStructFieldCount => "an inline struct has exactly one field, which it is in the generated program",
        error.InlineStructOwnField => "the field of an inline struct cannot be own, since the struct takes the ownership class of its field and has nothing of its own to hold it with",
        error.InlineSignature => "a typeclass function without a body cannot be inline",
        error.RangeOperand => "a range cannot be an operand",
        error.DiscardedValueName => "'as' needs a name, leave it out to leave the value without a name",
        error.ExpectedDeferredStatement => "expected a call, an assignment or a discard",
        error.MisplacedOwn => "own goes before a value that a call takes over, e.g. `list.append(own key)`; a method that takes over its receiver is called with own as its first argument, e.g. `key.deinit(own)`",
        error.MixedOwnNames => "own is written before every name in a case's braces or before none, e.g. `case Pair{ own left, own right }`",
        error.ParenthesizedPattern => "names that take a value apart are written in braces, not parentheses, e.g. `const { name, score } = pair`, `for { card, index } in Zip::zip({ cards, 0.. })` or `while map.pop() as own { key, value }`",
        error.MisplacedPrivate => "private is written only before a top-level declaration other than an import or instance, before a function or type in the block of a struct, an enum or a typeclass, or before a struct field, e.g. `private fn build_text` or `private own storage: *[]T`; at a use it is written between `.` or `::` and the name it crosses to, or before a field of a struct literal, e.g. `list.private.count`, `filesystem::private::build_path` or `{ private.bytes = text }`",
        error.RepeatedPrivate => "private is written once before a declaration, a field or a name",
        error.PrivateInstance => "an instance cannot be private, since instances are always visible wherever their typeclass and type are",
        error.MisplacedOwnReceiver => "own alone hands a method its receiver, so it is only the first argument of a method call, e.g. `key.deinit(own)` or `builder.finish(own, path)`; own before a value moves that value, e.g. `list.append(own key)`",
        error.ParenthesizedOwnReceiver => "a method that takes over its receiver is called with own as its first argument, not with the receiver in parentheses after own, e.g. `key.deinit(own)` or `builder.finish(own, path)`",
    };
}

test "Parser.parse: parses several functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() = noop\nfn two()\n    noop\n");
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
    var lexer = @import("lexer.zig").Lexer.init("\nfn one()\n    noop\n\n    noop\n\nfn two() = noop\n\n");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop\nnoop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseTopLevelStatement: rejects indentation at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseTopLevelStatement: rejects a deeper line after a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const LIMIT = 1\n    use(LIMIT)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseTopLevelStatement: parses constants between functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const one = two\nfn main() = noop\nconst three = four");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(3, module.declarations.len);
    try std.testing.expectEqualStrings("one", module.declarations[0].kind.constant_declaration.name);
    try std.testing.expectEqualStrings("main", module.declarations[1].kind.function_definition.signature.name);
    try std.testing.expectEqualStrings("three", module.declarations[2].kind.constant_declaration.name);
}

test "parseDeclaration: marks each kind of top-level declaration written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("private fn helper() = noop\nprivate inline fn quick() = noop\nprivate external fn write()\nprivate const limit: u8 = 1\nprivate struct Slot\n    value: u8\nprivate enum Mode\n    Read\nprivate error Failure\n    Broken\nprivate typeclass Shape(type T)\n    fn area(value: T) -> u8\nfn open() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const declarations = module.declarations;
    try std.testing.expect(declarations[0].kind.function_definition.signature.private);
    try std.testing.expect(declarations[1].kind.function_definition.signature.private);
    try std.testing.expect(declarations[1].kind.function_definition.signature.@"inline");
    try std.testing.expect(declarations[2].kind.function_declaration.private);
    for (declarations[0..8]) |declaration| try std.testing.expect(declaration.private);
    try std.testing.expect(!declarations[8].private);
    try std.testing.expect(!declarations[8].kind.function_definition.signature.private);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, declarations[0].location);
}

test "parseDeclaration: rejects private before an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("private instance Show(u8)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.PrivateInstance, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
}

test "parseDeclaration: rejects private before an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("private import mn::stream");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, parser.failure.?.location.?);
}

test "matchPrivate: rejects private written twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("private private fn helper() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RepeatedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
}

test "parseFunctionDeclaration: parses an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn stdout_write(text: const(*[]u8))\nfn main() = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("external fn log() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExternalFunctionBody, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    noop\n");
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

test "parseFunctionDefinition: parses an inline function at the top level and in a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline fn double(value: i32) -> i32 = return value * 2\nfn plain() = noop\nstruct Box\n    value: i32\n\n    inline fn get(self: Self) -> i32 = return self.value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[0].kind.function_definition.signature.@"inline");
    try std.testing.expect(!module.declarations[1].kind.function_definition.signature.@"inline");
    try std.testing.expect(module.declarations[3].kind.function_definition.signature.@"inline");
}

test "parseFunctionDefinition: rejects an inline external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline external fn write()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineExternal, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parser.failure.?.location.?);
}

test "parseFunctionDeclaration: rejects an external inline function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external inline fn write()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineExternal, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, parser.failure.?.location.?);
}

test "parseFunctionDefinition: parses an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations.len);
    try std.testing.expectEqualStrings("main", module.declarations[0].kind.function_definition.signature.name);
    try std.testing.expectEqual(1, module.declarations[0].kind.function_definition.body.len);
    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind == .noop);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, module.declarations[0].kind.function_definition.body[0].location);
}

test "parseFunctionDefinition: parses a body after an equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(a: i32, b: i32) -> i32 = a + b");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(ast.BinaryOperator.add, body[0].kind.value.kind.binary.operator);
}

test "parseEqualsBody: gives the block of a function line to the match after the equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn is_space(byte: u8) -> bool = match byte\n    case (space, tab) true\n    else false");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, module.declarations.len);
    const branches = body[0].kind.match.branches;
    try std.testing.expectEqual(2, branches[0].cases.len);
    try std.testing.expect(!branches[1].body[0].kind.value.kind.boolean_literal);
}

test "parseEqualsBody: gives the blocks of a function line to the if after the equals sign and its else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn sign(value: i32) -> i32 = if value < 0\n    low\nelse\n    high");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, module.declarations.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("low", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("high", conditional.else_body.?[0].kind.value.kind.identifier.name);
}

test "parseEqualsBody: gives the block of a function line to a struct without a name after the equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn Make(type T) -> type = struct\n    item: T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqualStrings("item", body[0].kind.value.kind.struct_type.fields[0].name);
}

test "parseEqualsBody: gives the block to the value after the equals sign of an inline function in a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card\n    value: i32\n\n    inline fn rank(self: Self) -> i32 = match self.value\n        case (1) high\n        else low");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[1].kind.function_definition;
    try std.testing.expect(function.signature.@"inline");
    try std.testing.expectEqual(2, function.body[0].kind.match.branches.len);
}

test "parseEqualsBody: gives the block to the value after the equals sign in a typeclass and an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n\n    fn show(value: T) -> i32 = match value\n        case (End) first\n        else second\ninstance Show(Card)\n\n    fn show(value: Card) -> i32 = if value.ready\n        first\n    else\n        second");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const default = module.declarations[0].kind.typeclass_definition.defaults[0].?;
    try std.testing.expectEqual(2, default.body[0].kind.match.branches.len);
    const function = module.declarations[2].kind.function_definition;
    try std.testing.expectEqualStrings("second", function.body[0].kind.@"if".else_body.?[0].kind.value.kind.identifier.name);
}

test "parseEqualsBody: rejects a deeper line after a body without an if, a match or a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(a: i32, b: i32) -> i32 = a + b\n    use(a)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseFunctionSignature: accepts a reserved word as the name of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn match(pattern: const(*[]u8)) -> bool = return true");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("match", module.declarations[0].kind.function_definition.signature.name);
}

test "parseFunctionSignature: parses the types a function declares after fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline fn(type Item, type Other: Show) pair(item: Item, other: Other) -> usize = return 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const signature = module.declarations[0].kind.function_definition.signature;
    try std.testing.expect(signature.@"inline");
    try std.testing.expectEqualStrings("pair", signature.name);
    try std.testing.expectEqual(2, signature.declared.len);
    try std.testing.expectEqualStrings("Item", signature.declared[0].name);
    try std.testing.expectEqual(0, signature.declared[0].requirements.len);
    try std.testing.expectEqualStrings("Other", signature.declared[1].name);
    try std.testing.expectEqualStrings("Show", signature.declared[1].requirements[0].kind.identifier.name);
    try std.testing.expectEqual(2, signature.parameters.len);
}

test "parseFunctionSignature: rejects a reserved word as the name of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn find(match: const(*[]u8)) -> bool = return true");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
}

test "parseFunctionSignature: rejects parameters without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main x: i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
}

test "parseFunctionSignature: parses a function without parentheses and an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[0].kind.function_definition;
    try std.testing.expectEqualStrings("main", function.signature.name);
    try std.testing.expectEqual(0, function.signature.parameters.len);
    try std.testing.expect(function.body[0].kind == .noop);
}

test "parseFunctionSignature: parses a return type without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer -> i32 = 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[0].kind.function_definition;
    try std.testing.expectEqualStrings("i32", function.signature.return_type.kind.identifier.name);
    try std.testing.expectEqualStrings("42", function.body[0].kind.value.kind.integer_literal.text);
}

test "parseFunctionSignature: parses a return type whose error set is left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn load(path: const(*[]u8)) -> !usize = 0");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const signature = module.declarations[0].kind.function_definition.signature;
    try std.testing.expectEqualStrings("usize", signature.return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, signature.inferred_error_set.?);
}

test "parseFunctionSignature: keeps a written error set apart from a left out one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main -> ParseError!void = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const signature = module.declarations[0].kind.function_definition.signature;
    try std.testing.expectEqual(null, signature.inferred_error_set);
    try std.testing.expectEqual(ast.BinaryOperator.result, signature.return_type.kind.binary.operator);
}

test "parseFunctionSignature: rejects a left out error set without a value type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn load -> ! = 0");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "opensHeaderBlock: rejects a colon after a function signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 10 }, parser.failure.?.location.?);
}

test "parseParameters: parses each parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: u8) -> i32 = return 1");
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
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32,) -> i32 = return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.signature.parameters.len);
}

test "parseParameters: parses parameters over several lines with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn create(\n    path: Path,\n\n    # options\n    options: Options = {},\n) -> Error!void\n    noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.function_definition;
    try std.testing.expectEqual(2, definition.signature.parameters.len);
    try std.testing.expectEqualStrings("path", definition.signature.parameters[0].name);
    try std.testing.expectEqualStrings("options", definition.signature.parameters[1].name);
    try std.testing.expect(definition.signature.parameters[1].default != null);
    try std.testing.expectEqual(2, definition.body.len);
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 5 }, definition.body[0].location);
}

test "parseParameters: rejects a parameter without a default after one with a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn draw(width: i32 = 1, filled: bool) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParameterDefaultNotTrailing, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseParameter: parses an underscore as a discarded parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f(_: i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqualStrings("_", parameter.name);
    try std.testing.expectEqualStrings("i32", parameter.type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 6 }, parameter.location);
}

test "parseAnyParameter: parses a parameter of type any" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn count(values: any, _: any) -> usize = return 0");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(.any, parameters[0].kind);
    try std.testing.expectEqualStrings("values", parameters[0].name);
    try std.testing.expectEqual(.any, parameters[1].kind);
    try std.testing.expectEqualStrings("_", parameters[1].name);
}

test "parseOperand: rejects any as the type of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var value: any = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x: any");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as a return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> any = return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the element of a slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(values: *[]any) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the target of a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(value: *any) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseOperand: rejects many without an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: many(u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects many without an asterisk in an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: ?many(u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the type of a comptime parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(comptime value: any) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseOperand: ends the last block of a one-line if argument at the comma and the closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = run(if (fast) high else low, rest)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const call = body[0].kind.call.kind.call;
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("low", call.arguments[0].value.kind.branching.kind.@"if".else_body.?[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("rest", call.arguments[1].value.kind.identifier.name);
}

test "parseOperand: extends the last block of a one-line if after an operator to the end of the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const total: u32 = base + if (bonus) 10 else low + high\n    use(total)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const sum = body[0].kind.constant_declaration.value.kind.binary;
    const conditional = sum.right.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("high", conditional.else_body.?[0].kind.value.kind.binary.right.kind.identifier.name);
}

test "parseOperand: parses a one-line if in parentheses after an operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const total: u32 = base + (if (bonus) 10 else 0)\n    use(total)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const sum = body[0].kind.constant_declaration.value.kind.binary;
    try std.testing.expectEqualStrings("base", sum.left.kind.identifier.name);
    try std.testing.expectEqualStrings("bonus", sum.right.kind.branching.kind.@"if".condition.kind.identifier.name);
}

test "parseOperand: rejects an if inside an expression whose block is not on its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const total: i32 = 1 + if big\n        high\n    else low");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedBranching, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, parser.failure.?.location.?);
}

test "parseOperand: rejects a match as an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = use(match token)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedBranching, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseParameter: parses a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T, value: T) -> T = return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(ast.ParameterKind.type, parameters[0].kind);
    try std.testing.expectEqualStrings("T", parameters[0].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parameters[0].location);
    try std.testing.expectEqual(ast.ParameterKind.run_time, parameters[1].kind);
}

test "parseParameter: parses the requirement of a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T: Default) -> T = return Default(T)::value()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(ast.ParameterKind.type, parameter.kind);
    try std.testing.expectEqualStrings("Default", parameter.requirements[0].kind.identifier.name);
}

test "parseRequirements: parses requirements joined with and on a type parameter, a declared type, an instance parameter and a typeclass parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T: Default and Show) -> T = return Default(T)::value()\nfn(type E: Show and Eq) show(value: E) = noop\ninstance(type K: Hash and Eq, type V: Show) Show(HashMap(K, V))\ntypeclass Ord(type T: Eq and Show)\n\n    fn less(one: T, two: T) -> bool");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(2, parameter.requirements.len);
    try std.testing.expectEqualStrings("Default", parameter.requirements[0].kind.identifier.name);
    try std.testing.expectEqualStrings("Show", parameter.requirements[1].kind.identifier.name);
    const declared = module.declarations[1].kind.function_definition.signature.declared[0];
    try std.testing.expectEqual(2, declared.requirements.len);
    try std.testing.expectEqualStrings("Eq", declared.requirements[1].kind.identifier.name);
    const instance_parameters = module.declarations[2].kind.instance_declaration.parameters;
    try std.testing.expectEqual(2, instance_parameters[0].requirements.len);
    try std.testing.expectEqualStrings("Hash", instance_parameters[0].requirements[0].kind.identifier.name);
    try std.testing.expectEqualStrings("Eq", instance_parameters[0].requirements[1].kind.identifier.name);
    try std.testing.expectEqual(1, instance_parameters[1].requirements.len);
    const typeclass_parameter = module.declarations[3].kind.typeclass_definition.parameters[0];
    try std.testing.expectEqual(2, typeclass_parameter.requirements.len);
    try std.testing.expectEqualStrings("Show", typeclass_parameter.requirements[1].kind.identifier.name);
}

test "parseRequirements: parses a requirement with arguments joined with and on a type parameter and an instance parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn decode(self: *D, type T: codec::Decode(_, D) and Show) -> T = noop\ninstance(type A: Encode(_, E), type E: Encoder) Encode(?A, E)\n\n    fn encode(value: const(*Self), encoder: *E) -> !void = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[1];
    try std.testing.expectEqual(2, parameter.requirements.len);
    const call = parameter.requirements[0].kind.call;
    try std.testing.expectEqualStrings("Decode", call.callee.path_expression.path[1]);
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expect(call.arguments[0].value.kind == .inferred_type);
    try std.testing.expectEqualStrings("D", call.arguments[1].value.kind.identifier.name);
    try std.testing.expectEqualStrings("Show", parameter.requirements[1].kind.identifier.name);
    const instance_parameter = module.declarations[1].kind.instance_declaration.parameters[0];
    try std.testing.expectEqualStrings("Encode", instance_parameter.requirements[0].kind.call.callee.identifier.name);
}

test "parseRequirements: rejects and without a typeclass after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T: Default and) -> T = return Default(T)::value()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, parser.failure.?.location.?);
}

test "parseParameter: parses a comptime parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn repeat(comptime count: usize) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(ast.ParameterKind.compile_time, parameter.kind);
    try std.testing.expectEqualStrings("count", parameter.name);
    try std.testing.expectEqualStrings("usize", parameter.type.kind.identifier.name);
}

test "parseParameter: rejects comptime without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn repeat(comptime) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseParameter: parses a default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn draw(width: i32, filled: bool = true) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(null, parameters[0].default);
    try std.testing.expect(parameters[1].default.?.kind.boolean_literal);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 36 }, parameters[1].default.?.location);
}

test "parseParameter: parses a default value of an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn draw(width: i32 = 1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const default = module.declarations[0].kind.function_declaration.parameters[0].default.?;
    try std.testing.expectEqualStrings("1", default.kind.integer_literal.text);
}

test "parseParameter: rejects a default of an own parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn keep(own data: *[]u8 = undefined) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.OwnParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseParameter: rejects a default of a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T = u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.TypeParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseParameter: rejects a default of a comptime parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn repeat(comptime count: usize = 2) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ComptimeParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, parser.failure.?.location.?);
}

test "parseReturnType: reads a written return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() -> i32 = return 42");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const return_type = module.declarations[0].kind.function_definition.signature.return_type;
    try std.testing.expectEqualStrings("void", return_type.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, return_type.location);
}

test "parseReturnType: rejects an arrow without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() -> = return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a type without an arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32 = return 42");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseReturnType: rejects a slice type without an arrow in a function without a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn read() *[]u8");
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
    var lexer = @import("lexer.zig").Lexer.init("external fn pair() [i32, bool]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseIndentedBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    noop\n    =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "parseIndentedBlock: rejects a deeper line after a line that cannot open a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const count = 1\n        use(count)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseIndentedBlock: rejects a deeper line after a same-line body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) start()\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseIndentedBlock: ends nested blocks at the depth of an enclosing block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while one\n        while two\n            step()\n    done()");
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

test "parseIndentedBlock: accepts a return as the last statement of a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    a = 1\n    return\nfn other() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expect(body[1].kind == .@"return");
}

test "parseIndentedBlock: parses the line after a call over several lines as its own statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    run(\n        1,\n    )\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqualStrings("run", body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", body[1].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, body[1].location);
}

test "parseIndentedBlock: accepts a statement after a loop whose inline block returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while (true) return\n    a = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expect(body[1].kind == .assignment);
}

test "parseBlockLine: parses an expression on the last line of a block as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick() -> i32\n    step()\n    one + two");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqualStrings("one", body[1].kind.value.kind.binary.left.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, body[1].location);
}

test "parseHandedValue: parses own before a name as the value of a branch of an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(flag: bool) -> i32\n    if flag\n        own one\n    else two");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const conditional = module.declarations[0].kind.function_definition.body[0].kind.@"if";
    try std.testing.expectEqualStrings("one", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expect(conditional.body[0].kind.value.handed);
    try std.testing.expect(!conditional.else_body.?[0].kind.value.handed);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 13 }, conditional.body[0].location);
}

test "parseHandedValue: parses own before a name as the value of a match branch on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(choice: Choice) -> i32\n    match choice\n        case (One) own one\n        else two");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const matching = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqualStrings("one", matching.branches[0].body[0].kind.value.kind.identifier.name);
    try std.testing.expect(matching.branches[0].body[0].kind.value.handed);
    try std.testing.expect(!matching.branches[1].body[0].kind.value.handed);
}

test "parseHandedValue: rejects own before a name on the last line of a function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick() -> i32\n    own one");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedOwn, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseHandedValue: rejects own before a name in the body of a loop inside a branch of an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(flag: bool)\n    if flag\n        while true\n            own one");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedOwn, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 13 }, parser.failure.?.location.?);
}

test "parseInlineBlock: rejects line that is not a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseInlineBlock: parses an expression as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(one: bool) -> i32\n    if (one) first\n    else second");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("first", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("second", conditional.else_body.?[0].kind.value.kind.identifier.name);
}

test "parseStatement: parses a constant inside a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const limit: i32 = 5\n    noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn answer() -> u8\n    return 42\n");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    return\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind == .@"return");
    try std.testing.expectEqual(null, module.declarations[0].kind.function_definition.body[0].kind.@"return");
}

test "parseReturn: rejects return followed by a non-expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = return =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseValue: parses an if after the equals sign of a constant with its else on the next line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const limit: u32 = if (strict) low\n    else high\n    use(limit)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const conditional = body[0].kind.constant_declaration.value.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("low", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("high", conditional.else_body.?[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("use", body[1].kind.call.kind.call.callee.identifier.name);
}

test "parseValue: gives the block of a constant line to its match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const kind = match token\n        case (End) first\n        else second\n    use(kind)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const matching = body[0].kind.constant_declaration.value.kind.branching.kind.match;
    try std.testing.expectEqualStrings("second", matching.branches[1].body[0].kind.value.kind.identifier.name);
}

test "parseValue: gives the blocks of a return line to its if and else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(big: bool) -> i32\n    return if big\n        high\n    else\n        low");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"return".?.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("high", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("low", conditional.else_body.?[0].kind.value.kind.identifier.name);
}

test "parseValue: gives the block of an assignment line to its if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    total = if big\n        high\n    else low");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.assignment.value.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("high", conditional.body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("low", conditional.else_body.?[0].kind.value.kind.identifier.name);
}

test "parseValue: parses a match after return with its branches indented under the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(token: Token) -> i32\n    return match token\n        case (Number) first\n        else second");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const matching = body[0].kind.@"return".?.kind.branching.kind.match;
    try std.testing.expectEqual(2, matching.branches.len);
    try std.testing.expectEqualStrings("second", matching.branches[1].body[0].kind.value.kind.identifier.name);
}

test "parseValue: parses an if after the equals sign of an assignment and of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var total = if (big) high\n    else low\n    total = if (big) low\n    else high");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqualStrings("high", body[0].kind.variable_declaration.value.kind.branching.kind.@"if".body[0].kind.value.kind.identifier.name);
    try std.testing.expectEqualStrings("low", body[1].kind.assignment.value.kind.branching.kind.@"if".body[0].kind.value.kind.identifier.name);
}

test "parseIf: parses a condition and a body without an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if ready\n        step()\n    done()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("ready", conditional.condition.kind.identifier.name);
    try std.testing.expectEqual(1, conditional.body.len);
    try std.testing.expectEqual(null, conditional.else_body);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, body[0].location);
    try std.testing.expect(body[1].kind == .call);
}

test "parseIf: takes the rest of the line as the condition before a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if count > limit\n        trim(list)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(ast.BinaryOperator.greater_than, conditional.condition.kind.binary.operator);
    try std.testing.expectEqualStrings("trim", conditional.body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: takes the whole line as the condition when a block follows a group in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready or late) and valid\n        start()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const condition = body[0].kind.@"if".condition.kind.binary;
    try std.testing.expectEqual(ast.BinaryOperator.@"and", condition.operator);
    try std.testing.expectEqual(ast.BinaryOperator.@"or", condition.left.kind.binary.operator);
}

test "parseIf: takes the group in parentheses as the condition when no block follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) start()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("ready", conditional.condition.kind.identifier.name);
    try std.testing.expectEqualStrings("start", conditional.body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses an else block and an else with its statement on the same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if ready\n        start()\n    else\n        stop()\n    if late\n        hurry()\n    else wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqualStrings("stop", body[0].kind.@"if".else_body.?[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("wait", body[1].kind.@"if".else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses a value name inside the parentheses of a same-line condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (found as card) show(card)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("card", conditional.names[0].name);
    try std.testing.expectEqualStrings("found", conditional.condition.kind.identifier.name);
}

test "expectHeaderEnd: rejects a colon after a condition before a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if ready:\n        start()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, parser.failure.?.location.?);
}

test "openSameLineHeader: rejects a colon after a same-line condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if ready: start()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseIf: parses an else block on the line after the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if ready\n        step()\n    else\n        wait()\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(1, conditional.body.len);
    try std.testing.expectEqual(2, conditional.else_body.?.len);
}

test "parseIf: parses an else if chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if one\n        first()\n    else if two\n        second()\n    else\n        third()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const else_body = body[0].kind.@"if".else_body.?;
    try std.testing.expectEqual(1, else_body.len);
    const chained = else_body[0].kind.@"if";
    try std.testing.expectEqualStrings("two", chained.condition.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, else_body[0].location);
    try std.testing.expectEqual(1, chained.else_body.?.len);
    try std.testing.expectEqualStrings("third", chained.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses an else after an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) step()\n    else wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(1, conditional.body.len);
    try std.testing.expectEqualStrings("wait", conditional.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses an else on the same line as an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if (ready) start() else wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqualStrings("start", conditional.body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("wait", conditional.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses an else if chain on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if (ready) start() else if (late) hurry() else wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const chained = body[0].kind.@"if".else_body.?[0].kind.@"if";
    try std.testing.expectEqualStrings("hurry", chained.body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("wait", chained.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: parses an else on the same line in a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const limit: u32 = if (strict) low else high\n    use(limit)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const conditional = body[0].kind.constant_declaration.value.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("high", conditional.else_body.?[0].kind.value.kind.identifier.name);
}

test "parseIf: gives an else on the next line to the last if of a chain on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) start() else if (late) hurry()\n    else wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const chained = body[0].kind.@"if".else_body.?[0].kind.@"if";
    try std.testing.expectEqualStrings("wait", chained.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: rejects an if with a same-line block in the same-line block of another if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if (ready) if (valid) start() else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NestedSameLineIf, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, parser.failure.?.location.?);
}

test "parseIf: parses an if after a same-line else as a chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const size: u32 = if (small) 1 else if (huge) 3 else 2\n    use(size)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const chained = body[0].kind.constant_declaration.value.kind.branching.kind.@"if".else_body.?[0].kind.@"if";
    try std.testing.expectEqualStrings("2", chained.else_body.?[0].kind.value.kind.integer_literal.text);
}

test "parseIf: rejects an if with a same-line block after the equals sign in the same-line block of another if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if (ready) total = if (fast) 1 else 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NestedSameLineIf, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, parser.failure.?.location.?);
}

test "parseIf: rejects an if with a same-line block in the same-line block of a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = while (ready) if (valid) start()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NestedSameLineIf, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, parser.failure.?.location.?);
}

test "parseIf: accepts an if in parentheses in the same-line block of an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const size: u32 = if (small) 1 else (if (huge) 3 else 2)\n    use(size)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.constant_declaration.value.kind.branching.kind.@"if";
    const inner = conditional.else_body.?[0].kind.value.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("2", inner.else_body.?[0].kind.value.kind.integer_literal.text);
}

test "parseIf: accepts an if in the arguments of a call in the same-line block of another if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if (ready) run(if (fast) 1 else 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const call = body[0].kind.@"if".body[0].kind.call.kind.call;
    const inner = call.arguments[0].value.kind.branching.kind.@"if";
    try std.testing.expectEqualStrings("1", inner.body[0].kind.value.kind.integer_literal.text);
}

test "parseIf: parses a header in parentheses over several lines before a same-line block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (\n        ready and\n            open\n    ) step() else wait()\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(ast.BinaryOperator.@"and", conditional.condition.kind.binary.operator);
    try std.testing.expectEqualStrings("step", conditional.body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("wait", conditional.else_body.?[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", body[1].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: accepts an if in the same-line block of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn sign(x: i32) -> i32 = if (x < 0) -1 else 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqualStrings("1", body[0].kind.@"if".else_body.?[0].kind.value.kind.integer_literal.text);
}

test "parseIf: accepts an if in the same-line block of a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn pick(value: u8, flag: bool) -> u8\n    match value\n        case (0) if (flag) 1 else 2\n        else 3");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const conditional = body[0].kind.match.branches[0].body[0].kind.@"if";
    try std.testing.expectEqualStrings("2", conditional.else_body.?[0].kind.value.kind.integer_literal.text);
}

test "parseIf: rejects a same-line condition without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = if ready step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseIf: records own written before the tested value of an if, a while and a match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if own found as own entry\n        noop\n    while own found as own entry\n        noop\n    match own found\n        else noop\n    if found as own entry\n        noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, body[0].kind.@"if".marker.?);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 11 }, body[1].kind.@"while".marker.?);
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 11 }, body[2].kind.match.marker.?);
    try std.testing.expectEqual(null, body[3].kind.@"if".marker);
}

test "parseWhile: parses a condition and an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while running\n        step()\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const loop = statement.kind.@"while";
    try std.testing.expectEqualStrings("running", loop.condition.kind.identifier.name);
    try std.testing.expectEqual(2, loop.body.len);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseWhile: parses a condition before a block and a same-line body after parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while index < count\n        step()\n    while (running) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(ast.BinaryOperator.less_than, body[0].kind.@"while".condition.kind.binary.operator);
    try std.testing.expectEqualStrings("running", body[1].kind.@"while".condition.kind.identifier.name);
    try std.testing.expectEqualStrings("step", body[1].kind.@"while".body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseWhile: parses a header in parentheses over several lines before a same-line block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while (\n        running\n    ) step()\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqualStrings("running", body[0].kind.@"while".condition.kind.identifier.name);
    try std.testing.expectEqualStrings("step", body[0].kind.@"while".body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", body[1].kind.call.kind.call.callee.identifier.name);
}

test "parseWhile: gives the block to the while and keeps a one-line if in its condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while index < (if (strict) high else low)\n        step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const loop = body[0].kind.@"while";
    try std.testing.expectEqualStrings("strict", loop.condition.kind.binary.right.kind.branching.kind.@"if".condition.kind.identifier.name);
    try std.testing.expectEqualStrings("step", loop.body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseWhile: parses an inline body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = while (running) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expectEqual(1, loop.body.len);
    try std.testing.expect(loop.body[0].kind == .call);
}

test "parseWhile: rejects a same-line condition without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = while running step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseWhile: parses a label before the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer while (running) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const loop = statement.kind.@"while";
    try std.testing.expectEqualStrings("outer", loop.label.?);
    try std.testing.expectEqualStrings("running", loop.condition.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseWhile: parses an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while running\n        step()\n    else\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const loop = body[0].kind.@"while";
    try std.testing.expectEqual(null, loop.label);
    try std.testing.expectEqualStrings("stop", loop.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseWhile: rejects an if with a same-line block in the same-line else of a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while (running) step()\n    else if (done) stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NestedSameLineIf, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, parser.failure.?.location.?);
}

test "parseConditionNames: parses a value name after an if condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (found as *card) noop\n    else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const conditional = module.declarations[0].kind.function_definition.body[0].kind.@"if";
    try std.testing.expectEqualStrings("found", conditional.condition.kind.identifier.name);
    try std.testing.expectEqual(1, conditional.names.len);
    try std.testing.expectEqualStrings("card", conditional.names[0].name);
    try std.testing.expect(conditional.names[0].pointer);
    try std.testing.expect(conditional.else_body != null);
}

test "parseConditionNames: parses a value name after a while condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while (queue.pop() as job) run(job)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expect(loop.condition.kind == .method_call);
    try std.testing.expectEqualStrings("job", loop.names[0].name);
    try std.testing.expect(!loop.names[0].pointer);
}

test "parseConditionNames: leaves a condition without as unnamed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(0, module.declarations[0].kind.function_definition.body[0].kind.@"if".names.len);
}

test "parseConditionNames: parses own names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while found as own { key, _ }\n        noop\n    if (found as { key }) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const loop = body[0].kind.@"while";
    try std.testing.expect(loop.own);
    try std.testing.expect(loop.tuple);
    try std.testing.expectEqualStrings("found", loop.condition.kind.identifier.name);
    try std.testing.expectEqual(2, loop.names.len);
    try std.testing.expectEqualStrings("key", loop.names[0].name);
    try std.testing.expectEqualStrings("_", loop.names[1].name);
    const conditional = body[1].kind.@"if";
    try std.testing.expect(!conditional.own);
    try std.testing.expect(conditional.tuple);
    try std.testing.expectEqual(1, conditional.names.len);
}

test "parseValueNames: rejects a pointer name after own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (found as own *card) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, parser.failure.?.location.?);
}

test "parseValueNames: rejects a pointer name inside own names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while map.pop() as own { key, *value }\n        noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 35 }, parser.failure.?.location.?);
}

test "parseFor: parses a name, a sequence and an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    for item in items\n        step()\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const loop = statement.kind.@"for";
    try std.testing.expectEqualStrings("item", loop.names[0].name);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 9 }, loop.names[0].location);
    try std.testing.expect(!loop.tuple);
    try std.testing.expectEqualStrings("items", loop.sequence.value.kind.identifier.name);
    try std.testing.expectEqual(2, loop.body.len);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseFor: parses a header before a block and a same-line body after parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    for card in cards\n        show(card)\n    for ({ name, score } in pairs) show(name, score)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqualStrings("card", body[0].kind.@"for".names[0].name);
    const loop = body[1].kind.@"for";
    try std.testing.expect(loop.tuple);
    try std.testing.expectEqualStrings("score", loop.names[1].name);
    try std.testing.expectEqualStrings("pairs", loop.sequence.value.kind.identifier.name);
}

test "parseFor: parses a header in parentheses over several lines before a same-line block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    for (\n        card in\n        cards\n    ) show(card)\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const loop = body[0].kind.@"for";
    try std.testing.expectEqualStrings("card", loop.names[0].name);
    try std.testing.expectEqualStrings("cards", loop.sequence.value.kind.identifier.name);
    try std.testing.expectEqualStrings("show", loop.body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", body[1].kind.call.kind.call.callee.identifier.name);
}

test "parseFor: parses a label, an inline body and an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer for (item in items) step()\n    else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const loop = body[0].kind.@"for";
    try std.testing.expectEqualStrings("outer", loop.label.?);
    try std.testing.expectEqualStrings("step", loop.body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", loop.else_body.?[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, body[0].location);
}

test "parseFor: rejects a missing in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (item items) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIn, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "parseFor: rejects a same-line header without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for item in items step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseElementNames: parses names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for ({ name, *score, _ } in pairs) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expect(loop.tuple);
    try std.testing.expectEqual(3, loop.names.len);
    try std.testing.expectEqualStrings("name", loop.names[0].name);
    try std.testing.expect(!loop.names[0].pointer);
    try std.testing.expectEqualStrings("score", loop.names[1].name);
    try std.testing.expect(loop.names[1].pointer);
    try std.testing.expectEqualStrings("_", loop.names[2].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, loop.names[1].location);
}

test "parseElementNames: parses one name in parentheses as a tuple pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for ({ name } in pairs) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expect(loop.tuple);
    try std.testing.expectEqualStrings("name", loop.names[0].name);
}

test "parseElementNames: rejects names in braces inside names in braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for ({ name, { score, rank } } in pairs) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
}

test "parseElementNames: rejects a missing closing brace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for ({ name, score in pairs) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBrace, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, parser.failure.?.location.?);
}

test "parseElementNames: rejects names in parentheses after for and as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while map.pop() as own (key, value)\n        noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParenthesizedPattern, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, parser.failure.?.location.?);
}

test "parseElementName: parses an underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (_ in items) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expectEqualStrings("_", loop.names[0].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, loop.names[0].location);
}

test "parseElementName: rejects a name that is not an identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (5 in items) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseElementName: parses a pointer name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (*card in cards) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expectEqualStrings("card", loop.names[0].name);
    try std.testing.expect(loop.names[0].pointer);
    try std.testing.expect(!loop.tuple);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, loop.names[0].location);
}

test "parseElementName: rejects a pointer to an underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (*_ in cards) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseSequence: parses ranges with and without an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    for (index in 0..) step()\n    for (index in 1..limit) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const open = body[0].kind.@"for".sequence.range;
    try std.testing.expectEqualStrings("0", open.start.kind.integer_literal.text);
    try std.testing.expectEqual(null, open.end);
    const closed = body[1].kind.@"for".sequence.range;
    try std.testing.expectEqualStrings("1", closed.start.kind.integer_literal.text);
    try std.testing.expectEqualStrings("limit", closed.end.?.kind.identifier.name);
}

test "parseSequence: parses a value in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (item in (items)) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const sequence = module.declarations[0].kind.function_definition.body[0].kind.@"for".sequence;
    try std.testing.expectEqualStrings("items", sequence.value.kind.identifier.name);
}

test "parseSequence: parses a range whose start is in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (index in (start)..end) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const range = module.declarations[0].kind.function_definition.body[0].kind.@"for".sequence.range;
    try std.testing.expectEqualStrings("start", range.start.kind.identifier.name);
    try std.testing.expectEqualStrings("end", range.end.?.kind.identifier.name);
}

test "parseSequence: rejects a missing sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = for (item in) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseMatch: parses branches with several cases, value names and an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (Number{ *digits }) step()\n        case Name, End\n            stop()\n        case (Token::Other{ _ }) noop\n        else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const match = statement.kind.match;
    try std.testing.expectEqualStrings("token", match.value.kind.identifier.name);
    try std.testing.expectEqual(4, match.branches.len);
    try std.testing.expectEqual(4, match.names.len);
    try std.testing.expectEqualStrings("Number", match.branches[0].cases[0].pattern.kind.identifier.name);
    try std.testing.expectEqual(.payload, match.branches[0].naming);
    try std.testing.expectEqualStrings("digits", match.names[0].name);
    try std.testing.expect(match.names[0].pointer);
    try std.testing.expectEqual(2, match.branches[1].cases.len);
    try std.testing.expectEqualStrings("End", match.branches[1].cases[1].pattern.kind.identifier.name);
    try std.testing.expectEqual(.none, match.branches[1].naming);
    try std.testing.expectEqualStrings("stop", match.branches[1].body[0].kind.call.kind.call.callee.identifier.name);
    const path = match.branches[2].cases[0].pattern.kind.path_expression.path;
    try std.testing.expectEqualStrings("Token", path[0]);
    try std.testing.expectEqualStrings("Other", path[1]);
    try std.testing.expectEqual(.payload, match.branches[2].naming);
    try std.testing.expectEqualStrings("_", match.names[2].name);
    try std.testing.expectEqual(0, match.branches[3].cases.len);
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 9 }, match.branches[3].location);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseMatch: parses branches with blocks and branches on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case Number{ digits }\n            use(digits)\n        case (End) stop()\n        else\n            noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const branches = body[0].kind.match.branches;
    try std.testing.expectEqual(3, branches.len);
    try std.testing.expectEqual(ast.Naming.payload, branches[0].naming);
    try std.testing.expectEqualStrings("stop", branches[1].body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqual(0, branches[2].cases.len);
}

test "parseMatch: rejects a colon after the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token:\n        case (End) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseMatch: rejects a match without a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseMatch: rejects a branch after else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        else noop\n        case (End) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ElseNotLast, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 9 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a value name in a branch with several cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (Name, End{ value }) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 24 }, parser.failure.?.location.?);
}

test "parseBranch: parses several cases and a payload name in braces on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (Space, Tab) true\n        case (Number{ digits }) total += digits\n        else false");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const branches = body[0].kind.match.branches;
    try std.testing.expectEqual(2, branches[0].cases.len);
    try std.testing.expect(branches[0].body[0].kind.value.kind.boolean_literal);
    try std.testing.expectEqualStrings("digits", body[0].kind.match.names[1].name);
    try std.testing.expect(branches[1].body[0].kind == .assignment);
}

test "parseBranch: parses cases in parentheses over several lines before a same-line block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (\n            Space,\n            Tab\n        ) skip()\n        else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const branches = module.declarations[0].kind.function_definition.body[0].kind.match.branches;
    try std.testing.expectEqual(2, branches.len);
    try std.testing.expectEqual(2, branches[0].cases.len);
    try std.testing.expectEqualStrings("Tab", branches[0].cases[1].pattern.kind.identifier.name);
    try std.testing.expectEqualStrings("skip", branches[0].body[0].kind.call.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("stop", branches[1].body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseBranch: numbers the names of each branch and parses own names in parentheses after a case and after else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match found\n        case Pair as own { key, value }\n            noop\n        case null\n            noop\n    match pair\n        case (Pair as { one, two }) noop\n        else (_ as own { three, four }) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const first = body[0].kind.match;
    try std.testing.expectEqual(3, first.names.len);
    try std.testing.expect(first.branches[0].own and first.branches[0].tuple);
    try std.testing.expectEqual(0, first.branches[0].first_name);
    try std.testing.expectEqual(2, first.branches[0].name_count);
    try std.testing.expectEqualStrings("value", first.names[1].name);
    try std.testing.expect(!first.branches[1].own and !first.branches[1].tuple);
    try std.testing.expectEqual(2, first.branches[1].first_name);
    try std.testing.expectEqual(1, first.branches[1].name_count);
    const second = body[1].kind.match;
    try std.testing.expect(!second.branches[0].own and second.branches[0].tuple);
    try std.testing.expect(second.branches[1].own and second.branches[1].tuple);
    try std.testing.expectEqual(2, second.branches[1].first_name);
    try std.testing.expectEqualStrings("four", second.names[3].name);
}

test "parseBranch: rejects a colon after the cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case End:\n            noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 17 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a case after a value name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (Number{ value }, End) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 30 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after as in a branch with several cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (null, Card as card) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 26 }, parser.failure.?.location.?);
}

test "parseBranch: parses a name after else on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        case (One) noop\n        else (_ as rest) rest");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const matching = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(ast.Naming.value, matching.branches[1].naming);
    try std.testing.expectEqual(0, matching.branches[1].cases.len);
    try std.testing.expectEqualStrings("rest", matching.names[1].name);
    try std.testing.expectEqualStrings("rest", matching.branches[1].body[0].kind.value.kind.identifier.name);
}

test "parseBranch: parses a name after else before an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        case (One) noop\n        else _ as rest\n            first()\n            rest");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const matching = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(ast.Naming.value, matching.branches[1].naming);
    try std.testing.expectEqualStrings("rest", matching.names[1].name);
    try std.testing.expectEqual(2, matching.branches[1].body.len);
}

test "parseBranch: tells a name after else from a discard and from an expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else _ = call()\n    match value\n        else (result)\n    match value\n        else\n            _ = call()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(ast.Naming.none, body[0].kind.match.branches[0].naming);
    try std.testing.expect(body[0].kind.match.branches[0].body[0].kind == .discard);
    try std.testing.expectEqual(ast.Naming.none, body[1].kind.match.branches[0].naming);
    try std.testing.expectEqualStrings("result", body[1].kind.match.branches[0].body[0].kind.value.kind.identifier.name);
    try std.testing.expect(body[2].kind.match.branches[0].body[0].kind == .discard);
}

test "parseBranch: parses a pointer name after else for the checker to reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else _ as *rest\n            noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[0].kind.function_definition.body[0].kind.match.names[0].pointer);
}

test "parseBranch: rejects a discarded name after else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else (_ as _) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.DiscardedValueName, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 20 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after else in parentheses before an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else (_ as rest)\n            noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 14 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after else without parentheses on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else _ as rest noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 16 }, parser.failure.?.location.?);
}

test "parseValue: parses a try on a match as the value of a declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const file = try match open()\n        case (One) make()\n        else (_ as rest) rest\n    use(file)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const operand = body[0].kind.constant_declaration.value.kind.@"try";
    try std.testing.expectEqual(2, operand.kind.branching.kind.match.branches.len);
}

test "parseStatement: parses a try on a match as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    try match open()\n        case (One) noop\n        else (_ as rest) rest\n    use()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expect(body[0].kind.call.kind.@"try".kind == .branching);
}

test "parseTry: rejects a match after try that does not start the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const value = 1 + try match open()\n        else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedBranching, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 27 }, parser.failure.?.location.?);
}

test "parseTry: rejects a match after try on the line of a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) try match open()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedBranching, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after else without as on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else (_ rest) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after else without as before an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n        else _ rest\n            noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 14 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a branch without a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case ()) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBranch, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a branch without the case keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        end: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCaseOrElse, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, parser.failure.?.location.?);
}

test "parseBranchCase: parses a type with a value name, null, values and ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (*Card as *card) noop\n        case (null) noop\n        case (-1, 3..10) noop\n        case (20..) noop\n        case (Box(i32) as box) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const match = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(.value, match.branches[0].naming);
    try std.testing.expectEqualStrings("Card", match.branches[0].cases[0].pattern.kind.pointer_type.target.kind.identifier.name);
    try std.testing.expectEqualStrings("card", match.names[0].name);
    try std.testing.expect(match.names[0].pointer);
    try std.testing.expect(match.branches[1].cases[0].pattern.kind == .null);
    try std.testing.expectEqual(.none, match.branches[1].naming);
    try std.testing.expect(match.branches[2].cases[0].pattern.kind == .negation);
    try std.testing.expect(!match.branches[2].cases[0].range);
    try std.testing.expect(match.branches[2].cases[1].range);
    try std.testing.expectEqualStrings("10", match.branches[2].cases[1].end.?.kind.integer_literal.text);
    try std.testing.expect(match.branches[3].cases[0].range);
    try std.testing.expect(match.branches[3].cases[0].end == null);
    try std.testing.expect(match.branches[4].cases[0].pattern.kind == .call);
    try std.testing.expectEqual(.value, match.branches[4].naming);
}

test "parseCaseNames: parses a case's names in braces with a pointer, a discarded name and own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match data\n        case Pair{ *left, _ }\n            noop\n        case (Bytes{ own bytes }) noop\n        case (Point{ x, y }) noop\n        else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const match = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(.payload, match.branches[0].naming);
    try std.testing.expectEqual(2, match.branches[0].name_count);
    try std.testing.expect(match.names[0].pointer);
    try std.testing.expectEqualStrings("_", match.names[1].name);
    try std.testing.expect(!match.branches[0].own);
    try std.testing.expect(match.branches[1].own);
    try std.testing.expectEqualStrings("bytes", match.names[2].name);
    try std.testing.expectEqualStrings("Point", match.branches[2].cases[0].pattern.kind.identifier.name);
    try std.testing.expectEqualStrings("y", match.names[4].name);
}

test "parseCaseNames: rejects own before some names and not others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match data\n        case (Pair{ own left, right }) noop\n        else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MixedOwnNames, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 31 }, parser.failure.?.location.?);
}

test "parseCaseNames: rejects a pointer name after own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match data\n        case (Bytes{ own *bytes }) noop\n        else noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 26 }, parser.failure.?.location.?);
}

test "parseValueName: rejects a discarded name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (Card as _) noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.DiscardedValueName, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 23 }, parser.failure.?.location.?);
}

test "parseLabel: rejects a label before a statement that is not a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "matchElse: leaves an else at the indentation of an enclosing statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while running\n        if (ready) step()\n    else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expectEqual(null, loop.body[0].kind.@"if".else_body);
    try std.testing.expectEqual(1, loop.else_body.?.len);
}

test "matchElse: leaves an else after a statement that does not start its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match token\n        case (End) if (ready) step()\n        else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const branches = module.declarations[0].kind.function_definition.body[0].kind.match.branches;
    try std.testing.expectEqual(2, branches.len);
    try std.testing.expectEqual(null, branches[0].body[0].kind.@"if".else_body);
    try std.testing.expectEqualStrings("stop", branches[1].body[0].kind.call.kind.call.callee.identifier.name);
}

test "parseElseBlock: rejects a colon after else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    if (ready) step()\n    else: stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, parser.failure.?.location.?);
}

test "isColonLabel: rejects a label written with a colon before a while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    outer: while (running) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "isColonLabel: rejects a label written with a colon before a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    outer: for (item in items) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseJump: parses break and continue with and without a label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer while running\n        break\n        break @outer\n        continue\n        continue @outer");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body[0].kind.@"while".body;
    try std.testing.expectEqual(4, body.len);
    try std.testing.expectEqual(null, body[0].kind.@"break".label);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, body[0].location);
    try std.testing.expectEqualStrings("outer", body[1].kind.@"break".label.?);
    try std.testing.expectEqual(null, body[2].kind.@"continue".label);
    try std.testing.expectEqualStrings("outer", body[3].kind.@"continue".label.?);
}

test "parseJump: rejects a label without the at sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer while (running) break outer");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 34 }, parser.failure.?.location.?);
}

test "parseJump: rejects an at sign without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    @outer while (running) continue @");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 38 }, parser.failure.?.location.?);
}

test "parseDefer: parses defer and errdefer before a call, an assignment and a discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    defer close()\n    errdefer count += 1\n    defer _ = value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expect(!body[0].kind.@"defer".on_error);
    try std.testing.expectEqualStrings("close", body[0].kind.@"defer".statement.kind.call.kind.call.callee.identifier.name);
    try std.testing.expect(body[1].kind.@"defer".on_error);
    try std.testing.expect(body[1].kind.@"defer".statement.kind.assignment.operator != null);
    try std.testing.expectEqualStrings("value", body[2].kind.@"defer".statement.kind.discard.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, body[1].location);
}

test "parseDefer: rejects a statement that is not a call, an assignment or a discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = defer return");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedDeferredStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseDiscard: parses a discarded call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, statement.location);
    const call = statement.kind.discard.kind.call;
    try std.testing.expectEqualStrings("add", call.callee.identifier.name);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseDiscard: parses a discarded name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: i32) = _ = value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("value", discarded.kind.identifier.name);
}

test "parseDiscard: parses a discarded method call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = card.count()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("count", discarded.kind.method_call.name);
}

test "parseDiscard: parses a discarded tried call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = try parse()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("parse", discarded.kind.@"try".kind.call.callee.identifier.name);
}

test "parseDiscard: rejects a missing equals sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ add(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
}

test "parseDiscard: parses a discarded operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = count + 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(ast.BinaryOperator.add, discarded.kind.binary.operator);
}

test "parseDiscard: parses a discarded field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = make().x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("x", discarded.kind.field_access.field);
}

test "parseDiscard: rejects a missing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseVariableDeclaration: parses a variable with a written type and undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var count: i32 = undefined\n    noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = var count: i32 =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, parser.failure.?.location.?);
}

test "parseVariableDeclaration: rejects names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = var (name, score) = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParenthesizedPattern, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseAssignment: parses an assignment to a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = point.x = 1");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = values[0] = 1");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = pointer.* = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const target = module.declarations[0].kind.function_definition.body[0].kind.assignment.target;
    try std.testing.expectEqualStrings("pointer", target.kind.dereference.kind.identifier.name);
}

test "parseAssignment: rejects a call as the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = make() = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseAssignment: rejects an unwrap as the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = maybe.? = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseAssignment: parses each compound assignment operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    a += 1\n    a -= 1\n    a *= 1\n    a /= 1\n    a %= 1\n    a &= 1\n    a |= 1\n    a ^= 1\n    a <<= 1\n    a >>= 1\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const operators = [_]ast.BinaryOperator{ .add, .subtract, .multiply, .divide, .remainder, .bitwise_and, .bitwise_or, .bitwise_exclusive_or, .shift_left, .shift_right };
    for (body, operators) |statement, operator| {
        try std.testing.expectEqual(operator, statement.kind.assignment.operator.?.operator);
    }
    try std.testing.expectEqual(token.Location{ .row = 10, .column = 7 }, body[8].kind.assignment.operator.?.location);
}

test "parseAssignment: rejects a call as the target of a compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = make() += 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseStatement: rejects a reserved word as the name of a local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const match = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 11 }, parser.failure.?.location.?);
}

test "parseCallStatement: parses a call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    log(1, true)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqualStrings("log", call.callee.identifier.name);
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("1", call.arguments[0].value.kind.integer_literal.text);
    try std.testing.expectEqual(true, call.arguments[1].value.kind.boolean_literal);
}

test "parseCallStatement: parses a tried call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = try save()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    try std.testing.expectEqualStrings("save", statement.kind.call.kind.@"try".kind.call.callee.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, statement.location);
}

test "parseCallStatement: rejects a name that is not called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    value\n    step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseCallStatement: rejects a field access as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    make().x\n    step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseCallStatement: rejects own before a method call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    own list.deinit()\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedOwn, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseTupleDeclaration: parses names in parentheses and a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const { name, *score } = pair\n    step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const declaration = statement.kind.tuple_declaration;
    try std.testing.expectEqual(2, declaration.names.len);
    try std.testing.expectEqualStrings("name", declaration.names[0].name);
    try std.testing.expect(declaration.names[1].pointer);
    try std.testing.expectEqualStrings("pair", declaration.value.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseTupleDeclaration: rejects a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = const { name, score }: [i32, bool] = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, parser.failure.?.location.?);
}

test "parseTupleDeclaration: rejects names in braces inside names in braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = const { name, { score, rank } } = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, parser.failure.?.location.?);
}

test "parseTupleDeclaration: parses variable names and own names in braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var { name, score } = pair\n    const own { path, record } = own entry\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const variable = body[0].kind.tuple_declaration;
    try std.testing.expect(variable.variable and !variable.own and !variable.moved);
    try std.testing.expectEqualStrings("score", variable.names[1].name);
    const owned = body[1].kind.tuple_declaration;
    try std.testing.expect(!owned.variable and owned.own and owned.moved);
    try std.testing.expectEqualStrings("record", owned.names[1].name);
}

test "parseTupleDeclaration: rejects names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = const own (path, record) = entry");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParenthesizedPattern, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "parseTupleDeclaration: rejects names in parentheses after const" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const (name, score) = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParenthesizedPattern, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 11 }, parser.failure.?.location.?);
}

test "parseConstantDeclaration: parses a path as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write = stdout::write");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.constant_declaration;
    try std.testing.expectEqualStrings("write", constant.name);
    try std.testing.expectEqual(2, constant.value.kind.path_expression.path.len);
    try std.testing.expectEqualStrings("stdout", constant.value.kind.path_expression.path[0]);
    try std.testing.expectEqualStrings("write", constant.value.kind.path_expression.path[1]);
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

test "parseConstantDeclaration: rejects names in parentheses at the top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const { name, score } = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 7 }, parser.failure.?.location.?);
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

test "parseConstantDeclaration: parses a struct without a name as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Data = struct\n    value: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("value", value.kind.struct_type.fields[0].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, value.location);
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
    var lexer = @import("lexer.zig").Lexer.init("const write =\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseStructDefinition: parses fields in an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x: i32\n    y: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.struct_definition;
    const fields = definition.fields;
    try std.testing.expectEqualStrings("Point", definition.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, module.declarations[0].location);
    try std.testing.expectEqual(2, fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqualStrings("i32", fields[0].type.kind.identifier.name);
    try std.testing.expectEqualStrings("y", fields[1].name);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, fields[1].location);
}

test "opensHeaderBlock: rejects a colon after the name of a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card:\n    value: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseStructDefinition: accepts a reserved word as the name of a struct and of an enum and an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct match\n    value: i32\nenum case\n    First\nerror for\n    Second");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("match", module.declarations[0].kind.struct_definition.name);
    try std.testing.expectEqualStrings("case", module.declarations[1].kind.enum_definition.name);
    try std.testing.expectEqualStrings("for", module.declarations[2].kind.enum_definition.name);
}

test "parseStructDefinition: rejects a reserved word as the name of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    match: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseEnumDefinition: rejects a reserved word as the name of a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Token\n    match");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCase, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "isTypeDeclaration: rejects a struct declared in an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("error Failure\n    Bad\n    struct Local\n        value: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedTypeDeclaration, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "isTypeDeclaration: rejects a struct declared in an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n\n    fn show(value: T)\ninstance Show(u8)\n    struct Local\n        value: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedTypeDeclaration, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, parser.failure.?.location.?);
}

test "isTypeDeclaration: rejects an enum declared in a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n    enum Kind\n        First");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedTypeDeclaration, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "isTypeDeclaration: rejects a struct declared in a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    struct Local\n        value: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedTypeDeclaration, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseNestedType: keeps the nested types of a struct without a name with that struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn List(type T) -> type\n    return struct\n        items: *[]T\n        struct Node\n            value: T\n        enum Kind\n            First");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const struct_type = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.struct_type;
    try std.testing.expectEqual(2, struct_type.types.len);
    try std.testing.expectEqual(null, struct_type.types[0].owner);
    try std.testing.expectEqualStrings("Kind", struct_type.types[1].kind.enum_definition.name);
}

test "parseNestedType: flattens nested types after their owner with the owner's position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Directory\n    struct Entry\n        name: u8\n\n        fn init() -> Self = Self{ name = 1 }\n    size: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(3, module.declarations.len);
    try std.testing.expectEqual(1, module.declarations[0].kind.struct_definition.fields.len);
    try std.testing.expectEqual(0, module.declarations[1].owner.?);
    try std.testing.expectEqualStrings("Entry", module.declarations[1].kind.struct_definition.name);
    try std.testing.expectEqual(1, module.declarations[2].owner.?);
    try std.testing.expectEqualStrings("init", module.declarations[2].kind.function_definition.signature.name);
}

test "parseNestedType: parses a private inline struct in the block of a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Directory\n    private inline struct Entry\n        name: const(*[]u8)\n    size: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    try std.testing.expect(!module.declarations[0].kind.struct_definition.@"inline");
    try std.testing.expect(module.declarations[1].kind.struct_definition.@"inline");
    try std.testing.expect(module.declarations[1].private);
}

test "parseStructDefinition: parses a struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Marker\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(0, module.declarations[0].kind.struct_definition.fields.len);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseStructDefinition: parses an external struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external struct Point\n    x: i32\nstruct Line\n    start: Point");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const point = module.declarations[0].kind.struct_definition;
    try std.testing.expect(point.external);
    try std.testing.expectEqualStrings("Point", point.name);
    try std.testing.expectEqual(1, point.fields.len);
    try std.testing.expect(!module.declarations[1].kind.struct_definition.external);
}

test "parseStructDefinition: parses an inline struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline struct Path\n    private bytes: const(*[]u8)\nstruct Line\n    start: Path\ninline fn read() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const path = module.declarations[0].kind.struct_definition;
    try std.testing.expect(path.@"inline");
    try std.testing.expect(!path.external);
    try std.testing.expectEqualStrings("bytes", path.fields[0].name);
    try std.testing.expect(!module.declarations[1].kind.struct_definition.@"inline");
    try std.testing.expect(module.declarations[2].kind.function_definition.signature.@"inline");
}

test "parseStructDefinition: rejects an inline external struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop\ninline external struct Point\n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineExternalStruct, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseStructDefinition: rejects an external inline struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop\nexternal inline struct Point\n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineExternalStruct, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 10 }, parser.failure.?.location.?);
}

test "parseStructDefinition: rejects a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct\n    x: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "expectInlineField: rejects an inline struct with two fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = noop\ninline struct Pair\n    first: i32\n    second: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineStructFieldCount, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "expectInlineField: rejects an inline struct with two fields that a function gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn Pair(type T) -> type\n    return inline struct\n        first: T\n        second: T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineStructFieldCount, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, parser.failure.?.location.?);
}

test "expectInlineField: rejects an inline struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Data\n    private inline struct Marker\n    value: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineStructFieldCount, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, parser.failure.?.location.?);
}

test "expectInlineField: rejects an own field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline struct Path\n    private own bytes: const(*[]u8)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineStructOwnField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, parser.failure.?.location.?);
}

test "parseEnumDefinition: parses cases with and without values and the functions of the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Token\n    Number: i64\n    Word: bool\n    End\n\n    fn is_end(self: Self) -> bool = return self == Token::End\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.enum_definition;
    try std.testing.expectEqual(3, definition.cases.len);
    try std.testing.expectEqualStrings("Number", definition.cases[0].name);
    try std.testing.expectEqualStrings("i64", definition.cases[0].type.?.kind.identifier.name);
    try std.testing.expectEqual(null, definition.cases[2].type);
    const function = module.declarations[1].kind.function_definition;
    try std.testing.expectEqualStrings("is_end", function.signature.name);
    try std.testing.expectEqual(ast.SelfParameter.value, function.signature.self_parameter);
}

test "parseEnumDefinition: marks a function and a nested type written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Mode\n    Read\n\n    private fn code(self: Self) -> u8 = 0\n    fn name(self: Self) -> u8 = 1\n    private struct Detail\n        value: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const declarations = module.declarations;
    try std.testing.expectEqualStrings("Detail", declarations[3].kind.struct_definition.name);
    try std.testing.expect(declarations[3].private);
    try std.testing.expect(declarations[1].kind.function_definition.signature.private);
    try std.testing.expect(!declarations[2].kind.function_definition.signature.private);
}

test "parseEnumDefinition: rejects private before a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Mode\n    private Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseEnumDefinition: parses an error set with and without cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("error ParseError\n    MissingEnd\n    Unexpected: [usize, usize]\nerror Never");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const set = module.declarations[0].kind.enum_definition;
    try std.testing.expectEqual(types.EnumKind.error_set, set.kind);
    try std.testing.expectEqualStrings("Unexpected", set.cases[1].name);
    try std.testing.expect(set.cases[1].type != null);
    const never = module.declarations[1].kind.enum_definition;
    try std.testing.expectEqual(types.EnumKind.error_set, never.kind);
    try std.testing.expectEqual(0, never.cases.len);
}

test "parseEnumDefinition: rejects a function in an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("error ParseError\n    MissingEnd\n    fn show() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedErrorCase, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "parseBinary: combines error sets at the level of bitwise or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Any = ParseError || FileError | Other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value.kind.binary;
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.operator);
    try std.testing.expectEqual(ast.BinaryOperator.combine, value.left.kind.binary.operator);
}

test "parseMembers: rejects a field on the line of the colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Meters: value: f64");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.HeaderColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseMembers: rejects a line that is not a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseMembers: lists a method of a struct as a declaration on the struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card\n    question: const(*[]u8)\n\n    fn show(self: Self) -> const(*[]u8) = return self.question");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations[0].kind.struct_definition.fields.len);
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

test "parseMembers: marks a function and a nested type written after private and keeps the fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Box\n    private value: u8\n    count: u8\n\n    private fn get(self: Self) -> u8 = self.value\n    fn put() = noop\n    private struct Inner\n        width: u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const declarations = module.declarations;
    const fields = declarations[0].kind.struct_definition.fields;
    try std.testing.expect(fields[0].private);
    try std.testing.expect(!fields[1].private);
    try std.testing.expectEqualStrings("Inner", declarations[3].kind.struct_definition.name);
    try std.testing.expect(declarations[3].private);
    try std.testing.expect(declarations[1].kind.function_definition.signature.private);
    try std.testing.expect(!declarations[2].kind.function_definition.signature.private);
}

test "parseMembers: marks a function written after private in a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn Box(type T) -> type\n    return struct\n        private value: T\n\n        private fn get(self: Self) -> T = self.value\n        fn put() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const struct_type = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.struct_type;
    try std.testing.expect(struct_type.fields[0].private);
    try std.testing.expect(struct_type.functions[0].kind.function_definition.signature.private);
    try std.testing.expect(!struct_type.functions[1].kind.function_definition.signature.private);
}

test "parseMembers: parses a field after a method with an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card\n\n    fn show(self: Self) -> const(*[]u8)\n        return self.question\n    question: const(*[]u8)\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.declarations[0].kind.struct_definition.fields.len);
    try std.testing.expectEqual(1, module.declarations[1].kind.function_definition.body.len);
    try std.testing.expectEqualStrings("main", module.declarations[2].kind.function_definition.signature.name);
}

test "parseField: parses a default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x: i32 = 0\n    y: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const fields = module.declarations[0].kind.struct_definition.fields;
    try std.testing.expectEqualStrings("0", fields[0].default.?.kind.integer_literal.text);
    try std.testing.expectEqual(null, fields[1].default);
}

test "parseField: marks a field written after private, before own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct List\n    private own storage: *[]u8\n    length: usize");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const fields = module.declarations[0].kind.struct_definition.fields;
    try std.testing.expect(fields[0].private);
    try std.testing.expect(fields[0].own);
    try std.testing.expect(!fields[1].private);
}

test "parseField: rejects private after own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct List\n    own private storage: *[]u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 9 }, parser.failure.?.location.?);
}

test "parseField: rejects an equals sign without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x: i32 =\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left i32) -> i32 = return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a name without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x:\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypedName: rejects a missing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: ) -> i32 = return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseTypeclassDefinition: parses the functions of a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T)\n\n    fn area(self: T) -> i32\n    fn grow(self: T, amount: i32) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.typeclass_definition;
    try std.testing.expectEqualStrings("Shape", definition.name);
    try std.testing.expectEqual(2, definition.functions.len);
    try std.testing.expectEqualStrings("self", definition.functions[1].parameters[0].name);
    try std.testing.expectEqualStrings("amount", definition.functions[1].parameters[1].name);
    try std.testing.expectEqual(null, definition.functions[0].receiver);
}

test "parseTypeclassFunctions: marks a function written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T)\n    private fn area(value: T) -> u8\n    fn name(value: T) -> u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const functions = module.declarations[0].kind.typeclass_definition.functions;
    try std.testing.expect(functions[0].private);
    try std.testing.expect(!functions[1].private);
}

test "parseTypeclassDefinition: parses the parameter of a typeclass and the receivers of its methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T)\n\n    fn area(shape: T) -> i32\n    fn grow(shape: *T)\n    fn read(shape: const(*T)) -> i32\n    fn make(side: i32) -> T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.typeclass_definition;
    try std.testing.expectEqualStrings("T", definition.parameters[0].name);
    try std.testing.expectEqual(ast.SelfParameter.value, definition.functions[0].self_parameter);
    try std.testing.expectEqual(ast.SelfParameter.pointer, definition.functions[1].self_parameter);
    try std.testing.expectEqual(ast.SelfParameter.constant_pointer, definition.functions[2].self_parameter);
    try std.testing.expectEqual(ast.SelfParameter.none, definition.functions[3].self_parameter);
}

test "parseTypeclassDefinition: makes methods only of functions whose first parameter is the first parameter of the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Decode(type T, type D)\n\n    fn decode(decoder: *D) -> T\n    fn check(value: const(*T), decoder: *D) -> bool");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.typeclass_definition;
    try std.testing.expectEqual(ast.SelfParameter.none, definition.functions[0].self_parameter);
    try std.testing.expectEqual(ast.SelfParameter.constant_pointer, definition.functions[1].self_parameter);
}

test "parseTypeclassDefinition: rejects a typeclass without parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape\n\n    fn area(shape: Shape) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseTypeclassDefinition: rejects a parameter that is not a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(T)\n\n    fn area(shape: T) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTypeParameter, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseTypeclassDefinition: parses several parameters and type constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Map(type K, type F(type, type), type V)\n\n    fn get(map: K) -> V");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.typeclass_definition.parameters;
    try std.testing.expectEqual(3, parameters.len);
    try std.testing.expectEqualStrings("F", parameters[1].name);
    try std.testing.expectEqual(2, parameters[1].arity);
    try std.testing.expectEqual(0, parameters[2].arity);
}

test "parseTypeclassDefinition: parses the requirement of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Ord(type T: Eq)\n\n    fn less(one: T, two: T) -> bool");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.typeclass_definition.parameters[0];
    try std.testing.expectEqualStrings("Eq", parameter.requirements[0].kind.identifier.name);
}

test "parseTypeclassDefinition: parses a function that is not a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T)\n\n    fn init() -> T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[0].kind.typeclass_definition.functions[0];
    try std.testing.expectEqual(0, function.parameters.len);
    try std.testing.expectEqual(ast.SelfParameter.none, function.self_parameter);
    try std.testing.expectEqualStrings("T", function.return_type.kind.identifier.name);
}

test "parseTypeclassDefinition: parses a function with a body as a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T)\n\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32\n        return self.area() * 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.typeclass_definition;
    try std.testing.expectEqual(2, definition.functions.len);
    try std.testing.expectEqual(null, definition.defaults[0]);
    const default = definition.defaults[1].?;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, default.body[0].kind.@"return".?.kind.binary.operator);
    try std.testing.expect(default.template.body.ptr != default.body.ptr);
    try std.testing.expectEqualStrings("double", default.template.signature.name);
}

test "parseTypeclassDefinition: parses an inline default implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n\n    fn show(value: T) -> i32\n    inline fn twice(value: T) -> i32 = return 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.typeclass_definition;
    try std.testing.expect(!definition.functions[0].@"inline");
    try std.testing.expect(definition.functions[1].@"inline");
    try std.testing.expect(definition.defaults[1].?.template.signature.@"inline");
}

test "parseTypeclassDefinition: rejects an inline function without a body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n\n    inline fn show(value: T) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineSignature, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "parseInstance: lists the functions of an instance as declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance Shape(const(*[]u8))\n\n    fn area(self: const(*[]u8)) -> i32 = return 0");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const instance_declaration = module.declarations[0].kind.instance_declaration;
    try std.testing.expectEqualStrings("Shape", instance_declaration.typeclass.kind.identifier.name);
    try std.testing.expect(instance_declaration.arguments[0].kind.slice_type.constant);
    try std.testing.expectEqual(1, instance_declaration.functions);
    const signature = module.declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Shape", signature.typeclass.?.kind.identifier.name);
    try std.testing.expectEqual(null, signature.receiver);
}

test "parseInstance: parses an inline function in an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T)\n\n    fn show(value: T) -> i32\ninstance Show(i32)\n\n    inline fn show(value: i32) -> i32 = return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[2].kind.function_definition.signature.@"inline");
}

test "parseInstance: rejects private before a function of an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance Show(u8)\n\n    private fn show(value: u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, parser.failure.?.location.?);
}

test "parseInstance: parses the typeclass and the type in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance shapes::Shape(const(*[]u8))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const instance_declaration = module.declarations[0].kind.instance_declaration;
    try std.testing.expectEqualStrings("Shape", instance_declaration.typeclass.kind.path_expression.path[1]);
    try std.testing.expect(instance_declaration.arguments[0].kind == .slice_type);
    try std.testing.expectEqual(0, instance_declaration.functions);
}

test "parseInstance: parses the parameters of a generic instance and several arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance(type A: Show, type B) Pair(ArrayList(A), B)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const instance_declaration = module.declarations[0].kind.instance_declaration;
    try std.testing.expectEqual(2, instance_declaration.parameters.len);
    try std.testing.expectEqualStrings("Show", instance_declaration.parameters[0].requirements[0].kind.identifier.name);
    try std.testing.expectEqual(0, instance_declaration.parameters[1].requirements.len);
    try std.testing.expectEqual(2, instance_declaration.arguments.len);
    try std.testing.expect(instance_declaration.arguments[0].kind == .call);
}

test "parseInstance: rejects a type without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance Shape Square");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseImport: binds the last name of the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import shapes::Shape");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const import = module.declarations[0].kind.import;
    try std.testing.expectEqual(2, import.path.len);
    try std.testing.expectEqualStrings("shapes", import.path[0]);
    try std.testing.expectEqualStrings("Shape", import.path[1]);
    try std.testing.expectEqualStrings("Shape", import.name);
}

test "parseImport: marks the name written after private and binds it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::filesystem::private::build_path");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const import = module.declarations[0].kind.import;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "filesystem", "build_path" }), import.path);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, import.crossings);
    try std.testing.expectEqualStrings("build_path", import.name);
}

test "parseImport: binds the name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::process::stdout as out\nimport mn as library");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const import = module.declarations[0].kind.import;
    try std.testing.expectEqual(3, import.path.len);
    try std.testing.expectEqualStrings("stdout", import.path[2]);
    try std.testing.expectEqualStrings("out", import.name);
    try std.testing.expectEqual(1, module.declarations[1].kind.import.path.len);
    try std.testing.expectEqualStrings("library", module.declarations[1].kind.import.name);
}

test "parseImport: rejects a missing path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import as out");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, parser.failure.?.location.?);
}

test "parseImport: rejects a missing name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::process::stdout as\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseImport: rejects a reserved word as the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::process::stdout as as");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, parser.failure.?.location.?);
}

test "parseImport: makes one import of each item of a group at the item's name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::text::{ self, Parser as TextParser }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "text" }), module.declarations[0].kind.import.path);
    try std.testing.expectEqualStrings("text", module.declarations[0].kind.import.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, module.declarations[0].location);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "text", "Parser" }), module.declarations[1].kind.import.path);
    try std.testing.expectEqualStrings("TextParser", module.declarations[1].kind.import.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, module.declarations[1].location);
}

test "parseImport: binds the name after as on self in a group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::text::{ self as words, Parser }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "text" }), module.declarations[0].kind.import.path);
    try std.testing.expectEqualStrings("words", module.declarations[0].kind.import.name);
    try std.testing.expectEqualStrings("Parser", module.declarations[1].kind.import.name);
}

test "parseImport: reads a group over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::codec::{\n    Decode,\n    Decoder\n}\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("Decode", module.declarations[0].kind.import.name);
    try std.testing.expectEqualStrings("Decoder", module.declarations[1].kind.import.name);
    try std.testing.expectEqualStrings("main", module.declarations[2].kind.function_definition.signature.name);
}

test "parseImport: rejects a group nested in a group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::{ codec::{ Decode } }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBrace, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseImport: rejects self in a group after private as private without a name after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::filesystem::private::{ self }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 35 }, parser.failure.?.location.?);
}

test "parseImport: rejects a path as an item of a group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::{ codec::Decode }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBrace, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "expectBlock: rejects empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one()\nfn two() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "expectBlock: rejects a nested block that is not indented more than its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    match value\n    case (First) step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBlock, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "matchBlockLine: rejects line deeper than the first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n  noop\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "matchBlockLine: rejects a dedent that matches no outer level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    noop\n  noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InconsistentIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "matchBlockLine: rejects a dedent between two nested levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while running\n        step()\n      stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InconsistentIndentation, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 1 }, parser.failure.?.location.?);
}

test "parseExpression: ends a range after the operations on its bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    for (index in 0..count + 1) step(index)\n    const range = (0..3)\n    take(range)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expect(body[0].kind.@"for".sequence.range.end.?.kind == .binary);
    try std.testing.expect(body[1].kind.constant_declaration.value.kind == .range);
}

test "parseBinary: rejects a range as the left operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const value = (0..3) + 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, parser.failure.?.location.?);
}

test "parseBinary: rejects a range as the right operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const value = 1 + (0..3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 23 }, parser.failure.?.location.?);
}

test "parsePrefix: rejects a range as the operand of a unary operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const value = !(0..3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, parser.failure.?.location.?);
}

test "parsePostfix: rejects a field of a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const value = (0..3).start");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, parser.failure.?.location.?);
}

test "parseExpression: records that the module has a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const span = 0..4\n    for index in 0..2\n        _ = index\n    _ = span");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expect((try parser.parse(&arena)).has_range);
}

test "parseExpression: records no range for a loop over a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(items: *[]u8)\n    for index in 0..2\n        _ = items[index..]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expect(!(try parser.parse(&arena)).has_range);
}

test "parseExpression: parses each literal kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() -> u8 = return 0xff_u8\nfn two() -> f64 = return 2.5\nfn three() -> bool = return true\nfn four() -> bool = return false");
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
    var lexer = @import("lexer.zig").Lexer.init("fn greeting() -> const(*[]u8) = return \"hello\"");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("hello", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.string_literal);
}

test "parseExpression: parses null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn nothing() -> ?i32 = return null");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expect(value.kind == .null);
}

test "parseExpression: parses a parameter reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn same(value: i32) -> i32 = return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("value", module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.identifier.name);
}

test "parseExpression: binds and tighter than or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return a or b and c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    while (a < b) log(a + b, { a * b })");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"while";
    try std.testing.expectEqual(ast.BinaryOperator.less_than, loop.condition.kind.binary.operator);
    const arguments = loop.body[0].kind.call.kind.call.arguments;
    try std.testing.expectEqual(ast.BinaryOperator.add, arguments[0].value.kind.binary.operator);
    const element = arguments[1].value.kind.composite_literal.elements[0].value;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, element.kind.binary.operator);
}

test "parseExpression: parses a range outside a for as a whole expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const range = 1 + 2..count\n    const open = start..\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const range = body[0].kind.constant_declaration.value.kind.range;
    try std.testing.expectEqual(ast.BinaryOperator.add, range.start.kind.binary.operator);
    try std.testing.expectEqualStrings("count", range.end.?.kind.identifier.name);
    try std.testing.expectEqual(null, body[1].kind.constant_declaration.value.kind.range.end);
}

test "parseAnd: binds a prefix operator tighter than and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return !a and b");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"and", value.kind.binary.operator);
    try std.testing.expectEqual(ast.UnaryOperator.not, value.kind.binary.left.kind.unary.operator);
    try std.testing.expectEqualStrings("b", value.kind.binary.right.kind.identifier.name);
}

test "parseWithValue: gives a call and a method call the operand of with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() = g(1) with &a\nfn h() = c.d() with b");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const first = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqualStrings("a", first.with_value.?.kind.address_of.kind.identifier.name);
    const second = module.declarations[1].kind.function_definition.body[0].kind.call.kind.method_call;
    try std.testing.expectEqualStrings("b", second.with_value.?.kind.identifier.name);
}

test "parseWithStatement: binds the allocator to a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f()\n    with allocator\n    _ = allocator");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expect(constant.with);
    try std.testing.expectEqualStrings("allocator", constant.name);
}

test "parseWithStatement: sets the context from an expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f()\n    with &heap\n    g()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expect(constant.context);
    try std.testing.expect(!constant.with);
    try std.testing.expectEqualStrings("heap", constant.value.kind.address_of.kind.identifier.name);
}

test "parseWithStatement: sets the context from a name other than allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f(arena: *Arena)\n    with arena\n    g()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const constant = module.declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expect(constant.context);
    try std.testing.expect(!constant.with);
    try std.testing.expectEqualStrings("arena", constant.value.kind.identifier.name);
}

test "parseFunctionSignature: reads own on a return type, a parameter, a field, a declaration and an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Holder\n    own path: Path\n    size: usize\nfn make(own path: Path, size: usize) -> own Error!Holder\n    const own kept = path\n    var own other = path\n    const plain = size\n    return { path = own kept, size = plain }\nfn infer() -> own !Holder = make(own other, 1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const fields = module.declarations[0].kind.struct_definition.fields;
    try std.testing.expect(fields[0].own);
    try std.testing.expect(!fields[1].own);
    const function = module.declarations[1].kind.function_definition;
    try std.testing.expect(function.signature.return_own);
    try std.testing.expect(function.signature.parameters[0].own);
    try std.testing.expect(!function.signature.parameters[1].own);
    try std.testing.expect(function.body[0].kind.constant_declaration.own);
    try std.testing.expect(function.body[1].kind.variable_declaration.own);
    try std.testing.expect(!function.body[2].kind.constant_declaration.own);
    const elements = function.body[3].kind.@"return".?.kind.composite_literal.elements;
    try std.testing.expect(elements[0].own);
    try std.testing.expect(!elements[1].own);
    const inferred = module.declarations[2].kind.function_definition;
    try std.testing.expect(inferred.signature.return_own);
    try std.testing.expect(inferred.signature.inferred_error_set != null);
    try std.testing.expect(inferred.body[0].kind.call.kind.call.arguments[0].own);
}

test "parseConstantDeclaration: reads own before the value of a declaration and an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f()\n    const own one = own two\n    var own three = own one\n    three = own four\n    const plain = five");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expect(body[0].kind.constant_declaration.moved);
    try std.testing.expect(body[1].kind.variable_declaration.moved);
    try std.testing.expect(body[2].kind.assignment.moved);
    try std.testing.expect(!body[3].kind.constant_declaration.moved);
}

test "parseComparison: binds bitwise operators tighter than a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return a | b == c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.equal, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, value.kind.binary.operator_location);
}

test "parseComparison: binds orelse tighter than a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return a orelse b == c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return a < b < c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ChainedComparison, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, parser.failure.?.location.?);
}

test "parseComparison: rejects a chained equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return a == b != c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ChainedComparison, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, parser.failure.?.location.?);
}

test "parseComparison: parses a comparison in parentheses as an operand of a comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return (a < b) == c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.equal, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.less_than, value.kind.binary.left.kind.binary.operator);
}

test "parseOrElse: takes a return as the fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a orelse return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    const fallback = value.kind.binary.right.kind.jump;
    try std.testing.expectEqualStrings("1", fallback.kind.@"return".?.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, fallback.location);
}

test "parseOrElse: binds bitwise or tighter than orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a | b orelse c | d");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, value.kind.binary.right.kind.binary.operator);
}

test "parseOrElse: parses catch at the level of orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a | b catch c orelse d");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    const caught = value.kind.binary.left.kind.binary;
    try std.testing.expectEqual(ast.BinaryOperator.@"catch", caught.operator);
    try std.testing.expectEqual(ast.BinaryOperator.bitwise_or, caught.left.kind.binary.operator);
}

test "parseOrElse: groups a chain of orelse from the left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a orelse b orelse c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
}

test "parseResultType: binds || tighter than ! and ! tighter than catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Any = ParseError || FileError!Token catch Other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqual(ast.BinaryOperator.@"catch", value.kind.binary.operator);
    const result = value.kind.binary.left.kind.binary;
    try std.testing.expectEqual(ast.BinaryOperator.result, result.operator);
    try std.testing.expectEqual(ast.BinaryOperator.combine, result.left.kind.binary.operator);
    try std.testing.expectEqualStrings("Token", result.right.kind.identifier.name);
}

test "parseBitwiseOr: binds exclusive or tighter than or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a | b ^ c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a ^ b & c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a & b << c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a + b >> c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a + b * c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.operator);
    try std.testing.expectEqualStrings("a", value.kind.binary.left.kind.identifier.name);
    try std.testing.expectEqual(ast.BinaryOperator.multiply, value.kind.binary.right.kind.binary.operator);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, value.kind.binary.operator_location);
}

test "parseAdditive: groups operators of one level from the left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a - b - c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -a * b % c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a +\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parsePrefix: parses a minus before a name as a negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -limit");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.UnaryOperator.negate, value.kind.unary.operator);
    try std.testing.expectEqualStrings("limit", value.kind.unary.operand.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
}

test "parsePrefix: keeps a minus before a number as part of the literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a - -5");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return ~-a");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -point.x");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> *i32 = return &value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("value", value.kind.address_of.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, value.location);
}

test "parsePrefix: takes the address of an element instead of indexing an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> *i32 = return &values[1]");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -values[1]");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return mask & &value");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -5.abs()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> bool = return !");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
}

test "parseTry: binds try to its operand before a binary operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return try first() + try second()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.operator);
    try std.testing.expectEqualStrings("first", value.kind.binary.left.kind.@"try".kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("second", value.kind.binary.right.kind.@"try".kind.call.callee.identifier.name);
}

test "parseJumpExpression: gives a return the rest of the expression as its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return a orelse return b orelse c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const returned = value.kind.binary.right.kind.jump.kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", returned.kind.binary.operator);
    try std.testing.expectEqualStrings("b", returned.kind.binary.left.kind.identifier.name);
}

test "parseJumpExpression: parses a return without a value before a closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() = g(a orelse return)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    const fallback = call.arguments[0].value.kind.binary.right.kind.jump;
    try std.testing.expectEqual(null, fallback.kind.@"return");
}

test "parseJumpExpression: parses break and continue with a label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f()\n    const a = b orelse break @outer\n    const c = d orelse continue");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const broken = body[0].kind.constant_declaration.value.kind.binary.right.kind.jump;
    try std.testing.expectEqualStrings("outer", broken.kind.@"break".label.?);
    const continued = body[1].kind.constant_declaration.value.kind.binary.right.kind.jump;
    try std.testing.expectEqual(null, continued.kind.@"continue".label);
}

test "parseJumpExpression: rejects a label without the at sign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() = const a = b orelse break outer");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 35 }, parser.failure.?.location.?);
}

test "parsePostfix: parses a chain of field accesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(line.start.x)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, outer.location);
    try std.testing.expectEqualStrings("x", outer.kind.field_access.field);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, outer.kind.field_access.field_location);
    const inner = outer.kind.field_access.value.kind.field_access;
    try std.testing.expectEqualStrings("start", inner.field);
    try std.testing.expectEqualStrings("line", inner.value.kind.identifier.name);
}

test "parsePostfix: parses a field access on a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(make().x)");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return grid[1][2]");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return points[1].x");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return pointer.*.x");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return -value.?.count");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const access = value.kind.unary.operand.kind.field_access;
    try std.testing.expectEqualStrings("count", access.field);
    try std.testing.expectEqualStrings("value", access.value.kind.unwrap.kind.identifier.name);
}

test "parsePostfix: rejects a receiver in parentheses after own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    defer (own list).deinit()\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ParenthesizedOwnReceiver, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 11 }, parser.failure.?.location.?);
}

test "parseStructType: parses the fields and functions of a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn List(type T) -> type\n    return struct\n        first: T\n\n        fn get(self: Self) -> T = return self.first\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const struct_type = body[0].kind.@"return".?.kind.struct_type;
    try std.testing.expectEqual(1, struct_type.fields.len);
    try std.testing.expectEqualStrings("first", struct_type.fields[0].name);
    const function = struct_type.functions[0].kind.function_definition;
    try std.testing.expectEqualStrings("get", function.signature.name);
    try std.testing.expectEqualStrings("Self", function.signature.receiver.?.kind.identifier.name);
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqual(1, module.declarations.len);
}

test "parseStructType: gives the block of a return line to a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn List(type T) -> type\n    return struct\n        items: *[]T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const struct_type = body[0].kind.@"return".?.kind.struct_type;
    try std.testing.expectEqualStrings("items", struct_type.fields[0].name);
}

test "parseStructType: parses an inline struct that a function gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn Wrapped(type T) -> type\n    return inline struct\n        value: T\nfn Plain(type T) -> type\n    return struct\n        value: T");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const wrapped = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.struct_type;
    try std.testing.expect(wrapped.@"inline");
    try std.testing.expectEqualStrings("value", wrapped.fields[0].name);
    try std.testing.expect(!module.declarations[1].kind.function_definition.body[0].kind.@"return".?.kind.struct_type.@"inline");
}

test "parseCompositeLiteral: parses an array literal over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values: [2]i32 = {\n    1,\n    2,\n}\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(null, literal.type);
    try std.testing.expectEqual(2, literal.elements.len);
    try std.testing.expectEqualStrings("2", literal.elements[1].value.kind.integer_literal.text);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseCompositeLiteral: parses the array type written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const values = [3]i32{ 1, 2, 3 }");
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
    var lexer = @import("lexer.zig").Lexer.init("const pair = [i32, bool]{ 1, true }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(2, literal.type.?.kind.tuple_type.elements.len);
    try std.testing.expectEqual(true, literal.elements[1].value.kind.boolean_literal);
}

test "parseCompositeLiteral: parses a one-element tuple type written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const single = [i32]{ 1 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqualStrings("i32", literal.type.?.kind.tuple_type.elements[0].kind.identifier.name);
    try std.testing.expectEqualStrings("1", literal.elements[0].value.kind.integer_literal.text);
}

test "parseCompositeLiteral: parses the empty tuple type written before empty braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const empty = []{}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(0, literal.type.?.kind.tuple_type.elements.len);
    try std.testing.expectEqual(0, literal.elements.len);
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take([2]i32{ 1, 2 }[..])");
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
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Values = return Values{ 1, 2 }");
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
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> pairs::Pair = return pairs::Pair{ 1, true }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.kind.composite_literal.type.?.kind.path_expression.path.len);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 35 }, value.location);
}

test "parseCompositeLiteral: parses named values after a struct type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data = return Data{ two = 2, one = 1 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const literal = value.kind.composite_literal;
    try std.testing.expectEqualStrings("Data", literal.type.?.kind.identifier.name);
    try std.testing.expectEqualStrings("two", literal.elements[0].name.?);
    try std.testing.expectEqualStrings("2", literal.elements[0].value.kind.integer_literal.text);
    try std.testing.expectEqualStrings("one", literal.elements[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 43 }, literal.elements[1].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, value.location);
}

test "parseCompositeLiteral: parses named values without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data = return { one = 1, two = 2 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const literal = value.kind.composite_literal;
    try std.testing.expectEqual(null, literal.type);
    try std.testing.expectEqualStrings("one", literal.elements[0].name.?);
    try std.testing.expectEqualStrings("two", literal.elements[1].name.?);
    try std.testing.expectEqualStrings("2", literal.elements[1].value.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, value.location);
}

test "parseCompositeLiteral: parses named values over several lines with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const data: Data = Data{\n    one = 0,\n    two = 0,\n}\nfn main() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(2, literal.elements.len);
    try std.testing.expectEqualStrings("two", literal.elements[1].name.?);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseCompositeLiteral: parses a name without a value after a named value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data = return Data{ one = 1, two }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.composite_literal;
    try std.testing.expectEqualStrings("one", literal.elements[0].name.?);
    try std.testing.expectEqual(null, literal.elements[1].name);
    try std.testing.expectEqualStrings("two", literal.elements[1].value.kind.identifier.name);
}

test "parseCompositeLiteral: parses an own name without a value before a named value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data = return { own one, two = 2 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.composite_literal;
    try std.testing.expectEqual(null, literal.elements[0].name);
    try std.testing.expect(literal.elements[0].own);
    try std.testing.expectEqualStrings("one", literal.elements[0].value.kind.identifier.name);
    try std.testing.expectEqualStrings("two", literal.elements[1].name.?);
}

test "parseElement: marks a named field and a field without a value written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Path = return { private.bytes = text, private.count, size = 1 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.composite_literal;
    try std.testing.expectEqualStrings("bytes", literal.elements[0].name.?);
    try std.testing.expect(literal.elements[0].crossing);
    try std.testing.expectEqualStrings("text", literal.elements[0].value.kind.identifier.name);
    try std.testing.expectEqual(null, literal.elements[1].name);
    try std.testing.expect(literal.elements[1].crossing);
    try std.testing.expectEqualStrings("count", literal.elements[1].value.kind.identifier.name);
    try std.testing.expect(!literal.elements[2].crossing);
}

test "parseElement: rejects private without a field after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Path = return { private.(1) }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, parser.failure.?.location.?);
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

test "parseBrackets: reads brackets with two types as a tuple type when a type follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool] value: i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, parser.failure.?.location.?);
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

test "parseBrackets: parses an array of pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [2]*i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const array_type = parameter.type.kind.array_type;
    try std.testing.expectEqualStrings("i32", array_type.element.kind.pointer_type.target.kind.identifier.name);
}

test "parseBrackets: parses a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool]) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const tuple_type = parameter.type.kind.tuple_type;
    try std.testing.expectEqual(2, tuple_type.elements.len);
    try std.testing.expectEqualStrings("bool", tuple_type.elements[1].kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parameter.type.location);
}

test "parseBrackets: parses a tuple type with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool,]) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(2, parameter.type.kind.tuple_type.elements.len);
}

test "parseBrackets: parses one type in brackets as a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: [i32]) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const tuple_type = parameter.type.kind.tuple_type;
    try std.testing.expectEqual(1, tuple_type.elements.len);
    try std.testing.expectEqualStrings("i32", tuple_type.elements[0].kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parseBrackets: parses empty brackets as the empty tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: []) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(0, parameter.type.kind.tuple_type.elements.len);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parseBrackets: parses a name in brackets followed by a type as an array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [count]i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const array_type = parameter.type.kind.array_type;
    try std.testing.expectEqualStrings("count", array_type.length.?.kind.identifier.name);
    try std.testing.expectEqualStrings("i32", array_type.element.kind.identifier.name);
}

test "parseBrackets: reads brackets with a trailing comma as a tuple type when a type follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [4,]i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects const after empty brackets and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []const u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects many after empty brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []many(u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects a slice without a pointer and names the pointer form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var bytes: []u8 = undefined\n    bytes = undefined");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedSlice, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("[]T is allowed only directly after *, since a slice is a pointer: write *[]T or const(*[]T), e.g. *[]u8 instead of []u8", parser.failure.?.message);
}

test "parseBrackets: rejects a slice in a type argument without a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(lists: List([]u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedSlice, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects the old read-only slice and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []const(u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedSlice, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects many brackets without an asterisk and names the form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: [many]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("many is written only in brackets directly after *, e.g. *[many]T or const(*[many]T)", parser.failure.?.message);
}

test "parseBrackets: rejects many brackets as the element of an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(rows: *[4][many]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseSliceType: parses a slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *[]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const slice_type = parameter.type.kind.slice_type;
    try std.testing.expect(!slice_type.constant);
    try std.testing.expectEqualStrings("u8", slice_type.element.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parseSliceType: parses a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: const(*[]u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    const slice_type = parameter.type.kind.slice_type;
    try std.testing.expect(slice_type.constant);
    try std.testing.expectEqualStrings("u8", slice_type.element.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parameter.type.location);
}

test "parseSliceType: parses a constant slice type whose const spans several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: const(*[]\n    u8\n)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice_type = module.declarations[0].kind.function_definition.signature.parameters[0].type.kind.slice_type;
    try std.testing.expect(slice_type.constant);
    try std.testing.expectEqualStrings("u8", slice_type.element.kind.identifier.name);
}

test "parseSliceType: rejects a slice of a slice without a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(lines: *[][]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedSlice, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects const after an asterisk and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(card: *const Card) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects many after an asterisk and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *many u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ManyPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects many const after an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *many const u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ManyPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects the old many pointer and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *many(u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ManyPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("write *[many]T instead of *many(T), with many in brackets", parser.failure.?.message);
}

test "parsePointerType: rejects the old read-only pointer and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(card: *const(Card)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstInsidePointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("write const(*T) instead of *const(T), with const around the whole pointer", parser.failure.?.message);
}

test "parsePointerType: parses many and const after an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: const(*[many]u8), b: const(*Card), c: *[many]i32, d: ?*[many]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const many_constant = parameters[0].type.kind.pointer_type;
    try std.testing.expect(many_constant.many and many_constant.constant);
    try std.testing.expectEqualStrings("u8", many_constant.target.kind.identifier.name);
    const constant_pointer = parameters[1].type.kind.pointer_type;
    try std.testing.expect(!constant_pointer.many and constant_pointer.constant);
    try std.testing.expectEqualStrings("Card", constant_pointer.target.kind.identifier.name);
    const many = parameters[2].type.kind.pointer_type;
    try std.testing.expect(many.many and !many.constant);
    try std.testing.expect(parameters[3].type.kind.optional_type.child.kind.pointer_type.many);
}

test "parsePointerType: parses many and const over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Bytes = const(\n    *[many]\n        u8\n)\nconst Other = u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    const pointer_type = module.declarations[0].kind.constant_declaration.value.kind.pointer_type;
    try std.testing.expect(pointer_type.many and pointer_type.constant);
    try std.testing.expectEqualStrings("u8", pointer_type.target.kind.identifier.name);
}

test "parsePointerType: parses each pointer form writable and read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: *u8, b: const(*u8), c: *[4]u8, d: const(*[4]u8), e: *[]u8, f: const(*[]u8), g: *[many]u8, h: const(*[many]u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const one = parameters[0].type.kind.pointer_type;
    try std.testing.expect(!one.many and !one.constant);
    try std.testing.expectEqualStrings("u8", one.target.kind.identifier.name);
    const read_only_one = parameters[1].type.kind.pointer_type;
    try std.testing.expect(!read_only_one.many and read_only_one.constant);
    try std.testing.expectEqualStrings("u8", read_only_one.target.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parameters[1].type.location);
    const array = parameters[2].type.kind.pointer_type;
    try std.testing.expect(!array.many and !array.constant);
    try std.testing.expectEqualStrings("u8", array.target.kind.array_type.element.kind.identifier.name);
    const read_only_array = parameters[3].type.kind.pointer_type;
    try std.testing.expect(!read_only_array.many and read_only_array.constant);
    try std.testing.expectEqualStrings("u8", read_only_array.target.kind.array_type.element.kind.identifier.name);
    try std.testing.expect(!parameters[4].type.kind.slice_type.constant);
    try std.testing.expect(parameters[5].type.kind.slice_type.constant);
    const many = parameters[6].type.kind.pointer_type;
    try std.testing.expect(many.many and !many.constant);
    try std.testing.expectEqualStrings("u8", many.target.kind.identifier.name);
    const read_only_many = parameters[7].type.kind.pointer_type;
    try std.testing.expect(read_only_many.many and read_only_many.constant);
    try std.testing.expectEqualStrings("u8", read_only_many.target.kind.identifier.name);
}

test "parsePointerType: tells a pointer to a read-only pointer from a read-only pointer to a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: *const(*u8), b: const(**u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const to_read_only = parameters[0].type.kind.pointer_type;
    try std.testing.expect(!to_read_only.constant);
    try std.testing.expect(to_read_only.target.kind.pointer_type.constant);
    const read_only_to_writable = parameters[1].type.kind.pointer_type;
    try std.testing.expect(read_only_to_writable.constant);
    try std.testing.expect(!read_only_to_writable.target.kind.pointer_type.constant);
}

test "parsePointerType: parses many pointers to arrays, slices and read-only pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: *[many][4]u8, b: *[many]*[]u8, c: *[many]const(*u8)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const arrays = parameters[0].type.kind.pointer_type;
    try std.testing.expect(arrays.many);
    try std.testing.expectEqualStrings("u8", arrays.target.kind.array_type.element.kind.identifier.name);
    const slices = parameters[1].type.kind.pointer_type;
    try std.testing.expect(slices.many);
    try std.testing.expect(!slices.target.kind.slice_type.constant);
    const read_only_pointers = parameters[2].type.kind.pointer_type;
    try std.testing.expect(read_only_pointers.many and !read_only_pointers.constant);
    try std.testing.expect(read_only_pointers.target.kind.pointer_type.constant);
}

test "parsePointerType: parses a pointer to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: **[]u8, b: const(**[]u8), c: *[]*[]u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const pointer = parameters[0].type.kind.pointer_type;
    try std.testing.expect(!pointer.many and !pointer.constant);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, pointer.target.location);
    const pointed_slice = pointer.target.kind.slice_type;
    try std.testing.expect(!pointed_slice.constant);
    try std.testing.expectEqualStrings("u8", pointed_slice.element.kind.identifier.name);
    const constant_pointer = parameters[1].type.kind.pointer_type;
    try std.testing.expect(!constant_pointer.many and constant_pointer.constant);
    try std.testing.expect(!constant_pointer.target.kind.slice_type.constant);
    const slices = parameters[2].type.kind.slice_type;
    try std.testing.expectEqualStrings("u8", slices.element.kind.slice_type.element.kind.identifier.name);
}

test "parseParentheses: reads one type in parentheses as that type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: (i32)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqualStrings("i32", parameter.type.kind.identifier.name);
}

test "parseParentheses: groups an expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return (a + b) * c");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.left.kind.binary.operator);
}

test "parseParentheses: groups an expression over several lines and continues the line after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32\n    return (\n        a +\n\n            # second\n    b\n    ) * c\nfn g() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const value = body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, value.kind.binary.operator);
    try std.testing.expectEqual(ast.BinaryOperator.add, value.kind.binary.left.kind.binary.operator);
    try std.testing.expectEqualStrings("c", value.kind.binary.right.kind.identifier.name);
}

test "parseParentheses: rejects a comma between types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: (i32, bool)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseParentheses: rejects a comma after one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: (i32,)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseParentheses: rejects empty parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ()) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: parses a pointer to a single value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *bool) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: const(*[many]i32)) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *const(*u8)) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around a type that is not a pointer as the type of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    var limit: const(u32) = 1\n    limit = 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around a type that is not a pointer as the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point\n    x: const(i32)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around a type that is not a pointer as the element of an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [2]const(i32)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around a type that is not a pointer as the type of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: const(i32)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around a type that is not a pointer as a return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> const(i32) = return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseConstantPointer: rejects const around an optional pointer and names the optional form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(card: const(?*Card)) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("const(...) is written only around a pointer: const(*T), const(*[N]T), const(*[]T) or const(*[many]T); an optional read-only pointer is ?const(*T)", parser.failure.?.message);
}

test "parseConstantPointer: rejects const around a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(card: const(const(*Card))) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstWithoutPointer, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
}

test "parseConstantPointer: parses a read-only pointer in a constant, as the value of a function that gives a type and as a type argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Alias = const(*u8)\nfn Bytes -> type = const(*[]u8)\nfn Run -> type\n    return const(*[many]u8)\nfn main()\n    _ = bytes.view_as(const(*[]u8))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const alias = module.declarations[0].kind.constant_declaration.value.kind.pointer_type;
    try std.testing.expect(alias.constant and !alias.many);
    const bytes = module.declarations[1].kind.function_definition.body[0].kind.value.kind.slice_type;
    try std.testing.expect(bytes.constant);
    const run = module.declarations[2].kind.function_definition.body[0].kind.@"return".?.kind.pointer_type;
    try std.testing.expect(run.constant and run.many);
    const call = module.declarations[3].kind.function_definition.body[0].kind.discard.kind.method_call;
    try std.testing.expect(call.arguments[0].value.kind.slice_type.constant);
}

test "parseOptionalType: parses an optional type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ?i32) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ??*i32) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ?) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseFunctionType: parses the parameter types and the return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32, bool,) -> u8) = noop");
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

test "parseFunctionType: parses parameter types over several lines with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Callback = fn(\n    i32,\n    bool,\n) -> u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function_type = module.declarations[0].kind.constant_declaration.value.kind.function_type;
    try std.testing.expectEqual(2, function_type.parameters.len);
    try std.testing.expectEqualStrings("bool", function_type.parameters[1].kind.identifier.name);
    try std.testing.expectEqualStrings("u8", function_type.return_type.kind.identifier.name);
}

test "parseFunctionType: returns void when no return type is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32), other: i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqualStrings("void", parameters[0].type.kind.function_type.return_type.kind.identifier.name);
    try std.testing.expectEqualStrings("other", parameters[1].name);
}

test "parseFunctionType: parses function types without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(callback: *fn -> i32, other: *fn) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[0].kind.function_definition.signature.parameters;
    const callback = parameters[0].type.kind.pointer_type.target.kind.function_type;
    try std.testing.expectEqual(0, callback.parameters.len);
    try std.testing.expectEqualStrings("i32", callback.return_type.kind.identifier.name);
    const other = parameters[1].type.kind.pointer_type.target.kind.function_type;
    try std.testing.expectEqualStrings("void", other.return_type.kind.identifier.name);
}

test "parseFunctionType: parses an optional function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: ?fn(i32) -> i32) = noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn apply(callback: fn(i32) i32) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedArrow, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, parser.failure.?.location.?);
}

test "parseCall: parses nested calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(add(1, 2))");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = mn::stdout::write(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const expression = module.declarations[0].kind.function_definition.body[0].kind.call;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, expression.location);
    const call = expression.kind.call;
    const path = call.callee.path_expression.path;
    try std.testing.expectEqual(3, path.len);
    try std.testing.expectEqualStrings("mn", path[0]);
    try std.testing.expectEqualStrings("stdout", path[1]);
    try std.testing.expectEqualStrings("write", path[2]);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseCall: parses the arguments of a function that gives a type over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const Map = HashMap(\n    u8,\n    u32,\n)\nconst Other = u8");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations.len);
    const call = module.declarations[0].kind.constant_declaration.value.kind.call;
    try std.testing.expectEqualStrings("HashMap", call.callee.identifier.name);
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("u32", call.arguments[1].value.kind.identifier.name);
}

test "parseCall: rejects a missing closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(1 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseNameExpression: parses a path used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> i32 = return utils::value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const path_expression = module.declarations[0].kind.function_definition.body[0].kind.@"return".?.kind.path_expression;
    try std.testing.expectEqual(2, path_expression.path.len);
    try std.testing.expectEqualStrings("utils", path_expression.path[0]);
    try std.testing.expectEqualStrings("value", path_expression.path[1]);
}

test "parsePathStart: parses a path that starts with the separator as a path from the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = module::match(module::Point::init())");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    const path = call.callee.path_expression.path;
    try std.testing.expectEqual(2, path.len);
    try std.testing.expectEqualStrings(ast.module_root, path[0]);
    try std.testing.expectEqualStrings("match", path[1]);
    const inner = call.arguments[0].value.kind.call.callee.path_expression.path;
    try std.testing.expectEqual(3, inner.len);
    try std.testing.expectEqualStrings("Point", inner[1]);
}

test "parsePathStart: records each path of the module except those from the module itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::text\nfn main(value: mn::container::ArrayList(u8)) = module::run(text::strip(value))");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.paths.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "container", "ArrayList" }), module.paths[0]);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "text", "strip" }), module.paths[1]);
}

test "parsePathStart: rejects a separator without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = ::(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
}

test "parsePath: rejects a separator without a name after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const write = stdout::");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "expectName: accepts reserved words after the separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = mn::comptime::error(\"stop\")");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const path = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.path;
    try std.testing.expectEqualStrings("comptime", path[1]);
    try std.testing.expectEqualStrings("error", path[2]);
}

test "parseNegation: wraps a number literal in a negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> i32 = return -5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("5", value.kind.negation.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, value.location);
}

test "parseNegation: allows a space before the number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() -> f64 = return - 2.5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("2.5", value.kind.negation.kind.float_literal.text);
}

test "parseNegation: rejects a minus before a literal that is not a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *-true) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedNumber, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseSegments: marks each name written after private and keeps the others unmarked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = things::private::Hidden::make(module::private::helper())");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "things", "Hidden", "make" }), call.callee.path_expression.path);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, call.callee.path_expression.crossings);
    const inner = call.arguments[0].value.kind.call.callee.path_expression;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ ast.module_root, "helper" }), inner.path);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, inner.crossings);
}

test "parseSegments: records the path without private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = filesystem::private::build_path(text)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(1, module.paths.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "filesystem", "build_path" }), module.paths[0]);
}

test "matchCrossing: rejects private written twice before a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = things::private::private::helper()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RepeatedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, parser.failure.?.location.?);
}

test "matchCrossing: rejects private without a separator and a name after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = things::private(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseArguments: accepts a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(1, 2,)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(2, module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments.len);
}

test "parseArguments: parses arguments over several lines with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    try filesystem::create_directory(\n        directory,\n\n        { create_ancestors = true },\n    )");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.@"try".kind.call;
    try std.testing.expectEqual(2, call.arguments.len);
    try std.testing.expectEqualStrings("directory", call.arguments[0].value.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 9 }, call.arguments[1].location);
}

test "parseArguments: rejects a missing argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(1, , 2)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseArgument: parses named arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(Point{ x = 1, y = 2 }, 3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(null, outer.arguments[1].name);
    const inner = outer.arguments[0].value.kind.composite_literal;
    try std.testing.expectEqualStrings("x", inner.elements[0].name.?);
    try std.testing.expectEqualStrings("1", inner.elements[0].value.kind.integer_literal.text);
    try std.testing.expectEqualStrings("y", inner.elements[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, inner.elements[1].location);
}

test "parseArgument: rejects a name without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(Point{ x = })");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, parser.failure.?.location.?);
}

test "parseArgument: rejects own alone after the first argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = builder.finish(path, own)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedOwnReceiver, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, parser.failure.?.location.?);
}

test "parseArgument: rejects own alone in a call that is not a method call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = release(own)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedOwnReceiver, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseArgument: rejects private before an argument of a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = run(private.count)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseMemberCall: parses a call to a function of a type that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = List(i32)::init(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.discard.kind.call;
    const member = call.callee.member;
    try std.testing.expectEqualStrings("init", member.name);
    try std.testing.expectEqualStrings("List", member.owner.kind.call.callee.identifier.name);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseMemberCall: marks a function written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = _ = Box(u8)::private::make()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const member = module.declarations[0].kind.function_definition.body[0].kind.discard.kind.call.callee.member;
    try std.testing.expectEqualStrings("make", member.name);
    try std.testing.expect(member.crossing);
}

test "parseMemberCall: parses a literal of a type that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    const list = List(i32){ first = 1 }\n    _ = list");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.function_definition.body[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqualStrings("List", literal.type.?.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("first", literal.elements[0].name.?);
}

test "parseMember: parses a method call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = card.show(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.method_call;
    try std.testing.expectEqualStrings("card", call.receiver.kind.identifier.name);
    try std.testing.expectEqualStrings("show", call.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, call.name_location);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseMember: parses the arguments of a method call over several lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    card.show(\n        1,\n        2,\n    )\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    const call = body[0].kind.call.kind.method_call;
    try std.testing.expectEqualStrings("show", call.name);
    try std.testing.expectEqual(2, call.arguments.len);
}

test "parseMember: marks a field and a method written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    list.private.count = 0\n    map.private.grow()\n    list.size = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const field = body[0].kind.assignment.target.kind.field_access;
    try std.testing.expectEqualStrings("count", field.field);
    try std.testing.expect(field.crossing);
    const call = body[1].kind.call.kind.method_call;
    try std.testing.expectEqualStrings("grow", call.name);
    try std.testing.expect(call.crossing);
    try std.testing.expect(!body[2].kind.assignment.target.kind.field_access.crossing);
}

test "parseMember: rejects private without a name after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(point.private)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "parseMember: parses a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return pointer.*");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("pointer", value.kind.dereference.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
}

test "parseMember: parses an optional unwrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return value.?");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("value", value.kind.unwrap.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
}

test "parseMember: rejects a dot without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = log(point.)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "matchOwnReceiver: hands the receiver to a method with own as its first argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    defer store.list.deinit(own)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.@"defer".statement.kind.call.kind.method_call;
    try std.testing.expect(call.receiver_own);
    try std.testing.expectEqual(0, call.arguments.len);
    try std.testing.expectEqualStrings("list", call.receiver.kind.field_access.field);
}

test "matchOwnReceiver: passes the arguments after own to the method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    try builder.finish(own, path)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.@"try".kind.method_call;
    try std.testing.expect(call.receiver_own);
    try std.testing.expectEqual(1, call.arguments.len);
    try std.testing.expect(!call.arguments[0].own);
    try std.testing.expectEqualStrings("path", call.arguments[0].value.kind.identifier.name);
}

test "matchOwnReceiver: leaves own before a name as a moved argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    try list.append(own record)\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.@"try".kind.method_call;
    try std.testing.expect(!call.receiver_own);
    try std.testing.expect(call.arguments[0].own);
    try std.testing.expectEqualStrings("record", call.arguments[0].value.kind.identifier.name);
}

test "parseSubscript: parses an index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32 = return values[position]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("values", value.kind.index.value.kind.identifier.name);
    try std.testing.expectEqualStrings("position", value.kind.index.index.kind.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, value.location);
}

test "parseSubscript: parses a slice of a whole array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(buffer[..])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    const slice = call.arguments[0].value;
    try std.testing.expectEqualStrings("buffer", slice.kind.slice.value.kind.identifier.name);
    try std.testing.expectEqual(null, slice.kind.slice.start);
    try std.testing.expectEqual(null, slice.kind.slice.end);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, slice.location);
}

test "parseSubscript: parses a slice with a start and an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[1..3])");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[start..])");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[..end])");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[1..][..2])");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(buffer[..)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBracket, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, parser.failure.?.location.?);
}

test "parseSubscript: rejects brackets without an index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseBound: parses an operation as a bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = take(values[start + 1..end])");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const slice = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value.kind.slice;
    try std.testing.expectEqual(ast.BinaryOperator.add, slice.start.?.kind.binary.operator);
    try std.testing.expectEqualStrings("end", slice.end.?.kind.identifier.name);
}

test "parseCaseLiteral: reads a case with a leading path separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const mode: Mode = ::Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("Read", value.kind.case_literal.name);
    try std.testing.expect(!value.kind.case_literal.called);
    try std.testing.expect(!value.kind.case_literal.braced);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, value.location);
}

test "parseCaseLiteral: marks a function written after private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const box: Box = ::private::make()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.case_literal;
    try std.testing.expectEqualStrings("make", literal.name);
    try std.testing.expect(literal.crossing);
    try std.testing.expect(literal.called);
}

test "parseCaseLiteral: reads a case with its value in braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const token: Token = ::Name{ \"cards\" }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("Name", value.kind.case_literal.name);
    try std.testing.expect(value.kind.case_literal.braced);
    try std.testing.expect(!value.kind.case_literal.called);
    try std.testing.expectEqualStrings("cards", value.kind.case_literal.arguments[0].value.kind.string_literal);
}

test "parseCaseLiteral: reads the parts of a tuple and an owned value in braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    take(::Pair{ 1, 2 }, ::Bytes{ own bytes })");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const arguments = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call.arguments;
    const pair = arguments[0].value.kind.case_literal;
    try std.testing.expectEqual(2, pair.arguments.len);
    try std.testing.expectEqualStrings("2", pair.arguments[1].value.kind.integer_literal.text);
    const bytes = arguments[1].value.kind.case_literal;
    try std.testing.expect(bytes.arguments[0].own);
    try std.testing.expectEqualStrings("bytes", bytes.arguments[0].value.kind.identifier.name);
}

test "parseCaseLiteral: reads a call to a function of the expected type in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const deck: Deck = ::load(\"cards\")");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("load", value.kind.case_literal.name);
    try std.testing.expect(value.kind.case_literal.called);
    try std.testing.expect(!value.kind.case_literal.braced);
}

test "parseCaseLiteral: leaves a path after a name as a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const first = record::field");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("record", value.kind.path_expression.path[0]);
    try std.testing.expectEqualStrings("field", value.kind.path_expression.path[1]);
}

test "parseCaseLiteral: leaves a member after a call as a member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const made = ArrayList(u8)::init");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("init", value.kind.member.name);
}

test "parseCaseLiteral: reads a range between two cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const part = items[::One..::Two]");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("One", value.kind.slice.start.?.kind.case_literal.name);
    try std.testing.expectEqualStrings("Two", value.kind.slice.end.?.kind.case_literal.name);
}

test "parseCaseLiteral: reads a case after a comma in a call that spans lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const opened = open(\n    path,\n    ::Read\n)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("Read", value.kind.call.arguments[1].value.kind.case_literal.name);
}

test "parseCaseLiteral: reads a separator on the next line inside brackets as the path of the name before it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const opened = open(\n    path\n    ::Read\n)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqual(1, value.kind.call.arguments.len);
    try std.testing.expectEqualStrings("Read", value.kind.call.arguments[0].value.kind.path_expression.path[1]);
}

test "parseCaseLiteral: reads a case as the body of a function on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give() -> Mode = ::Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqualStrings("Read", body[0].kind.value.kind.case_literal.name);
}

test "parseCaseLiteral: reads a line that starts with a case as a value of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give() -> Mode\n    const one = 1\n    ::Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expectEqualStrings("Read", body[1].kind.value.kind.case_literal.name);
}

test "parseCaseLiteral: reads a case in the body of a case and of an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give(number: u8) -> Mode = match number\n    case (0) ::Read\n    else if (number == 1) ::Write else ::Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const branching = module.declarations[0].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqualStrings("Read", branching.branches[0].body[0].kind.value.kind.case_literal.name);
}

test "parseCaseLiteral: rejects a number after the separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const mode: Mode = ::5");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, parser.failure.?.location.?);
}

test "parseCaseLiteral: rejects a dot where a case can stand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const mode: Mode = .Read");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseCaseLiteral: reads a reserved name after the separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const parser: Parser = ::match(\"text\")");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("match", value.kind.case_literal.name);
    try std.testing.expect(value.kind.case_literal.called);
}

test "parseCaseLiteral: rejects a longer path, the old form for a declaration of the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = ::Point::init()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.CaseWithoutEnum, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseCaseLiteral: rejects a path after a case with its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() = ::Point{ 1 }::init()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.CaseWithoutEnum, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, parser.failure.?.location.?);
}

test "parseBranchCase: rejects a case with a leading separator in a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give(mode: Mode) -> u8 = match mode\n    case ::Read\n        1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.BranchCaseWithColons, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 10 }, parser.failure.?.location.?);
}

test "parseBranchCase: rejects a case with a leading separator on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give(mode: Mode) -> u8 = match mode\n    case (::Read) 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.BranchCaseWithColons, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 11 }, parser.failure.?.location.?);
}

test "parsePathStart: reads module before a separator as the current module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = module::match(\"text\")");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    const path = body[0].kind.call.kind.call.callee.path_expression.path;
    try std.testing.expectEqualStrings(ast.module_root, path[0]);
    try std.testing.expectEqualStrings("match", path[1]);
}

test "parsePathStart: leaves module without a separator as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const value = module.field");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("module", value.kind.field_access.value.kind.identifier.name);
}

test "parsePathStart: leaves module later in a path as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const value = shapes::module::field");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("shapes", value.kind.path_expression.path[0]);
    try std.testing.expectEqualStrings("module", value.kind.path_expression.path[1]);
}

test "parseAssignment: rejects the old form of a declaration of the module as a target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give\n    ::total = 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.CaseWithoutEnum, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseImport: rejects a path that starts with module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import module::thing");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ReservedImport, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("an import path cannot start with module::, which names the current module; a directory named module has to be renamed", parser.failure.?.message);
}

test "parseImport: rejects a path that starts with module under an alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const VALUE: i32 = 1\nimport module::thing as other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ReservedImport, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
    try std.testing.expectEqualStrings("an import path cannot start with module::, which names the current module; a directory named module has to be renamed", parser.failure.?.message);
}

test "parseImport: keeps module as the path of an import with an alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import module as other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const import_declaration = module.declarations[0].kind.import;
    try std.testing.expectEqualStrings("module", import_declaration.path[0]);
    try std.testing.expectEqualStrings("other", import_declaration.name);
}

test "parseImport: keeps module later in a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import shapes::module as other");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const import_declaration = module.declarations[0].kind.import;
    try std.testing.expectEqualStrings("module", import_declaration.path[1]);
}

test "parseAssignment: rejects the old form of a declaration of the module as a target of a compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give\n    ::total += 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.CaseWithoutEnum, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseArgument: reads an underscore as an inferred type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const value = make(_, 1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expect(value.kind.call.arguments[0].value.kind == .inferred_type);
    try std.testing.expect(value.kind.call.arguments[1].value.kind == .integer_literal);
}

test "parseArgument: keeps a discard, an array length and a parameter with an underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn give(_: u8) -> [1]u8\n    _ = make(1)\n    return [_]u8{ 1 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const function = module.declarations[0].kind.function_definition;
    try std.testing.expectEqualStrings("_", function.signature.parameters[0].name);
    try std.testing.expect(function.body[0].kind == .discard);
    try std.testing.expect(function.body[1].kind.@"return".?.kind == .composite_literal);
}

test "parseArgument: rejects an underscore that starts a larger expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const value = make(_ + 1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseLengthParameter: reads a length parameter of an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Same(type T)\ninstance(type A, comptime N: usize) Same([N]A)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameters = module.declarations[1].kind.instance_declaration.parameters;
    try std.testing.expect(!parameters[0].is_length);
    try std.testing.expect(parameters[1].is_length);
    try std.testing.expectEqualStrings("N", parameters[1].name);
}

test "parseLengthParameter: rejects a length of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance(comptime N: u8) Same([N]u8)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LengthParameterType, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, parser.failure.?.location.?);
}

test "parseTypeParameters: rejects a length parameter on a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn(comptime N: usize) give() = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTypeParameter, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 4 }, parser.failure.?.location.?);
}

test "parseTypeParameters: rejects a default of a declared type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn(type T = u8) give(value: T) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.TypeParameterDefault, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, parser.failure.?.location.?);
}

test "parseWithValue: reads a value after a case literal that is called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const path: Path = ::parse(\"cards\") with &arena");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.constant_declaration.value;
    try std.testing.expect(value.kind.case_literal.with_value != null);
}

test "fail: rejects private in a function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main\n    private const limit: u8 = 1\n    _ = limit");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "fail: rejects private before a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(private value: u8) = noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
}

test "fail: rejects private before a tuple element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const pair: [private u8, u8] = { 1, 2 }");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedPrivate, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "findUnclosedParenthesis: points at a parenthesis left open at the end of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() = run(1, 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnclosedParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "findUnclosedParenthesis: points at a parenthesis left open before the next statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    run(\n        show(1),\n    stop()\n\nfn other() = noop\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnclosedParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, parser.failure.?.location.?);
}

test "findUnclosedParenthesis: keeps the error inside parentheses that close on a later line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    run(\n        1 2\n    )");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 11 }, parser.failure.?.location.?);
}

test "findUnclosedParenthesis: keeps the error on the line of a parenthesis closed by a bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    run(1]\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 10 }, parser.failure.?.location.?);
}

test "findUnclosedParenthesis: leaves a brace left open to the error of the brace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main()\n    run({\n        1,\n    stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightBrace, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 11 }, parser.failure.?.location.?);
}
