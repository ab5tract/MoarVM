//! Zig port of src/gc/allocation.c (lines 1-104): allocation from the
//! nursery, the memory space managed by the garbage collector, and the
//! STable, type object, object and frame allocators built on it. No
//! behaviour change. The four `MVM_STATIC_INLINE` functions of
//! src/gc/allocation.h (`MVM_gc_allocate`, `MVM_gc_allocate_zeroed` and the
//! gen2 default set/clear) stay C; the allocators below call the translated
//! `MVM_gc_allocate_zeroed`, which reaches `MVM_gc_allocate_nursery` (the
//! export below) as the C does. The `MVMROOT` macro, which translate-c
//! cannot translate, is `moar.root`, whose push and pop inline as the C's;
//! `MVM_ASSIGN_REF` (src/gc/wb.h, with src/gc/debug.h's
//! `MVM_ASSERT_NOT_FROMSPACE`) is the shared `moar.assignRef`. The
//! allocators are Zig-typed; the `MVM_gc_allocate_*` exports are thin C-ABI
//! wrappers over them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");
const finalize = @import("finalize.zig");

const Tc = view.Tc;
const Object = view.Object;
const STable = view.STable;
const Frame = view.Frame;

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
        // MVM_ALIGN_SECTION_MASK is `(MVMuint32)ALIGNOF(MVMint64) - 1`, so in
        // MVM_ALIGN_SECTION the add is size_t-wide but `~mask` is 32-bit:
        // zero-extended, it also clears bits 32 and up. Same widths here.
        const mask: c.MVMuint32 = @as(c.MVMuint32, @alignOf(c.MVMint64)) - 1;
        return (size + mask) & @as(usize, ~mask);
    }
}

/// Allocate the specified amount of memory from the nursery. Will trigger a
/// GC run if there is not enough. (allocation.c:8-51)
pub fn allocateNursery(tc: Tc, size_in: usize) *anyopaque {
    // Objects in the nursery must be aligned, so we pad at the end. The
    // assumption that they are aligned is also encoded in the collector.
    const size = alignSize(size_in);

    // Before an allocation is a GC safe-point and thus a good GC sync point
    // also; check if we've been signalled to collect. A plain read, not an
    // atomic load, as the C: it's okay if the interrupt is delayed a bit.
    // The whole word, so a suspend request alone enters too.
    if (tc.gc_status != 0)
        c.MVM_gc_enter_from_interrupt(tc);

    // Guard against 0-byte allocation.
    if (size == 0)
        c.MVM_panic(c.MVM_exitcode_gcalloc, "Cannot allocate 0 bytes of memory in the nursery");

    // Do a GC run if this allocation won't fit in what we have left in the
    // nursery. A loop for the pathological case where everything in the
    // nursery is young and survives in it; the next run promotes it.
    // Without the loop at MVM_GC_DEBUG 3 (collect on every allocation).
    if (comptime c.MVM_GC_DEBUG < 3) {
        while (@intFromPtr(tc.nursery_alloc) + size >= @intFromPtr(tc.nursery_alloc_limit)) {
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
    const allocated = tc.nursery_alloc.?;
    tc.nursery_alloc = @ptrFromInt(@intFromPtr(allocated) + size);
    return allocated;
}

/// `MVM_gc_allocate_zeroed` (allocation.h), the collectable at its head.
fn allocateZeroed(tc: Tc, size: usize) view.Col {
    return view.asCol(c.MVM_gc_allocate_zeroed(tc, size).?);
}

/// Allocates a new STable, based on the specified thread context, REPR and
/// meta-object. (allocation.c:53-68)
pub fn allocateStable(tc: Tc, repr: *const c.MVMREPROps, how: Object) STable {
    // MVMROOT(tc, how) { ... }
    var rooted_how = how;
    const r = moar.root(tc, &rooted_how);
    defer r.pop(tc);
    const header = allocateZeroed(tc, @sizeOf(c.MVMSTable));
    view.flags1(header).* = .{ .stable = true };
    const st = view.asStable(header);
    st.header.size = @sizeOf(c.MVMSTable);
    st.header.owner = tc.thread_id;
    st.REPR = repr;
    st.type_cache_id = c.MVM_6model_next_type_cache_id(tc);
    st.debug_name = null;
    moar.assignRef(tc, &st.header, &st.HOW, rooted_how);
    return st;
}

/// Allocates a new type object. (allocation.c:70-81)
pub fn allocateTypeObject(tc: Tc, st: STable) Object {
    // MVMROOT(tc, st) { ... }
    var rooted_st = st;
    const r = moar.root(tc, &rooted_st);
    defer r.pop(tc);
    const header = allocateZeroed(tc, @sizeOf(c.MVMObject));
    view.flags1(header).* = .{ .type_object = true };
    const obj = view.asObject(header);
    obj.header.size = @sizeOf(c.MVMObject);
    obj.header.owner = tc.thread_id;
    moar.assignRef(tc, &obj.header, &obj.st, rooted_st);
    return obj;
}

/// Allocates a new object, and points it at the specified STable.
/// (allocation.c:83-95)
pub fn allocateObject(tc: Tc, st: STable) Object {
    // MVMROOT(tc, st) { ... }
    var rooted_st = st;
    const r = moar.root(tc, &rooted_st);
    defer r.pop(tc);
    const obj = view.asObject(allocateZeroed(tc, rooted_st.size));
    obj.header.size = @truncate(rooted_st.size);
    obj.header.owner = tc.thread_id;
    moar.assignRef(tc, &obj.header, &obj.st, rooted_st);
    if (rooted_st.mode_flags & c.MVM_FINALIZE_TYPE != 0)
        finalize.addToQueue(tc, obj);
    return obj;
}

/// Allocates a new heap frame. (allocation.c:97-104)
pub fn allocateFrame(tc: Tc) Frame {
    const header = allocateZeroed(tc, @sizeOf(c.MVMFrame));
    view.flags1(header).* = .{ .frame = true };
    const f = view.asFrame(header);
    f.header.size = @sizeOf(c.MVMFrame);
    f.header.owner = tc.thread_id;
    return f;
}

// ---- the C ABI -------------------------------------------------------------

fn allocateNurseryExport(tc: [*c]c.MVMThreadContext, size: usize) callconv(.c) ?*anyopaque {
    return allocateNursery(tc, size);
}

fn allocateStableExport(tc: [*c]c.MVMThreadContext, repr: [*c]const c.MVMREPROps, how: [*c]c.MVMObject) callconv(.c) [*c]c.MVMSTable {
    return allocateStable(tc, repr, how);
}

fn allocateTypeObjectExport(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable) callconv(.c) [*c]c.MVMObject {
    return allocateTypeObject(tc, st);
}

fn allocateObjectExport(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable) callconv(.c) [*c]c.MVMObject {
    return allocateObject(tc, st);
}

fn allocateFrameExport(tc: [*c]c.MVMThreadContext) callconv(.c) [*c]c.MVMFrame {
    return allocateFrame(tc);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&allocateNurseryExport, .{ .name = "MVM_gc_allocate_nursery", .visibility = visibility });
    @export(&allocateStableExport, .{ .name = "MVM_gc_allocate_stable", .visibility = visibility });
    @export(&allocateTypeObjectExport, .{ .name = "MVM_gc_allocate_type_object", .visibility = visibility });
    @export(&allocateObjectExport, .{ .name = "MVM_gc_allocate_object", .visibility = visibility });
    @export(&allocateFrameExport, .{ .name = "MVM_gc_allocate_frame", .visibility = visibility });
}
