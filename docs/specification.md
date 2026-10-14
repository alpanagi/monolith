## Overview

Monolith is a statically typed language that compiles to readable source code in another language, called the target. The supported targets are JavaScript and C (C23).

This specification is the reference for writing Monolith. Every rule has an identifier, such as `L3` or `T7`. A rule that rejects a program states the error message the compiler reports.

Errors are reported as `path:row:column: error: message`. Rows and columns start at 1, and columns count bytes. The examples in this document show only `row:column: error: message`.

A program is a single source file. The compiler stops at the first error.

## Grammar

The grammar uses this notation:

| Notation | Meaning |
|---|---|
| `"fn"` | the literal text |
| `a b` | `a` followed by `b` |
| `a \| b` | `a` or `b` |
| `[ a ]` | `a`, optionally |
| `{ a }` | `a`, repeated zero or more times |

`name`, `integer`, `float`, `string` and `newline` are defined in the Lexical structure chapter (L2, L6, L12 to L16, L18 to L22). The indentation of lines is described in S6 to S8.

```
module         = { function }
function       = "fn" name "(" [ parameters ] ")" [ type ] ":" block
parameters     = parameter { "," parameter } [ "," ]
parameter      = name ":" type
type           = "i8" | "i16" | "i32" | "i64" | "u8" | "u16" | "u32" | "u64"
               | "f32" | "f64" | "Bool" | "String"
block          = statement | indented_block
indented_block = newline statement { newline statement }
statement      = "noop" | "return" [ expression ] | "_" "=" call | call
expression     = integer | float | string | "true" | "false" | name | call
call           = name "(" [ arguments ] ")"
arguments      = expression { "," expression } [ "," ]
```

## Lexical structure

### Characters and lines

- **L1.** Source files are ASCII. Any character not described in this chapter is rejected with `unexpected character`.
- **L2.** A line ends with a line feed (`\n`) or a carriage return followed by a line feed (`\r\n`). A carriage return on its own is rejected with `unexpected character`.
- **L3.** Spaces separate tokens. Outside string literals, tabs are rejected with `tabs are not allowed, use spaces`. Inside string literals, L22 applies.
- **L4.** The first line of a file cannot start with a space. It is rejected with `unexpected character` at 1:1.
- **L5.** The number of spaces at the start of a line is its indentation. A line containing only spaces is blank and is ignored, whatever its indentation.

### Words

- **L6.** A word starts with a letter or `_` and continues with letters, digits and `_`.
- **L7.** These words are keywords: `fn`, `noop`, `return`, `true`, `false`.
- **L8.** These words are type names: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`, `Bool`, `String`. Type names that state a size in bits are lowercase. All other type names start with a capital letter.
- **L9.** A lone `_` is the discard symbol. It is not a name.
- **L10.** Every other word is a name. Keywords, type names and `_` cannot be used as names.

### Symbols

- **L11.** The symbols are `(`, `)`, `:`, `,` and `=`.

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
- **L16.** A number literal may end with a type suffix, optionally separated by `_`: `5u8`, `1_000_u32`, `2.5f32`, `1.0_f64`.
  - An integer literal takes an integer type suffix: `i8` to `u64`.
  - A float literal takes `f32` or `f64`. `1f64` is rejected: write `1.0f64`.
  - In hexadecimal literals, `f` is a digit, so `0x1f32` is the number `0x1F32` without a suffix.
- **L17.** A letter, digit or `_` directly after a number literal that is not a valid suffix is rejected with `unexpected character`.

### String literals

- **L18.** A string literal is text between double quotes on a single line: `"hello"`.
- **L19.** Between the quotes, a string literal contains printable ASCII characters other than `"` and `\`, and these escapes:

  | Escape | Character |
  |---|---|
  | `\n` | line feed |
  | `\t` | tab |
  | `\\` | backslash |
  | `\"` | double quote |

- **L20.** A `\` followed by any other character is rejected with `unknown escape sequence`, at the `\`.
- **L21.** A string literal that reaches the end of its line or of the file without a closing `"` is rejected with `unterminated string`, at its opening `"`.
- **L22.** Any other character inside a string literal, such as a tab, is rejected with `unexpected character`.

## Program structure

### Modules

- **S1.** A source file is a module: a sequence of function definitions at indentation 0, separated by any number of blank lines.
- **S2.** Anything other than a function definition at top level is rejected with `unexpected token`. An indented line at top level is rejected with `unexpected indentation`.

### Functions

- **S3.** A function has a name, a parameter list, an optional return type and a block, following the `function` rule: `fn add(left: i32, right: i32) i32:`.
- **S4.** A trailing `,` after the last parameter is allowed.
- **S5.** A missing return type means the function returns `void`. `void` cannot be written.

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

## Names

- **N1.** Function names are unique within a module. A second function with the same name is rejected with `function is already defined`, at its `fn`.
- **N2.** Parameter names are unique within a parameter list. A repeated name is rejected with `parameter is already defined`, at the second parameter.
- **N3.** A function can call functions defined before or after it.
- **N4.** A name is looked up first among the parameters of the enclosing function, then among the module's functions. A parameter shadows a function with the same name.
- **N5.** A name that matches neither is rejected with `unknown name`.
- **N6.** A call to a name that refers to a parameter is rejected with `name is not a function`.
- **N7.** A function name that is not directly followed by a call is rejected with `functions cannot be used as values`.

## Types

### Primitive types

- **T1.** The primitive types are:

  | Type | Values |
  |---|---|
  | `i8`, `i16`, `i32`, `i64` | signed integers of 8, 16, 32 and 64 bits |
  | `u8`, `u16`, `u32`, `u64` | unsigned integers of 8, 16, 32 and 64 bits |
  | `f32`, `f64` | 32-bit and 64-bit floating point numbers |
  | `Bool` | `true` and `false` |
  | `String` | text, made of ASCII characters for now |
  | `void` | no value; only as the return type of a function without one |

- **T2.** There are no implicit conversions between types.
- **T3.** What happens when arithmetic exceeds a type's range is left to the target. It is not defined by Monolith.

### Types of expressions

- **T4.** `true` and `false` have type `Bool`, and a string literal has type `String`.
- **T5.** A number literal with a suffix has the suffix's type. A number literal without a suffix takes the type its context expects: the function's return type for a returned value, or the parameter's type for an argument.
- **T6.** An integer literal can only have an integer type, and a float literal only a float type. `return 2` in an `f64` function is rejected: write `2.0`.
- **T7.** An integer literal must not exceed its type's maximum, and a float literal must not overflow its type to infinity. Otherwise it is rejected with `literal out of range for its type`. A float literal too small for its type becomes 0 and is accepted.
- **T8.** A name has the type of the parameter it refers to.
- **T9.** A call has the return type of the called function.
- **T10.** An expression whose type differs from the expected type is rejected with `value does not match the expected type`. This includes a call to a `void` function where a value is expected.

## Functions

- **F1.** A call passes exactly as many arguments as the function has parameters. Otherwise it is rejected with `wrong number of arguments`.
- **F2.** Each argument must have the type of its parameter (T10).
- **F3.** A `void` function returns with `return` without a value. `return` with a value in a `void` function is rejected with `void function cannot return a value`.
- **F4.** A function with a return type returns with `return` and a value. `return` without a value is rejected with `missing return value`.
- **F5.** The last statement of a function with a return type must be `return`. Otherwise the function is rejected with `function must end with a return`, at its return type.
- **F6.** A call statement must call a `void` function. A call to any other function on its own is rejected with `call result is unused, discard it with _ =`.
- **F7.** `_ =` must call a function that returns a value. Discarding a call to a `void` function is rejected with `call returns no value to discard`.

### The main function

- **F8.** `main` is the program's entry point. A module does not need one.
- **F9.** `main` has no parameters and no return type. Otherwise it is rejected with `main cannot have parameters` or `main cannot have a return type`.
- **F10.** `main` cannot be called. A call to it is rejected with `main cannot be called`.

## Targets

### Names in the output

- **G1.** A name keeps its spelling in the output, unless it is a reserved word of the target or ends with `_`. Then `_` is appended. In C, `string` and `MONOLITH_H` are also reserved, because the output defines them (C1). `delete` becomes `delete_` in JavaScript, `int` becomes `int_` in C, and `count_` becomes `count__` in both. Two different names never produce the same output name.

### JavaScript

- **J1.** Each function becomes a `function` declaration with the same parameters, without types.
- **J2.** A function whose body only contains `noop` becomes an empty function, `{}`.
- **J3.** Values of `i64` and `u64` are JavaScript BigInts, so every value of these types is exact. All other number types are JavaScript numbers.
- **J4.** Number literals keep their base and separators and lose their suffix: `0xff_ff_u32` becomes `0xff_ff`. Literals of type `i64` or `u64` end with `n`: `1_000_i64` becomes `1_000n`.
- **J5.** `_ = add(1, 2)` becomes the plain call, `add(1, 2);`.
- **J6.** `String` values are JavaScript strings. String literals are written exactly as in the source: `"line\n"` stays `"line\n"`.
- **J7.** If the module defines `main`, the output ends with a call to it, `main();`, after all functions.

### C

- **C1.** The output is C23. Every file starts with `#include "monolith.h"`. That header is written next to it and contains the definitions the output relies on:

  ```c
  #ifndef MONOLITH_H
  #define MONOLITH_H

  #include <stddef.h>
  #include <stdint.h>

  typedef struct { const char *bytes; size_t length; } string;

  #endif
  ```

- **C2.** Every function except `main` becomes a `static` function, and a declaration of each follows the include, so functions can call each other in any order.
- **C3.** `main` becomes `int main()`. A `return` without a value inside `main` becomes `return 0;`.
- **C4.** Types become C types:

  | Monolith | C |
  |---|---|
  | `i8` to `i64` | `int8_t` to `int64_t` |
  | `u8` to `u64` | `uint8_t` to `uint64_t` |
  | `f32`, `f64` | `float`, `double` |
  | `Bool` | `bool` |
  | `String` | `string` |
  | `void` | `void` |

- **C5.** Number literals keep their base. `_` becomes `'`, `0o` becomes `0`, the suffix is removed, and literals of unsigned types end with `u`: `0o7_5_5` returned from a `u16` function becomes `07'5'5u`.
- **C6.** `_ = add(1, 2)` becomes the plain call, `add(1, 2);`.
- **C7.** A string literal becomes a `string` holding the literal as written and its length in bytes, counting each escape as one byte: `"line\n"` becomes `(string){ "line\n", 5 }`.

## Compiler

- **K1.** The compiler is invoked as `monolith --target <javascript|c> <file.mn>`. Any other arguments print `usage: monolith --target <javascript|c> <file.mn>`.
- **K2.** The source file name must end with `.mn` and have a name before it.
- **K3.** The output is written to `build/<target>/<name>.<extension>`, where `<name>` is the source file name without `.mn` and the extension is `js` or `c`. The C target also writes `build/c/monolith.h` (C1). No file is written when compilation fails.
- **K4.** The compiler exits with status 0 on success and 1 on any error.

## Examples

### A valid program

```monolith
fn add(left: i32, right: i32) i32: return left

fn flag() Bool:
    return true

fn greeting() String: return "hello\n"

fn main():
    _ = add(1, 2)
    _ = flag()
    _ = greeting()
```

JavaScript:

```javascript
function add(left, right) {
    return left;
}

function flag() {
    return true;
}

function greeting() {
    return "hello\n";
}

function main() {
    add(1, 2);
    flag();
    greeting();
}

main();
```

C:

```c
#include "monolith.h"

static int32_t add(int32_t left, int32_t right);
static bool flag();
static string greeting();

static int32_t add(int32_t left, int32_t right) {
    return left;
}

static bool flag() {
    return true;
}

static string greeting() {
    return (string){ "hello\n", 6 };
}

int main() {
    add(1, 2);
    flag();
    greeting();
}
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
