const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const NameResolver = struct {
    module: ast.Module,
    failure: ?token.Location = null,

    pub fn init(module: ast.Module) NameResolver {
        return .{ .module = module };
    }

    pub fn resolve(self: *NameResolver) NameError!void {
        for (self.module.declarations, 0..) |declaration, index| {
            const function_declaration = functionDeclarationOf(declaration);
            if (self.findDeclaration(function_declaration.name) != index) {
                return self.fail(function_declaration.location, error.DuplicateFunction);
            }
            try self.checkParameters(function_declaration);
            switch (declaration) {
                .function => |function| try self.resolveNamesInFunction(function),
                .external_function => {},
            }
        }
    }

    fn checkParameters(self: *NameResolver, declaration: ast.FunctionDeclaration) NameError!void {
        for (declaration.parameters, 0..) |parameter, index| {
            if (findBinding(declaration.parameters, parameter.name) != index) {
                return self.fail(parameter.location, error.DuplicateParameter);
            }
        }
    }

    fn resolveNamesInFunction(self: *NameResolver, function: ast.Function) NameError!void {
        for (function.body) |*statement| {
            try self.resolveNamesInStatement(function.declaration, statement);
        }
    }

    fn resolveNamesInStatement(
        self: *NameResolver,
        declaration: ast.FunctionDeclaration,
        statement: *ast.Statement,
    ) NameError!void {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    try self.resolveNamesInExpression(declaration, expression);
                }
            },
            .discard, .expression => |*expression| {
                try self.resolveNamesInExpression(declaration, expression);
            },
        }
    }

    fn resolveNamesInExpression(
        self: *NameResolver,
        declaration: ast.FunctionDeclaration,
        expression: *ast.Expression,
    ) NameError!void {
        const bindings = declaration.parameters;
        switch (expression.kind) {
            .integer, .float, .boolean, .string => {},
            .identifier => |*identifier| {
                if (findBinding(bindings, identifier.name)) |index| {
                    identifier.binding = index;
                    return;
                }
                if (self.findDeclaration(identifier.name) != null) {
                    return self.fail(expression.location, error.FunctionUsedAsValue);
                }
                return self.fail(expression.location, error.UnknownName);
            },
            .call => |*call| {
                if (findBinding(bindings, call.name) != null) {
                    return self.fail(expression.location, error.NotAFunction);
                }
                call.declaration = self.findDeclaration(call.name) orelse {
                    return self.fail(expression.location, error.UnknownName);
                };
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(declaration, argument);
                }
            },
        }
    }

    fn findDeclaration(self: *NameResolver, name: []const u8) ?usize {
        for (self.module.declarations, 0..) |declaration, index| {
            if (std.mem.eql(u8, functionDeclarationOf(declaration).name, name)) return index;
        }
        return null;
    }

    fn fail(self: *NameResolver, location: token.Location, name_error: NameError) NameError {
        self.failure = location;
        return name_error;
    }
};

pub const NameError = error{
    DuplicateFunction,
    DuplicateParameter,
    UnknownName,
    NotAFunction,
    FunctionUsedAsValue,
};

fn functionDeclarationOf(declaration: ast.Declaration) ast.FunctionDeclaration {
    return switch (declaration) {
        .function => |function| function.declaration,
        .external_function => |external_function| external_function,
    };
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
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = add(1, 2)\nfn add(left: i32, right: i32) i32: return right");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);
    try name_resolver.resolve();

    try std.testing.expectEqual(1, module.declarations[0].function.body[0].kind.discard.kind.call.declaration);
    try std.testing.expectEqual(1, module.declarations[1].function.body[0].kind.@"return".?.kind.identifier.binding);
}

test "NameResolver.resolve: resolves calls to external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn console_write(text: String)\nfn main(): console_write(\"hi\")");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);
    try name_resolver.resolve();

    try std.testing.expectEqual(0, module.declarations[1].function.body[0].kind.expression.kind.call.declaration);
}

test "NameResolver.resolve: rejects a duplicate function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn one(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?);
}

test "checkParameters: rejects a duplicate parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(value: i32, value: i32): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.DuplicateParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?);
}

test "resolveNamesInExpression: lets a parameter shadow a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32) i32: return left\nfn twice(add: i32) i32: return add");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);
    try name_resolver.resolve();

    try std.testing.expectEqual(0, module.declarations[1].function.body[0].kind.@"return".?.kind.identifier.binding);
}

test "resolveNamesInExpression: rejects an unknown call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(1)");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?);
}

test "resolveNamesInExpression: rejects an unknown value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn value() i32: return missing");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, name_resolver.failure.?);
}

test "resolveNamesInExpression: rejects an unknown argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): log(missing)\nfn log(value: i32): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, name_resolver.failure.?);
}

test "resolveNamesInExpression: rejects calling a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn twice(add: i32): add(add)");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?);
}

test "resolveNamesInExpression: rejects a function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn two() i32: return one");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);

    try std.testing.expectError(error.FunctionUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, name_resolver.failure.?);
}
