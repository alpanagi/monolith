pub const Token = struct {
    kind: TokenKind,
    location: Location,
};

pub const TokenKind = union(enum) {
    keyword_fn,
    keyword_noop,
    keyword_return,
    keyword_true,
    keyword_false,
    primitive_type: PrimitiveType,
    left_parenthesis,
    right_parenthesis,
    colon,
    identifier: []const u8,
    integer: NumberLiteral,
    float: NumberLiteral,
    indent: usize,
    eof,
};

pub const NumberLiteral = struct {
    text: []const u8,
    suffix: ?PrimitiveType,
};

pub const PrimitiveType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    bool,
};

pub const Location = struct {
    row: usize,
    column: usize,
};
