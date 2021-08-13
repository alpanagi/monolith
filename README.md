# Monolith

Shell scripting replacement for Rust

## Rational

TBD

## Structure

Each function takes a either an `str` or a `String` (or anything that implements
`Into<String>`) as input and returns `Result<impl Iterator<Item = String>, String>`.

* The input `String` corresponds to a line of `stdin`.
* The `Ok` of the `Result` of the return type corresponds to `stdout`.
* The `Err` of the `Result` of the return type corresponds to `stderr`. The
  difference here is that execution will stop on the first error in the pipeline
  instead of continuing on as shell scripts usually do.

Functions return a Result of an Iterator which will be combined ("flattened")
into a single iterator after each function execution. This is the same
functionality as piping the output of executables' outputs in a shell script.

## Examples

TBD
