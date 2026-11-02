# Zig hash engine: a tiered string-keyed table and the generic base for the other four

**Date:** 2026-11-02
**Status:** draft, awaiting builder check and user approval
**Builds on:** Zig port step zero (`docs/superpowers/specs/2026-11-02-zig-port-step0-design.md`, branch `zig-port-step0`): the `[zig]` section of `build/sources.list`, the translate-c `moar` module and its shims, `-Dzig-impl` and `--zig=PATH`. Appendix A of that spec, items 1 and 2, is the origin of this one.

## 1. Intent

MoarVM has five hand-specialised copies of one Robin Hood hash table (string,
pointer, fixkey, index and Unicode keys), and every hash a Raku program makes
pays the full price of that design: metadata bytes, probe bookkeeping and a
per-table salt on every access, although most Raku hashes never hold more
than a few dozen keys (named-argument captures, attribute stores, lexical name
tables, method caches).

The goal is a hash whose implementation scales with its size: the normal
instance, below a threshold on the order of 64 entries, is simple and flat,
and as a hash grows it is moved into more capable implementations. Which
implementation serves which size range is a *tier set*, a compile-time ladder.
This first campaign ships a two-rung ladder for the string-keyed table (a flat
small tier and the existing Robin Hood algorithm) and the interfaces that let
later campaigns add rungs that differ by probing strategy, memory layout and
hash function, and later still let Rakudo pre-allocate a hash by naming a tier
set. The four other tables are ported onto the same generic base unchanged in
behaviour, each a later campaign's starting point.

Success is measured, not argued: a bespoke benchmark reports small-hash and
large-hash speed against the C engine separately, and spectest time is the
whole-system check.

## 2. Decisions

Taken in the brainstorm (2026-11-02); the plan does not re-litigate them.

1. **Only the string-keyed table scales in this campaign.** The pointer,
   fixkey, index and Unicode tables are ported onto the generic base as
   single-rung sets that reproduce their current algorithms. Each gets its own
   later campaign to find its best algorithm.
2. **Two rungs now: Small, then Robin Hood.** More tiers come later and differ
   by probing strategy, memory layout and hash function. The tier boundary is
   a real interface from day one so that adding a rung is a new module, not
   surgery on an existing one.
3. **Migration is upward only.** A hash never steps down a rung when it
   shrinks.
4. **Tier sets are compile-time.** A tier set is an ordered list of (tier,
   entry-count threshold) such as `[Small(0), RobinHood(256)]`, possibly
   extended later as `[Small(0), RobinHood(256), SipHashTier(64_000)]`. Users
   cannot define sets from Raku. A VM-level construction hint names a set; the
   Raku syntax for that is a later project.
5. **Each tier set entry carries a `double_write` flag, reserved.** When a
   later campaign implements it, a rung with the flag keeps the next rung's
   table warm through a non-blocking write log drained off the main write
   path (eventual consistency), so migration becomes a pointer swap, trading
   memory for latency. This spec reserves the field and the log hook only;
   the hook is a no-op.
6. **The C APIs do not change.** Every exported and inline function of the
   five tables keeps its name and signature, so the fourteen files that use the
   string table and all users of the other four are untouched.
7. **The C implementation stays selectable** through step zero's mechanism:
   a build without the Zig groups compiles exactly the C it compiles today.
8. **Large hashes may be slower in this campaign.** The growth corridors are
   future campaigns' work. The benchmark must say by how much, in both
   directions, and the expectation to verify is that the small-hash gain
   outweighs the large-hash cost.
9. **Benchmarks come in two forms**, a C microbenchmark against libmoar and a
   Raku script, both sweeping a size ladder that straddles the threshold
   (including sizes such as 128 that cross it only slightly).

## 3. Verified facts about the current tables

From a read of the C on branch `zig-port-step0` (line numbers as of
`c22ec7d86`). The design relies on these.

### 3.1 API surface

Out-of-line in `src/core/str_hash_table.c`: `MVM_str_hash_build(tc, ht,
entry_size, entries)`, `MVM_str_hash_demolish`, `MVM_str_hash_lvalue_fetch_nocheck`,
`MVM_str_hash_insert_nocheck` (throws on a duplicate key),
`MVM_str_hash_delete_nocheck`, `MVM_str_hash_fsck`, `MVM_round_up_log_base2`.

Inline in `src/core/str_hash_table.h`: `MVM_str_hash_at_end` (`pos == 0`;
`MVMIter.h` needs it inline). Inline in `src/core/str_hash_table_funcs.h`:
`MVM_hash_round_size_up`, `allocated_size`, `is_empty`, `shallow_copy`,
`count`, `entry_size` (0 when unbuilt), `fetch_nocheck`, `key_is_valid`,
`key_throw_invalid`, `lvalue_fetch`, `fetch`, `delete`, `next_nocheck`,
`next`, `first`, `start`, `at_start`, `current_nocheck`, `current`, the
private helpers, `MVM_str_hash_code(tc, salt, key)`, and
`struct MVM_hash_loop_state`.

Call sites outside the table's own files (grep counts): `at_end` 19,
`current_nocheck` 17, `first` 16, `next_nocheck` 15, `key_is_valid` 14,
`key_throw_invalid` 14, `count` 9, `build` 8, `entry_size` 7,
`lvalue_fetch_nocheck` 4, `fetch` 4, `demolish` 4, `insert_nocheck` 3,
`fetch_nocheck` 3, `lvalue_fetch` 2, `at_start` 2, `allocated_size` 2,
`start` 1, `shallow_copy` 1, `next` 1, `delete_nocheck` 1, `delete` 1.
`is_empty`, `current`, `fsck` and `code` have no external callers.

Users: `src/6model/reprs/MVMHash.c`, `HashAttrStore.c`, `MVMIter.c`/`.h`,
`src/debug/debugserver.c`, `src/gc/roots.c`, `src/core/bytecode.c`,
`src/core/nativecall_libffi.c`, `nativecall_dyncall.c`, `src/core/args.c`,
`src/6model/sc.c`, `SCRef.c`, `MVMStaticFrame.c`, `src/moar.c`,
`src/core/threadcontext.c`. Tables embedded in structs: `MVMHashBody`,
`MVMHashAttrStoreBody`, `instance->sc_weakhash`,
`tc->native_callback_cache`, `MVMStaticFrameInstrumentation.debug_locals`.

The other four tables import from the string table's files:
`MVM_hash_round_size_up`, `MVM_round_up_log_base2`,
`struct MVM_hash_loop_state`, and `MVM_str_hash_key_is_valid`
(`index_hash_table_funcs.h:165`; also used as a generic "concrete string"
check in dll.c, hll.c, ext.c, loadbytecode.c, containers.c, reprs.c).

### 3.2 Layout and lifetime

- The public struct is one pointer: `MVMStrHashTable { MVMStrHashTableControl *table; }`.
  NULL means unbuilt; an all-zero body is a valid state (repossession
  `memset`s bodies, `serialization.c:3054`). `entry_size() == 0` is the
  "unbuilt" test used by callers. `first`, `count`, `is_empty` accept NULL.
- One `MVM_malloc` block per table (not the FSA): entries before the control
  struct in descending order (bucket i at `control - entry_size*(i+1)`),
  the control struct, then metadata bytes rounded to `sizeof(long)`.
- Entry size is declared by the caller at build: non-zero, at most 255, a
  multiple of 4, stored as u8. Every entry begins with
  `MVMStrHashHandle { MVMString *key; }`; the key is NULL in a fresh lvalue
  entry. All four caller entry types are 16 bytes on 64-bit.
- Growth allocates a new block, reinserts by memcpy, marks the old block
  `stale = 1`, frees it with `MVM_free_at_safepoint`, publishes the new
  pointer with `MVM_trycas` (a lost race is `MVM_oops`). Entries also move
  within a block on insert (make room) and on delete (backward shift).
- No caller keeps an entry pointer across a second insert, except
  `nativecall_{libffi,dyncall}.c` which hold `&entry->head` across code that
  can run a GC but never inserts into that table meanwhile. Table memory is
  never moved by the GC.
- `sizeof(MVMHash)` reaches spesh as an i16 (`MVMHash.c:250`); nothing in
  spesh, the JIT or dispatch depends on table internals.

### 3.3 Iteration

- `MVMStrHashIterator { MVMuint32 pos; }` is a plain value stored by value in
  GC objects (`MVMIterBody.hash_state.{curr,next}`). `at_end` is `pos == 0`;
  `start` is a before-first position, `at_start` tests it; `current` returns
  NULL at the end (de-facto API).
- The walk is in descending bucket order. Deleting the current entry while
  holding the next position is supported and used: delete back-shifts only
  higher-indexed, already visited entries. `MVMIter` advances `next` early to
  exploit this. Deleting another key or inserting during iteration is not
  supported; growth invalidates iterators; `lvalue_fetch` of an existing key
  deliberately never grows.
- No caller depends on order semantically; `args.c:136-160` sorts named args
  by cached hash code because order is random; serialization sorts keys.
- `copy_to` in `MVMHash.c:46` advances the source iterator while reading the
  destination, which works only because `shallow_copy` preserves layout
  exactly.

### 3.4 Randomisation

- Per process: `instance->hashSeed` (from `MVM_getrandom` under
  `MVM_HASH_RANDOMIZE`, else `RAPID_SEED`) seeds `MVM_string_compute_hash_code`
  (rapidhash over graphemes), cached in `MVMString.body.cached_hash_code`.
- Per table: `salt = MVM_proc_rand_i(tc)` at every allocation (empty build,
  every `hash_allocate_common`, so every resize); bucket hash is
  `(hash ^ salt) * 11400714819323198485`, top bits. `MVM_proc_rand_i` reads
  `tc->rand_state`, the same state `nqp::srand`/`nqp::rand_i` use, so every
  hash creation and resize advances the user-visible random sequence.
- `shallow_copy` keeps the salt. There is no runtime deterministic-order mode;
  `MVM_HASH_RANDOMIZE` is compile-time.

### 3.5 GC and serialization

- `MVMHash_gc_mark` presizes the worklist to 2*count and pushes the addresses
  of the key and value slots inside entries; the GC rewrites keys in place.
  Entries must not move between mark and drain (no mutation during GC). Other
  mark sites: `HashAttrStore.c:46-58`, `roots.c:104-119` (sc_weakhash),
  `roots.c:190-208` (native_callback_cache), `MVMStaticFrame.c:163-168`.
- `gc_free` demolishes; a full block is freed at a safepoint (one malloc per
  freed hash, `alloc.h:80-88`); a control-only table uses plain free.
  `SCRef`'s `gc_free` deletes from `sc_weakhash` under a mutex during the
  sweep.
- `MVMHash` serialize sorts keys with `MVM_string_compare` and writes pairs
  in that order; deserialize does `build(elems)` then `insert_nocheck` per
  entry and `MVM_oops`es if the table is already built. Nothing depends on
  hash order within or across processes.

### 3.6 Growth and hints

- Minimum size 2^3 official + 5 overflow slots; load factor 0.75 for all
  tables; max probe distance 255; starting metadata hash bits 5 (probe
  distance 7); on growth the table first trades a hash bit for probe distance
  in place, else doubles (which can cascade). `MVMHashNumItems` is u32.
- `MVM_str_hash_build(tc, ht, entry_size, entries)` already takes an expected
  count (allocates for `entries/0.75` rounded up to a power of two, minimum
  8; 0 means control-only). Callers passing a count: deserialize (`elems`),
  `HashAttrStore` clone, `bytecode.c:777` (`num_debug_locals`); the other
  five pass 0. No nqp op or REPR path presizes a hash.

### 3.7 Threading and debug hooks

- No internal locks. The `stale` flag is checked on entry and exit of almost
  every call; the debugserver reads tables owned by other threads with its own
  thread context, so hashing and salts must not be thread-local. Shared tables
  are guarded externally (`mutex_sc_registry`, `mutex_hll_syms`).
- `HASH_DEBUG_ITER` code in `MVMIter.c`/`.h` reads `control->ht_id` and
  `control->serial` directly. `MVM_str_hash_fsck` has no external callers.
- Key equality is pointer equality, then grapheme count, then
  `MVM_string_substrings_equal_nocheck`; the full hash code is deliberately
  not compared.
- `MVMHash.describe_refs` is NULL; heap snapshots go through `gc_mark`;
  `unmanaged_size` uses `allocated_size`.

## 4. Architecture

```
src/zig/core/hash/
  table.zig        generic base: Table(comptime Spec) with the policy layer
  tier.zig         the tier interface, TierSet, TierEntry, the log hook
  tiers/small.zig  Small tier (flat, tags, vector compare)
  tiers/robinhood.zig  Robin Hood tier (port of the C algorithm)
  str.zig          replaces src/core/str_hash_table.c: exports the C API
  ptr.zig          replaces src/core/ptr_hash_table.c
  fixkey.zig       replaces src/core/fixkey_hash_table.c
  index.zig        replaces src/core/index_hash_table.c
  uni.zig          replaces src/core/uni_hash_table.c
  bench.zig        the C-API microbenchmark driver (see §10)
```

Three layers:

1. **Tiers** implement one storage scheme each behind the tier interface
   (§5). They know nothing about each other.
2. **The policy layer** in `table.zig` owns the control block header, the
   tier set, growth and migration, the stale/CAS/free-at-safepoint
   discipline, iteration dispatch and the reserved double-write log hook.
3. **The C API files** (`str.zig` and the four others) translate the exact
   C signatures into calls on a `Table` instance and own anything C-specific
   (the `MVM_oops` texts, `MVM_exception_throw_adhoc` for invalid keys, the
   `MVMThreadContext` plumbing).

Implementation files `@import("moar")` only, as step zero requires.

### 4.1 The generic base

`Table(comptime Spec: type)` where `Spec` provides:

- `Key`: the key type stored at the start of every entry (`[*c]MVMString`,
  `?*anyopaque`, an index, `[*c]const u8`).
- `hash(ctx, key) u64` and `eql(ctx, a, b) bool` as comptime functions;
  `ctx` is whatever the C API passes (`tc`, the index table's string list).
- `runtime_entry_size: bool`: true for the string, pointer and fixkey tables
  (entry size declared at build, stored as u8), false where the entry type is
  fixed.
- `set: TierSet`: the ladder (§4.3).

The base exposes: `build(ctx, entry_size, expected_count, set_index)`,
`demolish`, `fetch`, `lvalueFetch`, `insert`, `delete`, `count`,
`entrySize`, `allocatedSize`, `shallowCopy`, `isEmpty`, and iteration as
`first`, `next`, `start`, `atStart`, `current`, plus `fsck`. The exact Zig
signatures are the builder's.

### 4.2 The control block

One `MVM_malloc` block per table, as today, so that `MVMStrHashTable` stays
one pointer, `sizeof(MVMHash)` is unchanged, `shallow_copy` is a block copy
that preserves layout, and `MVM_free_at_safepoint` keeps working. The block
begins with a header common to all tiers:

```
tier:        u8   rung index within the set
set:         u8   index into the comptime list of tier sets
entry_size:  u8   as today (0 is never stored; unbuilt is a NULL pointer)
stale:       u8   volatile, as today
cur_items:   u32
```

followed by the tier's own payload (the tier decides where its entries,
tags or metadata live relative to the header; the Robin Hood tier may keep
the C layout with entries before the header). Position of the header within
the block is the tier's choice; the policy layer reaches it through a tier
function, so "control pointer" means "pointer to wherever this tier keeps the
header". The control-only state (built with 0 entries) is a header alone with
`cur_items == 0` and a tier payload that reports zero capacity; the first
insert allocates the first rung.

The control block is opaque to C (§7); the HASH_DEBUG_ITER fields are not
provided (§8).

### 4.3 Tier sets

```zig
pub const TierEntry = struct {
    tier: type,          // a tier module
    from: u32,           // entry count at which this rung takes over
    double_write: bool = false,   // reserved, see decision 5
};
pub const TierSet = []const TierEntry;
```

Rules: the first entry's `from` is 0; `from` values strictly increase; each
tier's capacity scheme must be able to hold up to the next rung's `from`
entries (checked at comptime). The standard string set is

```zig
pub const standard = [_]TierEntry{
    .{ .tier = Small, .from = 0 },
    .{ .tier = RobinHood, .from = small_threshold },
};
```

with `small_threshold` a single comptime constant chosen by the spike (§9),
candidates 64, 128 and 256. All tier sets live in one comptime list,
indexed by the `set` byte in the header; this campaign defines two for the
string table, `standard` and `large_only = [RobinHood(0)]`, the latter
being what a future "pre-allocate big" hint selects. The four other tables
each have one single-rung set.

**Hints.** `build(ctx, entry_size, expected_count, set_index)` picks the
starting rung as the last entry of the set whose `from` is at most
`expected_count`, and sizes that rung for `expected_count`. The C
`MVM_str_hash_build(tc, ht, entry_size, entries)` calls it with the standard
set, so deserialize and clone land directly in Robin Hood when `entries`
exceeds the threshold, exactly as they land in a presized table today. A
future nqp op that names a set is a one-line addition in `str.zig`.

### 4.4 Growth and migration

On an insert that the current rung reports as full, the policy layer:

1. If the current rung can grow within itself (Robin Hood doubling or its
   metadata-bit trade), does that, as today.
2. Otherwise, if a next rung exists and `cur_items + 1 >= next.from`,
   migrates: allocates the next rung sized for `2 * cur_items` (what a resize
   does today), drains every entry of the old rung through the tier interface
   into the new one (entry bytes copied verbatim, keys rehashed by the new
   tier), then publishes.
3. Publication is today's discipline: mark the old block `stale = 1`, free it
   with `MVM_free_at_safepoint`, `MVM_trycas` the new pointer, `MVM_oops` on a
   lost race.

The Small rung never grows within itself: it has exactly `small_threshold`
slots, so its first "full" is the migration. Migration is upward only;
deletes never change rung. The reserved log hook is called by the policy
layer on every insert and delete with the entry and the operation, and is a
comptime no-op in this campaign.

Growth invalidates iterators, as today. `lvalueFetch` of an existing key
never grows or migrates, as today.

## 5. The tier interface

Every tier module provides, with `Header` the §4.2 header type and `Entry`
an opaque byte range of `entry_size` beginning with the key:

- `init(allocator, header_init, capacity) !*Header`: allocate one block able
  to hold `capacity` entries (the tier rounds up as it likes) and return the
  header.
- `deinit(header)`: nothing but returning the block to the policy layer,
  which frees it (the tier owns no other memory).
- `capacity(header) u32` and `isFull(header) bool` (full means the next
  insert needs growth or migration).
- `hash(ctx, key) u64`: the tier's own hash of a key. Small and Robin Hood
  both return the string's cached hash code; a future tier may compute its
  own, which is why migration rehashes.
- `fetch(header, ctx, key, h) ?*Entry`.
- `lvalueFetch(header, ctx, key, h) union { found: *Entry, inserted: *Entry, full }`:
  find or create; `inserted` entries have a NULL key for the caller to fill,
  as today; `full` is returned instead of inserting when `isFull`.
- `delete(header, ctx, key, h) bool`.
- `grow(header, allocator) ?*Header`: in-place or reallocated growth within
  the rung, or null if the rung cannot grow (Small). Robin Hood implements
  the metadata-bit trade and doubling here.
- Iteration by position: `first(header) u32`, `next(header, pos) u32`,
  `entryAt(header, pos) *Entry`, `start(header) u32`. Positions are
  `u32`, `0` means end, and the walk visits positions in strictly decreasing
  numeric order. **Invariant every tier must keep:** deleting the entry at
  the current position leaves every lower position's entry in place, so a
  caller holding the next position continues correctly. (Small satisfies
  this by filling the hole from the highest occupied slot, which has already
  been visited; Robin Hood by its backward shift.)
- `drain(header, visitor)`: visit every entry once, for migration and
  `shallowCopy`-independent uses.
- `allocatedSize(header) usize` and `fsck(header, ctx, mode) u64`.

The policy layer, not the tier, owns `cur_items` and the `stale` checks.

## 6. The tiers in this campaign

### 6.1 Small

Fixed capacity `small_threshold` entries. Block: header, a tag array of
`small_threshold` bytes, then entries. Tag of an entry is the top byte of its
hash code (cached rapidhash of the string). Lookup: splat the key's tag
across a `@Vector(small_threshold, u8)` (or chunks of 32 when the threshold
exceeds what the target vectorises well; the builder decides, measured),
compare against the tag array for a candidate bitmask, then for each
candidate the C equality (pointer, grapheme count, substrings). Insert
appends at index `cur_items`. Delete moves the entry and tag at index
`cur_items - 1` into the hole. Iteration position of index `i` is `i + 1`;
`first` returns `cur_items`; `next` returns `pos - 1`; `start` returns
`cur_items + 1`. No salt, no probe distances, no metadata.

Observable: Small iterates in insertion order (with swap-remove
perturbations after deletes). The language allows any order; this is stated
here because tests that accidentally depended on randomness will now see
stability for small hashes.

### 6.2 Robin Hood

A faithful port of today's algorithm: entries below the header in descending
order, metadata bytes after it, probe distance in the high bits and extra
hash bits in the low bits of each metadata byte, starting at 5 hash bits,
the in-place bit trade, doubling with reinsertion, the delete backward
shift, load factor 0.75, minimum 8 official slots, probe limit table as in
`str_hash_table.c:57-109`. Bucket hash `(h ^ salt) * 11400714819323198485`
with the top bits, as today. This keeps the measured large-hash change
attributable to the call boundary (§7) and the policy dispatch, not to a new
algorithm; later campaigns may replace it.

**Salt source changes.** The salt is drawn from an engine RNG kept on the
instance and seeded from `hashSeed`, not from `tc->rand_state`, so hash
creation and resizes no longer advance the user-visible `nqp::rand`
sequence. Observable: programs that seed with `nqp::srand` and then create
or grow hashes see a different `rand` sequence than today. The per-process
`hashSeed` and the cached string hash codes are untouched.

## 7. Build integration and the headers

**`[zig]` lines.** `build/sources.list` gains five lines, one per table, each
replacing its C file. They are on or off together with every other Zig
group (step zero's switch is global).

**The define.** Most of the string table's API is inline C in its headers,
which the file swap cannot replace. When the Zig groups are on, `config.h`
defines `MVM_ZIG_IMPL 1` (both builds: `build/config.h.in` gets
`#define MVM_ZIG_IMPL @zig_impl@` rendered as `1` or left undefined; the zig
build's config renderer does the same from `-Dzig-impl`). Under
`MVM_ZIG_IMPL`:

- `str_hash_table.h` keeps the public structs (`MVMStrHashTable`,
  `MVMStrHashIterator`, `MVMStrHashHandle`), keeps `MVM_str_hash_at_end`
  inline (the `pos == 0` convention is part of the tier interface), and
  declares `MVMStrHashTableControl` as an incomplete type.
- `str_hash_table_funcs.h` declares every function of §3.1 as an extern
  function with its current signature, implemented in `str.zig`, instead of
  defining it inline. The pure helpers that the other four tables and other
  files use (`MVM_hash_round_size_up`, `MVM_round_up_log_base2`'s
  declaration, `struct MVM_hash_loop_state`, `MVM_str_hash_key_is_valid`,
  `MVM_str_hash_key_throw_invalid`) stay as they are, so nothing outside the
  tables notices.
- The same treatment for the four other tables' `*_funcs.h` headers.

Without `MVM_ZIG_IMPL` the headers are byte-for-byte today's. The cost of a
real call where today there is inlined code is deliberate and is what the
microbenchmark measures.

`HASH_DEBUG_ITER` with `MVM_ZIG_IMPL` is a compile error (`#error` in
`str_hash_table.h`): the Zig engine does not provide `ht_id`/`serial`.

## 8. Preserved guarantees

The plan's tests must cover each of these against the Zig engine:

1. The unbuilt state: NULL control pointer; `entry_size`, `count`,
   `is_empty`, `first` accept it; a `memset(0)` body reads as unbuilt;
   `build` on a built table is `MVM_oops` in deserialize's hands as today.
2. Control-only state from `build(..., 0)`; first insert allocates.
3. Entry pointers returned by `lvalue_fetch` stay valid until the next
   insert into that table; the nativecall pattern (hold `&entry->head`
   across a GC with no intervening insert) keeps working because the GC never
   moves table memory.
4. Iteration: descending positions, `0` is end, `start`/`at_start`
   semantics, `current` NULL at end, delete-current-while-holding-next in
   both rungs, `lvalue_fetch` of an existing key never grows or migrates.
5. `shallow_copy` produces an identical layout (block copy), so
   `MVMHash.copy_to`'s cross-iterator use keeps working, and a clone iterates
   in the same order as its source.
6. GC: `gc_mark` pushes slot addresses; entries do not move during a
   collection; demolish frees full blocks at a safepoint and control-only
   blocks immediately.
7. Threading: stale checks on entry and exit, CAS publication, no thread-local
   state (the debugserver reads other threads' tables).
8. `insert_nocheck` on a duplicate key throws the same text; invalid keys
   throw through `key_throw_invalid`.
9. Serialization round-trips: deserialize's `build(elems)` plus
   `insert_nocheck` per key lands in the right rung and round-trips a
   precompiled module (stage0 and a `.moarvm` with hashes above the
   threshold).
10. `allocated_size` reports the block size for `unmanaged_size`.

## 9. The spike: a size histogram

Before the threshold is fixed, instrument the C engine: a histogram of final
entry counts per table at demolish (bucketed 0, 1-4, 5-16, 17-64, 65-128,
129-256, 257-1024, 1025+), separately for the string table's callers
(`MVMHash`, `HashAttrStore`, others), printed at instance exit under an
environment variable, hook points `hash_allocate_common`,
`hash_demolish_internal` and the control-only build. Run the rakudo
spectest once and the rakudo build once, record the histograms in the plan,
and choose `small_threshold` from them. The instrumentation is throwaway
(a scratch branch or a patch kept under `tools/`), not merged.

## 10. Benchmarks

Both harnesses sweep the same size ladder: 4, 16, 32, `small_threshold - 1`,
`small_threshold`, `small_threshold + 1`, 128, 256, 1024, 16384, 65536,
1048576 (ladder entries equal to the threshold collapse). Both report, per
size and operation, nanoseconds per operation for the C engine and the Zig
engine and the ratio, for: insert of N fresh keys, lookup hit, lookup miss,
delete of all keys, full iteration, and for sizes just above the threshold
the cost of the N-th insert alone (the migration). Three runs, median.

1. **C-API microbenchmark**: `src/zig/core/hash/bench.zig`, a `zig build
   hash-bench` step that builds an executable linked against the shared
   libmoar (as the shim tests are), creates an instance, builds tables through
   `MVM_str_hash_*` with 16-byte entries and distinct interned `MVMString`
   keys, and times the operations above. It runs against whichever libmoar
   was built (`-Dzig-impl=true` or `false`), so one run per engine.
2. **Raku script**: `tools/bench/hash-bench.raku`, the same ladder and
   operations on a `Hash` (`%h{$k} = $v`, `%h{$k}:exists`, `%h{$k}:delete`,
   `for %h.kv`), timed with `now`, run with two `moar`s (`--zig` and plain
   Perl builds, or the two zig builds).
3. **Spectest**: wall time of `make spectest` (rakudo built against each
   engine), three runs each, in the plan's report.

The plan records all three tables in its deviations section and in
`docs/zig-build.md`. The acceptance numbers are the ratios at sizes below
the threshold (expected below 1) and above (expected above 1 and recorded).

## 11. The other four tables

Each is ported onto `Table(Spec)` with a single-rung set that reproduces its
current algorithm and API (§3.1): pointer keys (`ptr_hash_table`, with
`fetch_and_delete`, no iterator), fixkey (no capacity hint, no delete,
`foreach`, entries are pointers to stable structs), index (keys are indices
into a `MVMString **` list, no salt), Unicode (C string keys, no salt).
Behaviour, including the absence of salts where there is none today, is
unchanged. These ports come after the string table and are verified by the
stage0 smoke test, `zig build test` and the rakudo build, since they have no
Raku-visible surface of their own.

## 12. Acceptance criteria

1. `zig build install && zig build test` and `zig build unit-test` pass with
   the Zig groups on; `nm -D` on libmoar lists `MVM_str_hash_build` and
   `MVM_fixkey_hash_build` as defined by the Zig object; no C hash table
   file is compiled.
2. The same with `-Dzig-impl=false`, compiling all five C files.
3. `perl Configure.pl --zig=/usr/bin/zig && make && make install` and the
   stage0 smoke test pass; `perl Configure.pl && make` compiles the C tables
   and has no `MVM_ZIG_IMPL` in `src/gen/config.h`.
4. nqp and rakudo build on the Zig engine and the rakudo spectest passes with
   no new failures against the C-engine baseline.
5. The §8 guarantees are covered by unit tests in `zig build unit-test`
   (shim-test style, against a real instance).
6. Both benchmarks exist, run against both engines, and their tables plus the
   spectest timings are recorded.
7. `zig fmt --check`, `perl -c Configure.pl` clean.

## 13. Observable changes

- Small-mode iteration order is insertion order (perturbed by deletes).
- Hash creation and growth no longer consume the user-visible RNG.
- `HASH_DEBUG_ITER` is unavailable with the Zig engine.
- Large hashes may be slower by the measured ratio.

## 14. Out of scope

- Implementing double-write (field and hook only).
- Demotion to a lower rung.
- Any Raku or nqp syntax or op for tier sets or pre-allocation.
- Additional tiers (SipHash, other probing or layouts) and the per-table
  campaigns for the pointer, fixkey, index and Unicode tables.
- Changing `MVMHash`, `HashAttrStore`, `MVMIter` or any caller.
- Making `HASH_DEBUG_ITER` work with the Zig engine.
- Non-Linux targets (phase 5 of the build migration).

## 15. Left to the builder

- Exact Zig generics and signatures for `Table`, `Spec` and the tier
  interface, as long as §5's operations and invariants hold.
- Block layouts of each tier, the vector width strategy in Small, and
  whether the Small tag uses 8 or 7 bits.
- How `drain` and `shallowCopy` are implemented per tier.
- Depth of `fsck` for each tier.
- The engine RNG's algorithm (anything seeded from `hashSeed` with
  instance-level state and no locks beyond what `MVM_proc_rand_i` has).
- Benchmark harness details beyond §10, including how keys are generated
  and interned.
- Task order in the plan, except that the spike precedes fixing the
  threshold and the string table precedes the other four.
