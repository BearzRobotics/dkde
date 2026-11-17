# Learning path: Euclid's Elements in dkde-calc

The Learn view (View > Learn, Ctrl+Shift+L) opens beside whatever pane is open. Choosing a lesson opens the
Geometry pane and draws the given figure; *Next step* adds one step at a time, in colour, with Euclid's own
words for the statement and plain words for each step and the proof. The wording of definitions, postulates,
common notions and statements follows T. L. Heath's translation (public domain).

Where things are: `src/calc/figure.zig` (the drawing language of a step), `src/calc/euclid.zig` (the
lessons), `src/calc/learn.zig` (the view), `src/calc/geometry.zig` (the canvas that carries out the steps).

## All of the Elements

| Book | Subject | Propositions | Written |
|---|---|---|---|
| Foundations | Book I definitions (selection), the 5 postulates, the 5 common notions | | done (definitions: a selection) |
| I | Triangles, parallels, area, Pythagoras | 48 | I.1 to I.4 |
| II | Geometric algebra | 14 | |
| III | Circles | 37 | |
| IV | Inscribed and circumscribed figures | 16 | |
| V | Proportion (Eudoxus) | 25 | |
| VI | Similar figures | 33 | |
| VII | Number theory: gcd, primes | 39 | |
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

## Checking a lesson

`DKDE_LEARN_LESSON=I.2 DKDE_LEARN_STEPS=7 dkde-calc` (with `learn = true` and `pane = "geometry"` in
calc.toml) opens that lesson with that many steps drawn, for a screenshot.
