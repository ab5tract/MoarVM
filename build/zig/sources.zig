//! Reads build/sources.list: the C source list shared by build.zig and
//! (via Configure.pl) build/Makefile.in.
//!
//! Format: one path per line relative to the repo root, grouped under
//! `[section]` headers. Blank lines and lines starting with `#` are ignored.
const std = @import("std");

pub const Lists = struct {
    core: []const []const u8 = &.{},
    platform_posix: []const []const u8 = &.{},
    jit: []const []const u8 = &.{},
    jit_x64: []const []const u8 = &.{},
    jit_stub: []const []const u8 = &.{},
    main: []const []const u8 = &.{},
};

pub const Error = error{ UnknownSection, EntryOutsideSection, OutOfMemory };

const Section = enum { core, platform_posix, jit, jit_x64, jit_stub, main };

const section_names = std.StaticStringMap(Section).initComptime(.{
    .{ "core", .core },
    .{ "platform-posix", .platform_posix },
    .{ "jit", .jit },
    .{ "jit-x64", .jit_x64 },
    .{ "jit-stub", .jit_stub },
    .{ "main", .main },
});

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    var buckets = [_]std.ArrayList([]const u8){ .empty, .empty, .empty, .empty, .empty, .empty };
    var current: ?Section = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.UnknownSection;
            current = section_names.get(line[1..end]) orelse return error.UnknownSection;
            continue;
        }
        const section = current orelse return error.EntryOutsideSection;
        try buckets[@intFromEnum(section)].append(allocator, line);
    }

    return .{
        .core = try buckets[@intFromEnum(Section.core)].toOwnedSlice(allocator),
        .platform_posix = try buckets[@intFromEnum(Section.platform_posix)].toOwnedSlice(allocator),
        .jit = try buckets[@intFromEnum(Section.jit)].toOwnedSlice(allocator),
        .jit_x64 = try buckets[@intFromEnum(Section.jit_x64)].toOwnedSlice(allocator),
        .jit_stub = try buckets[@intFromEnum(Section.jit_stub)].toOwnedSlice(allocator),
        .main = try buckets[@intFromEnum(Section.main)].toOwnedSlice(allocator),
    };
}

/// Reads and parses `sub_path` relative to the build root at configure time.
pub fn load(b: *std.Build, sub_path: []const u8) Lists {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, sub_path, b.allocator, .unlimited) catch |err|
        std.process.fatal("cannot read {s}: {t}", .{ sub_path, err });
    return parse(b.allocator, text) catch |err|
        std.process.fatal("cannot parse {s}: {t}", .{ sub_path, err });
}

test "parse: sections, comments, blanks and surrounding whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\# comment
        \\[core]
        \\src/core/a.c
        \\
        \\  src/core/b.c  
        \\[jit-stub]
        \\src/jit/stub.c
        \\[main]
        \\src/main.c
    );
    try std.testing.expectEqual(@as(usize, 2), lists.core.len);
    try std.testing.expectEqualStrings("src/core/a.c", lists.core[0]);
    try std.testing.expectEqualStrings("src/core/b.c", lists.core[1]);
    try std.testing.expectEqual(@as(usize, 1), lists.jit_stub.len);
    try std.testing.expectEqualStrings("src/jit/stub.c", lists.jit_stub[0]);
    try std.testing.expectEqualStrings("src/main.c", lists.main[0]);
    try std.testing.expectEqual(@as(usize, 0), lists.jit.len);
    try std.testing.expectEqual(@as(usize, 0), lists.platform_posix.len);
}

test "parse: entry before any section is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EntryOutsideSection, parse(arena.allocator(), "src/x.c\n"));
}

test "parse: unknown section is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownSection, parse(arena.allocator(), "[bogus]\nsrc/x.c\n"));
}
