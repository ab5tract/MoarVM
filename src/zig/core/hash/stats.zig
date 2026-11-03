//! Hash engine statistics (`-Dhash-stats=true`), a diagnostic build only.
//!
//! Every counting function is a comptime no-op unless the root of the
//! compilation declares `pub const hash_stats = true` (`src/zig/root.zig`
//! and `hash_test.zig` do, from the build options; the pure-Zig unit-test
//! roots have no such declaration, so `enabled` is false there and nothing
//! below reaches libc).
//!
//! Sites are call sites of the exported table constructors, interned by
//! return address (`siteOf`); the dump records each site's offset from the
//! load base of libmoar so a later pass can resolve it against the debug
//! info. Counters are per thread, page-allocated on first use and linked
//! into a global list that `dump` merges; the hot path touches only the
//! calling thread's counters. At exit (`atexit`) the dump goes to
//! `<MVM_HASH_STATS>/<pid>.tsv`. Nothing here uses `MVM_malloc`: mimalloc
//! may already be gone when the handler runs.
const std = @import("std");
const builtin = @import("builtin");

const root = @import("root");

pub const enabled: bool = @hasDecl(root, "hash_stats") and root.hash_stats;

pub const max_sites: u8 = 255;
/// Counter slots: the interned ids plus `other`.
const n_slots: usize = @as(usize, max_sites) + 1;

pub const Op = enum(u8) {
    build,
    insert,
    overwrite,
    fetch_hit,
    fetch_miss,
    delete_hit,
    delete_miss,
    iter_start,
    iter_step,
    copy,
    grow,
    migrate,
    demolish,
};
const n_ops = @typeInfo(Op).@"enum".fields.len;

/// Upper bounds of the size buckets; a tenth bucket holds anything larger.
pub const buckets = [_]u32{ 4, 16, 32, 64, 65, 128, 256, 1024, 16384 };
const n_buckets = buckets.len + 1;

/// The demolish histogram keeps sets 0..3 and rungs 0..7; larger values
/// are clamped into the last slot.
const n_sets = 4;
const n_rungs = 8;

pub fn bucketOf(n: u32) usize {
    for (buckets, 0..) |limit, i| if (n <= limit) return i;
    return buckets.len;
}

// ---------------------------------------------------------------- sites

var site_lock: std.atomic.Value(bool) = .init(false);
var site_addrs: [max_sites]usize = undefined;
var site_count: usize = 0;

fn lock(l: *std.atomic.Value(bool)) void {
    while (l.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock(l: *std.atomic.Value(bool)) void {
    l.store(false, .release);
}

/// The id of the call site whose return address is `ret_addr`, interned on
/// first sight; `max_sites` ("other") once all ids are taken.
pub fn siteOf(ret_addr: usize) u8 {
    lock(&site_lock);
    defer unlock(&site_lock);
    for (site_addrs[0..site_count], 0..) |a, i| if (a == ret_addr) return @intCast(i);
    if (site_count == max_sites) return max_sites;
    site_addrs[site_count] = ret_addr;
    site_count += 1;
    return @intCast(site_count - 1);
}

/// Set by an export that knows its caller, taken by the table call that
/// follows on the same thread.
pub threadlocal var pending_site: u8 = max_sites;

pub fn takePendingSite() u8 {
    const s = pending_site;
    pending_site = max_sites;
    return s;
}

// ------------------------------------------------------------- counters

const OpCount = struct { count: u64, cycles: u64 };
const ProbeCount = struct { count: u64, sum_len: u64, max_len: u32 };

const Counters = struct {
    next: ?*Counters,
    ops: [n_slots][n_ops]OpCount,
    probes: [n_slots][2]ProbeCount,
    builds: [n_slots][n_buckets]u64,
    demolishes: [n_slots][n_sets][n_rungs][n_buckets]u64,
};

var list_lock: std.atomic.Value(bool) = .init(false);
var list_head: ?*Counters = null;
threadlocal var local: ?*Counters = null;

var started_tsc: u64 = 0;
var started_ns: u64 = 0;

fn clockNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub inline fn now() u64 {
    if (!enabled) return 0;
    if (comptime builtin.cpu.arch == .x86_64) {
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | lo;
    }
    return clockNs();
}

fn counters() *Counters {
    if (local) |l| return l;
    return counterSlow();
}

fn counterSlow() *Counters {
    @branchHint(.cold);
    ensureRegistered();
    const l = std.heap.page_allocator.create(Counters) catch @panic("hash-stats: out of memory");
    // Fresh pages are zero; keep it explicit for the fields that matter.
    l.next = null;
    lock(&list_lock);
    l.next = list_head;
    list_head = l;
    unlock(&list_lock);
    local = l;
    return l;
}

pub inline fn count(site: u8, op: Op) void {
    if (!enabled) return;
    counters().ops[site][@intFromEnum(op)].count += 1;
}

pub inline fn countCycles(site: u8, op: Op, t0: u64) void {
    if (!enabled) return;
    const e = &counters().ops[site][@intFromEnum(op)];
    e.count += 1;
    e.cycles += now() -% t0;
}

pub inline fn probe(site: u8, hit: bool, len: u32) void {
    if (!enabled) return;
    const p = &counters().probes[site][@intFromBool(hit)];
    p.count += 1;
    p.sum_len += len;
    if (len > p.max_len) p.max_len = len;
}

pub fn sizeAtBuild(site: u8, expected: u32) void {
    if (!enabled) return;
    counters().builds[site][bucketOf(expected)] += 1;
}

pub fn sizeAtDemolish(site: u8, set: u8, rung: u8, max_items: u32) void {
    if (!enabled) return;
    const s = @min(set, n_sets - 1);
    const r = @min(rung, n_rungs - 1);
    counters().demolishes[site][s][r][bucketOf(max_items)] += 1;
}

// ----------------------------------------------------------------- dump

const DlInfo = extern struct {
    fname: ?[*:0]const u8,
    fbase: ?*anyopaque,
    sname: ?[*:0]const u8,
    saddr: ?*anyopaque,
};
extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;
extern "c" fn atexit(cb: *const fn () callconv(.c) void) c_int;

fn writeCmdline(w: *std.Io.Writer) !void {
    try w.writeAll("# cmdline: ");
    if (enabled) {
        const fd = std.c.open("/proc/self/cmdline", .{ .ACCMODE = .RDONLY });
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            var buf: [4096]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            if (n > 0) {
                const len: usize = @intCast(n);
                var end = len;
                if (end > 0 and buf[end - 1] == 0) end -= 1;
                for (buf[0..end]) |*ch| {
                    if (ch.* == 0 or ch.* == '\n' or ch.* == '\t') ch.* = ' ';
                }
                try w.writeAll(buf[0..end]);
            }
        }
    }
    try w.writeByte('\n');
}

/// Writes the merged counters of every thread in the TSV format described
/// in docs/zig-build.md. With statistics disabled only the header lines
/// are produced.
pub fn dump(w: *std.Io.Writer) !void {
    const dump_tsc = now();
    try writeCmdline(w);
    try w.print("# pid: {d}\n", .{if (enabled) std.c.getpid() else 0});
    var hz: u64 = 0;
    if (enabled) {
        const dns = clockNs() -% started_ns;
        const dt = dump_tsc -% started_tsc;
        hz = if (builtin.cpu.arch != .x86_64) std.time.ns_per_s else if (dns == 0) 0 else @intCast(@as(u128, dt) * std.time.ns_per_s / dns);
    }
    try w.print("# tsc_hz: {d}\n", .{hz});
    try w.print("# total_cycles: {d}\n", .{if (enabled) dump_tsc -% started_tsc else 0});
    var base: usize = 0;
    var path: []const u8 = "";
    if (enabled) {
        var info: DlInfo = undefined;
        if (dladdr(@ptrCast(&dump), &info) != 0) {
            base = @intFromPtr(info.fbase);
            if (info.fname) |f| path = std.mem.span(f);
        }
    }
    try w.print("# libmoar: {s}\n", .{path});
    if (!enabled) return;

    lock(&site_lock);
    const nsites = site_count;
    var addrs: [max_sites]usize = undefined;
    @memcpy(addrs[0..nsites], site_addrs[0..nsites]);
    unlock(&site_lock);
    for (addrs[0..nsites], 0..) |a, i| try w.print("site\t{d}\t{x}\n", .{ i, a -% base });

    lock(&list_lock);
    defer unlock(&list_lock);
    const op_names = comptime blk: {
        var names: [n_ops][]const u8 = undefined;
        for (@typeInfo(Op).@"enum".fields, 0..) |f, i| names[i] = f.name;
        break :blk names;
    };
    for (0..n_slots) |site| {
        for (0..n_ops) |op| {
            var tot: OpCount = .{ .count = 0, .cycles = 0 };
            var l = list_head;
            while (l) |c| : (l = c.next) {
                tot.count += c.ops[site][op].count;
                tot.cycles += c.ops[site][op].cycles;
            }
            if (tot.count != 0) try w.print("op\t{d}\t{s}\t{d}\t{d}\n", .{ site, op_names[op], tot.count, tot.cycles });
        }
        for ([_][]const u8{ "miss", "hit" }, 0..) |name, h| {
            var tot: ProbeCount = .{ .count = 0, .sum_len = 0, .max_len = 0 };
            var l = list_head;
            while (l) |c| : (l = c.next) {
                const p = c.probes[site][h];
                tot.count += p.count;
                tot.sum_len += p.sum_len;
                tot.max_len = @max(tot.max_len, p.max_len);
            }
            if (tot.count != 0) try w.print("probe\t{d}\t{s}\t{d}\t{d}\t{d}\n", .{ site, name, tot.count, tot.sum_len, tot.max_len });
        }
        for (0..n_buckets) |b| {
            var n: u64 = 0;
            var l = list_head;
            while (l) |c| : (l = c.next) n += c.builds[site][b];
            if (n != 0) try w.print("build\t{d}\t{d}\t{d}\n", .{ site, b, n });
        }
        for (0..n_sets) |s| for (0..n_rungs) |r| for (0..n_buckets) |b| {
            var n: u64 = 0;
            var l = list_head;
            while (l) |c| : (l = c.next) n += c.demolishes[site][s][r][b];
            if (n != 0) try w.print("demolish\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ site, s, r, b, n });
        };
    }
}

var registered: std.atomic.Value(u8) = .init(0);

/// Registers the exit handler and starts the cycle clock, once. Called on
/// the first counter use of any thread.
pub fn ensureRegistered() void {
    if (!enabled) return;
    if (registered.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        // Another thread is registering; wait until the start time is set.
        while (registered.load(.acquire) != 2) std.atomic.spinLoopHint();
        return;
    }
    started_tsc = now();
    started_ns = clockNs();
    _ = atexit(&exitHandler);
    registered.store(2, .release);
}

fn exitHandler() callconv(.c) void {
    const dir = std.c.getenv("MVM_HASH_STATS") orelse return;
    writeFile(std.mem.span(dir)) catch |e| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "hash-stats: cannot write the dump: {s}\n", .{@errorName(e)}) catch return;
        _ = std.c.write(2, msg.ptr, msg.len);
    };
}

fn writeFile(dir: []const u8) !void {
    var path_buf: [4096:0]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&path_buf, "{s}/{d}.tsv", .{ dir, std.c.getpid() });
    var dir_buf: [4096:0]u8 = undefined;
    const dz = try std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir});
    _ = std.c.mkdir(dz.ptr, 0o755);
    const fd = std.c.open(&path_buf, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();
    try dump(&out.writer);
    var rest = out.written();
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

// ---------------------------------------------------------------- tests

test "siteOf interns and saturates" {
    var ids: [256]u8 = undefined;
    for (0..256) |i| ids[i] = siteOf(0x10000 + i * 16);
    for (0..255) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), ids[i]);
    try std.testing.expectEqual(@as(u8, 255), ids[255]);
    try std.testing.expectEqual(@as(u8, 255), siteOf(0x90000));
    try std.testing.expectEqual(@as(u8, 7), siteOf(0x10000 + 7 * 16));
}

test "buckets map sizes to the ladder" {
    try std.testing.expectEqual(@as(usize, 0), bucketOf(4));
    try std.testing.expectEqual(@as(usize, 1), bucketOf(5));
    try std.testing.expectEqual(@as(usize, 4), bucketOf(65));
    try std.testing.expectEqual(@as(usize, 9), bucketOf(16385));
}

test "dump of empty counters is only the header" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try dump(&out.writer);
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(line[0] == '#');
        n += 1;
    }
    try std.testing.expect(n >= 4);
}
