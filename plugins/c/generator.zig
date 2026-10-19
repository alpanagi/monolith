const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

pub const Generator = struct {
    program: ast.Program,
    runtime_functions: std.ArrayList([]const u8) = .empty,
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
        const source_directory = try output_directory.createDirPathOpen(io, "source", .{});
        defer source_directory.close(io);

        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |directory_path| {
                try source_directory.createDirPath(io, directory_path);
            }
            try source_directory.writeFile(io, .{ .sub_path = file.path, .data = file.contents });
        }
        const runtime_files = try self.collectRuntimeFiles(allocator, io, plugin_directory);
        for (runtime_files) |path| {
            try source_directory.createDirPath(io, std.fs.path.dirname(path).?);
            try plugin_directory.copyFile(path, source_directory, path, io, .{});
        }
        try self.buildExecutable(allocator, io, source_directory, files, runtime_files);
    }

    fn collectRuntimeFiles(
        self: *Generator,
        allocator: std.mem.Allocator,
        io: std.Io,
        plugin_directory: std.Io.Dir,
    ) GenerateError![]const []const u8 {
        var runtime_files: std.ArrayList([]const u8) = .empty;
        try runtime_files.append(allocator, "runtime/monolith.h");
        for (self.runtime_functions.items) |name| {
            const path = try findRuntimeFile(allocator, io, plugin_directory, name);
            if (!containsName(runtime_files.items, path)) try runtime_files.append(allocator, path);
        }
        return runtime_files.items;
    }

    fn generateFiles(
        self: *Generator,
        allocator: std.mem.Allocator,
    ) GenerateError![]const File {
        self.names = try buildCNames(allocator, self.program);
        try self.checkNames();
        try self.checkStructCycles(allocator);

        var files: std.ArrayList(File) = .empty;
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

            const defines_functions = for (module.declarations) |declaration| {
                if (declaration.kind == .function_definition) break true;
            } else false;
            if (!defines_functions) continue;

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
        source_directory: std.Io.Dir,
        files: []const File,
        runtime_files: []const []const u8,
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
        for (runtime_files) |path| {
            if (std.mem.endsWith(u8, path, ".c")) try arguments.append(allocator, path);
        }
        const executable_path = try std.mem.concat(allocator, u8, &.{ "../", main_module.path[0] });
        try arguments.appendSlice(allocator, &.{ "-o", executable_path });

        var compiler = std.process.spawn(io, .{
            .argv = arguments.items,
            .cwd = .{ .dir = source_directory },
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

        const type_registry = self.program.types;
        for (type_registry.entries.items) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            self.module_index = struct_type.module;
            for (struct_type.fields) |field| try self.checkName(field.name, field.location);
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

    fn checkStructCycles(self: *Generator, allocator: std.mem.Allocator) GenerateError!void {
        const type_registry = self.program.types;
        for (type_registry.entries.items) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            if (isZeroSized(value_type)) continue;
            for (struct_type.fields) |field| {
                const target = findContainedModule(field.type) orelse continue;
                if (target == struct_type.module) continue;
                var visited: std.ArrayList(usize) = .empty;
                const cyclic =
                    try self.reachesModule(allocator, &visited, target, struct_type.module);
                if (!cyclic) continue;
                self.failure = .{
                    .module = self.program.modules[struct_type.module].path,
                    .location = field.location,
                    .message = "modules contain each other's structs",
                };
                return error.StructsContainEachOther;
            }
        }
    }

    fn reachesModule(
        self: *Generator,
        allocator: std.mem.Allocator,
        visited: *std.ArrayList(usize),
        from: usize,
        to: usize,
    ) std.mem.Allocator.Error!bool {
        if (from == to) return true;
        if (std.mem.findScalar(usize, visited.items, from) != null) return false;
        try visited.append(allocator, from);
        for (try self.collectContainedModules(allocator, from)) |next| {
            if (try self.reachesModule(allocator, visited, next, to)) return true;
        }
        return false;
    }

    fn generateHeader(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        path: []const u8,
        module: ast.Module,
    ) GenerateError!void {
        try writer.writeAll("#pragma once\n\n");
        const include = try buildRelativePath(allocator, path, "runtime/monolith.h");
        try writer.print("#include \"{s}\"\n", .{include});
        const contained = try self.collectContainedModules(allocator, self.module_index);
        for (contained) |index| {
            const contained_include = try buildModuleInclude(allocator, path, self.program, index);
            try writer.print("#include \"{s}\"\n", .{contained_include});
        }
        for (try self.collectStructs(allocator, self.module_index)) |value_type| {
            try writer.writeByte('\n');
            try self.generateStruct(writer, value_type);
        }
        try self.generateForwardDeclarations(allocator, writer, module, contained);
        try self.generateDeclarations(writer, module, .function_declaration);
        try self.generateDeclarations(writer, module, .function_definition);
    }

    fn collectContainedModules(
        self: *Generator,
        allocator: std.mem.Allocator,
        module_index: usize,
    ) std.mem.Allocator.Error![]const usize {
        var contained: std.ArrayList(usize) = .empty;
        for (try self.collectStructs(allocator, module_index)) |value_type| {
            for (value_type.@"struct".fields) |field| {
                const target = findContainedModule(field.type) orelse continue;
                const known = std.mem.findScalar(usize, contained.items, target) != null;
                if (target != module_index and !known) try contained.append(allocator, target);
            }
        }
        return contained.items;
    }

    fn collectStructs(
        self: *Generator,
        allocator: std.mem.Allocator,
        module_index: usize,
    ) std.mem.Allocator.Error![]const types.Type {
        var ordered: std.ArrayList(types.Type) = .empty;
        const type_registry = self.program.types;
        for (type_registry.entries.items) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            if (struct_type.module != module_index or isZeroSized(value_type)) continue;
            try self.orderStruct(allocator, &ordered, value_type);
        }
        return ordered.items;
    }

    fn orderStruct(
        self: *Generator,
        allocator: std.mem.Allocator,
        ordered: *std.ArrayList(types.Type),
        value_type: types.Type,
    ) std.mem.Allocator.Error!void {
        if (containsType(ordered.items, value_type)) return;
        const struct_type = value_type.@"struct";
        for (struct_type.fields) |field| {
            const target = findContainedModule(field.type) orelse continue;
            if (target != struct_type.module) continue;
            try self.orderStruct(allocator, ordered, field.type);
        }
        try ordered.append(allocator, value_type);
    }

    fn generateStruct(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("typedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n");
        for (value_type.@"struct".fields) |field| {
            if (isZeroSized(field.type)) continue;
            try writer.writeAll("    ");
            try self.generateType(writer, field.type);
            try writer.print(" {s};\n", .{field.name});
        }
        try writer.writeAll("} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n");
    }

    fn generateForwardDeclarations(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        module: ast.Module,
        contained: []const usize,
    ) GenerateError!void {
        var declared: std.ArrayList(types.Type) = .empty;
        for (module.declarations) |declaration| {
            const signature = switch (declaration.kind) {
                .function_definition => |function| function.signature,
                .function_declaration => |function_declaration| function_declaration,
                .constant_declaration => continue,
            };
            for (signature.parameters) |parameter| {
                const parameter_type = ast.extractType(parameter.type);
                try self.collectForeignStruct(allocator, &declared, contained, parameter_type);
            }
            const return_type = ast.extractType(signature.return_type);
            try self.collectForeignStruct(allocator, &declared, contained, return_type);
        }
        if (declared.items.len > 0) try writer.writeByte('\n');
        for (declared.items) |value_type| {
            try writer.writeAll("typedef struct ");
            try self.generateType(writer, value_type);
            try writer.writeByte(' ');
            try self.generateType(writer, value_type);
            try writer.writeAll(";\n");
        }
    }

    fn collectForeignStruct(
        self: *Generator,
        allocator: std.mem.Allocator,
        declared: *std.ArrayList(types.Type),
        contained: []const usize,
        value_type: types.Type,
    ) std.mem.Allocator.Error!void {
        const module = findContainedModule(value_type) orelse return;
        if (module == self.module_index) return;
        if (std.mem.findScalar(usize, contained, module) != null) return;
        if (containsType(declared.items, value_type)) return;
        try declared.append(allocator, value_type);
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
            for (function.signature.parameters) |parameter| {
                try self.collectStructModule(allocator, &reached, ast.extractType(parameter.type));
            }
            const return_type = ast.extractType(function.signature.return_type);
            try self.collectStructModule(allocator, &reached, return_type);
            for (function.body) |statement| {
                try self.collectReachedModules(allocator, &reached, statement);
            }
        }
        for (reached.items) |index| {
            const include = try buildModuleInclude(allocator, path, self.program, index);
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
        if (expression.type) |value_type| {
            try self.collectStructModule(allocator, reached, value_type);
        }
        const call = switch (expression.kind) {
            .call => |call| call,
            .field_access => |access| {
                return self.collectReachedModulesOf(allocator, reached, access.value.*);
            },
            else => return,
        };
        switch (ast.extractResolution(call.callee)) {
            .function => |function| try self.collectCalledFunction(allocator, reached, function),
            .type => {},
            .parameter, .constant => unreachable,
        }
        for (call.arguments) |argument| {
            try self.collectReachedModulesOf(allocator, reached, argument.value);
        }
    }

    fn collectCalledFunction(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *std.ArrayList(usize),
        function: ast.Resolution.Function,
    ) std.mem.Allocator.Error!void {
        const module = function.module;
        const known = std.mem.findScalar(usize, reached.items, module) != null;
        if (module != self.module_index and !known) try reached.append(allocator, module);
        switch (self.program.modules[module].declarations[function.declaration].kind) {
            .function_declaration => |function_declaration| {
                const name = function_declaration.name;
                const recorded = containsName(self.runtime_functions.items, name);
                if (isRuntimeFunction(name) and !recorded) {
                    try self.runtime_functions.append(allocator, name);
                }
            },
            .function_definition, .constant_declaration => {},
        }
    }

    fn collectStructModule(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *std.ArrayList(usize),
        value_type: types.Type,
    ) std.mem.Allocator.Error!void {
        const module = findContainedModule(value_type) orelse return;
        const known = std.mem.findScalar(usize, reached.items, module) != null;
        if (module != self.module_index and !known) try reached.append(allocator, module);
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
        try self.generateType(writer, ast.extractType(signature.return_type));
        try writer.writeByte(' ');
        try writer.writeAll(self.names[self.module_index][index].?);
        try self.generateParameters(writer, signature.parameters);
    }

    fn generateParameters(
        self: *Generator,
        writer: *std.Io.Writer,
        parameters: []const ast.TypedName,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        var written = false;
        for (parameters) |parameter| {
            const parameter_type = ast.extractType(parameter.type);
            if (isZeroSized(parameter_type)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateType(writer, parameter_type);
            try writer.writeByte(' ');
            try writer.writeAll(parameter.name);
            written = true;
        }
        try writer.writeByte(')');
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
                const returned = value orelse {
                    try self.generateIndentation(writer);
                    return writer.writeAll(if (self.in_main) "return 0;\n" else "return;\n");
                };
                if (isZeroSized(returned.type.?)) {
                    if (hasEffects(returned)) {
                        try self.generateIndentation(writer);
                        try self.generateEffects(writer, returned);
                        try writer.writeAll(";\n");
                    }
                    try self.generateIndentation(writer);
                    return writer.writeAll("return;\n");
                }
                try self.generateIndentation(writer);
                try writer.writeAll("return ");
                try self.generateExpression(writer, returned);
                try writer.writeAll(";\n");
            },
            .discard, .call => |expression| {
                try self.generateExpressionStatement(writer, expression);
            },
        }
    }

    fn generateExpressionStatement(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) std.Io.Writer.Error!void {
        try self.generateIndentation(writer);
        try self.generateExpression(writer, expression);
        try writer.writeAll(";\n");
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
                const hoists = for (call.arguments) |argument| {
                    if (isHoisted(argument.value)) break true;
                } else false;
                if (hoists) {
                    try writer.writeByte('(');
                    for (call.arguments) |argument| {
                        if (!isHoisted(argument.value)) continue;
                        try self.generateEffects(writer, argument.value);
                        try writer.writeAll(", ");
                    }
                }
                switch (ast.extractResolution(call.callee)) {
                    .function => |function| try self.generateFunctionCall(writer, call, function),
                    .type => |value_type| try self.generateConstruction(writer, call, value_type),
                    .parameter, .constant => unreachable,
                }
                if (hoists) try writer.writeByte(')');
            },
            .field_access => |access| {
                try self.generateExpression(writer, access.value.*);
                try writer.print(".{s}", .{access.field});
            },
            .@"struct" => unreachable,
        }
    }

    fn generateFunctionCall(
        self: *Generator,
        writer: *std.Io.Writer,
        call: ast.Call,
        function: ast.Resolution.Function,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(self.names[function.module][function.declaration].?);
        try writer.writeByte('(');
        var written = false;
        for (call.arguments) |argument| {
            if (isZeroSized(argument.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateExpression(writer, argument.value);
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateConstruction(
        self: *Generator,
        writer: *std.Io.Writer,
        call: ast.Call,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        try self.generateType(writer, value_type);
        try writer.writeAll("){ ");
        var written = false;
        for (call.arguments) |argument| {
            if (isZeroSized(argument.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{argument.name.?});
            try self.generateExpression(writer, argument.value);
            written = true;
        }
        try writer.writeAll(" }");
    }

    fn generateType(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        if (isZeroSized(value_type)) return writer.writeAll("void");
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
            .@"struct" => |struct_type| {
                try writer.writeAll("mn_");
                for (self.program.modules[struct_type.module].path) |part| {
                    try writer.print("{s}_", .{part});
                }
                return writer.writeAll(struct_type.name);
            },
        });
    }

    fn generateEffects(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) std.Io.Writer.Error!void {
        switch (expression.kind) {
            .call => |call| {
                if (ast.extractResolution(call.callee) == .function) {
                    return self.generateExpression(writer, expression);
                }
                var written = false;
                for (call.arguments) |argument| {
                    if (!hasEffects(argument.value)) continue;
                    if (written) try writer.writeAll(", ");
                    try self.generateEffects(writer, argument.value);
                    written = true;
                }
            },
            .field_access => |access| try self.generateEffects(writer, access.value.*),
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .identifier,
            .path_expression,
            .@"struct",
            => unreachable,
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
    std.Io.Dir.AccessError ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    error{ NameDefinedInTarget, StructsContainEachOther, CompilerFailed };

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

fn findContainedModule(field_type: types.Type) ?usize {
    if (isZeroSized(field_type)) return null;
    const struct_type = findStruct(field_type) orelse return null;
    return struct_type.module;
}

fn isHoisted(argument: ast.Expression) bool {
    return isZeroSized(argument.type.?) and hasEffects(argument);
}

fn hasEffects(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .call => |call| {
            if (ast.extractResolution(call.callee) == .function) return true;
            for (call.arguments) |argument| {
                if (hasEffects(argument.value)) return true;
            }
            return false;
        },
        .field_access => |access| hasEffects(access.value.*),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .identifier,
        .path_expression,
        => false,
        .@"struct" => unreachable,
    };
}

fn isZeroSized(value_type: types.Type) bool {
    const struct_type = findStruct(value_type) orelse return false;
    for (struct_type.fields) |field| {
        if (!isZeroSized(field.type)) return false;
    }
    return true;
}

fn findStruct(value_type: types.Type) ?types.Struct {
    return switch (value_type) {
        .@"struct" => |struct_type| struct_type,
        .number, .boolean, .string, .void, .type => null,
    };
}

fn countBytes(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        index += if (text[index] == '\\') 2 else 1;
    }
    return count;
}

fn buildModuleInclude(
    allocator: std.mem.Allocator,
    path: []const u8,
    program: ast.Program,
    module_index: usize,
) std.mem.Allocator.Error![]const u8 {
    const target = try std.mem.join(allocator, "/", program.modules[module_index].path);
    const target_header = try std.mem.concat(allocator, u8, &.{ target, ".h" });
    return buildRelativePath(allocator, path, target_header);
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

fn findRuntimeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    plugin_directory: std.Io.Dir,
    name: []const u8,
) (std.mem.Allocator.Error || std.Io.Dir.AccessError)![]const u8 {
    const parts = name["mn_".len..];
    var end = std.mem.findScalar(u8, parts, '_');
    while (end) |index| : (end = std.mem.findScalarPos(u8, parts, index + 1, '_')) {
        const path = try std.mem.concat(allocator, u8, &.{ parts[0..index], ".c" });
        std.mem.replaceScalar(u8, path, '_', '/');
        plugin_directory.access(io, path, .{}) catch |access_error| switch (access_error) {
            error.FileNotFound => continue,
            else => return access_error,
        };
        return path;
    }
    return error.FileNotFound;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |existing| {
        if (std.mem.eql(u8, existing, name)) return true;
    }
    return false;
}

fn containsType(value_types: []const types.Type, value_type: types.Type) bool {
    for (value_types) |existing| {
        if (std.meta.eql(existing, value_type)) return true;
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: String)\nconst write = mn_runtime_stdout_write" });
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/monolith.h", .data = "header" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/stdout.c", .data = "stdout" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/unused.c", .data = "unused" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): std::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const plugin_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &plugin_directory.sub_path });
    const output_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &output_directory.sub_path, "build" });
    try output_directory.dir.createDirPath(std.testing.io, "build");
    try output_directory.dir.writeFile(std.testing.io, .{ .sub_path = "build/old.txt", .data = "old" });
    try generator.generate(allocator, std.testing.io, plugin_path, output_path);

    try std.testing.expectEqualStrings("header", try output_directory.dir.readFileAlloc(std.testing.io, "build/source/runtime/monolith.h", allocator, .unlimited));
    try std.testing.expectEqualStrings("stdout", try output_directory.dir.readFileAlloc(std.testing.io, "build/source/runtime/stdout.c", allocator, .unlimited));
    try std.testing.expect(std.mem.startsWith(u8, try output_directory.dir.readFileAlloc(std.testing.io, "build/source/main.c", allocator, .unlimited), "#include \"main.h\""));
    try std.testing.expectError(error.FileNotFound, output_directory.dir.readFileAlloc(std.testing.io, "build/source/runtime/unused.c", allocator, .unlimited));
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: String)\nconst write = mn_runtime_stdout_write" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "hello.mn", .data = "fn main(): std::stdout::write(\"hi\\n\")" });
    try loader.loadMainModule(&arena, std.testing.io, "hello");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqual(2, files.len);
    try std.testing.expectEqualStrings("main.h", files[0].path);
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_main_two();\n",
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"utils.h\"\n\nint main() {\n    mn_utils_add(1);\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_utils_add(int32_t value);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"utils.h\"\n\nvoid mn_utils_add(int32_t value) {}\n",
        files[3].contents,
    );
}

test "generateFiles: includes the headers of the structs its functions use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "const Line = struct:\n    width: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nvoid mn_main_show(mn_shapes_Line line) {}\n",
        files[1].contents,
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: String)\nconst write = mn_runtime_stdout_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"std/stdout.h\"\n\nint main() {\n    mn_runtime_stdout_write((string){ \"hi\", 2 });\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings("std/stdout.h", files[2].path);
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"../runtime/monolith.h\"\n\nvoid mn_runtime_stdout_write(string text);\n",
        files[2].contents,
    );
    try std.testing.expectEqual(3, files.len);
    try std.testing.expectEqual(1, generator.runtime_functions.items.len);
    try std.testing.expectEqualStrings("mn_runtime_stdout_write", generator.runtime_functions.items[0]);
}

test "generateFiles: includes the headers of the modules a field access reaches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "const Line = struct:\n    width: i32\nexternal fn make() Line" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn width() i32: return shapes::make().width" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("main.c", files[1].path);
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nint32_t mn_main_width() {\n    return make().width;\n}\n",
        files[1].contents,
    );
}

test "generateFiles: includes the headers of the structs that constants build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "const Point = struct:\n    x: i32\nconst origin = Point(x = 0)" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() i32: return shapes::origin.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nint32_t mn_main_make() {\n    return (mn_shapes_Point){ .x = 0 }.x;\n}\n",
        files[1].contents,
    );
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, generator.failure.?.location.?);
}

test "checkNames: rejects field names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Point = struct:\n    int: i32\nfn show(point: Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, generator.failure.?.location.?);
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, generator.failure.?.location.?);
}

test "checkStructCycles: rejects modules that contain each other's structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "first.mn", .data = "const One = struct:\n    two: second::Two\nconst Zero = struct:\n    value: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "second.mn", .data = "const Two = struct:\n    zero: first::Zero" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: first::One): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.StructsContainEachOther, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqualStrings("modules contain each other's structs", generator.failure.?.message);
    try std.testing.expectEqual(loader.modules.items[2].path, generator.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, generator.failure.?.location.?);
}

test "generateHeader: defines the used structs in the order they depend on each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Line = struct:\n    start: Point\n    end: Point\nconst Point = struct:\n    x: i32\nconst Unused = struct:\n    z: i32\nfn show(line: Line): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Point {\n    int32_t x;\n} mn_main_Point;\n\ntypedef struct mn_main_Line {\n    mn_main_Point start;\n    mn_main_Point end;\n} mn_main_Line;\n\nvoid mn_main_show(mn_main_Line line);\n",
        files[0].contents,
    );
}

test "generateHeader: includes the headers of the modules whose structs it contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "const Line = struct:\n    start: points::Point" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "points.mn", .data = "const Point = struct:\n    x: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n#include \"points.h\"\n\ntypedef struct mn_shapes_Line {\n    mn_points_Point start;\n} mn_shapes_Line;\n",
        files[2].contents,
    );
}

test "generateStruct: leaves out fields of zero-sized types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nconst Tagged = struct:\n    marker: Marker\n    value: i32\nfn show(tagged: Tagged): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Tagged {\n    int32_t value;\n} mn_main_Tagged;\n\nvoid mn_main_show(mn_main_Tagged tagged);\n",
        files[0].contents,
    );
}

test "generateForwardDeclarations: declares the structs of other modules that signatures use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "const Line = struct:\n    width: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_shapes_Line mn_shapes_Line;\n\nvoid mn_main_show(mn_shapes_Line line);\n",
        files[0].contents,
    );
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid log(int32_t value);\n\nvoid mn_main_one();\nvoid mn_main_two();\n",
        files[0].contents,
    );
}

test "collectReachedModulesOf: records the runtime functions that a field access calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/clock.mn", .data = "const Time = struct:\n    seconds: i64\nexternal fn mn_runtime_clock_now() Time\nconst now = mn_runtime_clock_now" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn seconds() i64: return std::clock::now().seconds" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    _ = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqual(1, generator.runtime_functions.items.len);
    try std.testing.expectEqualStrings("mn_runtime_clock_now", generator.runtime_functions.items[0]);
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings("#pragma once\n\n#include \"runtime/monolith.h\"\n", files[0].contents);
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid print_(string text);\n",
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_utils_main();\nvoid mn_utils_one();\n",
        files[2].contents,
    );
}

test "generateParameters: leaves out parameters of zero-sized types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nfn show(marker: Marker, value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_main_show(int32_t value);\n",
        files[0].contents,
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_log(int32_t value) {}\n\nint32_t mn_main_one() {\n    return 1;\n}\n\nint main() {\n    mn_main_log(mn_main_one());\n    mn_main_one();\n}\n",
        files[1].contents,
    );
}

test "generateStatement: calls a zero-sized value before returning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nfn make(marker: Marker) Marker: return marker\nfn pass(marker: Marker) Marker: return make(marker)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_pass() {\n    mn_main_make();\n    return;\n}\n",
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nuint8_t mn_main_mask() {\n    return 0xffu;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: moves zero-sized calls out of the arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nfn make(marker: Marker) Marker: return marker\nfn use(marker: Marker, value: i32): noop\nfn run(marker: Marker): use(make(marker), 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_use(int32_t value) {}\n\nvoid mn_main_run() {\n    (mn_main_make(), mn_main_use(1));\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes field accesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Point = struct:\n    x: i32\nconst Line = struct:\n    start: Point\nexternal fn make() Line\nfn read(line: Line) i32: return line.start.x\nfn first() i32: return make().start.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_read(mn_main_Line line) {\n    return line.start.x;\n}\n\nint32_t mn_main_first() {\n    return make().start.x;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a constructed constant at each use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Point = struct:\n    x: i32\n    y: i32\nconst Line = struct:\n    start: Point\n    end: Point\nconst origin = Point(x = 0, y = 0)\nfn make() Line: return Line(start = origin, end = origin)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Line mn_main_make() {\n    return (mn_main_Line){ .start = (mn_main_Point){ .x = 0, .y = 0 }, .end = (mn_main_Point){ .x = 0, .y = 0 } };\n}\n",
        files[1].contents,
    );
}

test "generateConstruction: writes a compound literal for each struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Point = struct:\n    x: i32\n    y: i32\nconst Line = struct:\n    start: Point\n    end: Point\nfn make() Line: return Line(start = Point(x = 0, y = 0), end = Point(y = 2, x = 1))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Line mn_main_make() {\n    return (mn_main_Line){ .start = (mn_main_Point){ .x = 0, .y = 0 }, .end = (mn_main_Point){ .y = 2, .x = 1 } };\n}\n",
        files[1].contents,
    );
}

test "generateConstruction: leaves out zero-sized fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nconst Holder = struct:\n    marker: Marker\n    value: i32\nconst Wrapper = struct:\n    marker: Marker\nfn make() Holder: return Holder(marker = Marker(), value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Holder mn_main_make() {\n    return (mn_main_Holder){ .value = 1 };\n}\n",
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nfloat mn_main_half() {\n    return 0.5;\n}\n\ndouble mn_main_whole() {\n    return 1.0;\n}\n",
        files[1].contents,
    );
}

test "generateEffects: runs the calls of a zero-sized field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nconst Holder = struct:\n    marker: Marker\n    value: i32\nexternal fn make() Holder\nfn use(marker: Marker, value: i32): noop\nfn take(holder: Holder) Marker: return holder.marker\nfn get() Marker: return make().marker\nfn main(): use(make().marker, 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_use(int32_t value) {}\n\nvoid mn_main_take(mn_main_Holder holder) {\n    return;\n}\n\nvoid mn_main_get() {\n    make();\n    return;\n}\n\nint main() {\n    (make(), mn_main_use(1));\n}\n",
        files[1].contents,
    );
}

test "generateEffects: runs the calls in a zero-sized construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nconst Holder = struct:\n    marker: Marker\n    value: i32\nconst Wrapper = struct:\n    marker: Marker\nfn mark() Marker: return Marker()\nfn use(wrapper: Wrapper, value: i32): noop\nfn main():\n    use(Wrapper(marker = mark()), 1)\n    use(Wrapper(marker = Marker()), 2)\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_mark() {\n    return;\n}\n\nvoid mn_main_use(int32_t value) {}\n\nint main() {\n    (mn_main_mark(), mn_main_use(1));\n    mn_main_use(2);\n}\n",
        files[1].contents,
    );
}

test "isHoisted: leaves out zero-sized fields that call nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Marker = struct\nconst Holder = struct:\n    marker: Marker\n    value: i32\nfn use(marker: Marker, value: i32): noop\nfn pass(holder: Holder): use(holder.marker, 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_use(int32_t value) {}\n\nvoid mn_main_pass(mn_main_Holder holder) {\n    mn_main_use(1);\n}\n",
        files[1].contents,
    );
}

test "buildRelativePath: walks into directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try buildRelativePath(arena.allocator(), "hello.c", "std/stdout.h");
    try std.testing.expectEqualStrings("std/stdout.h", path);
}

test "buildRelativePath: walks out of directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const path = try buildRelativePath(allocator, "std/stdout.h", "monolith.h");
    try std.testing.expectEqualStrings("../monolith.h", path);
    const runtime = try buildRelativePath(allocator, "utils/math/add.c", "runtime/monolith.h");
    try std.testing.expectEqualStrings("../../runtime/monolith.h", runtime);
}

test "buildRelativePath: keeps a file named like a directory apart from it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try buildRelativePath(arena.allocator(), "utils.c", "utils/math.h");
    try std.testing.expectEqualStrings("utils/math.h", path);
}

test "isRuntimeFunction: recognizes the reserved prefix" {
    try std.testing.expect(isRuntimeFunction("mn_runtime_stdout_write"));
    try std.testing.expect(!isRuntimeFunction("stdout_write"));
}

test "findRuntimeFile: follows the name as a path to the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plugin_directory = std.testing.tmpDir(.{});
    defer plugin_directory.cleanup();
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/stdout.c", .data = "" });

    const path = try findRuntimeFile(arena.allocator(), std.testing.io, plugin_directory.dir, "mn_runtime_stdout_write");

    try std.testing.expectEqualStrings("runtime/stdout.c", path);
}

test "findRuntimeFile: finds a file in a nested folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plugin_directory = std.testing.tmpDir(.{});
    defer plugin_directory.cleanup();
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime/io");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/io/stdout.c", .data = "" });

    const path = try findRuntimeFile(arena.allocator(), std.testing.io, plugin_directory.dir, "mn_runtime_io_stdout_write");

    try std.testing.expectEqualStrings("runtime/io/stdout.c", path);
}

test "findRuntimeFile: keeps underscores of the function name out of the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plugin_directory = std.testing.tmpDir(.{});
    defer plugin_directory.cleanup();
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/stdout.c", .data = "" });

    const path = try findRuntimeFile(arena.allocator(), std.testing.io, plugin_directory.dir, "mn_runtime_stdout_write_line");

    try std.testing.expectEqualStrings("runtime/stdout.c", path);
}

test "findRuntimeFile: rejects a name that leads to no file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var plugin_directory = std.testing.tmpDir(.{});
    defer plugin_directory.cleanup();

    const result = findRuntimeFile(arena.allocator(), std.testing.io, plugin_directory.dir, "mn_runtime_stdout_write");

    try std.testing.expectError(error.FileNotFound, result);
}

test "containsName: matches whole names only" {
    try std.testing.expect(containsName(&.{ "stdout", "file" }, "file"));
    try std.testing.expect(!containsName(&.{"stdout"}, "stdou"));
}
