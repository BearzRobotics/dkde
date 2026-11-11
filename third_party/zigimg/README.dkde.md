# zigimg in dkde

Vendored from https://github.com/zigimg/zigimg (commit 083d0304840a3f5fd547c2e2005148a18886c401),
MIT, Zig 0.17.1, with its own `build.zig` (used as a package dependency: see `build.zig.zon`).
Pure Zig, no system libraries. Used through `src/imgcodec/` by dkde-view and the PDF renderer.

The `tests/` folder (which needs a separate test-suite checkout) is left out.
Local changes, one line each:

- `zigimg.zig`: the final `test { ... }` block that imports `tests/` is removed.
- Damaged files are refused instead of crashing (each change is marked `dkde:` in the source).
  Found by feeding about 9,500 damaged PNG, JPEG, GIF, BMP, TIFF, TGA, PCX, QOI and netpbm
  files through `imgcodec`; in release builds these were out-of-bounds reads and writes:
  - `formats/jpeg.zig`: unknown markers, short segment lengths, Huffman and quantization table
    numbers and sizes, the restart-interval length.
  - `formats/jpeg/Scan.zig`: table selectors over 3, missing tables, scans naming a component the
    frame lacks, block indexes past the frame, zero runs past the end of a block, the scan length.
  - `formats/jpeg/FrameHeader.zig`: the frame length.
  - `formats/jpeg/huffman.zig`: overlapping codes; taking more bits than are left.
  - `formats/tiff.zig`, `formats/tiff/types.zig`: zero rows per strip, missing or short strip
    lists, more samples than bit sizes, missing extra samples, tag types other than short and long,
    huge tag counts, the tag-entry count overflowing.
  - `utils.zig`: `FixedStorage.resize` past its storage.
  - `compressions/lzw.zig`: code sizes of 12 bits or more (GIF).
  - `formats/qoi.zig`: unknown format and colour-space values.
  - `formats/pcx.zig`: the scan-line length overflowing.
  - `formats/png/reader.zig`: data after the image is ignored rather than asserted absent.
