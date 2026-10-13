const std = @import("std");
const ast = @import("ast.zig");

pub const Generator = struct {
    module: ast.Module,

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
        try writer.writeAll(if (std.mem.eql(u8, function.name, "main")) "int " else "static void ");
        try self.generateIdentifier(writer, function.name);
        try writer.writeAll("() {");
        try self.generateBlock(writer, function.body);
        try writer.writeAll("}\n");
    }

    fn generateIdentifier(
        _: *Generator,
        writer: *std.Io.Writer,
        name: []const u8,
    ) std.Io.Writer.Error!void {
        const reserved_words = std.StaticStringMap(void).initComptime(.{
            .{"_Alignas"},       .{"_Alignof"},      .{"_Atomic"},       .{"_BitInt"},
            .{"_Bool"},          .{"_Complex"},      .{"_Decimal128"},   .{"_Decimal32"},
            .{"_Decimal64"},     .{"_Generic"},      .{"_Imaginary"},    .{"_Noreturn"},
            .{"_Static_assert"}, .{"_Thread_local"}, .{"alignas"},       .{"alignof"},
            .{"asm"},            .{"auto"},          .{"bool"},          .{"break"},
            .{"case"},           .{"char"},          .{"const"},         .{"constexpr"},
            .{"continue"},       .{"default"},       .{"do"},            .{"double"},
            .{"else"},           .{"enum"},          .{"extern"},        .{"false"},
            .{"float"},          .{"for"},           .{"goto"},          .{"if"},
            .{"inline"},         .{"int"},           .{"long"},          .{"nullptr"},
            .{"register"},       .{"restrict"},      .{"return"},        .{"short"},
            .{"signed"},         .{"sizeof"},        .{"static"},        .{"static_assert"},
            .{"struct"},         .{"switch"},        .{"thread_local"},  .{"true"},
            .{"typedef"},        .{"typeof"},        .{"typeof_unqual"}, .{"union"},
            .{"unsigned"},       .{"void"},          .{"volatile"},      .{"while"},
        });

        try writer.writeAll(name);
        if (reserved_words.has(name)) try writer.writeByte('_');
    }

    fn generateBlock(
        self: *Generator,
        writer: *std.Io.Writer,
        block: []const ast.Statement,
    ) std.Io.Writer.Error!void {
        for (block) |statement| try self.generateStatement(writer, statement);
    }

    fn generateStatement(
        _: *Generator,
        _: *std.Io.Writer,
        statement: ast.Statement,
    ) std.Io.Writer.Error!void {
        switch (statement.kind) {
            .noop => {},
        }
    }
};

test "Generator.generate: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("int main() {}\n\nstatic void two() {}\n", output.written());
}

test "generateFunction: generates main as the entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("int main() {}\n", output.written());
}

test "generateFunction: generates other functions as static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("static void one() {}\n", output.written());
}

test "generateIdentifier: appends an underscore to reserved words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn int(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    var generator = Generator.init(try parser.parse(&arena));
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("static void int_() {}\n", output.written());
}
