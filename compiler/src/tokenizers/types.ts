interface Location {
    line: number
    column: number
}

export type Token = Location &
    (
        | {
              kind: "string"
              value: {
                  arrayIdx: number
                  length: number
              }
          }
        | { kind: "left_parenthesis" }
        | { kind: "right_parenthesis" }
        | { kind: "new_line" }
        | { kind: "identifier"; value: { name: string } }
        | { kind: "from" }
        | { kind: "import" }
        | { kind: "for" }
        | { kind: "in" }
        | { kind: "if" }
        | { kind: "or" }
        | { kind: "let" }
        | { kind: "comma" }
        | { kind: "colon" }
        | { kind: "double_equals" }
        | { kind: "plus_equals" }
        | { kind: "equals_sign" }
        | { kind: "percent_sign" }
        | { kind: "plus_sign" }
        | { kind: "integer"; value: string }
    )

export interface TokenizerState {
    currentLine: number
    currentColumn: number
    currentIdx: number
    input: string
    tokens: Token[]
    strings: string[]
}
