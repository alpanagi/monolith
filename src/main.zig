const std = @import("std");
const javascript = @import("javascript.zig");
const token = @import("token.zig");

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len != 2 or !std.mem.endsWith(u8, arguments[1], ".mn")) {
        try stderr.writeAll("usage: monolith <file.mn>\n");
        try stderr.flush();
        return 1;
    }
    const path = arguments[1];

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |read_error| {
        try stderr.print("error: cannot read '{s}': {t}\n", .{ path, read_error });
        try stderr.flush();
        return 1;
    };

    var lexer = Lexer.init(source);
    lexer.lex(init.arena) catch |lex_error| switch (lex_error) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnexpectedCharacter => {
            try report(stderr, path, lexer.location, "unexpected character");
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

    const output_name = try std.fmt.allocPrint(allocator, "{s}.js", .{std.fs.path.stem(path)});
    const build_directory = try std.Io.Dir.cwd().createDirPathOpen(io, "build", .{});
    defer build_directory.close(io);
    const output = try build_directory.createFile(io, output_name, .{});
    defer output.close(io);

    var output_buffer: [4096]u8 = undefined;
    var output_writer = output.writer(io, &output_buffer);
    var generator = javascript.Generator.init(module);
    try generator.generate(&output_writer.interface);
    try output_writer.interface.flush();
    return 0;
}

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
        error.ExpectedBlock => "expected an indented block",
        error.UnexpectedIndentation => "unexpected indentation",
    };
}

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("javascript.zig");
}
