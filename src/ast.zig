const token = @import("token.zig");

pub const Module = struct {
    functions: []const Function,
};

pub const Function = struct {
    name: []const u8,
    body: []const Statement,
    location: token.Location,
};

pub const Statement = struct {
    kind: StatementKind,
    location: token.Location,
};

pub const StatementKind = union(enum) {
    noop,
};
