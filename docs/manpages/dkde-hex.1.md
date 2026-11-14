# NAME
dkde-hex - hex editor

# SYNOPSIS
dkde-hex [-h | --help] [-V | --version]

dkde-hex [FILE]

dkde-hex --device DEVICE

# DESCRIPTION
dkde-hex shows the bytes of a file, a disk or partition, or a running process's memory, as offsets, hexadecimal and text, with a data inspector (integers, floats and more at the cursor). It edits with undo and redo, finds and replaces bytes and text, goes to an offset or sector, lists the strings in the data, and copies a selection as hex, text, a C array, Python bytes, Base64 or an escaped string.

The Structure menu describes the bytes with a format: Kaitai Struct (.ksy) files or ImHex patterns (.hexpat), picked automatically when one matches, with colour highlights and a tree of the fields. Folders of formats and patterns are set in hex.toml, and the menu can download the public collections.

Disk mode (Disk menu) opens a disk or partition read-only, a window at a time, and searches the whole device. Reading a disk needs administrator rights; dkde-hex offers to open it in a second window as administrator. Writing is a separate step: **Enable writing**, then **Write changes**, each confirmed, with a warning if the disk is mounted. A disk can be saved as an image (to a regular file only) or cloned onto another disk; the clone refuses the source itself, a mounted disk and a smaller target, and asks before overwriting.

**Edits to a real disk can make it and its files unreadable. Try disk mode on an image file or a disk you do not care about first.**

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
FILE
: The file to open. Without it the editor starts with an empty tab.

--device DEVICE
: Open the disk or partition DEVICE (for example /dev/sdb1) read-only, in disk mode.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/hex.toml
: Settings: formats-dir, patterns-dir, disk-window-mib (how much of a disk is held in memory, 1 to 512), inspector, and the window's size. $XDG_DATA_DIRS/dkde/hex.toml has the defaults, with every key.

~/.cache/dkde/hex-formats.index
: What was learned from each format file, so the folders are not read again at every start. A file is read again only when it is new or its size or modification time changed. Deleting the index makes the next start scan everything.

~/.local/share/dkde/formats
: Kaitai Struct .ksy files, when formats-dir is empty.

~/.local/share/dkde/patterns
: ImHex patterns, when patterns-dir is empty.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-edit(1), dkde-parted(1), dkde-help(1)
