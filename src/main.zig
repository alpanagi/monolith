const std = @import("std");
const c = @import("c.zig");
const javascript = @import("javascript.zig");
const token = @import("token.zig");

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const TypeChecker = @import("type_checker.zig").TypeChecker;
const TypeError = @import("type_checker.zig").TypeError;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 4 or !std.mem.eql(u8, arguments[1], "--target")) return printUsage(stderr);
    const target = std.meta.stringToEnum(Target, arguments[2]) orelse return printUsage(stderr);
    const path = arguments[3];
    if (!std.mem.endsWith(u8, path, ".mn")) return printUsage(stderr);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |read_error| {
        try stderr.print("error: cannot read '{s}': {t}\n", .{ path, read_error });
        try stderr.flush();
        return 1;
    };

    var lexer = Lexer.init(source);
    lexer.lex(init.arena) catch |lex_error| switch (lex_error) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnexpectedCharacter => {
            try report(stderr, path, lexer.failure.?, "unexpected character");
            return 1;
        },
    };

    var parser = Parser.init(lexer.tokens.items);
    const module = parser.parse(init.arena) catch |parse_error| switch (parse_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report(stderr, path, parser.failure.?.location, describeParseError(parse_error));
            return 1;
        },
    };

    var type_checker = TypeChecker.init(module);
    type_checker.check() catch |type_error| {
        try report(stderr, path, type_checker.failure.?, describeTypeError(type_error));
        return 1;
    };

    var output: std.Io.Writer.Allocating = .init(allocator);
    switch (target) {
        .javascript => {
            var generator = javascript.Generator.init(module);
            generator.generate(&output.writer) catch |generate_error| switch (generate_error) {
                error.WriteFailed => return error.WriteFailed,
                error.UnsupportedType => {
                    const message = "type is not supported on the javascript target";
                    try report(stderr, path, generator.failure.?, message);
                    return 1;
                },
            };
        },
        .c => {
            var generator = c.Generator.init(module);
            try generator.generate(&output.writer);
        },
    }

    const extension = switch (target) {
        .javascript => "js",
        .c => "c",
    };
    const output_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ std.fs.path.stem(path), extension });
    const directory_path = try std.fs.path.join(allocator, &.{ "build", @tagName(target) });
    const directory = try std.Io.Dir.cwd().createDirPathOpen(io, directory_path, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = output_name, .data = output.written() });
    return 0;
}

fn printUsage(stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    try stderr.writeAll("usage: monolith --target <javascript|c> <file.mn>\n");
    try stderr.flush();
    return 1;
}

const Target = enum {
    javascript,
    c,
};

fn report(
    stderr: *std.Io.Writer,
    path: []const u8,
    location: token.Location,
    message: []const u8,
) std.Io.Writer.Error!void {
    try stderr.print("{s}:{d}:{d}: error: {s}\n", .{ path, location.row, location.column, message });
    try stderr.flush();
}

fn describeParseError(parse_error: ParseError) []const u8 {
    return switch (parse_error) {
        error.OutOfMemory => "out of memory",
        error.UnexpectedToken => "unexpected token",
        error.ExpectedIdentifier => "expected an identifier",
        error.ExpectedLeftParenthesis => "expected '('",
        error.ExpectedRightParenthesis => "expected ')'",
        error.ExpectedColon => "expected ':'",
        error.ExpectedStatement => "expected a statement",
        error.ExpectedExpression => "expected an expression",
        error.ExpectedBlock => "expected an indented block",
        error.UnexpectedIndentation => "unexpected indentation",
    };
}

fn describeTypeError(type_error: TypeError) []const u8 {
    return switch (type_error) {
        error.TypeMismatch => "value does not match the expected type",
        error.LiteralOutOfRange => "literal out of range for its type",
        error.MissingReturnValue => "missing return value",
        error.UnexpectedReturnValue => "void function cannot return a value",
        error.MissingReturn => "function must end with a return",
        error.MainHasReturnType => "main cannot have a return type",
    };
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("type_checker.zig");
    _ = @import("javascript.zig");
    _ = @import("c.zig");
}
