#!/bin/sh
# The full-cleanup runner (spec traces/llm/specs/2026-11-09-zig-native-gc-design.md,
# section 9): the three programs of tools/bench/gc/cleanup/ (from the
# Campaign 4 interlude: a background thread allocating while the main thread
# returns, one blocked in nqp::sleep, three threads) run under
# `moar --full-cleanup`, which exercises global destruction with threads
# still alive or blocked.
#
# Each run is
#     systemd-run --user --scope -q -p MemoryMax=8G \
#         timeout 60 <P>/bin/moar --full-cleanup --libpath=<nqp lib> \
#         <nqp lib>/nqp.moarvm <program>
# with LD_LIBRARY_PATH=<P>/lib, --runs times per program. A run passes when
# it exits 0 and its last line of output is `main returning`. Prints a table
# of program, run, exit code and whether the last line was right, then a
# total. --stress runs the heavier-allocating variants instead: each inner
# loop bound multiplied by 20 (100 to 2000, 10 to 200), as the interlude's
# extra verification did.
#
# Usage: tools/bench/gc/cleanup.sh --prefix=P --runs=N [--stress]
#            [--nqp-lib=DIR]
#        tools/bench/gc/cleanup.sh --help
# --nqp-lib defaults to /tmp/claude-1000/tune-zig-prefix/share/nqp/lib.
# Exit: 0 every run passed, 1 a run failed (its output is kept and its path
# printed), 64 misuse.
set -e

root=$(cd "$(dirname "$0")/../../.." && pwd)

prefix= runs= stress= nqp_lib=/tmp/claude-1000/tune-zig-prefix/share/nqp/lib
for a in "$@"; do
    case $a in
        --prefix=*)  prefix=${a#--prefix=} ;;
        --runs=*)    runs=${a#--runs=} ;;
        --stress)    stress=1 ;;
        --nqp-lib=*) nqp_lib=${a#--nqp-lib=} ;;
        --help|-h)   sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "cleanup.sh: unknown argument $a (see --help)" >&2; exit 64 ;;
    esac
done
usage() { echo "cleanup.sh: $1 (see --help)" >&2; exit 64; }
[ -n "$prefix" ] || usage "--prefix is required"
case $runs in ''|*[!0-9]*) usage "--runs must be a number" ;; esac
[ "$runs" -ge 1 ] || usage "--runs must be at least 1"
[ -x "$prefix/bin/moar" ] || usage "$prefix/bin/moar is not executable"
[ -e "$nqp_lib/nqp.moarvm" ] || usage "$nqp_lib/nqp.moarvm missing"

work=$(mktemp -d "${TMPDIR:-/tmp}/cleanup.XXXXXX")
trap 'rm -rf "$work"; exit 130' INT TERM
progs="running blocked three"
for p in $progs; do
    if [ -n "$stress" ]; then
        sed 's/\$j < 100 /$j < 2000 /; s/\$j < 10 /$j < 200 /' \
            "$root/tools/bench/gc/cleanup/$p.nqp" > "$work/$p.nqp"
    else
        cp "$root/tools/bench/gc/cleanup/$p.nqp" "$work/$p.nqp"
    fi
done

printf '| program | run | exit | last line `main returning` |\n|---|---|---|---|\n'
total=0 passed=0
for p in $progs; do
    i=1
    while [ "$i" -le "$runs" ]; do
        log="$work/$p-$i.out"
        set +e
        LD_LIBRARY_PATH="$prefix/lib" systemd-run --user --scope -q -p MemoryMax=8G \
            timeout 60 "$prefix/bin/moar" --full-cleanup --libpath="$nqp_lib" \
            "$nqp_lib/nqp.moarvm" "$work/$p.nqp" > "$log" 2>&1
        rc=$?
        set -e
        last=no
        [ "$(tail -n 1 "$log")" = "main returning" ] && last=yes
        total=$((total + 1))
        if [ "$rc" -eq 0 ] && [ "$last" = yes ]; then
            passed=$((passed + 1))
            rm -f "$log"
        fi
        printf '| %s | %d | %d | %s |\n' "$p" "$i" "$rc" "$last"
        i=$((i + 1))
    done
done
echo
echo "passed $passed of $total ($prefix${stress:+, --stress})"
if [ "$passed" -ne "$total" ]; then
    echo "cleanup.sh: failing runs' output kept in $work" >&2
    exit 1
fi
rm -rf "$work"
