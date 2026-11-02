//! The libraries MoarVM bundles under 3rdparty/, each built as a static
//! library from its sources with zig cc. Replaces the per-library rules in
//! build/setup.pm and dyncall's own ./configure.
const std = @import("std");
const Options = @import("options.zig").Options;
const platform = @import("platform.zig");
const Facts = platform.Facts;

/// Compiler flags shared by every C file (matches ccmiscflags + ccdefflags
/// + -D_GNU_SOURCE from the Perl build, minus the optimisation flags that
/// zig derives from -Doptimize).
pub const base_cflags = [_][]const u8{
    "-fwrapv",
    "-std=gnu99",
    "-Wextra",
    "-Wall",
    "-Wno-unused-parameter",
    "-Wno-unused-function",
    "-Wno-missing-braces",
    "-Werror=pointer-arith",
    "-D_REENTRANT",
    "-D_FILE_OFFSET_BITS=64",
    "-D_GNU_SOURCE",
};

pub const Libs = struct {
    uv: *std.Build.Step.Compile,
    tommath: *std.Build.Step.Compile,
    dyncall: *std.Build.Step.Compile,
    sha1: *std.Build.Step.Compile,
    cmp: *std.Build.Step.Compile,

    pub fn all(libs: Libs) [5]*std.Build.Step.Compile {
        return .{ libs.uv, libs.tommath, libs.dyncall, libs.sha1, libs.cmp };
    }
};

/// A C module with the settings every MoarVM C compilation shares.
/// `sanitize_c = .off`: zig traps undefined behaviour in C for Debug and
/// ReleaseSafe builds; gcc never did that for MoarVM and the code is not
/// clean under it.
pub fn newCModule(b: *std.Build, opts: Options) *std.Build.Module {
    return b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .pic = true,
        .sanitize_c = .off,
        // Perl's --optimize build carries no debug info and omits frame pointers.
        .strip = opts.strip orelse (opts.optimize != .Debug),
        .omit_frame_pointer = opts.optimize != .Debug,
    });
}

fn newStaticLib(b: *std.Build, opts: Options, name: []const u8) *std.Build.Step.Compile {
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = newCModule(b, opts) });
}

pub fn addAll(b: *std.Build, opts: Options, facts: Facts) Libs {
    return .{
        .uv = addLibuv(b, opts, facts),
        .tommath = addLibtommath(b, opts),
        .dyncall = addDyncall(b, opts),
        .sha1 = addSha1(b, opts),
        .cmp = addCmp(b, opts),
    };
}

fn addLibuv(b: *std.Build, opts: Options, facts: Facts) *std.Build.Step.Compile {
    const lib = newStaticLib(b, opts, "uv");
    lib.root_module.addIncludePath(b.path("3rdparty/libuv/include"));
    lib.root_module.addIncludePath(b.path("3rdparty/libuv/src"));
    lib.root_module.addCSourceFiles(.{
        .root = b.path("3rdparty/libuv/src"),
        .files = &platform.libuv_unix_sources,
        .flags = &base_cflags,
    });
    lib.root_module.addCSourceFiles(.{
        .root = b.path("3rdparty/libuv/src"),
        .files = facts.libuv_platform_sources,
        .flags = &base_cflags,
    });
    return lib;
}

fn addLibtommath(b: *std.Build, opts: Options) *std.Build.Step.Compile {
    const lib = newStaticLib(b, opts, "tommath");
    lib.root_module.addCSourceFiles(.{
        .root = b.path("3rdparty/libtommath"),
        .files = globC(b, "3rdparty/libtommath"),
        .flags = &base_cflags,
    });
    return lib;
}

/// dyncall, dyncallback and dynload in one archive. dyncall's own
/// ./configure only writes PREFIX and LDLIBS; architecture selection
/// happens in dyncall_macros.h at preprocessing time, so the .S files
/// compile for whatever target zig cc is given.
fn addDyncall(b: *std.Build, opts: Options) *std.Build.Step.Compile {
    const lib = newStaticLib(b, opts, "dyncall");
    lib.root_module.addIncludePath(b.path("3rdparty/dyncall/dyncall"));
    lib.root_module.addIncludePath(b.path("3rdparty/dyncall/dyncallback"));
    lib.root_module.addIncludePath(b.path("3rdparty/dyncall/dynload"));
    lib.root_module.addCSourceFiles(.{
        .root = b.path("3rdparty/dyncall"),
        .files = &.{
            "dyncall/dyncall_api.c",
            "dyncall/dyncall_callf.c",
            "dyncall/dyncall_callvm.c",
            "dyncall/dyncall_callvm_base.c",
            "dyncall/dyncall_struct.c",
            "dyncall/dyncall_vector.c",
            "dyncallback/dyncall_alloc_wx.c",
            "dyncallback/dyncall_args.c",
            "dyncallback/dyncall_callback.c",
            "dyncallback/dyncall_thunk.c",
            "dynload/dynload.c",
            "dynload/dynload_syms.c",
        },
        .flags = &base_cflags,
    });
    // .S is detected as assembly-with-preprocessor by extension.
    lib.root_module.addCSourceFiles(.{
        .root = b.path("3rdparty/dyncall"),
        .files = &.{ "dyncall/dyncall_call.S", "dyncallback/dyncall_callback_arch.S" },
        .flags = &.{},
    });
    return lib;
}

fn addSha1(b: *std.Build, opts: Options) *std.Build.Step.Compile {
    const lib = newStaticLib(b, opts, "sha1");
    lib.root_module.addCSourceFile(.{ .file = b.path("3rdparty/sha1/sha1.c"), .flags = &base_cflags });
    return lib;
}

fn addCmp(b: *std.Build, opts: Options) *std.Build.Step.Compile {
    const lib = newStaticLib(b, opts, "cmp");
    lib.root_module.addCSourceFile(.{ .file = b.path("3rdparty/cmp/cmp.c"), .flags = &base_cflags });
    return lib;
}

/// All `*.c` files directly inside `dir_rel` (relative to the build root), sorted.
pub fn globC(b: *std.Build, dir_rel: []const u8) []const []const u8 {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, dir_rel, .{ .iterate = true }) catch |err|
        std.process.fatal("cannot open {s}: {t}", .{ dir_rel, err });
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| std.process.fatal("cannot list {s}: {t}", .{ dir_rel, err })) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        files.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return files.items;
}

fn lessThan(_: void, a: []const u8, c: []const u8) bool {
    return std.mem.order(u8, a, c) == .lt;
}
