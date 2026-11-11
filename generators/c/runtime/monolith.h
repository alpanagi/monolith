#ifndef MONOLITH_H
#define MONOLITH_H

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
MN_SIGNED_HELPERS(isize, ptrdiff_t, size_t, PTRDIFF_WIDTH)
MN_UNSIGNED_HELPERS(u8, uint8_t, 8)
MN_UNSIGNED_HELPERS(u16, uint16_t, 16)
MN_UNSIGNED_HELPERS(u32, uint32_t, 32)
MN_UNSIGNED_HELPERS(u64, uint64_t, 64)
MN_UNSIGNED_HELPERS(u128, uint128_t, 128)
MN_UNSIGNED_HELPERS(usize, size_t, SIZE_WIDTH)

#undef MN_SIGNED_HELPERS
#undef MN_UNSIGNED_HELPERS

static inline uintptr_t mn_align_address(uintptr_t address, size_t alignment) {
    return (address + alignment - 1) & ~(uintptr_t)(alignment - 1);
}

#endif
