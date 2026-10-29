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
    `and`, `any`, `as`, `break`, `case`, `catch`, `comptime`, `const`, `continue`, `defer`, `else`, `enum`, `errdefer`, `error`, `external`, `false`, `fn`, `for`, `if`, `import`, `in`, `instance`, `many`, `match`, `noop`, `null`, `or`, `orelse`, `return`, `Self`, `struct`, `true`, `try`, `typeclass`, `undefined`, `var`, `void`, `while`
- A reserved name can be the name of a function, struct, enum or error set, and a name after `::`, e.g. `fn match(pattern: []const u8) -> bool` called as `parser::match(pattern)`. Elsewhere it is reached through a path.

## Built-In Types

### Primitive Types

- Signed integers: `i8`, `i16`, `i32`, `i64`, `i128`, and `isize` which has the target's pointer size. They use two's complement.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`, `u128`, and `usize` which has the target's pointer size.
- Floating point numbers: `f16`, `f32`, `f64`, `f128` as defined for IEEE 754 binary formats.
- Booleans: `bool` with `true` and `false` as values.
- `void`: represents no result, i.e. the result of a function that returns nothing. It has no size and can be used anywhere a type can, except as the target of a multiple value pointer. `*void` is a pointer whose target is unknown (see Pointer Types).

### Pointer Types

- Monolith supports pointers. A pointer's type is the target type prefixed with `*`, e.g. `*bool`.
- Pointers either point to a single value or multiple. Pointers to multiple values use the `*many` prefix, e.g. `*many bool`.
- Read-only pointers are marked `const`, e.g. `*const bool`, `*many const i32`. Values cannot be modified through a read-only pointer.
- A pointer converts implicitly to a read-only pointer of the same kind, e.g. `*T` to `*const T`. The reverse is a compile-time error.
- Pointer arithmetic and indexing are supported only for multiple value pointers.
- Pointers are never allowed to be `null` but can be `undefined` (see Undefined).
- A pointer never holds address 0.
- `*void` is a pointer whose target is unknown, like C's `void *`. It cannot be dereferenced, indexed or moved. Any pointer except a pointer to a function converts implicitly to `*void`, or to `*const void` if it is read-only.

### Array Types

- An array holds a fixed number of values of the same type. Its type is the length in brackets followed by the element type, e.g. `[4]i32`.
- The length is a `usize` and must be known at compile time. A length of 0 is allowed.
- In the written type of a constant or variable, `_` takes the length from the value, e.g. `const primes: [_]i32 = {2, 3, 5}`. A value without a length, such as `undefined`, is a compile-time error.
- Only the outermost length can be left out, e.g. `[_][2]i32`.
- Elements are stored next to each other in memory, in order.
- Nested arrays read left to right, e.g. `[3][4]f32` is 3 arrays of 4 floats.
- Arrays are values. Assigning or passing an array copies all its elements.
- Arrays support indexing, starting at 0.
- `array.length` gives an array's length as a `usize`, known at compile time, e.g. `primes.length` is 3 for `const primes: [_]i32 = {2, 3, 5}`. It can be read but not assigned.

### Slice Types

- A slice is a multiple value pointer and a `usize` length. Its type is the element type prefixed with `[]`, e.g. `[]i32`.
- Read-only slices are marked `const`, e.g. `[]const i32`. Values cannot be modified through a read-only slice.
- A slice converts implicitly to a read-only slice, e.g. `[]T` to `[]const T`. The reverse is a compile-time error.
- A pointer to an array converts implicitly to a slice, with the length taken from the array type, e.g. `*[4]u8` to `[]u8`. A read-only pointer gives a read-only slice.
- Slices support indexing, starting at 0.
- `slice.pointer` gives a slice's multiple value pointer and `slice.length` its length. They can be read but not assigned.

### Optional Types

- An optional holds either a value or `null`. Its type is the value's type prefixed with `?`, e.g. `?i32`.
- Optional pointers have the same size as pointers, with `null` stored as address 0.
- A value of type `T` converts implicitly to `?T`, e.g. `var count: ?i32 = 5`. Deeper optionals are not wrapped implicitly, e.g. an `i32` does not convert to `??i32`.

### Tuple Types

- A tuple holds a fixed number of values whose types can differ. Its type lists the element types in brackets, e.g. `[i32, bool]`.
- Tuples are structural: two tuple types with the same element types in the same order are the same type.
- A tuple can have any number of elements, e.g. `[i32]` and `[]`. Brackets without a comma that are followed by a type are an array or a slice instead.
- Tuple types can span multiple lines. A comma after the last element type is allowed.
- Tuples support indexing with an index known at compile time, starting at 0.
- Indexing a tuple type with an index known at compile time gives the type of that element, e.g. `T[0]`.
- Every tuple type has an instance of `mn`'s typeclass `mn::Tuple`, which the compiler provides. A program cannot declare an instance of `mn::Tuple`. A parameter that requires it takes any tuple, e.g. `fn print(comptime format: []const u8, values: mn::Tuple)`, and code that depends on the tuple's elements is checked in each instance of the function.

### Function Types

- A function type is written like a function signature without parameter names, e.g. `fn(i32, bool) -> i32` (see Functions). Functions exist only at compile time.
- A pointer to a function is written without `const`, e.g. `*fn(i32, bool) -> i32`, since a function cannot be modified.

## Structs

- A struct is a type with named fields. It is declared with `struct`, its name, and its fields in an indented block, each with a name and a type, e.g. `struct Point:` followed by the fields `x: i32` and `y: i32`.
- A struct without fields has no block, e.g. `struct Marker`.
- Named structs are declared at the top level of a module.
- Field names must be unique within a struct.
- A field can have a default value after `=`, e.g. `count: u32 = 0`. The default must be known at compile time.
- Two structs with the same fields are different types.
- The compiler chooses the order of a struct's fields in memory.
- `external struct` declares a struct whose layout the language does not manage: its fields stay in declaration order, and the target the program is generated for decides their alignment and padding, e.g. `external struct Point:`.
- An external struct's fields are numbers, `bool`, pointers, optional pointers, function pointers, arrays of these and external structs.
- A struct cannot hold a value of its own type, directly or through other structs, arrays or tuples. A pointer to its own type is allowed, e.g. `next: ?*Node`.
- Structs are values. Assigning or passing a struct copies all its fields.
- `value.field` gives a field of a struct.
- A struct's block can also declare functions, e.g. `fn area(self: Self) -> i32: return self.side`. In the block, `Self` is the struct's type.
- A function in a struct's block is reached through the struct's name and `::`, e.g. `Square::new()`.
- A function whose first parameter's type is written `Self`, `*Self` or `*const Self` is a method. `value.name(arguments)` calls it with `value` as the first argument, e.g. `square.area()`.
- When the first parameter is a pointer, the call takes the value's address automatically, e.g. `counter.increment()` passes `&counter`. It is allowed only where `&` is allowed, and `*Self` needs a pointer that can modify the value (see Pointer Operations).
- A method can also be called on a pointer to the value, which is dereferenced automatically, one level only, e.g. `pointer.area()`. If the pointer's own type has a method with the same name, that method is called.
- A method is found by the exact type of the value.
- Two functions in a struct's block cannot have the same name, and they cannot have the name of a field.

## Enums

- An enum is a type whose value is one of several cases. It is declared with `enum`, its name, and its cases in an indented block, e.g. `enum Token:` followed by `number: i64`, `name: []const u8` and `end`.
- A case can carry a value of the type written after `:`. A case without a type carries no value.
- Case names must be unique within an enum.
- `Enum::case` gives a case without a value, e.g. `Token::end`. `Enum::case(value)` gives a case with its value, e.g. `Token::number(42)`.
- An enum has at least one case.
- Enums are declared at the top level of a module. An enum's block can also declare functions, as a struct's can. A function cannot have the name of a case.
- Enums are values. Assigning or passing an enum copies its case and its value.
- An enum's case cannot carry a value of the enum's own type, directly or through structs, other enums, arrays or tuples. A pointer to its own type is allowed, e.g. `node: *Tree`.

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

- Tuple literals are written as the tuple type followed by the elements in braces, e.g. `[i32, bool]{1, true}`.
- The type can be left out when it is known from the surrounding code, e.g. `{1, true}`.
- A tuple literal without a type whose type is not known from the surrounding code takes its type from its elements, e.g. `{count, flag}` is a `[i32, bool]` when `count` is an `i32` and `flag` is a `bool`.
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
- `const` followed by names in parentheses takes a tuple apart, e.g. `const (name, score) = pair`. Each name is a constant holding the element at its position.
- The number of names must match the number of elements of the tuple.
- A name `_` leaves its element without a name.
- `*name` holds a pointer to the element instead of a copy, e.g. `const (name, *score) = pair`. It is allowed only where `&` is allowed, and the pointer is read-only when the element cannot be modified (see Pointer Operations).
- `var` cannot take a tuple apart.
- Taking a tuple apart is allowed only inside functions.

## Expressions

### Operator Precedence

- Operators bind in the following order, from strongest to weakest:
    1. Postfix: calls, indexing `a[i]`, slicing `a[i..j]`, field access `a.b`, dereference `a.*`, optional unwrap `a.?`
    2. Prefix: `-`, `!`, `~`, `&`, `try`
    3. `*`, `/`, `%`
    4. `+`, `-`
    5. `<<`, `>>`
    6. `&`
    7. `^`
    8. `|`, `||`
    9. `!` between an error set and a type, e.g. `ParseError || FileError!Token` is `(ParseError || FileError)!Token`
    10. `orelse`, `catch`
    11. `==`, `!=`, `<`, `<=`, `>`, `>=`
    12. `and`
    13. `or`
- Operators on the same level are left-associative. Operands and arguments are evaluated left to right. Comparisons cannot be chained, e.g. `a < b < c` is a compile-time error.
- Parentheses group an expression.
- A range, `start..end` or `start..`, is a whole expression: `..` binds weaker than every operator, and a range cannot be an operand, e.g. `0..count + 1` ends at `count + 1`.

### Operand Types

- Unless stated otherwise, both operands of a binary operator must have the same type. Numbers of different types are never mixed implicitly.
- An unsuffixed literal takes its type from the surrounding code. As an operand, it takes the type the operator requires, e.g. `pointer + 1`, otherwise the type of the other operand, e.g. `count + 1`.

### Number Conversions

- A number converts implicitly to a type of the same kind that holds every value of its type, e.g. `u8` to `u32`, `u8` to `i16`, `i8` to `i64` and `f32` to `f64`. Operands of an operator are not converted.
- `mn::convert(T, value)` converts a number to the number type `T`, keeping its value, e.g. `mn::convert(u8, count)`.
- Converting an integer to an integer type that cannot hold its value is illegal behavior. When the value is known at compile time, it is a compile-time error.
- `mn::truncate(T, value)` converts an integer to a smaller integer type `T`, keeping only its low bits, e.g. `mn::truncate(i8, -1i32)` is `-1` and `mn::truncate(u8, 300u32)` is `44`.
- An integer converted to a float, and a float converted to a smaller float, round to the nearest representable value, ties to even. A float beyond the smaller type's largest finite value becomes an infinity.
- A float converted to an integer rounds toward zero. A NaN, an infinity, or a value the integer type cannot hold is illegal behavior.

### Pointer Casts

- `mn::cast(T, pointer)` gives the pointer as the pointer type `T`, with the same address. It changes the target type or switches between single and multiple value pointers, e.g. `mn::cast(*const Header, buffer.pointer)`.
- A cast that removes `const` is a compile-time error.
- An address that is not a multiple of the target type's alignment is illegal behavior.
- `mn::align(pointer, alignment)` moves a multiple value pointer forward to the next address that is a multiple of `alignment`, e.g. `mn::align(next, mn::alignment(Card))`. An alignment that is not a power of two is illegal behavior.

### Arithmetic Operators

- `+`, `-`, `*` and `/` work on integers and floats. `%` works on integers.
- A prefix `-` negates signed integers and floats. Negating an unsigned integer is a compile-time error.
- Integer division rounds toward zero. `%` gives the remainder of that division, which is either 0 or has the sign of the left operand, e.g. `-7 % 3` is `-1`.
- The remainder of the most negative value of a signed type divided by `-1` is 0.
- Integer overflow and division or remainder by zero are illegal behavior. When the operands are known at compile time, they are compile-time errors.
- Float operations follow IEEE 754, e.g. dividing a nonzero value by zero gives an infinity, and `0.0 / 0.0` gives NaN.

### Comparison Operators

- `==` and `!=` work on numbers, `bool`, types, pointers, arrays whose elements support them, optionals whose values support them, and enums and error sets whose values support them. Arrays are equal when all their elements are equal. Optionals are equal when both are `null` or both hold equal values. An optional can be compared with `null`.
- Two types are equal when they are the same type, e.g. `T == i32`.
- Slices cannot be compared with `==` and `!=`, since a slice points to its elements. Their bytes are compared with `mn::memory::equal` (see the standard library).
- Two enum values, or two errors, are equal when they are the same case and their values are equal. An error can be compared with a value of an error set combined from its set, e.g. `failure == ParseError::missing_end`.
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

- `&value` gives a pointer to a variable, constant, parameter, element, field or function. The pointer is read-only if the value cannot be modified.
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
- A statement that can never run is a compile-time error, e.g. one after a `return`. Conditions are not evaluated at compile time for this, e.g. `return 2` after `if T == i32: return 1` can run.

### Calls

- A call can be a statement. A call whose result is not `void` must be used or discarded.

### Discards

- `_ = value` discards a value. The value must be a call or the name of a parameter, local constant or variable.
- Discarding a call that returns `void`, or a name that is used elsewhere, is a compile-time error.
- Discarding a result that can hold an error is a compile-time error, e.g. `_ = parse(text)`.

### Assignments

- `target = value` assigns a value to a variable, or to a field, element or dereference that can be modified.
- The target is evaluated before the value, e.g. `locate()` runs before `f()` in `locate().x = f()`.
- `target op= value` is the same as `target = target op value` for `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<` and `>>`, except that the target is evaluated once, e.g. `items[next()] += 1` calls `next` once.

### Return

- `return value` ends the function and gives its result. A function without a return type uses `return` without a value.
- Every path through a function with a return type must end with a `return`. A path that never ends, such as an endless loop, needs none.

### Defer

- `defer` followed by a call, an assignment or a discard runs it when the enclosing block ends, e.g. `defer allocator.free(items)`.
- It runs on every way out of the block: reaching its end, `return`, `break`, `continue`, and an error returned through `try`.
- Deferred statements run in reverse order of their `defer`.
- A deferred statement's expressions are evaluated when it runs, not when `defer` is reached. With `return value`, the value is evaluated before the deferred statements run.
- `errdefer` works like `defer`, but runs only when the function returns an error after the `errdefer` was reached.
- A deferred statement cannot use `try`.

### If

- `if condition:` runs its block when the condition is true. The condition is a `bool`.
- `else:` runs its block when the condition is false. It is on the line after the `if` block, at the same indentation as `if`.
- `else if condition:` checks another condition when the previous ones are false, e.g. `if a:` followed by `else if b:` and `else:`.
- A condition that depends on a `type` or `comptime` parameter is evaluated at compile time, and only the block it chooses is checked and compiled, e.g. `if T == i32:` in a function with a `type T` parameter or `if format[0] == '{':` in a function with a `comptime format: []const u8` parameter.
- `if optional as name:` runs its block when the optional is not `null`, with `name` holding its value, e.g. `if found as card:`. `*name` holds a pointer to the value instead of a copy. The name can be used only in the block.

### While

- `while condition:` runs its block as long as the condition is true. The condition is a `bool`, evaluated before each run of the block.
- `while optional as name:` runs its block as long as the optional is not `null`, with `name` holding its value, e.g. `while queue.pop() as job:`. The optional is evaluated before each run of the block.
- `else:` runs its block when the condition is false, but not when the loop is left with `break` or `return`. It is on the line after the `while` block, at the same indentation as `while`. Its block is not part of the loop, so `break` and `continue` in it act on an enclosing loop.

### For

- `for name in sequence:` runs its block once for each element of the sequence, in order, with `name` holding the element. A sequence is an array, a slice, a pointer to an array, a range, an iterator or a tuple.
- `start..end` is a range of the `usize` values from `start` up to, but not including, `end`, e.g. `for index in 0..count:`. `start..` is a range without an end. A start after the end is illegal behavior.
- A range is also a value of the type `mn::Range`, which is an iterator over its values, e.g. as an argument.
- An iterator is a value whose type has an instance of `mn`'s typeclass `Iterator(I)`. Its `Element() -> type` gives the type of the elements, and its `next(iterator: *I) -> ?Element()` gives the elements until it returns `null`, e.g. `Iterator(Countdown)::Element()`. The loop calls `next` on its own copy of the iterator.
- An iterator's elements are tuples. A single name without parentheses takes apart a one-element tuple, e.g. `for count in countdown:` over an iterator whose `Element()` is `[u32]` gives each `u32`. A single name over elements with more than one value is a compile-time error.
- An iterator gives its elements by value, so `*name` over an iterator is a compile-time error.
- Over a tuple, the block is compiled once for each element, with `name` holding that element with its own type, e.g. `for value in values:`.
- The sequence is evaluated once, before the first run of the block. An array is not copied: the loop goes over the array itself.
- Names in parentheses take each element apart, e.g. `for (name, score) in pairs:`, and `*name` holds a pointer to each element instead of a copy, e.g. `for *card in cards:`, as in a constant declaration (see Variables and Constants).
- The names are constants and can be used only in the block.
- A name `_` leaves the element without a name, and the block cannot refer to it, e.g. `for _ in 0..3:`.
- An unused name is a compile-time error.
- `else:` runs its block when the sequence ends, but not when the loop is left with `break` or `return`. It is on the line after the `for` block, at the same indentation as `for`. Its block is not part of the loop, so `break` and `continue` in it act on an enclosing loop.

### Match

- `match value:` runs the branch that fits the value. Its branches are in an indented block, each written `case` with one or more cases and a block, e.g. `case end: noop`.
- `match` works on enums, error sets, results, optionals and integers.
- On an enum, a case is a case name. A branch can name the value a case carries, e.g. `case number(digits): total += digits`. `*digits` holds a pointer to it instead of a copy, as in a constant declaration (see Variables and Constants), and `_` leaves it without a name.
- On an error set, a case is an error. A branch can name an error through its enum or error set, e.g. `case ParseError::missing_end:`. This is needed when a combined error set has two cases with the same name.
- On a result, a case is an error, or the value's type, which takes the value, e.g. `case Token as token:` for a `ParseError!Token`.
- On an optional, a case is `null`, or the value's type, which takes the value, e.g. `case Card as card:` for a `?Card`.
- `as name` names the value, `as *name` holds a pointer to it instead of a copy, and a value's type without `as` leaves it without a name.
- On an integer, a case is a value known at compile time or a range, e.g. `case 0:` or `case 3..10:`. Cases cannot overlap.
- A branch with several cases separated by commas cannot name their values, e.g. `case name, end: noop`.
- The branches must cover every case exactly once. `else:` as the last branch covers the remaining cases, but never a result's or optional's value. A match on an integer needs `else:` unless its cases cover every value of the type.

### Break and Continue

- `break` leaves the innermost loop. `continue` ends the current run of its block: a `while` evaluates its condition again, and a `for` goes on with the next element.
- A loop can have a label, written `@` and a name before `while` or `for`, e.g. `@outer while running:`. `break @outer` and `continue @outer` act on that loop instead of the innermost one.
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
- A struct in an external function's parameters or return type, directly or through pointers or arrays, must be an external struct.
- `main` has no parameters and either no return type or a result without a value, e.g. `ParseError!void`. It cannot be called, used as a value or be external.
- An error that ends `main` writes the case's name to the standard error stream and ends the program with a nonzero status.

## Errors

- An error set is declared with `error`, its name, and its cases in an indented block, e.g. `error ParseError:` followed by `unexpected: [usize, usize]` and `missing_end`. Its cases are written, compared and matched like an enum's, e.g. `ParseError::missing_end`.
- An error set without cases has no block, e.g. `error Never`. A result with it cannot hold an error.
- Error sets are declared at the top level of a module.
- `One || Two` is an error set with the cases of both. Each case keeps the set that declares it, e.g. `ParseError::missing_end` is a case of `ParseError || FileError`. A value of an error set converts implicitly to an error set combined from it.
- `E!T` is a result: either a value of type `T`, or an error of the set `E`, e.g. `ParseError!Token`. `E!void` is a result without a value.
- A value of type `T` and a case of `E` convert implicitly to `E!T`, e.g. `return token` and `return ParseError::missing_end`.
- A result converts implicitly to a result of the same value type whose error set contains its own, e.g. `ParseError!Token` to `(ParseError || FileError)!Token`.
- `try result` gives the result's value, or returns its error from the function. The function's own result must be able to hold that error, e.g. through `ParseError || FileError`.
- `result catch fallback` gives the result's value, or `fallback` if it holds an error. `fallback` is evaluated only when needed.
- An error that is not caught during compile-time evaluation is a compile-time error.

## Modules

- Each `.mn` file is a module. Its path is its location in the program's directory without the extension, with `::` between names, e.g. `shapes/circle.mn` is `shapes::circle`.
- The program starts at the function `main` in `main.mn`.
- `mn` is the module that comes with the language. It holds the built-in functions, which the compiler provides, and the standard library. A program's own `mn.mn` or `mn` directory is a compile-time error.
- The built-in functions are `mn::size(T)` and `mn::alignment(T)`, which give a type's size and alignment in bytes as a `usize`, and `mn::convert(T, value)` and `mn::truncate(T, value)` (see Number Conversions), and `mn::cast(T, pointer)` and `mn::align(pointer, alignment)` (see Pointer Casts).
- `mn::comptime::error(message)` stops compilation with the message wherever the code containing it is checked, e.g. in the block a condition chooses at compile time. Like `return`, it ends its block, so a function returning a value needs no `return` after it. The message is a `[]const u8` known at compile time. The error shows the location of the call and each call that led to it.
- `mn::reflection` holds the built-in functions that inspect and build types. `mn::reflection::length(T)` gives a tuple type's number of elements as a `usize`. `mn::reflection::join(A, B)` gives the tuple type with the elements of `A` followed by those of `B`, e.g. `mn::reflection::join([Card], [usize])` is `[Card, usize]`.
- `import path` makes the last name of the path available in the module. The path names a directory, a module or a declaration in a module, e.g. `import mn::io::stdout` allows `stdout::write("hi")`.
- `import path as name` makes it available as `name` instead, e.g. `import mn::io::stdout as out`.
- An import that would make a reserved name available is a compile-time error, e.g. `import mn::comptime`.
- A path that starts with `::` names a top-level declaration of the current module, e.g. `::match(pattern)`.
- `import` is written at the top level of a module. The name it makes available cannot be the same as another import or top-level declaration of the module.
- Other modules can use every top-level declaration of a module.
- A module can be next to a directory with the same name, e.g. `shapes.mn` and `shapes/`. A declaration in the module with the same name as a module or directory in the directory is a compile-time error, e.g. `circle` in `shapes.mn` and `shapes/circle.mn`.

## Typeclasses

- A typeclass is declared with `typeclass`, its name, its parameters in parentheses, and its functions in an indented block, e.g. `typeclass Show(type T):` followed by `fn show(value: T, output: *Writer)`.
- A parameter is a type, e.g. `type T`, or a type constructor written with the types it takes, e.g. `type F(type)`.
- A parameter can require instances of other typeclasses, e.g. `typeclass Ord(type T: Eq):`. Every instance of `Ord(T)` then needs an instance of `Eq(T)`, and `Ord`'s functions can use `Eq`'s.
- A typeclass's function without a body only declares its signature. With a body, the body is its default implementation.
- A default implementation can use only the functions of its typeclass and of the typeclasses its parameters require.
- A typeclass's function can take its own `type` parameters, e.g. `fn map(type A, type B, value: F(A), function: *fn(A) -> B) -> F(B)`.
- An instance is declared with `instance`, the typeclass with its arguments, and its functions in an indented block, e.g. `instance Show(Card):`.
- An instance can cover every instantiation of a type through its own parameters, e.g. `instance(type A: Show) Show(List(A)):`.
- An instance defines each function of the typeclass with the typeclass's signature, with the arguments in place of the parameters. A function with a default implementation can be left out, and the default implementation is used.
- An instance can only define the typeclass's functions.
- Two instances of a typeclass cannot cover the same arguments, e.g. `instance Show(List(u8)):` next to `instance(type A: Show) Show(List(A)):`.
- Instances are declared at the top level of a module.
- A typeclass's functions can be called only in modules that declare or import the typeclass, e.g. `import shapes::Shape`.
- A typeclass's function is called through the typeclass, e.g. `Show::show(card, output)`, with the instance chosen by the types of the arguments. If more than one instance fits, the call is a compile-time error.
- A typeclass with its arguments names one instance, e.g. `Default(Card)::value()`. A function whose arguments do not decide the instance is called this way.
- A typeclass's function whose first parameter's type is a parameter of the typeclass, or a pointer to one, can also be called as a method, e.g. `card.show(output)` (see Structs).
- A function in a struct's block shadows a typeclass's function with the same name. A method that a type gets from two typeclasses cannot be called as `value.name()`.
- A parameter whose type is a typeclass with one parameter takes a value of any type with an instance, e.g. `fn report(value: Show)` called as `report(card)`. Each different type gets its own instance of the function.
- A `type` parameter can require instances, e.g. `fn parse(type T: Parse, text: []const u8) -> T`.
- A function with such parameters is checked once, before any instance, and can use them only through the functions of the typeclasses they require.

## Compile-Time Evaluation

- Everything a type depends on is evaluated at compile time, e.g. an array's length, a tuple's index or a struct field's default.
- A value is known at compile time when it is a literal, a constant or parameter known at compile time, or computed from these at compile time.
- `type` is the type of types. Types are values known at compile time, e.g. `const Number = i32`. A value whose type contains `type` exists only at compile time.
- Top-level constants are evaluated at compile time.
- A parameter written `type T` takes a type, e.g. `fn List(type T) -> type`. A parameter marked `comptime` takes a value known at compile time, e.g. `comptime format: []const u8`. Their arguments are evaluated at compile time.
- A parameter whose type is `any` takes a value of any type, e.g. `fn equal(one: any, two: any) -> bool`. `any` can only be the type of a parameter.
- A function gets its own instance for each different set of arguments to its `type` and `comptime` parameters, and for each different set of types of the arguments to its `any` parameters.
- A function with `type`, `comptime` or `any` parameters is checked for everything that does not depend on them, even if it is never called.
- `struct:` followed by an indented block, written like a struct's, is a struct without a name, e.g. `return struct:` followed by `items: []T`.
- A call evaluated at compile time gives the same result for the same arguments, e.g. `List(i32)` is the same type everywhere.
- Any function can be evaluated at compile time, unless it reaches an external function.
- Illegal behavior during compile-time evaluation is a compile-time error.
- Evaluation that does not end within a limit of steps, or nests calls beyond a limit, is a compile-time error.
