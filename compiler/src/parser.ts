import { Token, Variable, Node } from "./types"

interface State {
    nodes: Node[]
    tokens: Token[]
    memoryIdx: number
    variables: Variable[]
}

export function parse(tokens: Token[], memoryStartIdx: number) {
    const state: State = {
        tokens,
        nodes: [],
        memoryIdx: memoryStartIdx,
        variables: [],
    }

    while (state.tokens.length > 0) {
        const currentTokensLength = state.tokens.length

        ignoreNewLine(state)
        functionCall(state)
        variableAssignment(state)

        if (currentTokensLength === state.tokens.length) {
            const token = state.tokens[0]
            throw new Error(
                `Invalid token [${token?.kind}] at ${(token?.line ?? NaN) + 1}:${(token?.column ?? NaN) + 1}`,
            )
        }
    }

    return state
}

// Temporarily until I add blocks to the language
function ignoreNewLine(state: State) {
    if (state.tokens[0]?.kind === "new_line") {
        state.tokens = state.tokens.slice(1)
    }
}

function functionCall(state: State) {
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
                    kind: "string",
                    memoryIdx: state.memoryIdx,
                    targetIdx: state.tokens[2]?.value.memoryIdx,
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
                parameter: {
                    kind: "string",
                    memoryIdx: variable.memoryIdx,
                    targetIdx: variable.targetIdx,
                    length: variable.length,
                },
            },
        })

        state.memoryIdx += 8
        state.tokens = state.tokens.slice(4)
    }
}

function variableAssignment(state: State) {
    if (
        state.tokens[0]?.kind === "identifier" &&
        state.tokens[1]?.kind === "equals" &&
        state.tokens[2]?.kind === "string"
    ) {
        const variable: Variable = {
            kind: "string",
            name: state.tokens[0].value.name,
            memoryIdx: state.memoryIdx,
            targetIdx: state.tokens[2]?.value.memoryIdx,
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
