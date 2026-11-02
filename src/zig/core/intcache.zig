//! Zig port of src/core/intcache.c: the per-type cache of boxed small
//! integers (-1 .. 14) for up to four types.
const moar = @import("moar");
const c = moar.c;

const min_value: i64 = -1;
const max_value: i64 = 15; // exclusive, as MVM_INTCACHE_RANGE_CHECK

inline fn cache(tc: *moar.ThreadContext) *c.MVMIntConstCache {
    return tc.instance.*.int_const_cache;
}

inline fn mutex(tc: *moar.ThreadContext) *c.uv_mutex_t {
    return &tc.instance.*.mutex_int_const_cache;
}

fn findSlot(tc: *moar.ThreadContext, ty: *moar.Object) ?usize {
    for (&cache(tc).types, 0..) |slot, i| {
        if (slot == ty) return i;
    }
    return null;
}

export fn MVM_intcache_for(tc: *moar.ThreadContext, type_: *moar.Object) void {
    var ty = type_;
    c.uv_mutex_lock(mutex(tc));
    defer c.uv_mutex_unlock(mutex(tc));

    var right_slot: ?usize = null;
    for (&cache(tc).types, 0..) |slot, i| {
        if (slot == null) {
            right_slot = i;
            break;
        } else if (slot == ty) {
            return; // already cached; the defer unlocks
        }
    }
    const idx = right_slot orelse return;

    {
        const r = moar.root(tc, &ty);
        defer r.pop(tc);
        var val: i64 = min_value;
        while (val < max_value) : (val += 1) {
            const obj: *moar.Object = c.MVM_repr_alloc_init(tc, ty);
            c.MVM_repr_set_int(tc, obj, val);
            const entry: *[*c]moar.Object = &cache(tc).cache[idx][@intCast(val + 1)];
            entry.* = obj;
            c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(entry), "Boxed integer cache entry");
        }
    }
    const type_slot: *[*c]moar.Object = &cache(tc).types[idx];
    type_slot.* = ty;
    c.MVM_gc_root_add_permanent_desc(tc, @ptrCast(type_slot), "Boxed integer cache type");
}

export fn MVM_intcache_get(tc: *moar.ThreadContext, ty: *moar.Object, value: i64) ?*moar.Object {
    if (value < min_value or value >= max_value) return null;
    const idx = findSlot(tc, ty) orelse return null;
    return cache(tc).cache[idx][@intCast(value + 1)];
}

export fn MVM_intcache_type_index(tc: *moar.ThreadContext, ty: *moar.Object) i32 {
    c.uv_mutex_lock(mutex(tc));
    defer c.uv_mutex_unlock(mutex(tc));
    const idx = findSlot(tc, ty) orelse return -1;
    return @intCast(idx);
}
