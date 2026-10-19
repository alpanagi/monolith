const token = @import("token.zig");
const types = @import("types.zig");

pub const Program = struct {
    modules: []Module,
    types: *const types.Registry,
};

pub const Module = struct {
    path: Path = &.{},
    declarations: []Declaration,
};

pub const Declaration = struct {
    kind: DeclarationKind,
    location: token.Location,
};

pub const DeclarationKind = union(enum) {
    function_declaration: FunctionSignature,
    function_definition: FunctionDefinition,
    constant_declaration: ConstantDeclaration,
};

pub const FunctionDefinition = struct {
    signature: FunctionSignature,
    body: []Statement,
};

pub const FunctionSignature = struct {
    name: []const u8,
    parameters: []TypedName,
    return_type: Expression,
};

pub const Statement = struct {
    kind: StatementKind,
    location: token.Location,
};

pub const StatementKind = union(enum) {
    noop,
    @"return": ?Expression,
    discard: Expression,
    call: Expression,
};

pub const ConstantDeclaration = struct {
    name: []const u8,
    value: Expression,
};

pub const Expression = struct {
    kind: ExpressionKind,
    type: ?types.Type = null,
    location: token.Location,
};

pub const ExpressionKind = union(enum) {
    integer_literal: token.NumberLiteral,
    float_literal: token.NumberLiteral,
    boolean_literal: bool,
    string_literal: []const u8,
    identifier: Identifier,
    path_expression: PathExpression,
    call: Call,
    @"struct": Struct,
};

pub const Call = struct {
    callee: Name,
    arguments: []Expression,
};

pub const Name = union(enum) {
    identifier: Identifier,
    path_expression: PathExpression,
};

pub const Identifier = struct {
    name: []const u8,
    resolution: ?Resolution = null,
};

pub const PathExpression = struct {
    path: Path,
    resolution: ?Resolution = null,
};

pub const Path = []const []const u8;

pub const Resolution = union(enum) {
    parameter: usize,
    function: Resolution.Function,
    type: types.Type,
    constant: Resolution.Constant,

    pub const Function = struct {
        module: usize,
        declaration: usize,
    };

    pub const Constant = struct {
        module: usize,
        declaration: usize,
    };
};

pub const Struct = struct {
    fields: []TypedName,
    value: ?types.Type = null,
};

pub const TypedName = struct {
    name: []const u8,
    type: Expression,
    location: token.Location,
};

pub fn extractType(expression: Expression) types.Type {
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| name.resolution.?.type,
        else => unreachable,
    };
}
