//! Zig port of src/gc/collect.c (lines 1-799): the collector proper. A run
//! swaps the nursery semi-spaces, adds the root sets in the C order and
//! drains the worklist, copying nursery objects to tospace on their first
//! survival and promoting them to gen2 on their second, marking gen2
//! objects on a full run, and passing items owned by other threads to their
//! in-trays; then the sweeps of the uncopied fromspace, of gen2 and of the
//! queued STables. No behaviour change. The worklist macros of
//! src/gc/worklist.h stay C for C callers; `MVM_gc_worklist_add` is
//! `moar.worklistAdd` and `MVM_gc_worklist_get` is `worklistGet` below. The
//! roots, gen2 and worklist ports are called as Zig; the object-id,
//! frame, STable, profiler and write-barrier calls go through `c.`. The
//! dispatch on what a collectable is (type object, STable, frame, object)
//! is a `switch` on `view.kind`, which keeps the C's flag precedence. Every
//! atomic site uses src/zig/gc/atomic.zig (or `moar.trycas` for
//! `MVM_trycas`) and names the C macro and line. `GCDEBUG_LOG` and the
//! `MVM_GC_DEBUG_ENABLED` blocks (src/gc/orchestrate.h:45-53) are kept as
//! comptime-guarded blocks: `MVM_GC_DEBUG_LOG_FLAGS` is 0, so, as in the C,
//! they compile to nothing. `#if MVM_GC_DEBUG` and
//! `#ifdef MVM_USE_OVERFLOW_SERIALIZATION_INDEX` are comptime branches on
//! the translated macros. The functions are Zig-typed; the `MVM_gc_collect*`
//! and `MVM_gc_mark_collectable` exports are thin C-ABI wrappers over them.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");
const allocation = @import("allocation.zig");
const view = @import("view.zig");
const worklist_mod = @import("worklist.zig");
const gen2_mod = @import("gen2.zig");
const roots = @import("roots.zig");

const Tc = view.Tc;
const Instance = view.Instance;
const Col = view.Col;
const ColSlot = view.ColSlot;
const Object = view.Object;
const STable = view.STable;
const Worklist = view.Worklist;
const Gen2 = view.Gen2;
const Thread = view.Thread;
const PassedWork = c.MVMGCPassedWork;

const worklistAdd = moar.worklistAdd;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.optimize == .debug) std.debug.assert(ok);
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
inline fn gcdebugLog(tc: Tc, msg: [*:0]const u8, args: anytype) void {
    // (int)MVM_load(&(tc)->instance->gc_seq_number) (orchestrate.h:53).
    const seq: c_int = @bitCast(@as(c_uint, @truncate(atomic.load(&tc.instance.*.gc_seq_number))));
    _ = @call(.auto, c.printf, .{ msg, @as(c_uint, tc.thread_id), seq } ++ args);
}

/// `(void *)p` for a `%p` argument.
inline fn vp(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}

/// The reprid of the debug logs: -1 for anything but an object
/// (collect.c:304, 316).
inline fn logReprId(col: Col) c_int {
    return if (view.kind(col) != .object) -1 else @bitCast(moar.repr(view.asObject(col)).ID);
}

/// `ptr[0..len]` of a C list field `ptr` with its count `len`, which the C
/// may hold as NULL with a zero count: slicing a NULL `[*c]` is not allowed.
inline fn list(ptr: anytype, len: usize) []@typeInfo(@TypeOf(ptr)).pointer.child {
    return if (len == 0) &.{} else ptr[0..len];
}

/// The bytes of a collectable, for the copies.
inline fn bytesOf(col: Col, size: usize) []u8 {
    return @as([*]u8, @ptrCast(col))[0..size];
}

/// MVM_gc_worklist_get(tc, worklist) (worklist.h:105-108): the top of the
/// list, or null when it is empty. A NULL entry also reads as null, which
/// ends the C's `while ((item_ptr = MVM_gc_worklist_get(...)))` loop too.
inline fn worklistGet(worklist: Worklist) ?ColSlot {
    if (worklist.items == 0) return null;
    worklist.items -= 1;
    return @ptrCast(worklist.list[worklist.items]);
}

/// `&tc->gc_in_tray`, the head of a thread's in-tray, as the volatile slot
/// the C declares (`MVMGCPassedWork * volatile *`, collect.c:418, 503).
inline fn inTray(tc: Tc) *volatile ?*PassedWork {
    return @ptrCast(&tc.gc_in_tray);
}

// ---- the C's enums (src/gc/collect.h) ---------------------------------------

/// What a run adds to the worklist (`MVMGCWhatToDo`, collect.h:24-36).
/// Non-exhaustive: the C compares the byte it is given against the
/// constants, so any other value runs as `all` does (a main run with the
/// instance roots); `_` keeps that instead of making it illegal.
pub const WhatToDo = enum(u8) {
    all = c.MVMGCWhatToDo_All,
    no_instance = c.MVMGCWhatToDo_NoInstance,
    in_tray = c.MVMGCWhatToDo_InTray,
    finalizing = c.MVMGCWhatToDo_Finalizing,
    _,
};

/// Which generations a run collects (`MVMGCGenerations`, collect.h:38-45).
/// Non-exhaustive for the same reason: the C tests `== Nursery`,
/// `!= Nursery` and `== Both`, so another value is neither.
pub const Generations = enum(u8) {
    nursery = c.MVMGCGenerations_Nursery,
    both = c.MVMGCGenerations_Both,
    _,
};

comptime {
    std.debug.assert(@backingInt(WhatToDo.all) == 0 and @backingInt(WhatToDo.no_instance) == 1);
    std.debug.assert(@backingInt(WhatToDo.in_tray) == 2 and @backingInt(WhatToDo.finalizing) == 4);
    std.debug.assert(@backingInt(Generations.nursery) == 0 and @backingInt(Generations.both) == 1);
}

// ---- work passing ----------------------------------------------------------

/// Combines a piece of work that will be passed to another thread with the
/// ID of the target thread to pass it to. (collect.c:3-8)
pub const ThreadWork = struct {
    target: u32,
    work: ?*PassedWork = null,
};

comptime {
    // The entry size of the C's array, which its realloc sizes count in.
    std.debug.assert(@sizeOf(ThreadWork) == @sizeOf(extern struct { target: u32, work: ?*PassedWork }));
}

/// Current chunks of work we're building up to pass. (collect.c:10-14) The
/// C's `num_target_threads`/`target_work` pair is the list's length and
/// items; it grows one entry at a time, so its capacity is its length and
/// each growth asks `MVM_malloc` for `num_target_threads *
/// sizeof(ThreadWork)` bytes, the C's realloc size.
pub const WorkToPass = struct {
    targets: std.ArrayList(ThreadWork) = .empty,
};

/// Adds a chunk of work to another thread's in-tray. (collect.c:416-447)
/// `pub` only for the in-tray test (collect_test.zig); not exported.
pub fn pushWorkToThreadInTray(tc: Tc, target: u32, work: *PassedWork) void {
    // Locate the thread to pass the work to.
    const target_tc: Tc = if (target == 1)
        // It's going to the main thread.
        tc.instance.*.main_thread
    else find: {
        // MVM_load(&tc->instance->threads) (collect.c:427).
        var t: Thread = atomic.load(&tc.instance.*.threads);
        while (true) {
            if (@as(?Tc, t.body.tc)) |ttc| {
                if (ttc.thread_id == target) break :find ttc;
            }
            t = @as(?Thread, t.body.next) orelse break;
        }
        c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: invalid thread ID %d in GC work pass", @as(c_uint, target));
    };

    // Pass the work, chaining any other in-tray entries for the thread
    // after us.
    const target_tray = inTray(target_tc);
    while (true) {
        const orig = target_tray.*;
        work.next = orig;
        // MVM_casptr(target_tray, orig, work) (collect.c:444).
        if (atomic.cas(target_tray, orig, work) == orig)
            return;
    }
}

/// Adds work to list of items to pass over to another thread, and if we
/// reach the pass threshold then does the passing. (collect.c:449-490)
/// `pub` only for the work-passing test (collect_test.zig).
pub fn passWorkItem(tc: Tc, wtp: *WorkToPass, item_ptr: ColSlot) void {
    const target: u32 = item_ptr.*.?.owner;

    // Find any existing thread work passing list for the target.
    if (target == 0)
        c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: zeroed target thread ID in work pass");
    const target_info: *ThreadWork = for (wtp.targets.items) |*tw| {
        if (tw.target == target) break tw;
    } else new: {
        // If there's no entry for this target, create one: the C's
        // MVM_realloc(target_work, num_target_threads * sizeof(ThreadWork))
        // (collect.c:468-470). MVM_malloc panics rather than failing.
        wtp.targets.ensureTotalCapacityPrecise(moar.mvm_allocator, wtp.targets.items.len + 1) catch unreachable;
        const tw = wtp.targets.addOneAssumeCapacity();
        tw.* = .{ .target = target };
        break :new tw;
    };

    // See if there's a currently active list; create it if not.
    const work: *PassedWork = target_info.work orelse new: {
        const w: *PassedWork = @ptrCast(@alignCast(c.MVM_calloc(1, @sizeOf(PassedWork))));
        target_info.work = w;
        break :new w;
    };

    // Add this item to the work list.
    work.items[work.num_items] = @ptrCast(item_ptr);
    work.num_items += 1;

    // If we've hit the limit, pass this work to the target thread.
    if (work.num_items == c.MVM_GC_PASS_WORK_SIZE) {
        pushWorkToThreadInTray(tc, target, work);
        target_info.work = null;
    }
}

/// Passes all work for other threads that we've got left in our to-pass
/// list. (collect.c:492-499)
fn passLeftoverWork(tc: Tc, wtp: *WorkToPass) void {
    for (wtp.targets.items) |tw| {
        if (tw.work) |work|
            pushWorkToThreadInTray(tc, tw.target, work);
    }
}

/// Takes work in a thread's in-tray, if any, and adds it to the worklist.
/// (collect.c:501-527)
fn addInTrayToWorklist(tc: Tc, worklist: Worklist) void {
    const in_tray = inTray(tc);

    // Get work to process.
    const taken: *PassedWork = while (true) {
        // See if there's anything in the in-tray; if not, we're done.
        const head = in_tray.* orelse return;

        // Otherwise, try to take it.
        // MVM_casptr(in_tray, head, NULL) (collect.c:514).
        if (atomic.cas(in_tray, head, null) == head)
            break head;
    };

    // Go through list, adding to worklist.
    var cur: ?*PassedWork = taken;
    while (cur) |head| {
        const next = head.next;
        for (head.items[0..head.num_items]) |item|
            worklistAdd(tc, worklist, item);
        c.MVM_free(head);
        cur = next;
    }
}

// ---- the run ---------------------------------------------------------------

/// The size of the nursery that a new thread should get. The main thread will
/// get a full-size one right away. (collect.c:22-30)
pub fn newThreadNurserySize(i: Instance) u32 {
    return if (i.main_thread != null)
        @min(c.MVM_NURSERY_SIZE, c.MVM_NURSERY_THREAD_START)
    else
        c.MVM_NURSERY_SIZE;
}

/// One phase of a run: the C's `GCDEBUG_LOG(..., "processing %d items
/// from ...")` (`msg`) then `process_worklist`.
inline fn drain(tc: Tc, worklist: Worklist, wtp: *WorkToPass, gen: Generations, comptime msg: [*:0]const u8) void {
    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, msg, .{@as(c_uint, worklist.items)});
    processWorklist(tc, worklist, wtp, gen);
}

/// Does a garbage collection run. Exactly what it does is configured by the
/// couple of arguments that it takes: what_to_do says where to look for
/// things to add to the worklist (everywhere, just thread local stuff, or
/// just the in-tray), gen whether to collect the nursery or both
/// generations. The roots are added and processed in phases, to try to
/// avoid building up a huge worklist. (collect.c:32-161)
pub fn collect(tc: Tc, what_to_do: WhatToDo, gen: Generations) void {
    // Create a GC worklist.
    const worklist = worklist_mod.create(tc, gen != .nursery);

    // Initialize work passing data structure.
    var wtp: WorkToPass = .{};

    // See what we need to work on this time.
    switch (what_to_do) {
        .in_tray => {
            // We just need to process anything in the in-tray.
            addInTrayToWorklist(tc, worklist);
            drain(tc, worklist, &wtp, gen, "Thread %d run %d : processing %d items from in tray \n");
        },
        .finalizing => {
            // Need to process the finalizing queue.
            for (list(tc.finalizing, tc.num_finalizing)) |*obj|
                worklistAdd(tc, worklist, obj);
            drain(tc, worklist, &wtp, gen, "Thread %d run %d : processing %d items from finalizing \n");
        },
        else => mainRun(tc, worklist, &wtp, what_to_do, gen),
    }

    // Destroy the worklist.
    worklist_mod.destroy(worklist);

    // Pass any work for other threads we accumulated but that didn't trigger
    // the work passing threshold, then cleanup work passing list.
    if (wtp.targets.items.len != 0) {
        passLeftoverWork(tc, &wtp);
        wtp.targets.deinit(moar.mvm_allocator);
    }
}

/// The main collection run of `collect` (collect.c:76-150).
inline fn mainRun(tc: Tc, worklist: Worklist, wtp: *WorkToPass, what_to_do: WhatToDo, gen: Generations) void {
    // Main collection run. The current tospace becomes fromspace, with
    // the size of the current tospace becoming stashed as the size of
    // that fromspace.
    const old_fromspace = tc.nursery_fromspace;
    const old_fromspace_size = tc.nursery_fromspace_size;
    tc.nursery_fromspace = tc.nursery_tospace;
    tc.nursery_fromspace_size = tc.nursery_tospace_size;

    // Decide on this threads's tospace size. If fromspace was already at
    // the maximum nursery size, then that is the new tospace size. If
    // not, then see if this thread caused the current GC run, and grant
    // it a bigger tospace. Otherwise, new tospace size is left as the
    // last tospace size.
    if (tc.nursery_tospace_size < c.MVM_NURSERY_SIZE) {
        if (tc.instance.*.thread_to_blame_for_gc == tc)
            tc.nursery_tospace_size *%= 2;
    }

    // If the old fromspace matches the target size, just re-use it. If
    // not, free it and allocate a new tospace.
    if (old_fromspace_size == tc.nursery_tospace_size) {
        tc.nursery_tospace = old_fromspace;
    } else {
        c.MVM_free(old_fromspace);
        tc.nursery_tospace = c.MVM_calloc(1, tc.nursery_tospace_size);
    }

    // Reset nursery allocation pointers to the new tospace.
    const tospace: [*]u8 = @ptrCast(tc.nursery_tospace.?);
    tc.nursery_alloc = tospace;
    tc.nursery_alloc_limit = tospace + tc.nursery_tospace_size;

    // Add permanent roots and process them; only one thread will do
    // this, since they are instance-wide.
    if (what_to_do != .no_instance) {
        roots.addPermanentsToWorklist(tc, worklist, null);
        drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from instance permanents\n");
        roots.addInstanceRootsToWorklist(tc, worklist, null);
        drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from instance roots\n");
    }

    // Add per-thread state to worklist and process it.
    roots.addTcRootsToWorklist(tc, worklist, null);
    drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from TC objects\n");

    // Add temporary roots and process them (these are per-thread).
    roots.addTempsToWorklist(tc, worklist, null);
    drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from thread temps\n");

    // Add things that are roots for the first generation because they are
    // pointed to by objects in the second generation and process them
    // (also per-thread). Note we need not do this if we're doing a full
    // collection anyway (in fact, we must not for correctness, otherwise
    // the gen2 rooting keeps them alive forever).
    if (gen == .nursery) {
        roots.addGen2sToWorklist(tc, worklist);
        drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from gen2 \n");
    }

    // Process anything in the in-tray.
    addInTrayToWorklist(tc, worklist);
    drain(tc, worklist, wtp, gen, "Thread %d run %d : processing %d items from in tray \n");

    // At this point, we have probably done most of the work we will
    // need to (only get more if another thread passes us more); zero
    // out the remaining tospace.
    const rest: [*]u8 = @ptrCast(tc.nursery_alloc.?);
    @memset(rest[0 .. @intFromPtr(tc.nursery_alloc_limit) - @intFromPtr(rest)], 0);
}

/// Processes the current worklist. (collect.c:163-346)
fn processWorklist(tc: Tc, worklist: Worklist, wtp: *WorkToPass, gen: Generations) void {
    // Grab the second generation allocator; we may move items into the
    // old generation.
    const gen2: Gen2 = tc.gen2;

    while (worklistGet(worklist)) |item_ptr| {
        // Dereference the object we're considering. If the item is NULL,
        // that's fine - it's just a null reference and thus we've no object
        // to consider.
        const item: Col = item_ptr.* orelse continue;

        // If it's in the second generation and we're only doing a nursery,
        // collection, we have nothing to do.
        const item_gen2 = view.flags2(item).second_gen;
        if (item_gen2) {
            if (gen == .nursery)
                continue;
            if (view.flags2(item).gen2_live) {
                // gen2 and marked as live.
                continue;
            }
        } else if (view.flags2(item).forwarder_valid) {
            // If the item was already seen and copied, then it will have a
            // forwarding address already. Just update this pointer to the
            // new address and we're done.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (item_ptr.* != @as(?Col, item.sc_forward_u.forwarder)) {
                    gcdebugLog(tc, "Thread %d run %d : updating handle %p from %p to forwarder %p\n", .{ vp(item_ptr), vp(item), vp(item.sc_forward_u.forwarder) });
                } else {
                    gcdebugLog(tc, "Thread %d run %d : already visited handle %p to forwarder %p\n", .{ vp(item_ptr), vp(item.sc_forward_u.forwarder) });
                }
            }
            // MVM_barrier() (collect.c:207).
            atomic.fence();
            item_ptr.* = item.sc_forward_u.forwarder;
            continue;
        } else {
            // If the pointer is already into tospace (the bit we've already
            // copied into), we already updated it, so we're done.
            if (@intFromPtr(item) >= @intFromPtr(tc.nursery_tospace) and @intFromPtr(item) < @intFromPtr(tc.nursery_alloc)) {
                continue;
            }
        }

        // If it's owned by a different thread, we need to pass it over to
        // the owning thread.
        if (item.owner != tc.thread_id) {
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : sending a handle %p to object %p to thread %d\n", .{ vp(item_ptr), vp(item), @as(c_uint, item.owner) });
            passWorkItem(tc, wtp, item_ptr);
            continue;
        }

        // If it's in to-space but *ahead* of our copy offset then it's an
        // out-of-date pointer and we have some kind of corruption.
        if (@intFromPtr(item) >= @intFromPtr(tc.nursery_alloc) and @intFromPtr(item) < @intFromPtr(tc.nursery_alloc_limit))
            c.MVM_panic(1, "Heap corruption detected: pointer %p to past fromspace", vp(item));

        // At this point, we didn't already see the object, which means we
        // need to take some action. Go on the generation...
        const new_addr: Col, const to_gen2: bool = if (item_gen2) marked: {
            cAssert(!view.flags2(item).forwarder_valid);
            // It's in the second generation. We'll just mark it.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                gcdebugLog(tc, "Thread %d run %d : handle %p was already %p\n", .{ vp(item_ptr), vp(item) });
            }
            view.flags2(item).gen2_live = true;
            cAssert(item_ptr.* == item);
            break :marked .{ item, false };
        } else moved: {
            // Catch NULL stable (always sign of trouble) in debug mode.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (view.asObject(item).st == null)
                    gcdebugLog(tc, "Thread %d run %d : found a zeroed handle %p to object %p\n", .{ vp(item_ptr), vp(item) });
            }

            // Did we see it in the nursery before, or should we move it to
            // gen2 anyway since either:
            //   * A persistent ID was requested?
            //   * It is referenced by a gen2 aggregate
            const promote = view.flags1(item).has_object_id or
                view.flags2(item).nursery_seen or view.flags2(item).ref_from_gen2;
            const copy: Col = if (promote) promoted: {
                // Yes; we should move it to the second generation. Allocate
                // space in the second generation.
                const to: Col = view.asCol(if (view.flags1(item).has_object_id)
                    c.MVM_gc_object_id_use_allocation(tc, item).?
                else
                    gen2_mod.allocate(gen2, item.size));

                // Add on to the promoted amount (used both to decide when to do
                // the next full collection, as well as for profiling). Note we
                // add unmanaged size on for objects below.
                tc.gc_promoted_bytes +%= item.size;

                // Copy the object to the second generation and mark it as
                // living there.
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : copying an object %p of size %d to gen2 %p\n", .{ vp(item), @as(c_int, item.size), vp(to) });
                @memcpy(bytesOf(to, item.size), bytesOf(item, item.size));
                if (view.flags2(to).nursery_seen)
                    view.flags2(to).nursery_seen = false;
                view.flags2(to).second_gen = true;

                // If it's a frame with an active work area, we need to keep
                // on visiting it. Also add on object's unmanaged size.
                if (view.flags1(to).frame) {
                    if (view.asFrame(to).work != null)
                        roots.gen2Add(tc, to);
                } else if (!view.flags1(to).type_object and !view.flags1(to).stable) {
                    const new_obj_addr = view.asObject(to);
                    if (moar.repr(new_obj_addr).unmanaged_size) |unmanaged_size_fn| {
                        const unmanaged_size: u64 = unmanaged_size_fn(tc, new_obj_addr.st, moar.objectBody(new_obj_addr));
                        // MVMuint32 += MVMuint64: the C truncates the sum.
                        tc.gc_promoted_bytes = @truncate(@as(u64, tc.gc_promoted_bytes) +% unmanaged_size);
                        if (tc.instance.*.profiling != 0)
                            c.MVM_profiler_log_unmanaged_data_promoted(tc, unmanaged_size);
                    }
                }

                // If we're going to sweep the second generation, also need
                // to mark it as live.
                if (gen == .both)
                    view.flags2(to).gen2_live = true;
                break :promoted to;
            } else copied: {
                // No, so it will live in the nursery for another GC
                // iteration. Allocate space in the nursery.
                const alloc: [*]u8 = @ptrCast(tc.nursery_alloc.?);
                const to = view.asCol(alloc);
                tc.nursery_alloc = alloc + allocation.alignSize(item.size);
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : copying an object %p (reprid %d) of size %d to tospace %p\n", .{ vp(item), logReprId(item), @as(c_int, item.size), vp(to) });

                // Copy the object to tospace and mark it as seen in the
                // nursery (so the next time around it will move to the
                // older generation, if it survives).
                @memcpy(bytesOf(to, item.size), bytesOf(item, item.size));
                view.flags2(to).nursery_seen = true;
                break :copied to;
            };

            // Store the forwarding pointer and update the original
            // reference.
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (copy != item)
                    gcdebugLog(tc, "Thread %d run %d : updating handle %p from referent %p (reprid %d) to %p\n", .{ vp(item_ptr), vp(item), logReprId(item), vp(copy) });
            }
            item_ptr.* = copy;
            item.sc_forward_u.forwarder = copy;
            // MVM_barrier() (collect.c:320).
            atomic.fence();
            // Set the flag on the copy of item *in fromspace* to mark that the
            // forwarder pointer is valid.
            view.flags2(item).forwarder_valid = true;
            break :moved .{ copy, promote };
        };

        // Finally, we need to mark the collectable (at its moved address).
        // Track how many items we had before we mark it, in case we need
        // to write barrier them post-move to uphold the generational
        // invariant.
        const gen2count = worklist.items;
        markCollectable(tc, worklist, new_addr);

        // In moving an object to generation 2, we may have left it pointing
        // to nursery objects. If so, make sure it's in the gen2 roots.
        if (to_gen2) {
            for (worklist.list[gen2count..worklist.items]) |entry| {
                const j: ColSlot = @ptrCast(entry);
                if (j.*) |referenced|
                    c.MVM_gc_write_barrier_no_update_referenced(tc, new_addr, referenced);
            }
        }
    }
}

/// Marks a collectable item (object, type object, STable). (collect.c:348-414)
pub fn markCollectable(tc: Tc, worklist: Worklist, col: Col) void {
    cAssert(!view.flags2(col).forwarder_valid);
    // assert(REPR(new_addr)); is commented out in the C (collect.c:354).
    const sc_idx: u32 = c.MVM_sc_get_idx_of_sc(col);
    if (sc_idx > 0) {
        if (comptime c.MVM_GC_DEBUG != 0) {
            if (sc_idx >= tc.instance.*.all_scs_next_idx)
                c.MVM_panic(1, "SC index out of range");
        }
        worklistAdd(tc, worklist, &tc.instance.*.all_scs[sc_idx].*.sc);
    }

    switch (view.kind(col)) {
        .type_object => {
            // Add the STable to the worklist.
            worklistAdd(tc, worklist, &view.asObject(col).st);
        },
        .stable => {
            // Add all references in the STable to the work list.
            const st = view.asStable(col);
            for (list(st.type_check_cache, st.type_check_cache_length)) |*entry|
                worklistAdd(tc, worklist, entry);
            if (@as(?*const c.MVMContainerSpec, st.container_spec)) |spec| {
                if (spec.gc_mark_data) |gc_mark_data|
                    gc_mark_data(tc, st, worklist);
            }
            if (@as(?*c.MVMBoolificationSpec, st.boolification_spec)) |spec|
                worklistAdd(tc, worklist, &spec.method);
            worklistAdd(tc, worklist, &st.WHO);
            worklistAdd(tc, worklist, &st.WHAT);
            worklistAdd(tc, worklist, &st.HOW);
            worklistAdd(tc, worklist, &st.HOW_sc);
            if (st.mode_flags & c.MVM_PARAMETRIC_TYPE != 0) {
                worklistAdd(tc, worklist, &st.paramet.ric.parameterizer);
                worklistAdd(tc, worklist, &st.paramet.ric.lookup);
            } else if (st.mode_flags & c.MVM_PARAMETERIZED_TYPE != 0) {
                worklistAdd(tc, worklist, &st.paramet.erized.parametric_type);
                worklistAdd(tc, worklist, &st.paramet.erized.parameters);
            }

            // If it needs to have its REPR data marked, do that.
            if (st.REPR.*.gc_mark_repr_data) |gc_mark_repr_data|
                gc_mark_repr_data(tc, st, worklist);
        },
        .frame => roots.addFrameRootsToWorklist(tc, worklist, view.asFrame(col)),
        .object => {
            // Need to view it as an object in here.
            const obj = view.asObject(col);

            // Add the STable to the worklist.
            worklistAdd(tc, worklist, &obj.st);

            // If needed, mark it. This will add addresses to the worklist
            // that will need updating. Note that we are passing the address
            // of the object *after* copying it since those are the addresses
            // we care about updating; the old chunk of memory is now dead!
            if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) {
                if (obj.st == null)
                    c.MVM_panic(c.MVM_exitcode_gcnursery, "Found an outdated reference to address %p", vp(col));
            }
            if (moar.repr(obj).gc_mark) |gc_mark|
                gc_mark(tc, obj.st, moar.objectBody(obj), worklist);
        },
    }
}

// ---- the sweeps ------------------------------------------------------------

/// Save dead STable pointers to delete later.. (collect.c:529-539)
fn enqueueStableForDeletion(tc: Tc, st: STable) void {
    if (comptime overflow_sci)
        cAssert(!view.flags1(&st.header).serialization_index_allocated);
    const head = &tc.instance.*.stables_to_free;
    while (true) {
        const old_head = head.*;
        st.header.sc_forward_u.st = old_head;
        // MVM_trycas(&tc->instance->stables_to_free, old_head, st) (collect.c:538).
        if (moar.trycas(head, old_head, st)) break;
    }
}

/// Some objects, having been copied, need no further attention. Others
/// need to do some additional freeing, however. This goes through the
/// fromspace and does any needed work to free uncopied things (this may
/// run in parallel with the mutator, which will be operating on tospace).
/// (collect.c:541-614)
pub fn freeNurseryUncopied(executing: Tc, tc: Tc, limit: [*]u8) void {
    // We start scanning the fromspace, and keep going until we hit
    // the end of the area allocated in it: `fromspace[0..used]`, empty
    // when the limit is not above it, as the C's `while (scan < limit)`.
    const from = @intFromPtr(tc.nursery_fromspace);
    const used = if (@intFromPtr(limit) > from) @intFromPtr(limit) - from else 0;
    const space: []u8 = if (used == 0) &.{} else @as([*]u8, @ptrCast(tc.nursery_fromspace.?))[0..used];

    const do_prof_log = executing.prof_data != null;

    var scan: usize = 0;
    while (scan < space.len) {
        // The object here is dead if it never got a forwarding pointer
        // written in to it.
        const item = view.asCol(space[scan..].ptr);
        const dead = !view.flags2(item).forwarder_valid;

        if (!dead)
            cAssert(item.sc_forward_u.forwarder != null);

        // Now go by collectable type.
        switch (view.kind(item)) {
            .type_object => {
                // Type object
                if (comptime overflow_sci) {
                    if (dead and view.flags1(item).serialization_index_allocated)
                        c.MVM_free(item.sc_forward_u.sci);
                }
                if (dead and view.flags1(item).has_object_id)
                    c.MVM_gc_object_id_clear(tc, item);
            },
            .stable => {
                const st = view.asStable(item);
                if (dead) {
                    // (The C's GCDEBUG_LOG here is commented out, collect.c:577.)
                    if (comptime overflow_sci) {
                        if (view.flags1(item).serialization_index_allocated) {
                            c.MVM_free(item.sc_forward_u.sci);
                            // Arguably we don't need to do this, if we're always
                            // consistent about what we put on the stable queue.
                            view.flags1(item).serialization_index_allocated = false;
                        }
                    }
                    enqueueStableForDeletion(tc, st);
                }
            },
            .frame => {
                if (dead)
                    c.MVM_frame_destroy(tc, view.asFrame(item));
            },
            .object => {
                // Object instance. If dead, call gc_free if needed. Scan is
                // incremented by object size.
                const obj = view.asObject(item);
                if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : collecting an object %p in the nursery with reprid %d\n", .{ vp(item), @as(c_uint, moar.repr(obj).ID) });
                if (dead) {
                    if (moar.repr(obj).gc_free) |gc_free|
                        gc_free(tc, obj);
                }
                if (dead and do_prof_log) {
                    c.MVM_profiler_log_gc_deallocate(executing, obj);
                }
                if (comptime overflow_sci) {
                    if (dead and view.flags1(item).serialization_index_allocated)
                        c.MVM_free(item.sc_forward_u.sci);
                }
                if (dead and view.flags1(item).has_object_id)
                    c.MVM_gc_object_id_clear(tc, item);
            },
        }

        // Go to the next item.
        scan += allocation.alignSize(item.size);
    }
}

/// Free STables (in any thread/generation!) queued to be freed.
/// (collect.c:616-631)
pub fn freeStables(tc: Tc) void {
    if (comptime c.MVM_GC_DEBUG < 3) {
        var st: ?STable = tc.instance.*.stables_to_free;
        while (st) |st_to_free| {
            st = st_to_free.header.sc_forward_u.st;
            st_to_free.header.sc_forward_u.st = null;
            c.MVM_6model_stable_gc_free(tc, st_to_free);
            if (comptime c.MVM_GC_DEBUG != 0)
                tc.gc_debug_stables_freed +%= 1;
        }
    }
    tc.instance.*.stables_to_free = null;
}

/// The first word of a gen2 slot or a bin's `free_list` field, as the
/// free-list link it holds (gen2.zig's threading; the C's `char ***`).
inline fn freeLink(word: anytype) *?*gen2_mod.FreeNode {
    return &@as(*gen2_mod.FreeNode, @ptrCast(@alignCast(word))).next;
}

/// Goes through the unmarked objects in the second generation heap and builds
/// free lists out of them. Also does any required finalization.
/// (collect.c:633-799)
pub fn freeGen2Unmarked(executing: Tc, tc: Tc, global_destruction: bool) void {
    // Visit each of the size class bins.
    const gen2: Gen2 = tc.gen2;
    const do_prof_log = executing.prof_data != null;

    for (gen2.size_classes[0..c.MVM_GEN2_BINS], 0..) |*sc, bin| {
        // If we've nothing allocated in this size class, skip it.
        if (sc.pages == null)
            continue;

        // Calculate object size for this bin.
        const obj_size: u32 = (@as(u32, @intCast(bin)) + 1) << c.MVM_GEN2_BIN_BITS;

        // freelist_insert_pos is a pointer to a memory location that
        // stores the address of the last traversed free list node (char **).
        // Initialize freelist insertion position to free list head.
        var freelist_insert_pos = freeLink(&sc.free_list);

        // Visit each page.
        var page: u32 = 0;
        while (page < sc.num_pages) : (page += 1) {
            // Visit all the objects, looking for dead ones and reset the
            // mark for each of them.
            var slots = gen2_mod.pageItems(sc, page, obj_size);
            slot: while (slots.next()) |cur_ptr| {
                const col = view.asCol(cur_ptr);

                // Is this already a free list slot? If so, it becomes the
                // new free list insert position.
                if (@intFromPtr(freelist_insert_pos.*) == @intFromPtr(cur_ptr)) {
                    freelist_insert_pos = freeLink(cur_ptr);
                }

                // Otherwise, it must be a collectable of some kind. Is it
                // live?
                else if (view.flags2(col).gen2_live) {
                    // Yes; clear the mark.
                    view.flags2(col).gen2_live = false;
                } else {
                    if (comptime gcDebugEnabled(c.MVM_GC_DEBUG_COLLECT)) gcdebugLog(tc, "Thread %d run %d : collecting an object %p in the gen2\n", .{vp(col)});
                    // No, it's dead. Do any cleanup.
                    if (comptime c.MVM_GC_DEBUG != 0)
                        view.flags2(col).debug_in_gen2_free_list = true;
                    switch (view.kind(col)) {
                        .type_object => {
                            if (comptime overflow_sci) {
                                if (view.flags1(col).serialization_index_allocated)
                                    c.MVM_free(col.sc_forward_u.sci);
                            }
                        },
                        .stable => {
                            if ((if (comptime overflow_sci) !view.flags1(col).serialization_index_allocated else true) and
                                col.sc_forward_u.sc.sc_idx == 0 and
                                col.sc_forward_u.sc.idx == @as(c_uint, @bitCast(@as(c_int, c.MVM_DIRECT_SC_IDX_SENTINEL))))
                            {
                                // We marked it dead last time, kill it.
                                c.MVM_6model_stable_gc_free(tc, view.asStable(col));
                            } else {
                                if (comptime overflow_sci) {
                                    if (view.flags1(col).serialization_index_allocated) {
                                        // Whatever happens next, we can free this
                                        // memory immediately, because no-one will be
                                        // serializing a dead STable.
                                        cAssert(!(col.sc_forward_u.sci.*.sc_idx == 0 and
                                            col.sc_forward_u.sci.*.idx == c.MVM_DIRECT_SC_IDX_SENTINEL));
                                        c.MVM_free(col.sc_forward_u.sci);
                                        view.flags1(col).serialization_index_allocated = false;
                                    }
                                }
                                if (global_destruction) {
                                    // We're in global destruction, so enqueue to the end
                                    // like we do in the nursery
                                    enqueueStableForDeletion(tc, view.asStable(col));
                                } else {
                                    // There will definitely be another gc run, so mark it as "died last time".
                                    col.sc_forward_u.sc.sc_idx = 0;
                                    col.sc_forward_u.sc.idx = @bitCast(@as(c_int, c.MVM_DIRECT_SC_IDX_SENTINEL));
                                }
                                // Skip the freelist updating.
                                continue :slot;
                            }
                        },
                        .frame => c.MVM_frame_destroy(tc, view.asFrame(col)),
                        .object => {
                            // Object instance; call gc_free if needed.
                            const obj = view.asObject(col);
                            if (do_prof_log) {
                                c.MVM_profiler_log_gc_deallocate(executing, obj);
                            }
                            if (@as(?STable, obj.st)) |st| {
                                if (st.REPR.*.gc_free) |gc_free|
                                    gc_free(tc, obj);
                            }
                            if (comptime overflow_sci) {
                                if (view.flags1(col).serialization_index_allocated)
                                    c.MVM_free(col.sc_forward_u.sci);
                            }
                        },
                    }

                    // Chain in to the free list.
                    const link = freeLink(cur_ptr);
                    link.* = freelist_insert_pos.*;
                    freelist_insert_pos.* = @ptrCast(@alignCast(cur_ptr));

                    // Update the pointer to the insert position to point to us
                    freelist_insert_pos = link;
                    if (comptime c.MVM_GC_DEBUG != 0)
                        tc.gc_debug_gen2_freed_bytes +%= obj_size;
                }
            }
        }
    }

    // Also need to consider overflows.
    for (list(gen2.overflows, gen2.num_overflows)) |*overflow| {
        const col: Col = overflow.* orelse continue;
        if (view.flags2(col).gen2_live) {
            // A living over-sized object; just clear the mark.
            view.flags2(col).gen2_live = false;
        } else {
            // Dead over-sized object. We know if it's this big it cannot
            // be a type object or STable, so only need handle the simple
            // object case.
            if (view.kind(col) == .object) {
                const obj = view.asObject(col);
                if (@as(?STable, obj.st)) |st| {
                    if (st.REPR.*.gc_free) |gc_free|
                        gc_free(tc, obj);
                }
                if (comptime overflow_sci) {
                    if (view.flags1(col).serialization_index_allocated)
                        c.MVM_free(col.sc_forward_u.sci);
                }
            } else {
                c.MVM_panic(c.MVM_exitcode_gcnursery, "Internal error: gen2 overflow contains non-object");
            }
            if (comptime c.MVM_GC_DEBUG != 0)
                tc.gc_debug_gen2_freed_bytes +%= col.size;
            c.MVM_free(col);
            overflow.* = null;
        }
    }
    // And finally compact the overflow list
    gen2_mod.compactOverflows(gen2);
}

// ---- the C ABI -------------------------------------------------------------

fn newThreadNurserySizeExport(i: [*c]c.MVMInstance) callconv(.c) c.MVMuint32 {
    return newThreadNurserySize(i);
}

fn collectExport(tc: [*c]c.MVMThreadContext, what_to_do: c.MVMuint8, gen: c.MVMuint8) callconv(.c) void {
    // Both enums are non-exhaustive, so any byte converts and compares as
    // the C compares it.
    collect(tc, @fromBackingInt(@intCast(what_to_do)), @fromBackingInt(@intCast(gen)));
}

fn markCollectableExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, new_addr: [*c]c.MVMCollectable) callconv(.c) void {
    markCollectable(tc, worklist, new_addr);
}

fn freeNurseryUncopiedExport(executing_thread: [*c]c.MVMThreadContext, tc: [*c]c.MVMThreadContext, limit: ?*anyopaque) callconv(.c) void {
    // A NULL limit is below any fromspace: the C's scan does nothing.
    freeNurseryUncopied(executing_thread, tc, @ptrCast(limit orelse return));
}

fn freeStablesExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    freeStables(tc);
}

fn freeGen2UnmarkedExport(executing_thread: [*c]c.MVMThreadContext, tc: [*c]c.MVMThreadContext, global_destruction: c.MVMint32) callconv(.c) void {
    freeGen2Unmarked(executing_thread, tc, global_destruction != 0);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&newThreadNurserySizeExport, .{ .name = "MVM_gc_new_thread_nursery_size", .visibility = visibility });
    @export(&collectExport, .{ .name = "MVM_gc_collect", .visibility = visibility });
    @export(&markCollectableExport, .{ .name = "MVM_gc_mark_collectable", .visibility = visibility });
    @export(&freeNurseryUncopiedExport, .{ .name = "MVM_gc_collect_free_nursery_uncopied", .visibility = visibility });
    @export(&freeStablesExport, .{ .name = "MVM_gc_collect_free_stables", .visibility = visibility });
    @export(&freeGen2UnmarkedExport, .{ .name = "MVM_gc_collect_free_gen2_unmarked", .visibility = visibility });
}
