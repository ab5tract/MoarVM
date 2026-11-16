#!/bin/sh
# VMArray differential runner (spec
# traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md, section 7, items 2
# and 3): the output of the programs that drive the array, compared byte for
# byte between two prefixes.
#
# The programs, all in this directory:
#   diff-nqp   vmarray-diff.nqp    every operation over every slot kind
#   diff-raku  vmarray-diff.raku   native references, atomics, Rakudo's arrays
#   serial     vmarray-serial.nqp  serialized bytes of arrays of every kind
#   devirt     vmarray-devirt.nqp  the errors of the two functions the JIT
#                                  calls directly (a small program of its own
#                                  because only its shape reaches them)
# For each side (base, then head), each program and each of two spesh
# settings the script runs the program K times with
#     LD_LIBRARY_PATH=<prefix>/lib
# and, for the setting
#     spesh    MVM_SPESH_DISABLE unset and MVM_SPESH_BLOCKING=1 (the program
#              waits for the specializer, so what runs specialized and
#              compiled does not depend on thread timing),
#     nospesh  MVM_SPESH_DISABLE=1.
# The nqp programs run through --nqp (default
# /tmp/claude-1000/tune-zig-prefix/bin/nqp-m), the Raku one through --rakudo
# (default $RAKUDO, else the in-tree
# /home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m) with
# RAKUDO_NO_PRECOMPILATION=1; both load libmoar from LD_LIBRARY_PATH first.
# Every run is under `systemd-run --user --scope -q -p MemoryMax=8G` and
# `timeout 900`, after the 1-minute load has dropped below 2.0 (polled every
# 60 s; the value is logged in <DIR>/load.log). Output goes to
#     <DIR>/<side>-<program>-<setting>-<i>.out     (stdout)
#     <DIR>/<side>-<program>-<setting>-<i>.err     (stderr, must stay empty)
# Then, per side, the serialization cross-read: the side deserializes what
# the other side serialized,
#     vmarray-serial.nqp --read=<DIR>/<other>-serial-<setting>-1.out
#         > <DIR>/<side>-serial-read-<setting>.out
# and that must equal the `.roundtrip` lines of the writer's own output
# (<DIR>/<other>-serial-<setting>.expect).
#
# Checks, in this order:
#   * a run that exits non-zero, times out or writes to stderr: exit 4;
#   * repeatability: the K outputs of a side, program and setting must be
#     identical, else exit 2 "not repeatable" with the first differing line;
#   * fidelity: base-...-1 against head-...-1 for every program and setting,
#     and each cross-read against its expectation; exit 1 naming the first
#     differing line otherwise;
#   * exit 0 "identical" with the line counts.
#
# Usage: tools/bench/repr/diff.sh --base=PREFIX --head=PREFIX --out=DIR
#            [--runs=K (default 3)] [--nqp=PATH] [--rakudo=PATH]
#        tools/bench/repr/diff.sh --compare-only [--runs=K] --out=DIR
#        tools/bench/repr/diff.sh --help
# PREFIX is an install (<prefix>/lib/libmoar.so). DIR must not exist, except
# with --compare-only, which runs nothing and repeats the checks on the
# outputs already in DIR (K as in the run that made them). The two
# PREFIX strings must be of equal length (the install path is baked into
# libmoar and its length moves the heap, and a few cases print what a
# memcpy over overlapping ranges leaves, which can follow the alignment of
# the storage); an unequal pair is refused with exit 4 before anything runs.
# Exit: 0 identical, 1 base and head differ, 2 a side not repeatable,
# 4 a run failed or the prefixes differ in length, 64 misuse.
set -e

root=$(cd "$(dirname "$0")/../../.." && pwd)

base= head= out= runs=3 compare_only=
nqp=/tmp/claude-1000/tune-zig-prefix/bin/nqp-m
rakudo=${RAKUDO:-/home/longwalker/code/raku/x.core/zmoarz/rakudo/rakudo-m}
for a in "$@"; do
    case $a in
        --base=*)   base=${a#--base=} ;;
        --head=*)   head=${a#--head=} ;;
        --out=*)    out=${a#--out=} ;;
        --runs=*)   runs=${a#--runs=} ;;
        --nqp=*)    nqp=${a#--nqp=} ;;
        --rakudo=*) rakudo=${a#--rakudo=} ;;
        --compare-only) compare_only=1 ;;
        --help|-h)  sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "diff.sh: unknown argument $a (see --help)" >&2; exit 64 ;;
    esac
done
usage() { echo "diff.sh: $1 (see --help)" >&2; exit 64; }
[ -n "$out" ] || usage "--out is required"
case $out in /*) ;; *) out=$PWD/$out ;; esac
case $runs in ''|*[!0-9]*|0) usage "--runs must be a positive number" ;; esac
if [ -n "$compare_only" ]; then
    [ -d "$out" ] || usage "$out is not a directory"
else
    [ -n "$base" ] && [ -n "$head" ] || usage "--base and --head are required"
    for p in "$base" "$head"; do
        [ -e "$p/lib/libmoar.so" ] || usage "$p/lib/libmoar.so missing"
    done
    [ -x "$nqp" ] || usage "$nqp is not executable"
    [ -x "$rakudo" ] || usage "$rakudo is not executable"
    [ -e "$out" ] && usage "$out exists; pick a fresh --out"
    if [ "${#base}" != "${#head}" ]; then
        echo "diff.sh: --base and --head differ in length (base $base is ${#base} characters, head $head is ${#head}); use prefixes of equal length" >&2
        exit 4
    fi
fi

programs="diff-nqp diff-raku serial devirt"
settings="spesh nospesh"
max_load=2.0

# first_diff A B: the first line where files A and B differ, or nothing.
# Lines are cut at 300 characters for the report (a serialized blob is long).
first_diff() {
    awk -v A="$1" -v B="$2" '
        function show(s) { return length(s) > 300 ? substr(s, 1, 300) "... (" length(s) " characters)" : s }
        FILENAME == A { a[FNR] = $0; n = FNR; next }
        !done {
            if (FNR > n || a[FNR] != $0) {
                printf "line %d:\n  %s: %s\n  %s: %s\n", FNR, A, (FNR > n ? "<end of file>" : show(a[FNR])), B, show($0)
                done = 1
            }
            m = FNR
        }
        END { if (!done && n > m) printf "line %d:\n  %s: %s\n  %s: <end of file>\n", m + 1, A, show(a[m + 1]), B }
    ' "$1" "$2"
}

wait_load() {
    waited=0
    until awk -v m="$max_load" '{ exit !($1 < m) }' /proc/loadavg; do
        if [ "$waited" -ge 3600 ]; then
            echo "diff.sh: load average stayed at or above $max_load for an hour; giving up" >&2
            exit 4
        fi
        sleep 60
        waited=$((waited + 60))
    done
}

# run_one LIBPREFIX SETTING STEM COMMAND...: one program run; stdout to
# STEM.out, stderr to STEM.err. Exit 4 on failure or on any stderr output.
run_one() {
    prefix=$1 setting=$2 stem=$3
    shift 3
    wait_load
    echo "$(basename "$stem") load $(cut -d' ' -f1 /proc/loadavg)" >> "$out/load.log"
    if [ "$setting" = spesh ]; then
        spesh_env="MVM_SPESH_BLOCKING=1"
    else
        spesh_env="MVM_SPESH_DISABLE=1"
    fi
    status=0
    env -u MVM_SPESH_DISABLE -u MVM_SPESH_BLOCKING -u MVM_JIT_DISABLE -u MVM_SPESH_NODELAY \
        LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        RAKUDO_NO_PRECOMPILATION=1 "$spesh_env" \
        systemd-run --user --scope -q -p MemoryMax=8G timeout 900 "$@" \
        > "$stem.out" 2> "$stem.err" || status=$?
    if [ "$status" != 0 ]; then
        echo "diff.sh: $(basename "$stem") failed with exit $status; see $stem.out and $stem.err" >&2
        exit 4
    fi
    if [ -s "$stem.err" ]; then
        echo "diff.sh: $(basename "$stem") wrote to stderr; see $stem.err" >&2
        exit 4
    fi
}

command_of() {
    case $1 in
        diff-nqp)  echo "$nqp tools/bench/repr/vmarray-diff.nqp" ;;
        diff-raku) echo "$rakudo tools/bench/repr/vmarray-diff.raku" ;;
        serial)    echo "$nqp tools/bench/repr/vmarray-serial.nqp" ;;
        devirt)    echo "$nqp tools/bench/repr/vmarray-devirt.nqp" ;;
    esac
}

cd "$root"
if [ -z "$compare_only" ]; then
    mkdir -p "$out"
    for side in base head; do
        if [ "$side" = base ]; then prefix=$base; else prefix=$head; fi
        for program in $programs; do
            for setting in $settings; do
                i=1
                while [ "$i" -le "$runs" ]; do
                    echo "diff.sh: $side $program $setting run $i (load $(cut -d' ' -f1 /proc/loadavg))" >&2
                    # shellcheck disable=SC2046
                    run_one "$prefix" "$setting" "$out/$side-$program-$setting-$i" $(command_of "$program")
                    i=$((i + 1))
                done
            done
        done
    done
else
    for side in base head; do
        for program in $programs; do
            for setting in $settings; do
                i=1
                while [ "$i" -le "$runs" ]; do
                    [ -e "$out/$side-$program-$setting-$i.out" ] || usage "$out/$side-$program-$setting-$i.out missing"
                    i=$((i + 1))
                done
            done
        done
    done
fi

# Repeatability, per side.
for side in base head; do
    for program in $programs; do
        for setting in $settings; do
            i=2
            while [ "$i" -le "$runs" ]; do
                if ! cmp -s "$out/$side-$program-$setting-1.out" "$out/$side-$program-$setting-$i.out"; then
                    echo "diff.sh: $side not repeatable ($program, $setting): run 1 against run $i, first difference at" >&2
                    first_diff "$out/$side-$program-$setting-1.out" "$out/$side-$program-$setting-$i.out" >&2
                    exit 2
                fi
                i=$((i + 1))
            done
        done
    done
done

# The serialization cross-read: each side reads what the other wrote.
for setting in $settings; do
    for side in base head; do
        sed -n 's/\.roundtrip: /.read: /p' "$out/$side-serial-$setting-1.out" > "$out/$side-serial-$setting.expect"
        echo "done: $(wc -l < "$out/$side-serial-$setting.expect" | tr -d ' ')" >> "$out/$side-serial-$setting.expect"
    done
    for side in base head; do
        if [ "$side" = base ]; then prefix=$base other=head; else prefix=$head other=base; fi
        if [ -n "$compare_only" ]; then
            [ -e "$out/$side-serial-read-$setting.out" ] || usage "$out/$side-serial-read-$setting.out missing"
            continue
        fi
        echo "diff.sh: $side reads the serialization of $other, $setting (load $(cut -d' ' -f1 /proc/loadavg))" >&2
        run_one "$prefix" "$setting" "$out/$side-serial-read-$setting" \
            "$nqp" tools/bench/repr/vmarray-serial.nqp --read="$out/$other-serial-$setting-1.out"
    done
done

# Fidelity.
differ=0
for program in $programs; do
    for setting in $settings; do
        if ! cmp -s "$out/base-$program-$setting-1.out" "$out/head-$program-$setting-1.out"; then
            echo "diff.sh: base and head differ ($program, $setting), first difference at" >&2
            first_diff "$out/base-$program-$setting-1.out" "$out/head-$program-$setting-1.out" >&2
            differ=1
        fi
    done
done
for setting in $settings; do
    for side in base head; do
        if [ "$side" = base ]; then other=head; else other=base; fi
        if ! cmp -s "$out/$other-serial-$setting.expect" "$out/$side-serial-read-$setting.out"; then
            echo "diff.sh: $side does not read the serialization of $other as $other does ($setting), first difference at" >&2
            first_diff "$out/$other-serial-$setting.expect" "$out/$side-serial-read-$setting.out" >&2
            differ=1
        fi
    done
done
[ "$differ" = 0 ] || exit 1

summary=
for program in $programs; do
    for setting in $settings; do
        summary="$summary $program/$setting $(wc -l < "$out/base-$program-$setting-1.out" | tr -d ' ')"
    done
done
echo "diff.sh: identical ($runs runs a side; lines:$summary; cross-read identical)" >&2
exit 0
