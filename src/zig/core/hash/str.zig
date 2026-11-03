//! The string table of the Zig hash engine (spec 3, 4.3, 7): `Table(Spec)`
//! instantiated for `MVMString` keys, and the C-API-shaped functions that
//! `src/core/str_hash_table.c` and `str_hash_table_funcs.h` define today.
//! Task 8 exports them under the C names; nothing here is exported yet.
//!
//! The C struct is one pointer, `MVMStrHashTable { table }`, and the control
//! struct behind it is the engine's: the pointer's address is the table's
//! `Handle` (`*?*Header`, `handleOf`) and this file never reads it as the
//! C's `MVMStrHashTableControl`.
//!
//! The ctx-less readers of `table.zig` (`count`, `first`, ...) cannot
//! `MVM_oops`, so their stale checks live here, with the C's message texts;
//! the mutators' checks are `table.zig`'s.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const tier = @import("tier.zig");
const table = @import("table.zig");
const rng = @import("rng.zig");
const small = @import("tiers/small.zig");
const robinhood = @import("tiers/robinhood.zig");

const Header = table.Header;
const ThreadContext = moar.ThreadContext;

/// The entry count at which a table leaves the Small tier (the plan's
/// "Spike results": 99.5% of tables stay at or below it).
pub const small_threshold: u32 = 64;

/// The ladder of `MVM_str_hash_build`: Small, then Robin Hood.
pub const standard = [_]tier.TierEntry{
    .{ .tier = small.Tier(.{ .max_capacity = small_threshold }), .from = 0 },
    .{ .tier = robinhood.Tier(.{}), .from = small_threshold },
};

/// Robin Hood from the first entry, for a future "pre-allocate big" hint.
pub const large_only = [_]tier.TierEntry{
    .{ .tier = robinhood.Tier(.{}), .from = 0 },
};

/// Indexed by the header's `set` byte.
pub const sets: []const tier.TierSet = StrSpec.sets;

/// Set index of `standard`, what the C API builds with. It must stay 0:
/// `table.zig` specialises dispatch for set 0.
const standard_set: u8 = 0;

pub const StrSpec = struct {
    pub const Key = [*c]c.MVMString;
    pub const Ctx = *ThreadContext;
    pub const runtime_entry_size = true;
    pub const publish: table.Publish = .safepoint_cas;
    pub const sets: []const tier.TierSet = &.{ &standard, &large_only };

    /// `MVM_string_hash_code` (`src/strings/ops.h`): the cached hash code,
    /// or, while it is still 0 (not computed yet), the out-of-line
    /// `MVM_string_compute_hash_code`, which computes and caches it. Written
    /// here rather than called through translate-c, whose copy of the C
    /// static inline is an out-of-line function the callers do not inline.
    pub inline fn hash(ctx: Ctx, key: Key) u64 {
        const cached = key.*.body.cached_hash_code;
        if (cached != 0) return cached;
        return c.MVM_string_compute_hash_code(ctx, key);
    }

    /// `str_hash_table_funcs.h:280-284`: pointer equality, then grapheme
    /// count, then the graphemes. The tiers pass (entry key, wanted key);
    /// the test is symmetric. The grapheme counts are the translated
    /// `MVM_string_graphs_nocheck` (a field read), inlined.
    pub inline fn eql(ctx: Ctx, a: Key, b: Key) bool {
        if (a == b) return true;
        const graphs = @call(.always_inline, c.MVM_string_graphs_nocheck, .{ ctx, a });
        return graphs == @call(.always_inline, c.MVM_string_graphs_nocheck, .{ ctx, b }) and
            c.MVM_string_substrings_equal_nocheck(ctx, a, 0, graphs, b, 0) != 0;
    }

    pub fn allocator(ctx: Ctx) std.mem.Allocator {
        _ = ctx;
        return moar.mvm_allocator;
    }

    pub fn tc(ctx: Ctx) *ThreadContext {
        return ctx;
    }

    pub fn salt(ctx: Ctx) u64 {
        return rng.salt(ctx.instance);
    }

    /// `Table.insert` of a present key. `insertNocheck` below does the C's
    /// own duplicate check (it needs the key for the message), so this is
    /// only reached through `StrTable.insert` directly.
    pub fn onDuplicate(ctx: Ctx) void {
        c.MVM_oops(ctx, "insert duplicate key");
    }
};

pub const StrTable = table.Table(StrSpec);

/// The C struct's pointer as the engine's handle.
pub inline fn handleOf(ht: *c.MVMStrHashTable) StrTable.Handle {
    return @ptrCast(&ht.table);
}

/// The stale check of a function `table.zig` cannot check (no ctx), with
/// the C's text for `MVM_str_hash_<who>`.
inline fn checkStale(tc: *ThreadContext, h: StrTable.Handle, comptime who: []const u8) void {
    if (h.*) |header| {
        if (@as(*volatile u8, &header.stale).* != 0)
            c.MVM_oops(tc, "MVM_str_hash_" ++ who ++ " called with a stale hashtable pointer");
    }
}

// -------------------------------------------------------------- sizing

/// MVM_round_up_log_base2 (`str_hash_table.c:12`, used by the index and
/// uni tables for their initial size): the log2 of `v` rounded up to a power
/// of two, with the De Bruijn table's results at the edges: 1 for `v == 1`
/// and 32 for `v == 0`.
pub fn roundUpLog2(v: u32) u32 {
    const w = v -% 1;
    return if (w == 0) 1 else 1 + @as(u32, std.math.log2_int(u32, w));
}

// ------------------------------------------------------------ lifetime

/// MVM_str_hash_build (`str_hash_table.c:158-200`).
pub fn build(tc: *ThreadContext, ht: *c.MVMStrHashTable, entry_size: u32, entries: u32) void {
    if (entry_size == 0 or entry_size > 255 or entry_size & 3 != 0)
        c.MVM_oops(tc, "Hash table entry_size %u is invalid", entry_size);
    StrTable.build(tc, handleOf(ht), entry_size, entries, standard_set);
}

/// The number of `MVMHashStrategy` values (`str_hash_table.h`).
pub const strategy_count: u8 = 4;

/// The tier set of each strategy, indexed by `MVMHashStrategy`; a null slot
/// is a strategy not built into this engine. A mapping rather than "the set
/// index is the strategy number", so `large_only` keeps index 1.
pub const strategy_sets = [strategy_count]?u8{ standard_set, null, null, null };

/// Whether `buildStrategy` can build `strategy`.
pub fn strategyAvailable(strategy: u8) bool {
    return strategy < strategy_count and strategy_sets[strategy] != null;
}

/// MVM_str_hash_build_strategy: `build` with the tier set of `strategy`; a
/// strategy this engine lacks throws.
pub fn buildStrategy(tc: *ThreadContext, ht: *c.MVMStrHashTable, entry_size: u32, entries: u32, strategy: u8) void {
    if (!strategyAvailable(strategy))
        c.MVM_exception_throw_adhoc(tc, "hash strategy %u is not available in this engine", @as(c_uint, strategy));
    if (entry_size == 0 or entry_size > 255 or entry_size & 3 != 0)
        c.MVM_oops(tc, "Hash table entry_size %u is invalid", entry_size);
    StrTable.build(tc, handleOf(ht), entry_size, entries, strategy_sets[strategy].?);
}

/// MVM_str_hash_seal: a no-op until a strategy compacts at seal.
pub fn seal(tc: *ThreadContext, ht: *c.MVMStrHashTable) void {
    _ = tc;
    _ = ht;
}

/// MVM_str_hash_demolish: frees the block (at a safepoint unless
/// control-only) and leaves the table unbuilt.
pub fn demolish(tc: *ThreadContext, ht: *c.MVMStrHashTable) void {
    StrTable.demolish(tc, handleOf(ht));
}

/// MVM_str_hash_count.
pub fn count(tc: *ThreadContext, ht: *c.MVMStrHashTable) c.MVMHashNumItems {
    const h = handleOf(ht);
    checkStale(tc, h, "count");
    return StrTable.count(h);
}

/// MVM_str_hash_entry_size: 0 means unbuilt.
pub fn entrySize(tc: *ThreadContext, ht: *c.MVMStrHashTable) c.MVMHashNumItems {
    const h = handleOf(ht);
    checkStale(tc, h, "entry_size");
    return StrTable.entrySize(h);
}

/// MVM_str_hash_is_empty.
pub fn isEmpty(tc: *ThreadContext, ht: *c.MVMStrHashTable) bool {
    const h = handleOf(ht);
    checkStale(tc, h, "is_empty");
    return StrTable.isEmpty(h);
}

/// MVM_str_hash_allocated_size: the block's size, for `unmanaged_size`.
pub fn allocatedSize(tc: *ThreadContext, ht: *c.MVMStrHashTable) usize {
    const h = handleOf(ht);
    checkStale(tc, h, "allocated_size");
    return StrTable.allocatedSize(h);
}

/// MVM_str_hash_shallow_copy: `dest` must be unbuilt; it gets a block copy
/// with the same layout and iteration order (an unbuilt source leaves it
/// unbuilt).
pub fn shallowCopy(tc: *ThreadContext, source: *c.MVMStrHashTable, dest: *c.MVMStrHashTable) void {
    StrTable.shallowCopy(tc, handleOf(source), handleOf(dest));
}

/// MVM_str_hash_fsck: the error count (0 is clean).
pub fn fsck(tc: *ThreadContext, ht: *c.MVMStrHashTable, mode: u32) u64 {
    return StrTable.fsck(tc, handleOf(ht), mode);
}

// ---------------------------------------------------------------- keys

/// MVM_str_hash_key_is_valid (`str_hash_table_funcs.h:366-371`), in its
/// order: not null (`MVM_is_null`: neither NULL nor VMNull), an MVMString,
/// concrete. All inline, no call.
pub inline fn keyIsValid(tc: *ThreadContext, key: [*c]c.MVMString) bool {
    const obj: [*c]c.MVMObject = @ptrCast(key);
    if (obj == null or obj == tc.instance.*.VMNull) return false;
    return moar.repr(obj).ID == c.MVM_REPR_ID_MVMString and moar.isConcrete(obj);
}

/// MVM_str_hash_key_throw_invalid.
pub fn keyThrowInvalid(tc: *ThreadContext, key: [*c]c.MVMString) noreturn {
    c.MVM_exception_throw_adhoc(tc, "Hash keys must be concrete strings (got %s)", c.MVM_6model_get_debug_name(tc, @ptrCast(key)));
}

inline fn checkKey(tc: *ThreadContext, key: [*c]c.MVMString) void {
    if (!keyIsValid(tc, key)) keyThrowInvalid(tc, key);
}

// -------------------------------------------------------------- access

/// MVM_str_hash_fetch_nocheck: the entry, or null. `inline`, as are
/// `deleteNocheck`, `fetch` and `delete`, with the table's `fetch`/`delete`
/// forced inline too, so each export is one function as the C's header
/// inline is.
pub inline fn fetchNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) ?*anyopaque {
    return @ptrCast(@call(.always_inline, StrTable.fetch, .{ tc, handleOf(ht), key }));
}

/// MVM_str_hash_lvalue_fetch_nocheck: the entry for `key`, created with a
/// NULL key (fill it in) if absent. Growth on an absent key only.
pub fn lvalueFetchNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) *anyopaque {
    return @ptrCast(StrTable.lvalueFetch(tc, handleOf(ht), key));
}

/// MVM_str_hash_insert_nocheck (`str_hash_table.c:505-516`): the key is
/// validated, a present key throws, a fresh entry gets its key stored.
pub fn insertNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) *anyopaque {
    const entry: *[*c]c.MVMString = @ptrCast(@alignCast(lvalueFetch(tc, ht, key)));
    if (entry.* != null) {
        const c_name = c.MVM_string_utf8_encode_C_string(tc, key);
        var waste = [_][*c]u8{ c_name, null };
        c.MVM_exception_throw_adhoc_free(tc, &waste, "insert duplicate key %s", c_name);
    }
    entry.* = key;
    return @ptrCast(entry);
}

/// MVM_str_hash_delete_nocheck: an absent key is a no-op.
pub inline fn deleteNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) void {
    _ = @call(.always_inline, StrTable.delete, .{ tc, handleOf(ht), key });
}

/// MVM_str_hash_fetch: `fetchNocheck` of a validated key.
pub inline fn fetch(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) ?*anyopaque {
    checkKey(tc, key);
    return fetchNocheck(tc, ht, key);
}

/// MVM_str_hash_lvalue_fetch: `lvalueFetchNocheck` of a validated key.
pub fn lvalueFetch(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) *anyopaque {
    checkKey(tc, key);
    return lvalueFetchNocheck(tc, ht, key);
}

/// MVM_str_hash_delete: `deleteNocheck` of a validated key.
pub inline fn delete(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) void {
    checkKey(tc, key);
    deleteNocheck(tc, ht, key);
}

// ----------------------------------------------------------- iteration
//
// `MVMStrHashIterator.pos` is the engine's position: 0 is the end, `start`
// is one before the first entry, `next` walks downward.

/// MVM_str_hash_at_end (`str_hash_table.h`).
pub fn atEnd(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) bool {
    checkStale(tc, handleOf(ht), "at_end");
    return iterator.pos == 0;
}

/// MVM_str_hash_first: at the end for an unbuilt or empty table.
pub fn first(tc: *ThreadContext, ht: *c.MVMStrHashTable) c.MVMStrHashIterator {
    const h = handleOf(ht);
    checkStale(tc, h, "iterator_first");
    return .{ .pos = StrTable.first(h) };
}

/// MVM_str_hash_next_nocheck: only when not at the end.
pub fn nextNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) c.MVMStrHashIterator {
    const h = handleOf(ht);
    checkStale(tc, h, "iterator_next_nocheck");
    return .{ .pos = StrTable.next(h, iterator.pos) };
}

/// MVM_str_hash_next: `nextNocheck` after the end check.
pub fn next(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) c.MVMStrHashIterator {
    if (iterator.pos == 0)
        c.MVM_oops(tc, "Calling str_hash_next when iterator is already at the end");
    return nextNocheck(tc, ht, iterator);
}

/// MVM_str_hash_start: the position before the first entry.
pub fn start(tc: *ThreadContext, ht: *c.MVMStrHashTable) c.MVMStrHashIterator {
    const h = handleOf(ht);
    checkStale(tc, h, "start");
    return .{ .pos = StrTable.start(h) };
}

/// MVM_str_hash_at_start.
pub fn atStart(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) bool {
    const h = handleOf(ht);
    checkStale(tc, h, "at_start");
    return StrTable.atStart(h, iterator.pos);
}

/// MVM_str_hash_current_nocheck: only when not at the end.
pub fn currentNocheck(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) *anyopaque {
    const h = handleOf(ht);
    checkStale(tc, h, "current_nocheck");
    const entry = StrTable.current(h, iterator.pos) orelse
        c.MVM_oops(tc, "MVM_str_hash_current_nocheck called with an iterator at the end");
    return @ptrCast(entry);
}

/// MVM_str_hash_current: null at the end (de-facto API).
pub fn current(tc: *ThreadContext, ht: *c.MVMStrHashTable, iterator: c.MVMStrHashIterator) ?*anyopaque {
    if (iterator.pos == 0) return null;
    return currentNocheck(tc, ht, iterator);
}

test "roundUpLog2 matches MVM_round_up_log_base2" {
    // The C's De Bruijn table (`str_hash_table.c:12`) returns 1 for v == 1
    // and 32 for v == 0 (which it says not to call it with); the tables that
    // use it only pass sizes.
    const cases = [_][2]u32{
        .{ 0, 32 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 2 }, .{ 4, 2 }, .{ 5, 3 }, .{ 133, 8 }, .{ 1 << 31, 31 }, .{ (1 << 31) + 1, 32 },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], roundUpLog2(case[0]));
}

test "set 0 is the standard string set" {
    // `table.zig` specialises dispatch for set 0, so the set every C-API
    // hash is built with must be index 0.
    comptime {
        std.debug.assert(sets[0].ptr == @as([*]const tier.TierEntry, &standard));
        std.debug.assert(sets[0].len == standard.len);
        std.debug.assert(standard_set == 0);
        std.debug.assert(StrTable.dispatch_reads_set);
    }
}
