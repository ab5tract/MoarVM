//! Parser for src/jit/expr_ops.h, a port of tools/lib/expr_ops.pm: after the
//! line containing `#define MVM_JIT_EXPR_OPS`, every `_(NAME, operands, params)`
//! entry in order, including MAX_NODES.
const std = @import("std");

pub const ExprOp = struct {
    name: []const u8,
    num_operands: i32,
    num_params: i32,
    idx: usize,
};

pub const ExprOps = struct {
    ops: []ExprOp,
    by_lower: std.StringHashMap(usize),

    /// Lookup by lower-case name (the template language uses lower case).
    pub fn get(self: *const ExprOps, lower_name: []const u8) ?*const ExprOp {
        const i = self.by_lower.get(lower_name) orelse return null;
        return &self.ops[i];
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !ExprOps {
    var ops: std.ArrayList(ExprOp) = .empty;
    var by_lower = std.StringHashMap(usize).init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_define = false;
    while (lines.next()) |line| {
        if (!seen_define) {
            if (std.mem.indexOf(u8, line, "#define MVM_JIT_EXPR_OPS") != null) seen_define = true;
            continue;
        }
        const entry = parseEntry(line) orelse continue;
        const idx = ops.items.len;
        const lower = try std.ascii.allocLowerString(gpa, entry.name);
        try by_lower.put(lower, idx);
        try ops.append(gpa, .{ .name = entry.name, .num_operands = entry.num_operands, .num_params = entry.num_params, .idx = idx });
    }
    return .{ .ops = try ops.toOwnedSlice(gpa), .by_lower = by_lower };
}

const Entry = struct { name: []const u8, num_operands: i32, num_params: i32 };

/// Finds `(\w+),\s*(-?\d+),\s*(\d+)\)` anywhere in the line.
fn parseEntry(line: []const u8) ?Entry {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, start, '(')) |open| {
        start = open + 1;
        var i = open + 1;
        const name_start = i;
        while (i < line.len and isWordChar(line[i])) i += 1;
        if (i == name_start or i >= line.len or line[i] != ',') continue;
        const name = line[name_start..i];
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const ops_start = i;
        if (i < line.len and line[i] == '-') i += 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == ops_start or i >= line.len or line[i] != ',') continue;
        const num_operands = std.fmt.parseInt(i32, line[ops_start..i], 10) catch continue;
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const params_start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == params_start or i >= line.len or line[i] != ')') continue;
        const num_params = std.fmt.parseInt(i32, line[params_start..i], 10) catch continue;
        return .{ .name = name, .num_operands = num_operands, .num_params = num_params };
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "parse: entries after the define, comments ignored, variadic kept negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const eo = try parse(arena.allocator(),
        \\/* header (NOT, 9, 9) must be ignored before the define */
        \\#define MVM_JIT_EXPR_OPS(_) \
        \\    /* invalid operator */ \
        \\    _(NOOP, 0, 0), \
        \\    _(LOAD, 1, 1),   \
        \\    _(ALL, -1, 0), \
        \\    _(MAX_NODES, 0, 0)
    );
    try std.testing.expectEqual(@as(usize, 4), eo.ops.len);
    try std.testing.expectEqualStrings("NOOP", eo.ops[0].name);
    const load = eo.get("load").?;
    try std.testing.expectEqual(@as(usize, 1), load.idx);
    try std.testing.expectEqual(@as(i32, 1), load.num_operands);
    try std.testing.expectEqual(@as(i32, 1), load.num_params);
    try std.testing.expectEqual(@as(i32, -1), eo.get("all").?.num_operands);
    try std.testing.expectEqualStrings("MAX_NODES", eo.ops[3].name);
    try std.testing.expect(eo.get("LOAD") == null);
}
