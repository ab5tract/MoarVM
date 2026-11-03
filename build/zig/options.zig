const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    jit: bool,
    static: bool,
    mimalloc: bool,
    zstd: bool,
    /// Compile the Zig implementations listed in build/sources.list's [zig]
    /// section and drop the C files they replace.
    zig_impl: bool,
    /// Use an existing <dir>/gen/config.h (the Perl build's) instead of the
    /// generated one. Only the `zig-objects` step is supported in this mode.
    config_h: ?[]const u8,
    /// Strip symbols from libmoar's C objects and the Zig object; null means
    /// the default (strip unless Debug). `-Dstrip=false` keeps them for
    /// `perf report`/`perf annotate` without changing the generated code.
    strip: ?bool,
    /// Full link-time optimisation for libmoar and the moar_zig object, so
    /// the LTO link binds the hash engine's exports locally and can inline
    /// the small ones (iteration); the lookup exports are still called.
    /// On by default except in Debug, so the LTO path (protected exports,
    /// bitcode object) is the one every build exercises; `-Dlto=false`
    /// turns it off for a faster link.
    lto: bool,
    /// Prefix of an installed MoarVM + nqp (`<P>/bin/nqp-m`) for the
    /// `strategy-test` step; when set, `zig build test` runs it too.
    nqp_prefix: ?[]const u8,
};

pub fn parse(b: *std.Build) Options {
    var target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    // On x86_64 the default CPU is x86-64-v3 (the AVX2 class: Haswell and
    // Zen and everything after them), not the generic baseline gcc defaults
    // to: the hash engine's group probes and the hot paths vectorise with
    // it. -Dcpu=baseline restores the generic build, -Dcpu=native tunes
    // for the host. The Perl build passes the same level through -march
    // (Configure.pl --march), so the two builds stay in sync.
    if (target.result.cpu.arch == .x86_64 and !b.user_input_options.contains("cpu")) {
        var query = target.query;
        query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
        target = b.resolveTargetQuery(query);
    }
    // Perl's Configure.pl defaults to --optimize (-O3); match that. Pass
    // -Doptimize=Debug for a -g style build.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default ReleaseFast)") orelse .ReleaseFast;

    const x86_64 = target.result.cpu.arch == .x86_64;
    const jit = b.option(bool, "jit", "Build the x86-64 JIT compiler (default: true on x86_64)") orelse x86_64;
    if (jit and !x86_64) std.process.fatal(
        "the JIT is only available on x86_64 (target is {s}); build with -Djit=false",
        .{@tagName(target.result.cpu.arch)},
    );

    const config_h = b.option([]const u8, "config-h", "Path to an existing gen/config.h to build the Zig implementations against (the Perl build passes src/gen/config.h); only `zig build zig-objects` is supported with it");
    if (config_h) |p| {
        if (!std.mem.endsWith(u8, p, "gen/config.h")) std.process.fatal("-Dconfig-h must end in gen/config.h, got {s}", .{p});
    }

    return .{
        .target = target,
        .optimize = optimize,
        .jit = jit,
        .static = b.option(bool, "static", "Build libmoar as a static library (default: shared)") orelse false,
        .mimalloc = b.option(bool, "mimalloc", "Use the bundled mimalloc allocator (default true)") orelse true,
        .zstd = b.option(bool, "zstd", "Link the system libzstd and use heap snapshot format 3 (default true)") orelse true,
        .zig_impl = b.option(bool, "zig-impl", "Build the Zig implementations from the [zig] section of build/sources.list in place of the C files they replace (default true)") orelse true,
        .config_h = config_h,
        .strip = b.option(bool, "strip", "Strip symbols from libmoar and the Zig object (default: true unless -Doptimize=Debug); false keeps them for perf"),
        .lto = b.option(bool, "lto", "Full link-time optimisation for libmoar and the Zig object (default: true unless -Doptimize=Debug); false links about three times faster") orelse (optimize != .Debug),
        .nqp_prefix = b.option([]const u8, "nqp-prefix", "Prefix of an installed MoarVM and nqp (<P>/bin/nqp-m) for `zig build strategy-test`; when given, `zig build test` runs that step too"),
    };
}
