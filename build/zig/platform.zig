//! Per-OS facts that replace the compiler probes in build/probe.pm.
//! With zig cc (clang) as the only compiler, compiler features are constants;
//! only libc behaviour varies, and it varies by OS.
const std = @import("std");

pub const Facts = struct {
    os_name: []const u8,
    has_pthread_yield: bool,
    has_pthread_setname_np: bool,
    has_fn_malloc_trim: bool,
    has_substandard_pow: bool,
    has_substandard_log: bool,
    has_substandard_log10: bool,
    has_substandard_asin: bool,
    has_substandard_acos: bool,
    has_isinf: bool,
    has_isnan: bool,
    has_signbit: bool,
    has_libuv_pty: bool,
    do_pty_ourself: bool,
    translate_newline_output: bool,
    /// libuv sources beyond `libuv_unix_sources`, relative to 3rdparty/libuv/src.
    libuv_platform_sources: []const []const u8,
    /// System libraries libmoar links (besides libc and libzstd).
    system_libs: []const []const u8,
    // Filled from the target by `facts`:
    has_rdtscp: bool = false,
    big_endian: bool = false,
    ptr_size: u8 = 8,
};

pub fn facts(target: *const std.Target) Facts {
    var f: Facts = switch (target.os.tag) {
        .linux => linux,
        else => std.process.fatal(
            "the zig build does not support OS '{s}' yet (only linux in phase 1). " ++
                "Add a Facts table for it in build/zig/platform.zig.",
            .{@tagName(target.os.tag)},
        ),
    };
    if (target.os.tag == .linux and !target.abi.isGnu()) std.process.fatal(
        "the zig build does not support the '{s}' ABI on linux yet (glibc only; musl is not supported yet). " ++
            "Add a Facts table for it in build/zig/platform.zig.",
        .{@tagName(target.abi)},
    );
    if (target.cpu.arch != .x86_64) std.process.fatal(
        "the zig build does not support CPU architecture '{s}' yet (only x86_64 in phase 1). " ++
            "Add the architecture to build/zig/platform.zig.",
        .{@tagName(target.cpu.arch)},
    );
    f.has_rdtscp = target.cpu.arch == .x86_64;
    f.big_endian = target.cpu.arch.endian() == .big;
    f.ptr_size = @intCast(@divExact(target.ptrBitWidth(), 8));
    return f;
}

/// What build/probe.pm reports on glibc x86_64 linux (see a Perl-generated src/gen/config.h).
const linux: Facts = .{
    .os_name = "linux",
    .has_pthread_yield = false,
    .has_pthread_setname_np = true,
    .has_fn_malloc_trim = true,
    .has_substandard_pow = false,
    .has_substandard_log = false,
    .has_substandard_log10 = false,
    .has_substandard_asin = false,
    .has_substandard_acos = false,
    .has_isinf = true,
    .has_isnan = true,
    .has_signbit = true,
    .has_libuv_pty = true,
    .do_pty_ourself = false,
    .translate_newline_output = false,
    .libuv_platform_sources = &.{ "unix/linux.c", "unix/procfs-exepath.c", "unix/proctitle.c" },
    .system_libs = &.{ "m", "pthread", "rt", "dl" },
};

/// UV_UNIX in build/Makefile.in, relative to 3rdparty/libuv/src.
pub const libuv_unix_sources = [_][]const u8{
    "strscpy.c",          "strtok.c",            "fs-poll.c",     "inet.c",
    "uv-common.c",        "version.c",           "timer.c",       "threadpool.c",
    "unix/async.c",       "unix/core.c",         "unix/dl.c",     "unix/fs.c",
    "unix/getaddrinfo.c", "unix/loop-watcher.c", "unix/loop.c",   "unix/pipe.c",
    "unix/poll.c",        "unix/process.c",      "unix/signal.c", "unix/stream.c",
    "unix/tcp.c",         "unix/thread.c",       "unix/tty.c",    "unix/udp.c",
};
