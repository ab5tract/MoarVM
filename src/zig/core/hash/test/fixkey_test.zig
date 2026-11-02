//! The fixkey table of `../fixkey.zig` driven through its C-shaped API on
//! real `MVMString`s. Runs in the libmoar-linked `hash-str-test` binary
//! (root `../hash_test.zig`).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const fixkey = @import("../fixkey.zig");
const keys = @import("keys.zig");

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

/// What the tests store behind the indirection: key first, as the API
/// requires, 24 bytes in all.
const Entry = extern struct {
    key: [*c]c.MVMString,
    value: u64,
    extra: u64,
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 24);
}

fn unbuilt() c.MVMFixKeyHashTable {
    return std.mem.zeroes(c.MVMFixKeyHashTable);
}

fn entryOf(p: ?*anyopaque) *Entry {
    return @ptrCast(@alignCast(p.?));
}

const Counter = struct {
    seen: u32 = 0,
    sum: u64 = 0,
};

fn count(tc: [*c]c.MVMThreadContext, entry: ?*anyopaque, arg: ?*anyopaque) callconv(.c) void {
    _ = tc;
    const counter: *Counter = @ptrCast(@alignCast(arg.?));
    counter.seen += 1;
    counter.sum += entryOf(entry).value;
}

test "fixkey: insert 200 keys with entry_size 24; each fresh entry is malloced with its first word the key; foreach visits 200; fetch_nocheck finds each" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const n: u32 = 200;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    try testing.expect(fixkey.isEmpty(tc, &ht));
    try testing.expectEqual(@as(?*anyopaque, null), fixkey.fetchNocheck(tc, &ht, ks[0]));
    fixkey.build(tc, &ht, @sizeOf(Entry));
    defer fixkey.demolish(tc, &ht);
    try testing.expect(ht.table != null);
    try testing.expect(fixkey.isEmpty(tc, &ht));
    try testing.expectEqual(@as(?*anyopaque, null), fixkey.fetchNocheck(tc, &ht, ks[0]));

    var entries = try testing.allocator.alloc(*Entry, n);
    defer testing.allocator.free(entries);
    for (ks, 0..) |k, i| {
        const e = entryOf(fixkey.insertNocheck(tc, &ht, k));
        try testing.expectEqual(k, e.key);
        e.value = i;
        e.extra = 0xFEED;
        entries[i] = e;
    }
    try testing.expect(!fixkey.isEmpty(tc, &ht));

    // The entries never move: the hash grew several times (8 official slots
    // at build) and every pointer is still the one returned at insert.
    for (ks, 0..) |k, i| {
        const found = fixkey.fetchNocheck(tc, &ht, k) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(entries[i], entryOf(found));
        try testing.expectEqual(i, entryOf(found).value);
        // A present key: the same entry, through lvalue_fetch too.
        try testing.expectEqual(entries[i], entryOf(fixkey.lvalueFetchNocheck(tc, &ht, k)));
    }

    var counter = Counter{};
    fixkey.foreach(tc, &ht, count, &counter);
    try testing.expectEqual(n, counter.seen);
    try testing.expectEqual(@as(u64, (n - 1) * n / 2), counter.sum);

    try testing.expectEqual(@as(u64, 0), fixkey.fsck(tc, &ht, 0));
}

test "fixkey: lvalue_fetch_nocheck of an absent key mallocs an entry with a NULL first word to fill in" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const ks = try keys.make(tc, 2);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    fixkey.build(tc, &ht, @sizeOf(Entry));
    defer fixkey.demolish(tc, &ht);

    const e = entryOf(fixkey.lvalueFetchNocheck(tc, &ht, ks[0]));
    try testing.expectEqual(@as([*c]c.MVMString, null), e.key);
    e.key = ks[0];
    e.value = 11;
    try testing.expectEqual(e, entryOf(fixkey.fetchNocheck(tc, &ht, ks[0])));
    try testing.expectEqual(e, entryOf(fixkey.lvalueFetchNocheck(tc, &ht, ks[0])));
    try testing.expectEqual(@as(?*anyopaque, null), fixkey.fetchNocheck(tc, &ht, ks[1]));
    try testing.expectEqual(@as(u64, 0), fixkey.fsck(tc, &ht, 0));
}

test "fixkey: entry_size 0 indirects to the caller's static storage" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const n: u32 = 50;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);

    const storage = try testing.allocator.alloc(Entry, n);
    defer testing.allocator.free(storage);

    var ht = unbuilt();
    fixkey.build(tc, &ht, 0);
    defer fixkey.demolish(tc, &ht);
    for (ks, 0..) |k, i| {
        storage[i] = .{ .key = k, .value = i, .extra = 0 };
        // The address of the indirection pointer inside the hash, to assign.
        const slot: *?*Entry = @ptrCast(@alignCast(fixkey.insertNocheck(tc, &ht, k)));
        try testing.expectEqual(@as(?*Entry, null), slot.*);
        slot.* = &storage[i];
    }
    for (ks, 0..) |k, i| try testing.expectEqual(&storage[i], entryOf(fixkey.fetchNocheck(tc, &ht, k)));
    var counter = Counter{};
    fixkey.foreach(tc, &ht, count, &counter);
    try testing.expectEqual(n, counter.seen);
    try testing.expectEqual(@as(u64, 0), fixkey.fsck(tc, &ht, 0));
}
