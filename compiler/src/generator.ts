import { generatePrelude } from "./prelude.js"
import { Node } from "./types"

interface State {
    output: string
    memoryIdx: number
}

export function generate(nodes: Node[], strings: string) {
    const state: State = {
        output: "",
        memoryIdx: strings.length,
    }

    state.output += `(module\n`
    state.output += generatePrelude()
    state.output += `  (import "memory" "heap" (memory 1))\n`
    state.output += `  (data (i32.const 0) "${strings}")\n\n`
    state.output += `  (func $main\n`

    for (const node of nodes) {
        variableDeclaration(state, node)
        callExpression(state, node)
    }

    state.output += `  )\n`
    state.output += `  (start $main)\n`
    state.output += `)`
    return state.output
}

function variableDeclaration(state: State, node: Node) {
    if (node.kind === "variable_assignment") {
        state.output += `    (i32.store (i32.const ${node.value.memoryIdx}) (i32.const ${node.value.targetIdx}))\n`
        state.output += `    (i32.store (i32.const ${node.value.memoryIdx + 4}) (i32.const ${node.value.length}))\n`
    }
}

function callExpression(state: State, node: Node) {
    if (node.kind === "call_expression") {
        state.output += `    (i32.store (i32.const ${node.value.parameter.memoryIdx}) (i32.const ${node.value.parameter.targetIdx}))\n`
        state.output += `    (i32.store (i32.const ${node.value.parameter.memoryIdx + 4}) (i32.const ${node.value.parameter.length}))\n`
        state.output += `    (i32.const ${node.value.parameter.memoryIdx})\n`
        state.output += `    (call $print)\n`
    }
}
