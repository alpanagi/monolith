const std = @import("std");
const ast = @import("ast.zig");

pub const Generator = struct {
    module: ast.Module,
    depth: usize = 0,

    pub fn init(module: ast.Module) Generator {
        return .{ .module = module };
    }

    pub fn generate(self: *Generator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.module.functions, 0..) |function, index| {
            if (index > 0) try writer.writeByte('\n');
            try self.generateFunction(writer, function);
        }

        const has_main = for (self.module.functions) |function| {
            if (std.mem.eql(u8, function.name, "main")) break true;
        } else false;
        if (has_main) try writer.writeAll("\nmain();\n");
    }

    fn generateFunction(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.Function,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("function ");
        try self.generateIdentifier(writer, function.name);
        try writer.writeByte('(');
        for (function.parameters, 0..) |parameter, index| {
            if (index > 0) try writer.writeAll(", ");
            try self.generateIdentifier(writer, parameter.name);
        }
        try writer.writeAll(") ");
        try self.generateBlock(writer, function.body);
        try writer.writeByte('\n');
    }

    fn generateIdentifier(
        _: *Generator,
        writer: *std.Io.Writer,
        name: []const u8,
    ) std.Io.Writer.Error!void {
        const reserved_words = std.StaticStringMap(void).initComptime(.{
            .{"arguments"},  .{"await"},     .{"break"},      .{"case"},     .{"catch"},
            .{"class"},      .{"const"},     .{"continue"},   .{"debugger"}, .{"default"},
            .{"delete"},     .{"do"},        .{"else"},       .{"enum"},     .{"eval"},
            .{"export"},     .{"extends"},   .{"false"},      .{"finally"},  .{"for"},
            .{"function"},   .{"if"},        .{"implements"}, .{"import"},   .{"in"},
            .{"instanceof"}, .{"interface"}, .{"let"},        .{"new"},      .{"null"},
            .{"package"},    .{"private"},   .{"protected"},  .{"public"},   .{"return"},
            .{"static"},     .{"super"},     .{"switch"},     .{"this"},     .{"throw"},
            .{"true"},       .{"try"},       .{"typeof"},     .{"var"},      .{"void"},
            .{"while"},      .{"with"},      .{"yield"},
        });

        try writer.writeAll(name);
        if (reserved_words.has(name) or std.mem.endsWith(u8, name, "_")) try writer.writeByte('_');
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
                }
                try writer.writeAll(";\n");
            },
            .discard, .expression => |expression| {
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
            .integer, .float => |literal| {
                try writer.writeAll(literal.text);
                switch (expression.primitive_type.?) {
                    .i64, .u64 => try writer.writeByte('n'),
                    else => {},
                }
            },
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
            .string => |text| try writer.print("\"{s}\"", .{text}),
            .identifier => |identifier| try self.generateIdentifier(writer, identifier.name),
            .call => |call| {
                try self.generateIdentifier(writer, call.name);
                try writer.writeByte('(');
                for (call.arguments, 0..) |argument, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try self.generateExpression(writer, argument);
                }
                try writer.writeByte(')');
            },
        }
    }
};

test "Generator.generate: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function one() {}\n\nfunction two() {}\n", output.written());
}

test "Generator.generate: calls main after all functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): helper()\nfn helper(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings(
        "function main() {\n    helper();\n}\n\nfunction helper() {}\n\nmain();\n",
        output.written(),
    );
}

test "generateFunction: generates an empty function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function main() {}\n\nmain();\n", output.written());
}

test "generateFunction: writes parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, right: i32) i32: return left");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function add(left, right) {\n    return left;\n}\n", output.written());
}

test "generateIdentifier: appends an underscore to reserved words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn delete(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function delete_() {}\n", output.written());
}

test "generateIdentifier: keeps escaped names apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn delete(): noop\nfn delete_(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function delete_() {}\n\nfunction delete__() {}\n", output.written());
}

test "generateBlock: writes statements on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32:\n    noop\n    return 42\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function answer() {\n    return 42;\n}\n", output.written());
}

test "generateStatement: writes return without a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn stop(): return");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function stop() {\n    return;\n}\n", output.written());
}

test "generateStatement: writes calls and discards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn log(value: i32): noop\nfn one() i32: return 1\nfn main():\n    log(one())\n    _ = one()\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function log(value) {}\n\nfunction one() {\n    return 1;\n}\n\nfunction main() {\n    log(one());\n    one();\n}\n\nmain();\n", output.written());
}

test "generateExpression: keeps the base and drops the suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mask() u32: return 0xff_FF_u32");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function mask() {\n    return 0xff_FF;\n}\n", output.written());
}

test "generateExpression: writes booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn ready() Bool: return false");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function ready() {\n    return false;\n}\n", output.written());
}

test "generateExpression: writes 64-bit integers as BigInt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn big() i64: return 1\nfn huge() u64: return 0xffff_ffff_ffff_ffff");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function big() {\n    return 1n;\n}\n\nfunction huge() {\n    return 0xffff_ffff_ffff_ffffn;\n}\n", output.written());
}

test "generateExpression: writes 64-bit arguments as BigInt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn take(value: i64): noop\nfn main(): take(5)");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function take(value) {}\n\nfunction main() {\n    take(5n);\n}\n\nmain();\n", output.written());
}

test "generateExpression: writes strings as written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn greeting() String: return \"line\\n\\\"quoted\\\"\"");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var name_resolver = @import("name_resolver.zig").NameResolver.init(module);
    try name_resolver.resolve();
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function greeting() {\n    return \"line\\n\\\"quoted\\\"\";\n}\n", output.written());
}
