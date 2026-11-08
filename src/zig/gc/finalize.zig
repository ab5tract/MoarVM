//! Zig port of src/gc/finalize.c (lines 1-123): the per-thread finalize
//! queues, the walk that moves dead finalizable objects to the finalizing
//! list, and the run of the HLL finalize handler. Faithful port; no
//! behaviour change. The queues grow through `c.MVM_realloc` as in the C.
//! `reinstate_last_handler_result` and `mark_last_handler_result` are
//! non-static in the C and keep their C names as exports (they are passed
//! by address to `MVM_callstack_allocate_special_return`, whose callback
//! types translate to plain `?*const fn` pointers). The `MVM_load` of the
//! thread list uses src/zig/gc/atomic.zig; `MVM_gc_worklist_add` is
//! `moar.worklistAdd`; `MVMROOT` is `moar.root`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");

const Tc = [*c]c.MVMThreadContext;
const Object = [*c]c.MVMObject;
const Worklist = [*c]c.MVMGCWorklist;

/// Turns finalization on or off for a type. (finalize.c:4-11)
pub fn set(tc: Tc, @"type": Object, finalize: c.MVMint64) callconv(.c) void {
    const st: [*c]c.MVMSTable = @"type".*.st;
    var new_flags: c.MVMint64 = st.*.mode_flags & ~@as(c.MVMint64, c.MVM_FINALIZE_TYPE);
    if (finalize != 0)
        new_flags |= c.MVM_FINALIZE_TYPE;
    st.*.mode_flags = @truncate(@as(u64, @bitCast(new_flags)));
    c.MVM_SC_WB_ST(tc, st);
}

/// Adds an object we've just allocated to the queue of those with
/// finalizers that will need calling upon collection. (finalize.c:15-27)
pub fn addToQueue(tc: Tc, obj: Object) callconv(.c) void {
    moar.assertNotFromspace(tc, obj);
    if (tc.*.num_finalize == tc.*.alloc_finalize) {
        if (tc.*.alloc_finalize != 0)
            tc.*.alloc_finalize *%= 2
        else
            tc.*.alloc_finalize = 64;
        tc.*.finalize = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.*.finalize), @sizeOf([*c][*c]c.MVMCollectable) * @as(usize, tc.*.alloc_finalize))));
    }
    tc.*.finalize[tc.*.num_finalize] = obj;
    tc.*.num_finalize +%= 1;
}

/// Walks through the per-thread finalize queues, identifying objects that
/// should be finalized, pushing them onto a finalize list, and then marking
/// that list entry. Assumes the world is stopped. (finalize.c:29-43)
fn addToFinalizing(tc: Tc, obj: Object) void {
    if (tc.*.num_finalizing == tc.*.alloc_finalizing) {
        if (tc.*.alloc_finalizing != 0)
            tc.*.alloc_finalizing *%= 2
        else
            tc.*.alloc_finalizing = 64;
        tc.*.finalizing = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.*.finalizing), @sizeOf([*c][*c]c.MVMCollectable) * @as(usize, tc.*.alloc_finalizing))));
    }
    tc.*.finalizing[tc.*.num_finalizing] = obj;
    tc.*.num_finalizing +%= 1;
}

/// (finalize.c:44-72)
fn walkThreadFinalizeQueue(tc: Tc, gen: c.MVMuint8) void {
    var collapse_pos: c.MVMuint32 = 0;
    var i: c.MVMuint32 = 0;
    while (i < tc.*.num_finalize) : (i += 1) {
        // See if it's dead, taking which generation we've marked into
        // account.
        const flags: c.MVMuint32 = tc.*.finalize[i].*.header.flags2;
        const in_gen2: c.MVMuint32 = flags & c.MVM_CF_SECOND_GEN;
        if (gen == c.MVMGCGenerations_Both or in_gen2 == 0) {
            const live: c.MVMuint32 = flags & (c.MVM_CF_GEN2_LIVE | c.MVM_CF_FORWARDER_VALID);
            if (live != 0) {
                // Alive, so just leave it in finalized queue, taking updated
                // address if needed.
                tc.*.finalize[collapse_pos] = if ((flags & c.MVM_CF_FORWARDER_VALID) != 0)
                    @as(Object, @ptrCast(@alignCast(tc.*.finalize[i].*.header.sc_forward_u.forwarder)))
                else
                    tc.*.finalize[i];
                collapse_pos += 1;
            } else {
                // Dead; needs finalizing, so pop it on the finalizing list.
                addToFinalizing(tc, tc.*.finalize[i]);
            }
        } else {
            // Just keep gen2 objects as they are during nursery-only collection
            tc.*.finalize[collapse_pos] = tc.*.finalize[i];
            collapse_pos += 1;
        }
    }
    tc.*.num_finalize = collapse_pos;
}

/// (finalize.c:73-83)
pub fn walkQueues(tc: Tc, gen: c.MVMuint8) callconv(.c) void {
    var cur_thread: [*c]c.MVMThread = atomic.load(&tc.*.instance.*.threads); // MVM_load, finalize.c:74
    while (cur_thread != null) {
        if (cur_thread.*.body.tc != null) {
            walkThreadFinalizeQueue(cur_thread.*.body.tc, gen);
            if (cur_thread.*.body.tc.*.num_finalizing > 0)
                c.MVM_gc_collect(cur_thread.*.body.tc, c.MVMGCWhatToDo_Finalizing, gen);
        }
        cur_thread = cur_thread.*.body.next;
    }
}

/// Try to run a finalization handler. Returns a true value if we do so
/// (finalize.c:85-88)
pub fn reinstateLastHandlerResult(tc: Tc, data: ?*anyopaque) callconv(.c) void {
    tc.*.last_handler_result = @as([*c]Object, @ptrCast(@alignCast(data))).*;
}

/// (finalize.c:89-91)
pub fn markLastHandlerResult(tc: Tc, data: ?*anyopaque, worklist: Worklist) callconv(.c) void {
    moar.worklistAdd(tc, worklist, @as([*c]Object, @ptrCast(@alignCast(data))));
}

/// (finalize.c:92-122)
pub fn runHandler(tc: Tc) callconv(.c) void {
    // Make sure there is a current frame and that there's a HLL handler
    // to run.
    if (tc.*.cur_frame == null)
        return;
    var handler: [*c]c.MVMCode = c.MVM_hll_current(tc).*.finalize_handler;
    if (handler != null) {
        // Drain the finalizing queue to an array.
        var drain: Object = undefined;
        {
            const r = moar.root(tc, &handler);
            defer r.pop(tc);
            drain = c.MVM_repr_alloc_init(tc, tc.*.instance.*.boot_types.BOOTArray);
            while (tc.*.num_finalizing > 0) {
                tc.*.num_finalizing -= 1;
                c.MVM_repr_push_o(tc, drain, tc.*.finalizing[tc.*.num_finalizing]);
            }
        }

        // If there is a last exception handler result stored, put something
        // in place to restore it, otherwise it may be overwritten during the
        // execution of finalizers.
        if (tc.*.last_handler_result != null) {
            const preserved: [*c]Object = @ptrCast(@alignCast(c.MVM_callstack_allocate_special_return(tc, reinstateLastHandlerResult, reinstateLastHandlerResult, markLastHandlerResult, @sizeOf(Object))));
            preserved.* = tc.*.last_handler_result;
        }

        // Invoke the handler.
        const args_record = c.MVM_callstack_allocate_args_from_c(tc, c.MVM_callsite_get_common(tc, c.MVM_CALLSITE_ID_OBJ));
        args_record.*.args.source[0].o = drain;
        c.MVM_frame_dispatch_from_c(tc, handler, args_record, null, c.MVM_RETURN_VOID);
    }
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&set, .{ .name = "MVM_gc_finalize_set", .visibility = visibility });
    @export(&addToQueue, .{ .name = "MVM_gc_finalize_add_to_queue", .visibility = visibility });
    @export(&walkQueues, .{ .name = "MVM_finalize_walk_queues", .visibility = visibility });
    @export(&reinstateLastHandlerResult, .{ .name = "reinstate_last_handler_result", .visibility = visibility });
    @export(&markLastHandlerResult, .{ .name = "mark_last_handler_result", .visibility = visibility });
    @export(&runHandler, .{ .name = "MVM_gc_finalize_run_handler", .visibility = visibility });
}
