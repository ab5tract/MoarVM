#!/bin/sh
# Report how the hash engine's exports bind inside libmoar (spec 4.7 of the
# hash tuning campaign). Usage: tools/check-lto-binding.sh path/to/libmoar.so
#
#   dynamic MVM_str_hash_ symbols            exports in the dynamic table
#                                            (expect > 0 in every build)
#   plt calls to MVM_str_hash_               calls from libmoar's own code
#                                            through the PLT (> 0 without
#                                            -Dlto, 0 with LTO and binding)
#   definitions of MVM_str_hash_fetch_nocheck  T/t entries in the symbol
#                                            tables (1 while it exists as a
#                                            function in the library; it
#                                            stays while it is exported)
#   call sites of MVM_str_hash_fetch_nocheck   calls or tail jumps to its
#                                            entry, through the PLT or
#                                            direct (5 in the current LTO
#                                            build: the lookup exports are
#                                            called, only the iteration
#                                            exports inline; see the tuning
#                                            plan, Task 9)
set -eu

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 path/to/libmoar.so" >&2
    exit 2
fi
lib=$1

dyn=$(nm -D --defined-only "$lib" | grep -c ' MVM_str_hash_' || true)
plt=$(objdump -d "$lib" | grep -c 'MVM_str_hash_[a-z_]*@plt' || true)
# A stripped library has no static symbol table, so look in both; the same
# symbol in both tables has the same line and counts once.
defs=$( { nm "$lib" 2>/dev/null || true; nm -D "$lib"; } \
    | awk '($2 == "T" || $2 == "t") && $3 == "MVM_str_hash_fetch_nocheck"' \
    | sort -u | wc -l)
# objdump names a direct target in a stripped library by its dynamic symbol
# (<name@@Base>); an offset (<name@@Base+0x..>) is a label inside it.
calls=$(objdump -d "$lib" \
    | grep -cE '(call|jmp)[^<]*<MVM_str_hash_fetch_nocheck(@plt|@@Base)?>' || true)

echo "dynamic MVM_str_hash_ symbols: $dyn"
echo "plt calls to MVM_str_hash_: $plt"
echo "definitions of MVM_str_hash_fetch_nocheck: $defs"
echo "call sites of MVM_str_hash_fetch_nocheck: $calls"
