//! The REPR vtable builder: `Ops(R)` turns a Zig struct type `R`, which
//! declares a REPR's name, ID and functions, into the complete
//! `c.MVMREPROps` table the VM calls through (the C struct of
//! src/6model/6model.h, reached through translate-c).
//!
//! In C a REPR writes that table as one positional initializer, a value per
//! field in struct order, with the `MVM_REPR_DEFAULT_*_FUNCS` macros of
//! src/6model/reprs.h standing in for the nested tables it does not
//! implement and `NULL` for the hooks it lacks. Here the REPR names what it
//! implements instead, and the builder supplies the rest:
//!
//! - `R`'s public declarations are named after the fields of
//!   `c.MVMREPROps`. The four nested tables (`attr_funcs`, `box_funcs`,
//!   `pos_funcs`, `ass_funcs`) are given as nested struct types whose public
//!   declarations are named after the nested fields. `name` is a
//!   `[:0]const u8` (a string literal will do) and `ID` an integer.
//! - A function slot is declared as a Zig function with the C calling
//!   convention (`fn (...) callconv(.c) ...`) or as a pointer to a C
//!   function (`&c.MVM_gc_allocate_object`); either way its type must be
//!   exactly the field's function type.
//! - Every field `R` does not declare gets what the C macros give it: the
//!   `MVM_REPR_DEFAULT_*` function of `default_functions` below (the C
//!   functions are referenced, not reimplemented), or null for a field
//!   with no default function. `name`, `ID`, `type_object_for`, `allocate`,
//!   `get_storage_spec` and `compose` have no default and are required.
//! - A declaration that is not `pub` is not part of the interface and is
//!   ignored, so `R` may keep private helpers. A public declaration whose
//!   name matches no field, or whose type does not match its field, is a
//!   compile error (`declError`): a misspelt hook never silently becomes a
//!   default.
//!
//! The walk over the table is driven by `@typeInfo(c.MVMREPROps)`, so the
//! field list is the C header's and is not repeated here; the only thing
//! written out by hand is which field has which default function.
//! `dumpOps` prints a table one leaf field per line, which is how a built
//! table is compared with a C one.
const std = @import("std");
const c = @import("moar").c;

/// The fields a REPR must declare, in the order `declError` reports them
/// missing: they have no default function and no C REPR leaves them NULL.
const required = [_][]const u8{ "name", "ID", "type_object_for", "allocate", "get_storage_spec", "compose" };

/// The default function of each field that has one, keyed by the field's
/// path (`<table>.<field>` for the nested tables): the expansion of
/// `MVM_REPR_DEFAULT_ATTR_FUNCS`, `_BOX_FUNCS`, `_POS_FUNCS` and
/// `_ASS_FUNCS` in src/6model/reprs.h, plus `MVM_REPR_DEFAULT_ELEMS`, which
/// C REPRs name for `elems`. A field missing from this table defaults to
/// null. The comptime block after it checks that every path names a field
/// and every pointer has that field's type, so a typo here fails the build.
const default_functions = .{
    .{ "attr_funcs.get_attribute", &c.MVM_REPR_DEFAULT_GET_ATTRIBUTE },
    .{ "attr_funcs.bind_attribute", &c.MVM_REPR_DEFAULT_BIND_ATTRIBUTE },
    .{ "attr_funcs.hint_for", &c.MVM_REPR_DEFAULT_HINT_FOR },
    .{ "attr_funcs.is_attribute_initialized", &c.MVM_REPR_DEFAULT_IS_ATTRIBUTE_INITIALIZED },
    .{ "attr_funcs.attribute_as_atomic", &c.MVM_REPR_DEFAULT_ATTRIBUTE_AS_ATOMIC },

    .{ "box_funcs.set_int", &c.MVM_REPR_DEFAULT_SET_INT },
    .{ "box_funcs.get_int", &c.MVM_REPR_DEFAULT_GET_INT },
    .{ "box_funcs.set_num", &c.MVM_REPR_DEFAULT_SET_NUM },
    .{ "box_funcs.get_num", &c.MVM_REPR_DEFAULT_GET_NUM },
    .{ "box_funcs.set_str", &c.MVM_REPR_DEFAULT_SET_STR },
    .{ "box_funcs.get_str", &c.MVM_REPR_DEFAULT_GET_STR },
    .{ "box_funcs.set_uint", &c.MVM_REPR_DEFAULT_SET_UINT },
    .{ "box_funcs.get_uint", &c.MVM_REPR_DEFAULT_GET_UINT },
    .{ "box_funcs.get_boxed_ref", &c.MVM_REPR_DEFAULT_GET_BOXED_REF },

    .{ "pos_funcs.at_pos", &c.MVM_REPR_DEFAULT_AT_POS },
    .{ "pos_funcs.bind_pos", &c.MVM_REPR_DEFAULT_BIND_POS },
    .{ "pos_funcs.set_elems", &c.MVM_REPR_DEFAULT_SET_ELEMS },
    .{ "pos_funcs.push", &c.MVM_REPR_DEFAULT_PUSH },
    .{ "pos_funcs.pop", &c.MVM_REPR_DEFAULT_POP },
    .{ "pos_funcs.unshift", &c.MVM_REPR_DEFAULT_UNSHIFT },
    .{ "pos_funcs.shift", &c.MVM_REPR_DEFAULT_SHIFT },
    .{ "pos_funcs.slice", &c.MVM_REPR_DEFAULT_SLICE },
    .{ "pos_funcs.splice", &c.MVM_REPR_DEFAULT_SPLICE },
    .{ "pos_funcs.at_pos_multidim", &c.MVM_REPR_DEFAULT_AT_POS_MULTIDIM },
    .{ "pos_funcs.bind_pos_multidim", &c.MVM_REPR_DEFAULT_BIND_POS_MULTIDIM },
    .{ "pos_funcs.dimensions", &c.MVM_REPR_DEFAULT_DIMENSIONS },
    .{ "pos_funcs.set_dimensions", &c.MVM_REPR_DEFAULT_SET_DIMENSIONS },
    .{ "pos_funcs.get_elem_storage_spec", &c.MVM_REPR_DEFAULT_GET_ELEM_STORAGE_SPEC },
    .{ "pos_funcs.pos_as_atomic", &c.MVM_REPR_DEFAULT_POS_AS_ATOMIC },
    .{ "pos_funcs.pos_as_atomic_multidim", &c.MVM_REPR_DEFAULT_POS_AS_ATOMIC_MULTIDIM },
    .{ "pos_funcs.write_buf", &c.MVM_REPR_DEFAULT_POS_WRITE_BUF },
    .{ "pos_funcs.read_buf", &c.MVM_REPR_DEFAULT_POS_READ_BUF },

    .{ "ass_funcs.at_key", &c.MVM_REPR_DEFAULT_AT_KEY },
    .{ "ass_funcs.bind_key", &c.MVM_REPR_DEFAULT_BIND_KEY },
    .{ "ass_funcs.exists_key", &c.MVM_REPR_DEFAULT_EXISTS_KEY },
    .{ "ass_funcs.delete_key", &c.MVM_REPR_DEFAULT_DELETE_KEY },
    .{ "ass_funcs.get_value_storage_spec", &c.MVM_REPR_DEFAULT_GET_VALUE_STORAGE_SPEC },

    .{ "elems", &c.MVM_REPR_DEFAULT_ELEMS },
};

/// The compile-time branch budget of the walks below: generous enough for
/// the 60 leaf fields against the 38 defaults and any REPR's declarations.
const eval_quota = 100_000;

// Generates nothing: each entry of `default_functions` must name a leaf
// field (`LeafType` fails otherwise) and its pointer must coerce to that
// field's type (`@as` fails otherwise).
comptime {
    for (default_functions) |entry| _ = @as(LeafType(entry[0]), entry[1]);
}

/// The type of the field of `c.MVMREPROps` at `path` (`"elems"` or
/// `"pos_funcs.at_pos"`); a compile error if there is none.
fn LeafType(comptime path: []const u8) type {
    const dot = std.mem.findScalar(u8, path, '.') orelse return @FieldType(c.MVMREPROps, path);
    return @FieldType(@FieldType(c.MVMREPROps, path[0..dot]), path[dot + 1 ..]);
}

/// The default of the field at `path` as a value of the field's type `F`:
/// its entry in `default_functions`, or null when it has none. Generates no
/// code: the `inline for` keeps at most the one matching entry.
fn defaultFor(comptime path: []const u8, comptime F: type) F {
    @setEvalBranchQuota(eval_quota);
    inline for (default_functions) |entry| {
        if (comptime std.mem.eql(u8, entry[0], path)) return entry[1];
    }
    return null;
}

/// Builds the vtable of the REPR declared by `R`, at compile time.
///
/// The result has one value per leaf field of `c.MVMREPROps`, chosen in
/// this order: `R`'s public declaration of that name (for a nested table,
/// `R.<table>`'s), else the field's `MVM_REPR_DEFAULT_*` function from
/// `default_functions`, else null. `name` becomes a pointer to `R.name`'s
/// bytes, `ID` the integer. If `declError(R)` reports a problem, that
/// message is the compile error. Bind the result to a container-level
/// `const` to give it static storage, as the C table has.
///
/// Expansion for the minimal REPR, which declares only what is required:
///
/// ```zig
/// const Minimal = struct {
///     pub const name = "Minimal";
///     pub const ID = 99;
///     pub const type_object_for = typeObjectFor;
///     pub const allocate = &c.MVM_gc_allocate_object;
///     pub const get_storage_spec = getStorageSpec;
///     pub const compose = composeMinimal;
/// };
/// ```
///
/// `Ops(Minimal)` is the table C would spell
///
/// ```c
/// { typeObjectFor, MVM_gc_allocate_object, NULL /* initialize */,
///   NULL /* copy_to */, MVM_REPR_DEFAULT_ATTR_FUNCS,
///   MVM_REPR_DEFAULT_BOX_FUNCS, MVM_REPR_DEFAULT_POS_FUNCS,
///   MVM_REPR_DEFAULT_ASS_FUNCS, MVM_REPR_DEFAULT_ELEMS, getStorageSpec,
///   NULL /* change_type */, NULL, NULL, NULL, NULL, NULL /* serialize ..
///   deserialize_stable_size */, NULL, NULL, NULL, NULL, NULL /* gc_mark ..
///   gc_free_repr_data */, composeMinimal, NULL /* spesh */, "Minimal", 99,
///   NULL /* unmanaged_size */, NULL /* describe_refs */ }
/// ```
///
/// Adding `pub const pos_funcs = struct { pub const push = myPush; };`
/// changes exactly one value: `pos_funcs.push` becomes `myPush`, and the
/// other seventeen positional slots keep their defaults.
pub fn Ops(comptime R: type) c.MVMREPROps {
    // The walks compare field and declaration names byte by byte at compile
    // time, which takes more than the default 1000 backward branches.
    @setEvalBranchQuota(eval_quota);
    if (comptime declError(R)) |message| @compileError(message);
    return comptime fill(c.MVMREPROps, R, "");
}

/// One table of the result of `Ops`: for each field of `T` (the top table or
/// a nested one, whose fields' paths start with `prefix`), a nested table is
/// filled recursively from `D.<table>` (or from nothing when `D` does not
/// declare it), and a leaf is `D`'s declaration converted by `slotValue`,
/// else `defaultFor(path)`. Called only once `declError` has passed.
fn fill(comptime T: type, comptime D: type, comptime prefix: []const u8) T {
    var table: T = undefined;
    for (@typeInfo(T).@"struct".field_names) |field| {
        const F = @FieldType(T, field);
        const path = prefix ++ field;
        if (@typeInfo(F) == .@"struct") {
            const Sub = if (declares(D, field)) @field(D, field) else struct {};
            @field(table, field) = fill(F, Sub, path ++ ".");
        } else if (declares(D, field)) {
            @field(table, field) = slotValue(F, D, field);
        } else {
            @field(table, field) = defaultFor(path, F);
        }
    }
    return table;
}

/// `D.<decl>` as a value of the field type `F`: a function becomes a
/// pointer to it, a string its bytes' address, anything else (a function
/// pointer, an integer) is coerced as it is.
fn slotValue(comptime F: type, comptime D: type, comptime decl: []const u8) F {
    const v = @field(D, decl);
    const V = @TypeOf(v);
    if (@typeInfo(V) == .@"fn") return &@field(D, decl);
    if (F == [*c]const u8) return @as([:0]const u8, v).ptr;
    return v;
}

/// Whether `D` has a public declaration named `name`. It looks at
/// `@typeInfo(D).@"struct".decl_names`, which lists only public
/// declarations, so a private helper of that name does not fill the slot.
fn declares(comptime D: type, comptime name: []const u8) bool {
    @setEvalBranchQuota(eval_quota);
    for (@typeInfo(D).@"struct".decl_names) |decl| {
        if (std.mem.eql(u8, decl, name)) return true;
    }
    return false;
}

/// Checks the declarations of `R` against `c.MVMREPROps`, at compile time;
/// null when `Ops(R)` can be built, otherwise the first problem found, in
/// this order (the names are paths, `pos_funcs.push` for a nested slot):
///
/// - `"<R>: unknown REPR function '<name>'"`: a public declaration of `R`
///   (or of one of its nested tables) that names no field, in declaration
///   order;
/// - `"<R>: '<name>' has the wrong type; the field is <type>"`: a
///   declaration that `Ops` could not store in its field, in field order
///   (for `name` the type given is `[:0]const u8`, what to declare);
/// - `"<R>: missing required '<name>'"`: the first name of `required` that
///   `R` does not declare.
pub fn declError(comptime R: type) ?[]const u8 {
    // The checks compare field and declaration names byte by byte at compile
    // time, which takes more than the default 1000 backward branches.
    @setEvalBranchQuota(eval_quota);
    if (unknownDecl(c.MVMREPROps, R, "")) |path|
        return @typeName(R) ++ ": unknown REPR function '" ++ path ++ "'";
    if (mistypedDecl(c.MVMREPROps, R, "")) |m|
        return @typeName(R) ++ ": '" ++ m.path ++ "' has the wrong type; the field is " ++ m.field_type;
    for (required) |name| {
        if (!declares(R, name)) return @typeName(R) ++ ": missing required '" ++ name ++ "'";
    }
    return null;
}

/// The path of the first public declaration of `D` that names no field of
/// `T`, looking into a declared nested table when it is a struct type (a
/// nested table declared as something else is left to `mistypedDecl`).
fn unknownDecl(comptime T: type, comptime D: type, comptime prefix: []const u8) ?[]const u8 {
    for (@typeInfo(D).@"struct".decl_names) |decl| {
        if (!@hasField(T, decl)) return prefix ++ decl;
        const F = @FieldType(T, decl);
        if (@typeInfo(F) == .@"struct" and isStructType(@field(D, decl))) {
            if (unknownDecl(F, @field(D, decl), prefix ++ decl ++ ".")) |path| return path;
        }
    }
    return null;
}

/// What `mistypedDecl` reports: the declaration's path and the type it
/// should have had, as text for the message.
const Mistyped = struct { path: []const u8, field_type: []const u8 };

/// The first field of `T`, in field order, whose declaration in `D` does
/// not fit it (`fits`): its path and the type to tell the author. A nested
/// table that is declared must be a struct type, whose declarations are
/// checked against the nested fields.
fn mistypedDecl(comptime T: type, comptime D: type, comptime prefix: []const u8) ?Mistyped {
    for (@typeInfo(T).@"struct".field_names) |field| {
        if (!declares(D, field)) continue;
        const F = @FieldType(T, field);
        const path = prefix ++ field;
        const v = @field(D, field);
        if (@typeInfo(F) == .@"struct") {
            if (!isStructType(v)) return .{ .path = path, .field_type = "a struct of " ++ @typeName(F) ++ "'s functions" };
            if (mistypedDecl(F, v, path ++ ".")) |m| return m;
        } else if (!fits(F, v)) {
            return .{ .path = path, .field_type = if (F == [*c]const u8) "[:0]const u8" else @typeName(F) };
        }
    }
    return null;
}

/// Whether the declared value `v` is a struct type (what a nested table
/// must be declared as).
fn isStructType(comptime v: anytype) bool {
    return @TypeOf(v) == type and @typeInfo(v) == .@"struct";
}

/// Whether the declared value `v` can fill a field of type `F`:
/// - a function slot (`?*const fn ...`): a function of exactly that type
///   (the calling convention included), or a pointer of that type;
/// - `name` (`[*c]const u8`): a `[:0]const u8` or a string literal;
/// - `ID` (an integer): an integer whose value fits `F`.
fn fits(comptime F: type, comptime v: anytype) bool {
    const V = @TypeOf(v);
    switch (@typeInfo(F)) {
        .optional => |o| {
            if (@typeInfo(V) == .@"fn") return *const V == o.child;
            return V == o.child or V == F;
        },
        .pointer => {
            if (V == [:0]const u8) return true;
            const p = switch (@typeInfo(V)) {
                .pointer => |p| p,
                else => return false,
            };
            if (p.size != .one) return false;
            return switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8 and a.sentinel() == 0,
                else => false,
            };
        },
        .int => return switch (@typeInfo(V)) {
            .int, .comptime_int => std.math.cast(F, v) != null,
            else => false,
        },
        else => @compileError("repr.zig: no rule for a field of type " ++ @typeName(F)),
    }
}

/// Writes `ops` one leaf field per line, `<path>\t<class>\n`, in the field
/// order of `c.MVMREPROps` with each nested table's fields in place of the
/// table (`pos_funcs.at_pos`). The class of a function slot is `default`
/// when it holds that field's `MVM_REPR_DEFAULT_*` function, `null` when it
/// is empty and `own` otherwise; `name` and `ID` show their values. The
/// walk is unrolled at compile time (see `dumpTable`); at run time only the
/// slot values are read and compared with the defaults.
pub fn dumpOps(ops: *const c.MVMREPROps, writer: anytype) !void {
    try dumpTable(c.MVMREPROps, ops, "", writer);
}

/// The lines of `dumpOps` for one table `T` (the top one or a nested one,
/// whose paths start with `prefix`): the `inline for` emits, per field of
/// `T`, either the nested table's lines or one `print` of the leaf.
fn dumpTable(comptime T: type, table: *const T, comptime prefix: []const u8, writer: anytype) !void {
    inline for (@typeInfo(T).@"struct".field_names) |field| {
        const F = @FieldType(T, field);
        const path = prefix ++ field;
        const v = @field(table.*, field);
        switch (@typeInfo(F)) {
            .@"struct" => try dumpTable(F, &@field(table.*, field), path ++ ".", writer),
            .optional => {
                const default = comptime defaultFor(path, F);
                const class = if (v == null) "null" else if (default != null and v == default) "default" else "own";
                try writer.print("{s}\t{s}\n", .{ path, class });
            },
            .pointer => try writer.print("{s}\t{s}\n", .{ path, if (v == null) "null" else std.mem.span(v) }),
            .int => try writer.print("{s}\t{d}\n", .{ path, v }),
            else => @compileError("repr.zig: no rule to dump a field of type " ++ @typeName(F)),
        }
    }
}
