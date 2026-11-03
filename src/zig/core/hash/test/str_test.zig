//! The string table of `../str.zig` driven through its C-shaped API on real
//! `MVMString`s, each test in its own instance, as `src/zig/moar.zig`'s tests
//! are. Runs in the libmoar-linked `hash-str-test` binary, whose root is
//! `../hash_test.zig`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const str = @import("../str.zig");
const keys = @import("keys.zig");
const tier = @import("../tier.zig");
const Header = tier.Header;

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

/// What the tests store: the C's `MVMHashEntry` shape (key first, 16 bytes),
/// with the value word used as a plain number.
const Entry = extern struct {
    key: [*c]c.MVMString,
    value: u64,
};
const entry_size: u32 = @sizeOf(c.MVMHashEntry);

comptime {
    std.debug.assert(@sizeOf(Entry) == entry_size);
}

const Instance = struct {
    instance: *c.MVMInstance,
    tc: *ThreadContext,

    fn create() Instance {
        const instance = c.MVM_vm_create_instance();
        return .{ .instance = instance, .tc = instance.*.main_thread };
    }

    fn destroy(self: Instance) void {
        c.MVM_vm_destroy_instance(self.instance);
    }
};

fn unbuilt() c.MVMStrHashTable {
    return std.mem.zeroes(c.MVMStrHashTable);
}

fn entryOf(p: ?*anyopaque) *Entry {
    return @ptrCast(@alignCast(p.?));
}

/// `lvalueFetchNocheck` of an absent key, filling the key and the value.
fn put(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString, value: u64) !void {
    const e = entryOf(str.lvalueFetchNocheck(tc, ht, key));
    try testing.expectEqual(@as([*c]c.MVMString, null), e.key);
    e.key = key;
    e.value = value;
}

fn valueOf(tc: *ThreadContext, ht: *c.MVMStrHashTable, key: [*c]c.MVMString) !u64 {
    const p = str.fetch(tc, ht, key) orelse return error.TestUnexpectedResult;
    return entryOf(p).value;
}

test "unbuilt, control-only and built states through the C-shaped API" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 1);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    try testing.expectEqual(@as(u32, 0), str.entrySize(tc, &ht));
    try testing.expectEqual(@as(u32, 0), str.count(tc, &ht));
    try testing.expect(str.isEmpty(tc, &ht));
    try testing.expectEqual(@as(usize, 0), str.allocatedSize(tc, &ht));
    try testing.expectEqual(@as(u32, 0), str.first(tc, &ht).pos);
    try testing.expect(str.atEnd(tc, &ht, str.first(tc, &ht)));
    try testing.expect(str.atStart(tc, &ht, str.start(tc, &ht)));
    try testing.expectEqual(@as(?*anyopaque, null), str.current(tc, &ht, str.first(tc, &ht)));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &ht, ks[0]));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetchNocheck(tc, &ht, ks[0]));
    str.deleteNocheck(tc, &ht, ks[0]);
    str.delete(tc, &ht, ks[0]);
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));

    str.build(tc, &ht, entry_size, 0);
    try testing.expect(ht.table != null);
    try testing.expectEqual(entry_size, str.entrySize(tc, &ht));
    try testing.expectEqual(@as(u32, 0), str.count(tc, &ht));
    try testing.expect(str.isEmpty(tc, &ht));
    try testing.expectEqual(@sizeOf(Header), str.allocatedSize(tc, &ht));
    try testing.expectEqual(@as(u32, 0), str.first(tc, &ht).pos);
    try testing.expect(str.atStart(tc, &ht, str.start(tc, &ht)));
    try testing.expectEqual(@as(?*anyopaque, null), str.current(tc, &ht, str.first(tc, &ht)));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &ht, ks[0]));
    str.delete(tc, &ht, ks[0]);
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));

    str.demolish(tc, &ht);
    try testing.expect(ht.table == null);
    try testing.expectEqual(@as(u32, 0), str.entrySize(tc, &ht));
    str.demolish(tc, &ht);

    // A memset(0) body (repossession) reads as unbuilt.
    var zeroed: c.MVMStrHashTable = undefined;
    @memset(std.mem.asBytes(&zeroed), 0);
    try testing.expectEqual(@as(u32, 0), str.entrySize(tc, &zeroed));
    try testing.expect(str.isEmpty(tc, &zeroed));
    try testing.expectEqual(@as(u32, 0), str.first(tc, &zeroed).pos);
}

test "lookup of another key while a fresh entry's key is still null" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 2);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.build(tc, &ht, entry_size, 0);
    defer str.demolish(tc, &ht);

    const e = entryOf(str.lvalueFetchNocheck(tc, &ht, ks[0]));
    try testing.expectEqual(@as([*c]c.MVMString, null), e.key);
    try testing.expectEqual(@as(u32, 1), str.count(tc, &ht));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetchNocheck(tc, &ht, ks[1]));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &ht, ks[1]));
    e.key = ks[0];
    e.value = 42;
    try testing.expectEqual(@as(u64, 42), try valueOf(tc, &ht, ks[0]));
    try testing.expectEqual(@as(*Entry, e), entryOf(str.lvalueFetch(tc, &ht, ks[0])));
    try testing.expectEqual(@as(u32, 1), str.count(tc, &ht));
}

test "insert, fetch, delete and count across the threshold" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const n = str.small_threshold + 10;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.build(tc, &ht, entry_size, 0);
    defer str.demolish(tc, &ht);
    const h = str.handleOf(&ht);

    var rung_changes: u32 = 0;
    var rung = str.StrTable.rung(h);
    for (ks, 0..) |k, i| {
        try put(tc, &ht, k, i);
        const now = str.StrTable.rung(h);
        if (now != rung) {
            rung_changes += 1;
            rung = now;
        }
        try testing.expectEqual(@as(u32, @intCast(i + 1)), str.count(tc, &ht));
    }
    try testing.expectEqual(@as(u32, 1), rung_changes);
    try testing.expectEqual(@as(u8, 1), rung);
    try testing.expectEqual(n, str.count(tc, &ht));
    for (ks, 0..) |k, i| try testing.expectEqual(i, try valueOf(tc, &ht, k));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));

    for (ks, 0..) |k, i| {
        if (i % 2 == 0) str.delete(tc, &ht, k);
    }
    try testing.expectEqual(n / 2, str.count(tc, &ht));
    for (ks, 0..) |k, i| {
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &ht, k));
        } else {
            try testing.expectEqual(i, try valueOf(tc, &ht, k));
        }
    }
    // Deleting an absent key is a no-op, as in C.
    str.deleteNocheck(tc, &ht, ks[0]);
    try testing.expectEqual(n / 2, str.count(tc, &ht));
    try testing.expect(!str.isEmpty(tc, &ht));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));
}

test "insertNocheck of a fresh key returns an entry with the key filled in" {
    // The duplicate path throws an adhoc exception, which is not exercised
    // in-process (there is no handler); Task 14's rakudo build covers
    // deserialize.
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 3);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.build(tc, &ht, entry_size, 3);
    defer str.demolish(tc, &ht);

    for (ks, 0..) |k, i| {
        const e = entryOf(str.insertNocheck(tc, &ht, k));
        // As MVM_str_hash_insert_nocheck: the key is stored for the caller,
        // who fills in the rest.
        try testing.expectEqual(k, e.key);
        e.value = i + 100;
    }
    try testing.expectEqual(@as(u32, 3), str.count(tc, &ht));
    for (ks, 0..) |k, i| try testing.expectEqual(i + 100, try valueOf(tc, &ht, k));
}

test "iteration matches MVMIter's protocol: start, first, delete current while holding next" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;

    for ([_]u32{ 30, 300 }) |n| {
        const ks = try keys.make(tc, n);
        defer testing.allocator.free(ks);
        var ht = unbuilt();
        str.build(tc, &ht, entry_size, 0);
        defer str.demolish(tc, &ht);
        for (ks, 0..) |k, i| try put(tc, &ht, k, i);
        try testing.expectEqual(@as(u8, if (n > str.small_threshold) 1 else 0), str.StrTable.rung(str.handleOf(&ht)));

        const seen = try testing.allocator.alloc(u32, n);
        defer testing.allocator.free(seen);
        @memset(seen, 0);

        // MVMIter: curr = start, next = first; each step moves curr to next
        // and advances next before the body runs, so the body may delete
        // the current entry.
        var curr = str.start(tc, &ht);
        try testing.expect(str.atStart(tc, &ht, curr));
        var next = str.first(tc, &ht);
        try testing.expect(!str.atStart(tc, &ht, next));
        try testing.expectEqual(@as(?*anyopaque, null), str.current(tc, &ht, .{ .pos = 0 }));
        var i: u32 = 0;
        while (true) : (i += 1) {
            curr = next;
            if (str.atEnd(tc, &ht, curr)) break;
            next = str.nextNocheck(tc, &ht, curr);
            const e = entryOf(str.currentNocheck(tc, &ht, curr));
            try testing.expectEqual(@as(*Entry, e), entryOf(str.current(tc, &ht, curr)));
            seen[e.value] += 1;
            if (i % 2 == 0) str.delete(tc, &ht, e.key);
        }
        try testing.expectEqual(n, i);
        for (seen) |s| try testing.expectEqual(@as(u32, 1), s);
        try testing.expectEqual(n / 2, str.count(tc, &ht));
        var remaining: u32 = 0;
        for (ks, 0..) |k, v| {
            if (str.fetch(tc, &ht, k)) |p| {
                try testing.expectEqual(v, entryOf(p).value);
                remaining += 1;
            }
        }
        try testing.expectEqual(n / 2, remaining);
        try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));

        // `next` is the checked variant: it walks the same positions.
        var walked: u32 = 0;
        var it = str.first(tc, &ht);
        while (!str.atEnd(tc, &ht, it)) : (it = str.next(tc, &ht, it)) walked += 1;
        try testing.expectEqual(n / 2, walked);
    }
}

test "migration marks the old block stale and publishes by CAS" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, str.small_threshold + 1);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.build(tc, &ht, entry_size, 0);
    defer str.demolish(tc, &ht);
    const h = str.handleOf(&ht);

    for (ks[0..str.small_threshold], 0..) |k, i| try put(tc, &ht, k, i);
    try testing.expectEqual(@as(u8, 0), str.StrTable.rung(h));
    const old: *Header = h.*.?;
    try testing.expectEqual(@as(u8, 0), old.stale);

    try put(tc, &ht, ks[str.small_threshold], str.small_threshold);
    try testing.expectEqual(@as(u8, 1), str.StrTable.rung(h));
    // The old block is only scheduled for freeing at a safepoint, so its
    // stale byte is readable until the instance is destroyed.
    try testing.expectEqual(@as(u8, 1), old.stale);
    try testing.expect(h.*.? != old);
    try testing.expectEqual(str.small_threshold + 1, str.count(tc, &ht));
    for (ks, 0..) |k, i| try testing.expectEqual(i, try valueOf(tc, &ht, k));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));
}

test "shallow copy of null and control-only tables" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;

    // From an unbuilt source: dest stays unbuilt.
    var none = unbuilt();
    var dest_of_none = unbuilt();
    str.shallowCopy(tc, &none, &dest_of_none);
    try testing.expect(dest_of_none.table == null);

    // From a control-only source: a control-only dest of the same entry size.
    var empty = unbuilt();
    str.build(tc, &empty, entry_size, 0);
    defer str.demolish(tc, &empty);
    var dest_of_empty = unbuilt();
    str.shallowCopy(tc, &empty, &dest_of_empty);
    defer str.demolish(tc, &dest_of_empty);
    try testing.expect(dest_of_empty.table != null);
    try testing.expect(dest_of_empty.table != empty.table);
    try testing.expectEqual(entry_size, str.entrySize(tc, &dest_of_empty));
    try testing.expectEqual(@as(u32, 0), str.count(tc, &dest_of_empty));
    try testing.expectEqual(@sizeOf(Header), str.allocatedSize(tc, &dest_of_empty));
    try testing.expectEqual(@as(u32, 0), str.first(tc, &dest_of_empty).pos);

    // From a 100-entry table: identical iteration order.
    const n: u32 = 100;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);
    var src = unbuilt();
    str.build(tc, &src, entry_size, 0);
    defer str.demolish(tc, &src);
    for (ks, 0..) |k, i| try put(tc, &src, k, i);
    var dst = unbuilt();
    str.shallowCopy(tc, &src, &dst);
    defer str.demolish(tc, &dst);
    try testing.expect(dst.table != src.table);
    try testing.expectEqual(n, str.count(tc, &dst));
    try testing.expectEqual(str.entrySize(tc, &src), str.entrySize(tc, &dst));
    try testing.expectEqual(str.allocatedSize(tc, &src), str.allocatedSize(tc, &dst));
    try testing.expectEqual(str.start(tc, &src).pos, str.start(tc, &dst).pos);

    var sp = str.first(tc, &src);
    var dp = str.first(tc, &dst);
    var walked: u32 = 0;
    while (!str.atEnd(tc, &src, sp)) : ({
        sp = str.nextNocheck(tc, &src, sp);
        dp = str.nextNocheck(tc, &dst, dp);
        walked += 1;
    }) {
        try testing.expectEqual(sp.pos, dp.pos);
        const se = entryOf(str.currentNocheck(tc, &src, sp));
        const de = entryOf(str.currentNocheck(tc, &dst, dp));
        try testing.expect(se != de);
        try testing.expectEqual(se.key, de.key);
        try testing.expectEqual(se.value, de.value);
    }
    try testing.expect(str.atEnd(tc, &dst, dp));
    try testing.expectEqual(n, walked);

    // Independent afterwards.
    str.delete(tc, &dst, ks[0]);
    try testing.expectEqual(n - 1, str.count(tc, &dst));
    try testing.expectEqual(@as(u64, 0), try valueOf(tc, &src, ks[0]));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &dst, 0));
}

test "allocated size is nonzero once built and grows at migration" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, str.small_threshold + 1);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    try testing.expectEqual(@as(usize, 0), str.allocatedSize(tc, &ht));
    str.build(tc, &ht, entry_size, 0);
    defer str.demolish(tc, &ht);
    const control_only = str.allocatedSize(tc, &ht);
    try testing.expectEqual(@sizeOf(Header), control_only);

    try put(tc, &ht, ks[0], 0);
    const first_rung = str.allocatedSize(tc, &ht);
    try testing.expect(first_rung > control_only);
    try testing.expect(first_rung >= @sizeOf(Header) + entry_size);

    for (ks[1..str.small_threshold], 1..) |k, i| try put(tc, &ht, k, i);
    const full_small = str.allocatedSize(tc, &ht);
    try testing.expect(full_small >= first_rung);
    try testing.expect(full_small >= @sizeOf(Header) + str.small_threshold * entry_size);

    try put(tc, &ht, ks[str.small_threshold], str.small_threshold);
    try testing.expectEqual(@as(u8, 1), str.StrTable.rung(str.handleOf(&ht)));
    try testing.expect(str.allocatedSize(tc, &ht) > full_small);

    // A presized table is allocated at once.
    var big = unbuilt();
    str.build(tc, &big, entry_size, 1000);
    defer str.demolish(tc, &big);
    try testing.expectEqual(@as(u8, 1), str.StrTable.rung(str.handleOf(&big)));
    try testing.expect(str.allocatedSize(tc, &big) >= 1000 * entry_size);
}

test "keyIsValid rejects a type object" {
    // The throw itself (keyThrowInvalid) is an adhoc exception with no
    // handler in-process, so it is not exercised here.
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 1);
    defer testing.allocator.free(ks);

    try testing.expect(str.keyIsValid(tc, ks[0]));
    const type_object: [*c]c.MVMString = @ptrCast(tc.instance.*.VMString);
    try testing.expect(!str.keyIsValid(tc, type_object));
    try testing.expect(!str.keyIsValid(tc, null));
    const vm_null: [*c]c.MVMString = @ptrCast(tc.instance.*.VMNull);
    try testing.expect(!str.keyIsValid(tc, vm_null));
    const not_a_string: [*c]c.MVMString = @ptrCast(c.MVM_repr_alloc_init(tc, tc.instance.*.boot_types.BOOTArray));
    try testing.expect(!str.keyIsValid(tc, not_a_string));
}

test "hash of a string equals MVM_string_hash_code and is stable across calls" {
    // `StrSpec.hash` reads the cached hash code itself and computes it only
    // when the cache is empty (0): two fresh strings with the same text, one
    // hashed by the Zig path and one by the C inline, must agree, and the
    // cached second call must return the same value.
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const zig_side = c.MVM_string_ascii_decode_nt(tc, tc.instance.*.VMString, "fresh hash key");
    const c_side = c.MVM_string_ascii_decode_nt(tc, tc.instance.*.VMString, "fresh hash key");
    try testing.expectEqual(@as(u64, 0), zig_side.*.body.cached_hash_code);
    try testing.expectEqual(@as(u64, 0), c_side.*.body.cached_hash_code);

    const first = str.StrSpec.hash(tc, zig_side);
    try testing.expect(first != 0);
    try testing.expectEqual(c.MVM_string_hash_code(tc, c_side), first);
    try testing.expectEqual(first, zig_side.*.body.cached_hash_code);

    try testing.expectEqual(first, str.StrSpec.hash(tc, zig_side));
    try testing.expectEqual(c.MVM_string_hash_code(tc, zig_side), str.StrSpec.hash(tc, zig_side));
}

test "buildStrategy with the default strategy is build" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 1);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.buildStrategy(tc, &ht, 16, 0, 0);
    defer str.demolish(tc, &ht);
    try put(tc, &ht, ks[0], 7);
    try testing.expectEqual(@as(u64, 7), try valueOf(tc, &ht, ks[0]));
    try testing.expectEqual(@as(u32, 1), str.count(tc, &ht));
    const h = str.handleOf(&ht);
    try testing.expectEqual(@as(u8, 0), str.StrTable.rung(h));
    try testing.expectEqual(@as(u8, 0), h.*.?.set);
}

test "buildStrategy refuses strategies that are not built in" {
    // The throw itself (an adhoc exception) has no handler in-process, so
    // the predicate `buildStrategy` checks is tested here; the throw is
    // exercised through MVM_HASH_STRATEGY and the nqp tests.
    try testing.expect(str.strategyAvailable(0));
    try testing.expect(str.strategyAvailable(1));
    for ([_]u8{ 2, 3, 4 }) |s| try testing.expect(!str.strategyAvailable(s));
    try testing.expect(!str.strategyAvailable(255));
}

test "seal on a default table is a no-op" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 3);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.buildStrategy(tc, &ht, entry_size, 0, 0);
    defer str.demolish(tc, &ht);
    for (ks, 0..) |k, i| try put(tc, &ht, k, i);
    str.seal(tc, &ht);
    try testing.expectEqual(@as(u32, 3), str.count(tc, &ht));
    for (ks, 0..) |k, i| try testing.expectEqual(i, try valueOf(tc, &ht, k));
}

test "strategy 1 round trip through the C-shaped API" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const n: u32 = 300;
    const ks = try keys.make(tc, n);
    defer testing.allocator.free(ks);

    var ht = unbuilt();
    str.buildStrategy(tc, &ht, entry_size, 0, 1);
    defer str.demolish(tc, &ht);
    for (ks, 0..) |k, i| try put(tc, &ht, k, i);
    try testing.expectEqual(n, str.count(tc, &ht));
    for (ks, 0..) |k, i| try testing.expectEqual(i, try valueOf(tc, &ht, k));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));

    // Delete the even values, fetch the rest, iterate MVMIter's way.
    for (ks, 0..) |k, i| {
        if (i % 2 == 0) str.delete(tc, &ht, k);
    }
    try testing.expectEqual(n / 2, str.count(tc, &ht));
    for (ks, 0..) |k, i| {
        if (i % 2 == 0) {
            try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &ht, k));
        } else {
            try testing.expectEqual(i, try valueOf(tc, &ht, k));
        }
    }
    const seen = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(seen);
    @memset(seen, 0);
    var curr = str.start(tc, &ht);
    try testing.expect(str.atStart(tc, &ht, curr));
    var next = str.first(tc, &ht);
    var walked: u32 = 0;
    while (true) : (walked += 1) {
        curr = next;
        if (str.atEnd(tc, &ht, curr)) break;
        next = str.nextNocheck(tc, &ht, curr);
        const e = entryOf(str.currentNocheck(tc, &ht, curr));
        try testing.expect(e.value % 2 == 1);
        seen[e.value] += 1;
        // Delete the current entry while holding the next.
        if (walked % 3 == 0) str.delete(tc, &ht, e.key);
    }
    try testing.expectEqual(n / 2, walked);
    for (seen, 0..) |s, i| try testing.expectEqual(@as(u32, if (i % 2 == 1) 1 else 0), s);
    try testing.expectEqual(n / 2 - (n / 2 + 2) / 3, str.count(tc, &ht));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &ht, 0));
}

test "strategy 1 shallow copy is independent" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const n: u32 = 100;
    const ks = try keys.make(tc, n + 1);
    defer testing.allocator.free(ks);

    var src = unbuilt();
    str.buildStrategy(tc, &src, entry_size, 0, 1);
    defer str.demolish(tc, &src);
    for (ks[0..n], 0..) |k, i| try put(tc, &src, k, i);
    var dst = unbuilt();
    str.shallowCopy(tc, &src, &dst);
    defer str.demolish(tc, &dst);
    try testing.expect(dst.table != src.table);
    try testing.expectEqual(str.allocatedSize(tc, &src), str.allocatedSize(tc, &dst));
    try testing.expectEqual(@as(u8, str.swiss_set), str.handleOf(&dst).*.?.set);

    // The same iteration order, entries in the copy's own block.
    var sp = str.first(tc, &src);
    var dp = str.first(tc, &dst);
    while (!str.atEnd(tc, &src, sp)) : ({
        sp = str.nextNocheck(tc, &src, sp);
        dp = str.nextNocheck(tc, &dst, dp);
    }) {
        try testing.expectEqual(sp.pos, dp.pos);
        const se = entryOf(str.currentNocheck(tc, &src, sp));
        const de = entryOf(str.currentNocheck(tc, &dst, dp));
        try testing.expect(se != de);
        try testing.expectEqual(se.key, de.key);
        try testing.expectEqual(se.value, de.value);
    }
    try testing.expect(str.atEnd(tc, &dst, dp));

    // Insert into one: the other is unchanged; then delete from the other.
    try put(tc, &dst, ks[n], n);
    entryOf(str.fetch(tc, &dst, ks[1])).value = 1000;
    try testing.expectEqual(n + 1, str.count(tc, &dst));
    try testing.expectEqual(n, str.count(tc, &src));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &src, ks[n]));
    try testing.expectEqual(@as(u64, 1), try valueOf(tc, &src, ks[1]));
    str.delete(tc, &src, ks[0]);
    try testing.expectEqual(@as(u64, 0), try valueOf(tc, &dst, ks[0]));
    try testing.expectEqual(@as(?*anyopaque, null), str.fetch(tc, &src, ks[0]));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &src, 0));
    try testing.expectEqual(@as(u64, 0), str.fsck(tc, &dst, 0));
}

test "strategy 1 header set byte is the swiss set" {
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 1);
    defer testing.allocator.free(ks);

    try testing.expectEqual(@as(?u8, str.swiss_set), str.strategy_sets[1]);
    try testing.expect(str.sets[str.swiss_set].ptr == @as([*]const tier.TierEntry, &str.swiss_only));
    // Control-only, then materialised, then presized: always the swiss set.
    var ht = unbuilt();
    str.buildStrategy(tc, &ht, entry_size, 0, 1);
    defer str.demolish(tc, &ht);
    const h = str.handleOf(&ht);
    try testing.expectEqual(@as(u8, str.swiss_set), h.*.?.set);
    try put(tc, &ht, ks[0], 7);
    try testing.expectEqual(@as(u8, str.swiss_set), h.*.?.set);
    try testing.expectEqual(@as(u8, 0), str.StrTable.rung(h));
    try testing.expectEqual(@as(u64, 7), try valueOf(tc, &ht, ks[0]));

    var big = unbuilt();
    str.buildStrategy(tc, &big, entry_size, 1000, 1);
    defer str.demolish(tc, &big);
    try testing.expectEqual(@as(u8, str.swiss_set), str.handleOf(&big).*.?.set);
    try testing.expect(str.allocatedSize(tc, &big) >= 1000 * entry_size);
}
