import fs from "fs";
import { tokenize } from "./tokenize.js";
import { generateAst } from "./ast.js";

if (process.argv.length !== 3) {
    console.log("Usage: monolith <FILENAME>");
    process.exit(-1);
}

const filepath: string = process.argv[2] ?? "";
const text = fs.readFileSync(filepath, "utf-8");
const tokens = tokenize(text);
const ast = generateAst(tokens);
console.log(JSON.stringify(ast, null, 2));
