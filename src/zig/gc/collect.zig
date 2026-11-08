//! Zig port of src/gc/collect.c (lines 1-799): the collector proper. A run
//! swaps the nursery semi-spaces, adds the root sets in the C order and
//! drains the worklist, copying nursery objects to tospace on their first
//! survival and promoting them to gen2 on their second, marking gen2
//! objects on a full run, and passing items owned by other threads to their
//! in-trays; then the sweeps of the uncopied fromspace, of gen2 and of the
//! queued STables. Faithful port; no behaviour change. The worklist macros
//! of src/gc/worklist.h stay C for C callers; `MVM_gc_worklist_add` is
//! `moar.worklistAdd` and `MVM_gc_worklist_get` is `worklistGet` below.
//! Every atomic site uses src/zig/gc/atomic.zig (or `moar.trycas` for
//! `MVM_trycas`) and names the C macro and line. `GCDEBUG_LOG` and the
//! `MVM_GC_DEBUG_ENABLED` blocks (src/gc/orchestrate.h:45-53) are kept as
//! comptime-guarded blocks: `MVM_GC_DEBUG_LOG_FLAGS` is 0, so, as in the C,
//! they compile to nothing. `#if MVM_GC_DEBUG` and
//! `#ifdef MVM_USE_OVERFLOW_SERIALIZATION_INDEX` are comptime branches on
//! the translated macros.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");
const allocation = @import("allocation.zig");

const Tc = [*c]c.MVMThreadContext;
const Instance = [*c]c.MVMInstance;
const Worklist = [*c]c.MVMGCWorklist;
const Collectable = c.MVMCollectable;
const Col = [*c]Collectable;
const ColPtr = [*c][*c]Collectable;
const PassedWork = [*c]c.MVMGCPassedWork;
const Object = [*c]c.MVMObject;
const STable = [*c]c.MVMSTable;
const Frame = [*c]c.MVMFrame;

const worklistAdd = moar.worklistAdd;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.mode == .Debug) std.debug.assert(ok);
}

/// `#ifdef MVM_USE_OVERFLOW_SERIALIZATION_INDEX` (src/moar.h:136).
const overflow_sci = @hasDecl(c, "MVM_USE_OVERFLOW_SERIALIZATION_INDEX");

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

/// `(void *)p` for a `%p` argument.
inline fn vp(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}

/// MVM_gc_worklist_get(tc, worklist) (worklist.h:105-108).
inline fn worklistGet(worklist: Worklist) ColPtr {
    if (worklist.*.items != 0) {
        worklist.*.items -= 1;
        return worklist.*.list[worklist.*.items];
    }
    return null;
}

/// `work->items`. Through a single-item pointer: in Zig 0.16 indexing an
/// array field reached through a C pointer (`work.*.items[i]` with `work`
/// a `[*c]`) indexes the field's address as a `[*c][62]...`, that is
/// whole arrays past it, not the element.
inline fn passedItems(work: PassedWork) *[c.MVM_GC_PASS_WORK_SIZE]ColPtr {
    return &@as(*c.MVMGCPassedWork, work).items;
}

/// STABLE(o) and REPR(o) on a collectable viewed as an object.
inline fn stableOf(p: anytype) STable {
    return @as(Object, @ptrCast(@alignCast(p))).*.st;
}
inline fn reprOf(p: anytype) [*c]const c.MVMREPROps {
    return stableOf(p).*.REPR;
}
/// OBJECT_BODY(o).
inline fn objectBody(o: Object) ?*anyopaque {
    return moar.objectBody(o);
}

/// Combines a piece of work that will be passed to another thread with the
/// ID of the target thread to pass it to. (collect.c:3-8)
const ThreadWork = extern struct {
    target: c.MVMuint32,
    work: PassedWork,
};

/// Current chunks of work we're building up to pass. (collect.c:10-14)
const WorkToPass = extern struct {
    num_target_threads: c.MVMuint32,
    target_work: [*c]ThreadWork,
};

/// The size of the nursery that a new thread should get. The main thread will
/// get a full-size one right away. (collect.c:22-30)
pub fn newThreadNurserySize(i: Instance) callconv(.c) c.MVMuint32 {
    return if (i.*.main_thread != null)
        (if (c.MVM_NURSERY_SIZE < c.MVM_NURSERY_THREAD_START)
            c.MVM_NURSERY_SIZE
        else
            c.MVM_NURSERY_THREAD_START)
    else
        c.MVM_NURSERY_SIZE;
}

/// Does a garbage collection run. Exactly what it does is configured by the
/// couple of arguments that it takes: what_to_do says where to look for
/// things to add to the worklist (everywhere, just thread local stuff, or
/// just the in-tray), gen whether to collect the nursery or both
/// generations. The roots are added and processed in phases, to try to
/// avoid building up a huge worklist. (collect.c:32-161)
pub fn collect(tc: Tc, what_to_do: c.MVMuint8, gen: c.MVMuint8) callconv(.c) void {
    // Create a GC worklist.
    const worklist = c.MVM_gc_worklist_create(tc, @intFromBool(gen != c.MVMGCGenerations_Nursery));

    // Initialize work passing data structure.
    var wtp: WorkToPass = undefined;
    wtp.num_target_threads = 0;
    wtp.target_work = null;

    // See what we need to work on this time.
    if (what_to_do == c.MVMGCWhatToDo_InTray) {
        // We just need to process anything in the in-tray.
        addInTrayToWorklist(tc, worklist);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from in tray \n", .{@as(c_uint, worklist.*.items)});
        processWorklist(tc, worklist, &wtp, gen);
    } else if (what_to_do == c.MVMGCWhatToDo_Finalizing) {
        // Need to process the finalizing queue.
        var i: c.MVMuint32 = 0;
        while (i < tc.*.num_finalizing) : (i += 1)
            worklistAdd(tc, worklist, &tc.*.finalizing[i]);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from finalizing \n", .{@as(c_uint, worklist.*.items)});
        processWorklist(tc, worklist, &wtp, gen);
    } else {
        // Main collection run. The current tospace becomes fromspace, with
        // the size of the current tospace becoming stashed as the size of
        // that fromspace.
        const old_fromspace: ?*anyopaque = tc.*.nursery_fromspace;
        const old_fromspace_size: c.MVMuint32 = tc.*.nursery_fromspace_size;
        tc.*.nursery_fromspace = tc.*.nursery_tospace;
        tc.*.nursery_fromspace_size = tc.*.nursery_tospace_size;

        // Decide on this threads's tospace size. If fromspace was already at
        // the maximum nursery size, then that is the new tospace size. If
        // not, then see if this thread caused the current GC run, and grant
        // it a bigger tospace. Otherwise, new tospace size is left as the
        // last tospace size.
        if (tc.*.nursery_tospace_size < c.MVM_NURSERY_SIZE) {
            if (tc.*.instance.*.thread_to_blame_for_gc == tc)
                tc.*.nursery_tospace_size *%= 2;
        }

        // If the old fromspace matches the target size, just re-use it. If
        // not, free it and allocate a new tospace.
        if (old_fromspace_size == tc.*.nursery_tospace_size) {
            tc.*.nursery_tospace = old_fromspace;
        } else {
            c.MVM_free(old_fromspace);
            tc.*.nursery_tospace = c.MVM_calloc(1, tc.*.nursery_tospace_size);
        }

        // Reset nursery allocation pointers to the new tospace.
        tc.*.nursery_alloc = tc.*.nursery_tospace;
        tc.*.nursery_alloc_limit = @as([*c]u8, @ptrCast(tc.*.nursery_tospace)) + tc.*.nursery_tospace_size;

        // Add permanent roots and process them; only one thread will do
        // this, since they are instance-wide.
        if (what_to_do != c.MVMGCWhatToDo_NoInstance) {
            c.MVM_gc_root_add_permanents_to_worklist(tc, worklist, null);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from instance permanents\n", .{@as(c_uint, worklist.*.items)});
            processWorklist(tc, worklist, &wtp, gen);
            c.MVM_gc_root_add_instance_roots_to_worklist(tc, worklist, null);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from instance roots\n", .{@as(c_uint, worklist.*.items)});
            processWorklist(tc, worklist, &wtp, gen);
        }

        // Add per-thread state to worklist and process it.
        c.MVM_gc_root_add_tc_roots_to_worklist(tc, worklist, null);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from TC objects\n", .{@as(c_uint, worklist.*.items)});
        processWorklist(tc, worklist, &wtp, gen);

        // Add temporary roots and process them (these are per-thread).
        c.MVM_gc_root_add_temps_to_worklist(tc, worklist, null);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from thread temps\n", .{@as(c_uint, worklist.*.items)});
        processWorklist(tc, worklist, &wtp, gen);

        // Add things that are roots for the first generation because they are
        // pointed to by objects in the second generation and process them
        // (also per-thread). Note we need not do this if we're doing a full
        // collection anyway (in fact, we must not for correctness, otherwise
        // the gen2 rooting keeps them alive forever).
        if (gen == c.MVMGCGenerations_Nursery) {
            c.MVM_gc_root_add_gen2s_to_worklist(tc, worklist);
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from gen2 \n", .{@as(c_uint, worklist.*.items)});
            processWorklist(tc, worklist, &wtp, gen);
        }

        // Process anything in the in-tray.
        addInTrayToWorklist(tc, worklist);
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : processing %d items from in tray \n", .{@as(c_uint, worklist.*.items)});
        processWorklist(tc, worklist, &wtp, gen);

        // At this point, we have probably done most of the work we will
        // need to (only get more if another thread passes us more); zero
        // out the remaining tospace.
        const rest: [*c]u8 = @ptrCast(tc.*.nursery_alloc);
        @memset(rest[0 .. @intFromPtr(tc.*.nursery_alloc_limit) - @intFromPtr(tc.*.nursery_alloc)], 0);
    }

    // Destroy the worklist.
    c.MVM_gc_worklist_destroy(tc, worklist);

    // Pass any work for other threads we accumulated but that didn't trigger
    // the work passing threshold, then cleanup work passing list.
    if (wtp.num_target_threads != 0) {
        passLeftoverWork(tc, &wtp);
        c.MVM_free(wtp.target_work);
    }
}

/// Processes the current worklist. (collect.c:163-346)
fn processWorklist(tc: Tc, worklist: Worklist, wtp: *WorkToPass, gen: c.MVMuint8) void {
    var item_ptr: ColPtr = undefined;
    var new_addr: Col = undefined;
    var gen2count: c.MVMuint32 = undefined;

    // Grab the second generation allocator; we may move items into the
    // old generation.
    const gen2: [*c]c.MVMGen2Allocator = tc.*.gen2;

    while (true) {
        item_ptr = worklistGet(worklist);
        if (item_ptr == null) break;
        // Dereference the object we're considering.
        const item: Col = item_ptr.*;
        var item_gen2: c.MVMuint8 = undefined;
        var to_gen2: c.MVMuint8 = 0;

        // If the item is NULL, that's fine - it's just a null reference and
        // thus we've no object to consider.
        if (item == null)
            continue;

        // If it's in the second generation and we're only doing a nursery,
        // collection, we have nothing to do.
        item_gen2 = item.*.flags2 & @as(u8, c.MVM_CF_SECOND_GEN);
        if (item_gen2 != 0) {
            if (gen == c.MVMGCGenerations_Nursery)
                continue;
            if (item.*.flags2 & c.MVM_CF_GEN2_LIVE != 0) {
                // gen2 and marked as live.
                continue;
            }
        } else if (item.*.flags2 & c.MVM_CF_FORWARDER_VALID != 0) {
            // If the item was already seen and copied, then it will have a
            // forwarding address already. Just update this pointer to the
            // new address and we're done.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (item_ptr.* != item.*.sc_forward_u.forwarder) {
                    gcdebugLog(tc, "Thread %d run %d : updating handle %p from %p to forwarder %p\n", .{ vp(item_ptr), vp(item), vp(item.*.sc_forward_u.forwarder) });
                } else {
                    gcdebugLog(tc, "Thread %d run %d : already visited handle %p to forwarder %p\n", .{ vp(item_ptr), vp(item.*.sc_forward_u.forwarder) });
                }
            }
            // MVM_barrier() (collect.c:207).
            atomic.fence();
            item_ptr.* = item.*.sc_forward_u.forwarder;
            continue;
        } else {
            // If the pointer is already into tospace (the bit we've already
            // copied into), we already updated it, so we're done.
            if (@intFromPtr(item) >= @intFromPtr(tc.*.nursery_tospace) and @intFromPtr(item) < @intFromPtr(tc.*.nursery_alloc)) {
                continue;
            }
        }

        // If it's owned by a different thread, we need to pass it over to
        // the owning thread.
        if (item.*.owner != tc.*.thread_id) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : sending a handle %p to object %p to thread %d\n", .{ vp(item_ptr), vp(item), @as(c_uint, item.*.owner) });
            passWorkItem(tc, wtp, item_ptr);
            continue;
        }

        // If it's in to-space but *ahead* of our copy offset then it's an
        // out-of-date pointer and we have some kind of corruption.
        if (@intFromPtr(item) >= @intFromPtr(tc.*.nursery_alloc) and @intFromPtr(item) < @intFromPtr(tc.*.nursery_alloc_limit))
            c.MVM_panic(1, "Heap corruption detected: pointer %p to past fromspace", vp(item));

        // At this point, we didn't already see the object, which means we
        // need to take some action. Go on the generation...
        if (item_gen2 != 0) {
            cAssert(item.*.flags2 & c.MVM_CF_FORWARDER_VALID == 0);
            // It's in the second generation. We'll just mark it.
            new_addr = item;
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                gcdebugLog(tc, "Thread %d run %d : handle %p was already %p\n", .{ vp(item_ptr), vp(new_addr) });
            }
            item.*.flags2 |= c.MVM_CF_GEN2_LIVE;
            cAssert(item_ptr.* == new_addr);
        } else {
            // Catch NULL stable (always sign of trouble) in debug mode.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (stableOf(item) == null)
                    gcdebugLog(tc, "Thread %d run %d : found a zeroed handle %p to object %p\n", .{ vp(item_ptr), vp(item) });
            }

            // Did we see it in the nursery before, or should we move it to
            // gen2 anyway since either:
            //   * A persistent ID was requested?
            //   * It is referenced by a gen2 aggregate
            if (item.*.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0 or
                item.*.flags2 & (c.MVM_CF_NURSERY_SEEN | c.MVM_CF_REF_FROM_GEN2) != 0)
            {
                // Yes; we should move it to the second generation. Allocate
                // space in the second generation.
                to_gen2 = 1;
                new_addr = @ptrCast(@alignCast(if (item.*.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0)
                    c.MVM_gc_object_id_use_allocation(tc, item)
                else
                    c.MVM_gc_gen2_allocate(gen2, item.*.size)));

                // Add on to the promoted amount (used both to decide when to do
                // the next full collection, as well as for profiling). Note we
                // add unmanaged size on for objects below.
                tc.*.gc_promoted_bytes +%= item.*.size;

                // Copy the object to the second generation and mark it as
                // living there.
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : copying an object %p of size %d to gen2 %p\n", .{ vp(item), @as(c_int, item.*.size), vp(new_addr) });
                @memcpy(@as([*]u8, @ptrCast(new_addr))[0..item.*.size], @as([*]const u8, @ptrCast(item))[0..item.*.size]);
                if (new_addr.*.flags2 & c.MVM_CF_NURSERY_SEEN != 0)
                    new_addr.*.flags2 ^= c.MVM_CF_NURSERY_SEEN;
                new_addr.*.flags2 |= c.MVM_CF_SECOND_GEN;

                // If it's a frame with an active work area, we need to keep
                // on visiting it. Also add on object's unmanaged size.
                if (new_addr.*.flags1 & c.MVM_CF_FRAME != 0) {
                    if (@as(Frame, @ptrCast(@alignCast(new_addr))).*.work != null)
                        c.MVM_gc_root_gen2_add(tc, new_addr);
                } else if (new_addr.*.flags1 & (c.MVM_CF_TYPE_OBJECT | c.MVM_CF_STABLE) == 0) {
                    const new_obj_addr: Object = @ptrCast(@alignCast(new_addr));
                    if (reprOf(new_obj_addr).*.unmanaged_size) |unmanaged_size_fn| {
                        const unmanaged_size: c.MVMuint64 = unmanaged_size_fn(tc, stableOf(new_obj_addr), objectBody(new_obj_addr));
                        // MVMuint32 += MVMuint64: the C truncates the sum.
                        tc.*.gc_promoted_bytes = @truncate(@as(c.MVMuint64, tc.*.gc_promoted_bytes) +% unmanaged_size);
                        if (tc.*.instance.*.profiling != 0)
                            c.MVM_profiler_log_unmanaged_data_promoted(tc, unmanaged_size);
                    }
                }

                // If we're going to sweep the second generation, also need
                // to mark it as live.
                if (gen == c.MVMGCGenerations_Both)
                    new_addr.*.flags2 |= c.MVM_CF_GEN2_LIVE;
            } else {
                // No, so it will live in the nursery for another GC
                // iteration. Allocate space in the nursery.
                new_addr = @ptrCast(@alignCast(tc.*.nursery_alloc));
                tc.*.nursery_alloc = @as([*c]u8, @ptrCast(tc.*.nursery_alloc)) + allocation.alignSize(item.*.size);
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : copying an object %p (reprid %d) of size %d to tospace %p\n", .{ vp(item), if (item.*.flags1 & (c.MVM_CF_TYPE_OBJECT | c.MVM_CF_STABLE | c.MVM_CF_FRAME) != 0) @as(c_int, -1) else @as(c_int, @bitCast(reprOf(item).*.ID)), @as(c_int, item.*.size), vp(new_addr) });

                // Copy the object to tospace and mark it as seen in the
                // nursery (so the next time around it will move to the
                // older generation, if it survives).
                @memcpy(@as([*]u8, @ptrCast(new_addr))[0..item.*.size], @as([*]const u8, @ptrCast(item))[0..item.*.size]);
                new_addr.*.flags2 |= c.MVM_CF_NURSERY_SEEN;
            }

            // Store the forwarding pointer and update the original
            // reference.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (new_addr != item)
                    gcdebugLog(tc, "Thread %d run %d : updating handle %p from referent %p (reprid %d) to %p\n", .{ vp(item_ptr), vp(item), if (item.*.flags1 & (c.MVM_CF_TYPE_OBJECT | c.MVM_CF_STABLE | c.MVM_CF_FRAME) != 0) @as(c_int, -1) else @as(c_int, @bitCast(reprOf(item).*.ID)), vp(new_addr) });
            }
            item_ptr.* = new_addr;
            item.*.sc_forward_u.forwarder = new_addr;
            // MVM_barrier() (collect.c:320).
            atomic.fence();
            // Set the flag on the copy of item *in fromspace* to mark that the
            // forwarder pointer is valid.
            item.*.flags2 |= c.MVM_CF_FORWARDER_VALID;
        }

        // Finally, we need to mark the collectable (at its moved address).
        // Track how many items we had before we mark it, in case we need
        // to write barrier them post-move to uphold the generational
        // invariant.
        gen2count = worklist.*.items;
        markCollectable(tc, worklist, new_addr);

        // In moving an object to generation 2, we may have left it pointing
        // to nursery objects. If so, make sure it's in the gen2 roots.
        if (to_gen2 != 0) {
            var j: ColPtr = undefined;
            const max: c.MVMuint32 = worklist.*.items;
            var k: c.MVMuint32 = gen2count;

            while (k < max) : (k += 1) {
                j = worklist.*.list[k];
                if (j.* != null)
                    c.MVM_gc_write_barrier_no_update_referenced(tc, new_addr, j.*);
            }
        }
    }
}

/// Marks a collectable item (object, type object, STable). (collect.c:348-414)
pub fn markCollectable(tc: Tc, worklist: Worklist, new_addr: Col) callconv(.c) void {
    var i: c.MVMuint16 = undefined;
    var sc_idx: c.MVMuint32 = undefined;

    cAssert(new_addr.*.flags2 & c.MVM_CF_FORWARDER_VALID == 0);
    // assert(REPR(new_addr)); is commented out in the C (collect.c:354).
    sc_idx = c.MVM_sc_get_idx_of_sc(new_addr);
    if (sc_idx > 0) {
        if (comptime c.MVM_GC_DEBUG != 0) {
            if (sc_idx >= tc.*.instance.*.all_scs_next_idx)
                c.MVM_panic(1, "SC index out of range");
        }
        worklistAdd(tc, worklist, &tc.*.instance.*.all_scs[sc_idx].*.sc);
    }

    if (new_addr.*.flags1 & c.MVM_CF_TYPE_OBJECT != 0) {
        // Add the STable to the worklist.
        worklistAdd(tc, worklist, &@as(Object, @ptrCast(@alignCast(new_addr))).*.st);
    } else if (new_addr.*.flags1 & c.MVM_CF_STABLE != 0) {
        // Add all references in the STable to the work list.
        const new_addr_st: STable = @ptrCast(@alignCast(new_addr));
        i = 0;
        while (i < new_addr_st.*.type_check_cache_length) : (i += 1)
            worklistAdd(tc, worklist, &new_addr_st.*.type_check_cache[i]);
        if (new_addr_st.*.container_spec != null)
            if (new_addr_st.*.container_spec.*.gc_mark_data) |gc_mark_data|
                gc_mark_data(tc, new_addr_st, worklist);
        if (new_addr_st.*.boolification_spec != null)
            worklistAdd(tc, worklist, &new_addr_st.*.boolification_spec.*.method);
        worklistAdd(tc, worklist, &new_addr_st.*.WHO);
        worklistAdd(tc, worklist, &new_addr_st.*.WHAT);
        worklistAdd(tc, worklist, &new_addr_st.*.HOW);
        worklistAdd(tc, worklist, &new_addr_st.*.HOW_sc);
        if (new_addr_st.*.mode_flags & c.MVM_PARAMETRIC_TYPE != 0) {
            worklistAdd(tc, worklist, &new_addr_st.*.paramet.ric.parameterizer);
            worklistAdd(tc, worklist, &new_addr_st.*.paramet.ric.lookup);
        } else if (new_addr_st.*.mode_flags & c.MVM_PARAMETERIZED_TYPE != 0) {
            worklistAdd(tc, worklist, &new_addr_st.*.paramet.erized.parametric_type);
            worklistAdd(tc, worklist, &new_addr_st.*.paramet.erized.parameters);
        }

        // If it needs to have its REPR data marked, do that.
        if (new_addr_st.*.REPR.*.gc_mark_repr_data) |gc_mark_repr_data|
            gc_mark_repr_data(tc, new_addr_st, worklist);
    } else if (new_addr.*.flags1 & c.MVM_CF_FRAME != 0) {
        c.MVM_gc_root_add_frame_roots_to_worklist(tc, worklist, @ptrCast(@alignCast(new_addr)));
    } else {
        // Need to view it as an object in here.
        const new_addr_obj: Object = @ptrCast(@alignCast(new_addr));

        // Add the STable to the worklist.
        worklistAdd(tc, worklist, &new_addr_obj.*.st);

        // If needed, mark it. This will add addresses to the worklist
        // that will need updating. Note that we are passing the address
        // of the object *after* copying it since those are the addresses
        // we care about updating; the old chunk of memory is now dead!
        if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
            if (stableOf(new_addr_obj) == null)
                c.MVM_panic(c.MVM_exitcode_gcnursery, "Found an outdated reference to address %p", vp(new_addr));
        }
        if (reprOf(new_addr_obj).*.gc_mark) |gc_mark|
            gc_mark(tc, stableOf(new_addr_obj), objectBody(new_addr_obj), worklist);
    }
}

/// Adds a chunk of work to another thread's in-tray. (collect.c:416-447)
/// `pub` only for the in-tray test (collect_test.zig); not exported.
pub fn pushWorkToThreadInTray(tc: Tc, target: c.MVMuint32, work: PassedWork) void {
    var target_tray: *volatile PassedWork = undefined;

    // Locate the thread to pass the work to.
    var target_tc: Tc = null;
    if (target == 1) {
        // It's going to the main thread.
        target_tc = tc.*.instance.*.main_thread;
    } else {
        // MVM_load(&tc->instance->threads) (collect.c:427).
        var t: [*c]c.MVMThread = atomic.load(&tc.*.instance.*.threads);
        while (true) {
            if (t.*.body.tc != null and t.*.body.tc.*.thread_id == target) {
                target_tc = t.*.body.tc;
                break;
            }
            t = t.*.body.next;
            if (t == null) break;
        }
        if (target_tc == null)
            c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: invalid thread ID %d in GC work pass", @as(c_uint, target));
    }

    // Pass the work, chaining any other in-tray entries for the thread
    // after us.
    target_tray = &target_tc.*.gc_in_tray;
    while (true) {
        const orig: PassedWork = target_tray.*;
        work.*.next = orig;
        // MVM_casptr(target_tray, orig, work) (collect.c:444).
        if (atomic.cas(target_tray, orig, work) == orig)
            return;
    }
}

/// Adds work to list of items to pass over to another thread, and if we
/// reach the pass threshold then does the passing. (collect.c:449-490)
fn passWorkItem(tc: Tc, wtp: *WorkToPass, item_ptr: ColPtr) void {
    var target_info: [*c]ThreadWork = null;
    const target: c.MVMuint32 = item_ptr.*.*.owner;
    var j: c.MVMuint32 = undefined;

    // Find any existing thread work passing list for the target.
    if (target == 0)
        c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: zeroed target thread ID in work pass");
    j = 0;
    while (j < wtp.num_target_threads) : (j += 1) {
        if (wtp.target_work[j].target == target) {
            target_info = &wtp.target_work[j];
            break;
        }
    }

    // If there's no entry for this target, create one.
    if (target_info == null) {
        wtp.num_target_threads +%= 1;
        wtp.target_work = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(wtp.target_work), @as(usize, wtp.num_target_threads) * @sizeOf(ThreadWork))));
        target_info = &wtp.target_work[wtp.num_target_threads - 1];
        target_info.*.target = target;
        target_info.*.work = null;
    }

    // See if there's a currently active list; create it if not.
    if (target_info.*.work == null) {
        target_info.*.work = @ptrCast(@alignCast(c.MVM_calloc(1, @sizeOf(c.MVMGCPassedWork))));
    }

    // Add this item to the work list.
    passedItems(target_info.*.work)[target_info.*.work.*.num_items] = item_ptr;
    target_info.*.work.*.num_items += 1;

    // If we've hit the limit, pass this work to the target thread.
    if (target_info.*.work.*.num_items == c.MVM_GC_PASS_WORK_SIZE) {
        pushWorkToThreadInTray(tc, target, target_info.*.work);
        target_info.*.work = null;
    }
}

/// Passes all work for other threads that we've got left in our to-pass
/// list. (collect.c:492-499)
fn passLeftoverWork(tc: Tc, wtp: *WorkToPass) void {
    var j: c.MVMuint32 = 0;
    while (j < wtp.num_target_threads) : (j += 1)
        if (wtp.target_work[j].work != null)
            pushWorkToThreadInTray(tc, wtp.target_work[j].target, wtp.target_work[j].work);
}

/// Takes work in a thread's in-tray, if any, and adds it to the worklist.
/// (collect.c:501-527)
fn addInTrayToWorklist(tc: Tc, worklist: Worklist) void {
    const in_tray: *volatile PassedWork = &tc.*.gc_in_tray;
    var head: PassedWork = undefined;

    // Get work to process.
    while (true) {
        // See if there's anything in the in-tray; if not, we're done.
        head = in_tray.*;
        if (head == null)
            return;

        // Otherwise, try to take it.
        // MVM_casptr(in_tray, head, NULL) (collect.c:514).
        if (atomic.cas(in_tray, head, null) == head)
            break;
    }

    // Go through list, adding to worklist.
    while (head != null) {
        const next: PassedWork = head.*.next;
        var i: c.MVMuint32 = 0;
        while (i < head.*.num_items) : (i += 1)
            worklistAdd(tc, worklist, passedItems(head)[i]);
        c.MVM_free(head);
        head = next;
    }
}

/// Save dead STable pointers to delete later.. (collect.c:529-539)
fn enqueueStableForDeletion(tc: Tc, st: STable) void {
    var old_head: STable = undefined;
    if (comptime overflow_sci)
        cAssert(st.*.header.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED == 0);
    while (true) {
        old_head = tc.*.instance.*.stables_to_free;
        st.*.header.sc_forward_u.st = old_head;
        // MVM_trycas(&tc->instance->stables_to_free, old_head, st) (collect.c:538).
        const slot: *STable = &tc.*.instance.*.stables_to_free;
        if (moar.trycas(slot, old_head, st)) break;
    }
}

/// Some objects, having been copied, need no further attention. Others
/// need to do some additional freeing, however. This goes through the
/// fromspace and does any needed work to free uncopied things (this may
/// run in parallel with the mutator, which will be operating on tospace).
/// (collect.c:541-614)
pub fn freeNurseryUncopied(executing_thread: Tc, tc: Tc, limit: ?*anyopaque) callconv(.c) void {
    // We start scanning the fromspace, and keep going until we hit
    // the end of the area allocated in it.
    var scan: [*c]u8 = @ptrCast(tc.*.nursery_fromspace);

    var do_prof_log: c.MVMuint8 = 0;

    if (executing_thread.*.prof_data != null)
        do_prof_log = 1;

    while (@intFromPtr(scan) < @intFromPtr(limit)) {
        // The object here is dead if it never got a forwarding pointer
        // written in to it.
        const item: Col = @ptrCast(@alignCast(scan));
        const dead: c.MVMuint8 = @intFromBool(item.*.flags2 & c.MVM_CF_FORWARDER_VALID == 0);

        if (dead == 0)
            cAssert(item.*.sc_forward_u.forwarder != null);

        // Now go by collectable type.
        if (item.*.flags1 & c.MVM_CF_TYPE_OBJECT != 0) {
            // Type object
            if (comptime overflow_sci) {
                if (dead != 0 and item.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0)
                    c.MVM_free(item.*.sc_forward_u.sci);
            }
            if (dead != 0 and item.*.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0)
                c.MVM_gc_object_id_clear(tc, item);
        } else if (item.*.flags1 & c.MVM_CF_STABLE != 0) {
            const st: STable = @ptrCast(@alignCast(item));
            if (dead != 0) {
                // (The C's GCDEBUG_LOG here is commented out, collect.c:577.)
                if (comptime overflow_sci) {
                    if (item.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0) {
                        c.MVM_free(item.*.sc_forward_u.sci);
                        // Arguably we don't need to do this, if we're always
                        // consistent about what we put on the stable queue.
                        item.*.flags1 &= ~@as(u8, c.MVM_CF_SERIALZATION_INDEX_ALLOCATED);
                    }
                }
                enqueueStableForDeletion(tc, st);
            }
        } else if (item.*.flags1 & c.MVM_CF_FRAME != 0) {
            if (dead != 0)
                c.MVM_frame_destroy(tc, @ptrCast(@alignCast(item)));
        } else {
            // Object instance. If dead, call gc_free if needed. Scan is
            // incremented by object size.
            const obj: Object = @ptrCast(@alignCast(item));
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : collecting an object %p in the nursery with reprid %d\n", .{ vp(item), @as(c_uint, reprOf(obj).*.ID) });
            if (dead != 0) {
                if (reprOf(obj).*.gc_free) |gc_free|
                    gc_free(tc, obj);
            }
            if (dead != 0 and do_prof_log != 0) {
                c.MVM_profiler_log_gc_deallocate(executing_thread, obj);
            }
            if (comptime overflow_sci) {
                if (dead != 0 and item.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0)
                    c.MVM_free(item.*.sc_forward_u.sci);
            }
            if (dead != 0 and item.*.flags1 & c.MVM_CF_HAS_OBJECT_ID != 0)
                c.MVM_gc_object_id_clear(tc, item);
        }

        // Go to the next item.
        scan = scan + allocation.alignSize(item.*.size);
    }
}

/// Free STables (in any thread/generation!) queued to be freed.
/// (collect.c:616-631)
pub fn freeStables(tc: Tc) callconv(.c) void {
    if (comptime c.MVM_GC_DEBUG < 3) {
        var st: STable = tc.*.instance.*.stables_to_free;
        while (st != null) {
            const st_to_free: STable = st;
            st = st_to_free.*.header.sc_forward_u.st;
            st_to_free.*.header.sc_forward_u.st = null;
            c.MVM_6model_stable_gc_free(tc, st_to_free);
            if (comptime c.MVM_GC_DEBUG != 0)
                tc.*.gc_debug_stables_freed +%= 1;
        }
    }
    tc.*.instance.*.stables_to_free = null;
}

/// Goes through the unmarked objects in the second generation heap and builds
/// free lists out of them. Also does any required finalization.
/// (collect.c:633-799)
pub fn freeGen2Unmarked(executing_thread: Tc, tc: Tc, global_destruction: c.MVMint32) callconv(.c) void {
    // Visit each of the size class bins.
    const gen2: [*c]c.MVMGen2Allocator = tc.*.gen2;
    var bin: c.MVMuint32 = undefined;
    var obj_size: c.MVMuint32 = undefined;
    var page: c.MVMuint32 = undefined;
    var i: c.MVMuint32 = undefined;
    var do_prof_log: c.MVMuint8 = 0;

    var freelist_insert_pos: [*c][*c][*c]u8 = undefined;

    if (executing_thread.*.prof_data != null)
        do_prof_log = 1;

    bin = 0;
    while (bin < c.MVM_GEN2_BINS) : (bin += 1) {
        // If we've nothing allocated in this size class, skip it.
        if (gen2.*.size_classes[bin].pages == null)
            continue;

        // Calculate object size for this bin.
        obj_size = (bin + 1) << c.MVM_GEN2_BIN_BITS;

        // freelist_insert_pos is a pointer to a memory location that
        // stores the address of the last traversed free list node (char **).
        // Initialize freelist insertion position to free list head.
        freelist_insert_pos = &gen2.*.size_classes[bin].free_list;

        // Visit each page.
        page = 0;
        while (page < gen2.*.size_classes[bin].num_pages) : (page += 1) {
            // Visit all the objects, looking for dead ones and reset the
            // mark for each of them.
            var cur_ptr: [*c]u8 = gen2.*.size_classes[bin].pages[page];
            const end_ptr: [*c]u8 = if (page + 1 == gen2.*.size_classes[bin].num_pages)
                gen2.*.size_classes[bin].alloc_pos
            else
                cur_ptr + obj_size *% c.MVM_GEN2_PAGE_ITEMS;
            while (@intFromPtr(cur_ptr) < @intFromPtr(end_ptr)) {
                const col: Col = @ptrCast(@alignCast(cur_ptr));

                // Is this already a free list slot? If so, it becomes the
                // new free list insert position.
                if (@intFromPtr(freelist_insert_pos.*) == @intFromPtr(cur_ptr)) {
                    freelist_insert_pos = @ptrCast(@alignCast(cur_ptr));
                }

                // Otherwise, it must be a collectable of some kind. Is it
                // live?
                else if (col.*.flags2 & c.MVM_CF_GEN2_LIVE != 0) {
                    // Yes; clear the mark.
                    col.*.flags2 &= ~@as(u8, c.MVM_CF_GEN2_LIVE);
                } else {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : collecting an object %p in the gen2\n", .{vp(col)});
                    // No, it's dead. Do any cleanup.
                    if (comptime c.MVM_GC_DEBUG != 0)
                        col.*.flags2 |= c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST;
                    if (col.*.flags1 & c.MVM_CF_TYPE_OBJECT != 0) {
                        if (comptime overflow_sci) {
                            if (col.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0)
                                c.MVM_free(col.*.sc_forward_u.sci);
                        }
                    } else if (col.*.flags1 & c.MVM_CF_STABLE != 0) {
                        if ((if (comptime overflow_sci) col.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED == 0 else true) and
                            col.*.sc_forward_u.sc.sc_idx == 0 and
                            col.*.sc_forward_u.sc.idx == @as(c_uint, @bitCast(@as(c_int, c.MVM_DIRECT_SC_IDX_SENTINEL))))
                        {
                            // We marked it dead last time, kill it.
                            c.MVM_6model_stable_gc_free(tc, @ptrCast(@alignCast(col)));
                        } else {
                            if (comptime overflow_sci) {
                                if (col.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0) {
                                    // Whatever happens next, we can free this
                                    // memory immediately, because no-one will be
                                    // serializing a dead STable.
                                    cAssert(!(col.*.sc_forward_u.sci.*.sc_idx == 0 and
                                        col.*.sc_forward_u.sci.*.idx == c.MVM_DIRECT_SC_IDX_SENTINEL));
                                    c.MVM_free(col.*.sc_forward_u.sci);
                                    col.*.flags1 &= ~@as(u8, c.MVM_CF_SERIALZATION_INDEX_ALLOCATED);
                                }
                            }
                            if (global_destruction != 0) {
                                // We're in global destruction, so enqueue to the end
                                // like we do in the nursery
                                enqueueStableForDeletion(tc, @ptrCast(@alignCast(col)));
                            } else {
                                // There will definitely be another gc run, so mark it as "died last time".
                                col.*.sc_forward_u.sc.sc_idx = 0;
                                col.*.sc_forward_u.sc.idx = @bitCast(@as(c_int, c.MVM_DIRECT_SC_IDX_SENTINEL));
                            }
                            // Skip the freelist updating.
                            cur_ptr += obj_size;
                            continue;
                        }
                    } else if (col.*.flags1 & c.MVM_CF_FRAME != 0) {
                        c.MVM_frame_destroy(tc, @ptrCast(@alignCast(col)));
                    } else {
                        // Object instance; call gc_free if needed.
                        const obj: Object = @ptrCast(@alignCast(col));
                        if (do_prof_log != 0) {
                            c.MVM_profiler_log_gc_deallocate(executing_thread, obj);
                        }
                        if (stableOf(obj) != null) {
                            if (reprOf(obj).*.gc_free) |gc_free|
                                gc_free(tc, obj);
                        }
                        if (comptime overflow_sci) {
                            if (col.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0)
                                c.MVM_free(col.*.sc_forward_u.sci);
                        }
                    }

                    // Chain in to the free list.
                    @as([*c][*c]u8, @ptrCast(@alignCast(cur_ptr))).* = @ptrCast(freelist_insert_pos.*);
                    freelist_insert_pos.* = @ptrCast(@alignCast(cur_ptr));

                    // Update the pointer to the insert position to point to us
                    freelist_insert_pos = @ptrCast(@alignCast(cur_ptr));
                    if (comptime c.MVM_GC_DEBUG != 0)
                        tc.*.gc_debug_gen2_freed_bytes +%= obj_size;
                }

                // Move to the next object.
                cur_ptr += obj_size;
            }
        }
    }

    // Also need to consider overflows.
    i = 0;
    while (i < gen2.*.num_overflows) : (i += 1) {
        if (gen2.*.overflows[i] != null) {
            const col: Col = gen2.*.overflows[i];
            if (col.*.flags2 & c.MVM_CF_GEN2_LIVE != 0) {
                // A living over-sized object; just clear the mark.
                col.*.flags2 &= ~@as(u8, c.MVM_CF_GEN2_LIVE);
            } else {
                // Dead over-sized object. We know if it's this big it cannot
                // be a type object or STable, so only need handle the simple
                // object case.
                if (col.*.flags1 & (c.MVM_CF_TYPE_OBJECT | c.MVM_CF_STABLE | c.MVM_CF_FRAME) == 0) {
                    const obj: Object = @ptrCast(@alignCast(col));
                    if (stableOf(obj) != null) {
                        if (reprOf(obj).*.gc_free) |gc_free|
                            gc_free(tc, obj);
                    }
                    if (comptime overflow_sci) {
                        if (col.*.flags1 & c.MVM_CF_SERIALZATION_INDEX_ALLOCATED != 0)
                            c.MVM_free(col.*.sc_forward_u.sci);
                    }
                } else {
                    c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: gen2 overflow contains non-object");
                }
                if (comptime c.MVM_GC_DEBUG != 0)
                    tc.*.gc_debug_gen2_freed_bytes +%= col.*.size;
                c.MVM_free(col);
                gen2.*.overflows[i] = null;
            }
        }
    }
    // And finally compact the overflow list
    c.MVM_gc_gen2_compact_overflows(gen2);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&newThreadNurserySize, .{ .name = "MVM_gc_new_thread_nursery_size", .visibility = visibility });
    @export(&collect, .{ .name = "MVM_gc_collect", .visibility = visibility });
    @export(&markCollectable, .{ .name = "MVM_gc_mark_collectable", .visibility = visibility });
    @export(&freeNurseryUncopied, .{ .name = "MVM_gc_collect_free_nursery_uncopied", .visibility = visibility });
    @export(&freeStables, .{ .name = "MVM_gc_collect_free_stables", .visibility = visibility });
    @export(&freeGen2Unmarked, .{ .name = "MVM_gc_collect_free_gen2_unmarked", .visibility = visibility });
}
