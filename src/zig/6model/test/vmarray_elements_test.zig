//! Tests of the array's element operations (`reprs/vmarray/elements.zig`)
//! and its collector hooks (`reprs/vmarray/mark.zig`) on a booted VM. The
//! arrays are allocated by the linked library (`MVM_repr_alloc_init`), whose
//! VMArray is still the C one; the Zig functions are called directly on
//! them, with the storage over `moar.mvm_allocator`, so the library frees
//! what the Zig code allocated. Only paths that do not throw are tested
//! here (spec 7.1): a throw longjmps out of the test. The throwing paths
//! and their messages are covered by the differential programs.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const kinds = @import("../reprs/vmarray/kinds.zig");
const storage = @import("../reprs/vmarray/storage.zig");
const elements = @import("../reprs/vmarray/elements.zig");
const mark = @import("../reprs/vmarray/mark.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Kind = kinds.Kind;
const Reg = c.MVMRegister;
const Object = c.MVMObject;

/// The element operations over the production allocator.
const E = elements.Elements(storage.Storage(struct {
    pub fn get() std.mem.Allocator {
        return moar.mvm_allocator;
    }
}));

const n_samples = 32;

/// A booted VM with an array type per kind and gen2 sample values. The
/// types and samples are permanent roots, so the struct must stay where
/// `boot` was called on it until `deinit`.
const Vm = struct {
    instance: *c.MVMInstance,
    tc: *c.MVMThreadContext,
    types: [kinds.kinds.len]?*Object,
    objs: [n_samples]?*Object,
    strs: [n_samples]?*c.MVMString,

    fn boot(vm: *Vm) void {
        vm.instance = c.MVM_vm_create_instance();
        vm.tc = vm.instance.main_thread;
        const tc = vm.tc;
        const boot_types = &vm.instance.boot_types;
        // Everything made here is in gen2, so no nursery collection moves it.
        c.MVM_gc_allocate_gen2_default_set(tc);
        defer c.MVM_gc_allocate_gen2_default_clear(tc);
        inline for (kinds.kinds) |ki| {
            const slot = &vm.types[@backingInt(ki.kind)];
            slot.* = switch (ki.kind) {
                // The boot types for the four kinds the VM has them for.
                .obj => boot_types.BOOTArray,
                .str => boot_types.BOOTStrArray,
                .i64 => boot_types.BOOTIntArray,
                .n64 => boot_types.BOOTNumArray,
                else => composedArray(tc, elemType(tc, ki.kind)),
            };
            c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(slot), "vmarray test type");
        }
        for (&vm.objs, &vm.strs, 0..) |*o, *s, i| {
            o.* = c.MVM_repr_box_int(tc, boot_types.BOOTInt, 1000 + @as(i64, @intCast(i)));
            s.* = c.MVM_coerce_i_s(tc, 2000 + @as(i64, @intCast(i)));
            c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(o), "vmarray test object");
            c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(s), "vmarray test string");
        }
        for (vm.types, 0..) |t, i| std.debug.assert(reprData(t.?).slot_type == i);
    }

    fn deinit(vm: *Vm) void {
        c.MVM_vm_destroy_instance(vm.instance);
    }

    /// A fresh, empty nursery array of kind `k`.
    fn new(vm: *Vm, k: Kind) A {
        return .{ .o = c.MVM_repr_alloc_init(vm.tc, vm.types[@backingInt(k)]) };
    }

    /// A fresh, empty gen2 array of kind `k`.
    fn newGen2(vm: *Vm, k: Kind) A {
        c.MVM_gc_allocate_gen2_default_set(vm.tc);
        defer c.MVM_gc_allocate_gen2_default_clear(vm.tc);
        return vm.new(k);
    }
};

fn reprData(type_obj: *Object) *c.MVMArrayREPRData {
    return @ptrCast(@alignCast(type_obj.st.*.REPR_data));
}

/// A VMArray type composed as `boot_typed_array` (bootstrap.c) does, with
/// `{ array => { type => elem_type } }`; no element type gives an OBJ array.
fn composedArray(tc: *c.MVMThreadContext, elem_type: ?*Object) *Object {
    const repr = c.MVM_repr_get_by_id(tc, c.MVM_REPR_ID_VMArray);
    const array = repr.*.type_object_for.?(tc, null);
    if (elem_type) |t| {
        const consts = tc.instance.*.str_consts;
        const info = c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTHash);
        const arr_info = c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTHash);
        c.MVM_repr_bind_key_o(tc, arr_info, consts.type, t);
        c.MVM_repr_bind_key_o(tc, info, consts.array, arr_info);
        c.MVM_repr_compose(tc, array, info);
    }
    return array;
}

/// A native element type for kind `k`: `BOOTStr`, or a P6int / P6num type
/// composed with the kind's width and signedness. `bits` overrides the
/// width (4, 2 or 1 give the kinds without storage).
fn nativeType(tc: *c.MVMThreadContext, repr_id: c_int, key: [*c]c.MVMString, bits: i64, unsigned: bool) *Object {
    const consts = tc.instance.*.str_consts;
    const boot_types = &tc.instance.*.boot_types;
    const t = c.MVM_repr_get_by_id(tc, @intCast(repr_id)).*.type_object_for.?(tc, null);
    const info = c.MVM_repr_alloc_init(tc, boot_types.BOOTHash);
    const sub = c.MVM_repr_alloc_init(tc, boot_types.BOOTHash);
    c.MVM_repr_bind_key_o(tc, sub, consts.bits, c.MVM_repr_box_int(tc, boot_types.BOOTInt, bits));
    if (unsigned) c.MVM_repr_bind_key_o(tc, sub, consts.unsigned_str, c.MVM_repr_box_int(tc, boot_types.BOOTInt, 1));
    c.MVM_repr_bind_key_o(tc, info, key, sub);
    c.MVM_repr_compose(tc, t, info);
    return t;
}

fn elemType(tc: *c.MVMThreadContext, comptime k: Kind) ?*Object {
    const T = kinds.Elem(k);
    return switch (@typeInfo(T)) {
        .pointer => if (k == .obj) null else tc.instance.*.boot_types.BOOTStr,
        .int => |i| nativeType(tc, c.MVM_REPR_ID_P6int, tc.instance.*.str_consts.integer, i.bits, i.signedness == .unsigned),
        .float => |f| nativeType(tc, c.MVM_REPR_ID_P6num, tc.instance.*.str_consts.float_str, f.bits, false),
        else => comptime unreachable,
    };
}

/// An array object and the calls the tests make on it. Each operation
/// passes the kind's own register kind (`reg_kind`, or the one
/// `stack_reg_kinds` accepts for push, pop, shift and unshift).
const A = struct {
    o: ?*Object,

    fn st(a: A) [*c]c.MVMSTable {
        return a.o.?.st;
    }
    fn body(a: A) *c.MVMArrayBody {
        return &@as(*c.MVMArray, @ptrCast(@alignCast(a.o.?))).body;
    }
    fn elems(a: A) u64 {
        return a.body().elems;
    }
    fn push(a: A, tc: *c.MVMThreadContext, comptime k: Kind, v: Reg) void {
        E.push(tc, a.st(), a.o, a.body(), v, kinds.info(k).stack_reg_kinds[0]);
    }
    fn unshift(a: A, tc: *c.MVMThreadContext, comptime k: Kind, v: Reg) void {
        E.unshift(tc, a.st(), a.o, a.body(), v, kinds.info(k).stack_reg_kinds[0]);
    }
    fn pop(a: A, tc: *c.MVMThreadContext, comptime k: Kind) Reg {
        var r: Reg = undefined;
        E.pop(tc, a.st(), a.o, a.body(), &r, kinds.info(k).stack_reg_kinds[0]);
        return r;
    }
    fn shift(a: A, tc: *c.MVMThreadContext, comptime k: Kind) Reg {
        var r: Reg = undefined;
        E.shift(tc, a.st(), a.o, a.body(), &r, kinds.info(k).stack_reg_kinds[0]);
        return r;
    }
    fn at(a: A, tc: *c.MVMThreadContext, comptime k: Kind, i: i64) Reg {
        var r: Reg = undefined;
        E.atPos(tc, a.st(), a.o, a.body(), i, &r, kinds.info(k).reg_kind);
        return r;
    }
    fn bind(a: A, tc: *c.MVMThreadContext, comptime k: Kind, i: i64, v: Reg) void {
        E.bindPos(tc, a.st(), a.o, a.body(), i, v, kinds.info(k).reg_kind);
    }
    /// The raw slot `i` (start not added) as bytes.
    fn slotBytes(a: A, comptime k: Kind, i: u64) []const u8 {
        return std.mem.asBytes(&kinds.slots(k, a.body())[i]);
    }
};

/// Sample value `i` of kind `k` in its register member: a gen2 object or
/// string of the VM, `3i + 1` for the integers (exact in every width) and
/// `i + 0.5` for the nums (exact in f32).
fn sample(vm: *const Vm, comptime k: Kind, i: usize) Reg {
    var r = std.mem.zeroes(Reg);
    switch (@typeInfo(kinds.Elem(k))) {
        .pointer => if (k == .obj) {
            r.o = vm.objs[i];
        } else {
            r.s = vm.strs[i];
        },
        .int => @field(r, kinds.info(k).reg) = @intCast(i * 3 + 1),
        .float => r.n64 = @as(f64, @floatFromInt(i)) + 0.5,
        else => comptime unreachable,
    }
    return r;
}

/// What `at_pos` gives for a hole or past `elems`: VMNull for OBJ, NULL
/// for STR, zero otherwise (va-kind-differences.md row 12c).
fn hole(vm: *const Vm, comptime k: Kind) Reg {
    var r = std.mem.zeroes(Reg);
    if (k == .obj) r.o = vm.instance.VMNull;
    return r;
}

fn expectReg(comptime k: Kind, want: Reg, got: Reg) !void {
    const m = kinds.info(k).reg;
    try expectEqual(@field(want, m), @field(got, m));
}

fn expectZeroBytes(bytes: []const u8) !void {
    for (bytes) |b| try expectEqual(@as(u8, 0), b);
}

/// Expects the array to hold the samples `want` (indices into `sample`).
fn expectSamples(vm: *Vm, a: A, comptime k: Kind, want: []const usize) !void {
    try expectEqual(@as(u64, want.len), a.elems());
    for (want, 0..) |w, i| try expectReg(k, sample(vm, k, w), a.at(vm.tc, k, @intCast(i)));
}

/// An array of kind `k` holding the samples `which`.
fn filled(vm: *Vm, comptime k: Kind, which: []const usize) A {
    const a = vm.new(k);
    for (which) |w| a.push(vm.tc, k, sample(vm, k, w));
    return a;
}

test "push then pop returns the value, and pop clears the slot" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = vm.new(k);
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        for (0..3) |i| a.push(tc, k, sample(&vm, k, i));
        try expectEqual(@as(u64, 3), a.elems());
        try expectEqual(@as(u64, 8), a.body().ssize);
        var i: usize = 3;
        while (i > 0) {
            i -= 1;
            try expectReg(k, sample(&vm, k, i), a.pop(tc, k));
            try expectZeroBytes(a.slotBytes(k, i));
        }
        try expectEqual(@as(u64, 0), a.elems());
    }
}

test "unshift then shift returns the values, making front room as the C" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        // On an empty array: 8 slots of front room, start 8 - 1.
        var a = vm.new(k);
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        a.unshift(tc, k, sample(&vm, k, 0));
        try expectEqual(@as(u64, 7), a.body().start);
        try expectEqual(@as(u64, 8), a.body().ssize);
        a.unshift(tc, k, sample(&vm, k, 1));
        a.unshift(tc, k, sample(&vm, k, 2));
        try expectSamples(&vm, a, k, &.{ 2, 1, 0 });
        try expectReg(k, sample(&vm, k, 2), a.shift(tc, k));
        try expectReg(k, sample(&vm, k, 1), a.shift(tc, k));
        try expectReg(k, sample(&vm, k, 0), a.shift(tc, k));
        try expectEqual(@as(u64, 0), a.elems());
        try expectEqual(@as(u64, 8), a.body().start);

        // On an array with elements and start 0: min(max(elems, 8), 8192)
        // slots of room, the elements moved behind it.
        var b = filled(&vm, k, &.{ 3, 4 });
        const rb = moar.root(tc, &b.o);
        defer rb.pop(tc);
        b.unshift(tc, k, sample(&vm, k, 5));
        try expectEqual(@as(u64, 7), b.body().start);
        try expectEqual(@as(u64, 16), b.body().ssize);
        try expectSamples(&vm, b, k, &.{ 5, 3, 4 });
        try expectZeroBytes(std.mem.sliceAsBytes(kinds.slots(k, b.body())[0..7]));
    }
}

test "bindPos beyond elems grows and zero-fills the gap" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = vm.new(k);
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        a.bind(tc, k, 5, sample(&vm, k, 7));
        try expectEqual(@as(u64, 6), a.elems());
        try expectEqual(@as(u64, 8), a.body().ssize);
        for (0..5) |i| try expectZeroBytes(a.slotBytes(k, i));
        try expectReg(k, sample(&vm, k, 7), a.at(tc, k, 5));
        // A hole reads as the kind's null (OBJ: VMNull, row 12c).
        try expectReg(k, hole(&vm, k), a.at(tc, k, 2));
        // Within elems: no growth.
        a.bind(tc, k, 1, sample(&vm, k, 8));
        try expectEqual(@as(u64, 6), a.elems());
        try expectReg(k, sample(&vm, k, 8), a.at(tc, k, 1));
    }
}

test "atPos past elems gives the kind's null or zero, for every accepted register kind" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = filled(&vm, k, &.{ 0, 1 });
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        inline for (ki.reg_kinds) |rk| {
            for ([_]i64{ 2, 7, 100, std.math.maxInt(i64) }) |i| {
                var got: Reg = undefined;
                E.atPos(tc, a.st(), a.o, a.body(), i, &got, rk);
                try expectReg(k, hole(&vm, k), got);
            }
            var got: Reg = undefined;
            E.atPos(tc, a.st(), a.o, a.body(), 1, &got, rk);
            try expectReg(k, sample(&vm, k, 1), got);
        }
    }
}

test "a negative index within range resolves from the end" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = filled(&vm, k, &.{ 0, 1, 2 });
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        try expectReg(k, sample(&vm, k, 2), a.at(tc, k, -1));
        try expectReg(k, sample(&vm, k, 0), a.at(tc, k, -3));
        a.bind(tc, k, -3, sample(&vm, k, 9));
        a.bind(tc, k, -1, sample(&vm, k, 10));
        try expectSamples(&vm, a, k, &.{ 9, 1, 10 });
    }
}

test "setElems grows with zeroed slots and shrinks clearing the dropped ones" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = filled(&vm, k, &.{ 0, 1, 2 });
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        E.setElems(tc, a.st(), a.o, a.body(), 10);
        try expectEqual(@as(u64, 10), a.elems());
        try expectEqual(@as(u64, 16), a.body().ssize);
        for (3..16) |i| try expectZeroBytes(a.slotBytes(k, i));
        try expectReg(k, sample(&vm, k, 2), a.at(tc, k, 2));
        E.setElems(tc, a.st(), a.o, a.body(), 2);
        try expectEqual(@as(u64, 2), a.elems());
        try expectEqual(@as(u64, 16), a.body().ssize);
        try expectZeroBytes(a.slotBytes(k, 2));
        try expectSamples(&vm, a, k, &.{ 0, 1 });
        // setDimensions with one dimension is setElems.
        var dims = [_]i64{4};
        E.setDimensions(tc, a.st(), a.o, a.body(), 1, &dims);
        try expectEqual(@as(u64, 4), a.elems());
    }
}

test "aslice copies the inclusive range, negative ends from the end" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var src = filled(&vm, k, &.{ 0, 1, 2, 3, 4, 5 });
        var d1 = vm.new(k);
        var d2 = vm.new(k);
        const r = moar.rootN(tc, .{ &src.o, &d1.o, &d2.o });
        defer r.pop(tc);
        E.aslice(tc, src.st(), src.o, src.body(), d1.o, 1, 3);
        try expectSamples(&vm, d1, k, &.{ 1, 2, 3 });
        E.aslice(tc, src.st(), src.o, src.body(), d2.o, -2, -1);
        try expectSamples(&vm, d2, k, &.{ 4, 5 });
        // The source is unchanged.
        try expectSamples(&vm, src, k, &.{ 0, 1, 2, 3, 4, 5 });
    }
}

test "asplice inserts, deletes and replaces, also at offset 0 with start > 0" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        const Case = struct { offset: i64, count: u64, from: []const usize, want: []const usize, shifts: usize = 0 };
        const cases = [_]Case{
            .{ .offset = 2, .count = 0, .from = &.{ 10, 11 }, .want = &.{ 0, 1, 10, 11, 2, 3, 4, 5 } },
            .{ .offset = 1, .count = 2, .from = &.{}, .want = &.{ 0, 3, 4, 5 } },
            .{ .offset = 1, .count = 2, .from = &.{ 10, 11, 12 }, .want = &.{ 0, 10, 11, 12, 3, 4, 5 } },
            .{ .offset = -2, .count = 1, .from = &.{10}, .want = &.{ 0, 1, 2, 3, 10, 5 } },
            .{ .offset = 6, .count = 0, .from = &.{ 10, 11 }, .want = &.{ 0, 1, 2, 3, 4, 5, 10, 11 } },
            .{ .offset = 0, .count = 6, .from = &.{}, .want = &.{} },
            // start = 2 after two shifts; the offset-0 adjustment moves the
            // window back over the shifted-off slots (row 26).
            .{ .offset = 0, .count = 1, .from = &.{ 10, 11, 12 }, .want = &.{ 10, 11, 12, 3, 4, 5 }, .shifts = 2 },
            .{ .offset = 0, .count = 0, .from = &.{10}, .want = &.{ 10, 2, 3, 4, 5 }, .shifts = 2 },
        };
        for (cases) |case| {
            var a = filled(&vm, k, &.{ 0, 1, 2, 3, 4, 5 });
            var from = filled(&vm, k, case.from);
            const r = moar.rootN(tc, .{ &a.o, &from.o });
            defer r.pop(tc);
            for (0..case.shifts) |_| _ = a.shift(tc, k);
            E.asplice(tc, a.st(), a.o, a.body(), from.o, case.offset, case.count);
            try expectSamples(&vm, a, k, case.want);
        }
    }
}

/// The value an element of `To` holds after a cross-kind copy of `v` from
/// an element of `From`, by the C's rule: `at_pos` widens into the source
/// kind's register (sign- or zero-extended), `bind_pos` keeps the low bits
/// of `.i64` (row 15d).
fn crossInt(comptime From: type, comptime To: type, v: From) To {
    const wide: u64 = if (@typeInfo(From).int.signedness == .signed)
        @bitCast(@as(i64, v))
    else
        @as(u64, v);
    return @bitCast(@as(@Int(.unsigned, @bitSizeOf(To)), @truncate(wide)));
}

test "asplice and aslice copy from another kind as the C's at_pos and bind_pos convert" {
    // 144 kind pairs unrolled, each comparing type names at compile time
    // in the rooting helpers.
    @setEvalBranchQuota(100_000);
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |from_ki| {
        inline for (kinds.kinds) |to_ki| {
            const F = from_ki.Elem;
            const T = to_ki.Elem;
            const fi = @typeInfo(F);
            const same_class = (fi == .int and @typeInfo(T) == .int) or (fi == .float and @typeInfo(T) == .float);
            if (comptime same_class and from_ki.kind != to_ki.kind) {
                var src = vm.new(from_ki.kind);
                var dst = filled(&vm, to_ki.kind, &.{ 0, 1 });
                var sliced = vm.new(to_ki.kind);
                const r = moar.rootN(tc, .{ &src.o, &dst.o, &sliced.o });
                defer r.pop(tc);
                const values: [4]F = if (fi == .int)
                    .{ std.math.minInt(F), std.math.maxInt(F), 0, ~@as(F, 1) }
                else
                    .{ 0.1, -1.5e38, 3.0e38, std.math.inf(F) };
                E.setElems(tc, src.st(), src.o, src.body(), 4);
                for (values, 0..) |v, i| kinds.slots(from_ki.kind, src.body())[i] = v;
                E.asplice(tc, dst.st(), dst.o, dst.body(), src.o, 1, 0);
                E.aslice(tc, src.st(), src.o, src.body(), sliced.o, 0, 3);
                try expectEqual(@as(u64, 6), dst.elems());
                const got = kinds.slots(to_ki.kind, dst.body());
                const got_sliced = kinds.slots(to_ki.kind, sliced.body());
                for (values, 0..) |v, i| {
                    const want: T = if (fi == .int) crossInt(F, T, v) else @floatCast(@as(f64, v));
                    try expectEqual(want, got[1 + i]);
                    try expectEqual(want, got_sliced[i]);
                }
                try expectReg(to_ki.kind, sample(&vm, to_ki.kind, 0), dst.at(tc, to_ki.kind, 0));
                try expectReg(to_ki.kind, sample(&vm, to_ki.kind, 1), dst.at(tc, to_ki.kind, 5));
            }
        }
    }
}

test "a splice from the array itself: memmove for the copied kinds, the C's forward loop for STR and promoted OBJ" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    const ten = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    // Splicing [0..9] into itself at 2: what a memmove of the overlapping
    // copy leaves (the array inserted into itself) ...
    const moved = [_]usize{ 0, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5, 6, 7, 8, 9 };
    // ... and what the element-by-element forward copy of copy_elements
    // leaves: each read sees what the copy has already written two slots
    // further left (va-differential.md section 5).
    const forward = [_]usize{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = filled(&vm, k, &ten);
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        E.asplice(tc, a.st(), a.o, a.body(), a.o, 2, 0);
        try expectSamples(&vm, a, k, if (k == .str) &forward else &moved);
    }
    // An OBJ array in gen2 takes the element path (row 22a), so the forward
    // pattern, through the write barrier.
    var g = vm.newGen2(.obj);
    const r = moar.root(tc, &g.o);
    defer r.pop(tc);
    for (ten) |i| g.push(tc, .obj, sample(&vm, .obj, i));
    E.asplice(tc, g.st(), g.o, g.body(), g.o, 2, 0);
    try expectSamples(&vm, g, .obj, &forward);
}

test "writeBuf and readBuf copy bytes for the integer kinds" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        if (@typeInfo(ki.Elem) == .int) {
            const k = ki.kind;
            const es = ki.elem_size;
            var a = vm.new(k);
            const r = moar.root(tc, &a.o);
            defer r.pop(tc);
            var bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
            E.writeBuf(tc, a.st(), a.o, a.body(), &bytes, 1, 4);
            // The C grows to offset + count elements, count being bytes
            // (va-differential.md section 4).
            try expectEqual(@as(u64, 5), a.elems());
            const raw = std.mem.sliceAsBytes(kinds.slots(k, a.body())[0..5]);
            try expectEqual(bytes, raw[es..][0..4].*);
            try expectZeroBytes(raw[0..es]);
            try expectEqual(@as(i64, 0x44332211), E.readBuf(tc, a.st(), a.o, a.body(), 1, 4));
            try expectEqual(@as(i64, 0x2211), E.readBuf(tc, a.st(), a.o, a.body(), 1, 2));
            try expectEqual(@as(i64, 0), E.readBuf(tc, a.st(), a.o, a.body(), 0, 1));
            try expectEqual(@as(i64, 0), E.readBuf(tc, a.st(), a.o, a.body(), 3, 0));
            // Within the elements: no growth.
            var two = [_]u8{ 0xfe, 0xff };
            E.writeBuf(tc, a.st(), a.o, a.body(), &two, 0, 2);
            try expectEqual(@as(u64, 5), a.elems());
            try expectEqual(@as(i64, 0xfffe), E.readBuf(tc, a.st(), a.o, a.body(), 0, 2));
        }
    }
}

/// Review Focus 2: the C's rule for an integer element, written out: a
/// bind keeps the low bits of the 64-bit register (`(MVMint8)value.i64`),
/// a read sign-extends a signed element and zero-extends an unsigned one.
fn cStoreRead(comptime T: type, v: i64) u64 {
    const low: @Int(.unsigned, @bitSizeOf(T)) = @truncate(@as(u64, @bitCast(v)));
    const elem: T = @bitCast(low);
    return if (@typeInfo(T).int.signedness == .signed) @bitCast(@as(i64, elem)) else @as(u64, elem);
}

test "integer binds truncate to the element and reads extend by signedness" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        if (@typeInfo(ki.Elem) == .int) {
            const k = ki.kind;
            const T = ki.Elem;
            var a = vm.new(k);
            const r = moar.root(tc, &a.o);
            defer r.pop(tc);
            const min: i128 = std.math.minInt(T);
            const max: i128 = std.math.maxInt(T);
            const inputs = [_]i64{
                @truncate(min),        @truncate(max),       @truncate(max + 1),
                @truncate(min - 1),    -1,                   0,
                1,                     std.math.maxInt(i64), std.math.minInt(i64),
                0x0123_4567_89ab_cdef,
            };
            for (inputs) |v| {
                const want = cStoreRead(T, v);
                // bind_pos/at_pos with every register kind they accept.
                inline for (ki.reg_kinds) |rk| {
                    var in = std.mem.zeroes(Reg);
                    in.i64 = v;
                    E.bindPos(tc, a.st(), a.o, a.body(), 0, in, rk);
                    var out: Reg = undefined;
                    E.atPos(tc, a.st(), a.o, a.body(), 0, &out, rk);
                    try expectEqual(want, out.u64);
                }
                // push/pop with int64.
                var in = std.mem.zeroes(Reg);
                in.i64 = v;
                E.push(tc, a.st(), a.o, a.body(), in, c.MVM_reg_int64);
                var out: Reg = undefined;
                E.pop(tc, a.st(), a.o, a.body(), &out, c.MVM_reg_int64);
                try expectEqual(want, out.u64);
            }
        }
    }
    // The same rule at a few points, as literals.
    const Lit = struct { k: Kind, in: i64, out: u64 };
    const lits = [_]Lit{
        .{ .k = .i8, .in = 128, .out = @bitCast(@as(i64, -128)) },
        .{ .k = .i8, .in = 0x1ff, .out = @bitCast(@as(i64, -1)) },
        .{ .k = .u8, .in = -1, .out = 255 },
        .{ .k = .u8, .in = 256, .out = 0 },
        .{ .k = .i16, .in = 0x18000, .out = @bitCast(@as(i64, -32768)) },
        .{ .k = .u16, .in = -2, .out = 65534 },
        .{ .k = .i32, .in = 0x1_0000_0001, .out = 1 },
        .{ .k = .i32, .in = 0x8000_0000, .out = @bitCast(@as(i64, -2147483648)) },
        .{ .k = .u32, .in = -1, .out = 4294967295 },
        .{ .k = .u64, .in = -1, .out = std.math.maxInt(u64) },
        .{ .k = .i64, .in = std.math.minInt(i64), .out = 1 << 63 },
    };
    inline for (kinds.kinds) |ki| {
        if (@typeInfo(ki.Elem) == .int) {
            var a = vm.new(ki.kind);
            const r = moar.root(tc, &a.o);
            defer r.pop(tc);
            for (lits) |l| {
                if (l.k != ki.kind) continue;
                var in = std.mem.zeroes(Reg);
                in.i64 = l.in;
                a.bind(tc, ki.kind, 0, in);
                try expectEqual(l.out, a.at(tc, ki.kind, 0).u64);
            }
        }
    }
}

test "an N32 bind rounds to float and a read widens to double" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    var a = vm.new(.n32);
    const r = moar.root(tc, &a.o);
    defer r.pop(tc);
    const Lit = struct { in: f64, out: f64 };
    const lits = [_]Lit{
        .{ .in = 0.1, .out = 0.100000001490116119384765625 },
        .{ .in = 1.0e39, .out = std.math.inf(f64) },
        .{ .in = -1.0e39, .out = -std.math.inf(f64) },
        .{ .in = 3.4028234663852886e38, .out = 3.4028234663852886e38 },
        .{ .in = 1.0e-50, .out = 0.0 },
    };
    for (lits) |l| {
        var in = std.mem.zeroes(Reg);
        in.n64 = l.in;
        a.bind(tc, .n32, 0, in);
        try expectEqual(l.out, a.at(tc, .n32, 0).n64);
        a.push(tc, .n32, in);
        try expectEqual(l.out, a.pop(tc, .n32).n64);
    }
}

test "an object bind into a gen2 array triggers the write barrier" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (.{ Kind.obj, Kind.str }) |k| {
        // bind_pos, push and unshift each store through MVM_ASSIGN_REF.
        inline for (0..3) |op| {
            var a = vm.newGen2(k);
            var v = std.mem.zeroes(Reg);
            if (k == .obj) {
                v.o = c.MVM_repr_box_int(tc, vm.instance.boot_types.BOOTInt, 5000);
            } else {
                v.s = c.MVM_coerce_i_s(tc, 5000);
            }
            const header: *c.MVMCollectable = &a.o.?.header;
            try expect(header.flags2 & c.MVM_CF_SECOND_GEN != 0);
            try expect(header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST == 0);
            const before = tc.num_gen2roots;
            switch (op) {
                0 => a.bind(tc, k, 0, v),
                1 => a.push(tc, k, v),
                else => a.unshift(tc, k, v),
            }
            try expect(header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
            try expectEqual(before + 1, tc.num_gen2roots);
            try expectReg(k, v, a.at(tc, k, 0));
        }
    }
}

test "a collection marks exactly the live range" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    // Fresh array types whose STables use the Zig gc_mark (a copy of the
    // linked table with that one slot replaced), so the collection runs it.
    c.MVM_gc_allocate_gen2_default_set(tc);
    var obj_type: ?*Object = composedArray(tc, null);
    var str_type: ?*Object = composedArray(tc, vm.instance.boot_types.BOOTStr);
    c.MVM_gc_allocate_gen2_default_clear(tc);
    const rt = moar.rootN(tc, .{ &obj_type, &str_type });
    defer rt.pop(tc);
    var ops: c.MVMREPROps = obj_type.?.st.*.REPR.*;
    ops.gc_mark = &mark.gcMark;
    obj_type.?.st.*.REPR = &ops;
    str_type.?.st.*.REPR = &ops;

    var objs: A = .{ .o = c.MVM_repr_alloc_init(tc, obj_type) };
    var strs: A = .{ .o = c.MVM_repr_alloc_init(tc, str_type) };
    var empty: A = .{ .o = c.MVM_repr_alloc_init(tc, obj_type) };
    const ra = moar.rootN(tc, .{ &objs.o, &strs.o, &empty.o });
    defer ra.pop(tc);
    const BOOTInt = vm.instance.boot_types.BOOTInt;
    var v = std.mem.zeroes(Reg);
    // 10 pushes, 3 shifts, 2 unshifts: slots 1..9 live (start 1), slot 0
    // holds the first shifted-off element, not cleared by shift.
    for (0..10) |i| {
        v.o = c.MVM_repr_box_int(tc, BOOTInt, 3000 + @as(i64, @intCast(i)));
        objs.push(tc, .obj, v);
        v.s = c.MVM_coerce_i_s(tc, 3000 + @as(i64, @intCast(i)));
        strs.push(tc, .str, v);
    }
    for (0..3) |_| {
        _ = objs.shift(tc, .obj);
        _ = strs.shift(tc, .str);
    }
    for (0..2) |i| {
        v.o = c.MVM_repr_box_int(tc, BOOTInt, 4000 + @as(i64, @intCast(i)));
        objs.unshift(tc, .obj, v);
        v.s = c.MVM_coerce_i_s(tc, 4000 + @as(i64, @intCast(i)));
        strs.unshift(tc, .str, v);
    }
    try expectEqual(@as(u64, 1), objs.body().start);
    try expectEqual(@as(u64, 9), objs.elems());
    // Live values in index order: the unshifted 4001, 4000, then 3003..3009.
    var want: [9]i64 = undefined;
    want[0] = 4001;
    want[1] = 4000;
    for (2..9) |i| want[i] = 3001 + @as(i64, @intCast(i));
    var old_objs: [10]usize = undefined;
    var old_strs: [10]usize = undefined;
    for (0..10) |i| {
        old_objs[i] = @intFromPtr(kinds.slots(.obj, objs.body())[i]);
        old_strs[i] = @intFromPtr(kinds.slots(.str, strs.body())[i]);
    }
    // An array with elems == 0 and storage.
    v.o = c.MVM_repr_box_int(tc, BOOTInt, 1);
    empty.push(tc, .obj, v);
    _ = empty.pop(tc, .obj);
    const empty_slots = empty.body().slots.any;
    try expect(empty_slots != null);

    c.MVM_gc_enter_from_allocator(tc);

    for (0..9) |i| {
        const o = kinds.slots(.obj, objs.body())[1 + i];
        const s = kinds.slots(.str, strs.body())[1 + i];
        try expect(@intFromPtr(o) != old_objs[1 + i]);
        try expect(@intFromPtr(s) != old_strs[1 + i]);
        try expectEqual(want[i], c.MVM_repr_get_int(tc, o));
        try expectEqual(want[i], c.MVM_coerce_s_i(tc, s));
        try expectEqual(o, objs.at(tc, .obj, @intCast(i)).o);
    }
    // Outside the window nothing was marked, so nothing was updated.
    try expectEqual(old_objs[0], @intFromPtr(kinds.slots(.obj, objs.body())[0]));
    try expectEqual(old_strs[0], @intFromPtr(kinds.slots(.str, strs.body())[0]));
    // The empty array survives with its storage.
    try expectEqual(@as(u64, 0), empty.elems());
    try expectEqual(empty_slots, empty.body().slots.any);
    empty.push(tc, .obj, sample(&vm, .obj, 3));
    try expectReg(.obj, sample(&vm, .obj, 3), empty.at(tc, .obj, 0));
}

test "gcMark presizes and adds in index order" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    const BOOTInt = vm.instance.boot_types.BOOTInt;
    var objs = vm.new(.obj);
    var big = vm.new(.obj);
    var ints = filled(&vm, .i64, &.{ 0, 1, 2, 3, 4 });
    const r = moar.rootN(tc, .{ &objs.o, &big.o, &ints.o });
    defer r.pop(tc);
    var v = std.mem.zeroes(Reg);
    // Six fresh nursery objects, one shifted off: five live from start 1.
    for (0..6) |i| {
        v.o = c.MVM_repr_box_int(tc, BOOTInt, 6000 + @as(i64, @intCast(i)));
        objs.push(tc, .obj, v);
    }
    _ = objs.shift(tc, .obj);
    for (0..300) |i| {
        v.o = c.MVM_repr_box_int(tc, BOOTInt, 7000 + @as(i64, @intCast(i)));
        big.push(tc, .obj, v);
    }
    for ([_]u8{ 0, 1 }) |include_gen2| {
        const wl = c.MVM_gc_worklist_create(tc, include_gen2);
        defer c.MVM_gc_worklist_destroy(tc, wl);
        mark.gcMark(tc, objs.st(), objs.body(), wl);
        try expectEqual(@as(u32, 5), wl.*.items);
        for (0..5) |i| try expectEqual(@intFromPtr(&kinds.slots(.obj, objs.body())[1 + i]), @intFromPtr(wl.*.list[i]));
        // A numeric array adds nothing.
        mark.gcMark(tc, ints.st(), ints.body(), wl);
        try expectEqual(@as(u32, 5), wl.*.items);
    }
    // Presized to exactly items + elems = 300 slots, past the start size
    // of 256: the C's presize, not the doubling of add_slow.
    const wl = c.MVM_gc_worklist_create(tc, 0);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    mark.gcMark(tc, big.st(), big.body(), wl);
    try expectEqual(@as(u32, 300), wl.*.items);
    try expectEqual(@as(u32, 300), wl.*.alloc);
    for (0..300) |i| try expectEqual(@intFromPtr(&kinds.slots(.obj, big.body())[i]), @intFromPtr(wl.*.list[i]));
}

test "gcMarkReprData adds the element type" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    const st = vm.types[@backingInt(Kind.i64)].?.st;
    mark.gcMarkReprData(tc, st, wl);
    try expectEqual(@as(u32, 1), wl.*.items);
    try expectEqual(@intFromPtr(&reprData(vm.types[@backingInt(Kind.i64)].?).elem_type), @intFromPtr(wl.*.list[0]));
    // An OBJ array's element type is NULL: nothing added.
    mark.gcMarkReprData(tc, vm.types[@backingInt(Kind.obj)].?.st, wl);
    try expectEqual(@as(u32, 1), wl.*.items);
}

test "describeRefs reports each object and string element with its index" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (.{ Kind.obj, Kind.str, Kind.i64 }) |k| {
        // A snapshot state as record_snapshot (heapsnapshot.c) starts it,
        // with the referring collectable at index 0.
        var col = std.mem.zeroes(c.MVMHeapSnapshotCollection);
        var hs = std.mem.zeroes(c.MVMHeapSnapshot);
        hs.collectables = @ptrCast(@alignCast(c.MVM_calloc(1, @sizeOf(c.MVMHeapSnapshotCollectable))));
        hs.num_collectables = 1;
        hs.alloc_collectables = 1;
        var ss = std.mem.zeroes(c.MVMHeapSnapshotState);
        ss.col = &col;
        ss.hs = &hs;
        defer {
            c.MVM_free(hs.collectables);
            c.MVM_free(hs.references);
            c.MVM_free(ss.workitems);
            c.MVM_ptr_hash_demolish(tc, &ss.seen);
        }
        // [s1, hole, s0, s1] from start 1: four elements, a NULL among them.
        var a = filled(&vm, k, &.{ 9, 1 });
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        a.bind(tc, k, 3, sample(&vm, k, 0));
        a.bind(tc, k, 4, sample(&vm, k, 1));
        _ = a.shift(tc, k);
        try expectEqual(@as(u64, 1), a.body().start);
        mark.describeRefs(tc, &ss, a.st(), a.body());
        if (k == .i64) {
            try expectEqual(@as(u64, 0), hs.num_references);
        } else {
            // Index 1 is NULL and skipped; the value at 0 and 3 is the same
            // collectable, so the same snapshot index.
            const refs = hs.references[0..hs.num_references];
            try expectEqual(@as(usize, 3), refs.len);
            const kind_index = c.MVM_SNAPSHOT_REF_KIND_INDEX;
            const bits = c.MVM_SNAPSHOT_REF_KIND_BITS;
            try expectEqual(@as(u64, (0 << bits) | kind_index), refs[0].description);
            try expectEqual(@as(u64, (2 << bits) | kind_index), refs[1].description);
            try expectEqual(@as(u64, (3 << bits) | kind_index), refs[2].description);
            try expectEqual(@as(u64, 1), refs[0].collectable_index);
            try expectEqual(@as(u64, 2), refs[1].collectable_index);
            try expectEqual(@as(u64, 1), refs[2].collectable_index);
            try expectEqual(@as(u32, 3), hs.collectables[0].num_refs);
            try expectEqual(@as(u64, 3), hs.num_collectables);
        }
    }
}

test "the register-kind messages are the C's, byte for byte" {
    const M = struct { op: elements.Op, k: Kind, text: []const u8 };
    // Copied from src/6model/reprs/VMArray.c, one line per arm (the
    // push, pop, unshift and shift lines extracted from its source in
    // that order).
    const table = [_]M{
        .{ .op = .atpos, .k = .obj, .text = "MVMArray: atpos expected object register" },
        .{ .op = .atpos, .k = .str, .text = "MVMArray: atpos expected string register" },
        .{ .op = .atpos, .k = .i64, .text = "MVMArray: atpos I64 expected int register" },
        .{ .op = .atpos, .k = .i32, .text = "MVMArray: atpos I32 expected int register" },
        .{ .op = .atpos, .k = .i16, .text = "MVMArray: atpos I16 expected int register" },
        .{ .op = .atpos, .k = .i8, .text = "MVMArray: atpos I8 expected int register" },
        .{ .op = .atpos, .k = .n64, .text = "MVMArray: atpos expected num register" },
        .{ .op = .atpos, .k = .n32, .text = "MVMArray: atpos expected num register" },
        .{ .op = .atpos, .k = .u64, .text = "MVMArray: atpos U64 expected int register, got %d instead" },
        .{ .op = .atpos, .k = .u32, .text = "MVMArray: atpos U32 expected int register" },
        .{ .op = .atpos, .k = .u16, .text = "MVMArray: atpos U16 expected int register" },
        .{ .op = .atpos, .k = .u8, .text = "MVMArray: atpos U8 expected int register" },
        .{ .op = .bindpos, .k = .obj, .text = "MVMArray: bindpos expected object register" },
        .{ .op = .bindpos, .k = .str, .text = "MVMArray: bindpos expected string register" },
        .{ .op = .bindpos, .k = .i64, .text = "MVMArray: bindpos I64 expected int register" },
        .{ .op = .bindpos, .k = .i32, .text = "MVMArray: bindpos I32 expected int register" },
        .{ .op = .bindpos, .k = .i16, .text = "MVMArray: bindpos I16 expected int register" },
        .{ .op = .bindpos, .k = .i8, .text = "MVMArray: bindpos I8 expected int register" },
        .{ .op = .bindpos, .k = .n64, .text = "MVMArray: bindpos expected num register" },
        .{ .op = .bindpos, .k = .n32, .text = "MVMArray: bindpos expected num register" },
        .{ .op = .bindpos, .k = .u64, .text = "MVMArray: bindpos U64 expected int register" },
        .{ .op = .bindpos, .k = .u32, .text = "MVMArray: bindpos U32 expected int register" },
        .{ .op = .bindpos, .k = .u16, .text = "MVMArray: bindpos U16 expected int register" },
        .{ .op = .bindpos, .k = .u8, .text = "MVMArray: bindpos U8 expected int register" },
        .{ .op = .push, .k = .obj, .text = "MVMArray: push expected object register" },
        .{ .op = .push, .k = .str, .text = "MVMArray: push expected string register" },
        .{ .op = .push, .k = .i64, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .i32, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .i16, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .i8, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .n64, .text = "MVMArray: push expected num register" },
        .{ .op = .push, .k = .n32, .text = "MVMArray: push expected num register" },
        .{ .op = .push, .k = .u64, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .u32, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .u16, .text = "MVMArray: push expected int register" },
        .{ .op = .push, .k = .u8, .text = "MVMArray: push expected int register" },
        .{ .op = .pop, .k = .obj, .text = "MVMArray: pop expected object register" },
        .{ .op = .pop, .k = .str, .text = "MVMArray: pop expected string register" },
        .{ .op = .pop, .k = .i64, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .i32, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .i16, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .i8, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .n64, .text = "MVMArray: pop expected num register" },
        .{ .op = .pop, .k = .n32, .text = "MVMArray: pop expected num register" },
        .{ .op = .pop, .k = .u64, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .u32, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .u16, .text = "MVMArray: pop expected int register" },
        .{ .op = .pop, .k = .u8, .text = "MVMArray: pop expected int register" },
        .{ .op = .unshift, .k = .obj, .text = "MVMArray: unshift expected object register" },
        .{ .op = .unshift, .k = .str, .text = "MVMArray: unshift expected string register" },
        .{ .op = .unshift, .k = .i64, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .i32, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .i16, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .i8, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .n64, .text = "MVMArray: unshift expected num register" },
        .{ .op = .unshift, .k = .n32, .text = "MVMArray: unshift expected num register" },
        .{ .op = .unshift, .k = .u64, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .u32, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .u16, .text = "MVMArray: unshift expected int register" },
        .{ .op = .unshift, .k = .u8, .text = "MVMArray: unshift expected int register" },
        .{ .op = .shift, .k = .obj, .text = "MVMArray: shift expected object register" },
        .{ .op = .shift, .k = .str, .text = "MVMArray: shift expected string register" },
        .{ .op = .shift, .k = .i64, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .i32, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .i16, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .i8, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .n64, .text = "MVMArray: shift expected num register" },
        .{ .op = .shift, .k = .n32, .text = "MVMArray: shift expected num register" },
        .{ .op = .shift, .k = .u64, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .u32, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .u16, .text = "MVMArray: shift expected int register" },
        .{ .op = .shift, .k = .u8, .text = "MVMArray: shift expected int register" },
    };
    inline for (table) |m| try std.testing.expectEqualStrings(m.text, comptime elements.kindMessage(m.op, m.k));
    // One entry per operation and kind: 6 x 12.
    try expectEqual(@as(usize, 6 * kinds.kinds.len), table.len);
}

test "the per-kind entry points read without a register kind; the JIT bind grows" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (.{ Kind.str, Kind.obj, Kind.i64, Kind.u64, Kind.n64 }) |k| {
        var a = filled(&vm, k, &.{ 0, 1 });
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        a.bind(tc, k, 3, sample(&vm, k, 2));
        const P = E.atPosKind(k);
        var out: Reg = undefined;
        P.withRoot(tc, a.st(), a.o, a.body(), -1, &out);
        try expectReg(k, sample(&vm, k, 2), out);
        P.withRoot(tc, a.st(), a.o, a.body(), 0, &out);
        try expectReg(k, sample(&vm, k, 0), out);
        P.withRoot(tc, a.st(), a.o, a.body(), 2, &out); // a hole
        try expectReg(k, hole(&vm, k), out);
        P.withRoot(tc, a.st(), a.o, a.body(), 9, &out);
        try expectReg(k, hole(&vm, k), out);
        P.jit(tc, a.st(), a.body(), 1, &out);
        try expectReg(k, sample(&vm, k, 1), out);
    }
    // vmarray_bind_pos_int64: grows like bind_pos, stores .i64; it serves U64 too.
    inline for (.{ Kind.i64, Kind.u64 }) |k| {
        var a = vm.new(k);
        const r = moar.root(tc, &a.o);
        defer r.pop(tc);
        var v = std.mem.zeroes(Reg);
        v.i64 = -5;
        E.bindPosKind(k).jit(tc, a.st(), a.body(), 4, v);
        try expectEqual(@as(u64, 5), a.elems());
        v.i64 = 6;
        E.bindPosKind(k).jit(tc, a.st(), a.body(), -5, v);
        try expectEqual(@as(u64, 5), a.elems());
        try expectEqual(@as(u64, @bitCast(@as(i64, -5))), a.at(tc, k, 4).u64);
        try expectEqual(@as(u64, 6), a.at(tc, k, 0).u64);
        try expectEqual(@as(u64, 0), a.at(tc, k, 2).u64);
    }
}

test "elems, dimensions, multidim access, storage specs, atomics, unmanaged size, copyTo and gcFree" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    inline for (kinds.kinds) |ki| {
        const k = ki.kind;
        var a = filled(&vm, k, &.{ 0, 1, 2, 3 });
        var copy = vm.new(k);
        const r = moar.rootN(tc, .{ &a.o, &copy.o });
        defer r.pop(tc);
        _ = a.shift(tc, k);
        try expectEqual(@as(u64, 3), E.elems(tc, a.st(), a.o, a.body()));

        var n: i64 = 0;
        var dims: [*c]i64 = null;
        E.dimensions(tc, a.st(), a.o, a.body(), &n, &dims);
        try expectEqual(@as(i64, 1), n);
        try expectEqual(@intFromPtr(&a.body().elems), @intFromPtr(dims));

        var index = [_]i64{-1};
        var out: Reg = undefined;
        E.atPosMultidim(tc, a.st(), a.o, a.body(), 1, &index, &out, ki.reg_kind);
        try expectReg(k, sample(&vm, k, 3), out);
        E.bindPosMultidim(tc, a.st(), a.o, a.body(), 1, &index, sample(&vm, k, 5), ki.reg_kind);
        try expectSamples(&vm, a, k, &.{ 1, 2, 5 });

        // Row 28: by group; OBJ is reported as a reference array.
        const spec = E.getElemStorageSpec(tc, a.st());
        try expectEqual(@as(u16, 0), spec.bits);
        try expectEqual(@as(u16, 0), spec.@"align");
        const Want = struct { u16, u16, u16, u8 };
        const want: Want = switch (@typeInfo(ki.Elem)) {
            .pointer => if (k == .obj)
                .{ c.MVM_STORAGE_SPEC_REFERENCE, c.MVM_STORAGE_SPEC_BP_NONE, 0, 0 }
            else
                .{ c.MVM_STORAGE_SPEC_INLINED, c.MVM_STORAGE_SPEC_BP_STR, c.MVM_STORAGE_SPEC_CAN_BOX_STR, 0 },
            .int => |i| if (i.signedness == .signed)
                .{ c.MVM_STORAGE_SPEC_INLINED, c.MVM_STORAGE_SPEC_BP_INT, c.MVM_STORAGE_SPEC_CAN_BOX_INT, 0 }
            else
                .{ c.MVM_STORAGE_SPEC_INLINED, c.MVM_STORAGE_SPEC_BP_UINT64, c.MVM_STORAGE_SPEC_CAN_BOX_INT, 1 },
            .float => .{ c.MVM_STORAGE_SPEC_INLINED, c.MVM_STORAGE_SPEC_BP_NUM, c.MVM_STORAGE_SPEC_CAN_BOX_NUM, 0 },
            else => comptime unreachable,
        };
        try expectEqual(want, Want{ spec.inlineable, spec.boxed_primitive, spec.can_box, spec.is_unsigned });

        // Row 29: an element pointer for the integer kinds of AO_t's size.
        if (comptime @typeInfo(ki.Elem) == .int and ki.elem_size == @sizeOf(c.AO_t)) {
            const p = E.posAsAtomic(tc, a.st(), a.o, a.body(), -3);
            try expectEqual(@intFromPtr(&kinds.slots(k, a.body())[1]), @intFromPtr(p));
            var idx = [_]i64{2};
            const q = E.posAsAtomicMultidim(tc, a.st(), a.o, a.body(), 1, &idx);
            try expectEqual(@intFromPtr(&kinds.slots(k, a.body())[3]), @intFromPtr(q));
        }

        try expectEqual(a.body().ssize * ki.elem_size, E.unmanagedSize(tc, a.st(), a.body()));

        // copyTo: exactly elems slots from start, start 0.
        E.copyTo(tc, a.st(), a.body(), copy.o, copy.body());
        try expectEqual(@as(u64, 3), copy.body().ssize);
        try expectEqual(@as(u64, 0), copy.body().start);
        try expectSamples(&vm, copy, k, &.{ 1, 2, 5 });
        // gcFree frees the slots (the library will not free them again).
        E.gcFree(tc, copy.o);
        copy.body().* = std.mem.zeroes(c.MVMArrayBody);
    }
    const spec = E.getStorageSpec(tc, vm.types[0].?.st);
    try expectEqual(@as(u16, c.MVM_STORAGE_SPEC_REFERENCE), spec.*.inlineable);
    try expectEqual(@as(u16, c.MVM_STORAGE_SPEC_BP_NONE), spec.*.boxed_primitive);
    try expectEqual(@as(u16, 0), spec.*.bits);
    try expectEqual(@as(u16, 0), spec.*.can_box);
    try expectEqual(@as(u8, 0), spec.*.is_unsigned);
}

test "the kinds without storage: what does not throw does nothing and keeps slots NULL" {
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    for ([_]struct { i64, bool, u8 }{
        .{ 4, true, c.MVM_ARRAY_U4 },  .{ 2, true, c.MVM_ARRAY_U2 },  .{ 1, true, c.MVM_ARRAY_U1 },
        .{ 4, false, c.MVM_ARRAY_I4 }, .{ 2, false, c.MVM_ARRAY_I2 }, .{ 1, false, c.MVM_ARRAY_I1 },
    }) |w| {
        c.MVM_gc_allocate_gen2_default_set(tc);
        var t: ?*Object = composedArray(tc, nativeType(tc, c.MVM_REPR_ID_P6int, vm.instance.str_consts.integer, w[0], w[1]));
        c.MVM_gc_allocate_gen2_default_clear(tc);
        var a: A = .{ .o = c.MVM_repr_alloc_init(tc, t) };
        var other = vm.new(.i64);
        const r = moar.rootN(tc, .{ &t, &a.o, &other.o });
        defer r.pop(tc);
        try expectEqual(w[2], reprData(t.?).slot_type);
        try expectEqual(@as(usize, 0), reprData(t.?).elem_size);

        E.setElems(tc, a.st(), a.o, a.body(), 0);
        E.asplice(tc, a.st(), a.o, a.body(), other.o, 0, 0);
        var bytes = [_]u8{1};
        E.writeBuf(tc, a.st(), a.o, a.body(), &bytes, 0, 0);
        try expectEqual(@as(i64, 0), E.readBuf(tc, a.st(), a.o, a.body(), 0, 0));
        const spec = E.getElemStorageSpec(tc, a.st());
        try expectEqual(@as(u16, c.MVM_STORAGE_SPEC_REFERENCE), spec.inlineable);
        try expectEqual(@as(u16, c.MVM_STORAGE_SPEC_BP_NONE), spec.boxed_primitive);
        try expectEqual(@as(u16, 0), spec.can_box);
        try expectEqual(@as(u64, 0), E.unmanagedSize(tc, a.st(), a.body()));
        const wl = c.MVM_gc_worklist_create(tc, 1);
        defer c.MVM_gc_worklist_destroy(tc, wl);
        mark.gcMark(tc, a.st(), a.body(), wl);
        try expectEqual(@as(u32, 0), wl.*.items);
        // Nothing was allocated: no storage is NULL slots (spec 5.4).
        try expect(a.body().slots.any == null);
        try expectEqual(@as(u64, 0), a.body().ssize);
        try expectEqual(@as(u64, 0), a.elems());
        try expectEqual(@as(u64, 0), a.body().start);
    }
}

comptime {
    // The tests above assume a little-endian target for readBuf's values.
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

extern "c" fn fork() c_int;
extern "c" fn signal(sig: c_int, handler: ?*anyopaque) ?*anyopaque;
extern "c" fn prctl(option: c_int, ...) c_int;
/// prctl's PR_SET_DUMPABLE (linux/prctl.h).
const PR_SET_DUMPABLE = 4;

/// Runs `f(args...)` in a forked child with the default SIGSEGV action
/// and returns the signal the child died of, or null if it exited. The
/// child never returns to the test runner, and is made non-dumpable so its
/// fault leaves no core dump (a pipe `core_pattern` ignores RLIMIT_CORE).
fn childSignal(comptime f: anytype, args: anytype) !?std.c.SIG {
    const pid = fork();
    if (pid == 0) {
        _ = signal(@backingInt(std.c.SIG.SEGV), null);
        _ = prctl(PR_SET_DUMPABLE, @as(c_ulong, 0));
        @call(.auto, f, args);
        std.c._exit(0);
    }
    try expect(pid > 0);
    var status: c_int = 0;
    try expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const w: u32 = @bitCast(status);
    return if (std.c.W.IFSIGNALED(w)) std.c.W.TERMSIG(w) else null;
}

fn spliceInto(tc: *c.MVMThreadContext, a: A, from: [*c]Object) void {
    E.asplice(tc, a.st(), a.o, a.body(), from, 0, 0);
}

test "where the C reads through NULL the Zig array faults with SIGSEGV too" {
    // The helper itself, at the offset of a field.
    try expectEqual(@as(?std.c.SIG, .SEGV), try childSignal(moar.nullDeref, .{@as(usize, 8)}));

    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    var a = filled(&vm, .obj, &.{ 0, 1 });
    var hash: ?*Object = c.MVM_repr_alloc_init(tc, vm.instance.boot_types.BOOTHash);
    const r = moar.rootN(tc, .{ &a.o, &hash });
    defer r.pop(tc);
    c.MVM_repr_bind_key_o(tc, hash, vm.strs[0], vm.objs[0]);
    // A splice from a non-VMArray with elements (VMArray.c:958) and from a
    // NULL object (`REPR(from)`).
    try expectEqual(@as(?std.c.SIG, .SEGV), try childSignal(spliceInto, .{ tc, a, hash }));
    try expectEqual(@as(?std.c.SIG, .SEGV), try childSignal(spliceInto, .{ tc, a, @as([*c]Object, null) }));
    // The parent's array is untouched; an empty hash only deletes (no copy).
    try expectSamples(&vm, a, .obj, &.{ 0, 1 });
}

test "on a stubbed STable without REPR data an empty array is left alone where the C does not read it" {
    // A nested MVM_serialization_demand_stable only stubs an STable
    // (REPR_data NULL) and objects of it can be allocated, zeroed, before
    // deserialize_repr_data runs; the collector marks and frees them.
    var vm: Vm = undefined;
    vm.boot();
    defer vm.deinit();
    const tc = vm.tc;
    c.MVM_gc_allocate_gen2_default_set(tc);
    var t: ?*Object = composedArray(tc, null);
    c.MVM_gc_allocate_gen2_default_clear(tc);
    var a: A = .{ .o = c.MVM_repr_alloc_init(tc, t) };
    var other = vm.new(.obj);
    const r = moar.rootN(tc, .{ &t, &a.o, &other.o });
    defer r.pop(tc);
    const st = t.?.st;
    const saved = st.*.REPR_data;
    st.*.REPR_data = null;
    defer st.*.REPR_data = saved;
    try expectEqual(@as(u64, 0), a.elems());
    try expect(a.body().slots.any == null);

    // gc_mark: the empty check comes before the read (VMArray.c:76-79).
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    mark.gcMark(tc, st, a.body(), wl);
    // gc_mark_repr_data: its own NULL check (VMArray.c:120).
    mark.gcMarkReprData(tc, st, wl);
    try expectEqual(@as(u32, 0), wl.*.items);
    // gc_free reads only the object; copy_to reads the REPR data only for
    // elements (VMArray.c:55-56); elems never reads it.
    E.gcFree(tc, a.o);
    var copy = std.mem.zeroes(c.MVMArrayBody);
    copy.slots.any = @ptrFromInt(0x10); // overwritten, not freed
    E.copyTo(tc, st, a.body(), a.o, &copy);
    try expect(copy.slots.any == null);
    try expectEqual(@as(u64, 0), copy.elems);
    try expectEqual(@as(u64, 0), E.elems(tc, st, a.o, a.body()));
    // set_elems to the current size and a splice with nothing to copy or
    // delete return before any read (VMArray.c:411-412, 1086-1089).
    E.setElems(tc, st, a.o, a.body(), 0);
    E.asplice(tc, st, a.o, a.body(), other.o, 0, 0);
    try expectEqual(@as(u64, 0), a.elems());
    try expect(a.body().slots.any == null);
}
