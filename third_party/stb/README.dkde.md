# stb_image in dkde

`stb_image.h` v2.30 from https://github.com/nothings/stb, unchanged. Public domain or
MIT (the licence text is at the end of the header). `stb_impl.c` compiles it with only
the JPEG decoder (baseline and progressive, including CMYK). It is used by
`src/pdfrender/` for DCTDecode image streams. It is built by `build.zig` with Zig's
own C compiler, so nothing needs to be installed.
