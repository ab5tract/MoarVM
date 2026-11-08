//! Reads build/sources.list: the C source list shared by build.zig and
//! (via Configure.pl) build/Makefile.in.
//!
//! Format: one path per line relative to the repo root, grouped under
//! `[section]` headers. Blank lines and lines starting with `#` are ignored.
//! The `[zig]` section is different: each line reads
//! `<zig file>: <c file> [<c file> ...]` and declares that the Zig file
//! replaces those C files when the Zig implementations are built.
const std = @import("std");

pub const ZigEntry = struct {
    zig: []const u8,
    replaces: []const []const u8,
};

pub const Lists = struct {
    core: []const []const u8 = &.{},
    platform_posix: []const []const u8 = &.{},
    jit: []const []const u8 = &.{},
    jit_x64: []const []const u8 = &.{},
    jit_stub: []const []const u8 = &.{},
    main: []const []const u8 = &.{},
    zig: []const ZigEntry = &.{},
};

pub const Error = error{
    UnknownSection,
    EntryOutsideSection,
    BadZigLine,
    ZigReplacesUnknownFile,
    ZigReplacesTwice,
    OutOfMemory,
};

const Section = enum { core, platform_posix, jit, jit_x64, jit_stub, main, zig };

const section_names = std.StaticStringMap(Section).initComptime(.{
    .{ "core", .core },
    .{ "platform-posix", .platform_posix },
    .{ "jit", .jit },
    .{ "jit-x64", .jit_x64 },
    .{ "jit-stub", .jit_stub },
    .{ "main", .main },
    .{ "zig", .zig },
});

const c_sections = [_]Section{ .core, .platform_posix, .jit, .jit_x64, .jit_stub, .main };

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    var buckets = [_]std.ArrayList([]const u8){ .empty, .empty, .empty, .empty, .empty, .empty };
    var zig_entries: std.ArrayList(ZigEntry) = .empty;
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
        if (section == .zig) {
            try zig_entries.append(allocator, try parseZigLine(allocator, line));
        } else {
            try buckets[@backingInt(section)].append(allocator, line);
        }
    }

    const lists: Lists = .{
        .core = try buckets[@backingInt(Section.core)].toOwnedSlice(allocator),
        .platform_posix = try buckets[@backingInt(Section.platform_posix)].toOwnedSlice(allocator),
        .jit = try buckets[@backingInt(Section.jit)].toOwnedSlice(allocator),
        .jit_x64 = try buckets[@backingInt(Section.jit_x64)].toOwnedSlice(allocator),
        .jit_stub = try buckets[@backingInt(Section.jit_stub)].toOwnedSlice(allocator),
        .main = try buckets[@backingInt(Section.main)].toOwnedSlice(allocator),
        .zig = try zig_entries.toOwnedSlice(allocator),
    };
    try validateZig(lists);
    return lists;
}

fn parseZigLine(allocator: std.mem.Allocator, line: []const u8) Error!ZigEntry {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadZigLine;
    const zig_file = std.mem.trim(u8, line[0..colon], " \t");
    if (zig_file.len == 0) return error.BadZigLine;
    var replaces: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    while (words.next()) |w| try replaces.append(allocator, w);
    if (replaces.items.len == 0) return error.BadZigLine;
    return .{ .zig = zig_file, .replaces = try replaces.toOwnedSlice(allocator) };
}

fn cList(lists: Lists, section: Section) []const []const u8 {
    return switch (section) {
        .core => lists.core,
        .platform_posix => lists.platform_posix,
        .jit => lists.jit,
        .jit_x64 => lists.jit_x64,
        .jit_stub => lists.jit_stub,
        .main => lists.main,
        .zig => unreachable,
    };
}

fn contains(list: []const []const u8, file: []const u8) bool {
    for (list) |f| if (std.mem.eql(u8, f, file)) return true;
    return false;
}

/// Every replaced C file must be listed in some C section, and only once
/// across all [zig] lines.
fn validateZig(lists: Lists) Error!void {
    for (lists.zig, 0..) |entry, i| {
        for (entry.replaces) |file| {
            var found = false;
            for (c_sections) |s| {
                if (contains(cList(lists, s), file)) found = true;
            }
            if (!found) return error.ZigReplacesUnknownFile;
            for (lists.zig[0..i]) |earlier| {
                if (contains(earlier.replaces, file)) return error.ZigReplacesTwice;
            }
            // Also reject duplicates within the same line.
            var seen: usize = 0;
            for (entry.replaces) |other| if (std.mem.eql(u8, other, file)) {
                seen += 1;
            };
            if (seen > 1) return error.ZigReplacesTwice;
        }
    }
}

fn isReplaced(lists: Lists, file: []const u8) bool {
    for (lists.zig) |entry| if (contains(entry.replaces, file)) return true;
    return false;
}

fn without(allocator: std.mem.Allocator, lists: Lists, list: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |f| if (!isReplaced(lists, f)) try out.append(allocator, f);
    return try out.toOwnedSlice(allocator);
}

/// The lists as the build compiles them when the Zig implementations are
/// on: every C file named on a [zig] line is dropped from its section.
pub fn applyZig(allocator: std.mem.Allocator, lists: Lists) Error!Lists {
    return .{
        .core = try without(allocator, lists, lists.core),
        .platform_posix = try without(allocator, lists, lists.platform_posix),
        .jit = try without(allocator, lists, lists.jit),
        .jit_x64 = try without(allocator, lists, lists.jit_x64),
        .jit_stub = try without(allocator, lists, lists.jit_stub),
        .main = try without(allocator, lists, lists.main),
        .zig = lists.zig,
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

test "parse: [zig] lines name a zig file and the C files it replaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\[core]
        \\src/core/a.c
        \\src/core/intcache.c
        \\[platform-posix]
        \\src/platform/posix/time.c
        \\[main]
        \\src/main.c
        \\[zig]
        \\src/zig/platform/time.zig: src/platform/posix/time.c
        \\src/zig/core/intcache.zig:   src/core/intcache.c
    );
    try std.testing.expectEqual(@as(usize, 2), lists.zig.len);
    try std.testing.expectEqualStrings("src/zig/platform/time.zig", lists.zig[0].zig);
    try std.testing.expectEqualStrings("src/platform/posix/time.c", lists.zig[0].replaces[0]);
    try std.testing.expectEqualStrings("src/core/intcache.c", lists.zig[1].replaces[0]);
    // parse leaves the C lists intact
    try std.testing.expectEqual(@as(usize, 2), lists.core.len);
    try std.testing.expectEqual(@as(usize, 1), lists.platform_posix.len);

    const applied = try applyZig(arena.allocator(), lists);
    try std.testing.expectEqual(@as(usize, 1), applied.core.len);
    try std.testing.expectEqualStrings("src/core/a.c", applied.core[0]);
    try std.testing.expectEqual(@as(usize, 0), applied.platform_posix.len);
    try std.testing.expectEqual(@as(usize, 2), applied.zig.len);
}

test "parse: [zig] line without a colon is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadZigLine, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig\n"));
}

test "parse: [zig] replacing a file listed nowhere is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigReplacesUnknownFile, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig: src/b.c\n"));
}

test "parse: a C file replaced on two [zig] lines is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigReplacesTwice, parse(arena.allocator(), "[core]\nsrc/a.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig: src/a.c\nsrc/zig/y.zig: src/a.c\n"));
}
