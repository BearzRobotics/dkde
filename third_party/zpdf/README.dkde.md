# zpdf in dkde

Vendored from https://github.com/donge/zpdf (commit 919b7685df629b405c1d5f6c809c86808f8657f0),
a hardened fork of https://github.com/Lulzx/zpdf. Both are CC0 (public domain); see `LICENSE`.
It is pure Zig with no dependencies and needs Zig 0.17.0.

Only the library sources in `src/` are kept. The benchmarks, the C, Python, Go and
WebAssembly bindings, the CLI and the test corpora are left out. `testpdf.zig` (which
generates small PDFs) is kept because `root.zig`'s own tests import it.

dkde uses it to read files (cross-references, object streams, filters, page tree),
tokenise content streams and extract text with positions. `src/pdfrender/` draws
pages with cairo on top of it. Local changes go here, one line each:

- (none yet)
