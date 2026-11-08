//! Generated configuration: config.h (from build/config.h.in), config.c
//! (from build/config.c.in) and pkgconfig/moar.pc.
const std = @import("std");
const Options = @import("options.zig").Options;
const Facts = @import("platform.zig").Facts;
const Version = @import("version.zig").Version;
const root_files = @import("root_files.zig");
const fill_prefix = @import("fill_prefix.zig");

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
/// must match the `@var@` set in build/config.h.in exactly (45 variables).
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
        .zig_impl = in.opts.zig_impl,
        .translate_newline_output = in.facts.translate_newline_output,

        .jit_arch = jitArch(in.opts),
        .jit_platform = jitPlatform(in.opts),
        .vectorizerspecifier = @as(S, ""),

        .expect_likely = @as(S, "__builtin_expect(!!(condition), 1)"),
        .expect_unlikely = @as(S, "__builtin_expect(!!(condition), 0)"),
        .expect_condition = @as(S, "__builtin_expect((condition), (expection))"),
    });
}

pub const Entry = struct { key: []const u8, value: []const u8 };

/// Replaces `@backendconfig@` in `template` (build/config.c.in) with one
/// `add_entry(tc, config, "key", "value");` line per entry, C-escaped.
pub fn renderBackendConfig(allocator: std.mem.Allocator, template: []const u8, entries: []const Entry) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try body.appendSlice(allocator, "        add_entry(tc, config, \"");
        try appendCEscaped(&body, allocator, e.key);
        try body.appendSlice(allocator, "\", \"");
        try appendCEscaped(&body, allocator, e.value);
        try body.appendSlice(allocator, "\");\n");
    }
    // The template line is "@backendconfig@\n"; drop our trailing newline so
    // the file does not get a blank line.
    const trimmed = std.mem.trimEnd(u8, body.items, "\n");
    return std.mem.replaceOwned(u8, allocator, template, "@backendconfig@", trimmed);
}

fn appendCEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(allocator, "\\\""),
        '\\' => try list.appendSlice(allocator, "\\\\"),
        '\n' => try list.appendSlice(allocator, "\\n"),
        else => try list.append(allocator, c),
    };
}

/// Where things end up at `zig build install`. The install prefix is known
/// only when the build runs (Zig 0.17), so configure renders these with the
/// `@MOAR_PREFIX@` token and fillPrefix substitutes the logical prefix
/// (`--prefix`, made absolute; not the DESTDIR-adjusted path, because these
/// strings are baked into the binary).
pub const InstallPaths = struct {
    prefix: []const u8,
    bindir: []const u8,
    libdir: []const u8,
    mastdir: []const u8,

    pub const placeholder: InstallPaths = .{
        .prefix = fill_prefix.token,
        .bindir = fill_prefix.token ++ "/bin",
        .libdir = fill_prefix.token ++ "/lib",
        .mastdir = fill_prefix.token ++ "/share/nqp/lib/MAST",
    };
};

/// The build-host executable that fills the prefix token in.
pub fn addFillPrefixTool(b: *std.Build) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "fill_prefix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/zig/fill_prefix.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
}

/// `text` with the prefix token replaced by the deployed install prefix, as
/// the file `basename`.
fn fillPrefix(b: *std.Build, tool: *std.Build.Step.Compile, text: []const u8, basename: []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addDirectoryArg2(b.graph.path(.deployed_prefix, ""), .{ .make_absolute = true });
    run.addFileArg2(b.addWriteFiles().add(b.fmt("{s}.in", .{basename}), text), .{});
    return run.addOutputFileArg2(basename, .{});
}

fn boolStr(v: bool) []const u8 {
    return if (v) "1" else "0";
}

/// The 0.16 spelling of the optimize mode for the baked `config` entry, so
/// 0.16 and 0.17 builds compare byte-identical (backendconfig strings are
/// baked into libmoar, and their length changes startup allocation). 0.17
/// still accepts these names on the command line; switch to the canonical
/// names (@tagName) at 0.18.
fn legacyOptimizeName(o: std.lang.Optimize) []const u8 {
    return switch (o) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

/// The nqp::backendconfig hash. Keys follow the Perl build's src/gen/config.c;
/// values describe the zig toolchain. Covered: every key that nqp-configure
/// (NQP/Config/NQP.pm), Rakudo (NQP/Config/Rakudo.pm) and the rakudo/nqp
/// Makefile templates are known to read. Perl keys that are only used inside
/// MoarVM's own Makefile (mingw_unicode, mainlibs variants, pkgconfig, ...)
/// are deliberately absent; `ldswitch` does not exist in the Perl build.
pub fn backendEntries(b: *std.Build, in: Inputs, paths: InstallPaths, cflags: []const []const u8) []const Entry {
    const opt_flags: []const u8 = if (in.opts.optimize == .debug) "" else "-O3 -DNDEBUG";
    const ldlibs: []const u8 = if (in.opts.zstd) "-lm -lpthread -lrt -ldl -lzstd" else "-lm -lpthread -lrt -ldl";
    const cflags_str = std.mem.join(b.allocator, " ", cflags) catch @panic("OOM");
    const config_str = b.fmt("zig build -Djit={} -Dstatic={} -Dmimalloc={} -Dzstd={} -Doptimize={s}", .{
        in.opts.jit, in.opts.static, in.opts.mimalloc, in.opts.zstd, legacyOptimizeName(in.opts.optimize),
    });
    const ldrpath = b.fmt("-Wl,-rpath,\"{s}\"", .{paths.libdir});
    const ldflags = if (opt_flags.len == 0) ldrpath else b.fmt("{s} {s}", .{ opt_flags, ldrpath });
    const entries = [_]Entry{
        .{ .key = "name", .value = "moar" },
        .{ .key = "version", .value = in.version.full },
        .{ .key = "versionmajor", .value = in.version.major },
        .{ .key = "versionminor", .value = in.version.minor },
        .{ .key = "versionpatch", .value = in.version.patch },
        .{ .key = "config", .value = config_str },
        .{ .key = "os", .value = in.facts.os_name },
        .{ .key = "osname", .value = in.facts.os_name },
        .{ .key = "be", .value = boolStr(in.facts.big_endian) },
        .{ .key = "ptr_size", .value = b.fmt("{d}", .{in.facts.ptr_size}) },
        .{ .key = "prefix", .value = paths.prefix },
        .{ .key = "bindir", .value = paths.bindir },
        .{ .key = "libdir", .value = paths.libdir },
        .{ .key = "mastdir", .value = paths.mastdir },
        .{ .key = "cc", .value = "zig cc" },
        .{ .key = "ld", .value = "zig cc" },
        .{ .key = "ccswitch", .value = "-c" },
        .{ .key = "ccout", .value = "-o " },
        .{ .key = "ldout", .value = "-o " },
        .{ .key = "ccinc", .value = "-I" },
        .{ .key = "ccincsystem", .value = "-isystem" },
        .{ .key = "ccdef", .value = "-D" },
        .{ .key = "lddir", .value = "-L" },
        .{ .key = "ldusr", .value = "-l%s" },
        .{ .key = "ldsys", .value = "-l%s" },
        .{ .key = "ccshared", .value = "-fPIC" },
        .{ .key = "ldshared", .value = "-shared -fPIC" },
        .{ .key = "ccdefflags", .value = "-D_REENTRANT -D_FILE_OFFSET_BITS=64" },
        .{ .key = "ccmiscflags", .value = "-std=gnu99 -Wextra -Wall -Wno-unused-parameter -Wno-unused-function -Wno-missing-braces -Werror=pointer-arith" },
        .{ .key = "ccoptiflags", .value = opt_flags },
        .{ .key = "ccdebugflags", .value = "-g3" },
        .{ .key = "cflags", .value = cflags_str },
        .{ .key = "cincludes", .value = "" },
        .{ .key = "ldflags", .value = ldflags },
        .{ .key = "ldrpath", .value = ldrpath },
        .{ .key = "ldrpath_relocatable", .value = "-Wl,-z,origin,-rpath,'$$ORIGIN/../lib'" },
        .{ .key = "ldimp", .value = "" },
        .{ .key = "do_pty_ourself", .value = boolStr(in.facts.do_pty_ourself) },
        .{ .key = "moar", .value = if (in.opts.static) "libmoar.a" else "libmoar.so" },
        .{ .key = "osvers", .value = "unknown" },
        .{ .key = "ldlibs", .value = ldlibs },
        .{ .key = "mainflags", .value = if (in.opts.static) "" else "-DMVM_SHARED" },
        .{ .key = "mainlibs", .value = "-L. -lmoar" },
        .{ .key = "objflags", .value = "-DMVM_BUILD_SHARED -fPIC" },
        .{ .key = "exe", .value = "" },
        .{ .key = "obj", .value = ".o" },
        .{ .key = "dll", .value = "lib%s.so" },
        .{ .key = "lib", .value = "lib%s.a" },
        .{ .key = "staticlib", .value = if (in.opts.static) "libmoar.a" else "" },
        .{ .key = "make", .value = "make" },
        .{ .key = "sh", .value = "/bin/sh" },
        .{ .key = "nul", .value = "/dev/null" },
        .{ .key = "nativecall_backend", .value = "dyncall" },
        .{ .key = "heapsnapformat", .value = if (in.opts.zstd) "3" else "2" },
        .{ .key = "use_mimalloc", .value = boolStr(in.opts.mimalloc) },
        .{ .key = "use_c11_atomics", .value = "1" },
        .{ .key = "has_fn_malloc_trim", .value = boolStr(in.facts.has_fn_malloc_trim) },
        .{ .key = "has_pthread_setname_np", .value = boolStr(in.facts.has_pthread_setname_np) },
        .{ .key = "has_pthread_yield", .value = boolStr(in.facts.has_pthread_yield) },
        .{ .key = "has_libuv_pty", .value = boolStr(in.facts.has_libuv_pty) },
        .{ .key = "has_rdtscp", .value = boolStr(in.facts.has_rdtscp) },
        .{ .key = "static_inline", .value = "static __inline__" },
        .{ .key = "thread_local", .value = "_Thread_local" },
        .{ .key = "booltype", .value = "_Bool" },
        .{ .key = "jit_arch", .value = jitArch(in.opts) },
        .{ .key = "jit_platform", .value = jitPlatform(in.opts) },
        .{ .key = "translate_newline_output", .value = boolStr(in.facts.translate_newline_output) },
        .{ .key = "hllincludes", .value = "moar libuv libtommath dyncall mimalloc zmij" },
    };
    return b.allocator.dupe(Entry, &entries) catch @panic("OOM");
}

/// config.c rendered from build/config.c.in at configure time, with the
/// install prefix filled in when the build runs.
pub fn configSource(b: *std.Build, in: Inputs, tool: *std.Build.Step.Compile, cflags: []const []const u8) std.Build.LazyPath {
    const template = root_files.readRootFile(b, "build/config.c.in") orelse
        std.process.fatal("cannot read build/config.c.in: FileNotFound", .{});
    const text = renderBackendConfig(b.allocator, template, backendEntries(b, in, .placeholder, cflags)) catch @panic("OOM");
    return fillPrefix(b, tool, text, "config.c");
}

test "renderBackendConfig: emits escaped add_entry lines in place of the marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderBackendConfig(arena.allocator(), "A\n@backendconfig@\nB\n", &.{
        .{ .key = "cc", .value = "zig cc" },
        .{ .key = "q", .value = "say \"hi\" \\ there" },
    });
    try std.testing.expectEqualStrings(
        "A\n" ++
            "        add_entry(tc, config, \"cc\", \"zig cc\");\n" ++
            "        add_entry(tc, config, \"q\", \"say \\\"hi\\\" \\\\ there\");\n" ++
            "B\n",
        out,
    );
}

/// pkgconfig/moar.pc, mirroring build/mk-moar-pc.in for a non-/usr prefix.
pub fn pkgConfig(b: *std.Build, ver: Version, tool: *std.Build.Step.Compile) std.Build.LazyPath {
    const paths: InstallPaths = .placeholder;
    const text = b.fmt(
        \\# pkg-config information for MoarVM {[version]s}
        \\#
        \\prefix={[prefix]s}
        \\package=moar
        \\includedir={[prefix]s}/include
        \\bindir={[bindir]s}
        \\libdir={[libdir]s}
        \\mastdir={[mastdir]s}
        \\ldopts=
        \\exeext=
        \\version={[version]s}
        \\moar={[bindir]s}/moar
        \\libs=-L{[libdir]s} -lmoar
        \\static_libs=
        \\
        \\Name:           MoarVM
        \\Description:    A virtual machine for Rakudo and NQP
        \\URL:            http://moarvm.org
        \\Version:        {[version]s}
        \\Libs:           -L{[libdir]s} -lmoar
        \\Cflags:         -I{[prefix]s}/include
        \\
    , .{ .version = ver.full, .prefix = paths.prefix, .bindir = paths.bindir, .libdir = paths.libdir, .mastdir = paths.mastdir });
    return fillPrefix(b, tool, text, "moar.pc");
}
