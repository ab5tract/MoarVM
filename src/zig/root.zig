//! Root of the `moar_zig` object. Each implementation file listed in the
//! [zig] section of build/sources.list must be referenced here so that its
//! `export fn`s are emitted; the build checks this.
comptime {
    _ = @import("platform/time.zig");
    _ = @import("core/intcache.zig");
    _ = @import("core/hash/str_exports.zig");
    _ = @import("core/hash/ptr_exports.zig");
    _ = @import("core/hash/fixkey_exports.zig");
    _ = @import("core/hash/index_exports.zig");
    _ = @import("core/hash/uni_exports.zig");
    _ = @import("gc/worklist.zig");
    _ = @import("gc/allocation.zig");
    _ = @import("gc/gen2.zig");
    _ = @import("gc/roots.zig");
    _ = @import("gc/collect.zig");
    _ = @import("gc/wb.zig");
    _ = @import("gc/objectid.zig");
    _ = @import("gc/finalize.zig");
    _ = @import("gc/debug.zig");
}
