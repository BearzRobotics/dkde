//! Indefinite integrals in closed form, by rules: powers, sums and constant multiples; exp, sin, cos,
//! tan, ln, sqrt and the inverse trigonometric functions of a linear argument; integration by parts for
//! a polynomial times one of those; and rational functions with distinct rational roots below
//! (partial fractions), 1/(x² + c) and x/(x² + c).
//!
//! Every answer is checked before it is given: its derivative is compared with the original at a few
//! points, and an antiderivative that does not differentiate back is dropped.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const calculus = @import("calculus.zig");
const algebra = @import("algebra.zig");
const simplify = @import("simplify.zig");
const Number = num.Number;
const Node = eval.Node;

pub const Error = eval.Error;

const mk = calculus.mk;
const bin = calculus.bin;
const call1 = calculus.call1;
const neg = calculus.neg;
const int = calculus.int;
const uses = calculus.uses;

const Ctx = struct { ev: *eval.Eval, x: []const u8 };

fn numNode(a: std.mem.Allocator, v: Number) Error!*Node {
    return mk(a, .{ .number = v });
}

fn nameNode(a: std.mem.Allocator, text: []const u8) Error!*Node {
    return mk(a, .{ .name = .{ .text = text, .pos = 0 } });
}

const Lin = struct { a: Number, b: Number };

/// n = x, or a·x + b: its slope and offset.
fn linearOrX(ctx: Ctx, n: *const Node) Error!?Lin {
    if (try linear(ctx, n)) |l| return l;
    if (n.* == .name and std.mem.eql(u8, n.name.text, ctx.x)) return .{ .a = try num.fromInt(ctx.ev.a, 1), .b = try num.fromInt(ctx.ev.a, 0) };
    return null;
}

/// n = a·x + b with exact a ≠ 0, b.
fn linear(ctx: Ctx, n: *const Node) Error!?Lin {
    const a = ctx.ev.a;
    const p = (try algebra.fromNode(.{ .a = a, .session = ctx.ev.session }, n)) orelse return null;
    if (p.terms.len == 0) return null;
    for (p.vars, 0..) |v, vi| {
        for (p.terms) |t| if (t.exps[vi] != 0 and !std.mem.eql(u8, v, ctx.x)) return null;
    }
    const c = (try algebra.dense(a, p, ctx.x)) orelse return null;
    if (algebra.degree(c) != 1) return null;
    return .{ .a = c[1], .b = c[0] };
}

fn divBy(a: std.mem.Allocator, n: *Node, k: Number) Error!*Node {
    if (num.isOneNumber(k)) return n;
    return bin(a, .div, n, try numNode(a, k));
}

fn integ(ctx: Ctx, n: *const Node, depth: usize) Error!?*Node {
    const a = ctx.ev.a;
    if (depth > 8) return null;
    const x = ctx.x;
    if (!uses(n, x)) return try bin(a, .mul, @constCast(n), try nameNode(a, x));
    switch (n.*) {
        .number => unreachable,
        .name => return try bin(a, .div, try bin(a, .pow, try nameNode(a, x), try int(a, 2)), try int(a, 2)),
        .unary => |u| {
            if (u.op != .neg) return null;
            const inner = (try integ(ctx, u.arg, depth + 1)) orelse return null;
            return try neg(a, inner);
        },
        .binary => |b| switch (b.op) {
            .add, .sub => {
                const l = (try integ(ctx, b.l, depth + 1)) orelse return null;
                const r = (try integ(ctx, b.r, depth + 1)) orelse return null;
                return try bin(a, b.op, l, r);
            },
            .mul => {
                if (!uses(b.l, x)) {
                    const r = (try integ(ctx, b.r, depth + 1)) orelse return null;
                    return try bin(a, .mul, b.l, r);
                }
                if (!uses(b.r, x)) {
                    const l = (try integ(ctx, b.l, depth + 1)) orelse return null;
                    return try bin(a, .mul, l, b.r);
                }
                return try byParts(ctx, b.l, b.r, depth) orelse try byParts(ctx, b.r, b.l, depth);
            },
            .div => return try quotient(ctx, b.l, b.r, depth),
            .pow => return try power(ctx, b.l, b.r, depth),
            else => return null,
        },
        .call => |c| return try function(ctx, c.name, c.args, depth),
    }
}

/// ∫ p·g with p a polynomial of degree ≥ 1: p·G − ∫ p′·G, with G = ∫ g (or u = ln x).
fn byParts(ctx: Ctx, poly_side: *const Node, other: *const Node, depth: usize) Error!?*Node {
    const a = ctx.ev.a;
    const actx: algebra.Ctx = .{ .a = a, .session = ctx.ev.session };
    const p = (try algebra.fromNode(actx, poly_side)) orelse return null;
    const coefs = (try algebra.dense(a, p, ctx.x)) orelse return null;
    if (algebra.degree(coefs) < 1) return null;
    // u = ln x: ∫ x^n ln x = P ln x − ∫ P/x.
    if (other.* == .call and std.mem.eql(u8, other.call.name, "ln") and other.call.args.len == 1 and other.call.args[0].* == .name and
        std.mem.eql(u8, other.call.args[0].name.text, ctx.x))
    {
        const big_p = (try integ(ctx, poly_side, depth + 1)) orelse return null;
        const rest = (try integ(ctx, try bin(a, .div, big_p, try nameNode(a, ctx.x)), depth + 1)) orelse return null;
        return try bin(a, .sub, try bin(a, .mul, big_p, @constCast(other)), rest);
    }
    const g_int = (try integ(ctx, other, depth + 1)) orelse return null;
    // p′ from the coefficients, so that it is a clean polynomial (a constant once the degree is spent).
    const dp = try polyNode(a, try derivDense(a, coefs), ctx.x);
    const inner = (try integ(ctx, try bin(a, .mul, dp, g_int), depth + 1)) orelse return null;
    return try bin(a, .sub, try bin(a, .mul, @constCast(poly_side), g_int), inner);
}

fn quotient(ctx: Ctx, l: *const Node, r: *const Node, depth: usize) Error!?*Node {
    const a = ctx.ev.a;
    const x = ctx.x;
    if (!uses(r, x)) {
        const top = (try integ(ctx, l, depth + 1)) orelse return null;
        return try bin(a, .div, top, @constCast(r));
    }
    // 1/(ax + b): ln|ax + b| / a.
    if (!uses(l, x)) {
        if (try linear(ctx, r)) |lin| {
            const logged = try call1(a, "ln", try call1(a, "abs", @constCast(r)));
            return try bin(a, .mul, @constCast(l), try divBy(a, logged, lin.a));
        }
    }
    // Polynomials over polynomials: partial fractions when the denominator has distinct rational roots.
    const actx: algebra.Ctx = .{ .a = a, .session = ctx.ev.session };
    const pn = (try algebra.fromNode(actx, l)) orelse return null;
    const pd = (try algebra.fromNode(actx, r)) orelse return null;
    const nc = (try algebra.dense(a, pn, x)) orelse return null;
    const dc = (try algebra.dense(a, pd, x)) orelse return null;
    // A polynomial over a single power of x: term by term (x²/2 ÷ x is x/2).
    if (pd.terms.len == 1) {
        const dt = pd.terms[0];
        const k = if (dt.exps.len > 0) dt.exps[0] else 0;
        var sum: ?*Node = null;
        for (pn.terms) |t| {
            const ti: i64 = if (t.exps.len > 0) @intCast(t.exps[0]) else 0;
            const coef = try num.div(a, t.c, dt.c);
            const e = ti - @as(i64, k);
            var term: *Node = undefined;
            if (e == -1) {
                term = try bin(a, .mul, try numNode(a, coef), try call1(a, "ln", try call1(a, "abs", try nameNode(a, x))));
            } else {
                const e1 = e + 1;
                const raised: *Node = if (e1 == 0) try int(a, 1) else if (e1 == 1) try nameNode(a, x) else try bin(a, .pow, try nameNode(a, x), try int(a, e1));
                term = try bin(a, .mul, try numNode(a, try num.div(a, coef, try num.fromInt(a, e1))), raised);
            }
            sum = if (sum) |sn| try bin(a, .add, sn, term) else term;
        }
        return sum;
    }
    if (algebra.degree(nc) >= algebra.degree(dc)) return null;
    // x/(x² + c) and 1/(x² + c) with c > 0.
    if (algebra.degree(dc) == 2 and dc[1].isZero() and dc[2].isExact() and !dc[2].isNegative() and !dc[0].isNegative() and !dc[0].isZero()) {
        const lead = dc[2];
        const c = try num.div(a, dc[0], lead);
        if (algebra.degree(nc) == 1 and nc[0].isZero()) {
            // k·x/(lead(x² + c)) → k/(2·lead)·ln(x² + c)
            const k = try num.div(a, nc[1], try num.mul(a, try num.fromInt(a, 2), lead));
            const arg = try bin(a, .add, try bin(a, .pow, try nameNode(a, x), try int(a, 2)), try numNode(a, c));
            return try bin(a, .mul, try numNode(a, k), try call1(a, "ln", arg));
        }
        if (algebra.degree(nc) == 0) {
            // k/(lead(x² + c)) → k/(lead·√c)·atan(x/√c)
            const root = try call1(a, "sqrt", try numNode(a, c));
            const scale = try bin(a, .div, try numNode(a, try num.div(a, nc[0], lead)), root);
            return try bin(a, .mul, scale, try call1(a, "atan", try bin(a, .div, try nameNode(a, x), root)));
        }
    }
    const fac = try algebra.factorDense(a, dc);
    var total: ?*Node = null;
    for (fac.factors) |f| {
        if (f.mult != 1 or algebra.degree(f.coefs) != 1) return null;
        // The root of this factor, and the residue N(root) / D′(root).
        const root = try num.div(a, try num.neg(a, f.coefs[0]), f.coefs[1]);
        const dprime = try derivDense(a, dc);
        const residue = try num.div(a, try algebra.evalAt(a, nc, root), try algebra.evalAt(a, dprime, root));
        if (residue.isZero()) continue;
        const shifted = try bin(a, .sub, try nameNode(a, x), try numNode(a, root));
        const term = try bin(a, .mul, try numNode(a, residue), try call1(a, "ln", try call1(a, "abs", shifted)));
        total = if (total) |t| try bin(a, .add, t, term) else term;
    }
    return total;
}

/// c₀ + c₁x + c₂x² + … as an expression.
fn polyNode(a: std.mem.Allocator, c: []const Number, x: []const u8) Error!*Node {
    var total: ?*Node = null;
    for (c, 0..) |v, i| {
        if (v.isZero()) continue;
        var term: *Node = undefined;
        if (i == 0) {
            term = try numNode(a, v);
        } else {
            const power_node: *Node = if (i == 1) try nameNode(a, x) else try bin(a, .pow, try nameNode(a, x), try int(a, @as(i64, @intCast(i))));
            term = if (num.isOneNumber(v)) power_node else try bin(a, .mul, try numNode(a, v), power_node);
        }
        total = if (total) |t| try bin(a, .add, t, term) else term;
    }
    return total orelse try int(a, 0);
}

fn derivDense(a: std.mem.Allocator, c: []const Number) Error![]Number {
    if (c.len < 2) return try a.alloc(Number, 0);
    const out = try a.alloc(Number, c.len - 1);
    for (1..c.len) |i| out[i - 1] = try num.mul(a, c[i], try num.fromInt(a, @as(i64, @intCast(i))));
    return out;
}

fn power(ctx: Ctx, base: *const Node, e: *const Node, depth: usize) Error!?*Node {
    _ = depth;
    const a = ctx.ev.a;
    const x = ctx.x;
    if (!uses(e, x)) {
        const en = (try ctx.ev.eval(e, null));
        if (!en.isExact()) return null;
        const minus_one = (try num.order(a, en, try num.fromInt(a, -1))) == .eq;
        const lin = (try linearOrX(ctx, base)) orelse return null;
        if (minus_one) {
            const logged = try call1(a, "ln", try call1(a, "abs", @constCast(base)));
            return try divBy(a, logged, lin.a);
        }
        const e1 = try num.add(a, en, try num.fromInt(a, 1));
        const raised = try bin(a, .pow, @constCast(base), try numNode(a, e1));
        return try divBy(a, raised, try num.mul(a, lin.a, e1));
    }
    if (!uses(base, x)) {
        const lin = (try linear(ctx, e)) orelse return null;
        // e^(ax + b)
        if (base.* == .name and std.mem.eql(u8, base.name.text, "e")) return try divBy(a, try call1(a, "exp", @constCast(e)), lin.a);
        const raised = try bin(a, .pow, @constCast(base), @constCast(e));
        const denom = try bin(a, .mul, try numNode(a, lin.a), try call1(a, "ln", @constCast(base)));
        return try bin(a, .div, raised, denom);
    }
    return null;
}

fn function(ctx: Ctx, name: []const u8, args: []*Node, depth: usize) Error!?*Node {
    _ = depth;
    const a = ctx.ev.a;
    if (args.len != 1) return null;
    const u = args[0];
    const lin = (try linearOrX(ctx, u)) orelse return null;
    const eql = std.ascii.eqlIgnoreCase;
    var core: *Node = undefined;
    if (eql(name, "sin")) {
        core = try neg(a, try call1(a, "cos", u));
    } else if (eql(name, "cos")) {
        core = try call1(a, "sin", u);
    } else if (eql(name, "tan")) {
        core = try neg(a, try call1(a, "ln", try call1(a, "abs", try call1(a, "cos", u))));
    } else if (eql(name, "exp")) {
        core = try call1(a, "exp", u);
    } else if (eql(name, "sinh")) {
        core = try call1(a, "cosh", u);
    } else if (eql(name, "cosh")) {
        core = try call1(a, "sinh", u);
    } else if (eql(name, "ln")) {
        core = try bin(a, .sub, try bin(a, .mul, u, try call1(a, "ln", u)), u);
    } else if (eql(name, "sqrt")) {
        core = try bin(a, .div, try bin(a, .mul, try int(a, 2), try bin(a, .pow, u, try numNode(a, try num.div(a, try num.fromInt(a, 3), try num.fromInt(a, 2))))), try int(a, 3));
    } else if (eql(name, "atan")) {
        const one_plus = try bin(a, .add, try int(a, 1), try bin(a, .pow, u, try int(a, 2)));
        core = try bin(a, .sub, try bin(a, .mul, u, try call1(a, "atan", u)), try bin(a, .div, try call1(a, "ln", one_plus), try int(a, 2)));
    } else if (eql(name, "asin") or eql(name, "acos")) {
        const root = try call1(a, "sqrt", try bin(a, .sub, try int(a, 1), try bin(a, .pow, u, try int(a, 2))));
        core = try bin(a, if (eql(name, "asin")) .add else .sub, try bin(a, .mul, u, try call1(a, name, u)), root);
    } else return null;
    return try divBy(a, core, lin.a);
}

/// An antiderivative of n with respect to x, checked by differentiating it; null when none is found.
pub fn antiderivative(ev: *eval.Eval, n: *const Node, x: []const u8) Error!?*Node {
    const ctx: Ctx = .{ .ev = ev, .x = x };
    const f = (integ(ctx, n, 0) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    }) orelse return null;
    // Does it differentiate back?
    const d = calculus.derivative(ev.a, ev, f, x) catch return null;
    var compared: usize = 0;
    for ([_]f64{ 0.37, 1.13, 2.41, -0.83, 0.61 }) |at| {
        const want = ev.float(n, x, at);
        const got = ev.float(d, x, at);
        if (!std.math.isFinite(want) or !std.math.isFinite(got)) continue;
        compared += 1;
        if (@abs(want - got) > 1e-6 * @max(1, @abs(want))) return null;
    }
    if (compared < 2) return null;
    return f;
}

/// "x³/3 + C": the integral of the entry text with respect to x, as text.
pub fn integralText(ev: *eval.Eval, expr: *const Node, x: []const u8) Error!?[]const u8 {
    const f = (try antiderivative(ev, expr, x)) orelse return null;
    const text = try simplify.simplify(ev.a, ev, f);
    return try std.fmt.allocPrint(ev.a, "{s} + C", .{text});
}

// ---- tests ------------------------------------------------------------------------------------------

fn finds(source: []const u8, x: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const n = try eval.parseExpr(a, source, .{ .angle = .radians }, &p);
    var ev: eval.Eval = .{ .a = a, .session = &session, .mode = .{ .angle = .radians }, .problem = &p };
    return (try antiderivative(&ev, n, x)) != null;
}

test "antiderivatives that differentiate back" {
    const found = [_][]const u8{
        "x^2",           "3x^2 + 2x + 1", "x^3 - 4x",         "1/x",              "1/(2x + 3)",       "sqrt(x)",
        "sin(2x)",       "cos(x)",        "exp(3x)",          "e^(2x)",           "2^x",              "ln(x)",
        "x*exp(x)",      "x*sin(x)",      "x^2*cos(x)", "x^2*exp(x)",      "x*ln(x)",          "1/(x^2 + 1)",      "x/(x^2 + 4)",
        "1/(x^2 - 1)",   "(2x + 1)/(x^2 + x - 6)", "atan(x)", "(3x + 1)^4",       "sinh(x) + cosh(x)", "x^2 + sin(x) - 5",
    };
    for (found) |f| {
        if (!try finds(f, "x")) {
            std.debug.print("no antiderivative found for {s}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
    // Not elementary, or beyond the rules: nothing is invented.
    const none = [_][]const u8{ "exp(x^2)", "sin(x)/x", "x^x" };
    for (none) |f| {
        if (try finds(f, "x")) {
            std.debug.print("unexpected antiderivative for {s}\n", .{f});
            return error.TestUnexpectedResult;
        }
    }
}

test "zz print" {
    if (std.c.getenv("INT_PRINT") == null) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    for ([_][]const u8{ "x*sin(x)", "x^2*cos(x)", "x^2*exp(x)", "x*ln(x)", "1/(x^2 - 1)", "(2x + 1)/(x^2 + x - 6)", "3x^2 + 2x + 1", "sin(2x)", "x/(x^2 + 4)" }) |src| {
        var p: eval.Problem = .{};
        const n = try eval.parseExpr(a, src, .{ .angle = .radians }, &p);
        var ev: eval.Eval = .{ .a = a, .session = &session, .mode = .{ .angle = .radians }, .problem = &p };
        const t = integralText(&ev, n, "x") catch |e| {
            std.debug.print("{s}: error {s}\n", .{ src, @errorName(e) });
            continue;
        };
        std.debug.print("{s}  ->  {s}\n", .{ src, t orelse "(none)" });
    }
}
