# NAME
dkde-idle - idle and screen-lock daemon

# SYNOPSIS
dkde-idle [-h | --help] [-V | --version]

dkde-idle

# DESCRIPTION
dkde-idle runs the lock, screen-off and sleep actions after the keyboard and pointer have been quiet for the configured time. It uses the ext-idle-notify-v1 protocol and reads the power and menu settings of panel.toml, which it watches, so changes made in dkde-settings apply at once. It opens no window and takes no operands.

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
~/.config/dkde/panel.toml
: The [power] and [menu] sections.

# SEE ALSO
dkde-settings(1), dkde-panel(1), dkde-help(1)
