//! The C symbols of the fixkey table (spec 11), exported from `fixkey.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `fixkey_hash_table.h`
//! and `fixkey_hash_table_funcs.h` declare these extern (`is_empty`,
//! `fetch_nocheck` and `foreach` were inline there), and build/sources.list's
//! [zig] section drops `src/core/fixkey_hash_table.c`. `MVM_fixkey_hash_fsck`
//! has no header declaration in C either; it is exported as the C defined it.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const fixkey = @import("fixkey.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMFixKeyHashTable;
const Key = [*c]c.MVMString;

fn MVM_fixkey_hash_build(tc: Tc, hashtable: Ht, entry_size: u32) callconv(.c) void {
    fixkey.build(tc, hashtable, entry_size);
}

fn MVM_fixkey_hash_demolish(tc: Tc, hashtable: Ht) callconv(.c) void {
    fixkey.demolish(tc, hashtable);
}

fn MVM_fixkey_hash_is_empty(tc: Tc, hashtable: Ht) callconv(.c) c_int {
    return @intFromBool(fixkey.isEmpty(tc, hashtable));
}

fn MVM_fixkey_hash_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return fixkey.fetchNocheck(tc, hashtable, key);
}

fn MVM_fixkey_hash_lvalue_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return fixkey.lvalueFetchNocheck(tc, hashtable, key);
}

fn MVM_fixkey_hash_insert_nocheck(tc: Tc, hashtable: Ht, key: Key) callconv(.c) ?*anyopaque {
    return fixkey.insertNocheck(tc, hashtable, key);
}

fn MVM_fixkey_hash_foreach(tc: Tc, hashtable: Ht, callback: fixkey.Callback, arg: ?*anyopaque) callconv(.c) void {
    fixkey.foreach(tc, hashtable, callback, arg);
}

fn MVM_fixkey_hash_fsck(tc: Tc, hashtable: Ht, mode: u32) callconv(.c) u64 {
    return fixkey.fsck(tc, hashtable, mode);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers (the benchmark shim, NativeCall), while
// calls from inside libmoar bind to these definitions, which is what lets
// the LTO link inline them into their C callers. Otherwise they are plain
// default-visibility exports, as `export fn` would make them.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&MVM_fixkey_hash_build, .{ .name = "MVM_fixkey_hash_build", .visibility = visibility });
    @export(&MVM_fixkey_hash_demolish, .{ .name = "MVM_fixkey_hash_demolish", .visibility = visibility });
    @export(&MVM_fixkey_hash_is_empty, .{ .name = "MVM_fixkey_hash_is_empty", .visibility = visibility });
    @export(&MVM_fixkey_hash_fetch_nocheck, .{ .name = "MVM_fixkey_hash_fetch_nocheck", .visibility = visibility });
    @export(&MVM_fixkey_hash_lvalue_fetch_nocheck, .{ .name = "MVM_fixkey_hash_lvalue_fetch_nocheck", .visibility = visibility });
    @export(&MVM_fixkey_hash_insert_nocheck, .{ .name = "MVM_fixkey_hash_insert_nocheck", .visibility = visibility });
    @export(&MVM_fixkey_hash_foreach, .{ .name = "MVM_fixkey_hash_foreach", .visibility = visibility });
    @export(&MVM_fixkey_hash_fsck, .{ .name = "MVM_fixkey_hash_fsck", .visibility = visibility });
}
