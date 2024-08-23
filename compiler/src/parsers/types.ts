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
          value: {
              parameter: Type
          }
      }
    | {
          kind: "variable_assignment"
          value: Variable
      }

export type Variable = { name: string } & Type

type Pointer =
    | {
          kind: "string_pointer"
          memoryIdx: number
          targetIdx: number
          length: number
      }
    | {
          kind: "string_constant"
          targetIdx: number
          length: number
      }

type Type = Pointer
