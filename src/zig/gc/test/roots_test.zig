//! Tests of `roots.zig` (the port of src/gc/roots.c) on a booted VM.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const roots = @import("../roots.zig");

const Collectable = c.MVMCollectable;

fn asCol(p: anytype) [*c]Collectable {
    return @ptrCast(@alignCast(p));
}

test "temp root push grows from 16 doubling and keeps roots" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    try std.testing.expectEqual(@as(u32, c.MVM_TEMP_ROOT_BASE_ALLOC), tc.*.alloc_temproots);
    const before = tc.*.num_temproots;
    var slots: [1000]?*Collectable = @splat(null);
    var alloc = tc.*.alloc_temproots;
    for (0..slots.len) |i| {
        roots.tempPushSlow(tc, @ptrCast(&slots[i]));
        if (tc.*.alloc_temproots != alloc) {
            // A growth step doubles, and every root pushed so far survives
            // the realloc.
            try std.testing.expectEqual(alloc * 2, tc.*.alloc_temproots);
            alloc = tc.*.alloc_temproots;
            for (0..i + 1) |j|
                try std.testing.expectEqual(@intFromPtr(&slots[j]), @intFromPtr(tc.*.temproots[before + j]));
        }
    }
    try std.testing.expectEqual(@as(u32, 1024), tc.*.alloc_temproots);
    try std.testing.expectEqual(before + 1000, tc.*.num_temproots);
    for (0..slots.len) |i|
        try std.testing.expectEqual(@intFromPtr(&slots[i]), @intFromPtr(tc.*.temproots[before + i]));
    tc.*.num_temproots = before;
}

test "mark and mark_reset restore num_temproots" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const before = tc.*.num_temproots;
    const mark_before = tc.*.mark_temproots;
    var a: ?*c.MVMObject = instance.*.VMNull;
    c.MVM_gc_root_temp_push(tc, @ptrCast(&a));
    c.MVM_gc_root_temp_push(tc, @ptrCast(&a));
    const m = roots.tempMark(tc);
    try std.testing.expectEqual(mark_before, m);
    try std.testing.expectEqual(before + 2, tc.*.mark_temproots);
    c.MVM_gc_root_temp_push(tc, @ptrCast(&a));
    c.MVM_gc_root_temp_push(tc, @ptrCast(&a));
    c.MVM_gc_root_temp_push(tc, @ptrCast(&a));
    try std.testing.expectEqual(before + 5, tc.*.num_temproots);
    // pop_all goes back to the mark, not to the bottom.
    roots.tempPopAll(tc);
    try std.testing.expectEqual(before + 2, tc.*.num_temproots);
    roots.tempMarkReset(tc, m);
    try std.testing.expectEqual(mark_before, tc.*.mark_temproots);
    roots.tempPopAll(tc);
    try std.testing.expectEqual(mark_before, tc.*.num_temproots);
    tc.*.num_temproots = before;
}

test "gen2_add sets IN_GEN2_ROOT_LIST and gen2_cleanup drops entries whose referents moved to gen2" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *c.MVMThreadContext = instance.*.main_thread;

    // A gen2 holder referencing a nursery object through MVM_ASSIGN_REF:
    // the write barrier calls MVM_gc_root_gen2_add (roots.c:304-323).
    c.MVM_gc_allocate_gen2_default_set(tc);
    var holder: ?*c.MVMException = @ptrCast(@alignCast(c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTException)));
    c.MVM_gc_allocate_gen2_default_clear(tc);
    const r = moar.root(tc, &holder);
    defer r.pop(tc);
    const h = holder.?;
    const hc: [*c]Collectable = asCol(h);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST == 0);
    const value: ?*c.MVMObject = c.MVM_repr_alloc_init(tc, instance.*.boot_types.BOOTArray);
    try std.testing.expect(value.?.header.flags2 & c.MVM_CF_SECOND_GEN == 0);
    const n0 = tc.num_gen2roots;
    moar.assignRef(tc, @ptrCast(h), @as(*[*c]c.MVMObject, &h.body.payload), value);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
    try std.testing.expectEqual(n0 + 1, tc.num_gen2roots);
    try std.testing.expect(tc.gen2roots[n0] == hc);

    // First collection: add_gen2s_to_worklist marks the holder, the payload
    // is added, so the holder stays listed (roots.c:354-358); the payload,
    // referenced from gen2, is promoted.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(h.body.payload != value);
    try std.testing.expect(h.body.payload.*.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
    try std.testing.expectEqual(n0 + 1, tc.num_gen2roots);
    try std.testing.expect(tc.gen2roots[n0] == hc);

    // Second collection: the holder references only gen2 now, nothing is
    // added, so it is slid out and its flag cleared (roots.c:363-369).
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST == 0);
    try std.testing.expectEqual(n0, tc.num_gen2roots);

    // gen2_add on a full list doubles alloc_gen2roots and keeps order.
    var fake: [100]Collectable = @splat(std.mem.zeroes(Collectable));
    const alloc0 = tc.alloc_gen2roots;
    const base = tc.num_gen2roots;
    for (&fake) |*f| roots.gen2Add(tc, f);
    try std.testing.expect(tc.alloc_gen2roots >= base + fake.len);
    try std.testing.expect(tc.alloc_gen2roots == alloc0 or tc.alloc_gen2roots == alloc0 * 2);
    try std.testing.expectEqual(base + @as(u32, fake.len), tc.num_gen2roots);
    for (&fake, 0..) |*f, i| {
        try std.testing.expect(tc.gen2roots[base + i] == f);
        try std.testing.expect(f.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
    }

    // gen2_cleanup keeps exactly the GEN2_LIVE entries, in order
    // (roots.c:383-404). The first entry is dead, so the leading-live scan
    // stops at once.
    for (&fake, 0..) |*f, i| {
        if (i % 3 == 1) f.flags2 |= c.MVM_CF_GEN2_LIVE;
    }
    roots.gen2Cleanup(tc);
    var live: u32 = 0;
    for (&fake, 0..) |*f, i| {
        if (i % 3 == 1) {
            try std.testing.expect(tc.gen2roots[base + live] == f);
            live += 1;
        }
    }
    try std.testing.expectEqual(base + live, tc.num_gen2roots);
    tc.num_gen2roots = base;
}

test "instance roots are added in the C order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    roots.addInstanceRootsToWorklist(tc, wl, null);
    // Captured from one run of the C collector (src/gc/roots.c), at commit
    // 4bf1abc71 before the [zig] line for roots.zig was added: the gc-test
    // binary of `zig build unit-test` (-Dgc-debug=0) called the C
    // MVM_gc_root_add_instance_roots_to_worklist on a fresh instance with an
    // include_gen2 worklist, five instances in a row, and printed items=37
    // each time; the first five items were the addresses of these instance
    // fields in this order (the null ones are skipped by the worklist), the
    // remaining 32 lie outside MVMInstance (callsite interns, dispatcher
    // registry). The same run with include_gen2=0 gave 0 items.
    const expected_items: u32 = 37;
    try std.testing.expectEqual(expected_items, wl.*.items);
    const base = @intFromPtr(instance);
    const fields = .{ "threads", "compiler_registry", "hll_syms", "spesh_thread", "spesh_queue" };
    inline for (fields, 0..) |f, i|
        try std.testing.expectEqual(base + @offsetOf(c.MVMInstance, f), @intFromPtr(wl.*.list[i]));
    for (fields.len..wl.*.items) |i| {
        const a = @intFromPtr(wl.*.list[i]);
        try std.testing.expect(a < base or a >= base + @sizeOf(c.MVMInstance));
    }
}

test "instance roots mark both VM event subscription types" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    // As nqp::vmeventsubscribe would set them (src/moar.c); any collectable
    // will do for the walk. roots.c:136-139 adds GCEvent and then
    // SpeshOverviewEvent, so each slot is on the worklist exactly once.
    instance.*.subscriptions.GCEvent = instance.*.VMNull;
    instance.*.subscriptions.SpeshOverviewEvent = instance.*.VMNull;
    defer {
        instance.*.subscriptions.GCEvent = null;
        instance.*.subscriptions.SpeshOverviewEvent = null;
    }
    roots.addInstanceRootsToWorklist(tc, wl, null);
    try std.testing.expectEqual(@as(u32, 37 + 2), wl.*.items);
    const gc_event = @intFromPtr(&instance.*.subscriptions.GCEvent);
    const spesh_overview = @intFromPtr(&instance.*.subscriptions.SpeshOverviewEvent);
    var seen_gc_event: u32 = 0;
    var seen_spesh_overview: u32 = 0;
    var at_gc_event: usize = 0;
    for (0..wl.*.items) |i| {
        const a = @intFromPtr(wl.*.list[i]);
        if (a == gc_event) {
            seen_gc_event += 1;
            at_gc_event = i;
        }
        if (a == spesh_overview) {
            seen_spesh_overview += 1;
            // The second subscription root, right after GCEvent.
            try std.testing.expectEqual(at_gc_event + 1, i);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), seen_gc_event);
    try std.testing.expectEqual(@as(u32, 1), seen_spesh_overview);
}

test "frame registers add only object and string registers" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);

    var types = [_]c.MVMuint16{ c.MVM_reg_obj, c.MVM_reg_int64, c.MVM_reg_str, c.MVM_reg_num64, c.MVM_reg_obj };
    var sf = std.mem.zeroes(c.MVMStaticFrame);
    sf.body.local_types = &types;
    sf.body.num_locals = types.len;
    var work: [types.len]c.MVMRegister = undefined;
    work[0] = .{ .o = instance.*.VMNull };
    work[1] = .{ .i64 = 0x12345678 };
    work[2] = .{ .s = instance.*.str_consts.empty };
    work[3] = .{ .n64 = 1.5 };
    work[4] = .{ .o = instance.*.VMNull };
    var frame = std.mem.zeroes(c.MVMFrame);
    frame.static_info = &sf;

    // No work area: nothing to scan.
    roots.addFrameRegistersToWorklist(tc, wl, &frame);
    try std.testing.expectEqual(@as(u32, 0), wl.*.items);

    // The static frame's register kinds.
    frame.work = &work;
    roots.addFrameRegistersToWorklist(tc, wl, &frame);
    try std.testing.expectEqual(@as(u32, 3), wl.*.items);
    try std.testing.expectEqual(@intFromPtr(&work[0].o), @intFromPtr(wl.*.list[0]));
    try std.testing.expectEqual(@intFromPtr(&work[2].o), @intFromPtr(wl.*.list[1]));
    try std.testing.expectEqual(@intFromPtr(&work[4].o), @intFromPtr(wl.*.list[2]));

    // A spesh candidate's register kinds take precedence.
    wl.*.items = 0;
    var cand_types = [_]c.MVMuint16{ c.MVM_reg_int64, c.MVM_reg_obj };
    var cand = std.mem.zeroes(c.MVMSpeshCandidate);
    cand.body.local_types = &cand_types;
    cand.body.num_locals = cand_types.len;
    work[1] = .{ .o = instance.*.VMNull };
    frame.spesh_cand = &cand;
    roots.addFrameRegistersToWorklist(tc, wl, &frame);
    try std.testing.expectEqual(@as(u32, 1), wl.*.items);
    try std.testing.expectEqual(@intFromPtr(&work[1].o), @intFromPtr(wl.*.list[0]));
}
