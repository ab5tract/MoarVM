//! The C-API benchmark of the four unicode tables (`zig build uni-bench --
//! [--runs=K] [--ops=a,b] [--sample=N]`): u1 `property_codes_by_names_aliases`,
//! u2 `property_codes_by_seq_names`, u3 `codepoints_by_name` and the 115 u4
//! `unicode_property_values_hashes`, all `MVMUniHashTable`s, timed through
//! `uni_bench_shim.c` (`MVM_uni_hash_fetch`, out of line) on whichever
//! engine libmoar was built with. The cells and keys are those of
//! `tools/bench/uni-bench.nqp`, and so is the output: the harness's
//! 7 columns `engine, size, op, ns_per_op, alloc_bytes (0 here), ns_min,
//! ns_max`, where size is the number of keys of the cell.
//!
//! Property, alias, value and sequence names come from the key file
//! `tools/bench/uni-bench-keys.tsv` (embedded as `uni_bench_keys`, see
//! `tools/bench/uni-bench-keys.pl`); codepoint names are harvested at
//! runtime with `MVM_unicode_get_name` for 0..0x2FFFF, skipping empty names,
//! placeholders and algorithmic names (a trailing -HEX), and sampled by a
//! shuffle with the LCG seeded 0x5eed. Every _hit cell dies on a miss and
//! every _miss cell on a hit. u1 and u3 (built lazily) and u2 (built on
//! the first u3 miss of a string_from_name) are forced to exist first.
const std = @import("std");
const moar = @import("moar");
const c = moar.c;
const build_options = @import("build_options");
const keys = @import("test/keys.zig");
const util = @import("bench_util.zig");

const Tc = *moar.ThreadContext;
const Table = *c.MVMUniHashTable;
const Entry = c.MVMUniHashEntry;

extern fn bench_uni_fetch(tc: Tc, table: Table, key: [*:0]const u8) ?*Entry;
extern fn bench_uni_insert(tc: Tc, table: Table, key: [*:0]const u8, value: i32) void;
extern fn bench_uni_demolish(tc: Tc, table: Table) void;

const engine = if (build_options.zig_impl) "zig" else "c";
/// A timed region lasts at least this long (the calibration doubling sizes it).
const target_ns: u64 = 50_000_000;
const cp_limit: u32 = 0x30000;
const default_sample: u32 = 4096;
const lcg_seed: u64 = 0x5eed;
/// The distinct prefix-resolved keys of cpbyname_miss_prefix: 512 compatibility
/// ideographs (0xF900..0xFAFF) and 20,992 unified ones (0x4E00..0x9FFF).
const prefix_key_limit: u32 = 512 + 20992;

pub const cell_names = [_][]const u8{
    "cpbyname_hit", "cpbyname_miss",  "cpbyname_miss_prefix",
    "propcode_hit", "propcode_alias", "propcode_miss",
    "pvalcode_hit", "pvalcode_miss",  "strfromname_seq",
};

const usage =
    \\usage: uni-bench [--runs=K] [--ops=a,b] [--sample=N]
    \\  --runs    runs per cell, the median is reported (default 3)
    \\  --ops     only these cells run: any of cpbyname_hit,cpbyname_miss,cpbyname_miss_prefix,
    \\            propcode_hit,propcode_alias,propcode_miss,pvalcode_hit,pvalcode_miss,strfromname_seq
    \\  --sample  codepoint names sampled for the cpbyname cells (default 4096)
    \\
;

pub const Options = struct {
    runs: u32 = 3,
    sample: u32 = default_sample,
    ops: ?[]const []const u8 = null,
};

pub fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var opts: Options = .{};
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--runs=")) {
            opts.runs = try std.fmt.parseInt(u32, a["--runs=".len..], 10);
            if (opts.runs == 0) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, a, "--sample=")) {
            opts.sample = try std.fmt.parseInt(u32, a["--sample=".len..], 10);
            if (opts.sample == 0) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, a, "--ops=")) {
            const list = try util.splitList(arena, a["--ops=".len..]);
            for (list) |o| {
                if (!util.selects(&cell_names, o)) {
                    if (!@import("builtin").is_test) std.debug.print("uni-bench: unknown op {s}\n", .{o});
                    return error.InvalidArgument;
                }
            }
            opts.ops = list;
        } else {
            if (!@import("builtin").is_test) std.debug.print("uni-bench: unknown argument {s}\n{s}", .{ a, usage });
            return error.InvalidArgument;
        }
    }
    return opts;
}

/// A key file row of a name with its value (prop, alias) or a property value
/// (pval: `value` is the property code, `name` the value name).
pub const Named = struct { name: [:0]const u8, value: i32 };

pub const KeyFile = struct {
    props: []const Named,
    aliases: []const Named,
    pvals: []const Named,
    seqs: []const [:0]const u8,
};

/// Parses the TSV of `uni-bench-keys.pl`: `kind<TAB>name[<TAB>value]`, kinds
/// prop, alias, pval (value = the property code) and seq (no value).
pub fn parseKeys(arena: std.mem.Allocator, text: []const u8) !KeyFile {
    var props: std.ArrayList(Named) = .empty;
    var aliases: std.ArrayList(Named) = .empty;
    var pvals: std.ArrayList(Named) = .empty;
    var seqs: std.ArrayList([:0]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const kind = f.next().?;
        const name = f.next() orelse return error.MalformedRow;
        if (name.len == 0) return error.MalformedRow;
        const z = try arena.dupeZ(u8, name);
        if (std.mem.eql(u8, kind, "seq")) {
            if (f.next() != null) return error.MalformedRow;
            try seqs.append(arena, z);
            continue;
        }
        const value_text = f.next() orelse return error.MalformedRow;
        if (f.next() != null) return error.MalformedRow;
        if (std.mem.eql(u8, kind, "pval")) {
            // pval<TAB><propcode><TAB><valuename>: `name` holds the code text.
            const code = std.fmt.parseInt(i32, name, 10) catch return error.MalformedRow;
            try pvals.append(arena, .{ .name = try arena.dupeZ(u8, value_text), .value = code });
            continue;
        }
        const value = std.fmt.parseInt(i32, value_text, 10) catch return error.MalformedRow;
        if (std.mem.eql(u8, kind, "prop")) {
            try props.append(arena, .{ .name = z, .value = value });
        } else if (std.mem.eql(u8, kind, "alias")) {
            try aliases.append(arena, .{ .name = z, .value = value });
        } else return error.MalformedRow;
    }
    return .{ .props = props.items, .aliases = aliases.items, .pvals = pvals.items, .seqs = seqs.items };
}

/// Whether a codepoint name is algorithmic: it ends in -HEX of 4 to 6 digits
/// (CJK UNIFIED IDEOGRAPH-4E00 and the like), resolved by prefix, not by an
/// entry of the table.
pub fn isAlgorithmic(name: []const u8) bool {
    const dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse return false;
    const tail = name[dash + 1 ..];
    if (tail.len < 4 or tail.len > 6) return false;
    for (tail) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F'))) return false;
    }
    return true;
}

/// The Fisher-Yates shuffle of tools/bench/uni-bench.nqp: x = (x * 1103515245
/// + 12345) & 0x7fffffff per step from the seed, j = x % (i + 1), for i from
/// the last index down to 1.
pub fn shuffle(comptime T: type, items: []T, seed: u64) void {
    var x = seed;
    var i = items.len;
    while (i > 1) {
        i -= 1;
        x = (x *% 1103515245 +% 12345) & 0x7fffffff;
        std.mem.swap(T, &items[i], &items[x % (i + 1)]);
    }
}

/// One cell: the table each key is looked up in, the keys, and what a lookup
/// must give (`hit`: an entry, whose value is `expect[j]` when that is given;
/// otherwise no entry).
const Cell = struct {
    name: []const u8,
    tables: []const Table,
    keys: []const [:0]const u8,
    hit: bool,
    expect: ?[]const i32 = null,

    /// One walk over the keys; returns how many lookups gave the wrong answer.
    fn pass(self: Cell, tc: Tc) u64 {
        var bad: u64 = 0;
        for (self.keys, self.tables, 0..) |k, t, j| {
            const e = bench_uni_fetch(tc, t, k.ptr);
            if (self.hit) {
                if (e == null or (self.expect != null and e.?.value != self.expect.?[j])) bad += 1;
            } else if (e != null) bad += 1;
        }
        return bad;
    }

    /// `reps` walks timed as one region; ns per lookup.
    fn timed(self: Cell, io: std.Io, tc: Tc, reps: u64, bad: *u64) f64 {
        const timer = util.Timer.begin(io);
        for (0..reps) |_| bad.* += self.pass(tc);
        return @as(f64, @floatFromInt(timer.elapsedNs())) / @as(f64, @floatFromInt(reps * self.keys.len));
    }
};

fn runCell(w: *std.Io.Writer, arena: std.mem.Allocator, io: std.Io, tc: Tc, cell: Cell, runs: u32) !void {
    var bad: u64 = 0;
    // Calibration (which also verifies and warms up): double the repeat
    // count until one timed region lasts `target_ns`.
    var reps: u64 = 1;
    while (true) : (reps *= 2) {
        const ns_per_lookup = cell.timed(io, tc, reps, &bad);
        if (ns_per_lookup * @as(f64, @floatFromInt(reps * cell.keys.len)) >= @as(f64, @floatFromInt(target_ns))) break;
    }
    const samples = try arena.alloc(f64, runs);
    for (samples) |*s| s.* = cell.timed(io, tc, reps, &bad);
    if (bad != 0) {
        std.debug.print("uni-bench: {s}: {d} wrong answers in {d} keys\n", .{ cell.name, bad, cell.keys.len });
        return error.WrongAnswer;
    }
    const sp = util.spread(samples);
    try w.print("{s}\t{d}\t{s}\t{d:.2}\t0\t{d:.2}\t{d:.2}\n", .{ engine, cell.keys.len, cell.name, util.median(samples), sp.min, sp.max });
    try w.flush();
}

fn repeatTable(arena: std.mem.Allocator, t: Table, n: usize) ![]const Table {
    const out = try arena.alloc(Table, n);
    @memset(out, t);
    return out;
}

/// Copies the names of `named` with `suffix` appended.
fn suffixed(arena: std.mem.Allocator, named: []const Named, suffix: []const u8) ![]const [:0]const u8 {
    const out = try arena.alloc([:0]const u8, named.len);
    for (named, out) |n, *o| o.* = try std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ n.name, suffix }, 0);
    return out;
}

fn harvestNames(arena: std.mem.Allocator, tc: Tc, sample: u32) ![]const [:0]const u8 {
    var names: std.ArrayList([:0]const u8) = .empty;
    var cp: u32 = 0;
    while (cp < cp_limit) : (cp += 1) {
        const s = c.MVM_unicode_get_name(tc, cp);
        const cname = c.MVM_string_utf8_encode_C_string(tc, s);
        defer c.MVM_free(cname);
        const name = std.mem.span(cname);
        if (name.len == 0 or name[0] == '<' or isAlgorithmic(name)) continue;
        try names.append(arena, try arena.dupeZ(u8, name));
    }
    shuffle([:0]const u8, names.items, lcg_seed);
    return names.items[0..@min(sample, names.items.len)];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args) catch |err| switch (err) {
        error.InvalidArgument => std.process.exit(2),
        else => return err,
    };
    const kf = parseKeys(arena, @embedFile("uni_bench_keys")) catch |err| {
        std.debug.print("uni-bench: malformed embedded key file: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const instance = c.MVM_vm_create_instance();
    const tc: Tc = instance.*.main_thread;
    const t_u1: Table = &instance.*.property_codes_by_names_aliases;
    const t_u2: Table = &instance.*.property_codes_by_seq_names;
    const t_u3: Table = &instance.*.codepoints_by_name;

    // Force the lazily built tables: one lookup of a name none of them has.
    const probe = (try keys.makeNamed(arena, tc, "k", 1))[0];
    _ = c.MVM_unicode_name_to_property_code(tc, probe);
    _ = c.MVM_unicode_lookup_by_name(tc, probe);
    _ = c.MVM_unicode_string_from_name(tc, probe);

    // The shim, on a table of its own, before anything is measured.
    {
        var scratch = std.mem.zeroes(c.MVMUniHashTable);
        bench_uni_insert(tc, &scratch, "present", 7);
        const found = bench_uni_fetch(tc, &scratch, "present");
        if (found == null or found.?.value != 7 or bench_uni_fetch(tc, &scratch, "absent") != null) {
            std.debug.print("uni-bench: the shim's insert and fetch disagree\n", .{});
            std.process.exit(1);
        }
        bench_uni_demolish(tc, &scratch);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &stdout.interface;

    const need_names = util.selects(opts.ops, "cpbyname_hit") or util.selects(opts.ops, "cpbyname_miss");
    const names = if (need_names) try harvestNames(arena, tc, opts.sample) else &[_][:0]const u8{};

    for (cell_names) |name| {
        if (!util.selects(opts.ops, name)) continue;
        const cell = try buildCell(arena, name, instance, kf, names, opts.sample, .{ t_u1, t_u2, t_u3 });
        try runCell(w, arena, io, tc, cell, opts.runs);
    }
    c.MVM_vm_destroy_instance(instance);
}

fn buildCell(
    arena: std.mem.Allocator,
    name: []const u8,
    instance: *c.MVMInstance,
    kf: KeyFile,
    names: []const [:0]const u8,
    sample: u32,
    t: [3]Table,
) !Cell {
    const eq = std.mem.eql;
    if (eq(u8, name, "cpbyname_hit")) {
        return .{ .name = name, .tables = try repeatTable(arena, t[2], names.len), .keys = names, .hit = true };
    } else if (eq(u8, name, "cpbyname_miss")) {
        const ks = try arena.alloc([:0]const u8, names.len);
        for (names, ks) |n, *k| k.* = try std.fmt.allocPrintSentinel(arena, "{s} ZZZ", .{n}, 0);
        return .{ .name = name, .tables = try repeatTable(arena, t[2], ks.len), .keys = ks, .hit = false };
    } else if (eq(u8, name, "cpbyname_miss_prefix")) {
        // Distinct keys the lookup resolves by prefix: the compatibility
        // block, then the unified one (--sample clamps to prefix_key_limit).
        const ks = try arena.alloc([:0]const u8, @min(sample, prefix_key_limit));
        for (ks, 0..) |*k, i| {
            k.* = if (i < 512)
                try std.fmt.allocPrintSentinel(arena, "CJK COMPATIBILITY IDEOGRAPH-{X}", .{0xF900 + i}, 0)
            else
                try std.fmt.allocPrintSentinel(arena, "CJK UNIFIED IDEOGRAPH-{X}", .{0x4E00 + i - 512}, 0);
        }
        return .{ .name = name, .tables = try repeatTable(arena, t[2], ks.len), .keys = ks, .hit = false };
    } else if (eq(u8, name, "propcode_hit") or eq(u8, name, "propcode_alias")) {
        const rows = if (eq(u8, name, "propcode_hit")) kf.props else kf.aliases;
        const ks = try arena.alloc([:0]const u8, rows.len);
        const ex = try arena.alloc(i32, rows.len);
        for (rows, ks, ex) |r, *k, *e| {
            k.* = r.name;
            e.* = r.value;
        }
        return .{ .name = name, .tables = try repeatTable(arena, t[0], ks.len), .keys = ks, .hit = true, .expect = ex };
    } else if (eq(u8, name, "propcode_miss")) {
        const a = try suffixed(arena, kf.props, "_X");
        const b = try suffixed(arena, kf.aliases, "_X");
        const ks = try std.mem.concat(arena, [:0]const u8, &.{ a, b });
        return .{ .name = name, .tables = try repeatTable(arena, t[0], ks.len), .keys = ks, .hit = false };
    } else if (eq(u8, name, "pvalcode_hit") or eq(u8, name, "pvalcode_miss")) {
        const hit = eq(u8, name, "pvalcode_hit");
        const ks = try arena.alloc([:0]const u8, kf.pvals.len);
        const tabs = try arena.alloc(Table, kf.pvals.len);
        for (kf.pvals, ks, tabs) |p, *k, *tb| {
            k.* = try std.fmt.allocPrintSentinel(arena, "{d}-{s}{s}", .{ p.value, p.name, if (hit) "" else "_X" }, 0);
            tb.* = @ptrCast(instance.*.unicode_property_values_hashes + @as(usize, @intCast(p.value)));
        }
        return .{ .name = name, .tables = tabs, .keys = ks, .hit = hit };
    } else {
        return .{ .name = name, .tables = try repeatTable(arena, t[1], kf.seqs.len), .keys = kf.seqs, .hit = true };
    }
}

test "parseArgs takes runs, sample and ops, and refuses unknown ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const o = try parseArgs(arena, &.{ "uni-bench", "--runs=2", "--sample=64", "--ops=cpbyname_hit,propcode_miss" });
    try std.testing.expectEqual(@as(u32, 2), o.runs);
    try std.testing.expectEqual(@as(u32, 64), o.sample);
    try std.testing.expectEqual(@as(usize, 2), o.ops.?.len);
    try std.testing.expectError(error.InvalidArgument, parseArgs(arena, &.{ "uni-bench", "--ops=bogus" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(arena, &.{ "uni-bench", "--runs=0" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(arena, &.{ "uni-bench", "--wat" }));
    const d = try parseArgs(arena, &.{"uni-bench"});
    try std.testing.expectEqual(@as(u32, default_sample), d.sample);
}

test "parseKeys reads the four kinds and refuses malformed rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kf = try parseKeys(arena, "prop\tAlphabetic\t33\nalias\tAlpha\t33\npval\t20\tC\nseq\tAFGHANISTAN\n");
    try std.testing.expectEqualStrings("Alphabetic", kf.props[0].name);
    try std.testing.expectEqual(@as(i32, 33), kf.props[0].value);
    try std.testing.expectEqualStrings("Alpha", kf.aliases[0].name);
    try std.testing.expectEqual(@as(i32, 20), kf.pvals[0].value);
    try std.testing.expectEqualStrings("C", kf.pvals[0].name);
    try std.testing.expectEqualStrings("AFGHANISTAN", kf.seqs[0]);
    for ([_][]const u8{ "bogus\tx\t1\n", "prop\tonly\n", "prop\tx\tnotanumber\n", "seq\tx\textra\n", "no tabs\n" }) |bad| {
        try std.testing.expectError(error.MalformedRow, parseKeys(arena, bad));
    }
}

test "isAlgorithmic spots the -HEX names only" {
    try std.testing.expect(isAlgorithmic("CJK UNIFIED IDEOGRAPH-4E00"));
    try std.testing.expect(isAlgorithmic("TANGUT IDEOGRAPH-17000"));
    try std.testing.expect(!isAlgorithmic("LATIN SMALL LETTER A"));
    try std.testing.expect(!isAlgorithmic("TANGUT COMPONENT-001"));
    try std.testing.expect(!isAlgorithmic("HYPHEN-MINUS"));
}

test "shuffle is a deterministic permutation" {
    var a = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var b = a;
    shuffle(u32, &a, lcg_seed);
    shuffle(u32, &b, lcg_seed);
    try std.testing.expectEqualSlices(u32, &a, &b);
    var seen = @as([8]bool, @splat(false));
    for (a) |v| seen[v] = true;
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expect(!std.mem.eql(u32, &a, &[_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 }));
}
