import { GeneratorState } from "./types"
import { Node, Pointer } from "../parsers/types"

export function variableDeclaration(state: GeneratorState, node: Node) {
    if (
        node.kind === "variable_assignment" &&
        node.variable.value.kind === "string_pointer"
    ) {
        const variable = node.variable
        const pointer = node.variable.value as Pointer
        state.output += `  %${variable.name} = alloca ptr\n`
        state.output += `  store ptr @.str.${pointer.value.stringArrayIdx}, ptr %${variable.name}\n`
    }

    if (
        node.kind === "variable_assignment" &&
        node.variable.value.kind === "integer_constant"
    ) {
        const variable = node.variable
        state.output += `  %${variable.name} = alloca i64\n`
        state.output += `  store i64 ${variable.value.value}, ptr %${variable.name}\n`
    }
}
