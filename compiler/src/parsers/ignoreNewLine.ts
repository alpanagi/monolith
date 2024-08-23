import { ParserState } from "./types"

// Temporarily until I add blocks to the language
export function ignoreNewLine(state: ParserState) {
    if (state.tokens[0]?.kind === "new_line") {
        state.tokens = state.tokens.slice(1)
    }
}
