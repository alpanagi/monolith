import { ParserState, Variable } from "./types"

export function variableDeclaration(state: ParserState) {
    if (
        state.tokens[0]?.kind === "let" &&
        state.tokens[1]?.kind === "identifier" &&
        state.tokens[2]?.kind === "equals_sign" &&
        state.tokens[3]?.kind === "string"
    ) {
        const variable: Variable = {
            kind: "variable",
            name: state.tokens[1].value.name,
            value: {
                kind: "string_pointer",
                value: {
                    stringArrayIdx: state.tokens[3]?.value.arrayIdx,
                    length: state.tokens[3]?.value.length,
                },
            },
        }

        state.nodes.push({
            kind: "variable_assignment",
            variable,
        })
        state.variables.push(variable)

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(4)
    }

    if (
        state.tokens[0]?.kind === "let" &&
        state.tokens[1]?.kind === "identifier" &&
        state.tokens[2]?.kind === "equals_sign" &&
        state.tokens[3]?.kind === "integer"
    ) {
        const variable: Variable = {
            kind: "variable",
            name: state.tokens[1].value.name,
            value: {
                kind: "integer_constant",
                value: state.tokens[3]?.value,
            },
        }

        state.nodes.push({
            kind: "variable_assignment",
            variable,
        })
        state.variables.push(variable)

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(4)
    }
}
