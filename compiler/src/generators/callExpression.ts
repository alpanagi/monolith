import { GeneratorState } from "./types"
import { Node } from "../parsers/types"

export function callExpression(state: GeneratorState, node: Node) {
    if (
        node.kind === "call_expression" &&
        node.parameter.kind === "string_constant"
    ) {
        const str = node.parameter
        state.output += `  call void @print(ptr @.str.${str.arrayIdx}, i64 ${str.length})\n`
    }

    if (node.kind === "call_expression" && node.parameter.kind === "variable") {
        const variable = node.parameter
        state.output += `  %${state.currentRegisterIdx} = load ptr, ptr %${variable.name}\n`
        state.output += `  call void @print(ptr %${state.currentRegisterIdx}, i64 ${variable.value.value.length})\n`
        state.currentRegisterIdx += 1
    }
}
