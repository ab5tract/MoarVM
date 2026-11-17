//! The VM array's type-level hooks: creating a type (`type_object_for`),
//! composing it (`compose`, `spec_to_repr_data`), freeing its REPR data
//! (`gc_free_repr_data`), and serialization (`serialize`, `deserialize`,
//! `serialize_repr_data`, `deserialize_repr_data`,
//! `deserialize_stable_size`), as src/6model/reprs/VMArray.c does them.
//!
//! The element loops of `serialize` and `deserialize` are written once,
//! generic over the kind, and reached through `kinds.dispatch`, like the
//! element operations of elements.zig. Which serialization reader and writer
//! a kind uses is a column of the kind table (`KindInfo.reader`/`.writer`);
//! the conversion between an element and what the reader returns or the
//! writer takes (`fromWire`, `toWire`) follows the element's type class.
//! `spec_to_repr_data` finds the kind for a storage spec by walking the kind
//! table and `kinds.unstored` (the six kinds without storage) for the
//! element type with that width and signedness.
//!
//! REPR data is created and freed through the storage `S`
//! (`storage.Storage(Source)`), so through the REPR's one allocator.
//! Pointers that can be NULL on a path the C reaches (an STable's REPR data
//! during nested deserialization, a REPR's NULL function slot) are kept
//! optional until the C dereferences them and then fault as the C does
//! (`storage.derefReprData`, `moar.nullDeref`).
//!
//! "Row N" below is a row of traces/llm/bench/va-kind-differences.md.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const kinds = @import("kinds.zig");
const storage = @import("storage.zig");
const elements = @import("elements.zig");

const Kind = kinds.Kind;
// As in elements.zig: the thread context, STable, root and body pointers
// the VM passes are never NULL; REPR data and other REPRs' functions can be.
const Tc = [*c]c.MVMThreadContext;
const St = [*c]c.MVMSTable;
const Obj = [*c]c.MVMObject;
const Body = c.MVMArrayBody;
const Reader = [*c]c.MVMSerializationReader;
const Writer = [*c]c.MVMSerializationWriter;
const ReprData = c.MVMArrayREPRData;

/// The C's read through a REPR data pointer: the pointer, or the C's fault.
const need = storage.derefReprData;

/// The `default:` arm of `serialize` and `deserialize` (rows 34b, 35).
const unhandled = kinds.Otherwise{ .throw = "MVMArray: Unhandled slot type" };

/// The `sizeof(MVMArray)` the C stores in `st->size`.
const array_size: c.MVMuint32 = @sizeOf(c.MVMArray);

// ---- elements on the wire ---------------------------------------------

/// What kind `k`'s serialization reader returns, which is also what its
/// writer takes (checked below): `MVMint64`, `MVMnum64`, `MVMString *` or
/// `MVMObject *`.
fn Wire(comptime k: Kind) type {
    return @typeInfo(@TypeOf(@field(c, kinds.info(k).reader))).@"fn".return_type orelse @compileError("serial.zig: a generic reader");
}

comptime {
    for (kinds.kinds) |ki| {
        const W = @typeInfo(@TypeOf(@field(c, ki.writer))).@"fn".param_types[2] orelse @compileError("serial.zig: a generic writer");
        if (W != Wire(ki.kind)) @compileError("serial.zig: " ++ ki.reader ++ " and " ++ ki.writer ++ " disagree on the value type");
    }
}

/// Element `e` of kind `k` as its writer's argument, as the C's casts in
/// `serialize` make it (row 35): an integer as `MVMint64` (signed ones
/// sign-extended, unsigned ones zero-extended, so U64 above 2**63 is
/// written as the negative number with its bits), N32 widened to double, a
/// pointer as it is. The branch is on the element's type class.
inline fn toWire(comptime k: Kind, e: kinds.Elem(k)) Wire(k) {
    return switch (@typeInfo(kinds.Elem(k))) {
        .int => |i| if (i.signedness == .unsigned) @bitCast(@as(u64, e)) else e,
        .float, .pointer => e,
        else => comptime unreachable,
    };
}

/// What kind `k`'s reader returned as an element, as the C's casts in
/// `deserialize` make it (row 34a): an integer keeps its low bits (the C
/// stores the unsigned kinds through the signed members with unsigned
/// casts, the same bits), N32 rounded from the double, a pointer as it is.
inline fn fromWire(comptime k: Kind, v: Wire(k)) kinds.Elem(k) {
    const T = kinds.Elem(k);
    return switch (@typeInfo(T)) {
        .int => |i| @bitCast(@as(@Int(.unsigned, i.bits), @truncate(@as(u64, @bitCast(v))))),
        .float => @floatCast(v),
        .pointer => v,
        else => comptime unreachable,
    };
}

/// `serialize` for kind `k`, one element (the C's switch is inside its
/// element loop): element `i` of the live window through the kind's writer.
fn writeArm(comptime k: Kind, tc: Tc, body: *Body, writer: Writer, i: u64) void {
    @field(c, kinds.info(k).writer)(tc, writer, toWire(k, kinds.slots(k, body)[body.start +% i]));
}

/// `deserialize` for kind `k`: `elems` values through the kind's reader
/// into slots 0 to `elems - 1`, through `MVM_ASSIGN_REF` on `root` for the
/// kinds that hold references and as plain stores otherwise. As in the C's
/// macro the value is read first, then stored.
fn readArm(comptime k: Kind, tc: Tc, root: Obj, body: *Body, reader: Reader) void {
    var i: u64 = 0;
    while (i < body.elems) : (i += 1) {
        const v = @field(c, kinds.info(k).reader)(tc, reader);
        const slot = &kinds.slots(k, body)[i];
        if (comptime kinds.info(k).holds_refs) {
            moar.assignRef(tc, &root.*.header, slot, v);
        } else {
            slot.* = fromWire(k, v);
        }
    }
}

// ---- composition --------------------------------------------------------

/// Sets the REPR data to stored kind `k`: its slot type and element size.
fn setKind(repr_data: *ReprData, comptime k: Kind) void {
    repr_data.slot_type = @backingInt(k);
    repr_data.elem_size = kinds.info(k).elem_size;
}

/// `spec_to_repr_data`'s integer branch (row 31a): the kind whose element
/// is an integer of `bits` bits and that signedness, else the kind without
/// storage of that width and signedness (`elem_size` 0), else the throw
/// `unsupported`. The `inline for`s emit one comparison per integer kind
/// of that signedness (64, 32, 16 and 8 bits) and per entry of
/// `kinds.unstored` (4, 2 and 1 bits): the C's `switch (spec->bits)`.
fn setInt(tc: Tc, repr_data: *ReprData, bits: u16, comptime signedness: std.builtin.Signedness, comptime unsupported: [:0]const u8) void {
    inline for (kinds.kinds) |ki| {
        const t = @typeInfo(ki.Elem);
        if (comptime t == .int and t.int.signedness == signedness) {
            if (bits == t.int.bits) return setKind(repr_data, ki.kind);
        }
    }
    inline for (kinds.unstored) |un| {
        if (comptime un.signedness == signedness) {
            if (bits == un.bits) {
                repr_data.slot_type = un.slot_type;
                repr_data.elem_size = 0;
                return;
            }
        }
    }
    c.MVM_exception_throw_adhoc(tc, unsupported);
}

/// `spec_to_repr_data`'s num branch (row 31b): the num kind of `bits` bits
/// (one comparison per num kind), else "MVMArray: Unsupported num size".
fn setNum(tc: Tc, repr_data: *ReprData, bits: u16) void {
    inline for (kinds.kinds) |ki| {
        const t = @typeInfo(ki.Elem);
        if (comptime t == .float) {
            if (bits == t.float.bits) return setKind(repr_data, ki.kind);
        }
    }
    c.MVM_exception_throw_adhoc(tc, "MVMArray: Unsupported num size");
}

/// `spec_to_repr_data` (VMArray.c:1224-1319): the slot type and element
/// size for an element type's storage spec. `BP_INT` and `BP_UINT64` share
/// the integer branch and `is_unsigned`, not the box kind, picks the
/// signedness (row 31a); `BP_NUM` the num branch; `BP_STR` the STR kind;
/// any other box kind (an object type) changes nothing (row 31b; kept).
pub fn specToReprData(tc: Tc, repr_data: *ReprData, spec: [*c]const c.MVMStorageSpec) void {
    switch (spec.*.boxed_primitive) {
        c.MVM_STORAGE_SPEC_BP_UINT64, c.MVM_STORAGE_SPEC_BP_INT => if (spec.*.is_unsigned != 0) {
            setInt(tc, repr_data, spec.*.bits, .unsigned, "MVMArray: Unsupported uint size");
        } else {
            setInt(tc, repr_data, spec.*.bits, .signed, "MVMArray: Unsupported int size");
        },
        c.MVM_STORAGE_SPEC_BP_NUM => setNum(tc, repr_data, spec.*.bits),
        c.MVM_STORAGE_SPEC_BP_STR => setKind(repr_data, .str),
        else => {},
    }
}

/// `REPR(type)->get_storage_spec(tc, STABLE(type))`, the call through
/// another REPR's slot (which the C makes without a check: a NULL slot
/// jumps to address 0, and so faults here).
inline fn storageSpecOf(tc: Tc, t: Obj) [*c]const c.MVMStorageSpec {
    const f = t.*.st.*.REPR.*.get_storage_spec orelse moar.nullDeref(0);
    return f(tc, t.*.st);
}

/// `MVM_ASSIGN_REF(tc, &(st->header), repr_data->elem_type, t)` with the
/// STable's REPR data pointer as loaded, possibly NULL (a stubbed STable):
/// the macro's checks and write barrier come first, then the store, which
/// is where the C reads through NULL; this faults there too. Returns the
/// REPR data, then known not to be NULL.
fn assignElemType(tc: Tc, st: St, repr_data: ?*ReprData, t: Obj) *ReprData {
    if (repr_data) |rd| {
        moar.assignRef(tc, &st.*.header, &rd.elem_type, t);
        return rd;
    }
    var discarded: Obj = null;
    moar.assignRef(tc, &st.*.header, &discarded, t);
    moar.nullDeref(@offsetOf(ReprData, "elem_type"));
}

/// The type-level hooks over the slot storage `S` (a
/// `storage.Storage(Source)`): a namespace of functions, each with its
/// VMArray vtable slot's C type (`repr.Ops` checks them), plus
/// `typeObjectFor`, which builds the `type_object_for` function for a given
/// table. It has no state.
pub fn Serial(comptime S: type) type {
    return struct {
        /// `serialize` (VMArray.c:1428-1476): `elems`, then each element of
        /// the live window through its kind's writer (row 35). The kind
        /// switch is inside the element loop, as the C's: an empty array of
        /// a kind without storage writes its 0 and succeeds, a non-empty
        /// one throws after the count, and the REPR data is first read for
        /// the first element.
        pub fn serialize(tc: Tc, st: St, data: ?*anyopaque, writer: Writer) callconv(.c) void {
            const repr_data = elements.reprDataOf(st);
            const body = elements.bodyOf(data);
            c.MVM_serialization_write_int(tc, writer, @bitCast(body.elems));
            var i: u64 = 0;
            while (i < body.elems) : (i += 1) {
                kinds.dispatch(need(repr_data).slot_type, writeArm, .{ tc, body, writer, i }, unhandled);
            }
        }

        /// `deserialize` (VMArray.c:1364-1426) into a fresh body: `elems`
        /// read and `ssize = elems`; storage of `ssize` slots only when
        /// `ssize` is non-zero (no limit check; `start` stays 0), before
        /// the kind switch, then each element through its kind's reader
        /// (row 34a). A kind without storage throws "MVMArray: Unhandled
        /// slot type" even with no elements (row 34b); with elements the C
        /// has stored a zero-byte block (a malloc of 0 bytes) before that
        /// throw, where this leaves `slots` NULL: the allocator is never
        /// asked for zero bytes (va-kind-differences.md section 3, the one
        /// pointer-value difference).
        pub fn deserialize(tc: Tc, st: St, root: Obj, data: ?*anyopaque, reader: Reader) callconv(.c) void {
            const repr_data = elements.reprDataOf(st);
            const body = elements.bodyOf(data);
            body.elems = @bitCast(c.MVM_serialization_read_int(tc, reader));
            body.ssize = body.elems;
            if (body.ssize != 0) body.slots.any = S.alloc(body.ssize, need(repr_data).elem_size);
            kinds.dispatch(need(repr_data).slot_type, readArm, .{ tc, root, body, reader }, unhandled);
        }

        /// `serialize_repr_data` (VMArray.c:1341-1344): the element type.
        pub fn serializeReprData(tc: Tc, st: St, writer: Writer) callconv(.c) void {
            c.MVM_serialization_write_ref(tc, writer, need(elements.reprDataOf(st)).elem_type);
        }

        /// `deserialize_repr_data` (VMArray.c:1347-1362): new REPR data
        /// (allocated before the read, as the C), the element type read
        /// and stored through the write barrier, an object array until,
        /// when there is an element type, its STable is forced and
        /// `specToReprData` composes from its storage spec (row 33).
        pub fn deserializeReprData(tc: Tc, st: St, reader: Reader) callconv(.c) void {
            // OBJ, pointer-sized elements, as the C sets them (1352-1353).
            const repr_data = S.createReprData();
            const t = c.MVM_serialization_read_ref(tc, reader);
            moar.assignRef(tc, &st.*.header, &repr_data.elem_type, t);
            st.*.REPR_data = repr_data;
            if (t != null) {
                c.MVM_serialization_force_stable(tc, reader, t.*.st);
                specToReprData(tc, repr_data, storageSpecOf(tc, t));
            }
        }

        /// `deserialize_stable_size` (VMArray.c:1336-1338).
        pub fn deserializeStableSize(tc: Tc, st: St, reader: Reader) callconv(.c) void {
            _ = tc;
            _ = reader;
            st.*.size = array_size;
        }

        /// `compose` (VMArray.c:1320-1333): with an `array` entry whose
        /// `type` is not null, the type's storage spec is fetched, the
        /// element type stored, and then the kind set from the spec, so an
        /// "Unsupported ... size" throw leaves the new element type with
        /// the old kind (row 32). Live arrays of the type keep their
        /// storage and change kind in place.
        pub fn compose(tc: Tc, st: St, info_hash: Obj) callconv(.c) void {
            // A copy of the string constants, as the C takes it.
            const str_consts = tc.*.instance.*.str_consts;
            const repr_data: ?*ReprData = @ptrCast(@alignCast(st.*.REPR_data));
            const info = c.MVM_repr_at_key_o(tc, info_hash, str_consts.array);
            if (c.MVM_is_null(tc, info) != 0) return;
            const t = c.MVM_repr_at_key_o(tc, info, str_consts.type);
            if (c.MVM_is_null(tc, t) != 0) return;
            const spec = storageSpecOf(tc, t);
            specToReprData(tc, assignElemType(tc, st, repr_data, t), spec);
        }

        /// `gc_free_repr_data` (VMArray.c:126-128): frees the REPR data; an
        /// STable that has none (a stub never deserialized) is left alone,
        /// as the C's free of NULL does nothing.
        pub fn gcFreeReprData(tc: Tc, st: St) callconv(.c) void {
            _ = tc;
            const repr_data: ?*ReprData = @ptrCast(@alignCast(st.*.REPR_data));
            if (repr_data) |rd| S.destroyReprData(rd);
        }

        /// The `type_object_for` function of the REPR whose table is
        /// `this_repr` (VMArray.c:26-43). It generates one function per
        /// table (the C refers to its static `VMArray_this_repr`; here the
        /// table is a parameter because it is built from this function):
        /// a new STable for `this_repr` and `HOW`, rooted while its type
        /// object and its REPR data are made (an object array, row 2), then
        /// `WHAT` set through the write barrier, `size = sizeof(MVMArray)`
        /// and the REPR data stored; the result is `st->WHAT`. VMArray.zig
        /// passes the address of its own table:
        /// `pub const type_object_for = Ser.typeObjectFor(&table);`.
        pub fn typeObjectFor(comptime this_repr: *const c.MVMREPROps) fn (Tc, Obj) callconv(.c) Obj {
            return struct {
                fn typeObjectFor(tc: Tc, how: Obj) callconv(.c) Obj {
                    var st = c.MVM_gc_allocate_stable(tc, this_repr, how);
                    const r = moar.root(tc, &st);
                    defer r.pop(tc);
                    const obj = c.MVM_gc_allocate_type_object(tc, st);
                    const repr_data = S.createReprData();
                    moar.assignRef(tc, &st.*.header, &st.*.WHAT, obj);
                    st.*.size = array_size;
                    st.*.REPR_data = repr_data;
                    return st.*.WHAT;
                }
            }.typeObjectFor;
        }
    };
}
