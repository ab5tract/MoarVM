//! The C symbols of the Unicode table (spec 11), exported from `uni.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `uni_hash_table.h` and
//! `uni_hash_table_funcs.h` declare these extern (`is_empty` and `fetch`
//! were inline there), and build/sources.list's [zig] section drops
//! `src/core/uni_hash_table.c`. `MVM_uni_hash_code` keeps its C inline body;
//! `MVM_uni_hash_lvalue_fetch` was static inline inside the C file and stays
//! private. `MVM_uni_hash_fsck` has no header declaration in C either; it is
//! exported as the C defined it.
const moar = @import("moar");
const c = moar.c;
const uni = @import("uni.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMUniHashTable;
const Key = [*c]const u8;

export fn MVM_uni_hash_build(tc: Tc, hashtable: Ht, entries: u32) void {
    uni.build(tc, hashtable, entries);
}

export fn MVM_uni_hash_demolish(tc: Tc, hashtable: Ht) void {
    uni.demolish(tc, hashtable);
}

export fn MVM_uni_hash_is_empty(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(uni.isEmpty(tc, hashtable));
}

export fn MVM_uni_hash_fetch(tc: Tc, hashtable: Ht, key: Key) ?*c.MVMUniHashEntry {
    return uni.fetch(tc, hashtable, key);
}

export fn MVM_uni_hash_insert(tc: Tc, hashtable: Ht, key: Key, value: i32) void {
    uni.insert(tc, hashtable, key, value);
}

export fn MVM_uni_hash_fsck(hashtable: Ht, mode: u32) u64 {
    return uni.fsck(hashtable, mode);
}
