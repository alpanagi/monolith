import { Token } from "./types"

interface State {
    currentLine: number
    currentColumn: number
    currentIdx: number
    input: string
    tokens: Token[]
    strings: string
}

export function tokenize(input: string) {
    const state: State = {
        input,
        currentLine: 0,
        currentColumn: 0,
        currentIdx: 0,
        tokens: [],
        strings: "",
    }

    while (state.currentIdx < state.input.length) {
        const currentIdx = state.currentIdx

        comments(state)
        string(state)
        whitespace(state)
        symbols(state)
        identifier(state)

        if (currentIdx === state.currentIdx) {
            throw new Error(
                `Unknown character [${state.input[state.currentIdx]}] at ${state.currentLine + 1}:${state.currentColumn + 1}`,
            )
        }
    }

    return state
}

function comments(state: State) {
    if (state.input[state.currentIdx] === "#") {
        while (state.input[state.currentIdx] !== "\n") {
            state.currentIdx += 1

            if (state.currentIdx === state.input.length) {
                return
            }
        }

        state.currentIdx += 1
        state.currentLine += 1
        state.currentColumn = 0
    }
}

function string(state: State) {
    if (state.input[state.currentIdx] === '"') {
        const startLine = state.currentLine
        const startColumn = state.currentColumn

        state.currentIdx += 1
        const startIdx = state.currentIdx

        while (state.input[state.currentIdx] !== '"') {
            state.currentIdx += 1

            if (state.currentIdx === state.input.length) {
                throw new Error(
                    `Unterminated string at ${state.currentLine + 1}:${state.currentColumn + 1}`,
                )
            }
        }

        const length = state.currentIdx - startIdx
        state.tokens.push({
            kind: "string",
            line: startLine,
            column: startColumn,
            value: {
                memoryIdx: state.strings.length,
                length,
            },
        })
        state.strings += state.input.slice(startIdx, startIdx + length)

        state.currentIdx += 1
        state.currentColumn += length + 2
    }
}

function whitespace(state: State) {
    if (
        state.input[state.currentIdx] === " " ||
        state.input[state.currentIdx] === "\t"
    ) {
        state.currentIdx += 1
        state.currentColumn += 1
    }
}

function symbols(state: State) {
    if (state.input[state.currentIdx] === "\n") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "new_line",
        })

        state.currentIdx += 1
        state.currentColumn = 0
        state.currentLine += 1
    }

    if (state.input[state.currentIdx] === "(") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "left_parenthesis",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }

    if (state.input[state.currentIdx] === ")") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "right_parenthesis",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }

    if (state.input[state.currentIdx] === "=") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "equals",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }
}

function identifier(state: State) {
    if (/[_a-zA-Z$]/.test(state.input[state.currentIdx] ?? "")) {
        const startIdx = state.currentIdx
        const startColumn = state.currentColumn

        state.currentIdx += 1
        while (/[_a-zA-Z0-9$]/.test(state.input[state.currentIdx] ?? "")) {
            state.currentIdx += 1

            if (state.currentIdx === state.input.length) {
                break
            }
        }

        state.tokens.push({
            kind: "identifier",
            line: state.currentLine,
            column: startColumn,
            value: {
                name: state.input.slice(startIdx, state.currentIdx),
            },
        })

        state.currentColumn += state.currentIdx - startIdx
    }
}
