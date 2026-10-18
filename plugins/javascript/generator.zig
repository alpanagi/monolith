const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;

const Failure = core.Failure;

pub const Generator = struct {
    program: ast.Program,
    runtime_files: std.ArrayList([]const u8) = .empty,
    module_index: usize = 0,
    depth: usize = 0,
    failure: ?Failure = null,

    pub fn init(program: ast.Program) Generator {
        return .{ .program = program };
    }

    pub fn generate(
        self: *Generator,
        allocator: std.mem.Allocator,
        io: std.Io,
        plugin_path: []const u8,
        output_path: []const u8,
    ) GenerateError!void {
        const files = try self.generateFiles(allocator);

        const plugin_directory = try std.Io.Dir.cwd().openDir(io, plugin_path, .{});
        defer plugin_directory.close(io);
        try std.Io.Dir.cwd().deleteTree(io, output_path);
        const output_directory = try std.Io.Dir.cwd().createDirPathOpen(io, output_path, .{});
        defer output_directory.close(io);

        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |directory_path| {
                try output_directory.createDirPath(io, directory_path);
            }
            try output_directory.writeFile(io, .{ .sub_path = file.path, .data = file.contents });
        }
        for (self.runtime_files.items) |name| {
            const path = try std.mem.concat(allocator, u8, &.{ "runtime/", name });
            try output_directory.createDirPath(io, "runtime");
            try plugin_directory.copyFile(path, output_directory, path, io, .{});
        }
    }

    fn generateFiles(
        self: *Generator,
        allocator: std.mem.Allocator,
    ) GenerateError![]const File {
        try self.checkNames();

        var files: std.ArrayList(File) = .empty;
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            var contents: std.Io.Writer.Allocating = .init(allocator);
            try self.generateModule(allocator, &contents.writer, module);
            const path = try buildOutputFileName(allocator, module.path);
            try files.append(allocator, .{ .path = path, .contents = contents.written() });
        }
        return files.items;
    }

    fn checkNames(self: *Generator) error{NameDefinedInTarget}!void {
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            for (module.declarations) |declaration| try self.checkDeclarationNames(declaration);
        }
    }

    fn checkDeclarationNames(
        self: *Generator,
        declaration: ast.Declaration,
    ) error{NameDefinedInTarget}!void {
        switch (declaration.kind) {
            .function_definition => |function| {
                try self.checkName(function.signature.name, declaration.location);
                for (function.signature.parameters) |parameter| {
                    try self.checkName(parameter.name, parameter.location);
                }
            },
            .function_declaration => |function_declaration| {
                try self.checkName(function_declaration.name, declaration.location);
            },
            .constant_declaration => {},
        }
    }

    fn checkName(
        self: *Generator,
        name: []const u8,
        location: token.Location,
    ) error{NameDefinedInTarget}!void {
        const reserved_words = std.StaticStringMap(void).initComptime(.{
            .{"arguments"},  .{"await"},     .{"break"},      .{"case"},     .{"catch"},
            .{"class"},      .{"const"},     .{"continue"},   .{"debugger"}, .{"default"},
            .{"delete"},     .{"do"},        .{"else"},       .{"enum"},     .{"eval"},
            .{"export"},     .{"extends"},   .{"false"},      .{"finally"},  .{"for"},
            .{"function"},   .{"if"},        .{"implements"}, .{"import"},   .{"in"},
            .{"instanceof"}, .{"interface"}, .{"let"},        .{"new"},      .{"null"},
            .{"package"},    .{"private"},   .{"protected"},  .{"public"},   .{"return"},
            .{"static"},     .{"super"},     .{"switch"},     .{"this"},     .{"throw"},
            .{"true"},       .{"try"},       .{"typeof"},     .{"var"},      .{"void"},
            .{"while"},      .{"with"},      .{"yield"},
        });

        if (!reserved_words.has(name)) return;
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = "name is already defined in the target",
        };
        return error.NameDefinedInTarget;
    }

    fn generateModule(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) GenerateError!void {
        const file = try buildOutputFileName(allocator, module.path);
        var reached: Reached = .{};
        for (module.declarations) |declaration| {
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration => continue,
            };
            for (function.body) |statement| {
                try self.collectReached(allocator, &reached, statement);
            }
        }
        const runtime_functions = reached.runtime_functions.items;
        for (runtime_functions) |name| try self.addRuntimeFile(allocator, name);
        try generateRuntimeImports(allocator, writer, file, runtime_functions);
        var written = runtime_functions.len > 0;
        for (reached.modules.items) |index| {
            const path = self.program.modules[index].path;
            try writer.writeAll("import * as ");
            try generateNamespace(writer, path);
            try writer.print(" from \"{s}\";\n", .{
                try buildImportPath(allocator, file, try buildOutputFileName(allocator, path)),
            });
            written = true;
        }
        for (module.declarations) |declaration| {
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration => continue,
            };
            if (written) try writer.writeByte('\n');
            try self.generateFunction(writer, function);
            written = true;
        }
        if (self.module_index == 0 and hasMain(module)) {
            if (written) try writer.writeByte('\n');
            try writer.writeAll("main();\n");
        }
    }

    fn collectReached(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        statement: ast.Statement,
    ) std.mem.Allocator.Error!void {
        const expression = switch (statement.kind) {
            .noop => return,
            .@"return" => |value| value orelse return,
            .discard, .call => |expression| expression,
        };
        try self.collectReachedOf(allocator, reached, expression);
    }

    fn collectReachedOf(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        expression: ast.Expression,
    ) std.mem.Allocator.Error!void {
        const call = switch (expression.kind) {
            .call => |call| call,
            else => return,
        };
        const function = extractCalledFunction(call);
        const module = function.module;
        switch (self.program.modules[module].declarations[function.declaration].kind) {
            .function_definition => {
                const known = std.mem.findScalar(usize, reached.modules.items, module) != null;
                if (module != self.module_index and !known) {
                    try reached.modules.append(allocator, module);
                }
            },
            .function_declaration => |function_declaration| {
                const name = function_declaration.name;
                const known = containsName(reached.runtime_functions.items, name);
                if (isRuntimeFunction(name) and !known) {
                    try reached.runtime_functions.append(allocator, name);
                }
            },
            .constant_declaration => unreachable,
        }
        for (call.arguments) |argument| {
            try self.collectReachedOf(allocator, reached, argument);
        }
    }

    fn addRuntimeFile(
        self: *Generator,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!void {
        const runtime_file = extractRuntimeFile(name);
        const file = try std.mem.concat(allocator, u8, &.{ runtime_file, ".js" });
        if (containsName(self.runtime_files.items, file)) return;
        try self.runtime_files.append(allocator, file);
    }

    fn generateFunction(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.FunctionDefinition,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("export function ");
        try writer.writeAll(function.signature.name);
        try writer.writeByte('(');
        for (function.signature.parameters, 0..) |parameter, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.writeAll(parameter.name);
        }
        try writer.writeAll(") ");
        try self.generateBlock(writer, function.body);
        try writer.writeByte('\n');
    }

    fn generateBlock(
        self: *Generator,
        writer: *std.Io.Writer,
        block: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        const empty = for (block) |statement| {
            if (statement.kind != .noop) break false;
        } else true;
        if (empty) return writer.writeAll("{}");

        try writer.writeAll("{\n");
        self.depth += 1;
        for (block) |statement| try self.generateStatement(writer, statement);
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeByte('}');
    }

    fn generateStatement(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: ast.Statement,
    ) std.Io.Writer.Error!void {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |value| {
                try self.generateIndentation(writer);
                try writer.writeAll("return");
                if (value) |expression| {
                    try writer.writeByte(' ');
                    try self.generateExpression(writer, expression);
                }
                try writer.writeAll(";\n");
            },
            .discard, .call => |expression| {
                try self.generateIndentation(writer);
                try self.generateExpression(writer, expression);
                try writer.writeAll(";\n");
            },
        }
    }

    fn generateIndentation(self: *Generator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.depth) |_| try writer.writeAll("    ");
    }

    fn generateExpression(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) std.Io.Writer.Error!void {
        switch (expression.kind) {
            .integer_literal, .float_literal => |literal| {
                try writer.writeAll(literal.text);
                switch (expression.type.?.number) {
                    .i64, .u64 => try writer.writeByte('n'),
                    else => {},
                }
            },
            .boolean_literal => |value| try writer.writeAll(if (value) "true" else "false"),
            .string_literal => |text| try writer.print("\"{s}\"", .{text}),
            .identifier => |identifier| switch (identifier.resolution.?) {
                .parameter => try writer.writeAll(identifier.name),
                .constant => |constant| {
                    const module = self.program.modules[constant.module];
                    const kind = module.declarations[constant.declaration].kind;
                    try self.generateExpression(writer, kind.constant_declaration.value);
                },
                .function, .type => unreachable,
            },
            .path_expression => |path_expression| switch (path_expression.resolution.?) {
                .constant => |constant| {
                    const module = self.program.modules[constant.module];
                    const kind = module.declarations[constant.declaration].kind;
                    try self.generateExpression(writer, kind.constant_declaration.value);
                },
                .parameter, .function, .type => unreachable,
            },
            .call => |call| {
                try self.generateCallee(writer, extractCalledFunction(call));
                try writer.writeByte('(');
                for (call.arguments, 0..) |argument, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, argument);
                }
                try writer.writeByte(')');
            },
        }
    }

    fn generateCallee(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.Resolution.Function,
    ) std.Io.Writer.Error!void {
        const module = self.program.modules[function.module];
        switch (module.declarations[function.declaration].kind) {
            .function_definition => |target| {
                if (function.module != self.module_index) {
                    try generateNamespace(writer, module.path);
                    try writer.writeByte('.');
                }
                try writer.writeAll(target.signature.name);
            },
            .function_declaration => |function_declaration| {
                try writer.writeAll(function_declaration.name);
            },
            .constant_declaration => unreachable,
        }
    }
};

pub const GenerateError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.DeleteTreeError ||
    std.Io.Dir.CreateDirPathOpenError ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.WriteFileError ||
    std.Io.Dir.CopyFileError ||
    error{NameDefinedInTarget};

const File = struct {
    path: []const u8,
    contents: []const u8,
};

const Reached = struct {
    modules: std.ArrayList(usize) = .empty,
    runtime_functions: std.ArrayList([]const u8) = .empty,
};

fn generateRuntimeImports(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    file: []const u8,
    runtime_functions: []const []const u8,
) GenerateError!void {
    var runtime_files: std.ArrayList([]const u8) = .empty;
    for (runtime_functions) |name| {
        const runtime_file = extractRuntimeFile(name);
        if (!containsName(runtime_files.items, runtime_file)) {
            try runtime_files.append(allocator, runtime_file);
        }
    }
    for (runtime_files.items) |runtime_file| {
        try writer.writeAll("import { ");
        var first = true;
        for (runtime_functions) |name| {
            if (!std.mem.eql(u8, extractRuntimeFile(name), runtime_file)) continue;
            if (!first) try writer.writeAll(", ");
            try writer.writeAll(name);
            first = false;
        }
        const target = try std.mem.concat(allocator, u8, &.{ "runtime/", runtime_file, ".js" });
        try writer.print(" }} from \"{s}\";\n", .{try buildImportPath(allocator, file, target)});
    }
}

fn buildOutputFileName(
    allocator: std.mem.Allocator,
    path: ast.Path,
) std.mem.Allocator.Error![]const u8 {
    return std.mem.concat(allocator, u8, &.{ try std.mem.join(allocator, "/", path), ".js" });
}

fn buildImportPath(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const path = try buildRelativePath(allocator, from, to);
    if (std.mem.startsWith(u8, path, "../")) return path;
    return std.mem.concat(allocator, u8, &.{ "./", path });
}

fn generateNamespace(writer: *std.Io.Writer, path: ast.Path) std.Io.Writer.Error!void {
    try writer.writeAll("mn_");
    for (path, 0..) |name, index| {
        if (index > 0) try writer.writeByte('_');
        try writer.writeAll(name);
    }
}

fn hasMain(module: ast.Module) bool {
    for (module.declarations) |declaration| {
        const function = switch (declaration.kind) {
            .function_definition => |function| function,
            .function_declaration, .constant_declaration => continue,
        };
        if (std.mem.eql(u8, function.signature.name, "main")) return true;
    }
    return false;
}

fn extractCalledFunction(call: ast.Call) ast.Resolution.Function {
    return switch (call.callee) {
        inline else => |callee| callee.resolution.?.function,
    };
}

fn buildRelativePath(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var from_directories = std.mem.splitScalar(u8, std.fs.path.dirname(from) orelse "", '/');
    var to_parts = std.mem.splitScalar(u8, to, '/');
    var result: std.ArrayList(u8) = .empty;
    while (from_directories.peek()) |directory| {
        if (directory.len == 0) break;
        const part = to_parts.peek() orelse break;
        if (!std.mem.eql(u8, directory, part) or to_parts.rest().len == part.len) break;
        _ = from_directories.next();
        _ = to_parts.next();
    }
    while (from_directories.next()) |directory| {
        if (directory.len > 0) try result.appendSlice(allocator, "../");
    }
    try result.appendSlice(allocator, to_parts.rest());
    return result.items;
}

fn isRuntimeFunction(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mn_");
}

fn extractRuntimeFile(name: []const u8) []const u8 {
    const rest = name["mn_".len..];
    const end = std.mem.findScalar(u8, rest, '_') orelse rest.len;
    return rest[0..end];
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

test "Generator.generate: writes the modules and the runtime files they use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    var plugin_directory = std.testing.tmpDir(.{});
    defer plugin_directory.cleanup();
    var output_directory = std.testing.tmpDir(.{});
    defer output_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn mn_console_write(text: String)\nconst write = mn_console_write" });
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/console.js", .data = "export function mn_console_write() {}" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/unused.js", .data = "unused" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::console::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const plugin_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &plugin_directory.sub_path });
    const output_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &output_directory.sub_path, "build" });
    try output_directory.dir.createDirPath(std.testing.io, "build");
    try output_directory.dir.writeFile(std.testing.io, .{ .sub_path = "build/old.txt", .data = "old" });
    try generator.generate(allocator, std.testing.io, plugin_path, output_path);

    try std.testing.expectEqualStrings("export function mn_console_write() {}", try output_directory.dir.readFileAlloc(std.testing.io, "build/runtime/console.js", allocator, .unlimited));
    try std.testing.expect(std.mem.startsWith(u8, try output_directory.dir.readFileAlloc(std.testing.io, "build/main.js", allocator, .unlimited), "import { mn_console_write }"));
    try std.testing.expectError(error.FileNotFound, output_directory.dir.readFileAlloc(std.testing.io, "build/runtime/unused.js", allocator, .unlimited));
    try std.testing.expectError(error.FileNotFound, output_directory.dir.readFileAlloc(std.testing.io, "build/old.txt", allocator, .unlimited));
}

test "Generator.generate: leaves the output alone when a name is defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var output_directory = std.testing.tmpDir(.{});
    defer output_directory.cleanup();
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn delete(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const output_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &output_directory.sub_path, "build" });
    try output_directory.dir.createDirPath(std.testing.io, "build");
    try output_directory.dir.writeFile(std.testing.io, .{ .sub_path = "build/old.txt", .data = "old" });

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(allocator, std.testing.io, program_path, output_path));
    try std.testing.expectEqualStrings("old", try output_directory.dir.readFileAlloc(std.testing.io, "build/old.txt", allocator, .unlimited));
}

test "generateFiles: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two():\n    noop\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function one() {}\n\nexport function two() {}\n", files[0].contents);
}

test "generateFiles: calls main after all functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): helper()\nfn helper(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "export function main() {\n    helper();\n}\n\nexport function helper() {}\n\nmain();\n",
        files[0].contents,
    );
}

test "generateFiles: writes nothing for external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn log(value: i32)\nfn one(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "export function one() {}\n",
        files[0].contents,
    );
}

test "generateFiles: writes one file per module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(value: i32): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqual(2, files.len);
    try std.testing.expectEqualStrings("main.js", files[0].path);
    try std.testing.expectEqualStrings(
        "import * as mn_utils from \"./utils.js\";\n\nexport function main() {\n    mn_utils.add(1);\n}\n\nmain();\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings("utils.js", files[1].path);
    try std.testing.expectEqualStrings(
        "export function add(value) {}\n",
        files[1].contents,
    );
}

test "checkDeclarationNames: rejects function names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn delete(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, generator.failure.?.location.?);
    try std.testing.expectEqualStrings("name is already defined in the target", generator.failure.?.message);
}

test "checkDeclarationNames: rejects external function names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn delete()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, generator.failure.?.location.?);
}

test "checkDeclarationNames: rejects parameter names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, new: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, generator.failure.?.location.?);
}

test "checkDeclarationNames: ignores parameter names of external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write(new: i32)\nfn main(): write(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "export function main() {\n    write(1);\n}\n\nmain();\n",
        files[0].contents,
    );
}

test "checkName: matches whole names only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn delete_(): noop\nfn new(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, generator.failure.?.location.?);
}

test "generateModule: imports a module reached through a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::math::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "import * as mn_utils_math from \"./utils/math.js\";\n\nexport function main() {\n    mn_utils_math.add();\n}\n\nmain();\n",
        files[0].contents,
    );
}

test "collectReachedOf: imports each module once in the order of the first call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop" });
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    utils::one()\n    utils::math::add()\n    utils::one()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "import * as mn_utils from \"./utils.js\";\nimport * as mn_utils_math from \"./utils/math.js\";\n\nexport function main() {\n    mn_utils.one();\n    mn_utils_math.add();\n    mn_utils.one();\n}\n\nmain();\n",
        files[0].contents,
    );
}

test "collectReachedOf: imports runtime functions from their runtime file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn show(): std::console::write(\"hi\")" });
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn mn_console_write(text: String)\nexternal fn mn_console_flush()\nconst write = mn_console_write\nconst flush = mn_console_flush" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::math::show()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "import { mn_console_write } from \"../runtime/console.js\";\n\nexport function show() {\n    mn_console_write(\"hi\");\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqual(1, generator.runtime_files.items.len);
    try std.testing.expectEqualStrings("console.js", generator.runtime_files.items[0]);
}

test "generateFunction: generates an empty function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function main() {}\n\nmain();\n", files[0].contents);
}

test "generateFunction: writes parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) i32: return left" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function add(left, right) {\n    return left;\n}\n", files[0].contents);
}

test "generateBlock: writes statements on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32:\n    noop\n    return 42\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function answer() {\n    return 42;\n}\n", files[0].contents);
}

test "generateStatement: writes return without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn stop(): return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function stop() {\n    return;\n}\n", files[0].contents);
}

test "generateStatement: writes calls and discards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(value: i32): noop\nfn one() i32: return 1\nfn main():\n    log(one())\n    _ = one()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function log(value) {}\n\nexport function one() {\n    return 1;\n}\n\nexport function main() {\n    log(one());\n    one();\n}\n\nmain();\n", files[0].contents);
}

test "generateExpression: keeps the base and drops the suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() u32: return 0xff_FF_u32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function mask() {\n    return 0xff_FF;\n}\n", files[0].contents);
}

test "generateExpression: writes booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn ready() Bool: return false" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function ready() {\n    return false;\n}\n", files[0].contents);
}

test "generateExpression: writes 64-bit integers as BigInt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn big() i64: return 1\nfn huge() u64: return 0xffff_ffff_ffff_ffff" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function big() {\n    return 1n;\n}\n\nexport function huge() {\n    return 0xffff_ffff_ffff_ffffn;\n}\n", files[0].contents);
}

test "generateExpression: writes 64-bit arguments as BigInt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i64): noop\nfn main(): take(5)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function take(value) {}\n\nexport function main() {\n    take(5n);\n}\n\nmain();\n", files[0].contents);
}

test "generateExpression: writes strings as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() String: return \"line\\n\\\"quoted\\\"\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function greeting() {\n    return \"line\\n\\\"quoted\\\"\";\n}\n", files[0].contents);
}

test "generateExpression: writes the value of a constant at its use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
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
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "limits.mn", .data = "const maximum = 7u64" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() u64: return limits::maximum" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("export function mask() {\n    return 7n;\n}\n", files[0].contents);
}

test "generateCallee: calls external functions of the program by their name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "external fn log(text: String)" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::log(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "export function main() {\n    log(\"hi\");\n}\n\nmain();\n",
        files[0].contents,
    );
    try std.testing.expectEqual(0, generator.runtime_files.items.len);
}

test "generateRuntimeImports: imports the functions of one runtime file together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn mn_console_write(text: String)\nexternal fn mn_console_flush()\nconst write = mn_console_write\nconst flush = mn_console_flush" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    std::console::write(\"hi\")\n    std::console::flush()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "import { mn_console_write, mn_console_flush } from \"./runtime/console.js\";\n\nexport function main() {\n    mn_console_write(\"hi\");\n    mn_console_flush();\n}\n\nmain();\n",
        files[0].contents,
    );
}

test "buildRelativePath: walks into directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try buildRelativePath(arena.allocator(), "hello.js", "std/console.js");
    try std.testing.expectEqualStrings("std/console.js", path);
}

test "buildRelativePath: walks out of directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const path = try buildRelativePath(allocator, "std/console.h", "monolith.h");
    try std.testing.expectEqualStrings("../monolith.h", path);
    const runtime = try buildRelativePath(allocator, "utils/math/add.js", "runtime/console.js");
    try std.testing.expectEqualStrings("../../runtime/console.js", runtime);
}

test "buildRelativePath: keeps a file named like a directory apart from it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try buildRelativePath(arena.allocator(), "utils.js", "utils/math.js");
    try std.testing.expectEqualStrings("utils/math.js", path);
}

test "isRuntimeFunction: recognizes the reserved prefix" {
    try std.testing.expect(isRuntimeFunction("mn_console_write"));
    try std.testing.expect(!isRuntimeFunction("console_write"));
}

test "extractRuntimeFile: takes the file from the name" {
    try std.testing.expectEqualStrings("console", extractRuntimeFile("mn_console_write"));
    try std.testing.expectEqualStrings("exit", extractRuntimeFile("mn_exit"));
}

test "containsName: matches whole names only" {
    try std.testing.expect(containsName(&.{ "console", "file" }, "file"));
    try std.testing.expect(!containsName(&.{"console"}, "consol"));
}
