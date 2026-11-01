//! Port of tools/tiler-table-generator.pl: turns the tile grammar
//! (src/jit/x64/tile_pattern.tile) into the tiler tables of tile_pattern.h.
//! Rulesets are numbered canonically (sorted by their rule lists); the Perl
//! tool numbers them in hash order, which differs from run to run.
const std = @import("std");
const sexpr = @import("sexpr.zig");
const expr_ops = @import("expr_ops.zig");
const Node = sexpr.Node;

const PREFIX = "MVM_JIT_";
const VARNAME = "MVM_jit_tile_";

pub const Rule = struct {
    /// head symbol followed by operand symbols (nonterminals or pseudo "#N")
    pat: []const []const u8,
    sym: []const u8,
    cost: f64,
    /// true for the rule that stands for a whole (tile:/define:) statement
    is_head: bool = false,
    name: ?[]const u8 = null,
    path: []const u8 = "",
    spec: []const []const u8 = &.{},
    refs: u32 = 0,
    text: []const u8 = "",
};

pub const Error = error{ MalformedStatement, BadCost, CannotFindKey, RulesetUnreachable, MissingCost, OutOfMemory, WriteFailed };

// --- Tests: the Perl tool's own __DATA__ grammar, expected values taken from
// a canonicalised run of the Perl tool. ---

const test_grammar =
    \\# Minimal grammar to test tiler table generator
    \\(tile: a (stack) reg 1)
    \\(tile: c (addr reg $ofs) reg 2)
    \\(tile: d (const $val) reg 2)
    \\(tile: e (load reg $size) reg 5)
    \\(tile: g (add reg reg) reg 2)
    \\(tile: h (add reg (const $val)) reg 3)
    \\(tile: i (add reg (load reg $size)) reg 6)
;

// One entry per line: expr_ops.parse (like expr_ops.pm) takes one entry per line.
const test_expr_ops =
    \\#define MVM_JIT_EXPR_OPS(_) \
    \\    _(NOOP, 0, 0), \
    \\    _(COPY, 1, 0), \
    \\    _(LOAD, 1, 1), \
    \\    _(STORE, 2, 1), \
    \\    _(ADDR, 1, 1), \
    \\    _(CONST, 0, 2), \
    \\    _(ADD, 2, 0), \
    \\    _(TC, 0, 0), \
    \\    _(STACK, 0, 0), \
    \\    _(MAX_NODES, 0, 0)
;

fn runTest(arena: std.mem.Allocator) !struct { out: []const u8, debug: []const u8 } {
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, test_expr_ops);
    var out: std.Io.Writer.Allocating = .init(arena);
    var dbg: std.Io.Writer.Allocating = .init(arena);
    try generate(arena, test_grammar, eo, &dbg.writer, &out.writer);
    return .{ .out = out.written(), .debug = dbg.written() };
}

fn countLines(text: []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) {
        n += 1;
    };
    return n;
}

test "debug listing: rules in statement order, rulesets in canonical order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runTest(arena.allocator());
    try std.testing.expectEqualStrings(
        "Rules:\n" ++
            "0 => (stack): reg\n" ++
            "1 => (addr reg): reg\n" ++
            "2 => (const): reg\n" ++
            "3 => (load reg): reg\n" ++
            "4 => (add reg reg): reg\n" ++
            "5 => (const): #0\n" ++
            "6 => (add reg #0): reg\n" ++
            "7 => (load reg): #1\n" ++
            "8 => (add reg #1): reg\n" ++
            "Rulesets:\n" ++
            "0 => 0, \n" ++
            "1 => 1, \n" ++
            "2 => 2, 5, \n" ++
            "3 => 3, 7, \n" ++
            "4 => 4, \n" ++
            "5 => 4, 6, \n" ++
            "6 => 4, 8, \n",
        r.debug,
    );
}

test "templates table: head rules carry name, path, text, symbol numbers, refs and spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runTest(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/* Tile function declarations */\n" ++
        "MVM_JIT_TILE_DECL(a);\nMVM_JIT_TILE_DECL(c);\nMVM_JIT_TILE_DECL(d);\nMVM_JIT_TILE_DECL(e);\n" ++
        "MVM_JIT_TILE_DECL(g);\nMVM_JIT_TILE_DECL(h);\nMVM_JIT_TILE_DECL(i);\n" ++
        "/* Tile template declarations */\n" ++
        "static const MVMJitTileTemplate MVM_jit_tile_templates[] = {\n" ++
        "  { MVM_JIT_TILE_NAME(a), \"\",\n   \"(stack)\", -1, -1, 0, 0,\n    { MVM_JIT_STORAGE_GPR } },\n" ++
        "  { MVM_JIT_TILE_NAME(c), \"1.2.\",\n   \"(addr reg $ofs)\", 0, -1, 1, 1,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n") != null);
    // rule 4 (g): two operand symbols, refs bitmap 3, nval 2, three storage specs
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  { MVM_JIT_TILE_NAME(g), \"1.2.\",\n   \"(add reg reg)\", 0, 0, 2, 3,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n" ++
        "  { NULL, NULL,\n   NULL, -1, -1, 0, 0,\n    { 0 } },\n" ++
        "  { MVM_JIT_TILE_NAME(h), \"1.21.\",\n   \"(add reg (const $val))\", 0, 1, 1, 1,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n" ++
        "  { NULL, NULL,\n   NULL, 0, -1, 0, 0,\n    { 0 } },\n" ++
        "  { MVM_JIT_TILE_NAME(i), \"1.21.22.\",\n   \"(add reg (load reg $size))\", 0, 2, 2, 3,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n};\n") != null);
}

test "select and state tables match the canonicalised Perl output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runTest(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/* Tiler tables */\n" ++
        "static const MVMint32 MVM_jit_tile_select[][3] = {\n" ++
        "  { 0, 0, 0 },\n  { 1, 0, 1 },\n  { 2, 0, 2 },\n  { 2, 1, 5 },\n  { 3, 0, 3 },\n" ++
        "  { 3, 2, 7 },\n  { 4, 0, 4 },\n  { 5, 0, 6 },\n  { 6, 0, 8 },\n};\n") != null);
    // 7 head templates (MVM_JIT_TILE_NAME) + 65 state rows; Perl output has the same counts.
    try std.testing.expectEqual(@as(usize, 72), countLines(r.out, "  { MVM_JIT_"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "static MVMint32 MVM_jit_tile_state[][6] = {\n  { MVM_JIT_LOAD, 0, -1, 3, 3 },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  { MVM_JIT_ADD, 0, 2, 5, 6 },\n  { MVM_JIT_ADD, 0, 3, 6, 8 },\n") != null);
    // Perl's `$best ||= ...` treats rule 0 as "no rule", so the (stack) state prints -1.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  { MVM_JIT_STACK, -1, -1, 0, -1 },\n};\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "/* FILE AUTOGENERATED BY tools/zig/tiler_table_generator.zig. DO NOT EDIT. */\n"));
    try std.testing.expect(std.mem.endsWith(u8, r.out, "    return MVM_jit_tile_select[mid][2];\n}\n\n"));
}

const Gen = struct {
    gpa: std.mem.Allocator,
    pseudosym: u32 = 0,
    rules: std.ArrayList(Rule) = .empty,
};

const RuleCtx = struct {
    path: std.ArrayList(u8) = .empty,
    spec: std.ArrayList([]const u8) = .empty,
    refs: u32 = 0,
    num: u5 = 0,
};

/// reg:NAME / num:NAME -> register_require(NAME); reg -> storage_gpr;
/// num -> storage_fpr; anything else -> storage_none.
fn registerSpec(gpa: std.mem.Allocator, symbol: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, symbol, ':');
    const ty = it.next().?;
    const name = it.next();
    if (std.mem.eql(u8, ty, "reg") or std.mem.eql(u8, ty, "num")) {
        if (name) |n| return std.fmt.allocPrint(gpa, "register_require({s})", .{try std.ascii.allocUpperString(gpa, n)});
        return if (std.mem.eql(u8, ty, "num")) "storage_fpr" else "storage_gpr";
    }
    return "storage_none";
}

/// Strips a `:annotation` suffix (word characters only).
fn symbolName(symbol: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, symbol, ':') orelse return symbol;
    const tail = symbol[colon + 1 ..];
    if (tail.len == 0) return symbol;
    for (tail) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return symbol;
    return symbol[0..colon];
}

fn appendPath(gpa: std.mem.Allocator, ctx: *RuleCtx, trace: []const usize, i: usize) !void {
    var w: std.Io.Writer.Allocating = .init(gpa);
    for (trace) |t| try w.writer.print("{d}", .{t});
    try w.writer.print("{d}.", .{i});
    try ctx.path.appendSlice(gpa, w.written());
}

/// Port of decompose: sub-patterns become pseudo-symbols "#N" with half the
/// cost; `$arg` items and value symbols extend the lookup path; rules are
/// appended children-first, the rule for `tree` itself last.
fn decompose(g: *Gen, ctx: *RuleCtx, tree: *const Node, sym: []const u8, cost_in: f64, trace: []const usize) Error!void {
    const gpa = g.gpa;
    var cost = cost_in;
    var list: std.ArrayList([]const u8) = .empty;
    for (tree.items.items, 0..) |item, i| {
        if (item.isList()) {
            const newsym = try std.fmt.allocPrint(gpa, "#{d}", .{g.pseudosym});
            g.pseudosym += 1;
            cost /= 2;
            const sub_trace = try std.mem.concat(gpa, usize, &.{ trace, &.{i} });
            try decompose(g, ctx, item, newsym, cost, sub_trace);
            try list.append(gpa, newsym);
        } else if (item.atom.len > 0 and item.atom[0] == '$') {
            try appendPath(gpa, ctx, trace, i);
            ctx.num += 1;
        } else {
            if (i > 0) {
                try appendPath(gpa, ctx, trace, i);
                ctx.refs += @as(u32, 1) << ctx.num;
                ctx.num += 1;
                try ctx.spec.append(gpa, try registerSpec(gpa, item.atom));
            }
            try list.append(gpa, symbolName(item.atom));
        }
    }
    try g.rules.append(gpa, .{ .pat = list.items, .sym = symbolName(sym), .cost = cost });
}

/// Port of add_rule: decomposes one statement and annotates its head rule.
fn addRule(g: *Gen, name: ?[]const u8, tree: *const Node, sym: []const u8, cost: f64) Error!void {
    var ctx: RuleCtx = .{};
    try ctx.spec.append(g.gpa, try registerSpec(g.gpa, sym));
    try decompose(g, &ctx, tree, sym, cost, &.{});
    const head = &g.rules.items[g.rules.items.len - 1];
    head.is_head = true;
    head.name = name;
    head.path = ctx.path.items;
    head.spec = ctx.spec.items;
    head.refs = ctx.refs;
    head.text = try sexpr.encode(g.gpa, tree);
}

fn parseGrammar(g: *Gen, text: []const u8) Error!void {
    var parser = sexpr.Parser.init(g.gpa, text);
    while (parser.next() catch return error.MalformedStatement) |tree| {
        if (tree.items.items.len == 0) continue;
        const keyword = tree.items.items[0].atom;
        const rest = tree.items.items[1..];
        if (std.mem.eql(u8, keyword, "tile:")) {
            // (tile: name pattern symbol cost)
            if (rest.len != 4 or !rest[1].isList()) return error.MalformedStatement;
            const cost = std.fmt.parseFloat(f64, rest[3].atom) catch return error.BadCost;
            try addRule(g, rest[0].atom, rest[1], rest[2].atom, cost);
        } else if (std.mem.eql(u8, keyword, "define:")) {
            // (define: pattern symbol [cost]); Perl calls add_rule(undef, @$tree, 0),
            // so a third item in the statement (e.g. `(define: (carg reg) c_arg 1)`)
            // becomes the cost and the appended 0 is ignored.
            if (rest.len < 2 or rest.len > 3 or !rest[0].isList()) return error.MalformedStatement;
            const cost: f64 = if (rest.len == 3) (std.fmt.parseFloat(f64, rest[2].atom) catch return error.BadCost) else 0;
            try addRule(g, null, rest[0], rest[1].atom, cost);
        }
        // other keywords are ignored, as in the Perl tool
    }
}

const SymSet = std.StringHashMap(void);

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanRuleList(_: void, a: []const u32, b: []const u32) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

/// Port of combine_rules. The %sets/%trie fixpoint is order independent; the
/// resulting rulesets are sorted canonically instead of taken in hash order.
fn combineRules(gpa: std.mem.Allocator, rules: []const Rule) Error![]const []const u32 {
    // sets: key -> symbols of that symset
    var sets = std.StringHashMap([]const []const u8).init(gpa);
    for (rules) |r| try sets.put(r.sym, try gpa.dupe([]const u8, &.{r.sym}));

    var trie = std.StringHashMap(std.AutoHashMap(u32, []const u8)).init(gpa);
    while (true) {
        // lookup: symbol -> set of symset keys it appears in
        var lookup = std.StringHashMap(SymSet).init(gpa);
        var sit = sets.iterator();
        while (sit.next()) |e| {
            for (e.value_ptr.*) |s| {
                const gop = try lookup.getOrPut(s);
                if (!gop.found_existing) gop.value_ptr.* = SymSet.init(gpa);
                try gop.value_ptr.put(e.key_ptr.*, {});
            }
        }
        trie = std.StringHashMap(std.AutoHashMap(u32, []const u8)).init(gpa);
        for (rules, 0..) |rule, rule_nr_usize| {
            const rule_nr: u32 = @intCast(rule_nr_usize);
            const head = rule.pat[0];
            const sym1: ?[]const u8 = if (rule.pat.len > 1) rule.pat[1] else null;
            const sym2: ?[]const u8 = if (rule.pat.len > 2) rule.pat[2] else null;
            if (sym2) |s2| {
                var l1 = (lookup.get(sym1.?) orelse continue).keyIterator();
                while (l1.next()) |k1| {
                    var l2 = (lookup.get(s2) orelse continue).keyIterator();
                    while (l2.next()) |k2| try trieInsert(gpa, &trie, head, k1.*, k2.*, rule_nr, rule.sym);
                }
            } else if (sym1) |s1| {
                var l1 = (lookup.get(s1) orelse continue).keyIterator();
                while (l1.next()) |k1| try trieInsert(gpa, &trie, head, k1.*, "-1", rule_nr, rule.sym);
            } else {
                try trieInsert(gpa, &trie, head, "-1", "-1", rule_nr, rule.sym);
            }
        }
        // new symsets: the distinct symbols each trie cell can produce
        var new_sets = std.StringHashMap([]const []const u8).init(gpa);
        var tit = trie.valueIterator();
        while (tit.next()) |cell| {
            var syms: std.ArrayList([]const u8) = .empty;
            var vit = cell.valueIterator();
            while (vit.next()) |s| {
                var dup = false;
                for (syms.items) |x| if (std.mem.eql(u8, x, s.*)) {
                    dup = true;
                };
                if (!dup) try syms.append(gpa, s.*);
            }
            std.mem.sort([]const u8, syms.items, {}, lessThanStr);
            const key = try std.mem.join(gpa, ":", syms.items);
            try new_sets.put(key, syms.items);
        }
        var deleted: usize = 0;
        var kit = sets.keyIterator();
        while (kit.next()) |k| if (!new_sets.contains(k.*)) {
            deleted += 1;
        };
        const added = @as(isize, @intCast(new_sets.count())) - @as(isize, @intCast(sets.count())) + @as(isize, @intCast(deleted));
        sets = new_sets;
        if (added == 0 and deleted == 0) break;
    }
    // rulesets: distinct sorted rule-number lists of the trie cells, canonical order
    var seen = std.StringHashMap(void).init(gpa);
    var rulesets: std.ArrayList([]const u32) = .empty;
    var tit = trie.valueIterator();
    while (tit.next()) |cell| {
        var nrs: std.ArrayList(u32) = .empty;
        var kit2 = cell.keyIterator();
        while (kit2.next()) |k| try nrs.append(gpa, k.*);
        std.mem.sort(u32, nrs.items, {}, std.sort.asc(u32));
        const key = try joinU32(gpa, nrs.items, ",");
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        try rulesets.append(gpa, nrs.items);
    }
    std.mem.sort([]const u32, rulesets.items, {}, lessThanRuleList);
    return rulesets.items;
}

fn trieInsert(gpa: std.mem.Allocator, trie: *std.StringHashMap(std.AutoHashMap(u32, []const u8)), head: []const u8, k1: []const u8, k2: []const u8, rule_nr: u32, sym: []const u8) !void {
    const key = try std.fmt.allocPrint(gpa, "{s},{s},{s}", .{ head, k1, k2 });
    const gop = try trie.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = std.AutoHashMap(u32, []const u8).init(gpa);
    try gop.value_ptr.put(rule_nr, sym);
}

fn joinU32(gpa: std.mem.Allocator, items: []const u32, sep: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    for (items, 0..) |x, i| {
        if (i > 0) try w.writer.writeAll(sep);
        try w.writer.print("{d}", .{x});
    }
    return w.toOwnedSlice();
}

const TableEntry = struct { head: []const u8, rs1: i32, rs2: i32, state: u32 };
const RsSym = struct { rs: u32, sym: u32 };
const RsRule = struct { rs: u32, rule: u32 };

/// Port of generate_table: for every rule and every pair of candidate
/// rulesets for its operand symbols, the set of rules that match
/// (head, rs1, rs2) is itself a ruleset; record its number.
fn generateTable(gpa: std.mem.Allocator, rules: []const Rule, rulesets: []const []const u32) Error![]const TableEntry {
    var candidates = std.StringHashMap(std.AutoHashMap(u32, void)).init(gpa);
    var trans = std.StringHashMap(u32).init(gpa);
    for (rulesets, 0..) |ruleset, nr_usize| {
        const nr: u32 = @intCast(nr_usize);
        for (ruleset) |rule_nr| {
            const gop = try candidates.getOrPut(rules[rule_nr].sym);
            if (!gop.found_existing) gop.value_ptr.* = std.AutoHashMap(u32, void).init(gpa);
            try gop.value_ptr.put(nr, {});
        }
        try trans.put(try joinU32(gpa, ruleset, ":"), nr); // rulesets are already sorted
    }
    const Flat = struct { head: []const u8, rs1: i32, rs2: i32, rules: std.AutoHashMap(u32, void) };
    var flat: std.ArrayList(Flat) = .empty;
    var flat_index = std.StringHashMap(usize).init(gpa);
    for (rules, 0..) |rule, rule_nr_usize| {
        const rule_nr: u32 = @intCast(rule_nr_usize);
        const head = rule.pat[0];
        const sym1: ?[]const u8 = if (rule.pat.len > 1) rule.pat[1] else null;
        const sym2: ?[]const u8 = if (rule.pat.len > 2) rule.pat[2] else null;
        if (sym2) |s2| {
            var c1 = (candidates.get(sym1.?) orelse continue).keyIterator();
            while (c1.next()) |rs1| {
                var c2 = (candidates.get(s2) orelse continue).keyIterator();
                while (c2.next()) |rs2| try flatInsert(gpa, &flat, &flat_index, head, @intCast(rs1.*), @intCast(rs2.*), rule_nr);
            }
        } else if (sym1) |s1| {
            var c1 = (candidates.get(s1) orelse continue).keyIterator();
            while (c1.next()) |rs1| try flatInsert(gpa, &flat, &flat_index, head, @intCast(rs1.*), -1, rule_nr);
        } else try flatInsert(gpa, &flat, &flat_index, head, -1, -1, rule_nr);
    }
    var table: std.ArrayList(TableEntry) = .empty;
    for (flat.items) |f| {
        var nrs: std.ArrayList(u32) = .empty;
        var kit = f.rules.keyIterator();
        while (kit.next()) |k| try nrs.append(gpa, k.*);
        std.mem.sort(u32, nrs.items, {}, std.sort.asc(u32));
        const state = trans.get(try joinU32(gpa, nrs.items, ":")) orelse return error.CannotFindKey;
        try table.append(gpa, .{ .head = f.head, .rs1 = f.rs1, .rs2 = f.rs2, .state = state });
    }
    return table.items;
}

fn flatInsert(gpa: std.mem.Allocator, flat: anytype, index: *std.StringHashMap(usize), head: []const u8, rs1: i32, rs2: i32, rule_nr: u32) !void {
    const key = try std.fmt.allocPrint(gpa, "{s},{d},{d}", .{ head, rs1, rs2 });
    const gop = try index.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = flat.items.len;
        try flat.append(gpa, .{ .head = head, .rs1 = rs1, .rs2 = rs2, .rules = std.AutoHashMap(u32, void).init(gpa) });
    }
    try flat.items[gop.value_ptr.*].rules.put(rule_nr, {});
}

/// Port of compute_costs: seed with each rule's own cost, then iterate
/// (Jacobi style, from the previous iteration's values) adding the cheapest
/// child costs averaged over every (rs1, rs2) pair that leads to the ruleset,
/// until the minimum-cost rule per (ruleset, symbol) stops changing.
fn computeCosts(gpa: std.mem.Allocator, rules: []const Rule, rulesets: []const []const u32, table: []const TableEntry, symnum: *const std.StringHashMap(u32)) Error!std.AutoHashMap(RsSym, u32) {
    var reversed = std.AutoHashMap(u32, std.ArrayList([2]i32)).init(gpa);
    for (table) |e| {
        const gop = try reversed.getOrPut(e.state);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, .{ e.rs1, e.rs2 });
    }
    var rule_cost = std.AutoHashMap(RsRule, f64).init(gpa);
    var min_cost = std.AutoHashMap(RsSym, u32).init(gpa);
    for (rulesets, 0..) |ruleset, rs_usize| {
        const rs: u32 = @intCast(rs_usize);
        for (ruleset) |rule_nr| {
            const cost = rules[rule_nr].cost;
            const sym = symnum.get(rules[rule_nr].sym).?;
            if (min_cost.get(.{ .rs = rs, .sym = sym })) |best| {
                if (rule_cost.get(.{ .rs = rs, .rule = best }).? > cost) try min_cost.put(.{ .rs = rs, .sym = sym }, rule_nr);
            } else try min_cost.put(.{ .rs = rs, .sym = sym }, rule_nr);
            try rule_cost.put(.{ .rs = rs, .rule = rule_nr }, cost);
        }
    }
    while (true) {
        var new_cost = std.AutoHashMap(RsRule, f64).init(gpa);
        var new_min = std.AutoHashMap(RsSym, u32).init(gpa);
        for (rulesets, 0..) |ruleset, rs_usize| {
            const rs: u32 = @intCast(rs_usize);
            const rev = reversed.get(rs) orelse return error.RulesetUnreachable;
            for (ruleset) |rule_nr| {
                var cost = rules[rule_nr].cost;
                const pat = rules[rule_nr].pat;
                for (rev.items) |rsg| {
                    if (pat.len > 1) cost += try childCost(&rule_cost, &min_cost, rsg[0], symnum.get(pat[1]).?);
                    if (pat.len > 2) cost += try childCost(&rule_cost, &min_cost, rsg[1], symnum.get(pat[2]).?);
                }
                cost /= @as(f64, @floatFromInt(rev.items.len));
                const sym = symnum.get(rules[rule_nr].sym).?;
                if (new_min.get(.{ .rs = rs, .sym = sym })) |best| {
                    if (new_cost.get(.{ .rs = rs, .rule = best }).? > cost) try new_min.put(.{ .rs = rs, .sym = sym }, rule_nr);
                } else try new_min.put(.{ .rs = rs, .sym = sym }, rule_nr);
                try new_cost.put(.{ .rs = rs, .rule = rule_nr }, cost);
            }
        }
        var changed: usize = 0;
        var it = min_cost.iterator();
        while (it.next()) |e| {
            const nv = new_min.get(e.key_ptr.*) orelse return error.MissingCost;
            if (nv != e.value_ptr.*) changed += 1;
        }
        rule_cost = new_cost;
        min_cost = new_min;
        if (changed == 0) break;
    }
    return min_cost;
}

fn childCost(rule_cost: *const std.AutoHashMap(RsRule, f64), min_cost: *const std.AutoHashMap(RsSym, u32), rs: i32, sym: u32) Error!f64 {
    if (rs < 0) return error.MissingCost;
    const best = min_cost.get(.{ .rs = @intCast(rs), .sym = sym }) orelse return error.MissingCost;
    return rule_cost.get(.{ .rs = @intCast(rs), .rule = best }) orelse error.MissingCost;
}

pub fn generate(gpa: std.mem.Allocator, tile_text: []const u8, eo: *const expr_ops.ExprOps, debug: ?*std.Io.Writer, out: *std.Io.Writer) !void {
    var g: Gen = .{ .gpa = gpa };
    try parseGrammar(&g, tile_text);
    const rules = g.rules.items;
    const rulesets = try combineRules(gpa, rules);

    if (debug) |d| {
        try d.writeAll("Rules:\n");
        for (rules, 0..) |r, i| try d.print("{d} => {s}: {s}\n", .{ i, try encodePattern(gpa, r.pat), r.sym });
        try d.writeAll("Rulesets:\n");
        for (rulesets, 0..) |rs, i| {
            try d.print("{d} => ", .{i});
            for (rs) |n| try d.print("{d}, ", .{n});
            try d.writeAll("\n");
        }
    }

    // symbols: unique rule symbols in rule order
    var symbols: std.ArrayList([]const u8) = .empty;
    var symnum = std.StringHashMap(u32).init(gpa);
    for (rules) |r| {
        if (!symnum.contains(r.sym)) {
            try symnum.put(r.sym, @intCast(symbols.items.len));
            try symbols.append(gpa, r.sym);
        }
    }
    const table = try generateTable(gpa, rules, rulesets);
    var min_cost = try computeCosts(gpa, rules, rulesets, table, &symnum);

    try out.writeAll("/* FILE AUTOGENERATED BY tools/zig/tiler_table_generator.zig. DO NOT EDIT. */\n");
    try out.writeAll("/* Tile function declarations */\n");
    for (rules) |r| if (r.name) |n| {
        if (n.len > 0 and !std.mem.eql(u8, n, "0")) try out.print("{s}TILE_DECL({s});\n", .{ PREFIX, n });
    };
    try out.writeAll("/* Tile template declarations */\n");
    try out.print("static const MVMJitTileTemplate {s}templates[] = {{\n", .{VARNAME});
    for (rules) |r| {
        const sn1: i32 = if (r.pat.len > 1) @intCast(symnum.get(r.pat[1]).?) else -1;
        const sn2: i32 = if (r.pat.len > 2) @intCast(symnum.get(r.pat[2]).?) else -1;
        if (r.is_head) {
            const func = if (r.name) |n| try std.fmt.allocPrint(gpa, "{s}TILE_NAME({s})", .{ PREFIX, n }) else "NULL";
            var spec: std.ArrayList([]const u8) = .empty;
            for (r.spec) |s| try spec.append(gpa, try std.ascii.allocUpperString(gpa, try std.mem.concat(gpa, u8, &.{ "mvm_jit_", s })));
            try out.print("  {{ {s}, \"{s}\",\n   \"{s}\", {d}, {d}, {d}, {d},\n    {{ {s} }} }},\n", .{
                func, r.path, r.text, sn1, sn2, @popCount(r.refs), r.refs, try std.mem.join(gpa, ", ", spec.items),
            });
        } else {
            try out.print("  {{ NULL, NULL,\n   NULL, {d}, {d}, 0, 0,\n    {{ 0 }} }},\n", .{ sn1, sn2 });
        }
    }
    try out.writeAll("};\n");

    try out.writeAll("/* Tiler tables */\n");
    try out.print("static const MVMint32 {s}select[][3] = {{\n", .{VARNAME});
    for (rulesets, 0..) |_, rs_usize| {
        const rs: u32 = @intCast(rs_usize);
        for (symbols.items, 0..) |_, sym_usize| {
            const sym: u32 = @intCast(sym_usize);
            if (min_cost.get(.{ .rs = rs, .sym = sym })) |rule| try out.print("  {{ {d}, {d}, {d} }},\n", .{ rs, sym, rule });
        }
    }
    try out.writeAll("};\n");

    try out.writeAll(
        \\
        \\/* Each table item consists of 5 integers:
        \\ * 0..3 -> lookup key (nodenr, ruleset_1, ruleset_2)
        \\ * 4    -> next state
        \\ * 5    -> optimum rule if this were a root */
        \\
        \\/* TODO - I think this table format can be, if we want it, much
        \\ * smaller - for our current table sizes, keys could fit in 32 bits.
        \\ * And we could add the terminals and minimum-cost table as
        \\ * intermediates. */
        \\
        \\
        \\
    );
    try out.print("static MVMint32 {s}state[][6] = {{\n", .{VARNAME});
    const best_syms = [_][]const u8{ "reg", "num", "void" };
    for (eo.ops) |op| {
        const head = try std.ascii.allocLowerString(gpa, op.name);
        var rows: std.ArrayList(TableEntry) = .empty;
        for (table) |e| if (std.mem.eql(u8, e.head, head)) try rows.append(gpa, e);
        std.mem.sort(TableEntry, rows.items, {}, lessThanRow);
        for (rows.items) |e| {
            // Perl: `$best ||= $min_cost{$state,$_} for qw(reg num void)`; rule 0 is falsy.
            var best: ?u32 = null;
            for (best_syms) |s| {
                if (best != null) break;
                const sym = symnum.get(s) orelse continue;
                if (min_cost.get(.{ .rs = e.state, .sym = sym })) |rule| if (rule != 0) {
                    best = rule;
                };
            }
            try out.print("  {{ {s}{s}, {d}, {d}, {d}, {d} }},\n", .{ PREFIX, op.name, e.rs1, e.rs2, e.state, @as(i64, if (best) |b| @intCast(b) else -1) });
        }
    }
    try out.writeAll("};\n");
    try out.writeAll(lookup_routines);
}

fn lessThanRow(_: void, a: TableEntry, b: TableEntry) bool {
    if (a.rs1 != b.rs1) return a.rs1 < b.rs1;
    return a.rs2 < b.rs2;
}

fn encodePattern(gpa: std.mem.Allocator, pat: []const []const u8) ![]const u8 {
    const list = try Node.newList(gpa);
    for (pat) |p| try list.items.append(gpa, try Node.newAtom(gpa, p));
    return sexpr.encode(gpa, list);
}

const lookup_routines =
    \\/* Lookup routines. Implemented here so that we may change it
    \\ * independently from tiler */
    \\
    \\static MVMint32* MVM_jit_tile_state_lookup(MVMThreadContext *tc, MVMint32 node, MVMint32 c1, MVMint32 c2) {
    \\    MVMint32 top    = (sizeof(MVM_jit_tile_state)/sizeof(MVM_jit_tile_state[0]));
    \\    MVMint32 bottom = 0;
    \\    MVMint32 mid = (top + bottom) / 2;
    \\    while (bottom < mid) {
    \\        if (MVM_jit_tile_state[mid][0] < node) {
    \\            bottom = mid;
    \\            mid    = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_state[mid][0] > node) {
    \\            top = mid;
    \\            mid = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_state[mid][1] < c1) {
    \\            bottom = mid;
    \\            mid    = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_state[mid][1] > c1) {
    \\            top = mid;
    \\            mid = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_state[mid][2] < c2) {
    \\            bottom = mid;
    \\            mid    = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_state[mid][2] > c2) {
    \\            top = mid;
    \\            mid = (top + bottom) / 2;
    \\        } else {
    \\            break;
    \\        }
    \\    }
    \\    if (MVM_jit_tile_state[mid][0] != node ||
    \\        MVM_jit_tile_state[mid][1] != c1   ||
    \\        MVM_jit_tile_state[mid][2] != c2)
    \\        return NULL;
    \\    return MVM_jit_tile_state[mid];
    \\}
    \\
    \\/* Same as above, maps tile state + nonterm -> child rule, used for
    \\ * downward propagation of optimal rules */
    \\
    \\static MVMint32 MVM_jit_tile_select_lookup(MVMThreadContext *tc, MVMint32 ts, MVMint32 nt) {
    \\    MVMint32 top    = (sizeof(MVM_jit_tile_select)/sizeof(MVM_jit_tile_select[0]));
    \\    MVMint32 bottom = 0;
    \\    MVMint32 mid = (top + bottom) / 2;
    \\    while (bottom < mid) {
    \\        if (MVM_jit_tile_select[mid][0] < ts) {
    \\            bottom = mid;
    \\            mid    = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_select[mid][0] > ts) {
    \\            top = mid;
    \\            mid = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_select[mid][1] < nt) {
    \\            bottom = mid;
    \\            mid    = (top + bottom) / 2;
    \\        } else if (MVM_jit_tile_select[mid][1] > nt) {
    \\            top = mid;
    \\            mid = (top + bottom) / 2;
    \\        } else {
    \\            break;
    \\        }
    \\    }
    \\    if (MVM_jit_tile_select[mid][0] != ts ||
    \\        MVM_jit_tile_select[mid][1] != nt)
    \\        return -1;
    \\    return MVM_jit_tile_select[mid][2];
    \\}
    \\
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var expr_ops_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var debug = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--expr-ops")) {
            i += 1;
            expr_ops_path = args[i];
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.eql(u8, a, "--debug")) {
            debug = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown option {s}\n", .{a});
            std.process.exit(2);
        } else input_path = a;
    }
    const in_path = input_path orelse {
        std.debug.print("usage: tiler_table_generator --expr-ops src/jit/expr_ops.h [--debug] -o out.h input.tile\n", .{});
        std.process.exit(2);
    };
    const cwd = std.Io.Dir.cwd();
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, try cwd.readFileAlloc(io, expr_ops_path orelse "src/jit/expr_ops.h", arena, .unlimited));
    const text = try cwd.readFileAlloc(io, in_path, arena, .unlimited);
    var out: std.Io.Writer.Allocating = .init(arena);
    var stdout_buf: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    generate(arena, text, eo, if (debug) &stdout.interface else null, &out.writer) catch |err| {
        std.debug.print("tiler_table_generator: {s}: {t}\n", .{ in_path, err });
        std.process.exit(1);
    };
    if (output_path) |p| {
        try cwd.writeFile(io, .{ .sub_path = p, .data = out.written() });
    } else {
        try stdout.interface.writeAll(out.written());
    }
    try stdout.interface.flush();
}
