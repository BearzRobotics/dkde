//! Typesetting the calculator's text for display: `1/2 + 3/4` becomes two stacked fractions (the
//! numerator over the denominator with a bar between), `x^2` a raised 2, `√x` a root with its bar.
//! This file only reads the text into a tree; drawing it is mathview.zig. The text itself is never
//! changed: what is stored, copied and evaluated stays the plain line.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = union(enum) {
    /// Plain text, drawn as it is.
    text: []const u8,
    row: []Node,
    /// Numerator over denominator.
    frac: struct { num: *Node, den: *Node },
    /// Raised and smaller.
    sup: *Node,
    /// A root sign over the radicand.
    sqrt: *Node,
    /// Parentheses around content (kept so that grouping is still visible).
    group: *Node,
    /// An empty pair of parentheses: a box waiting for something to be typed (the fraction template).
    empty,
};

const Kind = enum { number, ident, single_letter, group, call, root, other };
const Atom = struct { node: Node, kind: Kind };

const Parser = struct {
    arena: Allocator,
    s: []const u8,
    i: usize = 0,

    fn peek(self: *Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.s[self.i..], prefix);
    }

    fn skipSpaces(self: *Parser) void {
        while (self.peek()) |c| : (self.i += 1) if (c != ' ') break;
    }

    /// A UTF-8 sequence's length from its first byte.
    fn seqLen(c: u8) usize {
        return if (c < 0x80) 1 else if (c >> 5 == 0b110) 2 else if (c >> 4 == 0b1110) 3 else 4;
    }

    fn isSuperscript(self: *Parser) bool {
        // ⁰ ¹ ² ³ ⁴-⁹ ⁺ ⁻ and the like: U+2070..U+207F and ¹ ² ³ (U+00B9, B2, B3)
        const rest = self.s[self.i..];
        if (rest.len >= 2 and rest[0] == 0xC2 and (rest[1] == 0xB2 or rest[1] == 0xB3 or rest[1] == 0xB9)) return true;
        if (rest.len >= 3 and rest[0] == 0xE2 and rest[1] == 0x81) return true;
        return false;
    }

    fn isNarrowSpace(self: *Parser) bool {
        return self.startsWith("\u{202F}");
    }

    fn isLetter(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
    }

    fn atomStart(self: *Parser) bool {
        const c = self.peek() orelse return false;
        if (std.ascii.isDigit(c) or c == '.' or c == '(') return true;
        if (self.startsWith("√")) return true;
        if (self.isSuperscript() or self.isNarrowSpace()) return false;
        return isLetter(c);
    }

    fn alloc(self: *Parser, node: Node) Allocator.Error!*Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
    }

    /// One operand: a number, a name, a function call, a group or a root.
    fn atom(self: *Parser) Allocator.Error!Atom {
        const c = self.peek().?;
        const start = self.i;
        if (c == '(') {
            self.i += 1;
            const inner = try self.row(true);
            if (self.peek() == ')') self.i += 1;
            return .{ .node = .{ .group = try self.alloc(inner) }, .kind = .group };
        }
        if (self.startsWith("√")) {
            self.i += "√".len;
            if (self.atomStart()) {
                const operand = try self.atom();
                return .{ .node = .{ .sqrt = try self.alloc(strip(operand.node)) }, .kind = .root };
            }
            return .{ .node = .{ .text = "√" }, .kind = .other };
        }
        if (std.ascii.isDigit(c) or c == '.') {
            while (self.peek()) |d| {
                if (std.ascii.isDigit(d) or d == '.') {
                    self.i += 1;
                } else if (self.isNarrowSpace() and self.i + 3 < self.s.len and std.ascii.isDigit(self.s[self.i + 3])) {
                    self.i += 3;
                } else break;
            }
            return self.withSup(.{ .node = .{ .text = self.s[start..self.i] }, .kind = .number });
        }
        // A name: letters, then digits and underscores that belong to it.
        while (self.peek()) |d| {
            if (isLetter(d) and !self.isSuperscript()) {
                self.i += seqLen(d);
            } else if (std.ascii.isDigit(d) and self.i > start) {
                self.i += 1;
            } else break;
        }
        const name = self.s[start..self.i];
        if (self.peek() == '(') {
            // f(x): the name and its argument list stay together.
            self.i += 1;
            const inner = try self.row(true);
            if (self.peek() == ')') self.i += 1;
            const parts = try self.arena.alloc(Node, 3);
            parts[0] = .{ .text = name };
            parts[1] = .{ .text = "(" };
            parts[2] = .{ .row = try self.arena.dupe(Node, &.{ inner, .{ .text = ")" } }) };
            return self.withSup(.{ .node = .{ .row = parts }, .kind = .call });
        }
        const letters: usize = std.unicode.utf8CountCodepoints(name) catch name.len;
        return self.withSup(.{ .node = .{ .text = name }, .kind = if (letters == 1) .single_letter else .ident });
    }

    /// A unicode superscript right after an operand is part of it (x²).
    fn withSup(self: *Parser, a: Atom) Allocator.Error!Atom {
        if (!self.isSuperscript()) return a;
        const start = self.i;
        while (self.isSuperscript()) self.i += seqLen(self.s[self.i]);
        const parts = try self.arena.alloc(Node, 2);
        parts[0] = a.node;
        parts[1] = .{ .text = self.s[start..self.i] };
        return .{ .node = .{ .row = parts }, .kind = a.kind };
    }

    fn strip(n: Node) Node {
        return switch (n) {
            .group => |g| g.*,
            else => n,
        };
    }

    /// A row of items up to the end, or up to the `)` that closes a group.
    fn row(self: *Parser, in_group: bool) Allocator.Error!Node {
        var items: std.ArrayList(Node) = .empty;
        var plain_start: ?usize = null;
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (in_group and c == ')') break;
            if (c == '^') {
                // x^2, x^(n+1): raised.
                const mark = self.i;
                self.i += 1;
                var neg = false;
                if (self.peek() == '-') {
                    neg = true;
                    self.i += 1;
                }
                if (self.atomStart()) {
                    try self.flush(&items, &plain_start, mark);
                    const a = try self.atom();
                    const inner = if (neg) blk: {
                        const parts = try self.arena.dupe(Node, &.{ .{ .text = "\u{2212}" }, strip(a.node) });
                        break :blk Node{ .row = parts };
                    } else strip(a.node);
                    try items.append(self.arena, .{ .sup = try self.alloc(inner) });
                    continue;
                }
                self.i = mark + 1;
                if (plain_start == null) plain_start = mark;
                continue;
            }
            if (self.atomStart()) {
                try self.flush(&items, &plain_start, self.i);
                var a = try self.atom();
                // a/b, then (a/b)/c: stacked, unless both are long names (a unit like km/h reads better in a line).
                while (true) {
                    const save = self.i;
                    self.skipSpaces();
                    if (self.peek() != '/') {
                        self.i = save;
                        break;
                    }
                    self.i += 1;
                    self.skipSpaces();
                    if (!self.atomStart()) {
                        self.i = save;
                        break;
                    }
                    const rhs_start = self.i;
                    const b = try self.atom();
                    const a_name = a.kind == .ident or a.kind == .single_letter;
                    const b_name = b.kind == .ident or b.kind == .single_letter;
                    if (a_name and b_name and (a.kind == .ident or b.kind == .ident)) {
                        // Leave it as text: the slash stays.
                        const parts = try self.arena.dupe(Node, &.{ a.node, .{ .text = "/" }, b.node });
                        a = .{ .node = .{ .row = parts }, .kind = .other };
                        _ = rhs_start;
                        continue;
                    }
                    const num = try self.alloc(strip(a.node));
                    const den = try self.alloc(strip(b.node));
                    a = .{ .node = .{ .frac = .{ .num = num, .den = den } }, .kind = .other };
                }
                try items.append(self.arena, a.node);
                continue;
            }
            if (plain_start == null) plain_start = self.i;
            self.i += seqLen(c);
        }
        try self.flush(&items, &plain_start, self.i);
        if (in_group and items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .row = try items.toOwnedSlice(self.arena) };
    }

    fn flush(self: *Parser, items: *std.ArrayList(Node), start: *?usize, end: usize) Allocator.Error!void {
        if (start.*) |s| {
            if (end > s) try items.append(self.arena, .{ .text = self.s[s..end] });
        }
        start.* = null;
    }
};

/// Reads `text` into a tree. The pieces point into `text` and into `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Node {
    var p: Parser = .{ .arena = arena, .s = text };
    return p.row(false);
}

/// Does the tree hold anything that is drawn other than as a line of text?
pub fn isStacked(n: Node) bool {
    return switch (n) {
        .text, .empty => false,
        .row => |items| for (items) |x| {
            if (isStacked(x)) break true;
        } else false,
        .group => |g| isStacked(g.*),
        .frac, .sup, .sqrt => true,
    };
}

/// The plain text of a tree (for tests, and as the accessible label).
pub fn plain(n: Node, out: *std.ArrayList(u8), a: Allocator) Allocator.Error!void {
    switch (n) {
        .text => |t| try out.appendSlice(a, t),
        .empty => {},
        .row => |items| for (items) |x| try plain(x, out, a),
        .frac => |f| {
            try plain(f.num.*, out, a);
            try out.append(a, '/');
            try plain(f.den.*, out, a);
        },
        .sup => |s| {
            try out.append(a, '^');
            try plain(s.*, out, a);
        },
        .sqrt => |s| {
            try out.appendSlice(a, "√");
            try plain(s.*, out, a);
        },
        .group => |g| {
            try out.append(a, '(');
            try plain(g.*, out, a);
            try out.append(a, ')');
        },
    }
}

fn shape(a: Allocator, text: []const u8) ![]const u8 {
    const tree = try parse(a, text);
    var out: std.ArrayList(u8) = .empty;
    try dump(tree, &out, a);
    return out.items;
}

fn dump(n: Node, out: *std.ArrayList(u8), a: Allocator) !void {
    switch (n) {
        .text => |t| try out.appendSlice(a, t),
        .empty => try out.appendSlice(a, "_"),
        .row => |items| for (items) |x| try dump(x, out, a),
        .frac => |f| {
            try out.appendSlice(a, "[");
            try dump(f.num.*, out, a);
            try out.appendSlice(a, "|");
            try dump(f.den.*, out, a);
            try out.appendSlice(a, "]");
        },
        .sup => |s| {
            try out.appendSlice(a, "^{");
            try dump(s.*, out, a);
            try out.appendSlice(a, "}");
        },
        .sqrt => |s| {
            try out.appendSlice(a, "√{");
            try dump(s.*, out, a);
            try out.appendSlice(a, "}");
        },
        .group => |g| {
            try out.appendSlice(a, "(");
            try dump(g.*, out, a);
            try out.appendSlice(a, ")");
        },
    }
}

test "a fraction is stacked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[1|2]", try shape(a, "1/2"));
    try std.testing.expectEqualStrings("[1|2] + [3|4]", try shape(a, "1/2 + 3/4"));
    try std.testing.expectEqualStrings("[x+1|x−1]", try shape(a, "(x+1)/(x−1)"));
    try std.testing.expectEqualStrings("[[1|2]|3]", try shape(a, "1/2/3"));
    try std.testing.expectEqualStrings("[22|7]", try shape(a, "22 / 7"));
}

test "the fraction template shows two empty boxes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[_|_]", try shape(a, "()/()"));
    try std.testing.expectEqualStrings("[3|_]", try shape(a, "(3)/()"));
    try std.testing.expect(isStacked(try parse(a, "()/()")));
}

test "units and plain lines are left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("5 km/h", try shape(a, "5 km/h"));
    try std.testing.expectEqualStrings("2 + 3", try shape(a, "2 + 3"));
    try std.testing.expect(!isStacked(try parse(a, "2 + 3")));
    try std.testing.expect(isStacked(try parse(a, "1/2")));
}

test "powers, roots and function calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x^{2}", try shape(a, "x^2"));
    try std.testing.expectEqualStrings("2^{n+1}", try shape(a, "2^(n+1)"));
    try std.testing.expectEqualStrings("√{2}", try shape(a, "√2"));
    try std.testing.expectEqualStrings("[sin(x)|2]", try shape(a, "sin(x)/2"));
    try std.testing.expectEqualStrings("x²", try shape(a, "x²"));
}

test "a trailing slash or an odd paren does not crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try shape(a, "1/");
    _ = try shape(a, "/2");
    _ = try shape(a, "(1/2");
    _ = try shape(a, "1/2)");
    _ = try shape(a, "");
    _ = try shape(a, "^");
    _ = try shape(a, "√");
}
