//! The libmoar-linked test root of the hash engine (`zig build unit-test`,
//! binary `hash-str-test`): the tests of the five tables under `test/` (their
//! production Specs allocate through `moar.mvm_allocator`, so none has a
//! pure-Zig test step) and `rng.zig`'s self-test, which needs the `moar`
//! module too. The root sits in this directory because a module's files must
//! lie under its root file's directory.
test {
    _ = @import("test/str_test.zig");
    _ = @import("test/ptr_test.zig");
    _ = @import("test/fixkey_test.zig");
    _ = @import("rng.zig");
    _ = @import("str.zig");
}
