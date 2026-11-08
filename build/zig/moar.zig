//! libmoar and the moar executable.
const std = @import("std");
const Options = @import("options.zig").Options;
const Facts = @import("platform.zig").Facts;
const sources = @import("sources.zig");
const thirdparty = @import("thirdparty.zig");
const jit = @import("jit.zig");

pub fn heapSnapshotFormat(opts: Options) u8 {
    return if (opts.zstd) 3 else 2;
}

/// Flags for MoarVM's own sources: base_cflags plus the MoarVM defines.
pub fn cflags(b: *std.Build, opts: Options) []const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &thirdparty.base_cflags) catch @panic("OOM");
    flags.appendSlice(b.allocator, &.{ "-DMVM_TRACING=0", "-DMVM_CGOTO=1" }) catch @panic("OOM");
    flags.append(b.allocator, b.fmt("-DMVM_HEAPSNAPSHOT_FORMAT={d}", .{heapSnapshotFormat(opts)})) catch @panic("OOM");
    flags.append(b.allocator, b.fmt("-DMVM_GC_DEBUG={d}", .{opts.gc_debug})) catch @panic("OOM");
    flags.append(b.allocator, b.fmt("-DMVM_NURSERY_SIZE={d}", .{opts.nursery_size})) catch @panic("OOM");
    if (opts.optimize != .debug) {
        // zig's fast mode compiles C at -O2; Perl's --optimize uses -O3.
        // clang honours the last -O flag.
        flags.appendSlice(b.allocator, &.{ "-DNDEBUG", "-O3" }) catch @panic("OOM");
    }
    if (opts.hash_stats) flags.append(b.allocator, "-g") catch @panic("OOM");
    return flags.items;
}

fn withFlag(b: *std.Build, flags: []const []const u8, extra: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(b.allocator, flags) catch @panic("OOM");
    out.append(b.allocator, extra) catch @panic("OOM");
    return out.items;
}

/// zmij is C11; everything else is gnu99.
fn gnu11(b: *std.Build, flags: []const []const u8) []const []const u8 {
    const out = b.allocator.dupe([]const u8, flags) catch @panic("OOM");
    for (out) |*f| if (std.mem.eql(u8, f.*, "-std=gnu99")) {
        f.* = "-std=gnu11";
    };
    return out;
}

/// CINCLUDES from the generated Makefile, in order.
pub const include_paths = [_][]const u8{
    "src",
    "3rdparty/libuv/include",
    "3rdparty/libuv/src",
    "3rdparty/libtommath",
    "3rdparty/dyncall/dynload",
    "3rdparty/dyncall/dyncall",
    "3rdparty/dyncall/dyncallback",
    "3rdparty/mimalloc/include",
    "3rdparty/mimalloc/src",
    "3rdparty/sha1",
};
pub const system_include_paths = [_][]const u8{
    "3rdparty/mimalloc",
    "3rdparty/zmij",
    "3rdparty/dynasm",
    "3rdparty/cmp",
    "3rdparty",
};

pub fn addIncludes(b: *std.Build, mod: *std.Build.Module) void {
    for (include_paths) |p| mod.addIncludePath(b.path(p));
    for (system_include_paths) |p| mod.addSystemIncludePath(b.path(p));
}

pub const Define = struct { name: []const u8, value: ?[]const u8 };

/// The -D flags a libmoar object is compiled with, as name/value pairs for
/// translate-c. Keep in step with `cflags` and thirdparty.base_cflags.
pub fn defines(b: *std.Build, opts: Options) []const Define {
    var out: std.ArrayList(Define) = .empty;
    out.appendSlice(b.allocator, &.{
        .{ .name = "_REENTRANT", .value = null },
        .{ .name = "_FILE_OFFSET_BITS", .value = "64" },
        .{ .name = "_GNU_SOURCE", .value = null },
        .{ .name = "MVM_TRACING", .value = "0" },
        .{ .name = "MVM_CGOTO", .value = "1" },
        .{ .name = "MVM_HEAPSNAPSHOT_FORMAT", .value = b.fmt("{d}", .{heapSnapshotFormat(opts)}) },
        .{ .name = "MVM_GC_DEBUG", .value = b.fmt("{d}", .{opts.gc_debug}) },
        .{ .name = "MVM_NURSERY_SIZE", .value = b.fmt("{d}", .{opts.nursery_size}) },
        .{ .name = "MVM_BUILD_SHARED", .value = null },
    }) catch @panic("OOM");
    if (opts.optimize != .debug) out.append(b.allocator, .{ .name = "NDEBUG", .value = null }) catch @panic("OOM");
    return out.items;
}

pub const LibInputs = struct {
    opts: Options,
    facts: Facts,
    lists: sources.Lists,
    config_h: *std.Build.Step.ConfigHeader,
    /// Generated config.c (Task 7). Not read from sources.list, which lists
    /// the Perl-generated src/gen/config.c for the Makefile's benefit.
    config_c: std.Build.LazyPath,
    tp: thirdparty.Libs,
    jit: ?jit.Jit,
    /// The Zig implementations object (build/zig/zigimpl.zig), or null with -Dzig-impl=false.
    zig_object: ?*std.Build.Step.Compile,
};

pub fn addLibmoar(b: *std.Build, in: LibInputs) *std.Build.Step.Compile {
    const mod = thirdparty.newCModule(b, in.opts);
    const lib = b.addLibrary(.{
        .name = "moar",
        .linkage = if (in.opts.static) .static else .dynamic,
        .root_module = mod,
    });
    if (in.opts.lto) lib.lto = .full;
    // Generated JIT headers must come before `src`, where the Perl build
    // leaves its own copies (gitignored), so "jit/core_templates.h" and
    // "jit/x64/tile_pattern.h" resolve to ours.
    if (in.jit) |j| mod.addIncludePath(j.gen.include_dir);
    addIncludes(b, mod);
    mod.addConfigHeader(in.config_h);

    // The Perl .c.o rule passes -DMVM_BUILD_SHARED to every library object,
    // static builds included.
    const flags = withFlag(b, cflags(b, in.opts), "-DMVM_BUILD_SHARED");

    mod.addCSourceFiles(.{ .files = resolveCoreSources(b, in.lists.core), .flags = flags });
    mod.addCSourceFiles(.{ .files = in.lists.platform_posix, .flags = flags });
    if (in.jit) |j| {
        mod.addCSourceFiles(.{ .files = in.lists.jit, .flags = flags });
        // [jit-x64] lists the generated src/jit/x64/emit.c for the Makefile's
        // benefit; the zig build compiles the one DynASM just produced.
        for (in.lists.jit_x64) |f| {
            if (std.mem.eql(u8, f, "src/jit/x64/emit.c")) continue;
            mod.addCSourceFile(.{ .file = b.path(f), .flags = flags });
        }
        mod.addCSourceFile(.{ .file = j.dynasm.emit_c, .flags = flags });
    } else {
        mod.addCSourceFiles(.{ .files = in.lists.jit_stub, .flags = flags });
    }
    mod.addCSourceFile(.{ .file = b.path("3rdparty/freebsd/memmem.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("3rdparty/zmij/zmij.c"), .flags = gnu11(b, flags) });
    if (in.opts.mimalloc)
        mod.addCSourceFile(.{ .file = b.path("3rdparty/mimalloc/src/static.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = in.config_c, .flags = flags });
    if (in.zig_object) |obj| mod.addObject(obj);

    for (in.tp.all()) |tp_lib| mod.linkLibrary(tp_lib);
    for (in.facts.system_libs) |name| mod.linkSystemLibrary(name, .{});
    if (in.opts.zstd) mod.linkSystemLibrary("zstd", .{});

    return lib;
}

/// The [core] list as the zig build compiles it: drop the Perl-generated
/// src/gen/config.c (Task 7 generates our own) and expand the one Makefile
/// template variable the list carries, `@nativecall_backend@` (dyncall here;
/// libffi is a phase-5 option).
fn resolveCoreSources(b: *std.Build, files: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (std.mem.eql(u8, f, "src/gen/config.c")) continue;
        const resolved = std.mem.replaceOwned(u8, b.allocator, f, "@nativecall_backend@", "dyncall") catch @panic("OOM");
        out.append(b.allocator, resolved) catch @panic("OOM");
    }
    return out.items;
}

pub fn addMoar(
    b: *std.Build,
    opts: Options,
    libmoar: *std.Build.Step.Compile,
    lists: sources.Lists,
    config_h: *std.Build.Step.ConfigHeader,
) *std.Build.Step.Compile {
    const mod = thirdparty.newCModule(b, opts);
    const exe = b.addExecutable(.{ .name = "moar", .root_module = mod });
    addIncludes(b, mod);
    mod.addConfigHeader(config_h);

    const base = cflags(b, opts);
    const flags = if (opts.static) base else withFlag(b, base, "-DMVM_SHARED");
    mod.addCSourceFiles(.{ .files = lists.main, .flags = flags });

    if (opts.static) {
        mod.linkLibrary(libmoar);
    } else {
        // Not linkLibrary: for a dynamic artifact zig adds an rpath to the
        // build-tree dir (relative to the cwd), which would shadow the install.
        mod.addObjectFile(libmoar.getEmittedBin());
        // Find libmoar.so relative to the binary first, so a staged or
        // DESTDIR install loads its own sibling library, then fall back to
        // the install prefix (like the Perl build's -Wl,-rpath,$(LIBDIR)).
        mod.addRPathSpecial("$ORIGIN/../lib");
        mod.addRPath(b.graph.path(.deployed_lib, ""));
    }
    return exe;
}
