#!/usr/bin/env python3
"""Helpers for scripts/qemu-console-test/run (no third-party modules).

  tools.py cpio DIR OUT.gz     pack DIR as a gzipped newc cpio (no cpio program needed)
  tools.py mon CMD...          send monitor commands to ./mon.sock
  tools.py type TEXT           type TEXT on the guest keyboard (\\n is Enter)
  tools.py png IN.ppm OUT.png  convert a screendump
  tools.py lit FILE            print how many pixels differ from the top-left pixel
  tools.py same A B            exit 0 if two screendumps are identical
"""
import gzip, os, socket, stat, struct, sys, time, zlib


def cpio(root, out_path):
    out = bytearray()
    ino = [1]

    def entry(name, st, data=b"", target=None):
        if target is not None:
            data = target.encode()
        ino[0] += 1
        nm = name.encode() + b"\0"
        fields = (ino[0], st.st_mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0)
        out.extend(b"070701" + b"".join(b"%08X" % v for v in fields) + nm)
        out.extend(b"\0" * (-len(out) % 4))
        out.extend(data)
        out.extend(b"\0" * (-len(out) % 4))

    for d, dirs, files in os.walk(root):
        dirs.sort()
        for n in sorted(dirs) + sorted(files):
            p = os.path.join(d, n)
            rel = os.path.relpath(p, root)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                entry(rel, st, target=os.readlink(p))
            elif stat.S_ISDIR(st.st_mode):
                entry(rel, st)
            else:
                entry(rel, st, open(p, "rb").read())
    entry("TRAILER!!!", os.stat(root))
    with gzip.open(out_path, "wb") as f:
        f.write(bytes(out))


def monitor():
    s = socket.socket(socket.AF_UNIX)
    s.connect("mon.sock")
    s.settimeout(0.3)
    try:
        s.recv(65536)
    except Exception:
        pass
    return s


def send(s, cmd, pause):
    s.send(cmd.encode() + b"\n")
    time.sleep(pause)
    try:
        s.recv(65536)
    except Exception:
        pass


SPECIAL = {" ": "spc", "/": "slash", "|": "shift-backslash", "-": "minus", ".": "dot", "_": "shift-minus",
           "=": "equal", "$": "shift-4", "(": "shift-9", ")": "shift-0", "&": "shift-7", ";": "semicolon",
           '"': "shift-apostrophe", "'": "apostrophe", ">": "shift-dot", "<": "shift-comma", "*": "shift-8",
           ":": "shift-semicolon", "\n": "ret", "[": "bracket_left", "]": "bracket_right"}


def key_name(c):
    if c in SPECIAL:
        return SPECIAL[c]
    return "shift-" + c.lower() if c.isupper() else c


def ppm(path):
    d = open(path, "rb").read()
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def png(src, dst):
    w, h, px = ppm(src)
    raw = b"".join(b"\0" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))

    open(dst, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def lit(path):
    w, h, px = ppm(path)
    bg = px[:3]
    return sum(1 for i in range(0, len(px), 3) if px[i:i + 3] != bg)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "cpio":
        cpio(*args)
    elif cmd == "mon":
        s = monitor()
        for c in args:
            send(s, c, 0.4)
    elif cmd == "type":
        s = monitor()
        for c in args[0].replace("\\n", "\n"):
            send(s, "sendkey " + key_name(c), 0.12)
    elif cmd == "png":
        png(*args)
    elif cmd == "lit":
        print(lit(args[0]))
    elif cmd == "same":
        sys.exit(0 if open(args[0], "rb").read() == open(args[1], "rb").read() else 1)
    else:
        sys.exit(__doc__)


main()
