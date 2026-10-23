## Overview

Monolith is a statically typed language that compiles to readable source code in another language, called the target. The target is C (C23).

This specification is the reference for writing Monolith. Every rule has an identifier, such as `L3` or `T7`. A rule that rejects a program states the error message the compiler reports.

Errors are reported as `path:row:column: error: message`, where `path` is the file of the module the error is in. Rows and columns start at 1, and columns count bytes. An error that has no place in a module, such as an invalid file name (K2), is reported as `error: message`. The examples in this document show only `row:column: error: message`.

A program is the source file given to the compiler and the modules its paths reach (M1). The compiler stops at the first error.

## Grammar

The grammar uses this notation:

| Notation | Meaning |
|---|---|
| `"fn"` | the literal text |
| `a b` | `a` followed by `b` |
| `a \| b` | `a` or `b` |
| `[ a ]` | `a`, optionally |
| `{ a }` | `a`, repeated zero or more times |

`name`, `integer`, `float`, `string` and `newline` are defined in the Lexical structure chapter (L2, L6, L12 to L16, L18 to L21). The indentation of lines is described in S6 to S8, and applies to `fields` as to `indented_block`.

```
module               = { declaration }
declaration          = function | external_function | constant | struct
function             = function_declaration ":" block
external_function    = "external" function_declaration
function_declaration = "fn" name "(" [ parameters ] ")" [ type ]
parameters           = parameter { "," parameter } [ "," ]
parameter            = name ":" type [ "=" expression ]
type                 = expression
block                = statement | indented_block
indented_block       = newline statement { newline statement }
statement            = "noop" | "return" [ expression ] | "_" "=" ( call | name ) | call | constant
                     | variable | assignment | while
expression           = operand { "." name | "[" ".." "]" }
operand              = integer | float | string | "true" | "false" | "undefined" | path | call
                     | struct_literal | array_type | array_literal | slice_type
call                 = path "(" [ arguments ] ")"
struct_literal       = "." "(" [ arguments ] ")"
array_type           = "[" ( integer | "_" ) "]" operand
array_literal        = "[" [ expression { "," expression } [ "," ] ] "]"
slice_type           = "[" "]" [ "const" ] operand
arguments            = argument { "," argument } [ "," ]
argument             = [ name "=" ] expression
path                 = name { "::" name }
constant             = "const" name ( [ ":" type ] "=" expression | "=" anonymous_struct )
variable             = "var" name [ ":" type ] "=" expression
assignment           = expression "=" expression
while                = "while" expression ":" block
anonymous_struct     = "struct" [ ":" fields ]
struct               = "struct" name [ ":" fields ]
fields               = newline field { newline field }
field                = name ":" type [ "=" expression ]
```

## Lexical structure

### Characters and lines

- **L1.** Source files are ASCII outside string literals, which can contain any bytes (L19). Any character not described in this chapter is rejected with `unexpected character`.
- **L2.** A line ends with a line feed (`\n`) or a carriage return followed by a line feed (`\r\n`). A carriage return on its own is rejected with `unexpected character`.
- **L3.** Spaces separate tokens. Outside string literals, tabs are rejected with `tabs are not allowed, use spaces`.
- **L4.** The first line of a file cannot start with a space. It is rejected with `unexpected character` at 1:1.
- **L5.** The number of spaces at the start of a line is its indentation. A line containing only spaces is blank and is ignored, whatever its indentation. Between `(` and its `)`, and between `[` and its `]`, line ends and indentation are ignored, so a list of arguments or elements can continue on the following lines.

### Words

- **L6.** A word starts with a letter or `_` and continues with letters, digits and `_`.
- **L7.** These words are keywords: `fn`, `external`, `const`, `var`, `struct`, `noop`, `return`, `while`, `true`, `false`, `undefined`.
- **L8.** The built-in types (T1) are named `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize`, `f32`, `f64`, `Bool`, `String` and `void`. The names of number types, which state their size in bits or as the size of a pointer, and `void`, are lowercase. The others start with a capital letter. Type names are names, not keywords.
- **L9.** A lone `_` is the discard symbol. It is not a name.
- **L10.** Every other word is a name. Keywords and `_` cannot be used as names. The built-in type names and names that start with `mn_` are reserved (N14).

### Symbols

- **L11.** The symbols are `(`, `)`, `[`, `]`, `:`, `::`, `,`, `.`, `..` and `=`. Two `:` with nothing between them are the symbol `::`, and two `.` with nothing between them are the symbol `..`.

### Number literals

- **L12.** An integer literal is a sequence of digits in one of four bases:

  | Base | Form | Example |
  |---|---|---|
  | Decimal | digits `0`-`9` | `42` |
  | Hexadecimal | `0x`, then digits `0`-`9`, `a`-`f`, `A`-`F` | `0xff` |
  | Octal | `0o`, then digits `0`-`7` | `0o755` |
  | Binary | `0b`, then digits `0` and `1` | `0b1010` |

  The prefixes are lowercase. A prefix must be followed by at least one digit of its base.
- **L13.** A decimal literal cannot start with `0` followed by another digit or `_`. `0` on its own, `0.5` and `0e5` are valid. `007` is rejected with `unexpected character` at the second digit.
- **L14.** `_` may appear between two digits to group them, as in `1_000_000` or `0xff_ff`. It cannot appear at the start, at the end, or twice in a row.
- **L15.** A decimal literal becomes a float literal when it has a fractional part, an exponent, or both:
  - A fractional part is a `.` followed by optional digits: `2.5`, `5.`. A `.` only belongs to the number when it is not followed by another `.`, a `_` or a letter.
  - An exponent is `e` or `E`, an optional `+` or `-`, and at least one digit: `1e10`, `2.5e-3`.
- **L16.** A number literal may end with a suffix: a word directly after its digits, optionally separated by `_`: `5u8`, `1_000_u32`, `2.5f32`, `1.0_f64`. The suffix belongs to the literal, and which suffixes are valid is decided by types (T5, T6).
  - In hexadecimal literals, `f` is a digit, so `0x1f32` is the number `0x1F32` without a suffix.
- **L17.** A `_` directly after a number literal that is not followed by a letter is rejected with `unexpected character`.

### String literals

- **L18.** A string literal is text between double quotes on a single line: `"hello"`.
- **L19.** Between the quotes, a string literal contains any bytes other than `"`, `\`, line feeds and carriage returns, and these escapes:

  | Escape | Character |
  |---|---|
  | `\n` | line feed |
  | `\t` | tab |
  | `\\` | backslash |
  | `\"` | double quote |

- **L20.** A `\` followed by any other character is rejected with `unknown escape sequence`, at the `\`.
- **L21.** A string literal that reaches a line feed, a carriage return or the end of the file without a closing `"` is rejected with `unterminated string`, at its opening `"`.

## Program structure

### Top level

- **S1.** A source file is a module: a sequence of declarations at indentation 0, in any order, separated by any number of blank lines. A declaration is a function, an external function, a constant (N10) or a struct (S18).
- **S2.** Anything other than a declaration at top level is rejected with `unexpected token`. An indented line at top level is rejected with `unexpected indentation`.

### Functions

- **S3.** A function is a function declaration, made of its name, parameters and return type, followed by a block (the `function` rule): `fn add(left: i32, right: i32) i32:`.
- **S4.** A trailing `,` after the last parameter is allowed.
- **S5.** A missing return type is the return type `void`. `fn main():` and `fn main() void:` are the same.

### Blocks

- **S6.** A block is either inline or indented.
  - An inline block is a single statement on the same line as the `:`. It has the indentation of that line.
  - An indented block starts on the next line. Its first line sets the block's indentation, which must be greater than the indentation of the block that contains the `:`. The top level has indentation 0. Every following line of the block has exactly that indentation.
  - A block can hold statements with blocks of their own, such as `while` (S26).
- **S7.** An indented block ends at the first line indented less than the block, or at the end of the file. That line continues the enclosing block that has its indentation.
- **S8.** Errors in indented blocks:

  | Situation | Error |
  |---|---|
  | No line follows the `:` that is indented more than the block that contains the `:` | `expected an indented block` |
  | A line is indented more than the block | `unexpected indentation` |
  | A line is indented less than the block, and no enclosing block has its indentation | `indentation does not match any outer level` |

### Statements

- **S9.** `noop` does nothing.
- **S10.** `return` ends the function. Its value, if any, is on the same line.
- **S11.** `_ = add(1, 2)` calls a function and discards its result, and `_ = value` discards a parameter or a local constant (N19). Anything other than a call or a name after `_ =`, such as `_ = 5` or `_ = make().x`, is rejected with `expected a call or a name`. A struct value, `_ = Point(x = 1)`, is rejected with `expected a call`.
- **S12.** A call on its own, such as `log(1)`, is a statement. A name, a literal or a field access on its own is rejected with `expected a statement`.
- **S13.** A constant (N10) is also a statement. Inside a function, it declares a local constant (N15). `var` declares a variable (N20), and `target = value` assigns to one (N21). A target that is not a name or a field access, such as `make() = 1`, is rejected with `expected a name or a field access before '='`, at the target.
- **S14.** Each statement is on its own line, except for the single statement of an inline block.

### Expressions

- **S15.** A trailing `,` after the last argument is allowed: `add(1, 2,)`.

### External functions

- **S16.** An external function is a function declaration that the program calls but does not define: `external fn write(text: String)`. Its definition is written in the target's code. The standard library's external functions are defined by the target's runtime (D2). Every external function is called by its exact name (C8).
- **S17.** An external function has no body. A `:` after its declaration is rejected with `external functions have no body`.

### Structs

- **S18.** A struct is a type made of fields. It is declared with `struct`, its name and `:`, followed by an indented block with one field on each line. A field is a name and a type, `x: i32`. A line of the block that is not a field is rejected with `expected a field`.

  ```monolith
  struct Point:
      x: i32
      y: i32
  ```

- **S19.** A struct without fields is declared without the `:`: `struct Marker`.
- **S20.** A struct without a name is an anonymous struct: `struct:` followed by the block of fields, or `struct` without fields. An anonymous struct can only be the value of a top-level constant, which gives it the constant's name: `const Point = struct:` declares the same struct as `struct Point:`. Inside a function, it is rejected with `structs cannot be defined inside functions`, at `struct`.
- **S21.** A field of a struct value is read with `.` and the field's name, after any expression: `point.x`, `line.start.x`, `make().x`. A `.` that is not followed by a name is rejected with `expected an identifier`.
- **S22.** A struct value is built by calling its struct with one argument for each field, written as the field's name, `=` and the value: `Point(x = 0, y = 0)`. The fields can be given in any order, and a field with a default value (S23) can be left out. A struct without fields is built with `Marker()`. The value of a named argument is required: `Point(x = )` is rejected with `expected an expression`. A struct literal builds a struct value without naming its struct, which comes from where the value is used (T17): `.(x = 0, y = 0)`. A `.` that is not followed by `(` is rejected with `expected '('`.
- **S23.** A field or a parameter can have a default value, written after its type: `x: i32 = 0`, `fn draw(width: i32 = 1)`. A `=` without a value is rejected with `expected an expression`.

### Arrays

- **S24.** An array type is written `[N]T`: `N` elements of type `T`, as in `[2]Card` or `[3][2]i32`. `N` is an integer literal without a suffix. Any other length, such as `[size]i32` or `[2u8]i32`, is rejected with `array length must be an integer literal without a suffix`, and more than one value between the brackets is rejected with `expected one array length`. The length can be left out with `_` when the array type is the written type of a constant or a variable whose value is an array literal: in `const cards: [_]Card = [a, b]`, the length is 2, the number of elements. Anywhere else, `[_]` is rejected with `array length can only be left out with an array literal value`, at its `[`. Only the outermost length can be left out: in `[2][_]i32`, the `_` is rejected.
- **S25.** An array literal lists its elements between brackets: `[1, 2, 3]`. A trailing `,` is allowed, and the elements can continue on the following lines (L5). A missing `]` is rejected with `expected ']'`. Brackets that a type follows directly are an array type (S24); all other brackets are an array literal.

### Loops

- **S26.** `while`, a condition, `:` and a block run the block for as long as the condition is true: `while running: step()`. The condition is evaluated before each run of the block, so the block can run zero times. A `while` without a condition is rejected with `expected an expression`, and a `while` without the `:` with `expected ':'`.

### Slices

- **S27.** A slice type is written `[]T` or `[]const T`: elements of type `T` that the slice does not hold, as in `[]u8` or `[]const Card`. A slice refers to elements that are stored somewhere else, and their number is known only when the program runs. Through a `[]T` the elements can be changed, and through a `[]const T` they can only be read.
- **S28.** `value[..]` gives a slice of all the elements of an array: `buffer[..]`. A missing `]` is rejected with `expected ']'`.

## Modules

- **M1.** Every source file is a module. The file given to the compiler is the main module. A module's path is the path of its file, with directories separated by `::` and without `.mn`: `utils/math.mn` is the module `utils::math`, and the main file `hello.mn` is the module `hello`.
- **M2.** Every module's file name, without `.mn`, and every directory name in a module path must be a valid name (L6, L10). Paths can only spell valid names, so only the main file's name is checked (K2).
- **M3.** Every path is a namespace. A namespace is a module when a file has its path (M1), and it contains the namespaces whose paths continue its path: `std::io` contains `std::io::stdout`. A namespace can be both: with `utils.mn` and `utils/math.mn`, `utils` is a module and contains `utils::math`. A path reaches namespaces directly: `std::io::stdout::write("hello\n")` calls `write` in the module `std::io::stdout`.
- **M4.** A path that starts with `std` refers to the standard library, which comes with the compiler (K5). Every other path is a namespace of the program, relative to the directory of the main file, from every module.
- **M5.** The first name of a path that continues with `::` is looked up first among the local constants (N15), variables (N20) and parameters of the enclosing function, which hide any namespace with their name. A local constant that names a namespace reaches it. Any other local constant, and any variable or parameter, is rejected with `name has no members`. Otherwise the name is looked up only among namespaces: first the module's constants that name a namespace, then `std`, then the program's namespaces (M4).
- **M6.** The namespaces a namespace contains are reached through it: `std::io::stdout::write("hello\n")`. A namespace that is a module and contains namespaces reaches both its module's functions and its namespaces: `utils::add()` and `utils::math::add()`.
- **M7.** Each module is loaded once, however often it is reached, and modules can reach each other. Loading starts with the main module, and a module is read when resolving a module that is already loaded reaches it. Nothing else is read.
- **M8.** Every declaration of a module can be used by the other modules through a path, external functions and constants included.
- **M9.** In a namespace that contains namespaces, a name before a `::` that is none of them is rejected with `module not found`, at the path.
- **M10.** The name `monolith` is reserved. A path whose first name is `monolith` is rejected with `module name is reserved`.
- **M11.** If the main file's directory has its own `std.mn` or `std/`, a path whose first name is `std` is rejected with `name is ambiguous`.

## Names

- **N1.** Function, constant and struct names are unique within a module, external functions included. A second declaration with the name of a function, constant or struct is rejected at its `fn`, `external`, `const` or `struct`: a function with `function is already defined`, a constant with `constant is already defined`, and a struct with `struct is already defined`.
- **N2.** Parameter names are unique within a parameter list, and field names within a struct. A repeated name is rejected with `parameter is already defined` or `field is already defined`, at the second parameter or field.
- **N3.** A function can call functions defined before or after it.
- **N4.** A name is looked up first among the local constants (N15) and variables (N20) declared before it in the enclosing function, then among the parameters of the enclosing function, then among the module's functions, constants and structs, then among the built-in types (T1), then among `std` and the program's namespaces (M4). A name in a type (T11) is not looked up among the parameters, but it is looked up among the local constants and variables.
- **N5.** A name that matches none of them is rejected with `unknown name`.
- **N6.** A call to a name that does not refer to a function or a type, such as a parameter, a namespace or a constant whose value is a literal, is rejected with `name is not a function`. A call to a type builds a value of it (S22).
- **N7.** A function used as a value, named directly, through a path or through a constant, is rejected with `functions cannot be used as values`. A namespace used as a value is rejected with `unknown name`. A type can be used as a value (T11).
- **N8.** A path is resolved one name at a time. The first name is looked up as M5 describes. Each following name before a `::` goes through a namespace (M6): a constant of its module that names a namespace comes first, then the namespaces it contains. The last name is a declaration of the module reached, or a namespace it contains. A function and a namespace can have the same name: with `fn math()` in `utils.mn` and the module `utils::math`, `utils::math()` calls the function and `utils::math::add()` calls into the module. A parameter or a local constant hides a namespace with its name before a `::` (M5): with a parameter `utils`, `utils::add()` is rejected with `name has no members`, even when the module `utils` exists.
- **N9.** Errors in a path, at the path:

  | Situation | Error |
  |---|---|
  | The first name does not exist | `unknown name` |
  | A `::` follows a parameter, or a local constant that does not name a namespace | `name has no members` |
  | A `::` follows a declaration or a built-in type, and no namespace has its name | `name has no members` |
  | A name before a `::` is none of the namespaces that its namespace contains (M9) | `module not found` |
  | The module reached does not declare the last name | `unknown name` |
  | The last name of a call is a namespace | `name is not a function` |

### Constants

- **N10.** `const name = expression` declares a constant. Its value is evaluated at compile time, and can be a function, a type, a namespace, a literal, a struct value (S22) or an anonymous struct (S20). `const stdout = std::io::stdout` lets `stdout::write(...)` reach the module, `const write = mn_runtime_stdout_write` lets `write(...)` call the function, `const Integer = i32` lets `Integer` be used as a type, and `const limit = 5i32` lets `limit` be used as a value of type `i32`.
  - A constant can have a written type: `const limit: i32 = 5`. Its value must then have that type (T10), and a number literal without a suffix takes it (T5). With a written type, the value is used as a value, so a function or a namespace as the value is rejected as N7 describes. An anonymous struct cannot have a written type: `const Point: Shape = struct:` is rejected with `expected an expression`, at `struct`.
  - A number literal as the value has a suffix or a written type, which gives its type (T5): `const limit = 5i32`. Otherwise it is rejected with `value has no known type`, at the literal.
  - Errors in a literal value are reported at the literal, in the module of the constant.
  - A struct value as the value must be known at compile time: each field's value is a literal, a constant or another struct value. `const origin = Point(x = 0, y = 0)` lets `origin` be used as a value of type `Point`.
  - A call to a function or a field access, as the value or inside a struct value, is rejected with `cannot be evaluated at compile time`, at the call or the field access.
- **N11.** A constant means the same as its value, so every rule for that value applies to it. A constant produces no output: each use writes what the constant names, such as the function it calls or its literal. An anonymous struct is the exception, because C defines it (C10), and so is a constant whose value is a struct or an array, which the target stores once (C20).
- **N12.** A constant or a struct is only resolved and checked when something uses it. An unused constant or struct is not an error, because other modules can use it (M8), and the modules its value or its fields name are not loaded for it (M7).
- **N13.** A used constant whose value reaches itself, directly or through other constants, is rejected with `constant refers to itself`, at its `const`. A used struct that contains itself, directly or through the fields of other structs, is rejected with `struct contains itself`, at the `struct` or `const` of the first of them that is used.

### Reserved names

- **N14.** A function, external function, parameter, constant, struct or field whose name starts with `mn_` is rejected with `name is reserved`, at its `fn`, `external`, `const` or `struct`, or at the parameter or field. The modules of the standard library may use these names, because they declare the runtime's functions (D2). A function, external function, parameter, constant, struct or field named like a built-in type (T1) is rejected with `name is reserved` in every module, the standard library included.

### Local constants

- **N15.** A constant declared inside a function (S13) is a local constant. Its value can be known at compile time or only at run time: parameters, calls to functions and field accesses are allowed. A value that is only the name of a function, a type or a namespace makes the local constant an alias, as at the top level (N10), and an alias produces no output. Every other local constant becomes a constant of the target (C16). A local constant can be used from the statement after it to the end of the function. The names in its value are resolved, and its value is checked, where it is declared.
- **N16.** A local constant whose value has type `void`, such as a call to a `void` function, is rejected with `constant cannot have type void`, at the value.
- **N17.** A local constant can have the name of a parameter, of an earlier local constant or of any declaration. From the next statement on, the name refers to the new local constant: after `const limit = 1i32` and `const limit = 2i32`, `limit` is `2i32`. Its own value still refers to what the name meant before it.

### Unused names

- **N18.** Each parameter of a function with a body, each local constant and each variable (N20) must be used or discarded (N19). An unused parameter is rejected with `parameter is unused, discard it with _ =`, at the parameter. An unused local constant is rejected with `local constant is unused, discard it with _ =`, at its `const`, and an unused variable with `variable is unused, discard it with _ =`, at its `var`. Only reading a variable uses it: a variable that is assigned (N21) but never read is unused. A local constant or variable that a later one with the same name hides before any use is unused (N17). The parameters of external functions are not checked, because they have no body.
- **N19.** `_ = name` discards a parameter, a local constant or a variable of the enclosing function, which marks it as unused on purpose. Errors, at the name after `_ =`:

  | Situation | Error |
  |---|---|
  | The name is not a parameter, a local constant or a variable | `only parameters, local constants and variables can be discarded` |
  | The name is also used, or discarded a second time | `discarded name is used` |

### Variables

- **N20.** `var name: Type = value` declares a variable: a local whose value can change (N21). The type is optional, as for a local constant. A variable follows the rules of local constants for where it can be used, for shadowing (N17) and for its value (N15), except that a variable is never an alias: a function or a namespace as its value is rejected as N7 describes. Errors, at the value unless stated otherwise:

  | Situation | Error |
  |---|---|
  | The value has type `void` | `variable cannot have type void` |
  | The value is a type | `variable cannot hold a type` |
  | The variable is never assigned, at its `var` | `variable is never assigned, declare it with const` |

- **N21.** `target = value` assigns a value to a variable, or to a field reached through a variable: `count = 2`, `point.x = 3`, `line.start.x = 1`. The value must have the type of the target (T10). A struct value is copied. Any other target, such as a local constant, a parameter, a top-level name or a field of a call (`make().x = 1`), is rejected with `only variables and their fields can be assigned`, at the target. Parameters can never be assigned. A name that matches nothing is rejected with `unknown name` (N5).
- **N22.** `undefined` is a value whose contents are not set yet. It can only be the initial value of a variable with a written type: `var count: i32 = undefined`. Without a written type it is rejected with `value has no known type`, and anywhere else with `undefined can only be the initial value of a variable`, at `undefined`. The compiler does not check that a variable is assigned before it is read: reading an undefined value is the programmer's responsibility.

### Blocks

- **N23.** A local constant or a variable declared in the block of a `while` (S26) exists from its statement to the end of that block. After the block, its name means again what it meant before the block. Inside the block, the rules of local constants and variables (N15 to N22) apply. Uses, discards and assignments count wherever they are in the function, also inside nested blocks: a variable that is assigned only inside a loop is assigned (N20). The compiler does not check if a block runs.

### Slices

- **N24.** Only an array that is stored in a name can be sliced (S28): a variable, a local or top-level constant, a parameter, or a field reached through one of them, such as `deck.cards[..]`. Any other value, such as a call (`make()[..]`) or a literal (`[1, 2][..]`), is rejected with `only variables, constants, parameters and their fields can be sliced`, at the value. A slice of a variable counts as an assignment to it (N20), because the elements can be changed through the slice.

## Types

### Built-in types

- **T1.** The built-in types are:

  | Type | Values |
  |---|---|
  | `i8`, `i16`, `i32`, `i64` | signed integers of 8, 16, 32 and 64 bits |
  | `u8`, `u16`, `u32`, `u64` | unsigned integers of 8, 16, 32 and 64 bits |
  | `usize` | an unsigned integer with the size of a pointer, for lengths and counts; its literals can be as large as for `u64` |
  | `f32`, `f64` | 32-bit and 64-bit floating point numbers |
  | `Bool` | `true` and `false` |
  | `String` | text, stored as bytes in any encoding |
  | `void` | no value; only as a return type |

  A parameter of type `void` is rejected with `parameter cannot have type void`, at its type.

- **T2.** There are no implicit conversions between types, except from `[]T` to `[]const T` (T24).
- **T3.** What happens when arithmetic exceeds a type's range is left to the target. It is not defined by Monolith.

### Types of expressions

- **T4.** `true` and `false` have type `Bool`, and a string literal has type `String`.
- **T5.** A number literal with a suffix has the suffix's type, and the suffix must be the name of a number type. Any other suffix is rejected with `unknown suffix`, at the literal: `5Bool`. A number literal without a suffix takes the type its context expects: the function's return type for a returned value, the parameter's type for an argument, or the written type of a constant (N10).
- **T6.** An integer literal can only have an integer type, and a float literal only a float type. `return 2` in an `f64` function is rejected: write `2.0`. This includes suffixes: `1f64` and `2.5u8` are rejected with `value does not match the expected type`.
- **T7.** An integer literal must not exceed its type's maximum, and a float literal must not overflow its type to infinity. Otherwise it is rejected with `literal out of range for its type`. A float literal too small for its type becomes 0 and is accepted.
- **T8.** A name that refers to a parameter has the type of the parameter. A name that refers to a type has the type of types (T11). A name that refers to a constant has the type of its value (N10).
- **T9.** A call has the return type of the called function.
- **T10.** An expression whose type differs from the expected type is rejected with `value does not match the expected type`. This includes a call to a `void` function where a value is expected.

### Types as values

- **T11.** Types are values, and their type is the type of types. Each parameter type and return type is an expression that must have the type of types. Otherwise it is rejected with `value does not match the expected type`, at the expression: `fn add(value: 5)`. A type used where a value of another type is expected is rejected the same way: `return i32` in an `i32` function.

### Structs

- **T12.** Each struct is a type of its own, even when another struct has the same fields. A constant that names a struct names the same type: with `const Other = Point`, `Other` and `Point` are one type.
- **T13.** Each field type is an expression that must have the type of types (T11). A field of type `void` is rejected with `field cannot have type void`, at its type.
- **T14.** A field access has the type of the field. The name after the `.` is not looked up as a name (N4); it must be a field of the value's struct. Errors are reported at that name:
  - A value whose type is not a struct is rejected with `value has no fields`: `value.x` with `value: i32`.
  - A name that is not a field of the struct is rejected with `unknown field`.
  - A number literal without a suffix before the `.` has no type to take, and is rejected with `value has no known type`, at the literal: `5.x`.
- **T15.** A struct value (S22) has the type of its struct, and each field's value must have the field's type (T10). Errors:

  | Situation | Error | At |
  |---|---|---|
  | The called type is not a struct: `i32(x = 1)` | `type is not a struct` | the call |
  | An argument has no field name: `Point(1, y = 2)` | `expected a field name` | the argument |
  | The struct has no field with that name | `unknown field` | the argument |
  | A field is given twice | `field is already given` | the second argument |
  | A field without a default value is not given | `missing field` | the call |

- **T16.** A default value (S23) must have the type of its field or parameter (T10), and it must be known at compile time, like a constant's value (N10). A call to a function or a field access in it is rejected with `cannot be evaluated at compile time`. The default values of a struct are checked only when the struct is used (N12), and their errors are reported in the module of the struct.
- **T17.** A struct literal (S22) takes the type its context expects, as a number literal without a suffix does (T5): the parameter's type for an argument, the field's type for a field's value or default, the function's return type for a returned value, the written type of a constant or variable, or the target's type in an assignment. It follows the rules of a struct value of that type (T15). A struct literal never creates a type. Without an expected type, as in `const point = .(x = 1)`, it is rejected with `value has no known type`, and an expected type that is not a struct is rejected with `type is not a struct`, at the literal.

### Arrays

- **T18.** Array types with the same length and element type are the same type, wherever they are written. The element type must be a type (T11), and an element of type `void` is rejected with `array elements cannot have type void`, at the element type. An array type can be used wherever a type can: as the type of a parameter, a return value, a field, a constant or a variable, or as the element type of another array. A constant can name an array type: `const Pair = [2]i32`.
- **T19.** Arrays are values. Passing, returning and assigning an array gives an independent copy, as for a struct. An array has no fields (T14).
- **T20.** An array literal (S25) takes the type its context expects, as a struct literal does (T17), and each element must have the element type (T10). When no type is expected, every element must have a type of its own, and all elements must have the same type: `const values = [1i32, 2i32]` has type `[2]i32`. No element decides the type for the others, so a struct literal or a number without a suffix in such a literal is rejected with `value has no known type`, at that element. Errors, at the literal unless stated otherwise:

  | Situation | Error |
  |---|---|
  | No type is expected and the literal is empty: `const values = []` | `value has no known type` |
  | No type is expected and two elements have different types, at the later element | `elements of an array literal have different types` |
  | No type is expected and the elements have type `void`, at the first element | `array elements cannot have type void` |
  | The expected type is not an array | `type is not an array` |
  | The number of elements differs from the array's length | `number of elements does not match the length of the array` |

### Loops

- **T21.** The condition of a `while` (S26) must have type `Bool` (T10). Any other type is rejected with `value does not match the expected type`, at the condition.

### Slices

- **T22.** Slice types with the same element type, both with or both without `const`, are the same type, wherever they are written. The element type must be a type (T11), and an element of type `void` is rejected with `slice elements cannot have type void`, at the element type. A constant can name a slice type: `const Bytes = []const u8`.
- **T23.** A slice of an array (S28) has the element type of the array. A slice of a variable, or of a field reached through a variable, has the type `[]T`. A slice of a constant or a parameter has the type `[]const T`, because their elements cannot be changed. Only arrays can be sliced: any other type is rejected with `type is not an array`, at the value.
- **T24.** A `[]T` is accepted where a `[]const T` is expected. A `[]const T` where a `[]T` is expected is rejected with `value does not match the expected type`.

## Functions

- **F1.** A call passes at least one argument for each parameter without a default value, and at most one for each parameter. Otherwise it is rejected with `wrong number of arguments`. Arguments match parameters in order, so only the last parameters can be left out, and each one left out takes its default value. A parameter without a default value after one with a default value is rejected with `parameters with default values must come last`, at that parameter. The arguments of a function have no names: `add(value = 1)` is rejected with `function arguments have no names`, at the argument.
- **F2.** Each argument must have the type of its parameter (T10).
- **F3.** A `void` function returns with `return` without a value. `return` with a value in a `void` function is rejected with `void function cannot return a value`.
- **F4.** A function with a return type returns with `return` and a value. `return` without a value is rejected with `missing return value`.
- **F5.** The last statement of a function with a return type must be `return`, or a `while` whose condition is the literal `true`, which never ends. Otherwise the function is rejected with `function must end with a return`, at its return type.
- **F6.** A call statement must call a `void` function. A call to any other function on its own is rejected with `call result is unused, discard it with _ =`.
- **F7.** `_ =` must call a function that returns a value. Discarding a call to a `void` function is rejected with `call returns no value to discard`.

### The main function

- **F8.** The main module's `main` is the program's entry point. A module does not need one. Any module may define `main`, but only the main module's `main` is the entry point.
- **F9.** Every `main` has no parameters and returns `void`. Otherwise it is rejected with `main cannot have parameters` or `main cannot have a return type`.
- **F10.** No `main` can be called. A call to it is rejected with `main cannot be called`.
- **F11.** `main` cannot be an external function. An external `main` is rejected with `main cannot be external`.

## Targets

### Names in the output

- **G1.** Names are written to the output exactly as they are in the source, except the generated names: C function names (C9), C struct names (C10), C names of array types (C19), C names of slice types (C22) and C names of stored constants (C20). A generated name is `mn_` followed by the module path with `::` replaced by `_`, so it cannot be a name written in the source (N14).
- **G2.** A function, external function, parameter, local constant, variable or field whose name, as written to the output, the target already defines is rejected with `name is already defined in the target`, at the function's `fn` or `external` keyword, at the local constant's `const` or the variable's `var`, or at the parameter or field. Local constants and variables are checked with the name they get in the output (C16). Top-level constants are not checked, because they produce no output (N11), and neither are structs, because their C names are generated (C10), or discarded parameters, because they have no name in the output (C6). A function's name is checked as it is written to the output: `fn int(): noop` becomes `mn_hello_int` (C9) and is accepted, but a parameter named `int` is rejected.
- **G3.** C defines the C23 keywords `_Alignas`, `_Alignof`, `_Atomic`, `_BitInt`, `_Bool`, `_Complex`, `_Decimal128`, `_Decimal32`, `_Decimal64`, `_Generic`, `_Imaginary`, `_Noreturn`, `_Static_assert`, `_Thread_local`, `alignas`, `alignof`, `auto`, `bool`, `break`, `case`, `char`, `const`, `constexpr`, `continue`, `default`, `do`, `double`, `else`, `enum`, `extern`, `false`, `float`, `for`, `goto`, `if`, `inline`, `int`, `long`, `nullptr`, `register`, `restrict`, `return`, `short`, `signed`, `sizeof`, `static`, `static_assert`, `struct`, `switch`, `thread_local`, `true`, `typedef`, `typeof`, `typeof_unqual`, `union`, `unsigned`, `void`, `volatile` and `while`, and `asm`, which compilers such as GCC treat as a keyword outside strict C23. It also defines the names that C23 declares in `<stddef.h>` and `<stdint.h>`, which the header includes, such as `size_t`, `int32_t`, `NULL` and `INT32_MAX`. `string` and `MONOLITH_H` are defined by `runtime/monolith.h` itself (C1).

### C

- **C1.** The output is C23. Every module's header includes `runtime/monolith.h`, a file of the C runtime that is copied into every C output (K3). It contains the definitions the output and the runtime rely on:

  ```c
  #ifndef MONOLITH_H
  #define MONOLITH_H

  #include <stddef.h>
  #include <stdint.h>

  typedef struct { const char *bytes; size_t length; } string;

  #endif
  ```

- **C2.** Every module becomes a `.h` file, and a module that defines functions or stores constants (C20) also becomes a `.c` file (K3).
  - The `.h` file starts with `#pragma once`. It includes `runtime/monolith.h`, then the header of every other module whose structs its structs contain. Then it defines the module's structs (C10), each after the array and slice types its fields hold (C19, C22). Then it declares each struct of another module, and each array or slice type it does not define, that its function declarations or stored constants use, with `typedef struct mn_shapes_Line mn_shapes_Line;`. Then it declares its stored constants (C20). Last, it declares the module's functions: first its external functions, then, after a blank line, its other functions. The main module's `main` is not declared.
  - The `.c` file includes its own header, then the header of every other module that its calls or its uses of stored constants reach, also through the value of a constant that is not stored, or whose structs its functions use, in the order of their first use. Then it defines the slice types and then the array types that its functions and constants use and its header does not define (C22, C19), then its stored constants (C20), and then its functions.
  - Includes use paths relative to the file: `#include "std/io/stdout.h"`.
  - No function is `static`, so any module can be imported, the main module included.
- **C3.** The main module's `main` becomes `int main()`. A `return` without a value inside it becomes `return 0;`.
- **C4.** Types become C types:

  | Monolith | C |
  |---|---|
  | `i8` to `i64` | `int8_t` to `int64_t` |
  | `u8` to `u64` | `uint8_t` to `uint64_t` |
  | `usize` | `size_t` |
  | `f32`, `f64` | `float`, `double` |
  | `Bool` | `bool` |
  | `String` | `string` |
  | `void` | `void` |
  | a struct | its C name (C10) |
  | an array | its C name (C19) |
  | a slice | its C name (C22) |

- **C5.** Number literals keep their base. `_` becomes `'`, `0o` becomes `0`, the suffix is removed, and literals of unsigned types end with `u`: `0o7_5_5` returned from a `u16` function becomes `07'5'5u`.
- **C6.** `_ = add(1, 2)` becomes the plain call, `mn_hello_add(1, 2);` (C9). `_ = value` writes nothing. A discarded parameter has no name in the output: `fn show(value: i32): _ = value` becomes `void mn_hello_show(int32_t)` in the header and in the definition.
- **C7.** A string literal becomes a `string` holding the literal as written and its length in bytes, counting each escape as one byte: `"line\n"` becomes `(string){ "line\n", 5 }`.
- **C8.** An external function keeps exactly the name written in the source, so its definition, linked into the program, uses that name: `external fn stdout_write(text: String)` becomes `void stdout_write(string text);`. The runtime defines the standard library's external functions this way (D2).
- **C9.** C has one namespace for all files, so a function's C name is its module's generated name (G1), followed by `_` and its name: `greeting` in `hello.mn` becomes `mn_hello_greeting`, and `add` in `utils::math` becomes `mn_utils_math_add`. The main module's `main` stays `main`.
- **C10.** A struct that something uses (N12) becomes a `typedef` in the header of its module, with one field on each line. Its C name is its module's generated name (G1), followed by `_` and its name, as for functions (C9). The structs of a module are defined after the structs they contain.

  ```c
  typedef struct mn_hello_Point {
      int32_t x;
      int32_t y;
  } mn_hello_Point;
  ```

- **C11.** A zero-sized type is a struct whose fields all have zero-sized types, such as a struct without fields, or an array whose length is 0 or whose elements have a zero-sized type. It has no definition in C. Fields, parameters and arguments of a zero-sized type are left out, and a function that returns one returns `void`. The calls in a zero-sized argument run before the call that receives it: `use(make(marker), 1)` becomes `(mn_hello_make(), mn_hello_use(1))`, and `use(holder().marker, 1)` becomes `(mn_hello_holder(), mn_hello_use(1))`. The calls in a returned zero-sized value run before the `return;`. A zero-sized value without calls, such as `holder.marker`, writes nothing.
- **C12.** Modules whose structs contain each other's structs, directly or through other modules, are rejected with `modules contain each other's structs`, at the field.
- **C13.** A field access is written as in Monolith: `line.start.x` stays `line.start.x`, and `make().x` becomes `mn_hello_make().x`.
- **C14.** A struct value becomes a compound literal that names each field, in the order written: `Point(y = 2, x = 1)` becomes `(mn_hello_Point){ .y = 2, .x = 1 }`. Fields of a zero-sized type are left out (C11). Fields left out with a default value are written with that value, after the given fields, in the order they are defined: `Point(y = 1)` becomes `(mn_hello_Point){ .y = 1, .x = 0 }`. A struct literal is written the same way, with the struct it takes (T17): `.(y = 1)` where a `Point` is expected becomes `(mn_hello_Point){ .y = 1, .x = 0 }`. A constant that holds a struct value is stored once (C20).
- **C15.** A call writes the default value of each parameter it leaves out: `draw(2)` becomes `mn_hello_draw(2, 1)`.
- **C16.** A local constant that is not an alias (N15) becomes a C local constant, and each use writes its name: `const limit: i32 = 5` becomes `const int32_t limit = 5;`.
  - C cannot declare a name two times in one block, and in `const int32_t x = x;` the value already refers to the new `x`. So a local constant that has the name of a parameter or of an earlier local constant gets the next free number: in `fn show(value: i32)`, `const value = value` becomes `const int32_t value_2 = value;`. A number is skipped when a parameter or local constant of the function already has that name in the source.
  - A discarded local constant (N19), or one of a zero-sized type (C11), is not declared. Only the calls in its value run, as a statement: `const point = make_point()` followed by `_ = point` becomes `mn_hello_make_point();`.
- **C17.** A variable becomes a C local without `const`: `var count = 1i32` becomes `int32_t count = 1;`, and `var count: i32 = undefined` becomes `int32_t count;`. Its name follows C16, and it shares the numbers with the local constants. A discarded variable, or one of a zero-sized type, is not declared, as in C16.
- **C18.** An assignment is written as in Monolith: `count = 2` becomes `count = 2;`, and `point.x = 3` becomes `point.x = 3;`. When the variable is not declared (C17), or the target has a zero-sized type, only the calls in the value run, as a statement.
- **C19.** An array type becomes a struct that holds a C array in its field `items`, so that C copies it as a value (T19). Its C name is `mn_array_`, the length, `_`, and the element type as Monolith writes it, with a struct named by its module path and name: `[2]Card` in `hello` is `mn_array_2_hello_Card`, and `[3][2]i32` is `mn_array_3_array_2_i32`. Its definition is guarded, so that any number of files can contain it:

  ```c
  #ifndef mn_array_2_hello_Card_defined
  #define mn_array_2_hello_Card_defined
  typedef struct mn_array_2_hello_Card {
      mn_hello_Card items[2];
  } mn_array_2_hello_Card;
  #endif
  ```

  An array literal becomes a compound literal: `[1, 2]` where a `[2]i32` is expected becomes `(mn_array_2_i32){ .items = { 1, 2 } }`.
- **C20.** A top-level constant whose value is a struct or an array, and that is not zero-sized (C11), is stored once. Its C name is built as for a function (C9): `cards` in `hello` becomes `mn_hello_cards`. Its module's `.c` file defines it, and its header declares it with `extern const`. Every use writes its name. Its value is written as an initializer, without compound literals, and the constants it uses are written by their values: `const origin: Point = .(x = 0)` becomes `const mn_hello_Point mn_hello_origin = { .x = 0 };`. A constant is only stored when something uses it (N12).
- **C21.** A `while` is written as in Monolith, with its block in braces:

  ```c
  while (running) {
      mn_hello_step();
  }
  ```

  A block without output becomes `{}`: `while true: noop` becomes `while (true) {}`. The locals declared in the block follow C16, and their C names are unique in the whole function: a local in a loop that has the name of an outer local gets the next free number.

- **C22.** A slice type becomes a struct that holds a pointer to the first element in its field `items`, and the number of elements in its field `length`. `[]T` and `[]const T` become the same C type, because `const` is checked by Monolith (T24). Its C name is `mn_slice_` and the element type as in C19: `[]u8` is `mn_slice_u8`, and `[]const Card` in `hello` is `mn_slice_hello_Card`. Its definition is guarded as in C19. A struct, array or slice element is named by its struct tag, so the slice needs no definition of it, and a zero-sized element (C11) becomes `void`:

  ```c
  #ifndef mn_slice_hello_Card_defined
  #define mn_slice_hello_Card_defined
  typedef struct mn_slice_hello_Card {
      struct mn_hello_Card *items;
      size_t length;
  } mn_slice_hello_Card;
  #endif
  ```

  A slice of an array becomes a compound literal with the array's `items` and its length: `buffer[..]` of a `[4]u8` becomes `(mn_slice_u8){ .items = buffer.items, .length = 4 }`. Local and stored constants are `const` in C (C16, C20), so for a slice of one the pointer is converted: `(mn_slice_i32){ .items = (int32_t *)values.items, .length = 2 }`. A slice of a zero-sized array has only its length: `(mn_slice_hello_Marker){ .length = 2 }`.

## Compiler

- **K1.** The compiler is invoked as `monolith <file.mn>`, where the file name ends with `.mn` and has a name before it. Any other arguments print `usage: monolith <file.mn>`.
- **K2.** The file name without `.mn` must be a valid name (L6, L10), and neither a built-in type name (T1) nor `std` (M4). Otherwise the compiler stops with `error: file name must be a valid name`, before reading the file.
- **K3.** The output is written to `build/`, in the directory the compiler runs in. The C files are written to `build/source/`:
  - The main module is written as `<name>.h` and `<name>.c`, where `<name>` is the source file name without `.mn`.
  - Every other module is written at its module path, the standard library's modules included: `utils::math` as `utils/math.h` and `utils/math.c`, and `std::io::stdout` as `std/io/stdout.h`.
  - A module without functions or stored constants, the main module included, gets no `.c` file (C2).
  - The runtime files whose functions the program calls are copied to `runtime/`, such as `runtime/stdout.c` (D2).
  - `runtime/monolith.h` is always copied (C1).
  - When the main module defines `main`, the compiler also builds the executable `build/<name>` with GCC, from every `.c` file of the output: `gcc -std=c23 -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable -pedantic -O2 -flto`. GCC's warnings are shown. Its warnings about unused parameters and variables are turned off, because the compiler checks unused names in the source (N18), and the output leaves out code that does nothing in C, such as discarded local constants (C16). If GCC cannot be run, the compiler stops with `error: cannot run gcc: <reason>`. If GCC fails, it stops with `error: gcc could not build the executable`. GCC runs after the output is written, so the C files stay when it fails.
  - After a successful compilation, `build` is deleted and created again, so it only contains this output. No file is written or deleted when compilation fails.
- **K4.** The compiler exits with status 0 on success and 1 on any error.
- **K5.** The compiler's executable comes with two directories next to it: `std/`, the standard library's modules, and `plugins/`, with one directory for each target. A target's runtime (D2) is in the `runtime/` directory of its plugin: `plugins/c/runtime/stdout.c`.

## Standard library

- **D1.** The standard library is a set of Monolith modules under `std` (M4). `std::io::stdout` provides `write(text: String)`, which writes text to the standard output:

  ```monolith
  external fn mn_runtime_stdout_write(text: String)

  const write = mn_runtime_stdout_write
  ```

- **D2.** The runtime is a library of the target that does not depend on the standard library. A runtime function is named like a generated name (G1): `mn_`, then the path of the file that defines it, with `/` replaced by `_`, then `_` and its name. `mn_runtime_stdout_write` is `write` in `runtime/stdout.c`. The compiler finds the file by following the name's parts as folders until a file exists, so a function name can contain `_`. Its functions are linked by name (C8). The standard library declares them as external functions and names them with constants (D1), so a call such as `stdout::write(...)` calls the runtime function directly. Only the runtime files whose functions the program calls are copied into the output (K3).
- **D3.** `mn_runtime_stdout_write` writes the text exactly as given.
- **D4.** `std::io::stdin` provides `read(buffer: []u8) usize`, which reads bytes from the standard input into the buffer and returns how many it read:

  ```monolith
  external fn mn_runtime_stdin_read(buffer: []u8) usize

  const read = mn_runtime_stdin_read
  ```

  It waits until input is available, reads at most the buffer's length, and returns what has arrived. On a terminal, that is one line, with its `\n`, after the user presses Enter. Bytes that do not fit stay for the next call. It returns 0 at the end of the input, and also when reading fails.

## Examples

### A valid program

`hello.mn`:

```monolith
const stdout = std::io::stdout

fn add(left: i32, right: i32) i32:
    _ = right
    return left

fn flag() Bool:
    return true

fn greeting() String: return "hello\n"

fn main():
    _ = add(1, 2)
    _ = flag()
    stdout::write(greeting())
```

No `std/io/stdout.c` is written, because `std::io::stdout` only declares an external function and a constant (D1).

`hello.h`:

```c
#pragma once

#include "runtime/monolith.h"

int32_t mn_hello_add(int32_t left, int32_t);
bool mn_hello_flag();
string mn_hello_greeting();
```

`hello.c`:

```c
#include "hello.h"
#include "std/io/stdout.h"

int32_t mn_hello_add(int32_t left, int32_t) {
    return left;
}

bool mn_hello_flag() {
    return true;
}

string mn_hello_greeting() {
    return (string){ "hello\n", 6 };
}

int main() {
    mn_hello_add(1, 2);
    mn_hello_flag();
    mn_runtime_stdout_write(mn_hello_greeting());
}
```

`std/io/stdout.h`:

```c
#pragma once

#include "../../runtime/monolith.h"

void mn_runtime_stdout_write(string text);
```

### A program with its own module

`hello.mn`:

```monolith
fn main(): _ = utils::math::add(1, 2)
```

`utils/math.mn`:

```monolith
fn add(left: i32, right: i32) i32:
    _ = right
    return left
```

`hello.c` and `utils/math.c`:

```c
#include "hello.h"
#include "utils/math.h"

int main() {
    mn_utils_math_add(1, 2);
}
```

```c
#include "math.h"

int32_t mn_utils_math_add(int32_t left, int32_t) {
    return left;
}
```

### A program with structs

`hello.mn`:

```monolith
struct Point:
    x: i32
    y: i32

struct Line:
    start: Point
    end: Point

fn length(line: Line) i32: return line.start.x
```

`hello.h`:

```c
#pragma once

#include "runtime/monolith.h"

typedef struct mn_hello_Point {
    int32_t x;
    int32_t y;
} mn_hello_Point;

typedef struct mn_hello_Line {
    mn_hello_Point start;
    mn_hello_Point end;
} mn_hello_Line;

int32_t mn_hello_length(mn_hello_Line line);
```

### Invalid programs

```monolith
fn small() u8: return 300
```

→ `1:23: error: literal out of range for its type` (T7)

```monolith
fn ratio() f64: return 2
```

→ `1:24: error: value does not match the expected type` (T6)

```monolith
fn one() i32: return 1
fn main(): one()
```

→ `2:12: error: call result is unused, discard it with _ =` (F6)

```monolith
fn take(value: i32): _ = value
fn main(): take()
```

→ `2:12: error: wrong number of arguments` (F1)

```monolith
fn twice(add: i32): add(add)
```

→ `1:21: error: name is not a function` (N6)

```monolith
fn main():
    noop
  noop
```

→ `3:1: error: indentation does not match any outer level` (S8)

```monolith
fn value() u8: return 007
```

→ `1:24: error: unexpected character` (L13)

```monolith
fn name() String: return "a\qb"
```

→ `1:28: error: unknown escape sequence` (L20)

```monolith
external fn log(): noop
```

→ `1:18: error: external functions have no body` (S17)

```monolith
fn mn_write(): noop
```

→ `1:1: error: name is reserved` (N14)

```monolith
const one = two
const two = one

fn main(): one()
```

→ `1:1: error: constant refers to itself` (N13)

```monolith
const limit = 5

fn main(): _ = one()
fn one() i32: return limit
```

→ `1:15: error: value has no known type` (N10)

```monolith
struct Point:
    x: void

fn show(point: Point): noop
```

→ `2:8: error: field cannot have type void` (T13)
