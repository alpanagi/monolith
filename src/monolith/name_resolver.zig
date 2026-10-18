const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;
const Loader = @import("loader.zig").Loader;
const LoadError = @import("loader.zig").LoadError;
const Namespace = @import("loader.zig").Namespace;

pub const NameResolver = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    loader: *Loader,
    module_index: usize = 0,
    constant_depth: usize = 0,
    failure: ?Failure = null,

    pub fn init(arena: *std.heap.ArenaAllocator, io: std.Io, loader: *Loader) NameResolver {
        return .{ .arena = arena, .io = io, .loader = loader };
    }

    pub fn resolve(self: *NameResolver) ResolveError!void {
        var index: usize = 0;
        while (index < self.loader.modules.items.len) : (index += 1) {
            self.module_index = index;
            try self.resolveModule();
        }
    }

    fn resolveModule(self: *NameResolver) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const reserves_names = !isStandardLibrary(module.path);
        for (module.declarations, 0..) |declaration, index| {
            const name = extractName(declaration);
            const location = declaration.location;
            if (findDeclaration(module, name) != index) {
                if (declaration.kind == .constant_declaration) {
                    return self.fail(location, error.DuplicateConstant);
                }
                return self.fail(location, error.DuplicateFunction);
            }
            if (isBuiltInTypeName(name) or (reserves_names and hasReservedPrefix(name))) {
                return self.fail(location, error.ReservedName);
            }
            switch (declaration.kind) {
                .function_definition => |function| {
                    try self.checkParameters(function.signature, reserves_names);
                    const definition = &module.declarations[index].kind.function_definition;
                    try self.resolveFunctionTypes(&definition.signature);
                    try self.resolveNamesInFunction(function);
                },
                .function_declaration => |function_declaration| {
                    try self.checkParameters(function_declaration, reserves_names);
                    const kind = &module.declarations[index].kind;
                    try self.resolveFunctionTypes(&kind.function_declaration);
                },
                .constant_declaration => {},
            }
        }
    }

    fn checkParameters(
        self: *NameResolver,
        signature: ast.FunctionSignature,
        reserves_names: bool,
    ) ResolveError!void {
        for (signature.parameters, 0..) |parameter, index| {
            if (findBinding(signature.parameters, parameter.name) != index) {
                return self.fail(parameter.location, error.DuplicateParameter);
            }
            const reserved = reserves_names and hasReservedPrefix(parameter.name);
            if (isBuiltInTypeName(parameter.name) or reserved) {
                return self.fail(parameter.location, error.ReservedName);
            }
        }
    }

    fn resolveFunctionTypes(
        self: *NameResolver,
        signature: *ast.FunctionSignature,
    ) ResolveError!void {
        for (signature.parameters) |*parameter| {
            try self.resolveNamesInExpression(&.{}, &parameter.type);
        }
        try self.resolveNamesInExpression(&.{}, &signature.return_type);
    }

    fn resolveNamesInFunction(
        self: *NameResolver,
        function: ast.FunctionDefinition,
    ) ResolveError!void {
        for (function.body) |*statement| {
            try self.resolveNamesInStatement(function.signature.parameters, statement);
        }
    }

    fn resolveNamesInStatement(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        statement: *ast.Statement,
    ) ResolveError!void {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    try self.resolveNamesInExpression(bindings, expression);
                }
            },
            .discard, .call => |*expression| {
                try self.resolveNamesInExpression(bindings, expression);
            },
        }
    }

    fn resolveNamesInExpression(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        expression: *ast.Expression,
    ) ResolveError!void {
        const location = expression.location;
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal => {},
            .identifier => |*identifier| try self.resolveIdentifier(bindings, location, identifier),
            .path_expression => |*path_expression| {
                const target = try self.resolvePath(bindings, location, path_expression.path);
                path_expression.resolution = try self.expectValue(location, target);
            },
            .call => |*call| {
                try self.resolveCallee(bindings, location, &call.callee);
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(bindings, argument);
                }
            },
        }
    }

    fn resolveIdentifier(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        location: token.Location,
        identifier: *ast.Identifier,
    ) ResolveError!void {
        if (findBinding(bindings, identifier.name)) |index| {
            identifier.resolution = .{ .parameter = index };
            return;
        }
        const target = try self.resolveName(location, identifier.name);
        identifier.resolution = try self.expectValue(location, target);
    }

    fn expectValue(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) NameError!ast.Resolution {
        return switch (target) {
            .type => |value| .{ .type = value },
            .constant => |constant| .{ .constant = constant },
            .function => self.fail(location, error.FunctionUsedAsValue),
            .namespace => self.fail(location, error.UnknownName),
        };
    }

    fn resolveCallee(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        location: token.Location,
        callee: *ast.Name,
    ) ResolveError!void {
        switch (callee.*) {
            .identifier => |*identifier| {
                const name = identifier.name;
                if (findBinding(bindings, name) != null) {
                    return self.fail(location, error.NotAFunction);
                }
                const target = try self.resolveName(location, name);
                const function = try self.expectFunction(location, target);
                identifier.resolution = .{ .function = function };
            },
            .path_expression => |*path_expression| {
                const target = try self.resolvePath(bindings, location, path_expression.path);
                const function = try self.expectFunction(location, target);
                path_expression.resolution = .{ .function = function };
            },
        }
    }

    fn expectFunction(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) ResolveError!ast.Resolution.Function {
        return switch (target) {
            .function => |function| function,
            .namespace, .type, .constant => self.fail(location, error.NotAFunction),
        };
    }

    fn resolveName(
        self: *NameResolver,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Target {
        const module = self.loader.modules.items[self.module_index];
        if (findDeclaration(module, name)) |index| {
            return self.resolveDeclaration(self.module_index, index);
        }
        if (types.findBuiltInType(name)) |built_in_type| return .{ .type = built_in_type };
        if (try self.loadRoot(location, name)) |namespace| return .{ .namespace = namespace };
        return self.fail(location, error.UnknownName);
    }

    fn resolvePath(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        location: token.Location,
        path: ast.Path,
    ) ResolveError!Target {
        var namespace = try self.resolveFirstNamespace(bindings, location, path[0]);
        for (path[1 .. path.len - 1]) |name| {
            namespace = try self.resolveMemberNamespace(location, namespace, name);
        }
        return self.resolveMember(location, namespace, path[path.len - 1]);
    }

    fn resolveFirstNamespace(
        self: *NameResolver,
        bindings: []const ast.Parameter,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Namespace {
        const module = self.loader.modules.items[self.module_index];
        if (try self.findConstantNamespace(self.module_index, name)) |namespace| return namespace;
        if (try self.loadRoot(location, name)) |namespace| return namespace;
        if (findDeclaration(module, name) != null) return self.fail(location, error.NoMembers);
        if (isBuiltInTypeName(name)) return self.fail(location, error.NoMembers);
        if (findBinding(bindings, name) != null) return self.fail(location, error.NoMembers);
        return self.fail(location, error.UnknownName);
    }

    fn resolveMemberNamespace(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Namespace {
        if (namespace.module) |module_index| {
            if (try self.findConstantNamespace(module_index, name)) |target| return target;
        }
        if (try self.loadMember(namespace, name)) |member| return member;
        if (namespace.module) |module_index| {
            if (findDeclaration(self.loader.modules.items[module_index], name) != null) {
                return self.fail(location, error.NoMembers);
            }
        }
        if (namespace.directory) return self.fail(location, error.ModuleNotFound);
        return self.fail(location, error.UnknownName);
    }

    fn resolveMember(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Target {
        if (namespace.module) |module_index| {
            const module = self.loader.modules.items[module_index];
            if (findDeclaration(module, name)) |index| {
                return self.resolveDeclaration(module_index, index);
            }
        }
        if (try self.loadMember(namespace, name)) |member| return .{ .namespace = member };
        return self.fail(location, error.UnknownName);
    }

    fn findConstantNamespace(
        self: *NameResolver,
        module_index: usize,
        name: []const u8,
    ) ResolveError!?Namespace {
        const module = self.loader.modules.items[module_index];
        const index = findDeclaration(module, name) orelse return null;
        if (module.declarations[index].kind != .constant_declaration) return null;
        return switch (try self.resolveConstant(module_index, index)) {
            .function, .type, .constant => null,
            .namespace => |namespace| namespace,
        };
    }

    fn resolveDeclaration(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!Target {
        return switch (self.loader.modules.items[module_index].declarations[index].kind) {
            .function_definition, .function_declaration => .{
                .function = .{ .module = module_index, .declaration = index },
            },
            .constant_declaration => self.resolveConstant(module_index, index),
        };
    }

    fn resolveConstant(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = self.loader.modules.items[module_index].declarations[index];
        const constant = declaration.kind.constant_declaration;
        const caller_module_index = self.module_index;
        self.module_index = module_index;
        defer self.module_index = caller_module_index;
        self.constant_depth += 1;
        defer self.constant_depth -= 1;
        if (self.constant_depth > countConstants(self.loader.modules.items)) {
            return self.fail(declaration.location, error.ConstantRefersToItself);
        }
        const value = constant.value;
        return switch (value.kind) {
            .identifier => |identifier| self.resolveName(declaration.location, identifier.name),
            .path_expression => |path_expression| {
                return self.resolvePath(&.{}, declaration.location, path_expression.path);
            },
            .integer_literal, .float_literal, .boolean_literal, .string_literal => .{
                .constant = .{ .module = module_index, .declaration = index },
            },
            .call => self.fail(value.location, error.CannotEvaluate),
        };
    }

    fn loadRoot(
        self: *NameResolver,
        location: token.Location,
        name: []const u8,
    ) ResolveError!?Namespace {
        const namespace = self.loader.loadRoot(
            self.arena,
            self.io,
            self.module_index,
            location,
            name,
        ) catch |load_error| {
            return self.failLoading(load_error);
        };
        return namespace;
    }

    fn loadMember(
        self: *NameResolver,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!?Namespace {
        const member = self.loader.loadMember(
            self.arena,
            self.io,
            namespace,
            name,
        ) catch |load_error| {
            return self.failLoading(load_error);
        };
        return member;
    }

    fn failLoading(self: *NameResolver, load_error: LoadError) LoadError {
        self.failure = self.loader.failure;
        return load_error;
    }

    fn fail(self: *NameResolver, location: token.Location, name_error: NameError) NameError {
        self.failure = .{
            .module = self.loader.modules.items[self.module_index].path,
            .location = location,
            .message = describeError(name_error),
        };
        return name_error;
    }
};

pub const ResolveError = NameError || LoadError;

pub const NameError = error{
    DuplicateFunction,
    DuplicateConstant,
    DuplicateParameter,
    ReservedName,
    UnknownName,
    NotAFunction,
    FunctionUsedAsValue,
    NoMembers,
    ModuleNotFound,
    ConstantRefersToItself,
    CannotEvaluate,
};

const Target = union(enum) {
    function: ast.Resolution.Function,
    namespace: Namespace,
    type: types.Type,
    constant: ast.Resolution.Constant,
};

fn describeError(name_error: NameError) []const u8 {
    return switch (name_error) {
        error.DuplicateFunction => "function is already defined",
        error.DuplicateConstant => "constant is already defined",
        error.DuplicateParameter => "parameter is already defined",
        error.ReservedName => "name is reserved",
        error.UnknownName => "unknown name",
        error.NotAFunction => "name is not a function",
        error.FunctionUsedAsValue => "functions cannot be used as values",
        error.NoMembers => "name has no members",
        error.ModuleNotFound => "module not found",
        error.ConstantRefersToItself => "constant refers to itself",
        error.CannotEvaluate => "cannot be evaluated at compile time",
    };
}

fn countConstants(modules: []const ast.Module) usize {
    var count: usize = 0;
    for (modules) |module| {
        for (module.declarations) |declaration| {
            if (declaration.kind == .constant_declaration) count += 1;
        }
    }
    return count;
}

fn isStandardLibrary(path: ast.Path) bool {
    return path.len > 1 and std.mem.eql(u8, path[0], "std");
}

fn extractName(declaration: ast.Declaration) []const u8 {
    return switch (declaration.kind) {
        .function_definition => |function| function.signature.name,
        .function_declaration => |function_declaration| function_declaration.name,
        .constant_declaration => |constant| constant.name,
    };
}

fn findDeclaration(module: ast.Module, name: []const u8) ?usize {
    for (module.declarations, 0..) |declaration, index| {
        if (std.mem.eql(u8, extractName(declaration), name)) return index;
    }
    return null;
}

fn isBuiltInTypeName(name: []const u8) bool {
    return types.findBuiltInType(name) != null;
}

fn hasReservedPrefix(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mn_");
}

fn findBinding(bindings: []const ast.Parameter, name: []const u8) ?usize {
    for (bindings, 0..) |binding, index| {
        if (std.mem.eql(u8, binding.name, name)) return index;
    }
    return null;
}

test "NameResolver.resolve: records what each name refers to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = add(1, 2)\nfn add(left: i32, right: i32) i32: return right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.discard.kind.call;
    try std.testing.expectEqual(1, call.callee.identifier.resolution.?.function.declaration);
    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(1, value.kind.identifier.resolution.?.parameter);
}

test "NameResolver.resolve: resolves calls to external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn console_write(text: String)\nfn main(): console_write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.identifier.resolution.?.function;
    try std.testing.expectEqual(0, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveModule: rejects a duplicate function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn one(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a duplicate constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst one = two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.DuplicateConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a reserved name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mn_write(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: allows reserved names in the standard library" {
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
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::console::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveModule: rejects a type name as a function name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn String(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "checkParameters: rejects a duplicate parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: i32, value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.DuplicateParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "checkParameters: rejects a reserved parameter name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(mn_value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, name_resolver.failure.?.location.?);
}

test "checkParameters: rejects a type name as a parameter name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(i32: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionTypes: resolves built-in types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: i32) Bool: return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[0].kind.function_definition.signature;
    const parameter_type = signature.parameters[0].type.kind.identifier.resolution.?;
    try std.testing.expectEqual(ast.Resolution{ .type = .{ .number = .i32 } }, parameter_type);
    try std.testing.expectEqual(ast.Resolution{ .type = .boolean }, signature.return_type.kind.identifier.resolution.?);
}

test "resolveFunctionTypes: rejects an unknown type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: Integer): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInExpression: rejects an unknown argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): log(missing)\nfn log(value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInExpression: rejects a function of another module used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() i32: return 1" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() i32: return utils::add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.FunctionUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, name_resolver.failure.?.location.?);
}

test "resolveIdentifier: lets a parameter shadow a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) i32: return left\nfn twice(add: i32) i32: return add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(0, value.kind.identifier.resolution.?.parameter);
}

test "resolveIdentifier: rejects an unknown value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() i32: return missing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, name_resolver.failure.?.location.?);
    try std.testing.expectEqualStrings("unknown name", name_resolver.failure.?.message);
}

test "resolveIdentifier: rejects a function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two() i32: return one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.FunctionUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: rejects an unknown call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): log(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: rejects calling a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn twice(add: i32): add(add)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: rejects calling a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: calls a function through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const write = add\nfn add(): noop\nfn main(): write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.callee.identifier.resolution.?.function;
    try std.testing.expectEqual(0, function.module);
    try std.testing.expectEqual(1, function.declaration);
}

test "resolvePath: resolves a call through a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop\nfn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(1, function.declaration);
}

test "resolvePath: resolves a call through a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::console::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolvePath: resolves a call through a constant that names a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const console = std::console\nfn main(): console::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveFirstNamespace: rejects members of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(value: i32): value::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: looks past a parameter before a path separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop\nfn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(utils: i32): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(1, function.declaration);
}

test "resolveMemberNamespace: rejects members of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects a module missing from a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::missing::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ModuleNotFound, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: lets a function share its name with a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn math(): noop" });
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
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    utils::math()\n    utils::math::add()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const function = body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    const module_function = body[1].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(2, module_function.module);
}

test "resolveMember: rejects a call that ends at a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils/math");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::math()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: rejects a name the module does not declare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::missing()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: follows a constant into the modules below what it names" {
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
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const tools = utils\nfn main(): tools::math::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call;
    const function = call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualStrings("math", loader.modules.items[function.module].path[1]);
}

test "resolveConstant: rejects constants that refer to each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one = two\nconst two = one\nfn main(): one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ConstantRefersToItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: leaves constants that nothing uses alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one = two\nconst two = one\nconst missing = nothing::here" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    try std.testing.expectEqual(1, loader.modules.items.len);
}
test "resolveConstant: reports errors in the value at the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "output.mn", .data = "const write = std::missing" });
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/console.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): output::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: resolves a constant that names a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Integer = i32\nfn add(value: Integer): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const parameter_type = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type;
    try std.testing.expectEqual(ast.Resolution{ .type = .{ .number = .i32 } }, parameter_type.kind.identifier.resolution.?);
}

test "resolveConstant: resolves a constant that holds a literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return limit\nconst limit = other\nconst other = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 2 } }, value.kind.identifier.resolution.?);
}

test "resolveConstant: rejects a call as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return total\nconst total = one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, name_resolver.failure.?.location.?);
}

test "loadRoot: reports the reserved name monolith at the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "monolith.mn", .data = "fn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): monolith::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.ReservedModuleName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "failLoading: reports failures in the module that is loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one():\n\tnoop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader);

    try std.testing.expectError(error.UnexpectedTab, name_resolver.resolve());
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}
