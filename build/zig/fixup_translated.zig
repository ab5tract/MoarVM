//! Post-processes `zig translate-c` output for src/moar.h.
//!
//! translate-c (0.16.0) renders `x++` on a narrow integer inside some
//! static inline functions as `@as(c_int, x) += 1;`, which is not a valid
//! assignment target. This rewrites such lines to `x += 1;`. Everything
//! else passes through unchanged.
//!
//! Usage: fixup_translated IN OUT
const std = @import("std");

fn isOp(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '&', '|', '^' => true,
        else => false,
    };
}

/// Returns the rewritten line, or null when the line needs no change.
pub fn fixLine(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const body = std.mem.trimStart(u8, line, " \t");
    const indent = line[0 .. line.len - body.len];
    if (!std.mem.startsWith(u8, body, "@as(c_")) return null;
    const comma = std.mem.indexOf(u8, body, ", ") orelse return null;
    var i = comma + 2;
    while (i + 4 < body.len) : (i += 1) {
        if (body[i] == ')' and body[i + 1] == ' ' and isOp(body[i + 2]) and body[i + 3] == '=' and body[i + 4] == ' ') {
            const expr = body[comma + 2 .. i];
            const rest = body[i + 2 ..];
            return try std.mem.concat(allocator, u8, &.{ indent, expr, " ", rest });
        }
    }
    return null;
}

pub fn fixup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (try fixLine(allocator, line)) |fixed| {
            defer allocator.free(fixed);
            try out.appendSlice(allocator, fixed);
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) std.process.fatal("usage: fixup_translated IN OUT", .{});
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, args[1], allocator, .unlimited);
    const fixed = try fixup(allocator, text);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = fixed });
}

test "fixLine rewrites the invalid compound assignments translate-c emits" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "            @as(c_int, nameds) += 1;", "            nameds += 1;" },
        .{ "        @as(c_int, i) += 1;", "        i += 1;" },
        .{ "    @as(c_int, gi.*.strands_remaining) -= 1;", "    gi.*.strands_remaining -= 1;" },
        .{ "\t@as(c_uint, x.*.y[2]) |= 4;", "\tx.*.y[2] |= 4;" },
    };
    for (cases) |case| {
        const got = (try fixLine(a, case[0])).?;
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "fixLine leaves ordinary lines alone" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, "    while (@as(c_int, i) < @as(c_int, cs.*.flag_count)) {"));
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, "    x = @as(c_int, y) + 1;"));
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, ""));
}

test "fixup preserves line structure" {
    const a = std.testing.allocator;
    const got = try fixup(a, "a\n    @as(c_int, n) += 1;\nb");
    defer a.free(got);
    try std.testing.expectEqualStrings("a\n    n += 1;\nb", got);
}
