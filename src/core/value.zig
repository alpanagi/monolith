const ast = @import("ast.zig");
const types = @import("types.zig");

pub const Value = union(enum) {
    integer: i129,
    float: f128,
    boolean: bool,
    void,
    undefined,
    optional: ?*Value,
    aggregate: []Value,
    pointer: Value.Pointer,
    many: Value.Many,
    slice: Value.Slice,
    function: ast.Resolution.Function,
    type: types.Type,
    enumeration: Value.Enumeration,
    failure: Value.Enumeration,

    pub const Enumeration = struct {
        case: *const types.Case,
        value: ?*Value = null,
    };

    pub const Pointer = struct {
        root: *Value,
        root_type: types.Type,
        path: []const usize,
        text: bool = false,
    };

    pub const Many = struct {
        array: Value.Pointer,
        index: i129,
    };

    pub const Slice = struct {
        array: Value.Pointer,
        start: usize,
        length: usize,
    };
};
