#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tiny QMP client: qmp.py SOCKET cmd [json-args]   e.g. qmp.py q.sock screendump '{"filename":"/x.ppm"}'"""
import json, socket, sys, time
def qmp(path, cmd, args=None):
    s = socket.socket(socket.AF_UNIX); s.connect(path); f = s.makefile('rw')
    json.loads(f.readline())
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); json.loads(f.readline())
    req = {"execute": cmd}
    if args: req["arguments"] = args
    f.write(json.dumps(req) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
if __name__ == "__main__":
    print(json.dumps(qmp(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)))
