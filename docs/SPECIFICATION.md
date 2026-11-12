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
- Identifiers are case-sensitive. By convention a capital letter names a shape: a type, a type constructor or a case, e.g. `Token`, `ArrayList(u8)` and `Token::Number`. A case with a value is a shape with parts, and a case without one is a marker whose type is its only value, as a struct without fields is, so every case of an enum and of an error set starts with a capital letter and capitalizes each word after the first instead of separating it, e.g. `Mode::Read`, `filesystem::Error::NotFound` and `File::Kind::SymbolicLink`. A lowercase name in a pattern is a name the pattern binds, e.g. `digits` in `case Number{ digits }`. The compiler does not check the convention.
- The single character `_` is reserved and cannot be used as an identifier by the user.
- The following identifier names are reserved and cannot be used as identifiers by the user:
    `and`, `any`, `as`, `break`, `case`, `catch`, `comptime`, `const`, `continue`, `defer`, `else`, `enum`, `errdefer`, `error`, `external`, `false`, `fn`, `for`, `if`, `import`, `in`, `inline`, `instance`, `many`, `match`, `noop`, `null`, `or`, `orelse`, `private`, `return`, `Self`, `struct`, `true`, `try`, `typeclass`, `undefined`, `var`, `void`, `while`, `with`
- A reserved name can be the name of a function, struct, enum or error set, and a name after `::`, e.g. `fn match(pattern: []const(u8)) -> bool` called as `parser::match(pattern)`. Elsewhere it is reached through a path.
- `module` is reserved only as the first name of a path, before `::`. A local variable, a parameter or a declaration can be named `module`, e.g. `fn load(module: Module)`, and `module.field` reads its field.

## Built-In Types

### Primitive Types

- Signed integers: `i8`, `i16`, `i32`, `i64`, `i128`, and `isize` which has the target's pointer size. They use two's complement.
- Unsigned integers: `u8`, `u16`, `u32`, `u64`, `u128`, and `usize` which has the target's pointer size.
- Floating point numbers: `f16`, `f32`, `f64`, `f128` as defined for IEEE 754 binary formats.
- Booleans: `bool` with `true` and `false` as values.
- `void`: represents no result, i.e. the result of a function that returns nothing. It has no size and can be used anywhere a type can, except in `*many(void)`. `*void` is a pointer whose target is unknown (see Pointer Types).

### Pointer Types

- Monolith supports pointers. A pointer's type is the target type prefixed with `*`, e.g. `*bool`. It points to a single value.
- `*many(T)` is a pointer to any number of values of type `T`, like a C pointer, e.g. `*many(bool)`. It has no length.
- Pointer arithmetic and indexing are supported only for `*many(T)`.
- `*T`, `*many(T)` and slices `[]T` are the pointer forms. `const(T)` as what a pointer form points to makes it read-only, e.g. `*const(bool)`, `*many(const(i32))` and `[]const(u8)`. Values cannot be modified through a read-only pointer.
- `const` and `many` are qualifiers written as keywords with the type in parentheses, not type constructors: there is no value of type `const(u8)` or `many(u8)`. `many(T)` is allowed only directly after `*`, and `const(T)` only directly after `*`, `[]` or `*many(`, inside `many` when both are used. Anywhere else they are a compile-time error whose message says where they are allowed, e.g. `var limit: const(u32)`, `*const(many(u8))` or `[]many(u8)`. Without parentheses they are a compile-time error too, e.g. `*const T`. A capitalized name with parentheses is a function that gives a type, e.g. `ArrayList(u8)`.
- A pointer converts implicitly to a read-only pointer of the same kind, e.g. `*T` to `*const(T)` and `*many(T)` to `*many(const(T))`. The reverse is a compile-time error.
- Pointers are never allowed to be `null` but can be `undefined` (see Undefined).
- A pointer never holds address 0.
- `*void` is a pointer whose target is unknown, like C's `void *`. It cannot be dereferenced, indexed or moved. Any pointer except a pointer to a function converts implicitly to `*void`, or to `*const(void)` if it is read-only.

### Array Types

- An array holds a fixed number of values of the same type. Its type is the length in brackets followed by the element type, e.g. `[4]i32`.
- The length is a `usize` and must be known at compile time. A length of 0 is allowed.
- In the written type of a constant or variable, `_` takes the length from the value, e.g. `const primes: [_]i32 = { 2, 3, 5 }`. A value without a length, such as `undefined`, is a compile-time error.
- Only the outermost length can be left out, e.g. `[_][2]i32`.
- Elements are stored next to each other in memory, in order.
- Nested arrays read left to right, e.g. `[3][4]f32` is 3 arrays of 4 floats.
- Arrays are values. Assigning or passing an array copies all its elements.
- Arrays support indexing, starting at 0.
- `array.length` gives an array's length as a `usize`, known at compile time, e.g. `primes.length` is 3 for `const primes: [_]i32 = { 2, 3, 5 }`. It can be read but not assigned.

### Slice Types

- A slice is a `*many(T)` and a `usize` length. Its type is the element type prefixed with `[]`, e.g. `[]i32`.
- A slice converts implicitly to a read-only slice, e.g. `[]T` to `[]const(T)`. The reverse is a compile-time error.
- A pointer to an array converts implicitly to a slice, with the length taken from the array type, e.g. `*[4]u8` to `[]u8`. A read-only pointer gives a read-only slice.
- Slices support indexing, starting at 0.
- `slice.pointer` gives a slice's `*many(T)` and `slice.length` its length. They can be read but not assigned.

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
- Every tuple type has an instance of the typeclass `mn::reflection::Tuple`, which the compiler provides. A program cannot declare an instance of `mn::reflection::Tuple`. A parameter that requires it takes any tuple, e.g. `fn print(comptime format: []const(u8), values: mn::reflection::Tuple)`, and code that depends on the tuple's elements is checked in each instance of the function.

### Function Types

- A function type is written like a function signature without parameter names, e.g. `fn(i32, bool) -> i32` (see Functions). Without parameters it has no parentheses, e.g. `fn -> i32` and `*fn`. Functions exist only at compile time.
- A pointer to a function is written without `const`, e.g. `*fn(i32, bool) -> i32`, since a function cannot be modified.
- A pointer to a function whose parameters have defaults has every parameter in its type, e.g. `*fn(i32, bool) -> i32` for `fn draw(width: i32, filled: bool = false) -> i32`, and a call through the pointer gives every argument.

## Structs

- A struct is a type with named fields. It is declared with `struct`, its name, and its fields in an indented block, each with a name and a type, e.g. `struct Point` followed by the fields `x: i32` and `y: i32`.
- Structs without fields are allowed, e.g. `struct Marker`.
- Named structs are declared at the top level of a module or in the block of a struct or an enum, including a struct without a name, to any depth. Inside the block and the blocks within it, a nested type is named by its short name, and elsewhere by its path through the types around it, e.g. `Directory::Entry` or `filesystem::Directory::Entry::init()`. In a nested type's block, `Self` is the nested type. A nested type in a struct without a name can use the parameters of the function that gives it, and each instance gets its own nested type.
- Within one block, the names of fields, cases, functions and nested types are unique.
- Field names must be unique within a struct.
- A field can have a default value after `=`, e.g. `count: u32 = 0`. The default must be known at compile time.
- Two structs with the same fields are different types.
- The compiler chooses the order of a struct's fields in memory.
- `inline struct` declares an inline struct, with `inline` where `external` stands, e.g. `inline struct Count` with the field `value: u32`. It has exactly one field, and a declaration with any other number of fields is a compile-time error at the declaration. Its field cannot be `own`, a compile-time error at the field, since the struct takes the ownership class of its field (see Ownership) and has nothing of its own to hold it with. `inline` and `external` together are a compile-time error. An inline struct is its own type when checked, e.g. a `Count` is not a `u32`, and a `Count` and a `u32` do not convert into each other implicitly. It is built and read as any struct, e.g. `Count{ value = 1 }` and `count.value`, its field can be `private`, and a conversion between it and the type of its field is an instance of `mn::convert::To`, e.g. `instance To([]const(u8), filesystem::Path)`. In the generated program it is its field, with no wrapper around it, so a `Count` is stored, passed and returned as a `u32`, e.g. `filesystem::Path` with its field `private bytes: []const(u8)` is its bytes and is passed by value as a slice is. The one exception is an inline struct whose field refers to the struct itself through a pointer, directly or through an optional, e.g. `inline struct Node` with `next: ?*Node`, which keeps its struct around the field in the generated program.
- A struct with one field that is not marked `inline` is an ordinary struct: it is generated as a struct with that one member and keeps every rule of a struct, e.g. `struct Index` with the one field `own records: HashMap(Path, Record)` is an owning type. An external struct with one field keeps the layout C gives it.
- `external struct` declares a struct whose layout the language does not manage: its fields stay in declaration order, and the target the program is generated for decides their alignment and padding, e.g. `external struct Point`.
- An external struct's fields are numbers, `bool`, pointers, optional pointers, function pointers, arrays of these and external structs.
- An external struct's fields cannot be private, since C shares its layout, e.g. `private x: i32` in `external struct Point` is a compile-time error that names the field and the struct.
- A struct cannot hold a value of its own type, directly or through other structs, arrays or tuples. A pointer to its own type is allowed, e.g. `next: ?*Node`.
- Structs are values. Assigning or passing a struct copies all its fields.
- `value.field` gives a field of a struct.
- A field written after `private` is usable as any other only in the module that declares its struct, e.g. `private own storage: []T` and `private count: usize` in `ArrayList(T)`. Another module reads it, sets it, takes its address or takes it apart with `own` only with `private` written before the field at the use, e.g. `list.private.count`, `list.private.count = 0`, `&list.private.count` or `own path.private.bytes` (see Privacy). Without the word each is a compile-time error that names the field and the struct and shows the form with the word, e.g. "`count` is a private field of `ArrayList(u8)`; write `list.private.count` to use it anyway". The module gives what other modules need through functions, e.g. `list.length()`. A field without `private` is usable everywhere.
- A struct's block can also declare functions, e.g. `fn area(self: Self) -> i32 = self.side`. In the block, `Self` is the struct's type.
- A function in a struct's block is reached through the struct's name and `::`, e.g. `Square::init()`.
- A leading `::` also names a function in the block of the expected enum or struct whose return type is that type, or an optional or a result of it, e.g. `Inventory{ cards = ::init(), seen = ::init() }`, `const list: ArrayList(u8) = ::init()`, `const deck: Deck = try ::load("cards")` or `mode == ::make()`. It is the same call as `Type::name(...)`, including with `with`, and the type is worked out through `try`, `catch` and `orelse`. Parentheses after the name always make it such a call, and braces always make it a case with its value (see Enums), e.g. `::load("cards")` beside `::Number{ 42 }`. A method, a function that returns another type, a case written with parentheses or a name the type does not have is a compile-time error.
- A function whose first parameter's type is written `Self`, `*Self` or `*const(Self)` is a method. `value.name(arguments)` calls it with `value` as the first argument, e.g. `square.area()`.
- When the first parameter is a pointer, the call takes the value's address automatically, e.g. `counter.increment()` passes `&counter`. It is allowed only where `&` is allowed, and `*Self` needs a pointer that can modify the value (see Pointer Operations).
- A method can also be called on a pointer to the value, which is dereferenced automatically, one level only, e.g. `pointer.area()`. If the pointer's own type has a method with the same name, that method is called.
- A method is found by the exact type of the value.
- A type's fields, the functions in its block and the functions of its instances share one set of names: two functions in its block cannot have the same name, and neither they nor a function of an instance for the type can have the name of a field, e.g. a field `hash` with an instance of `Hash`, which is a compile-time error at the instance. Functions of the same name from different typeclasses with instances for one type are allowed, but calling one as a method is then a compile-time error as ambiguous, and the call names the typeclass, e.g. `Iterator::next(&cursor)` instead of `cursor.next()`. Instances of one typeclass for a type, e.g. `Path`'s two instances of `To`, are resolved by their arguments.

## Enums

- An enum is a type whose value is one of several cases. It is declared with `enum`, its name, and its cases in an indented block, e.g. `enum Token` followed by `Number: i64`, `Name: []const(u8)` and `End`.
- A case can carry a value of the type written after `:`. A case without a type carries no value.
- Case names must be unique within an enum.
- `Enum::Case` gives a case without a value, e.g. `Token::End`. `Enum::Case{ value }` gives a case with its value, e.g. `Token::Number{ 42 }`, since braces enclose a value's parts in both directions and a case's value is a part of the enum's value (see Tuple Literals). A case whose value is a tuple takes the tuple's elements directly in the braces, e.g. `Shape::Point{ 1, 2 }` for `Point: [i32, i32]`, and any other case takes exactly one value, e.g. `::At{ { x = 1, y = 2 } }` for `At: Point`. Parentheses after a case are a compile-time error whose message shows the form in braces, e.g. `Token::Number(42)` or `::Number(42)`.
- A case built in an `own` place makes its value an `own` place too when the value's type can own, e.g. `const own data = Data::Bytes{ own bytes }` or `::Bytes{ try make(4) }`, and so does each element of a tuple-valued case, e.g. `::Pair{ own one, try make(4) }`. A value written with `own` makes the case hold an owned value, as an `own` field of a struct literal does, so it then goes only into an `own` place (see Ownership).
- The enum can be left out when it is known from the surrounding code, written with a leading `::`, e.g. `const mode: Mode = ::Write`, `open(path, { mode = ::Write })`, `mode == ::Write` or `::Number{ 42 }`. An optional or a result of an enum takes it too, e.g. `const mode: ?Mode = ::Write`. The name is looked up in the expected type, even where a local variable has the same name.
- A leading `::` where the type is not known is a compile-time error, e.g. `const mode = ::Read`. So is one where the type is not an enum or a struct, and an error is not written this way, e.g. `return ::OutOfMemory`.
- An enum has at least one case.
- Enums are declared where structs are (see Structs). An enum's block can also declare functions, as a struct's can. A function cannot have the name of a case.
- Enums are values. Assigning or passing an enum copies its case and its value.
- An enum's case cannot carry a value of the enum's own type, directly or through structs, other enums, arrays or tuples. A pointer to its own type is allowed, e.g. `Node: *Tree`.

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

- Array literals are written as the array type followed by the elements in braces, separated by commas, e.g. `[3]i32{ 1, 2, 3 }`.
- The type can be left out when it is known from the surrounding code, e.g. `{ 1, 2, 3 }`.
- `_` takes the length from the literal, e.g. `[_]i32{ 1, 2, 3 }`.
- A braced literal can initialize a read-only slice when its elements are known at compile time, e.g. `const primes: []const(i32) = { 2, 3, 5 }`.
- `{}` where a slice is expected gives a slice of length 0, read-only or not, e.g. `items = {}` for a field of type `[]T`. It needs no storage, since it has no elements to read or write.
- The number of elements must match the array's length. A mismatch is a compile-time error.
- An array literal in an `own` place makes each element whose type can own an `own` place too, e.g. `const own items: [2][]u8 = { own first, try make(4) }`. An element written with `own` makes the literal hold an owned value, so the literal then goes only into an `own` place (see Ownership).
- Array literals can span multiple lines.
- A comma after the last element is allowed.

### String Literals

- Strings are enclosed in double quotes and are always single-line strings.
- A string literal is a `[]const(u8)` holding its text encoded as UTF-8, including `\u{...}` escapes.
- Strings allow for the following escapes, `\n`, `\t`, `\\`, `\'`, `\"`, `\r`, `\0`, and `\u{...}`. `\u{...}` takes 1 to 6 hexadecimal digits and must be a Unicode scalar value.

### Tuple Literals

- Tuple literals are written as the tuple type followed by the elements in braces, e.g. `[i32, bool]{ 1, true }`.
- The type can be left out when it is known from the surrounding code, e.g. `{ 1, true }`.
- A tuple literal without a type whose type is not known from the surrounding code takes its type from its elements, e.g. `{ count, flag }` is a `[i32, bool]` when `count` is an `i32` and `flag` is a `bool`.
- A tuple literal in an `own` place makes each element whose type can own an `own` place too, e.g. `const own pair: [[]u8, []u8] = { own one, own two }`. An element written with `own` makes the literal hold an owned value, so the literal then goes only into an `own` place (see Ownership).
- Tuple literals can span multiple lines.
- A comma after the last element is allowed.
- Braces enclose a value's parts in both directions: a literal assembles the parts into the value, e.g. `{ name, score }`, and a pattern lays the value out into its parts, e.g. `const { name, score } = pair` (see Variables and Constants). A pattern appears only after `const`, `var`, `for` and `as` and in a `case`, never where a literal can. Names in parentheses in a pattern are a compile-time error whose message shows the form in braces.

### Struct Literals

- Struct literals are written as the struct type followed by the field values in braces, e.g. `Point{ x = 1, y = 2 }`.
- The type can be left out when it is known from the surrounding code, e.g. `{ x = 1, y = 2 }`.
- Each value is given with its field name, e.g. `x = 1`.
- A name alone stands for the field of the same name given that name as its value, e.g. `Point{ x, y }` is `Point{ x = x, y = y }`, and `own name` alone stands for `name = own name`, e.g. `Record{ hash, own path }`.
- A field given by a name alone follows every rule of the field written in full, e.g. `{ x, x = 1 }` gives `x` twice, and a name declared `own` alone for an `own` field needs `own` before it.
- Fields given by a name alone and fields written in full mix in one literal, in any order, e.g. `{ y = 0, x }`.
- Any other value without its field name is a compile-time error, e.g. `Point{ 1, 2 }`, `Point{ point.x, y }` or `Record{ own record.path }`.
- A name alone that is not a field of the struct is a compile-time error that names the struct and the field, as a field written in full is, e.g. "`Point` has no field `z`".
- A name alone stands for a field only where the literal is a struct literal. Braces whose type is a tuple or an array, or that have no type known from the surrounding code, take their elements by position, e.g. `{ x, y }` for a `[i32, i32]`, and a pattern takes only a tuple apart, e.g. `const { x, y } = pair`.
- Every field without a default must be given, and each field at most once, in any order.
- A literal of a struct with a private field is written as any other in the module that declares the struct. Elsewhere it names each private field with `private.` before it, by name and value or by a name alone, e.g. `const path: Path = { private.bytes = "cards/easy" }` or `{ private.count, size = 1 }`, while the fields without `private` are written as usual. A private field left out there, including through `{}` when every field has a default, or named without `private.`, is a compile-time error saying that the struct is built through its functions, naming one of them that gives the struct if there is one, and showing the form with the word, e.g. "`ArrayList(u8)` has a private field, so it is built through its functions, e.g. `ArrayList(u8)::init()`; write `{ private.storage = ... }` to build it anyway".
- An `own` field is an `own` place, e.g. `{ name = own name }`, and the literal then goes only into an `own` place when it holds an owned value. A field that is not `own` copies its value, e.g. a view in `{ name = own name, label = "first" }` (see Ownership).
- Struct literals can span multiple lines. A comma after the last field is allowed.

### Null

- `null` is the value of an empty optional.

### Undefined

- `undefined` can be the initial value of a variable of any type whose value isn't known yet.
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
- `const` or `var` followed by names in braces takes a tuple apart, e.g. `const { name, score } = pair` or `var { count, flag } = pair`. Each name holds the element at its position, a constant after `const` and a variable after `var`, e.g. `count += 1`. Names in parentheses are a compile-time error, e.g. `const (name, score) = pair`.
- `const own` or `var own` followed by names in braces takes an owned tuple apart as `as own` does (see Ownership), e.g. `const own { path, record } = own entry`: each owned element moves to its name, which is declared `own` and is a variable, and each other element is copied.
- The number of names must match the number of elements of the tuple.
- A name `_` leaves its element without a name.
- `*name` holds a pointer to the element instead of a copy, e.g. `const { name, *score } = pair`. It is allowed only where `&` is allowed, and the pointer is read-only when the element cannot be modified (see Pointer Operations).
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
- Inside any open `(`, as inside `{`, a line break does not end the statement, and the closing `)` says where it ends. This holds for every pair of parentheses, including those around a grouped expression, a call's arguments, a function's parameters, the arguments of a function that gives a type, `const(...)` and `many(...)`, a function type's parameters, and the header of an `if`, `while`, `for` or `case` with its statement on the same line. A line can break between any two tokens inside them, blank lines and lines that hold only a comment are allowed, and indentation inside them carries no meaning. After the closing `)` the statement goes on as on any line, e.g. `const own home = try (`, `process::environment::variable("HOME") orelse ""` and `).to(Path)` on three lines, `try filesystem::create_directory(`, `directory,`, `{ should_create_parents = true },` and `)` on four, or `fn create(`, `path: Path,`, `options: Options = {},` and `) -> Error!void` before the function's block.
- A `(` without its `)` is a compile-time error at the `(` when the file ends inside it or the error it leads to is on a later line, e.g. `run(` with `stop()` on the next line.
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

- `mn::cast(T, pointer)` gives the pointer as the pointer type `T`, with the same address. It changes the target type or switches between `*T` and `*many(T)`, e.g. `mn::cast(*const(Header), buffer.pointer)`.
- A cast can remove `const`, e.g. `mn::cast(*many(u8), items.pointer)` for an `items` of type `[]const(Card)`. Writing through it to memory that cannot be modified, such as a string literal, is illegal behavior.
- An address that is not a multiple of the target type's alignment is illegal behavior.
- `mn::align(pointer, alignment)` moves a `*many(T)` forward to the next address that is a multiple of `alignment`, e.g. `mn::align(next, mn::alignment(Card))`. An alignment that is not a power of two is illegal behavior.

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
- Two enum values, or two errors, are equal when they are the same case and their values are equal. An error can be compared with a value of an error set combined from its set, e.g. `failure == ParseError::MissingEnd`.
- `<`, `<=`, `>` and `>=` work on numbers and `*many(T)`s.
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

- `a[i]` gives the element at index `i` of an array, slice, `*many(T)` or tuple. The index is a `usize`.
- An index outside the length of an array or slice is illegal behavior. An index known at compile time outside an array's length is a compile-time error, and so is any index into an array of length 0.
- An index that is the variable of a loop over a range is a compile-time error when the range's end is known at compile time and greater than the length of the array or of the array behind a pointer, e.g. `value[index]` on a `[3]u8` in `for index in 0..5`. Only the variable itself counts, e.g. `value[index + 1]` is not checked. Slices are not checked.
- A tuple's index must be known at compile time.
- Indexing a pointer to an array dereferences it automatically.

### Slicing

- `a[i..j]` gives a slice of the elements from index `i` up to, but not including, `j`. Either bound can be left out to start at 0 or end at the length, e.g. `a[..]`.
- Arrays, slices and `*many(T)`s can be sliced. A `*many(T)` needs an end bound.
- An array can be sliced only if it is a variable, constant, element or field.
- Slicing a pointer to an array slices the array.
- Slicing gives a read-only slice if the elements cannot be modified, e.g. a constant array, a read-only slice or a read-only pointer.
- A bound outside the length, or a start after the end, is illegal behavior.

### Pointer Operations

- `&value` gives a pointer to a variable, constant, parameter, element, field or function. The pointer is read-only if the value cannot be modified.
- `pointer.*` gives the value a pointer points to.
- Reading or writing through a pointer to invalid memory, such as a dangling or `undefined` pointer, is illegal behavior.
- Field access dereferences a pointer automatically, one level only, e.g. `pointer.field`.
- Adding a `usize` to a `*many(T)`, or subtracting one from it, moves it by that many elements.
- Pointer arithmetic that gives address 0 is illegal behavior.
- Subtracting two `*many(T)`s of the same type gives the number of elements between them as an `isize`.

### Optional Operations

- `value.?` gives the value inside an optional. If the optional is `null`, it is illegal behavior.
- `value orelse fallback` gives the value inside an optional, or `fallback` if the optional is `null`. `fallback` is evaluated only when needed.
- The fallback can itself be an optional, which makes the result an optional.

## Statements

### Blocks

- A block is a sequence of statements, one per line, indented deeper than the line that opens it, e.g. `if count > limit` followed by an indented `trim(list)`. There is no `:` before a block.
- Only these lines can open a block: `fn`, `struct`, `enum`, `error`, `typeclass`, `instance`, `if`, `else`, `while`, `for`, `match`, `case`, and a line whose value is an `if`, a `match` or a `struct` without a name. A deeper line after any other line is a compile-time error. Lines continued inside open brackets are not affected.
- The block belongs to the statement that begins the line. When that statement cannot take a block, it belongs to the `if`, `match` or `struct` in its value, e.g. `const kind = match token` followed by its branches. A function whose body follows `=` has its body on the line, so the block belongs to the `if`, `match` or `struct` in that body, e.g. `fn is_whitespace(byte: u8) -> bool = match byte` followed by its branches.
- A header followed by a block runs to the end of its line and needs no parentheses, e.g. `while index < count`.
- A block of one statement can follow on the same line instead. Then the header of `if`, `while`, `for` and `case` is in parentheses and the statement follows it, e.g. `if (byte_count == 0) return null`. The statement follows `else` directly, e.g. `else 20`, and a function's body follows `=`, e.g. `fn one -> u8 = 1`. `struct`, `enum`, `error`, `typeclass`, `instance` and `match` always take an indented block.
- A block cannot be empty. `noop` is a statement that does nothing, e.g. `while (running()) noop`.
- A name declared in a block can be used from its declaration to the end of the block.
- A statement that can never run is a compile-time error, e.g. one after a `return`. Conditions are not evaluated at compile time for this, e.g. `return 2` after `if (T == i32) return 1` can run.

### Calls

- A call can be a statement. A call whose result is not `void` must be used or discarded.
- A comma after the last argument is allowed, e.g. `log(1, 2,)`.

### Discards

- `_ = value` discards a value, e.g. `_ = read_input(&buffer) orelse break`.
- Discarding a call that returns `void`, or a name that is used elsewhere, is a compile-time error.
- Discarding a result that can hold an error is a compile-time error, e.g. `_ = parse(text)`.

### Assignments

- `target = value` assigns a value to a variable, or to a field, element or dereference that can be modified.
- The target is evaluated before the value, e.g. `locate()` runs before `f()` in `locate().x = f()`.
- `target op= value` is the same as `target = target op value` for `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `<<` and `>>`, except that the target is evaluated once, e.g. `items[next()] += 1` calls `next` once.

### Return

- `return value` ends the function and gives its result. A function without a return type uses `return` without a value.
- In a function with a return type, the last line of the body can be an expression, which is the function's result, e.g. `fn add(a: i32, b: i32) -> i32` followed by an indented `a + b`. A `return` on the last line is also allowed.
- Reaching the end of a function's body gives `void`, so a path can end there only when `void` converts to the return type. Any other path must end with a `return` or with the body's last line giving the result. A path that never ends, such as an endless loop, needs none.
- In a function without a return type, the last line is a statement like any other.

### Defer

- `defer` followed by a call, an assignment or a discard runs it when the enclosing block ends, e.g. `defer allocator.free(items)`.
- It runs on every way out of the block: reaching its end, `return`, `break`, `continue`, and an error returned through `try`.
- Deferred statements run in reverse order of their `defer`.
- A deferred statement's expressions are evaluated when it runs, not when `defer` is reached. With `return value`, the value is evaluated before the deferred statements run.
- `errdefer` works like `defer`, but runs only when the block ends because the function returns an error.
- A deferred statement uses the allocator in effect where it is written (see Allocators).
- A deferred statement cannot use `try`.

### If

- `if condition` followed by a block runs the block when the condition is true. The condition is a `bool`. On one line it is written `if (condition) statement`.
- `else` followed by a block runs it when the condition is false. It is on the line after the `if` block, at the same indentation as `if`.
- When an `if` block is on the same line as `if`, its `else` or `else if` can follow on that line, e.g. `if (strict) 10 else 20`. It belongs to that `if`.
- An `if` whose block is on the same line cannot be in the same-line block of another `if`, an `else` or a loop, unless it is inside brackets opened within that block, e.g. `if (ready) if (valid) start() else stop()` is a compile-time error, while `else (if (huge) 3 else 2)` and `if (ready) run(if (fast) 1 else 2)` are allowed. A same-line block of `fn` or `case` takes no `else`, so an `if` in it is allowed, e.g. `case (0) if (flag) 1 else 2`.
- An `if` used as a value that is written on one line can be part of any expression, e.g. `total + (if (bonus) 10 else 0)`. Its last block extends to the end of the line or to the closing bracket around it.
- An `if` can be used as a value, e.g. `const limit: u32 = if (strict) 10 else 20`, or as the last line of a function with a return type. Each block's value is the expression on its last line. In an `own` place, each block's value is in that place, e.g. `own one` (see Ownership). An `if` used as a value needs `else`. When it starts after other code on a line, its `else` is on the line after its block, at that line's indentation.
- `else if condition` checks another condition when the previous ones are false, e.g. `if a` followed by `else if b` and `else`, each with a block.
- A condition that is known at compile time as a whole is evaluated at compile time, and only the block it chooses is checked and compiled, e.g. `if T == i32` in a function with a `type T` parameter or `if format[0] == '{'` in a function with a `comptime format: []const(u8)` parameter. Any other condition is evaluated at run time and every block is checked, e.g. `if T == i32 and flag` with a run-time `flag`.
- `if optional as name` runs its block when the optional is not `null`, with `name` holding its value, e.g. `if found as card`, or `if (found as card) show(card)` on one line. `*name` holds a pointer to the value instead of a copy. The name can be used only in the block.
- Names in braces after `as` take a value that is a tuple apart, as in a constant declaration (see Variables and Constants), e.g. `if found as { name, score }`. A name `_` leaves its element without a name, and `*name` holds a pointer to its element.
- `as own name` and `as own { name, other }` declare their names `own`, e.g. `if list.pop() as own record`. A name tested with `as own` is taken over at the test, written without a marker before it, e.g. `if found as own entry` (see Ownership).

### While

- `while condition` runs its block as long as the condition is true. On one line it is written `while (condition) statement`. The condition is a `bool`, evaluated before each run of the block.
- `while optional as name` runs its block as long as the optional is not `null`, with `name` holding its value, e.g. `while queue.pop() as job`. The optional is evaluated before each run of the block.
- Names in braces and `as own` work as in `if`, e.g. `while map.pop() as own { key, value }` or `while found as own entry`, which takes `found` over at each test, so the body gives it a new value before the next one.
- `else` runs its block when the condition is false, but not when the loop is left with `break` or `return`. It is on the line after the `while` block, at the same indentation as `while`. Its block is not part of the loop, so `break` and `continue` in it act on an enclosing loop.

### For

- `for name in sequence` runs its block once for each element of the sequence, in order, with `name` holding the element. On one line it is written `for (name in sequence) statement`, e.g. `for (card in cards) total += card.value`. A sequence is an array, a slice, a pointer to an array, a range or a value whose type has an instance of `mn::iterator::Iterable`.
- `for` over a tuple is a compile-time error, whatever its names are and whatever the tuple holds, e.g. `for value in values` or `for { one, two } in { first, second }` with a tuple.
- `start..end` is a range of the `usize` values from `start` up to, but not including, `end`, e.g. `for index in 0..count`. `start..` is a range without an end. A start after the end is illegal behavior.
- A `for` over a range whose bounds are both known at compile time and equal, or with the start after the end, is a compile-time error, e.g. `for index in 0..0`, or `for index in 0..N` for an instance where `N` is 0. A bound known only at run time can make a loop run zero times.
- A range is also a value of the type `mn::range::Range`, e.g. as an argument, and `Range` is `Iterable` through its cursor `mn::range::RangeCursor`, which holds the current position and the end and gives each `usize`.
- The typeclass `mn::iterator::Iterable(T)` gives a cursor for a value: its `Cursor() -> type` gives the cursor's type, and its `iterator(value: T) -> Cursor()` gives the cursor, e.g. `Iterable([]u32)::Cursor()` is `SliceCursor(u32)`. `for` over a value that is not an array, a slice, a pointer to an array or a written range calls `iterator` once, before the first run of the block, and goes over the cursor it gives. A value whose type has no instance of `Iterable` is a compile-time error, even if it has an instance of `Iterator`.
- A cursor is a value whose type has an instance of the typeclass `mn::iterator::Iterator(I)`. Its `Element() -> type` gives the type of the elements, and its `next(iterator: *I) -> ?Element()` gives the elements until it returns `null`, e.g. `Iterator(Countdown)::Element()`. A cursor whose type has no instance of `Iterator` is a compile-time error at the `for`.
- A type that is an `Iterator` is made `Iterable` by an instance that gives itself, e.g. `instance Iterable(Countdown)` with `fn Cursor() -> type = Countdown` and `fn iterator(countdown: Countdown) -> Cursor() = countdown`. The cursor is a copy, so the loop leaves the value it was given unchanged.
- A slice is `Iterable` without changing while it is gone over: `Iterable([]T)` gives an `mn::iterator::SliceCursor(T)`, which holds the slice and an index and gives a `*T` for each element, and `Iterable([]const(T))` gives an `mn::iterator::ConstSliceCursor(T)`, which gives a `*const(T)`. A `for` over an array, a slice, a pointer to an array or a written range behaves as going through these cursors would.
- A cursor's elements are tuples. A single name without braces takes apart a one-element tuple, e.g. `for count in countdown` over a cursor whose `Element()` is `[u32]` gives each `u32`. A single name over elements with more than one value is a compile-time error.
- An element that is a pointer, `*T` or `*const(T)`, is named with `*name` to keep the pointer, and with a plain `name` to copy the value out of it, for a single name and for each name in braces, e.g. `for *record in records`, `for value in numbers` or `for { *key, *value } in map.iterator()`. Copying out a value of an owning type is a compile-time error (see Ownership). `*name` for an element that is not a pointer is a compile-time error.
- The sequence is evaluated once, before the first run of the block. An array is not copied: the loop goes over the array itself.
- Names in braces take each element apart, e.g. `for { name, score } in pairs`, and `*name` holds a pointer to each element instead of a copy, e.g. `for *card in cards`, as in a constant declaration (see Variables and Constants).
- The names are constants and can be used only in the block.
- A name `_` leaves the element without a name, and the block cannot refer to it, e.g. `for _ in 0..3`.
- An unused name is a compile-time error.
- `else` runs its block when the sequence ends, but not when the loop is left with `break` or `return`. It is on the line after the `for` block, at the same indentation as `for`. Its block is not part of the loop, so `break` and `continue` in it act on an enclosing loop.

### Match

- `match value` runs the branch that fits the value. Its branches are in an indented block, each written `case` with one or more cases and a block, e.g. `case End` followed by an indented block, or `case (End) noop` on one line.
- `match` works on enums, error sets, results, optionals and integers.
- A `match` can be used as a value, e.g. `return match byte` followed by `case (' ', '\t') true` and `else false`. Each branch's value is the expression on its last line. In an `own` place, each branch's value is in that place, e.g. `else (_ as own rest) own rest` (see Ownership).
- Without a type expected from the surrounding code, every block of an `if` or `match` used as a value must give the same type, otherwise the type must be written, e.g. `const found: ?Card = match …`. A block that ends with `return`, `break`, `continue` or `mn::comptime::error` gives no value and fits any type.
- A `match` used as a value whose branches give values of `T`, results of `T` or errors gives a result of `T` combining those errors, e.g. `const file = try match open(path)` followed by `case (NotFound) create(path)` and `else (_ as rest) rest`. A branch that gives no value gives `void`, so it fits only when `T` is `void`. A value of any other type is a compile-time error. Branches that give only errors of different sets do not give a `T`, so the type must be written.
- On an enum, a case is a case name. A branch can name the value a case carries in braces after the case, e.g. `case (Number{ digits }) total += digits`, or `case Number{ digits }` before an indented block. `*digits` holds a pointer to it instead of a copy, as in a constant declaration (see Variables and Constants), and `_` leaves it without a name. A case's pattern mirrors its construction, `case Number{ digits }` for `::Number{ 42 }`, so a tuple-valued case lays its value out into its elements, e.g. `case Point{ x, y }` for `::Point{ 1, 2 }`, with one name for each element. Several names for any other case are a compile-time error. `own` before the names binds the value as owned names under the rules of `as own` (see Ownership), e.g. `case Record{ own record }` in a `match held` or `case Pair{ own key, own value }`. It is written before every name but `_`, or before none. Parentheses after a case in a pattern are a compile-time error whose message shows the form in braces, e.g. `case Number(digits)`.
- On an error set, a case is an error. A branch can name an error through its enum or error set, e.g. `case ParseError::MissingEnd`. This is needed when a combined error set has two cases with the same name.
- On a result, a case is an error, or the value's type, which takes the value, e.g. `case Token as token` for a `ParseError!Token`.
- On an optional, a case is `null`, or the value's type, which takes the value, e.g. `case Card as card` for a `?Card`.
- `as name` names the value, `as *name` holds a pointer to it instead of a copy, and a value's type without `as` leaves it without a name.
- Names in braces after `as` take a value that is a tuple apart, and `as own` declares the names `own`, as in `if`, e.g. `case [K, V] as own { key, value }` or `else _ as { key, value }`. A `match held` with a branch that binds `as own` takes `held` over at the `match`, written without a marker before it. `*name` among the names after `else` is a compile-time error.
- On a result or an error set, `as name` in a case that is an error names the error, e.g. `case (NotFound as failure) failure` or `case NotFound as failure` before an indented block. Its type holds only that case and any data the case carries. `as *name` is a compile-time error there.
- On an integer, a case is a value known at compile time or a range, e.g. `case 0` or `case 3..10`. Cases cannot overlap.
- A branch with several cases separated by commas cannot name their values, e.g. `case (Name, End) noop`.
- The branches must cover every case exactly once. `else` as the last branch covers whatever is left, including a result's or an optional's value, e.g. `else noop` ignores a value and errors together. An `else` with nothing left is a compile-time error. A match on an integer needs `else` unless its cases cover every value of the type.
- `else (_ as name)` on one line, and `else _ as name` before an indented block, name whatever `else` covers. `name` has the smallest type that covers what is left:
  - On a result, some errors handled give a result of the value and the remaining errors, every error handled gives the value, the value handled gives the remaining errors, and nothing handled gives the same result type.
  - On an error set, it is the remaining errors.
  - On an optional, `null` handled gives the value's type. Otherwise it is the optional.
  - On an enum, it is the enum, and on an integer, the integer's type.
- When only `void` is left there is nothing to name, and a name is a compile-time error. `else _ as *name` is a compile-time error.

### Break and Continue

- `break` leaves the innermost loop. `continue` ends the current run of its block: a `while` evaluates its condition again, and a `for` goes on with the next element.
- A loop can have a label, written `@` and a name before `while` or `for`, e.g. `@outer while running`. `break @outer` and `continue @outer` act on that loop instead of the innermost one.
- A label cannot repeat the label of an enclosing loop. An unused label is a compile-time error.
- `break` and `continue` outside a loop are a compile-time error.
- `return`, `break` and `continue` are also expressions that never produce a value, so they can be used wherever a value is expected, e.g. `const input = read_input(&buffer) orelse break`. Code that can never run because of them is a compile-time error, e.g. `count + return 5`.

## Functions

- A function is declared with `fn`, its name, its parameters in parentheses, an optional return type after `->`, and its body in an indented block or after `=` on the same line, e.g. `fn add(a: i32, b: i32) -> i32 = a + b`.
- A comma after the last parameter is allowed, e.g. `fn add(a: i32, b: i32,) -> i32 = a + b`.
- A function without parameters can leave out the parentheses, e.g. `fn main`.
- A function without a return type returns `void`.
- Each parameter has a name and a type. Parameter names must be unique.
- Parameters cannot be modified, including their elements and fields.
- A parameter named `_` has no name, and the body cannot refer to it.
- An unused parameter is a compile-time error.
- Arguments are given in the order of the parameters.
- A parameter can have a default value after `=`, e.g. `fn print(self: *const(Self), comptime format: []const(u8), values: Tuple = {}) -> !void`. The default must be known at compile time, as a field's default must, and is typed against the parameter's type as a field's default is against the field's, e.g. `{}` for a struct whose fields have defaults or for a tuple, `::Read` for an enum, or `0` for a number.
- Once a parameter has a default, every parameter after it has one too, e.g. `fn draw(width: i32 = 1, filled: bool)` is a compile-time error at `filled`.
- A call can leave out trailing arguments whose parameters have defaults, and the defaults are used, e.g. `stdout.print("done\n")` or `open(path)` for `fn open(path: Path, options: Options = {}) -> Error!File`. A call that gives them passes them as usual.
- A `type`, `comptime` or `own` parameter cannot have a default, and neither can a parameter whose type is a typeclass, since each call's argument chooses its type. The exception is `mn::reflection::Tuple`, whose default is a tuple literal that takes its type from its elements, e.g. `values: Tuple = {}` is the empty tuple `[]`.
- A parameter whose type depends on a `type` parameter of the function or of its typeclass or instance cannot have a default, e.g. `value: T = 0` with a `type T`.
- The exception is a parameter of a typeclass's function whose type is a parameter of the typeclass itself, e.g. `options: O = {}` in `fn parse(text: T, type U, options: O = {}) -> own !U` of `typeclass Parser(type T, type U, type O)`. Its default is typed in each instance against the type the instance gives the parameter, e.g. `{}` is an `IntegerOptions` in `instance Parser([]const(u8), i64, IntegerOptions)` and the empty tuple in `instance Parser([]const(u8), f64, [])`. An instance whose type cannot take the default is a compile-time error at the instance that names the typeclass, the parameter and the type, e.g. `options: u32` for `options: O = {}`. A type built from the parameter is not the parameter, e.g. `other: []T = {}` in a typeclass's function is a compile-time error.
- The argument of a `type` parameter can be written `_` when the type is known from the surrounding code, e.g. `const size: u8 = make(_)` for `fn make(type T) -> T`. The type is worked out from the function's return type and what the surrounding code expects, through `try`, `catch` and `orelse`, e.g. `const text: []u8 = try path.to(_)`.
- `_` where the type is not known is a compile-time error, e.g. `const text = try path.to(_)`. So is `_` as the argument of any other parameter.
- `&name` gives a pointer to a function, e.g. to pass it as an argument. A pointer to a function is called like a function.
- `external fn` declares a function defined outside the program, without a body, e.g. `external fn write(text: []const(u8))`.
- A struct in an external function's parameters or return type, directly or through pointers or arrays, must be an external struct.
- `inline fn` declares a function whose every call is replaced by its body, e.g. `inline fn is_answer(input: []const(u8)) -> bool`. It is called like any other function and behaves the same.
- An inline function that calls itself, directly or through other functions, is a compile-time error. Using one as a value is a compile-time error, e.g. `&is_answer`. An external function cannot be inline.
- `main` has no parameters. Its return type is left out, `void`, or a result without a value, e.g. `ParseError!void` or `!void`. It cannot be called, used as a value, be external, inline or private.
- An error that ends `main` writes the case's name to the standard error stream and ends the program with a nonzero status.

## Errors

- An error set is declared with `error`, its name, and its cases in an indented block, e.g. `error ParseError` followed by `Unexpected: [usize, usize]` and `MissingEnd`. Its cases are written, compared and matched like an enum's, e.g. `ParseError::MissingEnd` or `ParseError::Unexpected{ 3, 7 }`.
- An error set without cases has no block, e.g. `error Never`. A result with it cannot hold an error.
- Error sets are declared where structs are (see Structs), and their own blocks hold only cases.
- `One || Two` is an error set with the cases of both. Each case keeps the set that declares it, e.g. `ParseError::MissingEnd` is a case of `ParseError || FileError`. A value of an error set converts implicitly to an error set combined from it. The remaining errors of a `match` convert implicitly to any set that contains their cases.
- `E!T` is a result: either a value of type `T`, or an error of the set `E`, e.g. `ParseError!Token`. `E!void` is a result without a value.
- `!T` as the return type of a function with a body leaves out the error set, which the compiler infers: the combination of the sets of every error the body can return, through `try`, `return` of a case or `return` of a result, e.g. `fn load(path: []const(u8)) -> !usize`. A body that returns no error gives a set without cases. A function with `type`, `comptime` or `any` parameters or declared types gets a set for each instance, and `&name` gives a pointer whose type has the set written out.
- A typeclass's function can leave it out too, e.g. `fn write(writer: W, bytes: []const(u8)) -> !void`: each instance writes `!T` and gets its own set, and generic code gets the set of the instance it calls. An inferred set is allowed only there, not in external functions or in any other type. A call to a function whose set is being inferred together with the caller's, because they call each other directly or through other functions, adds no error, so their sets are the combination of the sets of every other error their bodies can return.
- A value of type `T` and a case of `E` convert implicitly to `E!T`, e.g. `return token` and `return ParseError::MissingEnd`.
- A result converts implicitly to a result of the same value type whose error set contains its own, e.g. `ParseError!Token` to `(ParseError || FileError)!Token`.
- `try result` gives the result's value, or returns its error from the function. The function's own result must be able to hold that error, e.g. through `ParseError || FileError`.
- `try` can be written directly before a `match` that starts a statement or its value, e.g. `const file = try match open(path)`. The `match` ends the statement. Anywhere else, a `match` after `try` is a compile-time error, e.g. `1 + try match open(path)`.
- An error handled by a `match` is not part of the remaining errors, so it does not enter an inferred set through them, e.g. after `case (NotFound) create(path)` and `else (_ as rest) rest`.
- `result catch fallback` gives the result's value, or `fallback` if it holds an error. `fallback` is evaluated only when needed.
- An error that is not caught during compile-time evaluation is a compile-time error.

## Modules

- Each `.mn` file is a module. Its path is its location in the program's directory without the extension, with `::` between names, e.g. `shapes/circle.mn` is `shapes::circle`.
- The program starts at the function `main` in `main.mn`.
- `mn` comes with the language. It holds the built-in functions, which the compiler provides, and the modules of the standard library, e.g. `mn::container`, `mn::memory` and `mn::iterator`, and nothing else: it is not a module of its own and has no other declarations. A declaration of the library is reached through its module, e.g. `mn::container::ArrayList(u8)` or `import mn::convert::To`. `import mn` makes the built-ins and the modules available and adds no module of the library by itself. A program's own `mn.mn` or `mn` directory is a compile-time error.
- A program is made of `main.mn` and every module that one of its modules names in a path, in an import or in its code, e.g. `mn::container` for `mn::container::ArrayList(u8)` after `import mn`, and `mn::range` for a module that writes a range. A path into a module that does not exist is a compile-time error that names the module, e.g. `mn::containers::ArrayList(u8)`.
- The built-in functions are `mn::size(T)` and `mn::alignment(T)`, which give a type's size and alignment in bytes as a `usize`, and `mn::convert(T, value)` and `mn::truncate(T, value)` (see Number Conversions), and `mn::cast(T, pointer)` and `mn::align(pointer, alignment)` (see Pointer Casts).
- `mn::math::add_wrapping(a, b)`, `mn::math::subtract_wrapping(a, b)` and `mn::math::multiply_wrapping(a, b)` take two integers of the same type and give a result of that type that wraps around on overflow instead of being illegal behavior, e.g. `math::add_wrapping(value, 1)` is 0 for a `u8` `value` of 255.
- `mn::comptime::error(message)` stops compilation with the message wherever the code containing it is checked, e.g. in the block a condition chooses at compile time. Like `return`, it ends its block, so a function returning a value needs no `return` after it. The message is a `[]const(u8)` known at compile time. The error shows the location of the call and each call that led to it.
- `mn::reflection` holds the built-in functions that inspect and build types, and the typeclass `Tuple` (see Tuple Types). `mn::reflection::length(T)` gives a tuple type's number of elements as a `usize`. `mn::reflection::join(A, B)` gives the tuple type with the elements of `A` followed by those of `B`, e.g. `mn::reflection::join([Card], [usize])` is `[Card, usize]`.
- `import path` makes the last name of the path available in the module. The path names a directory, a module, a declaration in a module or a type nested in one, e.g. `import mn::text` allows `text::strip(input)`, `import mn::process::stdout` allows `stdout` and `import mn::filesystem::Directory::Entry` allows `Entry`.
- `import path as name` makes it available as `name` instead, e.g. `import mn::process::stdout as out`.
- An import that would make a reserved name available is a compile-time error, e.g. `import mn::comptime` or `import shapes::module`.
- An import path that starts with `module::` is a compile-time error, since `module::` names only the current module, e.g. `import module::thing`. A directory named `module` has to be renamed.
- `module.mn` at the top of the program is a compile-time error, since the root of a program is `main.mn`.
- A path that starts with `module::` names a top-level declaration of the current module, e.g. `module::match(pattern)`, even where a local variable named `module` is in scope.
- `import` is written at the top level of a module. The name it makes available cannot be the same as another import or top-level declaration of the module.
- Other modules can use every top-level declaration of a module that is not private, and a private one only with `private` at the use (see Privacy).
- A directory's own module is the file `module.mn` in it, e.g. `shapes/module.mn` is `shapes`.
- A module next to a directory with its name is a compile-time error, e.g. `shapes.mn` and `shapes/`. A declaration in a directory's own module with the same name as a module or directory in the directory is a compile-time error, e.g. `circle` in `shapes/module.mn` and `shapes/circle.mn`.

### Privacy

- The module is the boundary of privacy, and `private` is its one marker. A declaration or a field without it is usable from every module, as is every instance.
- `private` is written before a top-level function, struct, enum, error set, typeclass or constant, including external and inline functions and inline structs, e.g. `private fn build_path(bytes: []const(u8))`, `private const separator: u8 = '/'` or `private external fn mn_runtime_io_write(descriptor: i32, bytes: []const(u8)) -> isize`, and before a function or a nested type in the block of a struct, an enum or a typeclass, e.g. `private fn grow(self: *Self)` or `private external struct RawEntry`.
- A private declaration is usable as any other only in the module that declares it, including its nested blocks, the functions of its types and its instances. Another module naming it, by path or by import, without crossing into it is a compile-time error that names it and its module and shows the form that crosses, e.g. `filesystem::build_path(text)` gives "`build_path` is private to `mn::filesystem`; write `filesystem::private::build_path` to use it anyway", `import mn::filesystem::build_path` shows `import mn::filesystem::private::build_path`, and `Box::make()` for a private `make` in `Box`'s block gives "`Box::make` is private to `things`; write `Box::private::make` to use it anyway".
- The word `private` written at a use crosses into a private declaration or field of another module, e.g. `filesystem::private::build_path(text)`. It is written between the `.` or `::` before the name and the name: before a field, e.g. `path.private.bytes`, `list.private.count = 0`, `&list.private.count` or `own path.private.bytes`; before a function in a type's block called as a method, e.g. `map.private.grow()`; before a function, constant or type of a module, e.g. `filesystem::private::separator`; before a function or nested type in a type's block, e.g. `Directory::private::RawEntry`, `Box::private::make()`, `Box(u8)::private::make()` or `::private::make()` where the type is expected; before a function of a typeclass, e.g. `Shape::private::area(square)` or `square.private.area()`; and before a field of a struct literal (see Struct Literals).
- An import crosses with the word on its line, e.g. `import mn::filesystem::private::build_path`, after which the module uses the name plainly, e.g. `build_path(text)`.
- `private` covers exactly the one name after it, so each private name in a path takes its own, e.g. `things::private::Hidden::private::make()` for a private `make` in a private `Hidden`, while `things::private::Hidden::make()` reaches a `make` that is not private.
- What a private declaration or field refuses to other modules the word allows, and nothing else: ownership, mutability and every other rule apply as they do without it, and the generated program is the same.
- The word must be true: `private` before a name that is not private, e.g. a field, a function, a module, a case or a built-in function, or before a private name inside the module that declares it, where nothing is crossed, is a compile-time error that names the name and says to remove the word, e.g. "`open` is not private, so `private` before it crosses nothing; remove the word" or "`helper` is private to this module, which uses it without `private`; remove the word".
- A function in the block of a private type is unreachable from other modules through a value even without `private`, since the type is and a method call names no type to cross, and the error names the type and shows the path that crosses, e.g. "`Hidden` is private to `things`; write `things::private::Hidden::get(...)` to use it anyway" for a call to a method of a value of a private type `Hidden`.
- A private function of a typeclass cannot be called from another module without the word, through the typeclass or as a method, e.g. "`Shape::area` is private to `things`; write `square.private.area()` to use it anyway". Instances in other modules still define it.
- A private type cannot appear in a declaration that is not private, wherever it is written and whether or not anything uses the declaration: as a parameter type, a requirement or a return type of a function, including generic functions with `type`, `comptime` or typeclass-typed parameters, of a function in the block of a struct or of a struct without a name, and of a function of a typeclass; as the type of a field that is not private of a struct, including a struct without a name and the types nested in it; as the value of a case of an enum; as the type of a constant, e.g. "`Slot` is private to this module and cannot appear in `value`, which is not" for `const value: Slot`; and as the type a constant names, e.g. `const Alias = Slot`. It counts directly or inside pointers, slices, arrays, optionals, results, error sets, tuples, function types or type arguments, and behind a constant that names it, e.g. `fn find(slot: Alias)` for `private const Alias = Slot`. A private typeclass counts as a private type. The check reads the types as written; a type that is not written, e.g. an inferred error set or the type of `const value = make()`, is not checked. The error is at that declaration, e.g. "`Slot` is private to this module and cannot appear in `find`, which is not" for `fn find(slot: *const(Slot))`. A private type function counts as a private type where it is applied, e.g. `Box(u8)` for a private `Box`. A private field and a private declaration can use a private type.
- `private` before an instance is a compile-time error, since instances are always visible wherever their typeclass and type are. So is `private` before `import`, inside a function body other than at a use, on an enum's case, a parameter, an argument of a call or a tuple's element, without a name after it, e.g. `path.private`, or written twice.
- `private` before a struct field hides the field from other modules (see Structs and Struct Literals). A struct with a private field is built, changed and ended through the functions of its module, or through its fields with the word.
- Privacy restricts what other modules' source may name and says nothing to the compiler: compile-time evaluation, reflection such as `mn::reflection::length`, default implementations of typeclasses and the generated program see every field and every declaration, and the generated program is the same with or without `private`.
- The built-in functions under `mn`, e.g. `mn::cast`, `mn::size`, `mn::convert`, `mn::reflection::join`, `mn::comptime::error` and `mn::math::add_wrapping`, are usable everywhere.

## Typeclasses

- A typeclass is declared with `typeclass`, its name, its parameters in parentheses, and its functions in an indented block, e.g. `typeclass Show(type T)` followed by `fn show(value: T, output: *Writer)`.
- A parameter is a type, e.g. `type T`, or a type constructor written with the types it takes, e.g. `type F(type)`.
- A parameter can require instances of other typeclasses, e.g. `typeclass Ord(type T: Eq)`. Every instance of `Ord(T)` then needs an instance of `Eq(T)`, and `Ord`'s functions can use `Eq`'s.
- A parameter can require several typeclasses, joined with `and`, e.g. `typeclass Rank(type T: Eq and Show)`. The parameter then needs an instance of each, and code that depends on it can use the functions of every typeclass named. The same holds for an instance's parameters, e.g. `instance(type K: Hash and Decode(_, D), type V: Decode(_, D), type D: Decoder) Decode(HashMap(K, V), D)`, for a function's `type` parameters, e.g. `fn make(type T: Default and Show) -> T`, and for the types a function declares, e.g. `fn(type T: Show and Size) report(value: T)`.
- A typeclass's function without a body only declares its signature. With a body, the body is its default implementation.
- A typeclass's function without parameters that gives a type stands for a type each instance chooses, e.g. `fn Cursor() -> type` in `typeclass Iterable(type T)`. The typeclass's other signatures use it as a call, e.g. `fn iterator(value: T) -> Cursor()`, and an instance writes the same call, which stands for the type its own function gives, e.g. `fn iterator(items: []T) -> Cursor() = { items = items, index = 0 }` with `fn Cursor() -> type = SliceCursor(T)`. `Iterable(T)::Cursor()` gives the type of one instance.
- A default implementation can call the functions of its typeclass, of the typeclasses its parameters require, and functions that do not depend on the typeclass's parameters, e.g. a function of its module.
- A typeclass's function can take its own `type` and `comptime` parameters and parameters whose type is a typeclass, e.g. `fn map(type A, type B, value: F(A), function: *fn(A) -> B) -> F(B)` or `fn print(writer: W, comptime format: []const(u8), values: mn::reflection::Tuple) -> !void`. Its default implementation and an instance's function get their own instance for each different set of arguments to them, as any function does (see Compile-Time Evaluation).
- A function's `type` parameter with the same name as a parameter of the typeclass is that parameter, e.g. `U` in `fn to(value: T, type U) -> !U` of `typeclass To(type T, type U)`. Its argument takes part in choosing the instance, e.g. `path.to([]u8)` calls `instance To(Path, []u8)`. An instance repeats the line, with `U` fixed by its header. A `type` parameter with a different name is the function's own, e.g. `allocate(allocator: *A, type T, count: usize)` is one function for every `T`.
- An instance is declared with `instance`, the typeclass with its arguments, and its functions in an indented block, e.g. `instance Show(Card)`.
- An instance can cover every instantiation of a type through its own parameters, e.g. `instance(type A: Show) Show(ArrayList(A))`.
- An instance can cover every length of an array with a parameter written `comptime N: usize`, e.g. `instance(type A: Show, comptime N: usize) Show([N]A)` covers `[16]u8` and `[2][3]u8`. In the instance's signatures it is written alone as a length. In its functions it is a value known at compile time, e.g. `if N <= 8` or `for index in 0..N`. Each length gets its own instance of the functions, which are checked when they are used.
- A parameter of an instance that its arguments do not decide makes a call to it a compile-time error.
- An instance defines each function of the typeclass with the typeclass's signature, with the arguments in place of the parameters. A function with a default implementation can be left out, and the default implementation is used.
- In an instance's block, `Self` is the type the instance is for, the first argument of the typeclass as the instance's header writes it, with the instance's parameters, e.g. `fn hash(path: *const(Self)) -> u64` in `instance Hash(Path)`, or `ArrayList(A)` in `instance(type A: Show) Show(ArrayList(A))`. It is that type exactly as if it were written out, e.g. `Self::init()` or `-> own !Self`.
- In an instance for a type constructor, e.g. `instance Mapper(Box)`, `Self` is not a type, and using it is a compile-time error.
- A typeclass's own block has no `Self`, and its functions name its parameters instead, e.g. `fn hash(value: *const(T)) -> u64` in `typeclass Hash(type T)`.
- A default of a parameter of a typeclass's function applies to each instance that writes none for that parameter, so a call through the typeclass or through the instance can leave the argument out, e.g. `fn show(value: T, output: *Writer, options: Options = {})`. An instance that writes a default writes the same value, and a parameter without a default in the typeclass has none in the instance.
- A default whose type is a parameter of the typeclass (see Functions) is the same for every instance as written and is typed against each instance's type, so an instance that writes it writes the value against its own type, e.g. `options: IntegerOptions = {}`, and an instance that writes none takes it as for any default. A call that leaves the argument out, or gives one without a type of its own, e.g. `{ base = ::Base16 }`, chooses the instance by its other arguments and type arguments, and the argument then takes its type from the chosen instance, e.g. `"ff".parse(u8, { base = ::Base16 })`. An argument with a type of its own takes part in the choice as usual, e.g. `Parser::parse(text, u8, IntegerOptions{})`. Two instances that differ only in that parameter both fit a call that leaves it out, which is then a compile-time error as any use that two instances fit and neither is more specific.
- An instance's function can take `*const(W)` where the typeclass says `*W`, e.g. `fn write(_: *const(Stdout), bytes: []const(u8)) -> !void` for `fn write(writer: *W, bytes: []const(u8)) -> !void`. An instance whose functions that take such a pointer all take it read-only only reads, and the default implementations it leaves out take a read-only pointer too.
- An instance can only define the typeclass's functions.
- Two instances of a typeclass may both fit a use. One instance is more specific than another when its header is the other's header with the other's parameters filled in, e.g. `instance Show(ArrayList(u8))` is more specific than `instance(type A: Show) Show(ArrayList(A))`, and `instance(type W: Writer) Encode(WallTime, yaml::YamlEncoder(W))` is more specific than `instance(type E: Encoder) Encode(WallTime, E)`. Requirements take no part in the comparison. The instances can be declared in any modules.
- Two instances of a typeclass with the same header, up to the names of their parameters, are a compile-time error at the second, whatever their requirements, e.g. `instance(type A) Show([]A)` next to `instance(type B: Eq) Show([]B)`.
- Instances are declared at the top level of a module.
- A typeclass's functions can be called only in modules that declare or import the typeclass, e.g. `import shapes::Shape`.
- A typeclass's function is called through the typeclass, e.g. `Show::show(card, output)`, with the instance chosen by the types of the arguments and by a type argument for a parameter of the typeclass. If no instance fits, the call is a compile-time error. An instance whose requirements the types do not meet does not fit.
- If several instances fit, the most specific is chosen, the one more specific than each of the others, e.g. `Show::show(list)` for an `ArrayList(u8)` calls `instance Show(ArrayList(u8))` and for an `ArrayList(u16)` calls `instance(type A: Show) Show(ArrayList(A))`. If two fit and neither is more specific, the use is a compile-time error that names both instances and their modules, e.g. "more than one instance fits and neither is more specific: `Pair(A, u8)` in `main` and `Pair(u8, B)` in `main`" for `Pair::pair(one, two)` with two `u8`s.
- The same choice is made wherever an instance is chosen: for a call through the typeclass or a named instance, for a method call, for a requirement, and for generic code once it is instantiated for concrete types, e.g. `value.show()` in `fn(type T: Show) display(value: T)` calls `instance Show(ArrayList(u8))` in the instance of `display` for an `ArrayList(u8)`. Generic code checked before any instance sees only its requirements.
- An instance is looked up for the exact types first. If none fits, a writable slice or pointer also fits an instance for the read-only form, since read-only access asks for less, e.g. `instance Show([]const(u8))` takes a `[]u8`, and its functions see the `[]const(u8)`. It applies only to the outermost slice or pointer, e.g. `[][]u8` does not fit `[][]const(u8)`, and not to a parameter of the typeclass chosen by a type argument. A read-only value does not fit an instance for the writable form, e.g. `instance Show([]u8)` does not take a `[]const(u8)`. The most specific instance is chosen within each of these two steps, so an instance that fits the exact types is chosen over a more specific one for the read-only form, e.g. `instance(type A) Show([]A)` over `instance Show([]const(u8))` for a `[]u8`.
- A typeclass with its arguments names one instance, e.g. `Default(Card)::value()`. A function whose arguments do not decide the instance is called this way.
- A typeclass's function whose first parameter's type is the typeclass's first parameter, the one `Self` stands for in an instance, or a pointer to it, can also be called as a method, e.g. `card.show(output)` (see Structs). A function whose first parameter is a later parameter of the typeclass is called through the typeclass only, e.g. `Decode(T, D)::decode(&decoder)` for `fn decode(decoder: *D) -> own !T` in `typeclass Decode(type T, type D: Decoder)`, so it is never a method of the decoder.
- When no function fits the type of a method call's receiver and a typeclass's function fits a pointer to it, the call takes the receiver's address, e.g. `path.hash()` for a `Path` named `path`, whose instance of `Hash` takes `*const(Path)`. A string literal is static data, so it may be such a receiver when the first parameter is `*const(Self)`, e.g. `try "alpha".clone()`, and the argument of a parameter of type `*const(T)`; the pointer is to the static string and never dangles. `&"alpha"` written out stays a compile-time error, and other temporaries, e.g. struct and array literals and the results of calls, are not addressable.
- A function whose receiver parameter is `own` takes over its receiver, so a call to it as a method hands the receiver on with `own` as the call's first argument, e.g. `list.to_owned(own)` (see Ownership).
- A function in a struct's block shadows a typeclass's function with the same name. A method that a type gets from two typeclasses cannot be called as `value.name()`.
- A parameter whose type is a typeclass with one parameter takes a value of any type with an instance, e.g. `fn report(value: Show)` called as `report(card)`. Each different type gets its own instance of the function.
- Code that depends on a parameter that requires `mn::reflection::Tuple` or `mn::iterator::Iterable` is checked in each instance of the function, since the types of its elements are known only there, e.g. `for value in values` in `fn total(values: Iterable) -> u32`.
- A parameter whose type is a pointer to such a typeclass, `*Class` or `*const(Class)`, takes a pointer to a value of any type with an instance, e.g. `fn allocate(allocator: *Allocator, type T, count: usize)` called as `allocate(&heap, Card, 10)`. Each different type gets its own instance of the function.
- A `*Class` parameter takes a read-only pointer when the chosen instance only reads, e.g. `report(&stdout)` for a constant `stdout`. When the instance writes it is a compile-time error at the call.
- A parameter's type can be a typeclass with several parameters with exactly one of them left unknown, written `_`, e.g. `fn save(value: To(_, []u8))` or `value: Convert(u8, _)`. The `_` is the type of the argument. It is chosen at each call, and each different type gets its own instance of the function.
- A pointer to such a typeclass takes a pointer the same way, e.g. `value: *To(_, []u8)`.
- A typeclass with several parameters as a parameter's type without exactly one `_` is a compile-time error, e.g. `value: To`, `value: To(u8, []u8)` or `value: To(_, _)`. A typeclass with one parameter is written without `_`.
- The other arguments are types known without the function's own `type` parameters, e.g. `value: To(_, T)` with a `type T` is a compile-time error.
- An argument takes part in choosing the instance as it is written, e.g. with `instance To(Path, []u8)` a call `save(path)` fits and `save(&path)` is a compile-time error at the call.
- A `type` parameter can require instances, e.g. `fn parse(type T: Parse, text: []const(u8)) -> T`.
- A `type` parameter's requirement can name a typeclass with several parameters, written with its arguments and exactly one `_`, which stands for the type being declared, e.g. `fn decode(self: *D, type T: Decode(_, D)) -> own !T` or `instance(type A: Encode(_, E), type E: Encoder) Encode(?A, E)`. The other arguments are types the declaration knows: the typeclass's own parameters inside its functions, the other parameters of the same function, instance or typeclass, including later ones, e.g. `fn(type T: Monoid(_, Operation), type Operation) fold(values: []const(T), operation: Operation) -> T`, or any other type. It combines with `and` like any requirement, e.g. `type K: Hash and Encode(_, E)`.
- A requirement that names a typeclass with several parameters without arguments, with no `_` or more than one, or with a different number of arguments than the typeclass has parameters is a compile-time error that shows the form to write, e.g. `type A: Encode` gives "a requirement on a typeclass with several parameters gives its arguments, with _ for the type it requires, e.g. Encode(_, E)". A typeclass with one parameter is required without arguments, e.g. `type T: Show`, and `type T: Show(_)` is a compile-time error.
- A function with such parameters is checked once, before any instance, and can use them only through the functions of the typeclasses they require. A requirement with arguments gives the instance of those arguments, e.g. `Decode(T, D)::decode(self)` in a function with `type T: Decode(_, D)`.

## Allocators

- A call followed by `with` and a pointer to a value whose type has an instance of `mn::memory::Allocator` gives that allocator to the call and everything beneath it, e.g. `try load(path) with &heap`. A `with` on an inner call overrides it for that call only.
- `with` followed by such a pointer is also a statement, e.g. `with &arena`. It gives that allocator to the calls after it in its block, nested blocks included, and everything beneath them. The pointer is evaluated once, at the statement. A `with` statement that no later call uses is allowed and leaves nothing in the output, except that a pointer with side effects, e.g. a call, is still evaluated once. It ends with its block, and a `with` statement in an inner block ends with that block. A call's own `with` overrides it for that call.
- `with allocator` is a statement that binds the current allocator to the name `allocator`, valid from that line on as any local constant: the one set by an earlier `with` statement in reach, or else the one the function was given. It has the allocator's own type, e.g. `allocator.allocate(Card, 10)`. Nothing about it appears in the signature. `with` followed by any other name sets the allocator from that pointer, e.g. `with arena` for a pointer named `arena`.
- A local or parameter named `allocator` in scope at `with allocator` is a compile-time error. The name bound by an earlier `with allocator` is not.
- A function needs an allocator if its body has a `with allocator` statement outside the reach of a `with` statement that sets one, or calls a function that needs one without its own `with` and outside such reach. This is worked out for each instance, through recursion, and a block dropped by a condition known at compile time does not count.
- A function that needs an allocator gets its own instance for each allocator type, and allocator calls are direct. Other functions are not affected.
- There is no default allocator. `main` and top-level code are given none, so a program that allocates sets one in `main`, e.g. `with memory::Heap` as its first line.
- `with`, in either form, also takes the name of an allocator type with no fields, e.g. `with memory::Heap` or `try load(path) with memory::Heap`, and the compiler supplies the pointer. An allocator type with fields is a compile-time error there, since its state needs a value to live in.
- `with memory::None`, in either form, clears the allocator: from there on none is set. `memory::None` is a struct with no fields and no instance of `mn::memory::Allocator`, recognized by its name.
- A call that needs an allocator where none is set, in `main`, in top-level code or after `with memory::None`, or a `with allocator` there, is a compile-time error, so code with no `with` above it is checked never to allocate. Its message shows each call that led to the code that needs the allocator, from where none was set.
- A deferred statement, of `defer` or `errdefer`, uses the allocator in effect where it is written, not the one in effect when the block ends, e.g. `defer list.deinit(own)` written after `with memory::Heap` frees through the heap even after a later `with memory::None`. Where it needs one and none is set there, it is the compile-time error above, at the `defer`.
- `with` on a call that does not need an allocator is a compile-time error, as is a `with` operand that is not a pointer to an allocator, an allocator type with no fields or `memory::None`.
- `&name` of a function that needs an allocator is a compile-time error for now.

## Ownership

- A value of an owning type, or one held by a name declared `own` whose type can own something, e.g. a pointer, a slice or an inline struct around one, is owned. A value that is not owned is copied wherever it goes. An owned value is moved: it has one owner at a time, and handing it on ends the hold of the one it came from, e.g. `try list.append(own record)`. An owned value is never copied.
- `own` marks where memory a call creates reaches its holder, in five places: a declaration, e.g. `const own text = try filesystem::read_text(path)` or `var own list = ...`, a name `as` gives in an `if`, `while` or `match`, e.g. `while list.pop() as own record`, a return type, e.g. `fn read_text(path: Path) -> own Error![]u8`, a parameter that takes the value over, e.g. `fn adopt(self: *Self, own path: Path)`, and a field its struct holds, e.g. `own directory: Path`.
- The result of a call whose return type is `own` goes only into an `own` place: an `own` declaration, names that `as own` gives, an assignment to a variable declared `own`, the `return` of an `own` function, an `own` parameter, or an `own` part of a literal, the literal itself then in such a place: an `own` field of a struct literal, and the field of an inline struct literal, an element of a tuple or array literal or the value of an enum's case whose type can own. `try`, `catch` and `orelse` on the call keep it in that place, and so does an `if` or `match` used as a value in that place whose branch gives it, e.g. `const own bytes = if (small) try make(1) else try make(2)`. Anywhere else is a compile-time error, including `_ = make()`, `if find() as record`, an assignment to any other variable and a parameter that is not `own`.
- An `own` place holds an allocation or nothing. The `own` places are an `own` declaration, names that `as own` gives, an assignment to a variable declared `own`, an `own` parameter, an `own` field in a literal or an assignment to one, an assignment to an element of an inline array or tuple that is itself `own`, e.g. `record.tags[0] = try memory::allocate(u8, 3)` for an `own tags: [2][]u8`, the field of an inline struct literal, an element of a tuple or array literal and the value of an enum's case whose type can own when the literal is in an `own` place, e.g. `{ own one, own two }`, `::Bytes{ own bytes }` or `return { bytes = own bytes }` from a function that returns `own Path`, and the `return` of an `own` function. Each takes exactly a name declared `own` written `own name`, or an owned part written `own whole.part`; the result of a call whose return type is `own`, through `try`, `catch` and `orelse`; an `if` or `match` used as a value whose every branch gives one of these or leaves, e.g. `else (_ as own rest) own rest` in `const own bytes = try match filesystem::read(path)`; a value whose type cannot own anything, e.g. `{ x = 1 }` for a struct without `own` fields; or nothing: `{}`, `null` or `undefined`, e.g. `{ storage = {}, length = 0 }` in `ArrayList(T)::init()`. Linear still requires the place to be handed on. Anything else is a view and a compile-time error there, since the place owns its value and a view cannot be moved into it: a string, array, struct or tuple literal holding a pointer or slice, e.g. `map.put("key", "alpha")` for a `HashMap([]const(u8), []const(u8))`, `&local` or any other address, a slice of an array or of another slice, a parameter or local that is not `own`, a field or element read anywhere, `pointer.*`, or the result of a call that is not `own`. A copy made with `clone` is passed instead, e.g. `try map.put("key", try "alpha".clone())`. Code in `mn::memory` and the `allocate` and `free` of `Allocator` instances are exempt, since they hand out raw memory.
- An `if` or `match` used as a value keeps an `own` place, as `try`, `catch` and `orelse` do: when it gives the value of an `own` declaration, an assignment to a variable declared `own`, the `return` of an `own` function, an `own` parameter or an `own` part of a literal, also through `try`, `catch` and `orelse` around it, the value of each branch is in that place, e.g. `const own bytes = try match filesystem::read(path)` followed by `case (NotFound) return Index::init()` and `else (_ as own rest) own rest`. The value of a branch, the expression on its last line or after its one-line form, is what an `own` place takes: the result of an `own` call, through `try`, `catch` and `orelse`, e.g. `if (small) try make(1) else try make(2)`; a name declared `own` or an owned part of one handed on with `own`, e.g. `own rest`; another `if` or `match` used as a value, to which the same applies, e.g. an `if` on the last line of a `case` block; a value whose type cannot own anything or nothing, e.g. `{}`; or the branch leaves instead with `return`, `break`, `continue` or `mn::comptime::error`, e.g. `case (NotFound) return Index::init()`. Anything else is a view and a compile-time error at that branch's value, which the message names, e.g. `case (NotFound) view` for a parameter `view: []u8`.
- `own` before a branch's value is allowed only when its `if` or `match` is in an `own` place, and is a compile-time error elsewhere, as `own` before a value whose place is not `own` is, e.g. `const bytes = if (flag) own one else other` or `own one` as the last line of an `if` used as a statement. The last line of a function body is not a branch's value, so `own one` there is a compile-time error, while an `if` or `match` on the last line of an `own` function is in the place of its `return`, e.g. `if (flag) own one` followed by `else keep(own one)`.
- A name handed on with `own` as a branch's value is handed on along that branch only, and every other path still has to hand it on, e.g. `const own bytes: []u8 = if (flag) own one else {}` is a compile-time error that names `one` at the exit where it is still held, while `memory::free(own one)` before the value of the other branch hands it on there.
- The other rules on `own` hold in each branch: a branch of a `match` on an owned value that covers the value binds it `as own`, e.g. `else (_ as rest) rest` on `filesystem::read(path)` is a compile-time error, and an `if` or `match` that is not in an `own` place takes no result of an `own` call in a branch, e.g. `const bytes = if (flag) try make() else try make()`. An `if` or `match` whose branches give values that own nothing is not affected, e.g. `const file = try match open(path)` in Match, and neither is one used as a statement.
- An assignment to a variable declared `own`, or to a name `as own` gives, is allowed only where the name no longer holds anything: it was declared `undefined`, `{}` or `null`, e.g. `var own bytes: []u8 = {}` followed by `bytes = try memory::allocate(u8, 4)`, or it was handed on, e.g. `list.deinit(own)` followed by `list = ArrayList(u8)::init()`. After the assignment it holds its value. Giving it a new value while it still holds one on that path is a compile-time error that names the variable, e.g. `var own record = try make(1)` followed by `record = try make(2)`.
- Passing a name declared `own`, a local or a parameter, or a part of one, to any of these is written with `own` before it, e.g. `slot.value.* = own record`, `const own moved = own text`, `list = own other` or `memory::free(own record.path)`, so the code shows that the name no longer holds the value. Leaving it out is a compile-time error, as is `own` before anything other than such a name or part, or before a value whose place is not `own`.
- `as own name` declares the name `own` and takes the value being tested as `const own name = …` takes its value, e.g. `if find() as own record`. The name is a variable: it can be assigned and its address is writable, e.g. `key.deinit(own)` after `while map.pop() as own { key, value }`. A plain `as name` on an owned value is a compile-time error, as `const record = …` is, e.g. `if find() as record` or `if found as entry`. `as *name` moves nothing, e.g. `if found as *entry`, and `*name` after `as own` is a compile-time error. On a value that cannot own anything, `as own name` is the same as `as name`, except that the name is a variable, e.g. `while numbers.pop() as own { key, value }` for a `HashMap(u32, u32)`.
- `as own` takes over the tested name itself, and no marker stands before it: `if found as own entry`, `while found as own entry`, `if evicted as own { key, value }` and a `match found` with a branch that binds `as own` or `own` in a case's braces move `found` at the test, on every path, whether it holds a value or not. After them `found` is unusable until it is given a new value, and a `while` has to give it one before it tests it again. A call result tested with `as own` has nothing to move, and `as *name` keeps a view and moves nothing. `own` before the tested name, e.g. `if own found as own entry` or `match own held`, is a compile-time error whose message shows the form without it, e.g. `if found as own entry`.
- Names in braces after `as own` take a tuple apart at once: each owned element moves to its name, and each other element is copied, e.g. `while map.pop() as own { key, value }`. `_` in place of an owned element is a compile-time error, as `_ = make()` is, while `_` in place of an element that is not owned is allowed, e.g. `as own { _, value }` for a `HashMap(u32, []u8)`. Plain names in braces on a tuple with owned elements are a compile-time error, as a plain name is.
- In a `match` on an owned value with `as own` in a branch, a branch that covers an owned part of the value, the value of an optional or a result or the value of an enum's case, without `as own` is a compile-time error, as a plain `as name` is, e.g. `case One` without a name for an owned `One: Record`. A branch that covers only `null`, or errors and cases that hold nothing that can own, needs no name, e.g. `case Record as own record` followed by `else noop`.
- A name declared `own`, or a part of one, is returned without `own` from a function whose return type is `own`, e.g. `return path` or `return record.path`, and the return moves it. Returning a name declared `own` from any other function is a compile-time error.
- A type is owning if it has an `own` field, directly or through the type of a field, an array's element, a tuple's element, an optional, a result's value or an enum case's value, e.g. `ArrayList` and `HashMap`. An inline struct takes the ownership class of its field instead: it is owning if its field's type is owning, can own something if its field's type can, and copies freely otherwise. Every other type copies freely, e.g. integers, floats, `bool`, enums whose cases hold no owning value, pointers, slices, `filesystem::Path` and `time::WallTime`.
- An inline struct whose field is a pointer or a slice is neutral as its field is, so the name decides: `own path: Path` owns the bytes, while `path: Path` is a view, copied freely and passed by value, e.g. `fn open(path: Path, options: Options = {})`, and `path.bytes` of it is a view as a slice is. A view cannot be moved into an `own` place, e.g. `const own copy = path` for a parameter `path: Path` is a compile-time error and `try path.clone()` is passed instead, while the result of an `own` call goes into one as any owned value, e.g. `const own parent = try path.parent()`. An `own` field whose type is such an inline struct makes its struct owning, as `own bytes: []u8` does, e.g. `own path: Path` in `struct Record`.
- A value of an owning type is never copied. It goes only into an `own` place, through the result of an `own` call or a move written with `own`, and is otherwise passed by pointer, e.g. `*const(Record)`. Copying one from a name, a field, an element or `pointer.*` is a compile-time error in a plain declaration, an assignment to a variable that is not `own`, a parameter that is not `own`, a field that is not `own`, an element of an array or tuple literal, a case's value, a tuple taken apart, a name a `for` loop gives for each element, and a name `as` gives in an `if`, `while` or `match` on such a value, e.g. `const copy = record`, `look(record)` or `for record in records`. `*name` and `_` copy nothing, e.g. `for *record in records`, and neither do a literal, the result of a call and `_ = record`. Types that copy freely are not affected. The body of each instance of a generic function, or of a function in a type a generic function gives, is checked with that instance's types, and an error there shows each call that led to it from the program's code.
- A `return` of a value of an owning type copies it, and is a compile-time error, unless it gives a name declared `own` or a part of one from a function whose return type is `own`, or the result of an `own` call, e.g. `fn share(holder: *const(Holder)) -> Record = holder.record`. A lookup that would copy a stored value gives a pointer to it instead, e.g. `map.get(&key) -> ?*const(V)`, valid until the next change to the map.
- Within a function, a name declared `own` whose value moved, through an `own` argument, field or declaration, an assignment with `own`, a branch's value with `own`, or a `return` from a function whose return type is `own`, is unusable until it is given a new value, along every path through branches and loops, e.g. reading `record` after `try list.append(own record)` is a compile-time error, and so is moving it twice. A part that moved is unusable in the same way, and so is every whole that contains it, e.g. `record` after `own record.path`, while its other parts stay usable and can move on their own, e.g. `record.hash`. A name moved in a branch of an `if` or `match` is unusable after it unless every branch that goes on gives it a new value. A name declared outside a loop and moved inside it is a compile-time error on the next pass unless the loop gives it a new value before then. An assignment to a moved part gives it a new value, and one to a part of a moved whole is a compile-time error.
- A part of a name declared `own` is moved out with `own`, e.g. `const own path = own record.path`, `memory::free(own record.path)` or `record.list.deinit(own)`, after which the whole is unusable and each owning part left must still be handed on. A part is anything stored inline, at any depth: a struct's field, an inline array's element with an index known at compile time, a tuple's element, the value inside an optional, e.g. `own found.?`, the field of an inline struct that can own, also through nested inline structs, e.g. `own path.bytes` or `own label.name.bytes`, and through `as own` a result's value or an enum case's value, e.g. `own owner.inner.record`, which ends `owner.inner` and `owner`. Anything behind a pointer is not a part, e.g. `own pointer.*`, `own list.storage[0]` for a slice's element, or a field through a pointer that is not an `own` pointer parameter, and neither is a part of a name that is not `own`, e.g. `own path.bytes` for a parameter `path: Path`; these are compile-time errors, as is an index known only at run time into an inline array of owning values, e.g. `own records[index]`. Elements behind a slice are ended by taking them out, e.g. `while list.pop() as own record` followed by `record.deinit(own)`, or with `memory::move`. For an `own` pointer parameter, the parts of the value it points to are parts too, through the automatic dereference, e.g. `memory::free(own list.storage)` in `fn deinit(own list: *ArrayList(E))` or `memory::free(own path.bytes)` in `fn deinit(own path: *Path)`, which ends the whole `Path`.
- A deferred statement counts where it runs: a `defer` at every exit of its block, and an `errdefer` at every exit where the function fails, through `try`, a `return` of an error, or a `return` of a call's result that can hold an error. A deferred statement that moves a name moves it there, so uses between the `defer` and the end of its block are allowed, and a `defer` that uses a name moved before that exit is a compile-time error, e.g. `defer _ = record.size` followed by `return record`. An `errdefer` whose statement hands a name on runs only at the failing exits where that name is still held, and is left out at those where it has been handed on, decided for each exit at compile time, e.g. `errdefer release(own two)`, then `try records.append(own two)`, then another `try` at which the `errdefer` does not run. A call that fails through `try` has not taken what it was given, so an `errdefer` still runs for it at that `try`, e.g. `errdefer record.deinit(own)` before `try list.append(own record)`. Where the function fails through `try` on an `if` or `match`, or through a `return` of one, each branch whose value can hold an error is an exit of its own, with what is held after that branch, so an `errdefer` runs where the error comes from a branch that still holds its name and is left out where it comes from one that handed the name on, e.g. `errdefer memory::free(own one)` with `memory::free(own one)` before `count(1)` in one `case` of `try match choice` and `take(own one)` in another; a `catch` or `orelse` on an `if` or `match` starts from what is held after the branches whose value can hold an error or `null`, and a name an `errdefer` hands on that is handed on in some of them and held in others is a compile-time error there.
- `own` on a return is about the call, so it also fits a type that copies freely when the value reaches memory the call allocated, e.g. `memory::create(T) -> own *T` or `-> own Error![]u8`. `own` on a written type with no pointer, slice or `own` field anywhere inside it is a compile-time error, e.g. `-> own u32` or `-> own time::WallTime`, since nothing in it can have been allocated. An instance of a generic function is exempt, e.g. `map.remove(key)` for a `HashMap(u32, u32)`.
- `own` on a generic function applies to every instance.
- `own` has no effect on a type that cannot own anything: a number, `bool`, an enum whose cases hold nothing that can own, an inline struct whose field cannot own anything, and a struct, tuple, array, optional or result that holds no `own` field, pointer or slice, e.g. `const own count: u32 = 5` is a plain constant, `take(own count)` moves nothing, and `_ = list.pop()` is allowed for an `ArrayList(u32)`. A pointer, a slice, an inline struct whose field can own and an owning type keep every rule, e.g. `memory::allocate(T, count) -> own Error![]T`. It is decided in each instance of generic code with that instance's types, so `_ = list.pop()` is a compile-time error for an `ArrayList(Record)`. `own` on a written return type that cannot hold an allocation is still a compile-time error outside generic code.
- An assignment to a field or an element, also through a pointer, takes a name declared `own` written with `own` and moves it, e.g. `self.storage[self.length] = own value` or `pointer.* = own record`. Where the compiler tracks a value's parts, the parts of a name declared `own`, of an `own` parameter, of what an `own *T` parameter points to and of a name `as own` gives, an assignment to an owning part at any depth, including an element of an inline array or a tuple and the field of an inline struct that can own, e.g. `path.bytes = own bytes`, is allowed only when the part holds nothing: the whole was declared `undefined`, `{}` or `null`; `{}`, `null` or `undefined` was written to the part, in an assignment or in the literal the whole was declared with, e.g. `var own record: Record = { path = {}, size = 0 }`; the part was handed on with `own`, e.g. `memory::free(own record.path)`; or it was emptied through `mn::memory` (see below). After the assignment the part holds its new value and has to be handed on as any other. Assigning to a part that still holds a value is a compile-time error that names it, e.g. "`record.path` still holds a value; end it or take it out first". Through a plain pointer or any other place the compiler does not track, e.g. `self.path = try make()` in a function with `self: *Self`, what the place held is overwritten and not checked, so freeing or moving it out first is the program's job. Without `own` it copies the name's value, which is a compile-time error for an owning type.
- `own` on the return of a typeclass's function applies to every instance of the typeclass: each instance's version of the function is marked `own` too, and leaving it out is a compile-time error at the instance's function, e.g. every `allocate` of an instance of `mn::memory::Allocator`. Without `own` on the typeclass's function, each instance decides for itself, e.g. `mn::convert::To::to` is not `own`, while `instance mn::convert::To(filesystem::Path, []u8)` marks its `to` `own`, since it allocates the text.
- A call through a typeclass takes `own` from the instance's function it resolves to, and in generic code from the one it resolves to in each instance of that code, e.g. `_ = try value.to([]u8)` in `fn save(value: To(_, []u8))` is a compile-time error in the instance for `filesystem::Path`.
- `memory::swap(one: *T, two: *T)`, `memory::replace(target: *T, own value: T) -> own T` and `memory::take(target: *?T) -> own ?T` move values through pointers while leaving a valid value behind, e.g. to unlink a node with `memory::take(&current.next)`, to sort an array of owning values, or to take a part out of a whole that must stay alive, e.g. `memory::free(memory::replace(&self.storage, own storage))`. `memory::move(source: *T) -> own T` gives the value and writes nothing back, so what `source` points to is left to be overwritten, e.g. `ArrayList`'s `pop` moves its last element out with it. All four work through raw memory and can be evaluated at compile time. On a place the compiler tracks, written `&place`, `memory::move(&record.path)` hands the part on as `own record.path` does, so afterwards it holds nothing, may be filled again and is no longer required to be handed on, and `memory::move(&record)` hands on the whole name; `memory::take(&slot.record)` leaves the part holding `null`, which is nothing; `memory::replace` and `memory::swap` leave it holding a value. Through any other pointer they are outside these rules.
- The typeclass `mn::memory::Deinit(type T)` ends a value with `fn deinit(own value: *T)`, e.g. `record.deinit(own)` or `defer record.deinit(own)`, after which `record` is moved. The library's own types have no separate `deinit` method.
- A type that cannot own anything is ended as nothing and copied as itself. It needs no instance of `mn::memory::Deinit` or `mn::memory::Clone`: a requirement of either, alone or joined with others, accepts it, `count.deinit(own)` compiles to nothing, and `try count.clone()` gives the value itself without allocating and never fails, e.g. `fn end(type T: Deinit, own value: T)` called as `end(u32, 5)` or with a struct of two integers. A type that can own something still needs its written instance, e.g. a `[]u8` or a struct with an `own` field, and a written instance for a type that cannot own is used before this rule. It holds only for `Deinit` and `Clone`, not for other typeclasses.
- An `own` pointer parameter, written `own value: *T`, takes only `own &name` for a name declared `own`, e.g. `Deinit::deinit(own &record)`, `own &name.part` for a part of one, e.g. `Deinit::deinit(own &record.list)`, a name declared `own` that holds a pointer, passed on with `own`, e.g. `Deinit::deinit(own value)`, or the result of an `own` call. Either moves what it is given. A plain pointer or the address of anything else is a compile-time error, e.g. `Deinit::deinit(record)` for a parameter `record: *Record`, `Deinit::deinit(&holder.record)` for a `holder` that is not `own`, or `Deinit::deinit(element)` in `for *element in list.items()`. `own &name` of a name declared `const own` gives `*T`, not `*const(T)`, since ending a value does not modify the name, which is unusable afterwards, e.g. `const own path = try "a/b".to(filesystem::Path)` followed by `Deinit::deinit(own &path)`. On a type that cannot own anything, any pointer fits.
- A hand-off at a call is written with `own` before the value, and a hand-off of the receiver with `own` alone as the call's first argument, in the place of the method's first parameter: a method whose first parameter is `own`, e.g. `own self: *Self`, `own value: *T` or a by-value `own` parameter, takes over its receiver, and is called as `key.deinit(own)`, `store.records.deinit(own)`, `defer index.deinit(own)`, `errdefer key.deinit(own)`, `const own items = try list.to_owned(own)` or, with further arguments after it, `try builder.finish(own, path)`, for a function in a type's block and a typeclass's function alike. The receiver is what `own` takes as an argument: a name declared `own`, an owned part, or a part of what an `own` pointer parameter points to, and the call consumes it under the rules above. `own` followed by a value is a moved argument and not the receiver, e.g. `list.append(own record)`. `key.deinit()` without `own` is a compile-time error, as `append(key)` is for a name declared `own`, and so are `own key.deinit()`, which puts `own` before the call instead of handing on its receiver, `own` as the first argument of a method whose first parameter is not `own`, e.g. `list.pop(own)`, `own` alone anywhere else, e.g. `builder.finish(path, own)` or `release(own)`, and the receiver in parentheses after `own`, e.g. `(own key).deinit()`. The function form stays valid, e.g. `Deinit::deinit(own &key)`.
- Ownership is linear: every name declared `own`, a local, a by-value `own` parameter or a name `as own` gives, has to be handed on with `own` on every path out of its block, at its end, at a `return`, a `break` or a `continue`, and where the function fails through `try` or a `return` of an error. Handed on means moved with `own` into a call, a field, a declaration, an assignment, a `return` or the value of a branch of an `if` or `match` in an `own` place, or passed as `own &name` to an `own` pointer parameter. Once a part has moved, every owning part left of the whole has to be handed on instead, e.g. `pair.two` after `memory::free(own pair.one)`. A name handed on along only some paths is a compile-time error at the exit it is left on, and its message names the name or part and the exit, e.g. `const own record = try make(1)` followed by `const own other = try make(2)` without an `errdefer` for `record`. A value whose type cannot own anything is exempt, e.g. `const own count: u32 = 5`.
- A struct of another module with a private owning field, without an instance of `Deinit` and without a function of its module that is not private and takes it over with an `own` parameter, can be held but not ended outside its module, except by taking its private fields apart with the word, e.g. `own thing.private.bytes`. A name of that type left holding it is a compile-time error that names the type and its module, e.g. "`Thing` from `things` can be held but not ended: its module provides no `Deinit` instance and no function that takes it over, and its private fields cannot be taken apart here; take them apart with `private` anyway, e.g. `own thing.private.bytes`".
- An `own` pointer parameter has to hand on every owning part of the value it points to, or itself with `own`, on every path out of its function, e.g. `memory::free(own list.storage)` or `list.deinit(own)` in `fn end(own list: *ArrayList(u8))`. One that hands on nothing is a compile-time error, since its function is the last holder and ends nothing.
- A call that fails through `try` has not taken what it was given, so the caller still holds it there. At every exit where a function fails, each of its `own` parameters has to be still held on that path: it need not be handed on there, and handing it on before failing is a compile-time error that names the parameter and the exit, e.g. `_ = keep(own record)` followed by `try check(true)` in `fn store(own record: Record) -> Failure!void`.
- `_ = name` is a compile-time error for a name declared `own` whose type can own something, e.g. `_ = record`. A name an `errdefer` hands on is handed on where the function fails, e.g. `errdefer record.deinit(own)`.
- `memory::free(own items: []const(T))` and `memory::destroy(own pointer: *const(T))` take `own`, as do the `free` and `destroy` of `mn::memory::Allocator`, so only a responsible place can be freed, e.g. `memory::free(own text)` or `memory::free(own record.path)`, and `memory::free(bytes)` for a view is a compile-time error.
- `ToOwned`'s function is `fn to_owned(own value: *T) -> own !U`: taking the storage out ends the container, e.g. `return list.to_owned(own)` in `text::format`.
- `mn::memory::Clone(T)` duplicates a value with `fn clone(value: *const(T)) -> own memory::Error!T`, allocating with the current allocator and copying, e.g. `const own stored = try key.clone()` for a `key: []const(u8)`, followed by `slot.key.* = own stored` into the slot `map.get_or_put(&key)` gives. `[]const(u8)` and `[]u8` have instances, each giving an owned slice of the same type.
- Three places are trusted rather than checked: the functions of `mn::memory`, including the `allocate` and `free` of `Heap` and `Arena` and `memory::move`, `replace`, `swap` and `take`, and the `allocate` and `free` of every instance of `mn::memory::Allocator`, whose bodies end what they are given in the runtime or keep it, e.g. `fn(type T) free(_: *Fixed, own _: []const(T)) = noop`, are not checked for handing on or for views; `external` signatures, whose `own` is declared and never checked; and a function with an `own` pointer parameter, trusted to end every part it hands on, e.g. that a `Deinit` instance frees everything. A `Deinit` instance is an ordinary function with an `own` pointer parameter, and the compiler never names the typeclass.

## Compile-Time Evaluation

- Everything a type depends on is evaluated at compile time, e.g. an array's length, a tuple's index or a struct field's default.
- A value is known at compile time when it is a literal, a constant or parameter known at compile time, or computed from these at compile time.
- `type` is the type of types. Types are values known at compile time, e.g. `const Number = i32`. A value whose type contains `type` exists only at compile time.
- Top-level constants are evaluated at compile time.
- A parameter written `type T` takes a type, e.g. `fn ArrayList(type T) -> type`. A parameter marked `comptime` takes a value known at compile time, e.g. `comptime format: []const(u8)`. Their arguments are evaluated at compile time.
- A parameter whose type is `any` takes a value of any type, e.g. `fn equal(one: any, two: any) -> bool`. `any` can only be the type of a parameter.
- A function can declare types in parentheses after `fn`, written like an instance's parameters, e.g. `fn(type Item) free(allocator: *Allocator, items: []const(Item))`. They are not passed: each is taken from the types of the arguments, e.g. `free(&heap, cards)` for a `[]Card` `cards` gives `Item` as `Card`. Arguments convert implicitly as for any parameter, so a `*[4]Card` also gives `Card`.
- Each declared type must appear in a parameter's type. Arguments that give a declared type two different types, or that do not fit the parameter's type, are a compile-time error.
- The arguments of a function that gives a type can be left out before `::` and a call of a function in the block of the struct it gives, when that call's arguments decide them, e.g. `binary::BinaryDecoder::init(&source)` for a `stream::Bytes` named `source` is `binary::BinaryDecoder(stream::Bytes)::init(&source)`, since `init` takes `*R`. The name reaches the function through any module path, e.g. `BinaryDecoder::init`, `binary::BinaryDecoder::init` or `mn::codec::binary::BinaryDecoder::init`, and the call gives exactly the type and value of the written-out form, which stays valid.
- Each left-out argument is taken from the types of the call's arguments against the called function's parameter types, as the types a function declares are, with `Self` standing for the type with the left-out arguments, e.g. `Arena::init(heap)` for a `Heap` named `heap` gives `Arena(Heap)`, and `ArrayList::length(&list)` for an `ArrayList(u8)` named `list` takes `T` from `*const(Self)`. Arguments convert implicitly the same way, e.g. a `*[2]u8` for a parameter of type `[]const(A)` gives `A` as `u8`. What the surrounding code expects takes no part, and a leading `::` is written to use it instead, e.g. `const list: ArrayList(u8) = ::init()`.
- A parameter that the call's arguments do not decide is a compile-time error at the name written for the function that gives the type, whose message names the parameter and shows the written-out form, e.g. `ArrayList::init()` names `T` and shows `ArrayList(T)::init()`. A parameter that is not a `type` parameter is never decided this way, e.g. `comptime size: usize`, so the same error names it.
- Requirements on the left-out arguments are checked once they are decided, with the error the written-out form gives, e.g. `binary::BinaryDecoder::init(&count)` for a `u32` named `count` fails because `u32` has no instance of `mn::stream::Reader`.
- The called function's parameter types are seen without the arguments only when the function that gives the type gives, in its last line and with no other `return`, a `struct` written there or a call of another such function whose arguments are types written from its parameters, e.g. `fn List(type T) -> type = ArrayList(T)`, and when those parameter types name no declaration in the block of that struct, e.g. a nested `struct Slot`. Otherwise leaving out the arguments is a compile-time error that asks for the written-out form, e.g. for a function that returns one of two structs from an `if`.
- A function gets its own instance for each different set of arguments to its `type` and `comptime` parameters, for each different set of types of the arguments to its `any` parameters, and for each different set of its declared types.
- A function with `type`, `comptime` or `any` parameters or declared types is checked for everything that does not depend on them, even if it is never called.
- `struct` followed by an indented block, written like a struct's, is a struct without a name, e.g. `return struct` followed by `items: []T`.
- A call evaluated at compile time gives the same result for the same arguments, e.g. `ArrayList(i32)` is the same type everywhere.
- Any function can be evaluated at compile time, unless it reaches an external function.
- Illegal behavior during compile-time evaluation is a compile-time error.
- Evaluation that does not end within a limit of steps, or nests calls beyond a limit, is a compile-time error.
