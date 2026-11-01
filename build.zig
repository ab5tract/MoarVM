const std = @import("std");
const options = @import("build/zig/options.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    _ = opts;
}
