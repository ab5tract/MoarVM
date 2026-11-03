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
    _ = @import("test/index_test.zig");
    _ = @import("test/uni_test.zig");
    _ = @import("rng.zig");
    _ = @import("str.zig");
    _ = @import("bench.zig");
    _ = @import("stats.zig");
}

test "the four single-rung tables dispatch without a set comparison" {
    comptime {
        for (.{ @import("ptr.zig").PtrTable, @import("uni.zig").UniTable, @import("index.zig").IndexTable, @import("fixkey.zig").FixKeyTable }) |T| {
            if (T.dispatch_reads_set) @compileError("a single-set table reads the set byte in dispatch");
        }
    }
}
