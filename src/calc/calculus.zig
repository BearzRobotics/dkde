//! Calculus for the calculator:
//!
//!   diff(f, x)           the derivative of f by x, as a formula (by the rules
//!                        of differentiation, then tidied)
//!   diff(f, x, a)        its value at x = a
//!   integral(f, x, a, b) the definite integral from a to b (numerically, to
//!                        about 12 digits; exact when it is a simple fraction)
//!   limit(f, x, a)       the limit as x goes to a (a may be inf or -inf)
//!   sum(f, k, m, n)      f summed for k = m … n, exactly
//!   prod(f, k, m, n)     the product, exactly
//!
//! There is no symbolic integration: that needs a computer algebra system.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const Node = eval.Node;
const Error = eval.Error;

fn mk(a: std.mem.Allocator, n: Node) Error!*Node {
    const p = try a.create(Node);
    p.* = n;
    return p;
}

fn int(a: std.mem.Allocator, v: i64) Error!*Node {
    return mk(a, .{ .number = try num.fromInt(a, v) });
}

fn bin(a: std.mem.Allocator, op: eval.Op, l: *Node, r: *Node) Error!*Node {
    return mk(a, .{ .binary = .{ .op = op, .l = l, .r = r } });
}

fn call1(a: std.mem.Allocator, name: []const u8, arg: *Node) Error!*Node {
    const args = try a.alloc(*Node, 1);
    args[0] = arg;
    return mk(a, .{ .call = .{ .name = name, .args = args, .pos = 0 } });
}

fn neg(a: std.mem.Allocator, n: *Node) Error!*Node {
    return mk(a, .{ .unary = .{ .op = .neg, .arg = n } });
}

/// Whether `n` depends on `x`.
pub fn uses(n: *const Node, x: []const u8) bool {
    return switch (n.*) {
        .number => false,
        .name => |nm| std.mem.eql(u8, nm.text, x),
        .unary => |u| uses(u.arg, x),
        .binary => |b| uses(b.l, x) or uses(b.r, x),
        .call => |c| for (c.args) |arg| {
            if (uses(arg, x)) break true;
        } else false,
    };
}

/// A copy of `n` with `x` replaced by `value`.
pub fn substitute(a: std.mem.Allocator, n: *const Node, x: []const u8, value: *Node) Error!*Node {
    return switch (n.*) {
        .number => @constCast(n),
        .name => |nm| if (std.mem.eql(u8, nm.text, x)) value else @constCast(n),
        .unary => |u| mk(a, .{ .unary = .{ .op = u.op, .arg = try substitute(a, u.arg, x, value) } }),
        .binary => |b| bin(a, b.op, try substitute(a, b.l, x, value), try substitute(a, b.r, x, value)),
        .call => |c| blk: {
            var args = try a.alloc(*Node, c.args.len);
            for (c.args, 0..) |arg, i| args[i] = try substitute(a, arg, x, value);
            break :blk mk(a, .{ .call = .{ .name = c.name, .args = args, .pos = c.pos } });
        },
    };
}

/// The derivative of `n` by `x`, as a tree (not tidied).
pub fn derivative(a: std.mem.Allocator, ev: *eval.Eval, n: *const Node, x: []const u8) Error!*Node {
    if (!uses(n, x)) return int(a, 0);
    switch (n.*) {
        .number => return int(a, 0),
        .name => return int(a, 1),
        .unary => |u| switch (u.op) {
            .neg => return neg(a, try derivative(a, ev, u.arg, x)),
            .pct => return bin(a, .div, try derivative(a, ev, u.arg, x), try int(a, 100)),
            else => return error.Domain,
        },
        .binary => |b| {
            const du = try derivative(a, ev, b.l, x);
            const dv = try derivative(a, ev, b.r, x);
            switch (b.op) {
                .add => return bin(a, .add, du, dv),
                .sub => return bin(a, .sub, du, dv),
                // (uv)' = u'v + uv'
                .mul => return bin(a, .add, try bin(a, .mul, du, b.r), try bin(a, .mul, b.l, dv)),
                // (u/v)' = (u'v − uv') / v²
                .div => return bin(a, .div, try bin(a, .sub, try bin(a, .mul, du, b.r), try bin(a, .mul, b.l, dv)), try bin(a, .pow, b.r, try int(a, 2))),
                .pow => {
                    if (!uses(b.r, x)) {
                        // (u^n)' = n·u^(n−1)·u'
                        return bin(a, .mul, try bin(a, .mul, b.r, try bin(a, .pow, b.l, try bin(a, .sub, b.r, try int(a, 1)))), du);
                    }
                    if (!uses(b.l, x)) {
                        // (c^v)' = c^v·ln(c)·v'
                        return bin(a, .mul, try bin(a, .mul, @constCast(n), try call1(a, "ln", b.l)), dv);
                    }
                    // (u^v)' = u^v·(v'·ln(u) + v·u'/u)
                    const inner = try bin(a, .add, try bin(a, .mul, dv, try call1(a, "ln", b.l)), try bin(a, .div, try bin(a, .mul, b.r, du), b.l));
                    return bin(a, .mul, @constCast(n), inner);
                },
                .add_pct => return bin(a, .add, du, try bin(a, .div, try bin(a, .add, try bin(a, .mul, du, b.r), try bin(a, .mul, b.l, dv)), try int(a, 100))),
                .sub_pct => return bin(a, .sub, du, try bin(a, .div, try bin(a, .add, try bin(a, .mul, du, b.r), try bin(a, .mul, b.l, dv)), try int(a, 100))),
                else => return error.Domain,
            }
        },
        .call => |c| return callDerivative(a, ev, c.name, c.args, x),
    }
}

/// The factor trigonometric functions gain in degrees (π/180) or gradians.
fn angleFactor(a: std.mem.Allocator, ev: *eval.Eval) Error!?*Node {
    return switch (ev.mode.angle) {
        .radians => null,
        .degrees => try bin(a, .div, try mk(a, .{ .name = .{ .text = "π", .pos = 0 } }), try int(a, 180)),
        .gradians => try bin(a, .div, try mk(a, .{ .name = .{ .text = "π", .pos = 0 } }), try int(a, 200)),
    };
}

fn callDerivative(a: std.mem.Allocator, ev: *eval.Eval, name: []const u8, args: []const *Node, x: []const u8) Error!*Node {
    // A function of one's own: its body with the arguments put in.
    if (ev.session.funcs.get(name)) |f| {
        if (f.params.len != args.len) return error.WrongArguments;
        var p: eval.Problem = .{};
        var body = try eval.parseExpr(a, f.body, ev.mode, &p);
        for (f.params, args) |param, arg| body = try substitute(a, body, param, arg);
        return derivative(a, ev, body, x);
    }
    if (args.len != 1) return error.Domain;
    const u = args[0];
    const du = try derivative(a, ev, u, x);
    const eql = std.mem.eql;
    const f = name;
    // Chain rule: f(u)' = f'(u)·u'.
    const outer: *Node = blk: {
        if (eql(u8, f, "sin") or eql(u8, f, "cos") or eql(u8, f, "tan")) {
            const d = if (eql(u8, f, "sin"))
                try call1(a, "cos", u)
            else if (eql(u8, f, "cos"))
                try neg(a, try call1(a, "sin", u))
            else
                try bin(a, .div, try int(a, 1), try bin(a, .pow, try call1(a, "cos", u), try int(a, 2)));
            break :blk if (try angleFactor(a, ev)) |k| try bin(a, .mul, k, d) else d;
        }
        if (eql(u8, f, "asin") or eql(u8, f, "acos") or eql(u8, f, "atan")) {
            const one = try int(a, 1);
            const u_sq = try bin(a, .pow, u, try int(a, 2));
            var d = if (eql(u8, f, "atan"))
                try bin(a, .div, one, try bin(a, .add, one, u_sq))
            else
                try bin(a, .div, one, try call1(a, "sqrt", try bin(a, .sub, one, u_sq)));
            if (eql(u8, f, "acos")) d = try neg(a, d);
            break :blk if (try angleFactor(a, ev)) |k| try bin(a, .div, d, k) else d;
        }
        if (eql(u8, f, "sinh")) break :blk try call1(a, "cosh", u);
        if (eql(u8, f, "cosh")) break :blk try call1(a, "sinh", u);
        if (eql(u8, f, "tanh")) break :blk try bin(a, .div, try int(a, 1), try bin(a, .pow, try call1(a, "cosh", u), try int(a, 2)));
        if (eql(u8, f, "exp")) break :blk try call1(a, "exp", u);
        if (eql(u8, f, "ln")) break :blk try bin(a, .div, try int(a, 1), u);
        if (eql(u8, f, "log") or eql(u8, f, "log10")) break :blk try bin(a, .div, try int(a, 1), try bin(a, .mul, u, try call1(a, "ln", try int(a, 10))));
        if (eql(u8, f, "log2")) break :blk try bin(a, .div, try int(a, 1), try bin(a, .mul, u, try call1(a, "ln", try int(a, 2))));
        if (eql(u8, f, "sqrt")) break :blk try bin(a, .div, try int(a, 1), try bin(a, .mul, try int(a, 2), try call1(a, "sqrt", u)));
        if (eql(u8, f, "cbrt")) break :blk try bin(a, .div, try int(a, 1), try bin(a, .mul, try int(a, 3), try bin(a, .pow, try call1(a, "cbrt", u), try int(a, 2))));
        if (eql(u8, f, "abs")) break :blk try call1(a, "sign", u);
        return error.Domain;
    };
    return bin(a, .mul, outer, du);
}

/// Replaces diff(f, x) with the derivative's tree, and diff(f, x, a) with
/// it at x = a, everywhere in `n`.
pub fn expand(a: std.mem.Allocator, ev: *eval.Eval, n: *Node) Error!*Node {
    switch (n.*) {
        .number, .name => return n,
        .unary => |u| return mk(a, .{ .unary = .{ .op = u.op, .arg = try expand(a, ev, u.arg) } }),
        .binary => |b| return bin(a, b.op, try expand(a, ev, b.l), try expand(a, ev, b.r)),
        .call => |c| {
            var args = try a.alloc(*Node, c.args.len);
            for (c.args, 0..) |arg, i| args[i] = try expand(a, ev, arg);
            if (std.ascii.eqlIgnoreCase(c.name, "diff") or std.ascii.eqlIgnoreCase(c.name, "derivative")) {
                if (args.len < 2 or args.len > 3 or args[1].* != .name) {
                    ev.problem.* = .{ .pos = c.pos, .name = c.name };
                    return error.WrongArguments;
                }
                const x = args[1].name.text;
                const d = try derivative(a, ev, args[0], x);
                return if (args.len == 3) substitute(a, d, x, args[2]) else d;
            }
            return mk(a, .{ .call = .{ .name = c.name, .args = args, .pos = c.pos } });
        },
    }
}

/// Whether `n` has a call to diff anywhere (so it must be expanded first).
pub fn hasDiff(n: *const Node) bool {
    return switch (n.*) {
        .number, .name => false,
        .unary => |u| hasDiff(u.arg),
        .binary => |b| hasDiff(b.l) or hasDiff(b.r),
        .call => |c| std.ascii.eqlIgnoreCase(c.name, "diff") or std.ascii.eqlIgnoreCase(c.name, "derivative") or for (c.args) |arg| {
            if (hasDiff(arg)) break true;
        } else false,
    };
}

// ---- numbers ----------------------------------------------------------------------

/// The definite integral of f(x) from lo to hi, by adaptive Gauss–Kronrod
/// (7 and 15 points). Error when it does not settle (a pole inside).
pub fn integrate(ev: *eval.Eval, f: *const Node, x: []const u8, lo: f64, hi: f64) Error!f64 {
    if (lo == hi) return 0;
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return error.Domain;
    var budget: usize = 4000;
    const total = try gk(ev, f, x, lo, hi, 1e-13, 0, &budget);
    return total;
}

const kronrod_x = [_]f64{ 0.991455371120812639, 0.949107912342758525, 0.864864423359769073, 0.741531185599394440, 0.586087235467691130, 0.405845151377397167, 0.207784955007898468, 0.0 };
const kronrod_w = [_]f64{ 0.022935322010529225, 0.063092092629978553, 0.104790010322250184, 0.140653259715525919, 0.169004726639267903, 0.190350578064785410, 0.204432940075298892, 0.209482141084727828 };
const gauss_w = [_]f64{ 0.129484966168869693, 0.279705391489276668, 0.381830050505118945, 0.417959183673469388 };

fn gk(ev: *eval.Eval, f: *const Node, x: []const u8, a: f64, b: f64, tol: f64, depth: usize, budget: *usize) Error!f64 {
    if (budget.* == 0) return error.Domain;
    budget.* -= 1;
    const c = (a + b) / 2;
    const h = (b - a) / 2;
    var k: f64 = 0;
    var g: f64 = 0;
    for (kronrod_x, 0..) |xi, i| {
        const f1 = ev.float(f, x, c + h * xi);
        if (!std.math.isFinite(f1)) return error.Domain;
        if (i == kronrod_x.len - 1) {
            // The middle point is shared by both rules.
            k += kronrod_w[i] * f1;
            g += gauss_w[3] * f1;
            continue;
        }
        const f2 = ev.float(f, x, c - h * xi);
        if (!std.math.isFinite(f2)) return error.Domain;
        k += kronrod_w[i] * (f1 + f2);
        // The 7-point Gauss rule uses every other Kronrod point.
        if (i % 2 == 1) g += gauss_w[i / 2] * (f1 + f2);
    }
    k *= h;
    g *= h;
    const err = @abs(k - g);
    if (err <= @max(tol * @abs(k), 1e-15) or depth > 40) return k;
    return (try gk(ev, f, x, a, c, tol, depth + 1, budget)) + (try gk(ev, f, x, c, b, tol, depth + 1, budget));
}

/// The limit of f(x) as x goes to `at` (from both sides; `at` may be ±∞).
pub fn limit(ev: *eval.Eval, f: *const Node, x: []const u8, at: f64) Error!f64 {
    if (std.math.isInf(at)) return approach(ev, f, x, 0, if (at > 0) 1 else -1, true);
    // Defined there: that is the limit (for the functions here).
    const direct = ev.float(f, x, at);
    if (std.math.isFinite(direct)) return direct;
    const left = try approach(ev, f, x, at, -1, false);
    const right = try approach(ev, f, x, at, 1, false);
    if (@abs(left - right) > 1e-6 * @max(1, @abs(left))) return error.Domain;
    return (left + right) / 2;
}

/// f at points closing in on `at` from one side (at + dir·h, or dir/h for
/// infinity, h = 10⁻²… 10⁻⁹), extrapolated as h → 0; the estimate that
/// changes least is kept (before rounding spoils the smallest steps).
fn approach(ev: *eval.Eval, f: *const Node, x: []const u8, at: f64, dir: f64, infinite: bool) Error!f64 {
    var values: [8]f64 = undefined;
    var h: f64 = 1e-2;
    for (&values) |*v| {
        const point = if (infinite) dir / h else at + dir * h * @max(1, @abs(at));
        v.* = ev.float(f, x, point);
        if (!std.math.isFinite(v.*)) return error.Domain;
        h /= 10;
    }
    // Richardson: the error shrinks tenfold per step, so v + (v − prev)/9.
    var best: f64 = values[values.len - 1];
    var best_change: f64 = std.math.inf(f64);
    var prev_est: f64 = std.math.nan(f64);
    for (values[1..], 1..) |v, i| {
        const est = v + (v - values[i - 1]) / 9;
        const change = @abs(est - prev_est);
        if (change < best_change) {
            best_change = change;
            best = est;
        }
        prev_est = est;
    }
    return best;
}

// ---- tests ------------------------------------------------------------------------

const Fix = struct {
    arena: std.heap.ArenaAllocator,
    session: eval.Session,
    problem: eval.Problem = .{},

    fn init() Fix {
        return .{ .arena = .init(std.testing.allocator), .session = .{ .gpa = std.testing.allocator } };
    }

    fn deinit(self: *Fix) void {
        self.session.deinit();
        self.arena.deinit();
    }

    fn out(self: *Fix, text: []const u8, angle: eval.Angle) ![]const u8 {
        const a = self.arena.allocator();
        const o = try eval.run(a, &self.session, text, .{ .angle = angle }, &self.problem);
        return switch (o) {
            .value => |v| num.format(a, v, .{ .decimals = 8 }),
            .simplified => |s| s,
            .assigned => |x| num.format(a, x.value, .{ .decimals = 8 }),
            else => "?",
        };
    }
};

test "derivatives" {
    var f = Fix.init();
    defer f.deinit();
    try std.testing.expectEqualStrings("2x", try f.out("diff(x², x)", .radians));
    try std.testing.expectEqualStrings("3x² + 2", try f.out("diff(x³ + 2x + 1, x)", .radians));
    try std.testing.expectEqualStrings("cos(x)", try f.out("diff(sin(x), x)", .radians));
    try std.testing.expectEqualStrings("1/x", try f.out("diff(ln(x), x)", .radians));
    try std.testing.expectEqualStrings("12", try f.out("diff(x³, x, 2)", .radians));
    try std.testing.expectEqualStrings("0.5", try f.out("diff(sqrt(x), x, 1)", .radians));
    // In degrees the derivative carries π/180.
    try std.testing.expectEqualStrings("0.01745329", try f.out("diff(sin(x), x, 0)", .degrees));
    _ = try f.out("g(t) = t²", .radians);
    try std.testing.expectEqualStrings("6", try f.out("diff(g(x), x, 3)", .radians));
}

test "integrals, limits, sums" {
    var f = Fix.init();
    defer f.deinit();
    try std.testing.expectEqualStrings("9", try f.out("integral(x², x, 0, 3)", .radians));
    try std.testing.expectEqualStrings("2", try f.out("integral(sin(x), x, 0, π)", .radians));
    try std.testing.expectEqualStrings("0.74682413", try f.out("integral(e^(-x²), x, 0, 1)", .radians));
    try std.testing.expectEqualStrings("1", try f.out("limit(sin(x)/x, x, 0)", .radians));
    try std.testing.expectEqualStrings("2.71828183", try f.out("limit((1 + 1/n)^n, n, inf)", .radians));
    try std.testing.expectEqualStrings("385", try f.out("sum(k², k, 1, 10)", .radians));
    try std.testing.expectEqualStrings("120", try f.out("prod(k, k, 1, 5)", .radians));
    try std.testing.expectEqualStrings("0.99", try f.out("sum(1/(k(k+1)), k, 1, 99)", .radians));
    try std.testing.expectEqualStrings("6", try f.out("sum(1, 2, 3)", .radians));
}

test "the manual page's examples" {
    var f = Fix.init();
    defer f.deinit();
    try std.testing.expectEqualStrings("55", try f.out("50 + 10%", .degrees));
    try std.testing.expectEqualStrings("3", try f.out("r = 3", .degrees));
    try std.testing.expectEqualStrings("18.84955592", try f.out("2πr", .degrees));
    try std.testing.expectEqualStrings("0.5", try f.out("sin(30)", .degrees));
    try std.testing.expectEqualStrings("12", try f.out("gcd(84, 36)", .degrees));
    try std.testing.expectEqualStrings("2598960", try f.out("nCr(52, 5)", .degrees));
    try std.testing.expectEqualStrings("6", try f.out("mean(3, 5, 10)", .degrees));
    try std.testing.expectEqualStrings("3x²", try f.out("diff(x³, x)", .radians));
    try std.testing.expectEqualStrings("2x·sin(x) + x²·cos(x)", try f.out("diff(x²·sin(x), x)", .radians));
}

test "the guide's examples" {
    var f = Fix.init();
    defer f.deinit();
    try std.testing.expectEqualStrings("9", try f.out("6 ÷ 2(1 + 2)", .degrees));
    try std.testing.expectEqualStrings("8", try f.out("1 << 2 + 1", .degrees));
    try std.testing.expectEqualStrings("2", try f.out("6 and 3", .degrees));
    try std.testing.expectEqualStrings("4", try f.out("√9 + 1", .degrees));
    try std.testing.expectEqualStrings("-3", try f.out("root(−27, 3)", .degrees));
    try std.testing.expectEqualStrings("30", try f.out("200 × 15%", .degrees));
    try std.testing.expectEqualStrings("5", try f.out("mean(2, 4, 9)", .degrees));
    try std.testing.expectEqualStrings("3x² + 2", try f.out("diff(x³ + 2x, x)", .radians));
    try std.testing.expectEqualStrings("2x + 2", try f.out("2(x + 1)", .radians));
    try std.testing.expectEqualStrings("x³", try f.out("x²·x", .radians));
}
