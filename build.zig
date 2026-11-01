const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    const lists = sources.load(b, "build/sources.list");
    const ver = version.detect(b);
    _ = opts;
    _ = lists;

    const show = b.step("version", "Print the detected MoarVM version");
    const echo = b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch });
    show.dependOn(&echo.step);
}
