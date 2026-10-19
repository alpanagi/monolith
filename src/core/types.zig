const std = @import("std");
const token = @import("token.zig");

pub const Type = union(enum) {
    number: NumberType,
    boolean,
    string,
    void,
    type,
    @"struct": Struct,
};

pub const NumberType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
};

pub const Struct = struct {
    module: usize,
    name: []const u8,
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    location: token.Location,
};

pub const Registry = struct {
    entries: std.ArrayList(Type) = .empty,

    pub fn add(
        self: *Registry,
        allocator: std.mem.Allocator,
        value_type: Type,
    ) std.mem.Allocator.Error!void {
        try self.entries.append(allocator, value_type);
    }
};

pub fn findBuiltInType(name: []const u8) ?Type {
    if (findNumberType(name)) |number| return .{ .number = number };
    if (std.mem.eql(u8, name, "Bool")) return .boolean;
    if (std.mem.eql(u8, name, "String")) return .string;
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

test "findBuiltInType: finds number types, Bool, String and void" {
    try std.testing.expectEqual(Type{ .number = .u8 }, findBuiltInType("u8").?);
    try std.testing.expectEqual(Type.boolean, findBuiltInType("Bool").?);
    try std.testing.expectEqual(Type.string, findBuiltInType("String").?);
    try std.testing.expectEqual(Type.void, findBuiltInType("void").?);
}

test "findBuiltInType: finds nothing for other names" {
    try std.testing.expectEqual(null, findBuiltInType("bool"));
    try std.testing.expectEqual(null, findBuiltInType("Void"));
    try std.testing.expectEqual(null, findBuiltInType("Integer"));
}

test "findNumberType: finds only number types" {
    try std.testing.expectEqual(NumberType.f64, findNumberType("f64").?);
    try std.testing.expectEqual(null, findNumberType("Bool"));
}
