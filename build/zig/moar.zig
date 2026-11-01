//! libmoar and the moar executable.
const std = @import("std");
const Options = @import("options.zig").Options;
const Facts = @import("platform.zig").Facts;
const sources = @import("sources.zig");
const thirdparty = @import("thirdparty.zig");

pub fn heapSnapshotFormat(opts: Options) u8 {
    return if (opts.zstd) 3 else 2;
}

/// Flags for MoarVM's own sources: base_cflags plus the MoarVM defines.
pub fn cflags(b: *std.Build, opts: Options) []const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &thirdparty.base_cflags) catch @panic("OOM");
    flags.appendSlice(b.allocator, &.{ "-DMVM_TRACING=0", "-DMVM_CGOTO=1" }) catch @panic("OOM");
    flags.append(b.allocator, b.fmt("-DMVM_HEAPSNAPSHOT_FORMAT={d}", .{heapSnapshotFormat(opts)})) catch @panic("OOM");
    if (opts.optimize != .Debug) flags.append(b.allocator, "-DNDEBUG") catch @panic("OOM");
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

/// CINCLUDES from the generated Makefile.
pub fn addIncludes(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(b.path("3rdparty/libuv/include"));
    mod.addIncludePath(b.path("3rdparty/libuv/src"));
    mod.addIncludePath(b.path("3rdparty/libtommath"));
    mod.addIncludePath(b.path("3rdparty/dyncall/dynload"));
    mod.addIncludePath(b.path("3rdparty/dyncall/dyncall"));
    mod.addIncludePath(b.path("3rdparty/dyncall/dyncallback"));
    mod.addIncludePath(b.path("3rdparty/mimalloc/include"));
    mod.addIncludePath(b.path("3rdparty/mimalloc/src"));
    mod.addIncludePath(b.path("3rdparty/zmij"));
    mod.addIncludePath(b.path("3rdparty/sha1"));
    mod.addSystemIncludePath(b.path("3rdparty/mimalloc"));
    mod.addSystemIncludePath(b.path("3rdparty/zmij"));
    mod.addSystemIncludePath(b.path("3rdparty/dynasm"));
    mod.addSystemIncludePath(b.path("3rdparty/cmp"));
    mod.addSystemIncludePath(b.path("3rdparty"));
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
};

pub fn addLibmoar(b: *std.Build, in: LibInputs) *std.Build.Step.Compile {
    const mod = thirdparty.newCModule(b, in.opts);
    const lib = b.addLibrary(.{
        .name = "moar",
        .linkage = if (in.opts.static) .static else .dynamic,
        .root_module = mod,
    });
    addIncludes(b, mod);
    mod.addConfigHeader(in.config_h);

    // The Perl .c.o rule passes -DMVM_BUILD_SHARED to every library object,
    // static builds included.
    const flags = withFlag(b, cflags(b, in.opts), "-DMVM_BUILD_SHARED");

    mod.addCSourceFiles(.{ .files = resolveCoreSources(b, in.lists.core), .flags = flags });
    mod.addCSourceFiles(.{ .files = in.lists.platform_posix, .flags = flags });
    mod.addCSourceFiles(.{ .files = in.lists.jit_stub, .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("3rdparty/freebsd/memmem.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("3rdparty/zmij/zmij.c"), .flags = gnu11(b, flags) });
    if (in.opts.mimalloc)
        mod.addCSourceFile(.{ .file = b.path("3rdparty/mimalloc/src/static.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = in.config_c, .flags = flags });

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
