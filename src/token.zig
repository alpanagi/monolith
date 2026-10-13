pub const Token = struct {
    kind: TokenKind,
    location: Location,
};

pub const TokenKind = union(enum) {
    keyword_fn,
    keyword_noop,
    left_parenthesis,
    right_parenthesis,
    colon,
    identifier: []const u8,
    indent: usize,
    eof,
};

pub const Location = struct {
    row: usize,
    column: usize,
};
