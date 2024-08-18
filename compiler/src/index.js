import fs from "fs";
import { tokenize } from './tokenizer.js';
import { parse } from './parser.js';
import { generate } from './generator.js';

const args = process.argv.slice(2);
if (args.length !== 1) {
    console.log("Error: Expected a single command line argument\n");
    console.log("Usage:");
    console.log("  monolith [file]");
}

const filepath = args[0];
const text = fs.readFileSync(filepath, "utf-8").trim();
const processedText = text.split("\n")
    .filter(x => !x.startsWith("#"))
    .filter(x => x.length !== 0)
    .join("\n");

const tokens = tokenize(processedText);
const ast = parse(tokens);
const output = generate(ast);
console.log(output);
