from ast_generator import generate_ast
from ir_generator import generate_ir
from token_generator import generate_tokens


def compile(text):
    tokens = generate_tokens(text)
    (string_map, ast) = generate_ast(tokens)
    ir = generate_ir(string_map, ast)
    return ir
