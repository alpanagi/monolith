const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

const followPointer = types.followPointer;
const isZeroSized = types.isZeroSized;

pub const TypeChecker = struct {
    arena: *std.heap.ArenaAllocator,
    program: ast.Program,
    module_index: usize = 0,
    addresses: std.ArrayList(Address) = .empty,
    default: ?Default = null,
    failure: ?Failure = null,

    pub fn init(arena: *std.heap.ArenaAllocator, program: ast.Program) TypeChecker {
        return .{ .arena = arena, .program = program };
    }

    pub fn check(self: *TypeChecker) TypeError!void {
        for (self.program.types.entries.items) |value_type| {
            switch (value_type) {
                .@"struct" => |struct_type| try self.checkFieldDefaults(struct_type),
                .number, .boolean, .void, .type, .array, .slice, .pointer, .optional, .tuple, .function, .implementer => {
                    unreachable;
                },
            }
        }
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            for (module.declarations, 0..) |declaration, declaration_index| {
                switch (declaration.kind) {
                    .function_definition => |function| {
                        if (function.default_of == null) try self.checkFunction(function);
                    },
                    .trait_definition => |definition| {
                        const trait: ast.Resolution.Trait = .{ .module = index, .declaration = declaration_index };
                        for (definition.functions, definition.defaults) |signature, default| {
                            const written = default orelse continue;
                            const function: ast.FunctionDefinition = .{ .signature = signature, .body = written.body };
                            try self.checkDefault(function, trait, .implementer);
                        }
                    },
                    .function_declaration => |signature| {
                        try self.checkExternalFunction(signature, declaration.location);
                    },
                    .constant_declaration => |constant| {
                        if (ast.isAlias(constant)) continue;
                        _ = try self.checkConstant(.{ .module = index, .declaration = declaration_index });
                        try self.checkConstantComparisons(constant.value);
                    },
                    .struct_definition,
                    .implementation,
                    .import,
                    => {},
                }
            }
        }
        for (self.program.modules) |module| {
            for (module.declarations) |declaration| {
                if (declaration.kind != .function_definition) continue;
                const function = declaration.kind.function_definition;
                const trait = function.default_of orelse continue;
                try self.checkDefault(function, trait, ast.extractType(function.signature.receiver.?));
            }
        }
        try self.checkAddresses();
    }

    fn checkDefault(
        self: *TypeChecker,
        function: ast.FunctionDefinition,
        trait: ast.Resolution.Trait,
        self_type: types.Type,
    ) TypeError!void {
        const caller_module_index = self.module_index;
        self.module_index = trait.module;
        self.default = .{ .trait = trait, .self_type = self_type };
        defer self.module_index = caller_module_index;
        defer self.default = null;
        try self.checkFunction(function);
    }

    fn checkFieldDefaults(self: *TypeChecker, struct_type: types.Struct) TypeError!void {
        const caller_module_index = self.module_index;
        self.module_index = struct_type.module;
        defer self.module_index = caller_module_index;
        for (struct_type.fields) |field| {
            const default = field.default orelse continue;
            try self.checkExpression(&.{}, default, field.type);
        }
    }

    fn checkFunction(self: *TypeChecker, function: ast.FunctionDefinition) TypeError!void {
        const signature = function.signature;
        if (ast.isMain(signature)) {
            if (ast.extractType(signature.return_type) != .void) {
                return self.fail(signature.return_type.location, error.MainHasReturnType);
            }
            if (signature.parameters.len > 0) {
                return self.fail(signature.parameters[0].location, error.MainHasParameters);
            }
        }

        try self.checkBlock(signature, function.body);
        var trace: Trace = .{};
        const flow = try self.traceBlock(&trace, function.body, .unassigned);
        try self.checkDeferredUses(function.body);
        try self.checkUndefinedReads(function.body);

        const return_type = signature.return_type;
        if (ast.extractType(return_type) == .void) return;
        if (flow != .ended) return self.fail(return_type.location, error.MissingReturn);
    }

    fn traceBlock(
        self: *TypeChecker,
        trace: *Trace,
        statements: []const ast.Statement,
        entry: Flow,
    ) TypeError!Flow {
        var flow = entry;
        for (statements) |*statement| {
            if (flow == .ended) return self.fail(statement.location, error.UnreachableStatement);
            flow = try self.traceStatement(trace, statement, flow);
        }
        return flow;
    }

    fn traceStatement(
        self: *TypeChecker,
        trace: *Trace,
        statement: *const ast.Statement,
        entry: Flow,
    ) TypeError!Flow {
        const use: Use = if (trace.variable) |variable| findStatementUse(variable, statement.*) else .none;
        const flow: Flow = switch (use) {
            .none => entry,
            .read => |location| flow: {
                if (entry == .unassigned) return self.fail(location, error.UndefinedRead);
                break :flow entry;
            },
            .passed => .assigned,
        };
        switch (statement.kind) {
            .noop, .discard, .call, .constant_declaration, .tuple_declaration => return flow,
            .variable_declaration, .assignment => return flow,
            .@"return", .@"continue" => return .ended,
            .@"break" => |jump| {
                for (trace.exits.items) |*exit| {
                    if (exit.loop == jump.loop.?) exit.flow = mergeFlows(exit.flow, flow);
                }
                return .ended;
            },
            .@"if" => |conditional| {
                const body = try self.traceBlock(trace, conditional.body, flow);
                const else_body = conditional.else_body orelse return mergeFlows(body, flow);
                return mergeFlows(body, try self.traceBlock(trace, else_body, flow));
            },
            .@"while", .@"for" => {
                const body, const else_body = ast.extractBlocks(statement.*);
                try trace.exits.append(self.arena.allocator(), .{ .loop = statement });
                _ = try self.traceBlock(trace, body, flow);
                const exit = trace.exits.pop().?.flow;
                const finished: Flow = if (isEndless(statement.*)) .ended else flow;
                return mergeFlows(try self.traceBlock(trace, else_body, finished), exit);
            },
        }
    }

    fn checkDeferredUses(self: *TypeChecker, body: []const ast.Statement) TypeError!void {
        for (body) |statement| {
            for (ast.extractBlocks(statement)) |block| try self.checkDeferredUses(block);
        }
        for (body, 0..) |*statement, index| {
            if (statement.kind != .variable_declaration) continue;
            var use = statement.kind.variable_declaration.deferred_use orelse continue;
            recordTargetUses(&use, statement, body[index + 1 ..]);
            if (!use.modified) return self.fail(statement.location, error.NeverModified);
            if (use.discard) |discard| {
                if (use.used) return self.fail(discard, error.PointlessDiscard);
            } else if (!use.used) {
                return self.fail(statement.location, error.UnusedVariable);
            }
        }
    }

    fn checkUndefinedReads(self: *TypeChecker, body: []const ast.Statement) TypeError!void {
        for (body, 0..) |*statement, index| {
            for (ast.extractBlocks(statement.*)) |block| try self.checkUndefinedReads(block);
            if (statement.kind != .variable_declaration) continue;
            if (statement.kind.variable_declaration.value.kind != .undefined) continue;
            try self.checkUndefinedVariable(statement, body[index + 1 ..]);
        }
    }

    fn checkUndefinedVariable(
        self: *TypeChecker,
        variable: *const ast.Statement,
        statements: []const ast.Statement,
    ) TypeError!void {
        var trace: Trace = .{ .variable = variable };
        _ = try self.traceBlock(&trace, statements, .unassigned);
    }

    fn checkExternalFunction(
        self: *TypeChecker,
        signature: ast.FunctionSignature,
        location: token.Location,
    ) TypeError!void {
        if (ast.isMain(signature)) {
            return self.fail(location, error.MainIsExternal);
        }
    }

    fn checkConstantComparisons(self: *TypeChecker, expression: ast.Expression) TypeError!void {
        switch (expression.kind) {
            .binary => |binary| {
                const equality = binary.operator == .equal or binary.operator == .not_equal;
                if (equality and binary.left.type.? == .optional) {
                    return self.fail(expression.location, error.CannotEvaluate);
                }
                try self.checkConstantComparisons(binary.left.*);
                try self.checkConstantComparisons(binary.right.*);
            },
            .unary => |unary| try self.checkConstantComparisons(unary.operand.*),
            .composite_literal => |literal| {
                for (literal.elements) |element| try self.checkConstantComparisons(element.value);
            },
            .slice => |slice| {
                for ([_]?*ast.Expression{ slice.start, slice.end }) |optional_bound| {
                    const bound = optional_bound orelse continue;
                    try self.checkConstantComparisons(bound.*);
                }
            },
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .identifier,
            .path_expression,
            .call,
            .method_call,
            .negation,
            .address_of,
            .array_type,
            .slice_type,
            .index,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .field_access,
            .dereference,
            .unwrap,
            => {},
        }
    }

    fn checkAddresses(self: *TypeChecker) TypeError!void {
        for (self.addresses.items) |address| {
            const constant = self.findConstant(address.constant);
            if (self.isEvaluable(constant.value, false)) continue;
            self.module_index = address.module;
            return self.fail(address.location, error.UnevaluatedAddress);
        }
    }

    fn isEvaluable(self: *const TypeChecker, expression: ast.Expression, in_operation: bool) bool {
        switch (expression.kind) {
            .binary => |binary| {
                const operand_type = binary.left.type.?;
                const evaluable = switch (binary.operator) {
                    .shift_left, .shift_right, .@"orelse" => false,
                    .remainder => !isSigned(operand_type.number),
                    .equal, .not_equal => !comparesByParts(operand_type),
                    .multiply,
                    .divide,
                    .add,
                    .subtract,
                    .bitwise_and,
                    .bitwise_exclusive_or,
                    .bitwise_or,
                    .less_than,
                    .less_than_or_equal,
                    .greater_than,
                    .greater_than_or_equal,
                    .@"and",
                    .@"or",
                    => true,
                };
                return evaluable and self.isEvaluable(binary.left.*, true) and
                    self.isEvaluable(binary.right.*, true);
            },
            .unary => |unary| return self.isEvaluable(unary.operand.*, true),
            .negation => |operand| return self.isEvaluable(operand.*, in_operation),
            inline .identifier, .path_expression => |name| {
                const resolution = name.resolution orelse return true;
                if (resolution != .constant) return true;
                if (in_operation and self.isStored(resolution.constant)) return false;
                const constant = self.findConstant(resolution.constant);
                return self.isEvaluable(constant.value, in_operation);
            },
            .composite_literal => |literal| {
                for (literal.elements) |element| {
                    if (!self.isEvaluable(element.value, in_operation)) return false;
                }
                return true;
            },
            .slice => |slice| {
                if (!self.isEvaluable(slice.value.*, in_operation)) return false;
                for ([_]?*ast.Expression{ slice.start, slice.end }) |optional_bound| {
                    const bound = optional_bound orelse continue;
                    if (!self.isEvaluable(bound.*, in_operation)) return false;
                }
                return true;
            },
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
            .call,
            .method_call,
            .address_of,
            .array_type,
            .slice_type,
            .index,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .field_access,
            .dereference,
            .unwrap,
            => return true,
        }
    }

    fn isStored(self: *const TypeChecker, resolution: ast.Resolution.Constant) bool {
        const constant = self.findConstant(resolution);
        const value_type = ast.extractDeclaredType(constant.type, constant.value);
        if (isZeroSized(value_type)) return false;
        if (value_type == .@"struct" or value_type == .array) return true;
        for (self.addresses.items) |address| {
            if (std.meta.eql(address.constant, resolution)) return true;
        }
        return false;
    }

    fn findConstant(
        self: *const TypeChecker,
        resolution: ast.Resolution.Constant,
    ) ast.ConstantDeclaration {
        const declaration = self.program.modules[resolution.module].declarations[resolution.declaration];
        return declaration.kind.constant_declaration;
    }

    fn checkStatement(
        self: *TypeChecker,
        signature: ast.FunctionSignature,
        statement: *ast.Statement,
    ) TypeError!void {
        const parameters = signature.parameters;
        const return_type = ast.extractType(signature.return_type);
        switch (statement.kind) {
            .noop => {},
            .@"return" => |*value| {
                if (value.*) |*expression| {
                    if (return_type == .void) {
                        return self.fail(expression.location, error.UnexpectedReturnValue);
                    }
                    try self.checkExpression(parameters, expression, return_type);
                } else if (return_type != .void) {
                    return self.fail(statement.location, error.MissingReturnValue);
                }
            },
            .discard => |*expression| {
                if (expression.kind == .identifier) return;
                if (try self.checkCall(parameters, expression) == .void) {
                    return self.fail(expression.location, error.DiscardedVoid);
                }
            },
            .call => |*expression| {
                if (try self.checkCall(parameters, expression) != .void) {
                    return self.fail(expression.location, error.UnusedResult);
                }
            },
            .constant_declaration => |*constant| {
                if (ast.isAlias(constant.*)) return;
                const written = if (constant.type) |*written| written else null;
                _ = try self.checkDeclaredValue(parameters, written, &constant.value);
            },
            .tuple_declaration => |*declaration| {
                const value = &declaration.value;
                const value_type = try self.inferType(parameters, value);
                try self.checkElementNames(declaration.names, true, value_type, value.*, value.location);
            },
            .variable_declaration => |*variable| {
                const value = &variable.value;
                const written = if (variable.type) |*written| written else null;
                const value_type = try self.checkInitialValue(parameters, written, value);
                if (value_type == .type) return self.fail(value.location, error.TypeVariable);
            },
            .assignment => |*assignment| {
                const target = &assignment.target;
                const operator = assignment.operator orelse {
                    const target_type = try self.inferType(parameters, target);
                    if (!isWritable(target.*)) return self.fail(target.location, error.NotWritable);
                    return self.checkExpression(parameters, &assignment.value, target_type);
                };
                const binary: ast.Binary = .{
                    .operator = operator.operator,
                    .operator_location = operator.location,
                    .left = target,
                    .right = &assignment.value,
                };
                const result_type = try self.checkBinary(parameters, binary, null);
                if (!isWritable(target.*)) return self.fail(target.location, error.NotWritable);
                if (!isConvertible(result_type, target.type.?)) {
                    return self.fail(operator.location, error.TypeMismatch);
                }
            },
            .@"if" => |*conditional| {
                try self.checkExpression(parameters, &conditional.condition, .boolean);
                try self.checkBlock(signature, conditional.body);
                if (conditional.else_body) |else_body| try self.checkBlock(signature, else_body);
            },
            .@"while" => |*loop| {
                try self.checkExpression(parameters, &loop.condition, .boolean);
                try self.checkBlock(signature, loop.body);
                if (loop.else_body) |else_body| try self.checkBlock(signature, else_body);
            },
            .@"for" => |*loop| {
                try self.checkSequence(parameters, &loop.sequence);
                const element_type = ast.extractElementType(loop.sequence);
                switch (loop.sequence) {
                    .value => |value| {
                        try self.checkElementNames(loop.names, loop.tuple, element_type, value, value.location);
                    },
                    .range => |range| {
                        try self.checkElementNames(loop.names, loop.tuple, element_type, null, range.start.location);
                    },
                }
                try self.checkBlock(signature, loop.body);
                if (loop.else_body) |else_body| try self.checkBlock(signature, else_body);
            },
            .@"break", .@"continue" => {},
        }
    }

    fn checkElementNames(
        self: *TypeChecker,
        names: []ast.ElementName,
        tuple: bool,
        element_type: types.Type,
        container: ?ast.Expression,
        location: token.Location,
    ) TypeError!void {
        if (tuple) {
            if (element_type != .tuple) return self.fail(location, error.NotTuple);
            if (names.len != element_type.tuple.elements.len) {
                return self.fail(names[0].location, error.WrongNameCount);
            }
        }
        for (names, 0..) |*name, position| {
            const name_type = if (tuple) element_type.tuple.elements[position] else element_type;
            if (!name.pointer) {
                name.type = name_type;
                continue;
            }
            name.type = try self.checkElementAddress(name.location, name_type, container);
        }
    }

    fn checkElementAddress(
        self: *TypeChecker,
        location: token.Location,
        target: types.Type,
        container: ?ast.Expression,
    ) TypeError!types.Type {
        const value = container orelse return self.fail(location, error.NotAddressable);
        if (!isElementPlace(value)) return self.fail(location, error.NotAddressable);
        if (ast.findElementConstantRoot(value)) |constant| {
            try self.addresses.append(self.arena.allocator(), .{
                .constant = constant,
                .module = self.module_index,
                .location = location,
            });
        }
        const pointer = try self.program.types.addPointer(self.arena.allocator(), .{
            .target = target,
            .many = false,
            .constant = !isElementWritable(value),
        });
        return .{ .pointer = pointer };
    }

    fn checkSequence(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        sequence: *ast.Sequence,
    ) TypeError!void {
        switch (sequence.*) {
            .range => |*range| {
                const bound_type: types.Type = .{ .number = .usize };
                try self.checkExpression(parameters, &range.start, bound_type);
                if (range.end == null) return;
                const end = &range.end.?;
                try self.checkExpression(parameters, end, bound_type);
                if (range.start.kind != .integer_literal or end.kind != .integer_literal) return;
                const first = std.fmt.parseInt(u64, range.start.kind.integer_literal.text, 0) catch unreachable;
                const last = std.fmt.parseInt(u64, end.kind.integer_literal.text, 0) catch unreachable;
                if (first > last) return self.fail(range.start.location, error.ReversedRange);
            },
            .value => |*value| switch (try self.inferType(parameters, value)) {
                .array, .slice => {},
                .pointer => |pointer| {
                    if (pointer.many or pointer.target != .array) return self.fail(value.location, error.NotSequence);
                },
                .number, .boolean, .void, .type, .@"struct", .optional, .tuple, .function, .implementer => {
                    return self.fail(value.location, error.NotSequence);
                },
            },
        }
    }

    fn checkBlock(
        self: *TypeChecker,
        signature: ast.FunctionSignature,
        statements: []ast.Statement,
    ) TypeError!void {
        for (statements) |*statement| try self.checkStatement(signature, statement);
    }

    fn checkInitialValue(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        written_type: ?*ast.Expression,
        value: *ast.Expression,
    ) TypeError!types.Type {
        if (value.kind != .undefined) {
            return self.checkDeclaredValue(parameters, written_type, value);
        }
        const written = written_type orelse {
            return self.fail(value.location, error.UnknownValueType);
        };
        if (isUnfinishedArray(written.*)) return self.fail(value.location, error.MissingLength);
        value.type = ast.extractType(written.*);
        return value.type.?;
    }

    fn checkExpression(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        const value_type: types.Type = switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal => value_type: {
                try self.checkLiteral(expression.*, expected);
                break :value_type expected;
            },
            .negation => |operand| value_type: {
                try self.checkNegation(expression.location, operand, expected);
                break :value_type expected;
            },
            .binary => |binary| try self.checkBinary(parameters, binary, expected),
            .unary => |unary| try self.checkUnary(parameters, expression.location, unary, expected),
            .undefined => return self.fail(expression.location, error.UnexpectedUndefined),
            .null => value_type: {
                if (expected != .optional) return self.fail(expression.location, error.UnexpectedNull);
                break :value_type expected;
            },
            inline .identifier, .path_expression => |name| value_type: {
                break :value_type try self.computeValueType(parameters, expression.location, name.resolution.?);
            },
            .call, .method_call => try self.checkCall(parameters, expression),
            .composite_literal => |literal| value_type: {
                const location = expression.location;
                break :value_type try self.checkCompositeLiteral(parameters, location, literal, expected);
            },
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => value_type: {
                if (expected != .type) return self.fail(expression.location, error.TypeMismatch);
                break :value_type expected;
            },
            .slice => try self.inferSliceType(parameters, expression),
            .field_access => try self.checkFieldAccess(parameters, expression),
            .index, .address_of, .dereference, .unwrap => try self.inferType(parameters, expression),
        };
        if (!isConvertible(value_type, expected)) return self.fail(expression.location, error.TypeMismatch);
        expression.type = value_type;
    }

    fn checkCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        if (expression.kind == .method_call) try self.resolveMethodCall(parameters, expression);
        if (ast.extractResolution(expression.kind.call.callee) == .trait_method) {
            try self.resolveTraitCall(parameters, expression);
        }
        const call = expression.kind.call;
        const value_type = switch (ast.extractResolution(call.callee)) {
            .function, .trait_function => try self.checkFunctionCall(parameters, expression),
            .trait_method => unreachable,
            .parameter, .local, .constant, .element => try self.checkValueCall(parameters, expression),
            .type => unreachable,
        };
        expression.type = value_type;
        return value_type;
    }

    fn resolveMethodCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!void {
        const method_call = expression.kind.method_call;
        const receiver = try self.inferType(parameters, method_call.receiver);
        const name = method_call.name;
        const function = try self.findMethodFunction(method_call.name_location, receiver, name);
        if (!ast.hasSelf(self.extractSignature(function))) {
            return self.fail(method_call.name_location, error.NoSelf);
        }
        const allocator = self.arena.allocator();
        const arguments = try allocator.alloc(ast.Argument, method_call.arguments.len + 1);
        arguments[0] = .{
            .name = null,
            .value = method_call.receiver.*,
            .location = method_call.receiver.location,
        };
        @memcpy(arguments[1..], method_call.arguments);
        const callee: ast.Identifier = .{ .name = name, .resolution = function };
        const call: ast.Call = .{ .callee = .{ .identifier = callee }, .arguments = arguments };
        expression.kind = .{ .call = call };
    }

    fn resolveTraitCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!void {
        const call = &expression.kind.call;
        const callee = &call.callee.path_expression;
        const method = callee.resolution.?.trait_method;
        const signature = self.extractSignature(callee.resolution.?);
        if (!ast.hasSelf(signature)) return self.fail(expression.location, error.NoSelf);
        const module = self.program.modules[self.module_index];
        if (!isTraitVisible(module, self.module_index, method.trait)) {
            return self.fail(expression.location, error.UnknownMethod);
        }
        if (call.arguments.len == 0) return self.fail(expression.location, error.ArgumentCountMismatch);
        const receiver = try self.inferType(parameters, &call.arguments[0].value);
        callee.resolution = try self.findTraitMethod(call.arguments[0].location, method, receiver, signature.name);
    }

    fn findTraitMethod(
        self: *TypeChecker,
        location: token.Location,
        method: ast.Resolution.TraitFunction,
        receiver: types.Type,
        name: []const u8,
    ) TypeError!ast.Resolution {
        if (receiver == .implementer) {
            const default = self.default.?;
            if (!std.meta.eql(default.trait, method.trait)) return self.fail(location, error.NotImplemented);
            return .{ .trait_function = method };
        }
        const function = ast.findTraitFunction(self.program.modules, method.trait, receiver, name) orelse {
            return self.fail(location, error.NotImplemented);
        };
        return .{ .function = function };
    }

    fn findMethodFunction(
        self: *TypeChecker,
        location: token.Location,
        receiver: types.Type,
        name: []const u8,
    ) TypeError!ast.Resolution {
        const modules = self.program.modules;
        if (self.default) |default| {
            if (std.meta.eql(receiver, default.self_type)) return self.findSelfFunction(location, default, name);
        }
        return switch (ast.findMethod(modules, self.module_index, receiver, name)) {
            .found => |function| .{ .function = function },
            .missing => self.fail(location, error.UnknownMethod),
            .ambiguous => self.fail(location, error.AmbiguousMethod),
        };
    }

    fn findSelfFunction(
        self: *TypeChecker,
        location: token.Location,
        default: Default,
        name: []const u8,
    ) TypeError!ast.Resolution {
        const modules = self.program.modules;
        const trait = default.trait;
        if (default.self_type == .implementer) {
            const definition = modules[trait.module].declarations[trait.declaration].kind.trait_definition;
            for (definition.functions, 0..) |signature, position| {
                if (!std.mem.eql(u8, signature.name, name)) continue;
                return .{ .trait_function = .{ .trait = trait, .function = position } };
            }
            return self.fail(location, error.UnknownMethod);
        }
        const function = ast.findTraitFunction(modules, trait, default.self_type, name) orelse {
            return self.fail(location, error.UnknownMethod);
        };
        return .{ .function = function };
    }

    fn extractSignature(self: *const TypeChecker, function: ast.Resolution) ast.FunctionSignature {
        const modules = self.program.modules;
        return switch (function) {
            .function => |resolved| ast.extractFunctionSignature(modules[resolved.module].declarations[resolved.declaration]),
            .trait_function, .trait_method => |resolved| {
                const trait = resolved.trait;
                const definition = modules[trait.module].declarations[trait.declaration].kind.trait_definition;
                return definition.functions[resolved.function];
            },
            .parameter, .type, .constant, .local, .element => unreachable,
        };
    }

    fn checkFunctionCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const call = expression.kind.call;
        const callee = self.extractSignature(ast.extractResolution(call.callee));
        if (ast.isMain(callee)) {
            return self.fail(expression.location, error.MainCalled);
        }
        if (call.arguments.len != callee.parameters.len) {
            return self.fail(expression.location, error.ArgumentCountMismatch);
        }
        for (call.arguments, callee.parameters) |*argument, parameter| {
            if (argument.name != null) return self.fail(argument.location, error.NamedArgument);
            const parameter_type = ast.extractType(parameter.type);
            try self.checkExpression(parameters, &argument.value, parameter_type);
        }
        return ast.extractType(callee.return_type);
    }

    fn checkValueCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const call = expression.kind.call;
        const resolution = ast.extractResolution(call.callee);
        const callee_type = try self.computeValueType(parameters, expression.location, resolution);
        if (callee_type != .pointer or callee_type.pointer.target != .function) {
            return self.fail(expression.location, error.NotCallable);
        }
        const function = callee_type.pointer.target.function;
        if (call.arguments.len != function.parameters.len) {
            return self.fail(expression.location, error.ArgumentCountMismatch);
        }
        for (call.arguments, function.parameters) |*argument, parameter_type| {
            if (argument.name != null) return self.fail(argument.location, error.NamedArgument);
            try self.checkExpression(parameters, &argument.value, parameter_type);
        }
        return function.return_type;
    }

    fn checkFieldAccess(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const access = expression.kind.field_access;
        const value_type = try self.inferType(parameters, access.value);
        const struct_type = switch (followPointer(value_type)) {
            .@"struct" => |struct_type| struct_type,
            .number, .boolean, .void, .type, .array, .slice, .pointer, .optional, .tuple, .function, .implementer => {
                return self.fail(access.field_location, error.NoFields);
            },
        };
        const field = findField(struct_type.fields, access.field) orelse {
            return self.fail(access.field_location, error.UnknownField);
        };
        expression.type = field.type;
        return field.type;
    }

    fn inferType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        switch (expression.kind) {
            .undefined => return self.fail(expression.location, error.UnexpectedUndefined),
            .null => return self.fail(expression.location, error.UnexpectedNull),
            .integer_literal, .float_literal, .boolean_literal, .string_literal => {
                const value_type = try self.computeLiteralType(expression.location, expression.*);
                try self.checkLiteral(expression.*, value_type);
                expression.type = value_type;
                return value_type;
            },
            inline .identifier, .path_expression => |name| {
                const value_type = try self.computeValueType(parameters, expression.location, name.resolution.?);
                expression.type = value_type;
                return value_type;
            },
            .call, .method_call => return self.checkCall(parameters, expression),
            .negation => |operand| {
                const value_type = try self.computeLiteralType(expression.location, operand.*);
                try self.checkNegation(expression.location, operand, value_type);
                expression.type = value_type;
                return value_type;
            },
            .binary => |binary| {
                const value_type = try self.checkBinary(parameters, binary, null);
                expression.type = value_type;
                return value_type;
            },
            .unary => |unary| {
                const value_type = try self.checkUnary(parameters, expression.location, unary, null);
                expression.type = value_type;
                return value_type;
            },
            .address_of => return self.checkAddressOf(parameters, expression),
            .composite_literal => |literal| {
                const written = literal.type orelse {
                    return self.fail(expression.location, error.UnknownValueType);
                };
                const value_type = ast.extractType(written.*);
                const location = expression.location;
                _ = try self.checkCompositeLiteral(parameters, location, literal, value_type);
                expression.type = value_type;
                return value_type;
            },
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {
                expression.type = .type;
                return .type;
            },
            .index => return self.checkIndex(parameters, expression),
            .slice => return self.inferSliceType(parameters, expression),
            .field_access => return self.checkFieldAccess(parameters, expression),
            .dereference => return self.checkDereference(parameters, expression),
            .unwrap => return self.checkUnwrap(parameters, expression),
        }
    }

    fn checkBinary(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        context: ?types.Type,
    ) TypeError!types.Type {
        const location = binary.operator_location;
        switch (binary.operator) {
            .@"and", .@"or" => {
                try self.checkExpression(parameters, binary.left, .boolean);
                try self.checkExpression(parameters, binary.right, .boolean);
                return .boolean;
            },
            .shift_left, .shift_right => {
                const value_type = try self.checkOperand(parameters, binary.left, context);
                try self.checkExpression(parameters, binary.right, .{ .number = .usize });
                if (!isInteger(value_type)) return self.fail(location, error.NotInteger);
                return value_type;
            },
            .@"orelse" => return self.checkOrElse(parameters, binary),
            .equal, .not_equal => {
                if (ast.isNullComparison(binary)) return self.checkNullComparison(parameters, binary);
                const operand_type = try self.checkOperands(parameters, binary, null);
                if (!isEquatable(operand_type)) return self.fail(location, error.NotEquatable);
                return .boolean;
            },
            .less_than, .less_than_or_equal, .greater_than, .greater_than_or_equal => {
                const operand_type = try self.checkOperands(parameters, binary, null);
                if (!isOrdered(operand_type)) return self.fail(location, error.NotOrdered);
                return .boolean;
            },
            .add, .subtract => return self.checkAdditive(parameters, binary, context),
            .multiply, .divide => {
                const operand_type = try self.checkOperands(parameters, binary, context);
                if (operand_type != .number) return self.fail(location, error.NotNumeric);
                return operand_type;
            },
            .remainder, .bitwise_and, .bitwise_exclusive_or, .bitwise_or => {
                const operand_type = try self.checkOperands(parameters, binary, context);
                if (!isInteger(operand_type)) return self.fail(location, error.NotInteger);
                return operand_type;
            },
        }
    }

    fn checkOrElse(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
    ) TypeError!types.Type {
        const optional_type = try self.inferType(parameters, binary.left);
        if (optional_type != .optional) return self.fail(binary.left.location, error.NotOptional);
        const child = optional_type.optional.child;
        const fallback = binary.right;
        if (!hasOwnType(fallback.*)) {
            if (fallback.kind == .null and child != .optional) {
                try self.checkExpression(parameters, fallback, optional_type);
                return optional_type;
            }
            try self.checkExpression(parameters, fallback, child);
            return child;
        }
        const fallback_type = try self.inferType(parameters, fallback);
        if (isConvertible(fallback_type, child)) return child;
        if (isConvertible(fallback_type, optional_type)) return optional_type;
        return self.fail(fallback.location, error.TypeMismatch);
    }

    fn checkNullComparison(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
    ) TypeError!types.Type {
        const left_is_null = binary.left.kind == .null;
        const operand = if (left_is_null) binary.right else binary.left;
        const null_operand = if (left_is_null) binary.left else binary.right;
        if (operand.kind == .null) return self.fail(binary.left.location, error.UnknownValueType);
        const operand_type = try self.inferType(parameters, operand);
        try self.checkExpression(parameters, null_operand, operand_type);
        return .boolean;
    }

    fn checkAdditive(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        context: ?types.Type,
    ) TypeError!types.Type {
        const location = binary.operator_location;
        const left_type = try self.inferOwnType(parameters, binary.left);
        if (left_type) |known| {
            if (known == .pointer) return self.checkPointerArithmetic(parameters, binary, known);
        }
        const right_type = try self.inferOwnType(parameters, binary.right);
        if (right_type) |known| {
            if (known == .pointer and binary.operator == .add) {
                return self.checkOffsetPlusPointer(parameters, binary, left_type, known);
            }
        }
        const operand_type = try self.matchOperands(parameters, binary, left_type, right_type, context);
        if (operand_type != .number) return self.fail(location, error.NotNumeric);
        return operand_type;
    }

    fn checkOffsetPlusPointer(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        offset_type: ?types.Type,
        pointer_type: types.Type,
    ) TypeError!types.Type {
        try self.expectArithmeticPointer(binary.operator_location, pointer_type);
        const usize_type: types.Type = .{ .number = .usize };
        const known = offset_type orelse {
            try self.checkExpression(parameters, binary.left, usize_type);
            return pointer_type;
        };
        if (!std.meta.eql(known, usize_type)) {
            return self.fail(binary.left.location, error.TypeMismatch);
        }
        return pointer_type;
    }

    fn checkPointerArithmetic(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        pointer_type: types.Type,
    ) TypeError!types.Type {
        const location = binary.operator_location;
        try self.expectArithmeticPointer(location, pointer_type);
        const offset_type: types.Type = .{ .number = .usize };
        if (binary.operator == .add or !hasOwnType(binary.right.*)) {
            try self.checkExpression(parameters, binary.right, offset_type);
            return pointer_type;
        }
        const right_type = try self.inferType(parameters, binary.right);
        if (right_type != .pointer) {
            if (!std.meta.eql(right_type, offset_type)) {
                return self.fail(binary.right.location, error.TypeMismatch);
            }
            return pointer_type;
        }
        if (unifyTypes(pointer_type, right_type) == null) {
            return self.fail(location, error.MismatchedOperands);
        }
        return .{ .number = .isize };
    }

    fn expectArithmeticPointer(
        self: *TypeChecker,
        location: token.Location,
        pointer_type: types.Type,
    ) TypeError!void {
        const pointer = pointer_type.pointer;
        if (!pointer.many) return self.fail(location, error.SinglePointerArithmetic);
        if (isZeroSized(pointer.target)) return self.fail(location, error.ZeroSizedPointerArithmetic);
    }

    fn checkOperands(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        context: ?types.Type,
    ) TypeError!types.Type {
        const left_type = try self.inferOwnType(parameters, binary.left);
        const right_type = try self.inferOwnType(parameters, binary.right);
        return self.matchOperands(parameters, binary, left_type, right_type, context);
    }

    fn inferOwnType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!?types.Type {
        if (!hasOwnType(expression.*)) return null;
        return try self.inferType(parameters, expression);
    }

    fn matchOperands(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        binary: ast.Binary,
        left_type: ?types.Type,
        right_type: ?types.Type,
        context: ?types.Type,
    ) TypeError!types.Type {
        const left = binary.left;
        const right = binary.right;
        if (left_type) |known_left| {
            const known_right = right_type orelse {
                try self.checkExpression(parameters, right, known_left);
                return known_left;
            };
            return unifyTypes(known_left, known_right) orelse {
                return self.fail(binary.operator_location, error.MismatchedOperands);
            };
        }
        if (right_type) |known_right| {
            try self.checkExpression(parameters, left, known_right);
            return known_right;
        }
        const operand_type = context orelse return self.fail(left.location, error.UnknownValueType);
        try self.checkExpression(parameters, left, operand_type);
        try self.checkExpression(parameters, right, operand_type);
        return operand_type;
    }

    fn checkOperand(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        operand: *ast.Expression,
        context: ?types.Type,
    ) TypeError!types.Type {
        if (hasOwnType(operand.*)) return self.inferType(parameters, operand);
        const operand_type = context orelse {
            return self.fail(operand.location, error.UnknownValueType);
        };
        try self.checkExpression(parameters, operand, operand_type);
        return operand_type;
    }

    fn checkUnary(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        unary: ast.Unary,
        context: ?types.Type,
    ) TypeError!types.Type {
        if (unary.operator == .not) {
            try self.checkExpression(parameters, unary.operand, .boolean);
            return .boolean;
        }
        const operand_type = try self.checkOperand(parameters, unary.operand, context);
        if (unary.operator == .bitwise_not) {
            if (!isInteger(operand_type)) return self.fail(location, error.NotInteger);
            return operand_type;
        }
        if (operand_type != .number) return self.fail(location, error.NotNumeric);
        if (!isSigned(operand_type.number)) return self.fail(location, error.NegatedUnsigned);
        return operand_type;
    }

    fn checkAddressOf(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const operand = expression.kind.address_of;
        if (findFunction(operand.*)) |function| return self.checkFunctionAddress(expression, function);
        const target = try self.inferType(parameters, operand);
        if (!isPlace(operand.*)) return self.fail(operand.location, error.NotAddressable);
        if (ast.findConstantRoot(operand.*)) |constant| {
            try self.addresses.append(self.arena.allocator(), .{
                .constant = constant,
                .module = self.module_index,
                .location = operand.location,
            });
        }
        const pointer = try self.program.types.addPointer(self.arena.allocator(), .{
            .target = target,
            .many = false,
            .constant = !isWritable(operand.*),
        });
        expression.type = .{ .pointer = pointer };
        return expression.type.?;
    }

    fn checkFunctionAddress(
        self: *TypeChecker,
        expression: *ast.Expression,
        function: ast.Resolution,
    ) TypeError!types.Type {
        const operand = expression.kind.address_of;
        operand.type = try self.computeFunctionType(function);
        const pointer = try self.program.types.addPointer(self.arena.allocator(), .{
            .target = operand.type.?,
            .many = false,
            .constant = false,
        });
        expression.type = .{ .pointer = pointer };
        return expression.type.?;
    }

    fn checkCompositeLiteral(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        literal: ast.CompositeLiteral,
        expected: types.Type,
    ) TypeError!types.Type {
        const literal_type = if (literal.type) |written| ast.extractType(written.*) else expected;
        switch (literal_type) {
            .array => |array| {
                if (hasNames(literal.elements)) return self.fail(location, error.NotAStruct);
                if (literal.elements.len != array.length) {
                    return self.fail(location, error.WrongLength);
                }
                for (literal.elements) |*element| {
                    try self.checkExpression(parameters, &element.value, array.element);
                }
            },
            .tuple => |tuple| {
                if (hasNames(literal.elements)) return self.fail(location, error.NotAStruct);
                if (literal.elements.len != tuple.elements.len) {
                    return self.fail(location, error.WrongTupleLength);
                }
                for (literal.elements, tuple.elements) |*element, element_type| {
                    try self.checkExpression(parameters, &element.value, element_type);
                }
            },
            .@"struct" => |struct_type| {
                try self.checkConstruction(parameters, location, literal.elements, struct_type);
            },
            .number, .boolean, .void, .type, .slice, .pointer, .optional, .function, .implementer => {
                return self.fail(location, error.UnexpectedBraces);
            },
        }
        return literal_type;
    }

    fn checkConstruction(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        elements: []ast.Argument,
        struct_type: types.Struct,
    ) TypeError!void {
        for (elements, 0..) |*element, index| {
            const name = element.name orelse {
                return self.fail(element.location, error.MissingFieldName);
            };
            const field = findField(struct_type.fields, name) orelse {
                return self.fail(element.location, error.UnknownField);
            };
            if (ast.findArgument(elements, name) != index) {
                return self.fail(element.location, error.RepeatedField);
            }
            try self.checkExpression(parameters, &element.value, field.type);
        }
        for (struct_type.fields) |field| {
            if (field.default == null and ast.findArgument(elements, field.name) == null) {
                return self.fail(location, error.MissingField);
            }
        }
    }

    fn checkIndex(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const indexing = expression.kind.index;
        const index = indexing.index;
        const index_type: types.Type = .{ .number = .usize };
        const element_type = switch (try self.inferType(parameters, indexing.value)) {
            .array => |array| try self.checkArrayIndex(parameters, index, array),
            .tuple => |tuple| try self.checkTupleIndex(parameters, index, tuple),
            .slice => |slice| element: {
                try self.checkExpression(parameters, index, index_type);
                break :element slice.element;
            },
            .pointer => |pointer| element: {
                if (pointer.many) {
                    try self.checkExpression(parameters, index, index_type);
                    break :element pointer.target;
                }
                if (pointer.target != .array) {
                    return self.fail(expression.location, error.NotIndexable);
                }
                break :element try self.checkArrayIndex(parameters, index, pointer.target.array);
            },
            .number, .boolean, .void, .type, .@"struct", .optional, .function, .implementer => {
                return self.fail(expression.location, error.NotIndexable);
            },
        };
        expression.type = element_type;
        return element_type;
    }

    fn checkArrayIndex(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        index: *ast.Expression,
        array: *const types.Array,
    ) TypeError!types.Type {
        try self.checkExpression(parameters, index, .{ .number = .usize });
        if (array.length == 0) return self.fail(index.location, error.IndexOutOfRange);
        if (index.kind != .integer_literal) return array.element;
        const position = std.fmt.parseInt(u64, index.kind.integer_literal.text, 0) catch unreachable;
        if (position >= array.length) return self.fail(index.location, error.IndexOutOfRange);
        return array.element;
    }

    fn checkTupleIndex(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        index: *ast.Expression,
        tuple: *const types.Tuple,
    ) TypeError!types.Type {
        if (index.kind != .integer_literal) return self.fail(index.location, error.UnknownTupleIndex);
        try self.checkExpression(parameters, index, .{ .number = .usize });
        const position = std.fmt.parseInt(u64, index.kind.integer_literal.text, 0) catch unreachable;
        if (position >= tuple.elements.len) return self.fail(index.location, error.IndexOutOfRange);
        return tuple.elements[position];
    }

    fn inferSliceType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const slice = expression.kind.slice;
        const value = slice.value;
        const element: types.Type, const constant: bool = switch (try self.inferType(parameters, value)) {
            .array => |array| array: {
                if (!isPlace(value.*)) return self.fail(value.location, error.SlicedTemporary);
                break :array .{ array.element, !isWritable(value.*) };
            },
            .slice => |sliced| .{ sliced.element, sliced.constant },
            .pointer => |pointer| pointer: {
                if (pointer.many) {
                    if (slice.end == null) return self.fail(expression.location, error.MissingEnd);
                    break :pointer .{ pointer.target, pointer.constant };
                }
                if (pointer.target != .array) {
                    return self.fail(value.location, error.NotSliceable);
                }
                break :pointer .{ pointer.target.array.element, pointer.constant };
            },
            .number, .boolean, .void, .type, .@"struct", .optional, .tuple, .function, .implementer => {
                return self.fail(value.location, error.NotSliceable);
            },
        };
        const bound_type: types.Type = .{ .number = .usize };
        if (slice.start) |start| try self.checkExpression(parameters, start, bound_type);
        if (slice.end) |end| try self.checkExpression(parameters, end, bound_type);
        const allocator = self.arena.allocator();
        const slice_type = try self.program.types.addSlice(allocator, element, constant);
        expression.type = .{ .slice = slice_type };
        return expression.type.?;
    }

    fn checkDereference(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const pointer = switch (try self.inferType(parameters, expression.kind.dereference)) {
            .pointer => |pointer| pointer,
            .number, .boolean, .void, .type, .@"struct", .array, .slice, .optional, .tuple, .function, .implementer => {
                return self.fail(expression.location, error.NotAPointer);
            },
        };
        if (pointer.target == .function) return self.fail(expression.location, error.FunctionDereferenced);
        expression.type = pointer.target;
        return pointer.target;
    }

    fn checkUnwrap(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const optional_type = try self.inferType(parameters, expression.kind.unwrap);
        if (optional_type != .optional) return self.fail(expression.location, error.NotOptional);
        expression.type = optional_type.optional.child;
        return expression.type.?;
    }

    fn computeValueType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        resolution: ast.Resolution,
    ) TypeError!types.Type {
        return switch (resolution) {
            .parameter => |index| ast.extractType(parameters[index].type),
            .type => .type,
            .constant => |constant| self.checkConstant(constant),
            .local => |statement| switch (statement.kind) {
                .constant_declaration => |constant| ast.extractDeclaredType(constant.type, constant.value),
                .variable_declaration => |variable| ast.extractDeclaredType(variable.type, variable.value),
                .noop,
                .@"return",
                .discard,
                .call,
                .tuple_declaration,
                .assignment,
                .@"if",
                .@"while",
                .@"for",
                .@"break",
                .@"continue",
                => unreachable,
            },
            .element => |element| ast.findElementName(element).type.?,
            .function, .trait_function, .trait_method => self.fail(location, error.FunctionUsedAsValue),
        };
    }

    fn computeFunctionType(self: *TypeChecker, function: ast.Resolution) TypeError!types.Type {
        const signature = self.extractSignature(function);
        const allocator = self.arena.allocator();
        const parameters = try allocator.alloc(types.Type, signature.parameters.len);
        for (signature.parameters, parameters) |parameter, *parameter_type| {
            parameter_type.* = ast.extractType(parameter.type);
        }
        const return_type = ast.extractType(signature.return_type);
        const function_type = try self.program.types.addFunction(allocator, parameters, return_type);
        return .{ .function = function_type };
    }

    fn checkConstant(self: *TypeChecker, constant: ast.Resolution.Constant) TypeError!types.Type {
        const module = self.program.modules[constant.module];
        const declaration = &module.declarations[constant.declaration].kind.constant_declaration;
        const caller_module_index = self.module_index;
        const caller_default = self.default;
        self.module_index = constant.module;
        self.default = null;
        defer self.module_index = caller_module_index;
        defer self.default = caller_default;
        const written = if (declaration.type) |*written| written else null;
        return self.checkDeclaredValue(&.{}, written, &declaration.value);
    }

    fn checkDeclaredValue(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        written_type: ?*ast.Expression,
        value: *ast.Expression,
    ) TypeError!types.Type {
        if (value.type) |value_type| {
            const written = written_type orelse return value_type;
            return ast.extractType(written.*);
        }
        const written = written_type orelse return self.inferType(parameters, value);
        if (isUnfinishedArray(written.*)) return self.completeArrayType(parameters, written, value);
        const expected = ast.extractType(written.*);
        try self.checkExpression(parameters, value, expected);
        return expected;
    }

    fn completeArrayType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        written: *ast.Expression,
        value: *ast.Expression,
    ) TypeError!types.Type {
        if (value.kind == .undefined) return self.fail(value.location, error.MissingLength);
        const array_type = &written.kind.array_type;
        const value_type = try self.inferType(parameters, value);
        if (value_type != .array) return self.fail(value.location, error.MissingLength);
        const element = ast.extractType(array_type.element.*);
        if (!std.meta.eql(value_type.array.element, element)) {
            return self.fail(value.location, error.TypeMismatch);
        }
        value.type = value_type;
        array_type.value = value_type;
        return value_type;
    }

    fn computeLiteralType(
        self: *TypeChecker,
        location: token.Location,
        expression: ast.Expression,
    ) TypeError!types.Type {
        return switch (expression.kind) {
            .integer_literal, .float_literal => |literal| {
                const suffix = literal.suffix orelse {
                    return self.fail(location, error.UnknownValueType);
                };
                const number = types.findNumberType(suffix) orelse {
                    return self.fail(location, error.UnknownSuffix);
                };
                return .{ .number = number };
            },
            .boolean_literal => .boolean,
            .string_literal => {
                const allocator = self.arena.allocator();
                const slice = try self.program.types.addSlice(allocator, .{ .number = .u8 }, true);
                return .{ .slice = slice };
            },
            .undefined,
            .null,
            .identifier,
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
            .index,
            .slice,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .field_access,
            .dereference,
            .unwrap,
            => unreachable,
        };
    }

    fn checkLiteral(
        self: *TypeChecker,
        expression: ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        switch (expression.kind) {
            .integer_literal => |literal| {
                try self.checkInteger(expression.location, literal, expected, false);
            },
            .float_literal => |literal| try self.checkFloat(expression.location, literal, expected),
            .boolean_literal => {
                if (expected != .boolean) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .string_literal => {
                const text_type = try self.computeLiteralType(expression.location, expression);
                if (!isConvertible(text_type, expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .undefined,
            .null,
            .identifier,
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
            .index,
            .slice,
            .pointer_type,
            .optional_type,
            .tuple_type,
            .function_type,
            .field_access,
            .dereference,
            .unwrap,
            => unreachable,
        }
    }

    fn checkNegation(
        self: *TypeChecker,
        location: token.Location,
        operand: *ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        switch (operand.kind) {
            .integer_literal => |literal| try self.checkInteger(location, literal, expected, true),
            .float_literal => |literal| try self.checkFloat(location, literal, expected),
            else => unreachable,
        }
        operand.type = expected;
    }

    fn checkInteger(
        self: *TypeChecker,
        location: token.Location,
        literal: token.NumberLiteral,
        expected: types.Type,
        negative: bool,
    ) TypeError!void {
        const number = try self.expectNumber(location, literal, expected);
        const maximum = computeIntegerMaximum(number) orelse {
            return self.fail(location, error.TypeMismatch);
        };
        if (negative and !isSigned(number)) return self.fail(location, error.NegativeUnsigned);
        const value = std.fmt.parseInt(u128, literal.text, 0) catch {
            return self.fail(location, error.LiteralOutOfRange);
        };
        const limit = if (negative) maximum + 1 else maximum;
        if (value > limit) return self.fail(location, error.LiteralOutOfRange);
    }

    fn checkFloat(
        self: *TypeChecker,
        location: token.Location,
        literal: token.NumberLiteral,
        expected: types.Type,
    ) TypeError!void {
        const number = try self.expectNumber(location, literal, expected);
        const fits = switch (number) {
            .f16 => fitsFloat(f16, literal.text),
            .f32 => fitsFloat(f32, literal.text),
            .f64 => fitsFloat(f64, literal.text),
            .f128 => fitsFloat(f128, literal.text),
            else => return self.fail(location, error.TypeMismatch),
        };
        if (!fits) return self.fail(location, error.LiteralOutOfRange);
    }

    fn expectNumber(
        self: *TypeChecker,
        location: token.Location,
        literal: token.NumberLiteral,
        expected: types.Type,
    ) TypeError!types.NumberType {
        const number = switch (expected) {
            .number => |number| number,
            .boolean, .void, .type, .@"struct", .array, .slice, .pointer, .optional, .tuple, .function, .implementer => {
                return self.fail(location, error.TypeMismatch);
            },
        };
        const suffix = literal.suffix orelse return number;
        const suffix_type = types.findNumberType(suffix) orelse {
            return self.fail(location, error.UnknownSuffix);
        };
        if (suffix_type != number) return self.fail(location, error.TypeMismatch);
        return number;
    }

    fn fail(self: *TypeChecker, location: token.Location, type_error: TypeError) TypeError {
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = describeError(type_error),
        };
        return type_error;
    }
};

pub const TypeError = error{
    OutOfMemory,
    TypeMismatch,
    LiteralOutOfRange,
    NegativeUnsigned,
    MissingReturnValue,
    UnexpectedReturnValue,
    MissingReturn,
    MainHasReturnType,
    MainHasParameters,
    MainCalled,
    MainIsExternal,
    ArgumentCountMismatch,
    UnusedResult,
    DiscardedVoid,
    TypeVariable,
    UnexpectedUndefined,
    UndefinedRead,
    UnreachableStatement,
    UnexpectedNull,
    NotSliceable,
    SlicedTemporary,
    MissingEnd,
    NotIndexable,
    IndexOutOfRange,
    UnknownTupleIndex,
    NotAddressable,
    UnevaluatedAddress,
    MissingLength,
    CannotEvaluate,
    NotAPointer,
    NotOptional,
    SinglePointerArithmetic,
    ZeroSizedPointerArithmetic,
    NotWritable,
    NeverModified,
    UnusedVariable,
    PointlessDiscard,
    WrongLength,
    WrongTupleLength,
    UnexpectedBraces,
    NotCallable,
    FunctionUsedAsValue,
    FunctionDereferenced,
    UnknownMethod,
    AmbiguousMethod,
    NoSelf,
    UnknownSuffix,
    UnknownValueType,
    NoFields,
    UnknownField,
    NamedArgument,
    NotAStruct,
    MissingFieldName,
    RepeatedField,
    MissingField,
    NotNumeric,
    NotInteger,
    NotEquatable,
    NotOrdered,
    NegatedUnsigned,
    MismatchedOperands,
    NotSequence,
    ReversedRange,
    NotTuple,
    WrongNameCount,
    NotImplemented,
};

fn describeError(type_error: TypeError) []const u8 {
    return switch (type_error) {
        error.OutOfMemory => "out of memory",
        error.TypeMismatch => "value does not match the expected type",
        error.LiteralOutOfRange => "literal out of range for its type",
        error.NegativeUnsigned => "unsigned types cannot hold negative numbers",
        error.MissingReturnValue => "missing return value",
        error.UnexpectedReturnValue => "void function cannot return a value",
        error.MissingReturn => "every path must end with a return",
        error.MainHasReturnType => "main cannot have a return type",
        error.MainHasParameters => "main cannot have parameters",
        error.MainCalled => "main cannot be called",
        error.MainIsExternal => "main cannot be external",
        error.ArgumentCountMismatch => "wrong number of arguments",
        error.UnusedResult => "call result is unused, discard it with _ =",
        error.DiscardedVoid => "call returns no value to discard",
        error.TypeVariable => "variable cannot hold a type",
        error.UnexpectedUndefined => "undefined can only be the initial value of a variable",
        error.UndefinedRead => "variable is read before it is assigned",
        error.UnreachableStatement => "statement never runs",
        error.UnexpectedNull => "null can only be the value of an optional",
        error.NotSliceable => "only arrays, slices and multiple value pointers can be sliced",
        error.SlicedTemporary => "only arrays that are variables, constants, elements or fields can be sliced",
        error.MissingEnd => "a slice of a multiple value pointer needs an end",
        error.NotIndexable => "only arrays, slices, multiple value pointers and tuples can be indexed",
        error.IndexOutOfRange => "index is outside the length",
        error.UnknownTupleIndex => "a tuple index must be an integer literal",
        error.NotAddressable => "only variables, constants, elements, fields and functions have an address",
        error.MissingLength => "value has no length",
        error.UnevaluatedAddress => "the address of this constant cannot be taken until it can be evaluated at compile time",
        error.CannotEvaluate => "cannot be evaluated at compile time",
        error.NotAPointer => "only pointers can be dereferenced",
        error.NotOptional => "only optionals can be unwrapped",
        error.SinglePointerArithmetic => "only multiple value pointers support arithmetic",
        error.ZeroSizedPointerArithmetic => "pointers to zero-sized values do not support arithmetic",
        error.NotWritable => "value cannot be modified",
        error.NeverModified => "variable is never modified, declare it with const",
        error.UnusedVariable => "variable is unused, discard it with _ =",
        error.PointlessDiscard => "discarded name is used",
        error.WrongLength => "number of elements does not match the length of the array",
        error.WrongTupleLength => "number of elements does not match the tuple",
        error.UnexpectedBraces => "braces need an array, a tuple or a struct type",
        error.NotCallable => "only functions and function pointers can be called",
        error.FunctionUsedAsValue => "function is not a value, point to it with &",
        error.FunctionDereferenced => "function pointers cannot be dereferenced",
        error.UnknownMethod => "unknown method",
        error.AmbiguousMethod => "method is found in more than one place",
        error.NoSelf => "the first parameter is not Self",
        error.UnknownSuffix => "unknown suffix",
        error.UnknownValueType => "value has no known type",
        error.NoFields => "value has no fields",
        error.UnknownField => "unknown field",
        error.NamedArgument => "function arguments have no names",
        error.NotAStruct => "type is not a struct",
        error.MissingFieldName => "expected a field name",
        error.RepeatedField => "field is already given",
        error.MissingField => "missing field",
        error.NotNumeric => "operator needs integers or floats",
        error.NotInteger => "operator needs integers",
        error.NotEquatable => "only numbers, bool, pointers and arrays of them can be compared for equality",
        error.NotOrdered => "only numbers and multiple value pointers can be ordered",
        error.NegatedUnsigned => "unsigned integers cannot be negated",
        error.MismatchedOperands => "operands have different types",
        error.NotSequence => "only arrays, slices, pointers to arrays and ranges are sequences",
        error.ReversedRange => "range starts after its end",
        error.NotTuple => "names in parentheses need a tuple",
        error.WrongNameCount => "number of names does not match the tuple",
        error.NotImplemented => "type does not implement the trait",
    };
}

const Default = struct {
    trait: ast.Resolution.Trait,
    self_type: types.Type,
};

const Address = struct {
    constant: ast.Resolution.Constant,
    module: usize,
    location: token.Location,
};

const Trace = struct {
    variable: ?*const ast.Statement = null,
    exits: std.ArrayList(Exit) = .empty,
};

const Exit = struct {
    loop: *const ast.Statement,
    flow: Flow = .ended,
};

const Flow = enum {
    ended,
    unassigned,
    assigned,
};

const Use = union(enum) {
    none,
    read: token.Location,
    passed,
};

fn mergeFlows(one: Flow, two: Flow) Flow {
    if (one == .ended) return two;
    if (two == .ended) return one;
    if (one == .unassigned or two == .unassigned) return .unassigned;
    return .assigned;
}

fn findStatementUse(variable: *const ast.Statement, statement: ast.Statement) Use {
    return switch (statement.kind) {
        .noop, .@"break", .@"continue" => .none,
        .@"return" => |value| if (value) |expression| findUse(variable, expression) else .none,
        .discard => |expression| if (expression.kind == .identifier) .none else findUse(variable, expression),
        .call => |expression| findUse(variable, expression),
        .constant_declaration => |constant| findUse(variable, constant.value),
        .tuple_declaration => |declaration| findElementsUse(variable, declaration.names, declaration.value),
        .variable_declaration => |declaration| findUse(variable, declaration.value),
        .assignment => |assignment| use: {
            if (assignment.operator != null) {
                const target_use = findUse(variable, assignment.target);
                if (target_use != .none) break :use target_use;
            }
            const use = findUse(variable, assignment.value);
            if (use != .none) break :use use;
            const target_use = findTargetUse(variable, assignment.target);
            if (target_use != .none) break :use target_use;
            if (isRootedAt(assignment.target, variable)) break :use .passed;
            break :use .none;
        },
        .@"if" => |conditional| findUse(variable, conditional.condition),
        .@"while" => |loop| findUse(variable, loop.condition),
        .@"for" => |loop| switch (loop.sequence) {
            .value => |value| findElementsUse(variable, loop.names, value),
            .range => findSequenceUse(variable, loop.sequence),
        },
    };
}

fn findElementsUse(
    variable: *const ast.Statement,
    names: []const ast.ElementName,
    container: ast.Expression,
) Use {
    const copied = for (names) |name| {
        if (!name.pointer and !ast.isDiscardedName(name.name)) break true;
    } else false;
    const addressed = ast.hasPointerName(names) and isStorage(container);
    if (!copied and addressed and isRootedAt(container, variable)) return .passed;
    return findUse(variable, container);
}

fn findSequenceUse(variable: *const ast.Statement, sequence: ast.Sequence) Use {
    return switch (sequence) {
        .value => |value| findUse(variable, value),
        .range => |range| use: {
            const start = findUse(variable, range.start);
            if (start != .none) break :use start;
            const end = range.end orelse break :use .none;
            break :use findUse(variable, end);
        },
    };
}

fn isEndless(statement: ast.Statement) bool {
    return switch (statement.kind) {
        .@"while" => |loop| loop.condition.kind == .boolean_literal and loop.condition.kind.boolean_literal,
        .@"for" => |loop| loop.sequence == .range and loop.sequence.range.end == null,
        .noop, .@"return", .discard, .call, .constant_declaration, .tuple_declaration, .variable_declaration => false,
        .assignment, .@"if", .@"break", .@"continue" => false,
    };
}

fn isUnfinishedArray(written: ast.Expression) bool {
    return written.kind == .array_type and written.kind.array_type.value == null;
}

fn isConvertible(value_type: types.Type, expected: types.Type) bool {
    if (isReadOnlyMatch(value_type, expected)) return true;
    if (expected != .slice or value_type != .pointer) return false;
    const pointer = value_type.pointer;
    if (pointer.many or pointer.target != .array) return false;
    if (pointer.constant and !expected.slice.constant) return false;
    return std.meta.eql(pointer.target.array.element, expected.slice.element);
}

fn isReadOnlyMatch(value_type: types.Type, expected: types.Type) bool {
    if (std.meta.eql(value_type, expected)) return true;
    if (value_type == .pointer and expected == .pointer) {
        const pointer = value_type.pointer;
        if (pointer.many != expected.pointer.many) return false;
        return expected.pointer.constant and std.meta.eql(pointer.target, expected.pointer.target);
    }
    if (value_type != .slice or expected != .slice) return false;
    const element = value_type.slice.element;
    return expected.slice.constant and std.meta.eql(element, expected.slice.element);
}

fn hasOwnType(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .integer_literal, .float_literal => |literal| literal.suffix != null,
        .negation => |operand| hasOwnType(operand.*),
        .composite_literal => |literal| literal.type != null,
        .null, .undefined => false,
        .unary => |unary| unary.operator == .not or hasOwnType(unary.operand.*),
        .binary => |binary| switch (binary.operator) {
            .shift_left, .shift_right, .@"orelse" => hasOwnType(binary.left.*),
            .add,
            .subtract,
            .multiply,
            .divide,
            .remainder,
            .bitwise_and,
            .bitwise_exclusive_or,
            .bitwise_or,
            => hasOwnType(binary.left.*) or hasOwnType(binary.right.*),
            .equal,
            .not_equal,
            .less_than,
            .less_than_or_equal,
            .greater_than,
            .greater_than_or_equal,
            .@"and",
            .@"or",
            => true,
        },
        .boolean_literal,
        .string_literal,
        .identifier,
        .path_expression,
        .call,
        .method_call,
        .address_of,
        .array_type,
        .slice_type,
        .index,
        .slice,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        .field_access,
        .dereference,
        .unwrap,
        => true,
    };
}

fn hasNames(elements: []const ast.Argument) bool {
    for (elements) |element| {
        if (element.name != null) return true;
    }
    return false;
}

fn unifyTypes(one: types.Type, two: types.Type) ?types.Type {
    if (isReadOnlyMatch(one, two)) return two;
    if (isReadOnlyMatch(two, one)) return one;
    return null;
}

fn isEquatable(value_type: types.Type) bool {
    return switch (value_type) {
        .number, .boolean, .pointer => true,
        .array => |array| isEquatable(array.element),
        .optional => |optional| isEquatable(optional.child),
        .void, .type, .@"struct", .slice, .tuple, .function, .implementer => false,
    };
}

fn comparesByParts(value_type: types.Type) bool {
    if (value_type != .array and value_type != .optional) return false;
    return !isZeroSized(value_type);
}

fn isOrdered(value_type: types.Type) bool {
    return switch (value_type) {
        .number => true,
        .pointer => |pointer| pointer.many,
        .boolean, .void, .type, .@"struct", .array, .slice, .optional, .tuple, .function, .implementer => {
            return false;
        },
    };
}

fn isInteger(value_type: types.Type) bool {
    return value_type == .number and computeIntegerMaximum(value_type.number) != null;
}

fn findField(fields: []const types.Field, name: []const u8) ?types.Field {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn findFunction(expression: ast.Expression) ?ast.Resolution {
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| switch (name.resolution.?) {
            .function, .trait_function => name.resolution.?,
            .parameter, .type, .constant, .local, .element, .trait_method => null,
        },
        else => null,
    };
}

fn isTraitVisible(module: ast.Module, module_index: usize, trait: ast.Resolution.Trait) bool {
    for (module.declarations, 0..) |declaration, index| {
        switch (declaration.kind) {
            .trait_definition => {
                if (trait.module == module_index and trait.declaration == index) return true;
            },
            .import => |import| {
                const imported = import.trait orelse continue;
                if (std.meta.eql(imported, trait)) return true;
            },
            .function_declaration,
            .function_definition,
            .constant_declaration,
            .struct_definition,
            .implementation,
            => {},
        }
    }
    return false;
}

fn isPlace(expression: ast.Expression) bool {
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| switch (name.resolution.?) {
            .local, .parameter, .constant, .element => true,
            .function, .type, .trait_function, .trait_method => false,
        },
        .field_access => |access| access.value.type.? == .pointer or isPlace(access.value.*),
        .index => |indexing| isElementPlace(indexing.value.*),
        .dereference => true,
        else => false,
    };
}

fn isElementPlace(container: ast.Expression) bool {
    return !isStorage(container) or isPlace(container);
}

fn isWritable(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .identifier => |identifier| switch (identifier.resolution.?) {
            .local => |statement| statement.kind == .variable_declaration,
            .parameter, .function, .type, .constant, .element, .trait_function, .trait_method => false,
        },
        .field_access => |access| switch (access.value.type.?) {
            .pointer => |pointer| !pointer.constant,
            .number, .boolean, .void, .type, .@"struct", .array, .slice, .optional, .tuple, .function, .implementer => {
                return isWritable(access.value.*);
            },
        },
        .index => |indexing| isElementWritable(indexing.value.*),
        .dereference => |operand| !operand.type.?.pointer.constant,
        else => false,
    };
}

fn isElementWritable(container: ast.Expression) bool {
    return switch (container.type.?) {
        .slice => |slice| !slice.constant,
        .pointer => |pointer| !pointer.constant,
        .number, .boolean, .void, .type, .@"struct", .array, .optional, .tuple, .function, .implementer => {
            return isWritable(container);
        },
    };
}

fn isStorage(value: ast.Expression) bool {
    const value_type = value.type.?;
    return value_type == .array or value_type == .tuple;
}

fn findUse(variable: *const ast.Statement, expression: ast.Expression) Use {
    switch (expression.kind) {
        .identifier => {
            if (isRootedAt(expression, variable)) return .{ .read = expression.location };
            return .none;
        },
        .field_access => |access| {
            if (isRootedAt(expression, variable)) return .{ .read = findRoot(expression).location };
            return findUse(variable, access.value.*);
        },
        .index => |indexing| {
            const use = findUse(variable, indexing.value.*);
            if (use != .none) return use;
            return findUse(variable, indexing.index.*);
        },
        .slice => |slice| {
            for ([_]?*ast.Expression{ slice.start, slice.end }) |optional_bound| {
                const bound = optional_bound orelse continue;
                const use = findUse(variable, bound.*);
                if (use != .none) return use;
            }
            if (isStorage(slice.value.*) and isRootedAt(slice.value.*, variable)) return .passed;
            return findUse(variable, slice.value.*);
        },
        .address_of => |operand| {
            if (isRootedAt(operand.*, variable)) return .passed;
            return findUse(variable, operand.*);
        },
        .dereference, .unwrap => |operand| return findUse(variable, operand.*),
        .call => |call| {
            const resolution = ast.extractResolution(call.callee);
            if (resolution == .local and resolution.local == variable) {
                return .{ .read = expression.location };
            }
            for (call.arguments) |argument| {
                const passed = argument.value.kind == .identifier and
                    isRootedAt(argument.value, variable);
                if (passed) return .passed;
                const use = findUse(variable, argument.value);
                if (use != .none) return use;
            }
            return .none;
        },
        .method_call => |call| {
            if (isRootedAt(call.receiver.*, variable)) return .passed;
            const receiver_use = findUse(variable, call.receiver.*);
            if (receiver_use != .none) return receiver_use;
            for (call.arguments) |argument| {
                const use = findUse(variable, argument.value);
                if (use != .none) return use;
            }
            return .none;
        },
        .composite_literal => |literal| {
            for (literal.elements) |element| {
                const use = findUse(variable, element.value);
                if (use != .none) return use;
            }
            return .none;
        },
        .binary => |binary| {
            const use = findUse(variable, binary.left.*);
            if (use != .none) return use;
            return findUse(variable, binary.right.*);
        },
        .unary => |unary| return findUse(variable, unary.operand.*),
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .path_expression,
        .negation,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        => return .none,
    }
}

fn findTargetUse(variable: *const ast.Statement, target: ast.Expression) Use {
    switch (target.kind) {
        .field_access => |access| {
            if (access.value.type.? == .pointer) return findUse(variable, access.value.*);
            return findTargetUse(variable, access.value.*);
        },
        .index => |indexing| {
            const use = if (isStorage(indexing.value.*))
                findTargetUse(variable, indexing.value.*)
            else
                findUse(variable, indexing.value.*);
            if (use != .none) return use;
            return findUse(variable, indexing.index.*);
        },
        .dereference => |operand| return findUse(variable, operand.*),
        else => return .none,
    }
}

fn recordTargetUses(
    use: *ast.Use,
    variable: *const ast.Statement,
    statements: []const ast.Statement,
) void {
    for (statements) |statement| {
        switch (statement.kind) {
            .assignment => |assignment| {
                const target = assignment.target;
                if (target.kind == .identifier) continue;
                if (!isNamed(findTargetBase(target), variable)) continue;
                if (isRootedAt(target, variable)) {
                    use.modified = true;
                } else {
                    use.used = true;
                }
            },
            .@"if", .@"while", .@"for" => {
                for (ast.extractBlocks(statement)) |block| recordTargetUses(use, variable, block);
            },
            .noop,
            .@"return",
            .discard,
            .call,
            .constant_declaration,
            .tuple_declaration,
            .variable_declaration,
            .@"break",
            .@"continue",
            => {},
        }
    }
}

fn findTargetBase(target: ast.Expression) ast.Expression {
    return switch (target.kind) {
        .field_access => |access| findTargetBase(access.value.*),
        .index => |indexing| findTargetBase(indexing.value.*),
        else => target,
    };
}

fn isRootedAt(expression: ast.Expression, variable: *const ast.Statement) bool {
    return isNamed(findRoot(expression), variable);
}

fn findRoot(expression: ast.Expression) ast.Expression {
    return switch (expression.kind) {
        .field_access => |access| {
            if (access.value.type.? == .pointer) return expression;
            return findRoot(access.value.*);
        },
        .index => |indexing| if (isStorage(indexing.value.*)) findRoot(indexing.value.*) else expression,
        else => expression,
    };
}

fn isNamed(expression: ast.Expression, variable: *const ast.Statement) bool {
    if (expression.kind != .identifier) return false;
    const resolution = expression.kind.identifier.resolution orelse return false;
    return resolution == .local and resolution.local == variable;
}

fn computeIntegerMaximum(number: types.NumberType) ?u128 {
    return switch (number) {
        .i8 => std.math.maxInt(i8),
        .i16 => std.math.maxInt(i16),
        .i32 => std.math.maxInt(i32),
        .i64, .isize => std.math.maxInt(i64),
        .i128 => std.math.maxInt(i128),
        .u8 => std.math.maxInt(u8),
        .u16 => std.math.maxInt(u16),
        .u32 => std.math.maxInt(u32),
        .u64, .usize => std.math.maxInt(u64),
        .u128 => std.math.maxInt(u128),
        .f16, .f32, .f64, .f128 => null,
    };
}

fn isSigned(number: types.NumberType) bool {
    return switch (number) {
        .i8, .i16, .i32, .i64, .i128, .isize, .f16, .f32, .f64, .f128 => true,
        .u8, .u16, .u32, .u64, .u128, .usize => false,
    };
}

fn fitsFloat(comptime Float: type, text: []const u8) bool {
    const value = std.fmt.parseFloat(Float, text) catch return false;
    return std.math.isFinite(value);
}

test "TypeChecker.check: sets the type of each returned value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u8: return 255\nfn two() -> f32: return 2.5\nfn three() -> bool: return true\nfn four() -> i64: return 1_i64\nfn main(): return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .u8 }, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .f32 }, loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type.boolean, loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .i64 }, loader.modules.items[0].declarations[3].kind.function_definition.body[0].kind.@"return".?.type);
}

test "TypeChecker.check: sets the type of calls, arguments and names" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) -> i32:\n    _ = right\n    return left\nfn main(): _ = add(1, 2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .i32 }, loader.modules.items[0].declarations[0].kind.function_definition.body[1].kind.@"return".?.type);
    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.type);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.kind.call.arguments[0].value.type);
}

test "TypeChecker.check: rejects an unused top-level constant of an unsuffixed literal without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, type_checker.failure.?.location.?);
}

test "TypeChecker.check: rejects an unused top-level constant of null without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const nothing = null\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, type_checker.failure.?.location.?);
}

test "TypeChecker.check: rejects an unused top-level constant of braces without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values = {1, 2}\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, type_checker.failure.?.location.?);
}

test "TypeChecker.check: rejects an unused top-level constant of another type than its written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: u8 = true\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkDefault: checks a default that no implementation uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(_: Self) -> i32: return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 39 }, type_checker.failure.?.location.?);
}

test "checkDefault: checks a default against the trait before the implementations that use it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.side" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoFields, type_checker.check());
    try std.testing.expectEqualStrings("shapes", type_checker.failure.?.module.?[0]);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkFieldDefaults: gives a struct literal default the type of its field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct DataOne:\n    value: i32\nstruct DataTwo:\n    value: DataOne = {value = 0}\nfn make() -> DataTwo: return DataTwo{}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const default = loader.modules.items[0].declarations[1].kind.struct_definition.fields[0].default.?;
    try std.testing.expectEqualStrings("DataOne", default.type.?.@"struct".name);
}

test "checkFieldDefaults: rejects a default of another type than its field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    size: i32 = true\nfn show(box: Box): _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkFieldDefaults: reports errors in the module of the struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Box:\n    size: i32 = true" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn show(box: shapes::Box): _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[1].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects a return type on main" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main() -> i32: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MainHasReturnType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects parameters on main" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(value: i32): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MainHasParameters, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 9 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects a missing return" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkFunction: treats a method named main as a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn main(self: Self) -> i32:\n        _ = self\n        return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "checkFunction: accepts a function whose every branch returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(one: bool, two: bool) -> i32:\n    if one:\n        return 1\n    else if two:\n        return 2\n    else:\n        return 3\nfn main(): _ = pick(true, false)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkFunction: rejects a function with a branch that does not return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(one: bool) -> i32:\n    if one: return 1\nfn main(): _ = pick(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 23 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects an endless loop that a break leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() -> i32:\n    while true: break\nfn main(): _ = first()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, type_checker.failure.?.location.?);
}

test "checkFunction: accepts an endless loop that only an inner loop breaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: bool) -> i32:\n    while true:\n        while running: break\nfn main(): _ = first(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkFunction: rejects an endless loop that a labeled break of an inner loop leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: bool) -> i32:\n    outer: while true:\n        while running: break outer\nfn main(): _ = first(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkFunction: accepts a loop whose else block returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: bool) -> i32:\n    while running: noop\n    else: return 1\nfn main(): _ = first(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkFunction: rejects a break that skips the else block that returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: bool) -> i32:\n    while running: break\n    else: return 1\nfn main(): _ = first(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "traceBlock: rejects a statement after a return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    return\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "traceBlock: rejects a statement after a return in a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true:\n        return\n        step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 9 }, type_checker.failure.?.location.?);
}

test "traceBlock: rejects a statement after a break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true:\n        break\n        step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 9 }, type_checker.failure.?.location.?);
}

test "traceBlock: rejects a statement after a continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true:\n        continue\n        step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 9 }, type_checker.failure.?.location.?);
}

test "traceStatement: rejects a statement after an if whose every block ends the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    if true: return\n    else: return\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "traceStatement: accepts a statement after an if without an else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    if true: return\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "traceStatement: rejects a statement after a loop that never ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true: step()\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "traceStatement: rejects a statement after a for loop over a range without an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    for _ in 0..: step()\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "traceStatement: accepts a statement after an endless loop that a break leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true: break\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "traceStatement: accepts a statement after a for loop over a range without an end that a break leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    for _ in 0..: break\n    step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "traceStatement: rejects the else block of a loop that never ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn main():\n    while true: break\n    else: step()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 11 }, type_checker.failure.?.location.?);
}

test "traceStatement: accepts a statement after a loop whose body returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn run(running: bool):\n    while running: return\n    step()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "traceStatement: rejects a statement after a loop whose else block returns and that has no break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn step(): noop\nfn run(running: bool):\n    while running: noop\n    else: return\n    step()\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "traceStatement: accepts a statement after a for loop whose body returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(items: []const i32) -> i32:\n    for item in items: return item\n    return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "traceStatement: rejects a statement after a for loop whose else block returns and that has no break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(items: []const i32) -> i32:\n    for item in items: _ = item\n    else: return 1\n    return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnreachableStatement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a variable whose field is only assigned" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a variable whose element is only assigned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values = [2]i32{1, 2}\n    values[0] = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a variable whose field is only assigned in a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    while false:\n        point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a variable whose field is only assigned in a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    for _ in 0..3:\n        point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: accepts discarding a variable whose field is only assigned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    point.x = 2\n    _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkDeferredUses: rejects a pointer variable that is only written through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    var pointer = &point\n    pointer.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NeverModified, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a slice variable that is only written through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var buffer: [2]u8 = undefined\n    var bytes = buffer[..]\n    bytes[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NeverModified, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects an array variable that is only written through the pointers it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    var pointers = [1]*Point{&point}\n    pointers[0].x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NeverModified, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: accepts a variable whose field is only compound assigned" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkDeferredUses: rejects a pointer variable that is only compound assigned through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    var pointer = &point\n    pointer.x += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NeverModified, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects discarding a variable that is written through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var one = Point{x = 1}\n    var two = Point{x = 2}\n    var pointer = &one\n    pointer = &two\n    pointer.x = 3\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.PointlessDiscard, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 9 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: rejects a variable whose field is only assigned in an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    if false: noop\n    else: point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkDeferredUses: checks a variable declared in the else block of a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    while false: noop\n    else:\n        var point = Point{x = 1}\n        point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnusedVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 9 }, type_checker.failure.?.location.?);
}

test "checkUndefinedReads: checks a variable declared inside a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    while true:\n        var count: i32 = undefined\n        const copy = count\n        count = 1\n        _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkUndefinedReads: checks a variable declared in an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    if true: noop\n    else:\n        var count: i32 = undefined\n        const copy = count\n        count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read right after the declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    const copy = count\n    count = 1\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    count = 1\n    const copy = count\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: accepts a read after the variable is passed to a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(buffer: [4]u8): _ = buffer\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer)\n    const copy = buffer\n    buffer = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: accepts a read after a field assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point: Point = undefined\n    point.x = 1\n    const copy = point\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects a compound assignment right after the declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> i32:\n    var total: i32 = undefined\n    total += 1\n    return total" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a compound assignment to a field before an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read() -> i32:\n    var point: Point = undefined\n    point.x += 1\n    return point.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in the value of its own assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    count = count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 13 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a field read before an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn take(value: i32): _ = value\nfn main():\n    var point: Point = undefined\n    take(point.x)\n    point.x = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after an element assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values: [2]i32 = undefined\n    values[0] = 1\n    const copy = values\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects an element read before an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    var values: [2]i32 = undefined\n    take(values[0])\n    values[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in an assigned index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values = [2]i32{1, 2}\n    var position: usize = undefined\n    values[position] = 3\n    position = 1\n    const copy = values\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects writing through an undefined pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    var pointer: *i32 = undefined\n    pointer.* = 2\n    pointer = &value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects writing a field through an undefined pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    var pointer: *Point = undefined\n    pointer.x = 2\n    pointer = &point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects writing an element of an undefined slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var buffer: [2]u8 = undefined\n    var bytes: []u8 = undefined\n    bytes[0] = 1\n    bytes = buffer[..]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in a dereference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    var pointer: *i32 = undefined\n    const copy = pointer.*\n    pointer = &value\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects passing the variable to a construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Box:\n    value: i32\nfn main():\n    var value: i32 = undefined\n    const box = Box{value = value}\n    value = 1\n    _ = box" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read after a loop that does not assign the variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    while false: noop\n    const copy = count\n    count = 1\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: ends the check at a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(buffer[..])\n    const copy = buffer\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects slicing an undefined slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [2]u8 = undefined\n    var bytes: []u8 = undefined\n    take(bytes[..])\n    bytes = buffer[..]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in a slice bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    var end: usize = undefined\n    take(buffer[..end])\n    end = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: ends the check at an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(pointer: *i32): pointer.* = 1\nfn main():\n    var value: i32 = undefined\n    fill(&value)\n    const copy = value\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects calling the variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(): noop\nfn main():\n    var step: *fn() = undefined\n    step()\n    step = &first" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in an operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    const next: i32 = count + 1\n    _ = next\n    count = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 23 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read after an if that assigns the variable in one branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    if true: count = 1\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after an if that assigns the variable in every branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    if true: count = 1\n    else: count = 2\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: accepts a read after an if whose other branch ends the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    if true: count = 1\n    else: return\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects a read in an if condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var ready: bool = undefined\n    if ready: noop\n    ready = true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 8 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in a loop body before the assignment in the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    while true:\n        const copy = count\n        count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read after a loop that assigns the variable in its body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(running: bool):\n    var count: i32 = undefined\n    while running: count = 1\n    const copy = count\n    count = copy\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after an endless loop that assigns the variable before its break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    while true:\n        count = 1\n        break\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects a read after a break that leaves before the assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(early: bool):\n    var count: i32 = undefined\n    while true:\n        if early: break\n        count = 1\n        break\n    const copy = count\n    count = copy\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read after a labeled break that leaves before the assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(early: bool):\n    var count: i32 = undefined\n    outer: while true:\n        while early: break outer\n        count = 1\n        break\n    const copy = count\n    count = copy\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 7, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after a loop whose else block assigns the variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(running: bool):\n    var count: i32 = undefined\n    while running: noop\n    else: count = 1\n    const copy = count\n    count = copy\nfn main(): run(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects a read after a for loop that assigns the variable in its body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    for _ in 0..3: count = 1\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in a sequence of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    var items: [2]i32 = undefined\n    for item in items: take(item)\n    items[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects a read in the end of a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize): _ = value\nfn main():\n    var last: usize = undefined\n    for index in 0..last: take(index)\n    last = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 21 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: accepts a read after a for loop whose else block assigns the variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    for _ in 0..3: noop\n    else: count = 1\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkUndefinedVariable: rejects a read after a break of a for loop that skips the assignment in its else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count: i32 = undefined\n    for index in 0..3:\n        if index == 1: break\n    else: count = 1\n    const copy = count\n    count = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: rejects taking apart a variable before an assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var pair: [i32, bool] = undefined\n    const (number, _) = pair\n    _ = number\n    pair = {1, true}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UndefinedRead, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkUndefinedVariable: ends the check at a pointer name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var pair: [i32, bool] = undefined\n    const (*number, _) = pair\n    number.* = 1\n    const copy = pair\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkExternalFunction: rejects an external main" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn main()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MainIsExternal, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 1 }, type_checker.failure.?.location.?);
}

test "checkConstantComparisons: rejects comparing optionals in a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const one: ?i32 = null\nconst two: ?i32 = null\nconst same = one == two\nfn read() -> bool: return same" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.CannotEvaluate, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 14 }, type_checker.failure.?.location.?);
}

test "checkConstantComparisons: accepts comparing numbers in a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const same = 1i32 == 1i32\nfn read() -> bool: return same" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkAddresses: rejects the address of a constant that shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const mask = 1i32 << 2\nexternal fn keep(value: *const i32)\nfn main(): keep(&mask)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkAddresses: rejects the address of a constant with a remainder of signed integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const rest = -7i32 % 3i32\nexternal fn keep(value: *const i32)\nfn main(): keep(&rest)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkAddresses: accepts the address of a constant with a remainder of unsigned integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const rest = 7u32 % 3u32\nexternal fn keep(value: *const u32)\nfn main(): keep(&rest)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkAddresses: rejects the address of a constant that compares arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const values: [2]i32 = {1, 2}\nconst same = values == values\nexternal fn keep(value: *const bool)\nfn main(): keep(&same)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkAddresses: rejects the address of a constant whose operation uses a constant with an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const base = 2i32\nconst limit = base + 1i32\nexternal fn keep(value: *const i32)\nfn main():\n    keep(&base)\n    keep(&limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 11 }, type_checker.failure.?.location.?);
}

test "checkAddresses: accepts the address of a constant whose operation uses a constant without an address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const base = 2i32\nconst limit = base + 1i32\nexternal fn keep(value: *const i32)\nfn main(): keep(&limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkAddresses: rejects the address of an element of a constant that refers to a constant that shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const mask = 1i32 << 2\nconst pair = [i32, bool]{mask, true}\nexternal fn keep(value: *const i32)\nfn main(): keep(&pair[0])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkAddresses: accepts the address of a local constant that holds a shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const mask = 1i32 << 2\nexternal fn keep(value: *const i32)\nfn main():\n    const copy = mask\n    keep(&copy)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkFunction: accepts a function that ends with an endless loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() -> i32:\n    while true:\n        return 1\nfn main(): _ = first()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "checkFunction: accepts a function that ends with a for loop over a range without an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first() -> i32:\n    for _ in 0..: noop\nfn main(): _ = first()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "checkFunction: rejects a function that ends with a loop that can end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: bool) -> i32:\n    while running:\n        return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkFunction: rejects a function that ends with a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(items: []const i32) -> i32:\n    for item in items: return item" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkFunction: accepts a for loop whose else block returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(items: []const i32) -> i32:\n    for item in items:\n        if item > 0: return item\n    else: return 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects a missing return value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: return" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 21 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a value in a void function" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): return 5" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects an unused result" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return 1\nfn main(): one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnusedResult, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects discarding a void call" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn main(): _ = log()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.DiscardedVoid, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkStatement: checks the value of a local constant at its statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const limit: i32 = true\n    const copy = limit\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts a local constant of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn work(): noop\nfn main():\n    const result = work()\n    _ = result" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type.void, value.type.?);
}

test "checkStatement: checks a local constant with the parameters of its function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32) -> i32:\n    const copy: i32 = value\n    return copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, body[0].kind.constant_declaration.value.type);
}

test "checkStatement: accepts each compound assignment of an integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update() -> i32:\n    var total = 10i32\n    total += 1\n    total -= 1\n    total *= 1\n    total /= 1\n    total %= 1\n    total &= 1\n    total |= 1\n    total ^= 1\n    total <<= 1\n    total >>= 1\n    return total" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, body[1].kind.assignment.value.type.?);
    try std.testing.expectEqual(types.Type{ .number = .usize }, body[9].kind.assignment.value.type.?);
}

test "checkStatement: checks an unsuffixed literal in a compound assignment against the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update() -> u8:\n    var small = 1u8\n    small += 300\n    return small" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 14 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a shift amount that is not a usize in a compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update(amount: i32) -> i32:\n    var total = 1i32\n    total <<= amount\n    return total" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a remainder compound assignment of floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update() -> f64:\n    var total = 1.5f64\n    total %= 2.0\n    return total" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotInteger, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 11 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects an additive compound assignment of a bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn update() -> bool:\n    var flag = true\n    flag += true\n    return flag" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotNumeric, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkStatement: moves a multiple value pointer with compound assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn advance(items: *many i32) -> *many i32:\n    var cursor = items\n    cursor += 2\n    cursor -= 1\n    return cursor" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects a compound assignment that gives the difference of pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn advance(items: *many i32) -> *many i32:\n    var cursor = items\n    cursor -= items\n    return cursor" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a compound assignment to an element that cannot be modified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(values: [2]i32): values[0] += 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects an assignment of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count = 1i32\n    count = true\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 13 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects assigning to a field of a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    const point = Point{x = 1}\n    point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects assigning to a field of a name of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn show(points: []Point): for point in points: point.x = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects assigning to a field of a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return Point{x = 1}\nfn main(): make().x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing an element of a variable array and tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var values = [2]i32{1, 2}\n    var pair = [i32, bool]{1, true}\n    values[0] = 3\n    pair[1] = false\n    const copy = values\n    const other = pair\n    _ = copy\n    _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing an element of a constant array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [2]i32{1, 2}\n    values[0] = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects writing an element of a parameter array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: [2]i32): values[0] = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing an element of a mutable slice held in a constant" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing an element of a read-only slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []const u8): bytes[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing through a pointer held in a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var value = 1i32\n    const pointer = &value\n    pointer.* = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing through a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(pointer: *const i32): pointer.* = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing an element through a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(items: *many u8): items[1] = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing an element through a read-only multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(items: *many const u8): items[1] = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing a field through a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn move(point: *Point): point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing a field through a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn move(point: *const Point): point.x = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing a field through a pointer returned by a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nexternal fn locate() -> *Point\nfn main(): locate().x = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: accepts writing an element of the array behind a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: *[2]i32): values[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing a field of an unwrapped optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn set(maybe: ?Point): maybe.?.x = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts writing a field through an unwrapped optional pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn set(maybe: ?*Point): maybe.?.x = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkStatement: rejects writing an element of the array behind a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: *const [2]i32): values[0] = 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkStatement: accepts a variable of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn work(): noop\nfn main():\n    var result = work()\n    result = work()\n    _ = result" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.variable_declaration.value;
    try std.testing.expectEqual(types.Type.void, value.type.?);
}

test "checkStatement: accepts declarations named like built-in types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const bool: i32 = 5\nfn get() -> i32:\n    const u8 = bool\n    var char = u8\n    char = 1\n    return char" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, body[1].kind.variable_declaration.value.type.?);
}

test "checkStatement: rejects a variable of an unsuffixed literal without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var count = 1\n    count = 2\n    _ = count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a variable that holds a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var kind = i32\n    kind = i32\n    _ = kind" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects a while condition that is not a bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): while 1i32: noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkStatement: checks the statements of a while body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): while true: return 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkStatement: rejects an if condition that is not a bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): if 1i32: noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 15 }, type_checker.failure.?.location.?);
}

test "checkStatement: checks the statements of an else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    if true: noop\n    else: return 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkStatement: checks the statements of the else block of a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    while false: noop\n    else: return 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkStatement: checks the statements of the else block of a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    for _ in 0..3: noop\n    else: return 1i32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedReturnValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkStatement: gives a struct literal in an assignment the type of the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data:\n    var data = Data{value = 1}\n    data = {value = 2}\n    return data" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqualStrings("Data", body[1].kind.assignment.value.type.?.@"struct".name);
}

test "checkStatement: rejects taking apart a value without a type of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const (number, flag) = {1, true}\n    _ = number\n    _ = flag" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkElementNames: gives each name of a tuple declaration the type of its element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(pair: [i32, bool]):\n    const (number, flag) = pair\n    _ = number\n    _ = flag" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const names = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.tuple_declaration.names;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, names[0].type.?);
    try std.testing.expectEqual(types.Type.boolean, names[1].type.?);
}

test "checkElementNames: gives each name in parentheses of a for loop the type of its element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(pairs: [][i32, bool]):\n    for (number, flag) in pairs:\n        _ = number\n        _ = flag" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const names = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"for".names;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, names[0].type.?);
    try std.testing.expectEqual(types.Type.boolean, names[1].type.?);
}

test "checkElementNames: rejects taking apart a value that is not a tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32):\n    const (number) = value\n    _ = number" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotTuple, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkElementNames: rejects names in parentheses over elements that are not tuples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: []i32):\n    for (number) in values: _ = number" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotTuple, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 21 }, type_checker.failure.?.location.?);
}

test "checkElementNames: rejects another number of names than elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(pair: [i32, bool]):\n    const (number) = pair\n    _ = number" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongNameCount, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkElementNames: rejects another number of names than elements in a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(pairs: [][i32, bool]):\n    for (number, flag, other) in pairs:\n        _ = number\n        _ = flag\n        _ = other" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongNameCount, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: gives a pointer name a pointer to its element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var pair = [i32, bool]{1, true}\n    const (*number, _) = pair\n    number.* = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const name = loader.modules.items[0].declarations[0].kind.function_definition.body[1].kind.tuple_declaration.names[0];
    try std.testing.expectEqual(types.Type{ .number = .i32 }, name.type.?.pointer.target);
    try std.testing.expect(!name.type.?.pointer.constant);
}

test "checkElementAddress: gives a read-only pointer to an element of a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const pair = [i32, bool]{1, true}\n    const (*number, _) = pair\n    number.* = 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: gives a read-only pointer to an element of a constant array in a for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const cards = [2]i32{1, 2}\n    for *card in cards: card.* = 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: gives a pointer to an element of a mutable slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: []i32): for *value in values: value.* = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkElementAddress: gives a read-only pointer to an element of a read-only slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(values: []const i32): for *value in values: value.* = 0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotWritable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 53 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: rejects a pointer name over a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): for *index in 0..3: _ = index" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAddressable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: rejects a pointer name over an element of a call result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {1, true}\nfn main():\n    const (*number, _) = make()\n    _ = number" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAddressable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkElementAddress: rejects the address of an element of a constant that shifts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const pair = [i32, bool]{1i32 << 2, true}\nfn main():\n    const (*number, _) = pair\n    _ = number" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnevaluatedAddress, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkSequence: gives the unsuffixed bounds of a range the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize): _ = value\nfn main(): for index in 0..3: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const range = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"for".sequence.range;
    const usize_type: types.Type = .{ .number = .usize };
    try std.testing.expectEqual(usize_type, range.start.type.?);
    try std.testing.expectEqual(usize_type, range.end.?.type.?);
}

test "checkSequence: rejects a bound that is not a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize): _ = value\nfn show(count: u32): for index in 0..count: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkSequence: rejects a range that starts after its end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: usize): _ = value\nfn main(): for index in 5..2: take(index)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.ReversedRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkSequence: rejects a value that is not a sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main(): for item in 5i32: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotSequence, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkSequence: rejects a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn show(items: *many i32): for item in items: take(item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotSequence, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 40 }, type_checker.failure.?.location.?);
}

test "checkInitialValue: gives a struct literal the written type of a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data:\n    var data: Data = {value = 1}\n    data.value = 2\n    return data" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expectEqualStrings("Data", body[0].kind.variable_declaration.value.type.?.@"struct".name);
}

test "checkInitialValue: gives undefined the written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count: i32 = undefined\n    count = 5\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, body[0].kind.variable_declaration.value.type);
}

test "checkInitialValue: rejects undefined without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    var count = undefined\n    count = 5i32\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkInitialValue: rejects undefined for an array whose length is taken from the value" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a boolean for an integer type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: return true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an integer literal for a float type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn ratio() -> f64: return 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float literal for an integer type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: return 2.5" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a suffix of another type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: return 5u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float suffix of another type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn ratio() -> f64: return 2.5f32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts the maximum of each integer type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{
        .sub_path = "main.mn",
        .data =
        \\fn one() -> i8: return 127
        \\fn two() -> i16: return 32767
        \\fn three() -> i32: return 2147483647
        \\fn four() -> i64: return 9223372036854775807
        \\fn five() -> u8: return 255
        \\fn six() -> u16: return 65535
        \\fn seven() -> u32: return 4294967295
        \\fn eight() -> u64: return 18446744073709551615
        \\fn nine() -> usize: return 18446744073709551615
        \\fn ten() -> i128: return 170141183460469231731687303715884105727
        \\fn eleven() -> isize: return 9223372036854775807
        \\fn twelve() -> u128: return 340282366920938463463374607431768211455
        ,
    });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try type_checker.check();
}

test "checkExpression: rejects one past the maximum of each integer type" {
    const sources = [_][]const u8{
        "fn value() -> i8: return 128",
        "fn value() -> i16: return 32768",
        "fn value() -> i32: return 2147483648",
        "fn value() -> i64: return 9223372036854775808",
        "fn value() -> u8: return 256",
        "fn value() -> u16: return 65536",
        "fn value() -> u32: return 4294967296",
        "fn value() -> u64: return 18446744073709551616",
        "fn value() -> usize: return 18446744073709551616",
        "fn value() -> i128: return 170141183460469231731687303715884105728",
        "fn value() -> isize: return 9223372036854775808",
        "fn value() -> u128: return 340282366920938463463374607431768211456",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var program_directory = std.testing.tmpDir(.{});
        defer program_directory.cleanup();
        const program_path = try std.fs.path.join(
            arena.allocator(),
            &.{ ".zig-cache", "tmp", &program_directory.sub_path },
        );
        var loader = @import("loader.zig").Loader.init(program_path, program_path);
        try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = source });
        try loader.loadMainModule(&arena, std.testing.io, "main");
        var type_registry: types.Registry = .{};
        var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
        try name_resolver.resolve();
        var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

        try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    }
}

test "checkExpression: accepts the minimum of each signed integer type" {
    const sources = [_][]const u8{
        "fn value() -> i8: return -128",
        "fn value() -> i16: return -32768",
        "fn value() -> i32: return -2147483648",
        "fn value() -> i64: return -9223372036854775808",
        "fn value() -> i128: return -170141183460469231731687303715884105728",
        "fn value() -> isize: return -9223372036854775808",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var program_directory = std.testing.tmpDir(.{});
        defer program_directory.cleanup();
        const program_path = try std.fs.path.join(
            arena.allocator(),
            &.{ ".zig-cache", "tmp", &program_directory.sub_path },
        );
        var loader = @import("loader.zig").Loader.init(program_path, program_path);
        try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = source });
        try loader.loadMainModule(&arena, std.testing.io, "main");
        var type_registry: types.Registry = .{};
        var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
        try name_resolver.resolve();
        var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

        try type_checker.check();
    }
}

test "checkExpression: rejects one below the minimum of each signed integer type" {
    const sources = [_][]const u8{
        "fn value() -> i8: return -129",
        "fn value() -> i16: return -32769",
        "fn value() -> i32: return -2147483649",
        "fn value() -> i64: return -9223372036854775809",
        "fn value() -> i128: return -170141183460469231731687303715884105729",
        "fn value() -> isize: return -9223372036854775809",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var program_directory = std.testing.tmpDir(.{});
        defer program_directory.cleanup();
        const program_path = try std.fs.path.join(
            arena.allocator(),
            &.{ ".zig-cache", "tmp", &program_directory.sub_path },
        );
        var loader = @import("loader.zig").Loader.init(program_path, program_path);
        try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = source });
        try loader.loadMainModule(&arena, std.testing.io, "main");
        var type_registry: types.Registry = .{};
        var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
        try name_resolver.resolve();
        var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

        try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    }
}

test "checkExpression: rejects a negative number for each unsigned type" {
    const sources = [_][]const u8{
        "fn value() -> u8: return -1",
        "fn value() -> u16: return -1",
        "fn value() -> u32: return -1",
        "fn value() -> u64: return -1",
        "fn value() -> u128: return -1",
        "fn value() -> usize: return -1",
        "fn value() -> u8: return -0",
        "fn value() -> u8: return -999999999999999999999999999999999999999999",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var program_directory = std.testing.tmpDir(.{});
        defer program_directory.cleanup();
        const program_path = try std.fs.path.join(
            arena.allocator(),
            &.{ ".zig-cache", "tmp", &program_directory.sub_path },
        );
        var loader = @import("loader.zig").Loader.init(program_path, program_path);
        try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = source });
        try loader.loadMainModule(&arena, std.testing.io, "main");
        var type_registry: types.Registry = .{};
        var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
        try name_resolver.resolve();
        var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

        try std.testing.expectError(error.NegativeUnsigned, type_checker.check());
    }
}

test "checkExpression: rejects a suffixed literal out of range" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small() -> u8: return 300u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float out of range" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn huge() -> f32: return 1e39" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a negative float out of range" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn huge() -> f32: return -1e39" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a float out of range for f16" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn huge() -> f16: return 65520.0" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts a float beyond f64 for f128" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn huge() -> f128: return 1e309" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try type_checker.check();
}

test "checkExpression: rejects a type as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return i32\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
    try std.testing.expectEqualStrings("value does not match the expected type", type_checker.failure.?.message);
}

test "checkExpression: rejects a parameter of another type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: i32) -> u8: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 35 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a call of another type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u8: return 1\nfn two() -> i32: return one()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a void call as a value" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn two() -> i32: return log()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts a string literal as a constant byte slice" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() -> []const u8: return \"hello\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const text_type: types.Type = .{ .slice = try type_registry.addSlice(arena.allocator(), .{ .number = .u8 }, true) };
    try std.testing.expectEqual(text_type, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
}

test "checkExpression: rejects a string for an integer type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn answer() -> i32: return \"42\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an integer for a constant byte slice" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn name() -> []const u8: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a string literal for a mutable byte slice" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn name() -> []u8: return \"hi\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkExpression: gives a character literal the expected integer type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn letter() -> u8: return 'a'" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .u8 }, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
}

test "checkExpression: rejects a character literal for a boolean" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn code() -> bool: return 'a'" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects undefined as a returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32: return undefined" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedUndefined, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects undefined as the value of a local constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show() -> i32:\n    const count: i32 = undefined\n    return count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedUndefined, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkExpression: gives a struct literal the expected type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return {x = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Point", value.type.?.@"struct".name);
}

test "checkExpression: rejects a struct literal for a type that is not a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return {value = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedBraces, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: checks the fields of a struct literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data: return {value = true}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 36 }, type_checker.failure.?.location.?);
}

test "checkExpression: gives an array literal the expected type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return {1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.type.?.array.length);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.composite_literal.elements[1].value.type);
}

test "checkExpression: rejects an array literal of another length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects braces for a type that is neither an array nor a tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedBraces, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkExpression: checks the elements of an array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return {1, true}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkExpression: gives braces in an argument the type of the parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: [2]u8): _ = values\nfn main(): take({\n    1,\n    2,\n})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const argument = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, argument.type.?.array.element);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, argument.kind.composite_literal.elements[1].value.type.?);
}

test "checkExpression: converts a mutable slice to a constant slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []const u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    const bytes = buffer[..]\n    take(bytes)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "checkExpression: keeps a constant of a mutable slice type mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    const view: []u8 = buffer[..]\n    fill(view)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[2].kind.call.kind.call;
    try std.testing.expect(!call.arguments[0].value.type.?.slice.constant);
}

test "checkExpression: keeps a constant of a mutable pointer type mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(value: *i32): _ = value\nfn pass(value: *i32):\n    const pointer: *i32 = value\n    fill(pointer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[1].kind.call.kind.call;
    try std.testing.expect(!call.arguments[0].value.type.?.pointer.constant);
}

test "checkExpression: rejects a read-only slice constant where a mutable slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    const view: []const u8 = buffer[..]\n    fill(view)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a constant slice where a mutable slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    const values = [2]u8{1, 2}\n    take(values[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, type_checker.failure.?.location.?);
}

test "checkExpression: converts a pointer to a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: *const i32): _ = value\nfn give(value: *i32): take(value)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "checkExpression: rejects a read-only pointer where a mutable pointer is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: *i32): _ = value\nfn give(value: *const i32): take(value)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 34 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a pointer to a single value where multiple values are expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(values: *many const i32): _ = values\nfn give(value: *i32): take(value)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkExpression: converts a pointer to an array to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(&buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkExpression: keeps the own type of a value converted to a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    fill(&buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const argument = body[1].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, argument.type.?.pointer.target.array.element);
}

test "checkExpression: converts a pointer to an array to a read-only slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(bytes: []const u8): _ = bytes\nfn main():\n    var buffer: [4]u8 = undefined\n    show(&buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkExpression: converts a read-only pointer to an array to a read-only slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(bytes: []const u8): _ = bytes\nfn pass(buffer: *const [4]u8): show(buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkExpression: rejects a read-only pointer to an array where a mutable slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn pass(buffer: *const [4]u8): fill(buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 37 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a pointer to an array of other elements where a slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn pass(buffer: *[4]i8): fill(buffer)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects a multiple value pointer to an array where a slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(bytes: []u8): _ = bytes\nfn pass(buffers: *many [4]u8): fill(buffers)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 37 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an array of pointers to arrays where an array of slices is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(all: [1][]u8): _ = all\nfn pass(buffer: *[4]u8): fill([1]*[4]u8{buffer})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an optional pointer to an array where an optional slice is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn fill(maybe: ?[]u8): _ = maybe\nfn pass(maybe: ?*[4]u8): fill(maybe)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts null for an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?*i32: return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.number, std.meta.activeTag(value.type.?.optional.child.pointer.target));
}

test "checkExpression: rejects null for a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> *i32: return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 30 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects null for a value that is not optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main(): take(null)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkExpression: keeps an optional of an optional apart from the optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn wrap(value: ?i32) -> ??i32: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 39 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts null for an optional of an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const value: ??i32 = null\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.type.?.optional.child.optional.child);
}

test "checkExpression: accepts a pointer to a function for a parameter of its type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn double(value: i32) -> i32: return value\nfn apply(callback: *fn(i32) -> i32): _ = callback\nfn main(): apply(&double)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const argument = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.call.kind.call.arguments[0].value;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, argument.type.?.pointer.target.function.return_type);
}

test "checkExpression: rejects a pointer to a function of another signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate(value: bool) -> bool: return value\nfn apply(callback: *fn(i32) -> i32): _ = callback\nfn main(): apply(&negate)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkExpression: accepts null for an optional pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> ?*fn(i32) -> i32: return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expect(value.type.?.optional.child.pointer.target == .function);
}

test "checkExpression: rejects null for a pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn nothing() -> *fn(i32) -> i32: return null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 41 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an operation of another type than expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn widen(left: i32, right: i32) -> i64: return left + right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects calling main" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn helper(): main()\nfn main(): helper()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MainCalled, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, type_checker.failure.?.location.?);
}

test "checkCall: checks arguments of external functions" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn take(value: u8)\nfn main(): take(300)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkCall: checks arguments against a function of another module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    var compiler_directory = std.testing.tmpDir(.{});
    defer compiler_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "utils.mn", .data = "fn take(value: i32): _ = value" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    const compiler_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &compiler_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, compiler_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import utils\nfn main(): utils::take(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[0].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects a wrong number of arguments" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) -> i32:\n    _ = right\n    return left\nfn main(): _ = add(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.ArgumentCountMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkCall: rejects an argument of another type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn flag(value: bool): _ = value\nfn main(): flag(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkCall: checks literal arguments against their parameter" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn small(value: u8): _ = value\nfn main(): small(300)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: calls a method with its receiver as the first argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    points: i32\n    fn get(self: Self) -> i32: return self.points\nfn show(card: Card) -> i32: return card.get()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[2].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 1 } }, call.callee.identifier.resolution.?);
    try std.testing.expectEqualStrings("card", call.arguments[0].value.kind.identifier.name);
}

test "resolveMethodCall: checks the arguments after the receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn add(self: Self, count: i32) -> i32:\n        _ = self\n        return count\nfn show(card: Card) -> i32: return card.add(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 45 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: rejects an unknown method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card\nfn show(card: Card): card.missing()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 27 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: rejects a function without a Self parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card{}\nfn show(card: Card) -> Card: return card.new()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoSelf, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 42 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: rejects a function whose first parameter names the struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn show(card: Card) -> Card: return card\nfn take(card: Card) -> Card: return card.show()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoSelf, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 42 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: calls a function of a trait of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.@"return".?.kind.call.callee.identifier;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, callee.resolution.?);
}

test "resolveMethodCall: rejects a function of a trait that is not imported" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nstruct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 47 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: calls a function of an imported trait" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "resolveMethodCall: calls a function of a trait imported under another name" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape as Form\nstruct Square:\n    side: i32\nimpl Form for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "resolveMethodCall: calls the function of the struct's block over a trait's function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\n    fn area(self: Self) -> i32: return self.side\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side * self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 2 } }, ast.extractResolution(call.callee));
}

test "resolveMethodCall: rejects a method that two traits give a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\ntrait Figure:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nimpl Figure for Square:\n    fn area(self: Self) -> i32: return self.side * 2\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.AmbiguousMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 11, .column = 47 }, type_checker.failure.?.location.?);
}

test "resolveMethodCall: calls a function of the trait through self in a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const definition = loader.modules.items[0].declarations[0].kind.trait_definition;
    const product = definition.defaults[1].?.body[0].kind.@"return".?.kind.binary;
    const callee = product.left.kind.call.callee.identifier;
    const function: ast.Resolution.TraitFunction = .{ .trait = .{ .module = 0, .declaration = 0 }, .function = 0 };
    try std.testing.expectEqual(ast.Resolution{ .trait_function = function }, callee.resolution.?);
}

test "resolveMethodCall: calls the function of the implementation through self in a default made for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const default = loader.modules.items[0].declarations[4].kind.function_definition;
    const product = default.body[0].kind.@"return".?.kind.binary;
    const callee = product.left.kind.call.callee.identifier;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, callee.resolution.?);
}

test "resolveMethodCall: calls a default on a value of an implementing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.double()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const callee = body[0].kind.@"return".?.kind.call.callee.identifier;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 5 } }, callee.resolution.?);
}

test "resolveMethodCall: calls the function of the implementation instead of the default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn double(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.double()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const callee = body[0].kind.@"return".?.kind.call.callee.identifier;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 4 } }, callee.resolution.?);
}

test "resolveTraitCall: calls the function of the implementation through the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}\nfn show(square: Square) -> i32: return Shape::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, ast.extractResolution(call.callee));
}

test "resolveTraitCall: chooses the trait's function over the function of the struct's block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\n    fn area(self: Self) -> i32: return self.side\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side * self.side\nfn show(square: Square) -> i32: return Shape::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[5].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 4 } }, ast.extractResolution(call.callee));
}

test "resolveTraitCall: chooses the function of the trait it is called through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\ntrait Figure:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nimpl Figure for Square:\n    fn area(self: Self) -> i32: return self.side * 2\nfn shape(square: Square) -> i32: return Shape::area(square)\nfn figure(square: Square) -> i32: return Figure::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const declarations = loader.modules.items[0].declarations;
    const shape = declarations[7].kind.function_definition.body[0].kind.@"return".?.kind.call;
    const figure = declarations[8].kind.function_definition.body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 4 } }, ast.extractResolution(shape.callee));
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 6 } }, ast.extractResolution(figure.callee));
}

test "resolveTraitCall: calls a default implementation through the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return Shape::double(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 5 } }, ast.extractResolution(call.callee));
}

test "resolveTraitCall: calls a function of an imported trait through the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return Shape::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[4].kind.function_definition.body;
    const call = body[0].kind.@"return".?.kind.call;
    try std.testing.expectEqual(ast.Resolution{ .function = .{ .module = 0, .declaration = 3 } }, ast.extractResolution(call.callee));
}

test "resolveTraitCall: rejects a trait that is neither declared nor imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nstruct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return shapes::Shape::area(square)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 6, .column = 40 }, type_checker.failure.?.location.?);
}

test "resolveTraitCall: rejects a function without a Self parameter through the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}\nfn make() -> Square: return Shape::unit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoSelf, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 29 }, type_checker.failure.?.location.?);
}

test "findTraitMethod: rejects a value whose type does not implement the trait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn unit() -> Self\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\n    fn unit() -> Self: return Square{side = 1}\nstruct Circle:\n    radius: i32\nfn show(circle: Circle) -> i32: return Shape::area(circle)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotImplemented, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 11, .column = 52 }, type_checker.failure.?.location.?);
}

test "findTraitMethod: calls the trait's function on Self through the trait in a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: Self) -> i32: return Shape::area(self) * 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const definition = loader.modules.items[0].declarations[0].kind.trait_definition;
    const product = definition.defaults[1].?.body[0].kind.@"return".?.kind.binary;
    const function: ast.Resolution.TraitFunction = .{ .trait = .{ .module = 0, .declaration = 0 }, .function = 0 };
    try std.testing.expectEqual(ast.Resolution{ .trait_function = function }, ast.extractResolution(product.left.kind.call.callee));
}

test "findSelfFunction: rejects a function of the implementing type through self in a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn double(self: Self) -> i32: return self.size()\nstruct Square:\n    side: i32\n    fn size(self: Self) -> i32: return self.side\nimpl Shape for Square" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkFunctionCall: gives a struct literal the type of its parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn draw(data: Data) -> i32: return data.value\nfn main(): _ = draw({value = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const call = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.discard.kind.call;
    try std.testing.expectEqualStrings("Data", call.arguments[0].value.type.?.@"struct".name);
}

test "checkFunctionCall: rejects a named argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(value: i32): _ = value\nfn main(): add(value = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NamedArgument, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "checkFunctionCall: rejects a call that leaves out an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn draw(width: i32, height: i32):\n    _ = width\n    _ = height\nfn main(): draw(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.ArgumentCountMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkValueCall: gives a struct literal the type of its parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn apply(callback: *fn(Data) -> i32) -> i32: return callback({value = 1})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Data", returned.kind.call.arguments[0].value.type.?.@"struct".name);
}

test "checkValueCall: checks the arguments of a call of a parameter against its function type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(i32) -> bool) -> bool: return callback(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.call.arguments[0].value.type.?);
}

test "checkValueCall: calls a local variable that points to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(value: i32): _ = value\nfn second(value: i32): _ = value\nfn main():\n    var step: *fn(i32) = &first\n    step = &second\n    step(2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[2].kind.function_definition.body[2].kind.call.kind.call;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.arguments[0].value.type.?);
}

test "checkValueCall: calls a name of a for loop that points to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(callbacks: [2]*fn() -> i32): for callback in callbacks: _ = callback()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"for".body[0].kind.discard;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.type.?);
}

test "checkValueCall: calls a constant of another module" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.discard;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, call.type.?);
}

test "checkValueCall: rejects calling a top-level constant that is not a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit = 5i32\nfn main(): limit()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotCallable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 12 }, type_checker.failure.?.location.?);
}

test "checkValueCall: rejects an argument of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(i32)): callback(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 40 }, type_checker.failure.?.location.?);
}

test "checkValueCall: rejects a wrong number of arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: *fn(i32)): callback(1, 2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.ArgumentCountMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 31 }, type_checker.failure.?.location.?);
}

test "checkValueCall: rejects calling a value that is not a function" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotCallable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 5 }, type_checker.failure.?.location.?);
}

test "checkValueCall: rejects calling an optional pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn apply(callback: ?*fn()): callback()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotCallable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: gives each access the type of its field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn read(line: Line) -> i32: return line.start.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, returned.type.?);
    try std.testing.expectEqualStrings("Point", returned.kind.field_access.value.type.?.@"struct".name);
    try std.testing.expectEqualStrings("Line", returned.kind.field_access.value.kind.field_access.value.type.?.@"struct".name);
}

test "checkFieldAccess: rejects a field the struct does not have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn read(point: Point) -> i32: return point.y" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnknownField, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 44 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: rejects fields of a value that is not a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: i32) -> i32: return value.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NoFields, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 42 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: rejects a field of another type than expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn read(point: Point) -> bool: return point.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 39 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: rejects a field of a field that is not a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: Point) -> i32: return point.x.y" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NoFields, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 46 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: reads a field through a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: *const Point):\n    const x = point.x\n    _ = x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type);
}

test "checkFieldAccess: rejects a field through a pointer to a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(point: **Point) -> i32: return point.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoFields, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 46 }, type_checker.failure.?.location.?);
}

test "checkFieldAccess: reads a field through a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn read(points: *many Point) -> i32:\n    const x = points.x\n    return x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type);
}

test "checkFieldAccess: rejects a field of Self in a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32: return self.side\nstruct Square:\n    side: i32\nimpl Shape for Square" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NoFields, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 45 }, type_checker.failure.?.location.?);
}

test "inferType: gives a call its return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nexternal fn make() -> Line\nfn read() -> i32: return make().start.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[3].kind.function_definition.body[0].kind.@"return".?;
    const call = returned.kind.field_access.value.kind.field_access.value;
    try std.testing.expectEqualStrings("Line", call.type.?.@"struct".name);
}

test "inferType: gives a negation the type of its suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i8: return low\nconst low = -128i8\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type{ .number = .i8 }, loader.modules.items[0].declarations[1].kind.constant_declaration.value.type);
}

test "inferType: checks the range of a negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i8: return low\nconst low = -129i8\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, type_checker.failure.?.location.?);
}

test "inferType: reports a missing suffix of a negation at the minus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i8: return low\nconst low = -5\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, type_checker.failure.?.location.?);
}

test "inferType: rejects a literal without a known type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read() -> i32: return 5.x" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "inferType: rejects a struct literal without an expected type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    const point = {x = 1}\n    _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferType: rejects null without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const value = null\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferType: takes the type written before an array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [2]i32{1, 2}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(2, value.type.?.array.length);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.type.?.array.element);
}

test "inferType: takes the type written before a tuple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const pair = [i32, bool]{1, true}\n    _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type.boolean, value.type.?.tuple.elements[1]);
}

test "inferType: takes a one-element tuple type written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const single = [i32]{1}\n    _ = single" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(1, value.type.?.tuple.elements.len);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.type.?.tuple.elements[0]);
}

test "inferType: takes the empty tuple type written before empty braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const empty = []{}\n    _ = empty" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(0, value.type.?.tuple.elements.len);
}

test "inferType: rejects braces without a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = {1i32, 2i32}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, type_checker.failure.?.location.?);
}

test "inferType: gives an operation the type of its operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i32) -> i32:\n    const sum = left + right\n    return sum" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const sum = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, sum.value.type.?);
}

test "inferType: rejects an operation of two literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const sum = 1 + 2\n    _ = sum" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkBinary: checks both operands of and as bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn both(left: bool, right: i32) -> bool: return left and right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 58 }, type_checker.failure.?.location.?);
}

test "checkBinary: gives a comparison the type bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn less(left: i32, right: i32) -> bool: return left < right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.binary.left.type.?);
}

test "checkBinary: rejects a comparison where a number is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: i32, right: i32) -> i32: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkBinary: gives a shift the type of its left operand and a literal amount the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn shift(value: u8) -> u8: return value << 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, value.type.?);
    try std.testing.expectEqual(types.Type{ .number = .usize }, value.kind.binary.right.type.?);
}

test "checkBinary: takes the type of a shifted literal from the surrounding code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask(amount: usize) -> u32:\n    const bits: u32 = 1 << amount\n    return bits" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const bits = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expectEqual(types.Type{ .number = .u32 }, bits.value.kind.binary.left.type.?);
}

test "checkBinary: rejects a shift amount that is not a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn shift(value: u32, amount: u32) -> u32: return value << amount" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 59 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects a shift of a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn shift(value: f32, amount: usize) -> f32: return value >> amount" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotInteger, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 58 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects a remainder of floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn rest(left: f64, right: f64) -> f64: return left % right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotInteger, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 52 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects a bitwise and of floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask(left: f32, right: f32) -> f32: return left & right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotInteger, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 52 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects an addition of booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: bool, right: bool) -> bool: return left + right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotNumeric, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 54 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects ordering booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn less(left: bool, right: bool) -> bool: return left < right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOrdered, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 55 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects ordering pointers to single values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn less(left: *i32, right: *i32) -> bool: return left < right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOrdered, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 55 }, type_checker.failure.?.location.?);
}

test "checkBinary: orders pointers to multiple values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn less(left: *many i32, right: *many i32) -> bool: return left < right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expect(value.kind.binary.left.type.?.pointer.many);
}

test "checkBinary: compares arrays of numbers for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: [2]i32, right: [2]i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expectEqual(2, value.kind.binary.left.type.?.array.length);
}

test "checkBinary: rejects comparing slices for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: []i32, right: []i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotEquatable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 57 }, type_checker.failure.?.location.?);
}

test "checkBinary: compares optionals of numbers for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?i32, right: ?i32) -> bool: return left != right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkBinary: compares optionals of optionals for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ??i32, right: ??i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkBinary: compares optional pointers for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?*i32, right: ?*i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkBinary: compares optional arrays for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?[2]i32, right: ?[2]i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkBinary: compares arrays of optionals for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: [2]?i32, right: [2]?i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkBinary: compares pointers to functions for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn two(): noop\nfn same() -> bool: return &one == &two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expect(value.kind.binary.left.type.?.pointer.target == .function);
}

test "checkBinary: compares optional pointers to functions for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: ?*fn(i32) -> i32, right: ?*fn(i32) -> i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expect(value.kind.binary.left.type.?.optional.child.pointer.target == .function);
}

test "checkBinary: rejects comparing optionals of structs for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn same(left: ?Data, right: ?Data) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotEquatable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 57 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects comparing a slice with a pointer to an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(bytes: []u8, buffer: *[4]u8) -> bool: return bytes == buffer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MismatchedOperands, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 60 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects ordering optionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn before(left: ?i32, right: ?i32) -> bool: return left < right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOrdered, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 57 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects comparing an optional with an unsuffixed literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(maybe: ?i32) -> bool: return maybe == 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects comparing arrays of slices for equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: [2][]i32, right: [2][]i32) -> bool: return left == right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotEquatable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 63 }, type_checker.failure.?.location.?);
}

test "checkBinary: rejects ordering an optional and null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check(maybe: ?i32) -> bool: return maybe < null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOrdered, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 45 }, type_checker.failure.?.location.?);
}

test "checkOrElse: gives the child type when the fallback fits the child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?i32, fallback: i32):\n    const value = maybe orelse fallback\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqualDeep(types.Type{ .number = .i32 }, value_type);
}

test "checkOrElse: gives an unsuffixed literal fallback the child type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?i32):\n    const value = maybe orelse 1\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const fallback = body[0].kind.constant_declaration.value.kind.binary.right;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, fallback.type.?);
}

test "checkOrElse: gives a struct literal fallback the child type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make(data: ?Data) -> Data: return data orelse {value = 0}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Data", returned.kind.binary.right.type.?.@"struct".name);
}

test "checkOrElse: gives the optional type when the fallback is an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?i32, other: ?i32):\n    const value = maybe orelse other\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.optional.child);
}

test "checkOrElse: checks the fallback against the child before the optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ??i32, other: ?i32):\n    const value = maybe orelse other\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.optional.child);
}

test "checkOrElse: gives a null fallback the child type when the child is an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ??i32):\n    const value = maybe orelse null\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.optional.child);
}

test "checkOrElse: gives a null fallback the optional type when the child is not an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?i32):\n    const value = maybe orelse null\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.optional.child);
}

test "checkOrElse: converts a mutable pointer fallback to the read-only child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?*const i32, pointer: *i32):\n    const value = maybe orelse pointer\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.constant);
}

test "checkOrElse: rejects a fallback that fits neither the child nor the optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(maybe: ?i32, flag: bool) -> i32: return maybe orelse flag" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 62 }, type_checker.failure.?.location.?);
}

test "checkOrElse: rejects a value that is not an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(count: i32) -> i32: return count orelse 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOptional, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 36 }, type_checker.failure.?.location.?);
}

test "checkNullComparison: compares an optional with null on either side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check(maybe: ?i32) -> bool: return maybe == null and null != maybe" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    const right = value.kind.binary.right.kind.binary;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, right.left.type.?.optional.child);
    try std.testing.expectEqual(types.Type.boolean, value.kind.binary.left.type.?);
}

test "checkNullComparison: rejects comparing null with null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check() -> bool: return null == null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkNullComparison: rejects comparing a value that is not an optional with null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn check(count: i32) -> bool: return count != null" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnexpectedNull, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkAdditive: gives a multiple value pointer moved by a literal its own type and the literal the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32):\n    const moved = items + 1\n    _ = moved" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.many);
    const offset = body[0].kind.constant_declaration.value.kind.binary.right;
    try std.testing.expectEqual(types.Type{ .number = .usize }, offset.type.?);
}

test "checkAdditive: gives a usize plus a multiple value pointer the type of the pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32, count: usize):\n    const moved = count + items\n    _ = moved" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.many);
}

test "checkAdditive: gives a literal plus a multiple value pointer the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32):\n    const moved = 1 + items\n    _ = moved" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const offset = body[0].kind.constant_declaration.value.kind.binary.left;
    try std.testing.expectEqual(types.Type{ .number = .usize }, offset.type.?);
}

test "checkAdditive: rejects subtracting a pointer from a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32) -> *many i32: return 1 - items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkOffsetPlusPointer: rejects an offset of another integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32, count: u32) -> *many i32: return count + items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 60 }, type_checker.failure.?.location.?);
}

test "checkOffsetPlusPointer: rejects a single value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(item: *i32, count: usize) -> *i32: return count + item" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.SinglePointerArithmetic, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 57 }, type_checker.failure.?.location.?);
}

test "checkPointerArithmetic: moves a multiple value pointer back by a usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn previous(items: *many i32, count: usize):\n    const moved = items - count\n    _ = moved" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.many);
}

test "checkPointerArithmetic: rejects moving a multiple value pointer by a signed integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(items: *many i32, count: i32) -> *many i32: return items + count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 68 }, type_checker.failure.?.location.?);
}

test "checkPointerArithmetic: rejects moving a multiple value pointer back by another unsigned integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn previous(items: *many i32, count: u32) -> *many i32: return items - count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 72 }, type_checker.failure.?.location.?);
}

test "checkPointerArithmetic: rejects arithmetic on a single value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(item: *i32) -> *i32: return item + 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.SinglePointerArithmetic, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 42 }, type_checker.failure.?.location.?);
}

test "checkPointerArithmetic: gives the difference of two multiple value pointers the type isize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn distance(end: *many i32, start: *many i32):\n    const count = end - start\n    _ = count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .isize }, value_type);
}

test "checkPointerArithmetic: subtracts a read-only pointer from a mutable pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn distance(end: *many i32, start: *many const i32) -> isize: return end - start" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    try std.testing.expectEqual(null, type_checker.failure);
}

test "checkPointerArithmetic: rejects the difference of pointers to different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn distance(end: *many i32, start: *many u8) -> isize: return end - start" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MismatchedOperands, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 67 }, type_checker.failure.?.location.?);
}

test "expectArithmeticPointer: rejects moving a pointer to zero-sized values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn next(markers: *many Marker) -> *many Marker: return markers + 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.ZeroSizedPointerArithmetic, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 64 }, type_checker.failure.?.location.?);
}

test "expectArithmeticPointer: rejects a usize plus a pointer to zero-sized values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn next(markers: *many Marker, count: usize) -> *many Marker: return count + markers" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.ZeroSizedPointerArithmetic, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 76 }, type_checker.failure.?.location.?);
}

test "expectArithmeticPointer: rejects the difference of pointers to zero-sized values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn count(one: *many Marker, two: *many Marker) -> isize: return one - two" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.ZeroSizedPointerArithmetic, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 69 }, type_checker.failure.?.location.?);
}

test "checkOperands: gives a literal the type of the other operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(count: u8) -> u8: return count + 1\nfn previous(count: u8) -> u8: return 1 - count" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, value.kind.binary.right.type.?);
    const other = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, other.kind.binary.left.type.?);
}

test "checkOperands: gives two literals the type of the surrounding code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn total() -> u8:\n    const sum: u8 = 1 + 2\n    return sum" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const sum = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, sum.value.kind.binary.left.type.?);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, sum.value.kind.binary.right.type.?);
}

test "checkOperands: rejects a comparison of two literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn less() -> bool: return 1 < 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkOperands: rejects operands of different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn add(left: i32, right: i64) -> i32: return left + right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MismatchedOperands, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 51 }, type_checker.failure.?.location.?);
}

test "checkOperands: rejects a literal out of the range of the other operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(count: u8) -> u8: return count + 256" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 42 }, type_checker.failure.?.location.?);
}

test "checkOperands: compares a pointer with a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(left: *i32, right: *const i32) -> bool: return left == right\nfn other(left: *const i32, right: *i32) -> bool: return left != right" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type.boolean, value.type.?);
    try std.testing.expect(value.kind.binary.right.type.?.pointer.constant);
}

test "checkOperand: rejects a shifted literal without a type from the surrounding code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn mask(amount: usize):\n    const bits = 1 << amount\n    _ = bits" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 18 }, type_checker.failure.?.location.?);
}

test "checkUnary: rejects negating an unsigned integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate(value: u32) -> u32: return -value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NegatedUnsigned, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkUnary: rejects negating a bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate() -> bool: return -true" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotNumeric, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkUnary: rejects ! on an integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn invert(value: i32) -> bool: return !value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 40 }, type_checker.failure.?.location.?);
}

test "checkUnary: rejects ~ on a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn invert(value: f32) -> f32: return ~value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotInteger, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkUnary: gives a negated literal the type of the surrounding code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn negate() -> i8: return -(5)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .i8 }, value.kind.unary.operand.type.?);
}

test "checkAddressOf: gives the address of a variable a mutable pointer" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[1].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.pointer.target);
}

test "checkAddressOf: gives the address of a local constant a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const value = 1i32\n    const pointer = &value\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[1].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: gives the address of a parameter a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: i32):\n    const pointer = &value\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: gives the address of a name of a for loop a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(pointer: *const i32): _ = pointer\nfn show(items: []const i32): for item in items: take(&item)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"for".body[0].kind.call;
    const value_type = call.kind.call.arguments[0].value.type.?;
    try std.testing.expect(value_type.pointer.constant);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.pointer.target);
}

test "checkAddressOf: gives the address of a field of a variable a mutable pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    var point = Point{x = 1}\n    const pointer = &point.x\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const value_type = body[1].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: gives the address of an element of a mutable slice parameter a mutable pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: []i32):\n    const pointer = &values[0]\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: gives the address of an element of a read-only slice a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: []const i32):\n    const pointer = &values[0]\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: gives the address of the target of a read-only pointer a read-only pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(value: *const i32):\n    const pointer = &value.*\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.pointer.constant);
    try std.testing.expect(!value_type.pointer.many);
}

test "checkAddressOf: rejects the address of a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return 1\nfn main():\n    const pointer = &make()\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAddressable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 22 }, type_checker.failure.?.location.?);
}

test "checkAddressOf: gives a pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return 1\nfn main():\n    const pointer = &make\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.constant_declaration.value;
    const pointer = value.type.?.pointer;
    try std.testing.expect(!pointer.constant);
    try std.testing.expect(!pointer.many);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, pointer.target.function.return_type);
}

test "checkAddressOf: gives a pointer to a function through an alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return 1\nfn main():\n    const build = make\n    const pointer = &build\n    _ = pointer" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[1].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.type.?.pointer.target.function.return_type);
}

test "checkAddressOf: rejects the address of an unwrapped optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(maybe: ?i32) -> *const i32: return &maybe.?" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAddressable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 45 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: checks the elements against the written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [2]i32{1i32, 2u8}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 33 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: checks the elements against an alias written before the braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const Pair = [i32, bool]\nfn make() -> Pair: return Pair{1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 35 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: rejects a written length that the elements do not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [3]i32{1, 2}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: takes the length to infer from the elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [_]i32{1, 2, 3}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(3, value.type.?.array.length);
}

test "checkCompositeLiteral: accepts elements of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): return\nfn main():\n    const values = [2]void{show(), show()}\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type.void, value.type.?.array.element);
}

test "checkCompositeLiteral: accepts empty braces for an array of length zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [0]i32: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(0, value.type.?.array.length);
}

test "checkCompositeLiteral: rejects an array type written before the braces that is not expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return [2]u8{1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: checks each element of a tuple against its own type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: rejects a tuple literal with another number of elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongTupleLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: gives braces of one element the type of a one-element tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32]: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.composite_literal.elements[0].value.type.?);
    try std.testing.expectEqual(1, value.type.?.tuple.elements.len);
}

test "checkCompositeLiteral: gives empty braces the empty tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> []: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(0, value.type.?.tuple.elements.len);
}

test "checkCompositeLiteral: rejects empty braces where a one-element tuple is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32]: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongTupleLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: rejects an element where the empty tuple is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> []: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongTupleLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkCompositeLiteral: gives braces over several lines the type of the tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {\n    1,\n    true,\n}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.composite_literal.elements[0].value.type.?);
    try std.testing.expectEqual(types.Type.boolean, value.type.?.tuple.elements[1]);
}

test "checkCompositeLiteral: gives struct literals in an array literal the element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> [2]Data: return {{value = 1}, {value = 2}}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const second = returned.kind.composite_literal.elements[1].value;
    try std.testing.expectEqualStrings("Data", second.type.?.@"struct".name);
}

test "checkCompositeLiteral: gives a struct literal in a tuple literal its element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> [Data, i32]: return {{value = 1}, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const first = returned.kind.composite_literal.elements[0].value;
    try std.testing.expectEqualStrings("Data", first.type.?.@"struct".name);
}

test "checkConstruction: gives a construction its struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    one: i32\n    two: i32\nfn make() -> Data: return Data{two = 2, one = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Data", returned.type.?.@"struct".name);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, returned.kind.composite_literal.elements[0].value.type.?);
}

test "checkConstruction: rejects named values for an array type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [1]i32: return [1]i32{value = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NotAStruct, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects values without field names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    one: i32\n    two: i32\nfn make() -> Data: return Data{1, 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingFieldName, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 32 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects named values where a tuple is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [i32, bool]: return {one = 1, two = true}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NotAStruct, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 34 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects unnamed values where a struct is expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data: return {1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingFieldName, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects an unknown field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point{x = 1, z = 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.UnknownField, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 41 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects a field given twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point{x = 1, x = 2, y = 3}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.RepeatedField, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 41 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects a missing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point{x = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingField, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 28 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects a value of another type than its field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point{x = true, y = 2}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkConstruction: accepts leaving out fields with defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32 = 0\n    y: i32\nfn make() -> Point: return Point{y = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try type_checker.check();
}

test "checkConstruction: gives empty braces a struct whose fields all have defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    one: i32 = 0\n    two: i32 = 1\nfn make() -> Data: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Data", returned.type.?.@"struct".name);
}

test "checkConstruction: gives empty braces a struct without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn make() -> Marker: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Marker", returned.type.?.@"struct".name);
}

test "checkConstruction: rejects empty braces for a struct with a field without a default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nfn make() -> Data: return {}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingField, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 27 }, type_checker.failure.?.location.?);
}

test "checkConstruction: gives a struct literal in a field the type of the field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct DataOne:\n    value: i32\nstruct DataTwo:\n    value: DataOne\nfn make() -> DataTwo: return DataTwo{value = {value = 1}}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    const value = returned.kind.composite_literal.elements[0].value;
    try std.testing.expectEqualStrings("DataOne", value.type.?.@"struct".name);
}

test "checkIndex: gives an element of an array its element type and a literal index the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(values: [2]i32):\n    const element = values[0]\n    _ = element" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type);
    const index = body[0].kind.constant_declaration.value.kind.index.index;
    try std.testing.expectEqual(types.Type{ .number = .usize }, index.type.?);
}

test "checkIndex: gives an element of a slice its element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(values: []const u8):\n    const element = values[0]\n    _ = element" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .u8 }, value_type);
}

test "checkIndex: gives an element through a multiple value pointer its target type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(values: *many bool):\n    const element = values[3]\n    _ = element" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type.boolean, value_type);
}

test "checkIndex: gives an element of a tuple the type of that element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(pair: [i32, bool]):\n    const element = pair[1]\n    _ = element" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type.boolean, value_type);
}

test "checkIndex: indexes the array behind a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(values: *const [2]i64):\n    const element = values[1]\n    _ = element" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i64 }, value_type);
}

test "checkIndex: rejects indexing a single value pointer to a value that is not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(value: *i32) -> i32: return value[0]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotIndexable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, type_checker.failure.?.location.?);
}

test "checkIndex: rejects indexing a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(value: i32) -> i32: return value[0]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotIndexable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 37 }, type_checker.failure.?.location.?);
}

test "checkIndex: rejects an index of another integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(values: []const i32, position: u32) -> i32: return values[position]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 68 }, type_checker.failure.?.location.?);
}

test "checkArrayIndex: rejects any index into an array of length zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: [0]i32, position: usize) -> i32: return values[position]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.IndexOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 64 }, type_checker.failure.?.location.?);
}

test "checkArrayIndex: rejects a literal index outside the array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn last(values: [2]i32) -> i32: return values[2]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.IndexOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 47 }, type_checker.failure.?.location.?);
}

test "checkArrayIndex: rejects a literal index outside the array behind a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn last(values: *[2]i32) -> i32: return values[2]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.IndexOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkTupleIndex: rejects an index that is not an integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(pair: [i32, bool], position: usize) -> bool: return pair[position]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownTupleIndex, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 68 }, type_checker.failure.?.location.?);
}

test "checkTupleIndex: rejects an index outside the tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn third(pair: [i32, bool]) -> bool: return pair[2]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.IndexOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 50 }, type_checker.failure.?.location.?);
}

test "checkTupleIndex: rejects an index into the empty tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(empty: []) -> i32: return empty[0]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.IndexOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 42 }, type_checker.failure.?.location.?);
}

test "checkTupleIndex: rejects a suffixed index of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second(pair: [i32, bool]) -> bool: return pair[1u8]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 51 }, type_checker.failure.?.location.?);
}

test "inferSliceType: gives a slice of a variable a mutable slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    var buffer: [4]u8 = undefined\n    const bytes = buffer[..]\n    _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const slice = body[1].kind.constant_declaration.value.type.?.slice;
    try std.testing.expect(!slice.constant);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, slice.element);
}

test "inferSliceType: gives a slice of a constant a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [2]i32{1, 2}\n    const items = values[..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expect(body[1].kind.constant_declaration.value.type.?.slice.constant);
}

test "inferSliceType: gives a slice of a parameter a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(values: [2]i32):\n    const items = values[..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    try std.testing.expect(body[0].kind.constant_declaration.value.type.?.slice.constant);
}

test "inferSliceType: gives a slice of a field of a variable a mutable slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Deck:\n    cards: [2]i32\nfn main():\n    var deck: Deck = undefined\n    const cards = deck.cards[..]\n    _ = cards" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    try std.testing.expect(!body[1].kind.constant_declaration.value.type.?.slice.constant);
}

test "inferSliceType: gives a slice of an element of a constant array a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const grid = [2][2]i32{{1, 2}, {3, 4}}\n    const row = grid[1][..]\n    _ = row" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[1].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.slice.constant);
}

test "inferSliceType: keeps a slice of a mutable slice mutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []i32):\n    const items = values[1..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.slice.constant);
}

test "inferSliceType: keeps a slice of a read-only slice read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []const i32):\n    const items = values[..1]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.slice.constant);
}

test "inferSliceType: slices the array behind a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: *[4]i32):\n    const items = values[1..3]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.slice.constant);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type.slice.element);
}

test "inferSliceType: gives a slice of the array behind a read-only pointer a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: *const [4]i32):\n    const items = values[1..3]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.slice.constant);
}

test "inferSliceType: slices a multiple value pointer with an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(items: *many u8):\n    const bytes = items[0..4]\n    _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(!value_type.slice.constant);
    try std.testing.expectEqual(types.Type{ .number = .u8 }, value_type.slice.element);
}

test "inferSliceType: gives a slice of a read-only multiple value pointer a constant slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(items: *many const u8):\n    const bytes = items[..4]\n    _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expect(value_type.slice.constant);
}

test "inferSliceType: gives literal bounds the type usize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []const i32):\n    const items = values[1..2]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const slice = body[0].kind.constant_declaration.value.kind.slice;
    try std.testing.expectEqual(types.Type{ .number = .usize }, slice.start.?.type.?);
    try std.testing.expectEqual(types.Type{ .number = .usize }, slice.end.?.type.?);
}

test "inferSliceType: rejects a slice of a value that is not an array, a slice or a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(count: i32):\n    const items = count[..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotSliceable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferSliceType: rejects a slice of an array returned by a call" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.SlicedTemporary, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 20 }, type_checker.failure.?.location.?);
}

test "inferSliceType: rejects a slice of a multiple value pointer without an end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(items: *many u8):\n    const bytes = items[1..]\n    _ = bytes" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingEnd, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferSliceType: rejects a slice of a single value pointer to a value that is not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(value: *i32):\n    const items = value[..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotSliceable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferSliceType: rejects a bound of another integer type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn part(values: []const i32, start: u32):\n    const items = values[start..]\n    _ = items" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 26 }, type_checker.failure.?.location.?);
}

test "inferSliceType: rejects a slice of an array obtained through an unwrap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(maybe: ?[2]i32) -> []const i32: return maybe.?[..]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.SlicedTemporary, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkDereference: gives the target of a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: *const i32):\n    const copy = value.*\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value_type);
}

test "checkDereference: gives the first target of a multiple value pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(values: *many bool):\n    const copy = values.*\n    _ = copy" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqual(types.Type.boolean, value_type);
}

test "checkDereference: rejects dereferencing a value that is not a pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(value: i32) -> i32: return value.*" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAPointer, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 36 }, type_checker.failure.?.location.?);
}

test "checkDereference: rejects dereferencing a pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(callback: *fn() -> i32) -> i32: return callback.*" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.FunctionDereferenced, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 48 }, type_checker.failure.?.location.?);
}

test "checkUnwrap: gives the child type of the optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(maybe: ?i32):\n    const value = maybe.?\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value_type = body[0].kind.constant_declaration.value.type.?;
    try std.testing.expectEqualDeep(types.Type{ .number = .i32 }, value_type);
}

test "checkUnwrap: rejects unwrapping a value that is not an optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read(count: i32) -> i32: return count.?" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotOptional, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 36 }, type_checker.failure.?.location.?);
}

test "computeValueType: gives the name of a for loop the element type of its sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(flag: bool): _ = flag\nfn show(flags: *[2]bool): for flag in flags: take(flag)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const call = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"for".body[0].kind.call;
    try std.testing.expectEqual(types.Type.boolean, call.kind.call.arguments[0].value.type.?);
}

test "computeValueType: rejects a function passed as an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn double(value: i32) -> i32: return value\nfn apply(callback: *fn(i32) -> i32): _ = callback\nfn main(): apply(double)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.FunctionUsedAsValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 18 }, type_checker.failure.?.location.?);
}

test "computeValueType: rejects a function as the value of a constant with a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nconst step: *fn() = one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.FunctionUsedAsValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 21 }, type_checker.failure.?.location.?);
}

test "computeValueType: rejects an alias of a function used as a value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn get() -> *fn():\n    const step = one\n    return step" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.FunctionUsedAsValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, type_checker.failure.?.location.?);
}

test "computeValueType: rejects a function as an operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one(): noop\nfn same() -> bool: return one == one" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.FunctionUsedAsValue, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 27 }, type_checker.failure.?.location.?);
}

test "computeFunctionType: puts the receiver of a method first" {
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
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[2].kind.function_definition.body[0].kind.@"return".?;
    const function = value.type.?.pointer.target.function;
    try std.testing.expectEqualStrings("Point", function.parameters[0].@"struct".name);
    try std.testing.expectEqual(types.Type{ .number = .f32 }, function.return_type);
}

test "computeFunctionType: gives a function of a trait implementation the type of its signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn get() -> *fn(Square) -> i32: return &Square::area" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const declarations = loader.modules.items[0].declarations;
    const value = declarations[declarations.len - 1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Square", value.type.?.pointer.target.function.parameters[0].@"struct".name);
}

test "computeFunctionType: gives an external function the type of its signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn measure(text: []const u8) -> usize\nfn get() -> *fn([]const u8) -> usize: return &measure" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    const text_type: types.Type = .{ .slice = try type_registry.addSlice(arena.allocator(), .{ .number = .u8 }, true) };
    try std.testing.expectEqual(text_type, value.type.?.pointer.target.function.parameters[0]);
}

test "checkConstant: gives each use the type of the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u64: return limit\nfn two() -> u64: return limit\nconst limit = 7u64\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[1].kind.function_definition.body[0].kind.@"return".?.type);
    try std.testing.expectEqual(types.Type{ .number = .u64 }, declarations[2].kind.constant_declaration.value.type);
}

test "checkConstant: rejects a value of another type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return limit\nconst limit = true\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 25 }, type_checker.failure.?.location.?);
}

test "checkConstant: checks the value in the module of the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "limits.mn", .data = "const maximum = 300u8" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import limits\nfn one() -> u8: return limits::maximum\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[1].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 17 }, type_checker.failure.?.location.?);
}

test "checkConstant: checks a constant that constructs a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nconst origin = Point{x = 0, y = 0}\nfn make() -> Point: return origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("Point", value.type.?.@"struct".name);
}

test "checkConstant: reports errors in the module of the constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: i32\nconst origin = Point{x = true}" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes\nfn make() -> shapes::Point: return shapes::origin" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[1].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkConstant: checks an operator in a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: i32 = 10\nconst double: i32 = limit * 2\nconst ready = limit < 5\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const declarations = loader.modules.items[0].declarations;
    const double = declarations[1].kind.constant_declaration.value;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, double.type.?);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, double.kind.binary.right.type.?);
    try std.testing.expectEqual(types.Type.boolean, declarations[2].kind.constant_declaration.value.type.?);
}

test "checkDeclaredValue: gives a literal the written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const limit: i32 = 5\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const constant = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.constant_declaration;
    try std.testing.expectEqual(types.Type{ .number = .i32 }, constant.value.type);
}

test "checkDeclaredValue: rejects a value of another type than the written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const limit: i32 = true\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 24 }, type_checker.failure.?.location.?);
}

test "checkDeclaredValue: rejects a number without a suffix or a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32): _ = value\nfn main():\n    const limit = 5\n    take(limit)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkDeclaredValue: checks the written type of a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const limit: u8 = 300\nfn show() -> u8: return limit" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.LiteralOutOfRange, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 19 }, type_checker.failure.?.location.?);
}

test "checkDeclaredValue: gives a struct literal the written type of a top-level constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    value: i32\nconst data: Data = {value = 0}\nfn make() -> Data: return data" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const value = loader.modules.items[0].declarations[1].kind.constant_declaration.value;
    try std.testing.expectEqualStrings("Data", value.type.?.@"struct".name);
}

test "completeArrayType: takes the length from another array constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [3]i32 = {1, 2, 3}\nconst second: [_]i32 = first\nfn all() -> [3]i32: return second" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const written = loader.modules.items[0].declarations[1].kind.constant_declaration.type.?;
    try std.testing.expectEqual(3, ast.extractType(written).array.length);
}

test "completeArrayType: completes a constant used before its declaration and used twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn all() -> [3]i32: return second\nfn again() -> [3]i32: return second\nconst second: [_]i32 = first\nconst first: [3]i32 = {1, 2, 3}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const written = loader.modules.items[0].declarations[2].kind.constant_declaration.type.?;
    try std.testing.expectEqual(3, ast.extractType(written).array.length);
}

test "completeArrayType: takes the length from a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn make() -> [4]u8\nfn all() -> [4]u8:\n    const values: [_]u8 = make()\n    return values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const written = body[0].kind.constant_declaration.type.?;
    try std.testing.expectEqual(4, ast.extractType(written).array.length);
}

test "completeArrayType: takes the length of a variable from a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Data:\n    items: [2]i32\nfn first(data: Data) -> [2]i32:\n    var values: [_]i32 = data.items\n    values[0] = 1\n    return values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const written = body[0].kind.variable_declaration.type.?;
    try std.testing.expectEqual(2, ast.extractType(written).array.length);
}

test "completeArrayType: rejects undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values: [_]i32 = undefined\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 28 }, type_checker.failure.?.location.?);
}

test "completeArrayType: rejects a value that is not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const count = 1i32\n    const values: [_]i32 = count\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 28 }, type_checker.failure.?.location.?);
}

test "completeArrayType: rejects an array of another element type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const first: [3]i64 = {1, 2, 3}\nconst second: [_]i32 = first\nfn all() -> [3]i32: return second" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 24 }, type_checker.failure.?.location.?);
}

test "computeLiteralType: gives a string literal the constant byte slice type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> []const u8: return greeting\nconst greeting = \"hi\"\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });
    try type_checker.check();

    const text_type: types.Type = .{ .slice = try type_registry.addSlice(arena.allocator(), .{ .number = .u8 }, true) };
    try std.testing.expectEqual(text_type, loader.modules.items[0].declarations[1].kind.constant_declaration.value.type);
}

test "computeLiteralType: rejects a character literal without a written type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u8: return letter\nconst letter = 'a'\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 16 }, type_checker.failure.?.location.?);
}

test "computeLiteralType: rejects a number without a suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return limit\nconst limit = 5\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, type_checker.failure.?.location.?);
}

test "computeLiteralType: rejects an unknown suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return limit\nconst limit = 5Bool\nfn main(): noop" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownSuffix, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 15 }, type_checker.failure.?.location.?);
}

test "expectNumber: rejects an unknown suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> u8: return 5Bool" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownSuffix, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "expectNumber: rejects an integer suffix on a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> u8: return 2.5u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}
