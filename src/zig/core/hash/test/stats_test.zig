//! The statistics hooks (`-Dhash-stats=true`): a string table's operations
//! counted under the site its build was attributed to, merged across threads,
//! and the saturation of site ids. Skipped unless the flag is on. Runs in
//! the libmoar-linked `hash-str-test` binary.
//!
//! The counters and the site table are process-wide, so each test reads only
//! the lines of a site it minted itself. The saturating test must stay last:
//! after it no new site id is available to later tests of this binary.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const str = @import("../str.zig");
const stats = @import("../stats.zig");
const tier = @import("../tier.zig");
const keys = @import("keys.zig");

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

// Under stats the exports of the two tables below are defined in this binary
// (the stats twins that mint sites), so the C-shaped calls in the tests reach
// them and their counters, not libmoar's copies.
comptime {
    if (stats.enabled) {
        _ = @import("../str_exports.zig");
        _ = @import("../ptr_exports.zig");
    }
}

const entry_size: u32 = @sizeOf(c.MVMHashEntry);

const Entry = extern struct {
    key: [*c]c.MVMString,
    value: u64,
};

const Instance = struct {
    instance: *c.MVMInstance,
    tc: *ThreadContext,

    fn create() Instance {
        const instance = c.MVM_vm_create_instance();
        return .{ .instance = instance, .tc = instance.*.main_thread };
    }

    fn destroy(self: Instance) void {
        c.MVM_vm_destroy_instance(self.instance);
    }
};

fn unbuilt() c.MVMStrHashTable {
    return std.mem.zeroes(c.MVMStrHashTable);
}

fn fill(tc: *ThreadContext, ht: *c.MVMStrHashTable, ks: []const [*c]c.MVMString) void {
    for (ks) |k| {
        const e: *Entry = @ptrCast(@alignCast(str.lvalueFetchNocheck(tc, ht, k)));
        e.key = k;
        e.value = 1;
    }
}

/// Builds as the exported `MVM_str_hash_build` does under stats: the pending
/// site is the caller's, taken by `Table.build`.
fn buildAt(tc: *ThreadContext, ht: *c.MVMStrHashTable, site: u8, expected: u32) void {
    stats.pending_site = site;
    str.build(tc, ht, entry_size, expected);
}

fn dumpOf(out: *std.Io.Writer.Allocating) ![]const u8 {
    try stats.dump(&out.writer);
    return out.written();
}

/// The merged count of `op` at `site`, 0 if the dump has no such line.
fn countOf(text: []const u8, site: u8, op: []const u8) !u64 {
    var buf: [48]u8 = undefined;
    const prefix = try std.mem.print(&buf, "op\t{d}\t{s}\t", .{ site, op });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var fields = std.mem.splitScalar(u8, line[prefix.len..], '\t');
        return try std.fmt.parseInt(u64, fields.next().?, 10);
    }
    return 0;
}

fn expectLine(text: []const u8, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const want = try std.mem.print(&buf, fmt, args);
    if (std.mem.find(u8, text, want) == null) {
        std.debug.print("missing {s}in:\n{s}\n", .{ want, text });
        return error.TestExpectedEqual;
    }
}

test "a str table's ops are counted under its site" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 150);
    defer testing.allocator.free(ks);

    const site = stats.siteOf(0xa11ce);
    var ht = unbuilt();
    buildAt(tc, &ht, site, 100);
    fill(tc, &ht, ks[0..100]);
    for (ks[0..100]) |k| try testing.expect(str.fetch(tc, &ht, k) != null);
    for (ks[100..150]) |k| try testing.expect(str.fetch(tc, &ht, k) == null);
    for (ks[0..10]) |k| str.delete(tc, &ht, k);
    var it = str.first(tc, &ht);
    while (!str.atEnd(tc, &ht, it)) it = str.next(tc, &ht, it);
    str.demolish(tc, &ht);

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const text = try dumpOf(&out);
    try expectLine(text, "op\t{d}\tinsert\t100\t", .{site});
    try expectLine(text, "op\t{d}\tfetch_hit\t100\t", .{site});
    try expectLine(text, "op\t{d}\tfetch_miss\t50\t", .{site});
    try expectLine(text, "op\t{d}\tdelete_hit\t10\t", .{site});
    try expectLine(text, "op\t{d}\titer_step\t90\t", .{site});
    try expectLine(text, "op\t{d}\tdemolish\t1\t", .{site});
    // Expected 100 entries is the bucket whose limit is 128 (index 5).
    try expectLine(text, "build\t{d}\t{d}\t1\n", .{ site, stats.bucketOf(128) });
}

const Inserter = struct {
    tc: *ThreadContext,
    ht: *c.MVMStrHashTable,
    ks: []const [*c]c.MVMString,

    fn run(self: Inserter) void {
        fill(self.tc, self.ht, self.ks);
    }
};

fn siteOfTable(ht: anytype) u8 {
    const header: *tier.Header = @ptrCast(@alignCast(ht.table));
    return header.site;
}

/// The offset recorded for `site` in the dump (the `site` line).
fn offsetOf(text: []const u8, site: u8) !usize {
    var buf: [24]u8 = undefined;
    const prefix = try std.mem.print(&buf, "site\t{d}\t", .{site});
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return try std.fmt.parseInt(usize, line[prefix.len..], 16);
    }
    return error.SiteNotInDump;
}

/// The one call instruction of the "same call site" check (kept out of line,
/// so the optimizer cannot duplicate it).
noinline fn buildFromOneCallSite(tc: *ThreadContext, ht: *c.MVMStrHashTable) void {
    c.MVM_str_hash_build(tc, ht, entry_size, 0);
    // Work after the call keeps it from becoming a tail call, whose return
    // address would be this function's caller.
    std.mem.doNotOptimizeAway(ht.table);
}

test "fetches are binned by the table's size" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 120);
    defer testing.allocator.free(ks);

    const big = stats.siteOf(0xb1b1);
    const small = stats.siteOf(0xb2b2);
    var hb = unbuilt();
    buildAt(tc, &hb, big, 0);
    fill(tc, &hb, ks[0..100]);
    var hs = unbuilt();
    buildAt(tc, &hs, small, 0);
    fill(tc, &hs, ks[0..10]);
    for (ks[0..10]) |k| try testing.expect(str.fetch(tc, &hb, k) != null);
    for (ks[100..110]) |k| try testing.expect(str.fetch(tc, &hb, k) == null);
    for (ks[0..3]) |k| try testing.expect(str.fetch(tc, &hs, k) != null);

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const text = try dumpOf(&out);
    // 100 entries: the bucket with limit 128 (index 5).
    try expectLine(text, "fetch\t{d}\thit\t5\t10\t", .{big});
    try expectLine(text, "fetch\t{d}\tmiss\t5\t10\t", .{big});
    // 10 entries: limit 16 (index 1).
    try expectLine(text, "fetch\t{d}\thit\t1\t3\t", .{small});
    // Nothing else for the sites, and the bins add up to the op rows.
    try testing.expect(std.mem.find(u8, text, try std.mem.print(&buf2, "fetch\t{d}\tmiss\t1\t", .{small})) == null);
    try testing.expectEqual(try countOf(text, big, "fetch_hit"), 10);
    try testing.expectEqual(try countOf(text, big, "fetch_miss"), 10);
}

var buf2: [64]u8 = undefined;

test "a migration past the Small rung is counted once" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 100);
    defer testing.allocator.free(ks);

    const site = stats.siteOf(0xd00b1e);
    var ht = unbuilt();
    buildAt(tc, &ht, site, 0);
    fill(tc, &ht, ks);
    str.demolish(tc, &ht);

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const text = try dumpOf(&out);
    try testing.expectEqual(@as(u64, 100), try countOf(text, site, "insert"));
    try testing.expectEqual(@as(u64, 1), try countOf(text, site, "migrate"));
}

test "sites are minted through the exports, one per call site" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 8);
    defer testing.allocator.free(ks);

    // Two builds through one call instruction share a site id.
    var looped: [2]u8 = undefined;
    for (&looped) |*id| {
        var ht = unbuilt();
        buildFromOneCallSite(tc, &ht);
        id.* = siteOfTable(ht);
        fill(tc, &ht, ks);
        c.MVM_str_hash_demolish(tc, &ht);
    }
    try testing.expectEqual(looped[0], looped[1]);

    // A build from another call site gets another.
    var other = unbuilt();
    c.MVM_str_hash_build(tc, &other, entry_size, 0);
    const other_id = siteOfTable(other);
    try testing.expect(other_id != looped[0]);
    // The pending site was consumed by the build.
    try testing.expectEqual(@as(u8, 255), stats.pending_site);

    // A table built lazily by its export mints at that call.
    var ptr_ht = std.mem.zeroes(c.MVMPtrHashTable);
    const e = c.MVM_ptr_hash_lvalue_fetch(tc, &ptr_ht, ks[0]);
    e.*.key = ks[0];
    const ptr_id = siteOfTable(ptr_ht);
    try testing.expect(ptr_id != looped[0] and ptr_id != other_id);
    // A lookup-or-insert on a built table leaves no pending site behind.
    _ = c.MVM_ptr_hash_lvalue_fetch(tc, &ptr_ht, ks[0]);
    try testing.expectEqual(@as(u8, 255), stats.pending_site);

    // Every id is a real one with a nonzero recorded offset.
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const text = try dumpOf(&out);
    for ([_]u8{ looped[0], other_id, ptr_id }) |id| {
        try testing.expect(id != 255);
        try testing.expect(try offsetOf(text, id) != 0);
    }
    try expectLine(text, "op\t{d}\tinsert\t16\t", .{looped[0]});
    try expectLine(text, "op\t{d}\tinsert\t1\t", .{ptr_id});
    c.MVM_str_hash_demolish(tc, &other);
    c.MVM_ptr_hash_demolish(tc, &ptr_ht);
}

test "two threads merge" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 1000);
    defer testing.allocator.free(ks);

    const site = stats.siteOf(0xb0b);
    var ht = unbuilt();
    buildAt(tc, &ht, site, 1000);
    const t = try std.Thread.spawn(.{}, Inserter.run, .{Inserter{ .tc = tc, .ht = &ht, .ks = ks }});
    t.join();
    str.demolish(tc, &ht);

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const text = try dumpOf(&out);
    try expectLine(text, "op\t{d}\tinsert\t1000\t", .{site});
    var prefix: [32]u8 = undefined;
    const p = try std.mem.print(&prefix, "op\t{d}\tinsert\t", .{site});
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, p));
    try expectLine(text, "op\t{d}\tdemolish\t1\t", .{site});
}

test "site ids saturate at other" {
    if (!stats.enabled) return error.SkipZigTest;
    const vm = Instance.create();
    defer vm.destroy();
    const tc = vm.tc;
    const ks = try keys.make(tc, 20);
    defer testing.allocator.free(ks);

    var last: u8 = 0;
    for (0..300) |i| last = stats.siteOf(0x7000000 + i * 16);
    try testing.expectEqual(@as(u8, 255), last);

    // Site 255 also collects every table the other tests build without a
    // pending site, so compare against its count before.
    var before_out = std.Io.Writer.Allocating.init(testing.allocator);
    defer before_out.deinit();
    const before = try countOf(try dumpOf(&before_out), 255, "insert");

    var ht = unbuilt();
    buildAt(tc, &ht, 255, 20);
    fill(tc, &ht, ks);
    str.demolish(tc, &ht);

    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(before + 20, try countOf(try dumpOf(&out), 255, "insert"));
}
