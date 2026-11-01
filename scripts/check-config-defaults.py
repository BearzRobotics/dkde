#!/usr/bin/env python3
"""Lists config keys the code reads that no file in data/*.conf lists, so the
shipped defaults stay complete (SPEC.md 6.1). Run from anywhere; exit 1 if any
are missing. Finds `"group", "key"` pairs, so keys built at run time and the
[profile:*] groups (see term_profile_template in src/common/config.zig) are
not covered."""
import collections, glob, os, re, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
have, groups = collections.defaultdict(set), set()
for f in glob.glob(os.path.join(root, "data", "*.conf")):
    g = None
    for line in open(f):
        m = re.match(r"\[(.+)\]", line.strip())
        if m:
            g = m.group(1); groups.add(g); continue
        m = re.match(r"#?\s*([a-z][a-z0-9-]*)\s*=", line)
        if m and g:
            have[g].add(m.group(1))

missing = collections.defaultdict(set)
for f in glob.glob(os.path.join(root, "src", "**", "*.zig"), recursive=True):
    if f.endswith(("common/config.zig", "termcore/ini.zig")):
        continue  # their tests use made-up keys
    for g, k in re.findall(r'"([a-z]+)",\s*"([a-z][a-z0-9-]*)"', open(f).read()):
        if g in groups and k not in have[g]:
            missing[g].add(k)
for g in sorted(missing):
    print(f"[{g}] missing: {', '.join(sorted(missing[g]))}")
sys.exit(1 if missing else 0)
