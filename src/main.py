import sys

from compiler import compile

if len(sys.argv) != 2:
    print("Usage: monolith <FILENAME>")
text = open(sys.argv[1], "r").read()
print(compile(text))
