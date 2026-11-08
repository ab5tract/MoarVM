//! MoarVM version string, mirroring Configure.pl.
const std = @import("std");
const root_files = @import("root_files.zig");

pub const Version = struct {
    full: []const u8,
    major: []const u8,
    minor: []const u8,
    patch: []const u8,
};

pub fn parse(full: []const u8) Version {
    var v: Version = .{ .full = full, .major = "0", .minor = "0", .patch = "0" };

    const major_end = digitsEnd(full, 0);
    if (major_end == 0) return v;
    v.major = full[0..major_end];

    if (major_end >= full.len or full[major_end] != '.') return v;
    const minor_end = digitsEnd(full, major_end + 1);
    if (minor_end == major_end + 1) return v;
    v.minor = full[major_end + 1 .. minor_end];

    if (minor_end >= full.len or full[minor_end] != '-') return v;
    const patch_end = digitsEnd(full, minor_end + 1);
    if (patch_end == minor_end + 1) return v;
    v.patch = full[minor_end + 1 .. patch_end];

    return v;
}

fn digitsEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i;
}

/// VERSION file, then `git describe --tags --match=20*` if this is a git checkout.
pub fn detect(b: *std.Build) Version {
    var full: []const u8 = "0.0-0";

    if (root_files.readRootFile(b, "VERSION")) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) full = trimmed;
    }

    if (root_files.rootExists(b, ".git")) {
        dependOnGitDescribeInputs(b);
        const argv = [_][]const u8{
            "git", "-C", b.root.toString(b.allocator) catch @panic("OOM"), "describe", "--tags", "--match=20*",
        };
        switch (b.runFallible(&argv, .{ .stderr_behavior = .ignore })) {
            .success => |out| {
                const trimmed = std.mem.trim(u8, out, " \t\r\n");
                if (trimmed.len > 0) full = trimmed;
            },
            .spawn_failed, .bad_exit_code, .crashed => {},
        }
    }

    return parse(full);
}

/// Registers what `git describe --tags` depends on as configure inputs
/// (Zig 0.17 caches the configure phase): HEAD, the branch ref it names,
/// packed-refs and the loose tags. When .git is not a directory (a
/// worktree or submodule checkout whose .git file points elsewhere) the
/// refs live outside the build root, so the configure cache is poisoned
/// instead and configure re-runs on every build.
fn dependOnGitDescribeInputs(b: *std.Build) void {
    const io = b.graph.io;
    var git_dir = b.root.openDir(io, ".git", .{}) catch {
        b.graph.poisonCache();
        return;
    };
    git_dir.close(io);
    if (root_files.readRootFile(b, ".git/HEAD")) |head| {
        const ref_prefix = "ref: ";
        const line = std.mem.trim(u8, head, " \t\r\n");
        if (std.mem.startsWith(u8, line, ref_prefix))
            root_files.dependOnRootFile(b, b.fmt(".git/{s}", .{line[ref_prefix.len..]}));
    }
    root_files.dependOnRootFile(b, ".git/packed-refs");
    root_files.dependOnRootDir(b, ".git/refs/tags");
}

test "parse: git describe output" {
    const v = parse("2026.09-39-g71a33965f");
    try std.testing.expectEqualStrings("2026.09-39-g71a33965f", v.full);
    try std.testing.expectEqualStrings("2026", v.major);
    try std.testing.expectEqualStrings("09", v.minor);
    try std.testing.expectEqualStrings("39", v.patch);
}

test "parse: release tag without patch" {
    const v = parse("2026.09");
    try std.testing.expectEqualStrings("2026", v.major);
    try std.testing.expectEqualStrings("09", v.minor);
    try std.testing.expectEqualStrings("0", v.patch);
}

test "parse: fallback and garbage" {
    const d = parse("0.0-0");
    try std.testing.expectEqualStrings("0", d.major);
    try std.testing.expectEqualStrings("0", d.minor);
    try std.testing.expectEqualStrings("0", d.patch);
    const g = parse("garbage");
    try std.testing.expectEqualStrings("0", g.major);
    try std.testing.expectEqualStrings("0", g.minor);
    try std.testing.expectEqualStrings("0", g.patch);
}
