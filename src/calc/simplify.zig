//! Tidying an expression that still has unknowns in it, so a formula with
//! some of its values filled in is shown as simply as it goes:
//! "E = 4·v²/2" becomes "E = 2v²", "2x + 3x" becomes "5x".
//!
//! An expression is read as a sum of terms; each term is a number times
//! factors raised to powers. Known numbers are worked out exactly, like
//! terms are added, and powers of the same factor are combined. π, e, τ and
//! φ stay as they are. Brackets are not multiplied out (except a number
//! times a sum) and nothing is factored: this is tidying, not algebra.

const std = @import("std");
const num = @import("num.zig");
const eval = @import("eval.zig");
const Node = eval.Node;
const Number = num.Number;

const Factor = struct { base: *Node, exp: Number };
const Term = struct { coef: Number, factors: []Factor };

pub const Ctx = struct {
    a: std.mem.Allocator,
    ev: *eval.Eval,

    /// A name without a value (or one of the constants kept as letters).
    fn isSymbol(self: *Ctx, name: []const u8) bool {
        if (std.mem.eql(u8, name, "ans")) return false;
        if (eval.isConstant(name)) return true;
        return !self.ev.session.vars.contains(name);
    }

    fn hasSymbol(self: *Ctx, n: *const Node) bool {
        return switch (n.*) {
            .number => false,
            .name => |nm| self.isSymbol(nm.text),
            .unary => |u| self.hasSymbol(u.arg),
            .binary => |b| self.hasSymbol(b.l) or self.hasSymbol(b.r),
            .call => |c| for (c.args) |x| {
                if (self.hasSymbol(x)) break true;
            } else false,
        };
    }

    fn one(self: *Ctx) !Number {
        return num.fromInt(self.a, 1);
    }

    fn numberNode(self: *Ctx, v: Number) !*Node {
        const n = try self.a.create(Node);
        n.* = .{ .number = v };
        return n;
    }

    /// The expression as a sum of terms.
    fn toSum(self: *Ctx, n: *const Node) eval.Error![]Term {
        const a = self.a;
        if (!self.hasSymbol(n)) {
            // Known: work it out (exactly where possible).
            if (self.ev.eval(n, null)) |v| {
                const terms = try a.alloc(Term, 1);
                terms[0] = .{ .coef = v, .factors = &.{} };
                return terms;
            } else |_| {}
        }
        switch (n.*) {
            .name => |nm| {
                if (!self.isSymbol(nm.text)) return self.single(try self.ev.eval(n, null));
                return self.atom(@constCast(n));
            },
            .unary => |u| switch (u.op) {
                .neg => return self.scale(try self.toSum(u.arg), try num.fromInt(a, -1)),
                .pct => return self.scale(try self.toSum(u.arg), try num.div(a, try self.one(), try num.fromInt(a, 100))),
                else => return self.atom(try self.rebuildUnary(u.op, u.arg)),
            },
            .binary => |b| switch (b.op) {
                .add, .sub => {
                    const l = try self.toSum(b.l);
                    var r = try self.toSum(b.r);
                    if (b.op == .sub) r = try self.scale(r, try num.fromInt(a, -1));
                    return self.combine(try std.mem.concat(a, Term, &.{ l, r }));
                },
                .mul => {
                    const l = try self.toSum(b.l);
                    const r = try self.toSum(b.r);
                    if (l.len == 1 and r.len == 1) return self.combine(&.{try self.mulTerms(l[0], r[0])});
                    // A number times a sum: into each term.
                    if (l.len == 1 and l[0].factors.len == 0) return self.scale(r, l[0].coef);
                    if (r.len == 1 and r[0].factors.len == 0) return self.scale(l, r[0].coef);
                    // Otherwise a sum is one factor: (x + 1)²·(x + 1) is (x + 1)³.
                    return self.combine(&.{try self.mulTerms(try self.asTerm(l), try self.asTerm(r))});
                },
                .div => {
                    const l = try self.toSum(b.l);
                    const r = try self.toSum(b.r);
                    if (r.len == 1 and !r[0].coef.isZero()) {
                        const inv = try self.invert(r[0]);
                        var out = try a.alloc(Term, l.len);
                        for (l, 0..) |term, i| out[i] = try self.mulTerms(term, inv);
                        return self.combine(out);
                    }
                    return self.atom(try self.binaryNode(.div, try self.toNode(l), try self.toNode(r)));
                },
                .pow => {
                    const base = try self.toSum(b.l);
                    if (!self.hasSymbol(b.r)) {
                        const e_or = self.ev.eval(b.r, null) catch null;
                        if (e_or) |e| if (e.isExact()) {
                            if (base.len == 1) return self.combine(&.{try self.powTerm(base[0], e)});
                            const f = try a.alloc(Factor, 1);
                            f[0] = .{ .base = try self.toNode(base), .exp = e };
                            const terms = try a.alloc(Term, 1);
                            terms[0] = .{ .coef = try self.one(), .factors = f };
                            return terms;
                        };
                    }
                    return self.atom(try self.binaryNode(.pow, try self.toNode(base), try self.toNode(try self.toSum(b.r))));
                },
                else => return self.atom(try self.binaryNode(b.op, try self.toNode(try self.toSum(b.l)), try self.toNode(try self.toSum(b.r)))),
            },
            .call => |c| {
                var args = try a.alloc(*Node, c.args.len);
                for (c.args, 0..) |x, i| args[i] = try self.toNode(try self.toSum(x));
                const call = try a.create(Node);
                call.* = .{ .call = .{ .name = c.name, .args = args, .pos = c.pos } };
                return self.atom(call);
            },
            .number => |v| return self.single(v),
        }
    }

    /// A sum of several terms as one factor.
    fn asTerm(self: *Ctx, terms: []const Term) !Term {
        if (terms.len == 1) return terms[0];
        const f = try self.a.alloc(Factor, 1);
        f[0] = .{ .base = try self.toNode(terms), .exp = try self.one() };
        return .{ .coef = try self.one(), .factors = f };
    }

    fn single(self: *Ctx, v: Number) ![]Term {
        const terms = try self.a.alloc(Term, 1);
        terms[0] = .{ .coef = v, .factors = &.{} };
        return terms;
    }

    fn atom(self: *Ctx, n: *Node) ![]Term {
        const f = try self.a.alloc(Factor, 1);
        f[0] = .{ .base = n, .exp = try self.one() };
        const terms = try self.a.alloc(Term, 1);
        terms[0] = .{ .coef = try self.one(), .factors = f };
        return terms;
    }

    fn rebuildUnary(self: *Ctx, o: eval.UOp, arg: *const Node) !*Node {
        const n = try self.a.create(Node);
        n.* = .{ .unary = .{ .op = o, .arg = try self.toNode(try self.toSum(arg)) } };
        return n;
    }

    fn binaryNode(self: *Ctx, o: eval.Op, l: *Node, r: *Node) !*Node {
        const n = try self.a.create(Node);
        n.* = .{ .binary = .{ .op = o, .l = l, .r = r } };
        return n;
    }

    fn scale(self: *Ctx, terms: []const Term, k: Number) ![]Term {
        var out = try self.a.alloc(Term, terms.len);
        for (terms, 0..) |term, i| out[i] = .{ .coef = try num.mul(self.a, term.coef, k), .factors = term.factors };
        return self.combine(out);
    }

    fn mulTerms(self: *Ctx, x: Term, y: Term) !Term {
        const f = try std.mem.concat(self.a, Factor, &.{ x.factors, y.factors });
        return .{ .coef = try num.mul(self.a, x.coef, y.coef), .factors = try self.mergeFactors(f) };
    }

    fn invert(self: *Ctx, x: Term) !Term {
        var f = try self.a.alloc(Factor, x.factors.len);
        for (x.factors, 0..) |fac, i| f[i] = .{ .base = fac.base, .exp = try num.neg(self.a, fac.exp) };
        return .{ .coef = try num.div(self.a, try self.one(), x.coef), .factors = f };
    }

    fn powTerm(self: *Ctx, x: Term, e: Number) !Term {
        var f = try self.a.alloc(Factor, x.factors.len);
        for (x.factors, 0..) |fac, i| f[i] = .{ .base = fac.base, .exp = try num.mul(self.a, fac.exp, e) };
        const coef = num.pow(self.a, x.coef, e) catch x.coef;
        return .{ .coef = coef, .factors = try self.mergeFactors(f) };
    }

    /// x·x² is x³; x/x is gone.
    fn mergeFactors(self: *Ctx, f: []const Factor) ![]Factor {
        var out: std.ArrayList(Factor) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        for (f) |fac| {
            const key = try self.print(fac.base);
            const found = for (keys.items, 0..) |kk, i| {
                if (std.mem.eql(u8, kk, key)) break i;
            } else null;
            if (found) |i| {
                out.items[i].exp = try num.add(self.a, out.items[i].exp, fac.exp);
            } else {
                try out.append(self.a, fac);
                try keys.append(self.a, key);
            }
        }
        var kept: std.ArrayList(Factor) = .empty;
        for (out.items) |fac| if (!fac.exp.isZero()) try kept.append(self.a, fac);
        // A stable order, so like terms meet: letters by name.
        const Cmp = struct {
            ctx: *Ctx,
            fn less(c: @This(), x: Factor, y: Factor) bool {
                const kx = c.ctx.print(x.base) catch "";
                const ky = c.ctx.print(y.base) catch "";
                // As people write them: π, e, τ and φ first, then letters,
                // then functions and brackets (πr², x²·cos(x)).
                const rx = rank(x.base, kx);
                const ry = rank(y.base, ky);
                if (rx != ry) return rx < ry;
                return std.mem.order(u8, kx, ky) == .lt;
            }

            fn rank(n: *const Node, key: []const u8) u8 {
                if (eval.isConstant(key)) return 0;
                return if (n.* == .name) 1 else 2;
            }
        };
        std.mem.sort(Factor, kept.items, Cmp{ .ctx = self }, Cmp.less);
        return kept.toOwnedSlice(self.a);
    }

    /// 2x + 3x is 5x; terms that cancel go.
    fn combine(self: *Ctx, terms: []const Term) ![]Term {
        var out: std.ArrayList(Term) = .empty;
        var keys: std.ArrayList([]const u8) = .empty;
        for (terms) |term| {
            const key = try self.termKey(term);
            const found = for (keys.items, 0..) |kk, i| {
                if (std.mem.eql(u8, kk, key)) break i;
            } else null;
            if (found) |i| {
                out.items[i].coef = try num.add(self.a, out.items[i].coef, term.coef);
            } else {
                try out.append(self.a, term);
                try keys.append(self.a, key);
            }
        }
        var kept: std.ArrayList(Term) = .empty;
        for (out.items) |term| if (!term.coef.isZero()) try kept.append(self.a, term);
        // Terms with letters first, the number last.
        var sorted: std.ArrayList(Term) = .empty;
        for (kept.items) |term| if (term.factors.len > 0) try sorted.append(self.a, term);
        for (kept.items) |term| if (term.factors.len == 0) try sorted.append(self.a, term);
        if (sorted.items.len == 0) return self.single(try num.fromInt(self.a, 0));
        return sorted.toOwnedSlice(self.a);
    }

    fn termKey(self: *Ctx, term: Term) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (term.factors) |f| {
            try out.appendSlice(self.a, try self.print(f.base));
            try out.append(self.a, '^');
            try out.appendSlice(self.a, try num.format(self.a, f.exp, .{}));
            try out.append(self.a, ';');
        }
        return out.items;
    }

    /// A sum back as a tree (for nesting inside calls and powers).
    fn toNode(self: *Ctx, terms: []const Term) !*Node {
        // Printed and parsed back: simple, and keeps one printer.
        const text = try self.printSum(terms);
        var p: eval.Problem = .{};
        return eval.parseExpr(self.a, text, self.ev.mode, &p) catch self.literal(text);
    }

    fn literal(self: *Ctx, text: []const u8) !*Node {
        const n = try self.a.create(Node);
        n.* = .{ .name = .{ .text = try std.fmt.allocPrint(self.a, "({s})", .{text}), .pos = 0 } };
        return n;
    }

    // ---- writing it out ----------------------------------------------------------------

    fn printSum(self: *Ctx, terms: []const Term) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (terms, 0..) |term, i| {
            const negative = term.coef.isNegative();
            if (i == 0) {
                if (negative) try out.appendSlice(self.a, "−");
            } else try out.appendSlice(self.a, if (negative) " − " else " + ");
            const coef = if (negative) try num.neg(self.a, term.coef) else term.coef;
            try out.appendSlice(self.a, try self.printTerm(coef, term.factors));
        }
        return out.items;
    }

    fn printTerm(self: *Ctx, coef: Number, factors: []const Factor) ![]u8 {
        const a = self.a;
        if (factors.len == 0) return num.format(a, coef, .{});
        var top: std.ArrayList(u8) = .empty;
        var bottom: std.ArrayList(u8) = .empty;
        var bottom_items: usize = 0;
        // The number's numerator in front, its denominator below.
        var den_text: ?[]u8 = null;
        // Fractions with short denominators (x/2, 2x/3); long ones as decimals.
        if (coef.isExact() and !coef.isInteger() and coef.exact.den.bitCountAbs() <= 10) {
            const n = try num.format(a, .{ .exact = .{ .num = coef.exact.num, .den = try std.math.big.int.Managed.initSet(a, 1) } }, .{});
            const d = try num.format(a, .{ .exact = .{ .num = coef.exact.den, .den = try std.math.big.int.Managed.initSet(a, 1) } }, .{});
            if (!std.mem.eql(u8, n, "1")) try top.appendSlice(a, n);
            den_text = d;
        } else if (!(coef.isExact() and coef.isInteger() and std.mem.eql(u8, try num.format(a, coef, .{}), "1"))) {
            try top.appendSlice(a, try num.format(a, coef, .{}));
        }
        if (den_text) |d| {
            try bottom.appendSlice(a, d);
            bottom_items += 1;
        }
        for (factors) |f| {
            const below = f.exp.isNegative();
            const e = if (below) try num.neg(a, f.exp) else f.exp;
            const text = try self.printFactor(f.base, e);
            const list = if (below) &bottom else &top;
            if (below) bottom_items += 1;
            if (list.items.len > 0) {
                // 2x, 9π: a number then a letter needs no dot; letters do.
                const last = list.items[list.items.len - 1];
                const implicit = std.ascii.isDigit(last) and (std.ascii.isAlphabetic(text[0]) or text[0] == '(' or text[0] >= 0x80);
                if (!implicit) try list.appendSlice(a, "·");
            }
            try list.appendSlice(a, text);
        }
        if (top.items.len == 0) try top.appendSlice(a, "1");
        if (bottom.items.len == 0) return top.items;
        const b = if (bottom_items > 1) try std.fmt.allocPrint(a, "({s})", .{bottom.items}) else bottom.items;
        return std.fmt.allocPrint(a, "{s}/{s}", .{ top.items, b });
    }

    fn printFactor(self: *Ctx, base: *const Node, e: Number) ![]u8 {
        const a = self.a;
        var b = try self.print(base);
        const simple = base.* == .name or base.* == .call or base.* == .number;
        if (!simple) b = try std.fmt.allocPrint(a, "({s})", .{b});
        if (e.isExact() and e.isInteger()) {
            const ei = num.intValue(e) orelse 0;
            if (ei == 1) return b;
            if (ei == 2) return std.fmt.allocPrint(a, "{s}²", .{b});
            if (ei == 3) return std.fmt.allocPrint(a, "{s}³", .{b});
            return std.fmt.allocPrint(a, "{s}^{d}", .{ b, ei });
        }
        // A half power is a square root.
        if (e.isExact() and std.mem.eql(u8, try num.format(a, e, .{}), "0.5")) return std.fmt.allocPrint(a, "√{s}", .{if (simple) b else b});
        return std.fmt.allocPrint(a, "{s}^({s})", .{ b, try num.format(a, e, .{}) });
    }

    /// Any tree as text, with only the brackets it needs.
    pub fn print(self: *Ctx, n: *const Node) eval.Error![]u8 {
        return self.printPrec(n, 0);
    }

    fn prec(n: *const Node) u8 {
        return switch (n.*) {
            .binary => |b| switch (b.op) {
                .add, .sub, .add_pct, .sub_pct => 1,
                .mul, .div, .mod => 2,
                .pow => 4,
                else => 0,
            },
            .unary => |u| if (u.op == .neg or u.op == .bnot) 3 else 5,
            else => 6,
        };
    }

    fn printPrec(self: *Ctx, n: *const Node, outer: u8) eval.Error![]u8 {
        const a = self.a;
        const p = prec(n);
        const text: []u8 = switch (n.*) {
            .number => |v| try num.format(a, v, .{}),
            .name => |nm| try a.dupe(u8, nm.text),
            .call => |c| blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(a, c.name);
                try out.append(a, '(');
                for (c.args, 0..) |x, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try out.appendSlice(a, try self.printPrec(x, 0));
                }
                try out.append(a, ')');
                break :blk out.items;
            },
            .unary => |u| switch (u.op) {
                .neg => try std.fmt.allocPrint(a, "−{s}", .{try self.printPrec(u.arg, 3)}),
                .bnot => try std.fmt.allocPrint(a, "not {s}", .{try self.printPrec(u.arg, 3)}),
                .fact => try std.fmt.allocPrint(a, "{s}!", .{try self.printPrec(u.arg, 6)}),
                .pct => try std.fmt.allocPrint(a, "{s}%", .{try self.printPrec(u.arg, 6)}),
            },
            .binary => |b| blk: {
                if (b.op == .pow) {
                    const base = try self.printPrec(b.l, 5);
                    if (b.r.* == .number) {
                        const e = try num.format(a, b.r.number, .{});
                        if (std.mem.eql(u8, e, "2")) break :blk try std.fmt.allocPrint(a, "{s}²", .{base});
                        if (std.mem.eql(u8, e, "3")) break :blk try std.fmt.allocPrint(a, "{s}³", .{base});
                    }
                    break :blk try std.fmt.allocPrint(a, "{s}^{s}", .{ base, try self.printPrec(b.r, 4) });
                }
                const sym: []const u8 = switch (b.op) {
                    .add => " + ",
                    .sub => " − ",
                    .mul => "·",
                    .div => "/",
                    .mod => " mod ",
                    .add_pct => " + ",
                    .sub_pct => " − ",
                    .band => " and ",
                    .bor => " or ",
                    .bxor => " xor ",
                    .shl => " << ",
                    .shr => " >> ",
                    .pow => unreachable,
                };
                const l = try self.printPrec(b.l, p);
                // The right side of − and / binds tighter.
                const r = try self.printPrec(b.r, if (b.op == .sub or b.op == .div) p + 1 else p);
                const pct = if (b.op == .add_pct or b.op == .sub_pct) "%" else "";
                if (b.op == .mul and l.len > 0 and std.ascii.isDigit(l[l.len - 1]) and r.len > 0 and (std.ascii.isAlphabetic(r[0]) or r[0] == '(' or r[0] >= 0x80))
                    break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ l, r });
                break :blk try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ l, sym, r, pct });
            },
        };
        if (p < outer) return std.fmt.allocPrint(a, "({s})", .{text});
        return text;
    }
};

/// The coefficients of `n` (constant first) when it is a polynomial in `x`
/// with numbers for coefficients (π and e count as numbers), else null.
pub fn polynomial(a: std.mem.Allocator, ev: *eval.Eval, n: *const Node, x: []const u8) eval.Error!?[]f64 {
    var ctx: Ctx = .{ .a = a, .ev = ev };
    const terms = try ctx.toSum(n);
    var coefs: std.ArrayList(f64) = .empty;
    for (terms) |term| {
        var c = term.coef.toFloat();
        var power: usize = 0;
        for (term.factors) |f| {
            if (f.base.* != .name) return null;
            const name = f.base.name.text;
            if (eval.isConstant(name)) {
                // π, e, τ, φ are numbers here.
                const v = ev.eval(f.base, null) catch return null;
                c *= std.math.pow(f64, v.toFloat(), f.exp.toFloat());
                continue;
            }
            if (!std.mem.eql(u8, name, x)) return null;
            if (!f.exp.isExact() or !f.exp.isInteger() or f.exp.isNegative()) return null;
            const e = num.intValue(f.exp) orelse return null;
            if (e > 64) return null;
            power += @intCast(e);
        }
        while (coefs.items.len <= power) try coefs.append(a, 0);
        coefs.items[power] += c;
    }
    // The highest power must be there.
    while (coefs.items.len > 1 and coefs.items[coefs.items.len - 1] == 0) _ = coefs.pop();
    if (coefs.items.len < 2) return null;
    return coefs.items;
}

/// Every root, real and complex, of the polynomial with these coefficients
/// (constant first), by the Durand–Kerner method.
pub fn complexRoots(a: std.mem.Allocator, coefs: []const f64) ![]std.math.Complex(f64) {
    const C = std.math.Complex(f64);
    const n = coefs.len - 1;
    const lead = coefs[n];
    var z = try a.alloc(C, n);
    // Starting points spread on a circle (not on the real line).
    const start = C.init(0.4, 0.9);
    var p = C.init(1, 0);
    for (z) |*zi| {
        zi.* = p;
        p = p.mul(start);
    }
    var iter: usize = 0;
    while (iter < 500) : (iter += 1) {
        var moved: f64 = 0;
        for (z, 0..) |zi, i| {
            // The polynomial at zi, divided by the leading coefficient.
            var v = C.init(0, 0);
            var k = n + 1;
            while (k > 0) {
                k -= 1;
                v = v.mul(zi).add(C.init(coefs[k] / lead, 0));
            }
            var d = C.init(1, 0);
            for (z, 0..) |zj, j| if (j != i) {
                d = d.mul(zi.sub(zj));
            };
            if (d.magnitude() == 0) continue;
            const step = v.div(d);
            z[i] = zi.sub(step);
            moved = @max(moved, step.magnitude());
        }
        if (moved < 1e-14) break;
    }
    return z;
}

/// The expression tidied, as text.
pub fn simplify(a: std.mem.Allocator, ev: *eval.Eval, n: *const Node) eval.Error![]u8 {
    var ctx: Ctx = .{ .a = a, .ev = ev };
    return ctx.printSum(try ctx.toSum(n));
}

/// An equation tidied: "E = 2v²".
pub fn equation(a: std.mem.Allocator, ev: *eval.Eval, l: *const Node, r: *const Node) eval.Error![]u8 {
    return std.fmt.allocPrint(a, "{s} = {s}", .{ try simplify(a, ev, l), try simplify(a, ev, r) });
}

/// Any tree as text (for showing a formula with values put in).
pub fn print(a: std.mem.Allocator, ev: *eval.Eval, n: *const Node) eval.Error![]u8 {
    var ctx: Ctx = .{ .a = a, .ev = ev };
    return ctx.print(n);
}

test "tidying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    var ev: eval.Eval = .{ .a = a, .session = &session, .mode = .{}, .problem = &p };
    const cases = .{
        .{ "2x + 3x", "5x" },
        .{ "4·v²/2", "2v²" },
        .{ "x/2 + x/2", "x" },
        .{ "x - x", "0" },
        .{ "x^2·x", "x³" },
        .{ "a·b + 2·a·b", "3a·b" },
        .{ "π·3²", "9π" },
        .{ "π·r²", "π·r²" },
        .{ "2(x + 1)", "2x + 2" },
        .{ "x/(2y)", "x/(2y)" },
        .{ "3/x", "3/x" },
        .{ "sin(x) + sin(x)", "2sin(x)" },
        .{ "(x + 1)²·(x + 1)", "(x + 1)³" },
        .{ "m·v²/2", "m·v²/2" },
        .{ "-x + 5", "−x + 5" },
        .{ "x·x^-1", "1" },
    };
    inline for (cases) |c| {
        const n = try eval.parseExpr(a, c[0], .{}, &p);
        const got = try simplify(a, &ev, n);
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("for {s}\n", .{c[0]});
            return e;
        };
    }
    try session.setVar("g", try num.fromInt(a, 10));
    const n = try eval.parseExpr(a, "m·g·h", .{}, &p);
    try std.testing.expectEqualStrings("10h·m", try simplify(a, &ev, n));
}

test "polynomials and their complex roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session: eval.Session = .{ .gpa = std.testing.allocator };
    defer session.deinit();
    var p: eval.Problem = .{};
    var ev: eval.Eval = .{ .a = a, .session = &session, .mode = .{}, .problem = &p };
    // 9² = a² + 6²×8, as a − b = 0: 81 − a² − 288.
    const n = try eval.parseExpr(a, "9² − (a² + 6²×8)", .{}, &p);
    const c = (try polynomial(a, &ev, n, "a")).?;
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectApproxEqAbs(@as(f64, -207), c[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1), c[2], 1e-9);
    const roots = try complexRoots(a, c);
    for (roots) |r| {
        try std.testing.expectApproxEqAbs(@as(f64, 0), r.re, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, @sqrt(207.0)), @abs(r.im), 1e-9);
    }
    try std.testing.expect((try polynomial(a, &ev, try eval.parseExpr(a, "sin(x) + 1", .{}, &p), "x")) == null);
}
