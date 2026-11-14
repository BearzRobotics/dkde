//! Real numbers of fixed high precision (256 bits, about 77 digits) for the
//! functions that cannot stay exact: exp, ln, sin, cos, atan, roots and powers.
//! A value is m·2^e with an integer mantissa kept to `prec` bits.
//!
//! The functions are series with argument reduction (exp: k·ln 2 and halving;
//! ln: square roots and an atanh series; sin and cos: multiples of π/2, with
//! π computed to as many bits as the argument needs; atan: angle halving),
//! each good to far more digits than the calculator ever shows. Everything is
//! allocated from the caller's arena, as with the other numbers.

const std = @import("std");
const Big = std.math.big.int.Managed;
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, TooLarge, Domain, DivisionByZero };

/// Bits of the mantissa kept after every operation.
pub const prec: usize = 256;

pub const Real = struct {
    /// Signed mantissa.
    m: Big,
    /// Binary exponent: the value is m · 2^e.
    e: i64,

    pub fn isZero(self: Real) bool {
        return self.m.eqlZero();
    }

    pub fn isNegative(self: Real) bool {
        return !self.m.eqlZero() and !self.m.isPositive();
    }
};

fn bigFrom(a: Allocator, v: anytype) Error!Big {
    return Big.initSet(a, v) catch return error.OutOfMemory;
}

pub fn zero(a: Allocator) Error!Real {
    return .{ .m = try bigFrom(a, 0), .e = 0 };
}

pub fn fromInt(a: Allocator, v: i64) Error!Real {
    return norm(a, try bigFrom(a, v), 0);
}

pub fn fromBig(a: Allocator, v: Big) Error!Real {
    return norm(a, v.clone() catch return error.OutOfMemory, 0);
}

/// The float exactly (a float is a dyadic fraction).
pub fn fromF64(a: Allocator, f: f64) Error!Real {
    if (f == 0) return zero(a);
    if (!std.math.isFinite(f)) return error.Domain;
    const bits: u64 = @bitCast(f);
    const exp_bits: i64 = @intCast((bits >> 52) & 0x7ff);
    var mant: u64 = bits & ((1 << 52) - 1);
    var e: i64 = undefined;
    if (exp_bits == 0) {
        e = -1074;
    } else {
        mant |= 1 << 52;
        e = exp_bits - 1075;
    }
    var m = try bigFrom(a, mant);
    if (bits >> 63 == 1) m.negate();
    return norm(a, m, e);
}

/// num/den to `prec` bits.
pub fn fromRatio(a: Allocator, num: Big, den: Big) Error!Real {
    if (den.eqlZero()) return error.DivisionByZero;
    return div(a, try fromBig(a, num), try fromBig(a, den));
}

/// Rounds the mantissa to `prec` bits.
fn norm(a: Allocator, m_in: Big, e_in: i64) Error!Real {
    var m = m_in;
    if (m.eqlZero()) return .{ .m = m, .e = 0 };
    const bits = m.bitCountAbs();
    if (bits <= prec) return .{ .m = m, .e = e_in };
    const sh = bits - prec;
    const negative = !m.isPositive();
    m.abs();
    var half = try bigFrom(a, 1);
    half.shiftLeft(&half, sh - 1) catch return error.OutOfMemory;
    m.add(&m, &half) catch return error.OutOfMemory;
    m.shiftRight(&m, sh) catch return error.OutOfMemory;
    if (negative) m.negate();
    return .{ .m = m, .e = e_in + @as(i64, @intCast(sh)) };
}

pub fn neg(a: Allocator, x: Real) Error!Real {
    var m = x.m.clone() catch return error.OutOfMemory;
    m.negate();
    _ = a;
    return .{ .m = m, .e = x.e };
}

pub fn abs(x: Real) Real {
    var m = x.m;
    m.abs();
    return .{ .m = m, .e = x.e };
}

/// Where the top bit is: log2 of the magnitude, rounded down, plus one.
fn topBit(x: Real) i64 {
    return @as(i64, @intCast(x.m.bitCountAbs())) + x.e;
}

pub fn add(a: Allocator, x: Real, y: Real) Error!Real {
    if (x.isZero()) return y;
    if (y.isZero()) return x;
    // One far below the other (past the kept bits) changes nothing.
    const tx = topBit(x);
    const ty = topBit(y);
    if (tx - ty > @as(i64, prec) + 8) return x;
    if (ty - tx > @as(i64, prec) + 8) return y;
    const e = @min(x.e, y.e);
    var mx = x.m.clone() catch return error.OutOfMemory;
    var my = y.m.clone() catch return error.OutOfMemory;
    mx.shiftLeft(&mx, @intCast(x.e - e)) catch return error.OutOfMemory;
    my.shiftLeft(&my, @intCast(y.e - e)) catch return error.OutOfMemory;
    var r = Big.init(a) catch return error.OutOfMemory;
    r.add(&mx, &my) catch return error.OutOfMemory;
    return norm(a, r, e);
}

pub fn sub(a: Allocator, x: Real, y: Real) Error!Real {
    return add(a, x, try neg(a, y));
}

pub fn mul(a: Allocator, x: Real, y: Real) Error!Real {
    if (x.isZero() or y.isZero()) return zero(a);
    var r = Big.init(a) catch return error.OutOfMemory;
    r.mul(&x.m, &y.m) catch return error.OutOfMemory;
    return norm(a, r, x.e + y.e);
}

pub fn div(a: Allocator, x: Real, y: Real) Error!Real {
    if (y.isZero()) return error.DivisionByZero;
    if (x.isZero()) return zero(a);
    // Enough bits in the dividend for a mantissa of prec + 2 bits.
    const want: i64 = @as(i64, prec) + 2 + @as(i64, @intCast(y.m.bitCountAbs())) - @as(i64, @intCast(x.m.bitCountAbs()));
    const sh: usize = if (want > 0) @intCast(want) else 0;
    var n = x.m.clone() catch return error.OutOfMemory;
    n.shiftLeft(&n, sh) catch return error.OutOfMemory;
    var q = Big.init(a) catch return error.OutOfMemory;
    var r = Big.init(a) catch return error.OutOfMemory;
    q.divTrunc(&r, &n, &y.m) catch return error.OutOfMemory;
    return norm(a, q, x.e - y.e - @as(i64, @intCast(sh)));
}

pub fn order(a: Allocator, x: Real, y: Real) Error!std.math.Order {
    const d = try sub(a, x, y);
    if (d.isZero()) return .eq;
    return if (d.isNegative()) .lt else .gt;
}

/// Multiplies by 2^k.
pub fn scale2(x: Real, k: i64) Real {
    if (x.isZero()) return x;
    return .{ .m = x.m, .e = x.e + k };
}

pub fn toF64(x: Real) f64 {
    if (x.isZero()) return 0;
    // The top 64 bits, then scaled.
    const bits = x.m.bitCountAbs();
    const drop: usize = bits -| 64;
    var m = x.m.clone() catch return std.math.nan(f64);
    const negative = !m.isPositive();
    m.abs();
    m.shiftRight(&m, drop) catch return std.math.nan(f64);
    const f = m.toFloat(f64, .nearest_even)[0];
    const exponent = x.e + @as(i64, @intCast(drop));
    const clamped: i32 = @intCast(std.math.clamp(exponent, -5000, 5000));
    const v = std.math.ldexp(f, clamped);
    return if (negative) -v else v;
}

/// The value as a whole number rounded to nearest, if it is small enough.
pub fn roundToInt(a: Allocator, x: Real) Error!i64 {
    if (x.isZero()) return 0;
    if (topBit(x) > 62) return error.TooLarge;
    var m = x.m.clone() catch return error.OutOfMemory;
    if (x.e >= 0) {
        m.shiftLeft(&m, @intCast(x.e)) catch return error.OutOfMemory;
        return m.toInt(i64) catch error.TooLarge;
    }
    const sh: usize = @intCast(-x.e);
    if (sh > m.bitCountAbs() + 1) return 0;
    const negative = !m.isPositive();
    m.abs();
    var half = try bigFrom(a, 1);
    half.shiftLeft(&half, sh - 1) catch return error.OutOfMemory;
    m.add(&m, &half) catch return error.OutOfMemory;
    m.shiftRight(&m, sh) catch return error.OutOfMemory;
    const v = m.toInt(i64) catch return error.TooLarge;
    return if (negative) -v else v;
}

// ---- constants ---------------------------------------------------------------------------

const cache_alloc = std.heap.page_allocator;
var pi_bits: usize = 0;
var pi_fixed: ?Big = null;
var ln2_bits: usize = 0;
var ln2_fixed: ?Big = null;

/// atan(1/n) · 2^bits, as a fixed-point integer.
fn atanInv(a: Allocator, n: u64, bits: usize) Error!Big {
    var unit = try bigFrom(a, 1);
    unit.shiftLeft(&unit, bits) catch return error.OutOfMemory;
    var nb = try bigFrom(a, n);
    var n2 = try bigFrom(a, n * n);
    var term = Big.init(a) catch return error.OutOfMemory;
    var r = Big.init(a) catch return error.OutOfMemory;
    term.divTrunc(&r, &unit, &nb) catch return error.OutOfMemory;
    var sum = term.clone() catch return error.OutOfMemory;
    var k: u64 = 1;
    var plus = false;
    while (!term.eqlZero()) : (k += 1) {
        var t2 = Big.init(a) catch return error.OutOfMemory;
        t2.divTrunc(&r, &term, &n2) catch return error.OutOfMemory;
        term = t2;
        var d = try bigFrom(a, 2 * k + 1);
        var piece = Big.init(a) catch return error.OutOfMemory;
        piece.divTrunc(&r, &term, &d) catch return error.OutOfMemory;
        if (plus) sum.add(&sum, &piece) catch return error.OutOfMemory else sum.sub(&sum, &piece) catch return error.OutOfMemory;
        plus = !plus;
    }
    _ = &nb;
    return sum;
}

/// π to at least `bits` bits after the point (cached).
fn piFixed(bits: usize) Error!Real {
    const need = bits + 32;
    if (pi_fixed == null or pi_bits < need) {
        const want = @max(need, prec + 96);
        var arena = std.heap.ArenaAllocator.init(cache_alloc);
        defer arena.deinit();
        const a = arena.allocator();
        // π = 16 atan(1/5) − 4 atan(1/239).
        var x = try atanInv(a, 5, want + 8);
        var y = try atanInv(a, 239, want + 8);
        x.shiftLeft(&x, 4) catch return error.OutOfMemory;
        y.shiftLeft(&y, 2) catch return error.OutOfMemory;
        x.sub(&x, &y) catch return error.OutOfMemory;
        x.shiftRight(&x, 8) catch return error.OutOfMemory;
        if (pi_fixed) |*old| old.deinit();
        pi_fixed = x.clone() catch return error.OutOfMemory;
        // Move it to the long-lived allocator.
        var keep = Big.init(cache_alloc) catch return error.OutOfMemory;
        keep.copy(x.toConst()) catch return error.OutOfMemory;
        pi_fixed = keep;
        pi_bits = want;
    }
    return .{ .m = pi_fixed.?, .e = -@as(i64, @intCast(pi_bits)) };
}

/// π, to `prec` bits plus `extra` more (for reducing large angles).
pub fn pi(a: Allocator, extra: usize) Error!Real {
    const p = try piFixed(prec + extra);
    // Copy so that the caller's arithmetic never touches the cache.
    return norm(a, p.m.clone() catch return error.OutOfMemory, p.e);
}

/// π to the full cached precision (not rounded to `prec`), for reducing angles.
fn piWide(a: Allocator, bits: usize) Error!Real {
    _ = a;
    const p = try piFixed(bits);
    return .{ .m = p.m.clone() catch return error.OutOfMemory, .e = p.e };
}

fn ln2Fixed(bits: usize) Error!Real {
    const need = bits + 32;
    if (ln2_fixed == null or ln2_bits < need) {
        const want = @max(need, prec + 96);
        var arena = std.heap.ArenaAllocator.init(cache_alloc);
        defer arena.deinit();
        const a = arena.allocator();
        // ln 2 = 2 atanh(1/3) = 2 Σ 1/((2k+1)·3^(2k+1)).
        var unit = try bigFrom(a, 1);
        unit.shiftLeft(&unit, want + 8) catch return error.OutOfMemory;
        var three = try bigFrom(a, 3);
        var nine = try bigFrom(a, 9);
        var term = Big.init(a) catch return error.OutOfMemory;
        var r = Big.init(a) catch return error.OutOfMemory;
        term.divTrunc(&r, &unit, &three) catch return error.OutOfMemory;
        var sum = term.clone() catch return error.OutOfMemory;
        var k: u64 = 1;
        while (!term.eqlZero()) : (k += 1) {
            var t2 = Big.init(a) catch return error.OutOfMemory;
            t2.divTrunc(&r, &term, &nine) catch return error.OutOfMemory;
            term = t2;
            var d = try bigFrom(a, 2 * k + 1);
            var piece = Big.init(a) catch return error.OutOfMemory;
            piece.divTrunc(&r, &term, &d) catch return error.OutOfMemory;
            sum.add(&sum, &piece) catch return error.OutOfMemory;
        }
        _ = &three;
        sum.shiftLeft(&sum, 1) catch return error.OutOfMemory;
        sum.shiftRight(&sum, 8) catch return error.OutOfMemory;
        if (ln2_fixed) |*old| old.deinit();
        var keep = Big.init(cache_alloc) catch return error.OutOfMemory;
        keep.copy(sum.toConst()) catch return error.OutOfMemory;
        ln2_fixed = keep;
        ln2_bits = want;
    }
    return .{ .m = ln2_fixed.?, .e = -@as(i64, @intCast(ln2_bits)) };
}

pub fn ln2(a: Allocator) Error!Real {
    const p = try ln2Fixed(prec + 64);
    return norm(a, p.m.clone() catch return error.OutOfMemory, p.e);
}

fn wideLn2(a: Allocator) Error!Real {
    _ = a;
    const p = try ln2Fixed(prec + 128);
    return .{ .m = p.m.clone() catch return error.OutOfMemory, .e = p.e };
}

// ---- roots ----------------------------------------------------------------------------------

pub fn sqrt(a: Allocator, x: Real) Error!Real {
    if (x.isNegative()) return error.Domain;
    if (x.isZero()) return zero(a);
    // m·2^e with e even and at least 2·prec + 2 bits of mantissa.
    var m = x.m.clone() catch return error.OutOfMemory;
    var e = x.e;
    const bits: i64 = @intCast(m.bitCountAbs());
    var sh: i64 = 2 * @as(i64, prec) + 2 - bits;
    if (sh < 0) sh = 0;
    if (@mod(e - sh, 2) != 0) sh += 1;
    m.shiftLeft(&m, @intCast(sh)) catch return error.OutOfMemory;
    e -= sh;
    var r = Big.init(a) catch return error.OutOfMemory;
    r.sqrt(&m) catch return error.OutOfMemory;
    return norm(a, r, @divExact(e, 2));
}

// ---- exp and ln -------------------------------------------------------------------------------

pub fn one(a: Allocator) Error!Real {
    return fromInt(a, 1);
}

pub fn exp(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return one(a);
    // Beyond this the result is outside any range the calculator handles.
    if (topBit(x) > 24) return error.TooLarge;
    const l2 = try wideLn2(a);
    // x = k·ln 2 + r.
    const q = try div(a, x, l2);
    const k = try roundToInt(a, q);
    if (k > 3_000_000 or k < -3_000_000) return error.TooLarge;
    var r = try sub(a, x, try mul(a, try fromInt(a, k), l2));
    // exp(r) = exp(r / 2^s)^(2^s).
    const s: i64 = 10;
    r = scale2(r, -s);
    var sum = try one(a);
    var term = try one(a);
    var n: i64 = 1;
    while (n < 400) : (n += 1) {
        term = try div(a, try mul(a, term, r), try fromInt(a, n));
        if (term.isZero() or topBit(term) < -@as(i64, prec) - 8) break;
        sum = try add(a, sum, term);
    }
    var i: i64 = 0;
    while (i < s) : (i += 1) sum = try mul(a, sum, sum);
    return scale2(sum, k);
}

pub fn ln(a: Allocator, x: Real) Error!Real {
    if (x.isZero() or x.isNegative()) return error.Domain;
    // x = y · 2^k with y in [0.7, 1.4].
    var k: i64 = topBit(x);
    var y = scale2(x, -k);
    const lo = try div(a, try fromInt(a, 7), try fromInt(a, 10));
    if ((try order(a, y, lo)) == .lt) {
        y = scale2(y, 1);
        k -= 1;
    }
    // ln y = 16 · ln(y^(1/16)), then 2 atanh((t − 1)/(t + 1)).
    var t = y;
    var i: usize = 0;
    while (i < 4) : (i += 1) t = try sqrt(a, t);
    const o = try one(a);
    const z = try div(a, try sub(a, t, o), try add(a, t, o));
    const z2 = try mul(a, z, z);
    var sum = z;
    var term = z;
    var n: i64 = 3;
    while (n < 2000) : (n += 2) {
        term = try mul(a, term, z2);
        if (term.isZero() or topBit(term) < topBit(sum) - @as(i64, prec) - 8) break;
        sum = try add(a, sum, try div(a, term, try fromInt(a, n)));
    }
    const ly = scale2(sum, 5); // 2 · 16 = 32
    return add(a, ly, try mul(a, try fromInt(a, k), try ln2(a)));
}

// ---- sin, cos ----------------------------------------------------------------------------------

/// sin r and cos r for |r| <= about 0.8.
fn sinCosSmall(a: Allocator, r: Real) Error!struct { s: Real, c: Real } {
    const r2 = try mul(a, r, r);
    var sinv = r;
    var cosv = try one(a);
    var ts = r;
    var tc = try one(a);
    var n: i64 = 1;
    while (n < 600) : (n += 2) {
        tc = try neg(a, try div(a, try mul(a, tc, r2), try fromInt(a, n * (n + 1))));
        ts = try neg(a, try div(a, try mul(a, ts, r2), try fromInt(a, (n + 1) * (n + 2))));
        cosv = try add(a, cosv, tc);
        sinv = try add(a, sinv, ts);
        if (tc.isZero() and ts.isZero()) break;
        const small: i64 = -@as(i64, prec) - 8;
        if ((tc.isZero() or topBit(tc) < small) and (ts.isZero() or topBit(ts) < small + @min(0, topBit(r)))) break;
    }
    return .{ .s = sinv, .c = cosv };
}

pub const SinCos = struct { s: Real, c: Real };

pub fn sinCos(a: Allocator, x: Real) Error!SinCos {
    if (x.isZero()) return .{ .s = try zero(a), .c = try one(a) };
    if (topBit(x) > 4000) return error.TooLarge;
    // x = n·(π/2) + r.
    const extra: usize = @intCast(@max(topBit(x), 0));
    const p = try piWide(a, prec + extra + 32);
    const half_pi = scale2(p, -1);
    const n = try roundToIntBig(a, try div(a, x, half_pi));
    const r = try sub(a, x, try mul(a, n.real, half_pi));
    const sc = try sinCosSmall(a, r);
    return switch (n.quadrant) {
        0 => .{ .s = sc.s, .c = sc.c },
        1 => .{ .s = sc.c, .c = try neg(a, sc.s) },
        2 => .{ .s = try neg(a, sc.s), .c = try neg(a, sc.c) },
        else => .{ .s = try neg(a, sc.c), .c = sc.s },
    };
}

const RoundedBig = struct { real: Real, quadrant: u2 };

/// The nearest whole number to x, as a Real, and it modulo 4.
fn roundToIntBig(a: Allocator, x: Real) Error!RoundedBig {
    if (x.e >= 0) {
        var m = x.m.clone() catch return error.OutOfMemory;
        m.shiftLeft(&m, @intCast(x.e)) catch return error.OutOfMemory;
        const q = quadrantOf(m);
        return .{ .real = .{ .m = m, .e = 0 }, .quadrant = q };
    }
    const sh: usize = @intCast(-x.e);
    var m = x.m.clone() catch return error.OutOfMemory;
    const negative = !m.isPositive();
    m.abs();
    if (sh > m.bitCountAbs() + 1) return .{ .real = try zero(a), .quadrant = 0 };
    var half = try bigFrom(a, 1);
    half.shiftLeft(&half, sh - 1) catch return error.OutOfMemory;
    m.add(&m, &half) catch return error.OutOfMemory;
    m.shiftRight(&m, sh) catch return error.OutOfMemory;
    if (negative) m.negate();
    const q = quadrantOf(m);
    return .{ .real = .{ .m = m, .e = 0 }, .quadrant = q };
}

fn quadrantOf(m: Big) u2 {
    // m mod 4, for a negative m as well (-1 mod 4 = 3).
    const low: u2 = @truncate(m.limbs[0]);
    if (m.isPositive() or m.eqlZero()) return low;
    return 0 -% low;
}

pub fn sin(a: Allocator, x: Real) Error!Real {
    return (try sinCos(a, x)).s;
}

pub fn cos(a: Allocator, x: Real) Error!Real {
    return (try sinCos(a, x)).c;
}

pub fn tan(a: Allocator, x: Real) Error!Real {
    const sc = try sinCos(a, x);
    if (sc.c.isZero()) return error.Domain;
    return div(a, sc.s, sc.c);
}

// ---- atan and the inverse functions --------------------------------------------------------------

pub fn atan(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return x;
    const negative = x.isNegative();
    var v = abs(x);
    const o = try one(a);
    var invert = false;
    if ((try order(a, v, o)) == .gt) {
        v = try div(a, o, v);
        invert = true;
    }
    // atan v = 4 · atan(t) after two halvings of the angle: t = v / (1 + sqrt(1 + v²)).
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const root = try sqrt(a, try add(a, o, try mul(a, v, v)));
        v = try div(a, v, try add(a, o, root));
    }
    const v2 = try mul(a, v, v);
    var sum = v;
    var term = v;
    var n: i64 = 3;
    var plus = false;
    while (n < 3000) : (n += 2) {
        term = try mul(a, term, v2);
        if (term.isZero() or topBit(term) < topBit(sum) - @as(i64, prec) - 8) break;
        const piece = try div(a, term, try fromInt(a, n));
        sum = if (plus) try add(a, sum, piece) else try sub(a, sum, piece);
        plus = !plus;
    }
    var result = scale2(sum, 3); // × 8 for the three halvings
    if (invert) result = try sub(a, scale2(try pi(a, 8), -1), result);
    return if (negative) neg(a, result) else result;
}

pub fn asin(a: Allocator, x: Real) Error!Real {
    const o = try one(a);
    const ax = abs(x);
    switch (try order(a, ax, o)) {
        .gt => return error.Domain,
        .eq => {
            const h = scale2(try pi(a, 8), -1);
            return if (x.isNegative()) neg(a, h) else h;
        },
        .lt => {},
    }
    const root = try sqrt(a, try sub(a, o, try mul(a, x, x)));
    return atan(a, try div(a, x, root));
}

pub fn acos(a: Allocator, x: Real) Error!Real {
    return sub(a, scale2(try pi(a, 8), -1), try asin(a, x));
}

pub fn atan2(a: Allocator, y: Real, x: Real) Error!Real {
    if (x.isZero()) {
        if (y.isZero()) return error.Domain;
        const h = scale2(try pi(a, 8), -1);
        return if (y.isNegative()) neg(a, h) else h;
    }
    const t = try atan(a, try div(a, y, x));
    if (!x.isNegative()) return t;
    const p = try pi(a, 8);
    return if (y.isNegative()) sub(a, t, p) else add(a, t, p);
}

// ---- hyperbolic -----------------------------------------------------------------------------------

pub fn sinh(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return x;
    // Tiny: the series (the difference of exponentials would lose the digits).
    if (topBit(x) < -30) {
        const x2 = try mul(a, x, x);
        var sum = x;
        var term = x;
        var n: i64 = 2;
        while (n < 40) : (n += 2) {
            term = try div(a, try mul(a, term, x2), try fromInt(a, n * (n + 1)));
            if (term.isZero() or topBit(term) < topBit(sum) - @as(i64, prec) - 8) break;
            sum = try add(a, sum, term);
        }
        return sum;
    }
    const ex = try exp(a, x);
    return scale2(try sub(a, ex, try div(a, try one(a), ex)), -1);
}

pub fn cosh(a: Allocator, x: Real) Error!Real {
    const ex = try exp(a, x);
    return scale2(try add(a, ex, try div(a, try one(a), ex)), -1);
}

pub fn tanh(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return x;
    if (topBit(x) > 12) return if (x.isNegative()) neg(a, try one(a)) else one(a);
    const s = try sinh(a, x);
    const c = try cosh(a, x);
    return div(a, s, c);
}

pub fn asinh(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return x;
    const negative = x.isNegative();
    const v = abs(x);
    var r: Real = undefined;
    if (topBit(v) < -30) {
        // x − x³/6 + 3x⁵/40 − …
        const x2 = try mul(a, v, v);
        var sum = v;
        var term = v;
        var n: i64 = 1;
        var plus = false;
        while (n < 40) : (n += 2) {
            // term_{k+1} = −term_k · x² · (2k+1)² / ((2k+2)(2k+3))
            term = try div(a, try mul(a, try mul(a, term, x2), try fromInt(a, n * n)), try fromInt(a, (n + 1) * (n + 2)));
            if (term.isZero() or topBit(term) < topBit(sum) - @as(i64, prec) - 8) break;
            sum = if (plus) try add(a, sum, term) else try sub(a, sum, term);
            plus = !plus;
        }
        r = sum;
    } else {
        const o = try one(a);
        r = try ln(a, try add(a, v, try sqrt(a, try add(a, try mul(a, v, v), o))));
    }
    return if (negative) neg(a, r) else r;
}

pub fn acosh(a: Allocator, x: Real) Error!Real {
    const o = try one(a);
    if ((try order(a, x, o)) == .lt) return error.Domain;
    return ln(a, try add(a, x, try sqrt(a, try sub(a, try mul(a, x, x), o))));
}

pub fn atanh(a: Allocator, x: Real) Error!Real {
    if (x.isZero()) return x;
    const o = try one(a);
    if ((try order(a, abs(x), o)) != .lt) return error.Domain;
    if (topBit(x) < -30) {
        const x2 = try mul(a, x, x);
        var sum = x;
        var term = x;
        var n: i64 = 3;
        while (n < 80) : (n += 2) {
            term = try mul(a, term, x2);
            if (term.isZero() or topBit(term) < topBit(sum) - @as(i64, prec) - 8) break;
            sum = try add(a, sum, try div(a, term, try fromInt(a, n)));
        }
        return sum;
    }
    return scale2(try ln(a, try div(a, try add(a, o, x), try sub(a, o, x))), -1);
}

/// x^y for x > 0.
pub fn pow(a: Allocator, x: Real, y: Real) Error!Real {
    if (x.isZero() or x.isNegative()) return error.Domain;
    return exp(a, try mul(a, y, try ln(a, x)));
}

// ---- tests ------------------------------------------------------------------------------------------

/// x to `digits` decimals (rounded half up), as text.
fn digitsOf(a: Allocator, x: Real, digits: usize) ![]u8 {
    var scale = try fromInt(a, 1);
    var i: usize = 0;
    while (i < digits) : (i += 1) scale = try mul(a, scale, try fromInt(a, 10));
    const v = try mul(a, abs(x), scale);
    var m = try v.m.clone();
    if (v.e >= 0) {
        try m.shiftLeft(&m, @intCast(v.e));
    } else {
        const sh: usize = @intCast(-v.e);
        var half = try Big.initSet(a, 1);
        try half.shiftLeft(&half, sh - 1);
        try m.add(&m, &half);
        try m.shiftRight(&m, sh);
    }
    const raw = try m.toConst().toStringAlloc(a, 10, .lower);
    var padded: std.ArrayList(u8) = .empty;
    var pad: usize = 0;
    while (pad + raw.len < digits + 1) : (pad += 1) try padded.append(a, '0');
    try padded.appendSlice(a, raw);
    const whole = padded.items[0 .. padded.items.len - digits];
    const frac = padded.items[padded.items.len - digits ..];
    return std.fmt.allocPrint(a, "{s}{s}.{s}", .{ if (x.isNegative()) "-" else "", whole, frac });
}

fn expectDigits(a: Allocator, want: []const u8, x: Real, digits: usize) !void {
    try std.testing.expectEqualStrings(want, try digitsOf(a, x, digits));
}

fn ratio(a: Allocator, n: i64, d: i64) !Real {
    return div(a, try fromInt(a, n), try fromInt(a, d));
}

test "pi, e and ln 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDigits(a, "3.1415926535897932384626433832795028841972", try pi(a, 8), 40);
    try expectDigits(a, "2.7182818284590452353602874713526624977572", try exp(a, try one(a)), 40);
    try expectDigits(a, "0.6931471805599453094172321214581765680755", try ln2(a), 40);
}

test "exp and ln" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDigits(a, "7.3890560989306502272304274605750078131803", try exp(a, try fromInt(a, 2)), 40);
    try expectDigits(a, "0.0000000020611536224385578279659403801558209764", try exp(a, try fromInt(a, -20)), 46);
    try expectDigits(a, "2.3025850929940456840179914546843642076011", try ln(a, try fromInt(a, 10)), 40);
    try expectDigits(a, "-6.9077552789821370520539743640530926228033", try ln(a, try ratio(a, 1, 1000)), 40);
    // exp(ln x) comes back.
    try expectDigits(a, "3.1415929203539823008849557522123893805310", try exp(a, try ln(a, try ratio(a, 355, 113))), 40);
}

test "sin, cos, tan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDigits(a, "0.8414709848078965066525023216302989996226", try sin(a, try one(a)), 40);
    try expectDigits(a, "0.5403023058681397174009366074429766037323", try cos(a, try one(a)), 40);
    try expectDigits(a, "1.5574077246549022305069748074583601730873", try tan(a, try one(a)), 40);
    // Large arguments are reduced with enough digits of π.
    try expectDigits(a, "-0.9993608074382124518911", try cos(a, try fromInt(a, 100000)), 22);
    try expectDigits(a, "-0.3499935021712930", try sin(a, try fromInt(a, 1000000)), 16);
}

test "atan, asin, acos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDigits(a, "1.1071487177940905030170654601785370400700", try atan(a, try fromInt(a, 2)), 40);
    try expectDigits(a, "0.5235987755982988730771072305465838140329", try asin(a, try ratio(a, 1, 2)), 40);
    try expectDigits(a, "1.0471975511965977461542144610931676280657", try acos(a, try ratio(a, 1, 2)), 40);
    try expectDigits(a, "0.4636476090008061162142562314612144020285", try atan2(a, try fromInt(a, 1), try fromInt(a, 2)), 40);
}

test "roots, powers and hyperbolic functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectDigits(a, "1.4142135623730950488016887242096980785697", try sqrt(a, try fromInt(a, 2)), 40);
    try expectDigits(a, "1.2599210498948731647672106072782283505703", try pow(a, try fromInt(a, 2), try ratio(a, 1, 3)), 40);
    try expectDigits(a, "1.1752011936438014568823818505956008151557", try sinh(a, try one(a)), 40);
    try expectDigits(a, "1.5430806348152437784779056207570616826015", try cosh(a, try one(a)), 40);
    try expectDigits(a, "0.7615941559557648881194582826047935904128", try tanh(a, try one(a)), 40);
    try expectDigits(a, "0.8813735870195430252326093249797923090282", try asinh(a, try one(a)), 40);
    try expectDigits(a, "1.3169578969248167086250463473079684440270", try acosh(a, try fromInt(a, 2)), 40);
    try expectDigits(a, "0.5493061443340548456976226184612628523237", try atanh(a, try ratio(a, 1, 2)), 40);
}
