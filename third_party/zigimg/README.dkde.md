# zigimg in dkde

Vendored from https://github.com/zigimg/zigimg (commit 083d0304840a3f5fd547c2e2005148a18886c401),
MIT, Zig 0.17.0, with its own `build.zig` (used as a package dependency: see `build.zig.zon`).
Pure Zig, no system libraries. Used through `src/imgcodec/` by dkde-view and the PDF renderer.

The `tests/` folder (which needs a separate test-suite checkout) is left out.
Local changes, one line each:

- `zigimg.zig`: the final `test { ... }` block that imports `tests/` is removed.
