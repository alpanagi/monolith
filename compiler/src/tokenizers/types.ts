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

export interface TokenizerState {
    currentLine: number
    currentColumn: number
    currentIdx: number
    input: string
    tokens: Token[]
    strings: string
}
