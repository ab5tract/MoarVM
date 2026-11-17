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
//! operation is written. Their constants and widths are listed once, in
//! `unstored`, for the one place that creates them (`spec_to_repr_data`).
//!
//! Adding a stored kind (docs/zig-build.md, "The slot kinds, and how to add
//! one", says the same at more length):
//!
//! 1. The stored kinds are a dense prefix of the `MVM_ARRAY_*` values
//!    (`dispatch`'s arms are `0...kinds.len - 1`, and the checks below
//!    require it), so the new kind takes value 12 and the six without
//!    storage move up to 13 ... 18, in src/6model/reprs/VMArray.h, which
//!    also gets the new member of `MVMArrayBody.slots`. The header is
//!    shared: the C array (VMArray.c, the `-Dzig-reprs=false` control) needs
//!    the kind's arm in each of its switches too.
//! 2. Here: the tag in `Kind` with value 12 and its row in `kinds`. The
//!    comptime block after the table checks the row against the header.
//!    `unstored` names the six by their constants and follows the
//!    renumbering by itself.
//! 3. A kind whose slots hold collectable references: `holds_refs` is not a
//!    column but is computed in `entry` as `.obj` or `.str`, so widen it
//!    there; and these places tell the reference kinds apart by name or
//!    treat every pointer kind other than OBJ as STR, so each needs a
//!    decision for the new kind:
//!    - elements.zig `readElem`: only `.obj` turns an out-of-range index or
//!      a NULL slot into VMNull; any other kind reads NULL there.
//!    - elements.zig `kindMessage`: a pointer kind other than `.obj` is
//!      worded "string".
//!    - elements.zig `elemSpec`: a pointer kind other than `.obj` gets the
//!      STR storage spec (`BP_STR`, `CAN_BOX_STR`).
//!    - elements.zig `copyElements`: the block copy is refused by constant
//!      (`MVM_ARRAY_STR` always, `MVM_ARRAY_OBJ` into a gen2 target), so a
//!      new reference kind would be copied with `@memmove`, past the
//!      write barrier.
//!    - serial.zig `specToReprData`: the kind is chosen from the storage
//!      spec's box kind, `BP_STR` naming `.str`; a kind that is neither an
//!      integer nor a num needs its own branch there to be created at all
//!      (integer and num kinds are found by walking this table).
//!    The register member (`reg`), the element type and the serialization
//!    reader and writer are checked by the compiler where they are used
//!    (`fromReg`, `toWire`, `fromWire`). The rest follows `holds_refs`
//!    (the write barrier in elements.zig and serial.zig, the mark and the
//!    heap snapshot in mark.zig, `bindPosKind`'s refusal).
//! 4. The tests that pin twelve kinds and the six at 12 ... 17
//!    (test/vmarray_storage_test.zig) and that pick an element type per
//!    kind (test/vmarray_elements_test.zig `elemType`, `sample`).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

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
    /// The serialization reader the array's `deserialize` reads one element
    /// with, named as the C function (`"MVM_serialization_read_int"`), and
    /// the writer `serialize` writes one with (`..._write_int`): `ref` for
    /// OBJ, `str` for STR, `int` for the eight integer kinds, `num` for the
    /// two nums (va-kind-differences.md rows 34a, 35). What travels is the
    /// reader's result and the writer's argument (`MVMObject *`,
    /// `MVMString *`, `MVMint64`, `MVMnum64`); serial.zig converts to and
    /// from `Elem` as the C's casts do.
    reader: [:0]const u8,
    writer: [:0]const u8,
};

/// One row of `kinds` as written: the facts of `KindInfo` that are stated,
/// by name, so that two columns of the same type (`member` and `reg`,
/// `reg_kinds` and `stack_reg_kinds`) cannot be swapped unseen. `entry`
/// derives the rest.
const Row = struct {
    kind: Kind,
    Elem: type,
    member: [:0]const u8,
    reg: [:0]const u8,
    /// `reg_kinds`; its first element is the kind's own `reg_kind`.
    reg_kinds: []const u16,
    stack_reg_kinds: []const u16,
    /// The suffix of the kind's serialization reader and writer (`"int"`
    /// gives `MVM_serialization_read_int` and `MVM_serialization_write_int`).
    wire: [:0]const u8,
};

/// Builds one table entry from its row. Callable only at compile time: it
/// concatenates strings with `++`, and its result holds a `type` (`Elem`),
/// so a `KindInfo` exists only at compile time. `Elem` and `member` are
/// checked against the C union below, so a wrong type here fails the build.
fn entry(comptime r: Row) KindInfo {
    return .{
        .reader = "MVM_serialization_read_" ++ r.wire,
        .writer = "MVM_serialization_write_" ++ r.wire,
        .kind = r.kind,
        .Elem = r.Elem,
        .member = r.member,
        .reg = r.reg,
        .reg_kind = r.reg_kinds[0],
        .reg_kinds = r.reg_kinds,
        .stack_reg_kinds = r.stack_reg_kinds,
        .holds_refs = r.kind == .obj or r.kind == .str,
        .elem_size = @sizeOf(r.Elem),
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
    entry(.{
        .kind = .obj,
        .Elem = [*c]c.MVMObject,
        .member = "o",
        .reg = "o",
        .reg_kinds = &reg_obj,
        .stack_reg_kinds = &reg_obj,
        .wire = "ref",
    }),
    entry(.{
        .kind = .str,
        .Elem = [*c]c.MVMString,
        .member = "s",
        .reg = "s",
        .reg_kinds = &reg_str,
        .stack_reg_kinds = &reg_str,
        .wire = "str",
    }),
    entry(.{
        .kind = .i64,
        .Elem = c.MVMint64,
        .member = "i64",
        .reg = "i64",
        .reg_kinds = &reg_int,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .i32,
        .Elem = c.MVMint32,
        .member = "i32",
        .reg = "i64",
        .reg_kinds = &reg_int,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .i16,
        .Elem = c.MVMint16,
        .member = "i16",
        .reg = "i64",
        .reg_kinds = &reg_int,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .i8,
        .Elem = c.MVMint8,
        .member = "i8",
        .reg = "i64",
        .reg_kinds = &reg_int,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .n64,
        .Elem = c.MVMnum64,
        .member = "n64",
        .reg = "n64",
        .reg_kinds = &reg_num,
        .stack_reg_kinds = &reg_num,
        .wire = "num",
    }),
    entry(.{
        .kind = .n32,
        .Elem = c.MVMnum32,
        .member = "n32",
        .reg = "n64",
        .reg_kinds = &reg_num,
        .stack_reg_kinds = &reg_num,
        .wire = "num",
    }),
    entry(.{
        .kind = .u64,
        .Elem = c.MVMuint64,
        .member = "u64",
        .reg = "u64",
        .reg_kinds = &reg_uint,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .u32,
        .Elem = c.MVMuint32,
        .member = "u32",
        .reg = "u64",
        .reg_kinds = &reg_uint,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .u16,
        .Elem = c.MVMuint16,
        .member = "u16",
        .reg = "u64",
        .reg_kinds = &reg_uint,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
    entry(.{
        .kind = .u8,
        .Elem = c.MVMuint8,
        .member = "u8",
        .reg = "u64",
        .reg_kinds = &reg_uint,
        .stack_reg_kinds = &reg_int,
        .wire = "int",
    }),
};

/// One of the six kinds without storage, as `spec_to_repr_data` creates it
/// from an integer element type of 4, 2 or 1 bits (row 31a): its
/// `MVM_ARRAY_*` constant, the width and the signedness it comes from. It
/// has no `Kind` and no element operation (see the top of this file); its
/// `elem_size` is 0.
pub const Unstored = struct {
    slot_type: u8,
    bits: u16,
    signedness: std.builtin.Signedness,
};

/// The six kinds without storage, the single place their constants and
/// widths are stated.
pub const unstored = [_]Unstored{
    .{ .slot_type = c.MVM_ARRAY_U4, .bits = 4, .signedness = .unsigned },
    .{ .slot_type = c.MVM_ARRAY_U2, .bits = 2, .signedness = .unsigned },
    .{ .slot_type = c.MVM_ARRAY_U1, .bits = 1, .signedness = .unsigned },
    .{ .slot_type = c.MVM_ARRAY_I4, .bits = 4, .signedness = .signed },
    .{ .slot_type = c.MVM_ARRAY_I2, .bits = 2, .signedness = .signed },
    .{ .slot_type = c.MVM_ARRAY_I1, .bits = 1, .signedness = .signed },
};

/// The `body.slots` union type of the C header.
const SlotsUnion = @FieldType(c.MVMArrayBody, "slots");

// The table against the C header, at compile time: one entry per kind in
// value order, each union member a pointer to exactly `Elem`, each register
// member present. A header change that breaks a fact fails the build here.
comptime {
    if (kinds.len != std.enums.values(Kind).len) @compileError("kinds: one entry per Kind");
    for (kinds, 0..) |k, i| {
        if (@backingInt(k.kind) != i) @compileError("kinds: entries out of value order at " ++
            @tagName(k.kind) ++ ": row i must be the kind of value i, the stored kinds" ++
            " being the dense prefix 0 ... kinds.len - 1 of the MVM_ARRAY_* values" ++
            " (dispatch's arms)");
        const Member = @FieldType(SlotsUnion, k.member);
        if (@typeInfo(Member).pointer.child != k.Elem)
            @compileError("kinds: slots." ++ k.member ++ " does not point at " ++ @typeName(k.Elem));
        if (!@hasField(c.MVMRegister, k.reg)) @compileError("kinds: MVMRegister has no member " ++ k.reg);
        if (!@hasDecl(c, k.reader) or !@hasDecl(c, k.writer)) @compileError("kinds: no " ++ k.reader ++ " or " ++ k.writer);
    }
    // The six are the constants after the stored kinds, each once.
    for (unstored, 0..) |u, i| {
        if (u.slot_type < kinds.len) @compileError("kinds: an unstored kind overlaps a stored one");
        for (unstored[0..i]) |v| {
            if (v.slot_type == u.slot_type) @compileError("kinds: an unstored kind twice");
        }
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
/// `[body.start + i]`). `slots(.i32, body)` is `body.slots.i32` as a
/// `[*]c.MVMint32`. Every caller is about to read or write a slot; where
/// the C does that through NULL slots (an array whose storage a recompose
/// to a kind without storage left NULL, `moar.nullDeref`'s case) this
/// faults at the null page instead of forming a NULL `[*]`.
pub fn slots(comptime k: Kind, body: *c.MVMArrayBody) [*]Elem(k) {
    const p = @field(body.slots, info(k).member);
    if (p == null) moar.nullDeref(0);
    return p;
}

/// What `dispatch` does for a slot type that is not a stored kind (one of
/// the six without storage, or a value no kind has), when no function is
/// given for it. Each operation states the C's behaviour for it
/// (va-kind-differences.md section 3).
pub const Otherwise = union(enum) {
    /// `MVM_exception_throw_adhoc(tc, message)`, the C's `default:` arm.
    /// The first of `dispatch`'s `args` must be the thread context. The
    /// message is passed as the format with no arguments, so it must not
    /// contain `%`; `dispatch` refuses one that does at compile time.
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
            .throw => |message| {
                // The message is the printf format of the throw, with no
                // arguments: a `%` in it would read an argument that is not
                // there. Checked here, where the text becomes a format.
                if (comptime std.mem.findScalar(u8, message, '%') != null)
                    @compileError("dispatch: the Otherwise.throw message \"" ++ message ++
                        "\" contains '%', but it is passed as a printf format with no arguments;" ++
                        " write a function for `otherwise` that passes the text as an argument");
                c.MVM_exception_throw_adhoc(args[0], message.ptr);
            },
            .abort => std.c.abort(),
            .nothing => {
                if (ReturnOf(f) != void) @compileError("dispatch: .nothing needs f to return void");
                return;
            },
        },
    }
}
