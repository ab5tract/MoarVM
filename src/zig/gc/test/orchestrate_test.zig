//! Tests of `orchestrate.zig` (the port of src/gc/orchestrate.c) on a booted
//! VM: the stop-the-world protocol on one thread, the blocked/unblocked
//! transitions, the coordinator stealing a blocked thread's run, the
//! suspend requests of global destruction, and the debug-only RSS
//! override of the full-collection decision. The two-thread test waits only
//! on observable state (an atomic phase counter and `gc_status`), never on
//! time.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const orchestrate = @import("../orchestrate.zig");

const Tc = [*c]c.MVMThreadContext;
const Object = c.MVMObject;

/// From src/zig/test/layout_probe.c: the C compiler's view of
/// MVMDebugServerData, which translate-c leaves opaque.
extern fn moar_probe_sizeof_debugserver() usize;
extern fn moar_probe_offsetof_debugserver_mutex_cond() usize;
extern fn moar_probe_offsetof_debugserver_tell_threads() usize;
extern fn moar_probe_offsetof_debugserver_request_data() usize;
extern fn moar_probe_offsetof_debugserver_debugspam_protocol() usize;

test "the MVMDebugServerData mirror has the C compiler's layout" {
    const D = orchestrate.DebugServerData;
    try std.testing.expectEqual(moar_probe_sizeof_debugserver(), @sizeOf(D));
    try std.testing.expectEqual(moar_probe_offsetof_debugserver_mutex_cond(), @offsetOf(D, "mutex_cond"));
    try std.testing.expectEqual(moar_probe_offsetof_debugserver_tell_threads(), @offsetOf(D, "tell_threads"));
    try std.testing.expectEqual(moar_probe_offsetof_debugserver_request_data(), @offsetOf(D, "request_data"));
    try std.testing.expectEqual(moar_probe_offsetof_debugserver_debugspam_protocol(), @offsetOf(D, "debugspam_protocol"));
}

fn seq(instance: [*c]c.MVMInstance) c.AO_t {
    return @atomicLoad(c.AO_t, &instance.*.gc_seq_number, .seq_cst);
}

fn gcStatus(tc: Tc) c.AO_t {
    return @atomicLoad(c.AO_t, &tc.*.gc_status, .seq_cst);
}

fn inTospace(tc: Tc, p: anytype) bool {
    const a = @intFromPtr(p);
    const lo = @intFromPtr(tc.*.nursery_tospace);
    return a >= lo and a < lo + tc.*.nursery_tospace_size;
}

/// A second registered thread, as MVM_thread_new and MVM_thread_run set one
/// up (src/core/threads.c), without its libuv thread. `thread` must be a
/// temporary root of the caller while collections run.
fn registerThread(tc: Tc, thread: *[*c]c.MVMThread) Tc {
    const instance = tc.*.instance;
    thread.* = @ptrCast(@alignCast(c.MVM_repr_alloc_init(tc, instance.*.Thread)));
    const child_tc = c.MVM_tc_create(tc, instance);
    child_tc.*.thread_obj = thread.*;
    child_tc.*.thread_id = @truncate(1 + @atomicRmw(c.AO_t, &instance.*.next_user_thread_id, .Add, 1, .seq_cst));
    thread.*.*.body.tc = child_tc;
    thread.*.*.body.thread_id = child_tc.*.thread_id;
    c.uv_mutex_lock(&instance.*.mutex_threads);
    c.MVM_gc_write_barrier(tc, &thread.*.*.common.header, @ptrCast(instance.*.threads));
    thread.*.*.body.next = instance.*.threads;
    instance.*.threads = thread.*;
    thread.*.*.body.stage = c.MVM_thread_stage_started;
    c.uv_mutex_unlock(&instance.*.mutex_threads);
    return child_tc;
}

test "a single thread's collection advances gc_seq_number by one and returns status NONE" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const s0 = seq(instance);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(s0 + 1, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    // The protocol's end state (orchestrate.c:312-338): the start, finish
    // and ack counts are back at zero, the run is marked completed, the
    // in-trays are agreed clear, and the VM is no longer in GC.
    try std.testing.expectEqual(@as(c.AO_t, 0), @atomicLoad(c.AO_t, &instance.*.gc_start, .seq_cst));
    try std.testing.expectEqual(@as(c.AO_t, 0), @atomicLoad(c.AO_t, &instance.*.gc_finish, .seq_cst));
    try std.testing.expectEqual(@as(c.AO_t, 0), @atomicLoad(c.AO_t, &instance.*.gc_ack, .seq_cst));
    try std.testing.expectEqual(@as(c.AO_t, 1), @atomicLoad(c.AO_t, &instance.*.gc_completed, .seq_cst));
    try std.testing.expectEqual(@as(c.AO_t, 0), @atomicLoad(c.AO_t, &instance.*.gc_intrays_clearing, .seq_cst));
    try std.testing.expectEqual(@as(c.MVMuint32, 0), instance.*.in_gc);
    try std.testing.expect(instance.*.thread_to_blame_for_gc == tc);
    // The main thread is its own first work item (orchestrate.c:593).
    try std.testing.expect(tc.*.gc_work_count >= 1);
    try std.testing.expect(tc.*.gc_work[0].tc == tc);
    // A second run advances the sequence number by one again.
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(s0 + 2, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
}

test "a collection keeps a coordinator's pending suspend request" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    // As global destruction leaves a thread it asked after the thread won
    // the gc_start election. signal_all counts it as already interrupted
    // (orchestrate.c:44), so the run goes on with the coordinator's own
    // gc_work entry at INTERRUPT | SUSPEND_REQUEST, and finish_gc's reset
    // keeps that state (orchestrate.c:285-286) instead of producing
    // NONE | SUSPEND_REQUEST. The plain INTERRUPT case, reset to NONE, is
    // the test above.
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_INTERRUPT | c.MVMSuspendState_SUSPEND_REQUEST, .seq_cst);
    const s0 = seq(instance);
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(s0 + 1, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_INTERRUPT | c.MVMSuspendState_SUSPEND_REQUEST), gcStatus(tc));
    // Back to running, so the instance can be destroyed normally.
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_NONE, .seq_cst);
}

test "mark_thread_blocked then unblocked round-trips through UNABLE" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.MVMint32, 0), orchestrate.isThreadBlocked(tc));
    // NONE -> UNABLE (orchestrate.c:348).
    orchestrate.markThreadBlocked(tc);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_UNABLE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.MVMint32, 1), orchestrate.isThreadBlocked(tc));
    // UNABLE -> NONE (orchestrate.c:371).
    orchestrate.markThreadUnblocked(tc);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.MVMint32, 0), orchestrate.isThreadBlocked(tc));
    // is_thread_blocked looks at the status bits only (orchestrate.c:423):
    // STOLEN counts as blocked, a suspend request on UNABLE does not change it.
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_STOLEN, .seq_cst);
    try std.testing.expectEqual(@as(c.MVMint32, 1), orchestrate.isThreadBlocked(tc));
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_UNABLE | c.MVMSuspendState_SUSPEND_REQUEST, .seq_cst);
    try std.testing.expectEqual(@as(c.MVMint32, 1), orchestrate.isThreadBlocked(tc));
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_INTERRUPT, .seq_cst);
    try std.testing.expectEqual(@as(c.MVMint32, 0), orchestrate.isThreadBlocked(tc));
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_NONE, .seq_cst);
}

const Stolen = struct {
    tc: Tc,
    /// The second thread's rooted object: where it was allocated, and the
    /// root slot the collector updates.
    born: ?*Object = null,
    obj: ?*Object = null,
    /// 1: the second thread has allocated and is blocked; 2: the main
    /// thread's collection is done; 3: the second thread is unblocked and
    /// has dropped its root; 4: the second thread may exit.
    phase: std.atomic.Value(u32) = .init(0),

    fn waitFor(s: *Stolen, p: u32) void {
        while (s.phase.load(.seq_cst) != p) std.Thread.yield() catch {};
    }
};

fn stolenThread(s: *Stolen) void {
    const tc = s.tc;
    c.MVM_set_running_threads_context(tc);
    s.obj = c.MVM_repr_alloc_init(tc, tc.*.instance.*.boot_types.BOOTArray);
    s.born = s.obj;
    c.MVM_gc_root_temp_push(tc, @ptrCast(&s.obj));
    // Blocked (NONE -> UNABLE) while the main thread collects: the
    // coordinator steals this thread's run (UNABLE -> STOLEN -> UNABLE).
    orchestrate.markThreadBlocked(tc);
    s.phase.store(1, .seq_cst);
    s.waitFor(2);
    orchestrate.markThreadUnblocked(tc);
    c.MVM_gc_root_temp_pop(tc);
    s.phase.store(3, .seq_cst);
    s.waitFor(4);
    // Exit as src/core/threads.c start_thread does: exited, then blocked,
    // so later collections clear the nursery and destroy the context.
    @atomicStore(c.AO_t, &tc.*.thread_obj.*.body.stage, c.MVM_thread_stage_exited, .seq_cst);
    orchestrate.markThreadBlocked(tc);
}

test "a blocked thread's collection is stolen by the coordinator" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    var thread: [*c]c.MVMThread = null;
    c.MVM_gc_root_temp_push(tc, @ptrCast(&thread));
    defer c.MVM_gc_root_temp_pop(tc);
    const child_tc = registerThread(tc, &thread);

    // The Task 1 per-collection log, into a temporary file (debug builds).
    const has_log = comptime @hasField(c.MVMInstance, "gc_debug_log");
    var log: ?*c.FILE = null;
    if (has_log) {
        log = c.tmpfile() orelse return error.NoTmpfile;
        instance.*.gc_debug_log = log;
    }
    defer if (has_log) {
        instance.*.gc_debug_log = null;
        _ = c.fclose(log);
    };

    var shared: Stolen = .{ .tc = child_tc };
    const t = try std.Thread.spawn(.{}, stolenThread, .{&shared});
    shared.waitFor(1);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_UNABLE), gcStatus(child_tc));
    const born = shared.born.?;
    try std.testing.expect(inTospace(child_tc, born));
    try std.testing.expectEqual(child_tc.*.thread_id, born.header.owner);

    // The main thread's run: the blocked thread is signalled (orchestrate.c:52,
    // UNABLE -> STOLEN), its work added to the coordinator's list, collected
    // by the coordinator, and released (orchestrate.c:275, STOLEN -> UNABLE).
    const s0 = seq(instance);
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(s0 + 1, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_UNABLE), gcStatus(child_tc));
    var stolen_in_work = false;
    for (0..tc.*.gc_work_count) |i| {
        if (tc.*.gc_work[i].tc == child_tc) stolen_in_work = true;
    }
    try std.testing.expect(stolen_in_work);
    // Its object was moved: a nursery copy in the second thread's new
    // tospace, marked seen, still owned by it.
    const moved = shared.obj.?;
    try std.testing.expect(moved != born);
    try std.testing.expect(inTospace(child_tc, moved));
    try std.testing.expect(moved.header.flags2 & c.MVM_CF_NURSERY_SEEN != 0);
    try std.testing.expectEqual(child_tc.*.thread_id, moved.header.owner);
    try std.testing.expect(born.header.flags2 & c.MVM_CF_FORWARDER_VALID != 0);
    try std.testing.expectEqual(@intFromPtr(moved), @intFromPtr(born.header.sc_forward_u.forwarder));

    if (has_log) {
        // The stolen thread's line of this run: coord=0 (the main thread is
        // the thread to blame) and the main thread's sequence number.
        c.rewind(log);
        var buf: [8192]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, log);
        try std.testing.expect(n > 0 and n < buf.len);
        var want_buf: [64]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "seq={d} tid={d} full=", .{ s0 + 1, child_tc.*.thread_id });
        var found = false;
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, want)) {
                try std.testing.expect(std.mem.indexOf(u8, line, " coord=0 ") != null);
                found = true;
            }
        }
        try std.testing.expect(found);
    }

    shared.phase.store(2, .seq_cst);
    shared.waitFor(3);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(child_tc));
    shared.phase.store(4, .seq_cst);
    t.join();
    // Two collections clear and destroy the exited thread's context
    // (orchestrate.c:255-257, then :230-242).
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(@as(c.AO_t, c.MVM_thread_stage_clearing_nursery), @atomicLoad(c.AO_t, &thread.*.body.stage, .seq_cst));
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(@as(c.AO_t, c.MVM_thread_stage_destroyed), @atomicLoad(c.AO_t, &thread.*.body.stage, .seq_cst));
    try std.testing.expect(thread.*.body.tc == null);
}

fn resumeParked(tc: Tc) void {
    // Wait until the thread has parked (INTERRUPT | SUSPEND_REQUEST ->
    // UNABLE | SUSPENDED, orchestrate.c:352), then clear the suspend bits.
    while (gcStatus(tc) != (c.MVMGCStatus_UNABLE | c.MVMSuspendState_SUSPENDED)) std.Thread.yield() catch {};
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_UNABLE, .seq_cst);
}

test "a suspend request without a debugserver parks until the bits clear" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    try std.testing.expect(instance.*.debugserver == null);
    // As global destruction asks a running thread.
    @atomicStore(c.AO_t, &tc.*.gc_status, c.MVMGCStatus_INTERRUPT | c.MVMSuspendState_SUSPEND_REQUEST, .seq_cst);
    const s0 = seq(instance);
    const t = try std.Thread.spawn(.{}, resumeParked, .{tc});
    // orchestrate.c:724-735: blocked, sleep until no suspend bit, unblocked,
    // return without joining a GC run.
    orchestrate.enterFromInterrupt(tc);
    t.join();
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(s0, seq(instance));
}

test "global_destruction asks the other running and blocked threads to suspend" {
    // The instance is not destroyed afterwards: MVM_vm_destroy_instance
    // runs global destruction itself, and a second pass would free the
    // heap twice. The steps destroy_instance takes before it are taken
    // here in its order (src/moar.c:730-746).
    const instance = c.MVM_vm_create_instance();
    const tc = instance.*.main_thread;
    c.MVM_thread_join_foreground(tc);
    c.MVM_io_flush_standard_handles(tc);
    c.MVM_spesh_worker_stop(tc);
    c.MVM_spesh_worker_join(tc);
    c.MVM_io_eventloop_destroy(tc);
    orchestrate.enterFromAllocator(tc);
    c.MVM_profile_instrumented_free_data(tc);
    // Four other registered threads for the loop over the threads
    // (orchestrate.c:819-855): one running, one blocked, one in the middle
    // of a GC run, and one already cleaned up (no tc left).
    var threads: [4][*c]c.MVMThread = @splat(null);
    for (&threads) |*t| c.MVM_gc_root_temp_push(tc, @ptrCast(t));
    var others: [4]Tc = undefined;
    for (&threads, &others) |*t, *o| o.* = registerThread(tc, t);
    c.MVM_gc_root_temp_pop_n(tc, threads.len);
    const running = others[0];
    const blocked = others[1];
    const busy = others[2];
    @atomicStore(c.AO_t, &blocked.*.gc_status, c.MVMGCStatus_UNABLE, .seq_cst);
    @atomicStore(c.AO_t, &busy.*.gc_status, c.MVMGCStatus_INTERRUPT, .seq_cst);
    threads[3].*.body.tc = null;
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(running));
    const fromspace = tc.*.nursery_fromspace;
    const tospace = tc.*.nursery_tospace;
    orchestrate.globalDestruction(tc);
    // The caller was blocked around the loop and is running again
    // (orchestrate.c:816, :858); the running thread is interrupted with a
    // suspend request (:833), the blocked one keeps UNABLE and gets the
    // suspend bit (:841), and the one in a GC run is left alone (:826-829).
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_INTERRUPT | c.MVMSuspendState_SUSPEND_REQUEST), gcStatus(running));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_UNABLE | c.MVMSuspendState_SUSPEND_REQUEST), gcStatus(blocked));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_INTERRUPT), gcStatus(busy));
    // The faked nursery run swapped the semi-spaces (orchestrate.c:865-867).
    try std.testing.expectEqual(tospace, tc.*.nursery_fromspace);
    try std.testing.expectEqual(fromspace, tc.*.nursery_tospace);
    try std.testing.expect(instance.*.stables_to_free == null);
}

// Needs `instance->gc_debug_rss_override`, which exists only in a
// `-Dgc-debug=1` build (src/core/instance.h, Task 1): skipped otherwise.
test "is_full_collection uses the RSS override at gc-debug 1" {
    if (comptime !@hasField(c.MVMInstance, "gc_debug_rss_override")) return error.SkipZigTest;
    try fullCollectionOverride();
}

fn fullCollectionOverride() !void {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    // Below the absolute minimum the RSS is not consulted (orchestrate.c:433-435).
    @atomicStore(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, c.MVM_GC_GEN2_THRESHOLD_MINIMUM - 1, .seq_cst);
    instance.*.gc_debug_rss_override = 1;
    try std.testing.expectEqual(@as(c.MVMint32, 0), orchestrate.isFullCollection(tc));
    // At the minimum, a pinned resident set of one byte makes any growth
    // exceed the 20 % (orchestrate.c:443-452)...
    @atomicStore(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, c.MVM_GC_GEN2_THRESHOLD_MINIMUM, .seq_cst);
    try std.testing.expectEqual(@as(c.MVMint32, 1), orchestrate.isFullCollection(tc));
    // ... exactly 20 % of the pin is a full run, one byte less is not.
    instance.*.gc_debug_rss_override = 5 * c.MVM_GC_GEN2_THRESHOLD_MINIMUM;
    try std.testing.expectEqual(@as(c.MVMint32, 1), orchestrate.isFullCollection(tc));
    instance.*.gc_debug_rss_override = 5 * c.MVM_GC_GEN2_THRESHOLD_MINIMUM + 1;
    try std.testing.expectEqual(@as(c.MVMint32, 0), orchestrate.isFullCollection(tc));
    // The coordinator takes the decision at the start of the run
    // (orchestrate.c:576) and zeroes the counter on a full one (:632).
    instance.*.gc_debug_rss_override = 1;
    orchestrate.enterFromAllocator(tc);
    try std.testing.expect(instance.*.gc_full_collect != 0);
    try std.testing.expect(@atomicLoad(c.AO_t, &instance.*.gc_promoted_bytes_since_last_full, .seq_cst) < c.MVM_GC_GEN2_THRESHOLD_MINIMUM);
    instance.*.gc_debug_rss_override = 0;
    orchestrate.enterFromAllocator(tc);
    try std.testing.expectEqual(@as(c.MVMuint32, 0), instance.*.gc_full_collect);
}
