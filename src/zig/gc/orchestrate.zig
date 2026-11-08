//! Zig port of src/gc/orchestrate.c (lines 1-842): the stop-the-world
//! protocol. A thread whose nursery is full tries to start a run
//! (`enterFromAllocator`); the winner is the coordinator, which signals every
//! other thread to interrupt at its next safe point or steals the run of a
//! thread blocked in C code, counts the participants into `gc_start`,
//! collects its own work list, and then agrees termination with the
//! participants through `gc_finish`, `gc_intrays_clearing`, `gc_completed`
//! and `gc_ack` under `mutex_gc_orchestrate`. The other entry points are the
//! blocked/unblocked transitions of `gc_status`, the interrupt entry
//! (including the debugserver's suspend requests) and global destruction.
//! Faithful port; no behaviour change. Every atomic site uses
//! src/zig/gc/atomic.zig (or `moar.trycas` for `MVM_trycas`) and names the
//! C macro and line; the libuv mutex and condition calls go through `c.`.
//! `GCDEBUG_LOG` (src/gc/orchestrate.h:45-53) is kept as comptime-guarded
//! blocks: `MVM_GC_DEBUG_LOG_FLAGS` is 0, so, as in the C, they compile to
//! nothing. `#if MVM_GC_DEBUG` and `#if MVM_GC_DEBUG >= 3` are comptime
//! branches on the translated macro.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");

const Tc = [*c]c.MVMThreadContext;
const Thread = [*c]c.MVMThread;
const Object = [*c]c.MVMObject;

/// The `gc_status` word (src/core/threadcontext.h:1-41), AO_t-wide as the
/// slot it lives in: the status in the low two bits, the suspend state above.
const Status = c.AO_t;
const NONE: Status = c.MVMGCStatus_NONE;
const INTERRUPT: Status = c.MVMGCStatus_INTERRUPT;
const UNABLE: Status = c.MVMGCStatus_UNABLE;
const STOLEN: Status = c.MVMGCStatus_STOLEN;
const SUSPEND_NONE: Status = c.MVMSuspendState_NONE;
const SUSPEND_REQUEST: Status = c.MVMSuspendState_SUSPEND_REQUEST;
const SUSPENDED: Status = c.MVMSuspendState_SUSPENDED;
const STATUS_MASK: Status = c.MVMGCSTATUS_MASK;
const SUSPEND_MASK: Status = c.MVMSUSPENDSTATUS_MASK;

/// MVM_GC_DEBUG_ENABLED(flags) (orchestrate.h:47-48).
inline fn gcDebugEnabled(comptime flags: c_int) bool {
    return comptime (c.MVM_GC_DEBUG_LOG_FLAGS & flags) != 0;
}

/// The printf of GCDEBUG_LOG(tc, flags, msg, ...) (orchestrate.h:50-53);
/// callers guard it with `if (comptime gcDebugEnabled(flags))`, the
/// macro's `if`, so its arguments are evaluated only when it logs.
inline fn gcdebugLog(tc: Tc, msg: [*c]const u8, args: anytype) void {
    // (int)MVM_load(&(tc)->instance->gc_seq_number) (orchestrate.h:53).
    const seq: c_int = @bitCast(@as(c_uint, @truncate(atomic.load(&tc.*.instance.*.gc_seq_number))));
    _ = @call(.auto, c.printf, .{ msg, @as(c_uint, tc.*.thread_id), seq } ++ args);
}

/// `tc->thread_id` as a `%d` argument.
inline fn tid(tc: Tc) c_uint {
    return @as(c_uint, tc.*.thread_id);
}

/// `(void *)p` for a `%p` argument.
inline fn vp(p: anytype) ?*anyopaque {
    return @ptrCast(p);
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
    return @ptrCast(@alignCast(tc.*.instance.*.debugserver.?));
}

/// `tc->instance->debugserver && tc->instance->debugserver->debugspam_protocol`.
inline fn debugspam(tc: Tc) bool {
    return if (tc.*.instance.*.debugserver) |ds| @as(*DebugServerData, @ptrCast(@alignCast(ds))).debugspam_protocol != 0 else false;
}

/// src/platform/malloc_trim.h, which orchestrate.c includes directly and
/// moar.h does not, so the translation has no declaration of it.
extern fn MVM_malloc_trim() c_int;

/// src/platform/time.h, which orchestrate.c includes directly and moar.h
/// does not, so the translation has no declaration of it either.
extern fn MVM_platform_nanosleep(nanos: c.MVMuint64) void;

/// If we have the job of doing GC for a thread, we add it to our work
/// list. (orchestrate.c:5-21)
fn addWork(tc: Tc, stolen: Tc) void {
    var i: c.MVMuint32 = 0;
    while (i < tc.*.gc_work_count) : (i += 1)
        if (tc.*.gc_work[i].tc == stolen)
            return;
    if (tc.*.gc_work == null) {
        tc.*.gc_work_size = 16;
        tc.*.gc_work = @ptrCast(@alignCast(c.MVM_malloc(@as(usize, tc.*.gc_work_size) * @sizeOf(c.MVMWorkThread))));
    } else if (tc.*.gc_work_count == tc.*.gc_work_size) {
        tc.*.gc_work_size *%= 2;
        tc.*.gc_work = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.*.gc_work), @as(usize, tc.*.gc_work_size) * @sizeOf(c.MVMWorkThread))));
    }
    tc.*.gc_work[tc.*.gc_work_count].tc = stolen;
    tc.*.gc_work_count += 1;
}

/// Goes through all threads but the current one and notifies them that a
/// GC run is starting. Those that are blocked are considered excluded from
/// the run, and are not counted. Returns the count of threads that should be
/// added to the finished countdown. (orchestrate.c:23-71)
fn signalOneThread(tc: Tc, to_signal: Tc) c.MVMuint32 {
    // Loop here since we may not succeed first time (e.g. the status of the
    // thread may change between the two ways we try to twiddle it).
    var had_suspend_request: c_uint = 0;
    while (true) {
        // MVM_load(&to_signal->gc_status) (orchestrate.c:32).
        const current: Status = atomic.load(&to_signal.*.gc_status);
        switch (current) { // AO_READ(current)
            NONE => {
                // Try to set it from running to interrupted - the common case.
                // MVM_cas(&to_signal->gc_status, MVMGCStatus_NONE,
                //     MVMGCStatus_INTERRUPT) (orchestrate.c:36).
                if (atomic.cas(&to_signal.*.gc_status, NONE, INTERRUPT) == NONE) {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Signalled thread %d to interrupt\n", .{tid(to_signal)});
                    return 1;
                }
            },
            INTERRUPT | SUSPEND_REQUEST, INTERRUPT => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : thread %d already interrupted\n", .{tid(to_signal)});
                return 0;
            },
            UNABLE | SUSPEND_REQUEST, UNABLE | SUSPENDED, UNABLE => {
                // The two suspend cases (orchestrate.c:46-48) set
                // had_suspend_request and fall through to the UNABLE case
                // (:50), which keeps the value from the previous iteration.
                if (current != UNABLE)
                    had_suspend_request = @intCast(current & SUSPEND_MASK);
                // Otherwise, it's blocked; try to set it to work Stolen.
                // MVM_cas(&to_signal->gc_status, MVMGCStatus_UNABLE | had_suspend_request,
                //     MVMGCStatus_STOLEN | had_suspend_request) (orchestrate.c:52).
                if (atomic.cas(&to_signal.*.gc_status, UNABLE | had_suspend_request, STOLEN | had_suspend_request) == (UNABLE | had_suspend_request)) {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : A blocked thread %d spotted; work stolen\n", .{tid(to_signal)});
                    addWork(tc, to_signal);
                    return 0;
                }
            },
            // this case occurs if a child thread is Stolen by its parent
            // before we get to it in the chain.
            STOLEN | SUSPEND_REQUEST, STOLEN | SUSPENDED, STOLEN => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : thread %d already stolen (it was a spawning child)\n", .{tid(to_signal)});
                return 0;
            },
            else => {
                // MVM_load(&to_signal->gc_status) (orchestrate.c:67). MVM_panic
                // does not return, so the C's `return 0` after it (:68) is
                // unreachable and has no counterpart here.
                c.MVM_panic(c.MVM_exitcode_gcorch, "invalid status %" ++ c.MVM_PRSz ++ " in GC orchestrate\n", atomic.load(&to_signal.*.gc_status));
            },
        }
    }
}

/// (orchestrate.c:72-103)
fn signalAll(tc: Tc, threads: Thread) c.MVMuint32 {
    var t: Thread = threads;
    var count: c.MVMuint32 = 0;
    while (t != null) {
        // MVM_load(&t->body.stage) (orchestrate.c:76).
        switch (atomic.load(&t.*.body.stage)) {
            c.MVM_thread_stage_starting, c.MVM_thread_stage_waiting, c.MVM_thread_stage_started => {
                // Don't signal ourself.
                if (t.*.body.tc != tc)
                    count +%= signalOneThread(tc, t.*.body.tc);
            },
            c.MVM_thread_stage_exited => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : queueing to clear nursery of thread %d\n", .{tid(t.*.body.tc)});
                addWork(tc, t.*.body.tc);
            },
            c.MVM_thread_stage_clearing_nursery => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : queueing to destroy thread %d\n", .{tid(t.*.body.tc)});
                // last GC run for this thread
                addWork(tc, t.*.body.tc);
            },
            c.MVM_thread_stage_destroyed => {
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : found a destroyed thread\n", .{});
                // will be cleaned up (removed from the lists) shortly
            },
            else => {
                // MVM_load(&t->body.stage) (orchestrate.c:98).
                c.MVM_panic(c.MVM_exitcode_gcorch, "Corrupted MVMThread or running threads list: invalid thread stage %" ++ c.MVM_PRSz, atomic.load(&t.*.body.stage));
            },
        }
        t = t.*.body.next;
    }
    return count;
}

/// Does work in a thread's in-tray, if any. Returns a non-zero value if work
/// was found and done, and zero otherwise. (orchestrate.c:105-116)
fn processInTray(tc: Tc, gen: c.MVMuint8) c_int {
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Considering extra work\n", .{});
    // MVM_load(&tc->gc_in_tray) (orchestrate.c:109).
    if (atomic.load(&tc.*.gc_in_tray) != null) {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Was given extra work by another thread; doing it\n", .{});
        c.MVM_gc_collect(tc, c.MVMGCWhatToDo_InTray, gen);
        return 1;
    }
    return 0;
}

/// Called by a thread when it thinks it is done with GC. It may get some more
/// work yet, though. (orchestrate.c:118-132)
fn clearIntrays(tc: Tc, gen: c.MVMuint8) void {
    var did_work: c.MVMuint32 = 1;
    while (did_work != 0) {
        var cur_thread: Thread = undefined;
        did_work = 0;
        // (MVMThread *)MVM_load(&tc->instance->threads) (orchestrate.c:125).
        cur_thread = atomic.load(&tc.*.instance.*.threads);
        while (cur_thread != null) {
            if (cur_thread.*.body.tc != null)
                did_work +%= @intCast(processInTray(cur_thread.*.body.tc, gen));
            cur_thread = cur_thread.*.body.next;
        }
    }
}

/// (orchestrate.c:133-333)
fn finishGc(tc: Tc, gen: c.MVMuint8, is_coordinator: c.MVMuint8) void {
    var i: c.MVMuint32 = undefined;
    var did_work: c.MVMuint32 = undefined;

    // Do any extra work that we have been passed.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : doing any work in thread in-trays\n", .{});
    did_work = 1;
    while (did_work != 0) {
        did_work = 0;
        i = 0;
        while (i < tc.*.gc_work_count) : (i += 1)
            did_work +%= @intCast(processInTray(tc.*.gc_work[i].tc, gen));
    }

    // Decrement gc_finish to say we're done, and wait for termination.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Voting to finish\n", .{});
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:148).
    c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
    // MVM_decr(&tc->instance->gc_finish) (orchestrate.c:149).
    _ = atomic.decr(&tc.*.instance.*.gc_finish);
    // uv_cond_broadcast(&tc->instance->cond_gc_finish) (orchestrate.c:150).
    c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_finish);
    // MVM_load(&tc->instance->gc_finish) (orchestrate.c:151).
    while (atomic.load(&tc.*.instance.*.gc_finish) != 0)
        // uv_cond_wait(&tc->instance->cond_gc_finish, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:152).
        c.uv_cond_wait(&tc.*.instance.*.cond_gc_finish, &tc.*.instance.*.mutex_gc_orchestrate);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:153).
    c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Termination agreed\n", .{});

    // Co-ordinator should do final check over all the in-trays, and trigger
    // collection until all is settled. Rest should wait. Additionally, after
    // in-trays are settled, coordinator walks threads looking for anything
    // that needs adding to the finalize queue. It then will make another
    // iteration over in-trays to handle cross-thread references to objects
    // needing finalization. For full collections, collected objects are then
    // cleaned from all inter-generational sets, and finally any objects to
    // be freed at the fixed size allocator's next safepoint are freed.
    if (is_coordinator != 0) {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling in-tray clearing completion\n", .{});
        clearIntrays(tc, gen);

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling finalizers\n", .{});
        c.MVM_finalize_walk_queues(tc, gen);
        clearIntrays(tc, gen);

        if (gen == c.MVMGCGenerations_Both) {
            // (MVMThread *)MVM_load(&tc->instance->threads) (orchestrate.c:175).
            var cur_thread: Thread = atomic.load(&tc.*.instance.*.threads);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling inter-gen root cleanup\n", .{});
            while (cur_thread != null) {
                if (cur_thread.*.body.tc != null)
                    c.MVM_gc_root_gen2_cleanup(cur_thread.*.body.tc);
                cur_thread = cur_thread.*.body.next;
            }
        }

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator heapsnapshot or instrumented profiler data output\n", .{});
        c.MVM_profile_dump_instrumented_data(tc);
        c.MVM_profile_heap_take_snapshot(tc);

        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator handling allocator safepoint frees\n", .{});
        c.MVM_alloc_safepoint(tc);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Co-ordinator signalling in-trays clear\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:195).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_store(&tc->instance->gc_intrays_clearing, 0) (orchestrate.c:196).
        atomic.store(&tc.*.instance.*.gc_intrays_clearing, 0);
        // uv_cond_broadcast(&tc->instance->cond_gc_intrays_clearing) (orchestrate.c:197).
        c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_intrays_clearing);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:198).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
    } else {
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Waiting for in-tray clearing completion\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:203).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_load(&tc->instance->gc_intrays_clearing) (orchestrate.c:204).
        while (atomic.load(&tc.*.instance.*.gc_intrays_clearing) != 0)
            // uv_cond_wait(&tc->instance->cond_gc_intrays_clearing, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:205).
            c.uv_cond_wait(&tc.*.instance.*.cond_gc_intrays_clearing, &tc.*.instance.*.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:206).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Got in-tray clearing complete notice\n", .{});
    }

    // Reset GC status flags. This is also where thread destruction happens,
    // and it needs to happen before we acknowledge this GC run is finished.
    i = 0;
    while (i < tc.*.gc_work_count) : (i += 1) {
        const other: Tc = tc.*.gc_work[i].tc;
        const thread_obj: Thread = other.*.thread_obj;
        // MVM_load(&thread_obj->body.stage) (orchestrate.c:216).
        const destroying: c_int = @intFromBool(atomic.load(&thread_obj.*.body.stage) == c.MVM_thread_stage_clearing_nursery);

        // Free gen2 unmarked if full collection. A thread being destroyed is
        // swept too, before its gen2 is transferred
        if (gen == c.MVMGCGenerations_Both) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : freeing gen2 of thread %d%s\n", .{ tid(other), @as([*c]const u8, if (destroying != 0) " before transfer" else "") });
            c.MVM_gc_collect_free_gen2_unmarked(tc, other, 0);
            // Tell malloc implementation to free empty pages to kernel.
            // Currently only activated for Linux.
            _ = MVM_malloc_trim();
        }

        if (destroying != 0) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : transferring gen2 of thread %d\n", .{tid(other)});
            c.MVM_gc_gen2_transfer(other, tc);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : destroying thread %d\n", .{tid(other)});
            // #if MVM_GC_DEBUG (orchestrate.c:236-239)
            if (comptime c.MVM_GC_DEBUG != 0) {
                // Its log line now: it is gone by the end of finish_gc.
                c.MVM_gc_debug_log_collection(tc, other, @intFromBool(gen == c.MVMGCGenerations_Both));
            }
            // tc->gc_work[i].tc = thread_obj->body.tc = NULL; (orchestrate.c:240)
            thread_obj.*.body.tc = null;
            tc.*.gc_work[i].tc = null;
            c.MVM_tc_destroy(other);
            // MVM_store(&thread_obj->body.stage, MVM_thread_stage_destroyed) (orchestrate.c:242).
            atomic.store(&thread_obj.*.body.stage, c.MVM_thread_stage_destroyed);
        } else {
            // Contribute this thread's promoted bytes.
            // MVM_add(&tc->instance->gc_promoted_bytes_since_last_full, other->gc_promoted_bytes) (orchestrate.c:246).
            _ = atomic.add(&tc.*.instance.*.gc_promoted_bytes_since_last_full, other.*.gc_promoted_bytes);

            // Collect nursery.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : collecting nursery uncopied of thread %d\n", .{tid(other)});
            c.MVM_gc_collect_free_nursery_uncopied(tc, other, tc.*.gc_work[i].limit);

            // Handle exited threads.
            // MVM_load(&thread_obj->body.stage) (orchestrate.c:255).
            if (atomic.load(&thread_obj.*.body.stage) == c.MVM_thread_stage_exited) {
                // Don't bother freeing gen2; we'll do it next time
                // MVM_store(&thread_obj->body.stage, MVM_thread_stage_clearing_nursery) (orchestrate.c:257).
                atomic.store(&thread_obj.*.body.stage, c.MVM_thread_stage_clearing_nursery);
                // (int)MVM_load(&thread_obj->body.stage) (orchestrate.c:260).
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : set thread %d clearing nursery stage to %d\n", .{ tid(other), @as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&thread_obj.*.body.stage))))) });
            }

            // #if MVM_GC_DEBUG >= 3 (orchestrate.c:263-265)
            if (comptime c.MVM_GC_DEBUG >= 3) {
                @memset(@as([*]u8, @ptrCast(other.*.nursery_fromspace))[0..other.*.nursery_fromspace_size], 0xef);
            }

            // Mark thread free to continue.
            var suspend_bits: c_uint = 0;
            var status_bits: c_uint = 0;
            while (true) {
                // MVM_load(&other->gc_status) (orchestrate.c:271).
                const current: Status = atomic.load(&other.*.gc_status);
                status_bits = @intCast(current & STATUS_MASK); // AO_READ(current) & MVMGCSTATUS_MASK
                suspend_bits = @intCast(current & SUSPEND_MASK); // AO_READ(current) & MVMSUSPENDSTATUS_MASK
                if (status_bits == STOLEN) {
                    // MVM_cas(&other->gc_status, MVMGCStatus_STOLEN | suspend_bits, MVMGCStatus_UNABLE | suspend_bits) (orchestrate.c:275).
                    if (atomic.cas(&other.*.gc_status, STOLEN | suspend_bits, UNABLE | suspend_bits) == (STOLEN | suspend_bits)) {
                        break;
                    }
                } else if (status_bits == INTERRUPT) {
                    // MVM_cas(&other->gc_status, MVMGCStatus_INTERRUPT | suspend_bits, MVMGCStatus_NONE | suspend_bits) (orchestrate.c:281).
                    if (atomic.cas(&other.*.gc_status, INTERRUPT | suspend_bits, NONE | suspend_bits) == (INTERRUPT | suspend_bits)) {
                        break;
                    }
                } else if (status_bits == NONE or status_bits == UNABLE) {
                    break;
                } else {
                    c.MVM_panic(c.MVM_exitcode_gcorch, "Invalid GC status observed \"%lu\" while unblocking thread; aborting", @as(c_ulong, current));
                }
            }
        }
    }

    // #if MVM_GC_DEBUG (orchestrate.c:296-304)
    if (comptime c.MVM_GC_DEBUG != 0) {
        // One per-collection log line per thread this one collected (the
        // coordinator's work list, or a non-coordinator's own entry), before
        // gc_completed lets the next run start; threads destroyed above have
        // already written theirs.
        i = 0;
        while (i < tc.*.gc_work_count) : (i += 1)
            if (tc.*.gc_work[i].tc != null)
                c.MVM_gc_debug_log_collection(tc, tc.*.gc_work[i].tc, @intFromBool(gen == c.MVMGCGenerations_Both));
    }

    if (is_coordinator != 0) {
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:307).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_store(&tc->instance->gc_completed, 1) (orchestrate.c:308).
        atomic.store(&tc.*.instance.*.gc_completed, 1);
        // uv_cond_broadcast(&tc->instance->cond_gc_completed) (orchestrate.c:309).
        c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_completed);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:310).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
    } else {
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:313).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // !MVM_load(&tc->instance->gc_completed) (orchestrate.c:314).
        while (atomic.load(&tc.*.instance.*.gc_completed) == 0)
            // uv_cond_wait(&tc->instance->cond_gc_completed, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:315).
            c.uv_cond_wait(&tc.*.instance.*.cond_gc_completed, &tc.*.instance.*.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:316).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
    }

    // Signal acknowledgement of completing the cleanup,
    // except for STables, and if we're the final to do
    // so, free the STables, which have been linked.
    // MVM_decr(&tc->instance->gc_ack) == 2 (orchestrate.c:322): the value before the decrement.
    if (atomic.decr(&tc.*.instance.*.gc_ack) == 2) {
        // Set it to zero (we're guaranteed the only ones trying to write to
        // it here). Actual STable free in MVM_gc_enter_from_allocator.
        // MVM_store(&tc->instance->gc_ack, 0) (orchestrate.c:325).
        atomic.store(&tc.*.instance.*.gc_ack, 0);

        // Also clear in GC flag.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:328).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        tc.*.instance.*.in_gc = 0;
        // uv_cond_broadcast(&tc->instance->cond_blocked_can_continue) (orchestrate.c:330).
        c.uv_cond_broadcast(&tc.*.instance.*.cond_blocked_can_continue);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:331).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
    }
}

/// Called by a thread to indicate it is about to enter a blocking operation.
/// This tells any thread that is coordinating a GC run that this thread will
/// be unable to participate. (orchestrate.c:335-358)
pub fn markThreadBlocked(tc: Tc) callconv(.c) void {
    // This may need more than one attempt.
    while (true) {
        // Try to set it from running to unable - the common case.
        // MVM_cas(&tc->gc_status, MVMGCStatus_NONE, MVMGCStatus_UNABLE) (orchestrate.c:342).
        if (atomic.cas(&tc.*.gc_status, NONE, UNABLE) == NONE)
            return;

        // MVM_cas(&tc->gc_status, MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST,
        //     MVMGCStatus_UNABLE | MVMSuspendState_SUSPENDED) (orchestrate.c:346).
        if (atomic.cas(&tc.*.gc_status, INTERRUPT | SUSPEND_REQUEST, UNABLE | SUSPENDED) == (INTERRUPT | SUSPEND_REQUEST))
            return;

        // The only way this can fail is if another thread just decided we're to
        // participate in a GC run.
        // MVM_load(&tc->gc_status) (orchestrate.c:352).
        if (atomic.load(&tc.*.gc_status) == INTERRUPT)
            enterFromInterrupt(tc)
        else
            // MVM_load(&tc->gc_status) (orchestrate.c:356).
            c.MVM_panic(c.MVM_exitcode_gcorch, "Invalid GC status observed \"%lu\" while blocking thread; aborting", @as(c_ulong, atomic.load(&tc.*.gc_status)));
    }
}

/// Called by a thread to indicate it has completed a block operation and is
/// thus able to particpate in a GC run again. Note that this case needs some
/// special handling if it comes out of this mode when a GC run is taking place.
/// (orchestrate.c:360-406)
pub fn markThreadUnblocked(tc: Tc) callconv(.c) void {
    // Try to set it from unable to running.
    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE, MVMGCStatus_NONE) != MVMGCStatus_UNABLE (orchestrate.c:365).
    while (atomic.cas(&tc.*.gc_status, UNABLE, NONE) != UNABLE) {
        // We can't, presumably because a GC run is going on. We should wait
        // for that to finish before we go on; try using a condvar for it.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:369).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        if (tc.*.instance.*.in_gc != 0) {
            // uv_cond_wait(&tc->instance->cond_blocked_can_continue, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:371).
            c.uv_cond_wait(&tc.*.instance.*.cond_blocked_can_continue, &tc.*.instance.*.mutex_gc_orchestrate);
            // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:373).
            c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
        } else {
            // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:376).
            c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);
            // MVM_load(&tc->gc_status) (orchestrate.c:377).
            if ((atomic.load(&tc.*.gc_status) & SUSPEND_MASK) == SUSPEND_REQUEST) {
                while (true) {
                    // Let's try to unblock into INTERRUPT mode and keep the
                    // suspend request, then immediately enter_from_interrupt,
                    // so we actually wait to be woken up.
                    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE | MVMSuspendState_SUSPEND_REQUEST,
                    //     MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST) (orchestrate.c:382).
                    if (atomic.cas(&tc.*.gc_status, UNABLE | SUSPEND_REQUEST, INTERRUPT | SUSPEND_REQUEST) == (UNABLE | SUSPEND_REQUEST)) {
                        enterFromInterrupt(tc);
                        break;
                    }
                    // If we're being resumed while trying to unblock into
                    // suspend request, we'd block forever. Therefor we have
                    // to check if we've been un-requested.
                    // MVM_cas(&tc->gc_status, MVMGCStatus_UNABLE, MVMGCStatus_NONE) (orchestrate.c:391).
                    if (atomic.cas(&tc.*.gc_status, UNABLE, NONE) == UNABLE) {
                        return;
                    }
                }
                // MVM_load(&tc->gc_status) (orchestrate.c:397).
            } else if (atomic.load(&tc.*.gc_status) == NONE) {
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
/// (orchestrate.c:408-420)
pub fn isThreadBlocked(tc: Tc) callconv(.c) c.MVMint32 {
    // MVM_load(&(tc->gc_status)) (orchestrate.c:417).
    const gc_status: Status = atomic.load(&tc.*.gc_status) & STATUS_MASK;
    return @intFromBool(gc_status == UNABLE or
        gc_status == STOLEN);
}

/// (orchestrate.c:422-447) `pub` only for the tests; not exported.
pub fn isFullCollection(tc: Tc) c.MVMint32 {
    var percent_growth: c.MVMuint64 = undefined;
    var promoted: c.MVMuint64 = undefined;
    var rss: usize = undefined;

    // If it's below the absolute minimum, quickly return.
    // (MVMuint64)MVM_load(&tc->instance->gc_promoted_bytes_since_last_full) (orchestrate.c:427).
    promoted = @as(c.MVMuint64, atomic.load(&tc.*.instance.*.gc_promoted_bytes_since_last_full));
    if (promoted < c.MVM_GC_GEN2_THRESHOLD_MINIMUM)
        return 0;

    // If we're heap profiling then don't consider the resident set size, as
    // it will be hugely distorted by the profile data we record.
    if (c.MVM_profile_heap_profiling(tc) != 0)
        return 1;

    // Otherwise, consider percentage of resident set size.
    // #if MVM_GC_DEBUG (orchestrate.c:437-441): the override, when set, is the
    // resident set; otherwise (and always at 0) it is read from libuv (:442-443).
    if (comptime c.MVM_GC_DEBUG != 0) {
        if (tc.*.instance.*.gc_debug_rss_override != 0)
            rss = tc.*.instance.*.gc_debug_rss_override
        else if (c.uv_resident_set_memory(&rss) < 0 or rss == 0)
            rss = 50 * 1024 * 1024;
    } else {
        if (c.uv_resident_set_memory(&rss) < 0 or rss == 0)
            rss = 50 * 1024 * 1024;
    }
    percent_growth = (100 *% promoted) / @as(c.MVMuint64, rss);

    return @intFromBool(percent_growth >= c.MVM_GC_GEN2_THRESHOLD_PERCENT);
}

/// (orchestrate.c:449-535)
fn runGc(tc: Tc, what_to_do: c.MVMuint8) void {
    var gen: c.MVMuint8 = undefined;
    var i: c.MVMuint32 = undefined;
    var n: c.MVMuint32 = undefined;

    var is_coordinator: c.MVMuint8 = undefined;

    var start_time: c.MVMuint64 = 0;

    var interval_id: c_uint = undefined;

    var subscription_queue: Object = null;

    is_coordinator = @intFromBool(what_to_do == c.MVMGCWhatToDo_All);

    // #if MVM_GC_DEBUG (orchestrate.c:463-466)
    if (comptime c.MVM_GC_DEBUG != 0) {
        if (tc.*.in_spesh != 0)
            c.MVM_panic(1, "Must not GC when in the specializer/JIT\n");
    }

    // Decide nursery or full collection.
    gen = if (tc.*.instance.*.gc_full_collect != 0) c.MVMGCGenerations_Both else c.MVMGCGenerations_Nursery;

    if (tc.*.instance.*.gc_full_collect != 0) {
        interval_id = c.MVM_telemetry_interval_start(tc, "start full collection");
    } else {
        interval_id = c.MVM_telemetry_interval_start(tc, "start minor collection");
    }

    if (is_coordinator != 0)
        start_time = c.uv_hrtime();

    // Do GC work for ourselves and any work threads.
    i = 0;
    n = tc.*.gc_work_count;
    while (i < n) : (i += 1) {
        const other: Tc = tc.*.gc_work[i].tc;
        tc.*.gc_work[i].limit = other.*.nursery_alloc;
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : starting collection for thread %d\n", .{tid(other)});
        other.*.gc_promoted_bytes = 0;
        if (tc.*.instance.*.profiling != 0)
            c.MVM_profiler_log_gen2_roots(tc, other.*.num_gen2roots, other);
        c.MVM_gc_collect(other, if (other == tc) what_to_do else c.MVMGCWhatToDo_NoInstance, gen);
    }

    // Wait for everybody to agree we're done.
    finishGc(tc, gen, is_coordinator);

    // Finally, as the very last thing ever, the coordinator pushes a bit of
    // info into the subscription queue (if it is set)

    subscription_queue = tc.*.instance.*.subscriptions.subscription_queue;

    if (is_coordinator != 0 and subscription_queue != null and tc.*.instance.*.subscriptions.GCEvent != null) {
        const end_time: c.MVMuint64 = c.uv_hrtime();
        const instance: Object = c.MVM_repr_alloc(tc, tc.*.instance.*.subscriptions.GCEvent);
        var cur_thread: Thread = undefined;

        const arrobj: [*c]c.MVMArray = @ptrCast(@alignCast(instance));
        var data: [*c]c.MVMuint64 = undefined;

        c.MVM_repr_pos_set_elems(tc, instance, 9);

        data = arrobj.*.body.slots.u64;

        // MVM_load(&tc->instance->gc_seq_number) (orchestrate.c:512).
        data[0] = atomic.load(&tc.*.instance.*.gc_seq_number);
        data[1] = start_time / 1000;
        data[2] = (start_time -% tc.*.instance.*.subscriptions.vm_startup_hrtime) / 1000;
        data[3] = (end_time -% start_time) / 1000;
        data[4] = @intFromBool(gen == c.MVMGCGenerations_Both);
        data[5] = tc.*.gc_promoted_bytes;
        // MVM_load(&tc->instance->gc_promoted_bytes_since_last_full) (orchestrate.c:518).
        data[6] = atomic.load(&tc.*.instance.*.gc_promoted_bytes_since_last_full);
        data[7] = tc.*.thread_id;
        data[8] = 0;

        // uv_mutex_lock(&tc->instance->mutex_threads) (orchestrate.c:522).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_threads);
        cur_thread = tc.*.instance.*.threads;
        while (cur_thread != null) {
            if (cur_thread.*.body.tc != null)
                data[8] +%= cur_thread.*.body.tc.*.num_gen2roots;
            cur_thread = cur_thread.*.body.next;
        }
        // uv_mutex_unlock(&tc->instance->mutex_threads) (orchestrate.c:529).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_threads);

        c.MVM_repr_push_o(tc, tc.*.instance.*.subscriptions.subscription_queue, instance);
    }

    c.MVM_telemetry_interval_stop(tc, @bitCast(interval_id), "finished run_gc");
}

/// This is called when the allocator finds it has run out of memory and wants
/// to trigger a GC run. In this case, it's possible (probable, really) that it
/// will need to do that triggering, notifying other running threads that the
/// time has come to GC. (orchestrate.c:537-661)
pub fn enterFromAllocator(tc: Tc) callconv(.c) void {
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entered from allocate\n", .{});

    c.MVM_telemetry_timestamp(tc, "gc_enter_from_allocator");

    // Try to start the GC run.
    // MVM_trycas(&tc->instance->gc_start, 0, 1) (orchestrate.c:547).
    const gc_start: *c.AO_t = &tc.*.instance.*.gc_start;
    if (moar.trycas(gc_start, @as(c.AO_t, 0), @as(c.AO_t, 1))) {
        var num_threads: c.MVMuint32 = 0;

        // Stash us as the thread to blame for this GC run (used to give it a
        // potential nursery size boost).
        tc.*.instance.*.thread_to_blame_for_gc = tc;

        // Need to wait for other threads to reset their gc_status.
        // MVM_load(&tc->instance->gc_ack) (orchestrate.c:555).
        while (atomic.load(&tc.*.instance.*.gc_ack) != 0) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : waiting for other thread's gc_ack\n", .{});
            _ = c.MVM_platform_thread_yield();
        }

        // We are the winner of the GC starting race. This gives us some
        // extra responsibilities as well as doing the usual things.
        // First, increment GC sequence number.
        // MVM_incr(&tc->instance->gc_seq_number) (orchestrate.c:564).
        _ = atomic.incr(&tc.*.instance.*.gc_seq_number);
        // (int)MVM_load(&tc->instance->gc_seq_number) (orchestrate.c:567).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : GC thread elected coordinator: starting gc seq %d\n", .{@as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&tc.*.instance.*.gc_seq_number)))))});

        // Decide if it will be a full collection.
        tc.*.instance.*.gc_full_collect = @bitCast(isFullCollection(tc));

        c.MVM_telemetry_timestamp(tc, "won the gc starting race");

        // If profiling, record that GC is starting.
        if (tc.*.instance.*.profiling != 0)
            c.MVM_profiler_log_gc_start(tc, tc.*.instance.*.gc_full_collect, 1);

        // Ensure our stolen list is empty.
        tc.*.gc_work_count = 0;

        // Flag that we didn't agree on this run that all the in-trays are
        // cleared (a responsibility of the co-ordinator.
        // MVM_store(&tc->instance->gc_intrays_clearing, 1) (orchestrate.c:583).
        atomic.store(&tc.*.instance.*.gc_intrays_clearing, 1);
        // MVM_store(&tc->instance->gc_completed, 0) (orchestrate.c:584).
        atomic.store(&tc.*.instance.*.gc_completed, 0);

        // We'll take care of our own work.
        addWork(tc, tc);

        // Find other threads, and signal or steal. Also set in GC flag.
        // uv_mutex_lock(&tc->instance->mutex_threads) (orchestrate.c:590).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_threads);
        tc.*.instance.*.in_gc = 1;
        num_threads = signalAll(tc, tc.*.instance.*.threads);
        // uv_mutex_unlock(&tc->instance->mutex_threads) (orchestrate.c:593).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_threads);

        // Bump the thread count and signal any threads waiting for that.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:596).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_add(&tc->instance->gc_start, num_threads) (orchestrate.c:597).
        _ = atomic.add(&tc.*.instance.*.gc_start, num_threads);
        // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:598).
        c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_start);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:599).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);

        // If there's an event loop thread, wake it up to participate.
        if (tc.*.instance.*.event_loop_wakeup != null)
            _ = c.uv_async_send(tc.*.instance.*.event_loop_wakeup);

        // Wait for other threads to be ready.
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:606).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_load(&tc->instance->gc_start) > 1 (orchestrate.c:607).
        while (atomic.load(&tc.*.instance.*.gc_start) > 1)
            // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:608).
            c.uv_cond_wait(&tc.*.instance.*.cond_gc_start, &tc.*.instance.*.mutex_gc_orchestrate);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:609).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);

        // Sanity check finish votes.
        // MVM_load(&tc->instance->gc_finish) (orchestrate.c:612, and :614 in the message).
        if (atomic.load(&tc.*.instance.*.gc_finish) != 0)
            c.MVM_panic(c.MVM_exitcode_gcorch, "Finish votes was %" ++ c.MVM_PRSz ++ "\n", atomic.load(&tc.*.instance.*.gc_finish));

        // gc_ack gets an extra so the final acknowledger
        // can also free the STables.
        // MVM_store(&tc->instance->gc_finish, num_threads + 1) (orchestrate.c:618).
        atomic.store(&tc.*.instance.*.gc_finish, num_threads + 1);
        // MVM_store(&tc->instance->gc_ack, num_threads + 2) (orchestrate.c:619).
        atomic.store(&tc.*.instance.*.gc_ack, num_threads + 2);
        // (int)MVM_load(&tc->instance->gc_finish) (orchestrate.c:621).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : finish votes is %d\n", .{@as(c_int, @bitCast(@as(c_uint, @truncate(atomic.load(&tc.*.instance.*.gc_finish)))))});

        // Now we're ready to start, zero promoted since last full collection
        // counter if this is a full collect.
        if (tc.*.instance.*.gc_full_collect != 0)
            // MVM_store(&tc->instance->gc_promoted_bytes_since_last_full, 0) (orchestrate.c:626).
            atomic.store(&tc.*.instance.*.gc_promoted_bytes_since_last_full, 0);

        // This is a safe point for us to free any STables that have been marked
        // for deletion in the previous collection (since we let finalization -
        // which appends to this list - happen after we set threads on their
        // way again, it's not safe to do it in the previous collection).
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Freeing STables if needed\n", .{});
        c.MVM_gc_collect_free_stables(tc);

        // Signal to the rest to start
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : coordinator signalling start\n", .{});
        // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:637).
        c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
        // MVM_decr(&tc->instance->gc_start) != 1 (orchestrate.c:638): the value before the
        // decrement; MVM_load(&tc->instance->gc_start) (:639) in the message.
        if (atomic.decr(&tc.*.instance.*.gc_start) != 1)
            c.MVM_panic(c.MVM_exitcode_gcorch, "Start votes was %" ++ c.MVM_PRSz ++ "\n", atomic.load(&tc.*.instance.*.gc_start));
        // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:640).
        c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_start);
        // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:641).
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);

        // Start collecting.
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : coordinator entering run_gc\n", .{});
        runGc(tc, c.MVMGCWhatToDo_All);

        // If profiling, record that GC is over.
        if (tc.*.instance.*.profiling != 0)
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
/// MVMSUSPENDSTATUS_MASK. (orchestrate.c:663-712)
fn reactToDebugserverRequest(tc: Tc) c_int {
    if (debugspam(tc))
        _ = c.fprintf(c.stderr, "thread %p has received a request.\n", vp(tc));

    const kind: c.MVMDebugServerRequestKind = debugserver(tc).request_data.kind;

    if (kind == c.MVM_DebugRequest_invoke) {
        const invoke_target: [*c]c.MVMCode = debugserver(tc).request_data.data.invoke.target;
        const args: [*c]c.MVMArgs = debugserver(tc).request_data.data.invoke.args;
        debugserver(tc).request_data.data.invoke.target = null;

        // Have to clear the threadcontext's "blocked" status so that invoke
        // can work, for example to run the instruction level barrier.

        // MVM_trycas(&tc->gc_status, MVMGCStatus_UNABLE | MVMSuspendState_SUSPENDED, MVMGCStatus_NONE)
        // (orchestrate.c:688): only its success is used, so `moar.trycas`.
        const gc_status: *c.AO_t = &tc.*.gc_status;
        if (!moar.trycas(gc_status, UNABLE | SUSPENDED, NONE)) {
            c.MVM_panic(c.MVM_exitcode_gcorch, "could not unblock/unsuspend thread");
        }

        c.MVM_frame_dispatch(tc, invoke_target, args.*, -1);

        markThreadBlocked(tc);
    } else {
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "this debug request kind not implemented: %d\n", @as(c_int, @bitCast(kind)));
        return 0;
    }

    // MVM_cas(&tc->instance->debugserver->request_data.status,
    //     MVM_DebugRequestStatus_sender_is_waiting,
    //     MVM_DebugRequestStatus_receiver_acknowledged) (orchestrate.c:702).
    if (atomic.cas(&debugserver(tc).request_data.status, c.MVM_DebugRequestStatus_sender_is_waiting, c.MVM_DebugRequestStatus_receiver_acknowledged) != c.MVM_DebugRequestStatus_sender_is_waiting) {
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "could not acknowledge request?!?\n");
    }
    debugserver(tc).request_data.kind = c.MVM_DebugRequest_empty;

    return 1;
}

/// (orchestrate.c:713-798)
pub fn enterFromInterrupt(tc: Tc) callconv(.c) void {
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entered from interrupt\n", .{});

    // MVM_load(&tc->gc_status) (orchestrate.c:717).
    if ((atomic.load(&tc.*.gc_status) & SUSPEND_MASK) == SUSPEND_REQUEST) {
        if (tc.*.instance.*.debugserver == null) {
            // Without a debugserver there is no condvar to wait on and
            // nobody to send a resume: the only issuer of a suspend request
            // then is MVM_gc_global_destruction, which is tearing the
            // process down. Park the thread, blocked, until the suspend
            // bits clear (in practice, until the process exits).
            markThreadBlocked(tc);
            // MVM_load(&tc->gc_status) (orchestrate.c:725).
            while ((atomic.load(&tc.*.gc_status) & SUSPEND_MASK) != SUSPEND_NONE)
                MVM_platform_nanosleep(1000000);
            markThreadUnblocked(tc);
            return;
        }
        if (debugspam(tc))
            _ = c.fprintf(c.stderr, "thread %d reacting to suspend request\n", tid(tc));
        markThreadBlocked(tc);
        while (true) {
            // uv_mutex_lock(&tc->instance->debugserver->mutex_cond) (orchestrate.c:734).
            c.uv_mutex_lock(&debugserver(tc).mutex_cond);
            // uv_cond_wait(&tc->instance->debugserver->tell_threads, &tc->instance->debugserver->mutex_cond) (orchestrate.c:735).
            c.uv_cond_wait(&debugserver(tc).tell_threads, &debugserver(tc).mutex_cond);
            // uv_mutex_unlock(&tc->instance->debugserver->mutex_cond) (orchestrate.c:736).
            c.uv_mutex_unlock(&debugserver(tc).mutex_cond);
            // MVM_load(&tc->gc_status) (orchestrate.c:737).
            if ((atomic.load(&tc.*.gc_status) & SUSPEND_MASK) == SUSPEND_NONE) {
                if (debugspam(tc))
                    _ = c.fprintf(c.stderr, "thread %d got un-suspended\n", tid(tc));
                break;
            } else {
                if (tc.*.instance.*.debugserver != null and debugserver(tc).request_data.target_tc == tc) {
                    if (reactToDebugserverRequest(tc) != 0) {
                        break;
                    }
                }
                if (debugspam(tc))
                    _ = c.fprintf(c.stderr, "thread %p: something happened, but we're still suspended.\n", vp(tc));
            }
        }
        markThreadUnblocked(tc);
        return;
        // MVM_load(&tc->gc_status) (orchestrate.c:753).
    } else if (atomic.load(&tc.*.gc_status) == (UNABLE | SUSPENDED)) {
        // The thread that the tc belongs to is already waiting in that loop
        // up there. If we reach this piece of code the active thread must be
        // the debug remote using a suspended thread's ThreadContext.
        return;
    }

    c.MVM_telemetry_timestamp(tc, "gc_enter_from_interrupt");

    // We'll certainly take care of our own work.
    tc.*.gc_work_count = 0;
    addWork(tc, tc);

    // Indicate that we're ready to GC. Only want to decrement it if it's 2 or
    // greater (0 should never happen; 1 means the coordinator is still counting
    // up how many threads will join in, so we should wait until it decides to
    // decrement.)
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:770).
    c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
    // MVM_load(&tc->instance->gc_start) < 2 (orchestrate.c:771).
    while (atomic.load(&tc.*.instance.*.gc_start) < 2)
        // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:772).
        c.uv_cond_wait(&tc.*.instance.*.cond_gc_start, &tc.*.instance.*.mutex_gc_orchestrate);
    // MVM_decr(&tc->instance->gc_start) (orchestrate.c:773).
    _ = atomic.decr(&tc.*.instance.*.gc_start);
    // uv_cond_broadcast(&tc->instance->cond_gc_start) (orchestrate.c:774).
    c.uv_cond_broadcast(&tc.*.instance.*.cond_gc_start);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:775).
    c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);

    // If profiling, record that GC is starting.
    // We don't do this before add_work, because the gc_sequence_number
    // may not yet have been increased, leading to duplicate entries
    // in the gc parts of the profiler
    if (tc.*.instance.*.profiling != 0)
        c.MVM_profiler_log_gc_start(tc, @bitCast(isFullCollection(tc)), 0);

    // Wait for all threads to indicate readiness to collect.
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Waiting for other threads\n", .{});
    // uv_mutex_lock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:786).
    c.uv_mutex_lock(&tc.*.instance.*.mutex_gc_orchestrate);
    // MVM_load(&tc->instance->gc_start) (orchestrate.c:787).
    while (atomic.load(&tc.*.instance.*.gc_start) != 0)
        // uv_cond_wait(&tc->instance->cond_gc_start, &tc->instance->mutex_gc_orchestrate) (orchestrate.c:788).
        c.uv_cond_wait(&tc.*.instance.*.cond_gc_start, &tc.*.instance.*.mutex_gc_orchestrate);
    // uv_mutex_unlock(&tc->instance->mutex_gc_orchestrate) (orchestrate.c:789).
    c.uv_mutex_unlock(&tc.*.instance.*.mutex_gc_orchestrate);

    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : Entering run_gc\n", .{});
    runGc(tc, c.MVMGCWhatToDo_NoInstance);
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_ORCHESTRATE)) gcdebugLog(tc, "Thread %d run %d : GC complete\n", .{});

    // If profiling, record that GC is over.
    if (tc.*.instance.*.profiling != 0)
        c.MVM_profiler_log_gc_end(tc);
}

/// Run the global destruction phase. (orchestrate.c:800-868)
pub fn globalDestruction(tc: Tc) callconv(.c) void {
    var nursery_tmp: [*c]u8 = undefined;

    const vm: [*c]c.MVMInstance = tc.*.instance;
    var cur_thread: Thread = null;

    // Ask all threads to suspend on the next chance they get. Like the
    // debugserver, mark ourselves blocked while holding mutex_threads, so a
    // GC run started by another thread meanwhile does not wait for us.
    markThreadBlocked(tc);
    // uv_mutex_lock(&vm->mutex_threads) (orchestrate.c:811).
    c.uv_mutex_lock(&vm.*.mutex_threads);

    cur_thread = vm.*.threads;
    while (cur_thread != null) {
        const other: Tc = cur_thread.*.body.tc;
        // A thread that has been cleaned up already has no tc left. Only ask
        // threads that are running or blocked; one that is in the middle of a
        // GC run (or already has a suspend bit) is left alone.
        var ask = false;
        if (other != null and other != tc) {
            // MVM_load(&other->gc_status) (orchestrate.c:821).
            const current: Status = atomic.load(&other.*.gc_status);
            ask = current == NONE or current == UNABLE;
        }
        if (ask) {
            while (true) {
                // Is the thread currently doing completely ordinary code execution?
                // MVM_cas(&other->gc_status, MVMGCStatus_NONE, MVMGCStatus_INTERRUPT | MVMSuspendState_SUSPEND_REQUEST) (orchestrate.c:827).
                if (atomic.cas(&other.*.gc_status, NONE, INTERRUPT | SUSPEND_REQUEST) == NONE) {
                    break;
                }
                // Is the thread in question currently blocked, i.e. spending time in
                // some long-running piece of C code, waiting for I/O, etc.?
                // If so, just store the suspend request bit so when it unblocks itself
                // it'll suspend execution.
                // MVM_cas(&other->gc_status, MVMGCStatus_UNABLE, MVMGCStatus_UNABLE | MVMSuspendState_SUSPEND_REQUEST) (orchestrate.c:835).
                if (atomic.cas(&other.*.gc_status, UNABLE, UNABLE | SUSPEND_REQUEST) == UNABLE) {
                    break;
                }
                // Was the thread faster than us? For example by running into
                // a breakpoint, completing a step, or encountering an
                // unhandled exception? If so, we're done here.
                // MVM_load(&other->gc_status) (orchestrate.c:842).
                if ((atomic.load(&other.*.gc_status) & SUSPEND_MASK) == SUSPEND_REQUEST) {
                    break;
                }
                _ = c.MVM_platform_thread_yield();
            }
        }
        cur_thread = cur_thread.*.body.next;
    }

    // uv_mutex_unlock(&vm->mutex_threads) (orchestrate.c:851).
    c.uv_mutex_unlock(&vm.*.mutex_threads);
    markThreadUnblocked(tc);

    // Allow other threads to do a little more work before we continue here
    _ = c.MVM_platform_thread_yield();

    // Fake a nursery collection run by swapping the semi-
    // space nurseries.
    nursery_tmp = @ptrCast(tc.*.nursery_fromspace);
    tc.*.nursery_fromspace = tc.*.nursery_tospace;
    tc.*.nursery_tospace = @ptrCast(nursery_tmp);

    // Run the objects' finalizers
    c.MVM_gc_collect_free_nursery_uncopied(tc, tc, tc.*.nursery_alloc);
    c.MVM_gc_root_gen2_cleanup(tc);
    c.MVM_gc_collect_free_gen2_unmarked(tc, tc, 1);
    c.MVM_gc_collect_free_stables(tc);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&enterFromAllocator, .{ .name = "MVM_gc_enter_from_allocator", .visibility = visibility });
    @export(&enterFromInterrupt, .{ .name = "MVM_gc_enter_from_interrupt", .visibility = visibility });
    @export(&markThreadBlocked, .{ .name = "MVM_gc_mark_thread_blocked", .visibility = visibility });
    @export(&markThreadUnblocked, .{ .name = "MVM_gc_mark_thread_unblocked", .visibility = visibility });
    @export(&isThreadBlocked, .{ .name = "MVM_gc_is_thread_blocked", .visibility = visibility });
    @export(&globalDestruction, .{ .name = "MVM_gc_global_destruction", .visibility = visibility });
}
