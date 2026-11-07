#!/usr/bin/env python3
"""Gives every glyph of data/fonts/RosquinGlyphs.ttf a zero advance width.

Offline tool, standard library only. The glyphs are layers of one 900x900 stamp
that are printed on top of one another. With a zero advance, a string of them in
any program lands on the same spot, so a copied stamp (all its characters, then
one EM SPACE, which gives the run its width) shows as one glyph wherever the
Rosquin Glyphs font is installed and used. Run it after build-rosquin-font.py,
which does the same for new builds (see its metrics line); it is safe to run twice.

    scripts/zero-advance-font.py data/fonts/RosquinGlyphs.ttf
"""
import struct, sys


def checksum(data):
    data = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(">%dI" % (len(data) // 4), data)) & 0xFFFFFFFF


def main(path):
    font = bytearray(open(path, "rb").read())
    n = struct.unpack(">H", font[4:6])[0]
    tables = {}
    for i in range(n):
        tag, _, off, length = struct.unpack(">4sIII", font[12 + 16 * i:28 + 16 * i])
        tables[tag.decode()] = (12 + 16 * i, off, length)
    _, hhea, _ = tables["hhea"]
    hhea_off = tables["hhea"][1]
    metrics = struct.unpack(">H", font[hhea_off + 34:hhea_off + 36])[0]
    hmtx_off = tables["hmtx"][1]
    for g in range(1, metrics):  # glyph 0 is .notdef: it keeps its width
        struct.pack_into(">H", font, hmtx_off + 4 * g, 0)
    # Table checksums, then the whole-font checksum in head.
    head_off = tables["head"][1]
    struct.pack_into(">I", font, head_off + 8, 0)
    for tag, (entry, off, length) in tables.items():
        struct.pack_into(">I", font, entry + 4, checksum(bytes(font[off:off + length])))
    struct.pack_into(">I", font, head_off + 8, (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF)
    open(path, "wb").write(font)
    print("zero advance for %d glyphs" % (metrics - 1))


main(sys.argv[1])
