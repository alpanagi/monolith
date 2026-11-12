#include <string.h>

#include "monolith.h"

#if !defined(__FLT128_MANT_DIG__) || defined(MN_SOFTWARE_F128)

static uint128_t const mn_runtime_f128_sign = (uint128_t)1 << 127;
static uint128_t const mn_runtime_f128_magnitude = ~(uint128_t)0 >> 1;
static uint128_t const mn_runtime_f128_infinity = (uint128_t)0x7fff << 112;
static uint128_t const mn_runtime_f128_quiet = (uint128_t)1 << 111;
static uint128_t const mn_runtime_f128_hidden = (uint128_t)1 << 112;
static uint128_t const mn_runtime_f128_fraction = ((uint128_t)1 << 112) - 1;
static uint128_t const mn_runtime_f128_default_nan = ((uint128_t)1 << 127) | ((uint128_t)0x7fff << 112) | ((uint128_t)1 << 111);
static int32_t const mn_runtime_f128_bias = 16383;

static bool mn_runtime_f128_is_nan(uint128_t bits) {
    return (bits & mn_runtime_f128_magnitude) > mn_runtime_f128_infinity;
}

static uint128_t mn_runtime_f128_propagate(uint128_t left, uint128_t right) {
    uint128_t chosen = mn_runtime_f128_is_nan(left) ? left : right;
    if (mn_runtime_f128_is_nan(left) && mn_runtime_f128_is_nan(right)) {
        bool const is_left = (left & mn_runtime_f128_fraction) > (right & mn_runtime_f128_fraction);
        chosen = is_left ? left : right;
    }
    return chosen | mn_runtime_f128_quiet;
}

static uint128_t mn_runtime_f128_shift_right_sticky(uint128_t value, int32_t amount) {
    if (amount <= 0) return value;
    if (amount >= 128) return value != 0;
    return value >> amount | (uint128_t)((value << (128 - amount)) != 0);
}

static int32_t mn_runtime_f128_bit_length(uint128_t value) {
    uint64_t const high = (uint64_t)(value >> 64);
    if (high != 0) return 128 - __builtin_clzll(high);
    uint64_t const low = (uint64_t)value;
    if (low != 0) return 64 - __builtin_clzll(low);
    return 0;
}

static uint128_t mn_runtime_f128_round(
    int32_t exponent,
    uint128_t significand,
    int32_t fraction_bits,
    int32_t maximum_exponent
) {
    if (exponent >= maximum_exponent) return (uint128_t)maximum_exponent << fraction_bits;
    if (exponent < 1) {
        significand = mn_runtime_f128_shift_right_sticky(significand, 1 - exponent);
        exponent = 0;
    }
    uint32_t const rest = (uint32_t)(significand & 7);
    significand >>= 3;
    if (rest > 4 || (rest == 4 && (significand & 1) != 0)) significand += 1;
    if (exponent == 0) return significand;
    return ((uint128_t)(exponent - 1) << fraction_bits) + significand;
}

static uint128_t mn_runtime_f128_compose(
    int32_t power,
    uint128_t significand,
    int32_t fraction_bits,
    int32_t exponent_bits
) {
    int32_t const maximum_exponent = (1 << exponent_bits) - 1;
    int32_t const bias = maximum_exponent >> 1;
    int32_t const length = mn_runtime_f128_bit_length(significand);
    int32_t const width = fraction_bits + 4;
    if (length > width) {
        significand = mn_runtime_f128_shift_right_sticky(significand, length - width);
    } else {
        significand <<= width - length;
    }
    return mn_runtime_f128_round(power + length - 1 + bias, significand, fraction_bits, maximum_exponent);
}

static uint128_t mn_runtime_f128_compose_wide(int32_t power, uint128_t significand) {
    return mn_runtime_f128_compose(power, significand, 112, 15);
}

static int32_t mn_runtime_f128_unpack(uint128_t bits, uint128_t *significand) {
    int32_t const exponent = (int32_t)((bits & mn_runtime_f128_magnitude) >> 112);
    *significand = bits & mn_runtime_f128_fraction;
    if (exponent == 0) return 1;
    *significand |= mn_runtime_f128_hidden;
    return exponent;
}

static int32_t mn_runtime_f128_unpack_normalized(uint128_t bits, uint128_t *significand) {
    int32_t const exponent = mn_runtime_f128_unpack(bits, significand);
    int32_t const shift = 113 - mn_runtime_f128_bit_length(*significand);
    *significand <<= shift;
    return exponent - shift;
}

static uint128_t mn_runtime_f128_sum(uint128_t left, uint128_t right) {
    uint128_t left_magnitude = left & mn_runtime_f128_magnitude;
    uint128_t right_magnitude = right & mn_runtime_f128_magnitude;
    if (left_magnitude == mn_runtime_f128_infinity) {
        bool const is_opposite = ((left ^ right) & mn_runtime_f128_sign) != 0;
        if (right_magnitude == mn_runtime_f128_infinity && is_opposite) return mn_runtime_f128_default_nan;
        return left;
    }
    if (right_magnitude == mn_runtime_f128_infinity) return right;
    if (left_magnitude == 0) return right_magnitude == 0 ? left & right : right;
    if (right_magnitude == 0) return left;
    if (left_magnitude < right_magnitude) {
        uint128_t const bits = left;
        left = right;
        right = bits;
    }
    uint128_t left_significand;
    uint128_t right_significand;
    int32_t const left_exponent = mn_runtime_f128_unpack(left, &left_significand);
    int32_t const right_exponent = mn_runtime_f128_unpack(right, &right_significand);
    left_significand <<= 3;
    right_significand = mn_runtime_f128_shift_right_sticky(right_significand << 3, left_exponent - right_exponent);
    uint128_t significand = left_significand + right_significand;
    if (((left ^ right) & mn_runtime_f128_sign) != 0) {
        significand = left_significand - right_significand;
        if (significand == 0) return 0;
    }
    uint128_t const sign = left & mn_runtime_f128_sign;
    return sign | mn_runtime_f128_compose_wide(left_exponent - mn_runtime_f128_bias - 115, significand);
}

static void mn_runtime_f128_multiply_wide(uint128_t left, uint128_t right, uint128_t *high, uint128_t *low) {
    uint64_t const left_low = (uint64_t)left;
    uint64_t const left_high = (uint64_t)(left >> 64);
    uint64_t const right_low = (uint64_t)right;
    uint64_t const right_high = (uint64_t)(right >> 64);
    uint128_t const low_low = (uint128_t)left_low * right_low;
    uint128_t const low_high = (uint128_t)left_low * right_high;
    uint128_t const high_low = (uint128_t)left_high * right_low;
    uint128_t const high_high = (uint128_t)left_high * right_high;
    uint128_t const middle = (low_low >> 64) + (uint64_t)low_high + (uint64_t)high_low;
    *low = (middle << 64) | (uint64_t)low_low;
    *high = high_high + (low_high >> 64) + (high_low >> 64) + (middle >> 64);
}

static int mn_runtime_f128_order(uint128_t left, uint128_t right) {
    if (((left | right) & mn_runtime_f128_magnitude) == 0) return 0;
    if (left == right) return 0;
    bool const is_left_negative = (left & mn_runtime_f128_sign) != 0;
    bool const is_right_negative = (right & mn_runtime_f128_sign) != 0;
    if (is_left_negative != is_right_negative) return is_left_negative ? -1 : 1;
    bool const is_smaller = (left & mn_runtime_f128_magnitude) < (right & mn_runtime_f128_magnitude);
    return is_smaller != is_left_negative ? -1 : 1;
}

static uint128_t mn_runtime_f128_truncate_magnitude(uint128_t bits) {
    uint128_t const magnitude = bits & mn_runtime_f128_magnitude;
    if (magnitude > mn_runtime_f128_infinity) return 0;
    int32_t const exponent = (int32_t)(magnitude >> 112);
    if (exponent < mn_runtime_f128_bias) return 0;
    uint128_t const significand = (magnitude & mn_runtime_f128_fraction) | mn_runtime_f128_hidden;
    int32_t const shift = exponent - mn_runtime_f128_bias - 112;
    if (shift >= 16) return ~(uint128_t)0;
    if (shift >= 0) return significand << shift;
    return significand >> -shift;
}

static uint128_t mn_runtime_f128_widen(uint64_t bits, int32_t fraction_bits, int32_t exponent_bits) {
    int32_t const maximum_exponent = (1 << exponent_bits) - 1;
    int32_t const bias = maximum_exponent >> 1;
    uint128_t const sign = (uint128_t)(bits >> (fraction_bits + exponent_bits)) << 127;
    uint64_t const fraction = bits & (((uint64_t)1 << fraction_bits) - 1);
    int32_t const exponent = (int32_t)(bits >> fraction_bits) & maximum_exponent;
    if (exponent == maximum_exponent) {
        if (fraction == 0) return sign | mn_runtime_f128_infinity;
        uint128_t const payload = (uint128_t)fraction << (112 - fraction_bits);
        return sign | mn_runtime_f128_infinity | mn_runtime_f128_quiet | payload;
    }
    if (exponent == 0) {
        if (fraction == 0) return sign;
        return sign | mn_runtime_f128_compose_wide(1 - bias - fraction_bits, fraction);
    }
    uint64_t const significand = fraction | ((uint64_t)1 << fraction_bits);
    return sign | mn_runtime_f128_compose_wide(exponent - bias - fraction_bits, significand);
}

static uint64_t mn_runtime_f128_narrow(uint128_t bits, int32_t fraction_bits, int32_t exponent_bits) {
    uint64_t const maximum_exponent = ((uint64_t)1 << exponent_bits) - 1;
    uint64_t const sign = (uint64_t)(bits >> 127) << (fraction_bits + exponent_bits);
    uint128_t const magnitude = bits & mn_runtime_f128_magnitude;
    if (magnitude > mn_runtime_f128_infinity) {
        uint64_t const payload = (uint64_t)((magnitude & mn_runtime_f128_fraction) >> (112 - fraction_bits));
        uint64_t const quiet = (uint64_t)1 << (fraction_bits - 1);
        return sign | maximum_exponent << fraction_bits | quiet | payload;
    }
    if (magnitude == mn_runtime_f128_infinity) return sign | maximum_exponent << fraction_bits;
    if (magnitude == 0) return sign;
    uint128_t significand;
    int32_t const exponent = mn_runtime_f128_unpack(bits, &significand);
    int32_t const power = exponent - mn_runtime_f128_bias - 112;
    return sign | (uint64_t)mn_runtime_f128_compose(power, significand, fraction_bits, exponent_bits);
}

mn_f128 mn_runtime_f128_add(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) {
        return (mn_f128){ .bits = mn_runtime_f128_propagate(left.bits, right.bits) };
    }
    return (mn_f128){ .bits = mn_runtime_f128_sum(left.bits, right.bits) };
}

mn_f128 mn_runtime_f128_subtract(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) {
        return (mn_f128){ .bits = mn_runtime_f128_propagate(left.bits, right.bits) };
    }
    return (mn_f128){ .bits = mn_runtime_f128_sum(left.bits, right.bits ^ mn_runtime_f128_sign) };
}

mn_f128 mn_runtime_f128_multiply(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) {
        return (mn_f128){ .bits = mn_runtime_f128_propagate(left.bits, right.bits) };
    }
    uint128_t const sign = (left.bits ^ right.bits) & mn_runtime_f128_sign;
    uint128_t const left_magnitude = left.bits & mn_runtime_f128_magnitude;
    uint128_t const right_magnitude = right.bits & mn_runtime_f128_magnitude;
    if (left_magnitude == mn_runtime_f128_infinity || right_magnitude == mn_runtime_f128_infinity) {
        if (left_magnitude == 0 || right_magnitude == 0) return (mn_f128){ .bits = mn_runtime_f128_default_nan };
        return (mn_f128){ .bits = sign | mn_runtime_f128_infinity };
    }
    if (left_magnitude == 0 || right_magnitude == 0) return (mn_f128){ .bits = sign };
    uint128_t left_significand;
    uint128_t right_significand;
    int32_t const left_exponent = mn_runtime_f128_unpack(left.bits, &left_significand);
    int32_t const right_exponent = mn_runtime_f128_unpack(right.bits, &right_significand);
    uint128_t high;
    uint128_t low;
    mn_runtime_f128_multiply_wide(left_significand, right_significand, &high, &low);
    int32_t power = left_exponent + right_exponent - 2 * mn_runtime_f128_bias - 224;
    uint128_t significand = low;
    if (high != 0) {
        int32_t const shift = mn_runtime_f128_bit_length(high);
        significand = (high << (128 - shift)) | (low >> shift) | (uint128_t)((low << (128 - shift)) != 0);
        power += shift;
    }
    return (mn_f128){ .bits = sign | mn_runtime_f128_compose_wide(power, significand) };
}

mn_f128 mn_runtime_f128_divide(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) {
        return (mn_f128){ .bits = mn_runtime_f128_propagate(left.bits, right.bits) };
    }
    uint128_t const sign = (left.bits ^ right.bits) & mn_runtime_f128_sign;
    uint128_t const left_magnitude = left.bits & mn_runtime_f128_magnitude;
    uint128_t const right_magnitude = right.bits & mn_runtime_f128_magnitude;
    if (left_magnitude == mn_runtime_f128_infinity) {
        if (right_magnitude == mn_runtime_f128_infinity) return (mn_f128){ .bits = mn_runtime_f128_default_nan };
        return (mn_f128){ .bits = sign | mn_runtime_f128_infinity };
    }
    if (right_magnitude == mn_runtime_f128_infinity) return (mn_f128){ .bits = sign };
    if (right_magnitude == 0) {
        if (left_magnitude == 0) return (mn_f128){ .bits = mn_runtime_f128_default_nan };
        return (mn_f128){ .bits = sign | mn_runtime_f128_infinity };
    }
    if (left_magnitude == 0) return (mn_f128){ .bits = sign };
    uint128_t left_significand;
    uint128_t right_significand;
    int32_t exponent = mn_runtime_f128_unpack_normalized(left.bits, &left_significand);
    exponent -= mn_runtime_f128_unpack_normalized(right.bits, &right_significand);
    if (left_significand < right_significand) {
        left_significand <<= 1;
        exponent -= 1;
    }
    uint128_t quotient = 0;
    uint128_t remainder = left_significand;
    for (int32_t index = 115; index >= 0; index -= 1) {
        if (remainder >= right_significand) {
            remainder -= right_significand;
            quotient |= (uint128_t)1 << index;
        }
        remainder <<= 1;
    }
    if (remainder != 0) quotient |= 1;
    return (mn_f128){ .bits = sign | mn_runtime_f128_compose_wide(exponent - 115, quotient) };
}

bool mn_runtime_f128_less_than(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) return false;
    return mn_runtime_f128_order(left.bits, right.bits) < 0;
}

bool mn_runtime_f128_less_than_or_equal(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) return false;
    return mn_runtime_f128_order(left.bits, right.bits) <= 0;
}

bool mn_runtime_f128_greater_than(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) return false;
    return mn_runtime_f128_order(left.bits, right.bits) > 0;
}

bool mn_runtime_f128_greater_than_or_equal(mn_f128 left, mn_f128 right) {
    if (mn_runtime_f128_is_nan(left.bits) || mn_runtime_f128_is_nan(right.bits)) return false;
    return mn_runtime_f128_order(left.bits, right.bits) >= 0;
}

mn_f128 mn_runtime_f128_negate(mn_f128 value) {
    return (mn_f128){ .bits = value.bits ^ mn_runtime_f128_sign };
}

mn_f128 mn_runtime_f128_from_i128(int128_t value) {
    if (value == 0) return (mn_f128){ .bits = 0 };
    uint128_t const sign = value < 0 ? mn_runtime_f128_sign : 0;
    uint128_t const magnitude = value < 0 ? (uint128_t)0 - (uint128_t)value : (uint128_t)value;
    return (mn_f128){ .bits = sign | mn_runtime_f128_compose_wide(0, magnitude) };
}

int128_t mn_runtime_f128_to_i128(mn_f128 value) {
    uint128_t const magnitude = mn_runtime_f128_truncate_magnitude(value.bits);
    if ((value.bits & mn_runtime_f128_sign) != 0) return (int128_t)((uint128_t)0 - magnitude);
    return (int128_t)magnitude;
}

mn_f128 mn_runtime_f128_from_u128(uint128_t value) {
    if (value == 0) return (mn_f128){ .bits = 0 };
    return (mn_f128){ .bits = mn_runtime_f128_compose_wide(0, value) };
}

uint128_t mn_runtime_f128_to_u128(mn_f128 value) {
    uint128_t const magnitude = mn_runtime_f128_truncate_magnitude(value.bits);
    if ((value.bits & mn_runtime_f128_sign) != 0) return (uint128_t)0 - magnitude;
    return magnitude;
}

mn_f128 mn_runtime_f128_from_f32(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    return (mn_f128){ .bits = mn_runtime_f128_widen(bits, 23, 8) };
}

float mn_runtime_f128_to_f32(mn_f128 value) {
    uint32_t const bits = (uint32_t)mn_runtime_f128_narrow(value.bits, 23, 8);
    float result;
    memcpy(&result, &bits, sizeof result);
    return result;
}

mn_f128 mn_runtime_f128_from_f64(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    return (mn_f128){ .bits = mn_runtime_f128_widen(bits, 52, 11) };
}

double mn_runtime_f128_to_f64(mn_f128 value) {
    uint64_t const bits = mn_runtime_f128_narrow(value.bits, 52, 11);
    double result;
    memcpy(&result, &bits, sizeof result);
    return result;
}

#if defined(__FLT16_MANT_DIG__)

mn_f128 mn_runtime_f128_from_f16(_Float16 value) {
    uint16_t bits;
    memcpy(&bits, &value, sizeof bits);
    return (mn_f128){ .bits = mn_runtime_f128_widen(bits, 10, 5) };
}

_Float16 mn_runtime_f128_to_f16(mn_f128 value) {
    uint16_t const bits = (uint16_t)mn_runtime_f128_narrow(value.bits, 10, 5);
    _Float16 result;
    memcpy(&result, &bits, sizeof result);
    return result;
}

#endif

#endif
