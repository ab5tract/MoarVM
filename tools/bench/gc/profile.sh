#!/bin/sh
# Profile runner for the GC A/B (spec
# traces/llm/specs/2026-11-09-zig-native-gc-design.md, section 7): hardware
# counters and, optionally, cycle samples of one side (one libmoar build) on
# the user's crc-getter program. One side per invocation; the caller
# interleaves the sides.
#
# Each counted run is
#     LD_LIBRARY_PATH=<lib> RAKULIB=<rakulib> perf stat -x, -o <out>/stat-<n>.csv \
#         -e cycles:u,instructions:u,branch-misses:u,cache-misses:u,L1-dcache-load-misses:u \
#         <rakudo> tools/bench/gc/crc-getter.raku --volume=100000 --runs=5 [--bad-packages]
# (spesh and precompilation on, as ab.sh runs it; perf follows the whole
# process tree). One untimed warm-up run at --volume=1 --runs=1 comes first,
# so module precompilation is not counted. Before every run the script waits
# until the 1-minute load average is below 2.0 (30 minutes at most, then
# exit 1) and appends the load to <out>/load.log. Every event carries :u:
# perf_event_paranoid 2 permits user-space counters of one's own processes
# only. With --record, one more run under
#     perf record -e cycles:u -F 4000 -o <out>/perf.data
# follows the counted runs, then
#     perf report -i <out>/perf.data --sort dso,symbol --stdio -n > <out>/report.txt
# Writes <out>/stat-<n>.csv (perf stat's output), <out>/stat-<n>.out and
# <out>/record.out (the program's output), <out>/load.log and <out>/stat.tsv:
# per event the median, min and max over the counted runs, then each run's
# value. --stat-runs=0 with --record takes the sample run only.
#
# Usage: tools/bench/gc/profile.sh --lib=LIBDIR --out=DIR [--bad-packages]
#            [--stat-runs=N (default 5)] [--record]
#        tools/bench/gc/profile.sh --help
# LIBDIR holds the side's libmoar.so (<prefix>/lib); profile a build with
# symbols (-Dstrip=false). The rakudo is $RAKUDO, else
# /home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m, with RAKULIB
# tools/bench/gc/lib plus the lib/ beside it (as ab.sh). DIR must not exist.
# Exit: 0 done, 1 a run failed or the load never fell, 64 misuse.
set -e

root=$(cd "$(dirname "$0")/../../.." && pwd)

lib= out= bad= stat_runs=5 record= max_load=2.0
rakudo=${RAKUDO:-/home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m}
events=cycles:u,instructions:u,branch-misses:u,cache-misses:u,L1-dcache-load-misses:u
for a in "$@"; do
    case $a in
        --lib=*)        lib=${a#--lib=} ;;
        --out=*)        out=${a#--out=} ;;
        --bad-packages) bad=--bad-packages ;;
        --stat-runs=*)  stat_runs=${a#--stat-runs=} ;;
        --record)       record=1 ;;
        --help|-h)      sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "profile.sh: unknown argument $a (see --help)" >&2; exit 64 ;;
    esac
done
usage() { echo "profile.sh: $1 (see --help)" >&2; exit 64; }
[ -n "$lib" ] || usage "--lib is required"
[ -n "$out" ] || usage "--out is required"
case $stat_runs in ''|*[!0-9]*) usage "--stat-runs must be a number" ;; esac
[ "$stat_runs" -ge 1 ] || [ -n "$record" ] || usage "--stat-runs=0 needs --record"
[ -e "$lib/libmoar.so" ] || usage "$lib/libmoar.so missing"
[ -x "$rakudo" ] || usage "$rakudo is not executable"
command -v perf > /dev/null || usage "perf not found"
[ -e "$out" ] && usage "$out exists; pick a fresh --out"
case $out in /*) ;; *) out=$PWD/$out ;; esac
rakulib="$root/tools/bench/gc/lib,$(dirname "$rakudo")/lib"

load() { cut -d' ' -f1 /proc/loadavg; }
wait_load() {
    waited=0
    until awk -v m="$max_load" '{ exit !($1 < m) }' /proc/loadavg; do
        if [ "$waited" -ge 1800 ]; then
            echo "profile.sh: load average stayed at or above $max_load for 30 minutes; giving up" >&2
            exit 1
        fi
        sleep 10
        waited=$((waited + 10))
    done
}

mkdir -p "$out"
: > "$out/load.log"
cd "$root"
export LD_LIBRARY_PATH="$lib" RAKULIB="$rakulib"

wait_load
echo "warmup load $(load)" | tee -a "$out/load.log" >&2
if ! "$rakudo" tools/bench/gc/crc-getter.raku --volume=1 --runs=1 > "$out/warmup.out" 2>&1; then
    echo "profile.sh: warm-up failed; see $out/warmup.out" >&2
    exit 1
fi

n=1
while [ "$n" -le "$stat_runs" ]; do
    wait_load
    echo "stat $n load $(load)" | tee -a "$out/load.log" >&2
    if ! perf stat -x, -o "$out/stat-$n.csv" -e "$events" \
            "$rakudo" tools/bench/gc/crc-getter.raku --volume=100000 --runs=5 $bad \
            > "$out/stat-$n.out" 2>&1; then
        echo "profile.sh: stat run $n failed; see $out/stat-$n.out" >&2
        exit 1
    fi
    n=$((n + 1))
done

if [ -n "$record" ]; then
    wait_load
    echo "record load $(load)" | tee -a "$out/load.log" >&2
    if ! perf record -e cycles:u -F 4000 -o "$out/perf.data" \
            "$rakudo" tools/bench/gc/crc-getter.raku --volume=100000 --runs=5 $bad \
            > "$out/record.out" 2>&1; then
        echo "profile.sh: record run failed; see $out/record.out" >&2
        exit 1
    fi
    perf report -i "$out/perf.data" --sort dso,symbol --stdio -n > "$out/report.txt" 2> "$out/report.err"
fi
echo "end load $(load)" >> "$out/load.log"

[ "$stat_runs" -ge 1 ] || exit 0
perl - "$out" "$stat_runs" "$events" <<'PERL' > "$out/stat.tsv"
use strict; use warnings;
my ($out, $runs, $events) = @ARGV;
sub median { my @s = sort { $a <=> $b } @_; my $n = @s; $n % 2 ? $s[$n / 2] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
my @ev = split /,/, $events;
my %v;    # event -> [values per run]
for my $k (1 .. $runs) {
    my $f = "$out/stat-$k.csv";
    open my $fh, '<', $f or die "$f: $!";
    my %seen;
    while (<$fh>) {
        next if /^#/ || /^\s*$/;
        my @c = split /,/;
        next unless defined $c[2] && grep { $_ eq $c[2] } @ev;
        die "$f: $c[2] not counted: $c[0]\n" unless $c[0] =~ /^\d+$/;
        push @{ $v{$c[2]} }, $c[0];
        $seen{$c[2]} = 1;
    }
    for my $e (@ev) { die "$f: no $e\n" unless $seen{$e} }
}
print join("\t", 'event', 'median', 'min', 'max', map { "run$_" } 1 .. $runs), "\n";
for my $e (@ev) {
    my @s = sort { $a <=> $b } @{ $v{$e} };
    print join("\t", $e, median(@s), $s[0], $s[-1], @{ $v{$e} }), "\n";
}
PERL
echo "profile.sh: wrote $out/stat.tsv" >&2
