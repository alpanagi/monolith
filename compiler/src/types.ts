interface Location {
    line: number
    column: number
}

export type Token = Location &
    (
        | {
              kind: "string"
              value: {
                  memoryIdx: number
                  length: number
              }
          }
        | { kind: "left_parenthesis" }
        | { kind: "right_parenthesis" }
        | { kind: "new_line" }
        | { kind: "identifier"; value: { name: string } }
        | { kind: "equals" }
    )

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

type Pointer = {
    kind: "string"
    memoryIdx: number
    targetIdx: number
    length: number
}

type Type = Pointer
