const std = @import("std");

pub fn parseDescription(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!?Description {
    var reader: Reader = .{ .bytes = bytes };
    var executables: std.ArrayList(Executable) = .empty;
    var test_suites: std.ArrayList(TestSuite) = .empty;
    var commands: std.ArrayList(NamedCommand) = .empty;
    while (reader.position < bytes.len) {
        const kind = reader.readLine() orelse return null;
        if (std.mem.eql(u8, kind, "executable")) {
            const name = reader.readText() orelse return null;
            const main = reader.readText() orelse return null;
            const libraries = try reader.readTexts(allocator) orelse return null;
            try executables.append(allocator, .{ .name = name, .main = main, .libraries = libraries });
        } else if (std.mem.eql(u8, kind, "test_suite")) {
            const source = reader.readText() orelse return null;
            const tests = reader.readText() orelse return null;
            const libraries = try reader.readTexts(allocator) orelse return null;
            try test_suites.append(allocator, .{ .source = source, .tests = tests, .libraries = libraries });
        } else if (std.mem.eql(u8, kind, "command")) {
            const name = reader.readText() orelse return null;
            const program = reader.readText() orelse return null;
            const arguments = try reader.readTexts(allocator) orelse return null;
            try commands.append(allocator, .{ .name = name, .program = program, .arguments = arguments });
        } else {
            return null;
        }
    }
    return .{ .executables = executables.items, .test_suites = test_suites.items, .commands = commands.items };
}

pub const Description = struct {
    executables: []const Executable,
    test_suites: []const TestSuite,
    commands: []const NamedCommand,

    pub fn findCommand(self: Description, name: []const u8) ?NamedCommand {
        for (self.commands) |command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};

pub const Executable = struct {
    name: []const u8,
    main: []const u8,
    libraries: []const []const u8,
};

pub const TestSuite = struct {
    source: []const u8,
    tests: []const u8,
    libraries: []const []const u8,
};

pub const NamedCommand = struct {
    name: []const u8,
    program: []const u8,
    arguments: []const []const u8,
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readLine(self: *Reader) ?[]const u8 {
        const length = std.mem.findScalar(u8, self.bytes[self.position..], '\n') orelse return null;
        const line = self.bytes[self.position .. self.position + length];
        self.position += length + 1;
        return line;
    }

    fn readText(self: *Reader) ?[]const u8 {
        const rest = self.bytes[self.position..];
        const separator = std.mem.findScalar(u8, rest, ':') orelse return null;
        const length = std.fmt.parseInt(usize, rest[0..separator], 10) catch return null;
        const start = separator + 1;
        if (length >= rest.len - start or rest[start + length] != '\n') return null;
        self.position += start + length + 1;
        return rest[start .. start + length];
    }

    fn readTexts(self: *Reader, allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]const []const u8 {
        const line = self.readLine() orelse return null;
        const count = std.fmt.parseInt(usize, line, 10) catch return null;
        if (count > self.bytes.len - self.position) return null;
        const texts = try allocator.alloc([]const u8, count);
        for (texts) |*text| {
            text.* = self.readText() orelse return null;
        }
        return texts;
    }
};

test "parseDescription: reads every executable, test suite and command with bytes of any kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = "executable\n6:engine\n14:source/main.mn\n2\n4:SDL3\n6:vulkan\n" ++
        "test_suite\n6:source\n5:tests\n0\n" ++
        "command\n3:a:\n\n5:glslc\n2\n2:\n:\n1:\xff\n" ++
        "command\n4:true\n4:true\n0\n";
    const description = (try parseDescription(arena.allocator(), bytes)).?;

    try std.testing.expectEqual(1, description.executables.len);
    try std.testing.expectEqualStrings("engine", description.executables[0].name);
    try std.testing.expectEqualStrings("source/main.mn", description.executables[0].main);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "SDL3", "vulkan" }), description.executables[0].libraries);
    try std.testing.expectEqual(1, description.test_suites.len);
    try std.testing.expectEqualStrings("source", description.test_suites[0].source);
    try std.testing.expectEqualStrings("tests", description.test_suites[0].tests);
    try std.testing.expectEqual(0, description.test_suites[0].libraries.len);
    try std.testing.expectEqual(2, description.commands.len);
    try std.testing.expectEqualStrings("a:\n", description.commands[0].name);
    try std.testing.expectEqualStrings("glslc", description.commands[0].program);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "\n:", "\xff" }), description.commands[0].arguments);
    try std.testing.expectEqualStrings("true", description.commands[1].program);
    try std.testing.expectEqual(0, description.commands[1].arguments.len);
}

test "parseDescription: reads an empty description as one that adds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const description = (try parseDescription(arena.allocator(), "")).?;

    try std.testing.expectEqual(0, description.executables.len + description.test_suites.len + description.commands.len);
}

test "parseDescription: rejects a description that is cut short or holds anything else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(null, try parseDescription(allocator, "executable\n6:engine\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n4:run\n4:true\n0\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n9:run\n4:true\n0\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n3:run\n0\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n3:run\n4:true\n2\n2:-c\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n3:run\n4:true\n99999999999\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "library\n1:m\n"));
    try std.testing.expectEqual(null, try parseDescription(allocator, "command\n3:run\n4:true\n0"));
}

test "Description.findCommand: finds the first command of the name and nothing for another name" {
    const commands = [_]NamedCommand{
        .{ .name = "run", .program = "true", .arguments = &.{} },
        .{ .name = "run", .program = "false", .arguments = &.{} },
    };
    const description: Description = .{ .executables = &.{}, .test_suites = &.{}, .commands = &commands };

    try std.testing.expectEqualStrings("true", description.findCommand("run").?.program);
    try std.testing.expectEqual(null, description.findCommand("shaders"));
}
