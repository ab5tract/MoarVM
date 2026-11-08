# Building MoarVM with zig

An alternative to `perl Configure.pl && make` that needs only zig (0.16.0):

    zig build --prefix /abs/path/to/prefix install
    zig build unit-test       # unit tests of the build helpers (sources.list parser, version, config rendering) and of the JIT generators
    zig build check-jit-tools # diff the Zig JIT generators against the Perl originals (needs perl; exists only when the JIT is on)
    zig build test            # installs, then runs the installed moar: --version and the nqp stage0 smoke test
    zig build hash-bench -- --sizes=4,64,65  # the string hash table microbenchmark against this build's engine (tools/bench/hash-bench.sh runs it for both)
    zig build uni-bench -- --runs=3 --sample=256  # the unicode lookup tables (property, sequence, codepoint name, property value) benchmark against this build's engine; tools/bench/uni-bench.nqp is its nqp twin, tools/bench/hash-ab.sh --ladder=uni runs both
    zig build strategy-test -Dnqp-prefix=<P>  # the hashstrategy op tests on <P>/bin/nqp-m (needs an nqp that maps the op)

Options (`zig build --help` lists them):

| Option | Default | Meaning |
|---|---|---|
| `-Doptimize=` | `ReleaseFast` | zig's standard optimisation mode (`Debug` for a -g3 style build) |
| `-Dtarget=` | generic x86-64 linux | only glibc `x86_64-linux` is supported so far |
| `-Dcpu=` | `x86_64_v3` on x86_64, else `baseline` | the AVX2 class (Haswell, Zen and later); `-Dcpu=baseline` for a generic x86-64 build (gcc's default), `-Dcpu=native` for the host CPU. The Perl build's `--march` (default `x86-64-v3` with `--cc=zig`) is the same knob |
| `-Djit=` | `true` on x86_64 | build the x86-64 JIT (DynASM via the zig-built minilua, tables from the Zig generators) |
| `-Dstatic=` | `false` | build `libmoar.a` instead of `libmoar.so` |
| `-Dmimalloc=` | `true` | use the bundled mimalloc |
| `-Dzstd=` | `true` | link the system libzstd for heap snapshot format 3 |
| `-Dnqp-stage0=` | `../src/vm/moar/stage0` | where `zig build test` finds nqp's stage0 bytecode |
| `-Dnqp-prefix=` | unset | prefix of an installed MoarVM and nqp (`<P>/bin/nqp-m`) for `zig build strategy-test`; when given, `zig build test` runs that step too |
| `-Dstrip=` | `true` unless `-Doptimize=Debug` | strip symbols from libmoar's C objects and the Zig object; `false` keeps them for `perf report`/`perf annotate` (the generated code is the same) |
| `-Dlto=` | `true` unless `-Doptimize=Debug` | full link-time optimisation of libmoar together with the Zig object (`lto = .full` on both), so the LTO link binds the hash engine's exports locally and inlines the small ones (iteration); the lookup exports are still called directly; `false` links about three times faster (see "Hash engine") |
| `-Dhash-stats=` | `false` | diagnostic build with the hash engine's statistics compiled in (see "Statistics"); keeps debug info and forces `-Dstrip=false` |
| `-Duni-swiss=` | `false` | compile the Unicode hash tables' Swiss set (strategy 1 of `MVM_uni_hash_build_strategy`) into libmoar; no internal site uses it, so the shipped build leaves it out and strategy 1 throws; the uni benchmark needs it, unit tests always have it |
| `-Dgc-debug=` | `0` | `MVM_GC_DEBUG` 0..3 for the C sources and translate-c; 1 and up compile in the GC debug checks, the per-collection log (`$MVM_GC_LOG`) and the RSS pin (`$MVM_GC_DEBUG_RSS`) (see "Garbage collector") |
| `-Dnursery-size=` | `16777216` | `MVM_NURSERY_SIZE`, the maximum nursery size in bytes; small values stress the collector |
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
engine's safepoint discipline), `tier.zig` (tier sets) and the four tiers in
`tiers/`:

| Tier | Storage | Used by |
|---|---|---|
| `small.zig` | a flat array of entries in insertion order, each tagged with the top byte of its cached hash and found by a vector compare of the tags, up to `max_capacity` entries | the string table's first rung |
| `robinhood.zig` | the open-addressing Robin Hood table the C files implement today, with the same growth and probe-limit rules | the final rung of the default string ladder (set 0), and of the pointer, fixkey, index and Unicode tables |
| `swiss.zig` | Swiss-style 16-slot groups with a metadata byte per slot | the LOOKUP strategy (set 1) and the Unicode tables' Swiss set |
| `ordered.zig` | a dense entry array with a side index | the APPEND strategy (set 2) |

The strategy-to-tier mapping is in `docs/hash-strategies.md`.

A table is built on a *tier set*, a ladder of rungs with the entry count at
which each takes over. The string table (`str.zig`) builds on `standard`:
Small from 0 entries, Robin Hood from `small_threshold` entries, where
`small_threshold` is 64 (`str.zig`; chosen from a histogram of final table
sizes over the rakudo build and spectest, in which 99.7 percent of non-empty
tables hold at most 64 entries). The insert that takes a table past 64
migrates it into a Robin Hood block in one step. `large_only` (Robin Hood
from 0) is defined for a future pre-allocate-big hint and is not used yet.
The pointer, fixkey and index tables each use a single unsalted
Robin Hood rung (`only_rung` in `ptr.zig`, `fixkey.zig`, `index.zig`). The
Unicode table has two sets: `only_rung` (unsalted Robin Hood, the default)
and `swiss_rung` (Swiss groups, with the cached 32-bit hash widened to 64
bits), selected with `MVM_uni_hash_build_strategy` (strategy 0 or 1; 2 is
refused). Every internal Unicode site stays on the default; the table of
assignments is in `docs/hash-strategies.md`, "Internal tables".

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
Zig time over C time, both engines built the same way: with LTO (the
default) and with `-Dlto=false`, from the same interleaved rounds after
LTO became the default (the per-cell tables are in
`traces/llm/bench/tuning-lto-default-nqp.md`):

| Operation | Small, LTO | Small, no LTO | Robin Hood, LTO | Robin Hood, no LTO |
|---|---|---|---|---|
| insert | 0.36-0.44 | 0.39-0.46 | 0.75-1.03 | 0.77-1.05 |
| lookup hit | 0.75-0.92 | 0.84-1.07 | 0.95-1.03 | 0.99-1.08 |
| lookup miss | 0.74-0.93 | 0.78-1.13 | 0.96-0.98 | 1.02-1.03 |
| delete | 0.74-0.95 | 0.75-1.05 | 0.95-0.97 | 0.97-0.99 |
| iterate | 0.56-0.65 | 0.64-0.72 | 1.02-1.04 | 1.03-1.07 |
| N-th insert | 0.24-0.62 | 0.26-0.70 | 1.06-1.16 | 1.00-1.10 |

Small is 16-64 entries, Robin Hood 65-16384 (N-th insert 128-16384; the
Robin Hood N-th insert ranges sit inside the C's own spread). Without LTO
five cells miss the 5 percent line in that run: the Small lookup miss at
63 and 64 entries (1.10 and 1.13), insert at 1024 (1.05) and the N-th
insert at 128 and 256 (1.10 and 1.09); with LTO every cell passes. Re-measured on the final bake-off branch (`traces/llm/bench/bakeoff-final-nqp.md`), the figures hold except that the N-th insert at 128 and 256 entries reads 1.07-1.12 with spreads no longer overlapping the C engine's (a tighter C side; unchanged against the branch base). Against a C engine built without LTO the default Zig
build reads lower still (Robin Hood lookups and delete 0.90-0.97, iterate
0.95-0.98).

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

At the Raku level (a `Hash` on a rakudo built on each engine, eleven
invocations each, both engines the default LTO build) the operations run
in 0.73-1.04 of the C engine's time, except the 65th insert, which costs
2.84 times the C engine's ordinary insert there (4.29 before the tuning),
and four insert and lookup cells (insert at 63, 256 and 65536 entries,
lookup hit at 65) that read 1.18-1.52 because they are bimodal between
invocations on both engines: a spesh timing race in the benchmark loop,
which blocking spesh removes (the Zig engine then reads about 0.72 at 63)
and which builds without LTO did not hit in six reps. The rakudo spectest
passes on both engines with no new failure; in six interleaved runs on the
default builds the Zig engine's wall time is 0.99 of the C's and its peak
RSS 0.98 (the campaign's own sequential runs had read 0.89 with session
drift and RSS 3 percent above). Against the build a `--cc=zig` user gets
without LTO (C engine, `-Dlto=false`), the default Zig build's spectest
wall time is 0.975 and its peak RSS 0.973, six interleaved runs, the two
ranges disjoint (medians 4:55 against 5:03).

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

### Strategies

`MVMHashStrategy` (`str_hash_table.h`) names the string table's layout
strategies: `MVM_HASH_STRATEGY_DEFAULT` (0, the Small then Robin Hood
ladder above), `MVM_HASH_STRATEGY_LOOKUP` (1, `tiers/swiss.zig`) and
`MVM_HASH_STRATEGY_APPEND` (2, `tiers/ordered.zig`), selected with
`MVM_str_hash_build_strategy`, `nqp::hashstrategy(%h, $strategy, $size)`
or, process-wide as a diagnostic, the `MVM_HASH_STRATEGY` environment
variable. docs/hash-strategies.md describes each one, what it won and gave
up in the hash layout bake-off, and how to select it. The `hashstrategy`
op sits before the spesh ops in `src/core/oplist`, so only spesh op
numbers moved when it was added. Its tests, `tools/bench/t/strategy.nqp`
(TAP), need an nqp built with the mapping (nqp branch
`zig-hash-strategies`): `zig build strategy-test -Dnqp-prefix=<P>` runs
them on `<P>/bin/nqp-m` with `LD_LIBRARY_PATH=<P>/lib`, and `zig build
test` runs them too when `-Dnqp-prefix` is given.

### Statistics

The `stats_test.zig` tests skip unless `-Dhash-stats` is given, so run `zig build unit-test` and `zig build test` both with and without it.

`-Dhash-stats=true` compiles the hash engine's counting hooks in
(`core/hash/stats.zig`); in a normal build they are comptime no-ops. It is a
diagnostic build for finding out how the engine's own tables are used, it
exists only in the zig build, and it adds `-g` to the C objects and forces
`-Dstrip=false` so the sites in the dump can be resolved against the debug
info. The flag reaches `stats.zig` through the `zig_options` module that
every root reaching it is given (the engine object, the unit-test roots
and the bench).

Set `MVM_HASH_STATS=<dir>` and the process writes `<dir>/<pid>.tsv` at
exit (an `atexit` handler; the directory is created if missing, a failure
prints one line to stderr). Counters are kept per thread and merged at the
dump, so the hot path has no atomics; cycles are `rdtsc` on x86_64. A site
is a call site of an exported table constructor, interned by return
address (at most 255, then `other`). What is counted, per site: operations
(build, insert, overwrite, fetch hit and miss, delete hit and miss,
iterator start and step, copy, grow, migrate, demolish) with their cycles,
fetches binned by the table's entry count at the fetch (hit and miss apart),
the size requested at build and the maximum item count at demolish (the latter
by set and rung), both bucketed as `<=4, 16, 32, 64, 65, 128, 256, 1024,
16384` and more. Probe lengths are not measured: `stats.probe` and the
`probe` row of the dump format exist, but no engine hook calls them, so a
dump carries no `probe` rows and cycles per fetch stand in for probe depth.

The file is TSV; header lines start with `#`: `cmdline`, `pid`, `tsc_hz`
(calibrated from the first counted use to the dump), `total_cycles` and
`libmoar` (the path from `dladdr`). Rows: `site<TAB>id<TAB>offset_hex`
(offset from libmoar's load base), `op<TAB>site<TAB>op<TAB>count<TAB>cycles`,
`probe<TAB>site<TAB>hit|miss<TAB>count<TAB>sum_len<TAB>max_len` (defined, never written),
`build<TAB>site<TAB>bucket<TAB>count` and
`demolish<TAB>site<TAB>set<TAB>rung<TAB>bucket<TAB>count`, where a bucket is
an index into the ladder above (9 is "more").
`fetch<TAB>site<TAB>hit|miss<TAB>bucket<TAB>count<TAB>cycles` bins the fetches by the
table's entry count at the fetch (their sum is the `fetch_hit`/`fetch_miss` op row; zero rows are omitted).

`tools/bench/hash-stats.pl DIR --lib=PATH/libmoar.so [--census] [--tsv=OUT.tsv]`
merges every `*.tsv` in `DIR` into a markdown report. It resolves each site
offset (minus one, the call instruction) with `addr2line` (retried with
`llvm-addr2line`, which reads this build's DWARF where GNU addr2line does
not), maps it to the census label (s1 ... p2 of the bake-off census) through
a built-in survey table keyed by file, function and, for the sites inside
`MVM_vm_create_instance`, line, and prints per site the op counts, cycles,
cycles per op, share of hash cycles and of `total_cycles`, and the build and
demolish histograms, then `## Hash share` per program. Unmapped sites print
as `function@file:line`, site 255 as `other`; `grow` and `migrate` cycles
are inside `insert`'s and stay out of the shares. Files of processes that
built no table are counted apart. The table is meant for this branch and
needs updating when the C sources move.

## Garbage collector

Every C file of `src/gc/` has a Zig port under `src/zig/gc/`, one `[zig]`
line each, behind the same C symbols. The ports are faithful: the same
nursery and promotion rule, gen2 size classes and page layout, root sets
and their walk order, write barrier, stop-the-world orchestration with work
stealing, finalization and object ids, and the same atomic operations at the
same sites (`traces/llm/specs/2026-11-04-zig-gc-port-design.md`; the
evidence is in the plan's "Acceptance",
`traces/llm/plans/2026-11-04-zig-gc-port.md`). With `-Dzig-impl=false` the
C collector is compiled instead.

| C file | Zig file | What it holds |
|---|---|---|
| `worklist.c` | `worklist.zig` | the mark worklist: create, the slow-path grow, presize, destroy |
| `allocation.c` | `allocation.zig` | nursery bump allocation and the object, type object, STable and frame allocators |
| `gen2.c` | `gen2.zig` | the gen2 size-class allocator: bins, pages, free lists, overflows, transfer between threads |
| `roots.c` | `roots.zig` | permanent, instance, thread, temporary, gen2 and frame roots, and their heap snapshot variant |
| `collect.c` | `collect.zig` | the copying collector, the work passing between threads, freeing of the nursery, gen2 and STables |
| `wb.c` | `wb.zig` | the write barrier's slow path |
| `objectid.c` | `objectid.zig` | object ids |
| `finalize.c` | `finalize.zig` | finalizer queues and the finalize handler |
| `debug.c` | `debug.zig` | the region finder and the per-collection log writer; always built, but its exports exist only at `-Dgc-debug` 1 and up (a `comptime` gate, like the C `#if`) |
| `orchestrate.c` | `orchestrate.zig` | the stop-the-world protocol, coordinator election, work stealing, the full-collection decision, global destruction |

The inline fast paths in the headers (`MVM_gc_allocate`, the
`MVM_gc_worklist_add` macros, `MVM_gc_write_barrier` and `MVM_ASSIGN_REF`,
the temp-root push and pop) stay C inlines; the Zig ports call the slow
paths they call. Shared helpers: `src/zig/moar.zig` has `assignRef` (the
`MVM_ASSIGN_REF` macro with its `MVM_GC_DEBUG` checks, through
`assertNotFromspace`), `worklistAdd` (the `MVM_gc_worklist_add` statement
macro, which translate-c cannot express, with its debug checks) and
`trycas`; `src/zig/gc/atomic.zig` has `load`, `store`, `add`, `incr`,
`decr`, `cas` and `fence`, all sequentially consistent like the C11
operations behind `MVM_load` and friends (translate-c cannot use those),
each call site commented with the C macro and line it replaces. `add`,
`incr` and `decr` take only `usize`-wide slots, as the C's `AO_t`. Unit
tests: `src/zig/gc/test/`, run by `zig build unit-test` in the
libmoar-linked `gc-test` binary (they boot a VM), plus `atomic_test.zig`
on the host. Some tests apply only at one debug level and skip at the other,
so run `zig build unit-test` with and without `-Dgc-debug=1`.

Two build options feed the C `#define`s, which carry `#ifndef` guards for
this, and reach the Zig side through translate-c (`c.MVM_GC_DEBUG`,
`c.MVM_NURSERY_SIZE`), so the two sides cannot disagree:

| Option | Default | Meaning |
|---|---|---|
| `-Dgc-debug=` | `0` | `MVM_GC_DEBUG` (`src/gc/debug.h`). 0: no checks, and the release code path. 1: checks on reference assignments and worklist adds (`MVM_ASSERT_NOT_FROMSPACE`, the gen2 free-list check, `MVM_CHECK_CALLER_CHAIN`), plus the per-collection log and the RSS pin below. 2: also checks on every object register access (slow). 3: also a collection on every nursery allocation, and each collected thread's from-space filled with `0xef` once its uncopied objects are freed. In Zig each level is a `comptime` block, so nothing of it is compiled at 0. A debug level changes `MVMThreadContext`'s layout (`in_spesh` and the log counters exist only under it), so compare only builds of the same level |
| `-Dnursery-size=` | `16777216` | `MVM_NURSERY_SIZE`, the maximum nursery in bytes; small values stress the collector (the stress builds use 524288) |

### Per-collection log

At `-Dgc-debug=1` and up, `MVM_GC_LOG=<file>` opens `<file>` for append at
instance creation and the collector writes one line per thread per
collection, flushed:

    seq=N tid=N full=0|1 coord=0|1 from=N next=N promoted=N since_full=N gen2_freed=N stables_freed=N finalizing=N

`seq` is the instance's GC sequence number, `tid` the thread the line is
for, `full` whether the run collected gen2 too, `coord=1` marks the thread
that started the run (`thread_to_blame_for_gc`), `from` and `next` the
nursery sizes of this run and the next, `promoted` the bytes that thread
promoted to gen2 in the run, `since_full` the instance's promoted bytes
since the last full run, `gen2_freed` the gen2 bytes freed (the bin slot
size for a binned object, the object's size for an oversized one),
`stables_freed` the STables freed and `finalizing` the length of the
finalization queue. The coordinator writes the lines of every thread it
collected for; a thread destroyed during a run is logged just before it is
destroyed. `stables_freed` lands on the coordinator's line of the run that
frees them. Nothing is logged at global destruction, which frees outside any
run. The two counters are reset after each line.

`MVM_GC_DEBUG_RSS=<bytes>` pins the resident-set size that the
full-collection decision reads (`is_full_collection`) to that value, so the
decision depends only on the promoted bytes and is the same from run to run.
Both variables exist only at `-Dgc-debug=1` and up.

### Fidelity oracle, stress and A/B

The machinery is in `tools/bench/gc/` (its `README.md`; every script takes
`--help`). Variants are libmoar builds in their own prefixes, run through
`LD_LIBRARY_PATH=<prefix>/lib` with one installed nqp and rakudo.

- Oracle: build both collectors at `-Dgc-debug=1` (the campaign's C side is
  commit 139d404ed, the C collector with the Zig hash engine), then
  `tools/bench/gc/oracle.sh --base=<C prefix> --head=<Zig prefix> --volume=100000 [--bad-packages] [--tier=1|2] --out=<dir>`.
  It runs `crc-sequential.raku` three times per side with
  `MVM_SPESH_DISABLE=1 RAKUDO_NO_PRECOMPILATION=1` and the log on, checks
  the format, that each side is repeatable, and then that base and head are
  identical. Tier 1 leaves the RSS read real and drops the `full=` and
  `gen2_freed=` fields before comparing; tier 2 pins it at 100 MiB and
  compares every field. It compares every thread's lines, in order; this
  workload has only `tid=1`. The rakudo it runs defaults to the in-tree
  `rakudo-m`; `--rakudo=` or `$RAKUDO` overrides it. Exit codes: 0 the logs
  are identical, 1 base and head differ, 2 a side is not repeatable, 3 a log
  is malformed or empty, 4 a run failed or the prefix paths differ in
  length, 64 usage. `prove tools/bench/t/gc-oracle.t` tests the script and
  reports the file as skipped when `/tmp/claude-1000/gc-c-oracle` is
  missing, so run it with that prefix present when the result matters.
- Stress: both collectors at `-Dgc-debug=1 -Dnursery-size=524288`; nqp's
  and rakudo's `make test` and `crc-getter.raku --volume=100000` under each
  must give the same results.
- A/B: default builds,
  `tools/bench/gc/ab.sh --base=<prefix>/lib --head=<prefix>/lib --rounds=7 --runs=5 --volume=100000 [--bad-packages] --out=<dir>`
  on the user's `crc-getter.raku`, interleaved, with `summary.md` holding
  the round medians and the head/base ratios for wall and peak RSS; the
  rakudo spectest A/B is the main performance gate.

The two prefixes of a pair must have paths of the same length, and both
scripts refuse a pair that does not (exit 4): the install prefix is baked
into libmoar's config strings, so its length changes the size of objects
allocated at startup and shifts every later collection (a longer head
prefix showed 56 more promoted bytes at `seq=2`). The campaign used
`/tmp/claude-1000/gc-c-oracle` and `/tmp/claude-1000/gc-z-oracle`, and the
same pattern for `-stress` and `-base`.

Recipes the campaign used, for a maintainer repeating the comparison:

- Prefixes: check out the C side (139d404ed, or whatever commit the
  comparison is against) and `zig build install --prefix <P> [-Dgc-debug=1]
  [-Dnursery-size=524288]`, then the same from the Zig side with a prefix
  of equal length. Each prefix needs an nqp and rakudo installed against it
  (`perl Configure.pl --prefix=<P>` in nqp and rakudo, then `make install`),
  or one pair built against a path of that length and reached through
  `LD_LIBRARY_PATH`, which is what the scripts do. NativeCall tests need
  `RAKULIB` to include rakudo's `lib`.
- Spectest A/B: in rakudo, with `LD_LIBRARY_PATH=<P>/lib`, remove `.precomp`
  and run `TEST_JOBS=24 python3 <MoarVM>/tools/bench/timev.py <out>.time make -o
  spectest_update spectest`, alternating prefixes, three runs each, medians
  compared; the rule is wall within base's spread or within 1 percent, RSS
  within spread, and no new failures. Do not shim the harness.
- The machine has no swap: cap anything that may grow with
  `systemd-run --user --scope -q -p MemoryMax=24G <cmd>` or `ulimit -v`.
- A consumer compiled against the installed headers must use the same
  `MVM_GC_DEBUG` value as the libmoar it loads, since the debug level
  changes `MVMThreadContext` and `MVMInstance`.
- `zig build test -Dzig-impl=false` is the all-C control; it must stay green.

### Zig 0.16 notes from the port

- There is no `@fence`. `atomic.fence()` emits what C compilers emit for
  `atomic_thread_fence(memory_order_seq_cst)`: `mfence` on x86 (`dmb ish`
  on ARM64, `fence rw,rw` on RISC-V) with a memory clobber, and a seq_cst
  read-modify-write of a private word on other targets.
- An array field reached through a translated `[*c]` pointer must not be
  indexed as `p.*.arr[i]`: through a `[*c]S`, that indexes whole arrays
  (elements of type `[N]T`) past the field, and it compiles silently when the
  element is a scalar or a pointer. Write `p[0].arr[i]`, or go through a
  `*S` pointer. A pointer field (`tc.*.gc_work[i]`) is not affected.
- `MVMDebugServerData` has bit-fields, which translate-c leaves opaque;
  `orchestrate.zig` mirrors it as an `extern struct`, and the layout probe
  test checks its size and the offsets of the fields the port touches
  against the C compiler at both debug levels.

## Not yet supported

Any OS other than linux, any CPU other than x86_64, system libuv/libtommath/libffi, MSVC, coverage
and sanitizer builds, `--relocatable`.
