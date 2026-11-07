#!/usr/bin/env python3
"""Build data/fonts/RosquinGlyphs.ttf from the layered calendar glyph master.

Offline tool, not part of the build. The font is committed. Needs fonttools and
potracer (pip install fonttools pillow numpy potracer).

    scripts/build-rosquin-font.py "src/calendar/rosquincalander/All option glphy.ora"

Every layer of the ORA export (stack.xml keeps the Photoshop layer names) becomes
one glyph in the Private Use Area, starting at U+E000. All glyphs share the
900x900 canvas of the master, so stacking components at the same origin
reassembles the full glyph exactly as in the PSD. The Zig side lives in
src/calendar/rosglyph.zig, which this script also writes.
"""
import io, re, sys, zipfile
import xml.etree.ElementTree as ET
import numpy as np
from PIL import Image
import potrace
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen

UPM, ASCENT, DESCENT, CANVAS = 900, 800, 100, 900
FIRST = 0xE000
SKIP = {"BG", "Keep"}  # background bitmap and the author's discarded variants


def slug(s):
    return re.sub(r"[^A-Za-z0-9]+", "_", s).strip("_")


def zname(g):
    n = g[3:].lower()
    return "g_" + n if n[0].isdigit() else n


def layers(root):
    out = []

    def walk(node, path):
        for c in node:
            if c.tag == "stack":
                walk(c, path + [c.get("name") or ""])
            elif c.tag == "layer":
                out.append((path, c))
    walk(root, [])
    return out


def area(poly):
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1])) / 2


def inside(pt, poly):
    x, y = pt
    c = False
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            c = not c
    return c


def reverse(start, segs):
    """The same closed contour walked backwards. segs: ('l', end) or ('c', c1, c2, end)."""
    pts = [start] + [s[-1] for s in segs]
    out = []
    for i in range(len(segs) - 1, -1, -1):
        s = segs[i]
        out.append(("l", pts[i]) if s[0] == "l" else ("c", s[2], s[1], pts[i]))
    return pts[-1], out


def trace(img, ox, oy, pen):
    a = np.asarray(img.convert("RGBA")).astype(float)
    ink = (a[..., 3] > 127) & (a[..., :3].mean(axis=2) < 160)

    def pt(p):
        return (p.x + ox, (CANVAS - (p.y + oy)) - DESCENT)
    contours = []
    # potracer treats False as filled, so hand it the background.
    for curve in potrace.Bitmap(~ink).trace(turdsize=2, alphamax=1.0, opttolerance=0.4):
        segs = []
        for seg in curve.segments:
            if seg.is_corner:
                segs += [("l", pt(seg.c)), ("l", pt(seg.end_point))]
            else:
                segs.append(("c", pt(seg.c1), pt(seg.c2), pt(seg.end_point)))
        contours.append((pt(curve.start_point), segs))
    polys = [[c[0]] + [s[-1] for s in c[1]] for c in contours]
    for k, (start, segs) in enumerate(contours):
        depth = sum(inside(polys[k][0], polys[j]) for j in range(len(polys)) if j != k)
        clockwise = area(polys[k]) < 0
        if clockwise != (depth % 2 == 0):  # outer: clockwise, hole: counter-clockwise
            start, segs = reverse(start, segs)
        pen.moveTo(start)
        for s in segs:
            if s[0] == "l":
                pen.lineTo(s[1])
            else:
                pen.curveTo(*s[1:])
        pen.closePath()


def main(ora):
    z = zipfile.ZipFile(ora)
    root = ET.fromstring(z.read("stack.xml"))
    names, glyphs, cmap, table = [".notdef"], {}, {}, []
    pen = TTGlyphPen(None)
    glyphs[".notdef"] = pen.glyph()
    cp = FIRST
    for path, el in layers(root):
        top = path[-1] if path else ""
        if top in SKIP:
            continue
        label = el.get("name")
        gname = "rq_" + "_".join(filter(None, [slug(top), slug(label)]))
        i = 2
        while gname in glyphs:
            gname = f"{gname}_{i}"; i += 1
        img = Image.open(io.BytesIO(z.read(el.get("src"))))
        tp = TTGlyphPen(None)
        trace(img, int(el.get("x")), int(el.get("y")), Cu2QuPen(tp, 1.0))
        glyphs[gname] = tp.glyph()
        names.append(gname)
        cmap[cp] = gname
        table.append((cp, gname, top, label))
        cp += 1

    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    for g in glyphs.values():
        g.recalcBounds(None)
    fb.setupHorizontalMetrics({n: (0 if n != ".notdef" else 500, getattr(glyphs[n], "xMin", 0)) for n in names})
    fb.setupHorizontalHeader(ascent=ASCENT, descent=-DESCENT)
    fb.setupNameTable({"familyName": "Rosquin Glyphs", "styleName": "Regular",
                       "uniqueFontIdentifier": "RosquinGlyphs-Regular", "fullName": "Rosquin Glyphs Regular",
                       "psName": "RosquinGlyphs-Regular", "version": "Version 1.0"})
    fb.setupOS2(sTypoAscender=ASCENT, sTypoDescender=-DESCENT, usWinAscent=ASCENT, usWinDescent=DESCENT, fsType=0)
    fb.setupPost()
    fb.save("data/fonts/RosquinGlyphs.ttf")

    with open("src/calendar/rosglyph.zig", "w") as f:
        f.write("//! Generated by scripts/build-rosquin-font.py. Do not edit.\n"
                "//! Code points of data/fonts/RosquinGlyphs.ttf (Private Use Area). Every glyph is\n"
                "//! drawn on the same 900x900 canvas, so glyphs printed on top of one another stack.\n\n")
        f.write('pub const family = "Rosquin Glyphs";\n\n')
        for cp, g, top, label in table:
            f.write(f"/// {top}: {label}\npub const {zname(g)}: u21 = 0x{cp:X};\n")
    print(f"{len(table)} glyphs, U+{FIRST:X}..U+{cp-1:X}")


main(sys.argv[1])
