//! Build-host tool: `fill_prefix PREFIX IN OUT` copies IN to OUT with every
//! `@MOAR_PREFIX@` replaced by PREFIX. Zig 0.17 knows the install prefix
//! only when the build runs, so config.c and moar.pc are rendered at
//! configure time with the token and filled in here.
const std = @import("std");

pub const token = "@MOAR_PREFIX@";

pub const FillError = error{ NoToken, UnsafePrefix } || std.mem.Allocator.Error;

/// `text` with every token replaced by `prefix`. A text without the token
/// is an error: a template that stopped using it must not bake the token
/// into the binary. A prefix with `"`, `\` or a newline is rejected: 0.16
/// C-escaped the prefix, rejecting instead keeps config.c and moar.pc on
/// one code path that never emits different C.
pub fn fill(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) FillError![]u8 {
    if (std.mem.findAny(u8, prefix, "\"\\\n") != null) return error.UnsafePrefix;
    if (std.mem.find(u8, text, token) == null) return error.NoToken;
    return std.mem.replaceOwned(u8, allocator, text, token, prefix);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) std.process.fatal("usage: fill_prefix PREFIX IN OUT", .{});
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, args[2], allocator, .unlimited);
    const filled = fill(allocator, text, args[1]) catch |err| switch (err) {
        error.NoToken => std.process.fatal("{s} does not contain {s}", .{ args[2], token }),
        error.UnsafePrefix => std.process.fatal("install prefix '{s}' contains '\"', '\\' or a newline, which config.c cannot hold unescaped", .{args[1]}),
        error.OutOfMemory => |e| return e,
    };
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = filled });
}

test "fill replaces every token and leaves other lines alone" {
    const a = std.testing.allocator;
    const got = try fill(a, "libs=-L@MOAR_PREFIX@/lib -I@MOAR_PREFIX@/include\nName: MoarVM\n", "/opt/moar");
    defer a.free(got);
    try std.testing.expectEqualStrings("libs=-L/opt/moar/lib -I/opt/moar/include\nName: MoarVM\n", got);
}

test "fill rejects a text without the token" {
    try std.testing.expectError(error.NoToken, fill(std.testing.allocator, "Name: MoarVM\n", "/opt/moar"));
}

test "fill rejects a prefix with a quote, backslash or newline" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "/opt/mo\"ar", "/opt/mo\\ar", "/opt/mo\nar" }) |prefix| {
        try std.testing.expectError(error.UnsafePrefix, fill(a, "prefix=@MOAR_PREFIX@\n", prefix));
    }
}
