//! JIT code generation at build time: minilua runs DynASM over emit.dasc,
//! and the Zig ports of the Perl generators produce the expression template
//! and tiler tables. All of these run on the build host.
const std = @import("std");

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
        .optimize = .fast,
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
    const emit_c = run.addOutputFileArg2("emit.c", .{});
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

pub const Tools = struct {
    expr_compiler: *std.Build.Step.Compile,
    tiler: *std.Build.Step.Compile,
};

pub const Generated = struct {
    core_templates_h: std.Build.LazyPath,
    tile_pattern_h: std.Build.LazyPath,
    /// Directory laid out as jit/core_templates.h and jit/x64/tile_pattern.h,
    /// to be added to the include path before `src`.
    include_dir: std.Build.LazyPath,
};

pub const Jit = struct {
    dynasm: Dynasm,
    tools: Tools,
    gen: Generated,
};

fn hostTool(b: *std.Build, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .safe,
    });
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

pub fn addTools(b: *std.Build) Tools {
    return .{
        .expr_compiler = hostTool(b, "expr_template_compiler", "tools/zig/expr_template_compiler.zig"),
        .tiler = hostTool(b, "tiler_table_generator", "tools/zig/tiler_table_generator.zig"),
    };
}

/// Runs both generators from the repository root (the .expr `include:` paths
/// are cwd-relative) and collects their outputs into one include directory.
pub fn addGenerated(b: *std.Build, tools: Tools) Generated {
    const ec = b.addRunArtifact(tools.expr_compiler);
    ec.setCwd(b.path("."));
    ec.addArg("--oplist");
    ec.addFileArg2(b.path("src/core/oplist"), .{});
    ec.addArg("--expr-ops");
    ec.addFileArg2(b.path("src/jit/expr_ops.h"), .{});
    ec.addArg("-o");
    const core_templates_h = ec.addOutputFileArg2("core_templates.h", .{});
    ec.addFileArg2(b.path("src/jit/core_templates.expr"), .{});
    ec.addFileInput(b.path("src/jit/macro.expr"));

    const tt = b.addRunArtifact(tools.tiler);
    tt.setCwd(b.path("."));
    tt.addArg("--expr-ops");
    tt.addFileArg2(b.path("src/jit/expr_ops.h"), .{});
    tt.addArg("-o");
    const tile_pattern_h = tt.addOutputFileArg2("tile_pattern.h", .{});
    tt.addFileArg2(b.path("src/jit/x64/tile_pattern.tile"), .{});

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(core_templates_h, "jit/core_templates.h");
    _ = wf.addCopyFile(tile_pattern_h, "jit/x64/tile_pattern.h");

    return .{ .core_templates_h = core_templates_h, .tile_pattern_h = tile_pattern_h, .include_dir = wf.getDirectory() };
}

pub fn addAll(b: *std.Build) Jit {
    const tools = addTools(b);
    return .{ .dynasm = addDynasm(b), .tools = tools, .gen = addGenerated(b, tools) };
}

/// `zig build check-jit-tools`: runs the Perl generators and compares them
/// with the zig outputs (see tools/check-jit-tools.sh). Needs perl and sh.
pub fn addCheckStep(b: *std.Build, j: Jit) *std.Build.Step {
    const run = b.addSystemCommand(&.{ "sh", "tools/check-jit-tools.sh" });
    run.setCwd(b.path("."));
    run.addFileArg2(j.gen.core_templates_h, .{});
    run.addFileArg2(j.gen.tile_pattern_h, .{});
    run.addFileArg2(j.dynasm.emit_c, .{});
    run.has_side_effects = true;
    const step = b.step("check-jit-tools", "Compare the zig JIT generators with the Perl originals (needs perl)");
    step.dependOn(&run.step);
    return step;
}
