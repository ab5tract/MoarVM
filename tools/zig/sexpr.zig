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
                const close = std.mem.findScalarPos(u8, self.src, self.pos + 1, '"') orelse
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
};

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
