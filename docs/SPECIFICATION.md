## File Format

- Monolith files use the `.mn` extension.
- Source files are UTF-8. Any other encoding is rejected. A UTF-8 BOM at the beginning of the file is ignored.
- Accepted line endings are `\n` and `\r\n`. A lone `\r` anywhere in the file is treated as an error.
- `Tab` characters are not supported anywhere in the source file. Any instance of a `tab` character is a compile-time error.
- Unicode direction control characters (`U+202A`–`U+202E`, `U+2066`–`U+2069`) are a compile-time error anywhere in the source file.

## Comments

- Comments start with `#` and continue until the end of the line. There is no multi-line comment form. 

## Indentation

- Lines are indented using only the space character `U+0020`.
- Blank lines without indentation are ignored.
- Lines that contain only indentation and/or comments are ignored.

## Identifiers

- Identifiers are allowed to contain only the following characters: `a-z`, `A-Z`, `0-9`, and `_`. They must not start with `0-9`.
- Identifiers are case-sensitive. By convention only types and type constructors start with a capital letter.
- The single character `_` is reserved and cannot be used as an identifier by the user.
- The following identifier names are reserved and cannot be used as identifiers by the user:
    `const`, `external`, `false`, `fn`, `for`, `impl`, `import`, `many`, `noop`, `null`, `return`, `Self`, `struct`, `trait`, `true`, `undefined`, `var`, `void`, `while`

## Built-In Types

### Primitives

- Signed integers: `i8`, `i16`, `i32`, `i64`, `i128`, and `isize` which has the target's pointer size.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`, `u128`, and `usize` which has the target's pointer size.
- Floating point numbers: `f16`, `f32`, `f64`, `f128` as defined for IEEE 754 binary formats.
- Booleans: `bool` with `true` and `false` as values.
- Characters: `char`, 4 bytes representing one Unicode scalar value.
- `void`: represents no result, i.e. the result of a function that returns nothing.

### Pointers

- Monolith supports pointers. A pointer's type is the target type prefixed with `*`, e.g. `*bool`.
- Pointers either point to a single value or multiple. Pointers to multiple values use the `*many` prefix, e.g. `*many bool`.
- Read-only pointers are marked `const`, e.g. `*const bool`, `*many const i32`. Values cannot be modified through a read-only pointer.
- Pointer arithmetic and indexing are supported only for multiple value pointers.
- Pointers are never allowed to be `null` but can be `undefined` (see literals).
- A pointer never holds address 0.

### Arrays

- An array holds a fixed number of values of the same type. Its type is the length in brackets followed by the element type, e.g. `[4]i32`.
- The length is a `usize` and must be known at compile time. Constants can be used as the length. A length of 0 is allowed.
- Elements are stored next to each other in memory, in order.
- Nested arrays read left to right, e.g. `[3][4]f32` is 3 arrays of 4 floats.
- Arrays are values. Assigning or passing an array copies all its elements.
- Arrays support indexing, starting at 0.

### Slices

- A slice is a multiple value pointer and a `usize` length. Its type is the element type prefixed with `[]`, e.g. `[]i32`.
- Read-only slices are marked `const`, e.g. `[]const i32`. Values cannot be modified through a read-only slice.
- Slices support indexing, starting at 0.

### Strings

- `string` is a read-only slice of `u8` that always holds valid UTF-8.

### Optionals

- An optional holds either a value or `null`. Its type is the value's type prefixed with `?`, e.g. `?i32`.
- Optional pointers have the same size as pointers, with `null` stored as address 0.

### Tuples

- A tuple holds a fixed number of values whose types can differ. Its type lists the element types in parentheses, e.g. `(i32, bool)`.
- Tuples are structural: two tuple types with the same element types in the same order are the same type.
- A tuple has at least two elements.
- Tuples support indexing with an index known at compile time, starting at 0.

## Literals

### Primitives

**Integers**

- By default integers assume base 10. Other bases are supported with a prefix: hexadecimal (`0x`), octal (`0o`), and binary (`0b`).
- Negative values are written with a leading `-`, e.g. `-5`.
- Type suffixes can be added when the type is ambiguous after the value, e.g. `5u8`.
- A `_` separator between digits or between the last digit and a suffix is supported. A trailing or doubled separator is a compile-time error.
- Leading zeros are rejected. Zeros after a base prefix are allowed.
- A literal that does not fit into the type it is assigned to is a compile-time error.

**Floats**

- Floats are always base 10 and need at least one digit on each side of the decimal point.
- Negative values are written with a leading `-`, e.g. `-12.3`.
- Type suffixes can be added when the type is ambiguous after the value, e.g. `5.3f16`.
- Floats can also be written in scientific notation using `e`/`E`, with or without a decimal point.
- The exponent can have a leading `-` or `+`, e.g. `2.5e-3`, `2.5e+3`.
- A `_` separator between digits or between the last digit and a suffix is supported. A trailing or doubled separator is a compile-time error.
- The `_` separator is also allowed between the digits of the exponent. A separator next to `.`, `e`/`E`, `-` or `+` is a compile-time error.
- Leading zeros are rejected, except in the exponent.
- An integer with a float suffix is a float, e.g. `5f32`. Base prefixes are not allowed, e.g. `0b1f32` is a compile-time error.
- Float literals round to the nearest representable value, ties to even. A literal beyond the type's largest finite value is a compile-time error.

**Boolean**

- Booleans only have two values `true` and `false`.

**Character**

- A single Unicode scalar value inside of single quotes, e.g. `'a'`.
- Characters can be one of the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.

### Arrays

- Array literals are written as the array type followed by the elements in braces, separated by commas, e.g. `[3]i32{1, 2, 3}`.
- The type can be left out when it is known from the surrounding code, e.g. `{1, 2, 3}`.
- `_` takes the length from the literal, e.g. `[_]i32{1, 2, 3}`.
- The number of elements must match the array's length. A mismatch is a compile-time error.
- Array literals can span multiple lines.
- A comma after the last element is allowed.

### Strings

- Strings are enclosed in double quotes and are always single-line strings.
- Strings allow for the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.

### Tuples

- Tuple literals are written as the tuple type followed by the elements in braces, e.g. `(i32, bool){1, true}`.
- The type can be left out when it is known from the surrounding code, e.g. `{1, true}`.

### Null

- `null` is the value of an empty optional.

### Undefined

- `undefined` can be the initial value of a variable of any type whose value isn't known yet.
- Reading a variable that is `undefined` before any assignment is a compile-time error.
- Reading memory that is `undefined` is illegal behaviour.
