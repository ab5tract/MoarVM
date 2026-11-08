//! Build-host tool: `fill_prefix PREFIX IN OUT` copies IN to OUT with every
//! `@MOAR_PREFIX@` replaced by PREFIX. Zig 0.17 knows the install prefix
//! only when the build runs, so config.c and moar.pc are rendered at
//! configure time with the token and filled in here.
const std = @import("std");

pub const token = "@MOAR_PREFIX@";

pub fn fill(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, text, token, prefix);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) std.process.fatal("usage: fill_prefix PREFIX IN OUT", .{});
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, args[2], allocator, .unlimited);
    const filled = try fill(allocator, text, args[1]);
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = filled });
}

test "fill replaces every token and leaves other lines alone" {
    const a = std.testing.allocator;
    const got = try fill(a, "libs=-L@MOAR_PREFIX@/lib -I@MOAR_PREFIX@/include\nName: MoarVM\n", "/opt/moar");
    defer a.free(got);
    try std.testing.expectEqualStrings("libs=-L/opt/moar/lib -I/opt/moar/include\nName: MoarVM\n", got);
}
