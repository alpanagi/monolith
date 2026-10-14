const token = @import("token.zig");

pub const Module = struct {
    declarations: []Declaration,
};

pub const Declaration = union(enum) {
    function: Function,
    external_function: FunctionDeclaration,
};

pub const Function = struct {
    declaration: FunctionDeclaration,
    body: []Statement,
};

pub const FunctionDeclaration = struct {
    name: []const u8,
    parameters: []Parameter,
    return_type: Type,
    location: token.Location,
};

pub const Parameter = struct {
    name: []const u8,
    parameter_type: Type,
    location: token.Location,
};

pub const Type = struct {
    primitive_type: token.PrimitiveType,
    location: token.Location,
};

pub const Statement = struct {
    kind: StatementKind,
    location: token.Location,
};

pub const StatementKind = union(enum) {
    noop,
    @"return": ?Expression,
    discard: Expression,
    expression: Expression,
};

pub const Expression = struct {
    kind: ExpressionKind,
    primitive_type: ?token.PrimitiveType = null,
    location: token.Location,
};

pub const ExpressionKind = union(enum) {
    integer: token.NumberLiteral,
    float: token.NumberLiteral,
    boolean: bool,
    string: []const u8,
    identifier: Identifier,
    call: Call,
};

pub const Identifier = struct {
    name: []const u8,
    binding: ?usize = null,
};

pub const Call = struct {
    name: []const u8,
    arguments: []Expression,
    declaration: ?usize = null,
};
