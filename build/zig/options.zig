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
    /// Diagnostic build: compile the hash engine's statistics hooks in
    /// (src/zig/core/hash/stats.zig) and keep debug info and symbols so the
    /// dump's call sites can be resolved; forces `strip` off.
    hash_stats: bool,
    /// Compile the Unicode tables' Swiss set into libmoar (`-Duni-swiss`).
    uni_swiss: bool,
    /// Prefix of an installed MoarVM + nqp (`<P>/bin/nqp-m`) for the
    /// `strategy-test` step; when set, `zig build test` runs it too.
    nqp_prefix: ?[]const u8,
    /// MVM_GC_DEBUG for every C compile and the translate-c step (0-3, see
    /// src/gc/debug.h); 1 and up also compile in the per-collection log
    /// ($MVM_GC_LOG) and the RSS pin ($MVM_GC_DEBUG_RSS).
    gc_debug: u8,
    /// MVM_NURSERY_SIZE (src/gc/collect.h), the maximum nursery size in
    /// bytes; a small value is the GC stress configuration.
    nursery_size: u32,
};

pub const gc_debug_default: u8 = 0;
pub const nursery_size_default: u32 = 16777216;
pub const gc_debug_range_message = "-Dgc-debug must be 0..3";

/// The -Dgc-debug value, defaulted; MVM_GC_DEBUG has levels 0..3 only.
pub fn gcDebugLevel(raw: ?u8) error{GcDebugOutOfRange}!u8 {
    const v = raw orelse gc_debug_default;
    if (v > 3) return error.GcDebugOutOfRange;
    return v;
}

/// The -Dnursery-size value, defaulted.
pub fn nurserySize(raw: ?u32) u32 {
    return raw orelse nursery_size_default;
}

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

    const strip = b.option(bool, "strip", "Strip symbols from libmoar and the Zig object (default: true unless -Doptimize=Debug); false keeps them for perf");
    const hash_stats = b.option(bool, "hash-stats", "Diagnostic build with the hash engine's statistics (dump to $MVM_HASH_STATS/<pid>.tsv at exit); keeps debug info, forces -Dstrip=false (default false)") orelse false;

    const gc_debug = gcDebugLevel(b.option(u8, "gc-debug", "MVM_GC_DEBUG level 0..3 for the C sources and translate-c; 1 and up compile in the per-collection log ($MVM_GC_LOG) and the RSS pin ($MVM_GC_DEBUG_RSS) (default 0)")) catch
        std.process.fatal("{s}", .{gc_debug_range_message});
    const nursery_size = nurserySize(b.option(u32, "nursery-size", "MVM_NURSERY_SIZE, the maximum nursery size in bytes; small values stress the GC (default 16777216)"));

    const uni_swiss = b.option(bool, "uni-swiss", "Compile the Swiss set (strategy 1) of the Unicode hash tables into libmoar; no internal site uses it, the uni benchmark and the strategy tests do (default false)") orelse false;

    return .{
        .target = target,
        .optimize = optimize,
        .jit = jit,
        .static = b.option(bool, "static", "Build libmoar as a static library (default: shared)") orelse false,
        .mimalloc = b.option(bool, "mimalloc", "Use the bundled mimalloc allocator (default true)") orelse true,
        .zstd = b.option(bool, "zstd", "Link the system libzstd and use heap snapshot format 3 (default true)") orelse true,
        .zig_impl = b.option(bool, "zig-impl", "Build the Zig implementations from the [zig] section of build/sources.list in place of the C files they replace (default true)") orelse true,
        .config_h = config_h,
        .hash_stats = hash_stats,
        .uni_swiss = uni_swiss,
        .gc_debug = gc_debug,
        .nursery_size = nursery_size,
        .strip = if (hash_stats) false else strip,
        .lto = b.option(bool, "lto", "Full link-time optimisation for libmoar and the Zig object (default: true unless -Doptimize=Debug); false links about three times faster") orelse (optimize != .Debug),
        .nqp_prefix = b.option([]const u8, "nqp-prefix", "Prefix of an installed MoarVM and nqp (<P>/bin/nqp-m) for `zig build strategy-test`; when given, `zig build test` runs that step too"),
    };
}

test "gc-debug and nursery-size default and parse" {
    try std.testing.expectEqual(@as(u8, 0), try gcDebugLevel(null));
    try std.testing.expectEqual(@as(u32, 16777216), nurserySize(null));
    try std.testing.expectEqual(@as(u8, 3), try gcDebugLevel(3));
    try std.testing.expectEqual(@as(u32, 524288), nurserySize(524288));
    try std.testing.expectError(error.GcDebugOutOfRange, gcDebugLevel(4));
    try std.testing.expectEqualStrings("-Dgc-debug must be 0..3", gc_debug_range_message);
}
