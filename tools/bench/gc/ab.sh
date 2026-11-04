#!/bin/sh
# A/B runner for the GC port's performance and memory gate (spec
# traces/llm/specs/2026-11-04-zig-gc-port-design.md, section 6): two libmoar
# builds measured in interleaved rounds on the user's crc-getter program.
#
# Each run is
#     LD_LIBRARY_PATH=<lib> RAKULIB=<rakulib> tools/bench/timev.py <time file> \
#         <rakudo> tools/bench/gc/<program>.raku --volume=N --runs=5 [--bad-packages]
# (spesh and precompilation on, as a user runs it). One untimed warm-up run
# per side at --volume=1 comes first, so module precompilation is not timed.
# Per round the side order is rotated (round 1 base then head, round 2 head
# then base, ...); each side runs K times in its turn. Before every run the
# script waits until the 1-minute load average is below --max-load (30
# minutes at most, then exit 1) and appends the load to <out>/load.log.
# Writes <out>/<side>-r<round>-<run>.time (timev.py's output),
# <out>/<side>-r<round>-<run>.out (the program's output), <out>/load.log and
# <out>/summary.md: per side the median wall and peak RSS of each round, the
# median and min-max of those round medians, and the ratios head/base of the
# medians of round medians for wall and RSS.
#
# Usage: tools/bench/gc/ab.sh --base=LIBDIR --head=LIBDIR --rounds=R --runs=K
#            --volume=N [--bad-packages] --out=DIR
#            [--program=crc-getter|crc-sequential (default crc-getter)]
#            [--rakudo=PATH] [--rakulib=LIST] [--max-load=L (default 2.0)]
#        tools/bench/gc/ab.sh --help
# LIBDIR holds the libmoar.so of a side (<prefix>/lib). --rakudo defaults to
# $RAKUDO, else /home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m;
# --rakulib defaults to tools/bench/gc/lib plus the lib/ beside --rakudo.
# DIR must not exist. The two LIBDIR strings must be of equal length: the
# install path is baked into libmoar's config strings, and its length changes
# the allocation sequence, so an unequal pair is refused (exit 4) before
# anything runs. Exit: 0 done, 1 a run failed or the load never fell,
# 4 the LIBDIRs differ in length, 64 misuse.
set -e

root=$(cd "$(dirname "$0")/../../.." && pwd)

base= head= rounds= runs= volume= bad= out= program=crc-getter max_load=2.0
rakudo=${RAKUDO:-/home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m}
rakulib=
for a in "$@"; do
    case $a in
        --base=*)      base=${a#--base=} ;;
        --head=*)      head=${a#--head=} ;;
        --rounds=*)    rounds=${a#--rounds=} ;;
        --runs=*)      runs=${a#--runs=} ;;
        --volume=*)    volume=${a#--volume=} ;;
        --bad-packages) bad=--bad-packages ;;
        --out=*)       out=${a#--out=} ;;
        --program=crc-getter|--program=crc-sequential) program=${a#--program=} ;;
        --rakudo=*)    rakudo=${a#--rakudo=} ;;
        --rakulib=*)   rakulib=${a#--rakulib=} ;;
        --max-load=*)  max_load=${a#--max-load=} ;;
        --help|-h)     sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "ab.sh: unknown argument $a (see --help)" >&2; exit 64 ;;
    esac
done
usage() { echo "ab.sh: $1 (see --help)" >&2; exit 64; }
[ -n "$base" ] && [ -n "$head" ] || usage "--base and --head are required"
[ -n "$out" ] || usage "--out is required"
for v in "rounds:$rounds" "runs:$runs" "volume:$volume"; do
    case ${v#*:} in ''|*[!0-9]*) usage "--${v%%:*} must be a number" ;; esac
done
[ "$rounds" -ge 1 ] && [ "$runs" -ge 1 ] || usage "--rounds and --runs must be at least 1"
for l in "$base" "$head"; do
    [ -e "$l/libmoar.so" ] || usage "$l/libmoar.so missing"
done
if [ "${#base}" != "${#head}" ]; then
    echo "ab.sh: --base and --head differ in length (base $base is ${#base} characters, head $head is ${#head}); the install path changes the allocation sequence, use paths of equal length" >&2
    exit 4
fi
[ -x "$rakudo" ] || usage "$rakudo is not executable"
[ -e "$out" ] && usage "$out exists; pick a fresh --out"
case $out in /*) ;; *) out=$PWD/$out ;; esac
[ -n "$rakulib" ] || rakulib="$root/tools/bench/gc/lib,$(dirname "$rakudo")/lib"

load() { cut -d' ' -f1 /proc/loadavg; }
wait_load() {
    waited=0
    until awk -v m="$max_load" '{ exit !($1 < m) }' /proc/loadavg; do
        if [ "$waited" -ge 1800 ]; then
            echo "ab.sh: load average stayed at or above $max_load for 30 minutes; giving up" >&2
            exit 1
        fi
        sleep 10
        waited=$((waited + 10))
    done
}
lib_of() { if [ "$1" = base ]; then echo "$base"; else echo "$head"; fi; }

mkdir -p "$out"
: > "$out/load.log"
cd "$root"

for side in base head; do
    wait_load
    echo "warmup $side load $(load)" | tee -a "$out/load.log" >&2
    if ! LD_LIBRARY_PATH="$(lib_of $side)" RAKULIB="$rakulib" \
            "$rakudo" "tools/bench/gc/$program.raku" --volume=1 --runs=1 > "$out/$side-warmup.out" 2>&1; then
        echo "ab.sh: $side warm-up failed; see $out/$side-warmup.out" >&2
        exit 1
    fi
done

round=1
while [ "$round" -le "$rounds" ]; do
    if [ $((round % 2)) = 1 ]; then order="base head"; else order="head base"; fi
    for side in $order; do
        run=1
        while [ "$run" -le "$runs" ]; do
            wait_load
            echo "round $round $side run $run load $(load)" | tee -a "$out/load.log" >&2
            if ! LD_LIBRARY_PATH="$(lib_of $side)" RAKULIB="$rakulib" \
                    python3 "$root/tools/bench/timev.py" "$out/$side-r$round-$run.time" \
                    "$rakudo" "tools/bench/gc/$program.raku" --volume="$volume" --runs=5 $bad \
                    > "$out/$side-r$round-$run.out" 2>&1; then
                echo "ab.sh: $side round $round run $run failed; see $out/$side-r$round-$run.out" >&2
                exit 1
            fi
            run=$((run + 1))
        done
    done
    round=$((round + 1))
done
echo "end load $(load)" >> "$out/load.log"

perl - "$out" "$rounds" "$runs" "$program" "$volume" "$bad" <<'PERL' > "$out/summary.md"
use strict; use warnings;
my ($out, $rounds, $runs, $program, $volume, $bad) = @ARGV;
sub median { my @s = sort { $a <=> $b } @_; my $n = @s; $n % 2 ? $s[$n / 2] : ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
my %rm;    # side -> metric -> [round medians]
for my $side (qw(base head)) {
    for my $r (1 .. $rounds) {
        my (@wall, @rss);
        for my $k (1 .. $runs) {
            my $f = "$out/$side-r$r-$k.time";
            open my $fh, '<', $f or die "$f: $!";
            while (<$fh>) {
                push @wall, $1 * 60 + $2 if /Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\d+):([\d.]+)/;
                push @rss, $1 if /Maximum resident set size \(kbytes\): (\d+)/;
            }
        }
        push @{ $rm{$side}{wall} }, median(@wall);
        push @{ $rm{$side}{rss} }, median(@rss);
    }
}
print "# GC A/B: $program --volume=$volume --runs=5", ($bad ? " $bad" : ''), "\n\n";
print "$rounds rounds, $runs runs per side per round, side order rotated per round.\n";
print "Cells: median of the round medians [min-max of the round medians].\n\n";
print "| side | wall s | peak RSS kB | round medians (wall s) | round medians (RSS kB) |\n|---|---:|---:|---|---|\n";
for my $side (qw(base head)) {
    my ($w, $m) = ($rm{$side}{wall}, $rm{$side}{rss});
    my @ws = sort { $a <=> $b } @$w; my @ms = sort { $a <=> $b } @$m;
    printf "| %s | %.2f [%.2f-%.2f] | %d [%d-%d] | %s | %s |\n", $side,
        median(@$w), $ws[0], $ws[-1], median(@$m), $ms[0], $ms[-1],
        join(' ', map { sprintf '%.2f', $_ } @$w), join(' ', @$m);
}
printf "\nRatio head/base (medians of round medians): wall %.3f, RSS %.3f\n",
    median(@{ $rm{head}{wall} }) / median(@{ $rm{base}{wall} }),
    median(@{ $rm{head}{rss} }) / median(@{ $rm{base}{rss} });
PERL
echo "ab.sh: wrote $out/summary.md" >&2
