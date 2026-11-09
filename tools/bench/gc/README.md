# tools/bench/gc: workloads and runners of the Zig GC port

Evidence machinery of the GC port campaign
(`traces/llm/specs/2026-11-04-zig-gc-port-design.md`, sections 5-7). Every
script prints its usage with `--help` and exits 64 on misuse.

| File | What it is |
|---|---|
| `crc-getter.raku` | The user's program, verbatim from gist `ab5tract/61e08cfaf0bb3e67b3a3dc009fa3cc7a`, file `crc-getter.raku` (raw: `https://gist.github.com/ab5tract/61e08cfaf0bb3e67b3a3dc009fa3cc7a/raw/crc-getter.raku`, fetched 2026-11-04). The proving ground of the performance gate (`ab.sh`). |
| `crc-sequential.raku` | Its sequential reduction for the oracle: the same `Package` class, `@packages` construction (`xx $volume`; `--bad-packages` gives the 90/10 split), per-batch `map` of crc32 checks and `$bad-count`, with the supplies, `react` and `start` removed. One further change: durations are taken as `now.Num - $time.Num`, because `now - $time` (a Duration) makes the GC log vary with the clock. `--volume=N --runs=K [--bad-packages]`, one `RUN $n: <duration>s` line per batch. |
| `oracle.sh` | The fidelity oracle: three logged runs (`MVM_GC_LOG`) of `crc-sequential.raku` per prefix, with `MVM_SPESH_DISABLE=1` and `RAKUDO_NO_PRECOMPILATION=1`, tier 2 adding the RSS pin `MVM_GC_DEBUG_RSS=104857600`; checks the log format, the repeatability of each side and then base against head. `--compare-only` re-compares logs already in a directory. Exit 0 identical, 1 differ, 2 not repeatable, 3 malformed log, 4 a run failed. Test: `prove tools/bench/t/gc-oracle.t`. |
| `ab.sh` | The A/B runner of the performance and memory gate: interleaved rounds (side order rotated per round), `tools/bench/timev.py` per run, load under 2.0 before each run, `summary.md` with round medians, their min-max, and the head/base ratios for wall and peak RSS. Runs `crc-getter.raku` by default (`--program=crc-sequential` for the reduction). |
| `cleanup/` | The three full-cleanup programs of the Campaign 4 interlude, verbatim from its PR text: `running.nqp` (a background thread allocating in a loop while the main thread returns), `blocked.nqp` (a background thread mostly blocked in `nqp::sleep`), `three.nqp` (two allocating threads and one sleeping one). Each ends with `say("main returning")`. |
| `cleanup.sh` | The full-cleanup runner: `--prefix=P --runs=N [--stress] [--nqp-lib=DIR]` runs each program N times as `timeout 60 <P>/bin/moar --full-cleanup` on the nqp of `/tmp/claude-1000/tune-zig-prefix` under `systemd-run` (MemoryMax=8G), prints a table of exit codes and whether the last line was `main returning`, and exits 0 only when every run passed (1 otherwise). `--stress` runs the variants with 20 times the allocation per iteration. |
| `lib/String/CRC32.rakumod` | Vendored pure-Raku `String::CRC32`, version 0.05, `auth<github:cosimo>` (the file is the distribution's `lib/String/CRC32.pm`, renamed, unchanged). |
| `lib/String/CRC32.pod` | The distribution's documentation, unchanged. The distribution ships no license file and its `META6.json` has an empty `license` field; this pod's AUTHOR and COPYRIGHT sections are the only authorship and copyright statement it carries, so it is kept beside the module in place of a license file. |

## Where the vendored module came from

`zef info String::CRC32` (2026-11-04) names `String::CRC32:ver<0.05>` from the
REA ecosystem with source URL

    https://raw.githubusercontent.com/raku/REA/main/archive/S/String%3A%3ACRC32/String%3A%3ACRC32%3Aver%3C0.05%3E%3Aauth%3Cgithub%3Acosimo%3E.tar.gz

(sha256 `a7530c3b51815a81ee9185fd0938325ef6d089a420386375ac1398ffa9bb0362`).
The tarball's top directory is `perl6-string-crc32-master/`; `META6.json`
gives version 0.05, author Cosimo Streppone, upstream
`git://github.com/cosimo/perl6-string-crc32.git`.

## Running the programs

The in-tree rakudo (`/home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m`)
loads libmoar from `LD_LIBRARY_PATH` first, so a variant is chosen by its
prefix's `lib`. It has no core modules installed, so `use NativeCall` needs
the rakudo checkout's `lib/` on `RAKULIB` next to this directory's `lib/`:

    LD_LIBRARY_PATH=<prefix>/lib \
    RAKULIB=tools/bench/gc/lib,/home/longwalker/code/raku/x.core/zmoarz/rakudo/lib \
    /home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m tools/bench/gc/crc-getter.raku --volume=10000

Both runners set this up themselves (`--rakudo=`, `--rakulib=` override it).
