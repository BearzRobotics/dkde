# zig-yaml, vendored

A YAML parser for Zig by Jakub Konka, MIT licensed (see `LICENSE`).

- Upstream: <https://codeberg.org/kubkon/zig-yaml> (the project moved there from
  <https://github.com/kubkon/zig-yaml>).
- Snapshot: GitHub commit `e5cf8ac3de410749fef57a3f3864100104043042`, version
  0.3.0, the contents of its `src/` directory.
- Why vendored: its `build.zig` does not run on Zig 0.17 (it uses `b.args`), so
  it cannot be used as a package dependency.
- Edits for Zig 0.17, which changed struct reflection (`@typeInfo(T).@"struct"`
  has `field_names` and `field_types` instead of `fields`) and the error bundle:
  - `src/Parser.zig`: `addExtra`, `payloadToExtraItems` and `init`
    (`ErrorBundle.Wip.init`).
  - `src/Tree.zig`: `extraData`.
  The typed `Yaml.parse` and stringify code, which also reflects on struct
  fields, is not used by dkde and is left as it was.
- Used by: `src/hex/ksy/` to read Kaitai Struct `.ksy` files. Note that this
  parser has no block scalars or trailing comments; `src/hex/ksy/prep.zig`
  rewrites the text before it gets here.
