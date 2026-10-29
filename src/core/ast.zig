const std = @import("std");
const token = @import("token.zig");
const types = @import("types.zig");

const Value = @import("value.zig").Value;

pub const Program = struct {
    modules: []Module,
    types: *types.Registry,
};

pub const Module = struct {
    path: Path = &.{},
    declarations: []Declaration,
    instances: std.ArrayList(*Declaration) = .empty,
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
    enum_definition: EnumDefinition,
    typeclass_definition: TypeclassDefinition,
    instance_declaration: InstanceDeclaration,
    import: Import,
};

pub const FunctionDefinition = struct {
    signature: FunctionSignature,
    body: []Statement,
    default_of: ?Resolution.Typeclass = null,
    template: ?Resolution.Function = null,
    bindings: []const Binding = &.{},
    instance: ?InstanceReference = null,
    instance_arguments: []const types.Argument = &.{},
    pattern: bool = false,
    constraints: []const Constraint = &.{},
    check_only: bool = false,
    dropped_names: []const []const u8 = &.{},
    lenient: bool = false,
    body_progress: Progress = .pending,
    check_progress: Progress = .pending,
};

pub const Binding = struct {
    name: []const u8,
    target: Target,

    pub const Target = union(enum) {
        type: types.Type,
        constant: Resolution.Constant,
        constructor: types.Constructor,
    };
};

pub const InstanceReference = struct {
    module: usize,
    declaration: usize,
};

pub const Progress = enum {
    pending,
    running,
    done,
};

pub const FunctionSignature = struct {
    receiver: ?Expression = null,
    typeclass: ?Expression = null,
    name: []const u8,
    parameters: []TypedName,
    return_type: Expression,
    self_parameter: SelfParameter = .none,
    progress: Progress = .pending,
};

pub const SelfParameter = enum {
    none,
    value,
    pointer,
    constant_pointer,
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
    tuple_declaration: TupleDeclaration,
    variable_declaration: VariableDeclaration,
    assignment: Assignment,
    @"if": If,
    @"while": While,
    @"for": For,
    match: Match,
    @"defer": Defer,
    @"break": Jump,
    @"continue": Jump,
};

pub const ConstantDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
    resolved: bool = false,
    known: ?*Value = null,
    evaluating: bool = false,
};

pub const TupleDeclaration = struct {
    names: []ElementName,
    value: Expression,
};

pub const ElementName = struct {
    name: []const u8,
    pointer: bool = false,
    location: token.Location,
    type: ?types.Type = null,
};

pub const StructDefinition = struct {
    name: []const u8,
    fields: []Field,
    value: ?types.Type = null,
};

pub const EnumDefinition = struct {
    name: []const u8,
    kind: types.EnumKind = .enumeration,
    cases: []EnumCase,
    value: ?types.Type = null,
};

pub const EnumCase = struct {
    name: []const u8,
    type: ?Expression,
    location: token.Location,
};

pub const TypeclassDefinition = struct {
    name: []const u8,
    parameters: []TypeclassParameter,
    functions: []FunctionSignature,
    defaults: []?Default,
    resolved: bool = false,
};

pub const TypeclassParameter = struct {
    name: []const u8,
    arity: usize,
    requirement: ?Expression = null,
    resolved_requirement: ?Resolution.Typeclass = null,
    location: token.Location,
};

pub const Constraint = struct {
    typeclass: Resolution.Typeclass,
    arguments: []const types.Argument,
};

pub const Default = struct {
    body: []Statement,
    template: FunctionDefinition,
};

pub const InstanceDeclaration = struct {
    typeclass: Expression,
    parameters: []InstanceParameter = &.{},
    arguments: []Expression,
    functions: usize,
    defaults: []const usize = &.{},
    resolved: ?Resolution.Typeclass = null,
    resolved_arguments: []const types.Argument = &.{},
    progress: Progress = .pending,
};

pub const InstanceParameter = struct {
    name: []const u8,
    requirement: ?Expression = null,
    resolved_requirement: ?Resolution.Typeclass = null,
    location: token.Location,
};

pub const Import = struct {
    path: Path,
    name: []const u8,
    typeclass: ?Resolution.Typeclass = null,
};

pub const VariableDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
    deferred_use: ?Use = null,
};

pub const Use = struct {
    used: bool = false,
    modified: bool = false,
    discard: ?token.Location = null,
};

pub const Assignment = struct {
    target: Expression,
    operator: ?CompoundOperator = null,
    value: Expression,
};

pub const CompoundOperator = struct {
    operator: BinaryOperator,
    location: token.Location,
};

pub const If = struct {
    condition: Expression,
    body: []Statement,
    else_body: ?[]Statement = null,
    known: ?bool = null,
};

pub const While = struct {
    label: ?[]const u8 = null,
    condition: Expression,
    body: []Statement,
    else_body: ?[]Statement = null,
};

pub const For = struct {
    label: ?[]const u8 = null,
    names: []ElementName,
    tuple: bool = false,
    sequence: Sequence,
    body: []Statement,
    else_body: ?[]Statement = null,
};

pub const Defer = struct {
    statement: *Statement,
    on_error: bool = false,
};

pub const Match = struct {
    value: Expression,
    branches: []Branch,
    names: []ElementName,
};

pub const Branch = struct {
    cases: []BranchCase,
    named: bool = false,
    body: []Statement,
    location: token.Location,
};

pub const BranchCase = struct {
    name: Expression,
    index: ?usize = null,
};

pub const Sequence = union(enum) {
    value: Expression,
    range: Range,
};

pub const Range = struct {
    start: Expression,
    end: ?Expression = null,
    length: ?u64 = null,
};

pub const Jump = struct {
    label: ?[]const u8 = null,
    loop: ?*const Statement = null,
};

pub const Expression = struct {
    kind: ExpressionKind,
    type: ?types.Type = null,
    denoted: ?types.Type = null,
    location: token.Location,
};

pub const ExpressionKind = union(enum) {
    integer_literal: token.NumberLiteral,
    float_literal: token.NumberLiteral,
    boolean_literal: bool,
    string_literal: []const u8,
    undefined,
    null,
    identifier: Identifier,
    path_expression: PathExpression,
    member: Member,
    call: Call,
    method_call: MethodCall,
    negation: *Expression,
    binary: Binary,
    unary: Unary,
    address_of: *Expression,
    array_type: ArrayType,
    composite_literal: CompositeLiteral,
    slice_type: SliceType,
    index: Index,
    slice: Slice,
    pointer_type: PointerType,
    optional_type: OptionalType,
    tuple_type: TupleType,
    function_type: FunctionType,
    field_access: FieldAccess,
    dereference: *Expression,
    unwrap: *Expression,
    @"try": *Expression,
    struct_type: *StructType,
};

pub const Call = struct {
    callee: Name,
    arguments: []Argument,
    typeclass_arguments: []const types.Argument = &.{},
};

pub const Name = union(enum) {
    identifier: Identifier,
    path_expression: PathExpression,
    member: Member,
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

pub const Member = struct {
    owner: *Expression,
    name: []const u8,
    resolution: ?Resolution = null,
    typeclass_arguments: []const types.Argument = &.{},
};

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
    element: Resolution.Element,
    typeclass_function: Resolution.TypeclassFunction,
    typeclass_method: Resolution.TypeclassFunction,
    case: Resolution.Case,
    builtin: Builtin,

    pub const Function = struct {
        module: usize,
        declaration: usize,
    };

    pub const Constant = struct {
        module: usize,
        declaration: usize,
    };

    pub const Typeclass = struct {
        module: usize,
        declaration: usize,
    };

    pub const Element = struct {
        statement: *const Statement,
        position: usize,
    };

    pub const Case = struct {
        enumeration: *const types.Enum,
        index: usize,
    };

    pub const TypeclassFunction = struct {
        typeclass: Resolution.Typeclass,
        function: usize,
    };
};

pub const Builtin = enum {
    size,
    alignment,
    convert,
    truncate,
};

pub const Binary = struct {
    operator: BinaryOperator,
    operator_location: token.Location,
    left: *Expression,
    right: *Expression,
};

pub const BinaryOperator = enum {
    multiply,
    divide,
    remainder,
    add,
    subtract,
    shift_left,
    shift_right,
    bitwise_and,
    bitwise_exclusive_or,
    bitwise_or,
    combine,
    result,
    @"orelse",
    @"catch",
    equal,
    not_equal,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    @"and",
    @"or",
};

pub const Unary = struct {
    operator: UnaryOperator,
    operand: *Expression,
};

pub const UnaryOperator = enum {
    negate,
    not,
    bitwise_not,
};

pub const ArrayType = struct {
    length: ?*Expression,
    element: *Expression,
    value: ?types.Type = null,
};

pub const CompositeLiteral = struct {
    type: ?*Expression,
    elements: []Argument,
};

pub const SliceType = struct {
    constant: bool,
    element: *Expression,
    value: ?types.Type = null,
};

pub const Index = struct {
    value: *Expression,
    index: *Expression,
    position: ?u64 = null,
};

pub const Slice = struct {
    value: *Expression,
    start: ?*Expression,
    end: ?*Expression,
};

pub const PointerType = struct {
    many: bool,
    constant: bool,
    target: *Expression,
    value: ?types.Type = null,
};

pub const OptionalType = struct {
    child: *Expression,
    value: ?types.Type = null,
};

pub const TupleType = struct {
    elements: []Expression,
    value: ?types.Type = null,
};

pub const FunctionType = struct {
    parameters: []Expression,
    return_type: *Expression,
    value: ?types.Type = null,
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

pub const StructType = struct {
    fields: []Field,
    functions: []Declaration,
    module: usize = 0,
    bindings: []const Binding = &.{},
    prefix: []const u8 = "",
};

pub const TypedName = struct {
    name: []const u8,
    type: Expression,
    location: token.Location,
    kind: ParameterKind = .run_time,
    requirement: ?Expression = null,
    constraint: ?Resolution.Typeclass = null,
};

pub const ParameterKind = enum {
    run_time,
    type,
    compile_time,
    implicit,
};

pub const Field = struct {
    name: []const u8,
    type: Expression,
    default: ?Expression = null,
    default_value: ?Value = null,
    location: token.Location,
};

pub const Blocks = struct {
    statement: Statement,
    position: usize = 0,

    pub fn next(self: *Blocks) ?[]const Statement {
        const position = self.position;
        self.position += 1;
        if (self.statement.kind == .match) {
            const branches = self.statement.kind.match.branches;
            if (position >= branches.len) return null;
            return branches[position].body;
        }
        const blocks = extractBlocks(self.statement);
        if (position >= blocks.len) return null;
        return blocks[position];
    }
};

pub fn extractType(expression: Expression) types.Type {
    if (expression.denoted) |denoted| return denoted;
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| name.resolution.?.type,
        .array_type => |array_type| array_type.value.?,
        .slice_type => |slice_type| slice_type.value.?,
        .pointer_type => |pointer_type| pointer_type.value.?,
        .optional_type => |optional_type| optional_type.value.?,
        .tuple_type => |tuple_type| tuple_type.value.?,
        .function_type => |function_type| function_type.value.?,
        else => unreachable,
    };
}

pub fn extractDeclaredType(written: ?Expression, value: Expression) types.Type {
    const written_type = written orelse return value.type.?;
    return extractType(written_type);
}

pub fn findDeclaration(module: Module, index: usize) *Declaration {
    if (index < module.declarations.len) return &module.declarations[index];
    return module.instances.items[index - module.declarations.len];
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
        .enum_definition,
        .typeclass_definition,
        .instance_declaration,
        .import,
        => unreachable,
    };
}

pub fn isGeneric(signature: FunctionSignature) bool {
    for (signature.parameters) |parameter| {
        if (parameter.kind != .run_time) return true;
    }
    return false;
}

pub fn isMain(signature: FunctionSignature) bool {
    return signature.receiver == null and std.mem.eql(u8, signature.name, "main");
}

pub fn findInstance(
    allocator: std.mem.Allocator,
    modules: []const Module,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
) std.mem.Allocator.Error!InstanceSearch {
    var found: ?InstanceReference = null;
    var found_assigned: []?types.Argument = &.{};
    for (modules, 0..) |module, module_index| {
        for (module.declarations, 0..) |declaration, index| {
            if (declaration.kind != .instance_declaration) continue;
            const instance_declaration = declaration.kind.instance_declaration;
            if (!std.meta.eql(instance_declaration.resolved, typeclass)) continue;
            if (instance_declaration.resolved_arguments.len != decided.len) continue;
            const assigned = try allocator.alloc(?types.Argument, instance_declaration.parameters.len);
            @memset(assigned, null);
            const fits = for (instance_declaration.resolved_arguments, decided) |pattern, optional_argument| {
                const argument = optional_argument orelse continue;
                if (!types.matchArgument(pattern, argument, .instance, assigned)) break false;
            } else true;
            if (!fits) continue;
            if (!try satisfiesRequirements(allocator, modules, instance_declaration, assigned)) continue;
            if (found != null) return .ambiguous;
            if (instance_declaration.parameters.len > 0) {
                if (!try hasRequiredInstances(allocator, modules, typeclass, decided)) return .missing_requirement;
            }
            found = .{ .module = module_index, .declaration = index };
            found_assigned = assigned;
        }
    }
    const reference = found orelse return .missing;
    const assigned = try allocator.alloc(types.Argument, found_assigned.len);
    for (found_assigned, assigned) |optional_argument, *argument| {
        argument.* = optional_argument orelse return .undecided;
    }
    return .{ .found = .{ .reference = reference, .assigned = assigned } };
}

pub const InstanceSearch = union(enum) {
    missing,
    missing_requirement,
    ambiguous,
    undecided,
    found: FoundInstance,
};

pub const FoundInstance = struct {
    reference: InstanceReference,
    assigned: []const types.Argument,
};

pub fn findInstanceMember(modules: []const Module, reference: InstanceReference, name: []const u8) ?Resolution.Function {
    const module = modules[reference.module];
    const instance_declaration = module.declarations[reference.declaration].kind.instance_declaration;
    const first = reference.declaration + 1;
    for (module.declarations[first .. first + instance_declaration.functions], first..) |function, index| {
        if (std.mem.eql(u8, function.kind.function_definition.signature.name, name)) {
            return .{ .module = reference.module, .declaration = index };
        }
    }
    for (instance_declaration.defaults) |index| {
        if (std.mem.eql(u8, module.declarations[index].kind.function_definition.signature.name, name)) {
            return .{ .module = reference.module, .declaration = index };
        }
    }
    return null;
}

fn hasRequiredInstances(
    allocator: std.mem.Allocator,
    modules: []const Module,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
) std.mem.Allocator.Error!bool {
    const definition = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
    for (definition.parameters, decided) |parameter, optional_argument| {
        const requirement = parameter.resolved_requirement orelse continue;
        const argument = optional_argument orelse continue;
        const required: []const ?types.Argument = &.{argument};
        if (try findInstance(allocator, modules, requirement, required) != .found) return false;
    }
    return true;
}

fn satisfiesRequirements(
    allocator: std.mem.Allocator,
    modules: []const Module,
    instance_declaration: InstanceDeclaration,
    assigned: []const ?types.Argument,
) std.mem.Allocator.Error!bool {
    for (instance_declaration.parameters, assigned) |parameter, optional_argument| {
        const requirement = parameter.resolved_requirement orelse continue;
        const argument = optional_argument orelse continue;
        const decided: []const ?types.Argument = &.{argument};
        switch (try findInstance(allocator, modules, requirement, decided)) {
            .missing, .missing_requirement => return false,
            .found, .ambiguous, .undecided => {},
        }
    }
    return true;
}

pub fn findOwnMethod(modules: []const Module, receiver: types.Type, name: []const u8) ?Resolution.Function {
    const owner = switch (receiver) {
        .@"struct" => |struct_type| struct_type.module,
        .@"enum" => |enumeration| if (types.isDeclaredEnum(enumeration)) enumeration.module else return null,
        else => return null,
    };
    const index = findOwnFunction(modules[owner], receiver, name) orelse return null;
    return .{ .module = owner, .declaration = index };
}

fn findOwnFunction(module: Module, receiver: types.Type, name: []const u8) ?usize {
    for (0..module.declarations.len + module.instances.items.len) |index| {
        const declaration = findDeclaration(module, index).*;
        const signature = switch (declaration.kind) {
            .function_definition => |function| function.signature,
            .function_declaration,
            .constant_declaration,
            .struct_definition,
            .enum_definition,
            .typeclass_definition,
            .instance_declaration,
            .import,
            => continue,
        };
        const written = signature.receiver orelse continue;
        if (signature.typeclass != null or !std.mem.eql(u8, signature.name, name)) continue;
        if (std.meta.eql(extractType(written), receiver)) return index;
    }
    return null;
}

pub fn extractBlocks(statement: Statement) [2][]const Statement {
    return switch (statement.kind) {
        .@"if" => |conditional| .{ conditional.body, conditional.else_body orelse &.{} },
        .@"while" => |loop| .{ loop.body, loop.else_body orelse &.{} },
        .@"for" => |loop| .{ loop.body, loop.else_body orelse &.{} },
        .noop,
        .@"return",
        .discard,
        .call,
        .constant_declaration,
        .tuple_declaration,
        .variable_declaration,
        .assignment,
        .match,
        .@"defer",
        .@"break",
        .@"continue",
        => .{ &.{}, &.{} },
    };
}

pub fn iterateBlocks(statement: Statement) Blocks {
    return .{ .statement = statement };
}

pub fn extractLabel(statement: Statement) ?[]const u8 {
    return switch (statement.kind) {
        .@"while" => |loop| loop.label,
        .@"for" => |loop| loop.label,
        .noop,
        .@"return",
        .discard,
        .call,
        .constant_declaration,
        .tuple_declaration,
        .variable_declaration,
        .assignment,
        .@"if",
        .match,
        .@"defer",
        .@"break",
        .@"continue",
        => null,
    };
}

pub fn extractElementType(sequence: Sequence) types.Type {
    return switch (sequence) {
        .range => .{ .number = .usize },
        .value => |value| switch (types.followPointer(value.type.?)) {
            .array => |array| array.element,
            .slice => |slice| slice.element,
            .number, .boolean, .void, .type, .@"struct", .@"enum", .pointer, .optional, .result, .tuple, .function, .variable, .application => {
                unreachable;
            },
        },
    };
}

pub fn extractElementNames(statement: Statement) []ElementName {
    return switch (statement.kind) {
        .@"for" => |loop| loop.names,
        .tuple_declaration => |declaration| declaration.names,
        .match => |matching| matching.names,
        .noop,
        .@"return",
        .discard,
        .call,
        .constant_declaration,
        .variable_declaration,
        .assignment,
        .@"if",
        .@"while",
        .@"defer",
        .@"break",
        .@"continue",
        => unreachable,
    };
}

pub fn findElementName(element: Resolution.Element) ElementName {
    return extractElementNames(element.statement.*)[element.position];
}

pub fn hasPointerName(names: []const ElementName) bool {
    for (names) |name| {
        if (name.pointer) return true;
    }
    return false;
}

pub fn isDiscardedName(name: []const u8) bool {
    return std.mem.eql(u8, name, "_");
}

pub fn isAlias(constant: ConstantDeclaration) bool {
    return switch (constant.value.kind) {
        inline .identifier, .path_expression => |name| name.resolution == null,
        .array_type, .slice_type, .pointer_type, .optional_type, .tuple_type, .function_type => {
            return constant.type == null;
        },
        else => false,
    };
}

pub fn isNullComparison(binary: Binary) bool {
    if (binary.operator != .equal and binary.operator != .not_equal) return false;
    return binary.left.kind == .null or binary.right.kind == .null;
}

pub fn findArgument(arguments: []const Argument, name: []const u8) ?usize {
    for (arguments, 0..) |argument, index| {
        const argument_name = argument.name orelse continue;
        if (std.mem.eql(u8, argument_name, name)) return index;
    }
    return null;
}

pub fn findConstantRoot(expression: Expression) ?Resolution.Constant {
    return switch (expression.kind) {
        inline .identifier, .path_expression => |name| switch (name.resolution.?) {
            .constant => |constant| constant,
            .parameter, .function, .type, .local, .element, .typeclass_function, .typeclass_method, .case, .builtin => null,
        },
        .field_access => |access| {
            if (access.value.type.? == .pointer) return null;
            return findConstantRoot(access.value.*);
        },
        .index => |indexing| findElementConstantRoot(indexing.value.*),
        else => null,
    };
}

pub fn findElementConstantRoot(value: Expression) ?Resolution.Constant {
    return switch (value.type.?) {
        .array, .tuple => findConstantRoot(value),
        .number, .boolean, .void, .type, .@"struct", .@"enum", .slice, .pointer, .optional, .result, .function, .variable, .application => null,
    };
}

pub fn cloneFunctionDefinition(
    allocator: std.mem.Allocator,
    definition: FunctionDefinition,
) std.mem.Allocator.Error!FunctionDefinition {
    return .{
        .signature = try cloneFunctionSignature(allocator, definition.signature),
        .body = try cloneStatements(allocator, definition.body),
        .default_of = definition.default_of,
    };
}

pub fn cloneExpression(allocator: std.mem.Allocator, expression: Expression) std.mem.Allocator.Error!Expression {
    const kind: ExpressionKind = switch (expression.kind) {
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        => expression.kind,
        .member => |member| .{ .member = .{
            .owner = try cloneExpressionPointer(allocator, member.owner),
            .name = member.name,
        } },
        .call => |call| .{ .call = .{
            .callee = switch (call.callee) {
                .identifier, .path_expression => call.callee,
                .member => |member| .{ .member = .{
                    .owner = try cloneExpressionPointer(allocator, member.owner),
                    .name = member.name,
                } },
            },
            .arguments = try cloneArguments(allocator, call.arguments),
        } },
        .method_call => |call| .{ .method_call = .{
            .receiver = try cloneExpressionPointer(allocator, call.receiver),
            .name = call.name,
            .name_location = call.name_location,
            .arguments = try cloneArguments(allocator, call.arguments),
        } },
        .negation => |operand| .{ .negation = try cloneExpressionPointer(allocator, operand) },
        .binary => |binary| .{ .binary = .{
            .operator = binary.operator,
            .operator_location = binary.operator_location,
            .left = try cloneExpressionPointer(allocator, binary.left),
            .right = try cloneExpressionPointer(allocator, binary.right),
        } },
        .unary => |unary| .{ .unary = .{
            .operator = unary.operator,
            .operand = try cloneExpressionPointer(allocator, unary.operand),
        } },
        .address_of => |operand| .{ .address_of = try cloneExpressionPointer(allocator, operand) },
        .array_type => |array_type| .{ .array_type = .{
            .length = try cloneOptionalExpressionPointer(allocator, array_type.length),
            .element = try cloneExpressionPointer(allocator, array_type.element),
        } },
        .composite_literal => |literal| .{ .composite_literal = .{
            .type = try cloneOptionalExpressionPointer(allocator, literal.type),
            .elements = try cloneArguments(allocator, literal.elements),
        } },
        .slice_type => |slice_type| .{ .slice_type = .{
            .constant = slice_type.constant,
            .element = try cloneExpressionPointer(allocator, slice_type.element),
        } },
        .index => |indexing| .{ .index = .{
            .value = try cloneExpressionPointer(allocator, indexing.value),
            .index = try cloneExpressionPointer(allocator, indexing.index),
        } },
        .slice => |slice| .{ .slice = .{
            .value = try cloneExpressionPointer(allocator, slice.value),
            .start = try cloneOptionalExpressionPointer(allocator, slice.start),
            .end = try cloneOptionalExpressionPointer(allocator, slice.end),
        } },
        .pointer_type => |pointer_type| .{ .pointer_type = .{
            .many = pointer_type.many,
            .constant = pointer_type.constant,
            .target = try cloneExpressionPointer(allocator, pointer_type.target),
        } },
        .optional_type => |optional_type| .{ .optional_type = .{
            .child = try cloneExpressionPointer(allocator, optional_type.child),
        } },
        .tuple_type => |tuple_type| .{ .tuple_type = .{
            .elements = try cloneExpressions(allocator, tuple_type.elements),
        } },
        .function_type => |function_type| .{ .function_type = .{
            .parameters = try cloneExpressions(allocator, function_type.parameters),
            .return_type = try cloneExpressionPointer(allocator, function_type.return_type),
        } },
        .field_access => |access| .{ .field_access = .{
            .value = try cloneExpressionPointer(allocator, access.value),
            .field = access.field,
            .field_location = access.field_location,
        } },
        .dereference => |operand| .{ .dereference = try cloneExpressionPointer(allocator, operand) },
        .unwrap => |operand| .{ .unwrap = try cloneExpressionPointer(allocator, operand) },
        .@"try" => |operand| .{ .@"try" = try cloneExpressionPointer(allocator, operand) },
        .struct_type => |struct_type| kind: {
            const cloned = try allocator.create(StructType);
            cloned.* = .{ .fields = struct_type.fields, .functions = struct_type.functions };
            break :kind .{ .struct_type = cloned };
        },
    };
    return .{ .kind = kind, .location = expression.location };
}

pub fn cloneField(allocator: std.mem.Allocator, field: Field) std.mem.Allocator.Error!Field {
    return .{
        .name = field.name,
        .type = try cloneExpression(allocator, field.type),
        .default = try cloneOptionalExpression(allocator, field.default),
        .location = field.location,
    };
}

fn cloneFunctionSignature(
    allocator: std.mem.Allocator,
    signature: FunctionSignature,
) std.mem.Allocator.Error!FunctionSignature {
    const parameters = try allocator.alloc(TypedName, signature.parameters.len);
    for (signature.parameters, parameters) |parameter, *cloned| {
        cloned.* = .{
            .name = parameter.name,
            .type = try cloneExpression(allocator, parameter.type),
            .location = parameter.location,
            .kind = parameter.kind,
            .requirement = parameter.requirement,
            .constraint = parameter.constraint,
        };
    }
    return .{
        .receiver = try cloneOptionalExpression(allocator, signature.receiver),
        .typeclass = try cloneOptionalExpression(allocator, signature.typeclass),
        .name = signature.name,
        .parameters = parameters,
        .return_type = try cloneExpression(allocator, signature.return_type),
        .self_parameter = signature.self_parameter,
    };
}

fn cloneStatements(allocator: std.mem.Allocator, statements: []const Statement) std.mem.Allocator.Error![]Statement {
    const cloned = try allocator.alloc(Statement, statements.len);
    for (statements, cloned) |statement, *copy| copy.* = try cloneStatement(allocator, statement);
    return cloned;
}

fn cloneOptionalStatements(
    allocator: std.mem.Allocator,
    statements: ?[]const Statement,
) std.mem.Allocator.Error!?[]Statement {
    const present = statements orelse return null;
    return try cloneStatements(allocator, present);
}

fn cloneStatement(allocator: std.mem.Allocator, statement: Statement) std.mem.Allocator.Error!Statement {
    const kind: StatementKind = switch (statement.kind) {
        .noop => .noop,
        .@"return" => |value| .{ .@"return" = try cloneOptionalExpression(allocator, value) },
        .discard => |expression| .{ .discard = try cloneExpression(allocator, expression) },
        .call => |expression| .{ .call = try cloneExpression(allocator, expression) },
        .constant_declaration => |constant| .{ .constant_declaration = .{
            .name = constant.name,
            .type = try cloneOptionalExpression(allocator, constant.type),
            .value = try cloneExpression(allocator, constant.value),
        } },
        .tuple_declaration => |declaration| .{ .tuple_declaration = .{
            .names = try allocator.dupe(ElementName, declaration.names),
            .value = try cloneExpression(allocator, declaration.value),
        } },
        .variable_declaration => |variable| .{ .variable_declaration = .{
            .name = variable.name,
            .type = try cloneOptionalExpression(allocator, variable.type),
            .value = try cloneExpression(allocator, variable.value),
        } },
        .assignment => |assignment| .{ .assignment = .{
            .target = try cloneExpression(allocator, assignment.target),
            .operator = assignment.operator,
            .value = try cloneExpression(allocator, assignment.value),
        } },
        .@"if" => |conditional| .{ .@"if" = .{
            .condition = try cloneExpression(allocator, conditional.condition),
            .body = try cloneStatements(allocator, conditional.body),
            .else_body = try cloneOptionalStatements(allocator, conditional.else_body),
        } },
        .@"while" => |loop| .{ .@"while" = .{
            .label = loop.label,
            .condition = try cloneExpression(allocator, loop.condition),
            .body = try cloneStatements(allocator, loop.body),
            .else_body = try cloneOptionalStatements(allocator, loop.else_body),
        } },
        .@"for" => |loop| .{ .@"for" = .{
            .label = loop.label,
            .names = try allocator.dupe(ElementName, loop.names),
            .tuple = loop.tuple,
            .sequence = switch (loop.sequence) {
                .value => |value| .{ .value = try cloneExpression(allocator, value) },
                .range => |range| .{ .range = .{
                    .start = try cloneExpression(allocator, range.start),
                    .end = try cloneOptionalExpression(allocator, range.end),
                } },
            },
            .body = try cloneStatements(allocator, loop.body),
            .else_body = try cloneOptionalStatements(allocator, loop.else_body),
        } },
        .match => |matching| .{ .match = .{
            .value = try cloneExpression(allocator, matching.value),
            .branches = try cloneBranches(allocator, matching.branches),
            .names = try allocator.dupe(ElementName, matching.names),
        } },
        .@"defer" => |deferred| deferred: {
            const inner = try allocator.create(Statement);
            inner.* = try cloneStatement(allocator, deferred.statement.*);
            break :deferred .{ .@"defer" = .{ .statement = inner, .on_error = deferred.on_error } };
        },
        .@"break" => |jump| .{ .@"break" = .{ .label = jump.label } },
        .@"continue" => |jump| .{ .@"continue" = .{ .label = jump.label } },
    };
    return .{ .kind = kind, .location = statement.location };
}

fn cloneBranches(allocator: std.mem.Allocator, branches: []const Branch) std.mem.Allocator.Error![]Branch {
    const cloned = try allocator.alloc(Branch, branches.len);
    for (branches, cloned) |branch, *copy| {
        const cases = try allocator.alloc(BranchCase, branch.cases.len);
        for (branch.cases, cases) |case, *case_copy| {
            case_copy.* = .{ .name = try cloneExpression(allocator, case.name) };
        }
        copy.* = .{
            .cases = cases,
            .named = branch.named,
            .body = try cloneStatements(allocator, branch.body),
            .location = branch.location,
        };
    }
    return cloned;
}

fn cloneOptionalExpression(allocator: std.mem.Allocator, expression: ?Expression) std.mem.Allocator.Error!?Expression {
    const present = expression orelse return null;
    return try cloneExpression(allocator, present);
}

fn cloneExpressionPointer(allocator: std.mem.Allocator, expression: *const Expression) std.mem.Allocator.Error!*Expression {
    const cloned = try allocator.create(Expression);
    cloned.* = try cloneExpression(allocator, expression.*);
    return cloned;
}

fn cloneOptionalExpressionPointer(
    allocator: std.mem.Allocator,
    expression: ?*const Expression,
) std.mem.Allocator.Error!?*Expression {
    const present = expression orelse return null;
    return try cloneExpressionPointer(allocator, present);
}

fn cloneExpressions(allocator: std.mem.Allocator, expressions: []const Expression) std.mem.Allocator.Error![]Expression {
    const cloned = try allocator.alloc(Expression, expressions.len);
    for (expressions, cloned) |expression, *copy| copy.* = try cloneExpression(allocator, expression);
    return cloned;
}

fn cloneArguments(allocator: std.mem.Allocator, arguments: []const Argument) std.mem.Allocator.Error![]Argument {
    const cloned = try allocator.alloc(Argument, arguments.len);
    for (arguments, cloned) |argument, *copy| {
        copy.* = .{
            .name = argument.name,
            .value = try cloneExpression(allocator, argument.value),
            .location = argument.location,
        };
    }
    return cloned;
}

test "extractBlocks: finds the body and the else block of a loop" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    var body = [_]Statement{.{ .kind = .noop, .location = location }};
    var else_body = [_]Statement{ .{ .kind = .noop, .location = location }, .{ .kind = .noop, .location = location } };
    const loop: Statement = .{
        .kind = .{ .@"while" = .{
            .condition = .{ .kind = .{ .boolean_literal = true }, .location = location },
            .body = &body,
            .else_body = &else_body,
        } },
        .location = location,
    };

    const blocks = extractBlocks(loop);
    try std.testing.expectEqual(@as([]const Statement, &body), blocks[0]);
    try std.testing.expectEqual(@as([]const Statement, &else_body), blocks[1]);
}

test "extractBlocks: finds an empty else block for an if without one" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    var body = [_]Statement{.{ .kind = .noop, .location = location }};
    const conditional: Statement = .{
        .kind = .{ .@"if" = .{
            .condition = .{ .kind = .{ .boolean_literal = true }, .location = location },
            .body = &body,
        } },
        .location = location,
    };

    const blocks = extractBlocks(conditional);
    try std.testing.expectEqual(@as([]const Statement, &body), blocks[0]);
    try std.testing.expectEqual(0, blocks[1].len);
}

test "iterateBlocks: walks the body of every branch of a match" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    var one = [_]Statement{.{ .kind = .noop, .location = location }};
    var two = [_]Statement{.{ .kind = .noop, .location = location }};
    var branches = [_]Branch{
        .{ .cases = &.{}, .body = &one, .location = location },
        .{ .cases = &.{}, .body = &two, .location = location },
    };
    const matching: Statement = .{
        .kind = .{ .match = .{
            .value = .{ .kind = .{ .identifier = .{ .name = "value" } }, .location = location },
            .branches = &branches,
            .names = &.{},
        } },
        .location = location,
    };

    var blocks = iterateBlocks(matching);
    try std.testing.expectEqual(@as([]const Statement, &one), blocks.next().?);
    try std.testing.expectEqual(@as([]const Statement, &two), blocks.next().?);
    try std.testing.expectEqual(null, blocks.next());
}

test "extractElementType: finds the element of the array a pointer points to" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    const array: types.Array = .{ .length = 3, .element = .boolean };
    const pointer: types.Pointer = .{ .target = .{ .array = &array }, .many = false, .constant = true };
    const sequence: Sequence = .{ .value = .{
        .kind = .{ .identifier = .{ .name = "data" } },
        .type = .{ .pointer = &pointer },
        .location = location,
    } };

    try std.testing.expectEqual(types.Type.boolean, extractElementType(sequence));
}

test "extractElementType: finds usize elements in a range" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    const sequence: Sequence = .{ .range = .{
        .start = .{ .kind = .{ .integer_literal = .{ .text = "0", .suffix = null } }, .location = location },
    } };

    try std.testing.expectEqual(types.Type{ .number = .usize }, extractElementType(sequence));
}

test "findConstantRoot: finds the constant that stores a field or an element" {
    const constant: Resolution.Constant = .{ .module = 0, .declaration = 1 };
    const location: token.Location = .{ .row = 1, .column = 1 };
    const field: types.Field = .{ .name = "elements", .type = .boolean, .location = location };
    const data_type: types.Type = .{ .@"struct" = .{ .module = 0, .name = "Data", .fields = &.{field} } };
    const tuple: types.Tuple = .{ .elements = &.{ data_type, data_type } };
    var data: Expression = .{
        .kind = .{ .identifier = .{ .name = "data", .resolution = .{ .constant = constant } } },
        .type = .{ .tuple = &tuple },
        .location = location,
    };
    var position: Expression = .{ .kind = .{ .boolean_literal = true }, .type = .boolean, .location = location };
    var element: Expression = .{
        .kind = .{ .index = .{ .value = &data, .index = &position } },
        .type = data_type,
        .location = location,
    };
    const access: Expression = .{
        .kind = .{ .field_access = .{ .value = &element, .field = "elements", .field_location = location } },
        .type = .boolean,
        .location = location,
    };

    try std.testing.expectEqual(constant, findConstantRoot(access).?);
}

test "findConstantRoot: finds nothing behind a pointer or a slice" {
    const constant: Resolution.Constant = .{ .module = 0, .declaration = 1 };
    const location: token.Location = .{ .row = 1, .column = 1 };
    const pointer: types.Pointer = .{ .target = .boolean, .many = true, .constant = true };
    const slice: types.Slice = .{ .element = .boolean, .constant = true };
    var through_pointer: Expression = .{
        .kind = .{ .identifier = .{ .name = "data", .resolution = .{ .constant = constant } } },
        .type = .{ .pointer = &pointer },
        .location = location,
    };
    var through_slice: Expression = .{
        .kind = .{ .identifier = .{ .name = "data", .resolution = .{ .constant = constant } } },
        .type = .{ .slice = &slice },
        .location = location,
    };
    var position: Expression = .{ .kind = .{ .boolean_literal = true }, .type = .boolean, .location = location };
    const access: Expression = .{
        .kind = .{ .field_access = .{ .value = &through_pointer, .field = "value", .field_location = location } },
        .type = .boolean,
        .location = location,
    };
    const element: Expression = .{
        .kind = .{ .index = .{ .value = &through_slice, .index = &position } },
        .type = .boolean,
        .location = location,
    };

    try std.testing.expectEqual(null, findConstantRoot(access));
    try std.testing.expectEqual(null, findConstantRoot(element));
}
