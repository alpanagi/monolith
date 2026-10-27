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
    `and`, `break`, `const`, `continue`, `else`, `external`, `false`, `fn`, `for`, `if`, `impl`, `import`, `many`, `noop`, `null`, `or`, `orelse`, `return`, `Self`, `struct`, `trait`, `true`, `undefined`, `var`, `void`, `while`

## Built-In Types

### Primitive Types

- Signed integers: `i8`, `i16`, `i32`, `i64`, `i128`, and `isize` which has the target's pointer size. They use two's complement.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`, `u128`, and `usize` which has the target's pointer size.
- Floating point numbers: `f16`, `f32`, `f64`, `f128` as defined for IEEE 754 binary formats.
- Booleans: `bool` with `true` and `false` as values.
- `void`: represents no result, i.e. the result of a function that returns nothing. It has no size and can be used anywhere a type can.

### Pointer Types

- Monolith supports pointers. A pointer's type is the target type prefixed with `*`, e.g. `*bool`.
- Pointers either point to a single value or multiple. Pointers to multiple values use the `*many` prefix, e.g. `*many bool`.
- Read-only pointers are marked `const`, e.g. `*const bool`, `*many const i32`. Values cannot be modified through a read-only pointer.
- A pointer converts implicitly to a read-only pointer of the same kind, e.g. `*T` to `*const T`. The reverse is a compile-time error.
- Pointer arithmetic and indexing are supported only for multiple value pointers.
- Pointers are never allowed to be `null` but can be `undefined` (see Undefined).
- A pointer never holds address 0.

### Array Types

- An array holds a fixed number of values of the same type. Its type is the length in brackets followed by the element type, e.g. `[4]i32`.
- The length is a `usize` and must be known at compile time. A length of 0 is allowed.
- In the written type of a constant or variable, `_` takes the length from the value, e.g. `const primes: [_]i32 = {2, 3, 5}`. A value without a length, such as `undefined`, is a compile-time error.
- Only the outermost length can be left out, e.g. `[_][2]i32`.
- Elements are stored next to each other in memory, in order.
- Nested arrays read left to right, e.g. `[3][4]f32` is 3 arrays of 4 floats.
- Arrays are values. Assigning or passing an array copies all its elements.
- Arrays support indexing, starting at 0.

### Slice Types

- A slice is a multiple value pointer and a `usize` length. Its type is the element type prefixed with `[]`, e.g. `[]i32`.
- Read-only slices are marked `const`, e.g. `[]const i32`. Values cannot be modified through a read-only slice.
- A slice converts implicitly to a read-only slice, e.g. `[]T` to `[]const T`. The reverse is a compile-time error.
- A pointer to an array converts implicitly to a slice, with the length taken from the array type, e.g. `*[4]u8` to `[]u8`. A read-only pointer gives a read-only slice.
- Slices support indexing, starting at 0.

### Optional Types

- An optional holds either a value or `null`. Its type is the value's type prefixed with `?`, e.g. `?i32`.
- Optional pointers have the same size as pointers, with `null` stored as address 0.

### Tuple Types

- A tuple holds a fixed number of values whose types can differ. Its type lists the element types in parentheses, e.g. `(i32, bool)`.
- Tuples are structural: two tuple types with the same element types in the same order are the same type.
- A tuple has at least two elements.
- Tuples support indexing with an index known at compile time, starting at 0.

### Function Types

- A function type is written like a function signature without parameter names, e.g. `fn(i32, bool) -> i32` (see Functions). Functions exist only at compile time.
- A pointer to a function is written without `const`, e.g. `*fn(i32, bool) -> i32`, since a function cannot be modified.

## Structs

- A struct is a type with named fields. It is declared with `struct`, its name, and its fields in an indented block, each with a name and a type, e.g. `struct Point:` followed by the fields `x: i32` and `y: i32`.
- A struct without fields has no block, e.g. `struct Marker`.
- Structs are declared at the top level of a module.
- Field names must be unique within a struct.
- A field can have a default value after `=`, e.g. `count: u32 = 0`. The default must be known at compile time.
- Two structs with the same fields are different types.
- A struct cannot hold a value of its own type, directly or through other structs, arrays or tuples. A pointer to its own type is allowed, e.g. `next: ?*Node`.
- Structs are values. Assigning or passing a struct copies all its fields.
- `value.field` gives a field of a struct.

## Literals

### Primitive Literals

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

- A single ASCII character inside of single quotes, e.g. `'a'`.
- A character literal is an unsuffixed integer literal holding the value of the character, e.g. `'a'` is 97.
- Characters can be one of the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r` and `\0`.

### Array Literals

- Array literals are written as the array type followed by the elements in braces, separated by commas, e.g. `[3]i32{1, 2, 3}`.
- The type can be left out when it is known from the surrounding code, e.g. `{1, 2, 3}`.
- `_` takes the length from the literal, e.g. `[_]i32{1, 2, 3}`.
- A braced literal can initialize a read-only slice when its elements are known at compile time, e.g. `const primes: []const i32 = {2, 3, 5}`.
- The number of elements must match the array's length. A mismatch is a compile-time error.
- Array literals can span multiple lines.
- A comma after the last element is allowed.

### String Literals

- Strings are enclosed in double quotes and are always single-line strings.
- A string literal is a `[]const u8` holding its text encoded as UTF-8, including `\u{...}` escapes.
- Strings allow for the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.

### Tuple Literals

- Tuple literals are written as the tuple type followed by the elements in braces, e.g. `(i32, bool){1, true}`.
- The type can be left out when it is known from the surrounding code, e.g. `{1, true}`.
- Tuple literals can span multiple lines.
- A comma after the last element is allowed.

### Struct Literals

- Struct literals are written as the struct type followed by the field values in braces, e.g. `Point{x = 1, y = 2}`.
- The type can be left out when it is known from the surrounding code, e.g. `{x = 1, y = 2}`.
- Each value is given with its field name. Values without names are a compile-time error, e.g. `Point{1, 2}`.
- Every field without a default must be given, and each field at most once, in any order.
- Struct literals can span multiple lines. A comma after the last field is allowed.

### Null

- `null` is the value of an empty optional.

### Undefined

- `undefined` can be the initial value of a variable of any type whose value isn't known yet.
- Reading a variable on a path where it has not been assigned is a compile-time error.
- Reading memory that is `undefined` is illegal behavior.

## Variables and Constants

- Constants are declared with `const` and variables with `var`, followed by the name, an optional type after `:`, and the value after `=`, e.g. `const limit: u32 = 10`.
- A constant cannot be modified, including its elements and fields. Values it points to can be modified unless the pointer or slice is read-only. A variable can be modified.
- Without a written type, the type is taken from the value. A value with no type of its own, such as an unsuffixed literal, needs a written type, e.g. `var count = 1` is a compile-time error.
- A constant whose value is known at compile time can be used where a compile-time value is required, e.g. an array length.
- Any declaration can shadow a built-in type name. A local declaration can shadow any existing name, including earlier declarations in the same block.
- Two top-level declarations with the same name in one module are a compile-time error.
- Top-level declarations can be used anywhere in their module, before or after they are declared.
- An unused local constant or variable is a compile-time error.
- A variable that is never modified is a compile-time error.

## Expressions

### Operator Precedence

- Operators bind in the following order, from strongest to weakest:
    1. Postfix: calls, indexing `a[i]`, slicing `a[i..j]`, field access `a.b`, dereference `a.*`, optional unwrap `a.?`
    2. Prefix: `-`, `!`, `~`, `&`
    3. `*`, `/`, `%`
    4. `+`, `-`
    5. `<<`, `>>`
    6. `&`
    7. `^`
    8. `|`
    9. `orelse`
    10. `==`, `!=`, `<`, `<=`, `>`, `>=`
    11. `and`
    12. `or`
- Operators on the same level are left-associative. Operands and arguments are evaluated left to right. Comparisons cannot be chained, e.g. `a < b < c` is a compile-time error.
- Parentheses group an expression.

### Operand Types

- Unless stated otherwise, both operands of a binary operator must have the same type. Numbers of different types are never mixed implicitly.
- An unsuffixed literal takes its type from the surrounding code. As an operand, it takes the type the operator requires, e.g. `pointer + 1`, otherwise the type of the other operand, e.g. `count + 1`.

### Arithmetic Operators

- `+`, `-`, `*` and `/` work on integers and floats. `%` works on integers.
- A prefix `-` negates signed integers and floats. Negating an unsigned integer is a compile-time error.
- Integer division rounds toward zero. `%` gives the remainder of that division, which is either 0 or has the sign of the left operand, e.g. `-7 % 3` is `-1`.
- The remainder of the most negative value of a signed type divided by `-1` is 0.
- Integer overflow and division or remainder by zero are illegal behavior. When the operands are known at compile time, they are compile-time errors.
- Float operations follow IEEE 754, e.g. dividing a nonzero value by zero gives an infinity, and `0.0 / 0.0` gives NaN.

### Comparison Operators

- `==` and `!=` work on numbers, `bool`, pointers, arrays whose elements support them, and optionals whose values support them. Arrays are equal when all their elements are equal. Optionals are equal when both are `null` or both hold equal values. An optional can be compared with `null`.
- `<`, `<=`, `>` and `>=` work on numbers and multiple value pointers.
- A comparison gives a `bool`.

### Logical Operators

- `and`, `or` and `!` work on `bool`.
- `and` and `or` evaluate their right operand only when needed.

### Bitwise Operators

- `&`, `|`, `^` and `~` work on integers.
- `<<` and `>>` shift the left operand by the right operand, a `usize`.
- A shift has the type of its left operand. An unsuffixed literal on the left takes its type from the surrounding code, e.g. `const mask: u32 = 1 << n`.
- Bits shifted out are discarded. Shifting never overflows.
- `>>` keeps the sign of signed integers.

### Indexing

- `a[i]` gives the element at index `i` of an array, slice, multiple value pointer or tuple. The index is a `usize`.
- An index outside the length of an array or slice is illegal behavior. An index known at compile time outside an array's length is a compile-time error.
- A tuple's index must be known at compile time.
- Indexing a pointer to an array dereferences it automatically.

### Slicing

- `a[i..j]` gives a slice of the elements from index `i` up to, but not including, `j`. Either bound can be left out to start at 0 or end at the length, e.g. `a[..]`.
- Arrays, slices and multiple value pointers can be sliced. A multiple value pointer needs an end bound.
- An array can be sliced only if it is a variable, constant, element or field.
- Slicing a pointer to an array slices the array.
- Slicing gives a read-only slice if the elements cannot be modified, e.g. a constant array, a read-only slice or a read-only pointer.
- A bound outside the length, or a start after the end, is illegal behavior.

### Pointer Operations

- `&value` gives a pointer to a variable, constant, element, field or function. The pointer is read-only if the value cannot be modified.
- `pointer.*` gives the value a pointer points to.
- Reading or writing through a pointer to invalid memory, such as a dangling or `undefined` pointer, is illegal behavior.
- Field access dereferences a pointer automatically, one level only, e.g. `pointer.field`.
- Adding a `usize` to a multiple value pointer, or subtracting one from it, moves it by that many elements.
- Pointer arithmetic that gives address 0 is illegal behavior.
- Subtracting two multiple value pointers of the same type gives the number of elements between them as an `isize`.

### Optional Operations

- `value.?` gives the value inside an optional. If the optional is `null`, it is illegal behavior.
- `value orelse fallback` gives the value inside an optional, or `fallback` if the optional is `null`. `fallback` is evaluated only when needed.
- The fallback can itself be an optional, which makes the result an optional.

## Statements

### Blocks

- A block is a sequence of statements, one per line, indented deeper than the line that opens it. A block of one statement can follow the `:` on the same line, e.g. `fn one() -> u8: return 1`.
- A block cannot be empty. `noop` is a statement that does nothing, e.g. `while running(): noop`.
- A name declared in a block can be used from its declaration to the end of the block.
- A statement that can never run is a compile-time error, e.g. one after a `return`.

### Calls

- A call can be a statement. A call whose result is not `void` must be used or discarded.

### Discards

- `_ = value` discards a value. The value must be a call or the name of a parameter, local constant or variable.
- Discarding a call that returns `void`, or a name that is used elsewhere, is a compile-time error.

### Assignments

- `target = value` assigns a value to a variable, or to a field, element or dereference that can be modified.
- The target is evaluated before the value, e.g. `locate()` runs before `f()` in `locate().x = f()`.
- `target op= value` is the same as `target = target op value` for `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<` and `>>`, except that the target is evaluated once, e.g. `items[next()] += 1` calls `next` once.

### Return

- `return value` ends the function and gives its result. A function without a return type uses `return` without a value.
- Every path through a function with a return type must end with a `return`. A path that never ends, such as an endless loop, needs none.

### If

- `if condition:` runs its block when the condition is true. The condition is a `bool`.
- `else:` runs its block when the condition is false. It is on the line after the `if` block, at the same indentation as `if`.
- `else if condition:` checks another condition when the previous ones are false, e.g. `if a:` followed by `else if b:` and `else:`.

### While

- `while condition:` runs its block as long as the condition is true. The condition is a `bool`, evaluated before each run of the block.
- `else:` runs its block when the condition is false, but not when the loop is left with `break` or `return`. It is on the line after the `while` block, at the same indentation as `while`. Its block is not part of the loop, so `break` and `continue` in it act on an enclosing loop.
- `break` leaves the innermost loop. `continue` ends the current run of its block and evaluates the condition again.
- A loop can have a label before `while`, e.g. `outer: while running:`. `break outer` and `continue outer` act on that loop instead of the innermost one.
- A label cannot repeat the label of an enclosing loop. An unused label is a compile-time error.
- `break` and `continue` outside a loop are a compile-time error.

## Functions

- A function is declared with `fn`, its name, its parameters in parentheses, an optional return type after `->`, and its body after `:`, e.g. `fn add(a: i32, b: i32) -> i32: return a + b`.
- A function without a return type returns `void`.
- Each parameter has a name and a type. Parameter names must be unique.
- Parameters cannot be modified, including their elements and fields.
- A parameter named `_` has no name, and the body cannot refer to it.
- An unused parameter is a compile-time error.
- Arguments are given in the order of the parameters.
- `&name` gives a pointer to a function, e.g. to pass it as an argument. A pointer to a function is called like a function.
- `external fn` declares a function defined outside the program, without a body, e.g. `external fn write(text: []const u8)`.
- The program starts at `main`. It has no parameters and no return type, and cannot be called, used as a value or be external.
