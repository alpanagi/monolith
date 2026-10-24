const std = @import("std");
const token = @import("token.zig");
const types = @import("types.zig");

pub const Program = struct {
    modules: []Module,
    types: *types.Registry,
};

pub const Module = struct {
    path: Path = &.{},
    declarations: []Declaration,
};

pub const Declaration = struct {
    kind: DeclarationKind,
    location: token.Location,
};

pub const DeclarationKind = union(enum) {
    function_declaration: FunctionSignature,
    function_definition: FunctionDefinition,
    constant_declaration: ConstantDeclaration,
    struct_definition: StructDefinition,
    trait_definition: TraitDefinition,
    implementation: Implementation,
    import: Import,
};

pub const FunctionDefinition = struct {
    signature: FunctionSignature,
    body: []Statement,
};

pub const FunctionSignature = struct {
    receiver: ?Expression = null,
    trait: ?Expression = null,
    name: []const u8,
    parameters: []TypedName,
    return_type: Expression,
};

pub const Statement = struct {
    kind: StatementKind,
    location: token.Location,
};

pub const StatementKind = union(enum) {
    noop,
    @"return": ?Expression,
    discard: Expression,
    call: Expression,
    constant_declaration: ConstantDeclaration,
    variable_declaration: VariableDeclaration,
    assignment: Assignment,
    @"while": While,
};

pub const ConstantDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
    resolved: bool = false,
};

pub const StructDefinition = struct {
    name: []const u8,
    body: Struct,
};

pub const TraitDefinition = struct {
    name: []const u8,
    functions: []FunctionSignature,
    resolved: bool = false,
};

pub const Implementation = struct {
    trait: Expression,
    type: Expression,
    functions: usize,
    resolved: ?Resolution.Trait = null,
};

pub const Import = struct {
    trait: Expression,
    resolved: ?Resolution.Trait = null,
};

pub const VariableDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
};

pub const Assignment = struct {
    target: Expression,
    value: Expression,
};

pub const While = struct {
    condition: Expression,
    body: []Statement,
};

pub const Expression = struct {
    kind: ExpressionKind,
    type: ?types.Type = null,
    location: token.Location,
};

pub const ExpressionKind = union(enum) {
    integer_literal: token.NumberLiteral,
    float_literal: token.NumberLiteral,
    boolean_literal: bool,
    character_literal: []const u8,
    string_literal: []const u8,
    undefined,
    identifier: Identifier,
    path_expression: PathExpression,
    call: Call,
    method_call: MethodCall,
    negation: *Expression,
    struct_literal: StructLiteral,
    array_type: ArrayType,
    array_literal: ArrayLiteral,
    slice_type: SliceType,
    slice: Slice,
    field_access: FieldAccess,
    @"struct": Struct,
};

pub const Call = struct {
    callee: Name,
    arguments: []Argument,
};

pub const Name = union(enum) {
    identifier: Identifier,
    path_expression: PathExpression,
};

pub const Identifier = struct {
    name: []const u8,
    resolution: ?Resolution = null,
};

pub const PathExpression = struct {
    path: Path,
    resolution: ?Resolution = null,
};

pub const Path = []const []const u8;

pub const MethodCall = struct {
    receiver: *Expression,
    name: []const u8,
    name_location: token.Location,
    arguments: []Argument,
};

pub const Resolution = union(enum) {
    parameter: usize,
    function: Resolution.Function,
    type: types.Type,
    constant: Resolution.Constant,
    local: *const Statement,

    pub const Function = struct {
        module: usize,
        declaration: usize,
    };

    pub const Constant = struct {
        module: usize,
        declaration: usize,
    };

    pub const Trait = struct {
        module: usize,
        declaration: usize,
    };
};

pub const StructLiteral = struct {
    arguments: []Argument,
};

pub const ArrayType = struct {
    length: ?*Expression,
    element: *Expression,
    value: ?types.Type = null,
};

pub const ArrayLiteral = struct {
    elements: []Expression,
};

pub const SliceType = struct {
    constant: bool,
    element: *Expression,
    value: ?types.Type = null,
};

pub const Slice = struct {
    value: *Expression,
};

pub const Argument = struct {
    name: ?[]const u8,
    value: Expression,
    location: token.Location,
};

pub const FieldAccess = struct {
    value: *Expression,
    field: []const u8,
    field_location: token.Location,
};

pub const Struct = struct {
    fields: []TypedName,
    value: ?types.Type = null,
    resolving: bool = false,
};

pub const TypedName = struct {
    name: []const u8,
    type: Expression,
    default: ?Expression = null,
    location: token.Location,
};

pub fn extractType(expression: Expression) types.Type {
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| name.resolution.?.type,
        .array_type => |array_type| array_type.value.?,
        .slice_type => |slice_type| slice_type.value.?,
        else => unreachable,
    };
}

pub fn extractResolution(name: Name) Resolution {
    return switch (name) {
        inline else => |named| named.resolution.?,
    };
}

pub fn extractFunctionSignature(declaration: Declaration) FunctionSignature {
    return switch (declaration.kind) {
        .function_definition => |function| function.signature,
        .function_declaration => |function_declaration| function_declaration,
        .constant_declaration,
        .struct_definition,
        .trait_definition,
        .implementation,
        .import,
        => unreachable,
    };
}

pub fn isMain(signature: FunctionSignature) bool {
    return signature.receiver == null and std.mem.eql(u8, signature.name, "main");
}

pub fn hasSelf(signature: FunctionSignature) bool {
    if (signature.parameters.len == 0) return false;
    const first = signature.parameters[0].type;
    if (first.kind != .identifier) return false;
    return std.mem.eql(u8, first.kind.identifier.name, "Self");
}

pub fn findMethod(
    modules: []const Module,
    caller: usize,
    receiver: types.Type,
    name: []const u8,
) MethodSearch {
    var search: MethodSearch = .missing;
    if (receiver == .@"struct") {
        const owner = receiver.@"struct".module;
        if (findOwnFunction(modules[owner], receiver, name)) |index| {
            search.add(.{ .module = owner, .declaration = index });
        }
    }
    for (modules[caller].declarations, 0..) |declaration, index| {
        const trait: Resolution.Trait = switch (declaration.kind) {
            .trait_definition => .{ .module = caller, .declaration = index },
            .import => |import| import.resolved orelse continue,
            .function_declaration,
            .function_definition,
            .constant_declaration,
            .struct_definition,
            .implementation,
            => continue,
        };
        const function = findTraitFunction(modules, trait, receiver, name) orelse continue;
        search.add(function);
    }
    return search;
}

pub const MethodSearch = union(enum) {
    missing,
    found: Resolution.Function,
    ambiguous,

    fn add(self: *MethodSearch, function: Resolution.Function) void {
        self.* = switch (self.*) {
            .missing => .{ .found = function },
            .found => |found| if (std.meta.eql(found, function)) self.* else .ambiguous,
            .ambiguous => .ambiguous,
        };
    }
};

pub fn findTraitFunction(
    modules: []const Module,
    trait: Resolution.Trait,
    receiver: types.Type,
    name: []const u8,
) ?Resolution.Function {
    for (modules, 0..) |module, module_index| {
        for (module.declarations, 0..) |declaration, index| {
            const implementation = switch (declaration.kind) {
                .implementation => |implementation| implementation,
                .function_declaration,
                .function_definition,
                .constant_declaration,
                .struct_definition,
                .trait_definition,
                .import,
                => continue,
            };
            const resolved = implementation.resolved orelse continue;
            if (!std.meta.eql(resolved, trait)) continue;
            if (!std.meta.eql(extractType(implementation.type), receiver)) continue;
            const first = index + 1;
            const functions = module.declarations[first .. first + implementation.functions];
            for (functions, first..) |function, function_index| {
                const signature = function.kind.function_definition.signature;
                if (!std.mem.eql(u8, signature.name, name)) continue;
                return .{ .module = module_index, .declaration = function_index };
            }
            return null;
        }
    }
    return null;
}

fn findOwnFunction(module: Module, receiver: types.Type, name: []const u8) ?usize {
    for (module.declarations, 0..) |declaration, index| {
        const signature = switch (declaration.kind) {
            .function_definition => |function| function.signature,
            .function_declaration,
            .constant_declaration,
            .struct_definition,
            .trait_definition,
            .implementation,
            .import,
            => continue,
        };
        const written = signature.receiver orelse continue;
        if (signature.trait != null or !std.mem.eql(u8, signature.name, name)) continue;
        if (std.meta.eql(extractType(written), receiver)) return index;
    }
    return null;
}

pub fn isDiscardedName(name: []const u8) bool {
    return std.mem.eql(u8, name, "_");
}

pub fn isAlias(constant: ConstantDeclaration) bool {
    return switch (constant.value.kind) {
        inline .identifier, .path_expression => |name| name.resolution == null,
        .array_type, .slice_type => constant.type == null,
        else => false,
    };
}

pub fn findArgument(arguments: []const Argument, name: []const u8) ?usize {
    for (arguments, 0..) |argument, index| {
        const argument_name = argument.name orelse continue;
        if (std.mem.eql(u8, argument_name, name)) return index;
    }
    return null;
}
