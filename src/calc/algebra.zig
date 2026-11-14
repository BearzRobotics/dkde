//! Exact algebra on polynomials with rational coefficients: expand, factor over the
//! rationals, cancel common factors of a fraction, and solve polynomial equations in
//! exact form (rational roots, square roots, complex pairs).
//!
//! A polynomial is a list of terms; a term is a rational coefficient and an exponent for
//! each letter. Univariate work (factoring, solving) uses dense coefficient lists,
//! lowest power first.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const symbolic = @import("symbolic.zig");
const Number = num.Number;
const Big = std.math.big.int.Managed;
const Node = eval.Node;

pub const Error = eval.Error;

// ---- polynomials ------------------------------------------------------------------------

pub const PTerm = struct { c: Number, exps: []const u16 };

pub const Poly = struct {
    /// The letters, in the order the exponents use.
    vars: []const []const u8,
    terms: []const PTerm,

    pub fn isZero(self: Poly) bool {
        return self.terms.len == 0;
    }
};

pub const Ctx = struct {
    a: std.mem.Allocator,
    session: *eval.Session,
};

fn zeroExps(a: std.mem.Allocator, n: usize) Error![]u16 {
    const e = try a.alloc(u16, n);
    @memset(e, 0);
    return e;
}

fn varIndex(vars: *std.ArrayList([]const u8), a: std.mem.Allocator, name: []const u8) Error!usize {
    for (vars.items, 0..) |v, i| if (std.mem.eql(u8, v, name)) return i;
    try vars.append(a, name);
    return vars.items.len - 1;
}

/// Terms re-indexed to a longer list of letters.
fn widen(a: std.mem.Allocator, terms: []const PTerm, n: usize) Error![]PTerm {
    const out = try a.alloc(PTerm, terms.len);
    for (terms, 0..) |t, i| {
        const e = try zeroExps(a, n);
        @memcpy(e[0..t.exps.len], t.exps);
        out[i] = .{ .c = t.c, .exps = e };
    }
    return out;
}

fn expsEql(x: []const u16, y: []const u16) bool {
    return std.mem.eql(u16, x, y);
}

fn tidy(a: std.mem.Allocator, items: []PTerm) Error![]const PTerm {
    var out: std.ArrayList(PTerm) = .empty;
    outer: for (items) |t| {
        if (t.c.isZero()) continue;
        for (out.items) |*o| if (expsEql(o.exps, t.exps)) {
            o.c = try num.add(a, o.c, t.c);
            continue :outer;
        };
        try out.append(a, t);
    }
    var keep: usize = 0;
    for (out.items) |t| {
        if (!t.c.isZero()) {
            out.items[keep] = t;
            keep += 1;
        }
    }
    return out.items[0..keep];
}

pub fn constant(a: std.mem.Allocator, c: Number) Error!Poly {
    if (c.isZero()) return .{ .vars = &.{}, .terms = &.{} };
    const t = try a.alloc(PTerm, 1);
    t[0] = .{ .c = c, .exps = &.{} };
    return .{ .vars = &.{}, .terms = t };
}

/// Puts two polynomials on the same list of letters.
fn align2(a: std.mem.Allocator, x: Poly, y: Poly) Error!struct { vars: []const []const u8, x: []PTerm, y: []PTerm } {
    var vars: std.ArrayList([]const u8) = .empty;
    for (x.vars) |v| _ = try varIndex(&vars, a, v);
    var ymap = try a.alloc(usize, y.vars.len);
    for (y.vars, 0..) |v, i| ymap[i] = try varIndex(&vars, a, v);
    const xt = try widen(a, x.terms, vars.items.len);
    const yt = try a.alloc(PTerm, y.terms.len);
    for (y.terms, 0..) |t, i| {
        const e = try zeroExps(a, vars.items.len);
        for (t.exps, 0..) |p, j| e[ymap[j]] = p;
        yt[i] = .{ .c = t.c, .exps = e };
    }
    return .{ .vars = vars.items, .x = xt, .y = yt };
}

pub fn add(a: std.mem.Allocator, x: Poly, y: Poly) Error!Poly {
    const p = try align2(a, x, y);
    const items = try a.alloc(PTerm, p.x.len + p.y.len);
    @memcpy(items[0..p.x.len], p.x);
    @memcpy(items[p.x.len..], p.y);
    return .{ .vars = p.vars, .terms = try tidy(a, items) };
}

pub fn scale(a: std.mem.Allocator, x: Poly, c: Number) Error!Poly {
    const items = try a.alloc(PTerm, x.terms.len);
    for (x.terms, 0..) |t, i| items[i] = .{ .c = try num.mul(a, t.c, c), .exps = t.exps };
    return .{ .vars = x.vars, .terms = try tidy(a, items) };
}

pub fn sub(a: std.mem.Allocator, x: Poly, y: Poly) Error!Poly {
    return add(a, x, try scale(a, y, try num.fromInt(a, -1)));
}

pub fn mul(a: std.mem.Allocator, x: Poly, y: Poly) Error!Poly {
    const p = try align2(a, x, y);
    var items: std.ArrayList(PTerm) = .empty;
    for (p.x) |s| for (p.y) |t| {
        const e = try zeroExps(a, p.vars.len);
        for (e, 0..) |*slot, i| {
            const sum = @as(u32, s.exps[i]) + t.exps[i];
            if (sum > 1000) return error.TooLarge;
            slot.* = @intCast(sum);
        }
        try items.append(a, .{ .c = try num.mul(a, s.c, t.c), .exps = e });
        if (items.items.len > 200_000) return error.TooLarge;
    };
    return .{ .vars = p.vars, .terms = try tidy(a, items.items) };
}

pub fn powInt(a: std.mem.Allocator, x: Poly, n: u32) Error!Poly {
    if (n > 200) return error.TooLarge;
    var result = try constant(a, try num.fromInt(a, 1));
    var base = x;
    var k = n;
    while (k > 0) : (k >>= 1) {
        if (k & 1 == 1) result = try mul(a, result, base);
        if (k > 1) base = try mul(a, base, base);
    }
    return result;
}

fn isConstant(x: Poly) bool {
    if (x.terms.len == 0) return true;
    if (x.terms.len > 1) return false;
    for (x.terms[0].exps) |e| if (e != 0) return false;
    return true;
}

fn constValue(a: std.mem.Allocator, x: Poly) Error!Number {
    if (x.terms.len == 0) return num.fromInt(a, 0);
    return x.terms[0].c;
}

/// An entry as a polynomial: letters without a value are the variables. Null when it is
/// not one (a function of a letter, a letter in a denominator, a fractional power).
pub fn fromNode(ctx: Ctx, n: *const Node) Error!?Poly {
    const a = ctx.a;
    switch (n.*) {
        .number => |v| {
            if (!v.isExact()) return null;
            return try constant(a, v);
        },
        .name => |nm| {
            if (ctx.session.vars.get(nm.text)) |s| {
                const v = try s.load(a);
                if (!v.isExact()) return null;
                return try constant(a, v);
            }
            if (eval.isConstant(nm.text)) return null;
            const vars = try a.alloc([]const u8, 1);
            vars[0] = nm.text;
            const e = try a.alloc(u16, 1);
            e[0] = 1;
            const t = try a.alloc(PTerm, 1);
            t[0] = .{ .c = try num.fromInt(a, 1), .exps = e };
            return .{ .vars = vars, .terms = t };
        },
        .unary => |u| {
            const x = (try fromNode(ctx, u.arg)) orelse return null;
            return switch (u.op) {
                .neg => try scale(a, x, try num.fromInt(a, -1)),
                .pct => try scale(a, x, try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 100))),
                else => null,
            };
        },
        .binary => |b| {
            const x = (try fromNode(ctx, b.l)) orelse return null;
            const y = (try fromNode(ctx, b.r)) orelse return null;
            switch (b.op) {
                .add => return try add(a, x, y),
                .sub => return try sub(a, x, y),
                .mul => return try mul(a, x, y),
                .div => {
                    if (!isConstant(y)) return null;
                    const d = try constValue(a, y);
                    if (d.isZero()) return error.DivisionByZero;
                    return try scale(a, x, try num.div(a, try num.fromInt(a, 1), d));
                },
                .pow => {
                    if (!isConstant(y)) return null;
                    const e = try constValue(a, y);
                    if (!e.isInteger()) return null;
                    const k = num.intValue(e) orelse return null;
                    if (k >= 0) return try powInt(a, x, @intCast(k));
                    if (!isConstant(x)) return null;
                    return try constant(a, try num.pow(a, try constValue(a, x), e));
                },
                else => return null,
            }
        },
        .call => return null,
    }
}

// ---- writing ------------------------------------------------------------------------------

const sup_digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };

fn bigText(a: std.mem.Allocator, b: Big) ![]u8 {
    return b.toString(a, 10, .lower) catch return error.OutOfMemory;
}

fn exponentText(a: std.mem.Allocator, out: *std.ArrayList(u8), e: u16) !void {
    if (e == 1) return;
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{e}) catch return;
    for (s) |c| try out.appendSlice(a, sup_digits[c - '0']);
}

fn termOrder(vars: []const []const u8, x: PTerm, y: PTerm) bool {
    _ = vars;
    var dx: u32 = 0;
    var dy: u32 = 0;
    for (x.exps) |e| dx += e;
    for (y.exps) |e| dy += e;
    if (dx != dy) return dx > dy;
    for (x.exps, y.exps) |p, q| if (p != q) return p > q;
    return false;
}

/// The letters sorted alphabetically (so x² + 2xy + y², not y² + …).
fn sortedVars(a: std.mem.Allocator, p: Poly) Error!Poly {
    const order = try a.alloc(usize, p.vars.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, p.vars, struct {
        fn lt(vars: []const []const u8, i: usize, j: usize) bool {
            return std.mem.lessThan(u8, vars[i], vars[j]);
        }
    }.lt);
    const vars = try a.alloc([]const u8, p.vars.len);
    for (order, 0..) |o, i| vars[i] = p.vars[o];
    const terms = try a.alloc(PTerm, p.terms.len);
    for (p.terms, 0..) |t, ti| {
        const e = try a.alloc(u16, t.exps.len);
        for (order, 0..) |o, i| e[i] = t.exps[o];
        terms[ti] = .{ .c = t.c, .exps = e };
    }
    return .{ .vars = vars, .terms = terms };
}

/// A letter as a polynomial.
pub fn variable(a: std.mem.Allocator, name: []const u8) Error!Poly {
    const vars = try a.alloc([]const u8, 1);
    vars[0] = name;
    const e = try a.alloc(u16, 1);
    e[0] = 1;
    const t = try a.alloc(PTerm, 1);
    t[0] = .{ .c = try num.fromInt(a, 1), .exps = e };
    return .{ .vars = vars, .terms = t };
}

/// The terms in the order they are written (highest degree first), with the letters sorted.
pub fn orderedTerms(a: std.mem.Allocator, poly: Poly) Error!Poly {
    const p = try sortedVars(a, poly);
    const sorted = try a.dupe(PTerm, p.terms);
    std.mem.sort(PTerm, sorted, p.vars, termOrder);
    return .{ .vars = p.vars, .terms = sorted };
}

/// "x² + 2xy + y²", "3x/2 − 1", "x⁴ − 1". Highest degree first.
pub fn text(a: std.mem.Allocator, poly: Poly) Error![]u8 {
    if (poly.terms.len == 0) return a.dupe(u8, "0");
    const p = try sortedVars(a, poly);
    const sorted = try a.dupe(PTerm, p.terms);
    std.mem.sort(PTerm, sorted, p.vars, termOrder);
    var out: std.ArrayList(u8) = .empty;
    for (sorted, 0..) |t, i| {
        const negative = t.c.isNegative();
        if (i == 0) {
            if (negative) try out.appendSlice(a, "−");
        } else try out.appendSlice(a, if (negative) " − " else " + ");
        const n = if (negative) try num.neg(a, t.c) else t.c;
        var has_var = false;
        for (t.exps) |e| if (e != 0) {
            has_var = true;
        };
        const nbig = n.exact.num;
        const dbig = n.exact.den;
        const den_one = dbig.bitCountAbs() == 1;
        const num_one = nbig.bitCountAbs() == 1;
        if (!has_var) {
            if (den_one) {
                try out.appendSlice(a, try bigText(a, nbig));
            } else try out.print(a, "{s}/{s}", .{ try bigText(a, nbig), try bigText(a, dbig) });
            continue;
        }
        if (!num_one) try out.appendSlice(a, try bigText(a, nbig));
        for (t.exps, 0..) |e, vi| if (e != 0) {
            try out.appendSlice(a, p.vars[vi]);
            try exponentText(a, &out, e);
        };
        if (!den_one) try out.print(a, "/{s}", .{try bigText(a, dbig)});
    }
    return out.items;
}

// ---- dense univariate polynomials ------------------------------------------------------------------

pub const Coefs = []Number;

pub fn degree(c: []const Number) usize {
    var d = c.len;
    while (d > 0 and c[d - 1].isZero()) d -= 1;
    return if (d == 0) 0 else d - 1;
}

pub fn trimmed(c: []const Number) []const Number {
    var d = c.len;
    while (d > 0 and c[d - 1].isZero()) d -= 1;
    return c[0..d];
}

/// A polynomial in one letter as coefficients, lowest power first (null: more letters).
pub fn dense(a: std.mem.Allocator, p: Poly, name: []const u8) Error!?Coefs {
    var vi: ?usize = null;
    for (p.vars, 0..) |v, i| if (std.mem.eql(u8, v, name)) {
        vi = i;
    };
    var max_exp: usize = 0;
    for (p.terms) |t| {
        for (t.exps, 0..) |e, i| {
            if (e != 0 and (vi == null or i != vi.?)) return null;
        }
        if (vi) |i| max_exp = @max(max_exp, t.exps[i]);
    }
    const out = try a.alloc(Number, max_exp + 1);
    for (out) |*o| o.* = try num.fromInt(a, 0);
    for (p.terms) |t| {
        const e: usize = if (vi) |i| t.exps[i] else 0;
        out[e] = try num.add(a, out[e], t.c);
    }
    return out;
}

pub fn fromDense(a: std.mem.Allocator, c: []const Number, name: []const u8) Error!Poly {
    const vars = try a.alloc([]const u8, 1);
    vars[0] = name;
    var terms: std.ArrayList(PTerm) = .empty;
    for (c, 0..) |v, i| {
        if (v.isZero()) continue;
        const e = try a.alloc(u16, 1);
        e[0] = @intCast(i);
        try terms.append(a, .{ .c = v, .exps = e });
    }
    return .{ .vars = vars, .terms = terms.items };
}

pub const DivMod = struct { q: Coefs, r: Coefs };

pub fn divmod(a: std.mem.Allocator, n_in: []const Number, d_in: []const Number) Error!DivMod {
    const n = trimmed(n_in);
    const d = trimmed(d_in);
    if (d.len == 0) return error.DivisionByZero;
    if (n.len < d.len) return .{ .q = try a.alloc(Number, 0), .r = try a.dupe(Number, n) };
    const r = try a.dupe(Number, n);
    const q = try a.alloc(Number, n.len - d.len + 1);
    for (q) |*x| x.* = try num.fromInt(a, 0);
    var i = n.len - d.len + 1;
    while (i > 0) {
        i -= 1;
        const quotient = try num.div(a, r[i + d.len - 1], d[d.len - 1]);
        q[i] = quotient;
        if (quotient.isZero()) continue;
        for (d, 0..) |dc, j| r[i + j] = try num.sub(a, r[i + j], try num.mul(a, quotient, dc));
    }
    return .{ .q = q, .r = r };
}

pub fn evalAt(a: std.mem.Allocator, c: []const Number, x: Number) Error!Number {
    var v = try num.fromInt(a, 0);
    var i = c.len;
    while (i > 0) {
        i -= 1;
        v = try num.add(a, try num.mul(a, v, x), c[i]);
    }
    return v;
}

fn bigGcd(a: std.mem.Allocator, x: Big, y: Big) Error!Big {
    var g = try Big.init(a);
    var xa = try x.clone();
    var ya = try y.clone();
    xa.abs();
    ya.abs();
    try g.gcd(&xa, &ya);
    return g;
}

/// Scales to whole-number coefficients with no common factor and a positive leading
/// coefficient: returns the primitive polynomial and the rational factor that was taken out.
pub fn primitive(a: std.mem.Allocator, c_in: []const Number) Error!struct { prim: Coefs, content: Number } {
    const c = trimmed(c_in);
    var lcm = try Big.initSet(a, 1);
    for (c) |v| {
        const g = try bigGcd(a, lcm, v.exact.den);
        var q = try Big.init(a);
        var r = try Big.init(a);
        try q.divTrunc(&r, &lcm, &g);
        try lcm.mul(&q, &v.exact.den);
    }
    const lcm_n: Number = .{ .exact = .{ .num = lcm, .den = try Big.initSet(a, 1) } };
    var g = try Big.initSet(a, 0);
    const ints = try a.alloc(Number, c.len);
    for (c, 0..) |v, i| {
        ints[i] = try num.mul(a, v, lcm_n);
        g = try bigGcd(a, g, ints[i].exact.num);
    }
    if (g.eqlZero()) return .{ .prim = ints, .content = try num.fromInt(a, 1) };
    const g_n: Number = .{ .exact = .{ .num = g, .den = try Big.initSet(a, 1) } };
    var content = try num.div(a, g_n, lcm_n);
    const prim = try a.alloc(Number, c.len);
    for (ints, 0..) |v, i| prim[i] = try num.div(a, v, g_n);
    if (c.len > 0 and prim[c.len - 1].isNegative()) {
        for (prim) |*pv| pv.* = try num.neg(a, pv.*);
        content = try num.neg(a, content);
    }
    return .{ .prim = prim, .content = content };
}

/// The positive divisors of |n|, when n is not too large to factor by trial division.
pub fn divisors(a: std.mem.Allocator, n: Number) Error!?[]u64 {
    const v = num.intValue(n) orelse return null;
    var m: u64 = @abs(v);
    if (m == 0) return null;
    if (m > 1_000_000_000_000) return null;
    var out: std.ArrayList(u64) = .empty;
    var i: u64 = 1;
    while (i * i <= m) : (i += 1) {
        if (m % i == 0) {
            try out.append(a, i);
            if (i != m / i) try out.append(a, m / i);
        }
    }
    m = 0;
    return out.items;
}

pub const Factor = struct { coefs: Coefs, mult: u32 };

pub const Factored = struct {
    content: Number,
    factors: []Factor,
};

fn sameCoefs(x: []const Number, y: []const Number) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (!p.exact.num.eql(q.exact.num) or !p.exact.den.eql(q.exact.den)) return false;
    }
    return true;
}

fn addFactor(a: std.mem.Allocator, list: *std.ArrayList(Factor), coefs: Coefs) Error!void {
    for (list.items) |*f| if (sameCoefs(f.coefs, coefs)) {
        f.mult += 1;
        return;
    };
    try list.append(a, .{ .coefs = coefs, .mult = 1 });
}

/// A rational root of the polynomial, as the primitive linear factor (qx − p).
fn rationalRoot(a: std.mem.Allocator, c: []const Number) Error!?Coefs {
    const d = degree(c);
    if (d == 0) return null;
    // A root of 0.
    if (c[0].isZero()) {
        const f = try a.alloc(Number, 2);
        f[0] = try num.fromInt(a, 0);
        f[1] = try num.fromInt(a, 1);
        return f;
    }
    const pr = try primitive(a, c);
    const ps = (try divisors(a, pr.prim[0])) orelse return null;
    const qs = (try divisors(a, pr.prim[pr.prim.len - 1])) orelse return null;
    if (ps.len * qs.len > 200_000) return null;
    for (qs) |q| for (ps) |p| {
        var sign: i64 = 1;
        while (sign >= -1) : (sign -= 2) {
            const r = try num.div(a, try num.fromInt(a, sign * @as(i64, @intCast(p))), try num.fromInt(a, @as(i64, @intCast(q))));
            // gcd(p, q) = 1 only: others are the same root again.
            if (std.math.gcd(p, q) != 1) continue;
            if ((try evalAt(a, c, r)).isZero()) {
                const f = try a.alloc(Number, 2);
                f[0] = try num.fromInt(a, -sign * @as(i64, @intCast(p)));
                f[1] = try num.fromInt(a, @as(i64, @intCast(q)));
                return f;
            }
        }
    };
    return null;
}

/// Factors over the rationals as far as rational roots and a square in x² go.
pub fn factorDense(a: std.mem.Allocator, c_in: []const Number) Error!Factored {
    var current = try a.dupe(Number, trimmed(c_in));
    var list: std.ArrayList(Factor) = .empty;
    while (degree(current) >= 1 and current.len > 1) {
        const f = (try rationalRoot(a, current)) orelse break;
        const dm = try divmod(a, current, f);
        current = try a.dupe(Number, trimmed(dm.q));
        try addFactor(a, &list, f);
    }
    // x⁴ + bx² + c: a quadratic in x².
    if (degree(current) == 4 and current[1].isZero() and current[3].isZero()) {
        const pr = try primitive(a, current);
        // a y² + b y + c with y = x²
        const qa = pr.prim[4];
        const qb = pr.prim[2];
        const qc = pr.prim[0];
        const disc = try num.sub(a, try num.mul(a, qb, qb), try num.mul(a, try num.fromInt(a, 4), try num.mul(a, qa, qc)));
        if (!disc.isNegative()) if (try num.root(a, disc, 2)) |sq| {
            const two_a = try num.mul(a, try num.fromInt(a, 2), qa);
            const y1 = try num.div(a, try num.sub(a, sq, qb), two_a);
            const y2 = try num.div(a, try num.sub(a, try num.neg(a, qb), sq), two_a);
            // (x² − y1)(x² − y2), each made primitive.
            var rest = current;
            for ([_]Number{ y1, y2 }) |y| {
                const f2 = try a.alloc(Number, 3);
                f2[0] = try num.neg(a, y);
                f2[1] = try num.fromInt(a, 0);
                f2[2] = try num.fromInt(a, 1);
                const p2 = try primitive(a, f2);
                rest = try a.dupe(Number, trimmed((try divmod(a, rest, p2.prim)).q));
                try addFactor(a, &list, p2.prim);
            }
            current = rest;
        };
    }
    const pr = try primitive(a, current);
    var content = pr.content;
    if (degree(current) >= 1 and current.len > 1) try addFactor(a, &list, pr.prim);
    if (degree(current) == 0 or current.len <= 1) {
        content = if (current.len == 0) try num.fromInt(a, 0) else current[0];
    }
    // The factors are monic-free primitive polynomials: fold their leading coefficients
    // into the content so that the product is the original.
    var product = try a.alloc(Number, 1);
    product[0] = try num.fromInt(a, 1);
    for (list.items) |f| {
        var k: u32 = 0;
        while (k < f.mult) : (k += 1) product = try mulDense(a, product, f.coefs);
    }
    const total = trimmed(c_in);
    if (total.len > 0 and product.len > 0) {
        content = try num.div(a, total[total.len - 1], product[product.len - 1]);
    }
    // Ascending order by degree, then by the constant term.
    std.mem.sort(Factor, list.items, {}, struct {
        fn lt(_: void, x: Factor, y: Factor) bool {
            if (x.coefs.len != y.coefs.len) return x.coefs.len < y.coefs.len;
            const xc = x.coefs[0].toFloat();
            const yc = y.coefs[0].toFloat();
            if (@abs(xc) != @abs(yc)) return @abs(xc) < @abs(yc);
            return xc < yc;
        }
    }.lt);
    return .{ .content = content, .factors = list.items };
}

pub fn mulDense(a: std.mem.Allocator, x: []const Number, y: []const Number) Error!Coefs {
    const out = try a.alloc(Number, x.len + y.len - 1);
    for (out) |*o| o.* = try num.fromInt(a, 0);
    for (x, 0..) |p, i| for (y, 0..) |q, j| {
        out[i + j] = try num.add(a, out[i + j], try num.mul(a, p, q));
    };
    return out;
}

fn numberText(a: std.mem.Allocator, v: Number) Error![]u8 {
    return num.format(a, v, .{ .decimals = 30 });
}

/// "2(x − 3)²(x² + 1)", "(x − 1)(x + 1)", "x² + 1".
fn factoredText(a: std.mem.Allocator, f: Factored, name: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const one = num.isOneNumber(f.content);
    const minus_one = f.content.isNegative() and num.isOneNumber(try num.neg(a, f.content));
    const only_one = f.factors.len == 1 and f.factors[0].mult == 1;
    if (f.factors.len == 0) return numberText(a, f.content);
    if (minus_one) {
        try out.appendSlice(a, "−");
    } else if (!one) {
        if (f.content.exact.den.bitCountAbs() == 1) {
            try out.appendSlice(a, try numberText(a, f.content));
        } else try out.print(a, "({s})", .{try std.fmt.allocPrint(a, "{s}/{s}", .{ try bigText(a, f.content.exact.num), try bigText(a, f.content.exact.den) })});
    }
    for (f.factors) |fac| {
        const poly = try fromDense(a, fac.coefs, name);
        const body = try text(a, poly);
        // A lone letter needs no brackets: x, x².
        const bare = poly.terms.len == 1 and std.mem.eql(u8, body, name);
        if (only_one and one and fac.mult == 1) return body;
        if (bare) {
            try out.appendSlice(a, body);
        } else {
            try out.print(a, "({s})", .{body});
        }
        if (fac.mult > 1) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{fac.mult}) catch "";
            for (s) |ch| try out.appendSlice(a, sup_digits[ch - '0']);
        }
    }
    return out.items;
}

// ---- the entry points -------------------------------------------------------------------------------

/// expand((x + 1)³) is x³ + 3x² + 3x + 1.
pub fn expand(ctx: Ctx, n: *const Node) Error!?[]u8 {
    const p = (try fromNode(ctx, n)) orelse return null;
    return try text(ctx.a, p);
}

/// The one letter of a polynomial, or null (none, or several).
pub fn onlyVar(p: Poly) ?[]const u8 {
    var name: ?[]const u8 = null;
    for (p.vars, 0..) |v, i| {
        var used = false;
        for (p.terms) |t| if (t.exps[i] != 0) {
            used = true;
        };
        if (!used) continue;
        if (name != null) return null;
        name = v;
    }
    return name;
}

/// factor(x² − 1) is (x − 1)(x + 1).
pub fn factor(ctx: Ctx, n: *const Node) Error!?[]u8 {
    const a = ctx.a;
    const p = (try fromNode(ctx, n)) orelse return null;
    if (p.terms.len == 0) return try a.dupe(u8, "0");
    if (onlyVar(p)) |name| {
        const c = (try dense(a, p, name)) orelse return null;
        return try factoredText(a, try factorDense(a, c), name);
    }
    if (p.vars.len == 0 or isConstant(p)) return try text(a, p);
    return try factorMonomial(a, p);
}

/// Several letters: the common whole-number factor and the common powers of the letters.
fn factorMonomial(a: std.mem.Allocator, p: Poly) Error![]u8 {
    const sorted = try sortedVars(a, p);
    var min_exps = try a.dupe(u16, sorted.terms[0].exps);
    for (sorted.terms) |t| for (t.exps, 0..) |e, i| {
        min_exps[i] = @min(min_exps[i], e);
    };
    // The common number: gcd of the numerators over lcm of the denominators, with the sign
    // of the first term in the written order.
    const coefs = try a.alloc(Number, sorted.terms.len);
    for (sorted.terms, 0..) |t, i| coefs[i] = t.c;
    const pr = try primitive(a, coefs);
    const items = try a.alloc(PTerm, sorted.terms.len);
    for (sorted.terms, 0..) |t, i| {
        const e = try a.dupe(u16, t.exps);
        for (e, 0..) |*x, j| x.* -= min_exps[j];
        items[i] = .{ .c = try num.div(a, t.c, pr.content), .exps = e };
    }
    const rest: Poly = .{ .vars = sorted.vars, .terms = items };
    var out: std.ArrayList(u8) = .empty;
    if (!num.isOneNumber(pr.content)) {
        if (pr.content.isNegative() and num.isOneNumber(try num.neg(a, pr.content))) {
            try out.appendSlice(a, "−");
        } else try out.appendSlice(a, try numberText(a, pr.content));
    }
    for (min_exps, 0..) |e, i| if (e != 0) {
        try out.appendSlice(a, sorted.vars[i]);
        try exponentText(a, &out, e);
    };
    const rest_text = try text(a, rest);
    if (rest.terms.len == 1) {
        const t = rest.terms[0];
        var plain = true;
        for (t.exps) |e| if (e != 0) {
            plain = false;
        };
        if (plain and num.isOneNumber(t.c)) {
            if (out.items.len == 0 or std.mem.eql(u8, out.items, "−")) try out.appendSlice(a, "1");
            return out.items;
        }
        try out.appendSlice(a, rest_text);
        return out.items;
    }
    try out.print(a, "({s})", .{rest_text});
    return out.items;
}

// ---- cancelling a fraction ------------------------------------------------------------------------------

fn gcdDense(a: std.mem.Allocator, x_in: []const Number, y_in: []const Number) Error!Coefs {
    var x = try a.dupe(Number, trimmed(x_in));
    var y = try a.dupe(Number, trimmed(y_in));
    while (y.len > 0) {
        const r = (try divmod(a, x, y)).r;
        x = y;
        y = try a.dupe(Number, trimmed(r));
    }
    return x;
}

/// simplify((x² − 1)/(x − 1)) is x + 1. Null when the entry is not a fraction of polynomials in
/// one letter, or nothing cancels.
pub fn cancel(ctx: Ctx, n: *const Node) Error!?[]u8 {
    const a = ctx.a;
    if (n.* != .binary or n.binary.op != .div) return null;
    const top = (try fromNode(ctx, n.binary.l)) orelse return null;
    const bottom = (try fromNode(ctx, n.binary.r)) orelse return null;
    const name = onlyVar(top) orelse onlyVar(bottom) orelse return null;
    const nc = (try dense(a, top, name)) orelse return null;
    const dc = (try dense(a, bottom, name)) orelse return null;
    if (trimmed(dc).len == 0) return error.DivisionByZero;
    const g = try gcdDense(a, nc, dc);
    const gd = trimmed(g);
    if (gd.len <= 1) return null;
    var q1 = (try divmod(a, nc, g)).q;
    var q2 = (try divmod(a, dc, g)).q;
    // Whole-number coefficients on both sides, with the ratio of what was taken out moved to one side.
    if (trimmed(q2).len > 1) {
        const p1 = try primitive(a, q1);
        const p2 = try primitive(a, q2);
        const ratio_c = try num.div(a, p1.content, p2.content);
        var top_k: Number = undefined;
        var bottom_k: Number = undefined;
        if (ratio_c.isInteger()) {
            top_k = ratio_c;
            bottom_k = try num.fromInt(a, 1);
        } else {
            const inv = try num.div(a, try num.fromInt(a, 1), ratio_c);
            if (inv.isInteger()) {
                top_k = try num.fromInt(a, 1);
                bottom_k = inv;
            } else {
                top_k = .{ .exact = .{ .num = ratio_c.exact.num, .den = try Big.initSet(a, 1) } };
                bottom_k = .{ .exact = .{ .num = ratio_c.exact.den, .den = try Big.initSet(a, 1) } };
            }
        }
        const n1 = try a.alloc(Number, p1.prim.len);
        for (p1.prim, 0..) |v, i| n1[i] = try num.mul(a, v, top_k);
        const n2 = try a.alloc(Number, p2.prim.len);
        for (p2.prim, 0..) |v, i| n2[i] = try num.mul(a, v, bottom_k);
        q1 = n1;
        q2 = n2;
    }
    const q2t = trimmed(q2);
    if (q2t.len == 1) {
        // A constant denominator: a polynomial.
        const scaled = try a.alloc(Number, q1.len);
        for (q1, 0..) |v, i| scaled[i] = try num.div(a, v, q2t[0]);
        return try text(a, try fromDense(a, scaled, name));
    }
    const t1 = try text(a, try fromDense(a, q1, name));
    const t2 = try text(a, try fromDense(a, q2, name));
    const w1 = if (trimmed(q1).len > 1 and std.mem.indexOfAny(u8, t1, "+−") != null) try std.fmt.allocPrint(a, "({s})", .{t1}) else t1;
    const w2 = if (std.mem.indexOfAny(u8, t2, "+−") != null) try std.fmt.allocPrint(a, "({s})", .{t2}) else t2;
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ w1, w2 });
}

// ---- solving ------------------------------------------------------------------------------------------------

pub const Root = struct {
    /// The exact form of the real part, and of the imaginary part (zero when the root is real).
    re: symbolic.Sym,
    im: symbolic.Sym,
};

fn quadraticRoots(a: std.mem.Allocator, c: []const Number, out: *std.ArrayList(Root)) Error!bool {
    const qa = c[2];
    const qb = c[1];
    const qc = c[0];
    const disc = try num.sub(a, try num.mul(a, qb, qb), try num.mul(a, try num.fromInt(a, 4), try num.mul(a, qa, qc)));
    const two_a = try num.mul(a, try num.fromInt(a, 2), qa);
    const head = try symbolic.rational(a, try num.div(a, try num.neg(a, qb), two_a));
    const zero = try symbolic.int(a, 0);
    if (disc.isZero()) {
        try out.append(a, .{ .re = head, .im = zero });
        return true;
    }
    const negative = disc.isNegative();
    const mag = if (negative) try num.neg(a, disc) else disc;
    const root = (try symbolic.sqrt(a, try symbolic.rational(a, mag))) orelse return false;
    const half = try symbolic.rational(a, try num.div(a, try num.fromInt(a, 1), two_a));
    const spread = try symbolic.mul(a, root, half);
    if (negative) {
        try out.append(a, .{ .re = head, .im = try symbolic.neg(a, spread) });
        try out.append(a, .{ .re = head, .im = spread });
    } else {
        try out.append(a, .{ .re = try symbolic.sub(a, head, spread), .im = zero });
        try out.append(a, .{ .re = try symbolic.add(a, head, spread), .im = zero });
    }
    return true;
}

pub const Solution = struct {
    real: []Root,
    complex: []Root,
};

/// The exact roots of a polynomial in `name`, or null when a factor of degree three or more
/// (without rational roots) is left.
pub fn solveDense(a: std.mem.Allocator, c: []const Number) Error!?Solution {
    const fac = try factorDense(a, c);
    var real: std.ArrayList(Root) = .empty;
    var complex: std.ArrayList(Root) = .empty;
    for (fac.factors) |f| {
        const d = degree(f.coefs);
        if (d == 1) {
            const r = try num.div(a, try num.neg(a, f.coefs[0]), f.coefs[1]);
            try real.append(a, .{ .re = try symbolic.rational(a, r), .im = try symbolic.int(a, 0) });
        } else if (d == 2) {
            var pair: std.ArrayList(Root) = .empty;
            if (!try quadraticRoots(a, f.coefs, &pair)) return null;
            for (pair.items) |r| {
                if (r.im.isZero()) try real.append(a, r) else try complex.append(a, r);
            }
        } else return null;
    }
    // Ascending by value.
    const Ctx2 = struct { a: std.mem.Allocator };
    std.mem.sort(Root, real.items, Ctx2{ .a = a }, struct {
        fn lt(c2: Ctx2, x: Root, y: Root) bool {
            const xv = symbolic.toNumber(c2.a, x.re) catch return false;
            const yv = symbolic.toNumber(c2.a, y.re) catch return false;
            return xv.toFloat() < yv.toFloat();
        }
    }.lt);
    return .{ .real = real.items, .complex = complex.items };
}

/// Exact roots of l = r for the letter `name`, when both sides are polynomials in it.
pub fn solveEquation(ctx: Ctx, l: *const Node, r: *const Node, name: []const u8) Error!?Solution {
    const a = ctx.a;
    const pl = (try fromNode(ctx, l)) orelse return null;
    const pr = (try fromNode(ctx, r)) orelse return null;
    const diff = try sub(a, pl, pr);
    if (diff.terms.len == 0) return null;
    const c = (try dense(a, diff, name)) orelse return null;
    if (degree(c) == 0) return null;
    return try solveDense(a, c);
}

/// "−1/2 + (√3/2)i": a root with an imaginary part.
pub fn rootText(a: std.mem.Allocator, r: Root) Error![]u8 {
    if (r.im.isZero()) return symbolic.format(a, r.re);
    const imag = try symbolic.format(a, r.im);
    const im_neg = r.im.terms[0].c.isNegative() and r.im.terms.len == 1;
    const im_abs = if (im_neg) try symbolic.format(a, try symbolic.neg(a, r.im)) else imag;
    const wrapped = if (r.im.terms.len == 1 and std.mem.indexOfScalar(u8, im_abs, '/') != null and std.mem.indexOfScalar(u8, im_abs, '(') == null)
        try std.fmt.allocPrint(a, "({s})", .{im_abs})
    else if (r.im.terms.len > 1) try std.fmt.allocPrint(a, "({s})", .{im_abs}) else im_abs;
    const unit_only = std.mem.eql(u8, im_abs, "1");
    const im_part = if (unit_only) "i" else try std.fmt.allocPrint(a, "{s}i", .{wrapped});
    if (r.re.isZero()) return std.fmt.allocPrint(a, "{s}{s}", .{ if (im_neg) "−" else "", im_part });
    const re_text = try symbolic.format(a, r.re);
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ re_text, if (im_neg) "−" else "+", im_part });
}

// ---- tests ---------------------------------------------------------------------------------------------

fn run(want: []const u8, which: enum { expand, factor, cancel }, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const n = try eval.parseExpr(a, source, .{}, &p);
    const ctx: Ctx = .{ .a = a, .session = &session };
    const got = (switch (which) {
        .expand => try expand(ctx, n),
        .factor => try factor(ctx, n),
        .cancel => try cancel(ctx, n),
    }) orelse {
        std.debug.print("no answer for {s}\n", .{source});
        return error.TestUnexpectedResult;
    };
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{source});
        return e;
    };
}

test "expand" {
    try run("x³ + 3x² + 3x + 1", .expand, "(x+1)^3");
    try run("x² + 2xy + y²", .expand, "(x+y)^2");
    try run("x² − 1", .expand, "(x-1)(x+1)");
    try run("6x² + 7x − 3", .expand, "(2x+3)(3x-1)");
    try run("x/2 + 1/3", .expand, "(3x+2)/6");
    try run("−x + 2", .expand, "2-x");
    try run("0", .expand, "x-x");
}

test "factor" {
    try run("(x − 1)(x + 1)", .factor, "x^2-1");
    try run("(x + 1)(x − 3)²", .factor, "x^3-5x^2+3x+9");
    try run("2(x + 2)(x − 3)", .factor, "2x^2-2x-12");
    try run("x² + 1", .factor, "x^2+1");
    try run("x(x + 2)", .factor, "x^2+2x");
    try run("(3x + 1)(2x − 3)", .factor, "6x^2-7x-3");
    try run("(x² − 2)(x² − 3)", .factor, "x^4-5x^2+6");
    try run("−(x − 1)(x + 2)", .factor, "-x^2-x+2");
    try run("2x(x + 1)", .factor, "2x^2+2x");
    try run("xy(x + y)", .factor, "x^2*y+x*y^2");
    try run("(x − 2)³", .factor, "x^3-6x^2+12x-8");
}

test "cancel" {
    try run("x + 1", .cancel, "(x^2-1)/(x-1)");
    try run("(x + 3)/(x − 3)", .cancel, "(x^2+5x+6)/(x^2-x-6)");
}

fn solved(want: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const st = try eval.parse(a, source, .{}, &p);
    const sol = (try solveEquation(.{ .a = a, .session = &session }, st.equation.l, st.equation.r, "x")) orelse return error.TestUnexpectedResult;
    var out: std.ArrayList(u8) = .empty;
    for (sol.real) |r| try out.print(a, "{s}{s}", .{ if (out.items.len > 0) "; " else "", try rootText(a, r) });
    for (sol.complex) |r| try out.print(a, "{s}{s}", .{ if (out.items.len > 0) "; " else "", try rootText(a, r) });
    try std.testing.expectEqualStrings(want, out.items);
}

test "solve exactly" {
    try solved("4", "2x+3=11");
    try solved("−2; 2", "x^2=4");
    try solved("−√2; √2", "x^2=2");
    try solved("(1 − √5)/2; (1 + √5)/2", "x^2-x-1=0");
    try solved("−1/2 − (√3/2)i; −1/2 + (√3/2)i", "x^2+x+1=0");
    try solved("−i; i", "x^2+1=0");
    try solved("−1; 1; 2", "(x-1)(x+1)(x-2)=0");
    try solved("−2/3; 3/2", "6x^2-5x-6=0");
}
