pub const Analyzer = @import("analyzer.zig").Analyzer;
pub const CallNote = @import("analyzer.zig").CallNote;
pub const Command = @import("command.zig").Command;
pub const CommandRunner = @import("command.zig").CommandRunner;
pub const Description = @import("description.zig").Description;
pub const Loader = @import("loader.zig").Loader;
pub const NameResolver = @import("name_resolver.zig").NameResolver;
pub const ProjectInitializer = @import("command.zig").ProjectInitializer;
pub const TestRunner = @import("command.zig").TestRunner;
pub const TypeChecker = @import("type_checker.zig").TypeChecker;

pub const findModuleName = @import("command.zig").findModuleName;
pub const isRootModuleName = @import("loader.zig").isRootModuleName;
pub const parseCommand = @import("command.zig").parseCommand;
pub const parseDescription = @import("description.zig").parseDescription;

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
    _ = @import("description.zig");
}
