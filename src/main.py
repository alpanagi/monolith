import sys

from ast_generator import generate_ast
from ir_generator import generate_ir
from token_generator import generate_tokens

if len(sys.argv) != 2:
    print("Usage: monolith <FILENAME>")

text = open(sys.argv[1], "r").read()
tokens = generate_tokens(text)
(string_map, ast) = generate_ast(tokens)
ir = generate_ir(string_map, ast)
print(ir)
