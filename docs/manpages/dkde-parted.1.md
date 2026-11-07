# NAME
dkde-parted - partition manager

# SYNOPSIS
dkde-parted [-h | --help] [-V | --version]

dkde-parted [--selftest IMAGE]

# DESCRIPTION
dkde-parted shows disks and partitions. It reads lsblk, draws each disk with a size bar, and changes disks only through parted, mkfs.*, mount, umount and the filesystem checkers, as administrator, after a confirmation. A filesystem is offered only if its tools are installed. Inspecting a disk does not need root.

**Test it on a machine or disk image you do not care about first.** Every applied change is written to ~/.local/state/dkde/parted.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--selftest IMAGE
: Run the program's checks against the disk image IMAGE (a file, not a device) without a window, report a pass or FAIL per step and exit.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.local/state/dkde/parted
: The record of changes applied.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-files(1), dkde-help(1)
