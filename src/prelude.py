ir = """
define void @print(i8* %str) {
    call void @printf(i8* %str)
    ret void
}
declare void @printf(i8* %str)
""".strip()
