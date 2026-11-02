//! Test keys for the hash-str-test root: `make(tc, n)` gives `n` distinct
//! `MVMString`s ("k0", "k1", ...) that live for the instance's lifetime:
//! they are allocated straight into gen2 (so they never move) and held by a
//! `BOOTArray` that is rooted permanently, so no collection frees them.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

/// The returned slice is from `std.testing.allocator`; the caller frees it.
/// The strings and their holder are the instance's until it is destroyed:
/// the holder's root slot is `MVM_malloc`ed and never freed, because the
/// permanent root list reads it at every collection.
pub fn make(tc: *moar.ThreadContext, n: u32) ![]const [*c]c.MVMString {
    const keys = try std.testing.allocator.alloc([*c]c.MVMString, n);
    errdefer std.testing.allocator.free(keys);

    c.MVM_gc_allocate_gen2_default_set(tc);
    defer c.MVM_gc_allocate_gen2_default_clear(tc);

    const slot = try moar.mvm_allocator.create([*c]c.MVMCollectable);
    const holder = c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTArray);
    slot.* = @ptrCast(holder);
    c.MVM_gc_root_add_permanent_desc(tc, slot, "hash-str-test keys");

    var buf: [16]u8 = undefined;
    for (keys, 0..) |*key, i| {
        const name = try std.fmt.bufPrintZ(&buf, "k{d}", .{i});
        const s = c.MVM_string_ascii_decode_nt(tc, tc.instance.*.VMString, name.ptr);
        c.MVM_repr_push_o(tc, holder, @ptrCast(s));
        key.* = s;
    }
    return keys;
}
