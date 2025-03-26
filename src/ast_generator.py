from token_generator import Keyword, StringLiteral, Symbol


class AstGeneratorState:
    def __init__(self, tokens, node, string_map):
        self.tokens = tokens
        self.node = node
        self.string_map = string_map


class Program:
    def __init__(self, statements):
        self.statements = statements


class FunctionCall:
    def __init__(self, name, arguments):
        self.name = name
        self.arguments = arguments


class StringConstant:
    def __init__(self, string, size, id):
        self.string = string
        self.size = size
        self.id = id


def generate_ast(tokens):
    state = AstGeneratorState(tokens, None, {})
    statements = []

    generators = [
        function_call_generator,
    ]
    while len(state.tokens) > 0:
        for generator in generators:
            state = generator(state)
            if state.node != None:
                statements += [state.node]
            if len(state.tokens) == 0:
                break

    return (state.string_map, Program(statements))


def function_call_generator(prev_state):
    tokens = prev_state.tokens
    string_map = prev_state.string_map

    if (
        len(prev_state.tokens) >= 4
        and isinstance(tokens[0], Keyword)
        and isinstance(tokens[1], Symbol)
        and tokens[1].symbol == "("
        and isinstance(tokens[2], StringLiteral)
        and isinstance(tokens[3], Symbol)
        and tokens[3].symbol == ")"
    ):
        if tokens[2].string not in string_map:
            string_constant = StringConstant(
                tokens[2].string, tokens[2].size, len(string_map)
            )
            string_map[tokens[2].string] = string_constant
        else:
            string_constant = string_map[tokens[2].string]

        return AstGeneratorState(
            prev_state.tokens[4:],
            FunctionCall(
                prev_state.tokens[0].keyword,
                [string_constant],
            ),
            string_map,
        )

    return prev_state
