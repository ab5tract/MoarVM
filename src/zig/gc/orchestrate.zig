//! Zig port of src/gc/orchestrate.c (lines 1-898): the stop-the-world
//! protocol. A thread whose nursery is full tries to start a run
//! (`enterFromAllocator`); the winner is the coordinator, which signals every
//! other thread to interrupt at its next safe point or steals the run of a
//! thread blocked in C code, counts the participants into `gc_start`,
//! collects its own work list, and then agrees termination with the
//! participants through `gc_finish`, `gc_intrays_clearing`, `gc_completed`
//! and `gc_ack` under `mutex_gc_orchestrate`. The other entry points are the
//! blocked/unblocked transitions of `gc_status`, the interrupt entry
//! (including the debugserver's suspend requests) and global destruction.
//! No behaviour change. The ported functions are Zig-typed over the views of
//! `view.zig` and call the other ports (`collect`, `roots`, `gen2`,
//! `finalize`, `debug`) as Zig; the `MVM_gc_*` exports are thin C-ABI
//! wrappers over them. Every atomic site uses src/zig/gc/atomic.zig (or
//! `moar.trycas` for `MVM_trycas`), keeps the C's operation and `.seq_cst`
//! ordering, and names the C macro and line; `tc->gc_status` is read and
//! written as the `GcStatus` it holds (a status and a suspend state), with
//! every comparison the C makes on the whole word made on the whole word.
//! The libuv mutex and condition calls go through `c.`. `GCDEBUG_LOG`
//! (src/gc/orchestrate.h:45-53) is kept as comptime-guarded blocks:
//! `MVM_GC_DEBUG_LOG_FLAGS` is 0, so, as in the C, they compile to nothing.
//! `#if MVM_GC_DEBUG` and `#if MVM_GC_DEBUG >= 3` are comptime branches on
//! the translated macro.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");
const view = @import("view.zig");
const collect = @import("collect.zig");
const roots = @import("roots.zig");
const gen2_mod = @import("gen2.zig");
const finalize = @import("finalize.zig");
const debug = @import("debug.zig");

const Tc = view.Tc;
const Instance = view.Instance;
const Thread = view.Thread;
const Object = view.Object;
const GcStatus = view.GcStatus;
const Suspend = view.Suspend;
const WhatToDo = collect.WhatToDo;
const Generations = collect.Generations;

// ---- the states of the protocol (src/core/threadcontext.h:1-41) -----------
// The `gc_status` words the C names: a status (`MVMGCStatus_*`) with or
// without a suspend state (`MVMSuspendState_*`). Each is the whole word, as
// the C's `switch`es and `==` tests see it: `none` is `MVMGCStatus_NONE`
// with no suspend bit set, not "the status bits are NONE".

const none: GcStatus = .{ .status = .none };
const interrupt: GcStatus = .{ .status = .interrupt };
const unable: GcStatus = .{ .status = .unable };
const stolen: GcStatus = .{ .status = .stolen };
const interrupt_requested: GcStatus = .{ .status = .interrupt, .suspend_state = .request };
const unable_requested: GcStatus = .{ .status = .unable, .suspend_state = .request };
const unable_suspended: GcStatus = .{ .status = .unable, .suspend_state = .suspended };
const stolen_requested: GcStatus = .{ .status = .stolen, .suspend_state = .request };
const stolen_suspended: GcStatus = .{ .status = .stolen, .suspend_state = .suspended };

/// The whole `gc_status` word, for `MVM_trycas` (which takes words) and
/// the `%lu` of a panic message.
inline fn word(s: GcStatus) usize {
    return @bitCast(s);
}

// ---- helpers --------------------------------------------------------------

/// MVM_GC_DEBUG_ENABLED(flags) (orchestrate.h:47-48).
inline fn gcDebugEnabled(comptime flags: c_int) bool {
    return comptime (c.MVM_GC_DEBUG_LOG_FLAGS & flags) != 0;
}

/// The printf of GCDEBUG_LOG(tc, flags, msg, ...) (orchestrate.h:50-53);
/// callers guard it with `if (comptime gcDebugEnabled(flags))`, the
/// macro's `if`, so its arguments are evaluated only when it logs.
inline fn gcdebugLog(tc: Tc, msg: [*:0]const u8, args: anytype) void {
    // (int)MVM_load(&(tc)->instance->gc_seq_number) (orchestrate.h:53).
    const seq: c_int = @bitCast(@as(c_uint, @truncate(atomic.load(&tc.instance.*.gc_seq_number))));
    _ = @call(.auto, c.printf, .{ msg, @as(c_uint, tc.thread_id), seq } ++ args);
}

/// `tc->thread_id` as a `%d` argument.
inline fn tid(tc: Tc) c_uint {
    return @as(c_uint, tc.thread_id);
}

/// `(void *)p` for a `%p` argument.
inline fn vp(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}

/// `tc->gc_work[0..gc_work_count]`: the threads this one collects for
/// (its own entry first, orchestrate.c:593 and :770). Empty before the
/// first `add_work` allocates the array.
inline fn workList(tc: Tc) []c.MVMWorkThread {
    return if (tc.gc_work == null) &.{} else tc.gc_work[0..tc.gc_work_count];
}

/// `MVM_gc_collect_free_nursery_uncopied(executing, tc, limit)` with the
/// `void *` limit the work list holds: a NULL limit is below any fromspace,
/// so the C's scan does nothing, as `collect.zig`'s export does nothing.
inline fn freeNurseryUncopied(executing: Tc, tc: Tc, limit: ?*anyopaque) void {
    collect.freeNurseryUncopied(executing, tc, @ptrCast(limit orelse return));
}

/// `struct MVMDebugServerData` (src/debug/debugserver.h:118-162), which
/// translate-c demotes to an opaque type because of its two bit-fields
/// (`new_file_shall_suspend : 1` and `new_file_send_backtrace : 1`, which
/// share one `MVMuint8` storage unit under the SysV ABI: `new_file_flags`
/// here). The same fields at the same offsets; the layout probe test in
/// test/orchestrate_test.zig checks the size and the offsets of the fields
/// this file touches against the C compiler.
pub const DebugServerData = extern struct {
    thread: c.uv_thread_t,
    mutex_cond: c.uv_mutex_t,
    mutex_network_send: c.uv_mutex_t,
    mutex_request_list: c.uv_mutex_t,
    tell_threads: c.uv_cond_t,
    tell_worker: c.uv_cond_t,
    request_data: c.MVMDebugServerRequestData,
    port: c.MVMuint32,
    thread_id: c.MVMuint32,
    event_id: c.MVMuint64,
    handle_table: [*c]c.MVMDebugServerHandleTable,
    breakpoints: [*c]c.MVMDebugServerBreakpointTable,
    any_breakpoints_at_all: c.MVMuint32,
    breakpoints_alloc: c.MVMuint32,
    breakpoints_used: c.MVMuint32,
    mutex_breakpoints: c.uv_mutex_t,
    loaded_file_event_id: c.MVMuint64,
    new_file_flags: c.MVMuint8,
    messagepack_data: ?*anyopaque,
    debugspam_network: c.MVMuint8,
    debugspam_protocol: c.MVMuint8,
};

/// `tc->instance->debugserver`, dereferenced as the C does where it is
/// used without a null check (translate-c renders the field `?*`).
inline fn debugserver(tc: Tc) *DebugServerData {
    return @ptrCast(@alignCast(tc.instance.*.debugserver.?));
}

/// `tc->instance->debugserver && tc->instance->debugserver->debugspam_protocol`.
inline fn debugspam(tc: Tc) bool {
    const ds = tc.instance.*.debugserver orelse return false;
    return @as(*DebugServerData, @ptrCast(@alignCast(ds))).debugspam_protocol != 0;
}

/// src/platform/malloc_trim.h, which orchestrate.c includes directly and
/// moar.h does not, so the translation has no declaration of it.
extern fn MVM_malloc_trim() c_int;

/// src/platform/time.h, which orchestrate.c includes directly and moar.h
/// does not, so the translation has no declaration of it either.
extern fn MVM_platform_nanosleep(nanos: c.MVMuint64) void;

// ---- the work list and the signalling -------------------------------------

/// If we have the job of doing GC for a thread, we add it to our work
/// list. (orchestrate.c:5-21)
fn addWork(tc: Tc, stolen_tc: Tc) void {
    for (workList(tc)) |work|
        if (work.tc == stolen_tc)
            return;
    if (tc.gc_work == null) {
        tc.gc_work_size = 16;
        tc.gc_work = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, tc.gc_work_size) * @sizeOf(c.MVMWorkThread))));
    } else if (tc.gc_work_count == tc.gc_work_size) {
        tc.gc_work_size *%= 2;
        tc.gc_work = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.gc_work), @as(usize, tc.gc_work_size) * @sizeOf(c.MVMWorkThread))));
    }
    tc.gc_work[tc.gc_work_count].tc = stolen_tc;
    tc.gc_work_count += 1;
}

/// The default case of signal_one_thread's switch (orchestrate.c:66-68):
/// a `gc_status` word that is none of its cases. MVM_panic does not
/// return, so the C's `return 0` after it (:68) has no counterpart.
fn invalidStatus(to_signal: Tc) noreturn {
    // MVM_load(&to_signal->gc_status) (orchestrate.c:67).
    c.MVM_panic(c.MVM_exitcode_gcorch, "invalid status %" ++ c.MVM_PRSz ++ " in GC orchestrate\n", word(atomic.loadStatus(view.gcStatus(to_signal))));
}

/// Goes through all threads but the current one and notifies them that a
/// GC run is starting. Those that are blocked are considered excluded from
/// the run, and are not counted. Returns the count of threads that should be
/// added to the finished countdown. (orchestrate.c:23-71)
fn signalOneThread(tc: Tc, to_signal: Tc) u32 {
    // Loop here since we may not succeed first time (e.g. the status of the
    // thread may change between the two ways we try to twiddle it).
    var had_suspend_request: Suspend = .none;
    const slot = view.gcStatus(to_signal);
    while (true) {
        // MVM_load(&to_signal->gc_status) (orchestrate.c:32).
        const current = atomic.loadStatus(slot);
        // The C switches on the whole word (orchestrate.c:33): each case is
        // one status with one suspend state, and any other word, a status
        // with a suspend state no case names included, is the default and
        // panics. The status chooses the arm; the arm tests the whole word
        // against the C's cases, in the C's order.
        switch (current.status) {
            .none => {
                if (current != none) invalidStatus(to_signal);
                // Try to set it from running to interrupted - the common case.
                // MVM_cas(&to_signal->gc_status, MVMGCStatus_NONE,
                //     MVMGCStatus_INTERRUPT) == MVMGCStatus_NONE (orchestrate.c:36).
                if (atomic.casStatus(slot, none, interrupt) == none) {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Signalled thread %d to interrupt\n", .{tid(to_signal)});
                    return 1;
                }
            },
            .interrupt => {
                // MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST and
                // MVMGCStatus_INTERRUPT (orchestrate.c:42-43).
                if (current != interrupt_requested and current != interrupt) invalidStatus(to_signal);
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : thread %d already interrupted\n", .{tid(to_signal)});
                return 0;
            },
            .unable => {
                // The two suspend cases (orchestrate.c:46-48) set
                // had_suspend_request and fall through to the UNABLE case
                // (:50), which keeps the value from the previous iteration.
                if (current == unable_requested or current == unable_suspended)
                    had_suspend_request = current.suspend_state
                else if (current != unable)
                    invalidStatus(to_signal);
                // Otherwise, it's blocked; try to set it to work Stolen.
                // MVM_cas(&to_signal->gc_status, MVMGCStatus_UNABLE | had_suspend_request,
                //     MVMGCStatus_STOLEN | had_suspend_request) == (MVMGCStatus_UNABLE | had_suspend_request)
                // (orchestrate.c:52).
                const blocked: GcStatus = .{ .status = .unable, .suspend_state = had_suspend_request };
                if (atomic.casStatus(slot, blocked, .{ .status = .stolen, .suspend_state = had_suspend_request }) == blocked) {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : A blocked thread %d spotted; work stolen\n", .{tid(to_signal)});
                    addWork(tc, to_signal);
                    return 0;
                }
            },
            .stolen => {
                // this case occurs if a child thread is Stolen by its parent
                // before we get to it in the chain. (orchestrate.c:61-63)
                if (current != stolen_requested and current != stolen_suspended and current != stolen) invalidStatus(to_signal);
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : thread %d already stolen (it was a spawning child)\n", .{tid(to_signal)});
                return 0;
            },
        }
    }
}

/// (orchestrate.c:72-103)
fn signalAll(tc: Tc, threads: ?Thread) u32 {
    var count: u32 = 0;
    var cur_thread = threads;
    while (cur_thread) |t| : (cur_thread = t.body.next) {
        // MVM_load(&t->body.stage) (orchestrate.c:76).
        switch (atomic.load(&t.body.stage)) {
            c.MVM_thread_stage_starting, c.MVM_thread_stage_waiting, c.MVM_thread_stage_started => {
                // Don't signal ourself.
                if (t.body.tc != tc)
                    count +%= signalOneThread(tc, t.body.tc);
            },
            c.MVM_thread_stage_exited => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : queueing to clear nursery of thread %d\n", .{tid(t.body.tc)});
                addWork(tc, t.body.tc);
            },
            c.MVM_thread_stage_clearing_nursery => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : queueing to destroy thread %d\n", .{tid(t.body.tc)});
                // last GC run for this thread
                addWork(tc, t.body.tc);
            },
            c.MVM_thread_stage_destroyed => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : found a destroyed thread\n", .{});
                // will be cleaned up (removed from the lists) shortly
            },
            else => {
                // MVM_load(&t->body.stage) (orchestrate.c:98).
                c.MVM_panic(c.MVM_exitcode_gcorch, "Corrupted MVMThread or running threads list: invalid thread stage %" ++ c.MVM_PRSz, atomic.load(&t.body.stage));
            },
        }
    }
    return count;
}

// ---- the in-trays and the end of a run ------------------------------------

/// Does work in a thread's in-tray, if any. Returns true if work was found
/// and done, and false otherwise. (orchestrate.c:105-116)
fn processInTray(tc: Tc, gen: Generations) bool {
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Considering extra work\n", .{});
    // MVM_load(&tc->gc_in_tray) (orchestrate.c:109).
    if (atomic.load(&tc.gc_in_tray) != null) {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Was given extra work by another thread; doing it\n", .{});
        collect.collect(tc, .in_tray, gen);
        return true;
    }
    return false;
}

/// Called by a thread when it thinks it is done with GC. It may get some more
/// work yet, though. (orchestrate.c:118-132)
fn clearIntrays(tc: Tc, gen: Generations) void {
    var did_work: u32 = 1;
    while (did_work != 0) {
        did_work = 0;
        // (MVMThread *)MVM_load(&tc->instance->threads) (orchestrate.c:125).
        var cur_thread: ?Thread = atomic.load(&tc.instance.*.threads);
        while (cur_thread) |t| : (cur_thread = t.body.next) {
            const other: Tc = t.body.tc orelse continue;
            did_work +%= @intFromBool(processInTray(other, gen));
        }
    }
}

/// (orchestrate.c:133-339)
fn finishGc(tc: Tc, gen: Generations, is_coordinator: bool) void {
    const instance: Instance = tc.instance;

    // Do any extra work that we have been passed.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : doing any work in thread in-trays\n", .{});
    var did_work: u32 = 1;
    while (did_work != 0) {
        did_work = 0;
        for (workList(tc)) |work|
            did_work +%= @intFromBool(processInTray(work.tc, gen));
    }

    // Decrement gc_finish to say we're done, and wait for termination.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Voting to finish\n", .{});
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:148).
    c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
    // MVM_decr(&tc->instance->gc_finish) (orchestrate.c:149).
    _ = atomic.decr(&instance.gc_finish);
    // uv_cond_broadcast(&tc->instance->cond_gc_finish) (orchestrate.c:150).
    c.uv_cond_broadcast(&instance.cond_gc_finish);
    // MVM_load(&tc->instance->gc_finish) (orchestrate.c:151).
    while (atomic.load(&instance.gc_finish) != 0)
        // uv_cond_wait(&tc->instance->cond_gc_finish, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:152).
        c.uv_cond_wait(&instance.cond_gc_finish, &instance.mutex_gc_orchestrate);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:153).
    c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Termination agreed\n", .{});

    // Co-ordinator should do final check over all the in-trays, and trigger
    // collection until all is settled. Rest should wait. Additionally, after
    // in-trays are settled, coordinator walks threads looking for anything
    // that needs adding to the finalize queue. It then will make another
    // iteration over in-trays to handle cross-thread references to objects
    // needing finalization. For full collections, collected objects are then
    // cleaned from all inter-generational sets, and finally any objects to
    // be freed at the fixed size allocator's next safepoint are freed.
    if (is_coordinator) {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling in-tray clearing completion\n", .{});
        clearIntrays(tc, gen);

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling finalizers\n", .{});
        finalize.walkQueues(tc, gen);
        clearIntrays(tc, gen);

        if (gen == .both) {
            // (MVMThread *)MVM_load(&tc->instance->threads) (orchestrate.c:175).
            var cur_thread: ?Thread = atomic.load(&instance.threads);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling inter-gen root cleanup\n", .{});
            while (cur_thread) |t| : (cur_thread = t.body.next) {
                const other: Tc = t.body.tc orelse continue;
                roots.gen2Cleanup(other);
            }
        }

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator heapsnapshot or instrumented profiler data output\n", .{});
        c.MVM_profile_dump_instrumented_data(tc);
        c.MVM_profile_heap_take_snapshot(tc);

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling allocator safepoint frees\n", .{});
        c.MVM_alloc_safepoint(tc);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator signalling in-trays clear\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:195).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_store(&tc->instance->gc_intrays_clearing, 0) (orchestrate.c:196).
        atomic.store(&instance.gc_intrays_clearing, 0);
        // uv_cond_broadcast(&tc->instance->cond_gc_intrays_clearing) (orchestrate.c:197).
        c.uv_cond_broadcast(&instance.cond_gc_intrays_clearing);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:198).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
    } else {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Waiting for in-tray clearing completion\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:203).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_load(&tc->instance->gc_intrays_clearing) (orchestrate.c:204).
        while (atomic.load(&instance.gc_intrays_clearing) != 0)
            // uv_cond_wait(&tc->instance->cond_gc_intrays_clearing, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:205).
            c.uv_cond_wait(&instance.cond_gc_intrays_clearing, &instance.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:206).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Got in-tray clearing complete notice\n", .{});
    }

    // Reset GC status flags. This is also where thread destruction happens,
    // and it needs to happen before we acknowledge this GC run is finished.
    // The slice is stable across the loop: nothing in the body calls addWork
    // on tc (only signalAll/enterFromInterrupt do, before runGc), so the C's
    // per-iteration re-read of gc_work/gc_work_count reads the same.
    for (workList(tc)) |*work| {
        const other: Tc = work.tc;
        const thread_obj: Thread = other.thread_obj;
        // MVM_load(&thread_obj->body.stage) == MVM_thread_stage_clearing_nursery (orchestrate.c:216).
        const destroying = atomic.load(&thread_obj.body.stage) == c.MVM_thread_stage_clearing_nursery;

        // Free gen2 unmarked if full collection. A thread being destroyed is
        // swept too, before its gen2 is transferred
        if (gen == .both) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : freeing gen2 of thread %d%s\n", .{ tid(other), @as([*:0]const u8, if (destroying) " before transfer" else "") });
            collect.freeGen2Unmarked(tc, other, false);
            // Tell malloc implementation to free empty pages to kernel.
            // Currently only activated for Linux.
            _ = MVM_malloc_trim();
        }

        if (destroying) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : transferring gen2 of thread %d\n", .{tid(other)});
            gen2_mod.transfer(other, tc);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : destroying thread %d\n", .{tid(other)});
            // #if MVM_GC_DEBUG (orchestrate.c:236-239)
            if (comptime c.MVM_GC_DEBUG != 0) {
                // Its log line now: it is gone by the end of finish_gc.
                debug.logCollection(tc, other, gen == .both);
            }
            // tc->gc_work[i].tc = thread_obj->body.tc = NULL; (orchestrate.c:240)
            thread_obj.body.tc = null;
            work.tc = null;
            c.MVM_tc_destroy(other);
            // MVM_store(&thread_obj->body.stage, MVM_thread_stage_destroyed) (orchestrate.c:242).
            atomic.store(&thread_obj.body.stage, c.MVM_thread_stage_destroyed);
        } else {
            // Contribute this thread's promoted bytes.
            // MVM_add(&tc->instance->gc_promoted_bytes_since_last_full, other->gc_promoted_bytes) (orchestrate.c:246).
            _ = atomic.add(&instance.gc_promoted_bytes_since_last_full, other.gc_promoted_bytes);

            // Collect nursery.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : collecting nursery uncopied of thread %d\n", .{tid(other)});
            freeNurseryUncopied(tc, other, work.limit);

            // Handle exited threads.
            // MVM_load(&thread_obj->body.stage) == MVM_thread_stage_exited (orchestrate.c:255).
            if (atomic.load(&thread_obj.body.stage) == c.MVM_thread_stage_exited) {
                // Don't bother freeing gen2; we'll do it next time
                // MVM_store(&thread_obj->body.stage, MVM_thread_stage_clearing_nursery) (orchestrate.c:257).
                atomic.store(&thread_obj.body.stage, c.MVM_thread_stage_clearing_nursery);
                // (int)MVM_load(&thread_obj->body.stage) (orchestrate.c:260).
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : set thread %d clearing nursery stage to %d\n", .{ tid(other), @as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&thread_obj.body.stage))))) });
            }

            // #if MVM_GC_DEBUG >= 3 (orchestrate.c:263-265)
            if (comptime c.MVM_GC_DEBUG >= 3) {
                @memset(@as([*]u8, @ptrCast(other.nursery_fromspace))[0..other.nursery_fromspace_size], 0xef);
            }

            // Mark thread free to continue.
            const slot = view.gcStatus(other);
            while (true) {
                // MVM_load(&other->gc_status) (orchestrate.c:271); the C
                // splits the word into status_bits (& MVMGCSTATUS_MASK) and
                // suspend_bits (& MVMSUSPENDSTATUS_MASK) (:272-273).
                const current = atomic.loadStatus(slot);
                const suspend_bits = current.suspend_state;
                switch (current.status) {
                    .stolen => {
                        // MVM_cas(&other->gc_status, MVMGCStatus_STOLEN | suspend_bits, MVMGCStatus_UNABLE | suspend_bits)
                        //     == (MVMGCStatus_STOLEN | suspend_bits) (orchestrate.c:275).
                        const was_stolen: GcStatus = .{ .status = .stolen, .suspend_state = suspend_bits };
                        if (atomic.casStatus(slot, was_stolen, .{ .status = .unable, .suspend_state = suspend_bits }) == was_stolen) {
                            break;
                        }
                    },
                    .interrupt => {
                        // A coordinator that was asked to suspend after it won
                        // the election keeps INTERRUPT | SUSPEND_REQUEST, so it
                        // parks at its next safepoint; NONE | SUSPEND_REQUEST
                        // is a state nothing else handles.
                        if (suspend_bits == .request)
                            break;
                        // MVM_cas(&other->gc_status, MVMGCStatus_INTERRUPT | suspend_bits, MVMGCStatus_NONE | suspend_bits)
                        //     == (MVMGCStatus_INTERRUPT | suspend_bits) (orchestrate.c:287).
                        const was_interrupted: GcStatus = .{ .status = .interrupt, .suspend_state = suspend_bits };
                        if (atomic.casStatus(slot, was_interrupted, .{ .status = .none, .suspend_state = suspend_bits }) == was_interrupted) {
                            break;
                        }
                    },
                    // The C's closing else, a panic on an "Invalid GC
                    // status" (orchestrate.c:294-297), cannot be reached:
                    // status_bits holds two bits, and its four values are
                    // the arms of this switch.
                    .none, .unable => break,
                }
            }
        }
    }

    // #if MVM_GC_DEBUG (orchestrate.c:302-310)
    if (comptime c.MVM_GC_DEBUG != 0) {
        // One per-collection log line per thread this one collected (the
        // coordinator's work list, or a non-coordinator's own entry), before
        // gc_completed lets the next run start; threads destroyed above have
        // already written theirs.
        for (workList(tc)) |work| {
            const for_tc: Tc = work.tc orelse continue;
            debug.logCollection(tc, for_tc, gen == .both);
        }
    }

    if (is_coordinator) {
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:313).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_store(&tc->instance->gc_completed, 1) (orchestrate.c:314).
        atomic.store(&instance.gc_completed, 1);
        // uv_cond_broadcast(&tc->instance->cond_gc_completed) (orchestrate.c:315).
        c.uv_cond_broadcast(&instance.cond_gc_completed);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:316).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
    } else {
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:319).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // !MVM_load(&tc->instance->gc_completed) (orchestrate.c:320).
        while (atomic.load(&instance.gc_completed) == 0)
            // uv_cond_wait(&tc->instance->cond_gc_completed, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:321).
            c.uv_cond_wait(&instance.cond_gc_completed, &instance.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:322).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
    }

    // Signal acknowledgement of completing the cleanup,
    // except for STables, and if we're the final to do
    // so, free the STables, which have been linked.
    // MVM_decr(&tc->instance->gc_ack) == 2 (orchestrate.c:328): the value before the decrement.
    if (atomic.decr(&instance.gc_ack) == 2) {
        // Set it to zero (we're guaranteed the only ones trying to write to
        // it here). Actual STable free in MVM_gc_enter_from_allocator.
        // MVM_store(&tc->instance->gc_ack, 0) (orchestrate.c:331).
        atomic.store(&instance.gc_ack, 0);

        // Also clear in GC flag.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:334).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        instance.in_gc = 0;
        // uv_cond_broadcast(&tc->instance->cond_blocked_can_continue) (orchestrate.c:336).
        c.uv_cond_broadcast(&instance.cond_blocked_can_continue);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:337).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
    }
}

// ---- blocking and unblocking ----------------------------------------------

/// Called by a thread to indicate it is about to enter a blocking operation.
/// This tells any thread that is coordinating a GC run that this thread will
/// be unable to participate. (orchestrate.c:341-364)
pub fn markThreadBlocked(tc: Tc) void {
    const slot = view.gcStatus(tc);
    // This may need more than one attempt.
    while (true) {
        // Try to set it from running to unable - the common case.
        // MVM_cas(&tc->gc_status, MVMGCStatus_NONE, MVMGCStatus_UNABLE) == MVMGCStatus_NONE (orchestrate.c:348).
        if (atomic.casStatus(slot, none, unable) == none)
            return;

        // MVM_cas(&tc->gc_status, MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST,
        //     MVMGCStatus_UNABLE | MVMSuspendState_SUSPENDED) == (MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST)
        // (orchestrate.c:352).
        if (atomic.casStatus(slot, interrupt_requested, unable_suspended) == interrupt_requested)
            return;

        // The only way this can fail is if another thread just decided we're to
        // participate in a GC run.
        // MVM_load(&tc->gc_status) == MVMGCStatus_INTERRUPT (orchestrate.c:358): the whole word.
        if (atomic.loadStatus(slot) == interrupt)
            enterFromInterrupt(tc)
        else
            // MVM_load(&tc->gc_status) (orchestrate.c:362).
            c.MVM_panic(c.MVM_exitcode_gcorch, "Invalid GC status observed \"%lu\" while blocking thread; aborting", @as(c_ulong, word(atomic.loadStatus(slot))));
    }
}

/// Called by a thread to indicate it has completed a block operation and is
/// thus able to particpate in a GC run again. Note that this case needs some
/// special handling if it comes out of this mode when a GC run is taking place.
/// (orchestrate.c:366-412)
pub fn markThreadUnblocked(tc: Tc) void {
    const slot = view.gcStatus(tc);
    const instance: Instance = tc.instance;
    // Try to set it from unable to running.
    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE, MVMGCStatus_NONE) != MVMGCStatus_UNABLE (orchestrate.c:371).
    while (atomic.casStatus(slot, unable, none) != unable) {
        // We can't, presumably because a GC run is going on. We should wait
        // for that to finish before we go on; try using a condvar for it.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:375).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        if (instance.in_gc != 0) {
            // uv_cond_wait(&tc->instance->cond_blocked_can_continue, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:377).
            c.uv_cond_wait(&instance.cond_blocked_can_continue, &instance.mutex_gc_orchestrate);
            // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:379).
            c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
        } else {
            // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:382).
            c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);
            // (MVM_load(&tc->gc_status) & MVMSUSPENDSTATUS_MASK) == MVMSuspendState_SUSPEND_REQUEST (orchestrate.c:383).
            if (atomic.loadStatus(slot).suspend_state == .request) {
                while (true) {
                    // Let's try to unblock into INTERRUPT mode and keep the
                    // suspend request, then immediately enter_from_interrupt,
                    // so we actually wait to be woken up.
                    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE | MVMSuspendState_SUSPEND_REQUEST,
                    //     MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST) == (MVMGCStatus_UNABLE | MVMSuspendState_SUSPEND_REQUEST)
                    // (orchestrate.c:388).
                    if (atomic.casStatus(slot, unable_requested, interrupt_requested) == unable_requested) {
                        enterFromInterrupt(tc);
                        break;
                    }
                    // If we're being resumed while trying to unblock into
                    // suspend request, we'd block forever. Therefor we have
                    // to check if we've been un-requested.
                    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE, MVMGCStatus_NONE) == MVMGCStatus_UNABLE (orchestrate.c:397).
                    if (atomic.casStatus(slot, unable, none) == unable) {
                        return;
                    }
                }
                // MVM_load(&tc->gc_status) == MVMGCStatus_NONE (orchestrate.c:403): the whole word.
            } else if (atomic.loadStatus(slot) == none) {
                if (debugspam(tc))
                    _ = c.fprintf(c.stderr, "marking thread %d unblocked, but its status is already NONE.\n", tid(tc));
                break;
            } else {
                _ = c.MVM_platform_thread_yield();
            }
        }
    }
}

/// Checks if a thread has marked itself as blocked. Considers that the GC may
/// have stolen its work and marked it as such also. So what this really
/// answers is, "did this thread mark itself blocked, and since then not mark
/// itself unblocked", which is useful if you need to conditionally unblock
/// or re-block. If the status changes from blocked to stolen or stolen to
/// blocked between checking this and calling unblock, it's safe anyway since
/// these cases are handled in MVM_gc_mark_thread_unblocked. Note that this
/// relies on a thread itself only ever calling block/unblock.
/// (orchestrate.c:414-426)
pub fn isThreadBlocked(tc: Tc) bool {
    // MVM_load(&(tc->gc_status)) & MVMGCSTATUS_MASK (orchestrate.c:423): the status bits only.
    const gc_status = atomic.loadStatus(view.gcStatus(tc)).status;
    return gc_status == .unable or
        gc_status == .stolen;
}

// ---- a run ------------------------------------------------------------------

/// (orchestrate.c:428-453) `pub` only for the tests; not exported.
pub fn isFullCollection(tc: Tc) bool {
    const instance: Instance = tc.instance;

    // If it's below the absolute minimum, quickly return.
    // (MVMuint64)MVM_load(&tc->instance->gc_promoted_bytes_since_last_full) (orchestrate.c:433).
    const promoted: u64 = atomic.load(&instance.gc_promoted_bytes_since_last_full);
    if (promoted < c.MVM_GC_GEN2_THRESHOLD_MINIMUM)
        return false;

    // If we're heap profiling then don't consider the resident set size, as
    // it will be hugely distorted by the profile data we record.
    if (c.MVM_profile_heap_profiling(tc) != 0)
        return true;

    // Otherwise, consider percentage of resident set size.
    const rss: usize = rss: {
        // #if MVM_GC_DEBUG (orchestrate.c:443-447): the override, when set, is
        // the resident set; otherwise (and always at 0) it is read from libuv
        // (:448-449).
        if (comptime c.MVM_GC_DEBUG != 0) {
            if (instance.gc_debug_rss_override != 0)
                break :rss instance.gc_debug_rss_override;
        }
        var measured: usize = undefined;
        if (c.uv_resident_set_memory(&measured) < 0 or measured == 0)
            measured = 50 * 1024 * 1024;
        break :rss measured;
    };
    const percent_growth = (100 *% promoted) / @as(u64, rss);

    return percent_growth >= c.MVM_GC_GEN2_THRESHOLD_PERCENT;
}

/// (orchestrate.c:455-541)
fn runGc(tc: Tc, what_to_do: WhatToDo) void {
    const instance: Instance = tc.instance;
    const is_coordinator = what_to_do == .all;

    // #if MVM_GC_DEBUG (orchestrate.c:469-472)
    if (comptime c.MVM_GC_DEBUG != 0) {
        if (tc.in_spesh != 0)
            c.MVM_panic(1, "Must not GC when in the specializer/JIT\n");
    }

    // Decide nursery or full collection.
    const gen: Generations = if (instance.gc_full_collect != 0) .both else .nursery;

    const interval_id = c.MVM_telemetry_interval_start(tc, if (instance.gc_full_collect != 0) "start full collection" else "start minor collection");

    const start_time: u64 = if (is_coordinator) c.uv_hrtime() else 0;

    // Do GC work for ourselves and any work threads (the count read once,
    // as the C's `n`). The slice is stable across the loop: nothing in the
    // body calls addWork on tc (only signalAll/enterFromInterrupt do, before
    // runGc), so the C's per-iteration re-read of gc_work/gc_work_count reads
    // the same.
    for (workList(tc)) |*work| {
        const other: Tc = work.tc;
        work.limit = other.nursery_alloc;
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : starting collection for thread %d\n", .{tid(other)});
        other.gc_promoted_bytes = 0;
        if (instance.profiling != 0)
            c.MVM_profiler_log_gen2_roots(tc, other.num_gen2roots, other);
        collect.collect(other, if (other == tc) what_to_do else .no_instance, gen);
    }

    // Wait for everybody to agree we're done.
    finishGc(tc, gen, is_coordinator);

    // Finally, as the very last thing ever, the coordinator pushes a bit of
    // info into the subscription queue (if it is set)

    const subscription_queue: ?Object = instance.subscriptions.subscription_queue;

    if (is_coordinator and subscription_queue != null and instance.subscriptions.GCEvent != null) {
        const end_time = c.uv_hrtime();
        // The C's `instance` (orchestrate.c:508), an instance of GCEvent.
        const event: Object = c.MVM_repr_alloc(tc, instance.subscriptions.GCEvent);

        // (MVMArray *)instance (orchestrate.c:511): the REPR's body view.
        const arrobj: *c.MVMArray = @ptrCast(@alignCast(event));

        c.MVM_repr_pos_set_elems(tc, event, 9);

        const data: [*]u64 = arrobj.body.slots.u64;

        // MVM_load(&tc->instance->gc_seq_number) (orchestrate.c:518).
        data[0] = atomic.load(&instance.gc_seq_number);
        data[1] = start_time / 1000;
        data[2] = (start_time -% instance.subscriptions.vm_startup_hrtime) / 1000;
        data[3] = (end_time -% start_time) / 1000;
        data[4] = @intFromBool(gen == .both);
        data[5] = tc.gc_promoted_bytes;
        // MVM_load(&tc->instance->gc_promoted_bytes_since_last_full) (orchestrate.c:524).
        data[6] = atomic.load(&instance.gc_promoted_bytes_since_last_full);
        data[7] = tc.thread_id;
        data[8] = 0;

        // uv_mutex_lock(&tc->instance->mutex_threads) (orchestrate.c:528).
        c.uv_mutex_lock(&instance.mutex_threads);
        var cur_thread: ?Thread = instance.threads;
        while (cur_thread) |t| : (cur_thread = t.body.next) {
            const other: Tc = t.body.tc orelse continue;
            data[8] +%= other.num_gen2roots;
        }
        // uv_mutex_unlock(&tc->instance->mutex_threads) (orchestrate.c:535).
        c.uv_mutex_unlock(&instance.mutex_threads);

        c.MVM_repr_push_o(tc, instance.subscriptions.subscription_queue, event);
    }

    c.MVM_telemetry_interval_stop(tc, @bitCast(interval_id), "finished run_gc");
}

/// This is called when the allocator finds it has run out of memory and wants
/// to trigger a GC run. In this case, it's possible (probable, really) that it
/// will need to do that triggering, notifying other running threads that the
/// time has come to GC. (orchestrate.c:543-667)
pub fn enterFromAllocator(tc: Tc) void {
    const instance: Instance = tc.instance;
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entered from allocate\n", .{});

    c.MVM_telemetry_timestamp(tc, "gc_enter_from_allocator");

    // Try to start the GC run.
    // MVM_trycas(&tc->instance->gc_start, 0, 1) (orchestrate.c:553).
    if (moar.trycas(&instance.gc_start, @as(usize, 0), @as(usize, 1))) {
        // Stash us as the thread to blame for this GC run (used to give it a
        // potential nursery size boost).
        instance.thread_to_blame_for_gc = tc;

        // Need to wait for other threads to reset their gc_status.
        // MVM_load(&tc->instance->gc_ack) (orchestrate.c:561).
        while (atomic.load(&instance.gc_ack) != 0) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : waiting for other thread's gc_ack\n", .{});
            _ = c.MVM_platform_thread_yield();
        }

        // We are the winner of the GC starting race. This gives us some
        // extra responsibilities as well as doing the usual things.
        // First, increment GC sequence number.
        // MVM_incr(&tc->instance->gc_seq_number) (orchestrate.c:570).
        _ = atomic.incr(&instance.gc_seq_number);
        // (int)MVM_load(&tc->instance->gc_seq_number) (orchestrate.c:573).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : GC thread elected coordinator: starting gc seq %d\n", .{@as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&instance.gc_seq_number)))))});

        // Decide if it will be a full collection.
        instance.gc_full_collect = @intFromBool(isFullCollection(tc));

        c.MVM_telemetry_timestamp(tc, "won the gc starting race");

        // If profiling, record that GC is starting.
        if (instance.profiling != 0)
            c.MVM_profiler_log_gc_start(tc, instance.gc_full_collect, 1);

        // Ensure our stolen list is empty.
        tc.gc_work_count = 0;

        // Flag that we didn't agree on this run that all the in-trays are
        // cleared (a responsibility of the co-ordinator.
        // MVM_store(&tc->instance->gc_intrays_clearing, 1) (orchestrate.c:589).
        atomic.store(&instance.gc_intrays_clearing, 1);
        // MVM_store(&tc->instance->gc_completed, 0) (orchestrate.c:590).
        atomic.store(&instance.gc_completed, 0);

        // We'll take care of our own work.
        addWork(tc, tc);

        // Find other threads, and signal or steal. Also set in GC flag.
        // uv_mutex_lock(&tc->instance->mutex_threads) (orchestrate.c:596).
        c.uv_mutex_lock(&instance.mutex_threads);
        instance.in_gc = 1;
        const num_threads = signalAll(tc, instance.threads);
        // uv_mutex_unlock(&tc->instance->mutex_threads) (orchestrate.c:599).
        c.uv_mutex_unlock(&instance.mutex_threads);

        // Bump the thread count and signal any threads waiting for that.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:602).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_add(&tc->instance->gc_start, num_threads) (orchestrate.c:603).
        _ = atomic.add(&instance.gc_start, num_threads);
        // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:604).
        c.uv_cond_broadcast(&instance.cond_gc_start);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:605).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);

        // If there's an event loop thread, wake it up to participate.
        if (instance.event_loop_wakeup != null)
            _ = c.uv_async_send(instance.event_loop_wakeup);

        // Wait for other threads to be ready.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:612).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_load(&tc->instance->gc_start) > 1 (orchestrate.c:613).
        while (atomic.load(&instance.gc_start) > 1)
            // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:614).
            c.uv_cond_wait(&instance.cond_gc_start, &instance.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:615).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);

        // Sanity check finish votes.
        // MVM_load(&tc->instance->gc_finish) != 0 (orchestrate.c:618), and MVM_load(&tc->instance->gc_finish) (:620) in the message.
        if (atomic.load(&instance.gc_finish) != 0)
            c.MVM_panic(c.MVM_exitcode_gcorch, "Finish votes was %" ++ c.MVM_PRSz ++ "\n", atomic.load(&instance.gc_finish));

        // gc_ack gets an extra so the final acknowledger
        // can also free the STables.
        // MVM_store(&tc->instance->gc_finish, num_threads + 1) (orchestrate.c:624).
        atomic.store(&instance.gc_finish, num_threads + 1);
        // MVM_store(&tc->instance->gc_ack, num_threads + 2) (orchestrate.c:625).
        atomic.store(&instance.gc_ack, num_threads + 2);
        // (int)MVM_load(&tc->instance->gc_finish) (orchestrate.c:627).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : finish votes is %d\n", .{@as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&instance.gc_finish)))))});

        // Now we're ready to start, zero promoted since last full collection
        // counter if this is a full collect.
        if (instance.gc_full_collect != 0)
            // MVM_store(&tc->instance->gc_promoted_bytes_since_last_full, 0) (orchestrate.c:632).
            atomic.store(&instance.gc_promoted_bytes_since_last_full, 0);

        // This is a safe point for us to free any STables that have been marked
        // for deletion in the previous collection (since we let finalization -
        // which appends to this list - happen after we set threads on their
        // way again, it's not safe to do it in the previous collection).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Freeing STables if needed\n", .{});
        collect.freeStables(tc);

        // Signal to the rest to start
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : coordinator signalling start\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:643).
        c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
        // MVM_decr(&tc->instance->gc_start) != 1 (orchestrate.c:644): the value before the
        // decrement; MVM_load(&tc->instance->gc_start) (:645) in the message.
        if (atomic.decr(&instance.gc_start) != 1)
            c.MVM_panic(c.MVM_exitcode_gcorch, "Start votes was %" ++ c.MVM_PRSz ++ "\n", atomic.load(&instance.gc_start));
        // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:646).
        c.uv_cond_broadcast(&instance.cond_gc_start);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:647).
        c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);

        // Start collecting.
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : coordinator entering run_gc\n", .{});
        runGc(tc, .all);

        // If profiling, record that GC is over.
        if (instance.profiling != 0)
            c.MVM_profiler_log_gc_end(tc);

        c.MVM_telemetry_timestamp(tc, "gc finished");

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : GC complete (coordinator)\n", .{});
    } else {
        // Another thread beat us to starting the GC sync process. Thus, act as
        // if we were interrupted to GC.
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Lost coordinator election\n", .{});
        enterFromInterrupt(tc);
    }
}

/// This is called when a thread hits an interrupt at a GC safe point.
///
/// There are two interpretations for this:
/// * That another thread is already trying to start a GC run, so we don't need
///   to try and do that, just enlist in the run.
/// * The debug remote is asking this thread to suspend execution.
///
/// Those cases can be distinguished by the gc state masked with
/// MVMSUSPENDSTATUS_MASK. (orchestrate.c:669-718)
fn reactToDebugserverRequest(tc: Tc) bool {
    if (debugspam(tc))
        _ = c.fprintf(c.stderr, "thread %p has received a request.\n", vp(tc));

    const kind: c.MVMDebugServerRequestKind = debugserver(tc).request_data.kind;

    if (kind == c.MVM_DebugRequest_invoke) {
        const invoke_target = debugserver(tc).request_data.data.invoke.target;
        const args = debugserver(tc).request_data.data.invoke.args;
        debugserver(tc).request_data.data.invoke.target = null;

        // Have to clear the threadcontext's "blocked" status so that invoke
        // can work, for example to run the instruction level barrier.

        // MVM_trycas(&tc->gc_status, MVMGCStatus_UNABLE | MVMSuspendState_SUSPENDED, MVMGCStatus_NONE)
        // (orchestrate.c:694): only its success is used, so `moar.trycas`
        // over the words of the two states.
        if (!moar.trycas(view.gcStatus(tc), word(unable_suspended), word(none))) {
            c.MVM_panic(c.MVM_exitcode_gcorch, "could not unblock/unsuspend thread");
        }

        c.MVM_frame_dispatch(tc, invoke_target, args.*, -1);

        markThreadBlocked(tc);
    } else {
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "this debug request kind not implemented: %d\n", @as(c_int, @bitCast(kind)));
        return false;
    }

    // MVM_cas(&tc->instance->debugserver->request_data.status,
    //     MVM_DebugRequestStatus_sender_is_waiting,
    //     MVM_DebugRequestStatus_receiver_acknowledged) != MVM_DebugRequestStatus_sender_is_waiting
    // (orchestrate.c:708).
    if (atomic.cas(&debugserver(tc).request_data.status, c.MVM_DebugRequestStatus_sender_is_waiting, c.MVM_DebugRequestStatus_receiver_acknowledged) != c.MVM_DebugRequestStatus_sender_is_waiting) {
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "could not acknowledge request?!?\n");
    }
    debugserver(tc).request_data.kind = c.MVM_DebugRequest_empty;

    return true;
}

/// (orchestrate.c:719-804)
pub fn enterFromInterrupt(tc: Tc) void {
    const slot = view.gcStatus(tc);
    const instance: Instance = tc.instance;
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entered from interrupt\n", .{});

    // (MVM_load(&tc->gc_status) & MVMSUSPENDSTATUS_MASK) == MVMSuspendState_SUSPEND_REQUEST (orchestrate.c:723).
    if (atomic.loadStatus(slot).suspend_state == .request) {
        if (instance.debugserver == null) {
            // Without a debugserver there is no condvar to wait on and
            // nobody to send a resume: the only issuer of a suspend request
            // then is MVM_gc_global_destruction, which is tearing the
            // process down. Park the thread, blocked, until the suspend
            // bits clear (in practice, until the process exits).
            markThreadBlocked(tc);
            // (MVM_load(&tc->gc_status) & MVMSUSPENDSTATUS_MASK) != MVMSuspendState_NONE (orchestrate.c:731).
            while (atomic.loadStatus(slot).suspend_state != .none)
                MVM_platform_nanosleep(1000000);
            markThreadUnblocked(tc);
            return;
        }
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "thread %d reacting to suspend request\n", tid(tc));
        markThreadBlocked(tc);
        while (true) {
            // uv_mutex_lock(&tc->instance->debugserver->mutex_cond) (orchestrate.c:740).
            c.uv_mutex_lock(&debugserver(tc).mutex_cond);
            // uv_cond_wait(&tc->instance->debugserver->tell_threads, &tc->instance->debugserver->mutex_cond) (orchestrate.c:741).
            c.uv_cond_wait(&debugserver(tc).tell_threads, &debugserver(tc).mutex_cond);
            // uv_mutex_unlock(&tc->instance->debugserver->mutex_cond) (orchestrate.c:742).
            c.uv_mutex_unlock(&debugserver(tc).mutex_cond);
            // (MVM_load(&tc->gc_status) & MVMSUSPENDSTATUS_MASK) == MVMSuspendState_NONE (orchestrate.c:743).
            if (atomic.loadStatus(slot).suspend_state == .none) {
                if (debugspam(tc))
                    _ = c.fprintf(c.stderr, "thread %d got un-suspended\n", tid(tc));
                break;
            } else {
                if (instance.debugserver != null and debugserver(tc).request_data.target_tc == tc) {
                    if (reactToDebugserverRequest(tc)) {
                        break;
                    }
                }
                if (debugspam(tc))
                    _ = c.fprintf(c.stderr, "thread %p: something happened, but we're still suspended.\n", vp(tc));
            }
        }
        markThreadUnblocked(tc);
        return;
        // MVM_load(&tc->gc_status) == (MVMGCStatus_UNABLE | MVMSuspendState_SUSPENDED) (orchestrate.c:759): the whole word.
    } else if (atomic.loadStatus(slot) == unable_suspended) {
        // The thread that the tc belongs to is already waiting in that loop
        // up there. If we reach this piece of code the active thread must be
        // the debug remote using a suspended thread's ThreadContext.
        return;
    }

    c.MVM_telemetry_timestamp(tc, "gc_enter_from_interrupt");

    // We'll certainly take care of our own work.
    tc.gc_work_count = 0;
    addWork(tc, tc);

    // Indicate that we're ready to GC. Only want to decrement it if it's 2 or
    // greater (0 should never happen; 1 means the coordinator is still counting
    // up how many threads will join in, so we should wait until it decides to
    // decrement.)
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:776).
    c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
    // MVM_load(&tc->instance->gc_start) < 2 (orchestrate.c:777).
    while (atomic.load(&instance.gc_start) < 2)
        // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:778).
        c.uv_cond_wait(&instance.cond_gc_start, &instance.mutex_gc_orchestrate);
    // MVM_decr(&tc->instance->gc_start) (orchestrate.c:779).
    _ = atomic.decr(&instance.gc_start);
    // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:780).
    c.uv_cond_broadcast(&instance.cond_gc_start);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:781).
    c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);

    // If profiling, record that GC is starting.
    // We don't do this before add_work, because the gc_sequence_number
    // may not yet have been increased, leading to duplicate entries
    // in the gc parts of the profiler
    if (instance.profiling != 0)
        c.MVM_profiler_log_gc_start(tc, @intFromBool(isFullCollection(tc)), 0);

    // Wait for all threads to indicate readiness to collect.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Waiting for other threads\n", .{});
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:792).
    c.uv_mutex_lock(&instance.mutex_gc_orchestrate);
    // MVM_load(&tc->instance->gc_start) (orchestrate.c:793).
    while (atomic.load(&instance.gc_start) != 0)
        // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:794).
        c.uv_cond_wait(&instance.cond_gc_start, &instance.mutex_gc_orchestrate);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:795).
    c.uv_mutex_unlock(&instance.mutex_gc_orchestrate);

    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entering run_gc\n", .{});
    runGc(tc, .no_instance);
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : GC complete\n", .{});

    // If profiling, record that GC is over.
    if (instance.profiling != 0)
        c.MVM_profiler_log_gc_end(tc);
}

// ---- global destruction -----------------------------------------------------

/// Run the global destruction phase. (orchestrate.c:806-898)
pub fn globalDestruction(tc: Tc) void {
    const vm: Instance = tc.instance;

    // Ask all other threads to suspend, and wait until they have: each one
    // is either parked (it never allocates again) or blocked in C with the
    // request set (it parks when it unblocks, before touching anything
    // GC-managed), and no GC run is in flight. Then no new run can start:
    // we are the only thread left that could start one. Like the
    // debugserver, mark ourselves blocked meanwhile, so a GC run another
    // thread starts does not wait for us; we are in C code and never reach
    // a safepoint.
    //
    // mutex_threads is held only for one pass over the threads list, never
    // while waiting: a thread that has already won the gc_start election
    // needs it for signal_all, and would otherwise never get to finish its
    // run and park.
    //
    // The wait is bounded (about 2 seconds): a thread that never reaches a
    // safepoint, such as one spinning in native code, is given up on, and
    // we go on as before this wait existed, on a best-effort basis.
    markThreadBlocked(tc);
    for (0..2000) |_| {
        var pending: u32 = 0;

        // uv_mutex_lock(&vm->mutex_threads) (orchestrate.c:836).
        c.uv_mutex_lock(&vm.mutex_threads);

        // A GC run sets in_gc while holding mutex_threads and clears it
        // only after it has destroyed any exiting threads' tcs, so with
        // in_gc clear under mutex_threads no tc can go away during the
        // pass. While a run is in flight, just wait for it.
        // uv_mutex_lock(&vm->mutex_gc_orchestrate) (orchestrate.c:842).
        c.uv_mutex_lock(&vm.mutex_gc_orchestrate);
        const in_gc = vm.in_gc;
        // uv_mutex_unlock(&vm->mutex_gc_orchestrate) (orchestrate.c:844).
        c.uv_mutex_unlock(&vm.mutex_gc_orchestrate);

        var cur_thread: ?Thread = if (in_gc != 0) null else vm.threads;
        while (cur_thread) |t| : (cur_thread = t.body.next) {
            // A thread that has been cleaned up already has no tc left.
            const other: Tc = t.body.tc orelse continue;
            if (other == tc)
                continue;
            const slot = view.gcStatus(other);
            // MVM_load(&other->gc_status) (orchestrate.c:851): the C switches
            // on the whole word; its cases are NONE, UNABLE, UNABLE |
            // SUSPEND_REQUEST and UNABLE | SUSPENDED, and every other word
            // is its default (:871-876).
            const current = atomic.loadStatus(slot);
            switch (current.status) {
                .none => if (current == none) {
                    // Running ordinary code: ask it to suspend at its next
                    // safepoint. Pending until it has parked.
                    // MVM_cas(&other->gc_status, MVMGCStatus_NONE,
                    //     MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST) (orchestrate.c:855), the result unused.
                    _ = atomic.casStatus(slot, none, interrupt_requested);
                    pending += 1;
                } else {
                    pending += 1;
                },
                .unable => if (current == unable) {
                    // Blocked in C: store the request so it parks when it
                    // unblocks. If the status changed under us, look again
                    // on the next pass.
                    // MVM_cas(&other->gc_status, MVMGCStatus_UNABLE,
                    //     MVMGCStatus_UNABLE | MVMSuspendState_SUSPEND_REQUEST) != MVMGCStatus_UNABLE (orchestrate.c:863).
                    if (atomic.casStatus(slot, unable, unable_requested) != unable)
                        pending += 1;
                } else if (current == unable_requested or current == unable_suspended) {
                    // Blocked with the request set, or parked.
                } else {
                    pending += 1;
                },
                // Asked but not yet at a safepoint
                // (INTERRUPT | SUSPEND_REQUEST), or in the middle of a
                // GC run (INTERRUPT, STOLEN, STOLEN | any suspend bit).
                .interrupt, .stolen => pending += 1,
            }
        }
        // uv_mutex_unlock(&vm->mutex_threads) (orchestrate.c:879).
        c.uv_mutex_unlock(&vm.mutex_threads);

        if (pending == 0 and in_gc == 0)
            break;
        MVM_platform_nanosleep(1000000);
    }
    markThreadUnblocked(tc);

    // Fake a nursery collection run by swapping the semi-
    // space nurseries.
    std.mem.swap(?*anyopaque, &tc.nursery_fromspace, &tc.nursery_tospace);

    // Run the objects' finalizers
    freeNurseryUncopied(tc, tc, tc.nursery_alloc);
    roots.gen2Cleanup(tc);
    collect.freeGen2Unmarked(tc, tc, true);
    collect.freeStables(tc);
}

// ---- the C ABI -------------------------------------------------------------

fn enterFromAllocatorExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    enterFromAllocator(tc);
}

fn enterFromInterruptExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    enterFromInterrupt(tc);
}

fn markThreadBlockedExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    markThreadBlocked(tc);
}

fn markThreadUnblockedExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    markThreadUnblocked(tc);
}

fn isThreadBlockedExport(tc: [*c]c.MVMThreadContext) callconv(.c) c.MVMint32 {
    return @intFromBool(isThreadBlocked(tc));
}

fn globalDestructionExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    globalDestruction(tc);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&enterFromAllocatorExport, .{ .name = "MVM_gc_enter_from_allocator", .visibility = visibility });
    @export(&enterFromInterruptExport, .{ .name = "MVM_gc_enter_from_interrupt", .visibility = visibility });
    @export(&markThreadBlockedExport, .{ .name = "MVM_gc_mark_thread_blocked", .visibility = visibility });
    @export(&markThreadUnblockedExport, .{ .name = "MVM_gc_mark_thread_unblocked", .visibility = visibility });
    @export(&isThreadBlockedExport, .{ .name = "MVM_gc_is_thread_blocked", .visibility = visibility });
    @export(&globalDestructionExport, .{ .name = "MVM_gc_global_destruction", .visibility = visibility });
}
