#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Minimal RFB client: connects (no auth), asks for one raw full-screen update, saves a PNG."""
import socket, struct, sys
from PIL import Image
host, port, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port)); s.settimeout(20)
def rd(n):
    b = b''
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise EOFError
        b += c
    return b
rd(12); s.sendall(b'RFB 003.008\n')
n = rd(1)[0]; rd(n)            # security types
s.sendall(bytes([1])); rd(4)    # choose None; SecurityResult
s.sendall(bytes([1]))           # ClientInit shared
w, h = struct.unpack('>HH', rd(4)); rd(16); ln = struct.unpack('>I', rd(4))[0]; rd(ln)
# 32bpp little-endian true colour
s.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
s.sendall(struct.pack('>BxHi', 2, 1, 0))  # SetEncodings: raw
s.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, w, h))
img = Image.new('RGB', (w, h))
got = 0
while got < w * h:
    t = rd(1)[0]
    if t != 0: raise SystemExit('message %d' % t)
    rd(1); nrect = struct.unpack('>H', rd(2))[0]
    for _ in range(nrect):
        x, y, rw, rh, enc = struct.unpack('>HHHHi', rd(12))
        data = rd(rw * rh * 4)
        tile = Image.frombuffer('RGBA', (rw, rh), data, 'raw', 'BGRA', 0, 1).convert('RGB')
        img.paste(tile, (x, y)); got += rw * rh
img.save(out); print(out, w, h)
