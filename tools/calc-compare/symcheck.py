"""Symbolic checks with sympy: dsolve, laplace, ilaplace, integral and derivative results.

A result is never compared against dkde-calc's own derivation. Instead it is tested the way a
mathematician would: a solution is substituted back into its equation, an antiderivative is
differentiated, and transforms are compared with sympy's own transform at sample points.
"""

import re

import sympy as sp
from sympy.parsing.sympy_parser import (convert_xor, implicit_application, implicit_multiplication,
                                        parse_expr, standard_transformations)


class Unmapped(Exception):
    pass


x, t, s = sp.symbols("x t s")
TRANS = standard_transformations + (convert_xor, implicit_multiplication, implicit_application)
LOCAL = {"x": x, "t": t, "s": s, "e": sp.E, "pi": sp.pi, "ln": sp.log, "exp": sp.exp, "C": sp.Symbol("C"),
         "C1": sp.Symbol("C1"), "C2": sp.Symbol("C2")}


SUP = {"⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁻": "-"}


def clean(text):
    r = re.sub("[⁰¹²³⁴⁵⁶⁷⁸⁹⁻]+", lambda m: "^(" + "".join(SUP[c] for c in m.group(0)) + ")", text)
    r = r.replace("−", "-").replace("·", "*").replace("×", "*").replace("π", "pi")
    r = re.sub(r"(?<![A-Za-z])e\^", "E**", r)
    r = r.replace("^", "**")
    return r


def parse(text, extra=None):
    local = dict(LOCAL)
    if extra:
        local.update(extra)
    try:
        return parse_expr(clean(text), local_dict=local, transformations=TRANS)
    except Exception as e:  # noqa: BLE001
        raise Unmapped("sympy could not read %r (%s)" % (text, e))


def split_args(inner):
    out, depth, cur = [], 0, ""
    for ch in inner:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [a.strip() for a in out]


def call_args(entry, name):
    m = re.fullmatch(name + r"\((.*)\)", entry.strip())
    if not m:
        raise Unmapped("form")
    return split_args(m.group(1))


def sample_equal(a, b, var, points, tol=1e-8):
    for p in points:
        try:
            va = complex(sp.N(a.subs(var, p), 30))
            vb = complex(sp.N(b.subs(var, p), 30))
        except (TypeError, ValueError):
            raise Unmapped("sympy could not evaluate %s or %s at %s=%s" % (a, b, var, p))
        if abs(va - vb) > tol * max(1.0, abs(va), abs(vb)):
            return False, "at %s=%s: result %s, sympy %s" % (var, p, va, vb)
    return True, ""


def check(name, entry, output):
    out = output.split("\n")[0]
    if name == "dsolve":
        return check_dsolve(entry, out)
    if name == "laplace":
        (arg,) = call_args(entry, name)
        ref = sp.laplace_transform(parse(arg), t, s, noconds=True)
        return sample_equal(parse(out), ref, s, [sp.Rational(37, 10), sp.Rational(53, 10), 9])
    if name == "ilaplace":
        (arg,) = call_args(entry, name)
        ref = sp.inverse_laplace_transform(parse(arg), s, t)
        ref = ref.subs(sp.Heaviside(t), 1)
        return sample_equal(parse(out), ref, t, [sp.Rational(7, 10), sp.Rational(19, 10), 3])
    if name == "integral":
        args = call_args(entry, name)
        if len(args) == 4:
            ref = sp.integrate(parse(args[0]), (x, sp.sympify(args[2]), sp.sympify(args[3])))
            return sample_equal(parse(out) + 0 * x, ref + 0 * x, x, [1])
        if len(args) != 2:
            raise Unmapped("multi-argument integral")
        f = parse(args[0])
        res = parse(re.sub(r"\s*\+\s*C$", "", out))
        return sample_equal(sp.diff(res, x), f, x, [sp.Rational(3, 10), sp.Rational(17, 10), 2])
    if name in ("expand", "factor"):
        (arg,) = call_args(entry, name)
        ref = sp.expand(parse(arg)) if name == "expand" else sp.factor(parse(arg))
        return sample_equal(parse(out), ref, x, [sp.Rational(3, 10), sp.Rational(17, 10), 4])
    if name == "diff":
        args = call_args(entry, name)
        if len(args) != 2:
            raise Unmapped("diff form")
        return sample_equal(parse(out), sp.diff(parse(args[0]), x), x, [sp.Rational(3, 10), sp.Rational(17, 10), 2])
    if name == "limit":
        args = call_args(entry, name)
        ref = sp.limit(parse(args[0]), x, sp.sympify(args[2]))
        return sample_equal(parse(out) + 0 * x, ref + 0 * x, x, [1])
    if name == "taylor":
        args = call_args(entry, name)
        order = int(args[3])
        poly = re.sub(r"\s*\+\s*O\(.*\)$", "", out)
        ref = sp.series(parse(args[0]), x, int(args[2]), order + 1).removeO()
        return sample_equal(parse(poly), ref, x, [sp.Rational(3, 10), sp.Rational(1, 2), 1])
    if name == "derivative":
        args = call_args(entry, name)
        if len(args) != 2:
            raise Unmapped("derivative form")
        f = parse(args[0])
        ref = sp.diff(f, x)
        return sample_equal(parse(out), ref, x, [sp.Rational(3, 10), sp.Rational(17, 10), 2])
    raise Unmapped(name)


def ode_from(text, yf):
    """'y''+4*y'+4*y=0' -> a sympy equation in yf(x)."""
    r = clean(text)
    r = r.replace("y''", "Derivative(Y,(x,2))").replace("y'", "Derivative(Y,x)")
    r = re.sub(r"\by\b(?!\()", "Y", r)
    lhs, rhs = r.split("=")
    loc = {"Y": yf, "Derivative": sp.Derivative, "x": x, "e": sp.E}
    return sp.Eq(parse_expr(lhs, local_dict=loc, transformations=TRANS), parse_expr(rhs, local_dict=loc, transformations=TRANS))


def check_dsolve(entry, out):
    args = call_args(entry, "dsolve")
    yf = sp.Function("y")(x)
    try:
        ode = ode_from(args[0], yf)
    except Exception as e:  # noqa: BLE001
        raise Unmapped("could not read the equation: %s" % e)
    m = re.fullmatch(r"y\s*=\s*(.*)", out)
    if not m:
        raise Unmapped("dkde did not print y = ...")
    sol = parse(m.group(1))
    ok, resid = sp.checkodesol(ode, sp.Eq(yf, sol))
    if not ok:
        return False, "does not satisfy the equation: residual %s" % resid
    for ic in args[1:]:
        mm = re.fullmatch(r"y('*)\(([-0-9.]+)\)\s*=\s*([-0-9./]+)", ic.replace(" ", ""))
        if not mm:
            raise Unmapped("initial condition %r" % ic)
        order, at, val = len(mm.group(1)), sp.Rational(mm.group(2)), sp.Rational(mm.group(3))
        got = sp.diff(sol, x, order).subs(x, at) if order else sol.subs(x, at)
        if abs(complex(sp.N(got)) - complex(sp.N(val))) > 1e-9:
            return False, "initial condition %s: solution gives %s" % (ic, sp.N(got))
    return True, ""


def check_equation(entry, output):
    """'x^2 - 5x + 6 = 0' prints '2; 3': compare with sympy's solutions; 'a = b' on numbers prints true/false."""
    lhs, rhs = entry.split("=")
    out = output.split("\n")[0].strip()
    L, R = parse(lhs), parse(rhs)
    if not (L.free_symbols or R.free_symbols):
        want = sp.simplify(L - R) == 0
        if out in ("true", "false"):
            return (out == "true") == want, "dkde %s, sympy %s" % (out, want)
        raise Unmapped("equation of numbers printed %s" % out)
    if "complex" in out:
        sols = [k for k in sp.solve(sp.Eq(L, R), x) if k.is_real is False]
        return len(sols) >= 1, "dkde says complex roots, sympy %s" % sols
    sols = sorted(float(k) for k in sp.solve(sp.Eq(L, R), x) if k.is_real)
    try:
        got = sorted(float(v.replace("-", "-").strip()) for v in out.replace("−", "-").split(";"))
    except ValueError:
        raise Unmapped("equation result %r" % out)
    ok = len(got) == len(sols) and all(abs(a - b) < 1e-9 for a, b in zip(got, sols))
    return ok, "dkde %s, sympy %s" % (got, sols)
