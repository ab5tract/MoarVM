//! Tests of `roots.zig` (the port of src/gc/roots.c) on a booted VM.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const roots = @import("../roots.zig");

const Collectable = c.MVMCollectable;
const ColSlot = *?*Collectable;

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
    // the write barrier calls MVM_gc_root_gen2_add (roots.c:306-325).
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
    // is added, so the holder stays listed (roots.c:356-360); the payload,
    // referenced from gen2, is promoted.
    c.MVM_gc_enter_from_allocator(tc);
    try std.testing.expect(h.body.payload != value);
    try std.testing.expect(h.body.payload.*.header.flags2 & c.MVM_CF_SECOND_GEN != 0);
    try std.testing.expect(h.common.header.flags2 & c.MVM_CF_IN_GEN2_ROOT_LIST != 0);
    try std.testing.expectEqual(n0 + 1, tc.num_gen2roots);
    try std.testing.expect(tc.gen2roots[n0] == hc);

    // Second collection: the holder references only gen2 now, nothing is
    // added, so it is slid out and its flag cleared (roots.c:365-371).
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
    // (roots.c:385-406). The first entry is dead, so the leading-live scan
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

/// The description strings of src/gc/roots.c
/// `MVM_gc_root_add_instance_roots_to_worklist`, in the C order, copied
/// from the C at authoring (roots.c:70-137, 22 `add_collectable` sites; the
/// controller's "40" is not the C's number). Four are the loop and weakhash
/// sites; the other 18 are the single-field roots of `roots.instance_roots`.
const golden_instance_descriptions = [_][]const u8{
    "Thread list",
    "Compiler registry",
    "HLL symbols",
    "Command line args",
    "Event loop thread",
    "Event loop todo queue",
    "Event loop permit queue",
    "Event loop cancel queue",
    "Event loop active task list",
    "Event loop active free indices list",
    "Specialization thread",
    "Specialization log queue",
    "Integer to string cache entry",
    "SC weakhash hash key",
    "SC weakhash unresolved handle",
    "SC weakhash unclaimed SC",
    "Cached backend configuration hash",
    "Cached environment variable hash",
    "Cached signal mapping array",
    "VM Event Subscription Queue",
    "VM Event GCEvent type",
    "VM Event SpeshOverviewEvent type",
};

/// The descriptions of the instance walk that are not single-field roots.
const instance_loop_descriptions = [_][]const u8{
    "Integer to string cache entry",
    "SC weakhash hash key",
    "SC weakhash unresolved handle",
    "SC weakhash unclaimed SC",
};

fn isIn(comptime list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

/// The 18 single-field instance root slots, in the C order (roots.c:70-137),
/// as addresses: the golden list of the worklist walk.
fn goldenInstanceSlots(i: *c.MVMInstance) [18]ColSlot {
    return .{
        @ptrCast(&i.threads),
        @ptrCast(&i.compiler_registry),
        @ptrCast(&i.hll_syms),
        @ptrCast(&i.clargs),
        @ptrCast(&i.event_loop_thread),
        @ptrCast(&i.event_loop_todo_queue),
        @ptrCast(&i.event_loop_permit_queue),
        @ptrCast(&i.event_loop_cancel_queue),
        @ptrCast(&i.event_loop_active),
        @ptrCast(&i.event_loop_free_indices),
        @ptrCast(&i.spesh_thread),
        @ptrCast(&i.spesh_queue),
        @ptrCast(&i.cached_backend_config),
        @ptrCast(&i.env_hash),
        @ptrCast(&i.sig_arr),
        @ptrCast(&i.subscriptions.subscription_queue),
        @ptrCast(&i.subscriptions.GCEvent),
        @ptrCast(&i.subscriptions.SpeshOverviewEvent),
    };
}

/// A heap-snapshot stand-in: a real, zeroed `MVMHeapSnapshotState` with its
/// collection and snapshot, so `MVM_profile_heap_add_collectable_rel_const_cstr`
/// records each reference; `descriptions` reads the references back as
/// their description strings, in the order they were added.
const SnapshotRecorder = struct {
    col: c.MVMHeapSnapshotCollection = std.mem.zeroes(c.MVMHeapSnapshotCollection),
    hs: c.MVMHeapSnapshot = std.mem.zeroes(c.MVMHeapSnapshot),
    ss: c.MVMHeapSnapshotState = std.mem.zeroes(c.MVMHeapSnapshotState),

    fn init(self: *SnapshotRecorder) *c.MVMHeapSnapshotState {
        self.ss.col = &self.col;
        self.ss.hs = &self.hs;
        return &self.ss;
    }

    fn deinit(self: *SnapshotRecorder, tc: *c.MVMThreadContext) void {
        c.MVM_free(@ptrCast(self.ss.workitems));
        c.MVM_ptr_hash_demolish(tc, &self.ss.seen);
        c.MVM_free(@ptrCast(self.hs.collectables));
        c.MVM_free(@ptrCast(self.hs.references));
        c.MVM_free(@ptrCast(self.col.strings));
        c.MVM_free(@ptrCast(self.col.strings_free));
    }

    fn description(self: *const SnapshotRecorder, k: usize) [*:0]const u8 {
        const index = self.hs.references[k].description >> c.MVM_SNAPSHOT_REF_KIND_BITS;
        return @ptrCast(self.col.strings[index]);
    }

    /// The recorded descriptions of the instance walk, other references
    /// (callsite interns, dispatcher registry) dropped, runs of one string
    /// (the 65-entry integer cache) collapsed to one.
    fn walkSequence(self: *const SnapshotRecorder, out: *std.ArrayList([]const u8)) !void {
        for (0..self.hs.num_references) |k| {
            const d = std.mem.span(self.description(k));
            if (!isIn(&golden_instance_descriptions, d)) continue;
            if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], d)) continue;
            try out.append(std.testing.allocator, d);
        }
    }
};

fn expectSequence(expected: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "instance roots are added in the C order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    roots.addInstanceRootsToWorklist(tc, wl, null);
    // Captured from one run of the C collector (src/gc/roots.c), at commit
    // 9a3ebce05 before the [zig] line for roots.zig was added: the gc-test
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

    // The golden list. The table holds the 18 single-field roots, in the
    // C order, with the C's descriptions.
    const table = roots.instance_roots;
    try std.testing.expectEqual(@as(usize, golden_instance_descriptions.len - instance_loop_descriptions.len), table.len);
    const slots = goldenInstanceSlots(instance);
    var table_descs: [table.len][*:0]const u8 = undefined;
    inline for (table, &table_descs, 0..) |r, *d, k| {
        d.* = r.desc;
        try std.testing.expectEqual(@intFromPtr(slots[k]), @intFromPtr(r.get(instance)));
    }
    {
        var k: usize = 0;
        for (golden_instance_descriptions) |d| {
            if (isIn(&instance_loop_descriptions, d)) continue;
            try std.testing.expectEqualStrings(d, std.mem.span(table_descs[k]));
            k += 1;
        }
    }

    // Make every site of the walk fire: each field root non-null, one
    // integer cache entry, and the weak hash's one entry (the SC a fresh
    // instance registers at boot) unclaimed.
    var was_null: [slots.len]bool = undefined;
    for (slots, &was_null) |s, *n| {
        n.* = s.* == null;
        if (n.*) s.* = @ptrCast(instance.*.VMNull);
    }
    defer for (slots, was_null) |s, n| {
        if (n) s.* = null;
    };
    const cache0: *?*c.MVMString = @ptrCast(&instance.*.int_to_str_cache[0]);
    const cache0_was = cache0.*;
    if (cache0_was == null) cache0.* = instance.*.str_consts.empty;
    defer cache0.* = cache0_was;
    const weakhash = &instance.*.sc_weakhash;
    const it = c.MVM_str_hash_first(tc, weakhash);
    try std.testing.expect(c.MVM_str_hash_at_end(tc, weakhash, it) == 0);
    const entry: *c.MVMSerializationContextWeakHashEntry = @ptrCast(@alignCast(c.MVM_str_hash_current_nocheck(tc, weakhash, it)));
    try std.testing.expect(c.MVM_str_hash_at_end(tc, weakhash, c.MVM_str_hash_next_nocheck(tc, weakhash, it)) != 0);
    const scb: *c.MVMSerializationContextBody = entry.scb;
    try std.testing.expect(scb.sc != null);
    const claimed = scb.claimed;
    scb.claimed = 0;
    defer scb.claimed = claimed;

    // The worklist walk: the items inside MVMInstance are the 18 field
    // slots, in the C order.
    wl.*.items = 0;
    roots.addInstanceRootsToWorklist(tc, wl, null);
    {
        var k: usize = 0;
        for (0..wl.*.items) |i| {
            const a = @intFromPtr(wl.*.list[i]);
            if (a < base or a >= base + @sizeOf(c.MVMInstance)) continue;
            try std.testing.expect(k < slots.len);
            try std.testing.expectEqual(@intFromPtr(slots[k]), a);
            k += 1;
        }
        try std.testing.expectEqual(slots.len, k);
    }

    // The heap-snapshot walk, twice: the weak hash entry takes "unclaimed
    // SC" while its SC is set, "unresolved handle" without it.
    inline for (.{ "SC weakhash unresolved handle", "SC weakhash unclaimed SC" }) |absent| {
        const sc = scb.sc;
        if (comptime std.mem.eql(u8, absent, "SC weakhash unclaimed SC")) scb.sc = null;
        defer scb.sc = sc;
        var rec: SnapshotRecorder = .{};
        const ss = rec.init();
        defer rec.deinit(tc);
        roots.addInstanceRootsToWorklist(tc, null, ss);
        var got: std.ArrayList([]const u8) = .empty;
        defer got.deinit(std.testing.allocator);
        try rec.walkSequence(&got);
        var expected: std.ArrayList([]const u8) = .empty;
        defer expected.deinit(std.testing.allocator);
        for (golden_instance_descriptions) |d| {
            if (!std.mem.eql(u8, d, absent)) try expected.append(std.testing.allocator, d);
        }
        try expectSequence(expected.items, got.items);
        // Each field root is described once, through the table's own string.
        var from_table: usize = 0;
        for (0..rec.hs.num_references) |k| {
            const d = rec.description(k);
            for (table_descs) |t| {
                if (d == t) from_table += 1;
            }
        }
        try std.testing.expectEqual(table.len, from_table);
    }
}

/// The description strings of the single-field roots of src/gc/roots.c
/// `MVM_gc_root_add_tc_roots_to_worklist`, in the C order (roots.c:157-232),
/// copied from the C at authoring; the handler, callback cache and
/// mark_args loops are not in the table.
const golden_tc_descriptions = [_][]const u8{
    "Current bytecode frame",
    "Last exception payload",
    "Thread object",
    "Thread entry frame",
    "Last handler result",
    "Compiling serialization contexts",
    "Current interpreter compilation unit",
    "Specialization log",
    "Current static frame for watching for OSR spesh candidate",
    "Frame referenced for stepping mode",
};

/// The index of the interp_cu entry of `roots.thread_roots`, found by its
/// description so a reordering of the table cannot point the test elsewhere.
const interp_cu_root = blk: {
    for (roots.thread_roots, 0..) |r, i| {
        if (std.mem.eql(u8, std.mem.span(r.desc), "Current interpreter compilation unit")) break :blk i;
    }
    @compileError("no thread root describes interp_cu");
};

test "thread roots are added in the C order" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc: *c.MVMThreadContext = instance.*.main_thread;
    const table = roots.thread_roots;
    try std.testing.expectEqual(golden_tc_descriptions.len, table.len);
    inline for (golden_tc_descriptions, table) |d, r|
        try std.testing.expectEqualStrings(d, std.mem.span(r.desc));

    // interp_cu is the address of the interpreter's compunit variable, or
    // NULL when no interpreter runs: no slot then.
    const interp_cu = tc.interp_cu;
    defer tc.interp_cu = interp_cu;
    tc.interp_cu = null;
    try std.testing.expect(!table[interp_cu_root].when(tc));
    var cu: ?*c.MVMCompUnit = null;
    tc.interp_cu = @ptrCast(&cu);

    // The single-field slots (interp_cu is the slot the tc points at), in
    // the C order.
    const slots = [_]ColSlot{
        @ptrCast(&tc.cur_frame),
        @ptrCast(&tc.last_payload),
        @ptrCast(&tc.thread_obj),
        @ptrCast(&tc.thread_entry_frame),
        @ptrCast(&tc.last_handler_result),
        @ptrCast(&tc.compiling_scs),
        @ptrCast(&cu),
        @ptrCast(&tc.spesh_log),
        @ptrCast(&tc.osr_hunt_static_frame),
        @ptrCast(&tc.step_mode_frame),
    };
    inline for (table, 0..) |r, k|
        try std.testing.expectEqual(@intFromPtr(slots[k]), @intFromPtr(r.get(tc)));
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

test "tc roots add dispatch resumption init args of object and string kind" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const wl = c.MVM_gc_worklist_create(tc, 1);
    defer c.MVM_gc_worklist_destroy(tc, wl);
    roots.addTcRootsToWorklist(tc, wl, null);
    const without = wl.*.items;
    wl.*.items = 0;

    // As resume_init_capture sets it (src/disp/program.c). roots.c:233-241
    // adds the object and string arguments through add_collectable, the
    // last roots of the tc walk. This covers the GC (worklist) path only,
    // not the heap snapshot branch of add_collectable, which would need a
    // real MVMHeapSnapshotState.
    var flags = [_]c.MVMCallsiteEntry{ c.MVM_CALLSITE_ARG_OBJ, c.MVM_CALLSITE_ARG_INT, c.MVM_CALLSITE_ARG_STR };
    var cs = std.mem.zeroes(c.MVMCallsite);
    cs.arg_flags = &flags;
    cs.flag_count = flags.len;
    var source: [3]c.MVMRegister = undefined;
    source[0] = .{ .s = instance.*.str_consts.empty };
    source[1] = .{ .i64 = 0x12345678 };
    source[2] = .{ .o = instance.*.VMNull };
    var map = [_]c.MVMuint16{ 2, 1, 0 };
    var args = c.MVMArgs{ .callsite = &cs, .source = &source, .map = &map };
    tc.*.mark_args = &args;
    defer tc.*.mark_args = null;
    roots.addTcRootsToWorklist(tc, wl, null);
    try std.testing.expectEqual(without + 2, wl.*.items);
    try std.testing.expectEqual(@intFromPtr(&source[2].o), @intFromPtr(wl.*.list[without]));
    try std.testing.expectEqual(@intFromPtr(&source[0].o), @intFromPtr(wl.*.list[without + 1]));
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
