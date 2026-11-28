// SPDX-License-Identifier: GPL-2.0-or-later
//! Linear algebra on real matrices of exact numbers: the characteristic polynomial, eigenvalues
//! and eigenvectors, the null space, LU, QR and Cholesky factors.
//!
//! The characteristic polynomial is worked out exactly (Faddeev–LeVerrier), so eigenvalues that are
//! rational, square roots or complex pairs come out in exact form through the polynomial solver; the
//! eigenvectors of a rational eigenvalue are exact too, the others are worked out with floats.

const std = @import("std");
const num = @import("num.zig");
const algebra = @import("algebra.zig");
const symbolic = @import("symbolic.zig");
const simplify = @import("simplify.zig");
const bigreal = @import("bigreal.zig");
const eval = @import("eval.zig");
const Number = num.Number;

pub const Error = eval.Error;

/// A real matrix, row by row.
pub const M = struct {
    rows: usize,
    cols: usize,
    v: []Number,

    pub fn at(self: M, r: usize, c: usize) Number {
        return self.v[r * self.cols + c];
    }
    pub fn set(self: M, r: usize, c: usize, x: Number) void {
        self.v[r * self.cols + c] = x;
    }
};

pub fn zeros(a: std.mem.Allocator, rows: usize, cols: usize) Error!M {
    const v = try a.alloc(Number, rows * cols);
    for (v) |*x| x.* = try num.fromInt(a, 0);
    return .{ .rows = rows, .cols = cols, .v = v };
}

pub fn identity(a: std.mem.Allocator, n: usize) Error!M {
    const m = try zeros(a, n, n);
    for (0..n) |i| m.set(i, i, try num.fromInt(a, 1));
    return m;
}

fn mul(a: std.mem.Allocator, x: M, y: M) Error!M {
    const out = try zeros(a, x.rows, y.cols);
    for (0..x.rows) |i| for (0..y.cols) |j| {
        var sum = try num.fromInt(a, 0);
        for (0..x.cols) |k| sum = try num.add(a, sum, try num.mul(a, x.at(i, k), y.at(k, j)));
        out.set(i, j, sum);
    };
    return out;
}

fn trace(a: std.mem.Allocator, m: M) Error!Number {
    var t = try num.fromInt(a, 0);
    for (0..m.rows) |i| t = try num.add(a, t, m.at(i, i));
    return t;
}

/// The coefficients of det(λI − A), lowest power first (so the last is 1).
pub fn charPoly(a: std.mem.Allocator, m: M) Error![]Number {
    if (m.rows != m.cols) return error.Domain;
    const n = m.rows;
    const c = try a.alloc(Number, n + 1);
    c[n] = try num.fromInt(a, 1);
    var mk = try zeros(a, n, n);
    var k: usize = 1;
    while (k <= n) : (k += 1) {
        // M_k = A·M_{k−1} + c_{n−k+1}·I
        mk = try mul(a, m, mk);
        for (0..n) |i| mk.set(i, i, try num.add(a, mk.at(i, i), c[n - k + 1]));
        const am = try mul(a, m, mk);
        c[n - k] = try num.div(a, try num.neg(a, try trace(a, am)), try num.fromInt(a, @as(i64, @intCast(k))));
    }
    return c;
}

pub const Eigen = struct { re: Number, im: Number, exact_real: bool, rational: ?Number };

/// The eigenvalues, with their repeats, real ones first in increasing order.
pub fn eigenvalues(a: std.mem.Allocator, m: M) Error![]Eigen {
    const coefs = try charPoly(a, m);
    var out: std.ArrayList(Eigen) = .empty;
    const zero = try num.fromInt(a, 0);
    // Exact roots, each as often as it occurs.
    if (try algebra.solveDense(a, coefs)) |sol| {
        const fac = try algebra.factorDense(a, coefs);
        for (sol.real) |r| {
            const value = try symbolic.toNumber(a, r.re);
            const rational: ?Number = if (r.re.isRational()) (if (r.re.terms.len == 0) zero else r.re.terms[0].c) else null;
            const mult = multiplicityOf(a, fac, rational) catch 1;
            for (0..mult) |_| try out.append(a, .{ .re = value, .im = zero, .exact_real = true, .rational = rational });
        }
        for (sol.complex) |r| {
            try out.append(a, .{ .re = try symbolic.toNumber(a, r.re), .im = try symbolic.toNumber(a, r.im), .exact_real = false, .rational = null });
        }
        if (out.items.len == m.rows) return out.items;
        out.clearRetainingCapacity();
    }
    // Otherwise the roots as floats.
    const f = try a.alloc(f64, coefs.len);
    for (coefs, 0..) |x, i| f[i] = x.toFloat();
    const roots = simplify.complexRoots(a, f) catch return error.Domain;
    for (roots) |z| {
        const re = if (@abs(z.re) < 1e-12 * @max(1, z.magnitude())) 0 else z.re;
        const im = if (@abs(z.im) < 1e-12 * @max(1, z.magnitude())) 0 else z.im;
        try out.append(a, .{ .re = try num.fromFloat(re), .im = try num.fromFloat(im), .exact_real = false, .rational = null });
    }
    std.mem.sort(Eigen, out.items, {}, struct {
        fn lt(_: void, x: Eigen, y: Eigen) bool {
            if ((x.im.toFloat() == 0) != (y.im.toFloat() == 0)) return x.im.toFloat() == 0;
            return x.re.toFloat() < y.re.toFloat();
        }
    }.lt);
    return out.items;
}

/// How many times the rational root occurs among the factors (the factor's multiplicity).
fn multiplicityOf(a: std.mem.Allocator, fac: algebra.Factored, rational: ?Number) !usize {
    _ = a;
    const r = rational orelse return 1;
    for (fac.factors) |f| {
        if (algebra.degree(f.coefs) != 1) continue;
        // f = c0 + c1 x: its root is −c0/c1.
        const root = num.div(std.heap.page_allocator, num.neg(std.heap.page_allocator, f.coefs[0]) catch return 1, f.coefs[1]) catch return 1;
        if ((num.order(std.heap.page_allocator, root, r) catch return 1) == .eq) return f.mult;
    }
    return 1;
}

/// A reduced row echelon form, with the columns of the pivots.
fn rref(a: std.mem.Allocator, m: M) Error!struct { m: M, pivots: []usize } {
    const out = try zeros(a, m.rows, m.cols);
    @memcpy(out.v, m.v);
    var pivots: std.ArrayList(usize) = .empty;
    var row: usize = 0;
    var col: usize = 0;
    while (row < out.rows and col < out.cols) : (col += 1) {
        var p: ?usize = null;
        for (row..out.rows) |r| if (!out.at(r, col).isZero()) {
            p = r;
            break;
        };
        const pr = p orelse continue;
        if (pr != row) for (0..out.cols) |c| {
            const tmp = out.at(row, c);
            out.set(row, c, out.at(pr, c));
            out.set(pr, c, tmp);
        };
        const pivot = out.at(row, col);
        for (0..out.cols) |c| out.set(row, c, try num.div(a, out.at(row, c), pivot));
        for (0..out.rows) |r| {
            if (r == row) continue;
            const factor = out.at(r, col);
            if (factor.isZero()) continue;
            for (0..out.cols) |c| out.set(r, c, try num.sub(a, out.at(r, c), try num.mul(a, factor, out.at(row, c))));
        }
        try pivots.append(a, col);
        row += 1;
    }
    return .{ .m = out, .pivots = pivots.items };
}

/// The vectors that A sends to zero, as the columns of a matrix (null if only zero does).
pub fn nullspace(a: std.mem.Allocator, m: M) Error!?M {
    const r = try rref(a, m);
    const free = try a.alloc(bool, m.cols);
    @memset(free, true);
    for (r.pivots) |p| free[p] = false;
    var count: usize = 0;
    for (free) |f| if (f) {
        count += 1;
    };
    if (count == 0) return null;
    const out = try zeros(a, m.cols, count);
    var k: usize = 0;
    for (0..m.cols) |c| {
        if (!free[c]) continue;
        out.set(c, k, try num.fromInt(a, 1));
        for (r.pivots, 0..) |pc, row| out.set(pc, k, try num.neg(a, r.m.at(row, c)));
        k += 1;
    }
    return out;
}

/// An eigenvector for each eigenvalue (columns); exact for a rational eigenvalue, with floats otherwise.
pub fn eigenvectors(a: std.mem.Allocator, m: M) Error!M {
    const values = try eigenvalues(a, m);
    const out = try zeros(a, m.rows, values.len);
    for (values, 0..) |ev, j| {
        if (ev.im.toFloat() != 0) return error.Domain;
        var shifted = try zeros(a, m.rows, m.cols);
        @memcpy(shifted.v, m.v);
        const lambda = ev.rational orelse ev.re;
        // For a repeated eigenvalue each copy takes the next vector of its eigenspace.
        var copy_index: usize = 0;
        for (values[0..j]) |earlier| if (earlier.im.toFloat() == 0 and earlier.re.toFloat() == ev.re.toFloat()) {
            copy_index += 1;
        };
        for (0..m.rows) |i| shifted.set(i, i, try num.sub(a, shifted.at(i, i), lambda));
        var vec: ?M = null;
        if (ev.rational != null) vec = try nullspace(a, shifted);
        if (vec == null) vec = try numericNullspace(a, shifted);
        const space = vec orelse return error.Domain;
        const pick = @min(copy_index, space.cols - 1);
        for (0..m.rows) |i| out.set(i, j, space.at(i, pick));
    }
    return out;
}

/// The null vector of a singular matrix by Gaussian elimination in floats (for irrational eigenvalues).
fn numericNullspace(a: std.mem.Allocator, m: M) Error!?M {
    const n = m.rows;
    const g = try a.alloc(f64, n * n);
    for (0..n) |i| for (0..n) |j| {
        g[i * n + j] = m.at(i, j).toFloat();
    };
    var pivot_col = try a.alloc(?usize, n);
    @memset(pivot_col, null);
    var row: usize = 0;
    var col: usize = 0;
    const scale = blk: {
        var big: f64 = 1;
        for (g) |x| big = @max(big, @abs(x));
        break :blk big;
    };
    var free_col: ?usize = null;
    while (col < n) : (col += 1) {
        var best: usize = row;
        var bv: f64 = 0;
        if (row < n) for (row..n) |r| if (@abs(g[r * n + col]) > bv) {
            bv = @abs(g[r * n + col]);
            best = r;
        };
        if (row >= n or bv < 1e-8 * scale) {
            if (free_col == null) free_col = col;
            continue;
        }
        if (best != row) for (0..n) |c| std.mem.swap(f64, &g[row * n + c], &g[best * n + c]);
        const pv = g[row * n + col];
        for (0..n) |c| g[row * n + c] /= pv;
        for (0..n) |r| {
            if (r == row) continue;
            const f = g[r * n + col];
            if (f == 0) continue;
            for (0..n) |c| g[r * n + c] -= f * g[row * n + c];
        }
        pivot_col[row] = col;
        row += 1;
    }
    const fc = free_col orelse return null;
    const out = try zeros(a, n, 1);
    out.set(fc, 0, try num.fromInt(a, 1));
    for (0..n) |r| if (pivot_col[r]) |pc| out.set(pc, 0, try num.fromFloat(-g[r * n + fc]));
    return out;
}

/// L and U with A = L·U (no row swaps; error when a pivot is zero).
pub fn lu(a: std.mem.Allocator, m: M) Error!struct { l: M, u: M } {
    if (m.rows != m.cols) return error.Domain;
    const n = m.rows;
    const l = try identity(a, n);
    const u = try zeros(a, n, n);
    @memcpy(u.v, m.v);
    for (0..n) |k| {
        const pivot = u.at(k, k);
        if (pivot.isZero()) return error.Domain;
        for (k + 1..n) |i| {
            const f = try num.div(a, u.at(i, k), pivot);
            l.set(i, k, f);
            for (k..n) |j| u.set(i, j, try num.sub(a, u.at(i, j), try num.mul(a, f, u.at(k, j))));
        }
    }
    return .{ .l = l, .u = u };
}

/// Q (orthonormal columns) and R (upper triangular) with A = Q·R, by Gram–Schmidt in floats.
pub fn qr(a: std.mem.Allocator, m: M) Error!struct { q: M, r: M } {
    const rows = m.rows;
    const cols = m.cols;
    const q = try zeros(a, rows, cols);
    const r = try zeros(a, cols, cols);
    const col = try a.alloc(f64, rows);
    for (0..cols) |j| {
        for (0..rows) |i| col[i] = m.at(i, j).toFloat();
        for (0..j) |k| {
            var dot: f64 = 0;
            for (0..rows) |i| dot += q.at(i, k).toFloat() * m.at(i, j).toFloat();
            r.set(k, j, try num.fromFloat(dot));
            for (0..rows) |i| col[i] -= dot * q.at(i, k).toFloat();
        }
        var norm: f64 = 0;
        for (col) |x| norm += x * x;
        norm = @sqrt(norm);
        if (norm < 1e-12) return error.Domain;
        r.set(j, j, try num.fromFloat(norm));
        for (0..rows) |i| q.set(i, j, try num.fromFloat(col[i] / norm));
    }
    return .{ .q = q, .r = r };
}

/// L with A = L·Lᵀ for a symmetric positive-definite A.
pub fn cholesky(a: std.mem.Allocator, m: M) Error!M {
    if (m.rows != m.cols) return error.Domain;
    const n = m.rows;
    const l = try zeros(a, n, n);
    for (0..n) |i| for (0..i + 1) |j| {
        var sum = m.at(i, j);
        for (0..j) |k| sum = try num.sub(a, sum, try num.mul(a, l.at(i, k), l.at(j, k)));
        if (i == j) {
            if (sum.isNegative() or sum.isZero()) return error.Domain;
            const root = (try num.root(a, sum, 2)) orelse num.fromReal(try bigreal.sqrt(a, try num.toReal(a, sum)));
            l.set(i, j, root);
        } else {
            l.set(i, j, try num.div(a, sum, l.at(j, j)));
        }
    };
    return l;
}

// ---- tests ---------------------------------------------------------------------------------------

fn fromInts(a: std.mem.Allocator, rows: usize, cols: usize, vals: []const i64) !M {
    const m = try zeros(a, rows, cols);
    for (vals, 0..) |v, i| m.v[i] = try num.fromInt(a, v);
    return m;
}

fn showCoefs(a: std.mem.Allocator, c: []const Number) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c, 0..) |x, i| {
        if (i > 0) try out.appendSlice(a, ",");
        try out.appendSlice(a, try num.format(a, x, .{}));
    }
    return out.items;
}

test "characteristic polynomial and eigenvalues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try fromInts(a, 2, 2, &.{ 2, 1, 1, 2 });
    try std.testing.expectEqualStrings("3,-4,1", try showCoefs(a, try charPoly(a, m)));
    const ev = try eigenvalues(a, m);
    try std.testing.expectEqual(@as(usize, 2), ev.len);
    try std.testing.expectEqualStrings("1", try num.format(a, ev[0].re, .{}));
    try std.testing.expectEqualStrings("3", try num.format(a, ev[1].re, .{}));
    // A rotation: complex eigenvalues ±i.
    const rot = try fromInts(a, 2, 2, &.{ 0, -1, 1, 0 });
    const ev2 = try eigenvalues(a, rot);
    try std.testing.expectEqual(@as(usize, 2), ev2.len);
    try std.testing.expectEqualStrings("1", try num.format(a, try absOf(a, ev2[0].im), .{}));
}

fn absOf(a: std.mem.Allocator, x: Number) !Number {
    return if (x.isNegative()) num.neg(a, x) else x;
}

test "eigenvectors, null space, LU, Cholesky" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try fromInts(a, 2, 2, &.{ 2, 1, 1, 2 });
    const vecs = try eigenvectors(a, m);
    // (−1, 1) for 1 and (1, 1) for 3.
    try std.testing.expectEqualStrings("-1", try num.format(a, vecs.at(0, 0), .{}));
    try std.testing.expectEqualStrings("1", try num.format(a, vecs.at(1, 0), .{}));
    try std.testing.expectEqualStrings("1", try num.format(a, vecs.at(1, 1), .{}));
    const sing = try fromInts(a, 2, 2, &.{ 1, 2, 2, 4 });
    const ns = (try nullspace(a, sing)).?;
    try std.testing.expectEqualStrings("-2", try num.format(a, ns.at(0, 0), .{}));
    const f = try lu(a, try fromInts(a, 2, 2, &.{ 4, 3, 6, 3 }));
    try std.testing.expectEqualStrings("3/2", (try num.fraction(a, f.l.at(1, 0))).?);
    try std.testing.expectEqualStrings("-3/2", (try num.fraction(a, f.u.at(1, 1))).?);
    const ch = try cholesky(a, try fromInts(a, 2, 2, &.{ 4, 2, 2, 5 }));
    try std.testing.expectEqualStrings("2", try num.format(a, ch.at(0, 0), .{}));
    try std.testing.expectEqualStrings("1", try num.format(a, ch.at(1, 0), .{}));
    try std.testing.expectEqualStrings("2", try num.format(a, ch.at(1, 1), .{}));
}
