//! The calculator's language, without GTK, so it is unit tested.
//!
//! An entry is parsed into a tree, then worked out with exact numbers
//! (num.zig). The same tree is worked out with plain floats when speed
//! matters: for drawing graphs and for finding where equations hold.
//!
//!   statement = expr [ "=" expr ]
//!   expr      = or-expr
//!   or-expr   = xor-expr { ("|" | "or") xor-expr }      (programmer mode)
//!   xor-expr  = and-expr { "xor" and-expr }
//!   and-expr  = shift { ("&" | "and") shift }
//!   shift     = sum { ("<<" | ">>") sum }
//!   sum       = product { ("+" | "-") product }          (a + b% = a + a·b/100)
//!   product   = unary { ("*" | "×" | "·" | "/" | "÷" | "mod") unary | unary }
//!                                                         (2π, 2(3+4): implicit ×)
//!   unary     = ("-" | "+" | "~" | "not") unary | power
//!   power     = postfix [ ("^" | "**") unary ]            (right associative)
//!   postfix   = primary { "!" | "%" | "²" | "³" }
//!   primary   = number | "(" expr ")" | "|" expr "|" | ("√" | "∛") power
//!             | name [ "(" expr { "," expr } ")" ]
//!
//! A statement with "=" is one of:
//!   x = 5             stores a variable
//!   f(x) = x² + 1     defines a function
//!   x² - 4 = 0        an equation in one unknown, solved for it

const std = @import("std");
const num = @import("num.zig");
const simplify = @import("simplify.zig");
const calculus = @import("calculus.zig");
const functions = @import("functions.zig");
const letters = @import("letters.zig");
const rich = @import("rich.zig");
const bigreal = @import("bigreal.zig");
const Number = num.Number;

pub const Angle = enum {
    degrees,
    radians,
    gradians,

    pub fn parse(text: []const u8) Angle {
        return std.meta.stringToEnum(Angle, text) orelse .degrees;
    }
};

pub const Mode = struct {
    angle: Angle = .degrees,
    /// Programmer mode: whole numbers only, in a word of `bits`, typed in `base`.
    programmer: bool = false,
    base: u8 = 10,
    bits: u8 = 64,
    /// Formulas: "A = π·r²" is always an equation (never stores A).
    solve_only: bool = false,
};

pub const Error = error{
    Syntax,
    DivisionByZero,
    Domain,
    UnknownName,
    TooLarge,
    NotInteger,
    WrongArguments,
    TooManyUnknowns,
    NoSolution,
    Recursion,
    /// Units that cannot be added or converted.
    Units,
    /// A currency without an exchange rate yet.
    NoRates,
    OutOfMemory,
};

/// Where an error is and what it names, for the message.
pub const Problem = struct {
    pos: usize = 0,
    name: []const u8 = "",
};

// ---- the tree -------------------------------------------------------------------

pub const Op = enum { add, sub, mul, div, mod, pow, add_pct, sub_pct, band, bor, bxor, shl, shr };
pub const UOp = enum { neg, bnot, fact, pct };

pub const Node = union(enum) {
    number: Number,
    name: struct { text: []const u8, pos: usize },
    unary: struct { op: UOp, arg: *Node },
    binary: struct { op: Op, l: *Node, r: *Node },
    call: struct { name: []const u8, args: []*Node, pos: usize },
};

pub const Statement = union(enum) {
    expr: *Node,
    equation: struct { l: *Node, r: *Node },
};

// ---- parsing ----------------------------------------------------------------------

const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    mode: Mode,
    pos: usize = 0,
    depth: usize = 0,
    problem: *Problem,

    fn fail(self: *Parser, e: Error) Error {
        self.problem.pos = @min(self.pos, self.text.len);
        return e;
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }

    fn rest(self: *Parser) []const u8 {
        return self.text[self.pos..];
    }

    fn eat(self: *Parser, token: []const u8) bool {
        self.skipSpace();
        if (std.mem.startsWith(u8, self.rest(), token)) {
            self.pos += token.len;
            return true;
        }
        return false;
    }

    /// A word operator ("mod", "and"): only as a whole word.
    fn eatWord(self: *Parser, word: []const u8) bool {
        self.skipSpace();
        const r = self.rest();
        if (!std.ascii.startsWithIgnoreCase(r, word)) return false;
        if (r.len > word.len and isNameChar(r[word.len])) return false;
        self.pos += word.len;
        return true;
    }

    fn node(self: *Parser, n: Node) Error!*Node {
        const p = try self.a.create(Node);
        p.* = n;
        return p;
    }

    fn binary(self: *Parser, op: Op, l: *Node, r: *Node) Error!*Node {
        return self.node(.{ .binary = .{ .op = op, .l = l, .r = r } });
    }

    /// The length of a conversion word at the start of `r`: "to", "→", or "in"
    /// when something follows that is not an operator ("5 in" is inches).
    fn convertWord(r: []const u8) ?usize {
        if (std.mem.startsWith(u8, r, "→")) return "→".len;
        const is_to = std.ascii.startsWithIgnoreCase(r, "to") and (r.len == 2 or !isNameChar(r[2]));
        if (is_to) return 2;
        if (std.ascii.startsWithIgnoreCase(r, "in") and (r.len == 2 or !isNameChar(r[2]))) {
            const after = std.mem.trim(u8, r[2..], " \t");
            if (after.len == 0 or std.mem.indexOfScalar(u8, "+-*/^)=,;&|<>", after[0]) != null) return null;
            // "3 in to cm": inches, then the conversion.
            if (convertWord(after) != null and !std.ascii.startsWithIgnoreCase(after, "in")) return null;
            return 2;
        }
        return null;
    }

    /// "… to km/h": the amount in other units, as to(amount, units).
    fn withConversion(self: *Parser, l: *Node) Error!*Node {
        self.skipSpace();
        const skip = convertWord(self.rest()) orelse return l;
        self.pos += skip;
        const target = try self.expr();
        const args = try self.a.alloc(*Node, 2);
        args[0] = l;
        args[1] = target;
        return self.node(.{ .call = .{ .name = "to", .args = args, .pos = self.pos } });
    }

    fn statement(self: *Parser) Error!Statement {
        const l = try self.withConversion(try self.expr());
        self.skipSpace();
        if (self.eat("=")) {
            const r = try self.withConversion(try self.expr());
            self.skipSpace();
            if (self.pos != self.text.len) return self.fail(error.Syntax);
            return .{ .equation = .{ .l = l, .r = r } };
        }
        if (self.pos != self.text.len) return self.fail(error.Syntax);
        return .{ .expr = l };
    }

    fn expr(self: *Parser) Error!*Node {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 200) return self.fail(error.Syntax);
        return self.orExpr();
    }

    fn orExpr(self: *Parser) Error!*Node {
        var l = try self.xorExpr();
        // "|" is OR only in programmer mode; elsewhere |x| is the absolute value.
        while ((self.mode.programmer and self.eat("|")) or self.eatWord("or")) l = try self.binary(.bor, l, try self.xorExpr());
        return l;
    }

    fn xorExpr(self: *Parser) Error!*Node {
        var l = try self.andExpr();
        while (self.eatWord("xor")) l = try self.binary(.bxor, l, try self.andExpr());
        return l;
    }

    fn andExpr(self: *Parser) Error!*Node {
        var l = try self.compare();
        while (self.eat("&") or self.eatWord("and")) l = try self.binary(.band, l, try self.compare());
        return l;
    }

    /// a < b, a <= b, a > b, a >= b, a != b (also ≤ ≥ ≠): 1 or 0, shown as true or false.
    fn compare(self: *Parser) Error!*Node {
        const l = try self.shift();
        self.skipSpace();
        const r = self.rest();
        const table = [_]struct { tok: []const u8, name: []const u8 }{
            .{ .tok = "<=", .name = "le" },  .{ .tok = ">=", .name = "ge" },  .{ .tok = "!=", .name = "ne" },
            .{ .tok = "≤", .name = "le" },   .{ .tok = "≥", .name = "ge" },   .{ .tok = "≠", .name = "ne" },
            .{ .tok = "<>", .name = "ne" },
        };
        var cmp_name: []const u8 = "";
        var skip: usize = 0;
        for (table) |e| if (std.mem.startsWith(u8, r, e.tok)) {
            cmp_name = e.name;
            skip = e.tok.len;
            break;
        };
        if (skip == 0 and r.len > 0 and (r[0] == '<' or r[0] == '>') and !(r.len > 1 and r[1] == r[0])) {
            cmp_name = if (r[0] == '<') "lt" else "gt";
            skip = 1;
        }
        if (skip == 0) return l;
        self.pos += skip;
        const rhs = try self.shift();
        const args = try self.a.alloc(*Node, 2);
        args[0] = l;
        args[1] = rhs;
        return self.node(.{ .call = .{ .name = cmp_name, .args = args, .pos = self.pos } });
    }

    fn shift(self: *Parser) Error!*Node {
        var l = try self.sum();
        while (true) {
            if (self.eat("<<")) {
                l = try self.binary(.shl, l, try self.sum());
            } else if (self.eat(">>")) {
                l = try self.binary(.shr, l, try self.sum());
            } else return l;
        }
    }

    fn sum(self: *Parser) Error!*Node {
        var l = try self.product();
        while (true) {
            const plus = self.eat("+");
            const minus = !plus and (self.eat("-") or self.eat("−"));
            if (!plus and !minus) return l;
            const r = try self.product();
            // 50 + 10% is 55, as on a desk calculator.
            if (r.* == .unary and r.unary.op == .pct) {
                l = try self.binary(if (plus) .add_pct else .sub_pct, l, r.unary.arg);
            } else l = try self.binary(if (plus) .add else .sub, l, r);
        }
    }

    fn product(self: *Parser) Error!*Node {
        var l = try self.unary();
        while (true) {
            const loop_start = self.pos;
            if (self.eat("*") or self.eat("×") or self.eat("·") or self.eat("⋅")) {
                l = try self.binary(.mul, l, try self.unary());
            } else if (self.eat("/") or self.eat("÷")) {
                // As Qalculate reads it: after " / " the divisor is everything
                // juxtaposed (10 m / 2 s); after "/" only what touches it (1/2π is 1/(2π),
                // 1/2 π is π/2).
                const spaced_slash = loop_start < self.text.len and (self.text[loop_start] == ' ' or self.text[loop_start] == '\t');
                var r = try self.unary();
                while (true) {
                    const here = self.pos;
                    self.skipSpace();
                    const spaced = self.pos > here;
                    // Brackets keep the written order (the guide's 6 ÷ 2(1 + 2) is 9).
                    if ((spaced_slash or !spaced) and self.pos < self.text.len and self.text[self.pos] != '(' and self.text[self.pos] != '[' and self.implicitNext()) {
                        r = try self.binary(.mul, r, try self.power());
                    } else {
                        self.pos = here;
                        break;
                    }
                }
                l = try self.binary(.div, l, r);
            } else if (l.* == .unary and l.unary.op == .pct and self.eatWord("of")) {
                // 20% of 50 is 10.
                l = try self.binary(.mul, l, try self.unary());
            } else if (self.eatWord("mod")) {
                l = try self.binary(.mod, l, try self.unary());
            } else if (self.implicitNext()) {
                l = try self.binary(.mul, l, try self.power());
            } else return l;
        }
    }

    /// 2π, 2x, 2(3+4), (1+2)(3+4), 3sin(30): a factor right after another,
    /// with no space between.
    fn implicitNext(self: *Parser) bool {
        if (self.pos >= self.text.len) return false;
        const r = self.rest();
        const c = r[0];
        if (c == '(' or c == '[') return true;
        if (std.mem.startsWith(u8, r, "√") or std.mem.startsWith(u8, r, "∛")) return true;
        if (isNameStart(r)) {
            // Not a word operator.
            inline for (.{ "mod", "and", "or", "xor", "not", "of" }) |w| {
                if (std.ascii.startsWithIgnoreCase(r, w) and (r.len == w.len or !isNameChar(r[w.len]))) return false;
            }
            if (convertWord(r) != null) return false;
            return true;
        }
        // A number right after ")".
        return std.ascii.isDigit(c) and self.pos > 0 and self.text[self.pos - 1] == ')';
    }

    fn unary(self: *Parser) Error!*Node {
        if (self.eat("-") or self.eat("−")) return self.node(.{ .unary = .{ .op = .neg, .arg = try self.unary() } });
        if (self.eat("+")) return self.unary();
        if (self.eat("~") or self.eatWord("not")) return self.node(.{ .unary = .{ .op = .bnot, .arg = try self.unary() } });
        return self.power();
    }

    fn power(self: *Parser) Error!*Node {
        const base = try self.postfix();
        if (self.eat("^") or self.eat("**")) return self.binary(.pow, base, try self.unary());
        return base;
    }

    fn postfix(self: *Parser) Error!*Node {
        var v = try self.primary();
        while (true) {
            self.skipSpace();
            const here = self.rest();
            if (std.mem.startsWith(u8, here, "!=")) return v;
            if (std.mem.startsWith(u8, here, "!!") and !std.mem.startsWith(u8, here, "!!=")) {
                // 7!! is the double factorial 7·5·3·1.
                self.pos += 2;
                const args = try self.a.alloc(*Node, 1);
                args[0] = v;
                v = try self.node(.{ .call = .{ .name = "factorial2", .args = args, .pos = self.pos } });
            } else if (self.eat("!")) {
                v = try self.node(.{ .unary = .{ .op = .fact, .arg = v } });
            } else if (self.eat("%")) {
                v = try self.node(.{ .unary = .{ .op = .pct, .arg = v } });
            } else if (self.eat("²")) {
                v = try self.binary(.pow, v, try self.node(.{ .number = try num.fromInt(self.a, 2) }));
            } else if (self.eat("³")) {
                v = try self.binary(.pow, v, try self.node(.{ .number = try num.fromInt(self.a, 3) }));
            } else return v;
        }
    }

    fn primary(self: *Parser) Error!*Node {
        self.skipSpace();
        if (self.pos >= self.text.len) return self.fail(error.Syntax);
        const r = self.rest();
        if (r[0] == '(') {
            self.pos += 1;
            const v = try self.expr();
            if (!self.eat(")")) return self.fail(error.Syntax);
            return v;
        }
        if (r[0] == '[') return self.matrixLiteral();
        if (r[0] == '|' and self.mode.programmer == false) {
            self.pos += 1;
            const v = try self.expr();
            if (!self.eat("|")) return self.fail(error.Syntax);
            return self.call1("abs", v);
        }
        if (self.eat("√")) return self.call1("sqrt", try self.power());
        if (self.eat("∛")) return self.call1("cbrt", try self.power());
        if (try self.number()) |n| return n;
        if (isNameStart(r)) return self.name();
        return self.fail(error.Syntax);
    }

    /// An entry of a bracket list may be an equation: [x + y = 5; x - y = 1].
    fn exprOrEquation(self: *Parser) Error!*Node {
        const l = try self.expr();
        if (!self.eat("=")) return l;
        const r = try self.expr();
        const args = try self.a.alloc(*Node, 2);
        args[0] = l;
        args[1] = r;
        return self.node(.{ .call = .{ .name = "eq", .args = args, .pos = self.pos } });
    }

    /// [1, 2; 3, 4]: rows end with ";", entries with ",". Read as
    /// matrix(rows, cols, entries…).
    fn matrixLiteral(self: *Parser) Error!*Node {
        const start = self.pos;
        self.pos += 1;
        var items: std.ArrayList(*Node) = .empty;
        var rows: usize = 0;
        var cols: usize = 0;
        var cur: usize = 0;
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 200) return self.fail(error.Syntax);
        while (true) {
            try items.append(self.a, try self.exprOrEquation());
            cur += 1;
            const end = !self.eat(",");
            if (!end) continue;
            const row_end = self.eat(";");
            if (!row_end and !self.eat("]")) return self.fail(error.Syntax);
            if (rows == 0) cols = cur else if (cur != cols) return self.fail(error.Syntax);
            rows += 1;
            cur = 0;
            if (!row_end) break;
        }
        const args = try self.a.alloc(*Node, items.items.len + 2);
        args[0] = try self.node(.{ .number = try num.fromInt(self.a, @as(i64, @intCast(rows))) });
        args[1] = try self.node(.{ .number = try num.fromInt(self.a, @as(i64, @intCast(cols))) });
        @memcpy(args[2..], items.items);
        return self.node(.{ .call = .{ .name = "matrix", .args = args, .pos = start } });
    }

    fn call1(self: *Parser, name_: []const u8, arg: *Node) Error!*Node {
        const args = try self.a.alloc(*Node, 1);
        args[0] = arg;
        return self.node(.{ .call = .{ .name = name_, .args = args, .pos = self.pos } });
    }

    fn number(self: *Parser) Error!?*Node {
        const r = self.rest();
        const start = self.pos;
        // 0x1F, 0b101, 0o17: in any mode.
        if (r.len > 2 and r[0] == '0' and (r[1] == 'x' or r[1] == 'b' or r[1] == 'o')) {
            const base: u8 = switch (r[1]) {
                'x' => 16,
                'b' => 2,
                else => 8,
            };
            var end: usize = 2;
            while (end < r.len and digitValue(r[end]) != null and digitValue(r[end]).? < base) end += 1;
            if (end > 2) {
                self.pos += end;
                return try self.node(.{ .number = num.parseInteger(self.a, r[2..end], base) catch return self.fail(error.Syntax) });
            }
        }
        if (self.mode.programmer and self.mode.base != 10) {
            // In hex, a word of hex digits is a number, unless it is a name in use.
            var end: usize = 0;
            while (end < r.len and digitValue(r[end]) != null and digitValue(r[end]).? < self.mode.base) end += 1;
            if (end == 0) return null;
            if (end < r.len and isNameChar(r[end])) {
                if (!std.ascii.isDigit(r[0])) return null; // a name such as "abs"
            }
            if (!std.ascii.isDigit(r[0]) and isReserved(r[0..end])) return null;
            self.pos += end;
            return try self.node(.{ .number = num.parseInteger(self.a, r[0..end], self.mode.base) catch return self.fail(error.Syntax) });
        }
        if (!self.mode.programmer) if (dateLiteral(r)) {
            // 2026-12-25 is the date: date(2026, 12, 25).
            const args = try self.a.alloc(*Node, 3);
            args[0] = try self.node(.{ .number = try num.fromInt(self.a, std.fmt.parseInt(i64, r[0..4], 10) catch return self.fail(error.Syntax)) });
            args[1] = try self.node(.{ .number = try num.fromInt(self.a, std.fmt.parseInt(i64, r[5..7], 10) catch return self.fail(error.Syntax)) });
            args[2] = try self.node(.{ .number = try num.fromInt(self.a, std.fmt.parseInt(i64, r[8..10], 10) catch return self.fail(error.Syntax)) });
            self.pos += 10;
            return try self.node(.{ .call = .{ .name = "date", .args = args, .pos = start } });
        };
        if (!(std.ascii.isDigit(r[0]) or (r[0] == '.' and r.len > 1 and std.ascii.isDigit(r[1])))) return null;
        var end: usize = 0;
        while (end < r.len and (std.ascii.isDigit(r[end]) or r[end] == '.')) end += 1;
        // An exponent only when digits follow, so "2e" is 2·e.
        if (end + 1 < r.len and (r[end] == 'e' or r[end] == 'E')) {
            var look = end + 1;
            if (look < r.len and (r[look] == '+' or r[look] == '-')) look += 1;
            if (look < r.len and std.ascii.isDigit(r[look])) {
                end = look;
                while (end < r.len and std.ascii.isDigit(r[end])) end += 1;
            }
        }
        if (std.mem.count(u8, r[0..end], ".") > 1) {
            self.pos = start + end;
            return self.fail(error.Syntax);
        }
        self.pos += end;
        const n = num.parseDecimal(self.a, r[0..end]) catch |e| return self.fail(e);
        if (self.mode.programmer and !n.isInteger()) return self.fail(error.NotInteger);
        return try self.node(.{ .number = n });
    }

    fn name(self: *Parser) Error!*Node {
        const start = self.pos;
        self.pos += nameLength(self.rest());
        const ident = self.text[start..self.pos];
        if (self.pos < self.text.len and self.text[self.pos] == '(') {
            self.pos += 1;
            var args: std.ArrayList(*Node) = .empty;
            self.skipSpace();
            if (!self.eat(")")) {
                while (true) {
                    try args.append(self.a, try self.expr());
                    if (self.eat(",") or self.eat(";")) continue;
                    if (self.eat(")")) break;
                    return self.fail(error.Syntax);
                }
            }
            return self.node(.{ .call = .{ .name = ident, .args = try args.toOwnedSlice(self.a), .pos = start } });
        }
        return self.node(.{ .name = .{ .text = ident, .pos = start } });
    }
};

fn digitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Names that hex words must not hide.
fn isReserved(word: []const u8) bool {
    for ([_][]const u8{ "abs", "ans", "acos", "asin", "atan", "cbrt", "ceil", "deg", "e", "fact", "floor", "and" }) |w| {
        if (std.ascii.eqlIgnoreCase(word, w)) return true;
    }
    return false;
}

/// The Greek letter `r` starts with, and its length in bytes.
fn greekAt(r: []const u8) ?usize {
    if (r.len < 2 or r[0] < 0x80) return null;
    const n = std.unicode.utf8ByteSequenceLength(r[0]) catch return null;
    if (n > r.len) return null;
    const cp = std.unicode.utf8Decode(r[0..n]) catch return null;
    return if (letters.isGreek(cp)) n else null;
}

fn isNameStart(r: []const u8) bool {
    if (r.len == 0) return false;
    if (std.ascii.isAlphabetic(r[0]) or r[0] == '_') return true;
    if (unitMarkAt(r) != null) return true;
    return greekAt(r) != null;
}

/// ° and µ (micro sign) begin unit names: °F, µm.
fn unitMarkAt(r: []const u8) ?usize {
    if (std.mem.startsWith(u8, r, "°") or std.mem.startsWith(u8, r, "µ")) return 2;
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn nameLength(r: []const u8) usize {
    // A Greek letter is a name of its own (πr is π·r), with digits after it (θ1).
    if (greekAt(r)) |g| {
        var n = g;
        while (n < r.len and std.ascii.isDigit(r[n])) n += 1;
        return n;
    }
    var n: usize = 0;
    if (unitMarkAt(r)) |m| n = m;
    while (n < r.len and isNameChar(r[n])) n += 1;
    return n;
}

pub fn parse(a: std.mem.Allocator, raw: []const u8, mode: Mode, problem: *Problem) Error!Statement {
    const text = try letters.normalize(a, raw);
    var p: Parser = .{ .a = a, .text = text, .mode = mode, .problem = problem };
    if (std.mem.trim(u8, text, " \t").len == 0) return error.Syntax;
    return p.statement();
}

pub fn parseExpr(a: std.mem.Allocator, raw: []const u8, mode: Mode, problem: *Problem) Error!*Node {
    const text = try letters.normalize(a, raw);
    var p: Parser = .{ .a = a, .text = text, .mode = mode, .problem = problem };
    const n = try p.expr();
    p.skipSpace();
    if (p.pos != text.len) return p.fail(error.Syntax);
    return n;
}

// ---- what is remembered between calculations ------------------------------------------

/// A number kept between calculations (outside the per-calculation arena).
pub const Stored = union(enum) {
    exact: struct { num: []u8, den: []u8 },
    approx: f64,
    /// A high-precision real: the mantissa in decimal and the binary exponent.
    big: struct { mant: []u8, exp: i64 },

    pub fn deinit(self: Stored, gpa: std.mem.Allocator) void {
        switch (self) {
            .exact => |e| {
                gpa.free(e.num);
                gpa.free(e.den);
            },
            .big => |b| gpa.free(b.mant),
            .approx => {},
        }
    }

    pub fn of(gpa: std.mem.Allocator, n: Number) error{OutOfMemory}!Stored {
        return switch (n) {
            .approx => |f| .{ .approx = f },
            .big => |r| .{ .big = .{ .mant = try decimal(gpa, r.m), .exp = r.e } },
            .exact => |e| blk: {
                const ns = try decimal(gpa, e.num);
                errdefer gpa.free(ns);
                break :blk .{ .exact = .{ .num = ns, .den = try decimal(gpa, e.den) } };
            },
        };
    }

    fn decimal(gpa: std.mem.Allocator, b: std.math.big.int.Managed) error{OutOfMemory}![]u8 {
        return b.toString(gpa, 10, .lower) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // base 10 is valid
        };
    }

    pub fn load(self: Stored, a: std.mem.Allocator) Error!Number {
        return switch (self) {
            .approx => |f| .{ .approx = f },
            .big => |b| blk: {
                var m = try std.math.big.int.Managed.init(a);
                m.setString(10, b.mant) catch return error.Domain;
                break :blk .{ .big = .{ .m = m, .e = b.exp } };
            },
            .exact => |e| blk: {
                var n = try std.math.big.int.Managed.init(a);
                n.setString(10, e.num) catch return error.Domain;
                var d = try std.math.big.int.Managed.init(a);
                d.setString(10, e.den) catch return error.Domain;
                break :blk .{ .exact = .{ .num = n, .den = d } };
            },
        };
    }

    /// One line for the state file: "n/d" or "f:<float>".
    pub fn text(self: Stored, a: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .approx => |f| std.fmt.allocPrint(a, "f:{e}", .{f}),
            .big => |b| std.fmt.allocPrint(a, "b:{s}@{d}", .{ b.mant, b.exp }),
            .exact => |e| std.fmt.allocPrint(a, "{s}/{s}", .{ e.num, e.den }),
        };
    }

    pub fn fromText(gpa: std.mem.Allocator, t: []const u8) !Stored {
        if (std.mem.startsWith(u8, t, "f:")) return .{ .approx = std.fmt.parseFloat(f64, t[2..]) catch return error.Domain };
        if (std.mem.startsWith(u8, t, "b:")) {
            const at = std.mem.indexOfScalar(u8, t, '@') orelse return error.Domain;
            const mant = t[2..at];
            if (mant.len == 0 or mant.len > 200) return error.Domain;
            for (mant, 0..) |c, i| if (!(std.ascii.isDigit(c) or (i == 0 and c == '-'))) return error.Domain;
            const exp = std.fmt.parseInt(i64, t[at + 1 ..], 10) catch return error.Domain;
            if (@abs(exp) > 100_000) return error.Domain;
            return .{ .big = .{ .mant = try gpa.dupe(u8, mant), .exp = exp } };
        }
        const slash = std.mem.indexOfScalar(u8, t, '/') orelse return error.Domain;
        const n = t[0..slash];
        const d = t[slash + 1 ..];
        for (n, 0..) |c, i| if (!(std.ascii.isDigit(c) or (i == 0 and c == '-'))) return error.Domain;
        for (d) |c| if (!std.ascii.isDigit(c)) return error.Domain;
        if (n.len == 0 or d.len == 0) return error.Domain;
        return .{ .exact = .{ .num = try gpa.dupe(u8, n), .den = try gpa.dupe(u8, d) } };
    }
};

pub const Function = struct {
    params: [][]u8,
    /// The body as typed; parsed again each time it is used.
    body: []u8,

    pub fn deinit(self: Function, gpa: std.mem.Allocator) void {
        for (self.params) |p| gpa.free(p);
        gpa.free(self.params);
        gpa.free(self.body);
    }
};

/// Variables, functions and the last answer, kept for the whole session.
pub const Session = struct {
    gpa: std.mem.Allocator,
    vars: std.StringArrayHashMapUnmanaged(Stored) = .empty,
    funcs: std.StringArrayHashMapUnmanaged(Function) = .empty,
    /// Complex numbers and matrices (not saved between runs).
    rich: std.StringArrayHashMapUnmanaged(rich.Stored) = .empty,
    ans: ?Stored = null,
    rng: std.Random.DefaultPrng = .init(0x5eed),

    pub fn deinit(self: *Session) void {
        var it = self.vars.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.vars.deinit(self.gpa);
        var fit = self.funcs.iterator();
        while (fit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.funcs.deinit(self.gpa);
        var rit = self.rich.iterator();
        while (rit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.rich.deinit(self.gpa);
        if (self.ans) |s| s.deinit(self.gpa);
    }

    pub fn setVar(self: *Session, name: []const u8, value: Number) error{OutOfMemory}!void {
        if (self.rich.fetchOrderedRemove(name)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
        }
        const stored = try Stored.of(self.gpa, value);
        errdefer stored.deinit(self.gpa);
        if (self.vars.getPtr(name)) |old| {
            old.deinit(self.gpa);
            old.* = stored;
            return;
        }
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.vars.put(self.gpa, key, stored);
    }

    pub fn setRich(self: *Session, name: []const u8, value: rich.Value) error{OutOfMemory}!void {
        const stored = try rich.Stored.of(self.gpa, value);
        errdefer stored.deinit(self.gpa);
        if (self.rich.getPtr(name)) |old| {
            old.deinit(self.gpa);
            old.* = stored;
            return;
        }
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.rich.put(self.gpa, key, stored);
    }

    pub fn setAns(self: *Session, value: Number) error{OutOfMemory}!void {
        if (self.rich.fetchOrderedRemove("ans")) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
        }
        const stored = try Stored.of(self.gpa, value);
        if (self.ans) |old| old.deinit(self.gpa);
        self.ans = stored;
    }

    pub fn define(self: *Session, name: []const u8, params: []const []const u8, body: []const u8) error{OutOfMemory}!void {
        var ps = try self.gpa.alloc([]u8, params.len);
        var made: usize = 0;
        errdefer {
            for (ps[0..made]) |p| self.gpa.free(p);
            self.gpa.free(ps);
        }
        for (params, 0..) |p, i| {
            ps[i] = try self.gpa.dupe(u8, p);
            made += 1;
        }
        const f: Function = .{ .params = ps, .body = try self.gpa.dupe(u8, body) };
        if (self.funcs.getPtr(name)) |old| {
            old.deinit(self.gpa);
            old.* = f;
            return;
        }
        try self.funcs.put(self.gpa, try self.gpa.dupe(u8, name), f);
    }

    pub fn remove(self: *Session, name: []const u8) bool {
        if (self.rich.fetchOrderedRemove(name)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
            return true;
        }
        if (self.vars.fetchOrderedRemove(name)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
            return true;
        }
        if (self.funcs.fetchOrderedRemove(name)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
            return true;
        }
        return false;
    }
};

// ---- working it out -------------------------------------------------------------------

const builtin_functions = [_][]const u8{
    "sin",  "cos",   "tan",  "asin",  "acos",  "atan",  "sinh", "cosh",  "tanh",  "asinh", "acosh",  "atanh",
    "ln",   "log",   "log2", "log10", "exp",   "sqrt",  "cbrt", "root",  "abs",   "floor", "ceil",   "round",
    "trunc", "frac", "sign", "fact",  "gcd",   "lcm",   "ncr",  "npr",   "min",   "max",   "sum",    "mean",
    "avg",  "median", "stdev", "var", "mod",   "pow",   "atan2", "hypot", "rand",  "rol",  "ror",    "sec",
    "csc",  "cot",  "diff", "derivative", "integral", "integrate", "limit", "prod",
};

/// lt, le, gt, ge, ne: what a comparison in an entry is read as.
fn comparison(name: []const u8) ?void {
    inline for (.{ "lt", "le", "gt", "ge", "ne" }) |c| if (std.mem.eql(u8, name, c)) return {};
    return null;
}

fn compareNumbers(a: std.mem.Allocator, x: Number, y: Number) Error!std.math.Order {
    if (x.isExact() and y.isExact()) return num.order(a, x, y);
    const xf = x.toFloat();
    const yf = y.toFloat();
    if (@abs(xf - yf) <= 1e-12 * @max(1, @abs(xf))) return .eq;
    return if (xf < yf) .lt else .gt;
}

/// A comparison, or and/or/xor/not of them: its answer is true or false.
fn isBoolean(n: *const Node) bool {
    return switch (n.*) {
        .call => |c| comparison(c.name) != null,
        .binary => |b| (b.op == .band or b.op == .bor or b.op == .bxor) and isBoolean(b.l) and isBoolean(b.r),
        .unary => |u| u.op == .bnot and isBoolean(u.arg),
        else => false,
    };
}

pub fn isBuiltin(name: []const u8) bool {
    var buf: [48]u8 = undefined;
    if (name.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, name);
    const canon = functions.canonical(lower);
    for (builtin_functions) |f| if (std.mem.eql(u8, f, canon)) return true;
    return functions.isKnown(lower) or rich.isRichFunction(lower);
}

const constants = [_][]const u8{ "pi", "π", "e", "tau", "τ", "phi", "φ", "ans" };

pub fn isConstant(name: []const u8) bool {
    for (constants) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

/// One name bound to a value while a function's body or an equation is worked out.
pub const Binding = struct { name: []const u8, value: Number, next: ?*const Binding = null };

pub const Eval = struct {
    a: std.mem.Allocator,
    session: *Session,
    mode: Mode,
    problem: *Problem,
    depth: usize = 0,
    /// Functions' bodies, parsed once per calculation (a graph works one out thousands of times).
    bodies: std.StringHashMapUnmanaged(*Node) = .empty,

    pub fn lookupBinding(b: ?*const Binding, name: []const u8) ?Number {
        return lookup(b, name);
    }

    pub fn callPlain(self: *Eval, name: []const u8, arg_nodes: []const *Node, pos: usize, b: ?*const Binding) Error!Number {
        return self.call(name, arg_nodes, pos, b);
    }

    fn lookup(b: ?*const Binding, name: []const u8) ?Number {
        var it = b;
        while (it) |x| : (it = x.next) if (std.mem.eql(u8, x.name, name)) return x.value;
        return null;
    }

    pub fn eval(self: *Eval, n: *const Node, b: ?*const Binding) Error!Number {
        const v = try self.evalRaw(n, b);
        if (self.mode.programmer) return self.wrapInt(v);
        return v;
    }

    fn wrapInt(self: *Eval, v: Number) Error!Number {
        const i = num.int128(v) orelse return if (v.isInteger()) error.TooLarge else error.NotInteger;
        return num.fromI128(self.a, num.wrap(i, self.mode.bits));
    }

    fn int(self: *Eval, v: Number) Error!i128 {
        _ = self;
        return num.int128(v) orelse if (v.isInteger()) error.TooLarge else error.NotInteger;
    }

    fn evalRaw(self: *Eval, n: *const Node, b: ?*const Binding) Error!Number {
        const a = self.a;
        switch (n.*) {
            .number => |v| return v,
            .name => |nm| {
                if (lookup(b, nm.text)) |v| return v;
                if (self.session.vars.get(nm.text)) |s| return s.load(a);
                if (std.mem.eql(u8, nm.text, "ans")) return if (self.session.ans) |s| s.load(a) else num.fromInt(a, 0);
                if (std.mem.eql(u8, nm.text, "pi") or std.mem.eql(u8, nm.text, "π")) return num.fromReal(try bigreal.pi(a, 8));
                if (std.mem.eql(u8, nm.text, "tau") or std.mem.eql(u8, nm.text, "τ")) return num.fromReal(bigreal.scale2(try bigreal.pi(a, 8), 1));
                if (std.mem.eql(u8, nm.text, "e")) return num.fromReal(try bigreal.exp(a, try bigreal.one(a)));
                if (std.mem.eql(u8, nm.text, "phi") or std.mem.eql(u8, nm.text, "φ")) {
                    const root5 = try bigreal.sqrt(a, try bigreal.fromInt(a, 5));
                    return num.fromReal(bigreal.scale2(try bigreal.add(a, try bigreal.one(a), root5), -1));
                }
                self.problem.* = .{ .pos = nm.pos, .name = nm.text };
                return error.UnknownName;
            },
            .unary => |u| {
                const x = try self.eval(u.arg, b);
                return switch (u.op) {
                    .neg => num.neg(a, x),
                    .pct => num.div(a, x, try num.fromInt(a, 100)),
                    .fact => num.factorial(a, x),
                    .bnot => num.fromI128(a, ~(try self.int(x))),
                };
            },
            .binary => |bin| {
                const x = try self.eval(bin.l, b);
                const y = try self.eval(bin.r, b);
                return switch (bin.op) {
                    .add => num.add(a, x, y),
                    .sub => num.sub(a, x, y),
                    .mul => num.mul(a, x, y),
                    .div => if (self.mode.programmer) blk: {
                        const d = try self.int(y);
                        if (d == 0) return error.DivisionByZero;
                        break :blk num.fromI128(a, @divTrunc(try self.int(x), d));
                    } else num.div(a, x, y),
                    .mod => num.mod(a, x, y),
                    // (-8)^(1/3) is the principal complex root (cbrt(-8) is −2): leave it to rich.zig.
                    .pow => if (x.isNegative() and !y.isInteger() and !self.mode.programmer) error.Domain else num.pow(a, x, y),
                    .add_pct => num.add(a, x, try num.div(a, try num.mul(a, x, y), try num.fromInt(a, 100))),
                    .sub_pct => num.sub(a, x, try num.div(a, try num.mul(a, x, y), try num.fromInt(a, 100))),
                    .band => num.fromI128(a, (try self.int(x)) & (try self.int(y))),
                    .bor => num.fromI128(a, (try self.int(x)) | (try self.int(y))),
                    .bxor => num.fromI128(a, (try self.int(x)) ^ (try self.int(y))),
                    .shl, .shr => blk: {
                        const s = try self.int(y);
                        if (s < 0 or s > 127) return error.Domain;
                        const v = try self.int(x);
                        break :blk num.fromI128(a, if (bin.op == .shl) v << @intCast(s) else v >> @intCast(s));
                    },
                };
            },
            .call => |c| return self.call(c.name, c.args, c.pos, b),
        }
    }

    fn call(self: *Eval, name: []const u8, arg_nodes: []const *Node, pos: usize, b: ?*const Binding) Error!Number {
        const a = self.a;
        if (try self.calculusCall(name, arg_nodes, pos, b)) |v| return v;
        // The user's own functions first.
        if (self.session.funcs.get(name)) |f| {
            if (f.params.len != arg_nodes.len) {
                self.problem.* = .{ .pos = pos, .name = name };
                return error.WrongArguments;
            }
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > 64) return error.Recursion;
            var chain: ?*const Binding = null;
            for (f.params, arg_nodes) |p, an| {
                const bind = try a.create(Binding);
                bind.* = .{ .name = p, .value = try self.eval(an, b), .next = chain };
                chain = bind;
            }
            var inner: Problem = .{};
            const body = parseExpr(a, f.body, self.mode, &inner) catch |e| return e;
            return self.eval(body, chain);
        }
        // k(k + 1) where k is a value, not a function: a product.
        if (arg_nodes.len == 1 and !isBuiltin(name)) {
            const as_name: Node = .{ .name = .{ .text = name, .pos = pos } };
            const v = try self.eval(&as_name, b);
            return num.mul(a, v, try self.eval(arg_nodes[0], b));
        }
        var args = try a.alloc(Number, arg_nodes.len);
        for (arg_nodes, 0..) |an, i| args[i] = try self.eval(an, b);
        const lower = try std.ascii.allocLowerString(a, name);
        return self.builtin(lower, args) catch |e| {
            if (e == error.UnknownName or e == error.WrongArguments) self.problem.* = .{ .pos = pos, .name = name };
            return e;
        };
    }

    /// integral, limit, and sum/prod over a range: their first argument is
    /// worked out for many values, so it is not worked out first.
    fn calculusCall(self: *Eval, name: []const u8, args: []const *Node, pos: usize, b: ?*const Binding) Error!?Number {
        const a = self.a;
        const is = std.ascii.eqlIgnoreCase;
        if (is(name, "diff") or is(name, "derivative")) {
            const expanded = try calculus.expand(a, self, @constCast(&Node{ .call = .{ .name = name, .args = @constCast(args), .pos = pos } }));
            return try self.eval(expanded, b);
        }
        if (is(name, "integral") or is(name, "integrate")) {
            if (args.len != 4 or args[1].* != .name) return self.wrongArgs(name, pos);
            const lo = (try self.eval(args[2], b)).toFloat();
            const hi = (try self.eval(args[3], b)).toFloat();
            const r = try calculus.integrate(self, args[0], args[1].name.text, lo, hi);
            return try self.snap(r, 1e-11);
        }
        if (is(name, "limit")) {
            if (args.len != 3 or args[1].* != .name) return self.wrongArgs(name, pos);
            const at = try self.limitPoint(args[2], b);
            const r = try calculus.limit(self, args[0], args[1].name.text, at);
            return try self.snap(r, 1e-8);
        }
        const series = (is(name, "sum") or is(name, "prod")) and args.len == 4 and args[1].* == .name and
            !self.session.vars.contains(args[1].name.text) and calculus.uses(args[0], args[1].name.text);
        if (series or is(name, "prod") and args.len == 4) {
            if (args[1].* != .name) return self.wrongArgs(name, pos);
            const from = num.intValue(try self.eval(args[2], b)) orelse return error.NotInteger;
            const to = num.intValue(try self.eval(args[3], b)) orelse return error.NotInteger;
            if (to - from > 1_000_000) return error.TooLarge;
            const product = is(name, "prod");
            var acc = try num.fromInt(a, if (product) @as(i64, 1) else 0);
            var k = from;
            while (k <= to) : (k += 1) {
                const bind: Binding = .{ .name = args[1].name.text, .value = try num.fromInt(a, k), .next = b };
                const v = try self.eval(args[0], &bind);
                acc = if (product) try num.mul(a, acc, v) else try num.add(a, acc, v);
            }
            return acc;
        }
        return null;
    }

    fn wrongArgs(self: *Eval, name: []const u8, pos: usize) Error {
        self.problem.* = .{ .pos = pos, .name = name };
        return error.WrongArguments;
    }

    /// inf, ∞ and −inf for limits.
    fn limitPoint(self: *Eval, n: *const Node, b: ?*const Binding) Error!f64 {
        const isInf = struct {
            fn f(m: *const Node) bool {
                return m.* == .name and (std.mem.eql(u8, m.name.text, "inf") or std.mem.eql(u8, m.name.text, "∞") or std.mem.eql(u8, m.name.text, "infinity"));
            }
        }.f;
        if (isInf(n)) return std.math.inf(f64);
        if (n.* == .unary and n.unary.op == .neg and isInf(n.unary.arg)) return -std.math.inf(f64);
        return (try self.eval(n, b)).toFloat();
    }

    /// A numeric result that is (within `tol`) a simple fraction, as that fraction.
    fn snap(self: *Eval, r: f64, tol: f64) Error!Number {
        if (closeFraction(r, 1000)) |pq| {
            const f = @as(f64, @floatFromInt(pq[0])) / @as(f64, @floatFromInt(pq[1]));
            if (@abs(f - r) <= tol * @max(1, @abs(r))) return num.div(self.a, try num.fromInt(self.a, pq[0]), try num.fromInt(self.a, pq[1]));
        }
        return num.fromFloat(r);
    }

    fn toRad(self: *Eval, x: f64) f64 {
        return switch (self.mode.angle) {
            .degrees => x * std.math.pi / 180,
            .radians => x,
            .gradians => x * std.math.pi / 200,
        };
    }

    fn fromRad(self: *Eval, x: f64) f64 {
        return switch (self.mode.angle) {
            .degrees => x * 180 / std.math.pi,
            .radians => x,
            .gradians => x * 200 / std.math.pi,
        };
    }

    /// sin, cos and tan of whole multiples of 30° (and 45°) exactly.
    /// An angle as radians, to full precision.
    fn bigRad(self: *Eval, x: Number) Error!bigreal.Real {
        const a = self.a;
        const r = try num.toReal(a, x);
        const full: i64 = switch (self.mode.angle) {
            .radians => return r,
            .degrees => 180,
            .gradians => 200,
        };
        return bigreal.div(a, try bigreal.mul(a, r, try bigreal.pi(a, 8)), try bigreal.fromInt(a, full));
    }

    /// Radians as an angle in the chosen unit, to full precision.
    fn bigFromRad(self: *Eval, r: bigreal.Real) Error!bigreal.Real {
        const a = self.a;
        const full: i64 = switch (self.mode.angle) {
            .radians => return r,
            .degrees => 180,
            .gradians => 200,
        };
        return bigreal.div(a, try bigreal.mul(a, r, try bigreal.fromInt(a, full)), try bigreal.pi(a, 8));
    }

    /// The elementary functions of an exact or high-precision argument, to about 70 digits
    /// (null for the functions and arguments that go through plain floats instead).
    fn highFunction(self: *Eval, f: []const u8, x: Number) Error!?Number {
        const a = self.a;
        const eql = std.mem.eql;
        if (x == .approx) return null;
        const zero = try num.fromInt(a, 0);
        const one = try num.fromInt(a, 1);
        if (eql(u8, f, "sqrt")) {
            if (x.isNegative()) return error.Domain;
            if (try num.root(a, x, 2)) |r| return r;
            return num.fromReal(try bigreal.sqrt(a, try num.toReal(a, x)));
        }
        if (eql(u8, f, "cbrt")) {
            if (try num.root(a, x, 3)) |r| return r;
            if (x.isZero()) return zero;
            const r = try num.toReal(a, bigAbs(x));
            const root = try bigreal.pow(a, r, try bigreal.div(a, try bigreal.one(a), try bigreal.fromInt(a, 3)));
            return num.fromReal(if (x.isNegative()) try bigreal.neg(a, root) else root);
        }
        if (eql(u8, f, "sin") or eql(u8, f, "cos") or eql(u8, f, "tan") or eql(u8, f, "sec") or eql(u8, f, "csc") or eql(u8, f, "cot")) {
            if (eql(u8, f, "sin") or eql(u8, f, "cos") or eql(u8, f, "tan")) {
                if (try self.exactTrig(f, x)) |v| return v;
            }
            if (x.isZero()) {
                if (eql(u8, f, "sin") or eql(u8, f, "tan")) return zero;
                if (eql(u8, f, "cos") or eql(u8, f, "sec")) return one;
                return error.Domain; // csc, cot
            }
            const sc = bigreal.sinCos(a, try self.bigRad(x)) catch |e| return if (e == error.TooLarge) null else e;
            const tiny = bigreal.scale2(try bigreal.one(a), -200);
            const v = if (eql(u8, f, "sin")) sc.s else if (eql(u8, f, "cos")) sc.c else if (eql(u8, f, "tan") or eql(u8, f, "cot")) blk: {
                const den = if (eql(u8, f, "tan")) sc.c else sc.s;
                if ((try bigreal.order(a, bigreal.abs(den), tiny)) == .lt) return error.Domain;
                break :blk if (eql(u8, f, "tan")) try bigreal.div(a, sc.s, sc.c) else try bigreal.div(a, sc.c, sc.s);
            } else blk: {
                const den = if (eql(u8, f, "sec")) sc.c else sc.s;
                if ((try bigreal.order(a, bigreal.abs(den), tiny)) == .lt) return error.Domain;
                break :blk try bigreal.div(a, try bigreal.one(a), den);
            };
            return num.fromReal(v);
        }
        if (eql(u8, f, "asin") or eql(u8, f, "acos") or eql(u8, f, "atan")) {
            if (x.isZero() and !eql(u8, f, "acos")) return zero;
            const r = try num.toReal(a, x);
            const v = if (eql(u8, f, "asin")) try bigreal.asin(a, r) else if (eql(u8, f, "acos")) try bigreal.acos(a, r) else try bigreal.atan(a, r);
            return num.fromReal(try self.bigFromRad(v));
        }
        if (eql(u8, f, "sinh") or eql(u8, f, "cosh") or eql(u8, f, "tanh") or eql(u8, f, "asinh") or eql(u8, f, "acosh") or eql(u8, f, "atanh")) {
            if (x.isZero() and !eql(u8, f, "cosh") and !eql(u8, f, "acosh")) return zero;
            if (x.isZero() and eql(u8, f, "cosh")) return one;
            const r = try num.toReal(a, x);
            const v = if (eql(u8, f, "sinh")) try bigreal.sinh(a, r) else if (eql(u8, f, "cosh")) try bigreal.cosh(a, r) else if (eql(u8, f, "tanh")) try bigreal.tanh(a, r) else if (eql(u8, f, "asinh")) try bigreal.asinh(a, r) else if (eql(u8, f, "acosh")) try bigreal.acosh(a, r) else try bigreal.atanh(a, r);
            return num.fromReal(v);
        }
        if (eql(u8, f, "sech") or eql(u8, f, "csch") or eql(u8, f, "coth")) {
            if (x.isZero()) return if (eql(u8, f, "sech")) one else error.Domain;
            const r = try num.toReal(a, x);
            const sh = try bigreal.sinh(a, r);
            const ch = try bigreal.cosh(a, r);
            return num.fromReal(if (eql(u8, f, "sech")) try bigreal.div(a, try bigreal.one(a), ch) else if (eql(u8, f, "csch")) try bigreal.div(a, try bigreal.one(a), sh) else try bigreal.div(a, ch, sh));
        }
        if (eql(u8, f, "asech") or eql(u8, f, "acsch") or eql(u8, f, "acoth")) {
            if (x.isZero()) return error.Domain;
            const inv = try bigreal.div(a, try bigreal.one(a), try num.toReal(a, x));
            if (eql(u8, f, "asech")) {
                if (x.isNegative()) return error.Domain;
                return num.fromReal(try bigreal.acosh(a, inv));
            }
            return num.fromReal(if (eql(u8, f, "acsch")) try bigreal.asinh(a, inv) else try bigreal.atanh(a, inv));
        }
        if (eql(u8, f, "asec") or eql(u8, f, "acsc") or eql(u8, f, "acot")) {
            if (x.isZero()) {
                if (!eql(u8, f, "acot")) return error.Domain;
                return num.fromReal(try self.bigFromRad(bigreal.scale2(try bigreal.pi(a, 8), -1)));
            }
            const inv = try bigreal.div(a, try bigreal.one(a), try num.toReal(a, x));
            const v = if (eql(u8, f, "asec")) try bigreal.acos(a, inv) else if (eql(u8, f, "acsc")) try bigreal.asin(a, inv) else try bigreal.atan(a, inv);
            return num.fromReal(try self.bigFromRad(v));
        }
        if (eql(u8, f, "sinc")) {
            if (x.isZero()) return one;
            const r = try num.toReal(a, x);
            return num.fromReal(try bigreal.div(a, try bigreal.sin(a, r), r));
        }
        if (eql(u8, f, "exp")) {
            if (x.isZero()) return one;
            return num.fromReal(bigreal.exp(a, try num.toReal(a, x)) catch |e| return if (e == error.TooLarge) null else e);
        }
        if (eql(u8, f, "ln")) {
            if (x.isNegative() or x.isZero()) return error.Domain;
            if (try num.order(a, x, one) == .eq) return zero;
            return num.fromReal(try bigreal.ln(a, try num.toReal(a, x)));
        }
        return null;
    }

    fn bigAbs(x: Number) Number {
        return switch (x) {
            .exact => |e| blk: {
                var n = e.num;
                n.abs();
                break :blk .{ .exact = .{ .num = n, .den = e.den } };
            },
            .big => |r| .{ .big = bigreal.abs(r) },
            .approx => |f| .{ .approx = @abs(f) },
        };
    }

    fn exactTrig(self: *Eval, f: []const u8, x: Number) Error!?Number {
        if (self.mode.angle != .degrees or !x.isExact() or !x.isInteger()) return null;
        const d = num.intValue(x) orelse return null;
        const deg = @mod(d, 360);
        const a = self.a;
        const half = try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 2));
        const sinv: ?Number = switch (deg) {
            0, 180 => try num.fromInt(a, 0),
            90 => try num.fromInt(a, 1),
            270 => try num.fromInt(a, -1),
            30, 150 => half,
            210, 330 => try num.neg(a, half),
            else => null,
        };
        const cosv: ?Number = switch (deg) {
            90, 270 => try num.fromInt(a, 0),
            0 => try num.fromInt(a, 1),
            180 => try num.fromInt(a, -1),
            60, 300 => half,
            120, 240 => try num.neg(a, half),
            else => null,
        };
        if (std.mem.eql(u8, f, "sin")) return sinv;
        if (std.mem.eql(u8, f, "cos")) return cosv;
        if (std.mem.eql(u8, f, "tan")) {
            if (deg == 45 or deg == 225) return try num.fromInt(a, 1);
            if (deg == 135 or deg == 315) return try num.fromInt(a, -1);
            if (deg == 90 or deg == 270) return error.Domain;
            if (sinv != null and sinv.?.isZero()) return try num.fromInt(a, 0);
        }
        return null;
    }

    fn builtin(self: *Eval, f_in: []const u8, args: []const Number) Error!Number {
        const a = self.a;
        const f = functions.canonical(f_in);
        if (comparison(f)) |_| {
            if (args.len != 2) return error.WrongArguments;
            const o = try compareNumbers(a, args[0], args[1]);
            const yes = if (std.mem.eql(u8, f, "lt")) o == .lt else if (std.mem.eql(u8, f, "le")) o != .gt else if (std.mem.eql(u8, f, "gt")) o == .gt else if (std.mem.eql(u8, f, "ge")) o != .lt else o != .eq;
            return num.fromInt(a, @as(i64, if (yes) 1 else 0));
        }
        if (std.mem.eql(u8, f, "round") and args.len == 2) {
            // round(2.567, 2) is 2.57; round(1234.5, -2) is 1200.
            const digits = num.intValue(args[1]) orelse return error.Domain;
            if (digits < -300 or digits > 300) return error.Domain;
            const scale = try num.pow(a, try num.fromInt(a, 10), try num.fromInt(a, digits));
            const scaled = try self.builtin("round", &.{try num.mul(a, args[0], scale)});
            return num.div(a, scaled, scale);
        }
        if (args.len == 1) if (try self.highFunction(f, args[0])) |v| return v;
        if (functions.find(f)) |def| {
            if (args.len < def.min or args.len > def.max) return error.WrongArguments;
            const fctx: functions.Ctx = .{ .a = a, .rad_per_unit = self.toRad(1) };
            return def.run(&fctx, args);
        }
        const eql = std.mem.eql;
        const n = args.len;
        // Any number of arguments.
        if (eql(u8, f, "min") or eql(u8, f, "max") or eql(u8, f, "sum") or eql(u8, f, "mean") or eql(u8, f, "avg") or
            eql(u8, f, "median") or eql(u8, f, "stdev") or eql(u8, f, "var") or eql(u8, f, "gcd") or eql(u8, f, "lcm"))
        {
            if (n == 0) return error.WrongArguments;
            return self.listFunction(f, args);
        }
        if (eql(u8, f, "rand")) {
            if (n != 0) return error.WrongArguments;
            return .{ .approx = self.session.rng.random().float(f64) };
        }
        const two = eql(u8, f, "root") or eql(u8, f, "ncr") or eql(u8, f, "npr") or eql(u8, f, "mod") or eql(u8, f, "pow") or
            eql(u8, f, "atan2") or eql(u8, f, "hypot") or (eql(u8, f, "log") and n == 2) or eql(u8, f, "rol") or eql(u8, f, "ror");
        if (two) {
            if (eql(u8, f, "rol") or eql(u8, f, "ror")) {
                if (n != 1 and n != 2) return error.WrongArguments;
            } else if (n != 2) return error.WrongArguments;
        } else if (!isBuiltin(f)) {
            return error.UnknownName;
        } else if (n != 1) return error.WrongArguments;
        const x = args[0];
        if (eql(u8, f, "rol") or eql(u8, f, "ror")) {
            const bits = self.mode.bits;
            const mask: u128 = if (bits >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
            const v: u128 = @as(u128, @bitCast(try self.int(x))) & mask;
            const k: u7 = @intCast(@mod(if (n == 2) try self.int(args[1]) else 1, bits));
            const back: u7 = @intCast((bits - @as(u32, k)) % bits);
            const r = if (eql(u8, f, "rol")) ((v << k) | (v >> back)) & mask else ((v >> k) | (v << back)) & mask;
            return num.fromI128(a, @bitCast(if (k == 0) v else r));
        }
        if (eql(u8, f, "mod")) return num.mod(a, x, args[1]);
        if (eql(u8, f, "pow")) return num.pow(a, x, args[1]);
        if (eql(u8, f, "root")) {
            const k = num.intValue(args[1]) orelse return error.Domain;
            if (k <= 0) return error.Domain;
            return num.pow(a, x, try num.div(a, try num.fromInt(a, 1), args[1]));
        }
        if (eql(u8, f, "ncr") or eql(u8, f, "npr")) {
            const nn = num.intValue(x) orelse return error.Domain;
            const r = num.intValue(args[1]) orelse return error.Domain;
            if (nn < 0 or r < 0) return error.Domain;
            // Choosing more than there are: no way to do it.
            if (r > nn) return num.fromInt(a, 0);
            if (nn > 100_000) return error.TooLarge;
            var acc = try num.fromInt(a, 1);
            var i: i64 = 0;
            while (i < r) : (i += 1) acc = try num.mul(a, acc, try num.fromInt(a, nn - i));
            if (eql(u8, f, "npr")) return acc;
            return num.div(a, acc, try num.factorial(a, args[1]));
        }
        if (eql(u8, f, "atan2")) {
            if (x != .approx and args[1] != .approx) {
                if (bigreal.atan2(a, try num.toReal(a, x), try num.toReal(a, args[1]))) |r| return num.fromReal(try self.bigFromRad(r)) else |e| if (e != error.Domain) return e;
            }
            return num.fromFloat(self.fromRad(std.math.atan2(x.toFloat(), args[1].toFloat())));
        }
        if (eql(u8, f, "hypot")) {
            if (x != .approx and args[1] != .approx) {
                const sq = try num.add(a, try num.mul(a, x, x), try num.mul(a, args[1], args[1]));
                return self.builtin("sqrt", &.{sq});
            }
            return num.fromFloat(std.math.hypot(x.toFloat(), args[1].toFloat()));
        }
        if (eql(u8, f, "log") and n == 2) {
            const v = x.toFloat();
            const base = args[1].toFloat();
            if (v <= 0 or base <= 0 or base == 1) return error.Domain;
            // Whole logs of whole powers stay exact: log(8, 2) = 3.
            const r = @log(v) / @log(base);
            if (x.isExact() and args[1].isExact() and @abs(r - @round(r)) < 1e-12) {
                const k = try num.fromInt(a, @as(i64, @intFromFloat(@round(r))));
                if ((try num.order(a, try num.pow(a, args[1], k), x)) == .eq) return k;
            }
            if (x != .approx and args[1] != .approx) {
                const lx = try self.builtin("ln", &.{x});
                const lb = try self.builtin("ln", &.{args[1]});
                return num.div(a, lx, lb);
            }
            return num.fromFloat(r);
        }

        // One argument.
        if (eql(u8, f, "abs")) return if (x.isNegative()) num.neg(a, x) else x;
        if (eql(u8, f, "floor")) return num.floor(a, x);
        if (eql(u8, f, "ceil")) return num.neg(a, try num.floor(a, try num.neg(a, x)));
        if (eql(u8, f, "trunc")) return if (x.isNegative()) num.neg(a, try num.floor(a, try num.neg(a, x))) else num.floor(a, x);
        if (eql(u8, f, "round")) {
            const half = try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 2));
            return if (x.isNegative()) num.neg(a, try num.floor(a, try num.add(a, try num.neg(a, x), half))) else num.floor(a, try num.add(a, x, half));
        }
        if (eql(u8, f, "frac")) return num.sub(a, x, try num.floor(a, x));
        if (eql(u8, f, "sign")) return num.fromInt(a, if (x.isZero()) @as(i64, 0) else if (x.isNegative()) @as(i64, -1) else 1);
        if (eql(u8, f, "fact")) return num.factorial(a, x);
        if (try self.highFunction(f, x)) |v| return v;
        if (eql(u8, f, "sqrt")) {
            if (x.isNegative()) return error.Domain;
            if (try num.root(a, x, 2)) |r| return r;
            return num.fromFloat(@sqrt(x.toFloat()));
        }
        if (eql(u8, f, "cbrt")) {
            if (try num.root(a, x, 3)) |r| return r;
            return num.fromFloat(std.math.cbrt(x.toFloat()));
        }
        if (eql(u8, f, "sin") or eql(u8, f, "cos") or eql(u8, f, "tan")) {
            if (try self.exactTrig(f, x)) |v| return v;
            const r = self.toRad(x.toFloat());
            const v = if (eql(u8, f, "sin")) @sin(r) else if (eql(u8, f, "cos")) @cos(r) else blk: {
                if (@abs(@cos(r)) < 1e-15) return error.Domain;
                break :blk @tan(r);
            };
            return num.fromFloat(if (@abs(v) < 1e-15) 0 else v);
        }
        if (eql(u8, f, "sec") or eql(u8, f, "csc") or eql(u8, f, "cot")) {
            const r = self.toRad(x.toFloat());
            const d = if (eql(u8, f, "sec")) @cos(r) else if (eql(u8, f, "csc")) @sin(r) else @tan(r);
            if (@abs(d) < 1e-15) return error.Domain;
            return num.fromFloat(1 / d);
        }
        const v = x.toFloat();
        if (eql(u8, f, "asin") or eql(u8, f, "acos")) {
            if (v < -1 or v > 1) return error.Domain;
            return num.fromFloat(self.fromRad(if (eql(u8, f, "asin")) std.math.asin(v) else std.math.acos(v)));
        }
        if (eql(u8, f, "atan")) return num.fromFloat(self.fromRad(std.math.atan(v)));
        if (eql(u8, f, "sinh")) return num.fromFloat(std.math.sinh(v));
        if (eql(u8, f, "cosh")) return num.fromFloat(std.math.cosh(v));
        if (eql(u8, f, "tanh")) return num.fromFloat(std.math.tanh(v));
        if (eql(u8, f, "asinh")) return num.fromFloat(std.math.asinh(v));
        if (eql(u8, f, "acosh")) {
            if (v < 1) return error.Domain;
            return num.fromFloat(std.math.acosh(v));
        }
        if (eql(u8, f, "atanh")) {
            if (v <= -1 or v >= 1) return error.Domain;
            return num.fromFloat(std.math.atanh(v));
        }
        if (eql(u8, f, "exp")) return num.fromFloat(@exp(v));
        if (eql(u8, f, "ln") or eql(u8, f, "log") or eql(u8, f, "log10") or eql(u8, f, "log2")) {
            if (v <= 0) return error.Domain;
            if (eql(u8, f, "ln")) return num.fromFloat(@log(v));
            const base: i64 = if (eql(u8, f, "log2")) 2 else 10;
            return self.builtin("log", &.{ x, try num.fromInt(a, base) });
        }
        return error.UnknownName;
    }

    fn listFunction(self: *Eval, f: []const u8, args: []const Number) Error!Number {
        const a = self.a;
        const eql = std.mem.eql;
        if (eql(u8, f, "gcd") or eql(u8, f, "lcm")) {
            var acc: i128 = @intCast(@abs(try self.int(args[0])));
            for (args[1..]) |x| {
                const v: i128 = @intCast(@abs(try self.int(x)));
                if (eql(u8, f, "gcd")) {
                    acc = @intCast(std.math.gcd(@as(u128, @intCast(acc)), @as(u128, @intCast(v))));
                } else {
                    if (acc == 0 or v == 0) {
                        acc = 0;
                    } else {
                        const g: i128 = @intCast(std.math.gcd(@as(u128, @intCast(acc)), @as(u128, @intCast(v))));
                        acc = std.math.mul(i128, @divExact(acc, g), v) catch return error.TooLarge;
                    }
                }
            }
            return num.fromI128(a, acc);
        }
        if (eql(u8, f, "min") or eql(u8, f, "max")) {
            var best = args[0];
            for (args[1..]) |x| {
                const o = try num.order(a, x, best);
                if ((eql(u8, f, "min") and o == .lt) or (eql(u8, f, "max") and o == .gt)) best = x;
            }
            return best;
        }
        var total = try num.fromInt(a, 0);
        for (args) |x| total = try num.add(a, total, x);
        if (eql(u8, f, "sum")) return total;
        const count = try num.fromInt(a, @as(i64, @intCast(args.len)));
        const mean = try num.div(a, total, count);
        if (eql(u8, f, "mean") or eql(u8, f, "avg")) return mean;
        if (eql(u8, f, "median")) {
            const sorted = try a.dupe(Number, args);
            const Ctx = struct { a: std.mem.Allocator };
            std.mem.sort(Number, sorted, Ctx{ .a = a }, struct {
                fn less(c: Ctx, x: Number, y: Number) bool {
                    return (num.order(c.a, x, y) catch .eq) == .lt;
                }
            }.less);
            const mid = sorted.len / 2;
            if (sorted.len % 2 == 1) return sorted[mid];
            return num.div(a, try num.add(a, sorted[mid - 1], sorted[mid]), try num.fromInt(a, 2));
        }
        // Sample variance and standard deviation (n - 1), as calculators give.
        if (args.len < 2) return error.WrongArguments;
        var sq = try num.fromInt(a, 0);
        for (args) |x| {
            const d = try num.sub(a, x, mean);
            sq = try num.add(a, sq, try num.mul(a, d, d));
        }
        const variance = try num.div(a, sq, try num.fromInt(a, @as(i64, @intCast(args.len - 1))));
        if (eql(u8, f, "var")) return variance;
        if (try num.root(self.a, variance, 2)) |r| return r;
        return num.fromFloat(@sqrt(variance.toFloat()));
    }

    // ---- floats, for graphs and solving -------------------------------------------------

    /// The tree worked out with floats; NaN where it has no value.
    pub fn float(self: *Eval, n: *const Node, x_name: []const u8, x: f64) f64 {
        return self.floatIn(n, x_name, x, null) catch std.math.nan(f64);
    }

    fn floatIn(self: *Eval, n: *const Node, x_name: []const u8, x: f64, b: ?*const FBind) Error!f64 {
        switch (n.*) {
            .number => |v| return v.toFloat(),
            .name => |nm| {
                if (std.mem.eql(u8, nm.text, x_name)) return x;
                var it = b;
                while (it) |bb| : (it = bb.next) if (std.mem.eql(u8, bb.name, nm.text)) return bb.value;
                return (try self.evalRaw(n, null)).toFloat();
            },
            .unary => |u| {
                const v = try self.floatIn(u.arg, x_name, x, b);
                return switch (u.op) {
                    .neg => -v,
                    .pct => v / 100,
                    .fact => if (v >= 0 and v == @floor(v) and v <= 170) std.math.gamma(f64, v + 1) else error.Domain,
                    .bnot => error.Domain,
                };
            },
            .binary => |bin| {
                const l = try self.floatIn(bin.l, x_name, x, b);
                const r = try self.floatIn(bin.r, x_name, x, b);
                return switch (bin.op) {
                    .add => l + r,
                    .sub => l - r,
                    .mul => l * r,
                    .div => if (r == 0) error.DivisionByZero else l / r,
                    .mod => if (r == 0) error.DivisionByZero else @mod(l, r),
                    .pow => blk: {
                        if (l < 0 and r != @floor(r)) {
                            // Odd roots of negatives, when the exponent is written as 1/odd.
                            const inv = 1 / r;
                            if (@abs(inv - @round(inv)) < 1e-9 and @mod(@round(inv), 2) == 1) break :blk -std.math.pow(f64, -l, r);
                            return error.Domain;
                        }
                        break :blk std.math.pow(f64, l, r);
                    },
                    .add_pct => l + l * r / 100,
                    .sub_pct => l - l * r / 100,
                    else => error.Domain,
                };
            },
            .call => |c| {
                if (self.session.funcs.get(c.name)) |f| {
                    if (f.params.len != c.args.len) return error.WrongArguments;
                    self.depth += 1;
                    defer self.depth -= 1;
                    if (self.depth > 64) return error.Recursion;
                    var chain = b;
                    for (f.params, c.args) |p, an| {
                        const bind = try self.a.create(FBind);
                        bind.* = .{ .name = p, .value = try self.floatIn(an, x_name, x, b), .next = chain };
                        chain = bind;
                    }
                    // A function's body is parsed once per graph, not per point.
                    const body = try self.cachedBody(c.name, f.body);
                    return self.floatIn(body, "", 0, chain);
                }
                if (c.args.len == 1 and !isBuiltin(c.name)) {
                    const as_name: Node = .{ .name = .{ .text = c.name, .pos = c.pos } };
                    return (try self.floatIn(&as_name, x_name, x, b)) * (try self.floatIn(c.args[0], x_name, x, b));
                }
                var vals: [16]Number = undefined;
                if (c.args.len > vals.len) return error.WrongArguments;
                for (c.args, 0..) |an, i| vals[i] = .{ .approx = try self.floatIn(an, x_name, x, b) };
                const lower_buf = try self.a.alloc(u8, c.name.len);
                const r = try self.builtin(std.ascii.lowerString(lower_buf, c.name), vals[0..c.args.len]);
                return r.toFloat();
            },
        }
    }

    const FBind = struct { name: []const u8, value: f64, next: ?*const FBind };

    fn cachedBody(self: *Eval, name: []const u8, body: []const u8) Error!*Node {
        if (self.bodies.get(name)) |n| return n;
        var p: Problem = .{};
        const n = try parseExpr(self.a, body, self.mode, &p);
        try self.bodies.put(self.a, name, n);
        return n;
    }
};

// ---- whole entries ----------------------------------------------------------------------

/// yyyy-mm-dd, as a date (four-digit year, two-digit month and day, not part of a longer number or name).
pub fn dateLiteral(r: []const u8) bool {
    if (r.len < 10) return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(r[i])) return false;
    if (r[4] != '-' or r[7] != '-') return false;
    if (r.len > 10 and (std.ascii.isDigit(r[10]) or std.ascii.isAlphabetic(r[10]) or r[10] == '.')) return false;
    const m = (r[5] - '0') * 10 + (r[6] - '0');
    const d = (r[8] - '0') * 10 + (r[9] - '0');
    return m >= 1 and m <= 12 and d >= 1 and d <= 31;
}

pub const Outcome = union(enum) {
    value: Number,
    /// x = 5
    assigned: struct { name: []const u8, value: Number },
    /// f(x) = ...
    defined: []const u8,
    /// An equation: the unknown and where it holds (exact where possible),
    /// and the answer in letters when it has them ("9π").
    solved: struct { name: []const u8, roots: []Number, form: ?[]const u8 = null },
    /// Unknowns left: the entry tidied as far as it goes ("E = 2v²").
    simplified: []const u8,
    /// No real solution, but a polynomial equation has complex ones.
    complex: struct { name: []const u8, re: []f64, im: []f64 },
    /// Both sides known: whether they are equal.
    truth: bool,
    /// A complex number or a matrix.
    rich: rich.Value,
    /// x + y = 5; x - y = 1: each unknown and its value.
    system: struct { names: [][]const u8, values: []Number },
    /// M = [1, 2; 3, 4]: a stored matrix or complex number.
    rich_assigned: struct { name: []const u8, value: rich.Value },
};

/// Works out one entry. Everything returned lives in `a`.
/// The text inside `name(…)` when the whole entry is that one call.
fn unwrapCall(text: []const u8, name: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " ");
    if (t.len <= name.len + 1 or !std.ascii.startsWithIgnoreCase(t, name) or t[name.len] != '(' or t[t.len - 1] != ')') return null;
    var depth: usize = 0;
    for (t[name.len..], name.len..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -|= 1;
            if (depth == 0 and i != t.len - 1) return null;
        }
    }
    return t[name.len + 1 .. t.len - 1];
}

/// Splits at the separators outside brackets.
pub fn splitTop(a: std.mem.Allocator, text: []const u8, sep: u8) Error![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        else => if (c == sep and depth == 0) {
            try parts.append(a, text[start..i]);
            start = i + 1;
        },
    };
    try parts.append(a, text[start..]);
    return parts.items;
}

/// Could this entry be drawn as a graph of x? "sin(x)", "x^2 - 2", "y = 2x + 1" (the letters
/// besides x all have values), or the name of a function of your own with one argument.
/// Returns the expression to draw.
pub fn graphable(a: std.mem.Allocator, session: *Session, text: []const u8, mode: Mode) ?[]const u8 {
    var t = std.mem.trim(u8, text, " ");
    // y = …: the right side.
    if (t.len > 1 and (t[0] == 'y' or t[0] == 'Y')) {
        const after = std.mem.trimStart(u8, t[1..], " ");
        if (after.len > 0 and after[0] == '=') t = std.mem.trim(u8, after[1..], " ");
    }
    if (t.len == 0 or std.mem.indexOfScalar(u8, t, '=') != null) return null;
    if (session.funcs.get(t)) |f| return if (f.params.len == 1) t else null;
    var p: Problem = .{};
    const st = parse(a, t, mode, &p) catch return null;
    if (st != .expr) return null;
    var names: std.ArrayList([]const u8) = .empty;
    unknowns(a, st.expr, session, &names) catch return null;
    if (names.items.len == 1 and std.mem.eql(u8, names.items[0], "x")) return t;
    return null;
}

pub fn run(a: std.mem.Allocator, session: *Session, text: []const u8, mode: Mode, problem: *Problem) Error!Outcome {
    // solve(x^2 = 4, x) and solve(x^2 - 4): the equation itself. simplify(2x + 3x): the entry itself.
    if (!mode.programmer) {
        if (unwrapCall(text, "solve")) |inner| {
            const args = try splitTop(a, inner, ',');
            if (args.len < 1 or args.len > 2) return error.WrongArguments;
            const eq = if (std.mem.indexOfScalar(u8, args[0], '=') == null) try std.fmt.allocPrint(a, "{s} = 0", .{args[0]}) else args[0];
            return run(a, session, eq, .{ .angle = mode.angle, .solve_only = true }, problem);
        }
        if (unwrapCall(text, "simplify")) |inner| return run(a, session, inner, mode, problem);
        // x = 5; x * 2: the entries one after the other, the last one's answer (several
        // equations in a row are a system of equations instead).
        const parts = try splitTop(a, text, ';');
        if (parts.len > 1 and std.mem.indexOfScalar(u8, parts[parts.len - 1], '=') == null and std.mem.trim(u8, parts[parts.len - 1], " ").len > 0) {
            for (parts[0 .. parts.len - 1]) |part| _ = try run(a, session, part, mode, problem);
            return run(a, session, parts[parts.len - 1], mode, problem);
        }
    }
    if (!mode.programmer and !mode.solve_only) if (try systemOf(a, session, text, mode, problem)) |o| return o;
    const st = try parse(a, text, mode, problem);
    var ev: Eval = .{ .a = a, .session = session, .mode = mode, .problem = problem };
    switch (st) {
        .expr => |n0| {
            if (!mode.programmer and rich.needs(n0, session)) return richOutcome(a, &ev, session, n0);
            // diff(f, x) on its own is a formula: tidy it.
            const n = if (calculus.hasDiff(n0)) try calculus.expand(a, &ev, n0) else n0;
            if (ev.eval(n, null)) |v| return if (isBoolean(n)) .{ .truth = !v.isZero() } else .{ .value = v } else |e| {
                // sqrt(-4), ln(-1): an answer among the complex numbers.
                if (e == error.Domain and !mode.programmer) {
                    if (richOutcome(a, &ev, session, n)) |o| return o else |_| {}
                }
                // Letters without values: tidy it instead.
                if (e != error.UnknownName) return e;
                var names: std.ArrayList([]const u8) = .empty;
                try unknowns(a, n, session, &names);
                if (names.items.len == 0 or mode.programmer) return e;
                return .{ .simplified = try simplify.simplify(a, &ev, n) };
            }
        },
        .equation => |eq| {
            if (mode.solve_only) return solve(a, &ev, eq.l, eq.r);
            // M = [1, 2; 3, 4], z = 3 + 4i.
            if (!mode.programmer and eq.l.* == .name and !isConstant(eq.l.name.text) and rich.needs(eq.r, session)) {
                var rr = rich.Rich.init(&ev);
                const v = try rr.value(eq.r, null);
                if (v == .scalar and v.scalar.isReal()) {
                    try session.setVar(eq.l.name.text, v.scalar.re);
                    return .{ .assigned = .{ .name = eq.l.name.text, .value = v.scalar.re } };
                }
                try session.setRich(eq.l.name.text, v);
                return .{ .rich_assigned = .{ .name = eq.l.name.text, .value = v } };
            }
            // x = 5: a variable. When the right side uses x, it is an equation,
            // unless x is already a variable (x = x + 1 counts up).
            var rhs_unknowns: std.ArrayList([]const u8) = .empty;
            try unknowns(a, eq.r, session, &rhs_unknowns);
            if (eq.l.* == .name and !isConstant(eq.l.name.text) and rhs_unknowns.items.len == 0 and
                (!uses(eq.r, eq.l.name.text) or session.vars.contains(eq.l.name.text)))
            {
                const v = try ev.eval(eq.r, null);
                try session.setVar(eq.l.name.text, v);
                return .{ .assigned = .{ .name = eq.l.name.text, .value = v } };
            }
            // f(x, y) = body: a function, when every argument is a plain name.
            if (eq.l.* == .call and !isBuiltin(eq.l.call.name) and eq.l.call.args.len > 0) {
                var params: std.ArrayList([]const u8) = .empty;
                const ok = for (eq.l.call.args) |arg| {
                    if (arg.* != .name) break false;
                    try params.append(a, arg.name.text);
                } else true;
                if (ok) {
                    const eq_pos = std.mem.indexOfScalar(u8, text, '=').?;
                    const body = std.mem.trim(u8, text[eq_pos + 1 ..], " \t");
                    // The body must make sense with the parameters bound.
                    try checkNames(eq.r, session, params.items, problem);
                    try session.define(eq.l.call.name, params.items, body);
                    return .{ .defined = eq.l.call.name };
                }
            }
            return solve(a, &ev, eq.l, eq.r);
        },
    }
}

/// "x + y = 5; x - y = 1": equations side by side, solved together (linear).
fn systemOf(a: std.mem.Allocator, session: *Session, text: []const u8, mode: Mode, problem: *Problem) Error!?Outcome {
    var parts: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| switch (c) {
        '(', '[' => depth += 1,
        ')', ']' => depth -|= 1,
        ';' => if (depth == 0) {
            try parts.append(a, text[start..i]);
            start = i + 1;
        },
        else => {},
    };
    if (parts.items.len == 0) return null;
    try parts.append(a, text[start..]);
    var names: std.ArrayList([]const u8) = .empty;
    for (parts.items) |part| {
        if (std.mem.indexOfScalar(u8, part, '=') == null) return null;
        const st = parse(a, part, mode, problem) catch return null;
        if (st != .equation) return null;
        try unknowns(a, st.equation.l, session, &names);
        try unknowns(a, st.equation.r, session, &names);
    }
    if (names.items.len != parts.items.len) return error.TooManyUnknowns;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "multisolve([");
    for (parts.items, 0..) |part, i| {
        if (i > 0) try src.appendSlice(a, "; ");
        try src.appendSlice(a, part);
    }
    try src.appendSlice(a, "], [");
    for (names.items, 0..) |nm, i| {
        if (i > 0) try src.appendSlice(a, ", ");
        try src.appendSlice(a, nm);
    }
    try src.appendSlice(a, "])");
    const node = try parseExpr(a, src.items, mode, problem);
    var ev: Eval = .{ .a = a, .session = session, .mode = mode, .problem = problem };
    var rr = rich.Rich.init(&ev);
    const v = try rr.value(node, null);
    if (v != .matrix or v.matrix.items.len != names.items.len) return error.Domain;
    const values = try a.alloc(Number, names.items.len);
    for (v.matrix.items, 0..) |c, i| {
        if (!c.isReal()) return error.Domain;
        values[i] = c.re;
    }
    return .{ .system = .{ .names = names.items, .values = values } };
}

/// An entry worked out as a complex number or matrix; a plain real answer stays a plain value.
fn richOutcome(a: std.mem.Allocator, ev: *Eval, session: *Session, n: *const Node) Error!Outcome {
    var rr = rich.Rich.init(ev);
    const v = try rr.value(n, null);
    if (v == .scalar and v.scalar.isReal()) return .{ .value = v.scalar.re };
    _ = a;
    session.setRich("ans", v) catch return error.OutOfMemory;
    return .{ .rich = v };
}

fn uses(n: *const Node, name: []const u8) bool {
    return switch (n.*) {
        .number => false,
        .name => |nm| std.mem.eql(u8, nm.text, name),
        .unary => |u| uses(u.arg, name),
        .binary => |b| uses(b.l, name) or uses(b.r, name),
        .call => |c| for (c.args) |x| {
            if (uses(x, name)) break true;
        } else false,
    };
}

/// The names in `n` that have no value (not a variable, constant or parameter).
fn unknowns(a: std.mem.Allocator, n: *const Node, session: *Session, out: *std.ArrayList([]const u8)) Error!void {
    switch (n.*) {
        .number => {},
        .name => |nm| {
            if (isConstant(nm.text) or session.vars.contains(nm.text)) return;
            for (out.items) |o| if (std.mem.eql(u8, o, nm.text)) return;
            try out.append(a, nm.text);
        },
        .unary => |u| try unknowns(a, u.arg, session, out),
        .binary => |b| {
            try unknowns(a, b.l, session, out);
            try unknowns(a, b.r, session, out);
        },
        .call => |c| for (c.args) |x| try unknowns(a, x, session, out),
    }
}

fn checkNames(n: *const Node, session: *Session, params: []const []const u8, problem: *Problem) Error!void {
    switch (n.*) {
        .number => {},
        .name => |nm| {
            for (params) |p| if (std.mem.eql(u8, p, nm.text)) return;
            if (isConstant(nm.text) or session.vars.contains(nm.text)) return;
            problem.* = .{ .pos = nm.pos, .name = nm.text };
            return error.UnknownName;
        },
        .unary => |u| try checkNames(u.arg, session, params, problem),
        .binary => |b| {
            try checkNames(b.l, session, params, problem);
            try checkNames(b.r, session, params, problem);
        },
        .call => |c| for (c.args) |x| try checkNames(x, session, params, problem),
    }
}

/// Where l = r, for the one unknown in it.
fn solve(a: std.mem.Allocator, ev: *Eval, l: *Node, r: *Node) Error!Outcome {
    var names: std.ArrayList([]const u8) = .empty;
    try unknowns(a, l, ev.session, &names);
    try unknowns(a, r, ev.session, &names);
    if (names.items.len == 0) {
        const x = try ev.eval(l, null);
        const y = try ev.eval(r, null);
        if (x.isExact() and y.isExact()) return .{ .truth = (try num.order(a, x, y)) == .eq };
        return .{ .truth = @abs(x.toFloat() - y.toFloat()) <= 1e-12 * @max(1, @abs(x.toFloat())) };
    }
    if (names.items.len > 1) {
        if (ev.mode.programmer) {
            ev.problem.name = names.items[1];
            return error.TooManyUnknowns;
        }
        return .{ .simplified = try simplify.equation(a, ev, l, r) };
    }
    const x_name = names.items[0];
    // The unknown alone on one side: work out the other (exactly, and in letters: 9π).
    for ([_][2]*Node{ .{ l, r }, .{ r, l } }) |sides| {
        if (sides[0].* == .name and std.mem.eql(u8, sides[0].name.text, x_name) and !uses(sides[1], x_name)) {
            const v = try ev.eval(sides[1], null);
            const roots = try a.alloc(Number, 1);
            roots[0] = v;
            const form = try simplify.simplify(a, ev, sides[1]);
            return .{ .solved = .{ .name = x_name, .roots = roots, .form = form } };
        }
    }
    const diff = try a.create(Node);
    diff.* = .{ .binary = .{ .op = .sub, .l = l, .r = r } };
    const roots = try findRoots(a, ev, diff, x_name);
    if (roots.len == 0) {
        // A polynomial with no real roots still has complex ones.
        if (try simplify.polynomial(a, ev, diff, x_name)) |coefs| {
            const all = try simplify.complexRoots(a, coefs);
            var re: std.ArrayList(f64) = .empty;
            var im: std.ArrayList(f64) = .empty;
            for (all) |z| {
                try re.append(a, if (@abs(z.re) < 1e-12 * @max(1, z.magnitude())) 0 else z.re);
                try im.append(a, z.im);
            }
            if (re.items.len > 0) return .{ .complex = .{ .name = x_name, .re = re.items, .im = im.items } };
        }
        return error.NoSolution;
    }
    var out = try a.alloc(Number, roots.len);
    for (roots, 0..) |root, i| out[i] = try exactRoot(a, ev, diff, x_name, root);
    return .{ .solved = .{ .name = x_name, .roots = out } };
}

/// The real places in [lo, hi] where f(x) = 0, sorted (at most 20).
pub fn findRootsIn(a: std.mem.Allocator, ev: *Eval, f: *const Node, x_name: []const u8, lo: f64, hi: f64, samples: usize) Error![]f64 {
    var roots: std.ArrayList(f64) = .empty;
    const step = (hi - lo) / @as(f64, @floatFromInt(samples));
    var px = lo;
    var py = ev.float(f, x_name, px);
    var ppy: f64 = std.math.nan(f64);
    var i: usize = 1;
    while (i <= samples) : (i += 1) {
        const x = lo + step * @as(f64, @floatFromInt(i));
        const y = ev.float(f, x_name, x);
        if (std.math.isFinite(py) and std.math.isFinite(y)) {
            if (py == 0) {
                try addRoot(a, &roots, px, step);
            } else if ((py < 0) != (y < 0) and y != 0) {
                const root = refine(ev, f, x_name, px, x, py, y);
                // A sign change across a pole (1/x) is not a root.
                if (root) |rt| if (@abs(ev.float(f, x_name, rt)) < 1e-6 * @max(1, @max(@abs(py), @abs(y)))) try addRoot(a, &roots, rt, step);
            } else if (std.math.isFinite(ppy) and @abs(py) < @abs(ppy) and @abs(py) < @abs(y) and (ppy < 0) == (py < 0)) {
                // A touching root (x² = 0): |f| has a small minimum here.
                const m = minimise(ev, f, x_name, px - step, x);
                if (@abs(ev.float(f, x_name, m)) < 1e-10) try addRoot(a, &roots, m, step);
            }
        }
        ppy = py;
        px = x;
        py = y;
        if (roots.items.len >= 20) break;
    }
    if (std.math.isFinite(py) and py == 0) try addRoot(a, &roots, px, step);
    std.mem.sort(f64, roots.items, {}, std.sort.asc(f64));
    return roots.toOwnedSlice(a);
}

fn addRoot(a: std.mem.Allocator, roots: *std.ArrayList(f64), x: f64, step: f64) Error!void {
    for (roots.items) |r| if (@abs(r - x) < step * 0.5 + 1e-12) return;
    try roots.append(a, if (@abs(x) < 1e-13) 0 else x);
}

/// Bisection with a secant step, between a and b where f changes sign.
fn refine(ev: *Eval, f: *const Node, x_name: []const u8, a0: f64, b0: f64, fa0: f64, fb0: f64) ?f64 {
    var lo = a0;
    var hi = b0;
    var flo = fa0;
    var fhi = fb0;
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        var mid = lo - flo * (hi - lo) / (fhi - flo);
        if (!(mid > lo and mid < hi) or k % 3 == 2) mid = (lo + hi) / 2;
        const fm = ev.float(f, x_name, mid);
        if (!std.math.isFinite(fm)) return null;
        if (fm == 0 or hi - lo < 1e-15 * @max(1, @abs(mid))) return mid;
        if ((fm < 0) == (flo < 0)) {
            lo = mid;
            flo = fm;
        } else {
            hi = mid;
            fhi = fm;
        }
    }
    return (lo + hi) / 2;
}

/// The x in [a, b] where |f| is smallest (golden-section search).
fn minimise(ev: *Eval, f: *const Node, x_name: []const u8, a0: f64, b0: f64) f64 {
    const g = (@sqrt(5.0) - 1.0) / 2.0;
    var lo = a0;
    var hi = b0;
    var k: usize = 0;
    while (k < 120) : (k += 1) {
        const c = hi - g * (hi - lo);
        const d = lo + g * (hi - lo);
        if (@abs(ev.float(f, x_name, c)) < @abs(ev.float(f, x_name, d))) hi = d else lo = c;
    }
    return (lo + hi) / 2;
}

fn findRoots(a: std.mem.Allocator, ev: *Eval, f: *const Node, x_name: []const u8) Error![]f64 {
    // Closely near zero first, then wider.
    var all: std.ArrayList(f64) = .empty;
    for ([_][2]f64{ .{ -100, 100 }, .{ -1e4, 1e4 }, .{ -1e7, 1e7 } }, [_]usize{ 40000, 20000, 20000 }) |range, samples| {
        const found = try findRootsIn(a, ev, f, x_name, range[0], range[1], samples);
        for (found) |r| {
            const near = for (all.items) |o| {
                if (@abs(o - r) <= 1e-9 * @max(1, @abs(r))) break true;
            } else false;
            if (!near) try all.append(a, r);
        }
        if (all.items.len > 0) break;
    }
    std.mem.sort(f64, all.items, {}, std.sort.asc(f64));
    return all.toOwnedSlice(a);
}

/// A root as an exact fraction when one with a small denominator fits it
/// exactly (2x + 3 = 11 gives 4, not 3.9999999999999996).
fn exactRoot(a: std.mem.Allocator, ev: *Eval, f: *const Node, x_name: []const u8, x: f64) Error!Number {
    if (closeFraction(x, 10_000)) |pq| {
        const candidate = try num.div(a, try num.fromInt(a, pq[0]), try num.fromInt(a, pq[1]));
        const bind: Binding = .{ .name = x_name, .value = candidate };
        if (ev.eval(f, &bind)) |v| {
            if (v.isExact() and v.isZero()) return candidate;
            if (!v.isExact() and @abs(v.toFloat()) < 1e-12) return candidate;
        } else |_| {}
    }
    return .{ .approx = x };
}

/// The fraction p/q (q ≤ max_den) nearest x, by continued fractions.
pub fn closeFraction(x: f64, max_den: i64) ?[2]i64 {
    if (!std.math.isFinite(x) or @abs(x) > 1e12) return null;
    var h0: f64 = 0;
    var h1: f64 = 1;
    var k0: f64 = 1;
    var k1: f64 = 0;
    var v = x;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const ai = @floor(v);
        const h2 = ai * h1 + h0;
        const k2 = ai * k1 + k0;
        if (k2 > @as(f64, @floatFromInt(max_den))) break;
        h0 = h1;
        h1 = h2;
        k0 = k1;
        k1 = k2;
        const frac = v - ai;
        if (@abs(h1 / k1 - x) < 1e-12 * @max(1, @abs(x)) or frac < 1e-12) break;
        v = 1 / frac;
    }
    if (k1 == 0) return null;
    return .{ @intFromFloat(h1), @intFromFloat(k1) };
}

// ---- tests --------------------------------------------------------------------------------

const Tester = struct {
    arena: std.heap.ArenaAllocator,
    session: Session,

    fn init() Tester {
        return .{ .arena = .init(std.testing.allocator), .session = .{ .gpa = std.testing.allocator } };
    }

    fn deinit(self: *Tester) void {
        self.session.deinit();
        self.arena.deinit();
    }

    fn out(self: *Tester, text: []const u8, mode: Mode) ![]const u8 {
        const a = self.arena.allocator();
        var p: Problem = .{};
        const o = try run(a, &self.session, text, mode, &p);
        return switch (o) {
            .value => |v| num.format(a, v, .{}),
            .assigned => |s| num.format(a, s.value, .{}),
            .defined => |d| d,
            .truth => |t| if (t) "true" else "false",
            .simplified => |x| x,
            .rich => |v| try rich.format(a, v, .{}),
            .system => |sy| blk: {
                var parts: std.ArrayList(u8) = .empty;
                for (sy.names, sy.values, 0..) |nm, v, i| try parts.print(a, "{s}{s} = {s}", .{ if (i > 0) "; " else "", nm, try num.format(a, v, .{}) });
                break :blk parts.items;
            },
            .rich_assigned => |s| try rich.format(a, s.value, .{}),
            .complex => |cx| try std.fmt.allocPrint(a, "{d} complex", .{cx.re.len}),
            .solved => |s| blk: {
                var parts: std.ArrayList(u8) = .empty;
                for (s.roots, 0..) |r, i| {
                    if (i > 0) try parts.appendSlice(a, "; ");
                    try parts.appendSlice(a, try num.format(a, r, .{ .decimals = 6 }));
                }
                break :blk parts.items;
            },
        };
    }

    fn expect(self: *Tester, want: []const u8, text: []const u8) !void {
        const got = try self.out(text, .{});
        std.testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("for {s}\n", .{text});
            return e;
        };
    }
};

test "arithmetic, precedence and exactness" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("14", "2 + 3 * 4");
    try t.expect("20", "(2 + 3) × 4");
    try t.expect("2.5", "10 ÷ 4");
    try t.expect("7", "10 − 2 − 1");
    try t.expect("0.3", "0.1 + 0.2");
    try t.expect("1", "1/3*3");
    try t.expect("-4", "-2^2");
    try t.expect("512", "2^3^2");
    try t.expect("9", "3²");
    try t.expect("1267650600228229401496703205376", "2^100");
}

test "implicit multiplication" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("14", "2(3+4)");
    try t.expect("21", "(1+2)(3+4)");
    try t.expect("6.2831853072", "2π");
    try t.expect("1.5", "3sin(30)");
    try std.testing.expectError(error.Syntax, t.out("2 3", .{}));
}

test "percent like a desk calculator" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("55", "50 + 10%");
    try t.expect("45", "50 - 10%");
    try t.expect("5", "50 × 10%");
    try t.expect("0.5", "50%");
}

test "functions" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("1", "sin(90)");
    try t.expect("0.5", "cos(60)");
    try t.expect("1", "tan(45)");
    try t.expect("2", "log(100)");
    try t.expect("3", "log(8, 2)");
    try t.expect("3", "√9");
    try t.expect("1.4142135624", "sqrt(2)");
    try t.expect("2", "cbrt(8)");
    try t.expect("3", "root(27, 3)");
    try t.expect("120", "5!");
    try t.expect("10", "nCr(5, 2)");
    try t.expect("20", "nPr(5, 2)");
    try t.expect("6", "gcd(12, 18)");
    try t.expect("36", "lcm(12, 18)");
    try t.expect("2.5", "mean(1, 2, 3, 4)");
    try t.expect("2.5", "median(4, 1, 3, 2)");
    try t.expect("1", "min(3, 1, 2)");
    try t.expect("2", "abs(-2)");
    try t.expect("-3", "floor(-2.5)");
    try t.expect("-2", "ceil(-2.5)");
    try t.expect("3", "round(2.5)");
    try t.expect("2", "mod(-1, 3)");
    try t.expect("1", "10 mod 3");
    try t.expect("5", "|-5|");
    try t.expect("6", "𝟐·𝟑");
    try t.expect("9", "𝑥₁ = 9");
    try t.expect("18", "2x1");
    try t.expect("1.2909944487", "stdev(1, 2, 3, 4)");
}

test "variables, ans and functions of one's own" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("5", "x = 5");
    try t.expect("30", "x² + x");
    try t.session.setAns(try num.fromInt(t.arena.allocator(), 7));
    try t.expect("14", "ans × 2");
    try t.expect("f", "f(x) = x² - 3x + 2");
    try t.expect("6", "f(4)");
    try t.expect("area", "area(w, h) = w·h");
    try t.expect("12", "area(3, 4)");
    try std.testing.expectError(error.UnknownName, t.out("g(x) = x + y", .{}));
    try t.expect("nothing + 1", "nothing + 1");
    try std.testing.expectError(error.UnknownName, t.out("nosuch(2)", .{}));
}

test "equations" {
    var t = Tester.init();
    defer t.deinit();
    try t.expect("4", "2y + 3 = 11");
    try t.expect("1; 2", "z² - 3z + 2 = 0");
    try t.expect("-1.414214; 1.414214", "w² = 2");
    try t.expect("0.999848", "cos(q) = q"); // in degrees
    try std.testing.expectEqualStrings("0.739085", try t.out("cos(q) = q", .{ .angle = .radians }));
    try t.expect("0", "u² = 0");
    try t.expect("0.333333", "3v = 1");
    try t.expect("true", "2 + 2 = 4");
    try t.expect("false", "2 + 2 = 5");
    try t.expect("2 complex", "s² = -1");
    try t.expect("2 complex", "9² = p² + 6²×8");
    try std.testing.expectError(error.NoSolution, t.out("sin(s) = 2", .{}));
    try t.expect("a + b = 1", "a + b = 1");
    try t.expect("E = 2v²", "E = 4·v²/2");
    try t.expect("5n", "2n + 3n");
    // A pole is not a root.
    try std.testing.expectError(error.NoSolution, t.out("1/r = 0", .{}));
    // A variable already set is set again, even from itself.
    try t.expect("2", "k = 2");
    try t.expect("3", "k = k + 1");
}

test "programmer mode" {
    var t = Tester.init();
    defer t.deinit();
    const hex: Mode = .{ .programmer = true, .base = 16, .bits = 64 };
    const a = t.arena.allocator();
    var p: Problem = .{};
    const v = (try run(a, &t.session, "FF + 1", hex, &p)).value;
    try std.testing.expectEqual(@as(i128, 256), num.int128(v).?);
    const byte: Mode = .{ .programmer = true, .base = 10, .bits = 8 };
    try std.testing.expectEqual(@as(i128, -1), num.int128((try run(a, &t.session, "255", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, 3), num.int128((try run(a, &t.session, "7 / 2", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, 0b1000), num.int128((try run(a, &t.session, "0b1100 and 0b1010", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, 0b0110), num.int128((try run(a, &t.session, "0b1100 xor 0b1010", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, 16), num.int128((try run(a, &t.session, "1 << 4", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, -1), num.int128((try run(a, &t.session, "not 0", byte, &p)).value).?);
    try std.testing.expectEqual(@as(i128, 3), num.int128((try run(a, &t.session, "rol(0x81)", .{ .programmer = true, .bits = 8 }, &p)).value).?);
    try std.testing.expectError(error.NotInteger, run(a, &t.session, "1.5", byte, &p));
}

test "errors say where" {
    var t = Tester.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var p: Problem = .{};
    try std.testing.expectError(error.Syntax, run(a, &t.session, "2 + * 3", .{}, &p));
    try std.testing.expectEqual(@as(usize, 4), p.pos);
    try std.testing.expectError(error.DivisionByZero, run(a, &t.session, "1/0", .{}, &p));
    try std.testing.expectError(error.Domain, run(a, &t.session, "ln(0)", .{}, &p));
    p = .{};
    try std.testing.expectError(error.UnknownName, run(a, &t.session, "2 + foo(3)", .{}, &p));
    try std.testing.expectEqualStrings("foo", p.name);
    try std.testing.expectError(error.WrongArguments, run(a, &t.session, "sin(1, 2)", .{}, &p));
}

test "floats for graphs" {
    var t = Tester.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var p: Problem = .{};
    const n = try parseExpr(a, "x² - 1", .{}, &p);
    var ev: Eval = .{ .a = a, .session = &t.session, .mode = .{ .angle = .radians }, .problem = &p };
    try std.testing.expectApproxEqAbs(@as(f64, 3), ev.float(n, "x", 2), 1e-12);
    const pole = try parseExpr(a, "1/x", .{}, &p);
    try std.testing.expect(std.math.isNan(ev.float(pole, "x", 0)));
    try std.testing.expectEqual([2]i64{ 1, 3 }, closeFraction(1.0 / 3.0, 1000).?);
    try std.testing.expectEqual([2]i64{ 4, 1 }, closeFraction(3.9999999999999996, 1000).?);
}

test "stored values survive a round trip" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const third = try num.div(a, try num.fromInt(a, -1), try num.fromInt(a, 3));
    const s = try Stored.of(gpa, third);
    defer s.deinit(gpa);
    const line = try s.text(a);
    try std.testing.expectEqualStrings("-1/3", line);
    const back = try Stored.fromText(gpa, line);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("-0.3333333333", try num.format(a, try back.load(a), .{}));
    try std.testing.expectError(error.Domain, Stored.fromText(gpa, "1/x"));
}
