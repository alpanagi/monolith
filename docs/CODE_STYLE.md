## Module Layout

- A module starts with its imports, then its external functions, then its constants, then its other declarations.
- Imports come in two groups, separated by a blank line: first those from `mn`, then the program's own, e.g. `import mn::process::stdout` before `import cards::Card`. Each group is in alphabetical order, with uppercase before lowercase, e.g. `mn::process::Stdout` before `mn::process::stdin`.
- Two or more imports from one module are written as one group, the module itself included as `self`, e.g. `import mn::codec::{ self, Decode, Decoder }` instead of `import mn::codec`, `import mn::codec::Decode` and `import mn::codec::Decoder`. A single import is written without braces, e.g. `import mn::compare::Equal`, not `import mn::compare::{ Equal }`.
- Inside the braces `self` comes first, then the names in the order imports have, e.g. `{ self, Decode, Decoder, Encode, Encoder }`. A group stands where its path would, e.g. `import mn::codec::{ self, Decode }` before `import mn::compare::Equal`.
- External functions and constants are each in alphabetical order.
- Declarations that belong together stay together, the module's main ones first, and a helper comes after the first declaration that uses it.
- A module is named after its topic, in the singular, e.g. `container`, `iterator`, `memory`. The name is a whole word, e.g. `filesystem`, not `fs`. The name says what the module is about, not what it holds, so it stays right when the module grows.

## Naming

- A boolean that states a fact reads as a yes or no question, e.g. `is_absolute`, `has_value`.
- A boolean option is named as the command, e.g. `create_ancestors` in `create_directory(path, { create_ancestors = true })`. An option that is one of a list of choices is named as an adjective, e.g. `Prefixed` in `{ base = ::Prefixed }`.
- A function that builds a value of its type is named `init`, e.g. `ArrayList(u8)::init()`.
- Inside a struct's block and an instance's block, the type the block is about is written `Self`, e.g. `fn init -> Self` and `fn encode(record: const(*Self), encoder: *Encoder) -> !void`. A type that only happens to equal it stays written, e.g. the `u64` every `hash` returns in `instance Hash(u64)`.
- A parameter that takes any type with an instance has the typeclass as its type, e.g. `encoder: *Encoder`. A type parameter is named only when the type is written a second time, e.g. `fn decode(self: *D, type T: Decode) -> !T`.
- A declaration can shadow an earlier one, which is useful when the new value replaces the old, e.g. `const home = process::environment::variable("HOME")` followed by `const home = home orelse return Error::MissingHome`. This avoids a name made up only to tell the two apart, e.g. `maybe_home`.

## Layout

- Two blank lines separate top-level functions, constants, structs, enums, error sets, typeclasses and instances, and the functions in a struct's, typeclass's or instance's block. One blank line separates groups of statements inside a function. Consecutive one-line functions, and consecutive one-line constants, can stay together. External functions stay together.
- Fields and cases follow their header directly, and one blank line separates them from the functions after them. A struct, enum, typeclass or instance without fields or cases has one blank line between its header and its first function, e.g. `instance Deinit(Record)`, a blank line, then `fn deinit(record: *Record)`.
- A function without parameters is declared without parentheses, with a body on the same line, with a block, or without a body, e.g. `fn init -> Self = {}`, `fn now -> Self` and `fn Cursor -> type`. It is still called with them, e.g. `WallTime::now()`.

## Literals

- A struct literal leaves out its type when the surrounding code gives it, e.g. `return { directory = directory }`, and a declaration gives it with an annotation, e.g. `const stdout: Stdout = {}`. It writes the type only where nothing gives it, e.g. `Foo{}.area()`.
- A struct, tuple or array literal with contents has one space after `{` and one before `}`, e.g. `{ x = 1, y = { a = 2 } }` and `{ name, count }`. An empty literal is `{}`.

## Errors

- A library's functions write their error sets; other functions infer them, e.g. `fn main -> !void`.

## Resources

- Clean up with `defer` right after acquiring, e.g. `defer file.close()` or `defer list.deinit()`. A function that returns what it acquired uses `errdefer` instead, e.g. `errdefer path.deinit()`.
