#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Checks every formula in the Formulas pane (src/calc/formulas.zig) against sympy.

For each formula and each of its letters, the other letters get sample values; dkde-calc solves for the
one left out (as the pane does) and sympy solves the same equation independently. Run from the
repository root with the built binary at zig-out/bin/dkde-calc:

    python3 -I tools/calc-compare/verify_formulas.py [NAME-SUBSTRING]

Formulas sympy cannot solve (bitwise operators, modular powers for an exponent) are listed as unchecked.
"""

import random
import re
import sys
import multiprocessing
import signal
from concurrent.futures import ProcessPoolExecutor, TimeoutError as FutTimeout
from pathlib import Path

import sympy as sp
from sympy.parsing.sympy_parser import convert_xor, implicit_application, implicit_multiplication, parse_expr, standard_transformations

sys.path.insert(0, str(Path(__file__).resolve().parent))
import refeval  # noqa: E402

SRC = Path("src/calc/formulas.zig")
TRANS = standard_transformations + (convert_xor, implicit_multiplication, implicit_application)
FORMULA = re.compile(r'\.\{ \.group = "([^"]*)", \.name = "([^"]*)", \.text = "([^"]*)", \.vars = &\.\{ (.*) \} \},\s*$')
VAR = re.compile(r'(v|c)\("([^"]*)", "([^"]*)"(?:, "([^"]*)")?\)')


def load():
    out = []
    for line in SRC.read_text().splitlines():
        m = FORMULA.search(line.strip())
        if not m:
            continue
        group, name, text, vars_ = m.groups()
        vs = []
        for kind, n, what, default in VAR.findall(vars_):
            vs.append((n, what, default or ""))
        if "g_earth" in vars_:
            vs.append(("g", "gravity", "9.80665"))
        out.append({"group": group, "name": name, "text": text.replace("\\\\", "\\"), "vars": vs})
    return out


def sample(rng, what, default):
    if default:
        return sp.nsimplify(default)
    w = what.lower()
    if rng.random() < 0.35:
        return sp.Rational(rng.choice([2, 3, 5, 7, 8]), 10)
    if "0 to 1" in w or "probability" in w or "chance" in w or "fraction" in w or "loss rate" in w:
        return sp.Rational(rng.choice([1, 2, 3, 7]), 10)
    if "(%)" in w or "percent" in w:
        return sp.Rational(rng.choice([15, 25, 40, 60]), 1)
    if "angle" in w or "(°)" in w or "degrees" in w:
        return sp.Rational(rng.choice([20, 30, 45, 60]), 1)
    return sp.Rational(rng.choice([15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 100, 120]), rng.choice([1, 10]))


def safe(text, names):
    """The formula as a sympy equation with every letter renamed to V0, V1, ..."""
    t = text.replace("−", "-").replace("·", "*").replace("×", "*").replace("÷", "/").replace("∕", "/")
    t = re.sub("[⁰¹²³⁴⁵⁶⁷⁸⁹]+", lambda m: "^" + "".join(str("⁰¹²³⁴⁵⁶⁷⁸⁹".index(c)) for c in m.group(0)), t)
    t = re.sub(r"√\(", "sqrt(", t)
    t = re.sub(r"√(\w+)", r"sqrt(\1)", t)
    order = sorted(names, key=len, reverse=True)
    mapping = {}
    for i, n in enumerate(order):
        key = "Zq%d" % i
        mapping[n] = key
        t = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(n) + r"(?![A-Za-z0-9_])", key, t)
    t = t.replace("π", "pi")
    return t, mapping


def sym_env(mapping):
    env = {k: sp.Symbol(k, real=True) for k in mapping.values()}
    deg = sp.pi / 180
    env.update({
        "e": sp.E, "pi": sp.pi, "ln": sp.log, "exp": sp.exp, "sqrt": sp.sqrt, "abs": sp.Abs,
        "log10": lambda x: sp.log(x, 10), "log2": lambda x: sp.log(x, 2), "log": lambda x: sp.log(x, 10),
        "sin": lambda x: sp.sin(x * deg), "cos": lambda x: sp.cos(x * deg), "tan": lambda x: sp.tan(x * deg),
        "acos": lambda x: sp.acos(x) / deg, "asin": lambda x: sp.asin(x) / deg, "atan": lambda x: sp.atan(x) / deg,
        "nCr": sp.binomial, "mod": sp.Mod, "sinh": sp.sinh, "cosh": sp.cosh, "tanh": sp.tanh,
        "phi": (1 + sp.sqrt(5)) / 2, "tau": 2 * sp.pi,
    })
    return env


def sub_text(text, mapping_vals):
    """The formula text with each letter replaced by its value, ready for dkde-calc."""
    t = text
    for n in sorted(mapping_vals, key=len, reverse=True):
        v = mapping_vals[n]
        if v is None:
            continue
        t = re.sub(r"(?<![A-Za-z0-9_])" + re.escape(n) + r"(?![A-Za-z0-9_])", "(%s)" % v, t)
    return t


class _Timeout(Exception):
    pass


def _alarm(*_):
    raise _Timeout()


def check_one(args):
    signal.signal(signal.SIGALRM, _alarm)
    f, target, seed = args
    names = [n for n, _, _ in f["vars"]]
    if "xor" in f["text"]:
        return (f, target, "unchecked", "bitwise xor has no sympy equation form")
    t, mapping = safe(f["text"], names)
    env = sym_env(mapping)
    try:
        lhs, rhs = t.split("=")
        eq = sp.Eq(parse_expr(lhs, local_dict=env, transformations=TRANS),
                   parse_expr(rhs, local_dict=env, transformations=TRANS))
    except Exception as e:  # noqa: BLE001
        return (f, target, "unchecked", "sympy could not read %s (%s)" % (f["text"], e))
    last = "no sample values gave a real answer"
    for attempt in range(12):
        rng = random.Random(seed * 1000 + attempt)
        vals = {n: sample(rng, what, default) for n, what, default in f["vars"]}
        if "!" in f["text"] or "nCr(" in f["text"]:  # counting formulas take whole numbers
            vals = {n: (sp.nsimplify(default) if default else sp.Integer(rng.choice([3, 4, 5, 6, 7, 8]))) for n, _, default in f["vars"]}
        sub = {env[mapping[n]]: v for n, v in vals.items() if n != target}
        try:
            tsym = env[mapping[target]]
            if eq.lhs == tsym and tsym not in eq.rhs.free_symbols:
                sols = [eq.rhs.subs(sub)]
            else:
                signal.alarm(20)
                try:
                    sols = sp.solve(eq.subs(sub), tsym, dict=False)
                finally:
                    signal.alarm(0)
        except _Timeout:
            return (f, target, "unchecked", "sympy took too long to solve this one")
        except Exception as e:  # noqa: BLE001
            last = "sympy could not solve: %s" % str(e)[:60]
            continue
        real = []
        for s_ in sols:
            try:
                c = complex(sp.N(s_, 30))
            except (TypeError, ValueError):
                continue
            if abs(c.imag) < 1e-12 and abs(c.real) < 1e12:
                real.append(c.real)
        real = [r for r in real if 1e-5 <= abs(r) <= 1e9]
        if not real:
            last = "sympy found no real solution of a reasonable size for the sample values"
            continue
        entry = sub_text(f["text"], {n: (None if n == target else v) for n, v in vals.items()})
        raw = refeval.dkde_eval([entry], extra=("--solve",))[0]
        out = raw.split("\n")[0]
        if out == "" and "STDERR" in raw:
            return (f, target, "NO-ANSWER", "entry %s\n      dkde: %s; sympy has %s" % (entry, raw.split("STDERR")[-1].strip().split(": ")[-1], [round(r, 8) for r in real]))
        if out.startswith("TIMEOUT"):
            return (f, target, "HANG", "entry %s\n      %s" % (entry, out))
        got = refeval.parse_values(out)
        if got is None:
            return (f, target, "unchecked", "dkde printed %r for %s" % (out, entry))
        tsym = env[mapping[target]]
        resid = [abs(complex(sp.N(eq.lhs.subs(sub).subs(tsym, sp.Float(str(g), 30)) - eq.rhs.subs(sub).subs(tsym, sp.Float(str(g), 30)), 30))) for g in got]
        ok = len(got) >= 1 and all(rv < 1e-6 * max(1.0, abs(complex(sp.N(eq.rhs.subs(sub).subs(tsym, sp.Float(str(g), 30)), 30)))) for rv, g in zip(resid, got))
        if ok:
            return (f, target, "ok", "")
        return (f, target, "MISMATCH", "entry %s\n      dkde %s   sympy %s" % (entry, out, [round(r, 10) for r in real]))
    return (f, target, "unchecked", last)


def main(argv):
    flt = argv[0].lower() if argv else ""
    formulas = [f for f in load() if flt in f["name"].lower()]
    jobs = [(f, n, i) for i, f in enumerate(formulas) for n, _, _ in f["vars"]]
    results = []
    with ProcessPoolExecutor(8, mp_context=multiprocessing.get_context("fork")) as ex:
        futs = [ex.submit(check_one, j) for j in jobs]
        for i, (j, fu) in enumerate(zip(jobs, futs)):
            try:
                results.append(fu.result(timeout=240))
            except FutTimeout:
                results.append((j[0], j[1], "unchecked", "timed out"))
            if i % 200 == 0:
                print("  ...%d of %d" % (i, len(jobs)), file=sys.stderr, flush=True)
    counts = {}
    for _, _, st, _ in results:
        counts[st] = counts.get(st, 0) + 1
    print("formulas: %d   cases (formula x letter): %d   %s" % (len(formulas), len(jobs), "   ".join("%s: %d" % kv for kv in sorted(counts.items()))))
    for f, target, st, why in results:
        if st in ("MISMATCH", "HANG", "NO-ANSWER"):
            print("\nMISMATCH  %s: %s  solving for %s\n      %s" % (f["name"], f["text"], target, why))
    print("\nunchecked:")
    by = {}
    for f, target, st, why in results:
        if st == "unchecked":
            by.setdefault(f["name"], []).append((target, why))
    for name, items in sorted(by.items()):
        print("  %s  [%s]: %s" % (name, ", ".join(t for t, _ in items), items[0][1][:90]))
    return 1 if counts.get("MISMATCH") or counts.get("HANG") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
