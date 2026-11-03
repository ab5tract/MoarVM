# Hash layout strategies

The Zig hash engine (`docs/zig-build.md`, "Hash engine") can build a string
hash table with one of three layouts. The default suits nearly every hash; the
other two, LOOKUP and APPEND, are what the 2026-11-03 hash layout bake-off
found faster for some programs, and a program (or a later heuristic) picks one
per hash. The C hash engine knows only the default.

| strategy | `MVMHashStrategy` | tier set (`src/zig/core/hash/str.zig`) | layout |
|---|---|---|---|
| 0 | `MVM_HASH_STRATEGY_DEFAULT` | `standard` | Small (`tiers/small.zig`) to 64 entries, then Swiss (`tiers/swiss.zig`) |
| 1 | `MVM_HASH_STRATEGY_LOOKUP` | `swiss_only` | Swiss-style groups (`tiers/swiss.zig`) from the first entry |
| 2 | `MVM_HASH_STRATEGY_APPEND` | `ordered_only` | a dense entry array with a side index (`tiers/ordered.zig`) from the first entry |

`MVM_HASH_STRATEGY_COUNT` is 3.

## Selecting a strategy

- **C:** `MVM_str_hash_build_strategy(tc, hashtable, entry_size, entries, strategy)` (`str_hash_table_funcs.h`) builds a string table with a strategy. Strategy 0 is `MVM_str_hash_build`. A strategy the engine lacks throws "hash strategy N is not available in this engine". The C engine throws for any strategy but 0 ("hash strategies need the Zig hash engine").
- **nqp:** `nqp::hashstrategy(%h, $strategy, $size)` (the `hashstrategy` op; nqp branch `zig-hash-strategies` maps it) rebuilds an empty `MVMHash`'s table with a strategy, presized for `$size` entries, and returns `%h`.
  - It dies on a non-hash ("hashstrategy needs a concrete hash") and on a hash with entries ("hashstrategy on a non-empty hash"). A hash emptied by deletes is fine.
  - It dies on a strategy the engine lacks. A negative strategy, or one over 255, counts as 255.
  - The op is not known to the JIT, so a frame that calls it runs interpreted. Call it where the hash is made, outside hot loops.
- **Process-wide override (a diagnostic):** the `MVM_HASH_STRATEGY` environment variable, read once at startup into the instance's `hash_strategy_default`, makes every `MVMHash` and `HashAttrStore` table build with that strategy. The other tables (pointer, fixkey, index, Unicode) always use their own layout.
- **Unicode tables:** `MVM_uni_hash_build_strategy(tc, hashtable, entries, strategy)` (`uni_hash_table_funcs.h`) builds a Unicode table with strategy 0 (Robin Hood, the default) or 1 (LOOKUP, Swiss); APPEND (2) is not available for this kind and throws. The Zig engine widens the cached 32-bit hash to 64 bits (`uni.widen`) so the Swiss tag bits are filled. The four internal sites (`MVM_HASH_INTERNAL_UNI_*` in `core/hash_internal_strategies.h`) build with their real entry counts and all stay on the default: Swiss won none of the unicode benchmark cells (`traces/llm/bench/internals-uni-bench.md`).
  - Unset or empty is 0.
  - Anything other than a plain decimal number in 0..254 makes the first hash build throw, naming strategy 255.
  - It exists to run a whole test suite on one strategy (the bake-off's spectest gates), not to tune a program: no single strategy is best for every hash in a process.

The tests are `tools/bench/t/strategy.nqp` (TAP; `zig build strategy-test -Dnqp-prefix=<P>` runs it on `<P>/bin/nqp-m`) and the strategy tests in `src/zig/core/hash/test/str_test.zig` (`zig build unit-test`).

## How the numbers below were measured

The figures are from the bake-off scoreboard, recorded in `traces/llm/bench/bakeoff-scoreboard.md` (method in the plan's "## Scoreboard" section).
- The harness is `tools/bench/hash-bench.nqp`, run on nqp hashes through `tools/bench/hash-bakeoff.sh`: 7 rounds, strategy order rotated, `--runs=5 --nth=all --hint=0`.
- A ratio is the strategy's median of round medians over strategy 0's in the same rounds; below 1 is faster.
- A **win** is a ratio at or below 0.90 with disjoint round spreads. A **block** is two or more adjacent winning sizes on the ladder 16 32 63 64 65 128 256 1024 16384.
- The memory ratio is the ru_maxrss delta over strategy 0's. Below 65 entries that delta is a few pages, so small-size memory ratios are noisy; from 128 up they read as layout size.

## DEFAULT (0)

Small, then Swiss: what every hash gets unless a strategy is asked for.
Below 65 entries its Small tier is compact and fast, and no other layout beat it there. The 65th insert migrates the table into a 128-slot Swiss block (load limit 112). Until 2026-11-03 the second rung was Robin Hood; Small then Swiss was measured against it (`traces/llm/bench/internals-set0-ladder.md`) and replaced it. Strategy sets 1 and 2 are unchanged.

## LOOKUP (1)

The Swiss-style tier from the first entry. Since the default ladder moved to Small then Swiss, LOOKUP differs from the default only below 65 entries (it has no Small tier); from 65 up both are the same tier.
- **Layout:**
  - A power-of-two slot count, at least 16. One metadata byte per slot: `0x80` empty, `0xFE` deleted, else the top 7 bits of the salted hash.
  - Lookups search 16 slots at a time with a vector compare. Groups are probed at triangular offsets from the one the hash's low bits pick.
  - The load limit is 7/8, counting tombstones. A delete leaves an empty slot instead of a tombstone when its group still has one.
  - A full table doubles, or rehashes at the same size when at most 3/4 of the limit is live (tombstones filled it).
  - Iteration walks the slots downward. The block holds no pointers, so `nqp::clone` is a byte copy.
- **Blocks won** (ratio range, memory ratio range):
  - insert 128-16384: 0.78-0.86, mem 0.68-1.00
  - lookup_hit 65-256: 0.88-0.89, mem 0.68-0.73
  - lookup_miss 63-16384: 0.80-0.88, mem 0.68-2.07 (2.00-2.07 at 63-64)
  - delete 65-256: 0.88-0.89, mem 0.68-0.73
  - iterate 65-16384: 0.72-0.73, mem 0.68-1.00
  - insert_nth 65-1024: 0.02-0.87, mem 0.68-0.89 (0.02 at 65 is the 64-to-65 growth step strategy 0 pays; from 128 it is 0.83-0.87)
  - overwrite 65-16384: 0.78-0.89, mem 0.68-1.00
  - clone 65-256: 0.61-0.76, mem 0.68-0.73
  - iterate_delete 65-16384: 0.83-0.86, mem 0.68-1.00
  - all of the above at once at 128-256.
- **What it gives up:**
  - Below 65 entries it has no Small tier. Insert is 1.6-1.85x, clone 1.5-1.9x, iterate 1.1-1.16x and delete-while-iterating 1.03-1.23x, on 2.0-2.2x the memory. Lookups are level there (0.94-1.07).
  - Toward 16384 entries lookup hits and deletes fall back to level (0.93-0.99).
- **When to choose it:** a hash that will hold more than 64 entries and is used for everything (looked up, updated, iterated, cloned).
- **Composed variant:** Small then Swiss was first measured as a non-zero strategy set, where it lost five of these nine blocks and was 7-21 percent slower than strategy 0 in several 16-64 cells (`traces/llm/bench/bakeoff-composed-lookup.md`), so LOOKUP stayed the bare Swiss tier. Measured later as set 0 itself, it matched the old default in the 4-64 cells (`traces/llm/bench/internals-set0-ladder.md`) and is now the default.
- **Spectest:** `MVM_HASH_STRATEGY=1` passes rakudo's spectest with no strategy failures (`traces/llm/bench/bakeoff-spectest-s1.txt`; the scoreboard's column s1).
- **Select it:** `nqp::hashstrategy(%h, 1, $size)`, or `MVM_HASH_STRATEGY_LOOKUP` from C.

## APPEND (2)

The array-ordered tier from the first entry.
- **Layout:**
  - The entries live in a dense array in insertion order. A separate open-addressing index (linear probing, at most half full) finds them.
  - Index slots hold an entry's position plus one. They are one byte wide while the entry capacity is below 255, two below 65 535, else four; the control block records the width.
  - Insert appends. Delete moves the last entry into the hole (swap-remove) and empties the index slot by backward shift, so there are no tombstones and a full table always doubles.
  - Iteration walks the positions downward, which keeps MVMIter's "delete the current entry while holding the next" safe. The block holds no pointers.
- **Blocks won** (ratio range, memory ratio range):
  - insert 128-16384: 0.64-0.67, mem 0.34-0.58
  - iterate 65-16384: 0.66-0.75, mem 0.34-0.74
  - overwrite 65-128: 0.84-0.90, mem 0.34-0.74
  - clone 65-16384: 0.51-0.70, mem 0.34-0.74

  It is the fastest builder and the smallest table of the three from 65 entries up.
- **What it gives up:**
  - Delete is slower at every size: 1.40-1.94 up to 128 entries, 1.73 at 256, 2.04 at 1024 and 2.18 at 16384.
  - Lookups fall behind as the table grows: lookup_hit 1.12 at 1024 and 1.30 at 16384; lookup_miss 1.13 at 256, 1.28 at 1024 and 1.48 at 16384.
  - Delete-while-iterating is 1.03-1.36.
  - Below 65 entries building is slower (insert 1.25-1.37, clone up to 1.44) on 1.07-1.33x the memory.
- **Iteration order:** until its first delete an APPEND hash iterates in reverse insertion order; a delete's swap-remove moves the last entry into the hole, and from then on the order is not insertion order.
  - The order is a property of this strategy, not of hashes: nqp and Raku hashes promise no order, and a hash built with another strategy, or this one after a delete, has none.
  - Code must not rely on it.
- **When to choose it:** a hash that is built once (or mostly grown), then iterated, cloned or read, and rarely deleted from, such as a record or option set passed around and copied.
- **Spectest:** `MVM_HASH_STRATEGY=2` passes rakudo's spectest (`traces/llm/bench/bakeoff-spectest-s2.txt`; the scoreboard's column s2).
- **Select it:** `nqp::hashstrategy(%h, 2, $size)`, or `MVM_HASH_STRATEGY_APPEND` from C.

## What was measured and removed

The bake-off had a third candidate, a **fixed-key** layout (strategy 3): a hash-ordered dense array built in one step by a `hashseal` op once a hash's key set was complete. Robin Hood staged the entries until the seal, and the first insert after a seal migrated the table back to Robin Hood.
- It held one block, iterate and clone at 65-16384 (0.61-0.86).
- It never won a lookup cell (lookup_hit 1.15-1.34 and lookup_miss 1.15-1.51 except at 65).
- From 128 up it took 1.09-1.69x strategy 0's memory.
- LOOKUP and APPEND beat it on the same ops it won.

It was deleted, and the seal mechanism with it: the `hashseal` op, `MVM_str_hash_seal`, `Table.seal`, the harness's `--seal` and `bulk_load`.

The full results, including the fixed-key column, are in `traces/llm/bench/bakeoff-scoreboard.md`. The design is in `traces/llm/specs/2026-11-03-zig-hash-layout-bakeoff-design.md`, with its errata.
