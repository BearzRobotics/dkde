# zig-yaml, vendored

A YAML parser for Zig by Jakub Konka, MIT licensed (see `LICENSE`).

- Upstream: <https://codeberg.org/kubkon/zig-yaml> (the GitHub copy at
  <https://github.com/kubkon/zig-yaml> is no longer the main one).
- Snapshot: GitHub commit `e5cf8ac3de410749fef57a3f3864100104043042`
  (2026-09-05), version 0.3.0, the contents of its `src/` directory unchanged.
- Why vendored: its `build.zig` does not run on Zig 0.17 (it uses `b.args`), and
  its typed `Yaml.parse(T)` uses reflection that 0.17 removed. dkde-hex uses only
  `Yaml.load` and the plain `Value` tree, which compile fine, and Zig does not
  analyse the unused function. Nothing here was edited.
- Used by: `src/hex/ksy/` to read Kaitai Struct `.ksy` files.
