//! Tests of `collect.zig` (the port of src/gc/collect.c) on a booted VM. The
//! collections are real ones, started through `MVM_gc_enter_from_allocator`
//! as a full nursery starts them; with a single thread the main thread is
//! the coordinator and the thread to blame.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const collect = @import("../collect.zig");
const gen2 = @import("../gen2.zig");

const Tc = [*c]c.MVMThreadContext;
const Object = c.MVMObject;
const Collectable = c.MVMCollectable;

fn col(p: anytype) [*c]Collectable {
    return @ptrCast(@alignCast(p));
}

fn inNursery(tc: Tc, p: anytype) bool {
    const a = @intFromPtr(p);
    const lo = @intFromPtr(tc.*.nursery_tospace);
    return a >= lo and a < lo + tc.*.nursery_tospace_size;
}

/// Two collections, so that whatever the boot left in the nursery is in
/// gen2 and the next runs see only what the test allocates.
fn settle(tc: Tc) void {
    c.MVM_gc_enter_from_allocator(tc);
    c.MVM_gc_enter_from_allocator(tc);
}

test "an object surviving two collections is promoted and its forwarding pointer followed" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    settle(tc);
    // Two roots to one object: the first one processed copies it and writes
    // the forwarding pointer, the second one is updated through it.
    var a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    var b: ?*Object = a;
    const r = moar.rootN(tc, .{ &a, &b });
    defer r.pop(tc);
    const born = a.?;
    try std.testing.expect(inNursery(tc, born));
    try std.testing.expectEqual(@as(u8, 0), born.header.flags2 & (c.MVM_CF_NURSERY_SEEN | c.MVM_CF_SECOND_GEN));

    // First run: copied within the nursery, marked seen.
    c.MVM_gc_enter_from_allocator(tc);
    const seen = a.?;
    try std.testing.expect(seen != born);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(inNursery(tc, seen));
    try std.testing.expect(seen.header.flags2 & c.MVM_CF_NURSERY_SEEN != 0);
    try std.testing.expect(seen.header.flags2 & c.MVM_CF_SECOND_GEN == 0);
    // The fromspace copy (still mapped: fromspace is only reused by the
    // next run) carries the forwarder and its valid flag (collect.c:318-323).
    try std.testing.expect(born.header.flags2 & c.MVM_CF_FORWARDER_VALID != 0);
    try std.testing.expectEqual(@intFromPtr(seen), @intFromPtr(born.header.sc_forward_u.forwarder));

    // Second run: promoted to gen2 (collect.c:253-274).
    c.MVM_gc_enter_from_allocator(tc);
    const old = a.?;
    try std.testing.expect(old != seen);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(!inNursery(tc, old));
    try std.testing.expect(old.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(old.header.flags2 & c.MVM_CF_NURSERY_SEEN == 0);
    try std.testing.expect(old.header.flags2 & c.MVM_CF_FORWARDER_VALID == 0);
    try std.testing.expectEqual(instance.*.boot_types.BOOTArray.*.st, old.st);

    // A third run leaves a gen2 object where it is.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(old, a.?);
    try std.testing.expectEqual(a, b);
}

test "promoted bytes count the object's size" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    settle(tc);
    var a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.root(tc, &a);
    defer r.pop(tc);
    // The allocator stamps the STable's size into the header, and the
    // promotion adds that header size (collect.c:265), not the aligned one.
    try std.testing.expectEqual(@as(u16, @intCast(a.?.st.*.size)), a.?.header.size);
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(u32, 0), tc.*.gc_promoted_bytes);
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(a.?.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    // An empty VMArray has no unmanaged size, so the object is all of it.
    try std.testing.expectEqual(@as(u32, a.?.header.size), tc.*.gc_promoted_bytes);
}

// Needs `instance->gc_debug_rss_override`, which exists only in a
// `-Dgc-debug=1` build (src/core/instance.h, Task 1): skipped otherwise.
test "unreferenced gen2 object is freed on a full run" {
    if (comptime !@hasField(c.MVMInstance, "gc_debug_rss_override")) return error.SkipZigTest;
    try freedOnFullRun();
}

fn freedOnFullRun() !void {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    settle(tc);
    var a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    {
        const r = moar.root(tc, &a);
        defer r.pop(tc);
        c.MVM_gc_enter_from_allocator(tc);
        c.MVM_gc_enter_from_allocator(tc);
    }
    const dead = a.?;
    try std.testing.expect(dead.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    // A nursery run does not sweep gen2.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(dead.header.flags2 & c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST == 0);
    // Force the next run full (orchestrate.c:428-449): promoted bytes at the
    // minimum, and a resident set so small that any growth is over 20 %.
    @atomicStore(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, c.MVM_GC_GEN2_THRESHOLD_MINIMUM, .seq_cst);
    instance.*.gc_debug_rss_override = 1;
    c.MVM_gc_enter_from_allocator(tc);
    instance.*.gc_debug_rss_override = 0;
    try std.testing.expect(instance.*.gc_full_collect != 0);
    // Swept: flagged (collect.c:686) and threaded on its bin's free list.
    try std.testing.expect(dead.header.flags2 & c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST != 0);
    const bin = gen2.binOf(dead.header.size);
    var p: [*c][*c]u8 = tc.*.gen2.*.size_classes[bin].free_list;
    var found = false;
    while (p != null) : (p = @ptrCast(@alignCast(p.*))) {
        if (@intFromPtr(p) == @intFromPtr(dead)) found = true;
    }
    try std.testing.expect(found);
}

const pushes_per_thread = 1000;

fn pushMany(tc: Tc, tag_base: usize) void {
    for (0..pushes_per_thread) |k| {
        const work: [*c]c.MVMGCPassedWork = @ptrCast(@alignCast(c.MVM_calloc(1, @sizeOf(c.MVMGCPassedWork))));
        // A tag in the first item slot; num_items stays 0, so nothing would
        // be marked from these blocks if a collection did see them.
        // Through `*`: indexing `work.*.items` on a `[*c]` indexes whole
        // arrays in Zig 0.16 (see collect.zig, passedItems).
        const w: *c.MVMGCPassedWork = work;
        w.items[0] = @ptrFromInt(tag_base + k + 1);
        collect.pushWorkToThreadInTray(tc, 1, work);
    }
}

test "work pushed to a thread's in-tray from two threads is all there" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    try std.testing.expectEqual(@as(u32, 1), tc.*.thread_id);
    try std.testing.expect(tc.*.gc_in_tray == null);
    // Target 1 is the main thread (collect.c:422-424), the third party here:
    // the two pushers are plain OS threads using tc only to find it.
    const t1 = try std.Thread.spawn(.{}, pushMany, .{ tc, 0 });
    const t2 = try std.Thread.spawn(.{}, pushMany, .{ tc, pushes_per_thread });
    t1.join();
    t2.join();
    var seen: [2 * pushes_per_thread]bool = @splat(false);
    var n: usize = 0;
    var head = tc.*.gc_in_tray;
    tc.*.gc_in_tray = null;
    while (head != null) {
        const next = head.*.next;
        const h: *c.MVMGCPassedWork = head;
        const tag = @intFromPtr(h.items[0]);
        try std.testing.expect(tag >= 1 and tag <= seen.len);
        try std.testing.expect(!seen[tag - 1]);
        seen[tag - 1] = true;
        n += 1;
        c.MVM_free(head);
        head = next;
    }
    try std.testing.expectEqual(@as(usize, 2 * pushes_per_thread), n);
}

test "nursery doubles after a run that filled it, up to MVM_NURSERY_SIZE" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    // The main thread starts at the maximum, later threads at
    // MVM_NURSERY_THREAD_START unless the maximum is smaller (collect.c:24-30).
    try std.testing.expectEqual(@as(u32, @min(c.MVM_NURSERY_SIZE, c.MVM_NURSERY_THREAD_START)), c.MVM_gc_new_thread_nursery_size(instance));
    instance.*.main_thread = null;
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), c.MVM_gc_new_thread_nursery_size(instance));
    instance.*.main_thread = tc;
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), tc.*.nursery_tospace_size);
    settle(tc);
    // Pretend the current tospace is half the maximum (its buffer is the
    // full size, so nothing is overrun). The run's blame falls on this
    // thread, so its next tospace doubles (collect.c:90-93) to the maximum,
    // and the fromspace is the half-size space it gave up.
    tc.*.nursery_tospace_size = c.MVM_NURSERY_SIZE / 2;
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(instance.*.thread_to_blame_for_gc == tc);
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE / 2), tc.*.nursery_fromspace_size);
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), tc.*.nursery_tospace_size);
    try std.testing.expectEqual(@intFromPtr(tc.*.nursery_tospace) + c.MVM_NURSERY_SIZE, @intFromPtr(tc.*.nursery_alloc_limit));
    // At the maximum it stays there. This run's old fromspace was labelled
    // half size, so it is freed and a full one allocated (collect.c:100-103);
    // the next run finds the sizes equal and reuses the old fromspace as
    // the new tospace (collect.c:97-98).
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), tc.*.nursery_tospace_size);
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), tc.*.nursery_fromspace_size);
    const from = tc.*.nursery_fromspace;
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(u32, c.MVM_NURSERY_SIZE), tc.*.nursery_tospace_size);
    try std.testing.expectEqual(from, tc.*.nursery_tospace);
}
