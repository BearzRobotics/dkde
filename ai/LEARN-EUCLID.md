# Learning path: Euclid's Elements in dkde-calc

The Learn view (View > Learn, Ctrl+Shift+L) opens beside whatever pane is open. Choosing a lesson opens the
Geometry pane and draws the given figure; *Next step* adds one step at a time, in colour, with Euclid's own
words for the statement and plain words for each step and the proof. The wording of definitions, postulates,
common notions and statements follows T. L. Heath's translation (public domain).

Where things are: the lessons are TOML files in `data/learn/euclid/` (one file per lesson, format in
`src/calc/lessonfile.zig`; your own go in `~/.local/share/dkde/learn/`), `src/calc/figure.zig` (the
drawing lines of a step), `src/calc/learn.zig` (the view), `src/calc/geometry.zig` (the canvas that
carries out the steps).

## All of the Elements

| Book | Subject | Propositions | Written |
|---|---|---|---|
| Foundations | Book I definitions (selection), the 5 postulates, the 5 common notions | | done (definitions: a selection) |
| I | Triangles, parallels, area, Pythagoras | 48 | done (all 48) |
| II | Geometric algebra | 14 | done (all 14) |
| III | Circles | 37 | done (all 37) |
| IV | Inscribed and circumscribed figures | 16 | done (all 16) |
| V | Proportion (Eudoxus) | 25 | done (all 25; magnitudes are drawn as bars) |
| VI | Similar figures | 33 | done (all 33) |
| VII | Number theory: gcd, primes | 39 | done (all 39; numbers are drawn as bars) |
| VIII | Continued proportion in numbers | 27 | |
| IX | Numbers: primes are infinite, perfect numbers | 36 | |
| X | Incommensurables | 115 | |
| XI | Solid geometry | 39 | |
| XII | Areas and volumes by exhaustion | 18 | |
| XIII | The five regular solids | 18 | |

465 propositions in all. They are added book by book. Each one needs a figure (points with coordinates,
constructed crossings where Euclid constructs them), the statement, the steps and the proof, and each
figure is looked at on screen before it is committed. Books VII to X are about numbers and lengths, not
only figures: their steps use the same view with line segments standing for numbers.

## Command line

The calculator runs without a window for checking and for looking at figures:

    dkde-calc check-lessons [DIR...]    load every lesson file and run every step; exit 1 on a problem
    dkde-calc render data/learn/euclid/b01-p002.toml -o fig.png [--step N | --each] [--size WxH]
    dkde-calc eval -v "1/3 + 1/6" "x = 5" "x^2 + 1"
    dkde-calc steps "x^2 - 5x + 6 = 0"

`check-lessons` catches a file that does not read, a step that draws from a point not drawn yet, a
construction whose shapes do not cross, and a `calc` line that fails. `render` draws a lesson (all of it, one
step, or every step as its own file) to PNG or SVG with the same code as the window.

## Checking a lesson in the window

`DKDE_LEARN_LESSON=I.2 DKDE_LEARN_STEPS=7 dkde-calc` (with `learn = true` and `pane = "geometry"` in
calc.toml) opens that lesson with that many steps drawn, for a screenshot.

## 3D

A figure can be drawn in space: `view3d` turns the Geometry pane into a parallel projection (x and y along the floor, z up), `point A x y z` gives a point a height, and the same `segment`, `line`, `polygon ... fill` lines draw edges and faces. Faces are drawn far to near and lit by their slope; a name starting with `_` is a point that is not drawn or labelled. Drag to turn the view. The 3D switch in the Geometry tool bar does the same by hand. Books XI to XIII use this.
