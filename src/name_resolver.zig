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
        for (self.module.functions, 0..) |function, index| {
            if (self.findFunction(function.name) != index) {
                return self.fail(function.location, error.DuplicateFunction);
            }
            try self.resolveFunction(function);
        }
    }

    fn resolveFunction(self: *NameResolver, function: ast.Function) NameError!void {
        for (function.parameters, 0..) |parameter, index| {
            if (findBinding(function.parameters, parameter.name) != index) {
                return self.fail(parameter.location, error.DuplicateParameter);
            }
        }
        for (function.body) |*statement| try self.resolveStatement(function, statement);
    }

    fn resolveStatement(
        self: *NameResolver,
        function: ast.Function,
        statement: *ast.Statement,
    ) NameError!void {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| try self.resolveExpression(function, expression);
            },
            .discard, .expression => |*expression| try self.resolveExpression(function, expression),
        }
    }

    fn resolveExpression(
        self: *NameResolver,
        function: ast.Function,
        expression: *ast.Expression,
    ) NameError!void {
        const bindings = function.parameters;
        switch (expression.kind) {
            .integer, .float, .boolean => {},
            .identifier => |*identifier| {
                if (findBinding(bindings, identifier.name)) |index| {
                    identifier.binding = index;
                    return;
                }
                if (self.findFunction(identifier.name) != null) {
                    return self.fail(expression.location, error.FunctionUsedAsValue);
                }
                return self.fail(expression.location, error.UnknownName);
            },
            .call => |*call| {
                if (findBinding(bindings, call.name) != null) {
                    return self.fail(expression.location, error.NotAFunction);
                }
                call.function = self.findFunction(call.name) orelse {
                    return self.fail(expression.location, error.UnknownName);
                };
                for (call.arguments) |*argument| try self.resolveExpression(function, argument);
            },
        }
    }

    fn findFunction(self: *NameResolver, name: []const u8) ?usize {
        for (self.module.functions, 0..) |function, index| {
            if (std.mem.eql(u8, function.name, name)) return index;
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

    try std.testing.expectEqual(1, module.functions[0].body[0].kind.discard.kind.call.function);
    try std.testing.expectEqual(1, module.functions[1].body[0].kind.@"return".?.kind.identifier.binding);
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

test "resolveFunction: rejects a duplicate parameter" {
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

test "resolveExpression: lets a parameter shadow a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32) i32: return left\nfn twice(add: i32) i32: return add");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = NameResolver.init(module);
    try name_resolver.resolve();

    try std.testing.expectEqual(0, module.functions[1].body[0].kind.@"return".?.kind.identifier.binding);
}

test "resolveExpression: rejects an unknown call" {
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

test "resolveExpression: rejects an unknown value" {
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

test "resolveExpression: rejects an unknown argument" {
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

test "resolveExpression: rejects calling a parameter" {
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

test "resolveExpression: rejects a function used as a value" {
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
