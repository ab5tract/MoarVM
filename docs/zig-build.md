# Building MoarVM with zig

An alternative to `perl Configure.pl && make` that needs only zig (0.16.0):

    zig build --prefix /abs/path/to/prefix install
    zig build unit-test       # unit tests of the build helpers (sources.list parser, version, config rendering) and of the JIT generators
    zig build check-jit-tools # diff the Zig JIT generators against the Perl originals (needs perl; exists only when the JIT is on)
    zig build test            # installs, then runs the installed moar: --version and the nqp stage0 smoke test

Options (`zig build --help` lists them):

| Option | Default | Meaning |
|---|---|---|
| `-Doptimize=` | `ReleaseFast` | zig's standard optimisation mode (`Debug` for a -g3 style build) |
| `-Dtarget=` | generic x86-64 linux | only glibc `x86_64-linux` is supported so far |
| `-Dcpu=` | `baseline` | pass `-Dcpu=native` for a build tuned to the host CPU (the default matches gcc's generic x86-64) |
| `-Djit=` | `true` on x86_64 | build the x86-64 JIT (DynASM via the zig-built minilua, tables from the Zig generators) |
| `-Dstatic=` | `false` | build `libmoar.a` instead of `libmoar.so` |
| `-Dmimalloc=` | `true` | use the bundled mimalloc |
| `-Dzstd=` | `true` | link the system libzstd for heap snapshot format 3 |
| `-Dnqp-stage0=` | `../src/vm/moar/stage0` | where `zig build test` finds nqp's stage0 bytecode |
| `-Dzig-impl=` | `true` | compile the Zig implementations from the `[zig]` section of `build/sources.list` instead of the C files they replace |
| `-Dconfig-h=` | unset | path to an existing `gen/config.h` (the Perl build's `src/gen/config.h`) to build the Zig implementations against; only `zig build zig-objects` is supported with it |

Always pass an absolute `--prefix`: it is baked into the binary's RUNPATH,
into `nqp::backendconfig` and into `share/pkgconfig/moar.pc`. A relative
`--prefix` is rejected. The RUNPATH is `$ORIGIN/../lib` followed by `<prefix>/lib`.

## How it maps to the Perl build

| Perl build | zig build |
|---|---|
| `build/probe.pm` compiler probes | constants for clang plus a per-OS table in `build/zig/platform.zig` |
| `build/config.h.in` expanded by Configure.pl | same template rendered by zig's ConfigHeader step (`build/zig/config.zig`) |
| `build/config.c.in` | rendered by `build/zig/config.zig` into the zig cache |
| object lists in `build/Makefile.in` | `build/sources.list`, read by both Configure.pl and `build/zig/sources.zig` |
| `build/setup.pm` third-party rules, dyncall's `./configure` | `build/zig/thirdparty.zig` |
| `make install` | `zig build install` (`build/zig/install.zig`) |

## Coexisting with the Perl build in one checkout

`perl Configure.pl` writes `src/gen/config.h` and `src/gen/config.c` next to
the sources. Because `src/moar.h` includes `"gen/config.h"` with a quote
include, that file would shadow the header the zig build generates, so
`zig build` refuses to run while it exists and tells you to remove it:

    rm -f src/gen/config.h src/gen/config.c src/gen/config.o

Going the other way needs nothing: the zig build writes only under
`.zig-cache/` and the install prefix, and `perl Configure.pl` recreates its
files. Both builds compile the same `build/sources.list`.
The one exception to the refuse-to-run rule is `-Dconfig-h=src/gen/config.h`,
which tells `zig build zig-objects` to translate the Zig implementations
against the Perl build's own `config.h` (see "Zig implementations").

## JIT code generation

The Perl build runs three generators for the JIT; the zig build has
equivalents that need no Perl:

| Perl build | zig build |
|---|---|
| `3rdparty/dynasm/minilua` + `dynasm.lua` on `src/jit/x64/emit.dasc` | the same, with `minilua` built by zig (`build/zig/jit.zig`); output byte-identical |
| `tools/expr-template-compiler.pl` | `tools/zig/expr_template_compiler.zig`; output identical from line 2 |
| `tools/tiler-table-generator.pl` | `tools/zig/tiler_table_generator.zig`; identical after renumbering rulesets canonically (the Perl tool's numbering follows Perl hash order and differs between runs; `tools/canonicalize-tile-table.pl` applies the same renumbering to a Perl output) |

The generated `core_templates.h` and `tile_pattern.h` live in the zig cache
and are put on the include path ahead of `src/`, so Perl-generated copies
under `src/jit/` are ignored. `zig build test` additionally runs an nqp loop
with `MVM_SPESH_NODELAY=1 MVM_SPESH_BLOCKING=1 MVM_JIT_EXPR_ENABLE=1` which
exercises both JIT paths (the test asserts the program's result, not that
frames were compiled). That run is skipped when nqp's stage0 directory is
absent or with `-Djit=false`. `check-jit-tools` exists only when the JIT is on.

## Zig implementations

Parts of the VM are being ported to Zig, one C file at a time
(`traces/llm/specs/2026-11-02-zig-port-step0-design.md`). The
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

## Not yet supported

Any OS other than linux, any CPU other than x86_64, system libuv/libtommath/libffi, MSVC, coverage
and sanitizer builds, `--relocatable`.
