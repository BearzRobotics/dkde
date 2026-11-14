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

Nothing is contacted until an account is added, and the page never asks for a password: it only reads, and cannot send anything to the server. Plain http links are refused, and the link is shown only as its host name. See dkde-calendar(1), ONLINE CALENDARS, for what is read, how repeats are handled, and the limits. The accounts are the [account.ID] groups of dkde.toml (keys name, url, enabled, refresh-minutes and color; a GOA calendar has goa and calendar instead of url); the link is a secret, so keep that file private on a shared computer.

# DATE AND TIME
The Date & time page (--page datetime) sets the taskbar clock: a Clock style (or a custom strftime format), the **Calendar** its date codes count in, the time zone and the system time. The Calendar can be any system dkde-calendar has: Gregorian, Julian, Fixed (13 months), the three Rosquin layouts, Chinese, Hebrew, Coptic and Ethiopian. The codes @Y (year), @n (month name), @m (month number), @d (day), @N (weekday name) and @e (weekday number) count in it; the % codes are always Gregorian. See dkde-calendar(1), PANEL CLOCK, for all the codes. The choice is panel.clock-calendar in panel.toml.

# NETWORK
The Network page (--page network) uses NetworkManager when it is running (it asks **nmcli general**). It lists the devices, the Wi-Fi radio switch and the Wi-Fi networks in range (Connect asks for a password when one is needed; Disconnect), and the saved connections: Connect, Disconnect, Forget (after a question) and Edit. Edit shows the automatic-connect switch and, for IPv4 and for IPv6, a choice of Automatic, Fixed or Off; Fixed takes an address with its prefix length (192.168.1.20/24), a gateway and DNS servers. Each button acts at once through **nmcli** and is not held back until Apply. A Wi-Fi password is sent to nmcli on its standard input (not on the command line, where other users could read it) and is kept by NetworkManager, not by dkde-settings. VPN profiles, hidden Wi-Fi networks and creating wired profiles are not offered (NetworkManager makes "Wired connection 1" itself).

Without NetworkManager the page uses wpa_cli for Wi-Fi, and has a Fixed address (IPv4) section: an address, prefix, gateway and DNS servers that Apply writes between marked lines in /etc/dhcpcd.conf, through the same password dialog as other system changes (dkde-polkit-ui(1)). Clearing the fields and applying removes the block; nothing outside the marked lines is touched. There is no IPv6 on this path.

# ONLINE ACCOUNTS: GNOME ONLINE ACCOUNTS
The Accounts section at the top of the Online accounts page lists the accounts of GNOME Online Accounts (GOA), asked over D-Bus. The list is only read; the GOA service is never started just to show it, and with none running the page says so. Add or manage accounts… opens GOA's own window (gnome-online-accounts-gtk, or gnome-control-center online-accounts). For a Google account that signs in with OAuth2, the page asks Google which calendars the account has and the person ticks the ones to show; each is a read-only calendar like a link. dkde stores no password or token: at an update GOA hands out a short-lived access token and dkde-calendar reads the events with GET requests only. Sync all updates every chosen calendar. Contacts, mail and files from GOA, and calendars of other providers, are not offered.

# DEFAULT APPS
The Default apps page (--page defaults) chooses the web browser, file manager, text editor, image viewer, PDF viewer and terminal. A choice is written to ~/.config/mimeapps.list (the terminal to [default-apps] in dkde.toml). Until something is chosen, the DKDE session uses the programs of DKDE (dkde-files, dkde-edit, dkde-view, dkde-pdf, dkde-term) through the file dkde-mimeapps.list in the applications directory of the data directories, which GLib reads for XDG_CURRENT_DESKTOP=dkde. There is no DKDE web browser, so none is preset.

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
