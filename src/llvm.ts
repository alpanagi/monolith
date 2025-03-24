import { Node } from "./ast.js";

interface GeneratorState {
    ast: Node;
    strings: string[];
    ir: string[];
}

export function generateIr(ast: Node) {
    let state: GeneratorState = {
        ast,
        strings: [],
        ir: [],
    };

    state = generateLlvmIr(state);
    const ir = [
        ...state.strings.map(
            (x, idx) =>
                `@.str${idx} = private constant [${x.length + 1} x i8] c"${x}\\00"`,
        ),
        "define void @main() {",
        ...state.ir.map((x) => `    ${x}`),
        "    ret void",
        "}",
        "declare void @printf(i8*)",
    ];
    return ir.join("\n");
}

function generateLlvmIr(prevState: GeneratorState): GeneratorState {
    let state = { ...prevState };
    if (state.ast.type === "program") {
        state.ast.statements.forEach((it: Node) => {
            const newState = generateLlvmIr({
                ...state,
                ast: it,
            });
            state.strings = [
                ...new Set([...state.strings, ...newState.strings]),
            ];
            state.ir = [...state.ir, ...newState.ir];
        });
    }

    if (state.ast.type === "function_call") {
        state.ast.arguments.forEach((it: Node) => {
            const newState = generateLlvmIr({
                ...state,
                ast: it,
            });
            state.strings = [
                ...new Set([...state.strings, ...newState.strings]),
            ];
            state.ir = [...state.ir, ...newState.ir];
        });
        state.ir = [...state.ir, `call void @${state.ast.name}(i8* @.str0)`];
    }

    if (state.ast.type === "string_literal") {
        state.strings = [...new Set([...state.strings, state.ast.value])];
    }

    return state;
}
