# Building MoarVM with zig

An alternative to `perl Configure.pl && make` that needs only zig (0.16.0):

    zig build --prefix /abs/path/to/prefix install
    zig build unit-test       # unit tests of the build helpers (sources.list parser, version, config rendering) and of the JIT generators
    zig build check-jit-tools # diff the Zig JIT generators against the Perl originals (needs perl; exists only when the JIT is on)
    zig build test            # installs, then runs the installed moar: --version and the nqp stage0 smoke test
    zig build hash-bench -- --sizes=4,64,65  # the string hash table microbenchmark against this build's engine (tools/bench/hash-bench.sh runs it for both)

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

## Hash engine

The five hash tables of `src/core/` (`str_hash_table.c`, `ptr_hash_table.c`,
`fixkey_hash_table.c`, `index_hash_table.c`, `uni_hash_table.c`) have Zig
implementations under `src/zig/core/hash/`, one `[zig]` line each
(`str_exports.zig: src/core/str_hash_table.c` and so on). They share one
engine: `table.zig` (the policy layer, `Table(Spec)`, which owns the control
block, grows, migrates between tiers and publishes new blocks under the C
engine's safepoint discipline), `tier.zig` (tier sets) and the two tiers in
`tiers/`:

| Tier | Storage | Used by |
|---|---|---|
| `small.zig` | an insertion-ordered array of entries, no hashing of the keys, up to `max_capacity` entries | the string table's first rung |
| `robinhood.zig` | the open-addressing Robin Hood table the C files implement today, with the same growth and probe-limit rules | every table's final rung |

A table is built on a *tier set*, a ladder of rungs with the entry count at
which each takes over. The string table (`str.zig`) builds on `standard`:
Small from 0 entries, Robin Hood from `small_threshold` entries, where
`small_threshold` is 64 (`str.zig`; chosen from a histogram of final table
sizes over the rakudo build and spectest, in which 99.7 percent of non-empty
tables hold at most 64 entries). The insert that takes a table past 64
migrates it into a Robin Hood block in one step. `large_only` (Robin Hood
from 0) is defined for a future pre-allocate-big hint and is not used yet.
The pointer, fixkey, index and Unicode tables each use a single unsalted
Robin Hood rung (`only_rung` in `ptr.zig`, `fixkey.zig`, `index.zig`,
`uni.zig`).

The headers switch on `MVM_ZIG_IMPL`, which `config.h` defines to 1 when the
Zig implementations are built (`zig build` unless `-Dzig-impl=false`;
`perl Configure.pl --zig=PATH`) and leaves undefined otherwise. Under the
define `src/core/*_hash_table.h` declare the control structs incomplete and
`src/core/*_hash_table_funcs.h` declare the functions `extern` instead of
defining them inline, and the exports in `src/zig/core/hash/*_exports.zig`
provide them under the C names (plus `MVM_round_up_log_base2`). Without the
define the C files compile as before.

Two benchmarks compare the engines, both run by `tools/bench/hash-bench.sh`,
which writes `traces/llm/bench/hash-<date>.md` with the raw TSVs beside it:

    tools/bench/hash-bench.sh                       # the C-API microbenchmark, both engines
    tools/bench/hash-bench.sh --raku-c=$PC/bin/raku --raku-zig=$PZ/bin/raku
                                                    # plus tools/bench/hash-bench.raku on a Raku built on each engine

The microbenchmark is `zig build hash-bench` (sizes 4 to 1048576 around the
threshold, insert, lookup hit and miss, delete, iterate, the N-th insert at
the threshold, bytes allocated); the Raku script does the same on a `Hash`
and reports the peak-RSS delta. The script removes the Perl build's
`src/gen/config.{h,c,o}` before it starts.

Measured on 2026-11-02 (the full tables, and the rakudo spectest timings,
are in `traces/llm/plans/2026-11-02-zig-hash-engine.md`, "Benchmark
results"). At the Raku level (a `Hash` on a rakudo built on each engine)
small hashes of up to 64 entries run in 0.80-1.04 of the C engine's time
on every operation (insert 0.80-0.83, lookup hit 0.87-0.97, delete
0.83-1.01; up to 1.23 at size 4). Large hashes run in 0.92-1.17 of the C
engine's time (insert 1.61 at 65536 entries, iterate 0.66 at a million),
and the 65th insert, which migrates the table to Robin Hood, costs 4.29
times the C engine's ordinary insert. At the C API the Small tier inserts
in 0.3-0.35 of the C time, iterates in 0.7 and allocates a third to a half
of the C block, but a lookup hit costs 1.4-1.9 and a delete 2.9-3.4 times
the C engine, and the Robin Hood tier is 1.1-1.8 times slower than the C
engine on every operation. So at the C API small-tier lookup hit and
delete, and large hashes across the board, are currently slower than the C
engine; tuning them is a follow-up campaign and nothing in the engine is
tuned yet.

Observable changes with the Zig engine:

- Iteration order of a hash of at most 64 entries is insertion order
  (perturbed by deletes: a delete moves the last entry into the hole).
- Hash creation and growth no longer consume the user-visible RNG (the
  Robin Hood salt comes from the engine's own generator, `rng.zig`).
- `HASH_DEBUG_ITER` is unavailable (`#error` at compile time).
- Large hashes may be slower by the measured ratio above.

## Not yet supported

Any OS other than linux, any CPU other than x86_64, system libuv/libtommath/libffi, MSVC, coverage
and sanitizer builds, `--relocatable`.
