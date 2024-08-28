import { GeneratorState } from "./types"
import { Node } from "../parsers/types"

export function callExpression(state: GeneratorState, node: Node) {
    if (node.kind === "call_expression") {
        const str = node.value.parameter
        state.output += `  call void @print(ptr @.str.${str.arrayIdx}, i64 ${str.length})\n`
    }
}
