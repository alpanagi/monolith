from token_generator import Keyword, StringLiteral, Symbol, generate_tokens


def test_print_statement():
    tokens = generate_tokens('print("HERE")')

    assert isinstance(tokens[0], Keyword)
    assert tokens[0].keyword == "print"

    assert isinstance(tokens[1], Symbol)
    assert tokens[1].symbol == "("

    assert isinstance(tokens[2], StringLiteral)
    assert tokens[2].string == "HERE"

    assert isinstance(tokens[3], Symbol)
    assert tokens[3].symbol == ")"
