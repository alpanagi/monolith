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
    namespaces: std.ArrayList(Namespace) = .empty,
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
        const allocator = arena.allocator();
        const own_file = try std.fs.path.join(allocator, &.{ self.program_path, "mn.mn" });
        const own_directory = try std.fs.path.join(allocator, &.{ self.program_path, "mn" });
        if (try isFile(io, own_file) or try isDirectory(io, own_directory)) {
            self.failure = .{ .message = "mn is the module that comes with the language, a program cannot have its own" };
            return error.ReservedModuleName;
        }
        const top_module = try std.fs.path.join(allocator, &.{ self.program_path, "module.mn" });
        if (try isFile(io, top_module)) {
            self.failure = .{ .message = "module.mn cannot be at the top of the program, the root of the program is main.mn" };
            return error.ReservedModuleName;
        }
        const path = try allocator.dupe([]const u8, &.{name});
        _ = try self.loadModule(arena, io, path, try self.buildOuterFileName(allocator, path));
        try self.loadReferencedModules(arena, io);
    }

    pub fn buildModuleFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError![]const u8 {
        const outer_file = try self.buildOuterFileName(allocator, path);
        if (try isFile(io, outer_file)) return outer_file;
        const inner_file = try self.buildInnerFileName(allocator, path);
        if (try isFile(io, inner_file)) return inner_file;
        return outer_file;
    }

    pub fn findRoot(self: *const Loader, name: []const u8) ?Namespace {
        return self.findNamespace(&.{}, name);
    }

    pub fn findMember(self: *const Loader, namespace: Namespace, name: []const u8) ?Namespace {
        return self.findNamespace(namespace.path, name);
    }

    pub fn hasMember(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: ast.Path,
        name: []const u8,
    ) LoadError!bool {
        if (isDirectoryModuleName(name)) return false;
        const member = try std.mem.concat(allocator, []const u8, &.{ path, &.{name} });
        const file = try self.buildOuterFileName(allocator, member);
        if (try isFile(io, file)) return true;
        return isDirectory(io, try self.buildDirectoryName(allocator, member));
    }

    fn loadReferencedModules(self: *Loader, arena: *std.heap.ArenaAllocator, io: std.Io) LoadError!void {
        const allocator = arena.allocator();
        var module_index: usize = 0;
        while (module_index < self.modules.items.len) : (module_index += 1) {
            const module = self.modules.items[module_index];
            for (module.declarations) |declaration| {
                if (declaration.kind != .import) continue;
                try self.loadPath(arena, io, declaration.kind.import.path);
            }
            for (module.paths) |path| {
                const import = findImport(module, path[0]) orelse continue;
                try self.loadPath(arena, io, try std.mem.concat(allocator, []const u8, &.{ import.path, path[1..] }));
            }
            if (module.has_range) try self.loadPath(arena, io, &.{ "mn", "range" });
        }
    }

    fn loadPath(self: *Loader, arena: *std.heap.ArenaAllocator, io: std.Io, path: ast.Path) LoadError!void {
        const last = path.len - 1;
        const end = if (path.len > 1 and findBuiltin(path[0..last], path[last]) != null) last else path.len;
        for (1..end + 1) |length| {
            if (try self.loadNamespace(arena, io, path[0..length]) == null) return;
        }
    }

    fn findNamespace(self: *const Loader, parent: ast.Path, name: []const u8) ?Namespace {
        for (self.namespaces.items) |namespace| {
            if (namespace.path.len != parent.len + 1) continue;
            if (!std.mem.eql(u8, namespace.path[parent.len], name)) continue;
            for (namespace.path[0..parent.len], parent) |own_name, parent_name| {
                if (!std.mem.eql(u8, own_name, parent_name)) break;
            } else return namespace;
        }
        return null;
    }

    fn loadNamespace(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError!?Namespace {
        if (self.findNamespace(path[0 .. path.len - 1], path[path.len - 1])) |namespace| return namespace;
        if (isDirectoryModuleName(path[path.len - 1])) return null;
        const allocator = arena.allocator();
        const outer_file = try self.buildOuterFileName(allocator, path);
        const inner_file = try self.buildInnerFileName(allocator, path);
        const directory_path = try self.buildDirectoryName(allocator, path);
        const is_outer_file = try isFile(io, outer_file);
        const is_directory = try isDirectory(io, directory_path);
        if (is_outer_file and is_directory) {
            const format = "'{s}' is next to the directory with its name, move it to '{s}'";
            const message = try std.fmt.allocPrint(allocator, format, .{ outer_file, inner_file });
            self.failure = .{ .message = message };
            return error.ModuleNextToDirectory;
        }
        if (!is_outer_file and !is_directory and !isLanguageNamespace(path)) return null;

        var module: ?usize = null;
        if (is_outer_file) {
            module = try self.loadModule(arena, io, path, outer_file);
        } else if (try isFile(io, inner_file)) {
            module = try self.loadModule(arena, io, path, inner_file);
        }
        const namespace: Namespace = .{ .path = path, .module = module, .directory = is_directory };
        try self.namespaces.append(allocator, namespace);
        return namespace;
    }

    fn buildOuterFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        path: ast.Path,
    ) std.mem.Allocator.Error![]const u8 {
        const file = try buildSourceFileName(allocator, path);
        return std.fs.path.join(allocator, &.{ self.chooseRoot(path[0]), file });
    }

    fn buildInnerFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        path: ast.Path,
    ) std.mem.Allocator.Error![]const u8 {
        const directory_path = try self.buildDirectoryName(allocator, path);
        return std.fs.path.join(allocator, &.{ directory_path, "module.mn" });
    }

    fn buildDirectoryName(
        self: *Loader,
        allocator: std.mem.Allocator,
        path: ast.Path,
    ) std.mem.Allocator.Error![]const u8 {
        const joined = try std.mem.join(allocator, "/", path);
        return std.fs.path.join(allocator, &.{ self.chooseRoot(path[0]), joined });
    }

    fn chooseRoot(self: *Loader, name: []const u8) []const u8 {
        if (isLanguageModule(name)) return self.compiler_path;
        return self.program_path;
    }

    fn loadModule(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        path: ast.Path,
        file: []const u8,
    ) LoadError!usize {
        for (self.modules.items, 0..) |module, index| {
            if (module.path.len != path.len) continue;
            for (module.path, path) |loaded_name, name| {
                if (!std.mem.eql(u8, loaded_name, name)) break;
            } else return index;
        }

        const allocator = arena.allocator();
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

        try self.modules.append(allocator, .{
            .path = path,
            .declarations = module.declarations,
            .paths = module.paths,
            .has_range = module.has_range,
        });
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
    error{ ReservedModuleName, ModuleNextToDirectory };

pub fn findBuiltin(path: ast.Path, name: []const u8) ?ast.Builtin {
    if (!isLanguageModule(path[0])) return null;
    const builtin = std.meta.stringToEnum(ast.Builtin, name) orelse return null;
    const namespace = findBuiltinNamespace(builtin) orelse {
        if (path.len == 1) return builtin;
        return null;
    };
    if (path.len == 2 and std.mem.eql(u8, path[1], namespace)) return builtin;
    return null;
}

pub fn isLanguageModule(name: []const u8) bool {
    return std.mem.eql(u8, name, "mn");
}

pub fn isLanguageNamespace(path: ast.Path) bool {
    if (!isLanguageModule(path[0])) return false;
    if (path.len == 1) return true;
    if (path.len != 2) return false;
    for ([_][]const u8{ "reflection", "comptime", "math" }) |namespace| {
        if (std.mem.eql(u8, path[1], namespace)) return true;
    }
    return false;
}

fn findBuiltinNamespace(builtin: ast.Builtin) ?[]const u8 {
    return switch (builtin) {
        .length, .join => "reflection",
        .@"error" => "comptime",
        .add_wrapping, .subtract_wrapping, .multiply_wrapping => "math",
        .size, .alignment, .convert, .truncate, .cast, .@"align" => null,
    };
}

fn findImport(module: ast.Module, name: []const u8) ?ast.Import {
    for (module.declarations) |declaration| {
        if (declaration.kind != .import) continue;
        if (std.mem.eql(u8, declaration.kind.import.name, name)) return declaration.kind.import;
    }
    return null;
}

fn isDirectoryModuleName(name: []const u8) bool {
    return std.mem.eql(u8, name, "module");
}

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

test "loadMainModule: rejects a program with its own mn module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "mn.mn", .data = "fn one() = noop" });
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

    try std.testing.expectError(error.ReservedModuleName, loader.loadMainModule(&arena, io, "main"));
}

test "loadMainModule: rejects a program with its own mn directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(io, "mn");
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

    try std.testing.expectError(error.ReservedModuleName, loader.loadMainModule(&arena, io, "main"));
}

test "loadMainModule: rejects a module named module at the top of the program" {
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
    try program_directory.dir.writeFile(io, .{ .sub_path = "module.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });

    try std.testing.expectError(error.ReservedModuleName, loader.loadMainModule(&arena, io, "main"));
    try std.testing.expectEqual(null, loader.failure.?.location);
    try std.testing.expectEqualStrings("module.mn cannot be at the top of the program, the root of the program is main.mn", loader.failure.?.message);
    try std.testing.expectEqual(0, loader.modules.items.len);
}

test "loadMainModule: does not start from the module in the directory of the entry" {
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
    try program_directory.dir.createDirPath(io, "main");
    try program_directory.dir.writeFile(io, .{ .sub_path = "main/module.mn", .data = "fn main() = noop" });

    try std.testing.expectError(error.FileNotFound, loader.loadMainModule(&arena, io, "main"));
    const file = try std.fs.path.join(arena.allocator(), &.{ program_path, "main.mn" });
    const expected = try std.fmt.allocPrint(arena.allocator(), "cannot read '{s}': FileNotFound", .{file});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
    try std.testing.expectEqual(0, loader.modules.items.len);
}

test "loadMainModule: reads the entry and not the module in its directory" {
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
    try program_directory.dir.createDirPath(io, "main");
    try program_directory.dir.writeFile(io, .{ .sub_path = "main/module.mn", .data = "fn one() = noop\nfn two() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "fn one() = noop" });
    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(1, loader.modules.items[0].declarations.len);
}

test "loadMainModule: rejects an import path that starts with module when the directory exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(io, "module");
    try program_directory.dir.writeFile(io, .{ .sub_path = "module/thing.mn", .data = "const VALUE: i32 = 1" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "const VALUE: i32 = 1\nimport module::thing" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = Loader.init(program_path, program_path);

    try std.testing.expectError(error.ReservedImport, loader.loadMainModule(&arena, io, "main"));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, loader.failure.?.location.?);
}
test "buildModuleFileName: gives the module in the directory when there is no file next to it" {
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
    try program_directory.dir.createDirPath(io, "one/two");
    try program_directory.dir.writeFile(io, .{ .sub_path = "one/two/module.mn", .data = "" });

    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "one/two/module.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, &.{ "one", "two" }));
}

test "buildModuleFileName: prefers the file over the module in the directory" {
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
    try program_directory.dir.createDirPath(io, "shapes");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes.mn", .data = "" });

    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "shapes.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, &.{"shapes"}));
}

test "buildModuleFileName: gives the file next to the directory when neither exists" {
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

    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "missing.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, &.{"missing"}));
}

test "findMember: finds nothing for a module that no path names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "mn");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/text.mn", .data = "fn one() = noop" });
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/container.mn", .data = "fn two() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import mn::text\nfn main() = text::one()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try loader.loadMainModule(&arena, io, "main");
    const root = loader.findRoot("mn").?;

    try std.testing.expectEqual(1, loader.findMember(root, "text").?.module.?);
    try std.testing.expectEqual(null, loader.findMember(root, "container"));
    try std.testing.expectEqual(2, loader.modules.items.len);
}

test "hasMember: finds a module and a directory in the directory of a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(io, "shapes/lines");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/circle.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module.mn", .data = "" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = Loader.init(program_path, program_path);
    const allocator = arena.allocator();
    const path: ast.Path = &.{"shapes"};

    try std.testing.expect(try loader.hasMember(allocator, io, path, "circle"));
    try std.testing.expect(try loader.hasMember(allocator, io, path, "lines"));
    try std.testing.expect(!try loader.hasMember(allocator, io, path, "square"));
    try std.testing.expect(!try loader.hasMember(allocator, io, &.{"circle"}, "shapes"));
    try std.testing.expectEqual(0, loader.modules.items.len);
}

test "hasMember: finds nothing for the name module" {
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
    try program_directory.dir.createDirPath(io, "shapes/module");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module.mn", .data = "" });

    try std.testing.expect(!try loader.hasMember(arena.allocator(), io, &.{"shapes"}, "module"));
}

test "loadReferencedModules: loads a module named only by a path in a function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "mn");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/container.mn", .data = "fn one() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import mn\nfn main()\n    mn::container::one()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);

    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(2, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "container" }), loader.modules.items[1].path);
}

test "loadReferencedModules: loads the modules that a loaded module names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "mn");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/text.mn", .data = "fn two() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "import mn as library\nfn one() = library::text::two()" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils::one()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);

    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(3, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), loader.modules.items[1].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "text" }), loader.modules.items[2].path);
}

test "loadReferencedModules: loads mn::range for a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "mn");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/range.mn", .data = "struct Range\n    start: usize" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "fn main()\n    const span = 0..4\n    _ = span" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);

    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(2, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "range" }), loader.modules.items[1].path);
}

test "loadReferencedModules: loads no module of the library for an import of mn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = Loader.init(program_path, "library");
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import mn\nfn main()\n    _ = mn::size(u8)" });

    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(1, loader.modules.items.len);
    try std.testing.expectEqual(null, loader.findRoot("mn").?.module);
}

test "loadNamespace: loads a module at the top" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "fn one() = noop" });
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
    const namespace = (try loader.loadNamespace(&arena, io, &.{"utils"})).?;

    try std.testing.expectEqual(1, namespace.module.?);
    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "utils.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, loader.modules.items[1].path));
}

test "loadNamespace: reads mn from the compiler's directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(io, "mn");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/stdout.mn", .data = "fn one() = noop" });
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
    const namespace = (try loader.loadNamespace(&arena, io, &.{"mn"})).?;

    try std.testing.expectEqual(null, namespace.module);
    try std.testing.expect(namespace.directory);
    _ = try loader.loadNamespace(&arena, io, &.{ "mn", "stdout" });
    const expected = try std.fs.path.join(arena.allocator(), &.{ compiler_path, "mn/stdout.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, loader.modules.items[1].path));
}

test "loadNamespace: gives the language module even without its directory" {
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
    const namespace = (try loader.loadNamespace(&arena, io, &.{"mn"})).?;

    try std.testing.expectEqual(null, namespace.module);
    try std.testing.expect(!namespace.directory);
    try std.testing.expectEqualStrings("mn", namespace.path[0]);
}

test "loadNamespace: finds nothing for a name that is neither a file nor a directory" {
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
    try std.testing.expectEqual(null, try loader.loadNamespace(&arena, io, &.{"missing"}));
}

test "loadNamespace: loads the module of a directory once from the file in it" {
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
    try program_directory.dir.createDirPath(io, "shapes");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module.mn", .data = "fn draw() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const first = (try loader.loadNamespace(&arena, io, &.{"shapes"})).?;
    const second = (try loader.loadNamespace(&arena, io, &.{"shapes"})).?;

    try std.testing.expectEqual(first.module.?, second.module.?);
    try std.testing.expect(first.directory);
    try std.testing.expectEqual(2, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"shapes"}), loader.modules.items[first.module.?].path);
    try std.testing.expectEqual(1, loader.modules.items[first.module.?].declarations.len);
}

test "loadNamespace: keeps a module without a directory as a file" {
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
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes.mn", .data = "fn draw() = noop" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");
    const namespace = (try loader.loadNamespace(&arena, io, &.{"shapes"})).?;

    try std.testing.expect(!namespace.directory);
    try std.testing.expectEqual(1, loader.modules.items[namespace.module.?].declarations.len);
}

test "loadNamespace: rejects a module next to a directory with its name" {
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
    try program_directory.dir.createDirPath(io, "shapes");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectError(error.ModuleNextToDirectory, loader.loadNamespace(&arena, io, &.{"shapes"}));
    try std.testing.expectEqual(null, loader.failure.?.location);
    const file = try std.fs.path.join(arena.allocator(), &.{ program_path, "shapes.mn" });
    const target = try std.fs.path.join(arena.allocator(), &.{ program_path, "shapes/module.mn" });
    const expected = try std.fmt.allocPrint(arena.allocator(), "'{s}' is next to the directory with its name, move it to '{s}'", .{ file, target });
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
    try std.testing.expectEqual(1, loader.modules.items.len);
}

test "loadNamespace: finds nothing for the name module" {
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
    try program_directory.dir.createDirPath(io, "module");
    try program_directory.dir.writeFile(io, .{ .sub_path = "module/module.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "" });
    try loader.loadMainModule(&arena, io, "main");

    try std.testing.expectEqual(null, try loader.loadNamespace(&arena, io, &.{"module"}));
    try std.testing.expectEqual(1, loader.modules.items.len);
}

test "loadNamespace: loads each module once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(io, "utils");
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils/math.mn", .data = "fn add() = noop" });
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
    const first = (try loader.loadNamespace(&arena, io, &.{ "utils", "math" })).?;
    const second = (try loader.loadNamespace(&arena, io, &.{ "utils", "math" })).?;

    try std.testing.expectEqual(first.module.?, second.module.?);
    try std.testing.expectEqual(2, loader.modules.items.len);
}

test "loadNamespace: loads the module of a nested directory from the file in it" {
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
    try program_directory.dir.createDirPath(io, "one/two");
    try program_directory.dir.writeFile(io, .{ .sub_path = "one/two/module.mn", .data = "fn draw() = noop" });
    const one = (try loader.loadNamespace(&arena, io, &.{"one"})).?;
    const two = (try loader.loadNamespace(&arena, io, &.{ "one", "two" })).?;

    try std.testing.expectEqual(null, one.module);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "one", "two" }), loader.modules.items[two.module.?].path);
    try std.testing.expectEqual(1, loader.modules.items[two.module.?].declarations.len);
}

test "loadNamespace: rejects a nested module next to a directory with its name" {
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
    try program_directory.dir.createDirPath(io, "shapes/lines");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/lines.mn", .data = "" });

    try std.testing.expectError(error.ModuleNextToDirectory, loader.loadNamespace(&arena, io, &.{ "shapes", "lines" }));
    try std.testing.expectEqual(null, loader.failure.?.location);
    const file = try std.fs.path.join(arena.allocator(), &.{ program_path, "shapes/lines.mn" });
    const target = try std.fs.path.join(arena.allocator(), &.{ program_path, "shapes/lines/module.mn" });
    const expected = try std.fmt.allocPrint(arena.allocator(), "'{s}' is next to the directory with its name, move it to '{s}'", .{ file, target });
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}

test "loadNamespace: finds nothing for a member named module" {
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
    try program_directory.dir.createDirPath(io, "shapes/module");
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "shapes/module/module.mn", .data = "" });
    _ = try loader.loadNamespace(&arena, io, &.{"shapes"});

    try std.testing.expectEqual(null, try loader.loadNamespace(&arena, io, &.{ "shapes", "module" }));
    try std.testing.expectEqual(1, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"shapes"}), loader.modules.items[0].path);
}

test "loadModule: reports failures in the module they are in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(io, .{ .sub_path = "utils.mn", .data = "fn one()\n\tnoop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import utils" });

    try std.testing.expectError(error.UnexpectedTab, loader.loadMainModule(&arena, io, "main"));
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), loader.failure.?.module.?);
    try std.testing.expectEqual(1, loader.modules.items.len);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, loader.failure.?.location.?);
    try std.testing.expectEqualStrings("tabs are not allowed, use spaces", loader.failure.?.message);
    const expected = try std.fs.path.join(arena.allocator(), &.{ program_path, "utils.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(arena.allocator(), io, loader.failure.?.module.?));
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
    try program_directory.dir.writeFile(io, .{ .sub_path = "main.mn", .data = "import utils" });

    try std.testing.expectError(error.ExpectedBlock, loader.loadMainModule(&arena, io, "main"));
    try std.testing.expectEqualStrings("expected an indented block", loader.failure.?.message);
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
