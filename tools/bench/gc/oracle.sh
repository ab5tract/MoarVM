#!/bin/sh
# GC fidelity oracle (spec traces/llm/specs/2026-11-04-zig-gc-port-design.md,
# section 5): the per-collection log of a -Dgc-debug build (MVM_GC_LOG),
# compared line by line between two prefixes on a single-threaded workload.
#
# For each side (base, then head) the script runs
#     tools/bench/gc/crc-sequential.raku --volume=N --runs=K [--bad-packages]
# three times with
#     LD_LIBRARY_PATH=<prefix>/lib MVM_SPESH_DISABLE=1 RAKUDO_NO_PRECOMPILATION=1
#     MVM_GC_LOG=<out>/<side>-<i>.log RAKULIB=<rakulib>
# and, for --tier=2, MVM_GC_DEBUG_RSS=104857600 (the resident-set read of the
# full-collection decision pinned at 100 MiB). Program output goes to
# <out>/<side>-<i>.out. RAKUDO_NO_PRECOMPILATION=1 because loading a
# precompiled module varies the startup allocation by 168 bytes from run to
# run, compiling it from source does not (traces/llm/bench/
# gc-oracle-repeatability.md). Then:
#   * format guard: every log line must match
#       ^seq=N tid=N full=[01] coord=[01] from=N next=N promoted=N since_full=N
#        gen2_freed=N stables_freed=N finalizing=N$
#     and no log may be empty, else exit 3 naming the file and line;
#   * repeatability: the three logs of each side must be identical (after the
#     tier filter below), else exit 2 "not repeatable" with the first
#     differing line;
#   * fidelity: base-1 against head-1 (after the tier filter); exit 0 when
#     identical, exit 1 with the first differing line otherwise.
# Tier filter: tier 1 (no RSS pin; the full-collection decision follows the
# real RSS) deletes the full= and gen2_freed= fields before comparing; tier 2
# compares every field. The filtered logs are left in <out>/<side>-<i>.cmp.
#
# Reading the log (from the Task 1 review of 96d049123): one line per thread
# per collection; coord=1 marks the thread that started the run; a thread
# destroyed mid-run is logged just before its destruction; stables_freed
# appears on the coordinator's line of the run that frees them; nothing is
# logged for the frees at global destruction.
#
# Usage: tools/bench/gc/oracle.sh --base=PREFIX --head=PREFIX --volume=N
#            [--bad-packages] [--tier=1|2 (default 1)] [--runs=K (default 5)]
#            [--rakudo=PATH] [--rakulib=LIST] --out=DIR
#        tools/bench/gc/oracle.sh --compare-only [--tier=1|2] --out=DIR
#        tools/bench/gc/oracle.sh --help
# PREFIX is a -Dgc-debug=1 (or higher) install (<prefix>/lib/libmoar.so).
# --rakudo defaults to $RAKUDO, else the in-tree
# /home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m (it loads libmoar
# from LD_LIBRARY_PATH first). --rakulib defaults to tools/bench/gc/lib plus
# the lib/ directory beside --rakudo (the in-tree rakudo has no core modules
# installed, so `use NativeCall` needs its source directory). DIR must not
# exist, except with --compare-only, which runs nothing and compares the
# <side>-<i>.log files already in DIR.
# The two PREFIX strings must be of equal length: the install path is baked
# into libmoar's config strings, and its length changes the allocation
# sequence, so an unequal pair is refused (exit 4) before anything runs.
# Exit: 0 identical, 1 base and head differ, 2 a side not repeatable,
# 3 malformed or empty log, 4 a run failed or the prefixes differ in length,
# 64 misuse.
set -e

root=$(cd "$(dirname "$0")/../../.." && pwd)

base= head= volume= bad= tier=1 runs=5 out= compare_only=
rakudo=${RAKUDO:-/home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m}
rakulib=
for a in "$@"; do
    case $a in
        --base=*)        base=${a#--base=} ;;
        --head=*)        head=${a#--head=} ;;
        --volume=*)      volume=${a#--volume=} ;;
        --bad-packages)  bad=--bad-packages ;;
        --tier=1|--tier=2) tier=${a#--tier=} ;;
        --runs=*)        runs=${a#--runs=} ;;
        --rakudo=*)      rakudo=${a#--rakudo=} ;;
        --rakulib=*)     rakulib=${a#--rakulib=} ;;
        --out=*)         out=${a#--out=} ;;
        --compare-only)  compare_only=1 ;;
        --help|-h)       sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "oracle.sh: unknown argument $a (see --help)" >&2; exit 64 ;;
    esac
done
usage() { echo "oracle.sh: $1 (see --help)" >&2; exit 64; }
[ -n "$out" ] || usage "--out is required"
case $out in /*) ;; *) out=$PWD/$out ;; esac
# Tier 1 must not inherit a pin from the caller's environment.
unset MVM_GC_DEBUG_RSS
if [ -n "$compare_only" ]; then
    [ -d "$out" ] || usage "$out is not a directory"
else
    [ -n "$base" ] && [ -n "$head" ] || usage "--base and --head are required"
    [ -n "$volume" ] || usage "--volume is required"
    case $volume in *[!0-9]*) usage "--volume must be a number" ;; esac
    case $runs in ''|*[!0-9]*) usage "--runs must be a number" ;; esac
    for p in "$base" "$head"; do
        [ -e "$p/lib/libmoar.so" ] || usage "$p/lib/libmoar.so missing"
    done
    if [ "${#base}" != "${#head}" ]; then
        echo "oracle.sh: --base and --head differ in length (base $base is ${#base} characters, head $head is ${#head}); the install path changes the allocation sequence, use prefixes of equal length" >&2
        exit 4
    fi
    [ -x "$rakudo" ] || usage "$rakudo is not executable"
    [ -e "$out" ] && usage "$out exists; pick a fresh --out"
    [ -n "$rakulib" ] || rakulib="$root/tools/bench/gc/lib,$(dirname "$rakudo")/lib"
fi

# first_diff A B: the first line where files A and B differ, or nothing.
first_diff() {
    awk -v A="$1" -v B="$2" '
        FILENAME == A { a[FNR] = $0; n = FNR; next }
        !done {
            if (FNR > n || a[FNR] != $0) {
                printf "line %d:\n  %s: %s\n  %s: %s\n", FNR, A, (FNR > n ? "<end of file>" : a[FNR]), B, $0
                done = 1
            }
            m = FNR
        }
        END { if (!done && n > m) printf "line %d:\n  %s: %s\n  %s: <end of file>\n", m + 1, A, a[m + 1], B }
    ' "$1" "$2"
}

if [ -z "$compare_only" ]; then
    mkdir -p "$out"
    cd "$root"
    for side in base head; do
        if [ "$side" = base ]; then prefix=$base; else prefix=$head; fi
        for i in 1 2 3; do
            if [ "$tier" = 2 ]; then rss=104857600; else rss=; fi
            echo "oracle.sh: $side run $i (volume $volume${bad:+ $bad}, tier $tier, load $(cut -d' ' -f1 /proc/loadavg))" >&2
            if ! env LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" RAKULIB="$rakulib" \
                    MVM_SPESH_DISABLE=1 RAKUDO_NO_PRECOMPILATION=1 MVM_GC_LOG="$out/$side-$i.log" ${rss:+MVM_GC_DEBUG_RSS=$rss} \
                    "$rakudo" tools/bench/gc/crc-sequential.raku --volume="$volume" --runs="$runs" $bad \
                    > "$out/$side-$i.out" 2>&1; then
                echo "oracle.sh: $side run $i failed; see $out/$side-$i.out" >&2
                exit 4
            fi
        done
    done
fi

re='^seq=[0-9]+ tid=[0-9]+ full=[01] coord=[01] from=[0-9]+ next=[0-9]+ promoted=[0-9]+ since_full=[0-9]+ gen2_freed=[0-9]+ stables_freed=[0-9]+ finalizing=[0-9]+$'
for side in base head; do
    for i in 1 2 3; do
        log=$out/$side-$i.log
        if [ ! -s "$log" ]; then
            echo "oracle.sh: $log is missing or empty (is the prefix a -Dgc-debug build?)" >&2
            exit 3
        fi
        bad_line=$(grep -nEv "$re" "$log" | head -n 1 | sed "s/^\([0-9]*\):/\1: /") || true
        if [ -n "$bad_line" ]; then
            echo "oracle.sh: malformed log line at $log:$bad_line" >&2
            exit 3
        fi
        if [ "$tier" = 1 ]; then
            sed 's/ full=[01]//; s/ gen2_freed=[0-9]*//' "$log" > "$out/$side-$i.cmp"
        else
            cp "$log" "$out/$side-$i.cmp"
        fi
    done
    for i in 2 3; do
        if ! cmp -s "$out/$side-1.cmp" "$out/$side-$i.cmp"; then
            echo "oracle.sh: $side not repeatable (tier $tier): $side-1 against $side-$i, first difference at" >&2
            first_diff "$out/$side-1.cmp" "$out/$side-$i.cmp" >&2
            exit 2
        fi
    done
done

if ! cmp -s "$out/base-1.cmp" "$out/head-1.cmp"; then
    echo "oracle.sh: base and head differ (tier $tier), first difference at" >&2
    first_diff "$out/base-1.cmp" "$out/head-1.cmp" >&2
    exit 1
fi
echo "oracle.sh: identical (tier $tier, $(wc -l < "$out/base-1.log") lines)" >&2
exit 0
