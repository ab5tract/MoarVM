//! Typed views of the collector's C structures, for the native GC ports:
//! the pointer types the ports use in place of translate-c's `[*c]T`, the
//! `flags1`/`flags2` bytes of `MVMCollectable` as packed structs, the
//! `gc_status` word of `MVMThreadContext` as a typed status, and the view
//! changes between a collectable and the object, STable or frame it heads.
//! The accessors here are the only `@ptrCast(@alignCast(…))` sites of the
//! ports outside the C ABI. Every layout is the C's, asserted at comptime
//! against the constants of src/6model/6model.h and
//! src/core/threadcontext.h, so a header change fails the build. A plain
//! module: it exports nothing.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const atomic = @import("atomic.zig");

// ---- typed pointers ------------------------------------------------------

pub const Tc = *c.MVMThreadContext;
pub const Instance = *c.MVMInstance;
pub const Col = *c.MVMCollectable;
/// The address of a collectable pointer slot, as the worklist and the temp
/// roots hold it; the slot may hold NULL.
pub const ColSlot = *?*c.MVMCollectable;
pub const Object = *c.MVMObject;
pub const STable = *c.MVMSTable;
pub const Frame = *c.MVMFrame;
pub const Worklist = *c.MVMGCWorklist;
pub const Gen2 = *c.MVMGen2Allocator;
pub const Thread = *c.MVMThread;

// ---- the collectable flags (src/6model/6model.h) ---------------------------

/// `MVMCollectable.flags1`: what kind of collectable this is, and the
/// serialization and object-id bits. Every field defaults to clear, so
/// `.{ .stable = true }` is the C's `flags1 = MVM_CF_STABLE`.
pub const Flags1 = packed struct(u8) {
    type_object: bool = false,
    stable: bool = false,
    frame: bool = false,
    serialization_index_allocated: bool = false,
    has_object_id: bool = false,
    never_repossess: bool = false,
    _pad: u2 = 0,
};

/// `MVMCollectable.flags2`: the collector's own bits.
pub const Flags2 = packed struct(u8) {
    nursery_seen: bool = false,
    second_gen: bool = false,
    in_gen2_root_list: bool = false,
    gen2_live: bool = false,
    forwarder_valid: bool = false,
    ref_from_gen2: bool = false,
    debug_in_gen2_free_list: bool = false,
    _pad: u1 = 0,
};

/// The byte of a flags view with only the field `name` set.
fn onlyBit(comptime F: type, comptime name: []const u8) u8 {
    var f: F = @bitCast(@as(u8, 0));
    @field(f, name) = true;
    return @bitCast(f);
}

comptime {
    // MVMCollectableFlags1 (6model.h); the C spells the fourth one SERIALZATION.
    std.debug.assert(onlyBit(Flags1, "type_object") == c.MVM_CF_TYPE_OBJECT);
    std.debug.assert(onlyBit(Flags1, "stable") == c.MVM_CF_STABLE);
    std.debug.assert(onlyBit(Flags1, "frame") == c.MVM_CF_FRAME);
    std.debug.assert(onlyBit(Flags1, "serialization_index_allocated") == c.MVM_CF_SERIALZATION_INDEX_ALLOCATED);
    std.debug.assert(onlyBit(Flags1, "has_object_id") == c.MVM_CF_HAS_OBJECT_ID);
    std.debug.assert(onlyBit(Flags1, "never_repossess") == c.MVM_CF_NEVER_REPOSSESS);
}

comptime {
    // MVMCollectableFlags2 (6model.h).
    std.debug.assert(onlyBit(Flags2, "nursery_seen") == c.MVM_CF_NURSERY_SEEN);
    std.debug.assert(onlyBit(Flags2, "second_gen") == c.MVM_CF_SECOND_GEN);
    std.debug.assert(onlyBit(Flags2, "in_gen2_root_list") == c.MVM_CF_IN_GEN2_ROOT_LIST);
    std.debug.assert(onlyBit(Flags2, "gen2_live") == c.MVM_CF_GEN2_LIVE);
    std.debug.assert(onlyBit(Flags2, "forwarder_valid") == c.MVM_CF_FORWARDER_VALID);
    std.debug.assert(onlyBit(Flags2, "ref_from_gen2") == c.MVM_CF_REF_FROM_GEN2);
    std.debug.assert(onlyBit(Flags2, "debug_in_gen2_free_list") == c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST);
}

comptime {
    // The bytes the views overlay.
    std.debug.assert(@FieldType(c.MVMCollectable, "flags1") == u8);
    std.debug.assert(@FieldType(c.MVMCollectable, "flags2") == u8);
}

/// `col->flags1` through its view; reads and writes are the C byte's.
pub inline fn flags1(col: Col) *Flags1 {
    return @ptrCast(&col.flags1);
}

/// `col->flags2` through its view; reads and writes are the C byte's.
pub inline fn flags2(col: Col) *Flags2 {
    return @ptrCast(&col.flags2);
}

// ---- the GC status (src/core/threadcontext.h) ------------------------------

/// The types live in `atomic.zig`, which must build without the C headers
/// for its host tests; they are asserted against the C here.
pub const Status = atomic.Status;
pub const Suspend = atomic.Suspend;
pub const GcStatus = atomic.GcStatus;

comptime {
    std.debug.assert(@FieldType(c.MVMThreadContext, "gc_status") == usize);
    std.debug.assert(@backingInt(Status.none) == c.MVMGCStatus_NONE);
    std.debug.assert(@backingInt(Status.interrupt) == c.MVMGCStatus_INTERRUPT);
    std.debug.assert(@backingInt(Status.unable) == c.MVMGCStatus_UNABLE);
    std.debug.assert(@backingInt(Status.stolen) == c.MVMGCStatus_STOLEN);
    const word = struct {
        fn of(s: Suspend) usize {
            return @bitCast(GcStatus{ .status = .none, .@"suspend" = s });
        }
    }.of;
    std.debug.assert(word(.none) == c.MVMSuspendState_NONE);
    std.debug.assert(word(.request) == c.MVMSuspendState_SUSPEND_REQUEST);
    std.debug.assert(word(.suspended) == c.MVMSuspendState_SUSPENDED);
    std.debug.assert(word(.suspended) == c.MVMSUSPENDSTATUS_MASK);
    // The status is the bits below the mask.
    std.debug.assert(@as(usize, @bitCast(GcStatus{ .status = .stolen, .@"suspend" = .none })) == c.MVMSUSPENDSTATUS_MASK >> 2);
}

/// `&tc->gc_status`, for the typed atomics (`atomic.loadStatus` and friends).
pub inline fn gcStatus(tc: Tc) *usize {
    return &tc.gc_status;
}

// ---- view changes --------------------------------------------------------

/// The collectable at the head of `p`: any pointer to an `MVMCollectable`
/// or to a struct that begins with one (`MVMObject`, `MVMSTable`,
/// `MVMFrame`, the REPR bodies), or an untyped pointer to one.
pub inline fn asCol(p: anytype) Col {
    return @ptrCast(@alignCast(p));
}

/// `col` as the object it heads. Unchecked at every debug level: an object
/// is the default kind (no flag says "object"; a type object is one too).
pub inline fn asObject(col: Col) Object {
    return @ptrCast(@alignCast(col));
}

/// `col` as the STable it heads; at `MVM_GC_DEBUG` 1 and up a panic if its
/// `MVM_CF_STABLE` flag is clear.
pub inline fn asStable(col: Col) STable {
    if (comptime c.MVM_GC_DEBUG >= 1) {
        if (!flags1(col).stable)
            c.MVM_panic(1, "Collectable viewed as an STable has no MVM_CF_STABLE flag");
    }
    return @ptrCast(@alignCast(col));
}

/// `col` as the frame it heads; at `MVM_GC_DEBUG` 1 and up a panic if its
/// `MVM_CF_FRAME` flag is clear.
pub inline fn asFrame(col: Col) Frame {
    if (comptime c.MVM_GC_DEBUG >= 1) {
        if (!flags1(col).frame)
            c.MVM_panic(1, "Collectable viewed as a frame has no MVM_CF_FRAME flag");
    }
    return @ptrCast(@alignCast(col));
}
