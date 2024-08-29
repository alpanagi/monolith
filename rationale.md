# Rationale

This language is inspired by Rust, TypeScript, Python, and others.

## Inspiration from Rust

### Traits

The ability to implement functionality for a type without affecting that type's codebase is invaluable.

### Redeclare a Variable with a Different Type

Rust allows you to use `let` with a previously defined variable name and reuse the variable with different types. This is a significant boost in ergonomics.

### Pattern Matching

## Inspiration from Typescript

### Module System

TypeScript's modules are only read and executed once when imported.

## Inspiration from Python

### Code Readability

Python has arguably the most readable codebases. Lower level programming languages usually have C style syntax (probably because of both the target audience and developer familiarity). I would like to create a language that strives to be as readable as Python while providing the language constructs needed in a performance focused language.


## Limitations of Rust

### Memory Management

While memory management is awesome in itself, most applications do not benefit from the trade-off between code complexity and performance. A garbage collector based solution works best in the majority of cases. The JVM goes even further and offers GCs with different characteristics to fine tune performance. I view this as the limit of performance based engineering decisions I would want to make regarding memory management.

### Ergonomics

Rust is a pleasure to write, until it isn't. Types in async contexts become unwieldy fast.

## Limitations of TypeScript

### Association with JavaScript

TypeScript is tied to JavaScript (`Align with current and future ECMAScript proposals.`, and `Use a consistent, fully erasable, structural type system.` are some of the design goals). While this is great for adoption by existing JavaScript users it also means that the language is bound to all decisions made by JavaScript throught decades of its existance (i.e. the lack for integer numbers).

### The Type System is a Suggestion

TypeScript tries to make it possible to incrementally add itself to any JavaScript codebase. This means that the amount of confidence and trust you have in your codebase is dependent on having the correct combination of configuration and code. I am a strong supporter of compilers similar to Rust and Haskell that might be stricter than average but when they successfully compile your software you have a high confidence that large categories of bugs have been avoided.

### Tooling

prettier/eslint-stylistic, eslint, tsc, esbuild/webpack+babel, nx, pnpm/yarn/etc, jest, and others. Compare this to cargo. No need to elaborate further.

Sidenote: Tooling in TypeScript is beginner focused and it does something I call "devenv bulling" where a lot of tools are very opinionated and try to force you into a single way of doing things. Prettier is a great example of this, followed by recommended eslint/tsconfig rules, and others.

## Limitations of Python

### Dynamic Typing

In my language I want to have the features and guarantees that static typing provides which Python lacks. Even if Python has introduced type hints, they have limited capabilities.
