//! Laplace transforms of the functions a course starts with, and back again.
//!
//!   laplace(f, t)     sums of  c · tⁿ · e^(at) · (1, sin bt, cos bt, sinh bt or cosh bt)
//!   ilaplace(F, s)    rational functions whose denominator factors into (s − a)^k and quadratics
//!
//! A transform is a rational function of s, kept as two lists of coefficients (lowest power first).
//! tⁿ·e^(at)·g(t) becomes (−1)ⁿ dⁿ/dsⁿ of G(s − a); the way back is partial fractions.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const algebra = @import("algebra.zig");
const Number = num.Number;
const Node = eval.Node;

pub const Error = eval.Error;

// ---- polynomials in s -------------------------------------------------------------------------

const Poly = []Number;

fn zero(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 0);
}

fn one(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 1);
}

fn pconst(a: std.mem.Allocator, c: Number) Error!Poly {
    const p = try a.alloc(Number, 1);
    p[0] = c;
    return p;
}

fn pint(a: std.mem.Allocator, v: i64) Error!Poly {
    return pconst(a, try num.fromInt(a, v));
}

fn padd(a: std.mem.Allocator, x: []const Number, y: []const Number) Error!Poly {
    const n = @max(x.len, y.len);
    const out = try a.alloc(Number, n);
    for (0..n) |i| {
        const u = if (i < x.len) x[i] else try zero(a);
        const v = if (i < y.len) y[i] else try zero(a);
        out[i] = try num.add(a, u, v);
    }
    return out;
}

fn pscale(a: std.mem.Allocator, x: []const Number, k: Number) Error!Poly {
    const out = try a.alloc(Number, x.len);
    for (x, 0..) |c, i| out[i] = try num.mul(a, c, k);
    return out;
}

fn pmul(a: std.mem.Allocator, x: []const Number, y: []const Number) Error!Poly {
    if (x.len == 0 or y.len == 0) return try a.alloc(Number, 0);
    return algebra.mulDense(a, x, y);
}

fn pderiv(a: std.mem.Allocator, x: []const Number) Error!Poly {
    if (x.len <= 1) return pint(a, 0);
    const out = try a.alloc(Number, x.len - 1);
    for (1..x.len) |i| out[i - 1] = try num.mul(a, x[i], try num.fromInt(a, @as(i64, @intCast(i))));
    return out;
}

/// p(s − shift).
fn pshift(a: std.mem.Allocator, p: []const Number, shift: Number) Error!Poly {
    var acc = try pint(a, 0);
    const lin = try a.alloc(Number, 2);
    lin[0] = try num.neg(a, shift);
    lin[1] = try one(a);
    var i = p.len;
    while (i > 0) {
        i -= 1;
        acc = try padd(a, try pmul(a, acc, lin), try pconst(a, p[i]));
    }
    return acc;
}

const Rat = struct { n: Poly, d: Poly };

fn ratOf(a: std.mem.Allocator, n: []const Number, d: []const Number) Rat {
    _ = a;
    return .{ .n = @constCast(n), .d = @constCast(d) };
}

fn radd(a: std.mem.Allocator, x: Rat, y: Rat) Error!Rat {
    return .{ .n = try padd(a, try pmul(a, x.n, y.d), try pmul(a, y.n, x.d)), .d = try pmul(a, x.d, y.d) };
}

fn rmul(a: std.mem.Allocator, x: Rat, y: Rat) Error!Rat {
    return .{ .n = try pmul(a, x.n, y.n), .d = try pmul(a, x.d, y.d) };
}

fn rdiv(a: std.mem.Allocator, x: Rat, y: Rat) Error!Rat {
    if (algebra.trimmed(y.n).len == 0) return error.DivisionByZero;
    return .{ .n = try pmul(a, x.n, y.d), .d = try pmul(a, x.d, y.n) };
}

fn rscale(a: std.mem.Allocator, x: Rat, k: Number) Error!Rat {
    return .{ .n = try pscale(a, x.n, k), .d = x.d };
}

fn rderiv(a: std.mem.Allocator, x: Rat) Error!Rat {
    const top = try padd(a, try pmul(a, try pderiv(a, x.n), x.d), try pscale(a, try pmul(a, x.n, try pderiv(a, x.d)), try num.fromInt(a, -1)));
    return .{ .n = top, .d = try pmul(a, x.d, x.d) };
}

fn rshift(a: std.mem.Allocator, x: Rat, shift: Number) Error!Rat {
    return .{ .n = try pshift(a, x.n, shift), .d = try pshift(a, x.d, shift) };
}

/// Common factors out, and the denominator's leading coefficient made 1.
fn rreduce(a: std.mem.Allocator, x: Rat) Error!Rat {
    const n = algebra.trimmed(x.n);
    const d = algebra.trimmed(x.d);
    if (d.len == 0) return error.DivisionByZero;
    if (n.len == 0) return .{ .n = try pint(a, 0), .d = try pint(a, 1) };
    const g = algebra.trimmed(try algebra.gcdDense(a, n, d));
    var nn: Poly = try a.dupe(Number, n);
    var dd: Poly = try a.dupe(Number, d);
    if (g.len > 1) {
        nn = try a.dupe(Number, algebra.trimmed((try algebra.divmod(a, n, g)).q));
        dd = try a.dupe(Number, algebra.trimmed((try algebra.divmod(a, d, g)).q));
    }
    const lead = dd[dd.len - 1];
    const inv = try num.div(a, try one(a), lead);
    return .{ .n = try pscale(a, nn, inv), .d = try pscale(a, dd, inv) };
}

// ---- text --------------------------------------------------------------------------------------

fn polyText(a: std.mem.Allocator, p: []const Number) Error![]const u8 {
    return algebra.text(a, try algebra.fromDense(a, p, "s"));
}

fn terms(p: []const Number) usize {
    var k: usize = 0;
    for (p) |c| if (!c.isZero()) {
        k += 1;
    };
    return k;
}

fn wrapped(a: std.mem.Allocator, p: []const Number) Error![]const u8 {
    const t = try polyText(a, p);
    if (terms(p) > 1) return std.fmt.allocPrint(a, "({s})", .{t});
    return t;
}

/// The denominator as a product of its factors: (s − 1)²(s + 2).
fn denominatorText(a: std.mem.Allocator, d: []const Number) Error![]const u8 {
    if (d.len <= 1) return numText(a, if (d.len == 1) d[0] else try one(a));
    const fac = try algebra.factorDense(a, d);
    var out: std.ArrayList(u8) = .empty;
    if (!num.isOneNumber(fac.content)) {
        try out.appendSlice(a, try numText(a, fac.content));
    }
    for (fac.factors) |f| {
        const t = try wrapped(a, f.coefs);
        try out.appendSlice(a, if (terms(f.coefs) > 1) t else t);
        if (f.mult > 1) try out.appendSlice(a, try superscript(a, f.mult));
    }
    return out.items;
}

fn superscript(a: std.mem.Allocator, n: u32) Error![]const u8 {
    const digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };
    var buf: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    var out: std.ArrayList(u8) = .empty;
    for (s) |d| try out.appendSlice(a, digits[d - '0']);
    return out.items;
}

fn ratText(a: std.mem.Allocator, r_in: Rat) Error![]const u8 {
    const r = try rreduce(a, r_in);
    if (algebra.trimmed(r.n).len == 0) return "0";
    const top = try polyText(a, r.n);
    if (r.d.len == 1 and num.isOneNumber(r.d[0])) return top;
    const bottom = try denominatorText(a, r.d);
    const top_w = if (terms(r.n) > 1 or std.mem.indexOfScalar(u8, top, '/') != null) try std.fmt.allocPrint(a, "({s})", .{top}) else top;
    // A single whole-number denominator reads as a coefficient: 1/2 rather than 1/(2).
    const bottom_w = if (std.mem.indexOf(u8, bottom, ")(") != null or (std.mem.indexOfAny(u8, bottom, " ") != null and bottom[0] != '(')) try std.fmt.allocPrint(a, "({s})", .{bottom}) else bottom;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ top_w, bottom_w });
}

fn numText(a: std.mem.Allocator, v: Number) Error![]const u8 {
    const raw = if (v.isInteger()) try num.format(a, v, .{ .decimals = 0 }) else (try num.fraction(a, v)) orelse try num.format(a, v, .{ .decimals = 12 });
    if (raw.len > 0 and raw[0] == '-') return std.fmt.allocPrint(a, "−{s}", .{raw[1..]});
    return raw;
}

// ---- forward transform ----------------------------------------------------------------------------

/// The exact rational value of an expression without t, or null.
fn constantOf(ev: *eval.Eval, n: *const Node, t: []const u8) Error!?Number {
    if (usesName(n, t)) return null;
    const v = ev.eval(n, null) catch return null;
    if (!v.isExact()) return null;
    return v;
}

fn usesName(n: *const Node, name: []const u8) bool {
    return switch (n.*) {
        .number => false,
        .name => |nm| std.mem.eql(u8, nm.text, name),
        .unary => |u| usesName(u.arg, name),
        .binary => |b| usesName(b.l, name) or usesName(b.r, name),
        .call => |c| for (c.args) |arg| {
            if (usesName(arg, name)) break true;
        } else false,
    };
}

/// k when the node is k·t.
fn slope(ev: *eval.Eval, n: *const Node, t: []const u8) Error!?Number {
    const ctx: algebra.Ctx = .{ .a = ev.a, .session = ev.session };
    const poly = (try algebra.fromNode(ctx, n)) orelse return null;
    const c = (try algebra.dense(ev.a, poly, t)) orelse return null;
    if (c.len != 2 or !c[0].isZero()) return null;
    return c[1];
}

const Kind = enum { plain, sin, cos, sinh, cosh };

const Part = struct {
    coef: Number,
    n: u32 = 0,
    a: Number,
    kind: Kind = .plain,
    b: Number,
};

fn flatten(a: std.mem.Allocator, n: *const Node, list: *std.ArrayList(*const Node), divisors: *std.ArrayList(*const Node)) Error!void {
    if (n.* == .binary and n.binary.op == .mul) {
        try flatten(a, n.binary.l, list, divisors);
        try flatten(a, n.binary.r, list, divisors);
    } else if (n.* == .binary and n.binary.op == .div) {
        try flatten(a, n.binary.l, list, divisors);
        try divisors.append(a, n.binary.r);
    } else try list.append(a, n);
}

fn isName(n: *const Node, text: []const u8) bool {
    return n.* == .name and std.mem.eql(u8, n.name.text, text);
}

/// c·tⁿ·e^(at)·g(bt) as parts, or null when the product is anything else.
fn part(ev: *eval.Eval, n: *const Node, t: []const u8) Error!?Part {
    const a = ev.a;
    var factors: std.ArrayList(*const Node) = .empty;
    var divisors: std.ArrayList(*const Node) = .empty;
    try flatten(a, n, &factors, &divisors);
    var p: Part = .{ .coef = try one(a), .a = try zero(a), .b = try zero(a) };
    var have_kind = false;
    var have_exp = false;
    for (divisors.items) |d| {
        const c = (try constantOf(ev, d, t)) orelse return null;
        if (c.isZero()) return null;
        p.coef = try num.div(a, p.coef, c);
    }
    for (factors.items) |f| {
        if (try constantOf(ev, f, t)) |c| {
            p.coef = try num.mul(a, p.coef, c);
            continue;
        }
        if (f.* == .unary and f.unary.op == .neg) {
            p.coef = try num.neg(a, p.coef);
            const inner = (try part(ev, f.unary.arg, t)) orelse return null;
            // Fold the inner part in (it is one factor): only plain factors are expected here.
            if (inner.n != 0 or inner.kind != .plain or !inner.a.isZero()) return null;
            p.coef = try num.mul(a, p.coef, inner.coef);
            continue;
        }
        if (isName(f, t)) {
            p.n += 1;
            continue;
        }
        if (f.* == .binary and f.binary.op == .pow) {
            const bs = f.binary.l;
            const ex = f.binary.r;
            if (isName(bs, t)) {
                const k = (try constantOf(ev, ex, t)) orelse return null;
                const kv = num.intValue(k) orelse return null;
                if (kv < 0 or kv > 12) return null;
                p.n += @intCast(kv);
                continue;
            }
            if (isName(bs, "e") and !have_exp) {
                p.a = (try slope(ev, ex, t)) orelse return null;
                have_exp = true;
                continue;
            }
            return null;
        }
        if (f.* == .call and f.call.args.len == 1) {
            const name = f.call.name;
            const arg = f.call.args[0];
            const eql = std.ascii.eqlIgnoreCase;
            if (eql(name, "exp") and !have_exp) {
                p.a = (try slope(ev, arg, t)) orelse return null;
                have_exp = true;
                continue;
            }
            const kind: ?Kind = if (eql(name, "sin")) .sin else if (eql(name, "cos")) .cos else if (eql(name, "sinh")) .sinh else if (eql(name, "cosh")) .cosh else null;
            if (kind != null and !have_kind) {
                p.b = (try slope(ev, arg, t)) orelse return null;
                p.kind = kind.?;
                have_kind = true;
                continue;
            }
        }
        return null;
    }
    return p;
}

/// G(s) for the function g: 1, sin, cos, sinh, cosh of b·t.
fn base(a: std.mem.Allocator, kind: Kind, b: Number) Error!Rat {
    const s2 = try a.alloc(Number, 3);
    const b2 = try num.mul(a, b, b);
    s2[0] = if (kind == .sinh or kind == .cosh) try num.neg(a, b2) else b2;
    s2[1] = try zero(a);
    s2[2] = try one(a);
    return switch (kind) {
        .plain => .{ .n = try pint(a, 1), .d = try a.dupe(Number, &.{ try zero(a), try one(a) }) },
        .sin, .sinh => .{ .n = try pconst(a, b), .d = s2 },
        .cos, .cosh => .{ .n = try a.dupe(Number, &.{ try zero(a), try one(a) }), .d = s2 },
    };
}

fn transform(ev: *eval.Eval, n: *const Node, t: []const u8) Error!?Rat {
    const a = ev.a;
    switch (n.*) {
        .binary => |bn| switch (bn.op) {
            .add, .sub => {
                const l = (try transform(ev, bn.l, t)) orelse return null;
                var r = (try transform(ev, bn.r, t)) orelse return null;
                if (bn.op == .sub) r = try rscale(a, r, try num.fromInt(a, -1));
                return try radd(a, l, r);
            },
            else => {},
        },
        .unary => |u| if (u.op == .neg) {
            const x = (try transform(ev, u.arg, t)) orelse return null;
            return try rscale(a, x, try num.fromInt(a, -1));
        },
        else => {},
    }
    const p = (try part(ev, n, t)) orelse return null;
    if (p.kind != .plain and p.b.isZero()) return null;
    var g = try base(a, p.kind, p.b);
    if (!p.a.isZero()) g = try rshift(a, g, p.a);
    var k: u32 = 0;
    while (k < p.n) : (k += 1) g = try rscale(a, try rderiv(a, g), try num.fromInt(a, -1));
    return try rscale(a, g, p.coef);
}

pub fn laplaceText(ev: *eval.Eval, f: *const Node, t: []const u8) Error!?[]const u8 {
    const r = (try transform(ev, f, t)) orelse return null;
    return try ratText(ev.a, r);
}

pub const Term = struct { negative: bool, node: *const Node };

pub fn collect(a: std.mem.Allocator, n: *const Node, negative: bool, out: *std.ArrayList(Term)) Error!void {
    switch (n.*) {
        .binary => |b| if (b.op == .add or b.op == .sub) {
            try collect(a, b.l, negative, out);
            try collect(a, b.r, if (b.op == .sub) !negative else negative, out);
            return;
        },
        .unary => |u| if (u.op == .neg) return collect(a, u.arg, !negative, out),
        else => {},
    }
    try out.append(a, .{ .negative = negative, .node = n });
}

pub const Rule = struct { rule: []const u8, result: []const u8 };

/// Which table entry and rules a single term uses, and its transform.
pub fn termRule(ev: *eval.Eval, n: *const Node, t: []const u8) Error!?Rule {
    const a = ev.a;
    const p = (try part(ev, n, t)) orelse return null;
    const r = (try transform(ev, n, t)) orelse return null;
    var rule: std.ArrayList(u8) = .empty;
    const table: []const u8 = switch (p.kind) {
        .plain => "Table: L{1} = 1/s",
        .sin => "Table: L{sin bt} = b/(s² + b²)",
        .cos => "Table: L{cos bt} = s/(s² + b²)",
        .sinh => "Table: L{sinh bt} = b/(s² − b²)",
        .cosh => "Table: L{cosh bt} = s/(s² − b²)",
    };
    try rule.appendSlice(a, table);
    if (!p.a.isZero()) try rule.appendSlice(a, "; e^(at) shifts s to s − a");
    if (p.n > 0) try rule.appendSlice(a, "; tⁿ multiplies by (−1)ⁿ and differentiates n times in s");
    return .{ .rule = rule.items, .result = try ratText(a, r) };
}

// ---- the way back -------------------------------------------------------------------------------------

/// A rational function of s from an expression: numbers, s, + − × ÷ and whole powers.
fn rationalOf(ev: *eval.Eval, n: *const Node, s: []const u8) Error!?Rat {
    const a = ev.a;
    if (!usesName(n, s)) {
        const v = ev.eval(n, null) catch return null;
        if (!v.isExact()) return null;
        return .{ .n = try pconst(a, v), .d = try pint(a, 1) };
    }
    switch (n.*) {
        .name => return .{ .n = try a.dupe(Number, &.{ try zero(a), try one(a) }), .d = try pint(a, 1) },
        .unary => |u| {
            if (u.op != .neg) return null;
            const x = (try rationalOf(ev, u.arg, s)) orelse return null;
            return try rscale(a, x, try num.fromInt(a, -1));
        },
        .binary => |b| {
            if (b.op == .pow) {
                const x = (try rationalOf(ev, b.l, s)) orelse return null;
                const e = num.intValue(ev.eval(b.r, null) catch return null) orelse return null;
                if (e == 0 or @abs(e) > 12) return null;
                var acc: Rat = .{ .n = try pint(a, 1), .d = try pint(a, 1) };
                var i: i64 = 0;
                while (i < @abs(e)) : (i += 1) acc = try rmul(a, acc, x);
                if (e < 0) acc = .{ .n = acc.d, .d = acc.n };
                return acc;
            }
            const l = (try rationalOf(ev, b.l, s)) orelse return null;
            const r = (try rationalOf(ev, b.r, s)) orelse return null;
            return switch (b.op) {
                .add => try radd(a, l, r),
                .sub => try radd(a, l, try rscale(a, r, try num.fromInt(a, -1))),
                .mul => try rmul(a, l, r),
                .div => try rdiv(a, l, r),
                else => null,
            };
        },
        else => return null,
    }
}

/// Solves M·x = rhs exactly (M square), or null when it is singular.
fn gauss(a: std.mem.Allocator, m: [][]Number, rhs: []Number) Error!?[]Number {
    const n = rhs.len;
    for (0..n) |c| {
        var piv: ?usize = null;
        for (c..n) |r| if (!m[r][c].isZero()) {
            piv = r;
            break;
        };
        const pr = piv orelse return null;
        std.mem.swap([]Number, &m[c], &m[pr]);
        std.mem.swap(Number, &rhs[c], &rhs[pr]);
        for (0..n) |r| {
            if (r == c or m[r][c].isZero()) continue;
            const f = try num.div(a, m[r][c], m[c][c]);
            for (c..n) |k| m[r][k] = try num.sub(a, m[r][k], try num.mul(a, f, m[c][k]));
            rhs[r] = try num.sub(a, rhs[r], try num.mul(a, f, rhs[c]));
        }
    }
    const x = try a.alloc(Number, n);
    for (0..n) |i| x[i] = try num.div(a, rhs[i], m[i][i]);
    return x;
}

fn expText(a: std.mem.Allocator, k: Number) Error![]const u8 {
    if (k.isZero()) return "";
    const t = try numText(a, k);
    if (std.mem.eql(u8, t, "1")) return "e^t";
    if (std.mem.eql(u8, t, "−1")) return "e^(−t)";
    if (std.mem.indexOfScalar(u8, t, '/')) |sl| {
        const neg = std.mem.startsWith(u8, t, "−");
        const top = if (neg) t[3..sl] else t[0..sl];
        return std.fmt.allocPrint(a, "e^({s}{s}t/{s})", .{ if (neg) "−" else "", if (std.mem.eql(u8, top, "1")) "" else top, t[sl + 1 ..] });
    }
    return std.fmt.allocPrint(a, "e^({s}t)", .{t});
}

fn joinFactors(a: std.mem.Allocator, pieces: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pieces) |p| {
        if (p.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(a, "·");
        try out.appendSlice(a, p);
    }
    if (out.items.len == 0) return "1";
    return out.items;
}

/// c·f as text: 1 is dropped, −1 becomes a minus sign, a fraction p/q goes after: p·f/q. 0 gives null.
fn termText(a: std.mem.Allocator, c: Number, f: []const u8) Error!?[]const u8 {
    if (c.isZero()) return null;
    if (std.mem.eql(u8, f, "1")) return try numText(a, c);
    const t = try numText(a, c);
    const neg = std.mem.startsWith(u8, t, "−");
    const body = if (neg) t[3..] else t;
    const sign: []const u8 = if (neg) "−" else "";
    if (std.mem.indexOfScalar(u8, body, '/')) |sl| {
        const top = body[0..sl];
        const shown = if (std.mem.eql(u8, top, "1")) f else try std.fmt.allocPrint(a, "{s}·{s}", .{ top, f });
        return try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ sign, shown, body[sl + 1 ..] });
    }
    if (std.mem.eql(u8, body, "1")) return try std.fmt.allocPrint(a, "{s}{s}", .{ sign, f });
    return try std.fmt.allocPrint(a, "{s}{s}·{s}", .{ sign, body, f });
}

fn tPower(a: std.mem.Allocator, k: usize) Error![]const u8 {
    if (k == 0) return "";
    if (k == 1) return "t";
    return std.fmt.allocPrint(a, "t{s}", .{try superscript(a, @intCast(k))});
}

/// √ of a positive rational as text, and its exact value when it has one.
fn sqrtText(a: std.mem.Allocator, v: Number) Error!struct { text: []const u8, exact: ?Number } {
    if (try num.root(a, v, 2)) |r| return .{ .text = try numText(a, r), .exact = r };
    return .{ .text = try std.fmt.allocPrint(a, "√{s}", .{if (v.isInteger()) try numText(a, v) else try std.fmt.allocPrint(a, "({s})", .{try numText(a, v)})}), .exact = null };
}

pub fn inverseText(ev: *eval.Eval, f: *const Node, s: []const u8) Error!?[]const u8 {
    return inverseImpl(ev, f, s, null, null);
}

/// The steps of ilaplace: the denominator factored, the partial fractions, then each term back.
pub fn inverseSteps(ev: *eval.Eval, f: *const Node, s: []const u8) Error!?[]Line {
    const a = ev.a;
    var den: []const u8 = "";
    var decomp: []const u8 = "";
    const result = (try inverseImpl(ev, f, s, &den, &decomp)) orelse return null;
    var out: std.ArrayList(Line) = .empty;
    try out.append(a, .{ .note = "Factor the denominator", .math = den });
    try out.append(a, .{ .note = "Split into partial fractions (match numerators)", .math = decomp });
    try out.append(a, .{ .note = "Invert each term from the table: 1/(s − a)ⁿ → tⁿ⁻¹eᵃᵗ/(n−1)!, and the quadratics by completing the square", .math = result });
    return out.items;
}

pub const Line = struct { note: []const u8, math: []const u8 };

fn inverseImpl(ev: *eval.Eval, f: *const Node, s: []const u8, den_out: ?*[]const u8, decomp_out: ?*[]const u8) Error!?[]const u8 {
    const a = ev.a;
    const r0 = (try rationalOf(ev, f, s)) orelse return null;
    const r = try rreduce(a, r0);
    const nn = algebra.trimmed(r.n);
    const dd = algebra.trimmed(r.d);
    if (nn.len == 0) return "0";
    if (nn.len >= dd.len) return null; // a polynomial part would be impulses
    const fac = try algebra.factorDense(a, dd);
    // Unknown numerators: each factor power f^k gets a polynomial of degree < deg f.
    const Slot = struct { f: algebra.Factor, k: u32, start: usize };
    var slots: std.ArrayList(Slot) = .empty;
    var unknowns: usize = 0;
    for (fac.factors) |f_| {
        const deg = algebra.degree(f_.coefs);
        if (deg > 2 or (deg == 2 and f_.mult > 1)) return null;
        var k: u32 = 1;
        while (k <= f_.mult) : (k += 1) {
            try slots.append(a, .{ .f = f_, .k = k, .start = unknowns });
            unknowns += deg;
        }
    }
    if (unknowns != dd.len - 1) return null;
    // Columns: basis numerator × (D / f^k).
    const m = try a.alloc([]Number, unknowns);
    for (m) |*row| {
        row.* = try a.alloc(Number, unknowns);
        for (row.*) |*c| c.* = try zero(a);
    }
    const rhs = try a.alloc(Number, unknowns);
    for (0..unknowns) |i| rhs[i] = if (i < nn.len) try num.div(a, nn[i], fac.content) else try zero(a);
    // D without its content: the product of the factors.
    for (slots.items) |sl| {
        var cof = try pint(a, 1);
        for (fac.factors) |g| {
            const times: u32 = if (g.coefs.ptr == sl.f.coefs.ptr) g.mult - sl.k else g.mult;
            var j: u32 = 0;
            while (j < times) : (j += 1) cof = try pmul(a, cof, g.coefs);
        }
        const deg = algebra.degree(sl.f.coefs);
        for (0..deg) |bi| {
            const col = try a.alloc(Number, bi + 1);
            for (col) |*c| c.* = try zero(a);
            col[bi] = try one(a);
            const prod = try pmul(a, col, cof);
            for (prod, 0..) |c, row| if (row < unknowns) {
                m[row][sl.start + bi] = c;
            };
        }
    }
    const sol = (try gauss(a, m, rhs)) orelse return null;
    if (den_out) |o| o.* = try denominatorText(a, dd);
    if (decomp_out) |o| {
        var dt: std.ArrayList(u8) = .empty;
        if (!num.isOneNumber(fac.content)) try dt.print(a, "(1/{s})·(", .{try numText(a, fac.content)});
        var first = true;
        for (slots.items) |sl| {
            const deg = algebra.degree(sl.f.coefs);
            var den_poly = try pint(a, 1);
            var j: u32 = 0;
            while (j < sl.k) : (j += 1) den_poly = try pmul(a, den_poly, sl.f.coefs);
            const piece = try ratText(a, .{ .n = sol[sl.start .. sl.start + deg], .d = den_poly });
            if (!first) try dt.appendSlice(a, " + ");
            first = false;
            try dt.appendSlice(a, piece);
        }
        if (!num.isOneNumber(fac.content)) try dt.appendSlice(a, ")");
        o.* = dt.items;
    }
    var list: std.ArrayList(?[]const u8) = .empty;
    for (slots.items) |sl| {
        const deg = algebra.degree(sl.f.coefs);
        const lead = sl.f.coefs[deg];
        if (deg == 1) {
            // c/(l(s − a))^k with the factor l s + c0 = l(s − root).
            const root = try num.div(a, try num.neg(a, sl.f.coefs[0]), lead);
            var coef = sol[sl.start];
            var j: u32 = 0;
            while (j < sl.k) : (j += 1) coef = try num.div(a, coef, lead);
            const fact = try num.factorial(a, try num.fromInt(a, @as(i64, sl.k - 1)));
            coef = try num.div(a, coef, fact);
            const fn_text = try joinFactors(a, &.{ try tPower(a, sl.k - 1), try expText(a, root) });
            try list.append(a, try termText(a, coef, fn_text));
        } else {
            // (αs + β)/(l(s² + p s + q)), completing the square.
            const alpha = try num.div(a, sol[sl.start + 1], lead);
            const beta = try num.div(a, sol[sl.start], lead);
            const p = try num.div(a, sl.f.coefs[1], lead);
            const q = try num.div(a, sl.f.coefs[0], lead);
            const h = try num.div(a, p, try num.fromInt(a, 2));
            const w2 = try num.sub(a, q, try num.mul(a, h, h));
            const hyper = w2.isNegative();
            const wv = if (hyper) try num.neg(a, w2) else w2;
            const root = try sqrtText(a, wv);
            const rest = try num.sub(a, beta, try num.mul(a, alpha, h));
            const ex = try expText(a, try num.neg(a, h));
            const wtp = if (std.mem.eql(u8, root.text, "1")) "t" else if (root.exact != null) try std.fmt.allocPrint(a, "{s}t", .{root.text}) else try std.fmt.allocPrint(a, "{s}·t", .{root.text});
            const cos_f = try std.fmt.allocPrint(a, "{s}({s})", .{ if (hyper) "cosh" else "cos", wtp });
            const sin_f = try std.fmt.allocPrint(a, "{s}({s})", .{ if (hyper) "sinh" else "sin", wtp });
            // (rest/w)·sin: a division by an inexact root stays in the text.
            const sin_coef_text: []const u8 = blk: {
                if (rest.isZero()) break :blk "";
                if (root.exact) |ex_w| {
                    const c = try num.div(a, rest, ex_w);
                    break :blk (try termText(a, c, sin_f)) orelse "";
                }
                const rt = try numText(a, rest);
                break :blk try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ if (std.mem.eql(u8, rt, "1")) "" else rt, sin_f, root.text });
            };
            const cos_term = try termText(a, alpha, cos_f);
            const inner = try joinTerms(a, &.{ cos_term, if (sin_coef_text.len == 0) null else sin_coef_text });
            const both = cos_term != null and sin_coef_text.len > 0;
            const wrapped_inner = if (both) try std.fmt.allocPrint(a, "({s})", .{inner}) else inner;
            try list.append(a, if (ex.len == 0) (if (std.mem.eql(u8, inner, "0")) null else inner) else if (std.mem.eql(u8, inner, "0")) null else try std.fmt.allocPrint(a, "{s}·{s}", .{ ex, wrapped_inner }));
        }
    }
    return try joinTerms(a, list.items);
}

fn joinTerms(a: std.mem.Allocator, list: []const ?[]const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |maybe| {
        const t = maybe orelse continue;
        if (out.items.len == 0) {
            try out.appendSlice(a, t);
        } else if (std.mem.startsWith(u8, t, "−")) {
            try out.print(a, " − {s}", .{t[3..]});
        } else try out.print(a, " + {s}", .{t});
    }
    if (out.items.len == 0) return "0";
    return out.items;
}

// ---- tests --------------------------------------------------------------------------------------------

fn run(want: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var problem: eval.Problem = .{};
    const o = try eval.run(a, &session, source, .{ .angle = .radians }, &problem);
    const got = switch (o) {
        .simplified => |s| s,
        else => "?",
    };
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{source});
        return e;
    };
}

test "laplace transforms" {
    try run("1/s", "laplace(1, t)");
    try run("1/s²", "laplace(t, t)");
    try run("2/s³", "laplace(t^2, t)");
    try run("1/(s − 2)", "laplace(exp(2t), t)");
    try run("3/(s² + 9)", "laplace(sin(3t), t)");
    try run("s/(s² + 4)", "laplace(cos(2t), t)");
    try run("1/(s − 1)²", "laplace(t*exp(t), t)");
    try run("2/(s² + 2s + 5)", "laplace(exp(-t)*sin(2t), t)");
}

test "inverse laplace transforms" {
    try run("1", "ilaplace(1/s, s)");
    try run("t", "ilaplace(1/s^2, s)");
    try run("e^(2t)", "ilaplace(1/(s-2), s)");
    try run("sin(3t)", "ilaplace(3/(s^2+9), s)");
    try run("cos(2t)", "ilaplace(s/(s^2+4), s)");
    try run("e^t − e^(−t)", "ilaplace(2/(s^2-1), s)");
    try run("t·e^(−2t)", "ilaplace(1/(s+2)^2, s)");
    try run("e^t/3 + t·e^t − e^(−2t)/3", "ilaplace((2s+1)/((s-1)^2*(s+2)), s)");
    try run("e^(−t)·(cos(2t) + sin(2t))", "ilaplace((s+3)/(s^2+2s+5), s)");
}
