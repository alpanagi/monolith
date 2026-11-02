const std = @import("std");
const token = @import("token.zig");
const types = @import("types.zig");

const Value = @import("value.zig").Value;

pub const module_root = "";

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
    owner: ?usize = null,
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
    pristine: ?*const FunctionDefinition = null,
    instantiated: bool = false,
    allocator: ?*const types.Type = null,
    need: Need = .unknown,
    dropped_names: []const []const u8 = &.{},
    lenient: bool = false,
    body_progress: Progress = .pending,
    check_progress: Progress = .pending,
};

pub const Need = enum {
    unknown,
    running,
    no,
    yes,
};

pub const allocator_parameter = "mn_allocator";

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
    declared: []InstanceParameter = &.{},
    parameters: []TypedName,
    return_type: Expression,
    self_parameter: SelfParameter = .none,
    progress: Progress = .pending,
    @"inline": bool = false,
    inferred_error_set: ?token.Location = null,
    error_set: ?*types.Enum = null,
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
    value: Expression,
};

pub const ConstantDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
    resolved: bool = false,
    known: ?*Value = null,
    evaluating: bool = false,
    bound: bool = false,
    measured: bool = false,
    with: bool = false,
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
    external: bool = false,
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
    measured: bool = false,
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
    names: []ElementName = &.{},
    body: []Statement,
    else_body: ?[]Statement = null,
    known: ?bool = null,
    dropped_ends: bool = false,
    produces: bool = false,
};

pub const While = struct {
    label: ?[]const u8 = null,
    condition: Expression,
    names: []ElementName = &.{},
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
    iterator: ?Iteration = null,
    expansion_value: ?*Statement = null,
    expansions: []const []Statement = &.{},
};

pub const Iteration = struct {
    next: Resolution.Function,
    element: types.Type,
};

pub const Defer = struct {
    statement: *Statement,
    on_error: bool = false,
};

pub const Match = struct {
    value: Expression,
    branches: []Branch,
    names: []ElementName,
    produces: bool = false,
};

pub const Branch = struct {
    cases: []BranchCase,
    naming: Naming = .none,
    body: []Statement,
    location: token.Location,
};

pub const BranchCase = struct {
    pattern: Expression,
    end: ?Expression = null,
    range: bool = false,
    kind: CaseKind = .case,
    index: ?usize = null,
    minimum: i129 = 0,
    maximum: i129 = 0,
};

pub const Naming = enum {
    none,
    payload,
    value,
};

pub const CaseKind = enum {
    case,
    value,
    null,
    integer,
};

pub const Sequence = union(enum) {
    value: Expression,
    range: Range,
};

pub const Range = struct {
    start: Expression,
    end: ?Expression = null,
    length: ?u64 = null,
    type: ?types.Type = null,
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
    range: *Range,
    struct_type: *StructType,
    jump: *Statement,
    branching: *Statement,
};

pub const Call = struct {
    callee: Name,
    arguments: []Argument,
    typeclass_arguments: []const types.Argument = &.{},
    @"inline": bool = false,
    with_value: ?*Expression = null,
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
    with_value: ?*Expression = null,
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
    cast,
    @"align",
    length,
    join,
    @"error",
    add_wrapping,
    subtract_wrapping,
    multiply_wrapping,
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
    known: ?*Value = null,
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
    types: []Declaration = &.{},
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
    measured: bool = false,
    hidden: bool = false,
};

pub const ParameterKind = enum {
    run_time,
    type,
    compile_time,
    implicit,
    any,
};

pub const Field = struct {
    name: []const u8,
    type: Expression,
    default: ?Expression = null,
    default_value: ?Value = null,
    location: token.Location,
};

pub const Expressions = struct {
    items: [2]*const Expression = undefined,
    count: usize = 0,

    fn append(self: *Expressions, expression: *const Expression) void {
        self.items[self.count] = expression;
        self.count += 1;
    }
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
        if (self.statement.kind == .@"for" and isUnrolled(self.statement.kind.@"for")) {
            const loop = self.statement.kind.@"for";
            if (position < loop.expansions.len) return loop.expansions[position];
            if (position == loop.expansions.len) return loop.else_body orelse &.{};
            return null;
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
    if (signature.declared.len > 0) return true;
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
    if (isTupleTypeclass(modules, typeclass)) {
        const argument = decided[0] orelse return .undecided;
        if (argument != .type or argument.type != .tuple) return .missing;
        const reference: InstanceReference = .{ .module = typeclass.module, .declaration = typeclass.declaration };
        return .{ .found = .{ .reference = reference, .assigned = &.{} } };
    }
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

pub fn isTupleTypeclass(modules: []const Module, typeclass: Resolution.Typeclass) bool {
    const module = modules[typeclass.module];
    if (module.path.len != 1 or !std.mem.eql(u8, module.path[0], "mn")) return false;
    const declaration = module.declarations[typeclass.declaration];
    return std.mem.eql(u8, declaration.kind.typeclass_definition.name, "Tuple");
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
        .value,
        => .{ &.{}, &.{} },
    };
}

pub fn isEndingBlock(module: Module, statements: []const Statement) bool {
    for (statements) |statement| {
        if (isEndingStatement(module, statement)) return true;
    }
    return false;
}

fn isEndingStatement(module: Module, statement: Statement) bool {
    return switch (statement.kind) {
        .@"return", .@"break", .@"continue" => true,
        .call => |expression| isComptimeErrorCall(module, expression),
        .@"if" => |conditional| {
            const else_body = conditional.else_body orelse return false;
            return isEndingBlock(module, conditional.body) and isEndingBlock(module, else_body);
        },
        .match => |matching| {
            for (matching.branches) |branch| {
                if (!isEndingBlock(module, branch.body)) return false;
            }
            return true;
        },
        .noop, .discard, .constant_declaration, .tuple_declaration, .variable_declaration, .assignment, .@"while", .@"for", .@"defer", .value => false,
    };
}

pub fn extractExpressions(statement: *const Statement) Expressions {
    var expressions: Expressions = .{};
    switch (statement.kind) {
        .@"return" => |*value| if (value.*) |*returned| expressions.append(returned),
        .discard, .call, .value => |*expression| expressions.append(expression),
        .constant_declaration => |*constant| expressions.append(&constant.value),
        .tuple_declaration => |*declaration| expressions.append(&declaration.value),
        .variable_declaration => |*variable| expressions.append(&variable.value),
        .assignment => |*assignment| {
            expressions.append(&assignment.value);
            expressions.append(&assignment.target);
        },
        .@"if" => |*conditional| expressions.append(&conditional.condition),
        .@"while" => |*loop| expressions.append(&loop.condition),
        .@"for" => |*loop| switch (loop.sequence) {
            .value => |*value| expressions.append(value),
            .range => |*range| {
                expressions.append(&range.start);
                if (range.end) |*end| expressions.append(end);
            },
        },
        .match => |*matching| expressions.append(&matching.value),
        .noop, .@"defer", .@"break", .@"continue" => {},
    }
    return expressions;
}

pub fn collectJumps(
    allocator: std.mem.Allocator,
    jumps: *std.ArrayList(*Statement),
    expression: *const Expression,
) std.mem.Allocator.Error!void {
    switch (expression.kind) {
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        .struct_type,
        => {},
        .member => |member| try collectJumps(allocator, jumps, member.owner),
        .call => |call| {
            if (call.callee == .member) try collectJumps(allocator, jumps, call.callee.member.owner);
            for (call.arguments) |*argument| try collectJumps(allocator, jumps, &argument.value);
        },
        .method_call => |call| {
            try collectJumps(allocator, jumps, call.receiver);
            for (call.arguments) |*argument| try collectJumps(allocator, jumps, &argument.value);
        },
        .composite_literal => |literal| {
            for (literal.elements) |*element| try collectJumps(allocator, jumps, &element.value);
        },
        .binary => |binary| {
            try collectJumps(allocator, jumps, binary.left);
            try collectJumps(allocator, jumps, binary.right);
        },
        .unary => |unary| try collectJumps(allocator, jumps, unary.operand),
        .negation, .address_of, .dereference, .unwrap, .@"try" => |operand| try collectJumps(allocator, jumps, operand),
        .index => |indexing| {
            try collectJumps(allocator, jumps, indexing.value);
            try collectJumps(allocator, jumps, indexing.index);
        },
        .slice => |slice| {
            try collectJumps(allocator, jumps, slice.value);
            if (slice.start) |start| try collectJumps(allocator, jumps, start);
            if (slice.end) |end| try collectJumps(allocator, jumps, end);
        },
        .field_access => |access| try collectJumps(allocator, jumps, access.value),
        .range => |range| {
            try collectJumps(allocator, jumps, &range.start);
            if (range.end) |*end| try collectJumps(allocator, jumps, end);
        },
        .jump => |statement| {
            try jumps.append(allocator, statement);
            if (statement.kind == .@"return") {
                if (statement.kind.@"return") |*value| try collectJumps(allocator, jumps, value);
            }
        },
        .branching => {},
    }
}

pub fn collectBranchings(
    allocator: std.mem.Allocator,
    branchings: *std.ArrayList(*Statement),
    expression: *const Expression,
) std.mem.Allocator.Error!void {
    switch (expression.kind) {
        .integer_literal,
        .float_literal,
        .boolean_literal,
        .string_literal,
        .undefined,
        .null,
        .identifier,
        .path_expression,
        .array_type,
        .slice_type,
        .pointer_type,
        .optional_type,
        .tuple_type,
        .function_type,
        .struct_type,
        => {},
        .member => |member| try collectBranchings(allocator, branchings, member.owner),
        .call => |call| {
            if (call.callee == .member) try collectBranchings(allocator, branchings, call.callee.member.owner);
            for (call.arguments) |*argument| try collectBranchings(allocator, branchings, &argument.value);
        },
        .method_call => |call| {
            try collectBranchings(allocator, branchings, call.receiver);
            for (call.arguments) |*argument| try collectBranchings(allocator, branchings, &argument.value);
        },
        .composite_literal => |literal| {
            for (literal.elements) |*element| try collectBranchings(allocator, branchings, &element.value);
        },
        .binary => |binary| {
            try collectBranchings(allocator, branchings, binary.left);
            try collectBranchings(allocator, branchings, binary.right);
        },
        .unary => |unary| try collectBranchings(allocator, branchings, unary.operand),
        .negation, .address_of, .dereference, .unwrap, .@"try" => |operand| try collectBranchings(allocator, branchings, operand),
        .index => |indexing| {
            try collectBranchings(allocator, branchings, indexing.value);
            try collectBranchings(allocator, branchings, indexing.index);
        },
        .slice => |slice| {
            try collectBranchings(allocator, branchings, slice.value);
            if (slice.start) |start| try collectBranchings(allocator, branchings, start);
            if (slice.end) |end| try collectBranchings(allocator, branchings, end);
        },
        .field_access => |access| try collectBranchings(allocator, branchings, access.value),
        .range => |range| {
            try collectBranchings(allocator, branchings, &range.start);
            if (range.end) |*end| try collectBranchings(allocator, branchings, end);
        },
        .jump => |statement| {
            if (statement.kind == .@"return") {
                if (statement.kind.@"return") |*value| try collectBranchings(allocator, branchings, value);
            }
        },
        .branching => |statement| try branchings.append(allocator, statement),
    }
}

pub fn collectStatementBranchings(
    allocator: std.mem.Allocator,
    branchings: *std.ArrayList(*Statement),
    statement: *const Statement,
) std.mem.Allocator.Error!void {
    const expressions = extractExpressions(statement);
    for (expressions.items[0..expressions.count]) |expression| try collectBranchings(allocator, branchings, expression);
}

pub fn collectStatementJumps(
    allocator: std.mem.Allocator,
    jumps: *std.ArrayList(*Statement),
    statement: *const Statement,
) std.mem.Allocator.Error!void {
    const expressions = extractExpressions(statement);
    for (expressions.items[0..expressions.count]) |expression| try collectJumps(allocator, jumps, expression);
}

pub fn findWrappingOperator(builtin: Builtin) ?BinaryOperator {
    return switch (builtin) {
        .add_wrapping => .add,
        .subtract_wrapping => .subtract,
        .multiply_wrapping => .multiply,
        .size, .alignment, .convert, .truncate, .cast, .@"align", .length, .join, .@"error" => null,
    };
}

pub fn isComptimeErrorCall(module: Module, expression: Expression) bool {
    if (expression.kind != .call) return false;
    const path = switch (expression.kind.call.callee) {
        .identifier, .member => return false,
        .path_expression => |path_expression| path_expression,
    };
    if (path.resolution) |resolution| return resolution == .builtin and resolution.builtin == .@"error";
    const names = path.path;
    if (!std.mem.eql(u8, names[names.len - 1], "error")) return false;
    if (names.len == 3) return std.mem.eql(u8, names[0], "mn") and std.mem.eql(u8, names[1], "comptime");
    if (names.len != 2) return false;
    for (module.declarations) |declaration| {
        if (declaration.kind != .import) continue;
        const import = declaration.kind.import;
        if (!std.mem.eql(u8, import.name, names[0]) or import.path.len != 2) continue;
        if (std.mem.eql(u8, import.path[0], "mn") and std.mem.eql(u8, import.path[1], "comptime")) return true;
    }
    return false;
}

pub fn isUnrolled(loop: For) bool {
    if (loop.sequence != .value) return false;
    const sequence_type = loop.sequence.value.type orelse return false;
    return sequence_type == .tuple;
}

pub fn iterateBlocks(statement: Statement) Blocks {
    return .{ .statement = statement };
}

pub fn findBranching(statement: *const Statement) ?*Statement {
    const value = switch (statement.kind) {
        .@"return" => |value| value orelse return null,
        .constant_declaration => |constant| constant.value,
        .tuple_declaration => |declaration| declaration.value,
        .variable_declaration => |variable| variable.value,
        .assignment => |assignment| assignment.value,
        .noop, .discard, .call, .@"if", .@"while", .@"for", .match, .@"defer", .@"break", .@"continue", .value => return null,
    };
    if (value.kind != .branching) return null;
    return value.kind.branching;
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
        .value,
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
        .@"if" => |conditional| conditional.names,
        .@"while" => |loop| loop.names,
        .noop,
        .@"return",
        .discard,
        .call,
        .constant_declaration,
        .variable_declaration,
        .assignment,
        .@"defer",
        .@"break",
        .@"continue",
        .value,
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
    if (constant.with) return false;
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
        .call => |*call| .{ .call = try cloneCall(allocator, call) },
        .method_call => |*call| .{ .method_call = try cloneMethodCall(allocator, call) },
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
        .range => |range| .{ .range = try cloneRange(allocator, range) },
        .struct_type => |struct_type| kind: {
            const cloned = try allocator.create(StructType);
            cloned.* = .{ .fields = struct_type.fields, .functions = struct_type.functions, .types = struct_type.types };
            break :kind .{ .struct_type = cloned };
        },
        .jump => |statement| .{ .jump = try cloneNestedStatement(allocator, statement) },
        .branching => |statement| .{ .branching = try cloneNestedStatement(allocator, statement) },
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

fn cloneCall(allocator: std.mem.Allocator, call: *const Call) std.mem.Allocator.Error!Call {
    return .{
        .callee = switch (call.callee) {
            .identifier, .path_expression => call.callee,
            .member => |member| .{ .member = .{
                .owner = try cloneExpressionPointer(allocator, member.owner),
                .name = member.name,
            } },
        },
        .arguments = try cloneArguments(allocator, call.arguments),
        .with_value = try cloneWithValue(allocator, call.with_value),
    };
}

fn cloneMethodCall(allocator: std.mem.Allocator, call: *const MethodCall) std.mem.Allocator.Error!MethodCall {
    return .{
        .receiver = try cloneExpressionPointer(allocator, call.receiver),
        .name = call.name,
        .name_location = call.name_location,
        .arguments = try cloneArguments(allocator, call.arguments),
        .with_value = try cloneWithValue(allocator, call.with_value),
    };
}

fn cloneWithValue(allocator: std.mem.Allocator, value: ?*Expression) std.mem.Allocator.Error!?*Expression {
    const present = value orelse return null;
    return try cloneExpressionPointer(allocator, present);
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
        .declared = signature.declared,
        .parameters = parameters,
        .return_type = try cloneExpression(allocator, signature.return_type),
        .self_parameter = signature.self_parameter,
        .@"inline" = signature.@"inline",
        .inferred_error_set = signature.inferred_error_set,
    };
}

pub fn cloneBlock(allocator: std.mem.Allocator, statements: []const Statement) std.mem.Allocator.Error![]Statement {
    return cloneStatements(allocator, statements);
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
            .with = constant.with,
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
            .names = try allocator.dupe(ElementName, conditional.names),
            .body = try cloneStatements(allocator, conditional.body),
            .else_body = try cloneOptionalStatements(allocator, conditional.else_body),
        } },
        .@"while" => |loop| .{ .@"while" = .{
            .label = loop.label,
            .condition = try cloneExpression(allocator, loop.condition),
            .names = try allocator.dupe(ElementName, loop.names),
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
        .@"defer" => |deferred| .{ .@"defer" = try cloneDefer(allocator, deferred) },
        .@"break" => |jump| .{ .@"break" = .{ .label = jump.label } },
        .@"continue" => |jump| .{ .@"continue" = .{ .label = jump.label } },
        .value => |expression| .{ .value = try cloneExpression(allocator, expression) },
    };
    return .{ .kind = kind, .location = statement.location };
}

fn cloneNestedStatement(allocator: std.mem.Allocator, statement: *const Statement) std.mem.Allocator.Error!*Statement {
    const cloned = try allocator.create(Statement);
    cloned.* = try cloneStatement(allocator, statement.*);
    return cloned;
}

fn cloneDefer(allocator: std.mem.Allocator, deferred: Defer) std.mem.Allocator.Error!Defer {
    const inner = try allocator.create(Statement);
    inner.* = try cloneStatement(allocator, deferred.statement.*);
    return .{ .statement = inner, .on_error = deferred.on_error };
}

fn cloneRange(allocator: std.mem.Allocator, range: *const Range) std.mem.Allocator.Error!*Range {
    const cloned = try allocator.create(Range);
    cloned.* = .{
        .start = try cloneExpression(allocator, range.start),
        .end = try cloneOptionalExpression(allocator, range.end),
    };
    return cloned;
}

fn cloneBranches(allocator: std.mem.Allocator, branches: []const Branch) std.mem.Allocator.Error![]Branch {
    const cloned = try allocator.alloc(Branch, branches.len);
    for (branches, cloned) |branch, *copy| {
        const cases = try allocator.alloc(BranchCase, branch.cases.len);
        for (branch.cases, cases) |case, *case_copy| {
            case_copy.* = .{
                .pattern = try cloneExpression(allocator, case.pattern),
                .end = try cloneOptionalExpression(allocator, case.end),
                .range = case.range,
            };
        }
        copy.* = .{
            .cases = cases,
            .naming = branch.naming,
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

test "findBranching: finds the if that gives the value of a declaration" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    var one = [_]Statement{.{ .kind = .noop, .location = location }};
    var two = [_]Statement{.{ .kind = .noop, .location = location }};
    var conditional: Statement = .{
        .kind = .{ .@"if" = .{
            .condition = .{ .kind = .{ .identifier = .{ .name = "ready" } }, .location = location },
            .body = &one,
            .else_body = &two,
        } },
        .location = location,
    };
    const declaration: Statement = .{
        .kind = .{ .constant_declaration = .{
            .name = "value",
            .value = .{ .kind = .{ .branching = &conditional }, .location = location },
        } },
        .location = location,
    };

    try std.testing.expectEqual(&conditional, findBranching(&declaration).?);
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
