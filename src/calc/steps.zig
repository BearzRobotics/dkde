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
};

fn mk(a: std.mem.Allocator, n: N) Error!*N {
    const p = try a.create(N);
    p.* = n;
    return p;
}

fn fromNode(a: std.mem.Allocator, n: *const eval.Node) Error!?*N {
    switch (n.*) {
        .number => |v| {
            if (!v.isExact()) return null;
            return try mk(a, .{ .num = v });
        },
        .name => return null,
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

const Done = struct {
    /// The number the operation comes to (null when it has no number: an irrational root).
    value: ?Number,
    /// What it was, for the note: "Add 2 + 3 = 5".
    note: []const u8,
    /// Lines before the result, each the operation in another form (common denominators).
    between: []const []const u8 = &.{},
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
            var between: std.ArrayList([]const u8) = .empty;
            if (isFraction(x) or isFraction(y)) {
                const d = try lcmBig(a, x.exact.den, y.exact.den);
                if (!x.exact.den.eql(y.exact.den)) {
                    try between.append(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ try overDenominator(a, x, d), if (plus) "+" else "−", try overDenominator(a, y, d) }));
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
                if (!std.mem.eql(u8, combined, result_text)) try between.append(a, combined);
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} {s} and {s}: common denominator {s}", .{ verb, xt, yt, try bigText(a, d) }), .between = between.items };
            }
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ verb, xt, if (plus) "and" else "from", yt }) };
        },
        '*' => {
            const v = try num.mul(a, x, y);
            var between: std.ArrayList([]const u8) = .empty;
            if (isFraction(x) or isFraction(y)) {
                const xn = try intNumber(a, x.exact.num);
                const yn = try intNumber(a, y.exact.num);
                const dn = try num.mul(a, try intNumber(a, x.exact.den), try intNumber(a, y.exact.den));
                const raw = try std.fmt.allocPrint(a, "{s}/{s}", .{ try numText(a, try num.mul(a, xn, yn)), try numText(a, dn) });
                if (!std.mem.eql(u8, raw, try numText(a, v))) try between.append(a, raw);
            }
            return .{ .value = v, .note = try std.fmt.allocPrint(a, "Multiply {s} × {s}", .{ xt, yt }), .between = between.items };
        },
        '/' => {
            if (y.isZero()) return error.DivisionByZero;
            const v = try num.div(a, x, y);
            var between: std.ArrayList([]const u8) = .empty;
            if (isFraction(x) or isFraction(y)) {
                // Dividing by a fraction: multiply by its reciprocal.
                const recip = try num.div(a, try num.fromInt(a, 1), y);
                try between.append(a, try std.fmt.allocPrint(a, "{s} × {s}", .{ try wrapFraction(a, x), try wrapFraction(a, recip) }));
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "Divide {s} ÷ {s}: multiply by the reciprocal", .{ xt, yt }), .between = between.items };
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
                var between: std.ArrayList([]const u8) = .empty;
                try between.append(a, repeated.items);
                return .{ .value = v, .note = try std.fmt.allocPrint(a, "{s}: {s} to the power {s}", .{ word, xt, yt }), .between = between.items };
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
            const raw = try mk(a, .{ .raw = .{ .text = line, .prec = precOf(pick.node) } });
            try steps.append(a, .{ .note = "", .math = try write(a, try replace(a, tree, pick.node, raw)) });
        }
        const result = try mk(a, .{ .num = value });
        tree = try replace(a, tree, pick.node, result);
        try steps.append(a, .{ .note = note, .math = try write(a, tree) });
    }
    return steps.items;
}

// ---- the entry point -------------------------------------------------------------------------------------------------------

/// The steps for an entry, or null when there are none (a number already, no steps worth showing, or a
/// kind of entry this does not cover).
pub fn explain(ctx: Ctx, text: []const u8) Error!?[]Step {
    const a = ctx.a;
    prefer_decimals = std.mem.indexOfScalar(u8, text, '.') != null;
    var problem: eval.Problem = .{};
    const st = eval.parse(a, text, ctx.mode, &problem) catch return null;
    switch (st) {
        .expr => |n| {
            const steps = (try arithmetic(ctx, n)) orelse return null;
            if (steps.len <= 1) return null;
            return steps;
        },
        .equation => return null,
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
