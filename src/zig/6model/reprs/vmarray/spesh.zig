//! The VM array's hooks into the specializer and the JIT: the REPR's
//! `spesh` function, which rewrites `create` and `elems` on a known array
//! type, and `MVM_VMArray_find_fast_impl_for_jit`, which hands the JIT the
//! two element functions it may call directly, as
//! src/6model/reprs/VMArray.c does them (va-kind-differences.md rows 36,
//! 40, 41).
const moar = @import("moar");
const c = moar.c;
const kinds = @import("kinds.zig");
const storage = @import("storage.zig");
const elements = @import("elements.zig");

const Kind = kinds.Kind;
const Tc = [*c]c.MVMThreadContext;
const St = [*c]c.MVMSTable;
const Reg = c.MVMRegister;

/// The leading field of `MVMOpInfo` (src/core/interp.h), which translate-c
/// leaves opaque because the struct has bit-fields: `MVMuint16 opcode` at
/// offset 0. Only this field is read. `test/vmarray_serial_test.zig` checks
/// the offset and size against the C compiler (`layout_probe.c`), as
/// orchestrate.zig does for its mirror of `MVMDebugServerData`.
pub const OpInfoHead = extern struct {
    opcode: c.MVMuint16,
};

/// `ins->info->opcode`. The specializer never hands the hook an
/// instruction without op info; were it NULL, this faults where the C's
/// read does.
inline fn opcodeOf(info: ?*const c.MVMOpInfo) c.MVMuint16 {
    const p = info orelse moar.nullDeref(@offsetOf(OpInfoHead, "opcode"));
    return @as(*const OpInfoHead, @ptrCast(@alignCast(p))).opcode;
}

/// The literal operands the rewrites store, `MVMint16` as the C's: they are
/// constants that fit, which the compiler checks here (where the C would
/// truncate silently).
const array_size_lit: c.MVMint16 = @sizeOf(c.MVMArray);
const elems_offset_lit: c.MVMint16 = @offsetOf(c.MVMArray, "body") + @offsetOf(c.MVMArrayBody, "elems");

/// The REPR's `spesh` (VMArray.c:1479-1512, row 36), the same instructions
/// with the same operands:
/// - `create` of a type without `MVM_FINALIZE_TYPE` becomes
///   `sp_fastcreate target, sizeof(MVMArray), <spesh slot of the STable>`;
///   the type register's usage by it is deleted and the target is known to
///   be a concrete object of the type.
/// - `elems` becomes `sp_get_i64 target, obj, offsetof(MVMArray,
///   body.elems)`, with the comment "specialized from elems on VMArray".
/// Every other instruction is left as it is.
pub fn spesh(tc: Tc, st: St, g: [*c]c.MVMSpeshGraph, bb: [*c]c.MVMSpeshBB, ins: [*c]c.MVMSpeshIns) callconv(.c) void {
    _ = bb;
    switch (opcodeOf(ins.*.info)) {
        c.MVM_OP_create => if ((st.*.mode_flags & c.MVM_FINALIZE_TYPE) == 0) {
            const target = ins.*.operands[0];
            const type_reg = ins.*.operands[1];
            const tgt_facts = c.MVM_spesh_get_facts(tc, g, target);

            ins.*.info = c.MVM_op_get_op(c.MVM_OP_sp_fastcreate);
            ins.*.operands = @ptrCast(@alignCast(c.MVM_spesh_alloc(tc, g, 3 * @sizeOf(c.MVMSpeshOperand))));
            ins.*.operands[0] = target;
            ins.*.operands[1].lit_i16 = array_size_lit;
            ins.*.operands[2].lit_i16 = c.MVM_spesh_add_spesh_slot(tc, g, @ptrCast(st));
            c.MVM_spesh_usages_delete_by_reg(tc, g, type_reg, ins);

            tgt_facts.*.flags |= c.MVM_SPESH_FACT_KNOWN_TYPE | c.MVM_SPESH_FACT_CONCRETE;
            tgt_facts.*.type = st.*.WHAT;
        },
        c.MVM_OP_elems => {
            const target = ins.*.operands[0];
            const obj = ins.*.operands[1];

            c.MVM_spesh_graph_add_comment(tc, g, ins, "specialized from elems on VMArray");

            ins.*.info = c.MVM_op_get_op(c.MVM_OP_sp_get_i64);
            ins.*.operands = @ptrCast(@alignCast(c.MVM_spesh_alloc(tc, g, 3 * @sizeOf(c.MVMSpeshOperand))));
            ins.*.operands[0] = target;
            ins.*.operands[1] = obj;
            ins.*.operands[2].lit_i16 = elems_offset_lit;
        },
        else => {},
    }
}

/// The C types of the two static functions the JIT calls directly
/// (VMArray.c:1559 `vmarray_bind_pos_int64`, 1584 `vmarray_at_pos_int64`):
/// the positional functions without the root and, for at_pos, without the
/// register kind. The JIT builds its call from these (src/jit/graph.c).
pub const JitAtPos = fn (Tc, St, ?*anyopaque, c.MVMint64, [*c]Reg) callconv(.c) void;
pub const JitBindPos = fn (Tc, St, ?*anyopaque, c.MVMint64, Reg) callconv(.c) void;

/// One devirtualization `MVM_VMArray_find_fast_impl_for_jit` offers: for
/// `op` with the register kind of `slot` (`info(slot).reg_kind`) on an
/// array of kind `slot`, the JIT may call `function`.
const FastImpl = struct { op: c_int, slot: Kind, function: *const anyopaque };

/// The table of row 41 over the element operations `E`: `atpos_i` and
/// `bindpos_i` with an `int64` register on an I64 array, `atpos_u` and
/// `bindpos_u` with a `uint64` register on a U64 array, the I64
/// instantiations serving both (8-byte elements, no kind check, row 40).
fn fastImpls(comptime E: type) [4]FastImpl {
    const at: *const JitAtPos = &E.atPosKind(.i64).jit;
    const bind: *const JitBindPos = &E.bindPosKind(.i64).jit;
    return .{
        .{ .op = c.MVM_OP_atpos_i, .slot = .i64, .function = at },
        .{ .op = c.MVM_OP_atpos_u, .slot = .u64, .function = at },
        .{ .op = c.MVM_OP_bindpos_i, .slot = .i64, .function = bind },
        .{ .op = c.MVM_OP_bindpos_u, .slot = .u64, .function = bind },
    };
}

/// The function `MVM_VMArray_find_fast_impl_for_jit` (VMArray.c:1605-1645)
/// over the element operations `E` (`elements.Elements(S)`). The `inline
/// for` generates, per entry of `fastImpls(E)`, the C's `case` for that
/// op: a register kind other than the entry's gives NULL before the REPR
/// data is read; then the entry's function if the array's slot type is the
/// entry's, else NULL. Any other op gives NULL without reading anything.
pub fn findFastImplForJit(comptime E: type) fn (Tc, St, c.MVMint16, c.MVMuint16) callconv(.c) ?*anyopaque {
    return struct {
        fn findFastImplForJit(tc: Tc, st: St, op: c.MVMint16, kind: c.MVMuint16) callconv(.c) ?*anyopaque {
            _ = tc;
            const repr_data = elements.reprDataOf(st);
            inline for (comptime fastImpls(E)) |e| {
                if (op == e.op) {
                    if (kind != kinds.info(e.slot).reg_kind) return null;
                    if (storage.derefReprData(repr_data).slot_type == @backingInt(e.slot)) return @constCast(e.function);
                    return null;
                }
            }
            return null;
        }
    }.findFastImplForJit;
}
