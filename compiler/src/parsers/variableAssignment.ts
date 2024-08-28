import { ParserState, Variable } from "./types"

export function variableAssignment(state: ParserState) {
    if (
        state.tokens[0]?.kind === "identifier" &&
        state.tokens[1]?.kind === "equals" &&
        state.tokens[2]?.kind === "string"
    ) {
        const variable: Variable = {
            kind: "string_pointer",
            name: state.tokens[0].value.name,
            arrayIdx: state.tokens[2]?.value.arrayIdx,
            length: state.tokens[2]?.value.length,
        }

        state.nodes.push({
            kind: "variable_assignment",
            value: variable,
        })
        state.variables.push(variable)

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(3)
    }
}
