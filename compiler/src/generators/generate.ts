import { callExpression } from "./callExpression"
import { generatePrelude } from "./prelude"
import { GeneratorState } from "./types"
import { Node } from "../parsers/types"
import { variableDeclaration } from "./variableDeclaration"

const generators = [variableDeclaration, callExpression]

export function generate(nodes: Node[], strings: string) {
    const state: GeneratorState = {
        output: "",
        memoryIdx: strings.length,
    }

    state.output += `(module\n`
    state.output += generatePrelude()
    state.output += `  (import "memory" "heap" (memory 1))\n`
    state.output += `  (data (i32.const 0) "${strings}")\n\n`
    state.output += `  (func $main\n`

    for (const node of nodes) {
        generators.forEach(x => x(state, node))
    }

    state.output += `  )\n`
    state.output += `  (start $main)\n`
    state.output += `)`
    return state.output
}
