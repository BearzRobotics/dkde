//! Exact forms for results that are not fractions: 2√2, π/4, (1 + √5)/2, √6/4 + √2/4, e².
//!
//! A value is a sum of terms c · π^a · e^b · √r with a rational c and a squarefree whole r.
//! That set is closed under +, −, ×, whole powers, and division by a single term or by a
//! sum of two terms (rationalized with the conjugate), which is all that school
//! mathematics needs. Trigonometry is exact for multiples of π/12 (degrees or radians) and
//! so are the inverse functions of those values.
//!
//! `evaluate` returns null for anything outside that set (a letter without a value, a
//! float, ln 2, sin 1): the entry is then worked out with numbers as before.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const Number = num.Number;
const Big = std.math.big.int.Managed;
const Node = eval.Node;

pub const Error = eval.Error;

pub const Mono = struct {
    pi: i16 = 0,
    e: i16 = 0,
    /// Squarefree, at least 1: the term has a factor √rad.
    rad: u64 = 1,

    fn eql(x: Mono, y: Mono) bool {
        return x.pi == y.pi and x.e == y.e and x.rad == y.rad;
    }

    fn less(x: Mono, y: Mono) bool {
        if (x.pi != y.pi) return x.pi < y.pi;
        if (x.e != y.e) return x.e < y.e;
        return x.rad < y.rad;
    }

    fn isPlain(self: Mono) bool {
        return self.pi == 0 and self.e == 0 and self.rad == 1;
    }
};

pub const Term = struct { c: Number, m: Mono };

/// A sum of terms, sorted, with no zero coefficients and no two terms alike.
pub const Sym = struct {
    terms: []const Term,

    pub fn isRational(self: Sym) bool {
        return self.terms.len == 0 or (self.terms.len == 1 and self.terms[0].m.isPlain());
    }

    pub fn isZero(self: Sym) bool {
        return self.terms.len == 0;
    }
};

// ---- building ---------------------------------------------------------------------------

pub fn rational(a: std.mem.Allocator, x: Number) Error!Sym {
    if (x.isZero()) return .{ .terms = &.{} };
    const t = try a.alloc(Term, 1);
    t[0] = .{ .c = x, .m = .{} };
    return .{ .terms = t };
}

pub fn int(a: std.mem.Allocator, v: i64) Error!Sym {
    return rational(a, try num.fromInt(a, v));
}

fn single(a: std.mem.Allocator, c: Number, m: Mono) Error!Sym {
    if (c.isZero()) return .{ .terms = &.{} };
    const t = try a.alloc(Term, 1);
    t[0] = .{ .c = c, .m = m };
    return .{ .terms = t };
}

fn ratio(a: std.mem.Allocator, n: i64, d: i64) Error!Number {
    return num.div(a, try num.fromInt(a, n), try num.fromInt(a, d));
}

/// p/q · √r (r need not be squarefree).
fn surd(a: std.mem.Allocator, n: i64, d: i64, r: u64) Error!Sym {
    const sf = try squarefree(r);
    return single(a, try num.mul(a, try ratio(a, n, d), try num.fromInt(a, sf.sq)), .{ .rad = sf.rad });
}

/// The terms made canonical: sorted, alike merged, zeros dropped.
fn normalize(a: std.mem.Allocator, items: []Term) Error!Sym {
    std.mem.sort(Term, items, {}, struct {
        fn lt(_: void, x: Term, y: Term) bool {
            return Mono.less(x.m, y.m);
        }
    }.lt);
    var out: std.ArrayList(Term) = .empty;
    for (items) |t| {
        if (out.items.len > 0 and Mono.eql(out.items[out.items.len - 1].m, t.m)) {
            out.items[out.items.len - 1].c = try num.add(a, out.items[out.items.len - 1].c, t.c);
        } else try out.append(a, t);
    }
    var keep: usize = 0;
    for (out.items) |t| {
        if (!t.c.isZero()) {
            out.items[keep] = t;
            keep += 1;
        }
    }
    return .{ .terms = out.items[0..keep] };
}

const Squarefree = struct { sq: u64, rad: u64 };

/// n = sq² · rad with rad squarefree.
fn squarefree(n_in: u64) Error!Squarefree {
    var n = n_in;
    var sq: u64 = 1;
    var radicand: u64 = 1;
    var p: u64 = 2;
    while (p * p <= n) : (p += if (p == 2) 1 else 2) {
        if (p > 3_000_000) return error.TooLarge;
        var k: u32 = 0;
        while (n % p == 0) {
            n /= p;
            k += 1;
        }
        var i: u32 = 0;
        while (i < k / 2) : (i += 1) sq *= p;
        if (k % 2 == 1) radicand *= p;
    }
    if (n > 1) radicand *= n;
    return .{ .sq = sq, .rad = radicand };
}

// ---- arithmetic -------------------------------------------------------------------------

pub fn add(a: std.mem.Allocator, x: Sym, y: Sym) Error!Sym {
    const items = try a.alloc(Term, x.terms.len + y.terms.len);
    @memcpy(items[0..x.terms.len], x.terms);
    @memcpy(items[x.terms.len..], y.terms);
    return normalize(a, items);
}

pub fn neg(a: std.mem.Allocator, x: Sym) Error!Sym {
    const items = try a.alloc(Term, x.terms.len);
    for (x.terms, 0..) |t, i| items[i] = .{ .c = try num.neg(a, t.c), .m = t.m };
    return .{ .terms = items };
}

pub fn sub(a: std.mem.Allocator, x: Sym, y: Sym) Error!Sym {
    return add(a, x, try neg(a, y));
}

fn gcd64(x: u64, y: u64) u64 {
    return std.math.gcd(x, y);
}

pub fn mul(a: std.mem.Allocator, x: Sym, y: Sym) Error!Sym {
    var items: std.ArrayList(Term) = .empty;
    for (x.terms) |s| for (y.terms) |t| {
        const g = gcd64(s.m.rad, t.m.rad);
        const radicand = (s.m.rad / g) * (t.m.rad / g);
        const pi_exp = @as(i32, s.m.pi) + t.m.pi;
        const e_exp = @as(i32, s.m.e) + t.m.e;
        if (@abs(pi_exp) > 200 or @abs(e_exp) > 200) return error.TooLarge;
        var c = try num.mul(a, s.c, t.c);
        if (g != 1) c = try num.mul(a, c, try num.fromInt(a, g));
        try items.append(a, .{ .c = c, .m = .{ .pi = @intCast(pi_exp), .e = @intCast(e_exp), .rad = radicand } });
    };
    return normalize(a, items.items);
}

/// 1/x, when x is one term, or two terms without π or e (rationalized with the conjugate).
pub fn inverse(a: std.mem.Allocator, x: Sym) Error!?Sym {
    if (x.terms.len == 0) return error.DivisionByZero;
    if (x.terms.len == 1) {
        const t = x.terms[0];
        // 1 / (c π^a e^b √r) = (1/c) π^-a e^-b √r / r.
        const c = try num.div(a, try num.fromInt(a, 1), try num.mul(a, t.c, try num.fromInt(a, @as(i64, @intCast(t.m.rad)))));
        return try single(a, c, .{ .pi = -t.m.pi, .e = -t.m.e, .rad = t.m.rad });
    }
    if (x.terms.len == 2 and x.terms[0].m.pi == 0 and x.terms[0].m.e == 0 and x.terms[1].m.pi == 0 and x.terms[1].m.e == 0) {
        // (p + q)(p − q) = p² − q²: rational when each of p and q squares to a rational.
        const conj = try add(a, .{ .terms = x.terms[0..1] }, try neg(a, .{ .terms = x.terms[1..2] }));
        const prod = try mul(a, x, conj);
        if (!prod.isRational() or prod.isZero()) return null;
        const inv = (try inverse(a, prod)) orelse return null;
        return try mul(a, conj, inv);
    }
    return null;
}

pub fn div(a: std.mem.Allocator, x: Sym, y: Sym) Error!?Sym {
    const inv = (try inverse(a, y)) orelse return null;
    return try mul(a, x, inv);
}

pub fn powInt(a: std.mem.Allocator, x: Sym, n: i64) Error!?Sym {
    if (n < 0) {
        const inv = (try inverse(a, x)) orelse return null;
        return powInt(a, inv, -n);
    }
    if (n > 200) return error.TooLarge;
    var result = try int(a, 1);
    var i: i64 = 0;
    while (i < n) : (i += 1) result = try mul(a, result, x);
    return result;
}

/// √x for a rational, or a single term that is a perfect square.
pub fn sqrt(a: std.mem.Allocator, x: Sym) Error!?Sym {
    if (x.terms.len == 0) return x;
    if (x.terms.len != 1) return null;
    const t = x.terms[0];
    if (t.c.isNegative()) return null;
    if (t.m.rad != 1 or @mod(t.m.pi, 2) != 0 or @mod(t.m.e, 2) != 0) return null;
    const m: Mono = .{ .pi = @divExact(t.m.pi, 2), .e = @divExact(t.m.e, 2) };
    // √(p/q) = √(pq) / q.
    if (t.c != .exact) return null;
    if (try num.root(a, t.c, 2)) |r| return try single(a, r, m);
    const p = t.c.exact.num.toInt(u64) catch return null;
    const q = t.c.exact.den.toInt(u64) catch return null;
    const sf = try squarefree(std.math.mul(u64, p, q) catch return null);
    const coef = try num.div(a, try num.fromInt(a, sf.sq), try num.fromInt(a, q));
    return try single(a, coef, .{ .pi = m.pi, .e = m.e, .rad = sf.rad });
}

// ---- to a number and to text ----------------------------------------------------------------

/// The value to full precision.
pub fn toNumber(a: std.mem.Allocator, x: Sym) Error!Number {
    var total = try num.fromInt(a, 0);
    for (x.terms) |t| {
        var v = t.c;
        if (t.m.rad != 1) v = try num.mul(a, v, try rootOf(a, t.m.rad));
        if (t.m.pi != 0) v = try num.mul(a, v, try num.pow(a, try piNumber(a), try num.fromInt(a, @as(i64, t.m.pi))));
        if (t.m.e != 0) v = try num.mul(a, v, try num.pow(a, try eNumber(a), try num.fromInt(a, @as(i64, t.m.e))));
        total = try num.add(a, total, v);
    }
    return total;
}

fn rootOf(a: std.mem.Allocator, r: u64) Error!Number {
    const bigreal = @import("bigreal.zig");
    return num.fromReal(try bigreal.sqrt(a, try bigreal.fromInt(a, @intCast(r))));
}

pub fn piNumber(a: std.mem.Allocator) Error!Number {
    const bigreal = @import("bigreal.zig");
    return num.fromReal(try bigreal.pi(a, 8));
}

pub fn eNumber(a: std.mem.Allocator) Error!Number {
    const bigreal = @import("bigreal.zig");
    return num.fromReal(try bigreal.exp(a, try bigreal.one(a)));
}

const sup_digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };

fn writeExp(a: std.mem.Allocator, out: *std.ArrayList(u8), e: i16) !void {
    if (e == 1) return;
    var buf: [8]u8 = undefined;
    if (e < 0) try out.appendSlice(a, "⁻");
    const s = std.fmt.bufPrint(&buf, "{d}", .{@abs(e)}) catch return;
    for (s) |c| try out.appendSlice(a, sup_digits[c - '0']);
}

fn monoText(a: std.mem.Allocator, m: Mono) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (m.rad != 1) try out.print(a, "√{d}", .{m.rad});
    if (m.pi != 0) {
        if (out.items.len > 0) try out.appendSlice(a, "·");
        try out.appendSlice(a, "π");
        try writeExp(a, &out, m.pi);
    }
    if (m.e != 0) {
        if (out.items.len > 0) try out.appendSlice(a, "·");
        try out.appendSlice(a, "e");
        try writeExp(a, &out, m.e);
    }
    return out.items;
}

fn bigText(a: std.mem.Allocator, b: Big) ![]u8 {
    return b.toString(a, 10, .lower) catch return error.OutOfMemory;
}

/// The symbols of a term with positive (or negative) exponents only: "√6", "π²", "".
fn halfText(a: std.mem.Allocator, m: Mono, positive: bool) ![]u8 {
    const kept: Mono = .{
        .pi = if ((m.pi > 0) == positive and m.pi != 0) (if (positive) m.pi else -m.pi) else 0,
        .e = if ((m.e > 0) == positive and m.e != 0) (if (positive) m.e else -m.e) else 0,
        .rad = if (positive) m.rad else 1,
    };
    return monoText(a, kept);
}

/// 2√2, π/4, (1 + √5)/2, (√6 − √2)/4.
pub fn format(a: std.mem.Allocator, x: Sym) Error![]u8 {
    if (x.terms.len == 0) return a.dupe(u8, "0");
    // A single term: coefficient and symbols over a denominator that may hold symbols too (3/(2π)).
    if (x.terms.len == 1) {
        const t = x.terms[0];
        var n = try t.c.exact.num.clone();
        const negative = !n.isPositive();
        n.abs();
        const top = try halfText(a, t.m, true);
        const bottom = try halfText(a, t.m, false);
        const den_one = t.c.exact.den.bitCountAbs() == 1;
        var out: std.ArrayList(u8) = .empty;
        if (negative) try out.appendSlice(a, "−");
        const n_one = n.bitCountAbs() == 1;
        if (top.len == 0 or !n_one) try out.appendSlice(a, try bigText(a, n));
        try out.appendSlice(a, top);
        if (den_one and bottom.len == 0) return out.items;
        try out.append(a, '/');
        const d_text = if (den_one) "" else try bigText(a, t.c.exact.den);
        if (d_text.len > 0 and bottom.len > 0) {
            try out.print(a, "({s}{s})", .{ d_text, bottom });
        } else try out.print(a, "{s}{s}", .{ d_text, bottom });
        return out.items;
    }
    // A sum starts with a positive term when there is one: √6 − √2, not −√2 + √6.
    const ordered = try a.dupe(Term, x.terms);
    if (ordered[0].c.isNegative()) {
        for (ordered, 0..) |t, i| if (!t.c.isNegative()) {
            const keep = ordered[i];
            var j = i;
            while (j > 0) : (j -= 1) ordered[j] = ordered[j - 1];
            ordered[0] = keep;
            break;
        };
    }
    // Common denominator.
    var den = try Big.initSet(a, 1);
    for (ordered) |t| {
        const d = t.c.exact.den;
        var g = try Big.init(a);
        try g.gcd(&den, &d);
        var q = try Big.init(a);
        var r = try Big.init(a);
        try q.divTrunc(&r, &den, &g);
        try den.mul(&q, &d);
    }
    const den_number: Number = .{ .exact = .{ .num = den, .den = try Big.initSet(a, 1) } };
    var sum: std.ArrayList(u8) = .empty;
    for (ordered, 0..) |t, i| {
        const scaled = try num.mul(a, t.c, den_number);
        var n = try scaled.exact.num.clone();
        const negative = !n.isPositive();
        n.abs();
        const body = try monoText(a, t.m);
        if (i == 0) {
            if (negative) try sum.appendSlice(a, "−");
        } else try sum.appendSlice(a, if (negative) " − " else " + ");
        const is_one = n.bitCountAbs() == 1 and n.isPositive();
        if (body.len == 0) {
            try sum.appendSlice(a, try bigText(a, n));
        } else {
            if (!is_one) try sum.appendSlice(a, try bigText(a, n));
            try sum.appendSlice(a, body);
        }
    }
    if (den.bitCountAbs() == 1) return sum.items;
    return std.fmt.allocPrint(a, "({s})/{s}", .{ sum.items, try bigText(a, den) });
}

// ---- trigonometry -------------------------------------------------------------------------------

/// sin(kπ/12) for k = 0…6.
fn sinTable(a: std.mem.Allocator, k: i64) Error!Sym {
    return switch (k) {
        0 => .{ .terms = &.{} },
        1 => try add(a, try surd(a, 1, 4, 6), try surd(a, -1, 4, 2)),
        2 => try rational(a, try ratio(a, 1, 2)),
        3 => try surd(a, 1, 2, 2),
        4 => try surd(a, 1, 2, 3),
        5 => try add(a, try surd(a, 1, 4, 6), try surd(a, 1, 4, 2)),
        else => try int(a, 1),
    };
}

/// sin(kπ/12) for any whole k.
fn sinK(a: std.mem.Allocator, k_in: i64) Error!Sym {
    const k = @mod(k_in, 24);
    if (k <= 6) return sinTable(a, k);
    if (k <= 12) return sinTable(a, 12 - k);
    if (k <= 18) return neg(a, try sinTable(a, k - 12));
    return neg(a, try sinTable(a, 24 - k));
}

/// The angle x as k/12 turns of π (an integer k), if it is that.
fn twelfths(a: std.mem.Allocator, x: Sym) Error!?i64 {
    if (x.terms.len == 0) return 0;
    if (x.terms.len != 1) return null;
    const t = x.terms[0];
    if (t.m.pi != 1 or t.m.e != 0 or t.m.rad != 1) return null;
    const k = try num.mul(a, t.c, try num.fromInt(a, 12));
    return num.intValue(k);
}

/// An angle in the chosen unit as a multiple of π.
fn toRadians(a: std.mem.Allocator, x: Sym, angle: eval.Angle) Error!Sym {
    const full: i64 = switch (angle) {
        .radians => return x,
        .degrees => 180,
        .gradians => 200,
    };
    return mul(a, x, try single(a, try ratio(a, 1, full), .{ .pi = 1 }));
}

fn fromRadians(a: std.mem.Allocator, x: Sym, angle: eval.Angle) Error!?Sym {
    const full: i64 = switch (angle) {
        .radians => return x,
        .degrees => 180,
        .gradians => 200,
    };
    // Back to a plain number of degrees: multiply by full/π.
    return try mul(a, x, try single(a, try num.fromInt(a, full), .{ .pi = -1 }));
}

fn trig(a: std.mem.Allocator, name: []const u8, arg: Sym, angle: eval.Angle) Error!?Sym {
    const eql = std.mem.eql;
    const angle_rad = try toRadians(a, arg, angle);
    const k = (try twelfths(a, angle_rad)) orelse return null;
    const s = try sinK(a, k);
    const c = try sinK(a, k + 6);
    if (eql(u8, name, "sin")) return s;
    if (eql(u8, name, "cos")) return c;
    if (eql(u8, name, "tan")) {
        if (c.isZero()) return error.Domain;
        return try div(a, s, c);
    }
    if (eql(u8, name, "sec")) {
        if (c.isZero()) return error.Domain;
        return try inverse(a, c);
    }
    if (eql(u8, name, "csc")) {
        if (s.isZero()) return error.Domain;
        return try inverse(a, s);
    }
    if (s.isZero()) return error.Domain;
    return try div(a, c, s);
}

fn sameSym(x: Sym, y: Sym) bool {
    if (x.terms.len != y.terms.len) return false;
    for (x.terms, y.terms) |s, t| {
        if (!Mono.eql(s.m, t.m)) return false;
        if (s.c != .exact or t.c != .exact) return false;
        if (!s.c.exact.num.eql(t.c.exact.num) or !s.c.exact.den.eql(t.c.exact.den)) return false;
    }
    return true;
}

fn inverseTrig(a: std.mem.Allocator, name: []const u8, x: Sym, angle: eval.Angle) Error!?Sym {
    const eql = std.mem.eql;
    var k: i64 = -12;
    var found: ?i64 = null;
    while (k <= 12) : (k += 1) {
        const value: ?Sym = if (eql(u8, name, "asin"))
            (if (k >= -6 and k <= 6) try sinK(a, k) else null)
        else if (eql(u8, name, "acos"))
            (if (k >= 0 and k <= 12) try sinK(a, k + 6) else null)
        else if (k >= -5 and k <= 5) blk: {
            const s = try sinK(a, k);
            const c = try sinK(a, k + 6);
            break :blk try div(a, s, c);
        } else null;
        if (value) |v| if (sameSym(v, x)) {
            found = k;
            break;
        };
    }
    const kk = found orelse return null;
    const angle_rad = try single(a, try ratio(a, kk, 12), .{ .pi = 1 });
    return try fromRadians(a, angle_rad, angle);
}

// ---- evaluating an entry ----------------------------------------------------------------------

pub const Ctx = struct {
    a: std.mem.Allocator,
    session: *eval.Session,
    mode: eval.Mode,
};

/// Does the entry use anything this module gives an exact form to?
pub fn worthTrying(n: *const Node, session: *eval.Session) bool {
    return switch (n.*) {
        .number => false,
        .name => |nm| isConstantName(nm.text) and !session.vars.contains(nm.text),
        .unary => |u| worthTrying(u.arg, session),
        .binary => |b| worthTrying(b.l, session) or worthTrying(b.r, session),
        .call => |c| blk: {
            if (isFunction(c.name) and !session.funcs.contains(c.name)) break :blk true;
            for (c.args) |x| if (worthTrying(x, session)) break :blk true;
            break :blk false;
        },
    };
}

fn isConstantName(name: []const u8) bool {
    inline for (.{ "pi", "π", "e", "tau", "τ", "phi", "φ" }) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

fn isFunction(name: []const u8) bool {
    inline for (.{ "sqrt", "cbrt", "sin", "cos", "tan", "sec", "csc", "cot", "asin", "acos", "atan", "exp", "ln" }) |c| {
        if (std.ascii.eqlIgnoreCase(name, c)) return true;
    }
    return false;
}

/// The exact form of an entry, or null when it has none here.
pub fn evaluate(ctx: Ctx, n: *const Node) Error!?Sym {
    return ev(ctx, n) catch |e| switch (e) {
        error.UnknownName, error.WrongArguments, error.Syntax => null,
        else => e,
    };
}

fn ev(ctx: Ctx, n: *const Node) Error!?Sym {
    const a = ctx.a;
    switch (n.*) {
        .number => |v| {
            if (!v.isExact()) return null;
            return try rational(a, v);
        },
        .name => |nm| {
            const t = nm.text;
            if (ctx.session.vars.get(t)) |s| {
                const v = try s.load(a);
                if (!v.isExact()) return null;
                return try rational(a, v);
            }
            if (std.mem.eql(u8, t, "ans")) {
                if (ctx.session.ans) |s| {
                    const v = try s.load(a);
                    if (!v.isExact()) return null;
                    return try rational(a, v);
                }
                return null;
            }
            if (std.mem.eql(u8, t, "pi") or std.mem.eql(u8, t, "π")) return try single(a, try num.fromInt(a, 1), .{ .pi = 1 });
            if (std.mem.eql(u8, t, "tau") or std.mem.eql(u8, t, "τ")) return try single(a, try num.fromInt(a, 2), .{ .pi = 1 });
            if (std.mem.eql(u8, t, "e")) return try single(a, try num.fromInt(a, 1), .{ .e = 1 });
            if (std.mem.eql(u8, t, "phi") or std.mem.eql(u8, t, "φ")) return try add(a, try rational(a, try ratio(a, 1, 2)), try surd(a, 1, 2, 5));
            return null;
        },
        .unary => |u| {
            const x = (try ev(ctx, u.arg)) orelse return null;
            switch (u.op) {
                .neg => return try neg(a, x),
                .pct => return try mul(a, x, try rational(a, try ratio(a, 1, 100))),
                .fact => {
                    if (!x.isRational() or x.terms.len == 0) return null;
                    return try rational(a, try num.factorial(a, x.terms[0].c));
                },
                .bnot => return null,
            }
        },
        .binary => |b| {
            const x = (try ev(ctx, b.l)) orelse return null;
            const y = (try ev(ctx, b.r)) orelse return null;
            switch (b.op) {
                .add => return try add(a, x, y),
                .sub => return try sub(a, x, y),
                .mul => return try mul(a, x, y),
                .div => return try div(a, x, y),
                .add_pct => return try add(a, x, try mul(a, try mul(a, x, y), try rational(a, try ratio(a, 1, 100)))),
                .sub_pct => return try sub(a, x, try mul(a, try mul(a, x, y), try rational(a, try ratio(a, 1, 100)))),
                .pow => return try power(ctx, x, y),
                else => return null,
            }
        },
        .call => |c| {
            if (ctx.session.funcs.contains(c.name)) return null;
            var buf: [16]u8 = undefined;
            if (c.name.len > buf.len) return null;
            const name = std.ascii.lowerString(&buf, c.name);
            if (!isFunction(name)) return null;
            if (c.args.len != 1) return null;
            const x = (try ev(ctx, c.args[0])) orelse return null;
            return try function(ctx, name, x);
        },
    }
}

fn power(ctx: Ctx, x: Sym, y: Sym) Error!?Sym {
    const a = ctx.a;
    if (!y.isRational()) return null;
    if (y.terms.len == 0) return try int(a, 1);
    const e = y.terms[0].c;
    if (e.isInteger()) {
        const k = num.intValue(e) orelse return null;
        return try powInt(a, x, k);
    }
    // A fraction p/q: √ for 1/2, a whole root of a rational otherwise.
    if (e != .exact) return null;
    const q = e.exact.den.toInt(u32) catch return null;
    const p = e.exact.num.toInt(i64) catch return null;
    if (q == 2) {
        const r = (try sqrt(a, x)) orelse return null;
        return try powInt(a, r, p);
    }
    if (x.isRational() and x.terms.len == 1) {
        const r = (try num.root(a, x.terms[0].c, q)) orelse return null;
        return try powInt(a, try rational(a, r), p);
    }
    return null;
}

fn function(ctx: Ctx, name: []const u8, x: Sym) Error!?Sym {
    const a = ctx.a;
    const eql = std.mem.eql;
    if (eql(u8, name, "sqrt")) {
        if (x.terms.len == 1 and x.terms[0].c.isNegative()) return null;
        return try sqrt(a, x);
    }
    if (eql(u8, name, "cbrt")) {
        if (x.isRational() and x.terms.len == 1) {
            const r = (try num.root(a, x.terms[0].c, 3)) orelse return null;
            return try rational(a, r);
        }
        return null;
    }
    if (eql(u8, name, "exp")) {
        if (x.isZero()) return try int(a, 1);
        if (x.isRational()) {
            const k = num.intValue(x.terms[0].c) orelse return null;
            if (@abs(k) > 100) return null;
            return try single(a, try num.fromInt(a, 1), .{ .e = @intCast(k) });
        }
        return null;
    }
    if (eql(u8, name, "ln")) {
        if (x.terms.len == 1 and x.terms[0].c.isExact()) {
            const t = x.terms[0];
            if (num.isOneNumber(t.c) and t.m.pi == 0 and t.m.rad == 1) return try int(a, t.m.e);
        }
        return null;
    }
    if (eql(u8, name, "asin") or eql(u8, name, "acos") or eql(u8, name, "atan")) return try inverseTrig(a, name, x, ctx.mode.angle);
    return try trig(a, name, x, ctx.mode.angle);
}

// ---- tests ------------------------------------------------------------------------------------

fn shows(want: []const u8, text: []const u8, mode: eval.Mode) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const st = try eval.parse(a, text, mode, &p);
    const sym = (try evaluate(.{ .a = a, .session = &session, .mode = mode }, st.expr)) orelse {
        std.debug.print("no exact form for {s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    std.testing.expectEqualStrings(want, try format(a, sym)) catch |e| {
        std.debug.print("for {s}\n", .{text});
        return e;
    };
}

const rmode: eval.Mode = .{ .angle = .radians };
const dmode: eval.Mode = .{ .angle = .degrees };

test "surds" {
    try shows("2√2", "sqrt(8)", rmode);
    try shows("√6", "sqrt(2)*sqrt(3)", rmode);
    try shows("√2/2", "sqrt(1/2)", rmode);
    try shows("2", "sqrt(2)*sqrt(2)", rmode);
    try shows("2√2", "sqrt(2)^3", rmode);
    try shows("(1 + √5)/2", "(1+sqrt(5))/2", rmode);
    try shows("√2 − 1", "1/(1+sqrt(2))", rmode);
    try shows("√3/3", "1/sqrt(3)", rmode);
    try shows("3√2", "sqrt(18)", rmode);
    try shows("√10", "sqrt(10)", rmode);
    try shows("5", "(sqrt(5))^2", rmode);
}

test "pi and e" {
    try shows("π", "pi/4*4", rmode);
    try shows("π/4", "pi/4", rmode);
    try shows("3π/4", "3*pi/4", rmode);
    try shows("2π", "tau", rmode);
    try shows("π²", "pi^2", rmode);
    try shows("e²", "e^2", rmode);
    try shows("1/π", "1/pi", rmode);
    try shows("2 + π", "2+pi", rmode);
    try shows("√2·π", "sqrt(2)*pi", rmode);
}

test "exact trigonometry" {
    try shows("1/2", "sin(pi/6)", rmode);
    try shows("√2/2", "cos(pi/4)", rmode);
    try shows("√3", "tan(pi/3)", rmode);
    try shows("(√6 − √2)/4", "sin(pi/12)", rmode);
    try shows("−√3/2", "sin(4*pi/3)", rmode);
    try shows("√2/2", "sin(45)", dmode);
    try shows("√3/2", "cos(30)", dmode);
    try shows("π/4", "asin(sqrt(2)/2)", rmode);
    try shows("π/6", "atan(1/sqrt(3))", rmode);
    try shows("π/3", "acos(1/2)", rmode);
    try shows("45", "atan(1)", dmode);
    try shows("2 + √3", "tan(75)", dmode);
}

test "values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try add(a, try surd(a, 1, 1, 2), try int(a, 1));
    const v = try toNumber(a, s);
    try std.testing.expectEqualStrings("2.4142135623730950488", try num.format(a, v, .{ .decimals = 20 }));
}
