//! The index table of `../index.zig` driven through its C-shaped API on real
//! `MVMString`s. Runs in the libmoar-linked `hash-str-test` binary (root
//! `../hash_test.zig`).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const index = @import("../index.zig");
const keys = @import("keys.zig");

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

const not_found: u32 = c.MVM_INDEX_HASH_NOT_FOUND;

fn unbuilt() c.MVMIndexHashTable {
    return std.mem.zeroes(c.MVMIndexHashTable);
}

/// The C's `MVMString **list` from the test keys.
fn listOf(ks: []const [*c]c.MVMString) [*c][*c]c.MVMString {
    return @constCast(ks.ptr);
}

test "index: build(10), insert indices 0..9 of a 10-string list, fetch each by string, fetch of an absent string is NOT_FOUND, shallow_copy iterates the same" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const ks = try keys.make(tc, 11);
    defer testing.allocator.free(ks);
    const list = listOf(ks[0..10]);
    const absent = ks[10];

    var ht = unbuilt();
    try testing.expect(!index.built(tc, &ht));
    try testing.expect(index.isEmpty(tc, &ht));
    try testing.expectEqual(@as(usize, 0), index.allocatedSize(tc, &ht));
    try testing.expectEqual(not_found, index.fetchNocheck(tc, &ht, list, ks[0]));
    try testing.expectEqual(not_found, index.fetch(tc, &ht, list, ks[0]));

    index.build(tc, &ht, 10);
    defer index.demolish(tc, &ht);
    try testing.expect(index.built(tc, &ht));
    try testing.expect(index.isEmpty(tc, &ht));
    try testing.expect(index.allocatedSize(tc, &ht) > 0);
    try testing.expectEqual(not_found, index.fetchNocheck(tc, &ht, list, ks[0]));

    // Index 0 is a key like any other (the engine's "unfilled" key is not
    // an index).
    for (0..10) |i| index.insertNocheck(tc, &ht, list, @intCast(i));
    try testing.expect(!index.isEmpty(tc, &ht));
    for (ks[0..10], 0..) |k, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), index.fetchNocheck(tc, &ht, list, k));
        try testing.expectEqual(@as(u32, @intCast(i)), index.fetch(tc, &ht, list, k));
    }
    try testing.expectEqual(not_found, index.fetchNocheck(tc, &ht, list, absent));
    try testing.expectEqual(not_found, index.fetch(tc, &ht, list, absent));

    // A copy built from the same list finds the same indices, at the same
    // size; an unbuilt source leaves the destination untouched.
    var copy = unbuilt();
    index.shallowCopy(tc, &ht, &copy);
    defer index.demolish(tc, &copy);
    try testing.expect(index.built(tc, &copy));
    try testing.expect(copy.table != ht.table);
    try testing.expectEqual(index.allocatedSize(tc, &ht), index.allocatedSize(tc, &copy));
    try testing.expectEqual(index.IndexTable.count(index.handleOf(&ht)), index.IndexTable.count(index.handleOf(&copy)));
    var pos = index.IndexTable.first(index.handleOf(&ht));
    var cpos = index.IndexTable.first(index.handleOf(&copy));
    var walked: u32 = 0;
    while (pos != 0) : ({
        pos = index.IndexTable.next(index.handleOf(&ht), pos);
        cpos = index.IndexTable.next(index.handleOf(&copy), cpos);
        walked += 1;
    }) {
        try testing.expectEqual(pos, cpos);
    }
    try testing.expectEqual(@as(u32, 0), cpos);
    try testing.expectEqual(@as(u32, 10), walked);
    for (ks[0..10], 0..) |k, i| try testing.expectEqual(@as(u32, @intCast(i)), index.fetch(tc, &copy, list, k));
    try testing.expectEqual(not_found, index.fetch(tc, &copy, list, absent));
    var none = unbuilt();
    var dest_of_none = unbuilt();
    index.shallowCopy(tc, &none, &dest_of_none);
    try testing.expect(!index.built(tc, &dest_of_none));
}

test "index: growth from the minimum size keeps every index findable" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const n: u32 = 500;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);
    const list = listOf(ks);

    var ht = unbuilt();
    index.build(tc, &ht, 0);
    defer index.demolish(tc, &ht);
    try testing.expect(index.built(tc, &ht));
    const before = index.allocatedSize(tc, &ht);
    for (0..n) |i| index.insertNocheck(tc, &ht, list, @intCast(i));
    try testing.expect(index.allocatedSize(tc, &ht) > before);
    for (ks, 0..) |k, i| try testing.expectEqual(@as(u32, @intCast(i)), index.fetchNocheck(tc, &ht, list, k));
    const ctx: index.IndexSpec.Ctx = .{ .tc = tc, .list = list };
    try testing.expectEqual(@as(u64, 0), index.IndexTable.fsck(ctx, index.handleOf(&ht), 0));
    index.demolish(tc, &ht);
    try testing.expect(!index.built(tc, &ht));
}
