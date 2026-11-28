// SPDX-License-Identifier: GPL-2.0-or-later
//! Regressions, tests and confidence intervals on lists of numbers (as floats).
//!
//!   linreg      y = a·x + b                         [a, b, r²]
//!   quadreg     y = a·x² + b·x + c                  [a, b, c, r²]
//!   expreg      y = a·bˣ        (ln y against x)    [a, b, r²]
//!   powreg      y = a·xᵇ        (ln y against ln x) [a, b, r²]
//!   logreg      y = a + b·ln x                      [a, b, r²]
//!   ttest       one sample against a mean           [t, df, p]   (two-sided)
//!   ttest2      two samples, Welch's test           [t, df, p]
//!   tinterval   confidence interval of the mean     [low, high]
//!   zinterval   the same with a known σ             [low, high]
//!   chisqtest   observed against expected           [χ², df, p]
//!   anova       one-way, two or more groups         [F, df1, df2, p]
//!
//! r² of the transformed fits is the r² of the straight line fitted to the transformed data, as on a
//! graphing calculator.

const std = @import("std");
const functions = @import("functions.zig");

pub const Error = error{ Domain, WrongArguments, OutOfMemory };

pub fn mean(x: []const f64) f64 {
    var s: f64 = 0;
    for (x) |v| s += v;
    return s / @as(f64, @floatFromInt(x.len));
}

/// The sample variance (n − 1).
pub fn variance(x: []const f64) f64 {
    const m = mean(x);
    var s: f64 = 0;
    for (x) |v| s += (v - m) * (v - m);
    return s / @as(f64, @floatFromInt(x.len - 1));
}

/// A line through (x, y): slope, intercept, r².
fn line(x: []const f64, y: []const f64) struct { a: f64, b: f64, r2: f64 } {
    const mx = mean(x);
    const my = mean(y);
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (x, y) |xi, yi| {
        sxy += (xi - mx) * (yi - my);
        sxx += (xi - mx) * (xi - mx);
        syy += (yi - my) * (yi - my);
    }
    const a = sxy / sxx;
    const r2 = if (syy == 0) 1 else sxy * sxy / (sxx * syy);
    return .{ .a = a, .b = my - a * mx, .r2 = r2 };
}

pub fn linreg(x: []const f64, y: []const f64) Error![3]f64 {
    if (x.len != y.len or x.len < 2) return error.Domain;
    const l = line(x, y);
    if (!std.math.isFinite(l.a)) return error.Domain;
    return .{ l.a, l.b, l.r2 };
}

pub fn quadreg(a: std.mem.Allocator, x: []const f64, y: []const f64) Error![4]f64 {
    if (x.len != y.len or x.len < 3) return error.Domain;
    // Normal equations for 1, x, x².
    var s: [5]f64 = @splat(0);
    var t: [3]f64 = @splat(0);
    for (x, y) |xi, yi| {
        var p: f64 = 1;
        for (0..5) |k| {
            s[k] += p;
            p *= xi;
        }
        t[0] += yi;
        t[1] += xi * yi;
        t[2] += xi * xi * yi;
    }
    var m = [3][4]f64{
        .{ s[0], s[1], s[2], t[0] },
        .{ s[1], s[2], s[3], t[1] },
        .{ s[2], s[3], s[4], t[2] },
    };
    for (0..3) |c| {
        var best = c;
        for (c + 1..3) |r| if (@abs(m[r][c]) > @abs(m[best][c])) {
            best = r;
        };
        if (@abs(m[best][c]) < 1e-12) return error.Domain;
        std.mem.swap([4]f64, &m[c], &m[best]);
        for (c + 1..3) |r| {
            const f = m[r][c] / m[c][c];
            for (c..4) |k| m[r][k] -= f * m[c][k];
        }
    }
    var coef: [3]f64 = undefined;
    var i: usize = 3;
    while (i > 0) {
        i -= 1;
        var sum = m[i][3];
        for (i + 1..3) |k| sum -= m[i][k] * coef[k];
        coef[i] = sum / m[i][i];
    }
    // r² = 1 − SSres/SStot
    const my = mean(y);
    var ss_res: f64 = 0;
    var ss_tot: f64 = 0;
    for (x, y) |xi, yi| {
        const f = coef[0] + coef[1] * xi + coef[2] * xi * xi;
        ss_res += (yi - f) * (yi - f);
        ss_tot += (yi - my) * (yi - my);
    }
    _ = a;
    return .{ coef[2], coef[1], coef[0], if (ss_tot == 0) 1 else 1 - ss_res / ss_tot };
}

pub fn expreg(a: std.mem.Allocator, x: []const f64, y: []const f64) Error![3]f64 {
    if (x.len != y.len or x.len < 2) return error.Domain;
    const ly = try a.alloc(f64, y.len);
    for (y, 0..) |v, i| {
        if (v <= 0) return error.Domain;
        ly[i] = @log(v);
    }
    const l = line(x, ly);
    return .{ @exp(l.b), @exp(l.a), l.r2 };
}

pub fn powreg(a: std.mem.Allocator, x: []const f64, y: []const f64) Error![3]f64 {
    if (x.len != y.len or x.len < 2) return error.Domain;
    const lx = try a.alloc(f64, x.len);
    const ly = try a.alloc(f64, y.len);
    for (x, y, 0..) |xv, yv, i| {
        if (xv <= 0 or yv <= 0) return error.Domain;
        lx[i] = @log(xv);
        ly[i] = @log(yv);
    }
    const l = line(lx, ly);
    return .{ @exp(l.b), l.a, l.r2 };
}

pub fn logreg(a: std.mem.Allocator, x: []const f64, y: []const f64) Error![3]f64 {
    if (x.len != y.len or x.len < 2) return error.Domain;
    const lx = try a.alloc(f64, x.len);
    for (x, 0..) |v, i| {
        if (v <= 0) return error.Domain;
        lx[i] = @log(v);
    }
    const l = line(lx, y);
    return .{ l.b, l.a, l.r2 };
}

fn tTwoSided(t: f64, df: f64) f64 {
    return 2 * (1 - functions.cdfT(@abs(t), df, 0, 0));
}

pub fn ttest(x: []const f64, mu: f64) Error![3]f64 {
    if (x.len < 2) return error.Domain;
    const n: f64 = @floatFromInt(x.len);
    const se = @sqrt(variance(x) / n);
    if (se == 0) return error.Domain;
    const t = (mean(x) - mu) / se;
    return .{ t, n - 1, tTwoSided(t, n - 1) };
}

/// Welch's t-test for two samples.
pub fn ttest2(x: []const f64, y: []const f64) Error![3]f64 {
    if (x.len < 2 or y.len < 2) return error.Domain;
    const nx: f64 = @floatFromInt(x.len);
    const ny: f64 = @floatFromInt(y.len);
    const vx = variance(x) / nx;
    const vy = variance(y) / ny;
    if (vx + vy == 0) return error.Domain;
    const t = (mean(x) - mean(y)) / @sqrt(vx + vy);
    const df = (vx + vy) * (vx + vy) / (vx * vx / (nx - 1) + vy * vy / (ny - 1));
    return .{ t, df, tTwoSided(t, df) };
}

pub fn tinterval(x: []const f64, level: f64) Error![2]f64 {
    if (x.len < 2 or level <= 0 or level >= 1) return error.Domain;
    const n: f64 = @floatFromInt(x.len);
    const q = functions.invert(functions.cdfT, 1 - (1 - level) / 2, n - 1, 0, 0, -std.math.inf(f64), std.math.inf(f64));
    const half = q * @sqrt(variance(x) / n);
    return .{ mean(x) - half, mean(x) + half };
}

pub fn zinterval(x: []const f64, sigma: f64, level: f64) Error![2]f64 {
    if (x.len < 1 or sigma <= 0 or level <= 0 or level >= 1) return error.Domain;
    const n: f64 = @floatFromInt(x.len);
    // The normal quantile through erfinv-free inversion of the cdf.
    var lo: f64 = 0;
    var hi: f64 = 40;
    const target = 1 - (1 - level) / 2;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const mid = (lo + hi) / 2;
        const cdf = 0.5 * functions.erfcf(-mid / @sqrt(2.0));
        if (cdf < target) lo = mid else hi = mid;
    }
    const half = (lo + hi) / 2 * sigma / @sqrt(n);
    return .{ mean(x) - half, mean(x) + half };
}

pub fn chisqtest(observed: []const f64, expected: []const f64) Error![3]f64 {
    if (observed.len != expected.len or observed.len < 2) return error.Domain;
    var chi: f64 = 0;
    for (observed, expected) |o, e| {
        if (e <= 0) return error.Domain;
        chi += (o - e) * (o - e) / e;
    }
    const df: f64 = @floatFromInt(observed.len - 1);
    return .{ chi, df, 1 - functions.cdfChi(chi, df, 0, 0) };
}

pub fn anova(groups: []const []const f64) Error![4]f64 {
    if (groups.len < 2) return error.Domain;
    var total_n: f64 = 0;
    var grand: f64 = 0;
    for (groups) |g| {
        if (g.len < 1) return error.Domain;
        total_n += @floatFromInt(g.len);
        for (g) |v| grand += v;
    }
    grand /= total_n;
    var ss_between: f64 = 0;
    var ss_within: f64 = 0;
    for (groups) |g| {
        const m = mean(g);
        ss_between += @as(f64, @floatFromInt(g.len)) * (m - grand) * (m - grand);
        for (g) |v| ss_within += (v - m) * (v - m);
    }
    const df1: f64 = @floatFromInt(groups.len - 1);
    const df2 = total_n - @as(f64, @floatFromInt(groups.len));
    if (df2 <= 0 or ss_within == 0) return error.Domain;
    const f = (ss_between / df1) / (ss_within / df2);
    return .{ f, df1, df2, 1 - functions.cdfF(f, df1, df2, 0) };
}

// ---- tests --------------------------------------------------------------------------------------

fn near(want: f64, got: f64, tol: f64) !void {
    if (@abs(want - got) > tol) {
        std.debug.print("want {d}, got {d}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}

test "regressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = [_]f64{ 1, 2, 3, 4, 5 };
    const y = [_]f64{ 2.2, 4.1, 5.9, 8.2, 9.9 };
    const l = try linreg(&x, &y);
    try near(1.95, l[0], 1e-9);
    try near(0.21, l[1], 1e-9);
    try near(0.9982411, l[2], 1e-6);
    const q = try quadreg(a, &x, &.{ 3, 8, 15, 24, 35 });
    try near(1, q[0], 1e-9);
    try near(2, q[1], 1e-9);
    try near(0, q[2], 1e-9);
    const e = try expreg(a, &x, &.{ 2, 4, 8, 16, 32 });
    try near(1, e[0], 1e-9);
    try near(2, e[1], 1e-9);
    const p = try powreg(a, &x, &.{ 3, 12, 27, 48, 75 });
    try near(3, p[0], 1e-9);
    try near(2, p[1], 1e-9);
}

test "tests and intervals" {
    // Checked by hand and against Qalculate's t distribution: t = 2.84095, df = 5, p = 0.0362059.
    const s = [_]f64{ 5.1, 4.9, 5.6, 5.8, 6.0, 5.5 };
    const t = try ttest(&s, 5);
    try near(2.84095358, t[0], 1e-6);
    try near(5, t[1], 1e-9);
    try near(0.0362059032, t[2], 1e-7);
    const ci = try tinterval(&s, 0.95);
    try near(5.0459985, ci[0], 1e-6);
    try near(5.9206681, ci[1], 1e-6);
    const c = try chisqtest(&.{ 20, 30, 50 }, &.{ 25, 25, 50 });
    try near(2, c[0], 1e-9);
    try near(0.3678794, c[2], 1e-6);
    const f = try anova(&.{ &.{ 4, 5, 6 }, &.{ 7, 8, 9 }, &.{ 10, 11, 12 } });
    try near(27, f[0], 1e-9);
    try near(0.001, f[3], 1e-6);
}
