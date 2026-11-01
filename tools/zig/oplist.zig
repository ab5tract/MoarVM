//! Parser for src/core/oplist, a port of tools/lib/oplist.pm.
const std = @import("std");

pub const Operand = struct { dir: []const u8, ty: []const u8 };

pub const Op = struct {
    name: []const u8,
    attribute: ?[]const u8,
    operands: []Operand,
    adverbs: [][]const u8,

    /// Type of the first write operand, or null.
    pub fn outputOperand(op: *const Op) ?[]const u8 {
        for (op.operands) |o| if (std.mem.eql(u8, o.dir, "w")) return o.ty;
        return null;
    }
};

pub const Oplist = struct {
    ops: []Op,
    by_name: std.StringHashMap(usize),

    pub fn get(self: *const Oplist, name: []const u8) ?*const Op {
        const i = self.by_name.get(name) orelse return null;
        return &self.ops[i];
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Oplist {
    var ops: std.ArrayList(Op) = .empty;
    var by_name = std.StringHashMap(usize).init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // Perl: chomp; s/#.*$//; next unless length
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| line = line[0..hash];
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        var operands: std.ArrayList(Operand) = .empty;
        var adverbs: std.ArrayList([]const u8) = .empty;
        var attribute: ?[]const u8 = null;
        while (fields.next()) |meta| {
            if (meta.len == 2 and std.mem.indexOfScalar(u8, "-+.:*", meta[0]) != null and isWordChar(meta[1])) {
                attribute = meta; // ^[-+.:*]\w$
            } else if (meta.len >= 2 and meta[0] == ':' and allWordChars(meta[1..])) {
                try adverbs.append(gpa, meta); // ^:\w+$
            } else if (parseDirectedOperand(meta)) |o| {
                try operands.append(gpa, o); // ^([rw])l?\((.+)\)$
            } else {
                try operands.append(gpa, .{ .dir = "", .ty = meta });
            }
        }
        try by_name.put(name, ops.items.len);
        try ops.append(gpa, .{
            .name = name,
            .attribute = attribute,
            .operands = try operands.toOwnedSlice(gpa),
            .adverbs = try adverbs.toOwnedSlice(gpa),
        });
    }
    return .{ .ops = try ops.toOwnedSlice(gpa), .by_name = by_name };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn allWordChars(s: []const u8) bool {
    for (s) |c| if (!isWordChar(c)) return false;
    return true;
}

/// Matches `r(...)`, `w(...)`, `rl(...)`, `wl(...)`; returns dir "r"/"w" and the inner type.
fn parseDirectedOperand(meta: []const u8) ?Operand {
    if (meta.len < 3) return null;
    if (meta[0] != 'r' and meta[0] != 'w') return null;
    var i: usize = 1;
    if (meta[i] == 'l') i += 1;
    if (i >= meta.len or meta[i] != '(' or meta[meta.len - 1] != ')') return null;
    if (meta.len - 1 <= i + 1) return null; // (.+) needs at least one char
    return .{ .dir = meta[0..1], .ty = meta[i + 1 .. meta.len - 1] };
}

test "parse: operands, attribute, adverbs, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ol = try parse(arena.allocator(),
        \\# comment line
        \\no_op
        \\const_i64           w(int64) int64 :pure :confprog
        \\sp_guardconc     .s w(obj) r(obj) sslot uint32 :maycausedeopt
        \\getlex              w(`1) rl(`1) :pure
        \\
    );
    try std.testing.expectEqual(@as(usize, 4), ol.ops.len);
    try std.testing.expectEqualStrings("no_op", ol.ops[0].name);
    try std.testing.expectEqual(@as(usize, 0), ol.ops[0].operands.len);
    const c = ol.get("const_i64").?;
    try std.testing.expect(c.attribute == null);
    try std.testing.expectEqual(@as(usize, 2), c.operands.len);
    try std.testing.expectEqualStrings("w", c.operands[0].dir);
    try std.testing.expectEqualStrings("int64", c.operands[0].ty);
    try std.testing.expectEqualStrings("", c.operands[1].dir);
    try std.testing.expectEqualStrings("int64", c.operands[1].ty);
    try std.testing.expectEqual(@as(usize, 2), c.adverbs.len);
    try std.testing.expectEqualStrings(":confprog", c.adverbs[1]);
    const g = ol.get("sp_guardconc").?;
    try std.testing.expectEqualStrings(".s", g.attribute.?);
    try std.testing.expectEqual(@as(usize, 4), g.operands.len);
    try std.testing.expectEqualStrings("obj", g.outputOperand().?);
    const l = ol.get("getlex").?;
    try std.testing.expectEqualStrings("r", l.operands[1].dir); // "rl(`1)" is a read operand
    try std.testing.expectEqualStrings("`1", l.operands[1].ty);
    try std.testing.expect(ol.get("nope") == null);
}
