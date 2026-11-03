#!/bin/sh
# A/B runner for the hash ladders: two or more builds (variants) of libmoar
# measured in interleaved rounds on one machine, then compared.
#
# Each variant is NAME:LIBDIR[:BENCH_EXE]. Per round, for each variant (the
# order rotated each round, so none always runs first or last):
#   * the nqp ladder: LD_LIBRARY_PATH=LIBDIR <nqp> tools/bench/hash-bench.nqp
#     --engine=NAME --sizes=S --runs=K --nth=N
#   * the C-API ladder, when BENCH_EXE is given (the `zig build
#     hash-bench-exe` executable): LD_LIBRARY_PATH=LIBDIR BENCH_EXE
#     --sizes=S --runs=K --nth=N
# <nqp> is --nqp= (default /tmp/claude-1000/tune-zig-prefix/bin/nqp-m); it
# runs against each variant's libmoar through LD_LIBRARY_PATH, so it must
# be an nqp whose moar is the one that LIBDIR replaces.
#
# Raw rows go to <out>/nqp.raw and <out>/capi.raw as
#     variant<TAB>round<TAB><the harness's 7 columns>
# (engine, size, op, ns, rss, ns_min, ns_max). The 1-minute load average
# before each run goes to stderr and <out>/load.log. At the end each raw
# file is split per variant into <out>/<level>-<variant>.tsv (the 7
# columns) and, for the first variant against each other one,
#     perl tools/bench/hash-compare.pl <out>/<level>-<first>.tsv \
#          <out>/<level>-<other>.tsv > <out>/<level>-compare.md
# (with three or more variants the compare file takes all the others).
# <out> must not exist yet.
#
# --ladder=NAME (default hash) picks the harness: a round runs
# tools/bench/NAME-bench.nqp and, for a variant that names an exe, that exe
# (`zig build uni-bench-exe` leaves <prefix>/bin/uni-bench for --ladder=uni).
# Only the hash ladder is given --sizes and --nth; every ladder gets
# --engine and --runs. The raw and compare files keep their names.
#
# Usage: tools/bench/hash-ab.sh --out=DIR --variant=NAME:LIBDIR[:BENCH_EXE]
#            --variant=... [--ladder=NAME (default hash)] [--rounds=R] [--sizes=S] [--runs=K (default 5)]
#            [--nth=all|threshold (default all)] [--nqp=PATH]
#            [--max-load=L (default 2.0)]
#        tools/bench/hash-ab.sh --help
# Before each run the script waits until the 1-minute load average is below
# --max-load.
# Defaults: --rounds=5; --sizes= the ladder 4,16,32,63,64,65,128,256,1024,16384.
set -e

root=$(cd "$(dirname "$0")/../.." && pwd)

out=
rounds=5
sizes=4,16,32,63,64,65,128,256,1024,16384
runs=5
nth=all
nqp=/tmp/claude-1000/tune-zig-prefix/bin/nqp-m
max_load=2.0
ladder=hash
variants=
for a in "$@"; do
    case $a in
        --out=*)     out=${a#--out=} ;;
        --rounds=*)  rounds=${a#--rounds=} ;;
        --sizes=*)   sizes=${a#--sizes=} ;;
        --runs=*)    runs=${a#--runs=} ;;
        --nth=all|--nth=threshold) nth=${a#--nth=} ;;
        --nqp=*)     nqp=${a#--nqp=} ;;
        --ladder=*)  ladder=${a#--ladder=} ;;
        --max-load=*) max_load=${a#--max-load=} ;;
        --variant=*) variants="$variants ${a#--variant=}" ;;
        --help|-h)   sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "hash-ab.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
if [ -z "$out" ]; then
    echo "hash-ab.sh: --out is required" >&2
    exit 2
fi
# shellcheck disable=SC2086
set -- $variants
k=$#
if [ "$k" -lt 2 ]; then
    echo "hash-ab.sh: at least two --variant=NAME:LIBDIR[:BENCH_EXE] are required" >&2
    exit 2
fi
if [ -e "$out" ]; then
    echo "hash-ab.sh: $out exists; pick a fresh --out" >&2
    exit 2
fi
if [ ! -x "$nqp" ]; then
    echo "hash-ab.sh: $nqp is not executable" >&2
    exit 2
fi

if [ ! -f "$root/tools/bench/$ladder-bench.nqp" ]; then
    echo "hash-ab.sh: no tools/bench/$ladder-bench.nqp for --ladder=$ladder" >&2
    exit 2
fi
ladder_args="--runs=$runs"
if [ "$ladder" = hash ]; then ladder_args="--sizes=$sizes --runs=$runs --nth=$nth"; fi

# Check every variant and keep its names and paths in numbered shell vars.
i=1
for v in "$@"; do
    name=${v%%:*}
    rest=${v#*:}
    if [ "$rest" = "$v" ]; then
        echo "hash-ab.sh: variant $v has no :LIBDIR" >&2
        exit 2
    fi
    lib=${rest%%:*}
    exe=
    if [ "$rest" != "$lib" ]; then exe=${rest#*:}; fi
    if [ ! -d "$lib" ]; then
        echo "hash-ab.sh: $lib (variant $name) is not a directory" >&2
        exit 2
    fi
    if [ -n "$exe" ] && [ ! -x "$exe" ]; then
        echo "hash-ab.sh: $exe (variant $name) is not executable" >&2
        exit 2
    fi
    eval "v_name_$i=\$name; v_lib_$i=\$lib; v_exe_$i=\$exe"
    i=$((i + 1))
done

mkdir -p "$out"
: > "$out/nqp.raw"
: > "$out/capi.raw"

load() {
    cut -d' ' -f1 /proc/loadavg 2>/dev/null || uptime | sed 's/.*load average: *//; s/,.*//'
}

wait_load() {
    until awk -v m="$max_load" '{ exit !($1 < m) }' /proc/loadavg; do sleep 10; done
}

cd "$root"
round=1
while [ "$round" -le "$rounds" ]; do
    j=0
    while [ "$j" -lt "$k" ]; do
        idx=$(( (round - 1 + j) % k + 1 ))
        eval "name=\$v_name_$idx; lib=\$v_lib_$idx; exe=\$v_exe_$idx"
        wait_load
        echo "round $round $name nqp load $(load)" | tee -a "$out/load.log" >&2
        LD_LIBRARY_PATH=$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
            "$nqp" "tools/bench/$ladder-bench.nqp" --engine="$name" \
            $ladder_args > "$out/run.tsv"
        awk -F '\t' -v OFS='\t' -v v="$name" -v r="$round" 'NF >= 7 { print v, r, $0 }' "$out/run.tsv" >> "$out/nqp.raw"
        if [ -n "$exe" ]; then
            wait_load
            echo "round $round $name capi load $(load)" | tee -a "$out/load.log" >&2
            LD_LIBRARY_PATH=$lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} \
                "$exe" $ladder_args > "$out/run.tsv"
            awk -F '\t' -v OFS='\t' -v v="$name" -v r="$round" 'NF >= 7 { print v, r, $0 }' "$out/run.tsv" >> "$out/capi.raw"
        fi
        rm -f "$out/run.tsv"
        j=$((j + 1))
    done
    round=$((round + 1))
done
echo "end load $(load)" >> "$out/load.log"

for level in nqp capi; do
    [ -s "$out/$level.raw" ] || continue
    files=
    for idx in $(seq 1 "$k"); do
        eval "name=\$v_name_$idx"
        awk -F '\t' -v OFS='\t' -v v="$name" '$1 == v { $1 = ""; $2 = ""; sub(/^\t\t/, ""); print }' "$out/$level.raw" > "$out/$level-$name.tsv"
        [ -s "$out/$level-$name.tsv" ] && files="$files $out/$level-$name.tsv"
    done
    # shellcheck disable=SC2086
    perl "$root/tools/bench/hash-compare.pl" $files > "$out/$level-compare.md"
done
echo "hash-ab.sh: wrote $out" >&2
