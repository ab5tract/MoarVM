# Zig Hash Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MoarVM's five C hash tables with one generic Zig table behind the unchanged C APIs, give the string-keyed table a two-rung tier set (flat Small, then Robin Hood) with compile-time tier sets, and measure it against the C engine.

**Architecture:** `src/zig/core/hash/table.zig` is the policy layer (`Table(Spec)`: control-block header, tier sets, growth, migration, publication, iteration dispatch, reserved log hook) over tier modules that implement one storage scheme each (`tiers/small.zig`, `tiers/robinhood.zig`) behind the §5 interface of the spec. `str.zig` instantiates it for `MVMString` keys and `str_exports.zig` exports the exact C symbols; the other four tables follow the same pattern as single-rung sets. Both builds define `MVM_ZIG_IMPL` in `config.h` when the Zig groups are on, and the tables' headers switch from inline bodies to extern declarations under it.

**Tech Stack:** Zig 0.16.0 (`/usr/bin/zig`, std at `/usr/lib/zig/std`), the step-zero `moar` module (`src/zig/moar.zig`, translate-c of `src/moar.h`), Perl 5 `Configure.pl` and `build/Makefile.in`, GNU make, nqp and rakudo (nested checkouts at `../` and `../../`).

**Spec:** `docs/superpowers/specs/2026-11-02-zig-hash-engine-design.md` (§2 decisions, §3 verified facts with file:line, §4-§6 design, §7 build, §8 guarantees, §9 spike, §10 benchmarks, §12 acceptance). Builds on `docs/superpowers/specs/2026-11-02-zig-port-step0-design.md`.

## Global Constraints

- Repo root for all paths: `/home/longwalker/code/raku/x.core/zmoarz/rakudo/nqp/MoarVM`, branch `zig-hash-engine` (cut from `zig-port-step0`). nqp is `../`, rakudo is `../../`, nqp's stage0 is `../src/vm/moar/stage0`.
- Never use `@cImport`; implementation files `@import("moar")` only; `src/zig/moar.zig` is the only file that names the `c` module.
- Every C symbol exported from Zig keeps the exact name and signature of its C declaration (spec §3.1 and the headers). Every Zig file formats clean under `zig fmt --check`; every Perl change passes `perl -c Configure.pl`.
- A build without the Zig groups (`-Dzig-impl=false`, or `perl Configure.pl` without `--zig`) compiles exactly the C files it compiles on `zig-port-step0`, and its headers are byte-for-byte today's (`#if MVM_ZIG_IMPL` is the only addition).
- Before any `zig build` without `-Dconfig-h`: `rm -f src/gen/config.h src/gen/config.c src/gen/config.o`. `zig build` needs an absolute `--prefix` (`$PWD/zig-out`). After Perl builds: `make realclean; rm -f moar libmoar.so src/gen/config.h src/gen/config.c src/gen/config.o Makefile` (`realclean` leaves `moar` and `libmoar.so`).
- Full builds take minutes: use `timeout` of at least 600000 ms. rakudo builds and spectest runs take tens of minutes: run them in the background with their output redirected to a file in the plan workspace.
- Spec constants: load factor 0.75; minimum Robin Hood size 2^3 official slots; max probe distance 255 (`MVM_HASH_MAX_PROBE_DISTANCE`); starting metadata hash bits 5; Small starts at 8 slots and doubles to `small_threshold`; `small_threshold` is chosen in Task 1 from {64, 128, 256} by the 95-percent rule; tier set thresholds are entry counts; migration is upward only.
- Iteration positions are `u32`, `0` is end, visited in strictly decreasing numeric order; deleting the current entry leaves every lower position's entry in place.
- Zig gotcha from step zero: bind a C-pointer deref before taking the address of an array element (`const cache: *T = tc.instance.*.x;` then `&cache.arr[0]`).
- Commit after each task with the message given, appending the attribution lines the environment requires.

## Review Focus

1. A lookup that probes a slot whose entry was just created by `lvalueFetch` and whose key is still NULL (the caller has not filled it yet) must not dereference the NULL key: Task 7 test `lookup of another key while a fresh entry's key is still null`.
2. `lvalueFetch` of a key that already exists in a full Small rung must return it without migrating (today's "lvalue_fetch never grows" rule protects live iterators): Task 6 test `lvalueFetch of an existing key in a full rung does not migrate`.
3. A hash that fills, has every key deleted, and is refilled in Small must not leave stale tags or positions behind (swap-remove bookkeeping): Task 4 test `fill, delete all, refill`.
4. A concurrent reader (the debugserver) that still holds the old block during a migration must find `stale == 1` on it until the safepoint frees it: Task 7 test `migration marks the old block stale and publishes by CAS`.
5. `shallow_copy` and `allocated_size` on an unbuilt (NULL) and a control-only table must not crash and must produce a destination that reads as the same state: Task 7 test `shallow copy of null and control-only tables`.

---

### Task 1: Spike: histogram of final table sizes, choose `small_threshold`

**Files:**
- Scratch branch `zig-hash-spike` off `zig-hash-engine`; modify there: `src/core/str_hash_table.c`, `src/6model/reprs/MVMHash.c:83-88`, `src/6model/reprs/HashAttrStore.c` (its `gc_free`)
- Create (kept): `tools/hash-size-histogram.pl` (sums per-process lines), and the results section at the end of this plan

**Interfaces:**
- Produces: the value of `small_threshold` (64, 128 or 256) recorded under "Spike results" below; every later task reads it from there and from `src/zig/core/hash/str.zig` once Task 7 defines `pub const small_threshold`.

- [ ] **Step 1: Instrument on the scratch branch**

`git checkout -b zig-hash-spike`. In `str_hash_table.c` add a static `MVMuint64 histogram[3][8]` (rows: all, MVMHash, HashAttrStore; columns: buckets 0, 1-4, 5-16, 17-64, 65-128, 129-256, 257-1024, 1025+), a function `void MVM_str_hash_histogram_note(MVMStrHashTable *ht, int row)` that increments the bucket of `control ? control->cur_items : 0` for row 0 and, when `row > 0`, for that row too, and an `atexit` handler registered on the first call that appends one line `all <8 counts> mvmhash <8 counts> attrstore <8 counts>` to the file named by `getenv("MVM_HASH_HISTOGRAM")` (opened with `O_APPEND`). Call `MVM_str_hash_histogram_note(hashtable, 0)` at the top of `MVM_str_hash_demolish`; call it with row 1 from `MVMHash`'s `gc_free` and row 2 from `HashAttrStore`'s `gc_free`, each just before their `MVM_str_hash_demolish` call (the row-0 count then happens inside demolish; the handler subtracts nothing: "others" is `all - mvmhash - attrstore` in the summary script).

- [ ] **Step 2: Build the instrumented C engine and rakudo against it, run spectest**

```bash
P=/tmp/claude-1000/hash-spike-prefix
perl Configure.pl --prefix $P && make -j"$(nproc)" && make install
(cd .. && perl Configure.pl --backends=moar --with-moar=$P/bin/moar --prefix=$P && make -j"$(nproc)" install)
(cd ../.. && perl Configure.pl --backends=moar --with-nqp=$P/bin/nqp --prefix=$P && MVM_HASH_HISTOGRAM=/tmp/claude-1000/hist-build.txt make -j"$(nproc)" install)
(cd ../.. && MVM_HASH_HISTOGRAM=/tmp/claude-1000/hist-spectest.txt make spectest)
```
Expected: all four succeed (spectest may have pre-existing failures; note their count as the baseline for Task 14). Both histogram files are non-empty.

- [ ] **Step 3: Summarise and choose**

Write `tools/hash-size-histogram.pl` (reads the files named on its command line, sums the three rows, prints per-row bucket counts and the cumulative coverage of the 1-64, 1-128 and 1-256 ranges as percentages of tables with at least one entry). Run it on both files together and on each alone. Apply the rule: `small_threshold` is the smallest of 64, 128, 256 whose cumulative coverage over all callers in the combined data is at least 95 percent. Record the tables and the choice under "Spike results" at the end of this plan.

- [ ] **Step 4: Discard the instrumentation, keep the script and the results**

```bash
git add -A && git commit -m "spike: hash size histogram (throwaway)"     # on zig-hash-spike
git checkout zig-hash-engine
git checkout zig-hash-spike -- tools/hash-size-histogram.pl docs/superpowers/plans/2026-11-02-zig-hash-engine.md
git status --short   # only the script and this plan
git commit -m "Hash spike: size histogram script and results; small_threshold chosen"
git branch -D zig-hash-spike
```

---

### Task 2: Shims the engine needs: `trycas`, a `std.mem.Allocator` over `MVM_malloc`

**Files:**
- Modify: `src/zig/moar.zig` (shims and tests)

**Interfaces:**
- Produces: `pub inline fn trycas(addr: anytype, old: anytype, new: anytype) bool` (compare-and-swap of a pointer-sized slot, `.seq_cst`, mirrors the `MVM_trycas` macro at `src/moar.h:151-153`); `pub const mvm_allocator: std.mem.Allocator` (alloc through `c.MVM_malloc`, free through `c.MVM_free`, resize and remap unsupported); translated functions used directly: `c.MVM_free_at_safepoint`, `c.MVM_malloc`, `c.MVM_free`, `c.MVM_string_hash_code`, `c.MVM_string_graphs_nocheck`, `c.MVM_string_substrings_equal_nocheck`, `c.MVM_proc_rand_i`, `c.MVM_oops`, `c.MVM_exception_throw_adhoc` (all present in the translated module; verified).

- [ ] **Step 1: Write the failing tests**

Append to `src/zig/moar.zig`'s test section:
```zig
test "trycas swaps only when the slot holds the expected value" {
    var slot: usize = 1;
    try std.testing.expect(trycas(&slot, @as(usize, 1), @as(usize, 2)));
    try std.testing.expectEqual(@as(usize, 2), slot);
    try std.testing.expect(!trycas(&slot, @as(usize, 1), @as(usize, 3)));
    try std.testing.expectEqual(@as(usize, 2), slot);
}

test "mvm_allocator allocates and frees through MVM_malloc" {
    const buf = try mvm_allocator.alloc(u8, 4096);
    defer mvm_allocator.free(buf);
    @memset(buf, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[4095]);
}
```

- [ ] **Step 2: Run to verify failure**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build unit-test --prefix $PWD/zig-out 2>&1 | grep -m2 'error:'
```
Expected: `use of undeclared identifier 'trycas'` (or `mvm_allocator`).

- [ ] **Step 3: Implement**

In `src/zig/moar.zig`, before the tests: `trycas` as `@cmpxchgStrong` on `addr` (accept `*usize` and pointer-to-pointer slots by casting to `*usize`; `old`/`new` likewise via `@intFromPtr` when they are pointers); `mvm_allocator` as a `std.mem.Allocator` whose vtable `alloc` calls `c.MVM_malloc(len)` (ignore alignment above 16, which `MVM_malloc` guarantees for the sizes used), `free` calls `c.MVM_free`, `resize`/`remap` return false/null.

- [ ] **Step 4: Run tests**

```bash
zig fmt --check src/zig && zig build unit-test --prefix $PWD/zig-out --summary all 2>&1 | grep -m1 'Build Summary'
```
Expected: all tests pass; the shim-test binary reports 6 tests.

- [ ] **Step 5: Commit**

```bash
git add src/zig/moar.zig
git commit -m "moar shims: trycas and an Allocator over MVM_malloc for the hash engine"
```

---

### Task 3: Tier sets and the tier contract (`tier.zig`)

**Files:**
- Create: `src/zig/core/hash/tier.zig`
- Modify: `build.zig` (add `src/zig/core/hash/tier.zig` to the unit-test file list)

**Interfaces:**
- Produces:
  ```zig
  pub const Op = enum { insert, delete };
  pub const TierEntry = struct { tier: type, from: u32, double_write: bool = false };
  pub const TierSet = []const TierEntry;
  pub fn validate(comptime set: TierSet) void;          // @compileError on: empty set, first.from != 0, non-increasing from, tier.max_capacity < next.from
  pub fn startingRung(comptime set: TierSet, expected: u32) u8;   // index of the last entry with from <= expected
  pub fn nextRung(comptime set: TierSet, rung: u8) ?u8;           // null at the top
  pub inline fn logHook(comptime set: TierSet, rung: u8, op: Op, entry: [*]u8) void;  // no-op in this campaign (double_write reserved)
  pub const Header = extern struct { tier: u8, set: u8, entry_size: u8, stale: u8, cur_items: u32 };  // spec §4.2; Task 6's table.zig re-exports it
  ```
  A tier is a type with `pub const max_capacity: u32` and `pub fn Impl(comptime Spec: type) type` returning the §5 operations (Task 4 defines the first one).

- [ ] **Step 1: Write the failing tests** (in `tier.zig`, with two stub tier types declared in the test block, `max_capacity` 64 and `maxInt(u32)`):

```zig
test "startingRung picks the last rung whose threshold is at most the hint" {
    const set = [_]TierEntry{ .{ .tier = StubSmall, .from = 0 }, .{ .tier = StubBig, .from = 64 } };
    try std.testing.expectEqual(@as(u8, 0), startingRung(&set, 0));
    try std.testing.expectEqual(@as(u8, 0), startingRung(&set, 63));
    try std.testing.expectEqual(@as(u8, 1), startingRung(&set, 64));
    try std.testing.expectEqual(@as(u8, 1), startingRung(&set, 100_000));
    try std.testing.expectEqual(@as(?u8, 1), nextRung(&set, 0));
    try std.testing.expectEqual(@as(?u8, null), nextRung(&set, 1));
}
test "validate accepts the standard shape" {
    comptime validate(&[_]TierEntry{ .{ .tier = StubSmall, .from = 0 }, .{ .tier = StubBig, .from = 64 } });
}
```
(The `@compileError` paths cannot be unit-tested in-process; Task 6 compiles a negative probe for them.)

- [ ] **Step 2: Run to verify failure**

```bash
zig test src/zig/core/hash/tier.zig 2>&1 | head -3
```
Expected: `use of undeclared identifier 'startingRung'`.

- [ ] **Step 3: Implement the four functions and the types in `tier.zig`**

- [ ] **Step 4: Run tests, add to the unit-test list, run the build's unit tests**

```bash
zig fmt --check src/zig/core/hash && zig test src/zig/core/hash/tier.zig 2>&1 | tail -1
zig build unit-test --prefix $PWD/zig-out --summary all 2>&1 | grep -m1 'Build Summary'
```
Expected: `All 2 tests passed.`; build summary all steps succeeded.

- [ ] **Step 5: Commit**

```bash
git add src/zig/core/hash/tier.zig build.zig
git commit -m "hash engine: tier sets and the tier contract"
```

---

### Task 4: The Small tier (`tiers/small.zig`)

**Files:**
- Create: `src/zig/core/hash/tiers/small.zig`, `src/zig/core/hash/test_spec.zig` (a pure-Zig `Spec` for tier and table tests)
- Modify: `build.zig` (unit-test list: `tiers/small.zig`)

**Interfaces:**
- Consumes: `tier.TierEntry`.
- Produces: `pub fn Tier(comptime cfg: struct { max_capacity: u32 }) type` with `max_capacity` and `Impl(comptime Spec)`; `Impl` provides exactly spec §5: `init(allocator, header_init: Header, capacity: u32) !*Header`, `capacity(*Header) u32`, `isFull(*Header) bool`, `hash(ctx, key) u64`, `fetch(*Header, ctx, key, h: u64) ?[*]u8`, `lvalueFetch(*Header, ctx, key, h) LvalueResult` (`union(enum) { found: [*]u8, inserted: [*]u8, full }`), `delete(*Header, ctx, key, h) bool`, `grow(*Header, allocator) !?*Header` (doubling up to `max_capacity`, null at the ceiling), `first(*Header) u32`, `next(*Header, u32) u32`, `entryAt(*Header, u32) [*]u8`, `start(*Header) u32`, `drain(*Header, visitor: anytype) void` (visitor is `fn([*]u8) void`-shaped `anytype`), `allocatedSize(*Header) usize`, `fsck(*Header, ctx, mode: u32) u64`, `blockStart(*Header) [*]u8` (the malloc'd block's start, for freeing). `Header` is `tier.Header` (Task 3).
- `test_spec.zig` produces `pub const IntSpec` with `Key = u64` (0 is the "empty key" the caller fills), `Ctx = void`, `hash` = splitmix64 of the key, `eql` = `==`, `runtime_entry_size = true`, `allocator(ctx)` = `std.testing.allocator`, `publish = .plain`, `onDuplicate(ctx) void` sets `pub var duplicate_seen: bool` and returns, `sets` = `&.{standard_test_set}` where `standard_test_set = [Small(max 64) from 0, RobinHood from 64]` (RobinHood added in Task 5; until then the set has one rung).

- [ ] **Step 1: Write the failing tests** (in `small.zig`, entry size 16, keys 1..n, value stored at entry offset 8):

```zig
test "init at 8, fetch misses on empty, lvalueFetch inserts with a zero key" { ... capacity()==8; fetch(5)==null; lvalueFetch(5) == .inserted and key slot reads 0; caller writes key 5; fetch(5) returns that entry }
test "fills to capacity then reports full; grow doubles up to the ceiling" { ... 8 inserts; 9th lvalueFetch == .full; grow -> capacity 16 ... grow at 64 returns null }
test "delete swaps the last entry into the hole and iteration visits every entry once" { ... 10 entries, delete key 3, iterate from first() while pos != 0 collecting keys: 9 distinct keys, none == 3 }
test "deleting the current entry while holding next keeps the walk correct" { ... pos = first(); next = next(pos); delete(entryAt(pos).key); continue from next: remaining keys each seen exactly once }
test "fill, delete all, refill" { ... 64 inserts, delete all 64 (count 0, every fetch null), insert 64 new keys, each fetchable, iteration yields 64 }
test "tag collisions fall through to key equality" { ... two keys whose hash top bytes are equal (search for them in the test by brute force over small integers); both insertable and distinguishable }
```

- [ ] **Step 2: Run to verify failure**

```bash
zig test src/zig/core/hash/tiers/small.zig 2>&1 | head -3
```
Expected: compile error on the missing `Tier`/`Impl`.

- [ ] **Step 3: Implement `small.zig`**

Block layout: `Header`, tags (`capacity` bytes), entries (`capacity * entry_size` bytes), all in one allocation from `Spec.allocator(ctx)`; `blockStart` returns the header pointer (the header is first). Tag = top byte of `h`. Lookup compares tags in chunks of the current capacity using `@Vector(N, u8)` with `N` in {8, 16, 32, 64} chosen by capacity (comptime switch), then `Spec.eql` on candidates whose key is non-zero/non-null. Iteration positions: index `i` is position `i + 1`; `first` returns `cur_items`; `next` returns `pos - 1`; `start` returns `cur_items + 1`.

- [ ] **Step 4: Run tests**

```bash
zig fmt --check src/zig/core/hash && zig test src/zig/core/hash/tiers/small.zig 2>&1 | tail -1
```
Expected: `All 6 tests passed.` (no leaks: the testing allocator is in use).

- [ ] **Step 5: Commit**

```bash
git add src/zig/core/hash/tiers/small.zig src/zig/core/hash/test_spec.zig build.zig
git commit -m "hash engine: Small tier (flat entries, tag bytes, vector compare)"
```

---

### Task 5: The Robin Hood tier (`tiers/robinhood.zig`)

**Files:**
- Create: `src/zig/core/hash/tiers/robinhood.zig`
- Modify: `src/zig/core/hash/test_spec.zig` (second rung), `build.zig` (unit-test list)

**Interfaces:**
- Consumes: the tier contract (Task 3), `Header` (Task 4).
- Produces: `pub fn Tier(comptime cfg: struct { salt: enum { none, engine } = .engine }) type`, `max_capacity = std.math.maxInt(u32)`, same `Impl` operations as Small plus `pub fn setSalt(*Header, u64) void`/`salt(*Header) u64`. Payload fields mirror `MVMStrHashTableControl` minus the debug ones: `salt`, `max_items`, `official_size_log2`, `key_right_shift`, `max_probe_distance`, `max_probe_distance_limit`, `metadata_hash_bits`. Entries sit below the header (bucket i at `header - entry_size*(i+1)`), metadata bytes after it, as `src/core/str_hash_table.h:161-179` describes; `blockStart` returns the lowest address.

- [ ] **Step 1: Write the failing tests** (in `robinhood.zig`, `IntSpec`, entry size 16):

```zig
test "init rounds the capacity up to the C sizes (8 official + 5 overflow at minimum)" { ... init(capacity 1): capacity()==13 ... init(100): official 128 }
test "insert, fetch, miss, delete, count across a growth" { ... 1000 keys inserted through lvalueFetch/grow loop (call grow when .full); all fetchable; 500 deleted; the rest fetchable; deleted ones miss }
test "probe-limit growth trades a metadata bit before doubling" { ... construct keys sharing the top hash bits (brute force) until lvalueFetch returns .full below the load limit; grow; capacity unchanged and metadata_hash_bits decreased by one }
test "delete-current while holding next visits every remaining entry once" { ... as in Task 4, over 300 entries }
test "fsck reports no errors on a consistent table" { ... fsck(.., mode 0) == 0 }
```

- [ ] **Step 2: Run to verify failure**

```bash
zig test src/zig/core/hash/tiers/robinhood.zig 2>&1 | head -3
```
Expected: compile error on the missing module contents.

- [ ] **Step 3: Implement `robinhood.zig` as a port of `src/core/str_hash_table.c`**

Port the algorithm, not the file: `hash_allocate_common` (sizes and probe limits from `str_hash_table.c:57-121`), the loop state and probe from `str_hash_table_funcs.h:137-180` and `184-284`, insert with make-room from `str_hash_table.c:200-320`, the metadata-bit trade `356-389`, doubling with reinsert `391-451`, delete with backward shift `520-580` and the max_items repair `580-656`, iteration `funcs.h:411-585`, `fsck` from `876-`. Bucket hash is `(h ^ salt) * 11400714819323198485 >> key_right_shift` as `funcs.h:125-129, 170-172`. The salt is given by `setSalt` (the policy layer draws it, Task 6).

- [ ] **Step 4: Run tests; extend `test_spec.zig`'s set to `[Small(64) from 0, RobinHood from 64]`**

```bash
zig fmt --check src/zig/core/hash && zig test src/zig/core/hash/tiers/robinhood.zig 2>&1 | tail -1 && zig test src/zig/core/hash/tiers/small.zig 2>&1 | tail -1
```
Expected: `All 5 tests passed.`, `All 6 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/zig/core/hash/tiers/robinhood.zig src/zig/core/hash/test_spec.zig build.zig
git commit -m "hash engine: Robin Hood tier, a port of the C algorithm"
```

---

### Task 6: The policy layer (`table.zig`)

**Files:**
- Create: `src/zig/core/hash/table.zig`, `src/zig/core/hash/rng.zig`
- Modify: `src/zig/core/hash/tier.zig` (re-export `Header` from `table.zig` or move it), `build.zig` (unit-test list)

**Interfaces:**
- Consumes: tier modules (Tasks 4, 5), `tier.validate/startingRung/nextRung/logHook`, `moar.trycas`, `c.MVM_free_at_safepoint`.
- Produces: `pub const Header` (§4.2: `tier, set, entry_size, stale: u8; cur_items: u32`), and
  ```zig
  pub fn Table(comptime Spec: type) type   // Spec: Key, Ctx, hash, eql, runtime_entry_size (or fixed_entry_size: u32),
                                           //       allocator(ctx) std.mem.Allocator, publish: enum { plain, safepoint_cas },
                                           //       tc(ctx) *ThreadContext (safepoint_cas only), sets: []const TierSet,
                                           //       onDuplicate(ctx) void (StrSpec's calls MVM_oops and never returns), salt(ctx) u64 (for tiers configured .engine)
  // returned struct, Handle = *?*Header (the address of the C struct's one pointer):
  pub fn build(ctx, h: Handle, entry_size: u32, expected: u32, set_index: u8) void
  pub fn demolish(ctx, h) void
  pub fn count(h) u32;  pub fn entrySize(h) u32;  pub fn isEmpty(h) bool;  pub fn allocatedSize(h) usize
  pub fn shallowCopy(ctx, src: Handle, dst: Handle) void
  pub fn fetch(ctx, h, key) ?[*]u8
  pub fn lvalueFetch(ctx, h, key) [*]u8        // grows or migrates when full and the key is absent
  pub fn insert(ctx, h, key) [*]u8             // lvalueFetch; Spec.onDuplicate(ctx) if the key was present
  pub fn delete(ctx, h, key) bool
  pub fn first(h) u32;  pub fn next(h, pos: u32) u32;  pub fn start(h) u32;  pub fn atStart(h, pos) bool;  pub fn current(h, pos) ?[*]u8
  pub fn fsck(ctx, h, mode: u32) u64
  pub fn rung(h) u8                            // for tests
  ```
  `rng.zig`: `pub fn salt(instance: *c.MVMInstance) u64` (atomic counter mixed with `instance.hashSeed` by splitmix64).

- [ ] **Step 1: Write the failing tests** (in `table.zig`, `IntSpec`, entry size 16; `Handle` is the address of a local `?*Header`):

```zig
test "null and control-only states" { ... count/entrySize/isEmpty/allocatedSize on a null handle: 0/0/true/0; first == 0; build(.., 0 expected) -> entrySize 16, count 0, first == 0, rung 0; demolish -> null }
test "a hint picks the starting rung" { ... build(expected 10) -> rung 0, capacity >= 10; build(expected 64) -> rung 1; build(expected 1000) -> rung 1 and count 0 }
test "crossing the threshold migrates every entry upward exactly once" { ... insert keys 1..64 one by one: rung 0 throughout; insert 65: rung 1; every key 1..65 fetchable; count 65; the old block pointer differs from the new }
test "lvalueFetch of an existing key in a full rung does not migrate" { ... fill Small to 64; lvalueFetch(key 7) returns the existing entry and rung stays 0 }
test "deletes never demote" { ... grow to 200, delete down to 3, rung still 1 }
test "iteration dispatch and delete-current across both rungs" { ... at 30 and at 300 entries: walk with first/next/current deleting every other current entry; remaining count and keys correct }
test "shallowCopy preserves layout and contents" { ... copy at 50 and at 500 entries; destination iterates the same keys in the same positions }
test "insert of an existing key calls onDuplicate" { ... insert(5) twice: after the second, test_spec.duplicate_seen == true and count == 1 }
```

- [ ] **Step 2: Run to verify failure**

```bash
zig test src/zig/core/hash/table.zig 2>&1 | head -3
```
Expected: compile error on the missing `Table`.

- [ ] **Step 3: Implement `table.zig` and `rng.zig`**

Growth per spec §4.4: on `.full` from the rung, try `grow`; if null and a next rung exists, migrate (allocate the next rung for `2 * cur_items`, `setSalt` from `Spec.salt(ctx)` when the tier is `.engine`, `drain` the old rung inserting each entry's bytes verbatim after rehashing its key with the new tier's `hash`, then publish). Publication: `.plain` frees the old block through the allocator and stores the new pointer; `.safepoint_cas` sets `old.stale = 1`, calls `c.MVM_free_at_safepoint(Spec.tc(ctx), blockStart(old))`, and `moar.trycas(h, old, new)` with `c.MVM_oops` on failure, exactly as `str_hash_table.c:398, 479-487`. Every public function with a header checks `stale` on entry (and exit for mutators) and `MVM_oops`es when set, for `.safepoint_cas` Specs only. `logHook` is called from `lvalueFetch` (on `.inserted`) and `delete`.

- [ ] **Step 4: Run tests and a negative compile probe for `validate`**

```bash
zig fmt --check src/zig/core/hash && zig test src/zig/core/hash/table.zig 2>&1 | tail -1
printf 'const t = @import("tier.zig");\nconst s = @import("tiers/small.zig");\ncomptime { t.validate(&[_]t.TierEntry{ .{ .tier = s.Tier(.{ .max_capacity = 64 }), .from = 0 }, .{ .tier = s.Tier(.{ .max_capacity = 8 }), .from = 64 } }); }\n' > src/zig/core/hash/neg_probe.zig
zig build-obj src/zig/core/hash/neg_probe.zig -femit-bin=/tmp/claude-1000/neg.o 2>&1 | grep -m1 'error:'; rm -f src/zig/core/hash/neg_probe.zig /tmp/claude-1000/neg.o
```
Expected: `All 8 tests passed.`; the probe fails with the `validate` message naming the rung whose capacity is below the next threshold.

- [ ] **Step 5: Commit**

```bash
git add src/zig/core/hash/table.zig src/zig/core/hash/rng.zig src/zig/core/hash/tier.zig build.zig
git commit -m "hash engine: policy layer (tier sets, growth, migration, publication, iteration)"
```

---

### Task 7: The string table in Zig (`str.zig`), tested against libmoar

**Files:**
- Create: `src/zig/core/hash/str.zig`, `src/zig/core/hash/test/str_test.zig`, `src/zig/core/hash/test/keys.zig` (test helper: make N distinct `MVMString`s kept alive in a permanently rooted `BOOTArray`, allocated in gen2 so they never move)
- Modify: `build/zig/zigimpl.zig` (`addShimTests` takes the test root path and a name; call it twice from `build.zig`: `src/zig/moar.zig` as today and `src/zig/core/hash/test/str_test.zig` as `hash-str-test`), `build.zig`

**Interfaces:**
- Consumes: `Table(Spec)` (Task 6), tiers (Tasks 4, 5), `rng.salt`.
- Produces in `str.zig`: `pub const small_threshold: u32 = <Task 1 value>;`, `pub const standard: TierSet`, `pub const large_only: TierSet`, `pub const sets = &.{ standard, large_only };`, `pub const StrSpec` (`Key = [*c]c.MVMString`, `Ctx = *moar.ThreadContext`, `hash` = `c.MVM_string_hash_code(tc, key)`, `eql` = pointer equality, then `c.MVM_string_graphs_nocheck` equality, then `c.MVM_string_substrings_equal_nocheck(tc, a, b, 0, graphs, 0) != 0` as `str_hash_table_funcs.h:280-284`, `runtime_entry_size = true`, `allocator` = `moar.mvm_allocator`, `publish = .safepoint_cas`, `tc(ctx) = ctx`, `onDuplicate` = `c.MVM_oops(tc, "insert duplicate key")` with the exact text from `str_hash_table.c:511`, `salt(ctx)` = `rng.salt(tc.instance)`), `pub const StrTable = table.Table(StrSpec)`, and C-API-shaped Zig functions `build/demolish/fetchNocheck/lvalueFetchNocheck/insertNocheck/deleteNocheck/fetch/lvalueFetch/delete/first/next/nextNocheck/start/atStart/currentNocheck/current/count/entrySize/isEmpty/allocatedSize/shallowCopy/fsck/keyIsValid/keyThrowInvalid` taking `(tc: *ThreadContext, ht: *c.MVMStrHashTable, ...)` with the C semantics (`fetch`/`lvalueFetch`/`delete` validate the key and throw `"Hash keys must be concrete strings (got %s)"` via `c.MVM_exception_throw_adhoc` with `c.MVM_6model_get_debug_name`; `next` and `current` are the checked variants; `current` returns null at end). The header pointer in `c.MVMStrHashTable.table` is treated as `*?*table.Header` (`MVMStrHashTableControl` is opaque to Zig; cast at the boundary).

- [ ] **Step 1: Write the failing tests** (`str_test.zig`, each creating an instance as the shim tests do; keys from `keys.zig`; entry size `@sizeOf(c.MVMHashEntry)`):

```zig
test "unbuilt, control-only and built states through the C-shaped API" { ... null: entrySize 0, count 0, isEmpty, first.pos == 0; build(.., 0): entrySize 16, count 0; demolish -> table null; a zeroed MVMStrHashTable reads as unbuilt }
test "lookup of another key while a fresh entry's key is still null" { ... lvalueFetchNocheck(k1) returns entry with key null; fetchNocheck(k2) == null without crashing; fill key; fetch(k1) finds it }
test "insert, fetch, delete and count across the threshold" { ... small_threshold + 10 keys; rung changes once; all found; delete half; count right }
test "insertNocheck of a fresh key returns an entry with a null key" { ... (the duplicate path calls MVM_oops, which aborts, so it is not exercised in-process; Task 14's rakudo build covers deserialize) }
test "iteration matches MVMIter's protocol: start, first, delete current while holding next" { ... curr = start; next = first; loop: curr = next; if atEnd break; next = nextNocheck(curr); delete(current(curr).key) every other time; all keys visited once }
test "migration marks the old block stale and publishes by CAS" { ... capture the header pointer at small_threshold entries; insert one more; old.stale == 1; ht.table != old }
test "shallow copy of null and control-only tables" { ... shallowCopy from a null source leaves dest null; from control-only gives a control-only dest with the same entrySize; from a 100-entry table gives a dest with identical iteration order }
test "allocated size is nonzero once built and grows at migration" { ... }
test "keyIsValid rejects a type object" { ... keyIsValid(tc, instance.VMString as a type object) == false; the throw itself is not exercised in-process }
```
Also in this step: generalise `addShimTests` to take the test root path and a name, and call it from `build.zig` a second time for `src/zig/core/hash/test/str_test.zig` as `hash-str-test`, so the next step compiles the new root.

- [ ] **Step 2: Run to verify failure**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build unit-test --prefix $PWD/zig-out 2>&1 | grep -m2 'error:'
```
Expected: the new test root fails to compile on the missing `str.zig` declarations.

- [ ] **Step 3: Implement `str.zig` and `keys.zig`**

`keys.zig`: `pub fn make(tc, n: u32) []const [*c]c.MVMString` using `c.MVM_gc_allocate_gen2_default_set(tc)`, `c.MVM_string_ascii_decode_nt(tc, tc.instance.*.VMString, "k<n>")`, pushed into a `BOOTArray` rooted with `c.MVM_gc_root_add_permanent_desc`, then `c.MVM_gc_allocate_gen2_default_clear(tc)`.

- [ ] **Step 4: Run the unit tests**

```bash
zig fmt --check src/zig build/zig build.zig && zig build unit-test --prefix $PWD/zig-out --summary all 2>&1 | grep -m1 'Build Summary'
B=$(find .zig-cache -type f -name 'hash-str-test' | head -1); "$B" 2>&1 | tail -1
```
Expected: all steps succeed; `All 9 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/zig/core/hash/str.zig src/zig/core/hash/test build/zig/zigimpl.zig build.zig
git commit -m "hash engine: the string table on Table(Spec), tested against libmoar"
```

---

### Task 8: Cutover: `MVM_ZIG_IMPL`, header switch, exports, `[zig]` line

**Files:**
- Create: `src/zig/core/hash/str_exports.zig`
- Modify: `build/config.h.in`, `Configure.pl` (config key `zig_impl`; `ZIG_SOURCES` enumeration), `build/zig/config.zig`, `src/core/str_hash_table.h`, `src/core/str_hash_table_funcs.h`, `src/zig/root.zig`, `build/sources.list`

**Interfaces:**
- Consumes: Task 7's C-shaped functions.
- Produces: `MVM_ZIG_IMPL` defined to 1 in `config.h` when the Zig groups are on (both builds); the string table's headers switch on it; exported symbols: every function in spec §3.1 plus `MVM_round_up_log_base2` (used by `index_hash_table.c:81` and `uni_hash_table.c:71`); `MVMStrHashTableControl` is incomplete under the define.

- [ ] **Step 1: The define in both builds**

`build/config.h.in`, after the `MVM_BIGENDIAN` block:
```c
/* The Zig implementations from build/sources.list's [zig] section are built
 * in place of the C files they replace; the hash table headers then declare
 * their functions extern instead of defining them inline. */
#if @zig_impl@
#define MVM_ZIG_IMPL 1
#endif
```
`Configure.pl`: `$config{zig_impl} = defined $args{zig} ? 1 : 0;` next to the other `zig_*` keys. `build/zig/config.zig`: `.zig_impl = in.opts.zig_impl,` in `configHeader`. Verify both renderings:
```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build config-h --prefix $PWD/zig-out && grep -B1 'define MVM_ZIG_IMPL' zig-out/config.h | head -1
zig build config-h --prefix $PWD/zig-out -Dzig-impl=false && grep -B1 'define MVM_ZIG_IMPL' zig-out/config.h | head -1
perl Configure.pl --zig=/usr/bin/zig --prefix /tmp/claude-1000/zig-hash-prefix >/dev/null && gcc -E -dM -Isrc src/gen/config.h | grep -c MVM_ZIG_IMPL
perl Configure.pl --prefix /tmp/claude-1000/zig-hash-prefix >/dev/null && gcc -E -dM -Isrc src/gen/config.h | grep -c MVM_ZIG_IMPL
make realclean >/dev/null 2>&1; rm -f src/gen/config.h src/gen/config.c src/gen/config.o Makefile
```
Expected: `#if 1`, `#if 0`, `1`, `0`.

- [ ] **Step 2: Header switch**

`src/core/str_hash_table.h`: wrap `struct MVMStrHashTableControl { ... }` in `#if !MVM_ZIG_IMPL ... #else struct MVMStrHashTableControl; #endif`; add `#if MVM_ZIG_IMPL && HASH_DEBUG_ITER` / `#error "HASH_DEBUG_ITER is not available with the Zig hash engine"` / `#endif`; make `MVM_str_hash_at_end` return `iterator.pos == 0` under `MVM_ZIG_IMPL` (no stale read) and keep today's body otherwise. `src/core/str_hash_table_funcs.h`: wrap everything except `MVM_hash_round_size_up`, `struct MVM_hash_loop_state`, `MVM_str_hash_key_is_valid` and `MVM_str_hash_key_throw_invalid` in `#if !MVM_ZIG_IMPL`; in the `#else` branch declare, with the exact C signatures from `str_hash_table_funcs.h` and `str_hash_table.c` (spec §3.1): `allocated_size, is_empty, shallow_copy, fetch_nocheck, lvalue_fetch, fetch, delete, next_nocheck, next, first, start, at_start, current_nocheck, current, count, entry_size` (the out-of-line ones are already declared in `str_hash_table.h` or `.c`'s callers via the header; declare `build, demolish, lvalue_fetch_nocheck, insert_nocheck, delete_nocheck, fsck` there too if the header does not already).

- [ ] **Step 3: Exports and registration**

`str_exports.zig`: one `export fn` per symbol, each a one-line call into `str.zig`'s function of the same shape (`MVMStrHashIterator` is `extern struct { pos: u32 }` from the translation; `MVMHashNumItems` is `u32`), plus `export fn MVM_round_up_log_base2(v: u32) u32` (`std.math.log2_int_ceil`-based, same result as `str_hash_table.c:12`: 0 for v <= 1). `src/zig/root.zig`: `_ = @import("core/hash/str_exports.zig");`. `build/sources.list` `[zig]`: `src/zig/core/hash/str_exports.zig: src/core/str_hash_table.c`. `Configure.pl`: build `zig_sources` from `File::Find` over `src/zig` (every `*.zig` and `*.h`), replacing the fixed list, so helper modules are Makefile dependencies.

- [ ] **Step 4: Build both ways, Perl both ways, run everything**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check build.zig build/zig src/zig && perl -c Configure.pl
zig build --prefix $PWD/zig-out install --verbose 2>&1 | grep -c 'src/core/str_hash_table.c'
nm -D zig-out/lib/libmoar.so | grep -cE ' T MVM_(str_hash_build|str_hash_fetch_nocheck|str_hash_first|round_up_log_base2)$'
zig build test --prefix $PWD/zig-out 2>&1 | tail -2; echo "test exit=$?"
zig build unit-test --prefix $PWD/zig-out --summary all 2>&1 | grep -m1 'Build Summary'
zig build --prefix $PWD/zig-out install -Dzig-impl=false --verbose 2>&1 | grep -c 'src/core/str_hash_table.c' && zig build test --prefix $PWD/zig-out -Dzig-impl=false 2>&1 | tail -1
perl Configure.pl --zig=/usr/bin/zig --prefix /tmp/claude-1000/zig-hash-prefix >/dev/null && make -j"$(nproc)" >/tmp/claude-1000/h8-make.log 2>&1; echo "make exit=$?"; ./moar --libpath=../src/vm/moar/stage0 ../src/vm/moar/stage0/nqp.moarvm -e 'my %h; %h<a> := 1; %h<b> := 2; nqp::deletekey(%h, "a"); say(nqp::elems(%h)); my $i := 0; while $i < 300 { %h{"k$i"} := $i; $i := $i + 1 }; say(nqp::elems(%h)); say(%h<k299>)'
make realclean >/dev/null 2>&1; rm -f moar libmoar.so
perl Configure.pl --prefix /tmp/claude-1000/zig-hash-prefix >/dev/null && make -j"$(nproc)" >/tmp/claude-1000/h8-make-c.log 2>&1; echo "make exit=$?"; grep -c 'compiling src/core/str_hash_table.o' /tmp/claude-1000/h8-make-c.log
make realclean >/dev/null 2>&1; rm -f moar libmoar.so src/gen/config.h src/gen/config.c src/gen/config.o Makefile
```
Expected: `0` C compiles with the groups on; `4` exports; stage0 test passes; unit tests pass; `1` compile and test pass with groups off; Perl `--zig` build succeeds and prints `1`, `301`, `299`; plain Perl build compiles the C file.

- [ ] **Step 5: Commit**

```bash
git add build/config.h.in Configure.pl build/zig/config.zig src/core/str_hash_table.h src/core/str_hash_table_funcs.h src/zig/core/hash/str_exports.zig src/zig/root.zig build/sources.list
git commit -m "hash engine: MVM_ZIG_IMPL, header switch, string table exports and [zig] line"
```

---

### Task 9: Port the pointer table (`ptr.zig`)

**Files:**
- Create: `src/zig/core/hash/ptr.zig`, `src/zig/core/hash/ptr_exports.zig`
- Modify: `src/core/ptr_hash_table.h`, `src/core/ptr_hash_table_funcs.h` (header switch as in Task 8), `src/zig/root.zig`, `build/sources.list`
- Test: `src/zig/core/hash/ptr.zig` inline tests (pure Zig, no libmoar)

**Interfaces:**
- Consumes: `Table(Spec)`, `robinhood.Tier(.{ .salt = .none })`.
- Produces exports with the exact C signatures: `MVM_ptr_hash_demolish(tc, ht)`, `MVM_ptr_hash_lvalue_fetch(tc, ht, const void *key) struct MVMPtrHashEntry *`, `MVM_ptr_hash_insert(tc, ht, key, uintptr_t value)`, `MVM_ptr_hash_fetch_and_delete(tc, ht, key) uintptr_t`, and the formerly inline `MVM_ptr_hash_build(tc, ht)`, `MVM_ptr_hash_is_empty`, `MVM_ptr_hash_fetch(tc, ht, key) struct MVMPtrHashEntry *`. `PtrSpec`: `Key = ?*const anyopaque`, `hash` = `ptr * 11400714819323198485` (`ptr_hash_table_funcs.h:68`), `eql` = `==`, fixed entry size `@sizeOf(c.MVMPtrHashEntry)`, `publish = .plain`, single-rung set `[RobinHood(no salt) from 0]`.

- [ ] **Step 1: Write the failing tests** (`ptr.zig`): `insert 1000 distinct pointers (addresses of a static array's elements), fetch each, fetch_and_delete half returns the stored values, the rest still found, is_empty after deleting all`.
- [ ] **Step 2: Run** `zig test src/zig/core/hash/ptr.zig` → compile error on the missing declarations.
- [ ] **Step 3: Implement `ptr.zig`, `ptr_exports.zig`, the header switch (`MVM_hash_round_size_up` stays; `struct MVMPtrHashTableControl` incomplete under the define), root import, `[zig]` line `src/zig/core/hash/ptr_exports.zig: src/core/ptr_hash_table.c`.**
- [ ] **Step 4: Run** `zig test src/zig/core/hash/ptr.zig` → `All 1 tests passed.`; then the Task 8 Step 4 command block (expect `0` compiles of `ptr_hash_table.c` too, stage0 and unit tests pass, Perl `--zig` build and the nqp snippet pass).
- [ ] **Step 5: Commit** `git add src/zig/core/hash/ptr.zig src/zig/core/hash/ptr_exports.zig src/core/ptr_hash_table.h src/core/ptr_hash_table_funcs.h src/zig/root.zig build/sources.list && git commit -m "hash engine: pointer table on Table(Spec)"`

---

### Task 10: Port the fixkey table (`fixkey.zig`)

**Files:** create `src/zig/core/hash/fixkey.zig`, `fixkey_exports.zig`; modify `src/core/fixkey_hash_table.h`, `fixkey_hash_table_funcs.h`, `src/zig/root.zig`, `build/sources.list`, `src/zig/core/hash/test/str_test.zig` (tests need real strings, so they live in the hash-str-test root).

Specifics: `MVM_fixkey_hash_build(tc, ht, MVMuint32 entry_size)` (no capacity; `entry_size == 0` is legal and means "entries are bare `MVMString **` pointers", `fixkey_hash_table.h:46-79`), `MVM_fixkey_hash_demolish`, `MVM_fixkey_hash_fetch_nocheck(tc, ht, key) void *`, `MVM_fixkey_hash_lvalue_fetch_nocheck`, `MVM_fixkey_hash_insert_nocheck`, `MVM_fixkey_hash_foreach(tc, ht, void (*callback)(MVMThreadContext *, void *, void *), void *arg)`, `MVM_fixkey_hash_is_empty`, `MVM_fixkey_hash_fsck`. Entries in the table are `MVMString ***` (pointer to the separately allocated struct whose first word is the key pointer); the table's own entry size is `@sizeOf(usize)` and the caller's `entry_size` (u16, kept in the Spec's own payload field as spec §4.2) is what `lvalue_fetch_nocheck` mallocs for a fresh entry, as `fixkey_hash_table.c:300-348`. Keys are `MVMString`s hashed with `c.MVM_string_hash_code` and compared as the string table does, no salt.

- [ ] **Step 1: Write the failing test** in `str_test.zig`: `fixkey: insert 200 keys with entry_size 24; each fresh entry is malloced with its first word the key; foreach visits 200; fetch_nocheck finds each`.
- [ ] **Step 2: Run** the unit-test build → compile error on the missing `fixkey.zig`.
- [ ] **Step 3: Implement** `fixkey.zig`, `fixkey_exports.zig`, the header switch, the root import, the `[zig]` line `src/zig/core/hash/fixkey_exports.zig: src/core/fixkey_hash_table.c`.
- [ ] **Step 4: Run** the Task 8 Step 4 block → `0` compiles of `fixkey_hash_table.c` with the groups on; everything else as there.
- [ ] **Step 5: Commit** `hash engine: fixkey table on Table(Spec)`.

---

### Task 11: Port the index table (`index.zig`)

**Files:** create `src/zig/core/hash/index.zig`, `index_exports.zig`; modify `src/core/index_hash_table.h`, `index_hash_table_funcs.h`, `src/zig/root.zig`, `build/sources.list`, `src/zig/core/hash/test/str_test.zig`.

Specifics: `MVM_index_hash_build(tc, ht, MVMuint32 entries)`, `MVM_index_hash_demolish`, `MVM_index_hash_insert_nocheck(tc, ht, MVMString **list, MVMuint32 idx)`, formerly inline `MVM_index_hash_fetch_nocheck(tc, ht, list, want) MVMuint32`, `MVM_index_hash_fetch` (validates the key), `MVM_index_hash_built`, `MVM_index_hash_is_empty`, `MVM_index_hash_shallow_copy`, `MVM_index_hash_allocated_size`; entries are `struct MVMIndexHashEntry { MVMuint32 index; }` and the key of an entry is `list[entry.index]`, so `Ctx` carries `(tc, list)` and `Spec.eql` compares `list[a.index]` to the wanted string (`index_hash_table_funcs.h:97, 119-160`); `MVM_INDEX_HASH_NOT_FOUND` is `0xFFFFFFFF`; no salt.

- [ ] **Step 1: Write the failing test** in `str_test.zig`: `index: build(10), insert indices 0..9 of a 10-string list, fetch each by string, fetch of an absent string is NOT_FOUND, shallow_copy iterates the same`.
- [ ] **Step 2: Run** the unit-test build → compile error on the missing `index.zig`.
- [ ] **Step 3: Implement** `index.zig`, `index_exports.zig`, the header switch, the root import, the `[zig]` line `src/zig/core/hash/index_exports.zig: src/core/index_hash_table.c`.
- [ ] **Step 4: Run** the Task 8 Step 4 block → `0` compiles of `index_hash_table.c` with the groups on.
- [ ] **Step 5: Commit** `hash engine: index table on Table(Spec)`.

---

### Task 12: Port the Unicode table (`uni.zig`)

**Files:** create `src/zig/core/hash/uni.zig`, `uni_exports.zig`; modify `src/core/uni_hash_table.h`, `uni_hash_table_funcs.h`, `src/zig/root.zig`, `build/sources.list`, `build.zig` (unit-test list: `uni.zig`, pure Zig).

Specifics: `MVM_uni_hash_build(tc, ht, MVMuint32 entries)`, `MVM_uni_hash_demolish`, `MVM_uni_hash_insert(tc, ht, const char *key, MVMint32 value)`, `MVM_uni_hash_fetch(tc, ht, key) struct MVMUniHashEntry *`, `MVM_uni_hash_lvalue_fetch` (declared `MVM_STATIC_INLINE` inside the `.c`, so it is private: port it as a private Zig function), `MVM_uni_hash_is_empty`, `MVM_uni_hash_fsck(ht, mode)` (no `tc`); entries `{ const char *key; MVMuint32 hash_val; MVMint32 value; }`; hash is `MVM_uni_hash_code(key, strlen)` ported from `uni_hash_table_funcs.h:49-60` and stored in `hash_val`; `eql` compares `hash_val` then `strcmp`; no salt.

- [ ] **Step 1: Write the failing test** in `uni.zig`: `insert 2000 generated C-string keys ("prop<n>"), fetch each returns the stored value, a miss returns null`.
- [ ] **Step 2: Run** `zig test src/zig/core/hash/uni.zig` → compile error on the missing declarations.
- [ ] **Step 3: Implement** `uni.zig`, `uni_exports.zig`, the header switch, the root import, the `[zig]` line `src/zig/core/hash/uni_exports.zig: src/core/uni_hash_table.c`.
- [ ] **Step 4: Run** `zig test src/zig/core/hash/uni.zig` → `All 1 tests passed.`; then the Task 8 Step 4 block → `0` compiles of all five C hash files with the groups on, and `nm -D` shows `MVM_round_up_log_base2` still exported.
- [ ] **Step 5: Commit** `hash engine: Unicode table on Table(Spec); all five tables in Zig`.

---

### Task 13: Benchmarks

**Files:**
- Create: `src/zig/core/hash/bench.zig`, `tools/bench/hash-bench.raku`, `tools/bench/hash-bench.sh`
- Modify: `build/zig/zigimpl.zig` (`addHashBench`: an executable from `bench.zig` linked like the shim tests), `build.zig` (step `hash-bench`)

**Interfaces:**
- Produces: `zig build hash-bench --prefix $PWD/zig-out [-Dzig-impl=false] -- <ladder args>` prints TSV lines `engine<TAB>size<TAB>op<TAB>ns_per_op<TAB>alloc_bytes`; `hash-bench.raku --sizes=... ` prints the same columns with `engine` taken from `--engine=`; `hash-bench.sh` runs the microbenchmark for both engines (two clean `zig build install` runs into two prefixes) and the Raku script with two `moar`s given as arguments, and writes `docs/bench/hash-<date>.md` with one table per harness: rows = ladder sizes, columns = ops, cells = `zig_ns/c_ns` ratio with both absolute values, plus the memory columns.

- [ ] **Step 1: The ladder and the operations, as a test of the harness**: in `bench.zig` a test `ladder(threshold) yields the spec sizes with duplicates collapsed` (4, 16, 32, T-1, T, T+1, 128, 256, 1024, 16384, 65536, 1048576).
- [ ] **Step 2: Run** `zig test src/zig/core/hash/bench.zig` → fails on the missing `ladder`.
- [ ] **Step 3: Implement**: `bench.zig` `main` creates an instance, makes keys via `test/keys.zig`, and for each size times: insert N, lookup hit (N lookups of present keys), lookup miss (N lookups of a second key set), delete N, iterate (full walk), and for sizes T and T+1 the single (N)th insert; `std.time.Timer`, three runs, median; `alloc_bytes` from `MVM_str_hash_allocated_size` after the inserts. The engine column is `zig` or `c` from `-Dzig-impl` passed in as a build option (`b.addOptions` with `zig_impl`). The Raku script does the same with a `Hash` (`%h{$k} = $v`, `%h{$k}:exists`, `%h{$k}:delete`, `for %h.kv`), memory from `nqp::getrusage` maxrss deltas. `hash-bench.sh` orchestrates and renders the markdown.
- [ ] **Step 4: Run** the microbenchmark for both engines and the Raku script with the two Perl-built moars from Task 8 (rebuild them), check the markdown renders, and record the microbenchmark table in this plan's "Benchmark results" section (the Raku-level and spectest tables are added in Task 14).
- [ ] **Step 5: Commit** `git add src/zig/core/hash/bench.zig tools/bench build/zig/zigimpl.zig build.zig docs/bench && git commit -m "hash engine: C-API microbenchmark, Raku benchmark and the runner"`

---

### Task 14: nqp and rakudo on the Zig engine; spectest; docs

**Files:**
- Modify: `docs/zig-build.md` (section "Hash engine" after "Zig implementations": tier sets, `small_threshold`, the header switch and `MVM_ZIG_IMPL`, the benchmarks, observable changes from spec §13), `build/README.md` (one sentence: the hash tables live in `src/zig/core/hash/` when the Zig groups are on), this plan's results sections

- [ ] **Step 1: Two full stacks**

Build nqp and rakudo twice, against the C-engine moar (`perl Configure.pl --prefix $PC && make install`) and the Zig-engine moar (`perl Configure.pl --zig=/usr/bin/zig --prefix $PZ && make install`), using the nqp and rakudo `--with-moar`/`--with-nqp` commands from Task 1 Step 2 with `$PC` and `$PZ`. Expected: both complete; `$PZ/bin/raku -e 'my %h = (1..300).map({ "k$_" => $_ }); say %h<k299>; say %h.elems'` prints `299` and `300`.

- [ ] **Step 2: Spectest both, timed, with peak RSS**

`/usr/bin/time -v make spectest` in rakudo for each stack (three runs each, record wall time and "Maximum resident set size"); compare failure lists: no new failures on the Zig engine relative to the C baseline. Run `hash-bench.raku` with both `raku`s. Record all tables and the per-size ratios under "Benchmark results"; state the small-hash and large-hash ratios in one sentence each in `docs/zig-build.md`.

- [ ] **Step 3: Docs, then the spec's acceptance list end to end**

Run spec §12 items 1-3 and 7 as the Task 8 Step 4 block, items 4-6 as Steps 1-2 above, then `zig fmt --check build.zig build/zig src/zig tools/zig && perl -c Configure.pl`. Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add docs/zig-build.md build/README.md docs/superpowers/plans/2026-11-02-zig-hash-engine.md docs/bench
git commit -m "Docs and results: Zig hash engine on nqp and rakudo, spectest and benchmarks"
```

---

## Spike results

(Task 1 fills this in: the three histogram tables, the coverages at 64, 128 and 256, the chosen `small_threshold`.)

## Benchmark results

(Tasks 13 and 14 fill this in: microbenchmark, Raku-level and spectest tables with ratios and memory.)

## Deviations

Record here, during execution, anything that differed from the plan or spec and why.
