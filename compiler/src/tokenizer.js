const tokenizers = [
    comment, character, string, boolean, typeKeywords, logicalKeywords, identifier,
    whitespace, number, binary_operators, symbol
]

export function tokenize(text) {
    let state = {
        text,
        position: 0,
        tokens: []
    }

    while (state.position < text.length) {
        const currentPosition = state.position;
        for (const tokenizer of tokenizers) {
            state = tokenizer(state);

            if (state.position !== currentPosition) {
                break;
            }
        }

        if (state.position === currentPosition) {
            throw new Error("Invalid character");
        }
    }

    state.tokens.push({
        kind: 'eof'
    });
    return state.tokens;
}

function comment(state) {
    if ("#" !== state.text[state.position]) {
        return state;
    }
    while ("\n" !== state.text[state.position]) {
        state.position += 1;
    }

    return state;
}

function identifier(state) {
    if (/^[_A-Za-z]$/.test(state.text[state.position]) == false) {
        return state;
    }

    const startPosition = state.position;
    while (/^[_A-Za-z0-9]$/.test(state.text[state.position])) {
        state.position += 1;
    }
    state.tokens.push({
        kind: 'identifier',
        value: state.text.slice(startPosition, state.position)
    });

    return state;
}

function whitespace(state) {
    if (" " === state.text[state.position]
        || "\t" === state.text[state.position]) {
        state.position += 1;
        return state;
    }

    if ("\n" === state.text[state.position]) {
        state.position += 1;

        state.tokens.push({
            kind: 'newline'
        });
    }

    const currentPosition = state.position;
    while (" " === state.text[state.position]) {
        state.position += 1;
    }
    if (currentPosition != state.position
        && "\n" !== state.text[state.position]) {
        state.tokens.push({
            kind: 'space_indent',
            value: state.position - currentPosition
        });

        return state;
    }

    while ("\t" === state.text[state.position]) {
        state.position += 1;
    }
    if (currentPosition != state.position
        && "\n" !== state.text[state.position]) {
        state.tokens.push({
            kind: 'tab_indent',
            value: state.position - currentPosition
        });
    }

    return state;
}

function number(state) {
    if (/^[0-9]$/.test(state.text[state.position]) === false) {
        return state;
    }

    let isFloat = false;
    let isComplex = false;

    const startPosition = state.position;
    while (/^[0-9]$/.test(state.text[state.position])) {
        state.position += 1;
    }
    if (state.text[state.position] === "."
        && /^[0-9]$/.test(state.text[state.position + 1])) {
        isFloat = true;
        state.position += 1;

        while (/^[0-9]$/.test(state.text[state.position])) {
            state.position += 1;
        }
    }

    if (state.text[state.position] === "i") {
        isComplex = true;
        state.position += 1;
    }

    state.tokens.push({
        kind: 'number',
        type: isComplex ? 'complex64' : isFloat ? 'f32' : 'i32',
        value: state.text.slice(startPosition, state.position)
    });

    return state;
}

function binary_operators(state) {
    if (state.text[state.position] === "="
        && state.text[state.position + 1] === "=") {
        state.tokens.push({
            kind: 'double_equals'
        });
        state.position += 2;
    }

    return state;
}

function string(state) {
    if ("\"" !== state.text[state.position]) {
        return state;
    }

    state.position += 1;
    const startPosition = state.position;
    while (state.text[state.position] !== "\"") {
        state.position += 1;
    }

    state.tokens.push({
        kind: 'string',
        value: state.text.slice(startPosition, state.position)
    });
    state.position += 1;

    return state;
}

function boolean(state) {
    if (state.text.slice(state.position, state.position + 4) === "true") {
        state.tokens.push({
            kind: 'bool',
            value: 'true'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 5) === "false") {
        state.tokens.push({
            kind: 'bool',
            value: 'false'
        })
        state.position += 5;
    }

    return state;
}

function typeKeywords(state) {
    if (state.text.slice(state.position, state.position + 3) === "int") {
        state.tokens.push({
            kind: 'type',
            value: 'i32'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 4) === "uint") {
        state.tokens.push({
            kind: 'type',
            value: 'u32'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 4) === "long") {
        state.tokens.push({
            kind: 'type',
            value: 'i64'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 5) === "ulong") {
        state.tokens.push({
            kind: 'type',
            value: 'u64'
        })
        state.position += 5;
    }

    if (state.text.slice(state.position, state.position + 4) === "bool") {
        state.tokens.push({
            kind: 'type',
            value: 'bool'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 5) === "float") {
        state.tokens.push({
            kind: 'type',
            value: 'f32'
        })
        state.position += 5;
    }

    if (state.text.slice(state.position, state.position + 4) === "char") {
        state.tokens.push({
            kind: 'type',
            value: 'char'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 4) === "byte") {
        state.tokens.push({
            kind: 'type',
            value: 'u8'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 2) === "i8") {
        state.tokens.push({
            kind: 'type',
            value: 'i8'
        })
        state.position += 2;
    }

    if (state.text.slice(state.position, state.position + 3) === "i16") {
        state.tokens.push({
            kind: 'type',
            value: 'i16'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 3) === "i32") {
        state.tokens.push({
            kind: 'type',
            value: 'i32'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 3) === "i64") {
        state.tokens.push({
            kind: 'type',
            value: 'i64'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 4) === "i128") {
        state.tokens.push({
            kind: 'type',
            value: 'i128'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 2) === "u8") {
        state.tokens.push({
            kind: 'type',
            value: 'u8'
        })
        state.position += 2;
    }

    if (state.text.slice(state.position, state.position + 3) === "u16") {
        state.tokens.push({
            kind: 'type',
            value: 'u16'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 3) === "u32") {
        state.tokens.push({
            kind: 'type',
            value: 'u32'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 3) === "u64") {
        state.tokens.push({
            kind: 'type',
            value: 'u64'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 4) === "u128") {
        state.tokens.push({
            kind: 'type',
            value: 'u128'
        })
        state.position += 4;
    }

    if (state.text.slice(state.position, state.position + 3) === "f32") {
        state.tokens.push({
            kind: 'type',
            value: 'f32'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 3) === "f64") {
        state.tokens.push({
            kind: 'type',
            value: 'f64'
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 9) === "complex64") {
        state.tokens.push({
            kind: 'type',
            value: 'complex64'
        })
        state.position += 9;
    }

    if (state.text.slice(state.position, state.position + 10) === "complex128") {
        state.tokens.push({
            kind: 'type',
            value: 'complex128'
        })
        state.position += 10;
    }

    if (state.text.slice(state.position, state.position + 7) === "complex") {
        state.tokens.push({
            kind: 'type',
            value: 'complex64'
        })
        state.position += 7;
    }

    if (state.text.slice(state.position, state.position + 6) === "string") {
        state.tokens.push({
            kind: 'type',
            value: 'string'
        })
        state.position += 6;
    }

    return state;
}

function logicalKeywords(state) {
    if (state.text.slice(state.position, state.position + 3) === "and") {
        state.tokens.push({
            kind: 'logical_and',
        })
        state.position += 3;
    }

    if (state.text.slice(state.position, state.position + 2) === "or") {
        state.tokens.push({
            kind: 'logical_or',
        })
        state.position += 2;
    }

    return state;
}

function character(state) {
    if ("'" === state.text[state.position]
        && "'" !== state.text[state.position + 1]
        && "'" === state.text[state.position + 2]
    ) {
        state.tokens.push({
            kind: 'character',
            value: state.text[state.position + 1]
        });
        state.position += 3;
    }

    return state;
}

function symbol(state) {
    if ("=" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'equals',
        });
    } else if (":" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'colon',
        });
    } else if ("." === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'dot',
        });
    } else if ("-" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'minus',
        });
    } else if ("+" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'plus',
        });
    } else if ("(" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'left_parenthesis',
        });
    } else if (")" === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'right_parenthesis',
        });
    } else if ("," === state.text[state.position]) {
        state.position += 1;
        state.tokens.push({
            kind: 'comma',
        });
    }

    return state;
}
