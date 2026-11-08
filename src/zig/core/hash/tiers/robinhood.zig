//! The Robin Hood tier of the Zig hash engine (spec 6.2): a port of the C
//! algorithm in `src/core/str_hash_table.c` and `str_hash_table_funcs.h`
//! (open addressing, Robin Hood probing, extra hash bits in the metadata,
//! the in-place metadata-bit trade, doubling with reinsertion, the delete
//! backward shift). Ported: the algorithm and its sizes; not ported: `tc`,
//! `MVMString`, stale/CAS/safepoint publication (the policy layer's), and
//! HASH_DEBUG_ITER.
//!
//! Block layout (one allocation, 8-byte aligned), as `str_hash_table.h`
//! describes; the table pointer points at the `Header`, not the block start:
//!
//!     entries[allocated_items]  entry_size bytes each, key first; bucket i
//!                               lies at header - entry_size * (i + 1), so
//!                               the entries run downward from the header
//!     Header                    8 bytes (tier.Header)
//!     payload                   salt, max_items, official_size_log2,
//!                               key_right_shift, max_probe_distance,
//!                               max_probe_distance_limit, metadata_hash_bits
//!                               (MVMStrHashTableControl minus the debug
//!                               fields), padded to 32 bytes with the Header
//!     metadata[allocated + 1]   one byte per bucket: probe distance in the
//!                               high bits, extra hash bits in the low
//!                               `metadata_hash_bits`; 0 is empty; the last
//!                               byte is the 0 sentinel; rounded up to 8
//!
//! `allocated_items = official_size + max_probe_distance_limit - 1`; the
//! bucket of hash `h` is the top `official_size_log2` bits of
//! `(h ^ salt) * 11400714819323198485`. This tier maintains
//! `header.cur_items` in `lvalueFetch` and `delete`. Iteration position of
//! bucket `i` is `i + 1`; positions walk downward, and a delete only moves
//! entries from higher (already visited) buckets into lower ones at or above
//! the deleted bucket.
//!
//! Blocks are owned by the policy layer: `init` and a reallocating `grow`
//! return a new block and never free an old one, so the caller disposes of
//! the old block (`blockStart(old)` for `allocatedSize(old)` bytes) after
//! publishing the new header.
//!
//! An inserted entry has its key bytes zeroed for the caller to fill; lookups
//! skip zero keys without calling `Spec.eql`, `grow` skips them, and `fsck`
//! counts them as errors (the C's "key NULL") without calling `Spec.hash`.
//!
//! `drain` visitor convention: `visitor` is either a function
//! `fn ([*]u8) void` or a value (typically a pointer to a struct) with a
//! method `visit(self, [*]u8) void`; it is called once per live entry in
//! ascending bucket order.
const std = @import("std");
const Header = @import("../tier.zig").Header;

/// MVM_HASH_MAX_PROBE_DISTANCE.
const max_probe_distance_cap: u32 = 255;
/// MVM_HASH_INITIAL_BITS_IN_METADATA.
const initial_bits_in_metadata: u8 = 5;
/// STR_MIN_SIZE_BASE_2.
const min_size_log2: u8 = 3;
/// The multiplier of MVM_str_hash_code.
const fibonacci: u64 = 11400714819323198485;

pub const Salt = enum { none, engine };

pub fn Tier(comptime cfg: struct { salt: Salt = .engine }) type {
    return struct {
        pub const max_capacity: u32 = std.math.maxInt(u32);

        pub fn Impl(comptime Spec: type) type {
            return ImplType(cfg.salt, Spec);
        }
    };
}

/// The control block: the engine `Header` followed by this tier's payload.
const Control = extern struct {
    header: Header,
    salt: u64,
    /// "Hit this and we grow"; 0 forces a growth before the next insert.
    max_items: u32,
    official_size_log2: u8,
    key_right_shift: u8,
    /// The largest probe distance the metadata can express right now.
    max_probe_distance: u8,
    /// The largest probe distance possible for the official size.
    max_probe_distance_limit: u8,
    metadata_hash_bits: u8,
};
const control_size = @sizeOf(Control);
comptime {
    std.debug.assert(control_size == @sizeOf(Header) + 24);
}

/// MVM_hash_round_size_up with sizeof(long) == 8.
fn roundUp8(wanted: usize) usize {
    return (wanted - 1 + 8) & ~@as(usize, 7);
}

fn ImplType(comptime salt_mode: Salt, comptime Spec: type) type {
    return struct {
        const Key = Spec.Key;
        const Ctx = Spec.Ctx;
        const key_size = @sizeOf(Key);
        /// The key's bytes as one unsigned integer, for the zero-key test.
        const KeyBits = @Int(.unsigned, key_size * 8);

        pub const LvalueResult = union(enum) { found: [*]u8, inserted: [*]u8, full };

        // ------------------------------------------------------ geometry

        fn ctrl(header: *Header) *Control {
            return @ptrCast(@alignCast(header));
        }

        fn entrySize(header: *const Header) usize {
            return if (Spec.runtime_entry_size) header.entry_size else Spec.entry_size;
        }

        /// MVM_str_hash_official_size.
        pub fn officialSize(header: *Header) u32 {
            return @as(u32, 1) << @intCast(ctrl(header).official_size_log2);
        }

        /// MVM_str_hash_max_items: the load-factor limit, whatever the
        /// `max_items` field currently says.
        fn loadLimit(official_size: u32) u32 {
            return official_size / 4 * 3;
        }

        /// MVM_str_hash_allocated_items.
        pub fn allocatedItems(header: *Header) u32 {
            return officialSize(header) + ctrl(header).max_probe_distance_limit - 1;
        }

        /// MVM_str_hash_kompromat: the buckets in use.
        fn kompromat(header: *Header) u32 {
            if (header.cur_items == 0) return 0;
            return officialSize(header) + ctrl(header).max_probe_distance - 1;
        }

        fn metadata(header: *Header) [*]u8 {
            return @as([*]u8, @ptrCast(header)) + control_size;
        }

        /// Bucket `i`'s entry.
        fn entryAtIndex(header: *Header, i: u32) [*]u8 {
            return @as([*]u8, @ptrCast(header)) - entrySize(header) * (i + 1);
        }

        fn keyAt(entry: [*]u8) Key {
            return std.mem.bytesToValue(Key, entry[0..key_size]);
        }

        /// One unsigned load and compare of the key bytes (not a byte
        /// chain). Lookups apply it only after a metadata match, where the
        /// C compares the key directly (a zero key exists only between an
        /// insert and the caller filling the key in).
        fn isZeroKey(entry: [*]u8) bool {
            return std.mem.bytesToValue(KeyBits, entry[0..key_size]) == 0;
        }

        // The make-room and back-shift memmoves of str_hash_table.c. Two-
        // pointer entries, the common size (the C's `sizeof(MVMHashEntry)`
        // fast path, str_hash_table.c:419), are copied 16 bytes at a time
        // inline, walking a pointer from `entry` so that the copy needs no
        // address arithmetic carried through the probe loop; other sizes go
        // to `@memmove`. `entry_size` is comptime-known for every Spec but
        // the string table's, so the test folds away there.

        /// Make room at `entry`: the `n` entries at and below `entry` (in
        /// memory) move one entry downwards, lowest first.
        inline fn shiftDown(entry: [*]u8, n: usize, entry_size: usize) void {
            const size = entry_size * n;
            const dest = entry - size;
            if (entry_size == 16) {
                var p: [*]align(8) u8 = @alignCast(dest);
                for (0..n) |_| {
                    p[0..16].* = (p + 16)[0..16].*;
                    p += 16;
                }
            } else {
                @memmove(dest[0..size], (dest + entry_size)[0..size]);
            }
        }

        /// Close the gap at `entry`: the `n` entries below it (in memory)
        /// move one entry upwards, highest first.
        inline fn shiftUp(entry: [*]u8, n: usize, entry_size: usize) void {
            if (entry_size == 16) {
                var p: [*]align(8) u8 = @alignCast(entry);
                for (0..n) |_| {
                    p[0..16].* = (p - 16)[0..16].*;
                    p -= 16;
                }
            } else {
                const size = entry_size * n;
                const src = entry - size;
                @memmove((src + entry_size)[0..size], src[0..size]);
            }
        }

        /// Copies one entry (no overlap), inline for 16 bytes.
        inline fn copyEntry(dest: [*]u8, src: [*]const u8, entry_size: usize) void {
            if (entry_size == 16) dest[0..16].* = src[0..16].* else @memcpy(dest[0..entry_size], src[0..entry_size]);
        }

        fn blockSize(entry_size: usize, allocated_items: u32) usize {
            return entry_size * allocated_items + control_size + roundUp8(allocated_items + 1);
        }

        pub fn blockStart(header: *Header) [*]u8 {
            return @as([*]u8, @ptrCast(header)) - entrySize(header) * allocatedItems(header);
        }

        pub fn allocatedSize(header: *Header) usize {
            return blockSize(entrySize(header), allocatedItems(header));
        }

        // ------------------------------------------------- allocation

        /// hash_allocate_common (str_hash_table.c:111-157) minus the salt
        /// draw: an empty table of 2^`official_size_log2` official slots.
        fn allocate(allocator: std.mem.Allocator, header_init: Header, official_size_log2: u8) !*Header {
            const entry_size = if (Spec.runtime_entry_size) header_init.entry_size else Spec.entry_size;
            std.debug.assert(entry_size != 0 and entry_size % 8 == 0);
            std.debug.assert(official_size_log2 >= min_size_log2 and official_size_log2 < 32);
            const official_size = @as(u32, 1) << @intCast(official_size_log2);
            const max_items = loadLimit(official_size);
            const limit: u8 = @intCast(@min(max_probe_distance_cap, max_items));
            const allocated_items = official_size + limit - 1;
            const entries_size = entry_size * allocated_items;
            const total_size = blockSize(entry_size, allocated_items);
            std.debug.assert(total_size == roundUp8(total_size));

            const block = try allocator.alignedAlloc(u8, .@"8", total_size);
            const header: *Header = @ptrCast(@alignCast(block.ptr + entries_size));
            header.* = header_init;
            header.cur_items = 0;
            const c = ctrl(header);
            c.salt = 0;
            c.max_items = max_items;
            c.official_size_log2 = official_size_log2;
            c.metadata_hash_bits = initial_bits_in_metadata;
            const initial_probe_distance = (@as(u8, 1) << (8 - initial_bits_in_metadata)) - 1;
            c.max_probe_distance = @min(limit, initial_probe_distance);
            c.max_probe_distance_limit = limit;
            const bucket_right_shift = 64 - official_size_log2;
            c.key_right_shift = bucket_right_shift - c.metadata_hash_bits;
            @memset(metadata(header)[0..roundUp8(allocated_items + 1)], 0);
            return header;
        }

        fn free(header: *Header, allocator: std.mem.Allocator) void {
            const block: [*]align(8) u8 = @alignCast(blockStart(header));
            allocator.free(block[0..allocatedSize(header)]);
        }

        /// MVM_str_hash_build's sizing (str_hash_table.c:178-186): the
        /// smallest power of two at or above `cap / 0.75`, at least 2^3.
        pub fn init(allocator: std.mem.Allocator, header_init: Header, cap: u32) !*Header {
            const min_needed = @max(@as(u64, cap) * 4 / 3, 1);
            const log2 = @max(std.math.log2_int_ceil(u64, min_needed), min_size_log2);
            return allocate(allocator, header_init, @intCast(log2));
        }

        /// The load-factor limit (the C `max_items` before any probe-limit
        /// flagging).
        pub fn capacity(header: *Header) u32 {
            return loadLimit(officialSize(header));
        }

        /// The C's "cur_items >= max_items": also true after an insert
        /// reached the probe limit and zeroed `max_items`.
        pub fn isFull(header: *Header) bool {
            return header.cur_items >= ctrl(header).max_items;
        }

        pub fn setSalt(header: *Header, value: u64) void {
            if (salt_mode == .engine) ctrl(header).salt = value;
        }

        pub fn salt(header: *Header) u64 {
            return if (salt_mode == .engine) ctrl(header).salt else 0;
        }

        pub fn hash(ctx: Ctx, key: Key) u64 {
            return Spec.hash(ctx, key);
        }

        // ---------------------------------------------------- probing

        /// MVM_str_hash_code's mixing of the key's hash with the salt.
        fn bucketHash(c: *const Control, h: u64) u64 {
            const salted = if (salt_mode == .engine) h ^ c.salt else h;
            return salted *% fibonacci;
        }

        /// The ideal bucket of hash `h` (the top `official_size_log2` bits).
        fn idealBucket(header: *Header, h: u64) u32 {
            const c = ctrl(header);
            const bucket_right_shift: u6 = @intCast(@as(u32, c.key_right_shift) + c.metadata_hash_bits);
            return @intCast(bucketHash(c, h) >> bucket_right_shift);
        }

        /// MVM_hash_loop_state.
        const LoopState = struct {
            entry: [*]u8,
            metadata: [*]u8,
            increment: u32,
            shift: u5,
            max_probe_distance: u32,
            probe_distance: u32,
            entry_size: usize,

            fn advance(ls: *LoopState) void {
                ls.probe_distance += ls.increment;
                ls.metadata += 1;
                ls.entry -= ls.entry_size;
            }
        };

        /// MVM_str_hash_create_loop_state (str_hash_table_funcs.h:158-182).
        fn loopState(header: *Header, h: u64) LoopState {
            const c = ctrl(header);
            const bits: u5 = @intCast(c.metadata_hash_bits);
            const increment = @as(u32, 1) << bits;
            const used_hash_bits: u32 = @truncate(bucketHash(c, h) >> @as(u6, @intCast(c.key_right_shift)));
            const bucket = used_hash_bits >> bits;
            const entry_size = entrySize(header);
            return .{
                .entry = entryAtIndex(header, bucket),
                .metadata = metadata(header) + bucket,
                .increment = increment,
                .shift = bits,
                .max_probe_distance = c.max_probe_distance,
                .probe_distance = increment | (used_hash_bits & (increment - 1)),
                .entry_size = entry_size,
            };
        }

        /// MVM_str_hash_fetch_nocheck (str_hash_table_funcs.h:184-320).
        pub fn fetch(header: *Header, ctx: Ctx, key: Key, h: u64) ?[*]u8 {
            if (header.cur_items == 0) return null;
            var ls = loopState(header, h);
            while (true) : (ls.advance()) {
                const md = ls.metadata[0];
                if (md == ls.probe_distance) {
                    if (!isZeroKey(ls.entry) and Spec.eql(ctx, keyAt(ls.entry), key)) return ls.entry;
                } else if (md < ls.probe_distance) {
                    // Empty, or an entry that would have been displaced had
                    // the key been inserted; the sentinel ends the loop.
                    return null;
                }
            }
        }

        /// Takes the slot `ls` stopped at (its metadata below the probe
        /// distance) for a new entry: makes room by shifting the following
        /// entries along by one, flags a growth if a probe distance reached
        /// the limit, counts the entry and writes its metadata. Returns the
        /// entry, whose bytes the caller then writes.
        inline fn takeSlot(header: *Header, c: *Control, ls: *const LoopState, md: u8) [*]u8 {
            if (md != 0) {
                // Make room: the following entries keep their relative
                // order, so bump every probe distance by one and move the
                // block of entries along.
                var gap = ls.metadata;
                var old_probe_distance: u32 = md;
                while (true) {
                    const new_probe_distance = ls.increment + old_probe_distance;
                    std.debug.assert(new_probe_distance >> ls.shift <= ls.max_probe_distance);
                    if (new_probe_distance >> ls.shift == ls.max_probe_distance) {
                        // Force a growth before the next insert, so this
                        // loop never has to handle overflow.
                        c.max_items = 0;
                    }
                    gap += 1;
                    old_probe_distance = gap[0];
                    gap[0] = @intCast(new_probe_distance);
                    if (old_probe_distance == 0) break;
                }
                const entries_to_move = @intFromPtr(gap) - @intFromPtr(ls.metadata);
                // Entries descend in memory: move everything at and before
                // `ls.entry` one entry downwards.
                shiftDown(ls.entry, entries_to_move, ls.entry_size);
            }
            if (ls.probe_distance >> ls.shift == ls.max_probe_distance) c.max_items = 0;
            header.cur_items += 1;
            ls.metadata[0] = @intCast(ls.probe_distance);
            return ls.entry;
        }

        /// hash_insert_internal (str_hash_table.c:211-319): find or insert,
        /// making room by shifting the following entries along by one. The
        /// caller guarantees the table is not full.
        fn insertInternal(header: *Header, ctx: Ctx, key: Key, h: u64) [*]u8 {
            const c = ctrl(header);
            std.debug.assert(header.cur_items < c.max_items);
            var ls = loopState(header, h);
            while (true) : (ls.advance()) {
                const md = ls.metadata[0];
                if (md < ls.probe_distance) {
                    // This is our slot, occupied or not.
                    const e = takeSlot(header, c, &ls, md);
                    @memset(e[0..key_size], 0);
                    return e;
                } else if (md == ls.probe_distance) {
                    if (!isZeroKey(ls.entry) and Spec.eql(ctx, keyAt(ls.entry), key)) return ls.entry;
                }
            }
        }

        /// `insertInternal` for a key known to be absent, with its entry
        /// already built: the policy layer's migration, whose keys come
        /// from one table and are distinct. The same probe and make-room,
        /// without the key compare (the probe stops at the first slot whose
        /// metadata is below the probe distance) and without the load check,
        /// which the caller makes (`isFull`, then `grow`). Copies the
        /// `entry_bytes` (key included) into the slot once.
        pub fn insertKnownAbsent(header: *Header, ctx: Ctx, key: Key, h: u64, entry_bytes: [*]const u8) void {
            const c = ctrl(header);
            std.debug.assert(header.cur_items < c.max_items);
            if (std.lang.Optimize.runtimeSafety(@import("builtin").mode)) std.debug.assert(fetch(header, ctx, key, h) == null);
            var ls = loopState(header, h);
            while (true) : (ls.advance()) {
                const md = ls.metadata[0];
                if (md < ls.probe_distance) {
                    copyEntry(takeSlot(header, c, &ls, md), entry_bytes, ls.entry_size);
                    return;
                }
            }
        }

        /// MVM_str_hash_lvalue_fetch_nocheck (str_hash_table.c:454-497)
        /// minus the growth, which the policy layer drives through `grow`.
        pub fn lvalueFetch(header: *Header, ctx: Ctx, key: Key, h: u64) LvalueResult {
            if (isFull(header)) {
                // Never grow for a key that is present.
                if (fetch(header, ctx, key, h)) |e| return .{ .found = e };
                return .full;
            }
            const before = header.cur_items;
            const e = insertInternal(header, ctx, key, h);
            return if (header.cur_items == before) .{ .found = e } else .{ .inserted = e };
        }

        /// MVM_str_hash_delete_nocheck (str_hash_table.c:520-697): backward
        /// shift of the following entries, and the `max_items == 0` repair.
        pub fn delete(header: *Header, ctx: Ctx, key: Key, h: u64) bool {
            if (header.cur_items == 0) return false;
            const c = ctrl(header);
            var ls = loopState(header, h);
            while (true) : (ls.advance()) {
                const md = ls.metadata[0];
                if (md == ls.probe_distance) {
                    if (isZeroKey(ls.entry) or !Spec.eql(ctx, keyAt(ls.entry), key)) continue;
                    // Target acquired: pull every following entry with a
                    // probe distance of at least 2 back by one.
                    var target = ls.metadata;
                    var old_probe_distance: u32 = target[1];
                    const can_move = 2 * ls.increment;
                    while (old_probe_distance >= can_move) {
                        target[0] = @intCast(old_probe_distance - ls.increment);
                        target += 1;
                        old_probe_distance = target[1];
                    }
                    const entries_to_move = @intFromPtr(target) - @intFromPtr(ls.metadata);
                    if (entries_to_move != 0) {
                        // Move everything before `ls.entry` one entry upwards
                        // to close the gap.
                        shiftUp(ls.entry, entries_to_move, ls.entry_size);
                    }
                    target[0] = 0;
                    header.cur_items -= 1;
                    if (c.max_items == 0 and header.cur_items < c.max_probe_distance) {
                        // An insert reached the probe limit and flagged a
                        // growth that never came; with fewer entries than
                        // the limit no chain can reach it, so unflag
                        // (str_hash_table.c:580-656).
                        c.max_items = loadLimit(officialSize(header));
                    }
                    return true;
                } else if (md < ls.probe_distance) {
                    return false;
                }
            }
        }

        // ----------------------------------------------------- growth

        /// maybe_grow_hash (str_hash_table.c:321-452) minus publication:
        /// below the load limit and the probe limit, trades one metadata
        /// hash bit for double the probe distance in place and returns the
        /// same header; otherwise doubles, reinserting every entry, and
        /// returns the new header, leaving the old block untouched and
        /// allocated for the caller to dispose of through `blockStart(old)`
        /// and `allocatedSize(old)` once the new header is published. Never
        /// returns null. `ctx` is needed to rehash the keys.
        pub fn grow(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !?*Header {
            return try growInner(header, ctx, allocator);
        }

        fn growInner(header: *Header, ctx: Ctx, allocator: std.mem.Allocator) !*Header {
            const c = ctrl(header);
            // `max_items` may be 0 to have forced this call.
            const max_items = loadLimit(officialSize(header));
            if (header.cur_items < max_items and c.max_probe_distance < c.max_probe_distance_limit) {
                // The probe limit, not the load limit: one more probe bit.
                const new_probe_distance: u8 = @intCast(@min(1 + 2 * @as(u32, c.max_probe_distance), c.max_probe_distance_limit));
                const in_use_items = officialSize(header) + c.max_probe_distance;
                // Right shift each byte by one, clearing the top bit; the
                // sentinel need not move.
                const words: [*]u64 = @ptrCast(@alignCast(metadata(header)));
                for (words[0 .. roundUp8(in_use_items) / 8]) |*w| w.* = (w.* >> 1) & 0x7F7F7F7F7F7F7F7F;
                std.debug.assert(c.metadata_hash_bits != 0);
                c.metadata_hash_bits -= 1;
                c.key_right_shift += 1;
                c.max_probe_distance = new_probe_distance;
                c.max_items = max_items;
                return header;
            }

            const entries_in_use = kompromat(header);
            const entry_size = entrySize(header);
            var new = try allocate(allocator, header.*, c.official_size_log2 + 1);
            errdefer free(new, allocator);
            ctrl(new).salt = c.salt;
            const md = metadata(header);
            var bucket: u32 = 0;
            while (bucket < entries_in_use) : (bucket += 1) {
                if (md[bucket] == 0) continue;
                const old_entry = entryAtIndex(header, bucket);
                // A key the caller has not filled in yet cannot be hashed;
                // the C never meets one here.
                if (isZeroKey(old_entry)) continue;
                const key = keyAt(old_entry);
                const new_entry = insertInternal(new, ctx, key, Spec.hash(ctx, key));
                copyEntry(new_entry, old_entry, entry_size);
                // Probably the probe limit; possibly one doubling was not
                // enough. An intermediate block is ours to free.
                if (ctrl(new).max_items == 0) {
                    const bigger = try growInner(new, ctx, allocator);
                    if (bigger != new) {
                        free(new, allocator);
                        new = bigger;
                    }
                }
            }
            std.debug.assert(ctrl(new).max_items != 0);
            return new;
        }

        // -------------------------------------------------- iteration

        /// MVM_str_hash_first (str_hash_table_funcs.h:460-497).
        pub fn first(header: *Header) u32 {
            if (header.cur_items == 0) return 0;
            const pos = kompromat(header);
            if (metadata(header)[pos - 1] != 0) return pos;
            return next(header, pos);
        }

        /// MVM_str_hash_next_nocheck (str_hash_table_funcs.h:411-428).
        pub fn next(header: *Header, pos: u32) u32 {
            const md = metadata(header);
            var p = pos;
            while (true) {
                p -= 1;
                if (p == 0 or md[p - 1] != 0) return p;
            }
        }

        /// MVM_str_hash_current_nocheck (str_hash_table_funcs.h:549-560).
        pub fn entryAt(header: *Header, pos: u32) [*]u8 {
            std.debug.assert(metadata(header)[pos - 1] != 0);
            return entryAtIndex(header, pos - 1);
        }

        /// MVM_str_hash_start (str_hash_table_funcs.h:499-521).
        pub fn start(header: *Header) u32 {
            return kompromat(header) + 1;
        }

        pub fn drain(header: *Header, visitor: anytype) void {
            const is_fn = @typeInfo(@TypeOf(visitor)) == .@"fn";
            const md = metadata(header);
            for (0..kompromat(header)) |bucket| {
                if (md[bucket] == 0) continue;
                const e = entryAtIndex(header, @intCast(bucket));
                if (is_fn) visitor(e) else visitor.visit(e);
            }
        }

        // ------------------------------------------------------- fsck

        /// hash_fsck_internal (str_hash_table.c:700-871) without the
        /// `tc`-dependent key checks and the printing: counts live entries
        /// whose key is zero, whose metadata disagrees with their hash, or
        /// whose probe distance breaks the Robin Hood order; a non-zero
        /// sentinel; and `cur_items` disagreeing with the live count.
        pub fn fsck(header: *Header, ctx: Ctx, mode: u32) u64 {
            _ = mode;
            const c = ctrl(header);
            var errors: u64 = 0;
            var seen: u64 = 0;
            const allocated_items = allocatedItems(header);
            const bits: u5 = @intCast(c.metadata_hash_bits);
            const md = metadata(header);
            var prev_offset: i64 = 0;
            var bucket: u32 = 0;
            while (bucket < allocated_items) : (bucket += 1) {
                const m = md[bucket];
                if (m == 0) {
                    prev_offset = 0;
                    continue;
                }
                seen += 1;
                const e = entryAtIndex(header, bucket);
                if (isZeroKey(e)) {
                    // Corrupt key: its ideal bucket is unknowable.
                    errors += 1;
                    prev_offset = 0;
                    continue;
                }
                const ideal_bucket = idealBucket(header, Spec.hash(ctx, keyAt(e)));
                const offset = 1 + @as(i64, bucket) - @as(i64, ideal_bucket);
                const actual = @as(u32, m) >> bits;
                if (offset != actual) errors += 1;
                if (offset < 1 or offset > c.max_probe_distance or offset > prev_offset + 1) errors += 1;
                prev_offset = offset;
            }
            if (md[allocated_items] != 0) errors += 1;
            if (seen != header.cur_items) errors += 1;
            return errors;
        }
    };
}
// ---------------------------------------------------------------- tests

const testing = std.testing;
const IntSpec = @import("../test_spec.zig").IntSpec;
const S = Tier(.{}).Impl(IntSpec);
const test_entry_size = 16;

fn testInit(capacity: u32) !*Header {
    return S.init(testing.allocator, .{ .tier = 1, .set = 0, .entry_size = test_entry_size, .stale = 0, .cur_items = 0 }, capacity);
}

fn testFree(header: *Header) void {
    const block: [*]align(8) u8 = @alignCast(S.blockStart(header));
    testing.allocator.free(block[0..S.allocatedSize(header)]);
}

fn keyOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[0..8], .little);
}

fn fill(entry: [*]u8, key: u64) !void {
    try testing.expectEqual(@as(u64, 0), keyOf(entry));
    std.mem.writeInt(u64, entry[0..8], key, .little);
    std.mem.writeInt(u64, entry[8..16], key * 10, .little);
}

/// Insert `key` with value `key * 10`; the key must be absent and fit.
fn put(header: *Header, key: u64) !void {
    switch (S.lvalueFetch(header, {}, key, S.hash({}, key))) {
        .inserted => |e| try fill(e, key),
        else => return error.TestUnexpectedResult,
    }
}

/// `put`, growing the table (as the policy layer would) while it reports full.
fn putGrowing(header: **Header, key: u64) !void {
    while (true) {
        switch (S.lvalueFetch(header.*, {}, key, S.hash({}, key))) {
            .inserted => |e| return fill(e, key),
            .found => return error.TestUnexpectedResult,
            .full => {
                const old = header.*;
                header.* = (try S.grow(old, {}, testing.allocator)).?;
                if (header.* != old) testFree(old);
            },
        }
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

test "init rounds the capacity up to the C sizes (8 official + 5 overflow at minimum)" {
    const h = try testInit(1);
    defer testFree(h);
    try testing.expectEqual(@as(u32, 8), S.officialSize(h));
    try testing.expectEqual(@as(u32, 13), S.allocatedItems(h));
    try testing.expectEqual(@as(u32, 6), S.capacity(h));
    try testing.expect(!S.isFull(h));
    try testing.expectEqual(@as(u32, 0), S.first(h));
    try testing.expectEqual(@as(u32, 1), S.start(h));
    try testing.expectEqual(@as(?[*]u8, null), get(h, 5));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));

    const h0 = try testInit(0);
    defer testFree(h0);
    try testing.expectEqual(@as(u32, 8), S.officialSize(h0));

    // 96 / 0.75 = 128 exactly.
    const h96 = try testInit(96);
    defer testFree(h96);
    try testing.expectEqual(@as(u32, 128), S.officialSize(h96));
    try testing.expectEqual(@as(u32, 128 + 95), S.allocatedItems(h96));
    try testing.expectEqual(@as(u32, 96), S.capacity(h96));

    // 100 / 0.75 = 133, which MVM_round_up_log_base2 takes to 2^8: 128
    // official slots would hold only 96 at the load factor.
    const h100 = try testInit(100);
    defer testFree(h100);
    try testing.expectEqual(@as(u32, 256), S.officialSize(h100));
    try testing.expectEqual(@as(u32, 192), S.capacity(h100));

    // The salt is the policy layer's to set; with `.none` it stays 0.
    S.setSalt(h, 0x1234_5678_9abc_def0);
    try testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), S.salt(h));
    const N = Tier(.{ .salt = .none }).Impl(IntSpec);
    const hn = try N.init(testing.allocator, .{ .tier = 1, .set = 0, .entry_size = test_entry_size, .stale = 0, .cur_items = 0 }, 1);
    defer {
        const block: [*]align(8) u8 = @alignCast(N.blockStart(hn));
        testing.allocator.free(block[0..N.allocatedSize(hn)]);
    }
    N.setSalt(hn, 0x1234_5678_9abc_def0);
    try testing.expectEqual(@as(u64, 0), N.salt(hn));
}

test "insert, fetch, miss, delete, count across a growth" {
    var h = try testInit(1);
    defer testFree(h);
    S.setSalt(h, 0x9e37_79b9_7f4a_7c15);
    for (1..1001) |k| try putGrowing(&h, k);
    try testing.expectEqual(@as(u32, 1000), h.cur_items);
    try testing.expectEqual(@as(u64, 0x9e37_79b9_7f4a_7c15), S.salt(h));
    // 1000 / 0.75 = 1333 -> 2048 official, reached by doubling.
    try testing.expectEqual(@as(u32, 2048), S.officialSize(h));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    for (1..1001) |k| try testing.expectEqual(@as(u64, k * 10), std.mem.readInt(u64, get(h, k).?[8..16], .little));
    for (1001..1101) |k| try testing.expectEqual(@as(?[*]u8, null), get(h, k));
    try testing.expect(S.lvalueFetch(h, {}, 7, S.hash({}, 7)) == .found);
    for (1..501) |k| try testing.expect(del(h, k));
    for (1..501) |k| try testing.expect(!del(h, k));
    try testing.expectEqual(@as(u32, 500), h.cur_items);
    for (1..501) |k| try testing.expectEqual(@as(?[*]u8, null), get(h, k));
    for (501..1001) |k| try testing.expectEqual(@as(u64, k), keyOf(get(h, k).?));
    try testing.expectEqual(@as(u32, 500), countByIteration(h));
    const Summer = struct {
        sum: u64 = 0,
        n: u32 = 0,
        fn visit(self: *@This(), e: [*]u8) void {
            self.sum += keyOf(e);
            self.n += 1;
        }
    };
    var summer = Summer{};
    S.drain(h, &summer);
    try testing.expectEqual(@as(u32, 500), summer.n);
    try testing.expectEqual(@as(u64, (501 + 1000) * 500 / 2), summer.sum);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "probe-limit growth trades a metadata bit before doubling" {
    // 12 / 0.75 = 16 official: max_items 12, probe limit 12, initial max
    // probe distance 7 (5 hash bits in the metadata). The 8 + 5 table can
    // never trade (its limit, 6, is already below 7).
    var h = try testInit(12);
    defer testFree(h);
    try testing.expectEqual(@as(u32, 16), S.officialSize(h));
    try testing.expectEqual(@as(u8, 7), S.ctrl(h).max_probe_distance);
    try testing.expectEqual(@as(u8, 12), S.ctrl(h).max_probe_distance_limit);
    try testing.expectEqual(@as(u8, 5), S.ctrl(h).metadata_hash_bits);

    // Seven keys contesting one ideal bucket put one of them at probe
    // distance 7, the limit, which flags the table full.
    var keys: [8]u64 = undefined;
    var n: usize = 0;
    const want = S.idealBucket(h, S.hash({}, 1));
    var k: u64 = 1;
    while (n < keys.len) : (k += 1) {
        if (S.idealBucket(h, S.hash({}, k)) == want) {
            keys[n] = k;
            n += 1;
        }
    }
    for (keys[0..7]) |key| try put(h, key);
    try testing.expectEqual(@as(u32, 7), h.cur_items);
    try testing.expect(S.isFull(h));
    try testing.expect(S.lvalueFetch(h, {}, keys[7], S.hash({}, keys[7])) == .full);
    try testing.expect(S.lvalueFetch(h, {}, keys[3], S.hash({}, keys[3])) == .found);

    const grown = (try S.grow(h, {}, testing.allocator)).?;
    try testing.expectEqual(h, grown);
    try testing.expectEqual(@as(u32, 16), S.officialSize(h));
    try testing.expectEqual(@as(u8, 4), S.ctrl(h).metadata_hash_bits);
    try testing.expectEqual(@as(u8, 12), S.ctrl(h).max_probe_distance);
    try testing.expectEqual(@as(u32, 12), S.capacity(h));
    try testing.expect(!S.isFull(h));
    for (keys[0..7]) |key| try testing.expectEqual(key, keyOf(get(h, key).?));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    try put(h, keys[7]);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));

    // Past the load limit the next growth doubles.
    k = 1000;
    while (S.officialSize(h) == 16) : (k += 1) try putGrowing(&h, k);
    try testing.expectEqual(@as(u32, 32), S.officialSize(h));
    // The new table starts with 5 hash bits again, but reinserting keys that
    // still share an ideal bucket can hit its probe limit and trade one bit
    // during the doubling (str_hash_table.c:432-443).
    try testing.expect(S.ctrl(h).metadata_hash_bits <= 5);
    try testing.expectEqual(@as(u32, 24), S.capacity(h));
    for (keys) |key| try testing.expectEqual(key, keyOf(get(h, key).?));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "insertKnownAbsent lays out the same table as insertInternal" {
    // The same keys in the same order, one table through `lvalueFetch` and
    // a fill, the other through `insertKnownAbsent` with built entries,
    // both growing when full: the same probe, make-room and probe-limit
    // flagging must give the same geometry, metadata and entries. Eight
    // keys sharing one ideal bucket go first, to reach the probe limit
    // (the metadata-bit trade) on the way.
    var a = try testInit(12);
    defer testFree(a);
    var b = try testInit(12);
    defer testFree(b);
    var keys: [208]u64 = undefined;
    var n: usize = 0;
    const want = S.idealBucket(a, S.hash({}, 1));
    var k: u64 = 1;
    while (n < 8) : (k += 1) {
        if (S.idealBucket(a, S.hash({}, k)) == want) {
            keys[n] = k;
            n += 1;
        }
    }
    for (keys[8..], 5000..) |*key, i| key.* = i;
    var traded = false;
    for (keys) |key| {
        try putGrowing(&a, key);
        if (S.isFull(b)) {
            const old = b;
            b = (try S.grow(old, {}, testing.allocator)).?;
            if (b != old) testFree(old) else traded = true;
        }
        var entry: [test_entry_size]u8 = undefined;
        std.mem.writeInt(u64, entry[0..8], key, .little);
        std.mem.writeInt(u64, entry[8..16], key * 10, .little);
        S.insertKnownAbsent(b, {}, key, S.hash({}, key), &entry);
    }
    try testing.expect(traded);
    try testing.expectEqual(S.officialSize(a), S.officialSize(b));
    try testing.expectEqual(a.cur_items, b.cur_items);
    try testing.expectEqual(S.ctrl(a).max_items, S.ctrl(b).max_items);
    try testing.expectEqual(S.ctrl(a).max_probe_distance, S.ctrl(b).max_probe_distance);
    try testing.expectEqual(S.ctrl(a).metadata_hash_bits, S.ctrl(b).metadata_hash_bits);
    const ma = S.metadata(a);
    const mb = S.metadata(b);
    for (0..S.allocatedItems(a) + 1) |i| {
        try testing.expectEqual(ma[i], mb[i]);
        if (ma[i] == 0 or i == S.allocatedItems(a)) continue;
        const ea = S.entryAtIndex(a, @intCast(i));
        const eb = S.entryAtIndex(b, @intCast(i));
        try testing.expectEqualSlices(u8, ea[0..test_entry_size], eb[0..test_entry_size]);
    }
    try testing.expectEqual(@as(u64, 0), S.fsck(b, {}, 0));
    for (keys) |key| try testing.expectEqual(key * 10, std.mem.readInt(u64, get(b, key).?[8..16], .little));
}

test "delete-current while holding next visits every remaining entry once" {
    const h = try testInit(300);
    defer testFree(h);
    for (1..301) |k| try put(h, k);
    var seen = @as([301]u32, @splat(0));
    var pos = S.first(h);
    var i: u32 = 0;
    while (pos != 0) : (i += 1) {
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
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    try testing.expectEqual(S.start(h), S.officialSize(h) + S.ctrl(h).max_probe_distance);
}

test "fsck reports no errors on a consistent table" {
    var h = try testInit(1);
    defer testFree(h);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    for (1..201) |k| try putGrowing(&h, k);
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    var k: u64 = 2;
    while (k <= 200) : (k += 2) try testing.expect(del(h, k));
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));

    // A corrupted probe distance is reported, and only that.
    const pos = S.first(h);
    const md = S.metadata(h) + (pos - 1);
    const saved = md[0];
    md[0] +%= 1 << 5;
    try testing.expect(S.fsck(h, {}, 0) > 0);
    md[0] = saved;
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
    md[0] = 0;
    try testing.expect(S.fsck(h, {}, 0) > 0);
    md[0] = saved;
    try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
}

test "make-room and back-shift move runs of entries intact, 16-byte and generic sizes" {
    // 16 takes the inline two-word copies, 24 the `@memmove` fallback.
    inline for (.{ 16, 24 }) |es| {
        var h = try S.init(testing.allocator, .{ .tier = 1, .set = 0, .entry_size = es, .stale = 0, .cur_items = 0 }, 96);
        defer testFree(h);
        const n: u64 = 300;
        for (1..n + 1) |k| {
            while (true) {
                switch (S.lvalueFetch(h, {}, k, S.hash({}, k))) {
                    .inserted => |e| {
                        try testing.expectEqual(@as(u64, 0), keyOf(e));
                        for (0..es / 8) |w| std.mem.writeInt(u64, e[w * 8 ..][0..8], k * 10 + w, .little);
                        std.mem.writeInt(u64, e[0..8], k, .little);
                        break;
                    },
                    .found => return error.TestUnexpectedResult,
                    .full => {
                        const old = h;
                        h = (try S.grow(old, {}, testing.allocator)).?;
                        if (h != old) testFree(old);
                    },
                }
            }
        }
        try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
        var longest_shift: u32 = 0;
        // Delete in an order unrelated to the buckets, checking everything
        // after each delete.
        for (0..n) |i| {
            const k = i * 97 % n + 1;
            const e = get(h, k).?;
            const bucket: u32 = @intCast((@intFromPtr(h) - @intFromPtr(e)) / es - 1);
            const md = S.metadata(h);
            const can_move = 2 * (@as(u32, 1) << @intCast(S.ctrl(h).metadata_hash_bits));
            var run: u32 = 0;
            while (md[bucket + 1 + run] >= can_move) run += 1;
            longest_shift = @max(longest_shift, run);
            try testing.expect(del(h, k));
            try testing.expectEqual(@as(?[*]u8, null), get(h, k));
            try testing.expectEqual(@as(u64, 0), S.fsck(h, {}, 0));
            var pos = S.first(h);
            while (pos != 0) : (pos = S.next(h, pos)) {
                const live = S.entryAt(h, pos);
                const key = keyOf(live);
                try testing.expectEqual(@as(?[*]u8, live), get(h, key));
                for (1..es / 8) |w| try testing.expectEqual(key * 10 + w, std.mem.readInt(u64, live[w * 8 ..][0..8], .little));
            }
        }
        try testing.expectEqual(@as(u32, 0), h.cur_items);
        try testing.expect(longest_shift >= 3);
    }
}
