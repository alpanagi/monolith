const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

const followPointer = types.followPointer;
const isZeroSized = types.isZeroSized;

pub const Generator = struct {
    program: ast.Program,
    runtime_functions: std.ArrayList([]const u8) = .empty,
    names: []const []const ?[]const u8 = &.{},
    addressed: []const ast.Resolution.Constant = &.{},
    local_names: []const LocalName = &.{},
    steps: []const Step = &.{},
    parameters: []const ast.TypedName = &.{},
    return_type: types.Type = .void,
    sequenced: bool = false,
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
        self.addressed = try collectAddressedConstants(allocator, self.program);
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

            const has_source = for (module.declarations, 0..) |declaration, declaration_index| {
                if (declaration.kind == .function_definition) break true;
                if (self.isStored(index, declaration_index)) break true;
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
            if (ast.isMain(declaration.kind.function_definition.signature)) break true;
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
                    .trait_definition, .implementation, .import => continue,
                };
                const name = self.names[module_index][index].?;
                try self.checkName(name, declaration.location);
                const body = extractBody(declaration.kind);
                for (signature.parameters, 0..) |parameter, parameter_index| {
                    if (isDiscardedParameter(body, signature.parameters, parameter_index)) continue;
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
            .{"INT16_C"},            .{"INT16_MAX"},                 .{"INT16_MIN"},
            .{"INT16_WIDTH"},        .{"INT32_C"},                   .{"INT32_MAX"},
            .{"INT32_MIN"},          .{"INT32_WIDTH"},               .{"INT64_C"},
            .{"INT64_MAX"},          .{"INT64_MIN"},                 .{"INT64_WIDTH"},
            .{"INT8_C"},             .{"INT8_MAX"},                  .{"INT8_MIN"},
            .{"INT8_WIDTH"},         .{"INTMAX_C"},                  .{"INTMAX_MAX"},
            .{"INTMAX_MIN"},         .{"INTMAX_WIDTH"},              .{"INTPTR_MAX"},
            .{"INTPTR_MIN"},         .{"INTPTR_WIDTH"},              .{"INT_FAST16_MAX"},
            .{"INT_FAST16_MIN"},     .{"INT_FAST16_WIDTH"},          .{"INT_FAST32_MAX"},
            .{"INT_FAST32_MIN"},     .{"INT_FAST32_WIDTH"},          .{"INT_FAST64_MAX"},
            .{"INT_FAST64_MIN"},     .{"INT_FAST64_WIDTH"},          .{"INT_FAST8_MAX"},
            .{"INT_FAST8_MIN"},      .{"INT_FAST8_WIDTH"},           .{"INT_LEAST16_MAX"},
            .{"INT_LEAST16_MIN"},    .{"INT_LEAST16_WIDTH"},         .{"INT_LEAST32_MAX"},
            .{"INT_LEAST32_MIN"},    .{"INT_LEAST32_WIDTH"},         .{"INT_LEAST64_MAX"},
            .{"INT_LEAST64_MIN"},    .{"INT_LEAST64_WIDTH"},         .{"INT_LEAST8_MAX"},
            .{"INT_LEAST8_MIN"},     .{"INT_LEAST8_WIDTH"},          .{"MONOLITH_H"},
            .{"NULL"},               .{"PTRDIFF_MAX"},               .{"PTRDIFF_MIN"},
            .{"PTRDIFF_WIDTH"},      .{"SIG_ATOMIC_MAX"},            .{"SIG_ATOMIC_MIN"},
            .{"SIG_ATOMIC_WIDTH"},   .{"SIZE_MAX"},                  .{"SIZE_WIDTH"},
            .{"UINT16_C"},           .{"UINT16_MAX"},                .{"UINT16_WIDTH"},
            .{"UINT32_C"},           .{"UINT32_MAX"},                .{"UINT32_WIDTH"},
            .{"UINT64_C"},           .{"UINT64_MAX"},                .{"UINT64_WIDTH"},
            .{"UINT8_C"},            .{"UINT8_MAX"},                 .{"UINT8_WIDTH"},
            .{"UINTMAX_C"},          .{"UINTMAX_MAX"},               .{"UINTMAX_WIDTH"},
            .{"UINTPTR_MAX"},        .{"UINTPTR_WIDTH"},             .{"UINT_FAST16_MAX"},
            .{"UINT_FAST16_WIDTH"},  .{"UINT_FAST32_MAX"},           .{"UINT_FAST32_WIDTH"},
            .{"UINT_FAST64_MAX"},    .{"UINT_FAST64_WIDTH"},         .{"UINT_FAST8_MAX"},
            .{"UINT_FAST8_WIDTH"},   .{"UINT_LEAST16_MAX"},          .{"UINT_LEAST16_WIDTH"},
            .{"UINT_LEAST32_MAX"},   .{"UINT_LEAST32_WIDTH"},        .{"UINT_LEAST64_MAX"},
            .{"UINT_LEAST64_WIDTH"}, .{"UINT_LEAST8_MAX"},           .{"UINT_LEAST8_WIDTH"},
            .{"WCHAR_MAX"},          .{"WCHAR_MIN"},                 .{"WCHAR_WIDTH"},
            .{"WINT_MAX"},           .{"WINT_MIN"},                  .{"WINT_WIDTH"},
            .{"_Alignas"},           .{"_Alignof"},                  .{"_Atomic"},
            .{"_BitInt"},            .{"_Bool"},                     .{"_Complex"},
            .{"_Decimal128"},        .{"_Decimal32"},                .{"_Decimal64"},
            .{"_Float128"},          .{"_Float16"},                  .{"_Generic"},
            .{"_Imaginary"},         .{"_Noreturn"},                 .{"_Static_assert"},
            .{"_Thread_local"},      .{"__STDC_VERSION_STDDEF_H__"}, .{"__STDC_VERSION_STDINT_H__"},
            .{"alignas"},            .{"alignof"},                   .{"asm"},
            .{"auto"},               .{"bool"},                      .{"break"},
            .{"case"},               .{"char"},                      .{"const"},
            .{"constexpr"},          .{"continue"},                  .{"default"},
            .{"do"},                 .{"double"},                    .{"else"},
            .{"enum"},               .{"extern"},                    .{"false"},
            .{"float"},              .{"for"},                       .{"goto"},
            .{"if"},                 .{"inline"},                    .{"int"},
            .{"int128_t"},           .{"int16_t"},                   .{"int32_t"},
            .{"int64_t"},            .{"int8_t"},                    .{"int_fast16_t"},
            .{"int_fast32_t"},       .{"int_fast64_t"},              .{"int_fast8_t"},
            .{"int_least16_t"},      .{"int_least32_t"},             .{"int_least64_t"},
            .{"int_least8_t"},       .{"intmax_t"},                  .{"intptr_t"},
            .{"long"},               .{"max_align_t"},               .{"nullptr"},
            .{"nullptr_t"},          .{"offsetof"},                  .{"ptrdiff_t"},
            .{"register"},           .{"restrict"},                  .{"return"},
            .{"short"},              .{"signed"},                    .{"size_t"},
            .{"sizeof"},             .{"static"},                    .{"static_assert"},
            .{"struct"},             .{"switch"},                    .{"thread_local"},
            .{"true"},               .{"typedef"},                   .{"typeof"},
            .{"typeof_unqual"},      .{"uint128_t"},                 .{"uint16_t"},
            .{"uint32_t"},           .{"uint64_t"},                  .{"uint8_t"},
            .{"uint_fast16_t"},      .{"uint_fast32_t"},             .{"uint_fast64_t"},
            .{"uint_fast8_t"},       .{"uint_least16_t"},            .{"uint_least32_t"},
            .{"uint_least64_t"},     .{"uint_least8_t"},             .{"uintmax_t"},
            .{"uintptr_t"},          .{"union"},                     .{"unreachable"},
            .{"unsigned"},           .{"void"},                      .{"volatile"},
            .{"wchar_t"},            .{"while"},
        });

        if (!reserved_words.has(name)) return;
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = "name is already defined in the target",
        };
        return error.NameDefinedInTarget;
    }

    fn checkStructCycles(
        self: *Generator,
        allocator: std.mem.Allocator,
    ) GenerateError!void {
        const type_registry = self.program.types;
        for (type_registry.entries.items) |value_type| {
            const struct_type = findStruct(value_type) orelse continue;
            if (isZeroSized(value_type)) continue;
            for (struct_type.fields) |field| {
                var targets: std.ArrayList(usize) = .empty;
                try collectContainedModulesOf(allocator, &targets, field.type);
                for (targets.items) |target| {
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
        try self.generatePrototypeTags(allocator, writer, definitions);
        for (definitions) |value_type| {
            try writer.writeByte('\n');
            try self.generateDefinition(writer, value_type);
        }
        try self.generateForwardDeclarations(allocator, writer, module, contained, definitions);
        try self.generateConstantDeclarations(writer, module);
        try self.generateDeclarations(writer, module, .function_declaration);
        try self.generateDeclarations(writer, module, .function_definition);
    }

    fn generatePrototypeTags(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        definitions: []const types.Type,
    ) GenerateError!void {
        var tags: std.ArrayList(types.Type) = .empty;
        for (definitions) |value_type| {
            switch (value_type) {
                .@"struct" => |struct_type| {
                    for (struct_type.fields) |field| {
                        try collectPrototypeTags(allocator, &tags, field.type, false);
                    }
                },
                .array => |array| try collectPrototypeTags(allocator, &tags, array.element, false),
                .slice => |slice| try collectPrototypeTags(allocator, &tags, slice.element, false),
                .optional => |optional| {
                    try collectPrototypeTags(allocator, &tags, optional.child, false);
                },
                .tuple => |tuple| {
                    for (tuple.elements) |element| {
                        try collectPrototypeTags(allocator, &tags, element, false);
                    }
                },
                .number, .boolean, .void, .type, .pointer, .function, .implementer => {
                    unreachable;
                },
            }
        }
        if (tags.items.len > 0) try writer.writeByte('\n');
        for (tags.items) |value_type| {
            try writer.writeAll("typedef struct ");
            try self.generateType(writer, value_type);
            try writer.writeByte(' ');
            try self.generateType(writer, value_type);
            try writer.writeAll(";\n");
        }
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
                try collectContainedModulesOf(allocator, &contained, field.type);
            }
        }
        if (std.mem.findScalar(usize, contained.items, module_index)) |index| {
            _ = contained.orderedRemove(index);
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
    ) WriteError!void {
        switch (value_type) {
            .@"struct" => try self.generateStruct(writer, value_type),
            .array => try self.generateArrayDefinition(writer, value_type),
            .slice => try self.generateSliceDefinition(writer, value_type),
            .optional => try self.generateOptionalDefinition(writer, value_type),
            .tuple => try self.generateTupleDefinition(writer, value_type),
            .number, .boolean, .void, .type, .pointer, .function, .implementer => {
                unreachable;
            },
        }
    }

    fn generateStruct(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
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
        for (module.declarations, 0..) |declaration, index| {
            if (self.isStored(self.module_index, index)) {
                const constant = declaration.kind.constant_declaration;
                const value_type = ast.extractDeclaredType(constant.type, constant.value);
                try self.collectForwardType(allocator, &forward, value_type);
            }
            const signature = switch (declaration.kind) {
                .function_definition => |function| function.signature,
                .function_declaration => |function_declaration| function_declaration,
                .constant_declaration, .struct_definition => continue,
                .trait_definition, .implementation, .import => continue,
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
            .array, .slice, .tuple => {
                if (containsType(forward.definitions, value_type)) return;
            },
            .optional => |optional| {
                if (isPointerOptional(value_type)) {
                    return self.collectForwardType(allocator, forward, optional.child);
                }
                if (containsType(forward.definitions, value_type)) return;
            },
            .pointer => |pointer| return self.collectForwardType(allocator, forward, pointer.target),
            .function => |function| {
                for (function.parameters) |parameter| {
                    try self.collectForwardType(allocator, forward, parameter);
                }
                return self.collectForwardType(allocator, forward, function.return_type);
            },
            .number, .boolean, .void, .type, .implementer => return,
        }
        try forward.declared.append(allocator, value_type);
    }

    fn generateConstantDeclarations(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) WriteError!void {
        var declared = false;
        for (module.declarations, 0..) |declaration, index| {
            if (!self.isStored(self.module_index, index)) continue;
            if (!declared) try writer.writeByte('\n');
            try writer.writeAll("extern const ");
            const constant = declaration.kind.constant_declaration;
            try self.generateType(writer, ast.extractDeclaredType(constant.type, constant.value));
            try writer.print(" {s};\n", .{self.names[self.module_index][index].?});
            declared = true;
        }
    }

    fn generateDeclarations(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
        kind: std.meta.Tag(ast.DeclarationKind),
    ) WriteError!void {
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
        var constants: std.Io.Writer.Allocating = .init(allocator);
        var functions: std.Io.Writer.Allocating = .init(allocator);
        for (module.declarations, 0..) |declaration, index| {
            if (self.isStored(self.module_index, index)) {
                try self.generateConstantDefinition(allocator, &reached, &constants.writer, declaration, index);
            }
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration, .struct_definition => continue,
                .trait_definition, .implementation, .import => continue,
            };
            for (function.signature.parameters) |parameter| {
                try self.recordType(allocator, &reached, ast.extractType(parameter.type));
            }
            try self.recordType(allocator, &reached, ast.extractType(function.signature.return_type));
            try functions.writer.writeByte('\n');
            try self.generateFunction(allocator, &reached, &functions.writer, function, index);
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
        for (reached.definitions.items) |value_type| {
            if (containsType(definitions, value_type)) continue;
            try writer.writeByte('\n');
            try self.generateDefinition(writer, value_type);
        }
        for (reached.equalities.items) |value_type| {
            try writer.writeByte('\n');
            if (value_type == .array) {
                try self.generateArrayEquality(writer, value_type);
            } else {
                try self.generateOptionalEquality(writer, value_type);
            }
        }
        try self.generateZeroSizedObject(writer, module);
        if (constants.written().len > 0) try writer.writeByte('\n');
        try writer.writeAll(constants.written());
        try writer.writeAll(functions.written());
    }

    fn generateArrayDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
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
    ) WriteError!void {
        const element = value_type.slice.element;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n    ");
        try self.generateTaggedType(writer, element);
        try writer.writeAll(" *items;\n    size_t length;\n} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n#endif\n");
    }

    fn generateOptionalDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const child = value_type.optional.child;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n");
        if (!isZeroSized(child)) {
            try writer.writeAll("    ");
            try self.generateType(writer, child);
            try writer.writeAll(" value;\n");
        }
        try writer.writeAll("    bool present;\n} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n#endif\n");
    }

    fn generateTupleDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n");
        for (value_type.tuple.elements, 0..) |element, index| {
            if (isZeroSized(element)) continue;
            try writer.writeAll("    ");
            try self.generateType(writer, element);
            try writer.print(" _{d};\n", .{index});
        }
        try writer.writeAll("} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n#endif\n");
    }

    fn generateArrayEquality(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const array = value_type.array;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal_defined\nstatic inline bool ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal(");
        try self.generateType(writer, value_type);
        try writer.writeAll(" one, ");
        try self.generateType(writer, value_type);
        try writer.print(
            " two) {{\n    for (size_t index = 0; index < {d}; index += 1) {{\n        if (",
            .{array.length},
        );
        if (hasEqualityHelper(array.element)) {
            try writer.writeByte('!');
            try self.generateType(writer, array.element);
            try writer.writeAll("_equal(one.items[index], two.items[index])");
        } else {
            try writer.writeAll("one.items[index] != two.items[index]");
        }
        try writer.writeAll(") return false;\n    }\n    return true;\n}\n#endif\n");
    }

    fn generateOptionalEquality(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const child = value_type.optional.child;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal_defined\nstatic inline bool ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_equal(");
        try self.generateType(writer, value_type);
        try writer.writeAll(" one, ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" two) {\n");
        if (isZeroSized(child)) {
            return writer.writeAll("    return one.present == two.present;\n}\n#endif\n");
        }
        try writer.writeAll("    if (one.present != two.present) return false;\n");
        try writer.writeAll("    if (!one.present) return true;\n    return ");
        if (hasEqualityHelper(child)) {
            try self.generateType(writer, child);
            try writer.writeAll("_equal(one.value, two.value)");
        } else {
            try writer.writeAll("one.value == two.value");
        }
        try writer.writeAll(";\n}\n#endif\n");
    }

    fn generateZeroSizedObject(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) WriteError!void {
        for (module.declarations) |declaration| {
            if (!self.isEntryPoint(declaration.kind)) continue;
            return writer.writeAll("\nchar mn_zero_sized;\n");
        }
    }

    fn generateConstantDefinition(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        declaration: ast.Declaration,
        index: usize,
    ) WriteError!void {
        const constant = &declaration.kind.constant_declaration;
        const value = &constant.value;
        const constant_type = ast.extractDeclaredType(constant.type, value.*);
        try self.recordType(allocator, reached, constant_type);
        try writer.writeAll("const ");
        try self.generateType(writer, constant_type);
        try writer.print(" {s} = ", .{self.names[self.module_index][index].?});
        try self.generateValue(allocator, reached, writer, value, .initializer);
        try writer.writeAll(";\n");
    }

    fn recordCalledFunction(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        function: ast.Resolution.Function,
    ) WriteError!void {
        const module = function.module;
        try self.recordModule(allocator, reached, module);
        switch (self.program.modules[module].declarations[function.declaration].kind) {
            .function_declaration => |function_declaration| {
                const name = function_declaration.name;
                const recorded = containsName(self.runtime_functions.items, name);
                if (isRuntimeFunction(name) and !recorded) {
                    try self.runtime_functions.append(allocator, name);
                }
            },
            .function_definition, .constant_declaration, .struct_definition => {},
            .trait_definition, .implementation, .import => {},
        }
    }

    fn recordType(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        value_type: types.Type,
    ) WriteError!void {
        var contained: std.ArrayList(usize) = .empty;
        try collectContainedModulesOf(allocator, &contained, value_type);
        for (contained.items) |module| try self.recordModule(allocator, reached, module);
        if (value_type == .slice) {
            if (containsType(reached.slices.items, value_type)) return;
            return reached.slices.append(allocator, value_type);
        }
        switch (value_type) {
            .array, .optional, .tuple => {},
            .function => |function| {
                for (function.parameters) |parameter| try self.recordType(allocator, reached, parameter);
                return self.recordType(allocator, reached, function.return_type);
            },
            .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .implementer => {
                return;
            },
        }
        if (isPointerOptional(value_type)) return self.recordType(allocator, reached, value_type.optional.child);
        if (isZeroSized(value_type)) return;
        if (containsType(reached.definitions.items, value_type)) return;
        switch (value_type) {
            .array => |array| try self.recordType(allocator, reached, array.element),
            .optional => |optional| try self.recordType(allocator, reached, optional.child),
            .tuple => |tuple| {
                for (tuple.elements) |element| try self.recordType(allocator, reached, element);
            },
            .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .function, .implementer => {
                unreachable;
            },
        }
        try reached.definitions.append(allocator, value_type);
    }

    fn recordPointerTarget(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        value_type: types.Type,
    ) WriteError!void {
        if (value_type != .pointer) return;
        try self.recordType(allocator, reached, value_type.pointer.target);
    }

    fn recordModule(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        module: usize,
    ) WriteError!void {
        const known = std.mem.findScalar(usize, reached.modules.items, module) != null;
        if (module != self.module_index and !known) try reached.modules.append(allocator, module);
    }

    fn generateFunction(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        function: ast.FunctionDefinition,
        index: usize,
    ) WriteError!void {
        self.local_names = try buildLocalNames(allocator, function);
        self.steps = try self.collectSteps(allocator, function);
        self.parameters = function.signature.parameters;
        self.return_type = ast.extractType(function.signature.return_type);
        self.in_main = self.isEntryPoint(.{ .function_definition = function });
        try self.generateSignature(writer, .{ .function_definition = function }, index);
        try writer.writeByte(' ');
        try self.generateBlock(allocator, reached, writer, function.body);
        try writer.writeByte('\n');
    }

    fn collectSteps(
        self: *const Generator,
        allocator: std.mem.Allocator,
        function: ast.FunctionDefinition,
    ) std.mem.Allocator.Error![]const Step {
        var statements: std.ArrayList(*const ast.Statement) = .empty;
        try collectStatements(allocator, &statements, function.body);
        var steps: std.ArrayList(Step) = .empty;
        for (statements.items) |statement| {
            if (statement.kind == .assignment) {
                const assignment = statement.kind.assignment;
                const written = self.hasTarget(assignment.target);
                const compound = assignment.operator != null and assignment.target.kind != .identifier;
                const address: ?types.Type = if (written and compound) address: {
                    const pointer = try self.program.types.addPointer(allocator, .{
                        .target = assignment.target.type.?,
                        .many = false,
                        .constant = false,
                    });
                    break :address .{ .pointer = pointer };
                } else null;
                try collectTargetSteps(allocator, &steps, statement, written, address);
            }
            const expression = findStatementExpression(statement) orelse continue;
            try collectScopeSteps(allocator, &steps, statement, expression);
        }
        return steps.items;
    }

    fn generateSignature(
        self: *Generator,
        writer: *std.Io.Writer,
        kind: ast.DeclarationKind,
        index: usize,
    ) WriteError!void {
        if (self.isEntryPoint(kind)) return writer.writeAll("int main()");
        const signature = switch (kind) {
            .function_definition => |function| function.signature,
            .function_declaration => |function_declaration| function_declaration,
            .constant_declaration, .struct_definition => unreachable,
            .trait_definition, .implementation, .import => unreachable,
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
    ) WriteError!void {
        try writer.writeByte('(');
        var written = false;
        for (parameters, 0..) |parameter, index| {
            const parameter_type = ast.extractType(parameter.type);
            if (isZeroSized(parameter_type)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateType(writer, parameter_type);
            if (!isDiscardedParameter(body, parameters, index)) {
                try writer.print(" {s}", .{parameter.name});
            }
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateBlock(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        block: []const ast.Statement,
    ) WriteError!void {
        const empty = for (block) |*statement| {
            if (self.hasOutput(statement)) break false;
        } else true;
        if (empty) return writer.writeAll("{}");

        try writer.writeAll("{\n");
        self.depth += 1;
        for (block) |*statement| try self.generateStatement(allocator, reached, writer, statement);
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeByte('}');
    }

    fn generateStatement(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        if (!self.hasOutput(statement)) return;
        try self.generateTemporaries(writer, statement);
        switch (statement.kind) {
            .noop => unreachable,
            .@"return" => {
                const returned = findStatementExpression(statement) orelse {
                    try self.generateIndentation(writer);
                    return writer.writeAll(if (self.in_main) "return 0;\n" else "return;\n");
                };
                if (isZeroSized(returned.type.?)) {
                    if (hasEffects(returned.*)) {
                        try self.generateIndentation(writer);
                        try self.generateStatementEffects(allocator, reached, writer, returned);
                        try writer.writeAll(";\n");
                    }
                    try self.generateIndentation(writer);
                    return writer.writeAll("return;\n");
                }
                try self.generateIndentation(writer);
                try writer.writeAll("return ");
                try self.generateFullValue(allocator, reached, writer, returned, self.return_type);
                try writer.writeAll(";\n");
            },
            .discard, .call => |*expression| {
                try self.generateExpressionStatement(allocator, reached, writer, expression);
            },
            .constant_declaration, .variable_declaration => {
                try self.generateLocal(allocator, reached, writer, statement);
            },
            .assignment => |*assignment| try self.generateAssignment(allocator, reached, writer, assignment),
            .@"while" => |*loop| try self.generateWhile(allocator, reached, writer, loop),
        }
    }

    fn generateTemporaries(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        for (self.steps) |step| {
            if (step.statement != statement) continue;
            const number = step.temporary orelse continue;
            try self.generateIndentation(writer);
            try self.generateType(writer, step.address orelse step.expression.type.?);
            try writer.print(" mn_temporary_{d};\n", .{number});
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
                if (self.hasTarget(assignment.target)) return true;
                return hasEffects(assignment.target) or hasEffects(assignment.value);
            },
            .discard => |expression| expression.kind != .identifier,
            .@"return", .call, .@"while" => true,
        };
    }

    fn hasTarget(self: *const Generator, target: ast.Expression) bool {
        if (isZeroSized(target.type.?)) return false;
        const root = findTargetRoot(target) orelse return true;
        return self.findLocalName(root) != null;
    }

    fn generateExpressionStatement(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
    ) WriteError!void {
        try self.generateIndentation(writer);
        try self.generateFullExpression(allocator, reached, writer, expression);
        try writer.writeAll(";\n");
    }

    fn generateLocal(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const value = findStatementExpression(statement).?;
        try self.generateIndentation(writer);
        const name = self.findLocalName(statement) orelse {
            try self.generateStatementEffects(allocator, reached, writer, value);
            return writer.writeAll(";\n");
        };
        const constant = statement.kind == .constant_declaration;
        const local_type = findLocalType(statement.*);
        try self.recordType(allocator, reached, local_type);
        const pointer = local_type == .pointer or isPointerOptional(local_type);
        if (constant and !pointer) try writer.writeAll("const ");
        try self.generateType(writer, local_type);
        if (constant and pointer) try writer.writeAll(" const");
        try writer.print(" {s}", .{name});
        if (value.kind != .undefined) {
            try writer.writeAll(" = ");
            try self.generateFullValue(allocator, reached, writer, value, local_type);
        }
        try writer.writeAll(";\n");
    }

    fn generateAssignment(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        assignment: *const ast.Assignment,
    ) WriteError!void {
        const target = &assignment.target;
        const value = &assignment.value;
        try self.generateIndentation(writer);
        if (!self.hasTarget(target.*)) {
            const target_effects = hasEffects(target.*);
            if (target_effects) try self.generateTargetEffects(allocator, reached, writer, target);
            if (hasEffects(value.*)) {
                if (target_effects) try writer.writeAll(", ");
                try self.generateStatementEffects(allocator, reached, writer, value);
            }
            return writer.writeAll(";\n");
        }
        if (assignment.operator) |operator| {
            return self.generateCompoundAssignment(allocator, reached, writer, assignment, operator);
        }
        try self.generateTarget(allocator, reached, writer, target);
        try writer.writeAll(" = ");
        try self.generateFullValue(allocator, reached, writer, value, target.type.?);
        try writer.writeAll(";\n");
    }

    fn generateCompoundAssignment(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        assignment: *const ast.Assignment,
        operator: ast.CompoundOperator,
    ) WriteError!void {
        const target = &assignment.target;
        const value = &assignment.value;
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = self.hasSteps(target);
        if (self.sequenced) {
            try self.generateSteps(allocator, reached, writer, target);
            try writer.writeAll(", ");
        }
        if (self.findAddressTemporary(target)) |number| {
            try writer.print("(*mn_temporary_{d})", .{number});
        } else {
            try self.generateExpression(allocator, reached, writer, target.*);
        }
        try writer.writeAll(" = ");
        self.sequenced = self.hasSteps(value);
        if (self.sequenced) {
            try writer.writeByte('(');
            try self.generateSteps(allocator, reached, writer, value);
            try writer.writeAll(", ");
        }
        try self.recordPointerTarget(allocator, reached, target.type.?);
        const operation: Operation = .{ .operator = operator.operator, .left = target, .right = value };
        try self.generateBinary(allocator, reached, writer, operation);
        if (self.sequenced) try writer.writeByte(')');
        try writer.writeAll(";\n");
    }

    fn generateTargetEffects(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        target: *const ast.Expression,
    ) WriteError!void {
        if (!self.hasSteps(target)) return self.generateEffects(allocator, reached, writer, target.*);
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = true;
        try self.generateSteps(allocator, reached, writer, target);
    }

    fn generateTarget(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        target: *const ast.Expression,
    ) WriteError!void {
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = self.hasSteps(target);
        if (self.sequenced) {
            try self.generateSteps(allocator, reached, writer, target);
            try writer.writeAll(", ");
        }
        try self.generateExpression(allocator, reached, writer, target.*);
    }

    fn generateWhile(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        loop: *const ast.While,
    ) WriteError!void {
        try self.generateIndentation(writer);
        try writer.writeAll("while (");
        try self.generateFullExpression(allocator, reached, writer, &loop.condition);
        try writer.writeAll(") ");
        try self.generateBlock(allocator, reached, writer, loop.body);
        try writer.writeByte('\n');
    }

    fn generateIndentation(self: *Generator, writer: *std.Io.Writer) WriteError!void {
        for (0..self.depth) |_| try writer.writeAll("    ");
    }

    fn generateFullExpression(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
    ) WriteError!void {
        try self.generateFullValue(allocator, reached, writer, expression, expression.type.?);
    }

    fn generateFullValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
    ) WriteError!void {
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = self.hasSteps(expression);
        if (!self.sequenced) return self.generateConverted(allocator, reached, writer, expression, expected);
        try writer.writeByte('(');
        try self.generateSteps(allocator, reached, writer, expression);
        try writer.writeAll(", ");
        try self.generateConverted(allocator, reached, writer, expression, expected);
        try writer.writeByte(')');
    }

    fn generateConverted(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
    ) WriteError!void {
        if (!isArrayToSlice(expression.type.?, expected)) return self.generateExpression(allocator, reached, writer, expression.*);
        try self.generateSliceOf(allocator, reached, writer, expression, null, null, expected, .expression);
    }

    fn generateStatementEffects(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
    ) WriteError!void {
        if (!self.hasSteps(expression)) return self.generateEffects(allocator, reached, writer, expression.*);
        if (!isZeroSized(expression.type.?)) {
            try writer.writeAll("(void)");
            return self.generateFullExpression(allocator, reached, writer, expression);
        }
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = true;
        try self.generateSteps(allocator, reached, writer, expression);
        if (!isUnit(expression.*)) return;
        try writer.writeAll(", ");
        try self.generateExpression(allocator, reached, writer, expression.*);
    }

    fn generateSteps(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        scope: *const ast.Expression,
    ) WriteError!void {
        var written = false;
        for (self.steps) |step| {
            if (step.scope != scope) continue;
            if (written) try writer.writeAll(", ");
            if (step.temporary) |number| try writer.print("mn_temporary_{d} = ", .{number});
            if (step.address == null) {
                if (self.findAddressTemporary(step.expression)) |number| {
                    try writer.print("(*mn_temporary_{d})", .{number});
                    written = true;
                    continue;
                }
            } else {
                try writer.writeByte('&');
            }
            try self.generateExpression(allocator, reached, writer, step.expression.*);
            written = true;
        }
    }

    fn hasSteps(self: *const Generator, scope: *const ast.Expression) bool {
        for (self.steps) |step| {
            if (step.scope == scope) return true;
        }
        return false;
    }

    fn findAddressTemporary(self: *const Generator, expression: *const ast.Expression) ?usize {
        for (self.steps) |step| {
            if (step.expression == expression and step.address != null) return step.temporary.?;
        }
        return null;
    }

    fn generateOperand(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
    ) WriteError!void {
        for (self.steps) |step| {
            if (step.expression != expression or step.address != null) continue;
            return writer.print("mn_temporary_{d}", .{step.temporary.?});
        }
        if (self.findAddressTemporary(expression)) |number| {
            return writer.print("(*mn_temporary_{d})", .{number});
        }
        try self.generateExpression(allocator, reached, writer, expression.*);
    }

    fn generateConvertedOperand(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
    ) WriteError!void {
        if (!isArrayToSlice(expression.type.?, expected)) return self.generateOperand(allocator, reached, writer, expression);
        try self.generateSliceOf(allocator, reached, writer, expression, null, null, expected, .expression);
    }

    fn generateConvertedValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
        form: Form,
    ) WriteError!void {
        if (form == .expression) return self.generateConvertedOperand(allocator, reached, writer, expression, expected);
        try self.generateValue(allocator, reached, writer, expression, form);
    }

    fn generateBase(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
    ) WriteError!void {
        if (expression.kind != .address_of) return self.generateOperand(allocator, reached, writer, expression);
        try writer.writeByte('(');
        try self.generateOperand(allocator, reached, writer, expression);
        try writer.writeByte(')');
    }

    fn generateExpression(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) WriteError!void {
        if (expression.type) |value_type| try self.recordType(allocator, reached, value_type);
        switch (expression.kind) {
            .integer_literal, .float_literal => |literal| {
                const number = expression.type.?.number;
                if (number == .i128 or number == .u128) {
                    const value = std.fmt.parseInt(u128, literal.text, 0) catch unreachable;
                    return self.generateSplitLiteral(writer, value, number);
                }
                var text = literal.text;
                if (std.mem.startsWith(u8, text, "0o")) {
                    try writer.writeByte('0');
                    text = text[2..];
                }
                for (text) |byte| try writer.writeByte(if (byte == '_') '\'' else byte);
                if (expression.kind == .float_literal and std.mem.indexOfAny(u8, text, ".eE") == null) {
                    try writer.writeAll(".0");
                }
                try writer.writeAll(switch (number) {
                    .u8, .u16, .u32, .u64, .usize => "u",
                    .f16 => "f16",
                    .f32 => "f",
                    .f128 => "f128",
                    .i8, .i16, .i32, .i64, .isize, .f64 => "",
                    .i128, .u128 => unreachable,
                });
            },
            .boolean_literal => |value| try writer.writeAll(if (value) "true" else "false"),
            .string_literal => try self.generateString(writer, expression, .expression),
            .undefined => unreachable,
            .null => try self.generateNull(writer, expression.type.?, .expression),
            .identifier => |identifier| switch (identifier.resolution.?) {
                .parameter => try writer.writeAll(identifier.name),
                .constant => |constant| try self.generateConstant(allocator, reached, writer, constant),
                .local => |statement| try writer.writeAll(self.findLocalName(statement).?),
                .function => |function| try self.generateFunctionName(allocator, reached, writer, function),
                .type => unreachable,
            },
            .path_expression => |path_expression| switch (path_expression.resolution.?) {
                .constant => |constant| try self.generateConstant(allocator, reached, writer, constant),
                .function => |function| try self.generateFunctionName(allocator, reached, writer, function),
                .parameter, .type, .local => unreachable,
            },
            .call => |call| {
                const hoists = try self.generateHoistedEffects(allocator, reached, writer, call.arguments);
                switch (ast.extractResolution(call.callee)) {
                    .function => |function| try self.generateFunctionCall(allocator, reached, writer, call, function),
                    .parameter, .local, .constant => try self.generateValueCall(allocator, reached, writer, call),
                    .type => unreachable,
                }
                if (hoists) try writer.writeByte(')');
            },
            .negation => |operand| switch (operand.kind) {
                .integer_literal => |literal| {
                    try self.generateNegativeInteger(writer, literal.text, expression.type.?.number);
                },
                .float_literal => {
                    try writer.writeByte('-');
                    try self.generateExpression(allocator, reached, writer, operand.*);
                },
                else => unreachable,
            },
            .binary => |binary| {
                const equality = binary.operator == .equal or binary.operator == .not_equal;
                if (equality and !ast.isNullComparison(binary)) try collectEqualities(allocator, &reached.equalities, binary.left.type.?);
                try self.recordPointerTarget(allocator, reached, binary.left.type.?);
                try self.recordPointerTarget(allocator, reached, binary.right.type.?);
                if (binary.operator == .@"orelse") return self.generateOrElse(allocator, reached, writer, expression);
                const operation: Operation = .{
                    .operator = binary.operator,
                    .left = binary.left,
                    .right = binary.right,
                };
                try self.generateBinary(allocator, reached, writer, operation);
            },
            .unary => |unary| try self.generateUnary(allocator, reached, writer, unary),
            .address_of => |operand| {
                if (isZeroSized(operand.type.?)) return self.generateZeroSizedAddress(allocator, reached, writer, expression);
                try writer.writeByte('&');
                try self.generateOperand(allocator, reached, writer, operand);
            },
            .composite_literal => |literal| {
                const hoists = try self.generateHoistedEffects(allocator, reached, writer, literal.elements);
                try writer.writeByte('(');
                try self.generateType(writer, expression.type.?);
                try writer.writeByte(')');
                try self.generateLiteralElements(allocator, reached, writer, expression, .expression);
                if (hoists) try writer.writeByte(')');
            },
            .index => |indexing| try self.generateIndex(allocator, reached, writer, indexing),
            .slice => try self.generateSlice(allocator, reached, writer, expression, .expression),
            .field_access => |access| {
                try self.recordPointerTarget(allocator, reached, access.value.type.?);
                try self.generateBase(allocator, reached, writer, access.value);
                const separator = if (access.value.type.? == .pointer) "->" else ".";
                try writer.print("{s}{s}", .{ separator, access.field });
            },
            .dereference => |operand| {
                try self.recordPointerTarget(allocator, reached, operand.type.?);
                try writer.writeAll("(*");
                try self.generateOperand(allocator, reached, writer, operand);
                try writer.writeByte(')');
            },
            .unwrap => |operand| {
                if (isPointerOptional(operand.type.?)) return self.generateOperand(allocator, reached, writer, operand);
                try self.generateBase(allocator, reached, writer, operand);
                try writer.writeAll(".value");
            },
            .method_call, .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {
                unreachable;
            },
        }
    }

    fn generateBinary(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operation: Operation,
    ) WriteError!void {
        const operand_type = operation.left.type.?;
        switch (operation.operator) {
            .@"and", .@"or" => {
                try writer.writeByte('(');
                try self.generateOperand(allocator, reached, writer, operation.left);
                try writer.writeAll(if (operation.operator == .@"and") " && " else " || ");
                try self.generateFullExpression(allocator, reached, writer, operation.right);
                return writer.writeByte(')');
            },
            .@"orelse" => unreachable,
            .shift_left => return self.generateHelperCall(allocator, reached, writer, "shift_left", operation),
            .shift_right => return self.generateHelperCall(allocator, reached, writer, "shift_right", operation),
            .remainder => {
                if (isSignedInteger(operand_type)) {
                    return self.generateHelperCall(allocator, reached, writer, "remainder", operation);
                }
            },
            .equal, .not_equal => {
                if (operation.left.kind == .null or operation.right.kind == .null) {
                    return self.generateNullComparison(allocator, reached, writer, operation);
                }
                if (operand_type == .array) return self.generateArrayComparison(allocator, reached, writer, operation);
                if (hasEqualityHelper(operand_type)) return self.generateEqualityCall(allocator, reached, writer, operation);
            },
            .subtract => {
                if (operation.right.type.? == .pointer) return self.generatePointerDifference(allocator, reached, writer, operation);
            },
            .multiply,
            .divide,
            .add,
            .bitwise_and,
            .bitwise_exclusive_or,
            .bitwise_or,
            .less_than,
            .less_than_or_equal,
            .greater_than,
            .greater_than_or_equal,
            => {},
        }
        const promoted = isPromoted(operand_type) and !isComparison(operation.operator);
        if (promoted) {
            try writer.writeAll("((");
            try self.generateType(writer, operand_type);
            try writer.writeByte(')');
        }
        try writer.writeByte('(');
        try self.generateOperand(allocator, reached, writer, operation.left);
        try writer.print(" {s} ", .{operatorSymbol(operation.operator)});
        try self.generateOperand(allocator, reached, writer, operation.right);
        try writer.writeByte(')');
        if (promoted) try writer.writeByte(')');
    }

    fn generateOrElse(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) WriteError!void {
        const binary = expression.kind.binary;
        const optional_type = binary.left.type.?;
        const pointer = isPointerOptional(optional_type);
        try writer.writeByte('(');
        try self.generateOperand(allocator, reached, writer, binary.left);
        try writer.writeAll(if (pointer) " != NULL ? " else ".present ? ");
        if (isZeroSized(expression.type.?)) {
            try writer.writeAll("(void)0 : ");
            if (hasEffects(binary.right.*)) {
                try writer.writeAll("(void)(");
                try self.generateStatementEffects(allocator, reached, writer, binary.right);
                try writer.writeAll("))");
                return;
            }
            return writer.writeAll("(void)0)");
        }
        try self.generateOperand(allocator, reached, writer, binary.left);
        const unwrapped = !std.meta.eql(expression.type.?, optional_type);
        if (!pointer and unwrapped) try writer.writeAll(".value");
        try writer.writeAll(" : ");
        try self.generateFullValue(allocator, reached, writer, binary.right, expression.type.?);
        try writer.writeByte(')');
    }

    fn generateNullComparison(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operation: Operation,
    ) WriteError!void {
        const operand = if (operation.left.kind == .null) operation.right else operation.left;
        const equal = operation.operator == .equal;
        if (isPointerOptional(operand.type.?)) {
            try writer.writeByte('(');
            try self.generateOperand(allocator, reached, writer, operand);
            return writer.writeAll(if (equal) " == NULL)" else " != NULL)");
        }
        try writer.writeAll(if (equal) "(!" else "(");
        try self.generateOperand(allocator, reached, writer, operand);
        try writer.writeAll(".present)");
    }

    fn generateHelperCall(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        name: []const u8,
        operation: Operation,
    ) WriteError!void {
        try writer.print("mn_{s}_{t}(", .{ name, operation.left.type.?.number });
        try self.generateOperand(allocator, reached, writer, operation.left);
        try writer.writeAll(", ");
        try self.generateOperand(allocator, reached, writer, operation.right);
        try writer.writeByte(')');
    }

    fn generatePointerDifference(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operation: Operation,
    ) WriteError!void {
        try writer.writeAll("((");
        try self.generateType(writer, .{ .number = .isize });
        try writer.writeAll(")(");
        try self.generateOperand(allocator, reached, writer, operation.left);
        try writer.writeAll(" - ");
        try self.generateOperand(allocator, reached, writer, operation.right);
        try writer.writeAll("))");
    }

    fn generateArrayComparison(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operation: Operation,
    ) WriteError!void {
        const array_type = operation.left.type.?;
        const equal = operation.operator == .equal;
        if (isZeroSized(array_type)) {
            const result = if (equal) "true" else "false";
            var written = false;
            for ([_]*const ast.Expression{ operation.left, operation.right }) |operand| {
                if (self.sequenced or !hasEffects(operand.*)) continue;
                try writer.writeAll(if (written) ", " else "(");
                try self.generateEffects(allocator, reached, writer, operand.*);
                written = true;
            }
            if (!written) return writer.writeAll(result);
            return writer.print(", {s})", .{result});
        }
        try self.generateEqualityCall(allocator, reached, writer, operation);
    }

    fn generateEqualityCall(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operation: Operation,
    ) WriteError!void {
        const equal = operation.operator == .equal;
        if (!equal) try writer.writeAll("(!");
        try self.generateType(writer, operation.left.type.?);
        try writer.writeAll("_equal(");
        try self.generateOperand(allocator, reached, writer, operation.left);
        try writer.writeAll(", ");
        try self.generateOperand(allocator, reached, writer, operation.right);
        try writer.writeByte(')');
        if (!equal) try writer.writeByte(')');
    }

    fn generateUnary(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        unary: ast.Unary,
    ) WriteError!void {
        const operand_type = unary.operand.type.?;
        const promoted = unary.operator != .not and isPromoted(operand_type);
        if (promoted) {
            try writer.writeAll("((");
            try self.generateType(writer, operand_type);
            try writer.writeByte(')');
        }
        try writer.writeAll(switch (unary.operator) {
            .negate => if (unary.operand.kind == .negation) "(- " else "(-",
            .not => "(!",
            .bitwise_not => "(~",
        });
        try self.generateOperand(allocator, reached, writer, unary.operand);
        try writer.writeByte(')');
        if (promoted) try writer.writeByte(')');
    }

    fn generateZeroSizedAddress(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) WriteError!void {
        const operand = expression.kind.address_of;
        const effects = !self.sequenced and hasEffects(operand.*);
        if (effects) {
            try writer.writeByte('(');
            try self.generateEffects(allocator, reached, writer, operand.*);
            try writer.writeAll(", ");
        }
        try writer.writeAll("((");
        try self.generateType(writer, expression.type.?);
        try writer.writeAll(")&mn_zero_sized)");
        if (effects) try writer.writeByte(')');
    }

    fn generateNull(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
        form: Form,
    ) WriteError!void {
        if (isPointerOptional(value_type)) return writer.writeAll("NULL");
        if (form == .expression) {
            try writer.writeByte('(');
            try self.generateType(writer, value_type);
            try writer.writeByte(')');
        }
        try writer.writeAll("{ .present = false }");
    }

    fn generateFunctionName(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        function: ast.Resolution.Function,
    ) WriteError!void {
        try self.recordCalledFunction(allocator, reached, function);
        try writer.writeAll(self.names[function.module][function.declaration].?);
    }

    fn generateNegativeInteger(
        self: *Generator,
        writer: *std.Io.Writer,
        text: []const u8,
        number: types.NumberType,
    ) WriteError!void {
        const value = std.fmt.parseInt(u128, text, 0) catch unreachable;
        const maximum: u128 = if (number == .i128) std.math.maxInt(i128) else std.math.maxInt(i64);
        const at_minimum = value > maximum;
        try writer.writeAll(if (at_minimum) "(-" else "-");
        const magnitude = if (at_minimum) maximum else value;
        if (number == .i128) {
            try self.generateSplitLiteral(writer, magnitude, number);
        } else {
            try writer.print("{d}", .{magnitude});
        }
        if (at_minimum) try writer.writeAll(" - 1)");
    }

    fn generateSplitLiteral(
        self: *Generator,
        writer: *std.Io.Writer,
        value: u128,
        number: types.NumberType,
    ) WriteError!void {
        const high: u64 = @truncate(value >> 64);
        const low: u64 = @truncate(value);
        try writer.writeAll("((");
        try self.generateType(writer, .{ .number = number });
        try writer.print(")0x{x}u << 64 | 0x{x}u)", .{ high, low });
    }

    fn generateIndex(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        indexing: ast.Index,
    ) WriteError!void {
        try self.recordPointerTarget(allocator, reached, indexing.value.type.?);
        try self.generateBase(allocator, reached, writer, indexing.value);
        switch (indexing.value.type.?) {
            .tuple => {
                const text = indexing.index.kind.integer_literal.text;
                const position = std.fmt.parseInt(u64, text, 0) catch unreachable;
                return writer.print("._{d}", .{position});
            },
            .array, .slice => try writer.writeAll(".items"),
            .pointer => |pointer| if (!pointer.many) try writer.writeAll("->items"),
            .number, .boolean, .void, .type, .@"struct", .optional, .function, .implementer => {
                unreachable;
            },
        }
        try writer.writeByte('[');
        try self.generateOperand(allocator, reached, writer, indexing.index);
        try writer.writeByte(']');
    }

    fn generateSlice(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
        form: Form,
    ) WriteError!void {
        const slice = expression.kind.slice;
        try self.generateSliceOf(allocator, reached, writer, slice.value, slice.start, slice.end, expression.type.?, form);
    }

    fn generateSliceOf(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        value: *const ast.Expression,
        start: ?*const ast.Expression,
        end: ?*const ast.Expression,
        slice_type: types.Type,
        form: Form,
    ) WriteError!void {
        const element = slice_type.slice.element;
        try self.recordType(allocator, reached, slice_type);
        try self.recordPointerTarget(allocator, reached, value.type.?);
        const sliced_type = followPointer(value.type.?);
        if (isZeroSized(sliced_type) or isZeroSized(element)) {
            const length_reads_value = end == null and sliced_type == .slice;
            const effects = !self.sequenced and !length_reads_value and hasEffects(value.*);
            if (effects) {
                try writer.writeByte('(');
                try self.generateEffects(allocator, reached, writer, value.*);
                try writer.writeAll(", ");
            }
            try self.generateSliceCast(writer, slice_type, form);
            try writer.writeAll("{ .length = ");
            try self.generateSliceLength(allocator, reached, writer, value, start, end, form);
            try writer.writeAll(" }");
            if (effects) try writer.writeByte(')');
            return;
        }
        try self.generateSliceCast(writer, slice_type, form);
        try writer.writeAll("{ .items = ");
        const read_only = switch (value.type.?) {
            .array => isStoredAsConstant(value.*),
            .pointer => |pointer| pointer.constant,
            .number, .boolean, .void, .type, .@"struct", .slice, .optional, .tuple, .function, .implementer => false,
        };
        if (read_only) {
            try writer.writeByte('(');
            try self.generateType(writer, element);
            try writer.writeAll(" *)");
        }
        try self.generateBase(allocator, reached, writer, value);
        switch (value.type.?) {
            .array, .slice => try writer.writeAll(".items"),
            .pointer => |pointer| if (!pointer.many) try writer.writeAll("->items"),
            .number, .boolean, .void, .type, .@"struct", .optional, .tuple, .function, .implementer => {
                unreachable;
            },
        }
        if (start) |offset| {
            try writer.writeAll(" + ");
            try self.generateValue(allocator, reached, writer, offset, form);
        }
        try writer.writeAll(", .length = ");
        try self.generateSliceLength(allocator, reached, writer, value, start, end, form);
        try writer.writeAll(" }");
    }

    fn generateSliceCast(
        self: *Generator,
        writer: *std.Io.Writer,
        slice_type: types.Type,
        form: Form,
    ) WriteError!void {
        if (form != .expression) return;
        try writer.writeByte('(');
        try self.generateType(writer, slice_type);
        try writer.writeByte(')');
    }

    fn generateSliceLength(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        value: *const ast.Expression,
        start: ?*const ast.Expression,
        end: ?*const ast.Expression,
        form: Form,
    ) WriteError!void {
        if (end) |bound| {
            try self.generateValue(allocator, reached, writer, bound, form);
        } else switch (followPointer(value.type.?)) {
            .array => |array| try writer.print("{d}", .{array.length}),
            .slice => {
                try self.generateBase(allocator, reached, writer, value);
                try writer.writeAll(".length");
            },
            .number, .boolean, .void, .type, .@"struct", .pointer, .optional, .tuple, .function, .implementer => {
                unreachable;
            },
        }
        const offset = start orelse return;
        try writer.writeAll(" - ");
        try self.generateValue(allocator, reached, writer, offset, form);
    }

    fn generateString(
        self: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
        form: Form,
    ) WriteError!void {
        const text = expression.kind.string_literal;
        const slice_type = expression.type.?;
        if (form == .expression) {
            try writer.writeByte('(');
            try self.generateType(writer, slice_type);
            try writer.writeByte(')');
        }
        try writer.writeAll("{ .items = (");
        try self.generateType(writer, slice_type.slice.element);
        try writer.writeAll(" *)\"");
        try generateText(writer, text);
        try writer.print("\", .length = {d} }}", .{countBytes(text)});
    }

    fn generateConstant(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        constant: ast.Resolution.Constant,
    ) WriteError!void {
        const declarations = self.program.modules[constant.module].declarations;
        const declaration = declarations[constant.declaration];
        if (self.isStored(constant.module, constant.declaration)) {
            try self.recordModule(allocator, reached, constant.module);
            return writer.writeAll(self.names[constant.module][constant.declaration].?);
        }
        try self.generateExpression(allocator, reached, writer, declaration.kind.constant_declaration.value);
    }

    fn generateHoistedEffects(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        children: []const ast.Argument,
    ) WriteError!bool {
        if (self.sequenced) return false;
        const hoists = for (children) |child| {
            if (isHoisted(child.value)) break true;
        } else false;
        if (!hoists) return false;
        try writer.writeByte('(');
        for (children) |child| {
            if (!isHoisted(child.value)) continue;
            try self.generateEffects(allocator, reached, writer, child.value);
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
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        call: ast.Call,
        function: ast.Resolution.Function,
    ) WriteError!void {
        try self.generateFunctionName(allocator, reached, writer, function);
        const declaration = self.program.modules[function.module].declarations[function.declaration];
        const parameters = ast.extractFunctionSignature(declaration).parameters;
        try writer.writeByte('(');
        var written = false;
        for (call.arguments, parameters) |*argument, parameter| {
            if (isZeroSized(argument.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateConvertedOperand(allocator, reached, writer, &argument.value, ast.extractType(parameter.type));
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateValueCall(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        call: ast.Call,
    ) WriteError!void {
        const callee_type = switch (ast.extractResolution(call.callee)) {
            .parameter => |index| callee_type: {
                try writer.writeAll(call.callee.identifier.name);
                break :callee_type ast.extractType(self.parameters[index].type);
            },
            .local => |statement| callee_type: {
                try writer.writeAll(self.findLocalName(statement).?);
                break :callee_type findLocalType(statement.*);
            },
            .constant => |constant| callee_type: {
                try self.generateConstant(allocator, reached, writer, constant);
                const declaration = self.program.modules[constant.module].declarations[constant.declaration];
                const constant_declaration = declaration.kind.constant_declaration;
                break :callee_type ast.extractDeclaredType(constant_declaration.type, constant_declaration.value);
            },
            .function, .type => unreachable,
        };
        try writer.writeByte('(');
        var written = false;
        for (call.arguments, callee_type.function.parameters) |*argument, parameter_type| {
            if (isZeroSized(argument.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateConvertedOperand(allocator, reached, writer, &argument.value, parameter_type);
            written = true;
        }
        try writer.writeByte(')');
    }

    fn generateLiteralElements(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
        form: Form,
    ) WriteError!void {
        const elements = expression.kind.composite_literal.elements;
        const literal_type = expression.type.?;
        if (literal_type == .@"struct") return self.generateFields(allocator, reached, writer, elements, literal_type, form);
        if (literal_type == .tuple) return self.generateTupleElements(allocator, reached, writer, elements, literal_type, form);
        try self.generateElements(allocator, reached, writer, elements, literal_type.array.element, form);
    }

    fn generateFields(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        elements: []const ast.Argument,
        value_type: types.Type,
        form: Form,
    ) WriteError!void {
        try writer.writeAll("{ ");
        var written = false;
        for (elements) |*element| {
            if (isZeroSized(element.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{element.name.?});
            const field_type = findFieldType(value_type.@"struct".fields, element.name.?);
            try self.generateConvertedValue(allocator, reached, writer, &element.value, field_type, form);
            written = true;
        }
        for (value_type.@"struct".fields) |field| {
            const default = field.default orelse continue;
            if (ast.findArgument(elements, field.name) != null) continue;
            if (isZeroSized(field.type)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{field.name});
            try self.generateValue(allocator, reached, writer, default, form);
            written = true;
        }
        try writer.writeAll(" }");
    }

    fn generateElements(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        elements: []const ast.Argument,
        element_type: types.Type,
        form: Form,
    ) WriteError!void {
        try writer.writeAll("{ .items = { ");
        for (elements, 0..) |*element, index| {
            if (index > 0) try writer.writeAll(", ");
            try self.generateConvertedValue(allocator, reached, writer, &element.value, element_type, form);
        }
        try writer.writeAll(" } }");
    }

    fn generateTupleElements(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        elements: []const ast.Argument,
        tuple_type: types.Type,
        form: Form,
    ) WriteError!void {
        try writer.writeAll("{ ");
        var written = false;
        for (elements, tuple_type.tuple.elements, 0..) |*element, element_type, index| {
            if (isZeroSized(element.value.type.?)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print("._{d} = ", .{index});
            try self.generateConvertedValue(allocator, reached, writer, &element.value, element_type, form);
            written = true;
        }
        try writer.writeAll(" }");
    }

    fn generateValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        form: Form,
    ) WriteError!void {
        if (form == .expression) return self.generateOperand(allocator, reached, writer, expression);
        if (expression.type) |value_type| try self.recordType(allocator, reached, value_type);
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .negation => {
                try self.generateExpression(allocator, reached, writer, expression.*);
            },
            .string_literal => try self.generateString(writer, expression.*, .initializer),
            inline .identifier, .path_expression => |name| {
                if (name.resolution.? == .function) {
                    return self.generateFunctionName(allocator, reached, writer, name.resolution.?.function);
                }
                const constant = name.resolution.?.constant;
                const declarations = self.program.modules[constant.module].declarations;
                const declaration = &declarations[constant.declaration];
                try self.generateValue(allocator, reached, writer, &declaration.kind.constant_declaration.value, form);
            },
            .composite_literal => try self.generateLiteralElements(allocator, reached, writer, expression.*, form),
            .null => try self.generateNull(writer, expression.type.?, form),
            .slice => try self.generateSlice(allocator, reached, writer, expression.*, form),
            .binary, .unary => try self.generateExpression(allocator, reached, writer, expression.*),
            .undefined,
            .address_of,
            .call,
            .method_call,
            .array_type,
            .slice_type,
            .index,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .field_access,
            .dereference,
            .unwrap,
            => unreachable,
        }
    }

    fn generateType(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        if (isZeroSized(value_type)) return writer.writeAll("void");
        try writer.writeAll(switch (value_type) {
            .number => |number| switch (number) {
                .i8 => "int8_t",
                .i16 => "int16_t",
                .i32 => "int32_t",
                .i64 => "int64_t",
                .i128 => "int128_t",
                .isize => "ptrdiff_t",
                .u8 => "uint8_t",
                .u16 => "uint16_t",
                .u32 => "uint32_t",
                .u64 => "uint64_t",
                .u128 => "uint128_t",
                .usize => "size_t",
                .f16 => "_Float16",
                .f32 => "float",
                .f64 => "double",
                .f128 => "_Float128",
            },
            .boolean => "bool",
            .void => "void",
            .type, .implementer => unreachable,
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
            .pointer => |pointer| {
                try self.generateTaggedType(writer, pointer.target);
                if (pointer.constant) try writer.writeAll(" const");
                return writer.writeAll(" *");
            },
            .optional => |optional| {
                if (isPointerOptional(value_type)) return self.generateType(writer, optional.child);
                try writer.writeAll("mn_optional_");
                return self.generateTypeName(writer, optional.child);
            },
            .tuple => {
                try writer.writeAll("mn_");
                return self.generateTypeName(writer, value_type);
            },
            .function => |function| {
                try writer.writeAll("typeof(");
                try self.generateTaggedType(writer, function.return_type);
                try writer.writeAll(" (*)(");
                var written = false;
                for (function.parameters) |parameter| {
                    if (isZeroSized(parameter)) continue;
                    if (written) try writer.writeAll(", ");
                    try self.generateTaggedType(writer, parameter);
                    written = true;
                }
                return writer.writeAll("))");
            },
        });
    }

    fn generateTaggedType(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const tagged = value_type == .@"struct" or value_type == .array or value_type == .slice or
            value_type == .tuple or (value_type == .optional and !isPointerOptional(value_type));
        if (tagged and !isZeroSized(value_type)) try writer.writeAll("struct ");
        try self.generateType(writer, value_type);
    }

    fn generateTypeName(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        switch (value_type) {
            .number => |number| try writer.writeAll(@tagName(number)),
            .boolean => try writer.writeAll("bool"),
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
            .pointer => |pointer| {
                try writer.writeAll(pointerPrefix(pointer.*));
                try self.generateTypeName(writer, pointer.target);
            },
            .optional => |optional| {
                try writer.writeAll("optional_");
                try self.generateTypeName(writer, optional.child);
            },
            .tuple => |tuple| {
                try writer.print("tuple_{d}", .{tuple.elements.len});
                for (tuple.elements) |element| {
                    try writer.writeByte('_');
                    try self.generateTypeName(writer, element);
                }
            },
            .function => |function| {
                try writer.print("function_{d}", .{function.parameters.len});
                for (function.parameters) |parameter| {
                    try writer.writeByte('_');
                    try self.generateTypeName(writer, parameter);
                }
                try writer.writeByte('_');
                try self.generateTypeName(writer, function.return_type);
            },
            .void => try writer.writeAll("void"),
            .type, .implementer => unreachable,
        }
    }

    fn generateEffects(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) WriteError!void {
        switch (expression.kind) {
            .call => return self.generateExpression(allocator, reached, writer, expression),
            .composite_literal => |literal| {
                var written = false;
                for (literal.elements) |element| {
                    if (!hasEffects(element.value)) continue;
                    if (written) try writer.writeAll(", ");
                    try self.generateEffects(allocator, reached, writer, element.value);
                    written = true;
                }
            },
            .negation => |operand| return self.generateEffects(allocator, reached, writer, operand.*),
            .binary => |binary| {
                if (isUnit(expression)) {
                    try writer.writeAll("(void)");
                    return self.generateExpression(allocator, reached, writer, expression);
                }
                var written = false;
                for ([_]*const ast.Expression{ binary.left, binary.right }) |operand| {
                    if (!hasEffects(operand.*)) continue;
                    if (written) try writer.writeAll(", ");
                    try self.generateEffects(allocator, reached, writer, operand.*);
                    written = true;
                }
            },
            .unary => |unary| return self.generateEffects(allocator, reached, writer, unary.operand.*),
            .address_of => |operand| return self.generateEffects(allocator, reached, writer, operand.*),
            .index => |indexing| {
                return self.generateOperandEffects(allocator, reached, writer, &.{ indexing.value, indexing.index });
            },
            .slice => |slice| {
                return self.generateOperandEffects(allocator, reached, writer, &.{ slice.value, slice.start, slice.end });
            },
            .field_access => |access| return self.generateEffects(allocator, reached, writer, access.value.*),
            .dereference, .unwrap => |operand| return self.generateEffects(allocator, reached, writer, operand.*),
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .identifier,
            .path_expression,
            .method_call,
            .array_type,
            .slice_type,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            => unreachable,
        }
    }

    fn generateOperandEffects(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        operands: []const ?*const ast.Expression,
    ) WriteError!void {
        var written = false;
        for (operands) |optional_operand| {
            const operand = optional_operand orelse continue;
            if (!hasEffects(operand.*)) continue;
            if (written) try writer.writeAll(", ");
            try self.generateEffects(allocator, reached, writer, operand.*);
            written = true;
        }
    }

    fn isStored(self: *const Generator, module_index: usize, index: usize) bool {
        const declaration = self.program.modules[module_index].declarations[index];
        const constant = switch (declaration.kind) {
            .constant_declaration => |constant| constant,
            .function_declaration, .function_definition, .struct_definition => return false,
            .trait_definition, .implementation, .import => return false,
        };
        if (ast.isAlias(constant) or constant.value.type == null) return false;
        const value_type = ast.extractDeclaredType(constant.type, constant.value);
        if (isZeroSized(value_type)) return false;
        if (value_type == .@"struct" or value_type == .array) return true;
        return containsConstant(self.addressed, .{ .module = module_index, .declaration = index });
    }

    fn isEntryPoint(self: *Generator, kind: ast.DeclarationKind) bool {
        if (self.module_index != 0 or kind != .function_definition) return false;
        return ast.isMain(kind.function_definition.signature);
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

const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

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
    definitions: std.ArrayList(types.Type) = .empty,
    equalities: std.ArrayList(types.Type) = .empty,
};

const Form = enum {
    expression,
    initializer,
};

const UnicodeEscape = struct {
    value: u21,
    length: usize,
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

const Operation = struct {
    operator: ast.BinaryOperator,
    left: *const ast.Expression,
    right: *const ast.Expression,
};

const Step = struct {
    expression: *const ast.Expression,
    scope: *const ast.Expression,
    statement: *const ast.Statement,
    temporary: ?usize,
    address: ?types.Type = null,
};

fn buildCNames(
    allocator: std.mem.Allocator,
    program: ast.Program,
) std.mem.Allocator.Error![]const []const ?[]const u8 {
    const names = try allocator.alloc([]const ?[]const u8, program.modules.len);
    for (program.modules, 0..) |module, module_index| {
        const module_names = try allocator.alloc(?[]const u8, module.declarations.len);
        for (module.declarations, 0..) |declaration, index| {
            module_names[index] = try buildCName(allocator, program, module_index, declaration);
        }
        names[module_index] = module_names;
    }
    return names;
}

fn buildCName(
    allocator: std.mem.Allocator,
    program: ast.Program,
    module_index: usize,
    declaration: ast.Declaration,
) std.mem.Allocator.Error!?[]const u8 {
    const module = program.modules[module_index];
    switch (declaration.kind) {
        .function_definition => |function| {
            const signature = function.signature;
            if (module_index == 0 and ast.isMain(signature)) return signature.name;
            const receiver = signature.receiver orelse {
                return try buildQualifiedName(allocator, module.path, signature.name);
            };
            const receiver_type = ast.extractType(receiver);
            const type_name = try buildTypeName(allocator, program, module_index, receiver_type);
            const trait = signature.trait orelse {
                const parts = &.{ type_name, "_", signature.name };
                const name = try std.mem.concat(allocator, u8, parts);
                return try buildQualifiedName(allocator, module.path, name);
            };
            const trait_name = extractLastName(trait);
            const parts = &.{ type_name, "_", trait_name, "_", signature.name };
            const name = try std.mem.concat(allocator, u8, parts);
            return try buildQualifiedName(allocator, module.path, name);
        },
        .function_declaration => |function_declaration| return function_declaration.name,
        .constant_declaration => |constant| {
            return try buildQualifiedName(allocator, module.path, constant.name);
        },
        .struct_definition, .trait_definition, .implementation, .import => return null,
    }
}

fn buildTypeName(
    allocator: std.mem.Allocator,
    program: ast.Program,
    module_index: usize,
    value_type: types.Type,
) std.mem.Allocator.Error![]const u8 {
    return switch (value_type) {
        .@"struct" => |struct_type| {
            if (struct_type.module == module_index) return struct_type.name;
            const path = try std.mem.join(allocator, "_", program.modules[struct_type.module].path);
            return std.mem.concat(allocator, u8, &.{ path, "_", struct_type.name });
        },
        .number => |number| @tagName(number),
        .boolean => "bool",
        .array => |array| {
            const element = try buildTypeName(allocator, program, module_index, array.element);
            return std.fmt.allocPrint(allocator, "array_{d}_{s}", .{ array.length, element });
        },
        .slice => |slice| {
            const element = try buildTypeName(allocator, program, module_index, slice.element);
            return std.mem.concat(allocator, u8, &.{ "slice_", element });
        },
        .pointer => |pointer| {
            const target = try buildTypeName(allocator, program, module_index, pointer.target);
            return std.mem.concat(allocator, u8, &.{ pointerPrefix(pointer.*), target });
        },
        .optional => |optional| {
            const child = try buildTypeName(allocator, program, module_index, optional.child);
            return std.mem.concat(allocator, u8, &.{ "optional_", child });
        },
        .tuple => |tuple| {
            var name: std.ArrayList(u8) = .empty;
            try name.print(allocator, "tuple_{d}", .{tuple.elements.len});
            for (tuple.elements) |element| {
                try name.append(allocator, '_');
                try name.appendSlice(allocator, try buildTypeName(allocator, program, module_index, element));
            }
            return name.items;
        },
        .function => |function| {
            var name: std.ArrayList(u8) = .empty;
            try name.print(allocator, "function_{d}", .{function.parameters.len});
            for (function.parameters) |parameter| {
                try name.append(allocator, '_');
                try name.appendSlice(allocator, try buildTypeName(allocator, program, module_index, parameter));
            }
            try name.append(allocator, '_');
            try name.appendSlice(allocator, try buildTypeName(allocator, program, module_index, function.return_type));
            return name.items;
        },
        .void => "void",
        .type, .implementer => unreachable,
    };
}

fn pointerPrefix(pointer: types.Pointer) []const u8 {
    if (pointer.many) return if (pointer.constant) "pointer_many_const_" else "pointer_many_";
    return if (pointer.constant) "pointer_const_" else "pointer_";
}

fn extractLastName(expression: ast.Expression) []const u8 {
    return switch (expression.kind) {
        .identifier => |identifier| identifier.name,
        .path_expression => |path_expression| path_expression.path[path_expression.path.len - 1],
        else => unreachable,
    };
}

fn buildQualifiedName(
    allocator: std.mem.Allocator,
    path: ast.Path,
    name: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const joined = try std.mem.join(allocator, "_", path);
    return std.mem.concat(allocator, u8, &.{ "mn_", joined, "_", name });
}

fn collectContainedModulesOf(
    allocator: std.mem.Allocator,
    contained: *std.ArrayList(usize),
    value_type: types.Type,
) std.mem.Allocator.Error!void {
    if (isZeroSized(value_type)) return;
    switch (value_type) {
        .@"struct" => |struct_type| {
            if (std.mem.findScalar(usize, contained.items, struct_type.module) != null) return;
            try contained.append(allocator, struct_type.module);
        },
        .array => |array| try collectContainedModulesOf(allocator, contained, array.element),
        .optional => |optional| {
            if (isPointerOptional(value_type)) return;
            try collectContainedModulesOf(allocator, contained, optional.child);
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                try collectContainedModulesOf(allocator, contained, element);
            }
        },
        .number, .boolean, .void, .type, .slice, .pointer, .function, .implementer => {},
    }
}

fn collectPrototypeTags(
    allocator: std.mem.Allocator,
    tags: *std.ArrayList(types.Type),
    value_type: types.Type,
    in_prototype: bool,
) std.mem.Allocator.Error!void {
    if (isZeroSized(value_type)) return;
    switch (value_type) {
        .function => |function| {
            for (function.parameters) |parameter| {
                try collectPrototypeTags(allocator, tags, parameter, true);
            }
            try collectPrototypeTags(allocator, tags, function.return_type, true);
        },
        .pointer => |pointer| try collectPrototypeTags(allocator, tags, pointer.target, in_prototype),
        .optional => |optional| {
            if (isPointerOptional(value_type)) {
                return collectPrototypeTags(allocator, tags, optional.child, in_prototype);
            }
            if (!in_prototype) return collectPrototypeTags(allocator, tags, optional.child, false);
            if (!containsType(tags.items, value_type)) try tags.append(allocator, value_type);
        },
        .@"struct", .array, .slice, .tuple => {
            if (!in_prototype or containsType(tags.items, value_type)) return;
            try tags.append(allocator, value_type);
        },
        .number, .boolean, .void, .type, .implementer => {},
    }
}

fn isHoisted(argument: ast.Expression) bool {
    return isZeroSized(argument.type.?) and hasEffects(argument);
}

fn hasEffects(expression: ast.Expression) bool {
    switch (expression.kind) {
        .call => return true,
        .composite_literal => |literal| {
            for (literal.elements) |element| {
                if (hasEffects(element.value)) return true;
            }
            return false;
        },
        .negation => |operand| return hasEffects(operand.*),
        .binary => |binary| return hasEffects(binary.left.*) or hasEffects(binary.right.*),
        .unary => |unary| return hasEffects(unary.operand.*),
        .address_of => |operand| return hasEffects(operand.*),
        .index => |indexing| return hasEffects(indexing.value.*) or hasEffects(indexing.index.*),
        .slice => |slice| {
            if (hasEffects(slice.value.*)) return true;
            if (slice.start) |start| {
                if (hasEffects(start.*)) return true;
            }
            const end = slice.end orelse return false;
            return hasEffects(end.*);
        },
        .field_access => |access| return hasEffects(access.value.*),
        .dereference, .unwrap => |operand| return hasEffects(operand.*),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        => return false,
        .method_call => unreachable,
    }
}

fn isUnit(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .call => true,
        .binary => |binary| isShortCircuit(binary.operator) and hasEffects(binary.right.*),
        else => false,
    };
}

fn isShortCircuit(operator: ast.BinaryOperator) bool {
    return operator == .@"and" or operator == .@"or" or operator == .@"orelse";
}

fn isComparison(operator: ast.BinaryOperator) bool {
    return switch (operator) {
        .equal,
        .not_equal,
        .less_than,
        .less_than_or_equal,
        .greater_than,
        .greater_than_or_equal,
        => true,
        .multiply,
        .divide,
        .remainder,
        .add,
        .subtract,
        .shift_left,
        .shift_right,
        .bitwise_and,
        .bitwise_exclusive_or,
        .bitwise_or,
        .@"orelse",
        .@"and",
        .@"or",
        => false,
    };
}

fn operatorSymbol(operator: ast.BinaryOperator) []const u8 {
    return switch (operator) {
        .multiply => "*",
        .divide => "/",
        .remainder => "%",
        .add => "+",
        .subtract => "-",
        .bitwise_and => "&",
        .bitwise_exclusive_or => "^",
        .bitwise_or => "|",
        .equal => "==",
        .not_equal => "!=",
        .less_than => "<",
        .less_than_or_equal => "<=",
        .greater_than => ">",
        .greater_than_or_equal => ">=",
        .shift_left, .shift_right, .@"and", .@"or", .@"orelse" => unreachable,
    };
}

fn isPromoted(value_type: types.Type) bool {
    if (value_type != .number) return false;
    return switch (value_type.number) {
        .i8, .i16, .u8, .u16, .f16 => true,
        .i32, .i64, .i128, .isize, .u32, .u64, .u128, .usize, .f32, .f64, .f128 => false,
    };
}

fn isSignedInteger(value_type: types.Type) bool {
    if (value_type != .number) return false;
    return switch (value_type.number) {
        .i8, .i16, .i32, .i64, .i128, .isize => true,
        .u8, .u16, .u32, .u64, .u128, .usize, .f16, .f32, .f64, .f128 => false,
    };
}

fn collectEqualities(
    allocator: std.mem.Allocator,
    equalities: *std.ArrayList(types.Type),
    value_type: types.Type,
) std.mem.Allocator.Error!void {
    if (!hasEqualityHelper(value_type)) return;
    if (containsType(equalities.items, value_type)) return;
    const child = switch (value_type) {
        .array => |array| array.element,
        .optional => |optional| optional.child,
        .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .tuple, .function, .implementer => {
            unreachable;
        },
    };
    try collectEqualities(allocator, equalities, child);
    try equalities.append(allocator, value_type);
}

fn hasEqualityHelper(value_type: types.Type) bool {
    return switch (value_type) {
        .array => !isZeroSized(value_type),
        .optional => !isPointerOptional(value_type),
        .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .tuple, .function, .implementer => false,
    };
}

fn collectTargetSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    statement: *const ast.Statement,
    written: bool,
    address: ?types.Type,
) std.mem.Allocator.Error!void {
    const assignment = &statement.kind.assignment;
    const target = &assignment.target;
    const value_calls = written and try containsUnit(allocator, &assignment.value);
    const followed = value_calls and address == null;
    const ordered = followed and try containsUnit(allocator, target);
    const sequenced = ordered or try needsSequence(allocator, target) or
        try containsFollowedRead(allocator, target, followed);
    if (sequenced) try collectUnitSteps(allocator, steps, statement, target, target, written, followed);
    try collectInnerScopeSteps(allocator, steps, statement, target);
    if (address) |pointer_type| {
        try steps.append(allocator, .{
            .expression = target,
            .scope = target,
            .statement = statement,
            .temporary = countTemporaries(steps.items) + 1,
            .address = pointer_type,
        });
    }
    if (assignment.operator == null or !value_calls) return;
    try steps.append(allocator, .{
        .expression = target,
        .scope = target,
        .statement = statement,
        .temporary = countTemporaries(steps.items) + 1,
    });
}

fn findStatementExpression(statement: *const ast.Statement) ?*const ast.Expression {
    return switch (statement.kind) {
        .noop => null,
        .@"return" => |*value| if (value.*) |*returned| returned else null,
        .discard, .call => |*expression| expression,
        .constant_declaration => |*constant| &constant.value,
        .variable_declaration => |*variable| &variable.value,
        .assignment => |*assignment| &assignment.value,
        .@"while" => |*loop| &loop.condition,
    };
}

fn collectScopeSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    statement: *const ast.Statement,
    scope: *const ast.Expression,
) std.mem.Allocator.Error!void {
    if (try needsSequence(allocator, scope)) {
        const consumed = isUnit(scope.*) or !isZeroSized(scope.type.?);
        try collectUnitSteps(allocator, steps, statement, scope, scope, consumed, false);
    }
    try collectInnerScopeSteps(allocator, steps, statement, scope);
}

fn needsSequence(
    allocator: std.mem.Allocator,
    expression: *const ast.Expression,
) std.mem.Allocator.Error!bool {
    if (try repeatsUnit(allocator, expression)) return true;
    if (repeatsOptional(expression.*)) return true;
    if (try containsFollowedRead(allocator, expression, false)) return true;
    var branches: usize = 0;
    for (try collectScopeChildren(allocator, expression)) |child| {
        if (try needsSequence(allocator, child)) return true;
        if (try containsUnit(allocator, child)) branches += 1;
    }
    return branches > 1;
}

fn repeatsUnit(
    allocator: std.mem.Allocator,
    expression: *const ast.Expression,
) std.mem.Allocator.Error!bool {
    if (expression.kind != .slice) return false;
    const slice = expression.kind.slice;
    if (slice.start) |start| {
        if (try containsUnit(allocator, start)) return true;
    }
    if (slice.end != null or slice.value.type.? != .slice) return false;
    return containsUnit(allocator, slice.value);
}

fn repeatsOptional(expression: ast.Expression) bool {
    if (expression.kind != .binary or expression.kind.binary.operator != .@"orelse") return false;
    return !isPlainName(expression.kind.binary.left.*);
}

fn isPlainName(expression: ast.Expression) bool {
    return expression.kind == .identifier or expression.kind == .path_expression;
}

fn containsUnit(
    allocator: std.mem.Allocator,
    expression: *const ast.Expression,
) std.mem.Allocator.Error!bool {
    if (isUnit(expression.*)) return true;
    for (try collectScopeChildren(allocator, expression)) |child| {
        if (try containsUnit(allocator, child)) return true;
    }
    return false;
}

fn containsFollowedRead(
    allocator: std.mem.Allocator,
    expression: *const ast.Expression,
    followed: bool,
) std.mem.Allocator.Error!bool {
    const children = try collectScopeChildren(allocator, expression);
    for (children, 0..) |child, index| {
        const unit = isUnit(child.*);
        const child_followed = followed or try containsAnyUnit(allocator, children[index + 1 ..]);
        if (!unit and child_followed and isChangingRead(expression.*, child)) return true;
        const inner_followed = if (unit) false else child_followed;
        if (try containsFollowedRead(allocator, child, inner_followed)) return true;
    }
    return false;
}

fn containsAnyUnit(
    allocator: std.mem.Allocator,
    expressions: []const *const ast.Expression,
) std.mem.Allocator.Error!bool {
    for (expressions) |expression| {
        if (try containsUnit(allocator, expression)) return true;
    }
    return false;
}

fn isChangingRead(parent: ast.Expression, child: *const ast.Expression) bool {
    if (isZeroSized(child.type.?) or isPlaceOperand(parent, child)) return false;
    return isMemoryRead(child.*);
}

fn isPlaceOperand(parent: ast.Expression, child: *const ast.Expression) bool {
    return switch (parent.kind) {
        .address_of, .unwrap => true,
        .field_access => |access| access.value.type.? != .pointer,
        .index => |indexing| child == indexing.value and isStorage(indexing.value.type.?),
        .slice => |slice| child == slice.value and slice.value.type.? == .array,
        else => false,
    };
}

fn isMemoryRead(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .identifier => |identifier| switch (identifier.resolution.?) {
            .local => |statement| statement.kind == .variable_declaration,
            .parameter, .constant, .function, .type => false,
        },
        .field_access => |access| access.value.type.? == .pointer or isMemoryRead(access.value.*),
        .index => |indexing| !isStorage(indexing.value.type.?) or isMemoryRead(indexing.value.*),
        .dereference => true,
        .unwrap => |operand| isMemoryRead(operand.*),
        else => false,
    };
}

fn isStorage(value_type: types.Type) bool {
    return value_type == .array or value_type == .tuple;
}

fn collectUnitSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    statement: *const ast.Statement,
    scope: *const ast.Expression,
    expression: *const ast.Expression,
    consumed: bool,
    followed: bool,
) std.mem.Allocator.Error!void {
    const repeated: ?*const ast.Expression = if (repeatsOptional(expression.*))
        expression.kind.binary.left
    else
        null;
    const children = try collectScopeChildren(allocator, expression);
    for (children, 0..) |child, index| {
        const unit = isUnit(child.*);
        const kept = child == repeated;
        const child_followed = followed or try containsAnyUnit(allocator, children[index + 1 ..]);
        const read = !unit and child_followed and isChangingRead(expression.*, child);
        const step = unit or kept or read;
        const inner_followed = if (step) false else child_followed;
        try collectUnitSteps(allocator, steps, statement, scope, child, consumed or step, inner_followed);
        if (!step) continue;
        const stored = (consumed or kept or read) and !isZeroSized(child.type.?);
        try steps.append(allocator, .{
            .expression = child,
            .scope = scope,
            .statement = statement,
            .temporary = if (stored) countTemporaries(steps.items) + 1 else null,
        });
    }
}

fn collectInnerScopeSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    statement: *const ast.Statement,
    expression: *const ast.Expression,
) std.mem.Allocator.Error!void {
    if (expression.kind == .binary and isShortCircuit(expression.kind.binary.operator)) {
        try collectScopeSteps(allocator, steps, statement, expression.kind.binary.right);
    }
    for (try collectScopeChildren(allocator, expression)) |child| {
        try collectInnerScopeSteps(allocator, steps, statement, child);
    }
}

fn collectScopeChildren(
    allocator: std.mem.Allocator,
    expression: *const ast.Expression,
) std.mem.Allocator.Error![]const *const ast.Expression {
    var children: std.ArrayList(*const ast.Expression) = .empty;
    switch (expression.kind) {
        .call => |call| {
            for (call.arguments) |*argument| try children.append(allocator, &argument.value);
        },
        .composite_literal => |literal| {
            for (literal.elements) |*element| try children.append(allocator, &element.value);
        },
        .binary => |binary| {
            try children.append(allocator, binary.left);
            if (!isShortCircuit(binary.operator)) try children.append(allocator, binary.right);
        },
        .unary => |unary| try children.append(allocator, unary.operand),
        .address_of => |operand| try children.append(allocator, operand),
        .index => |indexing| {
            try children.append(allocator, indexing.value);
            try children.append(allocator, indexing.index);
        },
        .slice => |slice| {
            try children.append(allocator, slice.value);
            if (slice.start) |start| try children.append(allocator, start);
            if (slice.end) |end| try children.append(allocator, end);
        },
        .field_access => |access| try children.append(allocator, access.value),
        .dereference, .unwrap => |operand| try children.append(allocator, operand),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .method_call,
        .negation,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        => {},
    }
    return children.items;
}

fn countTemporaries(steps: []const Step) usize {
    var count: usize = 0;
    for (steps) |step| {
        if (step.temporary != null) count += 1;
    }
    return count;
}

fn extractBody(kind: ast.DeclarationKind) []const ast.Statement {
    return switch (kind) {
        .function_definition => |function| function.body,
        .function_declaration, .constant_declaration, .struct_definition => &.{},
        .trait_definition, .implementation, .import => &.{},
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
        if (isDiscardedParameter(body, function.signature.parameters, index)) continue;
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

fn findLocalType(statement: ast.Statement) types.Type {
    return switch (statement.kind) {
        .constant_declaration => |constant| ast.extractDeclaredType(constant.type, constant.value),
        .variable_declaration => |variable| ast.extractDeclaredType(variable.type, variable.value),
        .noop, .@"return", .discard, .call, .assignment, .@"while" => unreachable,
    };
}

fn isDeclared(body: []const ast.Statement, statement: *const ast.Statement) bool {
    const kind = statement.kind;
    if (kind != .constant_declaration and kind != .variable_declaration) return false;
    if (kind == .constant_declaration and ast.isAlias(kind.constant_declaration)) return false;
    if (isZeroSized(findLocalType(statement.*))) return false;
    return !isDiscarded(body, .{ .local = statement });
}

fn isDiscardedParameter(
    body: []const ast.Statement,
    parameters: []const ast.TypedName,
    index: usize,
) bool {
    if (ast.isDiscardedName(parameters[index].name)) return true;
    return isDiscarded(body, .{ .parameter = index });
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
        .field_access => |access| {
            const value_type = access.value.type.?;
            if (value_type == .pointer) return value_type.pointer.constant;
            return isStoredAsConstant(access.value.*);
        },
        .index => |indexing| switch (indexing.value.type.?) {
            .array, .tuple => isStoredAsConstant(indexing.value.*),
            .pointer => |pointer| pointer.constant,
            .slice => false,
            .number, .boolean, .void, .type, .@"struct", .optional, .function, .implementer => {
                unreachable;
            },
        },
        .dereference => |operand| operand.type.?.pointer.constant,
        else => unreachable,
    };
}

fn findTargetRoot(target: ast.Expression) ?*const ast.Statement {
    return switch (target.kind) {
        .identifier => |identifier| identifier.resolution.?.local,
        .field_access => |access| {
            if (access.value.type.? == .pointer) return null;
            return findTargetRoot(access.value.*);
        },
        .index => |indexing| switch (indexing.value.type.?) {
            .array, .tuple => findTargetRoot(indexing.value.*),
            .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .optional, .function, .implementer => {
                return null;
            },
        },
        .dereference => null,
        else => unreachable,
    };
}

fn collectAddressedConstants(
    allocator: std.mem.Allocator,
    program: ast.Program,
) std.mem.Allocator.Error![]const ast.Resolution.Constant {
    var addressed: std.ArrayList(ast.Resolution.Constant) = .empty;
    for (program.modules) |module| {
        for (module.declarations) |declaration| {
            if (declaration.kind != .function_definition) continue;
            var statements: std.ArrayList(*const ast.Statement) = .empty;
            try collectStatements(allocator, &statements, declaration.kind.function_definition.body);
            for (statements.items) |statement| {
                if (statement.kind == .assignment) {
                    const target = &statement.kind.assignment.target;
                    try collectAddressedConstantsOf(allocator, &addressed, target);
                }
                const expression = findStatementExpression(statement) orelse continue;
                try collectAddressedConstantsOf(allocator, &addressed, expression);
            }
        }
    }
    return addressed.items;
}

fn collectAddressedConstantsOf(
    allocator: std.mem.Allocator,
    addressed: *std.ArrayList(ast.Resolution.Constant),
    expression: *const ast.Expression,
) std.mem.Allocator.Error!void {
    if (expression.kind == .address_of) {
        if (ast.findConstantRoot(expression.kind.address_of.*)) |constant| {
            if (!containsConstant(addressed.items, constant)) try addressed.append(allocator, constant);
        }
    }
    if (expression.kind == .binary and isShortCircuit(expression.kind.binary.operator)) {
        try collectAddressedConstantsOf(allocator, addressed, expression.kind.binary.right);
    }
    for (try collectScopeChildren(allocator, expression)) |child| {
        try collectAddressedConstantsOf(allocator, addressed, child);
    }
}

fn isArrayToSlice(value_type: types.Type, expected: types.Type) bool {
    if (expected != .slice or value_type != .pointer) return false;
    return !value_type.pointer.many and value_type.pointer.target == .array;
}

fn findFieldType(fields: []const types.Field, name: []const u8) types.Type {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    unreachable;
}

fn isPointerOptional(value_type: types.Type) bool {
    if (value_type != .optional) return false;
    const child = value_type.optional.child;
    return child == .pointer or child == .function;
}

fn findStruct(value_type: types.Type) ?types.Struct {
    return switch (value_type) {
        .@"struct" => |struct_type| struct_type,
        .number, .boolean, .void, .type, .array, .slice, .pointer, .optional, .tuple, .function, .implementer => {
            return null;
        },
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
        .optional => |optional| {
            if (isPointerOptional(value_type)) return;
            try orderDefinition(allocator, ordered, module_index, optional.child);
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                try orderDefinition(allocator, ordered, module_index, element);
            }
        },
        .number, .boolean, .void, .type, .pointer, .function, .implementer => return,
    }
    try ordered.append(allocator, value_type);
}

fn generateText(writer: *std.Io.Writer, text: []const u8) WriteError!void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try writer.writeByte(text[index]);
            index += 1;
            continue;
        }
        switch (text[index + 1]) {
            '0' => {
                try writer.writeAll("\\000");
                index += 2;
            },
            'u' => {
                const escape = parseUnicodeEscape(text[index..]);
                var bytes: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(escape.value, &bytes) catch unreachable;
                for (bytes[0..length]) |byte| try writer.print("\\{o:0>3}", .{byte});
                index += escape.length;
            },
            else => {
                try writer.writeAll(text[index .. index + 2]);
                index += 2;
            },
        }
    }
}

fn countBytes(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "\\u")) {
            const escape = parseUnicodeEscape(text[index..]);
            count += std.unicode.utf8CodepointSequenceLength(escape.value) catch unreachable;
            index += escape.length;
        } else {
            count += 1;
            index += if (text[index] == '\\') 2 else 1;
        }
    }
    return count;
}

fn parseUnicodeEscape(text: []const u8) UnicodeEscape {
    const end = std.mem.indexOfScalar(u8, text, '}').?;
    const value = std.fmt.parseInt(u21, text[3..end], 16) catch unreachable;
    return .{ .value = value, .length = end + 1 };
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

fn containsConstant(
    constants: []const ast.Resolution.Constant,
    constant: ast.Resolution.Constant,
) bool {
    for (constants) |existing| {
        if (std.meta.eql(existing, constant)) return true;
    }
    return false;
}

fn isSameCType(one: types.Type, two: types.Type) bool {
    return switch (one) {
        .array => |array| two == .array and array.length == two.array.length and
            isSameCType(array.element, two.array.element),
        .slice => |slice| two == .slice and isSameCType(slice.element, two.slice.element),
        .pointer => |pointer| two == .pointer and pointer.many == two.pointer.many and
            pointer.constant == two.pointer.constant and isSameCType(pointer.target, two.pointer.target),
        .optional => |optional| two == .optional and isSameCType(optional.child, two.optional.child),
        .tuple => |tuple| two == .tuple and isSameCTypes(tuple.elements, two.tuple.elements),
        .function => |function| two == .function and
            isSameCType(function.return_type, two.function.return_type) and
            isSameCTypes(function.parameters, two.function.parameters),
        .number, .boolean, .void, .type, .@"struct", .implementer => {
            return std.meta.eql(one, two);
        },
    };
}

fn isSameCTypes(one: []const types.Type, two: []const types.Type) bool {
    if (one.len != two.len) return false;
    for (one, two) |element_one, element_two| {
        if (!isSameCType(element_one, element_two)) return false;
    }
    return true;
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(int32_t: i32) -> i32: return int32_t" });
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {}\n\nvoid mn_main_two() {}\n",
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
        "#include \"main.h\"\n#include \"utils.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_utils_add(1);\n}\n",
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
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
        "#include \"main.h\"\n#include \"std/stdout.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_runtime_stdout_write((mn_slice_u8){ .items = (uint8_t *)\"hi\", .length = 2 });\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings("std/stdout.h", files[2].path);
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"../runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nvoid mn_runtime_stdout_write(mn_slice_u8 text);\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32\nexternal fn make() -> Line" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn width() -> i32: return shapes::make().width" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: i32\nconst origin = Point{x = 0}" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return shapes::origin.x" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, char: i32) -> i32:\n    _ = left\n    return char" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const int = 5i32\n    return int" });
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

test "checkName: accepts string as a name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(string: i32) -> i32: return string" });
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
        "#include \"main.h\"\n\nint32_t mn_main_add(int32_t string) {\n    return string;\n}\n",
        files[1].contents,
    );
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(MONOLITH_H: i32) -> i32: return MONOLITH_H" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(size_t: i32) -> i32: return size_t" });
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

test "checkName: rejects the 128-bit type names" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(uint128_t: i32) -> i32: return uint128_t" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(int_: i32, int: i32) -> i32:\n    _ = take(int_)\n    return int\nfn take(value: i32) -> i32: return value" });
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

test "generateHeader: includes the headers of the modules whose structs a tuple contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    ends: (points::Point, colors::Color)" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "points.mn", .data = "struct Point:\n    x: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "colors.mn", .data = "struct Color:\n    red: u8" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n#include \"points.h\"\n#include \"colors.h\"\n\n#ifndef mn_tuple_2_points_Point_colors_Color_defined\n#define mn_tuple_2_points_Point_colors_Color_defined\ntypedef struct mn_tuple_2_points_Point_colors_Color {\n    mn_points_Point _0;\n    mn_colors_Color _1;\n} mn_tuple_2_points_Point_colors_Color;\n#endif\n\ntypedef struct mn_shapes_Line {\n    mn_tuple_2_points_Point_colors_Color ends;\n} mn_shapes_Line;\n",
        files[2].contents,
    );
}

test "generatePrototypeTags: declares the tags that function types in fields use" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node:\n    visit: fn(Other, *Other) -> (i32, bool)\nstruct Other:\n    x: i32\nfn show(node: Node): _ = node" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Other mn_main_Other;\ntypedef struct mn_tuple_2_i32_bool mn_tuple_2_i32_bool;\n\ntypedef struct mn_main_Other {\n    int32_t x;\n} mn_main_Other;\n\ntypedef struct mn_main_Node {\n    typeof(struct mn_tuple_2_i32_bool (*)(struct mn_main_Other, struct mn_main_Other *)) visit;\n} mn_main_Node;\n\nvoid mn_main_show(mn_main_Node);\n",
        files[0].contents,
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

test "collectForwardType: declares the struct of another module that a pointer points to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(line: *shapes::Line): _ = line" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_shapes_Line mn_shapes_Line;\n\nvoid mn_main_show(struct mn_shapes_Line *);\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\nconst cards: [2]Card = {\n    {question = \"a\"},\n    {question = \"b\"},\n}\nfn all() -> [2]Card: return cards" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\ntypedef struct mn_main_Card {\n    mn_slice_u8 question;\n} mn_main_Card;\n\ntypedef struct mn_array_2_main_Card mn_array_2_main_Card;\n\nextern const mn_array_2_main_Card mn_main_cards;\n\nmn_array_2_main_Card mn_main_all();\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\nstruct Deck:\n    cards: [2]Card\nfn show(deck: Deck): _ = deck" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\ntypedef struct mn_main_Card {\n    mn_slice_u8 question;\n} mn_main_Card;\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\ntypedef struct mn_main_Deck {\n    mn_array_2_main_Card cards;\n} mn_main_Deck;\n\nvoid mn_main_show(mn_main_Deck);\n",
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

test "generateOptionalDefinition: holds the value and a presence flag" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?i32: return null\nfn nested() -> ??i32: return null" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\n#ifndef mn_optional_optional_i32_defined\n#define mn_optional_optional_i32_defined\ntypedef struct mn_optional_optional_i32 {\n    mn_optional_i32 value;\n    bool present;\n} mn_optional_optional_i32;\n#endif\n\nmn_optional_i32 mn_main_nothing() {\n    return (mn_optional_i32){ .present = false };\n}\n\nmn_optional_optional_i32 mn_main_nested() {\n    return (mn_optional_optional_i32){ .present = false };\n}\n",
        files[1].contents,
    );
}

test "generateOptionalDefinition: leaves out the value of a zero-sized type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn nothing() -> ?Marker: return null" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_main_Marker_defined\n#define mn_optional_main_Marker_defined\ntypedef struct mn_optional_main_Marker {\n    bool present;\n} mn_optional_main_Marker;\n#endif\n\nmn_optional_main_Marker mn_main_nothing() {\n    return (mn_optional_main_Marker){ .present = false };\n}\n",
        files[1].contents,
    );
}

test "generateTupleDefinition: names the elements by their position" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> (i32, (bool, u8)): return {1, {true, 2}}" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_bool_u8_defined\n#define mn_tuple_2_bool_u8_defined\ntypedef struct mn_tuple_2_bool_u8 {\n    bool _0;\n    uint8_t _1;\n} mn_tuple_2_bool_u8;\n#endif\n\n#ifndef mn_tuple_2_i32_tuple_2_bool_u8_defined\n#define mn_tuple_2_i32_tuple_2_bool_u8_defined\ntypedef struct mn_tuple_2_i32_tuple_2_bool_u8 {\n    int32_t _0;\n    mn_tuple_2_bool_u8 _1;\n} mn_tuple_2_i32_tuple_2_bool_u8;\n#endif\n\nmn_tuple_2_i32_tuple_2_bool_u8 mn_main_make() {\n    return (mn_tuple_2_i32_tuple_2_bool_u8){ ._0 = 1, ._1 = (mn_tuple_2_bool_u8){ ._0 = true, ._1 = 2u } };\n}\n",
        files[1].contents,
    );
}

test "generateTupleDefinition: leaves out elements of zero-sized types" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make() -> (Marker, i32): return {Marker{}, 2}" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_main_Marker_i32_defined\n#define mn_tuple_2_main_Marker_i32_defined\ntypedef struct mn_tuple_2_main_Marker_i32 {\n    int32_t _1;\n} mn_tuple_2_main_Marker_i32;\n#endif\n\nmn_tuple_2_main_Marker_i32 mn_main_make() {\n    return (mn_tuple_2_main_Marker_i32){ ._1 = 2 };\n}\n",
        files[1].contents,
    );
}

test "generateArrayEquality: compares nested arrays element by element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: [2][3]i32, right: [2][3]i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\n#ifndef mn_array_2_array_3_i32_defined\n#define mn_array_2_array_3_i32_defined\ntypedef struct mn_array_2_array_3_i32 {\n    mn_array_3_i32 items[2];\n} mn_array_2_array_3_i32;\n#endif\n\n#ifndef mn_array_3_i32_equal_defined\n#define mn_array_3_i32_equal_defined\nstatic inline bool mn_array_3_i32_equal(mn_array_3_i32 one, mn_array_3_i32 two) {\n    for (size_t index = 0; index < 3; index += 1) {\n        if (one.items[index] != two.items[index]) return false;\n    }\n    return true;\n}\n#endif\n\n#ifndef mn_array_2_array_3_i32_equal_defined\n#define mn_array_2_array_3_i32_equal_defined\nstatic inline bool mn_array_2_array_3_i32_equal(mn_array_2_array_3_i32 one, mn_array_2_array_3_i32 two) {\n    for (size_t index = 0; index < 2; index += 1) {\n        if (!mn_array_3_i32_equal(one.items[index], two.items[index])) return false;\n    }\n    return true;\n}\n#endif\n\nbool mn_main_same(mn_array_2_array_3_i32 left, mn_array_2_array_3_i32 right) {\n    return mn_array_2_array_3_i32_equal(left, right);\n}\n",
        files[1].contents,
    );
}

test "generateArrayEquality: compares optional elements with the equality of the optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: [2]?i32, right: [2]?i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\n#ifndef mn_array_2_optional_i32_defined\n#define mn_array_2_optional_i32_defined\ntypedef struct mn_array_2_optional_i32 {\n    mn_optional_i32 items[2];\n} mn_array_2_optional_i32;\n#endif\n\n#ifndef mn_optional_i32_equal_defined\n#define mn_optional_i32_equal_defined\nstatic inline bool mn_optional_i32_equal(mn_optional_i32 one, mn_optional_i32 two) {\n    if (one.present != two.present) return false;\n    if (!one.present) return true;\n    return one.value == two.value;\n}\n#endif\n\n#ifndef mn_array_2_optional_i32_equal_defined\n#define mn_array_2_optional_i32_equal_defined\nstatic inline bool mn_array_2_optional_i32_equal(mn_array_2_optional_i32 one, mn_array_2_optional_i32 two) {\n    for (size_t index = 0; index < 2; index += 1) {\n        if (!mn_optional_i32_equal(one.items[index], two.items[index])) return false;\n    }\n    return true;\n}\n#endif\n\nbool mn_main_same(mn_array_2_optional_i32 left, mn_array_2_optional_i32 right) {\n    return mn_array_2_optional_i32_equal(left, right);\n}\n",
        files[1].contents,
    );
}

test "generateOptionalEquality: compares the flags and then the values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?i32, right: ?i32) -> bool: return left != right" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\n#ifndef mn_optional_i32_equal_defined\n#define mn_optional_i32_equal_defined\nstatic inline bool mn_optional_i32_equal(mn_optional_i32 one, mn_optional_i32 two) {\n    if (one.present != two.present) return false;\n    if (!one.present) return true;\n    return one.value == two.value;\n}\n#endif\n\nbool mn_main_same(mn_optional_i32 left, mn_optional_i32 right) {\n    return (!mn_optional_i32_equal(left, right));\n}\n",
        files[1].contents,
    );
}

test "generateOptionalEquality: compares only the flags of zero-sized values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?[0]i32, right: ?[0]i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_array_0_i32_defined\n#define mn_optional_array_0_i32_defined\ntypedef struct mn_optional_array_0_i32 {\n    bool present;\n} mn_optional_array_0_i32;\n#endif\n\n#ifndef mn_optional_array_0_i32_equal_defined\n#define mn_optional_array_0_i32_equal_defined\nstatic inline bool mn_optional_array_0_i32_equal(mn_optional_array_0_i32 one, mn_optional_array_0_i32 two) {\n    return one.present == two.present;\n}\n#endif\n\nbool mn_main_same(mn_optional_array_0_i32 left, mn_optional_array_0_i32 right) {\n    return mn_optional_array_0_i32_equal(left, right);\n}\n",
        files[1].contents,
    );
}

test "generateOptionalEquality: compares nested optionals with the equality of the inner optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ??i32, right: ??i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\n#ifndef mn_optional_optional_i32_defined\n#define mn_optional_optional_i32_defined\ntypedef struct mn_optional_optional_i32 {\n    mn_optional_i32 value;\n    bool present;\n} mn_optional_optional_i32;\n#endif\n\n#ifndef mn_optional_i32_equal_defined\n#define mn_optional_i32_equal_defined\nstatic inline bool mn_optional_i32_equal(mn_optional_i32 one, mn_optional_i32 two) {\n    if (one.present != two.present) return false;\n    if (!one.present) return true;\n    return one.value == two.value;\n}\n#endif\n\n#ifndef mn_optional_optional_i32_equal_defined\n#define mn_optional_optional_i32_equal_defined\nstatic inline bool mn_optional_optional_i32_equal(mn_optional_optional_i32 one, mn_optional_optional_i32 two) {\n    if (one.present != two.present) return false;\n    if (!one.present) return true;\n    return mn_optional_i32_equal(one.value, two.value);\n}\n#endif\n\nbool mn_main_same(mn_optional_optional_i32 left, mn_optional_optional_i32 right) {\n    return mn_optional_optional_i32_equal(left, right);\n}\n",
        files[1].contents,
    );
}

test "generateOptionalEquality: compares arrays inside optionals with the equality of the array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?[2]i32, right: ?[2]i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\n#ifndef mn_optional_array_2_i32_defined\n#define mn_optional_array_2_i32_defined\ntypedef struct mn_optional_array_2_i32 {\n    mn_array_2_i32 value;\n    bool present;\n} mn_optional_array_2_i32;\n#endif\n\n#ifndef mn_array_2_i32_equal_defined\n#define mn_array_2_i32_equal_defined\nstatic inline bool mn_array_2_i32_equal(mn_array_2_i32 one, mn_array_2_i32 two) {\n    for (size_t index = 0; index < 2; index += 1) {\n        if (one.items[index] != two.items[index]) return false;\n    }\n    return true;\n}\n#endif\n\n#ifndef mn_optional_array_2_i32_equal_defined\n#define mn_optional_array_2_i32_equal_defined\nstatic inline bool mn_optional_array_2_i32_equal(mn_optional_array_2_i32 one, mn_optional_array_2_i32 two) {\n    if (one.present != two.present) return false;\n    if (!one.present) return true;\n    return mn_array_2_i32_equal(one.value, two.value);\n}\n#endif\n\nbool mn_main_same(mn_optional_array_2_i32 left, mn_optional_array_2_i32 right) {\n    return mn_optional_array_2_i32_equal(left, right);\n}\n",
        files[1].contents,
    );
}

test "generateZeroSizedObject: defines the shared zero-sized object only in the file of the entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "other.mn", .data = "struct Marker\nfn locate(marker: Marker) -> *const Marker: return &marker" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = other::locate(other::Marker{})" });
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
        "#include \"main.h\"\n#include \"other.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_other_locate();\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"other.h\"\n\nvoid const * mn_other_locate() {\n    return ((void const *)&mn_zero_sized);\n}\n",
        files[3].contents,
    );
}

test "generateConstantDefinition: declares a constant whose length is taken from another constant with the complete array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [3]i32 = {1, 2, 3}\nconst second: [_]i32 = first\nfn all() -> [3]i32: return second" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_array_3_i32 mn_array_3_i32;\n\nextern const mn_array_3_i32 mn_main_first;\nextern const mn_array_3_i32 mn_main_second;\n\nmn_array_3_i32 mn_main_all();\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nconst mn_array_3_i32 mn_main_first = { .items = { 1, 2, 3 } };\nconst mn_array_3_i32 mn_main_second = { .items = { 1, 2, 3 } };\n\nmn_array_3_i32 mn_main_all() {\n    return mn_main_second;\n}\n",
        files[1].contents,
    );
}

test "recordCalledFunction: includes the header of a function called in a loop" {
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
        "#include \"main.h\"\n#include \"shapes.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    while (false) {\n        mn_shapes_draw();\n    }\n}\n",
        files[1].contents,
    );
}

test "recordCalledFunction: records a function called through a local alias" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): noop\nfn main():\n    const run = show\n    run()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_show() {}\n\nint main() {\n    mn_main_show();\n}\n",
        files[1].contents,
    );
}

test "recordCalledFunction: records the runtime functions that a field access calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/clock.mn", .data = "struct Time:\n    seconds: i64\nexternal fn mn_runtime_clock_now() -> Time\nconst now = mn_runtime_clock_now" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn seconds() -> i64: return std::clock::now().seconds" });
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

test "recordCalledFunction: includes the headers of the functions that operands call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "numbers.mn", .data = "fn one() -> i32: return 1" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn two() -> i32: return -numbers::one() + 1" });
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
        "#include \"main.h\"\n#include \"numbers.h\"\n\nint32_t mn_main_two() {\n    return ((-mn_numbers_one()) + 1);\n}\n",
        files[1].contents,
    );
}

test "recordType: includes the headers of the structs that defaults build" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Options:\n    size: geometry::Size = geometry::Size{width = 1}\nfn draw(options: Options): _ = options" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): shapes::draw(shapes::Options{})" });
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
        "#include \"main.h\"\n#include \"shapes.h\"\n#include \"geometry.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_shapes_draw((mn_shapes_Options){ .size = (mn_geometry_Size){ .width = 1 } });\n}\n",
        files[1].contents,
    );
}

test "recordType: defines a slice type and an array type used only by a conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn read(bytes: []u8) -> usize\nfn count(buffer: *[4]u8) -> usize: return read(buffer)" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nsize_t mn_main_count(struct mn_array_4_u8 * buffer) {\n    return read((mn_slice_u8){ .items = buffer->items, .length = 4 });\n}\n",
        files[1].contents,
    );
}

test "recordType: defines the array inside an optional before the optional" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?[2]i32: return null" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\n#ifndef mn_optional_array_2_i32_defined\n#define mn_optional_array_2_i32_defined\ntypedef struct mn_optional_array_2_i32 {\n    mn_array_2_i32 value;\n    bool present;\n} mn_optional_array_2_i32;\n#endif\n\nmn_optional_array_2_i32 mn_main_nothing() {\n    return (mn_optional_array_2_i32){ .present = false };\n}\n",
        files[1].contents,
    );
}

test "recordPointerTarget: includes the header of a struct that an assignment target writes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn widen(line: *shapes::Line): line.width = 2" });
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
        "#include \"main.h\"\n#include \"shapes.h\"\n\nvoid mn_main_widen(struct mn_shapes_Line * line) {\n    line->width = 2;\n}\n",
        files[1].contents,
    );
}

test "recordPointerTarget: includes the header of a struct that a usize moves a pointer to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn advance(lines: *many shapes::Line, count: usize) -> *many shapes::Line: return count + lines" });
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
        "#include \"main.h\"\n#include \"shapes.h\"\n\nstruct mn_shapes_Line * mn_main_advance(struct mn_shapes_Line * lines, size_t count) {\n    return (count + lines);\n}\n",
        files[1].contents,
    );
}

test "recordPointerTarget: includes the header of a struct read through a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Line:\n    width: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn width(line: *const shapes::Line) -> i32: return line.width" });
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
        "#include \"main.h\"\n#include \"shapes.h\"\n\nint32_t mn_main_width(struct mn_shapes_Line const * line) {\n    return line->width;\n}\n",
        files[1].contents,
    );
}

test "recordPointerTarget: defines the array behind an indexed pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: *const [3]i32) -> i32: return values[1]" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nint32_t mn_main_read(struct mn_array_3_i32 const * values) {\n    return values->items[1u];\n}\n",
        files[1].contents,
    );
}

test "recordPointerTarget: defines no slice for a pointer to an array that is not converted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(buffer: *[4]u8) -> u8: return buffer[0]" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nuint8_t mn_main_first(struct mn_array_4_u8 * buffer) {\n    return buffer->items[0u];\n}\n",
        files[1].contents,
    );
}

test "recordModule: includes the header of a stored array that an inlined slice constant uses" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "data.mn", .data = "const values = [2]i32{1, 2}\nconst items = values[..]" });
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
        "#include \"main.h\"\n#include \"data.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(mn_slice_i32) {}\n\nint main() {\n    mn_main_take((mn_slice_i32){ .items = (int32_t *)mn_data_values.items, .length = 2 });\n}\n",
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
    try std.testing.expectEqualStrings("#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {}\n", files[1].contents);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn print_(text: []const u8)\nfn main(): print_(\"hi\")" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nvoid print_(mn_slice_u8 text);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    print_((mn_slice_u8){ .items = (uint8_t *)\"hi\", .length = 2 });\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(left: i32, right: i32) -> i32:\n    _ = right\n    return left" });
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

test "generateParameters: leaves out the names of parameters written as an underscore" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(left: i32, _: i32) -> i32: return left" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {}\n",
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    return 0;\n}\n",
        files[1].contents,
    );
}

test "generateStatement: returns a pointer to an array as a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn all(buffer: *[4]u8) -> []u8: return buffer" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nmn_slice_u8 mn_main_all(struct mn_array_4_u8 * buffer) {\n    return (mn_slice_u8){ .items = buffer->items, .length = 4 };\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(value: i32): _ = value\nfn one() -> i32: return 1\nfn main():\n    log(one())\n    _ = one()\n" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_log(int32_t) {}\n\nint32_t mn_main_one() {\n    return 1;\n}\n\nint main() {\n    mn_main_log(mn_main_one());\n    mn_main_one();\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make(marker: Marker) -> Marker: return marker\nfn pass(marker: Marker) -> Marker: return make(marker)" });
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

test "hasTarget: assigns through slices and pointers whose root is not a local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn update(values: []i32, target: *i32, point: *Point):\n    values[0] = 1\n    target.* = 2\n    point.x = 3" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nvoid mn_main_update(mn_slice_i32 values, int32_t * target, struct mn_main_Point * point) {\n    values.items[0u] = 1;\n    (*target) = 2;\n    point->x = 3;\n}\n",
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_take(int32_t) {}\n\nint main() {\n    const int32_t limit = 5;\n    mn_main_take(limit);\n}\n",
        files[1].contents,
    );
}

test "generateLocal: makes a local pointer constant instead of its target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: *i32): _ = value\nfn give(value: *i32):\n    const alias = value\n    take(alias)" });
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
        "#include \"main.h\"\n\nvoid mn_main_take(int32_t *) {}\n\nvoid mn_main_give(int32_t * value) {\n    int32_t * const alias = value;\n    mn_main_take(alias);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    const value = value\n    const value = value\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    const value = value\n    const value_2 = value\n    return value_2" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return 1\nfn main():\n    const value = make()\n    _ = value" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_make() {\n    return 1;\n}\n\nint main() {\n    mn_main_make();\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make() -> Marker: return Marker{}\nfn use(marker: Marker): _ = marker\nfn main():\n    const marker = make()\n    use(marker)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_use() {}\n\nint main() {\n    mn_main_make();\n    mn_main_use();\n}\n",
        files[1].contents,
    );
}

test "generateLocal: writes only the calls of void constants and variables" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn work(): noop\nfn keep(value: void, number: i32) -> i32:\n    _ = value\n    return number\nstruct Box:\n    nothing: void\n    number: i32\nfn main():\n    const result = work()\n    var other: void = undefined\n    other = work()\n    _ = keep(result, 1)\n    _ = keep(other, 2)\n    const box = Box{nothing = result, number = 3}\n    _ = keep(box.nothing, box.number)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_work() {}\n\nint32_t mn_main_keep(int32_t number) {\n    return number;\n}\n\nint main() {\n    mn_main_work();\n    mn_main_work();\n    mn_main_keep(1);\n    mn_main_keep(2);\n    const mn_main_Box box = (mn_main_Box){ .number = 3 };\n    mn_main_keep(box.number);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() -> [2]i32:\n    const Pair = [2]i32\n    const values: Pair = {1, 2}\n    return values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count = 1i32\n    count = 2i32\n    return count" });
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

test "generateLocal: declares a local with its written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn keep(value: *const i32)\nfn main():\n    var one = 1i32\n    var two = 2i32\n    var pointer: *const i32 = &one\n    pointer = &two\n    keep(pointer)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t one = 1;\n    int32_t two = 2;\n    int32_t const * pointer = &one;\n    pointer = &two;\n    keep(pointer);\n}\n",
        files[1].contents,
    );
}

test "generateLocal: initializes a slice from a pointer to an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(buffer: *[4]u8) -> u8:\n    const bytes: []u8 = buffer\n    return bytes[0]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nuint8_t mn_main_first(struct mn_array_4_u8 * buffer) {\n    const mn_slice_u8 bytes = (mn_slice_u8){ .items = buffer->items, .length = 4 };\n    return bytes.items[0u];\n}\n",
        files[1].contents,
    );
}

test "generateLocal: declares a local whose length is taken from a call with the complete array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> [4]u8\nfn first() -> u8:\n    const values: [_]u8 = make()\n    return values[0]" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nuint8_t mn_main_first() {\n    const mn_array_4_u8 values = make();\n    return values.items[0u];\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count: i32 = undefined\n    count = 5\n    return count" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const value = 1i32\n    var value = value\n    value = 2i32\n    return value" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_take(int32_t) {}\n\nint main() {\n    const int32_t value = 1;\n    while (false) {\n        const int32_t value_2 = 2;\n        mn_main_take(value_2);\n    }\n    mn_main_take(value);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn show() -> Point:\n    var point = Point{x = 1, y = 2}\n    point.x = 3\n    return point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return 1\nfn main():\n    var value = 1i32\n    value = make()\n    _ = value" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_make() {\n    return 1;\n}\n\nint main() {\n    mn_main_make();\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn show() -> Line:\n    var line = Line{start = Point{x = 1}}\n    line.start.x = 2\n    return line" });
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

test "generateAssignment: assigns an element of a variable array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32:\n    var values = [2]i32{1, 2}\n    values[1] = 3\n    return values" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nmn_array_2_i32 mn_main_make() {\n    mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    values.items[1u] = 3;\n    return values;\n}\n",
        files[1].contents,
    );
}

test "generateAssignment: assigns a field through a pointer returned by a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn locate() -> *Point\nfn main(): locate().x = 1" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    locate()->x = 1;\n}\n",
        files[1].contents,
    );
}

test "generateAssignment: assigns a read-only pointer to an array as a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(buffer: *const [4]u8) -> u8:\n    var bytes: []const u8 = \"ab\"\n    bytes = buffer\n    return bytes[0]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nuint8_t mn_main_first(struct mn_array_4_u8 const * buffer) {\n    mn_slice_u8 bytes = (mn_slice_u8){ .items = (uint8_t *)\"ab\", .length = 2 };\n    bytes = (mn_slice_u8){ .items = (uint8_t *)buffer->items, .length = 4 };\n    return bytes.items[0u];\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: writes a name as the target and as the left operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update(amount: i32) -> i32:\n    var total = 1i32\n    total += amount\n    total %= 3\n    total <<= 2\n    return total" });
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
        "#include \"main.h\"\n\nint32_t mn_main_update(int32_t amount) {\n    int32_t total = 1;\n    total = (total + amount);\n    total = mn_remainder_i32(total, 3);\n    total = mn_shift_left_i32(total, 2u);\n    return total;\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: casts the result of a type narrower than int back to its type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update() -> u8:\n    var small = 1u8\n    small += 2\n    return small" });
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
        "#include \"main.h\"\n\nuint8_t mn_main_update() {\n    uint8_t small = 1u;\n    small = ((uint8_t)(small + 2u));\n    return small;\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: evaluates a target with a call once and before the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn next() -> usize\nexternal fn make() -> i32\nfn update(values: *many i32): values[next()] += make()" });
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
        "#include \"main.h\"\n\nvoid mn_main_update(int32_t * values) {\n    int32_t * mn_temporary_1;\n    int32_t mn_temporary_2;\n    mn_temporary_1 = &values[next()], mn_temporary_2 = (*mn_temporary_1), (*mn_temporary_1) = (mn_temporary_2 + make());\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: reads a variable target before a call in the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nfn total() -> i32:\n    var count = 1i32\n    count += make()\n    return count" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total() {\n    int32_t count = 1;\n    int32_t mn_temporary_1;\n    mn_temporary_1 = count, count = (mn_temporary_1 + make());\n    return count;\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: writes a field through a pointer temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn update() -> Point:\n    var point = Point{x = 1}\n    point.x *= 2\n    return point" });
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
        "#include \"main.h\"\n\nmn_main_Point mn_main_update() {\n    mn_main_Point point = (mn_main_Point){ .x = 1 };\n    int32_t * mn_temporary_1;\n    mn_temporary_1 = &point.x, (*mn_temporary_1) = ((*mn_temporary_1) * 2);\n    return point;\n}\n",
        files[1].contents,
    );
}

test "generateCompoundAssignment: moves a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn advance(items: *many i32) -> *many i32:\n    var cursor = items\n    cursor += 2\n    cursor -= 1\n    return cursor" });
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
        "#include \"main.h\"\n\nint32_t * mn_main_advance(int32_t * items) {\n    int32_t * cursor = items;\n    cursor = (cursor + 2u);\n    cursor = (cursor - 1u);\n    return cursor;\n}\n",
        files[1].contents,
    );
}

test "generateTargetEffects: runs the calls of a zero-sized target before the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Data:\n    marker: Marker\n    value: i32\nexternal fn locate() -> *Data\nexternal fn make() -> Marker\nfn main(): locate().marker = make()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    locate(), make();\n}\n",
        files[1].contents,
    );
}

test "generateTargetEffects: runs the calls of a zero-sized target from left to right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn locate() -> *many [2]Marker\nexternal fn position() -> usize\nexternal fn make() -> Marker\nfn main(): locate()[position()][position()] = make()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    locate(), position(), position(), make();\n}\n",
        files[1].contents,
    );
}

test "generateTarget: evaluates the calls of the target before the calls of the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn locate() -> *Point\nexternal fn make() -> i32\nfn main(): locate().x = make()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    struct mn_main_Point * mn_temporary_1;\n    mn_temporary_1 = locate(), mn_temporary_1->x = make();\n}\n",
        files[1].contents,
    );
}

test "generateTarget: evaluates the calls in a target from left to right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn locate() -> *many i32\nexternal fn position() -> usize\nfn main(): locate()[position()] = 1" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t * mn_temporary_1;\n    size_t mn_temporary_2;\n    mn_temporary_1 = locate(), mn_temporary_2 = position(), mn_temporary_1[mn_temporary_2] = 1;\n}\n",
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_step() {}\n\nint main() {\n    bool running = true;\n    while (running) {\n        mn_main_step();\n        running = false;\n    }\n}\n",
        files[1].contents,
    );
}

test "generateWhile: evaluates the temporaries of the condition in each iteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nexternal fn step()\nfn main(): while one() < two(): step()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    while ((mn_temporary_1 = one(), mn_temporary_2 = two(), (mn_temporary_1 < mn_temporary_2))) {\n        step();\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: stores calls in temporaries to evaluate them from left to right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nfn sum() -> i32: return one() + two()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = one(), mn_temporary_2 = two(), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: evaluates the arguments of a call before the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nexternal fn add(left: i32, right: i32) -> i32\nfn sum() -> i32: return add(one(), add(two(), 1))" });
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    int32_t mn_temporary_3;\n    return (mn_temporary_1 = one(), mn_temporary_2 = two(), mn_temporary_3 = add(mn_temporary_2, 1), add(mn_temporary_1, mn_temporary_3));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: leaves calls that contain each other in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn add(left: i32, right: i32) -> i32\nfn sum() -> i32: return add(one(), 1) + 1" });
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    return (add(one(), 1) + 1);\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: evaluates the bounds of a slice from left to right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn first() -> usize\nexternal fn last() -> usize\nfn part(values: []i32) -> []i32: return values[first()..last()]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part(mn_slice_i32 values) {\n    size_t mn_temporary_1;\n    size_t mn_temporary_2;\n    return (mn_temporary_1 = first(), mn_temporary_2 = last(), (mn_slice_i32){ .items = values.items + mn_temporary_1, .length = mn_temporary_2 - mn_temporary_1 });\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: stores calls in indexes in temporaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn first() -> usize\nexternal fn second() -> usize\nfn sum(values: []const i32) -> i32: return values[first()] + values[second()]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nint32_t mn_main_sum(mn_slice_i32 values) {\n    size_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    size_t mn_temporary_3;\n    return (mn_temporary_1 = first(), mn_temporary_2 = values.items[mn_temporary_1], mn_temporary_3 = second(), (mn_temporary_2 + values.items[mn_temporary_3]));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads a variable before a later call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nfn total() -> i32:\n    var count = 1i32\n    count = 2\n    return count + make()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total() {\n    int32_t count = 1;\n    count = 2;\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = count, mn_temporary_2 = make(), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads a field of a variable before a later call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn make() -> i32\nfn total() -> i32:\n    var point = Point{x = 1}\n    point.x = 2\n    return point.x + make()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total() {\n    mn_main_Point point = (mn_main_Point){ .x = 1 };\n    point.x = 2;\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = point.x, mn_temporary_2 = make(), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads through a pointer before a later call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nfn total(pointer: *i32) -> i32: return pointer.* + make()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total(int32_t * pointer) {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = (*pointer), mn_temporary_2 = make(), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads an argument before a later argument with a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nexternal fn add(one: i32, two: i32) -> i32\nfn total() -> i32:\n    var count = 1i32\n    count = 2\n    return add(count, make())" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total() {\n    int32_t count = 1;\n    count = 2;\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = count, mn_temporary_2 = make(), add(mn_temporary_1, mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads an element before a later element with a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nfn all() -> [2]i32:\n    var count = 1i32\n    count = 2\n    return [2]i32{count, make()}" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nmn_array_2_i32 mn_main_all() {\n    int32_t count = 1;\n    count = 2;\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = count, mn_temporary_2 = make(), (mn_array_2_i32){ .items = { mn_temporary_1, mn_temporary_2 } });\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: reads a field value before a later field value with a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nexternal fn make() -> i32\nfn build() -> Point:\n    var count = 1i32\n    count = 2\n    return Point{x = count, y = make()}" });
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
        "#include \"main.h\"\n\nmn_main_Point mn_main_build() {\n    int32_t count = 1;\n    count = 2;\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = count, mn_temporary_2 = make(), (mn_main_Point){ .x = mn_temporary_1, .y = mn_temporary_2 });\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: stores calls in field values in temporaries in written order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    one: i32\n    two: i32\nexternal fn one() -> i32\nexternal fn two() -> i32\nfn make() -> Data: return {two = two(), one = one()}" });
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
        "#include \"main.h\"\n\nmn_main_Data mn_main_make() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = two(), mn_temporary_2 = one(), (mn_main_Data){ .two = mn_temporary_1, .one = mn_temporary_2 });\n}\n",
        files[1].contents,
    );
}

test "generateFullExpression: leaves a parameter and a constant before a later call in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nconst limit = 5i32\nfn total(value: i32) -> i32: return value + limit + make()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_total(int32_t value) {\n    return ((value + 5) + make());\n}\n",
        files[1].contents,
    );
}

test "generateStatementEffects: runs the calls of a discarded operation from left to right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nfn main():\n    const sum: i32 = one() + two()\n    _ = sum" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    (void)(mn_temporary_1 = one(), mn_temporary_2 = two(), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateStatementEffects: runs the calls of a zero-sized value without storing an unused result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nexternal fn one() -> i32\nexternal fn make(left: i32, right: i32) -> Holder\nfn get() -> Marker: return make(one(), one()).marker" });
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
        "#include \"main.h\"\n\nvoid mn_main_get() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    mn_temporary_1 = one(), mn_temporary_2 = one(), make(mn_temporary_1, mn_temporary_2);\n    return;\n}\n",
        files[1].contents,
    );
}

test "generateSteps: runs a zero-sized call in its place without a temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn one() -> i32\nexternal fn mark(value: i32) -> Marker\nexternal fn use(marker: Marker, value: i32)\nfn main(): use(mark(one()), one())" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    (mn_temporary_1 = one(), mark(mn_temporary_1), mn_temporary_2 = one(), use(mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateOperand: replaces a call in a field access by its temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn make() -> Point\nfn sum() -> i32: return make().x + make().x" });
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    mn_main_Point mn_temporary_1;\n    mn_main_Point mn_temporary_2;\n    return (mn_temporary_1 = make(), mn_temporary_2 = make(), (mn_temporary_1.x + mn_temporary_2.x));\n}\n",
        files[1].contents,
    );
}

test "generateBase: puts an address used as a base in parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: Point) -> i32: return (&point).x" });
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
        "#include \"main.h\"\n\nint32_t mn_main_read(mn_main_Point point) {\n    return (&point)->x;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mode() -> u16: return 0o7_5_5\nfn big() -> u32: return 1_000" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() -> u8: return 0xff\nfn big() -> u64: return 18446744073709551615" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn big() -> i64: return 9223372036854775807" });
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

test "generateExpression: marks f16 and f128 literals" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn half() -> f16: return 0.5\nfn tenth() -> f128: return 0.1" });
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
        "#include \"main.h\"\n\n_Float16 mn_main_half() {\n    return 0.5f16;\n}\n\n_Float128 mn_main_tenth() {\n    return 0.1f128;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: adds a decimal point to a float written without one" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn half() -> f16: return 5f16\nfn whole() -> f64: return -1_000f64\nfn single() -> f32: return 5f32\nfn quadruple() -> f128: return 5f128\nfn large() -> f32: return 1e3f32\nfn negative() -> f32: return -1_000f32" });
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
        "#include \"main.h\"\n\n_Float16 mn_main_half() {\n    return 5.0f16;\n}\n\ndouble mn_main_whole() {\n    return -1'000.0;\n}\n\nfloat mn_main_single() {\n    return 5.0f;\n}\n\n_Float128 mn_main_quadruple() {\n    return 5.0f128;\n}\n\nfloat mn_main_large() {\n    return 1e3f;\n}\n\nfloat mn_main_negative() {\n    return -1'000.0f;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a negative float" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn half() -> f16: return -0.5" });
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
        "#include \"main.h\"\n\n_Float16 mn_main_half() {\n    return -0.5f16;\n}\n",
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_small(uint8_t) {}\n\nint main() {\n    mn_main_small(255u);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() -> []const u8: return \"line\\n\\\"quoted\\\"\"" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nmn_slice_u8 mn_main_greeting() {\n    return (mn_slice_u8){ .items = (uint8_t *)\"line\\n\\\"quoted\\\"\", .length = 13 };\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a character literal as an integer of the expected type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn letter() -> u8: return 'a'" });
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
        "#include \"main.h\"\n\nuint8_t mn_main_letter() {\n    return 97u;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask() -> u8: return limit\nconst limit = 0xff_u8" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make(marker: Marker) -> Marker: return marker\nfn use(marker: Marker, value: i32):\n    _ = marker\n    _ = value\nfn run(marker: Marker): use(make(marker), 1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nexternal fn make() -> Line\nfn read(line: Line) -> i32: return line.start.x\nfn first() -> i32: return make().start.x" });
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

test "generateExpression: takes the address of a variable, an element and a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn keep(value: *i32)\nfn main():\n    var value = 1i32\n    var values = [2]i32{1, 2}\n    var point = Point{x = 1}\n    var pair = (i32, bool){1, true}\n    keep(&value)\n    keep(&values[1])\n    keep(&point.x)\n    keep(&pair[0])" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t value = 1;\n    mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    mn_main_Point point = (mn_main_Point){ .x = 1 };\n    mn_tuple_2_i32_bool pair = (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true };\n    keep(&value);\n    keep(&values.items[1u]);\n    keep(&point.x);\n    keep(&pair._0);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: takes the address of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn keep(value: *const [2]i32)\nfn show(values: [2]i32): keep(&values)" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nvoid mn_main_show(mn_array_2_i32 values) {\n    keep(&values);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: dereferences a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: *const i32) -> i32: return value.*" });
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
        "#include \"main.h\"\n\nint32_t mn_main_read(int32_t const * value) {\n    return (*value);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: takes the address of the target of a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn keep(value: *const i32)\nfn show(value: *const i32): keep(&value.*)" });
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
        "#include \"main.h\"\n\nvoid mn_main_show(int32_t const * value) {\n    keep(&(*value));\n}\n",
        files[1].contents,
    );
}

test "generateExpression: accesses a field through a pointer and after a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: *const Point) -> i32: return point.x + point.*.x" });
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
        "#include \"main.h\"\n\nint32_t mn_main_read(struct mn_main_Point const * point) {\n    return (point->x + (*point).x);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes through a local constant pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    const pointer = &value\n    pointer.* = 2" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t value = 1;\n    int32_t * const pointer = &value;\n    (*pointer) = 2;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32 = 0\nfn draw(point: Point) -> i32: return point.x\nfn main(): _ = draw({x = 1})" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_draw(mn_main_Point point) {\n    return point.x;\n}\n\nint main() {\n    mn_main_draw((mn_main_Point){ .x = 1, .y = 0 });\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point = {x = 0}\nfn make() -> Line: return Line{}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point:\n    var point = Point{x = 1}\n    point = {x = 2}\n    return point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nfn mark() -> Marker: return Marker{}\nfn make() -> Holder: return {marker = mark(), value = 1}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn use(marker: Marker): _ = marker\nfn main(): use({})" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_use() {}\n\nint main() {\n    mn_main_use();\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return {1, 2}" });
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

test "generateExpression: writes an array literal with a written type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() -> [2]i32:\n    const values = [2]i32{1, 2}\n    return values" });
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

test "generateExpression: moves zero-sized calls out of a tuple literal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): return\nfn make() -> (void, i32): return {show(), 2}" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_void_i32_defined\n#define mn_tuple_2_void_i32_defined\ntypedef struct mn_tuple_2_void_i32 {\n    int32_t _1;\n} mn_tuple_2_void_i32;\n#endif\n\nvoid mn_main_show() {\n    return;\n}\n\nmn_tuple_2_void_i32 mn_main_make() {\n    return (mn_main_show(), (mn_tuple_2_void_i32){ ._1 = 2 });\n}\n",
        files[1].contents,
    );
}

test "generateExpression: writes a tuple literal in a stored constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pairs: [1](i32, bool) = {{1, true}}\nfn all() -> [1](i32, bool): return pairs" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\n#ifndef mn_array_1_tuple_2_i32_bool_defined\n#define mn_array_1_tuple_2_i32_bool_defined\ntypedef struct mn_array_1_tuple_2_i32_bool {\n    mn_tuple_2_i32_bool items[1];\n} mn_array_1_tuple_2_i32_bool;\n#endif\n\nconst mn_array_1_tuple_2_i32_bool mn_main_pairs = { .items = { { ._0 = 1, ._1 = true } } };\n\nmn_array_1_tuple_2_i32_bool mn_main_all() {\n    return mn_main_pairs;\n}\n",
        files[1].contents,
    );
}

test "generateExpression: unwraps a pointer optional to the pointer and a struct optional to its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: ?*Point, count: ?i32) -> i32: return point.?.x + count.?" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nint32_t mn_main_read(struct mn_main_Point * point, mn_optional_i32 count) {\n    return (point->x + count.value);\n}\n",
        files[1].contents,
    );
}

test "generateExpression: runs the calls of an unwrapped zero-sized value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn find() -> ?Marker\nexternal fn keep(marker: Marker)\nfn main(): keep(find().?)" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_main_Marker_defined\n#define mn_optional_main_Marker_defined\ntypedef struct mn_optional_main_Marker {\n    bool present;\n} mn_optional_main_Marker;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    (find(), keep());\n}\n",
        files[1].contents,
    );
}

test "generateBinary: writes arithmetic, bitwise and comparison operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn compute(left: i32, right: i32) -> i32: return left + right * 2 - left / right\nfn mask(left: u64, right: u64) -> bool: return (left & right | left ^ right) != 0" });
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
        "#include \"main.h\"\n\nint32_t mn_main_compute(int32_t left, int32_t right) {\n    return ((left + (right * 2)) - (left / right));\n}\n\nbool mn_main_mask(uint64_t left, uint64_t right) {\n    return (((left & right) | (left ^ right)) != 0u);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: casts the result of operators on types narrower than int back to their type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: u8, right: u8) -> u8: return left + right\nfn less(left: i16, right: i16) -> bool: return left - 1 < right" });
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
        "#include \"main.h\"\n\nuint8_t mn_main_add(uint8_t left, uint8_t right) {\n    return ((uint8_t)(left + right));\n}\n\nbool mn_main_less(int16_t left, int16_t right) {\n    return (((int16_t)(left - 1)) < right);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: calls the runtime for shifts and remainders of signed integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn shift(value: i32, amount: usize) -> i32: return value << amount >> 1\nfn rest(left: i32, right: i32) -> i32: return left % right\nfn unsigned_rest(left: u32, right: u32) -> u32: return left % right" });
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
        "#include \"main.h\"\n\nint32_t mn_main_shift(int32_t value, size_t amount) {\n    return mn_shift_right_i32(mn_shift_left_i32(value, amount), 1u);\n}\n\nint32_t mn_main_rest(int32_t left, int32_t right) {\n    return mn_remainder_i32(left, right);\n}\n\nuint32_t mn_main_unsigned_rest(uint32_t left, uint32_t right) {\n    return (left % right);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: writes and and or with the calls of the right operand inside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn ready() -> bool\nexternal fn one() -> i32\nexternal fn two() -> i32\nfn check(first: bool) -> bool: return first or ready() and one() < two()" });
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
        "#include \"main.h\"\n\nbool mn_main_check(bool first) {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (first || (ready() && (mn_temporary_1 = one(), mn_temporary_2 = two(), (mn_temporary_1 < mn_temporary_2))));\n}\n",
        files[1].contents,
    );
}

test "generateBinary: casts the result of arithmetic on f16 back to _Float16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn scale(left: f16, right: f16) -> f16: return left * right + 1.5\nfn less(left: f16, right: f16) -> bool: return left < right" });
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
        "#include \"main.h\"\n\n_Float16 mn_main_scale(_Float16 left, _Float16 right) {\n    return ((_Float16)(((_Float16)(left * right)) + 1.5f16));\n}\n\nbool mn_main_less(_Float16 left, _Float16 right) {\n    return (left < right);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: moves a multiple value pointer by a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn before(one: *many i32, two: *many i32) -> bool: return one + 1 < two" });
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
        "#include \"main.h\"\n\nbool mn_main_before(int32_t * one, int32_t * two) {\n    return ((one + 1u) < two);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: compares optional pointers directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?*i32, right: ?*i32) -> bool: return left == right" });
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
        "#include \"main.h\"\n\nbool mn_main_same(int32_t * left, int32_t * right) {\n    return (left == right);\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: chooses between a pointer optional or a struct optional and the fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(pointer: ?*i32, fallback: *i32, count: ?i32) -> i32: return (pointer orelse fallback).* + (count orelse 0)" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nint32_t mn_main_pick(int32_t * pointer, int32_t * fallback, mn_optional_i32 count) {\n    return ((*(pointer != NULL ? pointer : fallback)) + (count.present ? count.value : 0));\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: keeps the optional when the fallback is an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(one: ?i32, two: ?i32) -> ?i32: return one orelse two" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nmn_optional_i32 mn_main_pick(mn_optional_i32 one, mn_optional_i32 two) {\n    return (one.present ? one : two);\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: converts a pointer to an array in the fallback to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?[]u8, buffer: *[4]u8) -> []u8: return maybe orelse buffer" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_optional_slice_u8_defined\n#define mn_optional_slice_u8_defined\ntypedef struct mn_optional_slice_u8 {\n    mn_slice_u8 value;\n    bool present;\n} mn_optional_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nmn_slice_u8 mn_main_pick(mn_optional_slice_u8 maybe, struct mn_array_4_u8 * buffer) {\n    return (maybe.present ? maybe.value : (mn_slice_u8){ .items = buffer->items, .length = 4 });\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: stores an optional that is not a name in a temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn find() -> ?i32\nfn pick() -> i32: return find() orelse 0" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nint32_t mn_main_pick() {\n    mn_optional_i32 mn_temporary_1;\n    return (mn_temporary_1 = find(), (mn_temporary_1.present ? mn_temporary_1.value : 0));\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: runs the calls of the fallback only without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> i32\nfn pick(count: ?i32) -> i32: return make() + (count orelse make())" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nint32_t mn_main_pick(mn_optional_i32 count) {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = make(), mn_temporary_2 = (count.present ? count.value : make()), (mn_temporary_1 + mn_temporary_2));\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: runs the calls of a zero-sized fallback only without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn make() -> Marker\nfn run(maybe: ?Marker):\n    const marker = maybe orelse make()\n    _ = marker" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_main_Marker_defined\n#define mn_optional_main_Marker_defined\ntypedef struct mn_optional_main_Marker {\n    bool present;\n} mn_optional_main_Marker;\n#endif\n\nvoid mn_main_run(mn_optional_main_Marker maybe) {\n    (void)(maybe.present ? (void)0 : (void)(make()));\n}\n",
        files[1].contents,
    );
}

test "generateOrElse: writes an untyped struct literal fallback as a compound literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make(data: ?Data) -> Data: return data orelse {value = 0}" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_main_Data_defined\n#define mn_optional_main_Data_defined\ntypedef struct mn_optional_main_Data {\n    mn_main_Data value;\n    bool present;\n} mn_optional_main_Data;\n#endif\n\nmn_main_Data mn_main_make(mn_optional_main_Data data) {\n    return (data.present ? data.value : (mn_main_Data){ .value = 0 });\n}\n",
        files[1].contents,
    );
}

test "generateNullComparison: compares a pointer optional with NULL and a struct optional by its flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn find() -> ?i32\nfn check(pointer: ?*i32, count: ?i32) -> bool: return pointer == null and null != count and find() == null" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_i32_defined\n#define mn_optional_i32_defined\ntypedef struct mn_optional_i32 {\n    int32_t value;\n    bool present;\n} mn_optional_i32;\n#endif\n\nbool mn_main_check(int32_t * pointer, mn_optional_i32 count) {\n    return (((pointer == NULL) && (count.present)) && (!find().present));\n}\n",
        files[1].contents,
    );
}

test "generatePointerDifference: casts the difference of two pointers to ptrdiff_t" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn distance(start: *many i32, end: *many i32) -> isize: return end - (start + 1)" });
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
        "#include \"main.h\"\n\nptrdiff_t mn_main_distance(int32_t * start, int32_t * end) {\n    return ((ptrdiff_t)(end - (start + 1u)));\n}\n",
        files[1].contents,
    );
}

test "generateArrayComparison: calls the equality function of the array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn different(left: [2]f32, right: [2]f32) -> bool: return left != right" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_f32_defined\n#define mn_array_2_f32_defined\ntypedef struct mn_array_2_f32 {\n    float items[2];\n} mn_array_2_f32;\n#endif\n\n#ifndef mn_array_2_f32_equal_defined\n#define mn_array_2_f32_equal_defined\nstatic inline bool mn_array_2_f32_equal(mn_array_2_f32 one, mn_array_2_f32 two) {\n    for (size_t index = 0; index < 2; index += 1) {\n        if (one.items[index] != two.items[index]) return false;\n    }\n    return true;\n}\n#endif\n\nbool mn_main_different(mn_array_2_f32 left, mn_array_2_f32 right) {\n    return (!mn_array_2_f32_equal(left, right));\n}\n",
        files[1].contents,
    );
}

test "generateArrayComparison: compares arrays of length zero as equal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn empty() -> [0]i32\nfn same(other: [0]i32) -> bool: return empty() == other" });
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
        "#include \"main.h\"\n\nbool mn_main_same() {\n    return (empty(), true);\n}\n",
        files[1].contents,
    );
}

test "generateUnary: writes prefix operators and casts narrow results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate(value: i8) -> i8: return -value\nfn invert(value: u16) -> u16: return ~value\nfn flip(value: bool) -> bool: return !value\nfn twice() -> i32: return - -5" });
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
        "#include \"main.h\"\n\nint8_t mn_main_negate(int8_t value) {\n    return ((int8_t)(-value));\n}\n\nuint16_t mn_main_invert(uint16_t value) {\n    return ((uint16_t)(~value));\n}\n\nbool mn_main_flip(bool value) {\n    return (!value);\n}\n\nint32_t mn_main_twice() {\n    return (- -5);\n}\n",
        files[1].contents,
    );
}

test "generateUnary: casts a negated f16 back to _Float16" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate(value: f16) -> f16: return -value" });
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
        "#include \"main.h\"\n\n_Float16 mn_main_negate(_Float16 value) {\n    return ((_Float16)(-value));\n}\n",
        files[1].contents,
    );
}

test "generateZeroSizedAddress: points the addresses of zero-sized values to one shared object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn keep(marker: *const Marker)\nfn show(marker: Marker):\n    var markers: [2]Marker = undefined\n    keep(&marker)\n    keep(&markers[1])" });
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
        "#include \"main.h\"\n\nvoid mn_main_show() {\n    keep(((void const *)&mn_zero_sized));\n    keep(((void *)&mn_zero_sized));\n}\n",
        files[1].contents,
    );
}

test "generateZeroSizedAddress: runs the calls of a zero-sized value before its address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn keep(marker: *const Marker)\nexternal fn position() -> usize\nfn show(markers: [2]Marker): keep(&markers[position()])" });
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
        "#include \"main.h\"\n\nvoid mn_main_show() {\n    keep((position(), ((void const *)&mn_zero_sized)));\n}\n",
        files[1].contents,
    );
}

test "generateNull: writes NULL for an optional pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?*i32: return null\nfn take(value: ?*i32): _ = value\nfn main():\n    const value: ?*i32 = null\n    take(value)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t * mn_main_nothing() {\n    return NULL;\n}\n\nvoid mn_main_take(int32_t *) {}\n\nint main() {\n    int32_t * const value = NULL;\n    mn_main_take(value);\n}\n",
        files[1].contents,
    );
}

test "generateNull: writes NULL for an optional function" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?fn(i32) -> bool: return null" });
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
        "#include \"main.h\"\n\ntypeof(bool (*)(int32_t)) mn_main_nothing() {\n    return NULL;\n}\n",
        files[1].contents,
    );
}

test "generateNull: writes an initializer in a stored constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [2]?bool = {null, null}\nfn all() -> [2]?bool: return values" });
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
        "#include \"main.h\"\n\n#ifndef mn_optional_bool_defined\n#define mn_optional_bool_defined\ntypedef struct mn_optional_bool {\n    bool value;\n    bool present;\n} mn_optional_bool;\n#endif\n\n#ifndef mn_array_2_optional_bool_defined\n#define mn_array_2_optional_bool_defined\ntypedef struct mn_array_2_optional_bool {\n    mn_optional_bool items[2];\n} mn_array_2_optional_bool;\n#endif\n\nconst mn_array_2_optional_bool mn_main_values = { .items = { { .present = false }, { .present = false } } };\n\nmn_array_2_optional_bool mn_main_all() {\n    return mn_main_values;\n}\n",
        files[1].contents,
    );
}

test "generateFunctionName: writes the name of a function used as a value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn double(value: i32) -> i32: return value\nfn apply(callback: fn(i32) -> i32): _ = callback\nfn main():\n    const other: fn(i32) -> i32 = double\n    apply(double)\n    apply(other)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_double(int32_t value) {\n    return value;\n}\n\nvoid mn_main_apply(typeof(int32_t (*)(int32_t))) {}\n\nint main() {\n    const typeof(int32_t (*)(int32_t)) other = mn_main_double;\n    mn_main_apply(mn_main_double);\n    mn_main_apply(other);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionName: writes a function in a stored constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two(): noop\nconst steps: [2]fn() = {one, two}\nfn all() -> [2]fn(): return steps" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_function_0_void_defined\n#define mn_array_2_function_0_void_defined\ntypedef struct mn_array_2_function_0_void {\n    typeof(void (*)()) items[2];\n} mn_array_2_function_0_void;\n#endif\n\nconst mn_array_2_function_0_void mn_main_steps = { .items = { mn_main_one, mn_main_two } };\n\nvoid mn_main_one() {}\n\nvoid mn_main_two() {}\n\nmn_array_2_function_0_void mn_main_all() {\n    return mn_main_steps;\n}\n",
        files[1].contents,
    );
}

test "generateFunctionName: writes the name of a method or an external function used as a value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write_text(text: []const u8)\nstruct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn apply(measure: fn(Point) -> f32, write: fn([]const u8)):\n    _ = measure\n    _ = write\nfn main(): apply(Point::length, write_text)" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nfloat mn_main_Point_length(mn_main_Point self) {\n    return self.x;\n}\n\nvoid mn_main_apply(typeof(float (*)(struct mn_main_Point)), typeof(void (*)(struct mn_slice_u8))) {}\n\nint main() {\n    mn_main_apply(mn_main_Point_length, write_text);\n}\n",
        files[1].contents,
    );
}

test "generateNegativeInteger: writes a negative integer in decimal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32: return -0x10" });
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
        "#include \"main.h\"\n\nint32_t mn_main_value() {\n    return -16;\n}\n",
        files[1].contents,
    );
}

test "generateNegativeInteger: writes the minimum of a 64-bit type as the negated maximum minus one" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i64: return -9223372036854775808\nfn two() -> isize: return -9223372036854775808" });
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
        "#include \"main.h\"\n\nint64_t mn_main_one() {\n    return (-9223372036854775807 - 1);\n}\n\nptrdiff_t mn_main_two() {\n    return (-9223372036854775807 - 1);\n}\n",
        files[1].contents,
    );
}

test "generateNegativeInteger: builds a negative 128-bit integer from two halves" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i128: return -5\nfn two() -> i128: return -170141183460469231731687303715884105728" });
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
        "#include \"main.h\"\n\nint128_t mn_main_one() {\n    return -((int128_t)0x0u << 64 | 0x5u);\n}\n\nint128_t mn_main_two() {\n    return (-((int128_t)0x7fffffffffffffffu << 64 | 0xffffffffffffffffu) - 1);\n}\n",
        files[1].contents,
    );
}

test "generateSplitLiteral: builds a 128-bit literal from two halves" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn big() -> u128: return 340282366920938463463374607431768211455\nfn small() -> i128: return 1" });
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
        "#include \"main.h\"\n\nuint128_t mn_main_big() {\n    return ((uint128_t)0xffffffffffffffffu << 64 | 0xffffffffffffffffu);\n}\n\nint128_t mn_main_small() {\n    return ((int128_t)0x0u << 64 | 0x1u);\n}\n",
        files[1].contents,
    );
}

test "generateIndex: writes an element of an array, a slice and a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: [3]i32, items: []const i32, pointer: *many i32) -> i32: return values[0] + items[1] + pointer[2]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nint32_t mn_main_read(mn_array_3_i32 values, mn_slice_i32 items, int32_t * pointer) {\n    return ((values.items[0u] + items.items[1u]) + pointer[2u]);\n}\n",
        files[1].contents,
    );
}

test "generateIndex: writes an element of a tuple as its member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(pair: (i32, bool)) -> bool: return pair[1]" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nbool mn_main_second(mn_tuple_2_i32_bool pair) {\n    return pair._1;\n}\n",
        files[1].contents,
    );
}

test "generateIndex: indexes the array a pointer points to after a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: *const [3]i32) -> i32: return values.*[1]" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nint32_t mn_main_read(struct mn_array_3_i32 const * values) {\n    return (*values).items[1u];\n}\n",
        files[1].contents,
    );
}

test "generateIndex: writes an element of a tuple constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pair: (i32, bool) = {1, true}\nfn second() -> bool: return pair[1]" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nbool mn_main_second() {\n    return (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true }._1;\n}\n",
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_array_4_u8 buffer;\n    fill((mn_slice_u8){ .items = buffer.items, .length = 4 });\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: []const i32): _ = values\nfn main():\n    const values = [2]i32{1, 2}\n    take(values[..])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(mn_slice_i32) {}\n\nint main() {\n    const mn_array_2_i32 values = (mn_array_2_i32){ .items = { 1, 2 } };\n    mn_main_take((mn_slice_i32){ .items = (int32_t *)values.items, .length = 2 });\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn take(markers: []const Marker): _ = markers\nfn main():\n    const markers = [2]Marker{Marker{}, Marker{}}\n    take(markers[..])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Marker_defined\n#define mn_slice_main_Marker_defined\ntypedef struct mn_slice_main_Marker {\n    void *items;\n    size_t length;\n} mn_slice_main_Marker;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(mn_slice_main_Marker) {}\n\nint main() {\n    mn_main_take((mn_slice_main_Marker){ .length = 2 });\n}\n",
        files[1].contents,
    );
}

test "generateSlice: offsets the items by the start and subtracts the start from the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []i32) -> []i32: return values[1..3]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part(mn_slice_i32 values) {\n    return (mn_slice_i32){ .items = values.items + 1u, .length = 3u - 1u };\n}\n",
        files[1].contents,
    );
}

test "generateSlice: slices an array up to an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn fill(bytes: []u8)\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer[..2])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_array_4_u8 buffer;\n    fill((mn_slice_u8){ .items = buffer.items, .length = 2u });\n}\n",
        files[1].contents,
    );
}

test "generateSlice: slices the array behind a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: *[4]i32) -> []i32: return values[1..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_4_i32_defined\n#define mn_array_4_i32_defined\ntypedef struct mn_array_4_i32 {\n    int32_t items[4];\n} mn_array_4_i32;\n#endif\n\nmn_slice_i32 mn_main_part(struct mn_array_4_i32 * values) {\n    return (mn_slice_i32){ .items = values->items + 1u, .length = 4 - 1u };\n}\n",
        files[1].contents,
    );
}

test "generateSlice: casts the items behind a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: *const [4]i32) -> []const i32: return values[..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_4_i32_defined\n#define mn_array_4_i32_defined\ntypedef struct mn_array_4_i32 {\n    int32_t items[4];\n} mn_array_4_i32;\n#endif\n\nmn_slice_i32 mn_main_part(struct mn_array_4_i32 const * values) {\n    return (mn_slice_i32){ .items = (int32_t *)values->items, .length = 4 };\n}\n",
        files[1].contents,
    );
}

test "generateSlice: slices a multiple value pointer up to an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(items: *many const u8, count: usize) -> []const u8: return items[..count]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nmn_slice_u8 mn_main_part(uint8_t const * items, size_t count) {\n    return (mn_slice_u8){ .items = (uint8_t *)items, .length = count };\n}\n",
        files[1].contents,
    );
}

test "generateSlice: writes only the length of a slice of zero-sized elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn part(markers: []const Marker) -> []const Marker: return markers[1..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Marker_defined\n#define mn_slice_main_Marker_defined\ntypedef struct mn_slice_main_Marker {\n    void *items;\n    size_t length;\n} mn_slice_main_Marker;\n#endif\n\nmn_slice_main_Marker mn_main_part(mn_slice_main_Marker markers) {\n    return (mn_slice_main_Marker){ .length = markers.length - 1u };\n}\n",
        files[1].contents,
    );
}

test "generateSlice: offsets a slice of a stored constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [3]i32 = {1, 2, 3}\nexternal fn take(items: []const i32)\nfn main(): take(values[1..])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nchar mn_zero_sized;\n\nconst mn_array_3_i32 mn_main_values = { .items = { 1, 2, 3 } };\n\nint main() {\n    take((mn_slice_i32){ .items = (int32_t *)mn_main_values.items + 1u, .length = 3 - 1u });\n}\n",
        files[1].contents,
    );
}

test "generateSliceOf: converts a pointer to an array of length zero to its length only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn read(buffer: []u8) -> usize\nfn main():\n    var buffer: [0]u8 = undefined\n    _ = read(&buffer)" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    read((mn_slice_u8){ .length = 0 });\n}\n",
        files[1].contents,
    );
}

test "generateSliceOf: runs the calls of a sliced value of length zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn locate() -> *[0]i32\nexternal fn take(values: []i32)\nfn main(): take(locate()[..])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    take((locate(), (mn_slice_i32){ .length = 0 }));\n}\n",
        files[1].contents,
    );
}

test "generateSliceOf: runs the calls of a converted value of length zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn locate() -> *[0]i32\nexternal fn take(values: []i32)\nfn main(): take(locate())" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    take((locate(), (mn_slice_i32){ .length = 0 }));\n}\n",
        files[1].contents,
    );
}

test "generateSliceLength: takes the length of a slice without an end from the slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []i32) -> []i32: return values[2..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part(mn_slice_i32 values) {\n    return (mn_slice_i32){ .items = values.items + 2u, .length = values.length - 2u };\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nstruct Line:\n    start: Point\n    end: Point\nconst origin = Point{x = 0, y = 0}\nfn make() -> Line: return Line{start = origin, end = origin}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst origin: Point = {x = 0}\nfn make() -> Point: return origin" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\nconst cards: [2]Card = {\n    {question = \"a\"},\n    {question = \"b\"},\n}\nfn all() -> [2]Card: return cards" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\nconst mn_array_2_main_Card mn_main_cards = { .items = { { .question = { .items = (uint8_t *)\"a\", .length = 1 } }, { .question = { .items = (uint8_t *)\"b\", .length = 1 } } } };\n\nmn_array_2_main_Card mn_main_all() {\n    return mn_main_cards;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\nconst cards: [_]Card = {\n    {question = \"a\"},\n    {question = \"b\"},\n}\nfn all() -> [2]Card: return cards" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_2_main_Card_defined\n#define mn_array_2_main_Card_defined\ntypedef struct mn_array_2_main_Card {\n    mn_main_Card items[2];\n} mn_array_2_main_Card;\n#endif\n\nconst mn_array_2_main_Card mn_main_cards = { .items = { { .question = { .items = (uint8_t *)\"a\", .length = 1 } }, { .question = { .items = (uint8_t *)\"b\", .length = 1 } } } };\n\nmn_array_2_main_Card mn_main_all() {\n    return mn_main_cards;\n}\n",
        files[1].contents,
    );
}

test "generateConstant: writes the operators of a constant at each use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: i32 = 10\nconst double: i32 = limit * 2\nconst triple = limit * 3\nconst mask: u32 = 1 << 4\nconst ready: bool = !(limit < 5)\nfn sum() -> i32: return double + triple\nfn bits() -> u32: return mask\nfn check() -> bool: return ready" });
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    return ((10 * 2) + (10 * 3));\n}\n\nuint32_t mn_main_bits() {\n    return mn_shift_left_u32(1u, 4u);\n}\n\nbool mn_main_check() {\n    return (!(10 < 5));\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: passes a pointer to an array as a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn read(buffer: []u8) -> usize\nfn main():\n    var buffer: [4096]u8 = undefined\n    _ = read(&buffer)" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4096_u8_defined\n#define mn_array_4096_u8_defined\ntypedef struct mn_array_4096_u8 {\n    uint8_t items[4096];\n} mn_array_4096_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_array_4096_u8 buffer;\n    read((mn_slice_u8){ .items = (&buffer)->items, .length = 4096 });\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: passes the receiver of a method as its first argument" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    points: i32\n    fn get(self: Self) -> i32: return self.points\nfn show(card: Card) -> i32: return card.get()" });
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
        "#include \"main.h\"\n\nint32_t mn_main_Card_get(mn_main_Card self) {\n    return self.points;\n}\n\nint32_t mn_main_show(mn_main_Card card) {\n    return mn_main_Card_get(card);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: leaves out a zero-sized receiver" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker:\n    fn go(self: Self): _ = self\nfn main(): Marker{}.go()" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_Marker_go() {}\n\nint main() {\n    mn_main_Marker_go();\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: calls through the function pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn first(value: i32, _: Marker) -> i32: return value\nfn apply(callback: fn(i32, Marker) -> i32) -> i32: return callback(1, Marker{})\nfn main():\n    const step: fn(i32, Marker) -> i32 = first\n    _ = step(2, Marker{})\n    _ = apply(first)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_first(int32_t value) {\n    return value;\n}\n\nint32_t mn_main_apply(typeof(int32_t (*)(int32_t)) callback) {\n    return callback(1);\n}\n\nint main() {\n    const typeof(int32_t (*)(int32_t)) step = mn_main_first;\n    step(2);\n    mn_main_apply(mn_main_first);\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: passes a pointer to an array as a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(run: fn([]u8) -> usize, buffer: *[4]u8) -> usize: return run(buffer)" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nsize_t mn_main_apply(typeof(size_t (*)(struct mn_slice_u8)) run, struct mn_array_4_u8 * buffer) {\n    return run((mn_slice_u8){ .items = buffer->items, .length = 4 });\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: calls through a constant of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "steps.mn", .data = "fn first(value: i32) -> i32: return value\nconst step: fn(i32) -> i32 = first" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = steps::step(1)" });
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
        "#include \"main.h\"\n#include \"steps.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_steps_first(1);\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: writes an untyped struct literal argument as a compound literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn apply(callback: fn(Data) -> i32) -> i32: return callback({value = 1})" });
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
        "#include \"main.h\"\n\nint32_t mn_main_apply(typeof(int32_t (*)(struct mn_main_Data)) callback) {\n    return callback((mn_main_Data){ .value = 1 });\n}\n",
        files[1].contents,
    );
}

test "generateFields: writes a compound literal for each struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nstruct Line:\n    start: Point\n    end: Point\nfn make() -> Line: return Line{start = Point{x = 0, y = 0}, end = Point{y = 2, x = 1}}" });
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

test "generateFields: leaves out zero-sized fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nstruct Wrapper:\n    marker: Marker\nfn make() -> Holder: return Holder{marker = Marker{}, value = 1}" });
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

test "generateFields: writes the defaults of left out fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32 = 0\n    y: i32 = 7\nfn make() -> Point: return Point{y = 1}" });
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

test "generateFields: writes every default for empty braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    one: i32 = 0\n    two: i32 = 7\nfn make() -> Data: return {}" });
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
        "#include \"main.h\"\n\nmn_main_Data mn_main_make() {\n    return (mn_main_Data){ .one = 0, .two = 7 };\n}\n",
        files[1].contents,
    );
}

test "generateFields: writes a compound literal for a field value without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct DataOne:\n    one: i32\n    two: i32\nstruct DataTwo:\n    one: DataOne\n    two: DataOne\nfn make() -> DataTwo: return DataTwo{two = DataOne{one = 3, two = 4}, one = {two = 2, one = 1}}" });
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
        "#include \"main.h\"\n\nmn_main_DataTwo mn_main_make() {\n    return (mn_main_DataTwo){ .two = (mn_main_DataOne){ .one = 3, .two = 4 }, .one = (mn_main_DataOne){ .two = 2, .one = 1 } };\n}\n",
        files[1].contents,
    );
}

test "generateFields: converts a pointer to an array in a field to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    bytes: []u8\nfn wrap(buffer: *[4]u8) -> Data: return Data{bytes = buffer}" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nmn_main_Data mn_main_wrap(struct mn_array_4_u8 * buffer) {\n    return (mn_main_Data){ .bytes = (mn_slice_u8){ .items = buffer->items, .length = 4 } };\n}\n",
        files[1].contents,
    );
}

test "generateElements: converts a pointer to an array in an element to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn wrap(buffer: *[4]u8) -> [1][]u8: return [1][]u8{buffer}" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_1_slice_u8_defined\n#define mn_array_1_slice_u8_defined\ntypedef struct mn_array_1_slice_u8 {\n    mn_slice_u8 items[1];\n} mn_array_1_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nmn_array_1_slice_u8 mn_main_wrap(struct mn_array_4_u8 * buffer) {\n    return (mn_array_1_slice_u8){ .items = { (mn_slice_u8){ .items = buffer->items, .length = 4 } } };\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values = [2]i32{1, 2}\nstruct Box:\n    items: []const i32\nconst box = Box{items = values[..]}\nfn show() -> Box: return box" });
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

test "generateValue: writes a slice with bounds in a stored constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [3]i32 = {1, 2, 3}\nstruct Holder:\n    items: []const i32\nconst holder: Holder = Holder{items = values[1..2]}\nfn read() -> Holder: return holder" });
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
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nconst mn_array_3_i32 mn_main_values = { .items = { 1, 2, 3 } };\nconst mn_main_Holder mn_main_holder = { .items = { .items = (int32_t *)mn_main_values.items + 1u, .length = 2u - 1u } };\n\nmn_main_Holder mn_main_read() {\n    return mn_main_holder;\n}\n",
        files[1].contents,
    );
}

test "generateValue: writes an operation in a stored constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 2i32 + 3i32\nexternal fn keep(value: *const i32)\nfn main(): keep(&limit)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nconst int32_t mn_main_limit = (2 + 3);\n\nint main() {\n    keep(&mn_main_limit);\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn half() -> f32: return 0.5\nfn whole() -> f64: return 1.0" });
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
        "#include \"main.h\"\n\nfloat mn_main_half() {\n    return 0.5f;\n}\n\ndouble mn_main_whole() {\n    return 1.0;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> usize: return 3" });
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

test "generateType: maps isize to ptrdiff_t" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> isize: return 3" });
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
        "#include \"main.h\"\n\nptrdiff_t mn_main_count() {\n    return 3;\n}\n",
        files[1].contents,
    );
}

test "generateType: writes a pointer as a C pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: *const i32, values: *many u8, nested: **const bool):\n    _ = value\n    _ = values\n    _ = nested" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nvoid mn_main_show(int32_t const *, uint8_t *, bool const * *);\n",
        files[0].contents,
    );
}

test "generateType: points to a struct by its tag" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck:\n    top: *Card\nstruct Card:\n    points: i32\nfn show(deck: Deck): _ = deck" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Card {\n    int32_t points;\n} mn_main_Card;\n\ntypedef struct mn_main_Deck {\n    struct mn_main_Card * top;\n} mn_main_Deck;\n\nvoid mn_main_show(mn_main_Deck);\n",
        files[0].contents,
    );
}

test "generateType: names an optional after its child" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    value: ?u8\n    pointer: ?*u8\nfn show(box: Box): _ = box" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_optional_u8_defined\n#define mn_optional_u8_defined\ntypedef struct mn_optional_u8 {\n    uint8_t value;\n    bool present;\n} mn_optional_u8;\n#endif\n\ntypedef struct mn_main_Box {\n    mn_optional_u8 value;\n    uint8_t * pointer;\n} mn_main_Box;\n\nvoid mn_main_show(mn_main_Box);\n",
        files[0].contents,
    );
}

test "generateType: writes a function type as a C function pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn apply(callback: fn(i32, Marker, bool) -> i32, done: fn(), maybe: ?fn([2]u8) -> Marker):\n    _ = callback\n    _ = done\n    _ = maybe" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_array_2_u8 mn_array_2_u8;\n\nvoid mn_main_apply(typeof(int32_t (*)(int32_t, bool)), typeof(void (*)()), typeof(void (*)(struct mn_array_2_u8)));\n",
        files[0].contents,
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nexternal fn make() -> Holder\nfn use(marker: Marker, value: i32):\n    _ = marker\n    _ = value\nfn take(holder: Holder) -> Marker: return holder.marker\nfn get() -> Marker: return make().marker\nfn main(): use(make().marker, 1)" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_use(int32_t) {}\n\nvoid mn_main_take(mn_main_Holder holder) {\n    return;\n}\n\nvoid mn_main_get() {\n    make();\n    return;\n}\n\nint main() {\n    (make(), mn_main_use(1));\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nstruct Holder:\n    marker: Marker\n    value: i32\nstruct Wrapper:\n    marker: Marker\nfn mark() -> Marker: return Marker{}\nfn use(wrapper: Wrapper, value: i32):\n    _ = wrapper\n    _ = value\nfn main():\n    use(Wrapper{marker = mark()}, 1)\n    use(Wrapper{marker = Marker{}}, 2)\n" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_mark() {\n    return;\n}\n\nvoid mn_main_use(int32_t) {}\n\nint main() {\n    (mn_main_mark(), mn_main_use(1));\n    mn_main_use(2);\n}\n",
        files[1].contents,
    );
}

test "generateOperandEffects: runs the calls in the index of a zero-sized element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn position() -> usize\nfn get(markers: []const Marker) -> Marker: return markers[position()]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Marker_defined\n#define mn_slice_main_Marker_defined\ntypedef struct mn_slice_main_Marker {\n    void *items;\n    size_t length;\n} mn_slice_main_Marker;\n#endif\n\nvoid mn_main_get(mn_slice_main_Marker markers) {\n    position();\n    return;\n}\n",
        files[1].contents,
    );
}

test "isStored: stores a constant whose address is taken in one object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 10i32\nconst pair = (i32, bool){1, true}\nexternal fn keep(value: *const i32)\nfn main():\n    keep(&limit)\n    keep(&limit)\n    keep(&pair[0])" });
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
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nconst int32_t mn_main_limit = 10;\nconst mn_tuple_2_i32_bool mn_main_pair = { ._0 = 1, ._1 = true };\n\nint main() {\n    keep(&mn_main_limit);\n    keep(&mn_main_limit);\n    keep(&mn_main_pair._0);\n}\n",
        files[1].contents,
    );
}

test "buildCName: names a method after its module, its type and its name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    points: i32\n    fn get(self: Self) -> i32: return self.points" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Card {\n    int32_t points;\n} mn_main_Card;\n\nint32_t mn_main_Card_get(mn_main_Card self);\n",
        files[0].contents,
    );
}

test "buildCName: keeps main only for the entry point" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    points: i32\n    fn main(self: Self) -> i32: return self.points\nfn main(): noop" });
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Card_main(mn_main_Card self) {\n    return self.points;\n}\n\nint main() {}\n",
        files[1].contents,
    );
}

test "buildCName: names a function of an implementation after its type, its trait and its name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Square {\n    int32_t side;\n} mn_main_Square;\n\nint32_t mn_main_Square_Shape_area(mn_main_Square self);\n",
        files[0].contents,
    );
}

test "buildTypeName: names a slice by its elements" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nimpl Shape for []const u8:\n    fn area(self: Self) -> i32:\n        _ = self\n        return 0" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nint32_t mn_main_slice_u8_Shape_area(mn_slice_u8);\n",
        files[0].contents,
    );
}

test "buildTypeName: names a pointer by its count, mutability and target" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nimpl Shape for *many const u8:\n    fn area(self: Self) -> i32:\n        _ = self\n        return 0" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nint32_t mn_main_pointer_many_const_u8_Shape_area(uint8_t const *);\n",
        files[0].contents,
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

test "repeatsUnit: stores a start with a call in a temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn first() -> usize\nfn part(values: []i32) -> []i32: return values[first()..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part(mn_slice_i32 values) {\n    size_t mn_temporary_1;\n    return (mn_temporary_1 = first(), (mn_slice_i32){ .items = values.items + mn_temporary_1, .length = values.length - mn_temporary_1 });\n}\n",
        files[1].contents,
    );
}

test "repeatsUnit: stores a sliced call in a temporary when the length comes from it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> []i32\nfn part() -> []i32: return make()[1..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part() {\n    mn_slice_i32 mn_temporary_1;\n    return (mn_temporary_1 = make(), (mn_slice_i32){ .items = mn_temporary_1.items + 1u, .length = mn_temporary_1.length - 1u });\n}\n",
        files[1].contents,
    );
}

test "repeatsUnit: leaves a call in the end in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn last() -> usize\nfn part(values: []i32) -> []i32: return values[..last()]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part(mn_slice_i32 values) {\n    return (mn_slice_i32){ .items = values.items, .length = last() };\n}\n",
        files[1].contents,
    );
}

test "repeatsUnit: leaves a sliced call with an end in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> []i32\nfn part() -> []i32: return make()[..2]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_part() {\n    return (mn_slice_i32){ .items = make().items, .length = 2u };\n}\n",
        files[1].contents,
    );
}

test "isStoredAsConstant: casts a slice of an element of a constant array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(values: []const i32)\nfn main():\n    const grid = [2][2]i32{{1, 2}, {3, 4}}\n    take(grid[1][..])" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\n#ifndef mn_array_2_array_2_i32_defined\n#define mn_array_2_array_2_i32_defined\ntypedef struct mn_array_2_array_2_i32 {\n    mn_array_2_i32 items[2];\n} mn_array_2_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    const mn_array_2_array_2_i32 grid = (mn_array_2_array_2_i32){ .items = { (mn_array_2_i32){ .items = { 1, 2 } }, (mn_array_2_i32){ .items = { 3, 4 } } } };\n    take((mn_slice_i32){ .items = (int32_t *)grid.items[1u].items, .length = 2 });\n}\n",
        files[1].contents,
    );
}

test "isStoredAsConstant: casts a slice of an array field behind a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck:\n    cards: [2]i32\nfn cards(deck: *const Deck) -> []const i32: return deck.cards[..]" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nmn_slice_i32 mn_main_cards(struct mn_main_Deck const * deck) {\n    return (mn_slice_i32){ .items = (int32_t *)deck->cards.items, .length = 2 };\n}\n",
        files[1].contents,
    );
}

test "generateText: writes a NUL escape as three octal digits" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() -> []const u8: return \"\\01\"" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nmn_slice_u8 mn_main_greeting() {\n    return (mn_slice_u8){ .items = (uint8_t *)\"\\0001\", .length = 2 };\n}\n",
        files[1].contents,
    );
}

test "generateText: writes a unicode escape in a string as UTF-8 bytes" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() -> []const u8: return \"a\\u{E9}\\u{1F600}\"" });
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nmn_slice_u8 mn_main_greeting() {\n    return (mn_slice_u8){ .items = (uint8_t *)\"a\\303\\251\\360\\237\\230\\200\", .length = 7 };\n}\n",
        files[1].contents,
    );
}

test "countBytes: counts a unicode escape as its UTF-8 bytes" {
    try std.testing.expectEqual(4, countBytes("a\\u{e9}\\0"));
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
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_4_u8_defined\n#define mn_array_4_u8_defined\ntypedef struct mn_array_4_u8 {\n    uint8_t items[4];\n} mn_array_4_u8;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(mn_slice_u8) {}\n\nint main() {\n    mn_array_4_u8 buffer;\n    mn_slice_u8 bytes = (mn_slice_u8){ .items = buffer.items, .length = 4 };\n    bytes = (mn_slice_u8){ .items = buffer.items, .length = 4 };\n    mn_main_take(bytes);\n}\n",
        files[1].contents,
    );
}

test "containsType: keeps arrays of pointers that differ in mutability apart" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(one: [2]*i32, two: [2]*const i32):\n    _ = one\n    _ = two" });
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
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_array_2_pointer_i32 mn_array_2_pointer_i32;\ntypedef struct mn_array_2_pointer_const_i32 mn_array_2_pointer_const_i32;\n\nvoid mn_main_take(mn_array_2_pointer_i32, mn_array_2_pointer_const_i32);\n",
        files[0].contents,
    );
}
