//! Port of tools/expr-template-compiler.pl: compiles src/jit/core_templates.expr
//! (S-expression templates per MoarVM opcode) into the C tables in
//! core_templates.h. Must run from the repository root because `include:`
//! paths in .expr files are cwd-relative.
const std = @import("std");
const sexpr = @import("sexpr.zig");
const oplist = @import("oplist.zig");
const expr_ops = @import("expr_ops.zig");
const Node = sexpr.Node;

const PREFIX = "MVM_JIT_";

pub const Error = error{
    InvalidTemplate,
    UnknownOperator,
    TypeMismatch,
    NotDeclared,
    UndefinedMacro,
    MacroArity,
    UnmatchedSubstitution,
    InvalidName,
    ExpectedExpression,
    ExpectedOperator,
    OperandCount,
    CannotMatchTypes,
    ExpectedSizeParameter,
    ExpectedReference,
    InvalidOperandReference,
    RequireReference,
    NotAReference,
    UndefinedNamedReference,
    ExpectedMacroExpression,
    UnknownOpcode,
    OpcodeRedefined,
    NoWriteOperand,
    UnknownKeyword,
    MacroRedeclared,
    TemplateRedeclaredInInclude,
    MalformedStatement,
    OutOfMemory,
};

// --- Template check tables (verbatim from the Perl tool) ---

/// Expected result type of an operator; anything missing is 'reg'.
const operator_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "store", "void" },    .{ "store_num", "void" },  .{ "discard", "void" }, .{ "dov", "void" },
    .{ "when", "void" },     .{ "ifv", "void" },        .{ "branch", "void" },  .{ "mark", "void" },
    .{ "callv", "void" },    .{ "guard", "void" },      .{ "lt", "flag" },      .{ "le", "flag" },
    .{ "eq", "flag" },       .{ "ne", "flag" },         .{ "ge", "flag" },      .{ "gt", "flag" },
    .{ "nz", "flag" },       .{ "zr", "flag" },         .{ "all", "flag" },     .{ "any", "flag" },
    .{ "const_num", "num" }, .{ "load_num", "num" },    .{ "calln", "num" },    .{ "if", "?" },
    .{ "copy", "?" },        .{ "do", "?" },            .{ "add", "?" },        .{ "sub", "?" },
    .{ "mul", "?" },         .{ "arglist", "arglist" }, .{ "carg", "carg" },
});

/// Expected operand types, comma separated; anything missing is 'reg'.
const operand_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "flagval", "flag" },       .{ "all", "flag" },         .{ "any", "flag" },          .{ "copy", "?" },
    .{ "do", "void,?" },          .{ "dov", "void" },         .{ "when", "flag,void" },    .{ "if", "flag,?,?" },
    .{ "ifv", "flag,void,void" }, .{ "call", "reg,arglist" }, .{ "calln", "reg,arglist" }, .{ "callv", "reg,arglist" },
    .{ "arglist", "carg" },       .{ "carg", "?" },           .{ "store", "reg,?" },       .{ "guard", "void" },
    .{ "lt", "?" },               .{ "le", "?" },             .{ "eq", "?" },              .{ "ne", "?" },
    .{ "ge", "?" },               .{ "gt", "?" },             .{ "nz", "?" },              .{ "zr", "?" },
    .{ "add", "?" },              .{ "sub", "?" },            .{ "mul", "?" },
});

/// Which (1-based) operand position carries the size.
const op_size_param = std.StaticStringMap(usize).initComptime(.{
    .{ "load", 2 }, .{ "load_num", 2 }, .{ "store", 3 }, .{ "store_num", 3 },
    .{ "call", 3 }, .{ "const", 2 },    .{ "cast", 2 },
});

/// MoarVM operand types to expression types; anything missing is 'reg'.
const moar_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "num32", "num" }, .{ "num64", "num" }, .{ "`1", "?" },
});

// --- Environments, macros, compiler state ---

/// A `let:` name maps to its definition node; an opcode operand name ("$0",
/// "$1", ...) maps to its expression type.
pub const EnvEntry = union(enum) { ty: []const u8, node: *Node };
pub const Env = std.StringHashMap(EnvEntry);

pub const Macro = struct {
    params: []const []const u8, // atoms such as ",object"
    body: *Node,
    ty: []const u8,
};
pub const Macros = std.StringHashMap(Macro);

/// Constant table shared by every template: index = first-seen order.
pub const Constants = std.StringArrayHashMapUnmanaged(void);

const Code = struct { tag: u8, value: []const u8 };

pub const Compiled = struct { root: u32, template: []const []const u8, desc: []const u8 };

/// How `include:` files are read; main reads from the cwd, tests supply text.
pub const Includes = struct {
    context: ?*const anyopaque = null,
    read: *const fn (context: ?*const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]const u8 = readNothing,

    fn readNothing(context: ?*const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        _ = context;
        _ = gpa;
        _ = path;
        return error.FileNotFound;
    }
};

pub const Ctx = struct {
    includes: Includes = .{},
    gpa: std.mem.Allocator,
    ops: *const expr_ops.ExprOps,
    ol: *const oplist.Oplist,
    constants: *Constants,
};

const Compiler = struct {
    ctx: Ctx,
    opcode: []const u8,
    operands: *const Env,
    expr_index: std.AutoHashMap(*Node, u32),
    tmpl: std.ArrayList([]const u8) = .empty,
    desc: std.ArrayList(u8) = .empty,
};

pub const Info = struct { idx: usize, desc: []const u8, root: u32, len: usize, flags: u8 };

pub const ParsedFile = struct {
    templates: std.ArrayList([]const u8) = .empty,
    info: std.StringHashMap(Info),
};

// --- Helpers ---

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn allWordChars(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isWordChar(c)) return false;
    return true;
}

/// Perl's looks_like_number for the inputs that occur here: an optional sign,
/// decimal digits, optional fraction and exponent.
pub fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) return false;
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

fn upper(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.ascii.allocUpperString(gpa, s);
}

fn prefixed(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{ PREFIX, try upper(gpa, s) });
}

fn fmtInt(gpa: std.mem.Allocator, n: anytype) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{n});
}

/// `\$(\w+)` anywhere in an atom: returns the name after the `$`, or null.
fn dollarName(atom: []const u8) ?[]const u8 {
    const d = std.mem.indexOfScalar(u8, atom, '$') orelse return null;
    var end = d + 1;
    while (end < atom.len and isWordChar(atom[end])) end += 1;
    if (end == d + 1) return null;
    return atom[d + 1 .. end];
}

/// Operand environment of an opcode: "$0", "$1", ... mapped to expression
/// types (num32/num64 -> num, `1 -> ?, anything else -> reg). inc_i/dec_i
/// and inc_u/dec_u list one operand but templates reference $0 and $1, so
/// their type list is doubled (the Perl tool's "hack").
pub fn moarOperands(gpa: std.mem.Allocator, op: *const oplist.Op) !Env {
    var env = Env.init(gpa);
    const n = op.operands.len;
    const doubled = isIncDec(op.name, "iu");
    const total = if (doubled) n * 2 else n;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const ty = op.operands[i % n].ty;
        const key = try std.fmt.allocPrint(gpa, "${d}", .{i});
        try env.put(key, .{ .ty = moar_types.get(ty) orelse "reg" });
    }
    return env;
}

/// `^(inc|dec)_[<suffixes>]$`
fn isIncDec(name: []const u8, suffixes: []const u8) bool {
    if (name.len != 5) return false;
    if (!(std.mem.startsWith(u8, name, "inc_") or std.mem.startsWith(u8, name, "dec_"))) return false;
    return std.mem.indexOfScalar(u8, suffixes, name[4]) != null;
}

/// Replaces `let:`/`letv:` statements by do/dov, binding each declared name to
/// its definition node so every use shares that node (identity is what the
/// compiler later uses for reuse). Perl passes %env by value, so a nested
/// scope sees outer names but cannot leak its own.
pub fn linkDeclarations(gpa: std.mem.Allocator, expr: *Node, env_in: *const Env) Error!void {
    if (!expr.isList() or expr.items.items.len == 0) return;
    const op = expr.head();
    if (std.mem.indexOf(u8, op, "let:") != null or std.mem.indexOf(u8, op, "letv:") != null) {
        if (expr.items.items.len < 2 or !expr.items.items[1].isList()) return error.MalformedStatement;
        var env = env_in.clone() catch return error.OutOfMemory;
        const declarations = expr.items.items[1];
        const expressions = expr.items.items[2..];
        var definitions: std.ArrayList(*Node) = .empty;
        for (declarations.items.items) |declaration| {
            if (!declaration.isList() or declaration.items.items.len < 2) return error.MalformedStatement; // Perl ignores extra elements
            const name = declaration.items.items[0].atom;
            const definition = declaration.items.items[1];
            try linkDeclarations(gpa, definition, &env);
            _ = try checkType(try exprType(gpa, definition, &env), "?", op);
            try env.put(name, .{ .node = definition });
            const discard = try Node.newList(gpa);
            try discard.items.append(gpa, try Node.newAtom(gpa, "discard"));
            try discard.items.append(gpa, definition);
            try definitions.append(gpa, discard);
        }
        for (expressions) |e| try linkDeclarations(gpa, e, &env);
        var rebuilt: std.ArrayList(*Node) = .empty;
        try rebuilt.append(gpa, try Node.newAtom(gpa, if (eql(op, "letv:")) "dov" else "do"));
        try rebuilt.appendSlice(gpa, definitions.items);
        try rebuilt.appendSlice(gpa, expressions);
        expr.items = rebuilt;
        return;
    }
    for (expr.items.items[1..]) |*slot| {
        const operand = slot.*;
        if (operand.isList()) {
            if (operand.items.items.len > 0) try linkDeclarations(gpa, operand, env_in);
        } else if (dollarName(operand.atom)) |name| {
            if (looksLikeNumber(name)) continue;
            const entry = env_in.get(operand.atom) orelse return error.InvalidName;
            switch (entry) {
                .node => |n| slot.* = n,
                .ty => return error.InvalidName,
            }
        }
    }
}

/// Expands `^name` applications bottom-up. The expanded instance replaces the
/// application's contents in place, so the application node keeps its identity.
pub fn applyMacros(gpa: std.mem.Allocator, expr: *Node, macros: *const Macros) Error!void {
    if (!expr.isList() or expr.items.items.len == 0) return;
    for (expr.items.items[1..]) |operand| {
        if (operand.isList()) try applyMacros(gpa, operand, macros);
    }
    const op = expr.head();
    if (op.len == 0 or op[0] != '^') return;
    const macro = macros.get(op) orelse return error.UndefinedMacro;
    if (expr.items.items.len - 1 != macro.params.len) return error.MacroArity;
    var bind = std.StringHashMap(*Node).init(gpa);
    for (macro.params, expr.items.items[1..]) |param, arg| try bind.put(param, arg);
    var sub = std.AutoHashMap(*Node, *Node).init(gpa);
    const instance = try expandMacro(gpa, macro.body, &bind, &sub);
    expr.items = .empty;
    try expr.items.appendSlice(gpa, instance.items.items);
}

/// Copies a macro body with `,param` atoms replaced by their bindings. A
/// source sub-list is expanded once and that instance is reused wherever the
/// source appears, preserving the links made by linkDeclarations.
fn expandMacro(gpa: std.mem.Allocator, macro: *const Node, bind: *const std.StringHashMap(*Node), sub: *std.AutoHashMap(*Node, *Node)) Error!*Node {
    const result = try Node.newList(gpa);
    for (macro.items.items) |element| {
        if (element.isList()) {
            if (sub.get(element)) |instance| {
                try result.items.append(gpa, instance);
            } else {
                const instance = try expandMacro(gpa, element, bind, sub);
                try sub.put(element, instance);
                try result.items.append(gpa, instance);
            }
        } else if (element.atom.len > 0 and element.atom[0] == ',') {
            try result.items.append(gpa, bind.get(element.atom) orelse return error.UnmatchedSubstitution);
        } else {
            try result.items.append(gpa, element);
        }
    }
    return result;
}

/// Expression type: 'reg', 'num', 'flag', 'void', 'arglist', 'carg' or '?'
/// (polymorphic). A bare atom must be `$name` (looked up) or `\$name` (reg);
/// any other atom is not an expression (Perl dies with "Can't use string as
/// an ARRAY ref").
pub fn exprType(gpa: std.mem.Allocator, expr: *const Node, env: *const Env) Error![]const u8 {
    if (expr.kind == .atom) {
        var s = expr.atom;
        var is_ref = false;
        if (s.len > 0 and s[0] == '\\') {
            is_ref = true;
            s = s[1..];
        }
        if (s.len >= 2 and s[0] == '$' and allWordChars(s[1..])) {
            if (is_ref) return "reg";
            const entry = env.get(s) orelse return error.NotDeclared;
            return switch (entry) {
                .ty => |t| t,
                .node => error.NotDeclared,
            };
        }
        return error.ExpectedExpression;
    }
    if (expr.items.items.len == 0 or expr.items.items[0].isList()) return "reg";
    const op = expr.head();
    if ((op.len > 0 and op[0] == '&') or (op.len > 0 and op[op.len - 1] == ':')) return error.ExpectedOperator;
    const operands = expr.items.items[1..];
    if (std.mem.indexOf(u8, op, "if") != null) {
        if (operands.len < 3) return error.TypeMismatch;
        const flag = try exprType(gpa, operands[0], env);
        const left = try exprType(gpa, operands[1], env);
        const right = try exprType(gpa, operands[2], env);
        _ = try checkType(flag, "flag", op);
        return if (eql(left, "?")) checkType(right, left, op) else checkType(left, right, op);
    }
    if (eql(op, "do")) {
        if (operands.len == 0) return error.MalformedStatement;
        return exprType(gpa, operands[operands.len - 1], env);
    }
    if (eql(op, "copy")) {
        if (operands.len == 0) return error.MalformedStatement;
        return exprType(gpa, operands[0], env);
    }
    if (op.len > 1 and op[0] == '^' and isWordChar(op[1])) return "?";
    const ty = operator_types.get(op) orelse "reg";
    if (eql(ty, "?")) {
        if (operands.len == 0) return error.MalformedStatement;
        const subtype = try exprType(gpa, operands[0], env);
        for (operands[1..]) |o| _ = try checkType(try exprType(gpa, o, env), subtype, op);
        return subtype;
    }
    return ty;
}

/// Returns `got` when it satisfies `want`: equal, or `want` is '?' and `got`
/// contains "reg" or "num".
pub fn checkType(got: []const u8, want: []const u8, why: []const u8) Error![]const u8 {
    if (eql(got, want)) return got;
    if (eql(want, "?") and (std.mem.indexOf(u8, got, "reg") != null or std.mem.indexOf(u8, got, "num") != null)) return got;
    std.debug.print("{s}: Got {s} wanted {s}\n", .{ why, got, want });
    return error.TypeMismatch;
}

pub fn compileTemplate(ctx: Ctx, expr: *Node, opcode: []const u8, operands: *const Env) Error!Compiled {
    var c: Compiler = .{
        .ctx = ctx,
        .opcode = opcode,
        .operands = operands,
        .expr_index = std.AutoHashMap(*Node, u32).init(ctx.gpa),
    };
    const root = try compileExpression(&c, expr);
    return .{ .root = root, .template = c.tmpl.items, .desc = c.desc.items };
}

fn compileExpression(c: *Compiler, expr: *Node) Error!u32 {
    if (c.expr_index.get(expr)) |idx| return idx;
    if (!expr.isList() or expr.items.items.len == 0) return error.ExpectedExpression;
    const op = expr.head();
    if (op.len > 0 and op[0] == '&') return error.ExpectedExpression;
    const info = c.ctx.ops.get(op) orelse return error.UnknownOperator;
    const operands = expr.items.items[1..];
    const num_operands: usize = if (info.num_operands < 0) operands.len else @intCast(info.num_operands);
    const num_params: usize = @intCast(info.num_params);
    if (num_operands + num_params != operands.len) return error.OperandCount;

    var code: std.ArrayList(Code) = .empty;
    const gpa = c.ctx.gpa;

    // large constants are treated specially
    if (eql(op, "const_ptr") or eql(op, "const_large")) {
        if (operands.len == 0) return error.OperandCount;
        const const_op = try compileOperator(c, op, 0);
        try code.appendSlice(gpa, &const_op);
        try code.append(gpa, try compileConstant(c, operands[0]));
        // Perl pushes the size text as written (no MVM_JIT_ prefix for barewords).
        if (operands.len > 1) try code.append(gpa, .{
            .tag = '.',
            .value = if (operands[1].isList()) try cmacroText(c, operands[1]) else operands[1].atom,
        });
        return emit(c, code.items);
    }

    // match up types
    var types: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, operand_types.get(op) orelse "reg", ',');
    while (it.next()) |t| try types.append(gpa, t);
    if (types.items.len < num_operands) {
        if (types.items.len == 1) {
            const only = types.items[0];
            while (types.items.len < num_operands) try types.append(gpa, only);
        } else if (types.items.len == 2) {
            const first = types.items[0];
            const last = types.items[1];
            types.clearRetainingCapacity();
            var k: usize = 0;
            while (k + 1 < num_operands) : (k += 1) try types.append(gpa, first);
            try types.append(gpa, last);
        } else return error.CannotMatchTypes;
    }

    const op_code = try compileOperator(c, op, num_operands);
    try code.appendSlice(gpa, &op_code);
    var i: usize = 0;
    while (i < num_operands) : (i += 1) {
        _ = try checkType(try exprType(gpa, operands[i], c.operands), types.items[i], op);
        try code.append(gpa, try compileOperand(c, operands[i]));
    }
    if (op_size_param.get(op)) |param| {
        const size = operands[param - 1];
        const ok = (size.isList() and size.head().len > 0 and size.head()[0] == '&') or
            (size.kind == .atom and (looksLikeNumber(size.atom) or std.mem.endsWith(u8, size.atom, "_sz")));
        if (!ok) return error.ExpectedSizeParameter;
    }
    while (i < operands.len) : (i += 1) try code.append(gpa, try compileParameter(c, operands[i]));

    const node = try emit(c, code.items);
    try c.expr_index.put(expr, node);
    return node;
}

fn emit(c: *Compiler, code: []const Code) Error!u32 {
    const node: u32 = @intCast(c.tmpl.items.len);
    for (code) |item| {
        try c.desc.append(c.ctx.gpa, item.tag);
        try c.tmpl.append(c.ctx.gpa, item.value);
    }
    return node;
}

fn compileOperator(c: *Compiler, op: []const u8, num_operands: usize) Error![2]Code {
    if (c.ctx.ops.get(op) == null) return error.UnknownOperator;
    return .{
        .{ .tag = 'n', .value = try prefixed(c.ctx.gpa, op) },
        .{ .tag = 's', .value = try fmtInt(c.ctx.gpa, num_operands) },
    };
}

fn compileConstant(c: *Compiler, value: *Node) Error!Code {
    const text = if (value.isList()) try cmacroText(c, value) else value.atom;
    const gop = try c.ctx.constants.getOrPut(c.ctx.gpa, text);
    return .{ .tag = 'c', .value = try fmtInt(c.ctx.gpa, gop.index) };
}

fn compileOperand(c: *Compiler, expr: *Node) Error!Code {
    if (expr.isList()) return .{ .tag = 'l', .value = try fmtInt(c.ctx.gpa, try compileExpression(c, expr)) };
    return compileReference(c, expr.atom);
}

/// `$N` / `\$N` operand references. Write operands must be referenced with a
/// backslash, read operands must not. inc_i/dec_i may use $0 and $1 freely.
fn compileReference(c: *Compiler, atom: []const u8) Error!Code {
    var s = atom;
    var is_ref = false;
    if (s.len > 0 and s[0] == '\\') {
        is_ref = true;
        s = s[1..];
    }
    if (s.len < 2 or s[0] != '$') return error.ExpectedReference;
    var end: usize = 1;
    while (end < s.len and isWordChar(s[end])) end += 1;
    if (end == 1) return error.ExpectedReference;
    const name = s[1..end];
    if (!looksLikeNumber(name)) return error.UndefinedNamedReference;
    const idx = std.fmt.parseInt(i64, name, 10) catch return error.InvalidOperandReference;
    if (isIncDec(c.opcode, "i") and idx <= 1) return .{ .tag = 'i', .value = name };
    const op = c.ctx.ol.get(c.opcode) orelse return error.UnknownOpcode;
    if (idx < 0 or idx >= op.operands.len) return error.InvalidOperandReference;
    const dir = op.operands[@intCast(idx)].dir;
    if (eql(dir, "w")) {
        if (!is_ref) return error.RequireReference;
    } else if (is_ref) return error.NotAReference;
    return .{ .tag = 'i', .value = name };
}

fn compileParameter(c: *Compiler, expr: *Node) Error!Code {
    return .{ .tag = '.', .value = try parameterText(c, expr) };
}

fn parameterText(c: *Compiler, expr: *Node) Error![]const u8 {
    if (expr.isList()) return cmacroText(c, expr);
    if (looksLikeNumber(expr.atom)) return expr.atom;
    return prefixed(c.ctx.gpa, expr.atom);
}

/// `(&name p1 p2)` -> "name(p1, p2)"
fn cmacroText(c: *Compiler, expr: *Node) Error![]const u8 {
    const name = expr.head();
    if (name.len < 2 or name[0] != '&') return error.ExpectedMacroExpression;
    var end: usize = 1;
    while (end < name.len and isWordChar(name[end])) end += 1;
    var out: std.Io.Writer.Allocating = .init(c.ctx.gpa);
    out.writer.print("{s}(", .{name[1..end]}) catch return error.OutOfMemory;
    for (expr.items.items[1..], 0..) |p, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(if (p.isList()) "ARRAY" else p.atom) catch return error.OutOfMemory;
    }
    out.writer.writeByte(')') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Parses one .expr file (statements macro:, template:, include:). Macros and
/// the include set are shared across includes; templates and info are merged
/// into the including file with their indices shifted.
pub fn parseFile(ctx: Ctx, text: []const u8, macros: *Macros, seen: *std.StringHashMap(void)) !ParsedFile {
    const gpa = ctx.gpa;
    var result: ParsedFile = .{ .info = std.StringHashMap(Info).init(gpa) };
    var parser = sexpr.Parser.init(gpa, text);
    while (try parser.next()) |tree| {
        if (tree.items.items.len == 0) return error.MalformedStatement;
        const keyword = tree.items.items[0].atom;
        const rest = tree.items.items[1..];
        if (eql(keyword, "macro:")) {
            if (rest.len != 3 or !rest[1].isList()) return error.MalformedStatement;
            const name = rest[0].atom;
            if (macros.contains(name)) return error.MacroRedeclared;
            const body = rest[2];
            var empty = Env.init(gpa);
            try linkDeclarations(gpa, body, &empty);
            try applyMacros(gpa, body, macros);
            const ty = try exprType(gpa, body, &empty);
            var params: std.ArrayList([]const u8) = .empty;
            for (rest[1].items.items) |p| try params.append(gpa, p.atom);
            try macros.put(name, .{ .params = params.items, .body = body, .ty = ty });
        } else if (eql(keyword, "template:")) {
            if (rest.len != 2) return error.MalformedStatement;
            var opcode = rest[0].atom;
            const template = rest[1];
            var destructive: u8 = 0;
            if (std.mem.endsWith(u8, opcode, "!")) {
                destructive = 1;
                opcode = opcode[0 .. opcode.len - 1];
            }
            const op = ctx.ol.get(opcode) orelse {
                std.debug.print("Opcode '{s}' unknown\n", .{opcode});
                return error.UnknownOpcode;
            };
            if (result.info.contains(opcode)) return error.OpcodeRedefined;
            const output = op.outputOperand();
            if (destructive == 1 and output == null) return error.NoWriteOperand;
            var operands = try moarOperands(gpa, op);
            try linkDeclarations(gpa, template, &operands);
            try applyMacros(gpa, template, macros);
            const expr_ty = try exprType(gpa, template, &operands);
            const output_type: []const u8 = if (destructive == 1 or output == null) "void" else (moar_types.get(output.?) orelse "reg");
            _ = try checkType(expr_ty, output_type, opcode);
            const compiled = try compileTemplate(ctx, template, opcode, &operands);
            try result.info.put(opcode, .{
                .idx = result.templates.items.len,
                .desc = compiled.desc,
                .root = compiled.root,
                .len = compiled.desc.len,
                .flags = destructive,
            });
            try result.templates.appendSlice(gpa, compiled.template);
        } else if (eql(keyword, "include:")) {
            if (rest.len != 1) return error.MalformedStatement;
            const file = std.mem.trim(u8, rest[0].atom, "\"");
            if (seen.contains(file)) {
                std.debug.print("{s} already included\n", .{file});
                continue;
            }
            try seen.put(file, {});
            const inc_text = ctx.includes.read(ctx.includes.context, gpa, file) catch |err| {
                std.debug.print("cannot read include '{s}': {t}\n", .{ file, err });
                return err;
            };
            var inc = try parseFile(ctx, inc_text, macros, seen);
            // Perl's `$info{keys %$inc_info} = values %$inc_info;` (line 554 of
            // expr-template-compiler.pl) is a bug: both sides are evaluated in
            // scalar context, so it stores one junk key and drops the included
            // templates' info. This does the intended per-entry merge (index
            // shift, redeclaration check). macro.expr, the only include in the
            // tree, has no templates, so the output is unaffected.
            var it = inc.info.iterator();
            while (it.next()) |entry| {
                if (result.info.contains(entry.key_ptr.*)) return error.TemplateRedeclaredInInclude;
                var info = entry.value_ptr.*;
                info.idx += result.templates.items.len;
                try result.info.put(entry.key_ptr.*, info);
            }
            try result.templates.appendSlice(gpa, inc.templates.items);
        } else {
            std.debug.print("I don't know what to do with '{s}'\n", .{keyword});
            return error.UnknownKeyword;
        }
    }
    return result;
}

fn writeTemplatesArray(w: *std.Io.Writer, templates: []const []const u8) !void {
    try w.writeAll("static const MVMint32 MVM_jit_expr_templates[] = {\n    ");
    var i: usize = 0;
    for (templates) |t| {
        i += t.len + 2;
        if (i > 75) {
            try w.writeAll("\n    ");
            i = t.len + 2;
        }
        try w.print("{s},", .{t});
    }
    try w.writeAll("\n};\n");
}

pub fn writeOutput(w: *std.Io.Writer, parsed: *const ParsedFile, ol: *const oplist.Oplist, constants: *const Constants) !void {
    try w.writeAll("/* FILE AUTOGENERATED BY tools/zig/expr_template_compiler.zig. DO NOT EDIT.\n * Defines tables for expression templates. */\n");
    try writeTemplatesArray(w, parsed.templates.items);
    try w.writeAll("static const MVMJitExprTemplate MVM_jit_expr_template_info[] = {\n");
    for (ol.ops) |op| {
        if (parsed.info.get(op.name)) |td| {
            try w.print("    {{ MVM_jit_expr_templates + {d}, \"{s}\", {d}, {d}, {d} }},\n", .{ td.idx, td.desc, td.len, td.root, td.flags });
        } else {
            try w.writeAll("    { NULL, NULL, -1, 0, 0 },\n");
        }
    }
    try w.writeAll("};\n");
    try w.writeAll("static const void* MVM_jit_expr_template_constants[] = {\n");
    for (constants.keys()) |k| try w.print("    {s},\n", .{k});
    try w.writeAll("};\n");
    try w.print(
        \\static const MVMJitExprTemplate * MVM_jit_get_template_for_opcode(MVMuint16 opcode) {{
        \\    if (opcode >= {d}) return NULL;
        \\    if (MVM_jit_expr_template_info[opcode].len < 0) return NULL;
        \\    return &MVM_jit_expr_template_info[opcode];
        \\}}
        \\
    , .{ol.ops.len});
}

fn readFromCwd(context: ?*const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
    const io: *const std.Io = @ptrCast(@alignCast(context.?));
    return std.Io.Dir.cwd().readFileAlloc(io.*, path, gpa, .unlimited);
}

fn usageExit() noreturn {
    std.debug.print("usage: expr_template_compiler --oplist src/core/oplist --expr-ops src/jit/expr_ops.h -o out.h input.expr (run from the repository root)\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var oplist_path: ?[]const u8 = null;
    var expr_ops_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--oplist")) {
            i += 1;
            if (i >= args.len) usageExit();
            oplist_path = args[i];
        } else if (eql(a, "--expr-ops")) {
            i += 1;
            if (i >= args.len) usageExit();
            expr_ops_path = args[i];
        } else if (eql(a, "-o") or eql(a, "--output")) {
            i += 1;
            if (i >= args.len) usageExit();
            output_path = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown option {s}\n", .{a});
            std.process.exit(2);
        } else input_path = a;
    }
    const in_path = input_path orelse usageExit();
    const cwd = std.Io.Dir.cwd();
    const ol = try arena.create(oplist.Oplist);
    ol.* = try oplist.parse(arena, try cwd.readFileAlloc(io, oplist_path orelse "src/core/oplist", arena, .unlimited));
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, try cwd.readFileAlloc(io, expr_ops_path orelse "src/jit/expr_ops.h", arena, .unlimited));
    var constants: Constants = .empty;
    const ctx: Ctx = .{ .includes = .{ .context = &io, .read = readFromCwd }, .gpa = arena, .ops = eo, .ol = ol, .constants = &constants };
    var macros = Macros.init(arena);
    var seen = std.StringHashMap(void).init(arena);
    const text = try cwd.readFileAlloc(io, in_path, arena, .unlimited);
    const parsed = parseFile(ctx, text, &macros, &seen) catch |err| {
        std.debug.print("expr_template_compiler: {s}: {t}\n", .{ in_path, err });
        std.process.exit(1);
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeOutput(&out.writer, &parsed, ol, &constants);
    if (output_path) |p| {
        try cwd.writeFile(io, .{ .sub_path = p, .data = out.written() });
    } else {
        var buf: [4096]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), io, &buf);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
    }
}

// --- Tests ---

const test_oplist =
    \\no_op
    \\const_i64           w(int64) int64 :pure :confprog
    \\set                 w(`1) r(`1) :pure :confprog
    \\add_i               w(int64) r(int64) r(int64) :pure :confprog
    \\inc_i               w(int64)
    \\getcode             w(obj) coderef :pure
;

// One entry per line, as in the real expr_ops.h (the parser reads one per line).
const test_expr_ops =
    \\#define MVM_JIT_EXPR_OPS(_) \
    \\    _(NOOP, 0, 0), \
    \\    _(COPY, 1, 0), \
    \\    _(LOAD, 1, 1), \
    \\    _(STORE, 2, 1), \
    \\    _(ADDR, 1, 1), \
    \\    _(IDX, 2, 1), \
    \\    _(CONST, 0, 2), \
    \\    _(CONST_PTR, 0, 1), \
    \\    _(NZ, 1, 0), \
    \\    _(DISCARD, 1, 0), \
    \\    _(ADD, 2, 0), \
    \\    _(DO, -1, 0), \
    \\    _(DOV, -1, 0), \
    \\    _(IF, 3, 0), \
    \\    _(CALLV, 2, 0), \
    \\    _(ARGLIST, -1, 0), \
    \\    _(CARG, 1, 1), \
    \\    _(TC, 0, 0), \
    \\    _(CU, 0, 0), \
    \\    _(MAX_NODES, 0, 0)
;

fn testCtx(arena: std.mem.Allocator, constants: *Constants) !Ctx {
    const ol = try arena.create(oplist.Oplist);
    ol.* = try oplist.parse(arena, test_oplist);
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, test_expr_ops);
    return .{ .gpa = arena, .ops = eo, .ol = ol, .constants = constants };
}

fn parseOne(arena: std.mem.Allocator, src: []const u8) !*Node {
    var p = sexpr.Parser.init(arena, src);
    return (try p.next()).?;
}

test "compile: (copy $1) for const_i64 gives the real file's first row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants: Constants = .empty;
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("const_i64").?);
    const tmpl = try parseOne(a, "(copy $1)");
    const c = try compileTemplate(ctx, tmpl, "const_i64", &env);
    try std.testing.expectEqualStrings("nsi", c.desc);
    try std.testing.expectEqual(@as(u32, 0), c.root);
    try std.testing.expectEqual(@as(usize, 3), c.template.len);
    try std.testing.expectEqualStrings("MVM_JIT_COPY", c.template[0]);
    try std.testing.expectEqualStrings("1", c.template[1]);
    try std.testing.expectEqualStrings("1", c.template[2]);
}

test "compile: nested operands emit children first; constants are numbered; parameters are prefixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants: Constants = .empty;
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("getcode").?);
    // (load (idx (load (addr (cu) (&offsetof MVMCompUnit body.strings)) ptr_sz) $1 ptr_sz) ptr_sz)
    const tmpl = try parseOne(a, "(load (idx (load (addr (cu) (&offsetof MVMCompUnit body.strings)) ptr_sz) $1 ptr_sz) ptr_sz)");
    const c = try compileTemplate(ctx, tmpl, "getcode", &env);
    // cu:0 addr:2 load:6 idx:10 load:15  -> desc per node: ns, nsl., nsl., nsli. (size is a parameter), nsl.
    try std.testing.expectEqualStrings("nsnsl.nsl.nsli.nsl.", c.desc);
    try std.testing.expectEqual(@as(u32, 15), c.root);
    try std.testing.expectEqualStrings("MVM_JIT_CU", c.template[0]);
    try std.testing.expectEqualStrings("0", c.template[1]);
    try std.testing.expectEqualStrings("MVM_JIT_ADDR", c.template[2]);
    try std.testing.expectEqualStrings("0", c.template[4]); // 'l' -> node 0
    try std.testing.expectEqualStrings("offsetof(MVMCompUnit, body.strings)", c.template[5]);
    try std.testing.expectEqualStrings("MVM_JIT_PTR_SZ", c.template[9]);
    try std.testing.expectEqualStrings("1", c.template[13]); // 'i' -> $1
}

test "compile: const_ptr records a constant and writes 0 operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants: Constants = .empty;
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("no_op").?);
    const tmpl = try parseOne(a, "(callv (const_ptr &MVM_foo) (arglist (carg (tc) ptr)))");
    const c = try compileTemplate(ctx, tmpl, "no_op", &env);
    try std.testing.expectEqualStrings("nscnsnsl.nslnsll", c.desc);
    try std.testing.expectEqualStrings("MVM_JIT_CONST_PTR", c.template[0]);
    try std.testing.expectEqualStrings("0", c.template[1]);
    try std.testing.expectEqualStrings("0", c.template[2]); // constant number 0
    try std.testing.expectEqual(@as(usize, 1), constants.count());
    try std.testing.expectEqualStrings("&MVM_foo", constants.keys()[0]);
}

test "compile: errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants: Constants = .empty;
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("add_i").?);
    try std.testing.expectError(error.RequireReference, compileTemplate(ctx, try parseOne(a, "(copy $0)"), "add_i", &env));
    try std.testing.expectError(error.NotAReference, compileTemplate(ctx, try parseOne(a, "(copy \\$1)"), "add_i", &env));
    try std.testing.expectError(error.UnknownOperator, compileTemplate(ctx, try parseOne(a, "(bogus $1)"), "add_i", &env));
    try std.testing.expectError(error.OperandCount, compileTemplate(ctx, try parseOne(a, "(add $1)"), "add_i", &env));
    try std.testing.expectError(error.ExpectedSizeParameter, compileTemplate(ctx, try parseOne(a, "(load $1 nope)"), "add_i", &env));
}

test "link: single let shares the definition node (Perl test 1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($foo (copy $1))) (load $foo 8))");
    // The Perl tool's own --test passes no environment and therefore dies on
    // `(copy $1)` ("$1 is not declared"); real templates always have operand
    // types in scope, so provide $1 here.
    var env = Env.init(a);
    try env.put("$1", .{ .ty = "reg" });
    try linkDeclarations(a, expr, &env);
    // (do (discard X) (load X 8))
    try std.testing.expectEqualStrings("do", expr.head());
    try std.testing.expect(expr.items.items[1].items.items[1] == expr.items.items[2].items.items[1]);
}

test "link: nested lets, left-to-right (Perl test 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($foo (const 1 1)) ($bar (add $foo $foo))) (let: (($foo (sub $bar (const 1 1)))) (copy $foo)))");
    var env = Env.init(a);
    try linkDeclarations(a, expr, &env);
    const it = expr.items.items;
    // forward declaration: outer $foo used twice inside $bar's definition
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[1].items.items[1]);
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[1].items.items[2]);
    // inner declaration: do -> discard -> sub -> $bar, and do -> discard -> sub == do -> copy -> $foo
    try std.testing.expect(it[2].items.items[1] == it[3].items.items[1].items.items[1].items.items[1]);
    try std.testing.expect(it[3].items.items[1].items.items[1] == it[3].items.items[2].items.items[1]);
}

test "macros: expansion shares instances and keeps links (Perl test 3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($obj (load $1))) (^foo $obj))");
    const body = try parseOne(a, "(let: (($obj (addr ,foo 8))) (add ,foo $obj))");
    var empty = Env.init(a);
    try linkDeclarations(a, body, &empty);
    try linkDeclarations(a, expr, &empty);
    var macros = Macros.init(a);
    try macros.put("^foo", .{ .params = &.{",foo"}, .body = body, .ty = "?" });
    try applyMacros(a, expr, &macros);
    const it = expr.items.items;
    // outer let: the (load $1) node is the macro's ,foo argument in (add ,foo $obj)
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[2].items.items[1]);
    // macro let: (addr ...) is shared between its discard and the use in add
    try std.testing.expect(it[2].items.items[1].items.items[1] == it[2].items.items[2].items.items[2]);
    try std.testing.expectError(error.UndefinedMacro, applyMacros(a, try parseOne(a, "(^nope 1)"), &macros));
    try std.testing.expectError(error.MacroArity, applyMacros(a, try parseOne(a, "(^foo 1 2)"), &macros));
}

test "exprType: polymorphic resolution and checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    try env.put("$1", .{ .ty = "reg" });
    try env.put("$2", .{ .ty = "num" });
    try std.testing.expectEqualStrings("reg", try exprType(a, try parseOne(a, "(add $1 $1)"), &env));
    try std.testing.expectEqualStrings("num", try exprType(a, try parseOne(a, "(if (nz $1) $2 $2)"), &env));
    try std.testing.expectEqualStrings("void", try exprType(a, try parseOne(a, "(dov (discard $1))"), &env));
    try std.testing.expectEqualStrings("?", try exprType(a, try parseOne(a, "(^macro $1)"), &env));
    try std.testing.expectError(error.TypeMismatch, exprType(a, try parseOne(a, "(add $1 $2)"), &env));
    try std.testing.expectError(error.TypeMismatch, exprType(a, try parseOne(a, "(if $1 $1 $1)"), &env));
    try std.testing.expectError(error.NotDeclared, exprType(a, try parseOne(a, "(copy $9)"), &env));
    try std.testing.expectError(error.ExpectedExpression, exprType(a, try parseOne(a, "(add ,x ,x)"), &env));
}

test "output: template array wraps after 75 columns like the Perl loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var values: [7][]const u8 = undefined;
    for (&values) |*v| v.* = "MVM_JIT_COPY";
    try writeTemplatesArray(&out.writer, &values);
    try std.testing.expectEqualStrings(
        "static const MVMint32 MVM_jit_expr_templates[] = {\n" ++
            "    MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,\n" ++
            "    MVM_JIT_COPY,MVM_JIT_COPY,\n};\n",
        out.written(),
    );
}

const TestFiles = struct {
    names: []const []const u8,
    texts: []const []const u8,

    fn read(context: ?*const anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        _ = gpa;
        const self: *const TestFiles = @ptrCast(@alignCast(context.?));
        for (self.names, self.texts) |n, t| if (eql(n, path)) return t;
        return error.FileNotFound;
    }
};

test "include: templates merge with shifted indices, SEEN skips, redeclaration errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants: Constants = .empty;
    var ctx = try testCtx(a, &constants);
    const files: TestFiles = .{
        .names = &.{ "inc.expr", "dup.expr" },
        .texts = &.{
            "(template: set (copy $1))",
            "(template: const_i64 (copy $1))",
        },
    };
    ctx.includes = .{ .context = &files, .read = TestFiles.read };

    // const_i64 -> 3 template slots, set -> 3 slots (via include, shifted by 3)
    var macros = Macros.init(a);
    var seen = std.StringHashMap(void).init(a);
    const parsed = try parseFile(ctx, "(template: const_i64 (copy $1))\n(include: \"inc.expr\")\n(include: \"inc.expr\")", &macros, &seen);
    try std.testing.expectEqual(@as(usize, 6), parsed.templates.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.info.get("const_i64").?.idx);
    try std.testing.expectEqual(@as(usize, 3), parsed.info.get("set").?.idx);
    try std.testing.expectEqual(@as(usize, 1), seen.count()); // inc.expr recorded once, second include skipped

    var macros2 = Macros.init(a);
    var seen2 = std.StringHashMap(void).init(a);
    try std.testing.expectError(error.TemplateRedeclaredInInclude, parseFile(ctx, "(template: const_i64 (copy $1))\n(include: \"dup.expr\")", &macros2, &seen2));
}
