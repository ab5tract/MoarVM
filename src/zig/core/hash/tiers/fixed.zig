//! The fixed-key sealed tier of the Zig hash engine (bake-off candidate 3,
//! `MVM_HASH_STRATEGY_FIXED`): a layout built in one step from a complete
//! key set by `Table.seal`, through `initFrom`, as a hash-ordered dense
//! array with a per-bucket offset table. Nothing else builds it: the tier
//! reports itself full for every absent key and `grow` returns null, so the
//! first insert after seal migrates the table to the next rung of its set
//! (Robin Hood) through the policy layer's ordinary migration.
//!
//! Block layout (one allocation, 8-byte aligned; the table pointer points at
//! the header, which is also the block start; everything else lies at an
//! offset computed from the header's `log2_buckets` and `stored`, so a
//! verbatim copy of the block is a working table):
//!
//!     Control             24 bytes: the engine `Header`, then
//!       salt: u64           the bucket choice's salt (see below)
//!       stored: u32         records in the block, live or tombstoned
//!       log2_buckets: u8    2^log2_buckets buckets, at least `stored`
//!     offsets[buckets+1]  u32 each: bucket b's records are
//!                         [offsets[b], offsets[b+1]); offsets[buckets] is
//!                         `stored`; padded to a multiple of 8 bytes
//!     tombstones          one bit per record (1: deleted), in u64 words
//!     records[stored]     8 + entry_size bytes each: the entry's 64-bit
//!                         (unsalted) `Spec.hash`, then the entry itself,
//!                         key first; in bucket order
//!
//! Entries are 8-byte aligned (the control block, the padded offsets, the
//! tombstone words and the 8-byte hash are all multiples of 8 bytes, and
//! the entry size is a multiple of 8).
//!
//! Buckets: the smallest power of two at least the entry count (1 for no
//! entries), so the expected bucket holds at most one record. A key's bucket
//! is the top `log2_buckets` bits of `(hash ^ salt) * φ` (a Fibonacci
//! multiply, so the salt changes which keys collide; a plain xor would only
//! permute the buckets). The salt is `Spec.salt(ctx)` when the Spec has one
//! (the string table's per-instance salt, as every Robin Hood block gets),
//! else 0. `initFrom` is a counting sort: one pass counts the bucket sizes,
//! a prefix sum turns them into ends, and a second pass places each record
//! at its bucket's next free position from the end; expected linear, no
//! comparisons.
//!
//! A lookup reads the bucket's offset pair (8 adjacent bytes, the one cache
//! line beyond the entry), then for each record of the bucket compares the
//! stored hash, which sits right before the entry, and only on a match the
//! key (`Spec.eql`). With at least as many buckets as entries the bucket is
//! one record long on average.
//!
//! Delete marks the record's tombstone bit, zeroes its entry (no object
//! pointer stays in a dead entry) and decrements `cur_items`; nothing moves
//! and the block is never rebuilt, so `allocatedSize` does not change. A
//! lookup skips a dead record by its zero key, which lies on the entry's own
//! line, without reading the tombstone bits; iteration, `drain` and `fsck`
//! read the bits. `fsck` checks that the two agree.
//!
//! This tier maintains `header.cur_items` in `delete` (and sets it in
//! `initFrom`). Iteration position of record `i` is `i + 1`; `start` is
//! `stored + 1`, `first` the highest live position, and `next` walks down
//! skipping tombstones. Nothing moves an entry, so a delete of the current
//! entry leaves the held next position valid; a held position whose entry
//! was deleted reads as a zeroed entry, never a stale pointer.
//!
//! `insertKnownAbsent` is not provided: it is only ever called on the rung a
//! migration builds, and nothing migrates into this tier. `lvalueFetch` of
//! an absent key reports `.full` and never inserts, so the tier never holds
//! an unfilled (zero-key) entry; `initFrom` must not be given one.
//!
//! Blocks are owned by the policy layer: `init` and `initFrom` return a new
//! block and never free one; `grow` never allocates.
//!
//! `drain` visitor convention: `visitor` is either a function
//! `fn ([*]u8) void` or a value (typically a pointer to a struct) with a
//! method `visit(self, [*]u8) void`; it is called once per live entry in
//! ascending position order.
const std = @import("std");
const Header = @import("../tier.zig").Header;

/// Offsets are `u32` and so are positions, so the bucket count stays below
/// 2^32.
const max_log2_buckets: u8 = 31;

/// 2^64 / φ, the Fibonacci hashing multiplier.
const fib_mult: u64 = 0x9e3779b97f4a7c15;

pub fn Tier(comptime cfg: struct {}) type {
    _ = cfg;
    return struct {
        pub const max_capacity: u32 = std.math.maxInt(u32);

        pub fn Impl(comptime Spec: type) type {
            return ImplType(Spec);
        }
    };
}

/// The control block: the engine `Header` followed by this tier's payload.
const Control = extern struct {
    header: Header,
    salt: u64,
    stored: u32,
    log2_buckets: u8,
    _pad: [3]u8,
};
const control_size = @sizeOf(Control);
comptime {
    std.debug.assert(control_size == 24);
}

/// Bytes of the record's hash, before the entry.
const hash_size = 8;

fn offsetsSize(log2_buckets: u8) usize {
    const n = (@as(usize, 1) << @intCast(log2_buckets)) + 1;
    return std.mem.alignForward(usize, n * @sizeOf(u32), 8);
}

fn tombstonesSize(stored: u32) usize {
    return (@as(usize, stored) + 63) / 64 * 8;
}

/// The smallest `k` with `2^k >= n`.
fn log2For(n: u32) u8 {
    var k: u8 = 0;
    while (k < max_log2_buckets and (@as(u64, 1) << @intCast(k)) < n) k += 1;
    return k;
}

fn ImplType(comptime Spec: type) type {
    return struct {
        const Key = Spec.Key;
        const Ctx = Spec.Ctx;
        const key_size = @sizeOf(Key);
        /// The key's bytes as one unsigned integer, for the zero-key test.
        const KeyBits = std.meta.Int(.unsigned, key_size * 8);

        pub const LvalueResult = union(enum) { found: [*]u8, inserted: [*]u8, full };

        // ------------------------------------------------------ geometry

        fn ctrl(header: *Header) *Control {
            return @ptrCast(@alignCast(header));
        }

        fn entrySize(header: *const Header) usize {
            return if (Spec.runtime_entry_size) header.entry_size else Spec.entry_size;
        }

        fn recordSize(header: *const Header) usize {
            return hash_size + entrySize(header);
        }

        pub fn bucketCount(header: *Header) u32 {
            return @as(u32, 1) << @intCast(ctrl(header).log2_buckets);
        }

        /// Records in the block, live or tombstoned.
        pub fn storedCount(header: *Header) u32 {
            return ctrl(header).stored;
        }

        fn offsets(header: *Header) [*]u32 {
            return @ptrCast(@alignCast(@as([*]u8, @ptrCast(header)) + control_size));
        }

        fn tombstones(header: *Header) [*]u64 {
            return @ptrCast(@alignCast(@as([*]u8, @ptrCast(header)) + control_size + offsetsSize(ctrl(header).log2_buckets)));
        }

        fn records(header: *Header) [*]u8 {
            return @as([*]u8, @ptrCast(tombstones(header))) + tombstonesSize(ctrl(header).stored);
        }

        fn recordAt(header: *Header, i: u32) [*]u8 {
            return records(header) + @as(usize, i) * recordSize(header);
        }

        /// The entry of record `i` (0-based).
        pub fn entryAtIndex(header: *Header, i: u32) [*]u8 {
            return recordAt(header, i) + hash_size;
        }

        pub fn storedHash(header: *Header, i: u32) u64 {
            return std.mem.bytesToValue(u64, recordAt(header, i)[0..hash_size]);
        }

        /// For `fsck`'s tests.
        pub fn setStoredHash(header: *Header, i: u32, h: u64) void {
            @as(*u64, @ptrCast(@alignCast(recordAt(header, i)))).* = h;
        }

        pub fn isTombstone(header: *Header, i: u32) bool {
            return tombstones(header)[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
        }

        pub fn setTombstone(header: *Header, i: u32) void {
            tombstones(header)[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        }

        /// For `fsck`'s tests.
        pub fn clearTombstone(header: *Header, i: u32) void {
            tombstones(header)[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
        }

        fn keyAt(entry: [*]u8) Key {
            return std.mem.bytesToValue(Key, entry[0..key_size]);
        }

        fn isZeroKey(entry: [*]u8) bool {
            return std.mem.bytesToValue(KeyBits, entry[0..key_size]) == 0;
        }

        fn blockSize(stored: u32, log2_buckets: u8, entry_size: usize) usize {
            return control_size + offsetsSize(log2_buckets) + tombstonesSize(stored) + @as(usize, stored) * (hash_size + entry_size);
        }

        pub fn blockStart(header: *Header) [*]u8 {
            return @ptrCast(header);
        }

        pub fn allocatedSize(header: *Header) usize {
            return blockSize(ctrl(header).stored, ctrl(header).log2_buckets, entrySize(header));
        }

        pub fn salt(header: *Header) u64 {
            return ctrl(header).salt;
        }

        pub fn hash(ctx: Ctx, key: Key) u64 {
            return Spec.hash(ctx, key);
        }

        fn bucketOf(header: *Header, h: u64) u32 {
            const k = ctrl(header).log2_buckets;
            if (k == 0) return 0;
            return @intCast(((h ^ ctrl(header).salt) *% fib_mult) >> @intCast(64 - @as(u32, k)));
        }

        // ------------------------------------------------- allocation

        /// A zeroed block for `stored` records with its control filled in.
        fn allocate(allocator: std.mem.Allocator, header_init: Header, stored: u32, salt_value: u64) !*Header {
            const entry_size = if (Spec.runtime_entry_size) header_init.entry_size else Spec.entry_size;
            std.debug.assert(entry_size != 0 and entry_size % 8 == 0);
            const log2 = log2For(stored);
            if ((@as(u64, 1) << @intCast(log2)) < stored) return error.OutOfMemory;
            const block = try allocator.alignedAlloc(u8, .@"8", blockSize(stored, log2, entry_size));
            @memset(block, 0);
            const header: *Header = @ptrCast(block.ptr);
            ctrl(header).* = .{
                .header = header_init,
                .salt = salt_value,
                .stored = stored,
                .log2_buckets = log2,
                ._pad = @splat(0),
            };
            header.cur_items = 0;
            return header;
        }

        /// An empty sealed block (the contract's `init`; nothing but a
        /// direct build of this rung calls it, which no set does).
        pub fn init(allocator: std.mem.Allocator, header_init: Header, cap: u32) !*Header {
            _ = cap;
            return allocate(allocator, header_init, 0, 0);
        }

        /// The sealed block holding copies of `entries` (each `entry_size`
        /// bytes, key first, none with a zero key, keys distinct), salted by
        /// `Spec.salt(ctx)` when the Spec has one. `cur_items` is set to
        /// `entries.len`, whatever `header_init` says.
        pub fn initFrom(allocator: std.mem.Allocator, header_init: Header, ctx: Ctx, entries: []const [*]u8) !*Header {
            if (entries.len > std.math.maxInt(u32)) return error.OutOfMemory;
            const n: u32 = @intCast(entries.len);
            const salt_value: u64 = if (@hasDecl(Spec, "salt")) Spec.salt(ctx) else 0;
            const header = try allocate(allocator, header_init, n, salt_value);
            const off = offsets(header);
            const buckets = bucketCount(header);
            const es = entrySize(header);
            // Count: off[b] is bucket b's size.
            for (entries) |e| {
                std.debug.assert(!isZeroKey(e));
                off[bucketOf(header, Spec.hash(ctx, keyAt(e)))] += 1;
            }
            // Prefix sum: off[b] is bucket b's end.
            var sum: u32 = 0;
            for (0..buckets) |b| {
                sum += off[b];
                off[b] = sum;
            }
            off[buckets] = n;
            // Place from each bucket's end: off[b] ends as its start.
            for (entries) |e| {
                const h = Spec.hash(ctx, keyAt(e));
                const b = bucketOf(header, h);
                off[b] -= 1;
                const i = off[b];
                setStoredHash(header, i, h);
                @memcpy(entryAtIndex(header, i)[0..es], e[0..es]);
            }
            header.cur_items = n;
            return header;
        }

        /// Always: every absent key reports `.full`.
        pub fn isFull(header: *Header) bool {
            _ = header;
            return true;
        }

        // ---------------------------------------------------- lookups

        pub fn fetch(header: *Header, ctx: Ctx, key: Key, h: u64) ?[*]u8 {
            const off = offsets(header);
            const b = bucketOf(header, h);
            var i = off[b];
            const end = off[b + 1];
            while (i < end) : (i += 1) {
                if (storedHash(header, i) != h) continue;
                const e = entryAtIndex(header, i);
                // A tombstone's entry is zeroed.
                if (isZeroKey(e)) continue;
                if (Spec.eql(ctx, keyAt(e), key)) return e;
            }
            return null;
        }

        /// A present key is found; an absent one reports `.full`, so the
        /// policy layer migrates to the next rung.
        pub fn lvalueFetch(header: *Header, ctx: Ctx, key: Key, h: u64) LvalueResult {
            if (fetch(header, ctx, key, h)) |e| return .{ .found = e };
            return .full;
        }

        /// Marks the record's tombstone, zeroes its entry, drops the count.
        pub fn delete(header: *Header, ctx: Ctx, key: Key, h: u64) bool {
            const e = fetch(header, ctx, key, h) orelse return false;
            const i: u32 = @intCast((@intFromPtr(e) - @intFromPtr(records(header)) - hash_size) / recordSize(header));
            setTombstone(header, i);
            @memset(e[0..entrySize(header)], 0);
            header.cur_items -= 1;
            return true;
        }

        /// Never grows: null sends the policy layer to the next rung.
        pub fn grow(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !?*Header {
            _ = header;
            _ = ctx;
            _ = allocator;
            return null;
        }

        // -------------------------------------------------- iteration

        pub fn first(header: *Header) u32 {
            if (header.cur_items == 0) return 0;
            return next(header, start(header));
        }

        /// The live position below `pos` (`pos` is not 0), or 0.
        pub fn next(header: *Header, pos: u32) u32 {
            var i = @min(pos - 1, ctrl(header).stored);
            while (i > 0) {
                i -= 1;
                if (!isTombstone(header, i)) return i + 1;
            }
            return 0;
        }

        /// The entry at `pos`; a tombstone's (a position held across an
        /// unsupported delete) is a zeroed entry.
        pub fn entryAt(header: *Header, pos: u32) [*]u8 {
            std.debug.assert(pos >= 1 and pos <= ctrl(header).stored);
            return entryAtIndex(header, pos - 1);
        }

        /// One past the highest position.
        pub fn start(header: *Header) u32 {
            return ctrl(header).stored + 1;
        }

        pub fn drain(header: *Header, visitor: anytype) void {
            const is_fn = @typeInfo(@TypeOf(visitor)) == .@"fn";
            var i: u32 = 0;
            while (i < ctrl(header).stored) : (i += 1) {
                if (isTombstone(header, i)) continue;
                const e = entryAtIndex(header, i);
                if (is_fn) visitor(e) else visitor.visit(e);
            }
        }

        // ------------------------------------------------------- fsck

        /// Counts: a bucket count below the records; offsets that are not
        /// monotone or do not end at `stored`; live records other than
        /// `cur_items`; live records with a zero key, a stored hash other
        /// than the key's, a bucket other than the one they lie in, or that
        /// a lookup of their key does not reach; tombstones whose entry is
        /// not zeroed.
        pub fn fsck(header: *Header, ctx: Ctx, mode: u32) u64 {
            _ = mode;
            const stored = ctrl(header).stored;
            const buckets = bucketCount(header);
            if (buckets < stored) return 1;
            const off = offsets(header);
            if (off[0] != 0 or off[buckets] != stored) return 1;
            for (0..buckets) |b| {
                if (off[b] > off[b + 1]) return 1;
            }
            var errors: u64 = 0;
            var live: u64 = 0;
            for (0..buckets) |b| {
                var i = off[b];
                while (i < off[b + 1]) : (i += 1) {
                    const e = entryAtIndex(header, i);
                    if (isTombstone(header, i)) {
                        if (!std.mem.allEqual(u8, e[0..entrySize(header)], 0)) errors += 1;
                        continue;
                    }
                    live += 1;
                    if (isZeroKey(e)) {
                        errors += 1;
                        continue;
                    }
                    const h = Spec.hash(ctx, keyAt(e));
                    if (storedHash(header, i) != h or bucketOf(header, h) != b) {
                        errors += 1;
                        continue;
                    }
                    if (fetch(header, ctx, keyAt(e), h) != e) errors += 1;
                }
            }
            if (live != header.cur_items) errors += 1;
            return errors;
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_spec = @import("../test_spec.zig");
const FixedSpec = test_spec.FixedSpec;
const S = Tier(.{}).Impl(FixedSpec);
const T = @import("../table.zig").Table(FixedSpec);
const test_entry_size = 16;

fn keyOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[0..8], .little);
}

fn valueOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[8..16], .little);
}

fn fill(entry: [*]u8, key: u64) !void {
    try testing.expectEqual(@as(u64, 0), keyOf(entry));
    std.mem.writeInt(u64, entry[0..8], key, .little);
    std.mem.writeInt(u64, entry[8..16], key * 10, .little);
}

/// Insert `key` with value `key * 10` through the policy layer.
fn tput(h: T.Handle, key: u64) !void {
    try fill(T.insert({}, h, key), key);
}

/// A staging table holding keys `1..n`, sealed.
fn sealedWith(h: T.Handle, n: u64) !void {
    T.build({}, h, test_entry_size, 0, FixedSpec.staging_set);
    for (1..n + 1) |k| try tput(h, k);
    T.seal({}, h, FixedSpec.sealed_set);
    try testing.expectEqual(FixedSpec.sealed_set, h.*.?.set);
    try testing.expectEqual(@as(u8, 0), T.rung(h));
}

fn countByIteration(h: T.Handle) u32 {
    var n: u32 = 0;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) n += 1;
    return n;
}

fn isZeroed(e: [*]u8) bool {
    return std.mem.allEqual(u8, e[0..test_entry_size], 0);
}

test "a sealed block is full for absent keys and finds present ones" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 100);
    defer T.demolish({}, h);
    const header = slot.?;
    try testing.expect(S.isFull(header));
    try testing.expect(S.lvalueFetch(header, {}, 7, S.hash({}, 7)) == .found);
    try testing.expect(S.lvalueFetch(header, {}, 1000, S.hash({}, 1000)) == .full);
    try testing.expectEqual(@as(?*Header, null), try S.grow(header, {}, testing.allocator));
    // The salt comes from the Spec; the bucket count covers the entries.
    try testing.expectEqual(FixedSpec.salt({}), S.salt(header));
    try testing.expect(S.bucketCount(header) >= 100);
    try testing.expectEqual(@as(u32, 100), S.storedCount(header));
}

test "insert after seal migrates to Robin Hood and keeps every entry" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 500);
    defer T.demolish({}, h);
    const sealed = slot.?;
    // An existing key is found in place, without a migration.
    try testing.expectEqual(@as(u64, 70), valueOf(T.lvalueFetch({}, h, 7)));
    try testing.expectEqual(sealed, slot.?);
    try tput(h, 501);
    try testing.expect(slot.? != sealed);
    try testing.expectEqual(FixedSpec.sealed_set, slot.?.set);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    try testing.expectEqual(@as(u32, 501), T.count(h));
    var seen = [_]u32{0} ** 502;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) seen[keyOf(T.current(h, pos).?)] += 1;
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    for (1..502) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "delete after seal is a tombstone" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 100);
    defer T.demolish({}, h);
    const sealed = slot.?;
    const size = T.allocatedSize(h);
    for (1..11) |k| try testing.expect(T.delete({}, h, k));
    try testing.expect(!T.delete({}, h, 1));
    try testing.expectEqual(sealed, slot.?);
    try testing.expectEqual(size, T.allocatedSize(h));
    try testing.expectEqual(@as(u32, 90), T.count(h));
    try testing.expectEqual(@as(u32, 100), S.storedCount(sealed));
    for (1..11) |k| try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, k));
    for (11..101) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(u32, 90), countByIteration(h));
    // Each tombstone's entry is zeroed: no object pointer stays behind.
    var tombs: u32 = 0;
    var i: u32 = 0;
    while (i < S.storedCount(sealed)) : (i += 1) {
        if (S.isTombstone(sealed, i)) {
            tombs += 1;
            try testing.expect(isZeroed(S.entryAtIndex(sealed, i)));
        }
    }
    try testing.expectEqual(@as(u32, 10), tombs);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "delete current while iterating a sealed table visits every entry once" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 300);
    defer T.demolish({}, h);
    var seen = [_]u32{0} ** 301;
    var pos = T.first(h);
    var i: u32 = 0;
    var last_pos: u32 = std.math.maxInt(u32);
    while (pos != 0) : (i += 1) {
        // Descending positions.
        try testing.expect(pos < last_pos);
        last_pos = pos;
        const nxt = T.next(h, pos);
        const k = keyOf(T.current(h, pos).?);
        seen[k] += 1;
        if (i % 2 == 0) try testing.expect(T.delete({}, h, k));
        pos = nxt;
    }
    try testing.expectEqual(@as(u32, 300), i);
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    try testing.expectEqual(@as(u32, 150), T.count(h));
    try testing.expectEqual(@as(u32, 150), countByIteration(h));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "delete then insert after seal" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 100);
    defer T.demolish({}, h);
    for (1..11) |k| try testing.expect(T.delete({}, h, k));
    for (1001..1006) |k| try tput(h, k);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    try testing.expectEqual(@as(u32, 95), T.count(h));
    try testing.expectEqual(@as(u32, 95), countByIteration(h));
    for (1..11) |k| try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, k));
    for (11..101) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
    for (1001..1006) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

/// The key range of the random ops: 1..key_limit-1 (0 is the unfilled key).
const key_limit = 4_096;

/// Every key of the range fetches as the model says, with its value, and
/// iteration visits exactly the model's keys, each once.
fn matchesModel(h: T.Handle, model: *const std.AutoHashMap(u64, void)) !void {
    try testing.expectEqual(model.count(), T.count(h));
    for (1..key_limit) |k| {
        const e = T.fetch({}, h, k);
        try testing.expectEqual(model.contains(k), e != null);
        if (e) |p| try testing.expectEqual(k * 10, valueOf(p));
    }
    var seen = std.StaticBitSet(key_limit).initEmpty();
    var walked: u32 = 0;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) {
        const key = keyOf(T.current(h, pos).?);
        try testing.expect(model.contains(key));
        try testing.expect(!seen.isSet(key));
        seen.set(key);
        walked += 1;
    }
    try testing.expectEqual(model.count(), walked);
}

/// Seals 2_000 random keys, then 10_000 random fetches, deletes and
/// inserts, the whole table compared with `std.AutoHashMap` after every
/// operation. The first insert of an absent key ends the sealed phase; the
/// rest run on the migrated table.
fn randomOpsAfterSeal(h: T.Handle) !void {
    var prng = std.Random.DefaultPrng.init(0x5ea1);
    const rand = prng.random();
    var model = std.AutoHashMap(u64, void).init(testing.allocator);
    defer model.deinit();
    T.build({}, h, test_entry_size, 0, FixedSpec.staging_set);
    while (model.count() < 2_000) {
        const key = rand.intRangeLessThan(u64, 1, key_limit);
        if (model.contains(key)) continue;
        try tput(h, key);
        try model.put(key, {});
    }
    T.seal({}, h, FixedSpec.sealed_set);
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    try matchesModel(h, &model);
    var sealed_ops: u32 = 0;
    for (0..10_000) |_| {
        const key = rand.intRangeLessThan(u64, 1, key_limit);
        // Mostly fetches and deletes while sealed; an insert now and then.
        switch (rand.uintLessThan(u8, 16)) {
            0 => {
                const e = T.lvalueFetch({}, h, key);
                if (model.contains(key)) {
                    try testing.expectEqual(key, keyOf(e));
                    try testing.expectEqual(key * 10, valueOf(e));
                } else {
                    try fill(e, key);
                    try model.put(key, {});
                }
            },
            1...7 => try testing.expectEqual(model.remove(key), T.delete({}, h, key)),
            else => {
                const e = T.fetch({}, h, key);
                try testing.expectEqual(model.contains(key), e != null);
                if (e) |p| try testing.expectEqual(key * 10, valueOf(p));
            },
        }
        if (T.rung(h) == 0) sealed_ops += 1;
        try matchesModel(h, &model);
    }
    // Both phases ran.
    try testing.expect(sealed_ops > 0);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
}

test "random ops after seal match std.AutoHashMap" {
    var slot: ?*Header = null;
    const h = &slot;
    defer T.demolish({}, h);
    try randomOpsAfterSeal(h);
}

test "fsck finds no fault" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 1000);
    defer T.demolish({}, h);
    for (1..1001) |k| {
        if (k % 7 == 0) try testing.expect(T.delete({}, h, k));
    }
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));

    const header = slot.?;
    // A wrong stored hash, a live entry zeroed without its tombstone, a
    // tombstone on a live entry, and a lost count are each found.
    const saved_hash = S.storedHash(header, 3);
    S.setStoredHash(header, 3, saved_hash +% 1);
    try testing.expect(T.fsck({}, h, 0) > 0);
    S.setStoredHash(header, 3, saved_hash);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    var j: u32 = 0;
    while (S.isTombstone(header, j)) j += 1;
    const live = S.entryAtIndex(header, j);
    const saved: [test_entry_size]u8 = live[0..test_entry_size].*;
    @memset(live[0..test_entry_size], 0);
    try testing.expect(T.fsck({}, h, 0) > 0);
    live[0..test_entry_size].* = saved;
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    S.setTombstone(header, j);
    try testing.expect(T.fsck({}, h, 0) > 0);
    S.clearTombstone(header, j);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    header.cur_items += 1;
    try testing.expect(T.fsck({}, h, 0) > 0);
    header.cur_items -= 1;
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));

    // After the migration out of the sealed rung.
    try tput(h, 5000);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "a verbatim block copy of a sealed table is an independent table" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 300);
    defer T.demolish({}, h);
    for (1..11) |k| try testing.expect(T.delete({}, h, k));
    var copy_slot: ?*Header = null;
    const c = &copy_slot;
    T.shallowCopy({}, h, c);
    defer T.demolish({}, c);
    try testing.expectEqual(@as(u8, 0), T.rung(c));
    try testing.expectEqual(T.allocatedSize(h), T.allocatedSize(c));
    const block = S.blockStart(copy_slot.?);
    const size = T.allocatedSize(c);
    for (11..301) |k| {
        const p = T.fetch({}, c, k).?;
        try testing.expectEqual(@as(u64, k * 10), valueOf(p));
        // Every entry of the copy lies inside the copy's block.
        try testing.expect(@intFromPtr(p) >= @intFromPtr(block) and @intFromPtr(p) < @intFromPtr(block) + size);
    }
    try testing.expect(T.delete({}, c, 20));
    try tput(c, 1000);
    try testing.expectEqual(@as(u8, 1), T.rung(c));
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, 1000));
    try testing.expectEqual(@as(u64, 200), valueOf(T.fetch({}, h, 20).?));
    try testing.expectEqual(@as(u32, 290), T.count(h));
    try testing.expectEqual(@as(u32, 290), T.count(c));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, c, 0));
}

test "drain visits the live entries in ascending order" {
    var slot: ?*Header = null;
    const h = &slot;
    try sealedWith(h, 64);
    defer T.demolish({}, h);
    for (1..5) |k| try testing.expect(T.delete({}, h, k));
    var visits: u32 = 0;
    const Counter = struct {
        n: *u32,
        last: usize = 0,
        fn visit(self: *@This(), e: [*]u8) void {
            std.debug.assert(@intFromPtr(e) > self.last);
            std.debug.assert(keyOf(e) > 4);
            self.last = @intFromPtr(e);
            self.n.* += 1;
        }
    };
    var counter = Counter{ .n = &visits };
    S.drain(slot.?, &counter);
    try testing.expectEqual(@as(u32, 60), visits);
}
