//! Configure-time reads of files under the build root (`b.root`, the
//! directory holding build.zig). Zig 0.17 exposes it as a
//! `std.Build.Cache.Path`, which has no `readFileAlloc`.
const std = @import("std");

/// The contents of `sub_path` under the build root, or null when the file
/// does not exist. Any other failure is fatal and names the path.
pub fn readRootFile(b: *std.Build, sub_path: []const u8) ?[]u8 {
    const io = b.graph.io;
    var file = b.root.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.process.fatal("cannot read {s}: {t}", .{ sub_path, err }),
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(b.allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => std.process.fatal("cannot read {s}: {t}", .{ sub_path, reader.err.? }),
        else => std.process.fatal("cannot read {s}: {t}", .{ sub_path, err }),
    };
}

/// Whether `sub_path` exists under the build root.
pub fn rootExists(b: *std.Build, sub_path: []const u8) bool {
    b.root.access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}
