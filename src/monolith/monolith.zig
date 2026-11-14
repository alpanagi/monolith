pub const Analyzer = @import("analyzer.zig").Analyzer;
pub const CallNote = @import("analyzer.zig").CallNote;
pub const Command = @import("command.zig").Command;
pub const Loader = @import("loader.zig").Loader;
pub const NameResolver = @import("name_resolver.zig").NameResolver;
pub const TypeChecker = @import("type_checker.zig").TypeChecker;

pub const isRootModuleName = @import("loader.zig").isRootModuleName;
pub const parseCommand = @import("command.zig").parseCommand;

test {
    _ = @import("name.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("loader.zig");
    _ = @import("name_resolver.zig");
    _ = @import("type_checker.zig");
    _ = @import("evaluator.zig");
    _ = @import("analyzer.zig");
    _ = @import("command.zig");
}
