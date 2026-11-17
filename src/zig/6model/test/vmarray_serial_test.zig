//! Tests of the array's type-level hooks (`reprs/vmarray/serial.zig`:
//! composition, type creation, serialization) and of its specializer and
//! JIT hooks (`reprs/vmarray/spesh.zig`), on a booted VM. As in
//! vmarray_elements_test.zig, whose `Vm` and arrays these tests use, the
//! Zig functions are called directly, over `moar.mvm_allocator`, on arrays
//! the linked library made. Only paths that do not throw are tested (spec
//! 7.1).
//!
//! The serialization reader and writer are driven as
//! src/6model/serialization.c drives them for an object body: a reader or
//! writer whose `cur_read_*`/`cur_write_*` fields point at one buffer.
//! Without a serialization context only the integer and num readers and
//! writers work that way (strings and references go through the context's
//! string heap and dependency tables), so the element round trip covers the
//! ten numeric kinds; OBJ and STR, and the nested deserialization, are
//! covered by the whole-run serialization checks
//! (tools/bench/repr/vmarray-serial.nqp).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const repr = @import("../repr.zig");
const kinds = @import("../reprs/vmarray/kinds.zig");
const storage = @import("../reprs/vmarray/storage.zig");
const serial = @import("../reprs/vmarray/serial.zig");
const spesh = @import("../reprs/vmarray/spesh.zig");
const et = @import("vmarray_elements_test.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Kind = kinds.Kind;
const Reg = c.MVMRegister;
const Vm = et.Vm;
const A = et.A;
const E = et.E;

/// The storage over the production allocator, as `E`'s.
const S = storage.Storage(struct {
    pub fn get() std.mem.Allocator {
        return moar.mvm_allocator;
    }
});
const Ser = serial.Serial(S);

/// For the hooks that never read `tc` (`gcFreeReprData` of an STable
/// without REPR data, `deserializeStableSize`): no VM is booted for them.
const no_tc: [*c]c.MVMThreadContext = undefined;

// ---- spec_to_repr_data -------------------------------------------------

const Row = struct { bp: u16, bits: u16, unsigned: u8, slot_type: u8, elem_size: usize };

/// What the REPR data holds before each row; a row that changes nothing
/// expects it back.
const before = Row{ .bp = 0, .bits = 0, .unsigned = 0, .slot_type = 99, .elem_size = 77 };

fn unchanged(bp: u16, bits: u16) Row {
    return .{ .bp = bp, .bits = bits, .unsigned = 0, .slot_type = before.slot_type, .elem_size = before.elem_size };
}

/// Every non-throwing case of `spec_to_repr_data` (VMArray.c:1224-1319),
/// written out from the C: (boxed_primitive, bits, is_unsigned) -> (slot
/// type, element size).
const spec_rows = [_]Row{
    // BP_INT, signed: 64/32/16/8 bits stored, 4/2/1 without storage.
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 64, .unsigned = 0, .slot_type = c.MVM_ARRAY_I64, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 32, .unsigned = 0, .slot_type = c.MVM_ARRAY_I32, .elem_size = 4 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 16, .unsigned = 0, .slot_type = c.MVM_ARRAY_I16, .elem_size = 2 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 8, .unsigned = 0, .slot_type = c.MVM_ARRAY_I8, .elem_size = 1 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 4, .unsigned = 0, .slot_type = c.MVM_ARRAY_I4, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 2, .unsigned = 0, .slot_type = c.MVM_ARRAY_I2, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 1, .unsigned = 0, .slot_type = c.MVM_ARRAY_I1, .elem_size = 0 },
    // BP_INT, unsigned: is_unsigned picks U, whatever the box kind.
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 64, .unsigned = 1, .slot_type = c.MVM_ARRAY_U64, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 32, .unsigned = 1, .slot_type = c.MVM_ARRAY_U32, .elem_size = 4 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 16, .unsigned = 1, .slot_type = c.MVM_ARRAY_U16, .elem_size = 2 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 8, .unsigned = 1, .slot_type = c.MVM_ARRAY_U8, .elem_size = 1 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 4, .unsigned = 1, .slot_type = c.MVM_ARRAY_U4, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 2, .unsigned = 1, .slot_type = c.MVM_ARRAY_U2, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_INT, .bits = 1, .unsigned = 1, .slot_type = c.MVM_ARRAY_U1, .elem_size = 0 },
    // BP_UINT64 shares the branch: without is_unsigned it makes a signed array.
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 64, .unsigned = 0, .slot_type = c.MVM_ARRAY_I64, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 32, .unsigned = 0, .slot_type = c.MVM_ARRAY_I32, .elem_size = 4 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 16, .unsigned = 0, .slot_type = c.MVM_ARRAY_I16, .elem_size = 2 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 8, .unsigned = 0, .slot_type = c.MVM_ARRAY_I8, .elem_size = 1 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 4, .unsigned = 0, .slot_type = c.MVM_ARRAY_I4, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 2, .unsigned = 0, .slot_type = c.MVM_ARRAY_I2, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 1, .unsigned = 0, .slot_type = c.MVM_ARRAY_I1, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 64, .unsigned = 1, .slot_type = c.MVM_ARRAY_U64, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 32, .unsigned = 1, .slot_type = c.MVM_ARRAY_U32, .elem_size = 4 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 16, .unsigned = 1, .slot_type = c.MVM_ARRAY_U16, .elem_size = 2 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 8, .unsigned = 1, .slot_type = c.MVM_ARRAY_U8, .elem_size = 1 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 4, .unsigned = 1, .slot_type = c.MVM_ARRAY_U4, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 2, .unsigned = 1, .slot_type = c.MVM_ARRAY_U2, .elem_size = 0 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_UINT64, .bits = 1, .unsigned = 1, .slot_type = c.MVM_ARRAY_U1, .elem_size = 0 },
    // BP_NUM: 64 and 32 bits; is_unsigned is not looked at.
    .{ .bp = c.MVM_STORAGE_SPEC_BP_NUM, .bits = 64, .unsigned = 0, .slot_type = c.MVM_ARRAY_N64, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_NUM, .bits = 32, .unsigned = 0, .slot_type = c.MVM_ARRAY_N32, .elem_size = 4 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_NUM, .bits = 64, .unsigned = 1, .slot_type = c.MVM_ARRAY_N64, .elem_size = 8 },
    // BP_STR: bits are not looked at.
    .{ .bp = c.MVM_STORAGE_SPEC_BP_STR, .bits = 0, .unsigned = 0, .slot_type = c.MVM_ARRAY_STR, .elem_size = 8 },
    .{ .bp = c.MVM_STORAGE_SPEC_BP_STR, .bits = 64, .unsigned = 1, .slot_type = c.MVM_ARRAY_STR, .elem_size = 8 },
    // Every other box kind changes nothing (row 31b).
    unchanged(c.MVM_STORAGE_SPEC_BP_NONE, 0),
    unchanged(c.MVM_STORAGE_SPEC_BP_NONE, 64),
    unchanged(c.MVM_STORAGE_SPEC_BP_INT8, 8),
    unchanged(c.MVM_STORAGE_SPEC_BP_INT16, 16),
    unchanged(c.MVM_STORAGE_SPEC_BP_INT32, 32),
    unchanged(c.MVM_STORAGE_SPEC_BP_UINT8, 8),
    unchanged(c.MVM_STORAGE_SPEC_BP_UINT16, 16),
    unchanged(c.MVM_STORAGE_SPEC_BP_UINT32, 32),
};

test "specToReprData maps each storage spec to the C's slot type and element size" {
    // `specToReprData` reads `tc` only to throw, and no row below throws;
    // it gets a real one all the same, so a row that did throw would fail
    // as the VM fails, not through an undefined pointer.
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    for (spec_rows) |row| {
        var rd: c.MVMArrayREPRData = .{ .elem_size = before.elem_size, .slot_type = before.slot_type, .elem_type = null };
        const spec: c.MVMStorageSpec = .{
            .inlineable = c.MVM_STORAGE_SPEC_INLINED,
            .bits = row.bits,
            .@"align" = 0,
            .boxed_primitive = row.bp,
            .can_box = 0,
            .is_unsigned = row.unsigned,
        };
        serial.specToReprData(vm.tc, &rd, &spec);
        expectEqual(row.slot_type, rd.slot_type) catch |e| {
            std.debug.print("row bp={d} bits={d} unsigned={d}\n", .{ row.bp, row.bits, row.unsigned });
            return e;
        };
        try expectEqual(row.elem_size, rd.elem_size);
        try expect(rd.elem_type == null);
    }
}

// ---- deserialize ---------------------------------------------------------

/// A reader over `bytes` as serialization.c sets one up for an object
/// body: the current buffer, offset and end. Not movable once `init` has
/// pointed the reader at its own fields.
const OneBuffer = struct {
    buf: [*c]u8,
    offset: c.MVMint32,
    end: [*c]u8,
    reader: c.MVMSerializationReader,

    fn init(self: *OneBuffer, bytes: []u8) void {
        self.buf = bytes.ptr;
        self.offset = 0;
        self.end = bytes.ptr + bytes.len;
        self.reader = std.mem.zeroes(c.MVMSerializationReader);
        self.reader.cur_read_buffer = &self.buf;
        self.reader.cur_read_offset = &self.offset;
        self.reader.cur_read_end = &self.end;
    }
};

/// A writer as serialization.c sets one up: an `MVM_malloc`ed buffer that
/// `MVM_serialization_write_*` grows with `MVM_realloc`.
const GrowBuffer = struct {
    buf: [*c]u8,
    offset: c.MVMuint32,
    limit: c.MVMuint32,
    writer: c.MVMSerializationWriter,

    fn init(self: *GrowBuffer) void {
        self.limit = 16;
        self.buf = @ptrCast(c.MVM_malloc(self.limit));
        self.offset = 0;
        self.writer = std.mem.zeroes(c.MVMSerializationWriter);
        self.writer.cur_write_buffer = &self.buf;
        self.writer.cur_write_offset = &self.offset;
        self.writer.cur_write_limit = &self.limit;
    }
    fn written(self: *const GrowBuffer) []u8 {
        return self.buf[0..self.offset];
    }
    fn deinit(self: *GrowBuffer) void {
        c.MVM_free(self.buf);
    }
};

/// The state of a body that the tests compare: its fields, whether it has
/// storage, and its whole storage as bytes.
fn expectSameBody(comptime k: Kind, want: *const c.MVMArrayBody, got: *const c.MVMArrayBody) !void {
    try expectEqual(want.elems, got.elems);
    try expectEqual(want.start, got.start);
    try expectEqual(want.ssize, got.ssize);
    try expectEqual(want.slots.any == null, got.slots.any == null);
    if (want.slots.any) |w| {
        const n = want.ssize * kinds.info(k).elem_size;
        const wb: [*]const u8 = @ptrCast(w);
        const gb: [*]const u8 = @ptrCast(got.slots.any.?);
        try std.testing.expectEqualSlices(u8, wb[0..n], gb[0..n]);
    }
}

/// A fresh array of kind `k` that has deserialized zero elements: the
/// one-byte serialized 0 (`MVM_serialization_write_int` of 0 is 0x81).
fn deserializedEmpty(vm: *Vm, comptime k: Kind) !A {
    const a = vm.new(k);
    var bytes = [_]u8{0x81};
    var one: OneBuffer = undefined;
    one.init(&bytes);
    Ser.deserialize(vm.tc, a.st(), a.o, a.body(), &one.reader);
    try expectEqual(@as(c.MVMint32, 1), one.offset);
    return a;
}

test "an empty array deserialized has no storage and then behaves as a fresh one" {
    // Twelve kinds times four operations, unrolled at compile time.
    @setEvalBranchQuota(20_000);
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        // No storage requested, as the C's `if (body->ssize)`.
        {
            var d = try deserializedEmpty(&vm, k);
            const r = moar.root(tc, &d.o);
            defer r.pop(tc);
            try expect(d.body().slots.any == null);
            try expectEqual(@as(u64, 0), d.body().ssize);
            try expectEqual(@as(u64, 0), d.body().elems);
            try expectEqual(@as(u64, 0), d.body().start);
        }
        // Then each operation leaves it as it leaves a fresh array.
        const ops = [_][]const u8{ "push", "unshift", "setElems", "copyTo" };
        inline for (ops) |op| {
            var d = try deserializedEmpty(&vm, k);
            var f = vm.new(k);
            const r = moar.rootN(tc, .{ &d.o, &f.o });
            defer r.pop(tc);
            if (comptime std.mem.eql(u8, op, "copyTo")) {
                var dd = std.mem.zeroes(c.MVMArrayBody);
                var fd = std.mem.zeroes(c.MVMArrayBody);
                E.copyTo(tc, d.st(), d.body(), null, &dd);
                E.copyTo(tc, f.st(), f.body(), null, &fd);
                try expectSameBody(k, &fd, &dd);
                try expect(dd.slots.any == null);
            } else {
                inline for (.{ d, f }) |a| {
                    if (comptime std.mem.eql(u8, op, "push")) a.push(tc, k, et.sample(&vm, k, 1));
                    if (comptime std.mem.eql(u8, op, "unshift")) a.unshift(tc, k, et.sample(&vm, k, 2));
                    if (comptime std.mem.eql(u8, op, "setElems")) E.setElems(tc, a.st(), a.o, a.body(), 3);
                }
                try expectSameBody(k, f.body(), d.body());
            }
        }
    }
}

/// Register values for the round trip beyond `sample`: the integer
/// extremes (narrowed on push, so every width sees all-ones and sign bits)
/// and nums that N32 rounds or overflows.
fn extremes(comptime k: Kind) [4]Reg {
    var out: [4]Reg = @splat(std.mem.zeroes(Reg));
    switch (@typeInfo(kinds.Elem(k))) {
        .int => |i| if (i.signedness == .signed) {
            out[0].i64 = -1;
            out[1].i64 = std.math.minInt(i64);
            out[2].i64 = std.math.maxInt(i64);
            out[3].i64 = -129;
        } else {
            out[0].u64 = std.math.maxInt(u64);
            out[1].u64 = 1 << 63;
            out[2].u64 = 0x8000_0001;
            out[3].u64 = 0xFFFF_FF80;
        },
        .float => {
            out[0].n64 = -0.0;
            out[1].n64 = std.math.inf(f64);
            out[2].n64 = 1e39;
            out[3].n64 = 0.1;
        },
        else => comptime unreachable,
    }
    return out;
}

test "serialize writes the library's bytes and deserialize reads them back, for every numeric kind" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        if (comptime ki.holds_refs) continue;
        // Shifted, so start > 0 (the C writes from start), with samples and
        // extremes.
        var a = et.filled(&vm, k, &.{ 9, 0, 1, 2 });
        var b = vm.new(k);
        const r = moar.rootN(tc, .{ &a.o, &b.o });
        defer r.pop(tc);
        var dropped: Reg = undefined;
        E.shift(tc, a.st(), a.o, a.body(), &dropped, ki.stack_reg_kinds[0]);
        for (extremes(k)) |v| a.push(tc, k, v);
        try expect(a.body().start == 1);

        var mine: GrowBuffer = undefined;
        mine.init();
        defer mine.deinit();
        Ser.serialize(tc, a.st(), a.body(), &mine.writer);
        // The linked library's own serialize writes the same bytes. With
        // -Dzig-reprs=false that is the C array, so this compares the Zig
        // with the C; in the default build the library's array is this Zig
        // array, so there the comparison is Zig against Zig, and the C
        // comparison is the -Dzig-reprs=false run of this test.
        var lib: GrowBuffer = undefined;
        lib.init();
        defer lib.deinit();
        a.st().*.REPR.*.serialize.?(tc, a.st(), a.body(), &lib.writer);
        try std.testing.expectEqualSlices(u8, lib.written(), mine.written());

        var one: OneBuffer = undefined;
        one.init(mine.written());
        Ser.deserialize(tc, b.st(), b.o, b.body(), &one.reader);
        try expectEqual(@as(c.MVMint32, @intCast(mine.offset)), one.offset);
        try expectEqual(a.body().elems, b.body().elems);
        try expectEqual(a.body().elems, b.body().ssize);
        try expectEqual(@as(u64, 0), b.body().start);
        const n = a.body().elems * ki.elem_size;
        const from: [*]const u8 = @ptrCast(kinds.slots(k, a.body()) + a.body().start);
        const to: [*]const u8 = @ptrCast(kinds.slots(k, b.body()));
        try std.testing.expectEqualSlices(u8, from[0..n], to[0..n]);
    }
}

// ---- type creation and the REPR data's lifetime ------------------------

/// A table built from the hooks under test, for `typeObjectFor` to put in
/// the STables it makes (VMArray.zig does the same with all of the
/// array's functions; this test root must not import it, as it exports
/// the symbols the linked library defines).
const TestArray = struct {
    pub const name = "VMArray";
    pub const ID = c.MVM_REPR_ID_VMArray;
    pub const type_object_for = Ser.typeObjectFor(&test_table);
    pub const allocate = &c.MVM_gc_allocate_object;
    pub const get_storage_spec = E.getStorageSpec;
    pub const compose = Ser.compose;
    pub const gc_free_repr_data = Ser.gcFreeReprData;
};
const test_table: c.MVMREPROps = repr.Ops(TestArray);

test "typeObjectFor gives an object array type" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    const t = test_table.type_object_for.?(tc, null);
    const st = t.*.st;
    try expect(st.*.WHAT == t);
    try expect(st.*.REPR == &test_table);
    try expect(!moar.isConcrete(t));
    try expectEqual(@as(c.MVMuint32, @sizeOf(c.MVMArray)), st.*.size);
    const rd: *c.MVMArrayREPRData = @ptrCast(@alignCast(st.*.REPR_data.?));
    try expectEqual(@as(u8, c.MVM_ARRAY_OBJ), rd.slot_type);
    try expectEqual(@as(usize, 8), rd.elem_size);
    try expect(rd.elem_type == null);
}

test "gcFreeReprData leaves an STable without REPR data alone" {
    // A stubbed STable that was never deserialized: the C's MVM_free(NULL).
    var st = std.mem.zeroes(c.MVMSTable);
    Ser.gcFreeReprData(no_tc, &st);
    try expect(st.REPR_data == null);
}

test "deserializeStableSize sets the size of an MVMArray" {
    var st = std.mem.zeroes(c.MVMSTable);
    Ser.deserializeStableSize(no_tc, &st, null);
    try expectEqual(@as(c.MVMuint32, @sizeOf(c.MVMArray)), st.size);
}

// ---- the specializer's and the JIT's hooks -------------------------------

extern fn moar_probe_offsetof_opinfo_opcode() usize;
extern fn moar_probe_sizeof_opinfo_opcode() usize;

test "OpInfoHead mirrors the opcode field of MVMOpInfo" {
    try expectEqual(moar_probe_offsetof_opinfo_opcode(), @offsetOf(spesh.OpInfoHead, "opcode"));
    try expectEqual(moar_probe_sizeof_opinfo_opcode(), @sizeOf(@FieldType(spesh.OpInfoHead, "opcode")));
    // And it reads what the op table holds.
    const info = c.MVM_op_get_op(c.MVM_OP_elems);
    try expectEqual(@as(c.MVMuint16, c.MVM_OP_elems), @as(*const spesh.OpInfoHead, @ptrCast(@alignCast(info.?))).opcode);
}

const find = spesh.findFastImplForJit(E);

/// VMArray.c:1605-1645 spelled out: which function the C returns for `op`
/// with register kind `kind` on an array of `slot_type`.
fn wantFast(op: c_int, kind: u16, slot_type: usize) enum { at, bind, none } {
    if (op == c.MVM_OP_atpos_i and kind == c.MVM_reg_int64 and slot_type == c.MVM_ARRAY_I64) return .at;
    if (op == c.MVM_OP_atpos_u and kind == c.MVM_reg_uint64 and slot_type == c.MVM_ARRAY_U64) return .at;
    if (op == c.MVM_OP_bindpos_i and kind == c.MVM_reg_int64 and slot_type == c.MVM_ARRAY_I64) return .bind;
    if (op == c.MVM_OP_bindpos_u and kind == c.MVM_reg_uint64 and slot_type == c.MVM_ARRAY_U64) return .bind;
    return .none;
}

test "findFastImplForJit offers the C's (op, register kind, slot kind) triples and nothing else" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    const at: ?*anyopaque = @ptrCast(@constCast(&E.atPosKind(.i64).jit));
    const bind: ?*anyopaque = @ptrCast(@constCast(&E.bindPosKind(.i64).jit));
    const ops = [_]c_int{ c.MVM_OP_atpos_i, c.MVM_OP_atpos_u, c.MVM_OP_bindpos_i, c.MVM_OP_bindpos_u, c.MVM_OP_atpos_n, c.MVM_OP_atpos_o, c.MVM_OP_bindpos_n, c.MVM_OP_atpos_s, c.MVM_OP_elems };
    const reg_kinds = [_]u16{ c.MVM_reg_int64, c.MVM_reg_uint64, c.MVM_reg_num64, c.MVM_reg_obj, c.MVM_reg_str, c.MVM_reg_int32 };
    for (vm.types, 0..) |type_obj, slot_type| {
        for (ops) |op| {
            for (reg_kinds) |kind| {
                const want: ?*anyopaque = switch (wantFast(op, kind, slot_type)) {
                    .at => at,
                    .bind => bind,
                    .none => null,
                };
                try expectEqual(want, find(tc, type_obj.?.st, @intCast(op), kind));
            }
        }
    }
    // A stubbed STable (no REPR data): the C reads it only for an op it
    // has a case for, with that case's register kind.
    var stub = std.mem.zeroes(c.MVMSTable);
    try expectEqual(@as(?*anyopaque, null), find(tc, &stub, c.MVM_OP_atpos_i, c.MVM_reg_num64));
    try expectEqual(@as(?*anyopaque, null), find(tc, &stub, c.MVM_OP_bindpos_u, c.MVM_reg_int64));
    try expectEqual(@as(?*anyopaque, null), find(tc, &stub, c.MVM_OP_elems, c.MVM_reg_int64));
}
