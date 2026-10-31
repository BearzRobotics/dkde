//! Parser for the Kaitai Struct expression language. It produces a small tree
//! that interp.zig evaluates; everything is allocated from the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Op = enum { add, sub, mul, div, mod, shl, shr, lt, le, gt, ge, eq, ne, bit_and, bit_or, bit_xor, log_and, log_or };

pub const Expr = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    /// A plain identifier, including `_`, `_root`, `_parent`, `_io`, `_index`.
    name: []const u8,
    /// `a::b::c`, an enum value or a type path.
    scoped: []const []const u8,
    array: []const *const Expr,
    neg: *const Expr,
    bit_not: *const Expr,
    log_not: *const Expr,
    binary: struct { op: Op, l: *const Expr, r: *const Expr },
    ternary: struct { cond: *const Expr, a: *const Expr, b: *const Expr },
    member: struct { target: *const Expr, name: []const u8 },
    call: struct { target: *const Expr, name: []const u8, args: []const *const Expr },
    index: struct { target: *const Expr, idx: *const Expr },
};

pub const ParseError = error{ BadExpression, OutOfMemory };

const Token = union(enum) {
    end,
    int: i64,
    float: f64,
    str: []const u8,
    ident: []const u8,
    /// One of `+ - * / % << >> < <= > >= == != & | ^ ~ ( ) [ ] . , ? : ::`.
    punct: []const u8,
};

const Lexer = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn next(self: *Lexer) ParseError!Token {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) return .end;
        const c = self.src[self.pos];
        if (std.ascii.isDigit(c)) return self.number();
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.pos;
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
            return .{ .ident = self.src[start..self.pos] };
        }
        if (c == '"' or c == '\'') return self.string(c);
        const two = [_][]const u8{ "<<", ">>", "<=", ">=", "==", "!=", "::" };
        for (two) |p| {
            if (std.mem.startsWith(u8, self.src[self.pos..], p)) {
                self.pos += 2;
                return .{ .punct = p };
            }
        }
        const one = "+-*/%<>&|^~()[].,?:";
        if (std.mem.indexOfScalar(u8, one, c)) |i| {
            self.pos += 1;
            return .{ .punct = one[i .. i + 1] };
        }
        return error.BadExpression;
    }

    fn number(self: *Lexer) ParseError!Token {
        const s = self.src;
        const start = self.pos;
        if (s[start] == '0' and start + 1 < s.len and (s[start + 1] == 'x' or s[start + 1] == 'b' or s[start + 1] == 'o')) {
            const base: u8 = switch (s[start + 1]) {
                'x' => 16,
                'b' => 2,
                else => 8,
            };
            self.pos += 2;
            const digits_start = self.pos;
            while (self.pos < s.len and (std.ascii.isHex(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
            return .{ .int = try parseDigits(s[digits_start..self.pos], base) };
        }
        while (self.pos < s.len and (std.ascii.isDigit(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
        // A fraction needs a digit after the dot, so `x.to_i` and `5.to_s` stay method calls.
        if (self.pos + 1 < s.len and s[self.pos] == '.' and std.ascii.isDigit(s[self.pos + 1])) {
            self.pos += 1;
            while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
            if (self.pos < s.len and (s[self.pos] == 'e' or s[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < s.len and (s[self.pos] == '+' or s[self.pos] == '-')) self.pos += 1;
                while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
            }
            const f = std.fmt.parseFloat(f64, s[start..self.pos]) catch return error.BadExpression;
            return .{ .float = f };
        }
        return .{ .int = try parseDigits(s[start..self.pos], 10) };
    }

    fn string(self: *Lexer, quote: u8) ParseError!Token {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len and self.src[self.pos] != quote) {
            var c = self.src[self.pos];
            self.pos += 1;
            // Single quotes are literal in Kaitai; double quotes take escapes.
            if (c == '\\' and quote == '"' and self.pos < self.src.len) {
                c = self.src[self.pos];
                self.pos += 1;
                switch (c) {
                    'n' => c = '\n',
                    'r' => c = '\r',
                    't' => c = '\t',
                    '0' => c = 0,
                    'a' => c = 7,
                    'b' => c = 8,
                    'f' => c = 12,
                    'v' => c = 11,
                    'e' => c = 27,
                    'x' => {
                        if (self.pos + 2 > self.src.len) return error.BadExpression;
                        c = std.fmt.parseInt(u8, self.src[self.pos..][0..2], 16) catch return error.BadExpression;
                        self.pos += 2;
                    },
                    else => {},
                }
            }
            try out.append(self.arena, c);
        }
        if (self.pos >= self.src.len) return error.BadExpression;
        self.pos += 1;
        return .{ .str = out.items };
    }
};

fn parseDigits(digits: []const u8, base: u8) ParseError!i64 {
    var v: u64 = 0;
    var any = false;
    for (digits) |c| {
        if (c == '_') continue;
        const d = std.fmt.charToDigit(c, base) catch return error.BadExpression;
        v = std.math.mul(u64, v, base) catch return error.BadExpression;
        v = std.math.add(u64, v, d) catch return error.BadExpression;
        any = true;
    }
    if (!any) return error.BadExpression;
    return @bitCast(v);
}

const Parser = struct {
    arena: Allocator,
    lex: Lexer,
    tok: Token,

    fn advance(self: *Parser) ParseError!void {
        self.tok = try self.lex.next();
    }

    fn isPunct(self: *Parser, p: []const u8) bool {
        return switch (self.tok) {
            .punct => |q| std.mem.eql(u8, q, p),
            else => false,
        };
    }

    fn isWord(self: *Parser, w: []const u8) bool {
        return switch (self.tok) {
            .ident => |q| std.mem.eql(u8, q, w),
            else => false,
        };
    }

    fn expectPunct(self: *Parser, p: []const u8) ParseError!void {
        if (!self.isPunct(p)) return error.BadExpression;
        try self.advance();
    }

    fn make(self: *Parser, e: Expr) ParseError!*const Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    fn ternary(self: *Parser) ParseError!*const Expr {
        const cond = try self.binaryLevel(0);
        if (!self.isPunct("?")) return cond;
        try self.advance();
        const a = try self.ternary();
        try self.expectPunct(":");
        const b = try self.ternary();
        return self.make(.{ .ternary = .{ .cond = cond, .a = a, .b = b } });
    }

    const Level = struct { word: ?[]const u8 = null, puncts: []const []const u8 = &.{}, ops: []const Op };
    const levels = [_]Level{
        .{ .word = "or", .ops = &.{.log_or} },
        .{ .word = "and", .ops = &.{.log_and} },
        .{ .puncts = &.{"|"}, .ops = &.{.bit_or} },
        .{ .puncts = &.{"^"}, .ops = &.{.bit_xor} },
        .{ .puncts = &.{"&"}, .ops = &.{.bit_and} },
        .{ .puncts = &.{ "==", "!=" }, .ops = &.{ .eq, .ne } },
        .{ .puncts = &.{ "<", "<=", ">", ">=" }, .ops = &.{ .lt, .le, .gt, .ge } },
        .{ .puncts = &.{ "<<", ">>" }, .ops = &.{ .shl, .shr } },
        .{ .puncts = &.{ "+", "-" }, .ops = &.{ .add, .sub } },
        .{ .puncts = &.{ "*", "/", "%" }, .ops = &.{ .mul, .div, .mod } },
    };

    fn binaryLevel(self: *Parser, level: usize) ParseError!*const Expr {
        if (level == levels.len) return self.unary();
        const lv = levels[level];
        var left = try self.binaryLevel(level + 1);
        while (true) {
            var found: ?Op = null;
            if (lv.word) |w| {
                if (self.isWord(w)) found = lv.ops[0];
            }
            for (lv.puncts, 0..) |p, i| {
                if (self.isPunct(p)) found = lv.ops[i];
            }
            const op = found orelse return left;
            try self.advance();
            const right = try self.binaryLevel(level + 1);
            left = try self.make(.{ .binary = .{ .op = op, .l = left, .r = right } });
        }
    }

    fn unary(self: *Parser) ParseError!*const Expr {
        if (self.isPunct("-")) {
            try self.advance();
            return self.make(.{ .neg = try self.unary() });
        }
        if (self.isPunct("~")) {
            try self.advance();
            return self.make(.{ .bit_not = try self.unary() });
        }
        if (self.isWord("not")) {
            try self.advance();
            return self.make(.{ .log_not = try self.unary() });
        }
        return self.postfix();
    }

    fn postfix(self: *Parser) ParseError!*const Expr {
        var e = try self.primary();
        while (true) {
            if (self.isPunct(".")) {
                try self.advance();
                const name = switch (self.tok) {
                    .ident => |n| n,
                    else => return error.BadExpression,
                };
                try self.advance();
                // `.as<type>` is a cast; values are dynamically typed here.
                if (std.mem.eql(u8, name, "as") and self.isPunct("<")) {
                    while (!self.isPunct(">")) {
                        if (self.tok == .end) return error.BadExpression;
                        try self.advance();
                    }
                    try self.advance();
                    continue;
                }
                if (self.isPunct("(")) {
                    try self.advance();
                    var args: std.ArrayList(*const Expr) = .empty;
                    while (!self.isPunct(")")) {
                        try args.append(self.arena, try self.ternary());
                        if (self.isPunct(",")) try self.advance() else break;
                    }
                    try self.expectPunct(")");
                    e = try self.make(.{ .call = .{ .target = e, .name = name, .args = args.items } });
                } else {
                    e = try self.make(.{ .member = .{ .target = e, .name = name } });
                }
            } else if (self.isPunct("[")) {
                try self.advance();
                const idx = try self.ternary();
                try self.expectPunct("]");
                e = try self.make(.{ .index = .{ .target = e, .idx = idx } });
            } else return e;
        }
    }

    fn primary(self: *Parser) ParseError!*const Expr {
        switch (self.tok) {
            .int => |v| {
                try self.advance();
                return self.make(.{ .int = v });
            },
            .float => |v| {
                try self.advance();
                return self.make(.{ .float = v });
            },
            .str => |v| {
                try self.advance();
                return self.make(.{ .str = v });
            },
            .ident => |name| {
                try self.advance();
                if (std.mem.eql(u8, name, "true")) return self.make(.{ .boolean = true });
                if (std.mem.eql(u8, name, "false")) return self.make(.{ .boolean = false });
                if (self.isPunct("::")) {
                    var parts: std.ArrayList([]const u8) = .empty;
                    try parts.append(self.arena, name);
                    while (self.isPunct("::")) {
                        try self.advance();
                        switch (self.tok) {
                            .ident => |n| try parts.append(self.arena, n),
                            else => return error.BadExpression,
                        }
                        try self.advance();
                    }
                    return self.make(.{ .scoped = parts.items });
                }
                return self.make(.{ .name = name });
            },
            .punct => |p| {
                if (std.mem.eql(u8, p, "(")) {
                    try self.advance();
                    const e = try self.ternary();
                    try self.expectPunct(")");
                    return e;
                }
                if (std.mem.eql(u8, p, "[")) {
                    try self.advance();
                    var items: std.ArrayList(*const Expr) = .empty;
                    while (!self.isPunct("]")) {
                        try items.append(self.arena, try self.ternary());
                        if (self.isPunct(",")) try self.advance() else break;
                    }
                    try self.expectPunct("]");
                    return self.make(.{ .array = items.items });
                }
                return error.BadExpression;
            },
            .end => return error.BadExpression,
        }
    }
};

/// Parses `src`; the tree and its strings live in `arena`.
pub fn parse(arena: Allocator, src: []const u8) ParseError!*const Expr {
    var p: Parser = .{ .arena = arena, .lex = .{ .arena = arena, .src = src }, .tok = .end };
    try p.advance();
    const e = try p.ternary();
    if (p.tok != .end) return error.BadExpression;
    return e;
}

test "precedence and ternary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "a + 2 * 3 == 8 ? 0x10 : 1_000");
    try std.testing.expect(e.* == .ternary);
    try std.testing.expectEqual(@as(i64, 16), e.ternary.a.int);
    try std.testing.expectEqual(@as(i64, 1000), e.ternary.b.int);
    const cond = e.ternary.cond.binary;
    try std.testing.expectEqual(Op.eq, cond.op);
    try std.testing.expectEqual(Op.add, cond.l.binary.op);
    try std.testing.expectEqual(Op.mul, cond.l.binary.r.binary.op);
}

test "members, calls, indexes, enums and casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "_parent.items[_index - 1].as<u4>.len.to_i == kind::big");
    try std.testing.expectEqual(Op.eq, e.binary.op);
    try std.testing.expectEqualStrings("big", e.binary.r.scoped[1]);
    try std.testing.expectEqualStrings("to_i", e.binary.l.member.name);
}

test "strings take escapes only in double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try parse(arena.allocator(), "\"a\\x41\\n\"");
    try std.testing.expectEqualStrings("aA\n", a.str);
    const b = try parse(arena.allocator(), "'a\\n'");
    try std.testing.expectEqualStrings("a\\n", b.str);
}

test "bad input is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadExpression, parse(arena.allocator(), "1 +"));
    try std.testing.expectError(error.BadExpression, parse(arena.allocator(), "a b"));
    try std.testing.expectError(error.BadExpression, parse(arena.allocator(), "'open"));
}
