import { TokenizerState } from "./types"

export function comments(state: TokenizerState) {
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
