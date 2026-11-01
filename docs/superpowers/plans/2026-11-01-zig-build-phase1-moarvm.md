# Zig Build Phase 1: MoarVM `build.zig` (no JIT, bundled 3rdparty, x86_64-linux)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `rakudo/docs/superpowers/specs/2026-11-01-zig-build-migration-design.md` (in the rakudo checkout two directories up), sections 5, 6, 9, 10 and phase 1 of section 11.

**Goal:** `zig build --prefix <abs dir> install` in the MoarVM checkout produces a working `moar` executable and `libmoar.so` that runs the committed nqp stage0 bytecode, with no Perl, make or system C compiler involved.

**Architecture:** One `build.zig` at the repo root wires together small helper modules under `build/zig/`. Compiler probes are replaced by a per-OS fact table, `config.h` is rendered from the existing `build/config.h.in` by zig's `ConfigHeader` step in `autoconf_at` style, `config.c` is rendered from `build/config.c.in` by a `WriteFile` step, the C object list moves to `build/sources.list` (read by both `build.zig` and, in the last task, `Configure.pl`), and each bundled third-party library becomes a static `Compile` step linked into `libmoar`.

**Tech Stack:** Zig 0.16.0 (`/usr/bin/zig`), `zig cc` (clang) as the only C compiler, system `libzstd` via pkg-config, Perl only in the final behaviour-preserving task.

## Global Constraints

- Zig version: exactly 0.16.0 is installed; `minimum_zig_version = "0.16.0"` in `build.zig.zon`.
- Side by side: the Perl path (`Configure.pl`, `build/Makefile.in`, `build/*.in`) must keep producing the same build. The only Perl-side change is Task 9, and it must be behaviour-preserving (verified by the object-list diff in that task).
- `zig cc` only. No probes. No `-Dcc`.
- Target in this phase: `x86_64-linux`. Any other target fails at configure time with a message pointing at `build/zig/platform.zig`.
- `-Djit` exists but `true` fails at configure time with a "phase 2" message. Default `false`.
- Options in this phase: `-Djit`, `-Dstatic`, `-Dmimalloc`, `-Dzstd`, plus zig's standard `-Dtarget`, `-Doptimize`, `--prefix`. The spec's `-Dsystem-libuv`, `-Dsystem-libtommath`, `-Dsystem-libffi` are deferred to phase 5 (bundled only here).
- Install prefix: zig's built-in `--prefix` (`-p`) replaces the spec's `-Dprefix`. Always pass an absolute path, because it is baked into the rpath and into `config.c`.
- C flags must match the Perl build: `-fwrapv -std=gnu99 -Wextra -Wall -Wno-unused-parameter -Wno-unused-function -Wno-missing-braces -Werror=pointer-arith -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -DMVM_TRACING=0 -DMVM_CGOTO=1 -DMVM_HEAPSNAPSHOT_FORMAT=<3|2>` plus `-DNDEBUG` outside Debug, `-DMVM_BUILD_SHARED` for every libmoar object, `-DMVM_SHARED` for `src/main.c` when libmoar is shared, and `-std=gnu11` instead of `-std=gnu99` for `3rdparty/zmij/zmij.c`.
- All C modules set `.sanitize_c = .off`. Zig enables UBSan traps for C in Debug/ReleaseSafe; MoarVM is not clean under that and gcc never did it.
- Commits go on branch `zig-build-phase1` in this MoarVM checkout. Commit message trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Working directory for every command below: the MoarVM checkout (`rakudo/nqp/MoarVM`). The scratch directory for temporary files is `/tmp/claude-1000/-home-longwalker-code-raku-x-core-zmoarz-rakudo-nqp-MoarVM/529300be-8495-4763-892d-134053416824/scratchpad`, referred to as `$SCRATCH` below.

## Reference facts (gathered from the Perl build on this machine)

- Perl-built artifacts exist in the checkout: `./moar`, `./libmoar.so`, `./Makefile`, `src/gen/config.h`, `src/gen/config.c`. Perl install prefix: `/home/longwalker/code/raku/x.core/zmoarz/rakudo/install`. Do not delete these; several tasks diff against them.
- `./moar --version` prints `This is MoarVM version 2026.09-39-g71a33965f built with JIT support`.
- Stage0 smoke test that must pass with the zig-built `moar`: `moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'say(1+1)'` prints `2`.
- `git describe --tags --match=20*` prints `2026.09-39-g71a33965f`; `VERSION` contains `2026.09`.
- The generated Makefile's `OBJECTS1`+`OBJECTS2` expand to 167 `src/**/*.c` files (including `src/gen/config.c`), plus `3rdparty/freebsd/memmem.c`, `3rdparty/zmij/zmij.c`, `3rdparty/mimalloc/src/static.c`, `$(PLATFORM_POSIX)` (4 files) and `$(JIT_OBJECTS) $(JIT_ARCH_X64)` (8 + 2 files). With JIT off, `$(JIT_STUB)` = `src/jit/stub.c` replaces the JIT objects.
- Third-party archives linked into `libmoar.so`: cmp, dyncall (dyncall_s, dyncallback_s, dynload_s), sha1, libtommath (all 154 `bn_*.c`), libuv. System libs: `-lm -lpthread -lrt -ldl -lzstd`.
- zig APIs confirmed in `/usr/lib/zig/std` (0.16.0): `b.addLibrary(.{ .linkage, .name, .root_module })`, `b.addExecutable(.{ .name, .root_module })`, `b.createModule(.{ .target, .optimize, .link_libc, .pic, .sanitize_c })`, `module.addCSourceFiles(.{ .root, .files, .flags })`, `module.addCSourceFile(.{ .file, .flags })`, `module.addIncludePath`, `module.addSystemIncludePath`, `module.addConfigHeader`, `module.linkLibrary`, `module.linkSystemLibrary(name, .{})`, `module.addRPath(LazyPath)`, `module.addRPathSpecial([]const u8)`, `b.addConfigHeader(.{ .style = .{ .autoconf_at = path }, .include_path = "..." }, values)` (errors on unused or missing values; strings and idents are written raw; bools render `0`/`1`), `b.addWriteFiles().add(name, bytes) -> LazyPath`, `b.addInstallFileWithDir(src, .{ .custom = "rel/dir" } | .lib | .bin, dest_rel)`, `compile.installHeadersDirectory(src, dest_rel, .{})` (defaults to `.h` only), `compile.installHeader(src, dest_rel)`, `b.installArtifact`, `b.install_prefix` (logical prefix, excludes DESTDIR), `b.build_root.handle.readFileAlloc(b.graph.io, sub_path, allocator, .unlimited)`, `b.build_root.handle.access(b.graph.io, sub_path, .{})`, `b.build_root.handle.openDir(b.graph.io, sub_path, .{ .iterate = true })` then `dir.iterate()` and `it.next(b.graph.io)`, `dir.close(b.graph.io)`, `b.runAllowFail(argv, &code, .ignore)`, `std.process.fatal(fmt, args)`, `std.ArrayList(T)` is unmanaged (`.empty`, `append(gpa, x)`, `toOwnedSlice(gpa)`), `std.StaticStringMap(V).initComptime(...)`, `std.mem.replaceOwned`.

## File structure

| Path | Responsibility |
|---|---|
| `build.zig` | Wiring only: parse options, call helpers, declare install and named steps |
| `build.zig.zon` | Package manifest, no dependencies |
| `.gitignore` | add `.zig-cache/` and `zig-out/` |
| `build/zig/options.zig` | `Options` struct and `parse(b)` with the phase-1 guards |
| `build/zig/sources.zig` | Parser for `build/sources.list` (`Lists`, `parse`, `load`) with unit tests |
| `build/sources.list` | C source list in sections, generated once from `build/Makefile.in`, then the single source of truth |
| `build/zig/version.zig` | `Version`, `parse(full)`, `detect(b)` (VERSION file then `git describe`) with unit tests |
| `build/zig/platform.zig` | `Facts` per OS (linux only now), libuv source sets, system libs |
| `build/zig/config.zig` | `configHeader` (config.h), `renderBackendConfig` + `configSource` (config.c), `pkgConfig` (moar.pc), `InstallPaths` |
| `build/zig/thirdparty.zig` | `base_cflags`, one `add*` per bundled library, `addAll` returning `Libs` |
| `build/zig/moar.zig` | `cflags`, `addIncludes`, `addLibmoar`, `addMoar` |
| `build/zig/install.zig` | `addAll`: headers, gdb script, MAST files, moar.pc |
| `docs/zig-build.md` | How to use the zig build, what it does not do yet |
| `build/Makefile.in`, `Configure.pl` | Task 9 only: read object lists from `build/sources.list` |

---

### Task 1: Scaffold the zig package and options

**Files:**
- Create: `build.zig.zon`
- Create: `build.zig`
- Create: `build/zig/options.zig`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `options.Options { target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, jit: bool, static: bool, mimalloc: bool, zstd: bool }` and `options.parse(b: *std.Build) Options`.

- [ ] **Step 1: Confirm the branch and zig version**

Run:
```bash
git rev-parse --abbrev-ref HEAD && zig version
```
Expected: `zig-build-phase1` and `0.16.0`. If the branch is not current, run `git checkout zig-build-phase1`.

- [ ] **Step 2: Add zig cache dirs to `.gitignore`**

Append to `.gitignore`:
```
# zig build
.zig-cache/
zig-out/
```

- [ ] **Step 3: Write `build.zig.zon`**

```zig
.{
    .name = .moarvm,
    .version = "2026.9.0",
    // Replaced in step 6 with the value zig prints.
    .fingerprint = 0x0,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "build",
        "src",
        "3rdparty",
        "lib",
        "tools",
        "VERSION",
    },
}
```

- [ ] **Step 4: Write `build/zig/options.zig`**

```zig
const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    jit: bool,
    static: bool,
    mimalloc: bool,
    zstd: bool,
};

pub fn parse(b: *std.Build) Options {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const jit = b.option(bool, "jit",
        "Build the JIT compiler (not yet supported by the zig build; default false)") orelse false;
    if (jit) std.process.fatal(
        "-Djit=true is not implemented by the zig build yet (phase 2 of the migration). " ++
            "Build with the default -Djit=false, or use perl Configure.pl for a JIT-enabled MoarVM.",
        .{},
    );

    return .{
        .target = target,
        .optimize = optimize,
        .jit = jit,
        .static = b.option(bool, "static",
            "Build libmoar as a static library (default: shared)") orelse false,
        .mimalloc = b.option(bool, "mimalloc",
            "Use the bundled mimalloc allocator (default true)") orelse true,
        .zstd = b.option(bool, "zstd",
            "Link the system libzstd and use heap snapshot format 3 (default true)") orelse true,
    };
}
```

- [ ] **Step 5: Write the minimal `build.zig`**

```zig
const std = @import("std");
const options = @import("build/zig/options.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    _ = opts;
}
```

- [ ] **Step 6: Fix the fingerprint**

Run:
```bash
zig build --help 2>&1 | head -30
```
Expected: an error mentioning the fingerprint, with a suggested value like `.fingerprint = 0x1234abcd5678ef90,`. Copy that exact value into `build.zig.zon`, replacing `0x0`. Re-run the command.
Expected: the help text lists `-Djit=[bool]`, `-Dstatic=[bool]`, `-Dmimalloc=[bool]`, `-Dzstd=[bool]` under "Project-Specific Options".

- [ ] **Step 7: Verify the JIT guard**

Run:
```bash
zig build -Djit=true; echo "exit=$?"
```
Expected: the "phase 2" message on stderr and `exit=1`.

- [ ] **Step 8: Commit**

```bash
git add .gitignore build.zig build.zig.zon build/zig/options.zig
git commit -m "Scaffold zig build: manifest, options, phase-1 guards

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Source list file and its parser

**Files:**
- Create: `build/zig/sources.zig`
- Create: `build/sources.list`

**Interfaces:**
- Produces: `sources.Lists { core, platform_posix, jit, jit_x64, jit_stub, main: []const []const u8 }`, `sources.parse(allocator, text) Error!Lists`, `sources.load(b, sub_path) Lists`.
- Section names in the file: `[core]`, `[platform-posix]`, `[jit]`, `[jit-x64]`, `[jit-stub]`, `[main]`.

- [ ] **Step 1: Write the failing tests and the public shape**

Create `build/zig/sources.zig`:
```zig
//! Reads build/sources.list: the C source list shared by build.zig and
//! (via Configure.pl) build/Makefile.in.
//!
//! Format: one path per line relative to the repo root, grouped under
//! `[section]` headers. Blank lines and lines starting with `#` are ignored.
const std = @import("std");

pub const Lists = struct {
    core: []const []const u8 = &.{},
    platform_posix: []const []const u8 = &.{},
    jit: []const []const u8 = &.{},
    jit_x64: []const []const u8 = &.{},
    jit_stub: []const []const u8 = &.{},
    main: []const []const u8 = &.{},
};

pub const Error = error{ UnknownSection, EntryOutsideSection, OutOfMemory };

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    _ = allocator;
    _ = text;
    return error.UnknownSection;
}

test "parse: sections, comments, blanks and surrounding whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\# comment
        \\[core]
        \\src/core/a.c
        \\
        \\  src/core/b.c  
        \\[jit-stub]
        \\src/jit/stub.c
        \\[main]
        \\src/main.c
    );
    try std.testing.expectEqual(@as(usize, 2), lists.core.len);
    try std.testing.expectEqualStrings("src/core/a.c", lists.core[0]);
    try std.testing.expectEqualStrings("src/core/b.c", lists.core[1]);
    try std.testing.expectEqual(@as(usize, 1), lists.jit_stub.len);
    try std.testing.expectEqualStrings("src/jit/stub.c", lists.jit_stub[0]);
    try std.testing.expectEqualStrings("src/main.c", lists.main[0]);
    try std.testing.expectEqual(@as(usize, 0), lists.jit.len);
    try std.testing.expectEqual(@as(usize, 0), lists.platform_posix.len);
}

test "parse: entry before any section is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EntryOutsideSection, parse(arena.allocator(), "src/x.c\n"));
}

test "parse: unknown section is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownSection, parse(arena.allocator(), "[bogus]\nsrc/x.c\n"));
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `zig test build/zig/sources.zig`
Expected: the first test fails (`error.UnknownSection` returned), others may pass by accident. At least one FAIL.

- [ ] **Step 3: Implement `parse` and `load`**

Replace the stub `parse` with:
```zig
const Section = enum { core, platform_posix, jit, jit_x64, jit_stub, main };

const section_names = std.StaticStringMap(Section).initComptime(.{
    .{ "core", .core },
    .{ "platform-posix", .platform_posix },
    .{ "jit", .jit },
    .{ "jit-x64", .jit_x64 },
    .{ "jit-stub", .jit_stub },
    .{ "main", .main },
});

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    var buckets = [_]std.ArrayList([]const u8){ .empty, .empty, .empty, .empty, .empty, .empty };
    var current: ?Section = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.UnknownSection;
            current = section_names.get(line[1..end]) orelse return error.UnknownSection;
            continue;
        }
        const section = current orelse return error.EntryOutsideSection;
        try buckets[@intFromEnum(section)].append(allocator, line);
    }

    return .{
        .core = try buckets[@intFromEnum(Section.core)].toOwnedSlice(allocator),
        .platform_posix = try buckets[@intFromEnum(Section.platform_posix)].toOwnedSlice(allocator),
        .jit = try buckets[@intFromEnum(Section.jit)].toOwnedSlice(allocator),
        .jit_x64 = try buckets[@intFromEnum(Section.jit_x64)].toOwnedSlice(allocator),
        .jit_stub = try buckets[@intFromEnum(Section.jit_stub)].toOwnedSlice(allocator),
        .main = try buckets[@intFromEnum(Section.main)].toOwnedSlice(allocator),
    };
}

/// Reads and parses `sub_path` relative to the build root at configure time.
pub fn load(b: *std.Build, sub_path: []const u8) Lists {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, sub_path, b.allocator, .unlimited) catch |err|
        std.process.fatal("cannot read {s}: {t}", .{ sub_path, err });
    return parse(b.allocator, text) catch |err|
        std.process.fatal("cannot parse {s}: {t}", .{ sub_path, err });
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig test build/zig/sources.zig`
Expected: `All 3 tests passed.`

- [ ] **Step 5: Generate `build/sources.list` from `build/Makefile.in`**

Run this once. `extract` prints a Makefile variable from its `NAME = ` line through its last backslash-continued line (several variables have no blank line between them, so a blank-line-terminated range would bleed into the next variable), keeps the `src/` entries, strips `@obj@` and appends `.c`:
```bash
extract() { awk -v v="$1" '$0 ~ "^"v" *= " {p=1} p { print; if ($0 !~ /\\$/) p=0 }' build/Makefile.in | tr -d '\\' | tr -s ' \n' '\n' | grep '^src/.*@obj@$' | sed 's/@obj@$/.c/'; }
{
  echo "# C sources of libmoar and moar, relative to the repository root."
  echo "# Read by build.zig (build/zig/sources.zig) and by Configure.pl to fill build/Makefile.in."
  echo "# One path per line under a [section]; '#' starts a comment."
  echo "# Third-party objects (memmem, zmij, mimalloc) and generated JIT files are handled by the builds, not listed here."
  echo
  echo "[core]"; extract OBJECTS1; extract OBJECTS2
  echo; echo "[platform-posix]"; extract PLATFORM_POSIX
  echo; echo "[jit]"; extract JIT_OBJECTS
  echo; echo "[jit-x64]"; extract JIT_ARCH_X64
  echo; echo "[jit-stub]"; extract JIT_STUB
  echo; echo "[main]"; extract MAIN_OBJECTS
} > build/sources.list
```

- [ ] **Step 6: Verify the counts**

Run:
```bash
awk '/^\[/{s=$0} /^src\//{c[s]++} END{for(k in c) print k, c[k]}' build/sources.list | sort
grep -c '^src/' build/sources.list
grep -n 'src/gen/config.c' build/sources.list
```
Expected:
```
[core] 167
[jit-stub] 1
[jit-x64] 2
[jit] 8
[main] 1
[platform-posix] 4
183
```
and one `src/gen/config.c` line under `[core]`. If `[core]` is not 167, compare against `grep -c '^src/.*@obj@' build/Makefile.in` restricted to the OBJECTS1/OBJECTS2 ranges and fix the extraction.

- [ ] **Step 7: Verify every listed file exists**

Run:
```bash
grep '^src/' build/sources.list | grep -v 'src/gen/config.c\|src/jit/x64/emit.c\|@nativecall_backend@' | while read f; do [ -f "$f" ] || echo "MISSING $f"; done; echo done
```
Expected: only `done`. (`src/gen/config.c` is generated; `src/jit/x64/emit.c` is generated by dynasm in phase 2; `src/core/nativecall_@nativecall_backend@.c` is a Makefile template entry that Task 6 expands.)

- [ ] **Step 8: Commit**

```bash
git add build/zig/sources.zig build/sources.list
git commit -m "Add build/sources.list and its zig parser

The list is extracted from build/Makefile.in and becomes the single
source of truth for the C object list once Configure.pl reads it too.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Version detection

**Files:**
- Create: `build/zig/version.zig`

**Interfaces:**
- Produces: `version.Version { full, major, minor, patch: []const u8 }`, `version.parse(full) Version`, `version.detect(b) Version`.
- Semantics copied from `Configure.pl` lines 128-143: default `0.0-0`; `VERSION` file; then `git describe --tags --match=20*` when `.git` exists. `major = /^(\d+)/`, `minor = /^\d+\.(\d+)/`, `patch = /^\d+\.\d+-(\d+)/`, each `"0"` if absent. Fields stay strings so `09` keeps its leading zero exactly like the Perl output.

- [ ] **Step 1: Write the failing tests**

Create `build/zig/version.zig`:
```zig
//! MoarVM version string, mirroring Configure.pl.
const std = @import("std");

pub const Version = struct {
    full: []const u8,
    major: []const u8,
    minor: []const u8,
    patch: []const u8,
};

pub fn parse(full: []const u8) Version {
    return .{ .full = full, .major = "0", .minor = "0", .patch = "0" };
}

test "parse: git describe output" {
    const v = parse("2026.09-39-g71a33965f");
    try std.testing.expectEqualStrings("2026.09-39-g71a33965f", v.full);
    try std.testing.expectEqualStrings("2026", v.major);
    try std.testing.expectEqualStrings("09", v.minor);
    try std.testing.expectEqualStrings("39", v.patch);
}

test "parse: release tag without patch" {
    const v = parse("2026.09");
    try std.testing.expectEqualStrings("2026", v.major);
    try std.testing.expectEqualStrings("09", v.minor);
    try std.testing.expectEqualStrings("0", v.patch);
}

test "parse: fallback and garbage" {
    const d = parse("0.0-0");
    try std.testing.expectEqualStrings("0", d.major);
    try std.testing.expectEqualStrings("0", d.minor);
    try std.testing.expectEqualStrings("0", d.patch);
    const g = parse("garbage");
    try std.testing.expectEqualStrings("0", g.major);
    try std.testing.expectEqualStrings("0", g.minor);
    try std.testing.expectEqualStrings("0", g.patch);
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `zig test build/zig/version.zig`
Expected: the first two tests FAIL (major is `"0"` instead of `"2026"`).

- [ ] **Step 3: Implement `parse` and `detect`**

Replace `parse` and add `detect`:
```zig
pub fn parse(full: []const u8) Version {
    var v: Version = .{ .full = full, .major = "0", .minor = "0", .patch = "0" };

    const major_end = digitsEnd(full, 0);
    if (major_end == 0) return v;
    v.major = full[0..major_end];

    if (major_end >= full.len or full[major_end] != '.') return v;
    const minor_end = digitsEnd(full, major_end + 1);
    if (minor_end == major_end + 1) return v;
    v.minor = full[major_end + 1 .. minor_end];

    if (minor_end >= full.len or full[minor_end] != '-') return v;
    const patch_end = digitsEnd(full, minor_end + 1);
    if (patch_end == minor_end + 1) return v;
    v.patch = full[minor_end + 1 .. patch_end];

    return v;
}

fn digitsEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i;
}

/// VERSION file, then `git describe --tags --match=20*` if this is a git checkout.
pub fn detect(b: *std.Build) Version {
    var full: []const u8 = "0.0-0";

    if (b.build_root.handle.readFileAlloc(b.graph.io, "VERSION", b.allocator, .unlimited)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) full = trimmed;
    } else |_| {}

    if (b.build_root.handle.access(b.graph.io, ".git", .{})) |_| {
        var code: u8 = 0;
        const argv = [_][]const u8{
            "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--match=20*",
        };
        if (b.runAllowFail(&argv, &code, .ignore)) |out| {
            const trimmed = std.mem.trim(u8, out, " \t\r\n");
            if (code == 0 and trimmed.len > 0) full = trimmed;
        } else |_| {}
    } else |_| {}

    return parse(full);
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig test build/zig/version.zig`
Expected: `All 3 tests passed.`

- [ ] **Step 5: Wire a `version` named step into `build.zig` for a manual check**

Edit `build.zig`:
```zig
const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    const lists = sources.load(b, "build/sources.list");
    const ver = version.detect(b);
    _ = opts;
    _ = lists;

    const show = b.step("version", "Print the detected MoarVM version");
    const echo = b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch });
    show.dependOn(&echo.step);
}
```

Run: `zig build version`
Expected output line: `2026.09-39-g71a33965f 2026 09 39` (the git hash part will differ if HEAD moved).

- [ ] **Step 6: Commit**

```bash
git add build/zig/version.zig build.zig
git commit -m "zig build: detect MoarVM version like Configure.pl

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Platform facts and `config.h`

**Files:**
- Create: `build/zig/platform.zig`
- Create: `build/zig/config.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `options.Options`, `version.Version`.
- Produces: `platform.Facts` (fields below), `platform.facts(target: *const std.Target) Facts` (pointer because `std.Target.ptrBitWidth` takes `*const Target`), `platform.libuv_unix_sources`, `config.Inputs { opts, facts, version }`, `config.configHeader(b, in) *std.Build.Step.ConfigHeader` whose `include_path` is `gen/config.h` so that `#include "gen/config.h"` in `src/moar.h` resolves.

- [ ] **Step 1: Write `build/zig/platform.zig`**

```zig
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
    if (target.cpu.arch != .x86_64) std.process.fatal(
        "the zig build does not support CPU architecture '{s}' yet (only x86_64 in phase 1).",
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
    "strscpy.c",       "strtok.c",         "fs-poll.c",      "inet.c",
    "uv-common.c",     "version.c",        "timer.c",        "threadpool.c",
    "unix/async.c",    "unix/core.c",      "unix/dl.c",      "unix/fs.c",
    "unix/getaddrinfo.c", "unix/loop-watcher.c", "unix/loop.c", "unix/pipe.c",
    "unix/poll.c",     "unix/process.c",   "unix/signal.c",  "unix/stream.c",
    "unix/tcp.c",      "unix/thread.c",    "unix/tty.c",     "unix/udp.c",
};
```

- [ ] **Step 2: Write `build/zig/config.zig` with `configHeader`**

```zig
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
```

- [ ] **Step 3: Wire a `config-h` step in `build.zig` that installs the header for inspection**

Replace the body of `build.zig` with:
```zig
const std = @import("std");
const options = @import("build/zig/options.zig");
const sources = @import("build/zig/sources.zig");
const version = @import("build/zig/version.zig");
const platform = @import("build/zig/platform.zig");
const config = @import("build/zig/config.zig");

pub fn build(b: *std.Build) void {
    const opts = options.parse(b);
    const facts = platform.facts(&opts.target.result);
    const ver = version.detect(b);
    const lists = sources.load(b, "build/sources.list");
    _ = lists;

    const config_h = config.configHeader(b, .{ .opts = opts, .facts = facts, .version = ver });

    const show_version = b.step("version", "Print the detected MoarVM version");
    show_version.dependOn(&b.addSystemCommand(&.{ "echo", ver.full, ver.major, ver.minor, ver.patch }).step);

    const config_h_step = b.step("config-h", "Render config.h into zig-out/config.h for inspection");
    config_h_step.dependOn(&b.addInstallFileWithDir(config_h.getOutputFile(), .prefix, "config.h").step);
}
```

- [ ] **Step 4: Render and diff against the Perl-generated header**

Run:
```bash
zig build config-h && diff src/gen/config.h zig-out/config.h; echo "diff exit=$?"
```
Expected: exactly four changed lines and `diff exit=1`. Two are the JIT lines, because the zig build has JIT off:
```
< #define MVM_JIT_ARCH MVM_JIT_ARCH_X64
< #define MVM_JIT_PLATFORM MVM_JIT_PLATFORM_POSIX
---
> #define MVM_JIT_ARCH MVM_JIT_ARCH_NONE
> #define MVM_JIT_PLATFORM MVM_JIT_PLATFORM_NONE
```
The other two are `MVM_VERSION` and `MVM_VERSION_PATCH`: the Perl header was generated at `2026.09-39-g71a33965f`, and this branch has added commits since, so `git describe` now reports a higher patch number and a different hash (compare with `git describe --tags --match=20*`). Any other difference is a defect. If the step fails with "unspecified config header value" or "config header value unused", a name in `configHeader` does not match `build/config.h.in`; fix the name. If a `#define` line differs in whitespace, the Perl value has trailing spaces (`MVM_NO_RETURN ` and `MVM_VECTORIZE_LOOP ` do); zig's autoconf_at writer preserves the template's text, so a difference there means the template changed; accept it only if the Perl output has the same bytes.

- [ ] **Step 5: Check the unsupported-target guard**

Run: `zig build config-h -Dtarget=aarch64-linux; echo "exit=$?"`
Expected: message naming `aarch64` and `build/zig/platform.zig`, `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add build/zig/platform.zig build/zig/config.zig build.zig
git commit -m "zig build: render config.h from build/config.h.in via a per-OS fact table

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Bundled third-party libraries

**Files:**
- Create: `build/zig/thirdparty.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `options.Options`, `platform.Facts`, `platform.libuv_unix_sources`.
- Produces: `thirdparty.base_cflags: [N][]const u8`, `thirdparty.Libs { uv, tommath, dyncall, sha1, cmp: *std.Build.Step.Compile }`, `thirdparty.addAll(b, opts, facts) Libs`, `thirdparty.newCModule(b, opts) *std.Build.Module`, `thirdparty.globC(b, dir_rel) []const []const u8`.

- [ ] **Step 1: Write `build/zig/thirdparty.zig`**

```zig
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
```

- [ ] **Step 2: Add a `thirdparty` named step to `build.zig`**

Add after the `config_h` line in `build.zig`:
```zig
    const tp = thirdparty.addAll(b, opts, facts);

    const tp_step = b.step("thirdparty", "Build the bundled third-party static libraries");
    for (tp.all()) |lib| tp_step.dependOn(&lib.step);
```
and the import at the top:
```zig
const thirdparty = @import("build/zig/thirdparty.zig");
```

- [ ] **Step 3: Build them**

Run: `zig build thirdparty --summary all 2>&1 | tail -15`
Expected: `Build Summary: ... steps succeeded` with five `zig build-lib` lines (uv, tommath, dyncall, sha1, cmp) and no `error:` lines. Warnings from mimalloc, libuv or dyncall are acceptable (the Perl build emits them too). If `dyncall_call.S` fails to assemble, check that the error is not an unknown directive: the smoke test during planning assembled both `.S` files with `zig cc -c -fPIC`.

- [ ] **Step 4: Confirm the libtommath glob picked up all 154 files**

Run:
```bash
ls 3rdparty/libtommath/*.c | wc -l
```
Expected: `154`. (The build above compiled them; this confirms the count matches `TOM_OBJECTS` in the generated Makefile, which also lists 154.)

- [ ] **Step 5: Commit**

```bash
git add build/zig/thirdparty.zig build.zig
git commit -m "zig build: compile the bundled third-party libraries as static libs

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `libmoar`

**Files:**
- Create: `build/zig/moar.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `thirdparty.base_cflags`, `thirdparty.newCModule`, `thirdparty.Libs`, `sources.Lists`, `config.configHeader` result.
- Produces: `moar.heapSnapshotFormat(opts) u8`, `moar.cflags(b, opts) []const []const u8`, `moar.addIncludes(b, mod)`, `moar.LibInputs`, `moar.addLibmoar(b, in) *Compile`. Task 7 adds `moar.addMoar`.
- `config_c` is a `std.Build.LazyPath` to the generated `config.c`. Until Task 7 provides it, this task passes the Perl-generated `src/gen/config.c` so the library links; Task 7 swaps it.
- `build/sources.list` `[core]` contains one Makefile template entry, `src/core/nativecall_@nativecall_backend@.c` (Configure.pl expands it multi-pass; the Perl side needs nothing). `resolveCoreSources` expands it to `dyncall` for the zig build and drops `src/gen/config.c`.

- [ ] **Step 1: Write `build/zig/moar.zig`**

```zig
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
```

- [ ] **Step 2: Document the template entry in `build/sources.list`**

Add this line to the header comment block at the top of `build/sources.list` (after the line about third-party objects):
```
# Entries may use Makefile template variables; today only src/core/nativecall_@nativecall_backend@.c (dyncall or libffi). build.zig expands it to dyncall.
```

- [ ] **Step 3: Wire `libmoar` into `build.zig`, temporarily using the Perl-generated config.c**

Add the import `const moar = @import("build/zig/moar.zig");` and, after the `tp` lines:
```zig
    const libmoar = moar.addLibmoar(b, .{
        .opts = opts,
        .facts = facts,
        .lists = lists,
        .config_h = config_h,
        .config_c = b.path("src/gen/config.c"), // Task 7 replaces this with the generated file
        .tp = tp,
    });
    b.installArtifact(libmoar);
```
and remove the `_ = lists;` line.

- [ ] **Step 4: Build**

Run: `zig build --summary all 2>&1 | grep -E "error|Build Summary|steps succeeded" | head`
Expected: `Build Summary: N/N steps succeeded`, no `error:` lines. Typical first-time failures and their fixes:
- `'gen/config.h' file not found`: `mod.addConfigHeader(in.config_h)` missing or `include_path` is not `gen/config.h`.
- `undefined symbol: ZSTD_...`: `-Dzstd` is on but libzstd is not found; install `zstd` dev package or pass `-Dzstd=false`.
- `undefined symbol: MVM_jit_...`: `jit_stub` list empty; check `[jit-stub]` in `build/sources.list`.

- [ ] **Step 5: Verify the library**

Run:
```bash
ls -la zig-out/lib/libmoar.so && nm -D zig-out/lib/libmoar.so | grep -c " T MVM_"
```
Expected: the file exists and the symbol count is in the thousands (the Perl `libmoar.so` reports about the same: `nm -D libmoar.so | grep -c " T MVM_"`).

- [ ] **Step 6: Commit**

```bash
git add build/zig/moar.zig build.zig
git commit -m "zig build: build libmoar from build/sources.list

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Generated `config.c`, the `moar` executable, and the smoke test

**Files:**
- Modify: `build/zig/config.zig` (add `InstallPaths`, `Entry`, `renderBackendConfig`, `backendEntries`, `configSource`)
- Modify: `build/zig/moar.zig` (add `addMoar`)
- Modify: `build.zig`

**Interfaces:**
- Produces: `config.InstallPaths { prefix, bindir, libdir, mastdir: []const u8 }` with `InstallPaths.fromBuild(b)`, `config.Entry { key, value }`, `config.renderBackendConfig(allocator, template, entries) ![]u8` (pure, tested), `config.configSource(b, in, paths) std.Build.LazyPath`, `moar.addMoar(b, opts, libmoar, lists, config_h, paths) *Compile`.
- `zig build test` runs `moar --version` and the nqp stage0 smoke test.

- [ ] **Step 1: Write the failing test for `renderBackendConfig`**

Append to `build/zig/config.zig`:
```zig
pub const Entry = struct { key: []const u8, value: []const u8 };

/// Replaces `@backendconfig@` in `template` (build/config.c.in) with one
/// `add_entry(tc, config, "key", "value");` line per entry, C-escaped.
pub fn renderBackendConfig(allocator: std.mem.Allocator, template: []const u8, entries: []const Entry) ![]u8 {
    _ = entries;
    return allocator.dupe(u8, template);
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
```

- [ ] **Step 2: Run the test to see it fail**

Run: `zig test build/zig/config.zig`
Expected: FAIL (output still contains `@backendconfig@`).

- [ ] **Step 3: Implement `renderBackendConfig`, `InstallPaths`, `backendEntries`, `configSource`**

Replace the stub with:
```zig
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

/// Where things end up at `zig build install`. Uses the logical prefix
/// (`--prefix`), not the DESTDIR-adjusted path, because these strings are
/// baked into the binary.
pub const InstallPaths = struct {
    prefix: []const u8,
    bindir: []const u8,
    libdir: []const u8,
    mastdir: []const u8,

    pub fn fromBuild(b: *std.Build) InstallPaths {
        const prefix = b.install_prefix;
        return .{
            .prefix = prefix,
            .bindir = b.pathJoin(&.{ prefix, "bin" }),
            .libdir = b.pathJoin(&.{ prefix, "lib" }),
            .mastdir = b.pathJoin(&.{ prefix, "share", "nqp", "lib", "MAST" }),
        };
    }
};

fn boolStr(v: bool) []const u8 {
    return if (v) "1" else "0";
}

/// The nqp::backendconfig hash. Keys follow the Perl build's src/gen/config.c;
/// values describe the zig toolchain. Consumers known today: nqp-configure
/// reads `make` and `osname`; Rakudo reads `prefix` and `osname`; the
/// rakudo/nqp Makefile templates read exe, obj, ccout, ldout, prefix,
/// ccswitch, ccinc, libdir, lddir, ld, cflags, cc, cincludes, ldshared,
/// ldlibs, ccshared, bindir.
pub fn backendEntries(b: *std.Build, in: Inputs, paths: InstallPaths, cflags: []const []const u8) []const Entry {
    const opt_flags: []const u8 = if (in.opts.optimize == .Debug) "-g3" else "-O3 -DNDEBUG";
    const ldlibs: []const u8 = if (in.opts.zstd) "-lm -lpthread -lrt -ldl -lzstd" else "-lm -lpthread -lrt -ldl";
    const cflags_str = std.mem.join(b.allocator, " ", cflags) catch @panic("OOM");
    const config_str = b.fmt("zig build -Djit={} -Dstatic={} -Dmimalloc={} -Dzstd={} -Doptimize={s}", .{
        in.opts.jit, in.opts.static, in.opts.mimalloc, in.opts.zstd, @tagName(in.opts.optimize),
    });
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
        .{ .key = "ldflags", .value = "" },
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

/// config.c rendered from build/config.c.in at configure time.
pub fn configSource(b: *std.Build, in: Inputs, paths: InstallPaths, cflags: []const []const u8) std.Build.LazyPath {
    const template = b.build_root.handle.readFileAlloc(b.graph.io, "build/config.c.in", b.allocator, .unlimited) catch |err|
        std.process.fatal("cannot read build/config.c.in: {t}", .{err});
    const text = renderBackendConfig(b.allocator, template, backendEntries(b, in, paths, cflags)) catch @panic("OOM");
    return b.addWriteFiles().add("config.c", text);
}
```

- [ ] **Step 4: Run the unit test to see it pass**

Run: `zig test build/zig/config.zig`
Expected: `All 1 tests passed.`

- [ ] **Step 5: Add `addMoar` to `build/zig/moar.zig`**

Append:
```zig
const config = @import("config.zig");

pub fn addMoar(
    b: *std.Build,
    opts: Options,
    libmoar: *std.Build.Step.Compile,
    lists: sources.Lists,
    config_h: *std.Build.Step.ConfigHeader,
    paths: config.InstallPaths,
) *std.Build.Step.Compile {
    const mod = thirdparty.newCModule(b, opts);
    const exe = b.addExecutable(.{ .name = "moar", .root_module = mod });
    addIncludes(b, mod);
    mod.addConfigHeader(config_h);

    const base = cflags(b, opts);
    const flags = if (opts.static) base else withFlag(b, base, "-DMVM_SHARED");
    mod.addCSourceFiles(.{ .files = lists.main, .flags = flags });
    mod.linkLibrary(libmoar);

    if (!opts.static) {
        // Find libmoar.so both from the install prefix (like the Perl
        // build's -Wl,-rpath,$(LIBDIR)) and relative to the binary.
        mod.addRPath(.{ .cwd_relative = paths.libdir });
        mod.addRPathSpecial("$ORIGIN/../lib");
    }
    return exe;
}
```

- [ ] **Step 6: Wire everything in `build.zig` and add the `test` step**

Replace the `libmoar` block in `build.zig` with:
```zig
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

    // `zig build test`: moar --version plus the nqp stage0 smoke test.
    // MoarVM has no C test suite of its own; NQP's tests cover it.
    const test_step = b.step("test", "Run moar --version and the nqp stage0 smoke test");
    const version_run = b.addRunArtifact(exe);
    version_run.addArg("--version");
    version_run.expectStdOutEqual(b.fmt("This is MoarVM version {s}\n", .{ver.full}));
    test_step.dependOn(&version_run.step);

    const stage0 = b.option([]const u8, "nqp-stage0",
        "Directory with nqp's stage0 .moarvm files for `zig build test` (default ../src/vm/moar/stage0)") orelse
        "../src/vm/moar/stage0";
    if (b.build_root.handle.access(b.graph.io, stage0, .{})) |_| {
        const smoke = b.addRunArtifact(exe);
        smoke.addArg(b.fmt("--libpath={s}", .{stage0}));
        smoke.addArg(b.pathJoin(&.{ stage0, "nqp.moarvm" }));
        smoke.addArgs(&.{ "-e", "say(1+1)" });
        smoke.expectStdOutEqual("2\n");
        smoke.setCwd(b.path("."));
        test_step.dependOn(&smoke.step);
    } else |_| {}
```
Also make `config` passed into `moar.zig` compile: `build/zig/moar.zig` now imports `config.zig`, which imports `options.zig`, `platform.zig`, `version.zig`; no cycles.

Also replace the earlier `const config_h_step ...` block so `config-h` still works (keep it; it is useful).

- [ ] **Step 7: Build and run the tests**

Run:
```bash
zig build && zig-out/bin/moar --version && zig build test --summary all 2>&1 | tail -5
```
Expected:
```
This is MoarVM version 2026.09-39-g71a33965f
Build Summary: ... steps succeeded
```
Note the version line has no " built with JIT support" suffix: JIT is off. If `moar --version` fails with `libmoar.so: cannot open shared object file`, the `$ORIGIN/../lib` rpath is missing; check `readelf -d zig-out/bin/moar | grep -i rpath`.

- [ ] **Step 8: Run the stage0 smoke test by hand too**

Run:
```bash
zig-out/bin/moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'say(1+1)'
```
Expected: `2`.

- [ ] **Step 9: Check `config.c` content**

Run:
```bash
grep -o '"prefix", "[^"]*"' $(find .zig-cache -name config.c | head -1)
```
Expected: `"prefix", "/home/longwalker/code/raku/x.core/zmoarz/rakudo/nqp/MoarVM/zig-out"` (the default prefix).

- [ ] **Step 10: Commit**

```bash
git add build/zig/config.zig build/zig/moar.zig build.zig
git commit -m "zig build: generate config.c, link the moar executable, add zig build test

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Install layout and `moar.pc`

**Files:**
- Create: `build/zig/install.zig`
- Modify: `build/zig/config.zig` (add `pkgConfig`)
- Modify: `build.zig`

**Interfaces:**
- Consumes: `libmoar`, `config_h`, `config.InstallPaths`, `version.Version`.
- Produces: `config.pkgConfig(b, ver, paths) std.Build.LazyPath`, `install.addAll(b, libmoar, config_h, pc)`.
- Resulting layout under the prefix, matching the Perl `make install` for the moar backend: `bin/moar`, `lib/libmoar.so`, `lib/libmoar.so-gdb.py`, `lib/pkgconfig/moar.pc`, `share/nqp/lib/MAST/{Nodes,Ops}.nqp`, `include/moar/**/*.h` (incl. `include/moar/config.h` and `include/moar/gen/config.h`), `include/libuv/**`, `include/libtommath/*.h`, `include/dyncall/*.h`, `include/mimalloc/*.h`, `include/zmij/zmij-c.h`.

- [ ] **Step 1: Add `pkgConfig` to `build/zig/config.zig`**

```zig
/// pkgconfig/moar.pc, mirroring build/mk-moar-pc.in for a non-/usr prefix.
pub fn pkgConfig(b: *std.Build, ver: Version, paths: InstallPaths) std.Build.LazyPath {
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
    return b.addWriteFiles().add("moar.pc", text);
}
```

- [ ] **Step 2: Write `build/zig/install.zig`**

```zig
//! Everything `zig build install` puts under the prefix besides the two
//! artifacts (bin/moar, lib/libmoar.so), mirroring the `install:` target of
//! build/Makefile.in for the moar backend.
const std = @import("std");

pub fn addAll(
    b: *std.Build,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    pc: std.Build.LazyPath,
) void {
    // Headers travel with libmoar so dependents (nqp's build.zig, phase 3)
    // get them on their include path by linking the artifact.
    libmoar.installHeadersDirectory(b.path("src"), "moar", .{});
    libmoar.installHeader(config_h.getOutputFile(), "moar/config.h");
    libmoar.installHeader(config_h.getOutputFile(), "moar/gen/config.h");
    libmoar.installHeadersDirectory(b.path("3rdparty/libuv/include"), "libuv", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/libtommath"), "libtommath", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dyncall"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dyncallback"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/dyncall/dynload"), "dyncall", .{});
    libmoar.installHeadersDirectory(b.path("3rdparty/mimalloc/include"), "mimalloc", .{});
    libmoar.installHeader(b.path("3rdparty/zmij/zmij-c.h"), "zmij/zmij-c.h");

    const install = b.getInstallStep();
    install.dependOn(&b.addInstallFileWithDir(b.path("tools/libmoar.so-gdb.py"), .lib, "libmoar.so-gdb.py").step);
    install.dependOn(&b.addInstallFileWithDir(b.path("lib/MAST/Nodes.nqp"), .{ .custom = "share/nqp/lib/MAST" }, "Nodes.nqp").step);
    install.dependOn(&b.addInstallFileWithDir(b.path("lib/MAST/Ops.nqp"), .{ .custom = "share/nqp/lib/MAST" }, "Ops.nqp").step);
    install.dependOn(&b.addInstallFileWithDir(pc, .{ .custom = "lib/pkgconfig" }, "moar.pc").step);
}
```

- [ ] **Step 3: Wire it in `build.zig`**

Add `const install = @import("build/zig/install.zig");` and, right after the two `b.installArtifact` calls:
```zig
    install.addAll(b, libmoar, config_h, config.pkgConfig(b, ver, paths));
```

- [ ] **Step 4: Install to a scratch prefix and compare with the Perl install**

Run:
```bash
P=$SCRATCH/inst; rm -rf "$P"; zig build --prefix "$P" install && \
( cd /home/longwalker/code/raku/x.core/zmoarz/rakudo/install && find bin/moar lib/libmoar.so lib/libmoar.so-gdb.py lib/pkgconfig/moar.pc share/nqp/lib/MAST include/moar include/libuv include/libtommath include/dyncall include/mimalloc include/zmij -type f | sort ) > $SCRATCH/perl-files.txt; \
( cd "$P" && find . -type f | sed 's|^\./||' | sort ) > $SCRATCH/zig-files.txt; \
echo "in Perl install but missing from zig install:"; comm -23 $SCRATCH/perl-files.txt $SCRATCH/zig-files.txt
```
Expected: the "missing" list is empty. Extra files in the zig install are acceptable (it installs every `.h` under `src/` recursively, the Perl install picks directories by hand). If `include/moar/gen/config.h` is listed as missing, check the second `installHeader` call.

- [ ] **Step 5: Verify the installed binary runs from the prefix and the rpath points there**

Run:
```bash
P=$SCRATCH/inst; "$P/bin/moar" --version && readelf -d "$P/bin/moar" | grep -i 'runpath\|rpath' && grep '^prefix=' "$P/lib/pkgconfig/moar.pc" && grep -o '"prefix", "[^"]*"' $(find .zig-cache -name config.c -newer build.zig | head -1)
```
Expected: the version line, an RPATH/RUNPATH containing `$P/lib` and `$ORIGIN/../lib`, `prefix=$P` in the .pc file, and `"prefix", "$P"` in config.c.

- [ ] **Step 6: Commit**

```bash
git add build/zig/install.zig build/zig/config.zig build.zig
git commit -m "zig build: install headers, MAST files, gdb helper and moar.pc like make install

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Make `Configure.pl` read `build/sources.list` (behaviour-preserving)

**Files:**
- Modify: `build/Makefile.in` lines 61-64 (`PLATFORM_POSIX`), 68-78 (`JIT_ARCH_X64`, `JIT_STUB`, `JIT_OBJECTS`), 86 (`MAIN_OBJECTS`), 89-260 (`OBJECTS1`, `OBJECTS2`)
- Modify: `Configure.pl` (add `read_sources_list`, `objlist`, and six `$config{objects_*}` entries before `generate` is called at line 818)

**Interfaces:**
- `Configure.pl` substitution is multi-pass (`sub configure`, line 1004, loops while any `@word@` remains), so values may contain `@obj@`.
- New template variables: `@objects_core@`, `@objects_platform_posix@`, `@objects_jit@`, `@objects_jit_x64@`, `@objects_jit_stub@`, `@objects_main@`.

- [ ] **Step 1: Record the current object list from the existing generated Makefile**

Run:
```bash
cp Makefile $SCRATCH/Makefile.before
make -n -W src/moar.o libmoar.so | tr ' ' '\n' | grep '\.o$' | sort > $SCRATCH/objs.before.txt
make -n -W src/main.o moar | tr ' ' '\n' | grep '\.o$' | sort > $SCRATCH/main-objs.before.txt
wc -l $SCRATCH/objs.before.txt $SCRATCH/main-objs.before.txt
```
Expected: about 180 and 1 lines respectively (the exact count is what matters for the comparison later).

- [ ] **Step 2: Edit `build/Makefile.in`**

Replace the `PLATFORM_POSIX = ...` block (4 lines) with:
```
PLATFORM_POSIX = @objects_platform_posix@
```
Replace `JIT_ARCH_X64 = ...`, `JIT_STUB = ...` and the `JIT_OBJECTS = ...` block with:
```
JIT_ARCH_X64 = @objects_jit_x64@
JIT_STUB     = @objects_jit_stub@
JIT_OBJECTS  = @objects_jit@
```
Replace `MAIN_OBJECTS = src/main@obj@` with:
```
MAIN_OBJECTS = @objects_main@
```
Replace everything from `OBJECTS1 = src/core/callsite@obj@ \` through the line `src/moar@obj@ \` (the last `src/` entry of OBJECTS2) with:
```
OBJECTS1 = @objects_core@
OBJECTS2 = 3rdparty/freebsd/memmem@obj@ \
          @zmij_object@ \
          @mimalloc_object@ \
```
so that `OBJECTS2` continues with the existing `@platform@` and `@jit_obj@` lines. Keep `PLATFORM_WIN32`, `JIT_INTERMEDIATES`, `JIT_PERL_LIBS`, `OBJECTS = $(OBJECTS1) $(OBJECTS2)` and `HEADERS` untouched. Confirm with:
```bash
grep -n '^src/.*@obj@\|^ *src/.*@obj@ \\$' build/Makefile.in | grep -v 'win32' | head
```
Expected: no `src/` object lines remain except the `PLATFORM_WIN32` ones.

- [ ] **Step 3: Add the reader to `Configure.pl`**

Insert immediately before the `for` loop that calls `generate($target, $_)` (around line 810-818; find it with `grep -n 'generate(\$target' Configure.pl`):
```perl
# Object lists are shared with build.zig through build/sources.list.
{
    my %sections = read_sources_list('build/sources.list');
    $config{objects_core}           = objlist($sections{'core'});
    $config{objects_platform_posix} = objlist($sections{'platform-posix'});
    $config{objects_jit}            = objlist($sections{'jit'});
    $config{objects_jit_x64}        = objlist($sections{'jit-x64'});
    $config{objects_jit_stub}       = objlist($sections{'jit-stub'});
    $config{objects_main}           = objlist($sections{'main'});
}
```
and add these subs near `sub generate` (after line 1030):
```perl
# Parse build/sources.list: '[section]' headers, one path per line,
# '#' comments and blank lines ignored.
sub read_sources_list {
    my ($file) = @_;
    open my $fh, '<', $file or hardfail("cannot open $file: $!");
    my (%sections, $current);
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        if ($line =~ /^\[(.+)\]$/) {
            $current = $1;
            $sections{$current} ||= [];
            next;
        }
        hardfail("$file: entry '$line' before any [section]") unless defined $current;
        push @{ $sections{$current} }, $line;
    }
    close $fh;
    return %sections;
}

# Turn a list of .c paths into Makefile object entries, one per line.
sub objlist {
    my ($files) = @_;
    return join " \\\n          ", map { my $f = $_; $f =~ s/\.c$//; "$f\@obj\@" } @{ $files || [] };
}
```

- [ ] **Step 4: Regenerate the Makefile with Perl and compare the object lists**

Run (same options as the recorded `CONFIG =` line of the old Makefile minus `--make-install`, which would also run `make install`):
```bash
perl Configure.pl --optimize --prefix=/home/longwalker/code/raku/x.core/zmoarz/rakudo/install >/dev/null && \
make -n -W src/moar.o libmoar.so | tr ' ' '\n' | grep '\.o$' | sort > $SCRATCH/objs.after.txt && \
make -n -W src/main.o moar | tr ' ' '\n' | grep '\.o$' | sort > $SCRATCH/main-objs.after.txt && \
diff $SCRATCH/objs.before.txt $SCRATCH/objs.after.txt && diff $SCRATCH/main-objs.before.txt $SCRATCH/main-objs.after.txt && echo IDENTICAL
```
Expected: `IDENTICAL`. Then confirm the only other Makefile change is the `CONFIG =` line:
```bash
diff $SCRATCH/Makefile.before Makefile | grep '^[<>]' | grep -v '^[<>] CONFIG\|^[<>] *src/\|^[<>] *3rdparty/\|^[<>]OBJECTS\|^[<>]PLATFORM_POSIX\|^[<>]JIT_\|^[<>]MAIN_OBJECTS\|^[<>] *$'
```
Expected: no output (differences are confined to the `CONFIG` line and the reformatted object list lines).

- [ ] **Step 5: Confirm the Perl build still links**

Run: `make -j$(nproc) moar 2>&1 | tail -3 && ./moar --version`
Expected: `This is MoarVM version <git describe output> built with JIT support`, where the version matches `git describe --tags --match=20*` on this branch. Because Configure.pl regenerated `src/gen/config.h` with the new version string, make rebuilds every object; this takes a few minutes and must succeed.

- [ ] **Step 6: Confirm the zig build is unaffected**

Run: `zig build test --summary all 2>&1 | tail -3`
Expected: all steps succeeded.

- [ ] **Step 7: Commit**

```bash
git add build/Makefile.in Configure.pl
git commit -m "Configure.pl: read the C object lists from build/sources.list

Behaviour-preserving: the generated Makefile links the same objects.
build/sources.list is now the single source of truth for the Perl and
zig builds.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Documentation and final verification

**Files:**
- Create: `docs/zig-build.md`
- Modify: `build/README.md` (one paragraph pointing at the new doc)

- [ ] **Step 1: Write `docs/zig-build.md`**

```markdown
# Building MoarVM with zig

An alternative to `perl Configure.pl && make` that needs only zig (0.16.0):

    zig build --prefix /abs/path/to/prefix install
    zig build test            # moar --version and the nqp stage0 smoke test

Options (`zig build --help` lists them):

| Option | Default | Meaning |
|---|---|---|
| `-Doptimize=` | `ReleaseFast` | zig's standard optimisation mode (`Debug` for a -g3 style build) |
| `-Dtarget=` | native | only `x86_64-linux` is supported so far |
| `-Djit=` | `false` | the JIT is not built by the zig build yet |
| `-Dstatic=` | `false` | build `libmoar.a` instead of `libmoar.so` |
| `-Dmimalloc=` | `true` | use the bundled mimalloc |
| `-Dzstd=` | `true` | link the system libzstd for heap snapshot format 3 |
| `-Dnqp-stage0=` | `../src/vm/moar/stage0` | where `zig build test` finds nqp's stage0 bytecode |

Always pass an absolute `--prefix`: it is baked into the binary's rpath,
into `nqp::backendconfig` and into `lib/pkgconfig/moar.pc`.

## How it maps to the Perl build

| Perl build | zig build |
|---|---|
| `build/probe.pm` compiler probes | constants for clang plus a per-OS table in `build/zig/platform.zig` |
| `build/config.h.in` expanded by Configure.pl | same template rendered by zig's ConfigHeader step (`build/zig/config.zig`) |
| `build/config.c.in` | rendered by `build/zig/config.zig` into the zig cache |
| object lists in `build/Makefile.in` | `build/sources.list`, read by both Configure.pl and `build/zig/sources.zig` |
| `build/setup.pm` third-party rules, dyncall's `./configure` | `build/zig/thirdparty.zig` |
| `make install` | `zig build install` (`build/zig/install.zig`) |

## Not yet supported

JIT (dynasm and the Perl template compilers), any OS other than linux,
any CPU other than x86_64, system libuv/libtommath/libffi, MSVC, coverage
and sanitizer builds, `--relocatable`.
```

- [ ] **Step 2: Point to it from `build/README.md`**

Append to `build/README.md`:
```markdown

## zig build

`build.zig` and `build/zig/` provide an alternative build that needs only
zig; see `docs/zig-build.md`. `build/sources.list` is shared by both builds:
add new C files there, not in `Makefile.in`.
```

- [ ] **Step 3: Full clean verification**

Run:
```bash
rm -rf .zig-cache zig-out && zig build test --summary all 2>&1 | tail -3 && zig-out/bin/moar --version && zig test build/zig/sources.zig && zig test build/zig/version.zig && zig test build/zig/config.zig && git status --short
```
Expected: all steps succeeded, the version line, three `All N tests passed.`, and `git status` showing only the two doc files as changes.

- [ ] **Step 4: Commit**

```bash
git add docs/zig-build.md build/README.md
git commit -m "Document the zig build

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Deviations from the spec, recorded here for the spec's next revision

- `-Dprefix` is zig's built-in `--prefix`.
- `zig build test` has no C test suite to run: MoarVM ships none (`build/test.txt` says so). It runs `moar --version` and the nqp stage0 smoke test instead.
- `-Dzstd` is new; the spec did not mention that heap snapshot format 3 needs the system libzstd.
- `-Dsystem-libuv`, `-Dsystem-libtommath`, `-Dsystem-libffi` are deferred to phase 5.
- The `[core]` section of `build/sources.list` lists `src/gen/config.c` so the Perl Makefile is unchanged; `build/zig/moar.zig` filters it out and uses its own generated file.
- `build/sources.list` carries the Makefile template entry `src/core/nativecall_@nativecall_backend@.c` verbatim (found during Task 2); `build/zig/moar.zig` expands it to `dyncall`.
