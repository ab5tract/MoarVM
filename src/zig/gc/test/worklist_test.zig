//! Tests of `worklist.zig` (the port of src/gc/worklist.c) on a booted VM.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const worklist = @import("../worklist.zig");
const view = @import("../view.zig");

/// From src/zig/test/layout_probe.c: runs the C macro
/// `MVM_gc_worklist_add_include_gen2_nocheck`, which translate-c cannot
/// translate (a `do { } while (0)` body).
extern fn moar_probe_worklist_add_include_gen2_nocheck(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, item: [*c][*c]c.MVMCollectable) void;

const Item = ?*c.MVMCollectable;

/// The address of list entry `i`, for comparing with the slot pushed.
fn entry(wl: view.Worklist, i: usize) usize {
    return @intFromPtr(wl.list[i]);
}

test "create gives alloc 256, items 0 and include_gen2 as passed" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    for ([_]bool{ false, true }) |gen2| {
        const wl = worklist.create(tc, gen2);
        defer worklist.destroy(wl);
        try std.testing.expectEqual(@as(c.MVMuint32, 256), wl.alloc);
        try std.testing.expectEqual(@as(c.MVMuint32, 0), wl.items);
        try std.testing.expectEqual(@as(c.MVMuint8, @intFromBool(gen2)), wl.include_gen2);
        try std.testing.expect(wl.list != null);
    }
}

test "add_slow past alloc doubles alloc and keeps every item in push order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, true);
    defer worklist.destroy(wl);
    // 1000 distinct addresses; add_slow never dereferences them.
    var slots: [1000]Item = undefined;
    for (&slots) |*s| worklist.addSlow(wl, s);
    try std.testing.expectEqual(@as(c.MVMuint32, 1024), wl.alloc);
    try std.testing.expectEqual(@as(c.MVMuint32, 1000), wl.items);
    for (&slots, 0..) |*s, i| try std.testing.expectEqual(@intFromPtr(s), entry(wl, i));
}

test "presize_for 5000 then 5000 pushes leaves alloc unchanged" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, true);
    defer worklist.destroy(wl);
    worklist.presizeFor(wl, 5000);
    const alloc = wl.alloc;
    try std.testing.expectEqual(@as(c.MVMuint32, 5000), alloc);
    const slots = try std.testing.allocator.alloc(Item, 5000);
    defer std.testing.allocator.free(slots);
    // The macros' fast path (store while items < alloc), as C callers do
    // after presizing; add_slow is only reached when the list is full.
    for (slots) |*s| {
        if (wl.items == wl.alloc) worklist.addSlow(wl, s) else {
            wl.list[wl.items] = @ptrCast(s);
            wl.items += 1;
        }
    }
    try std.testing.expectEqual(@as(c.MVMuint32, 5000), wl.items);
    try std.testing.expectEqual(alloc, wl.alloc);
}

test "the C add macro and a Zig pop agree" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, true);
    defer worklist.destroy(wl);
    // A real nursery object, so the -Dgc-debug checks of the macro pass.
    var obj: ?*c.MVMObject = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const item: [*c][*c]c.MVMCollectable = @ptrCast(&obj);
    moar_probe_worklist_add_include_gen2_nocheck(tc, wl, item);
    try std.testing.expectEqual(@as(c.MVMuint32, 1), wl.items);
    try std.testing.expectEqual(@intFromPtr(item), entry(wl, wl.items - 1));
}

test "destroy then create again works" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    var slot: Item = null;
    const first = worklist.create(tc, false);
    worklist.addSlow(first, &slot);
    worklist.destroy(first);
    const second = worklist.create(tc, true);
    defer worklist.destroy(second);
    try std.testing.expectEqual(@as(c.MVMuint32, 0), second.items);
    try std.testing.expectEqual(@as(c.MVMuint32, 256), second.alloc);
    try std.testing.expectEqual(@as(c.MVMuint8, 1), second.include_gen2);
    worklist.addSlow(second, &slot);
    try std.testing.expectEqual(@intFromPtr(&slot), entry(second, 0));
}
