"""Independent reference evaluator for dkde-calc entries.

Uses mpmath, scipy and sympy (never dkde-calc's own code) so that a disagreement means one of the two
is wrong. Conventions follow dkde-calc's defaults: angles in degrees, `log` is base 10, `ln` natural,
`^` is a power, `and`/`or`/`xor` are bitwise on integers, `mod` is the remainder.
"""

import math
import re
import statistics
import struct
import subprocess

import mpmath as mp
import numpy as np
import sympy as sp
from scipy import stats

mp.mp.dps = 40

DKDE = "zig-out/bin/dkde-calc"


class Unmapped(Exception):
    """The entry uses something this reference does not model; it is listed, never silently passed."""


# ---------------------------------------------------------------- the dkde-calc side

def dkde_eval(entries, decimals=15, extra=()):
    """Runs entries (one session) and returns the printed result lines. Entries are independent here,
    so each runs in its own call and a failure in one cannot shift the others."""
    out = []
    for e in entries:
        try:
            p = subprocess.run([DKDE, "eval", "--decimals", str(decimals), *extra, e], capture_output=True, text=True, timeout=20)
        except subprocess.TimeoutExpired:
            out.append("TIMEOUT: dkde-calc did not answer within 20 seconds")
            continue
        out.append((p.stdout.strip() + (("\nSTDERR " + p.stderr.strip()) if p.stderr.strip() else "")))
    return out


_NUM = r"[-+]?\d+(?:\.\d+)?(?:[eE×x]\^?[-+]?\d+)?"


def parse_number(text):
    """The numeric value printed by dkde-calc: after the last '~' if it shows an exact form too."""
    t = text.replace("−", "-").replace("×10^", "e").replace("·10^", "e").strip()
    if "~" in t:
        t = t.split("~")[-1].strip()
    t = t.replace(" ", "")
    if re.fullmatch(r"[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?", t):
        return mp.mpf(t)
    m = re.fullmatch(r"([-+]?\d+)/(\d+)", t)
    if m:
        return mp.mpf(int(m.group(1))) / int(m.group(2))
    return None


# ---------------------------------------------------------------- the reference side

def _d(x):
    return mp.radians(x)


def _flat(a):
    out = []
    if isinstance(a, np.ndarray):
        a = a.tolist()
    for v in a:
        if isinstance(v, np.ndarray):
            v = v.tolist()
        if isinstance(v, (list, tuple)):
            out += _flat(v)
        elif isinstance(v, sp.MatrixBase):
            out += _flat(v.tolist())
        else:
            out.append(v)
    return out


def _data(args):
    return [float(v) for v in _flat(args)]


def _nper(r, pmt, pv, fv=0, t=0):
    return mp.log((pmt * (1 + r * t) - fv * r) / (pmt * (1 + r * t) + pv * r)) / mp.log(1 + r)


def _pmt(r, n, pv, fv=0, t=0):
    if r == 0:
        return -(pv + fv) / n
    return -(r * (pv * (1 + r) ** n + fv)) / ((1 + r * t) * ((1 + r) ** n - 1))


def _fv(r, n, pmt, pv=0, t=0):
    return -(pv * (1 + r) ** n + pmt * (1 + r * t) * ((1 + r) ** n - 1) / r)


def _pv(r, n, pmt, fv=0, t=0):
    return -(fv + pmt * (1 + r * t) * ((1 + r) ** n - 1) / r) / (1 + r) ** n


def _rate(n, pmt, pv, fv=0, t=0, guess=0.01):
    f = lambda r: pv * (1 + r) ** n + pmt * (1 + r * t) * ((1 + r) ** n - 1) / r + fv
    return mp.findroot(f, guess)


def _linreg(x, y):
    r = stats.linregress([float(v) for v in x], [float(v) for v in y])
    return [r.slope, r.intercept, r.rvalue ** 2]


def _quartile(data, q, *_):
    return np.percentile(_data([data]), 25 * float(q))


def _percentile(data, p, *_):
    return np.percentile(_data([data]), float(p))


def _round(x, n=0):
    x = mp.mpf(x)
    f = mp.mpf(10) ** int(n)
    y = mp.floor(abs(x) * f + mp.mpf("0.5")) / f
    return y if x >= 0 else -y


def _mat(rows):
    return sp.Matrix([[sp.sympify(v) for v in r] for r in rows])


def _logic(op):
    def f(*a):
        if any(int(v) not in (0, 1) for v in a):
            raise Unmapped("multi-bit logic gate: the word width is dkde-calc's own convention")
        r = a[0]
        for v in a[1:]:
            r = {"and": r & v, "or": r | v, "xor": r ^ v}[op]
        return r
    return f


def _gate(base, invert):
    g = _logic(base)
    return lambda *a: int(g(*[int(v) for v in a])) ^ 1 if invert else int(g(*[int(v) for v in a]))


def _shift(x, n):
    x, n = int(x), int(n)
    return x << n if n >= 0 else x >> -n


def _eigs(m):
    return sorted(float(v.real) for v in np.linalg.eigvals(np.array(m.tolist(), dtype=float)))


def _add(a, b):
    ma, mb = isinstance(a, sp.MatrixBase), isinstance(b, sp.MatrixBase)
    if ma and not mb:
        return a + sp.ones(*a.shape) * sp.sympify(b)
    if mb and not ma:
        return b + sp.ones(*b.shape) * sp.sympify(a)
    return a + b


NAMESPACE = {
    "pi": mp.pi, "π": mp.pi, "e": mp.e, "tau": 2 * mp.pi, "phi": (1 + mp.sqrt(5)) / 2, "φ": (1 + mp.sqrt(5)) / 2,
    "sqrt": mp.sqrt, "cbrt": mp.cbrt, "exp": mp.exp, "ln": mp.log, "log": mp.log10, "log10": mp.log10,
    "log2": lambda x: mp.log(x, 2), "abs": abs, "floor": mp.floor, "ceil": mp.ceil, "trunc": lambda x: mp.floor(x) if x >= 0 else -mp.floor(-x), "bnot": lambda x: ~int(x),
    "sin": lambda x: mp.sin(_d(x)), "cos": lambda x: mp.cos(_d(x)), "tan": lambda x: mp.tan(_d(x)),
    "asin": lambda x: mp.degrees(mp.asin(x)), "acos": lambda x: mp.degrees(mp.acos(x)),
    "atan": lambda x: mp.degrees(mp.atan(x)),
    "sinh": mp.sinh, "cosh": mp.cosh, "tanh": mp.tanh, "erf": mp.erf,
    "factorial": mp.factorial, "fact": mp.factorial,
    "nCr": lambda n, k: mp.binomial(n, k), "nPr": lambda n, k: mp.factorial(n) / mp.factorial(n - k),
    "mod": lambda a, n: a - n * mp.floor(mp.mpf(a) / n), "gcd": lambda *a: math.gcd(*[int(v) for v in a]), "lcm": lambda a, b: abs(int(a) * int(b)) // math.gcd(int(a), int(b)),
    "min": min, "max": max,
    "mean": lambda *a: mp.mpf(statistics.fmean(_data(a))),
    "median": lambda *a: mp.mpf(statistics.median(_data(a))),
    "var": lambda *a: mp.mpf(statistics.variance(_data(a))),
    "varp": lambda *a: mp.mpf(statistics.pvariance(_data(a))),
    "stdev": lambda *a: mp.mpf(statistics.stdev(_data(a))),
    "stdevp": lambda *a: mp.mpf(statistics.pstdev(_data(a))),
    "covar": lambda x, y: mp.mpf(float(np.cov(_data([x]), _data([y]), ddof=0)[0][1])),
    "pearson": lambda x, y: mp.mpf(float(np.corrcoef(_data([x]), _data([y]))[0][1])),
    "quartile": _quartile, "percentile": _percentile, "linreg": _linreg,
    "normdist": lambda x, mu, s, cum=1: (stats.norm.cdf if cum else stats.norm.pdf)(float(x), float(mu), float(s)),
    "normdistinv": lambda p, mu, s: stats.norm.ppf(float(p), float(mu), float(s)),
    "binomdist": lambda k, n, p, cum=0: (stats.binom.cdf if cum else stats.binom.pmf)(int(k), int(n), float(p)),
    "poisson": lambda k, lam, cum=0: (stats.poisson.cdf if cum else stats.poisson.pmf)(int(k), float(lam)),
    "tdist": lambda x, df, cum=1: (stats.t.cdf if cum else stats.t.pdf)(float(x), float(df)),
    "tdistinv": lambda p, df: stats.t.ppf(float(p), float(df)),
    "norm": lambda v: mp.sqrt(sum(mp.mpf(x) ** 2 for x in _flat(v))),
    "nand": _gate("and", True), "nor": _gate("or", True), "xnor": _gate("xor", True),
    "popcount": lambda n: bin(int(n)).count("1"), "bitlen": lambda n: int(n).bit_length(),
    "modinv": lambda a, m: pow(int(a), -1, int(m)),
    "tobcd": lambda n: int(str(int(n)), 16), "frombcd": lambda n: int(format(int(n), "x")),
    "f32bits": lambda x: struct.unpack("<I", struct.pack("<f", float(x)))[0],
    "f32": lambda b: mp.mpf(struct.unpack("<f", struct.pack("<I", int(b)))[0]),
    "f64bits": lambda x: struct.unpack("<Q", struct.pack("<d", float(x)))[0],
    "f64": lambda b: mp.mpf(struct.unpack("<d", struct.pack("<Q", int(b)))[0]),
    "round": _round, "erfc": mp.erfc, "fibonacci": lambda n: mp.fib(n),
    "shift": _shift, "powmod": lambda a, b, m: pow(int(a), int(b), int(m)),
    "dot": lambda a, b: sum(mp.mpf(x) * mp.mpf(y) for x, y in zip(_flat(a), _flat(b))),
    "add": _add, "Vec": lambda items: np.array(items, dtype=object), "Matrix": _mat, "det": lambda m: m.det(), "inv": lambda m: m.inv(), "trace": lambda m: m.trace(),
    "eigenvalues": _eigs, "cross": lambda a, b: list(sp.Matrix(a).cross(sp.Matrix(b))),
    "isprime": lambda n: sp.isprime(int(n)),
    "pmt": _pmt, "fv": _fv, "pv": _pv, "nper": _nper, "rate": _rate,
}

# names a lesson line may use that this reference cannot model
UNMAPPED_WORDS = ("integral", "derivative", "diff", "dsolve", "laplace", "ilaplace", "solve", " to ", "parity", "bin(", "hex(", "oct(",
                  "expand", "factor(", "limit", "taylor")


def to_python(entry):
    s = entry.strip()
    low = " " + s.lower() + " "
    for w in UNMAPPED_WORDS:
        if w in low:
            raise Unmapped(w.strip())
    if re.search(r"(?<![<>!=])=(?!=)", s.replace("<=", "").replace(">=", "").replace("==", "")):
        raise Unmapped("equation")
    s = re.sub("[⁰¹²³⁴⁵⁶⁷⁸⁹⁻]+", lambda m: "^(" + "".join("0123456789-"["⁰¹²³⁴⁵⁶⁷⁸⁹⁻".index(c)] for c in m.group(0)) + ")", s)
    s = s.replace("−", "-").replace("·", "*").replace("×", "*").replace("÷", "/")
    s = s.replace("π", "pi")
    s = re.sub(r"(\d+)!", r"factorial(\1)", s)
    s = s.replace("^", "**")
    s = re.sub(r"\bxor\b", "^", s)
    s = re.sub(r"\band\b", "&", s)
    s = re.sub(r"\bor\b", "|", s)
    s = re.sub(r"(\d)e\*\*?([-+]?\d)", r"\1e\2", s)  # 1e-9
    # keep integers exact for bitwise work, floats exact for the rest
    return s


import ast  # noqa: E402


class _Rewrite(ast.NodeTransformer):
    def visit_BinOp(self, node):
        self.generic_visit(node)
        if isinstance(node.op, ast.MatMult):  # our stand-in for the infix word `mod`
            return ast.Call(ast.Name("mod", ast.Load()), [node.left, node.right], [])
        if isinstance(node.op, ast.Add):
            return ast.Call(ast.Name("add", ast.Load()), [node.left, node.right], [])
        return node

    def visit_List(self, node):
        nested = bool(node.elts) and all(isinstance(e, ast.List) for e in node.elts)
        if nested:  # a matrix: its rows are plain lists, not vectors
            node.elts = [ast.List([self.visit(v) for v in row.elts], ast.Load()) for row in node.elts]
            return ast.Call(ast.Name("Matrix", ast.Load()), [node], [])
        self.generic_visit(node)
        return ast.Call(ast.Name("Vec", ast.Load()), [node], [])

    def visit_Constant(self, node):
        if isinstance(node.value, float):
            return ast.Call(ast.Attribute(ast.Name("mp", ast.Load()), "mpf", ast.Load()), [ast.Constant(repr(node.value))], [])
        if isinstance(node.value, int) and not isinstance(node.value, bool):
            return ast.Call(ast.Attribute(ast.Name("mp", ast.Load()), "mpf", ast.Load()), [ast.Constant(str(node.value))], [])
        return node


def reference(entry, base=10):
    """The reference value of an entry: an mpf, a list or a sympy Matrix. Raises Unmapped if not modelled."""
    s = to_python(entry)
    if base != 10:
        digits = "0123456789abcdef"[:base]
        words = {"and", "or", "xor", "not", "mod", "shift"}
        s = re.sub(r"(?<![\w.])(?!0x|0b)([0-9A-Fa-f]+)(?![\w.(])",
                   lambda m: str(int(m.group(1), base)) if all(c in digits for c in m.group(1).lower()) and m.group(1).lower() not in words else m.group(0), s)
    s = re.sub(r"\bmod\b(?!\()", "@", s)
    s = re.sub(r"\bnot\(", "bnot(", s)
    s = re.sub(r"0x([0-9a-fA-F]+)", lambda m: str(int(m.group(1), 16)), s)
    s = re.sub(r"0b([01]+)", lambda m: str(int(m.group(1), 2)), s)
    bitwise = bool(re.search(r"[&|]|(?<!\*)\^(?!\*)", s)) or "shift(" in s or "powmod(" in s or "gcd(" in s or "lcm(" in s or "bnot(" in s
    try:
        tree = ast.parse(s, mode="eval")
    except SyntaxError as e:
        raise Unmapped("syntax the reference does not read: %s" % e.msg)
    if not bitwise:
        tree = _Rewrite().visit(tree)
    else:
        class _Mod(_Rewrite):
            def visit_Constant(self, node):
                return node
        tree = _Mod().visit(tree)
    ast.fix_missing_locations(tree)
    env = dict(NAMESPACE)
    env["mp"] = mp
    env["__builtins__"] = {}
    try:
        return eval(compile(tree, "<entry>", "eval"), env)
    except ZeroDivisionError:
        raise Unmapped("division by zero")
    except NameError as e:
        raise Unmapped("name the reference does not have: %s" % e)


def wrap_word(values, bits):
    """Two's complement wrap of whole numbers to a word of `bits`, as programmer mode must do."""
    out = []
    for v in values:
        if v == mp.floor(v):
            n = int(v) % (1 << bits)
            out.append(mp.mpf(n - (1 << bits) if n >= (1 << (bits - 1)) else n))
        else:
            out.append(v)
    return out


def to_values(v):
    """A flat list of numbers from any reference result, or None for booleans and other kinds."""
    if isinstance(v, (bool, np.bool_)):
        return [mp.mpf(int(v))]
    if v is None:
        return None
    if isinstance(v, np.ndarray):
        v = v.tolist()
    if isinstance(v, sp.MatrixBase):
        v = v.tolist()
    if isinstance(v, (list, tuple)):
        out = []
        for e in v:
            f = to_values(e)
            if f is None:
                return None
            out += f
        return out
    try:
        return [mp.mpf(complex(v).real) if isinstance(v, complex) else mp.mpf(v)]
    except (TypeError, ValueError):
        try:
            return [mp.mpf(str(sp.N(v, 30)))]
        except Exception:  # noqa: BLE001
            return None


def parse_values(text):
    """The numbers in dkde-calc's printed result: a number, a vector or a matrix (nested lists)."""
    t = text.replace("−", "-").replace("×10^", "e").replace("·10^", "e")
    if t.strip() in ("true", "false"):
        return [mp.mpf(1 if t.strip() == "true" else 0)]
    if "~" in t and not t.lstrip().startswith("["):
        t = t.split("~")[-1]
    if re.search(r"[A-DF-Za-df-z√π]", t.replace("e-", "").replace("e+", "")) and not re.fullmatch(r"[\s\d.,\[\]/+\-eE]*", t):
        return None
    toks = re.findall(r"[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?(?:/\d+)?", t)
    if not toks:
        return None
    out = []
    for k in toks:
        if "/" in k:
            a, b = k.split("/")
            out.append(mp.mpf(a) / mp.mpf(b))
        else:
            out.append(mp.mpf(k))
    return out


def close(a, b, rel=2e-9, ab=2e-12):
    a, b = mp.mpf(a), mp.mpf(b)
    return abs(a - b) <= max(ab, rel * max(abs(a), abs(b)))
