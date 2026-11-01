const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");
const platform = @import("build/zig/platform.zig");
const config = @import("build/zig/config.zig");
const thirdparty = @import("build/zig/thirdparty.zig");
const moar = @import("build/zig/moar.zig");
const install = @import("build/zig/install.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    // The Perl build writes src/gen/config.h next to the sources. A quote
    // include searches the including file's directory first, so that file
    // would silently shadow the config.h this build generates.
    if (b.build_root.handle.access(b.graph.io, "src/gen/config.h", .{})) |_| {
        std.process.fatal(
            "src/gen/config.h exists (written by perl Configure.pl) and would shadow the zig-generated config.h.\n" ++
                "Remove the Perl-generated files first:  rm -f src/gen/config.h src/gen/config.c src/gen/config.o\n" ++
                "(perl Configure.pl recreates them when you go back to the Perl build.)",
            .{},
        );
    } else |_| {}
    const facts = platform.facts(&opts.target.result);
    const ver = version.detect(b);
    const lists = sources.load(b, "build/sources.list");

    const config_h = config.configHeader(b, .{ .opts = opts, .facts = facts, .version = ver });

    const tp = thirdparty.addAll(b, opts, facts);

    const paths = config.InstallPaths.fromBuild(b);
    const inputs: config.Inputs = .{ .opts = opts, .facts = facts, .version = ver };
    const config_c = config.configSource(b, inputs, paths, moar.cflags(b, opts));

    const libmoar = moar.addLibmoar(b, .{
        .opts = opts,
        .facts = facts,
        .lists = lists,
        .config_h = config_h,
        .config_c = config_c,
        .tp = tp,
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
    version_run.expectStdOutEqual(b.fmt("This is MoarVM version {s}\n", .{ver.full}));
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
    } else |_| {}

    // Unit tests of the build helpers; `test` runs them first.
    const unit_step = b.step("unit-test", "Run the unit tests of the build helpers");
    for ([_][]const u8{ "build/zig/sources.zig", "build/zig/version.zig", "build/zig/config.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        }) });
        unit_step.dependOn(&b.addRunArtifact(t).step);
    }
    test_step.dependOn(unit_step);

    const tp_step = b.step("thirdparty", "Build the bundled third-party static libraries");
    for (tp.all()) |lib| tp_step.dependOn(&lib.step);

    const show_version = b.step("version", "Print the detected MoarVM version");
    show_version.dependOn(&b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch }).step);

    const config_h_step = b.step("config-h", "Render config.h into zig-out/config.h for inspection");
    config_h_step.dependOn(&b.addInstallFileWithDir(config_h.getOutputFile(), .prefix, "config.h").step);
}
