//! The Swiss-style tier of the Zig hash engine (the LOOKUP strategy,
//! `MVM_HASH_STRATEGY_LOOKUP`; docs/hash-strategies.md): open addressing over 16-slot groups, with a
//! one-byte metadata array searched a group at a time by vector compares, in
//! the manner of Abseil's SwissTable and Rust's hashbrown.
//!
//! Block layout (one allocation, 8-byte aligned; the table pointer points at
//! the header, which is also the block start; everything else lies at an
//! offset computed from the header's `log2_slots`, so a verbatim copy of the
//! block is a working table):
//!
//!     Control             32 bytes: the engine `Header`, then
//!       salt: u64           xored into every hash
//!       deleted: u32        tombstones currently in the metadata
//!       log2_slots: u8      the slot count is 2^log2_slots, at least 16
//!     metadata[slots]     one byte per slot: 0x80 empty, 0xFE deleted,
//!                         0x00..0x7F a live entry, the top 7 bits of its
//!                         (salted) hash
//!     entries[slots]      entry_size bytes each, key first
//!
//! Probing: the slots form `slots / 16` aligned groups. A key's home group is
//! the low bits of its salted hash; the probe visits groups at triangular
//! offsets from it (+1, +3, +6, ...), which reach every group of a
//! power-of-two count. A lookup compares a whole group's metadata with the
//! key's tag and stops at the first group holding an empty slot; an insert
//! takes the first empty or deleted slot on the same path.
//!
//! Load: a block is full when live entries plus tombstones reach 7/8 of the
//! slots, so an empty slot always remains and every probe ends. A delete
//! leaves an empty slot rather than a tombstone when its group still holds
//! an empty slot: no probe ever passed through such a group, because a group
//! only regains an empty slot from a delete that already finds one there.
//! `grow` of a full block rehashes at the same size, dropping the
//! tombstones, when the live entries are at most 3/4 of the load limit
//! (about 66% of the slots, so the rehashed block has at least a quarter of
//! its limit free and the rehash cost is amortised), and doubles otherwise.
//! An insert into a full block still succeeds when its probe meets a
//! tombstone first (the occupancy does not change).
//!
//! This tier maintains `header.cur_items` in `lvalueFetch`, `delete` and
//! `insertKnownAbsent`. Iteration position of slot `i` is `i + 1`; `first`
//! is the highest live slot and `next` walks down, skipping empty and
//! deleted slots. Nothing ever moves an entry except `grow`, so a delete of
//! the current entry leaves the held next position valid.
//!
//! Blocks are owned by the policy layer: `init` and `grow` return a new
//! block and never free an old one, so the caller disposes of the old block
//! (`blockStart(old)` for `allocatedSize(old)` bytes) after publishing the
//! new header.
//!
//! An inserted entry has its key bytes zeroed for the caller to fill;
//! lookups skip zero keys without calling `Spec.eql`, `grow` drops them (as
//! Robin Hood's does), and `fsck` counts them as errors.
//!
//! `drain` visitor convention: `visitor` is either a function
//! `fn ([*]u8) void` or a value (typically a pointer to a struct) with a
//! method `visit(self, [*]u8) void`; it is called once per live entry in
//! ascending slot order.
const std = @import("std");
const Header = @import("../tier.zig").Header;

/// Slots per group: one `@Vector(16, u8)` of metadata.
const group_size: u32 = 16;
const Group = @Vector(group_size, u8);
const Mask = u16;

/// Metadata of an empty slot.
const empty: u8 = 0x80;
/// Metadata of a deleted slot (a tombstone).
const deleted: u8 = 0xFE;

/// The smallest block: one group.
const min_log2_slots: u8 = 4;
/// Positions are `u32` slot + 1, so the slot count stays below 2^32.
const max_log2_slots: u8 = 31;

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
    deleted: u32,
    log2_slots: u8,
    _pad: [11]u8,
};
const control_size = @sizeOf(Control);
comptime {
    std.debug.assert(control_size == @sizeOf(Header) + 24);
}

/// The live entries a block of `slots` slots holds: 7/8 of them.
fn loadLimit(slots: u32) u32 {
    return slots - slots / 8;
}

/// The bits of `n` low positions (1 <= n <= 16).
fn maskBelow(n: u32) Mask {
    return @truncate((@as(u32, 1) << @intCast(n)) - 1);
}

fn matchByte(g: Group, byte: u8) Mask {
    return @bitCast(g == @as(Group, @splat(byte)));
}

/// Empty or deleted slots (the high bit set).
fn matchFree(g: Group) Mask {
    return @bitCast(g >= @as(Group, @splat(empty)));
}

/// Live slots (the high bit clear).
fn matchLive(g: Group) Mask {
    return @bitCast(g < @as(Group, @splat(empty)));
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

        pub fn slotCount(header: *Header) u32 {
            return @as(u32, 1) << @intCast(ctrl(header).log2_slots);
        }

        fn metadata(header: *Header) [*]u8 {
            return @as([*]u8, @ptrCast(header)) + control_size;
        }

        fn entries(header: *Header) [*]u8 {
            return metadata(header) + slotCount(header);
        }

        fn entryAtIndex(header: *Header, i: u32) [*]u8 {
            return entries(header) + @as(usize, i) * entrySize(header);
        }

        fn loadGroup(md: [*]const u8, g: u32) Group {
            return md[@as(usize, g) * group_size ..][0..group_size].*;
        }

        fn keyAt(entry: [*]u8) Key {
            return std.mem.bytesToValue(Key, entry[0..key_size]);
        }

        fn isZeroKey(entry: [*]u8) bool {
            return std.mem.bytesToValue(KeyBits, entry[0..key_size]) == 0;
        }

        inline fn copyEntry(dest: [*]u8, src: [*]const u8, entry_size: usize) void {
            if (entry_size == 16) dest[0..16].* = src[0..16].* else @memcpy(dest[0..entry_size], src[0..entry_size]);
        }

        fn blockSize(log2_slots: u8, entry_size: usize) usize {
            const slots = @as(usize, 1) << @intCast(log2_slots);
            return control_size + slots + slots * entry_size;
        }

        pub fn blockStart(header: *Header) [*]u8 {
            return @ptrCast(header);
        }

        pub fn allocatedSize(header: *Header) usize {
            return blockSize(ctrl(header).log2_slots, entrySize(header));
        }

        // ------------------------------------------------- allocation

        fn allocate(allocator: std.mem.Allocator, header_init: Header, log2_slots: u8) !*Header {
            const entry_size = if (Spec.runtime_entry_size) header_init.entry_size else Spec.entry_size;
            std.debug.assert(entry_size != 0 and entry_size % 8 == 0);
            if (log2_slots > max_log2_slots) return error.OutOfMemory;
            const block = try allocator.alignedAlloc(u8, .@"8", blockSize(log2_slots, entry_size));
            const header: *Header = @ptrCast(block.ptr);
            const c = ctrl(header);
            c.* = .{ .header = header_init, .salt = 0, .deleted = 0, .log2_slots = log2_slots, ._pad = @splat(0) };
            header.cur_items = 0;
            @memset(metadata(header)[0..slotCount(header)], empty);
            return header;
        }

        /// The smallest block (at least one group) whose load limit holds
        /// `cap` entries.
        pub fn init(allocator: std.mem.Allocator, header_init: Header, cap: u32) !*Header {
            var log2: u8 = min_log2_slots;
            while (log2 < max_log2_slots and loadLimit(@as(u32, 1) << @intCast(log2)) < cap) log2 += 1;
            return allocate(allocator, header_init, log2);
        }

        /// The load limit: live entries the block holds without tombstones.
        pub fn capacity(header: *Header) u32 {
            return loadLimit(slotCount(header));
        }

        /// Live entries plus tombstones at the load limit.
        pub fn isFull(header: *Header) bool {
            return header.cur_items + ctrl(header).deleted >= capacity(header);
        }

        pub fn setSalt(header: *Header, value: u64) void {
            ctrl(header).salt = value;
        }

        pub fn salt(header: *Header) u64 {
            return ctrl(header).salt;
        }

        pub fn hash(ctx: Ctx, key: Key) u64 {
            return Spec.hash(ctx, key);
        }

        // ---------------------------------------------------- probing

        fn tagOf(salted: u64) u8 {
            return @intCast(salted >> 57);
        }

        /// The group a probe for hash `h` starts at.
        fn homeGroup(header: *Header, h: u64) u32 {
            const groups = slotCount(header) / group_size;
            return @as(u32, @truncate(h ^ ctrl(header).salt)) & (groups - 1);
        }

        const Probe = struct {
            group: u32,
            stride: u32 = 0,
            group_mask: u32,

            fn init(header: *Header, salted: u64) Probe {
                const group_mask = slotCount(header) / group_size - 1;
                return .{ .group = @as(u32, @truncate(salted)) & group_mask, .group_mask = group_mask };
            }

            fn advance(p: *Probe) void {
                p.stride += 1;
                p.group = (p.group + p.stride) & p.group_mask;
            }
        };

        /// The slot of `key`'s entry, or null.
        inline fn find(header: *Header, ctx: Ctx, key: Key, salted: u64) ?u32 {
            const md = metadata(header);
            const tag = tagOf(salted);
            const base = entries(header);
            const es = entrySize(header);
            var p = Probe.init(header, salted);
            while (true) : (p.advance()) {
                const g = loadGroup(md, p.group);
                var m = matchByte(g, tag);
                while (m != 0) : (m &= m - 1) {
                    const slot = p.group * group_size + @ctz(m);
                    const e = base + @as(usize, slot) * es;
                    if (!isZeroKey(e) and Spec.eql(ctx, keyAt(e), key)) return slot;
                }
                if (matchByte(g, empty) != 0) return null;
            }
        }

        /// The first empty or deleted slot on the probe path of `salted`.
        fn freeSlot(header: *Header, salted: u64) u32 {
            const md = metadata(header);
            var p = Probe.init(header, salted);
            while (true) : (p.advance()) {
                const m = matchFree(loadGroup(md, p.group));
                if (m != 0) return p.group * group_size + @ctz(m);
            }
        }

        /// Writes the metadata of a new entry at `slot` and counts it.
        fn occupy(header: *Header, slot: u32, salted: u64) void {
            const md = metadata(header);
            if (md[slot] == deleted) ctrl(header).deleted -= 1;
            md[slot] = tagOf(salted);
            header.cur_items += 1;
        }

        pub fn fetch(header: *Header, ctx: Ctx, key: Key, h: u64) ?[*]u8 {
            if (header.cur_items == 0) return null;
            const slot = find(header, ctx, key, h ^ ctrl(header).salt) orelse return null;
            return entryAtIndex(header, slot);
        }

        /// Find or insert in one probe: the first free slot met on the way
        /// is where an absent key goes. Full only for an absent key whose
        /// slot would be an empty one.
        pub fn lvalueFetch(header: *Header, ctx: Ctx, key: Key, h: u64) LvalueResult {
            const salted = h ^ ctrl(header).salt;
            const md = metadata(header);
            const tag = tagOf(salted);
            const base = entries(header);
            const es = entrySize(header);
            var candidate: ?u32 = null;
            var p = Probe.init(header, salted);
            while (true) : (p.advance()) {
                const g = loadGroup(md, p.group);
                var m = matchByte(g, tag);
                while (m != 0) : (m &= m - 1) {
                    const slot = p.group * group_size + @ctz(m);
                    const e = base + @as(usize, slot) * es;
                    if (!isZeroKey(e) and Spec.eql(ctx, keyAt(e), key)) return .{ .found = e };
                }
                if (candidate == null) {
                    const f = matchFree(g);
                    if (f != 0) candidate = p.group * group_size + @ctz(f);
                }
                if (matchByte(g, empty) != 0) break;
            }
            const slot = candidate.?;
            if (md[slot] != deleted and isFull(header)) return .full;
            occupy(header, slot, salted);
            const e = base + @as(usize, slot) * es;
            @memset(e[0..key_size], 0);
            return .{ .inserted = e };
        }

        /// Inserts the built entry `entry_bytes` of a key known to be absent
        /// (the policy layer's migration; `grow`'s rehash): no key compare.
        /// The caller has made the load check.
        pub fn insertKnownAbsent(header: *Header, ctx: Ctx, key: Key, h: u64, entry_bytes: [*]const u8) void {
            if (std.lang.Optimize.runtimeSafety(@import("builtin").mode)) std.debug.assert(fetch(header, ctx, key, h) == null);
            const salted = h ^ ctrl(header).salt;
            const slot = freeSlot(header, salted);
            std.debug.assert(metadata(header)[slot] == deleted or !isFull(header));
            occupy(header, slot, salted);
            copyEntry(entryAtIndex(header, slot), entry_bytes, entrySize(header));
        }

        pub fn delete(header: *Header, ctx: Ctx, key: Key, h: u64) bool {
            if (header.cur_items == 0) return false;
            const slot = find(header, ctx, key, h ^ ctrl(header).salt) orelse return false;
            const md = metadata(header);
            // An empty slot in the group means no probe ever went past it
            // (see the file comment), so this slot can be empty too.
            if (matchByte(loadGroup(md, slot / group_size), empty) != 0) {
                md[slot] = empty;
            } else {
                md[slot] = deleted;
                ctrl(header).deleted += 1;
            }
            header.cur_items -= 1;
            return true;
        }

        // ----------------------------------------------------- growth

        /// A full block: rehashes every live entry into a new block of the
        /// same size when the live entries are at most 3/4 of the load limit
        /// (the tombstones made it full), else of twice the size. Returns
        /// the new header, leaving the old block untouched for the caller to
        /// dispose of. Never returns null.
        pub fn grow(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !?*Header {
            const c = ctrl(header);
            const same_size = header.cur_items <= capacity(header) / 4 * 3;
            const new = try allocate(allocator, header.*, if (same_size) c.log2_slots else c.log2_slots + 1);
            ctrl(new).salt = c.salt;
            const md = metadata(header);
            const slots = slotCount(header);
            const es = entrySize(header);
            var g: u32 = 0;
            while (g < slots / group_size) : (g += 1) {
                var m = matchLive(loadGroup(md, g));
                while (m != 0) : (m &= m - 1) {
                    const e = entryAtIndex(header, g * group_size + @ctz(m));
                    // A key the caller has not filled in yet cannot be hashed.
                    if (isZeroKey(e)) continue;
                    const salted = Spec.hash(ctx, keyAt(e)) ^ c.salt;
                    const slot = freeSlot(new, salted);
                    occupy(new, slot, salted);
                    copyEntry(entryAtIndex(new, slot), e, es);
                }
            }
            std.debug.assert(!isFull(new));
            return new;
        }

        // -------------------------------------------------- iteration

        /// The highest live slot below `limit`, or null.
        fn highestLiveBelow(header: *Header, limit: u32) ?u32 {
            if (limit == 0) return null;
            const md = metadata(header);
            var g = (limit - 1) / group_size;
            var keep = maskBelow(limit - g * group_size);
            while (true) {
                const live = matchLive(loadGroup(md, g)) & keep;
                if (live != 0) return g * group_size + (group_size - 1 - @clz(live));
                if (g == 0) return null;
                g -= 1;
                keep = std.math.maxInt(Mask);
            }
        }

        pub fn first(header: *Header) u32 {
            if (header.cur_items == 0) return 0;
            return next(header, start(header));
        }

        /// The live position below `pos` (`pos` is not 0), or 0.
        pub fn next(header: *Header, pos: u32) u32 {
            const slot = highestLiveBelow(header, pos - 1) orelse return 0;
            return slot + 1;
        }

        pub fn entryAt(header: *Header, pos: u32) [*]u8 {
            std.debug.assert(metadata(header)[pos - 1] < empty);
            return entryAtIndex(header, pos - 1);
        }

        /// One past the highest position.
        pub fn start(header: *Header) u32 {
            return slotCount(header) + 1;
        }

        pub fn drain(header: *Header, visitor: anytype) void {
            const is_fn = @typeInfo(@TypeOf(visitor)) == .@"fn";
            const md = metadata(header);
            var g: u32 = 0;
            while (g < slotCount(header) / group_size) : (g += 1) {
                var m = matchLive(loadGroup(md, g));
                while (m != 0) : (m &= m - 1) {
                    const e = entryAtIndex(header, g * group_size + @ctz(m));
                    if (is_fn) visitor(e) else visitor.visit(e);
                }
            }
        }

        // ------------------------------------------------------- fsck

        /// Counts: metadata bytes that are neither empty, deleted nor a tag;
        /// live entries with a zero key, a tag that disagrees with their
        /// hash, or that a lookup of their key does not reach; live and
        /// deleted counts that disagree with `cur_items` and the tombstone
        /// count; a block at or past its load limit with no empty slot.
        pub fn fsck(header: *Header, ctx: Ctx, mode: u32) u64 {
            _ = mode;
            const c = ctrl(header);
            var errors: u64 = 0;
            var live: u64 = 0;
            var tombstones: u64 = 0;
            var empties: u64 = 0;
            const md = metadata(header);
            for (0..slotCount(header)) |i| {
                const m = md[i];
                if (m == empty) {
                    empties += 1;
                    continue;
                }
                if (m == deleted) {
                    tombstones += 1;
                    continue;
                }
                if (m > empty) {
                    errors += 1;
                    continue;
                }
                live += 1;
                const e = entryAtIndex(header, @intCast(i));
                if (isZeroKey(e)) {
                    errors += 1;
                    continue;
                }
                const key = keyAt(e);
                const h = Spec.hash(ctx, key);
                if (m != tagOf(h ^ c.salt)) errors += 1;
                if (fetch(header, ctx, key, h) != e) errors += 1;
            }
            if (live != header.cur_items) errors += 1;
            if (tombstones != c.deleted) errors += 1;
            if (empties == 0) errors += 1;
            if (live + tombstones > capacity(header)) errors += 1;
            return errors;
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_spec = @import("../test_spec.zig");
const IntSpec = test_spec.IntSpec;
const S = Tier(.{}).Impl(IntSpec);
const test_entry_size = 16;

/// `IntSpec` with the one-rung Swiss set, for tables the policy layer grows.
const SwissSpec = struct {
    pub const Key = IntSpec.Key;
    pub const Ctx = IntSpec.Ctx;
    pub const runtime_entry_size = true;
    pub const publish = .plain;
    pub const sets: []const @import("../tier.zig").TierSet = &.{&test_spec.swiss_test_set};
    pub const hash = IntSpec.hash;
    pub const eql = IntSpec.eql;
    pub const allocator = IntSpec.allocator;
    pub const onDuplicate = IntSpec.onDuplicate;
};
const T = @import("../table.zig").Table(SwissSpec);

fn testInit(cap: u32) !*Header {
    return S.init(testing.allocator, .{ .tier = 0, .set = 0, .entry_size = test_entry_size, .stale = 0, .cur_items = 0 }, cap);
}

fn testFree(header: *Header) void {
    const block: [*]align(8) u8 = @alignCast(S.blockStart(header));
    testing.allocator.free(block[0..S.allocatedSize(header)]);
}

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

/// Insert `key` with value `key * 10` into a tier block; absent, and fits.
fn put(header: *Header, key: u64) !void {
    switch (S.lvalueFetch(header, {}, key, S.hash({}, key))) {
        .inserted => |e| try fill(e, key),
        else => return error.TestUnexpectedResult,
    }
}

fn get(header: *Header, key: u64) ?[*]u8 {
    return S.fetch(header, {}, key, S.hash({}, key));
}

fn del(header: *Header, key: u64) bool {
    return S.delete(header, {}, key, S.hash({}, key));
}

fn countByIteration(header: *Header) u32 {
    var n: u32 = 0;
    var pos = S.first(header);
    while (pos != 0) : (pos = S.next(header, pos)) n += 1;
    return n;
}

/// Insert `key` with value `key * 10` through the policy layer.
fn tput(h: T.Handle, key: u64) !void {
    try fill(T.insert({}, h, key), key);
}

test "insert, fetch, delete across group boundaries" {
    const h = try testInit(100);
    defer testFree(h);
    S.setSalt(h, 0x9e37_79b9_7f4a_7c15);
    // 100 entries need 128 slots (112 at 7/8), eight groups.
    try testing.expectEqual(@as(u32, 128), S.slotCount(h));
    for (1..101) |k| try put(h, k);
    try testing.expectEqual(@as(u32, 100), h.cur_items);
    // Some keys overflowed their home group into the next one.
    var displaced: u32 = 0;
    for (1..101) |k| {
        const e = get(h, k).?;
        try testing.expectEqual(@as(u64, k * 10), valueOf(e));
        const slot: u32 = @intCast((@intFromPtr(e) - @intFromPtr(S.entries(h))) / test_entry_size);
        if (slot / group_size != S.homeGroup(h, S.hash({}, k))) displaced += 1;
    }
    try testing.expect(displaced > 0);
    for (101..201) |k| try testing.expectEqual(@as(?[*]u8, null), get(h, k));
    try testing.expect(S.lvalueFetch(h, {}, 7, S.hash({}, 7)) == .found);
    var k: u64 = 2;
    while (k <= 100) : (k += 2) try testing.expect(del(h, k));
    k = 2;
    while (k <= 100) : (k += 2) {
        try testing.expectEqual(@as(?[*]u8, null), get(h, k));
        try testing.expect(!del(h, k));
    }
    k = 1;
    while (k <= 100) : (k += 2) try testing.expectEqual(k, keyOf(get(h, k).?));
    try testing.expectEqual(@as(u32, 50), h.cur_items);
    try testing.expectEqual(@as(u32, 50), countByIteration(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "grow keeps every entry" {
    var slot: ?*Header = null;
    const h = &slot;
    T.build({}, h, test_entry_size, 0, 0);
    defer T.demolish({}, h);
    const n = 10_000;
    for (1..n + 1) |k| try tput(h, k);
    try testing.expectEqual(@as(u32, n), T.count(h));
    for (1..n + 1) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, n + 1));
    var seen = try std.DynamicBitSet.initEmpty(testing.allocator, n + 1);
    defer seen.deinit();
    var visits: u32 = 0;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) {
        const key = keyOf(T.current(h, pos).?);
        try testing.expect(key >= 1 and key <= n);
        try testing.expect(!seen.isSet(key));
        seen.set(key);
        visits += 1;
    }
    try testing.expectEqual(@as(u32, n), visits);
    try testing.expectEqual(@as(usize, n), seen.count());
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "tombstones do not accumulate forever" {
    var slot: ?*Header = null;
    const h = &slot;
    T.build({}, h, test_entry_size, 0, 0);
    defer T.demolish({}, h);
    for (1..65) |k| try tput(h, k);
    const baseline = T.allocatedSize(h);
    var oldest: u64 = 1;
    var fresh: u64 = 65;
    for (0..100_000) |_| {
        try tput(h, fresh);
        fresh += 1;
        try testing.expect(T.delete({}, h, oldest));
        oldest += 1;
        try testing.expectEqual(@as(u32, 64), T.count(h));
        try testing.expect(T.allocatedSize(h) <= 4 * baseline);
    }
    for (oldest..fresh) |k| try testing.expectEqual(k * 10, valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, oldest - 1));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

/// 20_000 random inserts, fetches and deletes on keys 1..4095 (0 is the
/// unfilled key), each checked against `std.AutoHashMap`; the whole key
/// range is swept every 1_000 operations and at the end.
fn randomOps(h: T.Handle) !void {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var model = std.AutoHashMap(u64, void).init(testing.allocator);
    defer model.deinit();
    for (0..20_000) |i| {
        const key = rand.intRangeLessThan(u64, 1, 4_096);
        switch (rand.uintLessThan(u8, 3)) {
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
            1 => {
                const e = T.fetch({}, h, key);
                try testing.expectEqual(model.contains(key), e != null);
                if (e) |p| try testing.expectEqual(key * 10, valueOf(p));
            },
            else => try testing.expectEqual(model.remove(key), T.delete({}, h, key)),
        }
        try testing.expectEqual(model.count(), T.count(h));
        if (i % 1_000 == 999) {
            for (1..4_096) |k| try testing.expectEqual(model.contains(k), T.fetch({}, h, k) != null);
        }
    }
    for (1..4_096) |k| try testing.expectEqual(model.contains(k), T.fetch({}, h, k) != null);
    var walked: u32 = 0;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) {
        try testing.expect(model.contains(keyOf(T.current(h, pos).?)));
        walked += 1;
    }
    try testing.expectEqual(model.count(), walked);
}

test "random ops match std.AutoHashMap" {
    var slot: ?*Header = null;
    const h = &slot;
    T.build({}, h, test_entry_size, 0, 0);
    defer T.demolish({}, h);
    try randomOps(h);
}

test "fsck finds no fault" {
    var slot: ?*Header = null;
    const h = &slot;
    T.build({}, h, test_entry_size, 0, 0);
    defer T.demolish({}, h);
    try randomOps(h);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));

    // A corrupted tag, a stray tombstone and a lost count are each found.
    const header = slot.?;
    const md = S.metadata(header);
    const s = S.first(header) - 1;
    const saved = md[s];
    md[s] = (saved + 1) & 0x7F;
    try testing.expect(T.fsck({}, h, 0) > 0);
    md[s] = deleted;
    try testing.expect(T.fsck({}, h, 0) > 0);
    md[s] = saved;
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    header.cur_items += 1;
    try testing.expect(T.fsck({}, h, 0) > 0);
    header.cur_items -= 1;
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "iteration walks slots downward and survives delete-current while holding next" {
    const h = try testInit(300);
    defer testFree(h);
    for (1..301) |k| try put(h, k);
    var seen = @as([301]u32, @splat(0));
    try testing.expectEqual(S.slotCount(h) + 1, S.start(h));
    try testing.expectEqual(S.first(h), S.next(h, S.start(h)));
    var pos = S.first(h);
    var prev: u32 = S.start(h);
    var i: u32 = 0;
    while (pos != 0) : (i += 1) {
        try testing.expect(pos < prev);
        prev = pos;
        const nxt = S.next(h, pos);
        const k = keyOf(S.entryAt(h, pos));
        seen[k] += 1;
        if (i % 2 == 0) try testing.expect(del(h, k));
        pos = nxt;
    }
    try testing.expectEqual(@as(u32, 300), i);
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    try testing.expectEqual(@as(u32, 150), h.cur_items);
    try testing.expectEqual(@as(u32, 150), countByIteration(h));
    const Summer = struct {
        n: u32 = 0,
        last: usize = 0,
        fn visit(self: *@This(), e: [*]u8) void {
            // Ascending slot order.
            std.debug.assert(@intFromPtr(e) > self.last);
            self.last = @intFromPtr(e);
            self.n += 1;
        }
    };
    var summer = Summer{};
    S.drain(h, &summer);
    try testing.expectEqual(@as(u32, 150), summer.n);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "a verbatim block copy is an independent table" {
    const h = try testInit(40);
    defer testFree(h);
    for (1..41) |k| try put(h, k);
    for (1..11) |k| try testing.expect(del(h, k));
    const size = S.allocatedSize(h);
    const copy_block = try testing.allocator.alignedAlloc(u8, .@"8", size);
    @memcpy(copy_block, S.blockStart(h)[0..size]);
    const copy: *Header = @ptrCast(copy_block.ptr);
    defer testFree(copy);
    try put(copy, 1000);
    try testing.expect(del(copy, 20));
    try testing.expectEqual(@as(?[*]u8, null), get(h, 1000));
    try testing.expectEqual(@as(u64, 20), keyOf(get(h, 20).?));
    for (11..41) |k| {
        const e = get(copy, k);
        if (k == 20) try testing.expectEqual(@as(?[*]u8, null), e) else try testing.expectEqual(@as(u64, k * 10), valueOf(e.?));
        // Every entry of the copy lies inside the copy's block.
        if (e) |p| try testing.expect(@intFromPtr(p) >= @intFromPtr(copy_block.ptr) and @intFromPtr(p) < @intFromPtr(copy_block.ptr) + size);
    }
    try testing.expectEqual(@as(u32, 30), h.cur_items);
    try testing.expectEqual(@as(u32, 30), copy.cur_items);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    try testing.expectEqual(@as(u64, 0), S.fsck(copy, {}, 0));
}

test "deletes, tombstones, reuse when full, and the same-size rehash" {
    // 16 slots hold 14 at 7/8.
    const one = try testInit(1);
    defer testFree(one);
    try testing.expectEqual(@as(u32, 16), S.slotCount(one));
    try testing.expectEqual(@as(u32, 14), S.capacity(one));
    for (1..15) |k| try put(one, k);
    try testing.expect(S.isFull(one));
    try testing.expect(S.lvalueFetch(one, {}, 3, S.hash({}, 3)) == .found);
    try testing.expect(S.lvalueFetch(one, {}, 99, S.hash({}, 99)) == .full);
    // A one-group table always keeps an empty slot, so its deletes free
    // their slot outright.
    try testing.expect(del(one, 1));
    try testing.expectEqual(@as(u32, 0), S.ctrl(one).deleted);
    try put(one, 99);

    // 64 slots hold 56: fill them, then delete every entry of the groups
    // left without an empty slot. Those deletes leave tombstones (a probe
    // may have passed through a full group), so the table stays full.
    var h = try testInit(56);
    defer testFree(h);
    try testing.expectEqual(@as(u32, 64), S.slotCount(h));
    var key: u64 = 1;
    while (!S.isFull(h)) : (key += 1) try put(h, key);
    try testing.expectEqual(@as(u32, 56), h.cur_items);
    const md = S.metadata(h);
    var full_groups: u32 = 0;
    var tombstoned: u32 = 0;
    for (0..S.slotCount(h) / group_size) |g| {
        const group = md[g * group_size ..][0..group_size];
        if (std.mem.indexOfScalar(u8, group, empty) != null) continue;
        full_groups += 1;
        tombstoned = @intCast(g);
        for (0..group_size) |j| try testing.expect(del(h, keyOf(S.entryAtIndex(h, @intCast(g * group_size + j)))));
    }
    try testing.expect(full_groups > 0);
    try testing.expectEqual(full_groups * group_size, S.ctrl(h).deleted);
    try testing.expect(S.isFull(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));

    // A key whose probe meets a tombstone first takes it, full or not.
    var fresh: u64 = 10_000;
    while (S.homeGroup(h, S.hash({}, fresh)) != tombstoned) fresh += 1;
    const deleted_before = S.ctrl(h).deleted;
    try put(h, fresh);
    try testing.expectEqual(deleted_before - 1, S.ctrl(h).deleted);
    try testing.expect(S.isFull(h));

    // The live entries are well under the load limit: grow rehashes at the
    // same size and drops the tombstones.
    const live = h.cur_items;
    try testing.expect(live <= S.capacity(h) / 4 * 3);
    const old = h;
    h = (try S.grow(old, {}, testing.allocator)).?;
    testFree(old);
    try testing.expectEqual(@as(u32, 64), S.slotCount(h));
    try testing.expectEqual(@as(u32, 0), S.ctrl(h).deleted);
    try testing.expectEqual(live, h.cur_items);
    try testing.expect(!S.isFull(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    try testing.expectEqual(fresh * 10, valueOf(get(h, fresh).?));

    // Past three quarters of the limit live, grow doubles.
    while (!S.isFull(h)) : (key += 1) try put(h, key);
    const old2 = h;
    h = (try S.grow(old2, {}, testing.allocator)).?;
    testFree(old2);
    try testing.expectEqual(@as(u32, 128), S.slotCount(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}
