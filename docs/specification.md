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
declaration          = function | external_function | constant
function             = function_declaration ":" block
external_function    = "external" function_declaration
function_declaration = "fn" name "(" [ parameters ] ")" [ type ]
parameters           = parameter { "," parameter } [ "," ]
parameter            = name ":" type
type                 = expression
block                = statement | indented_block
indented_block       = newline statement { newline statement }
statement            = "noop" | "return" [ expression ] | "_" "=" call | call
expression           = integer | float | string | "true" | "false" | path | call
call                 = path "(" [ arguments ] ")"
arguments            = expression { "," expression } [ "," ]
path                 = name { "::" name }
constant             = "const" name "=" ( expression | struct )
struct               = "struct" [ ":" fields ]
fields               = newline field { newline field }
field                = name ":" type
```

## Lexical structure

### Characters and lines

- **L1.** Source files are ASCII outside string literals, which can contain any bytes (L19). Any character not described in this chapter is rejected with `unexpected character`.
- **L2.** A line ends with a line feed (`\n`) or a carriage return followed by a line feed (`\r\n`). A carriage return on its own is rejected with `unexpected character`.
- **L3.** Spaces separate tokens. Outside string literals, tabs are rejected with `tabs are not allowed, use spaces`.
- **L4.** The first line of a file cannot start with a space. It is rejected with `unexpected character` at 1:1.
- **L5.** The number of spaces at the start of a line is its indentation. A line containing only spaces is blank and is ignored, whatever its indentation.

### Words

- **L6.** A word starts with a letter or `_` and continues with letters, digits and `_`.
- **L7.** These words are keywords: `fn`, `external`, `const`, `struct`, `noop`, `return`, `true`, `false`.
- **L8.** The built-in types (T1) are named `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`, `Bool`, `String` and `void`. The names that state a size in bits, and `void`, are lowercase. The others start with a capital letter. Type names are names, not keywords.
- **L9.** A lone `_` is the discard symbol. It is not a name.
- **L10.** Every other word is a name. Keywords and `_` cannot be used as names. The built-in type names and names that start with `mn_` are reserved (N14).

### Symbols

- **L11.** The symbols are `(`, `)`, `:`, `::`, `,` and `=`. Two `:` with nothing between them are the symbol `::`.

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

- **S1.** A source file is a module: a sequence of declarations at indentation 0, in any order, separated by any number of blank lines. A declaration is a function, an external function or a constant (N10).
- **S2.** Anything other than a declaration at top level is rejected with `unexpected token`. An indented line at top level is rejected with `unexpected indentation`.

### Functions

- **S3.** A function is a function declaration, made of its name, parameters and return type, followed by a block (the `function` rule): `fn add(left: i32, right: i32) i32:`.
- **S4.** A trailing `,` after the last parameter is allowed.
- **S5.** A missing return type is the return type `void`. `fn main():` and `fn main() void:` are the same.

### Blocks

- **S6.** A block is either inline or indented.
  - An inline block is a single statement on the same line as the `:`.
  - An indented block starts on the next line. Its first line sets the block's indentation, which must be greater than 0. Every following line of the block has exactly that indentation.
- **S7.** An indented block ends at the first line indented at 0, or at the end of the file.
- **S8.** Errors in indented blocks:

  | Situation | Error |
  |---|---|
  | No indented line follows the `:` | `expected an indented block` |
  | A line is indented more than the block | `unexpected indentation` |
  | A line is indented less than the block but more than 0 | `indentation does not match any outer level` |

### Statements

- **S9.** `noop` does nothing.
- **S10.** `return` ends the function. Its value, if any, is on the same line.
- **S11.** `_ = add(1, 2)` calls a function and discards its result. Anything other than a call after `_ =`, such as `_ = 5`, is rejected with `expected a call`.
- **S12.** A call on its own, such as `log(1)`, is a statement. A name or literal on its own is rejected with `expected a statement`.
- **S13.** Each statement is on its own line, except for the single statement of an inline block.

### Expressions

- **S14.** A trailing `,` after the last argument is allowed: `add(1, 2,)`.

### External functions

- **S15.** An external function is a function declaration that the program calls but does not define: `external fn write(text: String)`. Its definition is written in the target's code. The standard library's external functions are defined by the target's runtime (D2). Every external function is called by its exact name (C8).
- **S16.** An external function has no body. A `:` after its declaration is rejected with `external functions have no body`.

### Structs

- **S17.** A struct is a type made of fields. It is written as the value of a constant: `struct:` followed by an indented block with one field on each line. A field is a name and a type, `x: i32`. A line of the block that is not a field is rejected with `expected a field`.

  ```monolith
  const Point = struct:
      x: i32
      y: i32
  ```

- **S18.** A struct without fields is written `struct`, without the `:`: `const Marker = struct`.

## Modules

- **M1.** Every source file is a module. The file given to the compiler is the main module. A module's path is the path of its file, with directories separated by `::` and without `.mn`: `utils/math.mn` is the module `utils::math`, and the main file `hello.mn` is the module `hello`.
- **M2.** Every module's file name, without `.mn`, and every directory name in a module path must be a valid name (L6, L10). Paths can only spell valid names, so only the main file's name is checked (K2).
- **M3.** Every path is a namespace. A namespace is a module when a file has its path (M1), and it contains the namespaces whose paths continue its path: `std::io` contains `std::io::stdout`. A namespace can be both: with `utils.mn` and `utils/math.mn`, `utils` is a module and contains `utils::math`. A path reaches namespaces directly: `std::io::stdout::write("hello\n")` calls `write` in the module `std::io::stdout`.
- **M4.** A path that starts with `std` refers to the standard library, which comes with the compiler (K5). Every other path is a namespace of the program, relative to the directory of the main file, from every module.
- **M5.** The first name of a path that continues with `::` is looked up only among namespaces: first the module's constants that name a namespace, then `std`, then the program's namespaces (M4).
- **M6.** The namespaces a namespace contains are reached through it: `std::io::stdout::write("hello\n")`. A namespace that is a module and contains namespaces reaches both its module's functions and its namespaces: `utils::add()` and `utils::math::add()`.
- **M7.** Each module is loaded once, however often it is reached, and modules can reach each other. Loading starts with the main module, and a module is read when resolving a module that is already loaded reaches it. Nothing else is read.
- **M8.** Every declaration of a module can be used by the other modules through a path, external functions and constants included.
- **M9.** In a namespace that contains namespaces, a name before a `::` that is none of them is rejected with `module not found`, at the path.
- **M10.** The name `monolith` is reserved. A path whose first name is `monolith` is rejected with `module name is reserved`.
- **M11.** If the main file's directory has its own `std.mn` or `std/`, a path whose first name is `std` is rejected with `name is ambiguous`.

## Names

- **N1.** Function and constant names are unique within a module, external functions included. A second function with the name of a function or constant is rejected with `function is already defined`, at its `fn` or `external`. A second constant with the name of a function or constant is rejected with `constant is already defined`, at its `const`.
- **N2.** Parameter names are unique within a parameter list, and field names within a struct. A repeated name is rejected with `parameter is already defined` or `field is already defined`, at the second parameter or field.
- **N3.** A function can call functions defined before or after it.
- **N4.** A name is looked up first among the parameters of the enclosing function, then among the module's functions and constants, then among the built-in types (T1), then among `std` and the program's namespaces (M4). A name in a type (T11) is not looked up among the parameters.
- **N5.** A name that matches none of them is rejected with `unknown name`.
- **N6.** A call to a name that does not refer to a function, such as a parameter, a type, a namespace or a constant whose value is a literal, is rejected with `name is not a function`.
- **N7.** A function used as a value, named directly, through a path or through a constant, is rejected with `functions cannot be used as values`. A namespace used as a value is rejected with `unknown name`. A type can be used as a value (T11).
- **N8.** A path is resolved one name at a time. The first name is looked up as M5 describes. Each following name before a `::` goes through a namespace (M6): a constant of its module that names a namespace comes first, then the namespaces it contains. The last name is a declaration of the module reached, or a namespace it contains. A function and a namespace can have the same name: with `fn math()` in `utils.mn` and the module `utils::math`, `utils::math()` calls the function and `utils::math::add()` calls into the module. A parameter does not hide a namespace before a `::`: with a parameter `utils`, `utils::add()` still calls into the module `utils`.
- **N9.** Errors in a path, at the path:

  | Situation | Error |
  |---|---|
  | The first name does not exist | `unknown name` |
  | A `::` follows a parameter, a declaration or a built-in type, and no namespace has its name | `name has no members` |
  | A name before a `::` is none of the namespaces that its namespace contains (M9) | `module not found` |
  | The module reached does not declare the last name | `unknown name` |
  | The last name of a call is a namespace | `name is not a function` |

### Constants

- **N10.** `const name = expression` declares a constant. Its value is evaluated at compile time, and can be a function, a type, a namespace or a literal. `const stdout = std::io::stdout` lets `stdout::write(...)` reach the module, `const write = mn_runtime_stdout_write` lets `write(...)` call the function, `const Integer = i32` lets `Integer` be used as a type, and `const limit = 5i32` lets `limit` be used as a value of type `i32`.
  - A number literal as the value has a suffix, which gives its type (T5): `const limit = 5i32`. Otherwise it is rejected with `value has no known type`, at the literal.
  - Errors in a literal value are reported at the literal, in the module of the constant.
- **N11.** A constant means the same as its value, so every rule for that value applies to it. A constant produces no output: each use writes what the constant names, such as the function it calls or its literal. A struct is the exception, because C defines it (C10).
- **N12.** A constant is only resolved and checked when something uses it. An unused constant is not an error, because other modules can use it (M8), and the modules its value names are not loaded for it (M7).
- **N13.** A used constant whose value reaches itself, directly or through other constants, is rejected with `constant refers to itself`, at its `const`. This includes a struct that contains itself, directly or through the fields of other structs.

### Reserved names

- **N14.** A function, external function, parameter, constant or field whose name starts with `mn_` is rejected with `name is reserved`, at its `fn`, `external` or `const`, or at the parameter or field. The modules of the standard library may use these names, because they declare the runtime's functions (D2). A function, external function, parameter, constant or field named like a built-in type (T1) is rejected with `name is reserved` in every module, the standard library included.

## Types

### Built-in types

- **T1.** The built-in types are:

  | Type | Values |
  |---|---|
  | `i8`, `i16`, `i32`, `i64` | signed integers of 8, 16, 32 and 64 bits |
  | `u8`, `u16`, `u32`, `u64` | unsigned integers of 8, 16, 32 and 64 bits |
  | `f32`, `f64` | 32-bit and 64-bit floating point numbers |
  | `Bool` | `true` and `false` |
  | `String` | text, stored as bytes in any encoding |
  | `void` | no value; only as a return type |

  A parameter of type `void` is rejected with `parameter cannot have type void`, at its type.

- **T2.** There are no implicit conversions between types.
- **T3.** What happens when arithmetic exceeds a type's range is left to the target. It is not defined by Monolith.

### Types of expressions

- **T4.** `true` and `false` have type `Bool`, and a string literal has type `String`.
- **T5.** A number literal with a suffix has the suffix's type, and the suffix must be the name of a number type. Any other suffix is rejected with `unknown suffix`, at the literal: `5Bool`. A number literal without a suffix takes the type its context expects: the function's return type for a returned value, or the parameter's type for an argument.
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

## Functions

- **F1.** A call passes exactly as many arguments as the function has parameters. Otherwise it is rejected with `wrong number of arguments`.
- **F2.** Each argument must have the type of its parameter (T10).
- **F3.** A `void` function returns with `return` without a value. `return` with a value in a `void` function is rejected with `void function cannot return a value`.
- **F4.** A function with a return type returns with `return` and a value. `return` without a value is rejected with `missing return value`.
- **F5.** The last statement of a function with a return type must be `return`. Otherwise the function is rejected with `function must end with a return`, at its return type.
- **F6.** A call statement must call a `void` function. A call to any other function on its own is rejected with `call result is unused, discard it with _ =`.
- **F7.** `_ =` must call a function that returns a value. Discarding a call to a `void` function is rejected with `call returns no value to discard`.

### The main function

- **F8.** The main module's `main` is the program's entry point. A module does not need one. Any module may define `main`, but only the main module's `main` is the entry point.
- **F9.** Every `main` has no parameters and returns `void`. Otherwise it is rejected with `main cannot have parameters` or `main cannot have a return type`.
- **F10.** No `main` can be called. A call to it is rejected with `main cannot be called`.
- **F11.** `main` cannot be an external function. An external `main` is rejected with `main cannot be external`.

## Targets

### Names in the output

- **G1.** Names are written to the output exactly as they are in the source, except the generated names: C function names (C9) and C struct names (C10). A generated name is `mn_` followed by the module path with `::` replaced by `_`, so it cannot be a name written in the source (N14).
- **G2.** A function, external function, parameter or field whose name, as written to the output, the target already defines is rejected with `name is already defined in the target`, at the function's `fn` or `external` keyword or at the parameter or field. Constants are not checked, because they produce no output (N11), or a generated name for a struct (C10). A function's name is checked as it is written to the output: `fn int(): noop` becomes `mn_hello_int` (C9) and is accepted, but a parameter named `int` is rejected.
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

- **C2.** Every module becomes a `.h` file, and a module that defines functions also becomes a `.c` file (K3).
  - The `.h` file starts with `#pragma once`. It includes `runtime/monolith.h`, then the header of every other module whose structs its structs contain. Then it defines the module's structs (C10). Then it declares each struct of another module that its function declarations use, with `typedef struct mn_shapes_Line mn_shapes_Line;`. Last, it declares the module's functions: first its external functions, then, after a blank line, its other functions. The main module's `main` is not declared.
  - The `.c` file includes its own header, then the header of every other module that its calls reach or whose structs its functions use, in the order of their first use, and then defines its functions.
  - Includes use paths relative to the file: `#include "std/io/stdout.h"`.
  - No function is `static`, so any module can be imported, the main module included.
- **C3.** The main module's `main` becomes `int main()`. A `return` without a value inside it becomes `return 0;`.
- **C4.** Types become C types:

  | Monolith | C |
  |---|---|
  | `i8` to `i64` | `int8_t` to `int64_t` |
  | `u8` to `u64` | `uint8_t` to `uint64_t` |
  | `f32`, `f64` | `float`, `double` |
  | `Bool` | `bool` |
  | `String` | `string` |
  | `void` | `void` |
  | a struct | its C name (C10) |

- **C5.** Number literals keep their base. `_` becomes `'`, `0o` becomes `0`, the suffix is removed, and literals of unsigned types end with `u`: `0o7_5_5` returned from a `u16` function becomes `07'5'5u`.
- **C6.** `_ = add(1, 2)` becomes the plain call, `mn_hello_add(1, 2);` (C9).
- **C7.** A string literal becomes a `string` holding the literal as written and its length in bytes, counting each escape as one byte: `"line\n"` becomes `(string){ "line\n", 5 }`.
- **C8.** An external function keeps exactly the name written in the source, so its definition, linked into the program, uses that name: `external fn stdout_write(text: String)` becomes `void stdout_write(string text);`. The runtime defines the standard library's external functions this way (D2).
- **C9.** C has one namespace for all files, so a function's C name is its module's generated name (G1), followed by `_` and its name: `greeting` in `hello.mn` becomes `mn_hello_greeting`, and `add` in `utils::math` becomes `mn_utils_math_add`. The main module's `main` stays `main`.
- **C10.** A struct that something uses (N12) becomes a `typedef` in the header of its module, with one field on each line. Its C name is its module's generated name (G1), followed by `_` and the name of its constant, as for functions (C9). The structs of a module are defined after the structs they contain.

  ```c
  typedef struct mn_hello_Point {
      int32_t x;
      int32_t y;
  } mn_hello_Point;
  ```

- **C11.** A zero-sized type is a struct whose fields all have zero-sized types, such as a struct without fields. It has no definition in C. Fields, parameters and arguments of a zero-sized type are left out, and a function that returns one returns `void`. A call that gives a zero-sized argument runs before the call that receives it: `use(make(marker), 1)` becomes `(mn_hello_make(), mn_hello_use(1))`. A returned call of a zero-sized type runs before the `return;`.
- **C12.** Modules whose structs contain each other's structs, directly or through other modules, are rejected with `modules contain each other's structs`, at the field.

## Compiler

- **K1.** The compiler is invoked as `monolith <file.mn>`, where the file name ends with `.mn` and has a name before it. Any other arguments print `usage: monolith <file.mn>`.
- **K2.** The file name without `.mn` must be a valid name (L6, L10), and neither a built-in type name (T1) nor `std` (M4). Otherwise the compiler stops with `error: file name must be a valid name`, before reading the file.
- **K3.** The output is written to `build/`, in the directory the compiler runs in. The C files are written to `build/source/`:
  - The main module is written as `<name>.h` and `<name>.c`, where `<name>` is the source file name without `.mn`.
  - Every other module is written at its module path, the standard library's modules included: `utils::math` as `utils/math.h` and `utils/math.c`, and `std::io::stdout` as `std/io/stdout.h`.
  - A module without functions, the main module included, gets no `.c` file (C2).
  - The runtime files whose functions the program calls are copied to `runtime/`, such as `runtime/stdout.c` (D2).
  - `runtime/monolith.h` is always copied (C1).
  - When the main module defines `main`, the compiler also builds the executable `build/<name>` with GCC, from every `.c` file of the output: `gcc -std=c23 -Wall -Wextra -pedantic -O2 -flto`. GCC's warnings are shown. If GCC cannot be run, the compiler stops with `error: cannot run gcc: <reason>`. If GCC fails, it stops with `error: gcc could not build the executable`. GCC runs after the output is written, so the C files stay when it fails.
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

## Examples

### A valid program

`hello.mn`:

```monolith
const stdout = std::io::stdout

fn add(left: i32, right: i32) i32: return left

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

int32_t mn_hello_add(int32_t left, int32_t right);
bool mn_hello_flag();
string mn_hello_greeting();
```

`hello.c`:

```c
#include "hello.h"
#include "std/io/stdout.h"

int32_t mn_hello_add(int32_t left, int32_t right) {
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
fn add(left: i32, right: i32) i32: return left
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

int32_t mn_utils_math_add(int32_t left, int32_t right) {
    return left;
}
```

### A program with structs

`hello.mn`:

```monolith
const Point = struct:
    x: i32
    y: i32

const Line = struct:
    start: Point
    end: Point

fn length(line: Line) i32: return 0
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
fn add(left: i32, right: i32) i32: return left
fn main(): _ = add(1)
```

→ `2:16: error: wrong number of arguments` (F1)

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

→ `1:18: error: external functions have no body` (S16)

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
const Point = struct:
    x: void

fn show(point: Point): noop
```

→ `2:8: error: field cannot have type void` (T13)
