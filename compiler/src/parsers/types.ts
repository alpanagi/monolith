import { Token } from "../tokenizers/types"

export interface ParserState {
    nodes: Node[]
    tokens: Token[]
    memoryIdx: number
    variables: Variable[]
}

export type Node =
    | {
          kind: "call_expression"
          parameter: Type
      }
    | {
          kind: "variable_assignment"
          variable: Variable
      }

type Type = StringConstant | Variable

type StringConstant = {
    kind: "string_constant"
    arrayIdx: number
    length: number
}

export type Variable = { kind: "variable"; name: string; value: Value }

type Value = Pointer | Constant

export type Pointer = {
    kind: "string_pointer"
    value: {
        stringArrayIdx: number
        length: number
    }
}

export type Constant = {
    kind: "integer_constant"
    value: string
}
