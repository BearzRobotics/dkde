# NAME
dkde-idle - idle and screen-lock daemon

# SYNOPSIS
dkde-idle [-h | --help] [-V | --version]

dkde-idle

# DESCRIPTION
dkde-idle runs the lock, screen-off and sleep actions after the keyboard and pointer have been quiet for the configured time. It uses the ext-idle-notify-v1 protocol and reads the power and menu settings of panel.toml, which it watches, so changes made in dkde-settings apply at once. Switching the screens off and on uses wlr-output-management (through the shared desktop API), so it needs a compositor that offers it; it no longer runs wlr-randr. On X11 (no WAYLAND_DISPLAY, a DISPLAY) it polls the time since the last input once a second through the MIT-SCREEN-SAVER extension and switches the screen off with DPMS; lock and sleep work the same as on Wayland, and the lock command is detected among xsecurelock, i3lock, slock and xlock. Before the lock and screen-off times it can dim the backlight (**dim-after**, **dim-level**; through brightnessctl or light, restored when the user returns), and with **battery-separate** set it uses the **-battery** twin of each time (dim-after-battery, lock-after-battery, screen-off-after-battery, sleep-after-battery) while the machine runs on its battery, checking the power source every 15 seconds. It opens no window and takes no operands.

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
