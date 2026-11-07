#!/usr/bin/env python3
"""Keeps only some characters of a TrueType (glyf) font. Standard library only.

    scripts/subset-ttf.py IN.ttf OUT.ttf "characters to keep"

Glyph numbers stay as they are (the glyphs that are not kept become empty), so
composite glyphs need no renumbering; the font gets a new, small cmap (format 4,
BMP only), a short loca and a compact hmtx. Layout tables (GSUB, GPOS, ...) and the
vertical metrics are dropped. Used for data/fonts/native/DroidSansFallbackSubset.ttf,
which holds the Chinese calendar's characters (see src/calendar/native.zig).
"""
import struct, sys


def checksum(data):
    data = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(">%dI" % (len(data) // 4), data)) & 0xFFFFFFFF


def read_tables(font):
    n = struct.unpack(">H", font[4:6])[0]
    tables = {}
    for i in range(n):
        tag, _, off, length = struct.unpack(">4sIII", font[12 + 16 * i:28 + 16 * i])
        tables[tag.decode()] = font[off:off + length]
    return tables


def cmap_lookup(cmap):
    n = struct.unpack(">H", cmap[2:4])[0]
    best = None
    for i in range(n):
        pid, eid, off = struct.unpack(">HHI", cmap[4 + 8 * i:12 + 8 * i])
        fmt = struct.unpack(">H", cmap[off:off + 2])[0]
        if (pid, eid) in ((3, 10), (3, 1), (0, 3), (0, 4)) and fmt in (4, 12):
            if best is None or fmt == 12:
                best = (fmt, off)
    fmt, off = best
    table = {}
    if fmt == 12:
        groups = struct.unpack(">I", cmap[off + 12:off + 16])[0]
        for g in range(groups):
            start, end, gid = struct.unpack(">III", cmap[off + 16 + 12 * g:off + 28 + 12 * g])
            for c in range(start, end + 1):
                table[c] = gid + c - start
    else:
        segx2 = struct.unpack(">H", cmap[off + 6:off + 8])[0]
        seg = segx2 // 2
        ends = struct.unpack(">%dH" % seg, cmap[off + 14:off + 14 + segx2])
        starts = struct.unpack(">%dH" % seg, cmap[off + 16 + segx2:off + 16 + 2 * segx2])
        deltas = struct.unpack(">%dh" % seg, cmap[off + 16 + 2 * segx2:off + 16 + 3 * segx2])
        ro_pos = off + 16 + 3 * segx2
        ranges = struct.unpack(">%dH" % seg, cmap[ro_pos:ro_pos + segx2])
        for i in range(seg):
            for c in range(starts[i], ends[i] + 1):
                if c == 0xFFFF:
                    continue
                if ranges[i] == 0:
                    gid = (c + deltas[i]) & 0xFFFF
                else:
                    p = ro_pos + 2 * i + ranges[i] + 2 * (c - starts[i])
                    gid = struct.unpack(">H", cmap[p:p + 2])[0]
                    if gid:
                        gid = (gid + deltas[i]) & 0xFFFF
                table[c] = gid
    return table


def glyph_data(tables, loca_fmt, gid):
    loca, glyf = tables["loca"], tables["glyf"]
    if loca_fmt == 0:
        a, b = struct.unpack(">HH", loca[2 * gid:2 * gid + 4])
        a, b = a * 2, b * 2
    else:
        a, b = struct.unpack(">II", loca[4 * gid:4 * gid + 8])
    return glyf[a:b]


def components(data):
    """Glyph ids a composite glyph is made of."""
    out = []
    if len(data) < 10 or struct.unpack(">h", data[:2])[0] >= 0:
        return out
    p = 10
    while True:
        flags, gid = struct.unpack(">HH", data[p:p + 4])
        out.append(gid)
        p += 4
        p += 4 if flags & 1 else 2
        if flags & 8:
            p += 2
        elif flags & 0x40:
            p += 4
        elif flags & 0x80:
            p += 8
        if not flags & 0x20:
            return out


def main(src, dst, chars):
    font = open(src, "rb").read()
    t = read_tables(font)
    num = struct.unpack(">H", t["maxp"][4:6])[0]
    loca_fmt = struct.unpack(">h", t["head"][50:52])[0]
    lookup = cmap_lookup(t["cmap"])
    keep = {0}
    mapping = {}
    for ch in sorted(set(chars)):
        gid = lookup.get(ord(ch), 0)
        if gid == 0:
            print("missing:", ch)
            continue
        mapping[ord(ch)] = gid
        keep.add(gid)
    todo = list(keep)
    while todo:
        g = todo.pop()
        for c in components(glyph_data(t, loca_fmt, g)):
            if c not in keep:
                keep.add(c)
                todo.append(c)
    glyf = bytearray()
    offsets = []
    for gid in range(num):
        offsets.append(len(glyf))
        if gid in keep:
            d = glyph_data(t, loca_fmt, gid)
            glyf += d + b"\0" * (-len(d) % 4)
    offsets.append(len(glyf))
    assert len(glyf) < 131070
    loca = struct.pack(">%dH" % (num + 1), *[o // 2 for o in offsets])
    # hmtx: full entries up to the last kept glyph, then left side bearings only.
    old_n = struct.unpack(">H", t["hhea"][34:36])[0]
    hm = t["hmtx"]
    last = max(keep)
    metrics = bytearray()
    for gid in range(num):
        adv, lsb = struct.unpack(">Hh", hm[4 * gid:4 * gid + 4]) if gid < old_n else (struct.unpack(">H", hm[4 * (old_n - 1):4 * (old_n - 1) + 2])[0], struct.unpack(">h", hm[4 * old_n + 2 * (gid - old_n):4 * old_n + 2 * (gid - old_n) + 2])[0])
        if gid not in keep:
            adv, lsb = (adv if gid <= last else adv), 0
        if gid <= last:
            metrics += struct.pack(">Hh", adv, lsb)
        else:
            metrics += struct.pack(">h", lsb)
    hhea = bytearray(t["hhea"])
    struct.pack_into(">H", hhea, 34, last + 1)
    head = bytearray(t["head"])
    struct.pack_into(">h", head, 50, 0)
    struct.pack_into(">I", head, 8, 0)
    # cmap, format 4: one segment for each character.
    cps = sorted(mapping)
    segs = [(c, c, (mapping[c] - c) & 0xFFFF) for c in cps] + [(0xFFFF, 0xFFFF, 1)]
    sc = len(segs)
    pow2 = 1
    while pow2 * 2 <= sc:
        pow2 *= 2
    sub = struct.pack(">HHHHHHH", 4, 16 + 8 * sc, 0, 2 * sc, 2 * pow2, pow2.bit_length() - 1, 2 * sc - 2 * pow2)
    sub = struct.pack(">HHH", 4, 16 + 8 * sc, 0) + struct.pack(">HHHH", 2 * sc, 2 * pow2, pow2.bit_length() - 1, 2 * sc - 2 * pow2)
    sub += struct.pack(">%dH" % sc, *[s[1] for s in segs]) + b"\0\0" + struct.pack(">%dH" % sc, *[s[0] for s in segs])
    sub += struct.pack(">%dH" % sc, *[s[2] for s in segs]) + struct.pack(">%dH" % sc, *[0] * sc)
    cmap = struct.pack(">HHHHI", 0, 1, 3, 1, 12) + sub
    maxp = bytearray(t["maxp"])
    post = struct.pack(">IiHHIIIII", 0x00030000, 0, 0, 0, 0, 0, 0, 0, 0)
    out_tables = {"OS/2": t["OS/2"], "cmap": cmap, "cvt ": t.get("cvt ", b""), "fpgm": t.get("fpgm", b""),
                  "glyf": bytes(glyf), "head": bytes(head), "hhea": bytes(hhea), "hmtx": bytes(metrics),
                  "loca": loca, "maxp": bytes(maxp), "name": t["name"], "post": post, "prep": t.get("prep", b"")}
    out_tables = {k: v for k, v in out_tables.items() if v}
    tags = sorted(out_tables)
    n = len(tags)
    pw = 1
    while pw * 2 <= n:
        pw *= 2
    header = struct.pack(">IHHHH", 0x00010000, n, pw * 16, pw.bit_length() - 1, n * 16 - pw * 16)
    offset = 12 + 16 * n
    directory, body = b"", b""
    head_pos = None
    for tag in tags:
        data = out_tables[tag]
        pad = data + b"\0" * (-len(data) % 4)
        if tag == "head":
            head_pos = offset + len(body)
        directory += struct.pack(">4sIII", tag.encode(), checksum(data), offset + len(body), len(data))
        body += pad
    font_out = bytearray(header + directory + body)
    struct.pack_into(">I", font_out, head_pos + 8, (0xB1B0AFBA - checksum(bytes(font_out))) & 0xFFFFFFFF)
    open(dst, "wb").write(font_out)
    print("kept %d glyphs, %d bytes" % (len(keep), len(font_out)))


main(sys.argv[1], sys.argv[2], sys.argv[3])
