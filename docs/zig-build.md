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
| `-Dstrip=` | `true` unless `-Doptimize=Debug` | strip symbols from libmoar's C objects and the Zig object; `false` keeps them for `perf report`/`perf annotate` (the generated code is the same) |
| `-Dlto=` | `true` unless `-Doptimize=Debug` | full link-time optimisation of libmoar together with the Zig object (`lto = .full` on both), so the LTO link binds the hash engine's exports locally and inlines the small ones (iteration); the lookup exports are still called directly; `false` links about three times faster (see "Hash engine") |
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
C compiler. `--zig-lto` (with `--zig` and `--cc=zig`) is the Perl build's
`-Dlto`: it adds `-flto` to the C compile and link flags and `-Dlto=true`
to the `zig build zig-objects` call. It is on by default when both are
given and `--debug` is not; `--no-zig-lto` turns it off. With any other
compiler it stays off (the Makefile passes `-Dlto=false`, because gcc
cannot link the LLVM bitcode object), and asking for it explicitly is
refused.

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
| `small.zig` | a flat array of entries in insertion order, each tagged with the top byte of its cached hash and found by a vector compare of the tags, up to `max_capacity` entries | the string table's first rung |
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

The exports are separate functions in libmoar, so without LTO every call
from the C code (the `MVMHash` REPR, the interpreter, spesh) is a call
through the PLT that the C compiler cannot inline. `-Dlto` (`--zig-lto`
with `--cc=zig` in the Perl build), on by default outside Debug builds,
links libmoar and the Zig object with
full LTO and gives the exports protected visibility: they stay in libmoar's
dynamic symbol table (`nm -D`), so the microbenchmark and anything else
outside libmoar still link against them, but calls from inside libmoar bind
to them locally (default-visibility symbols are interposable, and LTO keeps
calling them through the PLT). With that binding the LTO link inlines the
iteration exports (`next`, `current_nocheck`) into their callers. In one
set of interleaved runs, a Robin Hood iterate at the nqp level took
0.96-0.98 of the plain C engine's time with `-Dlto` and 1.06-1.07 without
it (1.03-1.04 against a C build that also uses LTO, inside the spread). The
lookup and delete exports are one large function each, so LTO mostly calls
them directly rather than inlining them: no PLT, but still a call. Lookup
and delete still run in 0.90-0.93 of the plain C engine's time under
`-Dlto` (0.95-0.98 of an LTO-built C engine).
`tools/check-lto-binding.sh <libmoar.so>` shows the binding: PLT calls to
`MVM_str_hash_*` (0 under LTO) and the call sites left of
`MVM_str_hash_fetch_nocheck`. Without `-Dlto` the exports have default
visibility and the link is unchanged. LTO also speeds up the C side (with
the C engine, the hash operations at the nqp level run in 0.94-0.96 of
their time without it). The link takes about three times as long (about a
minute against 20 seconds for `zig build install`); `-Dlto=false` buys that
time back, and Debug builds leave it off. It is on by default so that the
LTO path (protected exports, bitcode object) is the one every build
exercises rather than an option that drifts untested. gcc builds cannot
use it, because gcc cannot link the Zig object's LLVM bitcode. So
`--zig-lto` requires both `--zig=PATH` and `--cc=zig`; Configure.pl leaves
it off otherwise and refuses an explicit `--zig-lto`, naming the missing
one.

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

Measured on 2026-11-02 after the tuning campaign (the full tables with
their spreads, and what each change did, are in
`traces/llm/plans/2026-11-02-zig-hash-tuning.md`, "Results"; the engine as
first written is measured in `2026-11-02-zig-hash-engine.md`). The
scoreboard is the nqp-level harness `tools/bench/hash-bench.nqp`
(`hash-bench.sh --nqp`), read from interleaved runs on the same binaries,
Zig time over C time. Both engines built with the defaults, so with LTO
(the re-run after LTO became the default; the per-cell tables are in
`traces/llm/bench/tuning-lto-default-nqp.md`):

| Operation | Small (16-64 entries) | Robin Hood (65-16384 entries) |
|---|---|---|
| insert | 0.36-0.44 | 0.75-1.03 |
| lookup hit | 0.75-0.92 | 0.95-1.03 |
| lookup miss | 0.74-0.93 | 0.96-0.98 |
| delete | 0.74-0.95 | 0.95-0.97 |
| iterate | 0.56-0.65 | 1.02-1.04 |
| N-th insert | 0.24-0.62 | 1.06-1.16 (128-16384, inside the C's spread) |

Against a C engine built without LTO the default Zig build is faster
still (Robin Hood lookups and delete 0.90-0.97, iterate 0.95-0.98). With
`-Dlto=false` on both sides (the campaign's own ladder) the Robin Hood
lookups sit at 0.98-1.08, iterate at 1.02-1.07 and Small lookup miss at
63-64 entries at 1.08-1.13, the only cells over the 5 percent line.

The Small tier allocates 0.29-0.30 of the C engine's block. The insert that
migrates a table from Small to Robin Hood, the 65th, costs 0.54 of the C
engine's own resize at its 97th insert (about 1050 against 1940 ns). The
migration builds the Robin Hood block at the size the C engine uses for 65
entries (128 slots) and moves the entries in without looking them up, so
the Zig engine, like the C, then resizes at the 97th insert, at the C's
cost.

What the tuning changed: the Small tier's scan returns a plain index, loads
the entry base once and compares an 8-byte key in one load. The Robin Hood
tier does the same key test and moves 16-byte entries inline instead of
byte by byte. Each string-table export runs the whole lookup in one
function, with the cached hash read inline as the C header does. The
policy layer reads the tier, set and stale bytes in one load and switches
on the tier directly for the standard tier set. The migration is sized and
filled as above. Two further attempts did not move their targets and were
reverted: an extra cached-hash test in key equality, and forcing the Small
scan inline at every capacity.

Still above the line at the nqp level: a Small lookup miss at 63 entries
(1.08: a miss scans all 64 tags, and the few false tag matches reach the
out-of-line string compare), and the N-th insert into a Robin Hood table
of 128 and 256 entries (1.13 and 1.11, about 3.5 ns on an insert into a
cold table; no single cause was found). A miss at 64 entries passes only
marginally (1.05). At the C API (`zig build hash-bench`), where every Zig
call crosses from the benchmark into libmoar while the C is inlined into
the benchmark, Small lookups at 63-64 entries cost 1.09-1.13 of the C time,
a Small delete there 1.23, Robin Hood lookups up to 1.10 and a Robin Hood
iterate 1.32-1.33 (two calls per element).

At the Raku level (a `Hash` on a rakudo built on each engine, five
invocations each) every operation runs in 0.66-1.07 of the C engine's time,
except the 65th insert, which costs 3.75 times the C engine's ordinary
insert there (4.29 before the tuning). The rakudo spectest passes on both
engines with no new failure. The runs (C first, then Zig) drifted over
the session, so the Zig engine's 0.89 of the C's wall time reads as
parity. Its peak RSS measured 3 percent above the C engine in this
campaign's runs, the Zig runs climbing 686 to 725 MB across the session
while the C runs stayed flat; not yet investigated.

Observable changes with the Zig engine:

- Iteration order of a hash in the Small tier is reverse insertion order,
  perturbed by deletes: a delete moves the last entry into the hole, so
  that entry is then visited where the deleted one was. A hash is in the
  Small tier while it has never held more than 64 entries and was not
  built for more; one presized above 64, or one that grew past 64 and
  shrank, stays in Robin Hood (migration is upward only).
- Hash creation and growth no longer consume the user-visible RNG (the
  Robin Hood salt comes from the engine's own generator, `rng.zig`).
- `HASH_DEBUG_ITER` is unavailable (`#error` at compile time).
- Some operations are still slower than with the C engine, by the
  measured ratios above.

## Not yet supported

Any OS other than linux, any CPU other than x86_64, system libuv/libtommath/libffi, MSVC, coverage
and sanitizer builds, `--relocatable`.
