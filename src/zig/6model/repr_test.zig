//! The libmoar-linked test root of the REPR mechanism (`zig build
//! unit-test`, binary `repr-test`): the tests under `test/`, which reach the
//! C default functions and, for the array table, boot a real VM. It runs
//! with `-Dzig-reprs` on or off. The root sits in this directory because a
//! module's files must lie under its root file's directory.
test {
    _ = @import("test/repr_ops_test.zig");
    _ = @import("test/vmarray_storage_test.zig");
    _ = @import("test/vmarray_elements_test.zig");
    _ = @import("test/vmarray_serial_test.zig");
}
