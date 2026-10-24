const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

pub const Type = union(enum) {
    number: NumberType,
    boolean,
    string,
    void,
    type,
    @"struct": Struct,
    array: *const Array,
    slice: *const Slice,
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

pub const Registry = struct {
    entries: std.ArrayList(Type) = .empty,
    arrays: std.ArrayList(*const Array) = .empty,
    slices: std.ArrayList(*const Slice) = .empty,

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
};

pub fn findBuiltInType(name: []const u8) ?Type {
    if (findNumberType(name)) |number| return .{ .number = number };
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "void")) return .void;
    return null;
}

pub fn findNumberType(name: []const u8) ?NumberType {
    return std.meta.stringToEnum(NumberType, name);
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

test "findBuiltInType: finds number types, bool, string and void" {
    try std.testing.expectEqual(Type{ .number = .u8 }, findBuiltInType("u8").?);
    try std.testing.expectEqual(Type{ .number = .usize }, findBuiltInType("usize").?);
    try std.testing.expectEqual(Type.boolean, findBuiltInType("bool").?);
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
