const ast = @import("ast.zig");
const token = @import("token.zig");

pub const Failure = struct {
    module: ?ast.Path = null,
    location: ?token.Location = null,
    message: []const u8,
};
