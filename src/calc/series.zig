// SPDX-License-Identifier: GPL-2.0-or-later
//! Power series: `taylor(f, x, a, n)` and exact limits.
//!
//! A series is kept as a lowest power (it may be negative: a pole gives a Laurent series) and
//! coefficients, known up to a stated order. Sums, products and quotients of series are worked out
//! term by term, so sin(x)/x, (1 − cos x)/x² or 1/x − 1/sin x need no special rules. Everything
//! that is not a sum, product or quotient is expanded from its derivatives at the point.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const calculus = @import("calculus.zig");
const algebra = @import("algebra.zig");
const Number = num.Number;
const Node = eval.Node;

pub const Error = eval.Error;

/// c[0]·t^lo + c[1]·t^(lo+1) + …, exact up to (not including) t^top.
pub const Series = struct {
    lo: i32,
    c: []Number,
    top: i32,
};

fn zero(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 0);
}

/// The series of f about x = at, known up to order `top` (relative to the point).
fn leaf(ev: *eval.Eval, f: *const Node, x: []const u8, center: Number, count: usize) Error!Series {
    const a = ev.a;
    // A polynomial is shifted to the point exactly (its high derivatives are zero, not worth evaluating).
    const actx: algebra.Ctx = .{ .a = a, .session = ev.session };
    if (try algebra.fromNode(actx, f)) |poly| {
        if (try algebra.dense(a, poly, x)) |dense| {
            const coefs = try a.alloc(Number, count);
            for (coefs) |*c| c.* = try zero(a);
            // Repeated synthetic division by (x − center) gives the coefficients about the point.
            var work = try a.dupe(Number, dense);
            var k: usize = 0;
            while (k < count and work.len > 0) : (k += 1) {
                var rem = try zero(a);
                var i = work.len;
                while (i > 0) {
                    i -= 1;
                    rem = try num.add(a, work[i], try num.mul(a, rem, center));
                    work[i] = rem;
                }
                coefs[k] = work[0];
                work = work[1..];
            }
            return .{ .lo = 0, .c = coefs, .top = @intCast(count) };
        }
    }
    const point = try calculus.mk(a, .{ .number = center });
    var coefs = try a.alloc(Number, count);
    var d: *const Node = f;
    var fact = try num.fromInt(a, 1);
    for (0..count) |k| {
        if (k > 0) {
            d = try calculus.derivative(a, ev, d, x);
            fact = try num.mul(a, fact, try num.fromInt(a, @as(i64, @intCast(k))));
        }
        const at_point = try calculus.substitute(a, d, x, point);
        const v = ev.eval(at_point, null) catch return error.Domain;
        coefs[k] = try num.div(a, v, fact);
    }
    return .{ .lo = 0, .c = coefs, .top = @intCast(count) };
}

fn trim(a: std.mem.Allocator, s: Series) Error!Series {
    // Leading zeros move the lowest power up (never past the known order).
    var lo = s.lo;
    var i: usize = 0;
    while (i < s.c.len and s.c[i].isZero() and lo < s.top) : (i += 1) lo += 1;
    _ = a;
    return .{ .lo = lo, .c = s.c[i..], .top = s.top };
}

fn at(s: Series, p: i32) ?Number {
    if (p < s.lo) return null;
    const i: usize = @intCast(p - s.lo);
    if (i >= s.c.len) return null;
    return s.c[i];
}

fn add(a: std.mem.Allocator, x: Series, y: Series, sign: i64) Error!Series {
    const lo = @min(x.lo, y.lo);
    const top = @min(x.top, y.top);
    if (top <= lo) return error.Domain;
    const out = try a.alloc(Number, @intCast(top - lo));
    var p = lo;
    while (p < top) : (p += 1) {
        var v = at(x, p) orelse try zero(a);
        if (at(y, p)) |w| v = if (sign > 0) try num.add(a, v, w) else try num.sub(a, v, w);
        out[@intCast(p - lo)] = v;
    }
    return .{ .lo = lo, .c = out, .top = top };
}

fn mul(a: std.mem.Allocator, x: Series, y: Series) Error!Series {
    const top = @min(x.lo + y.top, y.lo + x.top);
    const lo = x.lo + y.lo;
    if (top <= lo) return error.Domain;
    const out = try a.alloc(Number, @intCast(top - lo));
    for (out) |*o| o.* = try zero(a);
    for (x.c, 0..) |xc, i| {
        for (y.c, 0..) |yc, j| {
            const p = i + j;
            if (p >= out.len) continue;
            out[p] = try num.add(a, out[p], try num.mul(a, xc, yc));
        }
    }
    return .{ .lo = lo, .c = out, .top = top };
}

fn div(a: std.mem.Allocator, x_in: Series, y_in: Series) Error!Series {
    const x = try trim(a, x_in);
    const y = try trim(a, y_in);
    if (y.c.len == 0 or y.c[0].isZero()) return error.Domain;
    // Relative precision: the shorter of the two.
    const n = @min(x.c.len, y.c.len);
    if (n == 0) return error.Domain;
    const out = try a.alloc(Number, n);
    for (0..n) |k| {
        var v = if (k < x.c.len) x.c[k] else try zero(a);
        for (0..k) |j| v = try num.sub(a, v, try num.mul(a, out[j], if (k - j < y.c.len) y.c[k - j] else try zero(a)));
        out[k] = try num.div(a, v, y.c[0]);
    }
    const lo = x.lo - y.lo;
    return .{ .lo = lo, .c = out, .top = lo + @as(i32, @intCast(n)) };
}

/// The series of the expression: sums, differences, products and quotients are combined,
/// everything else is expanded from its derivatives.
pub fn of(ev: *eval.Eval, f: *const Node, x: []const u8, point: Number, count: usize) Error!Series {
    const a = ev.a;
    switch (f.*) {
        .binary => |b| switch (b.op) {
            .add, .sub => {
                const l = try of(ev, b.l, x, point, count);
                const r = try of(ev, b.r, x, point, count);
                return add(a, l, r, if (b.op == .add) 1 else -1);
            },
            .mul => {
                const l = try of(ev, b.l, x, point, count);
                const r = try of(ev, b.r, x, point, count);
                return mul(a, l, r);
            },
            .div => {
                const l = try of(ev, b.l, x, point, count + 4);
                const r = try of(ev, b.r, x, point, count + 4);
                return div(a, l, r);
            },
            else => {},
        },
        else => {},
    }
    return leaf(ev, f, x, point, count);
}

pub const Limit = union(enum) { finite: Number, infinite, undefined };

/// The exact limit as x → at (a number): from the lowest power of the series.
pub fn limit(ev: *eval.Eval, f: *const Node, x: []const u8, point: Number) Error!?Number {
    const s = trim(ev.a, of(ev, f, x, point, 6) catch return null) catch return null;
    if (s.c.len == 0) return try zero(ev.a); // zero to the order known
    if (s.lo > 0) return try zero(ev.a);
    if (s.lo == 0) return s.c[0];
    return null; // a pole
}

fn power(a: std.mem.Allocator, name: []const u8, p: i32) Error![]const u8 {
    const sup = "⁰¹²³⁴⁵⁶⁷⁸⁹";
    if (p == 1) return name;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, name);
    if (p < 0) try out.appendSlice(a, "⁻");
    var digits: [12]u8 = undefined;
    const s = std.fmt.bufPrint(&digits, "{d}", .{@abs(p)}) catch unreachable;
    for (s) |d| {
        const k: usize = d - '0';
        // each superscript digit is 2 bytes except ¹²³ (2) and ⁰⁴-⁹ (3)
        const starts = [_]usize{ 0, 3, 5, 7, 9, 12, 15, 18, 21, 24 };
        const end = if (k == 9) sup.len else starts[k + 1];
        try out.appendSlice(a, sup[starts[k]..end]);
    }
    return out.items;
}

/// "1 + x + x²/2 + O(x³)" for the series about `point`, in terms of `var_name` (x, or (x − 1)).
pub fn text(a: std.mem.Allocator, s: Series, var_name: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var p = s.lo;
    for (s.c) |c| {
        defer p += 1;
        if (c.isZero()) continue;
        const neg = c.isNegative();
        const mag = if (neg) try num.neg(a, c) else c;
        if (out.items.len == 0) {
            if (neg) try out.appendSlice(a, "−");
        } else try out.appendSlice(a, if (neg) " − " else " + ");
        const coef_text = if (mag.isExact()) (try num.fraction(a, mag)) orelse try num.format(a, mag, .{ .decimals = 12 }) else try num.format(a, mag, .{ .decimals = 12 });
        const is_frac = std.mem.indexOfScalar(u8, coef_text, '/') != null;
        const one = num.isOneNumber(mag);
        if (p == 0) {
            try out.appendSlice(a, coef_text);
        } else if (is_frac) {
            // x²/2, 2x/3
            const slash = std.mem.indexOfScalar(u8, coef_text, '/').?;
            const numer = coef_text[0..slash];
            try out.print(a, "{s}{s}/{s}", .{ if (std.mem.eql(u8, numer, "1")) "" else numer, try power(a, var_name, p), coef_text[slash + 1 ..] });
        } else {
            try out.print(a, "{s}{s}", .{ if (one) "" else coef_text, try power(a, var_name, p) });
        }
    }
    if (out.items.len == 0) try out.appendSlice(a, "0");
    try out.print(a, " + O({s})", .{try power(a, var_name, s.top)});
    return out.items;
}

/// taylor(f, x, a, n): the terms up to x^n about x = a, as text.
pub fn taylorText(ev: *eval.Eval, f: *const Node, x: []const u8, point: Number, n: usize) Error!?[]const u8 {
    const a = ev.a;
    var s = of(ev, f, x, point, n + 1) catch return null;
    if (s.top > @as(i32, @intCast(n)) + 1) {
        s.top = @intCast(n + 1);
        const keep: usize = @intCast(@max(0, s.top - s.lo));
        if (keep < s.c.len) s.c = s.c[0..keep];
    }
    const name = if (point.isZero()) x else blk: {
        const shown = try num.format(a, try num.neg(a, point), .{ .decimals = 10 });
        break :blk if (point.isNegative()) try std.fmt.allocPrint(a, "({s} + {s})", .{ x, shown[1..] }) else try std.fmt.allocPrint(a, "({s} − {s})", .{ x, shown[1..] });
    };
    _ = name;
    const var_name = if (point.isZero()) x else try std.fmt.allocPrint(a, "({s} {s} {s})", .{ x, if (point.isNegative()) "+" else "−", try num.format(a, if (point.isNegative()) try num.neg(a, point) else point, .{ .decimals = 10 }) });
    return try text(a, s, var_name);
}

// ---- tests ---------------------------------------------------------------------------------------

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
        .value => |v| try num.format(a, v, .{ .decimals = 8 }),
        else => "?",
    };
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{source});
        return e;
    };
}

test "taylor series" {
    try run("1 + x + x²/2 + x³/6 + O(x⁴)", "taylor(exp(x), x, 0, 3)");
    try run("x − x³/6 + O(x⁴)", "taylor(sin(x), x, 0, 3)");
    try run("1 − x²/2 + x⁴/24 + O(x⁵)", "taylor(cos(x), x, 0, 4)");
    try run("1 − x + x² − x³ + O(x⁴)", "taylor(1/(1+x), x, 0, 3)");
}

test "exact limits" {
    try run("1", "limit(sin(x)/x, x, 0)");
    try run("0.5", "limit((1 - cos(x))/x^2, x, 0)");
    try run("4", "limit((x^2 - 4)/(x - 2), x, 2)");
    try run("1", "limit((exp(x) - 1)/x, x, 0)");
    try run("-0.16666667", "limit((sin(x) - x)/x^3, x, 0)");
}
