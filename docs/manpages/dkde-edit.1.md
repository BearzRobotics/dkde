# NAME
dkde-edit - plain text editor

# SYNOPSIS
dkde-edit [-h | --help] [-V | --version]

dkde-edit [FILE...]

# DESCRIPTION
dkde-edit is a plain text editor in the style of Notepad. It opens, edits and saves UTF-8 text files, with find and replace and a configurable font and wrapping. Each FILE is opened in the window; without an operand an empty document is shown. **Ctrl+`** shows a terminal below the text (the same terminal as dkde-term), started in the folder of the open file.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
FILE...
: Files to open.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/edit.toml
: Editor settings.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-files(1), dkde-help(1)
