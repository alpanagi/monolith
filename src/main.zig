const std = @import("std");
const c = @import("c");
const core = @import("core");
const monolith = @import("monolith");
const types = core.types;

const Analyzer = monolith.Analyzer;
const CallNote = monolith.CallNote;
const Command = monolith.Command;
const Failure = core.Failure;
const Loader = monolith.Loader;
const ProjectInitializer = monolith.ProjectInitializer;
const TestRunner = monolith.TestRunner;

const isRootModuleName = monolith.isRootModuleName;
const parseCommand = monolith.parseCommand;

const output_directory = "build";
const test_output_directory = "tests";
const test_executable_name = "test";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena;
    const allocator = arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const command = parseCommand(try init.minimal.args.toSlice(allocator)) orelse {
        return printUsage(stderr);
    };
    const compiler_path = try std.process.executableDirPathAlloc(io, allocator);
    return switch (command) {
        .init => initializeProject(allocator, io, stderr),
        .build => |build| buildProgram(arena, io, stderr, compiler_path, build),
        .@"test" => |tests| buildTests(arena, io, stderr, compiler_path, tests),
    };
}

fn printUsage(stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    try stderr.writeAll("usage: monolith init\n       monolith build <file.mn> [--output <path>]\n       monolith test [<directory>] [--source <directory>]\n");
    try stderr.flush();
    return 1;
}

fn initializeProject(allocator: std.mem.Allocator, io: std.Io, stderr: *std.Io.Writer) !u8 {
    var initializer: ProjectInitializer = .{};
    initializer.initialize(allocator, io, std.Io.Dir.cwd()) catch |initialize_error| {
        const failure = initializer.failure orelse return initialize_error;
        try stderr.print("error: {s}\n", .{failure.message});
        try stderr.flush();
        return 1;
    };
    return 0;
}

fn buildProgram(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    compiler_path: []const u8,
    build: @FieldType(Command, "build"),
) !u8 {
    const allocator = arena.allocator();
    const program_path = std.fs.path.dirname(build.path) orelse ".";
    var loader = Loader.init(program_path, compiler_path);

    if (!isRootModuleName(build.module_name)) {
        const failure: Failure = .{ .message = "file name must be a valid name" };
        return report(allocator, io, stderr, &loader, failure, &.{});
    }

    loader.loadMainModule(arena, io, build.module_name) catch |load_error| {
        const failure = loader.failure orelse return load_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };

    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(arena, io, &loader, &type_registry);
    const program = analyzer.analyze() catch |analyze_error| {
        const failure = analyzer.failure orelse return analyze_error;
        return report(allocator, io, stderr, &loader, failure, try analyzer.collectCallTrace(allocator, failure));
    };

    var generator = c.Generator.init(program);
    generator.executable_path = build.output;
    generator.kept_directory = test_output_directory;
    return generate(allocator, io, stderr, compiler_path, output_directory, &loader, &generator);
}

fn buildTests(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    compiler_path: []const u8,
    tests: @FieldType(Command, "test"),
) !u8 {
    const allocator = arena.allocator();
    var loader = Loader.init(tests.source_directory, compiler_path);

    const modules = loader.loadTestModules(arena, io, tests.test_directory, tests.is_test_directory_optional) catch |load_error| {
        const failure = loader.failure orelse return load_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };

    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(arena, io, &loader, &type_registry);
    const program = analyzer.analyze() catch |analyze_error| {
        const failure = analyzer.failure orelse return analyze_error;
        return report(allocator, io, stderr, &loader, failure, try analyzer.collectCallTrace(allocator, failure));
    };

    const test_modules = try allocator.alloc(c.TestModule, modules.len);
    for (modules, test_modules) |module, *test_module| {
        const file = try loader.buildModuleFileName(allocator, io, loader.modules.items[module].path);
        test_module.* = .{ .module = module, .file = file };
    }
    const output_path = try std.fs.path.join(allocator, &.{ output_directory, test_output_directory });
    const executable_path = try std.fs.path.join(allocator, &.{ output_path, test_executable_name });
    var generator = c.Generator.init(program);
    generator.tests = test_modules;
    generator.executable_path = executable_path;
    const status = try generate(allocator, io, stderr, compiler_path, output_path, &loader, &generator);
    if (status != 0) return status;

    var runner: TestRunner = .{};
    return runner.run(allocator, io, executable_path) catch |run_error| {
        const failure = runner.failure orelse return run_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };
}

fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    compiler_path: []const u8,
    output_path: []const u8,
    loader: *Loader,
    generator: *c.Generator,
) !u8 {
    const generator_path = try std.fs.path.join(allocator, &.{ compiler_path, "generators", "c" });
    generator.generate(allocator, io, generator_path, output_path) catch |generate_error| {
        const failure = generator.failure orelse return generate_error;
        return report(allocator, io, stderr, loader, failure, &.{});
    };
    return 0;
}

fn report(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    loader: *Loader,
    failure: Failure,
    trace: []const CallNote,
) !u8 {
    if (failure.location) |location| {
        const file = try loader.buildModuleFileName(allocator, io, failure.module.?);
        try stderr.print("{s}:{d}:{d}: ", .{ file, location.row, location.column });
    }
    try stderr.print("error: {s}\n", .{failure.message});
    for (trace) |note| {
        const file = try loader.buildModuleFileName(allocator, io, loader.modules.items[note.module].path);
        try stderr.print("{s}:{d}:{d}: note: called from here", .{ file, note.location.row, note.location.column });
        if (note.count > 1) try stderr.print(" ({d} times)", .{note.count});
        try stderr.writeByte('\n');
    }
    try stderr.flush();
    return 1;
}
