from ast_generator import FunctionCall, StringConstant
from ir_generator import generate_ir

ir1 = """
@.str0 = constant [5 x i8] c"HERE\\00"
define void @main() {
    call void @print(i8* @.str0)
    ret void
}
define void @print(i8* %str) {
    call void @printf(i8* %str)
    ret void
}
declare void @printf(i8* %str)
""".strip()


def test_print_statement():
    string_map = {"HERE": 0}
    ast = FunctionCall("print", [StringConstant("HERE", 0)])
    ir = generate_ir(string_map, ast)
    assert ir == ir1
