# NAME
dkde-setup - check and fix the desktop setup

# SYNOPSIS
dkde-setup [-h | --help] [-V | --version]

dkde-setup [--check] [--yes] [--once] [--write-config] [--migrate-config]

# DESCRIPTION
dkde-setup finds what is missing for a working DKDE session and fixes what it can. User-level fixes (files in the user's own configuration directory) are applied after one confirmation; existing labwc files are only added to, and backed up once before the first edit. Anything that needs root is never run silently: the exact command and the reason are shown, and each is run only after you answer **y**.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--check
: Only report. Exit status 1 if something is missing.

--yes, -y
: Apply the user-level fixes without asking.

--once
: The first-login run: apply the user-level fixes quietly, and only if setup has never run for this user. dkde-session uses this.

--write-config
: Write every configuration file with all defaults in it. Missing files are created and existing ones only gain the keys they lack.

--migrate-config
: Convert old *.conf files in ~/.config/dkde to TOML. Each original is kept as *.conf.migrated and no existing *.toml is overwritten.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 when nothing is missing or all fixes were applied; 1 with **--check** when something is missing; 2 for an unknown option.

# FILES
$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-panel(1), dkde-help(1)
