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

const isLanguageModule = @import("loader.zig").isLanguageModule;

const keywords = @import("name.zig").keywords;

pub const NameResolver = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    loader: *Loader,
    types: *types.Registry,
    module_index: usize = 0,
    constant_depth: usize = 0,
    self_type: ?types.Type = null,
    self_name: []const u8 = "Self",
    typeclass: ?ast.Resolution.Typeclass = null,
    bindings: []const ast.Binding = &.{},
    owner_name: []const u8 = "",
    signature_typeclass: ?ast.Resolution.Typeclass = null,
    signature_definition: ?*const ast.FunctionDefinition = null,
    constraints: []const ast.Constraint = &.{},
    dropped_names: []const []const u8 = &.{},
    structs: std.ArrayList(StructCount) = .empty,
    instantiated: std.ArrayList(Instantiated) = .empty,
    type_checker: ?*TypeChecker = null,
    pending: std.ArrayList(PendingMethod) = .empty,
    resolved_branchings: std.AutoHashMapUnmanaged(*const ast.Statement, void) = .empty,
    preparing: bool = false,
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
        try self.expectSingleInstances();
    }

    fn resolveModule(self: *NameResolver) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        for (module.declarations, 0..) |declaration, index| {
            if (isMethod(declaration)) {
                if (declaration.kind.function_definition.signature.typeclass == null) {
                    try self.resolveFunction(self.module_index, index);
                }
                continue;
            }
            switch (declaration.kind) {
                .instance_declaration => {
                    try self.resolveInstance(index);
                    continue;
                },
                .function_definition,
                .function_declaration,
                .constant_declaration,
                .struct_definition,
                .enum_definition,
                .typeclass_definition,
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
                    .enum_definition => error.DuplicateEnum,
                    .typeclass_definition => error.DuplicateTypeclass,
                    .import => error.DuplicateImport,
                    .instance_declaration => unreachable,
                });
            }
            if (isReservedDeclarationName(module.path, declaration.kind, name)) return self.fail(location, error.ReservedName);
            if (declaration.kind == .import and isKeywordName(name)) return self.fail(location, error.ReservedImport);
            if (declaration.kind != .import and try self.hasMember(module.path, name)) {
                return self.fail(location, error.NamedLikeModule);
            }
            switch (declaration.kind) {
                .function_definition => try self.resolveFunction(self.module_index, index),
                .function_declaration => try self.resolveExternalSignature(self.module_index, index),
                .typeclass_definition => {
                    const module_index = self.module_index;
                    try self.resolveTypeclass(.{ .module = module_index, .declaration = index });
                },
                .import => _ = try self.resolveImport(self.module_index, index),
                .constant_declaration => |constant| {
                    if (constant.type == null and ast.isAlias(constant)) continue;
                    _ = try self.resolveConstant(self.module_index, index);
                },
                .enum_definition => _ = try self.resolveEnum(self.module_index, index),
                .struct_definition, .instance_declaration => {},
            }
        }
    }

    fn resolveTypeclass(self: *NameResolver, typeclass: ast.Resolution.Typeclass) ResolveError!void {
        const module = self.loader.modules.items[typeclass.module];
        const declaration = module.declarations[typeclass.declaration];
        const definition = &module.declarations[typeclass.declaration].kind.typeclass_definition;
        if (definition.resolved) return;
        definition.resolved = true;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        self.module_index = typeclass.module;
        self.self_type = null;
        self.typeclass = typeclass;
        self.bindings = try self.buildTypeclassBindings(definition.*, declaration.location);
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        for (definition.parameters) |*parameter| {
            const requirement = if (parameter.requirement) |*requirement| requirement else continue;
            parameter.resolved_requirement = try self.expectOneParameterTypeclass(requirement);
        }
        const functions = definition.functions;
        const typeclass_bindings = self.bindings;
        for (functions, 0..) |*signature, function_index| {
            if (findSignature(functions[0..function_index], signature.name) != null) {
                return self.fail(declaration.location, error.DuplicateFunction);
            }
            self.bindings = try self.addOwnTypeBindings(typeclass_bindings, signature.*);
            self.signature_typeclass = typeclass;
            defer self.signature_typeclass = null;
            try self.resolveFunctionTypes(signature);
        }
        self.bindings = typeclass_bindings;
        for (functions, definition.defaults) |signature, default| {
            const written = default orelse continue;
            if (ast.isGeneric(signature)) continue;
            try self.resolveNamesInFunction(.{ .signature = signature, .body = written.body });
        }
    }

    fn addOwnTypeBindings(
        self: *NameResolver,
        typeclass_bindings: []const ast.Binding,
        signature: ast.FunctionSignature,
    ) ResolveError![]const ast.Binding {
        if (!ast.isGeneric(signature)) return typeclass_bindings;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        const allocator = self.arena.allocator();
        try bindings.appendSlice(allocator, typeclass_bindings);
        for (signature.parameters, 0..) |parameter, index| {
            switch (parameter.kind) {
                .run_time => {},
                .type => {
                    const variable: types.Variable = .{ .scope = .function, .index = index };
                    try bindings.append(allocator, .{ .name = parameter.name, .target = .{ .type = .{ .variable = variable } } });
                },
                .compile_time => return self.fail(parameter.location, error.CompileTimeTypeclassParameter),
                .implicit, .any => {},
            }
        }
        for (signature.declared, 0..) |declared, position| {
            const variable: types.Variable = .{ .scope = .function, .index = signature.parameters.len + position };
            try bindings.append(allocator, .{ .name = declared.name, .target = .{ .type = .{ .variable = variable } } });
        }
        return bindings.items;
    }

    fn buildTypeclassBindings(
        self: *NameResolver,
        definition: ast.TypeclassDefinition,
        location: token.Location,
    ) ResolveError![]const ast.Binding {
        const allocator = self.arena.allocator();
        const bindings = try allocator.alloc(ast.Binding, definition.parameters.len);
        for (definition.parameters, bindings, 0..) |parameter, *binding, index| {
            for (definition.parameters[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, parameter.name)) return self.fail(location, error.DuplicateParameter);
            }
            const variable: types.Variable = .{ .scope = .typeclass, .index = index };
            binding.* = .{ .name = parameter.name, .target = if (parameter.arity == 0)
                .{ .type = .{ .variable = variable } }
            else
                .{ .constructor = .{ .variable = variable } } };
        }
        return bindings;
    }

    fn loadImportedModules(self: *NameResolver) ResolveError!void {
        _ = try self.loadRoot("mn");
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            self.module_index = module_index;
            const module = self.loader.modules.items[module_index];
            for (module.declarations) |declaration| {
                if (declaration.kind != .import) continue;
                const path = declaration.kind.import.path;
                var namespace = (try self.loadRoot(path[0])) orelse continue;
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
                if (declaration.kind != .instance_declaration) continue;
                const instance_declaration = &declaration.kind.instance_declaration;
                instance_declaration.resolved = try self.expectTypeclass(&instance_declaration.typeclass);
            }
            var declarations: std.ArrayList(ast.Declaration) = .empty;
            try declarations.appendSlice(allocator, original);
            for (original, 0..) |declaration, index| {
                if (declaration.kind != .instance_declaration) continue;
                const instance_declaration = declaration.kind.instance_declaration;
                const typeclass = instance_declaration.resolved.?;
                const required = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
                const definition = required.kind.typeclass_definition;
                const first = index + 1;
                const written = original[first .. first + instance_declaration.functions];
                const reference: ast.InstanceReference = .{ .module = module_index, .declaration = index };
                const pattern = instance_declaration.parameters.len > 0;
                for (declarations.items[first .. first + instance_declaration.functions]) |*function| {
                    const written_function = &function.kind.function_definition;
                    written_function.instance = reference;
                    written_function.pattern = pattern;
                    const expected = findSignature(definition.functions, written_function.signature.name) orelse continue;
                    written_function.signature.self_parameter = expected.self_parameter;
                }
                var defaults: std.ArrayList(usize) = .empty;
                for (definition.functions, definition.defaults) |signature, default| {
                    const template = (default orelse continue).template;
                    if (findDefinition(written, signature.name) != null) continue;
                    var function = try ast.cloneFunctionDefinition(allocator, template);
                    function.signature.typeclass = instance_declaration.typeclass;
                    function.default_of = typeclass;
                    function.instance = reference;
                    function.pattern = pattern;
                    try defaults.append(allocator, declarations.items.len);
                    const kind: ast.DeclarationKind = .{ .function_definition = function };
                    try declarations.append(allocator, .{ .kind = kind, .location = declaration.location });
                }
                declarations.items[index].kind.instance_declaration.defaults = defaults.items;
            }
            self.loader.modules.items[module_index].declarations = declarations.items;
        }
    }

    fn resolveInstanceArguments(self: *NameResolver, module_index: usize, index: usize) ResolveError!void {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const instance_declaration = &declaration.kind.instance_declaration;
        if (instance_declaration.progress != .pending) return;
        instance_declaration.progress = .running;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = try self.buildInstanceBindings(instance_declaration);
        const typeclass = instance_declaration.resolved.?;
        const definition = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
        if (instance_declaration.arguments.len != definition.parameters.len) {
            return self.fail(declaration.location, error.TypeclassArgumentCount);
        }
        const allocator = self.arena.allocator();
        const arguments = try allocator.alloc(types.Argument, definition.parameters.len);
        for (definition.parameters, instance_declaration.arguments, arguments) |parameter, *argument, *resolved| {
            try self.resolveNamesInExpression(.{}, argument);
            resolved.* = try self.expectArgument(parameter, argument);
        }
        instance_declaration.resolved_arguments = arguments;
        instance_declaration.progress = .done;
    }

    fn buildInstanceBindings(self: *NameResolver, instance_declaration: *ast.InstanceDeclaration) ResolveError![]const ast.Binding {
        const allocator = self.arena.allocator();
        const bindings = try allocator.alloc(ast.Binding, instance_declaration.parameters.len);
        for (instance_declaration.parameters, bindings, 0..) |*parameter, *binding, index| {
            for (instance_declaration.parameters[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, parameter.name)) return self.fail(parameter.location, error.DuplicateParameter);
            }
            if (parameter.requirement) |*requirement| {
                if (parameter.resolved_requirement == null) parameter.resolved_requirement = try self.expectTypeclass(requirement);
            }
            const variable: types.Variable = .{ .scope = .instance, .index = index };
            binding.* = .{ .name = parameter.name, .target = .{ .type = .{ .variable = variable } } };
        }
        return bindings;
    }

    fn expectArgument(
        self: *NameResolver,
        parameter: ast.TypeclassParameter,
        argument: *ast.Expression,
    ) ResolveError!types.Argument {
        if (parameter.arity == 0) return .{ .type = try self.expectType(argument) };
        if (argument.kind == .identifier and argument.kind.identifier.resolution == null) {
            const constructor = self.findConstructorBinding(argument.kind.identifier.name) orelse {
                return self.fail(argument.location, error.ConstructorMismatch);
            };
            return .{ .constructor = constructor };
        }
        const resolution = switch (argument.kind) {
            inline .identifier, .path_expression => |name| name.resolution,
            else => null,
        };
        const function = (resolution orelse return self.fail(argument.location, error.ConstructorMismatch));
        if (function != .function) return self.fail(argument.location, error.ConstructorMismatch);
        const module = self.loader.modules.items[function.function.module];
        const signature = ast.findDeclaration(module, function.function.declaration).kind.function_definition.signature;
        if (signature.parameters.len != parameter.arity) return self.fail(argument.location, error.ConstructorMismatch);
        for (signature.parameters) |typed_name| {
            if (typed_name.kind != .type) return self.fail(argument.location, error.ConstructorMismatch);
        }
        return .{ .constructor = .{ .function = function.function } };
    }

    fn resolveAllTypeclasses(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            for (self.loader.modules.items[module_index].declarations, 0..) |declaration, index| {
                if (declaration.kind != .typeclass_definition) continue;
                try self.resolveTypeclass(.{ .module = module_index, .declaration = index });
            }
        }
    }

    fn resolveAllInstanceArguments(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            for (self.loader.modules.items[module_index].declarations, 0..) |declaration, index| {
                if (declaration.kind != .instance_declaration) continue;
                try self.resolveInstanceArguments(module_index, index);
            }
        }
    }

    fn resolveInstance(self: *NameResolver, index: usize) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const declaration = module.declarations[index];
        const instance_declaration = &module.declarations[index].kind.instance_declaration;
        const typeclass = try self.expectTypeclass(&instance_declaration.typeclass);
        if (ast.isTupleTypeclass(self.loader.modules.items, typeclass)) {
            return self.fail(declaration.location, error.TupleInstance);
        }
        instance_declaration.resolved = typeclass;
        try self.resolveTypeclass(typeclass);
        try self.resolveInstanceArguments(self.module_index, index);
        const instance_arguments = instance_declaration.resolved_arguments;
        const required = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
        const signatures = required.kind.typeclass_definition.functions;
        const first = index + 1;
        const functions = module.declarations[first .. first + instance_declaration.functions];
        for (functions, first..) |function, function_index| {
            const signature = function.kind.function_definition.signature;
            for (functions[0 .. function_index - first]) |earlier| {
                const earlier_name = earlier.kind.function_definition.signature.name;
                if (std.mem.eql(u8, earlier_name, signature.name)) {
                    return self.fail(function.location, error.DuplicateFunction);
                }
            }
            const expected = findSignature(signatures, signature.name) orelse {
                return self.fail(function.location, error.NotInTypeclass);
            };
            try self.resolveFunction(self.module_index, function_index);
            const resolved = try self.resolveTemplateSignature(self.module_index, function_index);
            const reference: ast.InstanceReference = .{ .module = self.module_index, .declaration = index };
            const reduced = if (instance_declaration.parameters.len == 0)
                try self.reduceSignature(function.location, expected, reference)
            else
                expected;
            if (!try matchesSignature(self.arena.allocator(), resolved, reduced, instance_arguments)) {
                return self.fail(function.location, error.MismatchedTypeclassFunction);
            }
        }
        for (signatures, required.kind.typeclass_definition.defaults) |expected, default| {
            if (default != null or findDefinition(functions, expected.name) != null) continue;
            return self.fail(declaration.location, error.MissingTypeclassFunction);
        }
        try self.expectRequiredInstances(declaration.location, required.kind.typeclass_definition, instance_arguments);
        for (instance_declaration.defaults) |default_index| try self.resolveFunction(self.module_index, default_index);
    }

    fn reduceSignature(
        self: *NameResolver,
        location: token.Location,
        signature: ast.FunctionSignature,
        reference: ast.InstanceReference,
    ) ResolveError!ast.FunctionSignature {
        const allocator = self.arena.allocator();
        var reduced = signature;
        reduced.parameters = try allocator.dupe(ast.TypedName, signature.parameters);
        for (reduced.parameters) |*parameter| {
            parameter.type = try self.buildDenoted(location, parameter.type, reference);
        }
        reduced.return_type = try self.buildDenoted(location, signature.return_type, reference);
        return reduced;
    }

    fn buildDenoted(
        self: *NameResolver,
        location: token.Location,
        expression: ast.Expression,
        reference: ast.InstanceReference,
    ) ResolveError!ast.Expression {
        var denoted = expression;
        denoted.denoted = try self.reduceType(location, ast.extractType(expression), reference);
        return denoted;
    }

    fn reduceType(
        self: *NameResolver,
        location: token.Location,
        value_type: types.Type,
        reference: ast.InstanceReference,
    ) ResolveError!types.Type {
        const allocator = self.arena.allocator();
        return switch (value_type) {
            .application => |application| {
                if (application.constructor != .typeclass_function) return value_type;
                const function = application.constructor.typeclass_function;
                const modules = self.loader.modules.items;
                const definition = modules[function.typeclass.module].declarations[function.typeclass.declaration].kind.typeclass_definition;
                const name = definition.functions[function.function].name;
                const member = ast.findInstanceMember(modules, reference, name) orelse {
                    return self.fail(location, error.MissingTypeclassFunction);
                };
                var call: ast.Expression = .{
                    .kind = .{ .call = .{ .callee = .{ .identifier = .{ .name = name, .resolution = .{ .function = member } } }, .arguments = &.{} } },
                    .location = location,
                };
                return self.evaluateType(&call);
            },
            .optional => |optional| .{ .optional = try self.types.addOptional(allocator, try self.reduceType(location, optional.child, reference)) },
            .pointer => |pointer| .{ .pointer = try self.types.addPointer(allocator, .{
                .target = try self.reduceType(location, pointer.target, reference),
                .many = pointer.many,
                .constant = pointer.constant,
            }) },
            .slice => |slice| .{ .slice = try self.types.addSlice(allocator, try self.reduceType(location, slice.element, reference), slice.constant) },
            else => value_type,
        };
    }

    fn resolveTemplateSignature(self: *NameResolver, module_index: usize, index: usize) ResolveError!ast.FunctionSignature {
        const definition = self.loader.modules.items[module_index].declarations[index].kind.function_definition;
        if (!ast.isGeneric(definition.signature)) return definition.signature;
        const allocator = self.arena.allocator();
        var signature = (try ast.cloneFunctionDefinition(allocator, definition)).signature;
        const caller_module_index = self.module_index;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.bindings = try self.addOwnTypeBindings(definition.bindings, signature);
        try self.resolveFunctionTypes(&signature);
        return signature;
    }

    fn expectRequiredInstances(
        self: *NameResolver,
        location: token.Location,
        definition: ast.TypeclassDefinition,
        arguments: []const types.Argument,
    ) ResolveError!void {
        try self.resolveAllInstanceArguments();
        for (definition.parameters, arguments) |parameter, argument| {
            const requirement = parameter.resolved_requirement orelse continue;
            if (argument != .type or types.containsVariable(argument.type, .instance)) continue;
            const decided: []const ?types.Argument = &.{argument};
            switch (try ast.findInstance(self.arena.allocator(), self.loader.modules.items, requirement, decided)) {
                .missing, .missing_requirement => return self.fail(location, error.MissingRequiredInstance),
                .found, .ambiguous, .undecided => {},
            }
        }
    }

    fn expectTypeclass(
        self: *NameResolver,
        expression: *ast.Expression,
    ) ResolveError!ast.Resolution.Typeclass {
        const location = expression.location;
        const target = switch (expression.kind) {
            .identifier => |identifier| try self.resolveName(location, identifier.name),
            .path_expression => |path_expression| target: {
                const path = path_expression.path;
                break :target try self.resolvePath(.{}, location, path);
            },
            else => return self.fail(location, error.NotATypeclass),
        };
        if (target != .typeclass) return self.fail(location, error.NotATypeclass);
        return target.typeclass;
    }

    fn expectSingleInstances(self: *NameResolver) ResolveError!void {
        for (self.loader.modules.items, 0..) |module, module_index| {
            for (module.declarations, 0..) |declaration, index| {
                if (declaration.kind != .instance_declaration) continue;
                const instance_declaration = declaration.kind.instance_declaration;
                if (try self.findEarlierInstance(module_index, index, instance_declaration)) {
                    self.module_index = module_index;
                    return self.fail(declaration.location, error.DuplicateInstance);
                }
            }
        }
    }

    fn findEarlierInstance(
        self: *NameResolver,
        module_index: usize,
        index: usize,
        instance_declaration: ast.InstanceDeclaration,
    ) std.mem.Allocator.Error!bool {
        const allocator = self.arena.allocator();
        for (self.loader.modules.items[0 .. module_index + 1], 0..) |module, earlier_module| {
            const end = if (earlier_module == module_index) index else module.declarations.len;
            for (module.declarations[0..end]) |declaration| {
                if (declaration.kind != .instance_declaration) continue;
                const earlier = declaration.kind.instance_declaration;
                if (!std.meta.eql(earlier.resolved, instance_declaration.resolved)) continue;
                const sides: types.Sides = .{
                    .one = try allocator.alloc(?types.Unified, earlier.parameters.len),
                    .two = try allocator.alloc(?types.Unified, instance_declaration.parameters.len),
                };
                @memset(sides.one, null);
                @memset(sides.two, null);
                if (types.unifyArguments(earlier.resolved_arguments, instance_declaration.resolved_arguments, sides)) return true;
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
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.self_name = "Self";
        self.typeclass = null;
        self.bindings = definition.bindings;
        const caller_owner_name = self.owner_name;
        defer self.owner_name = caller_owner_name;
        self.owner_name = self.findOwnerName(definition.*);
        if (definition.instance) |reference| {
            if (definition.template == null) try self.prepareInstanceFunction(definition, reference);
            self.bindings = definition.bindings;
            self.self_name = "";
        }
        if (definition.default_of) |typeclass| {
            self.module_index = typeclass.module;
            self.typeclass = typeclass;
        } else if (signature.receiver) |*receiver| {
            if (!isStandardLibrary(module.path) and hasReservedPrefix(signature.name)) {
                return self.fail(declaration.location, error.ReservedName);
            }
            try self.resolveNamesInExpression(.{}, receiver);
            const receiver_type = try self.expectType(receiver);
            self.self_type = receiver_type;
            const unique = signature.typeclass == null and index < module.declarations.len;
            if (unique) try self.expectUniqueMethod(module_index, index, receiver_type);
        }
        try self.resolveConstraints(signature);
        try self.resolveDeclaredTypes(signature);
        const caller_signature_definition = self.signature_definition;
        defer self.signature_definition = caller_signature_definition;
        self.signature_definition = if (definition.instance != null) definition else null;
        if (!ast.isGeneric(signature.*)) try self.resolveFunctionTypes(signature);
        signature.progress = .done;
    }

    fn prepareInstanceFunction(
        self: *NameResolver,
        definition: *ast.FunctionDefinition,
        reference: ast.InstanceReference,
    ) ResolveError!void {
        try self.resolveInstanceArguments(reference.module, reference.declaration);
        const declaration = &self.loader.modules.items[reference.module].declarations[reference.declaration];
        const instance_declaration = &declaration.kind.instance_declaration;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        const allocator = self.arena.allocator();
        try bindings.appendSlice(allocator, try self.buildInstanceBindings(instance_declaration));
        if (definition.default_of) |typeclass| {
            const typeclass_declaration = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
            const parameters = typeclass_declaration.kind.typeclass_definition.parameters;
            for (parameters, instance_declaration.resolved_arguments) |parameter, argument| {
                try bindings.append(allocator, .{ .name = parameter.name, .target = switch (argument) {
                    .type => |value_type| .{ .type = value_type },
                    .constructor => |constructor| .{ .constructor = constructor },
                } });
            }
        }
        definition.bindings = bindings.items;
        if (!definition.pattern) definition.instance_arguments = instance_declaration.resolved_arguments;
    }

    fn resolveDeclaredTypes(self: *NameResolver, signature: *ast.FunctionSignature) ResolveError!void {
        const allocator = self.arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        for (signature.parameters) |parameter| {
            if (parameter.kind == .run_time) try collectExpressionNames(allocator, &names, parameter.type);
        }
        for (signature.declared) |*declared| {
            if (!containsName(names.items, declared.name)) return self.fail(declared.location, error.UnusedDeclaredType);
            const requirement = if (declared.requirement) |*requirement| requirement else continue;
            declared.resolved_requirement = try self.expectOneParameterTypeclass(requirement);
        }
    }

    fn resolveConstraints(self: *NameResolver, signature: *ast.FunctionSignature) ResolveError!void {
        for (signature.parameters) |*parameter| {
            switch (parameter.kind) {
                .type => {
                    const requirement = if (parameter.requirement) |*requirement| requirement else continue;
                    parameter.constraint = try self.expectOneParameterTypeclass(requirement);
                },
                .run_time => {
                    if (parameter.type.denoted != null) continue;
                    const written: *ast.Expression = written: {
                        if (parameter.type.kind != .pointer_type) break :written &parameter.type;
                        const pointer_type = parameter.type.kind.pointer_type;
                        if (pointer_type.many) continue;
                        break :written pointer_type.target;
                    };
                    const target = switch (written.kind) {
                        .identifier => |identifier| target: {
                            if (findBinding(self.bindings, identifier.name) != null) continue;
                            const module = self.loader.modules.items[self.module_index];
                            const index = findDeclaration(module, identifier.name) orelse continue;
                            break :target try self.resolveDeclaration(self.module_index, index);
                        },
                        .path_expression => |path_expression| try self.resolvePath(.{}, written.location, path_expression.path),
                        else => continue,
                    };
                    if (target != .typeclass) continue;
                    parameter.constraint = try self.expectOneParameterTypeclass(written);
                    parameter.kind = .implicit;
                },
                .compile_time, .implicit, .any => {},
            }
        }
    }

    fn expectOneParameterTypeclass(self: *NameResolver, expression: *ast.Expression) ResolveError!ast.Resolution.Typeclass {
        const typeclass = try self.expectTypeclass(expression);
        const declaration = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
        if (declaration.kind.typeclass_definition.parameters.len != 1) {
            return self.fail(expression.location, error.TypeclassArgumentCount);
        }
        return typeclass;
    }

    fn resolveMemberFunction(self: *NameResolver, scope: Scope, location: token.Location, member: *ast.Member) ResolveError!?ast.Resolution {
        if (try self.findNamedInstance(scope, member.owner)) |named| {
            const resolution = try self.resolveInstanceFunction(location, named, member.name);
            if (resolution == .typeclass_function) member.typeclass_arguments = named.arguments;
            return resolution;
        }
        try self.resolveNamesInExpression(scope, member.owner);
        const receiver = try self.expectType(member.owner);
        const function = ast.findOwnMethod(self.loader.modules.items, receiver, member.name) orelse {
            return self.fail(location, error.UnknownMethod);
        };
        return .{ .function = function };
    }

    fn findNamedInstance(self: *NameResolver, scope: Scope, owner: *ast.Expression) ResolveError!?NamedInstance {
        if (owner.kind != .call) return null;
        const call = owner.kind.call;
        const target = switch (call.callee) {
            .identifier => |identifier| try self.resolveName(owner.location, identifier.name),
            .path_expression => |path_expression| try self.resolvePath(scope, owner.location, path_expression.path),
            .member => return null,
        };
        if (target != .typeclass) return null;
        const typeclass = target.typeclass;
        const definition = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
        if (call.arguments.len != definition.parameters.len) return self.fail(owner.location, error.TypeclassArgumentCount);
        const arguments = try self.arena.allocator().alloc(types.Argument, definition.parameters.len);
        for (definition.parameters, call.arguments, arguments) |parameter, *argument, *resolved| {
            try self.resolveNamesInExpression(scope, &argument.value);
            resolved.* = try self.expectArgument(parameter, &argument.value);
        }
        return .{ .typeclass = typeclass, .arguments = arguments };
    }

    fn resolveInstanceFunction(
        self: *NameResolver,
        location: token.Location,
        named: NamedInstance,
        name: []const u8,
    ) ResolveError!ast.Resolution {
        const modules = self.loader.modules.items;
        const typeclass = named.typeclass;
        const definition = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
        const position = findSignaturePosition(definition.functions, name) orelse {
            return self.fail(location, error.UnknownMethod);
        };
        if (isOwnParameters(named.arguments)) {
            const current = self.typeclass orelse return self.fail(location, error.NoInstance);
            if (!std.meta.eql(current, typeclass)) return self.fail(location, error.NoInstance);
            return .{ .typeclass_function = .{ .typeclass = typeclass, .function = position } };
        }
        if (containsFunctionVariable(named.arguments)) {
            for (self.constraints) |constraint| {
                if (!std.meta.eql(constraint.typeclass, typeclass)) continue;
                if (!isSameArguments(constraint.arguments, named.arguments)) continue;
                return .{ .typeclass_function = .{ .typeclass = typeclass, .function = position } };
            }
            return self.fail(location, error.NoInstance);
        }
        const decided = try self.arena.allocator().alloc(?types.Argument, named.arguments.len);
        for (named.arguments, decided) |argument, *slot| slot.* = argument;
        const function = (try self.findInstanceFunction(self.module_index, location, typeclass, decided, name)) orelse {
            return self.fail(location, error.NoInstance);
        };
        return .{ .function = function };
    }

    fn findInstanceFunction(
        self: *NameResolver,
        module_index: usize,
        location: token.Location,
        typeclass: ast.Resolution.Typeclass,
        decided: []const ?types.Argument,
        name: []const u8,
    ) ResolveError!?ast.Resolution.Function {
        try self.resolveAllInstanceArguments();
        const modules = self.loader.modules.items;
        const found = switch (try ast.findInstance(self.arena.allocator(), modules, typeclass, decided)) {
            .missing => return null,
            .missing_requirement => return self.failIn(module_index, location, error.MissingRequiredInstance),
            .ambiguous => return self.failIn(module_index, location, error.AmbiguousInstance),
            .undecided => return self.failIn(module_index, location, error.UndecidedInstance),
            .found => |found| found,
        };
        const function = ast.findInstanceMember(modules, found.reference, name) orelse return null;
        const instance_declaration = modules[found.reference.module].declarations[found.reference.declaration];
        if (instance_declaration.kind.instance_declaration.parameters.len == 0) return function;
        return try self.instantiateInstanceFunction(function, found.assigned);
    }

    fn instantiateInstanceFunction(
        self: *NameResolver,
        function: ast.Resolution.Function,
        assigned: []const types.Argument,
    ) ResolveError!ast.Resolution.Function {
        for (self.instantiated.items) |entry| {
            if (!std.meta.eql(entry.function, function)) continue;
            const same = for (entry.arguments, assigned) |one, two| {
                if (!std.meta.eql(one, two)) break false;
            } else true;
            if (same) return entry.result;
        }
        const allocator = self.arena.allocator();
        const module = &self.loader.modules.items[function.module];
        const original = ast.findDeclaration(module.*, function.declaration).*;
        const template = original.kind.function_definition;
        const reference = template.instance.?;
        const instance_declaration = &self.loader.modules.items[reference.module].declarations[reference.declaration].kind.instance_declaration;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        for (instance_declaration.parameters, assigned) |parameter, argument| {
            try bindings.append(allocator, .{ .name = parameter.name, .target = .{ .type = argument.type } });
        }
        const arguments = try self.resolveConcreteArguments(reference, bindings.items);
        if (template.default_of) |typeclass| {
            const typeclass_declaration = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
            for (typeclass_declaration.kind.typeclass_definition.parameters, arguments) |parameter, argument| {
                try bindings.append(allocator, .{ .name = parameter.name, .target = switch (argument) {
                    .type => |value_type| .{ .type = value_type },
                    .constructor => |constructor| .{ .constructor = constructor },
                } });
            }
        }
        var definition = try ast.cloneFunctionDefinition(allocator, template);
        definition.instance = reference;
        definition.template = function;
        definition.bindings = bindings.items;
        definition.instance_arguments = arguments;
        const index = module.declarations.len + module.instances.items.len;
        const created = try allocator.create(ast.Declaration);
        created.* = .{ .kind = .{ .function_definition = definition }, .location = original.location };
        try module.instances.append(allocator, created);
        const result: ast.Resolution.Function = .{ .module = function.module, .declaration = index };
        try self.instantiated.append(allocator, .{ .function = function, .arguments = assigned, .result = result });
        const pending_start = self.pending.items.len;
        try self.resolveFunctionBody(function.module, index);
        for (self.pending.items[pending_start..]) |pending| try self.resolvePendingMethod(pending);
        self.pending.shrinkRetainingCapacity(pending_start);
        if (self.type_checker) |type_checker| try type_checker.created.append(allocator, result);
        return result;
    }

    fn resolveConcreteArguments(
        self: *NameResolver,
        reference: ast.InstanceReference,
        bindings: []const ast.Binding,
    ) ResolveError![]const types.Argument {
        const allocator = self.arena.allocator();
        const declaration = self.loader.modules.items[reference.module].declarations[reference.declaration];
        const instance_declaration = declaration.kind.instance_declaration;
        const typeclass = instance_declaration.resolved.?;
        const definition = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = reference.module;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = bindings;
        const arguments = try allocator.alloc(types.Argument, definition.parameters.len);
        for (definition.parameters, instance_declaration.arguments, arguments) |parameter, argument, *resolved| {
            var expression = try ast.cloneExpression(allocator, argument);
            try self.resolveNamesInExpression(.{}, &expression);
            resolved.* = try self.expectArgument(parameter, &expression);
        }
        return arguments;
    }

    fn isDroppedName(self: *const NameResolver, name: []const u8) bool {
        for (self.dropped_names) |dropped| {
            if (std.mem.eql(u8, dropped, name)) return true;
        }
        return false;
    }

    fn findConstructorBinding(self: *const NameResolver, name: []const u8) ?types.Constructor {
        var binding_index = self.bindings.len;
        while (binding_index > 0) {
            binding_index -= 1;
            const binding = self.bindings[binding_index];
            if (!std.mem.eql(u8, binding.name, name)) continue;
            return if (binding.target == .constructor) binding.target.constructor else null;
        }
        return null;
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
            if (other_signature.typeclass != null or other_signature.progress != .done) continue;
            if (!std.mem.eql(u8, other_signature.name, signature.name)) continue;
            const other_type = ast.extractType(other_signature.receiver.?);
            if (!std.meta.eql(other_type, receiver_type)) continue;
            const later = module.declarations[@max(index, other_index)];
            return self.fail(later.location, error.DuplicateFunction);
        }
        switch (receiver_type) {
            .@"struct" => |struct_type| {
                for (struct_type.fields) |field| {
                    if (std.mem.eql(u8, field.name, signature.name)) {
                        return self.fail(declaration.location, error.MethodIsField);
                    }
                }
            },
            .@"enum" => |enumeration| {
                for (enumeration.cases) |case| {
                    if (std.mem.eql(u8, case.name, signature.name)) {
                        return self.fail(declaration.location, error.MethodIsCase);
                    }
                }
            },
            else => {},
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
        if (ast.isGeneric(definition.signature) or definition.pattern) {
            definition.body_progress = .done;
            return;
        }
        definition.body_progress = .running;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = definition.default_of;
        self.bindings = definition.bindings;
        const caller_constraints = self.constraints;
        defer self.constraints = caller_constraints;
        self.constraints = definition.constraints;
        const caller_dropped_names = self.dropped_names;
        defer self.dropped_names = caller_dropped_names;
        self.dropped_names = definition.dropped_names;
        const caller_owner_name = self.owner_name;
        defer self.owner_name = caller_owner_name;
        self.owner_name = self.findOwnerName(definition.*);
        if (definition.signature.receiver) |receiver| self.self_type = ast.extractType(receiver);
        self.self_name = if (definition.instance == null) "Self" else "";
        if (definition.default_of) |typeclass| self.module_index = typeclass.module;
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
        for (signature.parameters) |parameter| {
            if (parameter.kind == .any) return self.fail(parameter.type.location, error.AnyInExternalFunction);
        }
        try self.resolveFunctionTypes(signature);
        for (signature.parameters) |parameter| {
            if (containsInternalStruct(ast.extractType(parameter.type))) {
                return self.fail(parameter.type.location, error.InternalStructInExternalFunction);
            }
        }
        const return_type = signature.return_type;
        if (containsInternalStruct(ast.extractType(return_type))) {
            return self.fail(return_type.location, error.InternalStructInExternalFunction);
        }
        signature.progress = .done;
    }

    fn resolveAllSignatures(self: *NameResolver) ResolveError!void {
        var module_index: usize = 0;
        while (module_index < self.loader.modules.items.len) : (module_index += 1) {
            const module = self.loader.modules.items[module_index];
            for (module.declarations, 0..) |declaration, index| {
                switch (declaration.kind) {
                    .function_definition => |function| {
                        if (function.signature.progress != .pending) continue;
                        if (function.instance) |reference| {
                            const instance_module = self.loader.modules.items[reference.module];
                            const instance_declaration = instance_module.declarations[reference.declaration].kind.instance_declaration;
                            if (instance_declaration.progress == .running) continue;
                        }
                        try self.resolveFunctionSignature(module_index, index);
                    },
                    .function_declaration => try self.resolveExternalSignature(module_index, index),
                    .constant_declaration, .struct_definition, .enum_definition, .typeclass_definition, .instance_declaration, .import => {},
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
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = template.module;
        self.self_type = if (signature.receiver) |receiver| ast.extractType(receiver) else null;
        self.self_name = "Self";
        self.typeclass = null;
        self.bindings = bindings.items;
        var written = try ast.cloneExpression(allocator, signature.parameters[position].type);
        try self.resolveNamesInExpression(.{}, &written);
        return self.expectRuntimeType(&written);
    }

    fn resolveDeclaredPatternForChecker(
        context: *anyopaque,
        template: ast.Resolution.Function,
        position: usize,
        arguments: []const Bound,
    ) AnalyzeError!types.Type {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        const module = self.loader.modules.items[template.module];
        const definition = ast.findDeclaration(module, template.declaration).kind.function_definition;
        const signature = definition.signature;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        try bindings.appendSlice(allocator, definition.bindings);
        var argument_index: usize = 0;
        for (signature.parameters) |parameter| {
            if (parameter.kind == .run_time) continue;
            const argument = arguments[argument_index];
            argument_index += 1;
            if (parameter.kind != .type) continue;
            try bindings.append(allocator, .{ .name = parameter.name, .target = .{ .type = argument.value.type } });
        }
        for (signature.declared, 0..) |declared, index| {
            const variable: types.Type = .{ .variable = .{ .scope = .declared, .index = index } };
            try bindings.append(allocator, .{ .name = declared.name, .target = .{ .type = variable } });
        }
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = template.module;
        self.self_type = if (signature.receiver) |receiver| ast.extractType(receiver) else null;
        self.self_name = "Self";
        self.typeclass = null;
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
        pattern: bool,
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
                .implicit, .any => {
                    var implicit = parameter;
                    implicit.kind = .run_time;
                    implicit.type.denoted = argument.value.type;
                    try parameters.append(allocator, implicit);
                    continue;
                },
                .run_time => unreachable,
            };
            try bindings.append(allocator, .{ .name = parameter.name, .target = target });
        }
        for (instance.signature.declared, arguments[argument_index..]) |declared, argument| {
            try bindings.append(allocator, .{ .name = declared.name, .target = .{ .type = argument.value.type } });
        }
        instance.signature.declared = &.{};
        const original = declaration.kind.function_definition;
        var all_bindings: std.ArrayList(ast.Binding) = .empty;
        try all_bindings.appendSlice(allocator, original.bindings);
        try all_bindings.appendSlice(allocator, bindings.items);
        instance.signature.name = name;
        instance.signature.parameters = parameters.items;
        instance.template = template;
        instance.bindings = all_bindings.items;
        instance.instance = original.instance;
        instance.instance_arguments = original.instance_arguments;
        instance.pattern = pattern;
        const index = module.declarations.len + module.instances.items.len;
        const created = try allocator.create(ast.Declaration);
        created.* = .{ .kind = .{ .function_definition = instance }, .location = declaration.location };
        try module.instances.append(allocator, created);
        return .{ .module = template.module, .declaration = index };
    }

    fn createCheckCopyForChecker(context: *anyopaque, function: ast.Resolution.Function) AnalyzeError!ast.Resolution.Function {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const caller_module_index = self.module_index;
        defer self.module_index = caller_module_index;
        const module = self.loader.modules.items[function.module];
        const declaration = ast.findDeclaration(module, function.declaration).*;
        const template = declaration.kind.function_definition;
        var copy = try self.buildCheckCopy(template, template.bindings);
        copy.template = function;
        copy.instance = template.instance;
        copy.instance_arguments = template.instance_arguments;
        return self.addCheckCopy(function.module, copy, declaration.location);
    }

    fn createDefaultCheckCopyForChecker(
        context: *anyopaque,
        typeclass: ast.Resolution.Typeclass,
        position: usize,
    ) AnalyzeError!ast.Resolution.Function {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const caller_module_index = self.module_index;
        defer self.module_index = caller_module_index;
        const allocator = self.arena.allocator();
        const declaration = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
        const definition = declaration.kind.typeclass_definition;
        const template = definition.defaults[position].?.template;
        var copy = try self.buildCheckCopy(template, try self.buildTypeclassBindings(definition, declaration.location));
        copy.default_of = typeclass;
        const arguments = try allocator.alloc(types.Argument, definition.parameters.len);
        for (definition.parameters, arguments, 0..) |parameter, *argument, index| {
            const variable: types.Variable = .{ .scope = .typeclass, .index = index };
            argument.* = if (parameter.arity == 0) .{ .type = .{ .variable = variable } } else .{ .constructor = .{ .variable = variable } };
        }
        copy.instance_arguments = arguments;
        return self.addCheckCopy(typeclass.module, copy, declaration.location);
    }

    fn buildCheckCopy(
        self: *NameResolver,
        template: ast.FunctionDefinition,
        initial_bindings: []const ast.Binding,
    ) ResolveError!ast.FunctionDefinition {
        const allocator = self.arena.allocator();
        var copy = try ast.cloneFunctionDefinition(allocator, template);
        var parameters: std.ArrayList(ast.TypedName) = .empty;
        var bindings: std.ArrayList(ast.Binding) = .empty;
        var constraints: std.ArrayList(ast.Constraint) = .empty;
        var dependency: Dependency = .{};
        try bindings.appendSlice(allocator, initial_bindings);
        const modules = self.loader.modules.items;
        for (copy.signature.parameters) |parameter| {
            const tuple = parameter.constraint != null and ast.isTupleTypeclass(modules, parameter.constraint.?);
            if (parameter.kind == .type and (parameter.constraint == null or tuple)) try dependency.roots.append(allocator, parameter.name);
            if (parameter.kind == .implicit and tuple) try dependency.roots.append(allocator, parameter.name);
            if (parameter.kind == .any) try dependency.roots.append(allocator, parameter.name);
        }
        for (copy.signature.declared, 0..) |declared, position| {
            const typeclass = declared.resolved_requirement orelse {
                try dependency.roots.append(allocator, declared.name);
                continue;
            };
            if (ast.isTupleTypeclass(modules, typeclass)) {
                try dependency.roots.append(allocator, declared.name);
                continue;
            }
            const variable: types.Type = .{ .variable = .{ .scope = .function, .index = copy.signature.parameters.len + position } };
            try bindings.append(allocator, .{ .name = declared.name, .target = .{ .type = variable } });
            try constraints.append(allocator, .{ .typeclass = typeclass, .arguments = try allocator.dupe(types.Argument, &.{.{ .type = variable }}) });
        }
        copy.signature.declared = &.{};
        for (copy.signature.parameters, 0..) |parameter, index| {
            const variable: types.Type = .{ .variable = .{ .scope = .function, .index = index } };
            const arguments = try allocator.dupe(types.Argument, &.{.{ .type = variable }});
            switch (parameter.kind) {
                .run_time, .compile_time => {
                    if (isDependentExpression(dependency.names(), parameter.type, true)) {
                        try dependency.roots.append(allocator, parameter.name);
                        try collectExpressionNames(allocator, &dependency.dropped, parameter.type);
                        dependency.removed = true;
                        continue;
                    }
                    var kept = parameter;
                    if (parameter.kind == .compile_time) {
                        kept.kind = .run_time;
                        try dependency.values.append(allocator, parameter.name);
                    }
                    try parameters.append(allocator, kept);
                },
                .type => {
                    const typeclass = parameter.constraint orelse continue;
                    if (ast.isTupleTypeclass(modules, typeclass)) continue;
                    try bindings.append(allocator, .{ .name = parameter.name, .target = .{ .type = variable } });
                    try constraints.append(allocator, .{ .typeclass = typeclass, .arguments = arguments });
                },
                .any => {
                    dependency.removed = true;
                    continue;
                },
                .implicit => {
                    if (ast.isTupleTypeclass(modules, parameter.constraint.?)) {
                        dependency.removed = true;
                        continue;
                    }
                    var implicit = parameter;
                    implicit.kind = .run_time;
                    implicit.type.denoted = try self.buildImplicitType(parameter, variable);
                    try parameters.append(allocator, implicit);
                    try constraints.append(allocator, .{ .typeclass = parameter.constraint.?, .arguments = arguments });
                },
            }
        }
        if (isDependentExpression(dependency.names(), copy.signature.return_type, true)) {
            dependency.returns = true;
            try collectExpressionNames(allocator, &dependency.dropped, copy.signature.return_type);
            const location = copy.signature.return_type.location;
            copy.signature.return_type = .{ .kind = .{ .identifier = .{ .name = "void" } }, .location = location };
        }
        copy.body = try dropDependent(allocator, &dependency, copy.body);
        copy.signature.parameters = parameters.items;
        copy.bindings = bindings.items;
        copy.constraints = try self.expandConstraints(constraints.items);
        copy.check_only = true;
        copy.dropped_names = dependency.dropped.items;
        copy.lenient = dependency.returns or dependency.dropped.items.len > 0 or dependency.removed;
        return copy;
    }

    fn buildImplicitType(self: *NameResolver, parameter: ast.TypedName, target: types.Type) ResolveError!types.Type {
        if (parameter.type.kind != .pointer_type) return target;
        const pointer = try self.types.addPointer(self.arena.allocator(), .{
            .target = target,
            .many = false,
            .constant = parameter.type.kind.pointer_type.constant,
        });
        return .{ .pointer = pointer };
    }

    fn addCheckCopy(
        self: *NameResolver,
        module_index: usize,
        copy: ast.FunctionDefinition,
        location: token.Location,
    ) ResolveError!ast.Resolution.Function {
        const allocator = self.arena.allocator();
        const module = &self.loader.modules.items[module_index];
        const index = module.declarations.len + module.instances.items.len;
        const created = try allocator.create(ast.Declaration);
        created.* = .{ .kind = .{ .function_definition = copy }, .location = location };
        try module.instances.append(allocator, created);
        const pending_start = self.pending.items.len;
        try self.resolveFunctionBody(module_index, index);
        for (self.pending.items[pending_start..]) |pending| try self.resolvePendingMethod(pending);
        self.pending.shrinkRetainingCapacity(pending_start);
        return .{ .module = module_index, .declaration = index };
    }

    fn expandConstraints(self: *NameResolver, constraints: []const ast.Constraint) ResolveError![]const ast.Constraint {
        const allocator = self.arena.allocator();
        var expanded: std.ArrayList(ast.Constraint) = .empty;
        var pending: std.ArrayList(ast.Constraint) = .empty;
        try pending.appendSlice(allocator, constraints);
        while (pending.pop()) |constraint| {
            const known = for (expanded.items) |earlier| {
                if (std.meta.eql(earlier.typeclass, constraint.typeclass) and isSameArguments(earlier.arguments, constraint.arguments)) break true;
            } else false;
            if (known) continue;
            try expanded.append(allocator, constraint);
            try self.resolveTypeclass(constraint.typeclass);
            const declaration = self.loader.modules.items[constraint.typeclass.module].declarations[constraint.typeclass.declaration];
            for (declaration.kind.typeclass_definition.parameters, constraint.arguments) |parameter, argument| {
                const requirement = parameter.resolved_requirement orelse continue;
                try pending.append(allocator, .{ .typeclass = requirement, .arguments = try allocator.dupe(types.Argument, &.{argument}) });
            }
        }
        return expanded.items;
    }

    fn expandConstraintsForChecker(context: *anyopaque, constraints: []const ast.Constraint) AnalyzeError![]const ast.Constraint {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        return self.expandConstraints(constraints);
    }

    fn buildResolver(self: *NameResolver) Resolver {
        return .{
            .context = self,
            .resolve = resolveForChecker,
            .resolveParameterType = resolveParameterTypeForChecker,
            .resolveDeclaredPattern = resolveDeclaredPatternForChecker,
            .instantiate = instantiateForChecker,
            .instantiateInstanceFunction = instantiateInstanceFunctionForChecker,
            .createCheckCopy = createCheckCopyForChecker,
            .createDefaultCheckCopy = createDefaultCheckCopyForChecker,
            .expandConstraints = expandConstraintsForChecker,
            .beginStruct = beginStructForChecker,
            .finishStruct = finishStructForChecker,
            .expandTupleLoop = expandTupleLoopForChecker,
        };
    }

    fn expandTupleLoopForChecker(
        context: *anyopaque,
        function: ast.Resolution.Function,
        statement: *ast.Statement,
        count: usize,
    ) AnalyzeError!void {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        return self.expandTupleLoop(function, statement, count);
    }

    fn expandTupleLoop(
        self: *NameResolver,
        function: ast.Resolution.Function,
        statement: *ast.Statement,
        count: usize,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const module = self.loader.modules.items[function.module];
        const definition = &ast.findDeclaration(module, function.declaration).kind.function_definition;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        const caller_constraints = self.constraints;
        const caller_dropped_names = self.dropped_names;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        defer self.constraints = caller_constraints;
        defer self.dropped_names = caller_dropped_names;
        self.module_index = if (definition.default_of) |typeclass| typeclass.module else function.module;
        self.self_type = if (definition.signature.receiver) |receiver| ast.extractType(receiver) else null;
        self.self_name = if (definition.instance == null) "Self" else "";
        self.typeclass = definition.default_of;
        self.bindings = definition.bindings;
        self.constraints = definition.constraints;
        self.dropped_names = definition.dropped_names;
        const parameters = definition.signature.parameters;
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
        _ = try self.collectScope(block, definition.body, statement);
        try loops.append(allocator, .{ .statement = statement });
        const loop = &statement.kind.@"for";
        const pointer = ast.hasPointerName(loop.names);
        if (!pointer) {
            const value = try allocator.create(ast.Statement);
            value.* = .{
                .kind = .{ .constant_declaration = .{ .name = "mn_tuple", .value = loop.sequence.value } },
                .location = statement.location,
            };
            loop.expansion_value = value;
            try locals.append(allocator, .{ .name = "mn_tuple", .target = .{ .local = value }, .statement = value, .location = statement.location });
        }
        const expansions = try allocator.alloc([]ast.Statement, count);
        for (expansions, 0..) |*expansion, position| {
            const body = try ast.cloneBlock(allocator, loop.body);
            const element = try self.buildTupleElement(statement, position, pointer);
            const declarations: []const ast.Statement = if (element) |declaration| &.{declaration} else &.{};
            expansion.* = try std.mem.concat(allocator, ast.Statement, &.{ declarations, body });
            try self.resolveNamesInBlock(block, expansion.*);
        }
        loop.expansions = expansions;
    }

    fn buildTupleElement(
        self: *NameResolver,
        statement: *const ast.Statement,
        position: usize,
        pointer: bool,
    ) ResolveError!?ast.Statement {
        const allocator = self.arena.allocator();
        const loop = statement.kind.@"for";
        const location = statement.location;
        const base = try allocator.create(ast.Expression);
        base.* = if (pointer)
            try ast.cloneExpression(allocator, loop.sequence.value)
        else
            .{ .kind = .{ .identifier = .{ .name = "mn_tuple" } }, .location = location };
        const index = try allocator.create(ast.Expression);
        const text = try std.fmt.allocPrint(allocator, "{d}", .{position});
        index.* = .{ .kind = .{ .integer_literal = .{ .text = text, .suffix = null } }, .location = location };
        const element: ast.Expression = .{ .kind = .{ .index = .{ .value = base, .index = index } }, .location = location };
        if (loop.tuple) {
            const names = try allocator.dupe(ast.ElementName, loop.names);
            for (names) |*name| name.type = null;
            return .{ .kind = .{ .tuple_declaration = .{ .names = names, .value = element } }, .location = location };
        }
        const name = loop.names[0];
        if (ast.isDiscardedName(name.name)) return null;
        var value = element;
        if (name.pointer) {
            const operand = try allocator.create(ast.Expression);
            operand.* = element;
            value = .{ .kind = .{ .address_of = operand }, .location = location };
        }
        return .{ .kind = .{ .constant_declaration = .{ .name = name.name, .value = value } }, .location = name.location };
    }

    fn collectScope(
        self: *NameResolver,
        block: Block,
        body: []ast.Statement,
        target: *const ast.Statement,
    ) ResolveError!bool {
        const allocator = self.arena.allocator();
        for (body) |*statement| {
            if (statement == target) return true;
            if (ast.findBranching(statement)) |inner| {
                if (containsTarget(inner[0..1], target)) return self.collectScope(block, inner[0..1], target);
            }
            switch (statement.kind) {
                .@"for" => |*loop| {
                    for (loop.expansions) |expansion| {
                        if (!containsTarget(expansion, target)) continue;
                        try block.loops.append(allocator, .{ .statement = statement });
                        if (loop.expansion_value) |value| {
                            try block.locals.append(allocator, .{ .name = "mn_tuple", .target = .{ .local = value }, .statement = value, .location = value.location });
                        }
                        return self.collectScope(block, expansion, target);
                    }
                    if (containsTarget(loop.body, target)) {
                        try block.loops.append(allocator, .{ .statement = statement });
                        try self.appendElements(block, statement);
                        return self.collectScope(block, loop.body, target);
                    }
                    if (loop.else_body) |else_body| {
                        if (containsTarget(else_body, target)) return self.collectScope(block, else_body, target);
                    }
                },
                .@"while" => |*loop| {
                    if (containsTarget(loop.body, target)) {
                        try block.loops.append(allocator, .{ .statement = statement });
                        try self.appendElements(block, statement);
                        return self.collectScope(block, loop.body, target);
                    }
                    if (loop.else_body) |else_body| {
                        if (containsTarget(else_body, target)) return self.collectScope(block, else_body, target);
                    }
                },
                .@"if" => |*conditional| {
                    if (containsTarget(conditional.body, target)) {
                        try self.appendElements(block, statement);
                        return self.collectScope(block, conditional.body, target);
                    }
                    if (conditional.else_body) |else_body| {
                        if (containsTarget(else_body, target)) return self.collectScope(block, else_body, target);
                    }
                },
                .match => |*matching| {
                    for (matching.branches, matching.names, 0..) |*branch, name, position| {
                        if (!containsTarget(branch.body, target)) continue;
                        if (!ast.isDiscardedName(name.name)) {
                            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
                            try block.locals.append(allocator, .{ .name = name.name, .target = .{ .element = element }, .statement = statement, .location = name.location });
                        }
                        return self.collectScope(block, branch.body, target);
                    }
                },
                .constant_declaration => |*constant| {
                    const scope: Scope = .{ .parameters = block.parameters, .parameter_uses = block.parameter_uses, .locals = block.locals.items };
                    const alias = if (constant.type == null) try self.findAlias(scope, &constant.value) else null;
                    const local_target: Target = alias orelse .{ .local = statement };
                    try block.locals.append(allocator, .{ .name = constant.name, .target = local_target, .statement = statement, .location = statement.location });
                },
                .variable_declaration => |variable| {
                    try block.locals.append(allocator, .{ .name = variable.name, .target = .{ .local = statement }, .statement = statement, .location = statement.location });
                },
                .tuple_declaration => try self.appendElements(block, statement),
                .noop, .@"return", .discard, .call, .assignment, .@"defer", .@"break", .@"continue", .value => {},
            }
        }
        return false;
    }

    fn appendElements(self: *NameResolver, block: Block, statement: *ast.Statement) ResolveError!void {
        for (ast.extractElementNames(statement.*), 0..) |name, position| {
            if (ast.isDiscardedName(name.name)) continue;
            const element: ast.Resolution.Element = .{ .statement = statement, .position = position };
            try block.locals.append(self.arena.allocator(), .{ .name = name.name, .target = .{ .element = element }, .statement = statement, .location = name.location });
        }
    }

    fn instantiateInstanceFunctionForChecker(
        context: *anyopaque,
        function: ast.Resolution.Function,
        assigned: []const types.Argument,
    ) AnalyzeError!ast.Resolution.Function {
        const self: *NameResolver = @ptrCast(@alignCast(context));
        const caller_module_index = self.module_index;
        defer self.module_index = caller_module_index;
        return self.instantiateInstanceFunction(function, assigned);
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
        const bindings = try bindSelf(allocator, struct_type.bindings, value_type);
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        self.module_index = struct_type.module;
        self.self_type = value_type;
        self.self_name = "Self";
        self.typeclass = null;
        self.bindings = bindings;
        const fields = try cloneFields(allocator, struct_type.fields);
        try self.resolveFields(fields, @constCast(value_type.@"struct".fields));
        try self.completeStruct(struct_type, value_type, location);
    }

    fn completeStruct(
        self: *NameResolver,
        struct_type: *const ast.StructType,
        value_type: types.Type,
        location: token.Location,
    ) ResolveError!void {
        try self.expectNotContained(value_type.@"struct", location);
        try self.types.add(self.arena.allocator(), value_type);
        try self.addStructFunctions(struct_type, self.bindings);
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
        if (!self.preparing) {
            self.preparing = true;
            defer self.preparing = false;
            try self.resolveAllTypeclasses();
            try self.resolveAllInstanceArguments();
            try self.resolveAllSignatures();
        }
        type_checker.resolver = self.buildResolver();
        type_checker.failure = null;
        return type_checker;
    }

    fn resolvePendingMethod(self: *NameResolver, pending: PendingMethod) NameError!void {
        self.module_index = pending.module;
        const modules = self.loader.modules.items;
        const receiver = pending.method.receiver;
        const name = pending.method.name;
        const function = ast.findOwnMethod(modules, receiver, name) orelse {
            return self.fail(pending.location, error.UnknownMethod);
        };
        if (pending.value) {
            const definition = ast.findDeclaration(modules[function.module], function.declaration);
            if (definition.kind == .function_definition and definition.kind.function_definition.signature.@"inline") {
                return self.fail(pending.location, error.InlineValue);
            }
        }
        pending.resolution.* = .{ .function = function };
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
            if (parameter.kind == .any) {
                parameter.type.denoted = .{ .variable = .{ .scope = .function, .index = index } };
                continue;
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
        if (written_type.denoted == null) try self.resolveNamesInExpression(.{}, written_type);
        _ = try self.expectRuntimeType(written_type);
    }

    fn expectRuntimeType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        const value_type = try self.expectType(expression);
        if (!isRuntimeType(value_type)) return self.fail(expression.location, error.FunctionWithoutPointer);
        return value_type;
    }

    fn expectType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        if (expression.denoted) |denoted| return denoted;
        if (!isCall(expression)) return self.expectOtherType(expression);
        if (try self.buildApplication(expression)) |application| {
            expression.denoted = application;
            return application;
        }
        return self.evaluateType(expression);
    }

    fn expectOtherType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        switch (expression.kind) {
            inline .identifier, .path_expression, .member => |name| {
                const resolution = name.resolution orelse return self.fail(expression.location, error.TypeMismatch);
                return switch (resolution) {
                    .type => |value_type| value_type,
                    .constant, .local => self.evaluateType(expression),
                    .parameter, .function, .element, .typeclass_function, .typeclass_method, .case, .builtin => {
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
            .call => unreachable,
            .method_call, .index, .field_access, .unwrap, .dereference, .struct_type => {
                return self.evaluateType(expression);
            },
            .binary => |binary| {
                if (binary.operator != .combine and binary.operator != .result) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
                return self.evaluateType(expression);
            },
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .negation,
            .unary,
            .address_of,
            .composite_literal,
            .slice,
            .@"try",
            .range,
            .jump,
            .branching,
            => return self.fail(expression.location, error.TypeMismatch),
        }
    }

    fn buildApplication(self: *NameResolver, expression: *ast.Expression) ResolveError!?types.Type {
        if (!hasVariableBindings(self.bindings)) return null;
        const call = expression.kind.call;
        const resolution: ?ast.Resolution = switch (call.callee) {
            inline .identifier, .path_expression => |name| name.resolution,
            .member => return null,
        };
        if (resolution != null and resolution.? == .typeclass_function) {
            return try self.buildTypeclassApplication(expression.location, resolution.?.typeclass_function, call);
        }
        const constructor: types.Constructor = if (resolution) |resolved| constructor: {
            if (resolved != .function) return null;
            const module = self.loader.modules.items[resolved.function.module];
            const declaration = ast.findDeclaration(module, resolved.function.declaration).*;
            if (declaration.kind != .function_definition) return null;
            const parameters = declaration.kind.function_definition.signature.parameters;
            if (parameters.len != call.arguments.len or parameters.len == 0) return null;
            for (parameters) |parameter| {
                if (parameter.kind != .type) return null;
            }
            break :constructor .{ .function = resolved.function };
        } else if (call.callee == .identifier)
            self.findConstructorBinding(call.callee.identifier.name) orelse return null
        else
            return null;
        const allocator = self.arena.allocator();
        const arguments = try allocator.alloc(types.Type, call.arguments.len);
        var variable = constructor == .variable;
        for (call.arguments, arguments) |*argument, *argument_type| {
            argument_type.* = try self.expectType(&argument.value);
            for ([_]types.Scope{ .typeclass, .instance, .function }) |scope| {
                if (types.containsVariable(argument_type.*, scope)) variable = true;
            }
        }
        if (!variable) return null;
        return .{ .application = try self.types.addApplication(allocator, constructor, arguments) };
    }

    fn buildTypeclassApplication(
        self: *NameResolver,
        location: token.Location,
        function: ast.Resolution.TypeclassFunction,
        call: ast.Call,
    ) ResolveError!types.Type {
        if (call.arguments.len != 0) return self.fail(location, error.TypeMismatch);
        const modules = self.loader.modules.items;
        const definition = modules[function.typeclass.module].declarations[function.typeclass.declaration].kind.typeclass_definition;
        const allocator = self.arena.allocator();
        const arguments = try allocator.alloc(types.Type, definition.parameters.len);
        for (arguments, 0..) |*argument, index| argument.* = .{ .variable = .{ .scope = .typeclass, .index = index } };
        if (self.signature_definition) |instance_function| {
            const reference = instance_function.instance.?;
            const instance_arguments = modules[reference.module].declarations[reference.declaration].kind.instance_declaration.resolved_arguments;
            for (arguments, instance_arguments) |*argument, instance_argument| argument.* = instance_argument.type;
        }
        return .{ .application = try self.types.addApplication(allocator, .{ .typeclass_function = function }, arguments) };
    }

    fn evaluateType(self: *NameResolver, expression: *ast.Expression) ResolveError!types.Type {
        const type_checker = try self.prepareKnownChecker(expression);
        const value = type_checker.evaluateKnown(self.loader.modules.items, self.module_index, expression, .type) catch |type_error| {
            self.adoptCheckerFailure(type_checker);
            return type_error;
        };
        expression.denoted = value.type;
        return expression.denoted.?;
    }

    fn adoptCheckerFailure(self: *NameResolver, type_checker: *const TypeChecker) void {
        if (type_checker.failure) |failure| self.failure = failure;
    }

    fn prepareKnownChecker(self: *NameResolver, expression: *const ast.Expression) ResolveError!*TypeChecker {
        if (self.type_checker == null) return self.fail(expression.location, error.TypeMismatch);
        const type_checker = try self.prepareChecker();
        if (!type_checker.isKnown(self.loader.modules.items, expression.*)) return self.fail(expression.location, error.TypeMismatch);
        return type_checker;
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
            if (ast.isDiscardedName(parameter.name) or self.isDroppedName(parameter.name)) continue;
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
            if (self.isDroppedName(local.name)) continue;
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
        try self.resolveStatementJumps(block, statement);
        try self.resolveBranchings(block, statement);
        const scope: Scope = .{
            .parameters = block.parameters,
            .parameter_uses = block.parameter_uses,
            .locals = block.locals.items,
        };
        switch (statement.kind) {
            .noop => {},
            .value => |*expression| try self.resolveNamesInExpression(scope, expression),
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
                if (conditional.names.len == 0) {
                    try self.chooseBlock(conditional);
                    try self.resolveNamesInBlock(block, conditional.body);
                } else {
                    if (ast.hasPointerName(conditional.names)) recordModifiedVariable(scope, findStorageRoot(conditional.condition));
                    try self.resolveNamedBody(block, statement);
                }
                if (conditional.else_body) |else_body| try self.resolveNamesInBlock(block, else_body);
            },
            .@"while" => |*loop| {
                try self.resolveNamesInExpression(scope, &loop.condition);
                if (ast.hasPointerName(loop.names)) recordModifiedVariable(scope, findStorageRoot(loop.condition));
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
            .@"defer" => |deferred| _ = try self.resolveNamesInStatement(block, deferred.statement),
            .match => |*matching| {
                try self.resolveNamesInExpression(scope, &matching.value);
                if (ast.hasPointerName(matching.names)) {
                    recordModifiedVariable(scope, findStorageRoot(matching.value));
                }
                try self.resolveBranches(block, statement);
            },
            .@"break", .@"continue" => try self.resolveJump(block.loops.items, statement),
        }
        return null;
    }

    fn resolveBranchings(self: *NameResolver, block: Block, statement: *const ast.Statement) ResolveError!void {
        const allocator = self.arena.allocator();
        var branchings: std.ArrayList(*ast.Statement) = .empty;
        try ast.collectStatementBranchings(allocator, &branchings, statement);
        for (branchings.items) |inner| {
            try self.resolved_branchings.put(allocator, inner, {});
            _ = try self.resolveNamesInStatement(block, inner);
        }
    }

    fn resolveDetachedBranching(self: *NameResolver, statement: *ast.Statement) ResolveError!void {
        if (self.resolved_branchings.contains(statement)) return;
        try self.resolved_branchings.put(self.arena.allocator(), statement, {});
        var locals: std.ArrayList(Local) = .empty;
        var loops: std.ArrayList(Loop) = .empty;
        const block: Block = .{ .parameters = &.{}, .parameter_uses = &.{}, .locals = &locals, .loops = &loops };
        _ = try self.resolveNamesInStatement(block, statement);
    }

    fn chooseBlock(self: *NameResolver, conditional: *ast.If) ResolveError!void {
        if (self.type_checker == null) return;
        const modules = self.loader.modules.items;
        const condition = &conditional.condition;
        if (!self.type_checker.?.isKnown(modules, condition.*)) return;
        const type_checker = try self.prepareChecker();
        const chosen = type_checker.chooseCondition(modules, self.module_index, condition) catch |type_error| {
            self.adoptCheckerFailure(type_checker);
            return type_error;
        } orelse return;
        const allocator = self.arena.allocator();
        const dropped = if (chosen) conditional.else_body orelse &.{} else conditional.body;
        var names: std.ArrayList([]const u8) = .empty;
        try names.appendSlice(allocator, self.dropped_names);
        for (dropped) |statement| try collectStatementNames(allocator, &names, statement);
        self.dropped_names = names.items;
        condition.kind = .{ .boolean_literal = chosen };
        conditional.known = chosen;
        const module = self.loader.modules.items[self.module_index];
        if (chosen) {
            conditional.dropped_ends = ast.isEndingBlock(module, conditional.else_body orelse &.{});
            if (conditional.else_body != null) conditional.else_body = &.{};
        } else {
            conditional.dropped_ends = ast.isEndingBlock(module, conditional.body);
            conditional.body = &.{};
        }
    }

    fn resolveNamedBody(self: *NameResolver, block: Block, statement: *ast.Statement) ResolveError!void {
        const start = block.locals.items.len;
        try self.declareElements(block, statement);
        try self.resolveNamesInBlock(block, statement.kind.@"if".body);
        for (block.locals.items[start..]) |local| {
            if (self.isDroppedName(local.name)) continue;
            try self.expectUsed(local.use, local.location, error.UnusedValueName);
        }
        block.locals.shrinkRetainingCapacity(start);
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
        try self.declareElements(block, statement);
        const body = switch (statement.kind) {
            .@"while" => |loop| loop.body,
            .@"for" => |loop| loop.body,
            else => unreachable,
        };
        try self.resolveNamesInBlock(block, body);
        for (block.locals.items[start..]) |local| {
            if (self.isDroppedName(local.name)) continue;
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

    fn resolveBranches(self: *NameResolver, block: Block, statement: *ast.Statement) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const matching = &statement.kind.match;
        for (matching.branches, matching.names, 0..) |*branch, *name, position| {
            const scope: Scope = .{
                .parameters = block.parameters,
                .parameter_uses = block.parameter_uses,
                .locals = block.locals.items,
            };
            if (branch.naming == .payload and try self.isTypeApplication(scope, branch.cases[0].pattern, name.*)) {
                branch.cases[0].pattern = try self.buildTypeApplication(branch.cases[0].pattern, name.*);
                branch.naming = .none;
                name.* = .{ .name = "_", .location = name.location };
            }
            for (branch.cases) |*case| try self.resolveBranchCase(scope, case);
            const start = block.locals.items.len;
            if (!ast.isDiscardedName(name.name)) {
                if (isReservedName(module.path, name.name)) return self.fail(name.location, error.ReservedName);
                try block.locals.append(self.arena.allocator(), .{
                    .name = name.name,
                    .target = .{ .element = .{ .statement = statement, .position = position } },
                    .statement = statement,
                    .location = name.location,
                });
            }
            try self.resolveNamesInBlock(block, branch.body);
            for (block.locals.items[start..]) |local| {
                if (self.isDroppedName(local.name)) continue;
                try self.expectUsed(local.use, local.location, error.UnusedValueName);
            }
            block.locals.shrinkRetainingCapacity(start);
        }
    }

    fn isTypeApplication(self: *NameResolver, scope: Scope, pattern: ast.Expression, name: ast.ElementName) ResolveError!bool {
        if (ast.isDiscardedName(name.name)) return false;
        const head = switch (pattern.kind) {
            .identifier => |identifier| if (isVisibleName(scope, identifier.name)) null else try self.findDeclaredTarget(pattern.location, identifier.name),
            .path_expression => |path_expression| try self.resolvePath(scope, pattern.location, path_expression.path),
            else => null,
        };
        if (head) |target| {
            if (target == .function or target == .constructor) return true;
        }
        if (findTypedName(scope.parameters, name.name)) |index| return scope.parameters[index].kind == .type;
        if (findLocal(scope.locals, name.name) != null) return false;
        const inner = try self.findDeclaredTarget(name.location, name.name) orelse return false;
        return inner == .type;
    }

    fn buildTypeApplication(self: *NameResolver, pattern: ast.Expression, name: ast.ElementName) ResolveError!ast.Expression {
        const allocator = self.arena.allocator();
        const callee: ast.Name = switch (pattern.kind) {
            .identifier => |identifier| .{ .identifier = identifier },
            .path_expression => |path_expression| .{ .path_expression = path_expression },
            else => unreachable,
        };
        var argument: ast.Expression = .{ .kind = .{ .identifier = .{ .name = name.name } }, .location = name.location };
        if (name.pointer) {
            const target = try allocator.create(ast.Expression);
            target.* = argument;
            argument = .{ .kind = .{ .pointer_type = .{ .many = false, .constant = false, .target = target } }, .location = name.location };
        }
        const arguments = try allocator.dupe(ast.Argument, &.{.{ .name = null, .value = argument, .location = name.location }});
        return .{ .kind = .{ .call = .{ .callee = callee, .arguments = arguments } }, .location = pattern.location };
    }

    fn resolveBranchCase(self: *NameResolver, scope: Scope, case: *ast.BranchCase) ResolveError!void {
        const pattern = &case.pattern;
        switch (pattern.kind) {
            .identifier => |*identifier| try self.resolveCaseName(scope, pattern.location, identifier),
            .path_expression => |*path_expression| {
                try self.resolveNamesInExpression(scope, pattern);
                const resolution = path_expression.resolution orelse return self.fail(pattern.location, error.NotCase);
                switch (resolution) {
                    .case, .type, .constant => {},
                    .parameter, .local, .function, .element, .typeclass_function, .typeclass_method, .builtin => {
                        return self.fail(pattern.location, error.NotCase);
                    },
                }
            },
            else => try self.resolveNamesInExpression(scope, pattern),
        }
        if (case.end) |*end| try self.resolveNamesInExpression(scope, end);
    }

    fn resolveCaseName(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        identifier: *ast.Identifier,
    ) ResolveError!void {
        if (!isVisibleName(scope, identifier.name)) {
            _ = try self.findDeclaredTarget(location, identifier.name) orelse return;
        }
        try self.resolveIdentifier(scope, location, identifier);
    }

    fn findDeclaredTarget(self: *NameResolver, location: token.Location, name: []const u8) ResolveError!?Target {
        const target = self.resolveName(location, name) catch |resolve_error| {
            if (resolve_error != error.UnknownName) return resolve_error;
            self.failure = null;
            return null;
        };
        return target;
    }

    fn resolveJump(self: *NameResolver, loops: []Loop, statement: *ast.Statement) NameError!void {
        const jump = switch (statement.kind) {
            .@"break", .@"continue" => |*jump| jump,
            else => unreachable,
        };
        if (loops.len == 0) {
            const outside_error: NameError = if (statement.kind == .@"break") error.BreakOutsideLoop else error.ContinueOutsideLoop;
            return self.fail(statement.location, outside_error);
        }
        const name = jump.label orelse {
            jump.loop = loops[loops.len - 1].statement;
            return;
        };
        const loop = findLoop(loops, name) orelse return self.fail(statement.location, error.UnknownLabel);
        loop.label_used = true;
        jump.loop = loop.statement;
    }

    fn resolveStatementJumps(self: *NameResolver, block: Block, statement: *const ast.Statement) ResolveError!void {
        var jumps: std.ArrayList(*ast.Statement) = .empty;
        try ast.collectStatementJumps(self.arena.allocator(), &jumps, statement);
        for (jumps.items) |jump| {
            if (jump.kind == .@"return") continue;
            try self.resolveJump(block.loops.items, jump);
        }
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
            self.adoptCheckerFailure(type_checker);
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
                try self.resolveNamesInExpression(scope.restrictToTypes(), array_type.element);
                _ = try self.expectRuntimeType(array_type.element);
                return;
            }
        }
        try self.resolveNamesInExpression(scope.restrictToTypes(), written_type);
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
        try self.expectNotInline(value.location, target);
        return switch (target) {
            .function, .type, .method, .typeclass => target,
            .namespace => self.fail(value.location, error.ModuleInConstant),
            .constant, .local, .element, .typeclass_method, .case, .constructor, .builtin => null,
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
            .member,
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
            .@"try",
            .range,
            .jump,
            .branching,
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
        switch (expression.kind) {
            .pointer_type => |*pointer_type| try self.resolvePointerType(scope, expression.location, pointer_type),
            .optional_type => |*optional_type| try self.resolveOptionalType(scope, optional_type),
            else => try self.resolveNamesInOtherExpression(scope, expression),
        }
    }

    fn resolveNamesInOtherExpression(
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
            .member => |*member| member.resolution = try self.resolveMemberFunction(scope, location, member),
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
            .pointer_type, .optional_type => unreachable,
            .tuple_type => |*tuple_type| try self.resolveTupleType(scope, tuple_type),
            .function_type => |*function_type| try self.resolveFunctionType(scope, function_type),
            .field_access => |access| try self.resolveNamesInExpression(scope, access.value),
            .dereference, .unwrap, .@"try" => |operand| try self.resolveNamesInExpression(scope, operand),
            .range => |range| try self.resolveRange(scope, location, range),
            .struct_type => |struct_type| {
                struct_type.module = self.module_index;
                struct_type.bindings = self.bindings;
                struct_type.prefix = self.owner_name;
            },
            .jump => |statement| {
                if (statement.kind == .@"return") {
                    if (statement.kind.@"return") |*value| try self.resolveNamesInExpression(scope, value);
                }
            },
            .branching => |statement| try self.resolveDetachedBranching(statement),
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
                    .parameter, .function, .element, .typeclass_function, .typeclass_method, .case, .builtin => {
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
            .array, .tuple, .@"struct", .@"enum" => {},
            .number, .boolean, .void, .type, .slice, .pointer, .optional, .result, .function, .variable, .application => {
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
        try self.resolveNamesInExpression(scope.restrictToTypes(), array_type.element);
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
        const type_scope = scope.restrictToTypes();
        const length_scope = if (isMeasuredParameter(type_scope, expression.*)) type_scope.exposeMeasurable() else type_scope;
        try self.resolveNamesInExpression(length_scope, expression);
        const type_checker = try self.prepareChecker();
        const modules = self.loader.modules.items;
        if (!isArrayLengthAccess(expression.*) and !type_checker.isKnown(modules, expression.*)) {
            return self.fail(expression.location, error.CannotEvaluate);
        }
        const usize_type: types.Type = .{ .number = .usize };
        type_checker.checkKnown(modules, self.module_index, length_scope.parameters, expression, usize_type) catch |type_error| {
            self.adoptCheckerFailure(type_checker);
            return type_error;
        };
        if (expression.kind == .field_access) {
            const container = types.followPointer(expression.kind.field_access.value.type.?);
            if (container == .array) return self.fail(expression.location, error.CallInArrayLength);
        }
        const value = type_checker.evaluateChecked(self.module_index, expression) catch |type_error| {
            self.adoptCheckerFailure(type_checker);
            return type_error;
        };
        return @intCast(value.integer);
    }

    fn resolveSliceType(
        self: *NameResolver,
        scope: Scope,
        slice_type: *ast.SliceType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(scope.restrictToTypes(), slice_type.element);
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
        try self.resolveNamesInExpression(scope.restrictToTypes(), pointer_type.target);
        const target = try self.expectType(pointer_type.target);
        if (target == .function) {
            if (pointer_type.many) return self.fail(location, error.ManyFunctionPointer);
            if (pointer_type.constant) return self.fail(location, error.ConstantFunctionPointer);
        }
        if (target == .void and pointer_type.many) return self.fail(location, error.ManyVoidPointer);
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
        try self.resolveNamesInExpression(scope.restrictToTypes(), optional_type.child);
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
            try self.resolveNamesInExpression(scope.restrictToTypes(), written);
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
        const type_scope = scope.restrictToTypes();
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

    fn resolveRange(self: *NameResolver, scope: Scope, location: token.Location, range: *ast.Range) ResolveError!void {
        try self.resolveNamesInExpression(scope, &range.start);
        if (range.end) |*end| try self.resolveNamesInExpression(scope, end);
        range.type = try self.resolveLanguageType(location, "Range");
    }

    fn resolveLanguageType(self: *NameResolver, location: token.Location, name: []const u8) ResolveError!types.Type {
        const namespace = (try self.loadRoot("mn")) orelse return self.fail(location, error.MissingLanguageDeclaration);
        const module_index = namespace.module orelse return self.fail(location, error.MissingLanguageDeclaration);
        const index = findDeclaration(self.loader.modules.items[module_index], name) orelse {
            return self.fail(location, error.MissingLanguageDeclaration);
        };
        const target = try self.resolveDeclaration(module_index, index);
        if (target != .type) return self.fail(location, error.MissingLanguageDeclaration);
        return target.type;
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
            .case => |case| .{ .case = case },
            .builtin => self.fail(location, error.BuiltinUsedAsValue),
            .typeclass, .typeclass_method => self.fail(location, error.TypeclassUsedAsValue),
            .constructor => self.fail(location, error.TypeMismatch),
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
                if (try self.findSiblingFunction(name)) |sibling| {
                    identifier.resolution = sibling;
                    return;
                }
                break :target .{ try self.resolveName(location, name), &identifier.resolution };
            },
            .path_expression => |*path_expression| target: {
                const path = path_expression.path;
                const target = try self.resolvePath(scope, location, path);
                break :target .{ target, &path_expression.resolution };
            },
            .member => |*member| {
                member.resolution = try self.resolveMemberFunction(scope, location, member);
                return;
            },
        };
        if (target == .constructor) return;
        if (target == .method) {
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

    fn findSiblingFunction(self: *NameResolver, name: []const u8) ResolveError!?ast.Resolution {
        const modules = self.loader.modules.items;
        if (self.signature_typeclass) |typeclass| {
            const definition = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
            const position = findSignaturePosition(definition.functions, name) orelse return null;
            return .{ .typeclass_function = .{ .typeclass = typeclass, .function = position } };
        }
        const definition = self.signature_definition orelse return null;
        const reference = definition.instance.?;
        const function = ast.findInstanceMember(modules, reference, name) orelse return null;
        const instance_declaration = modules[reference.module].declarations[reference.declaration].kind.instance_declaration;
        const parameters = instance_declaration.parameters;
        if (parameters.len == 0) return .{ .function = function };
        if (definition.template == null) {
            const typeclass = instance_declaration.resolved.?;
            const functions = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition.functions;
            const position = findSignaturePosition(functions, name).?;
            return .{ .typeclass_function = .{ .typeclass = typeclass, .function = position } };
        }
        const assigned = try self.arena.allocator().alloc(types.Argument, parameters.len);
        for (assigned, definition.bindings[0..parameters.len]) |*argument, binding| argument.* = .{ .type = binding.target.type };
        return .{ .function = try self.instantiateInstanceFunction(function, assigned) };
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
            .typeclass_method => |method| .{ .typeclass_method = method },
            .case => |case| .{ .case = case },
            .builtin => |builtin| .{ .builtin = builtin },
            .type, .namespace, .method, .typeclass, .constructor => {
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
                .constructor => |constructor| switch (constructor) {
                    .function => |function| .{ .function = function },
                    .variable => .{ .constructor = constructor },
                    .typeclass_function => unreachable,
                },
            };
        }
        if (self.self_type) |self_type| {
            if (std.mem.eql(u8, name, self.self_name)) return .{ .type = self_type };
        }
        if (std.mem.eql(u8, name, "Self")) return self.fail(location, error.UnknownName);
        const module = self.loader.modules.items[self.module_index];
        if (findBareDeclaration(module, name)) |index| {
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
                .type => |receiver| {
                    if (findCase(receiver, last)) |case| return .{ .case = case };
                    return .{ .method = .{ .receiver = receiver, .name = last } };
                },
                .typeclass => |typeclass| {
                    const declaration = self.loader.modules.items[typeclass.module].declarations[typeclass.declaration];
                    const functions = declaration.kind.typeclass_definition.functions;
                    const position = findSignaturePosition(functions, last) orelse {
                        return self.fail(location, error.UnknownMethod);
                    };
                    return .{ .typeclass_method = .{ .typeclass = typeclass, .function = position } };
                },
                .function, .namespace, .constant, .local, .element, .method, .typeclass_method, .constructor, .case, .builtin => unreachable,
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
            if (local.target != .type and local.target != .typeclass) return null;
            local.use.used = true;
            return local.target;
        }
        if (findTypedName(scope.parameters, last) != null) return null;
        if (std.mem.eql(u8, last, "Self")) return try self.resolveName(location, last);
        const module = self.loader.modules.items[self.module_index];
        const index = findBareDeclaration(module, last) orelse {
            const built_in_type = types.findBuiltInType(last) orelse return null;
            return .{ .type = built_in_type };
        };
        return self.findOwner(self.module_index, index);
    }

    fn findOwner(self: *NameResolver, module_index: usize, index: usize) ResolveError!?Target {
        const target = try self.resolveDeclaration(module_index, index);
        return switch (target) {
            .type, .typeclass => target,
            .function, .namespace, .constant, .local, .element, .method, .typeclass_method, .case, .constructor, .builtin => null,
        };
    }

    fn resolveFirstNamespace(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Namespace {
        if (std.mem.eql(u8, name, ast.module_root)) {
            const module = self.loader.modules.items[self.module_index];
            return .{ .path = module.path, .module = self.module_index, .directory = false };
        }
        if (findLocal(scope.locals, name) != null) return self.fail(location, error.NoMembers);
        if (findTypedName(scope.parameters, name) != null) {
            return self.fail(location, error.NoMembers);
        }
        const module = self.loader.modules.items[self.module_index];
        if (findBareDeclaration(module, name)) |index| {
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
            .enum_definition,
            .typeclass_definition,
            .instance_declaration,
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
        if (findBuiltin(namespace.path, name)) |builtin| return .{ .builtin = builtin };
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
            .enum_definition => .{ .type = try self.resolveEnum(module_index, index) },
            .typeclass_definition => .{ .typeclass = .{ .module = module_index, .declaration = index } },
            .import => self.resolveImport(module_index, index),
            .instance_declaration => unreachable,
        };
    }

    fn resolveImport(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const import = &declaration.kind.import;
        const location = declaration.location;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        const path = import.path;
        var namespace = (try self.loadRoot(path[0])) orelse {
            return self.fail(location, error.ModuleNotFound);
        };
        if (path.len == 1) return .{ .namespace = namespace };
        for (path[1 .. path.len - 1]) |name| {
            namespace = try self.resolveMemberNamespace(location, namespace, name);
        }
        const target = try self.resolveMember(location, namespace, path[path.len - 1]);
        if (target == .typeclass) import.typeclass = target.typeclass;
        return target;
    }

    fn resolveConstant(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const constant = &declaration.kind.constant_declaration;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
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
                try self.expectNotInline(value.location, target);
                return self.expectHeldByConstant(declaration.location, target);
            },
            .path_expression => |path_expression| {
                const path = path_expression.path;
                const target = try self.resolvePath(.{}, declaration.location, path);
                try self.expectNotInline(value.location, target);
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
            .@"try",
            .range,
            .struct_type,
            .member,
            .jump,
            .branching,
            => {
                if (!constant.resolved) {
                    try self.resolveNamesInExpression(.{}, value);
                    constant.resolved = true;
                }
                return own;
            },
        };
    }

    fn expectNotInline(self: *NameResolver, location: token.Location, target: Target) ResolveError!void {
        if (target == .method) {
            const allocator = self.arena.allocator();
            const resolution = try allocator.create(?ast.Resolution);
            resolution.* = null;
            try self.pending.append(allocator, .{
                .resolution = resolution,
                .method = target.method,
                .location = location,
                .module = self.module_index,
                .value = true,
            });
            return;
        }
        if (target != .function) return;
        const module = self.loader.modules.items[target.function.module];
        const declaration = ast.findDeclaration(module, target.function.declaration);
        if (declaration.kind != .function_definition) return;
        if (declaration.kind.function_definition.signature.@"inline") return self.fail(location, error.InlineValue);
    }

    fn expectHeldByConstant(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) NameError!Target {
        if (target == .namespace) return self.fail(location, error.ModuleInConstant);
        return target;
    }

    fn resolveEnum(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!types.Type {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const definition = &declaration.kind.enum_definition;
        if (definition.value) |value_type| return value_type;
        if (definition.kind == .enumeration and definition.cases.len == 0) {
            return self.failIn(module_index, declaration.location, error.EmptyEnum);
        }
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        const allocator = self.arena.allocator();
        const enumeration = try allocator.create(types.Enum);
        const parts = try allocator.alloc(*const types.Enum, 1);
        parts[0] = enumeration;
        const cases = try allocator.alloc(types.Case, definition.cases.len);
        enumeration.* = .{
            .module = module_index,
            .path = self.loader.modules.items[module_index].path,
            .position = index,
            .name = definition.name,
            .kind = definition.kind,
            .cases = cases,
            .parts = parts,
        };
        const value_type: types.Type = .{ .@"enum" = enumeration };
        definition.value = value_type;
        self.self_type = value_type;
        self.self_name = "Self";
        const first_tag = if (definition.kind == .error_set) self.types.tags else 0;
        for (definition.cases, cases, 0..) |case, *resolved, position| {
            for (definition.cases[0..position]) |earlier| {
                if (std.mem.eql(u8, earlier.name, case.name)) return self.fail(case.location, error.DuplicateCase);
            }
            const module = self.loader.modules.items[module_index];
            if (isReservedName(module.path, case.name)) return self.fail(case.location, error.ReservedName);
            resolved.* = .{
                .name = case.name,
                .type = null,
                .declaring = enumeration,
                .tag = first_tag + position,
                .location = case.location,
            };
        }
        if (definition.kind == .error_set) self.types.tags += cases.len;
        for (definition.cases, cases) |*case, *resolved| {
            const written = if (case.type) |*written| written else continue;
            try self.resolveNamesInExpression(.{}, written);
            resolved.type = try self.expectRuntimeType(written);
            if (types.containsEnum(resolved.type.?, enumeration)) return self.fail(declaration.location, error.EnumContainsItself);
        }
        try self.types.add(allocator, value_type);
        return value_type;
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
        const caller_self_name = self.self_name;
        const caller_typeclass = self.typeclass;
        const caller_bindings = self.bindings;
        self.module_index = module_index;
        self.self_type = null;
        self.typeclass = null;
        self.bindings = &.{};
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        defer self.self_name = caller_self_name;
        defer self.typeclass = caller_typeclass;
        defer self.bindings = caller_bindings;
        const resolved = try reserveFields(self.arena.allocator(), definition.fields);
        const struct_type: types.Struct = .{
            .module = module_index,
            .name = definition.name,
            .external = definition.external,
            .fields = resolved,
        };
        const value_type: types.Type = .{ .@"struct" = struct_type };
        definition.value = value_type;
        self.self_type = value_type;
        self.self_name = "Self";
        try self.resolveFields(definition.fields, resolved);
        if (definition.external) try self.expectExternalFields(definition.fields);
        try self.expectNotContained(struct_type, declaration.location);
        try self.types.add(self.arena.allocator(), value_type);
        return value_type;
    }

    fn expectExternalFields(self: *NameResolver, fields: []const ast.Field) NameError!void {
        for (fields) |field| {
            if (!isExternalFieldType(ast.extractType(field.type))) return self.fail(field.type.location, error.NotExternalField);
        }
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
        describeFields(fields, resolved);
    }

    fn loadRoot(self: *NameResolver, name: []const u8) ResolveError!?Namespace {
        const namespace = self.loader.loadRoot(self.arena, self.io, name) catch |load_error| {
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
    CallInArrayLength,
    AnyInExternalFunction,
    InlineValue,
    ReservedImport,
    NotExternalField,
    InternalStructInExternalFunction,
    ManyVoidPointer,
    NotAssignable,
    MethodIsField,
    MethodIsCase,
    DuplicateCase,
    DuplicateEnum,
    EnumContainsItself,
    UnknownMethod,
    AmbiguousMethod,
    DuplicateTypeclass,
    DuplicateImport,
    NamedLikeModule,
    ImportNotMember,
    ModuleUsedAsValue,
    ModuleInConstant,
    NotATypeclass,
    TypeclassUsedAsValue,
    NotInTypeclass,
    MismatchedTypeclassFunction,
    CompileTimeTypeclassParameter,
    MissingRequiredInstance,
    TypeclassArgumentCount,
    NoInstance,
    AmbiguousInstance,
    UndecidedInstance,
    ConstructorMismatch,
    MissingTypeclassFunction,
    DuplicateInstance,
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
    UnusedDeclaredType,
    UnusedLoopName,
    UnusedValueName,
    NotCase,
    EmptyEnum,
    BuiltinUsedAsValue,
    MissingLanguageDeclaration,
    TupleInstance,
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
    value: bool = false,
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
    measurable: []const ast.TypedName = &.{},
    measurable_uses: []ast.Use = &.{},

    fn restrictToTypes(self: Scope) Scope {
        if (self.parameters.len == 0) return .{ .locals = self.locals, .measurable = self.measurable, .measurable_uses = self.measurable_uses };
        return .{ .locals = self.locals, .measurable = self.parameters, .measurable_uses = self.parameter_uses };
    }

    fn exposeMeasurable(self: Scope) Scope {
        return .{ .locals = self.locals, .parameters = self.measurable, .parameter_uses = self.measurable_uses };
    }
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
    typeclass_method: ast.Resolution.TypeclassFunction,
    typeclass: ast.Resolution.Typeclass,
    constructor: types.Constructor,
    case: ast.Resolution.Case,
    builtin: ast.Builtin,
};

const Dependency = struct {
    roots: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,
    dropped: std.ArrayList([]const u8) = .empty,
    returns: bool = false,
    removed: bool = false,

    fn names(self: Dependency) Names {
        return .{ .roots = self.roots.items, .values = self.values.items, .returns = self.returns };
    }
};

const Names = struct {
    roots: []const []const u8 = &.{},
    values: []const []const u8 = &.{},
    returns: bool = false,
};

const NamedInstance = struct {
    typeclass: ast.Resolution.Typeclass,
    arguments: []const types.Argument,
};

const Instantiated = struct {
    function: ast.Resolution.Function,
    arguments: []const types.Argument,
    result: ast.Resolution.Function,
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
        error.InlineValue => "an inline function cannot be used as a value",
        error.AnyInExternalFunction => "an external function cannot have an 'any' parameter",
        error.CallInArrayLength => "the length of an array in a type cannot come from a call, since nothing runs there",
        error.ReservedImport => "an import cannot make a reserved name available, use 'as' to name it",
        error.NotExternalField => "an external struct's fields must be numbers, bool, pointers, optional pointers, function pointers, arrays of these or external structs",
        error.InternalStructInExternalFunction => "a struct in an external function's parameters or return type must be an external struct",
        error.ManyVoidPointer => "*Many(void) is not allowed, use *void",
        error.NotAssignable => "only variables and their fields can be assigned",
        error.MethodIsCase => "function has the name of a case",
        error.DuplicateCase => "case is already defined",
        error.DuplicateEnum => "enum is already defined",
        error.EnumContainsItself => "enum contains itself",
        error.MethodIsField => "method has the name of a field",
        error.UnknownMethod => "unknown method",
        error.AmbiguousMethod => "method is found in more than one place",
        error.DuplicateTypeclass => "typeclass is already defined",
        error.DuplicateImport => "name is already defined",
        error.NamedLikeModule => "name is already used by a module or directory",
        error.ImportNotMember => "an import is not a member of its module",
        error.ModuleUsedAsValue => "a module cannot be used here",
        error.ModuleInConstant => "a constant cannot hold a module, use import",
        error.NotATypeclass => "not a typeclass",
        error.TypeclassUsedAsValue => "a typeclass cannot be used here",
        error.NotInTypeclass => "function is not in the typeclass",
        error.MismatchedTypeclassFunction => "function does not match the typeclass",
        error.CompileTimeTypeclassParameter => "typeclass functions cannot take comptime parameters",
        error.MissingRequiredInstance => "type has no instance of a typeclass that the typeclass requires",
        error.TypeclassArgumentCount => "wrong number of typeclass arguments",
        error.NoInstance => "type has no instance of the typeclass",
        error.AmbiguousInstance => "more than one instance fits",
        error.UndecidedInstance => "name the instance, the arguments do not decide it",
        error.ConstructorMismatch => "argument does not match the type constructor",
        error.MissingTypeclassFunction => "instance is missing a function of the typeclass",
        error.DuplicateInstance => "typeclass already has an instance for these arguments",
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
        error.ManyFunctionPointer => "a function pointer is written *fn(...), not *Many(fn(...))",
        error.ConstantFunctionPointer => "a function pointer is written without Const",
        error.DuplicateLabel => "label is already used by an enclosing loop",
        error.UnusedLabel => "label is unused",
        error.UnknownLabel => "label does not name an enclosing loop",
        error.BreakOutsideLoop => "break outside a loop",
        error.ContinueOutsideLoop => "continue outside a loop",
        error.UnusedDeclaredType => "a declared type must appear in a parameter's type",
        error.UnusedLoopName => "loop name is unused, use _",
        error.UnusedValueName => "value name is unused, use _",
        error.NotCase => "not a case",
        error.EmptyEnum => "an enum needs at least one case",
        error.BuiltinUsedAsValue => "built-in functions can only be called",
        error.MissingLanguageDeclaration => "mn is missing a declaration the language needs",
        error.TupleInstance => "the compiler provides the instances of mn::Tuple",
        error.DependencyLoop => "value depends on itself at compile time",
    };
}

fn isExternalFieldType(value_type: types.Type) bool {
    return switch (value_type) {
        .number, .boolean, .pointer => true,
        .optional => |optional| optional.child == .pointer,
        .array => |array| isExternalFieldType(array.element),
        .@"struct" => |struct_type| struct_type.external,
        .void, .type, .@"enum", .slice, .result, .tuple, .function, .variable, .application => false,
    };
}

fn containsInternalStruct(value_type: types.Type) bool {
    return switch (value_type) {
        .@"struct" => |struct_type| !struct_type.external,
        .pointer => |pointer| containsInternalStruct(pointer.target),
        .array => |array| containsInternalStruct(array.element),
        .slice => |slice| containsInternalStruct(slice.element),
        .optional => |optional| optional.child == .pointer and containsInternalStruct(optional.child),
        .number, .boolean, .void, .type, .@"enum", .result, .tuple, .function, .variable, .application => false,
    };
}

fn isArrayLengthAccess(expression: ast.Expression) bool {
    if (expression.kind != .field_access) return false;
    const access = expression.kind.field_access;
    if (!std.mem.eql(u8, access.field, "length")) return false;
    return switch (access.value.kind) {
        inline .identifier, .path_expression => |name| hasKnownType(name.resolution),
        else => false,
    };
}

fn hasKnownType(resolution: ?ast.Resolution) bool {
    const resolved = resolution orelse return false;
    return switch (resolved) {
        .parameter, .constant => true,
        .local => |statement| switch (statement.kind) {
            .constant_declaration => |constant| constant.type != null or constant.value.type != null,
            .variable_declaration => |variable| variable.type != null or variable.value.type != null,
            else => false,
        },
        .function, .type, .element, .typeclass_function, .typeclass_method, .case, .builtin => false,
    };
}

fn isMeasuredParameter(scope: Scope, expression: ast.Expression) bool {
    if (expression.kind != .field_access) return false;
    const access = expression.kind.field_access;
    if (!std.mem.eql(u8, access.field, "length") or access.value.kind != .identifier) return false;
    const name = access.value.kind.identifier.name;
    if (findLocal(scope.locals, name) != null) return false;
    const index = findTypedName(scope.measurable, name) orelse return false;
    return types.followPointer(ast.extractType(scope.measurable[index].type)) == .array;
}

fn isVisibleName(scope: Scope, name: []const u8) bool {
    return findLocal(scope.locals, name) != null or findTypedName(scope.parameters, name) != null;
}

fn isCall(expression: *const ast.Expression) bool {
    return expression.kind == .call;
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
        .result => |result| isRuntimeType(result.value),
        .tuple => |tuple| areRuntimeTypes(tuple.elements),
        .number, .boolean, .void, .type, .@"struct", .@"enum", .variable, .application => true,
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
    for ([_][]const u8{ "void", "Self", "Const", "Many" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return !isStandardLibrary(module_path) and hasReservedPrefix(name);
}

fn isReservedDeclarationName(module_path: ast.Path, kind: ast.DeclarationKind, name: []const u8) bool {
    return switch (kind) {
        .function_definition, .function_declaration, .struct_definition, .enum_definition => {
            return !isStandardLibrary(module_path) and hasReservedPrefix(name);
        },
        .constant_declaration, .typeclass_definition, .instance_declaration, .import => isReservedName(module_path, name),
    };
}

fn findBareDeclaration(module: ast.Module, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "void")) return null;
    return findDeclaration(module, name);
}

fn isKeywordName(name: []const u8) bool {
    return keywords.has(name);
}

fn isStandardLibrary(path: ast.Path) bool {
    return std.mem.eql(u8, path[0], "mn");
}

fn findDeclaration(module: ast.Module, name: []const u8) ?usize {
    for (module.declarations, 0..) |declaration, index| {
        if (isMethod(declaration)) continue;
        if (declaration.kind == .instance_declaration) continue;
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
    const signature = declaration.kind.function_definition.signature;
    return signature.receiver != null or signature.typeclass != null;
}

fn extractName(declaration: ast.Declaration) []const u8 {
    return switch (declaration.kind) {
        .function_definition => |function| function.signature.name,
        .function_declaration => |function_declaration| function_declaration.name,
        .constant_declaration => |constant| constant.name,
        .struct_definition => |definition| definition.name,
        .enum_definition => |definition| definition.name,
        .typeclass_definition => |definition| definition.name,
        .import => |import| import.name,
        .instance_declaration => unreachable,
    };
}

fn dropDependent(
    allocator: std.mem.Allocator,
    dependency: *Dependency,
    body: []ast.Statement,
) std.mem.Allocator.Error![]ast.Statement {
    var kept: std.ArrayList(ast.Statement) = .empty;
    for (body) |statement| {
        if (isDependentStatement(dependency.names(), statement)) {
            try collectStatementNames(allocator, &dependency.dropped, statement);
            switch (statement.kind) {
                .constant_declaration => |constant| try dependency.roots.append(allocator, constant.name),
                .variable_declaration => |variable| try dependency.roots.append(allocator, variable.name),
                .tuple_declaration => |declaration| {
                    for (declaration.names) |name| try dependency.roots.append(allocator, name.name);
                },
                .noop,
                .@"return",
                .discard,
                .call,
                .assignment,
                .@"if",
                .@"while",
                .@"for",
                .match,
                .@"defer",
                .@"break",
                .@"continue",
                .value,
                => {},
            }
            dependency.removed = true;
            continue;
        }
        var copy = statement;
        switch (copy.kind) {
            .@"if" => |*conditional| {
                conditional.body = try dropDependent(allocator, dependency, conditional.body);
                if (conditional.else_body) |else_body| conditional.else_body = try dropDependent(allocator, dependency, else_body);
            },
            .@"while" => |*loop| {
                loop.body = try dropDependent(allocator, dependency, loop.body);
                if (loop.else_body) |else_body| loop.else_body = try dropDependent(allocator, dependency, else_body);
            },
            .@"for" => |*loop| {
                loop.body = try dropDependent(allocator, dependency, loop.body);
                if (loop.else_body) |else_body| loop.else_body = try dropDependent(allocator, dependency, else_body);
            },
            .match => |*matching| {
                matching.branches = try allocator.dupe(ast.Branch, matching.branches);
                for (matching.branches) |*branch| branch.body = try dropDependent(allocator, dependency, branch.body);
            },
            .constant_declaration => |constant| {
                if (mentionsAny(dependency.values.items, constant.value)) try dependency.values.append(allocator, constant.name);
            },
            .variable_declaration => |variable| {
                if (mentionsAny(dependency.values.items, variable.value)) try dependency.values.append(allocator, variable.name);
            },
            .noop, .@"return", .discard, .call, .tuple_declaration, .assignment, .@"defer", .@"break", .@"continue", .value => {},
        }
        try kept.append(allocator, copy);
    }
    return kept.items;
}

fn isDependentStatement(names: Names, statement: ast.Statement) bool {
    return switch (statement.kind) {
        .noop, .@"break", .@"continue" => false,
        .@"return" => |value| if (value) |returned| names.returns or isDependentExpression(names, returned, false) else false,
        .discard, .call, .value => |expression| isDependentExpression(names, expression, false),
        .constant_declaration => |constant| isDependentDeclaration(names, constant.type, constant.value),
        .variable_declaration => |variable| isDependentDeclaration(names, variable.type, variable.value),
        .tuple_declaration => |declaration| isDependentExpression(names, declaration.value, false),
        .assignment => |assignment| isDependentExpression(names, assignment.target, false) or
            isDependentExpression(names, assignment.value, false),
        .@"if" => |conditional| isDependentExpression(names, conditional.condition, false) or
            (conditional.names.len == 0 and mentionsAny(names.values, conditional.condition)),
        .@"while" => |loop| isDependentExpression(names, loop.condition, false),
        .@"for" => |loop| switch (loop.sequence) {
            .value => |value| isDependentExpression(names, value, false),
            .range => |range| isDependentExpression(names, range.start, false) or
                (if (range.end) |end| isDependentExpression(names, end, false) else false),
        },
        .match => |matching| isDependentExpression(names, matching.value, false) or isDependentMatch(names, matching),
        .@"defer" => |deferred| isDependentStatement(names, deferred.statement.*),
    };
}

fn isDependentBranching(names: Names, statement: ast.Statement) bool {
    if (isDependentStatement(names, statement)) return true;
    var blocks = ast.iterateBlocks(statement);
    while (blocks.next()) |block| {
        for (block) |inner| {
            if (isDependentBranching(names, inner)) return true;
        }
    }
    return false;
}

fn isDependentMatch(names: Names, matching: ast.Match) bool {
    for (matching.branches) |branch| {
        for (branch.cases) |case| {
            if (case.pattern.kind != .identifier and isDependentExpression(names, case.pattern, false)) return true;
            if (case.end) |end| {
                if (isDependentExpression(names, end, false)) return true;
            }
        }
    }
    return false;
}

fn isDependentDeclaration(names: Names, written: ?ast.Expression, value: ast.Expression) bool {
    if (written) |written_type| {
        if (isDependentExpression(names, written_type, true)) return true;
    }
    return isDependentExpression(names, value, false);
}

fn isDependentExpression(names: Names, expression: ast.Expression, in_type: bool) bool {
    return switch (expression.kind) {
        .integer_literal, .float_literal, .boolean_literal, .string_literal, .undefined, .null => false,
        .identifier => |identifier| isDependentName(names, identifier.name, in_type),
        .path_expression => |path_expression| isDependentName(names, path_expression.path[0], in_type),
        .member => |member| isDependentExpression(names, member.owner.*, true),
        .call => |call| {
            switch (call.callee) {
                .identifier => |identifier| if (isDependentName(names, identifier.name, false)) return true,
                .path_expression => |path_expression| if (isDependentName(names, path_expression.path[0], false)) return true,
                .member => |member| if (isDependentExpression(names, member.owner.*, true)) return true,
            }
            return areDependentArguments(names, call.arguments, true);
        },
        .method_call => |call| isDependentExpression(names, call.receiver.*, in_type) or
            areDependentArguments(names, call.arguments, true),
        .negation, .address_of, .dereference, .unwrap, .@"try" => |operand| isDependentExpression(names, operand.*, in_type),
        .range => |range| isDependentExpression(names, range.start, in_type) or
            (if (range.end) |end| isDependentExpression(names, end, in_type) else false),
        .unary => |unary| isDependentExpression(names, unary.operand.*, in_type),
        .binary => |binary| isDependentExpression(names, binary.left.*, in_type) or
            isDependentExpression(names, binary.right.*, in_type),
        .array_type => |array_type| isDependentExpression(names, array_type.element.*, true) or
            (if (array_type.length) |length| isDependentExpression(names, length.*, true) else false),
        .slice_type => |slice_type| isDependentExpression(names, slice_type.element.*, true),
        .pointer_type => |pointer_type| isDependentExpression(names, pointer_type.target.*, true),
        .optional_type => |optional_type| isDependentExpression(names, optional_type.child.*, true),
        .tuple_type => |tuple_type| areDependentExpressions(names, tuple_type.elements),
        .function_type => |function_type| areDependentExpressions(names, function_type.parameters) or
            isDependentExpression(names, function_type.return_type.*, true),
        .composite_literal => |literal| (if (literal.type) |literal_type| isDependentExpression(names, literal_type.*, true) else false) or
            areDependentArguments(names, literal.elements, in_type),
        .index => |indexing| isDependentExpression(names, indexing.value.*, in_type) or
            isDependentExpression(names, indexing.index.*, in_type),
        .slice => |slice| isDependentExpression(names, slice.value.*, in_type) or
            (if (slice.start) |start| isDependentExpression(names, start.*, in_type) else false) or
            (if (slice.end) |end| isDependentExpression(names, end.*, in_type) else false),
        .field_access => |access| isDependentExpression(names, access.value.*, in_type),
        .jump => |statement| switch (statement.kind) {
            .@"return" => |value| if (value) |returned| names.returns or isDependentExpression(names, returned, in_type) else false,
            else => false,
        },
        .branching => |statement| isDependentBranching(names, statement.*),
        .struct_type => |struct_type| {
            for (struct_type.fields) |field| {
                if (isDependentExpression(names, field.type, true)) return true;
            }
            return false;
        },
    };
}

fn isDependentName(names: Names, name: []const u8, in_type: bool) bool {
    if (containsName(names.roots, name)) return true;
    return in_type and containsName(names.values, name);
}

fn areDependentExpressions(names: Names, expressions: []const ast.Expression) bool {
    for (expressions) |expression| {
        if (isDependentExpression(names, expression, true)) return true;
    }
    return false;
}

fn areDependentArguments(names: Names, arguments: []const ast.Argument, in_type: bool) bool {
    for (arguments) |argument| {
        if (isDependentExpression(names, argument.value, in_type)) return true;
    }
    return false;
}

fn mentionsAny(names: []const []const u8, expression: ast.Expression) bool {
    return isDependentExpression(.{ .roots = names }, expression, false);
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn collectStatementNames(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    statement: ast.Statement,
) std.mem.Allocator.Error!void {
    switch (statement.kind) {
        .noop, .@"break", .@"continue" => {},
        .@"defer" => |deferred| try collectStatementNames(allocator, names, deferred.statement.*),
        .@"return" => |value| if (value) |returned| try collectExpressionNames(allocator, names, returned),
        .discard, .call, .value => |expression| try collectExpressionNames(allocator, names, expression),
        .constant_declaration => |constant| {
            if (constant.type) |written| try collectExpressionNames(allocator, names, written);
            try collectExpressionNames(allocator, names, constant.value);
        },
        .variable_declaration => |variable| {
            if (variable.type) |written| try collectExpressionNames(allocator, names, written);
            try collectExpressionNames(allocator, names, variable.value);
        },
        .tuple_declaration => |declaration| try collectExpressionNames(allocator, names, declaration.value),
        .assignment => |assignment| {
            try collectExpressionNames(allocator, names, assignment.target);
            try collectExpressionNames(allocator, names, assignment.value);
        },
        .@"if" => |conditional| {
            try collectExpressionNames(allocator, names, conditional.condition);
            for (conditional.body) |inner| try collectStatementNames(allocator, names, inner);
            for (conditional.else_body orelse &.{}) |inner| try collectStatementNames(allocator, names, inner);
        },
        .@"while" => |loop| {
            try collectExpressionNames(allocator, names, loop.condition);
            for (loop.body) |inner| try collectStatementNames(allocator, names, inner);
            for (loop.else_body orelse &.{}) |inner| try collectStatementNames(allocator, names, inner);
        },
        .@"for" => |loop| {
            switch (loop.sequence) {
                .value => |value| try collectExpressionNames(allocator, names, value),
                .range => |range| {
                    try collectExpressionNames(allocator, names, range.start);
                    if (range.end) |end| try collectExpressionNames(allocator, names, end);
                },
            }
            for (loop.body) |inner| try collectStatementNames(allocator, names, inner);
            for (loop.else_body orelse &.{}) |inner| try collectStatementNames(allocator, names, inner);
        },
        .match => |matching| {
            try collectExpressionNames(allocator, names, matching.value);
            for (matching.branches) |branch| {
                for (branch.cases) |case| {
                    if (case.pattern.kind != .identifier) try collectExpressionNames(allocator, names, case.pattern);
                    if (case.end) |end| try collectExpressionNames(allocator, names, end);
                }
                for (branch.body) |inner| try collectStatementNames(allocator, names, inner);
            }
        },
    }
}

fn collectExpressionNames(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    expression: ast.Expression,
) std.mem.Allocator.Error!void {
    switch (expression.kind) {
        .integer_literal, .float_literal, .boolean_literal, .string_literal, .undefined, .null => {},
        .identifier => |identifier| try names.append(allocator, identifier.name),
        .path_expression => |path_expression| try names.append(allocator, path_expression.path[0]),
        .member => |member| try collectExpressionNames(allocator, names, member.owner.*),
        .call => |call| {
            switch (call.callee) {
                .identifier => |identifier| try names.append(allocator, identifier.name),
                .path_expression => |path_expression| try names.append(allocator, path_expression.path[0]),
                .member => |member| try collectExpressionNames(allocator, names, member.owner.*),
            }
            for (call.arguments) |argument| try collectExpressionNames(allocator, names, argument.value);
        },
        .method_call => |call| {
            try collectExpressionNames(allocator, names, call.receiver.*);
            for (call.arguments) |argument| try collectExpressionNames(allocator, names, argument.value);
        },
        .negation, .address_of, .dereference, .unwrap, .@"try" => |operand| try collectExpressionNames(allocator, names, operand.*),
        .range => |range| {
            try collectExpressionNames(allocator, names, range.start);
            if (range.end) |end| try collectExpressionNames(allocator, names, end);
        },
        .unary => |unary| try collectExpressionNames(allocator, names, unary.operand.*),
        .binary => |binary| {
            try collectExpressionNames(allocator, names, binary.left.*);
            try collectExpressionNames(allocator, names, binary.right.*);
        },
        .composite_literal => |literal| {
            for (literal.elements) |element| try collectExpressionNames(allocator, names, element.value);
        },
        .index => |indexing| {
            try collectExpressionNames(allocator, names, indexing.value.*);
            try collectExpressionNames(allocator, names, indexing.index.*);
        },
        .slice => |slice| {
            try collectExpressionNames(allocator, names, slice.value.*);
            if (slice.start) |start| try collectExpressionNames(allocator, names, start.*);
            if (slice.end) |end| try collectExpressionNames(allocator, names, end.*);
        },
        .field_access => |access| try collectExpressionNames(allocator, names, access.value.*),
        .array_type => |array_type| {
            try collectExpressionNames(allocator, names, array_type.element.*);
            if (array_type.length) |length| try collectExpressionNames(allocator, names, length.*);
        },
        .slice_type => |slice_type| try collectExpressionNames(allocator, names, slice_type.element.*),
        .pointer_type => |pointer_type| try collectExpressionNames(allocator, names, pointer_type.target.*),
        .optional_type => |optional_type| try collectExpressionNames(allocator, names, optional_type.child.*),
        .tuple_type => |tuple_type| {
            for (tuple_type.elements) |element| try collectExpressionNames(allocator, names, element);
        },
        .function_type => |function_type| {
            for (function_type.parameters) |parameter| try collectExpressionNames(allocator, names, parameter);
            try collectExpressionNames(allocator, names, function_type.return_type.*);
        },
        .struct_type => |struct_type| {
            for (struct_type.fields) |field| try collectExpressionNames(allocator, names, field.type);
        },
        .jump => |statement| switch (statement.kind) {
            .@"return" => |value| if (value) |returned| try collectExpressionNames(allocator, names, returned),
            else => {},
        },
        .branching => |statement| try collectStatementNames(allocator, names, statement.*),
    }
}

fn containsFunctionVariable(arguments: []const types.Argument) bool {
    for (arguments) |argument| {
        if (argument == .type and types.containsVariable(argument.type, .function)) return true;
    }
    return false;
}

fn isSameArguments(one: []const types.Argument, two: []const types.Argument) bool {
    if (one.len != two.len) return false;
    for (one, two) |one_argument, two_argument| {
        if (!std.meta.eql(one_argument, two_argument)) return false;
    }
    return true;
}

fn findBinding(bindings: []const ast.Binding, name: []const u8) ?ast.Binding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding;
    }
    return null;
}

fn hasVariableBindings(bindings: []const ast.Binding) bool {
    for (bindings) |binding| {
        switch (binding.target) {
            .type => |value_type| if (value_type == .variable or value_type == .application) return true,
            .constructor => |constructor| if (constructor == .variable) return true,
            .constant => {},
        }
    }
    return false;
}

fn containsTarget(body: []const ast.Statement, target: *const ast.Statement) bool {
    for (body) |*statement| {
        if (statement == target) return true;
        if (ast.findBranching(statement)) |inner| {
            if (containsTarget(inner[0..1], target)) return true;
        }
        var blocks = ast.iterateBlocks(statement.*);
        while (blocks.next()) |block| {
            if (containsTarget(block, target)) return true;
        }
    }
    return false;
}

fn findBuiltin(path: ast.Path, name: []const u8) ?ast.Builtin {
    if (!isLanguageModule(path[0])) return null;
    const builtin = std.meta.stringToEnum(ast.Builtin, name) orelse return null;
    const namespace = findBuiltinNamespace(builtin) orelse {
        if (path.len == 1) return builtin;
        return null;
    };
    if (path.len == 2 and std.mem.eql(u8, path[1], namespace)) return builtin;
    return null;
}

fn findBuiltinNamespace(builtin: ast.Builtin) ?[]const u8 {
    return switch (builtin) {
        .length, .join => "reflection",
        .@"error" => "comptime",
        .add_wrapping, .subtract_wrapping, .multiply_wrapping => "math",
        .size, .alignment, .convert, .truncate, .cast, .@"align" => null,
    };
}

fn findCase(receiver: types.Type, name: []const u8) ?ast.Resolution.Case {
    if (receiver != .@"enum" or !types.isDeclaredEnum(receiver.@"enum")) return null;
    for (receiver.@"enum".cases, 0..) |case, index| {
        if (std.mem.eql(u8, case.name, name)) return .{ .enumeration = receiver.@"enum", .index = index };
    }
    return null;
}

fn isOwnParameters(arguments: []const types.Argument) bool {
    for (arguments, 0..) |argument, index| {
        const variable = switch (argument) {
            .type => |value_type| if (value_type == .variable) value_type.variable else return false,
            .constructor => |constructor| if (constructor == .variable) constructor.variable else return false,
        };
        if (variable.scope != .typeclass or variable.index != index) return false;
    }
    return true;
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

fn bindSelf(allocator: std.mem.Allocator, bindings: []const ast.Binding, value_type: types.Type) std.mem.Allocator.Error![]ast.Binding {
    const bound = try allocator.alloc(ast.Binding, bindings.len + 1);
    @memcpy(bound[0..bindings.len], bindings);
    bound[bindings.len] = .{ .name = "Self", .target = .{ .type = value_type } };
    return bound;
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const ast.Field) std.mem.Allocator.Error![]ast.Field {
    const cloned = try allocator.alloc(ast.Field, fields.len);
    for (fields, cloned) |*field, *clone| clone.* = try ast.cloneField(allocator, field.*);
    return cloned;
}

fn describeFields(fields: []ast.Field, resolved: []types.Field) void {
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
    const constant: ast.ConstantDeclaration = .{ .name = name, .value = value, .resolved = true, .known = known, .bound = true };
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
    allocator: std.mem.Allocator,
    signature: ast.FunctionSignature,
    expected: ast.FunctionSignature,
    instance_arguments: []const types.Argument,
) std.mem.Allocator.Error!bool {
    if (signature.parameters.len != expected.parameters.len) return false;
    for (signature.parameters, expected.parameters) |parameter, expected_parameter| {
        if (parameter.kind != expected_parameter.kind) return false;
    }
    const assigned = try allocator.alloc(?types.Argument, instance_arguments.len);
    for (instance_arguments, assigned) |argument, *slot| slot.* = argument;
    for (signature.parameters, expected.parameters) |parameter, expected_parameter| {
        const parameter_type = ast.extractType(parameter.type);
        const expected_type = ast.extractType(expected_parameter.type);
        if (!types.matchType(expected_type, parameter_type, .typeclass, assigned, true)) return false;
    }
    const return_type = ast.extractType(signature.return_type);
    return types.matchType(ast.extractType(expected.return_type), return_type, .typeclass, assigned, true);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = _ = add(1, 2)\nfn add(left: i32, right: i32) -> i32\n    _ = left\n    return right" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn stdout_write(text: []Const(u8))\nfn main() = stdout_write(\"hi\")" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nfn one() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nconst one = two" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nstruct one" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn size() -> i32 = return 1\nconst size: i32 = 2" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn Point() = noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects a constant named like a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nconst Shape: i32 = 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mn_write() = noop" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: []Const(u8))\nconst write = mn_runtime_stdout_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main() = mn::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolveModule: rejects void as the name of a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const void: i32 = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects Self as the name of a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Self: i32 = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects two typeclasses with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\ntypeclass Shape(type T)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateTypeclass, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveModule: rejects an import named like a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add() = noop\nimport utils::add" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw() = noop\nfn circle() = noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main() = shapes::circle()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn circle() = noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils::circle" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::circle\nfn main() = circle::area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "resolveTypeclass: rejects Self in a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(shape: Self) -> i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, analyzer.failure.?.location.?);
}

test "resolveTypeclass: rejects a comptime parameter of a typeclass function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Sized(type T)\n    fn size(comptime count: usize, value: T) -> usize" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CompileTimeTypeclassParameter, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, analyzer.failure.?.location.?);
}

test "resolveTypeclass: resolves a typeclass of a module that is resolved later" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nstruct Square\n    side: i32\ninstance shapes::Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const shapes = loader.modules.items[1].declarations[0].kind.typeclass_definition;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(shapes.functions[0].return_type));
}

test "resolveTypeclass: resolves a call through a named instance in a default to the function of the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const definition = loader.modules.items[0].declarations[0].kind.typeclass_definition;
    const call = definition.defaults[2].?.body[0].kind.@"return".?.kind.call;
    const function: ast.Resolution.TypeclassFunction = .{ .typeclass = .{ .module = 0, .declaration = 0 }, .function = 1 };
    try std.testing.expectEqual(ast.Resolution{ .typeclass_function = function }, call.callee.member.resolution.?);
}

test "addDefaults: adds a default for an instance that leaves it out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::unit()\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n    fn unit() -> Square = return Square{side = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(6, declarations.len);
    try std.testing.expectEqualSlices(usize, &.{5}, declarations[2].kind.instance_declaration.defaults);
    const default = declarations[5].kind.function_definition;
    try std.testing.expectEqualStrings("make", default.signature.name);
    try std.testing.expectEqual(ast.Resolution.Typeclass{ .module = 0, .declaration = 0 }, default.default_of.?);
    try std.testing.expectEqual(declarations[1].kind.struct_definition.value.?, ast.extractType(default.signature.return_type));
}

test "addDefaults: leaves out a default that the instance defines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::unit()\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n    fn unit() -> Square = return Square{side = 1}\n    fn make() -> Square = return Square{side = 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(6, declarations.len);
    try std.testing.expectEqual(0, declarations[2].kind.instance_declaration.defaults.len);
}

test "addDefaults: lets a length call typeclass methods given by a default and by a written function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [count()]i32) = _ = values\nfn count() -> usize\n    const square = Square{side = 1}\n    return square.sides() + square.corners()\ntypeclass Shape(type T)\n    fn sides(_: T) -> usize\n    fn corners(self: T) -> usize = return self.sides()\nstruct Square\n    side: usize\ninstance Shape(Square)\n    fn sides(_: Square) -> usize = return 4" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(8, ast.extractType(parameters[0].type).array.length);
}

test "resolveInstance: accepts an instance of a typeclass for a struct that a call gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nfn Box(type T) -> type\n    return struct\n        side: T\ninstance Shape(Box(i32))\n    fn area(self: Box(i32)) -> i32 = return self.side\nconst BOX = Box(i32){side = 3}\nconst AREA = BOX.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[5].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 3 }, known);
}

test "resolveInstance: rejects a type for a type constructor parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Container(type F(type))\n    fn size(value: F(i32)) -> usize\nfn Box(type T) -> type\n    return struct\n        value: T\ninstance Container(i32)\n    fn size(value: i32) -> usize = return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstructorMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 20 }, analyzer.failure.?.location.?);
}

test "resolveInstance: rejects a constructor that takes another number of types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Container(type F(type))\n    fn size(value: F(i32)) -> usize\nfn Box(type T) -> type\n    return struct\n        value: T\nfn Pair(type A, type B) -> type\n    return struct\n        one: A\n        two: B\ninstance Container(Pair)\n    fn size(value: Pair(i32, i32)) -> usize = return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstructorMismatch, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 10, .column = 20 }, analyzer.failure.?.location.?);
}

test "resolveInstance: rejects a wrong number of typeclass arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Convert(type From, type To)\n    fn convert(value: From) -> To\nstruct Celsius\n    degrees: i32\nstruct Fahrenheit\n    degrees: i32\ninstance Convert(Celsius, Fahrenheit)\n    fn convert(value: Celsius) -> Fahrenheit = return Fahrenheit{degrees = value.degrees * 9 / 5 + 32}\ninstance Convert(Celsius)\n    fn convert(value: Celsius) -> Celsius = return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeclassArgumentCount, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveInstance: resolves the typeclass and the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const instance_declaration = loader.modules.items[0].declarations[2].kind.instance_declaration;
    try std.testing.expectEqual(ast.Resolution.Typeclass{ .module = 0, .declaration = 0 }, instance_declaration.resolved.?);
    try std.testing.expectEqualStrings("Square", instance_declaration.resolved_arguments[0].type.@"struct".name);
}

test "resolveInstance: rejects a function that is not in the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n    fn grow(self: Square) = _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotInTypeclass, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: rejects a function that does not match the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> bool\n        _ = self\n        return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTypeclassFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: matches the typeclass parameter with the instance type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn merge(self: T, others: []Const(T)) -> T\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn merge(self: Square, others: []Const(Square)) -> Square\n        _ = others\n        return self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const merge = loader.modules.items[0].declarations[3].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Square", ast.extractType(merge.return_type).@"struct".name);
}

test "resolveInstance: matches the typeclass parameter behind a pointer with the instance type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn grow(self: T, other: *Const(T))\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn grow(self: Square, other: *Const(Square))\n        _ = self\n        _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const grow = loader.modules.items[0].declarations[3].kind.function_definition.signature;
    const pointer = ast.extractType(grow.parameters[1].type).pointer;
    try std.testing.expectEqualStrings("Square", pointer.target.@"struct".name);
}

test "resolveInstance: rejects a pointer of another mutability than the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn grow(self: T, other: *Const(T))\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn grow(self: Square, other: *Square)\n        _ = self\n        _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTypeclassFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: rejects Self in an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Self) -> i32 = return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: rejects an instance function whose own type parameters do not match the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Mapper(type F(type))\n    fn map(type A, type B, value: F(A), function: *fn(A) -> B) -> F(B)\nfn Box(type T) -> type\n    return struct\n        value: T\ninstance Mapper(Box)\n    fn map(type A, type B, value: Box(A), function: *fn(A) -> B) -> Box(A) = return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTypeclassFunction, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 5 }, analyzer.failure.?.location.?);
}

test "resolveInstance: rejects an instance without an instance of a required typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Eq(type T)\n    fn equal(one: T, two: T) -> bool\ntypeclass Ord(type T: Eq)\n    fn less(one: T, two: T) -> bool\n    fn at_most(one: T, two: T) -> bool = return Ord::less(one, two) or one.equal(two)\ninstance Eq(i32)\n    fn equal(one: i32, two: i32) -> bool = return one == two\ninstance Ord(bool)\n    fn less(one: bool, two: bool) -> bool = return one and !two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MissingRequiredInstance, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 8, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveInstance: rejects a missing function of the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MissingTypeclassFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: accepts leaving out a function with a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32 = return self.area() * 2\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveInstance: rejects a missing function without a default next to a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn double(self: T) -> i32 = return self.area() * 2\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn double(self: Square) -> i32 = return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MissingTypeclassFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveInstance: compares next with the Element of the same instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nstruct Countdown\n    count: u32\ninstance mn::Iterator(Countdown)\n    fn Element() -> type = return [u32]\n    fn next(iterator: *Countdown) -> ?Element()\n        if (iterator.count == 0) return null\n        iterator.count -= 1\n        return {iterator.count + 1}\nconst Element = mn::Iterator(Countdown)::Element()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const element = loader.modules.items[0].declarations[5].kind.constant_declaration.known.?.type;
    try std.testing.expectEqual(types.Type{ .number = .u32 }, element.tuple.elements[0]);
}

test "resolveInstance: rejects next with another type than Element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nstruct Countdown\n    count: u32\ninstance mn::Iterator(Countdown)\n    fn Element() -> type = return [u32]\n    fn next(_: *Countdown) -> ?[u8] = return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MismatchedTypeclassFunction, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, analyzer.failure.?.location.?);
}

test "resolveInstance: rejects an instance of mn::Tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\ninstance mn::Tuple(i32)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TupleInstance, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, analyzer.failure.?.location.?);
}

test "expandTupleLoop: resolves a copy of the block for each element of a tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count(pair: [i32, bool]) -> usize\n    var seen: usize = 0\n    for value in pair\n        const copy = value\n        _ = copy\n        seen += 1\n    return seen\nconst COUNT = count({1, true})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const expansions = body[1].kind.@"for".expansions;
    try std.testing.expectEqual(2, expansions.len);
    const second = expansions[1][1].kind.constant_declaration.value;
    try std.testing.expectEqual(&expansions[1][0], second.kind.identifier.resolution.?.local);
    try std.testing.expectEqual(types.Type.boolean, second.type.?);
    try std.testing.expectEqual(Value{ .integer = 2 }, loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*);
}

test "expectTypeclass: rejects an instance of something that is not a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Square\n    side: i32\ninstance Square(Square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotATypeclass, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, name_resolver.failure.?.location.?);
}

test "expectSingleInstances: accepts an instance whose arguments a repeated parameter cannot match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Eq(type T)\n    fn equal(one: T, two: T) -> bool\ninstance(type A) Eq([A, A])\n    fn equal(_: [A, A], _: [A, A]) -> bool = return true\ninstance Eq([i32, u8])\n    fn equal(_: [i32, u8], _: [i32, u8]) -> bool = return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const instance_declaration = loader.modules.items[0].declarations[3].kind.instance_declaration;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, instance_declaration.resolved_arguments[0].type.tuple.elements[1]);
}

test "expectSingleInstances: rejects an instance whose arguments a repeated parameter matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Eq(type T)\n    fn equal(one: T, two: T) -> bool\ninstance(type A) Eq([A, A])\n    fn equal(_: [A, A], _: [A, A]) -> bool = return true\ninstance Eq([i32, i32])\n    fn equal(_: [i32, i32], _: [i32, i32]) -> bool = return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateInstance, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 1 }, analyzer.failure.?.location.?);
}

test "expectSingleInstances: accepts instances whose parameters would have to contain themselves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Eq(type T)\n    fn equal(one: T, two: T) -> bool\ninstance(type A) Eq([A, A])\n    fn equal(_: [A, A], _: [A, A]) -> bool = return true\nfn List(type T) -> type\n    return struct\n        first: T\ninstance(type B) Eq([B, List(B)])\n    fn equal(_: [B, List(B)], _: [B, List(B)]) -> bool = return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const instance_declaration = loader.modules.items[0].declarations[4].kind.instance_declaration;
    try std.testing.expectEqual(2, instance_declaration.resolved_arguments[0].type.tuple.elements.len);
}

test "expectSingleInstances: rejects an instance that a generic instance covers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Show(type T)\n    fn show(value: T) -> i32\n    fn twice(value: T) -> i32 = return Show::show(value) * 2\ninstance Show(i32)\n    fn show(value: i32) -> i32 = return value\nfn List(type T) -> type\n    return struct\n        first: T\ninstance(type A: Show) Show(List(A))\n    fn show(value: List(A)) -> i32 = return Show::show(value.first) + 1\ninstance Show(List(u8))\n    fn show(_: List(u8)) -> i32 = return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateInstance, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 11, .column = 1 }, analyzer.failure.?.location.?);
}

test "expectSingleInstances: accepts instances that differ in one of several arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Convert(type From, type To)\n    fn convert(value: From) -> To\nstruct Celsius\n    degrees: i32\nstruct Fahrenheit\n    degrees: i32\ninstance Convert(Celsius, Fahrenheit)\n    fn convert(value: Celsius) -> Fahrenheit = return Fahrenheit{degrees = value.degrees * 9 / 5 + 32}\ninstance Convert(Celsius, i32)\n    fn convert(value: Celsius) -> i32 = return value.degrees" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const instance_declaration = loader.modules.items[0].declarations[5].kind.instance_declaration;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, instance_declaration.resolved_arguments[1].type);
}

test "expectSingleInstances: rejects a second instance of a typeclass for a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateInstance, name_resolver.resolve());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    question: []Const(u8)\n    fn show(self: Self) -> []Const(u8) = return self.question" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.receiver.?).@"struct".name);
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.parameters[0].type).@"struct".name);
}

test "resolveFunctionSignature: resolves Self in a method of mn::fs reached after the file's reader instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::fs\nimport mn::io\nimport mn::io::Reader\n\nfn size(path: []Const(u8)) -> io::Error!usize\n    const file = fs::File::open(path) catch return 0\n    defer file.close()\n    var buffer: [64]u8 = undefined\n    const count = try file.read(&buffer)\n    return count + try file.length()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const files = for (loader.modules.items) |module| {
        if (std.mem.eql(u8, module.path[module.path.len - 1], "fs")) break module;
    } else unreachable;
    const length = for (files.declarations) |declaration| {
        if (declaration.kind != .function_definition) continue;
        if (std.mem.eql(u8, declaration.kind.function_definition.signature.name, "length")) break declaration.kind.function_definition;
    } else unreachable;
    try std.testing.expect(ast.extractType(length.signature.parameters[0].type) == .@"struct");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn size(values: [count()]usize) -> usize\n    _ = values\n    return 1\nfn count() -> usize\n    const values = [1]usize{1}\n    return size(values)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DependencyLoop, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 12 }, analyzer.failure.?.location.?);
}

test "resolveConstraints: takes a typeclass through a module path and an imported name as the type of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nimport shapes::Show as Display\nfn first(value: shapes::Show) -> i32 = return value.show()\nfn second(value: Display) -> i32 = return Display::show(value)\nconst ONE = first(4i32) + second(5i32)" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "typeclass Show(type T)\n    fn show(value: T) -> i32\ninstance Show(i32)\n    fn show(value: i32) -> i32 = return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[4].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 9 }, known);
}

test "resolveConstraints: rejects a typeclass with two parameters as the type of a parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Convert(type A, type B)\n    fn convert(value: A) -> B\nfn show(value: Convert) = _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeclassArgumentCount, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 16 }, name_resolver.failure.?.location.?);
}

test "resolveDeclaredTypes: rejects a declared type that appears in no parameter's type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn(type Item, type Unused) count(items: []Const(Item)) -> usize = return items.length" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedDeclaredType, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 20 }, analyzer.failure.?.location.?);
}
test "resolveMemberFunction: reaches only functions of the struct's block through the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(shape: T) -> i32\n    fn unit() -> T\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(shape: Square) -> i32 = return shape.side\n    fn unit() -> Square = return Square{side = 1}\nfn main() = _ = Square::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 17 }, analyzer.failure.?.location.?);
}

test "findNamedInstance: rejects a wrong number of typeclass arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(shape: T) -> i32\n    fn unit() -> T\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(shape: Square) -> i32 = return shape.side\n    fn unit() -> Square = return Square{side = 1}\nfn main() = _ = Shape(Square, Square)::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeclassArgumentCount, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 17 }, analyzer.failure.?.location.?);
}

test "resolveInstanceFunction: rejects a named instance of a type without an instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(shape: T) -> i32\n    fn unit() -> T\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(shape: Square) -> i32 = return shape.side\n    fn unit() -> Square = return Square{side = 1}\nstruct Circle\n    radius: i32\nfn main() = _ = Shape(Circle)::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoInstance, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 11, .column = 17 }, analyzer.failure.?.location.?);
}

test "resolveInstanceFunction: names an instance of a typeclass with several parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Convert(type From, type To)\n    fn convert(value: From) -> To\nstruct Celsius\n    degrees: i32\nstruct Fahrenheit\n    degrees: i32\ninstance Convert(Celsius, Fahrenheit)\n    fn convert(value: Celsius) -> Fahrenheit = return Fahrenheit{degrees = value.degrees * 9 / 5 + 32}\ninstance Convert(Celsius, i32)\n    fn convert(value: Celsius) -> i32 = return value.degrees\nconst HOT = Convert(Celsius, i32)::convert(Celsius{degrees = 100})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[7].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 100 }, known);
}

test "resolveInstanceFunction: finds a function that is not a method through a named instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn new() -> T\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn new() -> Square = return Square{side = 1}\nfn main() = _ = Shape(Square)::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.member;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, callee.resolution.?);
}
test "resolveInstanceFunction: finds a default function through a named instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::unit()\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n    fn unit() -> Square = return Square{side = 1}\nfn main() = _ = Shape(Square)::make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.member;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 6 } }, callee.resolution.?);
}
test "resolveInstanceFunction: rejects a function that the typeclass does not have through a named instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::other()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 29 }, name_resolver.failure.?.location.?);
}
test "expectUniqueMethod: rejects a function with the name of a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    end\n    fn end(self: Self) -> bool = return true\nfn take(token: Token) -> bool = return token.end()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MethodIsCase, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, analyzer.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    fn show(self: Self) = _ = self\n    fn show(self: Self) = _ = self" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One\n    fn show(self: Self) = _ = self\nstruct Two\n    fn show(self: Self) = _ = self" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    fn new() -> Card = return Card{}\nfn new() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    question: []Const(u8)\n    fn question(self: Self) = _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MethodIsField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveFunctionBody: resolves a call through a named instance in a default to the function of the instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn unit() -> T\n    fn make() -> T = return Shape(T)::unit()\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\n    fn unit() -> Square = return Square{side = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const default = loader.modules.items[0].declarations[5].kind.function_definition;
    const call = default.body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 4 } }, call.callee.member.resolution.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box\n    count: usize\n    fn size(self: Self) -> usize = return self.count\nfn make() -> usize\n    const box = Box{count = 2}\n    return box.size()\nfn main()\n    const values: [make()]i32 = {1, 2}\n    _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    fn new() -> Card = return Card{}\nfn main() = _ = Card::new()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\nfn main() = _ = Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "cards.mn", .data = "struct Card\n    fn new() -> Card = return Card{}" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import cards\nfn main() = _ = cards::Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    const module = loader.modules.items[callee.resolution.?.function.module];
    try std.testing.expectEqualStrings("cards", module.path[0]);
}

test "resolvePendingMethod: chooses the function of the struct's block over a typeclass's function through the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\n    fn area(self: Self) -> i32 = return self.side\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\nfn main() = _ = Square::area(Square{side = 1})" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: i32) -> bool\n    _ = value\n    return true" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: Integer) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(letter: char, text: string) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct char\nstruct string\nfn show(letter: char, text: string)\n    _ = letter\n    _ = text" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add() -> 5 = noop\nfn main() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: i32, value: i32) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(_: i32, _: bool) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(mn_value: i32) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(i32: i32) -> i32 = return i32" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: 5) = noop\nfn main() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: void) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: fn(i32)) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn get() -> fn() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data\n    callback: fn()\nfn show(data: Data) = _ = data" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: ?fn()) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: [2]fn()) = _ = callbacks" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: []fn()) = _ = callbacks" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(pair: [i32, fn()]) = _ = pair" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(fn())) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(maybe: ?*fn(), all: [2]*fn())\n    _ = maybe\n    _ = all" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn(i32) -> i32\nfn apply(callback: *Callback) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn(i32) -> i32\nfn apply(callback: Callback) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const One = struct\n    value: i32\nconst Two = struct\n    value: i32\nfn take(one: One, two: Two)\n    _ = one\n    _ = two" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Box(type T) -> type\n    return struct\n        value: T\nfn take(one: Box(i32), two: Box(i32), three: Box(u8))\n    _ = one\n    _ = two\n    _ = three" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Link(type A) -> type\n    return struct\n        value: A\n        next: ?*Self\nfn take(link: Link(i32)) = _ = link" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type\n    return struct\n        value: A\n        next: ?*Node(A)\nfn take(node: Node(i32)) = _ = node" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type\n    return struct\n        next: Node(A)\nfn take(node: Node(i32)) = _ = node" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Node(type A) -> type\n    return struct\n        next: [2]Self\nfn take(node: Node(i32)) = _ = node" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Nested(type A) -> type\n    return struct\n        next: ?*Nested([A, A])\nfn take(value: Nested(i32)) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Counter(type T) -> type\n    return struct\n        count: T = 0\n        fn new() -> Self = return {}\n        fn add(self: *Self, amount: T) = self.count += amount\n        fn read(self: Self) -> T = return self.count\nfn total() -> i64\n    var counter = Counter(i64)::new()\n    counter.add(5)\n    return counter.read()\nconst TOTAL = total()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Box(type T) -> type\n    return struct\n        value: T\n        fn value(self: Self) -> T = return self.value\nfn take(box: Box(i32)) = _ = box" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type = return i32\nfn first(value: Number()) -> i32 = return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const kinds = [2]type{i32, bool}\nfn first(value: kinds[1]) -> bool = return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const kinds = [type, type]{i32, bool}\nfn first(value: kinds[0]) -> i32 = return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type = return i32\nconst Kind = Number()\nconst LENGTH: usize = 3\nfn take(values: [LENGTH]Kind, maybe: ?Kind, pointer: *Kind, pair: [Kind, bool])\n    _ = values\n    _ = maybe\n    _ = pointer\n    _ = pair" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Number() -> type = return i32\nfn main()\n    const Kind = Number()\n    var value: Kind = 1\n    value += 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> usize = return 1\nfn first(value: count()) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    const limit = 5i32\n    take(limit)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32\n    _ = value\n    const value = 5i32\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    const value = 1i32\n    _ = value\n    const value = 2i32\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn get() -> i32\n    const u8 = 5i32\n    return u8" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write(value: i32)\nfn main() = write(1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(_: i32) = noop\nfn main() = show(1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = const limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    const value = 1i32\n    const value = 2i32\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    var count = 1i32\n    return count" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var count = 1i32\n    count = 2i32" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn show(value: i32) = _ = value\nfn main()\n    var point = Point{x = 1}\n    point.x = 2\n    show(point.x)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8) = _ = bytes\nfn main()\n    var buffer: [4]u8 = undefined\n    fill(buffer[..])" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var values = [2]i32{1, 2}\n    values[0] = 3\n    const copy = values\n    _ = copy" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var value = 1i32\n    const pointer = &value\n    _ = pointer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var value = 1i32\n    var pointer = &value\n    pointer.* = 2" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(buffer: [4]u8) = _ = buffer\nfn main()\n    var buffer: [4]u8 = undefined\n    fill(buffer)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter\n    count: i32\n    fn show(self: Self) = _ = self\nfn main()\n    var counter = Counter{count = 1}\n    counter.show()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter\n    count: i32\n    fn increment(self: *Self) = self.count += 1\nstruct Holder\n    counter: Counter\nfn main()\n    var holder = Holder{counter = {count = 1}}\n    holder.counter.increment()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box\n    value: i32\nfn main()\n    var value = 1i32\n    const box = Box{value = value}\n    _ = box" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    while false\n        const limit = 5i32\n        take(limit)\n    take(limit)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    const value = 1i32\n    while false\n        const value = 2i32\n        _ = value\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = while (false) const limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var running = true\n    while running\n        running = false" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var count = 1i32\n    count += 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn main()\n    var point = Point{x = 1}\n    point.x += 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    const one = 1i32\n    if true\n        take(one)\n    else\n        take(one)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    if (true) noop\n    else const unused = 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLocalConstant, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    var count = 0i32\n    if (true) count = 1\n    take(count)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    const one = 1i32\n    while (false) noop\n    else take(one)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    while true\n        while (false) break\n        break" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    while true\n        while (false) noop\n        else break" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pair: [i32, i32])\n    const (first, second) = pair\n    take(first)\n    take(second)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pair: [i32, i32])\n    const (pair, other) = pair\n    take(pair)\n    take(other)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(ast.Resolution{ .parameter = 0 }, body[0].kind.tuple_declaration.value.kind.identifier.resolution.?);
    const shadowed = body[1].kind.call.kind.call.arguments[0].value.kind.identifier.resolution.?;
    try std.testing.expectEqual(&body[0], shadowed.element.statement);
}

test "resolveBranchings: counts a name in a one-line if inside an expression as a use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(one: bool) -> i32\n    const base: i32 = 1\n    return 2 + (if (one) base else 0)\nfn main() = _ = pick(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const conditional = body[1].kind.@"return".?.kind.binary.right.kind.branching.kind.@"if";
    try std.testing.expectEqual(@as(*const ast.Statement, &body[0]), conditional.body[0].kind.value.kind.identifier.resolution.?.local);
}

test "chooseBlock: keeps an empty else block when the condition is known to be true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const DEBUG = true\nfn pick() -> i32\n    if (DEBUG) return 1\n    else return 2\nfn main() = _ = pick()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const conditional = body[0].kind.@"if";
    try std.testing.expectEqual(true, conditional.known.?);
    try std.testing.expectEqual(0, conditional.else_body.?.len);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pair: [i32, i32])\n    const (first, second) = pair\n    take(first)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pair: [i32, i32])\n    const (_, second) = pair\n    take(second)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pair: [i32, i32])\n    const (first, second) = pair\n    _ = first\n    take(second)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var pair = [i32, i32]{1, 2}\n    const (*first, _) = pair\n    first.* = 3" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var values = [2]i32{1, 2}\n    for (*value in values) value.* = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expectEqual(null, name_resolver.failure);
}

test "resolveNamesInStatement: resolves the names of a deferred statement where it is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    var total: i32 = 0\n    defer take(total)\n    total = 5" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const arguments = body[1].kind.@"defer".statement.kind.call.kind.call.arguments;
    try std.testing.expectEqual(&body[0], arguments[0].value.kind.identifier.resolution.?.local);
}

test "chooseBlock: resolves only the block that a condition depending on a type chooses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn total(type T, comptime index: usize) -> usize\n    if (index == mn::reflection::length(T)) return 0\n    else\n        const Element = T[index]\n        return mn::size(Element) + total(T, index + 1)\nconst TOTAL = total([u8, i32, u16], 0)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 7 }, known);
}

test "resolveNamedBody: keeps the name of an if inside its block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(value: ?i64) -> i64\n    if (value as found) return found\n    else return found" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolveNamedBody: rejects an unused name of an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(value: ?i64)\n    if (value as found) noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedValueName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn main()\n    const items = [2]i32{1, 2}\n    for (items in items) take(items)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize) = _ = value\nfn main()\n    const first = 1usize\n    const last = 3usize\n    for (index in first..last) take(index)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while true\n        while (false) continue @outer\n        break @outer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while true\n        @outer while (false) break @outer\n        break @outer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while (false) break @outer\n    else\n        @outer while (false) break @outer\n    @outer while (false) break @outer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while (false) break" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @Self while (false) break @Self" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(items: []Const(i32))\n    for (item in items) take(item)\n    take(item)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(items: []Const(i32))\n    for (item in items) take(item)\n    else take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 15 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step() = noop\nfn show(items: []Const(i32)) = for (item in items) step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLoopName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 37 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step() = noop\nfn main() = for (_ in 0..3) step()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pairs: [][i32, i32])\n    for (first, second) in pairs\n        take(first)\n        take(second)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(pairs: [][i32, i32])\n    for ((first, second) in pairs) take(first)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLoopName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer for _ in 0..3\n        while (false) continue @outer\n        break @outer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while true\n        @outer for (_ in 0..3) break @outer\n        break @outer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer for (_ in 0..3) break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, name_resolver.failure.?.location.?);
}

test "resolveLoop: rejects an unused name of a while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn drain(value: ?i64)\n    while (value as found) noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedLoopName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 21 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(items: []Const(i32)) = for (item in items) take(item)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) = _ = value\nfn show(items: []Const(i32)) = for (mn_item in items) take(mn_item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 37 }, name_resolver.failure.?.location.?);
}

test "resolveBranches: resolves a value name to its branch and a case named through its enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    end\nfn take(value: i64) = _ = value\nfn show(token: Token)\n    match token\n        case (number(digits)) take(digits)\n        case (Token::end) noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const branches = body[0].kind.match.branches;
    const arguments = branches[0].body[0].kind.call.kind.call.arguments;
    const element: ast.Resolution.Element = .{ .statement = &body[0], .position = 0 };
    try std.testing.expectEqual(element, arguments[0].value.kind.identifier.resolution.?.element);
    try std.testing.expectEqual(1, branches[1].cases[0].pattern.kind.path_expression.resolution.?.case.index);
}

test "resolveBranches: rejects an unused value name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    end\nfn show(token: Token)\n    match token\n        case (number(digits)) noop\n        case (end) noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnusedValueName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 22 }, name_resolver.failure.?.location.?);
}

test "resolveBranches: keeps a value name inside its branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    end\nfn take(value: i64) = _ = value\nfn show(token: Token)\n    match token\n        case (number(digits)) take(digits)\n        case (end) take(digits)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 8, .column = 25 }, name_resolver.failure.?.location.?);
}

test "resolveBranches: rejects a name through an enum that is not a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    end\n    fn make() -> Token = return Token::end\nfn show(token: Token)\n    match token\n        case (Token::make) noop\n        else noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotCase, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 15 }, name_resolver.failure.?.location.?);
}

test "isTypeApplication: reads a type constructor applied to a type as a type, not as a value name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError\n    missing\nfn Box(type T) -> type\n    return struct\n        value: T\nfn parse(ready: bool) -> ParseError!Box(i32)\n    if (ready) return Box(i32){value = 3}\n    return ParseError::missing\nfn score(ready: bool) -> i32\n    match parse(ready)\n        case (Box(i32) as box) return box.value\n        case (missing) return 0\nfn check(ready: bool) -> i32\n    match parse(ready)\n        case (Box(i32)) return 1\n        case (missing) return 0\nconst VALUE = score(true)\nconst MISSING = score(false)\nconst CHECKED = check(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    const unnamed = declarations[4].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(.none, unnamed.branches[0].naming);
    try std.testing.expectEqualStrings("Box", unnamed.branches[0].cases[0].pattern.kind.call.callee.identifier.name);
    try std.testing.expectEqualStrings("_", unnamed.names[0].name);
    const named = declarations[3].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(.value, named.branches[0].naming);
    try std.testing.expectEqualStrings("box", named.names[0].name);
}

test "isTypeApplication: keeps a value name of an enum case whose name is not declared and whose value name is not a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    end\nfn Box(type T) -> type\n    return struct\n        value: T\nfn show(token: Token) -> i64\n    match token\n        case (number(digits)) return digits\n        case (end) return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const matching = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.match;
    try std.testing.expectEqual(.payload, matching.branches[0].naming);
    try std.testing.expectEqualStrings("digits", matching.names[0].name);
}

test "resolveBranchCase: resolves a constant and the end of a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const LIMIT: u8 = 10\nfn kind(value: u8) -> u8\n    match value\n        case (LIMIT) return 1\n        case (0..LIMIT) return 2\n        else return 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const branches = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.match.branches;
    try std.testing.expect(branches[0].cases[0].pattern.kind.identifier.resolution.? == .constant);
    try std.testing.expect(branches[1].cases[0].end.?.kind.identifier.resolution.? == .constant);
}

test "resolveCaseName: resolves a type and leaves an undeclared case name to the type checker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError\n    missing\nfn parse() -> ParseError!i64 = return 1\nfn show()\n    match parse()\n        case (i64 as value) _ = value\n        case (missing) noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const branches = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.match.branches;
    try std.testing.expectEqual(types.Type{ .number = .i64 }, branches[0].cases[0].pattern.kind.identifier.resolution.?.type);
    try std.testing.expect(branches[1].cases[0].pattern.kind.identifier.resolution == null);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = break" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.BreakOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    while (false) noop\n    else continue" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ContinueOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    for (_ in 0..3) noop\n    else continue" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ContinueOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    @outer while (false) break @outer\n    while (false) break @outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLabel, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveStatementJumps: resolves a labeled break in a fallback to its loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read() -> ?i32 = return null\nfn main()\n    @outer while true\n        while true\n            const value = read() orelse break @outer\n            _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const inner = body[0].kind.@"while".body[0].kind.@"while";
    const fallback = inner.body[0].kind.constant_declaration.value.kind.binary.right.kind.jump;
    try std.testing.expectEqual(&body[0], fallback.kind.@"break".loop.?);
}

test "resolveStatementJumps: rejects a break in a fallback outside a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read() -> ?i32 = return null\nfn main()\n    const value = read() orelse break\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.BreakOutsideLoop, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 33 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = const mn_limit = 5i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveLocalConstant: rejects Const and Many as names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32\n    const Many = 1i32\n    return Many" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedName, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, analyzer.failure.?.location.?);
}

test "resolveLocalConstant: leaves a call to a struct's function through a path for later and sees the import it shadows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "tools.mn", .data = "struct Maker\n    value: u64\n    fn new(seed: u64) -> Maker = return Maker{value = seed}\nfn seed() -> u64 = return 5" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import tools\nfn main()\n    const tools = tools::Maker::new(tools::seed())\n    _ = tools.value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(null, analyzer.failure);
}

test "resolveLocalConstant: accepts a struct's function through a path in a variable and a typed constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "tools.mn", .data = "struct Maker\n    value: u64\n    fn new(seed: u64) -> Maker = return Maker{value = seed}\nfn seed() -> u64 = return 5" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import tools\nfn main()\n    var made = tools::Maker::new(tools::seed())\n    made.value += 1\n    const typed: tools::Maker = tools::Maker::new(made.value)\n    _ = typed.value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(null, analyzer.failure);
}

test "resolveLocalConstant: evaluates a top-level constant made by a struct's function through a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "tools.mn", .data = "struct Maker\n    value: u64\n    fn new(seed: u64) -> Maker = return Maker{value = seed}\nfn seed() -> u64 = return 5" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import tools\nconst MADE = tools::Maker::new(7)\nfn main() = _ = MADE.value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(Value{ .integer = 7 }, loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.aggregate[0]);
}

test "resolveLocalConstant: reports calling a pointer method on a constant made through a path instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::random\nimport mn::random::Generator\nfn main()\n    const random = random::Xoshiro256::new(random::entropy())\n    _ = random.range(0..10)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotWritable, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 9 }, analyzer.failure.?.location.?);
}

test "resolveLocalConstant: reports a method of a typeclass that is not imported on a constant made through a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::random\nfn main()\n    const random = random::Xoshiro256::new(random::entropy())\n    _ = random.range(0..10)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 16 }, analyzer.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32\n    const copy = value\n    return copy" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn show(value: i32) -> Point\n    const point = Point{x = value}\n    return point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [_]i32 = {1, 2, 3}\nfn all() -> [3]i32 = return values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var values: [_]i32 = {1, 2}\n    values = {3, 4}\n    _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var buffer: [2]i32 = undefined\n    const pointer: *[_]i32 = &buffer\n    _ = pointer" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const maybe: ?[_]i32 = null\n    _ = maybe" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [2][3]i32 = {{1, 2, 3}, {4, 5, 6}}\nconst second: [_][_]i32 = first\nfn all() -> [2][3]i32 = return second" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [2][3]i32 = {{1, 2, 3}, {4, 5, 6}}\nconst second: [2][_]i32 = first\nfn all() -> [2][3]i32 = return second" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var step: fn() = undefined\n    step = step" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nconst step: fn() = one" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nconst steps: [_]fn() = {one}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32) -> i32 = return value\nfn main()\n    const run = take\n    _ = run(1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5i32\nfn show() -> i32\n    const copy = limit\n    return copy" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main()\n    const figures = shapes\n    figures::draw()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    var count = 1i32\n    count = 2i32\n    return count" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn show() -> Point\n    var point = Point{x = 1}\n    point.x = 2\n    return point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var buffer: [2]u8 = undefined\n    const bytes = buffer[..]\n    bytes[0] = 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: []u8, position: usize) = values[position] = 1" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32\n    const count = 1i32\n    count = 2i32\n    return count" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: i32 = 1\nfn main() = limit = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(count: i32) -> i32\n    count = 2\n    return count" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(items: []Const(i32)) = for (item in items) item = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 52 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = missing = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn main()\n    var point = Point{x = 1}\n    point.x = 2" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const limit = 5i32\n    _ = limit" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var count = 1i32\n    count = 2i32\n    _ = count" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(items: []Const(i32)) = for (item in items) _ = item" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5i32\nfn main() = _ = limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotDiscardable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32)\n    _ = value\n    _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32\n    _ = value\n    return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = log(missing)\nfn log(value: i32) = noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolveNamesInExpression: resolves a function of another module used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() -> i32 = return 1" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn value() -> i32 = return utils::add" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn read(point: Point) -> i32 = return point.x" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: []Const(i32), position: usize) -> i32 = return values[position]" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: i32) -> i32 = return (&value).*" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: ?i32) -> i32 = return value.?" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check(count: i32, ready: bool) -> bool = return -count < 0 and !ready" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Values = [3]i32\nfn make() -> Values = return Values{1, 2, 3}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const Pair = [i32, bool]\n    const pair = Pair{1, true}\n    _ = pair" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data\n    value: i32\nfn make() -> Data = return Data{value = 1}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "other.mn", .data = "struct Data\n    value: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import other\nfn make() -> other::Data = return other::Data{value = 1}" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32 = return i32{1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotLiteralType, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make(values: [2]i32) -> [2]i32 = return values{1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotLiteralType, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 44 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const steps = [0]fn(){}\n    _ = steps" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(left: [2]i32, right: [2]i32)\n    _ = left\n    _ = right" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = [2]i32\nfn show(pair: Pair) = _ = pair" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [2]void) = _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[0].type).array.element);
}

test "isMeasuredParameter: takes an array length from the length of an array parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn measure(values: [4]i32, pointer: *[3]u8) -> usize\n    var copy: [values.length]i32 = values\n    var bytes: [pointer.length]u8 = pointer.*\n    copy[0] = 1\n    bytes[0] = 2\n    return copy.length + bytes.length" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(4, ast.extractType(body[0].kind.variable_declaration.type.?).array.length);
    try std.testing.expectEqual(3, ast.extractType(body[1].kind.variable_declaration.type.?).array.length);
}

test "isMeasuredParameter: takes an array length from a parameter whose type depends on a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn measure(type T, values: T) -> usize\n    var copy: [values.length]u8 = undefined\n    copy[0] = 1\n    return copy.length\nconst SIZE = measure([5]i32, {1, 2, 3, 4, 5})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(5, loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.integer);
}

test "isMeasuredParameter: rejects a parameter used otherwise in a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(count: usize)\n    var values: [count]u8 = undefined\n    values[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, analyzer.failure.?.location.?);
}

test "expectLength: rejects the length of an array that comes from a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [3]u8 = return {1, 2, 3}\nfn fill()\n    var values: [make().length]u8 = undefined\n    values[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CallInArrayLength, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, analyzer.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [_]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const grid: [2][_]i32 = {{1}, {2}}\n    _ = grid" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [3usize]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = 4usize\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size: usize = 5\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const size = 2usize\n    const values: [size]i32 = {1, 2}\n    _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [true]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = 2i32\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size: i8 = 2\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = other\nconst other = 2usize\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = true\nfn show(values: [size]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    var size = 2usize\n    size = 3usize\n    var values: [size]i32 = undefined\n    values = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [2u8]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [-2]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZE = 2usize\nfn show(values: [SIZE * 3]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZES = [2]usize{3, 4}\nfn show(values: [SIZES[1]]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Shape\n    sides: usize = 4\nconst SQUARE = Shape{}\nfn show(values: [SQUARE.sides]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SIZE = 18446744073709551615usize\nfn show(values: [SIZE + 1]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [size()]i32) = _ = values\nfn size() -> usize = return 2 * 3" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn size() -> usize\nfn show(values: [size()]i32) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Bytes = []Const(u8)\nfn show(bytes: Bytes) = _ = bytes" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: []void) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []Const(i32), start: usize, end: usize) -> []Const(i32) = return values[start..end]" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8) = _ = bytes\nfn main()\n    var buffer: [4]u8 = undefined\n    take(buffer[..])" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck\n    cards: [2]i32\nfn take(cards: []i32) = _ = cards\nfn main()\n    var deck: Deck = undefined\n    take(deck.cards[..])" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8) = _ = bytes\nfn main()\n    var grid: [2][2]u8 = undefined\n    take(grid[0][..])" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: *Many(Const(u8))) = _ = values" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Bytes = *Many(u8)\nfn show(bytes: Bytes) = _ = bytes" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: *void) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *Const(fn())) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callbacks: *Many(fn())) = _ = callbacks" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Callback = fn()\nfn apply(callback: *Const(Callback)) = _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConstantFunctionPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, name_resolver.failure.?.location.?);
}

test "resolvePointerType: rejects a multiple value pointer to void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(pointer: *Many(void)) = _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ManyVoidPointer, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: ?i32, two: ??i32, three: ?i32)\n    _ = one\n    _ = two\n    _ = three" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Maybe = ?bool\nfn show(value: Maybe) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: [i32, bool], two: [i32, bool], three: [bool, i32])\n    _ = one\n    _ = two\n    _ = three" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = [i32, [bool, u8]]\nfn show(pair: Pair) = _ = pair" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: *fn(i32, bool) -> u8, two: *fn(i32, bool,) -> u8, three: *fn(i32, bool))\n    _ = one\n    _ = two\n    _ = three" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(callback: *fn(void)) = _ = callback" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) -> i32\n    _ = right\n    return left\nfn twice(add: i32) -> i32 = return add" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32 = return missing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nfn two() -> *fn() = return &one" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: f32\n    fn length(self: Self) -> f32 = return self.x\nfn get() -> *fn(Point) -> f32 = return &Point::length" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: f32\n    fn length(self: Self) -> f32 = return self.x\nfn get() -> *fn(Point) -> f32\n    const measure = Point::length\n    return &measure" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[1].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, value.kind.address_of.kind.identifier.resolution.?);
}

test "expectValue: rejects pointing to a function through a typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\nfn main()\n    const area = &Shape::area\n    _ = area" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TypeclassUsedAsValue, name_resolver.resolve());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write()\nfn get() -> *fn() = return &write" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = noop\nfn get() -> *fn() = return &main" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MainUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 29 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = noop\nfn run(value: i32) = _ = value\nfn get() = run(main)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MainUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 16 }, name_resolver.failure.?.location.?);
}

test "expectValue: rejects a module as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn value() -> i32 = return utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = log(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(i32), value: i32) = callback(value)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main()\n    const limit = 5i32\n    limit()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() = noop\nconst step: *fn() = &first\nfn main() = step()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "steps.mn", .data = "fn first(value: i32) -> i32 = return value\nconst step: *fn(i32) -> i32 = &first" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import steps\nfn main() = _ = steps::step(1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const write = add\nfn add() = noop\nfn main() = write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.callee.identifier.resolution.?.function;
    try std.testing.expectEqual(0, function.module);
    try std.testing.expectEqual(1, function.declaration);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data\n    value: i32\nfn make() -> Data = return Data(value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 28 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    fn new() -> Self = return Card{}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.return_type).@"struct".name);
}

test "resolveName: resolves the typeclass parameter to the instance type in a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n    fn copy(self: T) -> T = return self\ninstance Shape([]Const(u8))\n    fn area(self: []Const(u8)) -> i32\n        _ = self\n        return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[3].kind.function_definition.signature;
    try std.testing.expect(ast.extractType(signature.return_type).slice.constant);
}

test "resolveName: rejects Self outside a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: Self) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    next: ?*Self\nfn take(card: Card) = _ = card" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    next: Self\nfn take(card: Card) = _ = card" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct i32\n    count: u8\nfn show(value: i32) -> i32 = return value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const bool: i32 = 5\nfn get() -> i32 = return bool" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32 = return utils" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, name_resolver.failure.?.location.?);
}

test "resolvePath: resolves a case through its enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    word: bool\n    end\n    fn is_end(self: Self) -> bool = return self == Token::end\nfn last() -> Token = return Token::end" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.kind.path_expression.resolution.?.case.index);
}

test "resolvePath: resolves a call through a typeclass to the typeclass's function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\nfn main() = _ = Shape::area(Square{side = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    const method: ast.Resolution.TypeclassFunction = .{ .typeclass = .{ .module = 0, .declaration = 0 }, .function = 0 };
    try std.testing.expectEqual(ast.Resolution{ .typeclass_method = method }, callee.resolution.?);
}

test "resolvePath: rejects a function that the typeclass does not have through the typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side\nfn main() = _ = Shape::size(Square{side = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownMethod, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 17 }, name_resolver.failure.?.location.?);
}

test "resolvePath: resolves a call through a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one() = noop\nfn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils::add()" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main() = mn::stdout::write()" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::stdout\nfn main() = stdout::write()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\n    fn new() -> Self = return Card{}\n    fn copy(self: Self) -> Self\n        _ = self\n        return Self::new()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct i32\n    fn new() -> Self = return i32{}\nfn main() = _ = i32::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, callee.resolution.?);
}

test "resolveFirstNamespace: resolves a path that starts with the separator to a declaration of the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn match(pattern: []Const(u8)) -> bool = return pattern.length > 0\nstruct Point\n    x: i32\nfn make() -> ::Point = return ::Point{x = 1}\nfn main()\n    _ = ::match(\"x\")\n    _ = make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[3].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution.Function{ .module = 0, .declaration = 0 }, callee.resolution.?.function);
}

test "resolveMember: reaches a function with a reserved name in another module through a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "parser.mn", .data = "fn match(pattern: []Const(u8)) -> bool = return pattern.length > 0" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import parser\nfn main()\n    _ = parser::match(\"x\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expect(callee.resolution.? == .function);
}

test "resolveMember: reaches the built-ins through the current module's path inside mn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn.mn", .data = "fn width(type T) -> usize = return ::size(T) + ::alignment(T)\nfn same(pointer: *Const(i32)) -> *i32 = return ::cast(*i32, pointer)" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst WIDTH = mn::width(i64)\nfn main()\n    var value: i32 = 1\n    mn::same(&value).* = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 16 }, known);
}

test "resolveMember: rejects the built-ins through the current module's path outside mn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn width() -> usize = return ::size(i64)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, analyzer.failure.?.location.?);
}

test "resolveModule: rejects an import that makes a reserved name available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::comptime" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedImport, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveModule: rejects an import of a function with a reserved name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "parser.mn", .data = "fn match(pattern: []Const(u8)) -> bool = return pattern.length > 0" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import parser::match" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedImport, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveModule: accepts an import of a reserved name under another name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::comptime as compile\nfn check(comptime flag: bool)\n    if (flag) compile::error(\"bad\")\nfn main() = check(false)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqualStrings("compile", loader.modules.items[0].declarations[0].kind.import.name);
}

test "findBareDeclaration: reaches declarations named void and Self only through a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct void\n    count: i32\n    fn read(self: Self) -> i32 = return self.count\nfn Self() -> ::void = return ::void{count = 2}\nfn nothing() -> void = return\nfn main()\n    _ = ::Self().read()\n    nothing()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(types.Type.void, ast.extractType(declarations[3].kind.function_definition.signature.return_type));
    try std.testing.expect(ast.extractType(declarations[2].kind.function_definition.signature.return_type) == .@"struct");
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(value: i32) = value::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: lets a parameter shadow an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one() = noop\nfn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn run(utils: i32) = utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: lets a local constant shadow an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one() = noop\nfn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main()\n    const utils = 5i32\n    utils::add()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
    try std.testing.expectEqual(1, loader.modules.items.len);
}

test "resolveFirstNamespace: rejects the standard library when it is not imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = mn::stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: rejects members of an imported function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils::add\nfn main() = add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects members of a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils::add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects a module missing from a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main() = mn::missing::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleNotFound, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMemberNamespace: rejects an import of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main() = shapes::utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ImportNotMember, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMember: reaches a declaration of a module and a module in its directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "shapes");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "fn draw() = noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes/circle.mn", .data = "fn area() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main()\n    shapes::draw()\n    shapes::circle::area()" });
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

test "resolveMember: resolves the built-in functions of mn through the module and through an import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::convert\nconst SIZE = mn::size(i32)\nconst SMALL = convert(u8, SIZE)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const declarations = loader.modules.items[0].declarations;
    const size = declarations[2].kind.constant_declaration.value.kind.call.callee.path_expression.resolution.?;
    try std.testing.expectEqual(ast.Resolution{ .builtin = .size }, size);
    const convert = declarations[3].kind.constant_declaration.value.kind.call.callee.identifier.resolution.?;
    try std.testing.expectEqual(ast.Resolution{ .builtin = .convert }, convert);
}

test "resolveMember: rejects a built-in function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn main()\n    const size = mn::size\n    _ = size" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.BuiltinUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, name_resolver.failure.?.location.?);
}

test "resolveMember: resolves the reflection built-ins under mn::reflection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst LENGTH = mn::reflection::length([i32, bool])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.constant_declaration.value;
    try std.testing.expectEqual(ast.Resolution{ .builtin = .length }, value.kind.call.callee.path_expression.resolution.?);
}

test "resolveMember: rejects a reflection built-in directly under mn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst LENGTH = mn::length([i32, bool])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils::math()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMember: rejects a name the module does not declare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = utils::missing()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveMember: rejects an import of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "import utils::add" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn main() = shapes::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ImportNotMember, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveImport: binds the name of the imported typeclass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square\n    side: i32\ninstance Shape(Square)\n    fn area(self: Square) -> i32 = return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const instance_declaration = loader.modules.items[0].declarations[2].kind.instance_declaration;
    const typeclass_module = loader.modules.items[instance_declaration.resolved.?.module];
    try std.testing.expectEqualStrings("shapes", typeclass_module.path[0]);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "typeclass Shape(type T)\n    fn area(self: T) -> i32\n" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\ntypeclass Shape(type T)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateTypeclass, name_resolver.resolve());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import cards::cards\nfn count() -> i32 = return cards" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop\nexternal fn write()\nstruct Point\n    x: i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils::add\nimport utils::write\nimport utils::Point\nfn run(point: Point)\n    add()\n    write()\n    _ = point" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn/io");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/io/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::io::stdout as out\nfn main() = out::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualDeep(@as(ast.Path, &.{ "mn", "io", "stdout" }), loader.modules.items[function.module].path);
}

test "resolveImport: leaves the last name of the path unbound after as" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils as tools\nfn main() = utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, name_resolver.failure.?.location.?);
}

test "resolveImport: binds a name in the whole module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = utils::add()\nimport utils" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = noop\nimport missing" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one = two\nconst two = one\nfn main() = one()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "output.mn", .data = "import mn\nconst write = mn::missing" });
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import output\nfn main() = output::write()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Integer = i32\nfn add(value: Integer) = _ = value" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32 = return limit\nconst limit = other\nconst other = 5i32" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nconst step = &one\nfn main() = step()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nconst origin = Point{x = 0}\nfn make() -> Point = return origin" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: 5i32 = 5\nfn show() -> i32 = return limit" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() = noop\nconst run: *fn() = &one\nfn get() -> *fn() = return run" });
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
    try compiler_directory.dir.createDirPath(std.testing.io, "mn");
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "mn/stdout.mn", .data = "external fn write()" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst stdout = mn::stdout\nfn main() = stdout::write()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nconst tools = utils\nfn main() = tools::math::add()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn add() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nconst plus = utils::add\nfn main() = plus()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const callee = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.callee;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 1, .declaration = 0 } }, callee.identifier.resolution.?);
}

test "resolveEnum: resolves the cases of an enum with their values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    number: i64\n    word: bool\n    end\n    fn is_end(self: Self) -> bool = return self == Token::end\nfn first(token: Token) -> Token = return token" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const enumeration = ast.extractType(loader.modules.items[0].declarations[2].kind.function_definition.signature.return_type).@"enum";
    try std.testing.expectEqual(3, enumeration.cases.len);
    try std.testing.expectEqual(types.Type{ .number = .i64 }, enumeration.cases[0].type.?);
    try std.testing.expectEqual(null, enumeration.cases[2].type);
    try std.testing.expectEqual(enumeration, enumeration.cases[1].declaring);
}

test "resolveEnum: rejects an enum without cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() = noop\nenum Never" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.EmptyEnum, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}

test "resolveEnum: rejects a repeated case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token\n    end\n    end\nfn take(token: Token) = _ = token" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DuplicateCase, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, analyzer.failure.?.location.?);
}

test "resolveEnum: rejects an enum that holds itself without a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Tree\n    leaf\n    node: [2]Tree\nfn take(tree: Tree) = _ = tree" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.EnumContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveEnum: rejects an enum that holds itself through a tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Tree\n    leaf\n    node: [Tree, i32]\nfn take(tree: Tree) = _ = tree" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.EnumContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveEnum: rejects an enum that holds itself through another enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Tree\n    leaf\n    node: Wrap\nenum Wrap\n    tree: Tree\nfn take(tree: Tree) = _ = tree" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.EnumContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveEnum: rejects an enum that holds itself through a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Tree\n    leaf\n    node: Branch\nstruct Branch\n    left: Tree\nfn take(tree: Tree) = _ = tree" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.EnumContainsItself, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, analyzer.failure.?.location.?);
}

test "resolveEnum: accepts an enum that points to itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum List\n    end\n    next: *Const(List)\nfn take(list: List) = _ = list" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const enumeration = ast.extractType(loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type).@"enum";
    try std.testing.expectEqual(enumeration, enumeration.cases[1].type.?.pointer.target.@"enum");
}

test "resolveExternalSignature: rejects an any parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: any)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.AnyInExternalFunction, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, analyzer.failure.?.location.?);
}

test "resolveExternalSignature: rejects a struct that is not external through a slice and a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nexternal fn take(points: []Const(*Point))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InternalStructInExternalFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 26 }, name_resolver.failure.?.location.?);
}

test "resolveExternalSignature: rejects a struct that is not external in an array returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nexternal fn make() -> [2]Point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InternalStructInExternalFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 23 }, name_resolver.failure.?.location.?);
}

test "resolveExternalSignature: accepts external structs and other types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external struct Point\n    x: i32\nenum Token\n    end\nexternal fn take(point: *Point, maybe: ?*Point, token: Token, points: []Point) -> [2]Point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    try std.testing.expect(loader.modules.items[0].declarations[0].kind.struct_definition.value.?.@"struct".external);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nfn show(point: Point) = _ = point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node\n    next: Node\nfn show(node: Node) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One\n    two: Two\nstruct Two\n    one: One\nfn show(one: One) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Node\n    next: ?*Node\nfn take(node: Node) = _ = node" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const node = ast.extractType(loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type).@"struct";
    try std.testing.expect(std.meta.eql(node, node.fields[0].type.optional.child.pointer.target.@"struct"));
}

test "expectExternalFields: accepts numbers, bool, pointers, optional pointers, function pointers, arrays and external structs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external struct Inner\n    value: f64\nstruct Hidden\n    value: u8\nexternal struct Outer\n    count: u128\n    flag: bool\n    pointer: *Hidden\n    maybe: ?*Const(u8)\n    callback: *fn(i32) -> i32\n    values: [4][2]i16\n    inner: Inner\n    inners: [2]Inner\nfn use(outer: Outer) = _ = outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const outer = loader.modules.items[0].declarations[2].kind.struct_definition.value.?.@"struct";
    try std.testing.expect(outer.external);
    try std.testing.expectEqual(8, outer.fields.len);
}

test "expectExternalFields: rejects a slice field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external struct Text\n    bytes: []Const(u8)\nfn use(text: Text) = _ = text" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotExternalField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
}

test "expectExternalFields: rejects a struct that is not external" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Inner\n    value: i32\nexternal struct Outer\n    inner: Inner\nfn use(outer: Outer) = _ = outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotExternalField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, name_resolver.failure.?.location.?);
}

test "expectExternalFields: rejects an optional value that is not a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external struct Outer\n    maybe: ?i32\nfn use(outer: Outer) = _ = outer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotExternalField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\nconst Other = Point\nfn show(point: Point, other: Other)\n    _ = point\n    _ = other" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct One\n    x: i32\nstruct Two\n    x: i32\nfn show(one: One, two: Two)\n    _ = one\n    _ = two" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Line\n    start: Point\n    width: i32\nstruct Point\n    x: i32\nfn show(line: Line) = _ = line" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: missing" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: 5\nfn show(point: Point) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: void\nfn show(point: Point) = _ = point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point\n    x: Missing" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(point: shapes::Point) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    x: i32\n    x: i32\nfn show(point: Point) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point\n    mn_x: i32\nfn show(point: Point) = noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const width = 5i32\nstruct Box\n    size: i32 = width\nfn show(box: Box) = _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const default = type_registry.entries.items[0].@"struct".fields[0].default.?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 0 } }, default.kind.identifier.resolution.?);
}

test "loadRoot: loads a program module named monolith like any other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "monolith.mn", .data = "fn one() = noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import monolith\nfn main() = monolith::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();

    try std.testing.expectEqualStrings("monolith", loader.modules.items[1].path[0]);
}

test "failLoading: reports failures in the module that is loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn one()\n\tnoop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main() = utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnexpectedTab, name_resolver.resolve());
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}
