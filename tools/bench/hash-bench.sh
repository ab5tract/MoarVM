#!/bin/sh
# Run the string hash table benchmarks of spec §10 against both engines and
# render the comparison tables (traces/llm/bench/hash-<date>.md).
#
# 1. The C-API microbenchmark, `zig build hash-bench`, once per engine
#    (-Dzig-impl=true: the Zig engine; false: the C tables). The run step
#    reuses the zig cache, so no install is needed.
# 2. With --raku-c=<raku> --raku-zig=<raku> (a raku, or any command that
#    runs a .raku script, built on a C-engine and a Zig-engine moar), the
#    Raku-level script tools/bench/hash-bench.raku with each.
#
# Every other argument (--sizes=, --runs=, --max-size=) is passed to both
# harnesses. The raw TSVs are kept beside the markdown.
#
# Usage: tools/bench/hash-bench.sh [--out=FILE] [--raku-c=CMD --raku-zig=CMD]
#            [--sizes=N,N,...] [--runs=K] [--max-size=N]
set -e

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

out=
raku_c=
raku_zig=
args=
for a in "$@"; do
    case $a in
        --out=*)      out=${a#--out=} ;;
        --raku-c=*)   raku_c=${a#--raku-c=} ;;
        --raku-zig=*) raku_zig=${a#--raku-zig=} ;;
        --sizes=*|--runs=*|--max-size=*) args="$args $a" ;;
        *) echo "hash-bench.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done
if [ -n "$raku_c" ] && [ -z "$raku_zig" ] || [ -z "$raku_c" ] && [ -n "$raku_zig" ]; then
    echo "hash-bench.sh: --raku-c and --raku-zig go together" >&2
    exit 2
fi
if [ -z "$out" ]; then
    mkdir -p traces/llm/bench
    out=traces/llm/bench/hash-$(date +%Y-%m-%d).md
fi
raw=${out%.md}

# The Perl build's generated files would shadow the zig-generated config.h.
rm -f src/gen/config.h src/gen/config.c src/gen/config.o

for engine in zig c; do
    case $engine in zig) impl=true ;; c) impl=false ;; esac
    echo "hash-bench.sh: microbenchmark, $engine engine" >&2
    start=$(date +%s)
    # shellcheck disable=SC2086
    zig build hash-bench --prefix "$root/zig-out" -Dzig-impl=$impl -- $args > "$raw.micro-$engine.tsv"
    echo "hash-bench.sh: $(( $(date +%s) - start ))s" >&2
done

if [ -n "$raku_c" ]; then
    for engine in zig c; do
        case $engine in zig) cmd=$raku_zig ;; c) cmd=$raku_c ;; esac
        echo "hash-bench.sh: Raku benchmark, $engine engine ($cmd)" >&2
        start=$(date +%s)
        # shellcheck disable=SC2086
        $cmd tools/bench/hash-bench.raku --engine=$engine $args > "$raw.raku-$engine.tsv"
        echo "hash-bench.sh: $(( $(date +%s) - start ))s" >&2
    done
fi

# One markdown table from a zig TSV and a c TSV: rows = sizes, columns =
# ops, cells = zig_ns/c_ns (zig_ns / c_ns), last column the memory pair.
render() {
    awk -F '\t' -v memory="$3" '
        FNR == 1 { file++ }
        NF < 5 { next }
        {
            engine = $1; size = $2 + 0; op = $3
            ns[engine, size, op] = $4
            mem[engine, size] = $5
            if (!(size in sizes)) { sizes[size] = 1; order[++nsizes] = size }
            if (!(op in ops)) { ops[op] = 1; oporder[++nops] = op }
        }
        END {
            # Rows in numeric order; columns in the order first seen.
            for (i = 1; i <= nsizes; i++)
                for (j = i + 1; j <= nsizes; j++)
                    if (order[j] < order[i]) { t = order[i]; order[i] = order[j]; order[j] = t }
            header = "| size |"; rule = "|---:|"
            for (k = 1; k <= nops; k++) { header = header " " oporder[k] " |"; rule = rule "---:|" }
            print header " " memory " zig / c |"
            print rule "---:|"
            for (i = 1; i <= nsizes; i++) {
                size = order[i]
                line = "| " size " |"
                for (k = 1; k <= nops; k++) {
                    op = oporder[k]
                    z = ns["zig", size, op]; c = ns["c", size, op]
                    if (z == "" || c == "") cell = "-"
                    else if (c + 0 == 0) cell = "inf (" z " / " c ")"
                    else cell = sprintf("%.2f (%s / %s)", z / c, z, c)
                    line = line " " cell " |"
                }
                mz = mem["zig", size]; mc = mem["c", size]
                if (mz == "") mz = "-"
                if (mc == "") mc = "-"
                print line " " mz " / " mc " |"
            }
        }' "$1" "$2"
}

{
    echo "# String hash table benchmarks, $(date +%Y-%m-%d)"
    echo
    echo "Cells are \`zig_ns / c_ns\` (both in nanoseconds per operation, medians of"
    echo "the runs); below 1 the Zig engine is faster. Arguments:${args:- (the default ladder)}."
    echo
    echo "## C-API microbenchmark (zig build hash-bench)"
    echo
    render "$raw.micro-zig.tsv" "$raw.micro-c.tsv" "alloc_bytes"
    if [ -n "$raku_c" ]; then
        echo
        echo "## Raku Hash (tools/bench/hash-bench.raku)"
        echo
        echo "zig: \`$raku_zig\`; c: \`$raku_c\`."
        echo
        render "$raw.raku-zig.tsv" "$raw.raku-c.tsv" "maxrss delta bytes"
    fi
} > "$out"
echo "hash-bench.sh: wrote $out" >&2
