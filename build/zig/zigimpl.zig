//! The Zig implementations: translate-c of src/moar.h (through
//! src/zig/moar_c.h), the fixup pass, the `moar` module, and the single
//! object `moar_zig` that holds every file under src/zig/ named in
//! build/sources.list's [zig] section. See docs/zig-build.md.
const std = @import("std");
const Options = @import("options.zig").Options;
const moar = @import("moar.zig");
const sources = @import("sources.zig");

pub const Impl = struct {
    translate: *std.Build.Step.TranslateC,
    /// The fixed translate-c output as a module (import name "c").
    c_mod: *std.Build.Module,
    /// src/zig/moar.zig with "c" imported.
    moar_mod: *std.Build.Module,
    /// The object linked into libmoar, root src/zig/root.zig.
    object: *std.Build.Step.Compile,
};

pub const ConfigSource = union(enum) {
    /// The ConfigHeader step this build renders.
    generated: *std.Build.Step.ConfigHeader,
    /// A directory containing gen/config.h written by another build.
    existing: std.Build.LazyPath,
};

/// Directory to put on the include path for `-Dconfig-h=<dir>/gen/config.h`.
pub fn configDir(b: *std.Build, config_h: []const u8) std.Build.LazyPath {
    return b.path(configDirName(config_h));
}

fn configDirName(config_h: []const u8) []const u8 {
    const suffix = "gen/config.h";
    const dir = std.mem.trimEnd(u8, config_h[0 .. config_h.len - suffix.len], "/");
    return if (dir.len == 0) "." else dir;
}

pub fn add(b: *std.Build, opts: Options, config: ConfigSource) Impl {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/zig/moar_c.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    switch (config) {
        .generated => |h| translate.addConfigHeader(h),
        .existing => |dir| translate.addIncludePath(dir),
    }
    for (moar.include_paths) |p| translate.addIncludePath(b.path(p));
    for (moar.system_include_paths) |p| translate.addSystemIncludePath(b.path(p));
    for (moar.defines(b, opts)) |d| translate.defineCMacro(d.name, d.value);

    const fixup = b.addExecutable(.{
        .name = "fixup_translated",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/zig/fixup_translated.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(fixup);
    run.addFileArg(translate.getOutput());
    const fixed = run.addOutputFileArg("moar_c.zig");

    const c_mod = b.createModule(.{
        .root_source_file = fixed,
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    const moar_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/moar.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    // Read by src/zig/core/hash/*_exports.zig for the exports' visibility.
    const zig_opts = b.addOptions();
    zig_opts.addOption(bool, "lto", opts.lto);
    zig_opts.addOption(bool, "hash_stats", opts.hash_stats);
    zig_opts.addOption(bool, "uni_swiss", opts.uni_swiss);
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .pic = true,
        // Match thirdparty.newCModule for the optimize mode.
        .strip = opts.strip orelse (opts.optimize != .Debug),
        .omit_frame_pointer = opts.optimize != .Debug,
        .imports = &.{
            .{ .name = "moar", .module = moar_mod },
            .{ .name = "zig_options", .module = zig_opts.createModule() },
        },
    });
    const object = b.addObject(.{ .name = "moar_zig", .root_module = root_mod });
    if (opts.lto) object.lto = .full;

    return .{ .translate = translate, .c_mod = c_mod, .moar_mod = moar_mod, .object = object };
}

/// `zig build zig-objects`: install the object to <prefix>/lib/moar_zig.o.
/// The Perl Makefile calls this step; nothing else in the graph is needed.
pub fn addObjectsStep(b: *std.Build, impl: Impl) *std.Build.Step {
    const step = b.step("zig-objects", "Build the Zig implementations object into <prefix>/lib/moar_zig.o (used by the Perl Makefile with -Dconfig-h)");
    step.dependOn(&b.addInstallFile(impl.object.getEmittedBin(), "lib/moar_zig.o").step);
    return step;
}

/// Every [zig] file must be imported by src/zig/root.zig, or its exports
/// are never emitted and the link fails with undefined symbols later.
pub fn checkRootImports(b: *std.Build, lists: sources.Lists) void {
    const root = b.build_root.handle.readFileAlloc(b.graph.io, "src/zig/root.zig", b.allocator, .unlimited) catch |err|
        std.process.fatal("cannot read src/zig/root.zig: {t}", .{err});
    for (lists.zig) |entry| {
        const prefix = "src/zig/";
        if (!std.mem.startsWith(u8, entry.zig, prefix))
            std.process.fatal("build/sources.list: [zig] file {s} must live under src/zig/", .{entry.zig});
        const needle = b.fmt("@import(\"{s}\")", .{entry.zig[prefix.len..]});
        if (std.mem.indexOf(u8, root, needle) == null)
            std.process.fatal("src/zig/root.zig does not {s}; add it so the file's exports are emitted", .{needle});
    }
}

test "configDirName strips gen/config.h" {
    try std.testing.expectEqualStrings("src", configDirName("src/gen/config.h"));
    try std.testing.expectEqualStrings(".", configDirName("gen/config.h"));
    try std.testing.expectEqualStrings("a/b", configDirName("a/b//gen/config.h"));
}

/// A libmoar-linked test root (`root_source_file`, test binary `name`):
/// linked against libmoar (linkLibrary gives the cached test binary an rpath
/// to the cached .so, which the installed moar deliberately avoids) plus the
/// C layout probe. The root sees the translated C (`c`, what
/// src/zig/moar.zig imports), the shim module (`moar`, what everything under
/// src/zig/core/ imports) and `extra_imports`; a root ignores what it does
/// not use.
pub fn addShimTests(
    b: *std.Build,
    opts: Options,
    impl: Impl,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    cflags: []const []const u8,
    root_source_file: []const u8,
    name: []const u8,
    extra_imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = impl.c_mod },
            .{ .name = "moar", .module = impl.moar_mod },
        },
    });
    for (extra_imports) |imp| test_mod.addImport(imp.name, imp.module);
    // The real unicode names, for the tag-distribution test of uni_test.zig.
    test_mod.addAnonymousImport("uni_bench_keys", .{ .root_source_file = b.path("tools/bench/uni-bench-keys.tsv") });
    moar.addIncludes(b, test_mod);
    test_mod.addConfigHeader(config_h);
    test_mod.addCSourceFile(.{ .file = b.path("src/zig/test/layout_probe.c"), .flags = cflags });
    test_mod.linkLibrary(libmoar);
    return b.addTest(.{ .name = name, .root_module = test_mod });
}

/// `zig build hash-bench`: the C-API microbenchmark executable, its root
/// src/zig/core/hash/bench.zig, linked like the shim tests (against the
/// cached libmoar, with the includes and config header a libmoar object
/// sees) plus the benchmark's C shim compiled with libmoar's flags, so with
/// the Zig groups off the shim calls the inline C of the headers and with
/// them on the Zig exports. `bench_options` is the `build_options` module
/// the benchmark reads its `zig_impl` engine column from; `zig_options` carries
/// `hash_stats` for stats.zig.
pub fn addHashBench(
    b: *std.Build,
    opts: Options,
    impl: Impl,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    cflags: []const []const u8,
    bench_options: *std.Build.Module,
    zig_options: *std.Build.Module,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/zig/core/hash/bench.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "moar", .module = impl.moar_mod },
            .{ .name = "build_options", .module = bench_options },
            .{ .name = "zig_options", .module = zig_options },
        },
    });
    moar.addIncludes(b, mod);
    mod.addConfigHeader(config_h);
    mod.addCSourceFile(.{ .file = b.path("src/zig/core/hash/bench_shim.c"), .flags = cflags });
    mod.linkLibrary(libmoar);
    return b.addExecutable(.{ .name = "hash-bench", .root_module = mod });
}

/// `zig build uni-bench`: the C-API benchmark of the four unicode tables,
/// root src/zig/core/hash/uni_bench.zig, wired like `addHashBench` plus the
/// key file `tools/bench/uni-bench-keys.tsv` as the anonymous import
/// `uni_bench_keys` (`@embedFile` cannot leave the module's directory).
pub fn addUniBench(
    b: *std.Build,
    opts: Options,
    impl: Impl,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    cflags: []const []const u8,
    bench_options: *std.Build.Module,
    zig_options: *std.Build.Module,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/zig/core/hash/uni_bench.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "moar", .module = impl.moar_mod },
            .{ .name = "build_options", .module = bench_options },
            .{ .name = "zig_options", .module = zig_options },
        },
    });
    mod.addAnonymousImport("uni_bench_keys", .{ .root_source_file = b.path("tools/bench/uni-bench-keys.tsv") });
    moar.addIncludes(b, mod);
    mod.addConfigHeader(config_h);
    mod.addCSourceFile(.{ .file = b.path("src/zig/core/hash/uni_bench_shim.c"), .flags = cflags });
    mod.linkLibrary(libmoar);
    return b.addExecutable(.{ .name = "uni-bench", .root_module = mod });
}
