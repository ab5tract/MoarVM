//! Test keys for the hash-str-test root and the microbenchmark: `make(tc, n)`
//! gives `n` distinct `MVMString`s ("k0", "k1", ...) that live for the
//! instance's lifetime: they are allocated straight into gen2 (so they never
//! move) and held by a `BOOTArray` that is rooted permanently, so no
//! collection frees them. `makeNamed` is the same with a caller's allocator
//! and name prefix (the benchmark's "m<n>" miss keys).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;

/// The returned slice is from `std.testing.allocator`; the caller frees it.
pub fn make(tc: *moar.ThreadContext, n: u32) ![]const [*c]c.MVMString {
    return makeNamed(std.testing.allocator, tc, "k", n);
}

/// The returned slice is from `allocator`; the caller frees it. The strings
/// and their holder are the instance's until it is destroyed: the holder's
/// root slot is `MVM_malloc`ed and never freed, because the permanent root
/// list reads it at every collection.
pub fn makeNamed(allocator: std.mem.Allocator, tc: *moar.ThreadContext, prefix: []const u8, n: u32) ![]const [*c]c.MVMString {
    const keys = try allocator.alloc([*c]c.MVMString, n);
    errdefer allocator.free(keys);

    c.MVM_gc_allocate_gen2_default_set(tc);
    defer c.MVM_gc_allocate_gen2_default_clear(tc);

    const slot = try moar.mvm_allocator.create([*c]c.MVMCollectable);
    const holder = c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTArray);
    slot.* = @ptrCast(holder);
    c.MVM_gc_root_add_permanent_desc(tc, slot, "hash test keys");

    var buf: [32]u8 = undefined;
    for (keys, 0..) |*key, i| {
        const name = try std.fmt.bufPrintZ(&buf, "{s}{d}", .{ prefix, i });
        const s = c.MVM_string_ascii_decode_nt(tc, tc.instance.*.VMString, name.ptr);
        c.MVM_repr_push_o(tc, holder, @ptrCast(s));
        key.* = s;
    }
    return keys;
}
