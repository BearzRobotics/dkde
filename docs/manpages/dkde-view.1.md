# NAME
dkde-view - image viewer

# SYNOPSIS
dkde-view [-h | --help] [-V | --version]

dkde-view [FILE]

# DESCRIPTION
dkde-view is the DKDE image viewer. Images are decoded in Zig (PNG, JPEG, GIF, BMP, TGA, QOI, TIFF and more, with EXIF orientation); gdk-pixbuf is the fallback for formats it cannot read (WebP, SVG, ICO, AVIF, JPEG XL), as far as the installed loaders go. It zooms and moves through the other images in the same directory.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# FILE
: The image to open.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-files(1), dkde-snip(1), dkde-help(1)
