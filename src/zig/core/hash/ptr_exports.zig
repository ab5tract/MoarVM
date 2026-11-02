//! The C symbols of the pointer table (spec 11), exported from `ptr.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `ptr_hash_table.h` and
//! `ptr_hash_table_funcs.h` declare these extern (`build`, `is_empty` and
//! `fetch` were inline there), and build/sources.list's [zig] section drops
//! `src/core/ptr_hash_table.c`. `MVM_ptr_hash_code` keeps its C inline body.
const moar = @import("moar");
const c = moar.c;
const ptr = @import("ptr.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMPtrHashTable;
const Key = ?*const anyopaque;

export fn MVM_ptr_hash_build(tc: Tc, hashtable: Ht) void {
    ptr.build(tc, hashtable);
}

export fn MVM_ptr_hash_demolish(tc: Tc, hashtable: Ht) void {
    ptr.demolish(tc, hashtable);
}

export fn MVM_ptr_hash_is_empty(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(ptr.isEmpty(tc, hashtable));
}

export fn MVM_ptr_hash_fetch(tc: Tc, hashtable: Ht, key: Key) ?*c.MVMPtrHashEntry {
    return ptr.fetch(tc, hashtable, key);
}

export fn MVM_ptr_hash_lvalue_fetch(tc: Tc, hashtable: Ht, key: Key) ?*c.MVMPtrHashEntry {
    return ptr.lvalueFetch(tc, hashtable, key);
}

export fn MVM_ptr_hash_insert(tc: Tc, hashtable: Ht, key: Key, value: usize) void {
    ptr.insert(tc, hashtable, key, value);
}

export fn MVM_ptr_hash_fetch_and_delete(tc: Tc, hashtable: Ht, key: Key) usize {
    return ptr.fetchAndDelete(tc, hashtable, key);
}
