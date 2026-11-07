# NAME
dkde-notify - send a desktop notification

# SYNOPSIS
dkde-notify [-h | --help] [-V | --version]

dkde-notify [-i ICON] [-t MILLISECONDS] [--] SUMMARY [BODY]

# DESCRIPTION
dkde-notify sends a desktop notification from a script or a hook, like notify-send but with nothing extra to install. It talks to whichever notification daemon owns the session bus: the panel's own, or another. Without a session bus it reports that and exits with a failure.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# SUMMARY
: The notification's title.

# BODY
: Optional longer text.

# OPTIONS
-i ICON
: Icon name or path.

-t MILLISECONDS
: How long to show the notification.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# SEE ALSO
dkde-panel(1), dkde-help(1)
