//! Tests of the four small ports on a booted VM: `wb.zig` (src/gc/wb.c and
//! the inline barrier of src/gc/wb.h), `objectid.zig` (src/gc/objectid.c),
//! `finalize.zig` (src/gc/finalize.c) and `debug.zig` (src/gc/debug.c, only
//! at -Dgc-debug=1). The collections are real ones, started through
//! `MVM_gc_enter_from_allocator`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const view = @import("../view.zig");
const wb = @import("../wb.zig");
const objectid = @import("../objectid.zig");
const finalize = @import("../finalize.zig");
const debug = @import("../debug.zig");

const Tc = view.Tc;
const Object = c.MVMObject;

fn inNursery(tc: Tc, p: anytype) bool {
    const a = @intFromPtr(p);
    const lo = @intFromPtr(tc.nursery_tospace);
    return a >= lo and a < lo + tc.nursery_tospace_size;
}

fn hashed(tc: Tc, obj: *Object) bool {
    return c.MVM_ptr_hash_fetch(tc, &tc.instance.*.object_ids, obj) != null;
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
    const tc: Tc = instance.*.main_thread;
    c.MVM_gc_allocate_gen2_default_set(tc);
    var holder: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    c.MVM_gc_allocate_gen2_default_clear(tc);
    var value: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.rootN(tc, .{ &holder, &value });
    defer r.pop(tc);
    const h = view.asCol(holder.?);
    const v = view.asCol(value.?);
    try std.testing.expect(view.flags2(h).second_gen);
    try std.testing.expect(!view.flags2(h).in_gen2_root_list);
    try std.testing.expect(!view.flags2(v).ref_from_gen2);
    const before = tc.num_gen2roots;

    wb.hit(tc, h);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
    try std.testing.expect(view.flags2(h).in_gen2_root_list);
    try std.testing.expectEqual(@intFromPtr(h), @intFromPtr(tc.gen2roots[before]));
    // Already on the list: not added again.
    wb.hit(tc, h);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
    // hit_by: still once, and the referenced object is marked.
    wb.hitBy(tc, h, v);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
    try std.testing.expect(view.flags2(v).ref_from_gen2);
    // Off the list again, hit_by adds it (wb.c:14-19).
    view.flags2(h).in_gen2_root_list = false;
    tc.num_gen2roots = before;
    wb.hitBy(tc, h, v);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
    try std.testing.expect(view.flags2(h).in_gen2_root_list);
}

test "write barrier without updating referenced fires only from gen2 to nursery" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: Tc = instance.*.main_thread;
    c.MVM_gc_allocate_gen2_default_set(tc);
    var old_a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    var old_b: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    c.MVM_gc_allocate_gen2_default_clear(tc);
    var young: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    var young_too: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.rootN(tc, .{ &old_a, &old_b, &young, &young_too });
    defer r.pop(tc);
    const g = view.asCol(old_a.?);
    const g2 = view.asCol(old_b.?);
    const n = view.asCol(young.?);
    const n2 = view.asCol(young_too.?);
    try std.testing.expect(view.flags2(g).second_gen and view.flags2(g2).second_gen);
    try std.testing.expect(!view.flags2(n).second_gen and !view.flags2(n2).second_gen);
    const before = tc.num_gen2roots;

    // (wb.h:13-16) Not from gen2, a NULL referenced, or a gen2 referenced:
    // no hit.
    wb.noUpdateReferenced(tc, n, n2);
    wb.noUpdateReferenced(tc, g, null);
    wb.noUpdateReferenced(tc, g, g2);
    try std.testing.expectEqual(before, tc.num_gen2roots);
    try std.testing.expect(!view.flags2(g).in_gen2_root_list);
    // Gen2 to nursery: the root is added once, the referenced left as it is.
    wb.noUpdateReferenced(tc, g, n);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
    try std.testing.expect(view.flags2(g).in_gen2_root_list);
    try std.testing.expectEqual(@intFromPtr(g), @intFromPtr(tc.gen2roots[before]));
    try std.testing.expect(!view.flags2(n).ref_from_gen2);
    wb.noUpdateReferenced(tc, g, n);
    try std.testing.expectEqual(before + 1, tc.num_gen2roots);
}

test "object_id is stable across a collection and clear removes it" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: Tc = instance.*.main_thread;
    settle(tc);

    // A gen2 object's id is its address (objectid.c:9-11).
    const old: *Object = instance.*.VMNull;
    try std.testing.expect(view.flags2(&old.header).second_gen);
    try std.testing.expectEqual(@as(u64, @intFromPtr(old)), objectid.objectId(tc, old));

    var a: ?*Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const r = moar.root(tc, &a);
    defer r.pop(tc);
    const born = a.?;
    try std.testing.expect(inNursery(tc, born));
    const id = objectid.objectId(tc, born);
    try std.testing.expect(view.flags1(&born.header).has_object_id);
    try std.testing.expect(hashed(tc, born));
    // Asked again: the same id from the hash.
    try std.testing.expectEqual(id, objectid.objectId(tc, born));

    // The collection promotes it straight to the reserved gen2 address
    // (collect.c:253-260), through use_allocation, which drops the entry
    // and the flag.
    c.MVM_gc_enter_from_allocator(tc);
    const moved = a.?;
    try std.testing.expectEqual(id, @as(u64, @intFromPtr(moved)));
    try std.testing.expect(view.flags2(&moved.header).second_gen);
    try std.testing.expect(!view.flags1(&moved.header).has_object_id);
    try std.testing.expect(!hashed(tc, born));
    try std.testing.expectEqual(id, objectid.objectId(tc, moved));

    // A nursery object with an id that dies: the sweep clears its entry
    // (collect.c:571-572).
    const dying: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    _ = objectid.objectId(tc, dying);
    try std.testing.expect(hashed(tc, dying));
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(!hashed(tc, dying));

    // clear and use_allocation directly.
    const other: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const other_id = objectid.objectId(tc, other);
    objectid.clear(tc, &other.header);
    try std.testing.expect(!hashed(tc, other));
    // clear leaves the flag (objectid.c:50-54); use_allocation toggles it.
    try std.testing.expect(view.flags1(&other.header).has_object_id);
    view.flags1(&other.header).has_object_id = false;
    const third: *Object = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    const third_id = objectid.objectId(tc, third);
    try std.testing.expect(third_id != other_id);
    try std.testing.expectEqual(@as(usize, @intCast(third_id)), @intFromPtr(objectid.useAllocation(tc, &third.header)));
    try std.testing.expect(!view.flags1(&third.header).has_object_id);
    try std.testing.expect(!hashed(tc, third));
}

test "finalize_set marks the type and add_to_queue grows the queue" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: Tc = instance.*.main_thread;
    const ty: *Object = instance.*.boot_types.BOOTException;
    const st = ty.st;
    const flags_before = st.*.mode_flags;
    try std.testing.expect(flags_before & c.MVM_FINALIZE_TYPE == 0);
    finalize.set(tc, ty, true);
    try std.testing.expectEqual(flags_before | c.MVM_FINALIZE_TYPE, st.*.mode_flags);
    finalize.set(tc, ty, true);
    try std.testing.expectEqual(flags_before | c.MVM_FINALIZE_TYPE, st.*.mode_flags);

    // The allocator queues an object of a finalizable type
    // (allocation.c MVM_gc_allocate_object).
    const n0 = tc.num_finalize;
    var obj: ?*Object = c.MVM_repr_alloc_init(tc, ty);
    const r = moar.root(tc, &obj);
    defer r.pop(tc);
    try std.testing.expectEqual(n0 + 1, tc.num_finalize);
    try std.testing.expectEqual(@intFromPtr(obj.?), @intFromPtr(tc.finalize[n0]));
    // Growth: 64 first, then doubling, keeping the entries.
    try std.testing.expect(tc.alloc_finalize >= 64);
    var alloc = tc.alloc_finalize;
    while (tc.num_finalize < 300) {
        finalize.addToQueue(tc, obj.?);
        if (tc.alloc_finalize != alloc) {
            try std.testing.expectEqual(alloc * 2, tc.alloc_finalize);
            alloc = tc.alloc_finalize;
        }
    }
    try std.testing.expectEqual(@as(u32, 512), tc.alloc_finalize);
    for (tc.finalize[n0..300]) |entry|
        try std.testing.expectEqual(@intFromPtr(obj.?), @intFromPtr(entry));
    tc.num_finalize = n0;

    // Off again; other mode flags untouched.
    finalize.set(tc, ty, false);
    try std.testing.expectEqual(flags_before, st.*.mode_flags);
}

test "finalize queue walk moves finalizable dead objects to finalizing" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: Tc = instance.*.main_thread;
    settle(tc);
    const ty: *Object = instance.*.boot_types.BOOTException;
    finalize.set(tc, ty, true);
    defer finalize.set(tc, ty, false);
    try std.testing.expectEqual(@as(u32, 0), tc.num_finalize);
    try std.testing.expectEqual(@as(u32, 0), tc.num_finalizing);

    var live: ?*Object = c.MVM_repr_alloc_init(tc, ty);
    const r = moar.root(tc, &live);
    defer r.pop(tc);
    _ = c.MVM_repr_alloc_init(tc, ty);
    try std.testing.expectEqual(@as(u32, 2), tc.num_finalize);

    // The run calls MVM_finalize_walk_queues: the dead one goes to
    // finalizing, the live one stays queued at its new address
    // (finalize.c:53-65).
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(u32, 1), tc.num_finalizing);
    try std.testing.expectEqual(@as(u32, 1), tc.num_finalize);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.finalize[0]));
    try std.testing.expect(tc.finalizing[0] != null);

    // Without a current frame the handler does not run and the queue stays.
    try std.testing.expect(tc.cur_frame == null);
    finalize.runHandler(tc);
    try std.testing.expectEqual(@as(u32, 1), tc.num_finalizing);

    // A nursery-only walk keeps gen2 entries as they are; promote the live
    // one, then walk directly with a nursery-only generation.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(view.flags2(&live.?.header).second_gen);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.finalize[0]));
    // Outside a run, so with an empty finalizing list: a non-empty one
    // would start a finalizing collection (finalize.c:75-76).
    tc.num_finalizing = 0;
    finalize.walkQueues(tc, .nursery);
    try std.testing.expectEqual(@as(u32, 1), tc.num_finalize);
    try std.testing.expectEqual(@intFromPtr(live.?), @intFromPtr(tc.finalize[0]));
    try std.testing.expectEqual(@as(u32, 0), tc.num_finalizing);
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
    const tc: Tc = instance.*.main_thread;
    const saved_log = instance.*.gc_debug_log;
    defer instance.*.gc_debug_log = saved_log;
    const f = c.tmpfile() orelse return error.NoTmpfile;
    defer _ = c.fclose(f);
    instance.*.gc_debug_log = f;

    tc.gc_debug_gen2_freed_bytes = 123456789012;
    tc.gc_debug_stables_freed = 7;
    const saved_blame = instance.*.thread_to_blame_for_gc;
    defer instance.*.thread_to_blame_for_gc = saved_blame;
    instance.*.thread_to_blame_for_gc = tc;
    debug.logCollection(tc, tc, true);
    try std.testing.expectEqual(@as(u64, 0), tc.gc_debug_gen2_freed_bytes);
    try std.testing.expectEqual(@as(u32, 0), tc.gc_debug_stables_freed);
    instance.*.thread_to_blame_for_gc = null;
    debug.logCollection(tc, tc, false);
    // The same line through the exported symbol, the one orchestrate.zig
    // calls.
    tc.gc_debug_gen2_freed_bytes = 123456789012;
    tc.gc_debug_stables_freed = 7;
    instance.*.thread_to_blame_for_gc = tc;
    c.MVM_gc_debug_log_collection(tc, tc, 1);

    var expected: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&expected);
    inline for (.{ .{ 1, 1, 123456789012, 7 }, .{ 0, 0, 0, 0 }, .{ 1, 1, 123456789012, 7 } }) |row| {
        try w.print("seq={d} tid={d} full={d} coord={d} from={d} next={d} promoted={d} since_full={d} gen2_freed={d} stables_freed={d} finalizing={d}\n", .{
            @atomicLoad(c.AO_t, &instance.*.gc_seq_number, .seq_cst),
            tc.thread_id,
            row[0],
            row[1],
            tc.nursery_fromspace_size,
            tc.nursery_tospace_size,
            tc.gc_promoted_bytes,
            @atomicLoad(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, .seq_cst),
            row[2],
            row[3],
            tc.num_finalizing,
        });
    }
    var got: [1024]u8 = undefined;
    c.rewind(f);
    const n = c.fread(&got, 1, got.len, f);
    try std.testing.expectEqualStrings(w.buffered(), got[0..n]);
}

/// The oracle's line shape, as the regex
/// `^seq=\d+ tid=\d+ full=[01] coord=[01] from=\d+ next=\d+ promoted=\d+
/// since_full=\d+ gen2_freed=\d+ stables_freed=\d+ finalizing=\d+$`
/// (one line, no newline).
fn isLogLine(line: []const u8) bool {
    const fields = [_][]const u8{ "seq", "tid", "full", "coord", "from", "next", "promoted", "since_full", "gen2_freed", "stables_freed", "finalizing" };
    var it = std.mem.splitScalar(u8, line, ' ');
    inline for (fields) |name| {
        const tok = it.next() orelse return false;
        if (!std.mem.startsWith(u8, tok, name ++ "=")) return false;
        const value = tok[name.len + 1 ..];
        if (comptime std.mem.eql(u8, name, "full") or std.mem.eql(u8, name, "coord")) {
            if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "1")) return false;
        } else {
            if (value.len == 0) return false;
            for (value) |ch| if (!std.ascii.isDigit(ch)) return false;
        }
    }
    return it.next() == null;
}

test "the log line matcher accepts the oracle shape and nothing near it" {
    try std.testing.expect(isLogLine("seq=1 tid=1 full=0 coord=1 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0"));
    try std.testing.expect(!isLogLine("seq=1 tid=1 full=2 coord=1 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0"));
    try std.testing.expect(!isLogLine("seq=1 tid=1 full=0 coord=1 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0"));
    try std.testing.expect(!isLogLine("seq=1 tid=1 full=0 coord=1 from= next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0"));
    try std.testing.expect(!isLogLine("seq=1 tid=1 full=0 coord=1 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0 "));
    try std.testing.expect(!isLogLine("seq=1 tid=1 coord=1 full=0 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0"));
    try std.testing.expect(!isLogLine("seq=-1 tid=1 full=0 coord=1 from=4194304 next=4194304 promoted=0 since_full=0 gen2_freed=0 stables_freed=0 finalizing=0"));
}

// $MVM_GC_LOG is read once per instance, by MVM_vm_create_instance
// (src/moar.c:175-185, under `#if MVM_GC_DEBUG`), so the test sets it
// in-process before creating one.
test "a collection writes oracle-shaped lines to $MVM_GC_LOG" {
    if (comptime c.MVM_GC_DEBUG == 0) return error.SkipZigTest;
    try collectionLogLines();
}

fn collectionLogLines() !void {
    var path = "/tmp/mvm-gc-log-test-XXXXXX".*;
    const fd = c.mkstemp(&path);
    if (fd < 0) return error.NoTempFile;
    _ = c.close(fd);
    defer _ = c.unlink(&path);
    if (c.setenv("MVM_GC_LOG", &path, 1) != 0) return error.SetenvFailed;
    const instance = c.MVM_vm_create_instance();
    _ = c.unsetenv("MVM_GC_LOG");
    defer c.MVM_vm_destroy_instance(instance);
    const tc: Tc = instance.*.main_thread;
    const log = instance.*.gc_debug_log orelse return error.LogNotOpened;

    const seq_before = @atomicLoad(c.AO_t, &instance.*.gc_seq_number, .seq_cst);
    c.MVM_gc_enter_from_allocator(tc);
    // The VM leaves the log open; close it before reading.
    instance.*.gc_debug_log = null;
    _ = c.fclose(log);

    const f = c.fopen(&path, "r") orelse return error.LogNotReadable;
    defer _ = c.fclose(f);
    var got: [1024]u8 = undefined;
    const n = c.fread(&got, 1, got.len, f);
    const text = got[0..n];
    // One line per thread the run worked for (the main thread, which
    // started it and is coord=1, first; then the VM's other threads), each
    // of the oracle's shape and of this run's sequence number.
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
    var seq_buf: [32]u8 = undefined;
    const seq_field = try std.mem.print(&seq_buf, "seq={d} ", .{seq_before + 1});
    var main_buf: [64]u8 = undefined;
    const main_fields = try std.mem.print(&main_buf, "{s}tid={d} full=0 coord=1 ", .{ seq_field, tc.thread_id });
    var lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(isLogLine(line));
        try std.testing.expect(std.mem.startsWith(u8, line, if (count == 0) main_fields else seq_field));
    }
    try std.testing.expect(count >= 1);
}
