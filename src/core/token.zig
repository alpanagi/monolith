pub const Token = struct {
    kind: TokenKind,
    location: Location,
};

pub const TokenKind = union(enum) {
    keyword_fn,
    keyword_external,
    keyword_const,
    keyword_struct,
    keyword_noop,
    keyword_return,
    keyword_true,
    keyword_false,
    underscore,
    left_parenthesis,
    right_parenthesis,
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
