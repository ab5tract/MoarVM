# Zig port, step zero: the `moar` module and the implementation-group switch

**Date:** 2026-11-02
**Status:** approved design, awaiting spec review
**Builds on:** the zig build of MoarVM (branches `zig-build-phase1`, `zig-build-phase2`; user doc `docs/zig-build.md`)

## 1. Goal

Make it possible to replace one C source file of MoarVM with a Zig source file
that exports the same symbols, in both builds (Perl `Configure.pl` + `make`,
and `zig build`), with the C file kept selectable at configure time. Prove the
mechanism by porting two small files. Everything later in the incremental port
(the hash tables first, see Appendix A) reuses this mechanism unchanged.

## 2. Decisions

These were taken during brainstorming and are not to be re-litigated by the
plan.

1. **C implementations stay selectable during the incremental phase.** A build
   without the Zig groups must produce the same libmoar as today. Nothing in
   this spec changes behaviour for a user who does not opt in.
2. **`--zig=PATH` turns the Zig groups on in the Perl build.** It is independent
   of `--cc=zig`, which only selects `zig cc` as the C compiler. `--cc=zig`
   comes from the user's open upstream PR MoarVM/MoarVM#1971 (local branch
   `pr-1971-zig-support`, commit `3aac34699`). That commit is cherry-picked
   with two edits: the Darwin precedence bug `!$config{compiler} eq "zig"` is
   fixed to `$config{compiler} ne "zig"`, and the change of Darwin's default
   compiler from `clang` to `zig` is dropped (separate decision, separate PR).
3. **One Zig object, identical in both builds.** All Zig implementation files
   compile into a single object, `moar_zig.o`, produced by `build.zig`. The zig
   build links it into libmoar directly; the Perl Makefile obtains the same
   object by running one `zig build` step and adds it to its object list.
   Include paths, defines, translate-c wiring and the module graph are defined
   once, in `build.zig`.
4. **Zig code sees C through translate-c of `src/moar.h`**, run by the build
   with exactly the include paths, defines and config header the C objects are
   compiled with. Hand-written Zig covers only what translate-c cannot express:
   the macro layer.
5. **Substitution is declared in `build/sources.list`**, which both builds
   already parse, so the two builds cannot disagree about which C files a Zig
   file replaces.

Verified facts the design relies on (Zig 0.16.0, this checkout):

- `zig translate-c` over `src/moar.h` with the build's include paths succeeds:
  25,236 lines, 216 static-inline functions translated with bodies, 1,376
  extern declarations, 443 macros that fail to translate (among them
  `MVMROOT`..`MVMROOT6`, `MVM_ASSIGN_REF`, `GET_REG`, `MVM_STATIC_INLINE`).
  Structs translate as `extern struct`; `MVMCollectable` has no bitfields.
- Both `@cImport` and `std.Build.Step.TranslateC` (`b.addTranslateC`) exist in
  0.16.0. This spec uses the build step, never `@cImport`.
- `std.Build.Step.InstallArtifact` panics for objects ("object files have no
  standard installation procedure"); objects are installed with
  `b.addInstallFile(obj.getEmittedBin(), ...)`.
- A `Compile` step that `linkLibrary`s a shared libmoar gets an rpath to the
  build cache, so a test executable built that way can run from the cache.
  (The installed `moar` deliberately avoids this by linking the `.so` with
  `addObjectFile`; that stays as is.)

### 2.1 Amendments after prototyping (2026-11-02)

Compiling a Zig object against the raw translate-c output failed, so the
pipeline has two extra pieces, both small and both unit-tested:

- **`src/zig/moar_c.h`** is the translate-c entry point instead of
  `src/moar.h`. It does `#define _Atomic(T) T` and includes `moar.h`. Zig
  cannot express C11 `_Atomic`, and `MVMThreadContext` carries `AO_t`
  fields, so without this the translated `MVMThreadContext` is unusable.
  Size and alignment are unchanged for the word-sized types MoarVM makes
  atomic; the shim unit tests compare `@sizeOf`/`@offsetOf` of
  `MVMThreadContext`, `MVMInstance` and `MVMObject` against a C probe
  (`src/zig/test/layout_probe.c`) compiled with libmoar's flags.
- **`build/zig/fixup_translated.zig`** rewrites the four lines of the form
  `@as(c_int, x) += 1;` that translate-c 0.16.0 emits for `x++` on narrow
  integers (in `MVM_callsite_num_nameds` and the grapheme iterator) to
  `x += 1;`. They are AstGen errors, so the whole translated file is
  rejected until fixed. The fixup runs as a build step between translate-c
  and the `c` module.

Other corrections: `isConcrete(VMNull)` is false (VMNull is a type object),
so the test asserts that and checks a freshly allocated `BOOTArray` instead;
`--cc=zig` is implemented as shorthand for `--compiler=zig` because `--cc`
sets the compiler command verbatim and `zig cc` is two words; `make clean`
removes `zig-out` and `.zig-cache` only when configured with `--zig`, so a
developer using the zig build in the same checkout does not lose the cache.

## 3. Layout

```
src/zig/
  root.zig              object root: `comptime { _ = @import("platform/time.zig"); ... }`
                        one line per implementation file, so their `export fn`s are emitted
  moar.zig              the shared module: `pub const c = @import("c");` plus the shims
  platform/time.zig     replaces src/platform/posix/time.c
  core/intcache.zig     replaces src/core/intcache.c
build/zig/zigimpl.zig   build helper: translate-c step, `moar` module, `moar_zig` object
build/sources.list      new [zig] section (§5)
```

Zig sources mirror the C tree under `src/zig/`. `root.zig` contains no code of
its own. Implementation files `@import("moar")` and never `@import("c")`
directly; `moar.zig` is the only place that names the translate-c module, so
the shims can wrap or replace translated declarations later without touching
implementations.

## 4. The `moar` module

`src/zig/moar.zig`:

```zig
pub const c = @import("c");   // translate-c of src/moar.h

pub const ThreadContext = c.MVMThreadContext;
pub const Object = c.MVMObject;
pub const Collectable = c.MVMCollectable;
pub const STable = c.MVMSTable;
pub const REPROps = c.MVMREPROps;
```

### 4.1 Shims defined in this spec

Each shim is a `pub inline fn` whose body is a transliteration of the C macro
or inline function it replaces, calling the translated functions by name. The
exact set:

| C                                   | Zig                                                        |
|-------------------------------------|------------------------------------------------------------|
| `STABLE(o)`                         | `stable(o: *Object) *STable`                               |
| `REPR(o)`                           | `repr(o: *Object) *const REPROps`                          |
| `OBJECT_BODY(o)`                    | `objectBody(o: *Object) *anyopaque`                        |
| `IS_CONCRETE(o)`                    | `isConcrete(o: *Object) bool`                              |
| `MVM_ASSIGN_REF(tc, root, addr, v)` | `assignRef(tc, root: *Collectable, addr: anytype, v: anytype) void` |
| `MVMROOT(tc, a) { ... }`            | `const r = root(tc, &a); defer r.pop(tc);`                 |
| `MVMROOT2..6(tc, a, b, ...) { ... }`| `const r = rootN(tc, .{ &a, &b, ... }); defer r.pop(tc);`  |

Semantics to preserve:

- `assignRef` calls `c.MVM_gc_write_barrier(tc, root, @ptrCast(v))` then
  stores `v` through `addr`. `addr` is `*?*T` or `**T` for any collectable
  `T`; `v` may be optional. The `MVM_GC_DEBUG` variant (owner check,
  `MVM_ASSERT_NOT_FROMSPACE`) is reproduced under
  `if (c.MVM_GC_DEBUG != 0)`; translate-c exposes the define as a constant.
- `root` pushes with `c.MVM_gc_root_temp_push(tc, @ptrCast(ref))` and returns
  a zero-size struct whose `pop(tc)` calls `c.MVM_gc_root_temp_pop(tc)`.
  `rootN` takes a tuple of pointers, pushes each in order after
  `__MVM_gc_root_temp_push_ensure_space(tc, n)` exactly as the C macros do,
  and its `pop` calls `c.MVM_gc_root_temp_pop_n(tc, n)` with `n` known at
  comptime. Every pointer in the tuple must point at a pointer-to-collectable
  type; anything else is a `@compileError` naming the offending field.
- Shims never allocate and never throw.

`GET_REG`, `GET_LEX` and the other interpreter macros are out of scope; they
arrive with the op-table work (Appendix A, item 3).

### 4.2 What the module does not do

No Zig-side allocator wrapping, no error-union translation of `MVM_oops` or
`MVM_exception_throw_adhoc` (they are `noreturn` externs and are called as
such), no re-export renaming beyond the five type aliases above. YAGNI; later
specs add what their ports need.

## 5. `build/sources.list`: the `[zig]` section

Grammar of a line in the new section, after the existing trimming and comment
handling:

```
<zig file>: <c file> [<c file> ...]
```

Example:

```
[zig]
src/zig/platform/time.zig: src/platform/posix/time.c
src/zig/core/intcache.zig: src/core/intcache.c
```

Rules, enforced identically by `Configure.pl`'s `read_sources_list` and
`build/zig/sources.zig`:

- Every `<c file>` must appear in exactly one other section; otherwise the
  parser hardfails naming the file and the line. A C file may appear on at most
  one `[zig]` line.
- When the Zig groups are **on**, every listed C file is removed from the
  section it appears in before object lists are built, and every `<zig file>`
  must be imported by `src/zig/root.zig`. The zig build checks the latter by
  parsing `root.zig` for `@import("...")` strings in `sources.zig` and failing
  with a message naming the missing file; the Perl build does not check it
  (the link would fail with an undefined symbol anyway).
- When the Zig groups are **off**, the section is parsed and validated but has
  no effect.
- The `[zig]` section may be empty or absent. `core` and `main` remain the
  only required sections. Unknown sections still hardfail.

`sources.zig`'s `Lists` grows a `zig: []const ZigEntry` field where
`ZigEntry = struct { zig: []const u8, replaces: []const []const u8 }`, and a
function `applyZig(lists: *Lists) void` that performs the removal. The `[core]`
split into `OBJECTS1`/`OBJECTS2` in `Configure.pl` happens after removal.

## 6. The zig build

New option in `build/zig/options.zig`:

- `-Dzig-impl=<bool>`, default `true`: compile the `[zig]` implementations and
  drop the C files they replace. With `false`, libmoar is built exactly as on
  `zig-build-phase2`.
- `-Dconfig-h=<path>`: use an existing `config.h` instead of rendering one.
  The path must end in `gen/config.h`; its grand-parent directory is added as
  an include path ahead of `src` for the translate-c step and the object. When
  this option is given, the refuse-to-run check for a Perl-written
  `src/gen/config.h` in `build.zig` is skipped, because that file is now the
  intended input. Only the `zig-objects` step is supported in this mode; the
  `install` and `test` steps are not required to work with it and the option's
  help text says so.

New helper `build/zig/zigimpl.zig`:

```zig
pub const Impl = struct {
    translate: *std.Build.Step.TranslateC,
    moar_mod: *std.Build.Module,   // src/zig/moar.zig with import "c"
    object: *std.Build.Step.Compile, // name "moar_zig", root src/zig/root.zig
};
pub fn add(b: *std.Build, opts: Options, facts: Facts, lists: sources.Lists,
           config_h: ?*std.Build.Step.ConfigHeader, config_h_dir: ?std.Build.LazyPath) Impl;
```

- The translate-c step takes the same include paths as `moar.addIncludes`,
  the same defines as `moar.cflags` (`MVM_TRACING=0`, `MVM_CGOTO=1`,
  `MVM_HEAPSNAPSHOT_FORMAT=<n>`, `MVM_BUILD_SHARED`, and `NDEBUG` for
  non-Debug), `link_libc = true`, the build's target and optimize mode, and
  either `addConfigHeader(config_h)` or the `-Dconfig-h` include path.
- The object has `root_source_file = src/zig/root.zig`, imports `moar`,
  `link_libc = true`, `pic = true`, same target, optimize and CPU as libmoar,
  and `strip`/`omit_frame_pointer` matching `thirdparty.newCModule` for the
  optimize mode. It does not link libmoar or any third-party library.
- `addLibmoar` gains `zig: ?zigimpl.Impl` in `LibInputs`. When present it
  calls `sources.applyZig` on its lists before `addCSourceFiles` and
  `lib.addObject(zig.object)`.

New step `zig-objects`: installs the object to `<prefix>/lib/moar_zig.o` via
`b.addInstallFile`. It is the only step the Perl build calls. It depends on
nothing else in the graph, so `zig build zig-objects -Dconfig-h=src/gen/config.h`
builds the object and nothing more.

`zig build unit-test` gains a test compile of `src/zig/moar.zig` (so no
`export fn` is duplicated) that imports `c`, links libc and `linkLibrary`s the
shared libmoar, and is run with `addRunArtifact`. Its tests:

- create an instance with `c.MVM_vm_create_instance()`, take
  `instance.main_thread` as `tc`, and destroy it at the end of each test;
- `root`/`rootN`: after pushing k pointers, `tc.num_temproots` has grown by
  k, and after `pop` it is back to the starting value, for k in 1, 2, 3, 6;
- `assignRef`: allocate two objects with `c.MVM_repr_alloc_init` on
  `instance.boot_types.BOOTArray`; assigning one into a slot of the other
  stores the value and leaves `tc.num_gen2roots` unchanged (both nursery).
  Then set `MVM_CF_SECOND_GEN` in the root object's `header.flags2` by hand
  and assign again: `tc.num_gen2roots` grows by one and the root's `flags2`
  gains `MVM_CF_IN_GEN2_ROOT_LIST`, which is the C barrier's behaviour;
- `stable`/`repr`/`isConcrete` on `instance.VMNull` and on a type object
  from `instance.boot_types`.

`zig build test` runs as today with the Zig groups on. The plan adds one
clean build with `-Dzig-impl=false` followed by `zig build test` to prove the
C path still links and runs.

## 7. The Perl build

`Configure.pl`:

- New option `zig=s`. When given, `$config{zig}` is the path (hardfail if it is
  not executable), `read_sources_list` applies the `[zig]` section to the
  returned sections, and `$config{zig_objects}` is `zig-out/lib/moar_zig@obj@`.
  Without it, `$config{zig}` and `$config{zig_objects}` are empty strings and
  no object list changes.
- `$config{zig_build_flags}` carries the options that must agree with the C
  compile: `-Dconfig-h=src/gen/config.h`, `-Dzstd=<true|false>` from
  `$config{heapsnapformat} == 3`, `-Doptimize=Debug` when `--debug` was given
  and `-Doptimize=ReleaseFast` otherwise, and `-Djit=<true|false>` from
  `$config{jit_obj}` being non-empty. (`-Djit` does not change struct layout
  today; it is passed so the two sides agree if that ever changes.)
- `read_sources_list($file, $apply_zig)` learns the `[zig]` section with the
  validation in §5. When `$apply_zig` is true, the returned sections already
  have the replaced C files removed, and a new key `zig_files` lists the Zig
  files in order; when false, the `[zig]` section is validated and dropped.
  The caller passes `defined $config{zig}`. The `[core]` split into
  `OBJECTS1`/`OBJECTS2` runs on the returned, already-reduced list.
- `--help` documents `--zig=PATH` next to `--cc`.

`build/Makefile.in`:

- New variables `ZIG = @zig@`, `ZIG_BUILD_FLAGS = @zig_build_flags@`,
  `ZIG_OBJECTS = @zig_objects@`.
- `@zig_objects@` is appended to `OBJECTS2`.
- New rule: `zig-out/lib/moar_zig@obj@` depends on `src/gen/config.h`,
  `build.zig`, `build.zig.zon`, `build/sources.list`, `build/zig/zigimpl.zig`
  and `$(ZIG_SOURCES)`, and runs
  `$(ZIG) build zig-objects --prefix zig-out $(ZIG_BUILD_FLAGS)`.
  `ZIG_SOURCES = @zig_sources@` is expanded by Configure from the `[zig]`
  section plus `src/zig/root.zig` and `src/zig/moar.zig`; no `$(wildcard)`,
  which nmake lacks. Zig's own cache makes the rule cheap when nothing
  changed, so over-approximate dependencies cost little.
- `clean` removes `zig-out` and `.zig-cache`; `distclean` already removes
  `Makefile`.

`docs/zig-build.md` gains a section "Zig implementations" describing
`-Dzig-impl`, `-Dconfig-h`, the `[zig]` section and `--zig=PATH`.

## 8. Proof ports

### 8.1 `src/zig/platform/time.zig` replaces `src/platform/posix/time.c`

Exports, with behaviour identical to the C:

- `MVM_platform_now() u64`: wall-clock nanoseconds since the epoch via
  `c.clock_gettime(c.CLOCK_REALTIME, ...)`; returns 0 on failure. (The macOS
  Mach branch is not ported: the zig build is linux-only until phase 5, and
  the C file stays selectable there.)
- `MVM_platform_sleep(seconds: f64)`: `nanosleep` retried on `EINTR` with the
  remaining time, as in C.
- `MVM_platform_nanosleep(nanos: u64)`: same loop.
- `MVM_platform_decodelocaltime(tc, time: i64, decoded: [*]i64)`:
  `c.localtime_r`; on `NULL` throws through
  `c.MVM_exception_throw_adhoc(tc, "Could not decode localtime: %s", strerror(errno))`;
  otherwise fills `decoded[0..9]` with sec, min, hour, mday, mon+1, year+1900,
  wday, yday, isdst in that order.

All four use the translated libc declarations from the `c` module, not
`std.posix`, so the object has no dependency on Zig's own libc wrappers.

### 8.2 `src/zig/core/intcache.zig` replaces `src/core/intcache.c`

Exports `MVM_intcache_for`, `MVM_intcache_get`, `MVM_intcache_type_index`
with the C semantics: four type slots, values -1..14, the
`mutex_int_const_cache` lock held across slot search and fill, `MVMROOT(tc,
type)` around the fill loop (`moar.root` + `defer`), each cache entry and the
type slot registered with `c.MVM_gc_root_add_permanent_desc` using the same
description strings. Early return when the type is already cached must unlock
the mutex, as the C does.

This file is exercised on every boxed small integer, so a shim mistake fails
the stage0 smoke test immediately.

## 9. Acceptance criteria

All of these are run by the plan's final verification, on this machine:

1. `rm -f src/gen/config.h src/gen/config.c src/gen/config.o && zig build --prefix <abs> install && zig build test`
   passes with the Zig groups on; `nm -D <prefix>/lib/libmoar.so` lists
   `MVM_platform_now` and `MVM_intcache_get`; the build log contains no
   compile of `src/platform/posix/time.c` or `src/core/intcache.c`.
2. The same with `-Dzig-impl=false` passes, and the build compiles both C
   files.
3. `zig build unit-test` passes, including the new shim tests.
4. `perl Configure.pl --zig=/usr/bin/zig && make -j && make install` into a
   scratch prefix succeeds; the generated `Makefile` lists
   `zig-out/lib/moar_zig.o` in `OBJECTS2` and lists neither `time.o` nor
   `intcache.o`; the stage0 smoke test
   (`moar --libpath=... nqp.moarvm -e 'say(1+1)'`) prints 2.
5. `perl Configure.pl && make -j` (no `--zig`) produces a `Makefile` with no
   `zig` reference beyond comments, and compiles both C files.
6. `perl Configure.pl --cc=zig --zig=/usr/bin/zig && make -j` succeeds, proving
   the two options compose.
7. `zig fmt --check build.zig build/zig src/zig tools/zig` and `perl -c
   Configure.pl` are clean.

## 10. Out of scope

- The generic hash table and the small-mode dynamic hash (next spec).
- Any further ports, including the other `[platform-posix]` files.
- `GET_REG` and interpreter shims.
- Making `-Dconfig-h` work for `install`/`test`.
- Darwin and non-glibc targets (phase 5 of the build migration).
- Changing Darwin's default compiler (left out of the cherry-pick).

## Appendix A: port roadmap from the brainstorm (for later specs)

Ordered as recommended; sizes are from this checkout.

| # | Candidate | Zig advantage | Size today |
|---|-----------|---------------|------------|
| 1 | One generic Robin Hood table replacing `str_`, `ptr_`, `fixkey_`, `index_`, `uni_hash_table` | `comptime fn HashTable(Key, Entry, hash, eql)` collapses five hand-specialised copies; C APIs kept as `export fn` wrappers | 4,490 lines, 14 C files use the string table |
| 2 | Small-then-large dynamic hash on top of 1 | Small mode (64 or 256 entries): flat entries plus byte tags, `@Vector` tag compare, no metadata or salt; migrates to Robin Hood at N% full in one pass (same work as today's resize). Capacity and N comptime. Observable change: small-mode iteration is insertion order. Spike first: size histogram in `hash_allocate_common` over a spectest run | — |
| 3 | Op tables from `src/core/oplist` at comptime | Removes the Raku dependency (`tools/update_ops.raku`) from MoarVM's own dev loop; `@embedFile` + comptime parse yields `MVMOpInfo[]`, opcode enum, validator flags | `ops.c` 15,654 generated lines |
| 4 | Interpreter dispatch, later | `switch` on dense enum or `@call(.always_tail)` threaded dispatch, op bodies as functions; needs 3 and `GET_REG` shims | `interp.c` 7,103 lines |
| 5 | REPR vtables and reprconv | `makeReprOps(comptime R)` fills slots or REPR-named defaults; leaf REPRs first (`P6int`, `P6num`, `P6str`, `CPointer`, `MVMNull`, `Uninstantiable`); registry order fixed | 47 REPRs, 318 default-macro uses, 103 wrappers |
| 6 | Derived `gc_mark`/`serialize`/`deserialize`/`copy_to`/`describe_refs` | `inline for (std.meta.fields(Body))`; format must stay byte-identical (round-trip stage0) | 143 worklist sites, 19 REPRs with ser pairs |
| 7 | String encoders | Comptime tables for single-byte codecs, shared stream loop, `std.unicode` | 8 codecs, 3,415 lines |
| 8 | Platform layer | `std` abstractions; serves phase 5 | 4 files each in `posix`, `win32` |
| 9 | Vendored libs: sha1, zmij, libatomicops (`std.crypto.hash.Sha1`, `std.fmt`, atomics); libtommath only behind a benchmark gate | fewer 3rdparty trees | — |
| 10 | `ucd2c.pl` as a zig build step | Perl removal; data too large for comptime | `unicode_db.c` 10 MB |
