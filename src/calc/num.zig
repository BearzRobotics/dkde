//! The calculator's numbers. Arithmetic on fractions of big integers is
//! exact, as in Windows' and GNOME's calculators: 0.1 + 0.2 is 0.3, 1/3 × 3
//! is 1, 2^100 has all its digits. Anything that cannot stay exact (sin,
//! logarithms, roots of non-squares) becomes a 64-bit float, and the result
//! is marked approximate.
//!
//! Every number is allocated in one arena per calculation; nothing is freed
//! one by one.

const std = @import("std");
const Big = std.math.big.int.Managed;

pub const Error = error{ OutOfMemory, TooLarge, DivisionByZero, Domain };

/// Results larger than this many bits (about 40,000 digits) are refused.
pub const max_bits = 1 << 17;

pub const Number = union(enum) {
    /// num/den in lowest terms, den > 0.
    exact: struct { num: Big, den: Big },
    approx: f64,

    pub fn isExact(self: Number) bool {
        return self == .exact;
    }

    pub fn toFloat(self: Number) f64 {
        return switch (self) {
            .approx => |f| f,
            .exact => |e| blk: {
                // The top 64 bits of each part (so neither overflows a float),
                // divided, and scaled back by the bits that were dropped.
                const nb = e.num.bitCountAbs();
                const db = e.den.bitCountAbs();
                const shn: usize = nb -| 64;
                const shd: usize = db -| 64;
                var n = e.num.clone() catch break :blk std.math.nan(f64);
                var d = e.den.clone() catch break :blk std.math.nan(f64);
                n.abs();
                n.shiftRight(&n, shn) catch break :blk std.math.nan(f64);
                d.shiftRight(&d, shd) catch break :blk std.math.nan(f64);
                if (d.eqlZero()) break :blk std.math.nan(f64);
                const ratio = n.toFloat(f64, .nearest_even)[0] / d.toFloat(f64, .nearest_even)[0];
                const scaled = std.math.ldexp(ratio, @as(i32, @intCast(@min(shn, 1 << 30))) - @as(i32, @intCast(@min(shd, 1 << 30))));
                break :blk if (e.num.isPositive()) scaled else -scaled;
            },
        };
    }

    pub fn isZero(self: Number) bool {
        return switch (self) {
            .approx => |f| f == 0,
            .exact => |e| e.num.eqlZero(),
        };
    }

    pub fn isNegative(self: Number) bool {
        return switch (self) {
            .approx => |f| f < 0,
            .exact => |e| !e.num.isPositive() and !e.num.eqlZero(),
        };
    }

    pub fn isInteger(self: Number) bool {
        return switch (self) {
            .approx => |f| f == @floor(f) and std.math.isFinite(f),
            .exact => |e| isOne(e.den),
        };
    }
};

fn isOne(b: Big) bool {
    return b.isPositive() and b.len() == 1 and b.limbs[0] == 1;
}

pub fn fromInt(a: std.mem.Allocator, v: anytype) Error!Number {
    var n = try Big.initSet(a, v);
    _ = &n;
    return .{ .exact = .{ .num = n, .den = try Big.initSet(a, 1) } };
}

pub fn fromFloat(f: f64) Error!Number {
    if (!std.math.isFinite(f)) return error.Domain;
    return .{ .approx = f };
}

/// A ratio, reduced.
pub fn fromParts(a: std.mem.Allocator, num: Big, den: Big) Error!Number {
    if (den.eqlZero()) return error.DivisionByZero;
    var n = num;
    var d = den;
    if (!d.isPositive()) {
        n.negate();
        d.negate();
    }
    var g = try Big.init(a);
    var abs_n = try n.clone();
    abs_n.abs();
    try g.gcd(&abs_n, &d);
    if (!isOne(g) and !g.eqlZero()) {
        var r = try Big.init(a);
        var q = try Big.init(a);
        try q.divTrunc(&r, &n, &g);
        n = q;
        var q2 = try Big.init(a);
        try q2.divTrunc(&r, &d, &g);
        d = q2;
    }
    if (n.bitCountAbs() > max_bits or d.bitCountAbs() > max_bits) return error.TooLarge;
    return .{ .exact = .{ .num = n, .den = d } };
}

/// A decimal number as typed: digits, an optional fraction and exponent,
/// read exactly ("0.1" is 1/10, not the nearest float).
pub fn parseDecimal(a: std.mem.Allocator, text: []const u8) Error!Number {
    var digits: std.ArrayList(u8) = .empty;
    var scale: i64 = 0;
    var i: usize = 0;
    var seen_point = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isDigit(c)) {
            try digits.append(a, c);
            if (seen_point) scale -= 1;
        } else if (c == '.' and !seen_point) {
            seen_point = true;
        } else break;
    }
    if (digits.items.len == 0) return error.Domain;
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        const exp = std.fmt.parseInt(i64, text[i + 1 ..], 10) catch return error.Domain;
        if (@abs(exp) > 40000) return error.TooLarge;
        scale += exp;
    }
    var num = try Big.init(a);
    num.setString(10, digits.items) catch return error.Domain;
    var den = try Big.initSet(a, 1);
    var ten = try Big.initSet(a, 10);
    if (scale > 0) {
        var p = try Big.init(a);
        try p.pow(&ten, @intCast(scale));
        var r = try Big.init(a);
        try r.mul(&num, &p);
        num = r;
    } else if (scale < 0) {
        var p = try Big.init(a);
        try p.pow(&ten, @intCast(-scale));
        den = p;
    }
    return fromParts(a, num, den);
}

/// An integer in base 2, 8, 10 or 16 (programmer mode, 0x... literals).
pub fn parseInteger(a: std.mem.Allocator, text: []const u8, base: u8) Error!Number {
    var n = try Big.init(a);
    n.setString(base, text) catch return error.Domain;
    return .{ .exact = .{ .num = n, .den = try Big.initSet(a, 1) } };
}

// ---- arithmetic ----------------------------------------------------------------

pub fn add(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    if (x == .exact and y == .exact) {
        // a/b + c/d = (ad + cb) / bd
        var ad = try Big.init(a);
        try ad.mul(&x.exact.num, &y.exact.den);
        var cb = try Big.init(a);
        try cb.mul(&y.exact.num, &x.exact.den);
        var n = try Big.init(a);
        try n.add(&ad, &cb);
        var d = try Big.init(a);
        try d.mul(&x.exact.den, &y.exact.den);
        return fromParts(a, n, d);
    }
    return fromFloat(x.toFloat() + y.toFloat());
}

pub fn neg(a: std.mem.Allocator, x: Number) Error!Number {
    return switch (x) {
        .approx => |f| .{ .approx = -f },
        .exact => |e| blk: {
            var n = try e.num.clone();
            n.negate();
            _ = a;
            break :blk .{ .exact = .{ .num = n, .den = e.den } };
        },
    };
}

pub fn sub(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    return add(a, x, try neg(a, y));
}

pub fn mul(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    if (x == .exact and y == .exact) {
        var n = try Big.init(a);
        try n.mul(&x.exact.num, &y.exact.num);
        var d = try Big.init(a);
        try d.mul(&x.exact.den, &y.exact.den);
        return fromParts(a, n, d);
    }
    return fromFloat(x.toFloat() * y.toFloat());
}

pub fn div(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    if (y.isZero()) return error.DivisionByZero;
    if (x == .exact and y == .exact) {
        var n = try Big.init(a);
        try n.mul(&x.exact.num, &y.exact.den);
        var d = try Big.init(a);
        try d.mul(&x.exact.den, &y.exact.num);
        return fromParts(a, n, d);
    }
    return fromFloat(x.toFloat() / y.toFloat());
}

pub fn order(a: std.mem.Allocator, x: Number, y: Number) Error!std.math.Order {
    if (x == .exact and y == .exact) {
        const d = try sub(a, x, y);
        if (d.isZero()) return .eq;
        return if (d.isNegative()) .lt else .gt;
    }
    return std.math.order(x.toFloat(), y.toFloat());
}

/// The whole part, rounded toward minus infinity.
pub fn floor(a: std.mem.Allocator, x: Number) Error!Number {
    return switch (x) {
        .approx => |f| fromFloat(@floor(f)),
        .exact => |e| blk: {
            var q = try Big.init(a);
            var r = try Big.init(a);
            try q.divFloor(&r, &e.num, &e.den);
            break :blk .{ .exact = .{ .num = q, .den = try Big.initSet(a, 1) } };
        },
    };
}

/// x modulo y, with the sign of y (as people expect: -1 mod 3 = 2).
pub fn mod(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    if (y.isZero()) return error.DivisionByZero;
    const q = try floor(a, try div(a, x, y));
    return sub(a, x, try mul(a, q, y));
}

/// x to the power y: exact for whole exponents (and for roots that come
/// out whole, such as 8^(1/3)), a float otherwise.
/// x^y for an exact x and a whole y too large to work out exactly: a float, with ln worked
/// out from x − 1 so that (1 + 10⁻¹⁰)^(10¹⁰) is e and not a rounding error.
fn powBig(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    const xf = x.toFloat();
    if (!(xf > 0)) return error.TooLarge;
    const one = try fromInt(a, 1);
    const r = (try sub(a, x, one)).toFloat();
    const l = if (@abs(r) < 0.5) std.math.log1p(r) else @log(xf);
    const v = @exp(y.toFloat() * l);
    if (!std.math.isFinite(v) or v == 0) return error.TooLarge;
    return fromFloat(v);
}

pub fn pow(a: std.mem.Allocator, x: Number, y: Number) Error!Number {
    if (x == .exact and y == .exact and y.isInteger()) {
        const e = y.exact.num;
        if (e.bitCountAbs() > 31) {
            // Only 0, 1 and -1 stay small.
            if (x.isZero() or (isOne(x.exact.num) and isOne(x.exact.den))) return x;
            return powBig(a, x, y);
        }
        const k: i64 = e.toInt(i64) catch return error.TooLarge;
        const magnitude: u32 = @intCast(@abs(k));
        // Refuse results over the limit before computing them.
        if (@as(u64, @max(x.exact.num.bitCountAbs(), x.exact.den.bitCountAbs())) * magnitude > max_bits + 64) {
            if (!(isOne(x.exact.den) and x.exact.num.bitCountAbs() <= 1)) return powBig(a, x, y);
        }
        var n = try Big.init(a);
        try n.pow(&x.exact.num, magnitude);
        var d = try Big.init(a);
        try d.pow(&x.exact.den, magnitude);
        if (k < 0) {
            if (n.eqlZero()) return error.DivisionByZero;
            return fromParts(a, d, n);
        }
        return fromParts(a, n, d);
    }
    if (x == .exact and y == .exact and isOne(y.exact.num) and !x.isNegative()) {
        // x^(1/n): a whole root if there is one.
        if (y.exact.den.toInt(u32)) |n| {
            if (try root(a, x, n)) |r| return r;
        } else |_| {}
    }
    const xf = x.toFloat();
    const yf = y.toFloat();
    if (xf < 0 and yf != @floor(yf)) {
        // An odd root of a negative number is real: (-8)^(1/3) = -2.
        if (y == .exact and y.exact.den.isOdd()) return neg(a, try pow(a, try neg(a, x), y));
        return error.Domain;
    }
    if (xf == 0 and yf < 0) return error.DivisionByZero;
    return fromFloat(std.math.pow(f64, xf, yf));
}

/// The exact n-th root of x, when its numerator and denominator have one.
pub fn root(a: std.mem.Allocator, x: Number, n: u32) Error!?Number {
    if (x != .exact or n == 0) return null;
    if (x.isNegative() and n % 2 == 0) return null;
    const rn = (try intRoot(a, x.exact.num, n)) orelse return null;
    const rd = (try intRoot(a, x.exact.den, n)) orelse return null;
    return .{ .exact = .{ .num = rn, .den = rd } };
}

/// The integer whose n-th power is v, if there is one.
fn intRoot(a: std.mem.Allocator, v: Big, n: u32) Error!?Big {
    const negative = !v.isPositive() and !v.eqlZero();
    var abs_v = try v.clone();
    abs_v.abs();
    if (abs_v.bitCountAbs() > 4000) return null;
    // A float guess, then check it and its neighbours.
    const f = abs_v.toFloat(f64, .nearest_even)[0];
    const guess = @round(std.math.pow(f64, f, 1.0 / @as(f64, @floatFromInt(n))));
    if (!std.math.isFinite(guess) or guess > 1e15) return null;
    const g: i64 = @intFromFloat(guess);
    var k = g - 1;
    while (k <= g + 1) : (k += 1) {
        if (k < 0) continue;
        var c = try Big.initSet(a, k);
        var p = try Big.init(a);
        try p.pow(&c, n);
        if (p.eql(abs_v)) {
            if (negative) c.negate();
            return c;
        }
    }
    return null;
}

/// n! exactly (up to 3000!).
pub fn factorial(a: std.mem.Allocator, x: Number) Error!Number {
    if (!x.isInteger() or x.isNegative()) return error.Domain;
    const n = intValue(x) orelse return error.TooLarge;
    if (n > 3000) return error.TooLarge;
    var r = try Big.initSet(a, 1);
    var i: i64 = 2;
    while (i <= n) : (i += 1) {
        var k = try Big.initSet(a, i);
        var t = try Big.init(a);
        try t.mul(&r, &k);
        r = t;
        _ = &k;
    }
    return .{ .exact = .{ .num = r, .den = try Big.initSet(a, 1) } };
}

/// The value as an i64 when it is a whole number that fits.
/// Exactly 1.
pub fn isOneNumber(x: Number) bool {
    return x == .exact and isOne(x.exact.num) and isOne(x.exact.den);
}

pub fn intValue(x: Number) ?i64 {
    return switch (x) {
        .approx => |f| if (f == @floor(f) and @abs(f) < 9.2e18) @as(i64, @intFromFloat(f)) else null,
        .exact => |e| if (isOne(e.den)) (e.num.toInt(i64) catch null) else null,
    };
}

/// The value as an i128 when it is a whole number that fits (programmer mode).
pub fn int128(x: Number) ?i128 {
    return switch (x) {
        .approx => |f| if (f == @floor(f) and @abs(f) < 1.7e38) @as(i128, @intFromFloat(f)) else null,
        .exact => |e| if (isOne(e.den)) (e.num.toInt(i128) catch null) else null,
    };
}

pub fn fromI128(a: std.mem.Allocator, v: i128) Error!Number {
    return fromInt(a, v);
}

// ---- writing numbers ---------------------------------------------------------------

pub const Notation = enum { auto, scientific, engineering };

pub const Style = struct {
    /// Digits after the point, at most (results are rounded, then trailing zeros dropped).
    decimals: u8 = 10,
    /// "1,234,567" (with the given separators).
    grouping: bool = false,
    group_sep: []const u8 = ",",
    point: []const u8 = ".",
    notation: Notation = .auto,
};

/// The number as a person reads it, in base 10.
pub fn format(a: std.mem.Allocator, x: Number, style: Style) Error![]u8 {
    switch (x) {
        .approx => |f| return formatFloat(a, f, style),
        .exact => |e| {
            const int_digits = decimalDigits(e.num) -| decimalDigits(e.den);
            // Very large or very small values (and the scientific styles) as d.ddd×10^n.
            // Below a billionth a fixed decimal would show a few digits or none (a
            // nonzero result must not read as 0): d.ddd×10^-n, as for floats.
            var small = false;
            if (style.notation == .auto and int_digits < 1 and !e.num.eqlZero()) {
                var scaled = try e.num.clone();
                scaled.abs();
                var g = try Big.initSet(a, 1_000_000_000);
                try scaled.mul(&scaled, &g);
                small = scaled.order(e.den) == .lt;
            }
            if (style.notation != .auto or int_digits > 30 or small) return formatExactScientific(a, e.num, e.den, style);
            if (isOne(e.den)) {
                const s = try decString(a, e.num);
                return group(a, s, style);
            }
            // Long division to style.decimals + 1 digits, then round.
            var n = try e.num.clone();
            const negative = !n.isPositive();
            n.abs();
            var q = try Big.init(a);
            var r = try Big.init(a);
            try q.divTrunc(&r, &n, &e.den);
            const whole = try decString(a, q);
            var frac: std.ArrayList(u8) = .empty;
            var ten = try Big.initSet(a, 10);
            var exact = false;
            var i: usize = 0;
            while (i < @as(usize, style.decimals) + 1) : (i += 1) {
                if (r.eqlZero()) {
                    exact = true;
                    break;
                }
                var t = try Big.init(a);
                try t.mul(&r, &ten);
                var dq = try Big.init(a);
                var dr = try Big.init(a);
                try dq.divTrunc(&dr, &t, &e.den);
                try frac.append(a, @intCast('0' + (dq.toInt(u8) catch 0)));
                r = dr;
            }
            if (r.eqlZero()) exact = true;
            // A long fraction cut at the decimals shown must keep six significant digits.
            if (!exact and style.notation == .auto and whole.len == 1 and whole[0] == '0') {
                var lz: usize = 0;
                while (lz < frac.items.len and frac.items[lz] == '0') lz += 1;
                if (lz >= 3 and @as(usize, style.decimals) < lz + 6) return formatExactScientific(a, e.num, e.den, style);
            }
            var digits = try std.fmt.allocPrint(a, "{s}{s}", .{ whole, frac.items });
            var point_at = whole.len;
            if (!exact or frac.items.len > style.decimals) {
                // Round half up at style.decimals.
                const keep = point_at + @min(frac.items.len, style.decimals);
                const round_up = frac.items.len > style.decimals and digits[keep] >= '5';
                digits = digits[0..keep];
                if (round_up) {
                    var j = digits.len;
                    while (j > 0) {
                        j -= 1;
                        if (digits[j] == '9') {
                            digits[j] = '0';
                        } else {
                            digits[j] += 1;
                            break;
                        }
                    } else {
                        digits = try std.fmt.allocPrint(a, "1{s}", .{digits});
                        point_at += 1;
                    }
                }
            }
            var w: []const u8 = digits[0..point_at];
            var f: []const u8 = digits[point_at..];
            while (f.len > 0 and f[f.len - 1] == '0') f = f[0 .. f.len - 1];
            if (w.len == 0) w = "0";
            const grouped = try group(a, w, style);
            const sign: []const u8 = if (negative and (!std.mem.allEqual(u8, w, '0') or f.len > 0)) "-" else "";
            if (f.len == 0) return std.fmt.allocPrint(a, "{s}{s}", .{ sign, grouped });
            return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ sign, grouped, style.point, f });
        },
    }
}

/// d.ddd×10^n straight from the fraction, so that a whole number of any size
/// keeps its leading digits (a float would overflow past 10^308). Engineering
/// keeps n a multiple of 3.
fn formatExactScientific(a: std.mem.Allocator, num_in: Big, den: Big, style: Style) Error![]u8 {
    if (num_in.eqlZero()) return a.dupe(u8, "0");
    const negative = !num_in.isPositive();
    var n = try num_in.clone();
    n.abs();
    const sig: usize = @min(style.decimals, 15);
    // Enough digits of n/d: sig + 1 to show, one more to round by, and slack
    // for the estimate of the size being off by one or two.
    const want: i64 = @intCast(sig + 4);
    const est: i64 = @as(i64, @intCast(decimalDigits(n))) - @as(i64, @intCast(decimalDigits(den)));
    const k: i64 = want - est; // multiply n by 10^k (divide by 10^-k when negative)
    // 10^|k| by repeated squaring.
    var scale = try Big.initSet(a, 1);
    var p = try Big.initSet(a, 10);
    var e_: u64 = @intCast(@abs(k));
    while (e_ > 0) : (e_ >>= 1) {
        if (e_ & 1 == 1) try scale.mul(&scale, &p);
        if (e_ > 1) {
            var sq = try Big.init(a);
            try sq.mul(&p, &p);
            p = sq;
        }
    }
    var top = try Big.init(a);
    var bottom = try Big.init(a);
    var q = try Big.init(a);
    var r = try Big.init(a);
    if (k >= 0) {
        try top.mul(&n, &scale);
        try bottom.copy(den.toConst());
    } else {
        var d0 = try den.clone();
        try top.copy(n.toConst());
        try bottom.mul(&d0, &scale);
    }
    try q.divTrunc(&r, &top, &bottom);
    const digits_all = try decString(a, q);
    const L: i64 = @intCast(digits_all.len);
    var exp10: i64 = L - 1 - k; // the exponent of the first digit
    var lead: usize = 1; // digits before the point
    if (style.notation == .engineering) {
        const e3 = @divFloor(exp10, 3) * 3;
        lead = @intCast(exp10 - e3 + 1);
        exp10 = e3;
    }
    const keep = sig + lead; // digits shown
    var digits = try a.dupe(u8, digits_all[0..@min(keep, digits_all.len)]);
    const round_up = digits_all.len > keep and digits_all[keep] >= '5';
    var carried = false;
    if (round_up) {
        var j = digits.len;
        while (j > 0) {
            j -= 1;
            if (digits[j] == '9') {
                digits[j] = '0';
            } else {
                digits[j] += 1;
                break;
            }
        } else carried = true;
    }
    if (carried) {
        digits = try std.fmt.allocPrint(a, "1{s}", .{digits});
        if (style.notation == .engineering and lead == 3) {
            // 999.9 -> 1000: one group higher.
            exp10 += 3;
            digits = digits[0 .. digits.len - 2];
            lead = 1;
        } else if (style.notation == .engineering) {
            lead += 1;
            digits = digits[0 .. digits.len - 1];
        } else {
            exp10 += 1;
            digits = digits[0 .. digits.len - 1];
        }
    }
    var frac_end = digits.len;
    while (frac_end > lead and digits[frac_end - 1] == '0') frac_end -= 1;
    const whole = digits[0..@min(lead, digits.len)];
    const frac = if (frac_end > lead) digits[lead..frac_end] else "";
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}×10^{d}", .{ if (negative) "-" else "", whole, if (frac.len > 0) style.point else "", frac, exp10 });
}

fn decString(a: std.mem.Allocator, b: Big) Error![]u8 {
    return b.toString(a, 10, .lower) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // base 10 is valid
    };
}

fn decimalDigits(b: Big) usize {
    // log10(2) ≈ 0.30103
    return (b.bitCountAbs() * 30103) / 100000 + 1;
}

fn formatFloat(a: std.mem.Allocator, f: f64, style: Style) Error![]u8 {
    if (std.math.isNan(f)) return error.Domain;
    if (std.math.isInf(f)) return error.TooLarge;
    if (f == 0) return a.dupe(u8, "0");
    const m = @abs(f);
    // Fixed decimals only while at least six significant digits survive them.
    const zeros_after_point: i32 = if (m < 1) @intFromFloat(@floor(-std.math.log10(m))) else 0;
    if (style.notation == .auto and m < 1e15 and (m >= 1e-3 or (m >= 1e-9 and @as(i32, style.decimals) >= zeros_after_point + 6))) {
        const text = try std.fmt.allocPrint(a, "{d:.[1]}", .{ f, style.decimals });
        var end = text.len;
        if (std.mem.indexOfScalar(u8, text, '.') != null) {
            while (end > 0 and text[end - 1] == '0') end -= 1;
            if (end > 0 and text[end - 1] == '.') end -= 1;
        }
        const t = text[0..end];
        const negative = t.len > 0 and t[0] == '-';
        const body = if (negative) t[1..] else t;
        const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
        const grouped = try group(a, body[0..dot], style);
        return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ if (negative) "-" else "", grouped, if (dot < body.len) style.point else "", if (dot < body.len) body[dot + 1 ..] else "" });
    }
    // d.ddd×10^n; engineering keeps n a multiple of 3.
    var exp: i32 = @intFromFloat(@floor(std.math.log10(m)));
    if (style.notation == .engineering) exp = @divFloor(exp, 3) * 3;
    var mant = f / std.math.pow(f64, 10, @floatFromInt(exp));
    // Rounding may make 9.9999 into 10.
    const sig = @min(style.decimals, 15);
    const rounded = @round(mant * std.math.pow(f64, 10, @floatFromInt(sig))) / std.math.pow(f64, 10, @floatFromInt(sig));
    if (style.notation != .engineering and @abs(rounded) >= 10) {
        mant = rounded / 10;
        exp += 1;
    } else mant = rounded;
    const m_text = try std.fmt.allocPrint(a, "{d:.[1]}", .{ mant, sig });
    var end = m_text.len;
    if (std.mem.indexOfScalar(u8, m_text, '.') != null) {
        while (end > 0 and m_text[end - 1] == '0') end -= 1;
        if (end > 0 and m_text[end - 1] == '.') end -= 1;
    }
    const mt = try std.mem.replaceOwned(u8, a, m_text[0..end], ".", style.point);
    return std.fmt.allocPrint(a, "{s}×10^{d}", .{ mt, exp });
}

fn group(a: std.mem.Allocator, digits: []const u8, style: Style) Error![]u8 {
    const negative = digits.len > 0 and digits[0] == '-';
    const d = if (negative) digits[1..] else digits;
    if (!style.grouping or d.len <= 3) return a.dupe(u8, digits);
    var out: std.ArrayList(u8) = .empty;
    if (negative) try out.append(a, '-');
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0) try out.appendSlice(a, style.group_sep);
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// "num/den" for an exact non-whole number with a short denominator
/// (shown beside the decimal: 0.3333333333 = 1/3), else null.
pub fn fraction(a: std.mem.Allocator, x: Number) Error!?[]u8 {
    if (x != .exact or isOne(x.exact.den)) return null;
    if (x.exact.den.bitCountAbs() > 40 or x.exact.num.bitCountAbs() > 60) return null;
    const n = try decString(a, x.exact.num);
    const d = try decString(a, x.exact.den);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ n, d });
}

/// A whole number in base 2, 8 or 16, in groups of four (binary, hex) or
/// three (octal) digits; negative numbers as two's complement in `bits`.
pub fn formatBase(a: std.mem.Allocator, v: i128, base: u8, bits: u8, grouped: bool) Error![]u8 {
    if (base == 10) return std.fmt.allocPrint(a, "{d}", .{v});
    const mask: u128 = if (bits >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
    const u: u128 = @as(u128, @bitCast(v)) & mask;
    const raw = switch (base) {
        2 => try std.fmt.allocPrint(a, "{b}", .{u}),
        8 => try std.fmt.allocPrint(a, "{o}", .{u}),
        else => try std.fmt.allocPrint(a, "{X}", .{u}),
    };
    if (!grouped) return raw;
    const size: usize = if (base == 8) 3 else 4;
    var out: std.ArrayList(u8) = .empty;
    for (raw, 0..) |c, i| {
        if (i > 0 and (raw.len - i) % size == 0) try out.append(a, ' ');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// Wraps a whole number into a `bits`-wide two's complement value, as the
/// programmer mode's word sizes do.
pub fn wrap(v: i128, bits: u8) i128 {
    if (bits >= 128) return v;
    const shift: u7 = @intCast(128 - @as(u32, bits));
    return (v << shift) >> shift;
}

// ---- tests -----------------------------------------------------------------------

fn testFormat(a: std.mem.Allocator, x: Number) ![]u8 {
    return format(a, x, .{});
}

test "decimals are exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try add(a, try parseDecimal(a, "0.1"), try parseDecimal(a, "0.2"));
    try std.testing.expectEqualStrings("0.3", try testFormat(a, s));
    const third = try div(a, try fromInt(a, 1), try fromInt(a, 3));
    try std.testing.expectEqualStrings("1", try testFormat(a, try mul(a, third, try fromInt(a, 3))));
    try std.testing.expectEqualStrings("0.3333333333", try testFormat(a, third));
    try std.testing.expectEqualStrings("1/3", (try fraction(a, third)).?);
    try std.testing.expectEqualStrings("0.6666666667", try testFormat(a, try add(a, third, third)));
    try std.testing.expectEqualStrings("-0.5", try testFormat(a, try neg(a, try parseDecimal(a, "0.5"))));
    try std.testing.expectEqualStrings("1500", try testFormat(a, try parseDecimal(a, "1.5e3")));
    try std.testing.expectEqualStrings("0.0015", try testFormat(a, try parseDecimal(a, "1.5e-3")));
}

test "big whole numbers keep every digit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try pow(a, try fromInt(a, 2), try fromInt(a, 100));
    try std.testing.expectEqualStrings("1267650600228229401496703205376", try testFormat(a, p));
    const big = try add(a, try parseDecimal(a, "12345678901234567890"), try fromInt(a, 1));
    try std.testing.expectEqualStrings("12345678901234567891", try testFormat(a, big));
    try std.testing.expectEqualStrings("12,345,678,901,234,567,891", try format(a, big, .{ .grouping = true }));
    const f = try factorial(a, try fromInt(a, 25));
    try std.testing.expectEqualStrings("15511210043330985984000000", try testFormat(a, f));
}

test "powers and roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0.125", try testFormat(a, try pow(a, try fromInt(a, 2), try fromInt(a, -3))));
    const third = try div(a, try fromInt(a, 1), try fromInt(a, 3));
    try std.testing.expectEqualStrings("2", try testFormat(a, try pow(a, try fromInt(a, 8), third)));
    try std.testing.expectEqualStrings("-2", try testFormat(a, try pow(a, try fromInt(a, -8), third)));
    const half = try div(a, try fromInt(a, 1), try fromInt(a, 2));
    try std.testing.expect((try pow(a, try fromInt(a, 2), half)) == .approx);
    try std.testing.expectEqualStrings("1.4142135624", try testFormat(a, try pow(a, try fromInt(a, 2), half)));
    try std.testing.expectError(error.Domain, pow(a, try fromInt(a, -4), half));
    try std.testing.expectError(error.TooLarge, pow(a, try fromInt(a, 10), try fromInt(a, 1_000_000)));
    try std.testing.expectEqualStrings("1", try testFormat(a, try pow(a, try fromInt(a, 1), try parseDecimal(a, "99999999999999"))));
}

test "mod and floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2", try testFormat(a, try mod(a, try fromInt(a, -1), try fromInt(a, 3))));
    try std.testing.expectEqualStrings("1", try testFormat(a, try mod(a, try fromInt(a, 10), try fromInt(a, 3))));
    try std.testing.expectEqualStrings("0.5", try testFormat(a, try mod(a, try parseDecimal(a, "5.5"), try fromInt(a, 1))));
    try std.testing.expectError(error.DivisionByZero, div(a, try fromInt(a, 1), try fromInt(a, 0)));
}

test "floats and scientific notation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("3.1415926536", try format(a, .{ .approx = std.math.pi }, .{}));
    try std.testing.expectEqualStrings("1.5×10^20", try format(a, .{ .approx = 1.5e20 }, .{}));
    try std.testing.expectEqualStrings("12.5×10^3", try format(a, .{ .approx = 12500 }, .{ .notation = .engineering }));
    try std.testing.expectEqualStrings("1.25×10^4", try format(a, .{ .approx = 12500 }, .{ .notation = .scientific }));
    const huge = try pow(a, try fromInt(a, 10), try fromInt(a, 40));
    try std.testing.expectEqualStrings("1×10^40", try format(a, huge, .{}));
    try std.testing.expectEqualStrings("1 234,5", try format(a, try parseDecimal(a, "1234.5"), .{ .grouping = true, .group_sep = " ", .point = "," }));
}

test "programmer formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("FF", try formatBase(a, 255, 16, 64, true));
    try std.testing.expectEqualStrings("1111 1111", try formatBase(a, -1, 2, 8, true));
    try std.testing.expectEqualStrings("377", try formatBase(a, 255, 8, 64, false));
    try std.testing.expectEqual(@as(i128, -1), wrap(255, 8));
    try std.testing.expectEqual(@as(i128, 127), wrap(127, 8));
    try std.testing.expectEqual(@as(i128, 0), wrap(256, 8));
}

test "small results keep six significant digits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // exp(-19.643): not 0.000000003.
    try std.testing.expectEqualStrings("2.9454624597×10^-9", try testFormat(a, .{ .approx = 2.945462459743954e-9 }));
    try std.testing.expectEqualStrings("0.0000294546", try format(a, .{ .approx = 2.945462459743954e-5 }, .{ .decimals = 10 }));
    // A long exact fraction too, but a short exact decimal stays as it is.
    const third_nano = try div(a, try fromInt(a, 1), try fromInt(a, 333333333));
    try std.testing.expectEqualStrings("3.000000003×10^-9", try testFormat(a, third_nano));
    try std.testing.expectEqualStrings("0.000000002", try testFormat(a, try div(a, try fromInt(a, 2), try fromInt(a, 1_000_000_000))));
    try std.testing.expectEqualStrings("0.0003333333", try testFormat(a, try div(a, try fromInt(a, 1), try fromInt(a, 3000))));
}

test "a power too large to work out exactly is a float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try add(a, try fromInt(a, 1), try parseDecimal(a, "1e-10"));
    const p = try pow(a, base, try fromInt(a, 10_000_000_000));
    try std.testing.expectApproxEqRel(@as(f64, 2.718281828459045), p.toFloat(), 1e-9);
    try std.testing.expectError(error.TooLarge, pow(a, try fromInt(a, 7), try fromInt(a, 10_000_000_000)));
}
