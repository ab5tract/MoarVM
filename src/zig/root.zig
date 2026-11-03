//! Root of the `moar_zig` object. Each implementation file listed in the
//! [zig] section of build/sources.list must be referenced here so that its
//! `export fn`s are emitted; the build checks this.
/// Read by core/hash/stats.zig through `@import("root")`.
pub const hash_stats = @import("zig_options").hash_stats;

comptime {
    _ = @import("platform/time.zig");
    _ = @import("core/intcache.zig");
    _ = @import("core/hash/str_exports.zig");
    _ = @import("core/hash/ptr_exports.zig");
    _ = @import("core/hash/fixkey_exports.zig");
    _ = @import("core/hash/index_exports.zig");
    _ = @import("core/hash/uni_exports.zig");
}
