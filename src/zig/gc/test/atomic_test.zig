//! Tests of `atomic.zig`, pure Zig on the host (`zig build unit-test`, the
//! build-helper roots): `atomic.zig` is the root, and imports this file.
const std = @import("std");
const atomic = @import("../atomic.zig");

test "cas returns the previous value and leaves the slot on mismatch" {
    var w: usize = 5;
    try std.testing.expectEqual(@as(usize, 5), atomic.cas(&w, 5, 7));
    try std.testing.expectEqual(@as(usize, 7), w);
    // Mismatch: the slot keeps 7 and the previous value 7 comes back, as
    // MVM_cas (moar.h:350-354) returns what it found.
    try std.testing.expectEqual(@as(usize, 7), atomic.cas(&w, 5, 9));
    try std.testing.expectEqual(@as(usize, 7), w);
    var h: u32 = 1;
    try std.testing.expectEqual(@as(u32, 1), atomic.cas(&h, 1, 2));
    try std.testing.expectEqual(@as(u32, 2), atomic.cas(&h, 1, 3));
    try std.testing.expectEqual(@as(u32, 2), h);
    var q: u64 = 0xffff_ffff_0000_0000;
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_0000_0000), atomic.cas(&q, 0xffff_ffff_0000_0000, 1));
    try std.testing.expectEqual(@as(u64, 1), q);
}

test "add, incr and decr return the old value" {
    var w: usize = 10;
    try std.testing.expectEqual(@as(usize, 10), atomic.add(&w, 5));
    try std.testing.expectEqual(@as(usize, 15), atomic.incr(&w));
    try std.testing.expectEqual(@as(usize, 16), atomic.decr(&w));
    try std.testing.expectEqual(@as(usize, 15), w);
    var h: u32 = 0xffff_ffff;
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), atomic.incr(&h));
    try std.testing.expectEqual(@as(u32, 0), h); // wraps, as the C unsigned add
    var q: u64 = 0;
    try std.testing.expectEqual(@as(u64, 0), atomic.decr(&q));
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), q);
}

test "load and store" {
    var w: usize = 3;
    try std.testing.expectEqual(@as(usize, 3), atomic.load(&w));
    atomic.store(&w, 4);
    try std.testing.expectEqual(@as(usize, 4), atomic.load(&w));
    var h: u32 = 0;
    atomic.store(&h, 9);
    try std.testing.expectEqual(@as(u32, 9), atomic.load(&h));
}

test "works on a pointer slot" {
    var x: u32 = 0;
    var y: u32 = 0;
    var opt: ?*u32 = null;
    try std.testing.expectEqual(@as(?*u32, null), atomic.cas(&opt, null, &x));
    try std.testing.expectEqual(@as(?*u32, &x), opt);
    try std.testing.expectEqual(@as(?*u32, &x), atomic.cas(&opt, null, &y));
    try std.testing.expectEqual(@as(?*u32, &x), atomic.load(&opt));
    atomic.store(&opt, null);
    try std.testing.expectEqual(@as(?*u32, null), atomic.load(&opt));
    var cptr: [*c]u32 = &x;
    try std.testing.expect(atomic.cas(&cptr, &x, &y) == &x);
    try std.testing.expect(cptr == &y);
    try std.testing.expect(atomic.cas(&cptr, &x, null) == &y);
    try std.testing.expect(atomic.load(&cptr) == &y);
    // A volatile slot, as the C's `MVMGCPassedWork * volatile *`.
    const vslot: *volatile [*c]u32 = &cptr;
    try std.testing.expect(atomic.cas(vslot, &y, null) == &y);
    try std.testing.expect(atomic.load(vslot) == null);
    // Through a C pointer, as `&tc.*.instance.*.threads` is.
    const cslot: [*c][*c]u32 = &cptr;
    atomic.store(cslot, &x);
    try std.testing.expect(atomic.cas(cslot, &x, &y) == &x);
    try std.testing.expect(atomic.load(cslot) == &y);
    var n: usize = 1;
    const cn: [*c]usize = &n;
    try std.testing.expectEqual(@as(usize, 1), atomic.incr(cn));
    try std.testing.expectEqual(@as(usize, 2), atomic.load(cn));
}

test "fence" {
    atomic.fence();
}

test "cas from two threads loses no increment" {
    const N = 10000;
    const Ctx = struct {
        fn run(w: *usize) void {
            for (0..N) |_| {
                while (true) {
                    const old = atomic.load(w);
                    if (atomic.cas(w, old, old + 1) == old) break;
                }
            }
        }
    };
    var w: usize = 0;
    const t1 = try std.Thread.spawn(.{}, Ctx.run, .{&w});
    const t2 = try std.Thread.spawn(.{}, Ctx.run, .{&w});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(usize, 2 * N), w);
}
