pub const Token = struct {
    kind: TokenKind,
    location: Location,
};

pub const TokenKind = union(enum) {
    keyword_fn,
    keyword_external,
    keyword_const,
    keyword_var,
    keyword_struct,
    keyword_noop,
    keyword_return,
    keyword_true,
    keyword_false,
    keyword_undefined,
    underscore,
    left_parenthesis,
    right_parenthesis,
    left_bracket,
    right_bracket,
    colon,
    double_colon,
    comma,
    dot,
    equals,
    identifier: []const u8,
    integer_literal: NumberLiteral,
    float_literal: NumberLiteral,
    string_literal: []const u8,
    indent: usize,
    eof,
};

pub const NumberLiteral = struct {
    text: []const u8,
    suffix: ?[]const u8,
};

pub const Location = struct {
    row: usize,
    column: usize,
};
