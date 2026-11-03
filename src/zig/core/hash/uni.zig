//! The Unicode table of the Zig hash engine (spec 11): `Table(Spec)` over
//! `MVMUniHashEntry { const char *key; MVMuint32 hash_val; MVMint32 value }`
//! entries with C-string keys, and the C-API-shaped functions that
//! `src/core/uni_hash_table.c` and `uni_hash_table_funcs.h` define today.
//! `uni_exports.zig` exports them under the C names.
//!
//! Keys. The C compares an entry's cached `hash_val` before `strcmp`, so
//! `Spec.Key` is the entry's first two fields (`UniKey`, which with its
//! padding spans the whole 16-byte entry): a lookup builds one from the
//! wanted string and its hash, `hash` returns the cached value, `eql` is the
//! C's test. The C struct is one pointer, `MVMUniHashTable { table }`; its
//! address is the engine's `Handle`. One rung: Robin Hood without a salt,
//! published plainly (the C frees with `MVM_free`); `Ctx` is nothing, and
//! the `tc` the C API takes is only for `MVM_oops`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const tier = @import("tier.zig");
const table = @import("table.zig");
const robinhood = @import("tiers/robinhood.zig");
const swiss = @import("tiers/swiss.zig");

const Header = table.Header;
const ThreadContext = moar.ThreadContext;

/// The one rung: the C's Robin Hood table, which has no salt.
pub const only_rung = [_]tier.TierEntry{
    .{ .tier = robinhood.Tier(.{ .salt = .none }), .from = 0 },
};

/// The Swiss tier from the first entry: the LOOKUP strategy
/// (`MVM_HASH_STRATEGY_LOOKUP`, 1). Entry size 16 is a multiple of 8, and a
/// null `key` marks an unfilled slot.
pub const swiss_rung = [_]tier.TierEntry{
    .{ .tier = swiss.Tier(.{}), .from = 0 },
};

/// Set index of `only_rung`, what `build` uses: it must stay 0.
pub const default_set: u8 = 0;
/// Set index of `swiss_rung`, the LOOKUP strategy's set.
pub const lookup_set: u8 = 1;

/// The key fields of `MVMUniHashEntry`.
pub const UniKey = extern struct {
    key: [*c]const u8,
    hash_val: u32,
};

comptime {
    std.debug.assert(@offsetOf(c.MVMUniHashEntry, "key") == @offsetOf(UniKey, "key"));
    std.debug.assert(@offsetOf(c.MVMUniHashEntry, "hash_val") == @offsetOf(UniKey, "hash_val"));
    std.debug.assert(@sizeOf(UniKey) <= @sizeOf(c.MVMUniHashEntry));
    std.debug.assert(@sizeOf(c.MVMUniHashEntry) % 8 == 0);
}

/// MVM_uni_hash_code (`uni_hash_table_funcs.h:49-60`): 32-bit FNV-1a of the
/// bytes (each read as a C `char`, so sign-extended where `char` is signed),
/// times the 32-bit Fibonacci constant.
pub fn hashCode(key: [*c]const u8, len: usize) u32 {
    var hash: u32 = 0x811c9dc5;
    for (key[0..len]) |byte| {
        const ch: c_char = @bitCast(byte);
        hash ^= @as(u32, @bitCast(@as(i32, ch)));
        hash *%= 0x01000193;
    }
    return hash *% 0x9e3779b7;
}

/// The cached 32-bit hash as 64 bits (spec decision 9: a fixed mixing step,
/// not a new hash). The Swiss tier takes its 7-bit tag from the top bits and
/// its home group from the low bits; a bare 32-bit value has zero top bits.
/// The multiply spreads the low bits upward, the shifted copy keeps the
/// low 32 bits distinct from the multiply's.
pub inline fn widen(h: u32) u64 {
    return (@as(u64, h) *% 0x9E3779B97F4A7C15) ^ (@as(u64, h) << 32);
}

pub const UniSpec = struct {
    pub const Key = UniKey;
    pub const Ctx = void;
    pub const runtime_entry_size = false;
    pub const entry_size: u32 = @sizeOf(c.MVMUniHashEntry);
    pub const publish: table.Publish = .plain;
    pub const sets: []const tier.TierSet = &.{ &only_rung, &swiss_rung };

    pub fn hash(ctx: Ctx, key: Key) u64 {
        _ = ctx;
        return widen(key.hash_val);
    }

    /// `uni_hash_table_funcs.h:120`: the cached hash, then `strcmp`.
    pub fn eql(ctx: Ctx, a: Key, b: Key) bool {
        _ = ctx;
        return a.hash_val == b.hash_val and c.strcmp(a.key, b.key) == 0;
    }

    pub fn allocator(ctx: Ctx) std.mem.Allocator {
        _ = ctx;
        return moar.mvm_allocator;
    }

    /// Only `Table.insert` reaches this, and nothing here calls it:
    /// `insert` below does the C's own conflict check, which needs the key
    /// and a `tc`.
    pub fn onDuplicate(ctx: Ctx) void {
        _ = ctx;
        @panic("uni hash: insert of a present key");
    }
};

pub const UniTable = table.Table(UniSpec);

/// The C struct's pointer as the engine's handle.
pub inline fn handleOf(ht: *c.MVMUniHashTable) UniTable.Handle {
    return @ptrCast(&ht.table);
}

fn wanted(key: [*c]const u8) UniKey {
    return .{ .key = key, .hash_val = hashCode(key, std.mem.len(key)) };
}

/// `MVM_uni_hash_build` (`uni_hash_table.c:62-79`): sized for `entries`
/// (a control-only block for 0).
pub fn build(tc: *ThreadContext, ht: *c.MVMUniHashTable, entries: u32) void {
    _ = tc;
    UniTable.build({}, handleOf(ht), 0, entries, 0);
}

/// The tier set of each `MVMHashStrategy`; null is a strategy the uni kind
/// lacks (APPEND).
const strategy_sets = [3]?u8{ default_set, lookup_set, null };

/// Whether `buildStrategy` can build `strategy`.
pub fn strategyAvailable(strategy: u8) bool {
    return strategy < strategy_sets.len and strategy_sets[strategy] != null;
}

/// `MVM_uni_hash_build_strategy`: `build` with the tier set of `strategy`;
/// a strategy this kind lacks throws.
pub fn buildStrategy(tc: *ThreadContext, ht: *c.MVMUniHashTable, entries: u32, strategy: u8) void {
    if (!strategyAvailable(strategy))
        c.MVM_exception_throw_adhoc(tc, "hash strategy %u is not available in this engine", @as(c_uint, strategy));
    UniTable.build({}, handleOf(ht), 0, entries, strategy_sets[strategy].?);
}

/// `MVM_uni_hash_demolish`: frees the block and leaves the table unbuilt.
pub fn demolish(tc: *ThreadContext, ht: *c.MVMUniHashTable) void {
    _ = tc;
    UniTable.demolish({}, handleOf(ht));
}

/// `MVM_uni_hash_is_empty`: true when unbuilt too.
pub fn isEmpty(tc: *ThreadContext, ht: *c.MVMUniHashTable) bool {
    _ = tc;
    return UniTable.isEmpty(handleOf(ht));
}

/// `MVM_uni_hash_fetch`: the entry, or null.
pub fn fetch(tc: *ThreadContext, ht: *c.MVMUniHashTable, key: [*c]const u8) ?*c.MVMUniHashEntry {
    _ = tc;
    const e = UniTable.fetch({}, handleOf(ht), wanted(key)) orelse return null;
    return @ptrCast(@alignCast(e));
}

/// `MVM_uni_hash_lvalue_fetch` (`uni_hash_table.c:276-304`, private to the
/// C file): the entry for `key`, created with a NULL key (fill it in) if
/// absent; an unbuilt table is built first. Growth on an absent key only.
fn lvalueFetch(tc: *ThreadContext, ht: *c.MVMUniHashTable, key: [*c]const u8) *c.MVMUniHashEntry {
    const h = handleOf(ht);
    if (h.* == null) build(tc, ht, 0);
    return @ptrCast(@alignCast(UniTable.lvalueFetch({}, h, wanted(key))));
}

/// `MVM_uni_hash_insert` (`uni_hash_table.c:310-324`): stores `value` under
/// `key`; a present key with the same value is a no-op, with a different
/// value an `MVM_oops`.
pub fn insert(tc: *ThreadContext, ht: *c.MVMUniHashTable, key: [*c]const u8, value: i32) void {
    const entry = lvalueFetch(tc, ht, key);
    if (entry.key != null) {
        if (value != entry.value) {
            const hash_val = hashCode(key, std.mem.len(key));
            c.MVM_oops(tc, "insert conflict, %s is %u, %i != %i", key, hash_val, value, entry.value);
        }
    } else {
        // The C's insert loop stored hash_val; here the fresh entry's key
        // fields are all zero.
        entry.key = key;
        entry.hash_val = hashCode(key, std.mem.len(key));
        entry.value = value;
    }
}

/// `MVM_uni_hash_fsck` (no `tc`): the error count (0 is clean).
pub fn fsck(ht: *c.MVMUniHashTable, mode: u32) u64 {
    return UniTable.fsck({}, handleOf(ht), mode);
}
