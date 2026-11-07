# NAME
dkde-polkit - Polkit authentication agent

# SYNOPSIS
dkde-polkit [-h | --help] [-V | --version]

dkde-polkit [--process-subject]

# DESCRIPTION
dkde-polkit is a Polkit authentication agent. When a program that Polkit guards (GParted, udisks, **pkexec**) needs the user to prove who they are, polkitd calls the agent registered for the login session. This program is that agent. It speaks only D-Bus and so uses little memory while idle; for each request it starts dkde-polkit-ui and passes the answer to Polkit. It does not check passwords itself and keeps none (DKDE-066). If the system bus or the Polkit authority is missing it says so and exits; the desktop keeps working and privileged actions are refused.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--process-subject
: Register for the process rather than for the login session.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# SEE ALSO
dkde-polkit-ui(1), dkde-help(1)
