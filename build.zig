const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");
const platform = @import("build/zig/platform.zig");
const config = @import("build/zig/config.zig");
const thirdparty = @import("build/zig/thirdparty.zig");
const jit = @import("build/zig/jit.zig");
const moar = @import("build/zig/moar.zig");
const install = @import("build/zig/install.zig");
const zigimpl = @import("build/zig/zigimpl.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    // The Perl build writes src/gen/config.h next to the sources. A quote
    // include searches the including file's directory first, so that file
    // would silently shadow the config.h this build generates. With
    // -Dconfig-h that file is the intended input, so the check is skipped.
    if (opts.config_h == null) {
        if (b.build_root.handle.access(b.graph.io, "src/gen/config.h", .{})) |_| {
            std.process.fatal(
                "src/gen/config.h exists (written by perl Configure.pl) and would shadow the zig-generated config.h.\n" ++
                    "Remove the Perl-generated files first:  rm -f src/gen/config.h src/gen/config.c src/gen/config.o\n" ++
                    "(perl Configure.pl recreates them when you go back to the Perl build.)",
                .{},
            );
        } else |_| {}
    }
    const facts = platform.facts(&opts.target.result);
    const ver = version.detect(b);
    const raw_lists = sources.load(b, "build/sources.list");
    const lists = if (opts.zig_impl) sources.applyZig(b.allocator, raw_lists) catch |err|
        std.process.fatal("cannot apply the [zig] section: {t}", .{err}) else raw_lists;
    if (opts.zig_impl) zigimpl.checkRootImports(b, lists);

    const config_h = config.configHeader(b, .{ .opts = opts, .facts = facts, .version = ver });

    const zig_impl: ?zigimpl.Impl = if (opts.zig_impl) zigimpl.add(b, opts, if (opts.config_h) |p|
        .{ .existing = zigimpl.configDir(b, p) }
    else
        .{ .generated = config_h }) else null;
    if (zig_impl) |impl| _ = zigimpl.addObjectsStep(b, impl);

    const tp = thirdparty.addAll(b, opts, facts);

    const paths = config.InstallPaths.fromBuild(b);
    const inputs: config.Inputs = .{ .opts = opts, .facts = facts, .version = ver };
    const config_c = config.configSource(b, inputs, paths, moar.cflags(b, opts));

    const jit_build: ?jit.Jit = if (opts.jit) jit.addAll(b) else null;
    if (jit_build) |j| {
        _ = jit.addCheckStep(b, j);
    }

    const libmoar = moar.addLibmoar(b, .{
        .opts = opts,
        .facts = facts,
        .lists = lists,
        .config_h = config_h,
        .config_c = config_c,
        .tp = tp,
        .jit = jit_build,
        .zig_object = if (zig_impl) |impl| impl.object else null,
    });
    const exe = moar.addMoar(b, opts, libmoar, lists, config_h, paths);
    b.installArtifact(libmoar);
    b.installArtifact(exe);
    install.addAll(b, libmoar, config_h, config.pkgConfig(b, ver, paths));

    // `zig build test`: moar --version plus the nqp stage0 smoke test.
    // MoarVM has no C test suite of its own; NQP's tests cover it.
    const test_step = b.step("test", "Run moar --version and the nqp stage0 smoke test");
    // Run the installed binary, not the cached one: only the installed
    // layout has libmoar.so where the RUNPATH (<prefix>/lib, $ORIGIN/../lib)
    // expects it. The cached binary would silently load a system libmoar.so.
    // The library is hashed as well so a libmoar-only change re-runs the tests.
    const installed_moar: std.Build.LazyPath = .{ .cwd_relative = b.getInstallPath(.bin, "moar") };
    const installed_libmoar: std.Build.LazyPath = .{ .cwd_relative = b.getInstallPath(.lib, if (opts.static) "libmoar.a" else "libmoar.so") };

    const version_run = std.Build.Step.Run.create(b, "run installed moar --version");
    version_run.step.dependOn(b.getInstallStep());
    version_run.addFileArg(installed_moar);
    version_run.addFileInput(installed_libmoar);
    version_run.addArg("--version");
    version_run.expectStdOutEqual(b.fmt("This is MoarVM version {s}{s}\n", .{ ver.full, if (opts.jit) " built with JIT support" else "" }));
    test_step.dependOn(&version_run.step);

    const stage0 = b.option([]const u8, "nqp-stage0", "Directory with nqp's stage0 .moarvm files for `zig build test` (default ../src/vm/moar/stage0)") orelse
        "../src/vm/moar/stage0";
    if (b.build_root.handle.access(b.graph.io, stage0, .{})) |_| {
        const smoke = std.Build.Step.Run.create(b, "run installed moar on nqp stage0");
        smoke.step.dependOn(b.getInstallStep());
        smoke.addFileArg(installed_moar);
        smoke.addFileInput(installed_libmoar);
        smoke.addArg(b.fmt("--libpath={s}", .{stage0}));
        smoke.addArg(b.pathJoin(&.{ stage0, "nqp.moarvm" }));
        smoke.addArgs(&.{ "-e", "say(1+1)" });
        smoke.expectStdOutEqual("2\n");
        smoke.setCwd(b.path("."));
        test_step.dependOn(&smoke.step);

        if (jit_build != null) {
            const hot = std.Build.Step.Run.create(b, "run installed moar with forced JIT");
            hot.step.dependOn(b.getInstallStep());
            hot.addFileArg(installed_moar);
            hot.addFileInput(installed_libmoar);
            hot.addArg(b.fmt("--libpath={s}", .{stage0}));
            hot.addArg(b.pathJoin(&.{ stage0, "nqp.moarvm" }));
            hot.addArgs(&.{ "-e", "my int $i := 0; my int $n := 0; while $i < 200000 { $n := $n + $i; $i := $i + 1 }; say($n)" });
            hot.setEnvironmentVariable("MVM_SPESH_NODELAY", "1");
            hot.setEnvironmentVariable("MVM_SPESH_BLOCKING", "1");
            hot.setEnvironmentVariable("MVM_JIT_EXPR_ENABLE", "1");
            hot.expectStdOutEqual("19999900000\n");
            hot.setCwd(b.path("."));
            test_step.dependOn(&hot.step);
        }
    } else |_| {}

    // Unit tests of the build helpers; `test` runs them first.
    const unit_step = b.step("unit-test", "Run the unit tests of the build helpers");
    for ([_][]const u8{ "build/zig/sources.zig", "build/zig/version.zig", "build/zig/config.zig", "build/zig/fixup_translated.zig", "build/zig/zigimpl.zig", "tools/zig/sexpr.zig", "tools/zig/oplist.zig", "tools/zig/expr_ops.zig", "tools/zig/expr_template_compiler.zig", "tools/zig/tiler_table_generator.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        }) });
        unit_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (zig_impl) |impl| {
        if (opts.config_h == null) {
            const shim_tests = zigimpl.addShimTests(b, opts, impl, libmoar, config_h, moar.cflags(b, opts));
            unit_step.dependOn(&b.addRunArtifact(shim_tests).step);
        }
    }
    test_step.dependOn(unit_step);

    const tp_step = b.step("thirdparty", "Build the bundled third-party static libraries");
    for (tp.all()) |lib| tp_step.dependOn(&lib.step);

    const show_version = b.step("version", "Print the detected MoarVM version");
    show_version.dependOn(&b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch }).step);

    const config_h_step = b.step("config-h", "Render config.h into zig-out/config.h for inspection");
    config_h_step.dependOn(&b.addInstallFileWithDir(config_h.getOutputFile(), .prefix, "config.h").step);
}
