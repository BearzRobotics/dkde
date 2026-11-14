//! Values the plain evaluator cannot hold: complex numbers (exact while
//! they stay Gaussian rationals: i·i is −1, (1+i)² is 2i), vectors and
//! matrices, and the list statistics that work on them. An entry goes
//! through here when it uses a matrix, `i`, or a function that only makes
//! sense for them; a result the plain evaluator refuses (sqrt(−4), ln(−1))
//! is tried here too.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const quantity = @import("quantity.zig");
const Number = num.Number;
const Error = eval.Error;
const Node = eval.Node;
const cplx = std.math.Complex(f64);
const Big = std.math.big.int.Managed;

// ---- values ---------------------------------------------------------------------

/// re + im·i.
pub const C = struct {
    re: Number,
    im: Number,

    pub fn real(re: Number, a: std.mem.Allocator) Error!C {
        return .{ .re = re, .im = try num.fromInt(a, 0) };
    }
    pub fn isReal(self: C) bool {
        return self.im.isZero();
    }
};

pub const Matrix = struct {
    rows: usize,
    cols: usize,
    items: []C,

    fn at(self: Matrix, r: usize, c: usize) C {
        return self.items[r * self.cols + c];
    }
};

pub const Value = union(enum) {
    scalar: C,
    matrix: Matrix,
    /// A real amount with units (5 ft, 60 km/h).
    quantity: quantity.Quantity,
};

const max_cells = 250_000;

// ---- complex arithmetic ----------------------------------------------------------

fn zero(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 0);
}

fn cadd(a: std.mem.Allocator, x: C, y: C) Error!C {
    return .{ .re = try num.add(a, x.re, y.re), .im = try num.add(a, x.im, y.im) };
}

fn csub(a: std.mem.Allocator, x: C, y: C) Error!C {
    return .{ .re = try num.sub(a, x.re, y.re), .im = try num.sub(a, x.im, y.im) };
}

fn cneg(a: std.mem.Allocator, x: C) Error!C {
    return .{ .re = try num.neg(a, x.re), .im = try num.neg(a, x.im) };
}

fn cmul(a: std.mem.Allocator, x: C, y: C) Error!C {
    if (x.isReal() and y.isReal()) return C.real(try num.mul(a, x.re, y.re), a);
    return .{
        .re = try num.sub(a, try num.mul(a, x.re, y.re), try num.mul(a, x.im, y.im)),
        .im = try num.add(a, try num.mul(a, x.re, y.im), try num.mul(a, x.im, y.re)),
    };
}

fn cdiv(a: std.mem.Allocator, x: C, y: C) Error!C {
    if (y.isReal()) {
        if (y.re.isZero()) return error.DivisionByZero;
        return .{ .re = try num.div(a, x.re, y.re), .im = try num.div(a, x.im, y.re) };
    }
    const d = try num.add(a, try num.mul(a, y.re, y.re), try num.mul(a, y.im, y.im));
    const n = try cmul(a, x, .{ .re = y.re, .im = try num.neg(a, y.im) });
    return .{ .re = try num.div(a, n.re, d), .im = try num.div(a, n.im, d) };
}

fn conj(a: std.mem.Allocator, x: C) Error!C {
    return .{ .re = x.re, .im = try num.neg(a, x.im) };
}

fn toFloatC(x: C) cplx {
    return cplx.init(x.re.toFloat() + 0.0, if (x.im.isZero()) 0.0 else x.im.toFloat());
}

/// A float complex back to a value, dropping rounding dust (1e-16 against 1).
fn fromFloatC(z: cplx) Error!C {
    var re = z.re;
    var im = z.im;
    if (!std.math.isFinite(re) or !std.math.isFinite(im)) return error.Domain;
    const big = @max(@abs(re), @abs(im));
    if (@abs(im) < big * 1e-15) im = 0;
    if (@abs(re) < big * 1e-15) re = 0;
    return .{ .re = .{ .approx = re }, .im = .{ .approx = im } };
}

fn isNeg(x: Number) bool {
    return x.isNegative();
}

/// |z|, exact when the sum of squares is a perfect square.
fn cabs(a: std.mem.Allocator, x: C) Error!Number {
    if (x.isReal()) return if (isNeg(x.re)) num.neg(a, x.re) else x.re;
    const n2 = try num.add(a, try num.mul(a, x.re, x.re), try num.mul(a, x.im, x.im));
    if (n2.isExact()) if (try num.root(a, n2, 2)) |r| return r;
    return num.fromFloat(@sqrt(n2.toFloat()));
}

fn csqrt(a: std.mem.Allocator, x: C) Error!C {
    if (x.isReal()) {
        if (!isNeg(x.re)) {
            if (x.re.isExact()) {
                if (try num.root(a, x.re, 2)) |r| return C.real(r, a);
            }
            return C.real(try num.fromFloat(@sqrt(x.re.toFloat())), a);
        }
        const m = try num.neg(a, x.re);
        const r = if (m.isExact()) (try num.root(a, m, 2)) orelse try num.fromFloat(@sqrt(m.toFloat())) else try num.fromFloat(@sqrt(m.toFloat()));
        return .{ .re = try zero(a), .im = r };
    }
    return fromFloatC(std.math.complex.sqrt(toFloatC(x)));
}

fn cpowInt(a: std.mem.Allocator, x: C, n: i64) Error!C {
    var e: u64 = @abs(n);
    var base = x;
    var acc = try C.real(try num.fromInt(a, 1), a);
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) acc = try cmul(a, acc, base);
        if (e > 1) base = try cmul(a, base, base);
    }
    if (n < 0) return cdiv(a, try C.real(try num.fromInt(a, 1), a), acc);
    return acc;
}

fn cpow(a: std.mem.Allocator, x: C, y: C) Error!C {
    if (y.isReal() and y.re.isExact()) {
        if (num.intValue(y.re)) |n| {
            if (@abs(n) <= 100_000) {
                if (x.isReal()) return C.real(try num.pow(a, x.re, y.re), a);
                return cpowInt(a, x, n);
            }
        }
    }
    if (x.isReal() and y.isReal() and !(isNeg(x.re) and !y.re.isInteger())) {
        // A real base and exponent: the real power when it exists.
        if (num.pow(a, x.re, y.re)) |r| return C.real(r, a) else |e| if (e != error.Domain) return e;
    }
    if (x.re.isZero() and x.im.isZero()) {
        if (y.isReal() and !isNeg(y.re)) return C.real(try zero(a), a);
        return error.DivisionByZero;
    }
    return fromFloatC(std.math.complex.pow(toFloatC(x), toFloatC(y)));
}

// ---- matrices -------------------------------------------------------------------

fn newMatrix(a: std.mem.Allocator, rows: usize, cols: usize) Error!Matrix {
    if (rows == 0 or cols == 0 or rows * cols > max_cells) return error.TooLarge;
    return .{ .rows = rows, .cols = cols, .items = try a.alloc(C, rows * cols) };
}

fn identity(a: std.mem.Allocator, n: usize) Error!Matrix {
    const m = try newMatrix(a, n, n);
    for (0..n) |r| for (0..n) |c| {
        m.items[r * n + c] = try C.real(try num.fromInt(a, @as(i64, if (r == c) 1 else 0)), a);
    };
    return m;
}

fn transpose(a: std.mem.Allocator, m: Matrix) Error!Matrix {
    const t = try newMatrix(a, m.cols, m.rows);
    for (0..m.rows) |r| for (0..m.cols) |c| {
        t.items[c * m.rows + r] = m.at(r, c);
    };
    return t;
}

fn mapMatrix(a: std.mem.Allocator, m: Matrix, comptime f: fn (std.mem.Allocator, C) Error!C) Error!Matrix {
    const out = try newMatrix(a, m.rows, m.cols);
    for (m.items, 0..) |x, i| out.items[i] = try f(a, x);
    return out;
}

fn matmul(a: std.mem.Allocator, x: Matrix, y: Matrix) Error!Matrix {
    if (x.cols != y.rows) return error.Domain;
    const out = try newMatrix(a, x.rows, y.cols);
    for (0..x.rows) |r| for (0..y.cols) |c| {
        var acc = try C.real(try zero(a), a);
        for (0..x.cols) |k| acc = try cadd(a, acc, try cmul(a, x.at(r, k), y.at(k, c)));
        out.items[r * y.cols + c] = acc;
    };
    return out;
}

/// Is `x` zero for elimination: exactly, or negligible beside `scale`.
fn negligible(x: C, scale: f64) bool {
    if (x.re.isExact() and x.im.isExact()) return x.re.isZero() and x.im.isZero();
    return @max(@abs(x.re.toFloat()), @abs(x.im.toFloat())) <= scale * 1e-12;
}

fn magnitude(x: C) f64 {
    return @max(@abs(x.re.toFloat()), @abs(x.im.toFloat()));
}

/// Gauss-Jordan elimination of a copy of `m` (columns up to `pivot_cols`
/// are pivoted; the rest ride along). Rank, the product of pivots (for the
/// determinant when square) and the reduced matrix.
fn eliminate(a: std.mem.Allocator, m: Matrix, pivot_cols: usize, reduce_above: bool) Error!struct { m: Matrix, rank: usize, det: C } {
    const w = try newMatrix(a, m.rows, m.cols);
    @memcpy(w.items, m.items);
    var scale: f64 = 0;
    for (w.items) |x| scale = @max(scale, magnitude(x));
    var dt = try C.real(try num.fromInt(a, 1), a);
    var row: usize = 0;
    var col: usize = 0;
    while (col < pivot_cols and row < w.rows) : (col += 1) {
        // The best pivot at or below `row`.
        var best: ?usize = null;
        var best_mag: f64 = -1;
        for (row..w.rows) |r| {
            const x = w.items[r * w.cols + col];
            if (negligible(x, scale)) continue;
            const mg = magnitude(x);
            if (x.re.isExact() and x.im.isExact()) {
                if (best == null) best = r;
                break;
            }
            if (mg > best_mag) {
                best_mag = mg;
                best = r;
            }
        }
        const p = best orelse {
            dt = try C.real(try zero(a), a);
            continue;
        };
        if (p != row) {
            for (0..w.cols) |c| std.mem.swap(C, &w.items[p * w.cols + c], &w.items[row * w.cols + c]);
            dt = try cneg(a, dt);
        }
        const pv = w.items[row * w.cols + col];
        dt = try cmul(a, dt, pv);
        for (0..w.cols) |c| w.items[row * w.cols + c] = try cdiv(a, w.items[row * w.cols + c], pv);
        const start: usize = if (reduce_above) 0 else row + 1;
        for (start..w.rows) |r| {
            if (r == row) continue;
            const f = w.items[r * w.cols + col];
            if (f.re.isZero() and f.im.isZero()) continue;
            for (0..w.cols) |c| {
                w.items[r * w.cols + c] = try csub(a, w.items[r * w.cols + c], try cmul(a, f, w.items[row * w.cols + c]));
            }
        }
        row += 1;
    }
    return .{ .m = w, .rank = row, .det = dt };
}

fn det(a: std.mem.Allocator, m: Matrix) Error!C {
    if (m.rows != m.cols) return error.Domain;
    const e = try eliminate(a, m, m.cols, false);
    if (e.rank < m.rows) return C.real(try zero(a), a);
    return e.det;
}

fn inverse(a: std.mem.Allocator, m: Matrix) Error!Matrix {
    if (m.rows != m.cols) return error.Domain;
    const n = m.rows;
    const aug = try newMatrix(a, n, 2 * n);
    const id = try identity(a, n);
    for (0..n) |r| for (0..n) |c| {
        aug.items[r * 2 * n + c] = m.at(r, c);
        aug.items[r * 2 * n + n + c] = id.at(r, c);
    };
    const e = try eliminate(a, aug, n, true);
    if (e.rank < n) return error.Domain; // singular
    const out = try newMatrix(a, n, n);
    for (0..n) |r| for (0..n) |c| {
        out.items[r * n + c] = e.m.items[r * 2 * n + n + c];
    };
    return out;
}

fn minorOf(a: std.mem.Allocator, m: Matrix, skip_r: usize, skip_c: usize) Error!Matrix {
    const out = try newMatrix(a, m.rows - 1, m.cols - 1);
    var k: usize = 0;
    for (0..m.rows) |r| {
        if (r == skip_r) continue;
        for (0..m.cols) |c| {
            if (c == skip_c) continue;
            out.items[k] = m.at(r, c);
            k += 1;
        }
    }
    return out;
}

fn cofactor(a: std.mem.Allocator, m: Matrix, r: usize, c: usize) Error!C {
    if (m.rows != m.cols or m.rows < 2) return error.Domain;
    const d = try det(a, try minorOf(a, m, r, c));
    return if ((r + c) % 2 == 1) cneg(a, d) else d;
}

fn permanent(a: std.mem.Allocator, m: Matrix) Error!C {
    if (m.rows != m.cols or m.rows > 10) return error.Domain;
    const n = m.rows;
    // Ryser's formula would be faster; permutations are enough up to 10.
    var perm: [10]usize = undefined;
    for (0..n) |i| perm[i] = i;
    var tot = try C.real(try zero(a), a);
    while (true) {
        var term = try C.real(try num.fromInt(a, 1), a);
        for (0..n) |i| term = try cmul(a, term, m.at(i, perm[i]));
        tot = try cadd(a, tot, term);
        // Next permutation.
        var i: usize = n;
        while (i > 1 and perm[i - 2] >= perm[i - 1]) i -= 1;
        if (i <= 1) break;
        var j: usize = n;
        while (perm[j - 1] <= perm[i - 2]) j -= 1;
        std.mem.swap(usize, &perm[i - 2], &perm[j - 1]);
        std.mem.reverse(usize, perm[i - 1 .. n]);
    }
    return tot;
}

// ---- real lists ---------------------------------------------------------------------

fn lessNum(a: std.mem.Allocator, x: Number, y: Number) bool {
    return (num.order(a, x, y) catch .eq) == .lt;
}

fn sortNumbers(a: std.mem.Allocator, xs: []Number) void {
    const Ctx = struct { a: std.mem.Allocator };
    std.mem.sort(Number, xs, Ctx{ .a = a }, struct {
        fn less(c: Ctx, x: Number, y: Number) bool {
            return lessNum(c.a, x, y);
        }
    }.less);
}

fn nInt(a: std.mem.Allocator, n: usize) Error!Number {
    return num.fromInt(a, @as(i64, @intCast(n)));
}

fn total(a: std.mem.Allocator, xs: []const Number) Error!Number {
    var t = try zero(a);
    for (xs) |x| t = try num.add(a, t, x);
    return t;
}

fn meanOf(a: std.mem.Allocator, xs: []const Number) Error!Number {
    if (xs.len == 0) return error.WrongArguments;
    return num.div(a, try total(a, xs), try nInt(a, xs.len));
}

fn sqrtNumber(a: std.mem.Allocator, x: Number) Error!Number {
    if (isNeg(x)) return error.Domain;
    if (x.isExact()) if (try num.root(a, x, 2)) |r| return r;
    return num.fromFloat(@sqrt(x.toFloat()));
}

fn variance(a: std.mem.Allocator, xs: []const Number, sample: bool) Error!Number {
    if (xs.len < (if (sample) @as(usize, 2) else 1)) return error.WrongArguments;
    const m = try meanOf(a, xs);
    var sq = try zero(a);
    for (xs) |x| {
        const d = try num.sub(a, x, m);
        sq = try num.add(a, sq, try num.mul(a, d, d));
    }
    return num.div(a, sq, try nInt(a, if (sample) xs.len - 1 else xs.len));
}

/// Hyndman and Fan's nine definitions of a percentile; 7 is the common one.
fn percentile(a: std.mem.Allocator, sorted: []const Number, p: Number, method: i64) Error!Number {
    const n = sorted.len;
    if (n == 0) return error.WrongArguments;
    const pf = try num.div(a, p, try num.fromInt(a, 100));
    if (isNeg(pf) or (try num.order(a, pf, try num.fromInt(a, 1))) == .gt) return error.Domain;
    const nn = try nInt(a, n);
    const one = try num.fromInt(a, 1);
    const half = try num.div(a, one, try num.fromInt(a, 2));
    // h is the 1-based position (possibly fractional); methods 1-3 are discontinuous.
    var h: Number = undefined;
    switch (method) {
        1, 2, 3 => {
            const np = try num.mul(a, nn, pf);
            const fl = try num.floor(a, np);
            const g = try num.sub(a, np, fl);
            const gz = g.isZero();
            const k = fl;
            const pick = struct {
                fn at(xs: []const Number, kk: Number) Number {
                    const i = num.intValue(kk) orelse 0;
                    const j: usize = @intCast(std.math.clamp(i, 1, @as(i64, @intCast(xs.len))));
                    return xs[j - 1];
                }
            };
            if (method == 1) {
                return if (gz) pick.at(sorted, k) else pick.at(sorted, try num.add(a, k, one));
            }
            if (method == 2) {
                if (gz) return num.div(a, try num.add(a, pick.at(sorted, k), pick.at(sorted, try num.add(a, k, one))), try num.fromInt(a, 2));
                return pick.at(sorted, try num.add(a, k, one));
            }
            // 3: nearest even order statistic (Hyndman and Fan's m = -1/2).
            const np2 = try num.sub(a, np, half);
            const j2 = try num.floor(a, np2);
            const g2 = try num.sub(a, np2, j2);
            const ji = num.intValue(j2) orelse 0;
            if (g2.isZero() and @mod(ji, 2) == 0) return pick.at(sorted, j2);
            return pick.at(sorted, try num.add(a, j2, one));
        },
        4 => h = try num.mul(a, nn, pf),
        5 => h = try num.add(a, try num.mul(a, nn, pf), half),
        6 => h = try num.mul(a, try num.add(a, nn, one), pf),
        7 => h = try num.add(a, try num.mul(a, try num.sub(a, nn, one), pf), one),
        8 => {
            const third = try num.div(a, one, try num.fromInt(a, 3));
            h = try num.add(a, try num.mul(a, try num.add(a, nn, third), pf), third);
        },
        9 => {
            const q = try num.div(a, try num.fromInt(a, 3), try num.fromInt(a, 8));
            h = try num.add(a, try num.mul(a, try num.add(a, nn, try num.div(a, one, try num.fromInt(a, 4))), pf), q);
        },
        else => return error.Domain,
    }
    const fl = try num.floor(a, h);
    const frac = try num.sub(a, h, fl);
    const i = num.intValue(fl) orelse return error.Domain;
    const lo: usize = @intCast(std.math.clamp(i, 1, @as(i64, @intCast(n))));
    const hi: usize = @intCast(std.math.clamp(i + 1, 1, @as(i64, @intCast(n))));
    const x0 = sorted[lo - 1];
    const x1 = sorted[hi - 1];
    return num.add(a, x0, try num.mul(a, frac, try num.sub(a, x1, x0)));
}

// ---- formatting ---------------------------------------------------------------------

fn absNumber(a: std.mem.Allocator, x: Number) Error!Number {
    return if (isNeg(x)) num.neg(a, x) else x;
}

pub fn formatC(a: std.mem.Allocator, x: C, style: num.Style) Error![]u8 {
    if (x.isReal()) return num.format(a, x.re, style);
    const im_abs = try absNumber(a, x.im);
    const im_text = try num.format(a, im_abs, style);
    const im_part = if (std.mem.eql(u8, im_text, "1")) "" else im_text;
    if (x.re.isZero()) return std.fmt.allocPrint(a, "{s}{s}i", .{ if (isNeg(x.im)) "−" else "", im_part });
    const re_text = try num.format(a, x.re, style);
    return std.fmt.allocPrint(a, "{s} {s} {s}i", .{ re_text, if (isNeg(x.im)) "−" else "+", im_part });
}

fn isExactC(x: C) bool {
    return x.re.isExact() and x.im.isExact();
}

/// True when every part is exact (so the answer is shown with "=").
pub fn isExact(v: Value) bool {
    return switch (v) {
        .scalar => |c| isExactC(c),
        .matrix => |m| for (m.items) |x| {
            if (!isExactC(x)) break false;
        } else true,
        .quantity => |q| q.value.isExact(),
    };
}

pub fn format(a: std.mem.Allocator, v: Value, style: num.Style) Error![]u8 {
    switch (v) {
        .scalar => |c| return formatC(a, c, style),
        .quantity => |q| return quantity.format(a, q, style) catch |e| return @errorCast(e),
        .matrix => |m| {
            var out: std.ArrayList(u8) = .empty;
            try out.append(a, '[');
            for (0..m.rows) |r| {
                if (r > 0) try out.appendSlice(a, "; ");
                for (0..m.cols) |c| {
                    if (c > 0) try out.appendSlice(a, ", ");
                    const t = try formatC(a, m.at(r, c), style);
                    // A complex entry is parenthesised: [1 + 2i, 3].
                    if (!m.at(r, c).isReal() and !m.at(r, c).re.isZero()) {
                        try out.append(a, '(');
                        try out.appendSlice(a, t);
                        try out.append(a, ')');
                    } else try out.appendSlice(a, t);
                }
            }
            try out.append(a, ']');
            return out.toOwnedSlice(a);
        },
    }
}

// ---- evaluating ---------------------------------------------------------------------

const rich_only = [_][]const u8{
    "matrix",     "vector",   "identity", "transpose", "transp",  "det",      "inv",     "inverse", "adj",    "adjoint",
    "cofactor",   "trace",    "rk",       "rref",      "dimension", "rows",   "columns", "row",     "column", "element",
    "elements",   "magnitude", "norm",    "dot",       "cross",   "triple_product", "hadamard", "entrywise", "permanent", "horzcat",
    "vertcat",    "multiply", "lsolve",   "sort",      "rank",    "total",    "percentile", "quartile", "decile", "iqr",
    "mode",       "range",    "number",   "harmmean",  "geomean", "rms",      "stdevp",  "varp",    "stderr", "meandev",
    "cov",        "covar",    "pearson",  "spearman",  "weighmean", "trimmean", "winsormean", "poolvar", "re",   "im",
    "arg",        "conj",     "polar",    "cis",       "flip",    "reverse",  "cumsum",  "mad",     "skew",   "kurtosis",
    "zscore",     "sumsq",    "multisolve", "eq",
};

/// Names only this module knows (so the plain evaluator does not take them for a product).
pub fn isRichFunction(name: []const u8) bool {
    for (rich_only) |f| if (std.ascii.eqlIgnoreCase(f, name)) return true;
    return false;
}

fn isOneOf(name: []const u8, comptime list: anytype) bool {
    inline for (list) |w| if (std.mem.eql(u8, name, w)) return true;
    return false;
}

const Scan = struct { trigger: bool = false, unresolved: bool = false };

fn isNum(n: *const Node) bool {
    return n.* == .number or (n.* == .unary and n.unary.op == .neg and n.unary.arg.* == .number);
}

fn codepoints(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn scan(n: *const Node, session: *eval.Session, attached: bool, s: *Scan) void {
    switch (n.*) {
        .number => {},
        .name => |nm| {
            if (session.vars.contains(nm.text) or session.rich.contains(nm.text) or eval.isConstant(nm.text) or
                std.mem.eql(u8, nm.text, "i") or quantity.isConstantName(nm.text)) return;
            if (quantity.isUnitName(nm.text)) {
                if (attached or codepoints(nm.text) > 1) s.trigger = true;
            } else s.unresolved = true;
        },
        .unary => |u| scan(u.arg, session, false, s),
        .binary => |b| {
            const mulish = b.op == .mul or b.op == .div;
            if (b.op == .pow) {
                scan(b.l, session, attached, s);
                scan(b.r, session, false, s);
            } else {
                scan(b.l, session, mulish and isNum(b.r), s);
                scan(b.r, session, mulish and isNum(b.l), s);
            }
        },
        .call => |c| {
            if (std.mem.eql(u8, c.name, "to")) s.trigger = true;
            for (c.args) |x| scan(x, session, false, s);
        },
    }
}

/// Units in the entry (`5 ft + 3 in`, `60 mph to km/h`) and every name known.
fn unitRoute(n: *const Node, session: *eval.Session) bool {
    var s: Scan = .{};
    scan(n, session, false, &s);
    return s.trigger and !s.unresolved;
}

/// Does the entry need this module?
pub fn needs(n: *const Node, session: *eval.Session) bool {
    return needsRich(n, session) or unitRoute(n, session);
}

fn needsRich(n: *const Node, session: *eval.Session) bool {
    return switch (n.*) {
        .number => false,
        .name => |nm| (std.mem.eql(u8, nm.text, "i") and !session.vars.contains("i")) or session.rich.contains(nm.text) or
            (std.mem.eql(u8, nm.text, "ans") and session.rich.contains("ans")),
        .unary => |u| needsRich(u.arg, session),
        .binary => |b| needsRich(b.l, session) or needsRich(b.r, session),
        .call => |c| blk: {
            var buf: [48]u8 = undefined;
            if (c.name.len <= buf.len) {
                const lower = std.ascii.lowerString(&buf, c.name);
                if (isRichFunction(lower) and !session.funcs.contains(c.name) and !session.vars.contains(c.name)) break :blk true;
            }
            for (c.args) |x| if (needsRich(x, session)) break :blk true;
            break :blk false;
        },
    };
}

pub const Rich = struct {
    ev: *eval.Eval,
    a: std.mem.Allocator,

    pub fn init(ev: *eval.Eval) Rich {
        return .{ .ev = ev, .a = ev.a };
    }

    fn real(self: *Rich, n: Number) Error!Value {
        return .{ .scalar = try C.real(n, self.a) };
    }

    fn numNode(self: *Rich, n: Number) Error!*Node {
        const p = try self.a.create(Node);
        p.* = .{ .number = n };
        return p;
    }

    pub fn value(self: *Rich, n: *const Node, b: ?*const eval.Binding) Error!Value {
        const a = self.a;
        switch (n.*) {
            .number => |v| return try self.real(v),
            .name => |nm| {
                if (eval.Eval.lookupBinding(b, nm.text)) |v| return try self.real(v);
                if (self.ev.session.vars.contains(nm.text)) return try self.real(try self.ev.eval(n, b));
                if (self.ev.session.rich.get(nm.text)) |s| return s.load(a);
                if (std.mem.eql(u8, nm.text, "ans")) {
                    if (self.ev.session.rich.get("ans")) |s| return s.load(a);
                }
                if (std.mem.eql(u8, nm.text, "i")) return .{ .scalar = .{ .re = try zero(a), .im = try num.fromInt(a, 1) } };
                if (!eval.isConstant(nm.text)) {
                    if (try quantity.constant(a, nm.text)) |q| return fromQuantity(a, q);
                    if (try quantity.resolve(a, nm.text)) |u| {
                        const ups = try a.alloc(quantity.UPow, 1);
                        ups[0] = .{ .unit = u, .exp = 1 };
                        return .{ .quantity = .{ .value = try num.fromInt(a, 1), .units = ups } };
                    }
                }
                return try self.real(try self.ev.eval(n, b));
            },
            .unary => |u| {
                const x = try self.value(u.arg, b);
                switch (u.op) {
                    .neg => {
                        if (x == .quantity) return .{ .quantity = try quantity.neg(a, x.quantity) };
                        return mapValue(a, x, cneg);
                    },
                    .pct, .fact, .bnot => {
                        const c = switch (x) {
                            .scalar => |s| s,
                            else => return error.Domain,
                        };
                        if (!c.isReal()) return error.Domain;
                        const node: Node = .{ .unary = .{ .op = u.op, .arg = try self.numNode(c.re) } };
                        return try self.real(try self.ev.eval(&node, null));
                    },
                }
            },
            .binary => |bin| return self.binary(bin.op, try self.value(bin.l, b), try self.value(bin.r, b)),
            .call => |c| return self.call(c.name, c.args, c.pos, b),
        }
    }

    fn mapValue(a: std.mem.Allocator, v: Value, comptime f: fn (std.mem.Allocator, C) Error!C) Error!Value {
        return switch (v) {
            .scalar => |c| .{ .scalar = try f(a, c) },
            .matrix => |m| .{ .matrix = try mapMatrix(a, m, f) },
            .quantity => error.Units,
        };
    }

    fn asQuantity(v: Value) Error!quantity.Quantity {
        return switch (v) {
            .quantity => |q| q,
            .scalar => |c| if (c.isReal()) .{ .value = c.re, .units = &.{} } else error.Units,
            .matrix => error.Units,
        };
    }

    fn fromQuantity(a: std.mem.Allocator, q: quantity.Quantity) Error!Value {
        if (q.units.len == 0) return .{ .scalar = try C.real(q.value, a) };
        return .{ .quantity = q };
    }

    fn quantityBinary(self: *Rich, op: eval.Op, x: Value, y: Value) Error!Value {
        const a = self.a;
        const qx = try asQuantity(x);
        const qy = try asQuantity(y);
        switch (op) {
            .add, .sub => {
                if (qx.units.len == 0 and qy.units.len == 0) return fromQuantity(a, .{ .value = if (op == .add) try num.add(a, qx.value, qy.value) else try num.sub(a, qx.value, qy.value), .units = &.{} });
                return fromQuantity(a, try quantity.add(a, qx, qy, op == .sub));
            },
            .mul => return fromQuantity(a, try quantity.mul(a, qx, qy)),
            .div => {
                if (qy.value.isZero()) return error.DivisionByZero;
                return fromQuantity(a, try quantity.div(a, qx, qy));
            },
            .pow => {
                if (qy.units.len != 0) {
                    const pure = (try quantity.dimensionless(a, qy)) orelse return error.Units;
                    return self.quantityBinary(.pow, x, .{ .scalar = try C.real(pure, a) });
                }
                if (num.intValue(qy.value)) |n| {
                    if (n < -1000 or n > 1000) return error.TooLarge;
                    return fromQuantity(a, try quantity.powInt(a, qx, @intCast(n)));
                }
                // A fractional power p/q: the q-th root of the units, then the p-th power.
                if (qy.value == .exact) {
                    const q = num.intValue(.{ .exact = .{ .num = qy.value.exact.den, .den = try Big.initSet(a, 1) } }) orelse return error.Units;
                    const p = num.intValue(.{ .exact = .{ .num = qy.value.exact.num, .den = try Big.initSet(a, 1) } }) orelse return error.Units;
                    if (q < 2 or q > 12 or p < -1000 or p > 1000) return error.Units;
                    const root_value = try num.pow(a, qx.value, try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, q)));
                    const rq = try quantity.root(a, qx, @intCast(q), root_value);
                    return fromQuantity(a, try quantity.powInt(a, rq, @intCast(p)));
                }
                return error.Units;
            },
            else => return error.Units,
        }
    }

    fn binary(self: *Rich, op: eval.Op, x: Value, y: Value) Error!Value {
        const a = self.a;
        if (x == .quantity or y == .quantity) return self.quantityBinary(op, x, y);
        switch (op) {
            .add, .sub => {
                const f: *const fn (std.mem.Allocator, C, C) Error!C = if (op == .add) &cadd else &csub;
                if (x == .scalar and y == .scalar) return .{ .scalar = try f(a, x.scalar, y.scalar) };
                if (x == .matrix and y == .matrix) {
                    if (x.matrix.rows != y.matrix.rows or x.matrix.cols != y.matrix.cols) return error.Domain;
                    const out = try newMatrix(a, x.matrix.rows, x.matrix.cols);
                    for (out.items, 0..) |*o, i| o.* = try f(a, x.matrix.items[i], y.matrix.items[i]);
                    return .{ .matrix = out };
                }
                // A number with a matrix: added to every entry.
                const m = if (x == .matrix) x.matrix else y.matrix;
                const s = if (x == .matrix) y.scalar else x.scalar;
                const out = try newMatrix(a, m.rows, m.cols);
                for (out.items, 0..) |*o, i| o.* = if (x == .matrix) try f(a, m.items[i], s) else try f(a, s, m.items[i]);
                return .{ .matrix = out };
            },
            .mul => {
                if (x == .scalar and y == .scalar) return .{ .scalar = try cmul(a, x.scalar, y.scalar) };
                if (x == .matrix and y == .matrix) return .{ .matrix = try matmul(a, x.matrix, y.matrix) };
                const m = if (x == .matrix) x.matrix else y.matrix;
                const s = if (x == .matrix) y.scalar else x.scalar;
                const out = try newMatrix(a, m.rows, m.cols);
                for (out.items, 0..) |*o, i| o.* = try cmul(a, m.items[i], s);
                return .{ .matrix = out };
            },
            .div => {
                if (x == .scalar and y == .scalar) return .{ .scalar = try cdiv(a, x.scalar, y.scalar) };
                if (x == .matrix and y == .scalar) {
                    const out = try newMatrix(a, x.matrix.rows, x.matrix.cols);
                    for (out.items, 0..) |*o, i| o.* = try cdiv(a, x.matrix.items[i], y.scalar);
                    return .{ .matrix = out };
                }
                if (x == .matrix and y == .matrix) return .{ .matrix = try matmul(a, x.matrix, try inverse(a, y.matrix)) };
                return error.Domain;
            },
            .pow => {
                if (x == .scalar and y == .scalar) return .{ .scalar = try cpow(a, x.scalar, y.scalar) };
                if (x == .matrix and y == .scalar and y.scalar.isReal()) {
                    const n = num.intValue(y.scalar.re) orelse return error.Domain;
                    if (x.matrix.rows != x.matrix.cols) return error.Domain;
                    var base = if (n < 0) try inverse(a, x.matrix) else x.matrix;
                    var e: u64 = @abs(n);
                    var acc = try identity(a, x.matrix.rows);
                    if (e > 100_000) return error.TooLarge;
                    while (e > 0) : (e >>= 1) {
                        if (e & 1 == 1) acc = try matmul(a, acc, base);
                        if (e > 1) base = try matmul(a, base, base);
                    }
                    return .{ .matrix = acc };
                }
                return error.Domain;
            },
            .mod, .add_pct, .sub_pct, .band, .bor, .bxor, .shl, .shr => {
                if (x != .scalar or y != .scalar or !x.scalar.isReal() or !y.scalar.isReal()) return error.Domain;
                const node: Node = .{ .binary = .{ .op = op, .l = try self.numNode(x.scalar.re), .r = try self.numNode(y.scalar.re) } };
                return try self.real(try self.ev.eval(&node, null));
            },
        }
    }

    // ---- systems of equations --------------------------------------------------------

    /// The entries of a matrix literal node (matrix(rows, cols, e…)).
    fn literalItems(n: *const Node) ?[]*Node {
        if (n.* != .call or !std.mem.eql(u8, n.call.name, "matrix") or n.call.args.len < 3) return null;
        return n.call.args[2..];
    }

    /// multisolve([x + y = 5; x - y = 1], [x, y]): a linear system, as a vector.
    fn multisolve(self: *Rich, arg_nodes: []*Node, b: ?*const eval.Binding) Error!Value {
        const a = self.a;
        if (arg_nodes.len != 2) return error.WrongArguments;
        const eqs = literalItems(arg_nodes[0]) orelse return error.Domain;
        const vars = literalItems(arg_nodes[1]) orelse return error.Domain;
        const n = vars.len;
        if (eqs.len != n) return error.Domain;
        for (vars) |v| if (v.* != .name) return error.Domain;
        // Residuals of every equation at a point.
        const Probe = struct {
            fn at(rr: *Rich, eq_nodes: []*Node, var_nodes: []*Node, point: []const Number, outer: ?*const eval.Binding) Error![]Number {
                var chain = outer;
                for (var_nodes, point) |v, x| {
                    const bind = try rr.a.create(eval.Binding);
                    bind.* = .{ .name = v.name.text, .value = x, .next = chain };
                    chain = bind;
                }
                const res = try rr.a.alloc(Number, eq_nodes.len);
                for (eq_nodes, 0..) |e, i| {
                    if (e.* == .call and std.mem.eql(u8, e.call.name, "eq") and e.call.args.len == 2) {
                        res[i] = try num.sub(rr.a, try rr.ev.eval(e.call.args[0], chain), try rr.ev.eval(e.call.args[1], chain));
                    } else res[i] = try rr.ev.eval(e, chain);
                }
                return res;
            }
        };
        const point = try a.alloc(Number, n);
        for (point) |*p| p.* = try zero(a);
        const f0 = try Probe.at(self, eqs, vars, point, b);
        const aug = try newMatrix(a, n, n + 1);
        for (0..n) |j| {
            point[j] = try num.fromInt(a, 1);
            const fj = try Probe.at(self, eqs, vars, point, b);
            point[j] = try zero(a);
            for (0..n) |i| aug.items[i * (n + 1) + j] = try C.real(try num.sub(a, fj[i], f0[i]), a);
        }
        for (0..n) |i| aug.items[i * (n + 1) + n] = try C.real(try num.neg(a, f0[i]), a);
        // Linear? Check at another point.
        for (point, 0..) |*p, j| p.* = try num.fromInt(a, @as(i64, @intCast(j + 2)));
        const fp = try Probe.at(self, eqs, vars, point, b);
        for (0..n) |i| {
            var want = f0[i];
            for (0..n) |j| want = try num.add(a, want, try num.mul(a, aug.items[i * (n + 1) + j].re, point[j]));
            const d = try num.sub(a, fp[i], want);
            if (!(d.isZero() or @abs(d.toFloat()) <= 1e-9 * @max(1.0, @abs(want.toFloat())))) return error.Domain;
        }
        const e = try eliminate(a, aug, n, true);
        if (e.rank < n) return error.NoSolution;
        const out = try newMatrix(a, 1, n);
        for (0..n) |i| out.items[i] = e.m.items[i * (n + 1) + n];
        return .{ .matrix = out };
    }

    // ---- calls ---------------------------------------------------------------------

    fn call(self: *Rich, name: []const u8, arg_nodes: []*Node, pos: usize, b: ?*const eval.Binding) Error!Value {
        const a = self.a;
        var buf: [48]u8 = undefined;
        const lower = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else name;
        // A user's function or a calculus form: plain arguments only.
        const plain = self.ev.session.funcs.contains(name) or isOneOf(lower, .{ "diff", "derivative", "integral", "integrate", "limit", "prod" }) or
            (isOneOf(lower, .{"sum"}) and arg_nodes.len == 4);
        if (plain) return try self.real(try self.ev.callPlain(name, arg_nodes, pos, b));

        if (std.mem.eql(u8, lower, "multisolve")) return self.multisolve(arg_nodes, b);
        if (std.mem.eql(u8, lower, "eq")) return error.Domain;
        const args = try a.alloc(Value, arg_nodes.len);
        for (arg_nodes, 0..) |an, i| args[i] = try self.value(an, b);

        if (std.mem.eql(u8, lower, "to")) {
            if (args.len != 2) return error.WrongArguments;
            const target = try asQuantity(args[1]);
            return fromQuantity(a, try quantity.convert(a, try asQuantity(args[0]), target.units));
        }
        for (args) |v| if (v == .quantity) return self.quantityCall(name, lower, args, pos);

        if (try self.richCall(lower, args, pos)) |v| return v;

        // An ordinary function: of reals, the plain evaluator; of a matrix, entry by entry.
        var any_matrix = false;
        for (args) |v| if (v == .matrix) {
            any_matrix = true;
        };
        if (any_matrix) {
            if (args.len != 1) return error.Domain;
            const m = args[0].matrix;
            const out = try newMatrix(a, m.rows, m.cols);
            for (m.items, 0..) |x, i| {
                var one: [1]Value = .{.{ .scalar = x }};
                const r = try self.scalarFunction(name, lower, &one, arg_nodes, pos);
                out.items[i] = r;
            }
            return .{ .matrix = out };
        }
        return .{ .scalar = try self.scalarFunction(name, lower, args, arg_nodes, pos) };
    }

    /// A function of amounts with units: the shape-keeping ones; trigonometry of angles.
    fn quantityCall(self: *Rich, name: []const u8, lower: []const u8, args: []Value, pos: usize) Error!Value {
        const a = self.a;
        const mode = self.ev.mode.angle;
        // Dimensionless quantities (angles, ratios) are plain numbers to a function.
        const plain = try a.alloc(Value, args.len);
        var all_plain = true;
        for (args, 0..) |v, i| {
            plain[i] = v;
            if (v != .quantity) continue;
            const q = v.quantity;
            if (!quantity.isDimensionless(q)) {
                all_plain = false;
                continue;
            }
            const trig = isOneOf(lower, .{ "sin", "cos", "tan", "sec", "csc", "cot" });
            const want: []const u8 = switch (mode) {
                .degrees => "°",
                .radians => "rad",
                .gradians => "grad",
            };
            if (trig and q.units.len == 1 and q.units[0].exp == 1 and std.mem.eql(u8, q.units[0].unit.sym, want)) {
                plain[i] = .{ .scalar = try C.real(q.value, a) };
                continue;
            }
            var rad = (try quantity.dimensionless(a, q)).?;
            if (trig) {
                const per: f64 = switch (mode) {
                    .degrees => 180.0 / std.math.pi,
                    .radians => 1.0,
                    .gradians => 200.0 / std.math.pi,
                };
                rad = try num.mul(a, rad, .{ .approx = per });
            }
            plain[i] = .{ .scalar = try C.real(rad, a) };
        }
        if (all_plain) return self.call2(name, lower, plain, pos);
        // With dimensions: a few functions keep the units.
        if (args.len == 1 and args[0] == .quantity) {
            const q = args[0].quantity;
            if (isOneOf(lower, .{ "sqrt", "cbrt" })) {
                const rv = (try self.scalarFunction(name, lower, @constCast(&[_]Value{.{ .scalar = try C.real(q.value, a) }}), &.{}, pos)).re;
                return fromQuantity(a, try quantity.root(a, q, if (std.mem.eql(u8, lower, "sqrt")) 2 else 3, rv));
            }
            if (isOneOf(lower, .{ "abs", "floor", "ceil", "round", "trunc", "frac", "sign" })) {
                const rv = (try self.scalarFunction(name, lower, @constCast(&[_]Value{.{ .scalar = try C.real(q.value, a) }}), &.{}, pos)).re;
                if (std.mem.eql(u8, lower, "sign")) return .{ .scalar = try C.real(rv, a) };
                return fromQuantity(a, .{ .value = rv, .units = q.units });
            }
        }
        if (args.len >= 2 and isOneOf(lower, .{ "min", "max" })) {
            var best = try asQuantity(args[0]);
            for (args[1..]) |v| {
                const q = try asQuantity(v);
                const in_best = try quantity.convert(a, q, best.units);
                const o = try num.order(a, in_best.value, best.value);
                if ((std.mem.eql(u8, lower, "min") and o == .lt) or (std.mem.eql(u8, lower, "max") and o == .gt)) best = in_best;
            }
            return fromQuantity(a, best);
        }
        return error.Units;
    }

    /// The call once its arguments are plain values.
    fn call2(self: *Rich, name: []const u8, lower: []const u8, args: []Value, pos: usize) Error!Value {
        if (try self.richCall(lower, args, pos)) |v| return v;
        return .{ .scalar = try self.scalarFunction(name, lower, args, &.{}, pos) };
    }

    fn scalarFunction(self: *Rich, name: []const u8, lower: []const u8, args: []Value, arg_nodes: []*Node, pos: usize) Error!C {
        const a = self.a;
        _ = arg_nodes;
        var all_real = true;
        for (args) |v| if (!v.scalar.isReal()) {
            all_real = false;
        };
        if (all_real) {
            const nodes = try a.alloc(*Node, args.len);
            for (args, 0..) |v, i| nodes[i] = try self.numNode(v.scalar.re);
            if (self.ev.callPlain(name, nodes, pos, null)) |r| return C.real(r, a) else |e| {
                // Out of the reals: the complex function, if there is one.
                if (e != error.Domain) return e;
                if (try self.complexFunction(lower, args)) |c| return c;
                return e;
            }
        }
        if (try self.complexFunction(lower, args)) |c| return c;
        return error.Domain;
    }

    fn complexFunction(self: *Rich, f: []const u8, args: []Value) Error!?C {
        const a = self.a;
        if (args.len == 0 or args[0] != .scalar) return null;
        const x = args[0].scalar;
        const z = toFloatC(x);
        const one = try C.real(try num.fromInt(a, 1), a);
        if (isOneOf(f, .{"sqrt"})) return try csqrt(a, x);
        if (isOneOf(f, .{ "ln", "log" })) {
            if (args.len == 1 and std.mem.eql(u8, f, "log")) {
                const l = try fromFloatC(std.math.complex.log(z));
                return try cdiv(a, l, try C.real(try num.fromFloat(@log(10.0)), a));
            }
            if (args.len == 1) return try fromFloatC(std.math.complex.log(z));
            return null;
        }
        if (isOneOf(f, .{"exp"})) return try fromFloatC(std.math.complex.exp(z));
        if (isOneOf(f, .{"sin"})) return try fromFloatC(std.math.complex.sin(z));
        if (isOneOf(f, .{"cos"})) return try fromFloatC(std.math.complex.cos(z));
        if (isOneOf(f, .{"tan"})) return try fromFloatC(std.math.complex.tan(z));
        if (isOneOf(f, .{"sinh"})) return try fromFloatC(std.math.complex.sinh(z));
        if (isOneOf(f, .{"cosh"})) return try fromFloatC(std.math.complex.cosh(z));
        if (isOneOf(f, .{"tanh"})) return try fromFloatC(std.math.complex.tanh(z));
        if (isOneOf(f, .{ "asin", "acos" }) and x.isReal()) {
            // Beyond ±1 the answer sits on a branch cut; take the side Qalculate does
            // (asin(2) = π/2 − 1.317i, asin(−2) = −π/2 + 1.317i).
            const xv = x.re.toFloat();
            const side: f64 = if (xv > 1) -0.0 else 0.0;
            const s = std.math.complex.asin(cplx.init(xv, side));
            if (std.mem.eql(u8, f, "asin")) return try fromFloatC(s);
            return try fromFloatC(cplx.init(std.math.pi / 2.0 - s.re, -s.im));
        }
        if (isOneOf(f, .{"asin"})) return try fromFloatC(std.math.complex.asin(z));
        if (isOneOf(f, .{"acos"})) return try fromFloatC(std.math.complex.acos(z));
        if (isOneOf(f, .{"atan"})) {
            // On the imaginary axis beyond ±i the cut is crossed: π/2 on the upper half.
            if (z.re == 0 and @abs(z.im) > 1) {
                const y = z.im;
                return try fromFloatC(cplx.init(if (y > 0) std.math.pi / 2.0 else -std.math.pi / 2.0, 0.5 * @log(@abs((1 + y) / (1 - y)))));
            }
            return try fromFloatC(std.math.complex.atan(z));
        }
        if (isOneOf(f, .{"asinh"})) return try fromFloatC(std.math.complex.asinh(z));
        if (isOneOf(f, .{"acosh"})) return try fromFloatC(std.math.complex.acosh(z));
        if (isOneOf(f, .{"atanh"})) return try fromFloatC(std.math.complex.atanh(z));
        if (isOneOf(f, .{"cbrt"})) return try cpow(a, x, .{ .re = try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 3)), .im = try zero(a) });
        if (isOneOf(f, .{ "abs" })) return try C.real(try cabs(a, x), a);
        if (isOneOf(f, .{"sign"}) ) {
            const m = try cabs(a, x);
            if (m.isZero()) return try C.real(try zero(a), a);
            return try cdiv(a, x, try C.real(m, a));
        }
        _ = one;
        return null;
    }

    /// The functions of this module. Null when `f` is not one of them.
    fn richCall(self: *Rich, f: []const u8, args: []Value, pos: usize) Error!?Value {
        const a = self.a;
        _ = pos;
        // ---- complex parts ----
        if (isOneOf(f, .{ "re", "im", "arg", "conj", "polar", "cis" })) {
            if (std.mem.eql(u8, f, "polar")) {
                if (args.len != 2 or args[0] != .scalar or args[1] != .scalar) return error.WrongArguments;
                const r = args[0].scalar.re.toFloat();
                const th = args[1].scalar.re.toFloat();
                return .{ .scalar = try fromFloatC(cplx.init(r * @cos(th), r * @sin(th))) };
            }
            if (std.mem.eql(u8, f, "cis")) {
                if (args.len != 1 or args[0] != .scalar) return error.WrongArguments;
                const th = args[0].scalar.re.toFloat();
                return .{ .scalar = try fromFloatC(cplx.init(@cos(th), @sin(th))) };
            }
            if (args.len != 1) return error.WrongArguments;
            return switch (args[0]) {
                .scalar => |c| .{ .scalar = try complexPart(a, f, c) },
                .matrix => |m| blk: {
                    const out = try newMatrix(a, m.rows, m.cols);
                    for (m.items, 0..) |x, i| out.items[i] = try complexPart(a, f, x);
                    break :blk Value{ .matrix = out };
                },
                .quantity => return error.Units,
            };
        }
        // ---- building matrices ----
        if (std.mem.eql(u8, f, "matrix")) return try self.buildMatrix(args);
        if (std.mem.eql(u8, f, "vector")) {
            const items = try flatten(a, args);
            const m = try newMatrix(a, 1, items.len);
            @memcpy(m.items, items);
            return .{ .matrix = m };
        }
        if (std.mem.eql(u8, f, "identity")) {
            if (args.len != 1) return error.WrongArguments;
            const n = try self.smallInt(args[0]);
            if (n < 1) return error.Domain;
            return .{ .matrix = try identity(a, @intCast(n)) };
        }
        if (isOneOf(f, .{ "horzcat", "vertcat" })) return try self.concat(args, std.mem.eql(u8, f, "horzcat"));
        // ---- one matrix in ----
        if (isOneOf(f, .{ "transpose", "transp", "det", "inv", "inverse", "adj", "adjoint", "trace", "rk", "rref", "permanent", "dimension", "rows", "columns", "elements", "flip", "reverse" })) {
            if (args.len != 1) return error.WrongArguments;
            const m = try self.asMatrix(args[0]);
            if (isOneOf(f, .{ "transpose", "transp" })) return .{ .matrix = try transpose(a, m) };
            if (std.mem.eql(u8, f, "det")) return .{ .scalar = try det(a, m) };
            if (isOneOf(f, .{ "inv", "inverse" })) return if (args[0] == .scalar) .{ .scalar = try cdiv(a, try C.real(try num.fromInt(a, 1), a), args[0].scalar) } else .{ .matrix = try inverse(a, m) };
            if (isOneOf(f, .{ "adj", "adjoint" })) {
                if (m.rows != m.cols) return error.Domain;
                if (m.rows == 1) return .{ .matrix = try identity(a, 1) };
                if (m.rows > 8) return error.TooLarge;
                const out = try newMatrix(a, m.rows, m.cols);
                for (0..m.rows) |r| for (0..m.cols) |c| {
                    out.items[c * m.rows + r] = try cofactor(a, m, r, c);
                };
                return .{ .matrix = out };
            }
            if (std.mem.eql(u8, f, "trace")) {
                if (m.rows != m.cols) return error.Domain;
                var t = try C.real(try zero(a), a);
                for (0..m.rows) |i| t = try cadd(a, t, m.at(i, i));
                return .{ .scalar = t };
            }
            if (std.mem.eql(u8, f, "rk")) return try self.real(try nInt(a, (try eliminate(a, m, m.cols, false)).rank));
            if (std.mem.eql(u8, f, "rref")) return .{ .matrix = (try eliminate(a, m, m.cols, true)).m };
            if (std.mem.eql(u8, f, "permanent")) return .{ .scalar = try permanent(a, m) };
            if (std.mem.eql(u8, f, "dimension") or std.mem.eql(u8, f, "elements")) return try self.real(try nInt(a, m.rows * m.cols));
            if (std.mem.eql(u8, f, "rows")) return try self.real(try nInt(a, m.rows));
            if (std.mem.eql(u8, f, "columns")) return try self.real(try nInt(a, m.cols));
            // flip / reverse: the entries in reverse order.
            const out = try newMatrix(a, m.rows, m.cols);
            for (m.items, 0..) |_, i| out.items[i] = m.items[m.items.len - 1 - i];
            return .{ .matrix = out };
        }
        if (isOneOf(f, .{ "row", "column", "element", "cofactor" })) {
            if (args.len < 2) return error.WrongArguments;
            const m = try self.asMatrix(args[0]);
            const i = try self.smallInt(args[1]);
            if (std.mem.eql(u8, f, "row")) {
                if (i < 1 or i > m.rows) return error.Domain;
                const out = try newMatrix(a, 1, m.cols);
                for (0..m.cols) |c| out.items[c] = m.at(@intCast(i - 1), c);
                return .{ .matrix = out };
            }
            if (std.mem.eql(u8, f, "column")) {
                if (i < 1 or i > m.cols) return error.Domain;
                // Qalculate shows a column as a vector (one row).
                const out = try newMatrix(a, 1, m.rows);
                for (0..m.rows) |r| out.items[r] = m.at(r, @intCast(i - 1));
                return .{ .matrix = out };
            }
            if (std.mem.eql(u8, f, "element")) {
                if (args.len == 2) {
                    if (i < 1 or i > m.rows * m.cols) return error.Domain;
                    return .{ .scalar = m.items[@intCast(i - 1)] };
                }
                const j = try self.smallInt(args[2]);
                if (i < 1 or i > m.rows or j < 1 or j > m.cols) return error.Domain;
                return .{ .scalar = m.at(@intCast(i - 1), @intCast(j - 1)) };
            }
            if (args.len != 3) return error.WrongArguments;
            const j = try self.smallInt(args[2]);
            if (i < 1 or i > m.rows or j < 1 or j > m.cols) return error.Domain;
            return .{ .scalar = try cofactor(a, m, @intCast(i - 1), @intCast(j - 1)) };
        }
        // ---- two vectors / matrices ----
        if (isOneOf(f, .{ "dot", "cross", "hadamard", "entrywise", "multiply", "lsolve" })) {
            if (args.len != 2) return error.WrongArguments;
            const x = try self.asMatrix(args[0]);
            const y = try self.asMatrix(args[1]);
            if (std.mem.eql(u8, f, "multiply")) return .{ .matrix = try matmul(a, x, y) };
            if (std.mem.eql(u8, f, "lsolve")) {
                // A x = b.
                const sol = try matmul(a, try inverse(a, x), if (y.rows == 1 and x.rows != 1) try transpose(a, y) else y);
                return .{ .matrix = sol };
            }
            if (std.mem.eql(u8, f, "dot")) {
                if (x.items.len != y.items.len) return error.Domain;
                var t = try C.real(try zero(a), a);
                for (x.items, y.items) |p, q| t = try cadd(a, t, try cmul(a, p, try conj(a, q)));
                return .{ .scalar = t };
            }
            if (std.mem.eql(u8, f, "cross")) {
                if (x.items.len != 3 or y.items.len != 3) return error.Domain;
                const out = try newMatrix(a, x.rows, x.cols);
                const idx3 = [3][2]usize{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } };
                for (idx3, 0..) |p, k| {
                    out.items[k] = try csub(a, try cmul(a, x.items[p[0]], y.items[p[1]]), try cmul(a, x.items[p[1]], y.items[p[0]]));
                }
                return .{ .matrix = out };
            }
            // hadamard / entrywise: the product entry by entry.
            if (x.rows != y.rows or x.cols != y.cols) return error.Domain;
            const out = try newMatrix(a, x.rows, x.cols);
            for (out.items, 0..) |*o, i| o.* = try cmul(a, x.items[i], y.items[i]);
            return .{ .matrix = out };
        }
        if (std.mem.eql(u8, f, "triple_product")) {
            if (args.len != 3) return error.WrongArguments;
            const m = try newMatrix(a, 3, 3);
            for (args, 0..) |v, r| {
                const x = try self.asMatrix(v);
                if (x.items.len != 3) return error.Domain;
                for (0..3) |c| m.items[r * 3 + c] = x.items[c];
            }
            return .{ .scalar = try det(a, m) };
        }
        if (isOneOf(f, .{ "magnitude", "norm" })) {
            if (args.len < 1 or args.len > 2) return error.WrongArguments;
            const m = try self.asMatrix(args[0]);
            const p: Number = if (args.len == 2) args[1].scalar.re else try num.fromInt(a, 2);
            // (Σ |x|^p)^(1/p); p = inf is the largest.
            if (std.math.isInf(p.toFloat())) {
                var best = try zero(a);
                for (m.items) |x| {
                    const mg = try cabs(a, x);
                    if (lessNum(a, best, mg)) best = mg;
                }
                return try self.real(best);
            }
            var t = try zero(a);
            for (m.items) |x| t = try num.add(a, t, try num.pow(a, try cabs(a, x), p));
            return try self.real(try num.pow(a, t, try num.div(a, try num.fromInt(a, 1), p)));
        }
        // ---- lists of reals ----
        return try self.listFunction(f, args);
    }

    fn complexPart(a: std.mem.Allocator, f: []const u8, c: C) Error!C {
        if (std.mem.eql(u8, f, "re")) return C.real(c.re, a);
        if (std.mem.eql(u8, f, "im")) return C.real(c.im, a);
        if (std.mem.eql(u8, f, "conj")) return conj(a, c);
        // arg: the angle, in radians.
        if (c.isReal()) {
            if (c.re.isZero()) return error.Domain;
            return C.real(if (isNeg(c.re)) try num.fromFloat(std.math.pi) else try zero(a), a);
        }
        return C.real(try num.fromFloat(std.math.atan2(c.im.toFloat(), c.re.toFloat())), a);
    }

    fn smallInt(self: *Rich, v: Value) Error!i64 {
        _ = self;
        if (v != .scalar or !v.scalar.isReal()) return error.Domain;
        const n = num.intValue(v.scalar.re) orelse return error.NotInteger;
        if (n < -1_000_000 or n > 1_000_000) return error.TooLarge;
        return n;
    }

    fn asMatrix(self: *Rich, v: Value) Error!Matrix {
        return switch (v) {
            .matrix => |m| m,
            .scalar => |c| blk: {
                const m = try newMatrix(self.a, 1, 1);
                m.items[0] = c;
                break :blk m;
            },
            .quantity => error.Units,
        };
    }

    /// matrix(rows, cols, e11, e12, …) — what `[1, 2; 3, 4]` is read as. A
    /// single row of rows ([[1, 2], [3, 4]]) stacks them.
    fn buildMatrix(self: *Rich, args: []Value) Error!Value {
        const a = self.a;
        if (args.len < 3) return error.WrongArguments;
        const r = try self.smallInt(args[0]);
        const c = try self.smallInt(args[1]);
        if (r < 1 or c < 1 or @as(usize, @intCast(r)) * @as(usize, @intCast(c)) != args.len - 2) return error.WrongArguments;
        const items = args[2..];
        var any_matrix = false;
        for (items) |v| if (v == .matrix) {
            any_matrix = true;
        };
        if (!any_matrix) {
            const m = try newMatrix(a, @intCast(r), @intCast(c));
            for (items, 0..) |v, i| m.items[i] = v.scalar;
            return .{ .matrix = m };
        }
        // Rows given as matrices: [[1, 2], [3, 4]], or blocks.
        if (r == 1) return try self.concat(items, false);
        return error.Domain;
    }

    fn concat(self: *Rich, args: []Value, horizontal: bool) Error!Value {
        const a = self.a;
        if (args.len == 0) return error.WrongArguments;
        var ms = try a.alloc(Matrix, args.len);
        for (args, 0..) |v, i| ms[i] = try self.asMatrix(v);
        var rows: usize = 0;
        var cols: usize = 0;
        if (horizontal) {
            rows = ms[0].rows;
            for (ms) |m| {
                if (m.rows != rows) return error.Domain;
                cols += m.cols;
            }
        } else {
            cols = ms[0].cols;
            for (ms) |m| {
                if (m.cols != cols) return error.Domain;
                rows += m.rows;
            }
        }
        const out = try newMatrix(a, rows, cols);
        var off: usize = 0;
        for (ms) |m| {
            for (0..m.rows) |r| for (0..m.cols) |c| {
                if (horizontal) out.items[r * cols + off + c] = m.at(r, c) else out.items[(off + r) * cols + c] = m.at(r, c);
            };
            off += if (horizontal) m.cols else m.rows;
        }
        return .{ .matrix = out };
    }

    // ---- statistics -----------------------------------------------------------------

    fn reals(self: *Rich, v: Value) Error![]Number {
        const a = self.a;
        const items = switch (v) {
            .scalar => |c| blk: {
                const one = try a.alloc(C, 1);
                one[0] = c;
                break :blk one;
            },
            .matrix => |m| m.items,
            .quantity => return error.Units,
        };
        const out = try a.alloc(Number, items.len);
        for (items, 0..) |c, i| {
            if (!c.isReal()) return error.Domain;
            out[i] = c.re;
        }
        return out;
    }

    fn allReals(self: *Rich, args: []Value) Error![]Number {
        var list: std.ArrayList(Number) = .empty;
        for (args) |v| try list.appendSlice(self.a, try self.reals(v));
        return list.items;
    }

    fn vec(self: *Rich, xs: []const Number, as_col: bool) Error!Value {
        const m = if (as_col) try newMatrix(self.a, xs.len, 1) else try newMatrix(self.a, 1, xs.len);
        for (xs, 0..) |x, i| m.items[i] = try C.real(x, self.a);
        return .{ .matrix = m };
    }

    fn listFunction(self: *Rich, f: []const u8, args: []Value) Error!?Value {
        const a = self.a;
        if (!isOneOf(f, .{
            "total",   "sum",      "mean",     "avg",    "median", "percentile", "quartile", "decile",  "iqr",     "mode",     "range",
            "number",  "harmmean", "geomean",  "rms",    "stdev",  "stdevp",     "var",      "varp",    "stderr",  "meandev",  "cov",
            "covar",   "pearson",  "spearman", "weighmean", "trimmean", "winsormean", "poolvar", "min",   "max",     "sort",     "rank",
            "cumsum",  "mad",      "sumsq",    "zscore", "skew",   "kurtosis",
        })) return null;
        if (args.len == 0) return error.WrongArguments;

        // Two-list functions.
        if (isOneOf(f, .{ "cov", "covar", "pearson", "spearman", "weighmean", "poolvar" })) {
            if (args.len != 2) return error.WrongArguments;
            var x = try self.reals(args[0]);
            var y = try self.reals(args[1]);
            if (std.mem.eql(u8, f, "poolvar")) {
                if (x.len + y.len < 3) return error.WrongArguments;
                const vx = try variance(a, x, false);
                const vy = try variance(a, y, false);
                const sx = try num.mul(a, vx, try nInt(a, x.len));
                const sy = try num.mul(a, vy, try nInt(a, y.len));
                return try self.real(try num.div(a, try num.add(a, sx, sy), try nInt(a, x.len + y.len - 2)));
            }
            if (x.len != y.len or x.len == 0) return error.Domain;
            if (std.mem.eql(u8, f, "weighmean")) {
                var t = try zero(a);
                for (x, y) |p, q| t = try num.add(a, t, try num.mul(a, p, q));
                return try self.real(try num.div(a, t, try total(a, y)));
            }
            if (std.mem.eql(u8, f, "spearman")) {
                x = try ranks(a, x);
                y = try ranks(a, y);
            }
            const mx = try meanOf(a, x);
            const my = try meanOf(a, y);
            var cv = try zero(a);
            for (x, y) |p, q| cv = try num.add(a, cv, try num.mul(a, try num.sub(a, p, mx), try num.sub(a, q, my)));
            cv = try num.div(a, cv, try nInt(a, x.len));
            if (std.mem.eql(u8, f, "cov") or std.mem.eql(u8, f, "covar")) return try self.real(cv);
            const sx = try sqrtNumber(a, try variance(a, x, false));
            const sy = try sqrtNumber(a, try variance(a, y, false));
            return try self.real(try num.div(a, cv, try num.mul(a, sx, sy)));
        }

        // percentile(list, p, method), quartile(list, n, method), decile(list, n, method).
        if (isOneOf(f, .{ "percentile", "quartile", "decile" })) {
            if (args.len < 2 or args.len > 3) return error.WrongArguments;
            const xs = try a.dupe(Number, try self.reals(args[0]));
            sortNumbers(a, xs);
            var p = args[1].scalar.re;
            if (std.mem.eql(u8, f, "quartile")) p = try num.mul(a, p, try num.fromInt(a, 25));
            if (std.mem.eql(u8, f, "decile")) p = try num.mul(a, p, try num.fromInt(a, 10));
            const method: i64 = if (args.len == 3) try self.smallInt(args[2]) else 7;
            return try self.real(try percentile(a, xs, p, method));
        }

        const raw = try self.allReals(args);
        if (raw.len == 0) return error.WrongArguments;
        const n = raw.len;

        if (isOneOf(f, .{ "total", "sum" })) return try self.real(try total(a, raw));
        if (isOneOf(f, .{ "mean", "avg" })) return try self.real(try meanOf(a, raw));
        if (std.mem.eql(u8, f, "number")) return try self.real(try nInt(a, n));
        if (isOneOf(f, .{ "min", "max" })) {
            var best = raw[0];
            for (raw[1..]) |x| {
                const o = try num.order(a, x, best);
                if ((std.mem.eql(u8, f, "min") and o == .lt) or (std.mem.eql(u8, f, "max") and o == .gt)) best = x;
            }
            return try self.real(best);
        }
        const sorted = try a.dupe(Number, raw);
        sortNumbers(a, sorted);
        if (std.mem.eql(u8, f, "median")) return try self.real(try percentile(a, sorted, try num.fromInt(a, 50), 7));
        if (std.mem.eql(u8, f, "iqr")) {
            const q3 = try percentile(a, sorted, try num.fromInt(a, 75), 7);
            const q1 = try percentile(a, sorted, try num.fromInt(a, 25), 7);
            return try self.real(try num.sub(a, q3, q1));
        }
        if (std.mem.eql(u8, f, "range")) return try self.real(try num.sub(a, sorted[n - 1], sorted[0]));
        if (std.mem.eql(u8, f, "sort")) return try self.vec(sorted, args[0] == .matrix and args[0].matrix.cols == 1);
        if (std.mem.eql(u8, f, "rank")) return try self.vec(try ranks(a, raw), args[0] == .matrix and args[0].matrix.cols == 1);
        if (std.mem.eql(u8, f, "cumsum")) {
            const out = try a.alloc(Number, n);
            var t = try zero(a);
            for (raw, 0..) |x, i| {
                t = try num.add(a, t, x);
                out[i] = t;
            }
            return try self.vec(out, args[0] == .matrix and args[0].matrix.cols == 1);
        }
        if (std.mem.eql(u8, f, "mode")) {
            var best_count: usize = 0;
            var modes: std.ArrayList(Number) = .empty;
            var i: usize = 0;
            while (i < n) {
                var j = i + 1;
                while (j < n and (try num.order(a, sorted[j], sorted[i])) == .eq) j += 1;
                const count = j - i;
                if (count > best_count) {
                    best_count = count;
                    modes.clearRetainingCapacity();
                    try modes.append(a, sorted[i]);
                } else if (count == best_count) try modes.append(a, sorted[i]);
                i = j;
            }
            // Several equally common values: the smallest, as Qalculate gives.
            return try self.real(modes.items[0]);
        }
        if (isOneOf(f, .{ "var", "varp", "stdev", "stdevp", "stderr" })) {
            const sample = isOneOf(f, .{ "var", "stdev", "stderr" });
            const v = try variance(a, raw, sample);
            if (isOneOf(f, .{ "var", "varp" })) return try self.real(v);
            if (std.mem.eql(u8, f, "stderr")) return try self.real(try sqrtNumber(a, try num.div(a, v, try nInt(a, n))));
            return try self.real(try sqrtNumber(a, v));
        }
        if (std.mem.eql(u8, f, "rms")) {
            var t = try zero(a);
            for (raw) |x| t = try num.add(a, t, try num.mul(a, x, x));
            return try self.real(try sqrtNumber(a, try num.div(a, t, try nInt(a, n))));
        }
        if (std.mem.eql(u8, f, "sumsq")) {
            var t = try zero(a);
            for (raw) |x| t = try num.add(a, t, try num.mul(a, x, x));
            return try self.real(t);
        }
        if (std.mem.eql(u8, f, "meandev") or std.mem.eql(u8, f, "mad")) {
            const m = try meanOf(a, raw);
            var t = try zero(a);
            for (raw) |x| t = try num.add(a, t, try absNumber(a, try num.sub(a, x, m)));
            return try self.real(try num.div(a, t, try nInt(a, n)));
        }
        if (std.mem.eql(u8, f, "harmmean")) {
            var t = try zero(a);
            for (raw) |x| t = try num.add(a, t, try num.div(a, try num.fromInt(a, 1), x));
            return try self.real(try num.div(a, try nInt(a, n), t));
        }
        if (std.mem.eql(u8, f, "geomean")) {
            var t: f64 = 0;
            for (raw) |x| {
                if (isNeg(x) or x.isZero()) return error.Domain;
                t += @log(x.toFloat());
            }
            return try self.real(try num.fromFloat(@exp(t / @as(f64, @floatFromInt(n)))));
        }
        if (std.mem.eql(u8, f, "zscore")) {
            if (args.len != 2) return error.WrongArguments;
            const xs = try self.reals(args[0]);
            const sd = try sqrtNumber(a, try variance(a, xs, false));
            return try self.real(try num.div(a, try num.sub(a, args[1].scalar.re, try meanOf(a, xs)), sd));
        }
        if (isOneOf(f, .{ "skew", "kurtosis" })) {
            const m = try meanOf(a, raw);
            const v = try variance(a, raw, false);
            const sd = try sqrtNumber(a, v);
            const k: i64 = if (std.mem.eql(u8, f, "skew")) 3 else 4;
            var t = try zero(a);
            for (raw) |x| t = try num.add(a, t, try num.pow(a, try num.sub(a, x, m), try num.fromInt(a, k)));
            return try self.real(try num.div(a, try num.div(a, t, try nInt(a, n)), try num.pow(a, sd, try num.fromInt(a, k))));
        }
        if (std.mem.eql(u8, f, "trimmean") or std.mem.eql(u8, f, "winsormean")) {
            if (args.len != 2) return error.WrongArguments;
            const xs = try a.dupe(Number, try self.reals(args[0]));
            sortNumbers(a, xs);
            const pct = args[1].scalar.re;
            const k_num = try num.floor(a, try num.add(a, try num.div(a, try num.mul(a, try nInt(a, xs.len), pct), try num.fromInt(a, 100)), try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 2))));
            const k: usize = @intCast(@max(0, num.intValue(k_num) orelse 0));
            if (std.mem.eql(u8, f, "trimmean")) {
                // limits(sort(x), k+1, round(n/100*(100-p))): the entries k+1 … n−k.
                if (2 * k >= xs.len) return error.Domain;
                return try self.real(try meanOf(a, xs[k .. xs.len - k]));
            }
            if (2 * k >= xs.len) return error.Domain;
            var t = try zero(a);
            for (xs[k .. xs.len - k]) |x| t = try num.add(a, t, x);
            t = try num.add(a, t, try num.mul(a, xs[k], try nInt(a, k)));
            t = try num.add(a, t, try num.mul(a, xs[xs.len - k - 1], try nInt(a, k)));
            return try self.real(try num.div(a, t, try nInt(a, xs.len)));
        }
        return null;
    }
};

/// Ranks, ties sharing the average rank (1 = smallest).
fn ranks(a: std.mem.Allocator, xs: []const Number) Error![]Number {
    const n = xs.len;
    const out = try a.alloc(Number, n);
    for (xs, 0..) |x, i| {
        var below: usize = 0;
        var equal: usize = 0;
        for (xs) |y| switch (try num.order(a, y, x)) {
            .lt => below += 1,
            .eq => equal += 1,
            .gt => {},
        };
        // Ranks below + 1 … below + equal share their mean.
        const twice = 2 * below + equal + 1;
        out[i] = try num.div(a, try nInt(a, twice), try num.fromInt(a, 2));
    }
    return out;
}

fn flatten(a: std.mem.Allocator, args: []Value) Error![]C {
    var list: std.ArrayList(C) = .empty;
    for (args) |v| switch (v) {
        .scalar => |c| try list.append(a, c),
        .matrix => |m| try list.appendSlice(a, m.items),
        .quantity => return error.Units,
    };
    if (list.items.len == 0 or list.items.len > max_cells) return error.WrongArguments;
    return list.items;
}

// ---- storing ------------------------------------------------------------------------

/// A value kept in the session (it outlives the entry's arena).
pub const Stored = struct {
    rows: usize,
    cols: usize,
    is_matrix: bool,
    re: []eval.Stored,
    im: []eval.Stored,
    /// A quantity's units (names that resolve again) and exponents.
    unit_names: [][]u8 = &.{},
    unit_exps: []i32 = &.{},
    is_quantity: bool = false,

    pub fn of(gpa: std.mem.Allocator, v: Value) error{OutOfMemory}!Stored {
        const zero_c: C = .{ .re = .{ .approx = 0 }, .im = .{ .approx = 0 } };
        const q_item: C = switch (v) {
            .quantity => |q| .{ .re = q.value, .im = .{ .approx = 0 } },
            else => zero_c,
        };
        const items: []const C = switch (v) {
            .scalar => |*c| @as([*]const C, @ptrCast(c))[0..1],
            .matrix => |m| m.items,
            .quantity => @as([*]const C, @ptrCast(&q_item))[0..1],
        };
        const re = try gpa.alloc(eval.Stored, items.len);
        errdefer gpa.free(re);
        const im = try gpa.alloc(eval.Stored, items.len);
        errdefer gpa.free(im);
        for (items, 0..) |c, i| {
            re[i] = try eval.Stored.of(gpa, c.re);
            im[i] = try eval.Stored.of(gpa, c.im);
        }
        switch (v) {
            .scalar => return .{ .rows = 1, .cols = 1, .is_matrix = false, .re = re, .im = im },
            .matrix => |m| return .{ .rows = m.rows, .cols = m.cols, .is_matrix = true, .re = re, .im = im },
            .quantity => |q| {
                const names = try gpa.alloc([]u8, q.units.len);
                const exps = try gpa.alloc(i32, q.units.len);
                var made: usize = 0;
                errdefer {
                    for (names[0..made]) |n| gpa.free(n);
                    gpa.free(names);
                    gpa.free(exps);
                }
                for (q.units, 0..) |u, i| {
                    names[i] = try gpa.dupe(u8, u.unit.sym);
                    made += 1;
                    exps[i] = u.exp;
                }
                return .{ .rows = 1, .cols = 1, .is_matrix = false, .re = re, .im = im, .unit_names = names, .unit_exps = exps, .is_quantity = true };
            },
        }
    }

    pub fn deinit(self: Stored, gpa: std.mem.Allocator) void {
        for (self.re) |s| s.deinit(gpa);
        for (self.im) |s| s.deinit(gpa);
        gpa.free(self.re);
        gpa.free(self.im);
        for (self.unit_names) |n| gpa.free(n);
        if (self.unit_names.len > 0) gpa.free(self.unit_names);
        if (self.unit_exps.len > 0) gpa.free(self.unit_exps);
    }

    pub fn load(self: Stored, a: std.mem.Allocator) Error!Value {
        if (self.is_quantity) {
            const units = try a.alloc(quantity.UPow, self.unit_names.len);
            for (units, self.unit_names, self.unit_exps) |*u, nm, e| {
                u.* = .{ .unit = (try quantity.resolve(a, nm)) orelse return error.Domain, .exp = e };
            }
            return .{ .quantity = .{ .value = try self.re[0].load(a), .units = units } };
        }
        const items = try a.alloc(C, self.re.len);
        for (items, 0..) |*c, i| c.* = .{ .re = try self.re[i].load(a), .im = try self.im[i].load(a) };
        if (!self.is_matrix) return .{ .scalar = items[0] };
        return .{ .matrix = .{ .rows = self.rows, .cols = self.cols, .items = items } };
    }
};

// ---- tests ----------------------------------------------------------------------------

fn runText(a: std.mem.Allocator, session: *eval.Session, text: []const u8) ![]u8 {
    var p: eval.Problem = .{};
    const out = try eval.run(a, session, text, .{}, &p);
    return switch (out) {
        .rich => |v| try format(a, v, .{}),
        .value => |v| try num.format(a, v, .{}),
        else => error.Syntax,
    };
}

fn expectRich(text: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    const got = try runText(arena.allocator(), &session, text);
    try std.testing.expectEqualStrings(want, got);
}

test "complex numbers stay exact" {
    try expectRich("i*i", "-1");
    try expectRich("(1+i)^2", "2i");
    try expectRich("sqrt(-4)", "2i");
    try expectRich("(2+3i)*(4-i)", "11 + 10i");
    try expectRich("(1+2i)/(3-4i)", "-0.2 + 0.4i");
    try expectRich("abs(3+4i)", "5");
    try expectRich("conj(3+4i)", "3 − 4i");
}

test "matrices" {
    try expectRich("[1,2;3,4]*[5,6;7,8]", "[19, 22; 43, 50]");
    try expectRich("det([1,2;3,4])", "-2");
    try expectRich("inv([1,2;3,4])", "[-2, 1; 1.5, -0.5]");
    try expectRich("[1,2;3,4]^2", "[7, 10; 15, 22]");
    try expectRich("transpose([1,2,3])", "[1; 2; 3]");
    try expectRich("cross([1,0,0],[0,1,0])", "[0, 0, 1]");
    try expectRich("dot([1,2,3],[4,5,6])", "32");
    try expectRich("rk([1,2;2,4])", "1");
}

test "statistics" {
    try expectRich("mean([1,2,3,4])", "2.5");
    try expectRich("median([5,3,1,4])", "3.5");
    try expectRich("stdev([2,4,4,4,5,5,7,9])", "2.1380899353");
    try expectRich("quartile([1,2,3,4,5,6,7,8],1)", "2.75");
}

test "systems of equations" {
    try expectRich("multisolve([x+y=5; x-y=1],[x,y])", "[3, 2]");
    try expectRich("multisolve([x+y+z=6; x-y=0; z=3],[x,y,z])", "[1.5, 1.5, 3]");
}

test "units in entries" {
    try expectRich("5 ft + 3 in", "5.25 ft");
    try expectRich("60 mph to km/h", "96.56064 km/h");
    try expectRich("5 kg * 2 m/s^2", "10 N");
    try expectRich("10 m / 2 s", "5 m/s");
    try expectRich("100 °C to °F", "212 °F");
    try expectRich("3 in to cm", "7.62 cm");
    try expectRich("sqrt(9 m^2)", "3 m");
    try expectRich("1 GiB to MB", "1073.741824 MB");
}
