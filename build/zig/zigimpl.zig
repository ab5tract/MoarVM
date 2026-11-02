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
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .pic = true,
        // Match thirdparty.newCModule for the optimize mode.
        .strip = opts.optimize != .Debug,
        .omit_frame_pointer = opts.optimize != .Debug,
        .imports = &.{.{ .name = "moar", .module = moar_mod }},
    });
    const object = b.addObject(.{ .name = "moar_zig", .root_module = root_mod });

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

/// The shim unit tests: src/zig/moar.zig as a test root, linked against
/// libmoar (linkLibrary gives the cached test binary an rpath to the cached
/// .so, which the installed moar deliberately avoids) plus the C layout probe.
pub fn addShimTests(
    b: *std.Build,
    opts: Options,
    impl: Impl,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    cflags: []const []const u8,
) *std.Build.Step.Compile {
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/moar.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = impl.c_mod }},
    });
    moar.addIncludes(b, test_mod);
    test_mod.addConfigHeader(config_h);
    test_mod.addCSourceFile(.{ .file = b.path("src/zig/test/layout_probe.c"), .flags = cflags });
    test_mod.linkLibrary(libmoar);
    return b.addTest(.{ .name = "shim-test", .root_module = test_mod });
}
