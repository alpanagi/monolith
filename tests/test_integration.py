import textwrap

from compiler import compile


def test_multiple_prints_same_string():
    input = """
        print("HERE\\n")
        print("HERE\\n")
    """
    input = textwrap.dedent(input).strip()
    output = """
        @.str0 = constant [6 x i8] c"HERE\\0A\\00"
        define void @main() {
            call void @print(i8* @.str0)
            call void @print(i8* @.str0)
            ret void
        }
        define void @print(i8* %str) {
            call void @printf(i8* %str)
            ret void
        }
        declare void @printf(i8* %str)
    """
    output = textwrap.dedent(output).strip()

    assert compile(input) == output
