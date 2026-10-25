const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;
const Loader = @import("loader.zig").Loader;
const LoadError = @import("loader.zig").LoadError;
const Namespace = @import("loader.zig").Namespace;

pub const NameResolver = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    loader: *Loader,
    types: *types.Registry,
    module_index: usize = 0,
    constant_depth: usize = 0,
    self_type: ?types.Type = null,
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
                    try self.resolveMethod(index);
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
                    .trait_definition, .import => error.DuplicateTrait,
                    .implementation => unreachable,
                });
            }
            if (isReservedName(module.path, name)) return self.fail(location, error.ReservedName);
            switch (declaration.kind) {
                .function_definition => |function| {
                    const definition = &module.declarations[index].kind.function_definition;
                    try self.resolveFunctionTypes(&definition.signature);
                    try self.resolveNamesInFunction(function);
                },
                .function_declaration => {
                    const kind = &module.declarations[index].kind;
                    try self.resolveFunctionTypes(&kind.function_declaration);
                },
                .trait_definition => {
                    const module_index = self.module_index;
                    try self.resolveTrait(.{ .module = module_index, .declaration = index });
                },
                .import => _ = try self.resolveImport(self.module_index, index),
                .constant_declaration, .struct_definition, .implementation => {},
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
        self.module_index = trait.module;
        self.self_type = .implementer;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        const functions = definition.functions;
        for (functions, 0..) |*signature, function_index| {
            if (findSignature(functions[0..function_index], signature.name) != null) {
                return self.fail(declaration.location, error.DuplicateFunction);
            }
            try self.resolveFunctionTypes(signature);
        }
    }

    fn resolveImplementation(self: *NameResolver, index: usize) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const declaration = module.declarations[index];
        const implementation = &module.declarations[index].kind.implementation;
        const trait = try self.expectTrait(&implementation.trait);
        implementation.resolved = trait;
        try self.resolveTrait(trait);
        try self.resolveNamesInExpression(.{}, &implementation.type);
        const implemented = try self.expectType(implementation.type);
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
            try self.resolveMethod(function_index);
            const resolved = module.declarations[function_index].kind.function_definition.signature;
            if (!matchesSignature(resolved, expected, implemented)) {
                return self.fail(function.location, error.MismatchedTraitFunction);
            }
        }
        for (signatures) |expected| {
            const found = for (functions) |function| {
                const name = function.kind.function_definition.signature.name;
                if (std.mem.eql(u8, name, expected.name)) break true;
            } else false;
            if (!found) return self.fail(declaration.location, error.MissingTraitFunction);
        }
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

    fn resolveMethod(self: *NameResolver, index: usize) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        const declaration = module.declarations[index];
        const definition = &module.declarations[index].kind.function_definition;
        const signature = &definition.signature;
        if (isReservedName(module.path, signature.name)) {
            return self.fail(declaration.location, error.ReservedName);
        }
        const receiver = &signature.receiver.?;
        try self.resolveNamesInExpression(.{}, receiver);
        const receiver_type = try self.expectType(receiver.*);
        const caller_self_type = self.self_type;
        self.self_type = receiver_type;
        defer self.self_type = caller_self_type;
        if (signature.trait != null) {
            try self.resolveFunctionTypes(signature);
            return self.resolveNamesInFunction(definition.*);
        }
        for (module.declarations[0..index]) |earlier| {
            if (!isMethod(earlier)) continue;
            const earlier_signature = earlier.kind.function_definition.signature;
            if (earlier_signature.trait != null) continue;
            if (!std.mem.eql(u8, earlier_signature.name, signature.name)) continue;
            const earlier_type = ast.extractType(earlier_signature.receiver.?);
            if (std.meta.eql(earlier_type, receiver_type)) {
                return self.fail(declaration.location, error.DuplicateFunction);
            }
        }
        for (receiver_type.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, signature.name)) {
                return self.fail(declaration.location, error.MethodIsField);
            }
        }
        try self.resolveFunctionTypes(signature);
        try self.resolveNamesInFunction(definition.*);
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
            try self.resolveTypedName(parameter.name, parameter.location, &parameter.type, error.VoidParameter);
        }
        try self.resolveNamesInExpression(.{}, &signature.return_type);
        _ = try self.expectType(signature.return_type);
    }

    fn resolveTypedName(
        self: *NameResolver,
        name: []const u8,
        location: token.Location,
        written_type: *ast.Expression,
        void_error: NameError,
    ) ResolveError!void {
        const module = self.loader.modules.items[self.module_index];
        if (isReservedName(module.path, name)) return self.fail(location, error.ReservedName);
        try self.resolveNamesInExpression(.{}, written_type);
        if (try self.expectType(written_type.*) == .void) {
            return self.fail(written_type.location, void_error);
        }
    }

    fn expectType(self: *NameResolver, expression: ast.Expression) NameError!types.Type {
        const written_resolution = switch (expression.kind) {
            inline .identifier, .path_expression => |name| name.resolution,
            .array_type => |array_type| return array_type.value.?,
            .slice_type => |slice_type| return slice_type.value.?,
            .pointer_type => |pointer_type| return pointer_type.value.?,
            .optional_type => |optional_type| return optional_type.value.?,
            .tuple_type => |tuple_type| return tuple_type.value.?,
            .function_type => |function_type| return function_type.value.?,
            else => return self.fail(expression.location, error.TypeMismatch),
        };
        const resolution = written_resolution orelse {
            return self.fail(expression.location, error.TypeMismatch);
        };
        return switch (resolution) {
            .type => |value_type| value_type,
            .parameter, .function, .constant, .local => {
                return self.fail(expression.location, error.TypeMismatch);
            },
        };
    }

    fn resolveNamesInFunction(
        self: *NameResolver,
        function: ast.FunctionDefinition,
    ) ResolveError!void {
        const allocator = self.arena.allocator();
        const parameters = function.signature.parameters;
        const parameter_uses = try allocator.alloc(Use, parameters.len);
        @memset(parameter_uses, .{});
        var locals: std.ArrayList(Local) = .empty;
        const block: Block = .{
            .parameters = parameters,
            .parameter_uses = parameter_uses,
            .locals = &locals,
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
            const mutable = local.statement.kind == .variable_declaration;
            if (mutable and !local.use.assigned) {
                return self.fail(local.location, error.NeverAssigned);
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
            },
            .@"while" => |*loop| {
                try self.resolveNamesInExpression(scope, &loop.condition);
                try self.resolveNamesInBlock(block, loop.body);
            },
        }
        return null;
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
        if (value.kind == .@"struct") return self.fail(value.location, error.StructInFunction);
        if (constant.type) |*written| {
            try self.resolveWrittenType(scope, written, value.*);
        } else if (try self.findAlias(scope, value)) |target| {
            return target;
        }
        try self.resolveNamesInExpression(scope, value);
        return .{ .local = statement };
    }

    fn resolveWrittenType(
        self: *NameResolver,
        scope: Scope,
        written_type: *ast.Expression,
        value: ast.Expression,
    ) ResolveError!void {
        if (written_type.kind == .array_type and value.kind == .composite_literal) {
            const length = value.kind.composite_literal.elements.len;
            const array_type = &written_type.kind.array_type;
            return self.resolveArrayType(scope, written_type.location, array_type, length);
        }
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, written_type);
        _ = try self.expectType(written_type.*);
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
            .function, .type, .namespace, .method, .trait => target,
            .constant, .local => null,
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
                    local.use.assigned = true;
                    identifier.resolution = .{ .local = local.statement };
                    return;
                }
                if (findTypedName(scope.parameters, identifier.name) == null) {
                    _ = try self.resolveName(target.location, identifier.name);
                }
                return self.fail(target.location, error.NotAssignable);
            },
            .field_access => |access| try self.resolveTarget(scope, access.value),
            else => return self.fail(target.location, error.NotAssignable),
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
            identifier.resolution = .{ .local = local.statement };
            return;
        }
        if (findTypedName(scope.parameters, identifier.name)) |index| {
            try self.recordDiscard(&scope.parameter_uses[index], location);
            identifier.resolution = .{ .parameter = index };
            return;
        }
        return self.fail(location, error.NotDiscardable);
    }

    fn recordDiscard(self: *NameResolver, use: *Use, location: token.Location) NameError!void {
        if (use.discard != null) return self.fail(location, error.PointlessDiscard);
        use.discard = location;
    }

    fn expectUsed(
        self: *NameResolver,
        use: Use,
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
            .integer_literal, .float_literal, .boolean_literal, .character_literal, .string_literal, .undefined, .null => {},
            .identifier => |*identifier| try self.resolveIdentifier(scope, location, identifier),
            .path_expression => |*path_expression| {
                const target = try self.resolvePath(scope, location, path_expression.path);
                try self.resolveValue(location, target, &path_expression.resolution);
            },
            .call => |*call| {
                try self.resolveCallee(scope, location, &call.callee);
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(scope, &argument.value);
                }
            },
            .method_call => |*call| {
                try self.resolveNamesInExpression(scope, call.receiver);
                for (call.arguments) |*argument| {
                    try self.resolveNamesInExpression(scope, &argument.value);
                }
            },
            .negation => |operand| try self.resolveNamesInExpression(scope, operand),
            .struct_literal => |literal| {
                for (literal.arguments) |*argument| {
                    try self.resolveNamesInExpression(scope, &argument.value);
                }
            },
            .array_type => |*array_type| {
                try self.resolveArrayType(scope, location, array_type, null);
            },
            .composite_literal => |literal| {
                if (literal.type) |literal_type| {
                    try self.resolveLiteralType(scope, literal_type, literal.elements.len);
                }
                for (literal.elements) |*element| try self.resolveNamesInExpression(scope, element);
            },
            .slice_type => |*slice_type| try self.resolveSliceType(scope, slice_type),
            .slice => |slice| try self.resolveSlice(scope, slice.value),
            .pointer_type => |*pointer_type| try self.resolvePointerType(scope, pointer_type),
            .optional_type => |*optional_type| try self.resolveOptionalType(scope, optional_type),
            .tuple_type => |*tuple_type| try self.resolveTupleType(scope, tuple_type),
            .function_type => |*function_type| try self.resolveFunctionType(scope, function_type),
            .field_access => |access| try self.resolveNamesInExpression(scope, access.value),
            .@"struct" => unreachable,
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
                if (resolution != .type) return self.fail(location, error.NotLiteralType);
                switch (resolution.type) {
                    .array, .tuple => {},
                    .number, .boolean, .character, .string, .void, .type, .@"struct", .slice, .pointer, .optional, .function, .implementer => {
                        return self.fail(location, error.NotLiteralType);
                    },
                }
            },
            else => unreachable,
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
        const element = try self.expectType(array_type.element.*);
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
        const literal = switch (expression.kind) {
            .integer_literal => |literal| literal,
            .identifier, .path_expression => try self.findLengthLiteral(scope, expression),
            else => return self.fail(expression.location, error.InvalidLength),
        };
        if (literal.suffix) |suffix| {
            if (!std.mem.eql(u8, suffix, "usize")) {
                return self.fail(expression.location, error.InvalidLength);
            }
        }
        return std.fmt.parseInt(u64, literal.text, 0) catch {
            return self.fail(expression.location, error.InvalidLength);
        };
    }

    fn findLengthLiteral(
        self: *NameResolver,
        scope: Scope,
        expression: *ast.Expression,
    ) ResolveError!token.NumberLiteral {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, expression);
        const written_resolution = switch (expression.kind) {
            inline .identifier, .path_expression => |name| name.resolution,
            else => unreachable,
        };
        const resolution = written_resolution orelse {
            return self.fail(expression.location, error.InvalidLength);
        };
        const constant = switch (resolution) {
            .constant => |constant| constant: {
                const module = self.loader.modules.items[constant.module];
                break :constant module.declarations[constant.declaration].kind.constant_declaration;
            },
            .local => |statement| switch (statement.kind) {
                .constant_declaration => |constant| constant,
                .noop, .@"return", .discard, .call, .variable_declaration, .assignment, .@"while" => {
                    return self.fail(expression.location, error.InvalidLength);
                },
            },
            .parameter, .function, .type => return self.fail(expression.location, error.InvalidLength),
        };
        if (constant.type) |written| {
            const usize_type: types.Type = .{ .number = .usize };
            if (!std.meta.eql(ast.extractType(written), usize_type)) {
                return self.fail(expression.location, error.InvalidLength);
            }
        }
        if (constant.value.kind != .integer_literal) {
            return self.fail(expression.location, error.InvalidLength);
        }
        return constant.value.kind.integer_literal;
    }

    fn resolveSliceType(
        self: *NameResolver,
        scope: Scope,
        slice_type: *ast.SliceType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, slice_type.element);
        const element = try self.expectType(slice_type.element.*);
        if (element == .void) {
            return self.fail(slice_type.element.location, error.VoidSliceElement);
        }
        const allocator = self.arena.allocator();
        const slice = try self.types.addSlice(allocator, element, slice_type.constant);
        slice_type.value = .{ .slice = slice };
    }

    fn resolveSlice(self: *NameResolver, scope: Scope, value: *ast.Expression) ResolveError!void {
        try self.resolveNamesInExpression(scope, value);
        const root = findSliceRoot(value.*) orelse {
            return self.fail(value.location, error.NotSliceable);
        };
        if (root.kind != .identifier) return;
        const identifier = root.kind.identifier;
        const resolution = identifier.resolution orelse return;
        if (resolution != .local) return;
        const local = findLocal(scope.locals, identifier.name).?;
        if (local.statement.kind == .variable_declaration) local.use.assigned = true;
    }

    fn resolvePointerType(
        self: *NameResolver,
        scope: Scope,
        pointer_type: *ast.PointerType,
    ) ResolveError!void {
        try self.resolveNamesInExpression(.{ .locals = scope.locals }, pointer_type.target);
        const target = try self.expectType(pointer_type.target.*);
        if (target == .void) return self.fail(pointer_type.target.location, error.VoidPointerTarget);
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
        const child = try self.expectType(optional_type.child.*);
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
            element.* = try self.expectType(written.*);
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
            parameter.* = try self.expectType(written.*);
            if (parameter.* == .void) return self.fail(written.location, error.VoidParameter);
        }
        try self.resolveNamesInExpression(type_scope, function_type.return_type);
        const return_type = try self.expectType(function_type.return_type.*);
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
            .function => |function| {
                const module = self.loader.modules.items[function.module];
                const declaration = module.declarations[function.declaration];
                if (ast.isMain(ast.extractFunctionSignature(declaration))) {
                    return self.fail(location, error.MainUsedAsValue);
                }
                return .{ .function = function };
            },
            .method => unreachable,
            .trait => self.fail(location, error.TraitUsedAsValue),
            .namespace => self.fail(location, error.UnknownName),
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
        };
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

    fn expectCallee(
        self: *NameResolver,
        location: token.Location,
        target: Target,
    ) ResolveError!ast.Resolution {
        return switch (target) {
            .function => |function| .{ .function = function },
            .type => |value_type| .{ .type = value_type },
            .local => |local| .{ .local = local },
            .constant => |constant| .{ .constant = constant },
            .namespace, .method, .trait => {
                return self.fail(location, error.NotAFunction);
            },
        };
    }

    fn resolveName(
        self: *NameResolver,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Target {
        if (std.mem.eql(u8, name, "Self")) {
            const self_type = self.self_type orelse return self.fail(location, error.UnknownName);
            return .{ .type = self_type };
        }
        const module = self.loader.modules.items[self.module_index];
        if (findDeclaration(module, name)) |index| {
            return self.resolveDeclaration(self.module_index, index);
        }
        if (types.findBuiltInType(name)) |built_in_type| return .{ .type = built_in_type };
        if (try self.loadRoot(location, name)) |namespace| return .{ .namespace = namespace };
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
                .trait => self.fail(location, error.TraitUsedAsValue),
                .function, .namespace, .constant, .local, .method => unreachable,
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
        var module_index = self.module_index;
        if (prefix.len == 1) {
            if (findLocal(scope.locals, last)) |local| {
                if (local.target != .type and local.target != .trait) return null;
                local.use.used = true;
                return local.target;
            }
            if (findTypedName(scope.parameters, last) != null) return null;
            if (std.mem.eql(u8, last, "Self")) return try self.resolveName(location, last);
            const module = self.loader.modules.items[self.module_index];
            if (findDeclaration(module, last) == null) {
                const built_in_type = types.findBuiltInType(last) orelse return null;
                return .{ .type = built_in_type };
            }
        } else {
            var namespace = try self.resolveFirstNamespace(scope, location, prefix[0]);
            for (prefix[1 .. prefix.len - 1]) |name| {
                namespace = try self.resolveMemberNamespace(location, namespace, name);
            }
            module_index = namespace.module orelse return null;
        }
        const module = self.loader.modules.items[module_index];
        const index = findDeclaration(module, last) orelse return null;
        const target = try self.resolveDeclaration(module_index, index);
        return switch (target) {
            .type, .trait => target,
            .function, .namespace, .constant, .local, .method => null,
        };
    }

    fn resolveFirstNamespace(
        self: *NameResolver,
        scope: Scope,
        location: token.Location,
        name: []const u8,
    ) ResolveError!Namespace {
        const module = self.loader.modules.items[self.module_index];
        if (findLocal(scope.locals, name)) |local| {
            local.use.used = true;
            if (local.target == .namespace) return local.target.namespace;
            return self.fail(location, error.NoMembers);
        }
        if (findTypedName(scope.parameters, name) != null) {
            return self.fail(location, error.NoMembers);
        }
        if (try self.findConstantNamespace(self.module_index, name)) |namespace| return namespace;
        if (try self.loadRoot(location, name)) |namespace| return namespace;
        if (findDeclaration(module, name) != null) return self.fail(location, error.NoMembers);
        if (isBuiltInTypeName(name)) return self.fail(location, error.NoMembers);
        return self.fail(location, error.UnknownName);
    }

    fn resolveMemberNamespace(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Namespace {
        if (namespace.module) |module_index| {
            if (try self.findConstantNamespace(module_index, name)) |target| return target;
        }
        if (try self.loadMember(namespace, name)) |member| return member;
        if (namespace.module) |module_index| {
            if (findDeclaration(self.loader.modules.items[module_index], name) != null) {
                return self.fail(location, error.NoMembers);
            }
        }
        if (namespace.directory) return self.fail(location, error.ModuleNotFound);
        return self.fail(location, error.UnknownName);
    }

    fn resolveMember(
        self: *NameResolver,
        location: token.Location,
        namespace: Namespace,
        name: []const u8,
    ) ResolveError!Target {
        if (namespace.module) |module_index| {
            const module = self.loader.modules.items[module_index];
            if (findDeclaration(module, name)) |index| {
                return self.resolveDeclaration(module_index, index);
            }
        }
        if (try self.loadMember(namespace, name)) |member| return .{ .namespace = member };
        return self.fail(location, error.UnknownName);
    }

    fn findConstantNamespace(
        self: *NameResolver,
        module_index: usize,
        name: []const u8,
    ) ResolveError!?Namespace {
        const module = self.loader.modules.items[module_index];
        const index = findDeclaration(module, name) orelse return null;
        if (module.declarations[index].kind != .constant_declaration) return null;
        return switch (try self.resolveConstant(module_index, index)) {
            .function, .type, .constant, .local, .method, .trait => null,
            .namespace => |namespace| namespace,
        };
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
            .import => .{ .trait = try self.resolveImport(module_index, index) },
            .implementation => unreachable,
        };
    }

    fn resolveImport(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!ast.Resolution.Trait {
        const import = &self.loader.modules.items[module_index].declarations[index].kind.import;
        if (import.resolved) |trait| return trait;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        self.module_index = module_index;
        self.self_type = null;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        const trait = try self.expectTrait(&import.trait);
        import.resolved = trait;
        return trait;
    }

    fn resolveConstant(self: *NameResolver, module_index: usize, index: usize) ResolveError!Target {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const constant = &declaration.kind.constant_declaration;
        if (constant.value.kind == .@"struct") {
            return .{ .type = try self.resolveStruct(module_index, index) };
        }
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        self.module_index = module_index;
        self.self_type = null;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
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
            try self.expectEvaluable(value.*);
            return own;
        }
        return switch (value.kind) {
            .identifier => |identifier| self.resolveName(declaration.location, identifier.name),
            .path_expression => |path_expression| {
                return self.resolvePath(.{}, declaration.location, path_expression.path);
            },
            .integer_literal, .float_literal, .boolean_literal, .character_literal, .string_literal, .undefined, .null => own,
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {
                try self.resolveNamesInExpression(.{}, value);
                return .{ .type = ast.extractType(value.*) };
            },
            .call, .method_call, .negation, .struct_literal, .composite_literal, .slice => {
                if (!constant.resolved) {
                    try self.resolveNamesInExpression(.{}, value);
                    try self.expectEvaluable(value.*);
                    constant.resolved = true;
                }
                return own;
            },
            .field_access => self.fail(value.location, error.CannotEvaluate),
            .@"struct" => unreachable,
        };
    }

    fn expectEvaluable(self: *NameResolver, expression: ast.Expression) NameError!void {
        switch (expression.kind) {
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .character_literal,
            .string_literal,
            .undefined,
            .null,
            .identifier,
            .path_expression,
            => {},
            .call => |call| {
                const resolution = switch (call.callee) {
                    inline else => |name| name.resolution,
                };
                if (resolution == null or resolution.? != .type) {
                    return self.fail(expression.location, error.CannotEvaluate);
                }
                for (call.arguments) |argument| try self.expectEvaluable(argument.value);
            },
            .negation => |operand| try self.expectEvaluable(operand.*),
            .struct_literal => |literal| {
                for (literal.arguments) |argument| try self.expectEvaluable(argument.value);
            },
            .composite_literal => |literal| {
                for (literal.elements) |element| try self.expectEvaluable(element);
            },
            .slice => |slice| try self.expectEvaluable(slice.value.*),
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {},
            .method_call, .field_access => {
                return self.fail(expression.location, error.CannotEvaluate);
            },
            .@"struct" => unreachable,
        }
    }

    fn resolveStruct(
        self: *NameResolver,
        module_index: usize,
        index: usize,
    ) ResolveError!types.Type {
        const declaration = &self.loader.modules.items[module_index].declarations[index];
        const name: []const u8, const body: *ast.Struct = switch (declaration.kind) {
            .struct_definition => |*definition| .{ definition.name, &definition.body },
            .constant_declaration => |*constant| .{ constant.name, &constant.value.kind.@"struct" },
            .function_definition,
            .function_declaration,
            .trait_definition,
            .implementation,
            .import,
            => unreachable,
        };
        if (body.value) |value_type| return value_type;
        const caller_module_index = self.module_index;
        const caller_self_type = self.self_type;
        self.module_index = module_index;
        self.self_type = null;
        defer self.module_index = caller_module_index;
        defer self.self_type = caller_self_type;
        if (body.resolving) return self.fail(declaration.location, error.StructContainsItself);
        body.resolving = true;
        const struct_type: types.Struct = .{
            .module = module_index,
            .name = name,
            .fields = try self.resolveFields(body.fields),
        };
        const value_type: types.Type = .{ .@"struct" = struct_type };
        try self.types.add(self.arena.allocator(), value_type);
        body.value = value_type;
        return value_type;
    }

    fn resolveFields(
        self: *NameResolver,
        fields: []ast.Field,
    ) ResolveError![]const types.Field {
        for (fields, 0..) |*field, index| {
            const discarded = ast.isDiscardedName(field.name);
            if (!discarded and findFieldDeclaration(fields, field.name) != index) {
                return self.fail(field.location, error.DuplicateField);
            }
            try self.resolveTypedName(field.name, field.location, &field.type, error.VoidField);
            if (field.default) |*default| {
                try self.resolveNamesInExpression(.{}, default);
                try self.expectEvaluable(default.*);
            }
        }
        const resolved = try self.arena.allocator().alloc(types.Field, fields.len);
        for (fields, resolved) |*field, *resolved_field| {
            resolved_field.* = .{
                .name = field.name,
                .type = ast.extractType(field.type),
                .default = if (field.default) |*default| default else null,
                .location = field.location,
            };
        }
        return resolved;
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

    fn failLoading(self: *NameResolver, load_error: LoadError) LoadError {
        self.failure = self.loader.failure;
        return load_error;
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

pub const ResolveError = NameError || LoadError;

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
    StructInFunction,
    NotAssignable,
    VoidSliceElement,
    VoidPointerTarget,
    NotSliceable,
    MethodIsField,
    UnknownMethod,
    AmbiguousMethod,
    DuplicateTrait,
    NotATrait,
    TraitUsedAsValue,
    NotInTrait,
    MismatchedTraitFunction,
    MissingTraitFunction,
    DuplicateImplementation,
    InvalidLength,
    NotLiteralType,
    UnknownLength,
    NeverAssigned,
    UnusedVariable,
    UnusedParameter,
    UnusedLocalConstant,
    NotDiscardable,
    PointlessDiscard,
    CannotEvaluate,
    TypeMismatch,
    VoidParameter,
    VoidField,
};

const PendingMethod = struct {
    resolution: *?ast.Resolution,
    method: Method,
    location: token.Location,
    module: usize,
};

const Block = struct {
    parameters: []const ast.TypedName,
    parameter_uses: []Use,
    locals: *std.ArrayList(Local),
};

const Scope = struct {
    parameters: []const ast.TypedName = &.{},
    parameter_uses: []Use = &.{},
    locals: []Local = &.{},
};

const Local = struct {
    name: []const u8,
    target: Target,
    statement: *const ast.Statement,
    location: token.Location,
    use: Use = .{},
};

const Use = struct {
    used: bool = false,
    assigned: bool = false,
    discard: ?token.Location = null,
};

const Target = union(enum) {
    function: ast.Resolution.Function,
    namespace: Namespace,
    type: types.Type,
    constant: ast.Resolution.Constant,
    local: *const ast.Statement,
    method: Method,
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
        error.StructInFunction => "structs cannot be defined inside functions",
        error.NotAssignable => "only variables and their fields can be assigned",
        error.VoidSliceElement => "slice elements cannot have type void",
        error.VoidPointerTarget => "pointers cannot point to void",
        error.NotSliceable => "only variables, constants, parameters and their fields can be sliced",
        error.MethodIsField => "method has the name of a field",
        error.UnknownMethod => "unknown method",
        error.AmbiguousMethod => "method is found in more than one place",
        error.DuplicateTrait => "trait is already defined",
        error.NotATrait => "not a trait",
        error.TraitUsedAsValue => "a trait cannot be used here",
        error.NotInTrait => "function is not in the trait",
        error.MismatchedTraitFunction => "function does not match the trait",
        error.MissingTraitFunction => "implementation is missing a function of the trait",
        error.DuplicateImplementation => "trait is already implemented for this type",
        error.InvalidLength => "array length must be a usize integer literal or a constant bound to one",
        error.NotLiteralType => "braces need an array or a tuple type",
        error.UnknownLength => "array length can only be left out for an array literal",
        error.NeverAssigned => "variable is never assigned, declare it with const",
        error.UnusedVariable => "variable is unused, discard it with _ =",
        error.UnusedParameter => "parameter is unused, discard it with _ =",
        error.UnusedLocalConstant => "local constant is unused, discard it with _ =",
        error.NotDiscardable => "only parameters, local constants and variables can be discarded",
        error.PointlessDiscard => "discarded name is used",
        error.CannotEvaluate => "cannot be evaluated at compile time",
        error.TypeMismatch => "value does not match the expected type",
        error.VoidParameter => "parameter cannot have type void",
        error.VoidField => "field cannot have type void",
    };
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
        .import => |import| switch (import.trait.kind) {
            .identifier => |identifier| identifier.name,
            .path_expression => |path_expression| {
                const path = path_expression.path;
                return path[path.len - 1];
            },
            else => unreachable,
        },
        .implementation => unreachable,
    };
}

fn findSignature(
    signatures: []const ast.FunctionSignature,
    name: []const u8,
) ?ast.FunctionSignature {
    for (signatures) |signature| {
        if (std.mem.eql(u8, signature.name, name)) return signature;
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
        .number, .boolean, .character, .string, .void, .type, .@"struct" => std.meta.eql(value_type, expected),
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

fn findFieldDeclaration(fields: []const ast.Field, name: []const u8) ?usize {
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, name)) return index;
    }
    return null;
}

fn findSliceRoot(expression: ast.Expression) ?ast.Expression {
    return switch (expression.kind) {
        .identifier, .path_expression => expression,
        .field_access => |access| findSliceRoot(access.value.*),
        else => null,
    };
}

fn findLocal(locals: []Local, name: []const u8) ?*Local {
    var index = locals.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, locals[index].name, name)) return &locals[index];
    }
    return null;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn stdout_write(text: string)\nfn main(): stdout_write(\"hi\")" });
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
    try compiler_directory.dir.writeFile(std.testing.io, .{ .sub_path = "std/stdout.mn", .data = "external fn mn_runtime_stdout_write(text: string)\nconst write = mn_runtime_stdout_write" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::stdout::write(\"hi\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const shapes = loader.modules.items[1].declarations[0].kind.trait_definition;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, ast.extractType(shapes.functions[0].return_type));
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

test "resolveMethod: resolves the receiver and self of a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: string\n    fn show(self: Self) -> string: return self.question" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const signature = loader.modules.items[0].declarations[1].kind.function_definition.signature;
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.receiver.?).@"struct".name);
    try std.testing.expectEqualStrings("Card", ast.extractType(signature.parameters[0].type).@"struct".name);
}

test "resolveMethod: rejects two methods with the same name for one type" {
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

test "resolveMethod: allows methods with the same name for different types" {
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

test "resolveMethod: allows a method and a function with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card()\nfn new(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try name_resolver.resolve();
}

test "resolveMethod: rejects a method with the name of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    question: string\n    fn question(self: Self): _ = self" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MethodIsField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card()\nfn main(): _ = Card::new()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "cards.mn", .data = "struct Card:\n    fn new() -> Card: return Card()" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = cards::Card::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn new() -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn new() -> Self: return Square(side = 1)\nfn main(): _ = Square::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, callee.resolution.?);
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

test "resolveTypedName: rejects a void parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: void): noop\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.VoidParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, name_resolver.failure.?.location.?);
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

test "resolveNamesInBlock: rejects a variable that is never assigned" {
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

    try std.testing.expectError(error.NeverAssigned, name_resolver.resolve());
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

test "resolveLocalConstant: rejects an anonymous struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const Point = struct" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructInFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show(value: i32) -> Point:\n    const point = Point(x = value)\n    return point" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show() -> Point:\n    var point = Point(x = 1)\n    point.x = 2\n    return point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const root = body[1].kind.assignment.target.kind.field_access.value;
    try std.testing.expectEqual(&body[0], root.kind.identifier.resolution.?.local);
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

test "resolveTarget: rejects assigning to a field of a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return Point(x = 1)\nfn main(): make().x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAssignable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> i32: return utils::add" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const Pair = (i32, bool)\n    const pair = Pair{1, true}\n    _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[1].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type.boolean, ast.extractType(value.kind.composite_literal.type.?.*).tuple.elements[1]);
}

test "resolveLiteralType: rejects a struct name before braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return Point{1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotLiteralType, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 28 }, name_resolver.failure.?.location.?);
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

test "resolveArrayType: rejects a length to infer for an undefined variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values: [_]i32 = undefined\n    values = {1}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, name_resolver.failure.?.location.?);
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = 4\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const size = 2usize\n    var values: [size]i32 = undefined\n    values = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(2, ast.extractType(body[1].kind.variable_declaration.type.?).array.length);
}

test "expectLength: rejects a length that is not an integer literal" {
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, name_resolver.failure.?.location.?);
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const size = other\nconst other = 2\nfn show(values: [size]i32): _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    try std.testing.expectEqual(2, ast.extractType(parameters[0].type).array.length);
}

test "expectLength: rejects a constant that is not bound to an integer literal" {
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, name_resolver.failure.?.location.?);
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, name_resolver.failure.?.location.?);
}

test "expectLength: rejects a length with a suffix" {
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, name_resolver.failure.?.location.?);
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
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.InvalidLength, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, name_resolver.failure.?.location.?);
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

test "resolveSliceType: rejects void elements" {
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

    try std.testing.expectError(error.VoidSliceElement, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, name_resolver.failure.?.location.?);
}

test "resolveSlice: rejects a slice of a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return {1, 2}\nfn main():\n    const values = make()[..]\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotSliceable, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 20 }, name_resolver.failure.?.location.?);
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

test "resolvePointerType: rejects a pointer to void" {
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

    try std.testing.expectError(error.VoidPointerTarget, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: (i32, bool), two: (i32, bool), three: (bool, i32)):\n    _ = one\n    _ = two\n    _ = three" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = (i32, (bool, char))\nfn show(pair: Pair): _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters;
    const tuple = ast.extractType(parameters[0].type).tuple;
    try std.testing.expectEqual(types.Type.character, tuple.elements[1].tuple.elements[1]);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(one: fn(i32, bool) -> u8, two: fn(i32, bool,) -> u8, three: fn(i32, bool)):\n    _ = one\n    _ = two\n    _ = three" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameters = loader.modules.items[0].declarations[0].kind.function_definition.signature.parameters;
    const one = ast.extractType(parameters[0].type);
    try std.testing.expectEqual(one, ast.extractType(parameters[1].type));
    try std.testing.expect(!std.meta.eql(one, ast.extractType(parameters[2].type)));
    try std.testing.expectEqual(types.Type.void, ast.extractType(parameters[2].type).function.return_type);
}

test "resolveFunctionType: rejects a void parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(callback: fn(void)): _ = callback" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.VoidParameter, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, name_resolver.failure.?.location.?);
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

test "resolveIdentifier: resolves a function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two() -> fn(): return one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, value.kind.identifier.resolution.?);
}

test "resolveValue: resolves a method used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn get() -> fn(Point) -> f32: return Point::length" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, value.kind.path_expression.resolution.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: f32\n    fn length(self: Self) -> f32: return self.x\nfn get() -> fn(Point) -> f32:\n    const measure = Point::length\n    return measure" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[1].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, value.kind.identifier.resolution.?);
}

test "expectValue: resolves an external function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn write()\nfn get() -> fn(): return write" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, value.kind.identifier.resolution.?);
}

test "expectValue: rejects main used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): noop\nfn get() -> fn(): return main" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.MainUsedAsValue, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 26 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: fn(i32), value: i32): callback(value)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(): noop\nconst step: fn() = first\nfn main(): step()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "steps.mn", .data = "fn first(value: i32) -> i32: return value\nconst step: fn(i32) -> i32 = first" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): _ = steps::step(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.discard.kind.call;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
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

test "resolveCallee: resolves a struct through a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: i32" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> shapes::Point: return shapes::Point(x = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const resolution = returned.kind.call.callee.path_expression.resolution.?;
    try std.testing.expectEqualStrings("Point", resolution.type.@"struct".name);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Self: return Card()" });
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

test "resolveName: rejects Self in the type of a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    next: []const Self\nfn take(card: Card): _ = card" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, name_resolver.failure.?.location.?);
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

test "expectCallee: resolves a struct as a callee" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return Point(x = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const resolution = returned.kind.call.callee.identifier.resolution.?;
    try std.testing.expectEqualStrings("Point", resolution.type.@"struct".name);
}

test "resolvePath: rejects a call through a trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn main(): _ = Shape::area(Square(side = 1))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.TraitUsedAsValue, name_resolver.resolve());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::stdout::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const function = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
}

test "resolvePath: resolves a call through a constant that names a module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const stdout = std::stdout\nfn main(): stdout::write()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Self: return Card()\n    fn copy(self: Self) -> Self:\n        _ = self\n        return Self::new()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct i32:\n    fn new() -> Self: return i32()\nfn main(): _ = i32::new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const callee = body[0].kind.discard.kind.call.callee.path_expression;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, callee.resolution.?);
}

test "resolveFirstNamespace: reaches a namespace through a local constant" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const figures = shapes\n    figures::draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const function = body[1].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    try std.testing.expectEqual(0, function.declaration);
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

test "resolveFirstNamespace: lets a parameter hide a module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(utils: i32): utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, name_resolver.failure.?.location.?);
}

test "resolveFirstNamespace: lets a local constant hide a module" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const utils = 5i32\n    utils::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::add::more()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NoMembers, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): std::missing::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ModuleNotFound, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
}

test "resolveMember: lets a function share its name with a module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn math(): noop" });
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    utils::math()\n    utils::math::add()\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const function = body[0].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(1, function.module);
    const module_function = body[1].kind.call.kind.call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqual(2, module_function.module);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::math()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotAFunction, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
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

test "resolveConstant: follows a constant into the modules below what it names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.createDirPath(std.testing.io, "utils");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils/math.mn", .data = "fn add(): noop" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const tools = utils\nfn main(): tools::math::add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call;
    const function = call.callee.path_expression.resolution.?.function;
    try std.testing.expectEqualStrings("math", loader.modules.items[function.module].path[1]);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "output.mn", .data = "const write = std::missing" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): output::write()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnknownName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[1].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
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

test "resolveConstant: rejects a call as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return total\nconst total = one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, name_resolver.failure.?.location.?);
}

test "resolveConstant: rejects a field access as the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst origin = Point.x\nfn read() -> i32: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 16 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst origin = Point(x = 0)\nfn make() -> Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const returned = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(ast.Resolution{ .constant = .{ .module = 0, .declaration = 1 } }, returned.kind.identifier.resolution.?);
}

test "resolveConstant: resolves a constant that holds a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Point = struct:\n    x: i32\nfn show(point: Point): _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const parameter_type = loader.modules.items[0].declarations[1].kind.function_definition.signature.parameters[0].type;
    const point = parameter_type.kind.identifier.resolution.?.type.@"struct";
    try std.testing.expectEqualStrings("Point", point.name);
    try std.testing.expectEqual(0, point.module);
}

test "resolveConstant: rejects a struct that contains itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Node = struct:\n    next: Node\nfn show(node: Node): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StructContainsItself, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, name_resolver.failure.?.location.?);
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

test "resolveConstant: resolves a function as a value with a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst run: fn() = one\nfn get() -> fn(): return run" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();

    const constant = loader.modules.items[0].declarations[1].kind.constant_declaration;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 0 } }, constant.value.kind.identifier.resolution.?);
    try std.testing.expect(ast.extractType(constant.type.?) == .function);
}

test "expectEvaluable: rejects a function call inside a construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn zero() -> i32: return 0\nconst origin = Point(x = zero())\nfn make() -> Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 26 }, name_resolver.failure.?.location.?);
}

test "expectEvaluable: rejects a field access inside a construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nconst other = Point(x = 1)\nconst origin = Point(x = other.x)\nfn make() -> Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 26 }, name_resolver.failure.?.location.?);
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

test "resolveFields: rejects a void field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: void\nfn show(point: Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.VoidField, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 8 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: void" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(point: shapes::Point): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.VoidField, name_resolver.resolve());
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

test "resolveFields: rejects a default that cannot be evaluated at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn zero() -> i32: return 0\nstruct Size:\n    width: i32 = zero()\nfn draw(size: Size): _ = size" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, name_resolver.resolve());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, name_resolver.failure.?.location.?);
}

test "loadRoot: reports the reserved name monolith at the path" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): monolith::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReservedModuleName, name_resolver.resolve());
    try std.testing.expectEqual(loader.modules.items[0].path, name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 12 }, name_resolver.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = NameResolver.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UnexpectedTab, name_resolver.resolve());
    try std.testing.expectEqualDeep(@as(ast.Path, &.{"utils"}), name_resolver.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 1 }, name_resolver.failure.?.location.?);
}
