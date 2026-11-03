//! The Unicode table of `../uni.zig` driven through its C-shaped API. Runs
//! in the libmoar-linked `hash-str-test` binary (root `../hash_test.zig`):
//! the production Spec allocates through `moar.mvm_allocator`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const uni = @import("../uni.zig");

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

const n: u32 = 2000;

/// The keys: NUL-terminated "prop<n>", living as long as the test binary.
var names: [n][12]u8 = undefined;

fn makeNames() ![n][*c]const u8 {
    var ks: [n][*c]const u8 = undefined;
    for (&names, 0..) |*buf, i| {
        const s = try std.fmt.bufPrintZ(buf, "prop{d}", .{i});
        ks[i] = s.ptr;
    }
    return ks;
}

fn unbuilt() c.MVMUniHashTable {
    return std.mem.zeroes(c.MVMUniHashTable);
}

test "insert 2000 generated C-string keys (\"prop<n>\"), fetch each returns the stored value, a miss returns null" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const ks = try makeNames();

    var ht = unbuilt();
    try testing.expect(uni.isEmpty(tc, &ht));
    try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, ks[0]));
    try testing.expectEqual(@as(u64, 0), uni.fsck(&ht, 0));
    uni.build(tc, &ht, n);
    defer uni.demolish(tc, &ht);
    try testing.expect(ht.table != null);
    try testing.expect(uni.isEmpty(tc, &ht));
    try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, ks[0]));

    for (ks, 0..) |k, i| uni.insert(tc, &ht, k, @as(i32, @intCast(i)) - 1000);
    try testing.expect(!uni.isEmpty(tc, &ht));
    for (ks, 0..) |k, i| {
        const e = uni.fetch(tc, &ht, k) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(k, e.key);
        try testing.expectEqual(@as(i32, @intCast(i)) - 1000, e.value);
        try testing.expectEqual(uni.hashCode(k, std.mem.len(k)), e.hash_val);
    }
    // The same key from another buffer is the same entry (strcmp, not
    // pointer equality); a miss is null.
    var other: [12]u8 = undefined;
    const prop7 = try std.fmt.bufPrintZ(&other, "prop{d}", .{7});
    try testing.expectEqual(uni.fetch(tc, &ht, ks[7]), uni.fetch(tc, &ht, prop7.ptr));
    try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, "prop2000"));
    try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, "nope"));
    try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, ""));
    // Inserting a present key with its value again is a no-op.
    uni.insert(tc, &ht, prop7.ptr, 7 - 1000);
    try testing.expectEqual(ks[7], uni.fetch(tc, &ht, ks[7]).?.key);
    try testing.expectEqual(@as(u64, 0), uni.fsck(&ht, 0));
}

test "insert on an unbuilt table builds it, growing from the minimum size" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    const ks = try makeNames();

    var ht = unbuilt();
    defer uni.demolish(tc, &ht);
    for (ks, 0..) |k, i| uni.insert(tc, &ht, k, @intCast(i));
    try testing.expect(ht.table != null);
    for (ks, 0..) |k, i| try testing.expectEqual(@as(i32, @intCast(i)), uni.fetch(tc, &ht, k).?.value);
    try testing.expectEqual(@as(u64, 0), uni.fsck(&ht, 0));
    uni.demolish(tc, &ht);
    try testing.expect(ht.table == null);
    try testing.expect(uni.isEmpty(tc, &ht));
}

test "hashCode is the C's FNV-1a times the Fibonacci constant" {
    // FNV-1a of "" is the offset basis; "a" is 0xe40c292c; then * 0x9e3779b7.
    try testing.expectEqual(@as(u32, 0x811c9dc5) *% 0x9e3779b7, uni.hashCode("", 0));
    try testing.expectEqual(@as(u32, 0xe40c292c) *% 0x9e3779b7, uni.hashCode("a", 1));
    try testing.expect(uni.hashCode("prop1", 5) != uni.hashCode("prop2", 5));
}

// ------------------------------------------------ the Swiss set (strategy 1)

/// Names for the large tests: "name<i>" in one buffer that lives for the test.
fn bigNames(alloc: std.mem.Allocator, count: usize, prefix: []const u8) ![][*c]const u8 {
    const ks = try alloc.alloc([*c]const u8, count);
    for (ks, 0..) |*k, i| {
        const s = try std.fmt.allocPrintSentinel(alloc, "{s}{d}", .{ prefix, i }, 0);
        k.* = s.ptr;
    }
    return ks;
}

test "widen spreads the tag bits over the property names" {
    const keys = @embedFile("uni_bench_keys");
    var counts = [_]u32{0} ** 128;
    var total: u32 = 0;
    var lines = std.mem.splitScalar(u8, keys, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const kind = cols.next() orelse continue;
        if (!std.mem.eql(u8, kind, "prop") and !std.mem.eql(u8, kind, "alias")) continue;
        const name = cols.next() orelse continue;
        const h = uni.hashCode(name.ptr, name.len);
        counts[@intCast(uni.widen(h) >> 57)] += 1;
        total += 1;
    }
    try testing.expectEqual(@as(u32, 4380), total);
    const mean = total / 128;
    for (counts) |k| {
        try testing.expect(k > 0);
        try testing.expect(k <= 3 * mean);
        try testing.expect(k * 3 >= mean);
    }
}

test "strategy 1 round trip" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ks = try bigNames(arena.allocator(), 70_000, "swiss_name_");
    const misses = try bigNames(arena.allocator(), 10_000, "absent_");

    var ht = unbuilt();
    uni.buildStrategy(tc, &ht, 70_000, 1);
    defer uni.demolish(tc, &ht);
    for (ks, 0..) |k, i| uni.insert(tc, &ht, k, @intCast(i));
    for (ks, 0..) |k, i| try testing.expectEqual(@as(i32, @intCast(i)), (uni.fetch(tc, &ht, k) orelse return error.TestUnexpectedResult).value);
    for (misses) |k| try testing.expectEqual(@as(?*c.MVMUniHashEntry, null), uni.fetch(tc, &ht, k));
    try testing.expectEqual(@as(u64, 0), uni.fsck(&ht, 0));
}

test "strategy 1 grows from an implicit zero start" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *ThreadContext = instance.*.main_thread;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ks = try bigNames(arena.allocator(), 5_000, "grow_");

    var ht = unbuilt();
    uni.buildStrategy(tc, &ht, 0, 1);
    defer uni.demolish(tc, &ht);
    for (ks, 0..) |k, i| uni.insert(tc, &ht, k, @intCast(i));
    for (ks, 0..) |k, i| try testing.expectEqual(@as(i32, @intCast(i)), uni.fetch(tc, &ht, k).?.value);
    try testing.expectEqual(@as(u64, 0), uni.fsck(&ht, 0));
}

test "buildStrategy refuses 2" {
    try testing.expect(uni.strategyAvailable(0));
    try testing.expect(uni.strategyAvailable(1));
    try testing.expect(!uni.strategyAvailable(2));
    try testing.expect(!uni.strategyAvailable(255));
}
