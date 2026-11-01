//! JIT code generation at build time: minilua runs DynASM over emit.dasc,
//! and the Zig ports of the Perl generators produce the expression template
//! and tiler tables. All of these run on the build host.
const std = @import("std");
const Options = @import("options.zig").Options;

pub const Dynasm = struct {
    minilua: *std.Build.Step.Compile,
    emit_c: std.Build.LazyPath,
};

/// Builds 3rdparty/dynasm/minilua.c for the host and runs
/// `minilua 3rdparty/dynasm/dynasm.lua -D POSIX=1 -o <cache>/emit.c src/jit/x64/emit.dasc`
/// from the repository root. Relative paths matter: dynasm writes them into
/// `#line` directives and resolves `|.include src/jit/x64/tiles.dasc` against
/// the cwd, and the Perl build uses the same relative paths.
pub fn addDynasm(b: *std.Build) Dynasm {
    const host = b.graph.host;
    const mod = b.createModule(.{
        .target = host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addCSourceFile(.{ .file = b.path("3rdparty/dynasm/minilua.c"), .flags = &.{} });
    mod.linkSystemLibrary("m", .{});
    const minilua = b.addExecutable(.{ .name = "minilua", .root_module = mod });

    const run = b.addRunArtifact(minilua);
    run.setCwd(b.path("."));
    run.addArg("3rdparty/dynasm/dynasm.lua");
    run.addArgs(&.{ "-D", "POSIX=1", "-o" });
    const emit_c = run.addOutputFileArg("emit.c");
    run.addArg("src/jit/x64/emit.dasc");
    // Inputs dynasm reads by relative path; registered so the cache sees them.
    for ([_][]const u8{
        "src/jit/x64/emit.dasc",
        "src/jit/x64/tiles.dasc",
        "3rdparty/dynasm/dynasm.lua",
        "3rdparty/dynasm/dasm_x64.lua",
        "3rdparty/dynasm/dasm_x86.lua",
    }) |p| run.addFileInput(b.path(p));

    return .{ .minilua = minilua, .emit_c = emit_c };
}
