import json, re, os, math, sys
HERE = os.path.dirname(os.path.abspath(__file__))
res = json.load(open(os.path.join(HERE, "results.json"), encoding="utf-8"))

NUM = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?(?:/\d+(?:\.\d+)?)?")

def first_answer(s):
    # kalker: "= exact ≈ approx" / "≈ approx = exact": keep the first value only
    t = s.strip()
    t = re.sub(r"^[=≈]\s*", "", t)
    t = re.split(r"\s[≈=]\s", t)[0]
    return t

def norm(s):
    s = re.sub(r"(?<=\d[eE])\+", "", s)
    s = s.replace("−", "-").replace("×10^", "e").replace("·10^", "e").replace("x10^", "e").replace("*10^", "e")
    s = s.replace("E+", "e").replace("E-", "e-").replace(" ", "").replace(" ", "")
    for _ in range(8):
        s = re.sub(r"(?<=\d) (?=\d{3}\b)", "", s)  # digit grouping
    s = re.sub(r"\s*-\s*(?=\d)", " -", s)           # "1 - 2i" -> "1 -2i"
    s = re.sub(r"\+\s*", " ", s)
    s = re.sub(r"\(= [^)]*\)", "", s)               # ours: (= 7/12)
    s = s.replace("≈", " ").replace("=", " ")
    return s

def nums(s):
    out = []
    for m in NUM.findall(norm(s)):
        if "/" in m:
            a, b = m.split("/")
            try: out.append(float(a) / float(b))
            except Exception: pass
        else:
            try: out.append(float(m))
            except Exception: pass
    return out

def close(a, b, tol):
    if a == b: return True
    if math.isinf(a) or math.isinf(b): return False
    return abs(a - b) <= 1e-9 + tol * max(abs(a), abs(b))

def same(x, y, tol):
    nx, ny = nums(x), nums(y)
    if not nx or not ny:
        return norm(x).strip().lower() == norm(y).strip().lower()
    if len(nx) != len(ny): return False
    return all(close(p, q, tol) for p, q in zip(nx, ny))

TOL = {"qalc": 1e-9, "insect": 2e-5, "kalker": 2e-8}
tot = {t: [0, 0, 0] for t in TOL}  # agree, differ, no answer/skip
rows = []
for r in res:
    d = {}
    for t, tol in TOL.items():
        v = r[t]
        if v is None: continue
        if not v.strip() or v.startswith("ERR"):
            d[t] = "NOANS"; tot[t][2] += 1
        elif same(r["ours"], first_answer(v) if t == "kalker" else v, tol):
            d[t] = "ok"; tot[t][0] += 1
        else:
            d[t] = "DIFF"; tot[t][1] += 1
    rows.append((r, d))

print("per tool: agree / differ / no-answer-from-tool")
for t, (a, b, c) in tot.items():
    print(f"  {t:7s} {a:4d} {b:4d} {c:4d}")
print()
for r, d in rows:
    bad = [t for t, s in d.items() if s == "DIFF"]
    ours_bad = r["ours"].startswith("?") or "rror" in r["ours"] or r["ours"].strip() == ""
    if bad or ours_bad:
        print(f"[{r['cat']}] {r['expr']}")
        print(f"    ours  : {r['ours']}")
        for t in TOL:
            if r[t] is not None:
                print(f"    {t:6s}: {r[t]}   {d.get(t,'')}")
