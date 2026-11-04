//! The one module every Zig implementation file imports. Re-exports the
//! translated C API as `c` and holds the Zig equivalents of the C macros
//! translate-c cannot express.
pub const c = @import("c");

pub const ThreadContext = c.MVMThreadContext;
pub const Object = c.MVMObject;
pub const Collectable = c.MVMCollectable;
pub const STable = c.MVMSTable;
pub const REPROps = c.MVMREPROps;

const std = @import("std");

// ---- accessor macros from src/6model/6model.h --------------------------

/// STABLE(o)
pub inline fn stable(o: *Object) *STable {
    return o.st;
}
/// REPR(o)
pub inline fn repr(o: *Object) *const REPROps {
    return stable(o).REPR;
}
/// OBJECT_BODY(o)
pub inline fn objectBody(o: *Object) *anyopaque {
    const stooge: *c.MVMObjectStooge = @ptrCast(o);
    return @ptrCast(&stooge.data);
}
/// IS_CONCRETE(o)
pub inline fn isConcrete(o: *Object) bool {
    return (o.header.flags1 & c.MVM_CF_TYPE_OBJECT) == 0;
}

// ---- collectable type checks -------------------------------------------

/// True for MVMCollectable and for every struct that begins with one, either
/// directly (`header: MVMCollectable`: MVMObject, MVMSTable, MVMFrame, ...)
/// or through an embedded MVMObject (`common: MVMObject`: MVMString and the
/// REPR bodies). Being a prefix is what makes the C casts to MVMCollectable*
/// valid, so that is the test.
fn isCollectable(comptime T: type) bool {
    if (T == Collectable) return true;
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    const fields = info.@"struct".fields;
    if (fields.len == 0) return false;
    const first = fields[0];
    if (std.mem.eql(u8, first.name, "header") and first.type == Collectable) return true;
    if (std.mem.eql(u8, first.name, "common") and isCollectable(first.type)) return true;
    return false;
}

/// The type a `*T`, `?*T` or `[*c]T` points at; null for anything else.
fn pointee(comptime P: type) ?type {
    var T = P;
    if (@typeInfo(T) == .optional) T = @typeInfo(T).optional.child;
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size == .slice) return null;
    return info.pointer.child;
}

/// A collectable pointer: `*T`, `?*T` or `[*c]T` with T collectable.
fn isCollectablePtr(comptime P: type) bool {
    const T = pointee(P) orelse return false;
    return isCollectable(T);
}

// ---- MVM_ASSERT_NOT_FROMSPACE from src/gc/debug.h -----------------------

/// MVM_ASSERT_NOT_FROMSPACE(check_tc, c) (debug.h:12-26): panics if `p`
/// lies in any thread's nursery fromspace or is on a gen2 free list.
/// Compiled in when MVM_GC_DEBUG is non-zero; a no-op otherwise (debug.h:41).
pub inline fn assertNotFromspace(check_tc: *ThreadContext, p: ?*anyopaque) void {
    if (comptime c.MVM_GC_DEBUG == 0) return;
    var cur_thread: [*c]c.MVMThread = check_tc.instance.*.threads;
    if (p != null) {
        while (cur_thread != null) {
            const thread_tc: [*c]ThreadContext = cur_thread.*.body.tc;
            if (thread_tc != null and thread_tc.*.nursery_fromspace != null and
                @intFromPtr(p) >= @intFromPtr(thread_tc.*.nursery_fromspace) and
                @intFromPtr(p) < @intFromPtr(thread_tc.*.nursery_fromspace) + thread_tc.*.nursery_fromspace_size)
                c.MVM_panic(1, "Collectable %p in fromspace accessed", p);
            cur_thread = cur_thread.*.body.next;
        }
        if (@as(*Collectable, @ptrCast(@alignCast(p))).flags2 & c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST != 0)
            c.MVM_panic(1, "Collectable %p in a gen2 freelist accessed", p);
    }
}

// ---- MVM_ASSIGN_REF from src/gc/wb.h ------------------------------------

/// MVM_ASSIGN_REF(tc, update_root, update_addr, referenced) (wb.h:22-38):
/// under MVM_GC_DEBUG the owner check and MVM_ASSERT_NOT_FROMSPACE, then the
/// write barrier, then the store. `addr` is a pointer to the slot (`*?*T` or `*[*c]T`);
/// `v` is the collectable pointer being stored, or `null`.
pub inline fn assignRef(tc: *ThreadContext, update_root: *Collectable, addr: anytype, v: anytype) void {
    const V = @TypeOf(v);
    const referenced: ?*Collectable = if (V == @TypeOf(null)) null else blk: {
        if (comptime !isCollectablePtr(V)) @compileError("assignRef: expected a collectable pointer or null, got " ++ @typeName(V));
        break :blk @ptrCast(v);
    };
    const A = @TypeOf(addr);
    if (comptime (@typeInfo(A) != .pointer or @typeInfo(A).pointer.size != .one or !isCollectablePtr(@typeInfo(A).pointer.child)))
        @compileError("assignRef: expected a pointer to a collectable pointer slot, got " ++ @typeName(A));
    if (comptime c.MVM_GC_DEBUG != 0) {
        if (referenced) |r| {
            if (r.owner == 0) c.MVM_panic(1, "Invalid assignment (maybe of heap frame to stack frame?)");
        }
        assertNotFromspace(tc, referenced);
    }
    c.MVM_gc_write_barrier(tc, update_root, referenced);
    addr.* = v;
}

// ---- MVMROOT .. MVMROOT6 from src/gc/roots.h ----------------------------

/// Handle returned by `root`/`rootN`; `defer r.pop(tc)` ends the scope.
pub const Root = struct {
    n: u32,
    pub inline fn pop(self: Root, tc: *ThreadContext) void {
        if (self.n == 1) c.MVM_gc_root_temp_pop(tc) else c.MVM_gc_root_temp_pop_n(tc, self.n);
    }
};

/// The argument of `root`/`rootN` must be the address of a collectable
/// pointer variable (`*?*T`, `**T` or `*[*c]T` with T collectable); the
/// collector reads and updates the pointee through it.
inline fn checkRef(comptime T: type) void {
    const info = @typeInfo(T);
    const ok = comptime (info == .pointer and info.pointer.size == .one and isCollectablePtr(info.pointer.child));
    if (!ok) @compileError("root: expected a pointer to a collectable pointer (e.g. *?*MVMObject), got " ++ @typeName(T));
}

/// MVMROOT(tc, obj) { ... }  ->  const r = root(tc, &obj); defer r.pop(tc);
pub inline fn root(tc: *ThreadContext, ref: anytype) Root {
    checkRef(@TypeOf(ref));
    c.MVM_gc_root_temp_push(tc, @ptrCast(ref));
    return .{ .n = 1 };
}

/// MVMROOTn(tc, a, b, ...) { ... }  ->  const r = rootN(tc, .{ &a, &b }); defer r.pop(tc);
pub inline fn rootN(tc: *ThreadContext, refs: anytype) Root {
    const n = refs.len;
    _ = c.__MVM_gc_root_temp_push_ensure_space(tc, n);
    inline for (refs) |ref| {
        checkRef(@TypeOf(ref));
        c.MVM_gc_root_temp_push(tc, @ptrCast(ref));
    }
    return .{ .n = n };
}

// ---- MVM_trycas from src/moar.h -----------------------------------------

/// MVM_trycas(addr, old, new): full-barrier compare-and-swap of a word-sized
/// slot. `addr` is `*usize` or a pointer to a pointer slot (`*?*T`, `**T`,
/// `*[*c]T`); `old` and `new` have the slot's type. True if the swap happened.
pub inline fn trycas(addr: anytype, old: anytype, new: anytype) bool {
    const A = @TypeOf(addr);
    if (comptime (@typeInfo(A) != .pointer or @typeInfo(A).pointer.size != .one))
        @compileError("trycas: expected a pointer to a word-sized slot, got " ++ @typeName(A));
    const S = @typeInfo(A).pointer.child;
    if (comptime S == usize) {
        return @cmpxchgStrong(usize, addr, old, new, .seq_cst, .seq_cst) == null;
    }
    if (comptime (pointee(S) == null)) @compileError("trycas: slot must be usize or a pointer, got " ++ @typeName(S));
    const slot: *usize = @ptrCast(addr);
    const old_word: usize = @intFromPtr(@as(S, old));
    const new_word: usize = @intFromPtr(@as(S, new));
    return @cmpxchgStrong(usize, slot, old_word, new_word, .seq_cst, .seq_cst) == null;
}

// ---- MVM_free_at_safepoint from src/core/alloc.h ------------------------

/// MVM_free_at_safepoint(tc, p) (alloc.h:80-88): queues an MVM_malloc'ed
/// block for MVM_free at the next safepoint. The C is a static inline over
/// MVM_trycas_AO, itself a static inline over a C11 atomic that translate-c
/// leaves as an extern declaration nothing defines, so the translated
/// `c.MVM_free_at_safepoint` compiles but does not link; this is its port.
pub fn freeAtSafepoint(tc: *ThreadContext, to_free: *anyopaque) void {
    const Entry = c.MVMAllocSafepointFreeListEntry;
    // MVM_malloc panics rather than returning null.
    const to_add: *Entry = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf(Entry)) orelse unreachable));
    to_add.to_free = to_free;
    const slot: *[*c]Entry = &tc.instance.*.free_at_safepoint;
    while (true) {
        const orig = slot.*;
        to_add.next = orig;
        if (trycas(slot, orig, @as([*c]Entry, to_add))) break;
    }
}

// ---- std.mem.Allocator over MVM_malloc / MVM_free -------------------------

fn mvmAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // MVM_malloc gives malloc alignment (16 bytes); refuse more rather than
    // hand back misaligned memory.
    if (alignment.compare(.gt, .@"16")) return null;
    const p = c.MVM_malloc(len) orelse return null;
    return @ptrCast(p);
}

fn mvmResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn mvmRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn mvmFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    c.MVM_free(memory.ptr);
}

/// Allocator over MVM_malloc/MVM_free. Resize and remap are unsupported, so
/// callers reallocate by alloc-copy-free. Allocations are at most 16-byte
/// aligned.
pub const mvm_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = mvmAlloc,
        .resize = mvmResize,
        .remap = mvmRemap,
        .free = mvmFree,
    },
};

// ---- tests (compiled only by `zig build unit-test`, linked against libmoar)

extern fn moar_probe_sizeof_tc() usize;
extern fn moar_probe_sizeof_instance() usize;
extern fn moar_probe_offsetof_num_temproots() usize;
extern fn moar_probe_offsetof_int_const_cache() usize;
extern fn moar_probe_offsetof_object_st() usize;

test "translated struct layouts match the C compiler" {
    try std.testing.expectEqual(moar_probe_sizeof_tc(), @sizeOf(c.MVMThreadContext));
    try std.testing.expectEqual(moar_probe_sizeof_instance(), @sizeOf(c.MVMInstance));
    try std.testing.expectEqual(moar_probe_offsetof_num_temproots(), @offsetOf(c.MVMThreadContext, "num_temproots"));
    try std.testing.expectEqual(moar_probe_offsetof_int_const_cache(), @offsetOf(c.MVMInstance, "int_const_cache"));
    try std.testing.expectEqual(moar_probe_offsetof_object_st(), @offsetOf(c.MVMObject, "st"));
}

test "root and rootN push and pop temp roots" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const before = tc.num_temproots;
    var a: ?*Object = instance.*.VMNull;
    var b: ?*Object = instance.*.VMNull;
    var d: ?*Object = instance.*.VMNull;
    {
        const r = root(tc, &a);
        defer r.pop(tc);
        try std.testing.expectEqual(before + 1, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
    {
        const r = rootN(tc, .{ &a, &b });
        defer r.pop(tc);
        try std.testing.expectEqual(before + 2, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
    {
        const r = rootN(tc, .{ &a, &b, &d, &a, &b, &d });
        defer r.pop(tc);
        try std.testing.expectEqual(before + 6, tc.num_temproots);
    }
    try std.testing.expectEqual(before, tc.num_temproots);
}

test "assignRef stores and applies the write barrier" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const array_type: *Object = instance.*.boot_types.BOOTArray;
    var holder: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    const r = root(tc, &holder);
    defer r.pop(tc);
    const value: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    var slot: ?*Object = null;
    const gen2_before = tc.num_gen2roots;
    assignRef(tc, @ptrCast(holder.?), &slot, value);
    try std.testing.expectEqual(value, slot);
    try std.testing.expectEqual(gen2_before, tc.num_gen2roots);
    // Pretend the holder is in gen2: the barrier must now record it.
    holder.?.header.flags2 |= c.MVM_CF_SECOND_GEN;
    assignRef(tc, @ptrCast(holder.?), &slot, value);
    try std.testing.expectEqual(gen2_before + 1, tc.num_gen2roots);
    try std.testing.expect((holder.?.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST) != 0);
    // Undo so the destroy-time collection sees two ordinary nursery objects:
    // clear the flags, take the holder off the gen2 root list the barrier put
    // it on, and clear the "referenced from gen2" mark on the value. (The
    // root handle's defer pops before the destroy defer runs, so the holder
    // is unrooted by then, as any ordinary nursery object would be.)
    holder.?.header.flags2 &= ~@as(u8, c.MVM_CF_SECOND_GEN | c.MVM_CF_IN_GEN2_ROOT_LIST);
    tc.num_gen2roots = gen2_before;
    value.?.header.flags2 &= ~@as(u8, c.MVM_CF_REF_FROM_GEN2);
    try std.testing.expectEqual(gen2_before, tc.num_gen2roots);
}

test "assignRef of a live nursery object passes the debug checks" {
    // At -Dgc-debug=1 this walks every thread's fromspace and the gen2
    // free-list flag (MVM_ASSERT_NOT_FROMSPACE); at 0 the checks are absent.
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const array_type: *Object = instance.*.boot_types.BOOTArray;
    var holder: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    const r = root(tc, &holder);
    defer r.pop(tc);
    const value: ?*Object = c.MVM_repr_alloc_init(tc, array_type);
    try std.testing.expect(@intFromPtr(value) >= @intFromPtr(tc.nursery_tospace) and
        @intFromPtr(value) < @intFromPtr(tc.nursery_alloc_limit));
    var slot: ?*Object = null;
    assignRef(tc, @ptrCast(holder.?), &slot, value);
    try std.testing.expectEqual(value, slot);
    assignRef(tc, @ptrCast(holder.?), &slot, null);
    try std.testing.expectEqual(@as(?*Object, null), slot);
}

test "stable, repr, objectBody and isConcrete" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const null_obj: *Object = instance.*.VMNull;
    try std.testing.expect(!isConcrete(null_obj)); // VMNull is a type object
    try std.testing.expectEqual(stable(null_obj).REPR, repr(null_obj));
    const array_type: *Object = instance.*.boot_types.BOOTArray;
    try std.testing.expect(!isConcrete(array_type));
    const arr: *Object = c.MVM_repr_alloc_init(tc, array_type);
    try std.testing.expect(isConcrete(arr));
    try std.testing.expectEqual(@intFromPtr(arr) + @sizeOf(Object), @intFromPtr(objectBody(arr)));
}

test "trycas swaps only when the slot holds the expected value" {
    var slot: usize = 1;
    try std.testing.expect(trycas(&slot, @as(usize, 1), @as(usize, 2)));
    try std.testing.expectEqual(@as(usize, 2), slot);
    try std.testing.expect(!trycas(&slot, @as(usize, 1), @as(usize, 3)));
    try std.testing.expectEqual(@as(usize, 2), slot);
}

test "freeAtSafepoint queues the block on the instance's list" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance); // runs MVM_alloc_safepoint
    const tc: *ThreadContext = instance.*.main_thread;
    const before = instance.*.free_at_safepoint;
    const block = c.MVM_malloc(64).?;
    freeAtSafepoint(tc, block);
    const head = instance.*.free_at_safepoint;
    try std.testing.expect(head != before);
    try std.testing.expectEqual(@as(?*anyopaque, block), head.*.to_free);
    try std.testing.expect(head.*.next == before);
}

test "mvm_allocator allocates and frees through MVM_malloc" {
    const buf = try mvm_allocator.alloc(u8, 4096);
    defer mvm_allocator.free(buf);
    @memset(buf, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[4095]);
}

test "trycas swaps pointer slots" {
    var x: u32 = 0;
    var y: u32 = 0;
    var opt: ?*u32 = null;
    try std.testing.expect(trycas(&opt, @as(?*u32, null), @as(?*u32, &x)));
    try std.testing.expectEqual(@as(?*u32, &x), opt);
    try std.testing.expect(!trycas(&opt, @as(?*u32, null), @as(?*u32, &y)));
    try std.testing.expectEqual(@as(?*u32, &x), opt);
    var cptr: [*c]u32 = &x;
    try std.testing.expect(trycas(&cptr, @as([*c]u32, &x), @as([*c]u32, &y)));
    try std.testing.expect(cptr == &y);
    try std.testing.expect(!trycas(&cptr, @as([*c]u32, &x), @as([*c]u32, &x)));
    try std.testing.expect(cptr == &y);
}
