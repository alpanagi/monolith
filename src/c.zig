const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const Generator = struct {
    module: ast.Module,
    depth: usize = 0,
    in_main: bool = false,

    pub fn init(module: ast.Module) Generator {
        return .{ .module = module };
    }

    pub fn generate(self: *Generator, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("#include <stdint.h>\n\n");

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
        self.in_main = std.mem.eql(u8, function.name, "main");
        if (self.in_main) {
            try writer.writeAll("int ");
        } else {
            try writer.writeAll("static ");
            try self.generateType(writer, function.return_type.primitive_type);
            try writer.writeByte(' ');
        }
        try self.generateIdentifier(writer, function.name);
        try writer.writeAll("() ");
        try self.generateBlock(writer, function.body);
        try writer.writeByte('\n');
    }

    fn generateType(
        _: *Generator,
        writer: *std.Io.Writer,
        primitive_type: token.PrimitiveType,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(switch (primitive_type) {
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .f32 => "float",
            .f64 => "double",
            .bool => "bool",
            .void => "void",
        });
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
                } else if (self.in_main) {
                    try writer.writeAll(" 0");
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
            .integer, .float => |literal| {
                var text = literal.text;
                if (std.mem.startsWith(u8, text, "0o")) {
                    try writer.writeByte('0');
                    text = text[2..];
                }
                for (text) |byte| try writer.writeByte(if (byte == '_') '\'' else byte);
                switch (expression.primitive_type.?) {
                    .u8, .u16, .u32, .u64 => try writer.writeByte('u'),
                    else => {},
                }
            },
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        }
    }
};

test "Generator.generate: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\nfn two():\n    noop\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nint main() {}\n\nstatic void two() {}\n", output.written());
}

test "Generator.generate: includes stdint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 42");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic int32_t answer() {\n    return 42;\n}\n", output.written());
}

test "generateFunction: generates main as the entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nint main() {}\n", output.written());
}

test "generateFunction: generates other functions as static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic void one() {}\n", output.written());
}

test "generateType: maps floating point types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn half() f32: return 0.5\nfn whole() f64: return 1.0");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic float half() {\n    return 0.5;\n}\n\nstatic double whole() {\n    return 1.0;\n}\n", output.written());
}

test "generateIdentifier: appends an underscore to reserved words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn int(): noop");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic void int_() {}\n", output.written());
}

test "generateBlock: writes statements on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn stop():\n    noop\n    return\n");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic void stop() {\n    return;\n}\n", output.written());
}

test "generateStatement: returns zero from main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): return");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nint main() {\n    return 0;\n}\n", output.written());
}

test "generateExpression: converts separators and octal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mode() u16: return 0o7_5_5\nfn big() u32: return 1_000");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic uint16_t mode() {\n    return 07'5'5u;\n}\n\nstatic uint32_t big() {\n    return 1'000u;\n}\n", output.written());
}

test "generateExpression: marks unsigned literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mask() u8: return 0xff\nfn big() u64: return 18446744073709551615");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic uint8_t mask() {\n    return 0xffu;\n}\n\nstatic uint64_t big() {\n    return 18446744073709551615u;\n}\n", output.written());
}

test "generateExpression: leaves signed literals unmarked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn big() i64: return 9223372036854775807");
    try lexer.lex(&arena);
    var parser = @import("parser.zig").Parser.init(lexer.tokens.items);
    const module = try parser.parse(&arena);
    var type_checker = @import("type_checker.zig").TypeChecker.init(module);
    try type_checker.check();
    var generator = Generator.init(module);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try generator.generate(&output.writer);

    try std.testing.expectEqualStrings("#include <stdint.h>\n\nstatic int64_t big() {\n    return 9223372036854775807;\n}\n", output.written());
}
