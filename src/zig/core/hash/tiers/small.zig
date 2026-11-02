//! The Small tier of the Zig hash engine (spec 6.1): a flat array of entries
//! with a parallel array of one-byte hash tags, searched with a vector compare.
//!
//! Block layout (one allocation, 8-byte aligned; the table pointer points at
//! the header, which is also the block start):
//!
//!     Header              8 bytes (tier.Header)
//!     capacity: u32       4 bytes, the tier's payload
//!     tags[capacity]      top byte of each entry's hash
//!     padding             up to the next multiple of 8
//!     entries[capacity]   entry_size bytes each, key first
//!
//! Index `i` holds a live entry iff `i < header.cur_items`; insert appends at
//! `cur_items`, delete moves the last entry and tag into the hole. This tier
//! maintains `header.cur_items` in `lvalueFetch` and `delete`; the policy
//! layer reads it. Iteration position of index `i` is `i + 1`, so positions
//! walk downward from `cur_items` to 1, and a delete of the current entry
//! only moves an already visited (higher) entry.
//!
//! Blocks are owned by the policy layer: `init` and `grow` return a new
//! block and never free an old one, so the caller disposes of the old block
//! (`blockStart(old)` for `allocatedSize(old)` bytes) after publishing the
//! new header.
//!
//! An inserted entry has its key bytes zeroed for the caller to fill; lookups
//! skip zero keys without calling `Spec.eql`, and `fsck` skips them without
//! calling `Spec.hash`.
//!
//! `drain` visitor convention: `visitor` is either a function
//! `fn ([*]u8) void` or a value (typically a pointer to a struct) with a
//! method `visit(self, [*]u8) void`; it is called once per live entry in
//! ascending index order.
const std = @import("std");
const Header = @import("../tier.zig").Header;

pub fn Tier(comptime cfg: struct { max_capacity: u32 }) type {
    comptime std.debug.assert(cfg.max_capacity >= 8 and std.math.isPowerOfTwo(cfg.max_capacity));
    return struct {
        pub const max_capacity: u32 = cfg.max_capacity;

        pub fn Impl(comptime Spec: type) type {
            return ImplType(max_capacity, Spec);
        }
    };
}

fn ImplType(comptime max_capacity: u32, comptime Spec: type) type {
    return struct {
        const Key = Spec.Key;
        const Ctx = Spec.Ctx;
        const key_size = @sizeOf(Key);
        const tags_offset = @sizeOf(Header) + @sizeOf(u32);

        pub const LvalueResult = union(enum) { found: [*]u8, inserted: [*]u8, full };

        fn entrySize(header: *const Header) usize {
            return if (Spec.runtime_entry_size) header.entry_size else Spec.entry_size;
        }

        fn entriesOffset(cap: u32) usize {
            return std.mem.alignForward(usize, tags_offset + cap, 8);
        }

        fn blockSize(cap: u32, entry_size: usize) usize {
            return entriesOffset(cap) + cap * entry_size;
        }

        fn capPtr(header: *Header) *u32 {
            return @ptrCast(@alignCast(blockStart(header) + @sizeOf(Header)));
        }

        fn tags(header: *Header) [*]u8 {
            return blockStart(header) + tags_offset;
        }

        fn entryAtIndex(header: *Header, i: u32) [*]u8 {
            return blockStart(header) + entriesOffset(capacity(header)) + i * entrySize(header);
        }

        fn keyAt(entry: [*]u8) Key {
            return std.mem.bytesToValue(Key, entry[0..key_size]);
        }

        fn isZeroKey(entry: [*]u8) bool {
            return std.mem.allEqual(u8, entry[0..key_size], 0);
        }

        fn tagOf(h: u64) u8 {
            return @truncate(h >> 56);
        }

        fn alloc(allocator: std.mem.Allocator, cap: u32, entry_size: usize) !*Header {
            const block = try allocator.alignedAlloc(u8, .@"8", blockSize(cap, entry_size));
            return @ptrCast(block.ptr);
        }

        pub fn init(allocator: std.mem.Allocator, header_init: Header, cap: u32) !*Header {
            std.debug.assert(cap <= max_capacity);
            const rounded = std.math.ceilPowerOfTwoAssert(u32, @max(cap, 8));
            const header = try alloc(allocator, rounded, if (Spec.runtime_entry_size) header_init.entry_size else Spec.entry_size);
            header.* = header_init;
            capPtr(header).* = rounded;
            return header;
        }

        pub fn capacity(header: *Header) u32 {
            return capPtr(header).*;
        }

        pub fn isFull(header: *Header) bool {
            return header.cur_items == capacity(header);
        }

        pub fn hash(ctx: Ctx, key: Key) u64 {
            return Spec.hash(ctx, key);
        }

        /// Index of `key`'s entry, comparing tags `N` at a time.
        fn findIn(comptime N: comptime_int, header: *Header, ctx: Ctx, key: Key, tag: u8) ?u32 {
            const Mask = std.meta.Int(.unsigned, N);
            const t = tags(header);
            const n = header.cur_items;
            var base: u32 = 0;
            while (base < n) : (base += N) {
                const chunk: @Vector(N, u8) = t[base..][0..N].*;
                var mask: Mask = @bitCast(chunk == @as(@Vector(N, u8), @splat(tag)));
                if (n - base < N) mask &= (@as(Mask, 1) << @intCast(n - base)) - 1;
                while (mask != 0) : (mask &= mask - 1) {
                    const i = base + @ctz(mask);
                    const e = entryAtIndex(header, i);
                    if (!isZeroKey(e) and Spec.eql(ctx, keyAt(e), key)) return i;
                }
            }
            return null;
        }

        fn find(header: *Header, ctx: Ctx, key: Key, h: u64) ?u32 {
            const tag = tagOf(h);
            return switch (capacity(header)) {
                8 => findIn(8, header, ctx, key, tag),
                16 => findIn(16, header, ctx, key, tag),
                32 => findIn(32, header, ctx, key, tag),
                else => findIn(64, header, ctx, key, tag),
            };
        }

        pub fn fetch(header: *Header, ctx: Ctx, key: Key, h: u64) ?[*]u8 {
            const i = find(header, ctx, key, h) orelse return null;
            return entryAtIndex(header, i);
        }

        pub fn lvalueFetch(header: *Header, ctx: Ctx, key: Key, h: u64) LvalueResult {
            if (find(header, ctx, key, h)) |i| return .{ .found = entryAtIndex(header, i) };
            if (isFull(header)) return .full;
            const i = header.cur_items;
            tags(header)[i] = tagOf(h);
            const e = entryAtIndex(header, i);
            @memset(e[0..key_size], 0);
            header.cur_items = i + 1;
            return .{ .inserted = e };
        }

        pub fn delete(header: *Header, ctx: Ctx, key: Key, h: u64) bool {
            const i = find(header, ctx, key, h) orelse return false;
            const last = header.cur_items - 1;
            if (i != last) {
                const t = tags(header);
                t[i] = t[last];
                const es = entrySize(header);
                @memcpy(entryAtIndex(header, i)[0..es], entryAtIndex(header, last)[0..es]);
            }
            header.cur_items = last;
            return true;
        }

        /// Doubles into a new block and returns its header, or null at the
        /// ceiling. The old block is left untouched and allocated for the
        /// caller to dispose of through `blockStart(old)` and
        /// `allocatedSize(old)` once the new header is published. `ctx` is
        /// unused here; Robin Hood needs it to rehash on doubling.
        pub fn grow(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !?*Header {
            _ = ctx;
            const cap = capacity(header);
            if (cap >= max_capacity) return null;
            const es = entrySize(header);
            const new = try alloc(allocator, cap * 2, es);
            new.* = header.*;
            capPtr(new).* = cap * 2;
            const n = header.cur_items;
            @memcpy(tags(new)[0..n], tags(header)[0..n]);
            @memcpy(entryAtIndex(new, 0)[0 .. n * es], entryAtIndex(header, 0)[0 .. n * es]);
            return new;
        }

        pub fn first(header: *Header) u32 {
            return header.cur_items;
        }

        pub fn next(header: *Header, pos: u32) u32 {
            _ = header;
            return pos - 1;
        }

        pub fn entryAt(header: *Header, pos: u32) [*]u8 {
            return entryAtIndex(header, pos - 1);
        }

        pub fn start(header: *Header) u32 {
            return header.cur_items + 1;
        }

        pub fn drain(header: *Header, visitor: anytype) void {
            const is_fn = @typeInfo(@TypeOf(visitor)) == .@"fn";
            for (0..header.cur_items) |i| {
                const e = entryAtIndex(header, @intCast(i));
                if (is_fn) visitor(e) else visitor.visit(e);
            }
        }

        pub fn allocatedSize(header: *Header) usize {
            return blockSize(capacity(header), entrySize(header));
        }

        /// Number of inconsistencies: `cur_items` above capacity, and live
        /// entries whose tag does not match their key's hash.
        pub fn fsck(header: *Header, ctx: Ctx, mode: u32) u64 {
            _ = mode;
            var errors: u64 = 0;
            const cap = capacity(header);
            if (header.cur_items > cap) errors += 1;
            const t = tags(header);
            for (0..@min(header.cur_items, cap)) |i| {
                const e = entryAtIndex(header, @intCast(i));
                if (isZeroKey(e)) continue;
                if (t[i] != tagOf(Spec.hash(ctx, keyAt(e)))) errors += 1;
            }
            return errors;
        }

        pub fn blockStart(header: *Header) [*]u8 {
            return @ptrCast(header);
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const IntSpec = @import("../test_spec.zig").IntSpec;
const S = Tier(.{ .max_capacity = 64 }).Impl(IntSpec);
const test_entry_size = 16;

fn testInit(capacity: u32) !*Header {
    return S.init(testing.allocator, .{ .tier = 0, .set = 0, .entry_size = test_entry_size, .stale = 0, .cur_items = 0 }, capacity);
}

fn testFree(header: *Header) void {
    const block: [*]align(8) u8 = @alignCast(S.blockStart(header));
    testing.allocator.free(block[0..S.allocatedSize(header)]);
}

fn keyOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[0..8], .little);
}

/// `grow`, disposing of the old block as the policy layer would.
fn grown(header: *Header) !?*Header {
    const new = (try S.grow(header, {}, testing.allocator)) orelse return null;
    if (new != header) testFree(header);
    return new;
}

/// Insert `key` with value `key * 10`; the key must be absent and fit.
fn put(header: *Header, key: u64) !void {
    switch (S.lvalueFetch(header, {}, key, S.hash({}, key))) {
        .inserted => |e| {
            try testing.expectEqual(@as(u64, 0), keyOf(e));
            std.mem.writeInt(u64, e[0..8], key, .little);
            std.mem.writeInt(u64, e[8..16], key * 10, .little);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn get(header: *Header, key: u64) ?[*]u8 {
    return S.fetch(header, {}, key, S.hash({}, key));
}

fn del(header: *Header, key: u64) bool {
    return S.delete(header, {}, key, S.hash({}, key));
}

test "init at 8, fetch misses on empty, lvalueFetch inserts with a zero key" {
    const h = try testInit(1);
    defer testFree(h);
    try testing.expectEqual(@as(u32, 8), S.capacity(h));
    try testing.expectEqual(@as(?[*]u8, null), get(h, 5));
    const r = S.lvalueFetch(h, {}, 5, S.hash({}, 5));
    try testing.expect(r == .inserted);
    try testing.expectEqual(@as(u64, 0), keyOf(r.inserted));
    std.mem.writeInt(u64, r.inserted[0..8], 5, .little);
    try testing.expectEqual(@as(?[*]u8, r.inserted), get(h, 5));
    try testing.expect(S.lvalueFetch(h, {}, 5, S.hash({}, 5)) == .found);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "fills to capacity then reports full; grow doubles up to the ceiling" {
    var h = try testInit(8);
    defer testFree(h);
    for (1..9) |k| try put(h, k);
    try testing.expect(S.isFull(h));
    try testing.expect(S.lvalueFetch(h, {}, 9, S.hash({}, 9)) == .full);
    try testing.expect(S.lvalueFetch(h, {}, 3, S.hash({}, 3)) == .found);
    h = (try grown(h)).?;
    try testing.expectEqual(@as(u32, 16), S.capacity(h));
    try testing.expect(!S.isFull(h));
    for (1..9) |k| try testing.expectEqual(@as(u64, k * 10), std.mem.readInt(u64, get(h, k).?[8..16], .little));
    try put(h, 9);
    h = (try grown(h)).?;
    h = (try grown(h)).?;
    try testing.expectEqual(@as(u32, 64), S.capacity(h));
    try testing.expectEqual(@as(?*Header, null), try grown(h));
    for (1..10) |k| try testing.expect(get(h, k) != null);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "delete swaps the last entry into the hole and iteration visits every entry once" {
    const h = try testInit(16);
    defer testFree(h);
    for (1..11) |k| try put(h, k);
    try testing.expect(del(h, 3));
    try testing.expect(!del(h, 3));
    try testing.expectEqual(@as(?[*]u8, null), get(h, 3));
    var seen = [_]u32{0} ** 11;
    var n: u32 = 0;
    var pos = S.first(h);
    while (pos != 0) : (pos = S.next(h, pos)) {
        seen[keyOf(S.entryAt(h, pos))] += 1;
        n += 1;
    }
    try testing.expectEqual(@as(u32, 9), n);
    for (seen, 0..) |c, k| try testing.expectEqual(@as(u32, if (k == 0 or k == 3) 0 else 1), c);
    try testing.expectEqual(@as(u32, 10), S.start(h));
}

test "deleting the current entry while holding next keeps the walk correct" {
    const h = try testInit(16);
    defer testFree(h);
    for (1..13) |k| try put(h, k);
    var seen = [_]u32{0} ** 13;
    var pos = S.first(h);
    var i: u32 = 0;
    while (pos != 0) : (i += 1) {
        const nxt = S.next(h, pos);
        const k = keyOf(S.entryAt(h, pos));
        seen[k] += 1;
        if (i % 2 == 0) try testing.expect(del(h, k));
        pos = nxt;
    }
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    try testing.expectEqual(@as(u32, 6), h.cur_items);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "fill, delete all, refill" {
    const h = try testInit(64);
    defer testFree(h);
    for (1..65) |k| try put(h, k);
    for (1..65) |k| try testing.expect(del(h, k));
    try testing.expectEqual(@as(u32, 0), h.cur_items);
    for (1..65) |k| try testing.expectEqual(@as(?[*]u8, null), get(h, k));
    for (101..165) |k| try put(h, k);
    for (101..165) |k| try testing.expectEqual(@as(u64, k), keyOf(get(h, k).?));
    var n: u32 = 0;
    var pos = S.first(h);
    while (pos != 0) : (pos = S.next(h, pos)) n += 1;
    try testing.expectEqual(@as(u32, 64), n);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "tag collisions fall through to key equality" {
    const tagOf = struct {
        fn f(k: u64) u8 {
            return @truncate(IntSpec.hash({}, k) >> 56);
        }
    }.f;
    var a: u64 = 1;
    var b: u64 = 2;
    outer: while (a < 1000) : (a += 1) {
        b = a + 1;
        while (b < 1000) : (b += 1) {
            if (tagOf(a) == tagOf(b)) break :outer;
        }
    }
    try testing.expect(tagOf(a) == tagOf(b) and a != b);
    const h = try testInit(8);
    defer testFree(h);
    try put(h, a);
    try testing.expectEqual(@as(?[*]u8, null), get(h, b));
    try put(h, b);
    try testing.expectEqual(a, keyOf(get(h, a).?));
    try testing.expectEqual(b, keyOf(get(h, b).?));
    try testing.expect(get(h, a).? != get(h, b).?);
    try testing.expect(del(h, a));
    try testing.expectEqual(b, keyOf(get(h, b).?));
    try testing.expectEqual(@as(?[*]u8, null), get(h, a));
}
