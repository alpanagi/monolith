import { GeneratorState } from "./types"
import { Node } from "../parsers/types"

export function variableDeclaration(state: GeneratorState, node: Node) {
    if (node.kind === "variable_assignment") {
        const variable = node.variable
        state.output += `  %${variable.name} = alloca ptr\n`
        state.output += `  store ptr @.str.${variable.pointer.value.stringArrayIdx}, ptr %${variable.name}\n`
    }
}
