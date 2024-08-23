import { GeneratorState } from "./types"
import { Node } from "../parsers/types"

export function variableDeclaration(state: GeneratorState, node: Node) {
    if (
        node.kind === "variable_assignment" &&
        node.value.kind === "string_pointer"
    ) {
        state.output += `    (i32.store (i32.const ${node.value.memoryIdx}) (i32.const ${node.value.targetIdx}))\n`
        state.output += `    (i32.store (i32.const ${node.value.memoryIdx + 4}) (i32.const ${node.value.length}))\n`
    }
}
