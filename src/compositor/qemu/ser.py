#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ser.py SOCKET 'command' [idle-seconds]: send a line to the VM's serial console, print what comes back."""
import re, socket, sys, time
path, cmd = sys.argv[1], sys.argv[2]
idle = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
s = socket.socket(socket.AF_UNIX); s.connect(path); s.settimeout(0.5)
if cmd != "-":
    s.sendall((cmd + "\n").encode())
out = b""; last = time.time()
while time.time() - last < idle:
    try:
        d = s.recv(65536)
        if d: out += d; last = time.time()
    except socket.timeout: pass
text = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out).decode("utf8", "replace").replace("\r", "")
print(text)
