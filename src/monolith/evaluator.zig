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
    returned_error: ?Value.Enumeration = null,
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

    pub fn evaluate(self: *Evaluator, expression: *const ast.Expression) EvaluateError!Value {
        const caller_frame = self.frame;
        self.frame = null;
        defer self.frame = caller_frame;
        return self.expectCaught(expression.location, try self.evaluateExpression(expression));
    }

    pub fn readText(self: *Evaluator, allocator: std.mem.Allocator, location: token.Location, value: Value) EvaluateError![]const u8 {
        const slice = value.slice;
        const elements = self.locate(slice.array).aggregate[slice.start..][0..slice.length];
        const bytes = try allocator.alloc(u8, slice.length);
        for (elements, bytes) |element, *byte| {
            if (element != .integer) return self.fail(location, error.ReadUndefined);
            byte.* = @intCast(element.integer);
        }
        return bytes;
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
        cell.* = try self.copy(try self.expectCaught(value.location, try self.evaluateConverted(value, declared)));
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
        const default = field.default.?.*;
        const value = try self.copy(try self.expectCaught(default.location, try self.evaluateConverted(&default, field.type)));
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
            .enumeration => |enumeration| {
                if (two != .enumeration or two.enumeration.case.tag != enumeration.case.tag) return false;
                const inner = enumeration.value orelse return true;
                return self.isSameKey(inner.*, two.enumeration.value.?.*);
            },
            .failure => |failure| {
                if (two != .failure or two.failure.case.tag != failure.case.tag) return false;
                const inner = failure.value orelse return true;
                return self.isSameKey(inner.*, two.failure.value.?.*);
            },
            .integer, .boolean, .void, .undefined, .pointer, .many, .function, .type => isEqual(one, two),
        };
    }

    fn expectCaught(self: *Evaluator, location: token.Location, value: Value) EvaluateError!Value {
        if (value == .failure) return self.fail(location, error.UncaughtError);
        return value;
    }

    fn isKnownWith(self: *const Evaluator, expression: ast.Expression, calls: bool) bool {
        return switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal, .null => true,
            inline .identifier, .path_expression, .member => |name| self.isKnownResolution(name.resolution, calls),
            .negation, .unwrap, .dereference, .address_of => |operand| self.isKnownWith(operand.*, calls),
            .@"try" => false,
            .range => |range| self.isKnownWith(range.start, calls) and
                (if (range.end) |end| self.isKnownWith(end, calls) else true),
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
            .constant, .function, .type, .case, .builtin => true,
            .local => |statement| {
                if (statement.kind != .constant_declaration) return false;
                return self.isKnownWith(statement.kind.constant_declaration.value, calls);
            },
            .parameter, .element, .typeclass_function, .typeclass_method => false,
        };
    }

    fn areKnown(self: *const Evaluator, arguments: []const ast.Argument, calls: bool) bool {
        for (arguments) |argument| {
            if (!self.isKnownWith(argument.value, calls)) return false;
        }
        return true;
    }

    fn evaluateExpression(self: *Evaluator, expression: *const ast.Expression) EvaluateError!Value {
        if (findFunctionCall(expression)) |call| return self.evaluateCall(expression.location, call);
        if (findStructType(expression)) |struct_type| return self.evaluateStructType(expression.location, struct_type);
        return self.evaluateOtherExpression(expression);
    }

    fn evaluateOtherExpression(self: *Evaluator, expression: *const ast.Expression) EvaluateError!Value {
        const location = expression.location;
        return switch (expression.kind) {
            .integer_literal => |literal| parseInteger(findNumber(expression.type.?), literal.text),
            .float_literal => |literal| .{ .float = parseFloat(findNumber(expression.type.?), literal.text) },
            .boolean_literal => |value| .{ .boolean = value },
            .string_literal => |text| self.makeString(expression.type.?, text),
            .null => .{ .optional = null },
            .undefined => self.makeUndefined(expression.type.?),
            inline .identifier, .path_expression, .member => |name| self.readResolution(location, name.resolution.?),
            .negation => |operand| self.evaluateNegation(expression.*, operand.*),
            .unary => |unary| self.evaluateUnary(expression.*, unary),
            .binary => |binary| self.evaluateBinary(expression.*, binary),
            .composite_literal => |literal| self.evaluateCompositeLiteral(expression.*, literal),
            .index => self.evaluateIndex(expression.*),
            .field_access => self.evaluateFieldAccess(expression),
            .dereference => self.readPlace(location, try self.findPlace(expression.*)),
            .slice => |slice| self.evaluateSlice(expression.*, slice),
            .unwrap => |operand| self.evaluateUnwrap(expression.*, operand.*),
            .@"try" => |operand| self.evaluateTry(operand.*),
            .range => |range| self.evaluateRange(range),
            .address_of => |operand| self.evaluateAddress(operand.*),
            .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => .{
                .type = ast.extractType(expression.*),
            },
            .call => |*call| self.evaluateCallExpression(location, call),
            .method_call => self.fail(location, error.CannotEvaluate),
            .struct_type => unreachable,
        };
    }

    fn evaluateFieldAccess(self: *Evaluator, expression: *const ast.Expression) EvaluateError!Value {
        const access = expression.kind.field_access;
        const container = types.followPointer(access.value.type.?);
        if (container == .array) {
            _ = try self.evaluateExpression(access.value);
            return .{ .integer = container.array.length };
        }
        if (container != .slice) return self.readPlace(expression.location, try self.findPlace(expression.*));
        var slice_value = try self.evaluateExpression(access.value);
        if (slice_value == .pointer) slice_value = try self.readPlace(access.value.location, slice_value.pointer);
        const slice = slice_value.slice;
        if (std.mem.eql(u8, access.field, "length")) return .{ .integer = slice.length };
        return .{ .many = .{ .array = slice.array, .index = slice.start } };
    }

    fn evaluateRange(self: *Evaluator, range: *const ast.Range) EvaluateError!Value {
        const allocator = self.arena.allocator();
        const start = try self.evaluateExpression(&range.start);
        const fields = try allocator.alloc(Value, 2);
        fields[0] = start;
        fields[1] = .{ .optional = null };
        if (range.end) |end_expression| {
            const end = try self.evaluateExpression(&end_expression);
            if (start.integer > end.integer) return self.fail(range.start.location, error.ReversedRange);
            const cell = try allocator.create(Value);
            cell.* = end;
            fields[1] = .{ .optional = cell };
        }
        return .{ .aggregate = fields };
    }

    fn evaluateIndex(self: *Evaluator, expression: ast.Expression) EvaluateError!Value {
        const indexing = expression.kind.index;
        if (indexing.value.type.? == .type) return self.evaluateTypeIndex(indexing);
        return self.readPlace(expression.location, try self.findPlace(expression));
    }

    fn evaluateTypeIndex(self: *Evaluator, indexing: ast.Index) EvaluateError!Value {
        const indexed = (try self.evaluateExpression(indexing.value)).type;
        const position = try self.expectIndex(indexing.index.location, try self.evaluateExpression(indexing.index));
        return .{ .type = indexed.tuple.elements[@intCast(position)] };
    }

    fn evaluateStructType(self: *Evaluator, location: token.Location, struct_type: *const ast.StructType) EvaluateError!Value {
        const created = try self.beginStructType(location, struct_type);
        try self.preparer.?.finishStruct(self.preparer.?.context, struct_type, created, location);
        return .{ .type = created };
    }

    fn beginStructType(self: *Evaluator, location: token.Location, struct_type: *const ast.StructType) EvaluateError!types.Type {
        const preparer = self.preparer orelse return self.fail(location, error.CannotEvaluate);
        const created = try preparer.beginStruct(preparer.context, struct_type);
        if (self.calls.items.len > 0) {
            const innermost = &self.calls.items[self.calls.items.len - 1];
            if (innermost.frame == self.frame) {
                innermost.pending = created;
                try innermost.created.append(self.arena.allocator(), created.@"struct".origin.?);
            }
        }
        return created;
    }

    fn convert(self: *Evaluator, value: Value, value_type: types.Type, expected: types.Type) EvaluateError!Value {
        if (expected == .result and value_type != .result) {
            if (types.isResultError(value_type, expected.result.*)) return .{ .failure = value.enumeration };
            return self.convert(value, value_type, expected.result.value);
        }
        if (countOptionals(value_type) >= countOptionals(expected)) return convertDirectly(value, value_type, expected);
        const cell = try self.arena.allocator().create(Value);
        cell.* = try self.copy(convertDirectly(value, value_type, expected.optional.child));
        return .{ .optional = cell };
    }

    fn evaluateConverted(self: *Evaluator, expression: *const ast.Expression, expected: types.Type) EvaluateError!Value {
        const value = try self.evaluateExpression(expression);
        return self.convert(value, expression.type.?, expected);
    }

    fn readResolution(self: *Evaluator, location: token.Location, resolution: ast.Resolution) EvaluateError!Value {
        const value = switch (resolution) {
            .constant => |constant| (try self.evaluateConstant(constant)).*,
            .function => |function| Value{ .function = function },
            .type => |value_type| Value{ .type = value_type },
            .case => |case| Value{ .enumeration = .{ .case = &case.enumeration.cases[case.index] } },
            .parameter, .local, .element => (try self.findCell(location, resolution)).*,
            .typeclass_function, .typeclass_method, .builtin => return self.fail(location, error.CannotEvaluate),
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
                .constant, .function, .type, .typeclass_function, .typeclass_method, .case, .builtin => unreachable,
            }
        }
        if (resolution == .local and resolution.local.kind == .constant_declaration) {
            const constant = resolution.local.kind.constant_declaration;
            const declared = ast.extractDeclaredType(constant.type, constant.value);
            const cell = try self.arena.allocator().create(Value);
            cell.* = try self.copy(try self.evaluateConverted(&constant.value, declared));
            return cell;
        }
        return self.fail(location, error.CannotEvaluate);
    }

    fn findPlace(self: *Evaluator, expression: ast.Expression) EvaluateError!Value.Pointer {
        const location = expression.location;
        switch (expression.kind) {
            inline .identifier, .path_expression, .member => |name| {
                const resolution = name.resolution.?;
                const value_type = expression.type.?;
                return switch (resolution) {
                    .constant => |constant| .{ .root = try self.evaluateConstant(constant), .root_type = value_type, .path = &.{} },
                    .parameter, .local, .element => .{
                        .root = try self.findCell(location, resolution),
                        .root_type = value_type,
                        .path = &.{},
                    },
                    .function, .type, .typeclass_function, .typeclass_method, .case, .builtin => self.fail(location, error.CannotEvaluate),
                };
            },
            .field_access => |access| {
                const position = findFieldPosition(followPointer(access.value.type.?).@"struct", access.field);
                const base = if (access.value.type.? == .pointer)
                    try self.expectPointer(location, try self.evaluateExpression(access.value))
                else
                    try self.findPlace(access.value.*);
                return self.extendPlace(base, position);
            },
            .index => |indexing| return self.findElement(indexing),
            .dereference => |operand| return self.expectPointer(location, try self.evaluateExpression(operand)),
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
            .@"try",
            .range,
            => {
                const cell = try self.arena.allocator().create(Value);
                cell.* = try self.evaluateExpression(&expression);
                return .{ .root = cell, .root_type = expression.type.?, .path = &.{} };
            },
        }
    }

    fn findElement(self: *Evaluator, indexing: ast.Index) EvaluateError!Value.Pointer {
        const location = indexing.index.location;
        const position = try self.expectIndex(location, try self.evaluateExpression(indexing.index));
        switch (indexing.value.type.?) {
            .array => |array| {
                if (position >= array.length) return self.fail(location, error.IndexOutOfRange);
                return self.extendPlace(try self.findPlace(indexing.value.*), @intCast(position));
            },
            .tuple => return self.extendPlace(try self.findPlace(indexing.value.*), @intCast(position)),
            .slice => {
                const slice = (try self.evaluateExpression(indexing.value)).slice;
                if (position >= slice.length) return self.fail(location, error.IndexOutOfRange);
                return self.extendPlace(slice.array, slice.start + @as(usize, @intCast(position)));
            },
            .pointer => |pointer| {
                const value = try self.evaluateExpression(indexing.value);
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
            .number, .boolean, .@"enum", .void, .type, .@"struct", .optional, .result, .function, .variable, .application => unreachable,
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
        return switch (try self.evaluateExpression(&operand)) {
            .integer => |value| self.expectInRange(expression.location, number, -value),
            .float => |value| .{ .float = -value },
            .boolean, .void, .undefined, .optional, .aggregate, .pointer, .many, .slice, .function, .type, .enumeration, .failure => unreachable,
        };
    }

    fn evaluateUnary(self: *Evaluator, expression: ast.Expression, unary: ast.Unary) EvaluateError!Value {
        const operand = try self.evaluateExpression(unary.operand);
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

    fn evaluateCallExpression(self: *Evaluator, location: token.Location, call: *const ast.Call) EvaluateError!Value {
        const resolution = ast.extractResolution(call.callee);
        if (resolution == .builtin) return self.evaluateBuiltin(location, call.*, resolution.builtin);
        const case = &resolution.case.enumeration.cases[resolution.case.index];
        const cell = try self.arena.allocator().create(Value);
        cell.* = try self.copy(try self.evaluateConverted(&call.arguments[0].value, case.type.?));
        return .{ .enumeration = .{ .case = case, .value = cell } };
    }

    fn evaluateBuiltin(self: *Evaluator, location: token.Location, call: ast.Call, builtin: ast.Builtin) EvaluateError!Value {
        if (builtin == .@"align") return self.fail(location, error.CannotEvaluate);
        if (builtin == .@"error") unreachable;
        const target = (try self.evaluateExpression(&call.arguments[0].value)).type;
        switch (builtin) {
            .size => return .{ .integer = types.findLayout(target).size },
            .alignment => return .{ .integer = types.findLayout(target).alignment },
            .length => return .{ .integer = target.tuple.elements.len },
            .join => {
                const other = (try self.evaluateExpression(&call.arguments[1].value)).type;
                const elements = try std.mem.concat(self.arena.allocator(), types.Type, &.{ target.tuple.elements, other.tuple.elements });
                return .{ .type = .{ .tuple = try self.program.types.addTuple(self.arena.allocator(), elements) } };
            },
            .convert, .truncate => {
                const argument = call.arguments[1].value;
                const value = try self.evaluateExpression(&argument);
                if (value == .undefined) return self.fail(argument.location, error.ReadUndefined);
                return self.convertNumber(location, builtin, value, target.number);
            },
            .cast => return self.castPointer(location, target.pointer, &call.arguments[1].value),
            .@"align", .@"error" => unreachable,
        }
    }

    fn castPointer(self: *Evaluator, location: token.Location, target: *const types.Pointer, argument: *const ast.Expression) EvaluateError!Value {
        const value = try self.evaluateExpression(argument);
        if (value == .undefined) return self.fail(argument.location, error.ReadUndefined);
        if (target.target == .void) return value;
        const pointed = findPointedType(value) orelse return self.fail(location, error.CannotEvaluate);
        if (target.many != (value == .many) or !std.meta.eql(pointed, target.target)) return self.fail(location, error.CannotEvaluate);
        return value;
    }

    fn convertNumber(
        self: *Evaluator,
        location: token.Location,
        builtin: ast.Builtin,
        value: Value,
        target: types.NumberType,
    ) EvaluateError!Value {
        const float_target = isFloatType(target);
        switch (value) {
            .integer => |integer| {
                if (float_target) return .{ .float = roundFloat(target, @floatFromInt(integer)) };
                if (builtin == .truncate) return .{ .integer = truncateInteger(target, integer) };
                if (integer < findMinimum(target) or integer > findMaximum(target)) {
                    return self.fail(location, error.ConversionOutOfRange);
                }
                return value;
            },
            .float => |float| {
                if (float_target) return .{ .float = roundFloat(target, float) };
                if (std.math.isNan(float) or std.math.isInf(float)) return self.fail(location, error.ConversionOutOfRange);
                const truncated = @trunc(float);
                const minimum: f128 = @floatFromInt(findMinimum(target));
                const maximum: f128 = @floatFromInt(findMaximum(target));
                if (truncated < minimum or truncated > maximum) return self.fail(location, error.ConversionOutOfRange);
                return .{ .integer = @intFromFloat(truncated) };
            },
            else => unreachable,
        }
    }

    fn evaluateBinary(self: *Evaluator, expression: ast.Expression, binary: ast.Binary) EvaluateError!Value {
        switch (binary.operator) {
            .combine => {
                const left = try self.evaluateExpression(binary.left);
                const right = try self.evaluateExpression(binary.right);
                if (!isErrorSet(left) or !isErrorSet(right)) return self.fail(expression.location, error.NotErrorSet);
                const allocator = self.arena.allocator();
                return .{ .type = .{ .@"enum" = try self.program.types.addCombined(allocator, left.type.@"enum", right.type.@"enum") } };
            },
            .@"and" => {
                const left = try self.evaluateExpression(binary.left);
                if (!left.boolean) return left;
                return self.evaluateExpression(binary.right);
            },
            .@"or" => {
                const left = try self.evaluateExpression(binary.left);
                if (left.boolean) return left;
                return self.evaluateExpression(binary.right);
            },
            .result => {
                const left = try self.evaluateExpression(binary.left);
                const right = try self.evaluateExpression(binary.right);
                if (!isErrorSet(left)) return self.fail(binary.left.location, error.ExpectedErrorSet);
                const allocator = self.arena.allocator();
                return .{ .type = .{ .result = try self.program.types.addResult(allocator, left.type.@"enum", right.type) } };
            },
            .@"orelse" => {
                const left = try self.evaluateExpression(binary.left);
                const inner = left.optional orelse return self.evaluateExpression(binary.right);
                if (expression.type.? == .optional) return left;
                return inner.*;
            },
            .@"catch" => {
                const left = try self.evaluateExpression(binary.left);
                if (left == .failure) return self.evaluateConverted(binary.right, expression.type.?);
                return left;
            },
            .equal, .not_equal => {
                const left = try self.evaluateExpression(binary.left);
                const right = try self.evaluateExpression(binary.right);
                return .{ .boolean = isEqual(left, right) == (binary.operator == .equal) };
            },
            .less_than, .less_than_or_equal, .greater_than, .greater_than_or_equal => {
                const left = try self.evaluateExpression(binary.left);
                const right = try self.evaluateExpression(binary.right);
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
                const left = try self.evaluateExpression(binary.left);
                const right = try self.evaluateExpression(binary.right);
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
            .combine,
            .result,
            .@"orelse",
            .@"catch",
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
                        const value = try self.evaluateConverted(&literal.elements[position].value, field.type);
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
                    element_value.* = try self.copy(try self.evaluateConverted(&element.value, array.element));
                }
                return .{ .aggregate = elements };
            },
            .tuple => |tuple| {
                const elements = try allocator.alloc(Value, literal.elements.len);
                for (literal.elements, tuple.elements, elements) |element, element_type, *element_value| {
                    element_value.* = try self.copy(try self.evaluateConverted(&element.value, element_type));
                }
                return .{ .aggregate = elements };
            },
            .number, .boolean, .@"enum", .void, .type, .slice, .pointer, .optional, .result, .function, .variable, .application => unreachable,
        }
    }

    fn evaluateSlice(self: *Evaluator, expression: ast.Expression, slice: ast.Slice) EvaluateError!Value {
        const location = expression.location;
        const array: Value.Pointer, const base: usize, const length: usize = switch (slice.value.type.?) {
            .array => |array| .{ try self.findPlace(slice.value.*), 0, @intCast(array.length) },
            .slice => base: {
                const value = (try self.evaluateExpression(slice.value)).slice;
                break :base .{ value.array, value.start, value.length };
            },
            .pointer => |pointer| base: {
                const value = try self.evaluateExpression(slice.value);
                if (!pointer.many) {
                    break :base .{ try self.expectPointer(location, value), 0, @intCast(pointer.target.array.length) };
                }
                if (value.many.index < 0) return self.fail(location, error.SliceOutOfRange);
                const available = self.locate(value.many.array).aggregate.len;
                if (value.many.index > available) return self.fail(location, error.SliceOutOfRange);
                break :base .{ value.many.array, @intCast(value.many.index), available - @as(usize, @intCast(value.many.index)) };
            },
            .number, .boolean, .@"enum", .void, .type, .@"struct", .optional, .result, .tuple, .function, .variable, .application => unreachable,
        };
        const start = try self.evaluateBound(slice.start, 0);
        const end = try self.evaluateBound(slice.end, length);
        if (start > end or end > length) return self.fail(location, error.SliceOutOfRange);
        return .{ .slice = .{ .array = array, .start = base + start, .length = end - start } };
    }

    fn evaluateBound(self: *Evaluator, bound: ?*ast.Expression, fallback: usize) EvaluateError!usize {
        const expression = bound orelse return fallback;
        const value = try self.expectIndex(expression.location, try self.evaluateExpression(expression));
        if (value < 0) return self.fail(expression.location, error.SliceOutOfRange);
        if (value > std.math.maxInt(usize)) return self.fail(expression.location, error.SliceOutOfRange);
        return @intCast(value);
    }

    fn evaluateUnwrap(self: *Evaluator, expression: ast.Expression, operand: ast.Expression) EvaluateError!Value {
        const value = try self.evaluateExpression(&operand);
        const inner = value.optional orelse return self.fail(expression.location, error.UnwrappedNull);
        return inner.*;
    }

    fn evaluateTry(self: *Evaluator, operand: ast.Expression) EvaluateError!Value {
        const value = try self.evaluateExpression(&operand);
        if (value != .failure) return value;
        self.returned_error = value.failure;
        return error.ErrorReturned;
    }

    fn evaluateAddress(self: *Evaluator, operand: ast.Expression) EvaluateError!Value {
        switch (operand.kind) {
            inline .identifier, .path_expression, .member => |name| {
                if (name.resolution.? == .function) return .{ .function = name.resolution.?.function };
            },
            else => {},
        }
        return .{ .pointer = try self.findPlace(operand) };
    }

    fn evaluateCall(self: *Evaluator, location: token.Location, call: *const ast.Call) EvaluateError!Value {
        var frame: Frame = undefined;
        try self.prepareFrame(&frame, location, call);
        const cached = isCacheable(frame.definition);
        if (cached and self.recallPrevious(&frame)) return frame.result;
        try self.enterCall(location, frame.function);
        defer self.depth -= 1;
        const caller_frame = self.frame;
        self.frame = &frame;
        defer self.frame = caller_frame;
        if (cached) try self.activate(&frame);
        defer if (cached) self.deactivate();
        const caller_module_index = self.module_index;
        self.module_index = findFrameModule(&frame);
        defer self.module_index = caller_module_index;
        const flow = try (self.executeBlock(frame.definition.body) catch |execute_error| self.recoverReturnedError(execute_error));
        return self.finishCall(cached, flow);
    }

    fn prepareFrame(self: *Evaluator, frame: *Frame, location: token.Location, call: *const ast.Call) EvaluateError!void {
        const function = try self.findCalledFunction(location, call);
        const definition = try self.findCalledDefinition(location, function);
        frame.* = .{
            .function = function,
            .definition = definition,
            .parameters = try self.evaluateArguments(definition, call),
            .return_type = ast.extractType(definition.signature.return_type),
        };
    }

    fn findCalledFunction(self: *Evaluator, location: token.Location, call: *const ast.Call) EvaluateError!ast.Resolution.Function {
        const resolution = ast.extractResolution(call.callee);
        return switch (resolution) {
            .function => |function| function,
            .parameter, .local, .constant, .element => (try self.readResolution(location, resolution)).function,
            .type, .typeclass_function, .typeclass_method, .case, .builtin => self.fail(location, error.CannotEvaluate),
        };
    }

    fn findCalledDefinition(
        self: *Evaluator,
        location: token.Location,
        function: ast.Resolution.Function,
    ) EvaluateError!*const ast.FunctionDefinition {
        const declaration = ast.findDeclaration(self.program.modules[function.module], function.declaration);
        return switch (declaration.kind) {
            .function_definition => |*definition| definition,
            .function_declaration => self.fail(location, error.ExternalCall),
            .constant_declaration, .struct_definition, .enum_definition, .typeclass_definition, .instance_declaration, .import => unreachable,
        };
    }

    fn evaluateArguments(
        self: *Evaluator,
        definition: *const ast.FunctionDefinition,
        call: *const ast.Call,
    ) EvaluateError![]Value {
        const parameters = try self.arena.allocator().alloc(Value, call.arguments.len);
        for (call.arguments, definition.signature.parameters, parameters) |*argument, *parameter, *parameter_value| {
            const value = try self.evaluateConverted(&argument.value, ast.extractType(parameter.type));
            parameter_value.* = try self.copy(value);
        }
        return parameters;
    }

    fn recallPrevious(self: *const Evaluator, frame: *Frame) bool {
        if (self.findCached(frame.function, frame.parameters)) |result| {
            frame.result = result;
            return true;
        }
        if (self.findPending(frame.function, frame.parameters)) |pending| {
            frame.result = .{ .type = pending };
            return true;
        }
        return false;
    }

    fn enterCall(self: *Evaluator, location: token.Location, function: ast.Resolution.Function) EvaluateError!void {
        try self.step(location);
        if (self.depth >= depth_limit) return self.fail(location, error.CallDepth);
        self.depth += 1;
        errdefer self.depth -= 1;
        if (self.preparer) |preparer| try preparer.prepare(preparer.context, function);
    }

    fn activate(self: *Evaluator, frame: *Frame) EvaluateError!void {
        try self.calls.append(self.arena.allocator(), .{ .function = frame.function, .arguments = frame.parameters, .frame = frame });
    }

    fn deactivate(self: *Evaluator) void {
        _ = self.calls.pop();
    }

    fn finishCall(self: *Evaluator, cached: bool, flow: Flow) EvaluateError!Value {
        const frame = self.frame.?;
        const result: Value = switch (flow) {
            .returned => frame.result,
            .next => .void,
            .broke, .continued => unreachable,
        };
        if (cached) try self.recordOrigin(frame.function, result, self.calls.items[self.calls.items.len - 1].created.items);
        if (cached) try self.cache.append(self.arena.allocator(), .{ .function = frame.function, .arguments = frame.parameters, .result = result });
        return result;
    }

    fn recoverReturnedError(self: *Evaluator, execute_error: EvaluateError) EvaluateError!Flow {
        if (execute_error != error.ErrorReturned) return execute_error;
        const failure = self.returned_error.?;
        self.returned_error = null;
        self.frame.?.result = .{ .failure = failure };
        return .returned;
    }

    fn recordOrigin(
        self: *Evaluator,
        function: ast.Resolution.Function,
        result: Value,
        created: []const *types.Origin,
    ) EvaluateError!void {
        if (result != .type or result.type != .@"struct") return;
        const origin = result.type.@"struct".origin orelse return;
        if (std.mem.findScalar(*types.Origin, created, origin) == null) return;
        const preparer = self.preparer orelse return;
        origin.* = (try preparer.findOrigin(preparer.context, function)) orelse return;
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
        if (containsDefer(statements)) return self.executeDeferringBlock(statements);
        for (statements) |*statement| {
            const flow = try self.executeStatement(statement);
            if (flow != .next) return flow;
        }
        return .next;
    }

    fn executeDeferringBlock(self: *Evaluator, statements: []const ast.Statement) EvaluateError!Flow {
        var deferred: std.ArrayList(ast.Defer) = .empty;
        var flow: Flow = .next;
        for (statements) |*statement| {
            if (statement.kind == .@"defer") {
                try deferred.append(self.arena.allocator(), statement.kind.@"defer");
                continue;
            }
            flow = self.executeStatement(statement) catch |execute_error| {
                if (execute_error == error.ErrorReturned) try self.executeDeferred(deferred.items, true);
                return execute_error;
            };
            if (flow != .next) break;
        }
        if (deferred.items.len == 0) return flow;
        if (flow == .returned) self.frame.?.result = try self.copy(self.frame.?.result);
        const failed = flow == .returned and self.frame.?.result == .failure;
        try self.executeDeferred(deferred.items, failed);
        return flow;
    }

    fn executeDeferred(self: *Evaluator, deferred: []const ast.Defer, failed: bool) EvaluateError!void {
        var index = deferred.len;
        while (index > 0) {
            index -= 1;
            if (deferred[index].on_error and !failed) continue;
            _ = try self.executeStatement(deferred[index].statement);
        }
    }

    fn executeStatement(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        if (!isReturn(statement)) return self.executeOtherStatement(statement);
        const returned = findReturned(statement) orelse return .returned;
        const value = try self.evaluateExpression(returned);
        self.frame.?.result = try self.convert(value, returned.type.?, self.frame.?.return_type);
        return .returned;
    }

    fn executeOtherStatement(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        switch (statement.kind) {
            .noop => return .next,
            .@"return" => unreachable,
            .discard, .call => {
                try self.executeExpressionStatement(statement);
                return .next;
            },
            .constant_declaration, .variable_declaration => {
                try self.executeDeclaration(statement);
                return .next;
            },
            .tuple_declaration => |*declaration| {
                try self.executeTupleDeclaration(statement, declaration);
                return .next;
            },
            .assignment => |*assignment| {
                try self.executeAssignment(assignment);
                return .next;
            },
            .@"if" => return self.executeIf(statement),
            .@"while" => return self.executeWhile(statement),
            .@"for" => return self.executeFor(statement),
            .match => return self.executeMatch(statement),
            .@"defer" => unreachable,
            .@"break" => |*jump| return .{ .broke = jump.loop.? },
            .@"continue" => |*jump| return .{ .continued = jump.loop.? },
        }
    }

    fn executeExpressionStatement(self: *Evaluator, statement: *const ast.Statement) EvaluateError!void {
        const expression = switch (statement.kind) {
            .discard, .call => |*expression| expression,
            else => unreachable,
        };
        if (statement.kind == .discard and expression.kind == .identifier) return;
        _ = try self.evaluateExpression(expression);
    }

    fn executeDeclaration(self: *Evaluator, statement: *const ast.Statement) EvaluateError!void {
        switch (statement.kind) {
            .constant_declaration => |*constant| {
                if (ast.isAlias(constant.*)) return;
                const declared = ast.extractDeclaredType(constant.type, constant.value);
                try self.declareLocal(statement, try self.evaluateConverted(&constant.value, declared));
            },
            .variable_declaration => |*variable| {
                const declared = ast.extractDeclaredType(variable.type, variable.value);
                if (variable.value.kind == .undefined) {
                    try self.declareLocal(statement, try self.makeUndefined(declared));
                } else {
                    try self.declareLocal(statement, try self.evaluateConverted(&variable.value, declared));
                }
            },
            else => unreachable,
        }
    }

    fn executeIf(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const conditional = &statement.kind.@"if";
        if (try self.enterCondition(statement, conditional.condition)) return self.executeBlock(conditional.body);
        const else_body = conditional.else_body orelse return .next;
        return self.executeBlock(else_body);
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
        declaration: *const ast.TupleDeclaration,
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

    fn executeMatch(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const matching = &statement.kind.match;
        const value = matching.value;
        const value_type = value.type.?;
        const place = try self.findPlace(value);
        const matched = try self.readPlace(value.location, place);
        const position = findChosenBranch(matching, value_type, matched);
        const branch = matching.branches[position];
        const name = matching.names[position];
        if (branch.naming != .none and !ast.isDiscardedName(name.name)) {
            const bound = findBranchValue(value_type, name, place, matched);
            try self.declareElement(.{ .statement = statement, .position = position }, bound);
        }
        return self.executeBlock(branch.body);
    }

    fn executeAssignment(self: *Evaluator, assignment: *const ast.Assignment) EvaluateError!void {
        const target = assignment.target;
        const place = try self.findPlace(target);
        const target_type = target.type.?;
        const value = if (assignment.operator) |operator| value: {
            const current = try self.readPlace(target.location, place);
            const right = try self.evaluateExpression(&assignment.value);
            const location = target.location;
            if (current == .many) break :value try self.computePointer(location, operator.operator, current, right);
            const number = findNumber(target_type);
            if (current == .float) break :value Value{ .float = computeFloat(operator.operator, number, current.float, right.float) };
            break :value try self.computeInteger(operator.location, operator.operator, number, current.integer, right.integer);
        } else try self.evaluateConverted(&assignment.value, target_type);
        self.locate(place).* = try self.copy(value);
    }

    fn evaluateCondition(self: *Evaluator, condition: ast.Expression) EvaluateError!bool {
        return (try self.evaluateExpression(&condition)).boolean;
    }

    fn enterCondition(self: *Evaluator, statement: *const ast.Statement, condition: ast.Expression) EvaluateError!bool {
        const names = ast.extractElementNames(statement.*);
        if (names.len == 0) return self.evaluateCondition(condition);
        const element: ast.Resolution.Element = .{ .statement = statement, .position = 0 };
        if (!names[0].pointer) {
            const cell = (try self.evaluateExpression(&condition)).optional orelse return false;
            try self.declareElement(element, cell.*);
            return true;
        }
        const place = try self.findPlace(condition);
        const cell = (try self.readPlace(condition.location, place)).optional orelse return false;
        try self.declareElement(element, .{ .pointer = .{ .root = cell, .root_type = names[0].type.?.pointer.target, .path = &.{} } });
        return true;
    }

    fn executeWhile(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const loop = statement.kind.@"while";
        while (true) {
            try self.step(statement.location);
            if (!try self.enterCondition(statement, loop.condition)) break;
            switch (try self.executeBlock(loop.body)) {
                .next => {},
                .broke => |target| {
                    if (target == statement) return .next;
                    return .{ .broke = target };
                },
                .continued => |target| {
                    if (target != statement) return .{ .continued = target };
                },
                .returned => return .returned,
            }
        }
        const else_body = loop.else_body orelse return .next;
        return self.executeBlock(else_body);
    }

    fn executeFor(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const loop = statement.kind.@"for";
        if (loop.iterator) |iteration| return self.executeIteration(statement, iteration);
        if (ast.isUnrolled(loop)) return self.executeUnrolled(statement);
        switch (loop.sequence) {
            .range => |range| {
                const start = try self.expectIndex(range.start.location, try self.evaluateExpression(&range.start));
                const end: ?i129 = if (range.end) |end_expression|
                    try self.expectIndex(end_expression.location, try self.evaluateExpression(&end_expression))
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
                        .returned => return .returned,
                    }
                }
            },
            .value => |value| {
                const array: Value.Pointer, const start: usize, const length: usize = switch (value.type.?) {
                    .array => |array| .{ try self.findPlace(value), 0, @intCast(array.length) },
                    .slice => sequence: {
                        const slice = (try self.evaluateExpression(&value)).slice;
                        break :sequence .{ slice.array, slice.start, slice.length };
                    },
                    .pointer => |pointer| sequence: {
                        const target = try self.expectPointer(value.location, try self.evaluateExpression(&value));
                        break :sequence .{ target, 0, @intCast(pointer.target.array.length) };
                    },
                    .number, .boolean, .void, .type, .@"struct", .@"enum", .optional, .result, .tuple, .function, .variable, .application => unreachable,
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
                        .returned => return .returned,
                    }
                }
            },
        }
        const else_body = loop.else_body orelse return .next;
        return self.executeBlock(else_body);
    }

    fn executeUnrolled(self: *Evaluator, statement: *const ast.Statement) EvaluateError!Flow {
        const loop = statement.kind.@"for";
        if (loop.expansion_value) |value| _ = try self.executeStatement(value);
        for (loop.expansions) |expansion| {
            switch (try self.executeBlock(expansion)) {
                .next => {},
                .broke => |target| {
                    if (target == statement) return .next;
                    return .{ .broke = target };
                },
                .continued => |target| {
                    if (target != statement) return .{ .continued = target };
                },
                .returned => return .returned,
            }
        }
        const else_body = loop.else_body orelse return .next;
        return self.executeBlock(else_body);
    }

    fn executeIteration(self: *Evaluator, statement: *const ast.Statement, iteration: ast.Iteration) EvaluateError!Flow {
        const loop = statement.kind.@"for";
        const allocator = self.arena.allocator();
        const sequence = loop.sequence.value;
        const cell = try allocator.create(Value);
        cell.* = try self.copy(try self.evaluateExpression(&sequence));
        const holder = try allocator.create(ast.Statement);
        holder.* = .{ .kind = .noop, .location = statement.location };
        try self.frame.?.locals.put(allocator, holder, cell);
        const copy_name = try allocator.create(ast.Expression);
        copy_name.* = .{ .kind = .{ .identifier = .{ .name = "", .resolution = .{ .local = holder } } }, .type = sequence.type.?, .location = statement.location };
        const pointer_type = try self.program.types.addPointer(allocator, .{ .target = sequence.type.?, .many = false, .constant = false });
        const arguments = try allocator.dupe(ast.Argument, &.{.{
            .name = null,
            .value = .{ .kind = .{ .address_of = copy_name }, .type = .{ .pointer = pointer_type }, .location = statement.location },
            .location = statement.location,
        }});
        const signature = ast.extractFunctionSignature(ast.findDeclaration(self.program.modules[iteration.next.module], iteration.next.declaration).*);
        const call: ast.Call = .{
            .callee = .{ .identifier = .{ .name = signature.name, .resolution = .{ .function = iteration.next } } },
            .arguments = arguments,
        };
        while (true) {
            try self.step(statement.location);
            const result = try self.evaluateCall(statement.location, &call);
            const element = result.optional orelse break;
            for (loop.names, 0..) |name, position| {
                if (ast.isDiscardedName(name.name)) continue;
                const key: ast.Resolution.Element = .{ .statement = statement, .position = position };
                try self.declareElement(key, element.aggregate[position]);
            }
            switch (try self.executeBlock(loop.body)) {
                .next => {},
                .broke => |target| {
                    if (target == statement) return .next;
                    return .{ .broke = target };
                },
                .continued => |target| {
                    if (target != statement) return .{ .continued = target };
                },
                .returned => return .returned,
            }
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
            .number, .boolean, .@"enum", .void, .type, .slice, .pointer, .optional, .result, .function, .variable, .application => return .undefined,
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
            inline .enumeration, .failure => |enumeration, tag| {
                const inner = enumeration.value orelse return value;
                const cell = try self.arena.allocator().create(Value);
                cell.* = try self.copy(inner.*);
                return @unionInit(Value, @tagName(tag), .{ .case = enumeration.case, .value = cell });
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
    findOrigin: *const fn (context: *anyopaque, function: ast.Resolution.Function) AnalyzeError!?types.Origin,
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
    NotErrorSet,
    ExpectedErrorSet,
    ConversionOutOfRange,
    ErrorReturned,
    UncaughtError,
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
    created: std.ArrayList(*types.Origin) = .empty,
};

const Frame = struct {
    function: ast.Resolution.Function,
    definition: *const ast.FunctionDefinition,
    parameters: []Value,
    return_type: types.Type,
    result: Value = .void,
    locals: std.AutoHashMapUnmanaged(*const ast.Statement, *Value) = .empty,
    elements: std.AutoHashMapUnmanaged(ast.Resolution.Element, *Value) = .empty,
};

const Flow = union(enum) {
    next,
    broke: *const ast.Statement,
    continued: *const ast.Statement,
    returned,
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
        error.NotErrorSet => "only error sets can be combined",
        error.ExpectedErrorSet => "expected an error set before '!'",
        error.ConversionOutOfRange => "value does not fit the type",
        error.ErrorReturned => "error returned",
        error.UncaughtError => "error is not caught",
        error.StepLimit => "evaluation takes more than 1000000 steps",
        error.CallDepth => "compile-time calls are nested more than 512 deep",
        error.DependencyLoop => "value depends on itself at compile time",
    };
}

fn isVisited(visited: ?*const Visited, identity: usize) bool {
    var current = visited;
    while (current) |node| : (current = node.parent) {
        if (node.identity == identity) return true;
    }
    return false;
}

fn hasWritableReference(value_type: types.Type, visited: ?*const Visited) bool {
    return switch (value_type) {
        .pointer => |pointer| !pointer.constant or hasWritableReference(pointer.target, visited),
        .slice => |slice| !slice.constant or hasWritableReference(slice.element, visited),
        .array => |array| hasWritableReference(array.element, visited),
        .optional => |optional| hasWritableReference(optional.child, visited),
        .result => |result| hasWritableReference(result.value, visited),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (hasWritableReference(element, visited)) return true;
            }
            return false;
        },
        .@"struct" => |struct_type| {
            const identity = @intFromPtr(struct_type.fields.ptr);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (struct_type.fields) |field| {
                if (hasWritableReference(field.type, &node)) return true;
            }
            return false;
        },
        .@"enum" => |enumeration| {
            const identity = @intFromPtr(enumeration);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (enumeration.cases) |case| {
                if (hasWritableReference(case.type orelse continue, &node)) return true;
            }
            return false;
        },
        .number, .boolean, .void, .type, .function, .variable, .application => false,
    };
}

const Visited = struct {
    identity: usize,
    parent: ?*const Visited,
};

fn countOptionals(value_type: types.Type) usize {
    var count: usize = 0;
    var current = value_type;
    while (current == .optional) : (current = current.optional.child) count += 1;
    return count;
}

fn convertDirectly(value: Value, value_type: types.Type, expected: types.Type) Value {
    if (expected != .slice or value_type != .pointer) return value;
    const array = value_type.pointer.target.array;
    return .{ .slice = .{ .array = value.pointer, .start = 0, .length = @intCast(array.length) } };
}

fn isFloatType(number: types.NumberType) bool {
    return number == .f16 or number == .f32 or number == .f64 or number == .f128;
}

fn truncateInteger(number: types.NumberType, value: i129) i129 {
    const bits: u129 = @bitCast(value);
    return switch (number) {
        .u8 => @as(u8, @truncate(bits)),
        .u16 => @as(u16, @truncate(bits)),
        .u32 => @as(u32, @truncate(bits)),
        .u64, .usize => @as(u64, @truncate(bits)),
        .u128 => @as(u128, @truncate(bits)),
        .i8 => @as(i8, @bitCast(@as(u8, @truncate(bits)))),
        .i16 => @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .i32 => @as(i32, @bitCast(@as(u32, @truncate(bits)))),
        .i64, .isize => @as(i64, @bitCast(@as(u64, @truncate(bits)))),
        .i128 => @as(i128, @bitCast(@as(u128, @truncate(bits)))),
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

fn findPointedType(value: Value) ?types.Type {
    return switch (value) {
        .pointer => |pointer| findPlaceType(pointer),
        .many => |many| {
            const array = findPlaceType(many.array) orelse return null;
            if (array != .array) return null;
            return array.array.element;
        },
        else => null,
    };
}

fn findPlaceType(pointer: Value.Pointer) ?types.Type {
    var current = pointer.root_type;
    for (pointer.path) |position| current = findPartType(current, position) orelse return null;
    return current;
}

fn findPartType(container: types.Type, position: usize) ?types.Type {
    return switch (container) {
        .array => |array| array.element,
        .@"struct" => |struct_type| struct_type.fields[position].type,
        .tuple => |tuple| tuple.elements[position],
        else => null,
    };
}

fn findFunctionCall(expression: *const ast.Expression) ?*const ast.Call {
    return switch (expression.kind) {
        .call => |*call| switch (ast.extractResolution(call.callee)) {
            .builtin, .case => null,
            else => call,
        },
        else => null,
    };
}

fn findStructType(expression: *const ast.Expression) ?*const ast.StructType {
    return switch (expression.kind) {
        .struct_type => |struct_type| struct_type,
        else => null,
    };
}

fn isCacheable(definition: *const ast.FunctionDefinition) bool {
    for (definition.signature.parameters) |*parameter| {
        if (hasWritableReference(ast.extractType(parameter.type), null)) return false;
    }
    return true;
}

fn findFrameModule(frame: *const Frame) usize {
    if (frame.definition.default_of) |typeclass| return typeclass.module;
    return frame.function.module;
}

fn containsDefer(statements: []const ast.Statement) bool {
    for (statements) |statement| {
        if (statement.kind == .@"defer") return true;
    }
    return false;
}

fn isReturn(statement: *const ast.Statement) bool {
    return statement.kind == .@"return";
}

fn findReturned(statement: *const ast.Statement) ?*const ast.Expression {
    return switch (statement.kind) {
        .@"return" => |*returned| if (returned.*) |*value| value else null,
        else => unreachable,
    };
}

fn isErrorSet(value: Value) bool {
    return value.type == .@"enum" and value.type.@"enum".kind == .error_set;
}

fn findChosenBranch(matching: *const ast.Match, value_type: types.Type, matched: Value) usize {
    for (matching.branches, 0..) |branch, position| {
        if (branch.cases.len == 0) return position;
        for (branch.cases) |case| {
            if (isChosenCase(case, value_type, matched)) return position;
        }
    }
    unreachable;
}

fn isChosenCase(case: ast.BranchCase, value_type: types.Type, matched: Value) bool {
    return switch (case.kind) {
        .case => {
            if (value_type == .result) {
                if (matched != .failure) return false;
                return value_type.result.error_set.cases[case.index.?].tag == matched.failure.case.tag;
            }
            return value_type.@"enum".cases[case.index.?].tag == matched.enumeration.case.tag;
        },
        .value => if (value_type == .result) matched != .failure else matched.optional != null,
        .null => matched.optional == null,
        .integer => case.minimum <= matched.integer and matched.integer <= case.maximum,
    };
}

fn findBranchValue(value_type: types.Type, name: ast.ElementName, place: Value.Pointer, matched: Value) Value {
    if (value_type == .result and matched != .failure) {
        if (name.pointer) return .{ .pointer = place };
        return matched;
    }
    const cell = switch (matched) {
        .enumeration, .failure => |enumeration| enumeration.value.?,
        .optional => |optional| optional.?,
        else => unreachable,
    };
    if (name.pointer) return .{ .pointer = .{ .root = cell, .root_type = name.type.?.pointer.target, .path = &.{} } };
    return cell.*;
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
        .result => |result| findNumber(result.value),
        .boolean, .void, .type, .@"struct", .@"enum", .array, .slice, .pointer, .tuple, .function, .variable, .application => unreachable,
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
        .combine,
        .result,
        .@"orelse",
        .@"catch",
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
        .boolean, .void, .undefined, .optional, .aggregate, .pointer, .slice, .function, .type, .enumeration, .failure => unreachable,
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
        .combine,
        .result,
        .@"orelse",
        .@"catch",
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
        .enumeration => |enumeration| {
            if (two != .enumeration or two.enumeration.case.tag != enumeration.case.tag) return false;
            const inner = enumeration.value orelse return true;
            return isEqual(inner.*, two.enumeration.value.?.*);
        },
        .failure => |failure| {
            if (two != .failure or two.failure.case.tag != failure.case.tag) return false;
            const inner = failure.value orelse return true;
            return isEqual(inner.*, two.failure.value.?.*);
        },
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

test "Evaluator.evaluateConstant: rejects an error that is not caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_file\nfn digit(text: u8) -> ParseError!u8:\n    if text < 48: return ParseError::bad_digit(text)\n    return text - 48\nconst VALUE = digit(20)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.UncaughtError, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 9, .column = 15 }, analyzer.failure.?.location.?);
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
    try std.testing.expectEqual(Value{ .integer = 250 }, try analyzer.type_checker.evaluator.evaluate(&value));
}

test "evaluateFieldAccess: reads the pointer and the length of a slice at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn second(values: []const u8) -> u8:\n    const pointer = values.pointer\n    return pointer[1] + mn::convert(u8, values.length)\nconst VALUES: [3]u8 = {1, 2, 3}\nconst SECOND = second(&VALUES)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 5 }, declarations[3].kind.constant_declaration.known.?.*);
}

test "evaluateFieldAccess: gives the length of arrays from their types without reading them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "const primes: [_]i32 = {2, 3, 5}\nconst COUNT = primes.length\nfn sizes() -> usize:\n    var buffer: [64]u8 = undefined\n    const pointer = &buffer\n    var other: [buffer.length]u16 = undefined\n    other[0] = 1\n    buffer[0] = 2\n    return buffer.length + pointer.length + other.length\nconst SIZES = sizes()\nfn twice(comptime count: usize) -> usize: return count * 2\nfn local() -> usize:\n    var buffer: [8]u8 = undefined\n    buffer[0] = 1\n    return twice(buffer.length)\nconst LOCAL = local()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[1].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 192 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 16 }, declarations[6].kind.constant_declaration.known.?.*);
}

test "evaluateFieldAccess: runs a call that gives an array before taking its length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn bump(count: *u8) -> [2]u8:\n    count.* += 1\n    return {0, 0}\nfn run() -> u8:\n    var count: u8 = 0\n    const length = bump(&count).length\n    return count + mn::convert(u8, length)\nconst RUN = run()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(Value{ .integer = 3 }, loader.modules.items[0].declarations[3].kind.constant_declaration.known.?.*);
}

test "evaluateCall: evaluates a call with any arguments at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count(values: any) -> usize: return values.length\nconst ARRAY: [4]u8 = {1, 2, 3, 4}\nconst TOTAL = count(\"abc\") + count(ARRAY)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    try std.testing.expectEqual(Value{ .integer = 7 }, loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*);
}

test "evaluateBuiltin: converts and truncates numbers at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst COUNT: u16 = 300\nconst LARGE: i32 = 300\nconst SMALL: u8 = 200\nconst FRACTION: f64 = -2.7\nconst HUGE: f32 = 100000.0\nconst WIDE = mn::convert(i64, COUNT)\nconst FLOAT = mn::convert(f32, LARGE)\nconst WHOLE = mn::convert(i32, FRACTION)\nconst LOW = mn::truncate(u8, LARGE)\nconst NEGATIVE = mn::truncate(i8, SMALL)\nconst INFINITE = mn::convert(f16, HUGE)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 300 }, declarations[6].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .float = 300 }, declarations[7].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = -2 }, declarations[8].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 44 }, declarations[9].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = -56 }, declarations[10].kind.constant_declaration.known.?.*);
    try std.testing.expect(std.math.isInf(declarations[11].kind.constant_declaration.known.?.float));
}

test "evaluateBuiltin: rejects a float that the integer type cannot hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nconst LARGE: f32 = 300.0\nconst SMALL = mn::convert(u8, LARGE)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ConversionOutOfRange, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 15 }, analyzer.failure.?.location.?);
}

test "castPointer: casts a pointer through a pointer to void and back at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn round(value: i32) -> i32:\n    var copy = value\n    const hidden: *void = &copy\n    const back = mn::cast(*i32, hidden)\n    back.* += 1\n    return copy\nconst ROUND = round(4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 5 }, declarations[2].kind.constant_declaration.known.?.*);
}

test "castPointer: rejects a cast to another target type at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn reinterpret(value: i32) -> u8:\n    var copy = value\n    const bytes = mn::cast(*u8, &copy)\n    return bytes.*\nconst BYTE = reinterpret(4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 19 }, analyzer.failure.?.location.?);
}

test "evaluateBuiltin: rejects aligning a pointer at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn move(values: []const u8) -> usize:\n    const aligned = mn::align(values.pointer, 4)\n    _ = aligned\n    return 0\nconst VALUES: [2]u8 = {1, 2}\nconst MOVED = move(&VALUES)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.CannotEvaluate, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 21 }, analyzer.failure.?.location.?);
}

test "evaluateBinary: orders the cases of a combined error set by the declarations of its sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error Alpha:\n    first\nerror Beta:\n    second\n    third\nfn convert(value: Beta || Alpha) -> Alpha || Beta: return value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const signature = loader.modules.items[0].declarations[2].kind.function_definition.signature;
    const combined = ast.extractType(signature.parameters[0].type).@"enum";
    try std.testing.expectEqual(combined, ast.extractType(signature.return_type).@"enum");
    try std.testing.expectEqualStrings("first", combined.cases[0].name);
    try std.testing.expectEqualStrings("second", combined.cases[1].name);
    try std.testing.expectEqualStrings("third", combined.cases[2].name);
    try std.testing.expectEqualStrings("Alpha_or_Beta", combined.name);
}

test "evaluateBinary: rejects combining types that are not error sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(value: i32 || bool): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotErrorSet, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 16 }, analyzer.failure.?.location.?);
}
test "evaluateBinary: rejects combining enums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Alpha:\n    first\nenum Beta:\n    second\nfn take(value: Alpha || Beta): _ = value" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.NotErrorSet, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 16 }, analyzer.failure.?.location.?);
}

test "evaluateBinary: rejects a result of a type that is not an error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn f() -> i32!u8: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);

    try std.testing.expectError(error.ExpectedErrorSet, analyzer.analyze());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 11 }, analyzer.failure.?.location.?);
}

test "evaluateBinary: evaluates the fallback of catch only for an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_file\nfn digit(text: u8) -> ParseError!u8:\n    if text < 48: return ParseError::bad_digit(text)\n    return text - 48\nfn broken(zero: u8) -> u8: return 1 / zero\nconst VALUE = digit(50) catch broken(0)\nconst FALLBACK = digit(20) catch 7" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 7 }, declarations[5].kind.constant_declaration.known.?.*);
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
    try std.testing.expectEqual(Value{ .integer = 3 }, try analyzer.type_checker.evaluator.evaluate(&value));
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
    try std.testing.expectError(error.UnwrappedNull, analyzer.type_checker.evaluator.evaluate(&value));
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, analyzer.type_checker.evaluator.failure.?.location.?);
}

test "evaluateTry: returns the error of a result from the function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_file\nfn digit(text: u8) -> ParseError!u8:\n    if text < 48: return ParseError::bad_digit(text)\n    return text - 48\nfn total(one: u8, two: u8) -> ParseError || FileError!u8: return try digit(one) + try digit(two)\nconst GOOD = total(49, 50) catch 0\nconst BAD = total(49, 20) catch 99" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 99 }, declarations[5].kind.constant_declaration.known.?.*);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "typeclass Shape(type T):\n    fn area(self: T) -> i32\n    fn double(self: *const T) -> i32: return self.area() * 2\nstruct Square:\n    side: i32\ninstance Shape(Square):\n    fn area(self: Square) -> i32: return self.side * self.side\nfn make() -> i32:\n    const square = Square{side = 3}\n    return square.double()\nconst DOUBLE = make()" });
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

test "recordOrigin: gives the origin only to the struct that a call returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn Box(type T) -> type:\n    return struct:\n        value: T\nfn Pair(type T) -> type:\n    const Inner = struct:\n        value: T\n    return [2]Inner\nfn take(box: Box(i32), pair: Pair(i32)):\n    _ = box\n    _ = pair" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const parameters = loader.modules.items[0].declarations[2].kind.function_definition.signature.parameters;
    const box = ast.extractType(parameters[0].type).@"struct";
    try std.testing.expectEqual(ast.Resolution.Function{ .module = 0, .declaration = 0 }, box.origin.?.function.?);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, box.origin.?.arguments[0]);
    const inner = ast.extractType(parameters[1].type).array.element.@"struct";
    try std.testing.expectEqual(null, inner.origin.?.function);
}

test "executeDeferringBlock: runs deferred statements in reverse order after the returned value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn run(total: *i32) -> i32:\n    defer total.* = total.* * 10 + 1\n    defer total.* = total.* * 10 + 2\n    total.* = 3\n    return total.*\nfn check() -> [2]i32:\n    var total: i32 = 0\n    const returned = run(&total)\n    return {returned, total}\nconst ORDER = check()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const elements = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(Value{ .integer = 3 }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 321 }, elements[1]);
}

test "executeDeferringBlock: runs errdefer only when the function returns an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error Failure:\n    bad\nfn inner(fail: bool) -> Failure!i32:\n    if fail: return Failure::bad\n    return 1\nfn step(total: *i32, fail: bool, tried: bool) -> Failure!i32:\n    errdefer total.* += 100\n    defer total.* += 1\n    if tried: return try inner(fail) + 1\n    if fail: return Failure::bad\n    return 0\nfn tally(fail: bool, tried: bool) -> i32:\n    var total: i32 = 0\n    const value = step(&total, fail, tried) catch 7\n    return total * 10 + value\nconst SUCCESS = tally(false, false)\nconst FAILURE = tally(true, false)\nconst TRIED = tally(true, true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 10 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 1017 }, declarations[5].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 1017 }, declarations[6].kind.constant_declaration.known.?.*);
}

test "executeDeferringBlock: runs the deferred statements of a loop body on break and continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn count() -> i32:\n    var total: i32 = 0\n    var index: i32 = 0\n    while index < 5:\n        defer total += 1\n        index += 1\n        if index == 2: continue\n        if index == 4: break\n    return total * 10 + index\nconst COUNT = count()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[1].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 44 }, known);
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

test "executeMatch: runs the branch of the case and binds its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token:\n    number: i64\n    flag: bool\n    end\nfn score(token: Token) -> i64:\n    match token:\n        case number(digits): return digits\n        case flag(on):\n            if on: return 1\n            return 2\n        case end: return 3\nconst NUMBER = score(Token::number(40))\nconst FLAG = score(Token::flag(false))\nconst END = score(Token::end)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 40 }, declarations[2].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[4].kind.constant_declaration.known.?.*);
}

test "executeMatch: writes through a pointer to the value of a case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token:\n    number: i64\n    flag: bool\n    end\nfn bump(value: Token) -> Token:\n    var token = value\n    match token:\n        case number(*digits): digits.* += 1\n        else: noop\n    return token\nconst BUMPED = bump(Token::number(1))" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const known = loader.modules.items[0].declarations[2].kind.constant_declaration.known.?.*;
    try std.testing.expectEqual(Value{ .integer = 2 }, known.enumeration.value.?.*);
}

test "executeMatch: runs the else branch and a branch that names a case through its error set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nerror FileError:\n    missing_end\nfn code(failure: ParseError || FileError) -> u8:\n    match failure:\n        case FileError::missing_end: return 2\n        else: return 1\nconst PARSE = code(ParseError::missing_end)\nconst FILE = code(FileError::missing_end)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 1 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[4].kind.constant_declaration.known.?.*);
}

test "executeMatch: runs a match in an instance of a function with a type parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "enum Token:\n    number: i64\n    flag: bool\n    end\nfn pick(type T, token: Token, one: T, two: T) -> T:\n    match token:\n        case number(digits):\n            if digits > 0: return one\n            return two\n        else: return two\nconst PICKED = pick(i32, Token::number(1), 3, 4)\nconst OTHER = pick(bool, Token::end, true, false)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[2].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .boolean = false }, declarations[3].kind.constant_declaration.known.?.*);
}

test "executeMatch: runs the branch of the error or the value of a result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing_end\n    bad_digit: u8\nfn parse(text: u8) -> ParseError!i64:\n    if text == 0: return ParseError::missing_end\n    if text == 1: return ParseError::bad_digit(7)\n    return 40\nfn score(text: u8) -> i64:\n    match parse(text):\n        case i64 as value: return value + 2\n        case bad_digit(digit):\n            if digit == 7: return 5\n            return 6\n        case missing_end: return 1\nconst VALUE = score(2)\nconst BAD = score(1)\nconst MISSING = score(0)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 42 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 5 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 1 }, declarations[5].kind.constant_declaration.known.?.*);
}

test "executeMatch: takes the value of a result whose type is a type constructor applied to a type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "error ParseError:\n    missing\nfn Box(type T) -> type:\n    return struct:\n        value: T\nfn parse(ready: bool) -> ParseError!Box(i32):\n    if ready: return Box(i32){value = 3}\n    return ParseError::missing\nfn score(ready: bool) -> i32:\n    match parse(ready):\n        case Box(i32) as box: return box.value\n        case missing: return 0\nfn check(ready: bool) -> i32:\n    match parse(ready):\n        case Box(i32): return 1\n        case missing: return 0\nconst VALUE = score(true)\nconst MISSING = score(false)\nconst CHECKED = check(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[5].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 0 }, declarations[6].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 1 }, declarations[7].kind.constant_declaration.known.?.*);
}

test "executeMatch: runs the branch of an optional and writes through a pointer to its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn bump(start: ?i64) -> i64:\n    var value = start\n    match value:\n        case i64 as *count: count.* += 1\n        case null: return 0\n    return value.?\nconst BUMPED = bump(4)\nconst NOTHING = bump(null)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 5 }, declarations[1].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 0 }, declarations[2].kind.constant_declaration.known.?.*);
}

test "executeMatch: runs the branch whose value or range holds an integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn kind(value: i16) -> u8:\n    match value:\n        case 0: return 1\n        case 3..10, 20: return 2\n        case 200..: return 3\n        case -5..0: return 5\n        else: return 4\nconst ZERO = kind(0)\nconst NINE = kind(9)\nconst TEN = kind(10)\nconst TWENTY = kind(20)\nconst LAST = kind(32767)\nconst NEGATIVE = kind(-1)\nconst LOW = kind(-6)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 1 }, declarations[1].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[2].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 4 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 3 }, declarations[5].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 5 }, declarations[6].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 4 }, declarations[7].kind.constant_declaration.known.?.*);
}

test "executeUnrolled: runs the block once for each element of a tuple with its own type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn total(values: mn::Tuple) -> usize:\n    var sum: usize = 0\n    for value in values: sum += mn::convert(usize, value)\n    return sum\nfn run() -> usize:\n    const small: u8 = 4\n    const large: u64 = 5\n    const middle: i32 = 3\n    return total({middle, small, large})\nconst RUN = run()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 12 }, declarations[3].kind.constant_declaration.known.?.*);
}

test "executeUnrolled: breaks, continues and runs the else block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nfn count(values: mn::Tuple, limit: usize) -> usize:\n    var seen: usize = 0\n    for value in values:\n        _ = value\n        seen += 1\n        if seen == 1: continue\n        if seen == limit: break\n        seen += 10\n    else: seen += 100\n    return seen\nfn run(limit: usize) -> usize:\n    const one: i32 = 1\n    const flag = true\n    return count({one, flag, one}, limit)\nconst BROKEN = run(2)\nconst FINISHED = run(5)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[3].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 123 }, declarations[4].kind.constant_declaration.known.?.*);
}

test "executeUnrolled: points into the elements of a tuple and takes them apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn bump() -> [i32, u8]:\n    var pair: [i32, u8] = {1, 2}\n    for *value in pair: value.* += 1\n    return pair\nfn add() -> i32:\n    var sum: i32 = 0\n    const first: [i32, i32] = {1, 2}\n    const second: [i32, i32] = {3, 4}\n    for (left, right) in {first, second}: sum += left * right\n    return sum\nconst BUMPED = bump()\nconst ADDED = add()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    const bumped = declarations[2].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(Value{ .integer = 2 }, bumped[0]);
    try std.testing.expectEqual(Value{ .integer = 3 }, bumped[1]);
    try std.testing.expectEqual(Value{ .integer = 14 }, declarations[3].kind.constant_declaration.known.?.*);
}

test "executeIteration: calls next on a copy of the iterator until it gives null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nstruct Countdown:\n    count: u32\ninstance mn::Iterator(Countdown):\n    fn Element() -> type: return [u32]\n    fn next(iterator: *Countdown) -> ?Element():\n        if iterator.count == 0: return null\n        iterator.count -= 1\n        return {iterator.count + 1}\nfn total(start: u32) -> [2]u32:\n    var sum: u32 = 0\n    var countdown = Countdown{count = start}\n    for value in countdown: sum += value\n    countdown.count += 1\n    return {sum, countdown.count}\nfn indexes(count: usize) -> usize:\n    var sum: usize = 0\n    const range = 2..count\n    for (index) in range:\n        if index == 4: continue\n        sum += index\n    return sum\nconst TOTAL = total(3)\nconst INDEXES = indexes(6)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    const elements = declarations[7].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(Value{ .integer = 6 }, elements[0]);
    try std.testing.expectEqual(Value{ .integer = 4 }, elements[1]);
    try std.testing.expectEqual(Value{ .integer = 10 }, declarations[8].kind.constant_declaration.known.?.*);
}

test "executeIteration: zips iterators until the shortest ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::Zip\nfn sum(cards: []u32, count: usize) -> u32:\n    var total: u32 = 0\n    for (card, index) in Zip::zip({cards, 0..count}):\n        total += card * mn::convert(u32, index)\n    return total\nfn run(count: usize) -> u32:\n    var cards = [3]u32{1, 2, 3}\n    return sum(cards[..], count)\nconst ALL = run(5)\nconst SHORT = run(2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 8 }, declarations[4].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 2 }, declarations[5].kind.constant_declaration.known.?.*);
}

test "executeIteration: zips a read-only slice and a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::Zip\nfn sum(cards: []const u32) -> u32:\n    var total: u32 = 0\n    for (card, index) in Zip::zip({cards, 0..}):\n        total += card * mn::convert(u32, index)\n    return total\nconst CARDS = [3]u32{1, 2, 3}\nconst SUM = sum(CARDS[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 8 }, declarations[4].kind.constant_declaration.known.?.*);
}

test "executeIteration: takes the first element of a read-only slice and shortens it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::Iterator\nfn take() -> [u32, u32]:\n    const cards = [3]u32{7, 8, 9}\n    var rest = cards[..]\n    const first = Iterator::next(&rest)\n    const second = Iterator::next(&rest)\n    return {first.?[0], second.?[0]}\nconst TAKEN = take()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const taken = loader.modules.items[0].declarations[3].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(Value{ .integer = 7 }, taken[0]);
    try std.testing.expectEqual(Value{ .integer = 8 }, taken[1]);
}

test "executeIteration: takes the first element of a slice and shortens it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn\nimport mn::Iterator\nfn take() -> [u32, u32]:\n    var cards = [3]u32{7, 8, 9}\n    var rest = cards[..]\n    const first = Iterator::next(&rest)\n    const second = Iterator::next(&rest)\n    return {first.?[0], second.?[0]}\nconst TAKEN = take()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const taken = loader.modules.items[0].declarations[3].kind.constant_declaration.known.?.aggregate;
    try std.testing.expectEqual(Value{ .integer = 7 }, taken[0]);
    try std.testing.expectEqual(Value{ .integer = 8 }, taken[1]);
}

test "enterCondition: binds the value of an optional in an if and runs the else for null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn pick(value: ?i64) -> i64:\n    if value as found: return found * 2\n    else: return 1\nconst SOME = pick(4)\nconst NONE = pick(null)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 8 }, declarations[1].kind.constant_declaration.known.?.*);
    try std.testing.expectEqual(Value{ .integer = 1 }, declarations[2].kind.constant_declaration.known.?.*);
}

test "enterCondition: writes through a pointer to the value of an optional in an if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn bump(start: ?i64) -> i64:\n    var value = start\n    if value as *count: count.* += 10\n    return value orelse 0\nconst BUMPED = bump(1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 11 }, declarations[1].kind.constant_declaration.known.?.*);
}

test "enterCondition: evaluates the optional of a while loop before each run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn next(count: *u8) -> ?u8:\n    if count.* == 0: return null\n    count.* -= 1\n    return count.*\nfn total(start: u8) -> u8:\n    var count = start\n    var sum: u8 = 0\n    while next(&count) as value: sum += value\n    else: sum += 10\n    return sum\nconst TOTAL = total(4)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expectEqual(Value{ .integer = 16 }, declarations[2].kind.constant_declaration.known.?.*);
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

test "executeFor: compares slices with mn::memory::equal at compile time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, ".");
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import mn::memory\nconst BUFFER: [4]u8 = {'y', 'e', 's', '\\n'}\nconst ONE: [3]u8 = {1, 2, 3}\nconst TWO: [3]u8 = {1, 2, 3}\nconst THREE: [3]u8 = {1, 2, 4}\nconst LITERAL = memory::equal(&BUFFER, \"yes\\n\")\nconst UNEQUAL = memory::equal(\"yes\", \"yet\")\nconst SHORTER = memory::equal(\"ye\", \"yes\")\nconst EMPTY = memory::equal(\"\", \"\")\nconst ARRAYS = memory::equal(&ONE, &TWO)\nconst DIFFERENT = memory::equal(&ONE, &THREE)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var analyzer = @import("analyzer.zig").Analyzer.init(&arena, std.testing.io, &loader, &type_registry);
    _ = try analyzer.analyze();

    const declarations = loader.modules.items[0].declarations;
    try std.testing.expect(declarations[5].kind.constant_declaration.known.?.boolean == true);
    try std.testing.expect(declarations[6].kind.constant_declaration.known.?.boolean == false);
    try std.testing.expect(declarations[7].kind.constant_declaration.known.?.boolean == false);
    try std.testing.expect(declarations[8].kind.constant_declaration.known.?.boolean == true);
    try std.testing.expect(declarations[9].kind.constant_declaration.known.?.boolean == true);
    try std.testing.expect(declarations[10].kind.constant_declaration.known.?.boolean == false);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(limit: usize) -> usize:\n    var found = 0usize\n    @outer for row in 0..limit:\n        for column in 0..limit:\n            if row * column == 6:\n                found = row\n                break @outer\n    return found\nconst FIRST = first(5)" });
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
