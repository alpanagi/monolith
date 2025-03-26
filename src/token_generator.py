import re


class TokenGeneratorState:
    def __init__(self, text, tokens):
        self.text = text
        self.tokens = tokens


class Keyword:
    def __init__(self, keyword):
        self.keyword = keyword


class Symbol:
    def __init__(self, symbol):
        self.symbol = symbol


class StringLiteral:
    def __init__(self, text, size):
        self.string = text
        self.size = size


def generate_tokens(text):
    state = TokenGeneratorState(text, [])
    tokenizers = [
        tokenize_keyword,
        tokenize_symbol,
        tokenize_string,
        tokenize_whitespace,
        tokenize_comments,
    ]
    while len(state.text) > 0:
        for tokenizer in tokenizers:
            state = tokenizer(state)
            if len(state.text) == 0:
                break

    return state.tokens


def tokenize_keyword(prev_state):
    keyword_pattern = r"^([a-zA-Z][a-zA-Z0-9]*)"
    match = re.match(keyword_pattern, prev_state.text)

    if match:
        name = match.group(1)
        return TokenGeneratorState(
            prev_state.text[len(name) :], prev_state.tokens + [Keyword(name)]
        )

    return prev_state


def tokenize_symbol(prev_state):
    if prev_state.text[0] == "(":
        return TokenGeneratorState(
            prev_state.text[1:], prev_state.tokens + [Symbol("(")]
        )
    if prev_state.text[0] == ")":
        return TokenGeneratorState(
            prev_state.text[1:], prev_state.tokens + [Symbol(")")]
        )
    return prev_state


def tokenize_string(prev_state):
    string_pattern = r"^\"(.*)\""
    match = re.match(string_pattern, prev_state.text)

    if match:
        text = match.group(1)
        new_line_count = text.count("\\n")
        size = len(text) - new_line_count
        escaped_text = text.replace("\\n", "\\0A")
        return TokenGeneratorState(
            prev_state.text[len(text) + 2 :],
            prev_state.tokens + [StringLiteral(escaped_text, size)],
        )

    return prev_state


def tokenize_whitespace(prev_state):
    if prev_state.text[0] == "\n":
        return TokenGeneratorState(prev_state.text[1:], prev_state.tokens)
    if prev_state.text[0] == " ":
        return TokenGeneratorState(prev_state.text[1:], prev_state.tokens)
    return prev_state


def tokenize_comments(prev_state):
    idx = 0
    if prev_state.text[idx] == "#":
        while idx < len(prev_state.text) and prev_state.text[idx] != "\n":
            idx += 1
        return TokenGeneratorState(prev_state.text[idx:], prev_state.tokens)

    return prev_state
