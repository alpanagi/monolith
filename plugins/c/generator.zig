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
    local_names: []const LocalName = &.{},
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
        try self.checkNames(allocator);
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

            const has_source = for (module.declarations) |declaration| {
                if (declaration.kind == .function_definition or isStored(declaration)) break true;
            } else false;
            if (!has_source) continue;

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
        const flags = &.{
            "gcc",
            "-std=c23",
            "-Wall",
            "-Wextra",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
            "-pedantic",
            "-O2",
            "-flto",
        };
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

    fn checkNames(
        self: *Generator,
        allocator: std.mem.Allocator,
    ) (std.mem.Allocator.Error || error{NameDefinedInTarget})!void {
        for (self.program.modules, 0..) |module, module_index| {
            self.module_index = module_index;
            for (module.declarations, 0..) |declaration, index| {
                const signature = switch (declaration.kind) {
                    .function_definition => |function| function.signature,
                    .function_declaration => |function_declaration| function_declaration,
                    .constant_declaration, .struct_definition => continue,
                };
                const name = self.names[module_index][index].?;
                try self.checkName(name, declaration.location);
                const body = extractBody(declaration.kind);
                for (signature.parameters, 0..) |parameter, parameter_index| {
                    if (isDiscarded(body, .{ .parameter = parameter_index })) continue;
                    try self.checkName(parameter.name, parameter.location);
                }
                if (declaration.kind != .function_definition) continue;
                const function = declaration.kind.function_definition;
                for (try buildLocalNames(allocator, function)) |local_name| {
                    try self.checkName(local_name.name, local_name.location);
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
        const definitions = try self.collectDefinitions(allocator, self.module_index);
        for (definitions) |value_type| {
            try writer.writeByte('\n');
            try self.generateDefinition(writer, value_type);
        }
        try self.generateForwardDeclarations(allocator, writer, module, contained, definitions);
        try self.generateConstantDeclarations(writer, module);
        try self.generateDeclarations(writer, module, .function_declaration);
        try self.generateDeclarations(writer, module, .function_definition);
    }

    fn collectContainedModules(
        self: *Generator,
        allocator: std.mem.Allocator,
        module_index: usize,
    ) std.mem.Allocator.Error![]const usize {
        var contained: std.ArrayList(usize) = .empty;
        for (try self.collectDefinitions(allocator, module_index)) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            for (struct_type.fields) |field| {
                const target = findContainedModule(field.type) orelse continue;
                const known = std.mem.findScalar(usize, contained.items, target) != null;
                if (target != module_index and !known) try contained.append(allocator, target);
            }
        }
        return contained.items;
    }

    fn collectDefinitions(
        self: *Generator,
        allocator: std.mem.Allocator,
        module_index: usize,
    ) std.mem.Allocator.Error![]const types.Type {
        var ordered: std.ArrayList(types.Type) = .empty;
        const type_registry = self.program.types;
        for (type_registry.entries.items) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            if (struct_type.module != module_index) continue;
            try orderDefinition(allocator, &ordered, module_index, value_type);
        }
        return ordered.items;
    }

    fn generateDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        switch (value_type) {
            .@"struct" => try self.generateStruct(writer, value_type),
            .array => try self.generateArrayDefinition(writer, value_type),
            .slice => try self.generateSliceDefinition(writer, value_type),
            .number, .boolean, .string, .void, .type => unreachable,
        }
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
        definitions: []const types.Type,
    ) GenerateError!void {
        var forward: Forward = .{ .contained = contained, .definitions = definitions };
        for (module.declarations) |declaration| {
            if (isStored(declaration)) {
                const value_type = declaration.kind.constant_declaration.value.type.?;
                try self.collectForwardType(allocator, &forward, value_type);
            }
            const signature = switch (declaration.kind) {
                .function_definition => |function| function.signature,
                .function_declaration => |function_declaration| function_declaration,
                .constant_declaration, .struct_definition => continue,
            };
            for (signature.parameters) |parameter| {
                const parameter_type = ast.extractType(parameter.type);
                try self.collectForwardType(allocator, &forward, parameter_type);
            }
            const return_type = ast.extractType(signature.return_type);
            try self.collectForwardType(allocator, &forward, return_type);
        }
        const declared = forward.declared;
        if (declared.items.len > 0) try writer.writeByte('\n');
        for (declared.items) |value_type| {
            try writer.writeAll("typedef struct ");
            try self.generateType(writer, value_type);
            try writer.writeByte(' ');
            try self.generateType(writer, value_type);
            try writer.writeAll(";\n");
        }
    }

    fn collectForwardType(
        self: *Generator,
        allocator: std.mem.Allocator,
        forward: *Forward,
        value_type: types.Type,
    ) std.mem.Allocator.Error!void {
        if (isZeroSized(value_type) or containsType(forward.declared.items, value_type)) return;
        switch (value_type) {
            .@"struct" => |struct_type| {
                if (struct_type.module == self.module_index) return;
                const contained = forward.contained;
                if (std.mem.findScalar(usize, contained, struct_type.module) != null) return;
            },
            .array, .slice => {
                if (containsType(forward.definitions, value_type)) return;
            },
            .number, .boolean, .string, .void, .type => return,
        }
        try forward.declared.append(allocator, value_type);
    }

    fn generateConstantDeclarations(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) std.Io.Writer.Error!void {
        var declared = false;
        for (module.declarations, 0..) |declaration, index| {
            if (!isStored(declaration)) continue;
            if (!declared) try writer.writeByte('\n');
            try writer.writeAll("extern const ");
            try self.generateType(writer, declaration.kind.constant_declaration.value.type.?);
            try writer.print(" {s};\n", .{self.names[self.module_index][index].?});
            declared = true;
        }
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
        var reached: Reached = .{};
        for (module.declarations) |declaration| {
            if (isStored(declaration)) {
                const value = declaration.kind.constant_declaration.value;
                try self.collectReachedModulesOf(allocator, &reached, value);
            }
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration, .struct_definition => continue,
            };
            for (function.signature.parameters) |parameter| {
                try self.collectType(allocator, &reached, ast.extractType(parameter.type));
            }
            const return_type = ast.extractType(function.signature.return_type);
            try self.collectType(allocator, &reached, return_type);
            for (function.body) |statement| {
                try self.collectReachedModules(allocator, &reached, statement);
            }
        }
        for (reached.modules.items) |index| {
            const include = try buildModuleInclude(allocator, path, self.program, index);
            try writer.print("#include \"{s}\"\n", .{include});
        }
        const definitions = try self.collectDefinitions(allocator, self.module_index);
        for (reached.slices.items) |value_type| {
            if (containsType(definitions, value_type)) continue;
            try writer.writeByte('\n');
            try self.generateSliceDefinition(writer, value_type);
        }
        for (reached.arrays.items) |value_type| {
            if (containsType(definitions, value_type)) continue;
            try writer.writeByte('\n');
            try self.generateArrayDefinition(writer, value_type);
        }
        try self.generateConstantDefinitions(writer, module);

        for (module.declarations, 0..) |declaration, index| {
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration, .struct_definition => continue,
            };
            try writer.writeByte('\n');
            try self.generateFunction(allocator, writer, function, index);
        }
    }

    fn generateArrayDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        const array = value_type.array;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n    ");
        try self.generateType(writer, array.element);
        try writer.print(" items[{d}];\n}} ", .{array.length});
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n#endif\n");
    }

    fn generateSliceDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        const element = value_type.slice.element;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n    ");
        const tagged = element == .@"struct" or element == .array or element == .slice;
        if (tagged and !isZeroSized(element)) try writer.writeAll("struct ");
        try self.generateType(writer, element);
        try writer.writeAll(" *items;\n    size_t length;\n} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n#endif\n");
    }

    fn generateConstantDefinitions(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) std.Io.Writer.Error!void {
        var defined = false;
        for (module.declarations, 0..) |declaration, index| {
            if (!isStored(declaration)) continue;
            if (!defined) try writer.writeByte('\n');
            const value = declaration.kind.constant_declaration.value;
            try writer.writeAll("const ");
            try self.generateType(writer, value.type.?);
            try writer.print(" {s} = ", .{self.names[self.module_index][index].?});
            try self.generateValue(writer, value, .initializer);
            try writer.writeAll(";\n");
            defined = true;
        }
    }

    fn collectReachedModules(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        statement: ast.Statement,
    ) std.mem.Allocator.Error!void {
        const expression = switch (statement.kind) {
            .noop => return,
            .@"return" => |value| value orelse return,
            .discard, .call => |expression| expression,
            .constant_declaration => |constant| constant.value,
            .variable_declaration => |variable| variable.value,
            .assignment => |assignment| assignment.value,
            .@"while" => |loop| {
                try self.collectReachedModulesOf(allocator, reached, loop.condition);
                for (loop.body) |body_statement| {
                    try self.collectReachedModules(allocator, reached, body_statement);
                }
                return;
            },
        };
        try self.collectReachedModulesOf(allocator, reached, expression);
    }

    fn collectReachedModulesOf(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        expression: ast.Expression,
    ) std.mem.Allocator.Error!void {
        if (expression.type) |value_type| try self.collectType(allocator, reached, value_type);
        const arguments = switch (expression.kind) {
            inline .identifier, .path_expression => |name| {
                const constant = switch (name.resolution.?) {
                    .constant => |constant| constant,
                    .parameter, .function, .type, .local => return,
                };
                const declarations = self.program.modules[constant.module].declarations;
                const declaration = declarations[constant.declaration];
                if (isStored(declaration)) {
                    return self.collectModule(allocator, reached, constant.module);
                }
                const value = declaration.kind.constant_declaration.value;
                return self.collectReachedModulesOf(allocator, reached, value);
            },
            .array_literal => |literal| {
                for (literal.elements) |element| {
                    try self.collectReachedModulesOf(allocator, reached, element);
                }
                return;
            },
            .call => |call| arguments: {
                try self.collectCallee(allocator, reached, call);
                break :arguments call.arguments;
            },
            .struct_literal => |literal| arguments: {
                const value_type = expression.type.?;
                try self.collectFieldDefaults(allocator, reached, value_type, literal.arguments);
                break :arguments literal.arguments;
            },
            .slice => |slice| {
                return self.collectReachedModulesOf(allocator, reached, slice.value.*);
            },
            .field_access => |access| {
                return self.collectReachedModulesOf(allocator, reached, access.value.*);
            },
            else => return,
        };
        for (arguments) |argument| {
            try self.collectReachedModulesOf(allocator, reached, argument.value);
        }
    }

    fn collectCallee(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        call: ast.Call,
    ) std.mem.Allocator.Error!void {
        switch (ast.extractResolution(call.callee)) {
            .function => |function| {
                try self.collectCalledFunction(allocator, reached, function);
                const declarations = self.program.modules[function.module].declarations;
                const signature = ast.extractFunctionSignature(declarations[function.declaration]);
                for (signature.parameters[call.arguments.len..]) |parameter| {
                    try self.collectReachedModulesOf(allocator, reached, parameter.default.?);
                }
            },
            .type => |value_type| {
                try self.collectFieldDefaults(allocator, reached, value_type, call.arguments);
            },
            .parameter, .constant, .local => unreachable,
        }
    }

    fn collectCalledFunction(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        function: ast.Resolution.Function,
    ) std.mem.Allocator.Error!void {
        const module = function.module;
        try self.collectModule(allocator, reached, module);
        switch (self.program.modules[module].declarations[function.declaration].kind) {
            .function_declaration => |function_declaration| {
                const name = function_declaration.name;
                const recorded = containsName(self.runtime_functions.items, name);
                if (isRuntimeFunction(name) and !recorded) {
                    try self.runtime_functions.append(allocator, name);
                }
            },
            .function_definition, .constant_declaration, .struct_definition => {},
        }
    }

    fn collectFieldDefaults(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        value_type: types.Type,
        arguments: []const ast.Argument,
    ) std.mem.Allocator.Error!void {
        for (value_type.@"struct".fields) |field| {
            const default = field.default orelse continue;
            if (ast.findArgument(arguments, field.name) != null) continue;
            try self.collectReachedModulesOf(allocator, reached, default.*);
        }
    }

    fn collectType(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        value_type: types.Type,
    ) std.mem.Allocator.Error!void {
        if (findContainedModule(value_type)) |module| {
            try self.collectModule(allocator, reached, module);
        }
        if (value_type == .slice) {
            if (containsType(reached.slices.items, value_type)) return;
            return reached.slices.append(allocator, value_type);
        }
        if (value_type != .array or isZeroSized(value_type)) return;
        if (containsType(reached.arrays.items, value_type)) return;
        try self.collectType(allocator, reached, value_type.array.element);
        try reached.arrays.append(allocator, value_type);
    }

    fn collectModule(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        module: usize,
    ) std.mem.Allocator.Error!void {
        const known = std.mem.findScalar(usize, reached.modules.items, module) != null;
        if (module != self.module_index and !known) try reached.modules.append(allocator, module);
    }

    fn generateFunction(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        function: ast.FunctionDefinition,
        index: usize,
    ) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
        self.local_names = try buildLocalNames(allocator, function);
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
            .constant_declaration, .struct_definition => unreachable,
        };
        try self.generateType(writer, ast.extractType(signature.return_type));
        try writer.writeByte(' ');
        try writer.writeAll(self.names[self.module_index][index].?);
        try self.generateParameters(writer, signature.parameters, extractBody(kind));
    }

    fn generateParameters(
        self: *Generator,
        writer: *std.Io.Writer,
        parameters: []const ast.TypedName,
        body: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        var written = false;
        for (parameters, 0..) |parameter, index| {
            const parameter_type = ast.extractType(parameter.type);
            if (isZeroSized(parameter_type)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateType(writer, parameter_type);
            if (!isDiscarded(body, .{ .parameter = index })) {
                try writer.print(" {s}", .{parameter.name});
            }
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateBlock(
        self: *Generator,
        writer: *std.Io.Writer,
        block: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        const empty = for (block) |*statement| {
            if (self.hasOutput(statement)) break false;
        } else true;
        if (empty) return writer.writeAll("{}");

        try writer.writeAll("{\n");
        self.depth += 1;
        for (block) |*statement| try self.generateStatement(writer, statement);
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeByte('}');
    }

    fn generateStatement(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) std.Io.Writer.Error!void {
        if (!self.hasOutput(statement)) return;
        switch (statement.kind) {
            .noop => unreachable,
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
            .constant_declaration, .variable_declaration => {
                try self.generateLocal(writer, statement);
            },
            .assignment => |assignment| try self.generateAssignment(writer, assignment),
            .@"while" => |loop| try self.generateWhile(writer, loop),
        }
    }

    fn hasOutput(self: *const Generator, statement: *const ast.Statement) bool {
        return switch (statement.kind) {
            .noop => false,
            .constant_declaration, .variable_declaration => {
                const value = extractLocal(statement.*).?.value;
                return self.findLocalName(statement) != null or hasEffects(value);
            },
            .assignment => |assignment| {
                return self.hasTarget(assignment.target) or hasEffects(assignment.value);
            },
            .discard => |expression| expression.kind != .identifier,
            .@"return", .call, .@"while" => true,
        };
    }

    fn hasTarget(self: *const Generator, target: ast.Expression) bool {
        if (isZeroSized(target.type.?)) return false;
        return self.findLocalName(extractTargetRoot(target)) != null;
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

    fn generateLocal(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) std.Io.Writer.Error!void {
        const value = extractLocal(statement.*).?.value;
        try self.generateIndentation(writer);
        const name = self.findLocalName(statement) orelse {
            try self.generateEffects(writer, value);
            return writer.writeAll(";\n");
        };
        if (statement.kind == .constant_declaration) try writer.writeAll("const ");
        try self.generateType(writer, value.type.?);
        try writer.print(" {s}", .{name});
        if (value.kind != .undefined) {
            try writer.writeAll(" = ");
            try self.generateExpression(writer, value);
        }
        try writer.writeAll(";\n");
    }

    fn generateAssignment(
        self: *Generator,
        writer: *std.Io.Writer,
        assignment: ast.Assignment,
    ) std.Io.Writer.Error!void {
        try self.generateIndentation(writer);
        if (!self.hasTarget(assignment.target)) {
            try self.generateEffects(writer, assignment.value);
            return writer.writeAll(";\n");
        }
        try self.generateExpression(writer, assignment.target);
        try writer.writeAll(" = ");
        try self.generateExpression(writer, assignment.value);
        try writer.writeAll(";\n");
    }

    fn generateWhile(
        self: *Generator,
        writer: *std.Io.Writer,
        loop: ast.While,
    ) std.Io.Writer.Error!void {
        try self.generateIndentation(writer);
        try writer.writeAll("while (");
        try self.generateExpression(writer, loop.condition);
        try writer.writeAll(") ");
        try self.generateBlock(writer, loop.body);
        try writer.writeByte('\n');
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
                    .u8, .u16, .u32, .u64, .usize => try writer.writeByte('u'),
                    else => {},
                }
            },
            .boolean_literal => |value| try writer.writeAll(if (value) "true" else "false"),
            .string_literal => |text| {
                try writer.print("(string){{ \"{s}\", {d} }}", .{ text, countBytes(text) });
            },
            .undefined => unreachable,
            .identifier => |identifier| switch (identifier.resolution.?) {
                .parameter => try writer.writeAll(identifier.name),
                .constant => |constant| try self.generateConstant(writer, constant),
                .local => |statement| try writer.writeAll(self.findLocalName(statement).?),
                .function, .type => unreachable,
            },
            .path_expression => |path_expression| switch (path_expression.resolution.?) {
                .constant => |constant| try self.generateConstant(writer, constant),
                .parameter, .function, .type, .local => unreachable,
            },
            .call => |call| {
                const hoists = try self.generateHoistedEffects(writer, call.arguments);
                switch (ast.extractResolution(call.callee)) {
                    .function => |function| try self.generateFunctionCall(writer, call, function),
                    .type => |value_type| {
                        try self.generateConstruction(writer, call.arguments, value_type);
                    },
                    .parameter, .constant, .local => unreachable,
                }
                if (hoists) try writer.writeByte(')');
            },
            .struct_literal => |literal| {
                const hoists = try self.generateHoistedEffects(writer, literal.arguments);
                try self.generateConstruction(writer, literal.arguments, expression.type.?);
                if (hoists) try writer.writeByte(')');
            },
            .array_literal => |literal| {
                try writer.writeByte('(');
                try self.generateType(writer, expression.type.?);
                try writer.writeByte(')');
                try self.generateElements(writer, literal.elements, .expression);
            },
            .slice => try self.generateSlice(writer, expression, .expression),
            .field_access => |access| {
                try self.generateExpression(writer, access.value.*);
                try writer.print(".{s}", .{access.field});
            },
            .array_type, .slice_type, .@"struct" => unreachable,
        }
    }

    fn generateSlice(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
        form: Form,
    ) std.Io.Writer.Error!void {
        const value = expression.kind.slice.value.*;
        const array = value.type.?.array;
        if (form == .expression) {
            try writer.writeByte('(');
            try self.generateType(writer, expression.type.?);
            try writer.writeByte(')');
        }
        if (isZeroSized(value.type.?)) return writer.print("{{ .length = {d} }}", .{array.length});
        try writer.writeAll("{ .items = ");
        if (isStoredAsConstant(value)) {
            try writer.writeByte('(');
            try self.generateType(writer, array.element);
            try writer.writeAll(" *)");
        }
        try self.generateExpression(writer, value);
        try writer.print(".items, .length = {d} }}", .{array.length});
    }

    fn generateConstant(
        self: *Generator,
        writer: *std.Io.Writer,
        constant: ast.Resolution.Constant,
    ) std.Io.Writer.Error!void {
        const declarations = self.program.modules[constant.module].declarations;
        const declaration = declarations[constant.declaration];
        if (isStored(declaration)) {
            return writer.writeAll(self.names[constant.module][constant.declaration].?);
        }
        try self.generateExpression(writer, declaration.kind.constant_declaration.value);
    }

    fn generateHoistedEffects(
        self: *Generator,
        writer: *std.Io.Writer,
        arguments: []const ast.Argument,
    ) std.Io.Writer.Error!bool {
        const hoists = for (arguments) |argument| {
            if (isHoisted(argument.value)) break true;
        } else false;
        if (!hoists) return false;
        try writer.writeByte('(');
        for (arguments) |argument| {
            if (!isHoisted(argument.value)) continue;
            try self.generateEffects(writer, argument.value);
            try writer.writeAll(", ");
        }
        return true;
    }

    fn findLocalName(self: *const Generator, statement: *const ast.Statement) ?[]const u8 {
        for (self.local_names) |local_name| {
            if (local_name.statement == statement) return local_name.name;
        }
        return null;
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
        const declarations = self.program.modules[function.module].declarations;
        const signature = ast.extractFunctionSignature(declarations[function.declaration]);
        for (signature.parameters[call.arguments.len..]) |parameter| {
            const default = parameter.default.?;
            if (isZeroSized(default.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateExpression(writer, default);
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateConstruction(
        self: *Generator,
        writer: *std.Io.Writer,
        arguments: []const ast.Argument,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        try self.generateType(writer, value_type);
        try writer.writeByte(')');
        try self.generateFields(writer, arguments, value_type, .expression);
    }

    fn generateFields(
        self: *Generator,
        writer: *std.Io.Writer,
        arguments: []const ast.Argument,
        value_type: types.Type,
        form: Form,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("{ ");
        var written = false;
        for (arguments) |argument| {
            if (isZeroSized(argument.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{argument.name.?});
            try self.generateValue(writer, argument.value, form);
            written = true;
        }
        for (value_type.@"struct".fields) |field| {
            const default = field.default orelse continue;
            if (ast.findArgument(arguments, field.name) != null) continue;
            if (isZeroSized(field.type)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{field.name});
            try self.generateValue(writer, default.*, form);
            written = true;
        }
        try writer.writeAll(" }");
    }

    fn generateElements(
        self: *Generator,
        writer: *std.Io.Writer,
        elements: []const ast.Expression,
        form: Form,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("{ .items = { ");
        for (elements, 0..) |element, index| {
            if (index > 0) try writer.writeAll(", ");
            try self.generateValue(writer, element, form);
        }
        try writer.writeAll(" } }");
    }

    fn generateValue(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
        form: Form,
    ) std.Io.Writer.Error!void {
        if (form == .expression) return self.generateExpression(writer, expression);
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal => {
                try self.generateExpression(writer, expression);
            },
            .string_literal => |text| {
                try writer.print("{{ \"{s}\", {d} }}", .{ text, countBytes(text) });
            },
            inline .identifier, .path_expression => |name| {
                const constant = name.resolution.?.constant;
                const declarations = self.program.modules[constant.module].declarations;
                const kind = declarations[constant.declaration].kind;
                try self.generateValue(writer, kind.constant_declaration.value, form);
            },
            .call => |call| {
                try self.generateFields(writer, call.arguments, expression.type.?, form);
            },
            .struct_literal => |literal| {
                try self.generateFields(writer, literal.arguments, expression.type.?, form);
            },
            .array_literal => |literal| try self.generateElements(writer, literal.elements, form),
            .slice => try self.generateSlice(writer, expression, form),
            .undefined, .array_type, .slice_type, .field_access, .@"struct" => unreachable,
        }
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
                .usize => "size_t",
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
            .array => |array| {
                try writer.print("mn_array_{d}_", .{array.length});
                return self.generateTypeName(writer, array.element);
            },
            .slice => |slice| {
                try writer.writeAll("mn_slice_");
                return self.generateTypeName(writer, slice.element);
            },
        });
    }

    fn generateTypeName(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) std.Io.Writer.Error!void {
        switch (value_type) {
            .number => |number| try writer.writeAll(@tagName(number)),
            .boolean => try writer.writeAll("Bool"),
            .string => try writer.writeAll("String"),
            .@"struct" => |struct_type| {
                for (self.program.modules[struct_type.module].path) |part| {
                    try writer.print("{s}_", .{part});
                }
                try writer.writeAll(struct_type.name);
            },
            .array => |array| {
                try writer.print("array_{d}_", .{array.length});
                try self.generateTypeName(writer, array.element);
            },
            .slice => |slice| {
                try writer.writeAll("slice_");
                try self.generateTypeName(writer, slice.element);
            },
            .void, .type => unreachable,
        }
    }

    fn generateEffects(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) std.Io.Writer.Error!void {
        const arguments = switch (expression.kind) {
            .call => |call| arguments: {
                if (ast.extractResolution(call.callee) == .function) {
                    return self.generateExpression(writer, expression);
                }
                break :arguments call.arguments;
            },
            .struct_literal => |literal| literal.arguments,
            .array_literal => |literal| {
                var written = false;
                for (literal.elements) |element| {
                    if (!hasEffects(element)) continue;
                    if (written) try writer.writeAll(", ");
                    try self.generateEffects(writer, element);
                    written = true;
                }
                return;
            },
            .slice => |slice| return self.generateEffects(writer, slice.value.*),
            .field_access => |access| return self.generateEffects(writer, access.value.*),
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .identifier,
            .path_expression,
            .array_type,
            .slice_type,
            .@"struct",
            => unreachable,
        };
        var written = false;
        for (arguments) |argument| {
            if (!hasEffects(argument.value)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateEffects(writer, argument.value);
            written = true;
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

const Forward = struct {
    contained: []const usize,
    definitions: []const types.Type,
    declared: std.ArrayList(types.Type) = .empty,
};

const Reached = struct {
    modules: std.ArrayList(usize) = .empty,
    slices: std.ArrayList(types.Type) = .empty,
    arrays: std.ArrayList(types.Type) = .empty,
};

const Form = enum {
    expression,
    initializer,
};

const LocalName = struct {
    statement: *const ast.Statement,
    name: []const u8,
    location: token.Location,
};

const Local = struct {
    name: []const u8,
    value: ast.Expression,
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
        .constant_declaration => |constant| {
            return try buildQualifiedName(allocator, module.path, constant.name);
        },
        .struct_definition => return null,
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
    return switch (field_type) {
        .@"struct" => |struct_type| struct_type.module,
        .array => |array| findContainedModule(array.element),
        .number, .boolean, .string, .void, .type, .slice => null,
    };
}

fn isHoisted(argument: ast.Expression) bool {
    return isZeroSized(argument.type.?) and hasEffects(argument);
}

fn hasEffects(expression: ast.Expression) bool {
    const arguments = switch (expression.kind) {
        .call => |call| arguments: {
            if (ast.extractResolution(call.callee) == .function) return true;
            break :arguments call.arguments;
        },
        .struct_literal => |literal| literal.arguments,
        .array_literal => |literal| {
            for (literal.elements) |element| {
                if (hasEffects(element)) return true;
            }
            return false;
        },
        .slice => |slice| return hasEffects(slice.value.*),
        .field_access => |access| return hasEffects(access.value.*),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .identifier,
        .path_expression,
        .array_type,
        .slice_type,
        => return false,
        .@"struct" => unreachable,
    };
    for (arguments) |argument| {
        if (hasEffects(argument.value)) return true;
    }
    return false;
}

fn extractBody(kind: ast.DeclarationKind) []const ast.Statement {
    return switch (kind) {
        .function_definition => |function| function.body,
        .function_declaration, .constant_declaration, .struct_definition => &.{},
    };
}

fn buildLocalNames(
    allocator: std.mem.Allocator,
    function: ast.FunctionDefinition,
) std.mem.Allocator.Error![]const LocalName {
    const body = function.body;
    var written: std.ArrayList([]const u8) = .empty;
    var taken: std.ArrayList([]const u8) = .empty;
    for (function.signature.parameters, 0..) |parameter, index| {
        try written.append(allocator, parameter.name);
        if (isDiscarded(body, .{ .parameter = index })) continue;
        if (isZeroSized(ast.extractType(parameter.type))) continue;
        try taken.append(allocator, parameter.name);
    }
    var statements: std.ArrayList(*const ast.Statement) = .empty;
    try collectStatements(allocator, &statements, body);
    for (statements.items) |statement| {
        const local = extractLocal(statement.*) orelse continue;
        try written.append(allocator, local.name);
    }

    var local_names: std.ArrayList(LocalName) = .empty;
    for (statements.items) |statement| {
        if (!isDeclared(body, statement)) continue;
        const source_name = extractLocal(statement.*).?.name;
        var name = source_name;
        var number: usize = 1;
        while (containsName(taken.items, name) or
            (number > 1 and containsName(written.items, name)))
        {
            number += 1;
            name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ source_name, number });
        }
        try taken.append(allocator, name);
        try local_names.append(allocator, .{
            .statement = statement,
            .name = name,
            .location = statement.location,
        });
    }
    return local_names.items;
}

fn collectStatements(
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(*const ast.Statement),
    body: []const ast.Statement,
) std.mem.Allocator.Error!void {
    for (body) |*statement| {
        try statements.append(allocator, statement);
        if (statement.kind == .@"while") {
            try collectStatements(allocator, statements, statement.kind.@"while".body);
        }
    }
}

fn extractLocal(statement: ast.Statement) ?Local {
    return switch (statement.kind) {
        .constant_declaration => |constant| .{ .name = constant.name, .value = constant.value },
        .variable_declaration => |variable| .{ .name = variable.name, .value = variable.value },
        .noop, .@"return", .discard, .call, .assignment, .@"while" => null,
    };
}

fn isDeclared(body: []const ast.Statement, statement: *const ast.Statement) bool {
    const local = extractLocal(statement.*) orelse return false;
    const kind = statement.kind;
    if (kind == .constant_declaration and ast.isAlias(kind.constant_declaration)) return false;
    if (isZeroSized(local.value.type.?)) return false;
    return !isDiscarded(body, .{ .local = statement });
}

fn isDiscarded(body: []const ast.Statement, resolution: ast.Resolution) bool {
    for (body) |statement| {
        const expression = switch (statement.kind) {
            .discard => |expression| expression,
            .noop,
            .@"return",
            .call,
            .constant_declaration,
            .variable_declaration,
            .assignment,
            => continue,
            .@"while" => |loop| {
                if (isDiscarded(loop.body, resolution)) return true;
                continue;
            },
        };
        if (expression.kind != .identifier) continue;
        if (std.meta.eql(expression.kind.identifier.resolution.?, resolution)) return true;
    }
    return false;
}

fn isStoredAsConstant(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .identifier => |identifier| switch (identifier.resolution.?) {
            .local => |statement| statement.kind == .constant_declaration,
            .constant => true,
            .parameter, .function, .type => false,
        },
        .path_expression => true,
        .field_access => |access| isStoredAsConstant(access.value.*),
        else => unreachable,
    };
}

fn extractTargetRoot(target: ast.Expression) *const ast.Statement {
    return switch (target.kind) {
        .identifier => |identifier| identifier.resolution.?.local,
        .field_access => |access| extractTargetRoot(access.value.*),
        else => unreachable,
    };
}

fn isZeroSized(value_type: types.Type) bool {
    switch (value_type) {
        .@"struct" => |struct_type| {
            for (struct_type.fields) |field| {
                if (!isZeroSized(field.type)) return false;
            }
            return true;
        },
        .array => |array| return array.length == 0 or isZeroSized(array.element),
        .number, .boolean, .string, .void, .type, .slice => return false,
    }
}

fn isStored(declaration: ast.Declaration) bool {
    const constant = switch (declaration.kind) {
        .constant_declaration => |constant| constant,
        .function_declaration, .function_definition, .struct_definition => return false,
    };
    if (ast.isAlias(constant)) return false;
    const value_type = constant.value.type orelse return false;
    if (isZeroSized(value_type)) return false;
    return value_type == .@"struct" or value_type == .array;
}

fn findStruct(value_type: types.Type) ?types.Struct {
    return switch (value_type) {
        .@"struct" => |struct_type| struct_type,
        .number, .boolean, .string, .void, .type, .array, .slice => null,
    };
}

fn orderDefinition(
    allocator: std.mem.Allocator,
    ordered: *std.ArrayList(types.Type),
    module_index: usize,
    value_type: types.Type,
) std.mem.Allocator.Error!void {
    if (isZeroSized(value_type) or containsType(ordered.items, value_type)) return;
    switch (value_type) {
        .@"struct" => |struct_type| {
            if (struct_type.module != module_index) return;
            for (struct_type.fields) |field| {
                try orderDefinition(allocator, ordered, module_index, field.type);
            }
        },
        .array => |array| try orderDefinition(allocator, ordered, module_index, array.element),
        .slice => {},
        .number, .boolean, .string, .void, .type => return,
    }
    try ordered.append(allocator, value_type);
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
        if (isSameCType(existing, value_type)) return true;
    }
    return false;
}

fn isSameCType(one: types.Type, two: types.Type) bool {
    return switch (one) {
        .array => |array| two == .array and array.length == two.array.length and
            isSameCType(array.element, two.array.element),
        .slice => |slice| two == .slice and isSameCType(slice.element, two.slice.element),
        .number, .boolean, .string, .void, .type, .@"struct" => std.meta.eql(one, two),
    };
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(int32_t: i32) i32: return int32_t" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(value: i32): _ = value" });
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"utils.h\"\n\nint main() {\n    mn_utils_add(1);\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_utils_add(int32_t);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"utils.h\"\n\nvoid mn_utils_add(int32_t) {}\n",
        files[3].contents,
    );
}

test "generateFiles: includes the headers of the structs its functions use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nvoid mn_main_show(mn_shapes_Line) {}\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32\nexternal fn make() Line" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn width() i32: return shapes::make().width" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: i32\nconst origin = Point(x = 0)" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() i32: return shapes::origin.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nint32_t mn_main_make() {\n    return mn_shapes_origin.x;\n}\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, char: i32) i32:\n    _ = left\n    return char" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    int: i32\nfn show(point: Point): _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);

    try std.testing.expectError(error.NameDefinedInTarget, generator.generateFiles(arena.allocator()));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, generator.failure.?.location.?);
}

test "checkNames: accepts a discarded parameter named like the target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(int: i32): _ = int" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_add(int32_t) {}\n",
        files[1].contents,
    );
}

test "checkNames: rejects local constant names defined in the target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() i32:\n    const int = 5i32\n    return int" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(string: i32) i32: return string" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(MONOLITH_H: i32) i32: return MONOLITH_H" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(size_t: i32) i32: return size_t" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(int_: i32, int: i32) i32:\n    _ = take(int_)\n    return int\nfn take(value: i32) i32: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "first.mn", .data = "struct One:\n    two: second::Two\nstruct Zero:\n    value: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "second.mn", .data = "struct Two:\n    zero: first::Zero" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: first::One): _ = one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Line:\n    start: Point\n    end: Point\nstruct Point:\n    x: i32\nstruct Unused:\n    z: i32\nfn show(line: Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Point {\n    int32_t x;\n} mn_main_Point;\n\ntypedef struct mn_main_Line {\n    mn_main_Point start;\n    mn_main_Point end;\n} mn_main_Line;\n\nvoid mn_main_show(mn_main_Line);\n",
        files[0].contents,
    );
}

test "generateHeader: includes the headers of the modules whose structs it contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    start: points::Point" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "points.mn", .data = "struct Point:\n    x: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Tagged:\n    marker: Marker\n    value: i32\nfn show(tagged: Tagged): _ = tagged" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Tagged {\n    int32_t value;\n} mn_main_Tagged;\n\nvoid mn_main_show(mn_main_Tagged);\n",
        files[0].contents,
    );
}

test "generateForwardDeclarations: declares the structs of other modules that signatures use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_shapes_Line mn_shapes_Line;\n\nvoid mn_main_show(mn_shapes_Line);\n",
        files[0].contents,
    );
}

test "generateConstantDeclarations: declares a stored array constant in the header" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: String\nconst cards: [2]Card = [\n    .(question = \"a\"),\n    .(question = \"b\"),\n]\nfn all() [2]Card: return cards" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Card {\n    string question;\n} mn_main_Card;\n\ntypedef struct mn_array_2_main_Card mn_array_2_main_Card;\n\nextern const mn_array_2_main_Card mn_main_cards;\n\nmn_array_2_main_Card mn_main_all();\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid log(int32_t value);\n\nvoid mn_main_one();\nvoid mn_main_two();\n",
        files[0].contents,
    );
}

test "generateArrayDefinition: defines an array type before the struct that holds it" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: String\nstruct Deck:\n    cards: [2]Card\nfn show(deck: Deck): _ = deck" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Card {\n    string question;\n} mn_main_Card;\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\ntypedef struct mn_main_Deck {\n    mn_array_2_main_Card cards;\n} mn_main_Deck;\n\nvoid mn_main_show(mn_main_Deck);\n",
        files[0].contents,
    );
}

test "generateSliceDefinition: points to its elements by their struct tag" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck:\n    cards: []Card\nstruct Card:\n    points: i32\nfn show(deck: Deck): _ = deck" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Card {\n    int32_t points;\n} mn_main_Card;\n\n#ifndef mn_slice_main_Card_defined\n#define mn_slice_main_Card_defined\ntypedef struct mn_slice_main_Card {\n    struct mn_main_Card *items;\n    size_t length;\n} mn_slice_main_Card;\n#endif\n\ntypedef struct mn_main_Deck {\n    mn_slice_main_Card cards;\n} mn_main_Deck;\n\nvoid mn_main_show(mn_main_Deck);\n",
        files[0].contents,
    );
}

test "collectReachedModules: includes the headers that a loop reaches" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): while false: shapes::draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nint main() {\n    while (false) {\n        mn_shapes_draw();\n    }\n}\n",
        files[1].contents,
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/clock.mn", .data = "struct Time:\n    seconds: i64\nexternal fn mn_runtime_clock_now() Time\nconst now = mn_runtime_clock_now" });
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    _ = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqual(1, generator.runtime_functions.items.len);
    try std.testing.expectEqualStrings("mn_runtime_clock_now", generator.runtime_functions.items[0]);
}

test "collectReachedModulesOf: includes the headers of the structs that defaults build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "geometry.mn", .data = "struct Size:\n    width: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw(size: geometry::Size = geometry::Size(width = 1)): _ = size" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): shapes::draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n#include \"geometry.h\"\n\nint main() {\n    mn_shapes_draw((mn_geometry_Size){ .width = 1 });\n}\n",
        files[1].contents,
    );
}

test "collectReachedModulesOf: reaches what the value of a slice constant uses" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "data.mn", .data = "const values = [1i32, 2i32]\nconst items = values[..]" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: []const i32): _ = values\nfn main(): take(data::items)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"data.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nvoid mn_main_take(mn_slice_i32) {}\n\nint main() {\n    mn_main_take((mn_slice_i32){ .items = (int32_t *)mn_data_values.items, .length = 2 });\n}\n",
        files[1].contents,
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
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn show(marker: Marker, value: i32):\n    _ = marker\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_main_show(int32_t);\n",
        files[0].contents,
    );
}

test "generateParameters: leaves out the names of discarded parameters" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(left: i32, right: i32) i32:\n    _ = right\n    return left" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nint32_t mn_main_show(int32_t left, int32_t);\n",
        files[0].contents,
    );
}

test "generateParameters: leaves out the name of a parameter discarded in a loop" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32):\n    while false:\n        _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_main_show(int32_t);\n",
        files[0].contents,
    );
}

test "generateBlock: writes an empty block for a body of constants" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const limit = 5i32\n    _ = limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint main() {}\n",
        files[1].contents,
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(value: i32): _ = value\nfn one() i32: return 1\nfn main():\n    log(one())\n    _ = one()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_log(int32_t) {}\n\nint32_t mn_main_one() {\n    return 1;\n}\n\nint main() {\n    mn_main_log(mn_main_one());\n    mn_main_one();\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make(marker: Marker) Marker: return marker\nfn pass(marker: Marker) Marker: return make(marker)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_pass() {\n    mn_main_make();\n    return;\n}\n",
        files[1].contents,
    );
}

test "hasOutput: writes nothing for discards" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn show(marker: Marker, value: i32):\n    const limit = 5i32\n    _ = limit\n    _ = marker\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_show(int32_t) {}\n",
        files[1].contents,
    );
}

test "generateLocal: declares a local constant in C" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const limit: i32 = 5\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_take(int32_t) {}\n\nint main() {\n    const int32_t limit = 5;\n    mn_main_take(limit);\n}\n",
        files[1].contents,
    );
}

test "generateLocal: renames a constant that shadows" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) i32:\n    const value = value\n    const value = value\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_show(int32_t value) {\n    const int32_t value_2 = value;\n    const int32_t value_3 = value_2;\n    return value_3;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: skips names written in the function" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) i32:\n    const value = value\n    const value_2 = value\n    return value_2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_show(int32_t value) {\n    const int32_t value_3 = value;\n    const int32_t value_2 = value_3;\n    return value_2;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: writes only the calls of a discarded constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() i32: return 1\nfn main():\n    const value = make()\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_make() {\n    return 1;\n}\n\nint main() {\n    mn_main_make();\n}\n",
        files[1].contents,
    );
}

test "generateLocal: writes only the calls of a zero-sized constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make() Marker: return Marker()\nfn use(marker: Marker): _ = marker\nfn main():\n    const marker = make()\n    use(marker)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_use() {}\n\nint main() {\n    mn_main_make();\n    mn_main_use();\n}\n",
        files[1].contents,
    );
}

test "generateLocal: writes nothing for a local constant that names an array type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() [2]i32:\n    const Pair = [2]i32\n    const values: Pair = [1, 2]\n    return values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nmn_array_2_i32 mn_main_first() {\n    const mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    return values;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: declares a variable" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() i32:\n    var count = 1i32\n    count = 2i32\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_show() {\n    int32_t count = 1;\n    count = 2;\n    return count;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: declares an undefined variable without a value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() i32:\n    var count: i32 = undefined\n    count = 5\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_show() {\n    int32_t count;\n    count = 5;\n    return count;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: writes nothing for a discarded variable" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count = 1i32\n    count = 2i32\n    _ = count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint main() {}\n",
        files[1].contents,
    );
}

test "generateLocal: numbers a variable that shadows a local constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() i32:\n    const value = 1i32\n    var value = value\n    value = 2i32\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_show() {\n    const int32_t value = 1;\n    int32_t value_2 = value;\n    value_2 = 2;\n    return value_2;\n}\n",
        files[1].contents,
    );
}

test "generateLocal: numbers a local in a loop that shadows an outer local" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const value = 1i32\n    while false:\n        const value = 2i32\n        take(value)\n    take(value)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_take(int32_t) {}\n\nint main() {\n    const int32_t value = 1;\n    while (false) {\n        const int32_t value_2 = 2;\n        mn_main_take(value_2);\n    }\n    mn_main_take(value);\n}\n",
        files[1].contents,
    );
}

test "generateAssignment: assigns a field" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn show() Point:\n    var point = Point(x = 1, y = 2)\n    point.x = 3\n    return point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Point mn_main_show() {\n    mn_main_Point point = (mn_main_Point){ .x = 1, .y = 2 };\n    point.x = 3;\n    return point;\n}\n",
        files[1].contents,
    );
}

test "generateAssignment: writes only the calls when the variable is not declared" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() i32: return 1\nfn main():\n    var value = 1i32\n    value = make()\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_make() {\n    return 1;\n}\n\nint main() {\n    mn_main_make();\n}\n",
        files[1].contents,
    );
}

test "generateAssignment: assigns a nested field" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn show() Line:\n    var line = Line(start = Point(x = 1))\n    line.start.x = 2\n    return line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Line mn_main_show() {\n    mn_main_Line line = (mn_main_Line){ .start = (mn_main_Point){ .x = 1 } };\n    line.start.x = 2;\n    return line;\n}\n",
        files[1].contents,
    );
}

test "generateWhile: writes the condition and the body" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    var running = true\n    while running:\n        step()\n        running = false" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_step() {}\n\nint main() {\n    bool running = true;\n    while (running) {\n        mn_main_step();\n        running = false;\n    }\n}\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small(value: u8): _ = value\nfn main(): small(255)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_small(uint8_t) {}\n\nint main() {\n    mn_main_small(255u);\n}\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make(marker: Marker) Marker: return marker\nfn use(marker: Marker, value: i32):\n    _ = marker\n    _ = value\nfn run(marker: Marker): use(make(marker), 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_use(int32_t) {}\n\nvoid mn_main_run() {\n    (mn_main_make(), mn_main_use(1));\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nexternal fn make() Line\nfn read(line: Line) i32: return line.start.x\nfn first() i32: return make().start.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_read(mn_main_Line line) {\n    return line.start.x;\n}\n\nint32_t mn_main_first() {\n    return make().start.x;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a struct literal as a compound literal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32 = 0\nfn draw(point: Point) i32: return point.x\nfn main(): _ = draw(.(x = 1))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_draw(mn_main_Point point) {\n    return point.x;\n}\n\nint main() {\n    mn_main_draw((mn_main_Point){ .x = 1, .y = 0 });\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a struct literal in a field default" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point = .(x = 0)\nfn make() Line: return Line()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Line mn_main_make() {\n    return (mn_main_Line){ .start = (mn_main_Point){ .x = 0 } };\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a struct literal in a parameter default" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn draw(point: Point = .(x = 0)) i32: return point.x\nfn main(): _ = draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_draw(mn_main_Point point) {\n    return point.x;\n}\n\nint main() {\n    mn_main_draw((mn_main_Point){ .x = 0 });\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a struct literal in an assignment" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() Point:\n    var point = Point(x = 1)\n    point = .(x = 2)\n    return point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Point mn_main_make() {\n    mn_main_Point point = (mn_main_Point){ .x = 1 };\n    point = (mn_main_Point){ .x = 2 };\n    return point;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: moves zero-sized calls out of a struct literal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nfn mark() Marker: return Marker()\nfn make() Holder: return .(marker = mark(), value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_mark() {\n    return;\n}\n\nmn_main_Holder mn_main_make() {\n    return (mn_main_mark(), (mn_main_Holder){ .value = 1 });\n}\n",
        files[1].contents,
    );
}

test "generateExpression: leaves out a struct literal of a zero-sized struct" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn use(marker: Marker): _ = marker\nfn main(): use(.())" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_use() {}\n\nint main() {\n    mn_main_use();\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes an array literal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() [2]i32: return [1, 2]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nmn_array_2_i32 mn_main_make() {\n    return (mn_array_2_i32){ .items = { 1, 2 } };\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes an array literal whose type comes from its elements" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() [2]i32:\n    const values = [1i32, 2i32]\n    return values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nmn_array_2_i32 mn_main_first() {\n    const mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    return values;\n}\n",
        files[1].contents,
    );
}

test "generateSlice: writes a slice of a variable" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn fill(bytes: []u8)\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nint main() {\n    mn_array_4_u8 buffer;\n    fill((mn_slice_u8){ .items = buffer.items, .length = 4 });\n}\n",
        files[1].contents,
    );
}

test "generateSlice: casts a slice of a constant to a writable pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: []const i32): _ = values\nfn main():\n    const values = [1i32, 2i32]\n    take(values[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nvoid mn_main_take(mn_slice_i32) {}\n\nint main() {\n    const mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    mn_main_take((mn_slice_i32){ .items = (int32_t *)values.items, .length = 2 });\n}\n",
        files[1].contents,
    );
}

test "generateSlice: writes a slice of a parameter without a cast" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: []const i32): _ = values\nfn show(values: [2]i32): take(values[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nvoid mn_main_take(mn_slice_i32) {}\n\nvoid mn_main_show(mn_array_2_i32 values) {\n    mn_main_take((mn_slice_i32){ .items = values.items, .length = 2 });\n}\n",
        files[1].contents,
    );
}

test "generateSlice: writes only the length of a zero-sized array" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn take(markers: []const Marker): _ = markers\nfn main():\n    const markers = [Marker(), Marker()]\n    take(markers[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Marker_defined\n#define mn_slice_main_Marker_defined\ntypedef struct mn_slice_main_Marker {\n    void *items;\n    size_t length;\n} mn_slice_main_Marker;\n#endif\n\nvoid mn_main_take(mn_slice_main_Marker) {}\n\nint main() {\n    mn_main_take((mn_slice_main_Marker){ .length = 2 });\n}\n",
        files[1].contents,
    );
}

test "generateConstant: writes the name of a stored constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nstruct Line:\n    start: Point\n    end: Point\nconst origin = Point(x = 0, y = 0)\nfn make() Line: return Line(start = origin, end = origin)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nconst mn_main_Point mn_main_origin = { .x = 0, .y = 0 };\n\nmn_main_Line mn_main_make() {\n    return (mn_main_Line){ .start = mn_main_origin, .end = mn_main_origin };\n}\n",
        files[1].contents,
    );
}

test "generateConstant: stores a struct literal in a constant with a written type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst origin: Point = .(x = 0)\nfn make() Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nconst mn_main_Point mn_main_origin = { .x = 0 };\n\nmn_main_Point mn_main_make() {\n    return mn_main_origin;\n}\n",
        files[1].contents,
    );
}

test "generateConstant: stores an array constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: String\nconst cards: [2]Card = [\n    .(question = \"a\"),\n    .(question = \"b\"),\n]\nfn all() [2]Card: return cards" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\nconst mn_array_2_main_Card mn_main_cards = { .items = { { .question = { \"a\", 1 } }, { .question = { \"b\", 1 } } } };\n\nmn_array_2_main_Card mn_main_all() {\n    return mn_main_cards;\n}\n",
        files[1].contents,
    );
}

test "generateConstant: stores an array constant with a length to infer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: String\nconst cards: [_]Card = [\n    .(question = \"a\"),\n    .(question = \"b\"),\n]\nfn all() [2]Card: return cards" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\nconst mn_array_2_main_Card mn_main_cards = { .items = { { .question = { \"a\", 1 } }, { .question = { \"b\", 1 } } } };\n\nmn_array_2_main_Card mn_main_all() {\n    return mn_main_cards;\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: writes the defaults of left out parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn draw(width: i32, height: i32 = 1, label: String = \"box\"):\n    _ = width\n    _ = height\n    _ = label\nfn main():\n    draw(2)\n    draw(2, 5)\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_draw(int32_t, int32_t, string) {}\n\nint main() {\n    mn_main_draw(2, 1, (string){ \"box\", 3 });\n    mn_main_draw(2, 5, (string){ \"box\", 3 });\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nstruct Line:\n    start: Point\n    end: Point\nfn make() Line: return Line(start = Point(x = 0, y = 0), end = Point(y = 2, x = 1))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nstruct Wrapper:\n    marker: Marker\nfn make() Holder: return Holder(marker = Marker(), value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Holder mn_main_make() {\n    return (mn_main_Holder){ .value = 1 };\n}\n",
        files[1].contents,
    );
}

test "generateConstruction: writes the defaults of left out fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32 = 0\n    y: i32 = 7\nfn make() Point: return Point(y = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nmn_main_Point mn_main_make() {\n    return (mn_main_Point){ .y = 1, .x = 0 };\n}\n",
        files[1].contents,
    );
}

test "generateValue: writes a slice in a stored constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values = [1i32, 2i32]\nstruct Box:\n    items: []const i32\nconst box = Box(items = values[..])\nfn show() Box: return box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nconst mn_array_2_i32 mn_main_values = { .items = { 1, 2 } };\nconst mn_main_Box mn_main_box = { .items = { .items = (int32_t *)mn_main_values.items, .length = 2 } };\n\nmn_main_Box mn_main_show() {\n    return mn_main_box;\n}\n",
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
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nfloat mn_main_half() {\n    return 0.5;\n}\n\ndouble mn_main_whole() {\n    return 1.0;\n}\n",
        files[1].contents,
    );
}

test "generateType: maps usize to size_t" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() usize: return 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nsize_t mn_main_count() {\n    return 3u;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nexternal fn make() Holder\nfn use(marker: Marker, value: i32):\n    _ = marker\n    _ = value\nfn take(holder: Holder) Marker: return holder.marker\nfn get() Marker: return make().marker\nfn main(): use(make().marker, 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_use(int32_t) {}\n\nvoid mn_main_take(mn_main_Holder holder) {\n    return;\n}\n\nvoid mn_main_get() {\n    make();\n    return;\n}\n\nint main() {\n    (make(), mn_main_use(1));\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nstruct Wrapper:\n    marker: Marker\nfn mark() Marker: return Marker()\nfn use(wrapper: Wrapper, value: i32):\n    _ = wrapper\n    _ = value\nfn main():\n    use(Wrapper(marker = mark()), 1)\n    use(Wrapper(marker = Marker()), 2)\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_mark() {\n    return;\n}\n\nvoid mn_main_use(int32_t) {}\n\nint main() {\n    (mn_main_mark(), mn_main_use(1));\n    mn_main_use(2);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nfn use(marker: Marker, value: i32):\n    _ = marker\n    _ = value\nfn pass(holder: Holder): use(holder.marker, 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_use(int32_t) {}\n\nvoid mn_main_pass(mn_main_Holder holder) {\n    mn_main_use(1);\n}\n",
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

test "containsType: treats slices that differ only in mutability as one C type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []const u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    var bytes = buffer[..]\n    bytes = buffer[..]\n    take(bytes)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nvoid mn_main_take(mn_slice_u8) {}\n\nint main() {\n    mn_array_4_u8 buffer;\n    mn_slice_u8 bytes = (mn_slice_u8){ .items = buffer.items, .length = 4 };\n    bytes = (mn_slice_u8){ .items = buffer.items, .length = 4 };\n    mn_main_take(bytes);\n}\n",
        files[1].contents,
    );
}
