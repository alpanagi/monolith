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
        if (state.input[state.currentIdx + 1] === "=") {
            state.tokens.push({
                line: state.currentLine,
                column: state.currentColumn,
                kind: "double_equals",
            })

            state.currentIdx += 2
            state.currentColumn += 2
        } else {
            state.tokens.push({
                line: state.currentLine,
                column: state.currentColumn,
                kind: "equals_sign",
            })

            state.currentIdx += 1
            state.currentColumn += 1
        }
    }

    if (state.input[state.currentIdx] === ",") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "comma",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }

    if (state.input[state.currentIdx] === "%") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "percent_sign",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }

    if (state.input[state.currentIdx] === ":") {
        state.tokens.push({
            line: state.currentLine,
            column: state.currentColumn,
            kind: "colon",
        })

        state.currentIdx += 1
        state.currentColumn += 1
    }

    if (state.input[state.currentIdx] === "+") {
        if (state.input[state.currentIdx + 1] === "=") {
            state.tokens.push({
                line: state.currentLine,
                column: state.currentColumn,
                kind: "plus_equals",
            })

            state.currentIdx += 2
            state.currentColumn += 2
        } else {
            state.tokens.push({
                line: state.currentLine,
                column: state.currentColumn,
                kind: "plus_sign",
            })

            state.currentIdx += 1
            state.currentColumn += 1
        }
    }
}
