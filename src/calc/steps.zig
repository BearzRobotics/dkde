//! Show your work: the steps to an answer, written the way you would on paper.
//!
//! Each step is a line of mathematics and a short note about what was done to get
//! there ("Brackets first: 4 − 1 = 3"). The kinds of entry that have steps:
//!   * arithmetic: brackets, powers, multiplication and division, then addition and
//!     subtraction, one operation at a time, fractions over a common denominator;
//!   * equations: linear (collect, move, divide), quadratic (factor or formula);
//!   * expanding and factoring polynomials;
//!   * derivatives, and two linear equations in two unknowns.
//! `explain` returns null for an entry that has none.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const symbolic = @import("symbolic.zig");
const algebra = @import("algebra.zig");
const Number = num.Number;
const Big = std.math.big.int.Managed;

pub const Error = eval.Error;

pub const Step = struct {
    /// What was done, in a few words ("Add 2 and 3").
    note: []const u8,
    /// The line of mathematics after it.
    math: []const u8,
};

pub const Ctx = struct {
    a: std.mem.Allocator,
    session: *eval.Session,
    mode: eval.Mode,
};

// ---- numbers as text ----------------------------------------------------------------------------

fn bigText(a: std.mem.Allocator, b: Big) ![]u8 {
    return b.toString(a, 10, .lower) catch return error.OutOfMemory;
}

/// Decimals are written as decimals only when the entry used a decimal point.
var prefer_decimals: bool = false;

/// 5, −3, 7/12; 0.75 when the entry was written with decimals.
pub fn numText(a: std.mem.Allocator, x: Number) Error![]u8 {
    if (!x.isExact()) return num.format(a, x, .{ .decimals = 10 });
    const negative = x.isNegative();
    const mag = if (negative) try num.neg(a, x) else x;
    const sign: []const u8 = if (negative) "−" else "";
    if (mag.exact.den.bitCountAbs() == 1) return std.fmt.allocPrint(a, "{s}{s}", .{ sign, try bigText(a, mag.exact.num) });
    // Terminates when the denominator has only the factors 2 and 5.
    var d = try mag.exact.den.clone();
    var two = try Big.initSet(a, 2);
    var five = try Big.initSet(a, 5);
    var q = try Big.init(a);
    var r = try Big.init(a);
    while (true) {
        try q.divTrunc(&r, &d, &two);
        if (!r.eqlZero()) break;
        d = try q.clone();
    }
    while (true) {
        try q.divTrunc(&r, &d, &five);
        if (!r.eqlZero()) break;
        d = try q.clone();
    }
    _ = &two;
    _ = &five;
    if (d.bitCountAbs() == 1 and prefer_decimals) {
        const dec = try num.format(a, mag, .{ .decimals = 30 });
        return std.fmt.allocPrint(a, "{s}{s}", .{ sign, dec });
    }
    return std.fmt.allocPrint(a, "{s}{s}/{s}", .{ sign, try bigText(a, mag.exact.num), try bigText(a, mag.exact.den) });
}

fn isFraction(x: Number) bool {
    return x.isExact() and x.exact.den.bitCountAbs() != 1;
}

// ---- an expression tree for stepping ------------------------------------------------------------------

const N = union(enum) {
    num: Number,
    /// Text already written (an exact form, an intermediate line), and how tightly it binds.
    raw: struct { text: []const u8, prec: u8 },
    neg: *N,
    bin: struct { op: u8, l: *N, r: *N },
    fact: *N,
    pct: *N,
    call: struct { name: []const u8, arg: *N },
    /// An expanded polynomial, written in full.
    poly: algebra.Poly,
};

fn mk(a: std.mem.Allocator, n: N) Error!*N {
    const p = try a.create(N);
    p.* = n;
    return p;
}

var allow_letters: bool = false;

fn fromNode(a: std.mem.Allocator, n: *const eval.Node) Error!?*N {
    switch (n.*) {
        .number => |v| {
            if (!v.isExact()) return null;
            return try mk(a, .{ .num = v });
        },
        .name => |nm| {
            if (!allow_letters) return null;
            return try mk(a, .{ .raw = .{ .text = nm.text, .prec = 7 } });
        },
        .unary => |u| {
            const x = (try fromNode(a, u.arg)) orelse return null;
            return switch (u.op) {
                .neg => if (x.* == .num) try mk(a, .{ .num = try num.neg(a, x.num) }) else try mk(a, .{ .neg = x }),
                .fact => try mk(a, .{ .fact = x }),
                .pct => try mk(a, .{ .pct = x }),
                .bnot => null,
            };
        },
        .binary => |b| {
            const l = (try fromNode(a, b.l)) orelse return null;
            const r = (try fromNode(a, b.r)) orelse return null;
            // 1/2 is the fraction one half, not a division to work out (when it is in lowest terms).
            if (b.op == .div and l.* == .num and r.* == .num and l.num.isInteger() and r.num.isInteger() and !r.num.isZero()) {
                const q = try num.div(a, l.num, r.num);
                if (q.exact.num.eql(l.num.exact.num) and q.exact.den.eql(r.num.exact.num)) return try mk(a, .{ .num = q });
            }
            const op: u8 = switch (b.op) {
                .add => '+',
                .sub => '-',
                .mul => '*',
                .div => '/',
                .pow => '^',
                .mod => '%',
                else => return null,
            };
            return try mk(a, .{ .bin = .{ .op = op, .l = l, .r = r } });
        },
        .call => |c| {
            if (c.args.len != 1) return null;
            const x = (try fromNode(a, c.args[0])) orelse return null;
            return try mk(a, .{ .call = .{ .name = c.name, .arg = x } });
        },
    }
}

/// A letter, or a power of one (x, x²).
fn startsWithLetter(n: *const N) bool {
    return switch (n.*) {
        .raw => |r| r.prec == 7 and r.text.len > 0 and std.ascii.isAlphabetic(r.text[0]),
        .bin => |b| b.op == '^' and startsWithLetter(b.l),
        else => false,
    };
}

fn precOf(n: *const N) u8 {
    return switch (n.*) {
        .num => |v| if (v.isNegative() or isFraction(v)) 3 else 7,
        .raw => |r| r.prec,
        .neg => 3,
        .bin => |b| switch (b.op) {
            '+', '-' => 1,
            '*', '/', '%' => 2,
            else => 4,
        },
        .fact, .pct => 5,
        .call => 6,
        .poly => |p| if (p.terms.len > 1) 1 else 7,
    };
}

/// The expression as text, with brackets where the order needs them.
fn write(a: std.mem.Allocator, n: *const N) Error![]const u8 {
    return writePrec(a, n, 0, false);
}

fn wrap(a: std.mem.Allocator, text: []const u8, need: bool) ![]const u8 {
    return if (need) std.fmt.allocPrint(a, "({s})", .{text}) else text;
}

fn writePrec(a: std.mem.Allocator, n: *const N, outer: u8, right: bool) Error![]const u8 {
    switch (n.*) {
        .num => |v| {
            const t = try numText(a, v);
            // A negative number after an operator, or under a power, is bracketed.
            const need = (v.isNegative() and (outer > 0 and (right or outer >= 4))) or (isFraction(v) and outer >= 4);
            return wrap(a, t, need);
        },
        .raw => |r| return wrap(a, r.text, r.prec < outer),
        .poly => |p| return wrap(a, try algebra.text(a, p), precOf(n) < outer),
        .neg => |x| {
            const inner = try writePrec(a, x, 3, false);
            return wrap(a, try std.fmt.allocPrint(a, "−{s}", .{inner}), outer > 3 or (outer > 0 and right));
        },
        .bin => |b| {
            const p = precOf(n);
            switch (b.op) {
                '+', '-' => {
                    const l = try writePrec(a, b.l, p, false);
                    const r = try writePrec(a, b.r, p + 1, true);
                    return wrap(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ l, if (b.op == '+') "+" else "−", r }), outer > p);
                },
                '*', '%' => {
                    const l = try writePrec(a, b.l, p, false);
                    const r = try writePrec(a, b.r, p + 1, true);
                    // (x + 1)(x + 2): two brackets side by side.
                    if (b.op == '*' and precOf(b.l) < p and precOf(b.r) < p and b.l.* != .raw and b.r.* != .raw) {
                        return wrap(a, try std.fmt.allocPrint(a, "{s}{s}", .{ l, r }), outer > p);
                    }
                    // 2x, 3(x + 1): a number in front of a letter or a bracket is written without a sign.
                    if (b.op == '*' and b.l.* == .num and !isFraction(b.l.num) and !b.l.num.isNegative() and
                        (startsWithLetter(b.r) or (b.r.* == .bin and precOf(b.r) < p)))
                    {
                        return wrap(a, try std.fmt.allocPrint(a, "{s}{s}", .{ l, r }), outer > p);
                    }
                    return wrap(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ l, if (b.op == '*') "×" else "mod", r }), outer > p);
                },
                '/' => {
                    const l = try writePrec(a, b.l, p + 1, false);
                    const r = try writePrec(a, b.r, p + 1, true);
                    return wrap(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ l, r }), outer > p);
                },
                else => {
                    const l = try writePrec(a, b.l, p + 1, false);
                    const r = try writePrec(a, b.r, p, true);
                    return wrap(a, try writeSuperscript(a, l, r, b.r), outer > p);
                },
            }
        },
        .fact => |x| return std.fmt.allocPrint(a, "{s}!", .{try writePrec(a, x, 6, false)}),
        .pct => |x| return std.fmt.allocPrint(a, "{s}%", .{try writePrec(a, x, 6, false)}),
        .call => |c| {
            const inner = try write(a, c.arg);
            if (std.mem.eql(u8, c.name, "sqrt")) return std.fmt.allocPrint(a, "√{s}", .{try wrap(a, inner, precOf(c.arg) < 7)});
            return std.fmt.allocPrint(a, "{s}({s})", .{ c.name, inner });
        },
    }
}

const sup_digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };

/// 3² for small whole exponents, 3^(1/2) otherwise.
fn writeSuperscript(a: std.mem.Allocator, base: []const u8, exp_text: []const u8, exp: *const N) ![]const u8 {
    if (exp.* == .num and exp.num.isExact() and exp.num.isInteger() and !exp.num.isNegative()) {
        if (num.intValue(exp.num)) |k| if (k >= 0 and k < 100) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, base);
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{k}) catch "";
            for (s) |c| try out.appendSlice(a, sup_digits[c - '0']);
            return out.items;
        };
    }
    return std.fmt.allocPrint(a, "{s}^{s}", .{ base, exp_text });
}

// ---- choosing the next operation ----------------------------------------------------------------------------

fn isNumber(n: *const N) bool {
    return n.* == .num;
}

/// An operation whose operands are all numbers: it can be worked out now.
fn ready(n: *const N) bool {
    return switch (n.*) {
        .bin => |b| isNumber(b.l) and isNumber(b.r),
        .neg => |x| isNumber(x),
        .fact => |x| isNumber(x),
        .pct => |x| isNumber(x),
        .call => |c| isNumber(c.arg),
        else => false,
    };
}

const Pick = struct { node: *const N, rank: u32 };

/// How early an operation goes: inside more brackets first, then powers and functions, then
/// multiplication and division, then addition and subtraction; on a tie, the leftmost.
fn rankOf(n: *const N, brackets: u32) u32 {
    const op_rank: u32 = switch (n.*) {
        .call, .fact, .pct => 4,
        .neg => 3,
        .bin => |b| switch (b.op) {
            '^' => 4,
            '*', '/', '%' => 2,
            else => 1,
        },
        else => 0,
    };
    return brackets * 10 + op_rank;
}

fn findNext(n: *const N, brackets: u32, parent_prec: u8, best: *?Pick) void {
    const p = precOf(n);
    const inside = brackets + @as(u32, if (parent_prec > p and parent_prec != 0 and n.* != .num) 1 else 0);
    if (ready(n)) {
        const r = rankOf(n, inside);
        if (best.* == null or r > best.*.?.rank) best.* = .{ .node = n, .rank = r };
        return;
    }
    switch (n.*) {
        .bin => |b| {
            findNext(b.l, inside, p, best);
            findNext(b.r, inside, p, best);
        },
        .neg => |x| findNext(x, inside, p, best),
        .fact => |x| findNext(x, inside, p, best),
        .pct => |x| findNext(x, inside, p, best),
        .call => |c| findNext(c.arg, inside, p, best),
        else => {},
    }
}

fn replace(a: std.mem.Allocator, n: *const N, target: *const N, with: *N) Error!*N {
    if (n == target) return with;
    switch (n.*) {
        .bin => |b| return mk(a, .{ .bin = .{ .op = b.op, .l = try replace(a, b.l, target, with), .r = try replace(a, b.r, target, with) } }),
        .neg => |x| return mk(a, .{ .neg = try replace(a, x, target, with) }),
        .fact => |x| return mk(a, .{ .fact = try replace(a, x, target, with) }),
        .pct => |x| return mk(a, .{ .pct = try replace(a, x, target, with) }),
        .call => |c| return mk(a, .{ .call = .{ .name = c.name, .arg = try replace(a, c.arg, target, with) } }),
        else => return @constCast(n),
    }
}

// ---- working out one operation ----------------------------------------------------------------------------------

const Between = struct { note: []const u8, text: []const u8 };

const Done = struct {
    /// The number the operation comes to (null when it has no number: an irrational root).
    value: ?Number,
    /// What it was, for the note: "Add 2 + 3 = 5".
    note: []const u8,
    /// Lines before the result, each the operation in another form (common denominators).
    between: []const Between = &.{},
};

fn lcmBig(a: std.mem.Allocator, x: Big, y: Big) Error!Big {
    var g = try Big.init(a);
    try g.gcd(&x, &y);
    var q = try Big.init(a);
    var r = try Big.init(a);
    try q.divTrunc(&r, &x, &g);
    var out = try Big.init(a);
    try out.mul(&q, &y);
    return out;
}

fn intNumber(a: std.mem.Allocator, b: Big) Error!Number {
    return .{ .exact = .{ .num = b, .den = try Big.initSet(a, 1) } };
}

/// The fraction n/d with a given denominator (for a common denominator).
fn overDenominator(a: std.mem.Allocator, x: Number, d: Big) Error![]u8 {
    var scaled = try Big.init(a);
    var q = try Big.init(a);
    var r = try Big.init(a);
    try q.divTrunc(&r, &d, &x.exact.den);
    try scaled.mul(&x.exact.num, &q);
    const negative = !scaled.isPositive() and !scaled.eqlZero();
    scaled.abs();
    return std.fmt.allocPrint(a, "{s}{s}/{s}", .{ if (negative) "−" else "", try bigText(a, scaled), try bigText(a, d) });
}

fn isSquare(a: std.mem.Allocator, x: Number) Error!?Number {
    if (x.isNegative()) return null;
    return num.root(a, x, 2);
}

fn work(ctx: Ctx, n: *const N) Error!Done {
    const a = ctx.a;
    switch (n.*) {
        .neg => |x| {
            const v = try num.neg(a, x.num);
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "Negate {s}", .{try numText(a, x.num)}) };
        },
        .fact => |x| {
            const v = try num.factorial(a, x.num);
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s}! = {s}", .{ try numText(a, x.num), try numText(a, v) }) };
        },
        .pct => |x| {
            const v = try num.div(a, x.num, try num.fromInt(a, 100));
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s}% means {s} ÷ 100", .{ try numText(a, x.num), try numText(a, x.num) }) };
        },
        .call => |c| return workFunction(ctx, c.name, c.arg.num),
        .bin => |b| return workBinary(ctx, b.op, b.l.num, b.r.num),
        else => return error.Domain,
    }
}

fn workFunction(ctx: Ctx, name: []const u8, x: Number) Error!Done {
    const a = ctx.a;
    if (std.mem.eql(u8, name, "sqrt")) {
        if (x.isNegative()) return error.Domain;
        if (try isSquare(a, x)) |r| {
            return .{ .value = r, .note = try std.fmt.allocPrint(a, "√{s} = {s}, because {s}² = {s}", .{ try numText(a, x), try numText(a, r), try numText(a, r), try numText(a, x) }) };
        }
        return .{ .value = null, .note = try std.fmt.allocPrint(a, "√{s} is not a whole square: it stays a root", .{try numText(a, x)}) };
    }
    // Any other function: the value (exact when the exact form is a fraction).
    var parse_problem: eval.Problem = .{};
    const node = try eval.parseExpr(a, try std.fmt.allocPrint(a, "{s}({s})", .{ name, try numText(a, x) }), ctx.mode, &parse_problem);
    var problem: eval.Problem = .{};
    var ev: eval.Eval = .{ .a = a, .session = ctx.session, .mode = ctx.mode, .problem = &problem };
    if (symbolic.evaluate(.{ .a = a, .session = ctx.session, .mode = ctx.mode }, node) catch null) |sym| {
        if (sym.isRational()) {
            const v: Number = if (sym.terms.len == 0) try num.fromInt(a, 0) else sym.terms[0].c;
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s}({s}) = {s}", .{ name, try numText(a, x), try numText(a, v) }) };
        }
    }
    const v = try ev.eval(node, null);
    return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s}({s}) ≈ {s}", .{ name, try numText(a, x), try numText(a, v) }) };
}

fn workBinary(ctx: Ctx, op: u8, x: Number, y: Number) Error!Done {
    const a = ctx.a;
    const xt = try numText(a, x);
    const yt = try numText(a, y);
    switch (op) {
        '+', '-' => {
            const plus = op == '+';
            const v = if (plus) try num.add(a, x, y) else try num.sub(a, x, y);
            const verb: []const u8 = if (plus) "Add" else "Subtract";
            var between: std.ArrayList(Between) = .empty;
            if (isFraction(x) or isFraction(y)) {
                const d = try lcmBig(a, x.exact.den, y.exact.den);
                if (!x.exact.den.eql(y.exact.den)) {
                    try between.append(a, .{
                        .note = try std.fmt.allocPrint(a, "Write both over the common denominator {s}", .{try bigText(a, d)}),
                        .text = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ try overDenominator(a, x, d), if (plus) "+" else "−", try overDenominator(a, y, d) }),
                    });
                }
                var top = try Big.init(a);
                var xs = try Big.init(a);
                var ys = try Big.init(a);
                var qq = try Big.init(a);
                var rr = try Big.init(a);
                try qq.divTrunc(&rr, &d, &x.exact.den);
                try xs.mul(&x.exact.num, &qq);
                try qq.divTrunc(&rr, &d, &y.exact.den);
                try ys.mul(&y.exact.num, &qq);
                if (plus) try top.add(&xs, &ys) else try top.sub(&xs, &ys);
                const t_neg = !top.isPositive() and !top.eqlZero();
                top.abs();
                const combined = try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ if (t_neg) "−" else "", try bigText(a, top), try bigText(a, d) });
                const result_text = try numText(a, v);
                if (!std.mem.eql(u8, combined, result_text)) {
                    try between.append(a, .{ .note = try std.fmt.allocPrint(a, "{s} the numerators, keep the denominator {s}", .{ verb, try bigText(a, d) }), .text = combined });
                    return .{ .value = v, .note = try std.fmt.allocPrint(a, "Reduce {s} to lowest terms", .{combined}), .between = between.items };
                }
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} the numerators, keep the denominator {s}", .{ verb, try bigText(a, d) }), .between = between.items };
            }
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ verb, xt, if (plus) "and" else "from", yt }) };
        },
        '*' => {
            const v = try num.mul(a, x, y);
            var between: std.ArrayList(Between) = .empty;
            if (isFraction(x) or isFraction(y)) {
                const xn = try intNumber(a, x.exact.num);
                const yn = try intNumber(a, y.exact.num);
                const dn = try num.mul(a, try intNumber(a, x.exact.den), try intNumber(a, y.exact.den));
                const raw = try std.fmt.allocPrint(a, "{s}/{s}", .{ try numText(a, try num.mul(a, xn, yn)), try numText(a, dn) });
                if (!std.mem.eql(u8, raw, try numText(a, v))) {
                    try between.append(a, .{ .note = "Multiply the numerators and multiply the denominators", .text = raw });
                    return .{ .value = v, .note = try std.fmt.allocPrint(a, "Reduce {s} to lowest terms", .{raw}), .between = between.items };
                }
                return .{ .value = v, .note = "Multiply the numerators and multiply the denominators" };
            }
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "Multiply {s} × {s}", .{ xt, yt }) };
        },
        '/' => {
            if (y.isZero()) return error.DivisionByZero;
            const v = try num.div(a, x, y);
            var between: std.ArrayList(Between) = .empty;
            if (isFraction(x) or isFraction(y)) {
                // Dividing by a fraction: multiply by its reciprocal.
                const recip = try num.div(a, try num.fromInt(a, 1), y);
                try between.append(a, .{
                    .note = "Dividing by a fraction is multiplying by its reciprocal",
                    .text = try std.fmt.allocPrint(a, "{s} × {s}", .{ try wrapFraction(a, x), try wrapFraction(a, recip) }),
                });
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "Multiply {s} × {s}", .{ try wrapFraction(a, x), try wrapFraction(a, recip) }), .between = between.items };
            }
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "Divide {s} ÷ {s}", .{ xt, yt }) };
        },
        '^' => {
            const v = try num.pow(a, x, y);
            if (!v.isExact()) return error.Domain;
            const word: []const u8 = if (num.intValue(y) == 2) "Square" else if (num.intValue(y) == 3) "Cube" else "Raise";
            if (num.intValue(y)) |k| if (k >= 2 and k <= 6 and x.isExact() and x.isInteger()) {
                var repeated: std.ArrayList(u8) = .empty;
                var i: i64 = 0;
                while (i < k) : (i += 1) {
                    if (i > 0) try repeated.appendSlice(a, " × ");
                    try repeated.appendSlice(a, try wrapNeg(a, x));
                }
                var between: std.ArrayList(Between) = .empty;
                try between.append(a, .{ .note = try std.fmt.allocPrint(a, "{s}: write the multiplication out", .{word}), .text = repeated.items });
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "Multiply: {s} to the power {s} is {s}", .{ xt, yt, try numText(a, v) }), .between = between.items };
            };
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} {s} to the power {s}", .{ word, xt, yt }) };
        },
        '%' => {
            const v = try num.mod(a, x, y);
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} mod {s}: the remainder", .{ xt, yt }) };
        },
        else => return error.Domain,
    }
}

fn wrapFraction(a: std.mem.Allocator, x: Number) ![]const u8 {
    const t = try numText(a, x);
    return if (isFraction(x) or x.isNegative()) std.fmt.allocPrint(a, "({s})", .{t}) else t;
}

fn wrapNeg(a: std.mem.Allocator, x: Number) ![]const u8 {
    const t = try numText(a, x);
    return if (x.isNegative()) std.fmt.allocPrint(a, "({s})", .{t}) else t;
}

// ---- arithmetic ------------------------------------------------------------------------------------------------------

const max_steps = 60;

/// The steps of an expression with no letters.
fn arithmetic(ctx: Ctx, root_node: *const eval.Node) Error!?[]Step {
    const a = ctx.a;
    var tree = (try fromNode(a, root_node)) orelse return null;
    var steps: std.ArrayList(Step) = .empty;
    try steps.append(a, .{ .note = "Start", .math = try write(a, tree) });
    var guard: usize = 0;
    while (tree.* != .num and guard < max_steps) : (guard += 1) {
        var best: ?Pick = null;
        findNext(tree, 0, 0, &best);
        const pick = best orelse break;
        const done = try work(ctx, pick.node);
        const value = done.value orelse {
            try steps.append(a, .{ .note = done.note, .math = try write(a, tree) });
            break;
        };
        const bracketed = pick.rank >= 10;
        const note = if (bracketed) try std.fmt.allocPrint(a, "Brackets first: {s}", .{done.note}) else done.note;
        // Intermediate forms of the same operation (common denominators), then the result.
        for (done.between) |line| {
            const raw = try mk(a, .{ .raw = .{ .text = line.text, .prec = precOf(pick.node) } });
            try steps.append(a, .{ .note = line.note, .math = try write(a, try replace(a, tree, pick.node, raw)) });
        }
        const result = try mk(a, .{ .num = value });
        tree = try replace(a, tree, pick.node, result);
        try steps.append(a, .{ .note = note, .math = try write(a, tree) });
    }
    return steps.items;
}

// ---- equations ---------------------------------------------------------------------------------------------------------------

fn push(a: std.mem.Allocator, list: *std.ArrayList(Step), note: []const u8, math: []const u8) Error!void {
    try list.append(a, .{ .note = note, .math = math });
}

fn eqText(a: std.mem.Allocator, l: []const u8, r: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "{s} = {s}", .{ l, r });
}

fn polyOf(a: std.mem.Allocator, c: []const Number, name: []const u8) Error![]const u8 {
    return algebra.text(a, try algebra.fromDense(a, c, name));
}

fn coefAt(a: std.mem.Allocator, c: []const Number, i: usize) Error!Number {
    if (i < c.len) return c[i];
    return num.fromInt(a, 0);
}

/// "+ 3" or "− 3x": a term to add to both sides, written with its sign.
fn withSign(a: std.mem.Allocator, term: []const u8, negative: bool) Error![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ if (negative) "−" else "+", term });
}

fn absNumber(a: std.mem.Allocator, x: Number) Error!Number {
    return if (x.isNegative()) num.neg(a, x) else x;
}

fn linearEquation(ctx: Ctx, start: []const u8, cl: []const Number, cr: []const Number, name: []const u8) Error![]Step {
    const a = ctx.a;
    var steps: std.ArrayList(Step) = .empty;
    try push(a, &steps, "Start", start);
    // Combined form of each side.
    var a1 = try coefAt(a, cl, 1);
    var b1 = try coefAt(a, cl, 0);
    var a2 = try coefAt(a, cr, 1);
    var b2 = try coefAt(a, cr, 0);
    var lc = [_]Number{ b1, a1 };
    var rc = [_]Number{ b2, a2 };
    var lt = try polyOf(a, &lc, name);
    var rt = try polyOf(a, &rc, name);
    const combined = try eqText(a, lt, rt);
    if (!std.mem.eql(u8, combined, start)) try push(a, &steps, "Expand the brackets and combine like terms on each side", combined);
    // The letter on both sides: subtract the right one from both.
    if (!a2.isZero()) {
        const term = try polyOf(a, &[_]Number{ try num.fromInt(a, 0), try absNumber(a, a2) }, name);
        const sign = try withSign(a, term, !a2.isNegative());
        try push(a, &steps, try std.fmt.allocPrint(a, "{s} {s} {s} both sides", .{ if (a2.isNegative()) "Add" else "Subtract", term, if (a2.isNegative()) "to" else "from" }), try eqText(a, try std.fmt.allocPrint(a, "{s} {s}", .{ lt, sign }), try std.fmt.allocPrint(a, "{s} {s}", .{ rt, sign })));
        a1 = try num.sub(a, a1, a2);
        a2 = try num.fromInt(a, 0);
        lc = .{ b1, a1 };
        rc = .{ b2, a2 };
        lt = try polyOf(a, &lc, name);
        rt = try polyOf(a, &rc, name);
        try push(a, &steps, "Simplify", try eqText(a, lt, rt));
    }
    // The letter has gone: the equation is always true, or never.
    if (a1.isZero()) {
        const same = (try num.order(a, b1, b2)) == .eq;
        try push(a, &steps, if (same) "Both sides are the same: true for every value" else "The two sides can never be equal: no value works", try eqText(a, try numText(a, b1), try numText(a, b2)));
        return steps.items;
    }
    // The constant on the left: move it across.
    if (!b1.isZero()) {
        const abs_b = try absNumber(a, b1);
        const sign = try withSign(a, try numText(a, abs_b), !b1.isNegative());
        try push(a, &steps, try std.fmt.allocPrint(a, "{s} {s} {s} both sides", .{ if (b1.isNegative()) "Add" else "Subtract", try numText(a, abs_b), if (b1.isNegative()) "to" else "from" }), try eqText(a, try std.fmt.allocPrint(a, "{s} {s}", .{ lt, sign }), try std.fmt.allocPrint(a, "{s} {s}", .{ rt, sign })));
        b2 = try num.sub(a, b2, b1);
        b1 = try num.fromInt(a, 0);
        lc = .{ b1, a1 };
        rc = .{ b2, a2 };
        lt = try polyOf(a, &lc, name);
        rt = try polyOf(a, &rc, name);
        try push(a, &steps, "Simplify", try eqText(a, lt, rt));
    }
    if (a1.isZero()) {
        const text = if (b2.isZero()) "Both sides are 0: true for every value" else "0 equals a number that is not 0: no value works";
        try push(a, &steps, text, if (b2.isZero()) "0 = 0" else try eqText(a, "0", try numText(a, b2)));
        return steps.items;
    }
    // A fraction in front of the letter: multiply by its reciprocal.
    if (isFraction(a1)) {
        const recip = try num.div(a, try num.fromInt(a, 1), a1);
        const rec_text = try wrapFraction(a, recip);
        const rhs = try numText(a, b2);
        try push(a, &steps, try std.fmt.allocPrint(a, "Multiply both sides by {s}, the reciprocal of {s}", .{ try numText(a, recip), try numText(a, a1) }), try eqText(a, try std.fmt.allocPrint(a, "{s}({s})", .{ rec_text, lt }), try std.fmt.allocPrint(a, "{s}({s})", .{ rec_text, rhs })));
        const answer0 = try eqText(a, name, try numText(a, try num.div(a, b2, a1)));
        try push(a, &steps, "Simplify", answer0);
        return steps.items;
    }
    // Divide by the coefficient.
    if (!num.isOneNumber(a1)) {
        const at = try numText(a, a1);
        const wrapped = if (a1.isNegative() or isFraction(a1)) try std.fmt.allocPrint(a, "({s})", .{at}) else at;
        const rhs = try numText(a, b2);
        const rhs_w = if (b2.isNegative() or isFraction(b2)) try std.fmt.allocPrint(a, "({s})", .{rhs}) else rhs;
        try push(a, &steps, try std.fmt.allocPrint(a, "Divide both sides by {s}", .{at}), try eqText(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ lt, wrapped }), try std.fmt.allocPrint(a, "{s}/{s}", .{ rhs_w, wrapped })));
    }
    const x = try num.div(a, b2, a1);
    const answer = try eqText(a, name, try numText(a, x));
    if (steps.items.len > 0 and std.mem.eql(u8, steps.items[steps.items.len - 1].math, answer)) return steps.items;
    try push(a, &steps, if (num.isOneNumber(a1)) "The letter is alone" else "Simplify", answer);
    return steps.items;
}

/// The squares inside a whole number: 72 = 6² × 2.
fn radicalText(a: std.mem.Allocator, n: u64) Error!?[]const u8 {
    var sq: u64 = 1;
    var rest = n;
    var p: u64 = 2;
    while (p * p <= rest) : (p += 1) {
        while (rest % (p * p) == 0) {
            rest /= p * p;
            sq *= p;
        }
    }
    if (sq == 1) return null;
    if (rest == 1) return try std.fmt.allocPrint(a, "√{d} = √({d} × {d}) = {d}", .{ n, sq * sq, rest, sq });
    return try std.fmt.allocPrint(a, "√{d} = √({d} × {d}) = {d}√{d}", .{ n, sq * sq, rest, sq, rest });
}

fn linearFactorText(a: std.mem.Allocator, f: []const Number, name: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "({s})", .{try polyOf(a, f, name)});
}

/// A whole number with a proper minus sign.
fn iText(a: std.mem.Allocator, v: i64) Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ if (v < 0) "−" else "", @abs(v) });
}

/// The same, in brackets when negative: (−3).
fn iWrap(a: std.mem.Allocator, v: i64) Error![]const u8 {
    return if (v < 0) std.fmt.allocPrint(a, "({s})", .{try iText(a, v)}) else iText(a, v);
}

fn gcdInt(x: i64, y: i64) i64 {
    return @intCast(std.math.gcd(@as(u64, @intCast(@abs(x))), @as(u64, @intCast(@abs(y)))));
}

fn quadraticEquation(ctx: Ctx, start: []const u8, diff: []const Number, name: []const u8) Error![]Step {
    const a = ctx.a;
    var steps: std.ArrayList(Step) = .empty;
    try push(a, &steps, "Start", start);
    var c = try a.dupe(Number, algebra.trimmed(diff));
    const standard = try eqText(a, try polyOf(a, c, name), "0");
    const pure_square = c.len == 3 and c[1].isZero() and !c[0].isZero();
    if (!pure_square and !std.mem.eql(u8, standard, start)) try push(a, &steps, "Move everything to one side and combine like terms", standard);
    // Whole-number coefficients with a positive leading one.
    const pr = try algebra.primitive(a, c);
    if (!num.isOneNumber(pr.content)) {
        const k = pr.content;
        const note = if (k.isInteger() and !k.isNegative())
            try std.fmt.allocPrint(a, "Divide both sides by {s} (every coefficient has that factor)", .{try numText(a, k)})
        else if (k.isInteger())
            try std.fmt.allocPrint(a, "Divide both sides by {s}", .{try numText(a, k)})
        else
            try std.fmt.allocPrint(a, "Multiply both sides by {s} to clear the fractions", .{try numText(a, try num.div(a, try num.fromInt(a, 1), k))});
        c = pr.prim;
        try push(a, &steps, note, try eqText(a, try polyOf(a, c, name), "0"));
    }
    const qa = num.intValue(c[2]) orelse return steps.items;
    const qb = num.intValue(c[1]) orelse return steps.items;
    const qc = num.intValue(c[0]) orelse return steps.items;
    const A = try numText(a, c[2]);
    const B = try numText(a, c[1]);
    const C = try numText(a, c[0]);
    // c = 0: take the letter out.
    if (qc == 0) {
        const inner = try polyOf(a, &[_]Number{ c[1], c[2] }, name);
        try push(a, &steps, "Factor out the common letter", try std.fmt.allocPrint(a, "{s}({s}) = 0", .{ name, inner }));
        const r2 = try num.div(a, try num.neg(a, c[1]), c[2]);
        try push(a, &steps, "A product is zero when one factor is zero", try std.fmt.allocPrint(a, "{s} = 0   or   {s} = 0", .{ name, inner }));
        try push(a, &steps, "Solve each", try std.fmt.allocPrint(a, "{s} = 0   or   {s} = {s}", .{ name, name, try numText(a, r2) }));
        return steps.items;
    }
    // b = 0: a square.
    if (qb == 0) {
        const rhs = try num.div(a, try num.neg(a, c[0]), c[2]);
        if (!num.isOneNumber(c[2]) or true) {
            try push(a, &steps, try std.fmt.allocPrint(a, "Move {s} to the other side", .{C}), try eqText(a, try polyOf(a, &[_]Number{ try num.fromInt(a, 0), try num.fromInt(a, 0), c[2] }, name), try numText(a, try num.neg(a, c[0]))));
        }
        if (!num.isOneNumber(c[2])) try push(a, &steps, try std.fmt.allocPrint(a, "Divide both sides by {s}", .{A}), try eqText(a, try std.fmt.allocPrint(a, "{s}²", .{name}), try numText(a, rhs)));
        const sym = try symbolic.rational(a, rhs);
        if (rhs.isNegative()) {
            const pos = try symbolic.rational(a, try num.neg(a, rhs));
            const root = (try symbolic.sqrt(a, pos)) orelse return steps.items;
            try push(a, &steps, "A square is never negative: the roots are not real. Take the square root of both sides", try eqText(a, name, try std.fmt.allocPrint(a, "±{s}i", .{try symbolic.format(a, root)})));
            return steps.items;
        }
        const root = (try symbolic.sqrt(a, sym)) orelse return steps.items;
        try push(a, &steps, "Take the square root of both sides (both signs)", try eqText(a, name, try std.fmt.allocPrint(a, "±√{s}", .{try wrapFraction(a, rhs)})));
        if (rhs.isExact() and rhs.isInteger() and num.intValue(rhs) != null) {
            if (try radicalText(a, @intCast(num.intValue(rhs).?))) |rt| try push(a, &steps, "Simplify the root", rt);
        }
        try push(a, &steps, "The two solutions", try eqText(a, name, try std.fmt.allocPrint(a, "±{s}", .{try symbolic.format(a, root)})));
        return steps.items;
    }
    // Whole-number factors?
    const fac = try algebra.factorDense(a, c);
    var linear_factors: usize = 0;
    var total_mult: u32 = 0;
    for (fac.factors) |f| {
        if (algebra.degree(f.coefs) == 1) linear_factors += 1;
        total_mult += f.mult * @as(u32, @intCast(algebra.degree(f.coefs)));
    }
    if (linear_factors == fac.factors.len and total_mult == 2) {
        // Find the two numbers.
        const ac = qa * qc;
        var m: i64 = 0;
        var n: i64 = 0;
        const divs = (try algebra.divisors(a, try num.fromInt(a, ac))) orelse return steps.items;
        var found = false;
        outer: for (divs) |d| {
            var sign: i64 = 1;
            while (sign >= -1) : (sign -= 2) {
                const mm = sign * @as(i64, @intCast(d));
                if (@rem(ac, mm) != 0) continue;
                const nn = @divExact(ac, mm);
                if (mm + nn == qb) {
                    if (mm <= nn) {
                        m = mm;
                        n = nn;
                    } else {
                        m = nn;
                        n = mm;
                    }
                    found = true;
                    break :outer;
                }
            }
        }
        if (!found) return steps.items;
        if (qa == 1) {
            try push(a, &steps, try std.fmt.allocPrint(a, "Find two numbers that multiply to {s} and add to {s}: {s} and {s}", .{ C, B, try iText(a, m), try iText(a, n) }), try std.fmt.allocPrint(a, "{s} × {s} = {s},   {s} + {s} = {s}", .{ try iWrap(a, m), try iWrap(a, n), try iText(a, qc), try iWrap(a, m), try iWrap(a, n), try iText(a, qb) }));
        } else {
            try push(a, &steps, try std.fmt.allocPrint(a, "Multiply {s} and {s}: {s}. Find two numbers that multiply to {s} and add to {s}: {s} and {s}", .{ A, C, try iText(a, ac), try iText(a, ac), B, try iText(a, m), try iText(a, n) }), try std.fmt.allocPrint(a, "{s} × {s} = {s},   {s} + {s} = {s}", .{ try iWrap(a, m), try iWrap(a, n), try iText(a, ac), try iWrap(a, m), try iWrap(a, n), try iText(a, qb) }));
            // Split the middle term, group in pairs, take out what each pair shares.
            var pair = [2]i64{ m, n };
            var attempt: usize = 0;
            while (attempt < 2) : (attempt += 1) {
                const first = pair[0];
                const second = pair[1];
                const g1 = gcdInt(qa, first);
                const in1a = @divExact(qa, g1);
                const in1b = @divExact(first, g1);
                // The second pair, n x + c, must be g2 times the same bracket.
                if (in1a == 0 or @rem(second, in1a) != 0 or @divExact(second, in1a) * in1b != qc) {
                    pair = .{ n, m };
                    continue;
                }
                const g2 = @divExact(second, in1a);
                const sq_term = try termStr(a, qa, 2, name, true);
                try push(a, &steps, "Split the middle term", try std.fmt.allocPrint(a, "{s}{s}{s}{s} = 0", .{ sq_term, try termStr(a, first, 1, name, false), try termStr(a, second, 1, name, false), try termStr(a, qc, 0, name, false) }));
                try push(a, &steps, "Group the terms in pairs", try std.fmt.allocPrint(a, "({s}{s}) + ({s}{s}) = 0", .{ sq_term, try termStr(a, first, 1, name, false), try termStr(a, second, 1, name, true), try termStr(a, qc, 0, name, false) }));
                const bracket = try polyOf(a, &[_]Number{ try num.fromInt(a, in1b), try num.fromInt(a, in1a) }, name);
                const g1x = try polyOf(a, &[_]Number{ try num.fromInt(a, 0), try num.fromInt(a, g1) }, name);
                const g2_mag: i64 = @intCast(@abs(g2));
                try push(a, &steps, "Take out what each pair shares", try std.fmt.allocPrint(a, "{s}({s}) {s} {d}({s}) = 0", .{ g1x, bracket, if (g2 < 0) "−" else "+", g2_mag, bracket }));
                const outer_factor = try polyOf(a, &[_]Number{ try num.fromInt(a, g2), try num.fromInt(a, g1) }, name);
                try push(a, &steps, try std.fmt.allocPrint(a, "Take out the common bracket ({s})", .{bracket}), try std.fmt.allocPrint(a, "({s})({s}) = 0", .{ outer_factor, bracket }));
                break;
            }
        }
        // The factored form, then each factor to zero.
        var product: std.ArrayList(u8) = .empty;
        var zeros: std.ArrayList(u8) = .empty;
        var answers: std.ArrayList(u8) = .empty;
        for (fac.factors) |f| {
            const ft = try linearFactorText(a, f.coefs, name);
            const r1 = try num.div(a, try num.neg(a, f.coefs[0]), f.coefs[1]);
            try product.appendSlice(a, ft);
            if (f.mult > 1) try product.appendSlice(a, "²");
            if (zeros.items.len > 0) try zeros.appendSlice(a, "   or   ");
            try zeros.print(a, "{s} = 0", .{try polyOf(a, f.coefs, name)});
            if (answers.items.len > 0) try answers.appendSlice(a, "   or   ");
            try answers.print(a, "{s} = {s}", .{ name, try numText(a, r1) });
        }
        if (qa == 1) try push(a, &steps, "Write it as a product of brackets", try std.fmt.allocPrint(a, "{s} = 0", .{product.items}));
        try push(a, &steps, "A product is zero when one factor is zero", zeros.items);
        try push(a, &steps, "Solve each", answers.items);
        return steps.items;
    }
    // The quadratic formula.
    try push(a, &steps, "No whole-number factors work: use the quadratic formula", try std.fmt.allocPrint(a, "{s} = (−b ± √(b² − 4ac)) / (2a)", .{name}));
    try push(a, &steps, try std.fmt.allocPrint(a, "Here a = {s}, b = {s}, c = {s}", .{ A, B, C }), try std.fmt.allocPrint(a, "{s} = (−({s}) ± √(({s})² − 4({s})({s}))) / (2({s}))", .{ name, B, B, A, C, A }));
    const disc = try num.sub(a, try num.mul(a, c[1], c[1]), try num.mul(a, try num.fromInt(a, 4), try num.mul(a, c[2], c[0])));
    const dt = try numText(a, disc);
    try push(a, &steps, "Work out what is under the root (the discriminant)", try std.fmt.allocPrint(a, "({s})² − 4({s})({s}) = {s}", .{ B, A, C, dt }));
    const neg_b = try numText(a, try num.neg(a, c[1]));
    const two_a = try numText(a, try num.mul(a, try num.fromInt(a, 2), c[2]));
    if (disc.isNegative()) {
        const mag = try num.neg(a, disc);
        try push(a, &steps, "The discriminant is negative: there is no real root, the roots are complex (i = √−1)", try std.fmt.allocPrint(a, "{s} = ({s} ± √({s})) / {s}", .{ name, neg_b, dt, two_a }));
        if (num.intValue(mag)) |mv| if (try radicalText(a, @intCast(mv))) |rt| try push(a, &steps, "Simplify the root of the positive part, and put i in front", rt);
    } else {
        try push(a, &steps, "Put the numbers in", try std.fmt.allocPrint(a, "{s} = ({s} ± √{s}) / {s}", .{ name, neg_b, dt, two_a }));
        if (num.intValue(disc)) |dv| if (try radicalText(a, @intCast(dv))) |rt| try push(a, &steps, "Simplify the root", rt);
    }
    if (try algebra.solveDense(a, c)) |sol| {
        var out: std.ArrayList(u8) = .empty;
        const all = [_][]algebra.Root{ sol.real, sol.complex };
        for (all) |group| for (group) |r| {
            if (out.items.len > 0) try out.appendSlice(a, "   or   ");
            try out.print(a, "{s} = {s}", .{ name, try algebra.rootText(a, r) });
        };
        try push(a, &steps, "The two solutions", out.items);
        if (sol.real.len == 2) {
            const v1 = try symbolic.toNumber(a, sol.real[0].re);
            const v2 = try symbolic.toNumber(a, sol.real[1].re);
            try push(a, &steps, "As decimals", try std.fmt.allocPrint(a, "{s} ≈ {s}   or   {s} ≈ {s}", .{ name, try num.format(a, v1, .{ .decimals = 6 }), name, try num.format(a, v2, .{ .decimals = 6 }) }));
        }
    }
    return steps.items;
}

/// A term of a polynomial with its sign: "6x²", " − 9x", " + 2". The first term has no plus.
fn termStr(a: std.mem.Allocator, v: i64, power: u8, name: []const u8, first: bool) Error![]const u8 {
    const mag: u64 = @abs(v);
    var body: std.ArrayList(u8) = .empty;
    if (power == 0) {
        try body.print(a, "{d}", .{mag});
    } else {
        if (mag != 1) try body.print(a, "{d}", .{mag});
        try body.appendSlice(a, name);
        if (power > 1) try body.appendSlice(a, sup_digits[power]);
    }
    if (first) return std.fmt.allocPrint(a, "{s}{s}", .{ if (v < 0) "−" else "", body.items });
    return std.fmt.allocPrint(a, " {s} {s}", .{ if (v < 0) "−" else "+", body.items });
}

/// Equations in one letter: linear and quadratic.
fn equation(ctx: Ctx, l: *const eval.Node, r: *const eval.Node) Error!?[]Step {
    const a = ctx.a;
    const actx: algebra.Ctx = .{ .a = a, .session = ctx.session };
    const pl = (try algebra.fromNode(actx, l)) orelse return null;
    const pr = (try algebra.fromNode(actx, r)) orelse return null;
    const diff = try algebra.sub(a, pl, pr);
    const name = algebra.onlyVar(diff) orelse algebra.onlyVar(pl) orelse algebra.onlyVar(pr) orelse return null;
    const cl = (try algebra.dense(a, pl, name)) orelse return null;
    const cr = (try algebra.dense(a, pr, name)) orelse return null;
    const cd = (try algebra.dense(a, diff, name)) orelse return null;
    const deg = algebra.degree(cd);
    allow_letters = true;
    defer allow_letters = false;
    const ln = (try fromNode(a, l)) orelse return null;
    const rn = (try fromNode(a, r)) orelse return null;
    const start = try eqText(a, try write(a, ln), try write(a, rn));
    if (deg <= 1) return try linearEquation(ctx, start, cl, cr, name);
    if (deg == 2) return try quadraticEquation(ctx, start, cd, name);
    return null;
}

// ---- expanding ----------------------------------------------------------------------------------------------------------------

fn polyOfN(ctx: Ctx, n: *const N) Error!?algebra.Poly {
    const a = ctx.a;
    switch (n.*) {
        .num => |v| return try algebra.constant(a, v),
        .raw => |r| {
            if (r.prec == 7 and r.text.len > 0 and std.ascii.isAlphabetic(r.text[0])) return try algebra.variable(a, r.text);
            return null;
        },
        .poly => |p| return p,
        .neg => |x| {
            const p = (try polyOfN(ctx, x)) orelse return null;
            return try algebra.scale(a, p, try num.fromInt(a, -1));
        },
        .bin => |b| {
            const l = (try polyOfN(ctx, b.l)) orelse return null;
            const r = (try polyOfN(ctx, b.r)) orelse return null;
            switch (b.op) {
                '+' => return try algebra.add(a, l, r),
                '-' => return try algebra.sub(a, l, r),
                '*' => return try algebra.mul(a, l, r),
                '^' => {
                    if (b.r.* != .num or !b.r.num.isInteger() or b.r.num.isNegative()) return null;
                    const k = num.intValue(b.r.num) orelse return null;
                    return try algebra.powInt(a, l, @intCast(k));
                },
                else => return null,
            }
        },
        else => return null,
    }
}

fn termCount(p: algebra.Poly) usize {
    return p.terms.len;
}

/// A node that is a product with a sum in it, or a power of a sum.
fn expandable(ctx: Ctx, n: *const N) Error!bool {
    if (n.* != .bin) return false;
    const b = n.bin;
    if (b.op == '*') {
        const l = (try polyOfN(ctx, b.l)) orelse return false;
        const r = (try polyOfN(ctx, b.r)) orelse return false;
        return termCount(l) > 1 or termCount(r) > 1;
    }
    if (b.op == '^' and b.r.* == .num and b.r.num.isInteger() and !b.r.num.isNegative()) {
        const k = num.intValue(b.r.num) orelse return false;
        const base = (try polyOfN(ctx, b.l)) orelse return false;
        return k >= 2 and termCount(base) > 1;
    }
    return false;
}

/// The innermost expandable node, leftmost first.
fn findExpandable(ctx: Ctx, n: *const N) Error!?*const N {
    switch (n.*) {
        .bin => |b| {
            if (try findExpandable(ctx, b.l)) |t| return t;
            if (try findExpandable(ctx, b.r)) |t| return t;
        },
        .neg => |x| if (try findExpandable(ctx, x)) |t| return t,
        else => {},
    }
    if (try expandable(ctx, n)) return n;
    return null;
}

fn singleTerm(a: std.mem.Allocator, vars: []const []const u8, t: algebra.PTerm) Error!algebra.Poly {
    const items = try a.alloc(algebra.PTerm, 1);
    items[0] = t;
    return .{ .vars = vars, .terms = items };
}

/// 2x or −3: one term of a polynomial as text.
fn oneTermText(a: std.mem.Allocator, vars: []const []const u8, t: algebra.PTerm) Error![]const u8 {
    return algebra.text(a, try singleTerm(a, vars, t));
}

/// Every term of the first times every term of the second, as written on paper.
fn distributionRows(ctx: Ctx, steps: *std.ArrayList(Step), x: algebra.Poly, y: algebra.Poly, context: ?struct { tree: *const N, target: *const N }) Error!algebra.Poly {
    const a = ctx.a;
    const xo = try algebra.orderedTerms(a, x);
    const yo = try algebra.orderedTerms(a, y);
    var dist: std.ArrayList(u8) = .empty;
    var unmerged: std.ArrayList(u8) = .empty;
    var first = true;
    for (xo.terms) |s| for (yo.terms) |t| {
        const sw = try oneTermText(a, xo.vars, s);
        const tw = try oneTermText(a, yo.vars, t);
        const sb = if (s.c.isNegative()) try std.fmt.allocPrint(a, "({s})", .{sw}) else sw;
        const tb = if (t.c.isNegative()) try std.fmt.allocPrint(a, "({s})", .{tw}) else tw;
        if (!first) try dist.appendSlice(a, " + ");
        try dist.print(a, "{s} × {s}", .{ sb, tb });
        // The product of the two single terms.
        const prod = try algebra.mul(a, try singleTerm(a, xo.vars, s), try singleTerm(a, yo.vars, t));
        const pt = try algebra.text(a, prod);
        if (first) {
            try unmerged.appendSlice(a, pt);
        } else if (std.mem.startsWith(u8, pt, "−")) {
            try unmerged.print(a, " − {s}", .{pt[3..]});
        } else try unmerged.print(a, " + {s}", .{pt});
        first = false;
    };
    const merged = try algebra.mul(a, x, y);
    const merged_text = try algebra.text(a, merged);
    const rows = [_]struct { note: []const u8, text: []const u8 }{
        .{ .note = "Multiply every term of the first bracket by every term of the second", .text = dist.items },
        .{ .note = "Work out each product", .text = unmerged.items },
    };
    for (rows) |r| {
        const shown = if (context) |c| blk: {
            const raw = try mk(a, .{ .raw = .{ .text = r.text, .prec = 1 } });
            break :blk try write(a, try replace(a, c.tree, c.target, raw));
        } else r.text;
        try push(a, steps, r.note, shown);
    }
    if (!std.mem.eql(u8, merged_text, unmerged.items)) {
        const shown = if (context) |c| try write(a, try replace(a, c.tree, c.target, try mk(a, .{ .poly = merged }))) else merged_text;
        try push(a, steps, "Combine like terms", shown);
    }
    return merged;
}

/// Expands one product or power inside the expression and returns the expression with the
/// result put in its place.
fn expandOne(ctx: Ctx, steps: *std.ArrayList(Step), tree: *N, target: *const N) Error!*N {
    const a = ctx.a;
    const b = target.bin;
    if (b.op == '*') {
        const l = (try polyOfN(ctx, b.l)).?;
        const r = (try polyOfN(ctx, b.r)).?;
        const result = try distributionRows(ctx, steps, l, r, .{ .tree = tree, .target = target });
        return replace(a, tree, target, try mk(a, .{ .poly = result }));
    }
    // A power: write it out as a product, then multiply from the left.
    const base = (try polyOfN(ctx, b.l)).?;
    const k: usize = @intCast(num.intValue(b.r.num).?);
    const base_text = try algebra.text(a, base);
    var product: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < k) : (i += 1) try product.print(a, "({s})", .{base_text});
    const raw = try mk(a, .{ .raw = .{ .text = product.items, .prec = 2 } });
    try push(a, steps, "Write the power as a product of brackets", try write(a, try replace(a, tree, target, raw)));
    var acc = base;
    i = 1;
    while (i < k) : (i += 1) {
        const last = i + 1 == k;
        acc = try distributionRows(ctx, steps, acc, base, null);
        _ = last;
    }
    const final = try mk(a, .{ .poly = acc });
    const replaced = try replace(a, tree, target, final);
    if (!std.mem.eql(u8, try write(a, replaced), steps.items[steps.items.len - 1].math)) try push(a, steps, "Put the result back", try write(a, replaced));
    return replaced;
}

fn hasLetters(n: *const N) bool {
    return switch (n.*) {
        .raw => |r| r.prec == 7 and r.text.len > 0 and std.ascii.isAlphabetic(r.text[0]),
        .bin => |b| hasLetters(b.l) or hasLetters(b.r),
        .neg => |x| hasLetters(x),
        .fact, .pct => |x| hasLetters(x),
        .call => |c| hasLetters(c.arg),
        else => false,
    };
}

/// Steps for an expression with letters: expand each product and power, then combine like terms.
fn expansion(ctx: Ctx, node: *const eval.Node) Error!?[]Step {
    const a = ctx.a;
    allow_letters = true;
    defer allow_letters = false;
    var tree = (try fromNode(a, node)) orelse return null;
    if (!hasLetters(tree)) return null;
    var steps: std.ArrayList(Step) = .empty;
    try push(a, &steps, "Start", try write(a, tree));
    var guard: usize = 0;
    while (guard < 12) : (guard += 1) {
        const target = (try findExpandable(ctx, tree)) orelse break;
        tree = try expandOne(ctx, &steps, tree, target);
    }
    // Whatever is left: combine like terms.
    const total = (try polyOfN(ctx, tree)) orelse return null;
    const final_text = try algebra.text(a, total);
    if (!std.mem.eql(u8, final_text, steps.items[steps.items.len - 1].math)) {
        try push(a, &steps, "Combine like terms", final_text);
    }
    if (steps.items.len <= 1) return null;
    return steps.items;
}

// ---- the entry point -------------------------------------------------------------------------------------------------------

/// The steps for an entry, or null when there are none (a number already, no steps worth showing, or a
/// kind of entry this does not cover).
pub fn explain(ctx: Ctx, text: []const u8) Error!?[]Step {
    const a = ctx.a;
    prefer_decimals = std.mem.indexOfScalar(u8, text, '.') != null;
    // expand(…) and simplify(…): the steps of what is inside.
    inline for (.{ "expand", "simplify" }) |word| {
        if (eval.unwrapCall(text, word)) |inner| return explain(ctx, inner);
    }
    var problem: eval.Problem = .{};
    const st = eval.parse(a, text, ctx.mode, &problem) catch return null;
    switch (st) {
        .expr => |n| {
            if (try expansion(ctx, n)) |letters| return letters;
            const steps = (try arithmetic(ctx, n)) orelse return null;
            if (steps.len <= 1) return null;
            return steps;
        },
        .equation => |eq| return try equation(ctx, eq.l, eq.r),
    }
}

// ---- tests ----------------------------------------------------------------------------------------------------------------

fn lines(want: []const []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    const steps = (try explain(.{ .a = a, .session = &session, .mode = .{} }, source)) orelse {
        std.debug.print("no steps for {s}\n", .{source});
        return error.TestUnexpectedResult;
    };
    var got: std.ArrayList([]const u8) = .empty;
    for (steps) |s| try got.append(a, s.math);
    if (got.items.len != want.len) {
        for (got.items) |g| std.debug.print("  {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "order of operations, one operation at a time" {
    try lines(&.{ "2 + 3 × (4 − 1)²", "2 + 3 × 3²", "2 + 3 × 3 × 3", "2 + 3 × 9", "2 + 27", "29" }, "2 + 3*(4-1)^2");
    try lines(&.{ "10 − 2 × 3", "10 − 6", "4" }, "10 - 2*3");
    try lines(&.{ "2 × 3 + 4 × 5", "6 + 4 × 5", "6 + 20", "26" }, "2*3 + 4*5");
}

test "fractions over a common denominator" {
    try lines(&.{ "1/2 + 1/3", "3/6 + 2/6", "5/6" }, "1/2 + 1/3");
    try lines(&.{ "(2/3 × 3)/4", "(6/3)/4", "2/4", "1/2" }, "2/3 * 3/4");
}

test "negative numbers and powers" {
    try lines(&.{ "3 − (−2)", "5" }, "3 - (-2)");
    try lines(&.{ "(−2)² + 1", "(−2) × (−2) + 1", "4 + 1", "5" }, "(-2)^2 + 1");
}

test "roots and functions" {
    try lines(&.{ "√16 + 2", "4 + 2", "6" }, "sqrt(16) + 2");
}

test "a linear equation" {
    try lines(&.{
        "2x + 3 = 11",
        "2x + 3 − 3 = 11 − 3",
        "2x = 8",
        "2x/2 = 8/2",
        "x = 4",
    }, "2x + 3 = 11");
    try lines(&.{
        "5x − 2 = 3x + 8",
        "5x − 2 − 3x = 3x + 8 − 3x",
        "2x − 2 = 8",
        "2x − 2 + 2 = 8 + 2",
        "2x = 10",
        "2x/2 = 10/2",
        "x = 5",
    }, "5x - 2 = 3x + 8");
    try lines(&.{
        "3(x + 1) = 2x + 7",
        "3x + 3 = 2x + 7",
        "3x + 3 − 2x = 2x + 7 − 2x",
        "x + 3 = 7",
        "x + 3 − 3 = 7 − 3",
        "x = 4",
    }, "3(x+1) = 2x + 7");
}

test "a quadratic equation, factored" {
    try lines(&.{
        "x² − 5x + 6 = 0",
        "(−3) × (−2) = 6,   (−3) + (−2) = −5",
        "(x − 2)(x − 3) = 0",
        "x − 2 = 0   or   x − 3 = 0",
        "x = 2   or   x = 3",
    }, "x^2 - 5x + 6 = 0");
}

test "expanding" {
    try lines(&.{
        "(x + 2)(x + 3)",
        "x × x + x × 3 + 2 × x + 2 × 3",
        "x² + 3x + 2x + 6",
        "x² + 5x + 6",
    }, "(x+2)(x+3)");
    try lines(&.{
        "(x + y)²",
        "(x + y)(x + y)",
        "x × x + x × y + y × x + y × y",
        "x² + xy + xy + y²",
        "x² + 2xy + y²",
    }, "(x+y)^2");
    try lines(&.{ "3x + 2x − 5 + 1", "5x − 4" }, "3x + 2x - 5 + 1");
}

test "zz print" {
    if (std.c.getenv("STEPS_PRINT") == null) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    const list = [_][]const u8{ "(x+2)(x+3)", "(x+1)^3", "(2x-1)(x+4)", "2(x+3) + 4", "(x+y)^2", "(x-1)(x+1)", "3x + 2x - 5 + 1", "(x+1)(x+2)(x+3)", "6x^2 - 7x - 3 = 0", "x^2 = 2", "x^2 = 72", "x^2 - x - 1 = 0", "x^2 + x + 1 = 0", "2x^2 - 2x - 12 = 0", "x^2 + 4x = 0", "x^2 = -9", "x^2 - 6x + 9 = 0", "(x+1)^2 = 4", "x/2 + 1/3 = 5/6", "2x + 3 = 2x + 5", "3x - 1 = 3x - 1" };
    for (list) |src| {
        std.debug.print("\n=== {s}\n", .{src});
        const steps = (try explain(.{ .a = a, .session = &session, .mode = .{} }, src)) orelse {
            std.debug.print("  (no steps)\n", .{});
            continue;
        };
        for (steps) |st| std.debug.print("  [{s}]\n      {s}\n", .{ st.note, st.math });
    }
}
