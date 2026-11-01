const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");
const platform = @import("build/zig/platform.zig");
const config = @import("build/zig/config.zig");
const thirdparty = @import("build/zig/thirdparty.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    const facts = platform.facts(&opts.target.result);
    const ver = version.detect(b);
    const lists = sources.load(b, "build/sources.list");
    _ = lists;

    const config_h = config.configHeader(b, .{ .opts = opts, .facts = facts, .version = ver });

    const tp = thirdparty.addAll(b, opts, facts);

    const tp_step = b.step("thirdparty", "Build the bundled third-party static libraries");
    for (tp.all()) |lib| tp_step.dependOn(&lib.step);

    const show_version = b.step("version", "Print the detected MoarVM version");
    show_version.dependOn(&b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch }).step);

    const config_h_step = b.step("config-h", "Render config.h into zig-out/config.h for inspection");
    config_h_step.dependOn(&b.addInstallFileWithDir(config_h.getOutputFile(), .prefix, "config.h").step);
}
