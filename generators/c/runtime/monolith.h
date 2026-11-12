#ifndef MONOLITH_H
#define MONOLITH_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

__extension__ typedef __int128 int128_t;
__extension__ typedef unsigned __int128 uint128_t;

#define mn_zero_sized ((void *)4096)

#define MN_SIGNED_HELPERS(name, type, unsigned_type, width) \
    static inline type mn_shift_left_##name(type value, size_t amount) { \
        if (amount >= width) return 0; \
        return (type)(unsigned_type)((unsigned_type)value << amount); \
    } \
    static inline type mn_shift_right_##name(type value, size_t amount) { \
        if (amount >= width) return value < 0 ? -1 : 0; \
        return (type)(value >> amount); \
    } \
    static inline type mn_remainder_##name(type left, type right) { \
        if (right == -1) return 0; \
        return (type)(left % right); \
    }

#define MN_UNSIGNED_HELPERS(name, type, width) \
    static inline type mn_shift_left_##name(type value, size_t amount) { \
        if (amount >= width) return 0; \
        return (type)(value << amount); \
    } \
    static inline type mn_shift_right_##name(type value, size_t amount) { \
        if (amount >= width) return 0; \
        return (type)(value >> amount); \
    }

MN_SIGNED_HELPERS(i8, int8_t, uint8_t, 8)
MN_SIGNED_HELPERS(i16, int16_t, uint16_t, 16)
MN_SIGNED_HELPERS(i32, int32_t, uint32_t, 32)
MN_SIGNED_HELPERS(i64, int64_t, uint64_t, 64)
MN_SIGNED_HELPERS(i128, int128_t, uint128_t, 128)
MN_SIGNED_HELPERS(isize, ptrdiff_t, size_t, sizeof(ptrdiff_t) * CHAR_BIT)
MN_UNSIGNED_HELPERS(u8, uint8_t, 8)
MN_UNSIGNED_HELPERS(u16, uint16_t, 16)
MN_UNSIGNED_HELPERS(u32, uint32_t, 32)
MN_UNSIGNED_HELPERS(u64, uint64_t, 64)
MN_UNSIGNED_HELPERS(u128, uint128_t, 128)
MN_UNSIGNED_HELPERS(usize, size_t, sizeof(size_t) * CHAR_BIT)

#undef MN_SIGNED_HELPERS
#undef MN_UNSIGNED_HELPERS

#if defined(__FLT128_MANT_DIG__) && !defined(MN_SOFTWARE_F128)

typedef _Float128 mn_f128;

#define mn_f128_literal(native, high, low) (native)
#define mn_f128_initializer(native, high, low) native

static inline bool mn_f128_equal(mn_f128 one, mn_f128 two) {
    return one == two;
}

#define MN_F128_ARITHMETIC(name, operator) \
    static inline mn_f128 mn_runtime_f128_##name(mn_f128 left, mn_f128 right) { \
        return left operator right; \
    }

#define MN_F128_COMPARISON(name, operator) \
    static inline bool mn_runtime_f128_##name(mn_f128 left, mn_f128 right) { \
        return left operator right; \
    }

#define MN_F128_CONVERSIONS(name, type) \
    static inline mn_f128 mn_runtime_f128_from_##name(type value) { \
        return (mn_f128)value; \
    } \
    static inline type mn_runtime_f128_to_##name(mn_f128 value) { \
        return (type)value; \
    }

MN_F128_ARITHMETIC(add, +)
MN_F128_ARITHMETIC(subtract, -)
MN_F128_ARITHMETIC(multiply, *)
MN_F128_ARITHMETIC(divide, /)
MN_F128_COMPARISON(less_than, <)
MN_F128_COMPARISON(less_than_or_equal, <=)
MN_F128_COMPARISON(greater_than, >)
MN_F128_COMPARISON(greater_than_or_equal, >=)

static inline mn_f128 mn_runtime_f128_negate(mn_f128 value) {
    return -value;
}

MN_F128_CONVERSIONS(i8, int8_t)
MN_F128_CONVERSIONS(i16, int16_t)
MN_F128_CONVERSIONS(i32, int32_t)
MN_F128_CONVERSIONS(i64, int64_t)
MN_F128_CONVERSIONS(i128, int128_t)
MN_F128_CONVERSIONS(isize, ptrdiff_t)
MN_F128_CONVERSIONS(u8, uint8_t)
MN_F128_CONVERSIONS(u16, uint16_t)
MN_F128_CONVERSIONS(u32, uint32_t)
MN_F128_CONVERSIONS(u64, uint64_t)
MN_F128_CONVERSIONS(u128, uint128_t)
MN_F128_CONVERSIONS(usize, size_t)
MN_F128_CONVERSIONS(f32, float)
MN_F128_CONVERSIONS(f64, double)
#if defined(__FLT16_MANT_DIG__)
MN_F128_CONVERSIONS(f16, _Float16)
#endif

#undef MN_F128_ARITHMETIC
#undef MN_F128_COMPARISON
#undef MN_F128_CONVERSIONS

#else

typedef struct mn_f128 {
    uint128_t bits;
} mn_f128;

#define mn_f128_literal(native, high, low) ((mn_f128){ .bits = (uint128_t)(high) << 64 | (low) })
#define mn_f128_initializer(native, high, low) { .bits = (uint128_t)(high) << 64 | (low) }

static inline bool mn_f128_equal(mn_f128 one, mn_f128 two) {
    uint128_t const magnitude = ~(uint128_t)0 >> 1;
    uint128_t const infinity = (uint128_t)0x7fff << 112;
    if ((one.bits & magnitude) > infinity || (two.bits & magnitude) > infinity) return false;
    if (((one.bits | two.bits) & magnitude) == 0) return true;
    return one.bits == two.bits;
}

mn_f128 mn_runtime_f128_add(mn_f128 left, mn_f128 right);
mn_f128 mn_runtime_f128_subtract(mn_f128 left, mn_f128 right);
mn_f128 mn_runtime_f128_multiply(mn_f128 left, mn_f128 right);
mn_f128 mn_runtime_f128_divide(mn_f128 left, mn_f128 right);
bool mn_runtime_f128_less_than(mn_f128 left, mn_f128 right);
bool mn_runtime_f128_less_than_or_equal(mn_f128 left, mn_f128 right);
bool mn_runtime_f128_greater_than(mn_f128 left, mn_f128 right);
bool mn_runtime_f128_greater_than_or_equal(mn_f128 left, mn_f128 right);
mn_f128 mn_runtime_f128_negate(mn_f128 value);
mn_f128 mn_runtime_f128_from_i128(int128_t value);
int128_t mn_runtime_f128_to_i128(mn_f128 value);
mn_f128 mn_runtime_f128_from_u128(uint128_t value);
uint128_t mn_runtime_f128_to_u128(mn_f128 value);
mn_f128 mn_runtime_f128_from_f32(float value);
float mn_runtime_f128_to_f32(mn_f128 value);
mn_f128 mn_runtime_f128_from_f64(double value);
double mn_runtime_f128_to_f64(mn_f128 value);
#if defined(__FLT16_MANT_DIG__)
mn_f128 mn_runtime_f128_from_f16(_Float16 value);
_Float16 mn_runtime_f128_to_f16(mn_f128 value);
#endif

#define MN_F128_CONVERSIONS(name, type, wide) \
    static inline mn_f128 mn_runtime_f128_from_##name(type value) { \
        return mn_runtime_f128_from_##wide(value); \
    } \
    static inline type mn_runtime_f128_to_##name(mn_f128 value) { \
        return (type)mn_runtime_f128_to_##wide(value); \
    }

MN_F128_CONVERSIONS(i8, int8_t, i128)
MN_F128_CONVERSIONS(i16, int16_t, i128)
MN_F128_CONVERSIONS(i32, int32_t, i128)
MN_F128_CONVERSIONS(i64, int64_t, i128)
MN_F128_CONVERSIONS(isize, ptrdiff_t, i128)
MN_F128_CONVERSIONS(u8, uint8_t, u128)
MN_F128_CONVERSIONS(u16, uint16_t, u128)
MN_F128_CONVERSIONS(u32, uint32_t, u128)
MN_F128_CONVERSIONS(u64, uint64_t, u128)
MN_F128_CONVERSIONS(usize, size_t, u128)

#undef MN_F128_CONVERSIONS

#endif

static inline uintptr_t mn_align_address(uintptr_t address, size_t alignment) {
    return (address + alignment - 1) & ~(uintptr_t)(alignment - 1);
}

#endif
