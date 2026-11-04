//! Tests of `worklist.zig` (the port of src/gc/worklist.c) on a booted VM.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const worklist = @import("../worklist.zig");

/// From src/zig/test/layout_probe.c: runs the C macro
/// `MVM_gc_worklist_add_include_gen2_nocheck`, which translate-c cannot
/// translate (a `do { } while (0)` body).
extern fn moar_probe_worklist_add_include_gen2_nocheck(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, item: [*c][*c]c.MVMCollectable) void;

const Item = [*c]c.MVMCollectable;

test "create gives alloc 256, items 0 and include_gen2 as passed" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    for ([_]c.MVMuint8{ 0, 1 }) |gen2| {
        const wl = worklist.create(tc, gen2);
        defer worklist.destroy(tc, wl);
        try std.testing.expectEqual(@as(c.MVMuint32, 256), wl.*.alloc);
        try std.testing.expectEqual(@as(c.MVMuint32, 0), wl.*.items);
        try std.testing.expectEqual(gen2, wl.*.include_gen2);
        try std.testing.expect(wl.*.list != null);
    }
}

test "add_slow past alloc doubles alloc and keeps every item in push order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, 1);
    defer worklist.destroy(tc, wl);
    // 1000 distinct addresses; add_slow never dereferences them.
    var slots: [1000]Item = undefined;
    for (&slots) |*s| worklist.addSlow(tc, wl, s);
    try std.testing.expectEqual(@as(c.MVMuint32, 1024), wl.*.alloc);
    try std.testing.expectEqual(@as(c.MVMuint32, 1000), wl.*.items);
    for (&slots, 0..) |*s, i| try std.testing.expect(wl.*.list[i] == @as([*c]Item, s));
}

test "presize_for 5000 then 5000 pushes leaves alloc unchanged" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, 1);
    defer worklist.destroy(tc, wl);
    worklist.presizeFor(tc, wl, 5000);
    const alloc = wl.*.alloc;
    try std.testing.expectEqual(@as(c.MVMuint32, 5000), alloc);
    const slots = try std.testing.allocator.alloc(Item, 5000);
    defer std.testing.allocator.free(slots);
    // The macros' fast path (store while items < alloc), as C callers do
    // after presizing; add_slow is only reached when the list is full.
    for (slots) |*s| {
        if (wl.*.items == wl.*.alloc) worklist.addSlow(tc, wl, s) else {
            wl.*.list[wl.*.items] = s;
            wl.*.items += 1;
        }
    }
    try std.testing.expectEqual(@as(c.MVMuint32, 5000), wl.*.items);
    try std.testing.expectEqual(alloc, wl.*.alloc);
}

test "the C add macro and a Zig pop agree" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = worklist.create(tc, 1);
    defer worklist.destroy(tc, wl);
    // A real nursery object, so the -Dgc-debug checks of the macro pass.
    var obj: ?*c.MVMObject = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const item: [*c]Item = @ptrCast(&obj);
    moar_probe_worklist_add_include_gen2_nocheck(tc, wl, item);
    try std.testing.expectEqual(@as(c.MVMuint32, 1), wl.*.items);
    try std.testing.expect(wl.*.list[wl.*.items - 1] == item);
}

test "destroy then create again works" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    var slot: Item = null;
    const first = worklist.create(tc, 0);
    worklist.addSlow(tc, first, &slot);
    worklist.destroy(tc, first);
    const second = worklist.create(tc, 1);
    defer worklist.destroy(tc, second);
    try std.testing.expectEqual(@as(c.MVMuint32, 0), second.*.items);
    try std.testing.expectEqual(@as(c.MVMuint32, 256), second.*.alloc);
    try std.testing.expectEqual(@as(c.MVMuint8, 1), second.*.include_gen2);
    worklist.addSlow(tc, second, &slot);
    try std.testing.expect(second.*.list[0] == @as([*c]Item, &slot));
}
