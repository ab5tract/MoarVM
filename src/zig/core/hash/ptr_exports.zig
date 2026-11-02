//! The C symbols of the pointer table (spec 11), exported from `ptr.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `ptr_hash_table.h` and
//! `ptr_hash_table_funcs.h` declare these extern (`build`, `is_empty` and
//! `fetch` were inline there), and build/sources.list's [zig] section drops
//! `src/core/ptr_hash_table.c`. `MVM_ptr_hash_code` keeps its C inline body.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const ptr = @import("ptr.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMPtrHashTable;
const Key = ?*const anyopaque;

fn MVM_ptr_hash_build(tc: Tc, hashtable: Ht) callconv(.c) void {
    ptr.build(tc, hashtable);
}

fn MVM_ptr_hash_demolish(tc: Tc, hashtable: Ht) callconv(.c) void {
    ptr.demolish(tc, hashtable);
}

fn MVM_ptr_hash_is_empty(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(ptr.isEmpty(tc, hashtable));
}

fn MVM_ptr_hash_fetch(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*c.MVMPtrHashEntry {
    return ptr.fetch(tc, hashtable, key);
}

fn MVM_ptr_hash_lvalue_fetch(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*c.MVMPtrHashEntry {
    return ptr.lvalueFetch(tc, hashtable, key);
}

fn MVM_ptr_hash_insert(tc: Tc, hashtable: Ht, key: Key, value: usize) callconv(.c) void {
    ptr.insert(tc, hashtable, key, value);
}

fn MVM_ptr_hash_fetch_and_delete(tc: Tc, hashtable: Ht, key: Key) callconv(.c) usize {
    return ptr.fetchAndDelete(tc, hashtable, key);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers (the benchmark shim, NativeCall), while
// calls from inside libmoar bind to these definitions, which is what lets
// the LTO link inline them into their C callers. Otherwise they are plain
// default-visibility exports, as `export fn` would make them.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&MVM_ptr_hash_build, .{ .name = "MVM_ptr_hash_build", .visibility = visibility });
    @export(&MVM_ptr_hash_demolish, .{ .name = "MVM_ptr_hash_demolish", .visibility = visibility });
    @export(&MVM_ptr_hash_is_empty, .{ .name = "MVM_ptr_hash_is_empty", .visibility = visibility });
    @export(&MVM_ptr_hash_fetch, .{ .name = "MVM_ptr_hash_fetch", .visibility = visibility });
    @export(&MVM_ptr_hash_lvalue_fetch, .{ .name = "MVM_ptr_hash_lvalue_fetch", .visibility = visibility });
    @export(&MVM_ptr_hash_insert, .{ .name = "MVM_ptr_hash_insert", .visibility = visibility });
    @export(&MVM_ptr_hash_fetch_and_delete, .{ .name = "MVM_ptr_hash_fetch_and_delete", .visibility = visibility });
}
