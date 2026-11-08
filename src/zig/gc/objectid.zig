//! Zig port of src/gc/objectid.c (lines 1-54): stable object ids for
//! nursery objects, which reserve their gen2 address up front. Faithful
//! port; no behaviour change. The `MVM_ptr_hash_*` calls go through `c.`
//! (they resolve to the Zig hash engine's exports); the instance's
//! `mutex_object_ids` through `c.uv_mutex_*`; the gen2 reservation through
//! `c.MVM_gc_gen2_allocate_zeroed`.
const std = @import("std");
const builtin = @import("builtin");
const moar = @import("moar");
const c = moar.c;

const Tc = [*c]c.MVMThreadContext;
const Col = [*c]c.MVMCollectable;
const Object = [*c]c.MVMObject;

/// C `assert`: checked only when the C is built without NDEBUG, which the
/// build ties to a Debug optimize mode.
inline fn cAssert(ok: bool) void {
    if (comptime builtin.mode == .debug) std.debug.assert(ok);
}

/// Gets a stable identifier for an object, which will not change even if
/// the GC moves the object. (objectid.c:5-35)
pub fn objectId(tc: Tc, obj: Object) callconv(.c) c.MVMuint64 {
    var id: c.MVMuint64 = undefined;

    // If it's already in the old generation, just use memory address, as
    // gen2 objects never move.
    if ((obj.*.header.flags2 & c.MVM_CF_SECOND_GEN) != 0) {
        id = @intFromPtr(obj);
    }

    // Otherwise, see if we already have a persistent object ID.
    else {
        c.uv_mutex_lock(&tc.*.instance.*.mutex_object_ids);
        if ((obj.*.header.flags1 & c.MVM_CF_HAS_OBJECT_ID) != 0) {
            // Has one, so just look up by address in the hash ID hash.
            const entry = c.MVM_ptr_hash_fetch(tc, &tc.*.instance.*.object_ids, obj);
            cAssert(entry != null);
            id = entry.*.value;
        } else {
            // Hasn't got one; allocate it a place in gen2 and make an entry
            // in the persistent object ID hash.
            id = @intFromPtr(c.MVM_gc_gen2_allocate_zeroed(tc.*.gen2, obj.*.header.size));
            c.MVM_ptr_hash_insert(tc, &tc.*.instance.*.object_ids, obj, @intCast(id));
            obj.*.header.flags1 |= c.MVM_CF_HAS_OBJECT_ID;
        }
        c.uv_mutex_unlock(&tc.*.instance.*.mutex_object_ids);
    }

    return id;
}

/// If an object with an entry here lives long enough to be promoted to
/// gen2, this removes the hash entry for it and returns the pre-allocated
/// gen2 address. (objectid.c:40-46)
pub fn useAllocation(tc: Tc, item: Col) callconv(.c) ?*anyopaque {
    c.uv_mutex_lock(&tc.*.instance.*.mutex_object_ids);
    const addr: ?*anyopaque = @ptrFromInt(c.MVM_ptr_hash_fetch_and_delete(tc, &tc.*.instance.*.object_ids, item));
    item.*.flags1 ^= c.MVM_CF_HAS_OBJECT_ID;
    c.uv_mutex_unlock(&tc.*.instance.*.mutex_object_ids);
    return addr;
}

/// Clears hash entry for a persistent object ID when an object dies in the
/// nursery. (objectid.c:50-54)
pub fn clear(tc: Tc, item: Col) callconv(.c) void {
    c.uv_mutex_lock(&tc.*.instance.*.mutex_object_ids);
    _ = c.MVM_ptr_hash_fetch_and_delete(tc, &tc.*.instance.*.object_ids, item);
    c.uv_mutex_unlock(&tc.*.instance.*.mutex_object_ids);
}

// Under -Dlto (--zig-lto) the exports are protected: they stay in libmoar's
// dynamic table for outside callers, while calls from inside libmoar bind to
// these definitions, which is what lets the LTO link inline them into their
// C callers. Otherwise they are plain default-visibility exports.
const visibility: std.lang.SymbolVisibility = if (@import("zig_options").lto) .protected else .default;

comptime {
    @export(&objectId, .{ .name = "MVM_gc_object_id", .visibility = visibility });
    @export(&useAllocation, .{ .name = "MVM_gc_object_id_use_allocation", .visibility = visibility });
    @export(&clear, .{ .name = "MVM_gc_object_id_clear", .visibility = visibility });
}
