//! The fixkey table of the Zig hash engine (spec 11): `Table(Spec)` over
//! entries that are pointers to separately allocated structs whose first
//! word is the `MVMString *` key, and the C-API-shaped functions that
//! `src/core/fixkey_hash_table.c` and `fixkey_hash_table_funcs.h` define
//! today. `fixkey_exports.zig` exports them under the C names.
//!
//! Keys. The table's entry is the indirection pointer (`MVMString **`, the C's
//! `MVMString ***` entry), so that is `Spec.Key`: `hash` and `eql` read the
//! string through it. A lookup passes the address of a local holding the
//! wanted string, so one `Key` type serves stored and wanted keys alike and
//! the lookup key is never stored (the engine inserts a zeroed key for the
//! caller to fill).
//!
//! The caller's entry size. The C keeps it in its control struct as a u16
//! (`fixkey_hash_table.h:92`, up to 1024); the engine's `Header.entry_size`
//! is a byte and, for a fixed-size Spec, unused. So `MVMFixKeyHashTable.table`
//! points at a `Control` of this file's own: the engine's handle target and
//! the u16, allocated by `build` and freed by `demolish`. Unbuilt is NULL, as
//! in C. One rung: Robin Hood without a salt, published plainly (the C frees
//! with `MVM_free`); `Ctx` is the `tc` the string functions need.
//!
//! `foreach` visits the entries in the engine's iteration order (descending
//! buckets); the C walks ascending. Its one caller (`free_lib` in
//! `src/moar.c`) does not care.
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

/// The struct behind the indirection: its first word is the key.
pub const Indirection = [*c][*c]c.MVMString;

pub const FixKeySpec = struct {
    pub const Key = Indirection;
    pub const Ctx = *ThreadContext;
    pub const runtime_entry_size = false;
    pub const entry_size: u32 = @sizeOf(Key);
    pub const publish: table.Publish = .plain;
    pub const sets: []const tier.TierSet = &.{&only_rung};

    pub fn hash(ctx: Ctx, key: Key) u64 {
        return c.MVM_string_hash_code(ctx, key.*);
    }

    /// `fixkey_hash_table_funcs.h:99-104`: pointer equality, then grapheme
    /// count, then the graphemes. A struct whose key the caller has not
    /// filled in yet (NULL first word) matches nothing.
    pub fn eql(ctx: Ctx, a: Key, b: Key) bool {
        const sa = a.*;
        const sb = b.*;
        if (sa == sb) return true;
        if (sa == null or sb == null) return false;
        const graphs = c.MVM_string_graphs_nocheck(ctx, sa);
        return graphs == c.MVM_string_graphs_nocheck(ctx, sb) and
            c.MVM_string_substrings_equal_nocheck(ctx, sa, 0, graphs, sb, 0) != 0;
    }

    pub fn allocator(ctx: Ctx) std.mem.Allocator {
        _ = ctx;
        return moar.mvm_allocator;
    }

    /// Only `Table.insert` reaches this, and nothing here calls it:
    /// `insertNocheck` does the C's own duplicate check.
    pub fn onDuplicate(ctx: Ctx) void {
        c.MVM_oops(ctx, "duplicate key in fixkey_hash_insert");
    }
};

pub const FixKeyTable = table.Table(FixKeySpec);

/// What `MVMFixKeyHashTable.table` points at (see the file comment).
pub const Control = extern struct {
    /// The engine's table: `&header` is the `Handle`.
    header: ?*Header,
    /// The caller's entry size; 0 means the caller supplies the storage.
    entry_size: u16,
};

pub inline fn controlOf(ht: *c.MVMFixKeyHashTable) ?*Control {
    return @ptrCast(@alignCast(ht.table));
}

pub inline fn handleOf(control: *Control) FixKeyTable.Handle {
    return &control.header;
}

fn keyAt(entry: [*]u8) *Indirection {
    return @ptrCast(@alignCast(entry));
}

/// `MVM_fixkey_hash_build` (`fixkey_hash_table.c:83-90`): the control and
/// the first block (8 official slots, as FIXKEY_INITIAL_SIZE_LOG2);
/// `entry_size` is at most 1024 and a multiple of 4, 0 being the static
/// storage mode.
pub fn build(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, entry_size: u32) void {
    if (entry_size > 1024 or entry_size & 3 != 0)
        c.MVM_oops(tc, "Hash table entry_size %u is invalid", entry_size);
    const control = moar.mvm_allocator.create(Control) catch c.MVM_oops(tc, "hash table: allocation failed");
    control.* = .{ .header = null, .entry_size = @intCast(entry_size) };
    FixKeyTable.build(tc, handleOf(control), 0, 1, 0);
    ht.table = @ptrCast(control);
}

/// `MVM_fixkey_hash_demolish` (`fixkey_hash_table.c:15-38`): frees the
/// entries it allocated (`entry_size != 0`), the block and the control, and
/// leaves the table unbuilt.
pub fn demolish(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable) void {
    const control = controlOf(ht) orelse return;
    const h = handleOf(control);
    if (control.entry_size != 0) {
        var pos = FixKeyTable.first(h);
        while (pos != 0) : (pos = FixKeyTable.next(h, pos)) {
            const indirection = keyAt(FixKeyTable.current(h, pos).?).*;
            if (indirection != null) c.MVM_free(@ptrCast(indirection));
        }
    }
    FixKeyTable.demolish(tc, h);
    moar.mvm_allocator.destroy(control);
    ht.table = null;
}

/// `MVM_fixkey_hash_is_empty`: true when unbuilt too.
pub fn isEmpty(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable) bool {
    _ = tc;
    const control = controlOf(ht) orelse return true;
    return FixKeyTable.isEmpty(handleOf(control));
}

/// `MVM_fixkey_hash_fetch_nocheck`: the struct behind the indirection, or
/// null.
pub fn fetchNocheck(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, key: [*c]c.MVMString) ?*anyopaque {
    const control = controlOf(ht) orelse return null;
    var want = key;
    const entry = FixKeyTable.fetch(tc, handleOf(control), &want) orelse return null;
    return @ptrCast(keyAt(entry).*);
}

/// `MVM_fixkey_hash_lvalue_fetch_nocheck` (`fixkey_hash_table.c:300-348`).
/// With `entry_size != 0`: the struct for `key`, freshly `MVM_malloc`ed with
/// a NULL first word (fill it in) if absent. With `entry_size == 0`: the
/// address of the indirection pointer inside the hash, for the caller to
/// assign its storage to. Growth on an absent key only.
pub fn lvalueFetchNocheck(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, key: [*c]c.MVMString) *anyopaque {
    const control = controlOf(ht) orelse
        c.MVM_oops(tc, "Attempting insert on MVM_fixkey_hash without setting entry_size");
    var want = key;
    const indirection = keyAt(FixKeyTable.lvalueFetch(tc, handleOf(control), &want));
    if (indirection.* == null) {
        if (control.entry_size == 0) return @ptrCast(indirection);
        // MVM_malloc panics rather than returning null.
        const entry: Indirection = @ptrCast(@alignCast(c.MVM_malloc(control.entry_size) orelse unreachable));
        entry.* = null;
        indirection.* = entry;
    }
    return @ptrCast(indirection.*);
}

/// `MVM_fixkey_hash_insert_nocheck` (`fixkey_hash_table.c:354-369`): a
/// present key is an `MVM_oops`; with `entry_size != 0` the fresh struct
/// gets its key stored, with `entry_size == 0` the indirection's address is
/// returned for the caller to assign.
pub fn insertNocheck(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, key: [*c]c.MVMString) *anyopaque {
    const new_entry: Indirection = @ptrCast(@alignCast(lvalueFetchNocheck(tc, ht, key)));
    if (new_entry.* != null) {
        c.MVM_oops(tc, "duplicate key in fixkey_hash_insert");
    } else if (controlOf(ht).?.entry_size != 0) {
        new_entry.* = key;
    }
    return @ptrCast(new_entry);
}

pub const Callback = ?*const fn ([*c]c.MVMThreadContext, ?*anyopaque, ?*anyopaque) callconv(.c) void;

/// `MVM_fixkey_hash_foreach`: `callback(tc, entry, arg)` for every entry's
/// struct.
pub fn foreach(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, callback: Callback, arg: ?*anyopaque) void {
    const control = controlOf(ht) orelse return;
    const h = handleOf(control);
    var pos = FixKeyTable.first(h);
    while (pos != 0) : (pos = FixKeyTable.next(h, pos)) {
        const indirection = keyAt(FixKeyTable.current(h, pos).?).*;
        callback.?(tc, @ptrCast(indirection), arg);
    }
}

/// `MVM_fixkey_hash_fsck`: the error count (0 is clean).
pub fn fsck(tc: *ThreadContext, ht: *c.MVMFixKeyHashTable, mode: u32) u64 {
    const control = controlOf(ht) orelse return 0;
    return FixKeyTable.fsck(tc, handleOf(control), mode);
}
