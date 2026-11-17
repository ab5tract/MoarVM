//! The slot kinds of the VM array (`MVMArray`, src/6model/reprs/VMArray.h):
//! what an array may store, stated once.
//!
//! An array's elements live in one buffer, `body.slots`, a C union of
//! twelve pointer members (`o`, `s`, `i64`, `i32`, ..., `u8`) plus `any`.
//! Which member is the right one is a runtime fact, the STable's
//! `MVMArrayREPRData.slot_type`, one of the header's `MVM_ARRAY_*`
//! constants. The C writes every operation as a `switch` on that value with
//! twelve hand-copied arms that differ in the member, the element type and
//! the register member the value travels in.
//!
//! Here those per-kind facts are one table, `kinds`, with an entry per
//! stored kind. Code that touches elements is written once as a function
//! generic over the kind (`fn op(comptime k: Kind, ...)`), reads its facts
//! with `info(k)` and its typed elements with `slots(k, body)`, and is
//! reached through `dispatch`, which turns the runtime `slot_type` into the
//! comptime `k`. `dispatch` is the only `switch` on the slot type; nothing
//! else in the array spells out the twelve arms.
//!
//! The header has eighteen kind constants. The twelve with storage (values
//! 0 to 11) are `Kind`. The six without storage (`U4`, `U2`, `U1`, `I4`,
//! `I2`, `I1`, 12 to 17: element size 0, created only by composing an int
//! type of 4, 2 or 1 bits) have no entry: no element operation exists for
//! them, and what each C operation does with them instead (throw, abort, or
//! nothing; traces/llm/bench/va-kind-differences.md section 3) is stated by
//! the caller of `dispatch` in its last argument, so it is visible where the
//! operation is written.
const std = @import("std");
const c = @import("moar").c;

/// The twelve stored kinds, each at the value of its `MVM_ARRAY_*`
/// constant, named as the constant in lower case (`.obj` = `MVM_ARRAY_OBJ`
/// = 0, ..., `.u8` = `MVM_ARRAY_U8` = 11).
pub const Kind = enum(u8) {
    obj = 0,
    str = 1,
    i64 = 2,
    i32 = 3,
    i16 = 4,
    i8 = 5,
    n64 = 6,
    n32 = 7,
    u64 = 8,
    u32 = 9,
    u16 = 10,
    u8 = 11,
};

/// One kind's facts. `kinds` holds one per `Kind`, in value order.
pub const KindInfo = struct {
    kind: Kind,
    /// The element type: what one slot holds, the pointee of the union
    /// member (`c.MVMint32` for `.i32`, `[*c]c.MVMObject` for `.obj`).
    Elem: type,
    /// The `body.slots` union member that points at the elements.
    member: [:0]const u8,
    /// The `c.MVMRegister` member a value of this kind travels in: `o`,
    /// `s`, `i64` (signed integers), `u64` (unsigned integers) or `n64`
    /// (both nums). A narrower element is widened into it on read and
    /// narrowed from it on write; the narrowing keeps the low bits (a C
    /// cast: `@truncate`, never `@intCast`) and the num narrowing rounds
    /// (`@floatCast`).
    reg: [:0]const u8,
    /// The kind's own register kind (`c.MVM_reg_*`), what the C's
    /// `slot_type_to_kind` returns for it (va-kind-differences.md row 21):
    /// `MVM_reg_obj`, `MVM_reg_str`, `MVM_reg_int64` (signed integers),
    /// `MVM_reg_num64` (nums), `MVM_reg_uint64` (unsigned integers). A
    /// copy between arrays reads and writes elements with it.
    reg_kind: u16,
    /// The register kinds that `at_pos` and `bind_pos` accept for this
    /// kind: `reg_kind`, and for the unsigned kinds `MVM_reg_int64` too
    /// (rows 12a, 15a).
    reg_kinds: []const u16,
    /// The register kinds that `push`, `pop`, `shift` and `unshift` accept:
    /// one each, and `MVM_reg_int64` for every integer kind, the unsigned
    /// ones included (rows 17a, 18a, 19a, 20): a `uint64` register is
    /// refused there although `at_pos` takes it.
    stack_reg_kinds: []const u16,
    /// Whether a slot holds a collectable reference (OBJ, STR): only these
    /// kinds are marked by the GC, described in heap snapshots and stored
    /// through the write barrier.
    holds_refs: bool,
    /// `@sizeOf(Elem)`, the `elem_size` the REPR data records for the kind.
    elem_size: usize,
};

/// Builds one table entry; `Elem` and `member` are checked against the C
/// union below, so a wrong type here fails the build.
fn entry(kind: Kind, comptime E: type, member: [:0]const u8, reg: [:0]const u8, reg_kinds: []const u16, stack_reg_kinds: []const u16) KindInfo {
    return .{
        .kind = kind,
        .Elem = E,
        .member = member,
        .reg = reg,
        .reg_kind = reg_kinds[0],
        .reg_kinds = reg_kinds,
        .stack_reg_kinds = stack_reg_kinds,
        .holds_refs = kind == .obj or kind == .str,
        .elem_size = @sizeOf(E),
    };
}

// Each set starts with the kind's own register kind (`reg_kind`).
const reg_obj = [_]u16{c.MVM_reg_obj};
const reg_str = [_]u16{c.MVM_reg_str};
const reg_int = [_]u16{c.MVM_reg_int64};
const reg_uint = [_]u16{ c.MVM_reg_uint64, c.MVM_reg_int64 };
const reg_num = [_]u16{c.MVM_reg_num64};

/// The kind table: the single place a stored kind's properties are stated.
/// It is comptime-only (an entry holds a type) and is read in `inline for`
/// loops, through `info(k)`, and by `dispatch`.
pub const kinds = [_]KindInfo{
    entry(.obj, [*c]c.MVMObject, "o", "o", &reg_obj, &reg_obj),
    entry(.str, [*c]c.MVMString, "s", "s", &reg_str, &reg_str),
    entry(.i64, c.MVMint64, "i64", "i64", &reg_int, &reg_int),
    entry(.i32, c.MVMint32, "i32", "i64", &reg_int, &reg_int),
    entry(.i16, c.MVMint16, "i16", "i64", &reg_int, &reg_int),
    entry(.i8, c.MVMint8, "i8", "i64", &reg_int, &reg_int),
    entry(.n64, c.MVMnum64, "n64", "n64", &reg_num, &reg_num),
    entry(.n32, c.MVMnum32, "n32", "n64", &reg_num, &reg_num),
    entry(.u64, c.MVMuint64, "u64", "u64", &reg_uint, &reg_int),
    entry(.u32, c.MVMuint32, "u32", "u64", &reg_uint, &reg_int),
    entry(.u16, c.MVMuint16, "u16", "u64", &reg_uint, &reg_int),
    entry(.u8, c.MVMuint8, "u8", "u64", &reg_uint, &reg_int),
};

/// The `body.slots` union type of the C header.
const SlotsUnion = @FieldType(c.MVMArrayBody, "slots");

// The table against the C header, at compile time: one entry per kind in
// value order, each union member a pointer to exactly `Elem`, each register
// member present. A header change that breaks a fact fails the build here.
comptime {
    if (kinds.len != std.enums.values(Kind).len) @compileError("kinds: one entry per Kind");
    for (kinds, 0..) |k, i| {
        if (@backingInt(k.kind) != i) @compileError("kinds: entries out of value order at " ++ @tagName(k.kind));
        const Member = @FieldType(SlotsUnion, k.member);
        if (@typeInfo(Member).pointer.child != k.Elem)
            @compileError("kinds: slots." ++ k.member ++ " does not point at " ++ @typeName(k.Elem));
        if (!@hasField(c.MVMRegister, k.reg)) @compileError("kinds: MVMRegister has no member " ++ k.reg);
    }
}

/// The entry of kind `k`.
pub fn info(comptime k: Kind) KindInfo {
    return kinds[@backingInt(k)];
}

/// The element type of kind `k` (`Elem(.u16)` is `c.MVMuint16`).
pub fn Elem(comptime k: Kind) type {
    return info(k).Elem;
}

/// The alignment of every slot buffer, for every kind: 16 bytes, which is
/// what MoarVM's C malloc (src/core/alloc.h) gives, so buffers that outside
/// C code allocates and hands to the array satisfy it, and at least the
/// widest element's (8).
pub const slot_alignment: std.mem.Alignment = .@"16";

comptime {
    for (kinds) |k| {
        if (slot_alignment.toByteUnits() < @alignOf(k.Elem)) @compileError("slot_alignment below " ++ @typeName(k.Elem));
    }
}

/// The slots of `body` as kind `k`'s elements: `body.slots.<member>` as a
/// many-item pointer, indexed by slot (an element `i` of the array is at
/// `[body.start + i]`). The body must have storage (`slots.any` not null).
/// `slots(.i32, body)` is `body.slots.i32` as a `[*]c.MVMint32`.
pub fn slots(comptime k: Kind, body: *c.MVMArrayBody) [*]Elem(k) {
    return @field(body.slots, info(k).member);
}

/// What `dispatch` does for a slot type that is not a stored kind (one of
/// the six without storage, or a value no kind has), when no function is
/// given for it. Each operation states the C's behaviour for it
/// (va-kind-differences.md section 3).
pub const Otherwise = union(enum) {
    /// `MVM_exception_throw_adhoc(tc, message)`, the C's `default:` arm.
    /// The first of `dispatch`'s `args` must be the thread context. The
    /// message is passed as the format, so it must not contain `%`.
    throw: [:0]const u8,
    /// `abort()`, as `slot_type_to_kind` does.
    abort,
    /// Return without effect (`f` must return `void`); the C has no
    /// `default:` arm and so does nothing.
    nothing,
};

/// The return type of `f`, which must not depend on the kind.
pub fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type orelse
        @compileError("dispatch: the return type of f must not depend on the kind");
}

/// The one runtime dispatch on the slot type: calls `f(k, args...)` with
/// `k` the comptime `Kind` whose value is `slot_type`, and for any other
/// value does what `otherwise` says. `otherwise` is either an `Otherwise`
/// (`Otherwise{ .throw = "..." }`, `Otherwise.abort`, `Otherwise.nothing`)
/// or a function called as `otherwise(slot_type, args...)` returning
/// `ReturnOf(f)`, for a C `default:` arm that does more than throw a fixed
/// text (a message that names the slot type, a value to return).
///
/// It generates one `switch (slot_type)` with an arm per entry of `kinds`
/// (values 0 to 11), each calling that kind's instantiation of `f`, and an
/// `else` arm for `otherwise`. For example
/// `dispatch(st, zeroArm, .{ tc, body, from, to }, Otherwise{ .throw = "MVMArray: Unhandled slot type" })`
/// expands to
///
/// ```zig
/// switch (st) {
///     0 => return zeroArm(.obj, tc, body, from, to),
///     1 => return zeroArm(.str, tc, body, from, to),
///     // ... one arm per kind ...
///     11 => return zeroArm(.u8, tc, body, from, to),
///     else => c.MVM_exception_throw_adhoc(tc, "MVMArray: Unhandled slot type"),
/// }
/// ```
pub inline fn dispatch(slot_type: u8, comptime f: anytype, args: anytype, comptime otherwise: anytype) ReturnOf(f) {
    switch (slot_type) {
        inline 0...kinds.len - 1 => |v| return @call(.auto, f, .{@as(Kind, @fromBackingInt(@intCast(v)))} ++ args),
        else => if (comptime @typeInfo(@TypeOf(otherwise)) == .@"fn") {
            return @call(.auto, otherwise, .{slot_type} ++ args);
        } else switch (comptime @as(Otherwise, otherwise)) {
            .throw => |message| c.MVM_exception_throw_adhoc(args[0], message.ptr),
            .abort => std.c.abort(),
            .nothing => {
                if (ReturnOf(f) != void) @compileError("dispatch: .nothing needs f to return void");
                return;
            },
        },
    }
}
