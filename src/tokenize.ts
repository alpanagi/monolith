type TokenType =
    | "identifier"
    | "string"
    | "left_parenthesis"
    | "right_parenthesis";

export type Token = {
    type: TokenType;
    value?: string;
};

interface TokenizerState {
    text: string;
    tokens: Token[];
}

export function tokenize(text: string) {
    let state: TokenizerState = { text, tokens: [] };
    while (state.text.length > 0) {
        state = [
            identiferTokenizer,
            symbolTokenizer,
            stringTokenizer,
            whitespaceTokenizer,
        ].reduce((acc, x) => x(acc), state);
    }
    return state.tokens;
}

function identiferTokenizer(prevState: TokenizerState): TokenizerState {
    const regex = /^[a-zA-Z][a-zA-Z0-9]+/;
    const result = prevState.text.match(regex);
    if (result !== null) {
        return {
            text: prevState.text.slice(result[0].length),
            tokens: [
                ...prevState.tokens,
                { type: "identifier", value: result[0] },
            ],
        };
    }

    return prevState;
}

function symbolTokenizer(prevState: TokenizerState): TokenizerState {
    const tokenMap: Record<string, TokenType> = {
        "(": "left_parenthesis",
        ")": "right_parenthesis",
    };

    for (const key of Object.keys(tokenMap)) {
        if (prevState.text[0] === key) {
            return {
                text: prevState.text.slice(1),
                tokens: [...prevState.tokens, { type: tokenMap[key]! }],
            };
        }
    }

    return prevState;
}

function stringTokenizer(prevState: TokenizerState): TokenizerState {
    const regex = /^".*"/;
    const result = prevState.text.match(regex);
    if (result !== null) {
        return {
            text: prevState.text.slice(result[0].length),
            tokens: [
                ...prevState.tokens,
                {
                    type: "string",
                    value: result[0].slice(1, result[0].length - 1),
                },
            ],
        };
    }

    return prevState;
}

function whitespaceTokenizer(prevState: TokenizerState): TokenizerState {
    if (prevState.text[0] === "\n") {
        return {
            ...prevState,
            text: prevState.text.slice(1),
        };
    }

    return prevState;
}
