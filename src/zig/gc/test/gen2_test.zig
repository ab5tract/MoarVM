//! Tests of `gen2.zig` (the port of src/gc/gen2.c) on a booted VM. The
//! allocators under test are private to each test (never `tc->gen2`), so
//! the VM's own collections never walk the items written here.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const gen2 = @import("../gen2.zig");
const view = @import("../view.zig");

const Gen2 = view.Gen2;
const Tc = view.Tc;
const Collectable = c.MVMCollectable;

/// Puts `item` on the free list of `bin`, threading through its first word
/// in the C's `char **` layout, as the sweep in collect.c does (not through
/// gen2.zig's typed view, so the tests pin the byte layout).
fn pushFree(al: Gen2, bin: u32, item: *anyopaque) void {
    const slot: *[*c][*c]u8 = @ptrCast(@alignCast(item));
    slot.* = al.size_classes[bin].free_list;
    al.size_classes[bin].free_list = @ptrCast(@alignCast(item));
}

/// A bare thread context for transfer, which reads only gen2, thread_id and
/// the gen2 roots.
fn bareTc() Tc {
    return @ptrCast(@alignCast(c.MVM_calloc(1, @sizeOf(c.MVMThreadContext))));
}

fn addr(p: anytype) usize {
    return @intFromPtr(p);
}

test "bin geometry matches gen2.c" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    // (size, bin, item size). gen2.c:66-68 rounds a size that is not a
    // multiple of 8 up to the next bin, so 12 shares bin 1 with 16.
    const Row = struct { size: u32, bin: u32, item: u32 };
    const rows = [_]Row{
        .{ .size = 8, .bin = 0, .item = 8 },
        .{ .size = 12, .bin = 1, .item = 16 },
        .{ .size = 16, .bin = 1, .item = 16 },
        .{ .size = 24, .bin = 2, .item = 24 },
        .{ .size = 313, .bin = 39, .item = 320 },
        .{ .size = 320, .bin = 39, .item = 320 },
    };
    for (rows) |row| {
        try std.testing.expectEqual(row.bin, gen2.binOf(row.size));
        try std.testing.expectEqual(row.item, gen2.sizeOfBin(row.bin));
        const al = gen2.create(instance);
        defer gen2.destroy(instance, al);
        const p = gen2.allocate(al, row.size);
        const sc = al.size_classes[row.bin];
        try std.testing.expect(sc.pages != null);
        try std.testing.expectEqual(@as(u32, 1), sc.num_pages);
        try std.testing.expectEqual(addr(sc.pages[0]), addr(p));
        try std.testing.expectEqual(addr(p) + row.item, addr(sc.alloc_pos));
        try std.testing.expectEqual(addr(sc.pages[0]) + 256 * row.item, addr(sc.alloc_limit));
        try std.testing.expectEqual(@as(u32, 0), al.num_overflows);
        for (0..40) |b| {
            if (b != row.bin) try std.testing.expect(al.size_classes[b].pages == null);
        }
    }
    // Past bin 39 (anything over 320 bytes) the C mallocs into overflows.
    for ([_]u32{ 321, 328, 4096 }) |size| {
        try std.testing.expect(gen2.binOf(size) >= 40);
        const al = gen2.create(instance);
        defer gen2.destroy(instance, al);
        const p = gen2.allocate(al, size);
        try std.testing.expectEqual(@as(u32, 1), al.num_overflows);
        try std.testing.expectEqual(addr(p), addr(al.overflows[0]));
        for (0..40) |b| try std.testing.expect(al.size_classes[b].pages == null);
    }
    // The overflows list starts at 32 and doubles.
    {
        const al = gen2.create(instance);
        defer gen2.destroy(instance, al);
        try std.testing.expectEqual(@as(u32, 32), al.alloc_overflows);
        var ps: [33]*anyopaque = undefined;
        for (&ps) |*p| p.* = gen2.allocate(al, 400);
        try std.testing.expectEqual(@as(u32, 64), al.alloc_overflows);
        try std.testing.expectEqual(@as(u32, 33), al.num_overflows);
        for (ps, 0..) |p, k| try std.testing.expectEqual(addr(p), addr(al.overflows[k]));
    }
}

test "allocate returns page items in order and reuses the free list" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const al = gen2.create(instance);
    defer gen2.destroy(instance, al);
    const bin = 2;
    var items: [256]*anyopaque = undefined;
    for (&items, 0..) |*it, k| {
        it.* = gen2.allocate(al, 24);
        try std.testing.expectEqual(addr(al.size_classes[bin].pages[0]) + 24 * k, addr(it.*));
    }
    // The page is full: the next item opens page 1 and moves cur_page.
    const next = gen2.allocate(al, 24);
    const sc = &al.size_classes[bin];
    try std.testing.expectEqual(@as(u32, 2), sc.num_pages);
    try std.testing.expectEqual(@as(u32, 1), sc.cur_page);
    try std.testing.expectEqual(addr(sc.pages[1]), addr(next));
    // Freed items come back last-in first-out before the bump pointer moves.
    pushFree(al, bin, items[5]);
    pushFree(al, bin, items[9]);
    const pos = sc.alloc_pos;
    try std.testing.expectEqual(addr(items[9]), addr(gen2.allocate(al, 24)));
    try std.testing.expectEqual(addr(items[5]), addr(gen2.allocate(al, 24)));
    try std.testing.expect(sc.free_list == null);
    try std.testing.expectEqual(addr(pos), addr(sc.alloc_pos));
    try std.testing.expectEqual(addr(pos), addr(gen2.allocate(al, 24)));
}

/// The page walk of the faithful port (`git show 0b3c10c98:src/zig/gc/gen2.zig`,
/// MVM_gc_gen2_transfer, gen2.c:189-207), pointer arithmetic over `[*c]u8`,
/// kept here to compare the slice form against: every slot of a full page,
/// and of the last page the slots below `alloc_pos`. Writes the addresses
/// to `out` in walk order and returns their count.
fn faithfulPageWalk(sc: *const c.MVMGen2SizeClass, obj_size: u32, out: []usize) usize {
    var n: usize = 0;
    var cur_ptr: [*c]u8 = undefined;
    var end_ptr: [*c]u8 = undefined;
    var page: c.MVMuint32 = 0;
    while (page < sc.num_pages) : (page += 1) {
        cur_ptr = sc.pages[page];
        end_ptr = if (page +% 1 == sc.num_pages)
            sc.alloc_pos
        else
            cur_ptr + obj_size *% c.MVM_GEN2_PAGE_ITEMS;
        while (@intFromPtr(cur_ptr) < @intFromPtr(end_ptr)) {
            out[n] = @intFromPtr(cur_ptr);
            n += 1;
            cur_ptr += obj_size;
        }
    }
    return n;
}

test "page walk through slices visits the same addresses as the C arithmetic" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const al = gen2.create(instance);
    defer gen2.destroy(instance, al);
    const bin = 2;
    const obj_size = gen2.sizeOfBin(bin);
    const count = c.MVM_GEN2_PAGE_ITEMS + 1;
    var items: [count]usize = undefined;
    for (&items) |*it| it.* = @intFromPtr(gen2.allocate(al, 24));
    const sc = &al.size_classes[bin];
    // A full page 0 and one item on page 1.
    try std.testing.expectEqual(@as(u32, 2), sc.num_pages);

    var faithful: [2 * c.MVM_GEN2_PAGE_ITEMS]usize = undefined;
    const n_faithful = faithfulPageWalk(sc, obj_size, &faithful);
    var sliced: [2 * c.MVM_GEN2_PAGE_ITEMS]usize = undefined;
    var n_sliced: usize = 0;
    for (sc.pages[0..sc.num_pages], 0..) |_, k| {
        var slots = gen2.pageItems(sc, k, obj_size);
        while (slots.next()) |slot| : (n_sliced += 1) sliced[n_sliced] = @intFromPtr(slot);
    }

    // The same addresses in the same order, and they are the items allocated.
    try std.testing.expectEqual(@as(usize, count), n_faithful);
    try std.testing.expectEqualSlices(usize, faithful[0..n_faithful], sliced[0..n_sliced]);
    try std.testing.expectEqualSlices(usize, &items, sliced[0..n_sliced]);

    // The rest of the last page, as transfer chains it onto a free list:
    // from `alloc_pos` up to `alloc_limit`, the C's `cur_ptr < end_ptr`.
    var rest = gen2.Slots.init(sc.alloc_pos, sc.alloc_limit, obj_size);
    var n_rest: usize = 0;
    var expect = @intFromPtr(sc.alloc_pos);
    while (rest.next()) |slot| : (n_rest += 1) {
        try std.testing.expectEqual(expect, @intFromPtr(slot));
        expect += obj_size;
    }
    try std.testing.expectEqual(@as(usize, c.MVM_GEN2_PAGE_ITEMS - 1), n_rest);
    try std.testing.expectEqual(@intFromPtr(sc.alloc_limit), expect);
}

test "allocate_zeroed zeroes" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const al = gen2.create(instance);
    defer gen2.destroy(instance, al);
    for ([_]u32{ 64, 1000 }) |size| {
        // A free-list item full of junk (bin 7), and an overflow block.
        const reused: ?*anyopaque = if (size == 64) blk: {
            const p = gen2.allocate(al, size);
            @memset(@as([*]u8, @ptrCast(p))[0..size], 0xAB);
            pushFree(al, 7, p);
            break :blk p;
        } else null;
        const z = gen2.allocateZeroed(al, size);
        if (reused) |p| try std.testing.expectEqual(addr(p), addr(z));
        const col: *Collectable = @ptrCast(@alignCast(z));
        try std.testing.expectEqual(@as(u8, c.MVM_CF_SECOND_GEN), col.flags2);
        col.flags2 = 0;
        for (@as([*]u8, @ptrCast(z))[0..size]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "transfer moves every page and overflow to dest and leaves src empty" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const src = bareTc();
    defer c.MVM_free(src);
    const dest = bareTc();
    defer c.MVM_free(dest);
    src.gen2 = gen2.create(instance);
    dest.gen2 = gen2.create(instance);
    defer gen2.destroy(instance, dest.gen2);
    defer gen2.destroy(instance, src.gen2);
    src.thread_id = 7;
    dest.thread_id = 9;
    src.alloc_gen2roots = 4;
    src.gen2roots = @ptrCast(@alignCast(c.MVM_malloc(4 * @sizeOf([*c]Collectable))));
    dest.alloc_gen2roots = 4;
    dest.gen2roots = @ptrCast(@alignCast(c.MVM_malloc(4 * @sizeOf([*c]Collectable))));
    defer c.MVM_free(@ptrCast(dest.gen2roots));

    // Source bin 2: 300 items over two pages, one of them on the free list.
    const bin = 2;
    var items: [300]*Collectable = undefined;
    for (&items) |*it| {
        it.* = @ptrCast(@alignCast(gen2.allocate(src.gen2, 24)));
        it.*.* = std.mem.zeroes(Collectable);
        it.*.owner = 7;
    }
    pushFree(src.gen2, bin, items[10]);
    // Source overflows: two blocks.
    var big: [2]*Collectable = undefined;
    for (&big) |*b| {
        b.* = @ptrCast(@alignCast(gen2.allocate(src.gen2, 500)));
        b.*.* = std.mem.zeroes(Collectable);
        b.*.owner = 7;
    }
    // One gen2 root in the source.
    src.gen2roots[0] = items[0];
    src.num_gen2roots = 1;
    // Dest bin 2 has one page with one item used; the rest of that page
    // gets chained onto dest's free list ahead of src's free list.
    const dest_item = gen2.allocate(dest.gen2, 24);
    const dest_page0 = dest.gen2.*.size_classes[bin].pages[0];
    // Dest overflows: one block.
    const dest_big = gen2.allocate(dest.gen2, 500);

    const src_pages = [2][*c]u8{ src.gen2.*.size_classes[bin].pages[0], src.gen2.*.size_classes[bin].pages[1] };
    const src_pos = src.gen2.*.size_classes[bin].alloc_pos;
    const src_limit = src.gen2.*.size_classes[bin].alloc_limit;

    gen2.transfer(src, dest);

    const dsc = dest.gen2.*.size_classes[bin];
    try std.testing.expectEqual(@as(u32, 3), dsc.num_pages);
    try std.testing.expect(dsc.pages[0] == dest_page0);
    try std.testing.expect(dsc.pages[1] == src_pages[0]);
    try std.testing.expect(dsc.pages[2] == src_pages[1]);
    try std.testing.expect(dsc.alloc_pos == src_pos);
    try std.testing.expect(dsc.alloc_limit == src_limit);
    // Owners: every allocated item moves to dest, the free-list one not.
    for (items, 0..) |it, k| try std.testing.expectEqual(@as(u32, if (k == 10) 7 else 9), it.owner);
    // Dest free list: the 255 unused slots of dest's page in order, then
    // the source's free-list item.
    var node: [*c][*c]u8 = dsc.free_list;
    var n: usize = 0;
    while (node != null) : (n += 1) {
        const expect = if (n < 255) addr(dest_item) + 24 * (n + 1) else addr(items[10]);
        try std.testing.expectEqual(expect, addr(node));
        node = @ptrCast(@alignCast(node.*));
    }
    try std.testing.expectEqual(@as(usize, 256), n);
    // Overflows: dest's own, then the source's in order, now owned by dest.
    try std.testing.expectEqual(@as(u32, 3), dest.gen2.*.num_overflows);
    try std.testing.expectEqual(addr(dest_big), addr(dest.gen2.*.overflows[0]));
    try std.testing.expectEqual(addr(big[0]), addr(dest.gen2.*.overflows[1]));
    try std.testing.expectEqual(addr(big[1]), addr(dest.gen2.*.overflows[2]));
    for (big) |b| try std.testing.expectEqual(@as(u32, 9), b.owner);
    // Gen2 roots moved.
    try std.testing.expectEqual(@as(u32, 1), dest.num_gen2roots);
    try std.testing.expectEqual(addr(items[0]), addr(dest.gen2roots[0]));
    try std.testing.expect(src.gen2roots == null);
    try std.testing.expectEqual(@as(u32, 0), src.num_gen2roots);
    try std.testing.expectEqual(@as(u32, 0), src.alloc_gen2roots);
    // Source left empty.
    for (0..40) |b| {
        try std.testing.expect(src.gen2.*.size_classes[b].pages == null);
        try std.testing.expectEqual(@as(u32, 0), src.gen2.*.size_classes[b].num_pages);
    }
    try std.testing.expect(src.gen2.*.overflows == null);
    try std.testing.expectEqual(@as(u32, 0), src.gen2.*.num_overflows);
    try std.testing.expectEqual(@as(u32, 0), src.gen2.*.alloc_overflows);
}

test "transfer grows dest overflows to double the larger list" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const src = bareTc();
    defer c.MVM_free(src);
    const dest = bareTc();
    defer c.MVM_free(dest);
    src.gen2 = gen2.create(instance);
    dest.gen2 = gen2.create(instance);
    defer gen2.destroy(instance, dest.gen2);
    defer gen2.destroy(instance, src.gen2);
    src.gen2roots = @ptrCast(@alignCast(c.MVM_malloc(@sizeOf([*c]Collectable))));
    // 40 in src (alloc 64), 30 in dest (alloc 32): 70 > 32, so 64 * 2.
    for (0..40) |_| {
        const b: *Collectable = @ptrCast(@alignCast(gen2.allocate(src.gen2, 400)));
        b.* = std.mem.zeroes(Collectable);
    }
    for (0..30) |_| _ = gen2.allocate(dest.gen2, 400);
    gen2.transfer(src, dest);
    try std.testing.expectEqual(@as(u32, 128), dest.gen2.*.alloc_overflows);
    try std.testing.expectEqual(@as(u32, 70), dest.gen2.*.num_overflows);
}

test "compact_overflows drops NULL entries and keeps order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const al = gen2.create(instance);
    defer gen2.destroy(instance, al);
    var ps: [6]*anyopaque = undefined;
    for (&ps) |*p| p.* = gen2.allocate(al, 1024);
    // Free 1, 3 and 4, as the sweep does, leaving NULLs.
    for ([_]usize{ 1, 3, 4 }) |k| {
        c.MVM_free(@ptrCast(al.overflows[k]));
        al.overflows[k] = null;
    }
    gen2.compactOverflows(al);
    try std.testing.expectEqual(@as(u32, 3), al.num_overflows);
    try std.testing.expectEqual(addr(ps[0]), addr(al.overflows[0]));
    try std.testing.expectEqual(addr(ps[2]), addr(al.overflows[1]));
    try std.testing.expectEqual(addr(ps[5]), addr(al.overflows[2]));
    try std.testing.expectEqual(@as(u32, 32), al.alloc_overflows);
    // No NULLs: a no-op.
    gen2.compactOverflows(al);
    try std.testing.expectEqual(@as(u32, 3), al.num_overflows);
}

test "destroy frees every page" {
    // MVM_free cannot be counted from here; destroy must return with pages
    // in many bins, a multi-page bin and overflows (with a NULL among them),
    // and a second create must work.
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const al = gen2.create(instance);
    var size: u32 = 8;
    while (size <= 320) : (size += 8) _ = gen2.allocate(al, size);
    for (0..600) |_| _ = gen2.allocate(al, 16);
    for (0..3) |_| _ = gen2.allocate(al, 2048);
    c.MVM_free(@ptrCast(al.overflows[1]));
    al.overflows[1] = null;
    gen2.destroy(instance, al);
    const again = gen2.create(instance);
    defer gen2.destroy(instance, again);
    try std.testing.expectEqual(@as(u32, 0), again.num_overflows);
    try std.testing.expectEqual(@as(u32, 32), again.alloc_overflows);
    for (0..40) |b| try std.testing.expect(again.size_classes[b].pages == null);
    try std.testing.expect(@intFromPtr(gen2.allocate(again, 8)) != 0);
}
