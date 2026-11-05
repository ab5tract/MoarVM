//! Zig port of src/gc/roots.c (lines 1-477): the permanent, instance,
//! thread-context, temporary, inter-generational (gen2) and frame root
//! sets, added to a GC worklist or, when the worklist is NULL, described to
//! a heap snapshot. Faithful port; no behaviour change. The instance and tc
//! root walks add their roots in the C order, which fixes the marking order
//! and therefore the to-space layout. The inline temp-root push/pop and the
//! MVMROOT* macros stay in src/gc/roots.h; the slow push, the root arrays
//! and their growth are here, allocated through `MVM_realloc` as in the C.
//! `MVM_gc_worklist_add` is `moar.worklistAdd`; the `MVM_str_hash_*`
//! iteration goes through `c.` (the Zig hash engine's exports).
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;
const Worklist = [*c]c.MVMGCWorklist;
const Snapshot = [*c]c.MVMHeapSnapshotState;
const Collectable = c.MVMCollectable;
const Frame = [*c]c.MVMFrame;

const worklistAdd = moar.worklistAdd;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.mode == .Debug) std.debug.assert(ok);
}

/// MVM_FRAME_IS_ON_CALLSTACK as a bool.
inline fn onCallstack(tc: Tc, frame: Frame) bool {
    return c.MVM_FRAME_IS_ON_CALLSTACK(tc, frame) != 0;
}

/// Adds a location holding a collectable object to the permanent list of GC
/// roots, so that it will always be marked and never die. Note that the
/// address of the collectable must be passed, since it will need to be
/// updated. (roots.c:7-28)
pub fn addPermanentDesc(tc: Tc, obj_ref: [*c][*c]Collectable, description: [*c]const u8) callconv(.c) void {
    if (obj_ref == null)
        c.MVM_panic(c.MVM_exitcode_gcroots, "Illegal attempt to add null object address as a permanent root");

    const instance = tc.*.instance;
    c.uv_mutex_lock(&instance.*.mutex_permroots);
    // Allocate extra permanent root space if needed.
    if (instance.*.num_permroots == instance.*.alloc_permroots) {
        instance.*.alloc_permroots *%= 2;
        instance.*.permroots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(instance.*.permroots), @sizeOf([*c][*c]Collectable) * @as(usize, instance.*.alloc_permroots))));
        instance.*.permroot_descriptions = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(instance.*.permroot_descriptions), @sizeOf([*c]const u8) * @as(usize, instance.*.alloc_permroots))));
    }

    // Add this one to the list.
    instance.*.permroots[instance.*.num_permroots] = obj_ref;
    instance.*.permroot_descriptions[instance.*.num_permroots] = description;
    instance.*.num_permroots +%= 1;

    c.uv_mutex_unlock(&instance.*.mutex_permroots);
}

/// (roots.c:30-32)
pub fn addPermanent(tc: Tc, obj_ref: [*c][*c]Collectable) callconv(.c) void {
    addPermanentDesc(tc, obj_ref, "<??>");
}

/// Adds the set of permanently registered roots to a GC worklist.
/// (roots.c:35-50)
pub fn addPermanentsToWorklist(tc: Tc, worklist: Worklist, snapshot: Snapshot) callconv(.c) void {
    var i: c.MVMuint32 = 0;
    const num_roots: c.MVMuint32 = tc.*.instance.*.num_permroots;
    const permroots = tc.*.instance.*.permroots;
    if (worklist != null) {
        while (i < num_roots) : (i += 1)
            worklistAdd(tc, worklist, permroots[i]);
    } else {
        const permroot_descriptions = tc.*.instance.*.permroot_descriptions;
        while (i < num_roots) : (i += 1)
            c.MVM_profile_heap_add_collectable_rel_const_cstr(tc, snapshot, permroots[i].*, permroot_descriptions[i]);
    }
}

/// The add_collectable macro (roots.c:52-63): adds to the GC worklist if
/// there is one, otherwise describes the collectable to the heap snapshot.
/// `slot` is the address of the collectable pointer (the C's `&(col)`).
inline fn addCollectable(tc: Tc, worklist: Worklist, snapshot: Snapshot, slot: anytype, desc: [*c]const u8) void {
    if (worklist != null) {
        worklistAdd(tc, worklist, slot);
    } else {
        c.MVM_profile_heap_add_collectable_rel_const_cstr(tc, snapshot, @ptrCast(@alignCast(slot.*)), desc);
    }
}

/// Adds anything that is a root thanks to being referenced by instance,
/// but that isn't permanent. (roots.c:67-149)
pub fn addInstanceRootsToWorklist(tc: Tc, worklist: Worklist, snapshot: Snapshot) callconv(.c) void {
    const instance = tc.*.instance;

    addCollectable(tc, worklist, snapshot, &instance.*.threads, "Thread list");
    addCollectable(tc, worklist, snapshot, &instance.*.compiler_registry, "Compiler registry");
    addCollectable(tc, worklist, snapshot, &instance.*.hll_syms, "HLL symbols");
    addCollectable(tc, worklist, snapshot, &instance.*.clargs, "Command line args");

    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_thread, "Event loop thread");
    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_todo_queue, "Event loop todo queue");
    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_permit_queue, "Event loop permit queue");
    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_cancel_queue, "Event loop cancel queue");
    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_active, "Event loop active task list");
    addCollectable(tc, worklist, snapshot, &instance.*.event_loop_free_indices, "Event loop active free indices list");

    addCollectable(tc, worklist, snapshot, &instance.*.spesh_thread, "Specialization thread");
    addCollectable(tc, worklist, snapshot, &instance.*.spesh_queue, "Specialization log queue");

    if (worklist != null)
        c.MVM_spesh_plan_gc_mark(tc, instance.*.spesh_plan, worklist);

    const int_to_str_cache = instance.*.int_to_str_cache;
    var i: c.MVMuint32 = 0;
    while (i < c.MVM_INT_TO_STR_CACHE_SIZE) : (i += 1)
        addCollectable(tc, worklist, snapshot, &int_to_str_cache[i], "Integer to string cache entry");

    // okay, so this makes the weak hash slightly less weak.. for certain
    // keys of it anyway...
    const weakhash: [*c]c.MVMStrHashTable = &instance.*.sc_weakhash;
    var iterator = c.MVM_str_hash_first(tc, weakhash);
    while (c.MVM_str_hash_at_end(tc, weakhash, iterator) == 0) {
        const current: [*c]c.MVMSerializationContextWeakHashEntry = @ptrCast(@alignCast(c.MVM_str_hash_current_nocheck(tc, weakhash, iterator)));
        // mark the string handle pointer iff it hasn't yet been resolved
        addCollectable(tc, worklist, snapshot, &current.*.hash_handle.key, "SC weakhash hash key");
        if (current.*.scb.*.sc == null)
            addCollectable(tc, worklist, snapshot, &current.*.scb.*.handle, "SC weakhash unresolved handle")
        else if (current.*.scb.*.claimed == 0)
            addCollectable(tc, worklist, snapshot, &current.*.scb.*.sc, "SC weakhash unclaimed SC");
        iterator = c.MVM_str_hash_next_nocheck(tc, weakhash, iterator);
    }

    addCollectable(tc, worklist, snapshot, &instance.*.cached_backend_config, "Cached backend configuration hash");

    addCollectable(tc, worklist, snapshot, &instance.*.env_hash, "Cached environment variable hash");

    addCollectable(tc, worklist, snapshot, &instance.*.sig_arr, "Cached signal mapping array");

    if (instance.*.confprog != null)
        c.MVM_confprog_mark(tc, worklist, snapshot);

    addCollectable(tc, worklist, snapshot, &instance.*.subscriptions.subscription_queue, "VM Event Subscription Queue");

    // The C adds GCEvent twice, the second time under the SpeshOverviewEvent
    // description (roots.c:136-139); ported as written.
    addCollectable(tc, worklist, snapshot, &instance.*.subscriptions.GCEvent, "VM Event GCEvent type");
    addCollectable(tc, worklist, snapshot, &instance.*.subscriptions.GCEvent, "VM Event SpeshOverviewEvent type");

    c.MVM_callsite_mark_interns(tc, worklist, snapshot);

    if (worklist != null)
        c.MVM_disp_registry_mark(tc, worklist)
    else
        c.MVM_disp_registry_describe(tc, snapshot);

    c.MVM_debugserver_mark_handles(tc, worklist, snapshot);
}

/// Adds anything that is a root thanks to being referenced by a thread,
/// context, but that isn't permanent. (roots.c:153-240)
pub fn addTcRootsToWorklist(tc: Tc, worklist: Worklist, snapshot: Snapshot) callconv(.c) void {
    // The call stack.
    c.MVM_callstack_mark_current_thread(tc, worklist, snapshot);

    // The current frame, if it's on the heap.
    if (tc.*.cur_frame != null and !onCallstack(tc, tc.*.cur_frame))
        addCollectable(tc, worklist, snapshot, &tc.*.cur_frame, "Current bytecode frame");

    // Any active exception handlers and payload.
    var cur_ah: [*c]c.MVMActiveHandler = tc.*.active_handlers;
    while (cur_ah != null) {
        addCollectable(tc, worklist, snapshot, &cur_ah.*.ex_obj, "Active handler exception object");
        if (!onCallstack(tc, cur_ah.*.frame))
            addCollectable(tc, worklist, snapshot, &cur_ah.*.frame, "Active handler frame");
        cur_ah = cur_ah.*.next_handler;
    }
    addCollectable(tc, worklist, snapshot, &tc.*.last_payload, "Last exception payload");

    // The thread object.
    addCollectable(tc, worklist, snapshot, &tc.*.thread_obj, "Thread object");

    // The thread's entry frame.
    if (tc.*.thread_entry_frame != null and !onCallstack(tc, tc.*.thread_entry_frame))
        addCollectable(tc, worklist, snapshot, &tc.*.thread_entry_frame, "Thread entry frame");

    // Any exception handler result.
    addCollectable(tc, worklist, snapshot, &tc.*.last_handler_result, "Last handler result");

    // List of SCs currently being compiled.
    addCollectable(tc, worklist, snapshot, &tc.*.compiling_scs, "Compiling serialization contexts");

    // compunit variable pointer (and be null if thread finished)
    if (tc.*.interp_cu != null)
        addCollectable(tc, worklist, snapshot, tc.*.interp_cu, "Current interpreter compilation unit");

    // Callback cache.
    const cache: [*c]c.MVMStrHashTable = &tc.*.native_callback_cache;
    var iterator = c.MVM_str_hash_first(tc, cache);
    while (c.MVM_str_hash_at_end(tc, cache, iterator) == 0) {
        const current_cbceh: [*c]c.MVMNativeCallbackCacheHead = @ptrCast(@alignCast(c.MVM_str_hash_current_nocheck(tc, cache, iterator)));
        var i: c.MVMint32 = undefined;
        var entry: [*c]c.MVMNativeCallback = current_cbceh.*.head;
        addCollectable(tc, worklist, snapshot, &current_cbceh.*.hash_handle.key, "Native callback cache key");
        while (entry != null) {
            i = 0;
            while (i < entry.*.num_types) : (i += 1)
                addCollectable(tc, worklist, snapshot, &entry.*.types[@intCast(i)], "Native callback cache type");
            addCollectable(tc, worklist, snapshot, &entry.*.target, "Native callback cache target");
            entry = entry.*.next;
        }
        iterator = c.MVM_str_hash_next_nocheck(tc, cache, iterator);
    }

    // Profiling data.
    if (worklist != null)
        c.MVM_profile_instrumented_mark_data(tc, worklist);

    // Specialization log and stack simulation state.
    addCollectable(tc, worklist, snapshot, &tc.*.spesh_log, "Specialization log");
    if (worklist != null)
        c.MVM_spesh_sim_stack_gc_mark(tc, tc.*.spesh_sim_stack, worklist)
    else
        c.MVM_spesh_sim_stack_gc_describe(tc, snapshot, tc.*.spesh_sim_stack);
    if (tc.*.spesh_active_graph != null) {
        if (worklist != null)
            c.MVM_spesh_graph_mark(tc, tc.*.spesh_active_graph, worklist)
        else
            c.MVM_spesh_graph_describe(tc, tc.*.spesh_active_graph, snapshot);
    }
    addCollectable(tc, worklist, snapshot, &tc.*.osr_hunt_static_frame, "Current static frame for watching for OSR spesh candidate");

    if (tc.*.step_mode_frame != null)
        addCollectable(tc, worklist, snapshot, &tc.*.step_mode_frame, "Frame referenced for stepping mode");

    if (tc.*.mark_args != null) {
        // `int from` against the MVMuint16 flag_count.
        var from: c_int = 0;
        while (from < tc.*.mark_args.*.callsite.*.flag_count) : (from += 1) {
            const flag: c_int = tc.*.mark_args.*.callsite.*.arg_flags[@intCast(from)];
            if ((flag & c.MVM_CALLSITE_ARG_TYPE_MASK) == c.MVM_CALLSITE_ARG_OBJ or
                (flag & c.MVM_CALLSITE_ARG_TYPE_MASK) == c.MVM_CALLSITE_ARG_STR)
                // As in the C, the worklist is used directly here, even on the
                // heap snapshot path (roots.c:237).
                worklistAdd(tc, worklist, &tc.*.mark_args.*.source[tc.*.mark_args.*.map[@intCast(from)]].o);
        }
    }
}

/// Pushes a temporary root onto the thread-local roots list. (roots.c:243-254)
pub fn tempPushSlow(tc: Tc, obj_ref: [*c][*c]Collectable) callconv(.c) void {
    // Allocate extra temporary root space if needed.
    if (tc.*.num_temproots == tc.*.alloc_temproots) {
        tc.*.alloc_temproots *%= 2;
        tc.*.temproots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.*.temproots), @sizeOf([*c][*c]Collectable) * @as(usize, tc.*.alloc_temproots))));
    }

    // Add this one to the list.
    tc.*.temproots[tc.*.num_temproots] = obj_ref;
    tc.*.num_temproots +%= 1;
}

/// Marks the temporary root stack at its current height as the limit for
/// removing all roots. This is done so that in nested interpreter runs
/// (at present, just nativecall callbacks) we don't clear things that
/// are pushed by the native call itself. (roots.c:260-264)
pub fn tempMark(tc: Tc) callconv(.c) c.MVMuint32 {
    // MVMint32 current = tc->mark_temproots; returned as MVMuint32.
    const current: c.MVMint32 = @bitCast(tc.*.mark_temproots);
    tc.*.mark_temproots = tc.*.num_temproots;
    return @bitCast(current);
}

/// Resets the temporary root stack mark to the provided height.
/// (roots.c:267-269)
pub fn tempMarkReset(tc: Tc, mark: c.MVMuint32) callconv(.c) void {
    tc.*.mark_temproots = mark;
}

/// Pops all temporary roots off the thread-local roots list.
/// (roots.c:272-274)
pub fn tempPopAll(tc: Tc) callconv(.c) void {
    tc.*.num_temproots = tc.*.mark_temproots;
}

/// We may MVMROOT things that are actually frames on a thread local call
/// stack as they may be GC-able; such roots must not be added to the
/// worklist. (roots.c:281-284)
fn isStackFrame(tc: Tc, col: [*c][*c]Collectable) c.MVMuint32 {
    _ = tc;
    const maybe_frame = col.*;
    return @intFromBool(maybe_frame != null and maybe_frame.*.flags1 == 0 and maybe_frame.*.owner == 0);
}

/// Adds the set of thread-local temporary roots to a GC worklist.
/// (roots.c:285-300)
pub fn addTempsToWorklist(tc: Tc, worklist: Worklist, snapshot: Snapshot) callconv(.c) void {
    var i: c.MVMuint32 = 0;
    const num_roots: c.MVMuint32 = tc.*.num_temproots;
    const temproots = tc.*.temproots;
    if (worklist != null) {
        while (i < num_roots) : (i += 1)
            if (isStackFrame(tc, temproots[i]) == 0)
                worklistAdd(tc, worklist, temproots[i]);
    } else {
        while (i < num_roots) : (i += 1)
            if (isStackFrame(tc, temproots[i]) == 0)
                c.MVM_profile_heap_add_collectable_rel_idx(tc, snapshot, temproots[i].*, i);
    }
}

/// Pushes a collectable that is in generation 2, but now references a nursery
/// collectable, into the gen2 root set. (roots.c:304-323)
pub fn gen2Add(tc: Tc, col: [*c]Collectable) callconv(.c) void {
    // Ensure the collectable is not null.
    if (col == null)
        c.MVM_panic(c.MVM_exitcode_gcroots, "Illegal attempt to add null collectable address as an inter-generational root");
    cAssert((col.*.flags2 & c.MVM_CF_FORWARDER_VALID) == 0);

    // Allocate extra gen2 aggregate space if needed.
    if (tc.*.num_gen2roots == tc.*.alloc_gen2roots) {
        tc.*.alloc_gen2roots *%= 2;
        tc.*.gen2roots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.*.gen2roots), @sizeOf([*c]Collectable) * @as(usize, tc.*.alloc_gen2roots))));
    }

    // Add this one to the list.
    tc.*.gen2roots[tc.*.num_gen2roots] = col;
    tc.*.num_gen2roots +%= 1;

    // Flag it as added, so we don't add it multiple times.
    col.*.flags2 |= c.MVM_CF_IN_GEN2_ROOT_LIST;
}

/// Adds the set of thread-local inter-generational roots to a GC worklist. As
/// a side-effect, removes gen2 roots that no longer point to any nursery
/// items (usually because all the referenced objects also got promoted).
/// (roots.c:328-370)
pub fn addGen2sToWorklist(tc: Tc, worklist: Worklist) callconv(.c) void {
    const gen2roots = tc.*.gen2roots;
    const num_roots: c.MVMuint32 = tc.*.num_gen2roots;
    var i: c.MVMuint32 = 0;

    // We'll remove some entries from this list. The algorithm is simply to
    // slide all that stay towards the start of the array.
    var insert_pos: c.MVMuint32 = 0;

    // Guess that we'll end up with around num_roots entries, to avoid some
    // worklist growth reallocations. (MVMuint32 passed as MVMint32.)
    c.MVM_gc_worklist_presize_for(tc, worklist, @bitCast(num_roots));

    // Visit each gen2 root and...
    while (i < num_roots) : (i += 1) {
        // Count items on worklist before we mark it.
        const items_before_mark: c.MVMuint32 = worklist.*.items;

        // Put things it references into the worklist; since the worklist will
        // be set not to include gen2 things, only nursery things will make it
        // in.
        cAssert((gen2roots[i].*.flags2 & c.MVM_CF_FORWARDER_VALID) == 0);
        c.MVM_gc_mark_collectable(tc, worklist, gen2roots[i]);

        // If we added any nursery objects, or if we are a frame with ->work
        // area, keep in this list.
        if (worklist.*.items != items_before_mark or
            ((gen2roots[i].*.flags1 & c.MVM_CF_FRAME) != 0 and @as(Frame, @ptrCast(@alignCast(gen2roots[i]))).*.work != null))
        {
            gen2roots[insert_pos] = gen2roots[i];
            insert_pos += 1;
        }

        // Otherwise, clear the "in gen2 root list" flag. Note that another
        // thread may also clear this flag if it also had the entry in its
        // inter-gen list, so be careful to clear it, not just toggle.
        else {
            gen2roots[i].*.flags2 &= ~@as(c.MVMuint8, c.MVM_CF_IN_GEN2_ROOT_LIST);
        }
    }

    // New number of entries after sliding is the final insert position.
    tc.*.num_gen2roots = insert_pos;
}

/// Adds inter-generational roots to a heap snapshot. (roots.c:373-379)
pub fn addGen2sToSnapshot(tc: Tc, snapshot: Snapshot) callconv(.c) void {
    const gen2roots = tc.*.gen2roots;
    const num_roots: c.MVMuint32 = tc.*.num_gen2roots;
    var i: c.MVMuint32 = 0;
    while (i < num_roots) : (i += 1)
        c.MVM_profile_heap_add_collectable_rel_idx(tc, snapshot, gen2roots[i], i);
}

/// Visits all of the roots in the gen2 list and removes those that have been
/// collected. Applied after a full collection. (roots.c:383-404)
pub fn gen2Cleanup(tc: Tc) callconv(.c) void {
    const gen2roots = tc.*.gen2roots;
    const num_roots: c.MVMuint32 = tc.*.num_gen2roots;
    var i: c.MVMuint32 = 0;
    var cur_survivor: c.MVMuint32 = undefined;

    // Find the first collected object.
    while (i < num_roots and (gen2roots[i].*.flags2 & c.MVM_CF_GEN2_LIVE) != 0)
        i += 1;
    cur_survivor = i;

    // Slide others back so the alive ones are at the start of the list.
    while (i < num_roots) {
        if ((gen2roots[i].*.flags2 & c.MVM_CF_GEN2_LIVE) != 0) {
            cAssert((gen2roots[i].*.flags2 & c.MVM_CF_FORWARDER_VALID) == 0);
            gen2roots[cur_survivor] = gen2roots[i];
            cur_survivor += 1;
        }
        i += 1;
    }

    tc.*.num_gen2roots = cur_survivor;
}

/// Walks frames and compilation units. Adds the roots it finds into the
/// GC worklist. (roots.c:409-431)
pub fn addFrameRootsToWorklist(tc: Tc, worklist: Worklist, cur_frame: Frame) callconv(.c) void {
    // Add caller to worklist if it's heap-allocated.
    if (cur_frame.*.caller != null and !onCallstack(tc, cur_frame.*.caller))
        worklistAdd(tc, worklist, &cur_frame.*.caller);

    // Add outer, code_ref and static info to work list.
    worklistAdd(tc, worklist, &cur_frame.*.outer);
    worklistAdd(tc, worklist, &cur_frame.*.code_ref);
    worklistAdd(tc, worklist, &cur_frame.*.static_info);
    worklistAdd(tc, worklist, &cur_frame.*.spesh_cand);

    // Mark frame extras if needed.
    if (cur_frame.*.extra != null) {
        const e: [*c]c.MVMFrameExtra = cur_frame.*.extra;
        if (e.*.dynlex_cache_name != null)
            worklistAdd(tc, worklist, &e.*.dynlex_cache_name);
        worklistAdd(tc, worklist, &e.*.exit_handler_result);
    }

    // Scan the registers.
    addFrameRegistersToWorklist(tc, worklist, cur_frame);
    scanLexicals(tc, worklist, cur_frame);
}

/// Takes a frame, scans its registers and adds them to the roots.
/// (roots.c:434-458)
pub fn addFrameRegistersToWorklist(tc: Tc, worklist: Worklist, frame: Frame) callconv(.c) void {
    var i: c.MVMuint16 = undefined;
    var count: c.MVMuint16 = undefined;
    var type_map: [*c]c.MVMuint16 = undefined;
    // We only need to do any of this work if the frame is in dynamic scope.
    if (frame.*.work != null) {
        // Scan locals.

        const spesh_cand: [*c]c.MVMSpeshCandidate = frame.*.spesh_cand;
        const jitcode: [*c]c.MVMJitCode = if (spesh_cand != null) spesh_cand.*.body.jitcode else null;
        // The MVMuint32 local counts are truncated to the MVMuint16 count,
        // as the C assignment does.
        if (jitcode != null and jitcode.*.local_types != null) {
            type_map = jitcode.*.local_types;
            count = @truncate(jitcode.*.num_locals);
        } else if (spesh_cand != null and spesh_cand.*.body.local_types != null) {
            type_map = spesh_cand.*.body.local_types;
            count = spesh_cand.*.body.num_locals;
        } else {
            type_map = frame.*.static_info.*.body.local_types;
            count = @truncate(frame.*.static_info.*.body.num_locals);
        }
        i = 0;
        while (i < count) : (i += 1)
            if (type_map[i] == c.MVM_reg_str or type_map[i] == c.MVM_reg_obj)
                worklistAdd(tc, worklist, &frame.*.work[i].o);
    }
}

/// Takes a frame, scans its lexicals and adds them to the roots.
/// (roots.c:461-477)
fn scanLexicals(tc: Tc, worklist: Worklist, frame: Frame) void {
    if (frame.*.env != null) {
        var i: c.MVMuint16 = undefined;
        var count: c.MVMuint16 = undefined;
        var type_map: [*c]c.MVMuint16 = undefined;
        if (frame.*.spesh_cand != null and frame.*.spesh_cand.*.body.lexical_types != null) {
            type_map = frame.*.spesh_cand.*.body.lexical_types;
            count = frame.*.spesh_cand.*.body.num_lexicals;
        } else {
            type_map = frame.*.static_info.*.body.lexical_types;
            count = @truncate(frame.*.static_info.*.body.num_lexicals);
        }
        i = 0;
        while (i < count) : (i += 1)
            if (type_map[i] == c.MVM_reg_str or type_map[i] == c.MVM_reg_obj)
                worklistAdd(tc, worklist, &frame.*.env[i].o);
    }
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&addPermanentDesc, .{ .name = "MVM_gc_root_add_permanent_desc", .visibility = visibility });
    @export(&addPermanent, .{ .name = "MVM_gc_root_add_permanent", .visibility = visibility });
    @export(&addPermanentsToWorklist, .{ .name = "MVM_gc_root_add_permanents_to_worklist", .visibility = visibility });
    @export(&addInstanceRootsToWorklist, .{ .name = "MVM_gc_root_add_instance_roots_to_worklist", .visibility = visibility });
    @export(&addTcRootsToWorklist, .{ .name = "MVM_gc_root_add_tc_roots_to_worklist", .visibility = visibility });
    @export(&tempPushSlow, .{ .name = "MVM_gc_root_temp_push_slow", .visibility = visibility });
    @export(&tempMark, .{ .name = "MVM_gc_root_temp_mark", .visibility = visibility });
    @export(&tempMarkReset, .{ .name = "MVM_gc_root_temp_mark_reset", .visibility = visibility });
    @export(&tempPopAll, .{ .name = "MVM_gc_root_temp_pop_all", .visibility = visibility });
    @export(&addTempsToWorklist, .{ .name = "MVM_gc_root_add_temps_to_worklist", .visibility = visibility });
    @export(&gen2Add, .{ .name = "MVM_gc_root_gen2_add", .visibility = visibility });
    @export(&addGen2sToWorklist, .{ .name = "MVM_gc_root_add_gen2s_to_worklist", .visibility = visibility });
    @export(&addGen2sToSnapshot, .{ .name = "MVM_gc_root_add_gen2s_to_snapshot", .visibility = visibility });
    @export(&gen2Cleanup, .{ .name = "MVM_gc_root_gen2_cleanup", .visibility = visibility });
    @export(&addFrameRootsToWorklist, .{ .name = "MVM_gc_root_add_frame_roots_to_worklist", .visibility = visibility });
    @export(&addFrameRegistersToWorklist, .{ .name = "MVM_gc_root_add_frame_registers_to_worklist", .visibility = visibility });
}
