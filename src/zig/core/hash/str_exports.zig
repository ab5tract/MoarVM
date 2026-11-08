//! The C symbols of the string table (spec 3.1, 7), exported from
//! `str.zig`'s functions of the same shape. Under `MVM_ZIG_IMPL` (config.h,
//! when the Zig groups are on) `str_hash_table.h` and
//! `str_hash_table_funcs.h` declare these extern, and build/sources.list's
//! [zig] section drops `src/core/str_hash_table.c`. Each export takes the
//! translated C types so the ABI is the header's declaration exactly, and
//! is one call into `str.zig`. `MVM_str_hash_at_end` stays inline in the
//! header and `MVM_str_hash_key_is_valid`/`_key_throw_invalid` keep their C
//! inline bodies (the other tables use them), so none of those is here.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const stats = @import("stats.zig");
const str = @import("str.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMStrHashTable;
const Key = [*c]c.MVMString;
const Iterator = c.MVMStrHashIterator;

// ------------------------------------------------------------ lifetime

fn MVM_str_hash_build(tc: Tc, hashtable: Ht, entry_size: u32, entries: u32) callconv(.c) void {
    str.build(tc, hashtable, entry_size, entries);
}

/// The `-Dhash-stats` twin of `MVM_str_hash_build`: out of line, so `@returnAddress()` is
/// the C caller's call site, which names the statistics site of a table built here.
noinline fn MVM_str_hash_build_stats(tc: Tc, hashtable: Ht, entry_size: u32, entries: u32) callconv(.c) void {
    stats.setPendingSite(@returnAddress());
    str.build(tc, hashtable, entry_size, entries);
}

fn MVM_str_hash_build_strategy(tc: Tc, hashtable: Ht, entry_size: u32, entries: u32, strategy: u8) callconv(.c) void {
    str.buildStrategy(tc, hashtable, entry_size, entries, strategy);
}

/// The `-Dhash-stats` twin of `MVM_str_hash_build_strategy`: out of line, so `@returnAddress()` is
/// the C caller's call site, which names the statistics site of a table built here.
noinline fn MVM_str_hash_build_strategy_stats(tc: Tc, hashtable: Ht, entry_size: u32, entries: u32, strategy: u8) callconv(.c) void {
    stats.setPendingSite(@returnAddress());
    str.buildStrategy(tc, hashtable, entry_size, entries, strategy);
}

fn MVM_str_hash_demolish(tc: Tc, hashtable: Ht) callconv(.c) void {
    str.demolish(tc, hashtable);
}

fn MVM_str_hash_count(tc: Tc, hashtable: Ht) callconv(.c) c.MVMHashNumItems {
    return str.count(tc, hashtable);
}

fn MVM_str_hash_entry_size(tc: Tc, hashtable: Ht) callconv(.c) c.MVMHashNumItems {
    return str.entrySize(tc, hashtable);
}

fn MVM_str_hash_is_empty(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(str.isEmpty(tc, hashtable));
}

fn MVM_str_hash_allocated_size(tc: Tc, hashtable: Ht) callconv(.c) usize {
    return str.allocatedSize(tc, hashtable);
}

fn MVM_str_hash_shallow_copy(tc: Tc, source: Ht, dest: Ht) callconv(.c) void {
    str.shallowCopy(tc, source, dest);
}

fn MVM_str_hash_fsck(tc: Tc, hashtable: Ht, mode: u32) callconv(.c) u64 {
    return str.fsck(tc, hashtable, mode);
}

// -------------------------------------------------------------- access

fn MVM_str_hash_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return str.fetchNocheck(tc, hashtable, key);
}

fn MVM_str_hash_lvalue_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return str.lvalueFetchNocheck(tc, hashtable, key);
}

fn MVM_str_hash_insert_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return str.insertNocheck(tc, hashtable, key);
}

fn MVM_str_hash_delete_nocheck(tc: Tc, hashtable: Ht, want: Key) callconv(.c) void {
    str.deleteNocheck(tc, hashtable, want);
}

fn MVM_str_hash_fetch(tc: Tc, hashtable: Ht, want: Key) callconv(.c) ?*anyopaque {
    return str.fetch(tc, hashtable, want);
}

fn MVM_str_hash_lvalue_fetch(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return str.lvalueFetch(tc, hashtable, key);
}

fn MVM_str_hash_delete(tc: Tc, hashtable: Ht, want: Key) callconv(.c) void {
    str.delete(tc, hashtable, want);
}

// ----------------------------------------------------------- iteration

fn MVM_str_hash_first(tc: Tc, hashtable: Ht) callconv(.c) Iterator {
    return str.first(tc, hashtable);
}

fn MVM_str_hash_next_nocheck(tc: Tc, hashtable: Ht, iterator: Iterator) callconv(.c) Iterator {
    return str.nextNocheck(tc, hashtable, iterator);
}

fn MVM_str_hash_next(tc: Tc, hashtable: Ht, iterator: Iterator) callconv(.c) Iterator {
    return str.next(tc, hashtable, iterator);
}

fn MVM_str_hash_start(tc: Tc, hashtable: Ht) callconv(.c) Iterator {
    return str.start(tc, hashtable);
}

fn MVM_str_hash_at_start(tc: Tc, hashtable: Ht, iterator: Iterator) callconv(.c) c_int {
    return @intFromBool(str.atStart(tc, hashtable, iterator));
}

fn MVM_str_hash_current_nocheck(tc: Tc, hashtable: Ht, iterator: Iterator) callconv(.c) ?*anyopaque {
    return str.currentNocheck(tc, hashtable, iterator);
}

fn MVM_str_hash_current(tc: Tc, hashtable: Ht, iterator: Iterator) callconv(.c) ?*anyopaque {
    return str.current(tc, hashtable, iterator);
}

// -------------------------------------------------------------- sizing

/// Still defined by `str_hash_table.c`, which the [zig] line drops; the index
/// and uni tables call it for their initial size.
fn MVM_round_up_log_base2(v: u32) callconv(.c) u32 {
    return str.roundUpLog2(v);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers (the benchmark shim, NativeCall), while
// calls from inside libmoar bind to these definitions, which is what lets
// the LTO link inline them into their C callers. Otherwise they are plain
// default-visibility exports, as `export fn` would make them.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(if (stats.enabled) &MVM_str_hash_build_stats else &MVM_str_hash_build, .{ .name = "MVM_str_hash_build", .visibility = visibility });
    @export(if (stats.enabled) &MVM_str_hash_build_strategy_stats else &MVM_str_hash_build_strategy, .{ .name = "MVM_str_hash_build_strategy", .visibility = visibility });
    @export(&MVM_str_hash_demolish, .{ .name = "MVM_str_hash_demolish", .visibility = visibility });
    @export(&MVM_str_hash_count, .{ .name = "MVM_str_hash_count", .visibility = visibility });
    @export(&MVM_str_hash_entry_size, .{ .name = "MVM_str_hash_entry_size", .visibility = visibility });
    @export(&MVM_str_hash_is_empty, .{ .name = "MVM_str_hash_is_empty", .visibility = visibility });
    @export(&MVM_str_hash_allocated_size, .{ .name = "MVM_str_hash_allocated_size", .visibility = visibility });
    @export(&MVM_str_hash_shallow_copy, .{ .name = "MVM_str_hash_shallow_copy", .visibility = visibility });
    @export(&MVM_str_hash_fsck, .{ .name = "MVM_str_hash_fsck", .visibility = visibility });
    @export(&MVM_str_hash_fetch_nocheck, .{ .name = "MVM_str_hash_fetch_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_lvalue_fetch_nocheck, .{ .name = "MVM_str_hash_lvalue_fetch_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_insert_nocheck, .{ .name = "MVM_str_hash_insert_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_delete_nocheck, .{ .name = "MVM_str_hash_delete_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_fetch, .{ .name = "MVM_str_hash_fetch", .visibility = visibility });
    @export(&MVM_str_hash_lvalue_fetch, .{ .name = "MVM_str_hash_lvalue_fetch", .visibility = visibility });
    @export(&MVM_str_hash_delete, .{ .name = "MVM_str_hash_delete", .visibility = visibility });
    @export(&MVM_str_hash_first, .{ .name = "MVM_str_hash_first", .visibility = visibility });
    @export(&MVM_str_hash_next_nocheck, .{ .name = "MVM_str_hash_next_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_next, .{ .name = "MVM_str_hash_next", .visibility = visibility });
    @export(&MVM_str_hash_start, .{ .name = "MVM_str_hash_start", .visibility = visibility });
    @export(&MVM_str_hash_at_start, .{ .name = "MVM_str_hash_at_start", .visibility = visibility });
    @export(&MVM_str_hash_current_nocheck, .{ .name = "MVM_str_hash_current_nocheck", .visibility = visibility });
    @export(&MVM_str_hash_current, .{ .name = "MVM_str_hash_current", .visibility = visibility });
    @export(&MVM_round_up_log_base2, .{ .name = "MVM_round_up_log_base2", .visibility = visibility });
}
