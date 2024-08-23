import { TokenizerState } from "./types"

export function whitespace(state: TokenizerState) {
    if (
        state.input[state.currentIdx] === " " ||
        state.input[state.currentIdx] === "\t"
    ) {
        state.currentIdx += 1
        state.currentColumn += 1
    }
}
