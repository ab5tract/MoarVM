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

    // Read by core/hash/stats.zig in every root that reaches it.
    const stats_opts = b.addOptions();
    stats_opts.addOption(bool, "hash_stats", opts.hash_stats);
    stats_opts.addOption(bool, "uni_swiss", opts.uni_swiss);
    // The exports files, which the stats test links into its own binary, read it.
    stats_opts.addOption(bool, "lto", opts.lto);
    const stats_options = stats_opts.createModule();
    // Unit tests of the build helpers; `test` runs them first.
    const unit_step = b.step("unit-test", "Run the unit tests of the build helpers");
    for ([_][]const u8{ "build/zig/sources.zig", "build/zig/options.zig", "build/zig/version.zig", "build/zig/config.zig", "build/zig/fixup_translated.zig", "build/zig/zigimpl.zig", "tools/zig/sexpr.zig", "tools/zig/oplist.zig", "tools/zig/expr_ops.zig", "tools/zig/expr_template_compiler.zig", "tools/zig/tiler_table_generator.zig", "src/zig/core/hash/tier.zig", "src/zig/core/hash/test_spec.zig", "src/zig/core/hash/table.zig", "src/zig/core/hash/stats.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = b.graph.host,
                // The enabled statistics reach for libc (atexit, dladdr).
                .link_libc = opts.hash_stats,
                .imports = &.{.{ .name = "zig_options", .module = stats_options }},
            }),
        });
        unit_step.dependOn(&b.addRunArtifact(t).step);
    }
    // The hash microbenchmark reads the engine it is timing from here.
    const bench_opts = b.addOptions();
    bench_opts.addOption(bool, "zig_impl", opts.zig_impl);
    const bench_options = bench_opts.createModule();
    if (zig_impl) |impl| {
        if (opts.config_h == null) {
            // Test roots linked against libmoar: the shims, and the hash
            // engine's string table on real MVMStrings (plus the
            // microbenchmark's ladder test, hence build_options).
            const roots = [_]struct { []const u8, []const u8, []const std.Build.Module.Import }{
                .{ "src/zig/moar.zig", "shim-test", &.{} },
                .{ "src/zig/core/hash/hash_test.zig", "hash-str-test", &.{ .{ .name = "build_options", .module = bench_options }, .{ .name = "zig_options", .module = stats_options } } },
            };
            for (roots) |root| {
                const t = zigimpl.addShimTests(b, opts, impl, libmoar, config_h, moar.cflags(b, opts), root[0], root[1], root[2]);
                unit_step.dependOn(&b.addRunArtifact(t).step);
            }
        }
    }
    test_step.dependOn(unit_step);

    // `zig build strategy-test -Dnqp-prefix=<P>`: the hashstrategy op
    // tests (TAP) on an installed MoarVM + nqp, with <P>/lib
    // first on LD_LIBRARY_PATH so the installed libmoar is the one tested.
    // nqp's stage0 cannot compile the ops, hence the installed nqp-m.
    const strategy_step = b.step("strategy-test", "Run tools/bench/t/strategy.nqp on <P>/bin/nqp-m (needs -Dnqp-prefix=<P>)");
    if (opts.nqp_prefix) |prefix| {
        const nqp_m = b.pathJoin(&.{ prefix, "bin", "nqp-m" });
        const lib_dir = b.pathJoin(&.{ prefix, "lib" });
        const run = std.Build.Step.Run.create(b, "run strategy.nqp on the installed nqp");
        run.addFileArg(.{ .cwd_relative = nqp_m });
        run.addFileArg(b.path("tools/bench/t/strategy.nqp"));
        run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ lib_dir, if (opts.static) "libmoar.a" else "libmoar.so" }) });
        run.setEnvironmentVariable("LD_LIBRARY_PATH", lib_dir);
        run.setCwd(b.path("."));
        run.expectExitCode(0);
        strategy_step.dependOn(&run.step);
        test_step.dependOn(strategy_step);
    } else {
        const fail = b.addFail("strategy-test needs -Dnqp-prefix=<prefix of an installed MoarVM and nqp>");
        strategy_step.dependOn(&fail.step);
    }

    // `zig build hash-bench -- <args>`: the string table microbenchmark
    // against this build's libmoar, Zig engine or C tables as -Dzig-impl
    // says. With the Zig groups off the `moar` module is still needed for
    // the benchmark's keys and types, so the translation is set up here too.
    if (opts.config_h == null) {
        const bench_impl = zig_impl orelse zigimpl.add(b, opts, .{ .generated = config_h });
        const bench = zigimpl.addHashBench(b, opts, bench_impl, libmoar, config_h, moar.cflags(b, opts), bench_options, stats_options);
        const run = b.addRunArtifact(bench);
        if (b.args) |args| run.addArgs(args);
        const bench_step = b.step("hash-bench", "Run the string hash table microbenchmark against this build's engine (args after --: --sizes=, --runs=, --max-size=)");
        bench_step.dependOn(&run.step);
        // `zig build hash-bench-exe --prefix <P>` leaves <P>/bin/hash-bench
        // for tools/bench/hash-ab.sh (the C-API ladder under LD_LIBRARY_PATH).
        const bench_exe_step = b.step("hash-bench-exe", "Install the microbenchmark executable as <prefix>/bin/hash-bench");
        bench_exe_step.dependOn(&b.addInstallArtifact(bench, .{}).step);

        // `zig build uni-bench -- <args>` / `uni-bench-exe`: the same for the
        // four unicode tables (tools/bench/uni-bench.nqp is its nqp twin).
        const uni_bench = zigimpl.addUniBench(b, opts, bench_impl, libmoar, config_h, moar.cflags(b, opts), bench_options, stats_options);
        const uni_run = b.addRunArtifact(uni_bench);
        if (b.args) |args| uni_run.addArgs(args);
        const uni_step = b.step("uni-bench", "Run the unicode lookup table microbenchmark against this build's engine (args after --: --runs=, --ops=, --sample=)");
        uni_step.dependOn(&uni_run.step);
        const uni_exe_step = b.step("uni-bench-exe", "Install the unicode microbenchmark executable as <prefix>/bin/uni-bench");
        uni_exe_step.dependOn(&b.addInstallArtifact(uni_bench, .{}).step);
    }

    const tp_step = b.step("thirdparty", "Build the bundled third-party static libraries");
    for (tp.all()) |lib| tp_step.dependOn(&lib.step);

    const show_version = b.step("version", "Print the detected MoarVM version");
    show_version.dependOn(&b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch }).step);

    const config_h_step = b.step("config-h", "Render config.h into zig-out/config.h for inspection");
    config_h_step.dependOn(&b.addInstallFileWithDir(config_h.getOutputFile(), .prefix, "config.h").step);
}
