export const generatePrelude = () =>
    [
        `  ;; Prelude`,
        `  (import "prelude" "print" (func $print (param i32) (param i32)))`,
        `\n`,
    ].join("\n")
