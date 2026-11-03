//! The array-ordered tier of the Zig hash engine (bake-off candidate 2,
//! `MVM_HASH_STRATEGY_ORDERED`): the entries live in a dense array in
//! insertion order, found through a separate open-addressing index of small
//! integers, in the manner of CPython's compact dict and PHP 7's arrays.
//!
//! Block layout (one allocation, 8-byte aligned; the table pointer points at
//! the header, which is also the block start; everything else lies at an
//! offset computed from the header's `log2_index` and `slot_width`, so a
//! verbatim copy of the block is a working table):
//!
//!     Control             24 bytes: the engine `Header`, then
//!       salt: u64           xored into every hash
//!       log2_index: u8      the index has 2^log2_index slots, at least 16
//!       slot_width: u8      bytes per index slot: 1, 2 or 4
//!     index[slots]        slot_width bytes each: 0 empty, else the
//!                         position of an entry plus one
//!     entries[capacity]   entry_size bytes each, key first; the first
//!                         `cur_items` are live, in insertion order
//!
//! The entry capacity is half the index slots (the index's load factor is
//! at most 1/2). The slot width is the narrowest that holds every position
//! plus one: `u8` while the capacity is below 255, `u16` below 65_535, else
//! `u32`. Since the capacity is a power of two, that is `u8` up to 128
//! entries, `u16` from 256 to 32_768, `u32` from 65_536. The index starts at
//! byte 24 and is a multiple of 16 bytes long, so the entries are 8-byte
//! aligned.
//!
//! Probing: linear from the slot the low bits of the salted hash pick, until
//! an empty slot; a candidate's key is compared only when its (unsalted)
//! hash equals the wanted one. Every probe ends: at most half the slots are
//! occupied. Hashes are not stored; `delete` and `grow` recompute them from
//! the keys, which for the string tables is the cached hash code.
//!
//! Insert appends to the entries array. Delete is a swap-remove: the last
//! entry moves into the hole, and its index slot is rewritten to the new
//! position. The deleted key's index slot is emptied by backward-shift
//! deletion (each later slot of the cluster whose home is at or before the
//! hole moves back into it), so the index has no tombstones and a full
//! block is always one with `cur_items == capacity`; `grow` therefore
//! always doubles, into a new block, copying the entries in order and
//! rebuilding the index.
//!
//! This tier maintains `header.cur_items` in `lvalueFetch`, `delete` and
//! `insertKnownAbsent`. Iteration position of entry `i` is `i + 1`; `first`
//! is `cur_items` and `next` walks down (clamped to `cur_items`); `start` is
//! the capacity plus one. Walking down is what makes "delete the current
//! entry while holding the next position" safe with swap-remove: the entry
//! that moves into the hole comes from the top, which the walk has already
//! visited, and every position below the hole is unchanged. Before the
//! first delete the walk is reverse insertion order.
//!
//! Blocks are owned by the policy layer: `init` and `grow` return a new
//! block and never free an old one, so the caller disposes of the old block
//! (`blockStart(old)` for `allocatedSize(old)` bytes) after publishing the
//! new header.
//!
//! An inserted entry has its key bytes zeroed for the caller to fill;
//! lookups skip zero keys without calling `Spec.hash` or `Spec.eql`, `grow`
//! drops them (as Robin Hood's does), and `fsck` counts them as errors. A
//! zero-keyed entry has no hash to find its home slot by, so the backward
//! shift leaves its slot where it is and a swap-remove that moves it finds
//! its slot by a scan of the index.
//!
//! `drain` visitor convention: `visitor` is either a function
//! `fn ([*]u8) void` or a value (typically a pointer to a struct) with a
//! method `visit(self, [*]u8) void`; it is called once per live entry in
//! ascending position (insertion) order.
const std = @import("std");
const Header = @import("../tier.zig").Header;

/// The smallest block: 16 index slots, 8 entries.
const min_log2_index: u8 = 4;
/// The slot count stays below 2^32 (positions and slots are `u32`).
const max_log2_index: u8 = 31;

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
    log2_index: u8,
    slot_width: u8,
    _pad: [6]u8,
};
const control_size = @sizeOf(Control);
comptime {
    std.debug.assert(control_size == 24);
}

/// The entries a block of `slots` index slots holds: half of them.
fn capacityOf(slots: u32) u32 {
    return slots / 2;
}

/// Bytes per index slot for an entry capacity of `cap`.
fn widthFor(cap: u32) u8 {
    return if (cap < 255) 1 else if (cap < 65_535) 2 else 4;
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
            return @as(u32, 1) << @intCast(ctrl(header).log2_index);
        }

        fn index(header: *Header) [*]u8 {
            return @as([*]u8, @ptrCast(header)) + control_size;
        }

        /// The index as an array of `W`, the recorded slot width.
        fn indexOf(comptime W: type, header: *Header) [*]W {
            return @ptrCast(@alignCast(index(header)));
        }

        fn entries(header: *Header) [*]u8 {
            return index(header) + @as(usize, slotCount(header)) * ctrl(header).slot_width;
        }

        fn entryAtIndex(header: *Header, i: u32) [*]u8 {
            return entries(header) + @as(usize, i) * entrySize(header);
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

        fn blockSize(log2_index: u8, entry_size: usize) usize {
            const slots = @as(usize, 1) << @intCast(log2_index);
            const cap = capacityOf(@intCast(slots));
            return control_size + slots * widthFor(cap) + cap * entry_size;
        }

        pub fn blockStart(header: *Header) [*]u8 {
            return @ptrCast(header);
        }

        pub fn allocatedSize(header: *Header) usize {
            return blockSize(ctrl(header).log2_index, entrySize(header));
        }

        /// Index slot `s` (for tests and `fsck`; the hot paths are
        /// specialised by width).
        pub fn slotGet(header: *Header, s: u32) u32 {
            return switch (ctrl(header).slot_width) {
                1 => indexOf(u8, header)[s],
                2 => indexOf(u16, header)[s],
                else => indexOf(u32, header)[s],
            };
        }

        pub fn slotSet(header: *Header, s: u32, v: u32) void {
            switch (ctrl(header).slot_width) {
                1 => indexOf(u8, header)[s] = @intCast(v),
                2 => indexOf(u16, header)[s] = @intCast(v),
                else => indexOf(u32, header)[s] = v,
            }
        }

        // ------------------------------------------------- allocation

        fn allocate(allocator: std.mem.Allocator, header_init: Header, log2_index: u8) !*Header {
            const entry_size = if (Spec.runtime_entry_size) header_init.entry_size else Spec.entry_size;
            std.debug.assert(entry_size != 0 and entry_size % 8 == 0);
            if (log2_index > max_log2_index) return error.OutOfMemory;
            const block = try allocator.alignedAlloc(u8, .@"8", blockSize(log2_index, entry_size));
            const header: *Header = @ptrCast(block.ptr);
            const slots = @as(u32, 1) << @intCast(log2_index);
            ctrl(header).* = .{
                .header = header_init,
                .salt = 0,
                .log2_index = log2_index,
                .slot_width = widthFor(capacityOf(slots)),
                ._pad = @splat(0),
            };
            header.cur_items = 0;
            @memset(index(header)[0 .. @as(usize, slots) * ctrl(header).slot_width], 0);
            return header;
        }

        /// The smallest block whose entry capacity holds `cap` entries.
        pub fn init(allocator: std.mem.Allocator, header_init: Header, cap: u32) !*Header {
            var log2: u8 = min_log2_index;
            while (log2 < max_log2_index and capacityOf(@as(u32, 1) << @intCast(log2)) < cap) log2 += 1;
            return allocate(allocator, header_init, log2);
        }

        /// The entry capacity: half the index slots.
        pub fn capacity(header: *Header) u32 {
            return capacityOf(slotCount(header));
        }

        pub fn isFull(header: *Header) bool {
            return header.cur_items >= capacity(header);
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

        fn homeSlot(header: *Header, h: u64) u32 {
            return @as(u32, @truncate(h ^ ctrl(header).salt)) & (slotCount(header) - 1);
        }

        /// The home slot of the entry at `pos`, or null for a zero key.
        fn homeOfEntry(header: *Header, ctx: Ctx, pos: u32) ?u32 {
            const e = entryAtIndex(header, pos);
            if (isZeroKey(e)) return null;
            return homeSlot(header, Spec.hash(ctx, keyAt(e)));
        }

        /// Where a probe for `key` stopped: its slot, or the empty slot that
        /// ended the probe.
        const Probe = struct { slot: u32, found: bool };

        inline fn probeW(comptime W: type, header: *Header, ctx: Ctx, key: Key, h: u64) Probe {
            const idx = indexOf(W, header);
            const mask = slotCount(header) - 1;
            const base = entries(header);
            const es = entrySize(header);
            var s = homeSlot(header, h);
            while (true) : (s = (s + 1) & mask) {
                const v = idx[s];
                if (v == 0) return .{ .slot = s, .found = false };
                const e = base + @as(usize, v - 1) * es;
                if (isZeroKey(e)) continue;
                const k = keyAt(e);
                if (Spec.hash(ctx, k) == h and Spec.eql(ctx, k, key)) return .{ .slot = s, .found = true };
            }
        }

        inline fn probe(header: *Header, ctx: Ctx, key: Key, h: u64) Probe {
            return switch (ctrl(header).slot_width) {
                1 => probeW(u8, header, ctx, key, h),
                2 => probeW(u16, header, ctx, key, h),
                else => probeW(u32, header, ctx, key, h),
            };
        }

        /// The first empty slot from `h`'s home.
        fn emptySlot(header: *Header, h: u64) u32 {
            const mask = slotCount(header) - 1;
            var s = homeSlot(header, h);
            while (slotGet(header, s) != 0) s = (s + 1) & mask;
            return s;
        }

        /// Appends an entry indexed at the empty slot `s`; returns it.
        fn append(header: *Header, s: u32) [*]u8 {
            const pos = header.cur_items;
            slotSet(header, s, pos + 1);
            header.cur_items = pos + 1;
            return entryAtIndex(header, pos);
        }

        pub fn fetch(header: *Header, ctx: Ctx, key: Key, h: u64) ?[*]u8 {
            if (header.cur_items == 0) return null;
            const p = probe(header, ctx, key, h);
            if (!p.found) return null;
            return entryAtIndex(header, slotGet(header, p.slot) - 1);
        }

        /// Find or append in one probe. Full only for an absent key.
        pub fn lvalueFetch(header: *Header, ctx: Ctx, key: Key, h: u64) LvalueResult {
            const p = probe(header, ctx, key, h);
            if (p.found) return .{ .found = entryAtIndex(header, slotGet(header, p.slot) - 1) };
            if (isFull(header)) return .full;
            const e = append(header, p.slot);
            @memset(e[0..key_size], 0);
            return .{ .inserted = e };
        }

        /// Appends the built entry `entry_bytes` of a key known to be absent
        /// (the policy layer's migration; `grow`'s rebuild): no key compare.
        /// The caller has made the load check.
        pub fn insertKnownAbsent(header: *Header, ctx: Ctx, key: Key, h: u64, entry_bytes: [*]const u8) void {
            if (std.debug.runtime_safety) std.debug.assert(fetch(header, ctx, key, h) == null);
            std.debug.assert(!isFull(header));
            copyEntry(append(header, emptySlot(header, h)), entry_bytes, entrySize(header));
        }

        /// Empties index slot `hole` by backward-shift deletion: each later
        /// slot of the cluster whose home is not in (hole, slot] moves back
        /// into the hole, which moves to it.
        fn unindex(header: *Header, ctx: Ctx, hole_slot: u32) void {
            const mask = slotCount(header) - 1;
            var hole = hole_slot;
            var j = (hole + 1) & mask;
            while (true) : (j = (j + 1) & mask) {
                const v = slotGet(header, j);
                if (v == 0) break;
                // A zero key's home is unknown: leave it where it is.
                const home = homeOfEntry(header, ctx, v - 1) orelse continue;
                if (((j -% home) & mask) >= ((j -% hole) & mask)) {
                    slotSet(header, hole, v);
                    hole = j;
                }
            }
            slotSet(header, hole, 0);
        }

        /// The index slot holding position `pos` (0-based).
        fn slotOfPosition(header: *Header, ctx: Ctx, pos: u32) u32 {
            const mask = slotCount(header) - 1;
            var s = homeOfEntry(header, ctx, pos) orelse 0;
            while (slotGet(header, s) != pos + 1) s = (s + 1) & mask;
            return s;
        }

        pub fn delete(header: *Header, ctx: Ctx, key: Key, h: u64) bool {
            if (header.cur_items == 0) return false;
            const p = probe(header, ctx, key, h);
            if (!p.found) return false;
            const pos = slotGet(header, p.slot) - 1;
            unindex(header, ctx, p.slot);
            const last = header.cur_items - 1;
            if (pos != last) {
                slotSet(header, slotOfPosition(header, ctx, last), pos + 1);
                copyEntry(entryAtIndex(header, pos), entryAtIndex(header, last), entrySize(header));
            }
            header.cur_items = last;
            return true;
        }

        // ----------------------------------------------------- growth

        /// A full block: copies the live entries, in order, into a new
        /// block with twice the index slots and entry capacity, rebuilding
        /// the index. Returns the new header, leaving the old block
        /// untouched for the caller to dispose of. Never returns null.
        pub fn grow(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !?*Header {
            const new = try allocate(allocator, header.*, ctrl(header).log2_index + 1);
            ctrl(new).salt = ctrl(header).salt;
            const es = entrySize(header);
            var pos: u32 = 0;
            while (pos < header.cur_items) : (pos += 1) {
                const e = entryAtIndex(header, pos);
                // A key the caller has not filled in yet cannot be hashed.
                if (isZeroKey(e)) continue;
                const h = Spec.hash(ctx, keyAt(e));
                copyEntry(append(new, emptySlot(new, h)), e, es);
            }
            std.debug.assert(!isFull(new));
            return new;
        }

        // -------------------------------------------------- iteration

        pub fn first(header: *Header) u32 {
            return header.cur_items;
        }

        /// The position below `pos` (`pos` is not 0), clamped to the live
        /// entries, or 0.
        pub fn next(header: *Header, pos: u32) u32 {
            return @min(pos - 1, header.cur_items);
        }

        pub fn entryAt(header: *Header, pos: u32) [*]u8 {
            std.debug.assert(pos >= 1 and pos <= header.cur_items);
            return entryAtIndex(header, pos - 1);
        }

        /// One past the highest position.
        pub fn start(header: *Header) u32 {
            return capacity(header) + 1;
        }

        pub fn drain(header: *Header, visitor: anytype) void {
            const is_fn = @typeInfo(@TypeOf(visitor)) == .@"fn";
            var pos: u32 = 0;
            while (pos < header.cur_items) : (pos += 1) {
                const e = entryAtIndex(header, pos);
                if (is_fn) visitor(e) else visitor.visit(e);
            }
        }

        // ------------------------------------------------------- fsck

        /// Counts: a slot width other than the capacity's; live entries past
        /// the capacity; index slots past the live entries; occupied slots
        /// other than `cur_items`; live entries with a zero key or that a
        /// lookup of their key does not reach (which, with the slot count,
        /// makes the index a bijection onto the live entries).
        pub fn fsck(header: *Header, ctx: Ctx, mode: u32) u64 {
            _ = mode;
            var errors: u64 = 0;
            if (ctrl(header).slot_width != widthFor(capacity(header))) return 1;
            if (header.cur_items > capacity(header)) return 1;
            var occupied: u64 = 0;
            var s: u32 = 0;
            while (s < slotCount(header)) : (s += 1) {
                const v = slotGet(header, s);
                if (v == 0) continue;
                occupied += 1;
                if (v > header.cur_items) errors += 1;
            }
            if (occupied != header.cur_items) errors += 1;
            if (errors != 0) return errors;
            var pos: u32 = 0;
            while (pos < header.cur_items) : (pos += 1) {
                const e = entryAtIndex(header, pos);
                if (isZeroKey(e)) {
                    errors += 1;
                    continue;
                }
                const key = keyAt(e);
                if (fetch(header, ctx, key, Spec.hash(ctx, key)) != e) errors += 1;
            }
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

/// `IntSpec` with the one-rung ordered set, for tables the policy layer grows.
const OrderedSpec = struct {
    pub const Key = IntSpec.Key;
    pub const Ctx = IntSpec.Ctx;
    pub const runtime_entry_size = true;
    pub const publish = .plain;
    pub const sets: []const @import("../tier.zig").TierSet = &.{&test_spec.ordered_test_set};
    pub const hash = IntSpec.hash;
    pub const eql = IntSpec.eql;
    pub const allocator = IntSpec.allocator;
    pub const onDuplicate = IntSpec.onDuplicate;
};
const T = @import("../table.zig").Table(OrderedSpec);

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

test "iteration is insertion order until the first delete" {
    const h = try testInit(50);
    defer testFree(h);
    for (1..51) |k| try put(h, k);
    try testing.expectEqual(S.first(h), S.next(h, S.start(h)));
    // Descending positions: the last inserted first.
    var want: u64 = 50;
    var pos = S.first(h);
    while (pos != 0) : (pos = S.next(h, pos)) {
        try testing.expectEqual(want, keyOf(S.entryAt(h, pos)));
        want -= 1;
    }
    try testing.expectEqual(@as(u64, 0), want);
    // A delete swaps the last entry into the hole.
    try testing.expect(del(h, 10));
    try testing.expectEqual(@as(u64, 50), keyOf(S.entryAt(h, 10)));
    try testing.expectEqual(@as(u32, 49), countByIteration(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "swap-remove keeps every other entry reachable" {
    const h = try testInit(1000);
    defer testFree(h);
    for (1..1001) |k| try put(h, k);
    var k: u64 = 3;
    while (k <= 1000) : (k += 3) try testing.expect(del(h, k));
    for (1..1001) |j| {
        if (j % 3 == 0) {
            try testing.expectEqual(@as(?[*]u8, null), get(h, j));
            try testing.expect(!del(h, j));
        } else {
            try testing.expectEqual(@as(u64, j * 10), valueOf(get(h, j).?));
        }
    }
    try testing.expectEqual(@as(u32, 1000 - 333), h.cur_items);
    try testing.expectEqual(@as(u32, 1000 - 333), countByIteration(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "delete current while iterating visits every live entry exactly once" {
    const h = try testInit(500);
    defer testFree(h);
    for (1..501) |k| try put(h, k);
    var seen = [_]u32{0} ** 501;
    // MVMIter's protocol: hold the next position, delete the current entry.
    var pos = S.first(h);
    var visits: u32 = 0;
    while (pos != 0) : (visits += 1) {
        const nxt = S.next(h, pos);
        const k = keyOf(S.entryAt(h, pos));
        seen[k] += 1;
        try testing.expect(del(h, k));
        pos = nxt;
    }
    try testing.expectEqual(@as(u32, 500), visits);
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    try testing.expectEqual(@as(u32, 0), h.cur_items);
    try testing.expectEqual(@as(u32, 0), S.first(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));

    // Deleting every other entry as it is visited: the survivors stay.
    for (1..501) |k| try put(h, k);
    @memset(&seen, 0);
    pos = S.first(h);
    var i: u32 = 0;
    while (pos != 0) : (i += 1) {
        const nxt = S.next(h, pos);
        const k = keyOf(S.entryAt(h, pos));
        seen[k] += 1;
        if (i % 2 == 0) try testing.expect(del(h, k));
        pos = nxt;
    }
    for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
    try testing.expectEqual(@as(u32, 250), h.cur_items);
    try testing.expectEqual(@as(u32, 250), countByIteration(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "index width changes at the thresholds" {
    var slot: ?*Header = null;
    const h = &slot;
    T.build({}, h, test_entry_size, 0, 0);
    defer T.demolish({}, h);
    // Entry capacities are powers of two: 128 holds u8 positions, 256 to
    // 32_768 u16, 65_536 and up u32.
    const steps = [_]struct { n: u64, width: u8 }{
        .{ .n = 128, .width = 1 },
        .{ .n = 129, .width = 2 },
        .{ .n = 300, .width = 2 },
        .{ .n = 32_768, .width = 2 },
        .{ .n = 32_769, .width = 4 },
        .{ .n = 70_000, .width = 4 },
    };
    var next_key: u64 = 1;
    for (steps) |step| {
        while (next_key <= step.n) : (next_key += 1) try tput(h, next_key);
        try testing.expectEqual(step.width, S.ctrl(slot.?).slot_width);
        try testing.expectEqual(@as(u32, @intCast(step.n)), T.count(h));
        for (1..step.n + 1) |k| try testing.expectEqual(@as(u64, k * 10), valueOf(T.fetch({}, h, k).?));
        try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, step.n + 1));
        try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    }
    // Deletes across the widest index keep the rest.
    var k: u64 = 1;
    while (k <= 70_000) : (k += 7) try testing.expect(T.delete({}, h, k));
    for (1..70_001) |j| try testing.expectEqual((j - 1) % 7 != 0, T.fetch({}, h, j) != null);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

/// The key range of `randomOps`: 1..key_limit-1 (0 is the unfilled key).
const key_limit = 1_024;

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

/// 20_000 random inserts, fetches and deletes on keys 1..1023, the whole
/// table compared with `std.AutoHashMap` after every operation.
fn randomOps(h: T.Handle) !void {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    var model = std.AutoHashMap(u64, void).init(testing.allocator);
    defer model.deinit();
    for (0..20_000) |_| {
        const key = rand.intRangeLessThan(u64, 1, key_limit);
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
        try matchesModel(h, &model);
    }
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

    const header = slot.?;
    try testing.expect(header.cur_items >= 2);
    // An index slot pointing at the wrong entry, past the live entries, or
    // emptied, and a lost count, are each found.
    var s: u32 = 0;
    while (S.slotGet(header, s) == 0) s += 1;
    const saved = S.slotGet(header, s);
    S.slotSet(header, s, if (saved == 1) 2 else saved - 1);
    try testing.expect(T.fsck({}, h, 0) > 0);
    S.slotSet(header, s, header.cur_items + 1);
    try testing.expect(T.fsck({}, h, 0) > 0);
    S.slotSet(header, s, 0);
    try testing.expect(T.fsck({}, h, 0) > 0);
    S.slotSet(header, s, saved);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    header.cur_items += 1;
    try testing.expect(T.fsck({}, h, 0) > 0);
    header.cur_items -= 1;
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "a verbatim block copy is an independent table" {
    // 300 entries: the u16 index, whose width the copy reads back.
    const h = try testInit(300);
    defer testFree(h);
    for (1..301) |k| try put(h, k);
    for (1..11) |k| try testing.expect(del(h, k));
    const size = S.allocatedSize(h);
    const copy_block = try testing.allocator.alignedAlloc(u8, .@"8", size);
    @memcpy(copy_block, S.blockStart(h)[0..size]);
    const copy: *Header = @ptrCast(copy_block.ptr);
    defer testFree(copy);
    try testing.expectEqual(@as(u8, 2), S.ctrl(copy).slot_width);
    try put(copy, 1000);
    try testing.expect(del(copy, 20));
    try testing.expectEqual(@as(?[*]u8, null), get(h, 1000));
    try testing.expectEqual(@as(u64, 20), keyOf(get(h, 20).?));
    for (11..301) |k| {
        const e = get(copy, k);
        if (k == 20) try testing.expectEqual(@as(?[*]u8, null), e) else try testing.expectEqual(@as(u64, k * 10), valueOf(e.?));
        // Every entry of the copy lies inside the copy's block.
        if (e) |p| try testing.expect(@intFromPtr(p) >= @intFromPtr(copy_block.ptr) and @intFromPtr(p) < @intFromPtr(copy_block.ptr) + size);
    }
    try testing.expectEqual(@as(u32, 290), h.cur_items);
    try testing.expectEqual(@as(u32, 290), copy.cur_items);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    try testing.expectEqual(@as(u64, 0), S.fsck(copy, {}, 0));
}

test "full, grow doubles both arrays into a new block, block size" {
    const h = try testInit(1);
    // The smallest block: 16 index slots, 8 entries.
    try testing.expectEqual(@as(u32, 8), S.capacity(h));
    try testing.expectEqual(@as(usize, 24 + 16 * 1 + 8 * test_entry_size), S.allocatedSize(h));
    for (1..9) |k| try put(h, k);
    try testing.expect(S.isFull(h));
    try testing.expect(S.lvalueFetch(h, {}, 3, S.hash({}, 3)) == .found);
    try testing.expect(S.lvalueFetch(h, {}, 99, S.hash({}, 99)) == .full);
    const grown = (try S.grow(h, {}, testing.allocator)).?;
    try testing.expect(grown != h);
    // The old block is untouched.
    try testing.expectEqual(@as(u32, 8), h.cur_items);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    testFree(h);
    defer testFree(grown);
    try testing.expectEqual(@as(u32, 16), S.capacity(grown));
    try testing.expectEqual(@as(usize, 24 + 32 * 1 + 16 * test_entry_size), S.allocatedSize(grown));
    // Insertion order survives the grow.
    var want: u64 = 8;
    var pos = S.first(grown);
    while (pos != 0) : (pos = S.next(grown, pos)) {
        try testing.expectEqual(want, keyOf(S.entryAt(grown, pos)));
        want -= 1;
    }
    try put(grown, 99);
    try testing.expectEqual(@as(u64, 990), valueOf(get(grown, 99).?));
    try testing.expectEqual(@as(u64, 0), S.fsck(grown, {}, 0));
    var visits: u32 = 0;
    const Counter = struct {
        n: *u32,
        last: usize = 0,
        fn visit(self: *@This(), e: [*]u8) void {
            // Ascending positions.
            std.debug.assert(@intFromPtr(e) > self.last);
            self.last = @intFromPtr(e);
            self.n.* += 1;
        }
    };
    var counter = Counter{ .n = &visits };
    S.drain(grown, &counter);
    try testing.expectEqual(@as(u32, 9), visits);
}
