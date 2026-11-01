//! Generated configuration: config.h (from build/config.h.in), config.c
//! (from build/config.c.in) and pkgconfig/moar.pc.
const std = @import("std");
const Options = @import("options.zig").Options;
const Facts = @import("platform.zig").Facts;
const Version = @import("version.zig").Version;

pub const Inputs = struct {
    opts: Options,
    facts: Facts,
    version: Version,
};

pub fn jitArch(opts: Options) []const u8 {
    return if (opts.jit) "MVM_JIT_ARCH_X64" else "MVM_JIT_ARCH_NONE";
}

pub fn jitPlatform(opts: Options) []const u8 {
    return if (opts.jit) "MVM_JIT_PLATFORM_POSIX" else "MVM_JIT_PLATFORM_NONE";
}

/// Renders build/config.h.in. The step fails if a template variable is
/// missing here or a value here is unused by the template, so this list
/// must match the `@var@` set in build/config.h.in exactly (44 variables).
pub fn configHeader(b: *std.Build, in: Inputs) *std.Build.Step.ConfigHeader {
    const S = []const u8;
    return b.addConfigHeader(.{
        .style = .{ .autoconf_at = b.path("build/config.h.in") },
        .include_path = "gen/config.h",
    }, .{
        .version = in.version.full,
        .versionmajor = in.version.major,
        .versionminor = in.version.minor,
        .versionpatch = in.version.patch,

        .noreturnspecifier = @as(S, ""),
        .noreturnattribute = @as(S, "__attribute__((noreturn))"),
        .formatattribute = @as(S, "__attribute__((format(X, Y, Z)))"),
        .fallthrough = @as(S, "__attribute__ ((fallthrough));"),

        .dllimport = @as(S, "__attribute__ ((visibility (\"default\")))"),
        .dllexport = @as(S, "__attribute__ ((visibility (\"default\")))"),
        .dlllocal = @as(S, "__attribute__ ((visibility (\"hidden\")))"),

        .be = in.facts.big_endian,
        .has_pthread_yield = in.facts.has_pthread_yield,
        .has_pthread_setname_np = in.facts.has_pthread_setname_np,
        .has_fn_malloc_trim = in.facts.has_fn_malloc_trim,

        .static_inline = @as(S, "static __inline__"),
        .has_thread_local = true,
        .thread_local = @as(S, "_Thread_local"),
        .can_unaligned_int32 = true,
        .can_unaligned_int64 = true,
        .can_unaligned_num64 = true,
        .ptr_size = @as(i64, in.facts.ptr_size),

        .has_substandard_pow = in.facts.has_substandard_pow,
        .has_substandard_log = in.facts.has_substandard_log,
        .has_substandard_log10 = in.facts.has_substandard_log10,
        .has_substandard_asin = in.facts.has_substandard_asin,
        .has_substandard_acos = in.facts.has_substandard_acos,

        .has_booltype = true,
        .booltype = @as(S, "_Bool"),
        .has_rdtscp = in.facts.has_rdtscp,
        .has_isinf = in.facts.has_isinf,
        .has_isnan = in.facts.has_isnan,
        .has_signbit = in.facts.has_signbit,
        .has_libuv_pty = in.facts.has_libuv_pty,
        .do_pty_ourself = in.facts.do_pty_ourself,
        .use_mimalloc = in.opts.mimalloc,
        .use_c11_atomics = true,
        .translate_newline_output = in.facts.translate_newline_output,

        .jit_arch = jitArch(in.opts),
        .jit_platform = jitPlatform(in.opts),
        .vectorizerspecifier = @as(S, ""),

        .expect_likely = @as(S, "__builtin_expect(!!(condition), 1)"),
        .expect_unlikely = @as(S, "__builtin_expect(!!(condition), 0)"),
        .expect_condition = @as(S, "__builtin_expect((condition), (expection))"),
    });
}
