const std = @import("std");
const c = @import("c");
const core = @import("core");
const monolith = @import("monolith");
const ast = core.ast;
const types = core.types;

const Failure = core.Failure;
const Loader = monolith.Loader;
const NameResolver = monolith.NameResolver;
const TypeChecker = monolith.TypeChecker;

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
    if (!isName(module_name) or is_type_name or std.mem.eql(u8, module_name, "std")) {
        const failure: Failure = .{ .message = "file name must be a valid name" };
        return report(allocator, stderr, &loader, failure);
    }

    loader.loadMainModule(arena, io, module_name) catch |load_error| {
        const failure = loader.failure orelse return load_error;
        return report(allocator, stderr, &loader, failure);
    };

    var name_resolver = NameResolver.init(arena, io, &loader);
    name_resolver.resolve() catch |resolve_error| {
        const failure = name_resolver.failure orelse return resolve_error;
        return report(allocator, stderr, &loader, failure);
    };
    const program: ast.Program = .{ .modules = loader.modules.items };

    var type_checker = TypeChecker.init(program);
    type_checker.check() catch |type_error| {
        const failure = type_checker.failure orelse return type_error;
        return report(allocator, stderr, &loader, failure);
    };

    const plugin_path = try std.fs.path.join(allocator, &.{ compiler_path, "plugins", "c" });
    var generator = c.Generator.init(program);
    generator.generate(allocator, io, plugin_path, "build") catch |generate_error| {
        const failure = generator.failure orelse return generate_error;
        return report(allocator, stderr, &loader, failure);
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
    stderr: *std.Io.Writer,
    loader: *Loader,
    failure: Failure,
) !u8 {
    if (failure.location) |location| {
        const file = try loader.buildModuleFileName(allocator, failure.module.?);
        try stderr.print("{s}:{d}:{d}: ", .{ file, location.row, location.column });
    }
    try stderr.print("error: {s}\n", .{failure.message});
    try stderr.flush();
    return 1;
}
