# NAME
dkde-files - file manager

# SYNOPSIS
dkde-files [-h | --help] [-V | --version]

dkde-files [DIRECTORY]

# DESCRIPTION
dkde-files is the DKDE file manager. It browses local directories, copies, moves, renames and deletes files, uses the trash, shows properties and mounts removable media. The program starts in DIRECTORY, or in the home directory without an operand. Anything that needs administrator rights is run through the configured elevation helper after a confirmation.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# DIRECTORY
: The directory to open first.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/files.toml
: File manager settings.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-edit(1), dkde-help(1)
