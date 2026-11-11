#!/bin/sh
# Call-boundary parity check (spec traces/llm/specs/2026-11-11-gc-call-boundary-design.md,
# section 5): where the C collector calls a function out of line, the Zig
# collector's call to the ported function is out of line too. Under
# -Dlto=true LLVM inlines across the whole Zig module, so the rule is stated
# with `noinline` at the Zig definition; this script checks the result in a
# built library.
#
# For each row (caller symbol, callee symbol) of the table below, both
# symbols must be defined in LIBDIR/libmoar.so (`nm --defined-only`, exact
# name), and the caller's disassembly
#     objdump -d --no-show-raw-insn --disassemble=<caller> LIBDIR/libmoar.so
# must contain at least one `call <addr> <callee>` line (or `callq`, as
# older binutils and llvm-objdump print it), the callee's name matched
# exactly between the angle brackets. Requires GNU binutils (`objdump`,
# `nm`).
#
# The table: the noinline rows of the audit (traces/llm/bench/cb-audit.md),
# with the symbol names LTO gives them in a -Dstrip=false build, plus the
# markCollectable row (out of line in both builds without a noinline; the
# check keeps it so).
#     caller                                callee                    source
#     gc.allocation.allocateObject          gc.roots.gen2Add          spike
#     gc.allocation.allocateObject          gc.finalize.addToQueue    spike
#     gc.collect.processWorklist            gc.roots.gen2Add          spike
#     gc.allocation.allocateStable          gc.roots.gen2Add          gen2Add
#     gc.allocation.allocateTypeObject      gc.roots.gen2Add          gen2Add
#     gc.gen2.transfer                      gc.roots.gen2Add          gen2Add
#     gc.collect.markCollectable            gc.worklist.addSlow       audit
#     gc.collect.collect                    gc.worklist.addSlow       audit
#     gc.roots.addPermanentsToWorklist      gc.worklist.addSlow       audit
#     gc.roots.addInstanceRootsToWorklist   gc.worklist.addSlow       audit
#     gc.roots.addTcRootsToWorklist         gc.worklist.addSlow       audit
#     gc.roots.addTempsToWorklist           gc.worklist.addSlow       audit
#     gc.roots.addFrameRootsToWorklist      gc.worklist.addSlow       audit
#     gc.roots.addFrameRegistersToWorklist  gc.worklist.addSlow       audit
#     gc.collect.collect                    gc.worklist.create        audit
#     gc.collect.collect                    gc.worklist.presizeFor    audit
#     gc.orchestrate.runGc                  gc.finalize.walkQueues    audit
#     gc.collect.collect                    gc.collect.markCollectable  audit
#
# Usage: tools/bench/gc/call-boundary.sh LIBDIR
#        tools/bench/gc/call-boundary.sh --help
# LIBDIR is the lib/ directory of a -Dstrip=false install (a stripped
# library has no local symbols, and every row fails with exit 2).
# Rows are checked in table order, each for its two symbols and then for
# the call, and the first failure ends the run.
# Exit: 0 every row satisfied, 1 a row whose caller does not call the
# callee (named on stderr), 2 a row's caller or callee symbol absent from
# nm (named on stderr), 64 misuse.
set -e

case $1 in
    --help|-h) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac
usage() { echo "call-boundary.sh: $1 (see --help)" >&2; exit 64; }
[ $# -eq 1 ] || usage "exactly one LIBDIR is required"
lib=$1/libmoar.so
[ -f "$lib" ] || usage "$lib does not exist"

rows='gc.allocation.allocateObject gc.roots.gen2Add
gc.allocation.allocateObject gc.finalize.addToQueue
gc.collect.processWorklist gc.roots.gen2Add
gc.allocation.allocateStable gc.roots.gen2Add
gc.allocation.allocateTypeObject gc.roots.gen2Add
gc.gen2.transfer gc.roots.gen2Add
gc.collect.markCollectable gc.worklist.addSlow
gc.collect.collect gc.worklist.addSlow
gc.roots.addPermanentsToWorklist gc.worklist.addSlow
gc.roots.addInstanceRootsToWorklist gc.worklist.addSlow
gc.roots.addTcRootsToWorklist gc.worklist.addSlow
gc.roots.addTempsToWorklist gc.worklist.addSlow
gc.roots.addFrameRootsToWorklist gc.worklist.addSlow
gc.roots.addFrameRegistersToWorklist gc.worklist.addSlow
gc.collect.collect gc.worklist.create
gc.collect.collect gc.worklist.presizeFor
gc.orchestrate.runGc gc.finalize.walkQueues
gc.collect.collect gc.collect.markCollectable'

syms=$(mktemp) || exit 64
trap 'rm -f "$syms"' EXIT
nm --defined-only "$lib" | awk 'NF == 3 { print $3 }' > "$syms"

# Row by row, in table order: the symbols (exit 2), then the call (exit 1).
n=0
printf '%s\n' "$rows" | {
    while read -r caller callee; do
        for s in "$caller" "$callee"; do
            if ! grep -qxF "$s" "$syms"; then
                echo "call-boundary.sh: symbol $s (row $caller -> $callee) is not defined in $lib" >&2
                exit 2
            fi
        done
        k=$(objdump -d --no-show-raw-insn --disassemble="$caller" "$lib" |
            grep -E '[[:space:]]callq?[[:space:]]' | grep -cF "<$callee>" || true)
        if [ "$k" -lt 1 ]; then
            echo "call-boundary.sh: FAIL $caller does not call $callee in $lib" >&2
            exit 1
        fi
        echo "ok $caller -> $callee ($k)"
        n=$((n + 1))
    done
    echo "call-boundary.sh: all $n rows satisfied in $lib"
}
