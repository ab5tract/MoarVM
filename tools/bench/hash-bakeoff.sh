#!/bin/sh
# The hash layout bake-off: tools/bench/hash-bench.nqp once per strategy per
# round on one installed stack, then the scoreboard
# (tools/bench/hash-bakeoff.pl).
#
# Every strategy runs in the same process image: the harness selects the
# layout per hash with nqp::hashstrategy (--strategy=N), so <prefix> needs
# an nqp that maps the op (nqp branch zig-hash-strategies) on a moar that
# has the strategies built in. Strategy 3 runs with --seal (its insert and
# insert_nth rows are therefore n/a on the scoreboard).
#
# Per round r (numbered from 1) the strategy order is rotated: the round
# starts at strategy index (r-1) mod k of the k strategies, so no strategy
# always runs first or last. Each run's rows go to <out>/raw.tsv as
#     round<TAB>strategy<TAB>size<TAB>op<TAB>ns<TAB>rss<TAB>ns_min<TAB>ns_max
# (ns is the median of that run's --runs, ns_min-ns_max their spread); the
# 1-minute load average before each run goes to stderr and <out>/load.log.
# At the end <out>/scoreboard.md is written from raw.tsv, with the first of
# --strategies as the base. <out>/raw.tsv must not exist yet (a long run is
# never overwritten).
#
# Usage: tools/bench/hash-bakeoff.sh --prefix=<P> --out=<dir>
#            [--strategies=0,1,2,3] [--rounds=7]
#            [--sizes=N,N,...] [--runs=K] [--nth=all|threshold]
#            [--hint=0|size]
#        tools/bench/hash-bakeoff.sh --help
# Defaults: --sizes= the ladder 4,16,32,63,64,65,128,256,1024,16384 plus the
# resize cells 49,97; --runs=5; --nth=all; --hint=0.
# --hint= goes to the harness: 0 (the default) builds every hash with size
# hint 0, so it grows through its tiers as it fills and insert, insert_nth
# and the resize cells time that growth; size passes N as the hint, so every
# hash is built presized and no timed row grows a table.
set -e

root=$(cd "$(dirname "$0")/../.." && pwd)

prefix=
out=
strategies=0,1,2,3
rounds=7
sizes=4,16,32,63,64,65,128,256,1024,16384,49,97
runs=5
nth=all
hint=0
for a in "$@"; do
    case $a in
        --prefix=*)     prefix=${a#--prefix=} ;;
        --out=*)        out=${a#--out=} ;;
        --strategies=*) strategies=${a#--strategies=} ;;
        --rounds=*)     rounds=${a#--rounds=} ;;
        --sizes=*)      sizes=${a#--sizes=} ;;
        --runs=*)       runs=${a#--runs=} ;;
        --nth=*)        nth=${a#--nth=} ;;
        --hint=0|--hint=size) hint=${a#--hint=} ;;
        --help|-h)      sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "hash-bakeoff.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
if [ -z "$prefix" ] || [ -z "$out" ]; then
    echo "hash-bakeoff.sh: --prefix and --out are required" >&2
    exit 2
fi
nqp=$prefix/bin/nqp-m
if [ ! -x "$nqp" ]; then
    echo "hash-bakeoff.sh: $nqp is not executable" >&2
    exit 2
fi
mkdir -p "$out"
raw=$out/raw.tsv
if [ -e "$raw" ]; then
    echo "hash-bakeoff.sh: $raw exists; pick a fresh --out" >&2
    exit 2
fi
: > "$raw"

# The strategies as positional parameters, k of them.
old_ifs=$IFS
IFS=,
# shellcheck disable=SC2086
set -- $strategies
IFS=$old_ifs
k=$#

round=1
while [ "$round" -le "$rounds" ]; do
    i=0
    while [ "$i" -lt "$k" ]; do
        idx=$(( (round - 1 + i) % k + 1 ))
        eval "strategy=\${$idx}"
        seal=
        [ "$strategy" = 3 ] && seal=--seal
        load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || uptime | sed 's/.*load average: *//; s/,.*//')
        echo "round $round strategy $strategy load $load" | tee -a "$out/load.log" >&2
        start=$(date +%s)
        # shellcheck disable=SC2086
        LD_LIBRARY_PATH=$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
            "$nqp" "$root/tools/bench/hash-bench.nqp" --strategy="$strategy" $seal \
            --sizes="$sizes" --runs="$runs" --nth="$nth" --hint="$hint" > "$out/run.tsv"
        awk -F '\t' -v OFS='\t' -v r="$round" -v s="$strategy" \
            'NF >= 7 { print r, s, $2, $3, $4, $5, $6, $7 }' "$out/run.tsv" >> "$raw"
        rm -f "$out/run.tsv"
        echo "hash-bakeoff.sh: $(( $(date +%s) - start ))s" >&2
        i=$(( i + 1 ))
    done
    round=$(( round + 1 ))
done

base=${strategies%%,*}
perl "$root/tools/bench/hash-bakeoff.pl" "$raw" --base="$base" > "$out/scoreboard.md"
echo "hash-bakeoff.sh: wrote $raw and $out/scoreboard.md" >&2
