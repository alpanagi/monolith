const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Lexer = @import("lexer.zig").Lexer;
const LexError = @import("lexer.zig").LexError;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const Failure = core.Failure;

const isName = @import("name.zig").isName;
const isWordCharacter = @import("name.zig").isWordCharacter;
const isWordStart = @import("name.zig").isWordStart;

const runner_module_name = "runner";
const script_module_name = "build";

pub const Loader = struct {
    program_path: []const u8,
    compiler_path: []const u8,
    test_directory: ?TestDirectory = null,
    runner_file: ?[]const u8 = null,
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
        try self.expectProgramLayout(allocator, io);
        const path = try allocator.dupe([]const u8, &.{name});
        _ = try self.loadModule(arena, io, path, try self.buildOuterFileName(allocator, path));
        try self.loadReferencedModules(arena, io);
    }

    pub fn loadTestModules(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        test_path: []const u8,
        is_test_path_optional: bool,
    ) ![]const usize {
        const allocator = arena.allocator();
        try self.expectDirectory(allocator, io, self.program_path);
        try self.expectProgramLayout(allocator, io);
        var paths: std.ArrayList(ast.Path) = .empty;
        const prefix: ast.Path = if (try self.isLibraryDirectory(allocator, io)) &.{"mn"} else &.{};
        try self.collectTestModulePaths(allocator, io, self.program_path, prefix, &paths);
        if (try self.findTestDirectory(allocator, io, test_path, is_test_path_optional)) |test_directory| {
            try self.collectTestModulePaths(allocator, io, test_directory.path, &.{test_directory.name}, &paths);
            self.test_directory = test_directory;
        }
        std.mem.sort(ast.Path, paths.items, {}, isPathBefore);
        for (paths.items) |path| try self.loadPath(arena, io, path);
        const modules = try allocator.alloc(usize, paths.items.len);
        for (paths.items, modules) |path, *module| {
            module.* = self.findNamespace(path[0 .. path.len - 1], path[path.len - 1]).?.module.?;
        }
        try self.loadReferencedModules(arena, io);
        return modules;
    }

    pub fn loadBuildScript(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        runner_file: []const u8,
    ) LoadError!void {
        self.runner_file = runner_file;
        const path = try arena.allocator().dupe([]const u8, &.{runner_module_name});
        _ = try self.loadModule(arena, io, path, runner_file);
        try self.loadReferencedModules(arena, io);
    }

    pub fn buildModuleFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError![]const u8 {
        if (self.isRunnerPath(path)) return self.runner_file.?;
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
        if (self.isScriptPath(path)) return false;
        const member = try std.mem.concat(allocator, []const u8, &.{ path, &.{name} });
        const file = try self.buildOuterFileName(allocator, member);
        if (try isFile(io, file)) return true;
        return isDirectory(io, try self.buildDirectoryName(allocator, member));
    }

    fn expectProgramLayout(self: *Loader, allocator: std.mem.Allocator, io: std.Io) LoadError!void {
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
    }

    fn isLibraryDirectory(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) (std.mem.Allocator.Error || std.Io.Dir.RealPathFileAllocError)!bool {
        const library_path = try std.fs.path.join(allocator, &.{ self.compiler_path, "mn" });
        const library = std.Io.Dir.cwd().realPathFileAlloc(io, library_path, allocator) catch |real_path_error| switch (real_path_error) {
            error.FileNotFound => return false,
            else => return real_path_error,
        };
        const directory = try std.Io.Dir.cwd().realPathFileAlloc(io, self.program_path, allocator);
        return std.mem.eql(u8, library, directory);
    }

    fn expectDirectory(self: *Loader, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |open_error| {
            const message = try std.fmt.allocPrint(allocator, "cannot open '{s}': {t}", .{ path, open_error });
            self.failure = .{ .message = message };
            return open_error;
        };
        directory.close(io);
    }

    fn collectTestModulePaths(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        directory_path: []const u8,
        prefix: ast.Path,
        paths: *std.ArrayList(ast.Path),
    ) !void {
        var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".mn")) continue;
            const file = try std.fs.path.join(allocator, &.{ directory_path, entry.path });
            try paths.append(allocator, try self.buildTestModulePath(allocator, prefix, try allocator.dupe(u8, entry.path), file));
        }
    }

    fn findTestDirectory(
        self: *Loader,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        is_optional: bool,
    ) !?TestDirectory {
        if (is_optional and !try isDirectory(io, path)) return null;
        try self.expectDirectory(allocator, io, path);
        if (try isSameDirectory(allocator, io, self.program_path, path)) return null;
        const name = std.fs.path.basename(path);
        if (!isRootModuleName(name)) {
            const message = try std.fmt.allocPrint(allocator, "'{s}' cannot be a module, its directory name must be a valid name", .{path});
            self.failure = .{ .message = message };
            return error.InvalidModuleName;
        }
        const own_file = try std.fs.path.join(allocator, &.{ self.program_path, try std.mem.concat(allocator, u8, &.{ name, ".mn" }) });
        const own_directory = try std.fs.path.join(allocator, &.{ self.program_path, name });
        const has_file = try isFile(io, own_file);
        if (has_file or try isDirectory(io, own_directory)) {
            const clash = if (has_file) own_file else own_directory;
            const message = try std.fmt.allocPrint(allocator, "'{s}' has the name of the test directory '{s}'", .{ clash, path });
            self.failure = .{ .message = message };
            return error.ReservedModuleName;
        }
        return .{ .path = path, .name = name };
    }

    fn buildTestModulePath(
        self: *Loader,
        allocator: std.mem.Allocator,
        prefix: ast.Path,
        relative: []const u8,
        file: []const u8,
    ) LoadError!ast.Path {
        var path: std.ArrayList([]const u8) = .empty;
        try path.appendSlice(allocator, prefix);
        var names = std.mem.splitScalar(u8, relative[0 .. relative.len - ".mn".len], '/');
        while (names.next()) |name| try path.append(allocator, name);
        if (path.items.len > prefix.len + 1 and isDirectoryModuleName(path.items[path.items.len - 1])) _ = path.pop();
        for (path.items[prefix.len..], prefix.len..) |name, position| {
            const valid = if (position == 0) isRootModuleName(name) else isWord(name) and !std.mem.eql(u8, name, "_") and !isDirectoryModuleName(name);
            if (valid) continue;
            const message = try std.fmt.allocPrint(allocator, "'{s}' cannot be a module, its file name must be a valid name", .{file});
            self.failure = .{ .message = message };
            return error.InvalidModuleName;
        }
        return path.items;
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
        if (self.isScriptPath(path)) return self.loadScriptNamespace(arena, io, path);
        const allocator = arena.allocator();
        const outer_file = try self.buildOuterFileName(allocator, path);
        const inner_file = try self.buildInnerFileName(allocator, path);
        const directory_path = try self.buildDirectoryName(allocator, path);
        const is_test_root = path.len == 1 and self.isTestRoot(path[0]);
        const is_outer_file = !is_test_root and try isFile(io, outer_file);
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

    fn isScriptPath(self: *const Loader, path: ast.Path) bool {
        return self.runner_file != null and !isLanguageModule(path[0]);
    }

    fn isRunnerPath(self: *const Loader, path: ast.Path) bool {
        return self.runner_file != null and path.len == 1 and std.mem.eql(u8, path[0], runner_module_name);
    }

    fn loadScriptNamespace(
        self: *Loader,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        path: ast.Path,
    ) LoadError!?Namespace {
        if (path.len != 1 or !std.mem.eql(u8, path[0], script_module_name)) return null;
        const allocator = arena.allocator();
        const module = try self.loadModule(arena, io, path, try self.buildOuterFileName(allocator, path));
        const namespace: Namespace = .{ .path = path, .module = module, .directory = false };
        try self.namespaces.append(allocator, namespace);
        return namespace;
    }

    fn buildOuterFileName(
        self: *Loader,
        allocator: std.mem.Allocator,
        path: ast.Path,
    ) std.mem.Allocator.Error![]const u8 {
        const directory_path = try self.buildDirectoryName(allocator, path);
        return std.mem.concat(allocator, u8, &.{ directory_path, ".mn" });
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
        if (self.isTestRoot(path[0])) {
            const names = try std.mem.concat(allocator, []const u8, &.{ &.{self.test_directory.?.path}, path[1..] });
            return std.fs.path.join(allocator, names);
        }
        const joined = try std.mem.join(allocator, "/", path);
        return std.fs.path.join(allocator, &.{ self.chooseRoot(path[0]), joined });
    }

    fn isTestRoot(self: *const Loader, name: []const u8) bool {
        const test_directory = self.test_directory orelse return false;
        return std.mem.eql(u8, name, test_directory.name);
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

const TestDirectory = struct {
    path: []const u8,
    name: []const u8,
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
    error{ ReservedModuleName, ModuleNextToDirectory, InvalidModuleName };

pub fn isRootModuleName(name: []const u8) bool {
    return isName(name) and types.findBuiltInType(name) == null and !isLanguageModule(name);
}

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

fn isPathBefore(_: void, left: ast.Path, right: ast.Path) bool {
    for (left[0..@min(left.len, right.len)], right[0..@min(left.len, right.len)]) |left_name, right_name| {
        switch (std.mem.order(u8, left_name, right_name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return left.len < right.len;
}

fn isSameDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    one: []const u8,
    two: []const u8,
) (std.mem.Allocator.Error || std.Io.Dir.RealPathFileAllocError)!bool {
    const real_one = try std.Io.Dir.cwd().realPathFileAlloc(io, one, allocator);
    const real_two = try std.Io.Dir.cwd().realPathFileAlloc(io, two, allocator);
    return std.mem.eql(u8, real_one, real_two);
}

fn isWord(name: []const u8) bool {
    if (name.len == 0 or !isWordStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isWordCharacter(byte)) return false;
    }
    return true;
}

fn isDirectoryModuleName(name: []const u8) bool {
    return std.mem.eql(u8, name, "module");
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

test "loadTestModules: loads every file under the directory in the order of its module path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    var loader = Loader.init(program_path, "library");
    try program_directory.dir.createDirPath(io, "one");
    try program_directory.dir.writeFile(io, .{ .sub_path = "two.mn", .data = "import mn::test::expect" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "one/two.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "one/module.mn", .data = "" });
    try program_directory.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    const modules = try loader.loadTestModules(&arena, io, loader.program_path, false);

    try std.testing.expectEqual(3, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"one"}), loader.modules.items[modules[0]].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "one", "two" }), loader.modules.items[modules[1]].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"two"}), loader.modules.items[modules[2]].path);
    try std.testing.expectEqual(4, loader.modules.items.len);
}

test "loadTestModules: rejects a file whose name cannot be the name of a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    var loader = Loader.init(program_path, "library");
    try program_directory.dir.createDirPath(io, "one");
    try program_directory.dir.writeFile(io, .{ .sub_path = "one/two-three.mn", .data = "" });

    try std.testing.expectError(error.InvalidModuleName, loader.loadTestModules(&arena, io, loader.program_path, false));
    const file = try std.fs.path.join(arena.allocator(), &.{ program_path, "one/two-three.mn" });
    const expected = try std.fmt.allocPrint(arena.allocator(), "'{s}' cannot be a module, its file name must be a valid name", .{file});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}

test "loadTestModules: rejects a directory with its own mn module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    var loader = Loader.init(program_path, "library");
    try program_directory.dir.writeFile(io, .{ .sub_path = "mn.mn", .data = "" });

    try std.testing.expectError(error.ReservedModuleName, loader.loadTestModules(&arena, io, loader.program_path, false));
}

test "loadTestModules: loads the files of the library's directory as modules of mn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const compiler_path = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    try compiler_directory.dir.createDirPath(io, "mn/one");
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/two.mn", .data = "import mn::one" });
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "mn/one/module.mn", .data = "" });
    var loader = Loader.init(try std.fs.path.join(arena.allocator(), &.{ compiler_path, "mn" }), compiler_path);
    const modules = try loader.loadTestModules(&arena, io, loader.program_path, false);

    try std.testing.expectEqual(2, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "one" }), loader.modules.items[modules[0]].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "two" }), loader.modules.items[modules[1]].path);
    try std.testing.expectEqual(2, loader.modules.items.len);
}

test "loadTestModules: loads the files of a separate test directory as modules under its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.createDirPath(io, "tests/parsing");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/index.mn", .data = "" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "tests/fixtures.mn", .data = "import index" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "tests/parsing/numbers.mn", .data = "import tests::fixtures" });
    const test_path = try std.fs.path.join(allocator, &.{ project_path, "tests" });
    var loader = Loader.init(try std.fs.path.join(allocator, &.{ project_path, "source" }), "library");
    const modules = try loader.loadTestModules(&arena, io, test_path, false);

    try std.testing.expectEqual(3, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"index"}), loader.modules.items[modules[0]].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "tests", "fixtures" }), loader.modules.items[modules[1]].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "tests", "parsing", "numbers" }), loader.modules.items[modules[2]].path);
    try std.testing.expectEqual(3, loader.modules.items.len);
    const expected = try std.fs.path.join(allocator, &.{ test_path, "parsing/numbers.mn" });
    try std.testing.expectEqualStrings(expected, try loader.buildModuleFileName(allocator, io, loader.modules.items[modules[2]].path));
}

test "loadTestModules: names the modules of a test directory after the last part of its path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.createDirPath(io, "checks/unit");
    try project_directory.dir.writeFile(io, .{ .sub_path = "checks/unit/one.mn", .data = "" });
    var loader = Loader.init(try std.fs.path.join(allocator, &.{ project_path, "source" }), "library");
    const modules = try loader.loadTestModules(&arena, io, try std.fs.path.join(allocator, &.{ project_path, "checks/unit" }), false);

    try std.testing.expectEqual(1, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "unit", "one" }), loader.modules.items[modules[0]].path);
}

test "loadTestModules: takes each file once when the test directory is the source directory under another path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    try program_directory.dir.createDirPath(io, "two");
    try program_directory.dir.writeFile(io, .{ .sub_path = "one.mn", .data = "" });
    var loader = Loader.init(program_path, "library");
    const modules = try loader.loadTestModules(&arena, io, try std.fs.path.join(allocator, &.{ program_path, "two", ".." }), false);

    try std.testing.expectEqual(1, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"one"}), loader.modules.items[modules[0]].path);
}

test "loadTestModules: loads only the source directory when the test directory it may skip is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/one.mn", .data = "" });
    var loader = Loader.init(try std.fs.path.join(allocator, &.{ project_path, "source" }), "library");
    const modules = try loader.loadTestModules(&arena, io, try std.fs.path.join(allocator, &.{ project_path, "tests" }), true);

    try std.testing.expectEqual(1, modules.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"one"}), loader.modules.items[modules[0]].path);
}

test "loadTestModules: rejects an absent test directory it may not skip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    const test_path = try std.fs.path.join(allocator, &.{ project_path, "tests" });
    var loader = Loader.init(try std.fs.path.join(allocator, &.{ project_path, "source" }), "library");

    try std.testing.expectError(error.FileNotFound, loader.loadTestModules(&arena, io, test_path, false));
    const expected = try std.fmt.allocPrint(allocator, "cannot open '{s}': FileNotFound", .{test_path});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}

test "loadTestModules: rejects an absent source directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "tests");
    const source_path = try std.fs.path.join(allocator, &.{ project_path, "source" });
    var loader = Loader.init(source_path, "library");

    try std.testing.expectError(error.FileNotFound, loader.loadTestModules(&arena, io, try std.fs.path.join(allocator, &.{ project_path, "tests" }), true));
    const expected = try std.fmt.allocPrint(allocator, "cannot open '{s}': FileNotFound", .{source_path});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}

test "loadTestModules: rejects a module and a directory of the source directory with the name of the test directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "one/source");
    try project_directory.dir.createDirPath(io, "one/tests");
    try project_directory.dir.writeFile(io, .{ .sub_path = "one/source/tests.mn", .data = "" });
    try project_directory.dir.createDirPath(io, "two/source/tests");
    try project_directory.dir.createDirPath(io, "two/tests");

    for ([_][]const u8{ "one", "two" }, [_][]const u8{ "tests.mn", "tests" }) |project, clash| {
        const source_path = try std.fs.path.join(allocator, &.{ project_path, project, "source" });
        const test_path = try std.fs.path.join(allocator, &.{ project_path, project, "tests" });
        var loader = Loader.init(source_path, "library");

        try std.testing.expectError(error.ReservedModuleName, loader.loadTestModules(&arena, io, test_path, false));
        const clash_path = try std.fs.path.join(allocator, &.{ source_path, clash });
        const expected = try std.fmt.allocPrint(allocator, "'{s}' has the name of the test directory '{s}'", .{ clash_path, test_path });
        try std.testing.expectEqualStrings(expected, loader.failure.?.message);
    }
}

test "loadTestModules: rejects a test directory whose name cannot be the name of a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.createDirPath(io, "two-three");
    const test_path = try std.fs.path.join(allocator, &.{ project_path, "two-three" });
    var loader = Loader.init(try std.fs.path.join(allocator, &.{ project_path, "source" }), "library");

    try std.testing.expectError(error.InvalidModuleName, loader.loadTestModules(&arena, io, test_path, false));
    const expected = try std.fmt.allocPrint(allocator, "'{s}' cannot be a module, its directory name must be a valid name", .{test_path});
    try std.testing.expectEqualStrings(expected, loader.failure.?.message);
}

test "loadBuildScript: loads the runner first and build.mn as the module build without the directory build beside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    try project_directory.dir.createDirPath(io, "build/script");
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/module.mn", .data = "not a module" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/script.mn", .data = "not a module" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "fn build() = noop" });
    try compiler_directory.dir.writeFile(io, .{ .sub_path = "runner.mn", .data = "import build\nfn main() = build::build()\nfn other() = build::script::run()" });
    const runner_file = try std.fs.path.join(allocator, &.{ compiler_path, "runner.mn" });
    var loader = Loader.init(project_path, compiler_path);
    try loader.loadBuildScript(&arena, io, runner_file);

    try std.testing.expectEqual(2, loader.modules.items.len);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"runner"}), loader.modules.items[0].path);
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"build"}), loader.modules.items[1].path);
    const script = loader.findRoot("build").?;
    try std.testing.expectEqual(1, script.module.?);
    try std.testing.expect(!script.directory);
    try std.testing.expectEqual(null, loader.findMember(script, "script"));
}

test "loadBuildScript: loads no other module of the project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "source");
    try project_directory.dir.writeFile(io, .{ .sub_path = "source/main.mn", .data = "fn main() = noop" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "helper.mn", .data = "fn help() = noop" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "import helper\nimport runner\nimport source::main\nfn build() = helper::help()" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "runner.mn", .data = "fn main() = noop" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "compiler.mn", .data = "import build\nfn main() = build::build()" });
    var loader = Loader.init(project_path, project_path);
    try loader.loadBuildScript(&arena, io, try std.fs.path.join(allocator, &.{ project_path, "compiler.mn" }));

    try std.testing.expectEqual(2, loader.modules.items.len);
    try std.testing.expectEqual(null, loader.findRoot("helper"));
    try std.testing.expectEqual(null, loader.findRoot("source"));
    try std.testing.expectEqual(null, loader.findRoot("runner"));
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

test "buildModuleFileName: gives the runner's own file for the runner of a build script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "compiler");
    try project_directory.dir.writeFile(io, .{ .sub_path = "runner.mn", .data = "" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "compiler/runner.mn", .data = "import build\nfn main() = noop" });
    const runner_file = try std.fs.path.join(allocator, &.{ project_path, "compiler/runner.mn" });
    var loader = Loader.init(project_path, project_path);
    try loader.loadBuildScript(&arena, io, runner_file);

    try std.testing.expectEqualStrings(runner_file, try loader.buildModuleFileName(allocator, io, &.{"runner"}));
    const script_file = try std.fs.path.join(allocator, &.{ project_path, "build.mn" });
    try std.testing.expectEqualStrings(script_file, try loader.buildModuleFileName(allocator, io, &.{"build"}));
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

test "hasMember: finds nothing in the directory beside build.mn for a build script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const allocator = arena.allocator();
    var project_directory = std.testing.tmpDir(.{});
    defer project_directory.cleanup();
    const project_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &project_directory.sub_path });
    try project_directory.dir.createDirPath(io, "build/build");
    try project_directory.dir.writeFile(io, .{ .sub_path = "build/tests.mn", .data = "" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "build.mn", .data = "fn build() = noop" });
    try project_directory.dir.writeFile(io, .{ .sub_path = "runner.mn", .data = "import build\nfn main() = build::build()" });
    var loader = Loader.init(project_path, project_path);

    try std.testing.expect(try loader.hasMember(allocator, io, &.{"build"}, "tests"));
    try loader.loadBuildScript(&arena, io, try std.fs.path.join(allocator, &.{ project_path, "runner.mn" }));
    try std.testing.expect(!try loader.hasMember(allocator, io, &.{"build"}, "build"));
    try std.testing.expect(!try loader.hasMember(allocator, io, &.{"build"}, "tests"));
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
