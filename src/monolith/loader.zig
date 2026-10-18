const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;

const Lexer = @import("lexer.zig").Lexer;
const LexError = @import("lexer.zig").LexError;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const Failure = core.Failure;

pub const Loader = struct {
    program_path: []const u8,
    compiler_path: []const u8,
    modules: std.ArrayList(ast.Module) = .empty,
    program_has_std: ?bool = null,
    failure: ?Failure = null,

    pub fn init(program_path: []const u8, compiler_path: []const u8) Loader {
        return .{ .program_path = program_path, .compiler_path = compiler_path };
    }

    pub fn loadMainModule(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        name: []const u8,
    ) LoadError!void {
        const path = try arena.allocator().dupe([]const u8, &.{name});
        _ = try self.loadModule(arena, io, path);
    }

    pub fn buildModuleFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        path: ast.Path,
    ) std.mem.Allocator.Error![]const u8 {
        const file = try buildSourceFileName(allocator, path);
        return std.fs.path.join(allocator, &.{ self.chooseRoot(path[0]), file });
    }

    pub fn loadRoot(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        module_index: usize,
        location: token.Location,
        name: []const u8,
    ) LoadError!?Namespace {
        if (std.mem.eql(u8, name, "monolith")) {
            const message = "module name is reserved";
            return self.fail(module_index, location, message, error.ReservedModuleName);
        }

        const allocator = arena.allocator();
        if (std.mem.eql(u8, name, "std")) {
            if (self.program_has_std == null) {
                const program_path = self.program_path;
                const own_file = try std.fs.path.join(allocator, &.{ program_path, "std.mn" });
                const own_directory = try std.fs.path.join(allocator, &.{ program_path, "std" });
                const has_file = try isFile(io, own_file);
                self.program_has_std = has_file or try isDirectory(io, own_directory);
            }
            if (self.program_has_std.?) {
                const message = "name is ambiguous";
                return self.fail(module_index, location, message, error.AmbiguousName);
            }
        }

        const path = try allocator.dupe([]const u8, &.{name});
        return self.loadNamespace(arena, io, path);
    }

    pub fn loadMember(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        namespace: Namespace,
        name: []const u8,
    ) LoadError!?Namespace {
        const allocator = arena.allocator();
        const path = try std.mem.concat(allocator, []const u8, &.{ namespace.path, &.{name} });
        return self.loadNamespace(arena, io, path);
    }

    fn fail(
        self: *Loader,
        module_index: usize,
        location: token.Location,
        message: []const u8,
        load_error: LoadError,
    ) LoadError {
        const module = self.modules.items[module_index].path;
        self.failure = .{ .module = module, .location = location, .message = message };
        return load_error;
    }

    fn loadNamespace(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError!?Namespace {
        const allocator = arena.allocator();
        const file = try self.buildModuleFileName(allocator, path);
        const joined = try std.mem.join(allocator, "/", path);
        const root = self.chooseRoot(path[0]);
        const directory_path = try std.fs.path.join(allocator, &.{ root, joined });
        const is_file = try isFile(io, file);
        const is_directory = try isDirectory(io, directory_path);
        if (!is_file and !is_directory) return null;

        var module: ?usize = null;
        if (is_file) module = try self.loadModule(arena, io, path);
        return .{ .path = path, .module = module, .directory = is_directory };
    }

    fn chooseRoot(self: *Loader, name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "std")) return self.compiler_path;
        return self.program_path;
    }

    fn loadModule(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError!usize {
        for (self.modules.items, 0..) |module, index| {
            if (module.path.len != path.len) continue;
            for (module.path, path) |loaded_name, name| {
                if (!std.mem.eql(u8, loaded_name, name)) break;
            } else return index;
        }

        const allocator = arena.allocator();
        const file = try self.buildModuleFileName(allocator, path);
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            file,
            allocator,
            .unlimited,
        ) catch |read_error| {
            if (read_error == error.OutOfMemory) return error.OutOfMemory;
            const format = "cannot read '{s}': {t}";
            const message = try std.fmt.allocPrint(allocator, format, .{ file, read_error });
            self.failure = .{ .message = message };
            return read_error;
        };

        var lexer = Lexer.init(source);
        lexer.lex(arena) catch |lex_error| {
            if (lex_error == error.OutOfMemory) return error.OutOfMemory;
            self.failure = lexer.failure;
            self.failure.?.module = path;
            return lex_error;
        };

        var parser = Parser.init(lexer.tokens.items);
        const module = parser.parse(arena) catch |parse_error| {
            if (parse_error == error.OutOfMemory) return error.OutOfMemory;
            self.failure = parser.failure;
            self.failure.?.module = path;
            return parse_error;
        };

        try self.modules.append(allocator, .{ .path = path, .declarations = module.declarations });
        return self.modules.items.len - 1;
    }
};

pub const Namespace = struct {
    path: ast.Path,
    module: ?usize,
    directory: bool,
};

pub const LoadError = LexError ||
    ParseError ||
    std.Io.Dir.StatFileError ||
    std.Io.Dir.ReadFileAllocError ||
    error{ ReservedModuleName, AmbiguousName };

fn buildSourceFileName(
    allocator: std.mem.Allocator,
    path: ast.Path,
) std.mem.Allocator.Error![]const u8 {
    return std.mem.concat(allocator, u8, &.{ try std.mem.join(allocator, "/", path), ".mn" });
}

fn isFile(io: std.Io, path: []const u8) LoadError!bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |stat_error| switch (stat_error) {
        error.FileNotFound, error.NotDir => return false,
        else => return stat_error,
    };
    return stat.kind == .file;
}

fn isDirectory(io: std.Io, path: []const u8) LoadError!bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |stat_error| switch (stat_error) {
        error.FileNotFound, error.NotDir => return false,
        else => return stat_error,
    };
    return stat.kind == .directory;
}

test "loadRoot: loads a module at the top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "fn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };
    const namespace = (try loader.loadRoot(&arena, io, 0, location, "utils")).?;

    try std.testing.expectEqual(1, namespace.module.?);
    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "utils.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), loader.modules.items[1].path));
}

test "loadRoot: reads std from the compiler's directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "std");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "std/console.mn", .data = "fn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };
    const namespace = (try loader.loadRoot(&arena, io, 0, location, "std")).?;

    try std.testing.expectEqual(null, namespace.module);
    try std.testing.expect(namespace.directory);
    _ = try loader.loadMember(&arena, io, namespace, "console");
    const expected = try std.fs.path.join(arena.allocator(), &.{ compiler_path, "std/console.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), loader.modules.items[1].path));
}

test "loadRoot: finds nothing for a name that is neither a file nor a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };
    try std.testing.expectEqual(null, try loader.loadRoot(&arena, io, 0, location, "missing"));
}

test "loadRoot: rejects the reserved name monolith" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "monolith.mn", .data = "fn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };
    const result = loader.loadRoot(&arena, io, 0, location, "monolith");

    try std.testing.expectError(error.ReservedModuleName, result);
    try std.testing.expectEqual(location, loader.failure.?.location.?);
}

test "loadRoot: rejects std when the program has its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(io, "std");
    try compiler_directory.dir.createDirPath(io, "std");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };

    try std.testing.expectError(error.AmbiguousName, loader.loadRoot(&arena, io, 0, location, "std"));
    try std.testing.expectEqual(loader.modules.items[0].path, loader.failure.?.module.?);
}

test "loadMember: loads each module once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(io, "utils");
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };
    const utils = (try loader.loadRoot(&arena, io, 0, location, "utils")).?;
    const first = (try loader.loadMember(&arena, io, utils, "math")).?;
    const second = (try loader.loadMember(&arena, io, utils, "math")).?;

    try std.testing.expectEqual(first.module.?, second.module.?);
    try std.testing.expectEqual(2, loader.modules.items.len);
}

test "loadModule: reports failures in the module they are in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "fn one():\n\tnoop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };

    try std.testing.expectError(error.UnexpectedTab, loader.loadRoot(&arena, io, 0, location, "utils"));
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), loader.failure.?.module.?);
    try std.testing.expectEqual(1, loader.modules.items.len);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, loader.failure.?.location.?);
    try std.testing.expectEqualStrings("tabs are not allowed, use spaces", loader.failure.?.message);
    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "utils.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), loader.failure.?.module.?));
}

test "loadModule: describes a parse error in a module it reaches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "fn one()" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const location: token.Location = .{ .row = 1, .column = 1 };

    try std.testing.expectError(error.ExpectedColon, loader.loadRoot(&arena, io, 0, location, "utils"));
    try std.testing.expectEqualStrings("expected ':'", loader.failure.?.message);
}

test "loadModule: records the file it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = Loader.init(program_path, program_path);

    try std.testing.expectError(error.FileNotFound, loader.loadMainModule(&arena, io, "missing"));
    try std.testing.expectEqual(null, loader.failure.?.location);
    const file = try std.fs.path.join(arena.allocator(), &.{ program_path, "missing.mn" });
    const expected = try std.fmt.allocPrint(arena.allocator(), "cannot read '{s}': FileNotFound", .{file});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}
