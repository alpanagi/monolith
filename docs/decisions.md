## Direction

- **Transpile to readable source.** Monolith compiles to source code in other languages, not machine code, and the output must stay readable.
- **Host code only through external functions.** Monolith code reaches code of the target only through external functions (S16), so the rest of the language is not tied to any environment.
- **No borrow checker.** Keeping references valid is the programmer's responsibility, as in Zig. A borrow checker restricts programs and bloats them, especially performance-focused ones.

## Memory and errors

- **Explicit allocation.** Every allocation goes through an allocator the caller passes in.
- **Errors are values that carry data.** Like Rust's results, not Zig's bare error codes. Payloads that allocate go through an allocator.

## Types

- **Overflow is left to the target.** Defining it in the language would make Monolith describe platform details.
- **Types must be representable exactly.** A type whose values would change on a target cannot exist there, because it would change what the program means.
- **No arbitrary-width integers.** Types such as Zig's `u7` add casts everywhere and masking in the output.
- **Named types are capitalized.** Number types stay lowercase, because their names state their size in bits or as the size of a pointer (`i32`, `f64`, `usize`), and all other types start with a capital letter (`Bool`, `String`), so `String` looks like any other named type.
- **No integer literals for float types.** A float is written with its decimal point: `2.`, not `2`.
- **Tiny floats are accepted.** A float literal that rounds to zero is not an error.

## Syntax

- **No leading zeros.** `007` is rejected.
- **Float suffixes need a decimal point.** `1.0f64` instead of `1f64`, so a suffix never turns an integer into a float.
- **Comments start with `#`.**
- **Trailing commas are allowed.** A trailing comma can mark a list to be formatted over multiple lines.
- **Return types follow `->`.** As in Python and Rust, not directly after the parameters as in Zig and Go. `:` ends a signature, and an inline body follows it on the same line, so without `->`, `fn text(): String` (a body) and `fn text() String:` (a return type) differ only by the place of the `:`.
- **Names are snake case.** Functions, variables, constants, parameters, fields and modules use snake case, as in Rust, not camel case as Zig's functions do. Types use Pascal case.

## Functions

- **Unused values are rejected.** Return values, parameters and locals must be used or discarded with `_ =`, as in Zig. A silently dropped value is a common bug.
- **A parameter can be discarded in its declaration.** `_: Type`, for a function that must match a signature but does not use the value. `_ = value` also stays for parameters.
- **Parameters can shadow functions.**
- **`main` is optional.** A module does not need one, so libraries are possible.
- **Methods are declared inside their struct.** As in Zig and Kotlin. A type's functions are in one place, and in a struct that a generic function returns, the type parameters are in scope. Not in a separate `impl` block for the same type as in Rust, and not as top-level declarations as in Go.
- **The receiver is an explicit parameter.** Not an implicit `this` as in Kotlin, so every name in a body is declared.
- **A method is marked by the type `Self`, not by the name `self`.** A method is a function whose first parameter has the type `Self`, and `self` is an ordinary name whose type is written, as every parameter's type is: `self: Self`. As in Zig, which decides by the type. In Rust, the keyword `self` marks a method, which is left from its implicit receiver before version 0.6.
- **Only the written `Self` makes a method.** `fn show(card: Card)` in `struct Card` is not a method.
- **`Self` is a reserved name, as `String` is.** Not a keyword.
- **No extension functions.** Behavior for types declared elsewhere comes from traits, as in Rust. An extension is a trait that only one type implements.
- **No limit on nesting depth.** Like Zig, Rust, GCC and Clang, the compiler does not guard against deeply nested source.

## Traits

- **A trait as a parameter's type means a value.** `shape: Shape` takes a value whose type implements `Shape`, because functions that take values are the common case. A type parameter is marked with `type`: `type T: Hashable`.
- **Type parameters are constrained by traits.** In Zig, the type of every type is `type`, so a type parameter accepts any type, and a wrong type fails inside the generic code.
- **Every type parameter states its constraint.** `type T` alone is not a parameter. A type parameter without a constraint is `type T: Any`, so "no constraint" is a value that compile-time code can compute.
- **Traits can take type constructors.** As Haskell's higher-kinded classes: a trait can be implemented for `List` itself, and a call matches `List(Card)` against `F(A)`.
- **No proof system.** Types depend only on values known at compile time. Full dependent types, as in Idris, would need proofs written by the programmer.
- **Implementations are separate from types.** `impl Shape for Circle:` can be written for any type, including types declared elsewhere. A trait is not an interface that a type lists in its own declaration.
- **No orphan rule in programs.** Any file of a program may implement any trait for any type. When libraries exist, the orphan rule will apply to them, so two libraries cannot implement the same trait for the same type. Rust applies it to programs too.
- **Dot calls see only the traits in scope.** As in Rust, a trait's methods are called with `.` only where the trait is in scope, so unrelated traits with the same method name do not collide. Calls through a type, such as `Square::new()`, also see only the traits in scope.
- **Traits can have functions without `Self`.** Such as `fn new() -> Self`, which is called through the type: `Square::new()`. As Rust's `Default::default`.
- **No calls through a trait's path.** `Shape::area(square)` is rejected, and a trait's functions are called with `.` or through a type. Rust has these calls to choose between two traits in scope with the same method name. In Monolith, the file stops importing one of them.
- **`import` brings a trait into scope.** A declaration of its own, not a constant, and only for traits. It also binds the trait's name, as Rust's `use` does. The keyword is `import`, which most languages read the same way, not Rust's `use`.
- **Calls are resolved at compile time.** Type parameters give one instance for each type, and tagged unions cover a closed set of types. Most uses of Rust's `dyn` and Swift's `any` do not need dispatch at run time.
- **Vtables are written by hand.** As in Zig, whose `std.mem.Allocator` is a struct with a pointer to the value and a table of function pointers. There is no `dyn` as in Rust or `any` as in Swift, and no rules for which traits can be used at run time. The tables are visible in the source and in the output. Compile-time code can build them later, as ordinary code.
- **An implementation's default overrides the trait's.** A default value in a trait's function is used when the implementation declares none. Not rejected as in Swift, and implementations can declare their own, unlike Kotlin. Every call is resolved at compile time, so the implementation and its default are always known. Function pointers have no defaults, so a call through a vtable passes every argument, as in Zig.

## Strings

- **Text and bytes are separate types.** A `String` is an abstraction over a byte array, and string operations are defined on text, never on bytes.
- **Characters are Unicode code points.** Not grapheme clusters.
- **Code point validity is not checked.**
- **`String` is a single view type.** Its bytes are owned by something else: the program for literals, a byte buffer with an allocator for text built at runtime. There is no separate owned string type as in Rust.
- **C uses a pointer and a length.** A null-terminated `const char *` needs a scan to find its length and is a common source of security bugs.
- **No built-in print.** Printing is in the standard library (`std::io::stdout`), not in the language.

## Targets

- **C targets C23.** The output relies on C23's `bool` keyword, empty parameter lists meaning no parameters, binary literals and `'` digit separators.
- **GCC builds the executable.** Only GCC, with a release build.
