//! The C symbols of the fixkey table (spec 11), exported from `fixkey.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `fixkey_hash_table.h`
//! and `fixkey_hash_table_funcs.h` declare these extern (`is_empty`,
//! `fetch_nocheck` and `foreach` were inline there), and build/sources.list's
//! [zig] section drops `src/core/fixkey_hash_table.c`. `MVM_fixkey_hash_fsck`
//! has no header declaration in C either; it is exported as the C defined it.
const moar = @import("moar");
const c = moar.c;
const fixkey = @import("fixkey.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMFixKeyHashTable;
const Key = [*c]c.MVMString;

export fn MVM_fixkey_hash_build(tc: Tc, hashtable: Ht, entry_size: u32) void {
    fixkey.build(tc, hashtable, entry_size);
}

export fn MVM_fixkey_hash_demolish(tc: Tc, hashtable: Ht) void {
    fixkey.demolish(tc, hashtable);
}

export fn MVM_fixkey_hash_is_empty(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(fixkey.isEmpty(tc, hashtable));
}

export fn MVM_fixkey_hash_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return fixkey.fetchNocheck(tc, hashtable, key);
}

export fn MVM_fixkey_hash_lvalue_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return fixkey.lvalueFetchNocheck(tc, hashtable, key);
}

export fn MVM_fixkey_hash_insert_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return fixkey.insertNocheck(tc, hashtable, key);
}

export fn MVM_fixkey_hash_foreach(tc: Tc, hashtable: Ht, callback: fixkey.Callback, arg: ?*anyopaque) void {
    fixkey.foreach(tc, hashtable, callback, arg);
}

export fn MVM_fixkey_hash_fsck(tc: Tc, hashtable: Ht, mode: u32) u64 {
    return fixkey.fsck(tc, hashtable, mode);
}
