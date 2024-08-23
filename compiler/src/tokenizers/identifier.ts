import { TokenizerState } from "./types"

export function identifier(state: TokenizerState) {
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
