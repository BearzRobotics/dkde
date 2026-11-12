# NAME
dkde-settings - desktop settings

# SYNOPSIS
dkde-settings [-h | --help] [-V | --version]

dkde-settings [--page PAGE]

# DESCRIPTION
dkde-settings is the DKDE settings program. It edits the configuration files of the other DKDE programs and, through documented system tools, some system settings such as the network, Bluetooth, printers, users and the date and time. It works without the panel running. A configuration file with a syntax error is reported and left alone, not overwritten.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--page PAGE
: Open this page first. PAGE is one of: appearance, taskbar, startmenu, display, audio, power, network, bluetooth, printers, mouse, keyboard, shortcuts, defaults, terminal, datetime, region, about, online, users.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# ONLINE ACCOUNTS
The Online accounts page (--page online, under Accounts) is where optional online calendars are set up for dkde-calendar and the panel's reminders. It is the only place they are managed. An account is the private https link of an iCalendar (.ics) feed, with a name, an on/off switch and a choice of when to update: only when asked, or on start of dkde-calendar if the last update is older than an hour, 6 hours or a day. Add calendar saves the account and downloads it once; Update now downloads every account that is on; Remove (after a question) deletes the account and its cached copy. Each button acts at once, and is not held back until Apply like the other pages.

Nothing is contacted until an account is added, and the page never asks for a password: it only reads, and cannot send anything to the server. Plain http links are refused, and the link is shown only as its host name. See dkde-calendar(1), ONLINE CALENDARS, for what is read, how repeats are handled, and the limits. The accounts are the [account.ID] groups of dkde.toml (keys name, url, enabled, refresh-minutes and color); the link is a secret, so keep that file private on a shared computer.

# FILES
~/.cache/dkde/feeds/ID.ics
: The last downloaded copy of each online calendar; private to the user and safe to delete.

~/.config/dkde/*.toml
: The files this program edits. Writes replace the file in one step.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-panel(1), dkde-term(1), dkde-setup(1), dkde-help(1)
