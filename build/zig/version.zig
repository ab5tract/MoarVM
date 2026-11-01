//! MoarVM version string, mirroring Configure.pl.
const std = @import("std");

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

    if (b.build_root.handle.readFileAlloc(b.graph.io, "VERSION", b.allocator, .unlimited)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) full = trimmed;
    } else |_| {}

    if (b.build_root.handle.access(b.graph.io, ".git", .{})) |_| {
        var code: u8 = 0;
        const argv = [_][]const u8{
            "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--match=20*",
        };
        if (b.runAllowFail(&argv, &code, .ignore)) |out| {
            const trimmed = std.mem.trim(u8, out, " \t\r\n");
            if (code == 0 and trimmed.len > 0) full = trimmed;
        } else |_| {}
    } else |_| {}

    return parse(full);
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
