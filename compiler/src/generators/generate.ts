import { callExpression } from "./callExpression"
import { generatePrelude } from "./prelude"
import { GeneratorState } from "./types"
import { Node } from "../parsers/types"
import { variableDeclaration } from "./variableDeclaration"

const generators = [callExpression, variableDeclaration]

export function generate(nodes: Node[], strings: string[]) {
    const state: GeneratorState = {
        output: "",
        memoryIdx: strings.length,
        currentRegisterIdx: 1,
    }

    state.output += generatePrelude()
    strings.forEach(
        (string, idx) =>
            (state.output += `@.str.${idx} = internal constant [${string.length} x i8] c"${string}"\n`),
    )

    state.output += "\n"
    state.output += `define void @main() {\n`

    for (const node of nodes) {
        generators.forEach(x => x(state, node))
    }

    state.output += `  ret void\n}`
    return state.output
}
