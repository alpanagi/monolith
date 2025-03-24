import { Token } from "./tokenize.js";

interface StringLiteral {
    type: "string_literal";
    value: string;
}

export type Node =
    | { type: "program"; statements: Node[] }
    | { type: "function_call"; name: string; arguments: StringLiteral[] }
    | StringLiteral;

interface ASTReturnType {
    tokens: Token[];
    node: Node;
}

export function generateAst(tokens: Token[]): Node {
    const statements: Node[] = [];
    while (tokens.length > 0) {
        const result = statementAst(tokens);
        statements.push(result.node);
        tokens = result.tokens;
    }
    return { type: "program", statements };
}

function statementAst(tokens: Token[]): ASTReturnType {
    if (tokens[0]?.type == "identifier") {
        let result = functionCallAst(tokens);
        if (result != null) {
            return result;
        }
    }

    throw new Error("Invalid statement");
}

function functionCallAst(tokens: Token[]): ASTReturnType | undefined {
    if (
        tokens[0]?.type != "identifier" &&
        tokens[1]?.type != "left_parenthesis" &&
        tokens[2]?.type != "string" &&
        tokens[3]?.type != "right_parenthesis"
    ) {
        return;
    }

    return {
        tokens: tokens.slice(4),
        node: {
            type: "function_call",
            name: tokens[0]!.value!,
            arguments: [
                { type: "string_literal", value: tokens[2]?.value ?? "" },
            ],
        },
    };
}
