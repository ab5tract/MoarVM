//! The index table of the Zig hash engine (spec 11): `Table(Spec)` over
//! entries that are indices into a caller-supplied `MVMString **list`, and
//! the C-API-shaped functions that `src/core/index_hash_table.c` and
//! `index_hash_table_funcs.h` define today. `index_exports.zig` exports them
//! under the C names.
//!
//! Keys. The string of an entry is `list[index]`, and the list is an
//! argument of every call (the caller may reallocate it), so `Ctx` carries
//! `(tc, list)` and `Key` is a `u32` meaning:
//!
//!     1 + index   a stored key: the string is `list[index]`. The engine
//!                 treats an all-zero key as "not filled in yet", so index 0
//!                 cannot be stored as 0.
//!     0           the lookup key (`lookup`): the string is `Ctx.want`. It is
//!                 never stored.
//!
//! `eql` of two stored keys compares the indices, as the C's insert does
//! (`index_hash_table.c:160-165`: equal strings under different indices are
//! distinct entries); `eql` with the lookup key compares the strings, as
//! the C's fetch does. Entries are 8 bytes (the tier's unit), the index in
//! the first four; the C's 4-byte `MVMIndexHashEntry` is no longer read by
//! anything. One rung: Robin Hood without a salt, published plainly (the C
//! frees with `MVM_free`).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const tier = @import("tier.zig");
const table = @import("table.zig");
const str = @import("str.zig");
const robinhood = @import("tiers/robinhood.zig");

const Header = table.Header;
const ThreadContext = moar.ThreadContext;

pub const not_found: u32 = c.MVM_INDEX_HASH_NOT_FOUND;

/// The one rung: the C's Robin Hood table, which has no salt.
pub const only_rung = [_]tier.TierEntry{
    .{ .tier = robinhood.Tier(.{ .salt = .none }), .from = 0 },
};

pub const IndexSpec = struct {
    pub const Key = u32;
    pub const Ctx = struct {
        tc: *ThreadContext,
        list: [*c][*c]c.MVMString,
        /// The string a lookup wants (the key `lookup`).
        want: [*c]c.MVMString = null,
    };
    pub const runtime_entry_size = false;
    pub const entry_size: u32 = 8;
    pub const publish: table.Publish = .plain;
    pub const sets: []const tier.TierSet = &.{&only_rung};

    /// The lookup key (see the file comment).
    pub const lookup: Key = 0;

    fn stringOf(ctx: Ctx, key: Key) [*c]c.MVMString {
        return if (key == lookup) ctx.want else ctx.list[key - 1];
    }

    pub fn hash(ctx: Ctx, key: Key) u64 {
        return c.MVM_string_hash_code(ctx.tc, stringOf(ctx, key));
    }

    /// `index_hash_table_funcs.h:119-125` for a lookup: pointer equality,
    /// then grapheme count, then the graphemes. Two stored keys: the indices.
    pub fn eql(ctx: Ctx, a: Key, b: Key) bool {
        if (a != lookup and b != lookup) return a == b;
        const sa = stringOf(ctx, a);
        const sb = stringOf(ctx, b);
        if (sa == sb) return true;
        const graphs = c.MVM_string_graphs_nocheck(ctx.tc, sa);
        return graphs == c.MVM_string_graphs_nocheck(ctx.tc, sb) and
            c.MVM_string_substrings_equal_nocheck(ctx.tc, sa, 0, graphs, sb, 0) != 0;
    }

    pub fn allocator(ctx: Ctx) std.mem.Allocator {
        _ = ctx;
        return moar.mvm_allocator;
    }

    /// Only `Table.insert` reaches this, and nothing here calls it:
    /// `insertNocheck` does the C's own duplicate check (it needs the index
    /// for the message).
    pub fn onDuplicate(ctx: Ctx) void {
        c.MVM_oops(ctx.tc, "insert duplicate");
    }
};

pub const IndexTable = table.Table(IndexSpec);

/// The C struct's pointer as the engine's handle.
pub inline fn handleOf(ht: *c.MVMIndexHashTable) IndexTable.Handle {
    return @ptrCast(&ht.table);
}

fn keyAt(entry: [*]u8) *u32 {
    return @ptrCast(@alignCast(entry));
}

/// A ctx for the calls that take no list (nothing hashes).
inline fn listless(tc: *ThreadContext) IndexSpec.Ctx {
    return .{ .tc = tc, .list = null };
}

/// `MVM_index_hash_build` (`index_hash_table.c:71-88`): sized for
/// `entries` (a control-only block for 0).
pub fn build(tc: *ThreadContext, ht: *c.MVMIndexHashTable, entries: u32) void {
    IndexTable.build(listless(tc), handleOf(ht), 0, entries, 0);
}

/// `MVM_index_hash_demolish`: frees the block and leaves the table unbuilt.
pub fn demolish(tc: *ThreadContext, ht: *c.MVMIndexHashTable) void {
    IndexTable.demolish(listless(tc), handleOf(ht));
}

/// `MVM_index_hash_built`: whether `build` has been called.
pub fn built(tc: *ThreadContext, ht: *c.MVMIndexHashTable) bool {
    _ = tc;
    return ht.table != null;
}

/// `MVM_index_hash_is_empty`: true when unbuilt too.
pub fn isEmpty(tc: *ThreadContext, ht: *c.MVMIndexHashTable) bool {
    _ = tc;
    return IndexTable.isEmpty(handleOf(ht));
}

/// `MVM_index_hash_allocated_size`: the block's size, for `unmanaged_size`.
pub fn allocatedSize(tc: *ThreadContext, ht: *c.MVMIndexHashTable) usize {
    _ = tc;
    return IndexTable.allocatedSize(handleOf(ht));
}

/// `MVM_index_hash_shallow_copy`: `dest` must be unbuilt; it gets a block
/// copy (an unbuilt source leaves it untouched, as in C).
pub fn shallowCopy(tc: *ThreadContext, source: *c.MVMIndexHashTable, dest: *c.MVMIndexHashTable) void {
    if (source.table == null) return;
    IndexTable.shallowCopy(listless(tc), handleOf(source), handleOf(dest));
}

/// `MVM_index_hash_insert_nocheck` (`index_hash_table.c:291-308`): stores
/// `idx`, whose string is `list[idx]`; a present index is an `MVM_oops`.
/// Grows when full. `idx` cannot be MVM_INDEX_HASH_NOT_FOUND (the C could
/// not find it again either).
pub fn insertNocheck(tc: *ThreadContext, ht: *c.MVMIndexHashTable, list: [*c][*c]c.MVMString, idx: u32) void {
    std.debug.assert(idx != not_found);
    const ctx: IndexSpec.Ctx = .{ .tc = tc, .list = list };
    const key = keyAt(IndexTable.lvalueFetch(ctx, handleOf(ht), idx + 1));
    if (key.* != 0) c.MVM_oops(tc, "insert duplicate for %u", idx);
    key.* = idx + 1;
}

/// `MVM_index_hash_fetch_nocheck`: the index whose `list` string equals
/// `want`, or MVM_INDEX_HASH_NOT_FOUND.
pub fn fetchNocheck(tc: *ThreadContext, ht: *c.MVMIndexHashTable, list: [*c][*c]c.MVMString, want: [*c]c.MVMString) u32 {
    const ctx: IndexSpec.Ctx = .{ .tc = tc, .list = list, .want = want };
    const entry = IndexTable.fetch(ctx, handleOf(ht), IndexSpec.lookup) orelse return not_found;
    return keyAt(entry).* - 1;
}

/// `MVM_index_hash_fetch`: `fetchNocheck` of a validated key.
pub fn fetch(tc: *ThreadContext, ht: *c.MVMIndexHashTable, list: [*c][*c]c.MVMString, want: [*c]c.MVMString) u32 {
    if (!str.keyIsValid(tc, want)) str.keyThrowInvalid(tc, want);
    return fetchNocheck(tc, ht, list, want);
}
