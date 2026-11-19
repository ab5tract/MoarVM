//! The VM array's collector hooks: `gc_mark`, `describe_refs` and
//! `gc_mark_repr_data` of src/6model/reprs/VMArray.c.
//!
//! Only the kinds whose slots hold collectable references (OBJ and STR,
//! `holds_refs` in the kind table) have anything to mark or describe. Each
//! hook is one `kinds.dispatch` whose generic arm is empty, at compile
//! time, for the other ten kinds, and which does nothing for the six kinds
//! without storage (`Otherwise.nothing`, the C has no `default:` arm): of
//! the twelve generated arms two have work, as the C's two `case`s.
//!
//! Only the live window `[start, start + elems)` is visited, in index
//! order: slots a `shift` or `pop` left outside it are not kept alive
//! (va-kind-differences.md rows 4, 18c, 20). The mark presizes the worklist
//! for `elems` and then adds without capacity checks, as the C, so the
//! collector's worklist grows exactly as before.
const moar = @import("moar");
const c = moar.c;
const kinds = @import("kinds.zig");
const elements = @import("elements.zig");
const storage = @import("storage.zig");

const Kind = kinds.Kind;
const Tc = [*c]c.MVMThreadContext;
const St = [*c]c.MVMSTable;
const Worklist = [*c]c.MVMGCWorklist;
const Body = c.MVMArrayBody;

/// `VMArray_gc_mark` (VMArray.c:68-109): nothing for an empty array, else
/// the arm of the slot type (row 4).
pub fn gcMark(tc: Tc, st: St, data: ?*anyopaque, worklist: Worklist) callconv(.c) void {
    // Loaded first, read only after the empty check (VMArray.c:69, 76, 79):
    // a stubbed STable's empty objects are marked before it has REPR data.
    const repr_data = elements.reprDataOf(st);
    const body = elements.bodyOf(data);
    if (body.elems == 0) return;
    kinds.dispatch(storage.derefReprData(repr_data).slot_type, markArm, .{ tc, body, worklist }, kinds.Otherwise.nothing);
}

/// gc_mark for kind `k`: empty unless `k` holds references; for OBJ and
/// STR, `MVM_gc_worklist_presize_for(elems)` and then the address of each
/// live slot in index order, through the `include_gen2` no-check add or
/// the other as the worklist says.
///
/// The slots pointer is taken raw (`[*c]`), as the C's `slots += start`:
/// the `include_gen2` add of a non-debug build only stores slot addresses
/// and reads nothing, so NULL slots (an array a recompose left without
/// storage) are pushed as addresses as in the C, whose collector faults
/// later. The other add (and every add under MVM_GC_DEBUG) reads the first
/// slot at once; for NULL slots that read is the C's fault, made here
/// before the loop at that slot's address (`moar.nullDeref`). Slot
/// addresses stay `[*c]` (`slots + i`, never `&slots[i]`), so a NULL base
/// never becomes a non-optional pointer.
fn markArm(comptime k: Kind, tc: Tc, body: *Body, worklist: Worklist) void {
    if (comptime !kinds.info(k).holds_refs) return;
    const element_count = body.elems;
    const raw = @field(body.slots, kinds.info(k).member);
    const slots = raw + body.start;
    // The count is an MVMuint64, as elems (upstream e9dee2a3e).
    c.MVM_gc_worklist_presize_for(tc, worklist, element_count);
    if (raw == null and (c.MVM_GC_DEBUG != 0 or worklist.*.include_gen2 == 0))
        moar.nullDeref(body.start *% kinds.info(k).elem_size);
    var i: u64 = 0;
    if (worklist.*.include_gen2 != 0) {
        while (i < element_count) : (i += 1) moar.worklistAddIncludeGen2Nocheck(tc, worklist, slots + i);
    } else {
        while (i < element_count) : (i += 1) moar.worklistAddNoIncludeGen2Nocheck(tc, worklist, slots + i);
    }
}

/// `describe_refs` (VMArray.c:1521-1550): each live element of an OBJ or
/// STR array reported with its index from `start` (row 38).
pub fn describeRefs(tc: Tc, ss: [*c]c.MVMHeapSnapshotState, st: St, data: ?*anyopaque) callconv(.c) void {
    const repr_data = elements.reprDataOf(st);
    const body = elements.bodyOf(data);
    // The C reads the slot type at once (VMArray.c:1528).
    kinds.dispatch(storage.derefReprData(repr_data).slot_type, describeArm, .{ tc, ss, body }, kinds.Otherwise.nothing);
}

/// describe_refs for kind `k`: empty unless `k` holds references; for OBJ
/// and STR `MVM_profile_heap_add_collectable_rel_idx(slot, i)` for each
/// live slot (NULL ones are skipped by that function). The C has no early
/// return for `elems == 0` (its loop runs no iteration); here the slots
/// are not formed then, since they may be NULL.
fn describeArm(comptime k: Kind, tc: Tc, ss: [*c]c.MVMHeapSnapshotState, body: *Body) void {
    if (comptime !kinds.info(k).holds_refs) return;
    const n = body.elems;
    if (n == 0) return;
    const slots = kinds.slots(k, body) + body.start;
    var i: u64 = 0;
    while (i < n) : (i += 1) c.MVM_profile_heap_add_collectable_rel_idx(tc, ss, @ptrCast(slots[i]), i);
}

/// `gc_mark_repr_data` (VMArray.c:118-123): the element type, if the
/// STable has REPR data.
pub fn gcMarkReprData(tc: Tc, st: St, worklist: Worklist) callconv(.c) void {
    const repr_data: ?*c.MVMArrayREPRData = @ptrCast(@alignCast(st.*.REPR_data));
    const rd = repr_data orelse return;
    moar.worklistAdd(tc, worklist, &rd.elem_type);
}

comptime {
    const R = c.MVMREPROps;
    for (.{ .{ "gc_mark", gcMark }, .{ "describe_refs", describeRefs }, .{ "gc_mark_repr_data", gcMarkReprData } }) |e| {
        if (*const @TypeOf(e[1]) != @typeInfo(@FieldType(R, e[0])).optional.child)
            @compileError("mark.zig: " ++ e[0] ++ " does not have the C signature");
    }
}
