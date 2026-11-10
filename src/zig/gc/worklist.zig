//! Zig port of src/gc/worklist.c (lines 1-35): allocation, growth and
//! destruction of the GC worklist, a stack of addresses of collectable
//! pointer slots. No behaviour change. The struct and the
//! `MVM_gc_worklist_add*`/`_get` fast-path macros stay in src/gc/worklist.h;
//! the list is allocated through `MVM_malloc`/`MVM_realloc`/`MVM_free` so
//! the C macros and every C caller can keep using `worklist->list`. The
//! functions are Zig-typed; the `MVM_gc_worklist_*` exports are thin C-ABI
//! wrappers over them, which take the C's unused `tc`.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");

const Tc = view.Tc;
const Worklist = view.Worklist;
const ColSlot = view.ColSlot;

/// The type of a list entry, as the C struct declares it.
const Entry = @typeInfo(@FieldType(c.MVMGCWorklist, "list")).pointer.child;

// The C layout the macros of worklist.h index into.
comptime {
    if (builtin.target.cpu.arch == .x86_64) std.debug.assert(@sizeOf(c.MVMGCWorklist) == 24);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "items") == 8);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "alloc") == 12);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "include_gen2") == 16);
}

/// `MVM_realloc` of the list to `worklist.alloc` entries.
fn resize(worklist: Worklist) void {
    worklist.list = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(worklist.list), @as(usize, worklist.alloc) * @sizeOf(Entry))));
}

/// Allocates a new GC worklist. (worklist.c:3-11)
pub fn create(tc: Tc, include_gen2: bool) Worklist {
    _ = tc;
    const worklist: Worklist = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(c.MVMGCWorklist))));
    worklist.items = 0;
    worklist.alloc = c.MVM_GC_WORKLIST_START_SIZE;
    worklist.list = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, worklist.alloc) * @sizeOf(Entry))));
    worklist.include_gen2 = @intFromBool(include_gen2);
    return worklist;
}

/// Adds an item to the worklist, expanding it if needed. (worklist.c:13-20)
pub fn addSlow(worklist: Worklist, item: ColSlot) void {
    if (worklist.items == worklist.alloc) {
        worklist.alloc *%= 2;
        resize(worklist);
    }
    worklist.list[worklist.items] = @ptrCast(item);
    worklist.items +%= 1;
}

/// Pre-sizes the worklist in expectation a certain number of items is about to be
/// added. (worklist.c:22-29)
pub fn presizeFor(worklist: Worklist, items: u32) void {
    const wanted = worklist.items +% items;
    if (wanted >= worklist.alloc) {
        worklist.alloc = wanted;
        resize(worklist);
    }
}

/// Free a worklist. (worklist.c:31-35)
pub fn destroy(worklist: Worklist) void {
    c.MVM_free(@ptrCast(worklist.list));
    c.MVM_free(worklist);
}

// ---- the C ABI -------------------------------------------------------------

fn createExport(tc: [*c]c.MVMThreadContext, include_gen2: c.MVMuint8) callconv(.c) [*c]c.MVMGCWorklist {
    // Any non-zero byte is true, as the C stores the byte it is given; the
    // C callers pass 0 or 1.
    return create(tc, include_gen2 != 0);
}

fn addSlowExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, item: [*c][*c]c.MVMCollectable) callconv(.c) void {
    _ = tc;
    addSlow(worklist, @ptrCast(item));
}

fn presizeForExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, items: c.MVMint32) callconv(.c) void {
    _ = tc;
    // MVMuint32 + MVMint32 is unsigned 32-bit arithmetic in C.
    presizeFor(worklist, @bitCast(items));
}

fn destroyExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist) callconv(.c) void {
    _ = tc;
    destroy(worklist);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&createExport, .{ .name = "MVM_gc_worklist_create", .visibility = visibility });
    @export(&addSlowExport, .{ .name = "MVM_gc_worklist_add_slow", .visibility = visibility });
    @export(&presizeForExport, .{ .name = "MVM_gc_worklist_presize_for", .visibility = visibility });
    @export(&destroyExport, .{ .name = "MVM_gc_worklist_destroy", .visibility = visibility });
}
