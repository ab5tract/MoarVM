//! Tests of `allocation.zig` (the port of src/gc/allocation.c) on a booted VM.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const allocation = @import("../allocation.zig");
const view = @import("../view.zig");

/// From src/zig/test/layout_probe.c: the C compiler's offset of
/// `MVMThreadContext.num_temproots`.
extern fn moar_probe_offsetof_num_temproots() usize;

const Tc = view.Tc;

/// The environment variable that turns the test binary into the child of a
/// "panic" test: the runner takes no filter argument, so the child runs the
/// binary's tests in order and the named test, which comes first in this
/// file, does the panicking call instead of spawning.
const child_var = "MOAR_GC_TEST_CHILD";

fn childMode(name: []const u8) bool {
    const v = std.testing.environ.getPosix(child_var) orelse return false;
    return std.mem.eql(u8, v, name);
}

/// Runs this test binary again with `child_var=name`; returns its result.
fn runChild(name: []const u8) !std.process.RunResult {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put(child_var, name);
    _ = env.swapRemove("ZIG_PROGRESS");
    return std.process.run(gpa, io, .{ .argv = &.{exe}, .environ_map = &env });
}

/// Gives a raw nursery block a header the collector's sweep can step over
/// (a dead type object of the block's size): the sweep walks the nursery by
/// header size, and a zero size would never advance.
fn stampRaw(tc: Tc, p: *anyopaque, size: usize) void {
    const h = view.asCol(p);
    view.flags1(h).* = .{ .type_object = true };
    h.size = @intCast(size);
    h.owner = tc.thread_id;
}

fn seq(instance: [*c]c.MVMInstance) c.AO_t {
    return @atomicLoad(c.AO_t, &instance.*.gc_seq_number, .seq_cst);
}

fn gcStatus(tc: Tc) c.AO_t {
    return @atomicLoad(c.AO_t, &tc.*.gc_status, .seq_cst);
}

/// The st of BOOTInt, which the bootstrap allocates in gen2, so it does not
/// move when the tests collect.
fn bootIntSt(instance: view.Instance) !view.STable {
    const st: view.STable = instance.boot_types.BOOTInt.*.st;
    try std.testing.expect(view.flags2(&st.header).second_gen);
    return st;
}

fn inTospace(tc: Tc, p: ?*anyopaque) bool {
    const a = @intFromPtr(p);
    const lo = @intFromPtr(tc.*.nursery_tospace);
    return a >= lo and a < lo + tc.*.nursery_tospace_size;
}

test "request above MVM_NURSERY_SIZE panics with the C message" {
    if (childMode("oversize")) {
        const instance = c.MVM_vm_create_instance();
        _ = allocation.allocateNursery(instance.*.main_thread, @as(usize, c.MVM_NURSERY_SIZE) + 8);
        return error.TestUnexpectedResult; // not reached: the panic exits
    }
    const r = try runChild("oversize");
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = c.MVM_exitcode_gcalloc }, r.term);
    try std.testing.expect(std.mem.find(u8, r.stderr, "MoarVM panic: Attempt to allocate more than the maximum nursery size\n") != null);
}

test "MVMThreadContext layout as the C compiler sees it" {
    try std.testing.expectEqual(moar_probe_offsetof_num_temproots(), @offsetOf(c.MVMThreadContext, "num_temproots"));
}

test "nursery allocation is 8-aligned, zeroed and bumps alloc" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const before = @intFromPtr(tc.*.nursery_alloc);
    const p = allocation.allocateNursery(tc, 24);
    try std.testing.expectEqual(before, @intFromPtr(p));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 8);
    const bytes: [*]const u8 = @ptrCast(p);
    for (bytes[0..24]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(before + 24, @intFromPtr(tc.*.nursery_alloc));
    stampRaw(tc, p, 24);
    // An unaligned request is padded by MVM_ALIGN_SIZE, which is the
    // identity where the config allows unaligned 64-bit access.
    const unaligned_ok = @hasDecl(c, "MVM_CAN_UNALIGNED_INT64") and @hasDecl(c, "MVM_CAN_UNALIGNED_NUM64");
    try std.testing.expectEqual(@as(usize, if (unaligned_ok) 13 else 16), allocation.alignSize(13));
    const q = allocation.allocateNursery(tc, 13);
    try std.testing.expectEqual(before + 24, @intFromPtr(q));
    try std.testing.expectEqual(before + 24 + allocation.alignSize(13), @intFromPtr(tc.*.nursery_alloc));
    stampRaw(tc, q, 13);
}

test "request larger than the remaining space collects and retries" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const st = try bootIntSt(instance);
    try std.testing.expect(st.*.size < 100);
    // Fill with real (unrooted) objects to within 100 bytes of the limit;
    // no allocation here collects, as each leaves more than 100 - size.
    while (@intFromPtr(tc.*.nursery_alloc_limit) - @intFromPtr(tc.*.nursery_alloc) > 100)
        _ = allocation.allocateObject(tc, st);
    const s0 = seq(instance);
    const p = allocation.allocateNursery(tc, 200);
    try std.testing.expectEqual(s0 + 1, seq(instance));
    try std.testing.expect(inTospace(tc, p));
    stampRaw(tc, p, 200);
}

test "allocate_object sets st, owner thread id and header flags as C" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const st = try bootIntSt(instance);
    const obj = allocation.allocateObject(tc, st);
    // allocation.c:84-96: the zeroed block, size and owner set, st assigned
    // through the write barrier; flags stay 0 (a nursery object instance).
    try std.testing.expect(obj.*.st == st);
    try std.testing.expectEqual(tc.*.thread_id, obj.*.header.owner);
    try std.testing.expectEqual(@as(c.MVMuint16, @intCast(st.*.size)), obj.*.header.size);
    try std.testing.expectEqual(@as(c.MVMuint8, 0), obj.*.header.flags1);
    try std.testing.expectEqual(@as(c.MVMuint8, 0), obj.*.header.flags2);
    try std.testing.expect(obj.*.header.sc_forward_u.forwarder == null);
    try std.testing.expect(inTospace(tc, obj));
}

test "allocate_stable, allocate_type_object and allocate_frame headers as C" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const int_st = try bootIntSt(instance);
    const next_id = instance.*.cur_type_cache_id;
    const st = allocation.allocateStable(tc, int_st.*.REPR, int_st.*.HOW);
    try std.testing.expectEqual(@as(c.MVMuint8, c.MVM_CF_STABLE), st.*.header.flags1);
    try std.testing.expectEqual(@as(c.MVMuint16, @sizeOf(c.MVMSTable)), st.*.header.size);
    try std.testing.expectEqual(tc.*.thread_id, st.*.header.owner);
    try std.testing.expect(st.*.REPR == int_st.*.REPR);
    try std.testing.expect(st.*.HOW == int_st.*.HOW);
    try std.testing.expect(st.*.debug_name == null);
    try std.testing.expect(st.*.type_cache_id > next_id);
    const tobj = allocation.allocateTypeObject(tc, st);
    try std.testing.expectEqual(@as(c.MVMuint8, c.MVM_CF_TYPE_OBJECT), tobj.*.header.flags1);
    try std.testing.expectEqual(@as(c.MVMuint16, @sizeOf(c.MVMObject)), tobj.*.header.size);
    try std.testing.expectEqual(tc.*.thread_id, tobj.*.header.owner);
    try std.testing.expect(tobj.*.st == st);
    const f = allocation.allocateFrame(tc);
    try std.testing.expectEqual(@as(c.MVMuint8, c.MVM_CF_FRAME), f.*.header.flags1);
    try std.testing.expectEqual(@as(c.MVMuint16, @sizeOf(c.MVMFrame)), f.*.header.size);
    try std.testing.expectEqual(tc.*.thread_id, f.*.header.owner);
}

const Shared = struct {
    tc: Tc,
    /// 1: the second thread is blocked; 2: the main thread's collection is
    /// done; 3: the second thread's collection is done; 4: the second
    /// thread may exit.
    phase: std.atomic.Value(u32) = .init(0),

    fn waitFor(s: *Shared, p: u32) void {
        while (s.phase.load(.seq_cst) != p) std.Thread.yield() catch {};
    }
};

fn secondThread(s: *Shared) void {
    const tc = s.tc;
    c.MVM_set_running_threads_context(tc);
    // A: blocked (NONE -> UNABLE) while the main thread collects.
    c.MVM_gc_mark_thread_blocked(tc);
    s.phase.store(1, .seq_cst);
    s.waitFor(2);
    // B: running again; this thread starts a collection, which sets the
    // main thread's status NONE -> INTERRUPT.
    c.MVM_gc_mark_thread_unblocked(tc);
    c.MVM_gc_enter_from_allocator(tc);
    s.phase.store(3, .seq_cst);
    s.waitFor(4);
    // Exit as src/core/threads.c start_thread does: exited, then blocked,
    // so a later collection clears the nursery and destroys the context.
    @atomicStore(c.AO_t, &tc.*.thread_obj.*.body.stage, c.MVM_thread_stage_exited, .seq_cst);
    c.MVM_gc_mark_thread_blocked(tc);
}

test "allocation observes INTERRUPT set by another thread" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const st = try bootIntSt(instance);

    // A second registered thread, as MVM_thread_new and MVM_thread_run set
    // one up (src/core/threads.c), without its libuv thread.
    // `thread` stays a temporary root: the collections below move it.
    var thread: [*c]c.MVMThread = @ptrCast(@alignCast(c.MVM_repr_alloc_init(tc, instance.*.Thread)));
    c.MVM_gc_root_temp_push(tc, @ptrCast(&thread));
    defer c.MVM_gc_root_temp_pop(tc);
    const child_tc = c.MVM_tc_create(tc, instance);
    child_tc.*.thread_obj = thread;
    child_tc.*.thread_id = @truncate(1 + @atomicRmw(c.AO_t, &instance.*.next_user_thread_id, .Add, 1, .seq_cst));
    thread.*.body.tc = child_tc;
    thread.*.body.thread_id = child_tc.*.thread_id;
    c.uv_mutex_lock(&instance.*.mutex_threads);
    c.MVM_gc_write_barrier(tc, &thread.*.common.header, @ptrCast(instance.*.threads));
    thread.*.body.next = instance.*.threads;
    instance.*.threads = thread;
    thread.*.body.stage = c.MVM_thread_stage_started;
    c.uv_mutex_unlock(&instance.*.mutex_threads);

    var shared: Shared = .{ .tc = child_tc };
    const t = try std.Thread.spawn(.{}, secondThread, .{&shared});
    shared.waitFor(1);

    // A: the main thread allocates until a collection runs; the blocked
    // thread's work is stolen (UNABLE -> STOLEN -> UNABLE).
    const s0 = seq(instance);
    while (seq(instance) == s0) _ = allocation.allocateObject(tc, st);
    try std.testing.expectEqual(s0 + 1, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_UNABLE), gcStatus(child_tc));
    shared.phase.store(2, .seq_cst);

    // B: wait until the other thread has signalled this one, then a single
    // allocation must see INTERRUPT (the plain read of allocation.c:20) and
    // join the collection (INTERRUPT -> NONE) before bumping.
    while (gcStatus(tc) != c.MVMGCStatus_INTERRUPT) std.Thread.yield() catch {};
    const p = allocation.allocateNursery(tc, 16);
    try std.testing.expectEqual(s0 + 2, seq(instance));
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(tc));
    try std.testing.expect(inTospace(tc, p));
    stampRaw(tc, p, 16);
    shared.waitFor(3);
    try std.testing.expectEqual(@as(c.AO_t, c.MVMGCStatus_NONE), gcStatus(child_tc));

    shared.phase.store(4, .seq_cst);
    t.join();
    // Two collections clear and destroy the exited thread's context.
    c.MVM_gc_enter_from_allocator(tc);
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expectEqual(@as(c.AO_t, c.MVM_thread_stage_destroyed), @atomicLoad(c.AO_t, &thread.*.body.stage, .seq_cst));
}
