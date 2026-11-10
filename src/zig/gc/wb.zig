//! Zig port of src/gc/wb.c (lines 1-19): the out-of-line write barrier
//! hits, plus a Zig copy of one inline fast path of src/gc/wb.h,
//! `MVM_gc_write_barrier_no_update_referenced` (`noUpdateReferenced`), so
//! that the collector's Zig caller inlines it as the C caller inlines the
//! header's (translate-c's copy of a header inline is a separate function,
//! called out of line). No behaviour change. The other fast paths
//! (`MVM_gc_write_barrier` and `MVM_ASSIGN_REF`, the latter `moar.assignRef`)
//! stay with their callers. The functions are Zig-typed and call the roots
//! port as Zig; the `MVM_gc_write_barrier_hit*` exports are thin C-ABI
//! wrappers over them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");
const roots = @import("roots.zig");

const Tc = view.Tc;
const Col = view.Col;

/// Called when the write barrier macro detects we need to trigger the
/// write barrier. Arguments are the same as to the barrier macro itself
/// (updating is the object that we're about to write a pointer into, and
/// referenced is the object that the pointer references). This barrier
/// forces a re-scan of the object's contents during a GC run - even a
/// nursery only one - since somewhere it has references to a nursery
/// object. (wb.c:10-13)
pub fn hit(tc: Tc, update_root: Col) void {
    if (!view.flags2(update_root).in_gen2_root_list)
        roots.gen2Add(tc, update_root);
}

/// (wb.c:14-19)
pub fn hitBy(tc: Tc, update_root: Col, referenced: Col) void {
    if (!view.flags2(update_root).in_gen2_root_list)
        roots.gen2Add(tc, update_root);
    view.flags2(referenced).ref_from_gen2 = true;
}

/// MVM_gc_write_barrier_no_update_referenced (wb.h:13-16): if a gen2
/// collectable comes to hold a reference to a nursery one, it becomes an
/// inter-generational root; unlike `MVM_gc_write_barrier`, the referenced
/// collectable is not flagged. The C's tests, in its order: `update_root`
/// in gen2, `referenced` not NULL, `referenced` not in gen2.
pub inline fn noUpdateReferenced(tc: Tc, update_root: Col, referenced: ?Col) void {
    if (view.flags2(update_root).second_gen) {
        if (referenced) |r| {
            if (!view.flags2(r).second_gen)
                hit(tc, update_root);
        }
    }
}

// ---- the C ABI -------------------------------------------------------------

fn hitExport(tc: [*c]c.MVMThreadContext, update_root: [*c]c.MVMCollectable) callconv(.c) void {
    hit(tc, update_root);
}

fn hitByExport(tc: [*c]c.MVMThreadContext, update_root: [*c]c.MVMCollectable, referenced: [*c]c.MVMCollectable) callconv(.c) void {
    hitBy(tc, update_root, referenced);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&hitExport, .{ .name = "MVM_gc_write_barrier_hit", .visibility = visibility });
    @export(&hitByExport, .{ .name = "MVM_gc_write_barrier_hit_by", .visibility = visibility });
}
