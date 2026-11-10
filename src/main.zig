const std = @import("std");
const c = @import("c");
const core = @import("core");
const monolith = @import("monolith");
const types = core.types;

const Analyzer = monolith.Analyzer;
const CallNote = monolith.CallNote;
const Failure = core.Failure;
const Loader = monolith.Loader;

const isName = monolith.isName;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena;
    const allocator = arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const arguments = parseArguments(try init.minimal.args.toSlice(allocator)) orelse {
        return printUsage(stderr);
    };

    const compiler_path = try std.process.executableDirPathAlloc(io, allocator);
    const program_path = std.fs.path.dirname(arguments.path) orelse ".";
    var loader = Loader.init(program_path, compiler_path);

    const module_name = arguments.module_name;
    const is_type_name = types.findBuiltInType(module_name) != null;
    if (!isName(module_name) or is_type_name or std.mem.eql(u8, module_name, "mn")) {
        const failure: Failure = .{ .message = "file name must be a valid name" };
        return report(allocator, io, stderr, &loader, failure, &.{});
    }

    loader.loadMainModule(arena, io, module_name) catch |load_error| {
        const failure = loader.failure orelse return load_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };

    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(arena, io, &loader, &type_registry);
    const program = analyzer.analyze() catch |analyze_error| {
        const failure = analyzer.failure orelse return analyze_error;
        return report(allocator, io, stderr, &loader, failure, try analyzer.collectCallTrace(allocator, failure));
    };

    const generator_path = try std.fs.path.join(allocator, &.{ compiler_path, "generators", "c" });
    var generator = c.Generator.init(program);
    generator.generate(allocator, io, generator_path, "build") catch |generate_error| {
        const failure = generator.failure orelse return generate_error;
        return report(allocator, io, stderr, &loader, failure, &.{});
    };
    return 0;
}

fn parseArguments(arguments: []const [:0]const u8) ?Arguments {
    if (arguments.len != 2) return null;
    const path = arguments[1];
    const file_name = std.fs.path.basename(path);
    const source_extension = ".mn";
    const has_extension = std.mem.endsWith(u8, file_name, source_extension);
    if (!has_extension or file_name.len == source_extension.len) return null;
    const module_name = file_name[0 .. file_name.len - source_extension.len];
    return .{ .path = path, .module_name = module_name };
}

const Arguments = struct {
    path: []const u8,
    module_name: []const u8,
};

fn printUsage(stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    try stderr.writeAll("usage: monolith <file.mn>\n");
    try stderr.flush();
    return 1;
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
