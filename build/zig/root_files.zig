//! Configure-time reads of files under the build root (`b.root`, the
//! directory holding build.zig). Zig 0.17 exposes it as a
//! `std.Build.Cache.Path`, which has no `readFileAlloc`.
//!
//! Zig 0.17 caches the configure phase and re-runs build.zig only when a
//! registered input changes, so every read here registers what it read.
const std = @import("std");

/// `sub_path` as a LazyPath the configure-dependency API accepts: relative
/// to the build root, or cwd-relative when absolute (e.g. -Dnqp-stage0=/…).
fn rootLazyPath(b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(sub_path)) b.graph.cwdRelativePath(sub_path) else b.path(sub_path);
}

/// Registers whether `sub_path` exists, as the entries of its nearest
/// existing ancestor directory, so creating or deleting it (or a parent of
/// it) reconfigures. Not the path's own metadata: Zig 0.17 refuses a
/// missing path as a configure input (configuration fails with
/// FileSystemFailure), and file metadata on a directory misses the
/// configure cache on every run.
fn dependOnExistence(b: *std.Build, sub_path: []const u8) void {
    var dir = std.fs.path.dirname(sub_path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        if (b.root.access(b.graph.io, d, .{})) |_| {
            b.dependOnDirectoryContents(rootLazyPath(b, d));
            return;
        } else |_| {}
    }
    b.dependOnDirectoryContents(b.path("."));
}

/// The contents of `sub_path` under the build root, or null when the file
/// does not exist. Any other failure is fatal and names the path. Registers
/// the file's contents (or, when absent, its absence) as a configure input.
pub fn readRootFile(b: *std.Build, sub_path: []const u8) ?[]u8 {
    const io = b.graph.io;
    var file = b.root.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            dependOnExistence(b, sub_path);
            return null;
        },
        else => std.process.fatal("cannot read {s}: {t}", .{ sub_path, err }),
    };
    defer file.close(io);
    b.dependOnFileContents(rootLazyPath(b, sub_path));
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(b.allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => std.process.fatal("cannot read {s}: {t}", .{ sub_path, reader.err.? }),
        else => std.process.fatal("cannot read {s}: {t}", .{ sub_path, err }),
    };
}

/// Registers `sub_path`'s contents as a configure input when it exists, and
/// its absence otherwise.
pub fn dependOnRootFile(b: *std.Build, sub_path: []const u8) void {
    if (b.root.access(b.graph.io, sub_path, .{})) |_|
        b.dependOnFileContents(rootLazyPath(b, sub_path))
    else |_|
        dependOnExistence(b, sub_path);
}

/// Registers the entries of directory `sub_path` as a configure input when
/// it exists, and its absence otherwise.
pub fn dependOnRootDir(b: *std.Build, sub_path: []const u8) void {
    if (b.root.access(b.graph.io, sub_path, .{})) |_|
        b.dependOnDirectoryContents(rootLazyPath(b, sub_path))
    else |_|
        dependOnExistence(b, sub_path);
}

/// Whether `sub_path` (a file or a directory) exists under the build root.
/// Registers its existence as a configure input.
pub fn rootExists(b: *std.Build, sub_path: []const u8) bool {
    dependOnExistence(b, sub_path);
    b.root.access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}
