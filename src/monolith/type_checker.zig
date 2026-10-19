const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

pub const TypeChecker = struct {
    program: ast.Program,
    module_index: usize = 0,
    failure: ?Failure = null,

    pub fn init(program: ast.Program) TypeChecker {
        return .{ .program = program };
    }

    pub fn check(self: *TypeChecker) TypeError!void {
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            for (module.declarations) |declaration| {
                switch (declaration.kind) {
                    .function_definition => |function| try self.checkFunction(function),
                    .function_declaration => |function_declaration| {
                        try self.checkExternalFunction(function_declaration, declaration.location);
                    },
                    .constant_declaration => {},
                }
            }
        }
    }

    fn checkFunction(self: *TypeChecker, function: ast.FunctionDefinition) TypeError!void {
        const signature = function.signature;
        if (std.mem.eql(u8, signature.name, "main")) {
            if (ast.extractType(signature.return_type) != .void) {
                return self.fail(signature.return_type.location, error.MainHasReturnType);
            }
            if (signature.parameters.len > 0) {
                return self.fail(signature.parameters[0].location, error.MainHasParameters);
            }
        }

        for (function.body) |*statement| try self.checkStatement(signature, statement);

        const return_type = signature.return_type;
        if (ast.extractType(return_type) == .void) return;
        const last = function.body[function.body.len - 1];
        if (last.kind != .@"return") return self.fail(return_type.location, error.MissingReturn);
    }

    fn checkExternalFunction(
        self: *TypeChecker,
        signature: ast.FunctionSignature,
        location: token.Location,
    ) TypeError!void {
        if (std.mem.eql(u8, signature.name, "main")) {
            return self.fail(location, error.MainIsExternal);
        }
    }

    fn checkStatement(
        self: *TypeChecker,
        signature: ast.FunctionSignature,
        statement: *ast.Statement,
    ) TypeError!void {
        const parameters = signature.parameters;
        const return_type = ast.extractType(signature.return_type);
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    if (return_type == .void) {
                        return self.fail(expression.location, error.UnexpectedReturnValue);
                    }
                    try self.checkExpression(parameters, expression, return_type);
                } else if (return_type != .void) {
                    return self.fail(statement.location, error.MissingReturnValue);
                }
            },
            .discard => |*expression| {
                if (try self.checkCall(parameters, expression) == .void) {
                    return self.fail(expression.location, error.DiscardedVoid);
                }
            },
            .call => |*expression| {
                if (try self.checkCall(parameters, expression) != .void) {
                    return self.fail(expression.location, error.UnusedResult);
                }
            },
        }
    }

    fn checkExpression(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal => {
                try self.checkLiteral(expression.*, expected);
            },
            inline .identifier, .path_expression => |name| {
                const value_type = try self.computeValueType(parameters, name.resolution.?);
                if (!std.meta.eql(value_type, expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .call => {
                if (!std.meta.eql(try self.checkCall(parameters, expression), expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .@"struct" => unreachable,
        }
        expression.type = expected;
    }

    fn computeValueType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        resolution: ast.Resolution,
    ) TypeError!types.Type {
        return switch (resolution) {
            .parameter => |index| ast.extractType(parameters[index].type),
            .type => .type,
            .constant => |constant| self.checkConstant(constant),
            .function => unreachable,
        };
    }

    fn checkConstant(self: *TypeChecker, constant: ast.Resolution.Constant) TypeError!types.Type {
        const module = self.program.modules[constant.module];
        const value = &module.declarations[constant.declaration].kind.constant_declaration.value;
        if (value.type) |value_type| return value_type;
        const caller_module_index = self.module_index;
        self.module_index = constant.module;
        defer self.module_index = caller_module_index;
        const value_type = try self.computeLiteralType(value.*);
        try self.checkLiteral(value.*, value_type);
        value.type = value_type;
        return value_type;
    }

    fn computeLiteralType(self: *TypeChecker, expression: ast.Expression) TypeError!types.Type {
        return switch (expression.kind) {
            .integer_literal, .float_literal => |literal| {
                const suffix = literal.suffix orelse {
                    return self.fail(expression.location, error.UnknownValueType);
                };
                const number = types.findNumberType(suffix) orelse {
                    return self.fail(expression.location, error.UnknownSuffix);
                };
                return .{ .number = number };
            },
            .boolean_literal => .boolean,
            .string_literal => .string,
            .identifier, .path_expression, .call, .@"struct" => unreachable,
        };
    }

    fn checkLiteral(
        self: *TypeChecker,
        expression: ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        switch (expression.kind) {
            .integer_literal => |literal| {
                const number = try self.expectNumber(expression.location, literal, expected);
                const maximum = computeIntegerMaximum(number) orelse {
                    return self.fail(expression.location, error.TypeMismatch);
                };
                const value = std.fmt.parseInt(u64, literal.text, 0) catch {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                };
                if (value > maximum) {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                }
            },
            .float_literal => |literal| {
                const number = try self.expectNumber(expression.location, literal, expected);
                const fits = switch (number) {
                    .f32 => fitsFloat(f32, literal.text),
                    .f64 => fitsFloat(f64, literal.text),
                    else => return self.fail(expression.location, error.TypeMismatch),
                };
                if (!fits) return self.fail(expression.location, error.LiteralOutOfRange);
            },
            .boolean_literal => {
                if (expected != .boolean) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .string_literal => {
                if (expected != .string) return self.fail(expression.location, error.TypeMismatch);
            },
            .identifier, .path_expression, .call, .@"struct" => unreachable,
        }
    }

    fn expectNumber(
        self: *TypeChecker,
        location: token.Location,
        literal: token.NumberLiteral,
        expected: types.Type,
    ) TypeError!types.NumberType {
        const number = switch (expected) {
            .number => |number| number,
            .boolean, .string, .void, .type, .@"struct" => {
                return self.fail(location, error.TypeMismatch);
            },
        };
        const suffix = literal.suffix orelse return number;
        const suffix_type = types.findNumberType(suffix) orelse {
            return self.fail(location, error.UnknownSuffix);
        };
        if (suffix_type != number) return self.fail(location, error.TypeMismatch);
        return number;
    }

    fn checkCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const call = expression.kind.call;
        const function = switch (call.callee) {
            inline else => |callee| callee.resolution.?.function,
        };
        const declarations = self.program.modules[function.module].declarations;
        const callee = extractFunctionSignature(declarations[function.declaration]);
        if (std.mem.eql(u8, callee.name, "main")) {
            return self.fail(expression.location, error.MainCalled);
        }
        if (call.arguments.len != callee.parameters.len) {
            return self.fail(expression.location, error.ArgumentCountMismatch);
        }
        for (call.arguments, callee.parameters) |*argument, parameter| {
            const parameter_type = ast.extractType(parameter.type);
            try self.checkExpression(parameters, argument, parameter_type);
        }

        const return_type = ast.extractType(callee.return_type);
        expression.type = return_type;
        return return_type;
    }

    fn fail(self: *TypeChecker, location: token.Location, type_error: TypeError) TypeError {
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = describeError(type_error),
        };
        return type_error;
    }
};

pub const TypeError = error{
    TypeMismatch,
    LiteralOutOfRange,
    MissingReturnValue,
    UnexpectedReturnValue,
    MissingReturn,
    MainHasReturnType,
    MainHasParameters,
    MainCalled,
    MainIsExternal,
    ArgumentCountMismatch,
    UnusedResult,
    DiscardedVoid,
    UnknownSuffix,
    UnknownValueType,
};

fn describeError(type_error: TypeError) []const u8 {
    return switch (type_error) {
        error.TypeMismatch => "value does not match the expected type",
        error.LiteralOutOfRange => "literal out of range for its type",
        error.MissingReturnValue => "missing return value",
        error.UnexpectedReturnValue => "void function cannot return a value",
        error.MissingReturn => "function must end with a return",
        error.MainHasReturnType => "main cannot have a return type",
        error.MainHasParameters => "main cannot have parameters",
        error.MainCalled => "main cannot be called",
        error.MainIsExternal => "main cannot be external",
        error.ArgumentCountMismatch => "wrong number of arguments",
        error.UnusedResult => "call result is unused, discard it with _ =",
        error.DiscardedVoid => "call returns no value to discard",
        error.UnknownSuffix => "unknown suffix",
        error.UnknownValueType => "value has no known type",
    };
}

fn extractFunctionSignature(declaration: ast.Declaration) ast.FunctionSignature {
    return switch (declaration.kind) {
        .function_definition => |function| function.signature,
        .function_declaration => |function_declaration| function_declaration,
        .constant_declaration => unreachable,
    };
}

fn computeIntegerMaximum(number: types.NumberType) ?u64 {
    return switch (number) {
        .i8 => std.math.maxInt(i8),
        .i16 => std.math.maxInt(i16),
        .i32 => std.math.maxInt(i32),
        .i64 => std.math.maxInt(i64),
        .u8 => std.math.maxInt(u8),
        .u16 => std.math.maxInt(u16),
        .u32 => std.math.maxInt(u32),
        .u64 => std.math.maxInt(u64),
        .f32, .f64 => null,
    };
}

fn fitsFloat(comptime Float: type, text: []const u8) bool {
    const value = std.fmt.parseFloat(Float, text) catch return false;
    return std.math.isFinite(value);
}

test "TypeChecker.check: sets the type of each returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() u8: return 255\nfn two() f32: return 2.5\nfn three() Bool: return true\nfn four() i64: return 1_i64\nfn main(): return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .u8 }, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .f32 }, loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type.boolean, loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .i64 }, loader.modules.items[0].declarations[3].kind.function_definition.body[0].kind.@"return".?.type);
}

test "TypeChecker.check: sets the type of calls, arguments and names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) i32: return left\nfn main(): _ = add(1, 2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .i32 }, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.type);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.kind.call.arguments[0].type);
}

test "checkFunction: rejects a return type on main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() i32: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MainHasReturnType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects parameters on main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MainHasParameters, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects a missing return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, type_checker.failure.?.location.?);
}

test "checkExternalFunction: rejects an external main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn main()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MainIsExternal, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a missing return value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MissingReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a value in a void function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): return 5" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects an unused result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return 1\nfn main(): one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.UnusedResult, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects discarding a void call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn main(): _ = log()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.DiscardedVoid, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a boolean for an integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an integer literal for a float type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn ratio() f64: return 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float literal for an integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: return 2.5" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a suffix of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: return 5u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float suffix of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn ratio() f64: return 2.5f32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts the maximum of each integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{
        .sub_path = "main.mn",
        .data =
        \\fn one() i8: return 127
        \\fn two() i16: return 32767
        \\fn three() i32: return 2147483647
        \\fn four() i64: return 9223372036854775807
        \\fn five() u8: return 255
        \\fn six() u16: return 65535
        \\fn seven() u32: return 4294967295
        \\fn eight() u64: return 18446744073709551615
        ,
    });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try type_checker.check();
}

test "checkExpression: rejects one past the maximum of each integer type" {
    const sources = [_][]const u8{
        "fn value() i8: return 128",
        "fn value() i16: return 32768",
        "fn value() i32: return 2147483648",
        "fn value() i64: return 9223372036854775808",
        "fn value() u8: return 256",
        "fn value() u16: return 65536",
        "fn value() u32: return 4294967296",
        "fn value() u64: return 18446744073709551616",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var program_directory = std.testing.tmpDir(.{});
        defer program_directory.cleanup();
        const program_path = try std.fs.path.join(
            arena.allocator(),
            &.{ ".zig-cache", "tmp", &program_directory.sub_path },
        );
        var loader = @import("loader.zig").Loader.init(program_path, program_path);
        try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = source });
        try loader.loadMainModule(&arena, std.testing.io, "main");
        var type_registry: types.Registry = .{};
        var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
        try name_resolver.resolve();
        var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

        try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    }
}

test "checkExpression: rejects a suffixed literal out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small() u8: return 300u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an integer beyond 64 bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn big() u64: return 18446744073709551616" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn huge() f32: return 1e39" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a type as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return i32\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, type_checker.failure.?.location.?);
    try std.testing.expectEqualStrings("value does not match the expected type", type_checker.failure.?.message);
}

test "checkExpression: rejects a parameter of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: i32) u8: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 32 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a call of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() u8: return 1\nfn two() i32: return one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a void call as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn two() i32: return log()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkExpression: gives a string literal the String type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() String: return \"hello\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type.string, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
}

test "checkExpression: rejects a string for an integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() i32: return \"42\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an integer for String" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn name() String: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkConstant: gives each use the type of the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() u64: return limit\nfn two() u64: return limit\nconst limit = 7u64\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[1].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[2].kind.constant_declaration.value.type);
}

test "checkConstant: rejects a value of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return limit\nconst limit = true\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkConstant: checks the value in the module of the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "limits.mn", .data = "const maximum = 300u8" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() u8: return limits::maximum\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[1].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, type_checker.failure.?.location.?);
}

test "computeLiteralType: rejects a number without a suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return limit\nconst limit = 5\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, type_checker.failure.?.location.?);
}

test "computeLiteralType: rejects an unknown suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() i32: return limit\nconst limit = 5Bool\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownSuffix, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, type_checker.failure.?.location.?);
}

test "expectNumber: rejects an unknown suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() u8: return 5Bool" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownSuffix, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?.location.?);
}

test "expectNumber: rejects a float suffix on an integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() f64: return 1f64" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?.location.?);
}

test "expectNumber: rejects an integer suffix on a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() u8: return 2.5u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(.{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects calling main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn helper(): main()\nfn main(): helper()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.MainCalled, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, type_checker.failure.?.location.?);
}

test "checkCall: checks arguments of external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: u8)\nfn main(): take(300)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkCall: checks arguments against a function of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn take(value: i32): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::take(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[0].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects a wrong number of arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) i32: return left\nfn main(): _ = add(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.ArgumentCountMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects an argument of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn flag(value: Bool): noop\nfn main(): flag(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkCall: checks literal arguments against their parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small(value: u8): noop\nfn main(): small(300)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, type_checker.failure.?.location.?);
}
