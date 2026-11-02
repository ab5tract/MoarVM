//! The C symbols of the index table (spec 11), exported from `index.zig`'s
//! functions of the same shape. Under `MVM_ZIG_IMPL` `index_hash_table.h`
//! and `index_hash_table_funcs.h` declare these extern (`allocated_size`,
//! `is_empty`, `shallow_copy`, `fetch_nocheck`, `fetch` and `built` were
//! inline there), and build/sources.list's [zig] section drops
//! `src/core/index_hash_table.c`.
const moar = @import("moar");
const c = moar.c;
const index = @import("index.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMIndexHashTable;
const List = [*c][*c]c.MVMString;
const Key = [*c]c.MVMString;

export fn MVM_index_hash_build(tc: Tc, hashtable: Ht, entries: u32) void {
    index.build(tc, hashtable, entries);
}

export fn MVM_index_hash_demolish(tc: Tc, hashtable: Ht) void {
    index.demolish(tc, hashtable);
}

export fn MVM_index_hash_built(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(index.built(tc, hashtable));
}

export fn MVM_index_hash_is_empty(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(index.isEmpty(tc, hashtable));
}

export fn MVM_index_hash_allocated_size(tc: Tc, hashtable: Ht) usize {
    return index.allocatedSize(tc, hashtable);
}

export fn MVM_index_hash_shallow_copy(tc: Tc, source: Ht, dest: Ht) void {
    index.shallowCopy(tc, source, dest);
}

export fn MVM_index_hash_insert_nocheck(tc: Tc, hashtable: Ht, list: List, idx: u32) void {
    index.insertNocheck(tc, hashtable, list, idx);
}

export fn MVM_index_hash_fetch_nocheck(tc: Tc, hashtable: Ht, list: List, want: Key) u32 {
    return index.fetchNocheck(tc, hashtable, list, want);
}

export fn MVM_index_hash_fetch(tc: Tc, hashtable: Ht, list: List, want: Key) u32 {
    return index.fetch(tc, hashtable, list, want);
}
