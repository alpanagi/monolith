pub const Loader = @import("loader.zig").Loader;
pub const NameResolver = @import("name_resolver.zig").NameResolver;
pub const TypeChecker = @import("type_checker.zig").TypeChecker;

pub const isName = @import("name.zig").isName;

test {
    _ = @import("name.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("loader.zig");
    _ = @import("name_resolver.zig");
    _ = @import("type_checker.zig");
}
