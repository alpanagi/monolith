const std = @import("std");
const token = @import("token.zig");
const types = @import("types.zig");

const Integer = @import("value.zig").Integer;
const Value = @import("value.zig").Value;

pub const module_root = "";
pub const case_without_enum_message = "a leading :: names a case or a function of the expected type, and no enum or struct is expected here; use module:: for a declaration of this module, and the name of its error set for an error";
pub const case_without_known_enum_message = "a leading :: names a case or a function of the expected type, and that type is not known from the surrounding code; use module:: for a declaration of this module";

pub const Program = struct {
    modules: []Module,
    types: *types.Registry,
    skipped_defers: []const SkippedDefer = &.{},
};

pub const SkippedDefer = struct {
    statement: *const Statement,
    exit: *const Expression,
    sources: []const *const Expression = &.{},
};

pub const Module = struct {
    path: Path = &.{},
    declarations: []Declaration,
    paths: []const Path = &.{},
    has_range: bool = false,
    instances: std.ArrayList(*Declaration) = .empty,
};

pub const Declaration = struct {
    kind: DeclarationKind,
    location: token.Location,
    owner: ?usize = null,
    private: bool = false,
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
    allocator_root: bool = false,
    need: Need = .unknown,
    need_reason: ?NeedReason = null,
    dropped_names: []const []const u8 = &.{},
    lenient: bool = false,
    body_progress: Progress = .pending,
    check_progress: Progress = .pending,
};

pub const NeedReason = struct {
    location: token.Location,
    callee: ?Resolution.Function = null,
};

pub const Need = enum {
    unknown,
    running,
    no,
    yes,
};

pub const allocator_parameter = "mn_allocator";
pub const context_local = "mn_context";
pub const allocator_name = "allocator";

pub const Binding = struct {
    name: []const u8,
    target: Target,

    pub const Target = union(enum) {
        type: types.Type,
        constant: Resolution.Constant,
        constructor: types.Constructor,
        length: types.Variable,
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
    return_own: bool = false,
    private: bool = false,
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
    own: bool = false,
    moved: bool = false,
    context: bool = false,
    context_used: bool = false,
    called_early: bool = false,
};

pub const TupleDeclaration = struct {
    names: []ElementName,
    value: Expression,
    variable: bool = false,
    own: bool = false,
    moved: bool = false,
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
    @"inline": bool = false,
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
    requirements: []Expression = &.{},
    resolved_requirements: []Requirement = &.{},
    location: token.Location,
};

pub const Constraint = struct {
    typeclass: Resolution.Typeclass,
    arguments: []const types.Argument,
};

pub const Requirement = struct {
    typeclass: Resolution.Typeclass,
    arguments: []const types.Argument = &.{},
    unknown_position: usize = 0,
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
    only_reads: bool = false,
};

pub const InstanceParameter = struct {
    name: []const u8,
    is_length: bool = false,
    requirements: []Expression = &.{},
    resolved_requirements: []Requirement = &.{},
    location: token.Location,
};

pub const Import = struct {
    path: Path,
    crossings: []const bool = &.{},
    name: []const u8,
    typeclass: ?Resolution.Typeclass = null,
};

pub const VariableDeclaration = struct {
    name: []const u8,
    type: ?Expression = null,
    value: Expression,
    deferred_use: ?Use = null,
    measured: bool = false,
    own: bool = false,
    moved: bool = false,
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
    moved: bool = false,
};

pub const CompoundOperator = struct {
    operator: BinaryOperator,
    location: token.Location,
};

pub const If = struct {
    condition: Expression,
    marker: ?token.Location = null,
    moved: bool = false,
    names: []ElementName = &.{},
    own: bool = false,
    tuple: bool = false,
    body: []Statement,
    else_body: ?[]Statement = null,
    known: ?bool = null,
    dropped_ends: bool = false,
    produces: bool = false,
};

pub const While = struct {
    label: ?[]const u8 = null,
    condition: Expression,
    marker: ?token.Location = null,
    moved: bool = false,
    names: []ElementName = &.{},
    own: bool = false,
    tuple: bool = false,
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
};

pub const Iteration = struct {
    iterator: Resolution.Function,
    cursor: types.Type,
    next: Resolution.Function,
    element: types.Type,
};

pub const Defer = struct {
    statement: *Statement,
    on_error: bool = false,
};

pub const Match = struct {
    value: Expression,
    marker: ?token.Location = null,
    moved: bool = false,
    branches: []Branch,
    names: []ElementName,
    produces: bool = false,
    gives_void: bool = false,
};

pub const Branch = struct {
    cases: []BranchCase,
    naming: Naming = .none,
    own: bool = false,
    tuple: bool = false,
    first_name: usize = 0,
    name_count: usize = 1,
    body: []Statement,
    location: token.Location,
};

pub const BranchCase = struct {
    pattern: Expression,
    end: ?Expression = null,
    range: bool = false,
    kind: CaseKind = .case,
    index: ?usize = null,
    minimum: Integer = undefined,
    maximum: Integer = undefined,
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
    known_end: ?u64 = null,
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
    handed: bool = false,
    implicit: bool = false,
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
    case_literal: CaseLiteral,
    inferred_type: InferredType,
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

pub const CaseLiteral = struct {
    name: []const u8,
    crossing: bool = false,
    arguments: []Argument = &.{},
    called: bool = false,
    braced: bool = false,
    with_value: ?*Expression = null,
    expected: ?types.Type = null,
};

pub const InferredType = struct {
    expected: ?types.Type = null,
};

pub const Call = struct {
    callee: Name,
    arguments: []Argument,
    typeclass_arguments: []const types.Argument = &.{},
    @"inline": bool = false,
    with_value: ?*Expression = null,
    braces: Braces = .none,
    constructor: ?Resolution.Function = null,
};

pub const Name = union(enum) {
    identifier: Identifier,
    path_expression: PathExpression,
    member: Member,
};

pub const Braces = enum {
    none,
    written,
    gathered,
};

pub const Identifier = struct {
    name: []const u8,
    resolution: ?Resolution = null,
};

pub const PathExpression = struct {
    path: Path,
    crossings: []const bool = &.{},
    resolution: ?Resolution = null,
};

pub const Path = []const []const u8;

pub const Member = struct {
    owner: *Expression,
    name: []const u8,
    crossing: bool = false,
    resolution: ?Resolution = null,
    typeclass_arguments: []const types.Argument = &.{},
};

pub const MethodCall = struct {
    receiver: *Expression,
    name: []const u8,
    name_location: token.Location,
    crossing: bool = false,
    arguments: []Argument,
    with_value: ?*Expression = null,
    receiver_own: bool = false,
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
    own: bool = false,
    crossing: bool = false,
    receiver: bool = false,
};

pub const FieldAccess = struct {
    value: *Expression,
    field: []const u8,
    field_location: token.Location,
    crossing: bool = false,
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
    requirements: []Expression = &.{},
    resolved_requirements: []Requirement = &.{},
    constraint: ?Resolution.Typeclass = null,
    constraint_arguments: []const types.Argument = &.{},
    unknown_position: usize = 0,
    measured: bool = false,
    hidden: bool = false,
    own: bool = false,
    default: ?*Expression = null,
    default_constant: ?Resolution.Constant = null,
    inherited_default: ?InheritedDefault = null,
};

pub const InheritedDefault = struct {
    constant: Resolution.Constant,
    typeclass: Resolution.Typeclass,
};

pub fn fillConstraintArguments(
    allocator: std.mem.Allocator,
    parameter: TypedName,
    value_type: types.Type,
) std.mem.Allocator.Error![]types.Argument {
    if (parameter.constraint_arguments.len == 0) return allocator.dupe(types.Argument, &.{.{ .type = value_type }});
    const arguments = try allocator.dupe(types.Argument, parameter.constraint_arguments);
    arguments[parameter.unknown_position] = .{ .type = value_type };
    return arguments;
}

pub fn fillRequirementArguments(
    allocator: std.mem.Allocator,
    requirement: Requirement,
    value_type: types.Type,
) std.mem.Allocator.Error![]types.Argument {
    if (requirement.arguments.len == 0) return allocator.dupe(types.Argument, &.{.{ .type = value_type }});
    const arguments = try allocator.dupe(types.Argument, requirement.arguments);
    arguments[requirement.unknown_position] = .{ .type = value_type };
    return arguments;
}

pub fn decideRequirement(
    allocator: std.mem.Allocator,
    registry: *types.Registry,
    requirement: Requirement,
    value: types.Argument,
    assigned: []const ?types.Argument,
    scope: types.Scope,
) std.mem.Allocator.Error!?[]const ?types.Argument {
    const decided = try decideRequirementArguments(allocator, registry, requirement, value, assigned, scope);
    for (decided) |argument| {
        if (argument == null) return null;
    }
    return decided;
}

pub fn decideThroughRequirement(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    requirement: Requirement,
    value: types.Argument,
    assigned: []?types.Argument,
    scope: types.Scope,
) std.mem.Allocator.Error!?RequirementDecision {
    const decided = try decideRequirementArguments(allocator, registry, requirement, value, assigned, scope);
    for (decided) |argument| {
        if (argument == null) break;
    } else return null;
    const found = switch (try findInstance(allocator, modules, registry, requirement.typeclass, decided)) {
        .missing => return .missing,
        .missing_requirement => return .missing_requirement,
        .ambiguous => |pair| return .{ .ambiguous = pair },
        .undecided => return .undecided,
        .found => |found| found,
    };
    const arguments = try substituteInstanceArguments(allocator, modules, registry, found);
    for (requirement.arguments, decided, arguments) |pattern, argument, instance_argument| {
        if (argument != null) continue;
        if (!types.matchArgument(pattern, instance_argument, scope, assigned, false)) return .missing;
    }
    return .decided;
}

pub fn substituteInstanceArguments(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    found: FoundInstance,
) std.mem.Allocator.Error![]types.Argument {
    const instance_declaration = modules[found.reference.module].declarations[found.reference.declaration].kind.instance_declaration;
    const arguments = try allocator.alloc(types.Argument, instance_declaration.resolved_arguments.len);
    for (instance_declaration.resolved_arguments, arguments) |pattern, *argument| {
        argument.* = switch (pattern) {
            .type => |value_type| .{ .type = try types.substitute(allocator, registry, value_type, found.assigned, .instance) },
            .constructor => |constructor| constructor: {
                if (constructor != .variable or constructor.variable.scope != .instance) break :constructor pattern;
                break :constructor found.assigned[constructor.variable.index];
            },
            .length => pattern,
        };
    }
    return arguments;
}

fn decideRequirementArguments(
    allocator: std.mem.Allocator,
    registry: *types.Registry,
    requirement: Requirement,
    value: types.Argument,
    assigned: []const ?types.Argument,
    scope: types.Scope,
) std.mem.Allocator.Error![]?types.Argument {
    if (requirement.arguments.len == 0) return allocator.dupe(?types.Argument, &.{value});
    const known = try allocator.alloc(types.Argument, assigned.len);
    for (assigned, known, 0..) |optional_argument, *argument, index| {
        argument.* = optional_argument orelse .{ .type = .{ .variable = .{ .scope = scope, .index = index } } };
    }
    const decided = try allocator.alloc(?types.Argument, requirement.arguments.len);
    for (requirement.arguments, decided, 0..) |argument, *slot, position| {
        if (position == requirement.unknown_position) {
            slot.* = value;
            continue;
        }
        slot.* = switch (argument) {
            .type => |value_type| decided: {
                const substituted = try types.substitute(allocator, registry, value_type, known, scope);
                if (types.containsVariable(substituted, scope)) break :decided null;
                break :decided .{ .type = substituted };
            },
            .constructor, .length => argument,
        };
    }
    return decided;
}

pub const RequirementDecision = union(enum) {
    decided,
    missing,
    missing_requirement,
    ambiguous: [2]InstanceReference,
    undecided,
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
    own: bool = false,
    private: bool = false,
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

pub fn isHidden(module: Module, index: usize) bool {
    var current: ?usize = index;
    while (current) |position| {
        const declaration = module.declarations[position];
        if (isPrivate(declaration)) return true;
        current = declaration.owner;
    }
    return false;
}

pub fn findTypeDeclaration(module: Module, value_type: types.Type) ?usize {
    for (module.declarations, 0..) |declaration, index| {
        const value = switch (declaration.kind) {
            .struct_definition => |definition| definition.value,
            .enum_definition => |definition| definition.value,
            .function_definition,
            .function_declaration,
            .constant_declaration,
            .typeclass_definition,
            .instance_declaration,
            .import,
            => continue,
        } orelse continue;
        if (std.meta.eql(value, value_type)) return index;
    }
    return null;
}

pub fn isPrivate(declaration: Declaration) bool {
    return switch (declaration.kind) {
        .function_definition => |definition| definition.signature.private,
        .function_declaration => |signature| signature.private,
        .constant_declaration, .struct_definition, .enum_definition, .typeclass_definition, .instance_declaration, .import => declaration.private,
    };
}

pub fn renderTypeName(allocator: std.mem.Allocator, modules: []const Module, value_type: types.Type) std.mem.Allocator.Error![]const u8 {
    return switch (value_type) {
        .number => |number| @tagName(number),
        .boolean => "bool",
        .void => "void",
        .type => "type",
        .@"struct" => |struct_type| name: {
            const origin = struct_type.origin orelse break :name struct_type.name;
            const function = origin.function orelse break :name struct_type.name;
            const name = extractFunctionSignature(findDeclaration(modules[function.module], function.declaration).*).name;
            var arguments: std.ArrayList([]const u8) = .empty;
            for (origin.arguments) |argument| try arguments.append(allocator, try renderTypeName(allocator, modules, argument));
            break :name std.fmt.allocPrint(allocator, "{s}({s})", .{ name, try std.mem.join(allocator, ", ", arguments.items) });
        },
        .@"enum" => |enumeration| enumeration.name,
        .array => |array| std.fmt.allocPrint(allocator, "[{d}]{s}", .{ array.length, try renderTypeName(allocator, modules, array.element) }),
        .slice => |slice| renderReadOnly(allocator, "[]", slice.constant, try renderTypeName(allocator, modules, slice.element)),
        .pointer => |pointer| renderReadOnly(allocator, if (pointer.many) "*many" else "*", pointer.constant, try renderTypeName(allocator, modules, pointer.target)),
        .optional => |optional| std.fmt.allocPrint(allocator, "?{s}", .{try renderTypeName(allocator, modules, optional.child)}),
        .result => |result| std.fmt.allocPrint(allocator, "{s}!{s}", .{ result.error_set.name, try renderTypeName(allocator, modules, result.value) }),
        .tuple => |tuple| name: {
            var elements: std.ArrayList([]const u8) = .empty;
            for (tuple.elements) |element| try elements.append(allocator, try renderTypeName(allocator, modules, element));
            break :name std.fmt.allocPrint(allocator, "[{s}]", .{try std.mem.join(allocator, ", ", elements.items)});
        },
        .function, .variable, .application => "the type",
    };
}

fn renderReadOnly(allocator: std.mem.Allocator, prefix: []const u8, constant: bool, target: []const u8) std.mem.Allocator.Error![]const u8 {
    const inner = if (constant) try std.fmt.allocPrint(allocator, "const({s})", .{target}) else target;
    if (std.mem.eql(u8, prefix, "*many")) return std.fmt.allocPrint(allocator, "*many({s})", .{inner});
    return std.mem.concat(allocator, u8, &.{ prefix, inner });
}

pub fn isMain(signature: FunctionSignature) bool {
    return signature.receiver == null and std.mem.eql(u8, signature.name, "main");
}

pub fn findInstance(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
) std.mem.Allocator.Error!InstanceSearch {
    const exact = try searchInstance(allocator, modules, registry, typeclass, decided, false);
    if (exact != .missing) return exact;
    const relaxed = try searchInstance(allocator, modules, registry, typeclass, decided, true);
    if (relaxed != .missing) return relaxed;
    return findNothingOwningInstance(allocator, modules, typeclass, decided);
}

pub fn isNothingOwningInstance(modules: []const Module, module_index: usize, instance_declaration: InstanceDeclaration) bool {
    const typeclass = instance_declaration.resolved orelse return false;
    if (typeclass.module != module_index or !isNothingOwningTypeclass(modules, typeclass)) return false;
    if (instance_declaration.parameters.len != 1 or instance_declaration.resolved_arguments.len != 1) return false;
    const argument = instance_declaration.resolved_arguments[0];
    return argument == .type and argument.type == .variable and argument.type.variable.scope == .instance;
}

fn isNothingOwningTypeclass(modules: []const Module, typeclass: Resolution.Typeclass) bool {
    const path: []const []const u8 = &.{ "mn", "memory" };
    return isLibraryTypeclass(modules, typeclass, path, "Deinit") or isLibraryTypeclass(modules, typeclass, path, "Clone");
}

fn findNothingOwningInstance(
    allocator: std.mem.Allocator,
    modules: []const Module,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
) std.mem.Allocator.Error!InstanceSearch {
    if (!isNothingOwningTypeclass(modules, typeclass) or decided.len != 1) return .missing;
    const argument = decided[0] orelse return .missing;
    if (argument != .type or types.canOwn(argument.type)) return .missing;
    for (modules[typeclass.module].declarations, 0..) |declaration, index| {
        if (declaration.kind != .instance_declaration) continue;
        if (!std.meta.eql(declaration.kind.instance_declaration.resolved, typeclass)) continue;
        if (!isNothingOwningInstance(modules, typeclass.module, declaration.kind.instance_declaration)) continue;
        const reference: InstanceReference = .{ .module = typeclass.module, .declaration = index };
        return .{ .found = .{ .reference = reference, .assigned = try allocator.dupe(types.Argument, &.{argument}) } };
    }
    return .missing;
}

fn searchInstance(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
    relaxed: bool,
) std.mem.Allocator.Error!InstanceSearch {
    if (isTupleTypeclass(modules, typeclass)) {
        const argument = decided[0] orelse return .undecided;
        if (argument != .type or argument.type != .tuple) return .missing;
        const reference: InstanceReference = .{ .module = typeclass.module, .declaration = typeclass.declaration };
        return .{ .found = .{ .reference = reference, .assigned = &.{} } };
    }
    var candidates: std.ArrayList(Candidate) = .empty;
    for (modules, 0..) |module, module_index| {
        for (module.declarations, 0..) |declaration, index| {
            if (declaration.kind != .instance_declaration) continue;
            const instance_declaration = declaration.kind.instance_declaration;
            if (!std.meta.eql(instance_declaration.resolved, typeclass)) continue;
            if (instance_declaration.resolved_arguments.len != decided.len) continue;
            if (isNothingOwningInstance(modules, module_index, instance_declaration)) continue;
            const assigned = try allocator.alloc(?types.Argument, instance_declaration.parameters.len);
            @memset(assigned, null);
            const fits = for (instance_declaration.resolved_arguments, decided, 0..) |pattern, optional_argument, position| {
                const argument = optional_argument orelse continue;
                const reads_only = relaxed and !isTargetParameter(modules, typeclass, position);
                if (!types.matchArgument(pattern, argument, .instance, assigned, reads_only)) break false;
            } else true;
            if (!fits) continue;
            const decision = try decideFromRequirements(allocator, modules, registry, instance_declaration, assigned);
            if (decision == .missing) continue;
            if (!try satisfiesRequirements(allocator, modules, registry, instance_declaration, assigned)) continue;
            const ambiguous: ?[2]InstanceReference = if (decision == .ambiguous) decision.ambiguous else null;
            try candidates.append(allocator, .{ .reference = .{ .module = module_index, .declaration = index }, .assigned = assigned, .ambiguous = ambiguous });
        }
    }
    if (candidates.items.len == 0) return .missing;
    const chosen = switch (try chooseMostSpecific(allocator, modules, candidates.items)) {
        .chosen => |chosen| chosen,
        .ambiguous => |pair| return .{ .ambiguous = pair },
    };
    if (chosen.ambiguous) |pair| return .{ .ambiguous = pair };
    const instance_declaration = modules[chosen.reference.module].declarations[chosen.reference.declaration].kind.instance_declaration;
    if (instance_declaration.parameters.len > 0) {
        if (!try hasRequiredInstances(allocator, modules, registry, typeclass, decided)) return .missing_requirement;
    }
    const assigned = try allocator.alloc(types.Argument, chosen.assigned.len);
    for (chosen.assigned, assigned) |optional_argument, *argument| {
        argument.* = optional_argument orelse return .undecided;
    }
    return .{ .found = .{ .reference = chosen.reference, .assigned = assigned } };
}

fn chooseMostSpecific(allocator: std.mem.Allocator, modules: []const Module, candidates: []const Candidate) std.mem.Allocator.Error!Choice {
    for (candidates) |candidate| {
        const most_specific = for (candidates) |other| {
            if (std.meta.eql(candidate.reference, other.reference)) continue;
            if (!try isMoreSpecific(allocator, modules, candidate.reference, other.reference)) break false;
        } else true;
        if (most_specific) return .{ .chosen = candidate };
    }
    for (candidates, 0..) |one, position| {
        for (candidates[position + 1 ..]) |two| {
            if (try isMoreSpecific(allocator, modules, one.reference, two.reference)) continue;
            if (try isMoreSpecific(allocator, modules, two.reference, one.reference)) continue;
            return .{ .ambiguous = .{ one.reference, two.reference } };
        }
    }
    return .{ .ambiguous = .{ candidates[0].reference, candidates[1].reference } };
}

pub fn isMoreSpecific(allocator: std.mem.Allocator, modules: []const Module, specific: InstanceReference, general: InstanceReference) std.mem.Allocator.Error!bool {
    const one = modules[general.module].declarations[general.declaration].kind.instance_declaration;
    const two = modules[specific.module].declarations[specific.declaration].kind.instance_declaration;
    const sides: types.Sides = .{
        .one = try allocator.alloc(?types.Unified, one.parameters.len),
        .two = try allocator.alloc(?types.Unified, two.parameters.len),
        .rigid = .two,
    };
    @memset(sides.one, null);
    @memset(sides.two, null);
    return types.unifyArguments(one.resolved_arguments, two.resolved_arguments, sides);
}

pub fn renderInstance(allocator: std.mem.Allocator, modules: []const Module, reference: InstanceReference) std.mem.Allocator.Error![]const u8 {
    const instance_declaration = modules[reference.module].declarations[reference.declaration].kind.instance_declaration;
    const typeclass = instance_declaration.resolved.?;
    const name = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition.name;
    var arguments: std.ArrayList([]const u8) = .empty;
    for (instance_declaration.resolved_arguments) |argument| {
        try arguments.append(allocator, switch (argument) {
            .type => |value_type| try renderInstanceType(allocator, modules, instance_declaration.parameters, value_type),
            .constructor => |constructor| switch (constructor) {
                .variable => |variable| instance_declaration.parameters[variable.index].name,
                .function => |function| extractFunctionSignature(findDeclaration(modules[function.module], function.declaration).*).name,
                .typeclass_function => "the type",
            },
            .length => |length| try std.fmt.allocPrint(allocator, "{d}", .{length}),
        });
    }
    const module_name = try std.mem.join(allocator, "::", modules[reference.module].path);
    return std.fmt.allocPrint(allocator, "`{s}({s})` in `{s}`", .{ name, try std.mem.join(allocator, ", ", arguments.items), module_name });
}

fn renderInstanceType(
    allocator: std.mem.Allocator,
    modules: []const Module,
    parameters: []const InstanceParameter,
    value_type: types.Type,
) std.mem.Allocator.Error![]const u8 {
    return switch (value_type) {
        .variable => |variable| if (variable.scope == .instance) parameters[variable.index].name else "the type",
        .application => |application| name: {
            const constructor = switch (application.constructor) {
                .variable => |variable| if (variable.scope == .instance) parameters[variable.index].name else "the type",
                .function => |function| extractFunctionSignature(findDeclaration(modules[function.module], function.declaration).*).name,
                .typeclass_function => "the type",
            };
            var arguments: std.ArrayList([]const u8) = .empty;
            for (application.arguments) |argument| try arguments.append(allocator, try renderInstanceType(allocator, modules, parameters, argument));
            break :name std.fmt.allocPrint(allocator, "{s}({s})", .{ constructor, try std.mem.join(allocator, ", ", arguments.items) });
        },
        .optional => |optional| std.fmt.allocPrint(allocator, "?{s}", .{try renderInstanceType(allocator, modules, parameters, optional.child)}),
        .pointer => |pointer| renderReadOnly(allocator, if (pointer.many) "*many" else "*", pointer.constant, try renderInstanceType(allocator, modules, parameters, pointer.target)),
        .slice => |slice| renderReadOnly(allocator, "[]", slice.constant, try renderInstanceType(allocator, modules, parameters, slice.element)),
        .array => |array| name: {
            const element = try renderInstanceType(allocator, modules, parameters, array.element);
            if (array.length_variable) |variable| break :name std.fmt.allocPrint(allocator, "[{s}]{s}", .{ parameters[variable.index].name, element });
            break :name std.fmt.allocPrint(allocator, "[{d}]{s}", .{ array.length, element });
        },
        else => renderTypeName(allocator, modules, value_type),
    };
}

const Candidate = struct {
    reference: InstanceReference,
    assigned: []?types.Argument,
    ambiguous: ?[2]InstanceReference = null,
};

const Choice = union(enum) {
    chosen: Candidate,
    ambiguous: [2]InstanceReference,
};

fn isTargetParameter(modules: []const Module, typeclass: Resolution.Typeclass, position: usize) bool {
    const definition = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
    for (definition.functions) |signature| {
        for (signature.parameters) |parameter| {
            if (parameter.kind == .type and std.mem.eql(u8, parameter.name, definition.parameters[position].name)) return true;
        }
    }
    return false;
}

pub fn isTupleTypeclass(modules: []const Module, typeclass: Resolution.Typeclass) bool {
    return isLibraryTypeclass(modules, typeclass, &.{ "mn", "reflection" }, "Tuple");
}

pub fn isElementTypeclass(modules: []const Module, typeclass: Resolution.Typeclass) bool {
    return isTupleTypeclass(modules, typeclass) or isLibraryTypeclass(modules, typeclass, &.{ "mn", "iterator" }, "Iterable");
}

pub fn isLibraryTypeclass(modules: []const Module, typeclass: Resolution.Typeclass, path: []const []const u8, name: []const u8) bool {
    const module = modules[typeclass.module];
    if (module.path.len != path.len) return false;
    for (module.path, path) |segment, expected| {
        if (!std.mem.eql(u8, segment, expected)) return false;
    }
    const declaration = module.declarations[typeclass.declaration];
    return std.mem.eql(u8, declaration.kind.typeclass_definition.name, name);
}

pub const InstanceSearch = union(enum) {
    missing,
    missing_requirement,
    ambiguous: [2]InstanceReference,
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
    registry: *types.Registry,
    typeclass: Resolution.Typeclass,
    decided: []const ?types.Argument,
) std.mem.Allocator.Error!bool {
    const definition = modules[typeclass.module].declarations[typeclass.declaration].kind.typeclass_definition;
    for (definition.parameters, decided) |parameter, optional_argument| {
        const argument = optional_argument orelse continue;
        for (parameter.resolved_requirements) |requirement| {
            const required = try decideRequirement(allocator, registry, requirement, argument, decided, .typeclass) orelse continue;
            if (try findInstance(allocator, modules, registry, requirement.typeclass, required) != .found) return false;
        }
    }
    return true;
}

fn decideFromRequirements(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    instance_declaration: InstanceDeclaration,
    assigned: []?types.Argument,
) std.mem.Allocator.Error!RequirementDecision {
    var progress = true;
    while (progress) {
        progress = false;
        for (instance_declaration.parameters, 0..) |parameter, index| {
            const argument = assigned[index] orelse continue;
            for (parameter.resolved_requirements) |requirement| {
                const decision = try decideThroughRequirement(allocator, modules, registry, requirement, argument, assigned, .instance) orelse continue;
                switch (decision) {
                    .decided => progress = true,
                    .missing, .missing_requirement => return .missing,
                    .ambiguous => return decision,
                    .undecided => {},
                }
            }
        }
    }
    return .decided;
}

fn satisfiesRequirements(
    allocator: std.mem.Allocator,
    modules: []const Module,
    registry: *types.Registry,
    instance_declaration: InstanceDeclaration,
    assigned: []const ?types.Argument,
) std.mem.Allocator.Error!bool {
    for (instance_declaration.parameters, assigned) |parameter, optional_argument| {
        const argument = optional_argument orelse continue;
        for (parameter.resolved_requirements) |requirement| {
            const decided = try decideRequirement(allocator, registry, requirement, argument, assigned, .instance) orelse continue;
            switch (try findInstance(allocator, modules, registry, requirement.typeclass, decided)) {
                .missing, .missing_requirement => return false,
                .found, .ambiguous, .undecided => {},
            }
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
        .case_literal => |literal| {
            for (literal.arguments) |*argument| try collectJumps(allocator, jumps, &argument.value);
        },
        .inferred_type => {},
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
        .case_literal => |literal| {
            for (literal.arguments) |*argument| try collectBranchings(allocator, branchings, &argument.value);
        },
        .inferred_type => {},
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

pub fn isCopiedElement(loop: For, position: usize) bool {
    if (loop.names[position].pointer) return false;
    const element = findIterationPart(loop, position);
    return element == .pointer and !element.pointer.many;
}

pub fn findIterationPart(loop: For, position: usize) types.Type {
    const element = loop.iterator.?.element;
    if (!loop.tuple) return element;
    return element.tuple.elements[position];
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

pub fn isTupleCondition(statement: Statement) bool {
    return switch (statement.kind) {
        .@"if" => |conditional| conditional.tuple,
        .@"while" => |loop| loop.tuple,
        else => unreachable,
    };
}

pub fn extractBranchNames(matching: Match, branch: Branch) []ElementName {
    return matching.names[branch.first_name..][0..branch.name_count];
}

pub fn findNameBranch(matching: Match, position: usize) usize {
    for (matching.branches, 0..) |branch, index| {
        if (position < branch.first_name + branch.name_count) return index;
    }
    unreachable;
}

pub const Place = struct {
    root: Resolution,
    steps: []const PartStep = &.{},

    pub fn extend(self: Place, allocator: std.mem.Allocator, step: PartStep) std.mem.Allocator.Error!Place {
        const steps = try allocator.alloc(PartStep, self.steps.len + 1);
        @memcpy(steps[0..self.steps.len], self.steps);
        steps[self.steps.len] = step;
        return .{ .root = self.root, .steps = steps };
    }

    pub fn contains(self: Place, other: Place) bool {
        if (!std.meta.eql(self.root, other.root)) return false;
        if (self.steps.len > other.steps.len) return false;
        for (self.steps, other.steps[0..self.steps.len]) |one, two| {
            if (!one.eql(two)) return false;
        }
        return true;
    }

    pub fn eql(self: Place, other: Place) bool {
        return self.steps.len == other.steps.len and self.contains(other);
    }
};

pub const PartStep = union(enum) {
    field: []const u8,
    element: u64,
    value,

    pub fn eql(self: PartStep, other: PartStep) bool {
        return switch (self) {
            .field => |name| other == .field and std.mem.eql(u8, name, other.field),
            .element => |position| other == .element and position == other.element,
            .value => other == .value,
        };
    }
};

pub fn findSyntacticPlace(allocator: std.mem.Allocator, expression: Expression) std.mem.Allocator.Error!?Place {
    switch (expression.kind) {
        .identifier => |identifier| {
            const resolution = identifier.resolution orelse return null;
            return switch (resolution) {
                .local, .parameter, .element => .{ .root = resolution },
                else => null,
            };
        },
        .address_of => |operand| return findSyntacticPlace(allocator, operand.*),
        .field_access => |access| {
            const base = try findSyntacticPlace(allocator, access.value.*) orelse return null;
            return try base.extend(allocator, .{ .field = access.field });
        },
        .index => |indexing| {
            const position = indexing.position orelse return null;
            const base = try findSyntacticPlace(allocator, indexing.value.*) orelse return null;
            return try base.extend(allocator, .{ .element = position });
        },
        .unwrap => |operand| {
            const base = try findSyntacticPlace(allocator, operand.*) orelse return null;
            return try base.extend(allocator, .value);
        },
        else => return null,
    }
}

pub fn collectStatementMoves(allocator: std.mem.Allocator, statement: *const Statement, moved: *std.ArrayList(*const Expression)) std.mem.Allocator.Error!void {
    switch (statement.kind) {
        .discard, .call, .value => |*expression| try collectExpressionMoves(allocator, expression, moved),
        .assignment => |*assignment| {
            try collectExpressionMoves(allocator, &assignment.value, moved);
            if (assignment.moved) try moved.append(allocator, &assignment.value);
        },
        else => {},
    }
}

fn collectExpressionMoves(allocator: std.mem.Allocator, expression: *const Expression, moved: *std.ArrayList(*const Expression)) std.mem.Allocator.Error!void {
    const arguments: []const Argument = switch (expression.kind) {
        .call => |call| call.arguments,
        .method_call => |call| call.arguments,
        .composite_literal => |literal| literal.elements,
        .case_literal => |literal| literal.arguments,
        .@"try" => |operand| return collectExpressionMoves(allocator, operand, moved),
        else => return,
    };
    for (arguments) |*argument| {
        try collectExpressionMoves(allocator, &argument.value, moved);
        if (argument.own) try moved.append(allocator, &argument.value);
    }
}

pub fn isOwnElement(element: Resolution.Element) bool {
    return switch (element.statement.kind) {
        .@"if" => |conditional| conditional.own,
        .@"while" => |loop| loop.own,
        .match => |matching| matching.branches[findNameBranch(matching, element.position)].own,
        .tuple_declaration => |declaration| declaration.own,
        else => false,
    };
}

pub fn isWritableElement(element: Resolution.Element) bool {
    return switch (element.statement.kind) {
        .tuple_declaration => |declaration| declaration.variable or declaration.own,
        else => isOwnElement(element),
    };
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
    if (constant.with or constant.context) return false;
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
            .crossing = member.crossing,
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
        .inferred_type => |inferred| .{ .inferred_type = inferred },
        .case_literal => |literal| .{ .case_literal = .{
            .name = literal.name,
            .crossing = literal.crossing,
            .arguments = try cloneArguments(allocator, literal.arguments),
            .called = literal.called,
            .braced = literal.braced,
            .with_value = try cloneWithValue(allocator, literal.with_value),
            .expected = literal.expected,
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
            .crossing = access.crossing,
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
    return .{ .kind = kind, .location = expression.location, .handed = expression.handed, .implicit = expression.implicit };
}

pub fn cloneField(allocator: std.mem.Allocator, field: Field) std.mem.Allocator.Error!Field {
    return .{
        .name = field.name,
        .type = try cloneExpression(allocator, field.type),
        .default = try cloneOptionalExpression(allocator, field.default),
        .location = field.location,
        .own = field.own,
        .private = field.private,
    };
}

fn cloneCall(allocator: std.mem.Allocator, call: *const Call) std.mem.Allocator.Error!Call {
    return .{
        .callee = switch (call.callee) {
            .identifier, .path_expression => call.callee,
            .member => |member| .{ .member = .{
                .owner = try cloneExpressionPointer(allocator, member.owner),
                .name = member.name,
                .crossing = member.crossing,
            } },
        },
        .arguments = try cloneArguments(allocator, call.arguments),
        .with_value = try cloneWithValue(allocator, call.with_value),
        .braces = call.braces,
        .constructor = call.constructor,
    };
}

fn cloneMethodCall(allocator: std.mem.Allocator, call: *const MethodCall) std.mem.Allocator.Error!MethodCall {
    return .{
        .receiver = try cloneExpressionPointer(allocator, call.receiver),
        .name = call.name,
        .name_location = call.name_location,
        .crossing = call.crossing,
        .arguments = try cloneArguments(allocator, call.arguments),
        .with_value = try cloneWithValue(allocator, call.with_value),
        .receiver_own = call.receiver_own,
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
            .requirements = parameter.requirements,
            .resolved_requirements = parameter.resolved_requirements,
            .constraint = parameter.constraint,
            .constraint_arguments = parameter.constraint_arguments,
            .unknown_position = parameter.unknown_position,
            .own = parameter.own,
            .default = parameter.default,
            .default_constant = parameter.default_constant,
            .inherited_default = parameter.inherited_default,
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
        .return_own = signature.return_own,
        .private = signature.private,
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
            .with = constant.with,
            .own = constant.own,
            .moved = constant.moved,
            .context = constant.context,
        } },
        .tuple_declaration => |declaration| .{ .tuple_declaration = .{
            .names = try allocator.dupe(ElementName, declaration.names),
            .value = try cloneExpression(allocator, declaration.value),
            .variable = declaration.variable,
            .own = declaration.own,
            .moved = declaration.moved,
        } },
        .variable_declaration => |variable| .{ .variable_declaration = .{
            .name = variable.name,
            .type = try cloneOptionalExpression(allocator, variable.type),
            .value = try cloneExpression(allocator, variable.value),
            .own = variable.own,
            .moved = variable.moved,
        } },
        .assignment => |assignment| .{ .assignment = .{
            .target = try cloneExpression(allocator, assignment.target),
            .operator = assignment.operator,
            .value = try cloneExpression(allocator, assignment.value),
            .moved = assignment.moved,
        } },
        .@"if" => |conditional| .{ .@"if" = .{
            .condition = try cloneExpression(allocator, conditional.condition),
            .marker = conditional.marker,
            .moved = conditional.moved,
            .names = try allocator.dupe(ElementName, conditional.names),
            .own = conditional.own,
            .tuple = conditional.tuple,
            .body = try cloneStatements(allocator, conditional.body),
            .else_body = try cloneOptionalStatements(allocator, conditional.else_body),
        } },
        .@"while" => |loop| .{ .@"while" = .{
            .label = loop.label,
            .condition = try cloneExpression(allocator, loop.condition),
            .marker = loop.marker,
            .moved = loop.moved,
            .names = try allocator.dupe(ElementName, loop.names),
            .own = loop.own,
            .tuple = loop.tuple,
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
            .marker = matching.marker,
            .moved = matching.moved,
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
            .own = branch.own,
            .tuple = branch.tuple,
            .first_name = branch.first_name,
            .name_count = branch.name_count,
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
            .own = argument.own,
            .crossing = argument.crossing,
            .receiver = argument.receiver,
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

test "findNameBranch: finds the branch that gives each name when a branch takes a tuple apart" {
    const location: token.Location = .{ .row = 1, .column = 1 };
    var names = [_]ElementName{
        .{ .name = "_", .location = location },
        .{ .name = "key", .location = location },
        .{ .name = "value", .location = location },
        .{ .name = "rest", .location = location },
    };
    var branches = [_]Branch{
        .{ .cases = &.{}, .body = &.{}, .location = location },
        .{ .cases = &.{}, .tuple = true, .first_name = 1, .name_count = 2, .body = &.{}, .location = location },
        .{ .cases = &.{}, .first_name = 3, .body = &.{}, .location = location },
    };
    const matching: Match = .{
        .value = .{ .kind = .{ .identifier = .{ .name = "value" } }, .location = location },
        .branches = &branches,
        .names = &names,
    };

    try std.testing.expectEqual(0, findNameBranch(matching, 0));
    try std.testing.expectEqual(1, findNameBranch(matching, 1));
    try std.testing.expectEqual(1, findNameBranch(matching, 2));
    try std.testing.expectEqual(2, findNameBranch(matching, 3));
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
