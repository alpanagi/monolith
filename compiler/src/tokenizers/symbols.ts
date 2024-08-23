import { TokenizerState } from "./types"

export function symbols(state: TokenizerState) {
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
