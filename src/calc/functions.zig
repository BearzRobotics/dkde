//! The calculator's library of named functions that take plain numbers:
//! special functions, number theory, probability distributions and the
//! money functions of a spreadsheet. `find` says whether a name is one of
//! them and how many arguments it takes; `call` works it out.
//!
//! Exact results (a Fibonacci number, 30!!) stay exact; the rest are floats,
//! good to about 14 digits, and are checked against Qalculate.

const std = @import("std");
const num = @import("num.zig");
const Number = num.Number;
const Error = num.Error;

const two_over_sqrt_pi: f64 = 1.1283791670955126;

pub const Ctx = struct {
    a: std.mem.Allocator,
    /// Radians in one unit of the current angle (π/180 for degrees).
    rad_per_unit: f64,
};

pub const Def = struct {
    name: []const u8,
    min: u8,
    max: u8,
    run: *const fn (*const Ctx, []const Number) Error!Number,
};

/// The other names a function goes by.
const aliases = [_][2][]const u8{
    .{ "arcsin", "asin" },     .{ "arccos", "acos" },    .{ "arctan", "atan" },  .{ "arsinh", "asinh" },
    .{ "arcosh", "acosh" },    .{ "artanh", "atanh" },   .{ "sgn", "sign" },     .{ "int", "trunc" },
    .{ "binomial", "ncr" },    .{ "comb", "ncr" },       .{ "perm", "npr" },     .{ "factorial", "fact" },
    .{ "arcsec", "asec" },     .{ "arccsc", "acsc" },    .{ "arccot", "acot" },  .{ "arsech", "asech" },
    .{ "arcsch", "acsch" },    .{ "arcoth", "acoth" },   .{ "fib", "fibonacci" }, .{ "prime", "isprime" },
};

pub fn canonical(name: []const u8) []const u8 {
    for (aliases) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
    return name;
}

pub fn find(name: []const u8) ?*const Def {
    const n = canonical(name);
    for (&table) |*d| if (std.mem.eql(u8, d.name, n)) return d;
    return null;
}

pub fn isKnown(name: []const u8) bool {
    return find(name) != null;
}

// ---- helpers ------------------------------------------------------------------------

fn fl(x: Number) f64 {
    return x.toFloat();
}

fn res(v: f64) Error!Number {
    return num.fromFloat(v);
}

fn whole(ctx: *const Ctx, v: i128) Error!Number {
    return num.fromI128(ctx.a, v);
}

fn flag(args: []const Number, i: usize) bool {
    return i < args.len and !args[i].isZero();
}

fn opt(args: []const Number, i: usize, default: f64) f64 {
    return if (i < args.len) fl(args[i]) else default;
}

fn int(x: Number) Error!i128 {
    return num.int128(x) orelse error.Domain;
}

// ---- trigonometry and the like --------------------------------------------------------

fn sech(_: *const Ctx, a: []const Number) Error!Number {
    return res(1 / std.math.cosh(fl(a[0])));
}
fn csch(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v == 0) return error.Domain;
    return res(1 / std.math.sinh(v));
}
fn coth(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v == 0) return error.Domain;
    return res(1 / std.math.tanh(v));
}
fn asech(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v <= 0 or v > 1) return error.Domain;
    return res(std.math.acosh(1 / v));
}
fn acsch(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v == 0) return error.Domain;
    return res(std.math.asinh(1 / v));
}
fn acoth(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (@abs(v) <= 1) return error.Domain;
    return res(std.math.atanh(1 / v));
}
fn asec(c: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (@abs(v) < 1) return error.Domain;
    return res(std.math.acos(1 / v) / c.rad_per_unit);
}
fn acsc(c: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (@abs(v) < 1) return error.Domain;
    return res(std.math.asin(1 / v) / c.rad_per_unit);
}
fn acot(c: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v == 0) return res(std.math.pi / 2.0 / c.rad_per_unit);
    return res(std.math.atan(1 / v) / c.rad_per_unit);
}
fn sinc(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    if (v == 0) return res(1);
    return res(@sin(v) / v);
}
fn radtodef(c: *const Ctx, a: []const Number) Error!Number {
    return res(fl(a[0]) / c.rad_per_unit);
}
fn deftorad(c: *const Ctx, a: []const Number) Error!Number {
    return res(fl(a[0]) * c.rad_per_unit);
}
fn exp2(_: *const Ctx, a: []const Number) Error!Number {
    return res(std.math.pow(f64, 2, fl(a[0])));
}
fn exp10(_: *const Ctx, a: []const Number) Error!Number {
    return res(std.math.pow(f64, 10, fl(a[0])));
}
fn sqrtpi(_: *const Ctx, a: []const Number) Error!Number {
    return res(@sqrt(std.math.pi * fl(a[0])));
}

// ---- gamma, error function, zeta ------------------------------------------------------

fn lgammaf(x: f64) f64 {
    return std.math.lgamma(f64, x);
}

pub fn gammaf(x: f64) f64 {
    return std.math.gamma(f64, x);
}

fn gamma(c: *const Ctx, a: []const Number) Error!Number {
    const x = a[0];
    // A whole number gives the exact factorial.
    if (num.intValue(x)) |n| {
        if (n <= 0) return error.Domain;
        if (n < 20000) return num.factorial(c.a, try num.fromInt(c.a, n - 1));
    }
    const v = fl(x);
    if (v <= 0 and v == @floor(v)) return error.Domain;
    return res(gammaf(v));
}

fn beta(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const y = fl(a[1]);
    if (x <= 0 or y <= 0) return error.Domain;
    return res(@exp(lgammaf(x) + lgammaf(y) - lgammaf(x + y)));
}

fn digammaf(x0: f64) f64 {
    var x = x0;
    var r: f64 = 0;
    if (x <= 0 and x == @floor(x)) return std.math.nan(f64);
    if (x < 0) return digammaf(1 - x) - std.math.pi / @tan(std.math.pi * x);
    while (x < 10) : (x += 1) r -= 1 / x;
    const f = 1 / (x * x);
    return r + @log(x) - 0.5 / x - f * (1.0 / 12.0 - f * (1.0 / 120.0 - f * (1.0 / 252.0 - f * (1.0 / 240.0 - f * (1.0 / 132.0 - f * (691.0 / 32760.0 - f / 12.0))))));
}

fn digamma(_: *const Ctx, a: []const Number) Error!Number {
    const v = digammaf(fl(a[0]));
    if (std.math.isNan(v)) return error.Domain;
    return res(v);
}

fn erffc(x: f64) f64 {
    // erfc for x >= 0 by continued fraction (x > 2) or from the series.
    if (x < 2) return 1 - erfSeries(x);
    var f: f64 = 0;
    var k: f64 = 60;
    while (k >= 1) : (k -= 1) f = k / 2 / (x + f);
    return @exp(-x * x) / (std.math.sqrt(std.math.pi)) / (x + f);
}

fn erfSeries(x: f64) f64 {
    // 2/sqrt(pi) * sum (-1)^n x^(2n+1) / (n! (2n+1)), in the form that does not cancel:
    // erf(x) = 2/sqrt(pi) * exp(-x^2) * sum 2^n x^(2n+1) / (1·3·5···(2n+1)).
    var term = x;
    var sum = x;
    var n: f64 = 0;
    while (n < 200) : (n += 1) {
        term *= 2 * x * x / (2 * n + 3);
        sum += term;
        if (@abs(term) < 1e-17 * @abs(sum)) break;
    }
    return two_over_sqrt_pi * @exp(-x * x) * sum;
}

pub fn erff(x: f64) f64 {
    if (x < 0) return -erff(-x);
    if (x < 2) return erfSeries(x);
    return 1 - erffc(x);
}

pub fn erfcf(x: f64) f64 {
    if (x < 0) return 2 - erfcf(-x);
    return erffc(x);
}

fn erf(_: *const Ctx, a: []const Number) Error!Number {
    return res(erff(fl(a[0])));
}
fn erfc(_: *const Ctx, a: []const Number) Error!Number {
    return res(erfcf(fl(a[0])));
}

fn erfinvf(y: f64) f64 {
    if (y <= -1 or y >= 1) return std.math.nan(f64);
    if (y == 0) return 0;
    // Start from a rational guess, then Newton steps on erf.
    const w = -@log((1 - y) * (1 + y));
    var x: f64 = if (w < 5) blk: {
        const t = w - 2.5;
        var p: f64 = 2.81022636e-08;
        p = 3.43273939e-07 + p * t;
        p = -3.5233877e-06 + p * t;
        p = -4.39150654e-06 + p * t;
        p = 0.00021858087 + p * t;
        p = -0.00125372503 + p * t;
        p = -0.00417768164 + p * t;
        p = 0.246640727 + p * t;
        p = 1.50140941 + p * t;
        break :blk p * y;
    } else blk: {
        const t = @sqrt(w) - 3;
        var p: f64 = -0.000200214257;
        p = 0.000100950558 + p * t;
        p = 0.00134934322 + p * t;
        p = -0.00367342844 + p * t;
        p = 0.00573950773 + p * t;
        p = -0.0076224613 + p * t;
        p = 0.00943887047 + p * t;
        p = 1.00167406 + p * t;
        p = 2.83297682 + p * t;
        break :blk p * y;
    };
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const err = erff(x) - y;
        x -= err / (two_over_sqrt_pi * @exp(-x * x));
    }
    return x;
}

fn erfinv(_: *const Ctx, a: []const Number) Error!Number {
    const v = erfinvf(fl(a[0]));
    if (std.math.isNan(v)) return error.Domain;
    return res(v);
}

fn probitf(p: f64) f64 {
    return std.math.sqrt2 * erfinvf(2 * p - 1);
}

fn probit(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    if (p <= 0 or p >= 1) return error.Domain;
    return res(probitf(p));
}

fn zetaf(s: f64) f64 {
    if (s == 1) return std.math.inf(f64);
    if (s < 0) {
        // Functional equation, valid for s < 0.
        return std.math.pow(f64, 2, s) * std.math.pow(f64, std.math.pi, s - 1) * @sin(std.math.pi * s / 2) * gammaf(1 - s) * zetaf(1 - s);
    }
    // Euler-Maclaurin with N terms and a few corrections.
    const N: f64 = 20;
    var sum: f64 = 0;
    var k: f64 = 1;
    while (k < N) : (k += 1) sum += std.math.pow(f64, k, -s);
    sum += std.math.pow(f64, N, 1 - s) / (s - 1) + 0.5 * std.math.pow(f64, N, -s);
    // Bernoulli terms B2k/(2k)!
    const b = [_]f64{ 1.0 / 6.0, -1.0 / 30.0, 1.0 / 42.0, -1.0 / 30.0, 5.0 / 66.0, -691.0 / 2730.0, 7.0 / 6.0, -3617.0 / 510.0 };
    var fact: f64 = 1; // (2j)!
    var rising: f64 = s; // s(s+1)...(s+2j-2)
    var j: usize = 1;
    while (j <= b.len) : (j += 1) {
        const jj: f64 = @floatFromInt(j);
        fact *= (2 * jj - 1) * (2 * jj);
        if (j > 1) rising *= (s + 2 * jj - 3) * (s + 2 * jj - 2);
        sum += b[j - 1] / fact * rising * std.math.pow(f64, N, -s - 2 * jj + 1);
    }
    return sum;
}

fn zeta(_: *const Ctx, a: []const Number) Error!Number {
    const s = fl(a[0]);
    if (s == 1) return error.Domain;
    return res(zetaf(s));
}

fn lambertw(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    if (x < -1.0 / std.math.e) return error.Domain;
    if (x == 0) return res(0);
    var w: f64 = if (x < 1) x * (1 - x + 1.5 * x * x) else @log(x) - @log(@max(1.0, @log(x)));
    if (x < -0.3) w = -1 + @sqrt(2 * (std.math.e * x + 1));
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const ew = @exp(w);
        const f = w * ew - x;
        const d = ew * (w + 1) - (w + 2) * f / (2 * w + 2);
        if (d == 0) break;
        const step = f / d;
        w -= step;
        if (@abs(step) < 1e-16 * (1 + @abs(w))) break;
    }
    return res(w);
}

fn sigmoid(_: *const Ctx, a: []const Number) Error!Number {
    return res(1 / (1 + @exp(-fl(a[0]))));
}
fn logit(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    if (p <= 0 or p >= 1) return error.Domain;
    return res(@log(p / (1 - p)));
}
fn heaviside(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    return res(if (v < 0) 0 else if (v > 0) 1 else 0.5);
}
fn ramp(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    return res((v + @abs(v)) / 2);
}
fn rectangular(_: *const Ctx, a: []const Number) Error!Number {
    const v = fl(a[0]);
    return res(if (@abs(v) < 0.5) 1 else if (@abs(v) == 0.5) 0.5 else 0);
}
fn triangular(_: *const Ctx, a: []const Number) Error!Number {
    const v = @abs(fl(a[0]));
    return res(if (v < 1) 1 - v else 0);
}
fn kronecker(c: *const Ctx, a: []const Number) Error!Number {
    return whole(c, if ((try num.order(c.a, a[0], a[1])) == .eq) 1 else 0);
}

// ---- whole numbers --------------------------------------------------------------------

fn wholeArg(x: Number) Error!i64 {
    return num.intValue(x) orelse error.Domain;
}

fn isPrimeU(n: u64) bool {
    if (n < 2) return false;
    const small = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    for (small) |p| {
        if (n == p) return true;
        if (n % p == 0) return false;
    }
    var d = n - 1;
    var s: u6 = 0;
    while (d % 2 == 0) : (d /= 2) s += 1;
    for (small) |a| {
        var x = powModU(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var comp = true;
        var r: u6 = 1;
        while (r < s) : (r += 1) {
            x = mulModU(x, x, n);
            if (x == n - 1) {
                comp = false;
                break;
            }
        }
        if (comp) return false;
    }
    return true;
}

fn mulModU(a: u64, b: u64, m: u64) u64 {
    return @intCast((@as(u128, a) * @as(u128, b)) % m);
}

fn powModU(base: u64, e0: u64, m: u64) u64 {
    var r: u64 = 1 % m;
    var b = base % m;
    var e = e0;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) r = mulModU(r, b, m);
        b = mulModU(b, b, m);
    }
    return r;
}

fn primeArg(x: Number) Error!u64 {
    const v = try wholeArg(x);
    if (v < 0) return error.Domain;
    return @intCast(v);
}

fn isprime(c: *const Ctx, a: []const Number) Error!Number {
    const n = num.intValue(a[0]) orelse return whole(c, 0);
    return whole(c, if (n >= 2 and isPrimeU(@intCast(n))) 1 else 0);
}

fn nextprime(c: *const Ctx, a: []const Number) Error!Number {
    var n = try primeArg(a[0]);
    if (n < 2) n = 2;
    while (!isPrimeU(n)) : (n += 1) {
        if (n > std.math.maxInt(i64) - 1000) return error.TooLarge;
    }
    return whole(c, n);
}

fn prevprime(c: *const Ctx, a: []const Number) Error!Number {
    var n = try primeArg(a[0]);
    if (n < 2) return error.Domain;
    while (n >= 2 and !isPrimeU(n)) n -= 1;
    if (n < 2) return error.Domain;
    return whole(c, n);
}

fn sieve(a: std.mem.Allocator, limit: usize) Error![]bool {
    const s = try a.alloc(bool, limit + 1);
    @memset(s, true);
    s[0] = false;
    if (limit >= 1) s[1] = false;
    var i: usize = 2;
    while (i * i <= limit) : (i += 1) {
        if (!s[i]) continue;
        var j = i * i;
        while (j <= limit) : (j += i) s[j] = false;
    }
    return s;
}

fn nthprime(c: *const Ctx, a: []const Number) Error!Number {
    const n = try primeArg(a[0]);
    if (n < 1) return error.Domain;
    if (n > 3_000_000) return error.TooLarge;
    const nf: f64 = @floatFromInt(n);
    const limit: usize = if (n < 6) 15 else @intFromFloat(nf * (@log(nf) + @log(@log(nf))) + 10);
    const s = try sieve(c.a, limit);
    defer c.a.free(s);
    var count: u64 = 0;
    for (s, 0..) |is, i| {
        if (is) {
            count += 1;
            if (count == n) return whole(c, i);
        }
    }
    return error.TooLarge;
}

fn primepi(c: *const Ctx, a: []const Number) Error!Number {
    const n = try primeArg(a[0]);
    if (n > 100_000_000) return error.TooLarge;
    const s = try sieve(c.a, @intCast(n));
    defer c.a.free(s);
    var count: i128 = 0;
    for (s) |is| count += @intFromBool(is);
    return whole(c, count);
}

fn totient(c: *const Ctx, a: []const Number) Error!Number {
    var n = try primeArg(a[0]);
    if (n == 0) return error.Domain;
    var result = n;
    var p: u64 = 2;
    while (p * p <= n) : (p += 1) {
        if (n % p == 0) {
            while (n % p == 0) n /= p;
            result -= result / p;
        }
        if (p > 2_000_000_000) return error.TooLarge;
    }
    if (n > 1) result -= result / n;
    return whole(c, result);
}

fn fibonacci(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    const m: u64 = @intCast(@abs(n));
    if (m > 100_000) return error.TooLarge;
    // Fast doubling on exact numbers.
    var x = try num.fromInt(c.a, 0); // F(k)
    var y = try num.fromInt(c.a, 1); // F(k+1)
    var bit: i64 = 63 - @as(i64, @clz(m | 1));
    if (m == 0) return x;
    while (bit >= 0) : (bit -= 1) {
        const two_y = try num.mul(c.a, try num.fromInt(c.a, 2), y);
        const t = try num.mul(c.a, x, try num.sub(c.a, two_y, x)); // F(2k)
        const u = try num.add(c.a, try num.mul(c.a, x, x), try num.mul(c.a, y, y)); // F(2k+1)
        if ((m >> @intCast(bit)) & 1 == 1) {
            x = u;
            y = try num.add(c.a, t, u);
        } else {
            x = t;
            y = u;
        }
    }
    if (n < 0 and m % 2 == 0) return num.neg(c.a, x);
    return x;
}

fn factorial2(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    if (n < -1) return error.Domain;
    if (n > 50_000) return error.TooLarge;
    var acc = try num.fromInt(c.a, 1);
    var k = n;
    while (k > 1) : (k -= 2) acc = try num.mul(c.a, acc, try num.fromInt(c.a, k));
    return acc;
}

fn hyperfactorial(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    if (n < 0) return error.Domain;
    if (n > 3000) return error.TooLarge;
    var acc = try num.fromInt(c.a, 1);
    var k: i64 = 2;
    while (k <= n) : (k += 1) acc = try num.mul(c.a, acc, try num.pow(c.a, try num.fromInt(c.a, k), try num.fromInt(c.a, k)));
    return acc;
}

fn superfactorial(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    if (n < 0) return error.Domain;
    if (n > 3000) return error.TooLarge;
    var acc = try num.fromInt(c.a, 1);
    var f = try num.fromInt(c.a, 1);
    var k: i64 = 2;
    while (k <= n) : (k += 1) {
        f = try num.mul(c.a, f, try num.fromInt(c.a, k));
        acc = try num.mul(c.a, acc, f);
    }
    return acc;
}

fn derangements(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    if (n < 0) return error.Domain;
    if (n > 20_000) return error.TooLarge;
    // D(0) = 1, D(1) = 0, D(k) = k·D(k-1) + (-1)^k.
    var d = try num.fromInt(c.a, 1);
    var k: i64 = 1;
    while (k <= n) : (k += 1) {
        const sign: i64 = if (@rem(k, 2) == 0) 1 else -1;
        d = try num.add(c.a, try num.mul(c.a, try num.fromInt(c.a, k), d), try num.fromInt(c.a, sign));
    }
    return d;
}

fn bernoulli(c: *const Ctx, a: []const Number) Error!Number {
    const n = try wholeArg(a[0]);
    if (n < 0) return error.Domain;
    if (n > 600) return error.TooLarge;
    if (n == 1) return num.div(c.a, try num.fromInt(c.a, -1), try num.fromInt(c.a, 2));
    if (n > 1 and @rem(n, 2) == 1) return num.fromInt(c.a, 0);
    // Akiyama-Tanigawa.
    const m: usize = @intCast(n);
    const row = try c.a.alloc(Number, m + 1);
    var j: usize = 0;
    while (j <= m) : (j += 1) {
        row[j] = try num.div(c.a, try num.fromInt(c.a, 1), try num.fromInt(c.a, @as(i64, @intCast(j + 1))));
        var k = j;
        while (k >= 1) : (k -= 1) {
            row[k - 1] = try num.mul(c.a, try num.fromInt(c.a, @as(i64, @intCast(k))), try num.sub(c.a, row[k - 1], row[k]));
        }
    }
    return row[0];
}

fn powmod(c: *const Ctx, a: []const Number) Error!Number {
    const base = try int(a[0]);
    const e = try int(a[1]);
    const m = try int(a[2]);
    if (m <= 0 or m > std.math.maxInt(i64)) return error.Domain;
    const mm: u64 = @intCast(m);
    var b: u64 = @intCast(@mod(base, m));
    var ee: u64 = undefined;
    if (e < 0) {
        // Modular inverse by the extended Euclid, then a positive power.
        var r0: i128 = m;
        var r1: i128 = b;
        var t0: i128 = 0;
        var t1: i128 = 1;
        while (r1 != 0) {
            const q = @divTrunc(r0, r1);
            const r2 = r0 - q * r1;
            r0 = r1;
            r1 = r2;
            const t2 = t0 - q * t1;
            t0 = t1;
            t1 = t2;
        }
        if (r0 != 1) return error.Domain;
        b = @intCast(@mod(t0, m));
        ee = @intCast(-e);
    } else ee = @intCast(e);
    return whole(c, powModU(b, ee, mm));
}

fn clip(c: *const Ctx, a: []const Number) Error!Number {
    var v = a[0];
    if ((try num.order(c.a, v, a[1])) == .lt) v = a[1];
    if ((try num.order(c.a, v, a[2])) == .gt) v = a[2];
    return v;
}

fn numerator(c: *const Ctx, a: []const Number) Error!Number {
    return switch (a[0]) {
        .exact => |e| num.fromParts(c.a, e.num, try @TypeOf(e.den).initSet(c.a, 1)),
        .approx, .big => error.Domain,
    };
}

fn denominator(c: *const Ctx, a: []const Number) Error!Number {
    return switch (a[0]) {
        .exact => |e| num.fromParts(c.a, e.den, try @TypeOf(e.den).initSet(c.a, 1)),
        .approx, .big => error.Domain,
    };
}

fn truncated(c: *const Ctx, x: Number) Error!Number {
    return if (x.isNegative()) num.neg(c.a, try num.floor(c.a, try num.neg(c.a, x))) else num.floor(c.a, x);
}

fn div(c: *const Ctx, a: []const Number) Error!Number {
    return truncated(c, try num.div(c.a, a[0], a[1]));
}

fn rem(c: *const Ctx, a: []const Number) Error!Number {
    const q = try truncated(c, try num.div(c.a, a[0], a[1]));
    return num.sub(c.a, a[0], try num.mul(c.a, q, a[1]));
}

fn neg(c: *const Ctx, a: []const Number) Error!Number {
    return num.neg(c.a, a[0]);
}

fn subtract(c: *const Ctx, a: []const Number) Error!Number {
    return num.sub(c.a, a[0], a[1]);
}

fn square(c: *const Ctx, a: []const Number) Error!Number {
    return num.mul(c.a, a[0], a[0]);
}

fn even(c: *const Ctx, a: []const Number) Error!Number {
    const n = num.int128(a[0]) orelse return whole(c, 0);
    return whole(c, @intFromBool(@mod(n, 2) == 0));
}

fn odd(c: *const Ctx, a: []const Number) Error!Number {
    const n = num.int128(a[0]) orelse return whole(c, 0);
    return whole(c, @intFromBool(@mod(n, 2) != 0));
}

// ---- incomplete gamma and beta, and the distributions built on them ---------------------

/// Regularized lower incomplete gamma P(a, x).
fn gammaP(a: f64, x: f64) f64 {
    if (x <= 0) return 0;
    if (x < a + 1) {
        var ap = a;
        var del: f64 = 1 / a;
        var sum = del;
        var n: usize = 0;
        while (n < 1000) : (n += 1) {
            ap += 1;
            del *= x / ap;
            sum += del;
            if (@abs(del) < @abs(sum) * 1e-16) break;
        }
        return sum * @exp(-x + a * @log(x) - lgammaf(a));
    }
    return 1 - gammaQcf(a, x);
}

fn gammaQcf(a: f64, x: f64) f64 {
    const tiny: f64 = 1e-300;
    var b = x + 1 - a;
    var c: f64 = 1 / tiny;
    var d = 1 / b;
    var h = d;
    var i: f64 = 1;
    while (i < 1000) : (i += 1) {
        const an = -i * (i - a);
        b += 2;
        d = an * d + b;
        if (@abs(d) < tiny) d = tiny;
        c = b + an / c;
        if (@abs(c) < tiny) c = tiny;
        d = 1 / d;
        const del = d * c;
        h *= del;
        if (@abs(del - 1) < 1e-16) break;
    }
    return @exp(-x + a * @log(x) - lgammaf(a)) * h;
}

/// Regularized upper incomplete gamma Q(a, x).
fn gammaQ(a: f64, x: f64) f64 {
    if (x <= 0) return 1;
    if (x < a + 1) return 1 - gammaP(a, x);
    return gammaQcf(a, x);
}

fn betacf(a: f64, b: f64, x: f64) f64 {
    const tiny: f64 = 1e-300;
    const qab = a + b;
    const qap = a + 1;
    const qam = a - 1;
    var c: f64 = 1;
    var d = 1 - qab * x / qap;
    if (@abs(d) < tiny) d = tiny;
    d = 1 / d;
    var h = d;
    var m: f64 = 1;
    while (m < 1000) : (m += 1) {
        const m2 = 2 * m;
        var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
        d = 1 + aa * d;
        if (@abs(d) < tiny) d = tiny;
        c = 1 + aa / c;
        if (@abs(c) < tiny) c = tiny;
        d = 1 / d;
        h *= d * c;
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
        d = 1 + aa * d;
        if (@abs(d) < tiny) d = tiny;
        c = 1 + aa / c;
        if (@abs(c) < tiny) c = tiny;
        d = 1 / d;
        const del = d * c;
        h *= del;
        if (@abs(del - 1) < 1e-16) break;
    }
    return h;
}

/// Regularized incomplete beta I_x(a, b).
fn betaI(a: f64, b: f64, x: f64) f64 {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    const bt = @exp(lgammaf(a + b) - lgammaf(a) - lgammaf(b) + a * @log(x) + b * std.math.log1p(-x));
    if (x < (a + 1) / (a + b + 2)) return bt * betacf(a, b, x) / a;
    return 1 - bt * betacf(b, a, 1 - x) / b;
}

/// The x where an increasing function `cdf` reaches `p`, found by bracketing and bisection.
fn invert(comptime cdf: fn (f64, f64, f64, f64) f64, p: f64, a: f64, b: f64, c: f64, lo0: f64, hi0: f64) f64 {
    var lo = lo0;
    var hi = hi0;
    if (std.math.isInf(hi)) {
        hi = 1;
        while (cdf(hi, a, b, c) < p and hi < 1e300) hi *= 2;
    }
    if (std.math.isInf(lo)) {
        lo = -1;
        while (cdf(lo, a, b, c) > p and lo > -1e300) lo *= 2;
    }
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const mid = lo + (hi - lo) / 2;
        if (mid == lo or mid == hi) break;
        if (cdf(mid, a, b, c) < p) lo = mid else hi = mid;
    }
    return lo + (hi - lo) / 2;
}

fn cdfChi(x: f64, k: f64, _: f64, _: f64) f64 {
    return gammaP(k / 2, x / 2);
}
fn cdfT(x: f64, v: f64, _: f64, _: f64) f64 {
    const tail = betaI(v / 2, 0.5, v / (x * x + v)) / 2;
    return if (x < 0) tail else 1 - tail;
}
fn cdfF(x: f64, d1: f64, d2: f64, _: f64) f64 {
    return betaI(d1 / 2, d2 / 2, d1 * x / (d1 * x + d2));
}

fn needProb(p: f64) Error!void {
    if (std.math.isNan(p) or p < 0 or p > 1) return error.Domain;
}

fn normdist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const mu = opt(a, 1, 0);
    const sd = opt(a, 2, 1);
    if (sd <= 0) return error.Domain;
    const z = (x - mu) / sd;
    if (flag(a, 3)) return res(erfcf(-z / std.math.sqrt2) / 2);
    return res(@exp(-z * z / 2) / (sd * @sqrt(2 * std.math.pi)));
}

fn normdistinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    if (p <= 0 or p >= 1) return error.Domain;
    const sd = opt(a, 2, 1);
    if (sd <= 0) return error.Domain;
    return res(probitf(p) * sd + opt(a, 1, 0));
}

fn lbinom(n: f64, k: f64) f64 {
    return lgammaf(n + 1) - lgammaf(k + 1) - lgammaf(n - k + 1);
}

fn binomdist(_: *const Ctx, a: []const Number) Error!Number {
    const k = fl(a[0]);
    const n = fl(a[1]);
    const p = fl(a[2]);
    try needProb(p);
    if (n < 0 or n != @floor(n) or k != @floor(k)) return error.Domain;
    if (k < 0) return res(0);
    if (k > n) return res(if (flag(a, 3)) 1 else 0);
    if (flag(a, 3)) {
        if (k == n) return res(1);
        return res(betaI(n - k, k + 1, 1 - p));
    }
    if (p == 0) return res(if (k == 0) 1 else 0);
    if (p == 1) return res(if (k == n) 1 else 0);
    return res(@exp(lbinom(n, k) + k * @log(p) + (n - k) * std.math.log1p(-p)));
}

fn poisson(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const l = fl(a[1]);
    if (l < 0 or x != @floor(x)) return error.Domain;
    if (x < 0) return res(0);
    if (flag(a, 2)) return res(gammaQ(x + 1, l));
    if (l == 0) return res(if (x == 0) 1 else 0);
    return res(@exp(-l + x * @log(l) - lgammaf(x + 1)));
}

fn expondist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const l = fl(a[1]);
    if (flag(a, 2)) return res(1 - @exp(-l * x));
    return res(l * @exp(-l * x));
}

fn expinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    try needProb(p);
    return res(-std.math.log1p(-p) / fl(a[1]));
}

fn logistic(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const s = fl(a[1]);
    const mu = opt(a, 2, 0);
    if (s <= 0) return error.Domain;
    const z = -(x - mu) / s;
    if (flag(a, 3)) return res(1 / (1 + @exp(z)));
    return res(@exp(z) / (s * (1 + @exp(z)) * (1 + @exp(z))));
}

fn pareto(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const al = fl(a[1]);
    const xm = fl(a[2]);
    if (flag(a, 3)) return res(1 - std.math.pow(f64, xm / x, al));
    return res(al * std.math.pow(f64, xm, al) / std.math.pow(f64, x, al + 1));
}

fn rayleigh(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const s = fl(a[1]);
    if (s <= 0) return error.Domain;
    const e = @exp(-x * x / (2 * s * s));
    if (flag(a, 2)) return res(1 - e);
    return res(x / (s * s) * e);
}

fn rayleightail(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const lo = fl(a[1]);
    const s = fl(a[2]);
    if (s <= 0) return error.Domain;
    if (x < lo) return res(0);
    return res((x / s) / s * @exp((lo / s + x / s) * (lo / s - x / s) / 2));
}

fn gammadist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const k = fl(a[1]);
    const t = fl(a[2]);
    if (k <= 0 or t <= 0) return error.Domain;
    if (x < 0) return res(0);
    if (flag(a, 3)) return res(gammaP(k, x / t));
    if (x == 0) return res(if (k < 1) std.math.inf(f64) else if (k == 1) 1 / t else 0);
    return res(@exp((k - 1) * @log(x) - x / t - lgammaf(k) - k * @log(t)));
}

fn chisqdist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const k = fl(a[1]);
    if (k <= 0) return error.Domain;
    if (x < 0) return res(0);
    if (flag(a, 2)) return res(gammaP(k / 2, x / 2));
    if (x == 0) return res(if (k < 2) std.math.inf(f64) else if (k == 2) 0.5 else 0);
    return res(@exp((k / 2 - 1) * @log(x) - x / 2 - lgammaf(k / 2) - k / 2 * @log(2.0)));
}

fn chisqdistinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    const k = fl(a[1]);
    try needProb(p);
    if (k <= 0) return error.Domain;
    if (p == 0) return res(0);
    if (p == 1) return error.Domain;
    return res(invert(cdfChi, p, k, 0, 0, 0, std.math.inf(f64)));
}

fn weibulldist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const l = fl(a[1]);
    const k = fl(a[2]);
    if (l <= 0 or k <= 0) return error.Domain;
    if (x < 0) return res(0);
    const e = @exp(-std.math.pow(f64, x / l, k));
    if (flag(a, 3)) return res(1 - e);
    return res(k / l * std.math.pow(f64, x / l, k - 1) * e);
}

fn wblinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    try needProb(p);
    return res(fl(a[1]) * std.math.pow(f64, -std.math.log1p(-p), 1 / fl(a[2])));
}

fn betadist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const al = fl(a[1]);
    const be = fl(a[2]);
    if (al <= 0 or be <= 0) return error.Domain;
    if (x < 0 or x > 1) return res(0);
    if (flag(a, 3)) return res(betaI(al, be, x));
    return res(@exp((al - 1) * @log(x) + (be - 1) * std.math.log1p(-x) - (lgammaf(al) + lgammaf(be) - lgammaf(al + be))));
}

fn tdist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const v = fl(a[1]);
    if (v <= 0) return error.Domain;
    if (flag(a, 2)) return res(cdfT(x, v, 0, 0));
    return res(@exp(lgammaf((v + 1) / 2) - lgammaf(v / 2) - 0.5 * @log(v * std.math.pi) - (v + 1) / 2 * std.math.log1p(x * x / v)));
}

fn tdistinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    const v = fl(a[1]);
    if (v <= 0) return error.Domain;
    if (p <= 0 or p >= 1) return error.Domain;
    if (p == 0.5) return res(0);
    return res(invert(cdfT, p, v, 0, 0, -std.math.inf(f64), std.math.inf(f64)));
}

fn fdist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const d1 = fl(a[1]);
    const d2 = fl(a[2]);
    if (d1 <= 0 or d2 <= 0) return error.Domain;
    if (x < 0) return res(0);
    if (flag(a, 3)) return res(cdfF(x, d1, d2, 0));
    if (x == 0) return res(if (d1 < 2) std.math.inf(f64) else if (d1 == 2) 1 else 0);
    return res(@exp(0.5 * (d1 * @log(d1 * x) + d2 * @log(d2) - (d1 + d2) * @log(d1 * x + d2)) - @log(x) - (lgammaf(d1 / 2) + lgammaf(d2 / 2) - lgammaf((d1 + d2) / 2))));
}

fn fdistinv(_: *const Ctx, a: []const Number) Error!Number {
    const p = fl(a[0]);
    try needProb(p);
    const d1 = fl(a[1]);
    const d2 = fl(a[2]);
    if (d1 <= 0 or d2 <= 0) return error.Domain;
    if (p == 0) return res(0);
    if (p == 1) return error.Domain;
    return res(invert(cdfF, p, d1, d2, 0, 0, std.math.inf(f64)));
}

fn cauchydist(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const x0 = fl(a[1]);
    const g = fl(a[2]);
    if (g <= 0) return error.Domain;
    if (flag(a, 3)) return res(std.math.atan((x - x0) / g) / std.math.pi + 0.5);
    const z = (x - x0) / g;
    return res(1 / (std.math.pi * g * (1 + z * z)));
}

fn igamma(_: *const Ctx, a: []const Number) Error!Number {
    const s = fl(a[0]);
    const x = fl(a[1]);
    if (s <= 0) return error.Domain;
    return res(gammaQ(s, x) * gammaf(s));
}

fn gammainc(_: *const Ctx, a: []const Number) Error!Number {
    const s = fl(a[0]);
    const x = fl(a[1]);
    if (s <= 0) return error.Domain;
    return res(gammaP(s, x) * gammaf(s));
}

fn betainc(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const al = fl(a[1]);
    const be = fl(a[2]);
    if (al <= 0 or be <= 0 or x < 0 or x > 1) return error.Domain;
    return res(betaI(al, be, x));
}

// ---- spreadsheet money functions ----------------------------------------------------------
//
// As in a spreadsheet: money paid out is negative, money received positive; `type` 1 means
// payments at the start of each period.

fn annuityFactor(r: f64, n: f64, t: f64) f64 {
    if (r == 0) return n;
    return (1 + r * t) * (std.math.pow(f64, 1 + r, n) - 1) / r;
}

fn fvf(r: f64, n: f64, pmt_: f64, pv_: f64, t: f64) f64 {
    return -(pv_ * std.math.pow(f64, 1 + r, n) + pmt_ * annuityFactor(r, n, t));
}

fn pmtf(r: f64, n: f64, pv_: f64, fv_: f64, t: f64) f64 {
    return (-pv_ * std.math.pow(f64, 1 + r, n) - fv_) / annuityFactor(r, n, t);
}

fn pv(_: *const Ctx, a: []const Number) Error!Number {
    const r = fl(a[0]);
    const n = fl(a[1]);
    const p = fl(a[2]);
    const f = opt(a, 3, 0);
    const t: f64 = if (flag(a, 4)) 1 else 0;
    return res((-f - p * annuityFactor(r, n, t)) / std.math.pow(f64, 1 + r, n));
}

fn fv(_: *const Ctx, a: []const Number) Error!Number {
    return res(fvf(fl(a[0]), fl(a[1]), fl(a[2]), opt(a, 3, 0), if (flag(a, 4)) 1 else 0));
}

fn pmt(_: *const Ctx, a: []const Number) Error!Number {
    const n = fl(a[1]);
    if (n == 0) return error.DivisionByZero;
    return res(pmtf(fl(a[0]), n, fl(a[2]), opt(a, 3, 0), if (flag(a, 4)) 1 else 0));
}

fn nper(_: *const Ctx, a: []const Number) Error!Number {
    const r = fl(a[0]);
    const p = fl(a[1]);
    const pv_ = fl(a[2]);
    const f = opt(a, 3, 0);
    const t: f64 = if (flag(a, 4)) 1 else 0;
    if (r == 0) return res(-(pv_ + f) / p);
    const x = (p * (1 + r * t) - f * r) / (pv_ * r + p * (1 + r * t));
    if (x <= 0 or r <= -1) return error.Domain;
    return res(@log(x) / std.math.log1p(r));
}

fn rate(_: *const Ctx, a: []const Number) Error!Number {
    const n = fl(a[0]);
    const p = fl(a[1]);
    const pv_ = fl(a[2]);
    const f = opt(a, 3, 0);
    const t: f64 = if (flag(a, 4)) 1 else 0;
    var r = opt(a, 5, 0.1);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const g = pv_ * std.math.pow(f64, 1 + r, n) + p * annuityFactor(r, n, t) + f;
        const h = 1e-7 * @max(1, @abs(r));
        const g2 = pv_ * std.math.pow(f64, 1 + r + h, n) + p * annuityFactor(r + h, n, t) + f;
        const d = (g2 - g) / h;
        if (d == 0 or std.math.isNan(d)) return error.Domain;
        const step = g / d;
        r -= step;
        if (r <= -1) r = -0.999999;
        if (@abs(step) < 1e-15) return res(r);
    }
    return error.Domain;
}

fn ipmtf(r: f64, per: f64, n: f64, pv_: f64, fv_: f64, t: f64) f64 {
    const p = pmtf(r, n, pv_, fv_, t);
    return -(pv_ * std.math.pow(f64, 1 + r, per - 1) + p * ((std.math.pow(f64, 1 + r, per - 1) - 1) / r)) * r;
}

fn ipmt(_: *const Ctx, a: []const Number) Error!Number {
    const r = fl(a[0]);
    if (r == 0) return res(0);
    return res(ipmtf(r, fl(a[1]), fl(a[2]), fl(a[3]), opt(a, 4, 0), if (flag(a, 5)) 1 else 0));
}

fn ppmt(_: *const Ctx, a: []const Number) Error!Number {
    const r = fl(a[0]);
    const t: f64 = if (flag(a, 5)) 1 else 0;
    const p = pmtf(r, fl(a[2]), fl(a[3]), opt(a, 4, 0), t);
    if (r == 0) return res(p);
    return res(p - ipmtf(r, fl(a[1]), fl(a[2]), fl(a[3]), opt(a, 4, 0), t));
}

fn ispmt(_: *const Ctx, a: []const Number) Error!Number {
    const r = fl(a[0]);
    const per = fl(a[1]);
    const n = fl(a[2]);
    const p = fl(a[3]);
    return res((-p * r) - (-p * r) / n * per);
}

fn effect(_: *const Ctx, a: []const Number) Error!Number {
    const m = fl(a[1]);
    if (m < 1) return error.Domain;
    return res(std.math.pow(f64, 1 + fl(a[0]) / m, m) - 1);
}

fn nominal(_: *const Ctx, a: []const Number) Error!Number {
    const m = fl(a[1]);
    if (m < 1) return error.Domain;
    return res(m * (@abs(std.math.pow(f64, fl(a[0]) + 1, 1 / m)) - 1));
}

fn sln(_: *const Ctx, a: []const Number) Error!Number {
    const l = fl(a[2]);
    if (l == 0) return error.DivisionByZero;
    return res((fl(a[0]) - fl(a[1])) / l);
}

fn syd(_: *const Ctx, a: []const Number) Error!Number {
    const l = fl(a[2]);
    if (l == 0) return error.DivisionByZero;
    return res((fl(a[0]) - fl(a[1])) * (l - fl(a[3]) + 1) * 2 / (l * (l + 1)));
}

fn zeroCoupon(_: *const Ctx, a: []const Number) Error!Number {
    return res(fl(a[0]) / std.math.pow(f64, 1 + fl(a[1]), fl(a[2])));
}

fn continuous(_: *const Ctx, a: []const Number) Error!Number {
    return res(fl(a[0]) * @exp(fl(a[1]) * fl(a[2])));
}

fn compound(_: *const Ctx, a: []const Number) Error!Number {
    const m = fl(a[2]);
    return res(fl(a[0]) * std.math.pow(f64, 1 + fl(a[1]) / m, m * fl(a[3])));
}

fn dollarfr(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const d = fl(a[1]);
    if (d <= 0) return error.Domain;
    const ip = @trunc(x);
    return res(ip + (x - ip) * d / std.math.pow(f64, 10, @ceil(@log10(d))));
}

fn dollarde(_: *const Ctx, a: []const Number) Error!Number {
    const x = fl(a[0]);
    const d = fl(a[1]);
    if (d <= 0) return error.Domain;
    const ip = @trunc(x);
    return res(ip + (x - ip) * std.math.pow(f64, 10, @ceil(@log10(d - 0.5))) / d);
}

// ---- the table ---------------------------------------------------------------------------

fn def(name: []const u8, min: u8, max: u8, run: *const fn (*const Ctx, []const Number) Error!Number) Def {
    return .{ .name = name, .min = min, .max = max, .run = run };
}

const table = [_]Def{
    def("sech", 1, 1, sech),                 def("csch", 1, 1, csch),               def("coth", 1, 1, coth),
    def("asech", 1, 1, asech),               def("acsch", 1, 1, acsch),             def("acoth", 1, 1, acoth),
    def("asec", 1, 1, asec),                 def("acsc", 1, 1, acsc),               def("acot", 1, 1, acot),
    def("sinc", 1, 1, sinc),                 def("radtodef", 1, 1, radtodef),       def("deftorad", 1, 1, deftorad),
    def("exp2", 1, 1, exp2),                 def("exp10", 1, 1, exp10),             def("sqrtpi", 1, 1, sqrtpi),
    def("sq", 1, 1, square),                 def("gamma", 1, 1, gamma),             def("beta", 2, 2, beta),
    def("digamma", 1, 1, digamma),           def("erf", 1, 1, erf),                 def("erfc", 1, 1, erfc),
    def("erfinv", 1, 1, erfinv),             def("probit", 1, 1, probit),           def("zeta", 1, 1, zeta),
    def("lambertw", 1, 1, lambertw),         def("sigmoid", 1, 1, sigmoid),         def("logit", 1, 1, logit),
    def("heaviside", 1, 1, heaviside),       def("ramp", 1, 1, ramp),               def("rectangular", 1, 1, rectangular),
    def("triangular", 1, 1, triangular),     def("kronecker", 2, 2, kronecker),     def("isprime", 1, 1, isprime),
    def("nextprime", 1, 1, nextprime),       def("prevprime", 1, 1, prevprime),     def("nthprime", 1, 1, nthprime),
    def("primepi", 1, 1, primepi),           def("totient", 1, 1, totient),         def("fibonacci", 1, 1, fibonacci),
    def("factorial2", 1, 1, factorial2),     def("hyperfactorial", 1, 1, hyperfactorial), def("superfactorial", 1, 1, superfactorial),
    def("derangements", 1, 1, derangements), def("bernoulli", 1, 1, bernoulli),     def("powmod", 3, 3, powmod),
    def("clip", 3, 3, clip),                 def("numerator", 1, 1, numerator),     def("denominator", 1, 1, denominator),
    def("div", 2, 2, div),                   def("rem", 2, 2, rem),                 def("neg", 1, 1, neg),
    def("subtract", 2, 2, subtract),         def("even", 1, 1, even),               def("odd", 1, 1, odd),
    def("normdist", 1, 4, normdist),         def("normdistinv", 1, 3, normdistinv), def("binomdist", 3, 4, binomdist),
    def("poisson", 2, 3, poisson),           def("expondist", 2, 3, expondist),     def("expinv", 2, 2, expinv),
    def("logistic", 2, 4, logistic),         def("pareto", 3, 4, pareto),           def("rayleigh", 2, 3, rayleigh),
    def("rayleightail", 3, 3, rayleightail), def("gammadist", 3, 4, gammadist),     def("chisqdist", 2, 3, chisqdist),
    def("chisqdistinv", 2, 2, chisqdistinv), def("weibulldist", 3, 4, weibulldist), def("wblinv", 3, 3, wblinv),
    def("betadist", 3, 4, betadist),         def("tdist", 2, 3, tdist),             def("tdistinv", 2, 2, tdistinv),
    def("fdist", 3, 4, fdist),               def("fdistinv", 3, 3, fdistinv),       def("cauchydist", 3, 4, cauchydist),
    def("igamma", 2, 2, igamma),             def("gammainc", 2, 2, gammainc),       def("betainc", 3, 3, betainc),
    def("pv", 3, 5, pv),                     def("fv", 3, 5, fv),                   def("pmt", 3, 5, pmt),
    def("nper", 3, 5, nper),                 def("rate", 3, 6, rate),               def("ipmt", 4, 6, ipmt),
    def("ppmt", 4, 6, ppmt),                 def("ispmt", 4, 4, ispmt),             def("effect", 2, 2, effect),
    def("nominal", 2, 2, nominal),           def("sln", 3, 3, sln),                 def("syd", 4, 4, syd),
    def("zero_coupon", 3, 3, zeroCoupon),    def("continuous", 3, 3, continuous),   def("compound", 4, 4, compound),
    def("dollarfr", 2, 2, dollarfr),         def("dollarde", 2, 2, dollarde),
};
