const std = @import("std");

pub fn parseCommand(arguments: []const [:0]const u8) ?Command {
    if (arguments.len < 3) return null;
    const output = parseOutput(arguments[3..]) orelse return null;
    const operand = arguments[2];
    if (std.mem.eql(u8, arguments[1], "build")) {
        const module_name = findModuleName(operand) orelse return null;
        return .{ .build = .{ .path = operand, .module_name = module_name, .output = output.path } };
    }
    if (std.mem.eql(u8, arguments[1], "test")) return .{ .@"test" = .{ .directory = operand, .output = output.path } };
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
    directory: []const u8,
    output: ?[]const u8 = null,
};

fn parseOutput(arguments: []const [:0]const u8) ?Output {
    if (arguments.len == 0) return .{};
    if (arguments.len != 2 or !std.mem.eql(u8, arguments[0], "--output")) return null;
    return .{ .path = arguments[1] };
}

const Output = struct {
    path: ?[]const u8 = null,
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

test "parseCommand: tests the directory it names" {
    const command = parseCommand(&.{ "monolith", "test", "tests" }).?;

    try std.testing.expectEqualStrings("tests", command.@"test".directory);
    try std.testing.expectEqual(null, command.@"test".output);
}

test "parseCommand: tests the directory it names into the executable after --output" {
    const command = parseCommand(&.{ "monolith", "test", "tests", "--output", "bin/tests" }).?;

    try std.testing.expectEqualStrings("tests", command.@"test".directory);
    try std.testing.expectEqualStrings("bin/tests", command.@"test".output.?);
}

test "parseCommand: rejects a file without a command" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "hello.mn" }));
}

test "parseCommand: rejects a command without its argument" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test" }));
    try std.testing.expectEqual(null, parseCommand(&.{"monolith"}));
}

test "parseCommand: rejects an unknown command" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "run", "hello.mn" }));
}

test "parseCommand: rejects --output without its path and anything else after the argument" {
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "build", "hello.mn", "--output" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "-o", "bin/tests" }));
    try std.testing.expectEqual(null, parseCommand(&.{ "monolith", "test", "tests", "--output", "one", "--output", "two" }));
}
