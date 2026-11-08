//! Zig port of src/gc/worklist.c (lines 1-35): allocation, growth and
//! destruction of the GC worklist, a stack of addresses of collectable
//! pointers. Faithful port; no behaviour change. The struct and the
//! `MVM_gc_worklist_add*`/`_get` fast-path macros stay in src/gc/worklist.h;
//! the list is allocated through `MVM_malloc`/`MVM_realloc`/`MVM_free` so
//! the C macros and every C caller can keep using `worklist->list`.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;
const Worklist = [*c]c.MVMGCWorklist;
const Item = [*c][*c]c.MVMCollectable;

// The C layout the macros of worklist.h index into.
comptime {
    if (builtin.target.cpu.arch == .x86_64) std.debug.assert(@sizeOf(c.MVMGCWorklist) == 24);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "items") == 8);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "alloc") == 12);
    std.debug.assert(@offsetOf(c.MVMGCWorklist, "include_gen2") == 16);
}

/// Allocates a new GC worklist. (worklist.c:3-11)
pub fn create(tc: Tc, include_gen2: c.MVMuint8) callconv(.c) Worklist {
    _ = tc;
    const worklist: Worklist = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(c.MVMGCWorklist))));
    worklist.*.items = 0;
    worklist.*.alloc = c.MVM_GC_WORKLIST_START_SIZE;
    worklist.*.list = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, worklist.*.alloc) * @sizeOf(Item))));
    worklist.*.include_gen2 = include_gen2;
    return worklist;
}

/// Adds an item to the worklist, expanding it if needed. (worklist.c:13-20)
pub fn addSlow(tc: Tc, worklist: Worklist, item: Item) callconv(.c) void {
    _ = tc;
    if (worklist.*.items == worklist.*.alloc) {
        worklist.*.alloc *%= 2;
        worklist.*.list = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(worklist.*.list), @as(usize, worklist.*.alloc) * @sizeOf(Item))));
    }
    worklist.*.list[worklist.*.items] = item;
    worklist.*.items +%= 1;
}

/// Pre-sizes the worklist in expectation a certain number of items is about to be
/// added. (worklist.c:22-29)
pub fn presizeFor(tc: Tc, worklist: Worklist, items: c.MVMint32) callconv(.c) void {
    _ = tc;
    // MVMuint32 + MVMint32 is unsigned 32-bit arithmetic in C.
    if (worklist.*.items +% @as(c.MVMuint32, @bitCast(items)) >= worklist.*.alloc) {
        worklist.*.alloc = worklist.*.items +% @as(c.MVMuint32, @bitCast(items));
        worklist.*.list = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(worklist.*.list), @as(usize, worklist.*.alloc) * @sizeOf(Item))));
    }
}

/// Free a worklist. (worklist.c:31-35)
pub fn destroy(tc: Tc, worklist: Worklist) callconv(.c) void {
    _ = tc;
    c.MVM_free(@ptrCast(worklist.*.list));
    c.MVM_free(@ptrCast(worklist));
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&create, .{ .name = "MVM_gc_worklist_create", .visibility = visibility });
    @export(&addSlow, .{ .name = "MVM_gc_worklist_add_slow", .visibility = visibility });
    @export(&presizeFor, .{ .name = "MVM_gc_worklist_presize_for", .visibility = visibility });
    @export(&destroy, .{ .name = "MVM_gc_worklist_destroy", .visibility = visibility });
}
