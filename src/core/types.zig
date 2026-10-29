const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

const Value = @import("value.zig").Value;

pub const Type = union(enum) {
    number: NumberType,
    boolean,
    void,
    type,
    @"struct": Struct,
    @"enum": *const Enum,
    array: *const Array,
    slice: *const Slice,
    pointer: *const Pointer,
    optional: *const Optional,
    result: *const Result,
    tuple: *const Tuple,
    function: *const Function,
    variable: Variable,
    application: *const Application,
};

pub const NumberType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    f16,
    f32,
    f64,
    f128,
};

pub const Struct = struct {
    module: usize,
    name: []const u8,
    external: bool = false,
    fields: []const Field,
    origin: ?*Origin = null,
};

pub const Enum = struct {
    module: usize,
    path: []const []const u8 = &.{},
    position: usize = 0,
    name: []const u8,
    kind: EnumKind = .enumeration,
    cases: []const Case = &.{},
    parts: []const *const Enum = &.{},
};

pub const EnumKind = enum {
    enumeration,
    error_set,
};

pub const Case = struct {
    name: []const u8,
    type: ?Type,
    declaring: *const Enum,
    tag: usize,
    location: token.Location,
};

pub const Origin = struct {
    function: ?ast.Resolution.Function = null,
    arguments: []const Type = &.{},
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    default: ?*ast.Expression = null,
    default_value: ?*?Value = null,
    location: token.Location,
};

pub const Array = struct {
    length: u64,
    element: Type,
    variables: bool = false,
};

pub const Slice = struct {
    element: Type,
    constant: bool,
    variables: bool = false,
};

pub const Pointer = struct {
    target: Type,
    many: bool,
    constant: bool,
    variables: bool = false,
};

pub const Optional = struct {
    child: Type,
    variables: bool = false,
};

pub const Result = struct {
    error_set: *const Enum,
    value: Type,
    variables: bool = false,
};

pub const Tuple = struct {
    elements: []const Type,
    variables: bool = false,
};

pub const Function = struct {
    parameters: []const Type,
    return_type: Type,
    variables: bool = false,
};

pub const Variable = struct {
    scope: Scope,
    index: usize,
};

pub const Scope = enum {
    typeclass,
    instance,
    function,
};

pub const Application = struct {
    constructor: Constructor,
    arguments: []const Type,
    variables: bool = true,
};

pub const Constructor = union(enum) {
    variable: Variable,
    function: ast.Resolution.Function,
    typeclass_function: ast.Resolution.TypeclassFunction,
};

pub const Argument = union(enum) {
    type: Type,
    constructor: Constructor,
};

pub const Registry = struct {
    entries: std.ArrayList(Type) = .empty,
    arrays: std.ArrayList(*const Array) = .empty,
    slices: std.ArrayList(*const Slice) = .empty,
    pointers: std.ArrayList(*const Pointer) = .empty,
    optionals: std.ArrayList(*const Optional) = .empty,
    results: std.ArrayList(*const Result) = .empty,
    tuples: std.ArrayList(*const Tuple) = .empty,
    functions: std.ArrayList(*const Function) = .empty,
    applications: std.ArrayList(*const Application) = .empty,
    combined: std.ArrayList(*const Enum) = .empty,
    tags: usize = 1,

    pub fn add(
        self: *Registry,
        allocator: std.mem.Allocator,
        value_type: Type,
    ) std.mem.Allocator.Error!void {
        try self.entries.append(allocator, value_type);
    }

    pub fn addArray(
        self: *Registry,
        allocator: std.mem.Allocator,
        length: u64,
        element: Type,
    ) std.mem.Allocator.Error!*const Array {
        for (self.arrays.items) |array| {
            if (array.length == length and std.meta.eql(array.element, element)) return array;
        }
        const array = try allocator.create(Array);
        array.* = .{ .length = length, .element = element, .variables = hasVariables(element) };
        try self.arrays.append(allocator, array);
        return array;
    }

    pub fn addSlice(
        self: *Registry,
        allocator: std.mem.Allocator,
        element: Type,
        constant: bool,
    ) std.mem.Allocator.Error!*const Slice {
        for (self.slices.items) |slice| {
            if (slice.constant == constant and std.meta.eql(slice.element, element)) return slice;
        }
        const slice = try allocator.create(Slice);
        slice.* = .{ .element = element, .constant = constant, .variables = hasVariables(element) };
        try self.slices.append(allocator, slice);
        return slice;
    }

    pub fn addPointer(
        self: *Registry,
        allocator: std.mem.Allocator,
        pointer: Pointer,
    ) std.mem.Allocator.Error!*const Pointer {
        var marked = pointer;
        marked.variables = hasVariables(pointer.target);
        for (self.pointers.items) |existing| {
            if (std.meta.eql(existing.*, marked)) return existing;
        }
        const stored = try allocator.create(Pointer);
        stored.* = marked;
        try self.pointers.append(allocator, stored);
        return stored;
    }

    pub fn addOptional(
        self: *Registry,
        allocator: std.mem.Allocator,
        child: Type,
    ) std.mem.Allocator.Error!*const Optional {
        for (self.optionals.items) |optional| {
            if (std.meta.eql(optional.child, child)) return optional;
        }
        const optional = try allocator.create(Optional);
        optional.* = .{ .child = child, .variables = hasVariables(child) };
        try self.optionals.append(allocator, optional);
        return optional;
    }

    pub fn addResult(
        self: *Registry,
        allocator: std.mem.Allocator,
        error_set: *const Enum,
        value: Type,
    ) std.mem.Allocator.Error!*const Result {
        for (self.results.items) |result| {
            if (result.error_set == error_set and std.meta.eql(result.value, value)) return result;
        }
        const result = try allocator.create(Result);
        result.* = .{ .error_set = error_set, .value = value, .variables = hasVariables(value) };
        try self.results.append(allocator, result);
        return result;
    }

    pub fn addTuple(
        self: *Registry,
        allocator: std.mem.Allocator,
        elements: []const Type,
    ) std.mem.Allocator.Error!*const Tuple {
        for (self.tuples.items) |tuple| {
            if (isSameElements(tuple.elements, elements)) return tuple;
        }
        const tuple = try allocator.create(Tuple);
        tuple.* = .{ .elements = try allocator.dupe(Type, elements), .variables = anyVariables(elements) };
        try self.tuples.append(allocator, tuple);
        return tuple;
    }

    pub fn addFunction(
        self: *Registry,
        allocator: std.mem.Allocator,
        parameters: []const Type,
        return_type: Type,
    ) std.mem.Allocator.Error!*const Function {
        for (self.functions.items) |function| {
            if (!std.meta.eql(function.return_type, return_type)) continue;
            if (isSameElements(function.parameters, parameters)) return function;
        }
        const function = try allocator.create(Function);
        function.* = .{
            .parameters = try allocator.dupe(Type, parameters),
            .return_type = return_type,
            .variables = anyVariables(parameters) or hasVariables(return_type),
        };
        try self.functions.append(allocator, function);
        return function;
    }

    pub fn addCombined(
        self: *Registry,
        allocator: std.mem.Allocator,
        one: *const Enum,
        two: *const Enum,
    ) std.mem.Allocator.Error!*const Enum {
        var parts: std.ArrayList(*const Enum) = .empty;
        for ([_]*const Enum{ one, two }) |side| {
            for (side.parts) |part| {
                if (std.mem.findScalar(*const Enum, parts.items, part) == null) try parts.append(allocator, part);
            }
        }
        if (parts.items.len == 1) return parts.items[0];
        std.mem.sort(*const Enum, parts.items, {}, isDeclaredBefore);
        for (self.combined.items) |combined| {
            if (combined.parts.len != parts.items.len) continue;
            const same = for (parts.items) |part| {
                if (std.mem.findScalar(*const Enum, combined.parts, part) == null) break false;
            } else true;
            if (same) return combined;
        }
        var cases: std.ArrayList(Case) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (parts.items) |part| {
            try cases.appendSlice(allocator, part.cases);
            try names.append(allocator, part.name);
        }
        const combined = try allocator.create(Enum);
        combined.* = .{
            .module = parts.items[0].module,
            .name = try std.mem.join(allocator, "_or_", names.items),
            .kind = .error_set,
            .cases = cases.items,
            .parts = parts.items,
        };
        try self.combined.append(allocator, combined);
        return combined;
    }

    pub fn addApplication(
        self: *Registry,
        allocator: std.mem.Allocator,
        constructor: Constructor,
        arguments: []const Type,
    ) std.mem.Allocator.Error!*const Application {
        for (self.applications.items) |application| {
            if (!std.meta.eql(application.constructor, constructor)) continue;
            if (isSameElements(application.arguments, arguments)) return application;
        }
        const application = try allocator.create(Application);
        application.* = .{ .constructor = constructor, .arguments = try allocator.dupe(Type, arguments) };
        try self.applications.append(allocator, application);
        return application;
    }
};

pub fn findBuiltInType(name: []const u8) ?Type {
    if (findNumberType(name)) |number| return .{ .number = number };
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "type")) return .type;
    return null;
}

pub fn isCompileTimeOnly(value_type: Type) bool {
    return containsTypeValue(value_type, null);
}

pub fn containsVariable(value_type: Type, scope: Scope) bool {
    if (!hasVariables(value_type)) return false;
    return switch (value_type) {
        .variable => |variable| variable.scope == scope,
        .application => |application| {
            if (application.constructor == .variable and application.constructor.variable.scope == scope) return true;
            for (application.arguments) |argument| {
                if (containsVariable(argument, scope)) return true;
            }
            return false;
        },
        .number, .boolean, .void, .type, .@"struct", .@"enum" => false,
        .pointer => |pointer| containsVariable(pointer.target, scope),
        .slice => |slice| containsVariable(slice.element, scope),
        .array => |array| containsVariable(array.element, scope),
        .optional => |optional| containsVariable(optional.child, scope),
        .result => |result| containsVariable(result.value, scope),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (containsVariable(element, scope)) return true;
            }
            return false;
        },
        .function => |function| {
            for (function.parameters) |parameter| {
                if (containsVariable(parameter, scope)) return true;
            }
            return containsVariable(function.return_type, scope);
        },
    };
}

pub fn matchArgument(pattern: Argument, concrete: Argument, scope: Scope, assigned: []?Argument) bool {
    return switch (pattern) {
        .type => |pattern_type| concrete == .type and matchType(pattern_type, concrete.type, scope, assigned, true),
        .constructor => |constructor| concrete == .constructor and matchConstructor(constructor, concrete.constructor, scope, assigned),
    };
}

pub fn matchType(pattern: Type, concrete: Type, scope: Scope, assigned: []?Argument, exact: bool) bool {
    switch (pattern) {
        .variable => |variable| {
            if (variable.scope != scope) return !exact or std.meta.eql(pattern, concrete);
            const earlier = assigned[variable.index] orelse {
                assigned[variable.index] = .{ .type = concrete };
                return true;
            };
            return earlier == .type and std.meta.eql(earlier.type, concrete);
        },
        .application => |application| {
            const constructor: Constructor, const arguments = switch (concrete) {
                .@"struct" => |struct_type| origin: {
                    const origin = struct_type.origin orelse return false;
                    const function = origin.function orelse return false;
                    break :origin .{ .{ .function = function }, origin.arguments };
                },
                .application => |other| .{ other.constructor, other.arguments },
                else => return false,
            };
            if (!matchConstructor(application.constructor, constructor, scope, assigned)) return false;
            if (arguments.len != application.arguments.len) return false;
            for (application.arguments, arguments) |argument, concrete_argument| {
                if (!matchType(argument, concrete_argument, scope, assigned, exact)) return false;
            }
            return true;
        },
        .number, .boolean, .void, .type, .@"struct", .@"enum" => return !exact or std.meta.eql(pattern, concrete),
        .pointer => |pointer| {
            if (concrete != .pointer or concrete.pointer.many != pointer.many) return false;
            if (exact and concrete.pointer.constant != pointer.constant) return false;
            return matchType(pointer.target, concrete.pointer.target, scope, assigned, exact);
        },
        .slice => |slice| {
            if (concrete != .slice) return false;
            if (exact and concrete.slice.constant != slice.constant) return false;
            return matchType(slice.element, concrete.slice.element, scope, assigned, exact);
        },
        .array => |array| {
            if (concrete != .array or concrete.array.length != array.length) return false;
            return matchType(array.element, concrete.array.element, scope, assigned, exact);
        },
        .optional => |optional| {
            if (concrete != .optional) return false;
            return matchType(optional.child, concrete.optional.child, scope, assigned, exact);
        },
        .result => |result| {
            if (concrete != .result or concrete.result.error_set != result.error_set) return false;
            return matchType(result.value, concrete.result.value, scope, assigned, exact);
        },
        .tuple => |tuple| {
            if (concrete != .tuple or concrete.tuple.elements.len != tuple.elements.len) return false;
            for (tuple.elements, concrete.tuple.elements) |element, concrete_element| {
                if (!matchType(element, concrete_element, scope, assigned, exact)) return false;
            }
            return true;
        },
        .function => |function| {
            if (concrete != .function or concrete.function.parameters.len != function.parameters.len) return false;
            for (function.parameters, concrete.function.parameters) |parameter, concrete_parameter| {
                if (!matchType(parameter, concrete_parameter, scope, assigned, exact)) return false;
            }
            return matchType(function.return_type, concrete.function.return_type, scope, assigned, exact);
        },
    }
}

pub fn substitute(
    allocator: std.mem.Allocator,
    registry: *Registry,
    value_type: Type,
    arguments: []const Argument,
) std.mem.Allocator.Error!Type {
    return switch (value_type) {
        .variable => |variable| {
            if (variable.scope != .typeclass or variable.index >= arguments.len) return value_type;
            const argument = arguments[variable.index];
            return if (argument == .type) argument.type else value_type;
        },
        .number, .boolean, .void, .type, .@"struct", .@"enum" => value_type,
        .application => |application| {
            var constructor = application.constructor;
            if (constructor == .variable and constructor.variable.scope == .typeclass and constructor.variable.index < arguments.len) {
                const argument = arguments[constructor.variable.index];
                if (argument == .constructor) constructor = argument.constructor;
            }
            const substituted = try allocator.alloc(Type, application.arguments.len);
            for (application.arguments, substituted) |argument, *result| {
                result.* = try substitute(allocator, registry, argument, arguments);
            }
            return .{ .application = try registry.addApplication(allocator, constructor, substituted) };
        },
        .pointer => |pointer| .{ .pointer = try registry.addPointer(allocator, .{
            .target = try substitute(allocator, registry, pointer.target, arguments),
            .many = pointer.many,
            .constant = pointer.constant,
        }) },
        .slice => |slice| .{ .slice = try registry.addSlice(
            allocator,
            try substitute(allocator, registry, slice.element, arguments),
            slice.constant,
        ) },
        .array => |array| .{ .array = try registry.addArray(
            allocator,
            array.length,
            try substitute(allocator, registry, array.element, arguments),
        ) },
        .optional => |optional| .{ .optional = try registry.addOptional(
            allocator,
            try substitute(allocator, registry, optional.child, arguments),
        ) },
        .result => |result| .{ .result = try registry.addResult(
            allocator,
            result.error_set,
            try substitute(allocator, registry, result.value, arguments),
        ) },
        .tuple => |tuple| {
            const elements = try allocator.alloc(Type, tuple.elements.len);
            for (tuple.elements, elements) |element, *result| result.* = try substitute(allocator, registry, element, arguments);
            return .{ .tuple = try registry.addTuple(allocator, elements) };
        },
        .function => |function| {
            const parameters = try allocator.alloc(Type, function.parameters.len);
            for (function.parameters, parameters) |parameter, *result| result.* = try substitute(allocator, registry, parameter, arguments);
            const return_type = try substitute(allocator, registry, function.return_type, arguments);
            return .{ .function = try registry.addFunction(allocator, parameters, return_type) };
        },
    };
}

pub fn unifyArguments(one: []const Argument, two: []const Argument, sides: Sides) bool {
    if (one.len != two.len) return false;
    for (one, two) |one_argument, two_argument| {
        switch (one_argument) {
            .type => |one_type| {
                if (two_argument != .type) return false;
                if (!unifyType(.{ .type = one_type, .side = .one }, .{ .type = two_argument.type, .side = .two }, sides)) return false;
            },
            .constructor => |constructor| {
                if (two_argument != .constructor or !std.meta.eql(constructor, two_argument.constructor)) return false;
            },
        }
    }
    return true;
}

pub const Sides = struct {
    one: []?Unified,
    two: []?Unified,

    fn find(self: Sides, side: Side) []?Unified {
        return switch (side) {
            .one => self.one,
            .two => self.two,
        };
    }
};

pub const Unified = struct {
    type: Type,
    side: Side,
};

pub const Side = enum {
    one,
    two,
};

pub fn isDeclaredEnum(enumeration: *const Enum) bool {
    return enumeration.parts.len == 1 and enumeration.parts[0] == enumeration;
}

pub fn isResultError(value_type: Type, result: Result) bool {
    if (value_type != .@"enum" or value_type.@"enum".kind != .error_set) return false;
    if (result.value != .@"enum") return true;
    return !isEnumPart(value_type.@"enum", result.value.@"enum");
}

pub fn isEnumPart(enumeration: *const Enum, combined: *const Enum) bool {
    for (enumeration.parts) |part| {
        if (std.mem.findScalar(*const Enum, combined.parts, part) == null) return false;
    }
    return true;
}

pub fn containsStruct(value_type: Type, target: Struct) bool {
    return containsByValue(value_type, .{ .@"struct" = target }, null);
}

pub fn containsEnum(value_type: Type, target: *const Enum) bool {
    return containsByValue(value_type, .{ .@"enum" = target }, null);
}

fn containsTypeValue(value_type: Type, visited: ?*const Visited) bool {
    return switch (value_type) {
        .type => true,
        .number, .boolean, .void, .variable, .application => false,
        .array => |array| containsTypeValue(array.element, visited),
        .slice => |slice| containsTypeValue(slice.element, visited),
        .pointer => |pointer| containsTypeValue(pointer.target, visited),
        .optional => |optional| containsTypeValue(optional.child, visited),
        .result => |result| containsTypeValue(result.value, visited),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (containsTypeValue(element, visited)) return true;
            }
            return false;
        },
        .function => |function| {
            for (function.parameters) |parameter| {
                if (containsTypeValue(parameter, visited)) return true;
            }
            return containsTypeValue(function.return_type, visited);
        },
        .@"struct" => |struct_type| {
            const identity = @intFromPtr(struct_type.fields.ptr);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (struct_type.fields) |field| {
                if (containsTypeValue(field.type, &node)) return true;
            }
            return false;
        },
        .@"enum" => |enumeration| {
            const identity = @intFromPtr(enumeration);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (enumeration.cases) |case| {
                if (containsTypeValue(case.type orelse continue, &node)) return true;
            }
            return false;
        },
    };
}

fn isVisited(visited: ?*const Visited, identity: usize) bool {
    var current = visited;
    while (current) |node| : (current = node.parent) {
        if (node.identity == identity) return true;
    }
    return false;
}

fn containsByValue(value_type: Type, target: Type, visited: ?*const Visited) bool {
    return switch (value_type) {
        .number, .boolean, .void, .type, .variable, .application, .slice, .pointer, .function => false,
        .array => |array| containsByValue(array.element, target, visited),
        .optional => |optional| containsByValue(optional.child, target, visited),
        .result => |result| containsByValue(.{ .@"enum" = result.error_set }, target, visited) or
            containsByValue(result.value, target, visited),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (containsByValue(element, target, visited)) return true;
            }
            return false;
        },
        .@"struct" => |struct_type| {
            if (target == .@"struct" and std.meta.eql(struct_type, target.@"struct")) return true;
            const identity = @intFromPtr(struct_type.fields.ptr);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (struct_type.fields) |field| {
                if (containsByValue(field.type, target, &node)) return true;
            }
            return false;
        },
        .@"enum" => |enumeration| {
            if (target == .@"enum" and target.@"enum" == enumeration) return true;
            const identity = @intFromPtr(enumeration);
            if (isVisited(visited, identity)) return false;
            const node: Visited = .{ .identity = identity, .parent = visited };
            for (enumeration.cases) |case| {
                if (containsByValue(case.type orelse continue, target, &node)) return true;
            }
            return false;
        },
    };
}

fn isDeclaredBefore(_: void, one: *const Enum, two: *const Enum) bool {
    const length = @min(one.path.len, two.path.len);
    for (one.path[0..length], two.path[0..length]) |one_part, two_part| {
        switch (std.mem.order(u8, one_part, two_part)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    if (one.path.len != two.path.len) return one.path.len < two.path.len;
    return one.position < two.position;
}

fn matchConstructor(pattern: Constructor, concrete: Constructor, scope: Scope, assigned: []?Argument) bool {
    if (pattern == .variable and pattern.variable.scope == scope) {
        const earlier = assigned[pattern.variable.index] orelse {
            assigned[pattern.variable.index] = .{ .constructor = concrete };
            return true;
        };
        return earlier == .constructor and std.meta.eql(earlier.constructor, concrete);
    }
    return std.meta.eql(pattern, concrete);
}

fn unifyType(one: Unified, two: Unified, sides: Sides) bool {
    const left = followBinding(one, sides);
    const right = followBinding(two, sides);
    if (isInstanceVariable(left.type)) return bindVariable(left, right, sides);
    if (isInstanceVariable(right.type)) return bindVariable(right, left, sides);
    switch (left.type) {
        .application => |application| {
            const constructor: Constructor, const arguments = switch (right.type) {
                .@"struct" => |struct_type| origin: {
                    const origin = struct_type.origin orelse return false;
                    const function = origin.function orelse return false;
                    break :origin .{ .{ .function = function }, origin.arguments };
                },
                .application => |other| .{ other.constructor, other.arguments },
                else => return false,
            };
            if (!std.meta.eql(application.constructor, constructor) or arguments.len != application.arguments.len) return false;
            for (application.arguments, arguments) |argument, other| {
                if (!unifyType(.{ .type = argument, .side = left.side }, .{ .type = other, .side = right.side }, sides)) return false;
            }
            return true;
        },
        .@"struct" => {
            if (right.type == .application) return unifyType(right, left, sides);
            return std.meta.eql(left.type, right.type);
        },
        .number, .boolean, .void, .type, .variable, .@"enum" => return std.meta.eql(left.type, right.type),
        .pointer => |pointer| {
            const other = right.type;
            if (other != .pointer or other.pointer.many != pointer.many or other.pointer.constant != pointer.constant) return false;
            return unifyParts(pointer.target, left.side, other.pointer.target, right.side, sides);
        },
        .slice => |slice| {
            const other = right.type;
            if (other != .slice or other.slice.constant != slice.constant) return false;
            return unifyParts(slice.element, left.side, other.slice.element, right.side, sides);
        },
        .array => |array| {
            const other = right.type;
            if (other != .array or other.array.length != array.length) return false;
            return unifyParts(array.element, left.side, other.array.element, right.side, sides);
        },
        .optional => |optional| {
            if (right.type != .optional) return false;
            return unifyParts(optional.child, left.side, right.type.optional.child, right.side, sides);
        },
        .result => |result| {
            if (right.type != .result or right.type.result.error_set != result.error_set) return false;
            return unifyParts(result.value, left.side, right.type.result.value, right.side, sides);
        },
        .tuple => |tuple| {
            const other = right.type;
            if (other != .tuple or other.tuple.elements.len != tuple.elements.len) return false;
            for (tuple.elements, other.tuple.elements) |element, other_element| {
                if (!unifyParts(element, left.side, other_element, right.side, sides)) return false;
            }
            return true;
        },
        .function => |function| {
            const other = right.type;
            if (other != .function or other.function.parameters.len != function.parameters.len) return false;
            for (function.parameters, other.function.parameters) |parameter, other_parameter| {
                if (!unifyParts(parameter, left.side, other_parameter, right.side, sides)) return false;
            }
            return unifyParts(function.return_type, left.side, other.function.return_type, right.side, sides);
        },
    }
}

fn unifyParts(one: Type, one_side: Side, two: Type, two_side: Side, sides: Sides) bool {
    return unifyType(.{ .type = one, .side = one_side }, .{ .type = two, .side = two_side }, sides);
}

fn followBinding(term: Unified, sides: Sides) Unified {
    var current = term;
    while (isInstanceVariable(current.type)) {
        current = sides.find(current.side)[current.type.variable.index] orelse return current;
    }
    return current;
}

fn bindVariable(variable: Unified, term: Unified, sides: Sides) bool {
    if (isInstanceVariable(term.type) and term.side == variable.side) {
        if (term.type.variable.index == variable.type.variable.index) return true;
    }
    if (occurs(variable, term, sides)) return false;
    sides.find(variable.side)[variable.type.variable.index] = term;
    return true;
}

fn occurs(variable: Unified, term: Unified, sides: Sides) bool {
    const current = followBinding(term, sides);
    return switch (current.type) {
        .variable => |other| isInstanceVariable(current.type) and current.side == variable.side and
            other.index == variable.type.variable.index,
        .number, .boolean, .void, .type, .@"struct", .@"enum" => false,
        .application => |application| {
            for (application.arguments) |argument| {
                if (occurs(variable, .{ .type = argument, .side = current.side }, sides)) return true;
            }
            return false;
        },
        .pointer => |pointer| occurs(variable, .{ .type = pointer.target, .side = current.side }, sides),
        .slice => |slice| occurs(variable, .{ .type = slice.element, .side = current.side }, sides),
        .array => |array| occurs(variable, .{ .type = array.element, .side = current.side }, sides),
        .optional => |optional| occurs(variable, .{ .type = optional.child, .side = current.side }, sides),
        .result => |result| occurs(variable, .{ .type = result.value, .side = current.side }, sides),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (occurs(variable, .{ .type = element, .side = current.side }, sides)) return true;
            }
            return false;
        },
        .function => |function| {
            for (function.parameters) |parameter| {
                if (occurs(variable, .{ .type = parameter, .side = current.side }, sides)) return true;
            }
            return occurs(variable, .{ .type = function.return_type, .side = current.side }, sides);
        },
    };
}

fn isInstanceVariable(value_type: Type) bool {
    return value_type == .variable and value_type.variable.scope == .instance;
}

const Visited = struct {
    identity: usize,
    parent: ?*const Visited,
};

pub fn findNumberType(name: []const u8) ?NumberType {
    return std.meta.stringToEnum(NumberType, name);
}

pub fn followPointer(value_type: Type) Type {
    if (value_type != .pointer) return value_type;
    return value_type.pointer.target;
}

pub fn findLayout(value_type: Type) Layout {
    if (isZeroSized(value_type)) return .{ .size = 0, .alignment = 1 };
    return switch (value_type) {
        .number => |number| {
            const size: u64 = switch (number) {
                .i8, .u8 => 1,
                .i16, .u16, .f16 => 2,
                .i32, .u32, .f32 => 4,
                .i64, .u64, .isize, .usize, .f64 => 8,
                .i128, .u128, .f128 => 16,
            };
            return .{ .size = size, .alignment = size };
        },
        .boolean => .{ .size = 1, .alignment = 1 },
        .pointer => .{ .size = 8, .alignment = 8 },
        .slice => .{ .size = 16, .alignment = 8 },
        .array => |array| {
            const element = findLayout(array.element);
            return .{ .size = element.size * array.length, .alignment = element.alignment };
        },
        .optional => |optional| {
            if (optional.child == .pointer) return findLayout(optional.child);
            var layout: Layout = .{ .size = 0, .alignment = 1 };
            layout.append(findLayout(optional.child));
            layout.append(findLayout(.boolean));
            return layout.finish();
        },
        .result => |result| {
            var layout: Layout = .{ .size = 0, .alignment = 1 };
            layout.append(findLayout(.{ .@"enum" = result.error_set }));
            layout.append(findLayout(result.value));
            return layout.finish();
        },
        .tuple => |tuple| {
            var layout: Layout = .{ .size = 0, .alignment = 1 };
            for (tuple.elements) |element| layout.append(findLayout(element));
            return layout.finish();
        },
        .@"struct" => |struct_type| {
            var layout: Layout = .{ .size = 0, .alignment = 1 };
            for (struct_type.fields) |field| layout.append(findLayout(field.type));
            return layout.finish();
        },
        .@"enum" => |enumeration| {
            var payload: Layout = .{ .size = 0, .alignment = 1 };
            for (enumeration.cases) |case| {
                const member = findLayout(case.type orelse continue);
                payload.size = @max(payload.size, member.size);
                payload.alignment = @max(payload.alignment, member.alignment);
            }
            var layout: Layout = .{ .size = 0, .alignment = 1 };
            layout.append(findLayout(.{ .number = .u32 }));
            layout.append(payload.finish());
            return layout.finish();
        },
        .void, .type, .function, .variable, .application => unreachable,
    };
}

pub const Layout = struct {
    size: u64,
    alignment: u64,

    fn append(self: *Layout, member: Layout) void {
        if (member.size == 0) return;
        self.size = std.mem.alignForward(u64, self.size, member.alignment) + member.size;
        self.alignment = @max(self.alignment, member.alignment);
    }

    fn finish(self: Layout) Layout {
        return .{ .size = std.mem.alignForward(u64, self.size, self.alignment), .alignment = self.alignment };
    }
};

pub fn isZeroSized(value_type: Type) bool {
    switch (value_type) {
        .@"struct" => |struct_type| {
            for (struct_type.fields) |field| {
                if (!isZeroSized(field.type)) return false;
            }
            return true;
        },
        .array => |array| return array.length == 0 or isZeroSized(array.element),
        .tuple => |tuple| {
            for (tuple.elements) |element| {
                if (!isZeroSized(element)) return false;
            }
            return true;
        },
        .void => return true,
        .number, .boolean, .type, .slice, .pointer, .optional, .result, .function, .variable, .application, .@"enum" => {
            return false;
        },
    }
}

fn hasVariables(value_type: Type) bool {
    return switch (value_type) {
        .variable => true,
        .application => |application| application.variables,
        .number, .boolean, .void, .type, .@"struct", .@"enum" => false,
        .array => |array| array.variables,
        .slice => |slice| slice.variables,
        .pointer => |pointer| pointer.variables,
        .optional => |optional| optional.variables,
        .result => |result| result.variables,
        .tuple => |tuple| tuple.variables,
        .function => |function| function.variables,
    };
}

fn anyVariables(value_types: []const Type) bool {
    for (value_types) |value_type| {
        if (hasVariables(value_type)) return true;
    }
    return false;
}

fn isSameElements(one: []const Type, two: []const Type) bool {
    if (one.len != two.len) return false;
    for (one, two) |element_one, element_two| {
        if (!std.meta.eql(element_one, element_two)) return false;
    }
    return true;
}

test "Registry.add: records each type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const one: Type = .{ .@"struct" = .{ .module = 0, .name = "One", .fields = &.{} } };
    const two: Type = .{ .@"struct" = .{ .module = 0, .name = "Two", .fields = &.{} } };
    try type_registry.add(arena.allocator(), one);
    try type_registry.add(arena.allocator(), two);

    try std.testing.expectEqualStrings("One", type_registry.entries.items[0].@"struct".name);
    try std.testing.expectEqualStrings("Two", type_registry.entries.items[1].@"struct".name);
}

test "Registry.addArray: gives an array type one record for each length and element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addArray(arena.allocator(), 2, .boolean);
    const second = try type_registry.addArray(arena.allocator(), 2, .boolean);
    const longer = try type_registry.addArray(arena.allocator(), 3, .boolean);

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != longer);
}

test "Registry.addSlice: gives a slice type one record for each element and mutability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addSlice(arena.allocator(), .boolean, false);
    const second = try type_registry.addSlice(arena.allocator(), .boolean, false);
    const constant = try type_registry.addSlice(arena.allocator(), .boolean, true);

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != constant);
}

test "Registry.addPointer: gives a pointer type one record for each target, count and mutability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const pointer: Pointer = .{ .target = .boolean, .many = false, .constant = false };
    const first = try type_registry.addPointer(arena.allocator(), pointer);
    const second = try type_registry.addPointer(arena.allocator(), pointer);
    const many = try type_registry.addPointer(arena.allocator(), .{ .target = .boolean, .many = true, .constant = false });
    const constant = try type_registry.addPointer(arena.allocator(), .{ .target = .boolean, .many = false, .constant = true });

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != many);
    try std.testing.expect(first != constant);
}

test "Registry.addOptional: gives an optional type one record for each child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addOptional(arena.allocator(), .boolean);
    const second = try type_registry.addOptional(arena.allocator(), .boolean);
    const nested = try type_registry.addOptional(arena.allocator(), .{ .optional = first });

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != nested);
}

test "Registry.addTuple: gives a tuple type one record for each list of elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .void });
    const second = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .void });
    const reversed = try type_registry.addTuple(arena.allocator(), &.{ .void, .boolean });
    const longer = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .void, .boolean });

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != reversed);
    try std.testing.expect(first != longer);
}

test "Registry.addFunction: gives a function type one record for each signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .void);
    const second = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .void);
    const other_return = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .boolean);
    const other_parameters = try type_registry.addFunction(arena.allocator(), &.{}, .void);

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != other_return);
    try std.testing.expect(first != other_parameters);
}

test "findBuiltInType: finds number types, bool and void" {
    try std.testing.expectEqual(Type{ .number = .u8 }, findBuiltInType("u8").?);
    try std.testing.expectEqual(Type{ .number = .usize }, findBuiltInType("usize").?);
    try std.testing.expectEqual(Type.boolean, findBuiltInType("bool").?);
    try std.testing.expectEqual(Type.void, findBuiltInType("void").?);
}

test "findBuiltInType: finds nothing for other names" {
    try std.testing.expectEqual(null, findBuiltInType("Bool"));
    try std.testing.expectEqual(null, findBuiltInType("String"));
    try std.testing.expectEqual(null, findBuiltInType("Void"));
    try std.testing.expectEqual(null, findBuiltInType("Integer"));
    try std.testing.expectEqual(null, findBuiltInType("char"));
    try std.testing.expectEqual(null, findBuiltInType("string"));
}

test "findNumberType: finds only number types" {
    try std.testing.expectEqual(NumberType.f64, findNumberType("f64").?);
    try std.testing.expectEqual(null, findNumberType("bool"));
}

test "followPointer: follows a single and a multiple value pointer one level" {
    const single: Pointer = .{ .target = .boolean, .many = false, .constant = false };
    const many: Pointer = .{ .target = .boolean, .many = true, .constant = true };
    const nested: Pointer = .{ .target = .{ .pointer = &single }, .many = false, .constant = false };

    try std.testing.expectEqual(Type.boolean, followPointer(.{ .pointer = &single }));
    try std.testing.expectEqual(Type.boolean, followPointer(.{ .pointer = &many }));
    try std.testing.expectEqual(Type{ .pointer = &single }, followPointer(.{ .pointer = &nested }));
    try std.testing.expectEqual(Type.boolean, followPointer(.boolean));
}

test "isZeroSized: treats an array of void as zero-sized" {
    const voids: Array = .{ .length = 3, .element = .void };
    const numbers: Array = .{ .length = 3, .element = .{ .number = .i32 } };

    try std.testing.expect(isZeroSized(.{ .array = &voids }));
    try std.testing.expect(!isZeroSized(.{ .array = &numbers }));
}
