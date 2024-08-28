import { ParserState } from "./types"

export function functionCall(state: ParserState) {
    if (
        state.tokens[0]?.kind === "identifier" &&
        state.tokens[1]?.kind === "left_parenthesis" &&
        state.tokens[2]?.kind === "string" &&
        state.tokens[3]?.kind === "right_parenthesis"
    ) {
        state.nodes.push({
            kind: "call_expression",
            value: {
                parameter: {
                    kind: "string_pointer",
                    arrayIdx: state.tokens[2]?.value.arrayIdx,
                    length: state.tokens[2]?.value.length,
                },
            },
        })

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(4)
    }

    if (
        state.tokens[0]?.kind === "identifier" &&
        state.tokens[1]?.kind === "left_parenthesis" &&
        state.tokens[2]?.kind === "identifier" &&
        state.tokens[3]?.kind === "right_parenthesis"
    ) {
        const argument = state.tokens[2]
        const variable = state.variables.find(
            x => argument.value.name === x.name,
        )
        if (variable === undefined) {
            const token = state.tokens[2]
            throw new Error(
                `${token.line}:${token.column} Undeclared variable [${token.value.name}]`,
            )
        }

        state.nodes.push({
            kind: "call_expression",
            value: {
                parameter: variable,
            },
        })

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(4)
    }
}
