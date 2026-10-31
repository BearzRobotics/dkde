//! Expression evaluator for the calculator: a small recursive-descent parser
//! over f64. No GTK, so it is unit tested.
//!
//!   expr    = term { ("+" | "-") term }
//!   term    = unary { ("*" | "/" | "×" | "÷" | "mod") unary }
//!   unary   = "-" unary | power
//!   power   = postfix [ "^" unary ]           (right associative)
//!   postfix = primary { "!" | "%" }
//!   primary = number | constant | name "(" expr ")" | "(" expr ")"

const std = @import("std");

pub const AngleMode = enum { degrees, radians };

pub const Error = error{ Syntax, DivisionByZero, Domain, UnknownName };

pub fn evaluate(text: []const u8, mode: AngleMode) Error!f64 {
    var parser: Parser = .{ .text = text, .mode = mode };
    const value = try parser.expr();
    parser.skipSpace();
    if (parser.pos != text.len) return error.Syntax;
    if (std.math.isNan(value) or std.math.isInf(value)) return error.Domain;
    return value;
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    mode: AngleMode,
    depth: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }

    /// Consumes `token` (ASCII or UTF-8) if it is next.
    fn eat(self: *Parser, token: []const u8) bool {
        self.skipSpace();
        if (std.mem.startsWith(u8, self.text[self.pos..], token)) {
            self.pos += token.len;
            return true;
        }
        return false;
    }

    fn expr(self: *Parser) Error!f64 {
        var value = try self.term();
        while (true) {
            if (self.eat("+")) {
                value += try self.term();
            } else if (self.eat("-") or self.eat("−")) {
                value -= try self.term();
            } else return value;
        }
    }

    fn term(self: *Parser) Error!f64 {
        var value = try self.unary();
        while (true) {
            if (self.eat("*") or self.eat("×")) {
                value *= try self.unary();
            } else if (self.eat("/") or self.eat("÷")) {
                const divisor = try self.unary();
                if (divisor == 0) return error.DivisionByZero;
                value /= divisor;
            } else if (self.eat("mod")) {
                const divisor = try self.unary();
                if (divisor == 0) return error.DivisionByZero;
                value = @mod(value, divisor);
            } else return value;
        }
    }

    fn unary(self: *Parser) Error!f64 {
        if (self.eat("-") or self.eat("−")) return -(try self.unary());
        if (self.eat("+")) return self.unary();
        return self.power();
    }

    fn power(self: *Parser) Error!f64 {
        const base = try self.postfix();
        if (self.eat("^")) {
            const exponent = try self.unary();
            return std.math.pow(f64, base, exponent);
        }
        return base;
    }

    fn postfix(self: *Parser) Error!f64 {
        var value = try self.primary();
        while (true) {
            if (self.eat("!")) {
                value = try factorial(value);
            } else if (self.eat("%")) {
                value /= 100;
            } else return value;
        }
    }

    fn primary(self: *Parser) Error!f64 {
        self.skipSpace();
        if (self.pos >= self.text.len) return error.Syntax;
        const c = self.text[self.pos];

        if (c == '(') {
            self.pos += 1;
            self.depth += 1;
            if (self.depth > 200) return error.Syntax;
            const value = try self.expr();
            if (!self.eat(")")) return error.Syntax;
            self.depth -= 1;
            return value;
        }
        if (std.ascii.isDigit(c) or c == '.') return self.number();
        if (std.mem.startsWith(u8, self.text[self.pos..], "π")) {
            self.pos += "π".len;
            return std.math.pi;
        }
        if (std.mem.startsWith(u8, self.text[self.pos..], "√")) {
            self.pos += "√".len;
            const arg = try self.power();
            if (arg < 0) return error.Domain;
            return @sqrt(arg);
        }
        if (std.ascii.isAlphabetic(c)) return self.name();
        return error.Syntax;
    }

    fn number(self: *Parser) Error!f64 {
        const start = self.pos;
        while (self.pos < self.text.len and (std.ascii.isDigit(self.text[self.pos]) or self.text[self.pos] == '.')) self.pos += 1;
        // Exponent, but only if digits follow, so "e" stays a constant.
        if (self.pos + 1 < self.text.len and (self.text[self.pos] == 'e' or self.text[self.pos] == 'E')) {
            var look = self.pos + 1;
            if (look < self.text.len and (self.text[look] == '+' or self.text[look] == '-')) look += 1;
            if (look < self.text.len and std.ascii.isDigit(self.text[look])) {
                self.pos = look;
                while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
            }
        }
        return std.fmt.parseFloat(f64, self.text[start..self.pos]) catch error.Syntax;
    }

    fn name(self: *Parser) Error!f64 {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isAlphabetic(self.text[self.pos])) self.pos += 1;
        const ident = self.text[start..self.pos];

        if (std.mem.eql(u8, ident, "pi")) return std.math.pi;
        if (std.mem.eql(u8, ident, "e")) return std.math.e;

        if (!self.eat("(")) return error.UnknownName;
        self.depth += 1;
        if (self.depth > 200) return error.Syntax;
        const arg = try self.expr();
        if (!self.eat(")")) return error.Syntax;
        self.depth -= 1;
        return self.call(ident, arg);
    }

    fn toRadians(self: *const Parser, x: f64) f64 {
        return if (self.mode == .degrees) std.math.degreesToRadians(x) else x;
    }

    fn fromRadians(self: *const Parser, x: f64) f64 {
        return if (self.mode == .degrees) std.math.radiansToDegrees(x) else x;
    }

    fn call(self: *const Parser, f: []const u8, x: f64) Error!f64 {
        const eql = std.mem.eql;
        if (eql(u8, f, "sin")) return cleanTrig(@sin(self.toRadians(x)));
        if (eql(u8, f, "cos")) return cleanTrig(@cos(self.toRadians(x)));
        if (eql(u8, f, "tan")) {
            const c = cleanTrig(@cos(self.toRadians(x)));
            if (c == 0) return error.Domain;
            return cleanTrig(@sin(self.toRadians(x))) / c;
        }
        if (eql(u8, f, "asin")) {
            if (x < -1 or x > 1) return error.Domain;
            return self.fromRadians(std.math.asin(x));
        }
        if (eql(u8, f, "acos")) {
            if (x < -1 or x > 1) return error.Domain;
            return self.fromRadians(std.math.acos(x));
        }
        if (eql(u8, f, "atan")) return self.fromRadians(std.math.atan(x));
        if (eql(u8, f, "ln")) {
            if (x <= 0) return error.Domain;
            return @log(x);
        }
        if (eql(u8, f, "log")) {
            if (x <= 0) return error.Domain;
            return @log10(x);
        }
        if (eql(u8, f, "sqrt")) {
            if (x < 0) return error.Domain;
            return @sqrt(x);
        }
        if (eql(u8, f, "abs")) return @abs(x);
        if (eql(u8, f, "exp")) return @exp(x);
        return error.UnknownName;
    }
};

/// sin(180°) should be 0, not 1.2e-16.
fn cleanTrig(x: f64) f64 {
    return if (@abs(x) < 1e-15) 0 else x;
}

fn factorial(x: f64) Error!f64 {
    if (x < 0 or x != @floor(x) or x > 170) return error.Domain;
    var result: f64 = 1;
    var i: f64 = 2;
    while (i <= x) : (i += 1) result *= i;
    return result;
}

/// Shortest readable form: whole numbers without a fraction, otherwise up
/// to ten decimals with trailing zeros trimmed, and scientific notation for
/// very large or very small values.
pub fn format(buf: []u8, value: f64) []const u8 {
    if (value == 0) return "0";
    const magnitude = @abs(value);
    if (magnitude >= 1e15 or magnitude < 1e-9) {
        return std.fmt.bufPrint(buf, "{e}", .{value}) catch "?";
    }
    const text = std.fmt.bufPrint(buf, "{d:.10}", .{value}) catch return "?";
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

fn expectValue(expected: f64, text: []const u8) !void {
    try std.testing.expectApproxEqAbs(expected, try evaluate(text, .degrees), 1e-9);
}

test "precedence and parentheses" {
    try expectValue(14, "2 + 3 * 4");
    try expectValue(20, "(2 + 3) * 4");
    try expectValue(2.5, "10 / 4");
    try expectValue(7, "10 - 2 - 1");
}

test "unary minus binds looser than power" {
    try expectValue(-4, "-2^2");
    try expectValue(4, "(-2)^2");
    try expectValue(512, "2^3^2"); // right associative: 2^(3^2)
}

test "unicode operators from the keypad" {
    try expectValue(6, "2 × 3");
    try expectValue(3, "6 ÷ 2");
    try expectValue(1, "3 − 2");
}

test "percent, factorial and mod" {
    try expectValue(0.5, "50%");
    try expectValue(120, "5!");
    try expectValue(1, "10 mod 3");
}

test "functions in degrees and radians" {
    try expectValue(1, "sin(90)");
    try expectValue(0, "sin(180)");
    try expectValue(0.5, "cos(60)");
    try std.testing.expectApproxEqAbs(@as(f64, 1), try evaluate("sin(pi/2)", .radians), 1e-9);
    try expectValue(90, "asin(1)");
    try expectValue(2, "log(100)");
    try expectValue(3, "sqrt(9)");
    try expectValue(3, "√9");
    try expectValue(std.math.pi, "π");
}

test "constants and scientific notation" {
    try expectValue(std.math.e * 2, "2*e");
    try std.testing.expectError(error.Syntax, evaluate("2e", .degrees)); // no implicit multiplication
    try expectValue(1500, "1.5e3");
}

test "errors" {
    try std.testing.expectError(error.DivisionByZero, evaluate("1/0", .degrees));
    try std.testing.expectError(error.Domain, evaluate("sqrt(-1)", .degrees));
    try std.testing.expectError(error.Domain, evaluate("ln(0)", .degrees));
    try std.testing.expectError(error.Syntax, evaluate("2 +", .degrees));
    try std.testing.expectError(error.Syntax, evaluate("(2", .degrees));
    try std.testing.expectError(error.Syntax, evaluate("2 3", .degrees));
    try std.testing.expectError(error.UnknownName, evaluate("foo(2)", .degrees));
}

test "formatting" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("14", format(&buf, 14));
    try std.testing.expectEqualStrings("0.3", format(&buf, 0.1 + 0.2));
    try std.testing.expectEqualStrings("-2.5", format(&buf, -2.5));
    try std.testing.expectEqualStrings("0", format(&buf, 0));
}
