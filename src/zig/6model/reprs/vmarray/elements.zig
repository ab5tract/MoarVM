//! The VM array's element operations: the positional functions of the
//! VMArray REPR (`at_pos`, `bind_pos`, `push`, `pop`, `shift`, `unshift`,
//! `slice`, `splice`, the buffer and atomic access, ...) and the per-kind
//! entry points, as src/6model/reprs/VMArray.c does them.
//!
//! The C writes each of these as a `switch` on the slot type with twelve
//! hand-copied arms. Here each is written once:
//!
//! - The operation itself (`atPos`, `push`, ...) does what does not depend
//!   on the kind (index fix-up, growth, moving `start`), in the C's order,
//!   and reaches the kind-dependent part through `kinds.dispatch`, the one
//!   generated `switch` on the slot type. Its last argument says what the
//!   C does for a slot type with no arm (the six kinds without storage).
//! - The kind-dependent part is an "arm": a function whose first parameter
//!   is the comptime `Kind`. One generic arm is instantiated per kind by
//!   `dispatch`. What differs per kind comes from the kind table
//!   (`kinds.info(k)`: element type, register member, accepted register
//!   kinds, whether it holds references) or from a comptime branch that
//!   cites its row of traces/llm/bench/va-kind-differences.md.
//!
//! Worked expansion, `atPos` on an array whose `slot_type` is 3 (I32):
//! `dispatch(3, Arm(.atpos).read, .{ tc, body, i, value, kind }, unhandledAtPos)`
//! generates a twelve-arm switch whose arm 3 calls `Arm(.atpos).read(.i32, ...)`,
//! which, with `info(.i32)` = { Elem = MVMint32, reg = "i64",
//! reg_kinds = { MVM_reg_int64 } }, is
//!
//! ```zig
//! if (kind != c.MVM_reg_int64)
//!     c.MVM_exception_throw_adhoc(tc, "MVMArray: atpos I32 expected int register");
//! if (i >= body.elems) value.i64 = 0
//! else value.i64 = body.slots.i32[body.start + i]; // sign-extended
//! ```
//!
//! which is the C's `case MVM_ARRAY_I32:` arm (VMArray.c:283-290).
//!
//! Nothing here allocates directly: slot memory goes through the storage
//! `S` (`storage.Storage(Source)`), whose allocator is the REPR's one
//! declared allocator. Every throw is `MVM_exception_throw_adhoc` with the
//! C's format string, after the same side effects as in the C: a rejected
//! `push` or `bind_pos` has already grown the array, a rejected `unshift`
//! may have made front room (rows 15a, 17a, 19b); a rejected `pop` leaves
//! the array as it was (row 18c, since upstream 27ebea0b8). The C's
//! bugs on defined paths are kept and cited, not fixed, except where the
//! C itself has been fixed (traces/llm/bench/cfix-mirror.md): then the
//! Zig follows the fixed C. The C's unsigned
//! arithmetic wraps; it is written with the wrapping operators here.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const kinds = @import("kinds.zig");
const storage = @import("storage.zig");

const Kind = kinds.Kind;
// Pointers the VM passes in and the C dereferences without a check, which
// are never NULL on any path: the thread context, the STable, the `data`
// body (`OBJECT_BODY` of an object, so an address inside it), the root
// object (the caller reached this function through its STable), the
// register and index pointers. Pointers that can be NULL on a path the C
// reaches go through `moar.nullDeref` instead (the slots, the REPR data,
// another REPR's functions, a splice's `from`).
const Tc = [*c]c.MVMThreadContext;
const St = [*c]c.MVMSTable;
const Obj = [*c]c.MVMObject;
const Reg = c.MVMRegister;
const Body = c.MVMArrayBody;

/// The body behind a REPR function's `data` (the C's `(MVMArrayBody *)data`),
/// never NULL (see above).
pub inline fn bodyOf(data: ?*anyopaque) *Body {
    return @ptrCast(@alignCast(data));
}

/// The STable's array REPR data pointer as the C loads it (`(MVMArrayREPRData
/// *)st->REPR_data`), possibly NULL: an STable stubbed during deserialization
/// can already have empty array objects (`storage.derefReprData`). It stays
/// optional until the C's first read through it, where `need` dereferences
/// it, so an early return or throw the C takes before that read comes first
/// here too.
pub inline fn reprDataOf(st: St) ?*const c.MVMArrayREPRData {
    return @ptrCast(@alignCast(st.*.REPR_data));
}

/// The C's read through a REPR data pointer: the pointer, or the C's fault.
const need = storage.derefReprData;

/// The slots of `body` as bytes, for the byte copies. NULL only where a
/// recompose to a kind without storage left the array without storage
/// while the C goes on to copy through it (undefined or a fault in the C,
/// va-kind-differences.md section 3): a fault at the null page here.
inline fn slotBytes(body: *Body) [*]u8 {
    return @ptrCast(body.slots.any orelse moar.nullDeref(0));
}

/// `o`, an object the C dereferences without a check that the VM may pass
/// as NULL (a splice's `from` is a raw register): the C's `REPR(o)` then
/// reads `o->st` and faults, and so does this, at the same offset.
inline fn objectOrFault(o: Obj) *c.MVMObject {
    if (o == null) moar.nullDeref(@offsetOf(c.MVMObject, "st"));
    return o;
}

/// Another REPR's function `f`, which the C calls without a check: a REPR
/// may leave a slot NULL (MVMContinuation's `elems`), and the C's call then
/// jumps to address 0 and faults; this faults at the null page too.
inline fn reprFn(f: anytype) @typeInfo(@TypeOf(f)).optional.child {
    return f orelse moar.nullDeref(0);
}

/// The body of an array object (`OBJECT_BODY(o)`).
inline fn objectBodyOf(o: Obj) *Body {
    return @ptrCast(@alignCast(moar.objectBody(o)));
}

/// `x` as the C's unsigned 64-bit value (an `MVMint64` converted to
/// `MVMuint64`).
inline fn u(x: i64) u64 {
    return @bitCast(x);
}

/// `x` as the C's `MVMint64` (an `MVMuint64` converted to `MVMint64`).
inline fn s(x: u64) i64 {
    return @bitCast(x);
}

// ---- the single-user check (VMArray.c:7-19) ---------------------------

/// `enter_single_user`: with `MVM_ARRAY_CONC_DEBUG` (VMArray.h) at 0, as it
/// is, the branch is comptime-false and nothing is emitted, so "Array may
/// not be used concurrently" is compiled out as in the C. The non-zero
/// branch is a transcription of the C's that has never been compiled
/// (Zig does not analyse a comptime-false branch) or run; a build that
/// sets the flag must check it first.
inline fn enterSingleUser(tc: Tc, body: *Body) void {
    if (comptime c.MVM_ARRAY_CONC_DEBUG != 0) {
        if (!moar.trycas(&body.in_use, @as(c.AO_t, 0), @as(c.AO_t, 1))) {
            c.MVM_dump_backtrace(tc);
            c.MVM_exception_throw_adhoc(tc, "Array may not be used concurrently");
        }
    }
}

/// `exit_single_user`: empty at `MVM_ARRAY_CONC_DEBUG == 0`; the non-zero
/// branch is unanalysed, as `enterSingleUser`'s.
inline fn exitSingleUser(body: *Body) void {
    if (comptime c.MVM_ARRAY_CONC_DEBUG != 0) body.in_use = 0;
}

// ---- indices ----------------------------------------------------------

/// The C's negative-index fix-up: `index += elems` (unsigned, wrapping,
/// converted back to signed) and "MVMArray: Index out of bounds" if it is
/// still negative. A non-negative index is returned as it is.
inline fn fromEnd(tc: Tc, index: i64, elems: u64) i64 {
    if (index >= 0) return index;
    const resolved = s(u(index) +% elems);
    if (resolved < 0) c.MVM_exception_throw_adhoc(tc, "MVMArray: Index out of bounds");
    return resolved;
}

/// `bind_pos`'s index (VMArray.c:485-493, and 1565-1575 for the JIT's):
/// from the end when negative, else the array first grows to `index + 1`
/// elements when the index is past `elems`. `index + 1` cannot wrap: the
/// index is non-negative there, at most 2**63 - 1.
inline fn bindIndex(comptime S: type, tc: Tc, st: St, body: *Body, index: i64) u64 {
    if (index < 0) return u(fromEnd(tc, index, body.elems));
    if (u(index) >= body.elems) S.setSize(tc, body, u(index) + 1, reprDataOf(st));
    return u(index);
}

// ---- elements and registers -------------------------------------------

/// The register member's type for kind `k` (`i64` for `.i32`).
fn RegMember(comptime k: Kind) type {
    return @FieldType(Reg, kinds.info(k).reg);
}

/// Writes element `e` of kind `k` into its register member, widened as the
/// C's read casts do (row 12d): a signed element sign-extended into `.i64`,
/// an unsigned one zero-extended into `.u64` (the C's pop and shift write
/// `.i64` with the same bits), N32 promoted exactly to double, a pointer
/// as it is. Zig's coercion does each of these widenings.
inline fn toReg(comptime k: Kind, value: *Reg, e: kinds.Elem(k)) void {
    @field(value, kinds.info(k).reg) = @as(RegMember(k), e);
}

/// The element of kind `k` a register holds, narrowed as the C's store
/// casts do (row 15d): an integer keeps its low bits (`@truncate`, never
/// `@intCast`; the unsigned kinds read `.u64`, the same bits as the C's
/// `.i64`), N64 to N32 rounds (`@floatCast`, x86-64's cvtsd2ss as the C:
/// a double outside float range becomes an infinity), a pointer as it is.
/// The switch is on the element's type class, at compile time.
inline fn fromReg(comptime k: Kind, value: Reg) kinds.Elem(k) {
    const r = @field(value, kinds.info(k).reg);
    return switch (@typeInfo(kinds.Elem(k))) {
        .int => @truncate(r),
        .float => @floatCast(r),
        .pointer => r,
        else => comptime unreachable,
    };
}

/// Stores `value` into slot `slot` (start already added) of kind `k`:
/// through `MVM_ASSIGN_REF` on `root` (the write barrier) for the kinds
/// that hold references, a plain store for the others (row 15c).
inline fn storeElem(comptime k: Kind, tc: Tc, root: Obj, body: *Body, slot: u64, value: Reg) void {
    const p = &kinds.slots(k, body)[slot];
    if (comptime kinds.info(k).holds_refs) {
        moar.assignRef(tc, &root.*.header, p, fromReg(k, value));
    } else {
        p.* = fromReg(k, value);
    }
}

/// `at_pos`'s read of element `index` (`start` not yet added) into
/// `value`, shared by the generic `at_pos` and the per-kind entry points:
/// past `elems` the kind's null (OBJ: VMNull, STR: NULL, numbers: 0), and
/// for OBJ a NULL slot is VMNull too (row 12c; pop and shift do not do
/// this, row 18b).
inline fn readElem(comptime k: Kind, tc: Tc, body: *Body, index: u64, value: *Reg) void {
    if (index >= body.elems) {
        if (comptime k == .obj) {
            value.o = tc.*.instance.*.VMNull;
        } else {
            toReg(k, value, std.mem.zeroes(kinds.Elem(k)));
        }
        return;
    }
    const e = kinds.slots(k, body)[body.start +% index];
    if (comptime k == .obj) {
        value.o = if (e != null) e else tc.*.instance.*.VMNull;
    } else {
        toReg(k, value, e);
    }
}

// ---- register-kind checks and their texts ------------------------------

/// The operations whose arms check the caller's register kind, named as
/// the word in their error text.
pub const Op = enum { atpos, bindpos, push, pop, unshift, shift };

/// `s` in upper case, at compile time (`"u32"` -> `"U32"`).
fn upper(comptime str: []const u8) []const u8 {
    comptime {
        var b: [str.len]u8 = undefined;
        for (str, 0..) |ch, i| b[i] = std.ascii.toUpper(ch);
        const out = b;
        return &out;
    }
}

/// The text kind `k`'s arm of `op` throws for a register kind it does not
/// accept, built at compile time from the C's rule (rows 12b, 15b, 17b,
/// 18a, 19a, 20):
///
///     "MVMArray: <op> " ++ <name> ++ "expected <word> register" ++ <tail>
///
/// <word> is "object" (OBJ), "string" (STR), "int" (the integer kinds) or
/// "num" (N64, N32); <name> is "I32 " etc. only for the integer kinds of
/// `atpos` and `bindpos` (the other ops never name the kind, nor do the
/// num arms); <tail> is ", got %d instead", with the register kind as the
/// argument, only on U64's `atpos` (row 12b). So `kindMessage(.atpos, .i16)`
/// is "MVMArray: atpos I16 expected int register" and
/// `kindMessage(.push, .u8)` "MVMArray: push expected int register". The
/// switch is on the element's type class.
pub fn kindMessage(comptime op: Op, comptime k: Kind) [:0]const u8 {
    const T = kinds.Elem(k);
    const word = switch (@typeInfo(T)) {
        .pointer => if (k == .obj) "object" else "string",
        .int => "int",
        .float => "num",
        else => unreachable,
    };
    const named = (op == .atpos or op == .bindpos) and @typeInfo(T) == .int;
    const name = if (named) upper(@tagName(k)) ++ " " else "";
    const tail = if (op == .atpos and k == .u64) ", got %d instead" else "";
    return "MVMArray: " ++ @tagName(op) ++ " " ++ name ++ "expected " ++ word ++ " register" ++ tail;
}

/// Throws `kindMessage(op, k)` unless `kind` is one `op` accepts for `k`:
/// `info(k).reg_kinds` for `atpos` and `bindpos` (rows 12a, 15a),
/// `info(k).stack_reg_kinds` for push, pop, shift and unshift (row 17a).
/// The `inline for` emits one comparison per accepted register kind.
inline fn checkKind(comptime op: Op, comptime k: Kind, tc: Tc, kind: u16) void {
    const accepted = comptime if (op == .atpos or op == .bindpos) kinds.info(k).reg_kinds else kinds.info(k).stack_reg_kinds;
    inline for (accepted) |a| {
        if (kind == a) return;
    }
    const message = comptime kindMessage(op, k);
    if (comptime op == .atpos and k == .u64) {
        // The register kind, an MVMuint16 promoted to int for `%d`.
        c.MVM_exception_throw_adhoc(tc, message, @as(c_int, kind));
    } else {
        c.MVM_exception_throw_adhoc(tc, message);
    }
}

/// The arms of the indexed and stack operations, for `op`'s register-kind
/// check and text: `Arm(op).read`, `.store` and `.load`, each generic over
/// the kind and instantiated twelve times by the `dispatch` that calls it.
/// Only the pairs a `dispatch` names are generated: `Arm(.atpos).read`
/// (`atPos`), `Arm(.bindpos).store`, `Arm(.push).store`,
/// `Arm(.unshift).store` (`bindPos`, `push`, `unshift`), `Arm(.pop).load`
/// and `Arm(.shift).load` (`pop`, `shift`). Zig analyses a function of the
/// returned struct only when it is referenced, so a pair no operation names
/// (`Arm(.atpos).store`, `Arm(.pop).read`, ...) is never compiled.
/// `Arm(.bindpos).store(.u16, ...)` is the C's `case MVM_ARRAY_U16:` of
/// bind_pos: the check against { uint64, int64 } with "MVMArray: bindpos
/// U16 expected int register", then `slots.u16[slot] = (MVMuint16)value`.
fn Arm(comptime op: Op) type {
    return struct {
        /// at_pos: the check, then `readElem`.
        fn read(comptime k: Kind, tc: Tc, body: *Body, index: u64, value: *Reg, kind: u16) void {
            checkKind(op, k, tc, kind);
            readElem(k, tc, body, index, value);
        }
        /// bind_pos, push, unshift: the check, then the store into `slot`.
        fn store(comptime k: Kind, tc: Tc, root: Obj, body: *Body, slot: u64, value: Reg, kind: u16) void {
            checkKind(op, k, tc, kind);
            storeElem(k, tc, root, body, slot, value);
        }
        /// pop, shift: the check, then the raw slot into the register: a
        /// NULL OBJ slot comes back NULL, not VMNull (row 18b).
        fn load(comptime k: Kind, tc: Tc, body: *Body, slot: u64, value: *Reg, kind: u16) void {
            checkKind(op, k, tc, kind);
            toReg(k, value, kinds.slots(k, body)[slot]);
        }
    };
}

/// The `default:` arm of every per-kind operation but at_pos, for a slot
/// type that is not a stored kind (va-kind-differences.md section 3).
const unhandled = kinds.Otherwise{ .throw = "MVMArray: Unhandled slot type" };

/// at_pos's `default:` arm (row 12e): names the slot type through
/// `MVM_reg_get_debug_name`, the register-kind name table, as the C does.
fn unhandledAtPos(slot_type: u8, tc: Tc, body: *Body, index: u64, value: *Reg, kind: u16) void {
    _ = body;
    _ = index;
    _ = value;
    _ = kind;
    c.MVM_exception_throw_adhoc(tc, "MVMArray: Unhandled slot type, got '%s'", c.MVM_reg_get_debug_name(tc, slot_type));
}

/// `slot_type_to_kind` (VMArray.c:904-931, row 21): the kind's own
/// register kind, `abort()` for any other slot type.
fn slotTypeToKind(slot_type: u8) u16 {
    return kinds.dispatch(slot_type, ownRegKind, .{}, kinds.Otherwise.abort);
}

fn ownRegKind(comptime k: Kind) u16 {
    return kinds.info(k).reg_kind;
}

/// `kind_to_elements_name`: what a register kind from `slotTypeToKind`
/// holds, for the cross-kind splice message.
fn kindToElementsName(kind: u16) [*:0]const u8 {
    return switch (kind) {
        c.MVM_reg_obj => "objects",
        c.MVM_reg_str => "strings",
        c.MVM_reg_int64 => "integers",
        c.MVM_reg_uint64 => "unsigned integers",
        else => "numbers",
    };
}

/// Whether asplice copies from register kind `s_kind` into `d_kind`: the
/// same kind, a string into an object array, or between int and uint.
fn spliceKindsFit(s_kind: u16, d_kind: u16) bool {
    const int_like = struct {
        fn f(kind: u16) bool {
            return kind == c.MVM_reg_int64 or kind == c.MVM_reg_uint64;
        }
    }.f;
    return s_kind == d_kind or
        (s_kind == c.MVM_reg_str and d_kind == c.MVM_reg_obj) or
        (int_like(s_kind) and int_like(d_kind));
}

/// `memmove(slots + to, slots + from, len)` in bytes; nothing for 0 bytes
/// (the C's 0-byte memmove, where `slots` may be NULL).
inline fn moveBytes(body: *Body, to: u64, from: u64, len: u64) void {
    if (len == 0) return;
    const p = slotBytes(body);
    @memmove(p[to..][0..len], p[from..][0..len]);
}

/// The element type's storage spec (`get_elem_storage_spec`, row 28), by
/// group: STR, signed integers, unsigned integers, nums; OBJ shares the
/// `default:` arm's reference spec (`referenceSpec`). `bits` and `align`
/// are 0 for every kind.
fn elemSpec(comptime k: Kind) c.MVMStorageSpec {
    if (k == .obj) return reference_elem_spec;
    var spec: c.MVMStorageSpec = .{
        .inlineable = c.MVM_STORAGE_SPEC_INLINED,
        .bits = 0,
        .@"align" = 0,
        .boxed_primitive = undefined,
        .can_box = undefined,
        .is_unsigned = 0,
    };
    switch (@typeInfo(kinds.Elem(k))) {
        .pointer => {
            spec.boxed_primitive = c.MVM_STORAGE_SPEC_BP_STR;
            spec.can_box = c.MVM_STORAGE_SPEC_CAN_BOX_STR;
        },
        .int => |i| if (i.signedness == .signed) {
            spec.boxed_primitive = c.MVM_STORAGE_SPEC_BP_INT;
            spec.can_box = c.MVM_STORAGE_SPEC_CAN_BOX_INT;
        } else {
            spec.boxed_primitive = c.MVM_STORAGE_SPEC_BP_UINT64;
            spec.can_box = c.MVM_STORAGE_SPEC_CAN_BOX_INT;
            spec.is_unsigned = 1;
        },
        .float => {
            spec.boxed_primitive = c.MVM_STORAGE_SPEC_BP_NUM;
            spec.can_box = c.MVM_STORAGE_SPEC_CAN_BOX_NUM;
        },
        else => comptime unreachable,
    }
    return spec;
}

const reference_elem_spec: c.MVMStorageSpec = .{
    .inlineable = c.MVM_STORAGE_SPEC_REFERENCE,
    .bits = 0,
    .@"align" = 0,
    .boxed_primitive = c.MVM_STORAGE_SPEC_BP_NONE,
    .can_box = 0,
    .is_unsigned = 0,
};

/// `get_elem_storage_spec`'s `default:` arm (OBJ and the six kinds
/// without storage, row 28).
fn referenceSpec(slot_type: u8) c.MVMStorageSpec {
    _ = slot_type;
    return reference_elem_spec;
}

/// The array's own storage spec (`storage_spec`, VMArray.c:131-138).
const array_spec: c.MVMStorageSpec = .{
    .inlineable = c.MVM_STORAGE_SPEC_REFERENCE,
    .bits = 0,
    .@"align" = 0,
    .boxed_primitive = c.MVM_STORAGE_SPEC_BP_NONE,
    .can_box = 0,
    .is_unsigned = 0,
};

comptime {
    // pos_as_atomic's rule below (row 29) is the C's on 4- and 8-byte AO_t.
    std.debug.assert(@sizeOf(c.AO_t) == 8 or @sizeOf(c.AO_t) == 4);
}

/// pos_as_atomic for kind `k` (row 29): a pointer to the slot for the
/// integer kinds whose element is AO_t's size (I64 and U64 on x86-64, I32
/// and U32 where AO_t is 4 bytes); every other kind throws, as the C's
/// fall-through.
fn atomicArm(comptime k: Kind, tc: Tc, body: *Body, index: u64) [*c]c.AO_t {
    if (comptime @typeInfo(kinds.Elem(k)) == .int and kinds.info(k).elem_size == @sizeOf(c.AO_t)) {
        // Only the address, as the C (VMArray.c:1207): NULL slots are not
        // read here, so the raw `[*c]` member, not `kinds.slots`.
        const raw: [*c]c.AO_t = @ptrCast(@alignCast(@field(body.slots, kinds.info(k).member)));
        return raw + (body.start +% index);
    }
    return notAtomic(@backingInt(k), tc, body, index);
}

fn notAtomic(slot_type: u8, tc: Tc, body: *Body, index: u64) [*c]c.AO_t {
    _ = slot_type;
    _ = body;
    _ = index;
    c.MVM_exception_throw_adhoc(tc, "Can only do integer atomic operation on native integer array element of atomic size");
}

/// Checks at compile time that `f` has exactly the type of the function
/// slot `field` of the C table `T` (so `repr.Ops` will accept it).
fn slotFits(comptime T: type, comptime field: []const u8, comptime f: anytype) void {
    const F = @typeInfo(@FieldType(T, field)).optional.child;
    if (*const @TypeOf(f) != F) @compileError("elements.zig: " ++ field ++ " does not have the C signature " ++ @typeName(F));
}

/// The element operations over the slot storage `S` (a
/// `storage.Storage(Source)`): a namespace of functions, one per VMArray
/// vtable slot that touches elements, each with that slot's exact C type
/// (checked at compile time below), plus the per-kind entry points
/// `atPosKind` and `bindPosKind`. It has no state.
pub fn Elements(comptime S: type) type {
    return struct {
        /// `MVM_VMArray_at_pos` (VMArray.c:240-358).
        pub fn atPos(tc: Tc, st: St, root: Obj, data: ?*anyopaque, index: i64, value: [*c]Reg, kind: u16) callconv(.c) void {
            _ = root;
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            const i = u(fromEnd(tc, index, body.elems));
            kinds.dispatch(need(repr_data).slot_type, Arm(.atpos).read, .{ tc, body, i, @as(*Reg, value), kind }, unhandledAtPos);
        }

        /// `MVM_VMArray_bind_pos` (VMArray.c:478-561): the growth before
        /// the kind check (row 15a).
        pub fn bindPos(tc: Tc, st: St, root: Obj, data: ?*anyopaque, index: i64, value: Reg, kind: u16) callconv(.c) void {
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            enterSingleUser(tc, body);
            const i = bindIndex(S, tc, st, body, index);
            kinds.dispatch(need(repr_data).slot_type, Arm(.bindpos).store, .{ tc, root, body, body.start +% i, value, kind }, unhandled);
            exitSingleUser(body);
        }

        /// `set_elems` (VMArray.c:568-574).
        pub fn setElems(tc: Tc, st: St, root: Obj, data: ?*anyopaque, count: u64) callconv(.c) void {
            _ = root;
            const body = bodyOf(data);
            enterSingleUser(tc, body);
            S.setSize(tc, body, count, reprDataOf(st));
            exitSingleUser(body);
        }

        /// `MVM_VMArray_push` (VMArray.c:576-646): grows first, then the
        /// kind check (row 17a), so a rejected push leaves a zero element.
        pub fn push(tc: Tc, st: St, root: Obj, data: ?*anyopaque, value: Reg, kind: u16) callconv(.c) void {
            const body = bodyOf(data);
            const repr_data = reprDataOf(st);
            enterSingleUser(tc, body);
            S.setSize(tc, body, body.elems +% 1, repr_data);
            kinds.dispatch(need(repr_data).slot_type, Arm(.push).store, .{ tc, root, body, body.start +% body.elems -% 1, value, kind }, unhandled);
            exitSingleUser(body);
        }

        /// `pop` (VMArray.c:648-725): the empty check, the kind check,
        /// then `elems--` and the slot cleared, so a rejected pop leaves
        /// the array as it was (upstream 27ebea0b8; row 18c described the
        /// old order, which dropped the element and left its slot).
        pub fn pop(tc: Tc, st: St, root: Obj, data: ?*anyopaque, value: [*c]Reg, kind: u16) callconv(.c) void {
            _ = root;
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            // Computed before the empty check, as the C; it wraps when
            // elems is 0 and is not used then.
            const slot = body.start +% body.elems -% 1;
            if (body.elems < 1) c.MVM_exception_throw_adhoc(tc, "MVMArray: Can't pop from an empty array");
            enterSingleUser(tc, body);
            kinds.dispatch(need(repr_data).slot_type, Arm(.pop).load, .{ tc, body, slot, @as(*Reg, value), kind }, unhandled);
            // Only once the register kind has been checked.
            body.elems -= 1; // elems >= 1 here
            storage.zeroSlots(tc, body, slot, slot +% 1, need(repr_data).slot_type);
            exitSingleUser(body);
        }

        /// `unshift` (VMArray.c:727-824): at `start == 0` first
        /// `n = min(max(elems, 8), 8192)` slots of front room (grow, move
        /// the elements up by `n`, zero the first `n`); then the kind
        /// check and the store into the slot before `start`, and only then
        /// `start--` and `elems++`, so a rejected unshift leaves the window
        /// where it was (upstream fd53df2e0; row 19b described the old
        /// order). The front room made at `start == 0` stays, as in the C.
        pub fn unshift(tc: Tc, st: St, root: Obj, data: ?*anyopaque, value: Reg, kind: u16) callconv(.c) void {
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            enterSingleUser(tc, body);
            if (body.start < 1) {
                const live = body.elems;
                const n = @min(@max(live, 8), 8192);
                S.setSize(tc, body, live +% n, repr_data);
                const es = need(repr_data).elem_size; // VMArray.c:745
                moveBytes(body, n *% es, 0, live *% es);
                body.start = n;
                body.elems = live;
                storage.zeroSlots(tc, body, 0, n, need(repr_data).slot_type);
            }
            kinds.dispatch(need(repr_data).slot_type, Arm(.unshift).store, .{ tc, root, body, body.start -% 1, value, kind }, unhandled);
            body.start -%= 1;
            body.elems +%= 1;
            exitSingleUser(body);
        }

        /// `shift` (VMArray.c:826-902): the empty check, the kind check
        /// before any change, then `start++` and `elems--`. The slot left
        /// is not cleared (row 20; kept).
        pub fn shift(tc: Tc, st: St, root: Obj, data: ?*anyopaque, value: [*c]Reg, kind: u16) callconv(.c) void {
            _ = root;
            const body = bodyOf(data);
            const repr_data = reprDataOf(st);
            if (body.elems < 1) c.MVM_exception_throw_adhoc(tc, "MVMArray: Can't shift from an empty array");
            enterSingleUser(tc, body);
            kinds.dispatch(need(repr_data).slot_type, Arm(.shift).load, .{ tc, body, body.start, @as(*Reg, value), kind }, unhandled);
            body.start +%= 1;
            body.elems -%= 1;
            exitSingleUser(body);
        }

        /// `copy_elements` (VMArray.c:933-967): `n` elements of `src` from
        /// `s_offset` into `dest` at `d_offset`, which has room.
        ///
        /// - Block copy (row 22a) when `src` is a VMArray of the same slot
        ///   type and element size, unless the target is STR, or OBJ with
        ///   the target in gen2 (`MVM_CF_SECOND_GEN` of the DESTINATION,
        ///   row 22b): a `@memmove`, as the C's `memmove` (`src` may be
        ///   `dest`, a splice of an array into itself, whose ranges
        ///   overlap). The same kind without storage on both sides copies 0
        ///   bytes (row 22c).
        /// - Otherwise element by element through the source's `at_pos`
        ///   with its kind's register kind and `bindPos` with the target's
        ///   (the barrier; NULL OBJ holes become VMNull, row 22b): forward,
        ///   or from the last element down when `src` is `dest` and the
        ///   target range lies above the source range, so that no element
        ///   is overwritten before it is read (as the memmove). So a splice
        ///   of an array into itself gives the splice from its clone on
        ///   every path (traces/llm/bench/cfix-S.md). Nothing converts across kinds but the register's own
        ///   widening and narrowing (row 22c). A kind without storage on
        ///   either side aborts in `slotTypeToKind`, the target's first
        ///   (rule of row 22c); a non-VMArray source with elements (or a
        ///   VMArray one whose stubbed STable has no REPR data yet) makes
        ///   the C read its REPR data through NULL and fault, which
        ///   `moar.nullDeref` reproduces. Neither is reached any more:
        ///   `asplice` refuses such a source, a kind without storage and
        ///   the cross-kind pairs that would be reinterpreted before it
        ///   changes anything (as the C, upstream 007382664, 98a84053a,
        ///   f8a955192), and `aslice` copies into an array of the source's
        ///   own type (the `slice` op allocates it so). Both REPR data
        ///   pointers are loaded first and read only after `n <= 0`, as the
        ///   C (936-944).
        fn copyElements(tc: Tc, src: Obj, dest: Obj, s_offset: i64, d_offset: i64, n: i64) void {
            const s_body = objectBodyOf(src);
            const d_body = objectBodyOf(dest);
            const s_repr_data: ?*const c.MVMArrayREPRData = if (src.*.st.*.REPR.*.ID == c.MVM_REPR_ID_VMArray) reprDataOf(src.*.st) else null;
            const d_repr_data = reprDataOf(dest.*.st);
            if (n <= 0) return;
            const d_needs_barrier = (dest.*.header.flags2 & c.MVM_CF_SECOND_GEN) != 0;
            if (s_repr_data) |s_rd| {
                if (s_rd.slot_type == need(d_repr_data).slot_type and
                    s_rd.elem_size == need(d_repr_data).elem_size and
                    (need(d_repr_data).slot_type != c.MVM_ARRAY_OBJ or !d_needs_barrier) and
                    need(d_repr_data).slot_type != c.MVM_ARRAY_STR)
                {
                    const len = need(d_repr_data).elem_size *% u(n);
                    if (len == 0) return;
                    const d = slotBytes(d_body);
                    const sp = slotBytes(s_body);
                    const d_at = u(s(d_body.start) +% d_offset) *% need(d_repr_data).elem_size;
                    const s_at = u(s(s_body.start) +% s_offset) *% s_rd.elem_size;
                    @memmove(d[d_at..][0..len], sp[s_at..][0..len]);
                    return;
                }
            }
            const target_kind = slotTypeToKind(need(d_repr_data).slot_type);
            // A non-VMArray source with elements: the C reads
            // `s_repr_data->slot_type` through NULL and faults; this faults
            // at the same offset (asplice refuses such a source first).
            const s_rd = s_repr_data orelse moar.nullDeref(@offsetOf(c.MVMArrayREPRData, "slot_type"));
            const source_kind = slotTypeToKind(s_rd.slot_type);
            const at_pos = reprFn(src.*.st.*.REPR.*.pos_funcs.at_pos);
            const backwards = src == dest and d_offset > s_offset;
            var i: i64 = 0;
            while (i < n) : (i += 1) {
                // n > 0 here, so `n - 1 - i` does not overflow.
                const j = if (backwards) n - 1 - i else i;
                var to_copy: Reg = undefined;
                at_pos(tc, src.*.st, src, s_body, s_offset +% j, &to_copy, source_kind);
                bindPos(tc, dest.*.st, dest, d_body, d_offset +% j, to_copy, target_kind);
            }
        }

        /// `aslice` (VMArray.c:969-986): elements `start..end` inclusive,
        /// negative ends from the end, into `dest` (resized to them).
        pub fn aslice(tc: Tc, st: St, src: Obj, data: ?*anyopaque, dest: Obj, start: i64, end: i64) callconv(.c) void {
            const s_body = bodyOf(data);
            const d_body = objectBodyOf(dest);
            const d_repr_data = reprDataOf(dest.*.st);
            const total = s(reprFn(src.*.st.*.REPR.*.elems)(tc, st, src, s_body));
            const from = if (start < 0) total +% start else start;
            const to = if (end < 0) total +% end else end;
            if (to < from or from < 0 or to < 0 or total <= from or total <= to)
                c.MVM_exception_throw_adhoc(tc, "MVMArray: Slice index out of bounds");
            const n = to - from + 1; // 0 <= from <= to < total: no overflow
            S.setSize(tc, d_body, u(n), d_repr_data);
            copyElements(tc, src, dest, from, 0, n);
        }

        /// `asplice` (VMArray.c:1040-1121): replaces `count` elements at
        /// `offset` with `from`'s, step for step as the C, with its mixed
        /// signed and unsigned arithmetic (each `MVMuint64`/`MVMint64` mix
        /// is the C's conversion, wrapping). At offset 0 `start` may move
        /// back over shifted-off slots (row 26), but not when `from` is the
        /// array itself: that would move the source too. A non-empty
        /// `from` that is not a VMArray, a kind without storage on either
        /// side, or a pair of kinds `spliceKindsFit` refuses throws after
        /// the offset check and before anything is changed.
        pub fn asplice(tc: Tc, st: St, root: Obj, data: ?*anyopaque, from: Obj, offset_in: i64, count_in: u64) callconv(.c) void {
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            var elems0: u64 = body.elems;
            const from_obj = objectOrFault(from);
            const elems1: u64 = reprFn(from_obj.st.*.REPR.*.elems)(tc, from_obj.st, from, moar.objectBody(from_obj));
            var offset = offset_in;
            var count = count_in;

            if (offset < 0) {
                offset = s(u(offset) +% elems0);
                if (offset < 0) c.MVM_exception_throw_adhoc(tc, "MVMArray: Illegal splice offset");
            }

            // A source copyElements cannot copy from is refused before
            // anything is changed (upstream 007382664, 98a84053a,
            // f8a955192); an empty source of any kind copies nothing.
            if (elems1 > 0) {
                if (from_obj.st.*.REPR.*.ID != c.MVM_REPR_ID_VMArray)
                    c.MVM_exception_throw_adhoc(tc, "MVMArray: Can only splice from a VMArray, got a %s", from_obj.st.*.REPR.*.name);
                const s_repr_data = reprDataOf(from_obj.st);
                if (need(s_repr_data).elem_size == 0 or need(repr_data).elem_size == 0)
                    c.MVM_exception_throw_adhoc(tc, "MVMArray: Unhandled slot type");
                // The elements are copied as registers of these kinds,
                // without conversion: only the pairs where that is still a
                // value of the target's kind (a string is an object, int and
                // uint convert).
                const s_kind = slotTypeToKind(need(s_repr_data).slot_type);
                const d_kind = slotTypeToKind(need(repr_data).slot_type);
                if (!spliceKindsFit(s_kind, d_kind))
                    c.MVM_exception_throw_adhoc(tc, "MVMArray: Cannot splice from an array of %s into an array of %s", kindToElementsName(s_kind), kindToElementsName(d_kind));
            }

            enterSingleUser(tc, body);

            if (offset == 0 and from != root) {
                var n = s(elems1 -% count);
                const start = s(body.start);
                if (n > start) n = start;
                if (n <= @as(i64, 0) -% s(elems0)) {
                    elems0 = 0;
                    count = 0;
                    body.start = 0;
                    body.elems = elems0;
                } else if (n != 0) {
                    elems0 +%= u(n);
                    count +%= u(n);
                    body.start = u(start -% n);
                    body.elems = elems0;
                }
            }

            if (count == 0 and elems1 == 0) {
                exitSingleUser(body);
                return;
            }

            var tail = s(elems0 -% u(offset) -% count);
            if (tail < 0) {
                tail = 0;
            } else if (tail > 0 and count > elems1) {
                // Shrinking: move the tail left first.
                const start = s(body.start);
                const es = need(repr_data).elem_size; // VMArray.c:1100
                moveBytes(body, (u(start +% offset) +% elems1) *% es, (u(start +% offset) +% count) *% es, u(tail) *% es);
            }

            S.setSize(tc, body, u(offset) +% elems1 +% u(tail), repr_data);

            const start = s(body.start);
            if (tail > 0 and count < elems1) {
                // Grown: move the tail right.
                const es = need(repr_data).elem_size; // VMArray.c:1112
                moveBytes(body, (u(start +% offset) +% elems1) *% es, (u(start +% offset) +% count) *% es, u(tail) *% es);
            }
            exitSingleUser(body);

            copyElements(tc, from, root, 0, offset, s(elems1));
        }

        /// `at_pos_multidim` (VMArray.c:1123-1127).
        pub fn atPosMultidim(tc: Tc, st: St, root: Obj, data: ?*anyopaque, num_indices: i64, indices: [*c]i64, result: [*c]Reg, kind: u16) callconv(.c) void {
            if (num_indices != 1) c.MVM_exception_throw_adhoc(tc, "A dynamic array can only be indexed with a single dimension");
            atPos(tc, st, root, data, indices[0], result, kind);
        }

        /// `bind_pos_multidim` (VMArray.c:1129-1133).
        pub fn bindPosMultidim(tc: Tc, st: St, root: Obj, data: ?*anyopaque, num_indices: i64, indices: [*c]i64, value: Reg, kind: u16) callconv(.c) void {
            if (num_indices != 1) c.MVM_exception_throw_adhoc(tc, "A dynamic array can only be indexed with a single dimension");
            bindPos(tc, st, root, data, indices[0], value, kind);
        }

        /// `dimensions` (VMArray.c:1135-1139): one, pointing at `elems`.
        pub fn dimensions(tc: Tc, st: St, root: Obj, data: ?*anyopaque, num_dimensions: [*c]i64, dims: [*c][*c]i64) callconv(.c) void {
            _ = tc;
            _ = st;
            _ = root;
            num_dimensions.* = 1;
            dims.* = @ptrCast(&bodyOf(data).elems);
        }

        /// `set_dimensions` (VMArray.c:1141-1145).
        pub fn setDimensions(tc: Tc, st: St, root: Obj, data: ?*anyopaque, num_dimensions: i64, dims: [*c]i64) callconv(.c) void {
            if (num_dimensions != 1) c.MVM_exception_throw_adhoc(tc, "A dynamic array can only have a single dimension");
            setElems(tc, st, root, data, u(dims[0]));
        }

        /// `get_elem_storage_spec` (VMArray.c:1147-1192, row 28).
        pub fn getElemStorageSpec(tc: Tc, st: St) callconv(.c) c.MVMStorageSpec {
            _ = tc;
            return kinds.dispatch(need(reprDataOf(st)).slot_type, elemSpec, .{}, referenceSpec);
        }

        /// `pos_as_atomic` (VMArray.c:1194-1213): the index check first,
        /// then `atomicArm` (row 29).
        pub fn posAsAtomic(tc: Tc, st: St, root: Obj, data: ?*anyopaque, index_in: i64) callconv(.c) [*c]c.AO_t {
            _ = root;
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            var index = index_in;
            if (index < 0) index = s(u(index) +% body.elems);
            if (index < 0 or u(index) >= body.elems)
                c.MVM_exception_throw_adhoc(tc, "Index out of bounds in atomic operation on array");
            return kinds.dispatch(need(repr_data).slot_type, atomicArm, .{ tc, body, u(index) }, notAtomic);
        }

        /// `pos_as_atomic_multidim` (VMArray.c:1215-1221).
        pub fn posAsAtomicMultidim(tc: Tc, st: St, root: Obj, data: ?*anyopaque, num_indices: i64, indices: [*c]i64) callconv(.c) [*c]c.AO_t {
            if (num_indices != 1) c.MVM_exception_throw_adhoc(tc, "A dynamic array can only be indexed with a single dimension");
            return posAsAtomic(tc, st, root, data, indices[0]);
        }

        /// `write_buf` (VMArray.c:988-1012): `count` bytes from `from` at
        /// element `offset`. The kind gate is `slot_type < MVM_ARRAY_I64`,
        /// so the nums and the six kinds without storage pass (row 24;
        /// kept); the growth is to `offset + count` elements, `count` being
        /// bytes (an 8-byte write at element 1 of a 3-element U16 array
        /// grows it to 9 elements, va-differential.md section 4; kept).
        /// `@memmove`, defined where the C's
        /// memcpy is, so no caller's buffer can make it illegal.
        pub fn writeBuf(tc: Tc, st: St, root: Obj, data: ?*anyopaque, from: [*c]u8, offset: i64, count: u64) callconv(.c) void {
            _ = root;
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            var start = body.start;
            const live = body.elems;
            if (need(repr_data).slot_type < c.MVM_ARRAY_I64) c.MVM_exception_throw_adhoc(tc, "MVMArray: write_buf requires an integer type");
            if (offset < 0) c.MVM_exception_throw_adhoc(tc, "MVMArray: Index out of bounds");
            const es = need(repr_data).elem_size;
            if (live *% es < u(offset) *% es +% count) {
                S.setSize(tc, body, u(offset) +% count, repr_data);
                start = body.start;
            }
            if (count == 0) return; // the C's 0-byte memcpy
            // `from` is the caller's buffer of `count` bytes, never NULL.
            const p = slotBytes(body);
            @memmove(p[(start +% u(offset)) *% es ..][0..count], from[0..count]);
        }

        /// `read_buf` (VMArray.c:1014-1036): `count` bytes at element
        /// `offset` as an integer, filled from its low end (from the high
        /// end on a big-endian target, the C's `MVM_BIGENDIAN`, which
        /// the config derives from the target). The bounds check adds
        /// `start` to `elems`, so with `start > 0` it lets reads past the
        /// last element through: within the storage they read the slots
        /// past the window, beyond it past the allocation (row 25;
        /// va-differential.md sections 4 and 6; kept). The callers
        /// pass at most 8 bytes; more would overrun `result`, as in the C.
        pub fn readBuf(tc: Tc, st: St, root: Obj, data: ?*anyopaque, offset: i64, count: u64) callconv(.c) i64 {
            _ = root;
            const repr_data = reprDataOf(st);
            const body = bodyOf(data);
            const start = s(body.start);
            var result: i64 = 0;
            const es = need(repr_data).elem_size; // VMArray.c:1019, before the gate
            if (need(repr_data).slot_type < c.MVM_ARRAY_I64) c.MVM_exception_throw_adhoc(tc, "MVMArray: read_buf requires an integer type");
            if (offset < 0 or (u(start) +% body.elems) *% es < u(offset) *% es +% count)
                c.MVM_exception_throw_adhoc(tc, "MVMArray: read_buf out of bounds offset %" ++ c.PRIi64 ++ " start %" ++ c.PRIi64 ++ " elems %" ++ c.PRIu64 ++ " count %" ++ c.PRIu64, offset, start, body.elems, count);
            if (count == 0) return result; // the C's 0-byte memcpy
            const to: [*]u8 = @ptrCast(&result);
            const at: u64 = if (comptime builtin.cpu.arch.endian() == .big) 8 -% count else 0;
            const p = slotBytes(body);
            @memcpy((to + at)[0..count], p[u(start +% offset) *% es ..][0..count]);
            return result;
        }

        /// `elems` (VMArray.c:563-566).
        pub fn elems(tc: Tc, st: St, root: Obj, data: ?*anyopaque) callconv(.c) u64 {
            _ = tc;
            _ = st;
            _ = root;
            return bodyOf(data).elems;
        }

        /// `get_storage_spec` (VMArray.c:142-144).
        pub fn getStorageSpec(tc: Tc, st: St) callconv(.c) [*c]const c.MVMStorageSpec {
            _ = tc;
            _ = st;
            return &array_spec;
        }

        /// `copy_to` (VMArray.c:48-65): `S.copyTo`.
        pub fn copyTo(tc: Tc, st: St, src: ?*anyopaque, dest_root: Obj, dest: ?*anyopaque) callconv(.c) void {
            _ = tc;
            _ = dest_root;
            S.copyTo(bodyOf(src), bodyOf(dest), reprDataOf(st));
        }

        /// `gc_free` (VMArray.c:112-115): frees the slots. Like the C it
        /// reads only the object, not its STable's REPR data: whether that
        /// is still live when the collector frees an object is not
        /// something the C depends on, so neither does this. The length
        /// handed to the allocator's free is therefore 0, which works only
        /// because `S.free` calls `rawFree` directly and the allocator
        /// ignores the length (storage.zig's contract; `moar.mvm_allocator`
        /// is the C allocator's free). A length-sensitive allocator must
        /// change this.
        pub fn gcFree(tc: Tc, obj: Obj) callconv(.c) void {
            _ = tc;
            // The collector passes the object it frees, never NULL.
            const arr: *c.MVMArray = @ptrCast(@alignCast(obj));
            S.free(&arr.body, 0);
        }

        /// `unmanaged_size` (VMArray.c:1515-1519): `ssize * elem_size`.
        pub fn unmanagedSize(tc: Tc, st: St, data: ?*anyopaque) callconv(.c) u64 {
            _ = tc;
            return bodyOf(data).ssize *% need(reprDataOf(st)).elem_size;
        }

        /// The read entry points specialised for kind `k`, generated per
        /// kind. VMArray.zig exports the `withRoot` of `.str`, `.i64`,
        /// `.u64`, `.n64` and `.obj` as `MVM_VMArray_at_pos_s/_i/_u/_n/_o`;
        /// `.i64`'s `jit` is not exported: it is the function
        /// spesh.zig's `findFastImplForJit` hands the JIT for `atpos_i` and
        /// `atpos_u`, in place of the C's static `vmarray_at_pos_int64`
        /// (VMArray.c:1584), and has no symbol name. Both take no register
        /// kind and read as `readElem` after the negative-index fix-up:
        /// - for `.str` and `.obj` the slot type is checked first, with the
        ///   C's own texts (rows 7, 11);
        /// - for every other kind nothing is checked: the caller guarantees
        ///   the kind (rows 8-10, 40).
        /// `withRoot` has the `MVM_VMArray_at_pos_*` signature, `jit` the
        /// JIT's (no root).
        pub fn atPosKind(comptime k: Kind) type {
            return struct {
                pub fn withRoot(tc: Tc, st: St, root: Obj, data: ?*anyopaque, index: i64, value: [*c]Reg) callconv(.c) void {
                    _ = root;
                    read(tc, st, data, index, value);
                }
                pub fn jit(tc: Tc, st: St, data: ?*anyopaque, index: i64, value: [*c]Reg) callconv(.c) void {
                    read(tc, st, data, index, value);
                }
                inline fn read(tc: Tc, st: St, data: ?*anyopaque, index: i64, value: [*c]Reg) void {
                    const body = bodyOf(data);
                    const i = u(fromEnd(tc, index, body.elems));
                    if (comptime k == .str or k == .obj) {
                        const slot_type = need(reprDataOf(st)).slot_type;
                        // The slot type, an MVMuint8 promoted for `%u`.
                        if (slot_type != @backingInt(k)) c.MVM_exception_throw_adhoc(tc, if (k == .str)
                            "MVMArray: atpos expected a string register, but %u is not MVM_ARRAY_STR"
                        else
                            "MVMArray: atpos with an object register, but array type %u is not MVM_ARRAY_OBJ", @as(c_uint, slot_type));
                    }
                    readElem(k, tc, body, i, value);
                }
            };
        }

        /// The JIT's bind entry point specialised for kind `k`. `.i64`'s
        /// `jit` is what spesh.zig's `findFastImplForJit` returns for
        /// `bindpos_i` and `bindpos_u`, in place of the C's static
        /// `vmarray_bind_pos_int64` (VMArray.c:1559; it serves U64 too,
        /// row 40); it is not exported. It does `bindIndex`, then a plain
        /// store of the narrowed register, no kind check. Only for kinds without references: the
        /// JIT signature has no root for a write barrier.
        pub fn bindPosKind(comptime k: Kind) type {
            if (kinds.info(k).holds_refs) @compileError("bindPosKind: " ++ @tagName(k) ++ " needs the root for its write barrier");
            return struct {
                pub fn jit(tc: Tc, st: St, data: ?*anyopaque, index: i64, value: Reg) callconv(.c) void {
                    const body = bodyOf(data);
                    enterSingleUser(tc, body);
                    const i = bindIndex(S, tc, st, body, index);
                    kinds.slots(k, body)[body.start +% i] = fromReg(k, value);
                    exitSingleUser(body);
                }
            };
        }

        // Every function above has its C slot's exact type.
        comptime {
            const P = c.MVMREPROps_Positional;
            const R = c.MVMREPROps;
            slotFits(P, "at_pos", atPos);
            slotFits(P, "bind_pos", bindPos);
            slotFits(P, "set_elems", setElems);
            slotFits(P, "push", push);
            slotFits(P, "pop", pop);
            slotFits(P, "unshift", unshift);
            slotFits(P, "shift", shift);
            slotFits(P, "slice", aslice);
            slotFits(P, "splice", asplice);
            slotFits(P, "at_pos_multidim", atPosMultidim);
            slotFits(P, "bind_pos_multidim", bindPosMultidim);
            slotFits(P, "dimensions", dimensions);
            slotFits(P, "set_dimensions", setDimensions);
            slotFits(P, "get_elem_storage_spec", getElemStorageSpec);
            slotFits(P, "pos_as_atomic", posAsAtomic);
            slotFits(P, "pos_as_atomic_multidim", posAsAtomicMultidim);
            slotFits(P, "write_buf", writeBuf);
            slotFits(P, "read_buf", readBuf);
            slotFits(R, "elems", elems);
            slotFits(R, "get_storage_spec", getStorageSpec);
            slotFits(R, "copy_to", copyTo);
            slotFits(R, "gc_free", gcFree);
            slotFits(R, "unmanaged_size", unmanagedSize);
        }
    };
}
