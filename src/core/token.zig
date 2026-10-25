pub const Token = struct {
    kind: TokenKind,
    location: Location,
};

pub const TokenKind = union(enum) {
    keyword_fn,
    keyword_external,
    keyword_const,
    keyword_many,
    keyword_var,
    keyword_struct,
    keyword_trait,
    keyword_impl,
    keyword_for,
    keyword_import,
    keyword_noop,
    keyword_return,
    keyword_while,
    keyword_true,
    keyword_false,
    keyword_undefined,
    keyword_null,
    underscore,
    left_parenthesis,
    right_parenthesis,
    left_bracket,
    right_bracket,
    colon,
    double_colon,
    comma,
    dot,
    dot_dot,
    equals,
    arrow,
    minus,
    asterisk,
    identifier: []const u8,
    integer_literal: NumberLiteral,
    float_literal: NumberLiteral,
    character_literal: []const u8,
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
