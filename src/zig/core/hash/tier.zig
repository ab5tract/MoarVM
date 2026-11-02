//! Tier sets and the tier contract of the Zig hash engine (spec 4.2, 4.3).
//!
//! A tier is a type providing:
//!   * `pub const max_capacity: u32`: the largest entry count its capacity
//!     scheme can hold. `validate` checks it against the next rung's `from`.
//!   * `pub fn Impl(comptime Spec: type) type`: the storage operations of
//!     spec section 5. This file never calls it.
//!
//! This file is pure Zig with no C dependency.
const std = @import("std");

/// The mutating operations reported to `logHook`.
pub const Op = enum { insert, delete };

pub const TierEntry = struct {
    /// A tier module (see the file comment for the contract).
    tier: type,
    /// Entry count at which this rung takes over.
    from: u32,
    /// Reserved, see spec section 2 decision 5.
    double_write: bool = false,
};

/// The ladder of rungs a table is migrated through, lowest first.
pub const TierSet = []const TierEntry;

/// Comptime check of a set: non-empty, first `from` is 0, `from` strictly
/// increases, and each tier can hold up to the next rung's `from`.
pub fn validate(comptime set: TierSet) void {
    comptime {
        if (set.len == 0) @compileError("tier set is empty");
        if (set[0].from != 0) @compileError("tier set: the first entry's `from` must be 0");
        for (set[1..], 1..) |e, i| {
            if (e.from <= set[i - 1].from)
                @compileError(std.fmt.comptimePrint("tier set: `from` must strictly increase (rung {d})", .{i}));
        }
        for (set[0 .. set.len - 1], 0..) |e, i| {
            if (e.tier.max_capacity < set[i + 1].from)
                @compileError(std.fmt.comptimePrint("tier set: rung {d} has max_capacity {d}, below the next rung's from {d}", .{ i, e.tier.max_capacity, set[i + 1].from }));
        }
    }
}

/// Index of the last entry whose `from` is at most `expected`.
pub fn startingRung(comptime set: TierSet, expected: u32) u8 {
    var rung: u8 = 0;
    inline for (set, 0..) |e, i| {
        if (e.from <= expected) rung = @intCast(i);
    }
    return rung;
}

/// The rung above `rung`, or null at the top.
pub fn nextRung(comptime set: TierSet, rung: u8) ?u8 {
    if (@as(usize, rung) + 1 >= set.len) return null;
    return rung + 1;
}

/// Whether `logHook` does anything at all: false in this campaign, so the
/// policy layer skips, at comptime, any work done only to hand the hook an
/// entry (the pre-fetch of `Table.delete`).
pub const log_hook_enabled = false;

/// Whether `logHook` does anything for `set`: `log_hook_enabled` and a rung
/// of the set has `double_write`.
pub fn logHookEnabled(comptime set: TierSet) bool {
    comptime {
        if (!log_hook_enabled) return false;
        for (set) |e| {
            if (e.double_write) return true;
        }
        return false;
    }
}

/// Reserved double-write hook (spec section 2 decision 5); a no-op in this
/// campaign (`log_hook_enabled`).
pub inline fn logHook(comptime set: TierSet, rung: u8, op: Op, entry: [*]u8) void {
    _ = set;
    _ = rung;
    _ = op;
    _ = entry;
}

/// The first 8 bytes of every table's control block (spec 4.2). The stored
/// table pointer points at this header; the tier decides what lies around it.
pub const Header = extern struct {
    /// Rung index within the set.
    tier: u8,
    /// Index into the comptime list of tier sets.
    set: u8,
    /// Entry size as in C (0 is never stored; unbuilt is a NULL pointer).
    entry_size: u8,
    /// Volatile, as in C.
    stale: u8,
    cur_items: u32,
};

const StubSmall = struct {
    pub const max_capacity: u32 = 64;
};
const StubBig = struct {
    pub const max_capacity: u32 = std.math.maxInt(u32);
};

test "startingRung picks the last rung whose threshold is at most the hint" {
    const set = [_]TierEntry{ .{ .tier = StubSmall, .from = 0 }, .{ .tier = StubBig, .from = 64 } };
    try std.testing.expectEqual(@as(u8, 0), startingRung(&set, 0));
    try std.testing.expectEqual(@as(u8, 0), startingRung(&set, 63));
    try std.testing.expectEqual(@as(u8, 1), startingRung(&set, 64));
    try std.testing.expectEqual(@as(u8, 1), startingRung(&set, 100_000));
    try std.testing.expectEqual(@as(?u8, 1), nextRung(&set, 0));
    try std.testing.expectEqual(@as(?u8, null), nextRung(&set, 1));
}

test "validate accepts the standard shape" {
    comptime validate(&[_]TierEntry{ .{ .tier = StubSmall, .from = 0 }, .{ .tier = StubBig, .from = 64 } });
}

test "the log hook is a comptime no-op in this campaign" {
    const plain = [_]TierEntry{ .{ .tier = StubSmall, .from = 0 }, .{ .tier = StubBig, .from = 64 } };
    const flagged = [_]TierEntry{ .{ .tier = StubSmall, .from = 0, .double_write = true }, .{ .tier = StubBig, .from = 64 } };
    try std.testing.expect(!comptime logHookEnabled(&plain));
    try std.testing.expectEqual(log_hook_enabled, comptime logHookEnabled(&flagged));
}

test "Header is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
}
