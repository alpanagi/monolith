const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const header =
    \\#ifndef MONOLITH_H
    \\#define MONOLITH_H
    \\
    \\#include <stddef.h>
    \\#include <stdint.h>
    \\
    \\typedef struct { const char *bytes; size_t length; } string;
    \\
    \\#endif
    \\
;

pub const Generator = struct {
    module: ast.Module,
    depth: usize = 0,
    in_main: bool = false,
    failure: ?token.Location = null,

    pub fn init(module: ast.Module) Generator {
        return .{ .module = module };
    }

    pub fn generate(self: *Generator, writer: *std.Io.Writer) GenerateError!void {
        try self.checkNames();

        try writer.writeAll("#include \"monolith.h\"\n\n");
        try self.generateDeclarations(writer, .external_function);
        try self.generateDeclarations(writer, .function);

        var written: usize = 0;
        for (self.module.declarations) |declaration| {
            const function = switch (declaration) {
                .function => |function| function,
                .external_function => continue,
            };
            if (written > 0) try writer.writeByte('\n');
            try self.generateFunction(writer, function);
            written += 1;
        }
    }

    fn checkNames(self: *Generator) error{NameDefinedInTarget}!void {
        for (self.module.declarations) |declaration| {
            const function_declaration = switch (declaration) {
                .function => |function| function.declaration,
                .external_function => |external_function| external_function,
            };
            try self.checkName(function_declaration.name, function_declaration.location);
            for (function_declaration.parameters) |parameter| {
                try self.checkName(parameter.name, parameter.location);
            }
        }
    }

    fn checkName(
        self: *Generator,
        name: []const u8,
        location: token.Location,
    ) error{NameDefinedInTarget}!void {
        const reserved_words = std.StaticStringMap(void).initComptime(.{
            .{"INT16_C"},                   .{"INT16_MAX"},          .{"INT16_MIN"},
            .{"INT16_WIDTH"},               .{"INT32_C"},            .{"INT32_MAX"},
            .{"INT32_MIN"},                 .{"INT32_WIDTH"},        .{"INT64_C"},
            .{"INT64_MAX"},                 .{"INT64_MIN"},          .{"INT64_WIDTH"},
            .{"INT8_C"},                    .{"INT8_MAX"},           .{"INT8_MIN"},
            .{"INT8_WIDTH"},                .{"INTMAX_C"},           .{"INTMAX_MAX"},
            .{"INTMAX_MIN"},                .{"INTMAX_WIDTH"},       .{"INTPTR_MAX"},
            .{"INTPTR_MIN"},                .{"INTPTR_WIDTH"},       .{"INT_FAST16_MAX"},
            .{"INT_FAST16_MIN"},            .{"INT_FAST16_WIDTH"},   .{"INT_FAST32_MAX"},
            .{"INT_FAST32_MIN"},            .{"INT_FAST32_WIDTH"},   .{"INT_FAST64_MAX"},
            .{"INT_FAST64_MIN"},            .{"INT_FAST64_WIDTH"},   .{"INT_FAST8_MAX"},
            .{"INT_FAST8_MIN"},             .{"INT_FAST8_WIDTH"},    .{"INT_LEAST16_MAX"},
            .{"INT_LEAST16_MIN"},           .{"INT_LEAST16_WIDTH"},  .{"INT_LEAST32_MAX"},
            .{"INT_LEAST32_MIN"},           .{"INT_LEAST32_WIDTH"},  .{"INT_LEAST64_MAX"},
            .{"INT_LEAST64_MIN"},           .{"INT_LEAST64_WIDTH"},  .{"INT_LEAST8_MAX"},
            .{"INT_LEAST8_MIN"},            .{"INT_LEAST8_WIDTH"},   .{"MONOLITH_H"},
            .{"NULL"},                      .{"PTRDIFF_MAX"},        .{"PTRDIFF_MIN"},
            .{"PTRDIFF_WIDTH"},             .{"SIG_ATOMIC_MAX"},     .{"SIG_ATOMIC_MIN"},
            .{"SIG_ATOMIC_WIDTH"},          .{"SIZE_MAX"},           .{"SIZE_WIDTH"},
            .{"UINT16_C"},                  .{"UINT16_MAX"},         .{"UINT16_WIDTH"},
            .{"UINT32_C"},                  .{"UINT32_MAX"},         .{"UINT32_WIDTH"},
            .{"UINT64_C"},                  .{"UINT64_MAX"},         .{"UINT64_WIDTH"},
            .{"UINT8_C"},                   .{"UINT8_MAX"},          .{"UINT8_WIDTH"},
            .{"UINTMAX_C"},                 .{"UINTMAX_MAX"},        .{"UINTMAX_WIDTH"},
            .{"UINTPTR_MAX"},               .{"UINTPTR_WIDTH"},      .{"UINT_FAST16_MAX"},
            .{"UINT_FAST16_WIDTH"},         .{"UINT_FAST32_MAX"},    .{"UINT_FAST32_WIDTH"},
            .{"UINT_FAST64_MAX"},           .{"UINT_FAST64_WIDTH"},  .{"UINT_FAST8_MAX"},
            .{"UINT_FAST8_WIDTH"},          .{"UINT_LEAST16_MAX"},   .{"UINT_LEAST16_WIDTH"},
            .{"UINT_LEAST32_MAX"},          .{"UINT_LEAST32_WIDTH"}, .{"UINT_LEAST64_MAX"},
            .{"UINT_LEAST64_WIDTH"},        .{"UINT_LEAST8_MAX"},    .{"UINT_LEAST8_WIDTH"},
            .{"WCHAR_MAX"},                 .{"WCHAR_MIN"},          .{"WCHAR_WIDTH"},
            .{"WINT_MAX"},                  .{"WINT_MIN"},           .{"WINT_WIDTH"},
            .{"_Alignas"},                  .{"_Alignof"},           .{"_Atomic"},
            .{"_BitInt"},                   .{"_Bool"},              .{"_Complex"},
            .{"_Decimal128"},               .{"_Decimal32"},         .{"_Decimal64"},
            .{"_Generic"},                  .{"_Imaginary"},         .{"_Noreturn"},
            .{"_Static_assert"},            .{"_Thread_local"},      .{"__STDC_VERSION_STDDEF_H__"},
            .{"__STDC_VERSION_STDINT_H__"}, .{"alignas"},            .{"alignof"},
            .{"asm"},                       .{"auto"},               .{"bool"},
            .{"break"},                     .{"case"},               .{"char"},
            .{"const"},                     .{"constexpr"},          .{"continue"},
            .{"default"},                   .{"do"},                 .{"double"},
            .{"else"},                      .{"enum"},               .{"extern"},
            .{"false"},                     .{"float"},              .{"for"},
            .{"goto"},                      .{"if"},                 .{"inline"},
            .{"int"},                       .{"int16_t"},            .{"int32_t"},
            .{"int64_t"},                   .{"int8_t"},             .{"int_fast16_t"},
            .{"int_fast32_t"},              .{"int_fast64_t"},       .{"int_fast8_t"},
            .{"int_least16_t"},             .{"int_least32_t"},      .{"int_least64_t"},
            .{"int_least8_t"},              .{"intmax_t"},           .{"intptr_t"},
            .{"long"},                      .{"max_align_t"},        .{"nullptr"},
            .{"nullptr_t"},                 .{"offsetof"},           .{"ptrdiff_t"},
            .{"register"},                  .{"restrict"},           .{"return"},
            .{"short"},                     .{"signed"},             .{"size_t"},
            .{"sizeof"},                    .{"static"},             .{"static_assert"},
            .{"string"},                    .{"struct"},             .{"switch"},
            .{"thread_local"},              .{"true"},               .{"typedef"},
            .{"typeof"},                    .{"typeof_unqual"},      .{"uint16_t"},
            .{"uint32_t"},                  .{"uint64_t"},           .{"uint8_t"},
            .{"uint_fast16_t"},             .{"uint_fast32_t"},      .{"uint_fast64_t"},
            .{"uint_fast8_t"},              .{"uint_least16_t"},     .{"uint_least32_t"},
            .{"uint_least64_t"},            .{"uint_least8_t"},      .{"uintmax_t"},
            .{"uintptr_t"},                 .{"union"},              .{"unreachable"},
            .{"unsigned"},                  .{"void"},               .{"volatile"},
            .{"wchar_t"},                   .{"while"},
        });

        if (!reserved_words.has(name)) return;
        self.failure = location;
        return error.NameDefinedInTarget;
    }

    fn generateDeclarations(
        self: *Generator,
        writer: *std.Io.Writer,
        kind: std.meta.Tag(ast.Declaration),
    ) std.Io.Writer.Error!void {
        var declared = false;
        for (self.module.declarations) |declaration| {
            if (declaration != kind) continue;
            if (declaration == .function and isMain(declaration.function)) continue;
            try self.generateSignature(writer, declaration);
            try writer.writeAll(";\n");
            declared = true;
        }
        if (declared) try writer.writeByte('\n');
    }

    fn generateFunction(
        self: *Generator,
        writer: *std.Io.Writer,
        function: ast.Function,
    ) std.Io.Writer.Error!void {
        self.in_main = isMain(function);
        try self.generateSignature(writer, .{ .function = function });
        try writer.writeByte(' ');
        try self.generateBlock(writer, function.body);
        try writer.writeByte('\n');
    }

    fn generateSignature(
        self: *Generator,
        writer: *std.Io.Writer,
        declaration: ast.Declaration,
    ) std.Io.Writer.Error!void {
        switch (declaration) {
            .function => |function| {
                if (isMain(function)) return writer.writeAll("int main()");
                try writer.writeAll("static ");
                try self.generateType(writer, function.declaration.return_type.primitive_type);
                try writer.writeByte(' ');
                try writer.writeAll(function.declaration.name);
                try self.generateParameters(writer, function.declaration.parameters);
            },
            .external_function => |external_function| {
                try self.generateType(writer, external_function.return_type.primitive_type);
                try writer.writeByte(' ');
                try writer.writeAll(external_function.name);
                try self.generateParameters(writer, external_function.parameters);
            },
        }
    }

    fn generateParameters(
        self: *Generator,
        writer: *std.Io.Writer,
        parameters: []const ast.Parameter,
    ) std.Io.Writer.Error!void {
        try writer.writeByte('(');
        for (parameters, 0..) |parameter, index| {
            if (index > 0) try writer.writeAll(", ");
            try self.generateType(writer, parameter.parameter_type.primitive_type);
            try writer.writeByte(' ');
            try writer.writeAll(parameter.name);
        }
        try writer.writeByte(')');
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
            .string => "string",
            .void => "void",
        });
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
            .string => |text| {
                try writer.print("(string){{ \"{s}\", {d} }}", .{ text, countBytes(text) });
            },
            .identifier => |identifier| try writer.writeAll(identifier.name),
            .call => |call| {
                try writer.writeAll(call.name);
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

pub const GenerateError = std.Io.Writer.Error || error{NameDefinedInTarget};

fn isMain(function: ast.Function) bool {
    return std.mem.eql(u8, function.declaration.name, "main");
}

fn countBytes(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        index += if (text[index] == '\\') 2 else 1;
    }
    return count;
}

test "Generator.generate: separates functions with a blank line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): noop\nfn two():\n    noop\n");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic void two();\n\nint main() {}\n\nstatic void two() {}\n", output.written());
}

test "Generator.generate: includes stdint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn answer() i32: return 42");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic int32_t answer();\n\nstatic int32_t answer() {\n    return 42;\n}\n", output.written());
}

test "Generator.generate: declares every static function first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): _ = add(1, 2)\nfn add(left: i32, right: i32) i32: return left");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic int32_t add(int32_t left, int32_t right);\n\nint main() {\n    add(1, 2);\n}\n\nstatic int32_t add(int32_t left, int32_t right) {\n    return left;\n}\n", output.written());
}

test "checkNames: rejects function names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nfn int(): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkNames: rejects external function names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn int()");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkNames: rejects parameter names defined in the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(left: i32, char: i32): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkName: rejects the string type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn string(): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkName: rejects the header guard name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn MONOLITH_H(): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkName: rejects names from the included headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn add(size_t: i32): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, generator.failure.?);
    try std.testing.expectEqualStrings("", output.written());
}

test "checkName: matches whole names only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn int_(): noop\nfn int(): noop");
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

    try std.testing.expectError(error.NameDefinedInTarget, generator.generate(&output.writer));
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, generator.failure.?);
}

test "generateDeclarations: separates external functions from static functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop\nexternal fn log(value: i32)\nfn two(): noop");
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
        "#include \"monolith.h\"\n\nvoid log(int32_t value);\n\nstatic void one();\nstatic void two();\n\nstatic void one() {}\n\nstatic void two() {}\n",
        output.written(),
    );
}

test "generateFunction: generates main as the entry point" {
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nint main() {}\n", output.written());
}

test "generateFunction: generates other functions as static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn one(): noop");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic void one();\n\nstatic void one() {}\n", output.written());
}

test "generateSignature: declares external functions without static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("external fn print_(text: String)\nfn main(): print_(\"hi\")");
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
        "#include \"monolith.h\"\n\nvoid print_(string text);\n\nint main() {\n    print_((string){ \"hi\", 2 });\n}\n",
        output.written(),
    );
}

test "generateType: maps floating point types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn half() f32: return 0.5\nfn whole() f64: return 1.0");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic float half();\nstatic double whole();\n\nstatic float half() {\n    return 0.5;\n}\n\nstatic double whole() {\n    return 1.0;\n}\n", output.written());
}

test "generateBlock: writes statements on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn stop():\n    noop\n    return\n");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic void stop();\n\nstatic void stop() {\n    return;\n}\n", output.written());
}

test "generateStatement: returns zero from main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn main(): return");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nint main() {\n    return 0;\n}\n", output.written());
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic void log(int32_t value);\nstatic int32_t one();\n\nstatic void log(int32_t value) {}\n\nstatic int32_t one() {\n    return 1;\n}\n\nint main() {\n    log(one());\n    one();\n}\n", output.written());
}

test "generateExpression: converts separators and octal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mode() u16: return 0o7_5_5\nfn big() u32: return 1_000");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic uint16_t mode();\nstatic uint32_t big();\n\nstatic uint16_t mode() {\n    return 07'5'5u;\n}\n\nstatic uint32_t big() {\n    return 1'000u;\n}\n", output.written());
}

test "generateExpression: marks unsigned literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn mask() u8: return 0xff\nfn big() u64: return 18446744073709551615");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic uint8_t mask();\nstatic uint64_t big();\n\nstatic uint8_t mask() {\n    return 0xffu;\n}\n\nstatic uint64_t big() {\n    return 18446744073709551615u;\n}\n", output.written());
}

test "generateExpression: leaves signed literals unmarked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn big() i64: return 9223372036854775807");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic int64_t big();\n\nstatic int64_t big() {\n    return 9223372036854775807;\n}\n", output.written());
}

test "generateExpression: marks unsigned arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = @import("lexer.zig").Lexer.init("fn small(value: u8): noop\nfn main(): small(255)");
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic void small(uint8_t value);\n\nstatic void small(uint8_t value) {}\n\nint main() {\n    small(255u);\n}\n", output.written());
}

test "generateExpression: writes strings with their length in bytes" {
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

    try std.testing.expectEqualStrings("#include \"monolith.h\"\n\nstatic string greeting();\n\nstatic string greeting() {\n    return (string){ \"line\\n\\\"quoted\\\"\", 13 };\n}\n", output.written());
}
