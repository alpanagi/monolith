import { TokenizerState } from "./types"

export function number(state: TokenizerState) {
    if (/[0-9]/.test(state.input[state.currentIdx] ?? "")) {
        const startIdx = state.currentIdx
        const startColumn = state.currentColumn

        state.currentIdx += 1
        state.currentColumn += 1

        while (/[0-9]/.test(state.input[state.currentIdx] ?? "")) {
            state.currentIdx += 1
            state.currentColumn += 1
        }

        state.tokens.push({
            kind: "integer",
            line: state.currentLine,
            column: startColumn,
            value: state.input.slice(startIdx, state.currentIdx),
        })
    }
}
