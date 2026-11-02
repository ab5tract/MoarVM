//! The one module every Zig implementation file imports. Re-exports the
//! translated C API as `c` and will hold the macro shims (Task 5).
pub const c = @import("c");

pub const ThreadContext = c.MVMThreadContext;
pub const Object = c.MVMObject;
pub const Collectable = c.MVMCollectable;
pub const STable = c.MVMSTable;
pub const REPROps = c.MVMREPROps;
