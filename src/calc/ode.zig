// SPDX-License-Identifier: GPL-2.0-or-later
//! Ordinary differential equations in one unknown function y(x):
//!
//!   first order     a·y′ + b·y = f(x), f a polynomial
//!   second order    a·y″ + b·y′ + c·y = r, r a constant
//!
//! Primes are written `y'` and `y''`; initial conditions follow as further arguments
//! (`y(0) = 1`, and `y'(0) = 0` for the second order). Answers are exact.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const algebra = @import("algebra.zig");
const symbolic = @import("symbolic.zig");
const Number = num.Number;

pub const Error = eval.Error;

/// "y'' + 3y' + 2y" → "ydd + 3yd + 2y", so that the entry parses (a prime is not part of a name).
fn unprime(a: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "y''")) {
            try out.appendSlice(a, "ydd");
            i += 3;
        } else if (std.mem.startsWith(u8, rest, "y′′")) {
            try out.appendSlice(a, "ydd");
            i += 7;
        } else if (std.mem.startsWith(u8, rest, "y'")) {
            try out.appendSlice(a, "yd");
            i += 2;
        } else if (std.mem.startsWith(u8, rest, "y′")) {
            try out.appendSlice(a, "yd");
            i += 4;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return out.items;
}

const Parts = struct { order: u8, c2: Number, c1: Number, c0: Number, rest: []Number };

fn parts(a: std.mem.Allocator, session: *eval.Session, equation: []const u8) Error!?Parts {
    const text = try unprime(a, equation);
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    var problem: eval.Problem = .{};
    const ln = try eval.parseExpr(a, text[0..eq], .{}, &problem);
    const rn = try eval.parseExpr(a, text[eq + 1 ..], .{}, &problem);
    const ctx: algebra.Ctx = .{ .a = a, .session = session };
    const pl = (try algebra.fromNode(ctx, ln)) orelse return null;
    const pr = (try algebra.fromNode(ctx, rn)) orelse return null;
    const diff = try algebra.sub(a, pl, pr);
    var c2 = try num.fromInt(a, 0);
    var c1 = try num.fromInt(a, 0);
    var c0 = try num.fromInt(a, 0);
    var rest: std.ArrayList(algebra.PTerm) = .empty;
    for (diff.terms) |t| {
        var dd: u16 = 0;
        var d1: u16 = 0;
        var y0: u16 = 0;
        var xe: u16 = 0;
        for (t.exps, 0..) |e, i| {
            if (e == 0) continue;
            const v = diff.vars[i];
            if (std.mem.eql(u8, v, "ydd")) dd = e else if (std.mem.eql(u8, v, "yd")) d1 = e else if (std.mem.eql(u8, v, "y")) y0 = e else if (std.mem.eql(u8, v, "x")) xe = e else return null;
        }
        const total = dd + d1 + y0;
        if (total == 0) {
            // The right side, moved over: −t.
            const e = try a.alloc(u16, 1);
            e[0] = xe;
            try rest.append(a, .{ .c = try num.neg(a, t.c), .exps = e });
            continue;
        }
        if (total != 1 or xe != 0) return null;
        if (dd == 1) c2 = try num.add(a, c2, t.c);
        if (d1 == 1) c1 = try num.add(a, c1, t.c);
        if (y0 == 1) c0 = try num.add(a, c0, t.c);
    }
    const order: u8 = if (!c2.isZero()) 2 else if (!c1.isZero()) 1 else return null;
    const xv = try a.alloc([]const u8, 1);
    xv[0] = "x";
    const dn = (try algebra.dense(a, .{ .vars = xv, .terms = rest.items }, "x")) orelse return null;
    return .{ .order = order, .c2 = c2, .c1 = c1, .c0 = c0, .rest = dn };
}

fn zero(a: std.mem.Allocator) Error!Number {
    return num.fromInt(a, 0);
}

/// A rational as text: whole numbers plain, others as a fraction, a minus sign as "−".
fn numText(a: std.mem.Allocator, v: Number) Error![]const u8 {
    const raw = if (v.isInteger()) try num.format(a, v, .{ .decimals = 0 }) else (try num.fraction(a, v)) orelse try num.format(a, v, .{ .decimals = 12 });
    if (raw.len > 0 and raw[0] == '-') return std.fmt.allocPrint(a, "−{s}", .{raw[1..]});
    return raw;
}

fn isOne(v: Number) bool {
    return num.isOneNumber(v);
}

/// "e^(2x)", "e^(−x/2)", "e^x", "1": e raised to k·x for text k.
fn expOf(a: std.mem.Allocator, k: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, k, "0")) return "1";
    if (std.mem.eql(u8, k, "1")) return "e^x";
    if (std.mem.eql(u8, k, "−1")) return "e^(−x)";
    if (std.mem.indexOfScalar(u8, k, '/')) |s| {
        // n/d → nx/d
        const neg = std.mem.startsWith(u8, k, "−");
        const n = if (neg) k[3..s] else k[0..s];
        return std.fmt.allocPrint(a, "e^({s}{s}x/{s})", .{ if (neg) "−" else "", if (std.mem.eql(u8, n, "1")) "" else n, k[s + 1 ..] });
    }
    if (std.mem.indexOfAny(u8, k, "+−√") != null and !std.mem.startsWith(u8, k, "−") or std.mem.indexOf(u8, k, " ") != null)
        return std.fmt.allocPrint(a, "e^(({s})x)", .{k});
    return std.fmt.allocPrint(a, "e^({s}x)", .{k});
}

fn expOfNumber(a: std.mem.Allocator, k: Number) Error![]const u8 {
    return expOf(a, try numText(a, k));
}

/// "+ 3" or "− 3/2" appended to a text, nothing for zero.
fn plusText(a: std.mem.Allocator, v: Number) Error![]const u8 {
    if (v.isZero()) return "";
    const t = try numText(a, v);
    if (std.mem.startsWith(u8, t, "−")) return std.fmt.allocPrint(a, " − {s}", .{t[3..]});
    return std.fmt.allocPrint(a, " + {s}", .{t});
}

/// A coefficient with its function: "2·e^x"; 1 is left out, 0 gives null.
fn termText(a: std.mem.Allocator, c: Number, f: []const u8) Error!?[]const u8 {
    if (c.isZero()) return null;
    if (std.mem.eql(u8, f, "1")) return try numText(a, c);
    if (isOne(c)) return f;
    const t = try numText(a, c);
    if (std.mem.eql(u8, t, "−1")) return try std.fmt.allocPrint(a, "−{s}", .{f});
    const wrapped = if (std.mem.indexOfScalar(u8, t, '/') != null) try std.fmt.allocPrint(a, "({s})", .{t}) else t;
    return try std.fmt.allocPrint(a, "{s}·{s}", .{ wrapped, f });
}

fn joinTerms(a: std.mem.Allocator, list: []const ?[]const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |maybe| {
        const t = maybe orelse continue;
        if (out.items.len == 0) {
            try out.appendSlice(a, t);
        } else if (std.mem.startsWith(u8, t, "−")) {
            try out.print(a, " − {s}", .{t[3..]});
        } else try out.print(a, " + {s}", .{t});
    }
    if (out.items.len == 0) return "0";
    return out.items;
}

/// y′ − k·y = f for a polynomial f: the polynomial solution p, (i+1)p[i+1] − k·p[i] = f[i].
fn particular(a: std.mem.Allocator, f: []const Number, k: Number) Error![]Number {
    const p = try a.alloc(Number, f.len);
    var next = try zero(a);
    var i = f.len;
    while (i > 0) {
        i -= 1;
        const lhs = try num.sub(a, try num.mul(a, try num.fromInt(a, @as(i64, @intCast(i + 1))), next), f[i]);
        p[i] = try num.div(a, lhs, k);
        next = p[i];
    }
    return p;
}

fn polyOf(a: std.mem.Allocator, c: []const Number) Error![]const u8 {
    const p = try algebra.fromDense(a, c, "x");
    return algebra.text(a, p);
}

fn firstOrder(a: std.mem.Allocator, p: Parts, ic: ?[2]Number) Error![]const u8 {
    // y′ = k·y + f(x)
    const k = try num.div(a, try num.neg(a, p.c0), p.c1);
    const f = try a.alloc(Number, p.rest.len);
    for (p.rest, 0..) |c, i| f[i] = try num.div(a, c, p.c1);
    var part: []Number = undefined;
    if (k.isZero()) {
        part = try a.alloc(Number, f.len + 1);
        part[0] = try zero(a);
        for (f, 0..) |c, i| part[i + 1] = try num.div(a, c, try num.fromInt(a, @as(i64, @intCast(i + 1))));
    } else {
        // y′ − k·y = f: part′ − k·part = f.
        part = try particular(a, f, k);
    }
    if (k.isZero()) {
        if (ic) |cond| {
            const c = try num.sub(a, cond[1], try algebra.evalAt(a, part, cond[0]));
            part[0] = try num.add(a, part[0], c);
            return std.fmt.allocPrint(a, "y = {s}", .{try polyOf(a, part)});
        }
        const t = try polyOf(a, part);
        return std.fmt.allocPrint(a, "y = {s}{s}", .{ if (std.mem.eql(u8, t, "0")) "" else t, if (std.mem.eql(u8, t, "0")) "C" else " + C" });
    }
    const ex = try expOfNumber(a, k);
    var head: []const u8 = undefined;
    if (ic) |cond| {
        // C = (y0 − part(x0))·e^(−k·x0)
        const rhs = try num.sub(a, cond[1], try algebra.evalAt(a, part, cond[0]));
        if (!cond[0].isZero()) return error.Domain;
        head = (try termText(a, rhs, ex)) orelse "0";
    } else {
        head = try std.fmt.allocPrint(a, "C·{s}", .{ex});
    }
    var pp: []const u8 = "";
    var any = false;
    for (part) |c| if (!c.isZero()) {
        any = true;
    };
    if (any) {
        const t = try polyOf(a, part);
        pp = if (std.mem.startsWith(u8, t, "−")) try std.fmt.allocPrint(a, " − {s}", .{t[3..]}) else try std.fmt.allocPrint(a, " + {s}", .{t});
    }
    return std.fmt.allocPrint(a, "y = {s}{s}", .{ head, pp });
}

fn secondOrder(a: std.mem.Allocator, p: Parts, ic: ?[2]Number, ic2: ?Number) Error![]const u8 {
    const coefs = try a.alloc(Number, 3);
    coefs[0] = p.c0;
    coefs[1] = p.c1;
    coefs[2] = p.c2;
    const sol = (try algebra.solveDense(a, coefs)) orelse return error.Domain;
    if (p.rest.len > 1) for (p.rest[1..]) |c| if (!c.isZero()) return error.Domain;
    var shift = try zero(a);
    if (!p.rest[0].isZero()) {
        if (p.c0.isZero()) return error.Domain;
        shift = try num.div(a, p.rest[0], p.c0);
    }
    const tail = try plusText(a, shift);
    const have_ic = ic != null;
    if (have_ic and (ic2 == null or !ic.?[0].isZero())) return error.Domain;
    const y0 = if (have_ic) try num.sub(a, ic.?[1], shift) else try zero(a);
    const y1 = ic2 orelse try zero(a);
    if (sol.real.len == 2) {
        const t1 = try algebra.rootText(a, sol.real[0]);
        const t2 = try algebra.rootText(a, sol.real[1]);
        const e1 = try expOf(a, t1);
        const e2 = try expOf(a, t2);
        if (!have_ic) return std.fmt.allocPrint(a, "y = C1·{s} + C2·{s}{s}", .{ e1, e2, tail });
        const r1 = try symbolic.toNumber(a, sol.real[0].re);
        const r2 = try symbolic.toNumber(a, sol.real[1].re);
        if (!r1.isExact() or !r2.isExact()) return error.Domain;
        const det = try num.sub(a, r2, r1);
        const c1 = try num.div(a, try num.sub(a, try num.mul(a, r2, y0), y1), det);
        const c2 = try num.div(a, try num.sub(a, y1, try num.mul(a, r1, y0)), det);
        const body = try joinTerms(a, &.{ try termText(a, c1, e1), try termText(a, c2, e2) });
        return std.fmt.allocPrint(a, "y = {s}{s}", .{ body, tail });
    }
    if (sol.real.len == 1 and sol.complex.len == 0) {
        const t1 = try algebra.rootText(a, sol.real[0]);
        const e1 = try expOf(a, t1);
        if (!have_ic) return std.fmt.allocPrint(a, "y = (C1 + C2·x)·{s}{s}", .{ e1, tail });
        const r = try symbolic.toNumber(a, sol.real[0].re);
        if (!r.isExact()) return error.Domain;
        const c2 = try num.sub(a, y1, try num.mul(a, r, y0));
        const lin = try joinTerms(a, &.{ try termText(a, y0, "1"), try termText(a, c2, "x") });
        if (std.mem.eql(u8, e1, "1")) return std.fmt.allocPrint(a, "y = {s}{s}", .{ lin, tail });
        return std.fmt.allocPrint(a, "y = ({s})·{s}{s}", .{ lin, e1, tail });
    }
    if (sol.complex.len == 2) {
        const alpha_s = try symbolic.format(a, sol.complex[0].re);
        var beta_sym = sol.complex[0].im;
        const bn = try symbolic.toNumber(a, beta_sym);
        if (bn.isNegative()) beta_sym = sol.complex[1].im;
        const beta_s = try symbolic.format(a, beta_sym);
        const bx = if (std.mem.eql(u8, beta_s, "1")) "x" else try std.fmt.allocPrint(a, "{s}x", .{beta_s});
        const ex = try expOf(a, alpha_s);
        if (!have_ic) {
            const trig = try std.fmt.allocPrint(a, "(C1·cos({s}) + C2·sin({s}))", .{ bx, bx });
            if (std.mem.eql(u8, ex, "1")) return std.fmt.allocPrint(a, "y = {s}{s}", .{ trig, tail });
            return std.fmt.allocPrint(a, "y = {s}·{s}{s}", .{ ex, trig, tail });
        }
        const al = try symbolic.toNumber(a, sol.complex[0].re);
        const be = try symbolic.toNumber(a, beta_sym);
        if (!al.isExact() or !be.isExact()) return error.Domain;
        const c2 = try num.div(a, try num.sub(a, y1, try num.mul(a, al, y0)), be);
        const c1t = if (y0.isZero()) null else try termText(a, y0, try std.fmt.allocPrint(a, "cos({s})", .{bx}));
        const c2t = try termText(a, c2, try std.fmt.allocPrint(a, "sin({s})", .{bx}));
        const body = try joinTerms(a, &.{ c1t, c2t });
        const wrapped = if (c1t != null and c2t != null) try std.fmt.allocPrint(a, "({s})", .{body}) else body;
        if (std.mem.eql(u8, ex, "1")) return std.fmt.allocPrint(a, "y = {s}{s}", .{ body, tail });
        return std.fmt.allocPrint(a, "y = {s}·{s}{s}", .{ ex, wrapped, tail });
    }
    return error.Domain;
}

const Cond = struct { derivative: bool, at: Number, value: Number };

/// "y(0) = 1" or "y'(0) = 2".
fn condition(a: std.mem.Allocator, session: *eval.Session, text: []const u8) Error!?Cond {
    const t = std.mem.trim(u8, text, " ");
    const derivative = std.mem.startsWith(u8, t, "y'") or std.mem.startsWith(u8, t, "y′");
    const open = std.mem.indexOfScalar(u8, t, '(') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, t, open, ')') orelse return null;
    const eq = std.mem.indexOfScalarPos(u8, t, close, '=') orelse return null;
    var problem: eval.Problem = .{};
    var ev: eval.Eval = .{ .a = a, .session = session, .mode = .{}, .problem = &problem };
    const at = try ev.eval(try eval.parseExpr(a, t[open + 1 .. close], .{}, &problem), null);
    const value = try ev.eval(try eval.parseExpr(a, t[eq + 1 ..], .{}, &problem), null);
    if (!at.isExact() or !value.isExact()) return null;
    return .{ .derivative = derivative, .at = at, .value = value };
}

/// dsolve(equation, conditions…): the solution as text, or null when the equation is not of these kinds.
pub fn solve(a: std.mem.Allocator, session: *eval.Session, inner: []const u8) Error!?[]const u8 {
    const args = try eval.splitTop(a, inner, ',');
    if (args.len == 0) return null;
    const p = (try parts(a, session, args[0])) orelse return null;
    var first: ?[2]Number = null;
    var second: ?Number = null;
    for (args[1..]) |c| {
        const cond = (try condition(a, session, c)) orelse return error.Syntax;
        if (cond.derivative) second = cond.value else first = .{ cond.at, cond.value };
    }
    if (p.order == 1) return try firstOrder(a, p, first);
    return try secondOrder(a, p, first, second);
}

pub const Line = struct { note: []const u8, math: []const u8 };

fn push(a: std.mem.Allocator, list: *std.ArrayList(Line), note: []const u8, math: []const u8) Error!void {
    try list.append(a, .{ .note = note, .math = math });
}

/// The steps to dsolve(…): the method for the order, then the conditions.
pub fn steps(a: std.mem.Allocator, session: *eval.Session, inner: []const u8) Error!?[]Line {
    const args = try eval.splitTop(a, inner, ',');
    if (args.len == 0) return null;
    const p = (try parts(a, session, args[0])) orelse return null;
    var first: ?[2]Number = null;
    var second: ?Number = null;
    for (args[1..]) |c| {
        const cond = (try condition(a, session, c)) orelse return null;
        if (cond.derivative) second = cond.value else first = .{ cond.at, cond.value };
    }
    var out: std.ArrayList(Line) = .empty;
    try push(a, &out, "Given", std.mem.trim(u8, args[0], " "));
    var conds: []const u8 = "";
    if (first) |f1| {
        conds = try std.fmt.allocPrint(a, "y({s}) = {s}", .{ try numText(a, f1[0]), try numText(a, f1[1]) });
        if (second) |s2| conds = try std.fmt.allocPrint(a, "{s},   y′({s}) = {s}", .{ conds, try numText(a, f1[0]), try numText(a, s2) });
    }
    if (p.order == 1) {
        const k = try num.div(a, try num.neg(a, p.c0), p.c1);
        const f = try a.alloc(Number, p.rest.len);
        for (p.rest, 0..) |c, i| f[i] = try num.div(a, c, p.c1);
        const ftext = try polyOf(a, f);
        const f_zero = std.mem.eql(u8, ftext, "0");
        const ky: ?[]const u8 = blk: {
            if (k.isZero()) break :blk null;
            const kt = try numText(a, k);
            if (std.mem.eql(u8, kt, "1")) break :blk "y";
            if (std.mem.eql(u8, kt, "−1")) break :blk "−y";
            if (std.mem.indexOfScalar(u8, kt, '/') != null) break :blk try std.fmt.allocPrint(a, "({s})y", .{kt});
            break :blk try std.fmt.allocPrint(a, "{s}y", .{kt});
        };
        const solved = try joinTerms(a, &.{ ky, if (f_zero) null else ftext });
        try push(a, &out, "Solve for y′", try std.fmt.allocPrint(a, "y′ = {s}", .{solved}));
        if (k.isZero()) {
            try push(a, &out, "Integrate both sides", try std.fmt.allocPrint(a, "y = ∫ ({s}) dx", .{ftext}));
        } else {
            const ex = try expOfNumber(a, k);
            try push(a, &out, "Without the x-part, y′ = ky has the solutions", try std.fmt.allocPrint(a, "y = C·{s}", .{ex}));
            if (!f_zero) try push(a, &out, "Add a polynomial of the same degree as the x-part; matching coefficients gives a particular solution", try std.fmt.allocPrint(a, "y = C·{s} + (particular)", .{ex}));
        }
        try push(a, &out, "General solution", try firstOrder(a, p, null));
        if (first != null) {
            try push(a, &out, "Put in the condition to find C", conds);
            try push(a, &out, "Solution", try firstOrder(a, p, first));
        }
        return out.items;
    }
    const coefs = try a.alloc(Number, 3);
    coefs[0] = p.c0;
    coefs[1] = p.c1;
    coefs[2] = p.c2;
    const chars = try algebra.fromDense(a, coefs, "r");
    try push(a, &out, "Try y = e^(rx): it gives the characteristic equation", try std.fmt.allocPrint(a, "{s} = 0", .{try algebra.text(a, chars)}));
    const sol = (try algebra.solveDense(a, coefs)) orelse return null;
    var roots: std.ArrayList(u8) = .empty;
    for (sol.real) |r| {
        if (roots.items.len > 0) try roots.appendSlice(a, ",   ");
        try roots.print(a, "r = {s}", .{try algebra.rootText(a, r)});
    }
    for (sol.complex) |r| {
        if (roots.items.len > 0) try roots.appendSlice(a, ",   ");
        try roots.print(a, "r = {s}", .{try algebra.rootText(a, r)});
    }
    try push(a, &out, "Solve for r", roots.items);
    const form: []const u8 = if (sol.complex.len == 2) "Complex roots α ± βi give e^(αx)(C1·cos βx + C2·sin βx)" else if (sol.real.len == 1) "A double root r gives (C1 + C2·x)·e^(rx)" else "Two roots r1, r2 give C1·e^(r1·x) + C2·e^(r2·x)";
    try push(a, &out, form, try secondOrder(a, p, null, null));
    if (first != null) {
        try push(a, &out, "Put in the conditions to find C1 and C2", conds);
        try push(a, &out, "Solution", try secondOrder(a, p, first, second));
    }
    return out.items;
}

// ---- tests ---------------------------------------------------------------------------------------

fn gives(want: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    const got = (try solve(a, &session, source)) orelse return error.TestUnexpectedResult;
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {s}\n", .{source});
        return e;
    };
}

test "first order" {
    try gives("y = C·e^(2x)", "y' = 2y");
    try gives("y = C·e^(−x)", "y' + y = 0");
    try gives("y = x² + C", "y' = 2x");
    try gives("y = C·e^(2x) − 3/2", "y' = 2y + 3");
    try gives("y = 5·e^(3x)", "y' = 3y, y(0) = 5");
    try gives("y = C·e^x − x − 1", "y' = y + x");
}

test "second order" {
    try gives("y = C1·e^(−2x) + C2·e^(−x)", "y'' + 3y' + 2y = 0");
    try gives("y = (C1 + C2·x)·e^(−x)", "y'' + 2y' + y = 0");
    try gives("y = (C1·cos(x) + C2·sin(x))", "y'' + y = 0");
    try gives("y = e^(−2x)", "y'' + 3y' + 2y = 0, y(0) = 1, y'(0) = -2");
    try gives("y = −e^(−2x) + 2·e^(−x)", "y'' + 3y' + 2y = 0, y(0) = 1, y'(0) = 0");
    try gives("y = cos(2x)", "y'' + 4y = 0, y(0) = 1, y'(0) = 0");
}
