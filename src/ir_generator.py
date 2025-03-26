import prelude
from ast_generator import FunctionCall, Program


class IrGeneratorState:
    def __init__(self, node, irs):
        self.node = node
        self.irs = irs


def generate_ir(string_map, ast):
    state = IrGeneratorState(ast, [])
    state = generate_ir_(state)
    irs = []
    for key, string_constant in string_map.items():
        irs += [
            "@.str"
            + str(string_constant.id)
            + " = constant ["
            + str(string_constant.size + 1)
            + ' x i8] c"'
            + key
            + '\\00"'
        ]

    irs += (
        ["define void @main() {"]
        + ["    " + ir for ir in state.irs]
        + ["    ret void"]
        + ["}"]
    )
    irs += [prelude.ir]

    return "\n".join(irs)


def generate_ir_(prev_state):
    state = program_generator(prev_state)
    state = function_call_generator(state)
    return state


def program_generator(prev_state):
    if isinstance(prev_state.node, Program):
        states = [
            generate_ir_(IrGeneratorState(statement, prev_state.irs))
            for statement in prev_state.node.statements
        ]
        return IrGeneratorState(
            prev_state.node,
            prev_state.irs + [ir for state in states for ir in state.irs],
        )

    return prev_state


def function_call_generator(prev_state):
    if isinstance(prev_state.node, FunctionCall):
        return IrGeneratorState(
            prev_state.node,
            prev_state.irs
            + [
                "call void @"
                + prev_state.node.name
                + "(i8* @.str"
                + str(prev_state.node.arguments[0].id)
                + ")"
            ],
        )
    return prev_state
