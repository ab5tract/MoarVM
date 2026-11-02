//! The libmoar-linked test root of the hash engine (`zig build unit-test`,
//! binary `hash-str-test`): the string table tests of `test/str_test.zig`
//! and `rng.zig`'s self-test, which needs the `moar` module and so has no
//! pure-Zig test step. The root sits in this directory because a module's
//! files must lie under its root file's directory.
test {
    _ = @import("test/str_test.zig");
    _ = @import("rng.zig");
    _ = @import("str.zig");
}
