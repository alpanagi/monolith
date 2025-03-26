from ast_generator import FunctionCall, Program, StringConstant, generate_ast
from token_generator import Keyword, StringLiteral, Symbol


def test_print_statement():
    (string_map, ast) = generate_ast(
        [
            Keyword("print"),
            Symbol("("),
            StringLiteral("HERE", 4),
            Symbol(")"),
        ]
    )

    string_constant = string_map["HERE"]
    assert isinstance(string_constant, StringConstant)
    assert string_constant.string == "HERE"
    assert string_constant.size == 4
    assert string_constant.id == 0

    assert isinstance(ast, Program)

    call = ast.statements[0]
    assert isinstance(call, FunctionCall)
    assert call.name == "print"

    argument = call.arguments[0]
    assert isinstance(argument, StringConstant)
    assert argument.string == "HERE"
    assert argument.size == 4
    assert argument.id == 0
