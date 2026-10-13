const token = @import("token.zig");

pub const Module = struct {
    functions: []Function,
};

pub const Function = struct {
    name: []const u8,
    return_type: Type,
    body: []Statement,
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
};
