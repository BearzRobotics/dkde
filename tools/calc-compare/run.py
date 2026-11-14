import os, re, subprocess, sys, json
sys.path.insert(0, os.path.dirname(__file__))
import importlib
C = importlib.import_module(sys.argv[2] if len(sys.argv) > 2 else 'cases').C

HERE = os.path.dirname(os.path.abspath(__file__))
TEST_BIN = sys.argv[1]
TOOLS = ["qalc", "insect", "kalker"]

def expr_for(tool, expr, ov):
    if tool in ov:
        return ov[tool]
    return expr

# ours, in one go
lines = []
for cat, expr, ov in C:
    e = expr_for("ours", expr, ov)
    lines.append("rad:" + e)
pf = os.path.join(HERE, "probe.txt")
open(pf, "w").write("\n".join(lines) + "\n")
outf = os.path.join(HERE, "probe_out.txt")
if os.path.exists(outf): os.remove(outf)
env = dict(os.environ, CALC_PROBE=pf, CALC_PROBE_OUT=outf)
subprocess.run([TEST_BIN], env=env, cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
ours = {}
for ln in open(outf, encoding="utf-8").read().split("\n"):
    if "\t=> " in ln:
        k, v = ln.split("\t=> ", 1)
        ours.setdefault(k, v)

def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (r.stdout + ("\n" + r.stderr if not r.stdout.strip() else "")).strip()
        return out
    except Exception as ex:
        return "ERR " + type(ex).__name__

def run_tool(tool, e):
    if tool == "qalc":
        out = run(["qalc", "-t", "-s", "precision 20", "-s", "angle rad", e])
        # drop qalc's "warning"/"error" preamble lines: keep last non-empty line
        ls = [l for l in out.split("\n") if l.strip()]
        return ls[-1] if ls else ""
    if tool == "insect":
        return " ".join(run(["insect", e]).split("\n"))
    if tool == "kalker":
        return " ".join(run(["kalker", e]).split("\n"))

res = []
for cat, expr, ov in C:
    row = {"cat": cat, "expr": expr, "ours": ours.get("rad:" + expr_for("ours", expr, ov), "?")}
    for t in TOOLS:
        e = expr_for(t, expr, ov)
        row[t] = None if e is None else run_tool(t, e)
    res.append(row)
json.dump(res, open(os.path.join(HERE, (sys.argv[3] if len(sys.argv) > 3 else "results.json")), "w"), ensure_ascii=False, indent=1)
print(len(res), "cases")
