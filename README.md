# Monolith

Shell scripting replacement for Rust

## Rationale

TBD

## Structure

Each function in `monolith` configures a closure that is later used by the `pipe`
command (see example).

Each closure itself takes a `String` as input and returns `Result<Vec<String>, String>`.

* The input `String` corresponds to a line of `stdin`.
* The `Ok` of the `Result` of the return type corresponds to `stdout`.
* The `Err` of the `Result` of the return type corresponds to `stderr`. The
  difference here is that execution will stop on the first error in the pipeline
  instead of continuing on as shell scripts usually do.

Functions return a Result of a Vector which will be combined ("flattened")
into a single iterator after each function execution. This is the same
functionality as piping the output of executables' outputs in a shell script.

## Examples

```rust
use monolith::pipe;
use monolith::utils::echo;

fn main() {
    let script = pipe(vec![
        echo("Test".to_string())
    ]).unwrap();

    // Printing the resulting output
    for x in script {
        println!("{}", x);
    }
}
```
