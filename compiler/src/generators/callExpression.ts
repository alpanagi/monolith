import { GeneratorState } from "./types"
import { Node } from "../parsers/types"

export function callExpression(state: GeneratorState, node: Node) {
    if (node.kind === "call_expression") {
        state.output += `    (i32.const ${node.value.parameter.targetIdx})\n`
        state.output += `    (i32.const ${node.value.parameter.length})\n`
        state.output += `    (call $print)\n`
    }
}
