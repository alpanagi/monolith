const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const AnalyzeError = @import("analyzer.zig").AnalyzeError;
const Bound = @import("type_checker.zig").Bound;
const Failure = core.Failure;
const Loader = @import("loader.zig").Loader;
const LoadError = @import("loader.zig").LoadError;
const Namespace = @import("loader.zig").Namespace;
const Resolver = @import("type_checker.zig").Resolver;
const TypeChecker = @import("type_checker.zig").TypeChecker;
const Value = core.Value;

pub const NameResolver = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    loader: *Loader,
    types: *types.Registry,
    module_index: usize = 0,
    constant_depth: usize = 0,
    self_type: ?types.Type = null,
    trait: ?ast.Resolution.Trait = null,
    bindings: []const ast.Binding = &.{},
    owner_name: []const u8 = "",
    structs: std.ArrayList(StructCount) = .empty,
    type_checker: ?*TypeChecker = null,
    pending: std.ArrayList(PendingMethod) = .empty,
    failure: ?Failure = null,

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        loader: *Loader,
        type_registry: *types.Registry,
    ) NameResolver {
        return .{ .arena = arena, .io = io, .loader = loader, .types = type_registry };
    }

    pub fn resolve(self: *NameResolver) ResolveError!void {
        if (self.type_checker) |type_checker| type_checker.resolver = self.buildResolver();
        try self.loadImportedModules();
        try self.addDefaults();
        var index: usize = 0;
        while (index < self.loader.modules.items.len) : (index += 1) {
            self.module_index = index;
            try self.resolveModule();
        }
        for (self.pending.items) |pending| try self.resolvePendingMethod(pending);
        try self.expectSingleImplementations();
    }

    fn resolveModule(self: *NameResolver) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        for (module.declarations, 0..) |declaration, index| {
            if (isMethod(declaration)) {
                if (declaration.kind.function_definition.signature.trait == null) {
                    try self.resolveFunction(self.module_index, index);
                }
                continue;
            }
            switch (declaration.kind) {
                .implementation => {
                    try self.resolveImplementation(index);
                    continue;
                },
                .function_definition,
                .function_declaration,
                .constant_declaration,
                .struct_definition,
                .trait_definition,
                .import,
                => {},
            }
            const name = extractName(declaration);
            const location = declaration.location;
            if (findDeclaration(module, name) != index) {
                return self.fail(location, switch (declaration.kind) {
                    .function_definition, .function_declaration => error.DuplicateFunction,
                    .constant_declaration => error.DuplicateConstant,
                    .struct_definition => error.DuplicateStruct,
                    .trait_definition => error.DuplicateTrait,
                    .import => error.DuplicateImport,
                    .implementation => unreachable,
                });
            }
            if (isReservedName(module.path, name)) return self.fail(location, error.ReservedName);
            if (declaration.kind != .import and try self.hasMember(module.path, name)) {
                return self.fail(location, error.NamedLikeModule);
            }
            switch (declaration.kind) {
                .function_definition => try self.resolveFunction(self.module_index, index),
                .function_declaration => try self.resolveExternalSignature(self.module_index, index),
                .trait_definition => {
                    const module_index = self.module_index;
                    try self.resolveTrait(.{ .module = module_index, .declaration = index });
                },
                .import => _ = try self.resolveImport(self.module_index, index),
                .constant_declaration => |constant| {
                    if (constant.type == null and ast.isAlias(constant)) continue;
                    _ = try self.resolveConstant(self.module_index, index);
                },
                .struct_definition, .implementation => {},
            }
        }
    }

    fn resolveTrait(self: *NameResolver, trait: ast.Resolution.Trait) ResolveError!void {
        const module = self.loader.modules.items[trait.module];
        const declaration = module.declarations[trait.declaration];
        const definition = &module.declarations[trait.declaration].kind.trait_definition;
        if (definition.resolved) return;
        definition.resolved = true;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        self.module_index = trait.module;
        self.self_type = .implementer;
        self.trait = trait;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        const functions = definition.functions;
        for (functions, 0..) |*signature, function_index| {
            if (findSignature(functions[0..function_index], signature.name) != null) {
                return self.fail(declaration.location, error.DuplicateFunction);
            }
            if (ast.isGeneric(signature.*)) return self.fail(declaration.location, error.GenericTraitFunction);
            try self.resolveFunctionTypes(signature);
        }
        for (functions, definition.defaults) |signature, default| {
            const written = default orelse continue;
            try self.resolveNamesInFunction(.{ .signature = signature, .body = written.body });
        }
    }

    fn loadImportedModules(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            self.module_index = module_index;
            const module = self.loader.modules.items[module_index];
            for (module.declarations) |declaration| {
                if (declaration.kind != .import) continue;
                const path = declaration.kind.import.path;
                var namespace = (try self.loadRoot(declaration.location, path[0])) orelse continue;
                for (path[1..]) |name| namespace = (try self.loadMember(namespace, name)) orelse break;
            }
        }
    }

    fn addDefaults(self: *NameResolver) ResolveError!void {
        const allocator = self.arena.allocator();
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            self.module_index = module_index;
            const original = self.loader.modules.items[module_index].declarations;
            for (original) |*declaration| {
                if (declaration.kind != .implementation) continue;
                const implementation = &declaration.kind.implementation;
                implementation.resolved = try self.expectTrait(&implementation.trait);
            }
            var declarations: std.ArrayList(ast.Declaration) = .empty;
            try declarations.appendSlice(allocator, original);
            for (original, 0..) |declaration, index| {
                if (declaration.kind != .implementation) continue;
                const implementation = declaration.kind.implementation;
                const trait = implementation.resolved.?;
                const required = self.loader.modules.items[trait.module].declarations[trait.declaration];
                const definition = required.kind.trait_definition;
                const first = index + 1;
                const written = original[first .. first + implementation.functions];
                var defaults: std.ArrayList(usize) = .empty;
                for (definition.functions, definition.defaults) |signature, default| {
                    const template = (default orelse continue).template;
                    if (findDefinition(written, signature.name) != null) continue;
                    var function = try ast.cloneFunctionDefinition(allocator, template);
                    function.signature.receiver = implementation.type;
                    function.signature.trait = implementation.trait;
                    function.default_of = trait;
                    try defaults.append(allocator, declarations.items.len);
                    const kind: ast.DeclarationKind = .{ .function_definition = function };
                    try declarations.append(allocator, .{ .kind = kind, .location = declaration.location });
                }
                declarations.items[index].kind.implementation.defaults = defaults.items;
            }
            self.loader.modules.items[module_index].declarations = declarations.items;
        }
    }

    fn resolveImplementationType(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        const implementation = &self.loader.modules.items[module_index].declarations[index].kind.implementation;
        if (implementation.progress != .pending) return;
        implementation.progress = .running;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = null;
        self.bindings = &.{};
        try self.resolveNamesInExpression(.{}, &implementation.type);
        _ = try self.expectType(&implementation.type);
        implementation.progress = .done;
    }

    fn resolveAllImplementationTypes(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            for (self.loader.modules.items[module_index].declarations, 0..) |declaration, index| {
                if (declaration.kind != .implementation) continue;
                try self.resolveImplementationType(module_index, index);
            }
        }
    }

    fn resolveImplementation(self: *NameResolver, index: usize) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const declaration = module.declarations[index];
        const implementation = &module.declarations[index].kind.implementation;
        const trait = try self.expectTrait(&implementation.trait);
        implementation.resolved = trait;
        try self.resolveTrait(trait);
        try self.resolveImplementationType(self.module_index, index);
        const implemented = ast.extractType(implementation.type);
        const required = self.loader.modules.items[trait.module].declarations[trait.declaration];
        const signatures = required.kind.trait_definition.functions;
        const first = index + 1;
        const functions = module.declarations[first .. first + implementation.functions];
        for (functions, first..) |function, function_index| {
            const signature = function.kind.function_definition.signature;
            for (functions[0 .. function_index - first]) |earlier| {
                const earlier_name = earlier.kind.function_definition.signature.name;
                if (std.mem.eql(u8, earlier_name, signature.name)) {
                    return self.fail(function.location, error.DuplicateFunction);
                }
            }
            const expected = findSignature(signatures, signature.name) orelse {
                return self.fail(function.location, error.NotInTrait);
            };
            try self.resolveFunction(self.module_index, function_index);
            const resolved = module.declarations[function_index].kind.function_definition.signature;
            if (ast.isGeneric(resolved) or !matchesSignature(resolved, expected, implemented)) {
                return self.fail(function.location, error.MismatchedTraitFunction);
            }
        }
        for (signatures, required.kind.trait_definition.defaults) |expected, default| {
            if (default != null or findDefinition(functions, expected.name) != null) continue;
            return self.fail(declaration.location, error.MissingTraitFunction);
        }
        for (implementation.defaults) |default_index| try self.resolveFunction(self.module_index, default_index);
    }

    fn expectTrait(
        self: *NameResolver,
        expression: *ast.Expression,
    ) ResolveError!ast.Resolution.Trait {
        const location = expression.location;
        const target = switch (expression.kind) {
            .identifier => |identifier| try self.resolveName(location, identifier.name),
            .path_expression => |path_expression| target: {
                const path = path_expression.path;
                break :target try self.resolvePath(.{}, location, path);
            },
            else => return self.fail(location, error.NotATrait),
        };
        if (target != .trait) return self.fail(location, error.NotATrait);
        return target.trait;
    }

    fn expectSingleImplementations(self: *NameResolver) NameError!void {
        for (self.loader.modules.items, 0..) |module, module_index| {
            for (module.declarations, 0..) |declaration, index| {
                if (declaration.kind != .implementation) continue;
                const implementation = declaration.kind.implementation;
                if (self.findEarlierImplementation(module_index, index, implementation)) {
                    self.module_index = module_index;
                    return self.fail(declaration.location, error.DuplicateImplementation);
                }
            }
        }
    }

    fn findEarlierImplementation(
        self: *NameResolver,
        module_index: usize,
        index: usize,
        implementation: ast.Implementation,
    ) bool {
        const implemented = ast.extractType(implementation.type);
        for (self.loader.modules.items[0 .. module_index + 1], 0..) |module, earlier_module| {
            const end = if (earlier_module == module_index) index else module.declarations.len;
            for (module.declarations[0..end]) |declaration| {
                if (declaration.kind != .implementation) continue;
                const earlier = declaration.kind.implementation;
                if (!std.meta.eql(earlier.resolved, implementation.resolved)) continue;
                if (std.meta.eql(ast.extractType(earlier.type), implemented)) return true;
            }
        }
        return false;
    }

    fn resolveFunction(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        try self.resolveFunctionSignature(module_index, index);
        try self.resolveFunctionBody(module_index, index);
    }

    fn resolveFunctionSignature(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        const module = self.loader.modules.items[module_index];
        const declaration = ast.findDeclaration(module, index);
        const definition = &declaration.kind.function_definition;
        const signature = &definition.signature;
        switch (signature.progress) {
            .done => return,
            .running => return self.failIn(module_index, declaration.location, error.DependencyLoop),
            .pending => {},
        }
        signature.progress = .running;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = null;
        self.bindings = definition.bindings;
        const caller_owner_name = self.owner_name;
        defer self.owner_name = caller_owner_name;
        self.owner_name = self.findOwnerName(definition.*);
        if (definition.default_of) |trait| {
            const receiver = &signature.receiver.?;
            try self.resolveNamesInExpression(.{}, receiver);
            self.self_type = try self.expectType(receiver);
            self.module_index = trait.module;
            self.trait = trait;
        } else if (signature.receiver) |*receiver| {
            if (isReservedName(module.path, signature.name)) {
                return self.fail(declaration.location, error.ReservedName);
            }
            try self.resolveNamesInExpression(.{}, receiver);
            const receiver_type = try self.expectType(receiver);
            self.self_type = receiver_type;
            const unique = signature.trait == null and index < module.declarations.len;
            if (unique) try self.expectUniqueMethod(module_index, index, receiver_type);
        }
        if (!ast.isGeneric(signature.*)) try self.resolveFunctionTypes(signature);
        signature.progress = .done;
    }

    fn findOwnerName(self: *const NameResolver, definition: ast.FunctionDefinition) []const u8 {
        const template = definition.template orelse return definition.signature.name;
        const module = self.loader.modules.items[template.module];
        return ast.findDeclaration(module, template.declaration).kind.function_definition.signature.name;
    }

    fn expectUniqueMethod(
        self: *NameResolver,
        module_index: usize,
        index: usize,
        receiver_type: types.Type,
    ) NameError!void {
        const module = self.loader.modules.items[module_index];
        const declaration = module.declarations[index];
        const signature = declaration.kind.function_definition.signature;
        for (module.declarations, 0..) |other, other_index| {
            if (other_index == index or !isMethod(other)) continue;
            const other_signature = other.kind.function_definition.signature;
            if (other_signature.trait != null or other_signature.progress != .done) continue;
            if (!std.mem.eql(u8, other_signature.name, signature.name)) continue;
            const other_type = ast.extractType(other_signature.receiver.?);
            if (!std.meta.eql(other_type, receiver_type)) continue;
            const later = module.declarations[@max(index, other_index)];
            return self.fail(later.location, error.DuplicateFunction);
        }
        for (receiver_type.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, signature.name)) {
                return self.fail(declaration.location, error.MethodIsField);
            }
        }
    }

    fn resolveFunctionBody(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        try self.resolveFunctionSignature(module_index, index);
        const module = self.loader.modules.items[module_index];
        const declaration = ast.findDeclaration(module, index);
        const definition = &declaration.kind.function_definition;
        switch (definition.body_progress) {
            .done => return,
            .running => return self.failIn(module_index, declaration.location, error.DependencyLoop),
            .pending => {},
        }
        if (ast.isGeneric(definition.signature)) {
            definition.body_progress = .done;
            return;
        }
        definition.body_progress = .running;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = definition.default_of;
        self.bindings = definition.bindings;
        const caller_owner_name = self.owner_name;
        defer self.owner_name = caller_owner_name;
        self.owner_name = self.findOwnerName(definition.*);
        if (definition.signature.receiver) |receiver| self.self_type = ast.extractType(receiver);
        if (definition.default_of) |trait| self.module_index = trait.module;
        try self.resolveNamesInFunction(definition.*);
        definition.body_progress = .done;
    }

    fn resolveExternalSignature(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        const signature = &self.loader.modules.items[module_index].declarations[index].kind.function_declaration;
        if (signature.progress != .pending) return;
        signature.progress = .running;
        const caller_module_index = self.module_index;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.bindings = caller_bindings;
        try self.resolveFunctionTypes(signature);
        signature.progress = .done;
    }

    fn resolveAllSignatures(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            const module = self.loader.modules.items[module_index];
            for (module.declarations, 0..) |declaration, index| {
                switch (declaration.kind) {
                    .function_definition => |function| {
                        if (function.signature.progress == .pending) {
                            try self.resolveFunctionSignature(module_index, index);
                        }
                    },
                    .function_declaration => try self.resolveExternalSignature(module_index, index),
                    .constant_declaration, .struct_definition, .trait_definition, .implementation, .import => {},
                }
            }
        }
    }

    fn resolveForChecker(context: *anyopaque, function: ast.Resolution.Function) AnalyzeError!void {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const module = self.loader.modules.items[function.module];
        const definition = ast.findDeclaration(module, function.declaration).kind.function_definition;
        if (definition.body_progress == .done) return;
        const caller_module_index = self.module_index;
        defer self.module_index = caller_module_index;
        const pending_start = self.pending.items.len;
        try self.resolveFunctionBody(function.module, function.declaration);
        try self.resolveAllSignatures();
        for (self.pending.items[pending_start..]) |pending| try self.resolvePendingMethod(pending);
        self.pending.shrinkRetainingCapacity(pending_start);
    }

    fn resolveParameterTypeForChecker(
        context: *anyopaque,
        template: ast.Resolution.Function,
        position: usize,
        arguments: []const Bound,
    ) AnalyzeError!types.Type {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        const module = self.loader.modules.items[template.module];
        const signature = ast.findDeclaration(module, template.declaration).kind.function_definition.signature;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        var argument_index: usize = 0;
        for (signature.parameters[0..position]) |parameter| {
            if (parameter.kind == .run_time) continue;
            const argument = arguments[argument_index];
            argument_index += 1;
            if (parameter.kind != .type) continue;
            try bindings.append(allocator, .{ .name = parameter.name, .target = .{ .type = argument.value.type } });
        }
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        self.module_index = template.module;
        self.self_type = if (signature.receiver) |receiver| ast.extractType(receiver) else null;
        self.trait = null;
        self.bindings = bindings.items;
        var written = try ast.cloneExpression(allocator, signature.parameters[position].type);
        try self.resolveNamesInExpression(.{}, &written);
        return self.expectRuntimeType(&written);
    }

    fn instantiateForChecker(
        context: *anyopaque,
        template: ast.Resolution.Function,
        arguments: []const Bound,
        number: usize,
    ) AnalyzeError!ast.Resolution.Function {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        const module = &self.loader.modules.items[template.module];
        const declaration = ast.findDeclaration(module.*, template.declaration).*;
        var instance = try ast.cloneFunctionDefinition(allocator, declaration.kind.function_definition);
        const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ instance.signature.name, number });
        var parameters: std.ArrayList(ast.TypedName) = .empty;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        var argument_index: usize = 0;
        for (instance.signature.parameters) |parameter| {
            if (parameter.kind == .run_time) {
                try parameters.append(allocator, parameter);
                continue;
            }
            const argument = arguments[argument_index];
            argument_index += 1;
            const target: ast.Binding.Target = switch (parameter.kind) {
                .type => .{ .type = argument.value.type },
                .compile_time => .{ .constant = try addBoundConstant(allocator, module, template.module, name, parameter, argument) },
                .run_time => unreachable,
            };
            try bindings.append(allocator, .{ .name = parameter.name, .target = target });
        }
        instance.signature.name = name;
        instance.signature.parameters = parameters.items;
        instance.template = template;
        instance.bindings = bindings.items;
        const index = module.declarations.len + module.instances.items.len;
        const created = try allocator.create(ast.Declaration);
        created.* = .{ .kind = .{ .function_definition = instance }, .location = declaration.location };
        try module.instances.append(allocator, created);
        return .{ .module = template.module, .declaration = index };
    }

    fn buildResolver(self: *NameResolver) Resolver {
        return .{
            .context = self,
            .resolve = resolveForChecker,
            .resolveParameterType = resolveParameterTypeForChecker,
            .instantiate = instantiateForChecker,
            .beginStruct = beginStructForChecker,
            .finishStruct = finishStructForChecker,
        };
    }

    fn beginStructForChecker(context: *anyopaque, struct_type: *const ast.StructType) AnalyzeError!types.Type {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        const number = for (self.structs.items) |*created| {
            if (created.module != struct_type.module or !std.mem.eql(u8, created.prefix, struct_type.prefix)) continue;
            created.count += 1;
            break created.count;
        } else number: {
            try self.structs.append(allocator, .{ .module = struct_type.module, .prefix = struct_type.prefix });
            break :number 1;
        };
        const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ struct_type.prefix, number });
        const fields = try reserveFields(allocator, struct_type.fields);
        return .{ .@"struct" = .{ .module = struct_type.module, .name = name, .fields = fields } };
    }

    fn finishStructForChecker(
        context: *anyopaque,
        struct_type: *const ast.StructType,
        value_type: types.Type,
        location: token.Location,
    ) AnalyzeError!void {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        var bindings: std.ArrayList(ast.Binding) = .empty;
        try bindings.appendSlice(allocator, struct_type.bindings);
        try bindings.append(allocator, .{ .name = "Self", .target = .{ .type = value_type } });
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        self.module_index = struct_type.module;
        self.self_type = value_type;
        self.trait = null;
        self.bindings = bindings.items;
        const fields = try allocator.alloc(ast.Field, struct_type.fields.len);
        for (struct_type.fields, fields) |field, *cloned| cloned.* = try ast.cloneField(allocator, field);
        try self.resolveFields(fields, @constCast(value_type.@"struct".fields));
        try self.expectNotContained(value_type.@"struct", location);
        try self.types.add(allocator, value_type);
        try self.addStructFunctions(struct_type, bindings.items);
    }

    fn addStructFunctions(
        self: *NameResolver,
        struct_type: *const ast.StructType,
        bindings: []const ast.Binding,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const module = &self.loader.modules.items[struct_type.module];
        for (struct_type.functions, 0..) |declaration, position| {
            const signature = declaration.kind.function_definition.signature;
            for (struct_type.functions[0..position]) |earlier| {
                const earlier_name = earlier.kind.function_definition.signature.name;
                if (std.mem.eql(u8, earlier_name, signature.name)) return self.fail(declaration.location, error.DuplicateFunction);
            }
            if (findFieldDeclaration(struct_type.fields, signature.name) != null) {
                return self.fail(declaration.location, error.MethodIsField);
            }
            var function = try ast.cloneFunctionDefinition(allocator, declaration.kind.function_definition);
            function.bindings = bindings;
            const index = module.declarations.len + module.instances.items.len;
            const created = try allocator.create(ast.Declaration);
            created.* = .{ .kind = .{ .function_definition = function }, .location = declaration.location };
            try module.instances.append(allocator, created);
            try self.resolveFunctionSignature(struct_type.module, index);
            try self.type_checker.?.created.append(allocator, .{ .module = struct_type.module, .declaration = index });
        }
    }

    fn prepareChecker(self: *NameResolver) ResolveError!*TypeChecker {
        const type_checker = self.type_checker.?;
        try self.resolveAllImplementationTypes();
        try self.resolveAllSignatures();
        type_checker.resolver = self.buildResolver();
        type_checker.failure = null;
        return type_checker;
    }

    fn resolvePendingMethod(self: *NameResolver, pending: PendingMethod) NameError!void {
        self.module_index = pending.module;
        const modules = self.loader.modules.items;
        const receiver = pending.method.receiver;
        const name = pending.method.name;
        pending.resolution.* = switch (ast.findMethod(modules, pending.module, receiver, name)) {
            .found => |function| .{ .function = function },
            .missing => return self.fail(pending.location, error.UnknownMethod),
            .ambiguous => return self.fail(pending.location, error.AmbiguousMethod),
        };
    }

    fn resolveFunctionTypes(
        self: *NameResolver,
        signature: *ast.FunctionSignature,
    ) ResolveError!void {
        for (signature.parameters, 0..) |*parameter, index| {
            const discarded = ast.isDiscardedName(parameter.name);
            if (!discarded and findTypedName(signature.parameters, parameter.name) != index) {
                return self.fail(parameter.location, error.DuplicateParameter);
            }
            try self.resolveTypedName(parameter.name, parameter.location, &parameter.type);
        }
        try self.resolveNamesInExpression(.{}, &signature.return_type);
        _ = try self.expectRuntimeType(&signature.return_type);
    }

    fn resolveTypedName(
        self: *NameResolver,
        name: []const u8,
        location: token.Location,
        written_type: *ast.Expression,
    ) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        if (isReservedName(module.path, name)) return self.fail(location, error.ReservedName);
        try self.resolveNamesInExpression(.{}, written_type);
        _ = try self.expectRuntimeType(written_type);
    }

    fn expectRuntimeType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        const value_type = try self.expectType(expression);
        if (!isRuntimeType(value_type)) return self.fail(expression.location, error.FunctionWithoutPointer);
        return value_type;
    }

    fn expectType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        if (expression.denoted) |denoted| return denoted;
        switch (expression.kind) {
            inline .identifier, .path_expression => |name| {
                const resolution = name.resolution orelse return self.fail(expression.location, error.TypeMismatch);
                return switch (resolution) {
                    .type => |value_type| value_type,
                    .constant, .local => self.evaluateType(expression),
                    .parameter, .function, .element, .trait_function, .trait_method => {
                        return self.fail(expression.location, error.TypeMismatch);
                    },
                };
            },
            .array_type => |array_type| return array_type.value.?,
            .slice_type => |slice_type| return slice_type.value.?,
            .pointer_type => |pointer_type| return pointer_type.value.?,
            .optional_type => |optional_type| return optional_type.value.?,
            .tuple_type => |tuple_type| return tuple_type.value.?,
            .function_type => |function_type| return function_type.value.?,
            .call, .method_call, .index, .field_access, .unwrap, .dereference, .struct_type => {
                return self.evaluateType(expression);
            },
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .negation,
            .binary,
            .unary,
            .address_of,
            .composite_literal,
            .slice,
            => return self.fail(expression.location, error.TypeMismatch),
        }
    }

    fn evaluateType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        if (self.type_checker == null) return self.fail(expression.location, error.TypeMismatch);
        const type_checker = try self.prepareChecker();
        const modules = self.loader.modules.items;
        if (!type_checker.isKnown(modules, expression.*)) return self.fail(expression.location, error.TypeMismatch);
        const value = type_checker.evaluateKnown(modules, self.module_index, expression, .type) catch |type_error| {
            if (type_checker.failure) |failure| self.failure = failure;
            return type_error;
        };
        expression.denoted = value.type;
        return value.type;
    }

    fn resolveNamesInFunction(
        self: *NameResolver,
        function: ast.FunctionDefinition,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const parameters = function.signature.parameters;
        const parameter_uses = try allocator.alloc(ast.Use, parameters.len);
        @memset(parameter_uses, .{});
        var locals: std.ArrayList(Local) = .empty;
        var loops: std.ArrayList(Loop) = .empty;
        const block: Block = .{
            .parameters = parameters,
            .parameter_uses = parameter_uses,
            .locals = &locals,
            .loops = &loops,
        };
        try self.resolveNamesInBlock(block, function.body);
        for (parameters, parameter_uses) |parameter, use| {
            if (ast.isDiscardedName(parameter.name)) continue;
            try self.expectUsed(use, parameter.location, error.UnusedParameter);
        }
    }

    fn resolveNamesInBlock(
        self: *NameResolver,
        block: Block,
        body: []ast.Statement,
    ) ResolveError!void {
        const start = block.locals.items.len;
        for (body) |*statement| {
            const local = (try self.resolveNamesInStatement(block, statement)) orelse continue;
            try block.locals.append(self.arena.allocator(), local);
        }
        for (block.locals.items[start..]) |local| {
            if (local.deferred) {
                local.statement.kind.variable_declaration.deferred_use = local.use;
                continue;
            }
            const mutable = local.statement.kind == .variable_declaration;
            if (mutable and !local.use.modified) {
                return self.fail(local.location, error.NeverModified);
            }
            const unused_error: NameError = if (mutable)
                error.UnusedVariable
            else
                error.UnusedLocalConstant;
            try self.expectUsed(local.use, local.location, unused_error);
        }
        block.locals.shrinkRetainingCapacity(start);
    }

    fn resolveNamesInStatement(
        self: *NameResolver,
        block: Block,
        statement: *ast.Statement,
    ) ResolveError!?Local {
        const scope: Scope = .{
            .parameters = block.parameters,
            .parameter_uses = block.parameter_uses,
            .locals = block.locals.items,
        };
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    try self.resolveNamesInExpression(scope, expression);
                }
            },
            .discard => |*expression| {
                if (expression.kind == .identifier) {
                    try self.resolveDiscardedName(scope, expression);
                } else {
                    try self.resolveNamesInExpression(scope, expression);
                }
            },
            .call => |*expression| try self.resolveNamesInExpression(scope, expression),
            .constant_declaration => |*constant| {
                return .{
                    .name = constant.name,
                    .target = try self.resolveLocalConstant(scope, statement, constant),
                    .statement = statement,
                    .location = statement.location,
                };
            },
            .tuple_declaration => |*declaration| {
                try self.resolveNamesInExpression(scope, &declaration.value);
                if (ast.hasPointerName(declaration.names)) {
                    recordModifiedVariable(scope, findStorageRoot(declaration.value));
                }
                try self.declareElements(block, statement);
            },
            .variable_declaration => |*variable| {
                try self.resolveVariable(scope, statement.location, variable);
                return .{
                    .name = variable.name,
                    .target = .{ .local = statement },
                    .statement = statement,
                    .location = statement.location,
                };
            },
            .assignment => |*assignment| {
                try self.resolveNamesInExpression(scope, &assignment.value);
                try self.resolveTarget(scope, &assignment.target);
                if (assignment.operator != null) {
                    recordReadVariable(scope, findStorageRoot(assignment.target));
                }
            },
            .@"if" => |*conditional| {
                try self.resolveNamesInExpression(scope, &conditional.condition);
                try self.resolveNamesInBlock(block, conditional.body);
                if (conditional.else_body) |else_body| try self.resolveNamesInBlock(block, else_body);
            },
            .@"while" => |*loop| {
                try self.resolveNamesInExpression(scope, &loop.condition);
                try self.resolveLoop(block, statement);
                if (loop.else_body) |else_body| try self.resolveNamesInBlock(block, else_body);
            },
            .@"for" => |*loop| {
                try self.resolveSequence(scope, &loop.sequence);
                if (ast.hasPointerName(loop.names) and loop.sequence == .value) {
                    recordModifiedVariable(scope, findStorageRoot(loop.sequence.value));
                }
                try self.resolveLoop(block, statement);
                if (loop.else_body) |else_body| try self.resolveNamesInBlock(block, else_body);
            },
            .@"break" => |*jump| {
                jump.loop = try self.resolveJump(block, statement.location, jump.label, error.BreakOutsideLoop);
            },
            .@"continue" => |*jump| {
                jump.loop = try self.resolveJump(block, statement.location, jump.label, error.ContinueOutsideLoop);
            },
        }
        return null;
    }

    fn resolveSequence(self: *NameResolver, scope: Scope, sequence: *ast.Sequence) ResolveError!void {
        switch (sequence.*) {
            .value => |*value| try self.resolveNamesInExpression(scope, value),
            .range => |*range| {
                try self.resolveNamesInExpression(scope, &range.start);
                if (range.end) |*end| try self.resolveNamesInExpression(scope, end);
            },
        }
    }

    fn resolveLoop(self: *NameResolver, block: Block, statement: *ast.Statement) ResolveError!void {
        const label = ast.extractLabel(statement.*);
        if (label) |name| {
            const module = self.loader.modules.items[self.module_index];
            if (isReservedName(module.path, name)) return self.fail(statement.location, error.ReservedName);
            if (findLoop(block.loops.items, name) != null) {
                return self.fail(statement.location, error.DuplicateLabel);
            }
        }
        try block.loops.append(self.arena.allocator(), .{ .statement = statement });
        const start = block.locals.items.len;
        const body = switch (statement.kind) {
            .@"while" => |loop| loop.body,
            .@"for" => |loop| body: {
                try self.declareElements(block, statement);
                break :body loop.body;
            },
            else => unreachable,
        };
        try self.resolveNamesInBlock(block, body);
        for (block.locals.items[start..]) |local| {
            try self.expectUsed(local.use, local.location, error.UnusedLoopName);
        }
        block.locals.shrinkRetainingCapacity(start);
        const resolved = block.loops.pop().?;
        if (label != null and !resolved.label_used) {
            return self.fail(statement.location, error.UnusedLabel);
        }
    }

    fn declareElements(self: *NameResolver, block: Block, statement: *ast.Statement) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        for (ast.extractElementNames(statement.*), 0..) |element_name, position| {
            if (ast.isDiscardedName(element_name.name)) continue;
            if (isReservedName(module.path, element_name.name)) {
                return self.fail(element_name.location, error.ReservedName);
            }
            try block.locals.append(self.arena.allocator(), .{
                .name = element_name.name,
                .target = .{ .element = .{ .statement = statement, .position = position } },
                .statement = statement,
                .location = element_name.location,
            });
        }
    }

    fn resolveJump(
        self: *NameResolver,
        block: Block,
        location: token.Location,
        label: ?[]const u8,
        outside_error: NameError,
    ) NameError!*const ast.Statement {
        const loops = block.loops.items;
        if (loops.len == 0) return self.fail(location, outside_error);
        const name = label orelse return loops[loops.len - 1].statement;
        const loop = findLoop(loops, name) orelse return self.fail(location, error.UnknownLabel);
        loop.label_used = true;
        return loop.statement;
    }

    fn resolveLocalConstant(
        self: *NameResolver,
        scope: Scope,
        statement: *const ast.Statement,
        constant: *ast.ConstantDeclaration,
    ) ResolveError!Target {
        const module = self.loader.modules.items[self.module_index];
        if (isReservedName(module.path, constant.name)) {
            return self.fail(statement.location, error.ReservedName);
        }
        const value = &constant.value;
        if (constant.type) |*written| {
            try self.resolveWrittenType(scope, written, value.*);
        } else if (try self.findAlias(scope, value)) |target| {
            return target;
        }
        try self.resolveNamesInExpression(scope, value);
        if (self.type_checker == null) return .{ .local = statement };
        const modules = self.loader.modules.items;
        if (!self.type_checker.?.isKnown(modules, value.*)) return .{ .local = statement };
        const type_checker = try self.prepareChecker();
        type_checker.checkKnownConstant(modules, self.module_index, constant) catch |type_error| {
            if (type_checker.failure) |failure| self.failure = failure;
            return type_error;
        };
        return .{ .local = statement };
    }

    fn resolveWrittenType(
        self: *NameResolver,
        scope: Scope,
        written_type: *ast.Expression,
        value: ast.Expression,
    ) ResolveError!void {
        if (written_type.kind == .array_type) {
            const array_type = &written_type.kind.array_type;
            if (value.kind == .composite_literal) {
                const length = value.kind.composite_literal.elements.len;
                try self.resolveArrayType(scope, written_type.location, array_type, length);
                _ = try self.expectRuntimeType(written_type);
                return;
            }
            if (array_type.length == null) {
                try self.resolveNamesInExpression(.{ .locals = scope.locals }, array_type.element);
                _ = try self.expectRuntimeType(array_type.element);
                return;
            }
        }
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, written_type);
        _ = try self.expectRuntimeType(written_type);
    }

    fn findAlias(self: *NameResolver, scope: Scope, value: *ast.Expression) ResolveError!?Target {
        const target: Target = switch (value.kind) {
            .identifier => |identifier| target: {
                if (findLocal(scope.locals, identifier.name)) |local| {
                    local.use.used = true;
                    break :target local.target;
                }
                if (findTypedName(scope.parameters, identifier.name) != null) return null;
                break :target try self.resolveName(value.location, identifier.name);
            },
            .path_expression => |path_expression| target: {
                const path = path_expression.path;
                break :target try self.resolvePath(scope, value.location, path);
            },
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => target: {
                try self.resolveNamesInExpression(scope, value);
                break :target .{ .type = ast.extractType(value.*) };
            },
            else => return null,
        };
        return switch (target) {
            .function, .type, .method, .trait => target,
            .namespace => self.fail(value.location, error.ModuleInConstant),
            .constant, .local, .element, .trait_method => null,
        };
    }

    fn resolveVariable(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        variable: *ast.VariableDeclaration,
    ) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        if (isReservedName(module.path, variable.name)) {
            return self.fail(location, error.ReservedName);
        }
        if (variable.type) |*written| {
            try self.resolveWrittenType(scope, written, variable.value);
        }
        try self.resolveNamesInExpression(scope, &variable.value);
    }

    fn resolveTarget(self: *NameResolver, scope: Scope, target: *ast.Expression) ResolveError!void {
        switch (target.kind) {
            .identifier => |*identifier| {
                if (findLocal(scope.locals, identifier.name)) |local| {
                    if (local.statement.kind != .variable_declaration) {
                        return self.fail(target.location, error.NotAssignable);
                    }
                    local.use.modified = true;
                    identifier.resolution = .{ .local = local.statement };
                    return;
                }
                if (findTypedName(scope.parameters, identifier.name) == null) {
                    _ = try self.resolveName(target.location, identifier.name);
                }
                return self.fail(target.location, error.NotAssignable);
            },
            .field_access, .index, .dereference => try self.resolveTargetPath(scope, target),
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .path_expression,
            .call,
            .method_call,
            .negation,
            .binary,
            .unary,
            .address_of,
            .array_type,
            .composite_literal,
            .slice_type,
            .slice,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .struct_type,
            .unwrap,
            => unreachable,
        }
    }

    fn resolveTargetPath(
        self: *NameResolver,
        scope: Scope,
        expression: *ast.Expression,
    ) ResolveError!void {
        switch (expression.kind) {
            .field_access => |access| try self.resolveTargetPath(scope, access.value),
            .index => |indexing| {
                try self.resolveTargetPath(scope, indexing.value);
                try self.resolveNamesInExpression(scope, indexing.index);
            },
            .identifier => |*identifier| {
                const local = findLocal(scope.locals, identifier.name) orelse {
                    return self.resolveNamesInExpression(scope, expression);
                };
                if (local.statement.kind != .variable_declaration) {
                    return self.resolveNamesInExpression(scope, expression);
                }
                local.deferred = true;
                identifier.resolution = .{ .local = local.statement };
            },
            else => try self.resolveNamesInExpression(scope, expression),
        }
    }

    fn resolveDiscardedName(
        self: *NameResolver,
        scope: Scope,
        expression: *ast.Expression,
    ) NameError!void {
        const identifier = &expression.kind.identifier;
        const location = expression.location;
        if (findLocal(scope.locals, identifier.name)) |local| {
            try self.recordDiscard(&local.use, location);
            identifier.resolution = extractLocalResolution(local.*);
            return;
        }
        if (findTypedName(scope.parameters, identifier.name)) |index| {
            try self.recordDiscard(&scope.parameter_uses[index], location);
            identifier.resolution = .{ .parameter = index };
            return;
        }
        return self.fail(location, error.NotDiscardable);
    }

    fn recordDiscard(self: *NameResolver, use: *ast.Use, location: token.Location) NameError!void {
        if (use.discard != null) return self.fail(location, error.PointlessDiscard);
        use.discard = location;
    }

    fn expectUsed(
        self: *NameResolver,
        use: ast.Use,
        location: token.Location,
        unused_error: NameError,
    ) NameError!void {
        if (use.discard) |discard| {
            if (use.used) return self.fail(discard, error.PointlessDiscard);
        } else if (!use.used) {
            return self.fail(location, unused_error);
        }
    }

    fn resolveNamesInExpression(
        self: *NameResolver,
        scope: Scope,
        expression: *ast.Expression,
    ) ResolveError!void {
        const location = expression.location;
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal, .undefined, .null => {},
            .identifier => |*identifier| try self.resolveIdentifier(scope, location, identifier),
            .path_expression => |*path_expression| {
                const target = try self.resolvePath(scope, location, path_expression.path);
                try self.resolveValue(location, target, &path_expression.resolution);
            },
            .call => |*call| {
                try self.resolveCallee(scope, location, &call.callee);
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(scope, &argument.value);
                    recordModifiedVariable(scope, argument.value);
                }
            },
            .method_call => |*call| {
                try self.resolveNamesInExpression(scope, call.receiver);
                recordModifiedVariable(scope, findStorageRoot(call.receiver.*));
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(scope, &argument.value);
                    recordModifiedVariable(scope, argument.value);
                }
            },
            .negation => |operand| try self.resolveNamesInExpression(scope, operand),
            .binary => |binary| {
                try self.resolveNamesInExpression(scope, binary.left);
                try self.resolveNamesInExpression(scope, binary.right);
            },
            .unary => |unary| try self.resolveNamesInExpression(scope, unary.operand),
            .address_of => |operand| {
                try self.resolveNamesInExpression(scope, operand);
                recordModifiedVariable(scope, findStorageRoot(operand.*));
            },
            .array_type => |*array_type| {
                try self.resolveArrayType(scope, location, array_type, null);
            },
            .composite_literal => |literal| {
                if (literal.type) |literal_type| {
                    try self.resolveLiteralType(scope, literal_type, literal.elements.len);
                }
                for (literal.elements) |*element| try self.resolveNamesInExpression(scope, &element.value);
            },
            .slice_type => |*slice_type| try self.resolveSliceType(scope, slice_type),
            .index => |indexing| {
                try self.resolveNamesInExpression(scope, indexing.value);
                try self.resolveNamesInExpression(scope, indexing.index);
            },
            .slice => |slice| try self.resolveSlice(scope, slice),
            .pointer_type => |*pointer_type| try self.resolvePointerType(scope, location, pointer_type),
            .optional_type => |*optional_type| try self.resolveOptionalType(scope, optional_type),
            .tuple_type => |*tuple_type| try self.resolveTupleType(scope, tuple_type),
            .function_type => |*function_type| try self.resolveFunctionType(scope, function_type),
            .field_access => |access| try self.resolveNamesInExpression(scope, access.value),
            .dereference, .unwrap => |operand| try self.resolveNamesInExpression(scope, operand),
            .struct_type => |struct_type| {
                struct_type.module = self.module_index;
                struct_type.bindings = self.bindings;
                struct_type.prefix = self.owner_name;
            },
        }
    }

    fn resolveLiteralType(
        self: *NameResolver,
        scope: Scope,
        literal_type: *ast.Expression,
        length: u64,
    ) ResolveError!void {
        const location = literal_type.location;
        switch (literal_type.kind) {
            .array_type => |*array_type| {
                try self.resolveArrayType(scope, location, array_type, length);
            },
            .tuple_type => |*tuple_type| try self.resolveTupleType(scope, tuple_type),
            inline .identifier, .path_expression => |*name| {
                try self.resolveNamesInExpression(scope, literal_type);
                const resolution = name.resolution orelse {
                    return self.fail(location, error.NotLiteralType);
                };
                switch (resolution) {
                    .type, .constant, .local => {},
                    .parameter, .function, .element, .trait_function, .trait_method => {
                        return self.fail(location, error.NotLiteralType);
                    },
                }
                try self.expectLiteralType(literal_type);
            },
            .call => {
                try self.resolveNamesInExpression(scope, literal_type);
                try self.expectLiteralType(literal_type);
            },
            else => unreachable,
        }
        _ = try self.expectRuntimeType(literal_type);
    }

    fn expectLiteralType(self: *NameResolver, literal_type: *ast.Expression) ResolveError!void {
        switch (try self.expectType(literal_type)) {
            .array, .tuple, .@"struct" => {},
            .number, .boolean, .void, .type, .slice, .pointer, .optional, .function, .implementer => {
                return self.fail(literal_type.location, error.NotLiteralType);
            },
        }
    }

    fn resolveArrayType(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        array_type: *ast.ArrayType,
        literal_length: ?u64,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, array_type.element);
        const element = try self.expectType(array_type.element);
        var known_length = literal_length;
        if (array_type.length) |length| known_length = try self.expectLength(scope, length);
        const length = known_length orelse return self.fail(location, error.UnknownLength);
        const array = try self.types.addArray(self.arena.allocator(), length, element);
        array_type.value = .{ .array = array };
    }

    fn expectLength(
        self: *NameResolver,
        scope: Scope,
        expression: *ast.Expression,
    ) ResolveError!u64 {
        if (expression.kind == .integer_literal and expression.kind.integer_literal.suffix == null) {
            if (std.fmt.parseInt(u64, expression.kind.integer_literal.text, 0)) |length| {
                return length;
            } else |_| {}
        }
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, expression);
        const type_checker = try self.prepareChecker();
        const modules = self.loader.modules.items;
        if (!type_checker.isKnown(modules, expression.*)) return self.fail(expression.location, error.CannotEvaluate);
        const usize_type: types.Type = .{ .number = .usize };
        const value = type_checker.evaluateKnown(modules, self.module_index, expression, usize_type) catch |type_error| {
            if (type_checker.failure) |failure| self.failure = failure;
            return type_error;
        };
        return @intCast(value.integer);
    }

    fn resolveSliceType(
        self: *NameResolver,
        scope: Scope,
        slice_type: *ast.SliceType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, slice_type.element);
        const element = try self.expectType(slice_type.element);
        const allocator = self.arena.allocator();
        const slice = try self.types.addSlice(allocator, element, slice_type.constant);
        slice_type.value = .{ .slice = slice };
    }

    fn resolveSlice(self: *NameResolver, scope: Scope, slice: ast.Slice) ResolveError!void {
        try self.resolveNamesInExpression(scope, slice.value);
        if (slice.start) |start| try self.resolveNamesInExpression(scope, start);
        if (slice.end) |end| try self.resolveNamesInExpression(scope, end);
        recordModifiedVariable(scope, findStorageRoot(slice.value.*));
    }

    fn resolvePointerType(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        pointer_type: *ast.PointerType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, pointer_type.target);
        const target = try self.expectType(pointer_type.target);
        if (target == .function) {
            if (pointer_type.many) return self.fail(location, error.ManyFunctionPointer);
            if (pointer_type.constant) return self.fail(location, error.ConstantFunctionPointer);
        }
        const pointer = try self.types.addPointer(self.arena.allocator(), .{
            .target = target,
            .many = pointer_type.many,
            .constant = pointer_type.constant,
        });
        pointer_type.value = .{ .pointer = pointer };
    }

    fn resolveOptionalType(
        self: *NameResolver,
        scope: Scope,
        optional_type: *ast.OptionalType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, optional_type.child);
        const child = try self.expectType(optional_type.child);
        const optional = try self.types.addOptional(self.arena.allocator(), child);
        optional_type.value = .{ .optional = optional };
    }

    fn resolveTupleType(
        self: *NameResolver,
        scope: Scope,
        tuple_type: *ast.TupleType,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const elements = try allocator.alloc(types.Type, tuple_type.elements.len);
        for (tuple_type.elements, elements) |*written, *element| {
            try self.resolveNamesInExpression(.{ .locals = scope.locals }, written);
            element.* = try self.expectType(written);
        }
        const tuple = try self.types.addTuple(allocator, elements);
        tuple_type.value = .{ .tuple = tuple };
    }

    fn resolveFunctionType(
        self: *NameResolver,
        scope: Scope,
        function_type: *ast.FunctionType,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const type_scope: Scope = .{ .locals = scope.locals };
        const parameters = try allocator.alloc(types.Type, function_type.parameters.len);
        for (function_type.parameters, parameters) |*written, *parameter| {
            try self.resolveNamesInExpression(type_scope, written);
            parameter.* = try self.expectType(written);
        }
        try self.resolveNamesInExpression(type_scope, function_type.return_type);
        const return_type = try self.expectType(function_type.return_type);
        const function = try self.types.addFunction(allocator, parameters, return_type);
        function_type.value = .{ .function = function };
    }

    fn resolveIdentifier(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        identifier: *ast.Identifier,
    ) ResolveError!void {
        if (findLocal(scope.locals, identifier.name)) |local| {
            local.use.used = true;
            return self.resolveValue(location, local.target, &identifier.resolution);
        }
        if (findTypedName(scope.parameters, identifier.name)) |index| {
            scope.parameter_uses[index].used = true;
            identifier.resolution = .{ .parameter = index };
            return;
        }
        const target = try self.resolveName(location, identifier.name);
        try self.resolveValue(location, target, &identifier.resolution);
    }

    fn resolveValue(
        self: *NameResolver,
        location: token.Location,
        target: Target,
        resolution: *?ast.Resolution,
    ) ResolveError!void {
        if (target == .method) {
            if (try self.findSelfFunction(location, target.method)) |function| {
                resolution.* = function;
                return;
            }
            const pending: PendingMethod = .{
                .resolution = resolution,
                .method = target.method,
                .location = location,
                .module = self.module_index,
            };
            return self.pending.append(self.arena.allocator(), pending);
        }
        resolution.* = try self.expectValue(location, target);
    }

    fn expectValue(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) NameError!ast.Resolution {
        return switch (target) {
            .type => |value| .{ .type = value },
            .constant => |constant| .{ .constant = constant },
            .local => |local| .{ .local = local },
            .element => |element| .{ .element = element },
            .function => |function| {
                const module = self.loader.modules.items[function.module];
                const declaration = ast.findDeclaration(module, function.declaration).*;
                if (ast.isMain(ast.extractFunctionSignature(declaration))) {
                    return self.fail(location, error.MainUsedAsValue);
                }
                return .{ .function = function };
            },
            .method => unreachable,
            .trait, .trait_method => self.fail(location, error.TraitUsedAsValue),
            .namespace => self.fail(location, error.ModuleUsedAsValue),
        };
    }

    fn resolveCallee(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        callee: *ast.Name,
    ) ResolveError!void {
        const target, const resolution = switch (callee.*) {
            .identifier => |*identifier| target: {
                const name = identifier.name;
                if (findLocal(scope.locals, name)) |local| {
                    local.use.used = true;
                    break :target .{ local.target, &identifier.resolution };
                }
                if (findTypedName(scope.parameters, name)) |index| {
                    scope.parameter_uses[index].used = true;
                    identifier.resolution = .{ .parameter = index };
                    return;
                }
                break :target .{ try self.resolveName(location, name), &identifier.resolution };
            },
            .path_expression => |*path_expression| target: {
                const path = path_expression.path;
                const target = try self.resolvePath(scope, location, path);
                break :target .{ target, &path_expression.resolution };
            },
            .member => |*member| target: {
                try self.resolveNamesInExpression(scope, member.owner);
                const receiver = try self.expectType(member.owner);
                const target: Target = .{ .method = .{ .receiver = receiver, .name = member.name } };
                break :target .{ target, &member.resolution };
            },
        };
        if (target == .method) {
            if (try self.findSelfFunction(location, target.method)) |function| {
                resolution.* = function;
                return;
            }
            const pending: PendingMethod = .{
                .resolution = resolution,
                .method = target.method,
                .location = location,
                .module = self.module_index,
            };
            return self.pending.append(self.arena.allocator(), pending);
        }
        resolution.* = try self.expectCallee(location, target);
    }

    fn findSelfFunction(self: *NameResolver, location: token.Location, method: Method) NameError!?ast.Resolution {
        const trait = self.trait orelse return null;
        const self_type = self.self_type orelse return null;
        if (!std.meta.eql(method.receiver, self_type)) return null;
        const modules = self.loader.modules.items;
        if (method.receiver == .implementer) {
            const definition = modules[trait.module].declarations[trait.declaration].kind.trait_definition;
            const position = findSignaturePosition(definition.functions, method.name) orelse {
                return self.fail(location, error.UnknownMethod);
            };
            return .{ .trait_function = .{ .trait = trait, .function = position } };
        }
        const function = ast.findTraitFunction(modules, trait, method.receiver, method.name) orelse {
            return self.fail(location, error.UnknownMethod);
        };
        return .{ .function = function };
    }

    fn expectCallee(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) ResolveError!ast.Resolution {
        return switch (target) {
            .function => |function| .{ .function = function },
            .local => |local| .{ .local = local },
            .element => |element| .{ .element = element },
            .constant => |constant| .{ .constant = constant },
            .trait_method => |method| .{ .trait_method = method },
            .type, .namespace, .method, .trait => {
                return self.fail(location, error.NotAFunction);
            },
        };
    }

    fn resolveName(
        self: *NameResolver,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Target {
        var binding_index = self.bindings.len;
        while (binding_index > 0) {
            binding_index -= 1;
            const binding = self.bindings[binding_index];
            if (!std.mem.eql(u8, binding.name, name)) continue;
            return switch (binding.target) {
                .type => |value_type| .{ .type = value_type },
                .constant => |constant| .{ .constant = constant },
            };
        }
        if (std.mem.eql(u8, name, "Self")) {
            const self_type = self.self_type orelse return self.fail(location, error.UnknownName);
            return .{ .type = self_type };
        }
        const module = self.loader.modules.items[self.module_index];
        if (findDeclaration(module, name)) |index| {
            return self.resolveDeclaration(self.module_index, index);
        }
        if (types.findBuiltInType(name)) |built_in_type| return .{ .type = built_in_type };
        return self.fail(location, error.UnknownName);
    }

    fn resolvePath(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        path: ast.Path,
    ) ResolveError!Target {
        const last = path[path.len - 1];
        if (try self.findPathOwner(scope, location, path[0 .. path.len - 1])) |owner| {
            return switch (owner) {
                .type => |receiver| .{ .method = .{ .receiver = receiver, .name = last } },
                .trait => |trait| {
                    const declaration = self.loader.modules.items[trait.module].declarations[trait.declaration];
                    const functions = declaration.kind.trait_definition.functions;
                    const position = findSignaturePosition(functions, last) orelse {
                        return self.fail(location, error.UnknownMethod);
                    };
                    return .{ .trait_method = .{ .trait = trait, .function = position } };
                },
                .function, .namespace, .constant, .local, .element, .method, .trait_method => unreachable,
            };
        }
        var namespace = try self.resolveFirstNamespace(scope, location, path[0]);
        for (path[1 .. path.len - 1]) |name| {
            namespace = try self.resolveMemberNamespace(location, namespace, name);
        }
        return self.resolveMember(location, namespace, last);
    }

    fn findPathOwner(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        prefix: ast.Path,
    ) ResolveError!?Target {
        const last = prefix[prefix.len - 1];
        if (prefix.len > 1) {
            var namespace = try self.resolveFirstNamespace(scope, location, prefix[0]);
            for (prefix[1 .. prefix.len - 1]) |name| {
                namespace = try self.resolveMemberNamespace(location, namespace, name);
            }
            const module_index = namespace.module orelse return null;
            const index = findMember(self.loader.modules.items[module_index], last) orelse return null;
            return self.findOwner(module_index, index);
        }
        if (findLocal(scope.locals, last)) |local| {
            if (local.target != .type and local.target != .trait) return null;
            local.use.used = true;
            return local.target;
        }
        if (findTypedName(scope.parameters, last) != null) return null;
        if (std.mem.eql(u8, last, "Self")) return try self.resolveName(location, last);
        const module = self.loader.modules.items[self.module_index];
        const index = findDeclaration(module, last) orelse {
            const built_in_type = types.findBuiltInType(last) orelse return null;
            return .{ .type = built_in_type };
        };
        return self.findOwner(self.module_index, index);
    }

    fn findOwner(self: *NameResolver, module_index: usize, index: usize) ResolveError!?Target {
        const target = try self.resolveDeclaration(module_index, index);
        return switch (target) {
            .type, .trait => target,
            .function, .namespace, .constant, .local, .element, .method, .trait_method => null,
        };
    }

    fn resolveFirstNamespace(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Namespace {
        if (findLocal(scope.locals, name) != null) return self.fail(location, error.NoMembers);
        if (findTypedName(scope.parameters, name) != null) {
            return self.fail(location, error.NoMembers);
        }
        const module = self.loader.modules.items[self.module_index];
        if (findDeclaration(module, name)) |index| {
            return self.expectNamespace(location, self.module_index, index);
        }
        if (isBuiltInTypeName(name)) return self.fail(location, error.NoMembers);
        return self.fail(location, error.UnknownName);
    }

    fn resolveMemberNamespace(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Namespace {
        if (try self.loadMember(namespace, name)) |member| return member;
        if (namespace.module) |module_index| {
            const module = self.loader.modules.items[module_index];
            if (isImported(module, name)) return self.fail(location, error.ImportNotMember);
            if (findMember(module, name)) |index| {
                return self.expectNamespace(location, module_index, index);
            }
        }
        if (namespace.directory) return self.fail(location, error.ModuleNotFound);
        return self.fail(location, error.UnknownName);
    }

    fn expectNamespace(
        self: *NameResolver,
        location: token.Location,
        module_index: usize,
        index: usize,
    ) ResolveError!Namespace {
        switch (self.loader.modules.items[module_index].declarations[index].kind) {
            .import, .constant_declaration => {
                const target = try self.resolveDeclaration(module_index, index);
                if (target == .namespace) return target.namespace;
            },
            .function_definition,
            .function_declaration,
            .struct_definition,
            .trait_definition,
            .implementation,
            => {},
        }
        return self.fail(location, error.NoMembers);
    }

    fn resolveMember(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Target {
        if (namespace.module) |module_index| {
            const module = self.loader.modules.items[module_index];
            if (findMember(module, name)) |index| {
                return self.resolveDeclaration(module_index, index);
            }
        }
        if (try self.loadMember(namespace, name)) |member| return .{ .namespace = member };
        if (namespace.module) |module_index| {
            const module = self.loader.modules.items[module_index];
            if (isImported(module, name)) return self.fail(location, error.ImportNotMember);
        }
        return self.fail(location, error.UnknownName);
    }

    fn resolveDeclaration(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!Target {
        return switch (self.loader.modules.items[module_index].declarations[index].kind) {
            .function_definition, .function_declaration => .{
                .function = .{ .module = module_index, .declaration = index },
            },
            .constant_declaration => self.resolveConstant(module_index, index),
            .struct_definition => .{ .type = try self.resolveStruct(module_index, index) },
            .trait_definition => .{ .trait = .{ .module = module_index, .declaration = index } },
            .import => self.resolveImport(module_index, index),
            .implementation => unreachable,
        };
    }

    fn resolveImport(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const import = &declaration.kind.import;
        const location = declaration.location;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        const path = import.path;
        var namespace = (try self.loadRoot(location, path[0])) orelse {
            return self.fail(location, error.ModuleNotFound);
        };
        if (path.len == 1) return .{ .namespace = namespace };
        for (path[1 .. path.len - 1]) |name| {
            namespace = try self.resolveMemberNamespace(location, namespace, name);
        }
        const target = try self.resolveMember(location, namespace, path[path.len - 1]);
        if (target == .trait) import.trait = target.trait;
        return target;
    }

    fn resolveConstant(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const constant = &declaration.kind.constant_declaration;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        const caller_owner_name = self.owner_name;
        defer self.owner_name = caller_owner_name;
        self.owner_name = constant.name;
        self.constant_depth += 1;
        defer self.constant_depth -= 1;
        if (self.constant_depth > countConstants(self.loader.modules.items)) {
            return self.fail(declaration.location, error.ConstantRefersToItself);
        }
        const value = &constant.value;
        const own: Target = .{ .constant = .{ .module = module_index, .declaration = index } };
        if (constant.type) |*written| {
            try self.resolveWrittenType(.{}, written, value.*);
            try self.resolveNamesInExpression(.{}, value);
            return own;
        }
        return switch (value.kind) {
            .identifier => |identifier| {
                const target = try self.resolveName(declaration.location, identifier.name);
                return self.expectHeldByConstant(declaration.location, target);
            },
            .path_expression => |path_expression| {
                const path = path_expression.path;
                const target = try self.resolvePath(.{}, declaration.location, path);
                return self.expectHeldByConstant(declaration.location, target);
            },
            .integer_literal, .float_literal, .boolean_literal, .string_literal, .undefined, .null => own,
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {
                try self.resolveNamesInExpression(.{}, value);
                return .{ .type = ast.extractType(value.*) };
            },
            .call,
            .method_call,
            .negation,
            .binary,
            .unary,
            .address_of,
            .composite_literal,
            .slice,
            .field_access,
            .index,
            .dereference,
            .unwrap,
            .struct_type,
            => {
                if (!constant.resolved) {
                    try self.resolveNamesInExpression(.{}, value);
                    constant.resolved = true;
                }
                return own;
            },
        };
    }

    fn expectHeldByConstant(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) NameError!Target {
        if (target == .namespace) return self.fail(location, error.ModuleInConstant);
        return target;
    }

    fn resolveStruct(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!types.Type {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const definition = &declaration.kind.struct_definition;
        if (definition.value) |value_type| return value_type;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_trait = self.trait;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.trait = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.trait = caller_trait;
        defer self.bindings = caller_bindings;
        const resolved = try reserveFields(self.arena.allocator(), definition.fields);
        const struct_type: types.Struct = .{ .module = module_index, .name = definition.name, .fields = resolved };
        const value_type: types.Type = .{ .@"struct" = struct_type };
        definition.value = value_type;
        self.self_type = value_type;
        try self.resolveFields(definition.fields, resolved);
        try self.expectNotContained(struct_type, declaration.location);
        try self.types.add(self.arena.allocator(), value_type);
        return value_type;
    }

    fn expectNotContained(self: *NameResolver, struct_type: types.Struct, location: token.Location) NameError!void {
        for (struct_type.fields) |field| {
            if (types.containsStruct(field.type, struct_type)) return self.fail(location, error.StructContainsItself);
        }
    }

    fn resolveFields(
        self: *NameResolver,
        fields: []ast.Field,
        resolved: []types.Field,
    ) ResolveError!void {
        for (fields, 0..) |*field, index| {
            const discarded = ast.isDiscardedName(field.name);
            if (!discarded and findFieldDeclaration(fields, field.name) != index) {
                return self.fail(field.location, error.DuplicateField);
            }
            try self.resolveTypedName(field.name, field.location, &field.type);
            if (field.default) |*default| try self.resolveNamesInExpression(.{}, default);
        }
        for (fields, resolved) |*field, *resolved_field| {
            resolved_field.* = .{
                .name = field.name,
                .type = ast.extractType(field.type),
                .default = if (field.default) |*default| default else null,
                .default_value = if (field.default != null) &field.default_value else null,
                .location = field.location,
            };
        }
    }

    fn loadRoot(
        self: *NameResolver,
        location: token.Location,
        name: []const u8,
    ) ResolveError!?Namespace {
        const namespace = self.loader.loadRoot(
            self.arena,
            self.io,
            self.module_index,
            location,
            name,
        ) catch |load_error| {
            return self.failLoading(load_error);
        };
        return namespace;
    }

    fn loadMember(
        self: *NameResolver,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!?Namespace {
        const member = self.loader.loadMember(
            self.arena,
            self.io,
            namespace,
            name,
        ) catch |load_error| {
            return self.failLoading(load_error);
        };
        return member;
    }

    fn hasMember(self: *NameResolver, path: ast.Path, name: []const u8) ResolveError!bool {
        const allocator = self.arena.allocator();
        return self.loader.hasMember(allocator, self.io, path, name) catch |load_error| {
            return self.failLoading(load_error);
        };
    }

    fn failLoading(self: *NameResolver, load_error: LoadError) LoadError {
        self.failure = self.loader.failure;
        return load_error;
    }

    fn failIn(self: *NameResolver, module_index: usize, location: token.Location, name_error: NameError) NameError {
        self.module_index = module_index;
        return self.fail(location, name_error);
    }

    fn fail(self: *NameResolver, location: token.Location, name_error: NameError) NameError {
        self.failure = .{
            .module = self.loader.modules.items[self.module_index].path,
            .location = location,
            .message = describeError(name_error),
        };
        return name_error;
    }
};

pub const ResolveError = AnalyzeError;

pub const NameError = error{
    DuplicateFunction,
    DuplicateConstant,
    DuplicateStruct,
    DuplicateParameter,
    DuplicateField,
    ReservedName,
    UnknownName,
    NotAFunction,
    MainUsedAsValue,
    NoMembers,
    ModuleNotFound,
    ConstantRefersToItself,
    StructContainsItself,
    NotAssignable,
    MethodIsField,
    UnknownMethod,
    AmbiguousMethod,
    DuplicateTrait,
    DuplicateImport,
    NamedLikeModule,
    ImportNotMember,
    ModuleUsedAsValue,
    ModuleInConstant,
    NotATrait,
    TraitUsedAsValue,
    NotInTrait,
    MismatchedTraitFunction,
    GenericTraitFunction,
    MissingTraitFunction,
    DuplicateImplementation,
    NotLiteralType,
    UnknownLength,
    NeverModified,
    UnusedVariable,
    UnusedParameter,
    UnusedLocalConstant,
    NotDiscardable,
    PointlessDiscard,
    CannotEvaluate,
    TypeMismatch,
    FunctionWithoutPointer,
    ManyFunctionPointer,
    ConstantFunctionPointer,
    DuplicateLabel,
    UnusedLabel,
    UnknownLabel,
    BreakOutsideLoop,
    ContinueOutsideLoop,
    UnusedLoopName,
    DependencyLoop,
};

const StructCount = struct {
    module: usize,
    prefix: []const u8,
    count: usize = 1,
};

const PendingMethod = struct {
    resolution: *?ast.Resolution,
    method: Method,
    location: token.Location,
    module: usize,
};

const Block = struct {
    parameters: []const ast.TypedName,
    parameter_uses: []ast.Use,
    locals: *std.ArrayList(Local),
    loops: *std.ArrayList(Loop),
};

const Scope = struct {
    parameters: []const ast.TypedName = &.{},
    parameter_uses: []ast.Use = &.{},
    locals: []Local = &.{},
};

const Local = struct {
    name: []const u8,
    target: Target,
    statement: *ast.Statement,
    location: token.Location,
    use: ast.Use = .{},
    deferred: bool = false,
};

const Loop = struct {
    statement: *const ast.Statement,
    label_used: bool = false,
};

const Target = union(enum) {
    function: ast.Resolution.Function,
    namespace: Namespace,
    type: types.Type,
    constant: ast.Resolution.Constant,
    local: *const ast.Statement,
    element: ast.Resolution.Element,
    method: Method,
    trait_method: ast.Resolution.TraitFunction,
    trait: ast.Resolution.Trait,
};

const Method = struct {
    receiver: types.Type,
    name: []const u8,
};

fn describeError(name_error: NameError) []const u8 {
    return switch (name_error) {
        error.DuplicateFunction => "function is already defined",
        error.DuplicateConstant => "constant is already defined",
        error.DuplicateStruct => "struct is already defined",
        error.DuplicateParameter => "parameter is already defined",
        error.DuplicateField => "field is already defined",
        error.ReservedName => "name is reserved",
        error.UnknownName => "unknown name",
        error.NotAFunction => "name is not a function",
        error.MainUsedAsValue => "main cannot be used as a value",
        error.NoMembers => "name has no members",
        error.ModuleNotFound => "module not found",
        error.ConstantRefersToItself => "constant refers to itself",
        error.StructContainsItself => "struct contains itself",
        error.NotAssignable => "only variables and their fields can be assigned",
        error.MethodIsField => "method has the name of a field",
        error.UnknownMethod => "unknown method",
        error.AmbiguousMethod => "method is found in more than one place",
        error.DuplicateTrait => "trait is already defined",
        error.DuplicateImport => "name is already defined",
        error.NamedLikeModule => "name is already used by a module or directory",
        error.ImportNotMember => "an import is not a member of its module",
        error.ModuleUsedAsValue => "a module cannot be used here",
        error.ModuleInConstant => "a constant cannot hold a module, use import",
        error.NotATrait => "not a trait",
        error.TraitUsedAsValue => "a trait cannot be used here",
        error.NotInTrait => "function is not in the trait",
        error.MismatchedTraitFunction => "function does not match the trait",
        error.GenericTraitFunction => "trait functions cannot take compile-time parameters",
        error.MissingTraitFunction => "implementation is missing a function of the trait",
        error.DuplicateImplementation => "trait is already implemented for this type",
        error.NotLiteralType => "braces need an array, a tuple or a struct type",
        error.UnknownLength => "array length cannot be left out here",
        error.NeverModified => "variable is never modified, declare it with const",
        error.UnusedVariable => "variable is unused, discard it with _ =",
        error.UnusedParameter => "parameter is unused, discard it with _ =",
        error.UnusedLocalConstant => "local constant is unused, discard it with _ =",
        error.NotDiscardable => "only parameters, local constants and variables can be discarded",
        error.PointlessDiscard => "discarded name is used",
        error.CannotEvaluate => "cannot be evaluated at compile time",
        error.TypeMismatch => "value does not match the expected type",
        error.FunctionWithoutPointer => "function types need a pointer",
        error.ManyFunctionPointer => "functions need a single value pointer",
        error.ConstantFunctionPointer => "function pointers cannot be const",
        error.DuplicateLabel => "label is already used by an enclosing loop",
        error.UnusedLabel => "label is unused",
        error.UnknownLabel => "label does not name an enclosing loop",
        error.BreakOutsideLoop => "break outside a loop",
        error.ContinueOutsideLoop => "continue outside a loop",
        error.UnusedLoopName => "loop name is unused, use _",
        error.DependencyLoop => "value depends on itself at compile time",
    };
}

fn isRuntimeType(value_type: types.Type) bool {
    return switch (value_type) {
        .function => false,
        .pointer => |pointer| {
            if (pointer.target == .function) return isRuntimeFunction(pointer.target.function.*);
            return isRuntimeType(pointer.target);
        },
        .array => |array| isRuntimeType(array.element),
        .slice => |slice| isRuntimeType(slice.element),
        .optional => |optional| isRuntimeType(optional.child),
        .tuple => |tuple| areRuntimeTypes(tuple.elements),
        .number, .boolean, .void, .type, .@"struct", .implementer => true,
    };
}

fn isRuntimeFunction(function: types.Function) bool {
    return areRuntimeTypes(function.parameters) and isRuntimeType(function.return_type);
}

fn areRuntimeTypes(value_types: []const types.Type) bool {
    for (value_types) |value_type| {
        if (!isRuntimeType(value_type)) return false;
    }
    return true;
}

fn countConstants(modules: []const ast.Module) usize {
    var count: usize = 0;
    for (modules) |module| {
        for (module.declarations) |declaration| {
            if (declaration.kind == .constant_declaration) count += 1;
        }
    }
    return count;
}

fn isReservedName(module_path: ast.Path, name: []const u8) bool {
    if (std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "Self")) return true;
    return !isStandardLibrary(module_path) and hasReservedPrefix(name);
}

fn isStandardLibrary(path: ast.Path) bool {
    return path.len > 1 and std.mem.eql(u8, path[0], "std");
}

fn findDeclaration(module: ast.Module, name: []const u8) ?usize {
    for (module.declarations, 0..) |declaration, index| {
        if (isMethod(declaration)) continue;
        if (declaration.kind == .implementation) continue;
        if (std.mem.eql(u8, extractName(declaration), name)) return index;
    }
    return null;
}

fn findMember(module: ast.Module, name: []const u8) ?usize {
    if (isImported(module, name)) return null;
    return findDeclaration(module, name);
}

fn isImported(module: ast.Module, name: []const u8) bool {
    const index = findDeclaration(module, name) orelse return false;
    return module.declarations[index].kind == .import;
}

fn isMethod(declaration: ast.Declaration) bool {
    if (declaration.kind != .function_definition) return false;
    return declaration.kind.function_definition.signature.receiver != null;
}

fn extractName(declaration: ast.Declaration) []const u8 {
    return switch (declaration.kind) {
        .function_definition => |function| function.signature.name,
        .function_declaration => |function_declaration| function_declaration.name,
        .constant_declaration => |constant| constant.name,
        .struct_definition => |definition| definition.name,
        .trait_definition => |definition| definition.name,
        .import => |import| import.name,
        .implementation => unreachable,
    };
}

fn findSignature(
    signatures: []const ast.FunctionSignature,
    name: []const u8,
) ?ast.FunctionSignature {
    const position = findSignaturePosition(signatures, name) orelse return null;
    return signatures[position];
}

fn findSignaturePosition(signatures: []const ast.FunctionSignature, name: []const u8) ?usize {
    for (signatures, 0..) |signature, position| {
        if (std.mem.eql(u8, signature.name, name)) return position;
    }
    return null;
}

fn reserveFields(allocator: std.mem.Allocator, fields: []const ast.Field) std.mem.Allocator.Error![]types.Field {
    const reserved = try allocator.alloc(types.Field, fields.len);
    for (fields, reserved) |field, *placeholder| {
        placeholder.* = .{ .name = field.name, .type = .void, .location = field.location };
    }
    return reserved;
}

fn addBoundConstant(
    allocator: std.mem.Allocator,
    module: *ast.Module,
    module_index: usize,
    instance_name: []const u8,
    parameter: ast.TypedName,
    argument: Bound,
) std.mem.Allocator.Error!ast.Resolution.Constant {
    const known = try allocator.create(Value);
    known.* = argument.value;
    const name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ instance_name, parameter.name });
    const value: ast.Expression = .{ .kind = .undefined, .type = argument.type, .location = parameter.location };
    const constant: ast.ConstantDeclaration = .{ .name = name, .value = value, .resolved = true, .known = known };
    const index = module.declarations.len + module.instances.items.len;
    const declaration = try allocator.create(ast.Declaration);
    declaration.* = .{ .kind = .{ .constant_declaration = constant }, .location = parameter.location };
    try module.instances.append(allocator, declaration);
    return .{ .module = module_index, .declaration = index };
}

fn findDefinition(declarations: []const ast.Declaration, name: []const u8) ?usize {
    for (declarations, 0..) |declaration, index| {
        if (std.mem.eql(u8, declaration.kind.function_definition.signature.name, name)) return index;
    }
    return null;
}

fn matchesSignature(
    signature: ast.FunctionSignature,
    expected: ast.FunctionSignature,
    implemented: types.Type,
) bool {
    if (signature.parameters.len != expected.parameters.len) return false;
    if (ast.hasSelf(signature) != ast.hasSelf(expected)) return false;
    for (signature.parameters, expected.parameters) |parameter, expected_parameter| {
        const parameter_type = ast.extractType(parameter.type);
        const expected_type = ast.extractType(expected_parameter.type);
        if (!matchesType(parameter_type, expected_type, implemented)) return false;
    }
    const return_type = ast.extractType(signature.return_type);
    return matchesType(return_type, ast.extractType(expected.return_type), implemented);
}

fn matchesType(value_type: types.Type, expected: types.Type, implemented: types.Type) bool {
    return switch (expected) {
        .implementer => std.meta.eql(value_type, implemented),
        .array => |array| value_type == .array and value_type.array.length == array.length and
            matchesType(value_type.array.element, array.element, implemented),
        .slice => |slice| value_type == .slice and value_type.slice.constant == slice.constant and
            matchesType(value_type.slice.element, slice.element, implemented),
        .pointer => |pointer| value_type == .pointer and value_type.pointer.many == pointer.many and
            value_type.pointer.constant == pointer.constant and
            matchesType(value_type.pointer.target, pointer.target, implemented),
        .optional => |optional| value_type == .optional and
            matchesType(value_type.optional.child, optional.child, implemented),
        .tuple => |tuple| value_type == .tuple and
            matchesTypes(value_type.tuple.elements, tuple.elements, implemented),
        .function => |function| value_type == .function and
            matchesTypes(value_type.function.parameters, function.parameters, implemented) and
            matchesType(value_type.function.return_type, function.return_type, implemented),
        .number, .boolean, .void, .type, .@"struct" => std.meta.eql(value_type, expected),
    };
}

fn matchesTypes(
    value_types: []const types.Type,
    expected: []const types.Type,
    implemented: types.Type,
) bool {
    if (value_types.len != expected.len) return false;
    for (value_types, expected) |value_type, expected_type| {
        if (!matchesType(value_type, expected_type, implemented)) return false;
    }
    return true;
}

fn isBuiltInTypeName(name: []const u8) bool {
    return types.findBuiltInType(name) != null;
}

fn hasReservedPrefix(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mn_");
}

fn findTypedName(typed_names: []const ast.TypedName, name: []const u8) ?usize {
    for (typed_names, 0..) |typed_name, index| {
        if (std.mem.eql(u8, typed_name.name, name)) return index;
    }
    return null;
}

fn recordModifiedVariable(scope: Scope, expression: ast.Expression) void {
    if (expression.kind != .identifier) return;
    const identifier = expression.kind.identifier;
    const resolution = identifier.resolution orelse return;
    if (resolution != .local) return;
    const local = findLocal(scope.locals, identifier.name) orelse return;
    if (local.statement != resolution.local) return;
    if (local.statement.kind == .variable_declaration) local.use.modified = true;
}

fn recordReadVariable(scope: Scope, expression: ast.Expression) void {
    if (expression.kind != .identifier) return;
    const identifier = expression.kind.identifier;
    const resolution = identifier.resolution orelse return;
    if (resolution != .local) return;
    const local = findLocal(scope.locals, identifier.name) orelse return;
    if (local.statement == resolution.local) local.use.used = true;
}

fn findFieldDeclaration(fields: []const ast.Field, name: []const u8) ?usize {
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, name)) return index;
    }
    return null;
}

fn findStorageRoot(expression: ast.Expression) ast.Expression {
    return switch (expression.kind) {
        .field_access => |access| findStorageRoot(access.value.*),
        .index => |indexing| findStorageRoot(indexing.value.*),
        else => expression,
    };
}

fn findLoop(loops: []Loop, label: []const u8) ?*Loop {
    for (loops) |*loop| {
        const loop_label = ast.extractLabel(loop.statement.*) orelse continue;
        if (std.mem.eql(u8, loop_label, label)) return loop;
    }
    return null;
}

fn findLocal(locals: []Local, name: []const u8) ?*Local {
    var index = locals.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, locals[index].name, name)) return &locals[index];
    }
    return null;
}

fn extractLocalResolution(local: Local) ast.Resolution {
    if (local.target == .element) return .{ .element = local.target.element };
    return .{ .local = local.statement };
}

test "NameResolver.resolve: records what each name refers to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = add(1, 2)\nfn add(left: i32, right: i32) -> i32:\n    _ = left\n    return right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.discard.kind.call;
    try std.testing.expectEqual(1, call.callee.identifier.resolution.?.function.declaration);
    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[1].kind.@"return".?;
    try std.testing.expectEqual(1, value.kind.identifier.resolution.?.parameter);
}

test "NameResolver.resolve: resolves calls to external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn stdout_write(text: []const u8)\nfn main(): stdout_write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.identifier.resolution.?.function;
    try std.testing.expectEqual(0, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveModule: rejects a duplicate function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn one(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a duplicate constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst one = two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a duplicate struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nstruct one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateStruct, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a constant named like a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn size() -> i32: return 1\nconst size: i32 = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a function named like a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn Point(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a constant named like a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nconst Shape: i32 = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a struct named like an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write()\nstruct write" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateStruct, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a reserved name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mn_write(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: allows reserved names in the standard library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []const u8)\nconst write = mn_runtime_stdout_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std\nfn main(): std::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveModule: rejects void as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn void(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects Self as a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Self:\n    count: i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects two traits with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape\ntrait Shape" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateTrait, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects an import named like a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(): noop\nimport utils::add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateImport, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects two imports with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nimport other::utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateImport, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a declaration named like a module in the directory of its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "shapes");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw(): noop\nfn circle(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main(): shapes::circle()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NamedLikeModule, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a declaration named like a directory in the directory of its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "shapes/lines");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct lines" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NamedLikeModule, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: accepts an import named like a module in the directory of its module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "shapes");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn circle(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils::circle" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::circle\nfn main(): circle::area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "resolveTrait: resolves a trait of a module that is resolved later" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nstruct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const shapes = loader.modules.items[1].declarations[0].kind.trait_definition;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(shapes.functions[0].return_type));
}

test "resolveTrait: resolves a call through Self in a default to the function of the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\n    fn make() -> Self: return Self::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const definition = loader.modules.items[0].declarations[0].kind.trait_definition;
    const call = definition.defaults[2].?.body[0].kind.@"return".?.kind.call;
    const function: ast.Resolution.TraitFunction = .{ .trait = .{ .module = 0, .declaration = 0 }, .function = 1 };
    try std.testing.expectEqual(ast.Resolution{ .trait_function = function }, call.callee.path_expression.resolution.?);
}

test "addDefaults: adds a default for an implementation that leaves it out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\n    fn make() -> Self: return Self::unit()\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(6, declarations.len);
    try std.testing.expectEqualSlices(usize, &.{5}, declarations[2].kind.implementation.defaults);
    const default = declarations[5].kind.function_definition;
    try std.testing.expectEqualStrings("make", default.signature.name);
    try std.testing.expectEqual(ast.Resolution.Trait{ .module = 0, .declaration = 0 }, default.default_of.?);
    try std.testing.expectEqual(declarations[1].kind.struct_definition.value.?, ast.extractType(default.signature.return_type));
}

test "addDefaults: leaves out a default that the implementation defines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\n    fn make() -> Self: return Self::unit()\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}\n    fn make() -> Self: return Square{side = 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(6, declarations.len);
    try std.testing.expectEqual(0, declarations[2].kind.implementation.defaults.len);
}

test "addDefaults: lets a length call trait methods implemented by a default and by a written function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [count()]i32): _ = values\nfn count() -> usize:\n    const square = Square{side = 1}\n    return square.sides() + square.corners()\ntrait Shape:\n    fn sides(_: Self) -> usize\n    fn corners(self: Self) -> usize: return self.sides()\nstruct Square:\n    side: usize\nimpl Shape for Square:\n    fn sides(_: Self) -> usize: return 4" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(8, ast.extractType(parameters[0].type).array.length);
}

test "resolveImplementation: implements a trait for a struct that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nfn Box(type T) -> type:\n    return struct:\n        side: T\nimpl Shape for Box(i32):\n    fn area(self: Self) -> i32: return self.side\nconst BOX = Box(i32){side = 3}\nconst AREA = BOX.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[5].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 3 }, known);
}

test "resolveImplementation: resolves the trait and the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const implementation = loader.modules.items[0].declarations[2].kind.implementation;
    try std.testing.expectEqual(ast.Resolution.Trait{ .module = 0, .declaration = 0 }, implementation.resolved.?);
    try std.testing.expectEqualStrings("Square", ast.extractType(implementation.type).@"struct".name);
}

test "resolveImplementation: rejects a function that is not in the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn grow(self: Self): _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotInTrait, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveImplementation: rejects a function that does not match the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> bool:\n        _ = self\n        return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTraitFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveImplementation: matches Self of the trait with the implemented type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn merge(self: Self, others: []const Self) -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn merge(self: Self, others: []const Square) -> Square:\n        _ = others\n        return self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const merge = loader.modules.items[0].declarations[3].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Square", ast.extractType(merge.return_type).@"struct".name);
}

test "resolveImplementation: matches Self behind a pointer with the implemented type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn grow(self: Self, other: *const Self)\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn grow(self: Self, other: *const Square):\n        _ = self\n        _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const grow = loader.modules.items[0].declarations[3].kind.function_definition.signature;
    const pointer = ast.extractType(grow.parameters[1].type).pointer;
    try std.testing.expectEqualStrings("Square", pointer.target.@"struct".name);
}

test "resolveImplementation: rejects a pointer of another mutability than the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn grow(self: Self, other: *const Self)\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn grow(self: Self, other: *Square):\n        _ = self\n        _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTraitFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveImplementation: rejects the implemented type for a Self parameter of a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Square) -> i32: return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTraitFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveImplementation: rejects a missing function of the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MissingTraitFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveImplementation: accepts leaving out a function with a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveImplementation: rejects a missing function without a default next to a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn double(self: Self) -> i32: return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MissingTraitFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 1 }, name_resolver.failure.?.location.?);
}

test "expectTrait: rejects an implementation of something that is not a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Square:\n    side: i32\nimpl Square for Square" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotATrait, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 6 }, name_resolver.failure.?.location.?);
}

test "expectSingleImplementations: rejects a second implementation of a trait for a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateImplementation, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionSignature: resolves the receiver and self of a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\n    fn show(self: Self) -> []const u8: return self.question" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.receiver.?).@"struct".name);
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.parameters[0].type).@"struct".name);
}

test "resolveFunctionSignature: rejects a signature that depends on itself at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn size(values: [count()]usize) -> usize:\n    _ = values\n    return 1\nfn count() -> usize:\n    const values = [1]usize{1}\n    return size(values)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DependencyLoop, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 12 }, analyzer.failure.?.location.?);
}

test "expectUniqueMethod: rejects two methods with the same name for one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn show(self: Self): _ = self\n    fn show(self: Self): _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "expectUniqueMethod: allows methods with the same name for different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One:\n    fn show(self: Self): _ = self\nstruct Two:\n    fn show(self: Self): _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "expectUniqueMethod: allows a method and a function with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card{}\nfn new(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "expectUniqueMethod: rejects a method with the name of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: []const u8\n    fn question(self: Self): _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MethodIsField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionBody: resolves a call through Self in a default to the function of the implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\n    fn make() -> Self: return Self::unit()\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const default = loader.modules.items[0].declarations[5].kind.function_definition;
    const call = default.body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 4 } }, call.callee.path_expression.resolution.?);
}

test "resolveFunctionBody: resolves a method that a length calls at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    count: usize\n    fn size(self: Self) -> usize: return self.count\nfn make() -> usize:\n    const box = Box{count = 2}\n    return box.size()\nfn main():\n    const values: [make()]i32 = {1, 2}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[3].kind.function_definition.body;
    try std.testing.expectEqual(2, ast.extractType(body[0].kind.constant_declaration.type.?).array.length);
}

test "resolvePendingMethod: resolves a function declared on a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card{}\nfn main(): _ = Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, callee.resolution.?);
}

test "resolvePendingMethod: rejects an unknown method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\nfn main(): _ = Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolvePendingMethod: finds a function of a struct of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "cards.mn", .data = "struct Card:\n    fn new() -> Card: return Card{}" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import cards\nfn main(): _ = cards::Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    const module = loader.modules.items[callee.resolution.?.function.module];
    try std.testing.expectEqualStrings("cards", module.path[0]);
}

test "resolvePendingMethod: finds a function of a trait without a Self parameter through the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn new() -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn new() -> Self: return Square{side = 1}\nfn main(): _ = Square::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, callee.resolution.?);
}

test "resolvePendingMethod: finds a default function through the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\n    fn make() -> Self: return Self::unit()\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}\nfn main(): _ = Square::make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 6 } }, callee.resolution.?);
}

test "resolvePendingMethod: chooses the function of the struct's block over a trait's function through the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\n    fn area(self: Self) -> i32: return self.side\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn main(): _ = Square::area(Square{side = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 2 } }, callee.resolution.?);
}

test "resolveFunctionTypes: resolves built-in types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: i32) -> bool:\n    _ = value\n    return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[0].kind.function_definition.signature;
    const parameter_type = signature.parameters[0].type.kind.identifier.resolution.?;
    try std.testing.expectEqual(ast.Resolution{ .type = .{ .number = .i32 } }, parameter_type);
    try std.testing.expectEqual(ast.Resolution{ .type = .boolean }, signature.return_type.kind.identifier.resolution.?);
}

test "resolveFunctionTypes: rejects an unknown type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: Integer): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionTypes: rejects char and string as unknown type names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(letter: char, text: string): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionTypes: resolves structs named char and string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct char\nstruct string\nfn show(letter: char, text: string):\n    _ = letter\n    _ = text" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expectEqualStrings("char", ast.extractType(parameters[0].type).@"struct".name);
    try std.testing.expectEqualStrings("string", ast.extractType(parameters[1].type).@"struct".name);
}

test "resolveFunctionTypes: rejects a return type that is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add() -> 5: noop\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionTypes: rejects a duplicate parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: i32, value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionTypes: allows two discarded parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(_: i32, _: bool): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[0].kind.function_definition.signature;
    try std.testing.expectEqual(types.Type.boolean, ast.extractType(signature.parameters[1].type));
}

test "resolveTypedName: rejects a reserved parameter name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(mn_value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 8 }, name_resolver.failure.?.location.?);
}

test "resolveTypedName: accepts a built-in type name as a parameter name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(i32: i32) -> i32: return i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(0, value.kind.identifier.resolution.?.parameter);
}

test "resolveTypedName: rejects a value that is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: 5): noop\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, name_resolver.failure.?.location.?);
}

test "resolveTypedName: accepts a void parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: void): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type));
}

test "expectRuntimeType: rejects a parameter of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: fn(i32)): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects a return type of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn get() -> fn(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects a field of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    callback: fn()\nfn show(data: Data): _ = data" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects an optional function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: ?fn()): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects an array of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: [2]fn()): _ = callbacks" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects a slice of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: []fn()): _ = callbacks" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects a tuple with a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(pair: [i32, fn()]): _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: rejects a function type as a parameter of a pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(fn())): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "expectRuntimeType: accepts pointers to functions in an optional and an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(maybe: ?*fn(), all: [2]*fn()):\n    _ = maybe\n    _ = all" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expect(ast.extractType(parameters[0].type).optional.child.pointer.target == .function);
    try std.testing.expect(ast.extractType(parameters[1].type).array.element.pointer.target == .function);
}

test "expectRuntimeType: accepts a pointer to an alias of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn(i32) -> i32\nfn apply(callback: *Callback): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const function = ast.extractType(parameters[0].type).pointer.target.function;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, function.return_type);
}

test "expectRuntimeType: rejects an alias of a function type without a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn(i32) -> i32\nfn apply(callback: Callback): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, name_resolver.failure.?.location.?);
}

test "beginStructForChecker: creates a new type for each struct without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const One = struct:\n    value: i32\nconst Two = struct:\n    value: i32\nfn take(one: One, two: Two):\n    _ = one\n    _ = two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type).@"struct";
    const two = ast.extractType(parameters[1].type).@"struct";
    try std.testing.expect(!std.meta.eql(one, two));
    try std.testing.expectEqualStrings("One_1", one.name);
    try std.testing.expectEqualStrings("Two_1", two.name);
}

test "beginStructForChecker: gives a call with the same arguments the same type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Box(type T) -> type:\n    return struct:\n        value: T\nfn take(one: Box(i32), two: Box(i32), three: Box(u8)):\n    _ = one\n    _ = two\n    _ = three" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type);
    try std.testing.expectEqual(one, ast.extractType(parameters[1].type));
    try std.testing.expect(!std.meta.eql(one, ast.extractType(parameters[2].type)));
    try std.testing.expectEqualStrings("Box_1", one.@"struct".name);
    try std.testing.expectEqualStrings("Box_2", ast.extractType(parameters[2].type).@"struct".name);
}

test "finishStructForChecker: points to the struct itself through Self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Link(type A) -> type:\n    return struct:\n        value: A\n        next: ?*Self\nfn take(link: Link(i32)): _ = link" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const node = ast.extractType(parameters[0].type).@"struct";
    try std.testing.expectEqual(types.Type{ .number = .i32 }, node.fields[0].type);
    try std.testing.expect(std.meta.eql(node, node.fields[1].type.optional.child.pointer.target.@"struct"));
}

test "finishStructForChecker: points to the struct itself through a call with the same arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type:\n    return struct:\n        value: A\n        next: ?*Node(A)\nfn take(node: Node(i32)): _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const node = ast.extractType(parameters[0].type).@"struct";
    try std.testing.expect(std.meta.eql(node, node.fields[1].type.optional.child.pointer.target.@"struct"));
}

test "finishStructForChecker: rejects a struct that holds itself through a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type:\n    return struct:\n        next: Node(A)\nfn take(node: Node(i32)): _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, analyzer.failure.?.location.?);
}

test "finishStructForChecker: rejects a struct that holds itself through Self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type:\n    return struct:\n        next: [2]Self\nfn take(node: Node(i32)): _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, analyzer.failure.?.location.?);
}

test "finishStructForChecker: ends a struct whose fields keep creating new types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Nested(type A) -> type:\n    return struct:\n        next: ?*Nested([A, A])\nfn take(value: Nested(i32)): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InstanceDepth, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 17 }, analyzer.failure.?.location.?);
}

test "addStructFunctions: makes the functions of a struct without a name callable through the type and on values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Counter(type T) -> type:\n    return struct:\n        count: T = 0\n        fn new() -> Self: return {}\n        fn add(self: *Self, amount: T): self.count += amount\n        fn read(self: Self) -> T: return self.count\nfn total() -> i64:\n    var counter = Counter(i64)::new()\n    counter.add(5)\n    return counter.read()\nconst TOTAL = total()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 5 }, known);
}

test "addStructFunctions: rejects a function named like a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Box(type T) -> type:\n    return struct:\n        value: T\n        fn value(self: Self) -> T: return self.value\nfn take(box: Box(i32)): _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MethodIsField, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 9 }, analyzer.failure.?.location.?);
}

test "evaluateType: takes a parameter type from a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type: return i32\nfn first(value: Number()) -> i32: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[0].type));
}

test "evaluateType: takes a type from an element of an array of types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const kinds = [2]type{i32, bool}\nfn first(value: kinds[1]) -> bool: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.boolean, ast.extractType(parameters[0].type));
}

test "evaluateType: takes a type from an element of a tuple of types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const kinds = [type, type]{i32, bool}\nfn first(value: kinds[0]) -> i32: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[0].type));
}

test "evaluateType: builds types from a constant type that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type: return i32\nconst Kind = Number()\nconst LENGTH: usize = 3\nfn take(values: [LENGTH]Kind, maybe: ?Kind, pointer: *Kind, pair: [Kind, bool]):\n    _ = values\n    _ = maybe\n    _ = pointer\n    _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[3].kind.function_definition.signature.parameters;
    const array = ast.extractType(parameters[0].type).array;
    try std.testing.expectEqual(3, array.length);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, array.element);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[1].type).optional.child);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[2].type).pointer.target);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[3].type).tuple.elements[0]);
}

test "evaluateType: takes a type from a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type: return i32\nfn main():\n    const Kind = Number()\n    var value: Kind = 1\n    value += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(body[1].kind.variable_declaration.type.?));
}

test "evaluateType: rejects a call that does not give a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> usize: return 1\nfn first(value: count()): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, analyzer.failure.?.location.?);
}

test "resolveNamesInFunction: resolves a name to a constant declared before it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const limit = 5i32\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const argument = body[1].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(&body[0], argument.kind.identifier.resolution.?.local);
}

test "resolveNamesInFunction: lets a constant shadow a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    _ = value\n    const value = 5i32\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const returned = body[2].kind.@"return".?;
    try std.testing.expectEqual(&body[1], returned.kind.identifier.resolution.?.local);
}

test "resolveNamesInFunction: lets a constant shadow an earlier constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const value = 1i32\n    _ = value\n    const value = 2i32\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const returned = body[3].kind.@"return".?;
    try std.testing.expectEqual(&body[2], returned.kind.identifier.resolution.?.local);
}

test "resolveNamesInFunction: lets a local constant shadow a built-in type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn get() -> i32:\n    const u8 = 5i32\n    return u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(&body[0], body[1].kind.@"return".?.kind.identifier.resolution.?.local);
}

test "resolveNamesInFunction: rejects an unused parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInFunction: allows unused parameters of external functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write(value: i32)\nfn main(): write(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(0, call.callee.identifier.resolution.?.function.declaration);
}

test "resolveNamesInFunction: allows a discarded parameter that is not used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(_: i32): noop\nfn main(): show(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(0, call.callee.identifier.resolution.?.function.declaration);
}

test "resolveNamesInBlock: rejects an unused local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): const limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: rejects a constant that is shadowed before any use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const value = 1i32\n    const value = 2i32\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: rejects a variable that is never modified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count = 1i32\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NeverModified, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: rejects a variable that is only assigned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count = 1i32\n    count = 2i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedVariable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: counts a field assignment as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show(value: i32): _ = value\nfn main():\n    var point = Point{x = 1}\n    point.x = 2\n    show(point.x)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: counts slicing as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: counts an element assignment as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values = [2]i32{1, 2}\n    values[0] = 3\n    const copy = values\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: counts taking an address as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    const pointer = &value\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: does not count a write through a pointer as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    var pointer = &value\n    pointer.* = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NeverModified, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: counts passing to a call as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(buffer: [4]u8): _ = buffer\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: counts passing to a method as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter:\n    count: i32\n    fn show(self: Self): _ = self\nfn main():\n    var counter = Counter{count = 1}\n    counter.show()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}
test "resolveNamesInBlock: counts calling a method on a field of a variable as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter:\n    count: i32\n    fn increment(self: *Self): self.count += 1\nstruct Holder:\n    counter: Counter\nfn main():\n    var holder = Holder{counter = {count = 1}}\n    holder.counter.increment()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInBlock: does not count passing to a construction as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    value: i32\nfn main():\n    var value = 1i32\n    const box = Box{value = value}\n    _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NeverModified, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: ends a local at the end of its block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    while false:\n        const limit = 5i32\n        take(limit)\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 10 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: restores an outer local after a block that shadows it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const value = 1i32\n    while false:\n        const value = 2i32\n        _ = value\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(&body[0], body[2].kind.@"return".?.kind.identifier.resolution.?.local);
}

test "resolveNamesInBlock: rejects an unused local in a nested block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): while false: const limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInBlock: counts an assignment in a nested block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var running = true\n    while running:\n        running = false" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const assignment = body[1].kind.@"while".body[0].kind.assignment;
    try std.testing.expectEqual(&body[0], assignment.target.kind.identifier.resolution.?.local);
}

test "resolveNamesInStatement: counts a compound assignment as a use and a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count = 1i32\n    count += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: counts a compound assignment to a field as a use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    point.x += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expect(body[0].kind.variable_declaration.deferred_use.?.used);
}

test "resolveNamesInStatement: resolves the names in the blocks of an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const one = 1i32\n    if true:\n        take(one)\n    else:\n        take(one)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const conditional = body[1].kind.@"if";
    const first = conditional.body[0].kind.call.kind.call.arguments[0].value.kind.identifier;
    try std.testing.expectEqual(&body[0], first.resolution.?.local);
    const second = conditional.else_body.?[0].kind.call.kind.call.arguments[0].value.kind.identifier;
    try std.testing.expectEqual(&body[0], second.resolution.?.local);
}

test "resolveNamesInStatement: rejects an unused local constant in an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    if true: noop\n    else: const unused = 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 11 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInStatement: counts an assignment in one branch of an if as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    var count = 0i32\n    if true: count = 1\n    take(count)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: resolves the names in the else block of a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const one = 1i32\n    while false: noop\n    else: take(one)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const argument = body[1].kind.@"while".else_body.?[0].kind.call.kind.call.arguments[0].value.kind.identifier;
    try std.testing.expectEqual(&body[0], argument.resolution.?.local);
}

test "resolveNamesInStatement: resolves a break to the innermost loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    while true:\n        while false: break\n        break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const outer = body[0].kind.@"while";
    try std.testing.expectEqual(&outer.body[0], outer.body[0].kind.@"while".body[0].kind.@"break".loop.?);
    try std.testing.expectEqual(&body[0], outer.body[1].kind.@"break".loop.?);
}

test "resolveNamesInStatement: resolves a break in the else block of a loop to the enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    while true:\n        while false: noop\n        else: break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const inner = body[0].kind.@"while".body[0].kind.@"while";
    try std.testing.expectEqual(&body[0], inner.else_body.?[0].kind.@"break".loop.?);
}

test "resolveNamesInStatement: declares each name of a tuple declaration at its position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pair: [i32, i32]):\n    const (first, second) = pair\n    take(first)\n    take(second)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const first = body[1].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    const second = body[2].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    try std.testing.expectEqual(ast.Resolution.Element{ .statement = &body[0], .position = 0 }, first.element);
    try std.testing.expectEqual(ast.Resolution.Element{ .statement = &body[0], .position = 1 }, second.element);
}

test "resolveNamesInStatement: resolves the value of a tuple declaration before its names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pair: [i32, i32]):\n    const (pair, other) = pair\n    take(pair)\n    take(other)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, body[0].kind.tuple_declaration.value.kind.identifier.resolution.?);
    const shadowed = body[1].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    try std.testing.expectEqual(&body[0], shadowed.element.statement);
}

test "resolveNamesInStatement: rejects an unused name of a tuple declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pair: [i32, i32]):\n    const (first, second) = pair\n    take(first)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInStatement: leaves an underscore in a tuple declaration without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pair: [i32, i32]):\n    const (_, second) = pair\n    take(second)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: accepts a discarded name of a tuple declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pair: [i32, i32]):\n    const (first, second) = pair\n    _ = first\n    take(second)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: counts a pointer name of a tuple declaration as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var pair = [i32, i32]{1, 2}\n    const (*first, _) = pair\n    first.* = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: counts a pointer name of a for loop as a modification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values = [2]i32{1, 2}\n    for *value in values: value.* = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveSequence: resolves a sequence outside the names of its loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const items = [2]i32{1, 2}\n    for items in items: take(items)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const loop = body[1].kind.@"for";
    try std.testing.expectEqual(&body[0], loop.sequence.value.kind.identifier.resolution.?.local);
    const argument = loop.body[0].kind.call.kind.call.arguments[0].value.kind.identifier;
    try std.testing.expectEqual(&body[1], argument.resolution.?.element.statement);
}

test "resolveSequence: resolves both bounds of a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize): _ = value\nfn main():\n    const first = 1usize\n    const last = 3usize\n    for index in first..last: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const range = body[2].kind.@"for".sequence.range;
    try std.testing.expectEqual(&body[0], range.start.kind.identifier.resolution.?.local);
    try std.testing.expectEqual(&body[1], range.end.?.kind.identifier.resolution.?.local);
}

test "resolveLoop: resolves a labeled break and continue to the labeled loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while true:\n        while false: continue outer\n        break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const outer = body[0].kind.@"while";
    try std.testing.expectEqual(&body[0], outer.body[0].kind.@"while".body[0].kind.@"continue".loop.?);
    try std.testing.expectEqual(&body[0], outer.body[1].kind.@"break".loop.?);
}

test "resolveLoop: rejects a label that repeats the label of an enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while true:\n        outer: while false: break outer\n        break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: accepts a label that repeats the label of a loop that does not enclose it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while false: break outer\n    else:\n        outer: while false: break outer\n    outer: while false: break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveLoop: rejects an unused label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while false: break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: rejects a reserved label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    Self: while false: break Self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: ends the names of a for loop at the end of its body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(items: []const i32):\n    for item in items: take(item)\n    take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: leaves the names of a for loop out of its else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(items: []const i32):\n    for item in items: take(item)\n    else: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: rejects an unused name of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn show(items: []const i32): for item in items: step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLoopName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 34 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: accepts an underscore in place of a name of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main(): for _ in 0..3: step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveLoop: declares each name in parentheses of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pairs: [][i32, i32]):\n    for (first, second) in pairs:\n        take(first)\n        take(second)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const loop_body = body[0].kind.@"for".body;
    const first = loop_body[0].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    const second = loop_body[1].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    try std.testing.expectEqual(ast.Resolution.Element{ .statement = &body[0], .position = 0 }, first.element);
    try std.testing.expectEqual(ast.Resolution.Element{ .statement = &body[0], .position = 1 }, second.element);
}

test "resolveLoop: rejects an unused name in parentheses of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(pairs: [][i32, i32]):\n    for (first, second) in pairs: take(first)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLoopName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: resolves a labeled break and continue to a labeled for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: for _ in 0..3:\n        while false: continue outer\n        break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const outer = body[0].kind.@"for";
    try std.testing.expectEqual(&body[0], outer.body[0].kind.@"while".body[0].kind.@"continue".loop.?);
    try std.testing.expectEqual(&body[0], outer.body[1].kind.@"break".loop.?);
}

test "resolveLoop: rejects a label of a for loop that repeats the label of an enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while true:\n        outer: for _ in 0..3: break outer\n        break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: rejects an unused label of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: for _ in 0..3: break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "declareElements: resolves the name to its loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(items: []const i32): for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const arguments = body[0].kind.@"for".body[0].kind.call.kind.call.arguments;
    try std.testing.expectEqual(&body[0], arguments[0].value.kind.identifier.resolution.?.element.statement);
}

test "declareElements: rejects a reserved name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(items: []const i32): for mn_item in items: take(mn_item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 34 }, name_resolver.failure.?.location.?);
}

test "resolveJump: rejects a break outside a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.BreakOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveJump: rejects a continue in the else block of a loop without an enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    while false: noop\n    else: continue" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ContinueOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 11 }, name_resolver.failure.?.location.?);
}

test "resolveJump: rejects a continue in the else block of a for loop without an enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    for _ in 0..3: noop\n    else: continue" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ContinueOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 11 }, name_resolver.failure.?.location.?);
}

test "resolveJump: rejects a label that does not name an enclosing loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    outer: while false: break outer\n    while false: break outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, name_resolver.failure.?.location.?);
}

test "resolveLocalConstant: rejects a reserved name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): const mn_limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveLocalConstant: accepts a parameter as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    const copy = value\n    return copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(0, body[0].kind.constant_declaration.value.kind.identifier.resolution.?.parameter);
    try std.testing.expectEqual(&body[0], body[1].kind.@"return".?.kind.identifier.resolution.?.local);
}

test "resolveLocalConstant: accepts a construction from parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show(value: i32) -> Point:\n    const point = Point{x = value}\n    return point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(&body[0], body[1].kind.@"return".?.kind.identifier.resolution.?.local);
}

test "resolveWrittenType: takes the length of a constant from its array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [_]i32 = {1, 2, 3}\nfn all() -> [3]i32: return values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const written = loader.modules.items[0].declarations[0].kind.constant_declaration.type.?;
    try std.testing.expectEqual(3, ast.extractType(written).array.length);
}

test "resolveWrittenType: takes the length of a variable from its array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values: [_]i32 = {1, 2}\n    values = {3, 4}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const written = body[0].kind.variable_declaration.type.?;
    try std.testing.expectEqual(2, ast.extractType(written).array.length);
}

test "resolveWrittenType: rejects a length to take inside a pointer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var buffer: [2]i32 = undefined\n    const pointer: *[_]i32 = &buffer\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects a length to take inside an optional type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const maybe: ?[_]i32 = null\n    _ = maybe" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects a nested length to take" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [2][3]i32 = {{1, 2, 3}, {4, 5, 6}}\nconst second: [_][_]i32 = first\nfn all() -> [2][3]i32: return second" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects a length to take for the elements of a value that is not braced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [2][3]i32 = {{1, 2, 3}, {4, 5, 6}}\nconst second: [2][_]i32 = first\nfn all() -> [2][3]i32: return second" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects a variable of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var step: fn() = undefined\n    step = step" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects a constant of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst step: fn() = one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveWrittenType: rejects function types in an array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst steps: [_]fn() = {one}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 14 }, name_resolver.failure.?.location.?);
}

test "findAlias: keeps a function name as an alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) -> i32: return value\nfn main():\n    const run = take\n    _ = run(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(0, body[1].kind.discard.kind.call.callee.identifier.resolution.?.function.declaration);
}

test "findAlias: holds the value of a constant that names a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5i32\nfn show() -> i32:\n    const copy = limit\n    return copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(&body[0], body[1].kind.@"return".?.kind.identifier.resolution.?.local);
}

test "findAlias: rejects a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main():\n    const figures = shapes\n    figures::draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleInConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolveTarget: assigns a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count = 1i32\n    count = 2i32\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(&body[0], body[1].kind.assignment.target.kind.identifier.resolution.?.local);
}

test "resolveTarget: assigns a field of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show() -> Point:\n    var point = Point{x = 1}\n    point.x = 2\n    return point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const root = body[1].kind.assignment.target.kind.field_access.value;
    try std.testing.expectEqual(&body[0], root.kind.identifier.resolution.?.local);
}

test "resolveTarget: counts a write through a local constant as a use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var buffer: [2]u8 = undefined\n    const bytes = buffer[..]\n    bytes[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const root = body[2].kind.assignment.target.kind.index.value.kind.identifier;
    try std.testing.expectEqual(&body[1], root.resolution.?.local);
}

test "resolveTarget: resolves the names in an assigned element of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: []u8, position: usize): values[position] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const target = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.assignment.target;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, target.kind.index.value.kind.identifier.resolution.?);
    try std.testing.expectEqual(ast.Resolution{ .parameter = 1 }, target.kind.index.index.kind.identifier.resolution.?);
}

test "resolveTarget: rejects assigning to a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const count = 1i32\n    count = 2i32\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveTarget: rejects assigning to a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: i32 = 1\nfn main(): limit = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveTarget: rejects assigning to a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(count: i32) -> i32:\n    count = 2\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveTarget: rejects assigning to a name of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(items: []const i32): for item in items: item = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 49 }, name_resolver.failure.?.location.?);
}

test "resolveTarget: rejects an unknown name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): missing = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveTargetPath: leaves the use of a variable written through a field to the type checker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const use = body[0].kind.variable_declaration.deferred_use.?;
    try std.testing.expect(!use.used);
    try std.testing.expect(!use.modified);
}

test "resolveDiscardedName: discards a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const discarded = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(0, discarded.kind.identifier.resolution.?.parameter);
}

test "resolveDiscardedName: discards a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const limit = 5i32\n    _ = limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const discarded = body[1].kind.discard;
    try std.testing.expectEqual(&body[0], discarded.kind.identifier.resolution.?.local);
}

test "resolveDiscardedName: discards a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count = 1i32\n    count = 2i32\n    _ = count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const discarded = body[2].kind.discard;
    try std.testing.expectEqual(&body[0], discarded.kind.identifier.resolution.?.local);
}

test "resolveDiscardedName: discards a name of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(items: []const i32): for item in items: _ = item" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const discarded = body[0].kind.@"for".body[0].kind.discard;
    try std.testing.expectEqual(&body[0], discarded.kind.identifier.resolution.?.element.statement);
}

test "resolveDiscardedName: rejects a name that is not a parameter or local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5i32\nfn main(): _ = limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotDiscardable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, name_resolver.failure.?.location.?);
}

test "recordDiscard: rejects a second discard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32):\n    _ = value\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.PointlessDiscard, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 9 }, name_resolver.failure.?.location.?);
}

test "expectUsed: rejects a discarded name that is also used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    _ = value\n    return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.PointlessDiscard, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 9 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInExpression: rejects an unknown argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): log(missing)\nfn log(value: i32): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInExpression: resolves a function of another module used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() -> i32: return 1" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn value() -> i32: return utils::add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const function = value.kind.path_expression.resolution.?.function;
    const declaration = loader.modules.items[function.module].declarations[function.declaration];
    try std.testing.expectEqualStrings("add", ast.extractFunctionSignature(declaration).name);
}

test "resolveNamesInExpression: resolves the value of a field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: Point) -> i32: return point.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const value = returned.kind.field_access.value.kind.identifier;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, value.resolution.?);
}

test "resolveNamesInExpression: resolves the names in an index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: []const i32, position: usize) -> i32: return values[position]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, returned.kind.index.value.kind.identifier.resolution.?);
    try std.testing.expectEqual(ast.Resolution{ .parameter = 1 }, returned.kind.index.index.kind.identifier.resolution.?);
}

test "resolveNamesInExpression: resolves the operands of an address and a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: i32) -> i32: return (&value).*" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const value = returned.kind.dereference.kind.address_of.kind.identifier;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, value.resolution.?);
}

test "resolveNamesInExpression: resolves the operand of an unwrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: ?i32) -> i32: return value.?" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, value.kind.unwrap.kind.identifier.resolution.?);
}

test "resolveNamesInExpression: resolves the names in the operands of operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check(count: i32, ready: bool) -> bool: return -count < 0 and !ready" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const count = returned.kind.binary.left.kind.binary.left.kind.unary.operand.kind.identifier;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, count.resolution.?);
    const ready = returned.kind.binary.right.kind.unary.operand.kind.identifier;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 1 }, ready.resolution.?);
}

test "resolveLiteralType: resolves an alias of an array type before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Values = [3]i32\nfn make() -> Values: return Values{1, 2, 3}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(3, ast.extractType(value.kind.composite_literal.type.?.*).array.length);
}

test "resolveLiteralType: resolves a local alias of a tuple type before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const Pair = [i32, bool]\n    const pair = Pair{1, true}\n    _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[1].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type.boolean, ast.extractType(value.kind.composite_literal.type.?.*).tuple.elements[1]);
}

test "resolveLiteralType: resolves a struct name before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data: return Data{value = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const literal_type = returned.kind.composite_literal.type.?;
    try std.testing.expectEqualStrings("Data", ast.extractType(literal_type.*).@"struct".name);
}

test "resolveLiteralType: resolves a struct of another module before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "other.mn", .data = "struct Data:\n    value: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import other\nfn make() -> other::Data: return other::Data{value = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const struct_type = ast.extractType(returned.kind.composite_literal.type.?.*).@"struct";
    try std.testing.expectEqualStrings("Data", struct_type.name);
    try std.testing.expectEqual(1, struct_type.module);
}

test "resolveLiteralType: rejects a number type before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return i32{1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotLiteralType, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, name_resolver.failure.?.location.?);
}

test "resolveLiteralType: rejects a value before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make(values: [2]i32) -> [2]i32: return values{1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotLiteralType, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 43 }, name_resolver.failure.?.location.?);
}

test "resolveLiteralType: rejects an array of a function type before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const steps = [0]fn(){}\n    _ = steps" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.FunctionWithoutPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveArrayType: gives equal array types one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(left: [2]i32, right: [2]i32):\n    _ = left\n    _ = right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const left = ast.extractType(parameters[0].type).array;
    try std.testing.expectEqual(left, ast.extractType(parameters[1].type).array);
    try std.testing.expectEqual(2, left.length);
}

test "resolveArrayType: resolves an array type through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = [2]i32\nfn show(pair: Pair): _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(parameters[0].type).array.element);
}

test "resolveArrayType: accepts void elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [2]void): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).array.element);
}

test "resolveArrayType: rejects a length to infer without an array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [_]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolveArrayType: rejects a length to infer for the elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const grid: [2][_]i32 = {{1}, {2}}\n    _ = grid" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, name_resolver.failure.?.location.?);
}

test "expectLength: accepts a usize suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [3usize]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(3, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: takes the length from a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = 4usize\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(4, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: takes the length from a usize constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size: usize = 5\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(5, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: takes the length from a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const size = 2usize\n    const values: [size]i32 = {1, 2}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, ast.extractType(body[1].kind.constant_declaration.type.?).array.length);
}

test "expectLength: rejects a length that is not a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [true]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects a constant of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = 2i32\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects a constant with a written type other than usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size: u8 = 2\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: follows a constant that names another constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = other\nconst other = 2usize\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(2, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: rejects a constant that is not a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = true\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var size = 2usize\n    size = 3usize\n    var values: [size]i32 = undefined\n    values = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects a length with a suffix other than usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [2u8]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects a negative length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [-2]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NegativeUnsigned, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, analyzer.failure.?.location.?);
}
test "expectLength: computes a length from an operation on constants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZE = 2usize\nfn show(values: [SIZE * 3]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(6, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: computes a length from an element of a constant array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZES = [2]usize{3, 4}\nfn show(values: [SIZES[1]]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(4, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: computes a length from a field default of a constant struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Shape:\n    sides: usize = 4\nconst SQUARE = Shape{}\nfn show(values: [SQUARE.sides]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(4, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: rejects a length whose operation overflows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZE = 18446744073709551615usize\nfn show(values: [SIZE + 1]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.IntegerOverflow, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: computes a length from a call to a function declared later" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [size()]i32): _ = values\nfn size() -> usize: return 2 * 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(6, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: rejects a length that calls an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn size() -> usize\nfn show(values: [size()]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ExternalCall, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "resolveSliceType: resolves a slice type through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Bytes = []const u8\nfn show(bytes: Bytes): _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const slice = ast.extractType(parameters[0].type).slice;
    try std.testing.expect(slice.constant);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, slice.element);
}

test "resolveSliceType: accepts void elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: []void): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).slice.element);
}

test "resolveSlice: resolves the names in the bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []const i32, start: usize, end: usize) -> []const i32: return values[start..end]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 1 }, returned.kind.slice.start.?.kind.identifier.resolution.?);
    try std.testing.expectEqual(ast.Resolution{ .parameter = 2 }, returned.kind.slice.end.?.kind.identifier.resolution.?);
}

test "resolveSlice: counts a slice of a variable as an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    take(buffer[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "resolveSlice: counts a slice of a field of a variable as an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck:\n    cards: [2]i32\nfn take(cards: []i32): _ = cards\nfn main():\n    var deck: Deck = undefined\n    take(deck.cards[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "resolveSlice: counts a slice of an element of a variable as an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    var grid: [2][2]u8 = undefined\n    take(grid[0][..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolvePointerType: resolves the target, count and mutability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: *many const u8): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const pointer = ast.extractType(parameters[0].type).pointer;
    try std.testing.expect(pointer.many);
    try std.testing.expect(pointer.constant);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, pointer.target);
}

test "resolvePointerType: resolves a pointer type through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Bytes = *many u8\nfn show(bytes: Bytes): _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const pointer = ast.extractType(parameters[0].type).pointer;
    try std.testing.expect(pointer.many);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, pointer.target);
}

test "resolvePointerType: accepts a pointer to void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: *void): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).pointer.target);
}

test "resolvePointerType: rejects a read-only pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *const fn()): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstantFunctionPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, name_resolver.failure.?.location.?);
}

test "resolvePointerType: rejects a multiple value pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: *many fn()): _ = callbacks" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ManyFunctionPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolvePointerType: rejects a read-only pointer to an alias of a function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn()\nfn apply(callback: *const Callback): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstantFunctionPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, name_resolver.failure.?.location.?);
}

test "resolveOptionalType: gives an optional of an optional its own type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: ?i32, two: ??i32, three: ?i32):\n    _ = one\n    _ = two\n    _ = three" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type);
    const two = ast.extractType(parameters[1].type);
    try std.testing.expectEqual(one, ast.extractType(parameters[2].type));
    try std.testing.expectEqual(one, two.optional.child);
    try std.testing.expect(!std.meta.eql(one, two));
}

test "resolveOptionalType: resolves an optional type through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Maybe = ?bool\nfn show(value: Maybe): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.boolean, ast.extractType(parameters[0].type).optional.child);
}

test "resolveTupleType: gives tuples with the same elements in the same order one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: [i32, bool], two: [i32, bool], three: [bool, i32]):\n    _ = one\n    _ = two\n    _ = three" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type);
    try std.testing.expectEqual(one, ast.extractType(parameters[1].type));
    try std.testing.expect(!std.meta.eql(one, ast.extractType(parameters[2].type)));
    try std.testing.expectEqual(types.Type.boolean, one.tuple.elements[1]);
}

test "resolveTupleType: resolves a tuple type through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = [i32, [bool, u8]]\nfn show(pair: Pair): _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const tuple = ast.extractType(parameters[0].type).tuple;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, tuple.elements[1].tuple.elements[1]);
}

test "resolveFunctionType: gives equal signatures one type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: *fn(i32, bool) -> u8, two: *fn(i32, bool,) -> u8, three: *fn(i32, bool)):\n    _ = one\n    _ = two\n    _ = three" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type).pointer.target;
    try std.testing.expectEqual(one, ast.extractType(parameters[1].type).pointer.target);
    try std.testing.expect(!std.meta.eql(one, ast.extractType(parameters[2].type).pointer.target));
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[2].type).pointer.target.function.return_type);
}

test "resolveFunctionType: accepts a void parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(callback: *fn(void)): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).pointer.target.function.parameters[0]);
}

test "resolveIdentifier: lets a parameter shadow a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) -> i32:\n    _ = right\n    return left\nfn twice(add: i32) -> i32: return add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(0, value.kind.identifier.resolution.?.parameter);
}

test "resolveIdentifier: rejects an unknown value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32: return missing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, name_resolver.failure.?.location.?);
    try std.testing.expectEqualStrings("unknown name", name_resolver.failure.?.message);
}

test "resolveIdentifier: resolves a function to point to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two() -> *fn(): return &one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, value.kind.address_of.kind.identifier.resolution.?);
}

test "resolveValue: resolves a method to point to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn get() -> *fn(Point) -> f32: return &Point::length" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, value.kind.address_of.kind.path_expression.resolution.?);
}

test "resolveValue: resolves a method through a local alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn get() -> *fn(Point) -> f32:\n    const measure = Point::length\n    return &measure" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[1].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, value.kind.address_of.kind.identifier.resolution.?);
}

test "expectValue: rejects pointing to a function through a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn main():\n    const area = &Shape::area\n    _ = area" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TraitUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 8, .column = 19 }, name_resolver.failure.?.location.?);
}

test "expectValue: resolves an external function to point to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write()\nfn get() -> *fn(): return &write" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, value.kind.address_of.kind.identifier.resolution.?);
}

test "expectValue: rejects a pointer to main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop\nfn get() -> *fn(): return &main" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MainUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, name_resolver.failure.?.location.?);
}

test "expectValue: rejects main as an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop\nfn run(value: i32): _ = value\nfn get(): run(main)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MainUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, name_resolver.failure.?.location.?);
}

test "expectValue: rejects a module as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn value() -> i32: return utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 27 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: rejects an unknown call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): log(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: resolves a call of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(i32), value: i32): callback(value)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, call.callee.identifier.resolution.?);
}

test "resolveCallee: resolves a call of a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const limit = 5i32\n    limit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(ast.Resolution{ .local = &body[0] }, body[1].kind.call.kind.call.callee.identifier.resolution.?);
}

test "resolveCallee: resolves a call of a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(): noop\nconst step: *fn() = &first\nfn main(): step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 1 } }, call.callee.identifier.resolution.?);
}

test "resolveCallee: resolves a call of a constant of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "steps.mn", .data = "fn first(value: i32) -> i32: return value\nconst step: *fn(i32) -> i32 = &first" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import steps\nfn main(): _ = steps::step(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.discard.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 1, .declaration = 1 } }, call.callee.path_expression.resolution.?);
}

test "resolveCallee: rejects calling a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveCallee: calls a function through a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const write = add\nfn add(): noop\nfn main(): write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.callee.identifier.resolution.?.function;
    try std.testing.expectEqual(0, function.module);
    try std.testing.expectEqual(1, function.declaration);
}

test "findSelfFunction: rejects a function through Self that the trait does not have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn unit() -> Self\n    fn make() -> Self: return Self::other()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 31 }, name_resolver.failure.?.location.?);
}

test "expectCallee: rejects a struct as a callee" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data: return Data(value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 27 }, name_resolver.failure.?.location.?);
}

test "resolveName: resolves Self to the struct of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Self: return Card{}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.return_type).@"struct".name);
}

test "resolveName: resolves Self to the type of an implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nimpl Shape for []const u8:\n    fn area(self: Self) -> i32:\n        _ = self\n        return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[2].kind.function_definition.signature;
    try std.testing.expect(ast.extractType(signature.parameters[0].type).slice.constant);
}

test "resolveName: rejects Self outside a struct or an implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: Self): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolveName: accepts a pointer to Self in the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    next: ?*Self\nfn take(card: Card): _ = card" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const card = ast.extractType(loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type).@"struct";
    try std.testing.expect(std.meta.eql(card, card.fields[0].type.optional.child.pointer.target.@"struct"));
}

test "resolveName: rejects Self without a pointer in the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    next: Self\nfn take(card: Card): _ = card" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveName: prefers a declaration over a built-in type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct i32:\n    count: u8\nfn show(value: i32) -> i32: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("i32", ast.extractType(signature.return_type).@"struct".name);
}

test "resolveName: lets a top-level constant shadow a built-in type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const bool: i32 = 5\nfn get() -> i32: return bool" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 0 } }, value.kind.identifier.resolution.?);
}

test "resolveName: rejects a module that is not imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32: return utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, name_resolver.failure.?.location.?);
}

test "resolvePath: resolves a call through a trait to the trait's function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn main(): _ = Shape::area(Square{side = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    const method: ast.Resolution.TraitFunction = .{ .trait = .{ .module = 0, .declaration = 0 }, .function = 0 };
    try std.testing.expectEqual(ast.Resolution{ .trait_method = method }, callee.resolution.?);
}

test "resolvePath: rejects a function that the trait does not have through the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn main(): _ = Shape::size(Square{side = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolvePath: rejects a trait as the type of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nfn show(shape: Shape): _ = shape" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TraitUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolvePath: resolves a call through a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop\nfn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(1, function.declaration);
}

test "resolvePath: resolves a call through a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std\nfn main(): std::stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolvePath: resolves a call through an imported module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std::stdout\nfn main(): stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "findPathOwner: resolves a function through Self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Self: return Card{}\n    fn copy(self: Self) -> Self:\n        _ = self\n        return Self::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const callee = body[1].kind.@"return".?.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, callee.resolution.?);
}

test "findPathOwner: prefers a declaration over a built-in type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct i32:\n    fn new() -> Self: return i32{}\nfn main(): _ = i32::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, callee.resolution.?);
}

test "resolveFirstNamespace: rejects members of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(value: i32): value::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: lets a parameter shadow an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop\nfn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn run(utils: i32): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: lets a local constant shadow an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one(): noop\nfn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main():\n    const utils = 5i32\n    utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: rejects a module that is not imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
    try std.testing.expectEqual(1, loader.modules.items.len);
}

test "resolveFirstNamespace: rejects the standard library when it is not imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: rejects members of an imported function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils::add\nfn main(): add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects members of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects a module missing from a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std\nfn main(): std::missing::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleNotFound, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects an import of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main(): shapes::utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ImportNotMember, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: reaches a declaration of a module and a module in its directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "shapes");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main():\n    shapes::draw()\n    shapes::circle::area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const function = body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"shapes"}), loader.modules.items[function.module].path);
    const module_function = body[1].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "shapes", "circle" }), loader.modules.items[module_function.module].path);
}

test "resolveMember: rejects a call that ends at a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils/math");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::math()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: rejects a name the module does not declare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::missing()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: rejects an import of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils::add" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main(): shapes::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ImportNotMember, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveImport: binds the name of the imported trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const implementation = loader.modules.items[0].declarations[2].kind.implementation;
    const trait_module = loader.modules.items[implementation.resolved.?.module];
    try std.testing.expectEqualStrings("shapes", trait_module.path[0]);
}

test "resolveImport: rejects an import with the name of another declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\ntrait Shape" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateTrait, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveImport: binds a constant of a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "cards.mn", .data = "const cards: i32 = 52" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import cards::cards\nfn count() -> i32: return cards" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 1, .declaration = 0 } }, value.kind.identifier.resolution.?);
}

test "resolveImport: binds a function, an external function and a struct of a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop\nexternal fn write()\nstruct Point:\n    x: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils::add\nimport utils::write\nimport utils::Point\nfn run(point: Point):\n    add()\n    write()\n    _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[3].kind.function_definition;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 1, .declaration = 0 } }, function.body[0].kind.call.kind.call.callee.identifier.resolution.?);
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 1, .declaration = 1 } }, function.body[1].kind.call.kind.call.callee.identifier.resolution.?);
    try std.testing.expectEqual(1, ast.extractType(function.signature.parameters[0].type).@"struct".module);
}

test "resolveImport: binds the name after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std/io");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/io/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std::io::stdout as out\nfn main(): out::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "std", "io", "stdout" }), loader.modules.items[function.module].path);
}

test "resolveImport: leaves the last name of the path unbound after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils as tools\nfn main(): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveImport: binds a name in the whole module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add()\nimport utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
}

test "resolveImport: rejects a root that is neither a module nor a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop\nimport missing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleNotFound, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveImport: rejects an import of an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils::add" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ImportNotMember, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: rejects constants that refer to each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one = two\nconst two = one\nfn main(): one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstantRefersToItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: leaves constants that nothing uses alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one = two\nconst two = one\nconst missing = nothing::here" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(1, loader.modules.items.len);
}

test "resolveConstant: reports errors in the value at the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "output.mn", .data = "import std\nconst write = std::missing" });
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import output\nfn main(): output::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: resolves a constant that names a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Integer = i32\nfn add(value: Integer): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameter_type = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type;
    try std.testing.expectEqual(ast.Resolution{ .type = .{ .number = .i32 } }, parameter_type.kind.identifier.resolution.?);
}

test "resolveConstant: resolves a constant that holds a literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return limit\nconst limit = other\nconst other = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 2 } }, value.kind.identifier.resolution.?);
}

test "resolveConstant: accepts a pointer to a function as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst step = &one\nfn main(): step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 1 } }, call.callee.identifier.resolution.?);
}

test "resolveConstant: resolves a constant that constructs a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst origin = Point{x = 0}\nfn make() -> Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 1 } }, returned.kind.identifier.resolution.?);
}

test "resolveConstant: rejects a written type that is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: 5i32 = 5\nfn show() -> i32: return limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: resolves a pointer to a function with a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst run: *fn() = &one\nfn get() -> *fn(): return run" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const constant = loader.modules.items[0].declarations[1].kind.constant_declaration;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, constant.value.kind.address_of.kind.identifier.resolution.?);
    try std.testing.expect(ast.extractType(constant.type.?).pointer.target == .function);
}

test "expectHeldByConstant: rejects a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "std");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import std\nconst stdout = std::stdout\nfn main(): stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleInConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "expectHeldByConstant: rejects a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nconst tools = utils\nfn main(): tools::math::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleInConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "expectHeldByConstant: keeps a function of an imported module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nconst plus = utils::add\nfn main(): plus()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const callee = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.callee;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 1, .declaration = 0 } }, callee.identifier.resolution.?);
}

test "resolveStruct: resolves a struct used as a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show(point: Point): _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameter_type = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type;
    const point = parameter_type.kind.identifier.resolution.?.type.@"struct";
    try std.testing.expectEqualStrings("Point", point.name);
    try std.testing.expectEqual(0, point.module);
}

test "resolveStruct: rejects a struct that contains itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node:\n    next: Node\nfn show(node: Node): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveStruct: rejects structs that contain each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One:\n    two: Two\nstruct Two:\n    one: One\nfn show(one: One): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveStruct: accepts a pointer to the struct itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node:\n    next: ?*Node\nfn take(node: Node): _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const node = ast.extractType(loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type).@"struct";
    try std.testing.expect(std.meta.eql(node, node.fields[0].type.optional.child.pointer.target.@"struct"));
}

test "resolveStruct: gives every use of a struct the same type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst Other = Point\nfn show(point: Point, other: Other):\n    _ = point\n    _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(1, type_registry.entries.items.len);
    try std.testing.expectEqual(ast.extractType(parameters[0].type), ast.extractType(parameters[1].type));
}

test "resolveStruct: gives structs with the same fields different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One:\n    x: i32\nstruct Two:\n    x: i32\nfn show(one: One, two: Two):\n    _ = one\n    _ = two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expect(!std.meta.eql(ast.extractType(parameters[0].type), ast.extractType(parameters[1].type)));
}

test "resolveFields: resolves the types of the fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Line:\n    start: Point\n    width: i32\nstruct Point:\n    x: i32\nfn show(line: Line): _ = line" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameter_type = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters[0].type;
    const line = ast.extractType(parameter_type).@"struct";
    try std.testing.expectEqualStrings("start", line.fields[0].name);
    try std.testing.expectEqualStrings("Point", line.fields[0].type.@"struct".name);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, line.fields[1].type);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, line.fields[1].location);
}

test "resolveFields: leaves structs that nothing uses alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: missing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(0, type_registry.entries.items.len);
}

test "resolveFields: rejects a field type that is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: 5\nfn show(point: Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeMismatch, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, name_resolver.failure.?.location.?);
}

test "resolveFields: accepts a void field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: void\nfn show(point: Point): _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).@"struct".fields[0].type);
}

test "resolveFields: reports errors in the module of the struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: Missing" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(point: shapes::Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, name_resolver.failure.?.location.?);
}

test "resolveFields: rejects a duplicate field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    x: i32\nfn show(point: Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveFields: rejects a reserved field name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    mn_x: i32\nfn show(point: Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveFields: resolves the defaults of fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const width = 5i32\nstruct Box:\n    size: i32 = width\nfn show(box: Box): _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const default = type_registry.entries.items[0].@"struct".fields[0].default.?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 0 } }, default.kind.identifier.resolution.?);
}

test "loadRoot: reports the reserved name monolith at the import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "monolith.mn", .data = "fn one(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import monolith\nfn main(): monolith::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedModuleName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "failLoading: reports failures in the module that is loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one():\n\tnoop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnexpectedTab, name_resolver.resolve());
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}
