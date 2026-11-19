//! The VM array's slot storage: allocating, growing, copying and freeing
//! the buffer behind `MVMArrayBody.slots`, and the REPR data, as
//! `set_size_internal`, `zero_slots`, `copy_to`, `gc_free`,
//! `type_object_for` and `gc_free_repr_data` of src/6model/reprs/VMArray.c
//! do it, but through a `std.mem.Allocator` instead of the C's malloc,
//! realloc and free of src/core/alloc.h (called "the C allocator" below).
//!
//! `Storage(Source)` is that code over the allocator `Source.get()`
//! returns: the REPR instantiates it once with its one declared allocator,
//! the unit tests with `std.testing.allocator`. The allocator is a
//! comptime parameter, so the REPR's instantiation calls it directly with
//! no runtime field or extra indirection.
//!
//! Buffers are requested as bytes, `ssize * elem_size` of them, at the one
//! alignment `kinds.slot_alignment`, so a buffer does not depend on its
//! kind (a recompose changes the kind of live arrays in place). A zero
//! length is never requested: an array without storage has
//! `slots.any == NULL`, as in the C.
//!
//! The lengths given back to the allocator cannot be trusted. Outside C
//! code hands arrays buffers it got from the C allocator with an `ssize` that
//! misstates their size (smaller at io.c `MVM_io_read_bytes` and ops.c
//! `MVM_string_encode_to_buf_config`, about four times larger at normalize.c
//! `MVM_unicode_normalize_codepoints`, and a non-NULL buffer with
//! `ssize == 0` at three sites; traces/llm/bench/va-adoption-audit.md
//! sections 2, 3 and 5), and the C array's own `copy_to` and `deserialize`
//! of a kind without storage keep a zero-byte buffer with `ssize > 0`.
//! So `Source`'s allocator must ignore the length on `free` and must not
//! copy by it on `remap`, as the C allocator's free and realloc (and so
//! `moar.mvm_allocator`) do. A length-sensitive allocator (an arena, a
//! size-class pool, the planned nursery-lifetime spike) needs the adoption
//! sites of that record changed first. For the same reason this file calls
//! the allocator's raw functions: `Allocator.free` and `Allocator.realloc`
//! write and copy by the length and skip a zero-length buffer, which here
//! would leak a received non-NULL buffer with `ssize == 0`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const kinds = @import("kinds.zig");

const slot_alignment = kinds.slot_alignment;

/// The slot storage over the allocator `Source.get()`. `Source` is a type
/// with `pub fn get() std.mem.Allocator`; the allocator must tolerate a
/// misstated length on `free` and `remap`, as malloc does (see the top of
/// this file). The result is a namespace of functions; it has no state.
pub fn Storage(comptime Source: type) type {
    return struct {
        /// A new buffer for `n_slots` slots of `elem_size` bytes, at
        /// `slot_alignment`, uninitialized; null when that is zero bytes
        /// (no slots, or a kind without storage). Out of memory panics, as
        /// the C allocator does. The byte count wraps as the C's
        /// `ssize * elem_size` does (a deserialized count is not checked
        /// against any limit: traces/llm/bench/va-kind-differences.md
        /// row 34b).
        pub fn alloc(n_slots: u64, elem_size: usize) ?[*]u8 {
            const len = n_slots *% elem_size;
            if (len == 0) return null;
            return Source.get().rawAlloc(len, slot_alignment, @returnAddress()) orelse
                c.MVM_panic_allocation_failed(len);
        }

        /// Frees the body's slots, as `gc_free` does; nothing when there
        /// are none. A non-NULL buffer is freed even when
        /// `ssize * elem_size` is zero (a buffer received that way). The
        /// fields are left as they are. The length given to the allocator
        /// is `ssize * elem_size`, which callers may not know: the REPR's
        /// `gc_free` passes `elem_size = 0` (elements.zig `gcFree`). That
        /// is sound only because this calls `rawFree` directly (not
        /// `Allocator.free`, which skips a zero-length slice) and the
        /// allocator ignores the length, as the top of this file requires.
        pub fn free(body: *c.MVMArrayBody, elem_size: usize) void {
            const p: [*]u8 = @ptrCast(body.slots.any orelse return);
            // The C frees without a length; `ssize` may be any count a
            // deserialize or an adopting site stored, so the product wraps
            // rather than trap (the allocator ignores it).
            Source.get().rawFree(p[0 .. body.ssize *% elem_size], slot_alignment, @returnAddress());
        }

        /// Gives the body `n` elements, as `set_size_internal` does, step
        /// for step:
        /// - `n == elems`: nothing.
        /// - `start > 0` and the window would run past `ssize`: move the
        ///   elements to the front (`start = 0`) and zero the slots they
        ///   left.
        /// - otherwise, shrinking: zero the dropped slots of the window.
        /// - `n <= ssize`: set `elems`, done (`ssize` never shrinks).
        /// - else `grow`.
        /// The zeroing throws "MVMArray: Unhandled slot type" for a kind
        /// without storage, as `zero_slots` does.
        ///
        /// `repr_data` is the STable's pointer as loaded, possibly NULL (a
        /// stubbed STable, `derefReprData`), and is dereferenced exactly
        /// where the C dereferences it (VMArray.c:418-419 when there are
        /// elements to move, 423 and 428 for the slot type, 454 in
        /// `grow`): `n == elems`, and `n <= ssize` with neither branch
        /// taken, return without touching it, as in the C.
        pub fn setSize(tc: *c.MVMThreadContext, body: *c.MVMArrayBody, n: u64, repr_data: ?*const c.MVMArrayREPRData) void {
            const elems = body.elems;
            const start = body.start;
            const ssize = body.ssize;
            if (n == elems) return;

            // The slot `grow` zeroes from: past the elements, or past the
            // old storage once a shift has zeroed the slots it vacated.
            var clear_from = elems;
            if (start > 0 and n +% start > ssize) {
                if (elems > 0) {
                    const elem_size = derefReprData(repr_data).elem_size;
                    const live = elems *% elem_size;
                    // live > 0 with start > 0: storage was made by the
                    // shift or unshift that moved start, unless a
                    // recompose left it NULL; then the C's memmove reads
                    // through NULL, and so does this.
                    // (A 0-byte memmove, a kind without storage, touches
                    // nothing, NULL slots included.)
                    if (live > 0) {
                        const p: [*]u8 = @ptrCast(body.slots.any orelse moar.nullDeref(0));
                        @memmove(p[0..live], p[start *% elem_size ..][0..live]);
                    }
                }
                // Before the slot-type read, as the C (421, 423).
                body.start = 0;
                zeroSlots(tc, body, elems, start +% elems, derefReprData(repr_data).slot_type);
                clear_from = ssize;
            } else if (n < elems) {
                zeroSlots(tc, body, n +% start, start +% elems, derefReprData(repr_data).slot_type);
            }

            if (n <= ssize) {
                body.elems = n;
                return;
            }
            grow(tc, body, n, clear_from, derefReprData(repr_data));
        }

        /// The reallocation of `setSize`, out of line as the slow path. The
        /// new `ssize`: below 8,192 slots, twice the old, at least `n`, at
        /// least 8; from 8,192 on, `n` rounded up past the next multiple of
        /// 4,096 (`(n + 0x1000) & ~0xfff`, wrapping as the C's unsigned
        /// arithmetic does; a wrapped size, below `n`, throws "Unable to
        /// allocate an array of <n> elements" before anything is changed).
        /// Above the address budget for the element size it throws "Unable
        /// to allocate an array of <ssize> elements".
        /// Then the buffer is reallocated (`remap`, where the C calls
        /// its realloc) or allocated (where it calls its malloc), the
        /// new slots from `clear_from` are zeroed, and `ssize` and last
        /// `elems` are set.
        ///
        /// Where the new size is zero bytes (a kind without storage, or an
        /// `ssize` that wrapped to 0) the C passes 0 to the C allocator's
        /// malloc or realloc; here the allocator is not called and `slots`
        /// keeps its value. The zeroing that follows throws (a
        /// kind without storage) or runs over a wrapped length (the wrap),
        /// as in the C.
        noinline fn grow(tc: *c.MVMThreadContext, body: *c.MVMArrayBody, n: u64, clear_from: u64, repr_data: *const c.MVMArrayREPRData) void {
            const elem_size = repr_data.elem_size;
            const old_ssize = body.ssize;
            var ssize = old_ssize;
            if (ssize < 8192) {
                ssize *= 2;
                if (n > ssize) ssize = n;
                if (ssize < 8) ssize = 8;
            } else {
                ssize = (n +% 0x1000) & ~@as(u64, 0xfff);
                // A rounded size below n cannot hold the array (the addition
                // wrapped, for n within 4096 of 2**64): refused with the
                // limit's message, naming n (upstream 52aa25019).
                if (ssize < n)
                    c.MVM_exception_throw_adhoc(tc, "Unable to allocate an array of %" ++ c.PRIu64 ++ " elements", n);
            }
            // The budget is 2 ** (index bits - bits to address a byte of
            // an element): the C's table maps 8 to 4, 4 to 3, 2 to 2 and
            // every other size (1, and 0 for the kinds without storage)
            // to 1.
            const elem_addr_bits: u6 = switch (elem_size) {
                8 => 4,
                4 => 3,
                2 => 2,
                else => 1,
            };
            const budget_bits: u6 = @intCast(@as(u7, @bitSizeOf(usize)) - elem_addr_bits);
            if (ssize > (@as(u64, 1) << budget_bits))
                c.MVM_exception_throw_adhoc(tc, "Unable to allocate an array of %" ++ c.PRIu64 ++ " elements", ssize);

            // The C's `ssize * repr_data->elem_size` (size_t, wrapping).
            const len = ssize *% elem_size;
            if (len > 0) {
                if (body.slots.any) |old| {
                    // The old length, which the C never computes (its realloc
                    // takes none): `old_ssize` may come from another kind's
                    // budget (a recompose) or a deserialized count, so wrap.
                    body.slots.any = reallocate(@ptrCast(old), old_ssize *% elem_size, len);
                } else {
                    body.slots.any = alloc(ssize, elem_size);
                }
            }
            zeroSlots(tc, body, clear_from, ssize, repr_data.slot_type);
            body.ssize = ssize;
            // Last, so no thread sees the elements before their slots.
            body.elems = n;
        }

        /// The C's realloc over the allocator: the allocator's `remap`, or,
        /// if it cannot, a new buffer, a copy of the old one's first
        /// `min(old_len, new_len)` bytes and a free. The fallback copies
        /// by the recorded length, so it is exact only where that length is
        /// true; `moar.mvm_allocator` always remaps.
        fn reallocate(old: [*]u8, old_len: usize, new_len: usize) [*]u8 {
            const a = Source.get();
            if (a.rawRemap(old[0..old_len], slot_alignment, new_len, @returnAddress())) |p| return p;
            const p = a.rawAlloc(new_len, slot_alignment, @returnAddress()) orelse
                c.MVM_panic_allocation_failed(new_len);
            const keep = @min(old_len, new_len);
            @memcpy(p[0..keep], old[0..keep]);
            a.rawFree(old[0..old_len], slot_alignment, @returnAddress());
            return p;
        }

        /// Fills `dest` (a fresh body) with a copy of `src`'s elements, as
        /// `copy_to` does: storage of exactly `elems` slots (`ssize =
        /// elems`, `start = 0`) holding the live range from `src.start`,
        /// copied as bytes for every kind (OBJ and STR too: the destination
        /// is a fresh object, no write barrier). No elements: `slots` NULL.
        /// For a kind without storage with elements (after a recompose) the
        /// C keeps a zero-byte buffer; here `slots` is NULL, with the same
        /// `ssize = elems`. `repr_data` may be NULL (`derefReprData`): it
        /// is dereferenced only when there are elements (VMArray.c:56).
        pub fn copyTo(src: *const c.MVMArrayBody, dest: *c.MVMArrayBody, repr_data: ?*const c.MVMArrayREPRData) void {
            dest.elems = src.elems;
            dest.ssize = src.elems;
            dest.start = 0;
            dest.slots.any = null;
            if (dest.elems == 0) return;
            const elem_size = derefReprData(repr_data).elem_size;
            const p = alloc(dest.ssize, elem_size) orelse return;
            const len = dest.ssize *% elem_size; // the C's size_t product, as `alloc`'s
            // NULL only for a source a recompose left without storage: the
            // C's memcpy reads through NULL.
            const from: [*]const u8 = @ptrCast(src.slots.any orelse moar.nullDeref(0));
            @memcpy(p[0..len], from[src.start *% elem_size ..][0..len]);
            dest.slots.any = p;
        }

        /// New REPR data as `type_object_for` starts it: an object array
        /// (`MVM_ARRAY_OBJ`, pointer-sized elements, no element type) until
        /// `compose` says otherwise.
        pub fn createReprData() *c.MVMArrayREPRData {
            const repr_data = Source.get().create(c.MVMArrayREPRData) catch
                c.MVM_panic_allocation_failed(@sizeOf(c.MVMArrayREPRData));
            repr_data.* = .{
                .elem_size = kinds.info(.obj).elem_size,
                .slot_type = c.MVM_ARRAY_OBJ,
                .elem_type = null,
            };
            return repr_data;
        }

        /// Frees REPR data made by `createReprData`, as `gc_free_repr_data`
        /// does (the caller handles an STable without any).
        pub fn destroyReprData(repr_data: *c.MVMArrayREPRData) void {
            Source.get().destroy(repr_data);
        }
    };
}

/// The C's dereference of an array STable's REPR data pointer, which is
/// loaded at the top of most functions and may be NULL: an STable that a
/// nested `MVM_serialization_demand_stable` only stubbed (serialization.c,
/// `stub_stable`) can already have zeroed array objects (elems 0) before
/// `deserialize_repr_data` sets it, and the collector marks them. Callers
/// keep the pointer optional and call this exactly where the C reads a
/// field through it, so a function the C leaves early (an empty array, a
/// throw, a no-op resize) is left early here too; at the read, NULL faults
/// as the C's read does (`moar.nullDeref`).
pub inline fn derefReprData(repr_data: ?*const c.MVMArrayREPRData) *const c.MVMArrayREPRData {
    return repr_data orelse moar.nullDeref(0);
}

/// Zeroes slots `from` to `to` (slot indices, `start` not added), as
/// `zero_slots` does: the bytes of those slots for every stored kind (a
/// NULL pointer for OBJ and STR, +0.0 for the nums), and "MVMArray:
/// Unhandled slot type" thrown for any other slot type, before anything is
/// touched. The length is `to - from` with the C's unsigned wrap.
pub fn zeroSlots(tc: *c.MVMThreadContext, body: *c.MVMArrayBody, from: u64, to: u64, slot_type: u8) void {
    kinds.dispatch(slot_type, zeroArm, .{ tc, body, from, to }, kinds.Otherwise{ .throw = "MVMArray: Unhandled slot type" });
}

/// `zeroSlots` for one stored kind (an arm of its `dispatch`).
fn zeroArm(comptime k: kinds.Kind, tc: *c.MVMThreadContext, body: *c.MVMArrayBody, from: u64, to: u64) void {
    _ = tc; // only the not-stored path of `dispatch` reads it
    const count = to -% from;
    if (count == 0) return;
    const p: [*]u8 = @ptrCast(kinds.slots(k, body) + from);
    @memset(p[0 .. count *% kinds.info(k).elem_size], 0);
}
