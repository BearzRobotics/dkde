# NAME
dkde-calc - calculator with standard and scientific modes

# SYNOPSIS
dkde-calc [-h | --help] [-V | --version]

dkde-calc

# DESCRIPTION
dkde-calc is a calculator with a standard and a scientific mode. It takes no operands.

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
dkde-clock(1), dkde-help(1)
