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
    const target = b.standardTargetOptions(.{
        // Generic x86-64 like gcc's default; -Dcpu=native tunes for the host.
        .default_target = .{ .cpu_model = .baseline },
    });
    // Perl's Configure.pl defaults to --optimize (-O3); match that. Pass
    // -Doptimize=Debug for a -g style build.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default ReleaseFast)") orelse .ReleaseFast;

    const x86_64 = target.result.cpu.arch == .x86_64;
    const jit = b.option(bool, "jit", "Build the x86-64 JIT compiler (default: true on x86_64)") orelse x86_64;
    if (jit and !x86_64) std.process.fatal(
        "the JIT is only available on x86_64 (target is {s}); build with -Djit=false",
        .{@tagName(target.result.cpu.arch)},
    );

    return .{
        .target = target,
        .optimize = optimize,
        .jit = jit,
        .static = b.option(bool, "static", "Build libmoar as a static library (default: shared)") orelse false,
        .mimalloc = b.option(bool, "mimalloc", "Use the bundled mimalloc allocator (default true)") orelse true,
        .zstd = b.option(bool, "zstd", "Link the system libzstd and use heap snapshot format 3 (default true)") orelse true,
    };
}
