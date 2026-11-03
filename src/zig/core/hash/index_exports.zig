//! The C symbols of the index table (spec 11), exported from `index.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `index_hash_table.h`
//! and `index_hash_table_funcs.h` declare these extern (`allocated_size`,
//! `is_empty`, `shallow_copy`, `fetch_nocheck`, `fetch` and `built` were
//! inline there), and build/sources.list's [zig] section drops
//! `src/core/index_hash_table.c`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const stats = @import("stats.zig");
const index = @import("index.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMIndexHashTable;
const List = [*c][*c]c.MVMString;
const Key = [*c]c.MVMString;

fn MVM_index_hash_build(tc: Tc, hashtable: Ht, entries: u32) callconv(.c) void {
    index.build(tc, hashtable, entries);
}

/// The `-Dhash-stats` twin of `MVM_index_hash_build`: out of line, so `@returnAddress()` is
/// the C caller's call site, which names the statistics site of a table built here.
noinline fn MVM_index_hash_build_stats(tc: Tc, hashtable: Ht, entries: u32) callconv(.c) void {
    stats.setPendingSite(@returnAddress());
    index.build(tc, hashtable, entries);
}

fn MVM_index_hash_demolish(tc: Tc, hashtable: Ht) callconv(.c) void {
    index.demolish(tc, hashtable);
}

fn MVM_index_hash_built(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(index.built(tc, hashtable));
}

fn MVM_index_hash_is_empty(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(index.isEmpty(tc, hashtable));
}

fn MVM_index_hash_allocated_size(tc: Tc, hashtable: Ht) callconv(.c) usize {
    return index.allocatedSize(tc, hashtable);
}

fn MVM_index_hash_shallow_copy(tc: Tc, source: Ht, dest: Ht) callconv(.c) void {
    index.shallowCopy(tc, source, dest);
}

fn MVM_index_hash_insert_nocheck(tc: Tc, hashtable: Ht, list: List, idx: u32) callconv(.c) void {
    index.insertNocheck(tc, hashtable, list, idx);
}

fn MVM_index_hash_fetch_nocheck(tc: Tc, hashtable: Ht, list: List, want: Key) callconv(.c) u32 {
    return index.fetchNocheck(tc, hashtable, list, want);
}

fn MVM_index_hash_fetch(tc: Tc, hashtable: Ht, list: List, want: Key) callconv(.c) u32 {
    return index.fetch(tc, hashtable, list, want);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers (the benchmark shim, NativeCall), while
// calls from inside libmoar bind to these definitions, which is what lets
// the LTO link inline them into their C callers. Otherwise they are plain
// default-visibility exports, as `export fn` would make them.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(if (stats.enabled) &MVM_index_hash_build_stats else &MVM_index_hash_build, .{ .name = "MVM_index_hash_build", .visibility = visibility });
    @export(&MVM_index_hash_demolish, .{ .name = "MVM_index_hash_demolish", .visibility = visibility });
    @export(&MVM_index_hash_built, .{ .name = "MVM_index_hash_built", .visibility = visibility });
    @export(&MVM_index_hash_is_empty, .{ .name = "MVM_index_hash_is_empty", .visibility = visibility });
    @export(&MVM_index_hash_allocated_size, .{ .name = "MVM_index_hash_allocated_size", .visibility = visibility });
    @export(&MVM_index_hash_shallow_copy, .{ .name = "MVM_index_hash_shallow_copy", .visibility = visibility });
    @export(&MVM_index_hash_insert_nocheck, .{ .name = "MVM_index_hash_insert_nocheck", .visibility = visibility });
    @export(&MVM_index_hash_fetch_nocheck, .{ .name = "MVM_index_hash_fetch_nocheck", .visibility = visibility });
    @export(&MVM_index_hash_fetch, .{ .name = "MVM_index_hash_fetch", .visibility = visibility });
}
