//! Tests of `view.zig` (the typed views of the collector's C structures) on
//! a booted VM: the flag and status views against the C constants, and the
//! collectable view changes with their debug-level checks.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const view = @import("../view.zig");
const atomic = @import("../atomic.zig");

/// The environment variable that turns the test binary into the child of a
/// "panic" test (the pattern of `allocation_test.zig`): the runner takes no
/// filter argument, so the child runs the binary's tests in order, and the
/// named test, the first test of this file, which is the first file of
/// `gc_test.zig`, does the panicking call instead of spawning.
const child_var = "MOAR_GC_TEST_CHILD";

fn childVar() ?[]const u8 {
    return std.testing.environ.getPosix(child_var);
}

/// Runs this test binary again with `child_var=name`; returns its result.
fn runChild(name: []const u8) !std.process.RunResult {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put(child_var, name);
    _ = env.swapRemove("ZIG_PROGRESS");
    return std.process.run(gpa, io, .{ .argv = &.{exe}, .environ_map = &env });
}

test "asStable panics on a non-STable at debug 1" {
    if (comptime c.MVM_GC_DEBUG == 0) return error.SkipZigTest;
    if (childVar()) |name| {
        // Another test's child: that test's parent checks it; do not spawn.
        if (!std.mem.eql(u8, name, "as-stable")) return;
        const instance = c.MVM_vm_create_instance();
        // VMNull is an object, not an STable: its flags1 has no MVM_CF_STABLE.
        _ = view.asStable(view.asCol(instance.*.VMNull));
        return error.TestUnexpectedResult; // not reached: the panic exits
    }
    const r = try runChild("as-stable");
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expect(std.mem.find(u8, r.stderr, "MoarVM panic: Collectable viewed as an STable has no MVM_CF_STABLE flag\n") != null);
}

test "flag views round-trip every MVM_CF_ constant" {
    const flags1_bits = .{
        .{ "type_object", c.MVM_CF_TYPE_OBJECT },
        .{ "stable", c.MVM_CF_STABLE },
        .{ "frame", c.MVM_CF_FRAME },
        .{ "serialization_index_allocated", c.MVM_CF_SERIALZATION_INDEX_ALLOCATED },
        .{ "has_object_id", c.MVM_CF_HAS_OBJECT_ID },
        .{ "never_repossess", c.MVM_CF_NEVER_REPOSSESS },
    };
    inline for (flags1_bits) |bit| {
        var f: view.Flags1 = @bitCast(@as(u8, 0));
        @field(f, bit[0]) = true;
        try std.testing.expectEqual(@as(u8, bit[1]), @as(u8, @bitCast(f)));
    }
    const flags2_bits = .{
        .{ "nursery_seen", c.MVM_CF_NURSERY_SEEN },
        .{ "second_gen", c.MVM_CF_SECOND_GEN },
        .{ "in_gen2_root_list", c.MVM_CF_IN_GEN2_ROOT_LIST },
        .{ "gen2_live", c.MVM_CF_GEN2_LIVE },
        .{ "forwarder_valid", c.MVM_CF_FORWARDER_VALID },
        .{ "ref_from_gen2", c.MVM_CF_REF_FROM_GEN2 },
        .{ "debug_in_gen2_free_list", c.MVM_CF_DEBUG_IN_GEN2_FREE_LIST },
    };
    inline for (flags2_bits) |bit| {
        var f: view.Flags2 = @bitCast(@as(u8, 0));
        @field(f, bit[0]) = true;
        try std.testing.expectEqual(@as(u8, bit[1]), @as(u8, @bitCast(f)));
    }

    // Writes through the view land in the C byte.
    var header = std.mem.zeroes(c.MVMCollectable);
    view.flags2(&header).ref_from_gen2 = true;
    view.flags1(&header).has_object_id = true;
    try std.testing.expectEqual(@as(u8, c.MVM_CF_REF_FROM_GEN2), header.flags2);
    try std.testing.expectEqual(@as(u8, c.MVM_CF_HAS_OBJECT_ID), header.flags1);

    // Reads of real collectables: a fresh nursery object is young, VMNull
    // (allocated in gen2 at boot) is not.
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: view.Tc = instance.*.main_thread;
    const obj = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    try std.testing.expect(!view.flags2(view.asCol(obj)).second_gen);
    try std.testing.expect(view.flags2(view.asCol(instance.*.VMNull)).second_gen);
}

test "GcStatus round-trips the C constants" {
    try std.testing.expectEqual(@as(usize, 0), @as(usize, @bitCast(view.GcStatus{ .status = .none, .@"suspend" = .none })));
    try std.testing.expectEqual(@as(usize, 5), @as(usize, @bitCast(view.GcStatus{ .status = .interrupt, .@"suspend" = .request })));
    try std.testing.expectEqual(@as(usize, 14), @as(usize, @bitCast(view.GcStatus{ .status = .unable, .@"suspend" = .suspended })));
    const s: view.GcStatus = @bitCast(@as(usize, c.MVMGCStatus_STOLEN | c.MVMSuspendState_SUSPEND_REQUEST));
    try std.testing.expectEqual(view.Status.stolen, s.status);
    try std.testing.expectEqual(view.Suspend.request, s.@"suspend");

    // The slot of a running thread: no interrupt, no suspend.
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: view.Tc = instance.*.main_thread;
    try std.testing.expect(view.gcStatus(tc) == &tc.gc_status);
    const now = atomic.loadStatus(view.gcStatus(tc));
    try std.testing.expectEqual(view.Status.none, now.status);
    try std.testing.expectEqual(view.Suspend.none, now.@"suspend");
}

test "asObject, asStable, asFrame and asCol view the same address" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: view.Tc = instance.*.main_thread;
    const obj: view.Object = instance.*.VMNull;
    const col = view.asCol(obj);
    try std.testing.expectEqual(@intFromPtr(obj), @intFromPtr(col));
    try std.testing.expect(view.asObject(col) == obj);
    // An STable and a frame pass the debug-level flag checks.
    const st: view.STable = obj.st;
    try std.testing.expect(view.asStable(view.asCol(st)) == st);
    const frame: view.Frame = c.MVM_gc_allocate_frame(tc);
    try std.testing.expect(view.asFrame(view.asCol(frame)) == frame);
    // `c.MVMSTable`'s header is its collectable.
    try std.testing.expect(view.asCol(st) == &st.header);
}
