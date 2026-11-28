#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Generate src/charmap/unidata.txt from the unicode-data package.

    scripts/gen-charmap-data.py [/usr/share/unicode] > src/charmap/unidata.txt

Lines:  "B first last Block Name"   a block that has assigned characters
        "P first last Block Name"   a private-use block (no assigned characters)
        "N code NAME"              one named character
        "R first last PREFIX"      a run named PREFIX + hex code (CJK, Tangut...)
Codes are hex. Controls, surrogates and private use are left out.
"""
import sys

d = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/unicode"
out = []
named = []
first = None
for line in open(f"{d}/UnicodeData.txt", encoding="utf-8"):
    f = line.rstrip("\n").split(";")
    cp, name, cat = int(f[0], 16), f[1], f[2]
    if cat in ("Cc", "Cs", "Co"):
        continue
    if name.endswith(", First>"):
        first = cp
        continue
    if name.endswith(", Last>"):
        label = name[1:-len(", Last>")].upper()
        if label.startswith("HANGUL SYLLABLE"):
            label = "HANGUL SYLLABLE "
        else:  # "CJK IDEOGRAPH EXTENSION B" is really "CJK UNIFIED IDEOGRAPH-20000"
            label = label.split(" EXTENSION")[0].split(" SUPPLEMENT")[0]
            label = label.replace("CJK IDEOGRAPH", "CJK UNIFIED IDEOGRAPH") + "-"
        out.append(("R", first, cp, label))
        continue
    out.append(("M" if cat in ("Mn", "Mc", "Me") else "N", cp, cp, name))

def assigned(lo, hi):
    return any(lo <= e[2] and e[1] <= hi for e in out)

blocks = []
for line in open(f"{d}/Blocks.txt", encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    rng, name = line.strip().split("; ")
    lo, hi = (int(x, 16) for x in rng.split(".."))
    if assigned(lo, hi):
        blocks.append(("B", lo, hi, name))
    elif "Private Use" in name and "Surrogates" not in name:  # filled from a font's own coverage, see charmap
        blocks.append(("P", lo, hi, name))

for k, a, b, n in blocks:
    print(f"{k} {a:X} {b:X} {n}")
for k, a, b, n in out:
    print(f"R {a:X} {b:X} {n}" if k == "R" else f"{k} {a:X} {n}")
