# Zig Build Phase 2: JIT Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `rakudo/docs/superpowers/specs/2026-11-01-zig-build-migration-design.md` (two directories above the nqp checkout), section 5 "JIT pipeline", section 9 "Testing", phase 2 of section 11. Phase 1 plan with its "Deviations" section: `docs/superpowers/plans/2026-11-01-zig-build-phase1-moarvm.md`.

**Goal:** `zig build` produces a MoarVM with the x86-64 JIT enabled by default, with no Perl in the build: dynasm runs through a zig-built `minilua`, and the two Perl code generators (`tools/expr-template-compiler.pl`, `tools/tiler-table-generator.pl`) are ported to Zig and verified against the Perl originals.

**Architecture:** `build/zig/jit.zig` builds three host executables (`minilua` from `3rdparty/dynasm/minilua.c`, and the two Zig tools under `tools/zig/`), runs them as cached `Run` steps, and collects the generated `core_templates.h` and `tile_pattern.h` into a `WriteFile` directory laid out as `jit/core_templates.h` and `jit/x64/tile_pattern.h`, which `libmoar` puts on its include path ahead of `src/`. The generated `emit.c` is compiled from the cache. A `check-jit-tools` step runs the Perl originals and diffs: byte-identical for `emit.c` and `core_templates.h` (after the first line, which names the generator), and identical after canonical ruleset renumbering for `tile_pattern.h`, because the Perl tiler's output depends on Perl's randomized hash order.

**Tech Stack:** Zig 0.16.0 (`/usr/bin/zig`), `zig cc`, Lua 5.1 via the bundled `minilua.c`, Perl only inside the optional `check-jit-tools` verification step.

## Global Constraints

- Zig version exactly 0.16.0. Standalone tools use the 0.16 program shape: `pub fn main(init: std.process.Init) !void`, args via `init.minimal.args.toSlice(arena)`, I/O via `init.io`, files via `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited)` and `std.Io.Dir.cwd().writeFile(io, .{ .sub_path, .data })`, in-memory output via `std.Io.Writer.Allocating`.
- No Perl file changes at all in this phase. `Configure.pl`, `build/Makefile.in`, `tools/*.pl`, `tools/lib/*.pm`, `src/` and `3rdparty/` are read-only.
- Side by side: the Perl build keeps working unchanged. The Perl-generated `src/jit/core_templates.h`, `src/jit/x64/tile_pattern.h` and `src/jit/x64/emit.c` (all gitignored) may exist in the tree; the zig build must not read them and must not be shadowed by them (the generated include directory goes on the include path before `src`).
- Equivalence requirements: `emit.c` byte-identical to the Perl build's (same dynasm, same relative input paths so `#line` directives match); `core_templates.h` byte-identical from line 2 onward (line 1 names the generating program); `tile_pattern.h` identical from line 2 onward after `tools/canonicalize-tile-table.pl` renumbers the Perl output's rulesets canonically (rulesets sorted lexicographically by their sorted rule-number lists). The Zig tiler emits that canonical numbering directly.
- `-Djit` defaults to `true` on x86_64-linux; `-Djit=false` keeps building the stub as in phase 1. The phase-1 "not implemented" fatal goes away.
- All build-time tools are built for `b.graph.host`, not the target.
- Commits go on MoarVM branch `zig-build-phase2` (created from `zig-build-phase1` at `7b106ff79`). Commit message trailer: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (or the trailer the implementer's own instructions specify).
- Working directory for every command: the MoarVM checkout (`rakudo/nqp/MoarVM`). `$SCRATCH` means `/tmp/claude-1000/-home-longwalker-code-raku-x-core-zmoarz-rakudo-nqp-MoarVM/529300be-8495-4763-892d-134053416824/scratchpad`.
- Perl is available on this machine for verification; a system MoarVM 2025.08 exists at `/usr/lib/libmoar.so`, so a `moar --version` printing `2025.08` means the wrong library was loaded.

## Reference facts (gathered while planning)

- Perl build rules (`build/Makefile.in:360-524`): `MINILUA = 3rdparty/dynasm/minilua`, built with `$(CC) 3rdparty/dynasm/minilua.c -lm -o $@` (no defines). `DYNASM = $(MINILUA) 3rdparty/dynasm/dynasm.lua`, `DASM_FLAGS = -D POSIX=1`. `.dasc.c: $(DYNASM) $(DASM_FLAGS) -o $@ $<`. `.expr.h: perl -Itools/ tools/expr-template-compiler.pl -o $@ $<`. `.tile.h: perl -Itools/ tools/tiler-table-generator.pl -o $@ $<`. All run from the repo root. Dependencies: `emit.c` ← `emit.dasc`, `tiles.dasc` (pulled in by `|.include src/jit/x64/tiles.dasc`, resolved relative to the cwd), `dynasm.lua`, `dasm_x86.lua`; `core_templates.h` ← `core_templates.expr`, `macro.expr` (via `(include: "src/jit/macro.expr")`, cwd-relative), `src/core/oplist`, `src/jit/expr_ops.h`; `tile_pattern.h` ← `tile_pattern.tile`, `src/jit/expr_ops.h`.
- Consumers: `src/jit/expr.c:44` `#include "jit/core_templates.h"`, `src/jit/tile.c:5` `#include "jit/x64/tile_pattern.h"`. With `-I<gen> -Isrc`, the generated directory wins because the including file's own directory (`src/jit/`) does not contain `jit/...`.
- `dynasm.lua` finds `dasm_x64.lua` through the directory part of its own `arg[0]` (`prefix = match(arg[0], "^(.*[/\\])")`), and `.include` files through `g_opt.include = { "" }`, so with cwd = repo root, `3rdparty/dynasm/dynasm.lua` as the script path and `src/jit/x64/emit.dasc` as the input, the output is identical to the Perl build's `src/jit/x64/emit.c` (its header says `The original file is in "src/jit/x64/emit.dasc"` and `#line 1 "src/jit/x64/emit.dasc"`).
- Determinism (measured): three runs of `tools/expr-template-compiler.pl` are byte-identical and equal `src/jit/core_templates.h`. Three runs of `tools/tiler-table-generator.pl` differ (first difference at the `MVM_jit_tile_select` table): ruleset numbers come from Perl hash iteration order. After renumbering rulesets by their sorted rule lists (using the `--debug` listing, which prints `Rulesets:` with membership) and re-sorting the `select` and `state` rows, the three runs are identical. `PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0` also makes Perl deterministic but is not reproducible from Zig.
- Sizes: `src/core/oplist` defines 973 ops (the generated footer says `opcode >= 973`); `src/jit/expr_ops.h` defines 51 expression ops including `MAX_NODES`; `core_templates.expr` is 3100 lines; `tile_pattern.tile` has 164 lines and yields 257 lines of `--debug` output (rules plus rulesets).
- JIT sources: `build/sources.list` `[jit]` (8 files), `[jit-x64]` (`src/jit/x64/emit.c`, `src/jit/x64/arch.c`), `[jit-stub]` (`src/jit/stub.c`). `src/jit/internal.h` defines `MVM_JIT_ARCH_X64 1`, `MVM_JIT_PLATFORM_POSIX 1`. `config.zig` already emits `MVM_JIT_ARCH_X64`/`MVM_JIT_PLATFORM_POSIX` when `opts.jit` is true.
- Functional JIT exercise: `MVM_SPESH_NODELAY=1 MVM_SPESH_BLOCKING=1 MVM_JIT_EXPR_ENABLE=1` force specialization and both JITs on hot frames. `moar --version` prints ` built with JIT support` when `MVM_jit_support()` is true.
- Perl `sexpr.pm` tokens: `(`, `)`, whitespace, `#` to end of line, `"..."` strings kept with their quotes, words `[^\s()#"']+`.
- `perl -Itools/ tools/expr-template-compiler.pl --test` (the tool's self-test) dies with "$1 is not declared" because it links `(copy $1)` without an operand environment; the Zig unit tests supply one.
- Perl quirks that must be reproduced (see the task text for each): `sexpr_encode` strips the last character unconditionally, so an empty list encodes as `)`; the tiler's `$best ||= $min_cost{...} for qw(reg num void)` treats rule number 0 as "no rule", so a state whose best rule is rule 0 prints `-1`; `looks_like_number` accepts signed decimal integers and floats; `expr_type` on a bare atom that is not `$name`/`\$name` dies, so macros whose `?`-typed operators take bare `,param` atoms are rejected.

## File structure

| Path | Responsibility |
|---|---|
| `tools/zig/sexpr.zig` | S-expression `Node` tree, `Parser`, `encode` (port of `tools/lib/sexpr.pm`) |
| `tools/zig/oplist.zig` | `src/core/oplist` parser (port of `tools/lib/oplist.pm`) |
| `tools/zig/expr_ops.zig` | `src/jit/expr_ops.h` parser (port of `tools/lib/expr_ops.pm`) |
| `tools/zig/expr_template_compiler.zig` | port of `tools/expr-template-compiler.pl` |
| `tools/zig/tiler_table_generator.zig` | port of `tools/tiler-table-generator.pl`, canonical ruleset order |
| `tools/canonicalize-tile-table.pl` | renumbers a Perl `tile_pattern.h` into the canonical order for the equivalence check |
| `tools/check-jit-tools.sh` | runs the Perl generators and diffs them against the zig outputs |
| `build/zig/jit.zig` | `minilua`, dynasm step, tool executables and run steps, generated include dir, `check-jit-tools` step |
| `build/zig/options.zig` | `-Djit` default true on x86_64-linux |
| `build/zig/moar.zig` | JIT sources and include dir in `libmoar` |
| `build.zig` | wiring, `check-jit-tools` and the JIT functional test |
| `docs/zig-build.md` | JIT section |

---

### Task 1: `minilua` and the dynasm step

**Files:**
- Create: `build/zig/jit.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `options.Options` (fields `target`, `optimize`, `jit`).
- Produces: `jit.Dynasm { minilua: *std.Build.Step.Compile, emit_c: std.Build.LazyPath }`, `jit.addDynasm(b: *std.Build) Dynasm`. Later tasks add `jit.Tools` and `jit.Generated` to this file.

- [ ] **Step 1: Create the branch and confirm the baseline**

```bash
git checkout zig-build-phase1 && git checkout -b zig-build-phase2 2>/dev/null || git checkout zig-build-phase2
git log --oneline -1
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build test --summary all 2>&1 | tail -3
ls -la src/jit/x64/emit.c
```
Expected: HEAD is `7b106ff79` or later on `zig-build-phase2`; the phase-1 build and tests pass; the Perl-generated `src/jit/x64/emit.c` exists (it is the reference for this task; if it is missing, generate it once with `perl Configure.pl --optimize --prefix=/home/longwalker/code/raku/x.core/zmoarz/rakudo/install && make src/jit/x64/emit.c && rm -f src/gen/config.h src/gen/config.c src/gen/config.o`).

- [ ] **Step 2: Write `build/zig/jit.zig` with `addDynasm`**

```zig
//! JIT code generation at build time: minilua runs DynASM over emit.dasc,
//! and the Zig ports of the Perl generators produce the expression template
//! and tiler tables. All of these run on the build host.
const std = @import("std");
const Options = @import("options.zig").Options;

pub const Dynasm = struct {
    minilua: *std.Build.Step.Compile,
    emit_c: std.Build.LazyPath,
};

/// Builds 3rdparty/dynasm/minilua.c for the host and runs
/// `minilua 3rdparty/dynasm/dynasm.lua -D POSIX=1 -o <cache>/emit.c src/jit/x64/emit.dasc`
/// from the repository root. Relative paths matter: dynasm writes them into
/// `#line` directives and resolves `|.include src/jit/x64/tiles.dasc` against
/// the cwd, and the Perl build uses the same relative paths.
pub fn addDynasm(b: *std.Build) Dynasm {
    const host = b.graph.host;
    const mod = b.createModule(.{
        .target = host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addCSourceFile(.{ .file = b.path("3rdparty/dynasm/minilua.c"), .flags = &.{} });
    mod.linkSystemLibrary("m", .{});
    const minilua = b.addExecutable(.{ .name = "minilua", .root_module = mod });

    const run = b.addRunArtifact(minilua);
    run.setCwd(b.path("."));
    run.addArg("3rdparty/dynasm/dynasm.lua");
    run.addArgs(&.{ "-D", "POSIX=1", "-o" });
    const emit_c = run.addOutputFileArg("emit.c");
    run.addArg("src/jit/x64/emit.dasc");
    // Inputs dynasm reads by relative path; registered so the cache sees them.
    for ([_][]const u8{
        "src/jit/x64/emit.dasc",
        "src/jit/x64/tiles.dasc",
        "3rdparty/dynasm/dynasm.lua",
        "3rdparty/dynasm/dasm_x64.lua",
        "3rdparty/dynasm/dasm_x86.lua",
    }) |p| run.addFileInput(b.path(p));

    return .{ .minilua = minilua, .emit_c = emit_c };
}
```

- [ ] **Step 3: Add an `emit-c` inspection step to `build.zig`**

Add `const jit = @import("build/zig/jit.zig");` to the imports and, after the `thirdparty` step block:
```zig
    const dynasm = jit.addDynasm(b);
    const emit_c_step = b.step("emit-c", "Run DynASM and copy the generated emit.c to zig-out/emit.c for inspection");
    emit_c_step.dependOn(&b.addInstallFileWithDir(dynasm.emit_c, .prefix, "emit.c").step);
```

- [ ] **Step 4: Build and compare with the Perl-generated file**

```bash
zig build emit-c --summary all 2>&1 | tail -3 && cmp src/jit/x64/emit.c zig-out/emit.c && echo "emit.c IDENTICAL"
```
Expected: steps succeed and `emit.c IDENTICAL`. If `cmp` reports a difference in the first lines, check that the script and input paths are passed exactly as `3rdparty/dynasm/dynasm.lua` and `src/jit/x64/emit.dasc` (relative). If dynasm reports `include file 'src/jit/x64/tiles.dasc' not found`, the `setCwd` is missing.

- [ ] **Step 5: Commit**

```bash
git add build/zig/jit.zig build.zig
git commit -m "zig build: build minilua and run DynASM over emit.dasc

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: S-expression reader and printer

**Files:**
- Create: `tools/zig/sexpr.zig`

**Interfaces:**
- Produces: `sexpr.Node` (`kind: .atom | .list`, `atom: []const u8`, `items: std.ArrayList(*Node)`), `Node.newAtom(gpa, text) !*Node`, `Node.newList(gpa) !*Node`, `Node.head(n) []const u8` (first item's atom text or `""`), `sexpr.Parser.init(gpa, src) Parser`, `Parser.next(*Parser) Error!?*Node` (next top-level list, `null` at end), `sexpr.encode(gpa, node) ![]u8`, `sexpr.encodeInto(w: *std.Io.Writer, node) !void`.
- Nodes are heap pointers because the compiler relies on node identity (Perl `refaddr`) for common-subexpression numbering and macro expansion sharing.

- [ ] **Step 1: Write the failing tests**

Create `tools/zig/sexpr.zig`:
```zig
//! S-expression reader and printer, a port of tools/lib/sexpr.pm.
//! Tokens: `(`, `)`, whitespace, `#` to end of line, `"..."` strings kept
//! with their quotes, and words made of anything except whitespace, parens,
//! `#`, `"` and `'`.
const std = @import("std");

pub const Node = struct {
    kind: enum { atom, list },
    atom: []const u8 = "",
    items: std.ArrayList(*Node) = .empty,

    pub fn newAtom(gpa: std.mem.Allocator, text: []const u8) !*Node {
        const n = try gpa.create(Node);
        n.* = .{ .kind = .atom, .atom = text };
        return n;
    }

    pub fn newList(gpa: std.mem.Allocator) !*Node {
        const n = try gpa.create(Node);
        n.* = .{ .kind = .list };
        return n;
    }

    pub fn isList(n: *const Node) bool {
        return n.kind == .list;
    }

    /// Text of the first item when it is an atom, else "".
    pub fn head(n: *const Node) []const u8 {
        if (n.kind != .list or n.items.items.len == 0) return "";
        const h = n.items.items[0];
        return if (h.kind == .atom) h.atom else "";
    }
};

pub const Error = error{ ExpectedOpen, UnexpectedEnd, UnterminatedString, UnexpectedCharacter, OutOfMemory };

pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, src: []const u8) Parser {
        return .{ .src = src, .gpa = gpa };
    }

    pub fn next(self: *Parser) Error!?*Node {
        _ = self;
        return error.ExpectedOpen;
    }
};

pub fn encode(gpa: std.mem.Allocator, node: *const Node) ![]u8 {
    _ = gpa;
    _ = node;
    return error.OutOfMemory;
}

fn parseAll(arena: std.mem.Allocator, src: []const u8) ![]*Node {
    var p = Parser.init(arena, src);
    var out: std.ArrayList(*Node) = .empty;
    while (try p.next()) |n| try out.append(arena, n);
    return out.items;
}

test "parse: nested lists, strings keep quotes, comments and blanks skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try parseAll(arena.allocator(),
        \\# leading comment
        \\(template: add_i (add $1 $2)) # trailing comment
        \\
        \\(include: "src/jit/macro.expr")
        \\(macro: ^frame () (load (tc) 8))
    );
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("template:", nodes[0].head());
    try std.testing.expectEqual(@as(usize, 3), nodes[0].items.items.len);
    const add = nodes[0].items.items[2];
    try std.testing.expect(add.isList());
    try std.testing.expectEqualStrings("add", add.head());
    try std.testing.expectEqualStrings("$2", add.items.items[2].atom);
    try std.testing.expectEqualStrings("\"src/jit/macro.expr\"", nodes[1].items.items[1].atom);
    // empty parameter list parses as an empty list node
    const params = nodes[2].items.items[2];
    try std.testing.expect(params.isList());
    try std.testing.expectEqual(@as(usize, 0), params.items.items.len);
}

test "parse: errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ExpectedOpen, parseAll(arena.allocator(), "add $1"));
    try std.testing.expectError(error.UnexpectedEnd, parseAll(arena.allocator(), "(add $1"));
    try std.testing.expectError(error.UnterminatedString, parseAll(arena.allocator(), "(include: \"x)"));
    try std.testing.expectError(error.UnexpectedCharacter, parseAll(arena.allocator(), "(a 'b)"));
}

test "encode: matches sexpr_encode, including its empty-list quirk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try parseAll(arena.allocator(), "(add reg (load (addr reg $ofs) $size)) (x ())");
    try std.testing.expectEqualStrings("(add reg (load (addr reg $ofs) $size))", try encode(arena.allocator(), nodes[0]));
    // Perl: `$out = substr $out, 0, -1 if (substr $out, -1 eq ' ')` always strips the
    // last character, so "(" becomes "" and the empty list encodes as ")".
    try std.testing.expectEqualStrings("(x ))", try encode(arena.allocator(), nodes[1]));
    const atom = try Node.newAtom(arena.allocator(), "reg");
    try std.testing.expectEqualStrings("'reg'", try encode(arena.allocator(), atom));
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `zig test tools/zig/sexpr.zig`
Expected: compile succeeds and the three tests FAIL (`error.ExpectedOpen` / `error.OutOfMemory` returned).

- [ ] **Step 3: Implement `Parser.next` and `encode`**

Replace the two stubs:
```zig
    pub fn next(self: *Parser) Error!?*Node {
        self.skipSpaceAndComments();
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] != '(') return error.ExpectedOpen;
        return try self.parseList();
    }

    fn parseList(self: *Parser) Error!*Node {
        std.debug.assert(self.src[self.pos] == '(');
        self.pos += 1;
        const node = try Node.newList(self.gpa);
        while (true) {
            self.skipSpaceAndComments();
            if (self.pos >= self.src.len) return error.UnexpectedEnd;
            const c = self.src[self.pos];
            if (c == ')') {
                self.pos += 1;
                return node;
            }
            if (c == '(') {
                try node.items.append(self.gpa, try self.parseList());
                continue;
            }
            if (c == '"') {
                const close = std.mem.indexOfScalarPos(u8, self.src, self.pos + 1, '"') orelse
                    return error.UnterminatedString;
                try node.items.append(self.gpa, try Node.newAtom(self.gpa, self.src[self.pos .. close + 1]));
                self.pos = close + 1;
                continue;
            }
            const start = self.pos;
            while (self.pos < self.src.len and !isWordEnd(self.src[self.pos])) self.pos += 1;
            if (self.pos == start) return error.UnexpectedCharacter;
            try node.items.append(self.gpa, try Node.newAtom(self.gpa, self.src[start..self.pos]));
        }
    }

    fn skipSpaceAndComments(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else return;
        }
    }

    fn isWordEnd(c: u8) bool {
        return std.ascii.isWhitespace(c) or c == '(' or c == ')' or c == '#' or c == '"' or c == '\'';
    }
```
and
```zig
/// Port of sexpr_encode: a bare atom is quoted with single quotes; a list is
/// written with single spaces between items. Perl appends a space after every
/// item and then strips the last character unconditionally, which also turns
/// an empty list "(" into ")" — reproduced here so outputs stay identical.
pub fn encode(gpa: std.mem.Allocator, node: *const Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try encodeInto(&out.writer, node);
    return out.toOwnedSlice();
}

pub fn encodeInto(w: *std.Io.Writer, node: *const Node) !void {
    if (node.kind == .atom) {
        try w.print("'{s}'", .{node.atom});
        return;
    }
    if (node.items.items.len == 0) {
        try w.writeByte(')');
        return;
    }
    try w.writeByte('(');
    for (node.items.items, 0..) |item, i| {
        if (i > 0) try w.writeByte(' ');
        if (item.kind == .list) try encodeInto(w, item) else try w.writeAll(item.atom);
    }
    try w.writeByte(')');
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `zig test tools/zig/sexpr.zig`
Expected: `All 3 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/zig/sexpr.zig
git commit -m "tools/zig: S-expression reader and printer (port of sexpr.pm)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `oplist` and `expr_ops.h` parsers

**Files:**
- Create: `tools/zig/oplist.zig`
- Create: `tools/zig/expr_ops.zig`

**Interfaces:**
- Produces: `oplist.Operand { dir: []const u8, ty: []const u8 }` (`dir` is `"r"`, `"w"` or `""`), `oplist.Op { name, attribute: ?[]const u8, operands: []Operand, adverbs: [][]const u8 }`, `oplist.Oplist { ops: []Op }` with `parse(gpa, text) !Oplist`, `get(self, name) ?*const Op`, `Op.outputOperand(op) ?[]const u8` (type of the first `w` operand).
- Produces: `expr_ops.ExprOp { name: []const u8 (as written, upper case), num_operands: i32, num_params: i32, idx: usize }`, `expr_ops.ExprOps { ops: []ExprOp }` with `parse(gpa, text) !ExprOps`, `get(self, lower_name) ?*const ExprOp`.

- [ ] **Step 1: Write `tools/zig/oplist.zig` with failing tests**

```zig
//! Parser for src/core/oplist, a port of tools/lib/oplist.pm.
const std = @import("std");

pub const Operand = struct { dir: []const u8, ty: []const u8 };

pub const Op = struct {
    name: []const u8,
    attribute: ?[]const u8,
    operands: []Operand,
    adverbs: [][]const u8,

    /// Type of the first write operand, or null.
    pub fn outputOperand(op: *const Op) ?[]const u8 {
        for (op.operands) |o| if (std.mem.eql(u8, o.dir, "w")) return o.ty;
        return null;
    }
};

pub const Oplist = struct {
    ops: []Op,
    by_name: std.StringHashMap(usize),

    pub fn get(self: *const Oplist, name: []const u8) ?*const Op {
        const i = self.by_name.get(name) orelse return null;
        return &self.ops[i];
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Oplist {
    _ = text;
    return .{ .ops = &.{}, .by_name = std.StringHashMap(usize).init(gpa) };
}

test "parse: operands, attribute, adverbs, comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ol = try parse(arena.allocator(),
        \\# comment line
        \\no_op
        \\const_i64           w(int64) int64 :pure :confprog
        \\sp_guardconc     .s w(obj) r(obj) sslot uint32 :maycausedeopt
        \\getlex              w(`1) rl(`1) :pure
        \\
    );
    try std.testing.expectEqual(@as(usize, 4), ol.ops.len);
    try std.testing.expectEqualStrings("no_op", ol.ops[0].name);
    try std.testing.expectEqual(@as(usize, 0), ol.ops[0].operands.len);
    const c = ol.get("const_i64").?;
    try std.testing.expect(c.attribute == null);
    try std.testing.expectEqual(@as(usize, 2), c.operands.len);
    try std.testing.expectEqualStrings("w", c.operands[0].dir);
    try std.testing.expectEqualStrings("int64", c.operands[0].ty);
    try std.testing.expectEqualStrings("", c.operands[1].dir);
    try std.testing.expectEqualStrings("int64", c.operands[1].ty);
    try std.testing.expectEqual(@as(usize, 2), c.adverbs.len);
    try std.testing.expectEqualStrings(":confprog", c.adverbs[1]);
    const g = ol.get("sp_guardconc").?;
    try std.testing.expectEqualStrings(".s", g.attribute.?);
    try std.testing.expectEqual(@as(usize, 4), g.operands.len);
    try std.testing.expectEqualStrings("obj", g.outputOperand().?);
    const l = ol.get("getlex").?;
    try std.testing.expectEqualStrings("r", l.operands[1].dir); // "rl(`1)" is a read operand
    try std.testing.expectEqualStrings("`1", l.operands[1].ty);
    try std.testing.expect(ol.get("nope") == null);
}
```

- [ ] **Step 2: Write `tools/zig/expr_ops.zig` with a failing test**

```zig
//! Parser for src/jit/expr_ops.h, a port of tools/lib/expr_ops.pm: after the
//! line containing `#define MVM_JIT_EXPR_OPS`, every `_(NAME, operands, params)`
//! entry in order, including MAX_NODES.
const std = @import("std");

pub const ExprOp = struct {
    name: []const u8,
    num_operands: i32,
    num_params: i32,
    idx: usize,
};

pub const ExprOps = struct {
    ops: []ExprOp,
    by_lower: std.StringHashMap(usize),

    /// Lookup by lower-case name (the template language uses lower case).
    pub fn get(self: *const ExprOps, lower_name: []const u8) ?*const ExprOp {
        const i = self.by_lower.get(lower_name) orelse return null;
        return &self.ops[i];
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !ExprOps {
    _ = text;
    return .{ .ops = &.{}, .by_lower = std.StringHashMap(usize).init(gpa) };
}

test "parse: entries after the define, comments ignored, variadic kept negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const eo = try parse(arena.allocator(),
        \\/* header (NOT, 9, 9) must be ignored before the define */
        \\#define MVM_JIT_EXPR_OPS(_) \
        \\    /* invalid operator */ \
        \\    _(NOOP, 0, 0), \
        \\    _(LOAD, 1, 1),   \
        \\    _(ALL, -1, 0), \
        \\    _(MAX_NODES, 0, 0)
    );
    try std.testing.expectEqual(@as(usize, 4), eo.ops.len);
    try std.testing.expectEqualStrings("NOOP", eo.ops[0].name);
    const load = eo.get("load").?;
    try std.testing.expectEqual(@as(usize, 1), load.idx);
    try std.testing.expectEqual(@as(i32, 1), load.num_operands);
    try std.testing.expectEqual(@as(i32, 1), load.num_params);
    try std.testing.expectEqual(@as(i32, -1), eo.get("all").?.num_operands);
    try std.testing.expectEqualStrings("MAX_NODES", eo.ops[3].name);
    try std.testing.expect(eo.get("LOAD") == null);
}
```

- [ ] **Step 3: Run both test files to see them fail**

Run: `zig test tools/zig/oplist.zig; zig test tools/zig/expr_ops.zig`
Expected: both FAIL (0 ops parsed).

- [ ] **Step 4: Implement `oplist.parse`**

```zig
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Oplist {
    var ops: std.ArrayList(Op) = .empty;
    var by_name = std.StringHashMap(usize).init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // Perl: chomp; s/#.*$//; next unless length
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| line = line[0..hash];
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        var operands: std.ArrayList(Operand) = .empty;
        var adverbs: std.ArrayList([]const u8) = .empty;
        var attribute: ?[]const u8 = null;
        while (fields.next()) |meta| {
            if (meta.len == 2 and std.mem.indexOfScalar(u8, "-+.:*", meta[0]) != null and isWordChar(meta[1])) {
                attribute = meta; // ^[-+.:*]\w$
            } else if (meta.len >= 2 and meta[0] == ':' and allWordChars(meta[1..])) {
                try adverbs.append(gpa, meta); // ^:\w+$
            } else if (parseDirectedOperand(meta)) |o| {
                try operands.append(gpa, o); // ^([rw])l?\((.+)\)$
            } else {
                try operands.append(gpa, .{ .dir = "", .ty = meta });
            }
        }
        try by_name.put(name, ops.items.len);
        try ops.append(gpa, .{
            .name = name,
            .attribute = attribute,
            .operands = try operands.toOwnedSlice(gpa),
            .adverbs = try adverbs.toOwnedSlice(gpa),
        });
    }
    return .{ .ops = try ops.toOwnedSlice(gpa), .by_name = by_name };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn allWordChars(s: []const u8) bool {
    for (s) |c| if (!isWordChar(c)) return false;
    return true;
}

/// Matches `r(...)`, `w(...)`, `rl(...)`, `wl(...)`; returns dir "r"/"w" and the inner type.
fn parseDirectedOperand(meta: []const u8) ?Operand {
    if (meta.len < 3) return null;
    if (meta[0] != 'r' and meta[0] != 'w') return null;
    var i: usize = 1;
    if (meta[i] == 'l') i += 1;
    if (i >= meta.len or meta[i] != '(' or meta[meta.len - 1] != ')') return null;
    if (meta.len - 1 <= i + 1) return null; // (.+) needs at least one char
    return .{ .dir = meta[0..1], .ty = meta[i + 1 .. meta.len - 1] };
}
```

- [ ] **Step 5: Implement `expr_ops.parse`**

```zig
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !ExprOps {
    var ops: std.ArrayList(ExprOp) = .empty;
    var by_lower = std.StringHashMap(usize).init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var seen_define = false;
    while (lines.next()) |line| {
        if (!seen_define) {
            if (std.mem.indexOf(u8, line, "#define MVM_JIT_EXPR_OPS") != null) seen_define = true;
            continue;
        }
        const entry = parseEntry(line) orelse continue;
        const idx = ops.items.len;
        const lower = try std.ascii.allocLowerString(gpa, entry.name);
        try by_lower.put(lower, idx);
        try ops.append(gpa, .{ .name = entry.name, .num_operands = entry.num_operands, .num_params = entry.num_params, .idx = idx });
    }
    return .{ .ops = try ops.toOwnedSlice(gpa), .by_lower = by_lower };
}

const Entry = struct { name: []const u8, num_operands: i32, num_params: i32 };

/// Finds `(\w+),\s*(-?\d+),\s*(\d+)\)` anywhere in the line.
fn parseEntry(line: []const u8) ?Entry {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, start, '(')) |open| {
        start = open + 1;
        var i = open + 1;
        const name_start = i;
        while (i < line.len and isWordChar(line[i])) i += 1;
        if (i == name_start or i >= line.len or line[i] != ',') continue;
        const name = line[name_start..i];
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const ops_start = i;
        if (i < line.len and line[i] == '-') i += 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == ops_start or i >= line.len or line[i] != ',') continue;
        const num_operands = std.fmt.parseInt(i32, line[ops_start..i], 10) catch continue;
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const params_start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == params_start or i >= line.len or line[i] != ')') continue;
        const num_params = std.fmt.parseInt(i32, line[params_start..i], 10) catch continue;
        return .{ .name = name, .num_operands = num_operands, .num_params = num_params };
    }
    return null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `zig test tools/zig/oplist.zig && zig test tools/zig/expr_ops.zig`
Expected: `All 1 tests passed.` twice.

- [ ] **Step 7: Check both parsers against the real files**

Write a throwaway program in the scratch directory (not committed):
```bash
mkdir -p $SCRATCH/counts && cat > $SCRATCH/counts/main.zig <<'ZIG'
const std = @import("std");
const oplist = @import("oplist.zig");
const expr_ops = @import("expr_ops.zig");
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const ol_text = try std.Io.Dir.cwd().readFileAlloc(io, "src/core/oplist", arena, .unlimited);
    const eo_text = try std.Io.Dir.cwd().readFileAlloc(io, "src/jit/expr_ops.h", arena, .unlimited);
    const ol = try oplist.parse(arena, ol_text);
    const eo = try expr_ops.parse(arena, eo_text);
    std.debug.print("ops={d} expr_ops={d} getlex_no={s} inc_i_operands={d}\n", .{ ol.ops.len, eo.ops.len, ol.get("getlex_no").?.operands[0].ty, ol.get("inc_i").?.operands.len });
}
ZIG
cp tools/zig/oplist.zig tools/zig/expr_ops.zig $SCRATCH/counts/ && zig run $SCRATCH/counts/main.zig
```
Expected: `ops=973 expr_ops=51 getlex_no=obj inc_i_operands=1`.

- [ ] **Step 8: Commit**

```bash
git add tools/zig/oplist.zig tools/zig/expr_ops.zig
git commit -m "tools/zig: oplist and expr_ops.h parsers (ports of oplist.pm, expr_ops.pm)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Port `expr-template-compiler.pl` to Zig

**Files:**
- Create: `tools/zig/expr_template_compiler.zig`

**Interfaces:**
- Consumes: `sexpr.Node`, `sexpr.Parser`, `oplist.Oplist`, `expr_ops.ExprOps` from Tasks 2-3.
- Produces: a host executable with the command line `expr_template_compiler --oplist <src/core/oplist> --expr-ops <src/jit/expr_ops.h> -o <out.h> <input.expr>`. It must run with the repository root as cwd because `(include: "src/jit/macro.expr")` paths inside `.expr` files are cwd-relative (the Perl tool has the same requirement). Output: byte-identical to `perl -Itools/ tools/expr-template-compiler.pl -o out input.expr` from line 2 onward; line 1 reads `/* FILE AUTOGENERATED BY tools/zig/expr_template_compiler.zig. DO NOT EDIT.`.
- Node identity is semantic: a `let:` binding shares one `*Node` between the declaration and every use, and macro expansion shares one expanded instance per source sub-node; `compileExpression` numbers nodes by pointer, so shared nodes compile once (this is how the Perl tool implements common-subexpression reuse).

The Perl source `tools/expr-template-compiler.pl` is the reference for every rule below; read it alongside this task. Function names in the Zig port follow the Perl names.

- [ ] **Step 1: Write the module skeleton with tables, types and failing tests**

Create `tools/zig/expr_template_compiler.zig`:
```zig
//! Port of tools/expr-template-compiler.pl: compiles src/jit/core_templates.expr
//! (S-expression templates per MoarVM opcode) into the C tables in
//! core_templates.h. Must run from the repository root because `include:`
//! paths in .expr files are cwd-relative.
const std = @import("std");
const sexpr = @import("sexpr.zig");
const oplist = @import("oplist.zig");
const expr_ops = @import("expr_ops.zig");
const Node = sexpr.Node;

const PREFIX = "MVM_JIT_";

pub const Error = error{
    InvalidTemplate,
    UnknownOperator,
    TypeMismatch,
    NotDeclared,
    UndefinedMacro,
    MacroArity,
    UnmatchedSubstitution,
    InvalidName,
    ExpectedExpression,
    ExpectedOperator,
    OperandCount,
    CannotMatchTypes,
    ExpectedSizeParameter,
    ExpectedReference,
    InvalidOperandReference,
    RequireReference,
    NotAReference,
    UndefinedNamedReference,
    ExpectedMacroExpression,
    UnknownOpcode,
    OpcodeRedefined,
    NoWriteOperand,
    UnknownKeyword,
    MacroRedeclared,
    TemplateRedeclaredInInclude,
    MalformedStatement,
    OutOfMemory,
};

// --- Template check tables (verbatim from the Perl tool) ---

/// Expected result type of an operator; anything missing is 'reg'.
const operator_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "store", "void" }, .{ "store_num", "void" }, .{ "discard", "void" }, .{ "dov", "void" },
    .{ "when", "void" },  .{ "ifv", "void" },       .{ "branch", "void" },  .{ "mark", "void" },
    .{ "callv", "void" }, .{ "guard", "void" },
    .{ "lt", "flag" }, .{ "le", "flag" }, .{ "eq", "flag" }, .{ "ne", "flag" }, .{ "ge", "flag" },
    .{ "gt", "flag" }, .{ "nz", "flag" }, .{ "zr", "flag" }, .{ "all", "flag" }, .{ "any", "flag" },
    .{ "const_num", "num" }, .{ "load_num", "num" }, .{ "calln", "num" },
    .{ "if", "?" }, .{ "copy", "?" }, .{ "do", "?" }, .{ "add", "?" }, .{ "sub", "?" }, .{ "mul", "?" },
    .{ "arglist", "arglist" }, .{ "carg", "carg" },
});

/// Expected operand types, comma separated; anything missing is 'reg'.
const operand_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "flagval", "flag" }, .{ "all", "flag" }, .{ "any", "flag" }, .{ "copy", "?" },
    .{ "do", "void,?" }, .{ "dov", "void" }, .{ "when", "flag,void" }, .{ "if", "flag,?,?" },
    .{ "ifv", "flag,void,void" }, .{ "call", "reg,arglist" }, .{ "calln", "reg,arglist" },
    .{ "callv", "reg,arglist" }, .{ "arglist", "carg" }, .{ "carg", "?" }, .{ "store", "reg,?" },
    .{ "guard", "void" },
    .{ "lt", "?" }, .{ "le", "?" }, .{ "eq", "?" }, .{ "ne", "?" }, .{ "ge", "?" }, .{ "gt", "?" },
    .{ "nz", "?" }, .{ "zr", "?" }, .{ "add", "?" }, .{ "sub", "?" }, .{ "mul", "?" },
});

/// Which (1-based) operand position carries the size.
const op_size_param = std.StaticStringMap(usize).initComptime(.{
    .{ "load", 2 }, .{ "load_num", 2 }, .{ "store", 3 }, .{ "store_num", 3 },
    .{ "call", 3 }, .{ "const", 2 }, .{ "cast", 2 },
});

/// MoarVM operand types to expression types; anything missing is 'reg'.
const moar_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "num32", "num" }, .{ "num64", "num" }, .{ "`1", "?" },
});

// --- Environments, macros, compiler state ---

/// A `let:` name maps to its definition node; an opcode operand name ("$0",
/// "$1", ...) maps to its expression type.
pub const EnvEntry = union(enum) { ty: []const u8, node: *Node };
pub const Env = std.StringHashMap(EnvEntry);

pub const Macro = struct {
    params: []const []const u8, // atoms such as ",object"
    body: *Node,
    ty: []const u8,
};
pub const Macros = std.StringHashMap(Macro);

/// Constant table shared by every template: index = first-seen order.
pub const Constants = std.StringArrayHashMap(void);

const Code = struct { tag: u8, value: []const u8 };

pub const Compiled = struct { root: u32, template: []const []const u8, desc: []const u8 };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    ops: *const expr_ops.ExprOps,
    ol: *const oplist.Oplist,
    constants: *Constants,
};

const Compiler = struct {
    ctx: Ctx,
    opcode: []const u8,
    operands: *const Env,
    expr_index: std.AutoHashMap(*Node, u32),
    tmpl: std.ArrayList([]const u8) = .empty,
    desc: std.ArrayList(u8) = .empty,
};

pub const Info = struct { idx: usize, desc: []const u8, root: u32, len: usize, flags: u8 };

pub const ParsedFile = struct {
    templates: std.ArrayList([]const u8) = .empty,
    info: std.StringHashMap(Info),
};

// --- Helpers ---

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn allWordChars(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isWordChar(c)) return false;
    return true;
}

/// Perl's looks_like_number for the inputs that occur here: an optional sign,
/// decimal digits, optional fraction and exponent.
pub fn looksLikeNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E')) return false;
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

fn upper(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.ascii.allocUpperString(gpa, s);
}

fn prefixed(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.mem.concat(gpa, u8, &.{ PREFIX, try upper(gpa, s) });
}

fn fmtInt(gpa: std.mem.Allocator, n: anytype) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{n});
}

/// `\$(\w+)` anywhere in an atom: returns the name after the `$`, or null.
fn dollarName(atom: []const u8) ?[]const u8 {
    const d = std.mem.indexOfScalar(u8, atom, '$') orelse return null;
    var end = d + 1;
    while (end < atom.len and isWordChar(atom[end])) end += 1;
    if (end == d + 1) return null;
    return atom[d + 1 .. end];
}

// --- Public pipeline (implemented in later steps) ---

pub fn linkDeclarations(gpa: std.mem.Allocator, expr: *Node, env_in: *const Env) Error!void {
    _ = gpa;
    _ = expr;
    _ = env_in;
    return error.InvalidTemplate;
}

pub fn applyMacros(gpa: std.mem.Allocator, expr: *Node, macros: *const Macros) Error!void {
    _ = gpa;
    _ = expr;
    _ = macros;
    return error.InvalidTemplate;
}

pub fn exprType(gpa: std.mem.Allocator, expr: *const Node, env: *const Env) Error![]const u8 {
    _ = gpa;
    _ = expr;
    _ = env;
    return error.InvalidTemplate;
}

pub fn compileTemplate(ctx: Ctx, expr: *Node, opcode: []const u8, operands: *const Env) Error!Compiled {
    _ = ctx;
    _ = expr;
    _ = opcode;
    _ = operands;
    return error.InvalidTemplate;
}

// --- Tests ---

const test_oplist =
    \\no_op
    \\const_i64           w(int64) int64 :pure :confprog
    \\set                 w(`1) r(`1) :pure :confprog
    \\add_i               w(int64) r(int64) r(int64) :pure :confprog
    \\inc_i               w(int64)
    \\getcode             w(obj) coderef :pure
;

const test_expr_ops =
    \\#define MVM_JIT_EXPR_OPS(_) \
    \\    _(NOOP, 0, 0), _(COPY, 1, 0), _(LOAD, 1, 1), _(STORE, 2, 1), _(ADDR, 1, 1), _(IDX, 2, 1), \
    \\    _(CONST, 0, 2), _(CONST_PTR, 0, 1), _(NZ, 1, 0), _(DISCARD, 1, 0), _(ADD, 2, 0), \
    \\    _(DO, -1, 0), _(DOV, -1, 0), _(IF, 3, 0), _(CALLV, 2, 0), _(ARGLIST, -1, 0), _(CARG, 1, 1), \
    \\    _(TC, 0, 0), _(CU, 0, 0), _(MAX_NODES, 0, 0)
;

fn testCtx(arena: std.mem.Allocator, constants: *Constants) !Ctx {
    const ol = try arena.create(oplist.Oplist);
    ol.* = try oplist.parse(arena, test_oplist);
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, test_expr_ops);
    return .{ .gpa = arena, .ops = eo, .ol = ol, .constants = constants };
}

fn parseOne(arena: std.mem.Allocator, src: []const u8) !*Node {
    var p = sexpr.Parser.init(arena, src);
    return (try p.next()).?;
}

test "compile: (copy $1) for const_i64 gives the real file's first row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants = Constants.init(a);
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("const_i64").?);
    const tmpl = try parseOne(a, "(copy $1)");
    const c = try compileTemplate(ctx, tmpl, "const_i64", &env);
    try std.testing.expectEqualStrings("nsi", c.desc);
    try std.testing.expectEqual(@as(u32, 0), c.root);
    try std.testing.expectEqual(@as(usize, 3), c.template.len);
    try std.testing.expectEqualStrings("MVM_JIT_COPY", c.template[0]);
    try std.testing.expectEqualStrings("1", c.template[1]);
    try std.testing.expectEqualStrings("1", c.template[2]);
}

test "compile: nested operands emit children first; constants are numbered; parameters are prefixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants = Constants.init(a);
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("getcode").?);
    // (load (idx (load (addr (cu) (&offsetof MVMCompUnit body.strings)) ptr_sz) $1 ptr_sz) ptr_sz)
    const tmpl = try parseOne(a, "(load (idx (load (addr (cu) (&offsetof MVMCompUnit body.strings)) ptr_sz) $1 ptr_sz) ptr_sz)");
    const c = try compileTemplate(ctx, tmpl, "getcode", &env);
    // cu:0 addr:2 load:6 idx:10 load:15  -> desc per node: ns, nsl., nsl., nslil, nsl.
    try std.testing.expectEqualStrings("nsnsl.nsl.nslilnsl.", c.desc);
    try std.testing.expectEqual(@as(u32, 15), c.root);
    try std.testing.expectEqualStrings("MVM_JIT_CU", c.template[0]);
    try std.testing.expectEqualStrings("0", c.template[1]);
    try std.testing.expectEqualStrings("MVM_JIT_ADDR", c.template[2]);
    try std.testing.expectEqualStrings("0", c.template[4]); // 'l' -> node 0
    try std.testing.expectEqualStrings("offsetof(MVMCompUnit, body.strings)", c.template[5]);
    try std.testing.expectEqualStrings("MVM_JIT_PTR_SZ", c.template[9]);
    try std.testing.expectEqualStrings("1", c.template[13]); // 'i' -> $1
}

test "compile: const_ptr records a constant and writes 0 operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants = Constants.init(a);
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("no_op").?);
    const tmpl = try parseOne(a, "(callv (const_ptr &MVM_foo) (arglist (carg (tc) ptr)))");
    const c = try compileTemplate(ctx, tmpl, "no_op", &env);
    try std.testing.expectEqualStrings("nscnsnsl.nslnsll", c.desc);
    try std.testing.expectEqualStrings("MVM_JIT_CONST_PTR", c.template[0]);
    try std.testing.expectEqualStrings("0", c.template[1]);
    try std.testing.expectEqualStrings("0", c.template[2]); // constant number 0
    try std.testing.expectEqual(@as(usize, 1), constants.count());
    try std.testing.expectEqualStrings("&MVM_foo", constants.keys()[0]);
}

test "compile: errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var constants = Constants.init(a);
    const ctx = try testCtx(a, &constants);
    const env = try moarOperands(a, ctx.ol.get("add_i").?);
    try std.testing.expectError(error.RequireReference, compileTemplate(ctx, try parseOne(a, "(copy $0)"), "add_i", &env));
    try std.testing.expectError(error.NotAReference, compileTemplate(ctx, try parseOne(a, "(copy \\$1)"), "add_i", &env));
    try std.testing.expectError(error.UnknownOperator, compileTemplate(ctx, try parseOne(a, "(bogus $1)"), "add_i", &env));
    try std.testing.expectError(error.OperandCount, compileTemplate(ctx, try parseOne(a, "(add $1)"), "add_i", &env));
    try std.testing.expectError(error.ExpectedSizeParameter, compileTemplate(ctx, try parseOne(a, "(load $1 nope)"), "add_i", &env));
}

test "link: single let shares the definition node (Perl test 1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($foo (copy $1))) (load $foo 8))");
    // The Perl tool's own --test passes no environment and therefore dies on
    // `(copy $1)` ("$1 is not declared"); real templates always have operand
    // types in scope, so provide $1 here.
    var env = Env.init(a);
    try env.put("$1", .{ .ty = "reg" });
    try linkDeclarations(a, expr, &env);
    // (do (discard X) (load X 8))
    try std.testing.expectEqualStrings("do", expr.head());
    try std.testing.expect(expr.items.items[1].items.items[1] == expr.items.items[2].items.items[1]);
}

test "link: nested lets, left-to-right (Perl test 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($foo (const 1 1)) ($bar (add $foo $foo))) (let: (($foo (sub $bar (const 1 1)))) (copy $foo)))");
    var env = Env.init(a);
    try linkDeclarations(a, expr, &env);
    const it = expr.items.items;
    // forward declaration: outer $foo used twice inside $bar's definition
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[1].items.items[1]);
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[1].items.items[2]);
    // inner declaration: do -> discard -> sub -> $bar, and do -> discard -> sub == do -> copy -> $foo
    try std.testing.expect(it[2].items.items[1] == it[3].items.items[1].items.items[1].items.items[1]);
    try std.testing.expect(it[3].items.items[1].items.items[1] == it[3].items.items[2].items.items[1]);
}

test "macros: expansion shares instances and keeps links (Perl test 3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expr = try parseOne(a, "(let: (($obj (load $1))) (^foo $obj))");
    const body = try parseOne(a, "(let: (($obj (addr ,foo 8))) (add ,foo $obj))");
    var empty = Env.init(a);
    try linkDeclarations(a, body, &empty);
    try linkDeclarations(a, expr, &empty);
    var macros = Macros.init(a);
    try macros.put("^foo", .{ .params = &.{",foo"}, .body = body, .ty = "?" });
    try applyMacros(a, expr, &macros);
    const it = expr.items.items;
    // outer let: the (load $1) node is the macro's ,foo argument in (add ,foo $obj)
    try std.testing.expect(it[1].items.items[1] == it[2].items.items[2].items.items[1]);
    // macro let: (addr ...) is shared between its discard and the use in add
    try std.testing.expect(it[2].items.items[1].items.items[1] == it[2].items.items[2].items.items[2]);
    try std.testing.expectError(error.UndefinedMacro, applyMacros(a, try parseOne(a, "(^nope 1)"), &macros));
    try std.testing.expectError(error.MacroArity, applyMacros(a, try parseOne(a, "(^foo 1 2)"), &macros));
}

test "exprType: polymorphic resolution and checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.init(a);
    try env.put("$1", .{ .ty = "reg" });
    try env.put("$2", .{ .ty = "num" });
    try std.testing.expectEqualStrings("reg", try exprType(a, try parseOne(a, "(add $1 $1)"), &env));
    try std.testing.expectEqualStrings("num", try exprType(a, try parseOne(a, "(if (nz $1) $2 $2)"), &env));
    try std.testing.expectEqualStrings("void", try exprType(a, try parseOne(a, "(dov (discard $1))"), &env));
    try std.testing.expectEqualStrings("?", try exprType(a, try parseOne(a, "(^macro $1)"), &env));
    try std.testing.expectError(error.TypeMismatch, exprType(a, try parseOne(a, "(add $1 $2)"), &env));
    try std.testing.expectError(error.TypeMismatch, exprType(a, try parseOne(a, "(if $1 $1 $1)"), &env));
    try std.testing.expectError(error.NotDeclared, exprType(a, try parseOne(a, "(copy $9)"), &env));
    try std.testing.expectError(error.ExpectedExpression, exprType(a, try parseOne(a, "(add ,x ,x)"), &env));
}

test "output: template array wraps after 75 columns like the Perl loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var values: [7][]const u8 = undefined;
    for (&values) |*v| v.* = "MVM_JIT_COPY";
    try writeTemplatesArray(&out.writer, &values);
    try std.testing.expectEqualStrings(
        "static const MVMint32 MVM_jit_expr_templates[] = {\n" ++
            "    MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,MVM_JIT_COPY,\n" ++
            "    MVM_JIT_COPY,MVM_JIT_COPY,\n};\n",
        out.written(),
    );
}
```
Also add these two stubs so the tests compile:
```zig
pub fn moarOperands(gpa: std.mem.Allocator, op: *const oplist.Op) !Env {
    _ = op;
    return Env.init(gpa);
}

fn writeTemplatesArray(w: *std.Io.Writer, templates: []const []const u8) !void {
    _ = w;
    _ = templates;
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `zig test tools/zig/expr_template_compiler.zig`
Expected: compiles; every test FAILS (stubs return `error.InvalidTemplate`, empty env, empty output).

- [ ] **Step 3: Implement `moarOperands`, `linkDeclarations`, `applyMacros`, `expandMacro`**

Replace the `moarOperands`, `linkDeclarations` and `applyMacros` stubs with:
```zig
/// Operand environment of an opcode: "$0", "$1", ... mapped to expression
/// types (num32/num64 -> num, `1 -> ?, anything else -> reg). inc_i/dec_i
/// and inc_u/dec_u list one operand but templates reference $0 and $1, so
/// their type list is doubled (the Perl tool's "hack").
pub fn moarOperands(gpa: std.mem.Allocator, op: *const oplist.Op) !Env {
    var env = Env.init(gpa);
    const n = op.operands.len;
    const doubled = isIncDec(op.name, "iu");
    const total = if (doubled) n * 2 else n;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const ty = op.operands[i % n].ty;
        const key = try std.fmt.allocPrint(gpa, "${d}", .{i});
        try env.put(key, .{ .ty = moar_types.get(ty) orelse "reg" });
    }
    return env;
}

/// `^(inc|dec)_[<suffixes>]$`
fn isIncDec(name: []const u8, suffixes: []const u8) bool {
    if (name.len != 5) return false;
    if (!(std.mem.startsWith(u8, name, "inc_") or std.mem.startsWith(u8, name, "dec_"))) return false;
    return std.mem.indexOfScalar(u8, suffixes, name[4]) != null;
}

/// Replaces `let:`/`letv:` statements by do/dov, binding each declared name to
/// its definition node so every use shares that node (identity is what the
/// compiler later uses for reuse). Perl passes %env by value, so a nested
/// scope sees outer names but cannot leak its own.
pub fn linkDeclarations(gpa: std.mem.Allocator, expr: *Node, env_in: *const Env) Error!void {
    if (!expr.isList() or expr.items.items.len == 0) return;
    const op = expr.head();
    if (std.mem.indexOf(u8, op, "let:") != null or std.mem.indexOf(u8, op, "letv:") != null) {
        if (expr.items.items.len < 2 or !expr.items.items[1].isList()) return error.MalformedStatement;
        var env = env_in.clone() catch return error.OutOfMemory;
        const declarations = expr.items.items[1];
        const expressions = expr.items.items[2..];
        var definitions: std.ArrayList(*Node) = .empty;
        for (declarations.items.items) |declaration| {
            if (!declaration.isList() or declaration.items.items.len != 2) return error.MalformedStatement;
            const name = declaration.items.items[0].atom;
            const definition = declaration.items.items[1];
            try linkDeclarations(gpa, definition, &env);
            _ = try checkType(try exprType(gpa, definition, &env), "?", op);
            try env.put(name, .{ .node = definition });
            const discard = try Node.newList(gpa);
            try discard.items.append(gpa, try Node.newAtom(gpa, "discard"));
            try discard.items.append(gpa, definition);
            try definitions.append(gpa, discard);
        }
        for (expressions) |e| try linkDeclarations(gpa, e, &env);
        var rebuilt: std.ArrayList(*Node) = .empty;
        try rebuilt.append(gpa, try Node.newAtom(gpa, if (eql(op, "letv:")) "dov" else "do"));
        try rebuilt.appendSlice(gpa, definitions.items);
        try rebuilt.appendSlice(gpa, expressions);
        expr.items = rebuilt;
        return;
    }
    for (expr.items.items[1..]) |*slot| {
        const operand = slot.*;
        if (operand.isList()) {
            if (operand.items.items.len > 0) try linkDeclarations(gpa, operand, env_in);
        } else if (dollarName(operand.atom)) |name| {
            if (looksLikeNumber(name)) continue;
            const entry = env_in.get(operand.atom) orelse return error.InvalidName;
            switch (entry) {
                .node => |n| slot.* = n,
                .ty => return error.InvalidName,
            }
        }
    }
}

/// Expands `^name` applications bottom-up. The expanded instance replaces the
/// application's contents in place, so the application node keeps its identity.
pub fn applyMacros(gpa: std.mem.Allocator, expr: *Node, macros: *const Macros) Error!void {
    if (!expr.isList() or expr.items.items.len == 0) return;
    for (expr.items.items[1..]) |operand| {
        if (operand.isList()) try applyMacros(gpa, operand, macros);
    }
    const op = expr.head();
    if (op.len == 0 or op[0] != '^') return;
    const macro = macros.get(op) orelse return error.UndefinedMacro;
    if (expr.items.items.len - 1 != macro.params.len) return error.MacroArity;
    var bind = std.StringHashMap(*Node).init(gpa);
    for (macro.params, expr.items.items[1..]) |param, arg| try bind.put(param, arg);
    var sub = std.AutoHashMap(*Node, *Node).init(gpa);
    const instance = try expandMacro(gpa, macro.body, &bind, &sub);
    expr.items = .empty;
    try expr.items.appendSlice(gpa, instance.items.items);
}

/// Copies a macro body with `,param` atoms replaced by their bindings. A
/// source sub-list is expanded once and that instance is reused wherever the
/// source appears, preserving the links made by linkDeclarations.
fn expandMacro(gpa: std.mem.Allocator, macro: *const Node, bind: *const std.StringHashMap(*Node), sub: *std.AutoHashMap(*Node, *Node)) Error!*Node {
    const result = try Node.newList(gpa);
    for (macro.items.items) |element| {
        if (element.isList()) {
            if (sub.get(element)) |instance| {
                try result.items.append(gpa, instance);
            } else {
                const instance = try expandMacro(gpa, element, bind, sub);
                try sub.put(element, instance);
                try result.items.append(gpa, instance);
            }
        } else if (element.atom.len > 0 and element.atom[0] == ',') {
            try result.items.append(gpa, bind.get(element.atom) orelse return error.UnmatchedSubstitution);
        } else {
            try result.items.append(gpa, element);
        }
    }
    return result;
}
```

- [ ] **Step 4: Implement `exprType` and `checkType`**

Replace the `exprType` stub:
```zig
/// Expression type: 'reg', 'num', 'flag', 'void', 'arglist', 'carg' or '?'
/// (polymorphic). A bare atom must be `$name` (looked up) or `\$name` (reg);
/// any other atom is not an expression (Perl dies with "Can't use string as
/// an ARRAY ref").
pub fn exprType(gpa: std.mem.Allocator, expr: *const Node, env: *const Env) Error![]const u8 {
    if (expr.kind == .atom) {
        var s = expr.atom;
        var is_ref = false;
        if (s.len > 0 and s[0] == '\\') {
            is_ref = true;
            s = s[1..];
        }
        if (s.len >= 2 and s[0] == '$' and allWordChars(s[1..])) {
            if (is_ref) return "reg";
            const entry = env.get(s) orelse return error.NotDeclared;
            return switch (entry) {
                .ty => |t| t,
                .node => error.NotDeclared,
            };
        }
        return error.ExpectedExpression;
    }
    if (expr.items.items.len == 0 or expr.items.items[0].isList()) return "reg";
    const op = expr.head();
    if ((op.len > 0 and op[0] == '&') or (op.len > 0 and op[op.len - 1] == ':')) return error.ExpectedOperator;
    const operands = expr.items.items[1..];
    if (std.mem.indexOf(u8, op, "if") != null) {
        if (operands.len < 3) return error.TypeMismatch;
        const flag = try exprType(gpa, operands[0], env);
        const left = try exprType(gpa, operands[1], env);
        const right = try exprType(gpa, operands[2], env);
        _ = try checkType(flag, "flag", op);
        return if (eql(left, "?")) checkType(right, left, op) else checkType(left, right, op);
    }
    if (eql(op, "do")) {
        if (operands.len == 0) return error.MalformedStatement;
        return exprType(gpa, operands[operands.len - 1], env);
    }
    if (eql(op, "copy")) {
        if (operands.len == 0) return error.MalformedStatement;
        return exprType(gpa, operands[0], env);
    }
    if (op.len > 1 and op[0] == '^' and isWordChar(op[1])) return "?";
    const ty = operator_types.get(op) orelse "reg";
    if (eql(ty, "?")) {
        if (operands.len == 0) return error.MalformedStatement;
        const subtype = try exprType(gpa, operands[0], env);
        for (operands[1..]) |o| _ = try checkType(try exprType(gpa, o, env), subtype, op);
        return subtype;
    }
    return ty;
}

/// Returns `got` when it satisfies `want`: equal, or `want` is '?' and `got`
/// contains "reg" or "num".
pub fn checkType(got: []const u8, want: []const u8, why: []const u8) Error![]const u8 {
    if (eql(got, want)) return got;
    if (eql(want, "?") and (std.mem.indexOf(u8, got, "reg") != null or std.mem.indexOf(u8, got, "num") != null)) return got;
    std.debug.print("{s}: Got {s} wanted {s}\n", .{ why, got, want });
    return error.TypeMismatch;
}
```

- [ ] **Step 5: Implement the compiler**

Replace the `compileTemplate` stub:
```zig
pub fn compileTemplate(ctx: Ctx, expr: *Node, opcode: []const u8, operands: *const Env) Error!Compiled {
    var c: Compiler = .{
        .ctx = ctx,
        .opcode = opcode,
        .operands = operands,
        .expr_index = std.AutoHashMap(*Node, u32).init(ctx.gpa),
    };
    const root = try compileExpression(&c, expr);
    return .{ .root = root, .template = c.tmpl.items, .desc = c.desc.items };
}

fn compileExpression(c: *Compiler, expr: *Node) Error!u32 {
    if (c.expr_index.get(expr)) |idx| return idx;
    if (!expr.isList() or expr.items.items.len == 0) return error.ExpectedExpression;
    const op = expr.head();
    if (op.len > 0 and op[0] == '&') return error.ExpectedExpression;
    const info = c.ctx.ops.get(op) orelse return error.UnknownOperator;
    const operands = expr.items.items[1..];
    const num_operands: usize = if (info.num_operands < 0) operands.len else @intCast(info.num_operands);
    const num_params: usize = @intCast(info.num_params);
    if (num_operands + num_params != operands.len) return error.OperandCount;

    var code: std.ArrayList(Code) = .empty;
    const gpa = c.ctx.gpa;

    // large constants are treated specially
    if (eql(op, "const_ptr") or eql(op, "const_large")) {
        if (operands.len == 0) return error.OperandCount;
        const const_op = try compileOperator(c, op, 0);
        try code.appendSlice(gpa, &const_op);
        try code.append(gpa, try compileConstant(c, operands[0]));
        // Perl pushes the size text as written (no MVM_JIT_ prefix for barewords).
        if (operands.len > 1) try code.append(gpa, .{
            .tag = '.',
            .value = if (operands[1].isList()) try cmacroText(c, operands[1]) else operands[1].atom,
        });
        return emit(c, code.items);
    }

    // match up types
    var types: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, operand_types.get(op) orelse "reg", ',');
    while (it.next()) |t| try types.append(gpa, t);
    if (types.items.len < num_operands) {
        if (types.items.len == 1) {
            const only = types.items[0];
            while (types.items.len < num_operands) try types.append(gpa, only);
        } else if (types.items.len == 2) {
            const first = types.items[0];
            const last = types.items[1];
            types.clearRetainingCapacity();
            var k: usize = 0;
            while (k + 1 < num_operands) : (k += 1) try types.append(gpa, first);
            try types.append(gpa, last);
        } else return error.CannotMatchTypes;
    }

    const op_code = try compileOperator(c, op, num_operands);
    try code.appendSlice(gpa, &op_code);
    var i: usize = 0;
    while (i < num_operands) : (i += 1) {
        _ = try checkType(try exprType(gpa, operands[i], c.operands), types.items[i], op);
        try code.append(gpa, try compileOperand(c, operands[i]));
    }
    if (op_size_param.get(op)) |param| {
        const size = operands[param - 1];
        const ok = (size.isList() and size.head().len > 0 and size.head()[0] == '&') or
            (size.kind == .atom and (looksLikeNumber(size.atom) or std.mem.endsWith(u8, size.atom, "_sz")));
        if (!ok) return error.ExpectedSizeParameter;
    }
    while (i < operands.len) : (i += 1) try code.append(gpa, try compileParameter(c, operands[i]));

    const node = try emit(c, code.items);
    try c.expr_index.put(expr, node);
    return node;
}

fn emit(c: *Compiler, code: []const Code) Error!u32 {
    const node: u32 = @intCast(c.tmpl.items.len);
    for (code) |item| {
        try c.desc.append(c.ctx.gpa, item.tag);
        try c.tmpl.append(c.ctx.gpa, item.value);
    }
    return node;
}

fn compileOperator(c: *Compiler, op: []const u8, num_operands: usize) Error![2]Code {
    if (c.ctx.ops.get(op) == null) return error.UnknownOperator;
    return .{
        .{ .tag = 'n', .value = try prefixed(c.ctx.gpa, op) },
        .{ .tag = 's', .value = try fmtInt(c.ctx.gpa, num_operands) },
    };
}

fn compileConstant(c: *Compiler, value: *Node) Error!Code {
    const text = if (value.isList()) try cmacroText(c, value) else value.atom;
    const gop = try c.ctx.constants.getOrPut(text);
    return .{ .tag = 'c', .value = try fmtInt(c.ctx.gpa, gop.index) };
}

fn compileOperand(c: *Compiler, expr: *Node) Error!Code {
    if (expr.isList()) return .{ .tag = 'l', .value = try fmtInt(c.ctx.gpa, try compileExpression(c, expr)) };
    return compileReference(c, expr.atom);
}

/// `$N` / `\$N` operand references. Write operands must be referenced with a
/// backslash, read operands must not. inc_i/dec_i may use $0 and $1 freely.
fn compileReference(c: *Compiler, atom: []const u8) Error!Code {
    var s = atom;
    var is_ref = false;
    if (s.len > 0 and s[0] == '\\') {
        is_ref = true;
        s = s[1..];
    }
    if (s.len < 2 or s[0] != '$') return error.ExpectedReference;
    var end: usize = 1;
    while (end < s.len and isWordChar(s[end])) end += 1;
    if (end == 1) return error.ExpectedReference;
    const name = s[1..end];
    if (!looksLikeNumber(name)) return error.UndefinedNamedReference;
    const idx = std.fmt.parseInt(i64, name, 10) catch return error.InvalidOperandReference;
    if (isIncDec(c.opcode, "i") and idx <= 1) return .{ .tag = 'i', .value = name };
    const op = c.ctx.ol.get(c.opcode) orelse return error.UnknownOpcode;
    if (idx < 0 or idx >= op.operands.len) return error.InvalidOperandReference;
    const dir = op.operands[@intCast(idx)].dir;
    if (eql(dir, "w")) {
        if (!is_ref) return error.RequireReference;
    } else if (is_ref) return error.NotAReference;
    return .{ .tag = 'i', .value = name };
}

fn compileParameter(c: *Compiler, expr: *Node) Error!Code {
    return .{ .tag = '.', .value = try parameterText(c, expr) };
}

fn parameterText(c: *Compiler, expr: *Node) Error![]const u8 {
    if (expr.isList()) return cmacroText(c, expr);
    if (looksLikeNumber(expr.atom)) return expr.atom;
    return prefixed(c.ctx.gpa, expr.atom);
}

/// `(&name p1 p2)` -> "name(p1, p2)"
fn cmacroText(c: *Compiler, expr: *Node) Error![]const u8 {
    const name = expr.head();
    if (name.len < 2 or name[0] != '&') return error.ExpectedMacroExpression;
    var end: usize = 1;
    while (end < name.len and isWordChar(name[end])) end += 1;
    var out: std.Io.Writer.Allocating = .init(c.ctx.gpa);
    out.writer.print("{s}(", .{name[1..end]}) catch return error.OutOfMemory;
    for (expr.items.items[1..], 0..) |p, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(if (p.isList()) "ARRAY" else p.atom) catch return error.OutOfMemory;
    }
    out.writer.writeByte(')') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}
```

- [ ] **Step 6: Implement file parsing and output**

Append:
```zig
/// Parses one .expr file (statements macro:, template:, include:). Macros and
/// the include set are shared across includes; templates and info are merged
/// into the including file with their indices shifted.
pub fn parseFile(ctx: Ctx, io: std.Io, text: []const u8, macros: *Macros, seen: *std.StringHashMap(void)) !ParsedFile {
    const gpa = ctx.gpa;
    var result: ParsedFile = .{ .info = std.StringHashMap(Info).init(gpa) };
    var parser = sexpr.Parser.init(gpa, text);
    while (try parser.next()) |tree| {
        if (tree.items.items.len == 0) return error.MalformedStatement;
        const keyword = tree.items.items[0].atom;
        const rest = tree.items.items[1..];
        if (eql(keyword, "macro:")) {
            if (rest.len != 3 or !rest[1].isList()) return error.MalformedStatement;
            const name = rest[0].atom;
            if (macros.contains(name)) return error.MacroRedeclared;
            const body = rest[2];
            var empty = Env.init(gpa);
            try linkDeclarations(gpa, body, &empty);
            try applyMacros(gpa, body, macros);
            const ty = try exprType(gpa, body, &empty);
            var params: std.ArrayList([]const u8) = .empty;
            for (rest[1].items.items) |p| try params.append(gpa, p.atom);
            try macros.put(name, .{ .params = params.items, .body = body, .ty = ty });
        } else if (eql(keyword, "template:")) {
            if (rest.len != 2) return error.MalformedStatement;
            var opcode = rest[0].atom;
            const template = rest[1];
            var destructive: u8 = 0;
            if (std.mem.endsWith(u8, opcode, "!")) {
                destructive = 1;
                opcode = opcode[0 .. opcode.len - 1];
            }
            const op = ctx.ol.get(opcode) orelse {
                std.debug.print("Opcode '{s}' unknown\n", .{opcode});
                return error.UnknownOpcode;
            };
            if (result.info.contains(opcode)) return error.OpcodeRedefined;
            const output = op.outputOperand();
            if (destructive == 1 and output == null) return error.NoWriteOperand;
            var operands = try moarOperands(gpa, op);
            try linkDeclarations(gpa, template, &operands);
            try applyMacros(gpa, template, macros);
            const expr_ty = try exprType(gpa, template, &operands);
            const output_type: []const u8 = if (destructive == 1 or output == null) "void" else (moar_types.get(output.?) orelse "reg");
            _ = try checkType(expr_ty, output_type, opcode);
            const compiled = try compileTemplate(ctx, template, opcode, &operands);
            try result.info.put(opcode, .{
                .idx = result.templates.items.len,
                .desc = compiled.desc,
                .root = compiled.root,
                .len = compiled.desc.len,
                .flags = destructive,
            });
            try result.templates.appendSlice(gpa, compiled.template);
        } else if (eql(keyword, "include:")) {
            if (rest.len != 1) return error.MalformedStatement;
            const file = std.mem.trim(u8, rest[0].atom, "\"");
            if (seen.contains(file)) {
                std.debug.print("{s} already included\n", .{file});
                continue;
            }
            try seen.put(file, {});
            const inc_text = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited) catch |err| {
                std.debug.print("cannot read include '{s}': {t}\n", .{ file, err });
                return err;
            };
            var inc = try parseFile(ctx, io, inc_text, macros, seen);
            var it = inc.info.iterator();
            while (it.next()) |entry| {
                if (result.info.contains(entry.key_ptr.*)) return error.TemplateRedeclaredInInclude;
                var info = entry.value_ptr.*;
                info.idx += result.templates.items.len;
                try result.info.put(entry.key_ptr.*, info);
            }
            try result.templates.appendSlice(gpa, inc.templates.items);
        } else {
            std.debug.print("I don't know what to do with '{s}'\n", .{keyword});
            return error.UnknownKeyword;
        }
    }
    return result;
}

fn writeTemplatesArray(w: *std.Io.Writer, templates: []const []const u8) !void {
    try w.writeAll("static const MVMint32 MVM_jit_expr_templates[] = {\n    ");
    var i: usize = 0;
    for (templates) |t| {
        i += t.len + 2;
        if (i > 75) {
            try w.writeAll("\n    ");
            i = t.len + 2;
        }
        try w.print("{s},", .{t});
    }
    try w.writeAll("\n};\n");
}

pub fn writeOutput(w: *std.Io.Writer, parsed: *const ParsedFile, ol: *const oplist.Oplist, constants: *const Constants) !void {
    try w.writeAll("/* FILE AUTOGENERATED BY tools/zig/expr_template_compiler.zig. DO NOT EDIT.\n * Defines tables for expression templates. */\n");
    try writeTemplatesArray(w, parsed.templates.items);
    try w.writeAll("static const MVMJitExprTemplate MVM_jit_expr_template_info[] = {\n");
    for (ol.ops) |op| {
        if (parsed.info.get(op.name)) |td| {
            try w.print("    {{ MVM_jit_expr_templates + {d}, \"{s}\", {d}, {d}, {d} }},\n", .{ td.idx, td.desc, td.len, td.root, td.flags });
        } else {
            try w.writeAll("    { NULL, NULL, -1, 0, 0 },\n");
        }
    }
    try w.writeAll("};\n");
    try w.writeAll("static const void* MVM_jit_expr_template_constants[] = {\n");
    for (constants.keys()) |k| try w.print("    {s},\n", .{k});
    try w.writeAll("};\n");
    try w.print(
        \\static const MVMJitExprTemplate * MVM_jit_get_template_for_opcode(MVMuint16 opcode) {{
        \\    if (opcode >= {d}) return NULL;
        \\    if (MVM_jit_expr_template_info[opcode].len < 0) return NULL;
        \\    return &MVM_jit_expr_template_info[opcode];
        \\}}
        \\
    , .{ol.ops.len});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var oplist_path: ?[]const u8 = null;
    var expr_ops_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--oplist")) {
            i += 1;
            oplist_path = args[i];
        } else if (eql(a, "--expr-ops")) {
            i += 1;
            expr_ops_path = args[i];
        } else if (eql(a, "-o") or eql(a, "--output")) {
            i += 1;
            output_path = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown option {s}\n", .{a});
            std.process.exit(2);
        } else input_path = a;
    }
    const usage = "usage: expr_template_compiler --oplist src/core/oplist --expr-ops src/jit/expr_ops.h -o out.h input.expr (run from the repository root)\n";
    const in_path = input_path orelse {
        std.debug.print(usage, .{});
        std.process.exit(2);
    };
    const cwd = std.Io.Dir.cwd();
    const ol = try arena.create(oplist.Oplist);
    ol.* = try oplist.parse(arena, try cwd.readFileAlloc(io, oplist_path orelse "src/core/oplist", arena, .unlimited));
    const eo = try arena.create(expr_ops.ExprOps);
    eo.* = try expr_ops.parse(arena, try cwd.readFileAlloc(io, expr_ops_path orelse "src/jit/expr_ops.h", arena, .unlimited));
    var constants = Constants.init(arena);
    const ctx: Ctx = .{ .gpa = arena, .ops = eo, .ol = ol, .constants = &constants };
    var macros = Macros.init(arena);
    var seen = std.StringHashMap(void).init(arena);
    const text = try cwd.readFileAlloc(io, in_path, arena, .unlimited);
    const parsed = parseFile(ctx, io, text, &macros, &seen) catch |err| {
        std.debug.print("expr_template_compiler: {s}: {t}\n", .{ in_path, err });
        std.process.exit(1);
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeOutput(&out.writer, &parsed, ol, &constants);
    if (output_path) |p| {
        try cwd.writeFile(io, .{ .sub_path = p, .data = out.written() });
    } else {
        var buf: [4096]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), io, &buf);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
    }
}
```

- [ ] **Step 7: Run the unit tests**

Run: `zig test tools/zig/expr_template_compiler.zig`
Expected: `All 9 tests passed.` The expected `desc`/`template` values in the tests were derived by hand from the Perl rules; if one differs, re-derive it from the Perl source before changing the test, and record the reasoning in the report.

- [ ] **Step 8: Run against the real inputs and diff against Perl**

```bash
zig build-exe tools/zig/expr_template_compiler.zig -femit-bin=$SCRATCH/etc -OReleaseSafe && \
$SCRATCH/etc --oplist src/core/oplist --expr-ops src/jit/expr_ops.h -o $SCRATCH/ct.zig.h src/jit/core_templates.expr && \
perl -Itools/ tools/expr-template-compiler.pl -o $SCRATCH/ct.perl.h src/jit/core_templates.expr && \
diff <(tail -n +2 $SCRATCH/ct.perl.h) <(tail -n +2 $SCRATCH/ct.zig.h) && echo "core_templates.h IDENTICAL from line 2"
```
Expected: `core_templates.h IDENTICAL from line 2`. On a difference: `diff` output points at the first divergent line; find the construct in `core_templates.expr` that produced it (template rows carry the opcode order, so count rows), and compare the Zig function with the Perl one for that construct. Do not patch the output; fix the port.

Notes recorded during execution (the committed file reflects these): zig 0.16 has no managed `std.StringArrayHashMap`, so `Constants` is `std.StringArrayHashMapUnmanaged(void)` with `.empty` and `getOrPut(gpa, key)`; `expr_ops.parse` reads one entry per line, so test fixtures must list one `_(...)` per line; a `let:` declaration may carry extra elements after the definition (the real input has `($bibody (...) ptr_sz)`), which Perl ignores, so the check is `declaration.items.items.len < 2`; the second compile test's desc is `nsnsl.nsl.nsli.nsl.` because `idx`'s third item is a parameter.

- [ ] **Step 9: Commit**

```bash
git add tools/zig/expr_template_compiler.zig
git commit -m "tools/zig: port expr-template-compiler.pl to Zig

Output is identical to the Perl tool from line 2 onward on
src/jit/core_templates.expr.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Port `tiler-table-generator.pl` to Zig, with a canonicalizer for the equivalence check

**Files:**
- Create: `tools/zig/tiler_table_generator.zig`
- Create: `tools/canonicalize-tile-table.pl`

**Interfaces:**
- Consumes: `sexpr`, `expr_ops` from Tasks 2-3.
- Produces: a host executable `tiler_table_generator --expr-ops <src/jit/expr_ops.h> [--debug] -o <out.h> <input.tile>`. `--debug` prints the `Rules:`/`Rulesets:` listing to stdout exactly like the Perl tool. Rulesets are numbered canonically: sorted lexicographically by their ascending rule-number lists (shorter prefix first). Output line 1 reads `/* FILE AUTOGENERATED BY tools/zig/tiler_table_generator.zig. DO NOT EDIT. */`.
- Produces: `perl tools/canonicalize-tile-table.pl <perl --debug stdout> <perl tile_pattern.h>` prints the Perl output renumbered into the same canonical order on stdout, so `tail -n +2` of both files must be identical.
- Internal API used by the unit tests: `generate(gpa, tile_text, eo: *const expr_ops.ExprOps, debug: ?*std.Io.Writer, out: *std.Io.Writer) !void`.

The Perl source `tools/tiler-table-generator.pl` is the reference; read it alongside this task. The algorithm is: `add_rule`/`decompose` turn each `(tile: name pattern symbol cost)` or `(define: pattern symbol)` into a chain of rules (sub-patterns become pseudo-symbols `#N`, cost halves per nesting level); `combine_rules` computes the closed set of symbol combinations (rulesets); `generate_table` maps (head, ruleset, ruleset) to a ruleset; `compute_costs` picks the cheapest rule per (ruleset, symbol); then four tables are printed.

- [ ] **Step 1: Write the module skeleton with failing tests**

Create `tools/zig/tiler_table_generator.zig`:
```zig
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

pub fn generate(gpa: std.mem.Allocator, tile_text: []const u8, eo: *const expr_ops.ExprOps, debug: ?*std.Io.Writer, out: *std.Io.Writer) !void {
    _ = gpa;
    _ = tile_text;
    _ = eo;
    _ = debug;
    _ = out;
    return error.MalformedStatement;
}

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
    try std.testing.expect(std.mem.indexOf(u8, r.out,
        "/* Tile function declarations */\n" ++
            "MVM_JIT_TILE_DECL(a);\nMVM_JIT_TILE_DECL(c);\nMVM_JIT_TILE_DECL(d);\nMVM_JIT_TILE_DECL(e);\n" ++
            "MVM_JIT_TILE_DECL(g);\nMVM_JIT_TILE_DECL(h);\nMVM_JIT_TILE_DECL(i);\n" ++
            "/* Tile template declarations */\n" ++
            "static const MVMJitTileTemplate MVM_jit_tile_templates[] = {\n" ++
            "  { MVM_JIT_TILE_NAME(a), \"\",\n   \"(stack)\", -1, -1, 0, 0,\n    { MVM_JIT_STORAGE_GPR } },\n" ++
            "  { MVM_JIT_TILE_NAME(c), \"1.2.\",\n   \"(addr reg $ofs)\", 0, -1, 1, 1,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n") != null);
    // rule 4 (g): two operand symbols, refs bitmap 3, nval 2, three storage specs
    try std.testing.expect(std.mem.indexOf(u8, r.out,
        "  { MVM_JIT_TILE_NAME(g), \"1.2.\",\n   \"(add reg reg)\", 0, 0, 2, 3,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n" ++
            "  { NULL, NULL,\n   NULL, -1, -1, 0, 0,\n    { 0 } },\n" ++
            "  { MVM_JIT_TILE_NAME(h), \"1.21.\",\n   \"(add reg (const $val))\", 0, 1, 1, 1,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n" ++
            "  { NULL, NULL,\n   NULL, 0, -1, 0, 0,\n    { 0 } },\n" ++
            "  { MVM_JIT_TILE_NAME(i), \"1.21.22.\",\n   \"(add reg (load reg $size))\", 0, 2, 2, 3,\n    { MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR, MVM_JIT_STORAGE_GPR } },\n};\n") != null);
}

test "select and state tables match the canonicalised Perl output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try runTest(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, r.out,
        "/* Tiler tables */\n" ++
            "static const MVMint32 MVM_jit_tile_select[][3] = {\n" ++
            "  { 0, 0, 0 },\n  { 1, 0, 1 },\n  { 2, 0, 2 },\n  { 2, 1, 5 },\n  { 3, 0, 3 },\n" ++
            "  { 3, 2, 7 },\n  { 4, 0, 4 },\n  { 5, 0, 6 },\n  { 6, 0, 8 },\n};\n") != null);
    try std.testing.expectEqual(@as(usize, 65), countLines(r.out, "  { MVM_JIT_"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "static MVMint32 MVM_jit_tile_state[][6] = {\n  { MVM_JIT_LOAD, 0, -1, 3, 3 },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  { MVM_JIT_ADD, 0, 2, 5, 6 },\n  { MVM_JIT_ADD, 0, 3, 6, 8 },\n") != null);
    // Perl's `$best ||= ...` treats rule 0 as "no rule", so the (stack) state prints -1.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  { MVM_JIT_STACK, -1, -1, 0, -1 },\n};\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "/* FILE AUTOGENERATED BY tools/zig/tiler_table_generator.zig. DO NOT EDIT. */\n"));
    try std.testing.expect(std.mem.endsWith(u8, r.out, "    return MVM_jit_tile_select[mid][2];\n}\n\n"));
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `zig test tools/zig/tiler_table_generator.zig`
Expected: compiles; all three tests FAIL with `error.MalformedStatement`.

- [ ] **Step 3: Implement rule decomposition**

Replace the `generate` stub and add the pieces below. First the rule builder:
```zig
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
            // (define: pattern symbol)
            if (rest.len != 2 or !rest[0].isList()) return error.MalformedStatement;
            try addRule(g, null, rest[0], rest[1].atom, 0);
        }
        // other keywords are ignored, as in the Perl tool
    }
}
```
Add `WriteFailed` handling by writing all `std.Io.Writer` calls as `catch return error.WriteFailed` where the function returns `Error`; the `appendPath` writer above may instead be declared `!void` as shown.

- [ ] **Step 4: Implement `combineRules` with canonical ordering**

```zig
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
```

- [ ] **Step 5: Implement the table and the cost fixpoint**

```zig
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
```

- [ ] **Step 6: Implement `generate` (parsing, debug listing, output) and `main`**

```zig
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
```
`lookup_routines` is the Perl `LOOKUP` heredoc with `${VARNAME}` replaced by `MVM_jit_tile_`, followed by one extra newline (Perl's `$\`). Copy it from `tools/tiler-table-generator.pl` lines "print <<"LOOKUP";" to "LOOKUP" verbatim into a Zig multiline string constant:
```zig
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
```
(Verify the text against the Perl script with a diff of the generated file in Step 8; the Perl output ends with `}` newline and one more newline.)

Then `main`:
```zig
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
```

- [ ] **Step 7: Run the unit tests**

Run: `zig test tools/zig/tiler_table_generator.zig`
Expected: `All 3 tests passed.` The expected strings come from a canonicalised run of the Perl tool on the same grammar; if a test fails, compare against `perl -Itools/ tools/tiler-table-generator.pl --testing --debug -o $SCRATCH/t.h` canonicalised with the script from Step 8 before changing any expectation.

- [ ] **Step 8: Write `tools/canonicalize-tile-table.pl`**

```perl
#!/usr/bin/env perl
# Renumber the rulesets of a tools/tiler-table-generator.pl output into the
# canonical order used by tools/zig/tiler_table_generator.zig, so the two can
# be compared byte for byte. The Perl generator numbers rulesets in hash
# order, which changes from run to run; the canonical order sorts rulesets
# by their ascending rule-number lists.
#
# usage: perl tools/canonicalize-tile-table.pl <debug-output> <tile_pattern.h> > canonical.h
# where <debug-output> is the stdout of `tiler-table-generator.pl --debug`
# (it lists each ruleset's rules) and <tile_pattern.h> is the file it wrote.
use strict;
use warnings;

my ($debug_file, $header_file) = @ARGV;
die "usage: canonicalize-tile-table.pl <debug-output> <tile_pattern.h>\n" unless defined $header_file;

# ruleset number -> sorted rule numbers, from the "Rulesets:" listing
open my $dfh, '<', $debug_file or die "cannot open $debug_file: $!";
my (%rulesets, $in_rulesets);
while (my $line = <$dfh>) {
    if ($line =~ /^Rulesets:/) { $in_rulesets = 1; next }
    next unless $in_rulesets;
    next unless $line =~ /^(\d+) => (.*)$/;
    my ($nr, $list) = ($1, $2);
    $rulesets{$nr} = [ sort { $a <=> $b } grep { length } map { s/^\s+|\s+$//gr } split /,/, $list ];
}
close $dfh;

sub cmp_lists {
    my ($x, $y) = @_;
    for (my $i = 0; $i < @$x && $i < @$y; $i++) {
        my $c = $x->[$i] <=> $y->[$i];
        return $c if $c;
    }
    return @$x <=> @$y;
}
my @order = sort { cmp_lists($rulesets{$a}, $rulesets{$b}) } keys %rulesets;
my %newnum;
$newnum{ $order[$_] } = $_ for 0 .. $#order;

open my $hfh, '<', $header_file or die "cannot open $header_file: $!";
my @lines = <$hfh>;
chomp @lines;
close $hfh;

my @out;
my $i = 0;
while ($i < @lines) {
    my $line = $lines[$i];
    if ($line eq 'static const MVMint32 MVM_jit_tile_select[][3] = {') {
        push @out, $line;
        $i++;
        my @rows;
        while ($lines[$i] ne '};') {
            my ($rs, $sym, $rule) = $lines[$i] =~ /^  \{ (\d+), (\d+), (\d+) \},$/
                or die "bad select row: $lines[$i]";
            push @rows, [ $newnum{$rs}, $sym, $rule ];
            $i++;
        }
        push @out, map { sprintf('  { %d, %d, %d },', @$_) }
            sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @rows;
        push @out, $lines[$i++];
        next;
    }
    if ($line eq 'static MVMint32 MVM_jit_tile_state[][6] = {') {
        push @out, $line;
        $i++;
        my (@group, $head);
        my $flush = sub {
            push @out, map { sprintf('  { %s, %d, %d, %d, %d },', @$_) }
                sort { $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @group;
            @group = ();
        };
        while ($lines[$i] ne '};') {
            my ($h, $rs1, $rs2, $state, $best) =
                $lines[$i] =~ /^  \{ (MVM_JIT_\w+), (-?\d+), (-?\d+), (\d+), (-?\d+) \},$/
                or die "bad state row: $lines[$i]";
            if (!defined $head || $h ne $head) {
                $flush->() if @group;
                $head = $h;
            }
            push @group, [ $h, ($rs1 == -1 ? -1 : $newnum{$rs1}), ($rs2 == -1 ? -1 : $newnum{$rs2}), $newnum{$state}, $best ];
            $i++;
        }
        $flush->() if @group;
        push @out, $lines[$i++];
        next;
    }
    push @out, $line;
    $i++;
}
print "$_\n" for @out;
```

- [ ] **Step 9: Prove the canonicalizer removes Perl's run-to-run differences, then compare with the Zig tool**

```bash
perl -c tools/canonicalize-tile-table.pl
for n in 1 2 3; do
  perl -Itools/ tools/tiler-table-generator.pl --debug -o $SCRATCH/tp$n.h src/jit/x64/tile_pattern.tile > $SCRATCH/tp$n.debug
  perl tools/canonicalize-tile-table.pl $SCRATCH/tp$n.debug $SCRATCH/tp$n.h > $SCRATCH/tp$n.canon.h
done
cmp $SCRATCH/tp1.h $SCRATCH/tp2.h || echo "raw Perl outputs differ (expected)"
cmp $SCRATCH/tp1.canon.h $SCRATCH/tp2.canon.h && cmp $SCRATCH/tp2.canon.h $SCRATCH/tp3.canon.h && echo "canonical Perl outputs IDENTICAL"
zig build-exe tools/zig/tiler_table_generator.zig -femit-bin=$SCRATCH/ttg -OReleaseSafe
$SCRATCH/ttg --expr-ops src/jit/expr_ops.h -o $SCRATCH/tp.zig.h src/jit/x64/tile_pattern.tile
diff <(tail -n +2 $SCRATCH/tp1.canon.h) <(tail -n +2 $SCRATCH/tp.zig.h) && echo "tile_pattern.h IDENTICAL from line 2"
wc -l $SCRATCH/tp.zig.h
```
Expected: `canonical Perl outputs IDENTICAL`, `tile_pattern.h IDENTICAL from line 2`, and 30128 lines (the Perl output's size). If the `select`/`state` rows differ while the templates table matches, the fixpoint or the `best` quirk differs; if the templates table differs, `decompose`/`registerSpec`/`encode` differ.

Notes recorded during execution (the committed file reflects these): `(define: pattern symbol cost)` with a third item occurs three times in the real tile file (for example `(define: (carg reg) c_arg 1)`); Perl's `add_rule(undef, @$tree, 0)` takes that third item as the cost, so `parseGrammar` accepts 2 or 3 items for `define:` and uses the third as the cost when present. The `"  { MVM_JIT_"` line-prefix count in the third test is 72, not 65: the 7 `MVM_JIT_TILE_NAME` template rows share the prefix with the 65 state rows.

- [ ] **Step 10: Commit**

```bash
git add tools/zig/tiler_table_generator.zig tools/canonicalize-tile-table.pl
git commit -m "tools/zig: port tiler-table-generator.pl to Zig with canonical ruleset order

The Perl tool numbers rulesets in hash order, so its output differs from
run to run. The Zig port sorts rulesets by their rule lists;
tools/canonicalize-tile-table.pl renumbers a Perl output the same way so
the two can be diffed.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Wire the JIT into the zig build

**Files:**
- Modify: `build/zig/jit.zig` (add `Tools`, `Generated`, `addTools`, `addGenerated`, `addAll`, `addCheckStep`)
- Modify: `build/zig/options.zig` (`-Djit` default true on x86_64; drop the phase-1 fatal)
- Modify: `build/zig/moar.zig` (`LibInputs.jit`, JIT sources, generated include dir first)
- Modify: `build.zig` (wiring, `check-jit-tools`, JIT functional test, unit-test step covers the tools)
- Create: `tools/check-jit-tools.sh`

**Interfaces:**
- Consumes: `jit.Dynasm`/`jit.addDynasm` (Task 1), the two tool sources (Tasks 4-5), `sources.Lists.jit`, `.jit_x64`, `.jit_stub`, `thirdparty.newCModule`, `moar.cflags`.
- Produces: `jit.Jit { dynasm: Dynasm, tools: Tools, gen: Generated }` with `Generated { core_templates_h, tile_pattern_h, include_dir: LazyPath }`, `jit.addAll(b) Jit`, `jit.addCheckStep(b, j: Jit) *std.Build.Step`; `moar.LibInputs` gains `jit: ?jit.Jit`.

- [ ] **Step 1: Add the tool executables, run steps and generated include directory to `build/zig/jit.zig`**

Append:
```zig
pub const Tools = struct {
    expr_compiler: *std.Build.Step.Compile,
    tiler: *std.Build.Step.Compile,
};

pub const Generated = struct {
    core_templates_h: std.Build.LazyPath,
    tile_pattern_h: std.Build.LazyPath,
    /// Directory laid out as jit/core_templates.h and jit/x64/tile_pattern.h,
    /// to be added to the include path before `src`.
    include_dir: std.Build.LazyPath,
};

pub const Jit = struct {
    dynasm: Dynasm,
    tools: Tools,
    gen: Generated,
};

fn hostTool(b: *std.Build, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

pub fn addTools(b: *std.Build) Tools {
    return .{
        .expr_compiler = hostTool(b, "expr_template_compiler", "tools/zig/expr_template_compiler.zig"),
        .tiler = hostTool(b, "tiler_table_generator", "tools/zig/tiler_table_generator.zig"),
    };
}

/// Runs both generators from the repository root (the .expr `include:` paths
/// are cwd-relative) and collects their outputs into one include directory.
pub fn addGenerated(b: *std.Build, tools: Tools) Generated {
    const ec = b.addRunArtifact(tools.expr_compiler);
    ec.setCwd(b.path("."));
    ec.addArg("--oplist");
    ec.addFileArg(b.path("src/core/oplist"));
    ec.addArg("--expr-ops");
    ec.addFileArg(b.path("src/jit/expr_ops.h"));
    ec.addArg("-o");
    const core_templates_h = ec.addOutputFileArg("core_templates.h");
    ec.addFileArg(b.path("src/jit/core_templates.expr"));
    ec.addFileInput(b.path("src/jit/macro.expr"));

    const tt = b.addRunArtifact(tools.tiler);
    tt.setCwd(b.path("."));
    tt.addArg("--expr-ops");
    tt.addFileArg(b.path("src/jit/expr_ops.h"));
    tt.addArg("-o");
    const tile_pattern_h = tt.addOutputFileArg("tile_pattern.h");
    tt.addFileArg(b.path("src/jit/x64/tile_pattern.tile"));

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(core_templates_h, "jit/core_templates.h");
    _ = wf.addCopyFile(tile_pattern_h, "jit/x64/tile_pattern.h");

    return .{ .core_templates_h = core_templates_h, .tile_pattern_h = tile_pattern_h, .include_dir = wf.getDirectory() };
}

pub fn addAll(b: *std.Build) Jit {
    const tools = addTools(b);
    return .{ .dynasm = addDynasm(b), .tools = tools, .gen = addGenerated(b, tools) };
}

/// `zig build check-jit-tools`: runs the Perl generators and compares them
/// with the zig outputs (see tools/check-jit-tools.sh). Needs perl and sh.
pub fn addCheckStep(b: *std.Build, j: Jit) *std.Build.Step {
    const run = b.addSystemCommand(&.{ "sh", "tools/check-jit-tools.sh" });
    run.setCwd(b.path("."));
    run.addFileArg(j.gen.core_templates_h);
    run.addFileArg(j.gen.tile_pattern_h);
    run.addFileArg(j.dynasm.emit_c);
    run.has_side_effects = true;
    const step = b.step("check-jit-tools", "Compare the zig JIT generators with the Perl originals (needs perl)");
    step.dependOn(&run.step);
    return step;
}
```

- [ ] **Step 2: Write `tools/check-jit-tools.sh`**

```sh
#!/bin/sh
# Compare the zig build's JIT code generators with the Perl originals.
#   sh tools/check-jit-tools.sh <zig core_templates.h> <zig tile_pattern.h> <zig emit.c>
# Run from the repository root (zig build check-jit-tools does this).
#  - core_templates.h: identical from line 2 (line 1 names the generator)
#  - tile_pattern.h:   identical from line 2 after canonical ruleset renumbering
#                      of the Perl output (its numbering follows Perl hash order)
#  - emit.c:           identical to the Perl build's src/jit/x64/emit.c when present
set -eu
zig_ct=$1
zig_tp=$2
zig_emit=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

perl -Itools/ tools/expr-template-compiler.pl -o "$tmp/ct.h" src/jit/core_templates.expr
tail -n +2 "$tmp/ct.h" > "$tmp/ct.perl.body"
tail -n +2 "$zig_ct" > "$tmp/ct.zig.body"
if ! cmp -s "$tmp/ct.perl.body" "$tmp/ct.zig.body"; then
    echo "check-jit-tools: core_templates.h differs from the Perl output:" >&2
    diff "$tmp/ct.perl.body" "$tmp/ct.zig.body" | head -20 >&2
    exit 1
fi

perl -Itools/ tools/tiler-table-generator.pl --debug -o "$tmp/tp.h" src/jit/x64/tile_pattern.tile > "$tmp/tp.debug"
perl tools/canonicalize-tile-table.pl "$tmp/tp.debug" "$tmp/tp.h" > "$tmp/tp.canon.h"
tail -n +2 "$tmp/tp.canon.h" > "$tmp/tp.perl.body"
tail -n +2 "$zig_tp" > "$tmp/tp.zig.body"
if ! cmp -s "$tmp/tp.perl.body" "$tmp/tp.zig.body"; then
    echo "check-jit-tools: tile_pattern.h differs from the canonicalised Perl output:" >&2
    diff "$tmp/tp.perl.body" "$tmp/tp.zig.body" | head -20 >&2
    exit 1
fi

if [ -f src/jit/x64/emit.c ]; then
    if ! cmp -s src/jit/x64/emit.c "$zig_emit"; then
        echo "check-jit-tools: emit.c differs from src/jit/x64/emit.c" >&2
        exit 1
    fi
    echo "check-jit-tools: emit.c identical to the Perl build's"
else
    echo "check-jit-tools: src/jit/x64/emit.c not present, emit.c not compared"
fi
echo "check-jit-tools: core_templates.h and tile_pattern.h match the Perl generators"
```
Then `chmod +x tools/check-jit-tools.sh`.

- [ ] **Step 3: Make `-Djit` default to true in `build/zig/options.zig`**

Replace the `jit` option block (the `b.option(bool, "jit", ...)` and the `if (jit) std.process.fatal(...)` lines) with:
```zig
    const x86_64 = target.result.cpu.arch == .x86_64;
    const jit = b.option(bool, "jit", "Build the x86-64 JIT compiler (default: true on x86_64)") orelse x86_64;
    if (jit and !x86_64) std.process.fatal(
        "the JIT is only available on x86_64 (target is {s}); build with -Djit=false",
        .{@tagName(target.result.cpu.arch)},
    );
```

- [ ] **Step 4: Add the JIT sources to `libmoar` in `build/zig/moar.zig`**

Add `const jit = @import("jit.zig");` to the imports. In `LibInputs` add the field `jit: ?jit.Jit,` after `tp`. In `addLibmoar`, before the existing `addIncludes(b, mod);` call insert:
```zig
    // Generated JIT headers must come before `src`, where the Perl build
    // leaves its own copies (gitignored), so "jit/core_templates.h" and
    // "jit/x64/tile_pattern.h" resolve to ours.
    if (in.jit) |j| mod.addIncludePath(j.gen.include_dir);
```
Replace the line `mod.addCSourceFiles(.{ .files = in.lists.jit_stub, .flags = flags });` with:
```zig
    if (in.jit) |j| {
        mod.addCSourceFiles(.{ .files = in.lists.jit, .flags = flags });
        // [jit-x64] lists the generated src/jit/x64/emit.c for the Makefile's
        // benefit; the zig build compiles the one DynASM just produced.
        for (in.lists.jit_x64) |f| {
            if (std.mem.eql(u8, f, "src/jit/x64/emit.c")) continue;
            mod.addCSourceFile(.{ .file = b.path(f), .flags = flags });
        }
        mod.addCSourceFile(.{ .file = j.dynasm.emit_c, .flags = flags });
    } else {
        mod.addCSourceFiles(.{ .files = in.lists.jit_stub, .flags = flags });
    }
```

- [ ] **Step 5: Wire `build.zig`**

Replace the Task 1 `dynasm`/`emit-c` block with:
```zig
    const jit_build: ?jit.Jit = if (opts.jit) jit.addAll(b) else null;
    if (jit_build) |j| {
        _ = jit.addCheckStep(b, j);
        const emit_c_step = b.step("emit-c", "Copy the DynASM-generated emit.c to zig-out/emit.c for inspection");
        emit_c_step.dependOn(&b.addInstallFileWithDir(j.dynasm.emit_c, .prefix, "emit.c").step);
    }
```
Pass `.jit = jit_build,` in the `moar.addLibmoar` call. Extend the `test` step: after the existing stage0 smoke run, when `jit_build != null`, add a run that forces specialization and both JITs on a hot loop:
```zig
        if (jit_build != null) {
            const hot = std.Build.Step.Run.create(b, "run installed moar with forced JIT");
            hot.step.dependOn(b.getInstallStep());
            hot.addFileArg(installed_moar);
            hot.addFileInput(installed_libmoar);
            hot.addArg(b.fmt("--libpath={s}", .{stage0}));
            hot.addArg(b.pathJoin(&.{ stage0, "nqp.moarvm" }));
            hot.addArgs(&.{ "-e", "my int $i := 0; my int $n := 0; while $i < 200000 { $n := $n + $i; $i := $i + 1 }; say($n)" });
            hot.setEnvironmentVariable("MVM_SPESH_NODELAY", "1");
            hot.setEnvironmentVariable("MVM_SPESH_BLOCKING", "1");
            hot.setEnvironmentVariable("MVM_JIT_EXPR_ENABLE", "1");
            hot.expectStdOutEqual("19999900000\n");
            hot.setCwd(b.path("."));
            test_step.dependOn(&hot.step);
        }
```
(This goes inside the existing `if (b.build_root.handle.access(..., stage0, ...))` block so it only runs when nqp's stage0 is available.) Also change the `--version` expectation: with the JIT on, `moar --version` prints ` built with JIT support`:
```zig
    version_run.expectStdOutEqual(b.fmt("This is MoarVM version {s}{s}\n", .{ ver.full, if (opts.jit) " built with JIT support" else "" }));
```
Finally add the three tool files to the `unit-test` step's list of test roots (`tools/zig/sexpr.zig`, `tools/zig/oplist.zig`, `tools/zig/expr_ops.zig`, `tools/zig/expr_template_compiler.zig`, `tools/zig/tiler_table_generator.zig`), built for the host target like the existing ones.

- [ ] **Step 6: Build with the JIT and run everything**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig build test --summary all 2>&1 | tail -6
zig-out/bin/moar --version
zig build check-jit-tools 2>&1 | tail -4
```
Expected: all steps succeed including `run installed moar with forced JIT` and `unit-test`; the version line ends with `built with JIT support`; `check-jit-tools` prints the two "match"/"identical" lines. If `emit.c` fails to compile, check that `-isystem 3rdparty/dynasm` is still on the include path (it is in `addIncludes`) and that `jit/internal.h` resolves via `-Isrc`. If `moar --version` prints `2025.08`, the system library was loaded (see the phase-1 RUNPATH notes).

- [ ] **Step 7: Confirm the stub path still works and the generated headers win over stale Perl copies**

```bash
zig build -Djit=false test --summary all 2>&1 | tail -3 && zig-out/bin/moar --version
zig build 2>&1 | tail -1 && zig-out/bin/moar --version
ls src/jit/core_templates.h src/jit/x64/tile_pattern.h 2>/dev/null && zig build --verbose-cc 2>&1 | grep -m1 -o '\-I[^ ]*jit/core_templates[^ ]*\|-I[^ ]*/o/[0-9a-f]*' | head -2
```
Expected: the `-Djit=false` build passes and its version line has no JIT suffix; the default build is restored with the JIT; when the Perl-generated headers exist in `src/jit/`, the first `-I` in the compile command is the zig cache directory holding the generated headers (it precedes `-Isrc`).

- [ ] **Step 8: Commit**

```bash
chmod +x tools/check-jit-tools.sh
git add build/zig/jit.zig build/zig/options.zig build/zig/moar.zig build.zig tools/check-jit-tools.sh
git commit -m "zig build: enable the x86-64 JIT by default

DynASM runs through the zig-built minilua; the expression templates and
tiler tables come from the Zig ports of the Perl generators. zig build
check-jit-tools diffs all three against the Perl originals.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Documentation, plan deviations and final verification

**Files:**
- Modify: `docs/zig-build.md`
- Modify: `docs/superpowers/plans/2026-11-01-zig-build-phase2-jit.md` (the "Deviations" section at the end, if anything new was found)

- [ ] **Step 1: Update `docs/zig-build.md`**

Change the `-Djit=` row of the options table to:
```
| `-Djit=` | `true` on x86_64 | build the x86-64 JIT (DynASM via the zig-built minilua, tables from the Zig generators) |
```
Add a `zig build check-jit-tools` line to the commands at the top:
```
    zig build check-jit-tools # diff the Zig JIT generators against the Perl originals (needs perl)
```
Add a section before "Not yet supported":
```markdown
## JIT code generation

The Perl build runs three generators for the JIT; the zig build has
equivalents that need no Perl:

| Perl build | zig build |
|---|---|
| `3rdparty/dynasm/minilua` + `dynasm.lua` on `src/jit/x64/emit.dasc` | the same, with `minilua` built by zig (`build/zig/jit.zig`); output byte-identical |
| `tools/expr-template-compiler.pl` | `tools/zig/expr_template_compiler.zig`; output identical from line 2 |
| `tools/tiler-table-generator.pl` | `tools/zig/tiler_table_generator.zig`; identical after renumbering rulesets canonically (the Perl tool's numbering follows Perl hash order and differs between runs; `tools/canonicalize-tile-table.pl` applies the same renumbering to a Perl output) |

The generated `core_templates.h` and `tile_pattern.h` live in the zig cache
and are put on the include path ahead of `src/`, so Perl-generated copies
under `src/jit/` are ignored. `zig build test` additionally runs an nqp loop
with `MVM_SPESH_NODELAY=1 MVM_SPESH_BLOCKING=1 MVM_JIT_EXPR_ENABLE=1` so both
the lego JIT and the expression JIT execute.
```
Remove "JIT (dynasm and the Perl template compilers)," from the "Not yet supported" list.

- [ ] **Step 2: Full clean verification**

```bash
rm -f src/gen/config.h src/gen/config.c src/gen/config.o
zig fmt --check build.zig build/zig tools/zig && echo fmt-clean
rm -rf .zig-cache zig-out && zig build test --summary all 2>&1 | tail -4
zig-out/bin/moar --version
zig build check-jit-tools 2>&1 | tail -3
perl -c tools/canonicalize-tile-table.pl
git status --short
```
Expected: `fmt-clean`; all steps succeed; the version line ends with `built with JIT support`; `check-jit-tools` reports matches; `git status` shows only `docs/zig-build.md` modified (plus the plan if edited).

- [ ] **Step 3: Record anything learned in the plan's "Deviations" section and commit**

```bash
git add docs/zig-build.md docs/superpowers/plans/2026-11-01-zig-build-phase2-jit.md
git commit -m "Document the zig build's JIT code generation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Deviations from the spec, recorded here for the spec's next revision

- Spec section 5 asks for byte-identical output from the ported generators. That holds for `emit.c` and for `core_templates.h` from line 2 onward (line 1 names the generator). It cannot hold for `tile_pattern.h`: the Perl tiler's ruleset numbering follows Perl's randomized hash order and differs from run to run, so the Zig port numbers rulesets canonically and the check compares against a canonically renumbered Perl output (`tools/canonicalize-tile-table.pl`). The tables are the same up to that renumbering, which the C code never depends on (ruleset numbers are opaque table indices).
- The `check-jit-tools` step is a shell script that needs `perl` and `sh`; it is not part of `zig build test`, so the default build and tests still need no Perl.
- `-Djit` is a build option defaulting to true on x86_64 (the spec's "default on for x64").
- The Perl tool's own self-test (`expr-template-compiler.pl --test`) does not pass as shipped (it links `(copy $1)` with no operand environment); the Zig unit tests cover the same cases with an environment.
