const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

pub const Generator = struct {
    program: ast.Program,
    runtime_files: std.ArrayList([]const u8) = .empty,
    names: []const []const ?[]const u8 = &.{},
    module_index: usize = 0,
    depth: usize = 0,
    in_main: bool = false,
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
        try self.buildExecutable(allocator, io, output_directory, files);
    }

    fn generateFiles(
        self: *Generator,
        allocator: std.mem.Allocator,
    ) GenerateError![]const File {
        self.names = try buildCNames(allocator, self.program);
        try self.checkNames();

        var files: std.ArrayList(File) = .empty;
        try self.runtime_files.append(allocator, "monolith.h");
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            const path = try std.mem.join(allocator, "/", module.path);

            var header_contents: std.Io.Writer.Allocating = .init(allocator);
            const header_path = try std.mem.concat(allocator, u8, &.{ path, ".h" });
            try self.generateHeader(allocator, &header_contents.writer, header_path, module);
            try files.append(allocator, .{
                .path = header_path,
                .contents = header_contents.written(),
            });

            var source_contents: std.Io.Writer.Allocating = .init(allocator);
            const source_path = try std.mem.concat(allocator, u8, &.{ path, ".c" });
            try self.generateSource(allocator, &source_contents.writer, source_path, module);
            try files.append(allocator, .{
                .path = source_path,
                .contents = source_contents.written(),
            });
        }
        return files.items;
    }

    fn buildExecutable(
        self: *Generator,
        allocator: std.mem.Allocator,
        io: std.Io,
        output_directory: std.Io.Dir,
        files: []const File,
    ) GenerateError!void {
        const main_module = self.program.modules[0];
        const has_main = for (main_module.declarations) |declaration| {
            if (declaration.kind != .function_definition) continue;
            const name = declaration.kind.function_definition.signature.name;
            if (std.mem.eql(u8, name, "main")) break true;
        } else false;
        if (!has_main) return;

        var arguments: std.ArrayList([]const u8) = .empty;
        const flags = &.{ "gcc", "-std=c23", "-Wall", "-Wextra", "-pedantic", "-O2", "-flto" };
        try arguments.appendSlice(allocator, flags);
        for (files) |file| {
            if (std.mem.endsWith(u8, file.path, ".c")) try arguments.append(allocator, file.path);
        }
        for (self.runtime_files.items) |name| {
            if (!std.mem.endsWith(u8, name, ".c")) continue;
            const path = try std.mem.concat(allocator, u8, &.{ "runtime/", name });
            try arguments.append(allocator, path);
        }
        try arguments.appendSlice(allocator, &.{ "-o", main_module.path[0] });

        var compiler = std.process.spawn(io, .{
            .argv = arguments.items,
            .cwd = .{ .dir = output_directory },
            .stdin = .ignore,
        }) catch |spawn_error| {
            const format = "cannot run gcc: {t}";
            const message = try std.fmt.allocPrint(allocator, format, .{spawn_error});
            self.failure = .{ .message = message };
            return spawn_error;
        };
        const term = try compiler.wait(io);
        if (term != .exited or term.exited != 0) {
            self.failure = .{ .message = "gcc could not build the executable" };
            return error.CompilerFailed;
        }
    }

    fn checkNames(self: *Generator) error{NameDefinedInTarget}!void {
        for (self.program.modules, 0..) |module, module_index| {
            self.module_index = module_index;
            for (module.declarations, 0..) |declaration, index| {
                const signature = switch (declaration.kind) {
                    .function_definition => |function| function.signature,
                    .function_declaration => |function_declaration| function_declaration,
                    .constant_declaration => continue,
                };
                const name = self.names[module_index][index].?;
                try self.checkName(name, declaration.location);
                for (signature.parameters) |parameter| {
                    try self.checkName(parameter.name, parameter.location);
                }
            }
        }
    }

    fn checkName(
        self: *Generator,
        name: []const u8,
        location: token.Location,
    ) error{NameDefinedInTarget}!void {
        const reserved_words = std.StaticStringMap(void).initComptime(.{
            .{"INT16_C"},                   .{"INT16_MAX"},          .{"INT16_MIN"},
            .{"INT16_WIDTH"},               .{"INT32_C"},            .{"INT32_MAX"},
            .{"INT32_MIN"},                 .{"INT32_WIDTH"},        .{"INT64_C"},
            .{"INT64_MAX"},                 .{"INT64_MIN"},          .{"INT64_WIDTH"},
            .{"INT8_C"},                    .{"INT8_MAX"},           .{"INT8_MIN"},
            .{"INT8_WIDTH"},                .{"INTMAX_C"},           .{"INTMAX_MAX"},
            .{"INTMAX_MIN"},                .{"INTMAX_WIDTH"},       .{"INTPTR_MAX"},
            .{"INTPTR_MIN"},                .{"INTPTR_WIDTH"},       .{"INT_FAST16_MAX"},
            .{"INT_FAST16_MIN"},            .{"INT_FAST16_WIDTH"},   .{"INT_FAST32_MAX"},
            .{"INT_FAST32_MIN"},            .{"INT_FAST32_WIDTH"},   .{"INT_FAST64_MAX"},
            .{"INT_FAST64_MIN"},            .{"INT_FAST64_WIDTH"},   .{"INT_FAST8_MAX"},
            .{"INT_FAST8_MIN"},             .{"INT_FAST8_WIDTH"},    .{"INT_LEAST16_MAX"},
            .{"INT_LEAST16_MIN"},           .{"INT_LEAST16_WIDTH"},  .{"INT_LEAST32_MAX"},
            .{"INT_LEAST32_MIN"},           .{"INT_LEAST32_WIDTH"},  .{"INT_LEAST64_MAX"},
            .{"INT_LEAST64_MIN"},           .{"INT_LEAST64_WIDTH"},  .{"INT_LEAST8_MAX"},
            .{"INT_LEAST8_MIN"},            .{"INT_LEAST8_WIDTH"},   .{"MONOLITH_H"},
            .{"NULL"},                      .{"PTRDIFF_MAX"},        .{"PTRDIFF_MIN"},
            .{"PTRDIFF_WIDTH"},             .{"SIG_ATOMIC_MAX"},     .{"SIG_ATOMIC_MIN"},
            .{"SIG_ATOMIC_WIDTH"},          .{"SIZE_MAX"},           .{"SIZE_WIDTH"},
            .{"UINT16_C"},                  .{"UINT16_MAX"},         .{"UINT16_WIDTH"},
            .{"UINT32_C"},                  .{"UINT32_MAX"},         .{"UINT32_WIDTH"},
            .{"UINT64_C"},                  .{"UINT64_MAX"},         .{"UINT64_WIDTH"},
            .{"UINT8_C"},                   .{"UINT8_MAX"},          .{"UINT8_WIDTH"},
            .{"UINTMAX_C"},                 .{"UINTMAX_MAX"},        .{"UINTMAX_WIDTH"},
            .{"UINTPTR_MAX"},               .{"UINTPTR_WIDTH"},      .{"UINT_FAST16_MAX"},
            .{"UINT_FAST16_WIDTH"},         .{"UINT_FAST32_MAX"},    .{"UINT_FAST32_WIDTH"},
            .{"UINT_FAST64_MAX"},           .{"UINT_FAST64_WIDTH"},  .{"UINT_FAST8_MAX"},
            .{"UINT_FAST8_WIDTH"},          .{"UINT_LEAST16_MAX"},   .{"UINT_LEAST16_WIDTH"},
            .{"UINT_LEAST32_MAX"},          .{"UINT_LEAST32_WIDTH"}, .{"UINT_LEAST64_MAX"},
            .{"UINT_LEAST64_WIDTH"},        .{"UINT_LEAST8_MAX"},    .{"UINT_LEAST8_WIDTH"},
            .{"WCHAR_MAX"},                 .{"WCHAR_MIN"},          .{"WCHAR_WIDTH"},
            .{"WINT_MAX"},                  .{"WINT_MIN"},           .{"WINT_WIDTH"},
            .{"_Alignas"},                  .{"_Alignof"},           .{"_Atomic"},
            .{"_BitInt"},                   .{"_Bool"},              .{"_Complex"},
            .{"_Decimal128"},               .{"_Decimal32"},         .{"_Decimal64"},
            .{"_Generic"},                  .{"_Imaginary"},         .{"_Noreturn"},
            .{"_Static_assert"},            .{"_Thread_local"},      .{"__STDC_VERSION_STDDEF_H__"},
            .{"__STDC_VERSION_STDINT_H__"}, .{"alignas"},            .{"alignof"},
            .{"asm"},                       .{"auto"},               .{"bool"},
            .{"break"},                     .{"case"},               .{"char"},
            .{"const"},                     .{"constexpr"},          .{"continue"},
            .{"default"},                   .{"do"},                 .{"double"},
            .{"else"},                      .{"enum"},               .{"extern"},
            .{"false"},                     .{"float"},              .{"for"},
            .{"goto"},                      .{"if"},                 .{"inline"},
            .{"int"},                       .{"int16_t"},            .{"int32_t"},
            .{"int64_t"},                   .{"int8_t"},             .{"int_fast16_t"},
            .{"int_fast32_t"},              .{"int_fast64_t"},       .{"int_fast8_t"},
            .{"int_least16_t"},             .{"int_least32_t"},      .{"int_least64_t"},
            .{"int_least8_t"},              .{"intmax_t"},           .{"intptr_t"},
            .{"long"},                      .{"max_align_t"},        .{"nullptr"},
            .{"nullptr_t"},                 .{"offsetof"},           .{"ptrdiff_t"},
            .{"register"},                  .{"restrict"},           .{"return"},
            .{"short"},                     .{"signed"},             .{"size_t"},
            .{"sizeof"},                    .{"static"},             .{"static_assert"},
            .{"string"},                    .{"struct"},             .{"switch"},
            .{"thread_local"},              .{"true"},               .{"typedef"},
            .{"typeof"},                    .{"typeof_unqual"},      .{"uint16_t"},
            .{"uint32_t"},                  .{"uint64_t"},           .{"uint8_t"},
            .{"uint_fast16_t"},             .{"uint_fast32_t"},      .{"uint_fast64_t"},
            .{"uint_fast8_t"},              .{"uint_least16_t"},     .{"uint_least32_t"},
            .{"uint_least64_t"},            .{"uint_least8_t"},      .{"uintmax_t"},
            .{"uintptr_t"},                 .{"union"},              .{"unreachable"},
            .{"unsigned"},                  .{"void"},               .{"volatile"},
            .{"wchar_t"},                   .{"while"},
        });

        if (!reserved_words.has(name)) return;
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = "name is already defined in the target",
        };
        return error.NameDefinedInTarget;
    }

    fn generateHeader(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        path: []const u8,
        module: ast.Module,
    ) GenerateError!void {
        const include = try buildRelativePath(allocator, path, "runtime/monolith.h");
        try writer.print("#include \"{s}\"\n", .{include});
        try self.generateDeclarations(writer, module, .function_declaration);
        try self.generateDeclarations(writer, module, .function_definition);
    }

    fn generateDeclarations(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
        kind: std.meta.Tag(ast.DeclarationKind),
    ) std.Io.Writer.Error!void {
        var declared = false;
        for (module.declarations, 0..) |declaration, index| {
            if (declaration.kind != kind or self.isEntryPoint(declaration.kind)) continue;
            if (!declared) try writer.writeByte('\n');
            try self.generateSignature(writer, declaration.kind, index);
            try writer.writeAll(";\n");
            declared = true;
        }
    }

    fn generateSource(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        path: []const u8,
        module: ast.Module,
    ) GenerateError!void {
        const own_header = try std.mem.concat(allocator, u8, &.{ path[0 .. path.len - 2], ".h" });
        try writer.print("#include \"{s}\"\n", .{std.fs.path.basename(own_header)});
        var reached: std.ArrayList(usize) = .empty;
        for (module.declarations) |declaration| {
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration => continue,
            };
            for (function.body) |statement| {
                try self.collectReachedModules(allocator, &reached, statement);
            }
        }
        for (reached.items) |index| {
            const target = try std.mem.join(allocator, "/", self.program.modules[index].path);
            const target_header = try std.mem.concat(allocator, u8, &.{ target, ".h" });
            const include = try buildRelativePath(allocator, path, target_header);
            try writer.print("#include \"{s}\"\n", .{include});
        }

        for (module.declarations, 0..) |declaration, index| {
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration => continue,
            };
            try writer.writeByte('\n');
            try self.generateFunction(writer, function, index);
        }
    }

    fn collectReachedModules(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *std.ArrayList(usize),
        statement: ast.Statement,
    ) std.mem.Allocator.Error!void {
        const expression = switch (statement.kind) {
            .noop => return,
            .@"return" => |value| value orelse return,
            .discard, .call => |expression| expression,
        };
        try self.collectReachedModulesOf(allocator, reached, expression);
    }

    fn collectReachedModulesOf(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *std.ArrayList(usize),
        expression: ast.Expression,
    ) std.mem.Allocator.Error!void {
        const call = switch (expression.kind) {
            .call => |call| call,
            else => return,
        };
        const function = switch (call.callee) {
            inline else => |callee| callee.resolution.?.function,
        };
        const module = function.module;
        const known = std.mem.findScalar(usize, reached.items, module) != null;
        if (module != self.module_index and !known) try reached.append(allocator, module);
        switch (self.program.modules[module].declarations[function.declaration].kind) {
            .function_declaration => |function_declaration| {
                if (isRuntimeFunction(function_declaration.name)) {
                    try self.addRuntimeFile(allocator, function_declaration.name);
                }
            },
            .function_definition, .constant_declaration => {},
        }
        for (call.arguments) |argument| {
            try self.collectReachedModulesOf(allocator, reached, argument);
        }
    }

    fn addRuntimeFile(
        self: *Generator,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) std.mem.Allocator.Error!void {
        const file = try std.mem.concat(allocator, u8, &.{ extractRuntimeFile(name), ".c" });
        if (containsName(self.runtime_files.items, file)) return;
        try self.runtime_files.append(allocator, file);
    }

    fn generateFunction(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.FunctionDefinition,
        index: usize,
    ) std.Io.Writer.Error!void {
        self.in_main = self.isEntryPoint(.{ .function_definition = function });
        try self.generateSignature(writer, .{ .function_definition = function }, index);
        try writer.writeByte(' ');
        try self.generateBlock(writer, function.body);
        try writer.writeByte('\n');
    }

    fn generateSignature(
        self: *Generator,
        writer: *std.Io.Writer,
        kind: ast.DeclarationKind,
        index: usize,
    ) std.Io.Writer.Error!void {
        if (self.isEntryPoint(kind)) return writer.writeAll("int main()");
        const signature = switch (kind) {
            .function_definition => |function| function.signature,
            .function_declaration => |function_declaration| function_declaration,
            .constant_declaration => unreachable,
        };
        try generateType(writer, ast.extractType(signature.return_type));
        try writer.writeByte(' ');
        try writer.writeAll(self.names[self.module_index][index].?);
        try generateParameters(writer, signature.parameters);
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
                } else if (self.in_main) {
                    try writer.writeAll(" 0");
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
                var text = literal.text;
                if (std.mem.startsWith(u8, text, "0o")) {
                    try writer.writeByte('0');
                    text = text[2..];
                }
                for (text) |byte| try writer.writeByte(if (byte == '_') '\'' else byte);
                switch (expression.type.?.number) {
                    .u8, .u16, .u32, .u64 => try writer.writeByte('u'),
                    else => {},
                }
            },
            .boolean_literal => |value| try writer.writeAll(if (value) "true" else "false"),
            .string_literal => |text| {
                try writer.print("(string){{ \"{s}\", {d} }}", .{ text, countBytes(text) });
            },
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
                const function = switch (call.callee) {
                    inline else => |callee| callee.resolution.?.function,
                };
                try writer.writeAll(self.names[function.module][function.declaration].?);
                try writer.writeByte('(');
                for (call.arguments, 0..) |argument, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, argument);
                }
                try writer.writeByte(')');
            },
        }
    }

    fn isEntryPoint(self: *Generator, kind: ast.DeclarationKind) bool {
        if (self.module_index != 0 or kind != .function_definition) return false;
        return std.mem.eql(u8, kind.function_definition.signature.name, "main");
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
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    error{ NameDefinedInTarget, CompilerFailed };

const File = struct {
    path: []const u8,
    contents: []const u8,
};

fn buildCNames(
    allocator: std.mem.Allocator,
    program: ast.Program,
) std.mem.Allocator.Error![]const []const ?[]const u8 {
    const names = try allocator.alloc([]const ?[]const u8, program.modules.len);
    for (program.modules, 0..) |module, module_index| {
        const module_names = try allocator.alloc(?[]const u8, module.declarations.len);
        for (module.declarations, 0..) |declaration, index| {
            module_names[index] = try buildCName(allocator, module_index, module, declaration);
        }
        names[module_index] = module_names;
    }
    return names;
}

fn buildCName(
    allocator: std.mem.Allocator,
    module_index: usize,
    module: ast.Module,
    declaration: ast.Declaration,
) std.mem.Allocator.Error!?[]const u8 {
    switch (declaration.kind) {
        .function_definition => |function| {
            const name = function.signature.name;
            if (module_index == 0 and std.mem.eql(u8, name, "main")) return name;
            return try buildQualifiedName(allocator, module.path, name);
        },
        .function_declaration => |function_declaration| return function_declaration.name,
        .constant_declaration => return null,
    }
}

fn buildQualifiedName(
    allocator: std.mem.Allocator,
    path: ast.Path,
    name: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const joined = try std.mem.join(allocator, "_", path);
    return std.mem.concat(allocator, u8, &.{ "mn_", joined, "_", name });
}

fn generateParameters(
    writer: *std.Io.Writer,
    parameters: []const ast.Parameter,
) std.Io.Writer.Error!void {
    try writer.writeByte('(');
    for (parameters, 0..) |parameter, index| {
        if (index > 0) try writer.writeAll(", ");
        try generateType(writer, ast.extractType(parameter.type));
        try writer.writeByte(' ');
        try writer.writeAll(parameter.name);
    }
    try writer.writeByte(')');
}

fn generateType(writer: *std.Io.Writer, value_type: types.Type) std.Io.Writer.Error!void {
    try writer.writeAll(switch (value_type) {
        .number => |number| switch (number) {
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .f32 => "float",
            .f64 => "double",
        },
        .boolean => "bool",
        .string => "string",
        .void => "void",
        .type => unreachable,
    });
}

fn countBytes(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        index += if (text[index] == '\\') 2 else 1;
    }
    return count;
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
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/monolith.h", .data = "header" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/console.c", .data = "console" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/unused.c", .data = "unused" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): std::console::write(\"hi\")" });
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

    try std.testing.expectEqualStrings("header", try output_directory.dir.readFileAlloc(std.testing.io, "build/runtime/monolith.h", allocator, .unlimited));
    try std.testing.expectEqualStrings("console", try output_directory.dir.readFileAlloc(std.testing.io, "build/runtime/console.c", allocator, .unlimited));
    try std.testing.expect(std.mem.startsWith(u8, try output_directory.dir.readFileAlloc(std.testing.io, "build/main.c", allocator, .unlimited), "#include \"main.h\""));
    try std.testing.expectError(error.FileNotFound, output_directory.dir.readFileAlloc(std.testing.io, "build/runtime/unused.c", allocator, .unlimited));
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(int32_t: i32): noop" });
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

test "Generator.generate: builds an executable when the main module defines main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    var output_directory = std.testing.tmpDir(.{});
    defer output_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn mn_console_write(text: String)\nconst write = mn_console_write" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "hello.mn", .data = "fn main(): std::console::write(\"hi\\n\")" });
    try loader.loadMainModule(&arena, std.testing.io, "hello");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const output_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &output_directory.sub_path, "build" });
    try generator.generate(allocator, std.testing.io, "plugins/c", output_path);

    const executable = try output_directory.dir.statFile(std.testing.io, "build/hello", .{});
    try std.testing.expectEqual(.file, executable.kind);
}

test "generateFiles: writes a header and a source file per module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop\nfn two():\n    noop\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqual(2, files.len);
    try std.testing.expectEqualStrings("monolith.h", generator.runtime_files.items[0]);
    try std.testing.expectEqualStrings("main.h", files[0].path);
    try std.testing.expectEqualStrings(
        "#include \"runtime/monolith.h\"\n\nvoid mn_main_two();\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings("main.c", files[1].path);
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint main() {}\n\nvoid mn_main_two() {}\n",
        files[1].contents,
    );
}

test "generateFiles: includes the headers of the modules it calls" {
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

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"utils.h\"\n\nint main() {\n    mn_utils_add(1);\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"runtime/monolith.h\"\n\nvoid mn_utils_add(int32_t value);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"utils.h\"\n\nvoid mn_utils_add(int32_t value) {}\n",
        files[3].contents,
    );
}

test "generateFiles: writes the standard library at its module path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn mn_console_write(text: String)\nconst write = mn_console_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::console::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"std/console.h\"\n\nint main() {\n    mn_console_write((string){ \"hi\", 2 });\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings("std/console.h", files[2].path);
    try std.testing.expectEqualStrings(
        "#include \"../runtime/monolith.h\"\n\nvoid mn_console_write(string text);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings("std/console.c", files[3].path);
    try std.testing.expectEqualStrings("#include \"console.h\"\n", files[3].contents);
    try std.testing.expectEqual(2, generator.runtime_files.items.len);
    try std.testing.expectEqualStrings("console.c", generator.runtime_files.items[1]);
}

test "checkNames: names functions after their module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn int(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_int() {}\n",
        files[1].contents,
    );
}

test "checkNames: rejects external function names defined in the target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn int()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, generator.failure.?.location.?);
    try std.testing.expectEqualStrings("name is already defined in the target", generator.failure.?.message);
}

test "checkNames: rejects parameter names defined in the target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, char: i32): noop" });
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

test "checkName: rejects the string type name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(string: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, generator.failure.?.location.?);
}

test "checkName: rejects the header guard name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(MONOLITH_H: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, generator.failure.?.location.?);
}

test "checkName: rejects names from the included headers" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(size_t: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, generator.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(int_: i32, int: i32): noop" });
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

test "generateDeclarations: separates external functions from other functions" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nexternal fn log(value: i32)\nfn two(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"runtime/monolith.h\"\n\nvoid log(int32_t value);\n\nvoid mn_main_one();\nvoid mn_main_two();\n",
        files[0].contents,
    );
}

test "generateFunction: generates main as the entry point" {
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

    try std.testing.expectEqualStrings("#include \"runtime/monolith.h\"\n", files[0].contents);
    try std.testing.expectEqualStrings("#include \"main.h\"\n\nint main() {}\n", files[1].contents);
}

test "generateSignature: keeps the names of external functions" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn print_(text: String)\nfn main(): print_(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"runtime/monolith.h\"\n\nvoid print_(string text);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint main() {\n    print_((string){ \"hi\", 2 });\n}\n",
        files[1].contents,
    );
}

test "generateSignature: names main of other modules like any function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn main(): noop\nfn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"runtime/monolith.h\"\n\nvoid mn_utils_main();\nvoid mn_utils_one();\n",
        files[2].contents,
    );
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn stop():\n    noop\n    return\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_stop() {\n    return;\n}\n",
        files[1].contents,
    );
}

test "generateStatement: returns zero from main" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint main() {\n    return 0;\n}\n",
        files[1].contents,
    );
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

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_log(int32_t value) {}\n\nint32_t mn_main_one() {\n    return 1;\n}\n\nint main() {\n    mn_main_log(mn_main_one());\n    mn_main_one();\n}\n",
        files[1].contents,
    );
}

test "generateExpression: converts separators and octal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mode() u16: return 0o7_5_5\nfn big() u32: return 1_000" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nuint16_t mn_main_mode() {\n    return 07'5'5u;\n}\n\nuint32_t mn_main_big() {\n    return 1'000u;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: marks unsigned literals" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() u8: return 0xff\nfn big() u64: return 18446744073709551615" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nuint8_t mn_main_mask() {\n    return 0xffu;\n}\n\nuint64_t mn_main_big() {\n    return 18446744073709551615u;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: leaves signed literals unmarked" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn big() i64: return 9223372036854775807" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint64_t mn_main_big() {\n    return 9223372036854775807;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: marks unsigned arguments" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small(value: u8): noop\nfn main(): small(255)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_small(uint8_t value) {}\n\nint main() {\n    mn_main_small(255u);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes strings with their length in bytes" {
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

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nstring mn_main_greeting() {\n    return (string){ \"line\\n\\\"quoted\\\"\", 13 };\n}\n",
        files[1].contents,
    );
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() u8: return limit\nconst limit = 0xff_u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nuint8_t mn_main_mask() {\n    return 0xffu;\n}\n",
        files[1].contents,
    );
}

test "generateType: maps floating point types" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn half() f32: return 0.5\nfn whole() f64: return 1.0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nfloat mn_main_half() {\n    return 0.5;\n}\n\ndouble mn_main_whole() {\n    return 1.0;\n}\n",
        files[1].contents,
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
