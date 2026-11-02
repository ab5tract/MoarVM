# Zig Port Step Zero Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one C source file of MoarVM be replaced by a Zig file exporting the same symbols, selectable in both the Perl and zig builds, and prove it by porting `src/platform/posix/time.c` and `src/core/intcache.c`.

**Architecture:** `build.zig` runs translate-c over a wrapper of `src/moar.h`, post-processes the output with a small fixup program, and compiles every file under `src/zig/` into one object `moar_zig.o` that imports the translated module through `src/zig/moar.zig` (which also holds the macro shims). `build/sources.list` gains a `[zig]` section declaring which C files each Zig file replaces; both parsers drop those C files when the Zig groups are on. The zig build links the object into libmoar; the Perl Makefile obtains the same object via `zig build zig-objects -Dconfig-h=src/gen/config.h` when configured with `--zig=PATH`.

**Tech Stack:** Zig 0.16.0 (`std.Build.Step.TranslateC`, `addObject`, `addInstallFile`), Perl 5 (`Configure.pl`, `build/Makefile.in`), GNU make.

**Spec:** `docs/superpowers/specs/2026-11-02-zig-port-step0-design.md` (read its §2 decisions and §9 acceptance criteria; the "Amendments" section records what prototyping changed).

## Global Constraints

- Zig is `/usr/bin/zig`, version 0.16.0; its std lives at `/usr/lib/zig/std`. Never use `@cImport`; the translate-c build step is the only route to C.
- Every Zig source formats clean under `zig fmt --check`. Every Perl change passes `perl -c Configure.pl`. Every shell snippet passes `sh -n`.
- A build without the Zig groups (`-Dzig-impl=false`, or `perl Configure.pl` without `--zig`) must compile exactly the C files it compiles on branch `zig-build-phase2`.
- Exported Zig functions use the exact C symbol names and signatures from the header that declares them (`src/platform/time.h`, `src/core/intcache.h`). Implementation files `@import("moar")` only; never `@import("c")` directly outside `src/zig/moar.zig`.
- The Perl build writes `src/gen/config.h`, `src/gen/config.c`, `src/gen/config.o`. Before any `zig build` command that does not pass `-Dconfig-h`, run `rm -f src/gen/config.h src/gen/config.c src/gen/config.o`, or the build refuses to run. `perl Configure.pl` recreates them.
- `zig build` needs an absolute `--prefix`. Use `$PWD/zig-out` in commands below; the Makefile uses the absolute path Configure computes.
- Build commands take minutes; use `timeout` values of at least 600000 ms for full builds.
- Commit after each task with the message given; append the attribution line required by your environment.
- Repo root for all paths: `/home/longwalker/code/raku/x.core/zmoarz/rakudo/nqp/MoarVM`. nqp's stage0 for the smoke test: `../src/vm/moar/stage0`.
- Zig gotcha found while prototyping: `&tc.instance.*.int_const_cache.*.types[0]` has type `*[4][*c]MVMObject`, not a pointer to the element. Always bind the C-pointer deref to a `const cache: *c.MVMIntConstCache = tc.instance.*.int_const_cache;` first and then take `&cache.types[0]`.

---

### Task 1: Cherry-pick the `zig` compiler entry (PR #1971) with fixes

**Files:**
- Modify: `Configure.pl` (Darwin toolchain check, option handling near line 119)
- Modify: `build/setup.pm` (`%COMPILERS`)

**Interfaces:**
- Produces: `--compiler=zig` selects `cc => 'zig cc'`; `--cc=zig` without `--compiler` is treated as `--compiler=zig`. Later tasks rely on `$config{compiler}` being `zig` in that case only for acceptance criterion 6.

- [ ] **Step 1: Cherry-pick without committing**

```bash
git cherry-pick -n 3aac34699
git diff --stat
```
Expected: `Configure.pl` and `build/setup.pm` modified, no conflicts.

- [ ] **Step 2: Fix the precedence bug and drop the Darwin default change**

In `Configure.pl`, the cherry-picked line reads:
```perl
if ($^O eq 'darwin' && !$config{compiler} eq "zig") {
```
Replace with:
```perl
if ($^O eq 'darwin' && (defined_or $config{compiler}, '') ne 'zig') {
```
In `build/setup.pm`, in `%TC_DARWIN`, the cherry-pick changed `-compiler => 'clang',` to `-compiler => 'zig',`. Change it back to `-compiler => 'clang',`. Keep the new `zig => { ... }` entry in `%COMPILERS` unchanged.

- [ ] **Step 3: Make `--cc=zig` imply `--compiler=zig`**

In `Configure.pl`, immediately after `pod2usage(1) if $args{help};` (line 58), add:
```perl
# `--cc=zig` is shorthand for the zig compiler entry: zig's C compiler is
# invoked as `zig cc`, which no plain --cc value can express.
if (defined $args{cc} && $args{cc} eq 'zig') {
    $args{compiler} = 'zig' unless exists $args{compiler};
    delete $args{cc};
}
```

- [ ] **Step 4: Verify**

```bash
perl -c Configure.pl
perl -e 'use lib "."; use build::setup; print exists $::COMPILERS{zig} ? "zig entry ok\n" : "missing\n"; print $::TOOLCHAINS{darwin}{-compiler} // "none", "\n"' 2>/dev/null || perl -e 'use lib "."; use build::setup; print exists $::COMPILERS{zig} ? "zig entry ok\n" : "missing\n"'
perl Configure.pl --cc=zig --prefix /tmp/claude-1000/zig-port-prefix >/dev/null && grep -n '^CC ' Makefile
```
Expected: `Configure.pl syntax OK`; `zig entry ok`; `CC     = zig cc`.

- [ ] **Step 5: Clean up and commit**

```bash
make realclean >/dev/null 2>&1; rm -f src/gen/config.h src/gen/config.c src/gen/config.o Makefile
git add Configure.pl build/setup.pm
git commit -m "Configure: add the zig compiler entry (from PR #1971), --cc=zig shorthand

Cherry-picked from 3aac34699 with the Darwin precedence bug fixed and
Darwin's default compiler left at clang."
```

---

### Task 2: `[zig]` section in `build/zig/sources.zig`

**Files:**
- Modify: `build/zig/sources.zig`
- Test: `build/zig/sources.zig` (inline tests, run by `zig build unit-test`)

**Interfaces:**
- Produces: `pub const ZigEntry = struct { zig: []const u8, replaces: []const []const u8 };`, `Lists.zig: []const ZigEntry`, `pub fn applyZig(allocator, lists: Lists) Error!Lists` (returns lists with every replaced C file removed, `zig` untouched), new errors `BadZigLine`, `ZigReplacesUnknownFile`, `ZigReplacesTwice`.

- [ ] **Step 1: Write the failing tests**

Append to `build/zig/sources.zig`:
```zig
test "parse: [zig] lines name a zig file and the C files it replaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\[core]
        \\src/core/a.c
        \\src/core/intcache.c
        \\[platform-posix]
        \\src/platform/posix/time.c
        \\[main]
        \\src/main.c
        \\[zig]
        \\src/zig/platform/time.zig: src/platform/posix/time.c
        \\src/zig/core/intcache.zig:   src/core/intcache.c
    );
    try std.testing.expectEqual(@as(usize, 2), lists.zig.len);
    try std.testing.expectEqualStrings("src/zig/platform/time.zig", lists.zig[0].zig);
    try std.testing.expectEqualStrings("src/platform/posix/time.c", lists.zig[0].replaces[0]);
    try std.testing.expectEqualStrings("src/core/intcache.c", lists.zig[1].replaces[0]);
    // parse leaves the C lists intact
    try std.testing.expectEqual(@as(usize, 2), lists.core.len);
    try std.testing.expectEqual(@as(usize, 1), lists.platform_posix.len);

    const applied = try applyZig(arena.allocator(), lists);
    try std.testing.expectEqual(@as(usize, 1), applied.core.len);
    try std.testing.expectEqualStrings("src/core/a.c", applied.core[0]);
    try std.testing.expectEqual(@as(usize, 0), applied.platform_posix.len);
    try std.testing.expectEqual(@as(usize, 2), applied.zig.len);
}

test "parse: [zig] line without a colon is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadZigLine, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig\n"));
}

test "parse: [zig] replacing a file listed nowhere is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigReplacesUnknownFile, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig: src/b.c\n"));
}

test "parse: a C file replaced on two [zig] lines is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigReplacesTwice, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig: src/a.c\nsrc/zig/y.zig: src/a.c\n"));
}
```

- [ ] **Step 2: Run to verify failure**

```bash
zig test build/zig/sources.zig 2>&1 | head -5
```
Expected: compile error, `no field named 'zig'` or `use of undeclared identifier 'applyZig'`.

- [ ] **Step 3: Implement**

Replace the top of `build/zig/sources.zig` down to and including `pub fn load` with:
```zig
//! Reads build/sources.list: the C source list shared by build.zig and
//! (via Configure.pl) build/Makefile.in.
//!
//! Format: one path per line relative to the repo root, grouped under
//! `[section]` headers. Blank lines and lines starting with `#` are ignored.
//! The `[zig]` section is different: each line reads
//! `<zig file>: <c file> [<c file> ...]` and declares that the Zig file
//! replaces those C files when the Zig implementations are built.
const std = @import("std");

pub const ZigEntry = struct {
    zig: []const u8,
    replaces: []const []const u8,
};

pub const Lists = struct {
    core: []const []const u8 = &.{},
    platform_posix: []const []const u8 = &.{},
    jit: []const []const u8 = &.{},
    jit_x64: []const []const u8 = &.{},
    jit_stub: []const []const u8 = &.{},
    main: []const []const u8 = &.{},
    zig: []const ZigEntry = &.{},
};

pub const Error = error{
    UnknownSection,
    EntryOutsideSection,
    BadZigLine,
    ZigReplacesUnknownFile,
    ZigReplacesTwice,
    OutOfMemory,
};

const Section = enum { core, platform_posix, jit, jit_x64, jit_stub, main, zig };

const section_names = std.StaticStringMap(Section).initComptime(.{
    .{ "core", .core },
    .{ "platform-posix", .platform_posix },
    .{ "jit", .jit },
    .{ "jit-x64", .jit_x64 },
    .{ "jit-stub", .jit_stub },
    .{ "main", .main },
    .{ "zig", .zig },
});

const c_sections = [_]Section{ .core, .platform_posix, .jit, .jit_x64, .jit_stub, .main };

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    var buckets = [_]std.ArrayList([]const u8){ .empty, .empty, .empty, .empty, .empty, .empty };
    var zig_entries: std.ArrayList(ZigEntry) = .empty;
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
        if (section == .zig) {
            try zig_entries.append(allocator, try parseZigLine(allocator, line));
        } else {
            try buckets[@intFromEnum(section)].append(allocator, line);
        }
    }

    const lists: Lists = .{
        .core = try buckets[@intFromEnum(Section.core)].toOwnedSlice(allocator),
        .platform_posix = try buckets[@intFromEnum(Section.platform_posix)].toOwnedSlice(allocator),
        .jit = try buckets[@intFromEnum(Section.jit)].toOwnedSlice(allocator),
        .jit_x64 = try buckets[@intFromEnum(Section.jit_x64)].toOwnedSlice(allocator),
        .jit_stub = try buckets[@intFromEnum(Section.jit_stub)].toOwnedSlice(allocator),
        .main = try buckets[@intFromEnum(Section.main)].toOwnedSlice(allocator),
        .zig = try zig_entries.toOwnedSlice(allocator),
    };
    try validateZig(lists);
    return lists;
}

fn parseZigLine(allocator: std.mem.Allocator, line: []const u8) Error!ZigEntry {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadZigLine;
    const zig_file = std.mem.trim(u8, line[0..colon], " \t");
    if (zig_file.len == 0) return error.BadZigLine;
    var replaces: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    while (words.next()) |w| try replaces.append(allocator, w);
    if (replaces.items.len == 0) return error.BadZigLine;
    return .{ .zig = zig_file, .replaces = try replaces.toOwnedSlice(allocator) };
}

fn cList(lists: Lists, section: Section) []const []const u8 {
    return switch (section) {
        .core => lists.core,
        .platform_posix => lists.platform_posix,
        .jit => lists.jit,
        .jit_x64 => lists.jit_x64,
        .jit_stub => lists.jit_stub,
        .main => lists.main,
        .zig => unreachable,
    };
}

fn contains(list: []const []const u8, file: []const u8) bool {
    for (list) |f| if (std.mem.eql(u8, f, file)) return true;
    return false;
}

/// Every replaced C file must be listed in some C section, and only once
/// across all [zig] lines.
fn validateZig(lists: Lists) Error!void {
    for (lists.zig, 0..) |entry, i| {
        for (entry.replaces) |file| {
            var found = false;
            for (c_sections) |s| {
                if (contains(cList(lists, s), file)) found = true;
            }
            if (!found) return error.ZigReplacesUnknownFile;
            for (lists.zig[0..i]) |earlier| {
                if (contains(earlier.replaces, file)) return error.ZigReplacesTwice;
            }
            // Also reject duplicates within the same line.
            var seen: usize = 0;
            for (entry.replaces) |other| if (std.mem.eql(u8, other, file)) {
                seen += 1;
            };
            if (seen > 1) return error.ZigReplacesTwice;
        }
    }
}

fn isReplaced(lists: Lists, file: []const u8) bool {
    for (lists.zig) |entry| if (contains(entry.replaces, file)) return true;
    return false;
}

fn without(allocator: std.mem.Allocator, lists: Lists, list: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |f| if (!isReplaced(lists, f)) try out.append(allocator, f);
    return try out.toOwnedSlice(allocator);
}

/// The lists as the build compiles them when the Zig implementations are
/// on: every C file named on a [zig] line is dropped from its section.
pub fn applyZig(allocator: std.mem.Allocator, lists: Lists) Error!Lists {
    return .{
        .core = try without(allocator, lists, lists.core),
        .platform_posix = try without(allocator, lists, lists.platform_posix),
        .jit = try without(allocator, lists, lists.jit),
        .jit_x64 = try without(allocator, lists, lists.jit_x64),
        .jit_stub = try without(allocator, lists, lists.jit_stub),
        .main = try without(allocator, lists, lists.main),
        .zig = lists.zig,
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
Keep the three existing tests after it, then the new tests.

- [ ] **Step 4: Run tests**

```bash
zig fmt --check build/zig/sources.zig && zig test build/zig/sources.zig
```
Expected: `All 7 tests passed.`

- [ ] **Step 5: Add an empty `[zig]` section to `build/sources.list` and confirm the build is unchanged**

Append to `build/sources.list`:
```
[zig]
# <zig file>: <c file> [<c file> ...]  -- the Zig file replaces those C files
# when the Zig implementations are built (zig build -Dzig-impl=true, the
# default; perl Configure.pl --zig=PATH). Entries are added by later tasks.
```
Then:
```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build unit-test 2>&1 | tail -3
```
Expected: no output or only test summaries, exit 0. (Configure.pl still rejects the section; Task 3 fixes that.)

- [ ] **Step 6: Commit**

```bash
git add build/zig/sources.zig build/sources.list
git commit -m "sources.list: [zig] section declaring Zig replacements for C files (zig side)"
```

---

### Task 3: `[zig]` section in `Configure.pl`

**Files:**
- Modify: `Configure.pl:805-820` (object list block) and `Configure.pl:1047-1075` (`read_sources_list`)

**Interfaces:**
- Produces: `read_sources_list($file, $apply_zig)`; when `$apply_zig` is true the returned hash has replaced C files removed from their sections and a `zig_files` key listing the Zig files in order; when false the `[zig]` section is validated and dropped. Task 8 passes `defined $args{zig}`.

- [ ] **Step 1: Replace `read_sources_list`**

```perl
# Parse build/sources.list: '[section]' headers, one path per line,
# '#' comments and blank lines ignored. The [zig] section lists
# '<zig file>: <c file> [<c file> ...]' lines; with $apply_zig true the
# C files named there are removed from their sections and the Zig files
# are returned under the 'zig_files' key. Without it the section is
# validated and dropped. Mirrors build/zig/sources.zig.
sub read_sources_list {
    my ($file, $apply_zig) = @_;
    open my $fh, '<', $file or hardfail("cannot open $file: $!");
    my (%sections, $current, @zig);
    while (my $line = <$fh>) {
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        if ($line =~ /^\[(.+)\]$/) {
            $current = $1;
            $sections{$current} ||= [];
            next;
        }
        hardfail("$file: entry '$line' before any [section]") unless defined $current;
        if ($current eq 'zig') {
            my ($zig_file, $rest) = $line =~ /^([^:]+):(.*)$/
                or hardfail("$file: [zig] line '$line' must read '<zig file>: <c file> ...'");
            $zig_file =~ s/\s+$//;
            my @replaces = split ' ', $rest;
            hardfail("$file: [zig] line '$line' names no C file") unless @replaces;
            push @zig, [ $zig_file, @replaces ];
            next;
        }
        push @{ $sections{$current} }, $line;
    }
    close $fh;
    delete $sections{zig};
    my %known = map { $_ => 1 } qw(core platform-posix jit jit-x64 jit-stub main);
    for my $name (sort keys %sections) {
        hardfail("$file: unknown section [$name]") unless $known{$name};
    }
    for my $name (qw(core main)) {
        hardfail("$file: section [$name] is missing or empty")
            unless $sections{$name} && @{ $sections{$name} };
    }

    my %replaced;
    for my $entry (@zig) {
        my ($zig_file, @replaces) = @$entry;
        for my $c (@replaces) {
            hardfail("$file: [zig] replaces '$c' twice") if $replaced{$c}++;
            my $found = grep { $_ eq $c } map { @$_ } values %sections;
            hardfail("$file: [zig] replaces '$c', which no section lists") unless $found;
        }
    }
    if ($apply_zig) {
        for my $name (keys %sections) {
            $sections{$name} = [ grep { !$replaced{$_} } @{ $sections{$name} } ];
        }
        $sections{zig_files} = [ map { $_->[0] } @zig ];
    }
    return %sections;
}
```

- [ ] **Step 2: Pass the flag from the object list block**

In the block at `Configure.pl:805-820`, change
```perl
    my %sections = read_sources_list('build/sources.list');
```
to
```perl
    my %sections = read_sources_list('build/sources.list', defined $args{zig});
```
(`$args{zig}` is undefined until Task 8 adds the option; `defined` keeps this a no-op now.)

- [ ] **Step 3: Verify against the real list and against bad input**

```bash
perl -c Configure.pl
perl Configure.pl --prefix /tmp/claude-1000/zig-port-prefix >/dev/null && grep -c 'intcache@obj@\|intcache\.o' Makefile
cp build/sources.list /tmp/claude-1000/sources.list.bak
printf '[zig]\nsrc/zig/x.zig: src/nope.c\n' >> build/sources.list
perl Configure.pl --prefix /tmp/claude-1000/zig-port-prefix 2>&1 | grep -o "\[zig\] replaces 'src/nope.c', which no section lists"
cp /tmp/claude-1000/sources.list.bak build/sources.list
make realclean >/dev/null 2>&1; rm -f src/gen/config.h src/gen/config.c src/gen/config.o Makefile
```
Expected: `syntax OK`; `1` (intcache still compiled, flag off); the hardfail message; list restored (`git diff --quiet build/sources.list`).

- [ ] **Step 4: Commit**

```bash
git add Configure.pl
git commit -m "Configure: parse and validate the [zig] section of sources.list"
```

---

### Task 4: translate-c pipeline, `moar_zig` object, `-Dzig-impl`, `-Dconfig-h`, `zig-objects`

**Files:**
- Create: `src/zig/moar_c.h`, `src/zig/moar.zig`, `src/zig/root.zig`, `build/zig/fixup_translated.zig`, `build/zig/zigimpl.zig`
- Modify: `build/zig/options.zig`, `build/zig/moar.zig`, `build.zig`
- Test: `build/zig/fixup_translated.zig` (inline tests), build commands

**Interfaces:**
- Produces: `zigimpl.Impl { translate, c_mod, moar_mod, object }`, `zigimpl.add(b, opts, config: zigimpl.ConfigSource) Impl`, `zigimpl.addObjectsStep(b, impl) *std.Build.Step`, `zigimpl.checkRootImports(b, lists)`; `Options.zig_impl: bool`, `Options.config_h: ?[]const u8`; in `build/zig/moar.zig`: `pub const include_paths`, `pub const system_include_paths`, `pub const Define`, `pub fn defines(b, opts) []const Define`.

- [ ] **Step 1: The wrapper header**

Create `src/zig/moar_c.h`:
```c
/* Entry point for translate-c (build/zig/zigimpl.zig). Zig cannot express
 * C11 _Atomic types; MoarVM uses them only for word-sized counters whose
 * size and alignment equal the plain type on every supported target, and
 * Zig code never touches those fields directly. The shim unit tests check
 * the resulting struct layouts against the C compiler. */
#define _Atomic(T) T
#include "moar.h"
```

- [ ] **Step 2: Fixup program with failing tests first**

Create `build/zig/fixup_translated.zig`:
```zig
//! Post-processes `zig translate-c` output for src/moar.h.
//!
//! translate-c (0.16.0) renders `x++` on a narrow integer inside some
//! static inline functions as `@as(c_int, x) += 1;`, which is not a valid
//! assignment target. This rewrites such lines to `x += 1;`. Everything
//! else passes through unchanged.
//!
//! Usage: fixup_translated IN OUT
const std = @import("std");

fn isOp(ch: u8) bool {
    return switch (ch) {
        '+', '-', '*', '/', '%', '&', '|', '^' => true,
        else => false,
    };
}

/// Returns the rewritten line, or null when the line needs no change.
pub fn fixLine(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    const body = std.mem.trimLeft(u8, line, " \t");
    const indent = line[0 .. line.len - body.len];
    if (!std.mem.startsWith(u8, body, "@as(c_")) return null;
    const comma = std.mem.indexOf(u8, body, ", ") orelse return null;
    var i = comma + 2;
    while (i + 4 < body.len) : (i += 1) {
        if (body[i] == ')' and body[i + 1] == ' ' and isOp(body[i + 2]) and body[i + 3] == '=' and body[i + 4] == ' ') {
            const expr = body[comma + 2 .. i];
            const rest = body[i + 2 ..];
            return try std.mem.concat(allocator, u8, &.{ indent, expr, " ", rest });
        }
    }
    return null;
}

pub fn fixup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (try fixLine(allocator, line)) |fixed| {
            try out.appendSlice(allocator, fixed);
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) std.process.fatal("usage: fixup_translated IN OUT", .{});
    const text = try std.fs.cwd().readFileAlloc(allocator, args[1], std.math.maxInt(u32));
    const fixed = try fixup(allocator, text);
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = fixed });
}

test "fixLine rewrites the invalid compound assignments translate-c emits" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "            @as(c_int, nameds) += 1;", "            nameds += 1;" },
        .{ "        @as(c_int, i) += 1;", "        i += 1;" },
        .{ "    @as(c_int, gi.*.strands_remaining) -= 1;", "    gi.*.strands_remaining -= 1;" },
        .{ "\t@as(c_uint, x.*.y[2]) |= 4;", "\tx.*.y[2] |= 4;" },
    };
    for (cases) |case| {
        const got = (try fixLine(a, case[0])).?;
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "fixLine leaves ordinary lines alone" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, "    while (@as(c_int, i) < @as(c_int, cs.*.flag_count)) {"));
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, "    x = @as(c_int, y) + 1;"));
    try std.testing.expectEqual(@as(?[]u8, null), try fixLine(a, ""));
}

test "fixup preserves line structure" {
    const a = std.testing.allocator;
    const got = try fixup(a, "a\n    @as(c_int, n) += 1;\nb");
    defer a.free(got);
    try std.testing.expectEqualStrings("a\n    n += 1;\nb", got);
}
```
Note: the `std.fs.cwd().readFileAlloc` / `writeFile` calls must match 0.16's std API; if the compiler rejects them, consult `/usr/lib/zig/std/fs/Dir.zig` for the current signatures (0.16 may require an `Io` argument, as `b.build_root.handle.readFileAlloc(b.graph.io, ...)` in `sources.zig` does; in a standalone program obtain it via `std.Io.Threaded` as `tools/zig/expr_template_compiler.zig` does) and adjust while keeping the semantics.

```bash
zig fmt --check build/zig/fixup_translated.zig && zig test build/zig/fixup_translated.zig
```
Expected: `All 3 tests passed.`

- [ ] **Step 3: Options**

In `build/zig/options.zig`, add to `Options`:
```zig
    /// Compile the Zig implementations listed in build/sources.list's [zig]
    /// section and drop the C files they replace.
    zig_impl: bool,
    /// Use an existing <dir>/gen/config.h (the Perl build's) instead of the
    /// generated one. Only the `zig-objects` step is supported in this mode.
    config_h: ?[]const u8,
```
and in `parse`, before `return .{`:
```zig
    const config_h = b.option([]const u8, "config-h", "Path to an existing gen/config.h to build the Zig implementations against (the Perl build passes src/gen/config.h); only `zig build zig-objects` is supported with it");
    if (config_h) |p| {
        if (!std.mem.endsWith(u8, p, "gen/config.h")) std.process.fatal("-Dconfig-h must end in gen/config.h, got {s}", .{p});
    }
```
and the two fields in the returned struct:
```zig
        .zig_impl = b.option(bool, "zig-impl", "Build the Zig implementations from the [zig] section of build/sources.list in place of the C files they replace (default true)") orelse true,
        .config_h = config_h,
```

- [ ] **Step 4: Share include paths and defines from `build/zig/moar.zig`**

Replace `pub fn addIncludes` with:
```zig
/// CINCLUDES from the generated Makefile, in order.
pub const include_paths = [_][]const u8{
    "src",
    "3rdparty/libuv/include",
    "3rdparty/libuv/src",
    "3rdparty/libtommath",
    "3rdparty/dyncall/dynload",
    "3rdparty/dyncall/dyncall",
    "3rdparty/dyncall/dyncallback",
    "3rdparty/mimalloc/include",
    "3rdparty/mimalloc/src",
    "3rdparty/sha1",
};
pub const system_include_paths = [_][]const u8{
    "3rdparty/mimalloc",
    "3rdparty/zmij",
    "3rdparty/dynasm",
    "3rdparty/cmp",
    "3rdparty",
};

pub fn addIncludes(b: *std.Build, mod: *std.Build.Module) void {
    for (include_paths) |p| mod.addIncludePath(b.path(p));
    for (system_include_paths) |p| mod.addSystemIncludePath(b.path(p));
}

pub const Define = struct { name: []const u8, value: ?[]const u8 };

/// The -D flags a libmoar object is compiled with, as name/value pairs for
/// translate-c. Keep in step with `cflags` and thirdparty.base_cflags.
pub fn defines(b: *std.Build, opts: Options) []const Define {
    var out: std.ArrayList(Define) = .empty;
    out.appendSlice(b.allocator, &.{
        .{ .name = "_REENTRANT", .value = null },
        .{ .name = "_FILE_OFFSET_BITS", .value = "64" },
        .{ .name = "_GNU_SOURCE", .value = null },
        .{ .name = "MVM_TRACING", .value = "0" },
        .{ .name = "MVM_CGOTO", .value = "1" },
        .{ .name = "MVM_HEAPSNAPSHOT_FORMAT", .value = b.fmt("{d}", .{heapSnapshotFormat(opts)}) },
        .{ .name = "MVM_BUILD_SHARED", .value = null },
    }) catch @panic("OOM");
    if (opts.optimize != .Debug) out.append(b.allocator, .{ .name = "NDEBUG", .value = null }) catch @panic("OOM");
    return out.items;
}
```
Add to `LibInputs`:
```zig
    /// The Zig implementations object (build/zig/zigimpl.zig), or null with -Dzig-impl=false.
    zig_object: ?*std.Build.Step.Compile,
```
and in `addLibmoar`, after the `mod.addCSourceFile(.{ .file = in.config_c, ... })` line:
```zig
    if (in.zig_object) |obj| mod.addObject(obj);
```
(The lists passed in are already reduced by `sources.applyZig` in `build.zig`.)

- [ ] **Step 5: The pipeline helper**

Create `build/zig/zigimpl.zig`:
```zig
//! The Zig implementations: translate-c of src/moar.h (through
//! src/zig/moar_c.h), the fixup pass, the `moar` module, and the single
//! object `moar_zig` that holds every file under src/zig/ named in
//! build/sources.list's [zig] section. See docs/zig-build.md.
const std = @import("std");
const Options = @import("options.zig").Options;
const moar = @import("moar.zig");
const sources = @import("sources.zig");

pub const Impl = struct {
    translate: *std.Build.Step.TranslateC,
    /// The fixed translate-c output as a module (import name "c").
    c_mod: *std.Build.Module,
    /// src/zig/moar.zig with "c" imported.
    moar_mod: *std.Build.Module,
    /// The object linked into libmoar, root src/zig/root.zig.
    object: *std.Build.Step.Compile,
};

pub const ConfigSource = union(enum) {
    /// The ConfigHeader step this build renders.
    generated: *std.Build.Step.ConfigHeader,
    /// A directory containing gen/config.h written by another build.
    existing: std.Build.LazyPath,
};

/// Directory to put on the include path for `-Dconfig-h=<dir>/gen/config.h`.
pub fn configDir(b: *std.Build, config_h: []const u8) std.Build.LazyPath {
    const suffix = "gen/config.h";
    var dir = config_h[0 .. config_h.len - suffix.len];
    dir = std.mem.trimRight(u8, dir, "/");
    return b.path(if (dir.len == 0) "." else dir);
}

pub fn add(b: *std.Build, opts: Options, config: ConfigSource) Impl {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/zig/moar_c.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    switch (config) {
        .generated => |h| translate.addConfigHeader(h),
        .existing => |dir| translate.addIncludePath(dir),
    }
    for (moar.include_paths) |p| translate.addIncludePath(b.path(p));
    for (moar.system_include_paths) |p| translate.addSystemIncludePath(b.path(p));
    for (moar.defines(b, opts)) |d| translate.defineCMacro(d.name, d.value);

    const fixup = b.addExecutable(.{
        .name = "fixup_translated",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/zig/fixup_translated.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run = b.addRunArtifact(fixup);
    run.addFileArg(translate.getOutput());
    const fixed = run.addOutputFileArg("moar_c.zig");

    const c_mod = b.createModule(.{
        .root_source_file = fixed,
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    const moar_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/moar.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .pic = true,
        // Match thirdparty.newCModule for the optimize mode.
        .strip = opts.optimize != .Debug,
        .omit_frame_pointer = opts.optimize != .Debug,
        .imports = &.{.{ .name = "moar", .module = moar_mod }},
    });
    const object = b.addObject(.{ .name = "moar_zig", .root_module = root_mod });

    return .{ .translate = translate, .c_mod = c_mod, .moar_mod = moar_mod, .object = object };
}

/// `zig build zig-objects`: install the object to <prefix>/lib/moar_zig.o.
/// The Perl Makefile calls this step; nothing else in the graph is needed.
pub fn addObjectsStep(b: *std.Build, impl: Impl) *std.Build.Step {
    const step = b.step("zig-objects", "Build the Zig implementations object into <prefix>/lib/moar_zig.o (used by the Perl Makefile with -Dconfig-h)");
    step.dependOn(&b.addInstallFile(impl.object.getEmittedBin(), "lib/moar_zig.o").step);
    return step;
}

/// Every [zig] file must be imported by src/zig/root.zig, or its exports
/// are never emitted and the link fails with undefined symbols later.
pub fn checkRootImports(b: *std.Build, lists: sources.Lists) void {
    const root = b.build_root.handle.readFileAlloc(b.graph.io, "src/zig/root.zig", b.allocator, .unlimited) catch |err|
        std.process.fatal("cannot read src/zig/root.zig: {t}", .{err});
    for (lists.zig) |entry| {
        const prefix = "src/zig/";
        if (!std.mem.startsWith(u8, entry.zig, prefix))
            std.process.fatal("build/sources.list: [zig] file {s} must live under src/zig/", .{entry.zig});
        const needle = b.fmt("@import(\"{s}\")", .{entry.zig[prefix.len..]});
        if (std.mem.indexOf(u8, root, needle) == null)
            std.process.fatal("src/zig/root.zig does not {s}; add it so the file's exports are emitted", .{needle});
    }
}

test "configDir strips gen/config.h" {
    // Pure string logic exercised without a Build: replicate the trimming.
    const suffix = "gen/config.h";
    const p = "src/gen/config.h";
    try std.testing.expectEqualStrings("src", std.mem.trimRight(u8, p[0 .. p.len - suffix.len], "/"));
    const q = "gen/config.h";
    try std.testing.expectEqualStrings("", std.mem.trimRight(u8, q[0 .. q.len - suffix.len], "/"));
}
```

- [ ] **Step 6: Module root and object root**

Create `src/zig/moar.zig` (shims arrive in Task 5):
```zig
//! The one module every Zig implementation file imports. Re-exports the
//! translated C API as `c` and will hold the macro shims (Task 5).
pub const c = @import("c");

pub const ThreadContext = c.MVMThreadContext;
pub const Object = c.MVMObject;
pub const Collectable = c.MVMCollectable;
pub const STable = c.MVMSTable;
pub const REPROps = c.MVMREPROps;
```
Create `src/zig/root.zig`:
```zig
//! Root of the `moar_zig` object. Each implementation file listed in the
//! [zig] section of build/sources.list must be referenced here so that its
//! `export fn`s are emitted; the build checks this.
comptime {
    // Implementation files are added here, one line each, e.g.
    // _ = @import("platform/time.zig");
}
```

- [ ] **Step 7: Wire `build.zig`**

Replace the refuse check and the lists line with:
```zig
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
```
After `const config_h = config.configHeader(...)`:
```zig
    const zig_impl: ?zigimpl.Impl = if (opts.zig_impl) zigimpl.add(b, opts, if (opts.config_h) |p|
        .{ .existing = zigimpl.configDir(b, p) }
    else
        .{ .generated = config_h }) else null;
    if (zig_impl) |impl| _ = zigimpl.addObjectsStep(b, impl);
```
Add `.zig_object = if (zig_impl) |impl| impl.object else null,` to the `moar.addLibmoar(b, .{ ... })` call, and `const zigimpl = @import("build/zig/zigimpl.zig");` to the imports. Add `"build/zig/fixup_translated.zig", "build/zig/zigimpl.zig"` to the unit-test file list.

- [ ] **Step 8: Verify both modes and the Perl-config mode**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check build.zig build/zig src/zig
zig build zig-objects --prefix $PWD/zig-out 2>&1 | tail -5 && ls -la zig-out/lib/moar_zig.o && nm zig-out/lib/moar_zig.o | grep -c ' T ' || true
zig build --prefix $PWD/zig-out install 2>&1 | tail -3 && zig build test --prefix $PWD/zig-out 2>&1 | tail -3
zig build unit-test 2>&1 | tail -3
zig build --prefix $PWD/zig-out install -Dzig-impl=false 2>&1 | tail -3
# Perl-config mode: translate against the Perl build's config.h
perl Configure.pl --prefix /tmp/claude-1000/zig-port-prefix >/dev/null
zig build zig-objects --prefix $PWD/zig-out -Dconfig-h=src/gen/config.h 2>&1 | tail -3 && ls -la zig-out/lib/moar_zig.o
make realclean >/dev/null 2>&1; rm -f src/gen/config.h src/gen/config.c src/gen/config.o Makefile
```
Expected: object exists (empty of `T` symbols, so the grep count is 0); install and test pass; unit tests pass; the `-Dzig-impl=false` build succeeds; the `-Dconfig-h` run produces the object without the refuse message. If translate-c fails in `-Dconfig-h` mode because the Perl config did not choose C11 atomics (`MVM_USE_C11_ATOMICS` absent from `src/gen/config.h`), reconfigure with `perl Configure.pl --c11-atomics` and record that in the report; Task 8 then adds `--c11-atomics` to the Makefile documentation.

- [ ] **Step 9: Commit**

```bash
git add src/zig build/zig/fixup_translated.zig build/zig/zigimpl.zig build/zig/options.zig build/zig/moar.zig build.zig
git commit -m "zig build: translate-c pipeline, moar_zig object, -Dzig-impl, -Dconfig-h, zig-objects step"
```

---

### Task 5: Macro shims in `src/zig/moar.zig` with unit tests against libmoar

**Files:**
- Modify: `src/zig/moar.zig`
- Create: `src/zig/test/layout_probe.c`
- Modify: `build/zig/zigimpl.zig` (add `addShimTests`), `build.zig` (wire into `unit-test`)

**Interfaces:**
- Produces (all `pub inline fn` in `moar.zig`): `stable(o: *Object) *STable`, `repr(o: *Object) *const REPROps`, `objectBody(o: *Object) *anyopaque`, `isConcrete(o: *Object) bool`, `assignRef(tc: *ThreadContext, update_root: *Collectable, addr: anytype, v: anytype) void`, `root(tc, ref: anytype) Root`, `rootN(tc, refs: anytype) Root`, `Root.pop(self, tc)`.

- [ ] **Step 1: Write the shims and their tests**

Append to `src/zig/moar.zig`:
```zig
const std = @import("std");

// ---- accessor macros from src/6model/6model.h --------------------------

/// STABLE(o)
pub inline fn stable(o: *Object) *STable {
    return o.st;
}
/// REPR(o)
pub inline fn repr(o: *Object) *const REPROps {
    return stable(o).REPR;
}
/// OBJECT_BODY(o)
pub inline fn objectBody(o: *Object) *anyopaque {
    const stooge: *c.MVMObjectStooge = @ptrCast(o);
    return @ptrCast(&stooge.data);
}
/// IS_CONCRETE(o)
pub inline fn isConcrete(o: *Object) bool {
    return (o.header.flags1 & c.MVM_CF_TYPE_OBJECT) == 0;
}

// ---- MVM_ASSIGN_REF from src/gc/wb.h ------------------------------------

/// MVM_ASSIGN_REF(tc, update_root, update_addr, referenced): write barrier,
/// then the store. `addr` is a pointer to the slot (`*?*T` or `*[*c]T`);
/// `v` is the collectable pointer being stored.
pub inline fn assignRef(tc: *ThreadContext, update_root: *Collectable, addr: anytype, v: anytype) void {
    const referenced: ?*Collectable = @ptrCast(v);
    if (c.MVM_GC_DEBUG != 0) {
        if (referenced) |r| {
            if (r.owner == 0) c.MVM_panic(1, "Invalid assignment (maybe of heap frame to stack frame?)");
        }
    }
    c.MVM_gc_write_barrier(tc, update_root, referenced);
    addr.* = v;
}

// ---- MVMROOT .. MVMROOT6 from src/gc/roots.h ----------------------------

/// Handle returned by `root`/`rootN`; `defer r.pop(tc)` ends the scope.
pub const Root = struct {
    n: u32,
    pub inline fn pop(self: Root, tc: *ThreadContext) void {
        if (self.n == 1) c.MVM_gc_root_temp_pop(tc) else c.MVM_gc_root_temp_pop_n(tc, self.n);
    }
};

inline fn checkRef(comptime T: type) void {
    const info = @typeInfo(T);
    const ok = info == .pointer and switch (@typeInfo(info.pointer.child)) {
        .pointer, .optional => true,
        else => false,
    };
    if (!ok) @compileError("root: expected a pointer to a collectable pointer, got " ++ @typeName(T));
}

/// MVMROOT(tc, obj) { ... }  ->  const r = root(tc, &obj); defer r.pop(tc);
pub inline fn root(tc: *ThreadContext, ref: anytype) Root {
    checkRef(@TypeOf(ref));
    c.MVM_gc_root_temp_push(tc, @ptrCast(ref));
    return .{ .n = 1 };
}

/// MVMROOTn(tc, a, b, ...) { ... }  ->  const r = rootN(tc, .{ &a, &b }); defer r.pop(tc);
pub inline fn rootN(tc: *ThreadContext, refs: anytype) Root {
    const n = refs.len;
    _ = c.__MVM_gc_root_temp_push_ensure_space(tc, n);
    inline for (refs) |ref| {
        checkRef(@TypeOf(ref));
        c.MVM_gc_root_temp_push(tc, @ptrCast(ref));
    }
    return .{ .n = n };
}

// ---- tests (compiled only by `zig build unit-test`, linked against libmoar)

extern fn moar_probe_sizeof_tc() usize;
extern fn moar_probe_sizeof_instance() usize;
extern fn moar_probe_offsetof_num_temproots() usize;
extern fn moar_probe_offsetof_int_const_cache() usize;
extern fn moar_probe_offsetof_object_st() usize;

test "translated struct layouts match the C compiler" {
    try std.testing.expectEqual(moar_probe_sizeof_tc(), @sizeOf(c.MVMThreadContext));
    try std.testing.expectEqual(moar_probe_sizeof_instance(), @sizeOf(c.MVMInstance));
    try std.testing.expectEqual(moar_probe_offsetof_num_temproots(), @offsetOf(c.MVMThreadContext, "num_temproots"));
    try std.testing.expectEqual(moar_probe_offsetof_int_const_cache(), @offsetOf(c.MVMInstance, "int_const_cache"));
    try std.testing.expectEqual(moar_probe_offsetof_object_st(), @offsetOf(c.MVMObject, "st"));
}

test "root and rootN push and pop temp roots" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const before = tc.num_temproots;
    var a: ?*Object = instance.*.VMNull;
    var b: ?*Object = instance.*.VMNull;
    var d: ?*Object = instance.*.VMNull;
    {
        const r = root(tc, &a);
        defer r.pop(tc);
        try std.testing.expectEqual(before + 1, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
    {
        const r = rootN(tc, .{ &a, &b });
        defer r.pop(tc);
        try std.testing.expectEqual(before + 2, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
    {
        const r = rootN(tc, .{ &a, &b, &d, &a, &b, &d });
        defer r.pop(tc);
        try std.testing.expectEqual(before + 6, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
}

test "assignRef stores and applies the write barrier" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const array_type: *Object = instance.*.boot_types.BOOTArray;
    var holder: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    const r = root(tc, &holder);
    defer r.pop(tc);
    const value: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    var slot: ?*Object = null;
    const gen2_before = tc.num_gen2roots;
    assignRef(tc, @ptrCast(holder.?), &slot, value);
    try std.testing.expectEqual(value, slot);
    try std.testing.expectEqual(gen2_before, tc.num_gen2roots);
    // Pretend the holder is in gen2: the barrier must now record it.
    holder.?.header.flags2 |= c.MVM_CF_SECOND_GEN;
    assignRef(tc, @ptrCast(holder.?), &slot, value);
    try std.testing.expectEqual(gen2_before + 1, tc.num_gen2roots);
    try std.testing.expect((holder.?.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST) != 0);
    // Undo so the nursery collector at destroy time sees an ordinary object.
    holder.?.header.flags2 &= ~@as(u8, c.MVM_CF_SECOND_GEN | c.MVM_CF_IN_GEN2_ROOT_LIST);
}

test "stable, repr, objectBody and isConcrete" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const null_obj: *Object = instance.*.VMNull;
    try std.testing.expect(!isConcrete(null_obj)); // VMNull is a type object
    try std.testing.expectEqual(stable(null_obj).REPR, repr(null_obj));
    const array_type: *Object = instance.*.boot_types.BOOTArray;
    try std.testing.expect(!isConcrete(array_type));
    const arr: *Object = c.MVM_repr_alloc_init(tc, array_type);
    try std.testing.expect(isConcrete(arr));
    try std.testing.expectEqual(@intFromPtr(arr) + @sizeOf(Object), @intFromPtr(objectBody(arr)));
}
```
Create `src/zig/test/layout_probe.c`:
```c
/* Compiled into the shim unit tests with libmoar's flags: the C compiler's
 * view of struct layouts, to compare with translate-c's. */
#include "moar.h"
#include <stddef.h>
size_t moar_probe_sizeof_tc(void) { return sizeof(MVMThreadContext); }
size_t moar_probe_sizeof_instance(void) { return sizeof(MVMInstance); }
size_t moar_probe_offsetof_num_temproots(void) { return offsetof(MVMThreadContext, num_temproots); }
size_t moar_probe_offsetof_int_const_cache(void) { return offsetof(MVMInstance, int_const_cache); }
size_t moar_probe_offsetof_object_st(void) { return offsetof(MVMObject, st); }
```

- [ ] **Step 2: Build the test executable in `zigimpl.zig`**

Append to `build/zig/zigimpl.zig`:
```zig
/// The shim unit tests: src/zig/moar.zig as a test root, linked against
/// libmoar (linkLibrary gives the cached test binary an rpath to the cached
/// .so, which the installed moar deliberately avoids) plus the C layout probe.
pub fn addShimTests(
    b: *std.Build,
    opts: Options,
    impl: Impl,
    libmoar: *std.Build.Step.Compile,
    config_h: *std.Build.Step.ConfigHeader,
    cflags: []const []const u8,
) *std.Build.Step.Compile {
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/moar.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = impl.c_mod }},
    });
    moar.addIncludes(b, test_mod);
    test_mod.addConfigHeader(config_h);
    test_mod.addCSourceFile(.{ .file = b.path("src/zig/test/layout_probe.c"), .flags = cflags });
    test_mod.linkLibrary(libmoar);
    return b.addTest(.{ .name = "shim-test", .root_module = test_mod });
}
```
In `build.zig`, inside the `unit-test` section after the loop over helper files:
```zig
    if (zig_impl) |impl| {
        if (opts.config_h == null) {
            const shim_tests = zigimpl.addShimTests(b, opts, impl, libmoar, config_h, moar.cflags(b, opts));
            unit_step.dependOn(&b.addRunArtifact(shim_tests).step);
        }
    }
```

- [ ] **Step 3: Run**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check src/zig build/zig build.zig
zig build unit-test --prefix $PWD/zig-out 2>&1 | tail -5
zig build --prefix $PWD/zig-out install && zig build test --prefix $PWD/zig-out 2>&1 | tail -3
```
Expected: all unit tests pass including the four shim tests; install and test pass. If a test fails on `num_temproots` arithmetic, check that `MVM_gc_root_temp_push` and `MVM_gc_root_temp_pop_n` are the translated inline functions (grep the fixed `moar_c.zig` in `.zig-cache` for `pub fn MVM_gc_root_temp_push`).

- [ ] **Step 4: Commit**

```bash
git add src/zig/moar.zig src/zig/test/layout_probe.c build/zig/zigimpl.zig build.zig
git commit -m "Zig shims for STABLE/REPR/OBJECT_BODY/IS_CONCRETE, MVM_ASSIGN_REF and MVMROOT, tested against libmoar"
```

---

### Task 6: Port `src/platform/posix/time.c` to `src/zig/platform/time.zig`

**Files:**
- Create: `src/zig/platform/time.zig`
- Modify: `src/zig/root.zig`, `build/sources.list`

**Interfaces:**
- Consumes: `moar.c` (translated libc: `clock_gettime`, `nanosleep`, `localtime_r`, `strerror`, `__errno_location`, `MVM_exception_throw_adhoc`).
- Produces: `export fn MVM_platform_now() u64`, `MVM_platform_sleep(f64)`, `MVM_platform_nanosleep(u64)`, `MVM_platform_decodelocaltime(*ThreadContext, i64, [*]i64)`.

- [ ] **Step 1: Write the port**

Create `src/zig/platform/time.zig`:
```zig
//! Zig port of src/platform/posix/time.c (linux). Same symbols, same
//! behaviour; libc is reached through the translated header so this file
//! has no dependency on std.posix.
const moar = @import("moar");
const c = moar.c;

const E9: u64 = 1_000_000_000;

/// Wall-clock nanoseconds since the epoch; 0 if the clock cannot be read.
export fn MVM_platform_now() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_REALTIME, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * E9 + @as(u64, @intCast(ts.tv_nsec));
}

fn sleepLoop(timeout: *c.struct_timespec) void {
    // nanosleep writes the remaining time into its second argument when
    // interrupted, so retrying with the same struct resumes the sleep.
    while (c.nanosleep(timeout, timeout) != 0 and c.__errno_location().* == c.EINTR) {}
}

export fn MVM_platform_sleep(second: f64) void {
    var timeout: c.struct_timespec = undefined;
    timeout.tv_sec = @intFromFloat(second);
    // C: (long)((second - timeout.tv_sec) * E9F); the float literal is
    // promoted to double, so the whole expression is double precision.
    const whole: f64 = @floatFromInt(timeout.tv_sec);
    timeout.tv_nsec = @intFromFloat((second - whole) * 1_000_000_000.0);
    sleepLoop(&timeout);
}

export fn MVM_platform_nanosleep(nanos: u64) void {
    var timeout: c.struct_timespec = undefined;
    timeout.tv_sec = @intCast(nanos / E9);
    timeout.tv_nsec = @intCast(nanos % E9);
    sleepLoop(&timeout);
}

export fn MVM_platform_decodelocaltime(tc: *moar.ThreadContext, time: i64, decoded: [*]i64) void {
    const t: c.time_t = @intCast(time);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null)
        c.MVM_exception_throw_adhoc(tc, "Could not decode localtime: %s", c.strerror(c.__errno_location().*));
    decoded[0] = tm.tm_sec;
    decoded[1] = tm.tm_min;
    decoded[2] = tm.tm_hour;
    decoded[3] = tm.tm_mday;
    decoded[4] = tm.tm_mon + 1;
    decoded[5] = tm.tm_year + 1900;
    decoded[6] = tm.tm_wday;
    decoded[7] = tm.tm_yday;
    decoded[8] = tm.tm_isdst;
}
```
- [ ] **Step 2: Register the file**

In `src/zig/root.zig`, inside the `comptime` block replace the example comment with:
```zig
    _ = @import("platform/time.zig");
```
In `build/sources.list`, under `[zig]`, add:
```
src/zig/platform/time.zig: src/platform/posix/time.c
```

- [ ] **Step 3: Build, inspect, run**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check src/zig
zig build --prefix $PWD/zig-out install --verbose 2>&1 | grep -c 'src/platform/posix/time.c' || true
nm -D zig-out/lib/libmoar.so | grep -E ' T MVM_platform_(now|sleep|nanosleep|decodelocaltime)$' | wc -l
zig build test --prefix $PWD/zig-out 2>&1 | tail -3
zig-out/bin/moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'my $t := nqp::time(); nqp::sleep(0.05); say(nqp::time() - $t > 40000000 ?? "ok" !! "too short")'
zig-out/bin/moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'my @d := nqp::decodelocaltime(0); say(nqp::elems(@d))'
zig build --prefix $PWD/zig-out install -Dzig-impl=false --verbose 2>&1 | grep -c 'src/platform/posix/time.c'
```
Expected: `0` compiles of the C file with the Zig groups on; `4` exported symbols; tests pass; `ok`; `9`; `1` or more compiles of the C file with `-Dzig-impl=false`. (`nqp::time` returns nanoseconds; `nqp::sleep` takes seconds.) If `--verbose` does not print compile commands in 0.16, use `zig build ... --summary all` and check the cache for `time.o` instead, and record what you used.

- [ ] **Step 4: Commit**

```bash
git add src/zig/platform/time.zig src/zig/root.zig build/sources.list
git commit -m "Port src/platform/posix/time.c to Zig (first [zig] replacement)"
```

---

### Task 7: Port `src/core/intcache.c` to `src/zig/core/intcache.zig`

**Files:**
- Create: `src/zig/core/intcache.zig`
- Modify: `src/zig/root.zig`, `build/sources.list`

**Interfaces:**
- Consumes: `moar.root` (Task 5), `c.MVM_repr_alloc_init`, `c.MVM_repr_set_int`, `c.MVM_gc_root_add_permanent_desc`, `c.uv_mutex_lock/unlock`. The C stores cache entries with plain assignments and registers them as permanent roots, so `assignRef` is not needed here.
- Produces: `export fn MVM_intcache_for(*ThreadContext, *Object) void`, `MVM_intcache_get(*ThreadContext, *Object, i64) ?*Object`, `MVM_intcache_type_index(*ThreadContext, *Object) i32`.

- [ ] **Step 1: Write the port**

Create `src/zig/core/intcache.zig`:
```zig
//! Zig port of src/core/intcache.c: the per-type cache of boxed small
//! integers (-1 .. 14) for up to four types.
const moar = @import("moar");
const c = moar.c;

const slots = 4;
const min_value: i64 = -1;
const max_value: i64 = 15; // exclusive, as MVM_INTCACHE_RANGE_CHECK

inline fn cache(tc: *moar.ThreadContext) *c.MVMIntConstCache {
    return tc.instance.*.int_const_cache;
}

inline fn mutex(tc: *moar.ThreadContext) *c.uv_mutex_t {
    return &tc.instance.*.mutex_int_const_cache;
}

fn findSlot(tc: *moar.ThreadContext, ty: *moar.Object) ?usize {
    for (&cache(tc).types, 0..) |slot, i| {
        if (slot == ty) return i;
    }
    return null;
}

export fn MVM_intcache_for(tc: *moar.ThreadContext, type_: *moar.Object) void {
    var ty = type_;
    c.uv_mutex_lock(mutex(tc));
    defer c.uv_mutex_unlock(mutex(tc));

    var right_slot: ?usize = null;
    for (&cache(tc).types, 0..) |slot, i| {
        if (slot == null) {
            right_slot = i;
            break;
        } else if (slot == ty) {
            return; // already cached; the defer unlocks
        }
    }
    const idx = right_slot orelse return;

    {
        const r = moar.root(tc, &ty);
        defer r.pop(tc);
        var val: i64 = min_value;
        while (val < max_value) : (val += 1) {
            const obj: *moar.Object = c.MVM_repr_alloc_init(tc, ty);
            c.MVM_repr_set_int(tc, obj, val);
            const entry: *[*c]moar.Object = &cache(tc).cache[idx][@intCast(val + 1)];
            entry.* = obj;
            c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(entry), "Boxed integer cache entry");
        }
    }
    const type_slot: *[*c]moar.Object = &cache(tc).types[idx];
    type_slot.* = ty;
    c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(type_slot), "Boxed integer cache type");
}

export fn MVM_intcache_get(tc: *moar.ThreadContext, ty: *moar.Object, value: i64) ?*moar.Object {
    if (value < min_value or value >= max_value) return null;
    const idx = findSlot(tc, ty) orelse return null;
    return cache(tc).cache[idx][@intCast(value + 1)];
}

export fn MVM_intcache_type_index(tc: *moar.ThreadContext, ty: *moar.Object) i32 {
    c.uv_mutex_lock(mutex(tc));
    defer c.uv_mutex_unlock(mutex(tc));
    const idx = findSlot(tc, ty) orelse return -1;
    return @intCast(idx);
}
```
Behavioural notes to keep: the C version holds the mutex for the whole of `MVM_intcache_for` including the allocation loop (allocation may trigger GC; the mutex is a libuv mutex, not a GC-aware lock, and the C does the same); `MVM_intcache_get` takes no lock, as in C; the type slot is written after all entries, as in C. The `rootN` shim is exercised by the unit tests, not here.

- [ ] **Step 2: Register the file**

`src/zig/root.zig` comptime block gains:
```zig
    _ = @import("core/intcache.zig");
```
`build/sources.list` `[zig]` gains:
```
src/zig/core/intcache.zig: src/core/intcache.c
```

- [ ] **Step 3: Build and run**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check src/zig
zig build --prefix $PWD/zig-out install 2>&1 | tail -3
nm -D zig-out/lib/libmoar.so | grep -E ' T MVM_intcache_(for|get|type_index)$' | wc -l
zig build test --prefix $PWD/zig-out 2>&1 | tail -3
zig-out/bin/moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'my $a := nqp::box_i(3, NQPInt); my $b := nqp::box_i(3, NQPInt); say(nqp::eqaddr($a, $b) ?? "cached" !! "not cached"); say(nqp::unbox_i(nqp::box_i(14, NQPInt)) + nqp::unbox_i(nqp::box_i(-1, NQPInt)))'
```
Expected: `3`; tests pass; `cached` then `13`. (If `NQPInt` is not the boxed int type visible at this stage0 level, use `my int $x := 3; my $o := $x;` style boxing, or check `nqp::bootint()`; the point is that boxing the same small value twice yields the same object.)

- [ ] **Step 4: Commit**

```bash
git add src/zig/core/intcache.zig src/zig/root.zig build/sources.list
git commit -m "Port src/core/intcache.c to Zig (exercises the MVMROOT shim)"
```

---

### Task 8: Perl build: `--zig=PATH`, Makefile rule, flags, clean, help

**Files:**
- Modify: `Configure.pl` (GetOptions line 41-56; object list block ~805-820; new config keys; POD help), `build/Makefile.in` (variables near line 1-80, `OBJECTS2`, new rule, `clean`)

**Interfaces:**
- Consumes: `read_sources_list($file, $apply_zig)` from Task 3; `zig build zig-objects -Dconfig-h=...` from Task 4.
- Produces: Makefile variables `ZIG`, `ZIG_OUT`, `ZIG_BUILD_FLAGS`, `ZIG_SOURCES`, `ZIG_OBJECTS`; config keys `zig`, `zig_out`, `zig_build_flags`, `zig_sources`, `zig_objects`, `zig_clean` (always defined, empty or `@:` when `--zig` is absent).

- [ ] **Step 1: Option and config keys**

In `GetOptions`, change the line
```perl
    ar=s cc=s ld=s make=s has-sha has-libuv
```
to
```perl
    ar=s cc=s ld=s make=s zig=s has-sha has-libuv
```
Replace the object list block (the `{ ... }` starting with `my %sections = read_sources_list(...)`) with:
```perl
# Object lists are shared with build.zig through build/sources.list.
# With --zig=PATH the [zig] section applies: the Zig implementations are
# built into one object by `zig build zig-objects` and the C files they
# replace are left out.
$config{zig} = $config{zig_out} = $config{zig_build_flags} = $config{zig_sources} = $config{zig_objects} = '';
$config{zig_clean} = '@:';
if (defined $args{zig}) {
    hardfail("--zig=$args{zig} is not an executable") unless -x $args{zig};
    $config{zig}     = $args{zig};
    $config{zig_out} = File::Spec->rel2abs('zig-out');
    my $jit = $config{jit_obj} =~ /JIT_ARCH_X64/ ? 'true' : 'false';
    my $zstd = $config{heapsnapformat} == 3 ? 'true' : 'false';
    my $optimize = $args{debug} ? 'Debug' : 'ReleaseFast';
    $config{zig_build_flags} = "-Dconfig-h=src/gen/config.h -Dzstd=$zstd -Doptimize=$optimize -Djit=$jit";
    $config{zig_objects} = '$(ZIG_OUT)/lib/moar_zig@obj@';
    $config{zig_clean}   = '$(RM_RF) zig-out .zig-cache';
}
{
    my %sections = read_sources_list('build/sources.list', defined $args{zig});
    # Split [core] in half (OBJECTS1/OBJECTS2) so that nmake's
    # `$(RM) $(OBJECTS1)` stays under its command-line length limit.
    my @core  = @{ $sections{'core'} };
    my $half  = int(@core / 2);
    $config{objects_core1}          = objlist([ @core[0 .. $half - 1] ]);
    $config{objects_core2}          = objlist([ @core[$half .. $#core] ]);
    $config{objects_platform_posix} = objlist($sections{'platform-posix'});
    $config{objects_jit}            = objlist($sections{'jit'});
    $config{objects_jit_x64}        = objlist($sections{'jit-x64'});
    $config{objects_jit_stub}       = objlist($sections{'jit-stub'});
    $config{objects_main}           = objlist($sections{'main'});
    if ($sections{zig_files}) {
        $config{zig_sources} = join " \\\n          ", 'src/zig/root.zig', 'src/zig/moar.zig', 'src/zig/moar_c.h', @{ $sections{zig_files} };
    }
}
```
Check that this block sits after `$config{jit_obj}` and `$config{heapsnapformat}` are set (they are set near lines 400 and 643-680; the block is near line 805), so the flags read final values.

- [ ] **Step 2: Makefile**

In `build/Makefile.in`, after `MINGW_UNICODE = @mingw_unicode@` add:
```make
# Zig implementations (perl Configure.pl --zig=PATH); empty otherwise.
ZIG             = @zig@
ZIG_OUT         = @zig_out@
ZIG_BUILD_FLAGS = @zig_build_flags@
ZIG_SOURCES     = @zig_sources@
ZIG_OBJECTS     = @zig_objects@
```
Change `OBJECTS2` to:
```make
OBJECTS2 = @objects_core2@ \
           3rdparty/freebsd/memmem@obj@ \
          @zmij_object@ \
          @mimalloc_object@ \
          @platform@ \
          @jit_obj@ \
          $(ZIG_OBJECTS)
```
After the `@moardll@:` rule add:
```make
# One object for every Zig implementation; build.zig owns the recipe.
$(ZIG_OUT)/lib/moar_zig@obj@: src/gen/config.h build.zig build.zig.zon build/sources.list build/zig/zigimpl.zig $(ZIG_SOURCES)
	$(MSG) building the Zig implementations with zig
	$(CMD)$(ZIG) build zig-objects --prefix $(ZIG_OUT) $(ZIG_BUILD_FLAGS)
```
In `clean`, add as the last line:
```make
	-$(CMD)@zig_clean@ $(NOOUT) $(NOERR)
```

- [ ] **Step 3: Help**

In the POD, after the `=item --cc <cc>` entry's paragraph, add:
```pod
=item --zig <path>

Build the Zig implementations listed in the C<[zig]> section of
F<build/sources.list> with the given zig binary (0.16.0), in place of the C
files they replace. The object is produced by C<zig build zig-objects> from
F<build.zig>. Independent of C<--cc=zig>, which only selects zig as the C
compiler.
```
Also add `[--zig <path>]` to the first SYNOPSIS block after `[--cc <cc>] [--ld <ld>] [--make <make>]`.

- [ ] **Step 4: Verify the three Perl configurations (acceptance criteria 4, 5, 6)**

```bash
perl -c Configure.pl
# (4) with --zig
perl Configure.pl --zig=/usr/bin/zig --prefix /tmp/claude-1000/zig-port-prefix 2>&1 | tail -2
grep -n 'moar_zig' Makefile | head -3; grep -c 'posix/time@obj@\|posix/time\.o\|intcache' Makefile
make -j"$(nproc)" 2>&1 | tail -3
nm -D libmoar.so | grep -cE ' T MVM_(platform_now|intcache_get)$'
./moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'say(1+1)'
make install 2>&1 | tail -1
make clean >/dev/null; ls zig-out 2>&1 | head -1
make realclean >/dev/null 2>&1
# (5) without --zig
perl Configure.pl --prefix /tmp/claude-1000/zig-port-prefix >/dev/null
grep -c 'zig' Makefile; grep -c 'intcache@obj@\|intcache\.o' Makefile
make -j"$(nproc)" 2>&1 | tail -1
make realclean >/dev/null 2>&1
# (6) --cc=zig --zig
perl Configure.pl --cc=zig --zig=/usr/bin/zig --prefix /tmp/claude-1000/zig-port-prefix >/dev/null && grep -n '^CC ' Makefile
make -j"$(nproc)" 2>&1 | tail -1 && ./moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'say(1+1)'
make realclean >/dev/null 2>&1; rm -f src/gen/config.h src/gen/config.c src/gen/config.o Makefile
```
Expected: (4) `Makefile` has `moar_zig` in the object list and the rule, and `0` mentions of the time/intcache objects (the grep counts the rule's `src/zig/...` lines only if they match; check the OBJECTS lists by eye if the count is nonzero); build succeeds; `2`; `2`; `make clean` removes `zig-out` (ls prints "No such file"). (5) The only `zig` mentions are the always-present variable lines and comments (`grep -c` small and `grep ZIG_OBJECTS` shows empty assignment); intcache object listed; build succeeds. (6) `CC     = zig cc`; build and smoke pass.
If (4) fails inside translate-c because `src/gen/config.h` lacks `MVM_USE_C11_ATOMICS`, rerun with `--c11-atomics` added to Configure and document it in the report; the plan's docs task then mentions it.

- [ ] **Step 5: Commit**

```bash
git add Configure.pl build/Makefile.in
git commit -m "Configure/Makefile: --zig=PATH builds the [zig] implementations via zig build zig-objects"
```

---

### Task 9: Documentation and final verification

**Files:**
- Modify: `docs/zig-build.md`, `build/README.md`

- [ ] **Step 1: `docs/zig-build.md`**

Add to the options table:
```
| `-Dzig-impl=` | `true` | compile the Zig implementations from the `[zig]` section of `build/sources.list` instead of the C files they replace |
| `-Dconfig-h=` | unset | path to an existing `gen/config.h` (the Perl build's `src/gen/config.h`) to build the Zig implementations against; only `zig build zig-objects` is supported with it |
```
Add a section before "Not yet supported":
```markdown
## Zig implementations

Parts of the VM are being ported to Zig, one C file at a time
(`docs/superpowers/specs/2026-11-02-zig-port-step0-design.md`). The
`[zig]` section of `build/sources.list` lists each Zig file and the C
files it replaces:

    [zig]
    src/zig/platform/time.zig: src/platform/posix/time.c
    src/zig/core/intcache.zig: src/core/intcache.c

All Zig files compile into one object, `moar_zig.o`, whose root is
`src/zig/root.zig`. They see the C API through `src/zig/moar.zig`, which
imports the translate-c output of `src/zig/moar_c.h` (a wrapper around
`src/moar.h` that neutralises C11 `_Atomic`, which Zig cannot express) after
`build/zig/fixup_translated.zig` has repaired the compound assignments
translate-c 0.16 gets wrong, and which defines Zig equivalents of the macros
translate-c cannot handle: `stable`, `repr`, `objectBody`, `isConcrete`,
`assignRef`, `root`/`rootN`. `zig build unit-test` checks the translated
struct layouts against the C compiler and runs the shim tests against a real
instance.

The C files stay in the tree and are still compiled with
`-Dzig-impl=false`. The Perl build gets the same object from

    perl Configure.pl --zig=/usr/bin/zig && make

which runs `zig build zig-objects -Dconfig-h=src/gen/config.h ...` from the
Makefile (the Zig code is then translated against the Perl build's
`config.h`). `--zig` is independent of `--cc=zig`, which selects zig as the
C compiler.
```
Update the "Coexisting" section's last paragraph to mention that `-Dconfig-h` is the exception to the refuse-to-run rule.

- [ ] **Step 2: `build/README.md`**

Extend the sources.list sentence:
```
`build/sources.list` is shared by both builds: add new MoarVM C files there,
and declare Zig replacements for C files in its `[zig]` section (see
`docs/zig-build.md`, "Zig implementations").
```

- [ ] **Step 3: Full verification (spec §9, all seven criteria)**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
rm -rf zig-out
zig fmt --check build.zig build/zig src/zig tools/zig && perl -c Configure.pl && sh -n tools/check-jit-tools.sh
zig build --prefix $PWD/zig-out install 2>&1 | tail -2 && zig build test --prefix $PWD/zig-out 2>&1 | tail -2
nm -D zig-out/lib/libmoar.so | grep -cE ' T MVM_(platform_now|intcache_get)$'
zig build unit-test --prefix $PWD/zig-out 2>&1 | tail -2
rm -rf zig-out && zig build --prefix $PWD/zig-out install -Dzig-impl=false 2>&1 | tail -2 && zig build test --prefix $PWD/zig-out -Dzig-impl=false 2>&1 | tail -2
```
Then rerun Task 8 Step 4 in full. Record every command's outcome in the report. Expected: all pass; `2`.

- [ ] **Step 4: Commit**

```bash
git add docs/zig-build.md build/README.md
git commit -m "Docs: Zig implementations, -Dzig-impl, -Dconfig-h, --zig=PATH"
```

---

## Deviations

Record here, during execution, anything that differed from the plan or spec and why.
