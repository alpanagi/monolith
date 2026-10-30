const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const CheckError = @import("type_checker.zig").CheckError;
const EvaluationError = @import("evaluator.zig").EvaluationError;
const Failure = core.Failure;
const LoadError = @import("loader.zig").LoadError;
const Loader = @import("loader.zig").Loader;
const NameError = @import("name_resolver.zig").NameError;
const NameResolver = @import("name_resolver.zig").NameResolver;
const TypeChecker = @import("type_checker.zig").TypeChecker;

pub const Analyzer = struct {
    arena: *std.heap.ArenaAllocator,
    loader: *Loader,
    name_resolver: NameResolver,
    type_checker: TypeChecker,
    failure: ?Failure = null,

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        loader: *Loader,
        type_registry: *types.Registry,
    ) Analyzer {
        const program: ast.Program = .{ .modules = loader.modules.items, .types = type_registry };
        return .{
            .arena = arena,
            .loader = loader,
            .name_resolver = NameResolver.init(arena, io, loader, type_registry),
            .type_checker = TypeChecker.init(arena, program),
        };
    }

    pub fn analyze(self: *Analyzer) AnalyzeError!ast.Program {
        self.name_resolver.type_checker = &self.type_checker;
        self.name_resolver.resolve() catch |resolve_error| {
            self.recordFailure(self.name_resolver.failure orelse self.type_checker.failure);
            return resolve_error;
        };
        const program: ast.Program = .{ .modules = self.loader.modules.items, .types = self.type_checker.program.types };
        self.type_checker.program = program;
        self.type_checker.failure = null;
        self.type_checker.check() catch |type_error| {
            self.recordFailure(self.type_checker.failure orelse self.name_resolver.failure);
            return type_error;
        };
        try self.appendInstances();
        return program;
    }

    pub fn collectCallTrace(self: *const Analyzer, allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error![]const CallNote {
        var notes: std.ArrayList(CallNote) = .empty;
        var function = failure.function;
        while (function) |current| {
            const call = self.type_checker.findCreatingCall(current) orelse break;
            function = call.caller;
            if (notes.items.len > 0) {
                const last = &notes.items[notes.items.len - 1];
                if (last.module == call.module and std.meta.eql(last.location, call.location)) {
                    last.count += 1;
                    continue;
                }
            }
            try notes.append(allocator, .{ .module = call.module, .location = call.location });
        }
        return notes.items;
    }

    fn recordFailure(self: *Analyzer, failure: ?Failure) void {
        var recorded = failure orelse return;
        if (recorded.function == null) recorded.function = self.type_checker.failed_function;
        self.failure = recorded;
    }

    fn appendInstances(self: *Analyzer) std.mem.Allocator.Error!void {
        for (self.loader.modules.items) |*module| {
            if (module.instances.items.len == 0) continue;
            const length = module.declarations.len;
            const declarations = try self.arena.allocator().alloc(ast.Declaration, length + module.instances.items.len);
            @memcpy(declarations[0..length], module.declarations);
            for (module.instances.items, declarations[length..]) |instance, *declaration| declaration.* = instance.*;
            module.declarations = declarations;
            module.instances = .empty;
        }
    }
};

pub const CallNote = struct {
    module: usize,
    location: token.Location,
    count: usize = 1,
};

pub const AnalyzeError = NameError || LoadError || CheckError || EvaluationError;

test "collectCallTrace: lists the calls that created nested instances in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn inner(comptime flag: bool)\n    if (flag) mn::comptime::error(\"boom\")\nfn outer(comptime flag: bool) = inner(flag)\nfn main() = outer(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ComptimeError, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, analyzer.failure.?.location.?);
    const trace = try analyzer.collectCallTrace(arena.allocator(), analyzer.failure.?);
    try std.testing.expectEqual(2, trace.len);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 33 }, trace[0].location);
    try std.testing.expectEqual(1, trace[0].count);
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 13 }, trace[1].location);
    try std.testing.expectEqual(1, trace[1].count);
}

test "collectCallTrace: folds a call repeated by recursive instances into one note with its count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn count(comptime n: usize)\n    if (n == 0) mn::comptime::error(\"done\")\n    else count(n - 1)\nfn main() = count(3)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ComptimeError, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 17 }, analyzer.failure.?.location.?);
    const trace = try analyzer.collectCallTrace(arena.allocator(), analyzer.failure.?);
    try std.testing.expectEqual(2, trace.len);
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, trace[0].location);
    try std.testing.expectEqual(3, trace[0].count);
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 13 }, trace[1].location);
    try std.testing.expectEqual(1, trace[1].count);
}

test "collectCallTrace: gives no notes for an error outside an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main() = mn::comptime::error(\"plain\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ComptimeError, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, analyzer.failure.?.location.?);
    try std.testing.expectEqual(0, (try analyzer.collectCallTrace(arena.allocator(), analyzer.failure.?)).len);
}
