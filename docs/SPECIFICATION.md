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
    `const`, `external`, `false`, `fn`, `for`, `impl`, `import`, `noop`, `return`, `Self`, `struct`, `trait`, `true`, `undefined`, `var`, `void`, `while`

## Built-In Types

### Primitives

- Signed integers: `i8`, `i16`, `i32`, `i64`, `i128`, and `isize` which has the target's pointer size.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`, `u128`, and `usize` which has the target's pointer size.
- Floating point numbers: `f16`, `f32`, `f64`, `f128` as defined for IEEE 754 binary formats.
- Booleans: `bool` with `true` and `false` as values.
- Characters: `char`, 4 bytes representing one Unicode scalar value.
- `void`: represents no result, i.e. the result of a function that returns nothing.

## Literals

### Primitives

**Integers**

- By default integers assume base 10. Other bases are supported with a prefix: hexadecimal (`0x`), octal (`0o`), and binary (`0b`).
- Negative values are written with a leading `-`, e.g. `-5`.
- Type suffixes can be added when the type is ambiguous after the value, e.g. `5u8`.
- The `_` separator between digits or between the last digit and a suffix is supported. A trailing or doubled separator is a compile-time error.
- Leading zeros are rejected. Zeros after a base prefix are allowed.
- A literal that does not fit into the type it is assigned to is a compile-time error.

**Floats**

- Floats are always base 10 and need at least one digit before the decimal point.
- Negative values are written with a leading `-`, e.g. `-12.3`.
- Floats can be written without decimal digits if these are 0, e.g. `5.`.
- Floats can be written in scientific notation using `e`/`E`, e.g. `2.5e-3`.
- Type suffixes can be added when the type is ambiguous after the value, e.g. `5.3f16`.
- The `_` separator between digits or between the last digit and a suffix is supported. A trailing or doubled separator is a compile-time error.
- Float literals round to the nearest representable value, ties to even. A literal beyond the type's largest finite value is a compile-time error.

**Boolean**

- Booleans only have two values `true` and `false`.

**Character**

- A single Unicode scalar value inside of single quotes, e.g. `'a'`.
- Characters can be one of the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.

**String**

- Strings are enclosed in double quotes and are always single-line strings.
- Strings allow for the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.
