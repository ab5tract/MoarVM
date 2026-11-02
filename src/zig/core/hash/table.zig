//! The policy layer of the Zig hash engine (spec 4.1-4.4): `Table(Spec)`
//! owns the control-block header, runs a table through its tier set, grows
//! and migrates, publishes new blocks, dispatches iteration and calls the
//! reserved log hook. Tiers (`tiers/`) know nothing of each other or of
//! publication; the C API files know nothing of tiers.
//!
//! The Spec contract (everything is required unless marked otherwise):
//!
//!     Key: type                 stored at the start of every entry
//!     Ctx: type                 what the C API passes along (`tc`, ...)
//!     hash(ctx, key) u64
//!     eql(ctx, a, b) bool
//!     runtime_entry_size: bool  true: the entry size is the header's byte,
//!                               given to `build`; false: `entry_size: u32`
//!                               is a Spec constant and the byte is unused
//!     allocator(ctx) Allocator  block memory. Under `.safepoint_cas` it must
//!                               be MVM_malloc-backed, because
//!                               `MVM_free_at_safepoint` frees with MVM_free
//!     publish                   `.plain`: a grown table is stored and the
//!                               old block freed at once (tests, single
//!                               owner); `.safepoint_cas`: the C discipline,
//!                               `old.stale = 1`, `MVM_free_at_safepoint`,
//!                               `MVM_trycas`, `MVM_oops` on a lost race
//!     tc(ctx) *ThreadContext    `.safepoint_cas` only
//!     salt(ctx) u64             the salt of every new Robin Hood block;
//!                               required under `.safepoint_cas`, optional
//!                               otherwise (the salt is 0 without it)
//!     sets: []const TierSet     indexed by the header's `set` byte; each
//!                               set passes `tier.validate`
//!     onDuplicate(ctx) void     `insert` of a present key (StrSpec's
//!                               `MVM_oops`es and never returns)
//!
//! A `Handle` is the address of the C struct's one pointer
//! (`MVMStrHashTable.table`): null is unbuilt. The control-only state of a
//! table built for 0 entries (spec 4.2) is a bare `Header` with no tier
//! payload, marked by `control_only_bit` in `Header.tier`; the rung below
//! the bit is the starting rung, which the first insert allocates and
//! publishes. Readers treat it as empty.
//!
//! Block ownership: tiers never free. When `grow` returns a different header
//! or a migration builds a new rung, `publish` retires the old block:
//! `.plain` frees it through `Spec.allocator`, `.safepoint_cas` does what
//! `src/core/str_hash_table.c:398, 479-487` do (`MVM_free_at_safepoint` is
//! `moar.freeAtSafepoint`). `demolish` frees a
//! control-only block plainly in both modes (`str_hash_table.c:29-44`).
//!
//! Stale checks (`.safepoint_cas` only; comptime no-ops otherwise) guard the
//! functions that take a `ctx` on entry and, for mutators, on exit. The
//! `ctx`-less readers (`count`, `first`, ...) cannot `MVM_oops` without a
//! `tc` and leave the check to the C API layer, which has one.
//!
//! The `moar` module is imported lazily inside the `.safepoint_cas`
//! branches, so this file is a standalone `zig test` root for `.plain`
//! Specs and only Specs that publish through safepoints need the module.
const std = @import("std");
const tier = @import("tier.zig");

pub const Header = tier.Header;
pub const Publish = enum { plain, safepoint_cas };

/// Set in `Header.tier` of a control-only block (see the file comment).
pub const control_only_bit: u8 = 0x80;

const oom_msg = "hash table: allocation failed";

pub fn Table(comptime Spec: type) type {
    comptime {
        if (Spec.sets.len == 0) @compileError("Table: Spec.sets is empty");
        if (Spec.sets.len > 256) @compileError("Table: at most 256 tier sets");
        for (Spec.sets) |set| {
            tier.validate(set);
            if (set.len > control_only_bit) @compileError("Table: at most 128 rungs in a tier set");
        }
        if (@as(Publish, Spec.publish) == .safepoint_cas) {
            if (!@hasDecl(Spec, "tc")) @compileError("Table: a .safepoint_cas Spec needs tc(ctx)");
            if (!@hasDecl(Spec, "salt")) @compileError("Table: a .safepoint_cas Spec needs salt(ctx)");
        }
    }
    return struct {
        pub const Handle = *?*Header;
        pub const Key = Spec.Key;
        pub const Ctx = Spec.Ctx;

        const publish_mode: Publish = Spec.publish;
        const key_size = @sizeOf(Key);
        const Block = []align(8) u8;
        const Lvalue = union(enum) { found: [*]u8, inserted: [*]u8, full };

        // ------------------------------------------------- failure paths

        fn fail(ctx: Ctx, comptime msg: [:0]const u8) noreturn {
            if (comptime publish_mode == .safepoint_cas) {
                const moar = @import("moar");
                moar.c.MVM_oops(Spec.tc(ctx), msg.ptr);
            } else {
                @panic(msg);
            }
        }

        fn checkStale(ctx: Ctx, header: *Header, comptime who: []const u8) void {
            if (comptime publish_mode == .safepoint_cas) {
                if (@as(*volatile u8, &header.stale).* != 0)
                    fail(ctx, "hash table " ++ who ++ " called with a stale hashtable pointer");
            }
        }

        fn checkTurnedStale(ctx: Ctx, header: *Header, comptime who: []const u8) void {
            if (comptime publish_mode == .safepoint_cas) {
                if (@as(*volatile u8, &header.stale).* != 0)
                    fail(ctx, "hash table " ++ who ++ " called with a hashtable pointer that turned stale");
            }
        }

        // ------------------------------------------------------ dispatch

        fn rungOf(header: *const Header) u8 {
            return header.tier & ~control_only_bit;
        }

        fn isControlOnly(header: *const Header) bool {
            return header.tier & control_only_bit != 0;
        }

        fn entrySizeOf(header: *const Header) usize {
            return if (Spec.runtime_entry_size) header.entry_size else Spec.entry_size;
        }

        /// Resolves the runtime pair (set index, rung index) to comptime
        /// values and returns `op(set, rung_index, args)`.
        fn resolve(comptime R: type, set_index: u8, rung_index: u8, comptime op: anytype, args: anytype) R {
            inline for (Spec.sets, 0..) |set, si| {
                if (set_index == si) {
                    inline for (0..set.len) |ri| {
                        if (rung_index == ri) return op(set, ri, args);
                    }
                    unreachable; // the rung is not in the set
                }
            }
            unreachable; // the set index is not in Spec.sets
        }

        /// Returns `op(Impl, header, args)` for the rung of `header`.
        fn dispatch(comptime R: type, header: *Header, comptime op: anytype, args: anytype) R {
            std.debug.assert(!isControlOnly(header));
            const Op = struct {
                fn f(comptime set: tier.TierSet, comptime ri: usize, a: anytype) R {
                    return op(set[ri].tier.Impl(Spec), a[0], a[1]);
                }
            };
            return resolve(R, header.set, rungOf(header), Op.f, .{ header, args });
        }

        const ops = struct {
            fn fetch(comptime I: type, header: *Header, a: anytype) ?[*]u8 {
                return I.fetch(header, a[0], a[1], I.hash(a[0], a[1]));
            }
            fn lvalue(comptime I: type, header: *Header, a: anytype) Lvalue {
                return switch (I.lvalueFetch(header, a[0], a[1], I.hash(a[0], a[1]))) {
                    .found => |e| .{ .found = e },
                    .inserted => |e| .{ .inserted = e },
                    .full => .full,
                };
            }
            fn delete(comptime I: type, header: *Header, a: anytype) bool {
                return I.delete(header, a[0], a[1], I.hash(a[0], a[1]));
            }
            fn grow(comptime I: type, header: *Header, a: anytype) ?*Header {
                return I.grow(header, a[0], Spec.allocator(a[0])) catch fail(a[0], oom_msg);
            }
            fn first(comptime I: type, header: *Header, _: anytype) u32 {
                return I.first(header);
            }
            fn next(comptime I: type, header: *Header, a: anytype) u32 {
                return I.next(header, a[0]);
            }
            fn entryAt(comptime I: type, header: *Header, a: anytype) [*]u8 {
                return I.entryAt(header, a[0]);
            }
            fn start(comptime I: type, header: *Header, _: anytype) u32 {
                return I.start(header);
            }
            fn blockStart(comptime I: type, header: *Header, _: anytype) [*]u8 {
                return I.blockStart(header);
            }
            fn allocatedSize(comptime I: type, header: *Header, _: anytype) usize {
                return I.allocatedSize(header);
            }
            fn fsck(comptime I: type, header: *Header, a: anytype) u64 {
                return I.fsck(header, a[0], a[1]);
            }
            fn drain(comptime I: type, header: *Header, a: anytype) void {
                I.drain(header, a[0]);
            }
        };

        fn log(header: *Header, op: tier.Op, entry: [*]u8) void {
            const Op = struct {
                fn f(comptime set: tier.TierSet, comptime ri: usize, a: anytype) void {
                    tier.logHook(set, ri, a[0], a[1]);
                }
            };
            resolve(void, header.set, rungOf(header), Op.f, .{ op, entry });
        }

        // ------------------------------------------------------- blocks

        /// The whole allocation `header` lives in.
        fn blockOf(header: *Header) Block {
            if (isControlOnly(header)) {
                const p: [*]align(8) u8 = @ptrCast(@alignCast(header));
                return p[0..@sizeOf(Header)];
            }
            const block_start: [*]align(8) u8 = @alignCast(dispatch([*]u8, header, ops.blockStart, .{}));
            return block_start[0..dispatch(usize, header, ops.allocatedSize, .{})];
        }

        /// Frees a block no reader can hold: a control-only block, an
        /// unpublished block, or any block of a `.plain` table.
        fn freeNow(ctx: Ctx, header: *Header) void {
            Spec.allocator(ctx).free(blockOf(header));
        }

        /// Replaces `old` by `new` in the slot and retires the old block.
        fn publish(ctx: Ctx, h: Handle, old: *Header, new: *Header) void {
            switch (comptime publish_mode) {
                .plain => {
                    h.* = new;
                    freeNow(ctx, old);
                },
                .safepoint_cas => {
                    const moar = @import("moar");
                    @as(*volatile u8, &old.stale).* = 1;
                    moar.freeAtSafepoint(Spec.tc(ctx), blockOf(old).ptr);
                    if (!moar.trycas(h, old, new))
                        fail(ctx, "hash table grown concurrently on the same hash");
                },
            }
        }

        fn saltFor(ctx: Ctx) u64 {
            return if (@hasDecl(Spec, "salt")) Spec.salt(ctx) else 0;
        }

        fn headerInit(entry_size: u8, set_index: u8, rung_index: u8) Header {
            return .{ .tier = rung_index, .set = set_index, .entry_size = entry_size, .stale = 0, .cur_items = 0 };
        }

        /// A fresh block of rung `rung_index` sized for `wanted` entries
        /// (clamped to the rung's ceiling; the tier applies its minimum).
        fn initRung(ctx: Ctx, set_index: u8, rung_index: u8, header_init: Header, wanted: u32) *Header {
            const Op = struct {
                fn f(comptime set: tier.TierSet, comptime ri: usize, a: anytype) *Header {
                    const I = set[ri].tier.Impl(Spec);
                    const header = I.init(Spec.allocator(a[0]), a[1], @min(a[2], set[ri].tier.max_capacity)) catch fail(a[0], oom_msg);
                    if (@hasDecl(I, "setSalt")) I.setSalt(header, saltFor(a[0]));
                    return header;
                }
            };
            return resolve(*Header, set_index, rung_index, Op.f, .{ ctx, header_init, wanted });
        }

        // ---------------------------------------------- growth, migration

        /// The first insert into a control-only table: the starting rung at
        /// its minimum size replaces the bare header (maybe_grow_hash,
        /// str_hash_table.c:323-343).
        fn materialise(ctx: Ctx, h: Handle, header: *Header) *Header {
            const new = initRung(ctx, header.set, rungOf(header), headerInit(header.entry_size, header.set, rungOf(header)), 0);
            publish(ctx, h, header, new);
            return new;
        }

        /// The rung reported full for an absent key: grow within the rung,
        /// else migrate to the next one. Returns the header to retry on.
        fn growOrMigrate(ctx: Ctx, h: Handle, header: *Header) *Header {
            if (dispatch(?*Header, header, ops.grow, .{ctx})) |grown| {
                if (grown != header) publish(ctx, h, header, grown);
                return grown;
            }
            const new = migrate(ctx, header);
            publish(ctx, h, header, new);
            return new;
        }

        /// `resolve` for a migration: the top rung is never a source, so
        /// `migrateOp` is only instantiated for rungs that have a next one.
        fn migrate(ctx: Ctx, old: *Header) *Header {
            inline for (Spec.sets, 0..) |set, si| {
                if (old.set == si) {
                    inline for (0..set.len - 1) |ri| {
                        if (rungOf(old) == ri) return migrateOp(set, ri, ctx, old);
                    }
                    // `grow` returned null at the top rung: `validate`
                    // requires each rung to hold up to the next threshold,
                    // and the top rung's ceiling is unbounded in practice.
                    unreachable;
                }
            }
            unreachable; // the set index is not in Spec.sets
        }

        /// Builds the next rung for `2 * cur_items` and drains the old rung
        /// into it: each entry's bytes are copied verbatim after its key is
        /// hashed by the new tier. The result is unpublished.
        fn migrateOp(comptime set: tier.TierSet, comptime ri: usize, ctx: Ctx, old: *Header) *Header {
            const next_rung = comptime tier.nextRung(set, ri).?;
            const N = set[next_rung].tier.Impl(Spec);
            const Mover = struct {
                ctx: Ctx,
                new: *Header,
                entry_size: usize,

                pub fn visit(self: *@This(), e: [*]u8) void {
                    // A key the caller has not filled in yet cannot be hashed.
                    if (std.mem.allEqual(u8, e[0..key_size], 0)) return;
                    const key = std.mem.bytesToValue(Key, e[0..key_size]);
                    while (true) {
                        switch (N.lvalueFetch(self.new, self.ctx, key, N.hash(self.ctx, key))) {
                            .inserted => |ne| {
                                @memcpy(ne[0..self.entry_size], e[0..self.entry_size]);
                                return;
                            },
                            // The keys of one table are distinct.
                            .found => unreachable,
                            // Robin Hood's probe limit can flag a growth
                            // before the load limit; the block is still
                            // ours alone, so an intermediate one is freed
                            // plainly. Null would mean the next rung cannot
                            // hold this rung's ceiling, which `validate`
                            // rules out.
                            .full => {
                                const bigger = (N.grow(self.new, self.ctx, Spec.allocator(self.ctx)) catch fail(self.ctx, oom_msg)) orelse unreachable;
                                if (bigger != self.new) {
                                    freeNow(self.ctx, self.new);
                                    self.new = bigger;
                                }
                            },
                        }
                    }
                }
            };
            var mover = Mover{
                .ctx = ctx,
                .new = initRung(ctx, old.set, next_rung, headerInit(old.entry_size, old.set, next_rung), old.cur_items *| 2),
                .entry_size = entrySizeOf(old),
            };
            set[ri].tier.Impl(Spec).drain(old, &mover);
            return mover.new;
        }

        // ------------------------------------------------------ lifetime

        /// Builds the table in `h` (which must be unbuilt or demolished):
        /// a control-only block for `expected == 0`, else the starting rung
        /// of set `set_index` sized for `expected`.
        pub fn build(ctx: Ctx, h: Handle, entry_size: u32, expected: u32, set_index: u8) void {
            if (Spec.runtime_entry_size) std.debug.assert(entry_size != 0 and entry_size <= std.math.maxInt(u8));
            if (set_index >= Spec.sets.len) fail(ctx, "hash table build called with a set index that does not exist");
            const stored_entry_size: u8 = if (Spec.runtime_entry_size) @intCast(entry_size) else 0;
            const StartOp = struct {
                fn f(comptime set: tier.TierSet, comptime _: usize, a: anytype) u8 {
                    return tier.startingRung(set, a[0]);
                }
            };
            const rung_index = resolve(u8, set_index, 0, StartOp.f, .{expected});
            if (expected == 0) {
                const block = Spec.allocator(ctx).alignedAlloc(u8, .@"8", @sizeOf(Header)) catch fail(ctx, oom_msg);
                const header: *Header = @ptrCast(block.ptr);
                header.* = headerInit(stored_entry_size, set_index, rung_index | control_only_bit);
                h.* = header;
            } else {
                h.* = initRung(ctx, set_index, rung_index, headerInit(stored_entry_size, set_index, rung_index), expected);
            }
        }

        /// Frees the table's block and leaves `h` unbuilt.
        pub fn demolish(ctx: Ctx, h: Handle) void {
            const header = h.* orelse return;
            checkStale(ctx, header, "demolish");
            if (comptime publish_mode == .plain) {
                freeNow(ctx, header);
            } else if (isControlOnly(header)) {
                freeNow(ctx, header);
            } else {
                const moar = @import("moar");
                moar.freeAtSafepoint(Spec.tc(ctx), blockOf(header).ptr);
            }
            h.* = null;
        }

        pub fn count(h: Handle) u32 {
            return if (h.*) |header| header.cur_items else 0;
        }

        pub fn entrySize(h: Handle) u32 {
            const header = h.* orelse return 0;
            return @intCast(entrySizeOf(header));
        }

        pub fn isEmpty(h: Handle) bool {
            return count(h) == 0;
        }

        pub fn allocatedSize(h: Handle) usize {
            const header = h.* orelse return 0;
            return blockOf(header).len;
        }

        /// The current rung index (0 for an unbuilt table).
        pub fn rung(h: Handle) u8 {
            const header = h.* orelse return 0;
            return rungOf(header);
        }

        /// Copies the block byte for byte, so the copy has the same layout,
        /// salt and iteration order; an unbuilt source leaves `dst` unbuilt.
        pub fn shallowCopy(ctx: Ctx, src: Handle, dst: Handle) void {
            const header = src.* orelse {
                dst.* = null;
                return;
            };
            checkStale(ctx, header, "shallowCopy");
            const block = blockOf(header);
            const copy = Spec.allocator(ctx).alignedAlloc(u8, .@"8", block.len) catch fail(ctx, oom_msg);
            @memcpy(copy, block);
            // The header is not always at the block start (Robin Hood's
            // entries precede it).
            const offset = @intFromPtr(header) - @intFromPtr(block.ptr);
            dst.* = @ptrCast(@alignCast(copy.ptr + offset));
            checkTurnedStale(ctx, header, "shallowCopy");
        }

        // ------------------------------------------------------- access

        pub fn fetch(ctx: Ctx, h: Handle, key: Key) ?[*]u8 {
            const header = h.* orelse return null;
            checkStale(ctx, header, "fetch");
            if (isControlOnly(header)) return null;
            return dispatch(?[*]u8, header, ops.fetch, .{ ctx, key });
        }

        const Found = struct { entry: [*]u8, found: bool };

        fn lvalue(ctx: Ctx, h: Handle, key: Key, comptime who: []const u8) Found {
            var header = h.* orelse fail(ctx, "Attempting insert on a hash table without first calling build");
            checkStale(ctx, header, who);
            if (isControlOnly(header)) header = materialise(ctx, h, header);
            const result: Found = while (true) {
                switch (dispatch(Lvalue, header, ops.lvalue, .{ ctx, key })) {
                    .found => |e| break .{ .entry = e, .found = true },
                    .inserted => |e| {
                        log(header, .insert, e);
                        break .{ .entry = e, .found = false };
                    },
                    .full => header = growOrMigrate(ctx, h, header),
                }
            };
            checkTurnedStale(ctx, header, who);
            return result;
        }

        /// The entry for `key`, inserted with zeroed key bytes (for the
        /// caller to fill) if absent. Grows or migrates only for an absent
        /// key; growth invalidates iterators and earlier entry pointers.
        pub fn lvalueFetch(ctx: Ctx, h: Handle, key: Key) [*]u8 {
            return lvalue(ctx, h, key, "lvalueFetch").entry;
        }

        /// `lvalueFetch` that reports a present key to `Spec.onDuplicate`.
        pub fn insert(ctx: Ctx, h: Handle, key: Key) [*]u8 {
            const r = lvalue(ctx, h, key, "insert");
            if (r.found) Spec.onDuplicate(ctx);
            return r.entry;
        }

        /// Removes `key`'s entry; false if absent.
        pub fn delete(ctx: Ctx, h: Handle, key: Key) bool {
            const header = h.* orelse return false;
            checkStale(ctx, header, "delete");
            if (isControlOnly(header)) return false;
            const entry = dispatch(?[*]u8, header, ops.fetch, .{ ctx, key }) orelse return false;
            log(header, .delete, entry);
            const removed = dispatch(bool, header, ops.delete, .{ ctx, key });
            std.debug.assert(removed);
            checkTurnedStale(ctx, header, "delete");
            return true;
        }

        // ---------------------------------------------------- iteration
        //
        // Positions are the tier's: 0 is the end, `start` is one before the
        // first entry, and `next` walks downward (`pos` must not be 0).

        pub fn first(h: Handle) u32 {
            const header = h.* orelse return 0;
            if (isControlOnly(header)) return 0;
            return dispatch(u32, header, ops.first, .{});
        }

        pub fn next(h: Handle, pos: u32) u32 {
            const header = h.* orelse return 0;
            if (isControlOnly(header)) return 0;
            return dispatch(u32, header, ops.next, .{pos});
        }

        pub fn start(h: Handle) u32 {
            const header = h.* orelse return 1;
            if (isControlOnly(header)) return 1;
            return dispatch(u32, header, ops.start, .{});
        }

        pub fn atStart(h: Handle, pos: u32) bool {
            return pos == start(h);
        }

        /// The entry at `pos`, or null at the end.
        pub fn current(h: Handle, pos: u32) ?[*]u8 {
            if (pos == 0) return null;
            const header = h.* orelse return null;
            if (isControlOnly(header)) return null;
            return dispatch([*]u8, header, ops.entryAt, .{pos});
        }

        /// The tier's consistency count (0 is clean).
        pub fn fsck(ctx: Ctx, h: Handle, mode: u32) u64 {
            const header = h.* orelse return 0;
            checkStale(ctx, header, "fsck");
            if (isControlOnly(header)) return 0;
            return dispatch(u64, header, ops.fsck, .{ ctx, mode });
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const IntSpec = @import("test_spec.zig").IntSpec;
const T = Table(IntSpec);
const test_entry_size: u32 = 16;

fn keyOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[0..8], .little);
}

fn valueOf(entry: [*]u8) u64 {
    return std.mem.readInt(u64, entry[8..16], .little);
}

/// Insert `key` with value `key * 10`; the key must be absent.
fn put(h: T.Handle, key: u64) !void {
    const e = T.insert({}, h, key);
    try testing.expectEqual(@as(u64, 0), keyOf(e));
    std.mem.writeInt(u64, e[0..8], key, .little);
    std.mem.writeInt(u64, e[8..16], key * 10, .little);
}

fn build(h: T.Handle, expected: u32) void {
    T.build({}, h, test_entry_size, expected, 0);
}

test "null and control-only states" {
    var slot: ?*Header = null;
    const h = &slot;
    try testing.expectEqual(@as(u32, 0), T.count(h));
    try testing.expectEqual(@as(u32, 0), T.entrySize(h));
    try testing.expect(T.isEmpty(h));
    try testing.expectEqual(@as(usize, 0), T.allocatedSize(h));
    try testing.expectEqual(@as(u32, 0), T.first(h));
    try testing.expect(T.atStart(h, T.start(h)));
    try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, 3));
    try testing.expect(!T.delete({}, h, 3));

    build(h, 0);
    try testing.expect(slot != null);
    try testing.expectEqual(test_entry_size, T.entrySize(h));
    try testing.expectEqual(@as(u32, 0), T.count(h));
    try testing.expect(T.isEmpty(h));
    try testing.expectEqual(@as(u32, 0), T.first(h));
    try testing.expect(T.atStart(h, T.start(h)));
    try testing.expectEqual(@as(?[*]u8, null), T.current(h, T.first(h)));
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    try testing.expectEqual(@sizeOf(Header), T.allocatedSize(h));
    try testing.expectEqual(@as(?[*]u8, null), T.fetch({}, h, 3));
    try testing.expect(!T.delete({}, h, 3));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));

    T.demolish({}, h);
    try testing.expectEqual(@as(?*Header, null), slot);
    T.demolish({}, h);
}

test "a hint picks the starting rung" {
    var slot: ?*Header = null;
    const h = &slot;

    build(h, 10);
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    const sized_for_ten = slot.?;
    for (1..11) |k| try put(h, k);
    // No growth within the hint: the rung was sized for at least 10.
    try testing.expectEqual(sized_for_ten, slot.?);
    try testing.expectEqual(@as(u32, 10), T.count(h));
    T.demolish({}, h);

    build(h, 64);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    T.demolish({}, h);

    build(h, 1000);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    try testing.expectEqual(@as(u32, 0), T.count(h));
    try testing.expectEqual(@as(u32, 0), T.first(h));
    T.demolish({}, h);
}

test "crossing the threshold migrates every entry upward exactly once" {
    var slot: ?*Header = null;
    const h = &slot;
    build(h, 0);
    defer T.demolish({}, h);

    for (1..65) |k| {
        try put(h, k);
        try testing.expectEqual(@as(u8, 0), T.rung(h));
    }
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    const old = slot.?;
    try put(h, 65);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    try testing.expect(slot.? != old);
    try testing.expectEqual(@as(u32, 65), T.count(h));
    for (1..66) |k| {
        const e = T.fetch({}, h, k) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(k, keyOf(e));
        try testing.expectEqual(k * 10, valueOf(e));
    }
    var walked: u32 = 0;
    var pos = T.first(h);
    while (pos != 0) : (pos = T.next(h, pos)) walked += 1;
    try testing.expectEqual(@as(u32, 65), walked);
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "lvalueFetch of an existing key in a full rung does not migrate" {
    var slot: ?*Header = null;
    const h = &slot;
    build(h, 0);
    defer T.demolish({}, h);

    for (1..65) |k| try put(h, k);
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    const full = slot.?;
    const e = T.lvalueFetch({}, h, 7);
    try testing.expectEqual(@as(u64, 7), keyOf(e));
    try testing.expectEqual(@as(u64, 70), valueOf(e));
    try testing.expectEqual(@as(u8, 0), T.rung(h));
    try testing.expectEqual(full, slot.?);
    try testing.expectEqual(@as(u32, 64), T.count(h));
}

test "deletes never demote" {
    var slot: ?*Header = null;
    const h = &slot;
    build(h, 0);
    defer T.demolish({}, h);

    for (1..201) |k| try put(h, k);
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    for (1..198) |k| try testing.expect(T.delete({}, h, k));
    try testing.expect(!T.delete({}, h, 1));
    try testing.expectEqual(@as(u32, 3), T.count(h));
    try testing.expectEqual(@as(u8, 1), T.rung(h));
    for (198..201) |k| try testing.expectEqual(k * 10, valueOf(T.fetch({}, h, k).?));
    try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
}

test "iteration dispatch and delete-current across both rungs" {
    for ([_]u32{ 30, 300 }) |n| {
        var slot: ?*Header = null;
        const h = &slot;
        build(h, 0);
        defer T.demolish({}, h);
        for (1..n + 1) |k| try put(h, k);
        try testing.expectEqual(@as(u8, if (n > 64) 1 else 0), T.rung(h));

        try testing.expect(T.atStart(h, T.start(h)));
        try testing.expect(!T.atStart(h, T.first(h)));
        try testing.expectEqual(@as(?[*]u8, null), T.current(h, 0));

        var seen = try testing.allocator.alloc(u32, n + 1);
        defer testing.allocator.free(seen);
        @memset(seen, 0);
        var i: u32 = 0;
        var pos = T.first(h);
        while (pos != 0) : (i += 1) {
            const nxt = T.next(h, pos);
            const k = keyOf(T.current(h, pos).?);
            seen[k] += 1;
            if (i % 2 == 0) try testing.expect(T.delete({}, h, k));
            pos = nxt;
        }
        try testing.expectEqual(n, i);
        for (seen[1..]) |c| try testing.expectEqual(@as(u32, 1), c);
        try testing.expectEqual(n / 2, T.count(h));
        var remaining: u32 = 0;
        for (1..n + 1) |k| {
            if (T.fetch({}, h, k)) |e| {
                try testing.expectEqual(k * 10, valueOf(e));
                remaining += 1;
            }
        }
        try testing.expectEqual(n / 2, remaining);
        try testing.expectEqual(@as(u64, 0), T.fsck({}, h, 0));
    }
}

test "shallowCopy preserves layout and contents" {
    var none: ?*Header = null;
    var dst_of_none: ?*Header = undefined;
    T.shallowCopy({}, &none, &dst_of_none);
    try testing.expectEqual(@as(?*Header, null), dst_of_none);

    for ([_]u32{ 0, 50, 500 }) |n| {
        var slot: ?*Header = null;
        const h = &slot;
        build(h, 0);
        defer T.demolish({}, h);
        for (1..n + 1) |k| try put(h, k);

        var copy_slot: ?*Header = null;
        const c = &copy_slot;
        T.shallowCopy({}, h, c);
        defer T.demolish({}, c);
        try testing.expect(copy_slot.? != slot.?);
        try testing.expectEqual(T.rung(h), T.rung(c));
        try testing.expectEqual(T.count(h), T.count(c));
        try testing.expectEqual(T.entrySize(h), T.entrySize(c));
        try testing.expectEqual(T.allocatedSize(h), T.allocatedSize(c));
        try testing.expectEqual(T.start(h), T.start(c));

        var pos = T.first(h);
        var cpos = T.first(c);
        while (pos != 0) : ({
            pos = T.next(h, pos);
            cpos = T.next(c, cpos);
        }) {
            try testing.expectEqual(pos, cpos);
            try testing.expectEqual(keyOf(T.current(h, pos).?), keyOf(T.current(c, cpos).?));
            try testing.expect(T.current(h, pos).? != T.current(c, cpos).?);
        }
        try testing.expectEqual(@as(u32, 0), cpos);
        if (n > 0) {
            // Independent afterwards.
            try testing.expect(T.delete({}, c, 1));
            try testing.expect(T.fetch({}, h, 1) != null);
            try testing.expectEqual(n - 1, T.count(c));
        }
        try testing.expectEqual(@as(u64, 0), T.fsck({}, c, 0));
    }
}

test "insert of an existing key calls onDuplicate" {
    var slot: ?*Header = null;
    const h = &slot;
    build(h, 0);
    defer T.demolish({}, h);

    IntSpec.duplicate_seen = false;
    try put(h, 5);
    try testing.expect(!IntSpec.duplicate_seen);
    const again = T.insert({}, h, 5);
    try testing.expect(IntSpec.duplicate_seen);
    try testing.expectEqual(@as(u64, 5), keyOf(again));
    try testing.expectEqual(@as(u64, 50), valueOf(again));
    try testing.expectEqual(@as(u32, 1), T.count(h));
}
