//! Zig port of src/gc/objectid.c (lines 1-54): stable object ids for
//! nursery objects, which reserve their gen2 address up front. No behaviour
//! change. The `MVM_ptr_hash_*` calls go through `c.` (they resolve to the
//! Zig hash engine's exports); the instance's `mutex_object_ids` through
//! `c.uv_mutex_*`, held over the same statements as the C; the gen2
//! reservation is the gen2 port's `allocateZeroed`, called as Zig. The
//! functions are Zig-typed; the `MVM_gc_object_id*` exports are thin C-ABI
//! wrappers over them.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;
const view = @import("view.zig");
const gen2_mod = @import("gen2.zig");

const Tc = view.Tc;
const Col = view.Col;
const Object = view.Object;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.optimize == .debug) std.debug.assert(ok);
}

/// Gets a stable identifier for an object, which will not change even if
/// the GC moves the object. (objectid.c:5-35)
pub fn objectId(tc: Tc, obj: Object) u64 {
    // If it's already in the old generation, just use memory address, as
    // gen2 objects never move.
    if (view.flags2(&obj.header).second_gen)
        return @intFromPtr(obj);

    // Otherwise, see if we already have a persistent object ID.
    const i: view.Instance = tc.instance;
    c.uv_mutex_lock(&i.mutex_object_ids);
    defer c.uv_mutex_unlock(&i.mutex_object_ids);
    if (view.flags1(&obj.header).has_object_id) {
        // Has one, so just look up by address in the hash ID hash.
        const entry: ?*c.MVMPtrHashEntry = c.MVM_ptr_hash_fetch(tc, &i.object_ids, obj);
        cAssert(entry != null);
        return entry.?.value;
    }
    // Hasn't got one; allocate it a place in gen2 and make an entry in the
    // persistent object ID hash.
    const id: usize = @intFromPtr(gen2_mod.allocateZeroed(tc.gen2, obj.header.size));
    c.MVM_ptr_hash_insert(tc, &i.object_ids, obj, id);
    view.flags1(&obj.header).has_object_id = true;
    return id;
}

/// If an object with an entry here lives long enough to be promoted to
/// gen2, this removes the hash entry for it and returns the pre-allocated
/// gen2 address, or null when the hash has no entry for it (the C returns
/// the hash's 0 as NULL). (objectid.c:40-46) The collector calls this only
/// with `MVM_CF_HAS_OBJECT_ID` set, which implies an entry, and unwraps
/// the result with `.?` as the faithful port did.
pub fn useAllocation(tc: Tc, item: Col) ?*anyopaque {
    const i: view.Instance = tc.instance;
    c.uv_mutex_lock(&i.mutex_object_ids);
    defer c.uv_mutex_unlock(&i.mutex_object_ids);
    const addr = c.MVM_ptr_hash_fetch_and_delete(tc, &i.object_ids, item);
    // `flags1 ^= MVM_CF_HAS_OBJECT_ID`: a toggle, as the C's.
    const f1 = view.flags1(item);
    f1.has_object_id = !f1.has_object_id;
    if (addr == 0) return null;
    return @ptrFromInt(addr);
}

/// Clears hash entry for a persistent object ID when an object dies in the
/// nursery. (objectid.c:50-54)
pub fn clear(tc: Tc, item: Col) void {
    const i: view.Instance = tc.instance;
    c.uv_mutex_lock(&i.mutex_object_ids);
    defer c.uv_mutex_unlock(&i.mutex_object_ids);
    _ = c.MVM_ptr_hash_fetch_and_delete(tc, &i.object_ids, item);
}

// ---- the C ABI -------------------------------------------------------------

fn objectIdExport(tc: [*c]c.MVMThreadContext, obj: [*c]c.MVMObject) callconv(.c) c.MVMuint64 {
    return objectId(tc, obj);
}

fn useAllocationExport(tc: [*c]c.MVMThreadContext, item: [*c]c.MVMCollectable) callconv(.c) ?*anyopaque {
    return useAllocation(tc, item);
}

fn clearExport(tc: [*c]c.MVMThreadContext, item: [*c]c.MVMCollectable) callconv(.c) void {
    clear(tc, item);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&objectIdExport, .{ .name = "MVM_gc_object_id", .visibility = visibility });
    @export(&useAllocationExport, .{ .name = "MVM_gc_object_id_use_allocation", .visibility = visibility });
    @export(&clearExport, .{ .name = "MVM_gc_object_id_clear", .visibility = visibility });
}
