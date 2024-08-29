import { TokenizerState } from "./types"

export function keywords(state: TokenizerState) {
    if (state.input.slice(state.currentIdx)?.startsWith("from")) {
        state.tokens.push({
            kind: "from",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 4
        state.currentIdx += 4
    }

    if (state.input.slice(state.currentIdx)?.startsWith("import")) {
        state.tokens.push({
            kind: "import",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 6
        state.currentIdx += 6
    }

    if (state.input.slice(state.currentIdx)?.startsWith("for")) {
        state.tokens.push({
            kind: "for",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 3
        state.currentIdx += 3
    }

    if (state.input.slice(state.currentIdx)?.startsWith("in")) {
        state.tokens.push({
            kind: "in",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 2
        state.currentIdx += 2
    }

    if (state.input.slice(state.currentIdx)?.startsWith("if")) {
        state.tokens.push({
            kind: "if",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 2
        state.currentIdx += 2
    }

    if (state.input.slice(state.currentIdx)?.startsWith("or")) {
        state.tokens.push({
            kind: "or",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 2
        state.currentIdx += 2
    }

    if (state.input.slice(state.currentIdx)?.startsWith("let")) {
        state.tokens.push({
            kind: "let",
            line: state.currentLine,
            column: state.currentColumn,
        })

        state.currentColumn += 3
        state.currentIdx += 3
    }
}
