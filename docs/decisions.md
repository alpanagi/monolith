## Direction

- **Transpile to readable source.** Monolith compiles to source code in other languages, not machine code, and the output must stay readable.
- **Host code only through external functions.** Monolith code reaches code of the target only through external functions (S15), so the rest of the language is not tied to any environment.
- **No borrow checker.** Keeping references valid is the programmer's responsibility, as in Zig. A borrow checker restricts programs and bloats them, especially performance-focused ones.

## Memory and errors

- **Explicit allocation.** Every allocation goes through an allocator the caller passes in.
- **Errors are values that carry data.** Like Rust's results, not Zig's bare error codes. Payloads that allocate go through an allocator.

## Types

- **Overflow is left to the target.** Defining it in the language would make Monolith describe platform details.
- **Types must be representable exactly.** A type whose values would change on a target cannot exist there, because it would change what the program means.
- **No arbitrary-width integers.** Types such as Zig's `u7` add casts everywhere and masking in the output.
- **Named types are capitalized.** Types that state a size in bits stay lowercase (`i32`, `f64`), and all other types start with a capital letter (`Bool`, `String`), so `String` looks like any other named type.
- **No integer literals for float types.** A float is written with its decimal point: `2.`, not `2`.
- **Tiny floats are accepted.** A float literal that rounds to zero is not an error, as in Zig and Rust.

## Syntax

- **No leading zeros.** `007` is rejected.
- **Float suffixes need a decimal point.** `1.0f64` instead of `1f64`, so a suffix never turns an integer into a float.
- **Trailing commas are allowed.** A trailing comma can mark a list to be formatted over multiple lines.

## Functions

- **Results must be used or discarded explicitly.** A silently dropped result is a common bug, so a call that returns a value needs `_ =` to stand alone.
- **Only calls can be discarded.** Discarding a literal or a `void` call has no meaning.
- **Parameters can shadow functions.** As in Rust.
- **`main` is optional.** A module does not need one, so libraries are possible.
- **No limit on nesting depth.** Like Zig, Rust, GCC and Clang, the compiler does not guard against deeply nested source.

## Strings

- **Text and bytes are separate types.** A `String` is an abstraction over a byte array, and string operations are defined on text, never on bytes.
- **Characters are Unicode code points.** Not grapheme clusters.
- **Code point validity is not checked.**
- **`String` is a single view type.** Its bytes are owned by something else: the program for literals, a byte buffer with an allocator for text built at runtime. There is no separate owned string type as in Rust.
- **C uses a pointer and a length.** A null-terminated `const char *` needs a scan to find its length and is a common source of security bugs.
- **No built-in print.** Printing is in the standard library (`std::console`), not in the language.

## Targets

- **C targets C23.** The output relies on C23's `bool` keyword, empty parameter lists meaning no parameters, binary literals and `'` digit separators.
- **GCC builds the executable.** Only GCC, with a release build.
