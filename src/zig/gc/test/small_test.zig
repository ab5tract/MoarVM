//! Tests of the four small ports on a booted VM: `wb.zig` (src/gc/wb.c),
//! `objectid.zig` (src/gc/objectid.c), `finalize.zig` (src/gc/finalize.c)
//! and `debug.zig` (src/gc/debug.c, only at -Dgc-debug=1). The collections
//! are real ones, started through `MVM_gc_enter_from_allocator`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const wb = @import("../wb.zig");
const objectid = @import("../objectid.zig");
const finalize = @import("../finalize.zig");
const debug = @import("../debug.zig");

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

test "write barrier hit adds the root to the gen2 root list once" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    c.MVM_gc_allocate_gen2_default_set(tc);
    var holder: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    c.MVM_gc_allocate_gen2_default_clear(tc);
    var value: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.rootN(tc, .{ &holder, &value });
    defer r.pop(tc);
    const h = col(holder.?);
    const v = col(value.?);
    try std.testing.expect(h.*.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(h.*.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST == 0);
    try std.testing.expect(v.*.flags2 & c.MVM_CF_REF_FROM_GEN2 == 0);
    const before = tc.*.num_gen2roots;

    wb.hit(tc, h);
    try std.testing.expectEqual(before + 1, tc.*.num_gen2roots);
    try std.testing.expect(h.*.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
    try std.testing.expectEqual(@intFromPtr(h), @intFromPtr(tc.*.gen2roots[before]));
    // Already on the list: not added again.
    wb.hit(tc, h);
    try std.testing.expectEqual(before + 1, tc.*.num_gen2roots);
    // hit_by: still once, and the referenced object is marked.
    wb.hitBy(tc, h, v);
    try std.testing.expectEqual(before + 1, tc.*.num_gen2roots);
    try std.testing.expect(v.*.flags2 & c.MVM_CF_REF_FROM_GEN2 != 0);
    // Off the list again, hit_by adds it (wb.c:14-19).
    h.*.flags2 &= ~@as(u8, c.MVM_CF_IN_GEN2_ROOT_LIST);
    tc.*.num_gen2roots = before;
    wb.hitBy(tc, h, v);
    try std.testing.expectEqual(before + 1, tc.*.num_gen2roots);
    try std.testing.expect(h.*.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
}

test "object_id is stable across a collection and clear removes it" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    settle(tc);
    const ids = &instance.*.object_ids;

    // A gen2 object's id is its address (objectid.c:9-11).
    const old: *Object = instance.*.VMNull;
    try std.testing.expect(old.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expectEqual(@as(u64, @intFromPtr(old)), objectid.objectId(tc, old));

    var a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.root(tc, &a);
    defer r.pop(tc);
    const born = a.?;
    try std.testing.expect(inNursery(tc, born));
    const id = objectid.objectId(tc, born);
    try std.testing.expect(born.header.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0);
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, born) != null);
    // Asked again: the same id from the hash.
    try std.testing.expectEqual(id, objectid.objectId(tc, born));

    // The collection promotes it straight to the reserved gen2 address
    // (collect.c:253-260), through use_allocation, which drops the entry
    // and the flag.
    c.MVM_gc_enter_from_allocator(tc);
    const moved = a.?;
    try std.testing.expectEqual(id, @as(u64, @intFromPtr(moved)));
    try std.testing.expect(moved.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(moved.header.flags1 & c.MVM_CF_HAS_OBJECT_ID == 0);
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, born) == null);
    try std.testing.expectEqual(id, objectid.objectId(tc, moved));

    // A nursery object with an id that dies: the sweep clears its entry
    // (collect.c:571-572).
    const dying: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    _ = objectid.objectId(tc, dying);
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, dying) != null);
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, dying) == null);

    // clear and use_allocation directly.
    const other: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const other_id = objectid.objectId(tc, other);
    objectid.clear(tc, col(other));
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, other) == null);
    // clear leaves the flag (objectid.c:50-54); use_allocation toggles it.
    try std.testing.expect(other.header.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0);
    other.header.flags1 &= ~@as(u8, c.MVM_CF_HAS_OBJECT_ID);
    const third: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const third_id = objectid.objectId(tc, third);
    try std.testing.expect(third_id != other_id);
    try std.testing.expectEqual(@as(usize, @intCast(third_id)), @intFromPtr(objectid.useAllocation(tc, col(third))));
    try std.testing.expect(third.header.flags1 & c.MVM_CF_HAS_OBJECT_ID == 0);
    try std.testing.expect(c.MVM_ptr_hash_fetch(tc, ids, third) == null);
}

test "finalize_set marks the type and add_to_queue grows the queue" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const ty: *Object = instance.*.boot_types.BOOTException;
    const st = ty.st;
    const flags_before = st.*.mode_flags;
    try std.testing.expect(flags_before & c.MVM_FINALIZE_TYPE == 0);
    finalize.set(tc, ty, 1);
    try std.testing.expectEqual(flags_before | c.MVM_FINALIZE_TYPE, st.*.mode_flags);
    finalize.set(tc, ty, 1);
    try std.testing.expectEqual(flags_before | c.MVM_FINALIZE_TYPE, st.*.mode_flags);

    // The allocator queues an object of a finalizable type
    // (allocation.c MVM_gc_allocate_object).
    const n0 = tc.*.num_finalize;
    var obj: ?*Object = c.MVM_repr_alloc_init(tc, ty);
    const r = moar.root(tc, &obj);
    defer r.pop(tc);
    try std.testing.expectEqual(n0 + 1, tc.*.num_finalize);
    try std.testing.expectEqual(@intFromPtr(obj.?), @intFromPtr(tc.*.finalize[n0]));
    // Growth: 64 first, then doubling, keeping the entries.
    try std.testing.expect(tc.*.alloc_finalize >= 64);
    var alloc = tc.*.alloc_finalize;
    while (tc.*.num_finalize < 300) {
        finalize.addToQueue(tc, obj.?);
        if (tc.*.alloc_finalize != alloc) {
            try std.testing.expectEqual(alloc * 2, tc.*.alloc_finalize);
            alloc = tc.*.alloc_finalize;
        }
    }
    try std.testing.expectEqual(@as(u32, 512), tc.*.alloc_finalize);
    for (n0..300) |i|
        try std.testing.expectEqual(@intFromPtr(obj.?), @intFromPtr(tc.*.finalize[i]));
    tc.*.num_finalize = n0;

    // Off again; other mode flags untouched.
    finalize.set(tc, ty, 0);
    try std.testing.expectEqual(flags_before, st.*.mode_flags);
}

test "finalize queue walk moves finalizable dead objects to finalizing" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    settle(tc);
    const ty: *Object = instance.*.boot_types.BOOTException;
    finalize.set(tc, ty, 1);
    defer finalize.set(tc, ty, 0);
    try std.testing.expectEqual(@as(u32, 0), tc.*.num_finalize);
    try std.testing.expectEqual(@as(u32, 0), tc.*.num_finalizing);

    var live: ?*Object = c.MVM_repr_alloc_init(tc, ty);
    const r = moar.root(tc, &live);
    defer r.pop(tc);
    const dead: *Object = c.MVM_repr_alloc_init(tc, ty);
    try std.testing.expectEqual(@as(u32, 2), tc.*.num_finalize);

    // The run calls MVM_finalize_walk_queues: the dead one goes to
    // finalizing, the live one stays queued at its new address
    // (finalize.c:53-65).
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(u32, 1), tc.*.num_finalizing);
    try std.testing.expectEqual(@as(u32, 1), tc.*.num_finalize);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.*.finalize[0]));
    try std.testing.expect(tc.*.finalizing[0] != null);
    _ = dead;

    // Without a current frame the handler does not run and the queue stays.
    try std.testing.expect(tc.*.cur_frame == null);
    finalize.runHandler(tc);
    try std.testing.expectEqual(@as(u32, 1), tc.*.num_finalizing);

    // A nursery-only walk keeps gen2 entries as they are; promote the live
    // one, then walk directly with a nursery-only generation.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(live.?.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.*.finalize[0]));
    // Outside a run, so with an empty finalizing list: a non-empty one
    // would start a finalizing collection (finalize.c:75-76).
    tc.*.num_finalizing = 0;
    finalize.walkQueues(tc, c.MVMGCGenerations_Nursery);
    try std.testing.expectEqual(@as(u32, 1), tc.*.num_finalize);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.*.finalize[0]));
    try std.testing.expectEqual(@as(u32, 0), tc.*.num_finalizing);
}

// The log writer exists only in a `-Dgc-debug=1` build (src/gc/debug.c is
// all under `#if MVM_GC_DEBUG`, and so are the instance and tc fields it
// reads): skipped otherwise.
test "log_collection writes the Task 1 format" {
    if (comptime c.MVM_GC_DEBUG == 0) return error.SkipZigTest;
    try logCollection();
}

fn logCollection() !void {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const saved_log = instance.*.gc_debug_log;
    defer instance.*.gc_debug_log = saved_log;
    const f = c.tmpfile() orelse return error.NoTmpfile;
    defer _ = c.fclose(f);
    instance.*.gc_debug_log = f;

    tc.*.gc_debug_gen2_freed_bytes = 123456789012;
    tc.*.gc_debug_stables_freed = 7;
    const saved_blame = instance.*.thread_to_blame_for_gc;
    defer instance.*.thread_to_blame_for_gc = saved_blame;
    instance.*.thread_to_blame_for_gc = tc;
    debug.logCollection(tc, tc, 1);
    try std.testing.expectEqual(@as(u64, 0), tc.*.gc_debug_gen2_freed_bytes);
    try std.testing.expectEqual(@as(u32, 0), tc.*.gc_debug_stables_freed);
    instance.*.thread_to_blame_for_gc = null;
    debug.logCollection(tc, tc, 0);
    // The same line through the exported symbol: libmoar's writer (the C
    // one before the swap, this port after it).
    tc.*.gc_debug_gen2_freed_bytes = 123456789012;
    tc.*.gc_debug_stables_freed = 7;
    instance.*.thread_to_blame_for_gc = tc;
    c.MVM_gc_debug_log_collection(tc, tc, 1);

    var expected: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&expected);
    inline for (.{ .{ 1, 1, 123456789012, 7 }, .{ 0, 0, 0, 0 }, .{ 1, 1, 123456789012, 7 } }) |row| {
        try w.print("seq={d} tid={d} full={d} coord={d} from={d} next={d} promoted={d} since_full={d} gen2_freed={d} stables_freed={d} finalizing={d}\n", .{
            @atomicLoad(c.AO_t, &instance.*.gc_seq_number, .seq_cst),
            tc.*.thread_id,
            row[0],
            row[1],
            tc.*.nursery_fromspace_size,
            tc.*.nursery_tospace_size,
            tc.*.gc_promoted_bytes,
            @atomicLoad(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, .seq_cst),
            row[2],
            row[3],
            tc.*.num_finalizing,
        });
    }
    var got: [1024]u8 = undefined;
    c.rewind(f);
    const n = c.fread(&got, 1, got.len, f);
    try std.testing.expectEqualStrings(w.buffered(), got[0..n]);
}
