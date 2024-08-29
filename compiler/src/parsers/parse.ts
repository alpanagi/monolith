import { Token } from "../tokenizers/types"
import { functionCall } from "./functionCall"
import { ignoreNewLine } from "./ignoreNewLine"
import { ParserState } from "./types"
import { variableDeclaration } from "./variableDeclaration"

const parsers = [ignoreNewLine, variableDeclaration, functionCall]

export function parse(tokens: Token[], memoryStartIdx: number) {
    const state: ParserState = {
        tokens,
        nodes: [],
        memoryIdx: memoryStartIdx,
        variables: [],
    }

    while (state.tokens.length > 0) {
        const currentTokensLength = state.tokens.length
        parsers.forEach(x => x(state))
        if (currentTokensLength === state.tokens.length) {
            const token = state.tokens[0]
            throw new Error(
                `${(token?.line ?? NaN) + 1}:${(token?.column ?? NaN) + 1}: Invalid token [${token?.kind}]`,
            )
        }
    }

    return state
}
