# NAME
dkde-term - terminal emulator

# SYNOPSIS
dkde-term [-h | --help] [-V | --version]

dkde-term [-e COMMAND [ARG...]]

# DESCRIPTION
dkde-term is the DKDE terminal emulator. Terminal state is handled by libghostty-vt; text is drawn with Pango. It runs the user's shell, or the command given with **-e**. The terminal core is DKTermCore, an independent library.

A tab can be split into panes: **Alt+Shift+Plus** splits the active pane to the right, **Alt+Shift+Minus** splits it down. Each new pane runs the same profile in the same directory. **Ctrl+Alt+Left** and **Ctrl+Alt+Right** move between panes and **Ctrl+Shift+W** closes the active pane (the tab when it is the last). A pane whose program ends closes itself, unless the profile says to keep it open.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
-e COMMAND [ARG...]
: Run COMMAND with its arguments instead of the shell. Everything after **-e** belongs to the command and is not examined as an option.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/term.toml
: Terminal settings, edited on the Terminal page of dkde-settings.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-help(1)
