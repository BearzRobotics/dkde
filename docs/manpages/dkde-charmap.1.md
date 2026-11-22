# NAME
dkde-charmap - character map

# SYNOPSIS
dkde-charmap [-h | --help] [-V | --version]

dkde-charmap

# DESCRIPTION
dkde-charmap shows every assigned Unicode character, block by block. Hover a character for its code point, name and UTF-8 bytes. Click characters to collect them in the text field (they also go to the Recent row) and copy the text to the clipboard with Copy or Enter. The search box finds characters by words of their name ("greek alpha"), by the character itself, or by code point (U+00E9, 0xE9). Large blocks and long result lists are shown a page at a time. It takes no operands.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

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
dkde-edit(1), dkde-help(1)
