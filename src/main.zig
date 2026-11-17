const std = @import("std");
const c = @import("c");
const core = @import("core");
const monolith = @import("monolith");
const types = core.types;

const Analyzer = monolith.Analyzer;
const CallNote = monolith.CallNote;
const Command = monolith.Command;
const CommandRunner = monolith.CommandRunner;
const Description = monolith.Description;
const Failure = core.Failure;
const Loader = monolith.Loader;
const ProjectInitializer = monolith.ProjectInitializer;
const TestRunner = monolith.TestRunner;

const findModuleName = monolith.findModuleName;
const isRootModuleName = monolith.isRootModuleName;
const parseCommand = monolith.parseCommand;
const parseDescription = monolith.parseDescription;

const output_directory = "build";
const test_output_directory = "tests";
const test_executable_name = "test";
const script_file = "build.mn";
const script_output_directory = "script";
const runner_directory = "script";
const runner_file = "runner.mn";
const runner_executable_name = "runner";
const description_file = "description";
const usage =
    \\usage: monolith init
    \\       monolith build [<command>]
    \\       monolith build <file.mn> [--output <path>] [--library <name>]...
    \\       monolith test [<directory>] [--source <directory>] [--library <name>]...
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena;
    const allocator = arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const command = try parseCommand(allocator, try init.minimal.args.toSlice(allocator)) orelse {
        return printUsage(stderr);
    };
    const compiler_path = try std.process.executableDirPathAlloc(io, allocator);
    const paths: Paths = .{
        .compiler = compiler_path,
        .generator = try std.fs.path.join(allocator, &.{ compiler_path, "generators", "c" }),
        .project = "",
    };
    return run(arena, io, stderr, paths, command);
}

const Paths = struct {
    compiler: []const u8,
    generator: []const u8,
    project: []const u8,
};

fn printUsage(stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    try stderr.writeAll(usage);
    try stderr.flush();
    return 1;
}

fn run(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    command: Command,
) !u8 {
    const allocator = arena.allocator();
    return switch (command) {
        .init => initializeProject(allocator, io, stderr),
        .build => |build| buildProgram(arena, io, stderr, paths, try resolveBuild(allocator, paths, build), &.{}),
        .build_script => |script| runBuildScript(arena, io, stderr, paths, script.command_name),
        .@"test" => |tests| buildTests(arena, io, stderr, paths, try resolveTest(allocator, paths, tests)),
        .test_script => |tests| testProject(arena, io, stderr, paths, tests),
    };
}

fn initializeProject(allocator: std.mem.Allocator, io: std.Io, stderr: *std.Io.Writer) !u8 {
    var initializer: ProjectInitializer = .{};
    initializer.initialize(allocator, io, std.Io.Dir.cwd()) catch |initialize_error| {
        const failure = initializer.failure orelse return initialize_error;
        return reportMessage(stderr, failure.message);
    };
    return 0;
}

fn resolveBuild(
    allocator: std.mem.Allocator,
    paths: Paths,
    build: @FieldType(Command, "build"),
) std.mem.Allocator.Error!@FieldType(Command, "build") {
    var resolved = build;
    resolved.path = try std.fs.path.join(allocator, &.{ paths.project, build.path });
    if (build.output) |output| resolved.output = try std.fs.path.join(allocator, &.{ paths.project, output });
    return resolved;
}

fn buildProgram(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    build: @FieldType(Command, "build"),
    kept_names: []const []const u8,
) !u8 {
    const allocator = arena.allocator();
    const program_path = std.fs.path.dirname(build.path) orelse ".";
    var loader = Loader.init(program_path, paths.compiler);

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
    generator.libraries = build.libraries;
    generator.kept_directories = try std.mem.concat(allocator, []const u8, &.{ &.{ test_output_directory, script_output_directory }, kept_names });
    const output_path = try std.fs.path.join(allocator, &.{ paths.project, output_directory });
    return generate(allocator, io, stderr, paths, output_path, &loader, &generator);
}

fn resolveTest(
    allocator: std.mem.Allocator,
    paths: Paths,
    tests: @FieldType(Command, "test"),
) std.mem.Allocator.Error!@FieldType(Command, "test") {
    var resolved = tests;
    resolved.source_directory = try std.fs.path.join(allocator, &.{ paths.project, tests.source_directory });
    resolved.test_directory = try std.fs.path.join(allocator, &.{ paths.project, tests.test_directory });
    return resolved;
}

fn buildTests(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    tests: @FieldType(Command, "test"),
) !u8 {
    const allocator = arena.allocator();
    var loader = Loader.init(tests.source_directory, paths.compiler);

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
    const output_path = try std.fs.path.join(allocator, &.{ paths.project, output_directory, test_output_directory });
    const executable_path = try std.fs.path.join(allocator, &.{ output_path, test_executable_name });
    var generator = c.Generator.init(program);
    generator.tests = test_modules;
    generator.executable_path = executable_path;
    generator.libraries = tests.libraries;
    const status = try generate(allocator, io, stderr, paths, output_path, &loader, &generator);
    if (status != 0) return status;

    var runner: TestRunner = .{};
    return runner.run(allocator, io, executable_path) catch |run_error| {
        const failure = runner.failure orelse return run_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };
}

fn runBuildScript(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    command_name: ?[]const u8,
) !u8 {
    const allocator = arena.allocator();
    if (!try hasBuildScript(allocator, io, paths)) return reportMessage(stderr, "'" ++ script_file ++ "' does not exist");
    const description = try configure(arena, io, stderr, paths) orelse return 1;
    const name = command_name orelse return buildExecutables(arena, io, stderr, paths, description);
    return runCommand(allocator, io, stderr, paths, description, name);
}

fn hasBuildScript(allocator: std.mem.Allocator, io: std.Io, paths: Paths) !bool {
    const path = try std.fs.path.join(allocator, &.{ paths.project, script_file });
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |stat_error| switch (stat_error) {
        error.FileNotFound, error.NotDir => return false,
        else => return stat_error,
    };
    return stat.kind == .file;
}

fn configure(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
) !?Description {
    const allocator = arena.allocator();
    var loader = Loader.init(paths.project, paths.compiler);
    const runner_path = try std.fs.path.join(allocator, &.{ paths.compiler, runner_directory, runner_file });
    loader.loadBuildScript(arena, io, runner_path) catch |load_error| {
        const failure = loader.failure orelse return load_error;
        _ = try report(allocator, io, stderr, &loader, failure, &.{});
        return null;
    };

    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(arena, io, &loader, &type_registry);
    const program = analyzer.analyze() catch |analyze_error| {
        const failure = analyzer.failure orelse return analyze_error;
        _ = try report(allocator, io, stderr, &loader, failure, try analyzer.collectCallTrace(allocator, failure));
        return null;
    };

    const output_path = try std.fs.path.join(allocator, &.{ paths.project, output_directory, script_output_directory });
    const executable_path = try std.fs.path.join(allocator, &.{ output_path, runner_executable_name });
    var generator = c.Generator.init(program);
    generator.executable_path = executable_path;
    if (try generate(allocator, io, stderr, paths, output_path, &loader, &generator) != 0) return null;

    const description_path = try std.fs.path.join(allocator, &.{ output_path, description_file });
    var runner: CommandRunner = .{};
    const status = runner.run(allocator, io, "", &.{ executable_path, description_path }) catch |run_error| {
        const failure = runner.failure orelse return run_error;
        _ = try reportMessage(stderr, failure.message);
        return null;
    };
    if (status != 0) {
        _ = try reportMessage(stderr, "build in '" ++ script_file ++ "' returned an error");
        return null;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, description_path, allocator, .unlimited) catch |read_error| {
        _ = try reportMessage(stderr, try std.fmt.allocPrint(allocator, "cannot read '{s}': {t}", .{ description_path, read_error }));
        return null;
    };
    const description = try parseDescription(allocator, bytes) orelse {
        _ = try reportMessage(stderr, try std.fmt.allocPrint(allocator, "'{s}' does not describe a build", .{description_path}));
        return null;
    };
    return description;
}

fn buildExecutables(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    description: Description,
) !u8 {
    const allocator = arena.allocator();
    var kept_names: std.ArrayList([]const u8) = .empty;
    for (description.executables) |executable| {
        const status = try buildProgram(arena, io, stderr, paths, .{
            .path = try std.fs.path.join(allocator, &.{ paths.project, executable.main }),
            .module_name = findModuleName(executable.main) orelse "",
            .output = try std.fs.path.join(allocator, &.{ paths.project, output_directory, executable.name }),
            .libraries = executable.libraries,
        }, kept_names.items);
        if (status != 0) return status;
        const end = std.mem.findScalar(u8, executable.name, '/') orelse executable.name.len;
        try kept_names.append(allocator, executable.name[0..end]);
    }
    return 0;
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    description: Description,
    name: []const u8,
) !u8 {
    const command = description.findCommand(name) orelse {
        return reportMessage(stderr, try std.fmt.allocPrint(allocator, "'" ++ script_file ++ "' adds no command named '{s}'", .{name}));
    };
    const arguments = try std.mem.concat(allocator, []const u8, &.{ &.{command.program}, command.arguments });
    var runner: CommandRunner = .{};
    return runner.run(allocator, io, paths.project, arguments) catch |run_error| {
        const failure = runner.failure orelse return run_error;
        return reportMessage(stderr, failure.message);
    };
}

fn testProject(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    tests: @FieldType(Command, "test_script"),
) !u8 {
    const allocator = arena.allocator();
    if (!try hasBuildScript(allocator, io, paths)) return buildTests(arena, io, stderr, paths, try resolveTest(allocator, paths, tests));
    const description = try configure(arena, io, stderr, paths) orelse return 1;
    if (description.test_suites.len == 0) return reportMessage(stderr, "'" ++ script_file ++ "' adds no test suites");
    var has_failed = false;
    for (description.test_suites) |suite| {
        const status = try buildTests(arena, io, stderr, paths, .{
            .source_directory = try std.fs.path.join(allocator, &.{ paths.project, suite.source }),
            .test_directory = try std.fs.path.join(allocator, &.{ paths.project, suite.tests }),
            .is_test_directory_optional = true,
            .libraries = suite.libraries,
        });
        if (status != 0) has_failed = true;
    }
    return if (has_failed) 1 else 0;
}

fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    paths: Paths,
    output_path: []const u8,
    loader: *Loader,
    generator: *c.Generator,
) !u8 {
    generator.generate(allocator, io, paths.generator, output_path) catch |generate_error| {
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

fn reportMessage(stderr: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!u8 {
    try stderr.print("error: {s}\n", .{message});
    try stderr.flush();
    return 1;
}

test "printUsage: shows every form of the compiler and fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var stderr: std.Io.Writer.Allocating = .init(arena.allocator());

    try std.testing.expectEqual(1, try printUsage(&stderr.writer));
    try std.testing.expectEqualStrings(
        "usage: monolith init\n" ++
            "       monolith build [<command>]\n" ++
            "       monolith build <file.mn> [--output <path>] [--library <name>]...\n" ++
            "       monolith test [<directory>] [--source <directory>] [--library <name>]...\n",
        stderr.written(),
    );
}

test "run: links the libraries after --library on the direct commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.createDirPath(io, "roots");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/main.mn", .data = "import mn\nimport mn::process::{ self, stdout }\n\nexternal fn cbrt(value: f64) -> f64\n\n\nfn main -> !void\n    try stdout.println(\"{}\", { root(process::arguments()) })\n\n\nfn root(arguments: const(*[]const(*[]u8))) -> f64 = cbrt(mn::convert(f64, arguments.length + 27))\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "roots/roots.mn", .data = "import mn\nimport mn::process\nimport mn::test::expect\n\nexternal fn cbrt(value: f64) -> f64\n\n\nfn root(arguments: const(*[]const(*[]u8))) -> f64 = cbrt(mn::convert(f64, arguments.length + 27))\n\n\ntest \"root: gives a cube root\"\n    try expect(root(process::arguments()) > 2.5)\n" });
    var unlinked: std.Io.Writer.Allocating = .init(allocator);
    var linked: std.Io.Writer.Allocating = .init(allocator);
    var unlinked_tests: std.Io.Writer.Allocating = .init(allocator);
    var linked_tests: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &unlinked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "source/main.mn" })).?));
    try std.testing.expectEqualStrings("error: gcc could not build the executable\n", unlinked.written());
    try std.testing.expectEqual(0, try run(&arena, io, &linked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "source/main.mn", "--library", "m", "--output", "roots/cube" })).?));
    const executable = try std.fs.path.join(allocator, &.{ paths.project, "roots", "cube" });
    const result = try std.process.run(allocator, io, .{ .argv = &.{executable} });
    try std.testing.expectEqual(0, result.term.exited);
    try std.testing.expectEqual(1, try run(&arena, io, &unlinked_tests.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test", "roots" })).?));
    try std.testing.expectEqualStrings("error: gcc could not build the executable\n", unlinked_tests.written());
    try std.testing.expectEqual(0, try run(&arena, io, &linked_tests.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test", "roots", "--library", "m" })).?));
}

test "run: builds a file ending in .mn and tests a named directory without reading build.mn, keeping build/script and build/tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.createDirPath(io, "build/script");
    try project_directory.dir.createDirPath(io, "build/tests");
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "this is not a module\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/main.mn", .data = "fn main = noop\n\n\ntest \"main: passes\"\n    noop\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/script/description", .data = "kept" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/tests/kept", .data = "kept" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/old", .data = "old" });
    var built: std.Io.Writer.Allocating = .init(allocator);
    var tested: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(0, try run(&arena, io, &built.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "source/main.mn" })).?));
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/main", .{})).kind);
    try std.testing.expectError(error.FileNotFound, project_directory.dir.statFile(io, "build/old", .{}));
    try std.testing.expectEqualStrings("kept", try project_directory.dir.readFileAlloc(io, "build/tests/kept", allocator, .unlimited));
    try std.testing.expectEqual(0, try run(&arena, io, &tested.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test", "source" })).?));
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/main", .{})).kind);
    try std.testing.expectEqualStrings("kept", try project_directory.dir.readFileAlloc(io, "build/script/description", allocator, .unlimited));
    try std.testing.expectEqualStrings("", built.written());
    try std.testing.expectEqualStrings("", tested.written());
}

test "run: tests the source directory beside it without build.mn and without arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/checks.mn", .data = "import mn::test::expect\n\n\ntest \"checks: fails on purpose\"\n    try expect(false)\n" });
    var stderr: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &stderr.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/tests/test", .{})).kind);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "run: reports a project without build.mn for a build through it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    var build: std.Io.Writer.Allocating = .init(allocator);
    var command: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &build.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    try std.testing.expectEqualStrings("error: 'build.mn' does not exist\n", build.written());
    try std.testing.expectEqual(1, try run(&arena, io, &command.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "shaders" })).?));
    try std.testing.expectEqualStrings("error: 'build.mn' does not exist\n", command.written());
}

test "run: builds every executable that build.mn adds, each linked with its own libraries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    const program = "import mn\nimport mn::process::{ self, stdout }\n\nexternal fn cbrt(value: f64) -> f64\n\n\nfn main -> !void\n    try stdout.println(\"{}\", { root(process::arguments()) })\n\n\nfn root(arguments: const(*[]const(*[]u8))) -> f64 = cbrt(mn::convert(f64, arguments.length + 27))\n";
    const script = "import mn::build::{ Build, Executable }\n\n\nfn build(build: *Build) -> !void\n    var first = Executable::init({ name = \"first\", main = \"source/first.mn\" })\n    try first.link_system_library(\"m\")\n    try build.add_executable(first)\n";
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/first.mn", .data = program });
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/second.mn", .data = program });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = script ++ "    try build.add_executable(Executable::init({ name = \"second\", main = \"source/second.mn\" }))\n" });
    var unlinked: std.Io.Writer.Allocating = .init(allocator);
    var linked: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &unlinked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    try std.testing.expectEqualStrings("error: gcc could not build the executable\n", unlinked.written());
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/first", .{})).kind);
    try std.testing.expectError(error.FileNotFound, project_directory.dir.statFile(io, "build/second", .{}));
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = script ++ "    var second = Executable::init({ name = \"second\", main = \"source/second.mn\" })\n    try second.link_system_library(\"m\")\n    try build.add_executable(second)\n" });
    try std.testing.expectEqual(0, try run(&arena, io, &linked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    for ([_][]const u8{ "first", "second" }) |name| {
        const executable = try std.fs.path.join(allocator, &.{ paths.project, "build", name });
        const result = try std.process.run(allocator, io, .{ .argv = &.{executable} });
        try std.testing.expectEqual(0, result.term.exited);
    }
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/script/runner", .{})).kind);
    try std.testing.expectEqualStrings("", linked.written());
}

test "run: runs a command that build.mn adds only when asked for by its name, in the project, passing on its exit status, beside a directory build holding modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.createDirPath(io, "build");
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/module.mn", .data = "this is not a module\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/build.mn", .data = "this is not a module\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "import mn::build::Build\n\n\nfn build(build: *Build) -> !void\n    try build.add_command(\"mark\", \"sh\", { \"-c\", \"touch marked\" })\n    try build.add_command(\"fail\", \"sh\", { \"-c\", \"exit 3\" })\n    try build.add_command(\"succeed\", \"true\", {})\n    try build.add_command(\"refuse\", \"false\", {})\n" });
    var built: std.Io.Writer.Allocating = .init(allocator);
    var marked: std.Io.Writer.Allocating = .init(allocator);
    var failed: std.Io.Writer.Allocating = .init(allocator);
    var succeeded: std.Io.Writer.Allocating = .init(allocator);
    var refused: std.Io.Writer.Allocating = .init(allocator);
    var missing: std.Io.Writer.Allocating = .init(allocator);
    var tested: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(0, try run(&arena, io, &built.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    try std.testing.expectError(error.FileNotFound, project_directory.dir.statFile(io, "marked", .{}));
    try std.testing.expectEqual(0, try run(&arena, io, &marked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "mark" })).?));
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "marked", .{})).kind);
    try std.testing.expectEqual(3, try run(&arena, io, &failed.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "fail" })).?));
    try std.testing.expectEqual(0, try run(&arena, io, &succeeded.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "succeed" })).?));
    try std.testing.expectEqual(1, try run(&arena, io, &refused.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "refuse" })).?));
    try std.testing.expectEqualStrings("", refused.written());
    try std.testing.expectEqual(1, try run(&arena, io, &missing.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build", "missing" })).?));
    try std.testing.expectEqualStrings("error: 'build.mn' adds no command named 'missing'\n", missing.written());
    try std.testing.expectEqual(1, try run(&arena, io, &tested.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqualStrings("error: 'build.mn' adds no test suites\n", tested.written());
    try std.testing.expectEqualStrings("", built.written());
}

test "run: builds and runs every test suite that build.mn adds, each linked with its own libraries, and fails when one fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    const header = "import mn::build::{ Build, TestSuite }\n\n\nfn build(build: *Build) -> !void\n";
    const script = header ++ "    var roots = TestSuite::init({ source_directory = \"roots\" })\n    try roots.link_system_library(\"m\")\n    try build.add_test_suite(roots)\n";
    try project_directory.dir.createDirPath(io, "roots");
    try project_directory.dir.createDirPath(io, "checks");
    try project_directory.dir.writeFile(io, .{ .sub_path = "roots/roots.mn", .data = "import mn\nimport mn::process\nimport mn::test::expect\n\nexternal fn cbrt(value: f64) -> f64\n\n\nfn root(arguments: const(*[]const(*[]u8))) -> f64 = cbrt(mn::convert(f64, arguments.length + 27))\n\n\ntest \"root: gives a cube root\"\n    try expect(root(process::arguments()) > 2.5)\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "checks/checks.mn", .data = "import mn::test::expect\n\n\ntest \"checks: fails on purpose\"\n    try expect(false)\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = header ++ "    try build.add_test_suite(TestSuite::init({ source_directory = \"roots\" }))\n" });
    var unlinked: std.Io.Writer.Allocating = .init(allocator);
    var failing: std.Io.Writer.Allocating = .init(allocator);
    var passing: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &unlinked.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqualStrings("error: gcc could not build the executable\n", unlinked.written());
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = script ++ "    try build.add_test_suite(TestSuite::init({ source_directory = \"checks\" }))\n" });
    try std.testing.expectEqual(1, try run(&arena, io, &failing.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqualStrings("", failing.written());
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = script });
    try std.testing.expectEqual(0, try run(&arena, io, &passing.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqualStrings("", passing.written());
}

test "run: builds the two executables and runs the test suite of a build.mn that creates them and adds them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    const engine = "import mn\nimport mn::process::{ self, stdout }\nimport mn::test::expect\n\nexternal fn cbrt(value: f64) -> f64\n\n\nfn main -> !void\n    try stdout.println(\"{}\", { root(process::arguments()) })\n\n\nfn root(arguments: const(*[]const(*[]u8))) -> f64 = cbrt(mn::convert(f64, arguments.length + 27))\n\n\ntest \"root: gives a cube root\"\n    try expect(root(process::arguments()) > 2.5)\n";
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/engine.mn", .data = engine });
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/main.mn", .data = "fn main = noop\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "import mn::build::{ Build, Executable, TestSuite }\n\n\nfn build(build: *Build) -> !void\n    var engine = Executable::init({ name = \"engine\", main = \"source/engine.mn\" })\n    try engine.link_system_library(\"m\")\n    try build.add_executable(engine)\n\n    try build.add_executable(Executable::init())\n\n    var suite = TestSuite::init()\n    try suite.link_system_library(\"m\")\n    try build.add_test_suite(suite)\n\n    try build.add_command(\"check\", \"sh\", { \"-c\", \"exit 0\" })\n" });
    var built: std.Io.Writer.Allocating = .init(allocator);
    var tested: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(0, try run(&arena, io, &built.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    for ([_][]const u8{ "engine", "main" }) |name| {
        const executable = try std.fs.path.join(allocator, &.{ paths.project, "build", name });
        const result = try std.process.run(allocator, io, .{ .argv = &.{executable} });
        try std.testing.expectEqual(0, result.term.exited);
    }
    try std.testing.expectEqual(0, try run(&arena, io, &tested.writer, paths, (try parseCommand(allocator, &.{ "monolith", "test" })).?));
    try std.testing.expectEqual(.file, (try project_directory.dir.statFile(io, "build/tests/test", .{})).kind);
    try std.testing.expectEqualStrings("", built.written());
    try std.testing.expectEqualStrings("", tested.written());
}

test "run: reports a build.mn whose build returns an error after creating values and builds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/main.mn", .data = "fn main = noop\n" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "import mn::build::{ Build, Executable }\n\n\nerror Failure\n    Broken\n\n\nfn build(build: *Build) -> !void\n    var program = Executable::init()\n    try program.link_system_library(\"m\")\n    try build.add_executable(program)\n    return Failure::Broken\n" });
    var stderr: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &stderr.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    try std.testing.expectEqualStrings("error: build in 'build.mn' returned an error\n", stderr.written());
    try std.testing.expectError(error.FileNotFound, project_directory.dir.statFile(io, "build/main", .{}));
}

test "run: reports a build.mn that fails to compile where it fails and builds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const paths: Paths = .{ .compiler = "library", .generator = "generators/c", .project = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path }) };
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "import mn::build::Build\n\n\nfn build(build: *Build) -> !void\n    try build.add_library(\"main\")\n" });
    var stderr: std.Io.Writer.Allocating = .init(allocator);

    try std.testing.expectEqual(1, try run(&arena, io, &stderr.writer, paths, (try parseCommand(allocator, &.{ "monolith", "build" })).?));
    const location = try std.fs.path.join(allocator, &.{ paths.project, "build.mn:5:" });
    try std.testing.expect(std.mem.startsWith(u8, stderr.written(), location));
    try std.testing.expectError(error.FileNotFound, project_directory.dir.statFile(io, "build/script/runner", .{}));
}
