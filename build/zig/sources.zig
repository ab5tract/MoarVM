//! Reads build/sources.list: the C source list shared by build.zig and
//! (via Configure.pl) build/Makefile.in.
//!
//! Format: one path per line relative to the repo root, grouped under
//! `[section]` headers. Blank lines and lines starting with `#` are ignored.
//! The `[zig]` section is different: each line reads
//! `<zig file>: <c file> [<c file> ...]` and declares that the Zig file
//! replaces those C files when the Zig implementations are built.
//! The `[zig-gc]` section has the same line grammar and holds the garbage
//! collector's files, applied only when `-Dzig-gc` is on as well.
const std = @import("std");
const root_files = @import("root_files.zig");

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
    zig_gc: []const ZigEntry = &.{},
};

pub const Error = error{
    UnknownSection,
    EntryOutsideSection,
    BadZigLine,
    ZigReplacesUnknownFile,
    ZigReplacesTwice,
    OutOfMemory,
};

const Section = enum { core, platform_posix, jit, jit_x64, jit_stub, main, zig, zig_gc };

const section_names = std.StaticStringMap(Section).initComptime(.{
    .{ "core", .core },
    .{ "platform-posix", .platform_posix },
    .{ "jit", .jit },
    .{ "jit-x64", .jit_x64 },
    .{ "jit-stub", .jit_stub },
    .{ "main", .main },
    .{ "zig", .zig },
    .{ "zig-gc", .zig_gc },
});

const c_sections = [_]Section{ .core, .platform_posix, .jit, .jit_x64, .jit_stub, .main };

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Lists {
    var buckets = [_]std.ArrayList([]const u8){ .empty, .empty, .empty, .empty, .empty, .empty };
    var zig_entries: std.ArrayList(ZigEntry) = .empty;
    var zig_gc_entries: std.ArrayList(ZigEntry) = .empty;
    var current: ?Section = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.findScalar(u8, line, ']') orelse return error.UnknownSection;
            current = section_names.get(line[1..end]) orelse return error.UnknownSection;
            continue;
        }
        const section = current orelse return error.EntryOutsideSection;
        switch (section) {
            .zig => try zig_entries.append(allocator, try parseZigLine(allocator, line)),
            .zig_gc => try zig_gc_entries.append(allocator, try parseZigLine(allocator, line)),
            else => try buckets[@backingInt(section)].append(allocator, line),
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
        .zig_gc = try zig_gc_entries.toOwnedSlice(allocator),
    };
    try validateZig(lists);
    return lists;
}

fn parseZigLine(allocator: std.mem.Allocator, line: []const u8) Error!ZigEntry {
    const colon = std.mem.findScalar(u8, line, ':') orelse return error.BadZigLine;
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
        .zig, .zig_gc => unreachable,
    };
}

fn contains(list: []const []const u8, file: []const u8) bool {
    for (list) |f| if (std.mem.eql(u8, f, file)) return true;
    return false;
}

/// Every replaced C file must be listed in some C section, and only once
/// across all [zig] and [zig-gc] lines together.
fn validateZig(lists: Lists) Error!void {
    for (0..lists.zig.len + lists.zig_gc.len) |i| {
        const entry = zigEntry(lists, i);
        for (entry.replaces) |file| {
            var found = false;
            for (c_sections) |s| {
                if (contains(cList(lists, s), file)) found = true;
            }
            if (!found) return error.ZigReplacesUnknownFile;
            for (0..i) |j| {
                if (contains(zigEntry(lists, j).replaces, file)) return error.ZigReplacesTwice;
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

/// The `i`th entry of [zig] followed by [zig-gc].
fn zigEntry(lists: Lists, i: usize) ZigEntry {
    return if (i < lists.zig.len) lists.zig[i] else lists.zig_gc[i - lists.zig.len];
}

fn isReplaced(lists: Lists, file: []const u8) bool {
    for (lists.zig) |entry| if (contains(entry.replaces, file)) return true;
    for (lists.zig_gc) |entry| if (contains(entry.replaces, file)) return true;
    return false;
}

fn without(allocator: std.mem.Allocator, lists: Lists, list: []const []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list) |f| if (!isReplaced(lists, f)) try out.append(allocator, f);
    return try out.toOwnedSlice(allocator);
}

/// The lists as the build compiles them when the Zig implementations are
/// on: every C file named on a [zig] line is dropped from its section, and
/// with `zig_gc` every C file named on a [zig-gc] line too. Without
/// `zig_gc` the [zig-gc] entries are neither applied nor returned.
pub fn applyZig(allocator: std.mem.Allocator, raw: Lists, zig_gc: bool) Error!Lists {
    var lists = raw;
    if (!zig_gc) lists.zig_gc = &.{};
    return .{
        .core = try without(allocator, lists, lists.core),
        .platform_posix = try without(allocator, lists, lists.platform_posix),
        .jit = try without(allocator, lists, lists.jit),
        .jit_x64 = try without(allocator, lists, lists.jit_x64),
        .jit_stub = try without(allocator, lists, lists.jit_stub),
        .main = try without(allocator, lists, lists.main),
        .zig = lists.zig,
        .zig_gc = lists.zig_gc,
    };
}

/// Reads and parses `sub_path` relative to the build root at configure time.
pub fn load(b: *std.Build, sub_path: []const u8) Lists {
    const text = root_files.readRootFile(b, sub_path) orelse
        std.process.fatal("cannot read {s}: FileNotFound", .{sub_path});
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

    const applied = try applyZig(arena.allocator(), lists, true);
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

test "parse: [zig-gc] lines are ZigEntry and separate from [zig]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\[core]
        \\src/core/a.c
        \\src/gc/x.c
        \\[main]
        \\src/main.c
        \\[zig]
        \\src/zig/core/a.zig: src/core/a.c
        \\[zig-gc]
        \\src/zig/gc/x.zig: src/gc/x.c
    );
    try std.testing.expectEqual(@as(usize, 1), lists.zig.len);
    try std.testing.expectEqual(@as(usize, 1), lists.zig_gc.len);
    try std.testing.expectEqualStrings("src/zig/core/a.zig", lists.zig[0].zig);
    try std.testing.expectEqualStrings("src/zig/gc/x.zig", lists.zig_gc[0].zig);
    try std.testing.expectEqualStrings("src/gc/x.c", lists.zig_gc[0].replaces[0]);
}

test "applyZig without gc keeps the gc C files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = try parse(arena.allocator(),
        \\[core]
        \\src/core/a.c
        \\src/gc/x.c
        \\[main]
        \\src/main.c
        \\[zig]
        \\src/zig/core/a.zig: src/core/a.c
        \\[zig-gc]
        \\src/zig/gc/x.zig: src/gc/x.c
    );
    const without_gc = try applyZig(arena.allocator(), lists, false);
    try std.testing.expectEqual(@as(usize, 1), without_gc.core.len);
    try std.testing.expectEqualStrings("src/gc/x.c", without_gc.core[0]);
    try std.testing.expectEqual(@as(usize, 1), without_gc.zig.len);
    try std.testing.expectEqual(@as(usize, 0), without_gc.zig_gc.len);

    const with_gc = try applyZig(arena.allocator(), lists, true);
    try std.testing.expectEqual(@as(usize, 0), with_gc.core.len);
    try std.testing.expectEqual(@as(usize, 1), with_gc.zig.len);
    try std.testing.expectEqual(@as(usize, 1), with_gc.zig_gc.len);
}

test "validate: a C file replaced in both sections is ZigReplacesTwice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigReplacesTwice, parse(arena.allocator(), "[core]\nsrc/gc/x.c\n[main]\nsrc/main.c\n[zig]\nsrc/zig/x.zig: src/gc/x.c\n[zig-gc]\nsrc/zig/gc/x.zig: src/gc/x.c\n"));
}
