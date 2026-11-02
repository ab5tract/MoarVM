//! The C symbols of the Unicode table (spec 11), exported from `uni.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `uni_hash_table.h` and
//! `uni_hash_table_funcs.h` declare these extern (`is_empty` and `fetch`
//! were inline there), and build/sources.list's [zig] section drops
//! `src/core/uni_hash_table.c`. `MVM_uni_hash_code` keeps its C inline body;
//! `MVM_uni_hash_lvalue_fetch` was static inline inside the C file and stays
//! private. `MVM_uni_hash_fsck` has no header declaration in C either; it is
//! exported as the C defined it.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const uni = @import("uni.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMUniHashTable;
const Key = [*c]const u8;

fn MVM_uni_hash_build(tc: Tc, hashtable: Ht, entries: u32) callconv(.c) void {
    uni.build(tc, hashtable, entries);
}

fn MVM_uni_hash_demolish(tc: Tc, hashtable: Ht) callconv(.c) void {
    uni.demolish(tc, hashtable);
}

fn MVM_uni_hash_is_empty(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(uni.isEmpty(tc, hashtable));
}

fn MVM_uni_hash_fetch(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*c.MVMUniHashEntry {
    return uni.fetch(tc, hashtable, key);
}

fn MVM_uni_hash_insert(tc: Tc, hashtable: Ht, key: Key, value: i32) callconv(.c) void {
    uni.insert(tc, hashtable, key, value);
}

fn MVM_uni_hash_fsck(hashtable: Ht, mode: u32) callconv(.c) u64 {
    return uni.fsck(hashtable, mode);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers (the benchmark shim, NativeCall), while
// calls from inside libmoar bind to these definitions, which is what lets
// the LTO link inline them into their C callers. Otherwise they are plain
// default-visibility exports, as `export fn` would make them.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&MVM_uni_hash_build, .{ .name = "MVM_uni_hash_build", .visibility = visibility });
    @export(&MVM_uni_hash_demolish, .{ .name = "MVM_uni_hash_demolish", .visibility = visibility });
    @export(&MVM_uni_hash_is_empty, .{ .name = "MVM_uni_hash_is_empty", .visibility = visibility });
    @export(&MVM_uni_hash_fetch, .{ .name = "MVM_uni_hash_fetch", .visibility = visibility });
    @export(&MVM_uni_hash_insert, .{ .name = "MVM_uni_hash_insert", .visibility = visibility });
    @export(&MVM_uni_hash_fsck, .{ .name = "MVM_uni_hash_fsck", .visibility = visibility });
}
