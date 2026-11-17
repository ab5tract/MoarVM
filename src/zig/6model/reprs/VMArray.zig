//! The VMArray REPR: MoarVM's dynamic array of objects, strings or native
//! numbers (`MVMArray`, src/6model/reprs/VMArray.h), in place of
//! src/6model/reprs/VMArray.c. This file is its table of contents and holds
//! no logic of its own:
//!
//! - `allocator`, the one allocator of the array's slots and REPR data;
//! - `VMArray`, the REPR's declaration: its name, ID and the function of
//!   each vtable slot it implements, under the slot's name. `repr.Ops`
//!   (src/zig/6model/repr.zig) builds the table from it and fills every
//!   slot it does not name with the C default, as the C's
//!   `MVM_REPR_DEFAULT_*` macros do;
//! - `table`, that table, and the ten C symbols of VMArray.h, exported with
//!   the header's names and signatures.
//!
//! The functions live in vmarray/, one file per concern:
//!
//! - kinds.zig: the twelve slot kinds with storage, stated once, and
//!   `dispatch`, the one switch on an array's runtime slot type;
//! - storage.zig: allocating, growing, copying and freeing slot storage
//!   and REPR data, over an allocator given at compile time;
//! - elements.zig: the element operations (the positional functions,
//!   `elems`, `copy_to`, `gc_free`, `unmanaged_size`) and the per-kind entry
//!   points;
//! - mark.zig: `gc_mark`, `describe_refs`, `gc_mark_repr_data`;
//! - serial.zig: `type_object_for`, `compose`, `gc_free_repr_data` and
//!   serialization;
//! - spesh.zig (imported as `spesh_hooks`): the specializer hook and the
//!   JIT's fast-path lookup.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const repr = @import("../repr.zig");
const storage = @import("vmarray/storage.zig");
const elements = @import("vmarray/elements.zig");
const mark = @import("vmarray/mark.zig");
const serial = @import("vmarray/serial.zig");
const spesh_hooks = @import("vmarray/spesh.zig");

/// The array's allocator (spec 5.4): every slot buffer and every REPR data
/// block is allocated, resized and freed through it, and only through it.
/// It must be backed by MoarVM's C allocator (src/core/alloc.h), because
/// outside C code hands the array buffers it got from that allocator and
/// frees the array's (traces/llm/bench/va-adoption-audit.md), and it must
/// ignore the length it is given back on free and resize (storage.zig
/// explains why).
/// Changing the array's allocator is a change to this line.
const allocator: std.mem.Allocator = moar.mvm_allocator;

/// The slot storage over `allocator`.
const S = storage.Storage(struct {
    pub fn get() std.mem.Allocator {
        return allocator;
    }
});
/// The element operations over that storage.
const E = elements.Elements(S);
/// The type-level hooks over that storage.
const Ser = serial.Serial(S);

/// The REPR as `repr.Ops` reads it: each public declaration fills the
/// vtable slot of its name (the nested `pos_funcs` the slots of
/// `MVMREPROps_Positional`), in the C table's order. Not declared, so the
/// C defaults: `initialize` and `change_type`, `gc_cleanup` (null), and
/// `attr_funcs`, `box_funcs`, `ass_funcs` (the `MVM_REPR_DEFAULT_*`
/// functions), exactly as VMArray.c's table.
const VMArray = struct {
    pub const name = "VMArray";
    pub const ID = c.MVM_REPR_ID_VMArray;
    // `table` below is built from this struct, and this slot refers to
    // `table`: a cycle that compiles because the slot needs only `&table`,
    // the address of a container-level constant, which Zig knows without
    // evaluating the constant's initializer. A slot whose value used a
    // value of `table` (`table.name`) would be a dependency loop, since
    // `repr.Ops` reads every slot's value to build `table`.
    pub const type_object_for = Ser.typeObjectFor(&table);
    /// The C function itself: serialization.c compares against it.
    pub const allocate = &c.MVM_gc_allocate_object;
    pub const copy_to = E.copyTo;
    pub const pos_funcs = struct {
        pub const at_pos = E.atPos;
        pub const bind_pos = E.bindPos;
        pub const set_elems = E.setElems;
        pub const push = E.push;
        pub const pop = E.pop;
        pub const unshift = E.unshift;
        pub const shift = E.shift;
        pub const slice = E.aslice;
        pub const splice = E.asplice;
        pub const at_pos_multidim = E.atPosMultidim;
        pub const bind_pos_multidim = E.bindPosMultidim;
        pub const dimensions = E.dimensions;
        pub const set_dimensions = E.setDimensions;
        pub const get_elem_storage_spec = E.getElemStorageSpec;
        pub const pos_as_atomic = E.posAsAtomic;
        pub const pos_as_atomic_multidim = E.posAsAtomicMultidim;
        pub const write_buf = E.writeBuf;
        pub const read_buf = E.readBuf;
    };
    pub const elems = E.elems;
    pub const get_storage_spec = E.getStorageSpec;
    pub const serialize = Ser.serialize;
    pub const deserialize = Ser.deserialize;
    pub const serialize_repr_data = Ser.serializeReprData;
    pub const deserialize_repr_data = Ser.deserializeReprData;
    pub const deserialize_stable_size = Ser.deserializeStableSize;
    pub const gc_mark = mark.gcMark;
    pub const gc_free = E.gcFree;
    pub const gc_mark_repr_data = mark.gcMarkReprData;
    pub const gc_free_repr_data = Ser.gcFreeReprData;
    pub const compose = Ser.compose;
    pub const spesh = spesh_hooks.spesh;
    pub const unmanaged_size = E.unmanagedSize;
    pub const describe_refs = mark.describeRefs;
};

/// The array's vtable, with static storage as the C's `VMArray_this_repr`.
/// `VMArray.type_object_for` holds its address (see there).
const table: c.MVMREPROps = repr.Ops(VMArray);

/// `MVMArray_initialize`: the table's address, as the C returns
/// `&VMArray_this_repr`.
fn initialize(tc: [*c]c.MVMThreadContext) callconv(.c) [*c]const c.MVMREPROps {
    _ = tc;
    return &table;
}

/// The exports: the ten symbols VMArray.h declares, each the address of a
/// function above or of an instantiation of one (`atPosKind(k).withRoot`
/// is `at_pos` for kind `k` with no register kind; the JIT lookup is
/// generated over `E`).
const exports = .{
    .{ "MVMArray_initialize", &initialize },
    .{ "MVM_VMArray_at_pos", &E.atPos },
    .{ "MVM_VMArray_at_pos_s", &E.atPosKind(.str).withRoot },
    .{ "MVM_VMArray_at_pos_i", &E.atPosKind(.i64).withRoot },
    .{ "MVM_VMArray_at_pos_u", &E.atPosKind(.u64).withRoot },
    .{ "MVM_VMArray_at_pos_n", &E.atPosKind(.n64).withRoot },
    .{ "MVM_VMArray_at_pos_o", &E.atPosKind(.obj).withRoot },
    .{ "MVM_VMArray_bind_pos", &E.bindPos },
    .{ "MVM_VMArray_push", &E.push },
    .{ "MVM_VMArray_find_fast_impl_for_jit", &spesh_hooks.findFastImplForJit(E) },
};

// Under -Dlto the exports are protected, as the other Zig exports
// (gc/worklist.zig): calls from inside libmoar bind to them.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

// Generates one `@export` per entry of `exports`, after checking that the
// function has exactly the type of the header's declaration of that name
// (translate-c's extern of it; only its type is taken, so the extern is
// not referenced).
comptime {
    for (exports) |e| {
        if (@TypeOf(e[1].*) != @TypeOf(@field(c, e[0])))
            @compileError("VMArray.zig: " ++ e[0] ++ " does not have the header's signature");
        @export(e[1], .{ .name = e[0], .visibility = visibility });
    }
}
