//! Zig port of src/gc/allocation.c (lines 1-104): allocation from the
//! nursery, the memory space managed by the garbage collector, and the
//! STable, type object, object and frame allocators built on it. Faithful
//! port; no behaviour change. The four `MVM_STATIC_INLINE` functions of
//! src/gc/allocation.h (`MVM_gc_allocate`, `MVM_gc_allocate_zeroed` and the
//! gen2 default set/clear) stay C; the allocators below call the translated
//! `MVM_gc_allocate_zeroed`, which reaches `MVM_gc_allocate_nursery` (the
//! export below) as the C does. The `MVMROOT` and `MVM_ASSIGN_REF` macros,
//! which translate-c cannot translate, are spelled out from src/gc/roots.h
//! and src/gc/wb.h (with src/gc/debug.h's `MVM_ASSERT_NOT_FROMSPACE`).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;

// The MVMThreadContext fields the nursery path uses, with the types the C
// declares (void *, AO_t, MVMuint32); spec section 8, layout checks. The
// offset of num_temproots against the C compiler's is checked by the tests.
comptime {
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_fromspace") == ?*anyopaque);
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_tospace") == ?*anyopaque);
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_alloc") == ?*anyopaque);
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_alloc_limit") == ?*anyopaque);
    std.debug.assert(@FieldType(c.MVMThreadContext, "gc_status") == usize);
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_fromspace_size") == u32);
    std.debug.assert(@FieldType(c.MVMThreadContext, "nursery_tospace_size") == u32);
    std.debug.assert(@FieldType(c.MVMThreadContext, "allocate_in_gen2") == u32);
}

/// `MVM_ALIGN_SIZE` (allocation.h:1-5): the identity where the config allows
/// unaligned 64-bit integer and float access, else `MVM_ALIGN_SECTION`
/// (moar.h:121-122, the mask from `ALIGNOF(MVMint64)`, `__alignof__`).
pub inline fn alignSize(size: usize) usize {
    if (comptime @hasDecl(c, "MVM_CAN_UNALIGNED_INT64") and @hasDecl(c, "MVM_CAN_UNALIGNED_NUM64")) {
        return size;
    } else {
        const mask: usize = @as(c.MVMuint32, @alignOf(c.MVMint64)) - 1;
        return (size + mask) & ~mask;
    }
}

/// `MVM_ASSERT_NOT_FROMSPACE` (debug.h:12-26), compiled in when
/// MVM_GC_DEBUG is non-zero.
inline fn assertNotFromspace(check_tc: Tc, p: ?*anyopaque) void {
    var cur_thread: [*c]c.MVMThread = check_tc.*.instance.*.threads;
    if (p != null) {
        while (cur_thread != null) {
            const thread_tc: Tc = cur_thread.*.body.tc;
            if (thread_tc != null and thread_tc.*.nursery_fromspace != null and
                @intFromPtr(p) >= @intFromPtr(thread_tc.*.nursery_fromspace) and
                @intFromPtr(p) < @intFromPtr(thread_tc.*.nursery_fromspace) + thread_tc.*.nursery_fromspace_size)
                c.MVM_panic(1, "Collectable %p in fromspace accessed", p);
            cur_thread = cur_thread.*.body.next;
        }
        if (@as(*c.MVMCollectable, @ptrCast(@alignCast(p))).flags2 & c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST != 0)
            c.MVM_panic(1, "Collectable %p in a gen2 freelist accessed", p);
    }
}

/// `MVM_ASSIGN_REF(tc, update_root, *update_addr, referenced)` (wb.h:22-38).
inline fn assignRef(tc: Tc, update_root: [*c]c.MVMCollectable, update_addr: anytype, referenced: anytype) void {
    const r: ?*anyopaque = @ptrCast(referenced);
    if (comptime c.MVM_GC_DEBUG != 0) {
        if (r != null and @as(*c.MVMCollectable, @ptrCast(@alignCast(r))).owner == 0)
            c.MVM_panic(1, "Invalid assignment (maybe of heap frame to stack frame?)");
        assertNotFromspace(tc, r);
    }
    c.MVM_gc_write_barrier(tc, update_root, @ptrCast(@alignCast(r)));
    update_addr.* = @ptrCast(@alignCast(r));
}

/// Allocate the specified amount of memory from the nursery. Will trigger a
/// GC run if there is not enough. (allocation.c:8-51)
pub fn allocateNursery(tc: Tc, size_in: usize) callconv(.c) ?*anyopaque {
    var allocated: ?*anyopaque = undefined;
    // Objects in the nursery must be aligned, so we pad at the end. The
    // assumption that they are aligned is also encoded in the collector.
    const size = alignSize(size_in);

    // Before an allocation is a GC safe-point and thus a good GC sync point
    // also; check if we've been signalled to collect. A plain read, not an
    // atomic load, as the C: it's okay if the interrupt is delayed a bit.
    if (tc.*.gc_status != 0)
        c.MVM_gc_enter_from_interrupt(tc);

    // Guard against 0-byte allocation.
    if (size > 0) {
        // Do a GC run if this allocation won't fit in what we have left in
        // the nursery. A loop for the pathological case where everything in
        // the nursery is young and survives in it; the next run promotes it.
        // Without the loop at MVM_GC_DEBUG 3 (collect on every allocation).
        if (comptime c.MVM_GC_DEBUG < 3) {
            while (@intFromPtr(tc.*.nursery_alloc) + size >= @intFromPtr(tc.*.nursery_alloc_limit)) {
                if (size > c.MVM_NURSERY_SIZE)
                    c.MVM_panic(c.MVM_exitcode_gcalloc, "Attempt to allocate more than the maximum nursery size");
                c.MVM_gc_enter_from_allocator(tc);
            }
        } else {
            if (size > c.MVM_NURSERY_SIZE)
                c.MVM_panic(c.MVM_exitcode_gcalloc, "Attempt to allocate more than the maximum nursery size");
            c.MVM_gc_enter_from_allocator(tc);
        }

        // Allocate (just bump the pointer).
        allocated = tc.*.nursery_alloc;
        tc.*.nursery_alloc = @ptrFromInt(@intFromPtr(tc.*.nursery_alloc) + size);
    } else {
        c.MVM_panic(c.MVM_exitcode_gcalloc, "Cannot allocate 0 bytes of memory in the nursery");
    }

    return allocated;
}

/// Allocates a new STable, based on the specified thread context, REPR and
/// meta-object. (allocation.c:53-68)
pub fn allocateStable(tc: Tc, repr: [*c]const c.MVMREPROps, how_in: [*c]c.MVMObject) callconv(.c) [*c]c.MVMSTable {
    var how = how_in;
    var st: [*c]c.MVMSTable = undefined;
    // MVMROOT(tc, how) { ... }
    _ = c.__MVM_gc_root_temp_push_nonvoid(tc, @ptrCast(&how), 0);
    {
        st = @ptrCast(@alignCast(c.MVM_gc_allocate_zeroed(tc, @sizeOf(c.MVMSTable))));
        st.*.header.flags1 = c.MVM_CF_STABLE;
        st.*.header.size = @sizeOf(c.MVMSTable);
        st.*.header.owner = tc.*.thread_id;
        st.*.REPR = repr;
        st.*.type_cache_id = c.MVM_6model_next_type_cache_id(tc);
        st.*.debug_name = null;
        assignRef(tc, &st.*.header, &st.*.HOW, how);
    }
    c.MVM_gc_root_temp_pop(tc);
    return st;
}

/// Allocates a new type object. (allocation.c:70-81)
pub fn allocateTypeObject(tc: Tc, st_in: [*c]c.MVMSTable) callconv(.c) [*c]c.MVMObject {
    var st = st_in;
    var obj: [*c]c.MVMObject = undefined;
    // MVMROOT(tc, st) { ... }
    _ = c.__MVM_gc_root_temp_push_nonvoid(tc, @ptrCast(&st), 0);
    {
        obj = @ptrCast(@alignCast(c.MVM_gc_allocate_zeroed(tc, @sizeOf(c.MVMObject))));
        obj.*.header.flags1 = c.MVM_CF_TYPE_OBJECT;
        obj.*.header.size = @sizeOf(c.MVMObject);
        obj.*.header.owner = tc.*.thread_id;
        assignRef(tc, &obj.*.header, &obj.*.st, st);
    }
    c.MVM_gc_root_temp_pop(tc);
    return obj;
}

/// Allocates a new object, and points it at the specified STable.
/// (allocation.c:83-95)
pub fn allocateObject(tc: Tc, st_in: [*c]c.MVMSTable) callconv(.c) [*c]c.MVMObject {
    var st = st_in;
    var obj: [*c]c.MVMObject = undefined;
    // MVMROOT(tc, st) { ... }
    _ = c.__MVM_gc_root_temp_push_nonvoid(tc, @ptrCast(&st), 0);
    {
        obj = @ptrCast(@alignCast(c.MVM_gc_allocate_zeroed(tc, st.*.size)));
        obj.*.header.size = @truncate(st.*.size);
        obj.*.header.owner = tc.*.thread_id;
        assignRef(tc, &obj.*.header, &obj.*.st, st);
        if (st.*.mode_flags & c.MVM_FINALIZE_TYPE != 0)
            c.MVM_gc_finalize_add_to_queue(tc, obj);
    }
    c.MVM_gc_root_temp_pop(tc);
    return obj;
}

/// Allocates a new heap frame. (allocation.c:97-104)
pub fn allocateFrame(tc: Tc) callconv(.c) [*c]c.MVMFrame {
    const f: [*c]c.MVMFrame = @ptrCast(@alignCast(c.MVM_gc_allocate_zeroed(tc, @sizeOf(c.MVMFrame))));
    f.*.header.flags1 = c.MVM_CF_FRAME;
    f.*.header.size = @sizeOf(c.MVMFrame);
    f.*.header.owner = tc.*.thread_id;
    return f;
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.builtin.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&allocateNursery, .{ .name = "MVM_gc_allocate_nursery", .visibility = visibility });
    @export(&allocateStable, .{ .name = "MVM_gc_allocate_stable", .visibility = visibility });
    @export(&allocateTypeObject, .{ .name = "MVM_gc_allocate_type_object", .visibility = visibility });
    @export(&allocateObject, .{ .name = "MVM_gc_allocate_object", .visibility = visibility });
    @export(&allocateFrame, .{ .name = "MVM_gc_allocate_frame", .visibility = visibility });
}
