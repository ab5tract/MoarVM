//! Zig port of src/gc/finalize.c (lines 1-123): the per-thread finalize
//! queues, the walk that moves dead finalizable objects to the finalizing
//! list, and the run of the HLL finalize handler. No behaviour change. Both
//! queues grow through `c.MVM_realloc` as in the C (64 entries, then
//! doubling). The walk starts the finalizing run through the collect port,
//! called as Zig. `reinstate_last_handler_result` and
//! `mark_last_handler_result` are non-static in the C and keep their C
//! names as exports; they are also the callbacks passed by address to
//! `MVM_callstack_allocate_special_return`, so they keep the C ABI and its
//! types. The `MVM_load` of the thread list uses src/zig/gc/atomic.zig;
//! `MVM_gc_worklist_add` is `moar.worklistAdd`; `MVMROOT` is `moar.root`.
//! The other functions are Zig-typed; their `MVM_*` exports are thin C-ABI
//! wrappers over them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");
const view = @import("view.zig");
const collect = @import("collect.zig");

const Tc = view.Tc;
const Object = view.Object;
const STable = view.STable;
const Thread = view.Thread;
const Generations = collect.Generations;

/// A finalize queue's list, as `MVMThreadContext` declares both.
const Queue = @FieldType(c.MVMThreadContext, "finalize");
comptime {
    std.debug.assert(@FieldType(c.MVMThreadContext, "finalizing") == Queue);
}

/// Turns finalization on or off for a type. (finalize.c:4-11)
pub fn set(tc: Tc, @"type": Object, finalize: bool) void {
    const st: STable = @"type".st;
    // The C's `(mode_flags & ~MVM_FINALIZE_TYPE) | (finalize ? MVM_FINALIZE_TYPE : 0)`
    // in an MVMint64, stored back into the MVMuint16.
    const bit: @TypeOf(st.mode_flags) = c.MVM_FINALIZE_TYPE;
    st.mode_flags = if (finalize) st.mode_flags | bit else st.mode_flags & ~bit;
    c.MVM_SC_WB_ST(tc, st);
}

/// Appends to one of the two queues (finalize.c:17-26, 33-42): when it is
/// full, the capacity becomes 64, or doubles, and the list is reallocated
/// to that many `MVMCollectable **`-sized entries.
inline fn append(list: *Queue, num: *u32, alloc: *u32, obj: Object) void {
    if (num.* == alloc.*) {
        alloc.* = if (alloc.* != 0) alloc.* *% 2 else 64;
        list.* = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(list.*), @sizeOf(**c.MVMCollectable) * @as(usize, alloc.*))));
    }
    list.*[num.*] = obj;
    num.* +%= 1;
}

/// Adds an object we've just allocated to the queue of those with
/// finalizers that will need calling upon collection. (finalize.c:15-27)
pub fn addToQueue(tc: Tc, obj: Object) void {
    moar.assertNotFromspace(tc, obj);
    append(&tc.finalize, &tc.num_finalize, &tc.alloc_finalize, obj);
}

/// Walks through the per-thread finalize queues, identifying objects that
/// should be finalized, pushing them onto a finalize list, and then marking
/// that list entry. Assumes the world is stopped. (finalize.c:29-43)
fn addToFinalizing(tc: Tc, obj: Object) void {
    append(&tc.finalizing, &tc.num_finalizing, &tc.alloc_finalizing, obj);
}

/// (finalize.c:44-72) The queue is compacted in place: entry `i` is read
/// before `collapse_pos <= i` is written, and the walk never changes
/// `num_finalize` (dead entries go to the other queue).
fn walkThreadFinalizeQueue(tc: Tc, gen: Generations) void {
    var collapse_pos: u32 = 0;
    for (tc.finalize[0..tc.num_finalize]) |entry| {
        const obj: Object = entry;
        // See if it's dead, taking which generation we've marked into
        // account.
        const flags = view.flags2(&obj.header).*;
        if (gen == .both or !flags.second_gen) {
            if (flags.gen2_live or flags.forwarder_valid) {
                // Alive, so just leave it in finalized queue, taking updated
                // address if needed.
                tc.finalize[collapse_pos] = if (flags.forwarder_valid)
                    view.asObject(obj.header.sc_forward_u.forwarder)
                else
                    obj;
                collapse_pos += 1;
            } else {
                // Dead; needs finalizing, so pop it on the finalizing list.
                addToFinalizing(tc, obj);
            }
        } else {
            // Just keep gen2 objects as they are during nursery-only collection
            tc.finalize[collapse_pos] = obj;
            collapse_pos += 1;
        }
    }
    tc.num_finalize = collapse_pos;
}

/// (finalize.c:73-83)
pub fn walkQueues(tc: Tc, gen: Generations) void {
    var cur_thread: ?Thread = atomic.load(&tc.instance.*.threads); // MVM_load, finalize.c:74
    while (cur_thread) |thread| : (cur_thread = thread.body.next) {
        const thread_tc: Tc = thread.body.tc orelse continue;
        walkThreadFinalizeQueue(thread_tc, gen);
        if (thread_tc.num_finalizing > 0)
            collect.collect(thread_tc, .finalizing, gen);
    }
}

/// Try to run a finalization handler. Returns a true value if we do so
/// (finalize.c:85-88)
fn reinstateLastHandlerResult(tc: [*c]c.MVMThreadContext, data: ?*anyopaque) callconv(.c) void {
    const slot: *?*c.MVMObject = @ptrCast(@alignCast(data));
    tc.*.last_handler_result = slot.*;
}

/// (finalize.c:89-91)
fn markLastHandlerResult(tc: [*c]c.MVMThreadContext, data: ?*anyopaque, worklist: [*c]c.MVMGCWorklist) callconv(.c) void {
    const slot: *?*c.MVMObject = @ptrCast(@alignCast(data));
    moar.worklistAdd(tc, worklist, slot);
}

/// (finalize.c:92-122)
pub fn runHandler(tc: Tc) void {
    // Make sure there is a current frame and that there's a HLL handler
    // to run.
    if (tc.cur_frame == null)
        return;
    var handler: ?*c.MVMCode = c.MVM_hll_current(tc).*.finalize_handler;
    if (handler == null)
        return;

    // Drain the finalizing queue to an array.
    const drain: Object = drain: {
        const r = moar.root(tc, &handler);
        defer r.pop(tc);
        const array: Object = c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTArray);
        while (tc.num_finalizing > 0) {
            tc.num_finalizing -= 1;
            c.MVM_repr_push_o(tc, array, tc.finalizing[tc.num_finalizing]);
        }
        break :drain array;
    };

    // If there is a last exception handler result stored, put something in
    // place to restore it, otherwise it may be overwritten during the
    // execution of finalizers.
    if (tc.last_handler_result != null) {
        const preserved: *?*c.MVMObject = @ptrCast(@alignCast(c.MVM_callstack_allocate_special_return(tc, reinstateLastHandlerResult, reinstateLastHandlerResult, markLastHandlerResult, @sizeOf(*c.MVMObject))));
        preserved.* = tc.last_handler_result;
    }

    // Invoke the handler.
    const args_record: *c.MVMCallStackArgsFromC = c.MVM_callstack_allocate_args_from_c(tc, c.MVM_callsite_get_common(tc, c.MVM_CALLSITE_ID_OBJ));
    args_record.args.source[0].o = drain;
    c.MVM_frame_dispatch_from_c(tc, handler, args_record, null, c.MVM_RETURN_VOID);
}

// ---- the C ABI -------------------------------------------------------------

fn setExport(tc: [*c]c.MVMThreadContext, @"type": [*c]c.MVMObject, finalize: c.MVMint64) callconv(.c) void {
    set(tc, @"type", finalize != 0);
}

fn addToQueueExport(tc: [*c]c.MVMThreadContext, obj: [*c]c.MVMObject) callconv(.c) void {
    addToQueue(tc, obj);
}

fn walkQueuesExport(tc: [*c]c.MVMThreadContext, gen: c.MVMuint8) callconv(.c) void {
    // Non-exhaustive, so any byte converts and compares as the C compares it.
    walkQueues(tc, @fromBackingInt(@intCast(gen)));
}

fn runHandlerExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    runHandler(tc);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&setExport, .{ .name = "MVM_gc_finalize_set", .visibility = visibility });
    @export(&addToQueueExport, .{ .name = "MVM_gc_finalize_add_to_queue", .visibility = visibility });
    @export(&walkQueuesExport, .{ .name = "MVM_finalize_walk_queues", .visibility = visibility });
    @export(&reinstateLastHandlerResult, .{ .name = "reinstate_last_handler_result", .visibility = visibility });
    @export(&markLastHandlerResult, .{ .name = "mark_last_handler_result", .visibility = visibility });
    @export(&runHandlerExport, .{ .name = "MVM_gc_finalize_run_handler", .visibility = visibility });
}
