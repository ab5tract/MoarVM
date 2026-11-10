//! Zig port of src/gc/roots.c (lines 1-477): the permanent, instance,
//! thread-context, temporary, inter-generational (gen2) and frame root
//! sets, added to a GC worklist or, when the worklist is NULL, described to
//! a heap snapshot. No behaviour change. The single-field instance and
//! thread roots are comptime tables (`instance_roots`, `thread_roots`) of
//! slot getters and description strings, walked with `inline for` in the C
//! order, which fixes the marking order and therefore the to-space layout;
//! the loops and calls the C interleaves with them stay between the table
//! segments, where the C has them. The inline temp-root push/pop and the
//! MVMROOT* macros stay in src/gc/roots.h; the slow push, the root arrays
//! and their growth are here, allocated through `MVM_realloc` as in the C.
//! `MVM_gc_worklist_add` is `moar.worklistAdd`; the `MVM_str_hash_*`
//! iteration goes through `c.` (the Zig hash engine's exports). The
//! functions are Zig-typed; the `MVM_gc_root_*` exports are thin C-ABI
//! wrappers over them.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");
const worklist_mod = @import("worklist.zig");

const Tc = view.Tc;
const Instance = view.Instance;
const Col = view.Col;
const ColSlot = view.ColSlot;
const Frame = view.Frame;
const Worklist = view.Worklist;

const worklistAdd = moar.worklistAdd;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.optimize == .debug) std.debug.assert(ok);
}

/// MVM_FRAME_IS_ON_CALLSTACK as a bool.
inline fn onCallstack(tc: Tc, frame: ?Frame) bool {
    return c.MVM_FRAME_IS_ON_CALLSTACK(tc, frame) != 0;
}

/// `p`, the address of a C field or array element holding a pointer to a
/// collectable (`MVMObject *`, `MVMSTable *`, `MVMString *`, `MVMFrame *`,
/// …), viewed as a collectable slot: the C's `&(col)` cast to
/// `MVMCollectable **`. Every such view of the walks goes through here.
inline fn slot(p: anytype) ColSlot {
    comptime {
        const P = @typeInfo(@TypeOf(p)).pointer;
        std.debug.assert(@typeInfo(P.child) == .pointer);
    }
    return @ptrCast(p);
}

/// `ptr[0..len]` of a C list `ptr` with its count `len`, which the C may
/// hold as NULL with a zero count (a static frame without locals, a callsite
/// without flags): slicing a NULL `[*c]` is not allowed (view.list).
const list = view.list;

/// A root list of the C (`MVMCollectable ***`: permroots, temproots) as the
/// slots it holds; the C never stores NULL in one.
inline fn rootSlots(roots: anytype, n: u32) []const ColSlot {
    return @ptrCast(list(roots, n));
}

/// The gen2 root list (`MVMCollectable **`) as the collectables it holds;
/// `gen2Add` never stores NULL.
inline fn gen2List(tc: Tc) []Col {
    return @ptrCast(list(tc.gen2roots, tc.num_gen2roots));
}

/// Adds a location holding a collectable object to the permanent list of GC
/// roots, so that it will always be marked and never die. Note that the
/// address of the collectable must be passed, since it will need to be
/// updated. (roots.c:7-28)
pub fn addPermanentDesc(tc: Tc, obj_ref: ?ColSlot, description: ?[*:0]const u8) void {
    const ref = obj_ref orelse
        c.MVM_panic(c.MVM_exitcode_gcroots, "Illegal attempt to add null object address as a permanent root");

    const instance: Instance = tc.instance;
    c.uv_mutex_lock(&instance.mutex_permroots);
    // Allocate extra permanent root space if needed.
    if (instance.num_permroots == instance.alloc_permroots) {
        instance.alloc_permroots *%= 2;
        instance.permroots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(instance.permroots), @sizeOf(ColSlot) * @as(usize, instance.alloc_permroots))));
        instance.permroot_descriptions = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(instance.permroot_descriptions), @sizeOf(?[*:0]const u8) * @as(usize, instance.alloc_permroots))));
    }

    // Add this one to the list.
    instance.permroots[instance.num_permroots] = @ptrCast(ref);
    instance.permroot_descriptions[instance.num_permroots] = description;
    instance.num_permroots +%= 1;

    c.uv_mutex_unlock(&instance.mutex_permroots);
}

/// (roots.c:30-32)
pub fn addPermanent(tc: Tc, obj_ref: ?ColSlot) void {
    addPermanentDesc(tc, obj_ref, "<??>");
}

/// Adds the set of permanently registered roots to a GC worklist.
/// (roots.c:35-50)
pub fn addPermanentsToWorklist(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState) void {
    const instance: Instance = tc.instance;
    const permroots = rootSlots(instance.permroots, instance.num_permroots);
    if (worklist) |wl| {
        for (permroots) |r| worklistAdd(tc, wl, r);
    } else {
        const permroot_descriptions = list(instance.permroot_descriptions, permroots.len);
        for (permroots, permroot_descriptions) |r, d|
            c.MVM_profile_heap_add_collectable_rel_const_cstr(tc, snapshot, r.*, d);
    }
}

/// The add_collectable macro (roots.c:52-63): adds to the GC worklist if
/// there is one, otherwise describes the collectable to the heap snapshot.
/// `s` is the address of the collectable pointer (the C's `&(col)`).
inline fn addCollectable(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState, s: ColSlot, desc: [*:0]const u8) void {
    if (worklist) |wl| {
        worklistAdd(tc, wl, s);
    } else {
        c.MVM_profile_heap_add_collectable_rel_const_cstr(tc, snapshot, s.*, desc);
    }
}

// ---- the instance roots ----------------------------------------------------

/// A single-field instance root: the address of its slot, and the
/// description a heap snapshot gives it.
pub const InstanceRoot = struct { get: fn (Instance) ColSlot, desc: [*:0]const u8 };

/// The getter of the instance field `name`.
fn field(comptime name: []const u8) fn (Instance) ColSlot {
    return struct {
        fn get(i: Instance) ColSlot {
            return slot(&@field(i, name));
        }
    }.get;
}

/// The getter of the field `name` of the instance's VM event subscriptions.
fn subscription(comptime name: []const u8) fn (Instance) ColSlot {
    return struct {
        fn get(i: Instance) ColSlot {
            return slot(&@field(i.subscriptions, name));
        }
    }.get;
}

/// roots.c:70-90: the threads, the registries and arguments, the event loop
/// and the specialization thread.
const instance_head = [_]InstanceRoot{
    .{ .get = field("threads"), .desc = "Thread list" },
    .{ .get = field("compiler_registry"), .desc = "Compiler registry" },
    .{ .get = field("hll_syms"), .desc = "HLL symbols" },
    .{ .get = field("clargs"), .desc = "Command line args" },
    .{ .get = field("event_loop_thread"), .desc = "Event loop thread" },
    .{ .get = field("event_loop_todo_queue"), .desc = "Event loop todo queue" },
    .{ .get = field("event_loop_permit_queue"), .desc = "Event loop permit queue" },
    .{ .get = field("event_loop_cancel_queue"), .desc = "Event loop cancel queue" },
    .{ .get = field("event_loop_active"), .desc = "Event loop active task list" },
    .{ .get = field("event_loop_free_indices"), .desc = "Event loop active free indices list" },
    .{ .get = field("spesh_thread"), .desc = "Specialization thread" },
    .{ .get = field("spesh_queue"), .desc = "Specialization log queue" },
};

/// roots.c:118-125: the cached configuration, environment and signals.
const instance_caches = [_]InstanceRoot{
    .{ .get = field("cached_backend_config"), .desc = "Cached backend configuration hash" },
    .{ .get = field("env_hash"), .desc = "Cached environment variable hash" },
    .{ .get = field("sig_arr"), .desc = "Cached signal mapping array" },
};

/// roots.c:130-137: the VM event subscriptions.
const instance_subscriptions = [_]InstanceRoot{
    .{ .get = subscription("subscription_queue"), .desc = "VM Event Subscription Queue" },
    .{ .get = subscription("GCEvent"), .desc = "VM Event GCEvent type" },
    .{ .get = subscription("SpeshOverviewEvent"), .desc = "VM Event SpeshOverviewEvent type" },
};

/// The single-field instance roots, in the C order of
/// `MVM_gc_root_add_instance_roots_to_worklist`.
pub const instance_roots = instance_head ++ instance_caches ++ instance_subscriptions;

inline fn addInstanceRoots(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState, instance: Instance, comptime table: []const InstanceRoot) void {
    inline for (table) |r| addCollectable(tc, worklist, snapshot, r.get(instance), r.desc);
}

/// Adds anything that is a root thanks to being referenced by instance,
/// but that isn't permanent. (roots.c:67-149)
pub fn addInstanceRootsToWorklist(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState) void {
    const instance: Instance = tc.instance;

    addInstanceRoots(tc, worklist, snapshot, instance, &instance_head);

    if (worklist) |wl|
        c.MVM_spesh_plan_gc_mark(tc, instance.spesh_plan, wl);

    for (instance.int_to_str_cache[0..c.MVM_INT_TO_STR_CACHE_SIZE]) |*entry|
        addCollectable(tc, worklist, snapshot, slot(entry), "Integer to string cache entry");

    // okay, so this makes the weak hash slightly less weak.. for certain
    // keys of it anyway...
    const weakhash = &instance.sc_weakhash;
    var iterator = c.MVM_str_hash_first(tc, weakhash);
    while (c.MVM_str_hash_at_end(tc, weakhash, iterator) == 0) : (iterator = c.MVM_str_hash_next_nocheck(tc, weakhash, iterator)) {
        const current: *c.MVMSerializationContextWeakHashEntry = @ptrCast(@alignCast(c.MVM_str_hash_current_nocheck(tc, weakhash, iterator)));
        // mark the string handle pointer iff it hasn't yet been resolved
        addCollectable(tc, worklist, snapshot, slot(&current.hash_handle.key), "SC weakhash hash key");
        const scb: *c.MVMSerializationContextBody = current.scb;
        if (scb.sc == null)
            addCollectable(tc, worklist, snapshot, slot(&scb.handle), "SC weakhash unresolved handle")
        else if (scb.claimed == 0)
            addCollectable(tc, worklist, snapshot, slot(&scb.sc), "SC weakhash unclaimed SC");
    }

    addInstanceRoots(tc, worklist, snapshot, instance, &instance_caches);

    if (instance.confprog != null)
        c.MVM_confprog_mark(tc, worklist, snapshot);

    addInstanceRoots(tc, worklist, snapshot, instance, &instance_subscriptions);

    c.MVM_callsite_mark_interns(tc, worklist, snapshot);

    if (worklist) |wl|
        c.MVM_disp_registry_mark(tc, wl)
    else
        c.MVM_disp_registry_describe(tc, snapshot);

    c.MVM_debugserver_mark_handles(tc, worklist, snapshot);
}

// ---- the thread-context roots ----------------------------------------------

/// A single-field thread root: the address of its slot, its description,
/// and the C's condition for adding it (`always` where the C has none). The
/// condition is tested before the getter runs, as the C tests it before it
/// takes the field's address.
pub const ThreadRoot = struct { get: fn (Tc) ColSlot, desc: [*:0]const u8, when: fn (Tc) bool = always };

fn always(tc: Tc) bool {
    _ = tc;
    return true;
}

/// The getter of the thread-context field `name`.
fn tcField(comptime name: []const u8) fn (Tc) ColSlot {
    return struct {
        fn get(tc: Tc) ColSlot {
            return slot(&@field(tc, name));
        }
    }.get;
}

/// `tc->name` is set (roots.c:176, 230: `if (tc->name)`).
fn isSet(comptime name: []const u8) fn (Tc) bool {
    return struct {
        fn when(tc: Tc) bool {
            return @field(tc, name) != null;
        }
    }.when;
}

/// The frame `tc->name` is set and on the heap (roots.c:158, 175:
/// `if (tc->name && !MVM_FRAME_IS_ON_CALLSTACK(tc, tc->name))`).
fn heapFrame(comptime name: []const u8) fn (Tc) bool {
    return struct {
        fn when(tc: Tc) bool {
            const frame = @field(tc, name);
            return frame != null and !onCallstack(tc, frame);
        }
    }.when;
}

/// The compunit variable the interpreter points `interp_cu` at.
fn interpCu(tc: Tc) ColSlot {
    return slot(tc.interp_cu);
}

/// roots.c:157-159: the current frame, if it's on the heap.
const tc_frame_roots = [_]ThreadRoot{
    .{ .get = tcField("cur_frame"), .desc = "Current bytecode frame", .when = heapFrame("cur_frame") },
};

/// roots.c:168-187: the payload, the thread object and entry frame, the
/// handler result, the SCs being compiled and the current compunit (the
/// variable pointer is NULL once the thread has finished).
const tc_state_roots = [_]ThreadRoot{
    .{ .get = tcField("last_payload"), .desc = "Last exception payload" },
    .{ .get = tcField("thread_obj"), .desc = "Thread object" },
    .{ .get = tcField("thread_entry_frame"), .desc = "Thread entry frame", .when = heapFrame("thread_entry_frame") },
    .{ .get = tcField("last_handler_result"), .desc = "Last handler result" },
    .{ .get = tcField("compiling_scs"), .desc = "Compiling serialization contexts" },
    .{ .get = interpCu, .desc = "Current interpreter compilation unit", .when = isSet("interp_cu") },
};

/// roots.c:213: the specialization log.
const tc_spesh_roots = [_]ThreadRoot{
    .{ .get = tcField("spesh_log"), .desc = "Specialization log" },
};

/// roots.c:224-231: the OSR watch and the stepping frame.
const tc_late_roots = [_]ThreadRoot{
    .{ .get = tcField("osr_hunt_static_frame"), .desc = "Current static frame for watching for OSR spesh candidate" },
    .{ .get = tcField("step_mode_frame"), .desc = "Frame referenced for stepping mode", .when = isSet("step_mode_frame") },
};

/// The single-field thread roots, in the C order of
/// `MVM_gc_root_add_tc_roots_to_worklist`.
pub const thread_roots = tc_frame_roots ++ tc_state_roots ++ tc_spesh_roots ++ tc_late_roots;

inline fn addThreadRoots(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState, comptime table: []const ThreadRoot) void {
    inline for (table) |r| {
        if (r.when(tc)) addCollectable(tc, worklist, snapshot, r.get(tc), r.desc);
    }
}

/// Adds anything that is a root thanks to being referenced by a thread,
/// context, but that isn't permanent. (roots.c:153-242)
pub fn addTcRootsToWorklist(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState) void {
    // The call stack.
    c.MVM_callstack_mark_current_thread(tc, worklist, snapshot);

    // The current frame, if it's on the heap.
    addThreadRoots(tc, worklist, snapshot, &tc_frame_roots);

    // Any active exception handlers and payload.
    var cur_ah: ?*c.MVMActiveHandler = tc.active_handlers;
    while (cur_ah) |ah| : (cur_ah = ah.next_handler) {
        addCollectable(tc, worklist, snapshot, slot(&ah.ex_obj), "Active handler exception object");
        if (!onCallstack(tc, ah.frame))
            addCollectable(tc, worklist, snapshot, slot(&ah.frame), "Active handler frame");
    }

    // The payload, the thread object and its entry frame, the handler
    // result, the SCs being compiled, the compunit variable.
    addThreadRoots(tc, worklist, snapshot, &tc_state_roots);

    // Callback cache.
    const cache = &tc.native_callback_cache;
    var iterator = c.MVM_str_hash_first(tc, cache);
    while (c.MVM_str_hash_at_end(tc, cache, iterator) == 0) : (iterator = c.MVM_str_hash_next_nocheck(tc, cache, iterator)) {
        const current_cbceh: *c.MVMNativeCallbackCacheHead = @ptrCast(@alignCast(c.MVM_str_hash_current_nocheck(tc, cache, iterator)));
        addCollectable(tc, worklist, snapshot, slot(&current_cbceh.hash_handle.key), "Native callback cache key");
        var entry: ?*c.MVMNativeCallback = current_cbceh.head;
        while (entry) |e| : (entry = e.next) {
            // `MVMint32 i < entry->num_types`: none when the count is not
            // positive.
            const num_types: usize = @intCast(@max(e.num_types, 0));
            for (list(e.types, num_types)) |*t|
                addCollectable(tc, worklist, snapshot, slot(t), "Native callback cache type");
            addCollectable(tc, worklist, snapshot, slot(&e.target), "Native callback cache target");
        }
    }

    // Profiling data.
    if (worklist) |wl|
        c.MVM_profile_instrumented_mark_data(tc, wl);

    // Specialization log and stack simulation state.
    addThreadRoots(tc, worklist, snapshot, &tc_spesh_roots);
    if (worklist) |wl|
        c.MVM_spesh_sim_stack_gc_mark(tc, tc.spesh_sim_stack, wl)
    else
        c.MVM_spesh_sim_stack_gc_describe(tc, snapshot, tc.spesh_sim_stack);
    if (tc.spesh_active_graph != null) {
        if (worklist) |wl|
            c.MVM_spesh_graph_mark(tc, tc.spesh_active_graph, wl)
        else
            c.MVM_spesh_graph_describe(tc, tc.spesh_active_graph, snapshot);
    }

    // The OSR watch and the frame referenced for stepping mode.
    addThreadRoots(tc, worklist, snapshot, &tc_late_roots);

    if (tc.mark_args != null) {
        const args: *c.MVMArgs = tc.mark_args;
        const callsite: *c.MVMCallsite = args.callsite;
        // `int from < flag_count` (MVMuint16): every flag and its map entry.
        const flags = list(callsite.arg_flags, callsite.flag_count);
        for (flags, list(args.map, flags.len)) |flag, from| {
            if ((flag & c.MVM_CALLSITE_ARG_TYPE_MASK) == c.MVM_CALLSITE_ARG_OBJ or
                (flag & c.MVM_CALLSITE_ARG_TYPE_MASK) == c.MVM_CALLSITE_ARG_STR)
                addCollectable(tc, worklist, snapshot, slot(&args.source[from].o), "Dispatch resumption initial argument");
        }
    }
}

// ---- temporary roots ---------------------------------------------------------

/// Pushes a temporary root onto the thread-local roots list. (roots.c:245-256)
pub fn tempPushSlow(tc: Tc, s: ColSlot) void {
    // Allocate extra temporary root space if needed.
    if (tc.num_temproots == tc.alloc_temproots) {
        tc.alloc_temproots *%= 2;
        tc.temproots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.temproots), @sizeOf(ColSlot) * @as(usize, tc.alloc_temproots))));
    }

    // Add this one to the list.
    tc.temproots[tc.num_temproots] = @ptrCast(s);
    tc.num_temproots +%= 1;
}

/// Marks the temporary root stack at its current height as the limit for
/// removing all roots. This is done so that in nested interpreter runs
/// (at present, just nativecall callbacks) we don't clear things that
/// are pushed by the native call itself. (roots.c:262-266; the C's
/// `MVMint32 current` holds the MVMuint32 field and is returned as one.)
pub fn tempMark(tc: Tc) u32 {
    const current = tc.mark_temproots;
    tc.mark_temproots = tc.num_temproots;
    return current;
}

/// Resets the temporary root stack mark to the provided height.
/// (roots.c:269-271)
pub fn tempMarkReset(tc: Tc, mark: u32) void {
    tc.mark_temproots = mark;
}

/// Pops all temporary roots off the thread-local roots list.
/// (roots.c:274-276)
pub fn tempPopAll(tc: Tc) void {
    tc.num_temproots = tc.mark_temproots;
}

/// We may MVMROOT things that are actually frames on a thread local call
/// stack as they may be GC-able; such roots must not be added to the
/// worklist: a collectable with no flags1 bit and no owner.
/// (roots.c:283-286)
fn isStackFrame(s: ColSlot) bool {
    const maybe_frame = s.* orelse return false;
    return maybe_frame.flags1 == 0 and maybe_frame.owner == 0;
}

/// Adds the set of thread-local temporary roots to a GC worklist.
/// (roots.c:287-302)
pub fn addTempsToWorklist(tc: Tc, worklist: ?Worklist, snapshot: ?*c.MVMHeapSnapshotState) void {
    const temproots = rootSlots(tc.temproots, tc.num_temproots);
    if (worklist) |wl| {
        for (temproots) |r| {
            if (!isStackFrame(r)) worklistAdd(tc, wl, r);
        }
    } else {
        for (temproots, 0..) |r, i| {
            if (!isStackFrame(r)) c.MVM_profile_heap_add_collectable_rel_idx(tc, snapshot, r.*, i);
        }
    }
}

// ---- inter-generational roots ------------------------------------------------

/// Pushes a collectable that is in generation 2, but now references a nursery
/// collectable, into the gen2 root set. (roots.c:306-325)
pub fn gen2Add(tc: Tc, maybe_col: ?Col) void {
    // Ensure the collectable is not null.
    const col = maybe_col orelse
        c.MVM_panic(c.MVM_exitcode_gcroots, "Illegal attempt to add null collectable address as an inter-generational root");
    cAssert(!view.flags2(col).forwarder_valid);

    // Allocate extra gen2 aggregate space if needed.
    if (tc.num_gen2roots == tc.alloc_gen2roots) {
        tc.alloc_gen2roots *%= 2;
        tc.gen2roots = @ptrCast(@alignCast(c.MVM_realloc(@ptrCast(tc.gen2roots), @sizeOf(Col) * @as(usize, tc.alloc_gen2roots))));
    }

    // Add this one to the list.
    tc.gen2roots[tc.num_gen2roots] = col;
    tc.num_gen2roots +%= 1;

    // Flag it as added, so we don't add it multiple times.
    view.flags2(col).in_gen2_root_list = true;
}

/// Adds the set of thread-local inter-generational roots to a GC worklist. As
/// a side-effect, removes gen2 roots that no longer point to any nursery
/// items (usually because all the referenced objects also got promoted).
/// (roots.c:330-372)
pub fn addGen2sToWorklist(tc: Tc, worklist: Worklist) void {
    const gen2roots = gen2List(tc);

    // We'll remove some entries from this list. The algorithm is simply to
    // slide all that stay towards the start of the array.
    var insert_pos: u32 = 0;

    // Guess that we'll end up with around num_roots entries, to avoid some
    // worklist growth reallocations.
    worklist_mod.presizeFor(worklist, tc.num_gen2roots);

    // Visit each gen2 root and...
    for (gen2roots) |col| {
        // Count items on worklist before we mark it.
        const items_before_mark = worklist.items;

        // Put things it references into the worklist; since the worklist will
        // be set not to include gen2 things, only nursery things will make it
        // in.
        cAssert(!view.flags2(col).forwarder_valid);
        c.MVM_gc_mark_collectable(tc, worklist, col);

        // If we added any nursery objects, or if we are a frame with ->work
        // area, keep in this list.
        if (worklist.items != items_before_mark or
            (view.flags1(col).frame and view.asFrame(col).work != null))
        {
            gen2roots[insert_pos] = col;
            insert_pos += 1;
        }

        // Otherwise, clear the "in gen2 root list" flag. Note that another
        // thread may also clear this flag if it also had the entry in its
        // inter-gen list, so be careful to clear it, not just toggle.
        else {
            view.flags2(col).in_gen2_root_list = false;
        }
    }

    // New number of entries after sliding is the final insert position.
    tc.num_gen2roots = insert_pos;
}

/// Adds inter-generational roots to a heap snapshot. (roots.c:375-381)
pub fn addGen2sToSnapshot(tc: Tc, snapshot: ?*c.MVMHeapSnapshotState) void {
    for (gen2List(tc), 0..) |col, i|
        c.MVM_profile_heap_add_collectable_rel_idx(tc, snapshot, col, i);
}

/// Visits all of the roots in the gen2 list and removes those that have been
/// collected. Applied after a full collection. (roots.c:385-406)
pub fn gen2Cleanup(tc: Tc) void {
    const gen2roots = gen2List(tc);

    // Find the first collected object.
    const first_collected = for (gen2roots, 0..) |col, i| {
        if (!view.flags2(col).gen2_live) break i;
    } else gen2roots.len;

    // Slide others back so the alive ones are at the start of the list.
    var cur_survivor = first_collected;
    for (gen2roots[first_collected..]) |col| {
        if (view.flags2(col).gen2_live) {
            cAssert(!view.flags2(col).forwarder_valid);
            gen2roots[cur_survivor] = col;
            cur_survivor += 1;
        }
    }

    tc.num_gen2roots = @intCast(cur_survivor);
}

// ---- frame roots ---------------------------------------------------------------

/// Walks frames and compilation units. Adds the roots it finds into the
/// GC worklist. (roots.c:411-433)
pub fn addFrameRootsToWorklist(tc: Tc, worklist: Worklist, frame: Frame) void {
    // Add caller to worklist if it's heap-allocated.
    if (frame.caller != null and !onCallstack(tc, frame.caller))
        worklistAdd(tc, worklist, slot(&frame.caller));

    // Add outer, code_ref and static info to work list.
    worklistAdd(tc, worklist, slot(&frame.outer));
    worklistAdd(tc, worklist, slot(&frame.code_ref));
    worklistAdd(tc, worklist, slot(&frame.static_info));
    worklistAdd(tc, worklist, slot(&frame.spesh_cand));

    // Mark frame extras if needed.
    if (frame.extra != null) {
        const e: *c.MVMFrameExtra = frame.extra;
        if (e.dynlex_cache_name != null)
            worklistAdd(tc, worklist, slot(&e.dynlex_cache_name));
        worklistAdd(tc, worklist, slot(&e.exit_handler_result));
    }

    // Scan the registers.
    addFrameRegistersToWorklist(tc, worklist, frame);
    scanLexicals(tc, worklist, frame);
}

/// Takes a frame, scans its registers and adds them to the roots.
/// (roots.c:436-460)
pub fn addFrameRegistersToWorklist(tc: Tc, worklist: Worklist, frame: Frame) void {
    // We only need to do any of this work if the frame is in dynamic scope.
    if (frame.work == null) return;
    const work = frame.work;

    // Scan locals: the register kinds of the JIT code, else of the spesh
    // candidate, else of the static frame. The MVMuint32 local counts are
    // truncated to the MVMuint16 count, as the C assignment does.
    const spesh_cand: ?*c.MVMSpeshCandidate = frame.spesh_cand;
    const jitcode: ?*c.MVMJitCode = if (spesh_cand) |cand| cand.body.jitcode else null;
    const types: []const c.MVMuint16 = locals: {
        if (jitcode) |jit| {
            if (jit.local_types != null) break :locals list(jit.local_types, @as(u16, @truncate(jit.num_locals)));
        }
        if (spesh_cand) |cand| {
            if (cand.body.local_types != null) break :locals list(cand.body.local_types, cand.body.num_locals);
        }
        const body = &frame.static_info.*.body;
        break :locals list(body.local_types, @as(u16, @truncate(body.num_locals)));
    };
    const num_locals = types.len;
    for (work[0..num_locals], types[0..num_locals]) |*s, kind| {
        if (kind == c.MVM_reg_str or kind == c.MVM_reg_obj)
            worklistAdd(tc, worklist, slot(&s.o));
    }
}

/// Takes a frame, scans its lexicals and adds them to the roots: the
/// lexical kinds of the spesh candidate, else of the static frame.
/// (roots.c:463-479)
fn scanLexicals(tc: Tc, worklist: Worklist, frame: Frame) void {
    if (frame.env == null) return;
    const env = frame.env;
    const types: []const c.MVMuint16 = lexicals: {
        if (frame.spesh_cand != null and frame.spesh_cand.*.body.lexical_types != null)
            break :lexicals list(frame.spesh_cand.*.body.lexical_types, frame.spesh_cand.*.body.num_lexicals);
        const body = &frame.static_info.*.body;
        break :lexicals list(body.lexical_types, @as(u16, @truncate(body.num_lexicals)));
    };
    const num_lexicals = types.len;
    for (env[0..num_lexicals], types[0..num_lexicals]) |*s, kind| {
        if (kind == c.MVM_reg_str or kind == c.MVM_reg_obj)
            worklistAdd(tc, worklist, slot(&s.o));
    }
}

// ---- the C ABI -----------------------------------------------------------------

fn addPermanentDescExport(tc: [*c]c.MVMThreadContext, obj_ref: [*c][*c]c.MVMCollectable, description: [*c]const u8) callconv(.c) void {
    addPermanentDesc(tc, @ptrCast(obj_ref), @ptrCast(description));
}

fn addPermanentExport(tc: [*c]c.MVMThreadContext, obj_ref: [*c][*c]c.MVMCollectable) callconv(.c) void {
    addPermanent(tc, @ptrCast(obj_ref));
}

fn addPermanentsToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, snapshot: [*c]c.MVMHeapSnapshotState) callconv(.c) void {
    addPermanentsToWorklist(tc, worklist, snapshot);
}

fn addInstanceRootsToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, snapshot: [*c]c.MVMHeapSnapshotState) callconv(.c) void {
    addInstanceRootsToWorklist(tc, worklist, snapshot);
}

fn addTcRootsToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, snapshot: [*c]c.MVMHeapSnapshotState) callconv(.c) void {
    addTcRootsToWorklist(tc, worklist, snapshot);
}

fn tempPushSlowExport(tc: [*c]c.MVMThreadContext, obj_ref: [*c][*c]c.MVMCollectable) callconv(.c) void {
    tempPushSlow(tc, @ptrCast(obj_ref));
}

fn tempMarkExport(tc: [*c]c.MVMThreadContext) callconv(.c) c.MVMuint32 {
    return tempMark(tc);
}

fn tempMarkResetExport(tc: [*c]c.MVMThreadContext, mark: c.MVMuint32) callconv(.c) void {
    tempMarkReset(tc, mark);
}

fn tempPopAllExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    tempPopAll(tc);
}

fn addTempsToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, snapshot: [*c]c.MVMHeapSnapshotState) callconv(.c) void {
    addTempsToWorklist(tc, worklist, snapshot);
}

fn gen2AddExport(tc: [*c]c.MVMThreadContext, col: [*c]c.MVMCollectable) callconv(.c) void {
    gen2Add(tc, col);
}

fn addGen2sToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist) callconv(.c) void {
    addGen2sToWorklist(tc, worklist);
}

fn addGen2sToSnapshotExport(tc: [*c]c.MVMThreadContext, snapshot: [*c]c.MVMHeapSnapshotState) callconv(.c) void {
    addGen2sToSnapshot(tc, snapshot);
}

fn gen2CleanupExport(tc: [*c]c.MVMThreadContext) callconv(.c) void {
    gen2Cleanup(tc);
}

fn addFrameRootsToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, frame: [*c]c.MVMFrame) callconv(.c) void {
    addFrameRootsToWorklist(tc, worklist, frame);
}

fn addFrameRegistersToWorklistExport(tc: [*c]c.MVMThreadContext, worklist: [*c]c.MVMGCWorklist, frame: [*c]c.MVMFrame) callconv(.c) void {
    addFrameRegistersToWorklist(tc, worklist, frame);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&addPermanentDescExport, .{ .name = "MVM_gc_root_add_permanent_desc", .visibility = visibility });
    @export(&addPermanentExport, .{ .name = "MVM_gc_root_add_permanent", .visibility = visibility });
    @export(&addPermanentsToWorklistExport, .{ .name = "MVM_gc_root_add_permanents_to_worklist", .visibility = visibility });
    @export(&addInstanceRootsToWorklistExport, .{ .name = "MVM_gc_root_add_instance_roots_to_worklist", .visibility = visibility });
    @export(&addTcRootsToWorklistExport, .{ .name = "MVM_gc_root_add_tc_roots_to_worklist", .visibility = visibility });
    @export(&tempPushSlowExport, .{ .name = "MVM_gc_root_temp_push_slow", .visibility = visibility });
    @export(&tempMarkExport, .{ .name = "MVM_gc_root_temp_mark", .visibility = visibility });
    @export(&tempMarkResetExport, .{ .name = "MVM_gc_root_temp_mark_reset", .visibility = visibility });
    @export(&tempPopAllExport, .{ .name = "MVM_gc_root_temp_pop_all", .visibility = visibility });
    @export(&addTempsToWorklistExport, .{ .name = "MVM_gc_root_add_temps_to_worklist", .visibility = visibility });
    @export(&gen2AddExport, .{ .name = "MVM_gc_root_gen2_add", .visibility = visibility });
    @export(&addGen2sToWorklistExport, .{ .name = "MVM_gc_root_add_gen2s_to_worklist", .visibility = visibility });
    @export(&addGen2sToSnapshotExport, .{ .name = "MVM_gc_root_add_gen2s_to_snapshot", .visibility = visibility });
    @export(&gen2CleanupExport, .{ .name = "MVM_gc_root_gen2_cleanup", .visibility = visibility });
    @export(&addFrameRootsToWorklistExport, .{ .name = "MVM_gc_root_add_frame_roots_to_worklist", .visibility = visibility });
    @export(&addFrameRegistersToWorklistExport, .{ .name = "MVM_gc_root_add_frame_registers_to_worklist", .visibility = visibility });
}
