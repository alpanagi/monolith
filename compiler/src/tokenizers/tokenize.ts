import { TokenizerState } from "./types"
import { comments } from "./comments"
import { identifier } from "./identifier"
import { string } from "./string"
import { symbols } from "./symbols"
import { whitespace } from "./whitespace"

const tokenizers = [comments, string, whitespace, symbols, identifier]

export function tokenize(input: string) {
    const state: TokenizerState = {
        input,
        currentLine: 0,
        currentColumn: 0,
        currentIdx: 0,
        tokens: [],
        strings: [],
    }

    while (state.currentIdx < state.input.length) {
        const currentIdx = state.currentIdx
        tokenizers.forEach(x => x(state))
        if (currentIdx === state.currentIdx) {
            throw new Error(
                `${state.currentLine + 1}:${state.currentColumn + 1}: Unknown character [${state.input[state.currentIdx]}]`,
            )
        }
    }

    return state
}
