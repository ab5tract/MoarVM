//! Zig port of src/gc/wb.c (lines 1-19): the out-of-line write barrier
//! hits. Faithful port; no behaviour change. The inline barrier fast paths
//! (`MVM_gc_write_barrier*` and `MVM_ASSIGN_REF` in src/gc/wb.h) stay C;
//! they call these when the updated object is in gen2 and the referenced
//! one is not. `MVM_gc_root_gen2_add` is called through `c.` as the C calls
//! it (it resolves to the roots port's export).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;
const Col = [*c]c.MVMCollectable;

/// Called when the write barrier macro detects we need to trigger the
/// write barrier. Arguments are the same as to the barrier macro itself
/// (updating is the object that we're about to write a pointer into, and
/// referenced is the object that the pointer references). This barrier
/// forces a re-scan of the object's contents during a GC run - even a
/// nursery only one - since somewhere it has references to a nursery
/// object. (wb.c:10-13)
pub fn hit(tc: Tc, update_root: Col) callconv(.c) void {
    if ((update_root.*.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST) == 0)
        c.MVM_gc_root_gen2_add(tc, update_root);
}

/// (wb.c:14-19)
pub fn hitBy(tc: Tc, update_root: Col, referenced: Col) callconv(.c) void {
    if ((update_root.*.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST) == 0)
        c.MVM_gc_root_gen2_add(tc, update_root);
    referenced.*.flags2 |= c.MVM_CF_REF_FROM_GEN2;
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&hit, .{ .name = "MVM_gc_write_barrier_hit", .visibility = visibility });
    @export(&hitBy, .{ .name = "MVM_gc_write_barrier_hit_by", .visibility = visibility });
}
