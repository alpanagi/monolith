const std = @import("std");
const core = @import("core");

const Failure = core.Failure;

const default_source_directory = "source";
const default_test_directory = "tests";

pub fn parseCommand(arguments: []const [:0]const u8) ?Command {
    if (arguments.len < 2) return null;
    if (std.mem.eql(u8, arguments[1], "build")) return parseBuild(arguments[2..]);
    if (std.mem.eql(u8, arguments[1], "test")) return parseTest(arguments[2..]);
    return null;
}

pub const Command = union(enum) {
    build: Build,
    @"test": Test,
};

pub const Build = struct {
    path: []const u8,
    module_name: []const u8,
    output: ?[]const u8 = null,
};

pub const Test = struct {
    source_directory: []const u8,
    test_directory: []const u8,
    is_test_directory_optional: bool,
};

pub const TestRunner = struct {
    failure: ?Failure = null,

    pub fn run(self: *TestRunner, allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8) RunError!u8 {
        var child = std.process.spawn(io, .{ .argv = &.{executable_path} }) catch |spawn_error| {
            const message = try std.fmt.allocPrint(allocator, "cannot run '{s}': {t}", .{ executable_path, spawn_error });
            self.failure = .{ .message = message };
            return spawn_error;
        };
        const term = try child.wait(io);
        if (term == .exited) return term.exited;
        if (term == .signal) {
            self.failure = .{ .message = try std.fmt.allocPrint(allocator, "'{s}' was ended by a signal", .{executable_path}) };
        } else {
            self.failure = .{ .message = try std.fmt.allocPrint(allocator, "'{s}' ended without an exit status", .{executable_path}) };
        }
        return error.EndedWithoutStatus;
    }
};

pub const RunError = std.mem.Allocator.Error ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    error{EndedWithoutStatus};

fn parseBuild(arguments: []const [:0]const u8) ?Command {
    if (arguments.len == 0) return null;
    const output = parseOption(arguments[1..], "--output") orelse return null;
    const module_name = findModuleName(arguments[0]) orelse return null;
    return .{ .build = .{ .path = arguments[0], .module_name = module_name, .output = output.value } };
}

fn parseTest(arguments: []const [:0]const u8) ?Command {
    const has_directory = arguments.len > 0 and !std.mem.startsWith(u8, arguments[0], "-");
    const directory: ?[]const u8 = if (has_directory) arguments[0] else null;
    const source = parseOption(arguments[@intFromBool(has_directory)..], "--source") orelse return null;
    return .{ .@"test" = .{
        .source_directory = source.value orelse directory orelse default_source_directory,
        .test_directory = directory orelse default_test_directory,
        .is_test_directory_optional = directory == null,
    } };
}

fn parseOption(arguments: []const [:0]const u8, name: []const u8) ?Option {
    if (arguments.len == 0) return .{};
    if (arguments.len != 2 or !std.mem.eql(u8, arguments[0], name)) return null;
    return .{ .value = arguments[1] };
}

const Option = struct {
    value: ?[]const u8 = null,
};

fn findModuleName(path: []const u8) ?[]const u8 {
    const file_name = std.fs.path.basename(path);
    const source_extension = ".mn";
    const has_extension = std.mem.endsWith(u8, file_name, source_extension);
    if (!has_extension or file_name.len == source_extension.len) return null;
    return file_name[0 .. file_name.len - source_extension.len];
}

test "parseCommand: builds the file it names into the module it names" {
    const command = parseCommand(&.{ "monolith", "build", "programs/hello.mn" }).?;

    try std.testing.expectEqualStrings("programs/hello.mn", command.build.path);
    try std.testing.expectEqualStrings("hello", command.build.module_name);
    try std.testing.expectEqual(null, command.build.output);
}

test "parseCommand: builds the file it names into the executable after --output" {
    const command = parseCommand(&.{ "monolith", "build", "hello.mn", "--output", "bin/greeter" }).?;

    try std.testing.expectEqualStrings("hello.mn", command.build.path);
    try std.testing.expectEqualStrings("bin/greeter", command.build.output.?);
}

test "parseCommand: rejects a build of a file that is not a source file" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build", "hello.txt" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build", ".mn" }));
}

test "parseCommand: tests the source directory and the tests directory beside it without arguments" {
    const command = parseCommand(&.{ "monolith", "test" }).?;

    try std.testing.expectEqualStrings("source", command.@"test".source_directory);
    try std.testing.expectEqualStrings("tests", command.@"test".test_directory);
    try std.testing.expect(command.@"test".is_test_directory_optional);
}

test "parseCommand: tests the directory it names against the source directory after --source" {
    const command = parseCommand(&.{ "monolith", "test", "checks/unit", "--source", "program" }).?;

    try std.testing.expectEqualStrings("program", command.@"test".source_directory);
    try std.testing.expectEqualStrings("checks/unit", command.@"test".test_directory);
    try std.testing.expect(!command.@"test".is_test_directory_optional);
}

test "parseCommand: tests the directory it names as its own source directory" {
    const command = parseCommand(&.{ "monolith", "test", "tests" }).?;

    try std.testing.expectEqualStrings("tests", command.@"test".source_directory);
    try std.testing.expectEqualStrings("tests", command.@"test".test_directory);
    try std.testing.expect(!command.@"test".is_test_directory_optional);
}

test "parseCommand: tests the source directory after --source and the tests directory" {
    const command = parseCommand(&.{ "monolith", "test", "--source", "program" }).?;

    try std.testing.expectEqualStrings("program", command.@"test".source_directory);
    try std.testing.expectEqualStrings("tests", command.@"test".test_directory);
    try std.testing.expect(command.@"test".is_test_directory_optional);
}

test "parseCommand: rejects --output on a test" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "--output", "bin/tests" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "--output", "bin/tests" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "--output" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "--source", "source", "--output", "bin/tests" }));
}

test "parseCommand: rejects a file without a command" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "hello.mn" }));
}

test "parseCommand: rejects a build without its argument" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build" }));
    try std.testing.expectEqual(null, parseCommand(&.{"monolith"}));
}

test "parseCommand: rejects an unknown command" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "run", "hello.mn" }));
}

test "parseCommand: rejects an option without its value and anything else after the arguments" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build", "hello.mn", "--output" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "--source" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "-s", "source" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "--source", "one", "--source", "two" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "source" }));
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
