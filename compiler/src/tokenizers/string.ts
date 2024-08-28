import { TokenizerState } from "./types"

export function string(state: TokenizerState) {
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
                arrayIdx: state.strings.length,
                length,
            },
        })
        state.strings.push(state.input.slice(startIdx, startIdx + length))

        state.currentIdx += 1
        state.currentColumn += length + 2
    }
}
