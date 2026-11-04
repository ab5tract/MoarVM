//! The libmoar-linked test root of the GC port (`zig build unit-test`,
//! binary `gc-test`): the tests of the ports under `test/`, which boot a real
//! VM. The root sits in this directory because a module's files must lie
//! under its root file's directory.
test {
    _ = @import("test/worklist_test.zig");
    _ = @import("test/allocation_test.zig");
    _ = @import("test/gen2_test.zig");
}
