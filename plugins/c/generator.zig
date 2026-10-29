const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;
const Value = core.Value;

const followPointer = types.followPointer;
const isZeroSized = types.isZeroSized;

pub const Generator = struct {
    program: ast.Program,
    runtime_functions: std.ArrayList([]const u8) = .empty,
    names: []const []const ?[]const u8 = &.{},
    addressed: []const ast.Resolution.Constant = &.{},
    local_names: []const LocalName = &.{},
    steps: []const Step = &.{},
    loops: []const *const ast.Statement = &.{},
    tuple_declarations: []const *const ast.Statement = &.{},
    matches: []const *const ast.Statement = &.{},
    innermost_loop: ?*const ast.Statement = null,
    frames: std.ArrayList(Frame) = .empty,
    unrolled: std.ArrayList(Unrolled) = .empty,
    parameters: []const ast.TypedName = &.{},
    return_type: types.Type = .void,
    sequenced: bool = false,
    statics: std.ArrayList(Static) = .empty,
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
                if (isCompileTimeFunction(declaration)) continue;
                const signature = switch (declaration.kind) {
                    .function_definition => |function| function.signature,
                    .function_declaration => |function_declaration| function_declaration,
                    .constant_declaration, .struct_definition, .enum_definition => continue,
                    .typeclass_definition, .instance_declaration, .import => continue,
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
            switch (value_type) {
                .@"struct" => |struct_type| {
                    self.module_index = struct_type.module;
                    for (struct_type.fields) |field| try self.checkName(field.name, field.location);
                },
                .@"enum" => |enumeration| {
                    self.module_index = enumeration.module;
                    for (enumeration.cases) |case| try self.checkName(case.name, case.location);
                },
                else => {},
            }
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
                .@"enum" => |enumeration| {
                    for (enumeration.cases) |case| {
                        try collectPrototypeTags(allocator, &tags, case.type orelse continue, false);
                    }
                },
                .array => |array| try collectPrototypeTags(allocator, &tags, array.element, false),
                .slice => |slice| try collectPrototypeTags(allocator, &tags, slice.element, false),
                .optional => |optional| {
                    try collectPrototypeTags(allocator, &tags, optional.child, false);
                },
                .result => |result| {
                    try collectPrototypeTags(allocator, &tags, .{ .@"enum" = result.error_set }, false);
                    try collectPrototypeTags(allocator, &tags, result.value, false);
                },
                .tuple => |tuple| {
                    for (tuple.elements) |element| {
                        try collectPrototypeTags(allocator, &tags, element, false);
                    }
                },
                .number, .boolean, .void, .type, .pointer, .function, .variable, .application => {
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
            switch (value_type) {
                .@"struct" => |struct_type| {
                    for (struct_type.fields) |field| try collectContainedModulesOf(allocator, &contained, field.type);
                },
                .@"enum" => |enumeration| {
                    for (enumeration.cases) |case| try collectContainedModulesOf(allocator, &contained, case.type orelse continue);
                },
                else => {},
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
            const module = switch (value_type) {
                .@"struct" => |struct_type| struct_type.module,
                .@"enum" => |enumeration| enumeration.module,
                else => continue,
            };
            if (module != module_index or types.isCompileTimeOnly(value_type)) continue;
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
            .@"enum" => try self.generateEnumDefinition(writer, value_type),
            .array => try self.generateArrayDefinition(writer, value_type),
            .slice => try self.generateSliceDefinition(writer, value_type),
            .optional => try self.generateOptionalDefinition(writer, value_type),
            .result => try self.generateResultDefinition(writer, value_type),
            .tuple => try self.generateTupleDefinition(writer, value_type),
            .number, .boolean, .void, .type, .pointer, .function, .variable, .application => {
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

    fn generateEnumDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const enumeration = value_type.@"enum";
        const declared = types.isDeclaredEnum(enumeration);
        if (!declared) {
            try writer.writeAll("#ifndef ");
            try self.generateType(writer, value_type);
            try writer.writeAll("_defined\n#define ");
            try self.generateType(writer, value_type);
            try writer.writeAll("_defined\n");
        }
        try writer.writeAll("typedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n    uint32_t tag;\n");
        if (hasPayload(enumeration)) {
            try writer.writeAll("    union {\n");
            for (enumeration.cases) |case| {
                const payload = case.type orelse continue;
                if (isZeroSized(payload)) continue;
                try writer.writeAll("        ");
                try self.generateType(writer, payload);
                try writer.writeByte(' ');
                try self.generateCaseMember(writer, enumeration, case);
                try writer.writeAll(";\n");
            }
            try writer.writeAll("    } value;\n");
        }
        try writer.writeAll("} ");
        try self.generateType(writer, value_type);
        try writer.writeAll(";\n");
        if (!declared) try writer.writeAll("#endif\n");
    }

    fn generateCaseMember(
        self: *Generator,
        writer: *std.Io.Writer,
        enumeration: *const types.Enum,
        case: types.Case,
    ) WriteError!void {
        if (!types.isDeclaredEnum(enumeration)) {
            try self.generateTypeName(writer, .{ .@"enum" = case.declaring });
            try writer.writeByte('_');
        }
        try writer.writeAll(case.name);
    }

    fn generateEnumEquality(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const enumeration = value_type.@"enum";
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
        try writer.writeAll(" two) {\n    if (one.tag != two.tag) return false;\n    switch (one.tag) {\n");
        for (enumeration.cases) |case| {
            const payload = case.type orelse continue;
            if (isZeroSized(payload)) continue;
            try writer.print("    case {d}: return ", .{case.tag});
            if (hasEqualityHelper(payload)) {
                try self.generateType(writer, payload);
                try writer.writeAll("_equal(one.value.");
                try self.generateCaseMember(writer, enumeration, case);
                try writer.writeAll(", two.value.");
                try self.generateCaseMember(writer, enumeration, case);
                try writer.writeAll(");\n");
            } else {
                try writer.writeAll("one.value.");
                try self.generateCaseMember(writer, enumeration, case);
                try writer.writeAll(" == two.value.");
                try self.generateCaseMember(writer, enumeration, case);
                try writer.writeAll(";\n");
            }
        }
        try writer.writeAll("    default: return true;\n    }\n}\n#endif\n");
    }

    fn generateEnumConversion(
        self: *Generator,
        writer: *std.Io.Writer,
        conversion: Conversion,
    ) WriteError!void {
        const source = conversion.source.@"enum";
        const target = conversion.target.@"enum";
        try writer.writeAll("#ifndef ");
        try self.generateConversionName(writer, conversion);
        try writer.writeAll("_defined\n#define ");
        try self.generateConversionName(writer, conversion);
        try writer.writeAll("_defined\nstatic inline ");
        try self.generateType(writer, conversion.target);
        try writer.writeByte(' ');
        try self.generateConversionName(writer, conversion);
        try writer.writeByte('(');
        try self.generateType(writer, conversion.source);
        try writer.writeAll(" value) {\n    ");
        try self.generateType(writer, conversion.target);
        try writer.writeAll(" result;\n    result.tag = value.tag;\n");
        if (hasPayload(source)) {
            try writer.writeAll("    switch (value.tag) {\n");
            for (source.cases) |case| {
                const payload = case.type orelse continue;
                if (isZeroSized(payload)) continue;
                try writer.print("    case {d}: result.value.", .{case.tag});
                try self.generateCaseMember(writer, target, case);
                try writer.writeAll(" = value.value.");
                try self.generateCaseMember(writer, source, case);
                try writer.writeAll("; break;\n");
            }
            try writer.writeAll("    default: break;\n    }\n");
        }
        try writer.writeAll("    return result;\n}\n#endif\n");
    }

    fn generateResultConversion(
        self: *Generator,
        writer: *std.Io.Writer,
        conversion: Conversion,
    ) WriteError!void {
        const source = conversion.source.result;
        const target = conversion.target.result;
        try writer.writeAll("#ifndef ");
        try self.generateConversionName(writer, conversion);
        try writer.writeAll("_defined\n#define ");
        try self.generateConversionName(writer, conversion);
        try writer.writeAll("_defined\nstatic inline ");
        try self.generateType(writer, conversion.target);
        try writer.writeByte(' ');
        try self.generateConversionName(writer, conversion);
        try writer.writeByte('(');
        try self.generateType(writer, conversion.source);
        try writer.writeAll(" value) {\n    ");
        try self.generateType(writer, conversion.target);
        try writer.writeAll(" result;\n    result.error = ");
        if (source.error_set == target.error_set) {
            try writer.writeAll("value.error;\n");
        } else {
            const error_conversion: Conversion = .{
                .source = .{ .@"enum" = source.error_set },
                .target = .{ .@"enum" = target.error_set },
            };
            try self.generateConversionName(writer, error_conversion);
            try writer.writeAll("(value.error);\n");
        }
        if (!isZeroSized(target.value)) try writer.writeAll("    result.value = value.value;\n");
        try writer.writeAll("    return result;\n}\n#endif\n");
    }

    fn generateConversionName(self: *Generator, writer: *std.Io.Writer, conversion: Conversion) WriteError!void {
        try self.generateType(writer, conversion.target);
        try writer.writeAll("_from_");
        try self.generateTypeName(writer, conversion.source);
    }

    fn generateCaseValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        case: ast.Resolution.Case,
        payload: ?*const ast.Expression,
    ) WriteError!void {
        const value_type: types.Type = .{ .@"enum" = case.enumeration };
        const resolved = case.enumeration.cases[case.index];
        try self.recordType(allocator, reached, value_type);
        const argument = payload orelse {
            try self.generateCompoundStart(writer, value_type, .expression);
            return writer.print(".tag = {d} }}", .{resolved.tag});
        };
        if (isZeroSized(resolved.type.?)) {
            const effects = hasEffects(argument.*);
            if (effects) {
                try writer.writeByte('(');
                try self.generateEffects(allocator, reached, writer, argument.*);
                try writer.writeAll(", ");
            }
            try self.generateCompoundStart(writer, value_type, .expression);
            try writer.print(".tag = {d} }}", .{resolved.tag});
            if (effects) try writer.writeByte(')');
            return;
        }
        try self.generateCompoundStart(writer, value_type, .expression);
        try writer.print(".tag = {d}, .value.", .{resolved.tag});
        try self.generateCaseMember(writer, case.enumeration, resolved);
        try writer.writeAll(" = ");
        try self.generateConvertedOperand(allocator, reached, writer, argument, resolved.type.?);
        try writer.writeAll(" }");
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
            if (isCompileTimeFunction(declaration)) continue;
            const signature = switch (declaration.kind) {
                .function_definition => |function| function.signature,
                .function_declaration => |function_declaration| function_declaration,
                .constant_declaration, .struct_definition, .enum_definition => continue,
                .typeclass_definition, .instance_declaration, .import => continue,
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
            .@"enum" => |enumeration| {
                if (types.isDeclaredEnum(enumeration)) {
                    if (enumeration.module == self.module_index) return;
                    if (std.mem.findScalar(usize, forward.contained, enumeration.module) != null) return;
                } else if (containsType(forward.definitions, value_type)) return;
            },
            .array, .slice, .tuple, .result => {
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
            .number, .boolean, .void, .type, .variable, .application => return,
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
            try writer.writeAll("extern ");
            const constant = declaration.kind.constant_declaration;
            try self.generateLocalType(writer, ast.extractDeclaredType(constant.type, constant.value), true);
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
            if (isCompileTimeFunction(declaration)) continue;
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
        self.statics = .empty;
        for (module.declarations, 0..) |declaration, index| {
            if (self.isStored(self.module_index, index)) {
                try self.generateConstantDefinition(allocator, &reached, &constants.writer, declaration, index);
            }
            if (isCompileTimeFunction(declaration)) continue;
            const function = switch (declaration.kind) {
                .function_definition => |function| function,
                .function_declaration, .constant_declaration, .struct_definition, .enum_definition => continue,
                .typeclass_definition, .instance_declaration, .import => continue,
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
            switch (value_type) {
                .array => try self.generateArrayEquality(writer, value_type),
                .@"enum" => try self.generateEnumEquality(writer, value_type),
                else => try self.generateOptionalEquality(writer, value_type),
            }
        }
        for (reached.conversions.items) |conversion| {
            try writer.writeByte('\n');
            if (conversion.source == .result) {
                try self.generateResultConversion(writer, conversion);
            } else {
                try self.generateEnumConversion(writer, conversion);
            }
        }
        try self.generateZeroSizedObject(writer, module);
        try self.generateErrorReportDeclaration(writer, module);
        try self.generateStatics(writer);
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

    fn generateResultDefinition(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const result = value_type.result;
        try writer.writeAll("#ifndef ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\n#define ");
        try self.generateType(writer, value_type);
        try writer.writeAll("_defined\ntypedef struct ");
        try self.generateType(writer, value_type);
        try writer.writeAll(" {\n    ");
        try self.generateType(writer, .{ .@"enum" = result.error_set });
        try writer.writeAll(" error;\n");
        if (!isZeroSized(result.value)) {
            try writer.writeAll("    ");
            try self.generateType(writer, result.value);
            try writer.writeAll(" value;\n");
        }
        try writer.writeAll("} ");
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

    fn generateErrorReportDeclaration(
        self: *Generator,
        writer: *std.Io.Writer,
        module: ast.Module,
    ) WriteError!void {
        for (module.declarations) |declaration| {
            if (!self.isEntryPoint(declaration.kind) or !isResultMain(declaration.kind)) continue;
            return writer.writeAll("\nvoid mn_runtime_error_report(char const *name);\n");
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
        try self.generateLocalType(writer, constant_type, true);
        try writer.print(" {s} = ", .{self.names[self.module_index][index].?});
        try self.generateKnownValue(allocator, reached, writer, constant.known.?.*, constant_type, .initializer);
        try writer.writeAll(";\n");
    }

    fn generateStatics(self: *Generator, writer: *std.Io.Writer) WriteError!void {
        if (self.statics.items.len == 0) return;
        try writer.writeByte('\n');
        for (self.statics.items) |static| {
            try writer.writeAll("static ");
            try self.generateType(writer, static.root_type);
            try writer.print(" {s};\n", .{static.name});
        }
        for (self.statics.items) |static| {
            try writer.writeAll("static ");
            try self.generateType(writer, static.root_type);
            try writer.print(" {s} = {s};\n", .{ static.name, static.definition });
        }
    }

    fn generateKnownValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        value: Value,
        value_type: types.Type,
        form: Form,
    ) WriteError!void {
        try self.recordType(allocator, reached, value_type);
        switch (value_type) {
            .number => |number| switch (value) {
                .integer => |integer| try self.generateKnownInteger(writer, number, integer),
                .float => |float| try generateKnownFloat(writer, number, float),
                else => unreachable,
            },
            .boolean => try writer.writeAll(if (value.boolean) "true" else "false"),
            .optional => |optional| {
                const inner = value.optional orelse return self.generateNull(writer, value_type, form);
                if (isPointerOptional(value_type)) {
                    return self.generateKnownValue(allocator, reached, writer, inner.*, optional.child, form);
                }
                try self.generateCompoundStart(writer, value_type, form);
                if (!isZeroSized(optional.child)) {
                    try writer.writeAll(".value = ");
                    try self.generateKnownValue(allocator, reached, writer, inner.*, optional.child, .initializer);
                    try writer.writeAll(", ");
                }
                try writer.writeAll(".present = true }");
            },
            .result => |result| {
                try self.generateCompoundStart(writer, value_type, form);
                if (value == .failure) {
                    const error_type: types.Type = .{ .@"enum" = result.error_set };
                    try writer.writeAll(".error = ");
                    try self.generateKnownValue(allocator, reached, writer, .{ .enumeration = value.failure }, error_type, .initializer);
                    return writer.writeAll(" }");
                }
                try writer.writeAll(".error.tag = 0");
                if (!isZeroSized(result.value)) {
                    try writer.writeAll(", .value = ");
                    try self.generateKnownValue(allocator, reached, writer, value, result.value, .initializer);
                }
                try writer.writeAll(" }");
            },
            .array => |array| {
                try self.generateCompoundStart(writer, value_type, form);
                try writer.writeAll(".items = { ");
                for (value.aggregate, 0..) |element, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try self.generateKnownValue(allocator, reached, writer, element, array.element, .initializer);
                }
                try writer.writeAll(" } }");
            },
            .tuple => |tuple| {
                try self.generateCompoundStart(writer, value_type, form);
                var written = false;
                for (value.aggregate, tuple.elements, 0..) |element, element_type, index| {
                    if (isZeroSized(element_type)) continue;
                    if (written) try writer.writeAll(", ");
                    try writer.print("._{d} = ", .{index});
                    try self.generateKnownValue(allocator, reached, writer, element, element_type, .initializer);
                    written = true;
                }
                try writer.writeAll(" }");
            },
            .@"struct" => |struct_type| {
                try self.generateCompoundStart(writer, value_type, form);
                var written = false;
                for (value.aggregate, struct_type.fields) |field_value, field| {
                    if (isZeroSized(field.type)) continue;
                    if (written) try writer.writeAll(", ");
                    try writer.print(".{s} = ", .{field.name});
                    try self.generateKnownValue(allocator, reached, writer, field_value, field.type, .initializer);
                    written = true;
                }
                try writer.writeAll(" }");
            },
            .slice => |slice| {
                const known = value.slice;
                try self.generateCompoundStart(writer, value_type, form);
                try writer.writeAll(".items = (");
                try self.generateType(writer, slice.element);
                try writer.writeAll(" *)");
                try self.generateKnownElements(allocator, reached, writer, known.array, known.start);
                try writer.print(", .length = {d} }}", .{known.length});
            },
            .pointer => |pointer| switch (value) {
                .function => |function| try self.generateFunctionName(allocator, reached, writer, function),
                .pointer => |known| {
                    if (isZeroSized(pointer.target)) {
                        try writer.writeAll("((");
                        try self.generateType(writer, value_type);
                        return writer.writeAll(")&mn_zero_sized)");
                    }
                    try writer.writeAll("((");
                    try self.generateType(writer, value_type);
                    try writer.writeAll(")&");
                    try self.generatePlace(allocator, reached, writer, known);
                    try writer.writeByte(')');
                },
                .many => |many| {
                    try writer.writeAll("((");
                    try self.generateType(writer, value_type);
                    try writer.writeAll(")");
                    try self.generateKnownElements(allocator, reached, writer, many.array, @intCast(many.index));
                    try writer.writeByte(')');
                },
                else => unreachable,
            },
            .@"enum" => |enumeration| {
                const known = value.enumeration;
                try self.generateCompoundStart(writer, value_type, form);
                try writer.print(".tag = {d}", .{known.case.tag});
                const payload = known.case.type orelse return writer.writeAll(" }");
                if (isZeroSized(payload)) return writer.writeAll(" }");
                try writer.writeAll(", .value = { .");
                try self.generateCaseMember(writer, enumeration, known.case.*);
                try writer.writeAll(" = ");
                try self.generateKnownValue(allocator, reached, writer, known.value.?.*, payload, .initializer);
                try writer.writeAll(" } }");
            },
            .void, .type, .function, .variable, .application => unreachable,
        }
    }

    fn generateCompoundStart(self: *Generator, writer: *std.Io.Writer, value_type: types.Type, form: Form) WriteError!void {
        if (form == .expression) {
            try writer.writeByte('(');
            try self.generateType(writer, value_type);
            try writer.writeByte(')');
        }
        try writer.writeAll("{ ");
    }

    fn generateKnownInteger(self: *Generator, writer: *std.Io.Writer, number: types.NumberType, value: i129) WriteError!void {
        if (number == .i128 or number == .u128) {
            if (value >= 0) return self.generateSplitLiteral(writer, @intCast(value), number);
            if (value == std.math.minInt(i128)) {
                try writer.writeAll("(-");
                try self.generateSplitLiteral(writer, std.math.maxInt(i128), number);
                return writer.writeAll(" - 1)");
            }
            try writer.writeAll("(-");
            try self.generateSplitLiteral(writer, @intCast(-value), number);
            return writer.writeByte(')');
        }
        if (value == std.math.minInt(i64)) return writer.writeAll("(-9223372036854775807 - 1)");
        try writer.print("{d}", .{value});
        switch (number) {
            .u8, .u16, .u32, .u64, .usize => try writer.writeByte('u'),
            .i8, .i16, .i32, .i64, .isize => {},
            .i128, .u128, .f16, .f32, .f64, .f128 => unreachable,
        }
    }

    fn generateKnownElements(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        array: Value.Pointer,
        offset: usize,
    ) WriteError!void {
        if (array.text) {
            try writer.writeByte('"');
            var current = array.root.*;
            for (array.path) |position| current = current.aggregate[position];
            for (current.aggregate) |byte| try generateKnownByte(writer, @intCast(byte.integer));
            try writer.writeByte('"');
            if (offset > 0) try writer.print(" + {d}", .{offset});
            return;
        }
        if (offset == 0) {
            try self.generatePlace(allocator, reached, writer, array);
            return writer.writeAll(".items");
        }
        try writer.writeByte('(');
        try self.generatePlace(allocator, reached, writer, array);
        try writer.print(".items + {d})", .{offset});
    }

    fn generatePlace(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        pointer: Value.Pointer,
    ) WriteError!void {
        if (self.findConstantCell(pointer.root)) |constant| {
            try self.recordModule(allocator, reached, constant.module);
            try writer.writeAll(self.names[constant.module][constant.declaration].?);
        } else {
            try writer.writeAll(try self.findStatic(allocator, reached, pointer.root, pointer.root_type));
        }
        var current = pointer.root_type;
        for (pointer.path) |position| {
            switch (current) {
                .array => |array| {
                    try writer.print(".items[{d}]", .{position});
                    current = array.element;
                },
                .tuple => |tuple| {
                    try writer.print("._{d}", .{position});
                    current = tuple.elements[position];
                },
                .@"struct" => |struct_type| {
                    try writer.print(".{s}", .{struct_type.fields[position].name});
                    current = struct_type.fields[position].type;
                },
                .number, .boolean, .void, .type, .@"enum", .slice, .pointer, .optional, .result, .function, .variable, .application => unreachable,
            }
        }
    }

    fn findConstantCell(self: *const Generator, root: *const Value) ?ast.Resolution.Constant {
        for (self.program.modules, 0..) |module, module_index| {
            for (module.declarations, 0..) |declaration, index| {
                if (declaration.kind != .constant_declaration) continue;
                const known = declaration.kind.constant_declaration.known orelse continue;
                if (known == root) return .{ .module = module_index, .declaration = index };
            }
        }
        return null;
    }

    fn findStatic(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        root: *const Value,
        root_type: types.Type,
    ) WriteError![]const u8 {
        for (self.statics.items) |static| {
            if (static.root == root) return static.name;
        }
        const name = try std.fmt.allocPrint(allocator, "mn_static_{d}", .{self.statics.items.len + 1});
        const position = self.statics.items.len;
        try self.statics.append(allocator, .{ .root = root, .root_type = root_type, .name = name, .definition = "" });
        var definition: std.Io.Writer.Allocating = .init(allocator);
        try self.generateKnownValue(allocator, reached, &definition.writer, root.*, root_type, .initializer);
        self.statics.items[position].definition = definition.written();
        return name;
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
            .function_definition, .constant_declaration, .struct_definition, .enum_definition => {},
            .typeclass_definition, .instance_declaration, .import => {},
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
            .array, .optional, .result, .tuple => {},
            .@"enum" => |enumeration| if (types.isDeclaredEnum(enumeration)) return,
            .function => |function| {
                for (function.parameters) |parameter| try self.recordType(allocator, reached, parameter);
                return self.recordType(allocator, reached, function.return_type);
            },
            .pointer => |pointer| {
                if (pointer.target == .function) return self.recordType(allocator, reached, pointer.target);
                return;
            },
            .number, .boolean, .void, .type, .@"struct", .slice, .variable, .application => return,
        }
        if (isPointerOptional(value_type)) return self.recordType(allocator, reached, value_type.optional.child);
        if (isZeroSized(value_type)) return;
        if (containsType(reached.definitions.items, value_type)) return;
        switch (value_type) {
            .array => |array| try self.recordType(allocator, reached, array.element),
            .optional => |optional| try self.recordType(allocator, reached, optional.child),
            .result => |result| {
                try self.recordType(allocator, reached, .{ .@"enum" = result.error_set });
                try self.recordType(allocator, reached, result.value);
            },
            .tuple => |tuple| {
                for (tuple.elements) |element| try self.recordType(allocator, reached, element);
            },
            .@"enum" => |enumeration| {
                for (enumeration.cases) |case| try self.recordType(allocator, reached, case.type orelse continue);
            },
            .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .function, .variable, .application => {
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
        self.loops = try collectLoops(allocator, function.body);
        self.tuple_declarations = try collectKind(allocator, function.body, .tuple_declaration);
        self.matches = try collectKind(allocator, function.body, .match);
        self.parameters = function.signature.parameters;
        self.return_type = ast.extractType(function.signature.return_type);
        const kind: ast.DeclarationKind = .{ .function_definition = function };
        self.in_main = self.isEntryPoint(kind) and !isResultMain(kind);
        try self.generateSignature(writer, kind, index);
        try writer.writeByte(' ');
        if (needsFinalReturn(self.return_type, function.body)) {
            try writer.writeAll("{\n");
            self.depth += 1;
            try self.generateStatements(allocator, reached, writer, function.body, null);
            try self.generateSuccessReturn(allocator, reached, writer);
            self.depth -= 1;
            try writer.writeByte('}');
        } else {
            try self.generateBlock(allocator, reached, writer, function.body, null);
        }
        try writer.writeByte('\n');
        if (self.isEntryPoint(kind) and isResultMain(kind)) try self.generateEntryPoint(allocator, writer, index);
    }

    fn generateDeferredReturn(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        returned: *const ast.Expression,
    ) WriteError!void {
        const name = "mn_returned";
        try self.recordType(allocator, reached, self.return_type);
        try self.generateIndentation(writer);
        try self.generateLocalType(writer, self.return_type, true);
        try writer.print(" {s} = ", .{name});
        try self.generateFullValue(allocator, reached, writer, returned, self.return_type);
        try writer.writeAll(";\n");
        const errors: Errors = if (self.return_type != .result)
            .none
        else if (returned.type.? == .result)
            .{ .dynamic = name }
        else if (types.isResultError(returned.type.?, self.return_type.result.*))
            .all
        else
            .none;
        try self.generateUnwound(allocator, reached, writer, null, errors);
        try self.generateIndentation(writer);
        try writer.print("return {s};\n", .{name});
    }

    fn generateSuccessReturn(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
    ) WriteError!void {
        try self.recordType(allocator, reached, self.return_type);
        try self.generateIndentation(writer);
        try writer.writeAll("return ");
        try self.generateCompoundStart(writer, self.return_type, .expression);
        try writer.writeAll(".error.tag = 0 };\n");
    }

    fn generateEntryPoint(
        self: *Generator,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        index: usize,
    ) WriteError!void {
        const name = "mn_runtime_error_report";
        if (!containsName(self.runtime_functions.items, name)) try self.runtime_functions.append(allocator, name);
        try writer.writeAll("\nint main() {\n    ");
        try self.generateType(writer, self.return_type);
        try writer.print(" result = {s}();\n    if (result.error.tag == 0) return 0;\n    switch (result.error.tag) {{\n", .{self.names[self.module_index][index].?});
        for (self.return_type.result.error_set.cases) |case| {
            try writer.print("    case {d}: {s}(\"{s}\"); break;\n", .{ case.tag, name, case.name });
        }
        try writer.writeAll("    }\n    return 1;\n}\n");
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
            const start = steps.items.len;
            try self.collectStatementSteps(allocator, &steps, statement);
            try liftSteps(allocator, steps.items[start..]);
        }
        return steps.items;
    }

    fn collectStatementSteps(
        self: *const Generator,
        allocator: std.mem.Allocator,
        steps: *std.ArrayList(Step),
        statement: *const ast.Statement,
    ) std.mem.Allocator.Error!void {
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
            try collectTargetSteps(allocator, steps, statement, written, address);
        }
        if (statement.kind == .@"for" and statement.kind.@"for".iterator != null) {
            try collectScopeSteps(allocator, steps, statement, &statement.kind.@"for".sequence.value);
        } else if (statement.kind == .@"for") {
            for (try collectParts(allocator, &statement.kind.@"for")) |part| {
                if (!self.isStoredPart(statement, part) and !hasEffects(part.expression.*)) continue;
                try collectScopeSteps(allocator, steps, statement, part.expression);
            }
        }
        const expression = findStatementExpression(statement) orelse return;
        try collectScopeSteps(allocator, steps, statement, expression);
    }

    fn generateSignature(
        self: *Generator,
        writer: *std.Io.Writer,
        kind: ast.DeclarationKind,
        index: usize,
    ) WriteError!void {
        if (self.isEntryPoint(kind) and !isResultMain(kind)) return writer.writeAll("int main()");
        const signature = switch (kind) {
            .function_definition => |function| function.signature,
            .function_declaration => |function_declaration| function_declaration,
            .constant_declaration, .struct_definition, .enum_definition => unreachable,
            .typeclass_definition, .instance_declaration, .import => unreachable,
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
        const chosen = hasChosenBlock(body);
        for (parameters, 0..) |parameter, index| {
            const parameter_type = ast.extractType(parameter.type);
            if (isZeroSized(parameter_type)) continue;
            if (written) try writer.writeAll(", ");
            const named = !isDiscardedParameter(body, parameters, index);
            if (named and chosen) try writer.writeAll("[[maybe_unused]] ");
            try self.generateType(writer, parameter_type);
            if (named) try writer.print(" {s}", .{parameter.name});
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
        loop: ?*const ast.Statement,
    ) WriteError!void {
        const named = if (loop) |statement| self.declaresElements(statement) else false;
        const empty = !named and for (block) |*statement| {
            if (self.hasOutput(statement)) break false;
        } else true;
        if (empty) return writer.writeAll("{}");

        try writer.writeAll("{\n");
        self.depth += 1;
        if (named) try self.generateElementDeclarations(allocator, reached, writer, loop.?);
        try self.generateStatements(allocator, reached, writer, block, loop);
        if (loop) |statement| {
            if (containsGoto(block, statement, .@"continue", statement)) {
                try self.generateIndentation(writer);
                try writer.print("mn_continue_{d}:;\n", .{self.findLoopNumber(statement)});
            }
        }
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeByte('}');
    }

    fn generateStatements(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        block: []const ast.Statement,
        loop: ?*const ast.Statement,
    ) WriteError!void {
        try self.frames.append(allocator, .{ .loop = loop });
        const frame = self.frames.items.len - 1;
        for (block) |*statement| {
            if (statement.kind == .@"defer") {
                try self.frames.items[frame].deferred.append(allocator, statement.kind.@"defer");
                continue;
            }
            try self.generateStatement(allocator, reached, writer, statement);
        }
        if (!endsWithJump(block)) try self.generateFrameDeferred(allocator, reached, writer, frame, .none);
        _ = self.frames.pop();
    }

    fn generateFrameDeferred(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        frame: usize,
        errors: Errors,
    ) WriteError!void {
        const deferred = self.frames.items[frame].deferred.items;
        var index = deferred.len;
        while (index > 0) {
            index -= 1;
            const statement = deferred[index].statement;
            if (deferred[index].on_error) {
                switch (errors) {
                    .none => continue,
                    .all => {},
                    .dynamic => |name| {
                        try self.generateIndentation(writer);
                        try writer.print("if ({s}.error.tag != 0) {{\n", .{name});
                        self.depth += 1;
                        try self.generateDeferredStatement(allocator, reached, writer, statement);
                        self.depth -= 1;
                        try self.generateIndentation(writer);
                        try writer.writeAll("}\n");
                        continue;
                    },
                }
            }
            try self.generateDeferredStatement(allocator, reached, writer, statement);
        }
    }

    fn generateDeferredStatement(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        if (!self.hasTemporaries(statement)) return self.generateStatement(allocator, reached, writer, statement);
        try self.generateIndentation(writer);
        try writer.writeAll("{\n");
        self.depth += 1;
        try self.generateStatement(allocator, reached, writer, statement);
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeAll("}\n");
    }

    fn generateUnwound(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        loop: ?*const ast.Statement,
        errors: Errors,
    ) WriteError!void {
        var frame = self.frames.items.len;
        while (frame > 0) {
            frame -= 1;
            try self.generateFrameDeferred(allocator, reached, writer, frame, errors);
            if (loop != null and self.frames.items[frame].loop == loop) return;
        }
    }

    fn hasDeferred(self: *const Generator) bool {
        for (self.frames.items) |frame| {
            if (frame.deferred.items.len > 0) return true;
        }
        return false;
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
        if (statement.kind != .@"while") try self.generateLiftedSteps(allocator, reached, writer, statement);
        switch (statement.kind) {
            .noop => unreachable,
            .@"return" => {
                const returned = findStatementExpression(statement) orelse {
                    try self.generateUnwound(allocator, reached, writer, null, .none);
                    if (self.return_type == .result) return self.generateSuccessReturn(allocator, reached, writer);
                    try self.generateIndentation(writer);
                    return writer.writeAll(if (self.in_main) "return 0;\n" else "return;\n");
                };
                if (isZeroSized(returned.type.?) and isZeroSized(self.return_type)) {
                    if (hasEffects(returned.*)) {
                        try self.generateIndentation(writer);
                        try self.generateStatementEffects(allocator, reached, writer, returned);
                        try writer.writeAll(";\n");
                    }
                    try self.generateUnwound(allocator, reached, writer, null, .none);
                    try self.generateIndentation(writer);
                    return writer.writeAll("return;\n");
                }
                if (self.hasDeferred()) return self.generateDeferredReturn(allocator, reached, writer, returned);
                try self.generateIndentation(writer);
                try writer.writeAll("return ");
                try self.generateFullValue(allocator, reached, writer, returned, self.return_type);
                try writer.writeAll(";\n");
            },
            .discard, .call => |*expression| {
                if (self.isLiftedRoot(expression)) return;
                try self.generateExpressionStatement(allocator, reached, writer, expression);
            },
            .constant_declaration, .variable_declaration => {
                try self.generateLocal(allocator, reached, writer, statement);
            },
            .tuple_declaration => try self.generateTupleDeclaration(allocator, reached, writer, statement),
            .assignment => |*assignment| try self.generateAssignment(allocator, reached, writer, assignment),
            .@"if" => |*conditional| {
                try self.generateIndentation(writer);
                try self.generateIf(allocator, reached, writer, conditional);
                try writer.writeByte('\n');
            },
            .@"while" => try self.generateWhile(allocator, reached, writer, statement),
            .@"for" => try self.generateFor(allocator, reached, writer, statement),
            .match => try self.generateMatch(allocator, reached, writer, statement),
            .@"break" => |jump| try self.generateJump(allocator, reached, writer, jump.loop.?, .@"break"),
            .@"continue" => |jump| try self.generateJump(allocator, reached, writer, jump.loop.?, .@"continue"),
            .@"defer" => unreachable,
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
                const named = self.findLocalName(.{ .local = statement }) != null;
                const value = findStatementExpression(statement) orelse return named;
                return named or hasEffects(value.*);
            },
            .tuple_declaration => |declaration| {
                return self.declaresElements(statement) or hasEffects(declaration.value);
            },
            .assignment => |assignment| {
                if (self.hasTarget(assignment.target)) return true;
                return hasEffects(assignment.target) or hasEffects(assignment.value);
            },
            .discard => |expression| expression.kind != .identifier,
            .@"defer" => |deferred| self.hasOutput(deferred.statement),
            .@"return", .call, .@"if", .@"while", .@"for", .match, .@"break", .@"continue" => true,
        };
    }

    fn hasTemporaries(self: *const Generator, statement: *const ast.Statement) bool {
        for (self.steps) |step| {
            if (step.statement == statement and step.temporary != null) return true;
        }
        return false;
    }

    fn hasTarget(self: *const Generator, target: ast.Expression) bool {
        if (isZeroSized(target.type.?)) return false;
        const root = findTargetRoot(target) orelse return true;
        return self.findLocalName(.{ .local = root }) != null;
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
        const name = self.findLocalName(.{ .local = statement }) orelse {
            try self.generateStatementEffects(allocator, reached, writer, value);
            return writer.writeAll(";\n");
        };
        const local_type = findLocalType(statement.*);
        try self.recordType(allocator, reached, local_type);
        try self.generateLocalType(writer, local_type, statement.kind == .constant_declaration);
        try writer.print(" {s}", .{name});
        if (value.kind != .undefined) {
            try writer.writeAll(" = ");
            try self.generateFullValue(allocator, reached, writer, value, local_type);
        }
        try writer.writeAll(";\n");
    }

    fn generateTupleDeclaration(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const declaration = &statement.kind.tuple_declaration;
        const value = &declaration.value;
        const stored = !isPlainName(value.*) and self.readsElements(statement);
        if (!stored and hasEffects(value.*)) {
            try self.generateIndentation(writer);
            try self.generateStatementEffects(allocator, reached, writer, value);
            try writer.writeAll(";\n");
        }
        const addressed = self.addressesElements(statement);
        const value_type = value.type.?;
        try self.recordType(allocator, reached, value_type);
        if (stored) {
            try self.generateIndentation(writer);
            if (addressed) {
                try self.generateTaggedType(writer, value_type);
                const writable = hasWritablePointerName(declaration.names);
                try writer.writeAll(if (writable) " * const " else " const * const ");
                try self.generateTupleValueName(writer, statement);
                try writer.writeAll(" = ");
                try self.generateAddress(allocator, reached, writer, value);
            } else {
                try self.generateLocalType(writer, value_type, true);
                try writer.writeByte(' ');
                try self.generateTupleValueName(writer, statement);
                try writer.writeAll(" = ");
                try self.generateFullValue(allocator, reached, writer, value, value_type);
            }
            try writer.writeAll(";\n");
        }
        for (declaration.names, 0..) |name, position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            const local_name = self.findLocalName(.{ .element = element }) orelse continue;
            try self.generateElementName(allocator, reached, writer, name, local_name);
            if (!isZeroSizedPointer(name)) {
                if (name.pointer) try writer.writeByte('&');
                if (stored) {
                    try self.generateTupleValueName(writer, statement);
                    try writer.print("{s}_{d}", .{ if (addressed) "->" else ".", position });
                } else {
                    try self.generateExpression(allocator, reached, writer, value.*);
                    try writer.print("._{d}", .{position});
                }
            }
            try writer.writeAll(";\n");
        }
    }

    fn generateMatch(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const matching = &statement.kind.match;
        const value = &matching.value;
        const value_type = value.type.?;
        try self.recordType(allocator, reached, value_type);
        const stored = !isPlainName(value.*) and self.readsElements(statement);
        const addressed = self.addressesElements(statement);
        if (stored) {
            try self.generateIndentation(writer);
            if (addressed) {
                try self.generateTaggedType(writer, value_type);
                const writable = hasWritablePointerName(matching.names);
                try writer.writeAll(if (writable) " * const " else " const * const ");
                try self.generateMatchValueName(writer, statement);
                try writer.writeAll(" = ");
                try self.generateAddress(allocator, reached, writer, value);
            } else {
                try self.generateLocalType(writer, value_type, true);
                try writer.writeByte(' ');
                try self.generateMatchValueName(writer, statement);
                try writer.writeAll(" = ");
                try self.generateFullValue(allocator, reached, writer, value, value_type);
            }
            try writer.writeAll(";\n");
        }
        try self.generateIndentation(writer);
        try writer.writeAll("switch (");
        if (stored) {
            try self.generateMatchValueName(writer, statement);
            try writer.writeAll(if (addressed) "->tag" else ".tag");
        } else {
            try self.generateFullExpression(allocator, reached, writer, value);
            try writer.writeAll(".tag");
        }
        try writer.writeAll(") {\n");
        const enclosing_loop = self.innermost_loop;
        self.innermost_loop = null;
        for (0..matching.branches.len) |position| {
            try self.generateBranch(allocator, reached, writer, statement, position, stored, addressed);
        }
        self.innermost_loop = enclosing_loop;
        try self.generateIndentation(writer);
        try writer.writeAll("}\n");
    }

    fn generateBranch(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
        position: usize,
        stored: bool,
        addressed: bool,
    ) WriteError!void {
        const matching = &statement.kind.match;
        const branch = matching.branches[position];
        const enumeration = matching.value.type.?.@"enum";
        const last = position + 1 == matching.branches.len;
        const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
        const local_name = self.findLocalName(.{ .element = element });
        const empty = local_name == null and for (branch.body) |*inner| {
            if (self.hasOutput(inner)) break false;
        } else true;
        if (last) {
            try self.generateIndentation(writer);
            try writer.writeAll("default: ");
        } else {
            for (branch.cases, 0..) |case, index| {
                if (index > 0) try writer.writeByte('\n');
                try self.generateIndentation(writer);
                try writer.print("case {d}:", .{enumeration.cases[case.index.?].tag});
            }
            try writer.writeByte(' ');
        }
        if (empty) return writer.writeAll("break;\n");
        try writer.writeAll("{\n");
        self.depth += 1;
        if (local_name) |declared_name| {
            const name = matching.names[position];
            try self.generateElementName(allocator, reached, writer, name, declared_name);
            if (!isZeroSizedPointer(name)) {
                if (name.pointer) try writer.writeByte('&');
                if (stored) {
                    try self.generateMatchValueName(writer, statement);
                    try writer.writeAll(if (addressed) "->value." else ".value.");
                } else {
                    try self.generateExpression(allocator, reached, writer, matching.value);
                    try writer.writeAll(".value.");
                }
                try self.generateCaseMember(writer, enumeration, enumeration.cases[branch.cases[0].index.?]);
            }
            try writer.writeAll(";\n");
        }
        try self.generateStatements(allocator, reached, writer, branch.body, null);
        if (!last and !endsWithJump(branch.body)) {
            try self.generateIndentation(writer);
            try writer.writeAll("break;\n");
        }
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeAll("}\n");
    }

    fn generateMatchValueName(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const number = std.mem.findScalar(*const ast.Statement, self.matches, statement).? + 1;
        try writer.print("mn_match_value_{d}", .{number});
    }

    fn readsElements(self: *const Generator, statement: *const ast.Statement) bool {
        for (ast.extractElementNames(statement.*), 0..) |name, position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            if (self.findLocalName(.{ .element = element }) == null) continue;
            if (!isZeroSizedPointer(name)) return true;
        }
        return false;
    }

    fn addressesElements(self: *const Generator, statement: *const ast.Statement) bool {
        for (ast.extractElementNames(statement.*), 0..) |name, position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            if (self.findLocalName(.{ .element = element }) == null) continue;
            if (name.pointer and !isZeroSizedPointer(name)) return true;
        }
        return false;
    }

    fn generateTupleValueName(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const number = std.mem.findScalar(*const ast.Statement, self.tuple_declarations, statement).? + 1;
        try writer.print("mn_tuple_value_{d}", .{number});
    }

    fn generateElementName(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        name: ast.ElementName,
        local_name: []const u8,
    ) WriteError!void {
        const name_type = name.type.?;
        try self.recordType(allocator, reached, name_type);
        try self.generateIndentation(writer);
        try self.generateLocalType(writer, name_type, true);
        try writer.print(" {s} = ", .{local_name});
        if (!isZeroSizedPointer(name)) return;
        try writer.writeAll("((");
        try self.generateType(writer, name_type);
        try writer.writeAll(")&mn_zero_sized)");
    }

    fn generateLocalType(
        self: *Generator,
        writer: *std.Io.Writer,
        local_type: types.Type,
        constant: bool,
    ) WriteError!void {
        const pointer = local_type == .pointer or isPointerOptional(local_type);
        if (constant and !pointer) try writer.writeAll("const ");
        try self.generateType(writer, local_type);
        if (constant and pointer) try writer.writeAll(" const");
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

    fn generateIf(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        conditional: *const ast.If,
    ) WriteError!void {
        if (conditional.known) |chosen| {
            const block = if (chosen) conditional.body else conditional.else_body orelse &.{};
            return self.generateBlock(allocator, reached, writer, block, null);
        }
        try writer.writeAll("if (");
        try self.generateFullExpression(allocator, reached, writer, &conditional.condition);
        try writer.writeAll(") ");
        try self.generateBlock(allocator, reached, writer, conditional.body, null);
        const else_body = conditional.else_body orelse return;
        try writer.writeAll(" else ");
        const chained = else_body.len == 1 and else_body[0].kind == .@"if";
        if (chained and !self.hasTemporaries(&else_body[0]) and !self.isLiftedStatement(&else_body[0])) {
            return self.generateIf(allocator, reached, writer, &else_body[0].kind.@"if");
        }
        try self.generateBlock(allocator, reached, writer, else_body, null);
    }

    fn generateWhile(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const loop = &statement.kind.@"while";
        try self.generateIndentation(writer);
        if (self.isLiftedStatement(statement)) {
            try writer.writeAll("while (true) {\n");
            self.depth += 1;
            try self.generateLiftedSteps(allocator, reached, writer, statement);
            try self.generateIndentation(writer);
            try writer.writeAll("if (!");
            try self.generateFullExpression(allocator, reached, writer, &loop.condition);
            try writer.writeAll(") break;\n");
            try self.generateIndentation(writer);
            try self.generateLoopBody(allocator, reached, writer, statement);
            self.depth -= 1;
            try self.generateIndentation(writer);
            try writer.writeAll("}\n");
            return self.generateLoopEnd(allocator, reached, writer, statement);
        }
        try writer.writeAll("while (");
        try self.generateFullExpression(allocator, reached, writer, &loop.condition);
        try writer.writeAll(") ");
        try self.generateLoopBody(allocator, reached, writer, statement);
        try self.generateLoopEnd(allocator, reached, writer, statement);
    }

    fn isLiftedStatement(self: *const Generator, statement: *const ast.Statement) bool {
        for (self.steps) |step| {
            if (step.statement == statement and step.lifted) return true;
        }
        return false;
    }

    fn generateFor(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        if (statement.kind.@"for".iterator != null) return self.generateIteration(allocator, reached, writer, statement);
        if (ast.isUnrolled(statement.kind.@"for")) return self.generateUnrolled(allocator, reached, writer, statement);
        for (try collectParts(allocator, &statement.kind.@"for")) |part| {
            try self.generatePart(allocator, reached, writer, statement, part);
        }
        if (!isEmptyLoop(statement.*)) {
            const number = self.findLoopNumber(statement);
            try self.generateIndentation(writer);
            try writer.print("for (size_t mn_index_{d} = 0; ", .{number});
            if (hasLength(statement.kind.@"for")) {
                try writer.print("mn_index_{d} < ", .{number});
                try self.generateLength(allocator, reached, writer, statement);
            }
            try writer.print("; mn_index_{d} += 1) ", .{number});
            try self.generateLoopBody(allocator, reached, writer, statement);
        }
        try self.generateLoopEnd(allocator, reached, writer, statement);
    }

    fn generateUnrolled(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const loop = &statement.kind.@"for";
        const number = self.findLoopNumber(statement);
        if (loop.expansion_value) |value| try self.generateStatement(allocator, reached, writer, value);
        const enclosing_loop = self.innermost_loop;
        self.innermost_loop = statement;
        var broken = false;
        for (loop.expansions, 0..) |expansion, position| {
            try self.unrolled.append(allocator, .{ .loop = statement, .expansion = position });
            try self.generateIndentation(writer);
            try writer.writeAll("{\n");
            self.depth += 1;
            try self.generateStatements(allocator, reached, writer, expansion, statement);
            self.depth -= 1;
            try self.generateIndentation(writer);
            try writer.writeAll("}\n");
            _ = self.unrolled.pop();
            if (containsGoto(expansion, statement, .@"continue", statement)) {
                try self.generateIndentation(writer);
                try writer.print("mn_continue_{d}_{d}:;\n", .{ number, position });
            }
            if (containsGoto(expansion, statement, .@"break", statement)) broken = true;
        }
        self.innermost_loop = enclosing_loop;
        try self.generateStatements(allocator, reached, writer, loop.else_body orelse &.{}, null);
        if (!broken) return;
        try self.generateIndentation(writer);
        try writer.print("mn_break_{d}:;\n", .{number});
    }

    fn generateIteration(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const loop = &statement.kind.@"for";
        const iteration = loop.iterator.?;
        const number = self.findLoopNumber(statement);
        const sequence = &loop.sequence.value;
        const sequence_type = sequence.type.?;
        const optional_type: types.Type = .{ .optional = try self.program.types.addOptional(allocator, iteration.element) };
        try self.recordType(allocator, reached, sequence_type);
        try self.recordType(allocator, reached, optional_type);
        try self.generateIndentation(writer);
        try self.generateType(writer, sequence_type);
        try writer.print(" mn_iterator_{d} = ", .{number});
        try self.generateFullValue(allocator, reached, writer, sequence, sequence_type);
        try writer.writeAll(";\n");
        try self.generateIndentation(writer);
        try writer.writeAll("for (;;) {\n");
        self.depth += 1;
        try self.generateIndentation(writer);
        try self.generateType(writer, optional_type);
        try writer.print(" mn_element_{d} = ", .{number});
        try self.generateFunctionName(allocator, reached, writer, iteration.next);
        try writer.print("(&mn_iterator_{d});\n", .{number});
        try self.generateIndentation(writer);
        try writer.print("if (!mn_element_{d}.present) break;\n", .{number});
        try self.generateIndentation(writer);
        try self.generateLoopBody(allocator, reached, writer, statement);
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeAll("}\n");
        try self.generateLoopEnd(allocator, reached, writer, statement);
    }

    fn generatePart(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
        part: Part,
    ) WriteError!void {
        const expression = part.expression;
        if (!self.isStoredPart(statement, part)) {
            if (!hasEffects(expression.*)) return;
            try self.generateIndentation(writer);
            try self.generateStatementEffects(allocator, reached, writer, expression);
            return writer.writeAll(";\n");
        }
        const part_type = expression.type.?;
        try self.recordType(allocator, reached, part_type);
        try self.generateIndentation(writer);
        if (isAddressedPart(part)) {
            try self.generateTaggedType(writer, part_type);
            const writable = hasWritablePointerName(statement.kind.@"for".names);
            try writer.writeAll(if (writable) " * const " else " const * const ");
            try self.generatePartName(writer, statement, part);
            try writer.writeAll(" = ");
            try self.generateAddress(allocator, reached, writer, expression);
            return writer.writeAll(";\n");
        }
        try self.generateLocalType(writer, part_type, true);
        try writer.writeByte(' ');
        try self.generatePartName(writer, statement, part);
        try writer.writeAll(" = ");
        try self.generateFullValue(allocator, reached, writer, expression, part_type);
        try writer.writeAll(";\n");
    }

    fn generateAddress(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        place: *const ast.Expression,
    ) WriteError!void {
        const sequenced = self.sequenced;
        defer self.sequenced = sequenced;
        self.sequenced = self.hasSteps(place);
        if (!self.sequenced) {
            try writer.writeByte('&');
            return self.generateExpression(allocator, reached, writer, place.*);
        }
        try writer.writeByte('(');
        try self.generateSteps(allocator, reached, writer, place);
        try writer.writeAll(", &");
        try self.generateExpression(allocator, reached, writer, place.*);
        try writer.writeByte(')');
    }

    fn isStoredPart(self: *const Generator, statement: *const ast.Statement, part: Part) bool {
        if (isDirect(part.expression.*) or isEmptyLoop(statement.*)) return false;
        const measured = hasLength(statement.kind.@"for");
        const named = self.declaresElements(statement);
        return switch (part.role) {
            .sequence => named or (measured and part.expression.type.? == .slice),
            .start => named or measured,
            .end => measured,
        };
    }

    fn generatePartName(
        self: *Generator,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
        part: Part,
    ) WriteError!void {
        try writer.print("mn_{t}_{d}", .{ part.role, self.findLoopNumber(statement) });
    }

    fn generatePartValue(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
        part: Part,
    ) WriteError!void {
        if (isDirect(part.expression.*)) return self.generateExpression(allocator, reached, writer, part.expression.*);
        try self.generatePartName(writer, statement, part);
    }

    fn generateLength(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        switch (statement.kind.@"for".sequence) {
            .value => |*value| switch (followPointer(value.type.?)) {
                .array => |array| try writer.print("{d}", .{array.length}),
                .slice => {
                    const part: Part = .{ .expression = value, .role = .sequence };
                    try self.generatePartValue(allocator, reached, writer, statement, part);
                    try writer.writeAll(".length");
                },
                .number, .boolean, .void, .type, .@"struct", .@"enum", .pointer, .optional, .result, .tuple, .function, .variable, .application => {
                    unreachable;
                },
            },
            .range => |*range| {
                const end: Part = .{ .expression = &range.end.?, .role = .end };
                try self.generatePartValue(allocator, reached, writer, statement, end);
                if (isZeroLiteral(range.start)) return;
                try writer.writeAll(" - ");
                const start: Part = .{ .expression = &range.start, .role = .start };
                try self.generatePartValue(allocator, reached, writer, statement, start);
            },
        }
    }

    fn declaresElements(self: *const Generator, statement: *const ast.Statement) bool {
        if (statement.kind != .@"for" and statement.kind != .tuple_declaration) return false;
        for (0..ast.extractElementNames(statement.*).len) |position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            if (self.findLocalName(.{ .element = element }) != null) return true;
        }
        return false;
    }

    fn generateElementDeclarations(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const loop = &statement.kind.@"for";
        if (loop.iterator != null) return self.generateIterationNames(allocator, reached, writer, statement);
        try self.recordType(allocator, reached, ast.extractElementType(loop.sequence));
        for (loop.names, 0..) |name, position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            const local_name = self.findLocalName(.{ .element = element }) orelse continue;
            try self.generateElementName(allocator, reached, writer, name, local_name);
            if (!isZeroSizedPointer(name)) {
                if (name.pointer) try writer.writeByte('&');
                try self.generateElement(allocator, reached, writer, statement);
                if (loop.tuple) try writer.print("._{d}", .{position});
            }
            try writer.writeAll(";\n");
        }
    }

    fn generateIterationNames(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const loop = &statement.kind.@"for";
        const number = self.findLoopNumber(statement);
        for (loop.names, 0..) |name, position| {
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            const local_name = self.findLocalName(.{ .element = element }) orelse continue;
            try self.generateElementName(allocator, reached, writer, name, local_name);
            try writer.print("mn_element_{d}.value._{d};\n", .{ number, position });
        }
    }

    fn generateElement(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const sequence = &statement.kind.@"for".sequence;
        const number = self.findLoopNumber(statement);
        switch (sequence.*) {
            .value => |*value| {
                const part: Part = .{ .expression = value, .role = .sequence };
                try self.recordPointerTarget(allocator, reached, value.type.?);
                try self.generatePartValue(allocator, reached, writer, statement, part);
                const pointed = value.type.? == .pointer or isAddressedPart(part);
                try writer.writeAll(if (pointed) "->items[" else ".items[");
                try writer.print("mn_index_{d}]", .{number});
            },
            .range => |*range| {
                if (!isZeroLiteral(range.start)) {
                    const part: Part = .{ .expression = &range.start, .role = .start };
                    try self.generatePartValue(allocator, reached, writer, statement, part);
                    try writer.writeAll(" + ");
                }
                try writer.print("mn_index_{d}", .{number});
            },
        }
    }

    fn generateLoopBody(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const enclosing_loop = self.innermost_loop;
        self.innermost_loop = statement;
        try self.generateBlock(allocator, reached, writer, ast.extractBlocks(statement.*)[0], statement);
        self.innermost_loop = enclosing_loop;
        try writer.writeByte('\n');
    }

    fn generateLoopEnd(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        const body, const else_body = ast.extractBlocks(statement.*);
        try self.generateStatements(allocator, reached, writer, else_body, null);
        if (isEmptyLoop(statement.*) or !containsGoto(body, statement, .@"break", statement)) return;
        try self.generateIndentation(writer);
        try writer.print("mn_break_{d}:;\n", .{self.findLoopNumber(statement)});
    }

    fn generateJump(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        loop: *const ast.Statement,
        tag: std.meta.Tag(ast.StatementKind),
    ) WriteError!void {
        try self.generateUnwound(allocator, reached, writer, loop, .none);
        try self.generateIndentation(writer);
        const name = @tagName(tag);
        if (!isGoto(loop, tag, self.innermost_loop)) return writer.print("{s};\n", .{name});
        try writer.print("goto mn_{s}_{d}", .{ name, self.findLoopNumber(loop) });
        if (tag == .@"continue" and isUnrolledLoop(loop)) {
            for (self.unrolled.items) |unrolled| {
                if (unrolled.loop == loop) try writer.print("_{d}", .{unrolled.expansion});
            }
        }
        try writer.writeAll(";\n");
    }

    fn findLoopNumber(self: *const Generator, loop: *const ast.Statement) usize {
        return std.mem.findScalar(*const ast.Statement, self.loops, loop).? + 1;
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
        if (isOptionalWrap(expression.type.?, expected)) return self.generateWrapped(allocator, reached, writer, expression, expected, false);
        if (isResultWrap(expression.type.?, expected)) return self.generateResultWrapped(allocator, reached, writer, expression, expected);
        if (isConversionCall(expression.type.?, expected)) return self.generateEnumConverted(allocator, reached, writer, expression, expected);
        if (!isArrayToSlice(expression.type.?, expected)) return self.generateOperand(allocator, reached, writer, expression);
        try self.generateSliceOf(allocator, reached, writer, expression, null, null, expected, .expression);
    }

    fn generateResultWrapped(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
    ) WriteError!void {
        const result = expected.result;
        try self.recordType(allocator, reached, expected);
        if (types.isResultError(expression.type.?, result.*)) {
            try self.generateCompoundStart(writer, expected, .expression);
            try writer.writeAll(".error = ");
            try self.generateConverted(allocator, reached, writer, expression, .{ .@"enum" = result.error_set });
            return writer.writeAll(" }");
        }
        if (!isZeroSized(result.value)) {
            try self.generateCompoundStart(writer, expected, .expression);
            try writer.writeAll(".error.tag = 0, .value = ");
            try self.generateConverted(allocator, reached, writer, expression, result.value);
            return writer.writeAll(" }");
        }
        const effects = hasEffects(expression.*);
        if (effects) {
            try writer.writeAll("((void)(");
            try self.generateStatementEffects(allocator, reached, writer, expression);
            try writer.writeAll("), ");
        }
        try self.generateCompoundStart(writer, expected, .expression);
        try writer.writeAll(".error.tag = 0 }");
        if (effects) try writer.writeByte(')');
    }

    fn generateLiftedSteps(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        statement: *const ast.Statement,
    ) WriteError!void {
        for (self.steps) |*step| {
            if (step.statement != statement or !step.lifted or step.lazy) continue;
            try self.generateLiftedStep(allocator, reached, writer, step);
        }
    }

    fn generateLiftedScope(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        scope: *const ast.Expression,
    ) WriteError!void {
        for (self.steps) |*step| {
            if (step.scope != scope or !step.lifted) continue;
            try self.generateLiftedStep(allocator, reached, writer, step);
        }
    }

    fn generateLiftedStep(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        step: *const Step,
    ) WriteError!void {
        const expression = step.expression;
        if (step.address == null and expression.kind == .@"try") return self.generateLiftedTry(allocator, reached, writer, step);
        if (step.address == null and self.isLiftedShortCircuit(expression)) {
            return self.generateLiftedShortCircuit(allocator, reached, writer, step);
        }
        if (step.temporary == null and !isUnit(expression.*)) return;
        try self.generateIndentation(writer);
        if (step.temporary) |number| try writer.print("mn_temporary_{d} = ", .{number});
        if (step.address != null) {
            try writer.writeByte('&');
        } else if (self.findAddressTemporary(expression)) |number| {
            return writer.print("(*mn_temporary_{d});\n", .{number});
        }
        try self.generateExpression(allocator, reached, writer, expression.*);
        try writer.writeAll(";\n");
    }

    fn generateLiftedTry(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        step: *const Step,
    ) WriteError!void {
        const operand = step.expression.kind.@"try";
        const result_type = operand.type.?;
        try self.recordType(allocator, reached, result_type);
        try self.recordType(allocator, reached, self.return_type);
        const deferred = self.hasDeferred();
        try self.generateIndentation(writer);
        try writer.writeAll("if (");
        try self.generateOperand(allocator, reached, writer, operand);
        try writer.writeAll(".error.tag != 0) ");
        if (deferred) {
            try writer.writeAll("{\n");
            self.depth += 1;
            try self.generateUnwound(allocator, reached, writer, null, .all);
            try self.generateIndentation(writer);
        }
        try writer.writeAll("return ");
        try self.generateCompoundStart(writer, self.return_type, .expression);
        try writer.writeAll(".error = ");
        const source: types.Type = .{ .@"enum" = result_type.result.error_set };
        const target: types.Type = .{ .@"enum" = self.return_type.result.error_set };
        if (source.@"enum" == target.@"enum") {
            try self.generateOperand(allocator, reached, writer, operand);
            try writer.writeAll(".error");
        } else {
            try self.recordConversion(allocator, reached, .{ .source = source, .target = target });
            try self.generateConversionName(writer, .{ .source = source, .target = target });
            try writer.writeByte('(');
            try self.generateOperand(allocator, reached, writer, operand);
            try writer.writeAll(".error)");
        }
        try writer.writeAll(" };\n");
        if (deferred) {
            self.depth -= 1;
            try self.generateIndentation(writer);
            try writer.writeAll("}\n");
        }
        const number = step.temporary orelse return;
        try self.generateIndentation(writer);
        try writer.print("mn_temporary_{d} = ", .{number});
        try self.generateOperand(allocator, reached, writer, operand);
        try writer.writeAll(".value;\n");
    }

    fn generateLiftedShortCircuit(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        step: *const Step,
    ) WriteError!void {
        const binary = step.expression.kind.binary;
        const value_type = step.expression.type.?;
        const left_type = binary.left.type.?;
        try self.generateIndentation(writer);
        try writer.writeAll("if (");
        switch (binary.operator) {
            .@"and", .@"or" => {
                if (binary.operator == .@"or") try writer.writeByte('!');
                try writer.writeByte('(');
                try self.generateOperand(allocator, reached, writer, binary.left);
                try writer.writeByte(')');
            },
            .@"orelse" => {
                try writer.writeAll("!(");
                try self.generateOperand(allocator, reached, writer, binary.left);
                try writer.writeAll(if (isPointerOptional(left_type)) " != NULL)" else ".present)");
            },
            .@"catch" => {
                try self.generateOperand(allocator, reached, writer, binary.left);
                try writer.writeAll(".error.tag != 0");
            },
            else => unreachable,
        }
        try writer.writeAll(") {\n");
        self.depth += 1;
        try self.generateLiftedScope(allocator, reached, writer, binary.right);
        try self.generateIndentation(writer);
        if (step.temporary) |number| {
            try writer.print("mn_temporary_{d} = ", .{number});
            try self.generateFullValue(allocator, reached, writer, binary.right, value_type);
        } else {
            try writer.writeAll("(void)(");
            try self.generateStatementEffects(allocator, reached, writer, binary.right);
            try writer.writeByte(')');
        }
        try writer.writeAll(";\n");
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeByte('}');
        const number = step.temporary orelse return writer.writeByte('\n');
        try writer.writeAll(" else {\n");
        self.depth += 1;
        try self.generateIndentation(writer);
        try writer.print("mn_temporary_{d} = ", .{number});
        try self.generateOperand(allocator, reached, writer, binary.left);
        const unwrapped = switch (binary.operator) {
            .@"orelse" => !isPointerOptional(left_type) and !std.meta.eql(value_type, left_type),
            .@"catch" => true,
            else => false,
        };
        if (unwrapped) try writer.writeAll(".value");
        try writer.writeAll(";\n");
        self.depth -= 1;
        try self.generateIndentation(writer);
        try writer.writeAll("}\n");
    }

    fn isLiftedShortCircuit(self: *const Generator, expression: *const ast.Expression) bool {
        if (expression.kind != .binary or !isShortCircuit(expression.kind.binary.operator)) return false;
        const right = expression.kind.binary.right;
        for (self.steps) |step| {
            if (step.scope == right and step.lifted) return true;
        }
        return false;
    }

    fn isLiftedRoot(self: *const Generator, expression: *const ast.Expression) bool {
        for (self.steps) |step| {
            if (step.expression == expression and step.lifted) return true;
        }
        return false;
    }

    fn generateCatch(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) WriteError!void {
        const binary = expression.kind.binary;
        try writer.writeByte('(');
        try self.generateOperand(allocator, reached, writer, binary.left);
        try writer.writeAll(".error.tag == 0 ? ");
        if (isZeroSized(expression.type.?)) {
            try writer.writeAll("(void)0 : ");
            if (hasEffects(binary.right.*)) {
                try writer.writeAll("(void)(");
                try self.generateStatementEffects(allocator, reached, writer, binary.right);
                return writer.writeAll("))");
            }
            return writer.writeAll("(void)0)");
        }
        try self.generateOperand(allocator, reached, writer, binary.left);
        try writer.writeAll(".value : ");
        try self.generateFullValue(allocator, reached, writer, binary.right, expression.type.?);
        try writer.writeByte(')');
    }

    fn generateEnumConverted(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
    ) WriteError!void {
        const conversion: Conversion = .{ .source = expression.type.?, .target = expected };
        try self.recordConversion(allocator, reached, conversion);
        try self.generateConversionName(writer, conversion);
        try writer.writeByte('(');
        try self.generateOperand(allocator, reached, writer, expression);
        try writer.writeByte(')');
    }

    fn recordConversion(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        conversion: Conversion,
    ) WriteError!void {
        try self.recordType(allocator, reached, conversion.target);
        try self.recordType(allocator, reached, conversion.source);
        if (conversion.source == .result) {
            const source: types.Type = .{ .@"enum" = conversion.source.result.error_set };
            const target: types.Type = .{ .@"enum" = conversion.target.result.error_set };
            if (source.@"enum" != target.@"enum") try self.recordConversion(allocator, reached, .{ .source = source, .target = target });
        }
        const recorded = for (reached.conversions.items) |earlier| {
            if (std.meta.eql(earlier, conversion)) break true;
        } else false;
        if (!recorded) try reached.conversions.append(allocator, conversion);
    }

    fn generateWrapped(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        expression: *const ast.Expression,
        expected: types.Type,
        operand: bool,
    ) WriteError!void {
        const child = expected.optional.child;
        if (isPointerOptional(expected)) {
            if (operand) return self.generateConvertedOperand(allocator, reached, writer, expression, child);
            return self.generateConverted(allocator, reached, writer, expression, child);
        }
        try self.recordType(allocator, reached, expected);
        if (isZeroSized(child)) {
            const effects = hasEffects(expression.*);
            if (effects) {
                try writer.writeAll("(");
                try self.generateEffects(allocator, reached, writer, expression.*);
                try writer.writeAll(", ");
            }
            try self.generateCompoundStart(writer, expected, .expression);
            try writer.writeAll(".present = true }");
            if (effects) try writer.writeAll(")");
            return;
        }
        try self.generateCompoundStart(writer, expected, .expression);
        try writer.writeAll(".value = ");
        if (operand) {
            try self.generateConvertedOperand(allocator, reached, writer, expression, child);
        } else {
            try self.generateConverted(allocator, reached, writer, expression, child);
        }
        try writer.writeAll(", .present = true }");
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
            if (step.scope != scope or step.lifted) continue;
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
            if (step.scope == scope and !step.lifted) return true;
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
            if (step.lifted and step.temporary == null) continue;
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
        if (isOptionalWrap(expression.type.?, expected)) return self.generateWrapped(allocator, reached, writer, expression, expected, true);
        if (isResultWrap(expression.type.?, expected)) return self.generateResultWrapped(allocator, reached, writer, expression, expected);
        if (isConversionCall(expression.type.?, expected)) return self.generateEnumConverted(allocator, reached, writer, expression, expected);
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
                .local, .element => try writer.writeAll(self.findLocalName(identifier.resolution.?).?),
                .function => |function| try self.generateFunctionName(allocator, reached, writer, function),
                .case => |case| try self.generateCaseValue(allocator, reached, writer, case, null),
                .type, .typeclass_function, .typeclass_method, .builtin => unreachable,
            },
            inline .path_expression, .member => |name| switch (name.resolution.?) {
                .constant => |constant| try self.generateConstant(allocator, reached, writer, constant),
                .function => |function| try self.generateFunctionName(allocator, reached, writer, function),
                .case => |case| try self.generateCaseValue(allocator, reached, writer, case, null),
                .parameter, .type, .local, .element, .typeclass_function, .typeclass_method, .builtin => unreachable,
            },
            .call => |call| {
                const hoists = try self.generateHoistedEffects(allocator, reached, writer, call.arguments);
                switch (ast.extractResolution(call.callee)) {
                    .function => |function| try self.generateFunctionCall(allocator, reached, writer, call, function),
                    .parameter, .local, .constant, .element => try self.generateValueCall(allocator, reached, writer, call),
                    .case => |case| try self.generateCaseValue(allocator, reached, writer, case, &call.arguments[0].value),
                    .builtin => |builtin| try self.generateBuiltinCall(allocator, reached, writer, call, builtin),
                    .type, .typeclass_function, .typeclass_method => unreachable,
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
                if (equality and !ast.isNullComparison(binary)) {
                    try collectEqualities(allocator, &reached.equalities, binary.left.type.?);
                    try collectEqualities(allocator, &reached.equalities, binary.right.type.?);
                }
                try self.recordPointerTarget(allocator, reached, binary.left.type.?);
                try self.recordPointerTarget(allocator, reached, binary.right.type.?);
                if (binary.operator == .@"orelse") return self.generateOrElse(allocator, reached, writer, expression);
                if (binary.operator == .@"catch") return self.generateCatch(allocator, reached, writer, expression);
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
                if (operand.type.? != .function) try writer.writeByte('&');
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
            .range => |range| try self.generateRange(allocator, reached, writer, expression.type.?, range.*),
            .@"try" => |operand| {
                for (self.steps) |step| {
                    if (step.expression.kind != .@"try" or step.expression.kind.@"try" != operand) continue;
                    const number = step.temporary orelse break;
                    return writer.print("mn_temporary_{d}", .{number});
                }
                try writer.writeAll("(void)0");
            },
            .method_call, .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type, .struct_type => {
                unreachable;
            },
        }
    }

    fn generateRange(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        range_type: types.Type,
        range: ast.Range,
    ) WriteError!void {
        try self.recordType(allocator, reached, range_type);
        const end_type = range_type.@"struct".fields[1].type;
        try self.recordType(allocator, reached, end_type);
        try self.generateCompoundStart(writer, range_type, .expression);
        try writer.writeAll(".start = ");
        try self.generateOperand(allocator, reached, writer, &range.start);
        try writer.writeAll(", .end = ");
        if (range.end) |*end| {
            try self.generateConvertedOperand(allocator, reached, writer, end, end_type);
        } else {
            try self.generateNull(writer, end_type, .initializer);
        }
        try writer.writeAll(" }");
    }

    fn generateBuiltinCall(
        self: *Generator,
        allocator: std.mem.Allocator,
        reached: *Reached,
        writer: *std.Io.Writer,
        call: ast.Call,
        builtin: ast.Builtin,
    ) WriteError!void {
        const target = ast.extractType(call.arguments[0].value);
        switch (builtin) {
            .size => try self.generateKnownInteger(writer, .usize, types.findLayout(target).size),
            .alignment => try self.generateKnownInteger(writer, .usize, types.findLayout(target).alignment),
            .length => try self.generateKnownInteger(writer, .usize, target.tuple.elements.len),
            .join => unreachable,
            .convert, .truncate => {
                try writer.writeAll("((");
                try self.generateType(writer, target);
                try writer.writeByte(')');
                try self.generateOperand(allocator, reached, writer, &call.arguments[1].value);
                try writer.writeByte(')');
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
            .combine, .result, .@"catch" => unreachable,
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
        var operand_type = operation.left.type.?;
        if (isConversionCall(operand_type, operation.right.type.?) and types.isEnumPart(operand_type.@"enum", operation.right.type.?.@"enum")) {
            operand_type = operation.right.type.?;
        }
        try self.generateType(writer, operand_type);
        try writer.writeAll("_equal(");
        try self.generateConvertedOperand(allocator, reached, writer, operation.left, operand_type);
        try writer.writeAll(", ");
        try self.generateConvertedOperand(allocator, reached, writer, operation.right, operand_type);
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
            .tuple => return writer.print("._{d}", .{indexing.position.?}),
            .array, .slice => try writer.writeAll(".items"),
            .pointer => |pointer| if (!pointer.many) try writer.writeAll("->items"),
            .number, .boolean, .void, .type, .@"struct", .@"enum", .optional, .result, .function, .variable, .application => {
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
            .number, .boolean, .void, .type, .@"struct", .@"enum", .slice, .optional, .result, .tuple, .function, .variable, .application => false,
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
            .number, .boolean, .void, .type, .@"struct", .@"enum", .optional, .result, .tuple, .function, .variable, .application => {
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
            .number, .boolean, .void, .type, .@"struct", .@"enum", .pointer, .optional, .result, .tuple, .function, .variable, .application => {
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
        const constant_declaration = declaration.kind.constant_declaration;
        const constant_type = ast.extractDeclaredType(constant_declaration.type, constant_declaration.value);
        try self.generateKnownValue(allocator, reached, writer, constant_declaration.known.?.*, constant_type, .expression);
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

    fn findLocalName(self: *const Generator, resolution: ast.Resolution) ?[]const u8 {
        for (self.local_names) |local_name| {
            if (std.meta.eql(local_name.resolution, resolution)) return local_name.name;
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
                try writer.writeAll(self.findLocalName(.{ .local = statement }).?);
                break :callee_type findLocalType(statement.*);
            },
            .element => |element| callee_type: {
                try writer.writeAll(self.findLocalName(.{ .element = element }).?);
                break :callee_type ast.findElementName(element).type.?;
            },
            .constant => |constant| callee_type: {
                try self.generateConstant(allocator, reached, writer, constant);
                const declaration = self.program.modules[constant.module].declarations[constant.declaration];
                const constant_declaration = declaration.kind.constant_declaration;
                break :callee_type ast.extractDeclaredType(constant_declaration.type, constant_declaration.value);
            },
            .function, .type, .typeclass_function, .typeclass_method, .case, .builtin => unreachable,
        };
        try writer.writeByte('(');
        var written = false;
        for (call.arguments, callee_type.pointer.target.function.parameters) |*argument, parameter_type| {
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
            if (field.default == null) continue;
            if (ast.findArgument(elements, field.name) != null) continue;
            if (isZeroSized(field.type)) continue;
            if (written) try writer.writeAll(", ");
            try writer.print(".{s} = ", .{field.name});
            try self.generateKnownValue(allocator, reached, writer, field.default_value.?.*.?, field.type, form);
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
            inline .identifier, .path_expression, .member => |name| {
                if (name.resolution.? == .function) {
                    return self.generateFunctionName(allocator, reached, writer, name.resolution.?.function);
                }
                const constant = name.resolution.?.constant;
                const declarations = self.program.modules[constant.module].declarations;
                const constant_declaration = declarations[constant.declaration].kind.constant_declaration;
                const constant_type = ast.extractDeclaredType(constant_declaration.type, constant_declaration.value);
                try self.generateKnownValue(allocator, reached, writer, constant_declaration.known.?.*, constant_type, form);
            },
            .composite_literal => try self.generateLiteralElements(allocator, reached, writer, expression.*, form),
            .null => try self.generateNull(writer, expression.type.?, form),
            .slice => try self.generateSlice(allocator, reached, writer, expression.*, form),
            .binary, .unary => try self.generateExpression(allocator, reached, writer, expression.*),
            .address_of => |operand| try self.generateValue(allocator, reached, writer, operand, form),
            .undefined,
            .call,
            .method_call,
            .array_type,
            .slice_type,
            .index,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .struct_type,
            .field_access,
            .dereference,
            .unwrap,
            .@"try",
            .range,
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
            .type, .function, .variable, .application => unreachable,
            .@"struct" => |struct_type| {
                try writer.writeAll("mn_");
                for (self.program.modules[struct_type.module].path) |part| {
                    try writer.print("{s}_", .{part});
                }
                return writer.writeAll(struct_type.name);
            },
            .@"enum" => {
                try writer.writeAll("mn_");
                return self.generateTypeName(writer, value_type);
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
                if (pointer.target == .function) return self.generateFunctionPointer(writer, pointer.target.function.*);
                try self.generateTaggedType(writer, pointer.target);
                if (pointer.constant) try writer.writeAll(" const");
                return writer.writeAll(" *");
            },
            .optional => |optional| {
                if (isPointerOptional(value_type)) return self.generateType(writer, optional.child);
                try writer.writeAll("mn_optional_");
                return self.generateTypeName(writer, optional.child);
            },
            .result => {
                try writer.writeAll("mn_");
                return self.generateTypeName(writer, value_type);
            },
            .tuple => {
                try writer.writeAll("mn_");
                return self.generateTypeName(writer, value_type);
            },
        });
    }

    fn generateFunctionPointer(
        self: *Generator,
        writer: *std.Io.Writer,
        function: types.Function,
    ) WriteError!void {
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
        try writer.writeAll("))");
    }

    fn generateTaggedType(
        self: *Generator,
        writer: *std.Io.Writer,
        value_type: types.Type,
    ) WriteError!void {
        const tagged = value_type == .@"struct" or value_type == .@"enum" or value_type == .array or value_type == .slice or
            value_type == .tuple or value_type == .result or (value_type == .optional and !isPointerOptional(value_type));
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
            .@"enum" => |enumeration| {
                for (enumeration.parts, 0..) |part, index| {
                    if (index > 0) try writer.writeAll("_or_");
                    for (self.program.modules[part.module].path) |path_part| {
                        try writer.print("{s}_", .{path_part});
                    }
                    try writer.writeAll(part.name);
                }
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
            .result => |result| {
                try writer.writeAll("result_");
                try self.generateTypeName(writer, .{ .@"enum" = result.error_set });
                try writer.writeByte('_');
                try self.generateTypeName(writer, result.value);
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
            .type, .variable, .application => unreachable,
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
            .@"try" => return self.generateExpression(allocator, reached, writer, expression),
            .range => |range| {
                const end = if (range.end) |*end| end else null;
                return self.generateOperandEffects(allocator, reached, writer, &.{ &range.start, end });
            },
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .identifier,
            .path_expression,
            .member,
            .method_call,
            .array_type,
            .slice_type,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .struct_type,
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
            .function_declaration, .function_definition, .struct_definition, .enum_definition => return false,
            .typeclass_definition, .instance_declaration, .import => return false,
        };
        if (ast.isAlias(constant) or constant.value.type == null) return false;
        const value_type = ast.extractDeclaredType(constant.type, constant.value);
        if (isZeroSized(value_type) or types.isCompileTimeOnly(value_type)) return false;
        if (value_type == .@"struct" or value_type == .array) return true;
        if (constant.known) |known| {
            if (containsPlace(known.*)) return true;
        }
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
    conversions: std.ArrayList(Conversion) = .empty,
};

const Conversion = struct {
    source: types.Type,
    target: types.Type,
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
    resolution: ast.Resolution,
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

const Unrolled = struct {
    loop: *const ast.Statement,
    expansion: usize,
};

const Frame = struct {
    deferred: std.ArrayList(ast.Defer) = .empty,
    loop: ?*const ast.Statement = null,
};

const Errors = union(enum) {
    none,
    all,
    dynamic: []const u8,
};

const Step = struct {
    expression: *const ast.Expression,
    scope: *const ast.Expression,
    statement: *const ast.Statement,
    temporary: ?usize,
    address: ?types.Type = null,
    lifted: bool = false,
    lazy: bool = false,
};

const Static = struct {
    root: *const Value,
    root_type: types.Type,
    name: []const u8,
    definition: []const u8,
};

const Part = struct {
    expression: *const ast.Expression,
    role: Role,
};

const Role = enum {
    sequence,
    start,
    end,
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
            if (function.check_only) return null;
            const signature = function.signature;
            if (module_index == 0 and ast.isMain(signature) and !isResultMain(declaration.kind)) return signature.name;
            if (signature.typeclass) |typeclass| {
                var parts: std.ArrayList([]const u8) = .empty;
                for (function.instance_arguments) |argument| {
                    try parts.append(allocator, switch (argument) {
                        .type => |argument_type| try buildTypeName(allocator, program, module_index, argument_type),
                        .constructor => |constructor| try buildConstructorName(allocator, program, module_index, constructor),
                    });
                    try parts.append(allocator, "_");
                }
                try parts.appendSlice(allocator, &.{ extractLastName(typeclass), "_", signature.name });
                const name = try std.mem.concat(allocator, u8, parts.items);
                return try buildQualifiedName(allocator, module.path, name);
            }
            const receiver = signature.receiver orelse {
                return try buildQualifiedName(allocator, module.path, signature.name);
            };
            const receiver_type = ast.extractType(receiver);
            const type_name = try buildTypeName(allocator, program, module_index, receiver_type);
            const parts = &.{ type_name, "_", signature.name };
            const name = try std.mem.concat(allocator, u8, parts);
            return try buildQualifiedName(allocator, module.path, name);
        },
        .function_declaration => |function_declaration| return function_declaration.name,
        .constant_declaration => |constant| {
            return try buildQualifiedName(allocator, module.path, constant.name);
        },
        .struct_definition, .enum_definition, .typeclass_definition, .instance_declaration, .import => return null,
    }
}

fn buildConstructorName(
    allocator: std.mem.Allocator,
    program: ast.Program,
    module_index: usize,
    constructor: types.Constructor,
) std.mem.Allocator.Error![]const u8 {
    const function = constructor.function;
    const declaration = ast.findDeclaration(program.modules[function.module], function.declaration).*;
    const name = declaration.kind.function_definition.signature.name;
    if (function.module == module_index) return name;
    const path = try std.mem.join(allocator, "_", program.modules[function.module].path);
    return std.mem.concat(allocator, u8, &.{ path, "_", name });
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
        .@"enum" => |enumeration| {
            var names: std.ArrayList([]const u8) = .empty;
            for (enumeration.parts) |part| {
                if (part.module == module_index) {
                    try names.append(allocator, part.name);
                } else {
                    const path = try std.mem.join(allocator, "_", program.modules[part.module].path);
                    try names.append(allocator, try std.mem.concat(allocator, u8, &.{ path, "_", part.name }));
                }
            }
            return std.mem.join(allocator, "_or_", names.items);
        },
        .number => |number| @tagName(number),
        .boolean => "bool",
        .array => |array| {
            const element = try buildTypeName(allocator, program, module_index, array.element);
            return std.fmt.allocPrint(allocator, "array_{d}_{s}", .{ array.length, element });
        },
        .slice => |slice| {
            const element = try buildTypeName(allocator, program, module_index, slice.element);
            return std.mem.concat(allocator, u8, &.{ if (slice.constant) "slice_const_" else "slice_", element });
        },
        .pointer => |pointer| {
            const target = try buildTypeName(allocator, program, module_index, pointer.target);
            return std.mem.concat(allocator, u8, &.{ pointerPrefix(pointer.*), target });
        },
        .optional => |optional| {
            const child = try buildTypeName(allocator, program, module_index, optional.child);
            return std.mem.concat(allocator, u8, &.{ "optional_", child });
        },
        .result => |result| {
            const error_set = try buildTypeName(allocator, program, module_index, .{ .@"enum" = result.error_set });
            const value = try buildTypeName(allocator, program, module_index, result.value);
            return std.mem.concat(allocator, u8, &.{ "result_", error_set, "_", value });
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
        .type, .variable, .application => unreachable,
    };
}

fn pointerPrefix(pointer: types.Pointer) []const u8 {
    if (pointer.target == .function) return "";
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
        .@"enum" => |enumeration| {
            for (enumeration.parts) |part| {
                if (std.mem.findScalar(usize, contained.items, part.module) != null) continue;
                try contained.append(allocator, part.module);
            }
        },
        .array => |array| try collectContainedModulesOf(allocator, contained, array.element),
        .optional => |optional| {
            if (isPointerOptional(value_type)) return;
            try collectContainedModulesOf(allocator, contained, optional.child);
        },
        .result => |result| {
            try collectContainedModulesOf(allocator, contained, .{ .@"enum" = result.error_set });
            try collectContainedModulesOf(allocator, contained, result.value);
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                try collectContainedModulesOf(allocator, contained, element);
            }
        },
        .number, .boolean, .void, .type, .slice, .pointer, .function, .variable, .application => {},
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
        .result => |result| {
            if (!in_prototype) {
                try collectPrototypeTags(allocator, tags, .{ .@"enum" = result.error_set }, false);
                return collectPrototypeTags(allocator, tags, result.value, false);
            }
            if (!containsType(tags.items, value_type)) try tags.append(allocator, value_type);
        },
        .@"struct", .@"enum", .array, .slice, .tuple => {
            if (!in_prototype or containsType(tags.items, value_type)) return;
            try tags.append(allocator, value_type);
        },
        .number, .boolean, .void, .type, .variable, .application => {},
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
        .@"try" => return true,
        .range => |range| return hasEffects(range.start) or (if (range.end) |end| hasEffects(end) else false),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .member,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        .struct_type,
        => return false,
        .method_call => unreachable,
    }
}

fn isUnit(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .call, .@"try" => true,
        .binary => |binary| isShortCircuit(binary.operator) and hasEffects(binary.right.*),
        else => false,
    };
}

fn isShortCircuit(operator: ast.BinaryOperator) bool {
    return operator == .@"and" or operator == .@"or" or operator == .@"orelse" or operator == .@"catch";
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
        .combine,
        .result,
        .@"orelse",
        .@"catch",
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
        .shift_left, .shift_right, .@"and", .@"or", .@"orelse", .@"catch", .combine, .result => unreachable,
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
    if (value_type == .@"enum") {
        for (value_type.@"enum".cases) |case| {
            try collectEqualities(allocator, equalities, case.type orelse continue);
        }
        return equalities.append(allocator, value_type);
    }
    const child = switch (value_type) {
        .array => |array| array.element,
        .optional => |optional| optional.child,
        .number, .boolean, .void, .type, .@"struct", .@"enum", .slice, .pointer, .result, .tuple, .function, .variable, .application => {
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
        .@"enum" => true,
        .number, .boolean, .void, .type, .@"struct", .slice, .pointer, .result, .tuple, .function, .variable, .application => false,
    };
}

fn hasPayload(enumeration: *const types.Enum) bool {
    for (enumeration.cases) |case| {
        const payload = case.type orelse continue;
        if (!isZeroSized(payload)) return true;
    }
    return false;
}

fn isConversionCall(value_type: types.Type, expected: types.Type) bool {
    if (value_type == .result and expected == .result) return value_type.result != expected.result;
    return value_type == .@"enum" and expected == .@"enum" and value_type.@"enum" != expected.@"enum";
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
        .constant_declaration => |*constant| if (constant.known != null) null else &constant.value,
        .tuple_declaration => |*declaration| &declaration.value,
        .variable_declaration => |*variable| &variable.value,
        .assignment => |*assignment| &assignment.value,
        .@"if" => |*conditional| &conditional.condition,
        .@"while" => |*loop| &loop.condition,
        .match => |*matching| &matching.value,
        .@"for", .@"defer", .@"break", .@"continue" => null,
    };
}

fn collectParts(allocator: std.mem.Allocator, loop: *const ast.For) std.mem.Allocator.Error![]const Part {
    var parts: std.ArrayList(Part) = .empty;
    switch (loop.sequence) {
        .value => |*value| try parts.append(allocator, .{ .expression = value, .role = .sequence }),
        .range => |*range| {
            try parts.append(allocator, .{ .expression = &range.start, .role = .start });
            if (range.end) |*end| try parts.append(allocator, .{ .expression = end, .role = .end });
        },
    }
    return parts.items;
}

fn hasLength(loop: ast.For) bool {
    return loop.sequence == .value or loop.sequence.range.end != null;
}

fn isEmptyLoop(statement: ast.Statement) bool {
    if (statement.kind != .@"for") return false;
    switch (statement.kind.@"for".sequence) {
        .value => |value| {
            const sequence_type = followPointer(value.type.?);
            return sequence_type == .array and sequence_type.array.length == 0;
        },
        .range => |range| return range.length == 0,
    }
}

fn isDirect(expression: ast.Expression) bool {
    if (expression.kind == .integer_literal) return true;
    if (!isPlainName(expression)) return false;
    return expression.type.? == .array or !isMemoryRead(expression);
}

fn isAddressedPart(part: Part) bool {
    const expression = part.expression.*;
    if (part.role != .sequence or expression.type.? != .array) return false;
    return !isDirect(expression) and isPlace(expression);
}

fn isPlace(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .identifier, .path_expression, .dereference => true,
        .field_access => |access| access.value.type.? == .pointer or isPlace(access.value.*),
        .index => |indexing| !isStorage(indexing.value.type.?) or isPlace(indexing.value.*),
        else => false,
    };
}

fn isZeroLiteral(expression: ast.Expression) bool {
    return expression.kind == .integer_literal and parseInteger(expression) == 0;
}

fn parseInteger(expression: ast.Expression) u128 {
    return std.fmt.parseInt(u128, expression.kind.integer_literal.text, 0) catch unreachable;
}

fn collectScopeSteps(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(Step),
    statement: *const ast.Statement,
    scope: *const ast.Expression,
) std.mem.Allocator.Error!void {
    const tried = try containsTry(allocator, scope);
    if (tried or try needsSequence(allocator, scope)) {
        const consumed = isUnit(scope.*) or !isZeroSized(scope.type.?);
        try collectUnitSteps(allocator, steps, statement, scope, scope, consumed, false);
    }
    if (tried and (scope.kind == .@"try" or (scope.kind == .binary and isShortCircuit(scope.kind.binary.operator)))) {
        const stored = !isZeroSized(scope.type.?) and statement.kind != .discard;
        try steps.append(allocator, .{
            .expression = scope,
            .scope = scope,
            .statement = statement,
            .temporary = if (stored) countTemporaries(steps.items) + 1 else null,
        });
    }
    try collectInnerScopeSteps(allocator, steps, statement, scope);
}

fn liftSteps(allocator: std.mem.Allocator, steps: []Step) std.mem.Allocator.Error!void {
    const tried = for (steps) |step| {
        if (step.expression.kind == .@"try") break true;
    } else false;
    if (!tried) return;
    for (steps) |*step| step.lifted = !step.lazy or try containsTry(allocator, step.scope);
}

fn containsTry(allocator: std.mem.Allocator, expression: *const ast.Expression) std.mem.Allocator.Error!bool {
    if (expression.kind == .@"try") return true;
    if (expression.kind == .binary and isShortCircuit(expression.kind.binary.operator)) {
        if (try containsTry(allocator, expression.kind.binary.right)) return true;
    }
    for (try collectScopeChildren(allocator, expression)) |child| {
        if (try containsTry(allocator, child)) return true;
    }
    return false;
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
    if (expression.kind != .binary) return false;
    const operator = expression.kind.binary.operator;
    if (operator != .@"orelse" and operator != .@"catch") return false;
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
            .parameter, .constant, .function, .type, .element => false,
            .typeclass_function, .typeclass_method, .case, .builtin => unreachable,
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
        const right = expression.kind.binary.right;
        const start = steps.items.len;
        try collectScopeSteps(allocator, steps, statement, right);
        for (steps.items[start..]) |*step| {
            if (step.scope == right) step.lazy = true;
        }
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
        .dereference, .unwrap, .@"try" => |operand| try children.append(allocator, operand),
        .range => |range| {
            try children.append(allocator, &range.start);
            if (range.end) |*end| try children.append(allocator, end);
        },
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .member,
        .method_call,
        .negation,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        .struct_type,
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
        .function_declaration, .constant_declaration, .struct_definition, .enum_definition => &.{},
        .typeclass_definition, .instance_declaration, .import => &.{},
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
        if (declaresNames(statement.*)) {
            for (ast.extractElementNames(statement.*)) |name| try written.append(allocator, name.name);
        }
        const local = extractLocal(statement.*) orelse continue;
        try written.append(allocator, local.name);
    }

    var local_names: std.ArrayList(LocalName) = .empty;
    for (statements.items) |statement| {
        if (declaresNames(statement.*)) {
            for (ast.extractElementNames(statement.*), 0..) |name, position| {
                const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
                const scope = switch (statement.kind) {
                    .@"for" => |loop| loop.body,
                    .match => |matching| matching.branches[position].body,
                    else => body,
                };
                if (!isElementDeclared(scope, element)) continue;
                try local_names.append(allocator, .{
                    .resolution = .{ .element = element },
                    .name = try reserveName(allocator, &taken, written.items, name.name),
                    .location = name.location,
                });
            }
        }
        if (!isDeclared(body, statement)) continue;
        try local_names.append(allocator, .{
            .resolution = .{ .local = statement },
            .name = try reserveName(allocator, &taken, written.items, extractLocal(statement.*).?.name),
            .location = statement.location,
        });
    }
    return local_names.items;
}

fn declaresNames(statement: ast.Statement) bool {
    if (statement.kind == .@"for") return !ast.isUnrolled(statement.kind.@"for");
    return statement.kind == .tuple_declaration or statement.kind == .match;
}

fn reserveName(
    allocator: std.mem.Allocator,
    taken: *std.ArrayList([]const u8),
    written: []const []const u8,
    source_name: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var name = source_name;
    var number: usize = 1;
    while (containsName(taken.items, name) or (number > 1 and containsName(written, name))) {
        number += 1;
        name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ source_name, number });
    }
    try taken.append(allocator, name);
    return name;
}

fn collectStatements(
    allocator: std.mem.Allocator,
    statements: *std.ArrayList(*const ast.Statement),
    body: []const ast.Statement,
) std.mem.Allocator.Error!void {
    for (body) |*statement| {
        try statements.append(allocator, statement);
        if (statement.kind == .@"defer") try statements.append(allocator, statement.kind.@"defer".statement);
        if (statement.kind == .@"for") {
            if (statement.kind.@"for".expansion_value) |value| try statements.append(allocator, value);
        }
        var blocks = ast.iterateBlocks(statement.*);
        while (blocks.next()) |block| try collectStatements(allocator, statements, block);
    }
}

fn collectKind(
    allocator: std.mem.Allocator,
    body: []const ast.Statement,
    kind: std.meta.Tag(ast.StatementKind),
) std.mem.Allocator.Error![]const *const ast.Statement {
    var statements: std.ArrayList(*const ast.Statement) = .empty;
    try collectStatements(allocator, &statements, body);
    var collected: std.ArrayList(*const ast.Statement) = .empty;
    for (statements.items) |statement| {
        if (statement.kind == kind) try collected.append(allocator, statement);
    }
    return collected.items;
}

fn collectLoops(
    allocator: std.mem.Allocator,
    body: []const ast.Statement,
) std.mem.Allocator.Error![]const *const ast.Statement {
    var statements: std.ArrayList(*const ast.Statement) = .empty;
    try collectStatements(allocator, &statements, body);
    var loops: std.ArrayList(*const ast.Statement) = .empty;
    for (statements.items) |statement| {
        if (statement.kind == .@"while" or statement.kind == .@"for") try loops.append(allocator, statement);
    }
    return loops.items;
}

fn containsGoto(
    body: []const ast.Statement,
    loop: *const ast.Statement,
    tag: std.meta.Tag(ast.StatementKind),
    innermost_loop: ?*const ast.Statement,
) bool {
    for (body) |*statement| {
        switch (statement.kind) {
            .@"break", .@"continue" => |jump| {
                if (std.meta.activeTag(statement.kind) != tag or jump.loop.? != loop) continue;
                if (isGoto(loop, tag, innermost_loop)) return true;
            },
            .@"if" => |conditional| {
                if (containsGoto(conditional.body, loop, tag, innermost_loop)) return true;
                const else_body = conditional.else_body orelse continue;
                if (containsGoto(else_body, loop, tag, innermost_loop)) return true;
            },
            .@"while", .@"for" => {
                const inner_body, const else_body = ast.extractBlocks(statement.*);
                if (statement.kind == .@"for") {
                    for (statement.kind.@"for".expansions) |expansion| {
                        if (containsGoto(expansion, loop, tag, statement)) return true;
                    }
                }
                if (!isEmptyLoop(statement.*) and containsGoto(inner_body, loop, tag, statement)) return true;
                if (containsGoto(else_body, loop, tag, innermost_loop)) return true;
            },
            .match => |matching| {
                for (matching.branches) |branch| {
                    if (containsGoto(branch.body, loop, tag, null)) return true;
                }
            },
            .noop, .@"return", .discard, .call, .constant_declaration, .tuple_declaration => {},
            .variable_declaration, .assignment, .@"defer" => {},
        }
    }
    return false;
}

fn endsWithJump(body: []const ast.Statement) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1].kind) {
        .@"return", .@"break", .@"continue" => true,
        else => false,
    };
}

fn isGoto(
    loop: *const ast.Statement,
    tag: std.meta.Tag(ast.StatementKind),
    innermost_loop: ?*const ast.Statement,
) bool {
    if (loop != innermost_loop or isUnrolledLoop(loop)) return true;
    return tag == .@"break" and ast.extractBlocks(loop.*)[1].len != 0;
}

fn isUnrolledLoop(loop: *const ast.Statement) bool {
    return loop.kind == .@"for" and ast.isUnrolled(loop.kind.@"for");
}

fn extractLocal(statement: ast.Statement) ?Local {
    return switch (statement.kind) {
        .constant_declaration => |constant| .{ .name = constant.name, .value = constant.value },
        .variable_declaration => |variable| .{ .name = variable.name, .value = variable.value },
        .noop, .@"return", .discard, .call, .tuple_declaration, .assignment, .@"if", .@"while", .@"for" => null,
        .match, .@"defer", .@"break", .@"continue" => null,
    };
}

fn findLocalType(statement: ast.Statement) types.Type {
    return switch (statement.kind) {
        .constant_declaration => |constant| ast.extractDeclaredType(constant.type, constant.value),
        .variable_declaration => |variable| ast.extractDeclaredType(variable.type, variable.value),
        .noop, .@"return", .discard, .call, .tuple_declaration, .assignment, .@"if", .@"while", .@"for" => unreachable,
        .match, .@"defer", .@"break", .@"continue" => unreachable,
    };
}

fn isDeclared(body: []const ast.Statement, statement: *const ast.Statement) bool {
    const kind = statement.kind;
    if (kind != .constant_declaration and kind != .variable_declaration) return false;
    if (kind == .constant_declaration and ast.isAlias(kind.constant_declaration)) return false;
    const local_type = findLocalType(statement.*);
    if (isZeroSized(local_type) or types.isCompileTimeOnly(local_type)) return false;
    return !isDiscarded(body, .{ .local = statement });
}

fn isElementDeclared(body: []const ast.Statement, element: ast.Resolution.Element) bool {
    const name = ast.findElementName(element);
    if (ast.isDiscardedName(name.name)) return false;
    if (isZeroSized(name.type.?)) return false;
    return !isDiscarded(body, .{ .element = element });
}

fn isZeroSizedPointer(name: ast.ElementName) bool {
    return name.pointer and isZeroSized(name.type.?.pointer.target);
}

fn hasWritablePointerName(names: []const ast.ElementName) bool {
    for (names) |name| {
        if (name.pointer and !name.type.?.pointer.constant) return true;
    }
    return false;
}

fn hasChosenBlock(body: []const ast.Statement) bool {
    for (body) |statement| {
        if (statement.kind == .@"if" and statement.kind.@"if".known != null) return true;
        var blocks = ast.iterateBlocks(statement);
        while (blocks.next()) |block| {
            if (hasChosenBlock(block)) return true;
        }
    }
    return false;
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
            .tuple_declaration,
            .variable_declaration,
            .assignment,
            .@"break",
            .@"continue",
            => continue,
            .@"if", .@"while", .@"for", .match => {
                var blocks = ast.iterateBlocks(statement);
                while (blocks.next()) |block| {
                    if (isDiscarded(block, resolution)) return true;
                }
                continue;
            },
            .@"defer" => |deferred| {
                if (isDiscarded(deferred.statement[0..1], resolution)) return true;
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
            .constant, .element => true,
            .parameter, .function, .type, .case => false,
            .typeclass_function, .typeclass_method, .builtin => unreachable,
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
            .number, .boolean, .void, .type, .@"struct", .@"enum", .optional, .result, .function, .variable, .application => {
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
            .number, .boolean, .void, .type, .@"struct", .@"enum", .slice, .pointer, .optional, .result, .function, .variable, .application => {
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
            if (declaration.kind != .function_definition or isCompileTimeFunction(declaration)) continue;
            var statements: std.ArrayList(*const ast.Statement) = .empty;
            try collectStatements(allocator, &statements, declaration.kind.function_definition.body);
            for (statements.items) |statement| {
                if (statement.kind == .assignment) {
                    const target = &statement.kind.assignment.target;
                    try collectAddressedConstantsOf(allocator, &addressed, target);
                }
                if (statement.kind == .@"for") {
                    for (try collectParts(allocator, &statement.kind.@"for")) |part| {
                        try collectAddressedConstantsOf(allocator, &addressed, part.expression);
                    }
                }
                if (findAddressedContainer(statement)) |container| {
                    if (ast.findElementConstantRoot(container.*)) |constant| {
                        if (!containsConstant(addressed.items, constant)) try addressed.append(allocator, constant);
                    }
                }
                const expression = findStatementExpression(statement) orelse continue;
                try collectAddressedConstantsOf(allocator, &addressed, expression);
            }
        }
    }
    return addressed.items;
}

fn findAddressedContainer(statement: *const ast.Statement) ?*const ast.Expression {
    return switch (statement.kind) {
        .tuple_declaration => |*declaration| {
            if (!ast.hasPointerName(declaration.names)) return null;
            return &declaration.value;
        },
        .@"for" => |*loop| {
            if (!ast.hasPointerName(loop.names) or loop.sequence != .value) return null;
            return &loop.sequence.value;
        },
        .match => |*matching| {
            if (!ast.hasPointerName(matching.names)) return null;
            return &matching.value;
        },
        .noop,
        .@"return",
        .discard,
        .call,
        .constant_declaration,
        .variable_declaration,
        .assignment,
        .@"if",
        .@"while",
        .@"defer",
        .@"break",
        .@"continue",
        => null,
    };
}

fn generateKnownFloat(writer: *std.Io.Writer, number: types.NumberType, value: f128) WriteError!void {
    const suffix = switch (number) {
        .f16 => "f16",
        .f32 => "f",
        .f64 => "",
        .f128 => "f128",
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => unreachable,
    };
    if (std.math.isNan(value)) return writer.print("__builtin_nan{s}(\"\")", .{suffix});
    if (std.math.isInf(value)) {
        if (value < 0) try writer.writeByte('-');
        return writer.print("__builtin_inf{s}()", .{suffix});
    }
    switch (number) {
        .f16 => try writer.printFloatHex(@as(f16, @floatCast(value)), .lower, null),
        .f32 => try writer.printFloatHex(@as(f32, @floatCast(value)), .lower, null),
        .f64 => try writer.printFloatHex(@as(f64, @floatCast(value)), .lower, null),
        .f128 => try writer.printFloatHex(value, .lower, null),
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => unreachable,
    }
    try writer.writeAll(suffix);
}

fn generateKnownByte(writer: *std.Io.Writer, byte: u8) WriteError!void {
    if (byte >= 0x20 and byte < 0x7f and byte != '"' and byte != '\\' and byte != '?') return writer.writeByte(byte);
    try writer.print("\\{o:0>3}", .{byte});
}

fn isCompileTimeFunction(declaration: ast.Declaration) bool {
    if (declaration.kind != .function_definition) return false;
    const signature = declaration.kind.function_definition.signature;
    const definition = declaration.kind.function_definition;
    if (ast.isGeneric(signature) or definition.pattern or definition.check_only) return true;
    if (types.isCompileTimeOnly(ast.extractType(signature.return_type))) return true;
    for (signature.parameters) |parameter| {
        if (types.isCompileTimeOnly(ast.extractType(parameter.type))) return true;
    }
    return false;
}

fn containsPlace(value: Value) bool {
    return switch (value) {
        .pointer, .many, .slice => true,
        .optional => |optional| if (optional) |inner| containsPlace(inner.*) else false,
        .aggregate => |elements| {
            for (elements) |element| {
                if (containsPlace(element)) return true;
            }
            return false;
        },
        .enumeration, .failure => |enumeration| if (enumeration.value) |inner| containsPlace(inner.*) else false,
        .integer, .float, .boolean, .void, .undefined, .function, .type => false,
    };
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

fn isResultWrap(value_type: types.Type, expected: types.Type) bool {
    return expected == .result and value_type != .result;
}

fn isResultMain(kind: ast.DeclarationKind) bool {
    return kind == .function_definition and ast.extractType(kind.function_definition.signature.return_type) == .result;
}

fn needsFinalReturn(return_type: types.Type, body: []const ast.Statement) bool {
    if (return_type != .result or !isZeroSized(return_type.result.value)) return false;
    return !endsWithJump(body);
}

fn isOptionalWrap(value_type: types.Type, expected: types.Type) bool {
    if (expected != .optional) return false;
    var value_count: usize = 0;
    var current = value_type;
    while (current == .optional) : (current = current.optional.child) value_count += 1;
    var expected_count: usize = 0;
    current = expected;
    while (current == .optional) : (current = current.optional.child) expected_count += 1;
    return value_count < expected_count;
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
    return value_type.optional.child == .pointer;
}

fn findStruct(value_type: types.Type) ?types.Struct {
    return switch (value_type) {
        .@"struct" => |struct_type| struct_type,
        .number, .boolean, .void, .type, .@"enum", .array, .slice, .pointer, .optional, .result, .tuple, .function, .variable, .application => {
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
        .@"enum" => |enumeration| {
            if (types.isDeclaredEnum(enumeration) and enumeration.module != module_index) return;
            for (enumeration.cases) |case| {
                try orderDefinition(allocator, ordered, module_index, case.type orelse continue);
            }
        },
        .optional => |optional| {
            if (isPointerOptional(value_type)) return;
            try orderDefinition(allocator, ordered, module_index, optional.child);
        },
        .result => |result| {
            try orderDefinition(allocator, ordered, module_index, .{ .@"enum" = result.error_set });
            try orderDefinition(allocator, ordered, module_index, result.value);
        },
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                try orderDefinition(allocator, ordered, module_index, element);
            }
        },
        .number, .boolean, .void, .type, .pointer, .function, .variable, .application => return,
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
        .result => |result| two == .result and result.error_set == two.result.error_set and
            isSameCType(result.value, two.result.value),
        .tuple => |tuple| two == .tuple and isSameCTypes(tuple.elements, two.tuple.elements),
        .function => |function| two == .function and
            isSameCType(function.return_type, two.function.return_type) and
            isSameCTypes(function.parameters, two.function.parameters),
        .number, .boolean, .void, .type, .@"struct", .@"enum", .variable, .application => {
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
    try plugin_directory.dir.createDirPath(std.testing.io, "runtime");
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/monolith.h", .data = "header" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/stdout.c", .data = "stdout" });
    try plugin_directory.dir.writeFile(std.testing.io, .{ .sub_path = "runtime/unused.c", .data = "unused" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn show(): mn::stdout::write(\"hi\")" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
    const allocator = arena.allocator();
    const program_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &program_directory.sub_path });
    const compiler_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &compiler_directory.sub_path });
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "hello.mn", .data = "import mn\nfn main(): mn::stdout::write(\"hi\\n\")" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::add(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main(): mn::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"mn/stdout.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_runtime_stdout_write((mn_slice_u8){ .items = (uint8_t *)\"hi\", .length = 2 });\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings("mn/stdout.h", files[2].path);
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"../runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nvoid mn_runtime_stdout_write(mn_slice_u8 text);\n",
        files[2].contents,
    );
    try std.testing.expectEqual(3, files.len);
    try std.testing.expectEqual(1, generator.runtime_functions.items.len);
    try std.testing.expectEqualStrings("mn_runtime_stdout_write", generator.runtime_functions.items[0]);
}

test "generateFiles: calls a standard library function that takes the empty tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\n\nconst write = mn_runtime_stdout_write\n\nfn println(text: []const u8, _: []):\n    write(text)\n    write(\"\\n\")\n" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main(): mn::stdout::println(\"hi\", {})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"mn/stdout.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_mn_stdout_println((mn_slice_u8){ .items = (uint8_t *)\"hi\", .length = 2 });\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"../runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nvoid mn_runtime_stdout_write(mn_slice_u8 text);\n\nvoid mn_mn_stdout_println(mn_slice_u8 text);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"stdout.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nvoid mn_mn_stdout_println(mn_slice_u8 text) {\n    mn_runtime_stdout_write(text);\n    mn_runtime_stdout_write((mn_slice_u8){ .items = (uint8_t *)\"\\n\", .length = 1 });\n}\n",
        files[3].contents,
    );
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn width() -> i32: return shapes::make().width" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn make() -> i32: return shapes::origin.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "first.mn", .data = "import second\nstruct One:\n    two: second::Two\nstruct Zero:\n    value: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "second.mn", .data = "import first\nstruct Two:\n    zero: first::Zero" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import first\nfn show(one: first::One): _ = one" });
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
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, generator.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import points\nstruct Line:\n    start: points::Point" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "points.mn", .data = "struct Point:\n    x: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import points\nimport colors\nstruct Line:\n    ends: [points::Point, colors::Color]" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "points.mn", .data = "struct Point:\n    x: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "colors.mn", .data = "struct Color:\n    red: u8" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generatePrototypeTags: declares the tags that pointers to functions in fields use" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node:\n    visit: *fn(Other, *Other) -> [i32, bool]\nstruct Other:\n    x: i32\nfn show(node: Node): _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateStruct: writes each instance of a struct without a name with its functions" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn List(type T) -> type:\n    return struct:\n        first: T\n        count: usize = 0\n        fn new(first: T) -> Self: return Self{first = first}\n        fn get(self: Self) -> T: return self.first\n        fn grow(self: *Self): self.count += 1\nfn make() -> List(u8): return {first = 2}\nfn main():\n    var numbers = List(i32)::new(1)\n    numbers.grow()\n    _ = numbers.get()\n    const flags = List(bool){first = true}\n    _ = flags.get()\n    _ = make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_List_1 {\n    uint8_t first;\n    size_t count;\n} mn_main_List_1;\n\ntypedef struct mn_main_List_2 {\n    int32_t first;\n    size_t count;\n} mn_main_List_2;\n\ntypedef struct mn_main_List_3 {\n    bool first;\n    size_t count;\n} mn_main_List_3;\n\nmn_main_List_1 mn_main_make();\nmn_main_List_1 mn_main_List_1_new(uint8_t first);\nuint8_t mn_main_List_1_get(mn_main_List_1 self);\nvoid mn_main_List_1_grow(struct mn_main_List_1 * self);\nmn_main_List_2 mn_main_List_2_new(int32_t first);\nint32_t mn_main_List_2_get(mn_main_List_2 self);\nvoid mn_main_List_2_grow(struct mn_main_List_2 * self);\nmn_main_List_3 mn_main_List_3_new(bool first);\nbool mn_main_List_3_get(mn_main_List_3 self);\nvoid mn_main_List_3_grow(struct mn_main_List_3 * self);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nmn_main_List_1 mn_main_make() {\n    return (mn_main_List_1){ .first = 2u, .count = 0u };\n}\n\nint main() {\n    mn_main_List_2 numbers = mn_main_List_2_new(1);\n    mn_main_List_2_grow(&numbers);\n    mn_main_List_2_get(numbers);\n    const mn_main_List_3 flags = (mn_main_List_3){ .first = true, .count = 0u };\n    mn_main_List_3_get(flags);\n    mn_main_make();\n}\n\nmn_main_List_1 mn_main_List_1_new(uint8_t first) {\n    return (mn_main_List_1){ .first = first, .count = 0u };\n}\n\nuint8_t mn_main_List_1_get(mn_main_List_1 self) {\n    return self.first;\n}\n\nvoid mn_main_List_1_grow(struct mn_main_List_1 * self) {\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &self->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n}\n\nmn_main_List_2 mn_main_List_2_new(int32_t first) {\n    return (mn_main_List_2){ .first = first, .count = 0u };\n}\n\nint32_t mn_main_List_2_get(mn_main_List_2 self) {\n    return self.first;\n}\n\nvoid mn_main_List_2_grow(struct mn_main_List_2 * self) {\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &self->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n}\n\nmn_main_List_3 mn_main_List_3_new(bool first) {\n    return (mn_main_List_3){ .first = first, .count = 0u };\n}\n\nbool mn_main_List_3_get(mn_main_List_3 self) {\n    return self.first;\n}\n\nvoid mn_main_List_3_grow(struct mn_main_List_3 * self) {\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &self->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n}\n",
        files[1].contents,
    );
}

test "generateStruct: writes a struct without a name that points to itself" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type:\n    return struct:\n        value: A\n        next: ?*Node(A)\nfn second(node: Node(i32)) -> ?*Node(i32): return node.next" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Node_1 {\n    int32_t value;\n    struct mn_main_Node_1 * next;\n} mn_main_Node_1;\n\nstruct mn_main_Node_1 * mn_main_second(mn_main_Node_1 node);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nstruct mn_main_Node_1 * mn_main_second(mn_main_Node_1 node) {\n    return node.next;\n}\n",
        files[1].contents,
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

test "generateEnumDefinition: writes an enum and error sets with their cases, equality and conversion to a combined set" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_file\n    missing_end\nenum Token:\n    number: i64\n    end\n    fn is_end(self: Self) -> bool: return self == Token::end\nfn widen(failure: FileError) -> ParseError || FileError: return failure\nfn is_missing(failure: ParseError || FileError) -> bool: return failure == ParseError::missing_end\nfn digit(value: u8) -> ParseError: return ParseError::bad_digit(value)\nfn number() -> Token: return Token::number(4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_ParseError {\n    uint32_t tag;\n    union {\n        uint8_t bad_digit;\n    } value;\n} mn_main_ParseError;\n\ntypedef struct mn_main_FileError {\n    uint32_t tag;\n} mn_main_FileError;\n\ntypedef struct mn_main_Token {\n    uint32_t tag;\n    union {\n        int64_t number;\n    } value;\n} mn_main_Token;\n\ntypedef struct mn_main_ParseError_or_main_FileError mn_main_ParseError_or_main_FileError;\n\nbool mn_main_Token_is_end(mn_main_Token self);\nmn_main_ParseError_or_main_FileError mn_main_widen(mn_main_FileError failure);\nbool mn_main_is_missing(mn_main_ParseError_or_main_FileError failure);\nmn_main_ParseError mn_main_digit(uint8_t value);\nmn_main_Token mn_main_number();\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_main_ParseError_or_main_FileError_defined\n#define mn_main_ParseError_or_main_FileError_defined\ntypedef struct mn_main_ParseError_or_main_FileError {\n    uint32_t tag;\n    union {\n        uint8_t main_ParseError_bad_digit;\n    } value;\n} mn_main_ParseError_or_main_FileError;\n#endif\n\n#ifndef mn_main_Token_equal_defined\n#define mn_main_Token_equal_defined\nstatic inline bool mn_main_Token_equal(mn_main_Token one, mn_main_Token two) {\n    if (one.tag != two.tag) return false;\n    switch (one.tag) {\n    case 0: return one.value.number == two.value.number;\n    default: return true;\n    }\n}\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_equal_defined\n#define mn_main_ParseError_or_main_FileError_equal_defined\nstatic inline bool mn_main_ParseError_or_main_FileError_equal(mn_main_ParseError_or_main_FileError one, mn_main_ParseError_or_main_FileError two) {\n    if (one.tag != two.tag) return false;\n    switch (one.tag) {\n    case 2: return one.value.main_ParseError_bad_digit == two.value.main_ParseError_bad_digit;\n    default: return true;\n    }\n}\n#endif\n\n#ifndef mn_main_ParseError_equal_defined\n#define mn_main_ParseError_equal_defined\nstatic inline bool mn_main_ParseError_equal(mn_main_ParseError one, mn_main_ParseError two) {\n    if (one.tag != two.tag) return false;\n    switch (one.tag) {\n    case 2: return one.value.bad_digit == two.value.bad_digit;\n    default: return true;\n    }\n}\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_from_main_FileError_defined\n#define mn_main_ParseError_or_main_FileError_from_main_FileError_defined\nstatic inline mn_main_ParseError_or_main_FileError mn_main_ParseError_or_main_FileError_from_main_FileError(mn_main_FileError value) {\n    mn_main_ParseError_or_main_FileError result;\n    result.tag = value.tag;\n    return result;\n}\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_from_main_ParseError_defined\n#define mn_main_ParseError_or_main_FileError_from_main_ParseError_defined\nstatic inline mn_main_ParseError_or_main_FileError mn_main_ParseError_or_main_FileError_from_main_ParseError(mn_main_ParseError value) {\n    mn_main_ParseError_or_main_FileError result;\n    result.tag = value.tag;\n    switch (value.tag) {\n    case 2: result.value.main_ParseError_bad_digit = value.value.bad_digit; break;\n    default: break;\n    }\n    return result;\n}\n#endif\n\nbool mn_main_Token_is_end(mn_main_Token self) {\n    return mn_main_Token_equal(self, (mn_main_Token){ .tag = 1 });\n}\n\nmn_main_ParseError_or_main_FileError mn_main_widen(mn_main_FileError failure) {\n    return mn_main_ParseError_or_main_FileError_from_main_FileError(failure);\n}\n\nbool mn_main_is_missing(mn_main_ParseError_or_main_FileError failure) {\n    return mn_main_ParseError_or_main_FileError_equal(failure, mn_main_ParseError_or_main_FileError_from_main_ParseError((mn_main_ParseError){ .tag = 1 }));\n}\n\nmn_main_ParseError mn_main_digit(uint8_t value) {\n    return (mn_main_ParseError){ .tag = 2, .value.bad_digit = value };\n}\n\nmn_main_Token mn_main_number() {\n    return (mn_main_Token){ .tag = 0, .value.number = 4 };\n}\n",
        files[1].contents,
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(line: shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(line: *shapes::Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateDeclarations: leaves out functions and constants that hold types" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type: return i32\nconst kinds = [2]type{i32, bool}\nconst Kind = Number()\nfn first(value: kinds[1], other: Kind) -> Kind:\n    _ = value\n    return other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nint32_t mn_main_first(bool, int32_t other);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_first(bool, int32_t other) {\n    return other;\n}\n",
        files[1].contents,
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, [bool, u8]]: return {1, {true, 2}}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make() -> [Marker, i32]: return {Marker{}, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateTupleDefinition: defines a tuple of one element" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32]: return {1}\nfn first(single: [i32]) -> i32: return single[0]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_1_i32_defined\n#define mn_tuple_1_i32_defined\ntypedef struct mn_tuple_1_i32 {\n    int32_t _0;\n} mn_tuple_1_i32;\n#endif\n\nmn_tuple_1_i32 mn_main_make() {\n    return (mn_tuple_1_i32){ ._0 = 1 };\n}\n\nint32_t mn_main_first(mn_tuple_1_i32 single) {\n    return single._0;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import other\nfn main(): _ = other::locate(other::Marker{})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateConstantDefinition: writes a constant computed by calls from its value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn square(value: i32) -> i32: return value * value\nconst NINE = square(3)\nconst TABLE = [2]i32{square(2), NINE}\nfn read() -> i32: return NINE + TABLE[1]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nconst mn_array_2_i32 mn_main_TABLE = { .items = { 4, 9 } };\n\nint32_t mn_main_square(int32_t value) {\n    return (value * value);\n}\n\nint32_t mn_main_read() {\n    return (9 + mn_main_TABLE.items[1u]);\n}\n",
        files[1].contents,
    );
}

test "generateStatics: writes a slice of a compile-time array as static data" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> []const i32:\n    const values = [3]i32{1, 2, 3}\n    return values[1..]\nconst TAIL = make()\nfn read() -> []const i32: return TAIL" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nstatic mn_array_3_i32 mn_static_1;\nstatic mn_array_3_i32 mn_static_1 = { .items = { 1, 2, 3 } };\n\nconst mn_slice_i32 mn_main_TAIL = { .items = (int32_t *)(mn_static_1.items + 1), .length = 2 };\n\nmn_slice_i32 mn_main_make() {\n    const mn_array_3_i32 values = (mn_array_3_i32){ .items = { 1, 2, 3 } };\n    return (mn_slice_i32){ .items = (int32_t *)values.items + 1u, .length = 3 - 1u };\n}\n\nmn_slice_i32 mn_main_read() {\n    return mn_main_TAIL;\n}\n",
        files[1].contents,
    );
}

test "generateStatics: points into a compile-time array as static data" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(text: []const u8) -> *const u8: return &text[1]\nconst SECOND = second(\"abc\")\nfn read() -> u8: return SECOND.*" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\n#ifndef mn_array_3_u8_defined\n#define mn_array_3_u8_defined\ntypedef struct mn_array_3_u8 {\n    uint8_t items[3];\n} mn_array_3_u8;\n#endif\n\nstatic mn_array_3_u8 mn_static_1;\nstatic mn_array_3_u8 mn_static_1 = { .items = { 97u, 98u, 99u } };\n\nuint8_t const * const mn_main_SECOND = ((uint8_t const *)&mn_static_1.items[1]);\n\nuint8_t const * mn_main_second(mn_slice_u8 text) {\n    return &text.items[1u];\n}\n\nuint8_t mn_main_read() {\n    return (*mn_main_SECOND);\n}\n",
        files[1].contents,
    );
}

test "generateStatics: points into a constant instead of a copy" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const VALUES = [2]i32{1, 2}\nconst SECOND = &VALUES[1]\nfn read() -> i32: return SECOND.*" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nconst mn_array_2_i32 mn_main_VALUES = { .items = { 1, 2 } };\nint32_t const * const mn_main_SECOND = ((int32_t const *)&mn_main_VALUES.items[1]);\n\nint32_t mn_main_read() {\n    return (*mn_main_SECOND);\n}\n",
        files[1].contents,
    );
}

test "generateStatics: writes floats exactly and strings as text" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const THIRD = 1f32 / 3f32\nconst HUGE = 1f64 / 0f64\nconst NAME = \"a\\tb\"\nfn third() -> f32: return THIRD\nfn huge() -> f64: return HUGE\nfn name() -> []const u8: return NAME" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_u8_defined\n#define mn_slice_u8_defined\ntypedef struct mn_slice_u8 {\n    uint8_t *items;\n    size_t length;\n} mn_slice_u8;\n#endif\n\nconst mn_slice_u8 mn_main_NAME = { .items = (uint8_t *)\"a\\011b\", .length = 3 };\n\nfloat mn_main_third() {\n    return 0x1.555556p-2f;\n}\n\ndouble mn_main_huge() {\n    return __builtin_inf();\n}\n\nmn_slice_u8 mn_main_name() {\n    return mn_main_NAME;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main(): while false: shapes::draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/clock.mn", .data = "struct Time:\n    seconds: i64\nexternal fn mn_runtime_clock_now() -> Time\nconst now = mn_runtime_clock_now" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn seconds() -> i64: return mn::clock::now().seconds" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import numbers\nfn two() -> i32: return -numbers::one() + 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import geometry\nstruct Options:\n    size: geometry::Size = geometry::Size{width = 1}\nfn draw(options: Options): _ = options" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main(): shapes::draw(shapes::Options{})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn widen(line: *shapes::Line): line.width = 2" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn advance(lines: *many shapes::Line, count: usize) -> *many shapes::Line: return count + lines" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn width(line: *const shapes::Line) -> i32: return line.width" });
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

test "recordModule: includes the header of a stored slice constant of another module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import data\nfn take(values: []const i32): _ = values\nfn main(): take(data::items)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"data.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(mn_slice_i32) {}\n\nint main() {\n    mn_main_take(mn_data_items);\n}\n",
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

test "generateFunction: writes each instance of a function with a type parameter" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn max(type T, a: T, b: T) -> T:\n    if a > b: return a\n    return b\nfn main():\n    _ = max(i32, 1, 2)\n    _ = max(u8, 3, 4)\n    _ = max(i32, 5, 6)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_main_max_1(1, 2);\n    mn_main_max_2(3u, 4u);\n    mn_main_max_1(5, 6);\n}\n\nint32_t mn_main_max_1(int32_t a, int32_t b) {\n    if ((a > b)) {\n        return a;\n    }\n    return b;\n}\n\nuint8_t mn_main_max_2(uint8_t a, uint8_t b) {\n    if ((a > b)) {\n        return a;\n    }\n    return b;\n}\n",
        files[1].contents,
    );
}

test "generateFunction: writes each instance of a function with a comptime parameter" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn scale(comptime factor: i32, value: i32) -> i32: return value * factor\nfn main():\n    _ = scale(2, 5)\n    _ = scale(3, 5)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_main_scale_1(5);\n    mn_main_scale_2(5);\n}\n\nint32_t mn_main_scale_1(int32_t value) {\n    return (value * 2);\n}\n\nint32_t mn_main_scale_2(int32_t value) {\n    return (value * 3);\n}\n",
        files[1].contents,
    );
}

test "generateFunction: generates a default for each instance that uses it" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32: return self.area() * 2\n    fn unit() -> T\n    fn twice() -> i32: return Shape(T)::unit().double()\nstruct Square:\n    side: i32\nstruct Circle:\n    radius: i32\ninstance Shape(Square):\n    fn area(self: Square) -> i32: return self.side * self.side\n    fn unit() -> Square: return Square{side = 1}\ninstance Shape(Circle):\n    fn area(self: Circle) -> i32: return self.radius * 3\n    fn unit() -> Circle: return Circle{radius = 1}\n    fn double(self: Circle) -> i32: return self.radius\nfn main():\n    const square = Square{side = 2}\n    _ = square.double()\n    _ = Shape(Square)::twice()\n    _ = Shape(Circle)::twice()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Square_Shape_area(mn_main_Square self) {\n    return (self.side * self.side);\n}\n\nmn_main_Square mn_main_Square_Shape_unit() {\n    return (mn_main_Square){ .side = 1 };\n}\n\nint32_t mn_main_Circle_Shape_area(mn_main_Circle self) {\n    return (self.radius * 3);\n}\n\nmn_main_Circle mn_main_Circle_Shape_unit() {\n    return (mn_main_Circle){ .radius = 1 };\n}\n\nint32_t mn_main_Circle_Shape_double(mn_main_Circle self) {\n    return self.radius;\n}\n\nint main() {\n    const mn_main_Square square = (mn_main_Square){ .side = 2 };\n    mn_main_Square_Shape_double(square);\n    mn_main_Square_Shape_twice();\n    mn_main_Circle_Shape_twice();\n}\n\nint32_t mn_main_Square_Shape_double(mn_main_Square self) {\n    return (mn_main_Square_Shape_area(self) * 2);\n}\n\nint32_t mn_main_Square_Shape_twice() {\n    return mn_main_Square_Shape_double(mn_main_Square_Shape_unit());\n}\n\nint32_t mn_main_Circle_Shape_twice() {\n    return mn_main_Circle_Shape_double(mn_main_Circle_Shape_unit());\n}\n",
        files[1].contents,
    );
}

test "generateFunction: generates a default in the module of the instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn scale() -> i32: return 2\ntypeclass Shape(type T):\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32: return self.area() * scale()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nimport shapes::Shape\nstruct Square:\n    side: i32\ninstance Shape(Square):\n    fn area(self: Square) -> i32: return self.side\nfn main():\n    const square = Square{side = 2}\n    _ = square.double()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Square {\n    int32_t side;\n} mn_main_Square;\n\nint32_t mn_main_Square_Shape_area(mn_main_Square self);\nint32_t mn_main_Square_Shape_double(mn_main_Square self);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"shapes.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Square_Shape_area(mn_main_Square self) {\n    return self.side;\n}\n\nint main() {\n    const mn_main_Square square = (mn_main_Square){ .side = 2 };\n    mn_main_Square_Shape_double(square);\n}\n\nint32_t mn_main_Square_Shape_double(mn_main_Square self) {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    return (mn_temporary_1 = mn_main_Square_Shape_area(self), mn_temporary_2 = mn_shapes_scale(), (mn_temporary_1 * mn_temporary_2));\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\nint32_t mn_shapes_scale();\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"shapes.h\"\n\nint32_t mn_shapes_scale() {\n    return 2;\n}\n",
        files[3].contents,
    );
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateParameters: leaves out parameters of the empty tuple type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(empty: [], value: i32):\n    _ = empty\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateParameters: leaves out the name of a parameter discarded in a for loop" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32):\n    for _ in 0..3:\n        _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_show(int32_t) {\n    for (size_t mn_index_1 = 0; mn_index_1 < 3u; mn_index_1 += 1) {}\n}\n",
        files[1].contents,
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

test "generateStatements: runs deferred statements at every way out of their block" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error Failure:\n    bad\nfn close(): noop\nfn note(value: i32): _ = value\nfn inner(fail: bool) -> Failure!i32:\n    if fail: return Failure::bad\n    return 1\nfn step(fail: bool) -> Failure!i32:\n    errdefer note(1)\n    defer close()\n    const value = try inner(fail)\n    return value + 1\nfn count() -> i32:\n    var total: i32 = 0\n    while total < 5:\n        defer note(total)\n        total += 1\n        if total == 2: continue\n        if total == 4: break\n    return total\nfn plain():\n    defer close()\n    note(2)\nfn pass(fail: bool) -> Failure!i32:\n    errdefer note(3)\n    return inner(fail)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Failure {\n    uint32_t tag;\n} mn_main_Failure;\n\ntypedef struct mn_result_main_Failure_i32 mn_result_main_Failure_i32;\n\nvoid mn_main_close();\nvoid mn_main_note(int32_t);\nmn_result_main_Failure_i32 mn_main_inner(bool fail);\nmn_result_main_Failure_i32 mn_main_step(bool fail);\nint32_t mn_main_count();\nvoid mn_main_plain();\nmn_result_main_Failure_i32 mn_main_pass(bool fail);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_result_main_Failure_i32_defined\n#define mn_result_main_Failure_i32_defined\ntypedef struct mn_result_main_Failure_i32 {\n    mn_main_Failure error;\n    int32_t value;\n} mn_result_main_Failure_i32;\n#endif\n\nvoid mn_main_close() {}\n\nvoid mn_main_note(int32_t) {}\n\nmn_result_main_Failure_i32 mn_main_inner(bool fail) {\n    if (fail) {\n        return (mn_result_main_Failure_i32){ .error = (mn_main_Failure){ .tag = 1 } };\n    }\n    return (mn_result_main_Failure_i32){ .error.tag = 0, .value = 1 };\n}\n\nmn_result_main_Failure_i32 mn_main_step(bool fail) {\n    mn_result_main_Failure_i32 mn_temporary_1;\n    int32_t mn_temporary_2;\n    mn_temporary_1 = mn_main_inner(fail);\n    if (mn_temporary_1.error.tag != 0) {\n        mn_main_close();\n        mn_main_note(1);\n        return (mn_result_main_Failure_i32){ .error = mn_temporary_1.error };\n    }\n    mn_temporary_2 = mn_temporary_1.value;\n    const int32_t value = mn_temporary_2;\n    const mn_result_main_Failure_i32 mn_returned = (mn_result_main_Failure_i32){ .error.tag = 0, .value = (value + 1) };\n    mn_main_close();\n    return mn_returned;\n}\n\nint32_t mn_main_count() {\n    int32_t total = 0;\n    while ((total < 5)) {\n        total = (total + 1);\n        if ((total == 2)) {\n            mn_main_note(total);\n            continue;\n        }\n        if ((total == 4)) {\n            mn_main_note(total);\n            break;\n        }\n        mn_main_note(total);\n    }\n    return total;\n}\n\nvoid mn_main_plain() {\n    mn_main_note(2);\n    mn_main_close();\n}\n\nmn_result_main_Failure_i32 mn_main_pass(bool fail) {\n    const mn_result_main_Failure_i32 mn_returned = mn_main_inner(fail);\n    if (mn_returned.error.tag != 0) {\n        mn_main_note(3);\n    }\n    return mn_returned;\n}\n",
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

test "generateLocal: writes nothing for a constant of the empty tuple type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const empty: [] = {}\n    const typed = []{}\n    _ = empty\n    _ = typed" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateLocal: writes nothing for local constants that hold types" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type: return i32\nfn main():\n    const kind = Number()\n    const kinds = [2]type{kind, bool}\n    var value: kinds[0] = 1\n    value += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t value = 1;\n    value = (value + 1);\n}\n",
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

test "generateTupleDeclaration: reads the elements of a name in place" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn show(pair: [i32, bool]):\n    const (number, flag) = pair\n    take(number)\n    check(flag)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nvoid mn_main_show(mn_tuple_2_i32_bool pair) {\n    const int32_t number = pair._0;\n    const bool flag = pair._1;\n    take(number);\n    check(flag);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: evaluates a call once before taking it apart" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn make() -> [i32, bool]: return {1, true}\nfn main():\n    const (number, flag) = make()\n    take(number)\n    check(flag)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nmn_tuple_2_i32_bool mn_main_make() {\n    return (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true };\n}\n\nint main() {\n    const mn_tuple_2_i32_bool mn_tuple_value_1 = mn_main_make();\n    const int32_t number = mn_tuple_value_1._0;\n    const bool flag = mn_tuple_value_1._1;\n    take(number);\n    check(flag);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: points to the elements of a variable" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn main():\n    var pair = [i32, bool]{1, true}\n    const (*number, flag) = pair\n    number.* = 2\n    check(flag)\n    take(pair[0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_tuple_2_i32_bool pair = (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true };\n    int32_t * const number = &pair._0;\n    const bool flag = pair._1;\n    (*number) = 2;\n    check(flag);\n    take(pair._0);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: stores the address of a value that is not a name once" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nstruct Holder:\n    pair: [i32, bool]\nfn main():\n    var holder = Holder{pair = {1, true}}\n    const (*number, flag) = holder.pair\n    number.* = 2\n    check(flag)\n    take(holder.pair[0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_main_Holder holder = (mn_main_Holder){ .pair = (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true } };\n    struct mn_tuple_2_i32_bool * const mn_tuple_value_1 = &holder.pair;\n    int32_t * const number = &mn_tuple_value_1->_0;\n    const bool flag = mn_tuple_value_1->_1;\n    (*number) = 2;\n    check(flag);\n    take(holder.pair._0);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: evaluates the address of an element whose index has a call once" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn next() -> usize: return 0\nfn main():\n    var pairs = [2][i32, bool]{{1, true}, {2, false}}\n    const (*number, _) = pairs[next()]\n    number.* = 3\n    take(pairs[0][0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\n#ifndef mn_array_2_tuple_2_i32_bool_defined\n#define mn_array_2_tuple_2_i32_bool_defined\ntypedef struct mn_array_2_tuple_2_i32_bool {\n    mn_tuple_2_i32_bool items[2];\n} mn_array_2_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nsize_t mn_main_next() {\n    return 0u;\n}\n\nint main() {\n    mn_array_2_tuple_2_i32_bool pairs = (mn_array_2_tuple_2_i32_bool){ .items = { (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true }, (mn_tuple_2_i32_bool){ ._0 = 2, ._1 = false } } };\n    struct mn_tuple_2_i32_bool * const mn_tuple_value_1 = &pairs.items[mn_main_next()];\n    int32_t * const number = &mn_tuple_value_1->_0;\n    (*number) = 3;\n    take(pairs.items[0u]._0);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: writes only the calls when no name is declared" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {1, true}\nfn main():\n    const (_, _) = make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nmn_tuple_2_i32_bool mn_main_make() {\n    return (mn_tuple_2_i32_bool){ ._0 = 1, ._1 = true };\n}\n\nint main() {\n    mn_main_make();\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: points a pointer name to a zero-sized element at the shared object" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn keep(marker: *const Marker)\nfn show(pair: [Marker, i32]):\n    const (*marker, _) = pair\n    keep(marker)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_main_Marker_i32_defined\n#define mn_tuple_2_main_Marker_i32_defined\ntypedef struct mn_tuple_2_main_Marker_i32 {\n    int32_t _1;\n} mn_tuple_2_main_Marker_i32;\n#endif\n\nvoid mn_main_show(mn_tuple_2_main_Marker_i32 pair) {\n    void const * const marker = ((void const *)&mn_zero_sized);\n    keep(marker);\n}\n",
        files[1].contents,
    );
}

test "generateTupleDeclaration: stores a constant whose element a pointer name points to" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pair = [i32, bool]{1, true}\nexternal fn keep(value: *const i32)\nfn main():\n    const (*number, _) = pair\n    keep(number)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nchar mn_zero_sized;\n\nconst mn_tuple_2_i32_bool mn_main_pair = { ._0 = 1, ._1 = true };\n\nint main() {\n    int32_t const * const number = &mn_main_pair._0;\n    keep(number);\n}\n",
        files[1].contents,
    );
}

test "generateMatch: writes a switch on the tag that binds the values of the cases" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token:\n    number: i64\n    flag: bool\n    end\n    other\nerror ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_end\nfn total(token: Token) -> i64:\n    match token:\n        number(digits): return digits\n        flag, end: return 1\n        else: return 0\nfn bump(token: *Token):\n    match token.*:\n        number(*digits): digits.* += 1\n        flag(_): noop\n        end, other: noop\nfn sum(tokens: []const Token) -> i64:\n    var result: i64 = 0\n    for token in tokens:\n        match token:\n            end: break\n            other: continue\n            number(digits): result += digits\n            flag: noop\n    return result\nfn first(tokens: []const Token) -> i64:\n    match tokens[0]:\n        number(digits): return digits\n        else: return 0\nfn code(failure: ParseError || FileError) -> u8:\n    match failure:\n        ParseError::missing_end: return 1\n        FileError::missing_end: return 2\n        bad_digit(digit): return digit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Token {\n    uint32_t tag;\n    union {\n        int64_t number;\n        bool flag;\n    } value;\n} mn_main_Token;\n\ntypedef struct mn_main_ParseError {\n    uint32_t tag;\n    union {\n        uint8_t bad_digit;\n    } value;\n} mn_main_ParseError;\n\ntypedef struct mn_main_FileError {\n    uint32_t tag;\n} mn_main_FileError;\n\ntypedef struct mn_slice_main_Token mn_slice_main_Token;\ntypedef struct mn_main_ParseError_or_main_FileError mn_main_ParseError_or_main_FileError;\n\nint64_t mn_main_total(mn_main_Token token);\nvoid mn_main_bump(struct mn_main_Token * token);\nint64_t mn_main_sum(mn_slice_main_Token tokens);\nint64_t mn_main_first(mn_slice_main_Token tokens);\nuint8_t mn_main_code(mn_main_ParseError_or_main_FileError failure);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Token_defined\n#define mn_slice_main_Token_defined\ntypedef struct mn_slice_main_Token {\n    struct mn_main_Token *items;\n    size_t length;\n} mn_slice_main_Token;\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_defined\n#define mn_main_ParseError_or_main_FileError_defined\ntypedef struct mn_main_ParseError_or_main_FileError {\n    uint32_t tag;\n    union {\n        uint8_t main_ParseError_bad_digit;\n    } value;\n} mn_main_ParseError_or_main_FileError;\n#endif\n\nint64_t mn_main_total(mn_main_Token token) {\n    switch (token.tag) {\n    case 0: {\n        const int64_t digits = token.value.number;\n        return digits;\n    }\n    case 1:\n    case 2: {\n        return 1;\n    }\n    default: {\n        return 0;\n    }\n    }\n}\n\nvoid mn_main_bump(struct mn_main_Token * token) {\n    struct mn_main_Token * const mn_match_value_1 = &(*token);\n    switch (mn_match_value_1->tag) {\n    case 0: {\n        int64_t * const digits = &mn_match_value_1->value.number;\n        int64_t * mn_temporary_1;\n        mn_temporary_1 = &(*digits), (*mn_temporary_1) = ((*mn_temporary_1) + 1);\n        break;\n    }\n    case 1: break;\n    default: break;\n    }\n}\n\nint64_t mn_main_sum(mn_slice_main_Token tokens) {\n    int64_t result = 0;\n    for (size_t mn_index_1 = 0; mn_index_1 < tokens.length; mn_index_1 += 1) {\n        const mn_main_Token token = tokens.items[mn_index_1];\n        switch (token.tag) {\n        case 2: {\n            goto mn_break_1;\n        }\n        case 3: {\n            goto mn_continue_1;\n        }\n        case 0: {\n            const int64_t digits = token.value.number;\n            result = (result + digits);\n            break;\n        }\n        default: break;\n        }\n        mn_continue_1:;\n    }\n    mn_break_1:;\n    return result;\n}\n\nint64_t mn_main_first(mn_slice_main_Token tokens) {\n    const mn_main_Token mn_match_value_1 = tokens.items[0u];\n    switch (mn_match_value_1.tag) {\n    case 0: {\n        const int64_t digits = mn_match_value_1.value.number;\n        return digits;\n    }\n    default: {\n        return 0;\n    }\n    }\n}\n\nuint8_t mn_main_code(mn_main_ParseError_or_main_FileError failure) {\n    switch (failure.tag) {\n    case 1: {\n        return 1u;\n    }\n    case 3: {\n        return 2u;\n    }\n    default: {\n        const uint8_t digit = failure.value.main_ParseError_bad_digit;\n        return digit;\n    }\n    }\n}\n",
        files[1].contents,
    );
}

test "generateBranch: points into a constant and a zero-sized value and leaves loops with goto" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token:\n    number: i64\n    empty: [0]u8\n    end\nconst ORIGIN = Token::number(7)\nfn make() -> Token: return Token::end\nfn origin() -> i64:\n    match ORIGIN:\n        number(*digits): return digits.*\n        else: return 0\nfn kind() -> i64:\n    match make():\n        number: return 1\n        else: return 0\nfn take(bytes: *const [0]u8): _ = bytes\nfn hollow(token: Token):\n    match token:\n        empty(*bytes): take(bytes)\n        else: noop\nfn scan(tokens: []const Token) -> i64:\n    var count: i64 = 0\n    while count < 10:\n        for token in tokens:\n            match token:\n                end: break\n                else: match make():\n                    number(digits): count += digits\n                    else: continue\n    else: count = 1\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Token {\n    uint32_t tag;\n    union {\n        int64_t number;\n    } value;\n} mn_main_Token;\n\ntypedef struct mn_slice_main_Token mn_slice_main_Token;\n\nmn_main_Token mn_main_make();\nint64_t mn_main_origin();\nint64_t mn_main_kind();\nvoid mn_main_take(void const *);\nvoid mn_main_hollow(mn_main_Token token);\nint64_t mn_main_scan(mn_slice_main_Token tokens);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Token_defined\n#define mn_slice_main_Token_defined\ntypedef struct mn_slice_main_Token {\n    struct mn_main_Token *items;\n    size_t length;\n} mn_slice_main_Token;\n#endif\n\nmn_main_Token mn_main_make() {\n    return (mn_main_Token){ .tag = 2 };\n}\n\nint64_t mn_main_origin() {\n    switch ((mn_main_Token){ .tag = 0, .value = { .number = 7 } }.tag) {\n    case 0: {\n        int64_t const * const digits = &(mn_main_Token){ .tag = 0, .value = { .number = 7 } }.value.number;\n        return (*digits);\n    }\n    default: {\n        return 0;\n    }\n    }\n}\n\nint64_t mn_main_kind() {\n    switch (mn_main_make().tag) {\n    case 0: {\n        return 1;\n    }\n    default: {\n        return 0;\n    }\n    }\n}\n\nvoid mn_main_take(void const *) {}\n\nvoid mn_main_hollow(mn_main_Token token) {\n    switch (token.tag) {\n    case 1: {\n        void const * const bytes = ((void const *)&mn_zero_sized);\n        mn_main_take(bytes);\n        break;\n    }\n    default: break;\n    }\n}\n\nint64_t mn_main_scan(mn_slice_main_Token tokens) {\n    int64_t count = 0;\n    while ((count < 10)) {\n        for (size_t mn_index_2 = 0; mn_index_2 < tokens.length; mn_index_2 += 1) {\n            const mn_main_Token token = tokens.items[mn_index_2];\n            switch (token.tag) {\n            case 2: {\n                goto mn_break_2;\n            }\n            default: {\n                const mn_main_Token mn_match_value_2 = mn_main_make();\n                switch (mn_match_value_2.tag) {\n                case 0: {\n                    const int64_t digits = mn_match_value_2.value.number;\n                    count = (count + digits);\n                    break;\n                }\n                default: {\n                    goto mn_continue_2;\n                }\n                }\n            }\n            }\n            mn_continue_2:;\n        }\n        mn_break_2:;\n    }\n    count = 1;\n    return count;\n}\n",
        files[1].contents,
    );
}

test "generateTry: returns the error of a result from the function and converts it to the function's set" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_file\nfn digit(text: u8) -> ParseError!u8:\n    if text < 48: return ParseError::bad_digit(text)\n    return text - 48\nfn check(text: u8) -> ParseError!void:\n    if text == 0: return ParseError::missing_end\nfn total(one: u8, two: u8) -> ParseError || FileError!u8:\n    try check(one)\n    return try digit(one) + try digit(two)\nfn safe(text: u8) -> u8: return digit(text) catch 0\nfn widen(text: u8) -> ParseError || FileError!u8: return digit(text)\nfn ready(text: u8) -> ParseError!bool: return text > 0\nfn count(text: u8) -> ParseError!u8:\n    var result: u8 = 0\n    while try ready(text - result): result += 1\n    if text > 9 and try ready(text): return 1\n    else if try ready(text): return 2\n    return result\nfn fallback(text: u8) -> ParseError!u8: return digit(text) catch try digit(48)\nfn run() -> ParseError || FileError!void:\n    _ = try total(49, 50)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_ParseError {\n    uint32_t tag;\n    union {\n        uint8_t bad_digit;\n    } value;\n} mn_main_ParseError;\n\ntypedef struct mn_main_FileError {\n    uint32_t tag;\n} mn_main_FileError;\n\ntypedef struct mn_result_main_ParseError_u8 mn_result_main_ParseError_u8;\ntypedef struct mn_result_main_ParseError_void mn_result_main_ParseError_void;\ntypedef struct mn_result_main_ParseError_or_main_FileError_u8 mn_result_main_ParseError_or_main_FileError_u8;\ntypedef struct mn_result_main_ParseError_bool mn_result_main_ParseError_bool;\ntypedef struct mn_result_main_ParseError_or_main_FileError_void mn_result_main_ParseError_or_main_FileError_void;\n\nmn_result_main_ParseError_u8 mn_main_digit(uint8_t text);\nmn_result_main_ParseError_void mn_main_check(uint8_t text);\nmn_result_main_ParseError_or_main_FileError_u8 mn_main_total(uint8_t one, uint8_t two);\nuint8_t mn_main_safe(uint8_t text);\nmn_result_main_ParseError_or_main_FileError_u8 mn_main_widen(uint8_t text);\nmn_result_main_ParseError_bool mn_main_ready(uint8_t text);\nmn_result_main_ParseError_u8 mn_main_count(uint8_t text);\nmn_result_main_ParseError_u8 mn_main_fallback(uint8_t text);\nmn_result_main_ParseError_or_main_FileError_void mn_main_run();\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_result_main_ParseError_u8_defined\n#define mn_result_main_ParseError_u8_defined\ntypedef struct mn_result_main_ParseError_u8 {\n    mn_main_ParseError error;\n    uint8_t value;\n} mn_result_main_ParseError_u8;\n#endif\n\n#ifndef mn_result_main_ParseError_void_defined\n#define mn_result_main_ParseError_void_defined\ntypedef struct mn_result_main_ParseError_void {\n    mn_main_ParseError error;\n} mn_result_main_ParseError_void;\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_defined\n#define mn_main_ParseError_or_main_FileError_defined\ntypedef struct mn_main_ParseError_or_main_FileError {\n    uint32_t tag;\n    union {\n        uint8_t main_ParseError_bad_digit;\n    } value;\n} mn_main_ParseError_or_main_FileError;\n#endif\n\n#ifndef mn_result_main_ParseError_or_main_FileError_u8_defined\n#define mn_result_main_ParseError_or_main_FileError_u8_defined\ntypedef struct mn_result_main_ParseError_or_main_FileError_u8 {\n    mn_main_ParseError_or_main_FileError error;\n    uint8_t value;\n} mn_result_main_ParseError_or_main_FileError_u8;\n#endif\n\n#ifndef mn_result_main_ParseError_bool_defined\n#define mn_result_main_ParseError_bool_defined\ntypedef struct mn_result_main_ParseError_bool {\n    mn_main_ParseError error;\n    bool value;\n} mn_result_main_ParseError_bool;\n#endif\n\n#ifndef mn_result_main_ParseError_or_main_FileError_void_defined\n#define mn_result_main_ParseError_or_main_FileError_void_defined\ntypedef struct mn_result_main_ParseError_or_main_FileError_void {\n    mn_main_ParseError_or_main_FileError error;\n} mn_result_main_ParseError_or_main_FileError_void;\n#endif\n\n#ifndef mn_main_ParseError_or_main_FileError_from_main_ParseError_defined\n#define mn_main_ParseError_or_main_FileError_from_main_ParseError_defined\nstatic inline mn_main_ParseError_or_main_FileError mn_main_ParseError_or_main_FileError_from_main_ParseError(mn_main_ParseError value) {\n    mn_main_ParseError_or_main_FileError result;\n    result.tag = value.tag;\n    switch (value.tag) {\n    case 2: result.value.main_ParseError_bad_digit = value.value.bad_digit; break;\n    default: break;\n    }\n    return result;\n}\n#endif\n\n#ifndef mn_result_main_ParseError_or_main_FileError_u8_from_result_main_ParseError_u8_defined\n#define mn_result_main_ParseError_or_main_FileError_u8_from_result_main_ParseError_u8_defined\nstatic inline mn_result_main_ParseError_or_main_FileError_u8 mn_result_main_ParseError_or_main_FileError_u8_from_result_main_ParseError_u8(mn_result_main_ParseError_u8 value) {\n    mn_result_main_ParseError_or_main_FileError_u8 result;\n    result.error = mn_main_ParseError_or_main_FileError_from_main_ParseError(value.error);\n    result.value = value.value;\n    return result;\n}\n#endif\n\nmn_result_main_ParseError_u8 mn_main_digit(uint8_t text) {\n    if ((text < 48u)) {\n        return (mn_result_main_ParseError_u8){ .error = (mn_main_ParseError){ .tag = 2, .value.bad_digit = text } };\n    }\n    return (mn_result_main_ParseError_u8){ .error.tag = 0, .value = ((uint8_t)(text - 48u)) };\n}\n\nmn_result_main_ParseError_void mn_main_check(uint8_t text) {\n    if ((text == 0u)) {\n        return (mn_result_main_ParseError_void){ .error = (mn_main_ParseError){ .tag = 1 } };\n    }\n    return (mn_result_main_ParseError_void){ .error.tag = 0 };\n}\n\nmn_result_main_ParseError_or_main_FileError_u8 mn_main_total(uint8_t one, uint8_t two) {\n    mn_result_main_ParseError_void mn_temporary_1;\n    mn_temporary_1 = mn_main_check(one);\n    if (mn_temporary_1.error.tag != 0) return (mn_result_main_ParseError_or_main_FileError_u8){ .error = mn_main_ParseError_or_main_FileError_from_main_ParseError(mn_temporary_1.error) };\n    mn_result_main_ParseError_u8 mn_temporary_2;\n    uint8_t mn_temporary_3;\n    mn_result_main_ParseError_u8 mn_temporary_4;\n    uint8_t mn_temporary_5;\n    mn_temporary_2 = mn_main_digit(one);\n    if (mn_temporary_2.error.tag != 0) return (mn_result_main_ParseError_or_main_FileError_u8){ .error = mn_main_ParseError_or_main_FileError_from_main_ParseError(mn_temporary_2.error) };\n    mn_temporary_3 = mn_temporary_2.value;\n    mn_temporary_4 = mn_main_digit(two);\n    if (mn_temporary_4.error.tag != 0) return (mn_result_main_ParseError_or_main_FileError_u8){ .error = mn_main_ParseError_or_main_FileError_from_main_ParseError(mn_temporary_4.error) };\n    mn_temporary_5 = mn_temporary_4.value;\n    return (mn_result_main_ParseError_or_main_FileError_u8){ .error.tag = 0, .value = ((uint8_t)(mn_temporary_3 + mn_temporary_5)) };\n}\n\nuint8_t mn_main_safe(uint8_t text) {\n    mn_result_main_ParseError_u8 mn_temporary_1;\n    return (mn_temporary_1 = mn_main_digit(text), (mn_temporary_1.error.tag == 0 ? mn_temporary_1.value : 0u));\n}\n\nmn_result_main_ParseError_or_main_FileError_u8 mn_main_widen(uint8_t text) {\n    return mn_result_main_ParseError_or_main_FileError_u8_from_result_main_ParseError_u8(mn_main_digit(text));\n}\n\nmn_result_main_ParseError_bool mn_main_ready(uint8_t text) {\n    return (mn_result_main_ParseError_bool){ .error.tag = 0, .value = (text > 0u) };\n}\n\nmn_result_main_ParseError_u8 mn_main_count(uint8_t text) {\n    uint8_t result = 0u;\n    mn_result_main_ParseError_bool mn_temporary_1;\n    bool mn_temporary_2;\n    while (true) {\n        mn_temporary_1 = mn_main_ready(((uint8_t)(text - result)));\n        if (mn_temporary_1.error.tag != 0) return (mn_result_main_ParseError_u8){ .error = mn_temporary_1.error };\n        mn_temporary_2 = mn_temporary_1.value;\n        if (!mn_temporary_2) break;\n        {\n            result = ((uint8_t)(result + 1u));\n        }\n    }\n    bool mn_temporary_3;\n    mn_result_main_ParseError_bool mn_temporary_4;\n    bool mn_temporary_5;\n    if (((text > 9u))) {\n        mn_temporary_4 = mn_main_ready(text);\n        if (mn_temporary_4.error.tag != 0) return (mn_result_main_ParseError_u8){ .error = mn_temporary_4.error };\n        mn_temporary_5 = mn_temporary_4.value;\n        mn_temporary_3 = mn_temporary_5;\n    } else {\n        mn_temporary_3 = (text > 9u);\n    }\n    if (mn_temporary_3) {\n        return (mn_result_main_ParseError_u8){ .error.tag = 0, .value = 1u };\n    } else {\n        mn_result_main_ParseError_bool mn_temporary_6;\n        bool mn_temporary_7;\n        mn_temporary_6 = mn_main_ready(text);\n        if (mn_temporary_6.error.tag != 0) return (mn_result_main_ParseError_u8){ .error = mn_temporary_6.error };\n        mn_temporary_7 = mn_temporary_6.value;\n        if (mn_temporary_7) {\n            return (mn_result_main_ParseError_u8){ .error.tag = 0, .value = 2u };\n        }\n    }\n    return (mn_result_main_ParseError_u8){ .error.tag = 0, .value = result };\n}\n\nmn_result_main_ParseError_u8 mn_main_fallback(uint8_t text) {\n    mn_result_main_ParseError_u8 mn_temporary_1;\n    uint8_t mn_temporary_2;\n    mn_result_main_ParseError_u8 mn_temporary_3;\n    uint8_t mn_temporary_4;\n    mn_temporary_1 = mn_main_digit(text);\n    if (mn_temporary_1.error.tag != 0) {\n        mn_temporary_3 = mn_main_digit(48u);\n        if (mn_temporary_3.error.tag != 0) return (mn_result_main_ParseError_u8){ .error = mn_temporary_3.error };\n        mn_temporary_4 = mn_temporary_3.value;\n        mn_temporary_2 = mn_temporary_4;\n    } else {\n        mn_temporary_2 = mn_temporary_1.value;\n    }\n    return (mn_result_main_ParseError_u8){ .error.tag = 0, .value = mn_temporary_2 };\n}\n\nmn_result_main_ParseError_or_main_FileError_void mn_main_run() {\n    mn_result_main_ParseError_or_main_FileError_u8 mn_temporary_1;\n    mn_temporary_1 = mn_main_total(49u, 50u);\n    if (mn_temporary_1.error.tag != 0) return (mn_result_main_ParseError_or_main_FileError_void){ .error = mn_temporary_1.error };\n    return (mn_result_main_ParseError_or_main_FileError_void){ .error.tag = 0 };\n}\n",
        files[1].contents,
    );
}

test "generateEntryPoint: reports the error that ends main and ends with a nonzero status" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nfn main() -> ParseError!void: return ParseError::missing_end" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_ParseError {\n    uint32_t tag;\n    union {\n        uint8_t bad_digit;\n    } value;\n} mn_main_ParseError;\n\ntypedef struct mn_result_main_ParseError_void mn_result_main_ParseError_void;\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_result_main_ParseError_void_defined\n#define mn_result_main_ParseError_void_defined\ntypedef struct mn_result_main_ParseError_void {\n    mn_main_ParseError error;\n} mn_result_main_ParseError_void;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_runtime_error_report(char const *name);\n\nmn_result_main_ParseError_void mn_main_main() {\n    return (mn_result_main_ParseError_void){ .error = (mn_main_ParseError){ .tag = 1 } };\n}\n\nint main() {\n    mn_result_main_ParseError_void result = mn_main_main();\n    if (result.error.tag == 0) return 0;\n    switch (result.error.tag) {\n    case 1: mn_runtime_error_report(\"missing_end\"); break;\n    case 2: mn_runtime_error_report(\"bad_digit\"); break;\n    }\n    return 1;\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings("mn_runtime_error_report", generator.runtime_functions.items[0]);
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

test "generateIf: writes the condition, the body and the else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step()\nexternal fn stop()\nfn run(ready: bool):\n    if ready: step()\n    else: stop()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool ready) {\n    if (ready) {\n        step();\n    } else {\n        stop();\n    }\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateIf: writes only the block that each instance chooses" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn describe(type T, value: T) -> i32:\n    if T == bool:\n        if value: return 1\n        return 0\n    else:\n        return value\nfn main():\n    _ = describe(bool, true)\n    _ = describe(i32, 2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_main_describe_1(true);\n    mn_main_describe_2(2);\n}\n\nint32_t mn_main_describe_1([[maybe_unused]] bool value) {\n    {\n        if (value) {\n            return 1;\n        }\n        return 0;\n    }\n}\n\nint32_t mn_main_describe_2([[maybe_unused]] int32_t value) {\n    {\n        return value;\n    }\n}\n",
        files[1].contents,
    );
}

test "generateIf: chains an else if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step()\nexternal fn stop()\nfn run(one: bool, two: bool):\n    if one: step()\n    else if two: stop()\n    else: step()\nfn main(): run(true, false)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool one, bool two) {\n    if (one) {\n        step();\n    } else if (two) {\n        stop();\n    } else {\n        step();\n    }\n}\n\nint main() {\n    mn_main_run(true, false);\n}\n",
        files[1].contents,
    );
}

test "generateIf: declares the temporaries of an else if condition in the else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nexternal fn step()\nfn run(ready: bool):\n    if ready: step()\n    else if one() < two(): step()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool ready) {\n    if (ready) {\n        step();\n    } else {\n        int32_t mn_temporary_1;\n        int32_t mn_temporary_2;\n        if ((mn_temporary_1 = one(), mn_temporary_2 = two(), (mn_temporary_1 < mn_temporary_2))) {\n            step();\n        }\n    }\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
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

test "generateWhile: writes the else block after the loop and jumps over it on break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step() -> bool\nexternal fn stop()\nfn run(running: bool):\n    while running:\n        if step(): break\n    else: stop()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool running) {\n    while (running) {\n        if (step()) {\n            goto mn_break_1;\n        }\n    }\n    stop();\n    mn_break_1:;\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateWhile: writes no label for a loop with an else block and no break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step()\nexternal fn stop()\nfn run(running: bool):\n    while running: step()\n    else: stop()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool running) {\n    while (running) {\n        step();\n    }\n    stop();\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateFor: counts over the length of an array" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const items = [3]i32{1, 2, 3}\n    for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nchar mn_zero_sized;\n\nvoid mn_main_take(int32_t) {}\n\nint main() {\n    const mn_array_3_i32 items = (mn_array_3_i32){ .items = { 1, 2, 3 } };\n    for (size_t mn_index_1 = 0; mn_index_1 < 3; mn_index_1 += 1) {\n        const int32_t item = items.items[mn_index_1];\n        mn_main_take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: counts over a slice" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nfn show(items: []const i32): for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nvoid mn_main_show(mn_slice_i32 items) {\n    for (size_t mn_index_1 = 0; mn_index_1 < items.length; mn_index_1 += 1) {\n        const int32_t item = items.items[mn_index_1];\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: loops without a condition over a range without an end" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(index: usize)\nfn main(): for index in 1..: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    for (size_t mn_index_1 = 0; ; mn_index_1 += 1) {\n        const size_t index = 1u + mn_index_1;\n        take(index);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: counts over a pointer to an array" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nfn show(items: *[3]i32): for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nvoid mn_main_show(struct mn_array_3_i32 * items) {\n    for (size_t mn_index_1 = 0; mn_index_1 < 3; mn_index_1 += 1) {\n        const int32_t item = items->items[mn_index_1];\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: reads a variable array in place" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nfn main():\n    var items = [2]i32{1, 2}\n    for item in items:\n        items[1] = item\n        take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_array_2_i32 items = (mn_array_2_i32){ .items = { 1, 2 } };\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        const int32_t item = items.items[mn_index_1];\n        items.items[1u] = item;\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: counts over a range from its start to its end" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: usize)\nfn show(count: usize): for index in 2..count: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_show(size_t count) {\n    for (size_t mn_index_1 = 0; mn_index_1 < count - 2u; mn_index_1 += 1) {\n        const size_t index = 2u + mn_index_1;\n        take(index);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: evaluates the start of a range without an end once before the loop" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn first() -> usize\nexternal fn take(index: usize)\nfn main(): for index in first()..: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    const size_t mn_start_1 = first();\n    for (size_t mn_index_1 = 0; ; mn_index_1 += 1) {\n        const size_t index = mn_start_1 + mn_index_1;\n        take(index);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: continues with the next elements" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step(index: usize) -> bool\nfn main():\n    outer: for index in 0..3:\n        if step(index): continue\n        while step(index): continue outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    for (size_t mn_index_1 = 0; mn_index_1 < 3u; mn_index_1 += 1) {\n        const size_t index = mn_index_1;\n        if (step(index)) {\n            continue;\n        }\n        while (step(index)) {\n            goto mn_continue_1;\n        }\n        mn_continue_1:;\n    }\n}\n",
        files[1].contents,
    );
}

test "generateFor: leaves out the loop over an empty array" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn stop()\nfn show(items: [0]i32):\n    for item in items:\n        take(item)\n        break\n    else: stop()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_show() {\n    stop();\n}\n",
        files[1].contents,
    );
}

test "generateFor: leaves out the loop over a range whose bounds are equal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(index: usize)\nexternal fn stop()\nfn main():\n    for index in 3..3: take(index)\n    else: stop()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    stop();\n}\n",
        files[1].contents,
    );
}

test "generateFor: leaves out the loop over a range whose bounds known at compile time are equal" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step()\nconst LIMIT = 0usize\nfn main():\n    for _ in 0..LIMIT: step()\n    for _ in 0..LIMIT + 1: step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    const size_t mn_end_2 = (0u + 1u);\n    for (size_t mn_index_2 = 0; mn_index_2 < mn_end_2; mn_index_2 += 1) {\n        step();\n    }\n}\n",
        files[1].contents,
    );
}

test "generateUnrolled: writes the block of a loop over a tuple once for each element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn total(values: mn::Tuple) -> usize:\n    var sum: usize = 0\n    for value in values:\n        if sum > 100: break\n        if sum == 7: continue\n        sum += mn::convert(usize, value)\n    return sum\nfn run(small: u8, large: u64) -> usize: return total({small, large})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_tuple_2_u8_u64 mn_tuple_2_u8_u64;\n\nsize_t mn_main_run(uint8_t small, uint64_t large);\nsize_t mn_main_total_1(mn_tuple_2_u8_u64 values);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_u8_u64_defined\n#define mn_tuple_2_u8_u64_defined\ntypedef struct mn_tuple_2_u8_u64 {\n    uint8_t _0;\n    uint64_t _1;\n} mn_tuple_2_u8_u64;\n#endif\n\nsize_t mn_main_run(uint8_t small, uint64_t large) {\n    return mn_main_total_1((mn_tuple_2_u8_u64){ ._0 = small, ._1 = large });\n}\n\nsize_t mn_main_total_1(mn_tuple_2_u8_u64 values) {\n    size_t sum = 0u;\n    const mn_tuple_2_u8_u64 mn_tuple = values;\n    {\n        const uint8_t value = mn_tuple._0;\n        if ((sum > 100u)) {\n            goto mn_break_1;\n        }\n        if ((sum == 7u)) {\n            goto mn_continue_1_0;\n        }\n        size_t mn_temporary_1;\n        mn_temporary_1 = sum, sum = (mn_temporary_1 + ((size_t)value));\n    }\n    mn_continue_1_0:;\n    {\n        const uint64_t value_2 = mn_tuple._1;\n        if ((sum > 100u)) {\n            goto mn_break_1;\n        }\n        if ((sum == 7u)) {\n            goto mn_continue_1_1;\n        }\n        size_t mn_temporary_2;\n        mn_temporary_2 = sum, sum = (mn_temporary_2 + ((size_t)value_2));\n    }\n    mn_continue_1_1:;\n    mn_break_1:;\n    return sum;\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_optional_usize_defined\n#define mn_optional_usize_defined\ntypedef struct mn_optional_usize {\n    size_t value;\n    bool present;\n} mn_optional_usize;\n#endif\n\ntypedef struct mn_mn_Range {\n    size_t start;\n    mn_optional_usize end;\n} mn_mn_Range;\n\ntypedef struct mn_optional_tuple_1_usize mn_optional_tuple_1_usize;\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"mn.h\"\n\n#ifndef mn_tuple_1_usize_defined\n#define mn_tuple_1_usize_defined\ntypedef struct mn_tuple_1_usize {\n    size_t _0;\n} mn_tuple_1_usize;\n#endif\n\n#ifndef mn_optional_tuple_1_usize_defined\n#define mn_optional_tuple_1_usize_defined\ntypedef struct mn_optional_tuple_1_usize {\n    mn_tuple_1_usize value;\n    bool present;\n} mn_optional_tuple_1_usize;\n#endif\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator) {\n    if (((iterator->end.present) && (iterator->start >= iterator->end.value))) {\n        return (mn_optional_tuple_1_usize){ .present = false };\n    }\n    const size_t value = iterator->start;\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &iterator->start, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n    return (mn_optional_tuple_1_usize){ .value = (mn_tuple_1_usize){ ._0 = value }, .present = true };\n}\n",
        files[3].contents,
    );
}

test "generateIteration: copies the iterator and calls next until it gives null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nstruct Countdown:\n    count: u32\ninstance mn::Iterator(Countdown):\n    fn Element() -> type: return [u32]\n    fn next(iterator: *Countdown) -> ?Element():\n        if iterator.count == 0: return null\n        iterator.count -= 1\n        return {iterator.count + 1}\nfn total(start: u32) -> u32:\n    var sum: u32 = 0\n    for value in Countdown{count = start}: sum += value\n    return sum\nfn indexes(count: usize) -> usize:\n    var sum: usize = 0\n    const range = 2..count\n    for (index) in range:\n        if index == 4: continue\n        sum += index\n    else: sum += 1\n    return sum" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Countdown {\n    uint32_t count;\n} mn_main_Countdown;\n\ntypedef struct mn_optional_tuple_1_u32 mn_optional_tuple_1_u32;\n\nmn_optional_tuple_1_u32 mn_main_Countdown_Iterator_next(struct mn_main_Countdown * iterator);\nuint32_t mn_main_total(uint32_t start);\nsize_t mn_main_indexes(size_t count);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"mn.h\"\n\n#ifndef mn_tuple_1_u32_defined\n#define mn_tuple_1_u32_defined\ntypedef struct mn_tuple_1_u32 {\n    uint32_t _0;\n} mn_tuple_1_u32;\n#endif\n\n#ifndef mn_optional_tuple_1_u32_defined\n#define mn_optional_tuple_1_u32_defined\ntypedef struct mn_optional_tuple_1_u32 {\n    mn_tuple_1_u32 value;\n    bool present;\n} mn_optional_tuple_1_u32;\n#endif\n\n#ifndef mn_optional_usize_defined\n#define mn_optional_usize_defined\ntypedef struct mn_optional_usize {\n    size_t value;\n    bool present;\n} mn_optional_usize;\n#endif\n\n#ifndef mn_tuple_1_usize_defined\n#define mn_tuple_1_usize_defined\ntypedef struct mn_tuple_1_usize {\n    size_t _0;\n} mn_tuple_1_usize;\n#endif\n\n#ifndef mn_optional_tuple_1_usize_defined\n#define mn_optional_tuple_1_usize_defined\ntypedef struct mn_optional_tuple_1_usize {\n    mn_tuple_1_usize value;\n    bool present;\n} mn_optional_tuple_1_usize;\n#endif\n\nmn_optional_tuple_1_u32 mn_main_Countdown_Iterator_next(struct mn_main_Countdown * iterator) {\n    if ((iterator->count == 0u)) {\n        return (mn_optional_tuple_1_u32){ .present = false };\n    }\n    uint32_t * mn_temporary_1;\n    mn_temporary_1 = &iterator->count, (*mn_temporary_1) = ((*mn_temporary_1) - 1u);\n    return (mn_optional_tuple_1_u32){ .value = (mn_tuple_1_u32){ ._0 = (iterator->count + 1u) }, .present = true };\n}\n\nuint32_t mn_main_total(uint32_t start) {\n    uint32_t sum = 0u;\n    mn_main_Countdown mn_iterator_1 = (mn_main_Countdown){ .count = start };\n    for (;;) {\n        mn_optional_tuple_1_u32 mn_element_1 = mn_main_Countdown_Iterator_next(&mn_iterator_1);\n        if (!mn_element_1.present) break;\n        {\n            const uint32_t value = mn_element_1.value._0;\n            sum = (sum + value);\n        }\n    }\n    return sum;\n}\n\nsize_t mn_main_indexes(size_t count) {\n    size_t sum = 0u;\n    const mn_mn_Range range = (mn_mn_Range){ .start = 2u, .end = (mn_optional_usize){ .value = count, .present = true } };\n    mn_mn_Range mn_iterator_1 = range;\n    for (;;) {\n        mn_optional_tuple_1_usize mn_element_1 = mn_mn_Range_Iterator_next(&mn_iterator_1);\n        if (!mn_element_1.present) break;\n        {\n            const size_t index = mn_element_1.value._0;\n            if ((index == 4u)) {\n                continue;\n            }\n            sum = (sum + index);\n        }\n    }\n    sum = (sum + 1u);\n    return sum;\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_optional_usize_defined\n#define mn_optional_usize_defined\ntypedef struct mn_optional_usize {\n    size_t value;\n    bool present;\n} mn_optional_usize;\n#endif\n\ntypedef struct mn_mn_Range {\n    size_t start;\n    mn_optional_usize end;\n} mn_mn_Range;\n\ntypedef struct mn_optional_tuple_1_usize mn_optional_tuple_1_usize;\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"mn.h\"\n\n#ifndef mn_tuple_1_usize_defined\n#define mn_tuple_1_usize_defined\ntypedef struct mn_tuple_1_usize {\n    size_t _0;\n} mn_tuple_1_usize;\n#endif\n\n#ifndef mn_optional_tuple_1_usize_defined\n#define mn_optional_tuple_1_usize_defined\ntypedef struct mn_optional_tuple_1_usize {\n    mn_tuple_1_usize value;\n    bool present;\n} mn_optional_tuple_1_usize;\n#endif\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator) {\n    if (((iterator->end.present) && (iterator->start >= iterator->end.value))) {\n        return (mn_optional_tuple_1_usize){ .present = false };\n    }\n    const size_t value = iterator->start;\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &iterator->start, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n    return (mn_optional_tuple_1_usize){ .value = (mn_tuple_1_usize){ ._0 = value }, .present = true };\n}\n",
        files[3].contents,
    );
}

test "generateIteration: zips a slice or a read-only slice and a range into one iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::Zip\nfn sum(cards: []u32) -> u32:\n    var total: u32 = 0\n    for (card, index) in Zip::zip({cards, 0..}):\n        total += card * mn::convert(u32, index)\n    return total\nfn constant(cards: []const u32) -> u32:\n    var total: u32 = 0\n    for (card, index) in Zip::zip({cards, 0..}):\n        total += card * mn::convert(u32, index)\n    return total" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_slice_u32 mn_slice_u32;\n\nuint32_t mn_main_sum(mn_slice_u32 cards);\nuint32_t mn_main_constant(mn_slice_u32 cards);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n#include \"mn.h\"\n\n#ifndef mn_slice_u32_defined\n#define mn_slice_u32_defined\ntypedef struct mn_slice_u32 {\n    uint32_t *items;\n    size_t length;\n} mn_slice_u32;\n#endif\n\n#ifndef mn_tuple_2_u32_usize_defined\n#define mn_tuple_2_u32_usize_defined\ntypedef struct mn_tuple_2_u32_usize {\n    uint32_t _0;\n    size_t _1;\n} mn_tuple_2_u32_usize;\n#endif\n\n#ifndef mn_optional_tuple_2_u32_usize_defined\n#define mn_optional_tuple_2_u32_usize_defined\ntypedef struct mn_optional_tuple_2_u32_usize {\n    mn_tuple_2_u32_usize value;\n    bool present;\n} mn_optional_tuple_2_u32_usize;\n#endif\n\n#ifndef mn_tuple_2_slice_u32_mn_Range_defined\n#define mn_tuple_2_slice_u32_mn_Range_defined\ntypedef struct mn_tuple_2_slice_u32_mn_Range {\n    mn_slice_u32 _0;\n    mn_mn_Range _1;\n} mn_tuple_2_slice_u32_mn_Range;\n#endif\n\n#ifndef mn_optional_usize_defined\n#define mn_optional_usize_defined\ntypedef struct mn_optional_usize {\n    size_t value;\n    bool present;\n} mn_optional_usize;\n#endif\n\nuint32_t mn_main_sum(mn_slice_u32 cards) {\n    uint32_t total = 0u;\n    mn_mn_Zipped_1 mn_iterator_1 = mn_mn_tuple_2_slice_u32_Range_Zip_zip((mn_tuple_2_slice_u32_mn_Range){ ._0 = cards, ._1 = (mn_mn_Range){ .start = 0u, .end = { .present = false } } });\n    for (;;) {\n        mn_optional_tuple_2_u32_usize mn_element_1 = mn_mn_Zipped_1_Iterator_next(&mn_iterator_1);\n        if (!mn_element_1.present) break;\n        {\n            const uint32_t card = mn_element_1.value._0;\n            const size_t index = mn_element_1.value._1;\n            uint32_t mn_temporary_1;\n            mn_temporary_1 = total, total = (mn_temporary_1 + (card * ((uint32_t)index)));\n        }\n    }\n    return total;\n}\n\nuint32_t mn_main_constant(mn_slice_u32 cards) {\n    uint32_t total = 0u;\n    mn_mn_Zipped_2 mn_iterator_1 = mn_mn_tuple_2_slice_const_u32_Range_Zip_zip((mn_tuple_2_slice_u32_mn_Range){ ._0 = cards, ._1 = (mn_mn_Range){ .start = 0u, .end = { .present = false } } });\n    for (;;) {\n        mn_optional_tuple_2_u32_usize mn_element_1 = mn_mn_Zipped_2_Iterator_next(&mn_iterator_1);\n        if (!mn_element_1.present) break;\n        {\n            const uint32_t card = mn_element_1.value._0;\n            const size_t index = mn_element_1.value._1;\n            uint32_t mn_temporary_1;\n            mn_temporary_1 = total, total = (mn_temporary_1 + (card * ((uint32_t)index)));\n        }\n    }\n    return total;\n}\n",
        files[1].contents,
    );
    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\n#ifndef mn_optional_usize_defined\n#define mn_optional_usize_defined\ntypedef struct mn_optional_usize {\n    size_t value;\n    bool present;\n} mn_optional_usize;\n#endif\n\ntypedef struct mn_mn_Range {\n    size_t start;\n    mn_optional_usize end;\n} mn_mn_Range;\n\n#ifndef mn_slice_u32_defined\n#define mn_slice_u32_defined\ntypedef struct mn_slice_u32 {\n    uint32_t *items;\n    size_t length;\n} mn_slice_u32;\n#endif\n\n#ifndef mn_tuple_2_slice_u32_mn_Range_defined\n#define mn_tuple_2_slice_u32_mn_Range_defined\ntypedef struct mn_tuple_2_slice_u32_mn_Range {\n    mn_slice_u32 _0;\n    mn_mn_Range _1;\n} mn_tuple_2_slice_u32_mn_Range;\n#endif\n\ntypedef struct mn_mn_Zipped_1 {\n    mn_tuple_2_slice_u32_mn_Range iterators;\n} mn_mn_Zipped_1;\n\ntypedef struct mn_mn_Zipped_2 {\n    mn_tuple_2_slice_u32_mn_Range iterators;\n} mn_mn_Zipped_2;\n\ntypedef struct mn_optional_tuple_1_usize mn_optional_tuple_1_usize;\ntypedef struct mn_optional_tuple_2_u32_usize mn_optional_tuple_2_u32_usize;\ntypedef struct mn_tuple_2_u32_usize mn_tuple_2_u32_usize;\ntypedef struct mn_optional_tuple_1_u32 mn_optional_tuple_1_u32;\ntypedef struct mn_tuple_1_u32 mn_tuple_1_u32;\ntypedef struct mn_tuple_1_usize mn_tuple_1_usize;\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator);\nmn_mn_Zipped_1 mn_mn_tuple_2_slice_u32_Range_Zip_zip(mn_tuple_2_slice_u32_mn_Range iterators);\nmn_optional_tuple_2_u32_usize mn_mn_Zipped_1_Iterator_next(struct mn_mn_Zipped_1 * iterator);\nbool mn_mn_fillZipped_1([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nmn_mn_Zipped_2 mn_mn_tuple_2_slice_const_u32_Range_Zip_zip(mn_tuple_2_slice_u32_mn_Range iterators);\nmn_optional_tuple_2_u32_usize mn_mn_Zipped_2_Iterator_next(struct mn_mn_Zipped_2 * iterator);\nbool mn_mn_fillZipped_2([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nmn_optional_tuple_1_u32 mn_mn_slice_u32_Iterator_next(struct mn_slice_u32 * iterator);\nvoid mn_mn_copyElements_1([[maybe_unused]] mn_tuple_1_u32 source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination);\nbool mn_mn_fillZipped_3([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nmn_optional_tuple_1_u32 mn_mn_slice_const_u32_Iterator_next(struct mn_slice_u32 * iterator);\nbool mn_mn_fillZipped_4([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nvoid mn_mn_copyElements_2([[maybe_unused]] mn_tuple_1_u32 source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination);\nvoid mn_mn_copyElements_3([[maybe_unused]] mn_tuple_1_usize source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination);\nbool mn_mn_fillZipped_5([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nbool mn_mn_fillZipped_6([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element);\nvoid mn_mn_copyElements_4([[maybe_unused]] mn_tuple_1_usize source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination);\n",
        files[2].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"mn.h\"\n\n#ifndef mn_tuple_1_usize_defined\n#define mn_tuple_1_usize_defined\ntypedef struct mn_tuple_1_usize {\n    size_t _0;\n} mn_tuple_1_usize;\n#endif\n\n#ifndef mn_optional_tuple_1_usize_defined\n#define mn_optional_tuple_1_usize_defined\ntypedef struct mn_optional_tuple_1_usize {\n    mn_tuple_1_usize value;\n    bool present;\n} mn_optional_tuple_1_usize;\n#endif\n\n#ifndef mn_tuple_2_u32_usize_defined\n#define mn_tuple_2_u32_usize_defined\ntypedef struct mn_tuple_2_u32_usize {\n    uint32_t _0;\n    size_t _1;\n} mn_tuple_2_u32_usize;\n#endif\n\n#ifndef mn_optional_tuple_2_u32_usize_defined\n#define mn_optional_tuple_2_u32_usize_defined\ntypedef struct mn_optional_tuple_2_u32_usize {\n    mn_tuple_2_u32_usize value;\n    bool present;\n} mn_optional_tuple_2_u32_usize;\n#endif\n\n#ifndef mn_tuple_1_u32_defined\n#define mn_tuple_1_u32_defined\ntypedef struct mn_tuple_1_u32 {\n    uint32_t _0;\n} mn_tuple_1_u32;\n#endif\n\n#ifndef mn_optional_tuple_1_u32_defined\n#define mn_optional_tuple_1_u32_defined\ntypedef struct mn_optional_tuple_1_u32 {\n    mn_tuple_1_u32 value;\n    bool present;\n} mn_optional_tuple_1_u32;\n#endif\n\nmn_optional_tuple_1_usize mn_mn_Range_Iterator_next(struct mn_mn_Range * iterator) {\n    if (((iterator->end.present) && (iterator->start >= iterator->end.value))) {\n        return (mn_optional_tuple_1_usize){ .present = false };\n    }\n    const size_t value = iterator->start;\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &iterator->start, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n    return (mn_optional_tuple_1_usize){ .value = (mn_tuple_1_usize){ ._0 = value }, .present = true };\n}\n\nmn_mn_Zipped_1 mn_mn_tuple_2_slice_u32_Range_Zip_zip(mn_tuple_2_slice_u32_mn_Range iterators) {\n    return (mn_mn_Zipped_1){ .iterators = iterators };\n}\n\nmn_optional_tuple_2_u32_usize mn_mn_Zipped_1_Iterator_next(struct mn_mn_Zipped_1 * iterator) {\n    mn_tuple_2_u32_usize element;\n    const bool filled = mn_mn_fillZipped_1(&iterator->iterators, &element);\n    if (filled) {\n        return (mn_optional_tuple_2_u32_usize){ .value = element, .present = true };\n    }\n    return (mn_optional_tuple_2_u32_usize){ .present = false };\n}\n\nbool mn_mn_fillZipped_1([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        const mn_optional_tuple_1_u32 item = mn_mn_slice_u32_Iterator_next(&(*iterators)._0);\n        if ((!item.present)) {\n            return false;\n        }\n        mn_mn_copyElements_1(item.value, element);\n        return mn_mn_fillZipped_3(iterators, element);\n    }\n}\n\nmn_mn_Zipped_2 mn_mn_tuple_2_slice_const_u32_Range_Zip_zip(mn_tuple_2_slice_u32_mn_Range iterators) {\n    return (mn_mn_Zipped_2){ .iterators = iterators };\n}\n\nmn_optional_tuple_2_u32_usize mn_mn_Zipped_2_Iterator_next(struct mn_mn_Zipped_2 * iterator) {\n    mn_tuple_2_u32_usize element;\n    const bool filled = mn_mn_fillZipped_2(&iterator->iterators, &element);\n    if (filled) {\n        return (mn_optional_tuple_2_u32_usize){ .value = element, .present = true };\n    }\n    return (mn_optional_tuple_2_u32_usize){ .present = false };\n}\n\nbool mn_mn_fillZipped_2([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        const mn_optional_tuple_1_u32 item = mn_mn_slice_const_u32_Iterator_next(&(*iterators)._0);\n        if ((!item.present)) {\n            return false;\n        }\n        mn_mn_copyElements_1(item.value, element);\n        return mn_mn_fillZipped_4(iterators, element);\n    }\n}\n\nmn_optional_tuple_1_u32 mn_mn_slice_u32_Iterator_next(struct mn_slice_u32 * iterator) {\n    const mn_slice_u32 mn_sequence_1 = (*iterator);\n    for (size_t mn_index_1 = 0; mn_index_1 < mn_sequence_1.length; mn_index_1 += 1) {\n        const uint32_t element = mn_sequence_1.items[mn_index_1];\n        (*iterator) = (mn_slice_u32){ .items = (*iterator).items + 1u, .length = (*iterator).length - 1u };\n        return (mn_optional_tuple_1_u32){ .value = (mn_tuple_1_u32){ ._0 = element }, .present = true };\n    }\n    return (mn_optional_tuple_1_u32){ .present = false };\n}\n\nvoid mn_mn_copyElements_1([[maybe_unused]] mn_tuple_1_u32 source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination) {\n    {\n        (*destination)._0 = source._0;\n        mn_mn_copyElements_2(source, destination);\n    }\n}\n\nbool mn_mn_fillZipped_3([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        const mn_optional_tuple_1_usize item = mn_mn_Range_Iterator_next(&(*iterators)._1);\n        if ((!item.present)) {\n            return false;\n        }\n        mn_mn_copyElements_3(item.value, element);\n        return mn_mn_fillZipped_5(iterators, element);\n    }\n}\n\nmn_optional_tuple_1_u32 mn_mn_slice_const_u32_Iterator_next(struct mn_slice_u32 * iterator) {\n    const mn_slice_u32 mn_sequence_1 = (*iterator);\n    for (size_t mn_index_1 = 0; mn_index_1 < mn_sequence_1.length; mn_index_1 += 1) {\n        const uint32_t element = mn_sequence_1.items[mn_index_1];\n        (*iterator) = (mn_slice_u32){ .items = (*iterator).items + 1u, .length = (*iterator).length - 1u };\n        return (mn_optional_tuple_1_u32){ .value = (mn_tuple_1_u32){ ._0 = element }, .present = true };\n    }\n    return (mn_optional_tuple_1_u32){ .present = false };\n}\n\nbool mn_mn_fillZipped_4([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        const mn_optional_tuple_1_usize item = mn_mn_Range_Iterator_next(&(*iterators)._1);\n        if ((!item.present)) {\n            return false;\n        }\n        mn_mn_copyElements_3(item.value, element);\n        return mn_mn_fillZipped_6(iterators, element);\n    }\n}\n\nvoid mn_mn_copyElements_2([[maybe_unused]] mn_tuple_1_u32 source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination) {\n    {}\n}\n\nvoid mn_mn_copyElements_3([[maybe_unused]] mn_tuple_1_usize source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination) {\n    {\n        (*destination)._1 = source._0;\n        mn_mn_copyElements_4(source, destination);\n    }\n}\n\nbool mn_mn_fillZipped_5([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        return true;\n    }\n}\n\nbool mn_mn_fillZipped_6([[maybe_unused]] struct mn_tuple_2_slice_u32_mn_Range * iterators, [[maybe_unused]] struct mn_tuple_2_u32_usize * element) {\n    {\n        return true;\n    }\n}\n\nvoid mn_mn_copyElements_4([[maybe_unused]] mn_tuple_1_usize source, [[maybe_unused]] struct mn_tuple_2_u32_usize * destination) {\n    {}\n}\n",
        files[3].contents,
    );
}

test "generatePart: stores a sequence that needs temporaries" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn one() -> i32\nexternal fn two() -> i32\nexternal fn pick(left: i32, right: i32) -> []const i32\nexternal fn take(value: i32)\nfn main(): for item in pick(one(), two()): take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    int32_t mn_temporary_1;\n    int32_t mn_temporary_2;\n    const mn_slice_i32 mn_sequence_1 = (mn_temporary_1 = one(), mn_temporary_2 = two(), pick(mn_temporary_1, mn_temporary_2));\n    for (size_t mn_index_1 = 0; mn_index_1 < mn_sequence_1.length; mn_index_1 += 1) {\n        const int32_t item = mn_sequence_1.items[mn_index_1];\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generatePart: evaluates a sequence without a name only for its effects" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> [2]i32\nexternal fn step()\nfn main(): for _ in make(): step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    make();\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        step();\n    }\n}\n",
        files[1].contents,
    );
}

test "generatePart: stores the address of an array that is not a name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    items: [2]i32\nexternal fn one() -> usize\nexternal fn two() -> usize\nexternal fn pick(left: usize, right: usize) -> usize\nexternal fn take(value: i32)\nfn show(all: []Data): for item in all[pick(one(), two())].items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_main_Data_defined\n#define mn_slice_main_Data_defined\ntypedef struct mn_slice_main_Data {\n    struct mn_main_Data *items;\n    size_t length;\n} mn_slice_main_Data;\n#endif\n\nvoid mn_main_show(mn_slice_main_Data all) {\n    size_t mn_temporary_1;\n    size_t mn_temporary_2;\n    size_t mn_temporary_3;\n    struct mn_array_2_i32 const * const mn_sequence_1 = (mn_temporary_1 = one(), mn_temporary_2 = two(), mn_temporary_3 = pick(mn_temporary_1, mn_temporary_2), &all.items[mn_temporary_3].items);\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        const int32_t item = mn_sequence_1->items[mn_index_1];\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generatePart: stores an array that has no storage of its own" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> [2]i32\nexternal fn take(value: i32)\nfn main(): for item in make(): take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    const mn_array_2_i32 mn_sequence_1 = make();\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        const int32_t item = mn_sequence_1.items[mn_index_1];\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "isStoredPart: stores a sequence held by a variable" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nfn show(items: []const i32, others: []const i32):\n    var current = items\n    for item in current:\n        current = others\n        take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nvoid mn_main_show(mn_slice_i32 items, mn_slice_i32 others) {\n    mn_slice_i32 current = items;\n    const mn_slice_i32 mn_sequence_1 = current;\n    for (size_t mn_index_1 = 0; mn_index_1 < mn_sequence_1.length; mn_index_1 += 1) {\n        const int32_t item = mn_sequence_1.items[mn_index_1];\n        current = others;\n        take(item);\n    }\n}\n",
        files[1].contents,
    );
}

test "generatePart: stores a writable address of an array that a pointer name modifies" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Hand:\n    cards: [2]i32\nfn main():\n    var hand = Hand{cards = {1, 2}}\n    for *card in hand.cards: card.* = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    mn_main_Hand hand = (mn_main_Hand){ .cards = (mn_array_2_i32){ .items = { 1, 2 } } };\n    struct mn_array_2_i32 * const mn_sequence_1 = &hand.cards;\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        int32_t * const card = &mn_sequence_1->items[mn_index_1];\n        (*card) = 0;\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: leaves out a zero-sized element" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn step()\nfn take(marker: Marker): _ = marker\nfn show(markers: [2]Marker):\n    for marker in markers:\n        take(marker)\n        step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_take() {}\n\nvoid mn_main_show() {\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        mn_main_take();\n        step();\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: numbers a name that shadows an outer local" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nfn show(items: []const i32):\n    const item = 1i32\n    take(item)\n    for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nvoid mn_main_show(mn_slice_i32 items) {\n    const int32_t item = 1;\n    take(item);\n    for (size_t mn_index_1 = 0; mn_index_1 < items.length; mn_index_1 += 1) {\n        const int32_t item_2 = items.items[mn_index_1];\n        take(item_2);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: takes each element apart" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn show(pairs: [][i32, bool]):\n    for (number, flag) in pairs:\n        take(number)\n        check(flag)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_tuple_2_i32_bool_defined\n#define mn_slice_tuple_2_i32_bool_defined\ntypedef struct mn_slice_tuple_2_i32_bool {\n    struct mn_tuple_2_i32_bool *items;\n    size_t length;\n} mn_slice_tuple_2_i32_bool;\n#endif\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nvoid mn_main_show(mn_slice_tuple_2_i32_bool pairs) {\n    for (size_t mn_index_1 = 0; mn_index_1 < pairs.length; mn_index_1 += 1) {\n        const int32_t number = pairs.items[mn_index_1]._0;\n        const bool flag = pairs.items[mn_index_1]._1;\n        take(number);\n        check(flag);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: points a pointer name to each element" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var cards = [2]i32{1, 2}\n    for *card in cards: card.* = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    mn_array_2_i32 cards = (mn_array_2_i32){ .items = { 1, 2 } };\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        int32_t * const card = &cards.items[mn_index_1];\n        (*card) = 0;\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: points a pointer name in parentheses to the element of each element" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: i32)\nexternal fn check(flag: bool)\nfn show(pairs: [][i32, bool]):\n    for (*number, flag) in pairs:\n        number.* = 0\n        check(flag)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_tuple_2_i32_bool_defined\n#define mn_slice_tuple_2_i32_bool_defined\ntypedef struct mn_slice_tuple_2_i32_bool {\n    struct mn_tuple_2_i32_bool *items;\n    size_t length;\n} mn_slice_tuple_2_i32_bool;\n#endif\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nvoid mn_main_show(mn_slice_tuple_2_i32_bool pairs) {\n    for (size_t mn_index_1 = 0; mn_index_1 < pairs.length; mn_index_1 += 1) {\n        int32_t * const number = &pairs.items[mn_index_1]._0;\n        const bool flag = pairs.items[mn_index_1]._1;\n        (*number) = 0;\n        check(flag);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateElementDeclarations: points a pointer name to each element of a constant array as read-only" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn keep(value: *const i32)\nfn main():\n    const cards = [2]i32{1, 2}\n    for *card in cards: keep(card)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_i32_defined\n#define mn_array_2_i32_defined\ntypedef struct mn_array_2_i32 {\n    int32_t items[2];\n} mn_array_2_i32;\n#endif\n\nchar mn_zero_sized;\n\nint main() {\n    const mn_array_2_i32 cards = (mn_array_2_i32){ .items = { 1, 2 } };\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        int32_t const * const card = &cards.items[mn_index_1];\n        keep(card);\n    }\n}\n",
        files[1].contents,
    );
}

test "generateLoopEnd: writes the else block of a for loop and jumps over it on break" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step(value: i32) -> bool\nexternal fn stop()\nfn show(items: []const i32):\n    for item in items:\n        if step(item): break\n    else: stop()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_slice_i32_defined\n#define mn_slice_i32_defined\ntypedef struct mn_slice_i32 {\n    int32_t *items;\n    size_t length;\n} mn_slice_i32;\n#endif\n\nvoid mn_main_show(mn_slice_i32 items) {\n    for (size_t mn_index_1 = 0; mn_index_1 < items.length; mn_index_1 += 1) {\n        const int32_t item = items.items[mn_index_1];\n        if (step(item)) {\n            goto mn_break_1;\n        }\n    }\n    stop();\n    mn_break_1:;\n}\n",
        files[1].contents,
    );
}

test "generateJump: writes a jump to the innermost loop as a plain break or continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step() -> bool\nfn run(running: bool):\n    outer: while running:\n        if step(): continue outer\n        break outer\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool running) {\n    while (running) {\n        if (step()) {\n            continue;\n        }\n        break;\n    }\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateJump: jumps to the labels of an outer loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step() -> bool\nfn run(running: bool):\n    outer: while running:\n        while step():\n            if step(): continue outer\n            break outer\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool running) {\n    while (running) {\n        while (step()) {\n            if (step()) {\n                goto mn_continue_1;\n            }\n            goto mn_break_1;\n        }\n        mn_continue_1:;\n    }\n    mn_break_1:;\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateJump: breaks from the else block of an inner loop as from the innermost loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step() -> bool\nfn run(running: bool):\n    while running:\n        while step(): noop\n        else: break\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_run(bool running) {\n    while (running) {\n        while (step()) {}\n        break;\n    }\n}\n\nint main() {\n    mn_main_run(true);\n}\n",
        files[1].contents,
    );
}

test "generateJump: breaks from the else block of a for loop as from the enclosing loop" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn step() -> bool\nfn main():\n    while step():\n        for _ in 0..3: noop\n        else: break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint main() {\n    while (step()) {\n        for (size_t mn_index_2 = 0; mn_index_2 < 3u; mn_index_2 += 1) {}\n        break;\n    }\n}\n",
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
        "#include \"main.h\"\n\nuint8_t mn_main_mask() {\n    return 255u;\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn keep(value: *i32)\nfn main():\n    var value = 1i32\n    var values = [2]i32{1, 2}\n    var point = Point{x = 1}\n    var pair = [i32, bool]{1, true}\n    keep(&value)\n    keep(&values[1])\n    keep(&point.x)\n    keep(&pair[0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): return\nfn make() -> [void, i32]: return {show(), 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pairs: [1][i32, bool] = {{1, true}}\nfn all() -> [1][i32, bool]: return pairs" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateBinary: compares pointers to functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two(): noop\nfn same() -> bool: return &one == &two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nvoid mn_main_one() {}\n\nvoid mn_main_two() {}\n\nbool mn_main_same() {\n    return (mn_main_one == mn_main_two);\n}\n",
        files[1].contents,
    );
}

test "generateBinary: compares optional pointers to functions directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?*fn(i32), right: ?*fn(i32)) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nbool mn_main_same(typeof(void (*)(int32_t)) left, typeof(void (*)(int32_t)) right) {\n    return (left == right);\n}\n",
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

test "generateNull: writes NULL for an optional pointer to a function" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?*fn(i32) -> bool: return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateFunctionName: writes the name of a function to point to" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn double(value: i32) -> i32: return value\nfn apply(callback: *fn(i32) -> i32): _ = callback\nfn main():\n    const other: *fn(i32) -> i32 = &double\n    apply(&double)\n    apply(other)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_double(int32_t value) {\n    return value;\n}\n\nvoid mn_main_apply(typeof(int32_t (*)(int32_t))) {}\n\nint main() {\n    typeof(int32_t (*)(int32_t)) const other = mn_main_double;\n    mn_main_apply(mn_main_double);\n    mn_main_apply(other);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionName: writes pointers to functions in a stored constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two(): noop\nconst steps: [2]*fn() = {&one, &two}\nfn all() -> [2]*fn(): return steps" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateFunctionName: writes the name of a method or an external function to point to" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write_text(text: []const u8)\nstruct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn apply(measure: *fn(Point) -> f32, write: *fn([]const u8)):\n    _ = measure\n    _ = write\nfn main(): apply(&Point::length, &write_text)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(pair: [i32, bool]) -> bool: return pair[1]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pair: [i32, bool] = {1, true}\nfn second() -> bool: return pair[1]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateIndex: writes an element of a tuple at an index known at compile time" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SECOND = 1usize\nfn second(pair: [i32, bool]) -> bool: return pair[SECOND]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\nbool mn_main_second(mn_tuple_2_i32_bool pair) {\n    return pair._1;\n}\n",
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

test "generateConstant: writes the value of a constant with operators at each use" {
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
        "#include \"main.h\"\n\nint32_t mn_main_sum() {\n    return (20 + 30);\n}\n\nuint32_t mn_main_bits() {\n    return 16u;\n}\n\nbool mn_main_check() {\n    return true;\n}\n",
        files[1].contents,
    );
}

test "generateBuiltinCall: writes sizes and alignments as constants and conversions as casts" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nstruct Pair:\n    small: u8\n    large: i32\nenum Token:\n    number: i64\n    end\nerror Failure:\n    bad: u8\nfn size() -> usize: return mn::size(Pair)\nfn alignment() -> usize: return mn::alignment(Pair)\nfn token() -> usize: return mn::size(Token)\nfn maybe() -> usize: return mn::size(?i32)\nfn text() -> usize: return mn::size([]const u8)\nfn result() -> usize: return mn::size(Failure!u16)\nfn whole(value: f64) -> i32: return mn::convert(i32, value)\nfn low(value: i32) -> u8: return mn::truncate(u8, value)\nfn wide(value: u8) -> u64: return value\nfn float(value: f32) -> f64: return value\nfn count() -> usize: return mn::reflection::length([u8, bool])\nfn pairs() -> [i32, bool]:\n    const number: i32 = 4\n    return {number, true}\nfn use(pair: Pair, token: Token, failure: Failure!u16) -> usize:\n    _ = pair\n    _ = token\n    _ = failure\n    return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_main_Token {\n    uint32_t tag;\n    union {\n        int64_t number;\n    } value;\n} mn_main_Token;\n\ntypedef struct mn_main_Failure {\n    uint32_t tag;\n    union {\n        uint8_t bad;\n    } value;\n} mn_main_Failure;\n\ntypedef struct mn_main_Pair {\n    uint8_t small;\n    int32_t large;\n} mn_main_Pair;\n\ntypedef struct mn_tuple_2_i32_bool mn_tuple_2_i32_bool;\ntypedef struct mn_result_main_Failure_u16 mn_result_main_Failure_u16;\n\nsize_t mn_main_size();\nsize_t mn_main_alignment();\nsize_t mn_main_token();\nsize_t mn_main_maybe();\nsize_t mn_main_text();\nsize_t mn_main_result();\nint32_t mn_main_whole(double value);\nuint8_t mn_main_low(int32_t value);\nuint64_t mn_main_wide(uint8_t value);\ndouble mn_main_float(float value);\nsize_t mn_main_count();\nmn_tuple_2_i32_bool mn_main_pairs();\nsize_t mn_main_use(mn_main_Pair, mn_main_Token, mn_result_main_Failure_u16);\n",
        files[0].contents,
    );
    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_i32_bool_defined\n#define mn_tuple_2_i32_bool_defined\ntypedef struct mn_tuple_2_i32_bool {\n    int32_t _0;\n    bool _1;\n} mn_tuple_2_i32_bool;\n#endif\n\n#ifndef mn_result_main_Failure_u16_defined\n#define mn_result_main_Failure_u16_defined\ntypedef struct mn_result_main_Failure_u16 {\n    mn_main_Failure error;\n    uint16_t value;\n} mn_result_main_Failure_u16;\n#endif\n\nsize_t mn_main_size() {\n    return 8u;\n}\n\nsize_t mn_main_alignment() {\n    return 4u;\n}\n\nsize_t mn_main_token() {\n    return 16u;\n}\n\nsize_t mn_main_maybe() {\n    return 8u;\n}\n\nsize_t mn_main_text() {\n    return 16u;\n}\n\nsize_t mn_main_result() {\n    return 12u;\n}\n\nint32_t mn_main_whole(double value) {\n    return ((int32_t)value);\n}\n\nuint8_t mn_main_low(int32_t value) {\n    return ((uint8_t)value);\n}\n\nuint64_t mn_main_wide(uint8_t value) {\n    return value;\n}\n\ndouble mn_main_float(float value) {\n    return value;\n}\n\nsize_t mn_main_count() {\n    return 2u;\n}\n\nmn_tuple_2_i32_bool mn_main_pairs() {\n    const int32_t number = 4;\n    return (mn_tuple_2_i32_bool){ ._0 = number, ._1 = true };\n}\n\nsize_t mn_main_use(mn_main_Pair, mn_main_Token, mn_result_main_Failure_u16) {\n    return 0u;\n}\n",
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

test "generateFunctionCall: calls the function of a typeclass through the typeclass and the function of the struct through the value and the type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\nstruct Square:\n    side: i32\n    fn area(self: Self) -> i32: return self.side\ninstance Shape(Square):\n    fn area(self: Square) -> i32: return self.side * self.side\nfn main():\n    const square = Square{side = 2}\n    _ = square.area()\n    _ = Square::area(square)\n    _ = Shape::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Square_area(mn_main_Square self) {\n    return self.side;\n}\n\nint32_t mn_main_Square_Shape_area(mn_main_Square self) {\n    return (self.side * self.side);\n}\n\nint main() {\n    const mn_main_Square square = (mn_main_Square){ .side = 2 };\n    mn_main_Square_area(square);\n    mn_main_Square_area(square);\n    mn_main_Square_Shape_area(square);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: calls a function of a named instance and points to one" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(shape: T) -> i32\n    fn unit() -> T\nstruct Square:\n    side: i32\ninstance Shape(Square):\n    fn area(shape: Square) -> i32: return shape.side\n    fn unit() -> Square: return Square{side = 1}\nfn main():\n    const square = Shape(Square)::unit()\n    const area = &Shape(Square)::area\n    _ = area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Square_Shape_area(mn_main_Square shape) {\n    return shape.side;\n}\n\nmn_main_Square mn_main_Square_Shape_unit() {\n    return (mn_main_Square){ .side = 1 };\n}\n\nint main() {\n    const mn_main_Square square = mn_main_Square_Shape_unit();\n    typeof(int32_t (*)(struct mn_main_Square)) const area = mn_main_Square_Shape_area;\n    area(square);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: calls a function of an instance with several arguments" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Iterator(type I, type T):\n    fn next(iterator: *I) -> ?T\nstruct Counter:\n    count: usize\ninstance Iterator(Counter, [usize, bool]):\n    fn next(iterator: *Counter) -> ?[usize, bool]:\n        iterator.count += 1\n        return [usize, bool]{iterator.count, true}\nfn main():\n    var counter = Counter{count = 0}\n    _ = counter.next()\n    _ = Iterator(Counter, [usize, bool])::next(&counter)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_tuple_2_usize_bool_defined\n#define mn_tuple_2_usize_bool_defined\ntypedef struct mn_tuple_2_usize_bool {\n    size_t _0;\n    bool _1;\n} mn_tuple_2_usize_bool;\n#endif\n\n#ifndef mn_optional_tuple_2_usize_bool_defined\n#define mn_optional_tuple_2_usize_bool_defined\ntypedef struct mn_optional_tuple_2_usize_bool {\n    mn_tuple_2_usize_bool value;\n    bool present;\n} mn_optional_tuple_2_usize_bool;\n#endif\n\nchar mn_zero_sized;\n\nmn_optional_tuple_2_usize_bool mn_main_Counter_tuple_2_usize_bool_Iterator_next(struct mn_main_Counter * iterator) {\n    size_t * mn_temporary_1;\n    mn_temporary_1 = &iterator->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1u);\n    return (mn_optional_tuple_2_usize_bool){ .value = (mn_tuple_2_usize_bool){ ._0 = iterator->count, ._1 = true }, .present = true };\n}\n\nint main() {\n    mn_main_Counter counter = (mn_main_Counter){ .count = 0u };\n    mn_main_Counter_tuple_2_usize_bool_Iterator_next(&counter);\n    mn_main_Counter_tuple_2_usize_bool_Iterator_next(&counter);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: calls a function of a generic instance for two arguments" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Show(type T):\n    fn show(value: T) -> i32\n    fn twice(value: T) -> i32: return Show::show(value) * 2\ninstance Show(i32):\n    fn show(value: i32) -> i32: return value\nfn List(type T) -> type:\n    return struct:\n        first: T\ninstance(type A: Show) Show(List(A)):\n    fn show(value: List(A)) -> i32: return Show::show(value.first) + 1\nfn main():\n    _ = Show::show(List(i32){first = 5})\n    _ = Show::show(List(List(i32)){first = List(i32){first = 5}})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_i32_Show_show(int32_t value) {\n    return value;\n}\n\nint main() {\n    mn_main_List_1_Show_show((mn_main_List_1){ .first = 5 });\n    mn_main_List_2_Show_show((mn_main_List_2){ .first = (mn_main_List_1){ .first = 5 } });\n}\n\nint32_t mn_main_i32_Show_twice(int32_t value) {\n    return (mn_main_i32_Show_show(value) * 2);\n}\n\nint32_t mn_main_List_1_Show_show(mn_main_List_1 value) {\n    return (mn_main_i32_Show_show(value.first) + 1);\n}\n\nint32_t mn_main_List_2_Show_show(mn_main_List_2 value) {\n    return (mn_main_List_1_Show_show(value.first) + 1);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: calls a typeclass function with its own type parameters" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Mapper(type F(type)):\n    fn map(type A, type B, value: F(A), function: *fn(A) -> B) -> F(B)\nfn Box(type T) -> type:\n    return struct:\n        value: T\ninstance Mapper(Box):\n    fn map(type A, type B, value: Box(A), function: *fn(A) -> B) -> Box(B): return Box(B){value = function(value.value)}\nfn positive(value: i32) -> bool: return value > 0\nfn main(): _ = Mapper::map(i32, bool, Box(i32){value = 3}, &positive)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nbool mn_main_positive(int32_t value) {\n    return (value > 0);\n}\n\nint main() {\n    mn_main_Box_Mapper_map_1((mn_main_Box_1){ .value = 3 }, mn_main_positive);\n}\n\nmn_main_Box_2 mn_main_Box_Mapper_map_1(mn_main_Box_1 value, typeof(bool (*)(int32_t)) function) {\n    return (mn_main_Box_2){ .value = function(value.value) };\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: calls the instance of a function with a parameter of a typeclass type for each type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Show(type T):\n    fn show(value: T) -> i32\ninstance Show(i32):\n    fn show(value: i32) -> i32: return value\ninstance Show(bool):\n    fn show(value: bool) -> i32:\n        if value: return 1\n        return 0\nfn report(value: Show) -> i32: return value.show() + 1\nfn main():\n    _ = report(5i32)\n    _ = report(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_i32_Show_show(int32_t value) {\n    return value;\n}\n\nint32_t mn_main_bool_Show_show(bool value) {\n    if (value) {\n        return 1;\n    }\n    return 0;\n}\n\nint main() {\n    mn_main_report_1(5);\n    mn_main_report_2(true);\n}\n\nint32_t mn_main_report_1(int32_t value) {\n    return (mn_main_i32_Show_show(value) + 1);\n}\n\nint32_t mn_main_report_2(bool value) {\n    return (mn_main_bool_Show_show(value) + 1);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: wraps a converted value in an optional" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    value: ?i32\nfn take(value: ?i32) -> i32: return value orelse 0\nfn wrap(value: i32) -> ?i32: return value\nfn read(box: Box) -> i32: return box.value orelse 0\nfn main():\n    var count: ?i32 = 5\n    count = 6\n    _ = read(Box{value = 7})\n    _ = wrap(1)\n    _ = take(3)\n    _ = take(count)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_take(mn_optional_i32 value) {\n    return (value.present ? value.value : 0);\n}\n\nmn_optional_i32 mn_main_wrap(int32_t value) {\n    return (mn_optional_i32){ .value = value, .present = true };\n}\n\nint32_t mn_main_read(mn_main_Box box) {\n    mn_optional_i32 mn_temporary_1;\n    return (mn_temporary_1 = box.value, (mn_temporary_1.present ? mn_temporary_1.value : 0));\n}\n\nint main() {\n    mn_optional_i32 count = (mn_optional_i32){ .value = 5, .present = true };\n    count = (mn_optional_i32){ .value = 6, .present = true };\n    mn_main_read((mn_main_Box){ .value = (mn_optional_i32){ .value = 7, .present = true } });\n    mn_main_wrap(1);\n    mn_main_take((mn_optional_i32){ .value = 3, .present = true });\n    mn_main_take(count);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: runs a zero-sized value that is wrapped in an optional" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nexternal fn make() -> Marker\nfn wrap() -> ?Marker: return make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_optional_main_Marker_defined\n#define mn_optional_main_Marker_defined\ntypedef struct mn_optional_main_Marker {\n    bool present;\n} mn_optional_main_Marker;\n#endif\n\nmn_optional_main_Marker mn_main_wrap() {\n    return (make(), (mn_optional_main_Marker){ .present = true });\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: passes the pointer written as the first argument of a call through a typeclass" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn grow(self: *T)\n    fn measure(self: *const T) -> i32\nstruct Square:\n    side: i32\ninstance Shape(Square):\n    fn grow(self: *Square): self.side += 1\n    fn measure(self: *const Square) -> i32: return self.side\nfn main():\n    var square = Square{side = 1}\n    Shape::grow(&square)\n    _ = Shape::measure(&square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_Square_Shape_grow(struct mn_main_Square * self) {\n    int32_t * mn_temporary_1;\n    mn_temporary_1 = &self->side, (*mn_temporary_1) = ((*mn_temporary_1) + 1);\n}\n\nint32_t mn_main_Square_Shape_measure(struct mn_main_Square const * self) {\n    return self->side;\n}\n\nint main() {\n    mn_main_Square square = (mn_main_Square){ .side = 1 };\n    mn_main_Square_Shape_grow(&square);\n    mn_main_Square_Shape_measure(&square);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: takes the address of the receiver once for a pointer receiver" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter:\n    count: i32\n    fn read(self: Self) -> i32: return self.count\n    fn increment(self: *Self): self.count += 1\nfn next() -> usize: return 0\nfn main():\n    var counters = [2]Counter{{count = 0}, {count = 1}}\n    counters[next()].increment()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_main_Counter_defined\n#define mn_array_2_main_Counter_defined\ntypedef struct mn_array_2_main_Counter {\n    mn_main_Counter items[2];\n} mn_array_2_main_Counter;\n#endif\n\nchar mn_zero_sized;\n\nint32_t mn_main_Counter_read(mn_main_Counter self) {\n    return self.count;\n}\n\nvoid mn_main_Counter_increment(struct mn_main_Counter * self) {\n    int32_t * mn_temporary_1;\n    mn_temporary_1 = &self->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1);\n}\n\nsize_t mn_main_next() {\n    return 0u;\n}\n\nint main() {\n    mn_array_2_main_Counter counters = (mn_array_2_main_Counter){ .items = { (mn_main_Counter){ .count = 0 }, (mn_main_Counter){ .count = 1 } } };\n    mn_main_Counter_increment(&counters.items[mn_main_next()]);\n}\n",
        files[1].contents,
    );
}

test "generateFunctionCall: dereferences a pointer once for a value receiver" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter:\n    count: i32\n    fn read(self: Self) -> i32: return self.count\n    fn increment(self: *Self): self.count += 1\nexternal fn locate() -> *Counter\nfn main():\n    _ = locate().read()\n    locate().increment()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_Counter_read(mn_main_Counter self) {\n    return self.count;\n}\n\nvoid mn_main_Counter_increment(struct mn_main_Counter * self) {\n    int32_t * mn_temporary_1;\n    mn_temporary_1 = &self->count, (*mn_temporary_1) = ((*mn_temporary_1) + 1);\n}\n\nint main() {\n    mn_main_Counter_read((*locate()));\n    mn_main_Counter_increment(locate());\n}\n",
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

test "generateFunctionCall: leaves out arguments of the empty tuple type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> []: return {}\nfn show(empty: [], value: i32):\n    _ = empty\n    _ = value\nfn pass(empty: []): show(empty, 1)\nfn main():\n    show({}, 2)\n    show([]{}, 3)\n    show(make(), 4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_make() {\n    return;\n}\n\nvoid mn_main_show(int32_t) {}\n\nvoid mn_main_pass() {\n    mn_main_show(1);\n}\n\nint main() {\n    mn_main_show(2);\n    mn_main_show(3);\n    (mn_main_make(), mn_main_show(4));\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn first(value: i32, _: Marker) -> i32: return value\nfn apply(callback: *fn(i32, Marker) -> i32) -> i32: return callback(1, Marker{})\nfn main():\n    const step: *fn(i32, Marker) -> i32 = &first\n    _ = step(2, Marker{})\n    _ = apply(&first)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nint32_t mn_main_first(int32_t value) {\n    return value;\n}\n\nint32_t mn_main_apply(typeof(int32_t (*)(int32_t)) callback) {\n    return callback(1);\n}\n\nint main() {\n    typeof(int32_t (*)(int32_t)) const step = mn_main_first;\n    step(2);\n    mn_main_apply(mn_main_first);\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: calls through a name of a for loop" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(callbacks: [2]*fn()): for callback in callbacks: callback()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\n#ifndef mn_array_2_function_0_void_defined\n#define mn_array_2_function_0_void_defined\ntypedef struct mn_array_2_function_0_void {\n    typeof(void (*)()) items[2];\n} mn_array_2_function_0_void;\n#endif\n\nvoid mn_main_show(mn_array_2_function_0_void callbacks) {\n    for (size_t mn_index_1 = 0; mn_index_1 < 2; mn_index_1 += 1) {\n        typeof(void (*)()) const callback = callbacks.items[mn_index_1];\n        callback();\n    }\n}\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(run: *fn([]u8) -> usize, buffer: *[4]u8) -> usize: return run(buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "steps.mn", .data = "fn first(value: i32) -> i32: return value\nconst step: *fn(i32) -> i32 = &first" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import steps\nfn main(): _ = steps::step(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn apply(callback: *fn(Data) -> i32) -> i32: return callback({value = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "generateValueCall: calls through a constant without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(): noop\nconst step = &first\nfn main(): step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nvoid mn_main_first() {}\n\nint main() {\n    mn_main_first();\n}\n",
        files[1].contents,
    );
}

test "generateValueCall: calls a method through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("monolith").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nconst measure: *fn(Point) -> f32 = &Point::length\nfn main(): _ = measure(Point{x = 1.0})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nfloat mn_main_Point_length(mn_main_Point self) {\n    return self.x;\n}\n\nint main() {\n    mn_main_Point_length((mn_main_Point){ .x = 1.0f });\n}\n",
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

test "generateFields: writes a field default from its value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn start() -> i32: return 3\nstruct Point:\n    x: i32 = start()\nfn make() -> Point: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("monolith").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    const program = try analyzer.analyze();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#include \"main.h\"\n\nint32_t mn_main_start() {\n    return 3;\n}\n\nmn_main_Point mn_main_make() {\n    return (mn_main_Point){ .x = 3 };\n}\n",
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
        "#include \"main.h\"\n\n#ifndef mn_array_3_i32_defined\n#define mn_array_3_i32_defined\ntypedef struct mn_array_3_i32 {\n    int32_t items[3];\n} mn_array_3_i32;\n#endif\n\nconst mn_array_3_i32 mn_main_values = { .items = { 1, 2, 3 } };\nconst mn_main_Holder mn_main_holder = { .items = { .items = (int32_t *)(mn_main_values.items + 1), .length = 1 } };\n\nmn_main_Holder mn_main_read() {\n    return mn_main_holder;\n}\n",
        files[1].contents,
    );
}

test "generateValue: writes the value of an operation in a stored constant" {
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
        "#include \"main.h\"\n\nchar mn_zero_sized;\n\nconst int32_t mn_main_limit = 5;\n\nint main() {\n    keep(&mn_main_limit);\n}\n",
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

test "generateType: writes a pointer to a function as a C function pointer" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn apply(callback: *fn(i32, Marker, bool) -> i32, done: *fn(), maybe: ?*fn([2]u8) -> Marker):\n    _ = callback\n    _ = done\n    _ = maybe" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 10i32\nconst pair = [i32, bool]{1, true}\nexternal fn keep(value: *const i32)\nfn main():\n    keep(&limit)\n    keep(&limit)\n    keep(&pair[0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "buildCName: names a function of an instance after its type, its typeclass and its name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\nstruct Square:\n    side: i32\ninstance Shape(Square):\n    fn area(self: Square) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

test "buildTypeName: names a slice by its elements and whether they are read-only" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\ninstance Shape([]const u8):\n    fn area(self: []const u8) -> i32:\n        _ = self\n        return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("monolith").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = @import("monolith").TypeChecker.init(&arena, program);
    try type_checker.check();
    var generator = Generator.init(program);
    const files = try generator.generateFiles(arena.allocator());

    try std.testing.expectEqualStrings(
        "#pragma once\n\n#include \"runtime/monolith.h\"\n\ntypedef struct mn_slice_u8 mn_slice_u8;\n\nint32_t mn_main_slice_const_u8_Shape_area(mn_slice_u8);\n",
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\ninstance Shape(*many const u8):\n    fn area(self: *many const u8) -> i32:\n        _ = self\n        return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
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

    const path = try buildRelativePath(arena.allocator(), "hello.c", "mn/stdout.h");
    try std.testing.expectEqualStrings("mn/stdout.h", path);
}

test "buildRelativePath: walks out of directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const path = try buildRelativePath(allocator, "mn/stdout.h", "monolith.h");
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
