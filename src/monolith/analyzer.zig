const std = @import("std");
const core = @import("core");
const ast = core.ast;
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
            self.failure = self.name_resolver.failure orelse self.type_checker.failure;
            return resolve_error;
        };
        const program: ast.Program = .{ .modules = self.loader.modules.items, .types = self.type_checker.program.types };
        self.type_checker.program = program;
        self.type_checker.failure = null;
        self.type_checker.check() catch |type_error| {
            self.failure = self.type_checker.failure orelse self.name_resolver.failure;
            return type_error;
        };
        try self.appendInstances();
        return program;
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

pub const AnalyzeError = NameError || LoadError || CheckError || EvaluationError;
