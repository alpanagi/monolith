(module
    (import "prelude" "print" (func $print (param i32)))
    (import "memory" "heap" (memory 1))

    (data (i32.const 4) "This is a test")

    (func $main
        (i32.store (i32.const 0) (i32.const 14))
        i32.const 0
        call $print)

    (start $main)
)
