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
# Every MVM_*, RAKUDO_*, NQP_*, RAKU_* and PERL6* variable and RAKULIB of the
# caller's environment is removed from the runs before the setting's own are
# set, so both sides see the same, known environment.
# Every run is under `systemd-run --user --scope -q -p MemoryMax=8G` and
# `timeout 900`, after the 1-minute load has dropped below 2.0 (polled every
# 60 s; the value is logged in <DIR>/load.log). Output goes to
#     <DIR>/<side>-<program>-<setting>-<i>.out     (stdout)
#     <DIR>/<side>-<program>-<setting>-<i>.err     (stderr, must stay empty)
# Before a side's runs, a probe through each runner prints the libmoar.so the
# process has mapped (from /proc/self/maps) and the variables of those
# families it sees; the library must lie under the side's prefix, else the
# script stops with exit 4. The probes are logged in <DIR>/libmoar.log.
# Then, per side, the serialization cross-read: the side deserializes what
# the other side serialized,
#     vmarray-serial.nqp --read=<DIR>/<other>-serial-<setting>-1.out
#         > <DIR>/<side>-serial-read-<setting>.out
# and that must equal the `.roundtrip` lines of the writer's own output
# (<DIR>/<other>-serial-<setting>.expect).
#
# Checks, in this order:
#   * a run that exits non-zero, times out or writes to stderr, or a probe
#     that finds another libmoar: exit 4;
#   * repeatability: the K outputs of a side, program and setting must be
#     identical, else exit 2 "not repeatable" with the first differing line;
#   * fidelity: base-...-1 against head-...-1 for every program and setting,
#     and each cross-read against its expectation. A difference in a line
#     that undefined-lines.txt (beside this script) does not list, a
#     different number of lines, or a cross-read that differs: exit 1 naming
#     the first differing line;
#   * if base and head differ, but only in lines listed in
#     undefined-lines.txt (self-splices whose result in C is what memcpy over
#     overlapping ranges leaves), each such line of the head must print what
#     memmove gives: memmove-model.py (beside this script) models it for
#     every listed line (the diff-nqp `<kind>.selfsplice.*` lines and the
#     diff-raku self-splices), and a head value that differs from the model
#     is exit 1 like any other difference. A listed line the model does not
#     cover would be named in the output as "accepted without a model
#     check"; none is at present. Then exit 3 "differs only in
#     undefined self-splice lines, and equals memmove there", with every
#     differing line, both values and the model's verdict. This is not a
#     pass: it is recorded and put to the user;
#   * exit 0 "identical" with the line counts.
#
# Usage: tools/bench/repr/diff.sh --base=PREFIX --head=PREFIX --out=DIR
#            [--runs=K (default 3)] [--nqp=PATH] [--rakudo=PATH]
#        tools/bench/repr/diff.sh --compare-only [--runs=K] --out=DIR
#        tools/bench/repr/diff.sh --help
# PREFIX is an install (<prefix>/lib/libmoar.so). DIR must not exist, except
# with --compare-only, which runs nothing and repeats the checks on the
# outputs already in DIR (K as in the run that made them; it first deletes
# the undefined-*.txt and model-*.txt files an earlier pass left there, so
# its verdict rests on this pass alone). The two
# PREFIX strings must be of equal length (the install path is baked into
# libmoar and its length moves the heap, and a few cases print what a
# memcpy over overlapping ranges leaves, which can follow the alignment of
# the storage); an unequal pair is misuse and refused before anything runs.
# Exit: 0 identical, 1 base and head differ, 2 a side not repeatable,
# 3 base and head differ only in the listed undefined self-splice lines and
# the head equals memmove there (or the line is named as not model-checked),
# 4 a run failed or a side did not load its own libmoar, 64 misuse.
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
        usage "--base and --head differ in length (base $base is ${#base} characters, head $head is ${#head}); use prefixes of equal length"
    fi
fi

undefined_list="$root/tools/bench/repr/undefined-lines.txt"
[ -r "$undefined_list" ] || usage "$undefined_list missing"
memmove_model="$root/tools/bench/repr/memmove-model.py"
[ -r "$memmove_model" ] || usage "$memmove_model missing"
programs="diff-nqp diff-raku serial devirt"
settings="spesh nospesh"
max_load=2.0

# first_diff A B: the first line where files A and B differ. Lines are cut
# at 300 characters for the report (a serialized blob is long). When no line
# differs but the bytes do (awk reads a last line without its newline as a
# whole line), it says which file ends without a newline.
first_diff() {
    fd_lines=$(first_line_diff "$1" "$2")
    if [ -n "$fd_lines" ]; then
        printf '%s\n' "$fd_lines"
    elif ! cmp -s "$1" "$2"; then
        fd_ends=
        for fd_f in "$1" "$2"; do
            if [ ! -s "$fd_f" ]; then
                fd_end="is empty"
            elif [ "$(tail -c 1 "$fd_f" | od -An -c | tr -d ' ')" = '\n' ]; then
                fd_end="ends with a newline"
            else
                fd_end="does not end with a newline"
            fi
            echo "  $fd_f $fd_end"
            fd_ends="$fd_ends|$fd_end"
        done
        case $fd_ends in
            "|ends with a newline|does not end with a newline"|"|does not end with a newline|ends with a newline")
                echo "  (no line differs; the files differ only in their final newline)" ;;
            *)  echo "  (no line differs as awk reads them; cmp: $(cmp "$1" "$2" 2>&1 || :))" ;;
        esac
    fi
}
first_line_diff() {
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

# The variables of the caller's environment that could change what a run
# does, as `-u NAME` arguments for env.
scrub=$(env | sed -n 's/^\(\(MVM_\|RAKUDO_\|NQP_\|RAKU_\|PERL6\)[A-Za-z0-9_]*\|RAKULIB\)=.*/-u \1/p')

# run_env LIBPREFIX SETTING COMMAND...: COMMAND with the side's library and
# the setting's variables, and none of the caller's.
run_env() {
    re_prefix=$1 re_setting=$2
    shift 2
    if [ "$re_setting" = spesh ]; then
        spesh_env="MVM_SPESH_BLOCKING=1"
    else
        spesh_env="MVM_SPESH_DISABLE=1"
    fi
    # shellcheck disable=SC2086
    env $scrub \
        LD_LIBRARY_PATH="$re_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        RAKUDO_NO_PRECOMPILATION=1 "$spesh_env" \
        systemd-run --user --scope -q -p MemoryMax=8G timeout 900 "$@"
}

# run_one LIBPREFIX SETTING STEM COMMAND...: one program run; stdout to
# STEM.out, stderr to STEM.err. Exit 4 on failure or on any stderr output.
run_one() {
    prefix=$1 setting=$2 stem=$3
    shift 3
    wait_load
    echo "$(basename "$stem") load $(cut -d' ' -f1 /proc/loadavg)" >> "$out/load.log"
    status=0
    run_env "$prefix" "$setting" "$@" > "$stem.out" 2> "$stem.err" || status=$?
    if [ "$status" != 0 ]; then
        echo "diff.sh: $(basename "$stem") failed with exit $status; see $stem.out and $stem.err" >&2
        exit 4
    fi
    if [ -s "$stem.err" ]; then
        echo "diff.sh: $(basename "$stem") wrote to stderr; see $stem.err" >&2
        exit 4
    fi
}

# probe SIDE LIBPREFIX: through each runner, which libmoar.so the process has
# mapped and which variables of the scrubbed families it sees. The library
# must lie under the prefix (symbolic links resolved), else exit 4: without
# this a side that silently ran another library would pass as identical.
nqp_probe='for nqp::split("\n", slurp("/proc/self/maps")) { if nqp::index($_, "libmoar") >= 0 { say(nqp::substr($_, nqp::index($_, "/"))); last } }; for nqp::getenvhash() { my $n := $_.key; say($n ~ "=" ~ $_.value) if nqp::eqat($n, "MVM_", 0) || nqp::eqat($n, "RAKU", 0) || nqp::eqat($n, "NQP_", 0) || nqp::eqat($n, "PERL6", 0) }'
raku_probe='say "/proc/self/maps".IO.lines.first(*.contains("libmoar")).words[*-1]; .say for %*ENV.pairs.grep({ .key ~~ /^[MVM_|RAKU|NQP_|PERL6]/ }).map({ .key ~ "=" ~ .value })'
probe() {
    pr_side=$1 pr_prefix=$2
    pr_real=$(cd "$pr_prefix" && pwd -P)
    for pr_runner in nqp rakudo; do
        if [ "$pr_runner" = nqp ]; then
            pr_out=$(run_env "$pr_prefix" nospesh "$nqp" -e "$nqp_probe" 2>&1) || { echo "diff.sh: the $pr_runner probe of $pr_side failed: $pr_out" >&2; exit 4; }
        else
            pr_out=$(run_env "$pr_prefix" nospesh "$rakudo" -e "$raku_probe" 2>&1) || { echo "diff.sh: the $pr_runner probe of $pr_side failed: $pr_out" >&2; exit 4; }
        fi
        pr_lib=$(printf '%s\n' "$pr_out" | sed -n 1p)
        pr_env=$(printf '%s\n' "$pr_out" | sed 1d | sort | tr '\n' ' ')
        echo "$pr_side $pr_runner libmoar=$pr_lib env: $pr_env" >> "$out/libmoar.log"
        echo "diff.sh: $pr_side through $pr_runner loads $pr_lib" >&2
        case $pr_lib in
            "$pr_real"/*) ;;
            *) echo "diff.sh: $pr_side ($pr_runner) loaded $pr_lib, which is not under its prefix $pr_real" >&2; exit 4 ;;
        esac
    done
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
        probe "$side" "$prefix"
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
    # The undefined-* and model-* files are this pass's findings: one left by
    # an earlier pass would be read below as if this pass had written it.
    rm -f "$out"/undefined-*.txt "$out"/model-*.txt
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

# only_listed PROGRAM A B: succeeds when A and B have the same number of
# lines, at least one line differs, and every line that differs has the same
# case name in both and that name is listed for PROGRAM in
# undefined-lines.txt; it then prints those lines with both values. Fails,
# printing nothing, otherwise (also when no line differs although the bytes
# do: a missing final newline).
only_listed() {
    awk -v P="$1" -v L="$undefined_list" -v A="$2" -v B="$3" '
        function name(s,  i) { i = index(s, ": "); return i ? substr(s, 1, i - 1) : s }
        function show(s) { return length(s) > 300 ? substr(s, 1, 300) "... (" length(s) " characters)" : s }
        FILENAME == L { if ($0 !~ /^#/ && $1 == P) { sub(/^[^ ]+ /, ""); listed[$0] = 1 } next }
        FILENAME == A { a[FNR] = $0; n = FNR; next }
        { m = FNR
          if (FNR > n) { bad = 1; exit }
          if (a[FNR] != $0) {
              if (name(a[FNR]) != name($0) || !(name($0) in listed)) { bad = 1; exit }
              d[++k] = sprintf("  %s\n    base: %s\n    head: %s", name($0), show(substr(a[FNR], length(name($0)) + 3)), show(substr($0, length(name($0)) + 3)))
          } }
        END { if (bad || m != n || k == 0) exit 1; for (i = 1; i <= k; i++) print d[i] }
    ' "$undefined_list" "$2" "$3"
}

# Fidelity.
differ=0 undefined=0
for program in $programs; do
    for setting in $settings; do
        if ! cmp -s "$out/base-$program-$setting-1.out" "$out/head-$program-$setting-1.out"; then
            if only_listed "$program" "$out/base-$program-$setting-1.out" "$out/head-$program-$setting-1.out" > "$out/undefined-$program-$setting.txt"; then
                undefined=$((undefined + $(grep -c '^  [^ ]' "$out/undefined-$program-$setting.txt" || :)))
                # The head's value on each such line against the memmove model.
                if ! sed -n 's/^  \([^ ].*\)$/\1/p' "$out/undefined-$program-$setting.txt" |
                    xargs -d '\n' python3 "$memmove_model" "$program" "$out/head-$program-$setting-1.out" > "$out/model-$program-$setting.txt"; then
                    echo "diff.sh: base and head differ ($program, $setting) only in listed lines, but the head does not print what memmove gives on all of them:" >&2
                    grep -A2 '^MISMATCH' "$out/model-$program-$setting.txt" >&2 || cat "$out/model-$program-$setting.txt" >&2
                    differ=1
                fi
            else
                rm -f "$out/undefined-$program-$setting.txt"
                echo "diff.sh: base and head differ ($program, $setting), first difference at" >&2
                first_diff "$out/base-$program-$setting-1.out" "$out/head-$program-$setting-1.out" >&2
                differ=1
            fi
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
if [ "$undefined" != 0 ]; then
    accepted=$(cat "$out"/model-*.txt | grep -c '^accepted without a model check' || :)
    echo "diff.sh: differs only in undefined self-splice lines, and equals memmove there ($undefined differing lines over the programs and settings, all listed in tools/bench/repr/undefined-lines.txt; $((undefined - accepted)) of them equal to memmove-model.py's memmove result, $accepted accepted without a model check, named below; everything else and the cross-read identical). Record this and put it to the user:" >&2
    for program in $programs; do
        for setting in $settings; do
            if [ -s "$out/undefined-$program-$setting.txt" ]; then
                echo "$program, $setting:" >&2
                cat "$out/undefined-$program-$setting.txt" >&2
                echo "$program, $setting, the head against the memmove model:" >&2
                sed 's/^/  /' "$out/model-$program-$setting.txt" >&2
            fi
        done
    done
    exit 3
fi

summary=
for program in $programs; do
    for setting in $settings; do
        summary="$summary $program/$setting $(wc -l < "$out/base-$program-$setting-1.out" | tr -d ' ')"
    done
done
echo "diff.sh: identical ($runs runs a side; lines:$summary; cross-read identical)" >&2
exit 0
