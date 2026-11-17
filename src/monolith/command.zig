const std = @import("std");
const core = @import("core");

const Failure = core.Failure;

const default_source_directory = "source";
const default_test_directory = "tests";
const main_file = "main.mn";
const main_source = "fn main = noop\n";
const source_extension = ".mn";
const library_option = "--library";
const output_option = "--output";
const source_option = "--source";

pub fn parseCommand(allocator: std.mem.Allocator, arguments: []const [:0]const u8) std.mem.Allocator.Error!?Command {
    if (arguments.len < 2) return null;
    if (std.mem.eql(u8, arguments[1], "init")) return parseInit(arguments[2..]);
    if (std.mem.eql(u8, arguments[1], "build")) return parseBuild(allocator, arguments[2..]);
    if (std.mem.eql(u8, arguments[1], "test")) return parseTest(allocator, arguments[2..]);
    return null;
}

pub fn findModuleName(path: []const u8) ?[]const u8 {
    const file_name = std.fs.path.basename(path);
    const has_extension = std.mem.endsWith(u8, file_name, source_extension);
    if (!has_extension or file_name.len == source_extension.len) return null;
    return file_name[0 .. file_name.len - source_extension.len];
}

pub const Command = union(enum) {
    init: void,
    build: Build,
    build_script: BuildScript,
    @"test": Test,
    test_script: Test,
};

pub const Build = struct {
    path: []const u8,
    module_name: []const u8,
    output: ?[]const u8 = null,
    libraries: []const []const u8 = &.{},
};

pub const BuildScript = struct {
    command_name: ?[]const u8 = null,
};

pub const Test = struct {
    source_directory: []const u8,
    test_directory: []const u8,
    is_test_directory_optional: bool,
    libraries: []const []const u8 = &.{},
};

pub const ProjectInitializer = struct {
    failure: ?Failure = null,

    pub fn initialize(self: *ProjectInitializer, allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) InitializeError!void {
        directory.createDir(io, default_source_directory, .default_dir) catch |create_error| {
            if (create_error == error.PathAlreadyExists) {
                self.failure = .{ .message = "'" ++ default_source_directory ++ "' already exists" };
                return create_error;
            }
            const message = try std.fmt.allocPrint(allocator, "cannot create '{s}': {t}", .{ default_source_directory, create_error });
            self.failure = .{ .message = message };
            return create_error;
        };
        const path = default_source_directory ++ std.fs.path.sep_str ++ main_file;
        directory.writeFile(io, .{ .sub_path = path, .data = main_source }) catch |write_error| {
            const message = try std.fmt.allocPrint(allocator, "cannot write '{s}': {t}", .{ path, write_error });
            self.failure = .{ .message = message };
            return write_error;
        };
    }
};

pub const InitializeError = std.mem.Allocator.Error ||
    std.Io.Dir.CreateDirError ||
    std.Io.Dir.WriteFileError;

pub const TestRunner = struct {
    failure: ?Failure = null,

    pub fn run(self: *TestRunner, allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8) RunError!u8 {
        var child = std.process.spawn(io, .{ .argv = &.{executable_path} }) catch |spawn_error| {
            const message = try std.fmt.allocPrint(allocator, "cannot run '{s}': {t}", .{ executable_path, spawn_error });
            self.failure = .{ .message = message };
            return spawn_error;
        };
        return waitForStatus(allocator, io, &child, executable_path, &self.failure);
    }
};

pub const RunError = std.mem.Allocator.Error ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    error{EndedWithoutStatus};

pub const CommandRunner = struct {
    failure: ?Failure = null,

    pub fn run(
        self: *CommandRunner,
        allocator: std.mem.Allocator,
        io: std.Io,
        directory_path: []const u8,
        arguments: []const []const u8,
    ) (RunError || std.Io.Dir.OpenError)!u8 {
        var child = spawnInDirectory(io, directory_path, arguments) catch |spawn_error| {
            const message = try std.fmt.allocPrint(allocator, "cannot run '{s}': {t}", .{ arguments[0], spawn_error });
            self.failure = .{ .message = message };
            return spawn_error;
        };
        return waitForStatus(allocator, io, &child, arguments[0], &self.failure);
    }
};

fn spawnInDirectory(
    io: std.Io,
    directory_path: []const u8,
    arguments: []const []const u8,
) (std.process.SpawnError || std.Io.Dir.OpenError)!std.process.Child {
    if (directory_path.len == 0) return std.process.spawn(io, .{ .argv = arguments });
    const directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{});
    defer directory.close(io);
    return std.process.spawn(io, .{ .argv = arguments, .cwd = .{ .dir = directory } });
}

fn waitForStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    name: []const u8,
    failure: *?Failure,
) RunError!u8 {
    const term = try child.wait(io);
    if (term == .exited) return term.exited;
    if (term == .signal) {
        failure.* = .{ .message = try std.fmt.allocPrint(allocator, "'{s}' was ended by a signal", .{name}) };
    } else {
        failure.* = .{ .message = try std.fmt.allocPrint(allocator, "'{s}' ended without an exit status", .{name}) };
    }
    return error.EndedWithoutStatus;
}

fn parseInit(arguments: []const [:0]const u8) ?Command {
    if (arguments.len != 0) return null;
    return .init;
}

fn parseBuild(allocator: std.mem.Allocator, arguments: []const [:0]const u8) std.mem.Allocator.Error!?Command {
    if (arguments.len == 0) return .{ .build_script = .{} };
    if (isOption(arguments[0])) return null;
    if (!std.mem.endsWith(u8, arguments[0], source_extension)) {
        if (arguments.len != 1) return null;
        return .{ .build_script = .{ .command_name = arguments[0] } };
    }
    const module_name = findModuleName(arguments[0]) orelse return null;
    const options = try parseOptions(allocator, arguments[1..], output_option) orelse return null;
    return .{ .build = .{
        .path = arguments[0],
        .module_name = module_name,
        .output = options.value,
        .libraries = options.libraries,
    } };
}

fn parseTest(allocator: std.mem.Allocator, arguments: []const [:0]const u8) std.mem.Allocator.Error!?Command {
    const has_directory = arguments.len > 0 and !isOption(arguments[0]);
    const directory: ?[]const u8 = if (has_directory) arguments[0] else null;
    const options = try parseOptions(allocator, arguments[@intFromBool(has_directory)..], source_option) orelse return null;
    const tests: Test = .{
        .source_directory = options.value orelse directory orelse default_source_directory,
        .test_directory = directory orelse default_test_directory,
        .is_test_directory_optional = directory == null,
        .libraries = options.libraries,
    };
    if (arguments.len == 0) return .{ .test_script = tests };
    return .{ .@"test" = tests };
}

fn isOption(argument: []const u8) bool {
    return std.mem.startsWith(u8, argument, "-");
}

fn parseOptions(
    allocator: std.mem.Allocator,
    arguments: []const [:0]const u8,
    value_name: []const u8,
) std.mem.Allocator.Error!?Options {
    if (arguments.len % 2 != 0) return null;
    var value: ?[]const u8 = null;
    var library_count: usize = 0;
    var index: usize = 0;
    while (index < arguments.len) : (index += 2) {
        if (std.mem.eql(u8, arguments[index], library_option)) {
            library_count += 1;
        } else if (std.mem.eql(u8, arguments[index], value_name) and value == null) {
            value = arguments[index + 1];
        } else {
            return null;
        }
    }
    const libraries = try allocator.alloc([]const u8, library_count);
    var library_index: usize = 0;
    index = 0;
    while (index < arguments.len) : (index += 2) {
        if (!std.mem.eql(u8, arguments[index], library_option)) continue;
        libraries[library_index] = arguments[index + 1];
        library_index += 1;
    }
    return .{ .value = value, .libraries = libraries };
}

const Options = struct {
    value: ?[]const u8,
    libraries: []const []const u8,
};

test "parseCommand: initializes a project without arguments" {
    try std.testing.expectEqual(.init, (try parseCommand(std.testing.allocator, &.{ "monolith", "init" })).?);
}

test "parseCommand: rejects anything after init" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "init", "project" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "init", "--source", "program" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "init", "" }));
}

test "parseCommand: builds the file it names into the module it names" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "build", "programs/hello.mn" })).?;

    try std.testing.expectEqualStrings("programs/hello.mn", command.build.path);
    try std.testing.expectEqualStrings("hello", command.build.module_name);
    try std.testing.expectEqual(null, command.build.output);
    try std.testing.expectEqual(0, command.build.libraries.len);
}

test "parseCommand: builds the file it names into the executable after --output" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "build", "hello.mn", "--output", "bin/greeter" })).?;

    try std.testing.expectEqualStrings("hello.mn", command.build.path);
    try std.testing.expectEqualStrings("bin/greeter", command.build.output.?);
}

test "parseCommand: links the library after each --library in the order given, among the other options in any order" {
    const allocator = std.testing.allocator;
    const build = (try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--library", "SDL3", "--output", "bin/greeter", "--library", "vulkan" })).?;
    defer allocator.free(build.build.libraries);
    const tests = (try parseCommand(allocator, &.{ "monolith", "test", "checks", "--library", "m", "--source", "program", "--library", "m" })).?;
    defer allocator.free(tests.@"test".libraries);
    const source_tests = (try parseCommand(allocator, &.{ "monolith", "test", "--library", "m" })).?;
    defer allocator.free(source_tests.@"test".libraries);

    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "SDL3", "vulkan" }), build.build.libraries);
    try std.testing.expectEqualStrings("bin/greeter", build.build.output.?);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "m", "m" }), tests.@"test".libraries);
    try std.testing.expectEqualStrings("program", tests.@"test".source_directory);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"m"}), source_tests.@"test".libraries);
    try std.testing.expectEqualStrings("source", source_tests.@"test".source_directory);
}

test "parseCommand: rejects a build of a source file without a name" {
    try std.testing.expectEqual(null, try parseCommand(std.testing.allocator, &.{ "monolith", "build", ".mn" }));
    try std.testing.expectEqual(null, try parseCommand(std.testing.allocator, &.{ "monolith", "build", "programs/.mn" }));
}

test "parseCommand: builds through build.mn without arguments" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "build" })).?;

    try std.testing.expectEqual(null, command.build_script.command_name);
}

test "parseCommand: runs the command of build.mn named by an argument that does not end in .mn" {
    const shaders = (try parseCommand(std.testing.allocator, &.{ "monolith", "build", "shaders" })).?;
    const text = (try parseCommand(std.testing.allocator, &.{ "monolith", "build", "hello.txt" })).?;

    try std.testing.expectEqualStrings("shaders", shaders.build_script.command_name.?);
    try std.testing.expectEqualStrings("hello.txt", text.build_script.command_name.?);
}

test "parseCommand: rejects anything after the name of a command and an option in place of the file" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "shaders", "--output", "bin/shaders" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "shaders", "--library", "m" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "shaders", "extra" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "--output", "bin/hello" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "--library", "m" }));
}

test "parseCommand: tests the source directory and the tests directory beside it, or through build.mn, without arguments" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "test" })).?;

    try std.testing.expectEqualStrings("source", command.test_script.source_directory);
    try std.testing.expectEqualStrings("tests", command.test_script.test_directory);
    try std.testing.expect(command.test_script.is_test_directory_optional);
}

test "parseCommand: tests the directory it names against the source directory after --source" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "test", "checks/unit", "--source", "program" })).?;

    try std.testing.expectEqualStrings("program", command.@"test".source_directory);
    try std.testing.expectEqualStrings("checks/unit", command.@"test".test_directory);
    try std.testing.expect(!command.@"test".is_test_directory_optional);
}

test "parseCommand: tests the directory it names as its own source directory" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "test", "tests" })).?;

    try std.testing.expectEqualStrings("tests", command.@"test".source_directory);
    try std.testing.expectEqualStrings("tests", command.@"test".test_directory);
    try std.testing.expect(!command.@"test".is_test_directory_optional);
}

test "parseCommand: tests the source directory after --source and the tests directory" {
    const command = (try parseCommand(std.testing.allocator, &.{ "monolith", "test", "--source", "program" })).?;

    try std.testing.expectEqualStrings("program", command.@"test".source_directory);
    try std.testing.expectEqualStrings("tests", command.@"test".test_directory);
    try std.testing.expect(command.@"test".is_test_directory_optional);
}

test "parseCommand: rejects --output on a test" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "--output", "bin/tests" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "--output", "bin/tests" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "--output" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "--source", "source", "--output", "bin/tests" }));
}

test "parseCommand: rejects a file without a command" {
    try std.testing.expectEqual(null, try parseCommand(std.testing.allocator, &.{ "monolith", "hello.mn" }));
}

test "parseCommand: rejects the compiler without a command" {
    try std.testing.expectEqual(null, try parseCommand(std.testing.allocator, &.{"monolith"}));
}

test "parseCommand: rejects an unknown command" {
    try std.testing.expectEqual(null, try parseCommand(std.testing.allocator, &.{ "monolith", "run", "hello.mn" }));
}

test "parseCommand: rejects an option without its value, a repeated option and anything else after the arguments" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--output" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--library" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--library", "m", "--output" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--output", "one", "--output", "two" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "--library", "m", "--source", "source" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "build", "hello.mn", "other.mn" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "--source" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "--library" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "-s", "source" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "--source", "one", "--source", "two" }));
    try std.testing.expectEqual(null, try parseCommand(allocator, &.{ "monolith", "test", "tests", "source" }));
}

test "ProjectInitializer.initialize: creates the source directory holding main.mn with an empty main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    var initializer: ProjectInitializer = .{};

    try initializer.initialize(arena.allocator(), std.testing.io, directory.dir);
    try std.testing.expectEqualStrings("fn main = noop\n", try directory.dir.readFileAlloc(std.testing.io, "source/main.mn", arena.allocator(), .unlimited));
    var walker = try directory.dir.walk(arena.allocator());
    defer walker.deinit();
    const source = (try walker.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("source", source.path);
    try std.testing.expectEqual(.directory, source.kind);
    const main = (try walker.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("source" ++ std.fs.path.sep_str ++ "main.mn", main.path);
    try std.testing.expectEqual(.file, main.kind);
    try std.testing.expectEqual(null, try walker.next(std.testing.io));
}

test "ProjectInitializer.initialize: leaves an existing source directory untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    try directory.dir.createDirPath(std.testing.io, "source");
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "source/main.mn", .data = "fn main = run()\n" });
    var initializer: ProjectInitializer = .{};

    try std.testing.expectError(error.PathAlreadyExists, initializer.initialize(arena.allocator(), std.testing.io, directory.dir));
    try std.testing.expectEqualStrings("'source' already exists", initializer.failure.?.message);
    try std.testing.expectEqualStrings("fn main = run()\n", try directory.dir.readFileAlloc(std.testing.io, "source/main.mn", arena.allocator(), .unlimited));
    var walker = try directory.dir.walk(arena.allocator());
    defer walker.deinit();
    try std.testing.expectEqualStrings("source", (try walker.next(std.testing.io)).?.path);
    try std.testing.expectEqualStrings("source" ++ std.fs.path.sep_str ++ "main.mn", (try walker.next(std.testing.io)).?.path);
    try std.testing.expectEqual(null, try walker.next(std.testing.io));
}

test "ProjectInitializer.initialize: leaves an existing file named source untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = "notes" });
    var initializer: ProjectInitializer = .{};

    try std.testing.expectError(error.PathAlreadyExists, initializer.initialize(arena.allocator(), std.testing.io, directory.dir));
    try std.testing.expectEqualStrings("'source' already exists", initializer.failure.?.message);
    try std.testing.expectEqualStrings("notes", try directory.dir.readFileAlloc(std.testing.io, "source", arena.allocator(), .unlimited));
}

test "TestRunner.run: reports an executable it cannot start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &directory.sub_path, "missing" });
    var runner: TestRunner = .{};

    try std.testing.expectError(error.FileNotFound, runner.run(arena.allocator(), std.testing.io, path));
    const expected = try std.fmt.allocPrint(arena.allocator(), "cannot run '{s}': FileNotFound", .{path});
    try std.testing.expectEqualStrings(expected, runner.failure.?.message);
}

test "TestRunner.run: reports an executable ended by a signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const created = try std.process.run(arena.allocator(), std.testing.io, .{
        .argv = &.{ "sh", "-c", "printf '%s\\n' '#!/bin/sh' 'kill -KILL $$' > ended && chmod +x ended" },
        .cwd = .{ .dir = directory.dir },
    });
    try std.testing.expectEqual(0, created.term.exited);
    const path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &directory.sub_path, "ended" });
    var runner: TestRunner = .{};

    try std.testing.expectError(error.EndedWithoutStatus, runner.run(arena.allocator(), std.testing.io, path));
    const expected = try std.fmt.allocPrint(arena.allocator(), "'{s}' was ended by a signal", .{path});
    try std.testing.expectEqualStrings(expected, runner.failure.?.message);
}

test "CommandRunner.run: runs a command in the directory it is given and passes on its exit status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &directory.sub_path });
    var runner: CommandRunner = .{};

    try std.testing.expectEqual(3, try runner.run(arena.allocator(), std.testing.io, path, &.{ "sh", "-c", "touch ran && exit 3" }));
    try std.testing.expectEqual(.file, (try directory.dir.statFile(std.testing.io, "ran", .{})).kind);
}

test "CommandRunner.run: reports a command it cannot start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &directory.sub_path, "missing" });
    var runner: CommandRunner = .{};

    try std.testing.expectError(error.FileNotFound, runner.run(arena.allocator(), std.testing.io, "", &.{path}));
    const expected = try std.fmt.allocPrint(arena.allocator(), "cannot run '{s}': FileNotFound", .{path});
    try std.testing.expectEqualStrings(expected, runner.failure.?.message);
}
