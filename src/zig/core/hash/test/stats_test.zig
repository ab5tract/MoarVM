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
const keys = @import("keys.zig");

const testing = std.testing;
const ThreadContext = moar.ThreadContext;

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
    const prefix = try std.fmt.bufPrint(&buf, "op\t{d}\t{s}\t", .{ site, op });
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
    const want = try std.fmt.bufPrint(&buf, fmt, args);
    if (std.mem.indexOf(u8, text, want) == null) {
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
    const p = try std.fmt.bufPrint(&prefix, "op\t{d}\tinsert\t", .{site});
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
