//! The pointer table of the Zig hash engine (spec 11): `Table(Spec)`
//! instantiated for `const void *` keys, and the C-API-shaped functions that
//! `src/core/ptr_hash_table.c` and `ptr_hash_table_funcs.h` define today.
//! `ptr_exports.zig` exports them under the C names.
//!
//! The C struct is one pointer, `MVMPtrHashTable { table }`; its address is
//! the engine's `Handle`. Unbuilt is NULL (`MVM_ptr_hash_build` only stores
//! NULL), and the first `lvalue_fetch` allocates, as the C does. One rung:
//! Robin Hood without a salt, published plainly (no stale/CAS/safepoint
//! discipline: the C frees with `MVM_free`), so a `ctx` is nothing (`void`)
//! and the `tc` the C API takes is only for `MVM_oops`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const tier = @import("tier.zig");
const table = @import("table.zig");
const robinhood = @import("tiers/robinhood.zig");

const Header = table.Header;
const ThreadContext = moar.ThreadContext;

/// The one rung: the C's Robin Hood table, which has no salt.
pub const only_rung = [_]tier.TierEntry{
    .{ .tier = robinhood.Tier(.{ .salt = .none }), .from = 0 },
};

pub const PtrSpec = struct {
    pub const Key = ?*const anyopaque;
    pub const Ctx = void;
    pub const runtime_entry_size = false;
    pub const entry_size: u32 = @sizeOf(c.MVMPtrHashEntry);
    pub const publish: table.Publish = .plain;
    pub const sets: []const tier.TierSet = &.{&only_rung};

    /// MVM_ptr_hash_code (`ptr_hash_table_funcs.h:68`).
    pub fn hash(ctx: Ctx, key: Key) u64 {
        _ = ctx;
        return @intFromPtr(key) *% 11400714819323198485;
    }

    pub fn eql(ctx: Ctx, a: Key, b: Key) bool {
        _ = ctx;
        return a == b;
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
        @panic("ptr hash: insert of a present key");
    }
};

pub const PtrTable = table.Table(PtrSpec);

comptime {
    std.debug.assert(@offsetOf(c.MVMPtrHashEntry, "key") == 0);
    std.debug.assert(@sizeOf(c.MVMPtrHashEntry) % 8 == 0);
}

/// The C struct's pointer as the engine's handle.
pub inline fn handleOf(ht: *c.MVMPtrHashTable) PtrTable.Handle {
    return @ptrCast(&ht.table);
}

/// `MVM_ptr_hash_build`: doesn't allocate; the table is unbuilt until the
/// first `lvalueFetch`.
pub fn build(tc: *ThreadContext, ht: *c.MVMPtrHashTable) void {
    _ = tc;
    ht.table = null;
}

/// `MVM_ptr_hash_demolish`: frees the block and leaves the table unbuilt.
pub fn demolish(tc: *ThreadContext, ht: *c.MVMPtrHashTable) void {
    _ = tc;
    PtrTable.demolish({}, handleOf(ht));
}

/// `MVM_ptr_hash_is_empty`: true when unbuilt too.
pub fn isEmpty(tc: *ThreadContext, ht: *c.MVMPtrHashTable) bool {
    _ = tc;
    return PtrTable.isEmpty(handleOf(ht));
}

/// `MVM_ptr_hash_fetch`: the entry, or null.
pub fn fetch(tc: *ThreadContext, ht: *c.MVMPtrHashTable, key: ?*const anyopaque) ?*c.MVMPtrHashEntry {
    _ = tc;
    const e = PtrTable.fetch({}, handleOf(ht), key) orelse return null;
    return @ptrCast(@alignCast(e));
}

/// `MVM_ptr_hash_lvalue_fetch` (`ptr_hash_table.c:253-278`): the entry for
/// `key`, created with a NULL key (fill it in) if absent. An unbuilt table
/// gets its first block here, sized as the C's PTR_INITIAL_SIZE_LOG2 (the
/// tier's minimum, 8 official slots). Growth on an absent key only.
pub fn lvalueFetch(tc: *ThreadContext, ht: *c.MVMPtrHashTable, key: ?*const anyopaque) *c.MVMPtrHashEntry {
    _ = tc;
    const h = handleOf(ht);
    if (h.* == null) PtrTable.build({}, h, 0, 1, 0);
    return @ptrCast(@alignCast(PtrTable.lvalueFetch({}, h, key)));
}

/// `MVM_ptr_hash_insert` (`ptr_hash_table.c:284-299`): stores `value` under
/// `key`; a present key with the same value is a no-op, with a different
/// value an `MVM_oops`.
pub fn insert(tc: *ThreadContext, ht: *c.MVMPtrHashTable, key: ?*const anyopaque, value: usize) void {
    const entry = lvalueFetch(tc, ht, key);
    if (entry.key != null) {
        if (value != entry.value) {
            // The C also prints the bucket, which is the tier's business now.
            c.MVM_oops(tc, "insert conflict, %p is %llu != %llu", key, @as(c_ulonglong, value), @as(c_ulonglong, entry.value));
        }
    } else {
        entry.key = key;
        entry.value = value;
    }
}

/// `MVM_ptr_hash_fetch_and_delete` (`ptr_hash_table.c:301-387`): removes
/// `key`'s entry and returns its value, 0 when absent. Two probes: the
/// value is read once from the fetched entry, then `Table.delete` runs the
/// tier's delete (a single probe while the log hook is a no-op); the C does
/// it in one, which would need a delete-by-entry in the tier interface.
pub fn fetchAndDelete(tc: *ThreadContext, ht: *c.MVMPtrHashTable, key: ?*const anyopaque) usize {
    _ = tc;
    const h = handleOf(ht);
    const e: *c.MVMPtrHashEntry = @ptrCast(@alignCast(PtrTable.fetch({}, h, key) orelse return 0));
    const value = e.value;
    const removed = PtrTable.delete({}, h, key);
    std.debug.assert(removed);
    return value;
}
