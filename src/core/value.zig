const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

pub const Value = union(enum) {
    integer: Integer,
    float: f128,
    boolean: bool,
    void,
    undefined,
    optional: ?*Value,
    aggregate: []Value,
    pointer: Value.Pointer,
    many: Value.Many,
    slice: Value.Slice,
    function: ast.Resolution.Function,
    type: types.Type,
    enumeration: Value.Enumeration,
    failure: Value.Enumeration,

    pub const Enumeration = struct {
        case: *const types.Case,
        value: ?*Value = null,
    };

    pub const Pointer = struct {
        root: *Value,
        root_type: types.Type,
        path: []const usize,
        text: bool = false,
        single: bool = false,
    };

    pub const Many = struct {
        array: Value.Pointer,
        index: i128,
    };

    pub const Slice = struct {
        array: Value.Pointer,
        start: usize,
        length: usize,
    };
};

pub const Integer = union(enum) {
    signed: i128,
    unsigned: u128,

    pub const Error = error{
        IntegerOverflow,
        DivisionByZero,
    };

    pub fn findMinimum(number: types.NumberType) Integer {
        return switch (number) {
            .i8 => .{ .signed = std.math.minInt(i8) },
            .i16 => .{ .signed = std.math.minInt(i16) },
            .i32 => .{ .signed = std.math.minInt(i32) },
            .i64, .isize => .{ .signed = std.math.minInt(i64) },
            .i128 => .{ .signed = std.math.minInt(i128) },
            .u8, .u16, .u32, .u64, .u128, .usize => .{ .unsigned = 0 },
            .f16, .f32, .f64, .f128 => unreachable,
        };
    }

    pub fn findMaximum(number: types.NumberType) Integer {
        return switch (number) {
            .i8 => .{ .signed = std.math.maxInt(i8) },
            .i16 => .{ .signed = std.math.maxInt(i16) },
            .i32 => .{ .signed = std.math.maxInt(i32) },
            .i64, .isize => .{ .signed = std.math.maxInt(i64) },
            .i128 => .{ .signed = std.math.maxInt(i128) },
            .u8 => .{ .unsigned = std.math.maxInt(u8) },
            .u16 => .{ .unsigned = std.math.maxInt(u16) },
            .u32 => .{ .unsigned = std.math.maxInt(u32) },
            .u64, .usize => .{ .unsigned = std.math.maxInt(u64) },
            .u128 => .{ .unsigned = std.math.maxInt(u128) },
            .f16, .f32, .f64, .f128 => unreachable,
        };
    }

    pub fn parse(number: types.NumberType, text: []const u8, negative: bool) Integer {
        const magnitude = std.fmt.parseInt(u128, text, 0) catch unreachable;
        if (!isSigned(number)) {
            std.debug.assert(!negative);
            return .{ .unsigned = magnitude };
        }
        if (!negative) return .{ .signed = @intCast(magnitude) };
        if (magnitude == @as(u128, 1) << 127) return .{ .signed = std.math.minInt(i128) };
        return .{ .signed = -@as(i128, @intCast(magnitude)) };
    }

    pub fn fromFloat(number: types.NumberType, float: f128) ?Integer {
        if (std.math.isNan(float) or std.math.isInf(float)) return null;
        const truncated = @trunc(float);
        const signed = isSigned(number);
        const lowest: f128 = if (signed) -0x1p127 else 0;
        const limit: f128 = if (signed) 0x1p127 else 0x1p128;
        if (truncated < lowest or truncated >= limit) return null;
        const integer: Integer = if (signed) .{ .signed = @intFromFloat(truncated) } else .{ .unsigned = @intFromFloat(truncated) };
        if (!integer.fits(number)) return null;
        return integer;
    }

    pub fn toFloat(self: Integer) f128 {
        return switch (self) {
            inline else => |value| @floatFromInt(value),
        };
    }

    pub fn convert(self: Integer, number: types.NumberType) ?Integer {
        const converted = self.recast(isSigned(number)) orelse return null;
        if (!converted.fits(number)) return null;
        return converted;
    }

    pub fn truncate(self: Integer, number: types.NumberType) Integer {
        return truncateBits(number, self.toBits());
    }

    pub fn order(self: Integer, other: Integer) std.math.Order {
        return switch (self) {
            .signed => |value| std.math.order(value, other.signed),
            .unsigned => |value| std.math.order(value, other.unsigned),
        };
    }

    pub fn increment(self: Integer) Integer {
        return switch (self) {
            .signed => |value| .{ .signed = value + 1 },
            .unsigned => |value| .{ .unsigned = value + 1 },
        };
    }

    pub fn decrement(self: Integer) Integer {
        return switch (self) {
            .signed => |value| .{ .signed = value - 1 },
            .unsigned => |value| .{ .unsigned = value - 1 },
        };
    }

    pub fn add(self: Integer, number: types.NumberType, other: Integer) Error!Integer {
        assertOperands(number, self, other);
        const sum: Integer = switch (self) {
            .signed => |value| .{ .signed = try expectExact(@addWithOverflow(value, other.signed)) },
            .unsigned => |value| .{ .unsigned = try expectExact(@addWithOverflow(value, other.unsigned)) },
        };
        return sum.expectFits(number);
    }

    pub fn subtract(self: Integer, number: types.NumberType, other: Integer) Error!Integer {
        assertOperands(number, self, other);
        const difference: Integer = switch (self) {
            .signed => |value| .{ .signed = try expectExact(@subWithOverflow(value, other.signed)) },
            .unsigned => |value| .{ .unsigned = try expectExact(@subWithOverflow(value, other.unsigned)) },
        };
        return difference.expectFits(number);
    }

    pub fn multiply(self: Integer, number: types.NumberType, other: Integer) Error!Integer {
        assertOperands(number, self, other);
        const product: Integer = switch (self) {
            .signed => |value| .{ .signed = try expectExact(@mulWithOverflow(value, other.signed)) },
            .unsigned => |value| .{ .unsigned = try expectExact(@mulWithOverflow(value, other.unsigned)) },
        };
        return product.expectFits(number);
    }

    pub fn divide(self: Integer, number: types.NumberType, other: Integer) Error!Integer {
        assertOperands(number, self, other);
        if (other.isZero()) return error.DivisionByZero;
        const quotient: Integer = switch (self) {
            .signed => |value| quotient: {
                if (value == std.math.minInt(i128) and other.signed == -1) return error.IntegerOverflow;
                break :quotient .{ .signed = @divTrunc(value, other.signed) };
            },
            .unsigned => |value| .{ .unsigned = @divTrunc(value, other.unsigned) },
        };
        return quotient.expectFits(number);
    }

    pub fn remainder(self: Integer, number: types.NumberType, other: Integer) Error!Integer {
        assertOperands(number, self, other);
        if (other.isZero()) return error.DivisionByZero;
        const result: Integer = switch (self) {
            .signed => |value| .{ .signed = if (other.signed == -1) 0 else @rem(value, other.signed) },
            .unsigned => |value| .{ .unsigned = @rem(value, other.unsigned) },
        };
        return result.expectFits(number);
    }

    pub fn bitwiseAnd(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() & other.toBits());
    }

    pub fn bitwiseExclusiveOr(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() ^ other.toBits());
    }

    pub fn bitwiseOr(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() | other.toBits());
    }

    pub fn shiftLeft(self: Integer, number: types.NumberType, amount: Integer) Integer {
        self.assertCase(number);
        const distance = amount.unsigned;
        if (distance >= findWidth(number)) return truncateBits(number, 0);
        return truncateBits(number, self.toBits() << @intCast(distance));
    }

    pub fn shiftRight(self: Integer, number: types.NumberType, amount: Integer) Integer {
        self.assertCase(number);
        const distance = amount.unsigned;
        if (distance >= findWidth(number)) {
            return switch (self) {
                .signed => |value| .{ .signed = if (value < 0) -1 else 0 },
                .unsigned => .{ .unsigned = 0 },
            };
        }
        return switch (self) {
            .signed => |value| .{ .signed = value >> @intCast(distance) },
            .unsigned => |value| .{ .unsigned = value >> @intCast(distance) },
        };
    }

    pub fn negate(self: Integer, number: types.NumberType) Error!Integer {
        self.assertCase(number);
        const negated: Integer = switch (self) {
            .signed => |value| .{ .signed = try expectExact(@subWithOverflow(0, value)) },
            .unsigned => |value| .{ .unsigned = try expectExact(@subWithOverflow(0, value)) },
        };
        return negated.expectFits(number);
    }

    pub fn invert(self: Integer, number: types.NumberType) Integer {
        self.assertCase(number);
        return switch (self) {
            .signed => |value| .{ .signed = ~value },
            .unsigned => |value| .{ .unsigned = findMaximum(number).unsigned - value },
        };
    }

    pub fn addWrapping(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() +% other.toBits());
    }

    pub fn subtractWrapping(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() -% other.toBits());
    }

    pub fn multiplyWrapping(self: Integer, number: types.NumberType, other: Integer) Integer {
        assertOperands(number, self, other);
        return truncateBits(number, self.toBits() *% other.toBits());
    }

    fn assertCase(self: Integer, number: types.NumberType) void {
        std.debug.assert((self == .signed) == isSigned(number));
    }

    fn recast(self: Integer, signed: bool) ?Integer {
        return switch (self) {
            .signed => |value| {
                if (signed) return self;
                const unsigned = std.math.cast(u128, value) orelse return null;
                return .{ .unsigned = unsigned };
            },
            .unsigned => |value| {
                if (!signed) return self;
                const cast = std.math.cast(i128, value) orelse return null;
                return .{ .signed = cast };
            },
        };
    }

    fn fits(self: Integer, number: types.NumberType) bool {
        return self.order(findMinimum(number)) != .lt and self.order(findMaximum(number)) != .gt;
    }

    fn expectFits(self: Integer, number: types.NumberType) Error!Integer {
        if (!self.fits(number)) return error.IntegerOverflow;
        return self;
    }

    fn isZero(self: Integer) bool {
        return switch (self) {
            inline else => |value| value == 0,
        };
    }

    fn toBits(self: Integer) u128 {
        return switch (self) {
            .signed => |value| @bitCast(value),
            .unsigned => |value| value,
        };
    }
};

fn assertOperands(number: types.NumberType, one: Integer, two: Integer) void {
    one.assertCase(number);
    two.assertCase(number);
}

fn expectExact(result: anytype) Integer.Error!@TypeOf(result[0]) {
    if (result[1] == 1) return error.IntegerOverflow;
    return result[0];
}

fn truncateBits(number: types.NumberType, bits: u128) Integer {
    return switch (number) {
        .u8 => .{ .unsigned = @as(u8, @truncate(bits)) },
        .u16 => .{ .unsigned = @as(u16, @truncate(bits)) },
        .u32 => .{ .unsigned = @as(u32, @truncate(bits)) },
        .u64, .usize => .{ .unsigned = @as(u64, @truncate(bits)) },
        .u128 => .{ .unsigned = bits },
        .i8 => .{ .signed = @as(i8, @bitCast(@as(u8, @truncate(bits)))) },
        .i16 => .{ .signed = @as(i16, @bitCast(@as(u16, @truncate(bits)))) },
        .i32 => .{ .signed = @as(i32, @bitCast(@as(u32, @truncate(bits)))) },
        .i64, .isize => .{ .signed = @as(i64, @bitCast(@as(u64, @truncate(bits)))) },
        .i128 => .{ .signed = @bitCast(bits) },
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

fn isSigned(number: types.NumberType) bool {
    return switch (number) {
        .i8, .i16, .i32, .i64, .i128, .isize => true,
        .u8, .u16, .u32, .u64, .u128, .usize => false,
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

fn findWidth(number: types.NumberType) u8 {
    return switch (number) {
        .i8, .u8 => 8,
        .i16, .u16 => 16,
        .i32, .u32 => 32,
        .i64, .u64, .isize, .usize => 64,
        .i128, .u128 => 128,
        .f16, .f32, .f64, .f128 => unreachable,
    };
}

test "Integer.parse: gives the most negative i128 from its magnitude" {
    try std.testing.expectEqual(Integer{ .signed = std.math.minInt(i128) }, Integer.parse(.i128, "170141183460469231731687303715884105728", true));
    try std.testing.expectEqual(Integer{ .unsigned = std.math.maxInt(u128) }, Integer.parse(.u128, "0xffffffffffffffffffffffffffffffff", false));
}

test "Integer.fromFloat: rejects the first float past the i128 and the u128 maximum" {
    try std.testing.expectEqual(null, Integer.fromFloat(.i128, 0x1p127));
    try std.testing.expectEqual(null, Integer.fromFloat(.u128, 0x1p128));
    try std.testing.expectEqual(Integer{ .signed = std.math.minInt(i128) }, Integer.fromFloat(.i128, -0x1p127).?);
    try std.testing.expectEqual(Integer{ .unsigned = 0 }, Integer.fromFloat(.u8, -0.5).?);
    try std.testing.expectEqual(null, Integer.fromFloat(.u8, -1));
}

test "Integer.convert: rejects a value outside the target type across signedness" {
    try std.testing.expectEqual(null, (Integer{ .unsigned = @as(u128, 1) << 127 }).convert(.i128));
    try std.testing.expectEqual(null, (Integer{ .signed = -1 }).convert(.u128));
    try std.testing.expectEqual(Integer{ .unsigned = 255 }, (Integer{ .signed = 255 }).convert(.u8).?);
    try std.testing.expectEqual(Integer{ .signed = std.math.maxInt(i128) }, (Integer{ .unsigned = std.math.maxInt(i128) }).convert(.i128).?);
}

test "Integer.truncate: keeps the low bits between i128 and u128" {
    try std.testing.expectEqual(Integer{ .unsigned = @as(u128, 1) << 127 }, (Integer{ .signed = std.math.minInt(i128) }).truncate(.u128));
    try std.testing.expectEqual(Integer{ .signed = -1 }, (Integer{ .unsigned = std.math.maxInt(u128) }).truncate(.i128));
    try std.testing.expectEqual(Integer{ .signed = -1 }, (Integer{ .unsigned = std.math.maxInt(u128) }).truncate(.i8));
}

test "Integer.add: rejects a sum past the i128 and the u128 maximum" {
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .unsigned = std.math.maxInt(u128) }).add(.u128, .{ .unsigned = 1 }));
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = std.math.maxInt(i128) }).add(.i128, .{ .signed = 1 }));
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = 127 }).add(.i8, .{ .signed = 1 }));
}

test "Integer.subtract: rejects an unsigned difference below 0" {
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .unsigned = 0 }).subtract(.u128, .{ .unsigned = 1 }));
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = std.math.minInt(i128) }).subtract(.i128, .{ .signed = 1 }));
}

test "Integer.multiply: rejects the most negative i128 times -1" {
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = std.math.minInt(i128) }).multiply(.i128, .{ .signed = -1 }));
}

test "Integer.divide: rejects the most negative i128 divided by -1" {
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = std.math.minInt(i128) }).divide(.i128, .{ .signed = -1 }));
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = -128 }).divide(.i8, .{ .signed = -1 }));
    try std.testing.expectError(error.DivisionByZero, (Integer{ .unsigned = 1 }).divide(.u128, .{ .unsigned = 0 }));
    try std.testing.expectEqual(Integer{ .signed = -2 }, try (Integer{ .signed = -7 }).divide(.i128, .{ .signed = 3 }));
}

test "Integer.remainder: gives 0 for the most negative i128 by -1" {
    try std.testing.expectEqual(Integer{ .signed = 0 }, try (Integer{ .signed = std.math.minInt(i128) }).remainder(.i128, .{ .signed = -1 }));
    try std.testing.expectEqual(Integer{ .signed = -1 }, try (Integer{ .signed = -7 }).remainder(.i128, .{ .signed = 3 }));
    try std.testing.expectError(error.DivisionByZero, (Integer{ .signed = 1 }).remainder(.i128, .{ .signed = 0 }));
}

test "Integer.shiftLeft: discards the bits shifted out of i128 and u128" {
    try std.testing.expectEqual(Integer{ .signed = std.math.minInt(i128) }, (Integer{ .signed = 1 }).shiftLeft(.i128, .{ .unsigned = 127 }));
    try std.testing.expectEqual(Integer{ .unsigned = std.math.maxInt(u128) - 1 }, (Integer{ .unsigned = std.math.maxInt(u128) }).shiftLeft(.u128, .{ .unsigned = 1 }));
    try std.testing.expectEqual(Integer{ .signed = 0 }, (Integer{ .signed = -1 }).shiftLeft(.i128, .{ .unsigned = 128 }));
}

test "Integer.shiftRight: fills i128 with its sign for any amount" {
    try std.testing.expectEqual(Integer{ .signed = -1 }, (Integer{ .signed = std.math.minInt(i128) }).shiftRight(.i128, .{ .unsigned = 127 }));
    try std.testing.expectEqual(Integer{ .signed = -1 }, (Integer{ .signed = std.math.minInt(i128) }).shiftRight(.i128, .{ .unsigned = 200 }));
    try std.testing.expectEqual(Integer{ .unsigned = 1 }, (Integer{ .unsigned = std.math.maxInt(u128) }).shiftRight(.u128, .{ .unsigned = 127 }));
    try std.testing.expectEqual(Integer{ .unsigned = 0 }, (Integer{ .unsigned = std.math.maxInt(u128) }).shiftRight(.u128, .{ .unsigned = 128 }));
}

test "Integer.negate: rejects the most negative i128" {
    try std.testing.expectError(error.IntegerOverflow, (Integer{ .signed = std.math.minInt(i128) }).negate(.i128));
    try std.testing.expectEqual(Integer{ .signed = -std.math.maxInt(i128) }, try (Integer{ .signed = std.math.maxInt(i128) }).negate(.i128));
}

test "Integer.invert: inverts every bit inside the type" {
    try std.testing.expectEqual(Integer{ .signed = std.math.maxInt(i128) }, (Integer{ .signed = std.math.minInt(i128) }).invert(.i128));
    try std.testing.expectEqual(Integer{ .unsigned = std.math.maxInt(u128) }, (Integer{ .unsigned = 0 }).invert(.u128));
    try std.testing.expectEqual(Integer{ .unsigned = 250 }, (Integer{ .unsigned = 5 }).invert(.u8));
}

test "Integer.addWrapping: wraps around the i128 and the u128 maximum" {
    try std.testing.expectEqual(Integer{ .unsigned = 0 }, (Integer{ .unsigned = std.math.maxInt(u128) }).addWrapping(.u128, .{ .unsigned = 1 }));
    try std.testing.expectEqual(Integer{ .signed = std.math.minInt(i128) }, (Integer{ .signed = std.math.maxInt(i128) }).addWrapping(.i128, .{ .signed = 1 }));
}

test "Integer.subtractWrapping: wraps around the i128 minimum" {
    try std.testing.expectEqual(Integer{ .signed = std.math.maxInt(i128) }, (Integer{ .signed = std.math.minInt(i128) }).subtractWrapping(.i128, .{ .signed = 1 }));
}

test "Integer.multiplyWrapping: gives the most negative i128 for itself times -1" {
    try std.testing.expectEqual(Integer{ .signed = std.math.minInt(i128) }, (Integer{ .signed = std.math.minInt(i128) }).multiplyWrapping(.i128, .{ .signed = -1 }));
}
