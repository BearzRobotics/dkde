# NAME
dkde-panel - the DKDE panel: taskbar, Start menu, clock, tray and wallpaper

# SYNOPSIS
dkde-panel [-h | --help] [-V | --version]

dkde-panel

dkde-panel msg COMMAND

# DESCRIPTION
dkde-panel is the DKDE shell. It draws the taskbar with the Start button, the running windows, the system tray and the clock, shows the Start menu, paints the wallpaper and the desktop icons, and receives desktop notifications. It needs a Wayland compositor that offers wlr-layer-shell and wlr-foreign-toplevel-management (labwc does). Features that depend on an optional protocol or on a session D-Bus are switched off when it is missing; the panel itself still starts.

No other DKDE program needs the panel to run (DKDE-020). Stopping or restarting it does not close open applications.

With the operand msg the program does not start a panel. It sends COMMAND to the running panel over its control socket, prints the reply and exits.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
msg COMMAND
: Send COMMAND to the running panel. The commands are: **toggle-menu** (open or close the Start menu), **volume-up**, **volume-down**, **volume-mute**, **brightness-up**, **brightness-down**, **lock**, **sleep** and **reload** (read the configuration again). The reply is `ok` or a line beginning `error:`.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/panel.toml
: Panel, Start menu and power settings. Settings (dkde-settings) edits it, and the panel reads it again when it changes.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-idle(1), dkde-notify(1), dkde-help(1)
