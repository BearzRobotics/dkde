//! Lexer and parser for ImHex pattern files (`.hexpat`), a C-like language that
//! describes how bytes are laid out. The tree is evaluated by eval.zig.
//! Everything is allocated from the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

// -- tree ---------------------------------------------------------------------------------

pub const Op = enum { add, sub, mul, div, mod, shl, shr, lt, le, gt, ge, eq, ne, bit_and, bit_or, bit_xor, log_and, log_or };

pub const Expr = union(enum) {
    int: i128,
    float: f64,
    str: []const u8,
    boolean: bool,
    /// `$`, the read position.
    dollar,
    this,
    parent,
    null_,
    /// `a`, `a::b::c`.
    path: []const []const u8,
    neg: *const Expr,
    plus: *const Expr,
    bit_not: *const Expr,
    log_not: *const Expr,
    binary: struct { op: Op, l: *const Expr, r: *const Expr },
    ternary: struct { cond: *const Expr, a: *const Expr, b: *const Expr },
    member: struct { target: *const Expr, name: []const u8 },
    index: struct { target: *const Expr, idx: *const Expr },
    call: struct { callee: *const Expr, args: []const *const Expr },
    /// `sizeof(x)`, `addressof(x)`, `typenameof(x)`: `what` is an expression or a type.
    sizeof: Operand,
    addressof: *const Expr,
    /// `T(x)`, a conversion to a built-in type.
    cast: struct { ty: *const TypeExpr, e: *const Expr },
    /// A type used where a value is expected, as `std::sizeof<T>`-like arguments.
    type_value: *const TypeExpr,
    /// `a = b`, `a += b` ...; `op` is null for plain assignment.
    assign: struct { target: *const Expr, op: ?Op, value: *const Expr },
};

pub const Operand = union(enum) { expr: *const Expr, ty: *const TypeExpr };

pub const Endian = enum { default, little, big };

pub const TypeArg = union(enum) { ty: *const TypeExpr, expr: *const Expr };

pub const TypeExpr = struct {
    endian: Endian = .default,
    path: []const []const u8,
    args: []const TypeArg = &.{},
};

pub const Attr = struct { name: []const u8, args: []const *const Expr };

pub const ArraySpec = union(enum) {
    count: *const Expr,
    while_: *const Expr,
    /// `name[]`: runs to a terminator (a zero byte, for strings).
    unsized,
};

pub const Decl = struct {
    ty: *const TypeExpr,
    name: []const u8,
    array: ?ArraySpec = null,
    placement: ?*const Expr = null,
    init: ?*const Expr = null,
    pointer: ?*const TypeExpr = null,
    attrs: []const Attr = &.{},
    line: u32 = 0,
};

pub const MatchCase = struct {
    /// One entry per matched value; null is `_`.
    patterns: []const ?Pattern,
    body: []const Stmt,
};

pub const Pattern = struct { lo: *const Expr, hi: ?*const Expr, alternatives: []const *const Expr };

pub const Stmt = union(enum) {
    decl: Decl,
    if_: struct { cond: *const Expr, then: []const Stmt, else_: []const Stmt },
    while_: struct { cond: *const Expr, body: []const Stmt },
    for_: struct { init: []const Stmt, cond: ?*const Expr, step: ?*const Expr, body: []const Stmt },
    match: struct { values: []const *const Expr, cases: []const MatchCase },
    return_: ?*const Expr,
    break_,
    continue_,
    expr: *const Expr,
    block: []const Stmt,
    padding: *const Expr,
    /// A type, enum, function or namespace; registered once, not run.
    def: *const Def,
    nop,
};

pub const Param = struct { name: []const u8, ty: ?*const TypeExpr, is_type: bool = false, default: ?*const Expr = null };

pub const StructDef = struct {
    name: []const u8,
    params: []const Param,
    parent: ?*const TypeExpr,
    body: []const Stmt,
    attrs: []const Attr,
    is_union: bool,
    ns: []const u8,
};

pub const EnumEntry = struct { name: []const u8, value: ?*const Expr, hi: ?*const Expr };

pub const EnumDef = struct { name: []const u8, base: *const TypeExpr, entries: []const EnumEntry, ns: []const u8 };

pub const BitEntry = struct { name: []const u8, bits: ?*const Expr, ty: ?*const TypeExpr = null, is_padding: bool, attrs: []const Attr, value: ?*const Expr = null };

pub const BitfieldDef = struct { name: []const u8, params: []const Param, entries: []const BitEntry, attrs: []const Attr, ns: []const u8 };

pub const UsingDef = struct { name: []const u8, params: []const Param, target: ?*const TypeExpr, ns: []const u8 };

pub const FuncDef = struct { name: []const u8, params: []const Param, body: []const Stmt, ns: []const u8 };

pub const Def = union(enum) {
    struct_: StructDef,
    enum_: EnumDef,
    bitfield: BitfieldDef,
    using: UsingDef,
    func: FuncDef,
};

pub const Program = struct {
    stmts: []const Stmt,
    /// `#pragma endian`.
    endian: Endian = .default,
    /// Names of files this one imports (`import type.magic;`), without std.
    imports: []const []const u8 = &.{},
    description: []const u8 = "",
};

pub const ParseError = error{ Syntax, OutOfMemory };

pub const Failure = struct { line: u32, message: []const u8 };

// -- lexer --------------------------------------------------------------------------------

const Tok = struct {
    kind: Kind,
    text: []const u8,
    line: u32,
    pos: u32,
    int: i128 = 0,
    float: f64 = 0,

    const Kind = enum { ident, int, float, str, char, punct, end };
};

const Lexer = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    out: std.ArrayList(Tok) = .empty,
    macros: std.StringHashMapUnmanaged([]const Tok) = .empty,
    /// Nesting of `#ifdef` blocks: each entry says whether tokens are kept.
    active: std.ArrayList(bool) = .empty,
    endian: Endian = .default,
    description: []const u8 = "",
    imports: std.ArrayList([]const u8) = .empty,
    failure: ?Failure = null,

    fn live(self: *const Lexer) bool {
        for (self.active.items) |a| if (!a) return false;
        return true;
    }

    fn fail(self: *Lexer, comptime fmt: []const u8, args: anytype) ParseError {
        if (self.failure == null) self.failure = .{ .line = self.line, .message = std.fmt.allocPrint(self.arena, fmt, args) catch "syntax error" };
        return error.Syntax;
    }

    fn run(self: *Lexer) ParseError!void {
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            if (c == '#' and self.atLineStart()) {
                try self.directive();
                continue;
            }
            if (!self.live()) {
                // Inside a skipped #ifdef: drop the rest of the line.
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            try self.token();
        }
        try self.out.append(self.arena, .{ .kind = .end, .text = "", .line = self.line, .pos = @intCast(self.pos) });
    }

    fn atLineStart(self: *const Lexer) bool {
        var i = self.pos;
        while (i > 0) {
            i -= 1;
            if (self.src[i] == '\n') return true;
            if (self.src[i] != ' ' and self.src[i] != '\t') return false;
        }
        return true;
    }

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.line += 1;
                self.pos += 1;
            } else if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len and !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/')) {
                    if (self.src[self.pos] == '\n') self.line += 1;
                    self.pos += 1;
                }
                self.pos = @min(self.pos + 2, self.src.len);
            } else break;
        }
    }

    fn directive(self: *Lexer) ParseError!void {
        // The whole logical line, with `\` continuations joined.
        var line: std.ArrayList(u8) = .empty;
        self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                self.pos += 2;
                self.line += 1;
                try line.append(self.arena, ' ');
                continue;
            }
            if (self.src[self.pos] == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                break;
            }
            try line.append(self.arena, self.src[self.pos]);
            self.pos += 1;
        }
        const text = std.mem.trim(u8, line.items, " \t\r");
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const name = it.next() orelse return;
        const rest = std.mem.trim(u8, text[name.len..], " \t");
        const eql = std.mem.eql;

        if (eql(u8, name, "ifdef") or eql(u8, name, "ifndef")) {
            const defined = self.macros.contains(rest);
            try self.active.append(self.arena, if (eql(u8, name, "ifdef")) defined else !defined);
            return;
        }
        if (eql(u8, name, "else")) {
            if (self.active.items.len > 0) self.active.items[self.active.items.len - 1] = !self.active.items[self.active.items.len - 1];
            return;
        }
        if (eql(u8, name, "endif")) {
            _ = self.active.pop();
            return;
        }
        if (!self.live()) return;
        if (eql(u8, name, "define")) {
            var parts = std.mem.tokenizeAny(u8, rest, " \t");
            const macro = parts.next() orelse return;
            // Function-like macros are not supported; their uses fail in the parser.
            if (std.mem.indexOfScalar(u8, macro, '(') != null) return;
            const body = std.mem.trim(u8, rest[macro.len..], " \t");
            var sub: Lexer = .{ .arena = self.arena, .src = body, .line = self.line, .macros = self.macros };
            try sub.run();
            // Drop the end token.
            const toks = sub.out.items[0 .. sub.out.items.len - 1];
            try self.macros.put(self.arena, try self.arena.dupe(u8, macro), toks);
        } else if (eql(u8, name, "pragma")) {
            var parts = std.mem.tokenizeAny(u8, rest, " \t");
            const key = parts.next() orelse return;
            const value = std.mem.trim(u8, rest[key.len..], " \t");
            if (eql(u8, key, "endian")) {
                if (eql(u8, value, "big")) self.endian = .big else if (eql(u8, value, "little")) self.endian = .little;
            } else if (eql(u8, key, "description")) {
                self.description = try self.arena.dupe(u8, value);
            }
        } else if (eql(u8, name, "include")) {
            const inner = std.mem.trim(u8, rest, "<>\"");
            try self.imports.append(self.arena, try self.arena.dupe(u8, inner));
        }
    }

    fn push(self: *Lexer, kind: Tok.Kind, text: []const u8, start: usize) ParseError!void {
        try self.out.append(self.arena, .{ .kind = kind, .text = text, .line = self.line, .pos = @intCast(start) });
    }

    fn token(self: *Lexer) ParseError!void {
        const s = self.src;
        const start = self.pos;
        const c = s[start];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < s.len and (std.ascii.isAlphanumeric(s[self.pos]) or s[self.pos] == '_')) self.pos += 1;
            const word = s[start..self.pos];
            if (self.macros.get(word)) |body| {
                for (body) |t| {
                    var copy = t;
                    copy.line = self.line;
                    try self.out.append(self.arena, copy);
                }
            } else try self.push(.ident, word, start);
            return;
        }
        if (std.ascii.isDigit(c)) return self.number();
        if (c == '"') return self.string();
        if (c == '\'') {
            self.pos += 1;
            var v: u8 = 0;
            if (self.pos + 3 < s.len and s[self.pos] == '\\' and s[self.pos + 1] == 'x') {
                v = std.fmt.parseInt(u8, s[self.pos + 2 ..][0..2], 16) catch 0;
                self.pos += 3;
            } else if (self.pos < s.len and s[self.pos] == '\\' and self.pos + 1 < s.len) {
                self.pos += 1;
                v = unescape(s[self.pos]);
            } else if (self.pos < s.len) v = s[self.pos];
            self.pos += 1;
            if (self.pos < s.len and s[self.pos] == '\'') self.pos += 1;
            try self.out.append(self.arena, .{ .kind = .char, .text = "", .line = self.line, .pos = @intCast(start), .int = v });
            return;
        }
        const three = [_][]const u8{ "<<=", ">>=" };
        for (three) |p| if (std.mem.startsWith(u8, s[start..], p)) {
            self.pos += 3;
            return self.push(.punct, p, start);
        };
        // `>>` is left as two `>` so templates like `A<B<C>>` work; the
        // expression parser joins them back into a shift.
        const two = [_][]const u8{ "::", "==", "!=", "<=", ">=", "&&", "||", "<<", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "++", "--" };
        for (two) |p| if (std.mem.startsWith(u8, s[start..], p)) {
            self.pos += 2;
            return self.push(.punct, p, start);
        };
        const one = "+-*/%<>&|^~!()[]{}.,;:?=@$#";
        if (std.mem.indexOfScalar(u8, one, c)) |i| {
            self.pos += 1;
            return self.push(.punct, one[i .. i + 1], start);
        }
        return self.fail("unexpected character '{c}'", .{c});
    }

    fn unescape(c: u8) u8 {
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'v' => 11,
            else => c,
        };
    }

    fn string(self: *Lexer) ParseError!void {
        const s = self.src;
        const start = self.pos;
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < s.len and s[self.pos] != '"') {
            var c = s[self.pos];
            self.pos += 1;
            if (c == '\n') self.line += 1;
            if (c == '\\' and self.pos < s.len) {
                c = s[self.pos];
                self.pos += 1;
                if (c == 'x' and self.pos + 2 <= s.len) {
                    c = std.fmt.parseInt(u8, s[self.pos..][0..2], 16) catch 'x';
                    self.pos += 2;
                } else c = unescape(c);
            }
            try out.append(self.arena, c);
        }
        if (self.pos >= s.len) return self.fail("a string is not closed", .{});
        self.pos += 1;
        try self.push(.str, out.items, start);
    }

    fn number(self: *Lexer) ParseError!void {
        const s = self.src;
        const start = self.pos;
        var base: u8 = 10;
        if (s[start] == '0' and start + 1 < s.len and (s[start + 1] == 'x' or s[start + 1] == 'X')) {
            base = 16;
            self.pos += 2;
        } else if (s[start] == '0' and start + 1 < s.len and (s[start + 1] == 'b' or s[start + 1] == 'B')) {
            base = 2;
            self.pos += 2;
        } else if (s[start] == '0' and start + 1 < s.len and (s[start + 1] == 'o' or s[start + 1] == 'O')) {
            base = 8;
            self.pos += 2;
        }
        const digits_start = self.pos;
        while (self.pos < s.len and (std.ascii.isHex(s[self.pos]) and (base == 16 or std.ascii.isDigit(s[self.pos])) or s[self.pos] == '\'')) self.pos += 1;
        // A fraction: only after plain decimal digits, and followed by a digit.
        if (base == 10 and self.pos + 1 < s.len and s[self.pos] == '.' and std.ascii.isDigit(s[self.pos + 1])) {
            self.pos += 1;
            while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
            if (self.pos < s.len and (s[self.pos] == 'e' or s[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < s.len and (s[self.pos] == '+' or s[self.pos] == '-')) self.pos += 1;
                while (self.pos < s.len and std.ascii.isDigit(s[self.pos])) self.pos += 1;
            }
            const f = std.fmt.parseFloat(f64, s[digits_start..self.pos]) catch return self.fail("bad number", .{});
            // Suffix (f, d).
            while (self.pos < s.len and std.ascii.isAlphabetic(s[self.pos])) self.pos += 1;
            try self.out.append(self.arena, .{ .kind = .float, .text = "", .line = self.line, .pos = @intCast(start), .float = f });
            return;
        }
        var v: u128 = 0;
        for (s[digits_start..self.pos]) |ch| {
            if (ch == '\'') continue;
            const d = std.fmt.charToDigit(ch, base) catch return self.fail("bad number", .{});
            v = v *% base +% d;
        }
        // Integer suffixes: u, l, ll, ul ...
        while (self.pos < s.len and (s[self.pos] == 'u' or s[self.pos] == 'U' or s[self.pos] == 'l' or s[self.pos] == 'L')) self.pos += 1;
        try self.out.append(self.arena, .{ .kind = .int, .text = "", .line = self.line, .pos = @intCast(start), .int = @bitCast(v) });
    }
};

// -- parser -------------------------------------------------------------------------------

pub const Parser = struct {
    arena: Allocator,
    toks: []const Tok,
    i: usize = 0,
    ns: []const u8 = "",
    failure: ?Failure = null,
    depth: u32 = 0,
    in_for: bool = false,

    fn cur(self: *const Parser) Tok {
        return self.toks[self.i];
    }

    fn peekAt(self: *const Parser, n: usize) Tok {
        return self.toks[@min(self.i + n, self.toks.len - 1)];
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        if (self.failure == null) {
            self.failure = .{ .line = self.cur().line, .message = std.fmt.allocPrint(self.arena, fmt, args) catch "syntax error" };
        }
        return error.Syntax;
    }

    fn isPunct(self: *const Parser, p: []const u8) bool {
        const t = self.cur();
        return t.kind == .punct and std.mem.eql(u8, t.text, p);
    }

    fn isWord(self: *const Parser, w: []const u8) bool {
        const t = self.cur();
        return t.kind == .ident and std.mem.eql(u8, t.text, w);
    }

    fn acceptPunct(self: *Parser, p: []const u8) bool {
        if (self.isPunct(p)) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn acceptWord(self: *Parser, w: []const u8) bool {
        if (self.isWord(w)) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn expectPunct(self: *Parser, p: []const u8) ParseError!void {
        if (!self.acceptPunct(p)) return self.fail("expected '{s}' but found '{s}'", .{ p, self.describe() });
    }

    fn describe(self: *const Parser) []const u8 {
        const t = self.cur();
        return switch (t.kind) {
            .end => "the end of the file",
            .int, .float => "a number",
            .str => "a string",
            .char => "a character",
            else => t.text,
        };
    }

    fn ident(self: *Parser) ParseError![]const u8 {
        const t = self.cur();
        if (t.kind != .ident) return self.fail("expected a name but found '{s}'", .{self.describe()});
        self.i += 1;
        return t.text;
    }

    fn make(self: *Parser, e: Expr) ParseError!*const Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    // -- expressions --

    pub fn expr(self: *Parser) ParseError!*const Expr {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 200) return self.fail("an expression nests too deeply", .{});
        return self.assignment();
    }

    fn assignment(self: *Parser) ParseError!*const Expr {
        const left = try self.ternary();
        const compound = [_]struct { p: []const u8, op: Op }{
            .{ .p = "+=", .op = .add },    .{ .p = "-=", .op = .sub },     .{ .p = "*=", .op = .mul },
            .{ .p = "/=", .op = .div },    .{ .p = "%=", .op = .mod },     .{ .p = "&=", .op = .bit_and },
            .{ .p = "|=", .op = .bit_or }, .{ .p = "^=", .op = .bit_xor }, .{ .p = "<<=", .op = .shl },
            .{ .p = ">>=", .op = .shr },
        };
        if (self.isPunct("=")) {
            self.i += 1;
            return self.make(.{ .assign = .{ .target = left, .op = null, .value = try self.assignment() } });
        }
        for (compound) |c| if (self.isPunct(c.p)) {
            self.i += 1;
            return self.make(.{ .assign = .{ .target = left, .op = c.op, .value = try self.assignment() } });
        };
        return left;
    }

    fn ternary(self: *Parser) ParseError!*const Expr {
        const cond = try self.binaryLevel(0);
        if (!self.isPunct("?")) return cond;
        self.i += 1;
        const a = try self.ternary();
        try self.expectPunct(":");
        const b = try self.ternary();
        return self.make(.{ .ternary = .{ .cond = cond, .a = a, .b = b } });
    }

    const Level = []const struct { p: []const u8, op: Op };
    const levels = [_]Level{
        &.{.{ .p = "||", .op = .log_or }},
        &.{.{ .p = "&&", .op = .log_and }},
        &.{.{ .p = "|", .op = .bit_or }},
        &.{.{ .p = "^", .op = .bit_xor }},
        &.{.{ .p = "&", .op = .bit_and }},
        &.{ .{ .p = "==", .op = .eq }, .{ .p = "!=", .op = .ne } },
        &.{ .{ .p = "<=", .op = .le }, .{ .p = ">=", .op = .ge }, .{ .p = "<", .op = .lt }, .{ .p = ">", .op = .gt } },
        &.{ .{ .p = "<<", .op = .shl }, .{ .p = ">>", .op = .shr } },
        &.{ .{ .p = "+", .op = .add }, .{ .p = "-", .op = .sub } },
        &.{ .{ .p = "*", .op = .mul }, .{ .p = "/", .op = .div }, .{ .p = "%", .op = .mod } },
    };

    /// True when the next two tokens are an adjacent `>` `>`, a right shift.
    fn atShiftRight(self: *const Parser) bool {
        const a = self.cur();
        const b = self.peekAt(1);
        return a.kind == .punct and b.kind == .punct and std.mem.eql(u8, a.text, ">") and std.mem.eql(u8, b.text, ">") and b.pos == a.pos + 1;
    }

    fn binaryLevel(self: *Parser, level: usize) ParseError!*const Expr {
        if (level == levels.len) return self.unary();
        var left = try self.binaryLevel(level + 1);
        outer: while (true) {
            if (level == 7 and self.atShiftRight()) {
                self.i += 2;
                const right = try self.binaryLevel(level + 1);
                left = try self.make(.{ .binary = .{ .op = .shr, .l = left, .r = right } });
                continue :outer;
            }
            for (levels[level]) |c| {
                if (!self.isPunct(c.p)) continue;
                // A lone `>` before another adjacent `>` is half of `>>`.
                if (level == 6 and std.mem.eql(u8, c.p, ">") and self.atShiftRight()) return left;
                self.i += 1;
                const right = try self.binaryLevel(level + 1);
                left = try self.make(.{ .binary = .{ .op = c.op, .l = left, .r = right } });
                continue :outer;
            }
            return left;
        }
    }

    fn unary(self: *Parser) ParseError!*const Expr {
        if (self.acceptPunct("-")) return self.make(.{ .neg = try self.unary() });
        if (self.acceptPunct("+")) return self.make(.{ .plus = try self.unary() });
        if (self.acceptPunct("~")) return self.make(.{ .bit_not = try self.unary() });
        if (self.acceptPunct("!")) return self.make(.{ .log_not = try self.unary() });
        return self.postfix();
    }

    fn postfix(self: *Parser) ParseError!*const Expr {
        var e = try self.primary();
        while (true) {
            if (self.isPunct(".") and !(self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, "."))) {
                self.i += 1;
                const name = try self.ident();
                e = try self.make(.{ .member = .{ .target = e, .name = name } });
            } else if (self.isPunct("[") and !self.peekIsAttrOpen()) {
                self.i += 1;
                const idx = try self.expr();
                try self.expectPunct("]");
                e = try self.make(.{ .index = .{ .target = e, .idx = idx } });
            } else if (self.isPunct("(")) {
                self.i += 1;
                var args: std.ArrayList(*const Expr) = .empty;
                while (!self.isPunct(")")) {
                    try args.append(self.arena, try self.expr());
                    if (!self.acceptPunct(",")) break;
                }
                try self.expectPunct(")");
                e = try self.make(.{ .call = .{ .callee = e, .args = args.items } });
            } else if (self.isPunct("++") or self.isPunct("--")) {
                const op: Op = if (self.isPunct("++")) .add else .sub;
                self.i += 1;
                e = try self.make(.{ .assign = .{ .target = e, .op = op, .value = try self.make(.{ .int = 1 }) } });
            } else return e;
        }
    }

    /// `[[` begins an attribute list, never an index.
    fn peekIsAttrOpen(self: *const Parser) bool {
        const a = self.cur();
        const b = self.peekAt(1);
        return b.kind == .punct and std.mem.eql(u8, b.text, "[") and b.pos == a.pos + 1;
    }

    const builtin_types = [_][]const u8{ "u8", "u16", "u24", "u32", "u48", "u64", "u96", "u128", "s8", "s16", "s24", "s32", "s48", "s64", "s96", "s128", "float", "double", "char", "char16", "bool", "str", "padding", "auto" };

    fn isBuiltinType(name: []const u8) bool {
        for (builtin_types) |b| if (std.mem.eql(u8, b, name)) return true;
        return false;
    }

    fn primary(self: *Parser) ParseError!*const Expr {
        const t = self.cur();
        switch (t.kind) {
            .int => {
                self.i += 1;
                return self.make(.{ .int = t.int });
            },
            .char => {
                self.i += 1;
                return self.make(.{ .int = t.int });
            },
            .float => {
                self.i += 1;
                return self.make(.{ .float = t.float });
            },
            .str => {
                self.i += 1;
                return self.make(.{ .str = t.text });
            },
            .punct => {
                if (self.acceptPunct("(")) {
                    const e = try self.expr();
                    try self.expectPunct(")");
                    return e;
                }
                if (self.acceptPunct("$")) return self.make(.dollar);
                return self.fail("unexpected '{s}' in an expression", .{t.text});
            },
            .ident => {
                const eql = std.mem.eql;
                if (eql(u8, t.text, "true")) {
                    self.i += 1;
                    return self.make(.{ .boolean = true });
                }
                if (eql(u8, t.text, "false")) {
                    self.i += 1;
                    return self.make(.{ .boolean = false });
                }
                if (eql(u8, t.text, "this")) {
                    self.i += 1;
                    return self.make(.this);
                }
                if (eql(u8, t.text, "parent")) {
                    self.i += 1;
                    return self.make(.parent);
                }
                if (eql(u8, t.text, "null")) {
                    self.i += 1;
                    return self.make(.null_);
                }
                if (eql(u8, t.text, "sizeof") or eql(u8, t.text, "addressof") or eql(u8, t.text, "typenameof")) {
                    self.i += 1;
                    try self.expectPunct("(");
                    const is_size = eql(u8, t.text, "sizeof");
                    var result: *const Expr = undefined;
                    if (is_size) {
                        // A type or a value.
                        const save = self.i;
                        if (self.tryType()) |ty| {
                            if (self.isPunct(")")) {
                                result = try self.make(.{ .sizeof = .{ .ty = ty } });
                            } else {
                                self.i = save;
                                result = try self.make(.{ .sizeof = .{ .expr = try self.expr() } });
                            }
                        } else {
                            self.i = save;
                            result = try self.make(.{ .sizeof = .{ .expr = try self.expr() } });
                        }
                    } else {
                        const inner = try self.expr();
                        result = if (eql(u8, t.text, "addressof")) try self.make(.{ .addressof = inner }) else try self.make(.{ .sizeof = .{ .expr = inner } });
                        if (!eql(u8, t.text, "addressof")) result = try self.make(.{ .call = .{ .callee = try self.make(.{ .path = &.{"typenameof"} }), .args = &.{inner} } });
                    }
                    try self.expectPunct(")");
                    return result;
                }
                // A conversion such as u8(x).
                if (isBuiltinType(t.text) and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, "(")) {
                    self.i += 2;
                    const inner = try self.expr();
                    try self.expectPunct(")");
                    const ty = try self.arena.create(TypeExpr);
                    ty.* = .{ .path = try self.arena.dupe([]const u8, &.{t.text}) };
                    return self.make(.{ .cast = .{ .ty = ty, .e = inner } });
                }
                var parts: std.ArrayList([]const u8) = .empty;
                try parts.append(self.arena, try self.ident());
                while (self.isPunct("::") and self.peekAt(1).kind == .ident) {
                    self.i += 1;
                    try parts.append(self.arena, try self.ident());
                }
                // `Type<args>(...)` is not supported; a path is a name.
                return self.make(.{ .path = parts.items });
            },
            .end => return self.fail("the file ends in the middle of an expression", .{}),
        }
    }

    // -- types --

    /// Parses a type if one starts here, else returns null (position unspecified).
    fn tryType(self: *Parser) ?*const TypeExpr {
        const save = self.i;
        const ty = self.parseType() catch {
            self.i = save;
            self.failure = null;
            return null;
        };
        return ty;
    }

    fn parseType(self: *Parser) ParseError!*const TypeExpr {
        var endian: Endian = .default;
        if (self.isWord("be") and self.peekAt(1).kind == .ident) {
            endian = .big;
            self.i += 1;
        } else if (self.isWord("le") and self.peekAt(1).kind == .ident) {
            endian = .little;
            self.i += 1;
        }
        _ = self.acceptWord("const");
        var parts: std.ArrayList([]const u8) = .empty;
        // `builtin::...` and `auto` style names, with namespaces.
        try parts.append(self.arena, try self.ident());
        while (self.isPunct("::") and self.peekAt(1).kind == .ident) {
            self.i += 1;
            try parts.append(self.arena, try self.ident());
        }
        var args: std.ArrayList(TypeArg) = .empty;
        if (self.isPunct("<")) {
            self.i += 1;
            while (!self.isPunct(">")) {
                const save = self.i;
                if (self.tryType()) |t| {
                    if (self.isPunct(",") or self.isPunct(">")) {
                        try args.append(self.arena, .{ .ty = t });
                        if (!self.acceptPunct(",")) break;
                        continue;
                    }
                }
                self.i = save;
                self.failure = null;
                // An expression argument; `>` ends it, so parse below comparisons.
                try args.append(self.arena, .{ .expr = try self.binaryLevel(7) });
                if (!self.acceptPunct(",")) break;
            }
            try self.expectPunct(">");
        }
        const ty = try self.arena.create(TypeExpr);
        ty.* = .{ .endian = endian, .path = parts.items, .args = args.items };
        return ty;
    }

    // -- attributes --

    fn attributes(self: *Parser) ParseError![]const Attr {
        var out: std.ArrayList(Attr) = .empty;
        while (self.isPunct("[") and self.peekIsAttrOpen()) {
            self.i += 2;
            while (true) {
                const name = try self.ident();
                var args: std.ArrayList(*const Expr) = .empty;
                if (self.acceptPunct("(")) {
                    while (!self.isPunct(")")) {
                        try args.append(self.arena, try self.expr());
                        if (!self.acceptPunct(",")) break;
                    }
                    try self.expectPunct(")");
                }
                // `hex::visualize` style names keep their last part.
                var attr_name = name;
                while (self.isPunct("::")) {
                    self.i += 1;
                    attr_name = try self.ident();
                }
                if (self.acceptPunct("(")) {
                    while (!self.isPunct(")")) {
                        try args.append(self.arena, try self.expr());
                        if (!self.acceptPunct(",")) break;
                    }
                    try self.expectPunct(")");
                }
                try out.append(self.arena, .{ .name = attr_name, .args = args.items });
                if (!self.acceptPunct(",")) break;
            }
            try self.expectPunct("]");
            try self.expectPunct("]");
        }
        return out.items;
    }

    // -- statements --

    fn block(self: *Parser) ParseError![]const Stmt {
        try self.expectPunct("{");
        var out: std.ArrayList(Stmt) = .empty;
        while (!self.isPunct("}")) {
            if (self.cur().kind == .end) return self.fail("a '{{' is never closed", .{});
            try out.append(self.arena, try self.statement());
        }
        self.i += 1;
        return out.items;
    }

    /// A braced block or a single statement.
    fn body(self: *Parser) ParseError![]const Stmt {
        if (self.isPunct("{")) return self.block();
        const one = try self.arena.alloc(Stmt, 1);
        one[0] = try self.statement();
        return one;
    }

    fn params(self: *Parser) ParseError![]const Param {
        var out: std.ArrayList(Param) = .empty;
        if (!self.acceptPunct("(")) return out.items;
        while (!self.isPunct(")")) {
            _ = self.acceptWord("ref");
            if (self.isPunct(".")) return self.fail("variadic parameters are not supported", .{});
            const ty = try self.parseType();
            if (self.isPunct(".")) return self.fail("variadic parameters are not supported", .{});
            const name = try self.ident();
            var default: ?*const Expr = null;
            if (self.acceptPunct("=")) default = try self.expr();
            try out.append(self.arena, .{ .name = name, .ty = ty, .default = default });
            if (!self.acceptPunct(",")) break;
        }
        try self.expectPunct(")");
        return out.items;
    }

    fn templateParams(self: *Parser) ParseError![]const Param {
        var out: std.ArrayList(Param) = .empty;
        if (!self.isPunct("<")) return out.items;
        self.i += 1;
        while (!self.isPunct(">")) {
            if (self.acceptWord("auto")) {
                try out.append(self.arena, .{ .name = try self.ident(), .ty = null });
            } else {
                // `Type`, or `u32 N`.
                const first = try self.ident();
                if (self.cur().kind == .ident) {
                    try out.append(self.arena, .{ .name = try self.ident(), .ty = null });
                } else try out.append(self.arena, .{ .name = first, .ty = null, .is_type = true });
            }
            if (!self.acceptPunct(",")) break;
        }
        try self.expectPunct(">");
        return out.items;
    }

    fn defStmt(self: *Parser, d: Def) ParseError!Stmt {
        const p = try self.arena.create(Def);
        p.* = d;
        return .{ .def = p };
    }

    fn statement(self: *Parser) ParseError!Stmt {
        const t = self.cur();
        if (t.kind == .punct) {
            if (self.acceptPunct(";")) return .nop;
            if (self.isPunct("{")) return .{ .block = try self.block() };
        }
        if (t.kind == .ident) {
            const eql = std.mem.eql;
            const w = t.text;
            if (eql(u8, w, "import")) {
                // Imports are collected by the caller from the token stream.
                self.i += 1;
                while (!self.isPunct(";") and self.cur().kind != .end) self.i += 1;
                _ = self.acceptPunct(";");
                return .nop;
            }
            if (eql(u8, w, "namespace")) {
                self.i += 1;
                _ = self.acceptWord("auto");
                var name: std.ArrayList(u8) = .empty;
                try name.appendSlice(self.arena, try self.ident());
                while (self.acceptPunct("::")) {
                    try name.appendSlice(self.arena, "::");
                    try name.appendSlice(self.arena, try self.ident());
                }
                const saved = self.ns;
                self.ns = if (saved.len > 0) try std.fmt.allocPrint(self.arena, "{s}::{s}", .{ saved, name.items }) else name.items;
                defer self.ns = saved;
                return .{ .block = try self.block() };
            }
            if (eql(u8, w, "struct") or eql(u8, w, "union")) {
                self.i += 1;
                const name = try self.ident();
                const tparams = try self.templateParams();
                var parent: ?*const TypeExpr = null;
                if (self.acceptPunct(":")) parent = try self.parseType();
                if (self.acceptPunct(";")) return .nop; // forward declaration
                const stmts = try self.block();
                const attrs = try self.attributes();
                _ = self.acceptPunct(";");
                return self.defStmt(.{ .struct_ = .{ .name = name, .params = tparams, .parent = parent, .body = stmts, .attrs = attrs, .is_union = eql(u8, w, "union"), .ns = self.ns } });
            }
            if (eql(u8, w, "enum")) {
                self.i += 1;
                const name = try self.ident();
                try self.expectPunct(":");
                const base = try self.parseType();
                try self.expectPunct("{");
                var entries: std.ArrayList(EnumEntry) = .empty;
                while (!self.isPunct("}")) {
                    const en = try self.ident();
                    var value: ?*const Expr = null;
                    var hi: ?*const Expr = null;
                    if (self.acceptPunct("=")) {
                        value = try self.expr();
                        if (self.isPunct(".") and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, ".")) {
                            self.i += 3;
                            hi = try self.expr();
                        }
                    }
                    try entries.append(self.arena, .{ .name = en, .value = value, .hi = hi });
                    if (!self.acceptPunct(",")) break;
                }
                try self.expectPunct("}");
                _ = try self.attributes();
                _ = self.acceptPunct(";");
                return self.defStmt(.{ .enum_ = .{ .name = name, .base = base, .entries = entries.items, .ns = self.ns } });
            }
            if (eql(u8, w, "bitfield")) {
                self.i += 1;
                const name = try self.ident();
                const tparams = try self.templateParams();
                try self.expectPunct("{");
                var entries: std.ArrayList(BitEntry) = .empty;
                while (!self.isPunct("}")) {
                    if (self.acceptPunct(";")) continue;
                    if (self.isWord("padding")) {
                        self.i += 1;
                        try self.expectPunct(":");
                        const bits = try self.expr();
                        try self.expectPunct(";");
                        try entries.append(self.arena, .{ .name = "padding", .bits = bits, .is_padding = true, .attrs = &.{} });
                        continue;
                    }
                    if (self.isWord("if") or self.isWord("match")) return self.fail("conditions inside a bitfield are not supported", .{});
                    // Computed values: `x = expr;` or `u32 x = expr;`.
                    if (self.cur().kind == .ident and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, "=")) {
                        const vn = try self.ident();
                        self.i += 1;
                        const value = try self.expr();
                        try self.expectPunct(";");
                        try entries.append(self.arena, .{ .name = vn, .bits = null, .is_padding = false, .attrs = &.{}, .value = value });
                        continue;
                    }
                    if (self.cur().kind == .ident and self.peekAt(1).kind == .ident and self.peekAt(2).kind == .punct and std.mem.eql(u8, self.peekAt(2).text, "=")) {
                        self.i += 1;
                        const vn = try self.ident();
                        self.i += 1;
                        const value = try self.expr();
                        try self.expectPunct(";");
                        try entries.append(self.arena, .{ .name = vn, .bits = null, .is_padding = false, .attrs = &.{}, .value = value });
                        continue;
                    }
                    // `Type name : bits;` or `name : bits;` or `Enum name : bits;`
                    var ty: ?*const TypeExpr = null;
                    if (self.peekAt(1).kind == .ident) ty = try self.parseType();
                    const en = try self.ident();
                    try self.expectPunct(":");
                    const bits = try self.expr();
                    const attrs = try self.attributes();
                    try self.expectPunct(";");
                    try entries.append(self.arena, .{ .name = en, .bits = bits, .ty = ty, .is_padding = false, .attrs = attrs });
                }
                try self.expectPunct("}");
                const attrs = try self.attributes();
                _ = self.acceptPunct(";");
                return self.defStmt(.{ .bitfield = .{ .name = name, .params = tparams, .entries = entries.items, .attrs = attrs, .ns = self.ns } });
            }
            if (eql(u8, w, "using")) {
                self.i += 1;
                const name = try self.ident();
                const tparams = try self.templateParams();
                var target: ?*const TypeExpr = null;
                if (self.acceptPunct("=")) target = try self.parseType();
                _ = try self.attributes();
                try self.expectPunct(";");
                return self.defStmt(.{ .using = .{ .name = name, .params = tparams, .target = target, .ns = self.ns } });
            }
            if (eql(u8, w, "fn")) {
                self.i += 1;
                const name = try self.ident();
                const ps = try self.params();
                const stmts = try self.block();
                _ = self.acceptPunct(";");
                return self.defStmt(.{ .func = .{ .name = name, .params = ps, .body = stmts, .ns = self.ns } });
            }
            if (eql(u8, w, "if")) {
                self.i += 1;
                try self.expectPunct("(");
                const cond = try self.expr();
                try self.expectPunct(")");
                const then = try self.body();
                var else_: []const Stmt = &.{};
                if (self.acceptWord("else")) else_ = try self.body();
                return .{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } };
            }
            if (eql(u8, w, "while")) {
                self.i += 1;
                try self.expectPunct("(");
                const cond = try self.expr();
                try self.expectPunct(")");
                return .{ .while_ = .{ .cond = cond, .body = try self.body() } };
            }
            if (eql(u8, w, "for")) {
                self.i += 1;
                try self.expectPunct("(");
                var init: std.ArrayList(Stmt) = .empty;
                self.in_for = true;
                defer self.in_for = false;
                if (!self.isPunct(";") and !self.isPunct(",")) try init.append(self.arena, try self.simple());
                self.in_for = false;
                if (!self.acceptPunct(";")) try self.expectPunct(",");
                const cond: ?*const Expr = if (self.isPunct(";") or self.isPunct(",")) null else try self.expr();
                if (!self.acceptPunct(";")) try self.expectPunct(",");
                const step: ?*const Expr = if (self.isPunct(")")) null else try self.expr();
                try self.expectPunct(")");
                return .{ .for_ = .{ .init = init.items, .cond = cond, .step = step, .body = try self.body() } };
            }
            if (eql(u8, w, "match")) return self.matchStmt();
            if (eql(u8, w, "return")) {
                self.i += 1;
                const value: ?*const Expr = if (self.isPunct(";")) null else try self.expr();
                try self.expectPunct(";");
                return .{ .return_ = value };
            }
            if (eql(u8, w, "break")) {
                self.i += 1;
                try self.expectPunct(";");
                return .break_;
            }
            if (eql(u8, w, "continue")) {
                self.i += 1;
                try self.expectPunct(";");
                return .continue_;
            }
            if (eql(u8, w, "padding") and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, "[")) {
                self.i += 2;
                const n = try self.expr();
                try self.expectPunct("]");
                _ = try self.attributes();
                try self.expectPunct(";");
                return .{ .padding = n };
            }
        }
        const s = try self.simple();
        try self.expectPunct(";");
        return s;
    }

    /// A declaration or an expression, without the closing `;`.
    fn simple(self: *Parser) ParseError!Stmt {
        const save = self.i;
        if (self.cur().kind == .ident) {
            if (self.tryType()) |ty| {
                // `std::mem::AlignTo<4>;` instantiates a type for its effect.
                if (self.isPunct(";") and ty.args.len > 0) return .{ .decl = .{ .ty = ty, .name = "", .line = self.cur().line } };
                var pointer = false;
                if (self.isPunct("*")) pointer = true;
                if ((self.cur().kind == .ident or (pointer and self.peekAt(1).kind == .ident)) and !self.isWord("else")) {
                    if (pointer) self.i += 1;
                    const first = try self.declRest(ty, pointer);
                    if (!self.isPunct(",") or self.in_for) return .{ .decl = first };
                    // `u16 a, b;`
                    var all: std.ArrayList(Stmt) = .empty;
                    try all.append(self.arena, .{ .decl = first });
                    while (self.acceptPunct(",")) try all.append(self.arena, .{ .decl = try self.declRest(ty, false) });
                    return .{ .block = all.items };
                }
            }
            self.i = save;
            self.failure = null;
        }
        return .{ .expr = try self.expr() };
    }

    fn declRest(self: *Parser, ty: *const TypeExpr, pointer: bool) ParseError!Decl {
        const line = self.cur().line;
        const name = try self.ident();
        var d: Decl = .{ .ty = ty, .name = name, .line = line };
        if (pointer) {
            try self.expectPunct(":");
            d.pointer = try self.parseType();
        }
        if (self.isPunct("[") and !self.peekIsAttrOpen()) {
            self.i += 1;
            if (self.acceptPunct("]")) {
                d.array = .unsized;
            } else if (self.isWord("while") and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, "(")) {
                self.i += 2;
                const cond = try self.expr();
                try self.expectPunct(")");
                try self.expectPunct("]");
                d.array = .{ .while_ = cond };
            } else {
                const n = try self.expr();
                try self.expectPunct("]");
                d.array = .{ .count = n };
            }
            if (self.isPunct("[") and !self.peekIsAttrOpen()) return self.fail("arrays of arrays are not supported", .{});
        }
        if (self.isWord("in") or self.isWord("out")) self.i += 1;
        if (self.acceptPunct("@")) d.placement = try self.expr();
        if (self.acceptPunct("=")) d.init = try self.expr();
        d.attrs = try self.attributes();
        return d;
    }

    fn matchStmt(self: *Parser) ParseError!Stmt {
        self.i += 1;
        try self.expectPunct("(");
        var values: std.ArrayList(*const Expr) = .empty;
        while (!self.isPunct(")")) {
            try values.append(self.arena, try self.expr());
            if (!self.acceptPunct(",")) break;
        }
        try self.expectPunct(")");
        try self.expectPunct("{");
        var cases: std.ArrayList(MatchCase) = .empty;
        while (!self.isPunct("}")) {
            try self.expectPunct("(");
            var pats: std.ArrayList(?Pattern) = .empty;
            while (!self.isPunct(")")) {
                if (self.isWord("_")) {
                    self.i += 1;
                    try pats.append(self.arena, null);
                } else {
                    var alts: std.ArrayList(*const Expr) = .empty;
                    const first = try self.binaryLevel(3);
                    var hi: ?*const Expr = null;
                    if (self.isPunct(".") and self.peekAt(1).kind == .punct and std.mem.eql(u8, self.peekAt(1).text, ".")) {
                        self.i += 3;
                        hi = try self.binaryLevel(3);
                    }
                    while (self.isPunct("|")) {
                        self.i += 1;
                        try alts.append(self.arena, try self.binaryLevel(4));
                    }
                    try pats.append(self.arena, .{ .lo = first, .hi = hi, .alternatives = alts.items });
                }
                if (!self.acceptPunct(",")) break;
            }
            try self.expectPunct(")");
            try self.expectPunct(":");
            try cases.append(self.arena, .{ .patterns = pats.items, .body = try self.body() });
        }
        try self.expectPunct("}");
        return .{ .match = .{ .values = values.items, .cases = cases.items } };
    }
};

/// Parses `source`. On failure `failure` says where and why.
pub fn parse(arena: Allocator, source: []const u8, failure: *?Failure) ParseError!Program {
    var lexer: Lexer = .{ .arena = arena, .src = source };
    lexer.run() catch |e| {
        failure.* = lexer.failure;
        return e;
    };
    // `import a.b.c;` lines.
    var imports: std.ArrayList([]const u8) = .empty;
    for (lexer.imports.items) |i| try imports.append(arena, i);
    const toks = lexer.out.items;
    var k: usize = 0;
    while (k + 1 < toks.len) : (k += 1) {
        if (toks[k].kind == .ident and std.mem.eql(u8, toks[k].text, "import") and toks[k + 1].kind == .ident) {
            var name: std.ArrayList(u8) = .empty;
            var j = k + 1;
            while (j < toks.len and toks[j].kind == .ident) {
                if (name.items.len > 0) try name.append(arena, '/');
                try name.appendSlice(arena, toks[j].text);
                j += 1;
                if (j < toks.len and toks[j].kind == .punct and std.mem.eql(u8, toks[j].text, ".")) j += 1 else break;
            }
            try imports.append(arena, name.items);
        }
    }

    var p: Parser = .{ .arena = arena, .toks = toks };
    var stmts: std.ArrayList(Stmt) = .empty;
    while (p.cur().kind != .end) {
        const s = p.statement() catch |e| {
            failure.* = p.failure;
            return e;
        };
        try stmts.append(arena, s);
    }
    return .{ .stmts = stmts.items, .endian = lexer.endian, .imports = imports.items, .description = lexer.description };
}

/// What a pattern file says about itself in its `#pragma` lines, found without
/// parsing the program.
pub const Pragmas = struct {
    description: []const u8 = "",
    /// From `#pragma magic [ 89 50 ] @ 0x00`; empty when absent.
    magic: []const u8 = &.{},
    magic_offset: usize = 0,
    mime: []const u8 = "",
};

/// Allocates the magic bytes from `arena`; the other fields point into `source`.
pub fn pragmas(arena: Allocator, source: []const u8) Allocator.Error!Pragmas {
    var out: Pragmas = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "#pragma")) continue;
        const rest = std.mem.trim(u8, line["#pragma".len..], " \t");
        if (std.mem.startsWith(u8, rest, "description")) {
            if (out.description.len == 0) out.description = std.mem.trim(u8, rest["description".len..], " \t");
        } else if (std.mem.startsWith(u8, rest, "MIME")) {
            if (out.mime.len == 0) out.mime = std.mem.trim(u8, rest["MIME".len..], " \t");
        } else if (std.mem.startsWith(u8, rest, "magic") and out.magic.len == 0) {
            const open = std.mem.indexOfScalar(u8, rest, '[') orelse continue;
            const close = std.mem.indexOfScalarPos(u8, rest, open, ']') orelse continue;
            var bytes: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, rest[open + 1 .. close], " \t,");
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, "??")) {
                    bytes.clearRetainingCapacity();
                    break;
                }
                try bytes.append(arena, std.fmt.parseInt(u8, tok, 16) catch {
                    bytes.clearRetainingCapacity();
                    break;
                });
            }
            out.magic = bytes.items;
            if (std.mem.indexOfScalarPos(u8, rest, close, '@')) |at| {
                const v = std.mem.trim(u8, rest[at + 1 ..], " \t");
                out.magic_offset = if (std.mem.startsWith(u8, v, "0x")) (std.fmt.parseInt(usize, v[2..], 16) catch 0) else (std.fmt.parseInt(usize, v, 10) catch 0);
            }
        }
    }
    return out;
}

test "pragmas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try pragmas(arena.allocator(), "#pragma description PNG image\n#pragma magic [ 89 50 4E 47 ] @ 0x00\n#pragma MIME image/png\nstruct X {};");
    try std.testing.expectEqualStrings("PNG image", p.description);
    try std.testing.expectEqual(@as(usize, 4), p.magic.len);
    try std.testing.expectEqual(@as(u8, 0x89), p.magic[0]);
    try std.testing.expectEqualStrings("image/png", p.mime);
}

test "parses a struct, enum and placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: ?Failure = null;
    const prog = try parse(arena.allocator(),
        \\#pragma endian big
        \\#define K 4
        \\enum E : u8 { A, B = 5 };
        \\struct S { u8 a; E e; char s[K]; u16 xs[while($ < 8)]; if (a == 1) { u8 b; } else u8 c; } [[name("x")]];
        \\S s @ 0x10;
    , &failure);
    try std.testing.expectEqual(Endian.big, prog.endian);
    try std.testing.expectEqual(@as(usize, 3), prog.stmts.len);
    try std.testing.expect(prog.stmts[0] == .def and prog.stmts[0].def.* == .enum_);
    const st = prog.stmts[1].def.struct_;
    try std.testing.expectEqual(@as(usize, 5), st.body.len);
    try std.testing.expectEqualStrings("name", st.attrs[0].name);
    try std.testing.expect(prog.stmts[2].decl.placement != null);
}

test "templates, shifts and match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: ?Failure = null;
    const prog = try parse(arena.allocator(),
        \\struct W<T, auto N> { T v[N >> 1]; };
        \\struct M { u8 k; match (k) { (1 | 2): u8 a; (3 ... 5): u16 b; (_): u32 c; } };
        \\W<u8, 4> w @ 0;
        \\fn f(u32 x) { return x + 1; };
    , &failure);
    try std.testing.expectEqual(@as(usize, 4), prog.stmts.len);
    const m = prog.stmts[1].def.struct_;
    try std.testing.expectEqual(@as(usize, 3), m.body[1].match.cases.len);
}

test "errors name the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failure: ?Failure = null;
    try std.testing.expectError(error.Syntax, parse(arena.allocator(), "struct S {\n u8 a\n};", &failure));
    try std.testing.expect(failure != null);
    try std.testing.expectEqual(@as(u32, 3), failure.?.line);
}
