//! Tests of `repr.zig` (the vtable builder `Ops`, its checker `declError`
//! and the table dump `dumpOps`): stub REPRs that declare a few functions,
//! and the array table of the linked library against the dump recorded from
//! the C table (`vmarray_vtable_c.tsv`, from a `-Dzig-reprs=false` build).
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const repr = @import("../repr.zig");

// Stub functions of the four required slots' types. They are never called.
fn typeObjectFor(tc: [*c]c.MVMThreadContext, how: [*c]c.MVMObject) callconv(.c) [*c]c.MVMObject {
    _ = tc;
    _ = how;
    return null;
}
fn allocateStub(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable) callconv(.c) [*c]c.MVMObject {
    _ = tc;
    _ = st;
    return null;
}
fn getStorageSpec(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable) callconv(.c) [*c]const c.MVMStorageSpec {
    _ = tc;
    _ = st;
    return null;
}
fn composeStub(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable, info: [*c]c.MVMObject) callconv(.c) void {
    _ = tc;
    _ = st;
    _ = info;
}
fn pushStub(tc: [*c]c.MVMThreadContext, st: [*c]c.MVMSTable, root: [*c]c.MVMObject, data: ?*anyopaque, value: c.MVMRegister, kind: c.MVMuint16) callconv(.c) void {
    _ = tc;
    _ = st;
    _ = root;
    _ = data;
    _ = value;
    _ = kind;
}

/// Declares exactly the required slots.
const Minimal = struct {
    pub const name = "Minimal";
    pub const ID = 99;
    pub const type_object_for = typeObjectFor;
    pub const allocate = allocateStub;
    pub const get_storage_spec = getStorageSpec;
    pub const compose = composeStub;
    // Not pub: a helper, not part of the REPR's interface, so ignored.
    const helper = 1;
};

/// Minimal plus one positional function.
const WithPush = struct {
    pub const name = "Minimal";
    pub const ID = 99;
    pub const type_object_for = typeObjectFor;
    pub const allocate = allocateStub;
    pub const get_storage_spec = getStorageSpec;
    pub const compose = composeStub;
    pub const pos_funcs = struct {
        pub const push = pushStub;
    };
};

fn dump(ops: *const c.MVMREPROps) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try repr.dumpOps(ops, &out.writer);
    return out.toOwnedSlice();
}

fn addr(p: anytype) usize {
    return @intFromPtr(p);
}

test "a REPR that declares only the required functions gets every default" {
    const ops = comptime repr.Ops(Minimal);
    try std.testing.expectEqual(addr(&c.MVM_REPR_DEFAULT_AT_POS), addr(ops.pos_funcs.at_pos.?));
    try std.testing.expectEqual(addr(&c.MVM_REPR_DEFAULT_GET_INT), addr(ops.box_funcs.get_int.?));
    try std.testing.expectEqual(addr(&c.MVM_REPR_DEFAULT_AT_KEY), addr(ops.ass_funcs.at_key.?));
    try std.testing.expectEqual(addr(&c.MVM_REPR_DEFAULT_GET_ATTRIBUTE), addr(ops.attr_funcs.get_attribute.?));
    try std.testing.expectEqual(addr(&c.MVM_REPR_DEFAULT_ELEMS), addr(ops.elems.?));
    try std.testing.expect(ops.initialize == null);
    try std.testing.expect(ops.gc_cleanup == null);
    try std.testing.expectEqualStrings("Minimal", std.mem.span(ops.name));
    try std.testing.expectEqual(@as(u32, 99), ops.ID);

    // Every other leaf: the four declared functions are `own`, `name` and
    // `ID` their values, and every remaining one `default` or `null`. The
    // five default groups of reprs.h hold 5 + 9 + 18 + 5 + 1 functions.
    const text = try dump(&ops);
    defer std.testing.allocator.free(text);
    var defaults: usize = 0;
    var nulls: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const path = cols.next().?;
        const class = cols.next().?;
        if (std.mem.eql(u8, path, "name")) {
            try std.testing.expectEqualStrings("Minimal", class);
        } else if (std.mem.eql(u8, path, "ID")) {
            try std.testing.expectEqualStrings("99", class);
        } else if (std.mem.eql(u8, class, "own")) {
            const declared = [_][]const u8{ "type_object_for", "allocate", "get_storage_spec", "compose" };
            for (declared) |d| {
                if (std.mem.eql(u8, d, path)) break;
            } else return error.UndeclaredOwnSlot;
        } else if (std.mem.eql(u8, class, "default")) {
            defaults += 1;
        } else {
            try std.testing.expectEqualStrings("null", class);
            nulls += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 38), defaults);
    // initialize, copy_to, change_type, serialize, deserialize, the three
    // repr-data/size (de)serializers, gc_mark, gc_free, gc_cleanup,
    // gc_mark_repr_data, gc_free_repr_data, spesh, unmanaged_size,
    // describe_refs.
    try std.testing.expectEqual(@as(usize, 16), nulls);
}

test "a declared function replaces its default and no other" {
    const minimal = comptime repr.Ops(Minimal);
    const with_push = comptime repr.Ops(WithPush);
    try std.testing.expectEqual(addr(&pushStub), addr(with_push.pos_funcs.push.?));
    const a = try dump(&minimal);
    defer std.testing.allocator.free(a);
    const b = try dump(&with_push);
    defer std.testing.allocator.free(b);
    var la = std.mem.splitScalar(u8, a, '\n');
    var lb = std.mem.splitScalar(u8, b, '\n');
    var differing: usize = 0;
    while (la.next()) |x| {
        const y = lb.next() orelse return error.DumpsDifferInLength;
        if (std.mem.eql(u8, x, y)) continue;
        differing += 1;
        try std.testing.expectEqualStrings("pos_funcs.push\tdefault", x);
        try std.testing.expectEqualStrings("pos_funcs.push\town", y);
    }
    try std.testing.expect(lb.next() == null);
    try std.testing.expectEqual(@as(usize, 1), differing);
}

test "declError names an unknown, a mistyped and a missing declaration" {
    const Unknown = struct {
        pub const name = "Unknown";
        pub const ID = 99;
        pub const type_object_for = typeObjectFor;
        pub const allocate = allocateStub;
        pub const get_storage_spec = getStorageSpec;
        pub const compose = composeStub;
        pub const pos_funcs = struct {
            pub const pussh = pushStub;
        };
    };
    const Mistyped = struct {
        pub const name = "Mistyped";
        pub const ID = 99;
        pub const type_object_for = typeObjectFor;
        pub const allocate = typeObjectFor;
        pub const get_storage_spec = getStorageSpec;
        pub const compose = composeStub;
    };
    const Missing = struct {
        pub const name = "Missing";
        pub const ID = 99;
        pub const type_object_for = typeObjectFor;
        pub const allocate = allocateStub;
        pub const get_storage_spec = getStorageSpec;
    };
    const unknown = comptime repr.declError(Unknown).?;
    const mistyped = comptime repr.declError(Mistyped).?;
    const missing = comptime repr.declError(Missing).?;
    try std.testing.expectEqualStrings(@typeName(Unknown) ++ ": unknown REPR function 'pos_funcs.pussh'", unknown);
    try std.testing.expectEqualStrings(@typeName(Mistyped) ++ ": 'allocate' has the wrong type; the field is " ++
        @typeName(@FieldType(c.MVMREPROps, "allocate")), mistyped);
    try std.testing.expectEqualStrings(@typeName(Missing) ++ ": missing required 'compose'", missing);
    try std.testing.expect(comptime repr.declError(Minimal) == null);
    try std.testing.expect(comptime repr.declError(WithPush) == null);
}

test "a C function can fill a slot" {
    const WithC = struct {
        pub const name = "WithC";
        pub const ID = 99;
        pub const type_object_for = typeObjectFor;
        pub const allocate = &c.MVM_gc_allocate_object;
        pub const get_storage_spec = getStorageSpec;
        pub const compose = composeStub;
    };
    const ops = comptime repr.Ops(WithC);
    try std.testing.expectEqual(addr(&c.MVM_gc_allocate_object), addr(ops.allocate.?));
}

test "the linked library's array table has the C table's shape" {
    const instance = c.MVM_vm_create_instance();
    defer c.MVM_vm_destroy_instance(instance);
    const tc = instance.*.main_thread;
    const text = try dump(c.MVMArray_initialize(tc));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(@embedFile("vmarray_vtable_c.tsv"), text);
}
