#!/bin/sh
# Compare the zig build's JIT code generators with the Perl originals.
#   sh tools/check-jit-tools.sh <zig core_templates.h> <zig tile_pattern.h> <zig emit.c>
# Run from the repository root (zig build check-jit-tools does this).
#  - core_templates.h: identical from line 2 (line 1 names the generator)
#  - tile_pattern.h:   identical from line 2 after canonical ruleset renumbering
#                      of the Perl output (its numbering follows Perl hash order)
#  - emit.c:           identical to the Perl build's src/jit/x64/emit.c when present
set -eu
zig_ct=$1
zig_tp=$2
zig_emit=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

perl -Itools/ tools/expr-template-compiler.pl -o "$tmp/ct.h" src/jit/core_templates.expr
tail -n +2 "$tmp/ct.h" > "$tmp/ct.perl.body"
tail -n +2 "$zig_ct" > "$tmp/ct.zig.body"
if ! cmp -s "$tmp/ct.perl.body" "$tmp/ct.zig.body"; then
    echo "check-jit-tools: core_templates.h differs from the Perl output:" >&2
    diff "$tmp/ct.perl.body" "$tmp/ct.zig.body" | head -20 >&2
    exit 1
fi

perl -Itools/ tools/tiler-table-generator.pl --debug -o "$tmp/tp.h" src/jit/x64/tile_pattern.tile > "$tmp/tp.debug"
perl tools/canonicalize-tile-table.pl "$tmp/tp.debug" "$tmp/tp.h" > "$tmp/tp.canon.h"
tail -n +2 "$tmp/tp.canon.h" > "$tmp/tp.perl.body"
tail -n +2 "$zig_tp" > "$tmp/tp.zig.body"
if ! cmp -s "$tmp/tp.perl.body" "$tmp/tp.zig.body"; then
    echo "check-jit-tools: tile_pattern.h differs from the canonicalised Perl output:" >&2
    diff "$tmp/tp.perl.body" "$tmp/tp.zig.body" | head -20 >&2
    exit 1
fi

if [ -f src/jit/x64/emit.c ]; then
    if ! cmp -s src/jit/x64/emit.c "$zig_emit"; then
        echo "check-jit-tools: emit.c differs from src/jit/x64/emit.c" >&2
        exit 1
    fi
    echo "check-jit-tools: emit.c identical to the Perl build's"
else
    echo "check-jit-tools: src/jit/x64/emit.c not present, emit.c not compared"
fi
echo "check-jit-tools: core_templates.h and tile_pattern.h match the Perl generators"
