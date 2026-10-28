const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const AnalyzeError = @import("analyzer.zig").AnalyzeError;
const Failure = core.Failure;
const Value = core.Value;

const followPointer = types.followPointer;

const step_limit = 1_000_000;
const depth_limit = 512;

pub const Evaluator = struct {
    arena: *std.heap.ArenaAllocator,
    program: ast.Program,
    module_index: usize = 0,
    steps: u64 = 0,
    depth: usize = 0,
    frame: ?*Frame = null,
    preparer: ?Preparer = null,
    cache: std.ArrayList(Cached) = .empty,
    calls: std.ArrayList(Active) = .empty,
    failure: ?Failure = null,

    pub fn init(arena: *std.heap.ArenaAllocator, program: ast.Program) Evaluator {
        return .{ .arena = arena, .program = program };
    }

    pub fn isKnown(self: *const Evaluator, expression: ast.Expression) bool {
        return self.isKnownWith(expression, true);
    }

    pub fn isKnownWithoutCalls(self: *const Evaluator, expression: ast.Expression) bool {
        return self.isKnownWith(expression, false);
    }

    pub fn evaluate(self: *Evaluator, expression: ast.Expression) EvaluateError!Value {
        const caller_frame = self.frame;
        self.frame = null;
        defer self.frame = caller_frame;
        return self.evaluateExpression(expression);
    }

    pub fn evaluateConstant(self: *Evaluator, constant: ast.Resolution.Constant) EvaluateError!*Value {
        const declaration = ast.findDeclaration(self.program.modules[constant.module], constant.declaration);
        const constant_declaration = &declaration.kind.constant_declaration;
        if (constant_declaration.known) |cell| return cell;
        const caller_module_index = self.module_index;
        self.module_index = constant.module;
        defer self.module_index = caller_module_index;
        const value = &constant_declaration.value;
        if (constant_declaration.evaluating) return self.fail(value.location, error.DependencyLoop);
        constant_declaration.evaluating = true;
        defer constant_declaration.evaluating = false;
        const caller_frame = self.frame;
        self.frame = null;
        defer self.frame = caller_frame;
        const declared = ast.extractDeclaredType(constant_declaration.type, value.*);
        const cell = try self.arena.allocator().create(Value);
        cell.* = try self.copy(try self.evaluateConverted(value.*, declared));
        constant_declaration.known = cell;
        return cell;
    }

    pub fn evaluateDefault(self: *Evaluator, struct_type: types.Struct, field: types.Field) EvaluateError!Value {
        if (field.default_value.?.*) |value| return value;
        const caller_module_index = self.module_index;
        self.module_index = struct_type.module;
        defer self.module_index = caller_module_index;
        const caller_frame = self.frame;
        self.frame = null;
        defer self.frame = caller_frame;
        const value = try self.copy(try self.evaluateConverted(field.default.?.*, field.type));
        field.default_value.?.* = value;
        return value;
    }

    pub fn findCurrentFunction(self: *const Evaluator) ?ast.Resolution.Function {
        const frame = self.frame orelse return null;
        return frame.function;
    }

    pub fn isSameKey(self: *const Evaluator, one: Value, two: Value) bool {
        return switch (one) {
            .float => |value| two == .float and @as(u128, @bitCast(value)) == @as(u128, @bitCast(two.float)),
            .aggregate => |elements| {
                if (two != .aggregate or two.aggregate.len != elements.len) return false;
                for (elements, two.aggregate) |element, other| {
                    if (!self.isSameKey(element, other)) return false;
                }
                return true;
            },
            .optional => |optional| {
                if (two != .optional) return false;
                const inner = optional orelse return two.optional == null;
                const other = two.optional orelse return false;
                return self.isSameKey(inner.*, other.*);
            },
            .slice => |slice| {
                if (two != .slice or two.slice.length != slice.length) return false;
                const elements = self.locate(slice.array).aggregate[slice.start..][0..slice.length];
                const others = self.locate(two.slice.array).aggregate[two.slice.start..][0..slice.length];
                for (elements, others) |element, other| {
                    if (!self.isSameKey(element, other)) return false;
                }
                return true;
            },
            .integer, .boolean, .void, .undefined, .pointer, .many, .function, .type => isEqual(one, two),
        };
    }

    fn isKnownWith(self: *const Evaluator, expression: ast.Expression, calls: bool) bool {
        return switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal, .null => true,
            inline .identifier, .path_expression => |name| self.isKnownResolution(name.resolution, calls),
            .negation, .unwrap, .dereference, .address_of => |operand| self.isKnownWith(operand.*, calls),
            .unary => |unary| self.isKnownWith(unary.operand.*, calls),
            .binary => |binary| self.isKnownWith(binary.left.*, calls) and self.isKnownWith(binary.right.*, calls),
            .composite_literal => |literal| self.areKnown(literal.elements, calls),
            .index => |indexing| self.isKnownWith(indexing.value.*, calls) and self.isKnownWith(indexing.index.*, calls),
            .slice => |slice| {
                if (!self.isKnownWith(slice.value.*, calls)) return false;
                for ([_]?*ast.Expression{ slice.start, slice.end }) |optional_bound| {
                    const bound = optional_bound orelse continue;
                    if (!self.isKnownWith(bound.*, calls)) return false;
                }
                return true;
            },
            .field_access => |access| self.isKnownWith(access.value.*, calls),
            .call => |call| {
                if (!calls) return false;
                const resolution = ast.extractResolution(call.callee);
                if (resolution != .function and !self.isKnownResolution(resolution, calls)) return false;
                return self.areKnown(call.arguments, calls);
            },
            .method_call => |call| calls and self.isKnownWith(call.receiver.*, calls) and self.areKnown(call.arguments, calls),
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type, .struct_type => true,
            .undefined => false,
        };
    }

    fn isKnownResolution(self: *const Evaluator, resolution: ?ast.Resolution, calls: bool) bool {
        const resolved = resolution orelse return false;
        return switch (resolved) {
            .constant, .function, .type => true,
            .local => |statement| {
                if (statement.kind != .constant_declaration) return false;
                return self.isKnownWith(statement.kind.constant_declaration.value, calls);
            },
            .parameter, .element, .trait_function, .trait_method => false,
        };
    }

    fn areKnown(self: *const Evaluator, arguments: []const ast.Argument, calls: bool) bool {
        for (arguments) |argument| {
            if (!self.isKnownWith(argument.value, calls)) return false;
        }
        return true;
    }

    fn evaluateExpression(self: *Evaluator, expression: ast.Expression) EvaluateError!Value {
        const location = expression.location;
        return switch (expression.kind) {
            .integer_literal => |literal| parseInteger(findNumber(expression.type.?), literal.text),
            .float_literal => |literal| .{ .float = parseFloat(findNumber(expression.type.?), literal.text) },
            .boolean_literal => |value| .{ .boolean = value },
            .string_literal => |text| self.makeString(expression.type.?, text),
            .null => .{ .optional = null },
            .undefined => self.makeUndefined(expression.type.?),
            inline .identifier, .path_expression => |name| self.readResolution(location, name.resolution.?),
            .negation => |operand| self.evaluateNegation(expression, operand.*),
            .unary => |unary| self.evaluateUnary(expression, unary),
            .binary => |binary| self.evaluateBinary(expression, binary),
            .composite_literal => |literal| self.evaluateCompositeLiteral(expression, literal),
            .index, .field_access, .dereference => self.readPlace(location, try self.findPlace(expression)),
            .slice => |slice| self.evaluateSlice(expression, slice),
            .unwrap => |operand| self.evaluateUnwrap(expression, operand.*),
            .address_of => |operand| self.evaluateAddress(operand.*),
            .call => |call| self.evaluateCall(location, call),
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => .{
                .type = ast.extractType(expression),
            },
            .struct_type => |struct_type| self.evaluateStructType(location, struct_type),
            .method_call => self.fail(location, error.CannotEvaluate),
        };
    }

    fn evaluateStructType(self: *Evaluator, location: token.Location, struct_type: *const ast.StructType) EvaluateError!Value {
        const preparer = self.preparer orelse return self.fail(location, error.CannotEvaluate);
        const created = try preparer.beginStruct(preparer.context, struct_type);
        if (self.calls.items.len > 0) {
            const innermost = &self.calls.items[self.calls.items.len - 1];
            if (innermost.frame == self.frame) innermost.pending = created;
        }
        try preparer.finishStruct(preparer.context, struct_type, created, location);
        return .{ .type = created };
    }

    fn evaluateConverted(self: *Evaluator, expression: ast.Expression, expected: types.Type) EvaluateError!Value {
        const value = try self.evaluateExpression(expression);
        return convert(value, expression.type.?, expected);
    }

    fn readResolution(self: *Evaluator, location: token.Location, resolution: ast.Resolution) EvaluateError!Value {
        const value = switch (resolution) {
            .constant => |constant| (try self.evaluateConstant(constant)).*,
            .function => |function| Value{ .function = function },
            .type => |value_type| Value{ .type = value_type },
            .parameter, .local, .element => (try self.findCell(location, resolution)).*,
            .trait_function, .trait_method => return self.fail(location, error.CannotEvaluate),
        };
        if (value == .undefined) return self.fail(location, error.ReadUndefined);
        return value;
    }

    fn findCell(self: *Evaluator, location: token.Location, resolution: ast.Resolution) EvaluateError!*Value {
        if (self.frame) |frame| {
            switch (resolution) {
                .parameter => |index| return &frame.parameters[index],
                .local => |statement| {
                    if (frame.locals.get(statement)) |cell| return cell;
                },
                .element => |element| {
                    if (frame.elements.get(element)) |cell| return cell;
                },
                .constant, .function, .type, .trait_function, .trait_method => unreachable,
            }
        }
        if (resolution == .local and resolution.local.kind == .constant_declaration) {
            const constant = resolution.local.kind.constant_declaration;
            const declared = ast.extractDeclaredType(constant.type, constant.value);
            const cell = try self.arena.allocator().create(Value);
            cell.* = try self.copy(try self.evaluateConverted(constant.value, declared));
            return cell;
        }
        return self.fail(location, error.CannotEvaluate);
    }

    fn findPlace(self: *Evaluator, expression: ast.Expression) EvaluateError!Value.Pointer {
        const location = expression.location;
        switch (expression.kind) {
            inline .identifier, .path_expression => |name| {
                const resolution = name.resolution.?;
                const value_type = expression.type.?;
                return switch (resolution) {
                    .constant => |constant| .{ .root = try self.evaluateConstant(constant), .root_type = value_type, .path = &.{} },
                    .parameter, .local, .element => .{
                        .root = try self.findCell(location, resolution),
                        .root_type = value_type,
                        .path = &.{},
                    },
                    .function, .type, .trait_function, .trait_method => self.fail(location, error.CannotEvaluate),
                };
            },
            .field_access => |access| {
                const position = findFieldPosition(followPointer(access.value.type.?).@"struct", access.field);
                const base = if (access.value.type.? == .pointer)
                    try self.expectPointer(location, try self.evaluateExpression(access.value.*))
                else
                    try self.findPlace(access.value.*);
                return self.extendPlace(base, position);
            },
            .index => |indexing| return self.findElement(indexing),
            .dereference => |operand| return self.expectPointer(location, try self.evaluateExpression(operand.*)),
            .integer_literal,
            .float_literal,
            .boolean_literal,
            .string_literal,
            .undefined,
            .null,
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
            => {
                const cell = try self.arena.allocator().create(Value);
                cell.* = try self.evaluateExpression(expression);
                return .{ .root = cell, .root_type = expression.type.?, .path = &.{} };
            },
        }
    }

    fn findElement(self: *Evaluator, indexing: ast.Index) EvaluateError!Value.Pointer {
        const location = indexing.index.location;
        const position = try self.expectIndex(location, try self.evaluateExpression(indexing.index.*));
        switch (indexing.value.type.?) {
            .array => |array| {
                if (position >= array.length) return self.fail(location, error.IndexOutOfRange);
                return self.extendPlace(try self.findPlace(indexing.value.*), @intCast(position));
            },
            .tuple => return self.extendPlace(try self.findPlace(indexing.value.*), @intCast(position)),
            .slice => {
                const slice = (try self.evaluateExpression(indexing.value.*)).slice;
                if (position >= slice.length) return self.fail(location, error.IndexOutOfRange);
                return self.extendPlace(slice.array, slice.start + @as(usize, @intCast(position)));
            },
            .pointer => |pointer| {
                const value = try self.evaluateExpression(indexing.value.*);
                if (!pointer.many) {
                    if (position >= pointer.target.array.length) return self.fail(location, error.IndexOutOfRange);
                    return self.extendPlace(try self.expectPointer(location, value), @intCast(position));
                }
                const many = value.many;
                const element = many.index + position;
                const length = self.locate(many.array).aggregate.len;
                if (element < 0 or element >= length) return self.fail(location, error.IndexOutOfRange);
                return self.extendPlace(many.array, @intCast(element));
            },
            .number, .boolean, .void, .type, .@"struct", .optional, .function, .implementer => unreachable,
        }
    }

    fn extendPlace(self: *Evaluator, base: Value.Pointer, position: usize) EvaluateError!Value.Pointer {
        const path = try self.arena.allocator().alloc(usize, base.path.len + 1);
        @memcpy(path[0..base.path.len], base.path);
        path[base.path.len] = position;
        return .{ .root = base.root, .root_type = base.root_type, .path = path, .text = base.text };
    }

    fn locate(self: *const Evaluator, pointer: Value.Pointer) *Value {
        _ = self;
        var current = pointer.root;
        for (pointer.path) |position| current = &current.aggregate[position];
        return current;
    }

    fn readPlace(self: *Evaluator, location: token.Location, pointer: Value.Pointer) EvaluateError!Value {
        const value = self.locate(pointer).*;
        if (value == .undefined) return self.fail(location, error.ReadUndefined);
        return value;
    }

    fn expectPointer(self: *Evaluator, location: token.Location, value: Value) EvaluateError!Value.Pointer {
        if (value != .pointer) return self.fail(location, error.ReadUndefined);
        return value.pointer;
    }

    fn expectIndex(self: *Evaluator, location: token.Location, value: Value) EvaluateError!i129 {
        if (value != .integer) return self.fail(location, error.ReadUndefined);
        return value.integer;
    }

    fn evaluateNegation(self: *Evaluator, expression: ast.Expression, operand: ast.Expression) EvaluateError!Value {
        const number = findNumber(expression.type.?);
        return switch (try self.evaluateExpression(operand)) {
            .integer => |value| self.expectInRange(expression.location, number, -value),
            .float => |value| .{ .float = -value },
            .boolean, .void, .undefined, .optional, .aggregate, .pointer, .many, .slice, .function, .type => unreachable,
        };
    }

    fn evaluateUnary(self: *Evaluator, expression: ast.Expression, unary: ast.Unary) EvaluateError!Value {
        const operand = try self.evaluateExpression(unary.operand.*);
        switch (unary.operator) {
            .not => return .{ .boolean = !operand.boolean },
            .negate => {
                const number = findNumber(expression.type.?);
                if (operand == .float) return .{ .float = -operand.float };
                return self.expectInRange(expression.location, number, -operand.integer);
            },
            .bitwise_not => {
                const number = findNumber(expression.type.?);
                if (findMinimum(number) < 0) return .{ .integer = -operand.integer - 1 };
                return .{ .integer = findMaximum(number) - operand.integer };
            },
        }
    }

    fn evaluateBinary(self: *Evaluator, expression: ast.Expression, binary: ast.Binary) EvaluateError!Value {
        switch (binary.operator) {
            .@"and" => {
                const left = try self.evaluateExpression(binary.left.*);
                if (!left.boolean) return left;
                return self.evaluateExpression(binary.right.*);
            },
            .@"or" => {
                const left = try self.evaluateExpression(binary.left.*);
                if (left.boolean) return left;
                return self.evaluateExpression(binary.right.*);
            },
            .@"orelse" => {
                const left = try self.evaluateExpression(binary.left.*);
                const inner = left.optional orelse return self.evaluateExpression(binary.right.*);
                if (expression.type.? == .optional) return left;
                return inner.*;
            },
            .equal, .not_equal => {
                const left = try self.evaluateExpression(binary.left.*);
                const right = try self.evaluateExpression(binary.right.*);
                return .{ .boolean = isEqual(left, right) == (binary.operator == .equal) };
            },
            .less_than, .less_than_or_equal, .greater_than, .greater_than_or_equal => {
                const left = try self.evaluateExpression(binary.left.*);
                const right = try self.evaluateExpression(binary.right.*);
                return .{ .boolean = compare(binary.operator, left, right) };
            },
            .multiply,
            .divide,
            .remainder,
            .add,
            .subtract,
            .shift_left,
            .shift_right,
            .bitwise_and,
            .bitwise_exclusive_or,
            .bitwise_or,
            => {
                const left = try self.evaluateExpression(binary.left.*);
                const right = try self.evaluateExpression(binary.right.*);
                const location = expression.location;
                if (left == .many or right == .many) return self.computePointer(location, binary.operator, left, right);
                const number = findNumber(expression.type.?);
                if (left == .float) return .{ .float = computeFloat(binary.operator, number, left.float, right.float) };
                return self.computeInteger(location, binary.operator, number, left.integer, right.integer);
            },
        }
    }

    fn computePointer(
        self: *Evaluator,
        location: token.Location,
        operator: ast.BinaryOperator,
        left: Value,
        right: Value,
    ) EvaluateError!Value {
        if (left == .many and right == .many) {
            return self.expectInRange(location, .isize, left.many.index - right.many.index);
        }
        const many = if (left == .many) left.many else right.many;
        const offset = if (left == .many) right.integer else left.integer;
        const index = if (operator == .add) many.index + offset else many.index - offset;
        return .{ .many = .{ .array = many.array, .index = index } };
    }

    fn computeInteger(
        self: *Evaluator,
        location: token.Location,
        operator: ast.BinaryOperator,
        number: types.NumberType,
        left: i129,
        right: i129,
    ) EvaluateError!Value {
        const result: i129 = switch (operator) {
            .add => result: {
                const sum, const overflow = @addWithOverflow(left, right);
                if (overflow == 1) return self.fail(location, error.IntegerOverflow);
                break :result sum;
            },
            .subtract => result: {
                const difference, const overflow = @subWithOverflow(left, right);
                if (overflow == 1) return self.fail(location, error.IntegerOverflow);
                break :result difference;
            },
            .multiply => result: {
                const product, const overflow = @mulWithOverflow(left, right);
                if (overflow == 1) return self.fail(location, error.IntegerOverflow);
                break :result product;
            },
            .divide => result: {
                if (right == 0) return self.fail(location, error.DivisionByZero);
                break :result @divTrunc(left, right);
            },
            .remainder => result: {
                if (right == 0) return self.fail(location, error.DivisionByZero);
                break :result @rem(left, right);
            },
            .bitwise_and => left & right,
            .bitwise_exclusive_or => left ^ right,
            .bitwise_or => left | right,
            .shift_left => shiftLeft(number, left, right),
            .shift_right => shiftRight(number, left, right),
            .@"orelse",
            .equal,
            .not_equal,
            .less_than,
            .less_than_or_equal,
            .greater_than,
            .greater_than_or_equal,
            .@"and",
            .@"or",
            => unreachable,
        };
        return self.expectInRange(location, number, result);
    }

    fn evaluateCompositeLiteral(
        self: *Evaluator,
        expression: ast.Expression,
        literal: ast.CompositeLiteral,
    ) EvaluateError!Value {
        const allocator = self.arena.allocator();
        switch (expression.type.?) {
            .@"struct" => |struct_type| {
                const fields = try allocator.alloc(Value, struct_type.fields.len);
                for (struct_type.fields, fields) |field, *field_value| {
                    if (ast.findArgument(literal.elements, field.name)) |position| {
                        const value = try self.evaluateConverted(literal.elements[position].value, field.type);
                        field_value.* = try self.copy(value);
                    } else {
                        field_value.* = try self.copy(try self.evaluateDefault(struct_type, field));
                    }
                }
                return .{ .aggregate = fields };
            },
            .array => |array| {
                const elements = try allocator.alloc(Value, literal.elements.len);
                for (literal.elements, elements) |element, *element_value| {
                    element_value.* = try self.copy(try self.evaluateConverted(element.value, array.element));
                }
                return .{ .aggregate = elements };
            },
            .tuple => |tuple| {
                const elements = try allocator.alloc(Value, literal.elements.len);
                for (literal.elements, tuple.elements, elements) |element, element_type, *element_value| {
                    element_value.* = try self.copy(try self.evaluateConverted(element.value, element_type));
                }
                return .{ .aggregate = elements };
            },
            .number, .boolean, .void, .type, .slice, .pointer, .optional, .function, .implementer => unreachable,
        }
    }

    fn evaluateSlice(self: *Evaluator, expression: ast.Expression, slice: ast.Slice) EvaluateError!Value {
        const location = expression.location;
        const array: Value.Pointer, const base: usize, const length: usize = switch (slice.value.type.?) {
            .array => |array| .{ try self.findPlace(slice.value.*), 0, @intCast(array.length) },
            .slice => base: {
                const value = (try self.evaluateExpression(slice.value.*)).slice;
                break :base .{ value.array, value.start, value.length };
            },
            .pointer => |pointer| base: {
                const value = try self.evaluateExpression(slice.value.*);
                if (!pointer.many) {
                    break :base .{ try self.expectPointer(location, value), 0, @intCast(pointer.target.array.length) };
                }
                if (value.many.index < 0) return self.fail(location, error.SliceOutOfRange);
                const available = self.locate(value.many.array).aggregate.len;
                if (value.many.index > available) return self.fail(location, error.SliceOutOfRange);
                break :base .{ value.many.array, @intCast(value.many.index), available - @as(usize, @intCast(value.many.index)) };
            },
            .number, .boolean, .void, .type, .@"struct", .optional, .tuple, .function, .implementer => unreachable,
        };
        const start = try self.evaluateBound(slice.start, 0);
        const end = try self.evaluateBound(slice.end, length);
        if (start > end or end > length) return self.fail(location, error.SliceOutOfRange);
        return .{ .slice = .{ .array = array, .start = base + start, .length = end - start } };
    }

    fn evaluateBound(self: *Evaluator, bound: ?*ast.Expression, fallback: usize) EvaluateError!usize {
        const expression = bound orelse return fallback;
        const value = try self.expectIndex(expression.location, try self.evaluateExpression(expression.*));
        if (value < 0) return self.fail(expression.location, error.SliceOutOfRange);
        if (value > std.math.maxInt(usize)) return self.fail(expression.location, error.SliceOutOfRange);
        return @intCast(value);
    }

    fn evaluateUnwrap(self: *Evaluator, expression: ast.Expression, operand: ast.Expression) EvaluateError!Value {
        const value = try self.evaluateExpression(operand);
        const inner = value.optional orelse return self.fail(expression.location, error.UnwrappedNull);
        return inner.*;
    }

    fn evaluateAddress(self: *Evaluator, operand: ast.Expression) EvaluateError!Value {
        switch (operand.kind) {
            inline .identifier, .path_expression => |name| {
                if (name.resolution.? == .function) return .{ .function = name.resolution.?.function };
            },
            else => {},
        }
        return .{ .pointer = try self.findPlace(operand) };
    }

    fn evaluateCall(self: *Evaluator, location: token.Location, call: ast.Call) EvaluateError!Value {
        const resolution = ast.extractResolution(call.callee);
        const function = switch (resolution) {
            .function => |function| function,
            .parameter, .local, .constant, .element => (try self.readResolution(location, resolution)).function,
            .type, .trait_function, .trait_method => return self.fail(location, error.CannotEvaluate),
        };
        const declaration = ast.findDeclaration(self.program.modules[function.module], function.declaration);
        const definition = switch (declaration.kind) {
            .function_definition => |*definition| definition,
            .function_declaration => return self.fail(location, error.ExternalCall),
            .constant_declaration, .struct_definition, .trait_definition, .implementation, .import => unreachable,
        };
        const signature = definition.signature;
        const allocator = self.arena.allocator();
        const parameters = try allocator.alloc(Value, call.arguments.len);
        var cached = true;
        for (call.arguments, signature.parameters, parameters) |argument, parameter, *parameter_value| {
            const parameter_type = ast.extractType(parameter.type);
            const value = try self.evaluateConverted(argument.value, parameter_type);
            parameter_value.* = try self.copy(value);
            if (hasWritableReference(parameter_type, null)) cached = false;
        }
        if (cached) {
            if (self.findCached(function, parameters)) |result| return result;
            if (self.findPending(function, parameters)) |pending| return .{ .type = pending };
        }
        try self.step(location);
        if (self.depth >= depth_limit) return self.fail(location, error.CallDepth);
        self.depth += 1;
        defer self.depth -= 1;
        if (self.preparer) |preparer| try preparer.prepare(preparer.context, function);
        var frame: Frame = .{
            .function = function,
            .parameters = parameters,
            .return_type = ast.extractType(signature.return_type),
        };
        const caller_frame = self.frame;
        self.frame = &frame;
        defer self.frame = caller_frame;
        if (cached) try self.calls.append(allocator, .{ .function = function, .arguments = parameters, .frame = &frame });
        defer if (cached) {
            _ = self.calls.pop();
        };
        const caller_module_index = self.module_index;
        self.module_index = if (definition.default_of) |trait| trait.module else function.module;
        defer self.module_index = caller_module_index;
        const result: Value = switch (try self.executeBlock(definition.body)) {
            .returned => |value| value,
            .next => .void,
            .broke, .continued => unreachable,
        };
        if (cached) try self.cache.append(self.arena.allocator(), .{ .function = function, .arguments = parameters, .result = result });
        return result;
    }

    fn findPending(self: *const Evaluator, function: ast.Resolution.Function, arguments: []const Value) ?types.Type {
        for (self.calls.items) |active| {
            if (!std.meta.eql(active.function, function)) continue;
            const pending = active.pending orelse continue;
            const same = for (active.arguments, arguments) |one, two| {
                if (!self.isSameKey(one, two)) break false;
            } else true;
            if (same) return pending;
        }
        return null;
    }

    fn findCached(self: *const Evaluator, function: ast.Resolution.Function, arguments: []const Value) ?Value {
        for (self.cache.items) |entry| {
            if (!std.meta.eql(entry.function, function)) continue;
            const same = for (entry.arguments, arguments) |one, two| {
                if (!self.isSameKey(one, two)) break false;
            } else true;
            if (same) return entry.result;
        }
        return null;
    }

    fn executeBlock(self: *Evaluator, statements: []const ast.Statement) EvaluateError!Flow {
        for (statements) |*statement| {
            const flow = try self.executeStatement(statement);
            if (flow != .next) return flow;
        }
        return .next;
    }

    fn executeStatement(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        switch (statement.kind) {
            .noop => {},
            .@"return" => |optional_value| {
                const value = optional_value orelse return .{ .returned = .void };
                return .{ .returned = try self.evaluateConverted(value, self.frame.?.return_type) };
            },
            .discard => |expression| {
                if (expression.kind != .identifier) _ = try self.evaluateExpression(expression);
            },
            .call => |expression| _ = try self.evaluateExpression(expression),
            .constant_declaration => |constant| {
                if (ast.isAlias(constant)) return .next;
                const declared = ast.extractDeclaredType(constant.type, constant.value);
                try self.declareLocal(statement, try self.evaluateConverted(constant.value, declared));
            },
            .variable_declaration => |variable| {
                const declared = ast.extractDeclaredType(variable.type, variable.value);
                if (variable.value.kind == .undefined) {
                    try self.declareLocal(statement, try self.makeUndefined(declared));
                } else {
                    try self.declareLocal(statement, try self.evaluateConverted(variable.value, declared));
                }
            },
            .tuple_declaration => |declaration| try self.executeTupleDeclaration(statement, declaration),
            .assignment => |assignment| try self.executeAssignment(assignment),
            .@"if" => |conditional| {
                if (try self.evaluateCondition(conditional.condition)) return self.executeBlock(conditional.body);
                const else_body = conditional.else_body orelse return .next;
                return self.executeBlock(else_body);
            },
            .@"while" => return self.executeWhile(statement),
            .@"for" => return self.executeFor(statement),
            .@"break" => |jump| return .{ .broke = jump.loop.? },
            .@"continue" => |jump| return .{ .continued = jump.loop.? },
        }
        return .next;
    }

    fn declareLocal(self: *Evaluator, statement: *const ast.Statement, value: Value) EvaluateError!void {
        const cell = try self.arena.allocator().create(Value);
        cell.* = try self.copy(value);
        try self.frame.?.locals.put(self.arena.allocator(), statement, cell);
    }

    fn declareElement(self: *Evaluator, element: ast.Resolution.Element, value: Value) EvaluateError!void {
        const cell = try self.arena.allocator().create(Value);
        cell.* = try self.copy(value);
        try self.frame.?.elements.put(self.arena.allocator(), element, cell);
    }

    fn executeTupleDeclaration(
        self: *Evaluator,
        statement: *const ast.Statement,
        declaration: ast.TupleDeclaration,
    ) EvaluateError!void {
        const location = declaration.value.location;
        const place = try self.findPlace(declaration.value);
        for (declaration.names, 0..) |name, position| {
            if (ast.isDiscardedName(name.name)) continue;
            const element_place = try self.extendPlace(place, position);
            const value = if (name.pointer)
                Value{ .pointer = element_place }
            else
                try self.readPlace(location, element_place);
            try self.declareElement(.{ .statement = statement, .position = position }, value);
        }
    }

    fn executeAssignment(self: *Evaluator, assignment: ast.Assignment) EvaluateError!void {
        const target = assignment.target;
        const place = try self.findPlace(target);
        const target_type = target.type.?;
        const value = if (assignment.operator) |operator| value: {
            const current = try self.readPlace(target.location, place);
            const right = try self.evaluateExpression(assignment.value);
            const location = target.location;
            if (current == .many) break :value try self.computePointer(location, operator.operator, current, right);
            const number = findNumber(target_type);
            if (current == .float) break :value Value{ .float = computeFloat(operator.operator, number, current.float, right.float) };
            break :value try self.computeInteger(operator.location, operator.operator, number, current.integer, right.integer);
        } else try self.evaluateConverted(assignment.value, target_type);
        self.locate(place).* = try self.copy(value);
    }

    fn evaluateCondition(self: *Evaluator, condition: ast.Expression) EvaluateError!bool {
        return (try self.evaluateExpression(condition)).boolean;
    }

    fn executeWhile(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const loop = statement.kind.@"while";
        while (true) {
            try self.step(statement.location);
            if (!try self.evaluateCondition(loop.condition)) break;
            switch (try self.executeBlock(loop.body)) {
                .next => {},
                .broke => |target| {
                    if (target == statement) return .next;
                    return .{ .broke = target };
                },
                .continued => |target| {
                    if (target != statement) return .{ .continued = target };
                },
                .returned => |value| return .{ .returned = value },
            }
        }
        const else_body = loop.else_body orelse return .next;
        return self.executeBlock(else_body);
    }

    fn executeFor(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const loop = statement.kind.@"for";
        switch (loop.sequence) {
            .range => |range| {
                const start = try self.expectIndex(range.start.location, try self.evaluateExpression(range.start));
                const end: ?i129 = if (range.end) |end_expression|
                    try self.expectIndex(end_expression.location, try self.evaluateExpression(end_expression))
                else
                    null;
                if (end) |last| {
                    if (start > last) return self.fail(range.start.location, error.ReversedRange);
                }
                var index = start;
                while (end == null or index < end.?) : (index += 1) {
                    try self.step(statement.location);
                    try self.bindNames(statement, .{ .integer = index }, null);
                    switch (try self.executeBlock(loop.body)) {
                        .next => {},
                        .broke => |target| {
                            if (target == statement) return .next;
                            return .{ .broke = target };
                        },
                        .continued => |target| {
                            if (target != statement) return .{ .continued = target };
                        },
                        .returned => |value| return .{ .returned = value },
                    }
                }
            },
            .value => |value| {
                const array: Value.Pointer, const start: usize, const length: usize = switch (value.type.?) {
                    .array => |array| .{ try self.findPlace(value), 0, @intCast(array.length) },
                    .slice => sequence: {
                        const slice = (try self.evaluateExpression(value)).slice;
                        break :sequence .{ slice.array, slice.start, slice.length };
                    },
                    .pointer => |pointer| sequence: {
                        const target = try self.expectPointer(value.location, try self.evaluateExpression(value));
                        break :sequence .{ target, 0, @intCast(pointer.target.array.length) };
                    },
                    .number, .boolean, .void, .type, .@"struct", .optional, .tuple, .function, .implementer => unreachable,
                };
                for (0..length) |offset| {
                    try self.step(statement.location);
                    const element = try self.extendPlace(array, start + offset);
                    try self.bindNames(statement, null, element);
                    switch (try self.executeBlock(loop.body)) {
                        .next => {},
                        .broke => |target| {
                            if (target == statement) return .next;
                            return .{ .broke = target };
                        },
                        .continued => |target| {
                            if (target != statement) return .{ .continued = target };
                        },
                        .returned => |returned| return .{ .returned = returned },
                    }
                }
            },
        }
        const else_body = loop.else_body orelse return .next;
        return self.executeBlock(else_body);
    }

    fn bindNames(
        self: *Evaluator,
        statement: *const ast.Statement,
        integer: ?Value,
        element: ?Value.Pointer,
    ) EvaluateError!void {
        const loop = statement.kind.@"for";
        for (loop.names, 0..) |name, position| {
            if (ast.isDiscardedName(name.name)) continue;
            const key: ast.Resolution.Element = .{ .statement = statement, .position = position };
            const place = element orelse {
                try self.declareElement(key, integer.?);
                continue;
            };
            const named = if (loop.tuple) try self.extendPlace(place, position) else place;
            const value = if (name.pointer) Value{ .pointer = named } else try self.readPlace(statement.location, named);
            try self.declareElement(key, value);
        }
    }

    fn makeString(self: *Evaluator, slice_type: types.Type, text: []const u8) EvaluateError!Value {
        const allocator = self.arena.allocator();
        const bytes = try decodeText(allocator, text);
        const elements = try allocator.alloc(Value, bytes.len);
        for (bytes, elements) |byte, *element| element.* = .{ .integer = byte };
        const root = try allocator.create(Value);
        root.* = .{ .aggregate = elements };
        const array = try self.program.types.addArray(allocator, bytes.len, slice_type.slice.element);
        const pointer: Value.Pointer = .{ .root = root, .root_type = .{ .array = array }, .path = &.{}, .text = true };
        return .{ .slice = .{ .array = pointer, .start = 0, .length = bytes.len } };
    }

    fn makeUndefined(self: *Evaluator, value_type: types.Type) EvaluateError!Value {
        const allocator = self.arena.allocator();
        switch (value_type) {
            .array => |array| {
                const elements = try allocator.alloc(Value, @intCast(array.length));
                for (elements) |*element| element.* = try self.makeUndefined(array.element);
                return .{ .aggregate = elements };
            },
            .tuple => |tuple| {
                const elements = try allocator.alloc(Value, tuple.elements.len);
                for (tuple.elements, elements) |element_type, *element| element.* = try self.makeUndefined(element_type);
                return .{ .aggregate = elements };
            },
            .@"struct" => |struct_type| {
                const fields = try allocator.alloc(Value, struct_type.fields.len);
                for (struct_type.fields, fields) |field, *field_value| field_value.* = try self.makeUndefined(field.type);
                return .{ .aggregate = fields };
            },
            .number, .boolean, .void, .type, .slice, .pointer, .optional, .function, .implementer => return .undefined,
        }
    }

    fn copy(self: *Evaluator, value: Value) EvaluateError!Value {
        switch (value) {
            .aggregate => |elements| {
                const copied = try self.arena.allocator().alloc(Value, elements.len);
                for (elements, copied) |element, *copied_element| copied_element.* = try self.copy(element);
                return .{ .aggregate = copied };
            },
            .optional => |optional| {
                const inner = optional orelse return value;
                const cell = try self.arena.allocator().create(Value);
                cell.* = try self.copy(inner.*);
                return .{ .optional = cell };
            },
            .integer, .float, .boolean, .void, .undefined, .pointer, .many, .slice, .function, .type => return value,
        }
    }

    fn step(self: *Evaluator, location: token.Location) EvaluateError!void {
        self.steps += 1;
        if (self.steps > step_limit) return self.fail(location, error.StepLimit);
    }

    fn expectInRange(
        self: *Evaluator,
        location: token.Location,
        number: types.NumberType,
        value: i129,
    ) EvaluateError!Value {
        if (value < findMinimum(number) or value > findMaximum(number)) {
            return self.fail(location, error.IntegerOverflow);
        }
        return .{ .integer = value };
    }

    fn fail(self: *Evaluator, location: token.Location, evaluation_error: EvaluationError) EvaluationError {
        self.failure = .{
            .module = self.program.modules[self.module_index].path,
            .location = location,
            .message = describeError(evaluation_error),
        };
        return evaluation_error;
    }
};

pub const Preparer = struct {
    context: *anyopaque,
    prepare: *const fn (context: *anyopaque, function: ast.Resolution.Function) AnalyzeError!void,
    beginStruct: *const fn (context: *anyopaque, struct_type: *const ast.StructType) AnalyzeError!types.Type,
    finishStruct: *const fn (
        context: *anyopaque,
        struct_type: *const ast.StructType,
        value_type: types.Type,
        location: token.Location,
    ) AnalyzeError!void,
};

pub const EvaluateError = AnalyzeError;

pub const EvaluationError = error{
    OutOfMemory,
    CannotEvaluate,
    IntegerOverflow,
    DivisionByZero,
    IndexOutOfRange,
    SliceOutOfRange,
    UnwrappedNull,
    ReadUndefined,
    ReversedRange,
    ExternalCall,
    StepLimit,
    CallDepth,
    DependencyLoop,
};

const Cached = struct {
    function: ast.Resolution.Function,
    arguments: []const Value,
    result: Value,
};

const Active = struct {
    function: ast.Resolution.Function,
    arguments: []const Value,
    frame: *Frame,
    pending: ?types.Type = null,
};

const Frame = struct {
    function: ast.Resolution.Function,
    parameters: []Value,
    return_type: types.Type,
    locals: std.AutoHashMapUnmanaged(*const ast.Statement, *Value) = .empty,
    elements: std.AutoHashMapUnmanaged(ast.Resolution.Element, *Value) = .empty,
};

const Flow = union(enum) {
    next,
    broke: *const ast.Statement,
    continued: *const ast.Statement,
    returned: Value,
};

fn describeError(evaluation_error: EvaluationError) []const u8 {
    return switch (evaluation_error) {
        error.OutOfMemory => "out of memory",
        error.CannotEvaluate => "cannot be evaluated at compile time",
        error.IntegerOverflow => "integer overflow",
        error.DivisionByZero => "division by zero",
        error.IndexOutOfRange => "index is outside the length",
        error.SliceOutOfRange => "slice bounds are outside the length or reversed",
        error.UnwrappedNull => "null is unwrapped",
        error.ReadUndefined => "undefined is read",
        error.ReversedRange => "range starts after its end",
        error.ExternalCall => "external functions cannot run at compile time",
        error.StepLimit => "evaluation takes more than 1000000 steps",
        error.CallDepth => "compile-time calls are nested more than 512 deep",
        error.DependencyLoop => "value depends on itself at compile time",
    };
}

fn hasWritableReference(value_type: types.Type, visited: ?*const Visited) bool {
    return switch (value_type) {
        .pointer => |pointer| !pointer.constant or hasWritableReference(pointer.target, visited),
        .slice => |slice| !slice.constant or hasWritableReference(slice.element, visited),
        .array => |array| hasWritableReference(array.element, visited),
        .optional => |optional| hasWritableReference(optional.child, visited),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (hasWritableReference(element, visited)) return true;
            }
            return false;
        },
        .@"struct" => |struct_type| {
            var current = visited;
            while (current) |node| : (current = node.parent) {
                if (node.fields.ptr == struct_type.fields.ptr) return false;
            }
            const node: Visited = .{ .fields = struct_type.fields, .parent = visited };
            for (struct_type.fields) |field| {
                if (hasWritableReference(field.type, &node)) return true;
            }
            return false;
        },
        .number, .boolean, .void, .type, .function, .implementer => false,
    };
}

const Visited = struct {
    fields: []const types.Field,
    parent: ?*const Visited,
};

fn convert(value: Value, value_type: types.Type, expected: types.Type) Value {
    if (expected != .slice or value_type != .pointer) return value;
    const array = value_type.pointer.target.array;
    return .{ .slice = .{ .array = value.pointer, .start = 0, .length = @intCast(array.length) } };
}

fn findFieldPosition(struct_type: types.Struct, name: []const u8) usize {
    for (struct_type.fields, 0..) |field, position| {
        if (std.mem.eql(u8, field.name, name)) return position;
    }
    unreachable;
}

fn decodeText(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try bytes.append(allocator, text[index]);
            index += 1;
            continue;
        }
        const escaped = text[index + 1];
        index += 2;
        switch (escaped) {
            'n' => try bytes.append(allocator, '\n'),
            't' => try bytes.append(allocator, '\t'),
            'r' => try bytes.append(allocator, '\r'),
            '0' => try bytes.append(allocator, 0),
            'u' => {
                const end = std.mem.indexOfScalarPos(u8, text, index, '}').?;
                const code_point = std.fmt.parseInt(u21, text[index + 1 .. end], 16) catch unreachable;
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(code_point, &encoded) catch unreachable;
                try bytes.appendSlice(allocator, encoded[0..length]);
                index = end + 1;
            },
            else => try bytes.append(allocator, escaped),
        }
    }
    return bytes.items;
}

fn findNumber(value_type: types.Type) types.NumberType {
    return switch (value_type) {
        .number => |number| number,
        .optional => |optional| findNumber(optional.child),
        .boolean, .void, .type, .@"struct", .array, .slice, .pointer, .tuple, .function, .implementer => unreachable,
    };
}

fn parseInteger(number: types.NumberType, text: []const u8) Value {
    const value = std.fmt.parseInt(i129, text, 0) catch unreachable;
    return switch (number) {
        .f16, .f32, .f64, .f128 => .{ .float = roundFloat(number, @floatFromInt(value)) },
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => .{ .integer = value },
    };
}

fn parseFloat(number: types.NumberType, text: []const u8) f128 {
    return switch (number) {
        .f16 => std.fmt.parseFloat(f16, text) catch unreachable,
        .f32 => std.fmt.parseFloat(f32, text) catch unreachable,
        .f64 => std.fmt.parseFloat(f64, text) catch unreachable,
        .f128 => std.fmt.parseFloat(f128, text) catch unreachable,
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => unreachable,
    };
}

fn roundFloat(number: types.NumberType, value: f128) f128 {
    return switch (number) {
        .f16 => @as(f16, @floatCast(value)),
        .f32 => @as(f32, @floatCast(value)),
        .f64 => @as(f64, @floatCast(value)),
        .f128 => value,
        .i8, .i16, .i32, .i64, .i128, .isize, .u8, .u16, .u32, .u64, .u128, .usize => unreachable,
    };
}

fn computeFloat(operator: ast.BinaryOperator, number: types.NumberType, left: f128, right: f128) f128 {
    const result = switch (operator) {
        .add => left + right,
        .subtract => left - right,
        .multiply => left * right,
        .divide => left / right,
        .remainder,
        .shift_left,
        .shift_right,
        .bitwise_and,
        .bitwise_exclusive_or,
        .bitwise_or,
        .@"orelse",
        .equal,
        .not_equal,
        .less_than,
        .less_than_or_equal,
        .greater_than,
        .greater_than_or_equal,
        .@"and",
        .@"or",
        => unreachable,
    };
    return roundFloat(number, result);
}

fn compare(operator: ast.BinaryOperator, left: Value, right: Value) bool {
    const order: std.math.Order = switch (left) {
        .integer => |value| std.math.order(value, right.integer),
        .float => |value| order: {
            if (std.math.isNan(value) or std.math.isNan(right.float)) return false;
            break :order std.math.order(value, right.float);
        },
        .many => |many| std.math.order(many.index, right.many.index),
        .boolean, .void, .undefined, .optional, .aggregate, .pointer, .slice, .function, .type => unreachable,
    };
    return switch (operator) {
        .less_than => order == .lt,
        .less_than_or_equal => order != .gt,
        .greater_than => order == .gt,
        .greater_than_or_equal => order != .lt,
        .multiply,
        .divide,
        .remainder,
        .add,
        .subtract,
        .shift_left,
        .shift_right,
        .bitwise_and,
        .bitwise_exclusive_or,
        .bitwise_or,
        .@"orelse",
        .equal,
        .not_equal,
        .@"and",
        .@"or",
        => unreachable,
    };
}

fn isEqual(one: Value, two: Value) bool {
    return switch (one) {
        .integer => |value| two == .integer and two.integer == value,
        .float => |value| two == .float and two.float == value,
        .boolean => |value| two == .boolean and two.boolean == value,
        .void => two == .void,
        .undefined => false,
        .optional => |optional| {
            if (two != .optional) return false;
            const inner = optional orelse return two.optional == null;
            const other = two.optional orelse return false;
            return isEqual(inner.*, other.*);
        },
        .aggregate => |elements| {
            if (two != .aggregate or two.aggregate.len != elements.len) return false;
            for (elements, two.aggregate) |element, other| {
                if (!isEqual(element, other)) return false;
            }
            return true;
        },
        .pointer => |pointer| two == .pointer and isSamePlace(pointer, two.pointer),
        .many => |many| two == .many and isSamePlace(many.array, two.many.array) and many.index == two.many.index,
        .slice => |slice| {
            if (two != .slice or !isSamePlace(slice.array, two.slice.array)) return false;
            return slice.start == two.slice.start and slice.length == two.slice.length;
        },
        .function => |function| two == .function and std.meta.eql(function, two.function),
        .type => |value_type| two == .type and std.meta.eql(value_type, two.type),
    };
}

fn isSamePlace(one: Value.Pointer, two: Value.Pointer) bool {
    return one.root == two.root and std.mem.eql(usize, one.path, two.path);
}

fn shiftLeft(number: types.NumberType, value: i129, amount: i129) i129 {
    const width = findWidth(number);
    if (amount >= width) return 0;
    const mask = (@as(u256, 1) << width) - 1;
    const bits = @as(u256, @bitCast(@as(i256, value))) & mask;
    const shifted = (bits << @intCast(amount)) & mask;
    if (findMinimum(number) < 0 and shifted >> (width - 1) == 1) {
        return @intCast(@as(i256, @intCast(shifted)) - (@as(i256, 1) << width));
    }
    return @intCast(shifted);
}

fn shiftRight(number: types.NumberType, value: i129, amount: i129) i129 {
    if (amount >= findWidth(number)) return if (value < 0) -1 else 0;
    return value >> @intCast(amount);
}

fn findWidth(number: types.NumberType) u8 {
    return switch (number) {
        .i8, .u8 => 8,
        .i16, .u16, .f16 => 16,
        .i32, .u32, .f32 => 32,
        .i64, .u64, .isize, .usize, .f64 => 64,
        .i128, .u128, .f128 => 128,
    };
}

fn findMinimum(number: types.NumberType) i129 {
    return switch (number) {
        .i8 => std.math.minInt(i8),
        .i16 => std.math.minInt(i16),
        .i32 => std.math.minInt(i32),
        .i64, .isize => std.math.minInt(i64),
        .i128 => std.math.minInt(i128),
        .u8, .u16, .u32, .u64, .u128, .usize => 0,
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

fn findMaximum(number: types.NumberType) i129 {
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
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

test "Evaluator.isKnown: knows a local constant computed from constants but not one computed from a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const LIMIT = 4i32\nfn main():\n    var count = 1i32\n    count += 1\n    const known = LIMIT * 2\n    const unknown = count * 2\n    _ = known\n    _ = unknown" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const evaluator = &analyzer.type_checker.evaluator;
    try std.testing.expect(evaluator.isKnown(body[2].kind.constant_declaration.value));
    try std.testing.expect(!evaluator.isKnown(body[3].kind.constant_declaration.value));
}

test "Evaluator.isKnownWithoutCalls: does not know a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> i32: return 1\nfn main():\n    const value = one()\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[1].kind.function_definition.body;
    const evaluator = &analyzer.type_checker.evaluator;
    try std.testing.expect(evaluator.isKnown(body[0].kind.constant_declaration.value));
    try std.testing.expect(!evaluator.isKnownWithoutCalls(body[0].kind.constant_declaration.value));
}

test "Evaluator.evaluateConstant: rejects a constant that depends on itself through a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const LOOP = again()\nfn again() -> i32: return LOOP" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DependencyLoop, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 14 }, analyzer.failure.?.location.?);
}

test "Evaluator.evaluateDefault: evaluates a field default with a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn start() -> i32: return 3\nstruct Point:\n    x: i32 = start()\nconst ORIGIN = Point{}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(1, elements.len);
    try std.testing.expectEqual(Value{ .integer = 3 }, elements[0]);
}

test "readResolution: rejects reading an undefined element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn read() -> i32:\n    var values: [2]i32 = undefined\n    values[0] = 1\n    return values[1]\nconst VALUE = read()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ReadUndefined, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, analyzer.failure.?.location.?);
}

test "findPlace: writes through a pointer to a field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn moved() -> Point:\n    var point = Point{x = 1, y = 2}\n    const pointer = &point.y\n    pointer.* = 5\n    return point\nconst MOVED = moved()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(2, elements.len);
    try std.testing.expectEqual(Value{ .integer = 1 }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 5 }, elements[1]);
}

test "evaluateNegation: rejects negating the most negative value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const LOWEST = -128i8\nconst NEGATED = -LOWEST" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.IntegerOverflow, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 17 }, analyzer.failure.?.location.?);
}

test "evaluateUnary: inverts the bits of an unsigned integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const INVERTED = ~5u8" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const value = loader.modules.items[0].declarations[0].kind.constant_declaration.value;
    try std.testing.expectEqual(Value{ .integer = 250 }, try analyzer.type_checker.evaluator.evaluate(value));
}

test "evaluateBinary: compares arrays element by element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const SAME = [2]i32{1, 2} == [2]i32{1, 2}\nconst DIFFERENT = [2]i32{1, 2} == [2]i32{1, 3}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .boolean = true }, declarations[0].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .boolean = false }, declarations[1].kind.constant_declaration.known.?.*);
}

test "evaluateBinary: takes the right operand of orelse for null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const maybe: ?i32 = null\n    const value = maybe orelse 3\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value = body[1].kind.constant_declaration.value;
    try std.testing.expectEqual(Value{ .integer = 3 }, try analyzer.type_checker.evaluator.evaluate(value));
}

test "evaluateBinary: leaves out the right operand of and when the left decides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn divide(value: i32) -> i32: return 1 / value\nconst SAFE = false and divide(0) == 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .boolean = false }, known);
}

test "computeInteger: rounds a division toward zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const QUOTIENT = -7i32 / 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[0].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = -3 }, known);
}

test "computeInteger: gives a remainder the sign of the left operand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const REMAINDER = -7i32 % 3" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[0].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = -1 }, known);
}

test "computeInteger: gives 0 for the remainder of the most negative value by -1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const REMAINDER = -128i8 % -1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[0].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 0 }, known);
}

test "computeInteger: rejects an overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const DOUBLE = 100i8 * 2" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.IntegerOverflow, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, analyzer.failure.?.location.?);
}

test "computeInteger: rejects a division by zero inside a call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn divide(value: i32) -> i32: return 1 / value\nconst QUOTIENT = divide(0)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DivisionByZero, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, analyzer.failure.?.location.?);
}

test "computeInteger: reports a division by zero in the module where it happens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "math.mn", .data = "fn divide(value: i32) -> i32: return 1 / value" });
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import math\nconst QUOTIENT = math::divide(0)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.DivisionByZero, analyzer.analyze());
    try std.testing.expectEqualStrings("math", analyzer.failure.?.module.?[0]);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 38 }, analyzer.failure.?.location.?);
}

test "evaluateCompositeLiteral: takes missing fields from their defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32 = 7\nconst ORIGIN = Point{x = 1}" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(2, elements.len);
    try std.testing.expectEqual(Value{ .integer = 1 }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 7 }, elements[1]);
}

test "evaluateSlice: slices an array and reads an element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn second() -> i32:\n    const values = [3]i32{1, 2, 3}\n    const tail = values[1..]\n    return tail[0]\nconst SECOND = second()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 2 }, known);
}

test "evaluateSlice: rejects bounds outside the length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn outside() -> []const i32:\n    const values = [3]i32{1, 2, 3}\n    return values[1..4]\nconst OUTSIDE = outside()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.SliceOutOfRange, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 12 }, analyzer.failure.?.location.?);
}

test "evaluateUnwrap: rejects unwrapping null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const maybe: ?i32 = null\n    const value = maybe.?\n    _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const body = loader.modules.items[0].declarations[0].kind.function_definition.body;
    const value = body[1].kind.constant_declaration.value;
    try std.testing.expectError(error.UnwrappedNull, analyzer.type_checker.evaluator.evaluate(value));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, analyzer.type_checker.evaluator.failure.?.location.?);
}

test "evaluateCall: runs a function at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn square(value: i32) -> i32: return value * value\nconst NINE = square(3)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 9 }, known);
}

test "evaluateCall: calls through a pointer to a function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn twice(value: i32) -> i32: return value * 2\nfn apply(function: *fn(i32) -> i32, value: i32) -> i32: return function(value)\nconst APPLIED = apply(&twice, 4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 8 }, known);
}

test "evaluateCall: calls methods with value and pointer receivers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Counter:\n    count: i32\n    fn increment(self: *Self): self.count += 1\n    fn read(self: Self) -> i32: return self.count\nfn counted() -> i32:\n    var counter = Counter{count = 0}\n    counter.increment()\n    counter.increment()\n    return counter.read()\nconst COUNTED = counted()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[4].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 2 }, known);
}

test "evaluateCall: calls a default implementation with a pointer receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\n    fn double(self: *const Self) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side * self.side\nfn make() -> i32:\n    const square = Square{side = 3}\n    return square.double()\nconst DOUBLE = make()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[5].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 18 }, known);
}

test "evaluateCall: rejects an external function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "external fn now() -> i32\nconst NOW = now()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ExternalCall, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 13 }, analyzer.failure.?.location.?);
}

test "evaluateCall: rejects a recursion that does not end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn forever(value: i32) -> i32: return forever(value)\nconst NEVER = forever(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CallDepth, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 39 }, analyzer.failure.?.location.?);
}

test "findCached: evaluates a call with the same arguments once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn slow(count: i32) -> i32:\n    var index = 0i32\n    while index < count: index += 1\n    return index\nconst TOTAL = slow(300000) + slow(300000) + slow(300000) + slow(300000)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 1200000 }, known);
}

test "isSameKey: tells floats apart bit for bit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn same(value: f64) -> f64: return value\nconst POSITIVE = same(0.0f64)\nconst NEGATIVE = same(-0.0f64)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*;
    try std.testing.expect(std.math.signbit(known.float));
}

test "executeTupleDeclaration: takes a tuple apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn swap(pair: [i32, bool]) -> [bool, i32]:\n    const (number, flag) = pair\n    return {flag, number}\nconst SWAPPED = swap({1, true})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(2, elements.len);
    try std.testing.expectEqual(Value{ .boolean = true }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 1 }, elements[1]);
}

test "executeWhile: runs a loop with compound assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn sum(limit: i32) -> i32:\n    var total = 0i32\n    var index = 0i32\n    while index < limit:\n        index += 1\n        total += index\n    return total\nconst TOTAL = sum(4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 10 }, known);
}

test "executeWhile: rejects a loop that does not end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn spin() -> i32:\n    while true: noop\nconst SPIN = spin()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.StepLimit, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 5 }, analyzer.failure.?.location.?);
}

test "executeFor: writes each element through a pointer name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn double(values: [3]i32) -> [3]i32:\n    var result = values\n    for *value in result: value.* = value.* * 2\n    return result\nconst DOUBLED = double({1, 2, 3})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(3, elements.len);
    try std.testing.expectEqual(Value{ .integer = 2 }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 4 }, elements[1]);
    try std.testing.expectEqual(Value{ .integer = 6 }, elements[2]);
}

test "executeFor: leaves an outer loop through its label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(limit: usize) -> usize:\n    var found = 0usize\n    outer: for row in 0..limit:\n        for column in 0..limit:\n            if row * column == 6:\n                found = row\n                break outer\n    return found\nconst FIRST = first(5)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 2 }, known);
}

test "executeFor: runs the else block of a loop that ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn search(limit: usize) -> usize:\n    var result = 0usize\n    for index in 0..limit:\n        if index == 10:\n            result = index\n            break\n    else:\n        result = 99\n    return result\nconst SEARCHED = search(3)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 99 }, known);
}

test "executeFor: takes the elements of each tuple apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn total(pairs: [2][i32, i32]) -> i32:\n    var sum = 0i32\n    for (left, right) in pairs: sum += left * right\n    return sum\nconst TOTAL = total({{1, 2}, {3, 4}})" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 14 }, known);
}

test "makeString: decodes the escapes of a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count(text: []const u8) -> usize:\n    var total = 0usize\n    for _ in text: total += 1\n    return total\nconst LENGTH = count(\"a\\n\\u{e9}\")" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 4 }, known);
}

test "computeFloat: rounds to the precision of the type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const THIRD = 1f32 / 3f32" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const third: f32 = 1.0 / 3.0;
    try std.testing.expectEqual(Value{ .float = third }, loader.modules.items[0].declarations[0].kind.constant_declaration.known.?.*);
}

test "isEqual: compares optionals of optionals by their level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn empty(maybe: ??i32) -> bool: return maybe == null\nconst EMPTY = empty(null)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .boolean = true }, known);
}

test "shiftLeft: discards the bits shifted out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const UNSIGNED = 200u8 << 1\nconst SIGNED = 64i8 << 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 144 }, declarations[0].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = -128 }, declarations[1].kind.constant_declaration.known.?.*);
}

test "shiftRight: keeps the sign of a signed integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const HALF = -8i8 >> 1\nconst ALL = -8i8 >> 10" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = -4 }, declarations[0].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = -1 }, declarations[1].kind.constant_declaration.known.?.*);
}
