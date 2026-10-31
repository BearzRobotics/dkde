# Structure view in dkde-hex

`dkde-hex` can read a [Kaitai Struct](https://kaitai.io) description (`.ksy`) of a
binary format, parse the open file with it and show the result next to the bytes.

## Getting formats

Formats are not bundled with dkde, because the community collection
([kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats)) has
mixed licences. Clone it, or any folder of `.ksy` files, and point dkde at it:

    git clone https://github.com/kaitai-io/kaitai_struct_formats ~/.local/share/dkde/formats

`~/.local/share/dkde/formats` is where dkde looks by default. To use another
folder, choose **Structure ▸ Formats folder…**, or set it in
`~/.config/dkde/hex.conf`:

    [hex]
    formats-dir=/path/to/kaitai_struct_formats

Subfolders are searched. Imports between formats (`meta: imports:`) are resolved
from the same folder.

## Using it

- Opening a file picks a format by its magic bytes (the `contents` of the first
  field), or by file extension when only one format claims it.
- **Structure ▸ Choose format…** (Ctrl+T) lists every format, best fit first, with
  a search box. **Load definition…** opens one `.ksy` file directly.
- The panel on the right is a tree. Double-click (or press Enter on) a row to
  expand it; selecting a row selects its bytes. Clicking in the hex view selects
  the field under the cursor, and the status bar shows its path, such as
  `chunks[3].body`.
- Fields are coloured in the hex view; **Show colours** turns that off.
- Edits re-parse a moment after you stop typing (or press F5).
- **Find strings…** lists ASCII and UTF-16 strings with their offsets.

## What is understood

The part of Kaitai Struct that describes layouts: `seq`, `types`, `instances`
(with `pos`, `io`, `value`), `enums`, the integer, float, bit-field, `str`,
`strz` and byte types in either endianness (including calculated endianness),
`size`, `size-eos`, `terminator`, `contents`, `repeat` (`eos`, `expr`, `until`),
`if`, `switch-on`, type parameters, and the expression language (arithmetic,
comparisons, ternary, `_root`, `_parent`, `_io`, `_index`, `_`, enum values,
array and string methods).

Not understood: `process` (such fields are shown as raw bytes), `valid`,
`doc` (ignored), user-defined sub-stream tricks beyond `pos`/`io`. Arrays show
their first 512 elements; the rest are parsed but not listed.

If a format does not fit the file, parsing stops at that point. What was read so
far stays in the tree and the problem appears as a red `error` row and in the
panel's note.

## Notes for developers

The `.ksy` YAML is read with a vendored copy of zig-yaml (`third_party/zig-yaml`).
That parser lacks block scalars, trailing comments and a few other YAML
features that real `.ksy` files use, so `src/hex/ksy/prep.zig` rewrites the text
first (keys are escaped, plain values quoted, `doc` text dropped). All 191 files
of kaitai_struct_formats load; run

    KSY_FORMATS_DIR=/path/to/kaitai_struct_formats zig build test

to check that, and to run every format over a sample file without crashing.
