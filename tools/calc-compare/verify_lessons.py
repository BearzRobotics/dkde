#!/usr/bin/env python3
"""Checks every calculator line and every exercise answer in data/learn against independent references
(mpmath, scipy, sympy). Run from the repository root with the built binary at zig-out/bin/dkde-calc:

    python3 -I tools/calc-compare/verify_lessons.py [DIR-or-FILE ...]

Prints a summary and every disagreement; entries the references cannot model are listed as unchecked,
never counted as passes. Exit status 1 when anything disagrees.
"""

import sys
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mpmath as mp  # noqa: E402

import refeval  # noqa: E402
import symcheck  # noqa: E402

ERROR_WORDS = ("TIMEOUT", "UnknownName", "WrongArguments", "Domain", "Syntax", "NoSolution", "Overflow", "DivideByZero", "STDERR")


def entries_of(path):
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    lid = doc.get("id", path.name)
    for i, step in enumerate(doc.get("step", []), 1):
        prog = step.get("mode") == "programmer"
        tag = " [programmer mode base=%d bits=%d]" % (step.get("base", 10), step.get("bits", 64))
        for key in ("calc", "work"):
            for e in step.get(key, []):
                yield (str(path), lid, "step %d %s%s" % (i, key, tag if prog else ""), e)
    for i, ex in enumerate(doc.get("exercise", []), 1):
        if "answer" in ex:
            yield (str(path), lid, "exercise %d answer" % i, ex["answer"])


def check(item):
    bits = None
    path, lid, where, entry = item
    base, extra = 10, ()
    if "[programmer mode" in where:
        import re
        m = re.search(r"base=(\d+) bits=(\d+)", where)
        base = int(m.group(1))
        bits = int(m.group(2))
        extra = ("--programmer", "--base", m.group(1), "--bits", m.group(2))
    out = refeval.dkde_eval([entry], extra=extra)[0]
    first = out.split("\n")[0]
    if any(w in out for w in ERROR_WORDS):
        return (item, "dkde-error", out)
    low = entry.strip()
    for name in ("dsolve", "ilaplace", "laplace", "integral", "derivative", "expand", "factor", "diff", "limit", "taylor"):
        if low.startswith(name + "("):
            try:
                ok, why = symcheck.check(name, low, first)
            except symcheck.Unmapped as e:
                return (item, "unchecked", "%s: %s" % (e, first))
            return (item, "ok" if ok else "MISMATCH", why if not ok else first)
    if low.count("=") == 1 and "==" not in low and "<=" not in low and ">=" not in low and "<" not in low and ">" not in low and not low.startswith(("dsolve", "ode")):
        try:
            ok, why = symcheck.check_equation(low, first)
        except (symcheck.Unmapped, Exception) as e:  # noqa: BLE001
            return (item, "unchecked", "equation: %s" % e)
        return (item, "ok" if ok else "MISMATCH", why)
    try:
        ref = refeval.reference(entry, base)
    except refeval.Unmapped as e:
        return (item, "unchecked", str(e))
    except Exception as e:  # noqa: BLE001  (a reference that cannot read the entry is reported, not hidden)
        return (item, "unchecked", "reference could not read it: %s" % e)
    want = refeval.to_values(ref)
    if want is None:
        return (item, "unchecked", "reference gave a non-number (%s)" % type(ref).__name__)
    if bits:
        want = refeval.wrap_word(want, bits)
    if "eigenvalues" in entry:
        want = sorted(want)
    got = refeval.parse_values(first)
    if got is None:
        return (item, "unchecked", "dkde printed a non-number: %s" % first)
    if "eigenvalues" in entry:
        got = sorted(got)
    ok = len(got) == len(want) and all(refeval.close(a, b, 5e-8, 5e-11) for a, b in zip(got, want))
    return (item, "ok" if ok else "MISMATCH", "dkde %s, reference %s" % (first, [mp.nstr(w, 12) for w in want]))


def main(argv):
    roots = [Path(a) for a in argv] or [Path("data/learn")]
    files = []
    for r in roots:
        files += sorted(r.rglob("*.toml")) if r.is_dir() else [r]
    items = [it for f in files for it in entries_of(f)]
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(check, items))
    counts = {}
    for _, status, _ in results:
        counts[status] = counts.get(status, 0) + 1
    bad = [r for r in results if r[1] in ("MISMATCH", "dkde-error")]
    unchecked = [r for r in results if r[1] == "unchecked"]
    print("entries: %d   %s" % (len(items), "   ".join("%s: %d" % kv for kv in sorted(counts.items()))))
    for (path, lid, where, entry), status, why in bad:
        print("\n%s  %s  %s\n  entry:  %s\n  %s: %s" % (status, lid, where, entry, "why", why))
    if "--unchecked" in argv or True:
        reasons = {}
        for (path, lid, where, entry), status, why in unchecked:
            key = why.split(":")[0]
            reasons.setdefault(key, []).append("%s %s: %s" % (lid, where, entry))
        print("\nunchecked, by reason:")
        for k, v in sorted(reasons.items(), key=lambda kv: -len(kv[1])):
            print("  %4d  %s   e.g. %s" % (len(v), k, v[0]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main([a for a in sys.argv[1:] if not a.startswith("--")]))
