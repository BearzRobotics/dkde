// SPDX-License-Identifier: GPL-2.0-or-later
//! Values with an uncertainty: `5 ± 0.1`, `12.3 ± 0.4`. The error is carried through the
//! arithmetic the way a lab report does it (first-order propagation, independent errors):
//!
//!   x ± y            √(σx² + σy²)
//!   x · y            √((y·σx)² + (x·σy)²)
//!   x / y            √((σx/y)² + (x·σy/y²)²)
//!   xⁿ               |n·xⁿ⁻¹|·σx
//!   f(x)             |f′(x)|·σx   (f′ by a small difference)
//!
//! A result is written with its error to one significant figure (two when the first is 1) and
//! the value rounded to the same place: `12.3 ± 0.4`, `1.00 ± 0.15`.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const Number = num.Number;
const Node = eval.Node;

pub const Error = eval.Error;

pub const U = struct { v: Number, s: f64 };

/// Does the entry have a `±` (an `uncertainty(…)` call) in it?
pub fn has(n: *const Node) bool {
    return switch (n.*) {
        .number, .name => false,
        .unary => |u| has(u.arg),
        .binary => |b| has(b.l) or has(b.r),
        .call => |c| blk: {
            if (std.ascii.eqlIgnoreCase(c.name, "uncertainty")) break :blk true;
            for (c.args) |x| if (has(x)) break :blk true;
            break :blk false;
        },
    };
}

fn exactOne(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 1);
}

fn sq(x: f64) f64 {
    return x * x;
}

pub fn evaluate(ev: *eval.Eval, n: *const Node) Error!U {
    const a = ev.a;
    if (!has(n)) return .{ .v = try ev.eval(n, null), .s = 0 };
    switch (n.*) {
        .unary => |u| {
            const x = try evaluate(ev, u.arg);
            return switch (u.op) {
                .neg => .{ .v = try num.neg(a, x.v), .s = x.s },
                .pct => .{ .v = try num.div(a, x.v, try num.fromInt(a, 100)), .s = x.s / 100 },
                else => error.Domain,
            };
        },
        .binary => |b| {
            const x = try evaluate(ev, b.l);
            const y = try evaluate(ev, b.r);
            const xf = x.v.toFloat();
            const yf = y.v.toFloat();
            switch (b.op) {
                .add => return .{ .v = try num.add(a, x.v, y.v), .s = std.math.hypot(x.s, y.s) },
                .sub => return .{ .v = try num.sub(a, x.v, y.v), .s = std.math.hypot(x.s, y.s) },
                .mul => return .{ .v = try num.mul(a, x.v, y.v), .s = @sqrt(sq(yf * x.s) + sq(xf * y.s)) },
                .div => {
                    if (y.v.isZero()) return error.DivisionByZero;
                    return .{ .v = try num.div(a, x.v, y.v), .s = @sqrt(sq(x.s / yf) + sq(xf * y.s / (yf * yf))) };
                },
                .pow => {
                    const v = try num.pow(a, x.v, y.v);
                    var s2: f64 = 0;
                    if (x.s != 0) s2 += sq(yf * std.math.pow(f64, xf, yf - 1) * x.s);
                    if (y.s != 0 and xf > 0) s2 += sq(std.math.pow(f64, xf, yf) * @log(xf) * y.s);
                    return .{ .v = v, .s = @sqrt(s2) };
                },
                else => return error.Domain,
            }
        },
        .call => |c| {
            const eql = std.ascii.eqlIgnoreCase;
            if (eql(c.name, "uncertainty")) {
                if (c.args.len != 2) return error.WrongArguments;
                const x = try evaluate(ev, c.args[0]);
                const e = try evaluate(ev, c.args[1]);
                return .{ .v = x.v, .s = std.math.hypot(x.s, @abs(e.v.toFloat())) };
            }
            if (c.args.len != 1) return error.WrongArguments;
            const x = try evaluate(ev, c.args[0]);
            if (eql(c.name, "midpoint")) return .{ .v = x.v, .s = 0 };
            if (eql(c.name, "errorPart")) return .{ .v = try num.fromFloat(x.s), .s = 0 };
            if (eql(c.name, "lowerEndpoint")) return .{ .v = try num.sub(a, x.v, try num.fromFloat(x.s)), .s = 0 };
            if (eql(c.name, "upperEndpoint")) return .{ .v = try num.add(a, x.v, try num.fromFloat(x.s)), .s = 0 };
            // Any other function of one value (built in, from the library, or your own): the value,
            // and the slope times the error.
            const v = try callNamed(ev, c.name, x.v);
            if (x.s == 0) return .{ .v = v, .s = 0 };
            const xf = x.v.toFloat();
            const h = 1e-6 * @max(1.0, @abs(xf));
            const up = (try callNamed(ev, c.name, try num.fromFloat(xf + h))).toFloat();
            const down = (try callNamed(ev, c.name, try num.fromFloat(xf - h))).toFloat();
            return .{ .v = v, .s = @abs((up - down) / (2 * h)) * x.s };
        },
        else => return .{ .v = try ev.eval(n, null), .s = 0 },
    }
}

/// name(value), worked out as an entry would be.
fn callNamed(ev: *eval.Eval, name: []const u8, value: Number) Error!Number {
    const a = ev.a;
    const arg = try a.create(Node);
    arg.* = .{ .number = value };
    const args = try a.alloc(*Node, 1);
    args[0] = arg;
    const call: Node = .{ .call = .{ .name = name, .args = args, .pos = 0 } };
    return ev.eval(&call, null);
}

/// `value` rounded to `places` decimals as text, with the zeros kept (1.50, not 1.5).
fn fixed(a: std.mem.Allocator, value: Number, places: i32) Error![]const u8 {
    if (places <= 0) {
        // Rounded to tens, hundreds…
        const scale = try num.pow(a, try num.fromInt(a, 10), try num.fromInt(a, -places));
        const r = try num.floor(a, try num.add(a, try num.div(a, value, scale), try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 2))));
        const whole = try num.mul(a, r, scale);
        return num.format(a, whole, .{ .decimals = 0 });
    }
    const scale = try num.pow(a, try num.fromInt(a, 10), try num.fromInt(a, places));
    const half = try num.div(a, try num.fromInt(a, 1), try num.fromInt(a, 2));
    const r = try num.floor(a, try num.add(a, try num.mul(a, value, scale), half));
    const negative = r.isNegative();
    const mag = if (negative) try num.neg(a, r) else r;
    const digits = try num.format(a, mag, .{ .decimals = 0 });
    var out: std.ArrayList(u8) = .empty;
    if (negative) try out.appendSlice(a, "−");
    const p: usize = @intCast(places);
    if (digits.len <= p) {
        try out.appendSlice(a, "0.");
        for (0..p - digits.len) |_| try out.append(a, '0');
        try out.appendSlice(a, digits);
    } else {
        try out.appendSlice(a, digits[0 .. digits.len - p]);
        try out.append(a, '.');
        try out.appendSlice(a, digits[digits.len - p ..]);
    }
    return out.items;
}

/// "12.3 ± 0.4": the error to one significant figure (two when it starts with 1), the value to the same place.
pub fn format(a: std.mem.Allocator, u: U) Error![]const u8 {
    if (u.s == 0 or !std.math.isFinite(u.s)) return num.format(a, u.v, .{ .decimals = 10 });
    const exp10: i32 = @intFromFloat(@floor(std.math.log10(u.s)));
    const lead: f64 = u.s / std.math.pow(f64, 10, @floatFromInt(exp10));
    const keep: i32 = if (lead < 1.95) 2 else 1;
    const places: i32 = keep - 1 - exp10;
    const err_text = try fixed(a, try num.fromFloat(u.s), places);
    const value_text = try fixed(a, u.v, places);
    return std.fmt.allocPrint(a, "{s} ± {s}", .{ value_text, err_text });
}

// ---- tests -------------------------------------------------------------------------------------

fn shows(want: []const u8, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    const n = try eval.parseExpr(a, text, .{}, &p);
    var ev: eval.Eval = .{ .a = a, .session = &session, .mode = .{ .angle = .radians }, .problem = &p };
    const u = try evaluate(&ev, n);
    std.testing.expectEqualStrings(want, try format(a, u)) catch |e| {
        std.debug.print("for {s}\n", .{text});
        return e;
    };
}

test "an error is carried through arithmetic" {
    try shows("5.00 ± 0.10", "5 ± 0.1");
    try shows("12.3 ± 0.4", "12.3 ± 0.4");
    try shows("8.0 ± 0.5", "(5 ± 0.3) + (3 ± 0.4)");
    try shows("10.0 ± 1.0", "(5 ± 0.5) * 2");
    try shows("1.00 ± 0.14", "(5 ± 0.5) / (5 ± 0.5)");
    try shows("25 ± 5", "(5 ± 0.5) ^ 2");
    try shows("1.00 ± 0.15", "(1 ± 0.15)");
    try shows("100 ± 20", "(1000 ± 200) / 10");
    try shows("0.5", "midpoint(0.5 ± 0.1)");
}

test "library and own functions carry the error too" {
    try shows("12.6 ± 1.3", "circle(2 ± 0.1)");
}
