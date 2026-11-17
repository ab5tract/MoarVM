//! Tests of the array's slot kinds (`reprs/vmarray/kinds.zig`) and its slot
//! storage (`reprs/vmarray/storage.zig`), on bodies that are plain stack
//! values: no VM is booted. Every path tested here is one that does not
//! throw, so the `tc` the storage functions take is never read and the
//! tests pass `no_tc`. The throwing paths (the size limit, a kind without
//! storage) longjmp and are covered by the differential programs instead.
//!
//! Two allocators back the storage under test:
//! - `std.testing.allocator`, which fails a test on a leak, a double free
//!   or a free whose length differs from the allocation's. Every body whose
//!   `ssize * elem_size` is the true size of its buffer is tested on it.
//! - `Agnostic` below, for the adoption shapes of va-adoption-audit.md where
//!   outside C code hands the array a buffer whose `ssize * elem_size` is
//!   not its size. The production allocator (`moar.mvm_allocator`, over
//!   `MVM_malloc`) ignores lengths, as malloc does; `Agnostic` models that
//!   and still catches leaks (through `std.testing.allocator` underneath)
//!   and frees of a pointer it does not hold.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const kinds = @import("../reprs/vmarray/kinds.zig");
const storage = @import("../reprs/vmarray/storage.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// The storage functions take a `tc` only to throw; none of the paths
/// tested here throws, so none reads it.
const no_tc: *c.MVMThreadContext = undefined;

/// The storage over `std.testing.allocator`.
const Testing = storage.Storage(struct {
    pub fn get() std.mem.Allocator {
        return std.testing.allocator;
    }
});

/// A length-agnostic test allocator: it records the true length of every
/// block it hands out and uses that, not the length it is given, on
/// `remap` and `free`, as `MVM_realloc`/`MVM_free` do. The blocks come
/// from `std.testing.allocator`, so a block never freed is reported as a
/// leak; a `free` or `remap` of a pointer it does not hold (a double
/// free) is counted in `unknown`.
const Agnostic = struct {
    live: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    unknown: usize = 0,

    var instance: Agnostic = .{};

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = remap,
        .free = free,
    };

    fn get() std.mem.Allocator {
        return .{ .ptr = &instance, .vtable = &vtable };
    }

    /// Starts a test: no block live, no unknown free.
    fn reset() void {
        instance.live.deinit(std.testing.allocator);
        instance = .{};
    }

    /// Ends a test: every block was freed exactly once.
    fn expectClean() !void {
        try expectEqual(@as(usize, 0), instance.unknown);
        try expectEqual(@as(u32, 0), instance.live.count());
        instance.live.deinit(std.testing.allocator);
        instance = .{};
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p = std.testing.allocator.rawAlloc(len, alignment, ret) orelse return null;
        instance.live.put(std.testing.allocator, @intFromPtr(p), len) catch @panic("Agnostic: out of memory");
        return p;
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const true_len = instance.live.get(@intFromPtr(memory.ptr)) orelse {
            instance.unknown += 1;
            return null;
        };
        const p = alloc(undefined, new_len, alignment, ret) orelse return null;
        @memcpy(p[0..@min(true_len, new_len)], memory.ptr[0..@min(true_len, new_len)]);
        free(undefined, memory, alignment, ret);
        return p;
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const entry = instance.live.fetchRemove(@intFromPtr(memory.ptr)) orelse {
            instance.unknown += 1;
            return;
        };
        std.testing.allocator.rawFree(memory.ptr[0..entry.value], alignment, ret);
    }

    /// A block of `len` bytes at the slots' alignment, as an outside C site
    /// gets one from `MVM_malloc`.
    fn adopt(len: usize) [*]u8 {
        return get().rawAlloc(len, kinds.slot_alignment, @returnAddress()).?;
    }
};

/// The storage over `Agnostic`.
const Lenient = storage.Storage(struct {
    pub fn get() std.mem.Allocator {
        return Agnostic.get();
    }
});

fn reprData(comptime k: kinds.Kind) c.MVMArrayREPRData {
    return .{ .elem_size = kinds.info(k).elem_size, .slot_type = @backingInt(k), .elem_type = null };
}

/// The slots of a body as bytes, `ssize * elem_size` of them.
fn bytesOf(body: *c.MVMArrayBody, elem_size: usize) []u8 {
    const p: [*]u8 = @ptrCast(body.slots.any.?);
    return p[0 .. body.ssize * elem_size];
}

/// The test's own transcription of the two growth formulas of
/// `set_size_internal` (VMArray.c): the `ssize` after growing to `n`.
fn cGrowth(ssize: u64, n: u64) u64 {
    if (n <= ssize) return ssize;
    if (ssize < 8192) {
        var s = ssize * 2;
        if (n > s) s = n;
        if (s < 8) s = 8;
        return s;
    }
    return (n + 0x1000) & ~@as(u64, 0xfff);
}

extern fn moar_probe_sizeof_array_body() usize;
extern fn moar_probe_sizeof_array() usize;
extern fn moar_probe_sizeof_array_repr_data() usize;
extern fn moar_probe_offsetof_array_body_elems() usize;
extern fn moar_probe_offsetof_array_body_start() usize;
extern fn moar_probe_offsetof_array_body_ssize() usize;
extern fn moar_probe_offsetof_array_body_slots() usize;
extern fn moar_probe_offsetof_array_body() usize;
extern fn moar_probe_offsetof_array_repr_data_elem_size() usize;
extern fn moar_probe_offsetof_array_repr_data_slot_type() usize;
extern fn moar_probe_offsetof_array_repr_data_elem_type() usize;

test "the kind table matches the C header" {
    try expectEqual(@as(usize, 12), kinds.kinds.len);
    inline for (kinds.kinds, 0..) |k, i| {
        // In value order, at the value of the header's constant of the
        // same name (`.u16` is MVM_ARRAY_U16).
        try expectEqual(i, @backingInt(k.kind));
        const upper = comptime blk: {
            var buf: [@tagName(k.kind).len]u8 = undefined;
            _ = std.ascii.upperString(&buf, @tagName(k.kind));
            break :blk buf;
        };
        try expectEqual(@field(c, "MVM_ARRAY_" ++ upper), @backingInt(k.kind));
        try expectEqual(@sizeOf(k.Elem), k.elem_size);
        try expect(k.Elem == kinds.Elem(k.kind));
        try expect(k.holds_refs == (k.kind == .obj or k.kind == .str));
        try expect(k.reg_kinds.len > 0);
        try expect(kinds.slot_alignment.toByteUnits() >= @alignOf(k.Elem));
    }
    try expect(kinds.slot_alignment.toByteUnits() <= 16);
    // The six kinds without storage are not stored kinds.
    for ([_]c_int{ c.MVM_ARRAY_U4, c.MVM_ARRAY_U2, c.MVM_ARRAY_U1, c.MVM_ARRAY_I4, c.MVM_ARRAY_I2, c.MVM_ARRAY_I1 }, 12..) |v, i| {
        try expectEqual(@as(c_int, @intCast(i)), v);
        try expect(std.enums.fromInt(kinds.Kind, v) == null);
    }
    // The three structs as the C compiler lays them out.
    try expectEqual(moar_probe_sizeof_array_body(), @sizeOf(c.MVMArrayBody));
    try expectEqual(moar_probe_sizeof_array(), @sizeOf(c.MVMArray));
    try expectEqual(moar_probe_sizeof_array_repr_data(), @sizeOf(c.MVMArrayREPRData));
    try expectEqual(moar_probe_offsetof_array_body_elems(), @offsetOf(c.MVMArrayBody, "elems"));
    try expectEqual(moar_probe_offsetof_array_body_start(), @offsetOf(c.MVMArrayBody, "start"));
    try expectEqual(moar_probe_offsetof_array_body_ssize(), @offsetOf(c.MVMArrayBody, "ssize"));
    try expectEqual(moar_probe_offsetof_array_body_slots(), @offsetOf(c.MVMArrayBody, "slots"));
    try expectEqual(moar_probe_offsetof_array_body(), @offsetOf(c.MVMArray, "body"));
    try expectEqual(moar_probe_offsetof_array_repr_data_elem_size(), @offsetOf(c.MVMArrayREPRData, "elem_size"));
    try expectEqual(moar_probe_offsetof_array_repr_data_slot_type(), @offsetOf(c.MVMArrayREPRData, "slot_type"));
    try expectEqual(moar_probe_offsetof_array_repr_data_elem_type(), @offsetOf(c.MVMArrayREPRData, "elem_type"));
}

test "dispatch calls the instantiation for the runtime kind and the stated fallback otherwise" {
    const Probe = struct {
        fn size(comptime k: kinds.Kind, plus: usize) usize {
            return kinds.info(k).elem_size + plus;
        }
        fn other(slot_type: u8, plus: usize) usize {
            return @as(usize, 1000) + slot_type + plus;
        }
    };
    inline for (kinds.kinds) |k| {
        try expectEqual(k.elem_size + 1, kinds.dispatch(@backingInt(k.kind), Probe.size, .{@as(usize, 1)}, Probe.other));
    }
    for (12..18) |v| {
        try expectEqual(1000 + v + 1, kinds.dispatch(@intCast(v), Probe.size, .{@as(usize, 1)}, Probe.other));
    }

    // `.nothing`: the stored kinds run `f`, the others return untouched.
    const Count = struct {
        fn add(comptime k: kinds.Kind, total: *usize) void {
            total.* += kinds.info(k).elem_size;
        }
    };
    var total: usize = 0;
    for (0..18) |v| kinds.dispatch(@intCast(v), Count.add, .{&total}, kinds.Otherwise.nothing);
    try expectEqual(@as(usize, 8 + 8 + 8 + 4 + 2 + 1 + 8 + 4 + 8 + 4 + 2 + 1), total);
}

/// The sizes `growth follows the C policy` grows an empty array to, and the
/// `ssize` set_size_internal (VMArray.c:441-448) gives after each, worked
/// out by hand from the C, independently of `cGrowth`:
///
///     n      old ssize  rule                                   ssize
///     1      0          < 8192: max(0 * 2, 1) = 1, then at least 8     8
///     8      8          n <= ssize: no growth                          8
///     9      8          < 8192: max(8 * 2, 9)                         16
///     17     16         < 8192: max(16 * 2, 17)                       32
///     8191   32         < 8192: max(32 * 2, 8191)                   8191
///     8192   8191       < 8192: max(8191 * 2, 8192)                16382
///     8193   16382      n <= ssize: no growth                      16382
///     20000  16382      >= 8192: (20000 + 0x1000) & ~0xfff         20480
///
/// (24096 & ~4095 = 5 * 4096 = 20480.) `start` stays 0 throughout: the
/// array is never shifted.
const growth_steps = [_]u64{ 1, 8, 9, 17, 8191, 8192, 8193, 20000 };
const growth_ssizes = [_]u64{ 8, 8, 16, 32, 8191, 16382, 16382, 20480 };

test "growth follows the C policy" {
    // The transcription agrees with the hand-worked sequence.
    {
        var ssize: u64 = 0;
        for (growth_steps, growth_ssizes) |n, want| {
            ssize = cGrowth(ssize, n);
            try expectEqual(want, ssize);
        }
    }
    inline for (kinds.kinds) |k| {
        const rd = reprData(k.kind);
        var body = std.mem.zeroes(c.MVMArrayBody);
        var ssize: u64 = 0;
        var elems: u64 = 0;
        for (growth_steps, growth_ssizes) |n, want| {
            // Mark the live elements so the test sees whether they move.
            if (elems > 0) @memset(bytesOf(&body, k.elem_size)[0 .. elems * k.elem_size], 0xa5);
            Testing.setSize(no_tc, &body, n, &rd);
            ssize = cGrowth(ssize, n);
            try expectEqual(want, body.ssize);
            try expectEqual(ssize, body.ssize);
            try expectEqual(n, body.elems);
            try expectEqual(@as(u64, 0), body.start);
            const bytes = bytesOf(&body, k.elem_size);
            for (bytes[0 .. elems * k.elem_size]) |b| try expectEqual(@as(u8, 0xa5), b);
            for (bytes[elems * k.elem_size ..]) |b| try expectEqual(@as(u8, 0), b);
            elems = n;
        }
        Testing.free(&body, k.elem_size);
    }
}

test "growth with start > 0 shifts back before reallocating" {
    const rd = reprData(.i64);
    var body = std.mem.zeroes(c.MVMArrayBody);
    body.slots.any = Testing.alloc(8, 8);
    body.ssize = 8;
    body.start = 5;
    body.elems = 3;
    const s = kinds.slots(.i64, &body);
    @memset(s[0..8], 0);
    s[5] = 50;
    s[6] = 60;
    s[7] = 70;
    const before = body.slots.any;

    // 6 + 5 > 8: shift the three elements to the front, then 6 fit.
    Testing.setSize(no_tc, &body, 6, &rd);
    try expectEqual(before, body.slots.any);
    try expectEqual(@as(u64, 0), body.start);
    try expectEqual(@as(u64, 6), body.elems);
    try expectEqual(@as(u64, 8), body.ssize);
    try expectEqual([_]i64{ 50, 60, 70, 0, 0, 0, 0, 0 }, kinds.slots(.i64, &body)[0..8].*);

    // 9 > 8: grows to 16 slots.
    Testing.setSize(no_tc, &body, 9, &rd);
    try expectEqual(@as(u64, 16), body.ssize);
    try expectEqual(@as(u64, 9), body.elems);
    try expectEqual([_]i64{ 50, 60, 70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, kinds.slots(.i64, &body)[0..16].*);
    Testing.free(&body, 8);
}

test "shrinking zeroes the dropped slots and keeps ssize" {
    const rd = reprData(.u16);
    var body = std.mem.zeroes(c.MVMArrayBody);
    Testing.setSize(no_tc, &body, 10, &rd);
    for (kinds.slots(.u16, &body)[0..10], 1..) |*e, i| e.* = @intCast(i);
    Testing.setSize(no_tc, &body, 4, &rd);
    try expectEqual(@as(u64, 4), body.elems);
    try expectEqual(@as(u64, 10), body.ssize);
    try expectEqual([_]u16{ 1, 2, 3, 4, 0, 0, 0, 0, 0, 0 }, kinds.slots(.u16, &body)[0..10].*);

    // With start > 0 the dropped slots are the window's tail.
    body.start = 2;
    body.elems = 2; // the window holds 3, 4
    Testing.setSize(no_tc, &body, 1, &rd);
    try expectEqual(@as(u64, 2), body.start);
    try expectEqual([_]u16{ 1, 2, 3, 0 }, kinds.slots(.u16, &body)[0..4].*);
    Testing.free(&body, 2);
}

test "copyTo copies the live range into storage of exactly elems slots; an empty source leaves slots null" {
    const rd = reprData(.n32);
    var src = std.mem.zeroes(c.MVMArrayBody);
    Testing.setSize(no_tc, &src, 8, &rd);
    for (kinds.slots(.n32, &src)[0..8], 0..) |*e, i| e.* = @floatFromInt(i);
    src.start = 3;
    src.elems = 5;
    var dest = std.mem.zeroes(c.MVMArrayBody);
    Testing.copyTo(&src, &dest, &rd);
    try expectEqual(@as(u64, 5), dest.elems);
    try expectEqual(@as(u64, 5), dest.ssize);
    try expectEqual(@as(u64, 0), dest.start);
    try expectEqual([_]f32{ 3, 4, 5, 6, 7 }, kinds.slots(.n32, &dest)[0..5].*);
    Testing.free(&dest, 4);
    Testing.free(&src, 4);

    var empty = std.mem.zeroes(c.MVMArrayBody);
    empty.start = 4;
    var copy = std.mem.zeroes(c.MVMArrayBody);
    copy.slots.any = @ptrFromInt(0x10); // overwritten, not freed
    Testing.copyTo(&empty, &copy, &rd);
    try expect(copy.slots.any == null);
    try expectEqual(@as(u64, 0), copy.elems);
    try expectEqual(@as(u64, 0), copy.ssize);
    try expectEqual(@as(u64, 0), copy.start);
}

test "an empty array has no storage and frees nothing" {
    var body = std.mem.zeroes(c.MVMArrayBody);
    Testing.free(&body, 8);
    try expect(Testing.alloc(0, 8) == null);
    // A kind without storage (elem_size 0) never allocates either.
    try expect(Testing.alloc(5, 0) == null);
}

test "the REPR data is created as type_object_for starts it and destroyed" {
    const rd = Testing.createReprData();
    try expectEqual(@as(u8, c.MVM_ARRAY_OBJ), rd.slot_type);
    try expectEqual(@as(usize, @sizeOf(*c.MVMObject)), rd.elem_size);
    try expect(rd.elem_type == null);
    Testing.destroyReprData(rd);
}

test "an adopted buffer can be grown and freed" {
    const n = 12;
    const rd = reprData(.u32);

    // The truthful shape: n * elem_size bytes, ssize = elems = n, start 0.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        const buf = std.testing.allocator.rawAlloc(n * 4, kinds.slot_alignment, @returnAddress()).?;
        body.slots.any = buf;
        body.ssize = n;
        body.elems = n;
        for (kinds.slots(.u32, &body)[0..n], 0..) |*e, i| e.* = @intCast(i);
        Testing.setSize(no_tc, &body, n + 1, &rd);
        try expectEqual(cGrowth(n, n + 1), body.ssize);
        for (kinds.slots(.u32, &body)[0..n], 0..) |e, i| try expectEqual(@as(u32, @intCast(i)), e);
        try expectEqual(@as(u32, 0), kinds.slots(.u32, &body)[n]);
        Testing.free(&body, 4);
    }
    // The same with start = 2, elems = n - 2: shifted back, then grown.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        const buf = std.testing.allocator.rawAlloc(n * 4, kinds.slot_alignment, @returnAddress()).?;
        body.slots.any = buf;
        body.ssize = n;
        body.start = 2;
        body.elems = n - 2;
        for (kinds.slots(.u32, &body)[0..n], 0..) |*e, i| e.* = @intCast(i);
        Testing.setSize(no_tc, &body, n + 1, &rd);
        try expectEqual(@as(u64, 0), body.start);
        try expectEqual(cGrowth(n, n + 1), body.ssize);
        for (kinds.slots(.u32, &body)[0 .. n - 2], 2..) |e, i| try expectEqual(@as(u32, @intCast(i)), e);
        for (kinds.slots(.u32, &body)[n - 2 .. body.ssize]) |e| try expectEqual(@as(u32, 0), e);
        Testing.free(&body, 4);
    }
    // A 0-byte socket read (asyncsocket.c, asyncsocketudp.c): elems = 0
    // with ssize = the buffer's length. Truthful, so on the testing
    // allocator.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        const u8rd = reprData(.u8);
        body.slots.any = std.testing.allocator.rawAlloc(4, kinds.slot_alignment, @returnAddress()).?;
        body.ssize = 4;
        Testing.setSize(no_tc, &body, 10, &u8rd);
        try expectEqual(@as(u64, 10), body.ssize);
        for (kinds.slots(.u8, &body)[0..10]) |e| try expectEqual(@as(u8, 0), e);
        Testing.free(&body, 1);
    }

    // The shapes where ssize * elem_size is not the buffer's size, on the
    // length-agnostic allocator (va-adoption-audit.md sections 2 and 3).
    Agnostic.reset();
    // ssize understates the buffer (io.c MVM_io_read_bytes; ops.c
    // MVM_string_encode_to_buf_config): 64 bytes, ssize = elems = 40.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        const u8rd = reprData(.u8);
        body.slots.any = Agnostic.adopt(64);
        body.ssize = 40;
        body.elems = 40;
        @memset(kinds.slots(.u8, &body)[0..40], 7);
        Lenient.setSize(no_tc, &body, 100, &u8rd);
        try expectEqual(@as(u64, 100), body.ssize);
        for (kinds.slots(.u8, &body)[0..40]) |e| try expectEqual(@as(u8, 7), e);
        for (kinds.slots(.u8, &body)[40..100]) |e| try expectEqual(@as(u8, 0), e);
        Lenient.free(&body, 1);
    }
    // ssize overstates the buffer (normalize.c
    // MVM_unicode_normalize_codepoints: a byte count as ssize; procops.c
    // async_read with a wide buf_type): 8 elements, ssize = 32, elems = 2.
    // Growing past ssize and freeing must not use the stated length.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        body.slots.any = Agnostic.adopt(8 * 4);
        body.ssize = 32;
        body.elems = 2;
        kinds.slots(.u32, &body)[0] = 0xdead;
        kinds.slots(.u32, &body)[1] = 0xbeef;
        Lenient.setSize(no_tc, &body, 40, &rd);
        try expectEqual(@as(u64, 64), body.ssize);
        try expectEqual([_]u32{ 0xdead, 0xbeef }, kinds.slots(.u32, &body)[0..2].*);
        for (kinds.slots(.u32, &body)[2..64]) |e| try expectEqual(@as(u32, 0), e);
        Lenient.free(&body, 4);
    }
    // A non-NULL buffer with ssize = 0 (io.c after a 0-byte file read;
    // normalize.c MVM_unicode_string_to_codepoints of an empty string to
    // NFC; ops.c encoding an empty string): freed as it is ...
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        body.slots.any = Agnostic.adopt(4);
        Lenient.free(&body, 4);
    }
    // ... and grown from, which must reallocate it, not leak it.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        body.slots.any = Agnostic.adopt(4);
        Lenient.setSize(no_tc, &body, 3, &rd);
        try expectEqual(@as(u64, 8), body.ssize);
        for (kinds.slots(.u32, &body)[0..8]) |e| try expectEqual(@as(u32, 0), e);
        Lenient.free(&body, 4);
    }
    // A kind without storage holding a zero-capacity buffer with
    // ssize = elems > 0 (the C's copy_to or deserialize of a recomposed
    // array: MVM_malloc(elems * 0)): elem_size is 0, the buffer is freed.
    {
        var body = std.mem.zeroes(c.MVMArrayBody);
        body.slots.any = Agnostic.adopt(1);
        body.ssize = 5;
        body.elems = 5;
        Lenient.free(&body, 0);
    }
    try Agnostic.expectClean();
}

/// A 64-bit register value stored into an integer element of type `E`, as
/// the C's cast does: the low bits, the unsigned kinds reading the same
/// bits as unsigned (`(MVMuint16)value.i64`).
fn narrow(comptime E: type, v: i64) E {
    return switch (@typeInfo(E).int.signedness) {
        .signed => @truncate(v),
        .unsigned => @truncate(@as(u64, @bitCast(v))),
    };
}

test "every kind round-trips through its slots view" {
    inline for (kinds.kinds) |k| {
        const rd = reprData(k.kind);
        var body = std.mem.zeroes(c.MVMArrayBody);
        Testing.setSize(no_tc, &body, 4, &rd);
        const s = kinds.slots(k.kind, &body);
        const E = k.Elem;
        switch (@typeInfo(E)) {
            .int => {
                s[0] = std.math.minInt(E);
                s[1] = std.math.maxInt(E);
                // A store narrows a 64-bit register value by keeping its
                // low bits, as the C's cast does: one above the maximum
                // wraps to the minimum.
                const above: i64 = @truncate(@as(i128, std.math.maxInt(E)) + 1);
                s[2] = narrow(E, above);
                s[3] = narrow(E, -1);
                try expectEqual(@as(E, std.math.minInt(E)), s[0]);
                try expectEqual(@as(E, std.math.maxInt(E)), s[1]);
                try expectEqual(@as(E, std.math.minInt(E)), s[2]);
                try expectEqual(~@as(E, 0), s[3]);
            },
            .float => {
                s[0] = std.math.floatMax(E);
                s[1] = -std.math.floatMax(E);
                s[2] = std.math.floatTrueMin(E);
                s[3] = std.math.inf(E);
                try expectEqual(std.math.floatMax(E), s[0]);
                try expectEqual(-std.math.floatMax(E), s[1]);
                try expectEqual(std.math.floatTrueMin(E), s[2]);
                try expectEqual(std.math.inf(E), s[3]);
            },
            .pointer => {
                // Pointers are stored and read back, never dereferenced.
                const high: E = @ptrFromInt(std.mem.alignBackward(usize, std.math.maxInt(usize), @alignOf(usize)));
                const low: E = @ptrFromInt(@alignOf(usize));
                s[0] = high;
                s[1] = low;
                s[2] = null;
                try expectEqual(high, s[0]);
                try expectEqual(low, s[1]);
                try expect(s[2] == null);
            },
            else => comptime unreachable,
        }
        Testing.free(&body, k.elem_size);
    }
}
