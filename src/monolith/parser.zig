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
            if (try self.parseEnumDefinition(allocator, offset)) |definition| {
                break :kind .{ .enum_definition = definition };
            }
            if (try self.parseTypeclassDefinition(allocator, offset)) |definition| {
                break :kind .{ .typeclass_definition = definition };
            }
            if (try self.parseInstance(allocator, offset)) |instance_declaration| {
                break :kind .{ .instance_declaration = instance_declaration };
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
        if (self.tokens[position].kind == .keyword_struct) return null;
        if (self.tokens[position].kind == .keyword_inline) return self.fail(position, error.InlineExternal);
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
        const inlined = self.match(&position, .keyword_inline) != null;
        if (inlined and self.tokens[position].kind == .keyword_external) return self.fail(position, error.InlineExternal);
        var signature = (try self.parseFunctionSignature(allocator, &position, receiver)) orelse {
            if (inlined) return self.fail(position, error.ExpectedFunctionKeyword);
            return null;
        };
        signature.@"inline" = inlined;
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
        const declared = try self.parseTypeParameters(allocator, &position);
        const name = try self.expectName(&position);
        _ = try self.expect(&position, .left_parenthesis, error.ExpectedLeftParenthesis);
        const parameters = try self.parseParameters(allocator, &position);
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const return_type = try self.parseReturnType(allocator, &position);

        offset.* = position;
        return .{
            .receiver = receiver,
            .name = name,
            .declared = declared,
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
        if (try self.parseTypeParameter(allocator, &position)) |parameter| {
            offset.* = position;
            return parameter;
        }
        if (self.parseAnyParameter(&position)) |parameter| {
            offset.* = position;
            return parameter;
        }
        const marker = self.match(&position, .keyword_comptime);
        const underscore = self.match(&position, .underscore);
        var parameter = if (underscore) |discarded|
            try self.parseNameType(allocator, &position, "_", discarded.location)
        else if (try self.parseTypedName(allocator, &position)) |typed_name|
            typed_name
        else if (marker != null)
            return self.fail(position, error.ExpectedIdentifier)
        else
            return null;
        if (marker != null) parameter.kind = .compile_time;
        if (self.tokens[position].kind == .equals) {
            return self.fail(position, error.ParameterDefault);
        }

        offset.* = position;
        return parameter;
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
        var requirement: ?ast.Expression = null;
        if (self.match(&position, .colon) != null) {
            requirement = (try self.parseNameExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
        }
        const kind: ast.ExpressionKind = .{ .identifier = .{ .name = "type" } };

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .type = .{ .kind = kind, .location = marker.location },
            .location = name.location,
            .kind = .type,
            .requirement = requirement,
        };
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
        const else_depth: ?usize = if (self.tokens[offset.* - 1].kind == .indent) depth else null;
        if (try self.parseIf(allocator, offset, depth, else_depth)) |statement| return statement;
        if (self.isColonLabel(offset.*)) return self.fail(offset.*, error.LabelWithoutSigil);
        if (try self.parseWhile(allocator, offset, depth, else_depth)) |statement| return statement;
        if (try self.parseFor(allocator, offset, depth, else_depth)) |statement| return statement;
        if (try self.parseMatch(allocator, offset, depth)) |statement| return statement;
        if (try self.parseJump(offset)) |statement| return statement;
        if (try self.parseDefer(allocator, offset)) |statement| return statement;
        if (try self.parseDiscard(allocator, offset)) |statement| return statement;
        if (try self.parseTupleDeclaration(allocator, offset)) |declaration| {
            return .{ .kind = .{ .tuple_declaration = declaration }, .location = location };
        }
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

    fn parseIf(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_if) orelse return null;
        const condition = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        const names = try self.parseConditionNames(allocator, &position);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);
        var else_body: ?[]ast.Statement = null;
        if (self.matchElse(&position, else_depth)) {
            if (try self.parseIf(allocator, &position, depth, else_depth)) |chained| {
                else_body = try allocator.dupe(ast.Statement, &.{chained});
            } else {
                else_body = try self.parseElseBlock(allocator, &position, depth);
            }
        }

        offset.* = position;
        const conditional: ast.If = .{ .condition = condition, .names = names, .body = body, .else_body = else_body };
        return .{ .kind = .{ .@"if" = conditional }, .location = keyword.location };
    }

    fn parseWhile(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const location = self.tokens[position].location;
        const label = self.parseLabel(&position);
        if (self.match(&position, .keyword_while) == null) return null;
        const condition = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        const names = try self.parseConditionNames(allocator, &position);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);
        var else_body: ?[]ast.Statement = null;
        if (self.matchElse(&position, else_depth)) {
            else_body = try self.parseElseBlock(allocator, &position, depth);
        }

        offset.* = position;
        const loop: ast.While = .{
            .label = label,
            .condition = condition,
            .names = names,
            .body = body,
            .else_body = else_body,
        };
        return .{ .kind = .{ .@"while" = loop }, .location = location };
    }

    fn parseConditionNames(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError![]ast.ElementName {
        if (self.match(offset, .keyword_as) == null) return &.{};
        const name = try self.parseValueName(offset);
        return allocator.dupe(ast.ElementName, &.{name});
    }

    fn parseFor(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        depth: usize,
        else_depth: ?usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const location = self.tokens[position].location;
        const label = self.parseLabel(&position);
        if (self.match(&position, .keyword_for) == null) return null;
        const tuple = self.tokens[position].kind == .left_parenthesis;
        const names = try self.parseElementNames(allocator, &position);
        _ = try self.expect(&position, .keyword_in, error.ExpectedIn);
        const sequence = try self.parseSequence(allocator, &position);
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);
        var else_body: ?[]ast.Statement = null;
        if (self.matchElse(&position, else_depth)) {
            else_body = try self.parseElseBlock(allocator, &position, depth);
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
        if (self.match(&position, .left_parenthesis) == null) {
            const name = try self.parseElementName(&position);
            offset.* = position;
            return allocator.dupe(ast.ElementName, &.{name});
        }
        var names: std.ArrayList(ast.ElementName) = .empty;
        while (true) {
            try names.append(allocator, try self.parseElementName(&position));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

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
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_match) orelse return null;
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };
        _ = try self.expect(&position, .colon, error.ExpectedColon);
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
        const matching: ast.Match = .{ .value = value, .branches = branches.items, .names = names.items };
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
        var name: ast.ElementName = .{ .name = "_", .location = location };
        var naming: ast.Naming = .none;
        if (self.match(&position, .keyword_else) == null) {
            _ = try self.expect(&position, .keyword_case, error.ExpectedCaseOrElse);
            while (true) {
                try cases.append(allocator, try self.parseBranchCase(allocator, &position));
                if (self.isPayloadName(position)) {
                    if (cases.items.len > 1) return self.fail(position, error.NamedCases);
                    position += 1;
                    name = try self.parseElementName(&position);
                    naming = .payload;
                    _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
                    if (self.tokens[position].kind == .comma) return self.fail(position, error.NamedCases);
                }
                if (self.match(&position, .comma) == null) break;
            }
            if (naming == .none and self.tokens[position].kind == .keyword_as) {
                if (cases.items.len > 1) return self.fail(position, error.NamedCases);
                position += 1;
                name = try self.parseValueName(&position);
                naming = .value;
            }
        }
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const body = try self.parseBlock(allocator, &position, depth);
        try names.append(allocator, name);

        offset.* = position;
        return .{ .cases = cases.items, .naming = naming, .body = body, .location = location };
    }

    fn parseBranchCase(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.BranchCase {
        var position = offset.*;
        if (try self.parseNameExpression(allocator, &position)) |name| {
            if (self.isPayloadName(position)) {
                offset.* = position;
                return .{ .pattern = name };
            }
            position = offset.*;
        }
        const pattern = (try self.parseOperation(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedBranch);
        };
        var case: ast.BranchCase = .{ .pattern = pattern };
        if (self.match(&position, .dot_dot) != null) {
            case.range = true;
            case.end = try self.parseOperation(allocator, &position);
        }

        offset.* = position;
        return case;
    }

    fn isPayloadName(self: *const Parser, offset: usize) bool {
        var position = offset;
        if (self.tokens[position].kind != .left_parenthesis) return false;
        position += 1;
        if (self.tokens[position].kind == .asterisk) position += 1;
        const kind = self.tokens[position].kind;
        if (kind != .identifier and kind != .underscore) return false;
        if (self.tokens[position + 1].kind != .right_parenthesis) return false;
        return self.tokens[position + 2].kind != .keyword_as;
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
    ) ParseError![]ast.Statement {
        _ = try self.expect(offset, .colon, error.ExpectedColon);
        return self.parseBlock(allocator, offset, depth);
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
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const keyword = self.tokens[position];
        if (keyword.kind != .keyword_defer and keyword.kind != .keyword_errdefer) return null;
        position += 1;
        const start = position;
        const statement = (try self.parseDiscard(allocator, &position)) orelse
            (try self.parseAssignment(allocator, &position)) orelse
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
        const operator_token = self.tokens[position];
        const operator: ?ast.CompoundOperator = if (findOperator(compound_operators, operator_token.kind)) |found|
            .{ .operator = found, .location = operator_token.location }
        else
            null;
        if (operator == null and operator_token.kind != .equals) return null;
        position += 1;
        switch (target.kind) {
            .identifier, .field_access, .index, .dereference => {},
            else => return self.fail(offset.*, error.ExpectedTarget),
        }
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        const assignment: ast.Assignment = .{ .target = target, .operator = operator, .value = value };
        return .{ .kind = .{ .assignment = assignment }, .location = target.location };
    }

    fn parseCallStatement(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Statement {
        var position = offset.*;
        const call = (try self.parseExpression(allocator, &position)) orelse return null;
        if (!isCallOrTriedCall(call)) return null;

        offset.* = position;
        return .{ .kind = .{ .call = call }, .location = call.location };
    }

    fn parseTupleDeclaration(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.TupleDeclaration {
        var position = offset.*;
        _ = self.match(&position, .keyword_const) orelse return null;
        if (self.tokens[position].kind != .left_parenthesis) return null;
        const names = try self.parseElementNames(allocator, &position);
        _ = try self.expect(&position, .equals, error.ExpectedEquals);
        const value = (try self.parseExpression(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedExpression);
        };

        offset.* = position;
        return .{ .names = names, .value = value };
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
        const value = (try self.parseExpression(allocator, &position)) orelse {
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

    fn parseStructDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.StructDefinition {
        var position = offset.*;
        const external = self.match(&position, .keyword_external) != null;
        _ = self.match(&position, .keyword_struct) orelse return null;
        const name_location = self.tokens[position].location;
        const name = try self.expectName(&position);
        var fields: []ast.Field = &.{};
        if (self.match(&position, .colon) != null) {
            const receiver = try buildReceiverExpression(allocator, name, name_location);
            fields = try self.parseMembers(allocator, &position, receiver, 0, &self.methods);
        }

        offset.* = position;
        return .{ .name = name, .external = external, .fields = fields };
    }

    fn parseEnumDefinition(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.EnumDefinition {
        var position = offset.*;
        const kind: types.EnumKind = switch (self.tokens[position].kind) {
            .keyword_enum => .enumeration,
            .keyword_error => .error_set,
            else => return null,
        };
        position += 1;
        const name_location = self.tokens[position].location;
        const name = try self.expectName(&position);
        var cases: std.ArrayList(ast.EnumCase) = .empty;
        if (self.match(&position, .colon) != null) {
            const receiver = try buildReceiverExpression(allocator, name, name_location);
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const location = self.tokens[position].location;
                if (kind == .error_set) {
                    try cases.append(allocator, try self.parseCase(allocator, &position, error.ExpectedErrorCase));
                    continue;
                }
                if (try self.parseFunctionDefinition(allocator, &position, receiver, depth)) |parsed| {
                    var function = parsed;
                    function.signature.self_parameter = findSelfParameter(function.signature, "Self");
                    const method: ast.DeclarationKind = .{ .function_definition = function };
                    try self.methods.append(allocator, .{ .kind = method, .location = location });
                    continue;
                }
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
        functions: *std.ArrayList(ast.Declaration),
    ) ParseError![]ast.Field {
        var position = offset.*;
        const depth = try self.expectBlock(position, outer);
        var fields: std.ArrayList(ast.Field) = .empty;
        while (try self.matchBlockLine(&position, depth, outer)) {
            const location = self.tokens[position].location;
            const method = try self.parseFunctionDefinition(allocator, &position, receiver, depth);
            if (method) |parsed| {
                var function = parsed;
                function.signature.self_parameter = findSelfParameter(function.signature, "Self");
                const kind: ast.DeclarationKind = .{ .function_definition = function };
                try functions.append(allocator, .{ .kind = kind, .location = location });
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
        if (self.match(&position, .colon) != null) {
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const start = position;
                const inlined = self.match(&position, .keyword_inline) != null;
                const parsed = try self.parseFunctionSignature(allocator, &position, null);
                var signature = parsed orelse {
                    return self.fail(position, error.ExpectedFunctionKeyword);
                };
                signature.self_parameter = findTypeclassSelfParameter(signature, parameters.items);
                signature.@"inline" = inlined;
                try functions.append(allocator, signature);
                if (self.match(&position, .colon) == null) {
                    if (inlined) return self.fail(start, error.InlineSignature);
                    try defaults.append(allocator, null);
                    continue;
                }
                const body = try self.parseBlock(allocator, &position, depth);
                const definition: ast.FunctionDefinition = .{ .signature = signature, .body = body };
                const template = try ast.cloneFunctionDefinition(allocator, definition);
                try defaults.append(allocator, .{ .body = body, .template = template });
            }
        }

        offset.* = position;
        return .{
            .name = name.kind.identifier,
            .parameters = parameters.items,
            .functions = functions.items,
            .defaults = defaults.items,
        };
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
        var requirement: ?ast.Expression = null;
        if (self.match(&position, .colon) != null) {
            requirement = (try self.parseNameExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
        }

        offset.* = position;
        return .{ .name = name.kind.identifier, .arity = arity, .requirement = requirement, .location = name.location };
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
        const parameters = try self.parseTypeParameters(allocator, &position);
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
        if (self.match(&position, .colon) != null) {
            const depth = try self.expectBlock(position, 0);
            while (try self.matchBlockLine(&position, depth, 0)) {
                const location = self.tokens[position].location;
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
    ) ParseError![]ast.InstanceParameter {
        var position = offset.*;
        if (self.match(&position, .left_parenthesis) == null) return &.{};
        var parameters: std.ArrayList(ast.InstanceParameter) = .empty;
        while (true) {
            try parameters.append(allocator, try self.parseInstanceParameter(allocator, &position));
            if (self.match(&position, .comma) == null) break;
        }
        _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);

        offset.* = position;
        return parameters.items;
    }

    fn parseInstanceParameter(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!ast.InstanceParameter {
        var position = offset.*;
        try self.expectTypeMarker(&position);
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        var requirement: ?ast.Expression = null;
        if (self.match(&position, .colon) != null) {
            requirement = (try self.parseNameExpression(allocator, &position)) orelse {
                return self.fail(position, error.ExpectedIdentifier);
            };
        }

        offset.* = position;
        return .{ .name = name.kind.identifier, .requirement = requirement, .location = name.location };
    }

    fn parseImport(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Import {
        var position = offset.*;
        _ = self.match(&position, .keyword_import) orelse return null;
        const first = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const path = try self.parsePath(allocator, &position, first);
        var name = path[path.len - 1];
        if (self.match(&position, .keyword_as) != null) {
            name = (try self.expect(&position, .identifier, error.ExpectedIdentifier)).kind.identifier;
        }

        offset.* = position;
        return .{ .path = path, .name = name };
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
        var expression = (try self.parseOperand(allocator, &position)) orelse return null;
        if (expression.kind == .range and isPostfixStart(self.tokens[position].kind)) return self.fail(offset.*, error.RangeOperand);
        while (true) {
            if (isLiteralType(expression) and self.tokens[position].kind == .left_brace) {
                const literal_type = try allocator.create(ast.Expression);
                literal_type.* = expression;
                expression = try self.parseCompositeLiteral(allocator, &position, literal_type);
            } else if (expression.kind == .call and self.match(&position, .double_colon) != null) {
                expression = try self.parseMemberCall(allocator, &position, expression);
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
        if (self.tokens[offset.*].kind == .keyword_any) return self.fail(offset.*, error.MisplacedAny);
        if (self.isTypeConstructor(offset.*, "Const")) return self.fail(offset.*, error.MisplacedConst);
        if (self.isTypeConstructor(offset.*, "Many")) return self.fail(offset.*, error.MisplacedMany);
        if (self.tokens[offset.*].kind == .left_brace) {
            return try self.parseCompositeLiteral(allocator, offset, null);
        }
        if (try self.parseBrackets(allocator, offset)) |expression| return expression;
        if (try self.parseParentheses(allocator, offset)) |expression| return expression;
        if (try self.parsePointerType(allocator, offset)) |pointer_type| return pointer_type;
        if (try self.parseOptionalType(allocator, offset)) |optional_type| return optional_type;
        if (try self.parseFunctionType(allocator, offset)) |function_type| return function_type;
        if (try self.parseStructType(allocator, offset)) |struct_type| return struct_type;
        if (try self.parseCall(allocator, offset)) |call| return call;
        if (try self.parseNameExpression(allocator, offset)) |name| return name;
        if (try self.parseNegation(allocator, offset)) |negation| return negation;
        return self.parseLiteral(offset);
    }

    fn parseStructType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const keyword = self.match(&position, .keyword_struct) orelse return null;
        _ = try self.expect(&position, .colon, error.ExpectedColon);
        const receiver: ast.Expression = .{ .kind = .{ .identifier = .{ .name = "Self" } }, .location = keyword.location };
        var functions: std.ArrayList(ast.Declaration) = .empty;
        const outer = self.findLineIndentation(offset.*);
        const fields = try self.parseMembers(allocator, &position, receiver, outer, &functions);
        const struct_type = try allocator.create(ast.StructType);
        struct_type.* = .{ .fields = fields, .functions = functions.items };

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
            const start = position;
            const element = try self.parseArgument(allocator, &position);
            const named = element.name != null;
            if (elements.items.len > 0 and named != (elements.items[0].name != null)) {
                return self.fail(start, error.MixedNamedValues);
            }
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
        if (empty and self.tokens[position].kind == .keyword_const) return self.fail(position, error.ConstSliceSyntax);
        if (empty and self.isTypeConstructor(position, "Many")) return self.fail(position, error.MisplacedMany);
        const constant = empty and self.isTypeConstructor(position, "Const");
        if (constant) position += 2;
        const has_comma = elements.items.len > 1 or trailing_comma;
        if (!constant and (has_comma or !self.isTypeStart(position))) {
            offset.* = position;
            const tuple_type: ast.TupleType = .{ .elements = elements.items };
            return .{ .kind = .{ .tuple_type = tuple_type }, .location = bracket.location };
        }
        if (empty) {
            const slice_type = try self.parseSliceType(allocator, &position, constant);
            offset.* = position;
            return .{ .kind = .{ .slice_type = slice_type }, .location = bracket.location };
        }
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
        if (constant) _ = try self.expect(offset, .right_parenthesis, error.ExpectedRightParenthesis);
        return .{ .constant = constant, .element = element };
    }

    fn parsePointerType(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Expression {
        var position = offset.*;
        const asterisk = self.match(&position, .asterisk) orelse return null;
        if (self.tokens[position].kind == .keyword_const) return self.fail(position, error.ConstPointerSyntax);
        if (self.isManyWord(position)) return self.fail(position, error.ManyPointerSyntax);
        const many = self.isTypeConstructor(position, "Many");
        if (many) position += 2;
        if (self.isTypeConstructor(position, "Const") and self.isTypeConstructor(position + 2, "Many")) {
            return self.fail(position, error.ConstOutsideMany);
        }
        const constant = self.isTypeConstructor(position, "Const");
        if (constant) position += 2;
        const target = try allocator.create(ast.Expression);
        target.* = (try self.parseOperand(allocator, &position)) orelse {
            return self.fail(position, error.ExpectedType);
        };
        if (constant) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        if (many) _ = try self.expect(&position, .right_parenthesis, error.ExpectedRightParenthesis);
        const pointer_type: ast.PointerType = .{
            .many = many,
            .constant = constant,
            .target = target,
        };

        offset.* = position;
        return .{ .kind = .{ .pointer_type = pointer_type }, .location = asterisk.location };
    }

    fn isManyWord(self: *Parser, offset: usize) bool {
        const current = self.tokens[offset];
        if (current.kind != .identifier or !std.mem.eql(u8, current.kind.identifier, "many")) return false;
        return self.tokens[offset + 1].kind == .keyword_const or self.isTypeStart(offset + 1);
    }

    fn isTypeConstructor(self: *const Parser, offset: usize, name: []const u8) bool {
        const current = self.tokens[offset];
        if (current.kind != .identifier or !std.mem.eql(u8, current.kind.identifier, name)) return false;
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
        const first = self.tokens[position];
        const path = (try self.parsePathStart(allocator, &position)) orelse return null;
        const callee = buildName(path);
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
        const path = (try self.parsePathStart(allocator, &position)) orelse return null;

        offset.* = position;
        return buildNameExpression(path, first.location);
    }

    fn parsePathStart(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
    ) ParseError!?ast.Path {
        if (self.tokens[offset.*].kind == .identifier) {
            const first = self.tokens[offset.*];
            offset.* += 1;
            return try self.parsePath(allocator, offset, first);
        }
        if (self.tokens[offset.*].kind != .double_colon) return null;
        var position = offset.*;
        var path: std.ArrayList([]const u8) = .empty;
        try path.append(allocator, ast.module_root);
        while (self.match(&position, .double_colon) != null) {
            try path.append(allocator, try self.expectName(&position));
        }

        offset.* = position;
        return path.items;
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
            try path.append(allocator, try self.expectName(&position));
        }

        offset.* = position;
        return path.items;
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

    fn parseMemberCall(
        self: *Parser,
        allocator: std.mem.Allocator,
        offset: *usize,
        owner: ast.Expression,
    ) ParseError!ast.Expression {
        var position = offset.*;
        const stored = try allocator.create(ast.Expression);
        stored.* = owner;
        const name = try self.expect(&position, .identifier, error.ExpectedIdentifier);
        const member: ast.Member = .{ .owner = stored, .name = name.kind.identifier };
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
    ExpectedTypeParameter,
    ExpectedCase,
    ExpectedErrorCase,
    ExpectedArrow,
    ExpectedType,
    ConstPointerSyntax,
    ConstSliceSyntax,
    ManyPointerSyntax,
    MisplacedConst,
    MisplacedMany,
    ConstOutsideMany,
    ExpectedEquals,
    ExpectedStatement,
    ExpectedExpression,
    ExpectedNumber,
    ExpectedTarget,
    ExpectedRightBracket,
    ExpectedLeftBrace,
    ExpectedRightBrace,
    MixedNamedValues,
    ExpectedField,
    ParameterDefault,
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
    InlineSignature,
    RangeOperand,
    DiscardedValueName,
    ExpectedDeferredStatement,
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
    for (parameters) |parameter| {
        if (parameter.arity != 0) continue;
        const self_parameter = findSelfParameter(signature, parameter.name);
        if (self_parameter != .none) return self_parameter;
    }
    return .none;
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

fn buildName(path: ast.Path) ast.Name {
    if (path.len == 1) return .{ .identifier = .{ .name = path[0] } };
    return .{ .path_expression = .{ .path = path } };
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
        error.ExpectedFunctionKeyword => "expected 'fn' or 'struct'",
        error.ExternalFunctionBody => "external functions have no body",
        error.ExpectedTypeParameter => "expected a type parameter, e.g. type T",
        error.ExpectedCase => "expected a case or a function",
        error.ExpectedErrorCase => "expected a case",
        error.ExpectedArrow => "expected '->'",
        error.ExpectedType => "expected a type",
        error.ConstPointerSyntax => "write *Const(T) instead of *const T",
        error.ConstSliceSyntax => "write []Const(T) instead of []const T",
        error.ManyPointerSyntax => "write *Many(T) instead of *many T, and *Many(Const(T)) instead of *many const T",
        error.MisplacedConst => "Const(T) is allowed only as what *, *Many or [] points to, e.g. *Const(T) or []Const(T)",
        error.MisplacedMany => "Many(T) is allowed only right after *, e.g. *Many(T)",
        error.ConstOutsideMany => "write *Many(Const(T)) instead of *Const(Many(T))",
        error.ExpectedEquals => "expected '='",
        error.ExpectedStatement => "expected a statement",
        error.ExpectedExpression => "expected an expression",
        error.ExpectedNumber => "expected a number after '-'",
        error.ExpectedTarget => "expression cannot be assigned",
        error.ExpectedRightBracket => "expected ']'",
        error.ExpectedLeftBrace => "expected '{'",
        error.ExpectedRightBrace => "expected '}'",
        error.MixedNamedValues => "either every value has a name or none does",
        error.ExpectedField => "expected a field or a function",
        error.ParameterDefault => "parameters cannot have default values, use a struct parameter with field defaults",
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
        error.InlineSignature => "a typeclass function without a body cannot be inline",
        error.RangeOperand => "a range cannot be an operand",
        error.DiscardedValueName => "'as' needs a name, leave it out to leave the value without a name",
        error.ExpectedDeferredStatement => "expected a call, an assignment or a discard",
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
    var lexer = @import("lexer.zig").Lexer.init("external fn stdout_write(text: []Const(u8))\nfn main(): noop");
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

test "parseFunctionDefinition: parses an inline function at the top level and in a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline fn double(value: i32) -> i32: return value * 2\nfn plain(): noop\nstruct Box:\n    value: i32\n    inline fn get(self: Self) -> i32: return self.value");
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

test "parseFunctionSignature: accepts a reserved word as the name of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn match(pattern: []Const(u8)) -> bool: return true");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqualStrings("match", module.declarations[0].kind.function_definition.signature.name);
}

test "parseFunctionSignature: parses the types a function declares after fn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("inline fn(type Item, type Other: Show) pair(item: Item, other: Other) -> usize: return 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const signature = module.declarations[0].kind.function_definition.signature;
    try std.testing.expect(signature.@"inline");
    try std.testing.expectEqualStrings("pair", signature.name);
    try std.testing.expectEqual(2, signature.declared.len);
    try std.testing.expectEqualStrings("Item", signature.declared[0].name);
    try std.testing.expectEqual(null, signature.declared[0].requirement);
    try std.testing.expectEqualStrings("Other", signature.declared[1].name);
    try std.testing.expectEqualStrings("Show", signature.declared[1].requirement.?.kind.identifier.name);
    try std.testing.expectEqual(2, signature.parameters.len);
}

test "parseFunctionSignature: rejects a reserved word as the name of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn find(match: []Const(u8)) -> bool: return true");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, parser.failure.?.location.?);
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

test "parseAnyParameter: parses a parameter of type any" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn count(values: any, _: any) -> usize: return 0");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    var value: any = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: any");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as a return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> any: return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the element of a slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(values: []any): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the target of a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(value: *any): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Const as the type of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    var limit: Const(u32) = 1\n    limit = 2");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Const as the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: Const(i32)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Const as the element of an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [2]Const(i32)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Const as the type of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: Const(i32)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Const as a return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Const(i32): return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Many without an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: Many(u8)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseOperand: rejects Many without an asterisk in an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: ?Many(u8)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseOperand: rejects any as the type of a comptime parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(comptime value: any): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedAny, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
}

test "parseParameter: parses a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T, value: T) -> T: return value");
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
    var lexer = @import("lexer.zig").Lexer.init("fn make(type T: Default) -> T: return Default(T)::value()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(ast.ParameterKind.type, parameter.kind);
    try std.testing.expectEqualStrings("Default", parameter.requirement.?.kind.identifier.name);
}

test "parseParameter: parses a comptime parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn repeat(comptime count: usize): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn repeat(comptime): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("external fn pair() [i32, bool]");
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

test "parseIndentedBlock: accepts a return as the last statement of a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    a = 1\n    return\nfn other(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expect(body[1].kind == .@"return");
}

test "parseIndentedBlock: accepts a statement after a loop whose inline block returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while true: return\n    a = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, body.len);
    try std.testing.expect(body[1].kind == .assignment);
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

test "parseIf: parses a condition and a body without an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if ready:\n        step()\n    done()");
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

test "parseIf: parses an else block on the line after the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if ready:\n        step()\n    else:\n        wait()\n        stop()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if one:\n        first()\n    else if two:\n        second()\n    else:\n        third()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if ready: step()\n    else: wait()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(1, conditional.body.len);
    try std.testing.expectEqualStrings("wait", conditional.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseIf: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): if ready step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
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

test "parseWhile: parses a label before the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer while running: step()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running:\n        step()\n    else:\n        stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const body = module.declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(1, body.len);
    const loop = body[0].kind.@"while";
    try std.testing.expectEqual(null, loop.label);
    try std.testing.expectEqualStrings("stop", loop.else_body.?[0].kind.call.kind.call.callee.identifier.name);
}

test "parseWhile: rejects an else if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running: step()\n    else if done: stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, parser.failure.?.location.?);
}

test "parseConditionNames: parses a value name after an if condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if found as *card: noop\n    else: noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while queue.pop() as job: run(job)");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if ready: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(0, module.declarations[0].kind.function_definition.body[0].kind.@"if".names.len);
}

test "parseFor: parses a name, a sequence and an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    for item in items:\n        step()\n        stop()");
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

test "parseFor: parses a label, an inline body and an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer for item in items: step()\n    else: stop()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for item items: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIn, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseFor: rejects a missing colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for item in items step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, parser.failure.?.location.?);
}

test "parseElementNames: parses names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for (name, *score, _) in pairs: step()");
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
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, loop.names[1].location);
}

test "parseElementNames: parses one name in parentheses as a tuple pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for (name) in pairs: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expect(loop.tuple);
    try std.testing.expectEqualStrings("name", loop.names[0].name);
}

test "parseElementNames: rejects names in parentheses inside names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for (name, (score, rank)) in pairs: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "parseElementNames: rejects a missing closing parenthesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for (name, score in pairs: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, parser.failure.?.location.?);
}

test "parseElementName: parses an underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for _ in items: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expectEqualStrings("_", loop.names[0].name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, loop.names[0].location);
}

test "parseElementName: rejects a name that is not an identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for 5 in items: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseElementName: parses a pointer name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for *card in cards: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const loop = module.declarations[0].kind.function_definition.body[0].kind.@"for";
    try std.testing.expectEqualStrings("card", loop.names[0].name);
    try std.testing.expect(loop.names[0].pointer);
    try std.testing.expect(!loop.tuple);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, loop.names[0].location);
}

test "parseElementName: rejects a pointer to an underscore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for *_ in cards: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseSequence: parses ranges with and without an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    for index in 0..: step()\n    for index in 1..limit: step()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for item in (items): step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const sequence = module.declarations[0].kind.function_definition.body[0].kind.@"for".sequence;
    try std.testing.expectEqualStrings("items", sequence.value.kind.identifier.name);
}

test "parseSequence: parses a range whose start is in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for index in (start)..end: step()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): for item in: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, parser.failure.?.location.?);
}

test "parseMatch: parses branches with several cases, value names and an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case number(*digits): step()\n        case name, end:\n            stop()\n        case Token::other(_): noop\n        else: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    const match = statement.kind.match;
    try std.testing.expectEqualStrings("token", match.value.kind.identifier.name);
    try std.testing.expectEqual(4, match.branches.len);
    try std.testing.expectEqual(4, match.names.len);
    try std.testing.expectEqualStrings("number", match.branches[0].cases[0].pattern.kind.identifier.name);
    try std.testing.expectEqual(.payload, match.branches[0].naming);
    try std.testing.expectEqualStrings("digits", match.names[0].name);
    try std.testing.expect(match.names[0].pointer);
    try std.testing.expectEqual(2, match.branches[1].cases.len);
    try std.testing.expectEqualStrings("end", match.branches[1].cases[1].pattern.kind.identifier.name);
    try std.testing.expectEqual(.none, match.branches[1].naming);
    try std.testing.expectEqualStrings("stop", match.branches[1].body[0].kind.call.kind.call.callee.identifier.name);
    const path = match.branches[2].cases[0].pattern.kind.path_expression.path;
    try std.testing.expectEqualStrings("Token", path[0]);
    try std.testing.expectEqualStrings("other", path[1]);
    try std.testing.expectEqual(.payload, match.branches[2].naming);
    try std.testing.expectEqualStrings("_", match.names[2].name);
    try std.testing.expectEqual(0, match.branches[3].cases.len);
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 9 }, match.branches[3].location);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, statement.location);
}

test "parseMatch: rejects a match without a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match value\n    noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, parser.failure.?.location.?);
}

test "parseMatch: rejects a branch after else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        else: noop\n        case end: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ElseNotLast, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 9 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a value name in a branch with several cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case name, end(value): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 23 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a case after a value name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case number(value), end: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 27 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a name after as in a branch with several cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case null, Card as card: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.NamedCases, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 25 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a branch without a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case : noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedBranch, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 14 }, parser.failure.?.location.?);
}

test "parseBranch: rejects a branch without the case keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        end: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCaseOrElse, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, parser.failure.?.location.?);
}

test "parseBranchCase: parses a type with a value name, null, values and ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case *Card as *card: noop\n        case null: noop\n        case -1, 3..10: noop\n        case 20..: noop\n        case Box(i32) as box: noop");
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

test "parseValueName: rejects a discarded name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    match token:\n        case Card as _: noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.DiscardedValueName, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 22 }, parser.failure.?.location.?);
}

test "parseLabel: rejects a label before a statement that is not a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "matchElse: leaves an else at the indentation of an enclosing statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    while running:\n        if ready: step()\n    else: stop()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): if ready: step()\nelse: stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.UnexpectedToken, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseElseBlock: rejects an else without a colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    if ready: step()\n    else stop()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedColon, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, parser.failure.?.location.?);
}

test "isColonLabel: rejects a label written with a colon before a while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    outer: while running: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "isColonLabel: rejects a label written with a colon before a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    outer: for item in items: step()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseJump: parses break and continue with and without a label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer while running:\n        break\n        break @outer\n        continue\n        continue @outer");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer while running: break outer");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 33 }, parser.failure.?.location.?);
}

test "parseJump: rejects an at sign without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    @outer while running: continue @");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 37 }, parser.failure.?.location.?);
}

test "parseDefer: parses defer and errdefer before a call, an assignment and a discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    defer close()\n    errdefer count += 1\n    defer _ = value");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): defer return");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedDeferredStatement, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
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

test "parseDiscard: parses a discarded tried call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = try parse()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("parse", discarded.kind.@"try".kind.call.callee.identifier.name);
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

test "parseDiscard: parses a discarded operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = count + 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(ast.BinaryOperator.add, discarded.kind.binary.operator);
}

test "parseDiscard: parses a discarded field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = make().x");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const discarded = module.declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqualStrings("x", discarded.kind.field_access.field);
}

test "parseDiscard: rejects a missing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ =");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, parser.failure.?.location.?);
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

test "parseVariableDeclaration: rejects names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): var (name, score) = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
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

test "parseAssignment: parses each compound assignment operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    a += 1\n    a -= 1\n    a *= 1\n    a /= 1\n    a %= 1\n    a &= 1\n    a |= 1\n    a ^= 1\n    a <<= 1\n    a >>= 1\n");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): make() += 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTarget, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, parser.failure.?.location.?);
}

test "parseStatement: rejects a reserved word as the name of a local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const match = 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 11 }, parser.failure.?.location.?);
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

test "parseCallStatement: parses a tried call as a statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): try save()");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const statement = module.declarations[0].kind.function_definition.body[0];
    try std.testing.expectEqualStrings("save", statement.kind.call.kind.@"try".kind.call.callee.identifier.name);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, statement.location);
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

test "parseTupleDeclaration: parses names in parentheses and a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const (name, *score) = pair\n    step()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): const (name, score): [i32, bool] = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedEquals, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, parser.failure.?.location.?);
}

test "parseTupleDeclaration: rejects names in parentheses inside names in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): const (name, (score, rank)) = pair");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("const (name, score) = pair");
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
    var lexer = @import("lexer.zig").Lexer.init("const Data = struct:\n    value: i32");
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
    var lexer = @import("lexer.zig").Lexer.init("const write =\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseStructDefinition: parses fields in an indented block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: i32\n    y: f64");
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

test "parseStructDefinition: accepts a reserved word as the name of a struct and of an enum and an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct match:\n    value: i32\nenum case:\n    first\nerror for:\n    second");
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
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    match: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedField, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseEnumDefinition: rejects a reserved word as the name of a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Token:\n    match");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedCase, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseStructDefinition: parses a struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Marker\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expectEqual(0, module.declarations[0].kind.struct_definition.fields.len);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseStructDefinition: parses an external struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external struct Point:\n    x: i32\nstruct Line:\n    start: Point");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const point = module.declarations[0].kind.struct_definition;
    try std.testing.expect(point.external);
    try std.testing.expectEqualStrings("Point", point.name);
    try std.testing.expectEqual(1, point.fields.len);
    try std.testing.expect(!module.declarations[1].kind.struct_definition.external);
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

test "parseEnumDefinition: parses cases with and without values and the functions of the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("enum Token:\n    number: i64\n    word: bool\n    end\n    fn is_end(self: Self) -> bool: return self == Token::end\n");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const definition = module.declarations[0].kind.enum_definition;
    try std.testing.expectEqual(3, definition.cases.len);
    try std.testing.expectEqualStrings("number", definition.cases[0].name);
    try std.testing.expectEqualStrings("i64", definition.cases[0].type.?.kind.identifier.name);
    try std.testing.expectEqual(null, definition.cases[2].type);
    const function = module.declarations[1].kind.function_definition;
    try std.testing.expectEqualStrings("is_end", function.signature.name);
    try std.testing.expectEqual(ast.SelfParameter.value, function.signature.self_parameter);
}

test "parseEnumDefinition: parses an error set with and without cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("error ParseError:\n    missing_end\n    unexpected: [usize, usize]\nerror Never");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const set = module.declarations[0].kind.enum_definition;
    try std.testing.expectEqual(types.EnumKind.error_set, set.kind);
    try std.testing.expectEqualStrings("unexpected", set.cases[1].name);
    try std.testing.expect(set.cases[1].type != null);
    const never = module.declarations[1].kind.enum_definition;
    try std.testing.expectEqual(types.EnumKind.error_set, never.kind);
    try std.testing.expectEqual(0, never.cases.len);
}

test "parseEnumDefinition: rejects a function in an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("error ParseError:\n    missing_end\n    fn show(): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("struct Card:\n    question: []Const(u8)\n\n    fn show(self: Self) -> []Const(u8): return self.question");
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

test "parseMembers: parses a field after a method with an indented body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("struct Card:\n    fn show(self: Self) -> []Const(u8):\n        return self.question\n    question: []Const(u8)\nfn main(): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("struct Point:\n    x: i32 = 0\n    y: i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const fields = module.declarations[0].kind.struct_definition.fields;
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

test "parseTypeclassDefinition: parses the functions of a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T):\n    fn area(self: T) -> i32\n    fn grow(self: T, amount: i32) -> i32");
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

test "parseTypeclassDefinition: parses the parameter of a typeclass and the receivers of its methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T):\n    fn area(shape: T) -> i32\n    fn grow(shape: *T)\n    fn read(shape: *Const(T)) -> i32\n    fn make(side: i32) -> T");
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

test "parseTypeclassDefinition: rejects a typeclass without parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape:\n    fn area(shape: Shape) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedLeftParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parseTypeclassDefinition: rejects a parameter that is not a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(T):\n    fn area(shape: T) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedTypeParameter, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parseTypeclassDefinition: parses several parameters and type constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Map(type K, type F(type, type), type V):\n    fn get(map: K) -> V");
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
    var lexer = @import("lexer.zig").Lexer.init("typeclass Ord(type T: Eq):\n    fn less(one: T, two: T) -> bool");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.typeclass_definition.parameters[0];
    try std.testing.expectEqualStrings("Eq", parameter.requirement.?.kind.identifier.name);
}

test "parseTypeclassDefinition: parses a function that is not a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T):\n    fn new() -> T");
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
    var lexer = @import("lexer.zig").Lexer.init("typeclass Shape(type T):\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32:\n        return self.area() * 2");
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
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T):\n    fn show(value: T) -> i32\n    inline fn twice(value: T) -> i32: return 2");
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
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T):\n    inline fn show(value: T) -> i32");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.InlineSignature, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, parser.failure.?.location.?);
}

test "parseInstance: lists the functions of an instance as declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance Shape([]Const(u8)):\n    fn area(self: []Const(u8)) -> i32: return 0");
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
    var lexer = @import("lexer.zig").Lexer.init("typeclass Show(type T):\n    fn show(value: T) -> i32\ninstance Show(i32):\n    inline fn show(value: i32) -> i32: return value");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    try std.testing.expect(module.declarations[2].kind.function_definition.signature.@"inline");
}

test "parseInstance: parses the typeclass and the type in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance shapes::Shape([]Const(u8))");
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
    var lexer = @import("lexer.zig").Lexer.init("instance(type A: Show, type B) Pair(List(A), B)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const instance_declaration = module.declarations[0].kind.instance_declaration;
    try std.testing.expectEqual(2, instance_declaration.parameters.len);
    try std.testing.expectEqualStrings("Show", instance_declaration.parameters[0].requirement.?.kind.identifier.name);
    try std.testing.expectEqual(null, instance_declaration.parameters[1].requirement);
    try std.testing.expectEqual(2, instance_declaration.arguments.len);
    try std.testing.expect(instance_declaration.arguments[0].kind == .call);
}

test "parseInstance: rejects a type without parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("instance Shape Square:");
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

test "parseImport: binds the name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::io::stdout as out\nimport mn as library");
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
    var lexer = @import("lexer.zig").Lexer.init("import mn::io::stdout as\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, parser.failure.?.location.?);
}

test "parseImport: rejects a reserved word as the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("import mn::io::stdout as as");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
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

test "parseExpression: ends a range after the operations on its bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    for index in 0..count + 1: step(index)\n    const range = (0..3)\n    take(range)");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const value = (0..3) + 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, parser.failure.?.location.?);
}

test "parseBinary: rejects a range as the right operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const value = 1 + (0..3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 23 }, parser.failure.?.location.?);
}

test "parsePrefix: rejects a range as the operand of a unary operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const value = !(0..3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, parser.failure.?.location.?);
}

test "parsePostfix: rejects a field of a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const value = (0..3).start");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.RangeOperand, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("fn greeting() -> []Const(u8): return \"hello\"");
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
    const element = arguments[1].value.kind.composite_literal.elements[0].value;
    try std.testing.expectEqual(ast.BinaryOperator.multiply, element.kind.binary.operator);
}

test "parseExpression: parses a range outside a for as a whole expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const range = 1 + 2..count\n    const open = start..\n    noop");
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

test "parseOrElse: takes a return as the fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a orelse return 1");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.BinaryOperator.@"orelse", value.kind.binary.operator);
    const fallback = value.kind.binary.right.kind.jump;
    try std.testing.expectEqualStrings("1", fallback.kind.@"return".?.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, fallback.location);
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

test "parseOrElse: parses catch at the level of orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a | b catch c orelse d");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a orelse b orelse c");
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

test "parseTry: binds try to its operand before a binary operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return try first() + try second()");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f() -> i32: return a orelse return b orelse c");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f(): g(a orelse return)");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f():\n    const a = b orelse break @outer\n    const c = d orelse continue");
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
    var lexer = @import("lexer.zig").Lexer.init("fn f(): const a = b orelse break outer");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.LabelWithoutSigil, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, parser.failure.?.location.?);
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

test "parseStructType: parses the fields and functions of a struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn List(type T) -> type:\n    return struct:\n        first: T\n        fn get(self: Self) -> T: return self.first\n    noop");
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
    try std.testing.expectEqualStrings("2", literal.elements[1].value.kind.integer_literal.text);
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
    var lexer = @import("lexer.zig").Lexer.init("const pair = [i32, bool]{1, true}");
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
    var lexer = @import("lexer.zig").Lexer.init("const single = [i32]{1}");
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

test "parseCompositeLiteral: parses named values after a struct type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data: return Data{two = 2, one = 1}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const literal = value.kind.composite_literal;
    try std.testing.expectEqualStrings("Data", literal.type.?.kind.identifier.name);
    try std.testing.expectEqualStrings("two", literal.elements[0].name.?);
    try std.testing.expectEqualStrings("2", literal.elements[0].value.kind.integer_literal.text);
    try std.testing.expectEqualStrings("one", literal.elements[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 41 }, literal.elements[1].location);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, value.location);
}

test "parseCompositeLiteral: parses named values without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data: return {one = 1, two = 2}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const value = module.declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const literal = value.kind.composite_literal;
    try std.testing.expectEqual(null, literal.type);
    try std.testing.expectEqualStrings("one", literal.elements[0].name.?);
    try std.testing.expectEqualStrings("two", literal.elements[1].name.?);
    try std.testing.expectEqualStrings("2", literal.elements[1].value.kind.integer_literal.text);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, value.location);
}

test "parseCompositeLiteral: parses named values over several lines with a trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("const data: Data = Data{\n    one = 0,\n    two = 0,\n}\nfn main(): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const literal = module.declarations[0].kind.constant_declaration.value.kind.composite_literal;
    try std.testing.expectEqual(2, literal.elements.len);
    try std.testing.expectEqualStrings("two", literal.elements[1].name.?);
    try std.testing.expect(module.declarations[1].kind == .function_definition);
}

test "parseCompositeLiteral: rejects an unnamed value after a named value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data: return Data{one = 1, 2}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MixedNamedValues, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 41 }, parser.failure.?.location.?);
}

test "parseCompositeLiteral: rejects a named value after an unnamed value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn make() -> Data: return {1, two = 2}");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MixedNamedValues, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool] value: i32): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []Const(u8)): noop");
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

test "parseBrackets: parses a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool]): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: [i32, bool,]): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const parameter = module.declarations[0].kind.function_definition.signature.parameters[0];
    try std.testing.expectEqual(2, parameter.type.kind.tuple_type.elements.len);
}

test "parseBrackets: parses one type in brackets as a tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: [i32]): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: []): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [count]i32): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: [4,]i32): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects const after empty brackets and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []const u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstSliceSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects Many after empty brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []Many(u8)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, parser.failure.?.location.?);
}

test "parseBrackets: rejects Const inside the Const of a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: []Const(Const(u8))): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.MisplacedConst, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects const after an asterisk and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(card: *const Card): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects many after an asterisk and names the new form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *many u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ManyPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects many const after an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *many const u8): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ManyPointerSyntax, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: rejects Const around Many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(bytes: *Const(Many(u8))): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ConstOutsideMany, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
}

test "parsePointerType: reads many as the name of a target type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: *many): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const pointer_type = module.declarations[0].kind.function_definition.signature.parameters[0].type.kind.pointer_type;
    try std.testing.expect(!pointer_type.many);
    try std.testing.expectEqualStrings("many", pointer_type.target.kind.identifier.name);
}

test "parsePointerType: parses Many and Const after an asterisk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(a: *Many(Const(u8)), b: *Const(Card), c: *Many(i32), d: ?*Many(u8)): noop");
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

test "parseParentheses: rejects a comma between types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(pair: (i32, bool)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, parser.failure.?.location.?);
}

test "parseParentheses: rejects a comma after one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: (i32,)): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedRightParenthesis, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, parser.failure.?.location.?);
}

test "parseParentheses: rejects empty parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: ()): noop");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(values: *Many(Const(i32))): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn show(value: **Const(u8)): noop");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): mn::stdout::write(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const expression = module.declarations[0].kind.function_definition.body[0].kind.call;
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, expression.location);
    const call = expression.kind.call;
    const path = call.callee.path_expression.path;
    try std.testing.expectEqual(3, path.len);
    try std.testing.expectEqualStrings("mn", path[0]);
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

test "parsePathStart: parses a path that starts with the separator as a path from the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): ::match(::Point::new())");
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

test "parsePathStart: rejects a separator without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): ::(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedIdentifier, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, parser.failure.?.location.?);
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): mn::comptime::error(\"stop\")");
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(Point{x = 1, y = 2}, 3)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const outer = module.declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(null, outer.arguments[1].name);
    const inner = outer.arguments[0].value.kind.composite_literal;
    try std.testing.expectEqualStrings("x", inner.elements[0].name.?);
    try std.testing.expectEqualStrings("1", inner.elements[0].value.kind.integer_literal.text);
    try std.testing.expectEqualStrings("y", inner.elements[1].name.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, inner.elements[1].location);
}

test "parseArgument: rejects a name without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(Point{x = })");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);

    try std.testing.expectError(error.ExpectedExpression, parser.parse(&arena));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, parser.failure.?.location.?);
}

test "parseMemberCall: parses a call to a function of a type that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = List(i32)::new(1)");
    try lexer.lex(&arena);
    var parser = Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);

    const call = module.declarations[0].kind.function_definition.body[0].kind.discard.kind.call;
    const member = call.callee.member;
    try std.testing.expectEqualStrings("new", member.name);
    try std.testing.expectEqualStrings("List", member.owner.kind.call.callee.identifier.name);
    try std.testing.expectEqual(1, call.arguments.len);
}

test "parseMemberCall: parses a literal of a type that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main():\n    const list = List(i32){first = 1}\n    _ = list");
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
