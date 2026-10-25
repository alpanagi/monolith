const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const Type = union(enum) {
    number: NumberType,
    boolean,
    character,
    string,
    void,
    type,
    @"struct": Struct,
    array: *const Array,
    slice: *const Slice,
    pointer: *const Pointer,
    optional: *const Optional,
    tuple: *const Tuple,
    function: *const Function,
    implementer,
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
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    default: ?*ast.Expression = null,
    location: token.Location,
};

pub const Array = struct {
    length: u64,
    element: Type,
};

pub const Slice = struct {
    element: Type,
    constant: bool,
};

pub const Pointer = struct {
    target: Type,
    many: bool,
    constant: bool,
};

pub const Optional = struct {
    child: Type,
};

pub const Tuple = struct {
    elements: []const Type,
};

pub const Function = struct {
    parameters: []const Type,
    return_type: Type,
};

pub const Registry = struct {
    entries: std.ArrayList(Type) = .empty,
    arrays: std.ArrayList(*const Array) = .empty,
    slices: std.ArrayList(*const Slice) = .empty,
    pointers: std.ArrayList(*const Pointer) = .empty,
    optionals: std.ArrayList(*const Optional) = .empty,
    tuples: std.ArrayList(*const Tuple) = .empty,
    functions: std.ArrayList(*const Function) = .empty,

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
        array.* = .{ .length = length, .element = element };
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
        slice.* = .{ .element = element, .constant = constant };
        try self.slices.append(allocator, slice);
        return slice;
    }

    pub fn addPointer(
        self: *Registry,
        allocator: std.mem.Allocator,
        pointer: Pointer,
    ) std.mem.Allocator.Error!*const Pointer {
        for (self.pointers.items) |existing| {
            if (std.meta.eql(existing.*, pointer)) return existing;
        }
        const stored = try allocator.create(Pointer);
        stored.* = pointer;
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
        optional.* = .{ .child = child };
        try self.optionals.append(allocator, optional);
        return optional;
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
        tuple.* = .{ .elements = try allocator.dupe(Type, elements) };
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
        };
        try self.functions.append(allocator, function);
        return function;
    }
};

pub fn findBuiltInType(name: []const u8) ?Type {
    if (findNumberType(name)) |number| return .{ .number = number };
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "char")) return .character;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "void")) return .void;
    return null;
}

pub fn findNumberType(name: []const u8) ?NumberType {
    return std.meta.stringToEnum(NumberType, name);
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

    const first = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .character });
    const second = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .character });
    const reversed = try type_registry.addTuple(arena.allocator(), &.{ .character, .boolean });
    const longer = try type_registry.addTuple(arena.allocator(), &.{ .boolean, .character, .boolean });

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != reversed);
    try std.testing.expect(first != longer);
}

test "Registry.addFunction: gives a function type one record for each signature" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var type_registry: Registry = .{};

    const first = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .character);
    const second = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .character);
    const other_return = try type_registry.addFunction(arena.allocator(), &.{.boolean}, .boolean);
    const other_parameters = try type_registry.addFunction(arena.allocator(), &.{}, .character);

    try std.testing.expectEqual(first, second);
    try std.testing.expect(first != other_return);
    try std.testing.expect(first != other_parameters);
}

test "findBuiltInType: finds number types, bool, char, string and void" {
    try std.testing.expectEqual(Type{ .number = .u8 }, findBuiltInType("u8").?);
    try std.testing.expectEqual(Type{ .number = .usize }, findBuiltInType("usize").?);
    try std.testing.expectEqual(Type.boolean, findBuiltInType("bool").?);
    try std.testing.expectEqual(Type.character, findBuiltInType("char").?);
    try std.testing.expectEqual(Type.string, findBuiltInType("string").?);
    try std.testing.expectEqual(Type.void, findBuiltInType("void").?);
}

test "findBuiltInType: finds nothing for other names" {
    try std.testing.expectEqual(null, findBuiltInType("Bool"));
    try std.testing.expectEqual(null, findBuiltInType("String"));
    try std.testing.expectEqual(null, findBuiltInType("Void"));
    try std.testing.expectEqual(null, findBuiltInType("Integer"));
}

test "findNumberType: finds only number types" {
    try std.testing.expectEqual(NumberType.f64, findNumberType("f64").?);
    try std.testing.expectEqual(null, findNumberType("bool"));
}
