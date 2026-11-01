const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    jit: bool,
    static: bool,
    mimalloc: bool,
    zstd: bool,
};

pub fn parse(b: *std.Build) Options {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const jit = b.option(bool, "jit",
        "Build the JIT compiler (not yet supported by the zig build; default false)") orelse false;
    if (jit) std.process.fatal(
        "-Djit=true is not implemented by the zig build yet (phase 2 of the migration). " ++
            "Build with the default -Djit=false, or use perl Configure.pl for a JIT-enabled MoarVM.",
        .{},
    );

    return .{
        .target = target,
        .optimize = optimize,
        .jit = jit,
        .static = b.option(bool, "static",
            "Build libmoar as a static library (default: shared)") orelse false,
        .mimalloc = b.option(bool, "mimalloc",
            "Use the bundled mimalloc allocator (default true)") orelse true,
        .zstd = b.option(bool, "zstd",
            "Link the system libzstd and use heap snapshot format 3 (default true)") orelse true,
    };
}
