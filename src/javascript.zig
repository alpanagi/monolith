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
    }

    fn generateFunction(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.Function,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("function ");
        try self.generateIdentifier(writer, function.name);
        try writer.writeAll("() ");
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
        if (reserved_words.has(name)) try writer.writeByte('_');
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
        }
    }

    fn generateIndentation(self: *Generator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.depth) |_| try writer.writeAll("    ");
    }

    fn generateExpression(
        _: *Generator,
        writer: *std.Io.Writer,
        expression: ast.Expression,
    ) std.Io.Writer.Error!void {
        switch (expression.kind) {
            .integer, .float => |literal| try writer.writeAll(literal.text),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        }
    }
};

test "Generator.generate: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function one() {}\n\nfunction two() {}\n", output.written());
}

test "generateFunction: generates an empty function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function main() {}\n", output.written());
}

test "generateIdentifier: appends an underscore to reserved words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn delete(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function delete_() {}\n", output.written());
}

test "generateBlock: writes statements on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32:\n    noop\n    return 42\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
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
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function stop() {\n    return;\n}\n", output.written());
}

test "generateExpression: keeps the base and drops the suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mask() u32: return 0xff_FF_u32");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function mask() {\n    return 0xff_FF;\n}\n", output.written());
}

test "generateExpression: writes booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn ready() bool: return false");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("function ready() {\n    return false;\n}\n", output.written());
}
