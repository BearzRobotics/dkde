import random, subprocess, os, sys, re, math, json
HERE = os.path.dirname(os.path.abspath(__file__))
TEST_BIN = sys.argv[1]
random.seed(20261114)

def dec(lo, hi, digits=3):
    return f"{random.uniform(lo, hi):.{digits}f}"

# name -> list of arg generators
F = {
 "sin": [lambda: dec(-10, 10)], "cos": [lambda: dec(-10, 10)], "tan": [lambda: dec(-1.5, 1.5)],
 "asin": [lambda: dec(-1, 1)], "acos": [lambda: dec(-1, 1)], "atan": [lambda: dec(-50, 50)],
 "sinh": [lambda: dec(-5, 5)], "cosh": [lambda: dec(-5, 5)], "tanh": [lambda: dec(-3, 3)],
 "asinh": [lambda: dec(-50, 50)], "acosh": [lambda: dec(1, 50)], "atanh": [lambda: dec(-0.99, 0.99)],
 "exp": [lambda: dec(-30, 30)], "ln": [lambda: dec(0.001, 1000)], "log10": [lambda: dec(0.001, 1e5)],
 "log2": [lambda: dec(0.01, 1e4)], "sqrt": [lambda: dec(0, 1e4)], "cbrt": [lambda: dec(-1e4, 1e4)],
 "gamma": [lambda: dec(0.05, 30)], "erf": [lambda: dec(-4, 4)], "erfc": [lambda: dec(-3, 6)],
 "atan2": [lambda: dec(-10, 10), lambda: dec(-10, 10)],
 "beta": [lambda: dec(0.1, 20), lambda: dec(0.1, 20)],
 "digamma": [lambda: dec(0.1, 30)], "zeta": [lambda: dec(1.1, 30)], "lambertw": [lambda: dec(0, 100)],
 "sinc": [lambda: dec(-20, 20)], "sech": [lambda: dec(-5, 5)], "csch": [lambda: dec(0.1, 5)], "coth": [lambda: dec(0.1, 5)],
 "asec": [lambda: dec(1.01, 30)], "acsc": [lambda: dec(1.01, 30)], "acot": [lambda: dec(-30, 30)],
 "normdist": [lambda: dec(-3, 3), lambda: "0", lambda: "1"], 
 "fibonacci": [lambda: str(random.randint(1, 200))],
 "nthprime": [lambda: str(random.randint(1, 2000))],
 "totient": [lambda: str(random.randint(1, 100000))],
}
# qalc spellings
QALC = {"normdist": None, "fibonacci": "fibonacci", "lambertw": "lambertw", "digamma": "digamma", "sinc": "sinc",
        "log2": "log2", "cbrt": "cbrt", "nthprime": "prime", "totient": "totient", "asec": "asec"}
cases = []
for name, gens in F.items():
    for _ in range(14):
        args = ",".join(g() for g in gens)
        cases.append((name, f"{name}({args})"))
# operators / mixed
for _ in range(60):
    a, b, c = dec(-100, 100, 2), dec(0.1, 100, 2), dec(1, 20, 1)
    cases.append(("expr", random.choice([f"({a})*({b})+({c})", f"({a})/({b})-({c})", f"({b})^({c})", f"({a})^3/({b})", f"sqrt({b})*({c})", f"({a})*({b})/({c})^2", f"1/({b})+1/({c})"])))
# stress
for e in ["sin(1e6)", "cos(1e10)", "tan(1e8)", "exp(700)", "exp(-700)", "ln(1e-300)", "ln(1e300)", "gamma(100.5)", "gamma(170.5)", "170!",
          "sqrt(1e-300)", "atan(1e20)", "sinh(50)", "cosh(100)", "tanh(20)", "asinh(1e10)", "acosh(1e10)", "atanh(0.999999)",
          "erf(6)", "erfc(10)", "erfc(20)", "acos(0.9999999)", "asin(-0.9999999)", "log10(1e-20)", "2^0.001", "10^-10", "(1+1e-10)^1e10",
          "sin(1e-10)", "tan(1.5707963)", "exp(1e-12)-1", "ln(1+1e-12)", "gamma(1e-5)", "zeta(1.001)", "zeta(50)"]:
    cases.append(("stress", e))

pf = os.path.join(HERE, "fprobe.txt"); outf = os.path.join(HERE, "fprobe_out.txt")
open(pf, "w").write("\n".join("rad:" + e for _, e in cases) + "\n")
if os.path.exists(outf): os.remove(outf)
subprocess.run([TEST_BIN], env=dict(os.environ, CALC_PROBE=pf, CALC_PROBE_OUT=outf), cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
ours = {}
for ln in open(outf, encoding="utf-8").read().split("\n"):
    if "\t=> " in ln:
        k, v = ln.split("\t=> ", 1); ours.setdefault(k, v)

NUM = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
def parse(s):
    s = s.replace("−", "-").replace("×10^", "e").replace(" ", "").replace(" ", "")
    s = re.sub(r"(?<=\d[eE])\+", "", s)
    s = re.sub(r"(?<=\d) (?=\d{3}\b)", "", s)
    s = re.sub(r"\(= [^)]*\)", "", s)
    m = NUM.findall(s.replace("≈", " ").replace("=", " "))
    return [float(x) for x in m]

def qalc(e):
    try:
        r = subprocess.run(["qalc", "-t", "-s", "precision 25", "-s", "angle rad", e], capture_output=True, text=True, timeout=30)
        ls = [l for l in r.stdout.split("\n") if l.strip()]
        return ls[-1] if ls else ""
    except Exception:
        return "ERR"

bad = []; n = 0; worst = {}
for cat, e in cases:
    qe = e
    nm = e.split("(")[0]
    if nm in QALC and QALC[nm] is None: continue
    if nm == "nthprime": qe = e.replace("nthprime", "prime")
    q = qalc(qe); o = ours.get("rad:" + e, "?")
    n += 1
    a, b = parse(o), parse(q)
    ok = False
    if a and b and len(a) == len(b):
        ok = all(abs(x - y) <= 1e-300 + 1e-9 * max(abs(x), abs(y)) or (abs(x) < 1e-11 and abs(y) < 1e-11) for x, y in zip(a, b))
    elif not a and not b:
        ok = o.strip() == q.strip()
    if not ok:
        err = None
        if a and b and len(a) == len(b):
            err = max(abs(x - y) / max(abs(x), abs(y), 1e-300) for x, y in zip(a, b))
        bad.append((cat, e, o, q, err))
print(f"{n} cases, {len(bad)} differ")
for cat, e, o, q, err in bad:
    print(f"[{cat}] {e}\n    ours: {o}\n    qalc: {q}" + (f"   rel.err {err:.2e}" if err is not None else ""))
