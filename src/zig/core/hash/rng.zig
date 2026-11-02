//! Per-table salts for the engine's Robin Hood blocks (spec 3.4). The C
//! draws `MVM_proc_rand_i(tc)` at every allocation, which advances the
//! user-visible `nqp::rand_i` sequence; the engine mixes a process-wide
//! atomic counter with `instance->hashSeed` through splitmix64 instead,
//! which is as unpredictable as the seed and leaves the user's random
//! sequence alone.
//!
//! `salt` needs the `moar` module, so this file belongs to the hash-str
//! test root, not to the pure-Zig unit-test list; `mix` is pure and carries
//! the self-test.
const std = @import("std");
const moar = @import("moar");

var counter = std.atomic.Value(u64).init(0);

/// splitmix64 over `seed` advanced by `counter_value + 1` steps' worth of
/// the golden-ratio increment: distinct counters give distinct salts for
/// one seed, and the salt is a function of (counter, seed) alone.
pub fn mix(counter_value: u64, seed: u64) u64 {
    var z = seed +% (counter_value +% 1) *% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// The next salt for a table of `instance`.
pub fn salt(instance: *moar.c.MVMInstance) u64 {
    return mix(counter.fetchAdd(1, .monotonic), instance.hashSeed);
}

test "mix is deterministic in (counter, seed) and consecutive counters differ" {
    comptime {
        std.debug.assert(mix(0, 0x1234) == mix(0, 0x1234));
        std.debug.assert(mix(0, 0x1234) != mix(1, 0x1234));
        std.debug.assert(mix(0, 1) != mix(0, 2));
        std.debug.assert(mix(0, 0) != 0);
    }
    var local = std.atomic.Value(u64).init(0);
    const a = mix(local.fetchAdd(1, .monotonic), 7);
    const b = mix(local.fetchAdd(1, .monotonic), 7);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(mix(0, 7), a);
}
