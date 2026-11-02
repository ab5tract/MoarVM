//! Root of the `moar_zig` object. Each implementation file listed in the
//! [zig] section of build/sources.list must be referenced here so that its
//! `export fn`s are emitted; the build checks this.
comptime {
    // Implementation files are added here, one line each, e.g.
    // _ = @import("platform/time.zig");
}
