//! The pointer table of `../ptr.zig` driven through its C-shaped API. Runs
//! in the libmoar-linked `hash-str-test` binary (root `../hash_test.zig`):
//! the production Spec allocates through `moar.mvm_allocator`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const ptr = @import("../ptr.zig");

const testing = std.testing;

/// The keys: addresses of this array's elements, distinct and stable.
var cells: [1000]u64 = undefined;

fn unbuilt() c.MVMPtrHashTable {
    return std.mem.zeroes(c.MVMPtrHashTable);
}

test "insert 1000 distinct pointers (addresses of a static array's elements), fetch each, fetch_and_delete half returns the stored values, the rest still found, is_empty after deleting all" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *moar.ThreadContext = instance.*.main_thread;

    var ht = unbuilt();
    ptr.build(tc, &ht);
    try testing.expect(ht.table == null);
    try testing.expect(ptr.isEmpty(tc, &ht));
    try testing.expectEqual(@as(?*c.MVMPtrHashEntry, null), ptr.fetch(tc, &ht, &cells[0]));
    try testing.expectEqual(@as(usize, 0), ptr.fetchAndDelete(tc, &ht, &cells[0]));
    defer ptr.demolish(tc, &ht);

    for (&cells, 0..) |*cell, i| ptr.insert(tc, &ht, cell, i + 1);
    try testing.expect(ht.table != null);
    try testing.expect(!ptr.isEmpty(tc, &ht));
    for (&cells, 0..) |*cell, i| {
        const e = ptr.fetch(tc, &ht, cell) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(?*const anyopaque, cell), e.key);
        try testing.expectEqual(i + 1, e.value);
    }
    // Inserting a present key with its value again is a no-op.
    ptr.insert(tc, &ht, &cells[7], 8);
    try testing.expectEqual(@as(usize, 8), ptr.fetch(tc, &ht, &cells[7]).?.value);

    // lvalue_fetch of a present key is the same entry; of an absent one a
    // fresh entry with a NULL key.
    try testing.expectEqual(ptr.fetch(tc, &ht, &cells[3]).?, ptr.lvalueFetch(tc, &ht, &cells[3]));
    var extra: u64 = 0;
    const fresh = ptr.lvalueFetch(tc, &ht, &extra);
    try testing.expectEqual(@as(?*const anyopaque, null), fresh.key);
    fresh.key = &extra;
    fresh.value = 4242;
    try testing.expectEqual(@as(usize, 4242), ptr.fetch(tc, &ht, &extra).?.value);
    try testing.expectEqual(@as(usize, 4242), ptr.fetchAndDelete(tc, &ht, &extra));

    for (&cells, 0..) |*cell, i| {
        if (i % 2 == 0) try testing.expectEqual(i + 1, ptr.fetchAndDelete(tc, &ht, cell));
    }
    for (&cells, 0..) |*cell, i| {
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?*c.MVMPtrHashEntry, null), ptr.fetch(tc, &ht, cell));
            // A second delete of an absent key returns 0, as in C.
            try testing.expectEqual(@as(usize, 0), ptr.fetchAndDelete(tc, &ht, cell));
        } else {
            try testing.expectEqual(i + 1, ptr.fetch(tc, &ht, cell).?.value);
        }
    }
    try testing.expect(!ptr.isEmpty(tc, &ht));
    try testing.expectEqual(@as(u64, 0), ptr.PtrTable.fsck({}, ptr.handleOf(&ht), 0));

    for (&cells, 0..) |*cell, i| {
        if (i % 2 == 1) try testing.expectEqual(i + 1, ptr.fetchAndDelete(tc, &ht, cell));
    }
    try testing.expect(ptr.isEmpty(tc, &ht));
    try testing.expect(ht.table != null);
}

test "demolish leaves the table unbuilt and is idempotent" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *moar.ThreadContext = instance.*.main_thread;

    var ht = unbuilt();
    ptr.demolish(tc, &ht);
    ptr.insert(tc, &ht, &cells[0], 1);
    try testing.expect(ht.table != null);
    ptr.demolish(tc, &ht);
    try testing.expect(ht.table == null);
    ptr.demolish(tc, &ht);
}
