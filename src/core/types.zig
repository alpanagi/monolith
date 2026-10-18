const std = @import("std");

pub const Type = union(enum) {
    number: NumberType,
    boolean,
    string,
    void,
    type,
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
