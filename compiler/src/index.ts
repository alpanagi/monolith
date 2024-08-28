import fs from "fs"
import { tokenize } from "./tokenizers/tokenize"
import { parse } from "./parsers/parse"
import { generate } from "./generators/generate"

void main()
function main() {
    const args = process.argv.slice(2)
    if (args.length !== 1) {
        console.log("Error: Expected a single command line argument\n")
        console.log("Usage:")
        console.log("  monolith [file]")
        return
    }

    const filepath = args[0] as string
    const text = fs.readFileSync(filepath, "utf-8").trim()

    const tokenState = tokenize(text)

    const astState = parse(tokenState.tokens, tokenState.strings.length)

    const output = generate(astState.nodes, tokenState.strings)
    console.log(output)
}
