import { generatePrelude } from "./prelude.js";
import { generateEnvironment } from "./environment.js";

export function generate(ast) {
    let output = `(module\n`;
    output += generatePrelude();
    output += generateEnvironment();
    output += `  (data (i32.const 104) "Hello, World!\\n")\n`

    output += `  (func $main\n`;
    for (const node of ast.children) {
        if (node.kind === "variable_declaration" && node.type === 'f32') {
            output += `    (local \$${node.identifier} ${node.type})\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'f64') {
            output += `    (local \$${node.identifier} ${node.type})\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'bool') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'char') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'u8') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'u16') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'u32') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'u64') {
            output += `    (local \$${node.identifier} i64)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'i8') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'i16') {
            output += `    (local \$${node.identifier} i32)\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'i32') {
            output += `    (local \$${node.identifier} ${node.type})\n`
        }

        if (node.kind === "variable_declaration" && node.type === 'i64') {
            output += `    (local \$${node.identifier} i64)\n`
        }
    }

    // output += "i32.const 1\n";
    // output += "i32.const 0\n";
    // output += "i32.const 2\n";
    // output += "i32.const 92\n";
    // output += "call $fd_write\n";
    // output += "drop";
    output += `\n`;
    output += `    (i32.const 14)\n`
    output += `    (i32.store (i32.const 100))\n`;
    output += `    (i32.const 100)\n`
    output += `    call $log)\n`;
    output += "\n  (start $main))\n";
    return output;
}
