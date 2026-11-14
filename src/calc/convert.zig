//! "… to fraction", "255 to hex", "0.25 to percent", "2024 to roman",
//! "360 to factors": the answer shown another way. The value is worked out
//! first (by eval), then written here; the entry itself is not changed.

const std = @import("std");
const num = @import("num.zig");
const Big = std.math.big.int.Managed;
const Number = num.Number;

pub const Kind = union(enum) {
    fraction,
    mixed,
    decimal,
    base: u8,
    roman,
    sexagesimal,
    time,
    factors,
    percent,
    scientific,
    engineering,
};

pub const Request = struct { expr: []const u8, kind: Kind };

const names = [_]struct { []const u8, Kind }{
    .{ "fraction", .fraction },
    .{ "frac", .fraction },
    .{ "mixed", .mixed },
    .{ "decimal", .decimal },
    .{ "bin", .{ .base = 2 } },
    .{ "binary", .{ .base = 2 } },
    .{ "oct", .{ .base = 8 } },
    .{ "octal", .{ .base = 8 } },
    .{ "dec", .{ .base = 10 } },
    .{ "hex", .{ .base = 16 } },
    .{ "hexadecimal", .{ .base = 16 } },
    .{ "duodecimal", .{ .base = 12 } },
    .{ "roman", .roman },
    .{ "sexagesimal", .sexagesimal },
    .{ "time", .time },
    .{ "factors", .factors },
    .{ "factor", .factors },
    .{ "percent", .percent },
    .{ "scientific", .scientific },
    .{ "sci", .scientific },
    .{ "engineering", .engineering },
    .{ "eng", .engineering },
};

/// The last " to " / " in " / " → " and a known word after it, else null.
pub fn request(text: []const u8) ?Request {
    const t = std.mem.trim(u8, text, " ");
    var split: ?usize = null;
    var sep_len: usize = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        inline for (.{ " to ", " in ", " → " }) |sep| {
            if (std.mem.startsWith(u8, t[i..], sep)) {
                split = i;
                sep_len = sep.len;
            }
        }
    }
    const at = split orelse return null;
    const expr = std.mem.trim(u8, t[0..at], " ");
    const word = std.mem.trim(u8, t[at + sep_len ..], " ");
    if (expr.len == 0) return null;
    for (names) |n| if (std.ascii.eqlIgnoreCase(word, n[0])) return .{ .expr = expr, .kind = n[1] };
    // "base 16", "base 36".
    if (std.ascii.startsWithIgnoreCase(word, "base")) {
        const rest = std.mem.trim(u8, word[4..], " ");
        const b = std.fmt.parseInt(u8, rest, 10) catch return null;
        if (b >= 2 and b <= 36) return .{ .expr = expr, .kind = .{ .base = b } };
    }
    return null;
}

pub const Shown = struct {
    text: []const u8,
    /// The answer is a rounding, not exact.
    approx: bool = false,
};

pub fn apply(a: std.mem.Allocator, v: Number, kind: Kind, style: num.Style) num.Error!Shown {
    return switch (kind) {
        .decimal => .{ .text = try num.format(a, v, style), .approx = !v.isExact() },
        .scientific => blk: {
            var s = style;
            s.notation = .scientific;
            break :blk .{ .text = try num.format(a, v, s), .approx = !v.isExact() };
        },
        .engineering => blk: {
            var s = style;
            s.notation = .engineering;
            break :blk .{ .text = try num.format(a, v, s), .approx = !v.isExact() };
        },
        .percent => blk: {
            const p = try num.mul(a, v, try num.fromInt(a, 100));
            const t = try num.format(a, p, style);
            break :blk .{ .text = try std.fmt.allocPrint(a, "{s}%", .{t}), .approx = !p.isExact() };
        },
        .fraction => try fractionOf(a, v, false, style),
        .mixed => try fractionOf(a, v, true, style),
        .base => |b| try inBase(a, v, b),
        .roman => try roman(a, v),
        .sexagesimal => try sexagesimal(a, v, style),
        .time => try timeText(a, v),
        .factors => try factors(a, v),
    };
}

// ---- helpers ------------------------------------------------------------------------

const Ratio = struct { neg: bool, num: Big, den: Big };

/// The exact value of `v` (a float is its exact binary value).
fn ratio(a: std.mem.Allocator, v: Number) num.Error!Ratio {
    var r: Number = v;
    if (v == .approx) {
        const f = v.approx;
        if (!std.math.isFinite(f)) return error.Domain;
        if (f == 0) {
            r = try num.fromInt(a, 0);
        } else {
            const fr = std.math.frexp(f);
            const mant: i64 = @intFromFloat(fr.significand * 9007199254740992.0); // 2^53
            const e2: i32 = fr.exponent - 53;
            var n = try Big.initSet(a, mant);
            var d = try Big.initSet(a, 1);
            if (e2 >= 0) {
                if (e2 > 4000) return error.TooLarge;
                try n.shiftLeft(&n, @intCast(e2));
            } else {
                if (e2 < -4000) return error.TooLarge;
                try d.shiftLeft(&d, @intCast(-e2));
            }
            r = try num.fromParts(a, n, d);
        }
    }
    var n = try r.exact.num.clone();
    const neg = !n.eqlZero() and !n.isPositive();
    n.abs();
    return .{ .neg = neg, .num = n, .den = try r.exact.den.clone() };
}

fn isOne(b: Big) bool {
    return b.isPositive() and b.bitCountAbs() == 1;
}

fn bigString(a: std.mem.Allocator, b: Big, base: u8) num.Error![]u8 {
    return b.toString(a, base, .upper) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

// ---- fraction / mixed -----------------------------------------------------------------

fn fractionOf(a: std.mem.Allocator, v: Number, mixed: bool, style: num.Style) num.Error!Shown {
    var approx = false;
    var r: Ratio = undefined;
    if (v == .exact) {
        r = try ratio(a, v);
    } else {
        // The simplest ratio within a hair of the float (continued fraction).
        const f = v.approx;
        if (!std.math.isFinite(f)) return error.Domain;
        const best = simplest(f) orelse return .{ .text = try num.format(a, v, style), .approx = true };
        r = .{
            .neg = f < 0,
            .num = try Big.initSet(a, best[0]),
            .den = try Big.initSet(a, best[1]),
        };
        approx = true;
    }
    const sign: []const u8 = if (r.neg) "−" else "";
    if (isOne(r.den)) return .{ .text = try std.fmt.allocPrint(a, "{s}{s}", .{ sign, try bigString(a, r.num, 10) }), .approx = approx };
    if (mixed) {
        var q = try Big.init(a);
        var rem = try Big.init(a);
        try q.divTrunc(&rem, &r.num, &r.den);
        if (!q.eqlZero()) {
            return .{ .text = try std.fmt.allocPrint(a, "{s}{s} {s}/{s}", .{ sign, try bigString(a, q, 10), try bigString(a, rem, 10), try bigString(a, r.den, 10) }), .approx = approx };
        }
    }
    return .{ .text = try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ sign, try bigString(a, r.num, 10), try bigString(a, r.den, 10) }), .approx = approx };
}

/// A ratio p/q (q ≤ 10^9) within 1e-14 (relative) of |f|, else null.
fn simplest(f: f64) ?[2]u64 {
    const x = @abs(f);
    if (x >= 1e15) return null;
    var h1: u64 = 1;
    var h0: u64 = 0;
    var k1: u64 = 0;
    var k0: u64 = 1;
    var y = x;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const ai = @floor(y);
        if (ai > 1e15) return null;
        const a_i: u64 = @intFromFloat(ai);
        const h2 = std.math.mul(u64, a_i, h1) catch return null;
        const hh = std.math.add(u64, h2, h0) catch return null;
        const k2 = std.math.mul(u64, a_i, k1) catch return null;
        const kk = std.math.add(u64, k2, k0) catch return null;
        if (kk > 1_000_000_000) return null;
        h0 = h1;
        h1 = hh;
        k0 = k1;
        k1 = kk;
        const approx_v = @as(f64, @floatFromInt(h1)) / @as(f64, @floatFromInt(k1));
        if (@abs(approx_v - x) <= 1e-14 * @max(x, 1e-300)) return .{ h1, k1 };
        const frac = y - ai;
        if (frac == 0) return .{ h1, k1 };
        y = 1.0 / frac;
    }
    return null;
}

// ---- other bases --------------------------------------------------------------------

fn inBase(a: std.mem.Allocator, v: Number, base: u8) num.Error!Shown {
    const r = try ratio(a, v);
    var ip = try Big.init(a);
    var rem = try Big.init(a);
    try ip.divTrunc(&rem, &r.num, &r.den);
    var int_text = try bigString(a, ip, base);
    // Binary: groups of four, as Qalculate does.
    if (base == 2) {
        const pad = (4 - int_text.len % 4) % 4;
        var buf: std.ArrayList(u8) = .empty;
        for (0..pad) |_| try buf.append(a, '0');
        try buf.appendSlice(a, int_text);
        var out: std.ArrayList(u8) = .empty;
        for (buf.items, 0..) |c, i| {
            if (i > 0 and i % 4 == 0) try out.append(a, ' ');
            try out.append(a, c);
        }
        int_text = try out.toOwnedSlice(a);
    }
    var out: std.ArrayList(u8) = .empty;
    if (r.neg) try out.appendSlice(a, "−");
    if (base == 16) try out.appendSlice(a, "0x");
    try out.appendSlice(a, int_text);
    var truncated = false;
    if (!rem.eqlZero()) {
        try out.append(a, '.');
        var b = try Big.initSet(a, base);
        var digits: usize = 0;
        const limit: usize = 40;
        while (!rem.eqlZero() and digits < limit) : (digits += 1) {
            try rem.mul(&rem, &b);
            var q = try Big.init(a);
            var r2 = try Big.init(a);
            try q.divTrunc(&r2, &rem, &r.den);
            const d = q.toInt(u8) catch 0;
            try out.append(a, std.fmt.digitToChar(d, .upper));
            rem = r2;
        }
        if (!rem.eqlZero()) truncated = true;
        _ = &b;
    }
    if (truncated) try out.appendSlice(a, "…");
    return .{ .text = try out.toOwnedSlice(a), .approx = truncated };
}

// ---- roman, sexagesimal, time -------------------------------------------------------

fn roman(a: std.mem.Allocator, v: Number) num.Error!Shown {
    const n = num.intValue(v) orelse return error.Domain;
    if (n < 1 or n > 3999) return error.Domain;
    const table = [_]struct { u32, []const u8 }{
        .{ 1000, "M" }, .{ 900, "CM" }, .{ 500, "D" }, .{ 400, "CD" }, .{ 100, "C" }, .{ 90, "XC" },
        .{ 50, "L" },   .{ 40, "XL" },  .{ 10, "X" },  .{ 9, "IX" },   .{ 5, "V" },   .{ 4, "IV" },
        .{ 1, "I" },
    };
    var out: std.ArrayList(u8) = .empty;
    var left: u32 = @intCast(n);
    for (table) |e| while (left >= e[0]) {
        try out.appendSlice(a, e[1]);
        left -= e[0];
    };
    return .{ .text = try out.toOwnedSlice(a) };
}

/// 12.5 → 12°30′0″ (degrees, minutes, seconds).
fn sexagesimal(a: std.mem.Allocator, v: Number, style: num.Style) num.Error!Shown {
    const f = v.toFloat();
    if (!std.math.isFinite(f)) return error.Domain;
    const x = @abs(f);
    const deg = @floor(x);
    const mins_f = (x - deg) * 60;
    const mins = @floor(mins_f);
    const secs = (mins_f - mins) * 60;
    var s = style;
    s.grouping = false;
    s.decimals = @min(style.decimals, 6);
    const st = try num.format(a, .{ .approx = secs }, s);
    // Rounding can make seconds 60: carry.
    var d: f64 = deg;
    var m: f64 = mins;
    var secs_text: []const u8 = st;
    if (std.mem.eql(u8, st, "60")) {
        secs_text = "0";
        m += 1;
        if (m >= 60) {
            m = 0;
            d += 1;
        }
    }
    const ds = try num.format(a, .{ .approx = d }, s);
    const ms = try num.format(a, .{ .approx = m }, s);
    const exact = v == .exact and secsExact(v);
    return .{ .text = try std.fmt.allocPrint(a, "{s}{s}°{s}′{s}″", .{ if (f < 0) "−" else "", ds, ms, secs_text }), .approx = !exact };
}

fn secsExact(v: Number) bool {
    // A whole number of seconds in degrees needs denominator | 3600.
    const d = v.exact.den.toInt(u64) catch return false;
    return d != 0 and 3600 % d == 0;
}

/// Seconds as h:mm:ss (days beyond 24 h stay in hours).
fn timeText(a: std.mem.Allocator, v: Number) num.Error!Shown {
    const f = v.toFloat();
    if (!std.math.isFinite(f) or @abs(f) > 1e15) return error.Domain;
    const x = @abs(f);
    const total = @floor(x);
    const frac = x - total;
    const t: u64 = @intFromFloat(total);
    const h = t / 3600;
    const m = (t / 60) % 60;
    const s = t % 60;
    var out: std.ArrayList(u8) = .empty;
    if (f < 0) try out.appendSlice(a, "−");
    try out.print(a, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s });
    if (frac > 1e-9) {
        const fs = try std.fmt.allocPrint(a, "{d:.6}", .{frac});
        var end = fs.len;
        while (end > 2 and fs[end - 1] == '0') end -= 1;
        try out.appendSlice(a, fs[1..end]);
    }
    return .{ .text = try out.toOwnedSlice(a), .approx = v == .approx };
}

// ---- prime factors ------------------------------------------------------------------

const superscripts = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };

fn factors(a: std.mem.Allocator, v: Number) num.Error!Shown {
    if (!(v == .exact and isOne(v.exact.den))) return error.Domain;
    const big = v.exact.num;
    if (big.bitCountAbs() > 63) return error.TooLarge;
    const i = big.toInt(i64) catch return error.TooLarge;
    var n: u64 = @abs(i);
    if (n < 2) return error.Domain;
    var out: std.ArrayList(u8) = .empty;
    if (i < 0) try out.appendSlice(a, "−1 × ");
    var first = true;
    var p: u64 = 2;
    var steps: u64 = 0;
    while (p * p <= n) {
        if (n % p == 0) {
            var e: usize = 0;
            while (n % p == 0) {
                n /= p;
                e += 1;
            }
            try appendFactor(a, &out, &first, p, e);
        }
        p += if (p == 2) 1 else 2;
        steps += 1;
        if (steps > 200_000_000) return error.TooLarge;
    }
    if (n > 1) try appendFactor(a, &out, &first, n, 1);
    return .{ .text = try out.toOwnedSlice(a) };
}

fn appendFactor(a: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, p: u64, e: usize) !void {
    if (!first.*) try out.appendSlice(a, " × ");
    first.* = false;
    try out.print(a, "{d}", .{p});
    if (e > 1) {
        const s = try std.fmt.allocPrint(a, "{d}", .{e});
        for (s) |c| try out.appendSlice(a, superscripts[c - '0']);
    }
}

// ---- tests ----------------------------------------------------------------------------

fn expectShown(kind: Kind, input: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const neg = input[0] == '-';
    var v = try num.parseDecimal(a, if (neg) input[1..] else input);
    if (neg) v = try num.neg(a, v);
    const got = try apply(a, v, kind, .{});
    try std.testing.expectEqualStrings(want, got.text);
}

test "requests are recognised" {
    try std.testing.expect(request("5 km in mi") == null);
    const r = request("255 to hex").?;
    try std.testing.expectEqualStrings("255", r.expr);
    try std.testing.expectEqual(@as(u8, 16), r.kind.base);
    try std.testing.expectEqual(@as(u8, 36), request("100 to base 36").?.kind.base);
    try std.testing.expect(request("100 to base 99") == null);
}

test "conversions match Qalculate" {
    try expectShown(.fraction, "0.333", "333/1000");
    try expectShown(.mixed, "-2.5", "−2 1/2");
    try expectShown(.{ .base = 16 }, "255", "0xFF");
    try expectShown(.{ .base = 16 }, "255.5", "0xFF.8");
    try expectShown(.{ .base = 16 }, "-255", "−0xFF");
    try expectShown(.{ .base = 2 }, "255", "1111 1111");
    try expectShown(.{ .base = 2 }, "0.5", "0000.1");
    try expectShown(.{ .base = 36 }, "100", "2S");
    try expectShown(.roman, "2024", "MMXXIV");
    try expectShown(.percent, "0.25", "25%");
    try expectShown(.sexagesimal, "12.5", "12°30′0″");
    try expectShown(.factors, "360", "2³ × 3² × 5");
    try expectShown(.time, "3725", "1:02:05");
}
