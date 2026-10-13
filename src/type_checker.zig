const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const TypeChecker = struct {
    module: ast.Module,
    failure: ?token.Location = null,

    pub fn init(module: ast.Module) TypeChecker {
        return .{ .module = module };
    }

    pub fn check(self: *TypeChecker) TypeError!void {
        for (self.module.functions) |function| try self.checkFunction(function);
    }

    fn checkFunction(self: *TypeChecker, function: ast.Function) TypeError!void {
        const return_type = function.return_type;
        if (std.mem.eql(u8, function.name, "main") and return_type.primitive_type != .void) {
            return self.fail(return_type.location, error.MainHasReturnType);
        }

        for (function.body) |*statement| {
            try self.checkStatement(statement, return_type.primitive_type);
        }

        if (return_type.primitive_type == .void) return;
        const last = function.body[function.body.len - 1];
        if (last.kind != .@"return") return self.fail(return_type.location, error.MissingReturn);
    }

    fn checkStatement(
        self: *TypeChecker,
        statement: *ast.Statement,
        return_type: token.PrimitiveType,
    ) TypeError!void {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    if (return_type == .void) {
                        return self.fail(expression.location, error.UnexpectedReturnValue);
                    }
                    try self.checkExpression(expression, return_type);
                } else if (return_type != .void) {
                    return self.fail(statement.location, error.MissingReturnValue);
                }
            },
        }
    }

    fn checkExpression(
        self: *TypeChecker,
        expression: *ast.Expression,
        expected: token.PrimitiveType,
    ) TypeError!void {
        switch (expression.kind) {
            .integer => |literal| {
                if ((literal.suffix orelse expected) != expected) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
                const maximum = integerMaximum(expected) orelse {
                    return self.fail(expression.location, error.TypeMismatch);
                };
                const value = std.fmt.parseInt(u64, literal.text, 0) catch {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                };
                if (value > maximum) {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                }
            },
            .float => |literal| {
                if ((literal.suffix orelse expected) != expected) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
                const fits = switch (expected) {
                    .f32 => fitsFloat(f32, literal.text),
                    .f64 => fitsFloat(f64, literal.text),
                    else => return self.fail(expression.location, error.TypeMismatch),
                };
                if (!fits) return self.fail(expression.location, error.LiteralOutOfRange);
            },
            .boolean => {
                if (expected != .bool) return self.fail(expression.location, error.TypeMismatch);
            },
        }
        expression.primitive_type = expected;
    }

    fn fail(self: *TypeChecker, location: token.Location, type_error: TypeError) TypeError {
        self.failure = location;
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
};

fn integerMaximum(primitive_type: token.PrimitiveType) ?u64 {
    return switch (primitive_type) {
        .i8 => std.math.maxInt(i8),
        .i16 => std.math.maxInt(i16),
        .i32 => std.math.maxInt(i32),
        .i64 => std.math.maxInt(i64),
        .u8 => std.math.maxInt(u8),
        .u16 => std.math.maxInt(u16),
        .u32 => std.math.maxInt(u32),
        .u64 => std.math.maxInt(u64),
        .f32, .f64, .bool, .void => null,
    };
}

fn fitsFloat(comptime Float: type, text: []const u8) bool {
    const value = std.fmt.parseFloat(Float, text) catch return false;
    return std.math.isFinite(value);
}

test "TypeChecker.check: sets the type of each returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one() u8: return 255\nfn two() f32: return 2.5\nfn three() bool: return true\nfn four() i64: return 1_i64\nfn main(): return");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);
    try type_checker.check();

    try std.testing.expectEqual(token.PrimitiveType.u8, module.functions[0].body[0].kind.@"return".?.primitive_type);
    try std.testing.expectEqual(token.PrimitiveType.f32, module.functions[1].body[0].kind.@"return".?.primitive_type);
    try std.testing.expectEqual(token.PrimitiveType.bool, module.functions[2].body[0].kind.@"return".?.primitive_type);
    try std.testing.expectEqual(token.PrimitiveType.i64, module.functions[3].body[0].kind.@"return".?.primitive_type);
}

test "checkFunction: rejects a return type on main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main() i32: return 1");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.MainHasReturnType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, type_checker.failure.?);
}

test "checkFunction: rejects a missing return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, type_checker.failure.?);
}

test "checkStatement: rejects a missing return value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.MissingReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, type_checker.failure.?);
}

test "checkStatement: rejects a value in a void function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): return 5");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, type_checker.failure.?);
}

test "checkExpression: rejects a boolean for an integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return true");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?);
}

test "checkExpression: rejects an integer literal for a float type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn ratio() f64: return 2");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?);
}

test "checkExpression: rejects a float literal for an integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 2.5");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?);
}

test "checkExpression: rejects a suffix of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 5u8");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?);
}

test "checkExpression: rejects a float suffix of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn ratio() f64: return 2.5f32");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?);
}

test "checkExpression: accepts the maximum of each integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init(
        \\fn one() i8: return 127
        \\fn two() i16: return 32767
        \\fn three() i32: return 2147483647
        \\fn four() i64: return 9223372036854775807
        \\fn five() u8: return 255
        \\fn six() u16: return 65535
        \\fn seven() u32: return 4294967295
        \\fn eight() u64: return 18446744073709551615
    );
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

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
        var lexer = @import("lexer.zig").Lexer.init(source);
        try lexer.lex(&arena);
        var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
        const module = try parser.parse(&arena);
        var type_checker = TypeChecker.init(module);

        try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    }
}

test "checkExpression: rejects a suffixed literal out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn small() u8: return 300u8");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?);
}

test "checkExpression: rejects an integer beyond 64 bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn big() u64: return 18446744073709551616");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, type_checker.failure.?);
}

test "checkExpression: rejects a float out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn huge() f32: return 1e39");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = TypeChecker.init(module);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?);
}
