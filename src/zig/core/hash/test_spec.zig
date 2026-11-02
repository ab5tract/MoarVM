//! A pure-Zig `Spec` for tier and table unit tests: u64 keys (0 is the
//! "empty key" a caller fills in after `lvalueFetch` inserts), splitmix64
//! hashing, entry size chosen at runtime, memory from `std.testing.allocator`.
const std = @import("std");
const tier = @import("tier.zig");
const small = @import("tiers/small.zig");
const robinhood = @import("tiers/robinhood.zig");

/// The ladder the tests run tables through.
pub const standard_test_set = [_]tier.TierEntry{
    .{ .tier = small.Tier(.{ .max_capacity = 64 }), .from = 0 },
    .{ .tier = robinhood.Tier(.{}), .from = 64 },
};

pub const IntSpec = struct {
    pub const Key = u64;
    pub const Ctx = void;
    pub const runtime_entry_size = true;
    pub const publish = .plain;
    pub const sets: []const tier.TierSet = &.{&standard_test_set};

    /// Set by `onDuplicate`; tests reset it.
    pub var duplicate_seen: bool = false;

    pub fn hash(ctx: Ctx, key: Key) u64 {
        _ = ctx;
        var z = key +% 0x9e3779b97f4a7c15;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    pub fn eql(ctx: Ctx, a: Key, b: Key) bool {
        _ = ctx;
        return a == b;
    }

    pub fn allocator(ctx: Ctx) std.mem.Allocator {
        _ = ctx;
        return std.testing.allocator;
    }

    pub fn onDuplicate(ctx: Ctx) void {
        _ = ctx;
        duplicate_seen = true;
    }
};

// The tier files import `../tier.zig` and this file, which lie outside a
// module rooted in `tiers/`, so their tests run with this file as the root.
test {
    _ = small;
    _ = robinhood;
    comptime tier.validate(&standard_test_set);
}
