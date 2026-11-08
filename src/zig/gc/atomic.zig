//! The C11 atomics of src/moar.h:333-365 (the `MVM_USE_C11_ATOMICS` branch;
//! the libatomic_ops branch at :367-395 is the same operations with full
//! barriers) for the Zig GC port. translate-c cannot use them: `MVM_load`,
//! `MVM_store` and `MVM_trycas` come out as `@compileError` (the `volatile`
//! cast), and `MVM_cas`, a `MVM_STATIC_INLINE` over
//! `atomic_compare_exchange_strong`, as an extern declaration nothing
//! defines. Every operation here is `.seq_cst`, the ordering of the C11
//! generic functions the macros call, and works on `*usize` (the C's
//! `AO_t`), `*u32`, `*u64` and on a pointer slot (`*?*T`, `**T`, `*[*c]T`),
//! volatile or not, and on the same slots through a C pointer. Pointer slots are operated on as the word they are, as
//! the C casts them to `volatile AO_t *`. Pure Zig: no `moar` import, so the
//! host unit tests build it alone.
const std = @import("std");
const builtin = @import("builtin");

fn isIntSlot(comptime S: type) bool {
    return S == usize or S == u32 or S == u64;
}

fn isPtrSlot(comptime S: type) bool {
    var T = S;
    if (@typeInfo(T) == .optional) T = @typeInfo(T).optional.child;
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size != .slice;
}

/// The slot type behind `P`, checked: `P` must be a single-item pointer to
/// an unsigned word (u32, u64, usize) or to a pointer. A C pointer is taken
/// too, since the address of a field reached through a translated `[*c]`
/// (`&tc.*.instance.*.threads`) is one.
fn Slot(comptime P: type) type {
    const info = @typeInfo(P);
    if (info != .pointer or (info.pointer.size != .one and info.pointer.size != .c))
        @compileError("atomic: expected a pointer to a slot, got " ++ @typeName(P));
    const S = info.pointer.child;
    if (!isIntSlot(S) and !isPtrSlot(S))
        @compileError("atomic: slot must be usize, u32, u64 or a pointer, got " ++ @typeName(S));
    return S;
}

/// The slot behind `ptr` without its volatile qualifier: the builtins take
/// plain pointers, and the access is atomic either way.
inline fn plain(ptr: anytype) *Slot(@TypeOf(ptr)) {
    return @volatileCast(ptr);
}

/// A pointer slot as the word it is.
inline fn word(ptr: anytype) *usize {
    return @ptrCast(plain(ptr));
}

/// MVM_load(addr) (moar.h:364): `atomic_load`.
pub inline fn load(ptr: anytype) Slot(@TypeOf(ptr)) {
    const S = Slot(@TypeOf(ptr));
    if (comptime isIntSlot(S)) return @atomicLoad(S, plain(ptr), .seq_cst);
    return @ptrFromInt(@atomicLoad(usize, word(ptr), .seq_cst));
}

/// MVM_store(addr, new) (moar.h:363): `atomic_store`.
pub inline fn store(ptr: anytype, v: Slot(@TypeOf(ptr))) void {
    const S = Slot(@TypeOf(ptr));
    if (comptime isIntSlot(S)) return @atomicStore(S, plain(ptr), v, .seq_cst);
    @atomicStore(usize, word(ptr), @intFromPtr(v), .seq_cst);
}

fn IntSlot(comptime P: type) type {
    const S = Slot(P);
    if (!isIntSlot(S)) @compileError("atomic: add/incr/decr need an integer slot, got " ++ @typeName(S));
    return S;
}

/// MVM_add(addr, add) (moar.h:337): `atomic_fetch_add`; returns the old
/// value. Wraps, as the unsigned C add does.
pub inline fn add(ptr: anytype, v: IntSlot(@TypeOf(ptr))) IntSlot(@TypeOf(ptr)) {
    return @atomicRmw(IntSlot(@TypeOf(ptr)), plain(ptr), .Add, v, .seq_cst);
}

/// MVM_incr(addr) (moar.h:335): `atomic_fetch_add(addr, 1)`; returns the old value.
pub inline fn incr(ptr: anytype) IntSlot(@TypeOf(ptr)) {
    return @atomicRmw(IntSlot(@TypeOf(ptr)), plain(ptr), .Add, 1, .seq_cst);
}

/// MVM_decr(addr) (moar.h:336): `atomic_fetch_sub(addr, 1)`; returns the old value.
pub inline fn decr(ptr: anytype) IntSlot(@TypeOf(ptr)) {
    return @atomicRmw(IntSlot(@TypeOf(ptr)), plain(ptr), .Sub, 1, .seq_cst);
}

/// MVM_cas(addr, old, new) (moar.h:350-354) and MVM_casptr (:356):
/// `atomic_compare_exchange_strong`, returning the value found in the slot,
/// which equals `old` exactly when the swap happened.
pub inline fn cas(ptr: anytype, old: Slot(@TypeOf(ptr)), new: Slot(@TypeOf(ptr))) Slot(@TypeOf(ptr)) {
    const S = Slot(@TypeOf(ptr));
    if (comptime isIntSlot(S))
        return @cmpxchgStrong(S, plain(ptr), old, new, .seq_cst, .seq_cst) orelse old;
    const old_word: usize = @intFromPtr(old);
    const found = @cmpxchgStrong(usize, word(ptr), old_word, @intFromPtr(new), .seq_cst, .seq_cst) orelse old_word;
    return @ptrFromInt(found);
}

/// Word the fallback fence below operates on.
var fence_word: usize = 0;

/// MVM_barrier() (moar.h:359): `atomic_thread_fence(memory_order_seq_cst)`.
/// Zig 0.16 has no `@fence`, so this emits what the C compilers emit for
/// the seq_cst fence: `mfence` on x86, `dmb ish` on ARM64, `fence rw,rw`
/// on RISC-V, each with a memory clobber so the compiler moves no access
/// across it. Elsewhere a seq_cst read-modify-write of a private word,
/// which the hardware orders as a full barrier on the remaining targets.
pub inline fn fence() void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64, .aarch64_be => asm volatile ("dmb ish" ::: .{ .memory = true }),
        .riscv32, .riscv64 => asm volatile ("fence rw,rw" ::: .{ .memory = true }),
        else => _ = @atomicRmw(usize, &fence_word, .Add, 0, .seq_cst),
    }
}

test {
    _ = @import("test/atomic_test.zig");
}
