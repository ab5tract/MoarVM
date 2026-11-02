//! The C-API microbenchmark of the string hash table (`zig build hash-bench
//! -- [--sizes=4,16,...] [--runs=3] [--max-size=1048576]`), spec §10.
//!
//! Times whichever engine libmoar was built with (`-Dzig-impl=true`: the
//! Zig engine of `str.zig`; `false`: the C tables) through `bench_shim.c`,
//! one out-of-line C wrapper per `MVM_str_hash_*` function, so both engines
//! run the compiled C API path and pay one identical wrapper call per
//! operation. Per ladder size N, in each of `runs` runs (median reported):
//! insert N fresh keys (`lvalue_fetch_nocheck` + key fill into tables built
//! with 0 entries), lookup hit (N `fetch_nocheck` of present keys), lookup
//! miss (N of a disjoint key set), full iteration, delete N; for sizes T and
//! T+1 (T = `str.small_threshold`) the N-th insert alone, into a table of
//! N-1. Small sizes are measured over a batch of `batch_ops / N` tables
//! handled in turn inside one timed region, so a clock read is amortised
//! over at least `batch_ops` operations; the figure is always nanoseconds
//! per operation (for the N-th insert, per insert). `alloc_bytes` is
//! `allocated_size` of one table after the inserts.
//!
//! Keys are gen2 `MVMString`s rooted for the instance's lifetime
//! (`test/keys.zig`), so a collection cannot move or free them; the tables
//! hold only key pointers and null values and are not GC roots.
//!
//! Output: TSV lines `engine<TAB>size<TAB>op<TAB>ns_per_op<TAB>alloc_bytes`.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const build_options = @import("build_options");
const keys = @import("test/keys.zig");
const str = @import("str.zig");

const Tc = *moar.ThreadContext;
const Ht = *c.MVMStrHashTable;
const Key = [*c]c.MVMString;
const Iter = c.MVMStrHashIterator;

extern fn bench_str_build(tc: Tc, ht: Ht, entry_size: u32, entries: u32) void;
extern fn bench_str_demolish(tc: Tc, ht: Ht) void;
extern fn bench_str_allocated_size(tc: Tc, ht: Ht) usize;
extern fn bench_str_lvalue_fetch_nocheck(tc: Tc, ht: Ht, key: Key) ?*anyopaque;
extern fn bench_str_fetch_nocheck(tc: Tc, ht: Ht, key: Key) ?*anyopaque;
extern fn bench_str_delete_nocheck(tc: Tc, ht: Ht, key: Key) void;
extern fn bench_str_first(tc: Tc, ht: Ht) Iter;
extern fn bench_str_next_nocheck(tc: Tc, ht: Ht, it: Iter) Iter;
extern fn bench_str_current_nocheck(tc: Tc, ht: Ht, it: Iter) ?*anyopaque;
extern fn bench_str_at_end(tc: Tc, ht: Ht, it: Iter) c_int;

const engine = if (build_options.zig_impl) "zig" else "c";
const entry_size: u32 = @sizeOf(c.MVMHashEntry);
/// One timed region covers at least this many operations.
const batch_ops: u32 = 1 << 16;
const default_max_size: u32 = 1048576;

/// The fixed rungs of spec §10; `small_threshold - 1`, the threshold and
/// `small_threshold + 1` join them.
const fixed_rungs = [_]u32{ 4, 16, 32, 128, 256, 1024, 16384, 65536, 1048576 };

/// The size ladder for a Small tier of `threshold` entries: the fixed rungs
/// plus T-1, T and T+1, sorted, with duplicates collapsed (a threshold on a
/// fixed rung yields one entry for it). Writes into `buf`, returns the slice.
pub fn ladder(threshold: u32, buf: *[16]u32) []u32 {
    var n: usize = 0;
    for (fixed_rungs) |s| {
        buf[n] = s;
        n += 1;
    }
    for ([_]u32{ threshold -| 1, threshold, threshold + 1 }) |s| {
        buf[n] = s;
        n += 1;
    }
    std.mem.sort(u32, buf[0..n], {}, std.sort.asc(u32));
    var out: usize = 0;
    for (buf[0..n]) |s| {
        if (s == 0 or (out > 0 and buf[out - 1] == s)) continue;
        buf[out] = s;
        out += 1;
    }
    return buf[0..out];
}

test "ladder(threshold) yields the spec sizes with duplicates collapsed" {
    var buf: [16]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 4, 16, 32, 63, 64, 65, 128, 256, 1024, 16384, 65536, 1048576 }, ladder(64, &buf));
    // A threshold on a fixed rung collapses onto it.
    try std.testing.expectEqualSlices(u32, &.{ 4, 16, 31, 32, 33, 128, 256, 1024, 16384, 65536, 1048576 }, ladder(32, &buf));
    try std.testing.expectEqualSlices(u32, &.{ 4, 16, 32, 127, 128, 129, 256, 1024, 16384, 65536, 1048576 }, ladder(128, &buf));
}

const usage =
    \\usage: hash-bench [--sizes=N,N,...] [--runs=K] [--max-size=N]
    \\  --sizes     the table sizes to measure (default: the spec's ladder)
    \\  --runs      runs per size, the median is reported (default 3)
    \\  --max-size  skip ladder sizes above this (default 1048576)
    \\
;

const Options = struct {
    sizes: []const u32,
    runs: u32 = 3,
    max_size: u32 = default_max_size,
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var opts: Options = .{ .sizes = &.{} };
    var sizes: ?[]u32 = null;
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--sizes=")) {
            var list: std.ArrayList(u32) = .empty;
            var it = std.mem.splitScalar(u8, a["--sizes=".len..], ',');
            while (it.next()) |s| {
                if (s.len == 0) continue;
                try list.append(arena, try std.fmt.parseInt(u32, s, 10));
            }
            sizes = list.items;
        } else if (std.mem.startsWith(u8, a, "--runs=")) {
            opts.runs = try std.fmt.parseInt(u32, a["--runs=".len..], 10);
            if (opts.runs == 0) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, a, "--max-size=")) {
            opts.max_size = try std.fmt.parseInt(u32, a["--max-size=".len..], 10);
        } else {
            std.debug.print("hash-bench: unknown argument {s}\n{s}", .{ a, usage });
            return error.InvalidArgument;
        }
    }
    if (sizes) |s| {
        opts.sizes = s;
    } else {
        const buf = try arena.create([16]u32);
        opts.sizes = ladder(str.small_threshold, buf);
    }
    return opts;
}

const Timer = struct {
    io: std.Io,
    start: i96,

    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io).toNanoseconds() };
    }

    fn elapsedNs(self: Timer) u64 {
        return @intCast(std.Io.Clock.awake.now(self.io).toNanoseconds() - self.start);
    }
};

fn entryOf(p: ?*anyopaque) *c.MVMHashEntry {
    return @ptrCast(@alignCast(p.?));
}

fn median(samples: []f64) f64 {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    return samples[samples.len / 2];
}

/// One ladder size: `reps` tables of `n` entries, each operation timed over
/// all of them, repeated `runs` times.
const Size = struct {
    n: u32,
    reps: u32,
    tables: []c.MVMStrHashTable,
    present: []const Key,
    miss: []const Key,
    insert: []f64,
    lookup_hit: []f64,
    lookup_miss: []f64,
    iterate: []f64,
    delete: []f64,
    insert_nth: []f64,
    alloc_bytes: usize = 0,

    fn init(arena: std.mem.Allocator, n: u32, runs: u32, present: []const Key, miss: []const Key) !Size {
        const reps = @max(1, batch_ops / n);
        return .{
            .n = n,
            .reps = reps,
            .tables = try arena.alloc(c.MVMStrHashTable, reps),
            .present = present[0..n],
            .miss = miss[0..n],
            .insert = try arena.alloc(f64, runs),
            .lookup_hit = try arena.alloc(f64, runs),
            .lookup_miss = try arena.alloc(f64, runs),
            .iterate = try arena.alloc(f64, runs),
            .delete = try arena.alloc(f64, runs),
            .insert_nth = try arena.alloc(f64, runs),
        };
    }

    fn perOp(self: Size, ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(@as(u64, self.n) * self.reps));
    }

    fn buildAll(self: *Size, tc: Tc) void {
        for (self.tables) |*t| {
            t.* = std.mem.zeroes(c.MVMStrHashTable);
            bench_str_build(tc, t, entry_size, 0);
        }
    }

    fn demolishAll(self: *Size, tc: Tc) void {
        for (self.tables) |*t| bench_str_demolish(tc, t);
    }

    fn insertInto(tc: Tc, t: Ht, ks: []const Key) void {
        for (ks) |k| {
            const e = entryOf(bench_str_lvalue_fetch_nocheck(tc, t, k));
            e.hash_handle.key = k;
            e.value = null;
        }
    }

    fn run(self: *Size, io: std.Io, tc: Tc, i: usize) !void {
        const expected = @as(u64, self.n) * self.reps;
        self.buildAll(tc);

        var timer = Timer.begin(io);
        for (self.tables) |*t| insertInto(tc, t, self.present);
        self.insert[i] = self.perOp(timer.elapsedNs());
        self.alloc_bytes = bench_str_allocated_size(tc, &self.tables[0]);

        var hits: u64 = 0;
        timer = Timer.begin(io);
        for (self.tables) |*t| {
            for (self.present) |k| {
                if (bench_str_fetch_nocheck(tc, t, k) != null) hits += 1;
            }
        }
        self.lookup_hit[i] = self.perOp(timer.elapsedNs());

        var misses: u64 = 0;
        timer = Timer.begin(io);
        for (self.tables) |*t| {
            for (self.miss) |k| {
                if (bench_str_fetch_nocheck(tc, t, k) == null) misses += 1;
            }
        }
        self.lookup_miss[i] = self.perOp(timer.elapsedNs());

        var seen: u64 = 0;
        timer = Timer.begin(io);
        for (self.tables) |*t| {
            var it = bench_str_first(tc, t);
            while (bench_str_at_end(tc, t, it) == 0) : (it = bench_str_next_nocheck(tc, t, it)) {
                const e = entryOf(bench_str_current_nocheck(tc, t, it));
                if (e.hash_handle.key != null) seen += 1;
            }
        }
        self.iterate[i] = self.perOp(timer.elapsedNs());

        timer = Timer.begin(io);
        for (self.tables) |*t| {
            for (self.present) |k| bench_str_delete_nocheck(tc, t, k);
        }
        self.delete[i] = self.perOp(timer.elapsedNs());

        var left: u64 = 0;
        for (self.tables) |*t| {
            if (bench_str_at_end(tc, t, bench_str_first(tc, t)) == 0) left += 1;
        }
        self.demolishAll(tc);

        if (hits != expected or misses != expected or seen != expected or left != 0) {
            std.debug.print("hash-bench: size {d}: {d} hits, {d} misses, {d} iterated, {d} tables not empty after delete (expected {d}, {d}, {d}, 0)\n", .{ self.n, hits, misses, seen, left, expected, expected, expected });
            return error.WrongAnswer;
        }
    }

    /// The N-th insert alone: tables of N-1 entries, then one insert each.
    fn runNth(self: *Size, io: std.Io, tc: Tc, i: usize) void {
        self.buildAll(tc);
        for (self.tables) |*t| insertInto(tc, t, self.present[0 .. self.n - 1]);
        const timer = Timer.begin(io);
        for (self.tables) |*t| insertInto(tc, t, self.present[self.n - 1 ..]);
        self.insert_nth[i] = @as(f64, @floatFromInt(timer.elapsedNs())) / @as(f64, @floatFromInt(self.reps));
        self.demolishAll(tc);
    }
};

fn isNthSize(n: u32) bool {
    return n == str.small_threshold or n == str.small_threshold + 1;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args) catch |err| switch (err) {
        error.InvalidArgument => std.process.exit(2),
        else => return err,
    };

    var max_n: u32 = 0;
    for (opts.sizes) |n| {
        if (n == 0) {
            std.debug.print("hash-bench: a size of 0 cannot be measured\n", .{});
            std.process.exit(2);
        }
        if (n > opts.max_size) {
            std.debug.print("hash-bench: skipping size {d} above --max-size={d}\n", .{ n, opts.max_size });
            continue;
        }
        max_n = @max(max_n, n);
    }
    if (max_n == 0) return;

    const instance = c.MVM_vm_create_instance();
    const tc: Tc = instance.*.main_thread;
    const present = try keys.makeNamed(arena, tc, "k", max_n);
    const miss = try keys.makeNamed(arena, tc, "m", max_n);

    var stdout_buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout.interface;

    for (opts.sizes) |n| {
        if (n > opts.max_size) continue;
        var size = try Size.init(arena, n, opts.runs, present, miss);
        for (0..opts.runs) |i| try size.run(io, tc, i);
        const rows = [_]struct { []const u8, []f64 }{
            .{ "insert", size.insert },
            .{ "lookup_hit", size.lookup_hit },
            .{ "lookup_miss", size.lookup_miss },
            .{ "delete", size.delete },
            .{ "iterate", size.iterate },
        };
        for (rows) |row| try w.print("{s}\t{d}\t{s}\t{d:.2}\t{d}\n", .{ engine, n, row[0], median(row[1]), size.alloc_bytes });
        if (isNthSize(n)) {
            for (0..opts.runs) |i| size.runNth(io, tc, i);
            try w.print("{s}\t{d}\t{s}\t{d:.2}\t{d}\n", .{ engine, n, "insert_nth", median(size.insert_nth), size.alloc_bytes });
        }
        try w.flush();
    }
    c.MVM_vm_destroy_instance(instance);
}
