const std = @import("std");
const core = @import("core");
const ast = core.ast;
const token = core.token;
const types = core.types;

const Failure = core.Failure;

pub const TypeChecker = struct {
    arena: *std.heap.ArenaAllocator,
    program: ast.Program,
    module_index: usize = 0,
    failure: ?Failure = null,

    pub fn init(arena: *std.heap.ArenaAllocator, program: ast.Program) TypeChecker {
        return .{ .arena = arena, .program = program };
    }

    pub fn check(self: *TypeChecker) TypeError!void {
        for (self.program.types.entries.items) |value_type| {
            switch (value_type) {
                .@"struct" => |struct_type| try self.checkFieldDefaults(struct_type),
                .number, .boolean, .string, .void, .type, .array, .slice, .implementer => {
                    unreachable;
                },
            }
        }
        for (self.program.modules, 0..) |module, index| {
            self.module_index = index;
            for (module.declarations) |declaration| {
                switch (declaration.kind) {
                    .function_definition => |function| {
                        try self.checkParameterDefaults(function.signature.parameters);
                        try self.checkFunction(function);
                    },
                    .function_declaration => |signature| {
                        try self.checkParameterDefaults(signature.parameters);
                        try self.checkExternalFunction(signature, declaration.location);
                    },
                    .constant_declaration,
                    .struct_definition,
                    .trait_definition,
                    .implementation,
                    .import,
                    => {},
                }
            }
        }
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

    fn checkParameterDefaults(self: *TypeChecker, parameters: []ast.TypedName) TypeError!void {
        for (parameters) |*parameter| {
            if (parameter.default) |*default| {
                try self.checkExpression(&.{}, default, ast.extractType(parameter.type));
            }
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

        for (function.body) |*statement| try self.checkStatement(signature, statement);

        const return_type = signature.return_type;
        if (ast.extractType(return_type) == .void) return;
        const last = function.body[function.body.len - 1];
        if (last.kind != .@"return" and !isEndless(last)) {
            return self.fail(return_type.location, error.MissingReturn);
        }
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
                const call = expression.kind == .call;
                if (call and ast.extractResolution(expression.kind.call.callee) == .type) {
                    return self.fail(expression.location, error.ExpectedCall);
                }
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
                const value = &constant.value;
                if (try self.checkDeclaredValue(parameters, constant.type, value) == .void) {
                    return self.fail(value.location, error.VoidConstant);
                }
            },
            .variable_declaration => |*variable| {
                const value = &variable.value;
                const value_type = try self.checkInitialValue(parameters, variable.type, value);
                if (value_type == .void) return self.fail(value.location, error.VoidVariable);
                if (value_type == .type) return self.fail(value.location, error.TypeVariable);
            },
            .assignment => |*assignment| {
                const target_type = try self.inferType(parameters, &assignment.target);
                try self.checkExpression(parameters, &assignment.value, target_type);
            },
            .@"while" => |*loop| {
                try self.checkExpression(parameters, &loop.condition, .boolean);
                for (loop.body) |*body_statement| {
                    try self.checkStatement(signature, body_statement);
                }
            },
        }
    }

    fn checkInitialValue(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        written_type: ?ast.Expression,
        value: *ast.Expression,
    ) TypeError!types.Type {
        if (value.kind != .undefined) {
            return self.checkDeclaredValue(parameters, written_type, value);
        }
        const written = written_type orelse {
            return self.fail(value.location, error.UnknownValueType);
        };
        value.type = ast.extractType(written);
        return value.type.?;
    }

    fn checkExpression(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
        expected: types.Type,
    ) TypeError!void {
        switch (expression.kind) {
            .integer_literal, .float_literal, .boolean_literal, .string_literal => {
                try self.checkLiteral(expression.*, expected);
            },
            .undefined => return self.fail(expression.location, error.UnexpectedUndefined),
            inline .identifier, .path_expression => |name| {
                const value_type = try self.computeValueType(parameters, name.resolution.?);
                if (!isConvertible(value_type, expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .call, .method_call => {
                if (!isConvertible(try self.checkCall(parameters, expression), expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .struct_literal => |literal| {
                const location = expression.location;
                _ = try self.checkConstruction(parameters, location, literal.arguments, expected);
            },
            .array_literal => |literal| {
                const array = switch (expected) {
                    .array => |array| array,
                    .number, .boolean, .string, .void, .type, .@"struct", .slice => {
                        return self.fail(expression.location, error.NotAnArray);
                    },
                    .implementer => unreachable,
                };
                if (literal.elements.len != array.length) {
                    return self.fail(expression.location, error.WrongLength);
                }
                for (literal.elements) |*element| {
                    try self.checkExpression(parameters, element, array.element);
                }
            },
            .array_type, .slice_type => {
                if (expected != .type) return self.fail(expression.location, error.TypeMismatch);
            },
            .slice => {
                if (!isConvertible(try self.inferSliceType(parameters, expression), expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .field_access => {
                const field_type = try self.checkFieldAccess(parameters, expression);
                if (!isConvertible(field_type, expected)) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .@"struct" => unreachable,
        }
        expression.type = expected;
    }

    fn checkCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        if (expression.kind == .method_call) try self.resolveMethodCall(parameters, expression);
        const call = expression.kind.call;
        const value_type = switch (ast.extractResolution(call.callee)) {
            .function => |function| try self.checkFunctionCall(parameters, expression, function),
            .type => |value_type| try self.checkConstruction(
                parameters,
                expression.location,
                call.arguments,
                value_type,
            ),
            .parameter, .constant, .local => unreachable,
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
        const modules = self.program.modules;
        const name = method_call.name;
        const function = switch (ast.findMethod(modules, self.module_index, receiver, name)) {
            .found => |function| function,
            .missing => return self.fail(method_call.name_location, error.UnknownMethod),
            .ambiguous => return self.fail(method_call.name_location, error.AmbiguousMethod),
        };
        const declaration = modules[function.module].declarations[function.declaration];
        if (!ast.hasSelf(ast.extractFunctionSignature(declaration))) {
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
        const callee: ast.Identifier = .{ .name = name, .resolution = .{ .function = function } };
        const call: ast.Call = .{ .callee = .{ .identifier = callee }, .arguments = arguments };
        expression.kind = .{ .call = call };
    }

    fn checkFunctionCall(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
        function: ast.Resolution.Function,
    ) TypeError!types.Type {
        const call = expression.kind.call;
        const declarations = self.program.modules[function.module].declarations;
        const callee = ast.extractFunctionSignature(declarations[function.declaration]);
        if (ast.isMain(callee)) {
            return self.fail(expression.location, error.MainCalled);
        }
        const required = for (callee.parameters, 0..) |parameter, index| {
            if (parameter.default != null) break index;
        } else callee.parameters.len;
        const count = call.arguments.len;
        if (count < required or count > callee.parameters.len) {
            return self.fail(expression.location, error.ArgumentCountMismatch);
        }
        for (call.arguments, callee.parameters[0..count]) |*argument, parameter| {
            if (argument.name != null) return self.fail(argument.location, error.NamedArgument);
            const parameter_type = ast.extractType(parameter.type);
            try self.checkExpression(parameters, &argument.value, parameter_type);
        }
        return ast.extractType(callee.return_type);
    }

    fn checkConstruction(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        arguments: []ast.Argument,
        value_type: types.Type,
    ) TypeError!types.Type {
        const struct_type = switch (value_type) {
            .@"struct" => |struct_type| struct_type,
            .number, .boolean, .string, .void, .type, .array, .slice => {
                return self.fail(location, error.NotAStruct);
            },
            .implementer => unreachable,
        };
        for (arguments, 0..) |*argument, index| {
            const name = argument.name orelse {
                return self.fail(argument.location, error.MissingFieldName);
            };
            const field = findField(struct_type.fields, name) orelse {
                return self.fail(argument.location, error.UnknownField);
            };
            if (ast.findArgument(arguments, name) != index) {
                return self.fail(argument.location, error.RepeatedField);
            }
            try self.checkExpression(parameters, &argument.value, field.type);
        }
        for (struct_type.fields) |field| {
            if (field.default == null and ast.findArgument(arguments, field.name) == null) {
                return self.fail(location, error.MissingField);
            }
        }
        return value_type;
    }

    fn checkFieldAccess(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const access = expression.kind.field_access;
        const struct_type = switch (try self.inferType(parameters, access.value)) {
            .@"struct" => |struct_type| struct_type,
            .number, .boolean, .string, .void, .type, .array, .slice => {
                return self.fail(access.field_location, error.NoFields);
            },
            .implementer => unreachable,
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
            .integer_literal, .float_literal, .boolean_literal, .string_literal => {
                const value_type = try self.computeLiteralType(expression.*);
                try self.checkLiteral(expression.*, value_type);
                expression.type = value_type;
                return value_type;
            },
            inline .identifier, .path_expression => |name| {
                const value_type = try self.computeValueType(parameters, name.resolution.?);
                expression.type = value_type;
                return value_type;
            },
            .call, .method_call => return self.checkCall(parameters, expression),
            .struct_literal => return self.fail(expression.location, error.UnknownValueType),
            .array_literal => |literal| {
                const location = expression.location;
                const value_type = try self.inferArrayType(parameters, location, literal);
                expression.type = value_type;
                return value_type;
            },
            .array_type, .slice_type => {
                expression.type = .type;
                return .type;
            },
            .slice => return self.inferSliceType(parameters, expression),
            .field_access => return self.checkFieldAccess(parameters, expression),
            .@"struct" => unreachable,
        }
    }

    fn inferArrayType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        location: token.Location,
        literal: ast.ArrayLiteral,
    ) TypeError!types.Type {
        if (literal.elements.len == 0) return self.fail(location, error.UnknownValueType);
        const first = &literal.elements[0];
        const element_type = try self.inferType(parameters, first);
        if (element_type == .void) return self.fail(first.location, error.VoidElement);
        for (literal.elements[1..]) |*element| {
            if (!std.meta.eql(try self.inferType(parameters, element), element_type)) {
                return self.fail(element.location, error.MixedElements);
            }
        }
        const allocator = self.arena.allocator();
        const length = literal.elements.len;
        return .{ .array = try self.program.types.addArray(allocator, length, element_type) };
    }

    fn inferSliceType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        expression: *ast.Expression,
    ) TypeError!types.Type {
        const value = expression.kind.slice.value;
        const array = switch (try self.inferType(parameters, value)) {
            .array => |array| array,
            .number, .boolean, .string, .void, .type, .@"struct", .slice => {
                return self.fail(value.location, error.NotAnArray);
            },
            .implementer => unreachable,
        };
        const allocator = self.arena.allocator();
        const constant = !isWritable(value.*);
        const slice = try self.program.types.addSlice(allocator, array.element, constant);
        expression.type = .{ .slice = slice };
        return expression.type.?;
    }

    fn computeValueType(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        resolution: ast.Resolution,
    ) TypeError!types.Type {
        return switch (resolution) {
            .parameter => |index| ast.extractType(parameters[index].type),
            .type => .type,
            .constant => |constant| self.checkConstant(constant),
            .local => |statement| switch (statement.kind) {
                .constant_declaration => |constant| constant.value.type.?,
                .variable_declaration => |variable| variable.value.type.?,
                .noop, .@"return", .discard, .call, .assignment, .@"while" => unreachable,
            },
            .function => unreachable,
        };
    }

    fn checkConstant(self: *TypeChecker, constant: ast.Resolution.Constant) TypeError!types.Type {
        const module = self.program.modules[constant.module];
        const declaration = &module.declarations[constant.declaration].kind.constant_declaration;
        const caller_module_index = self.module_index;
        self.module_index = constant.module;
        defer self.module_index = caller_module_index;
        return self.checkDeclaredValue(&.{}, declaration.type, &declaration.value);
    }

    fn checkDeclaredValue(
        self: *TypeChecker,
        parameters: []const ast.TypedName,
        written_type: ?ast.Expression,
        value: *ast.Expression,
    ) TypeError!types.Type {
        if (value.type) |value_type| return value_type;
        const written = written_type orelse return self.inferType(parameters, value);
        const expected = ast.extractType(written);
        try self.checkExpression(parameters, value, expected);
        return expected;
    }

    fn computeLiteralType(self: *TypeChecker, expression: ast.Expression) TypeError!types.Type {
        return switch (expression.kind) {
            .integer_literal, .float_literal => |literal| {
                const suffix = literal.suffix orelse {
                    return self.fail(expression.location, error.UnknownValueType);
                };
                const number = types.findNumberType(suffix) orelse {
                    return self.fail(expression.location, error.UnknownSuffix);
                };
                return .{ .number = number };
            },
            .boolean_literal => .boolean,
            .string_literal => .string,
            .undefined,
            .identifier,
            .path_expression,
            .call,
            .method_call,
            .struct_literal,
            .array_type,
            .array_literal,
            .slice_type,
            .slice,
            .field_access,
            .@"struct",
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
                const number = try self.expectNumber(expression.location, literal, expected);
                const maximum = computeIntegerMaximum(number) orelse {
                    return self.fail(expression.location, error.TypeMismatch);
                };
                const value = std.fmt.parseInt(u128, literal.text, 0) catch {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                };
                if (value > maximum) {
                    return self.fail(expression.location, error.LiteralOutOfRange);
                }
            },
            .float_literal => |literal| {
                const number = try self.expectNumber(expression.location, literal, expected);
                const fits = switch (number) {
                    .f16 => fitsFloat(f16, literal.text),
                    .f32 => fitsFloat(f32, literal.text),
                    .f64 => fitsFloat(f64, literal.text),
                    .f128 => fitsFloat(f128, literal.text),
                    else => return self.fail(expression.location, error.TypeMismatch),
                };
                if (!fits) return self.fail(expression.location, error.LiteralOutOfRange);
            },
            .boolean_literal => {
                if (expected != .boolean) {
                    return self.fail(expression.location, error.TypeMismatch);
                }
            },
            .string_literal => {
                if (expected != .string) return self.fail(expression.location, error.TypeMismatch);
            },
            .undefined,
            .identifier,
            .path_expression,
            .call,
            .method_call,
            .struct_literal,
            .array_type,
            .array_literal,
            .slice_type,
            .slice,
            .field_access,
            .@"struct",
            => unreachable,
        }
    }

    fn expectNumber(
        self: *TypeChecker,
        location: token.Location,
        literal: token.NumberLiteral,
        expected: types.Type,
    ) TypeError!types.NumberType {
        const number = switch (expected) {
            .number => |number| number,
            .boolean, .string, .void, .type, .@"struct", .array, .slice => {
                return self.fail(location, error.TypeMismatch);
            },
            .implementer => unreachable,
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
    VoidConstant,
    VoidVariable,
    TypeVariable,
    UnexpectedUndefined,
    NotAnArray,
    WrongLength,
    MixedElements,
    VoidElement,
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
    ExpectedCall,
};

fn describeError(type_error: TypeError) []const u8 {
    return switch (type_error) {
        error.OutOfMemory => "out of memory",
        error.TypeMismatch => "value does not match the expected type",
        error.LiteralOutOfRange => "literal out of range for its type",
        error.MissingReturnValue => "missing return value",
        error.UnexpectedReturnValue => "void function cannot return a value",
        error.MissingReturn => "function must end with a return",
        error.MainHasReturnType => "main cannot have a return type",
        error.MainHasParameters => "main cannot have parameters",
        error.MainCalled => "main cannot be called",
        error.MainIsExternal => "main cannot be external",
        error.ArgumentCountMismatch => "wrong number of arguments",
        error.UnusedResult => "call result is unused, discard it with _ =",
        error.DiscardedVoid => "call returns no value to discard",
        error.VoidConstant => "constant cannot have type void",
        error.VoidVariable => "variable cannot have type void",
        error.TypeVariable => "variable cannot hold a type",
        error.UnexpectedUndefined => "undefined can only be the initial value of a variable",
        error.NotAnArray => "type is not an array",
        error.WrongLength => "number of elements does not match the length of the array",
        error.MixedElements => "elements of an array literal have different types",
        error.VoidElement => "array elements cannot have type void",
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
        error.ExpectedCall => "expected a call",
    };
}

fn isEndless(statement: ast.Statement) bool {
    if (statement.kind != .@"while") return false;
    const condition = statement.kind.@"while".condition;
    return condition.kind == .boolean_literal and condition.kind.boolean_literal;
}

fn isConvertible(value_type: types.Type, expected: types.Type) bool {
    if (std.meta.eql(value_type, expected)) return true;
    if (value_type != .slice or expected != .slice) return false;
    const element = value_type.slice.element;
    return expected.slice.constant and std.meta.eql(element, expected.slice.element);
}

fn findField(fields: []const types.Field, name: []const u8) ?types.Field {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

fn isWritable(expression: ast.Expression) bool {
    return switch (expression.kind) {
        .identifier => |identifier| switch (identifier.resolution.?) {
            .local => |statement| statement.kind == .variable_declaration,
            .parameter, .function, .type, .constant => false,
        },
        .field_access => |access| isWritable(access.value.*),
        else => false,
    };
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u8: return 255\nfn two() -> f32: return 2.5\nfn three() -> Bool: return true\nfn four() -> i64: return 1_i64\nfn main(): return" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(box: shapes::Box): _ = box" });
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

test "checkParameterDefaults: rejects a default of another type than its parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn draw(width: i32 = true): _ = width" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 22 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn first(running: Bool) -> i32:\n    while running:\n        return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MissingReturn, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 28 }, type_checker.failure.?.location.?);
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

test "checkStatement: rejects a discarded struct value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Marker\nfn main(): _ = Marker()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.ExpectedCall, type_checker.check());
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

test "checkStatement: rejects a local constant of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn main():\n    const nothing = log()\n    _ = nothing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.VoidConstant, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 21 }, type_checker.failure.?.location.?);
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

test "checkStatement: rejects a variable of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn log(): noop\nfn main():\n    var nothing = log()\n    nothing = log()\n    _ = nothing" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.VoidVariable, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 19 }, type_checker.failure.?.location.?);
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

test "checkStatement: rejects a while condition that is not a Bool" {
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

test "checkExpression: gives a string literal the String type" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn greeting() -> String: return \"hello\"" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    try std.testing.expectEqual(types.Type.string, loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?.type);
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

test "checkExpression: rejects an integer for String" {
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn name() -> String: return 1" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return .(x = 1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return .(x = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAStruct, type_checker.check());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn make() -> Point: return .(x = true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 34 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return [1, 2]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();

    const value = loader.modules.items[0].declarations[0].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqual(2, value.type.?.array.length);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, value.kind.array_literal.elements[1].type);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return [1]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.WrongLength, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 29 }, type_checker.failure.?.location.?);
}

test "checkExpression: rejects an array literal for a type that is not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return [1]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.NotAnArray, type_checker.check());
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> [2]i32: return [1, true]" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 33 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn take(bytes: []u8): _ = bytes\nfn main():\n    const values = [1u8, 2u8]\n    take(values[..])" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 10 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main(): utils::take(true)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(loader.modules.items[0].path, type_checker.failure.?.module.?);
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 24 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn flag(value: Bool): _ = value\nfn main(): flag(1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Card:\n    fn new() -> Card: return Card()\nfn show(card: Card) -> Card: return card.new()" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 5, .column = 47 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "import shapes::Shape\nstruct Square:\n    side: i32\nimpl shapes::Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try type_checker.check();
}

test "resolveMethodCall: rejects a method that a struct and a trait both have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "trait Shape:\n    fn area(self: Self) -> i32\nstruct Square:\n    side: i32\n    fn area(self: Self) -> i32: return self.side\nimpl Shape for Square:\n    fn area(self: Self) -> i32: return self.side\nfn show(square: Square) -> i32: return square.area()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.AmbiguousMethod, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 8, .column = 47 }, type_checker.failure.?.location.?);
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

test "checkFunctionCall: accepts leaving out parameters with defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn draw(width: i32, height: i32 = 1):\n    _ = width\n    _ = height\nfn main(): draw(2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try type_checker.check();
}

test "checkFunctionCall: rejects fewer arguments than the parameters without defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn draw(width: i32, height: i32 = 1):\n    _ = width\n    _ = height\nfn main(): draw()" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.ArgumentCountMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 12 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(y = 2, x = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);
    try type_checker.check();

    const returned = loader.modules.items[0].declarations[1].kind.function_definition.body[0].kind.@"return".?;
    try std.testing.expectEqualStrings("Point", returned.type.?.@"struct".name);
    try std.testing.expectEqual(types.Type{ .number = .i32 }, returned.kind.call.arguments[0].value.type.?);
}

test "checkConstruction: rejects a type that is not a struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> i32: return i32(x = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.NotAStruct, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 26 }, type_checker.failure.?.location.?);
}

test "checkConstruction: rejects an argument without a field name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(1, y = 2)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try std.testing.expectError(error.MissingFieldName, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 34 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(x = 1, z = 2)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(x = 1, x = 2, y = 3)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(x = 1)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nfn make() -> Point: return Point(x = true, y = 2)" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32 = 0\n    y: i32\nfn make() -> Point: return Point(y = 1)" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    const program: ast.Program = .{ .modules = loader.modules.items, .types = &type_registry };
    var type_checker = TypeChecker.init(&arena, program);

    try type_checker.check();
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nstruct Line:\n    start: Point\nfn read(point: Point) -> Bool: return point.x" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    const point = .(x = 1)\n    _ = point" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 19 }, type_checker.failure.?.location.?);
}

test "inferArrayType: takes the type of elements that all have the same type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [1i32, 2i32]\n    _ = values" });
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

test "inferArrayType: rejects an element without a type of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\nfn main():\n    const points = [Point(x = 1), .(x = 2)]\n    _ = points" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 4, .column = 35 }, type_checker.failure.?.location.?);
}

test "inferArrayType: rejects elements of different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [1i32, 2u8]\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.MixedElements, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 27 }, type_checker.failure.?.location.?);
}

test "inferArrayType: rejects elements of type void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn show(): return\nfn main():\n    const values = [show(), show()]\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.VoidElement, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 3, .column = 21 }, type_checker.failure.?.location.?);
}

test "inferArrayType: rejects an empty array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = []\n    _ = values" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.UnknownValueType, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 20 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn main():\n    const values = [1i32, 2i32]\n    const items = values[..]\n    _ = items" });
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

test "inferSliceType: rejects a slice of a value that is not an array" {
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

    try std.testing.expectError(error.NotAnArray, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 2, .column = 19 }, type_checker.failure.?.location.?);
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn one() -> u8: return limits::maximum\nfn main(): noop" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "struct Point:\n    x: i32\n    y: i32\nconst origin = Point(x = 0, y = 0)\nfn make() -> Point: return origin" });
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
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "shapes.mn", .data = "struct Point:\n    x: i32\nconst origin = Point(x = true)" });
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn make() -> shapes::Point: return shapes::origin" });
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

test "checkConstantValue: gives a literal the written type" {
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

test "checkConstantValue: rejects a value of another type than the written type" {
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

test "checkConstantValue: rejects a number without a suffix or a written type" {
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

test "checkConstantValue: checks the written type of a top-level constant" {
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

test "expectNumber: rejects a float suffix on an integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var program_directory = std.testing.tmpDir(.{});
    defer program_directory.cleanup();
    const program_path = try std.fs.path.join(
        arena.allocator(),
        &.{ ".zig-cache", "tmp", &program_directory.sub_path },
    );
    var loader = @import("loader.zig").Loader.init(program_path, program_path);
    try program_directory.dir.writeFile(std.testing.io, .{ .sub_path = "main.mn", .data = "fn value() -> f64: return 1f64" });
    try loader.loadMainModule(&arena, std.testing.io, "main");
    var type_registry: types.Registry = .{};
    var name_resolver = @import("name_resolver.zig").NameResolver.init(&arena, std.testing.io, &loader, &type_registry);
    try name_resolver.resolve();
    var type_checker = TypeChecker.init(&arena, .{ .modules = loader.modules.items, .types = &type_registry });

    try std.testing.expectError(error.TypeMismatch, type_checker.check());
    try std.testing.expectEqual(token.Location{ .row = 1, .column = 27 }, type_checker.failure.?.location.?);
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
