//! The C symbols of the string table (spec 3.1, 7), exported from
//! `str.zig`'s functions of the same shape. Under `MVM_ZIG_IMPL` (config.h,
//! when the Zig groups are on) `str_hash_table.h` and
//! `str_hash_table_funcs.h` declare these extern, and build/sources.list's
//! [zig] section drops `src/core/str_hash_table.c`. Each export takes the
//! translated C types so the ABI is the header's declaration exactly, and
//! is one call into `str.zig`. `MVM_str_hash_at_end` stays inline in the
//! header and `MVM_str_hash_key_is_valid`/`_key_throw_invalid` keep their C
//! inline bodies (the other tables use them), so none of those is here.
const moar = @import("moar");
const c = moar.c;
const str = @import("str.zig");

const Tc = [*c]c.MVMThreadContext;
const Ht = [*c]c.MVMStrHashTable;
const Key = [*c]c.MVMString;
const Iterator = c.MVMStrHashIterator;

// ------------------------------------------------------------ lifetime

export fn MVM_str_hash_build(tc: Tc, hashtable: Ht, entry_size: u32, entries: u32) void {
    str.build(tc, hashtable, entry_size, entries);
}

export fn MVM_str_hash_demolish(tc: Tc, hashtable: Ht) void {
    str.demolish(tc, hashtable);
}

export fn MVM_str_hash_count(tc: Tc, hashtable: Ht) c.MVMHashNumItems {
    return str.count(tc, hashtable);
}

export fn MVM_str_hash_entry_size(tc: Tc, hashtable: Ht) c.MVMHashNumItems {
    return str.entrySize(tc, hashtable);
}

export fn MVM_str_hash_is_empty(tc: Tc, hashtable: Ht) c_int {
    return @intFromBool(str.isEmpty(tc, hashtable));
}

export fn MVM_str_hash_allocated_size(tc: Tc, hashtable: Ht) usize {
    return str.allocatedSize(tc, hashtable);
}

export fn MVM_str_hash_shallow_copy(tc: Tc, source: Ht, dest: Ht) void {
    str.shallowCopy(tc, source, dest);
}

export fn MVM_str_hash_fsck(tc: Tc, hashtable: Ht, mode: u32) u64 {
    return str.fsck(tc, hashtable, mode);
}

// -------------------------------------------------------------- access

export fn MVM_str_hash_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return str.fetchNocheck(tc, hashtable, key);
}

export fn MVM_str_hash_lvalue_fetch_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return str.lvalueFetchNocheck(tc, hashtable, key);
}

export fn MVM_str_hash_insert_nocheck(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return str.insertNocheck(tc, hashtable, key);
}

export fn MVM_str_hash_delete_nocheck(tc: Tc, hashtable: Ht, want: Key) void {
    str.deleteNocheck(tc, hashtable, want);
}

export fn MVM_str_hash_fetch(tc: Tc, hashtable: Ht, want: Key) ?*anyopaque {
    return str.fetch(tc, hashtable, want);
}

export fn MVM_str_hash_lvalue_fetch(tc: Tc, hashtable: Ht, key: Key) ?*anyopaque {
    return str.lvalueFetch(tc, hashtable, key);
}

export fn MVM_str_hash_delete(tc: Tc, hashtable: Ht, want: Key) void {
    str.delete(tc, hashtable, want);
}

// ----------------------------------------------------------- iteration

export fn MVM_str_hash_first(tc: Tc, hashtable: Ht) Iterator {
    return str.first(tc, hashtable);
}

export fn MVM_str_hash_next_nocheck(tc: Tc, hashtable: Ht, iterator: Iterator) Iterator {
    return str.nextNocheck(tc, hashtable, iterator);
}

export fn MVM_str_hash_next(tc: Tc, hashtable: Ht, iterator: Iterator) Iterator {
    return str.next(tc, hashtable, iterator);
}

export fn MVM_str_hash_start(tc: Tc, hashtable: Ht) Iterator {
    return str.start(tc, hashtable);
}

export fn MVM_str_hash_at_start(tc: Tc, hashtable: Ht, iterator: Iterator) c_int {
    return @intFromBool(str.atStart(tc, hashtable, iterator));
}

export fn MVM_str_hash_current_nocheck(tc: Tc, hashtable: Ht, iterator: Iterator) ?*anyopaque {
    return str.currentNocheck(tc, hashtable, iterator);
}

export fn MVM_str_hash_current(tc: Tc, hashtable: Ht, iterator: Iterator) ?*anyopaque {
    return str.current(tc, hashtable, iterator);
}

// -------------------------------------------------------------- sizing

/// Still defined by `str_hash_table.c`, which the [zig] line drops; the index
/// and uni tables call it for their initial size.
export fn MVM_round_up_log_base2(v: u32) u32 {
    return str.roundUpLog2(v);
}
