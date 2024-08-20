export function parse({ tokens, string }) {
    let ast = {
        root: { kind: 'root', children: [] },
        tokens: tokens,
        string
    };

    while (ast.tokens.length > 0) {
        const currentTokenLength = ast.tokens.length;

        ast = variableDeclaration(ast);
        ast = callExpression(ast);

        if (ast.tokens.length === currentTokenLength) {
            return ast.root;
        }
    }
    return { nodes: ast.root.children, string: ast.string };
}

function variableDeclaration(ast) {
    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'equals'
        && (ast.tokens[2].kind === 'number' | ast.tokens[2].kind === 'string')
        && ast.tokens[3].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[2].kind === 'string' ? 'string' : ast.tokens[2].type,
            value: ast.tokens[2].value
        })
        ast.tokens = ast.tokens.slice(4);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'equals'
        && ast.tokens[2].kind === 'minus'
        && ast.tokens[3].kind === 'number'
        && ast.tokens[4].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[3].type,
            value: '-' + ast.tokens[3].value
        })
        ast.tokens = ast.tokens.slice(5);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'colon'
        && ast.tokens[2].kind === 'type'
        && ast.tokens[3].kind === 'equals'
        && (ast.tokens[4].kind === 'number' | ast.tokens[4].kind === 'string')
        && ast.tokens[5].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[2].value,
            value: ast.tokens[4].value
        })
        ast.tokens = ast.tokens.slice(6);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'colon'
        && ast.tokens[2].kind === 'type'
        && ast.tokens[3].kind === 'equals'
        && ast.tokens[4].kind === 'minus'
        && ast.tokens[5].kind === 'number'
        && ast.tokens[6].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[2].value,
            value: '-' + ast.tokens[5].value
        })
        ast.tokens = ast.tokens.slice(7);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'equals'
        && ast.tokens[2].kind === 'bool'
        && ast.tokens[3].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: 'bool',
            value: ast.tokens[2].value
        })
        ast.tokens = ast.tokens.slice(4);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'colon'
        && ast.tokens[2].kind === 'type'
        && ast.tokens[3].kind === 'equals'
        && ast.tokens[4].kind === 'bool'
        && ast.tokens[5].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[2].value,
            value: ast.tokens[4].value
        })
        ast.tokens = ast.tokens.slice(6);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'equals'
        && ast.tokens[2].kind === 'character'
        && ast.tokens[3].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: 'char',
            value: ast.tokens[2].value
        })
        ast.tokens = ast.tokens.slice(4);
    }

    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'colon'
        && ast.tokens[2].kind === 'type'
        && ast.tokens[3].kind === 'equals'
        && ast.tokens[4].kind === 'character'
        && ast.tokens[5].kind === 'newline') {
        ast.root.children.push({
            kind: 'variable_declaration',
            identifier: ast.tokens[0].value,
            type: ast.tokens[2].value,
            value: ast.tokens[4].value
        })
        ast.tokens = ast.tokens.slice(6);
    }

    return ast;
}

function callExpression(ast) {
    if (ast.tokens[0].kind === 'identifier'
        && ast.tokens[1].kind === 'left_parenthesis'
        && (ast.tokens[2].kind === 'number' || ast.tokens[2].kind === 'string')
        && ast.tokens[3].kind === 'right_parenthesis'
        && (ast.tokens[4].kind === 'newline' || ast.tokens[4].kind === 'eof')) {
        ast.root.children.push({
            kind: 'call_expression',
            identifier: 'print',
            idx: ast.tokens[2].idx,
            length: ast.tokens[2].length
        })
        ast.tokens = ast.tokens.slice(5);
    }

    return ast;
}
