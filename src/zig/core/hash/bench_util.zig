//! The pieces the C-API benchmarks share (`bench.zig`, the string table
//! ladder, and `uni_bench.zig`, the unicode lookups): the wall clock timer,
//! the median and the spread of a cell's runs, and the comma lists of the
//! `--ops=a,b` arguments.
const std = @import("std");

pub const Timer = struct {
    io: std.Io,
    start: i96,

    pub fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io).toNanoseconds() };
    }

    pub fn elapsedNs(self: Timer) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds() - self.start);
    }
};

/// The median of the samples (sorts them in place).
pub fn median(samples: []f64) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    return samples[samples.len / 2];
}

/// The fastest and the slowest run.
pub fn spread(samples: []const f64) struct { min: f64, max: f64 } {
    return .{ .min = std.mem.min(f64, samples), .max = std.mem.max(f64, samples) };
}

/// The non-empty items of a comma separated list, allocated from `arena`.
pub fn splitList(arena: std.mem.Allocator, list: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |o| if (o.len != 0) try out.append(arena, o);
    return out.items;
}

/// Whether `name` is selected by an `--ops` list (null selects everything).
pub fn selects(ops: ?[]const []const u8, name: []const u8) bool {
    const list = ops orelse return true;
    for (list) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

test "spread is the min and max of the runs" {
    var runs = [_]f64{ 3.0, 1.0, 2.0 };
    const s = spread(&runs);
    try std.testing.expectEqual(@as(f64, 1.0), s.min);
    try std.testing.expectEqual(@as(f64, 3.0), s.max);
}

test "median is the middle run, the upper one of an even count" {
    var odd = [_]f64{ 3.0, 1.0, 2.0 };
    try std.testing.expectEqual(@as(f64, 2.0), median(&odd));
    var even = [_]f64{ 4.0, 1.0, 3.0, 2.0 };
    try std.testing.expectEqual(@as(f64, 3.0), median(&even));
}

test "splitList drops empty items and selects honours the list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const list = try splitList(arena_state.allocator(), "a,,b,");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(selects(list, "b"));
    try std.testing.expect(!selects(list, "c"));
    try std.testing.expect(selects(null, "anything"));
}
