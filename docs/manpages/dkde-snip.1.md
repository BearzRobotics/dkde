# NAME
dkde-snip - screenshot tool

# SYNOPSIS
dkde-snip [-h | --help] [-V | --version]

dkde-snip [--full | --region | --window | --gui] [--area X,Y,W,H] [--delay SECONDS]

dkde-snip --scroll-region X,Y,W,H

# DESCRIPTION
dkde-snip takes screenshots through the wlr-screencopy protocol. The whole output is captured first; for a region the picture is shown frozen and you drag a rectangle on it. If the compositor does not offer the protocol, or refuses it, the program says so and exits. Capturing a single window is not offered, because the protocols used give no window geometry.

Without a mode option the program opens its own window to choose from.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--full
: Capture the whole output at once.

--region
: Pick a region on a frozen picture of the screen.

--window
: Accepted for compatibility; behaves as if no mode was given.

--gui
: Open the editor window.

--area X,Y,W,H
: Capture this rectangle (pixels) without asking.

--delay SECONDS
: Wait this long before capturing.

--scroll-region X,Y,W,H
: Take a scrolling capture of this region, driving the pointer through wlr-virtual-pointer. No picker is shown.

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
dkde-view(1), dkde-help(1)
