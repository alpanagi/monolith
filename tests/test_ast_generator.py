from ast_generator import FunctionCall, Program, StringConstant, generate_ast
from token_generator import Keyword, StringLiteral, Symbol


def test_print_statement():
    ast = generate_ast(
        [
            Keyword("print"),
            Symbol("("),
            StringLiteral("HERE"),
            Symbol(")"),
        ]
    )

    assert isinstance(ast, Program)

    call = ast.statements[0]
    assert isinstance(call, FunctionCall)
    assert call.name == "print"

    argument = call.arguments[0]
    assert isinstance(argument, StringConstant)
    assert argument.string == "HERE"
