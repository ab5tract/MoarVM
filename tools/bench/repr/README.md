# tools/bench/repr: the VMArray differential programs and their runner

Evidence machinery of the VMArray REPR port
(`traces/llm/specs/2026-11-16-zig-vmarray-repr-design.md`, section 7, items 2
and 3). The port has no line-by-line correspondence with
`src/6model/reprs/VMArray.c` to review, so identical behaviour rests on these
programs printing the same bytes on both builds. What the C array prints, the
coverage reached and the cases left out are recorded in
`traces/llm/bench/va-differential.md`; the control's raw outputs are in
`traces/llm/bench/va-differential-raw/`.

| File | What it is |
|---|---|
| `vmarray-diff.nqp` | The nqp half of the differential program. Twelve slot kinds with storage (OBJ, STR, I64, I32, I16, I8, U64, U32, U16, U8, N64, N32; the sized ones made with `nqp::newtype(..., 'VMArray')` and `nqp::composetype`), each through: `atpos`/`bindpos`/`push`/`pop`/`shift`/`unshift`/`setelems`/`elems`, growth through every branch of the policy and the size limit, `splice` (insert, delete, replace, from another kind, from itself), `slice`, `clone`, the multi-dimensional ops, `writeint`/`readint`/`writenum`/`readnum` at every size and endianness, every typed op with every register kind (the mismatches, and the state they leave), the integer and num boundary values, iteration, argument flattening, `join`, `existspos`. Then the six kinds without storage (4-, 2- and 1-bit element types), arrays whose type is composed a second time, the collector's view (`nqp::force_gc`), hot loops, and megamorphic subs that reach the `MVM_VMArray_at_pos_*` entry points from compiled code. About 10,000 lines of output. |
| `vmarray-diff.raku` | The Raku half: what nqp cannot reach. `nqp::atposref_*` and `nqp::multidimref_*` (native references), the atomic operations on a position (`nqp::cas_i`, `nqp::atomicload_i`, ... and the `⚛` operators on an `atomicint` array), and the arrays as Rakudo uses them: `array[int8]` to `array[uint64]`, `array[num32]`, `array[num64]`, `array[str]`, `buf8` to `buf64`, `blob8` to `blob64` (with every `read-*`/`write-*` method), and the reified `IterationBuffer` inside an `Array`. About 2,500 lines. |
| `vmarray-serial.nqp` | The serialization record: one serialization context per case, an empty, a 3-element, a shifted and a 10,000-element array of each of 16 kinds, printed as hex (`<case>.blob`), with the string heap (`<case>.strings`) and the array as deserialized in the same process (`<case>.roundtrip`). `--read=FILE` deserializes the blobs in another run's output and prints `<case>.read` lines; `sed -n 's/\.roundtrip: /.read: /p' FILE` is what a correct reader prints. |
| `vmarray-devirt.nqp` | Ten lines of output for one purpose: the "Index out of bounds" errors of `vmarray_at_pos_int64` and `vmarray_bind_pos_int64`, the two functions the JIT calls directly. Only this program's shape was found to reach them (see its header); do not reshape it without measuring again. |
| `undefined-lines.txt` | The 195 output lines (`<program> <case name>`) whose value in C is what `memcpy` over overlapping ranges leaves: self-splices of the eleven kinds copied with `memcpy`. Its header says how the list was derived. `diff.sh` reads it for exit 3. |
| `diff.sh` | The runner: each program K times (default 3) per side and per spesh setting, repeatability of each side, base against head, and the serialization cross-read (each side deserializes what the other serialized). Exit 0 identical, 1 base and head differ (first differing line named), 2 a side is not repeatable, 3 base and head differ only in lines listed in `undefined-lines.txt` (every such line printed with both values), 4 a run failed, wrote to stderr or a side did not load the libmoar under its prefix, 64 misuse (including prefixes of unequal length). The caller's `MVM_*`, `RAKUDO_*`, `NQP_*`, `RAKU_*`, `PERL6*` variables and `RAKULIB` are removed from the runs. `--compare-only --out=DIR` repeats the checks on outputs already there. `--help` prints the details. |

Every output line is `<case name>: <result>`; a caught exception prints
`<case name>: DIED <message>`. The case name says which kind and which
operation; a differing line therefore names what to look at. Nothing printed
varies from run to run: no addresses, no object ids, no hash order, no
timings.

## Running

    tools/bench/repr/diff.sh --base=/tmp/claude-1000/va-c-base \
        --head=/tmp/claude-1000/va-n-base --out=<fresh directory>

A side is chosen by `LD_LIBRARY_PATH=<prefix>/lib`; the nqp programs run
through `/tmp/claude-1000/tune-zig-prefix/bin/nqp-m` and the Raku one through
the in-tree `rakudo-m` with `RAKUDO_NO_PRECOMPILATION=1` (`--nqp=`,
`--rakudo=` override). The two settings are `spesh` (`MVM_SPESH_DISABLE`
unset, `MVM_SPESH_BLOCKING=1`) and `nospesh` (`MVM_SPESH_DISABLE=1`).
`MVM_SPESH_BLOCKING=1` makes the program wait for the specializer, so that
which code runs specialized and compiled is the same every run; the control's
output was also the same without it. A full run of the control against itself
takes a little over three minutes (189 s as recorded).

One program by hand:

    LD_LIBRARY_PATH=<prefix>/lib /tmp/claude-1000/tune-zig-prefix/bin/nqp-m \
        tools/bench/repr/vmarray-diff.nqp > out.txt

## What a difference can mean

- A `DIED` message that differs, or a `DIED` where the control has a value:
  an exception path. The messages are the C array's and must be byte
  identical; roast matches on some.
- `*.kind.*.state` lines: what a rejected operation leaves behind (the C
  array grows before it checks the register kind in `push` and `bindpos`,
  decrements `elems` before it checks in `pop`, moves `start` before it
  checks in `unshift`). These are per-kind accidents the port keeps.
- `*.selfsplice.*`, `*.splice.self*` and `array.reified.splice`: a splice from
  the array itself. For the kinds copied with `memcpy` the C passes
  overlapping ranges, which is undefined; the control prints what its `memcpy`
  leaves, which is neither a forward nor a backward copy for some cases
  (`va-differential.md` lists them). STR arrays, and OBJ arrays that have been
  promoted, are copied element by element and print a forward copy. The
  decision taken: the Zig array copies overlapping ranges with memmove
  semantics, so it is expected to differ from the control in exactly the
  lines of `undefined-lines.txt`. `diff.sh` then exits 3, not 0: that result
  is recorded with the lines it printed and put to the user, never passed as
  "identical". A difference in any other line is exit 1.
- `*.limit.*`: the message carries the slot count the growth policy computed,
  so a different number is a different policy.
- `*.mega.*` lines list every distinct result a megamorphic sub gave, in
  order of first appearance: with spesh the interpreter's message first, then
  the message of the `MVM_VMArray_at_pos_s`/`_o` entry point compiled code
  calls. They differ between the two settings by design.

## Left out on purpose

The C array crashes, aborts or reads memory it does not own in these places,
so no case goes there (the reasons are in `va-differential.md`): `setelems`
of 2**64 - 4096 or more on an array with 8,192 or more slots of storage; a
size request that is under the limit but cannot be allocated; a splice from a
non-empty object that is not a VMArray; a splice that copies elements into an
array of a kind without storage; a cross-kind splice between a reference kind
and a numeric kind; growing an OBJ or STR array back over the slot a rejected
`pop` left behind; a `read_buf` the bounds check lets through that lies
beyond the storage; `writeint` on a recomposed array without storage.
