# NAME
dkde-polkit-ui - authentication dialog for dkde-polkit

# SYNOPSIS
dkde-polkit-ui [-h | --help] [-V | --version]

dkde-polkit-ui --message TEXT [--icon NAME] [--program PATH] --uid N [--uid N...]

# DESCRIPTION
dkde-polkit-ui is the dialog of the Polkit agent. dkde-polkit starts one for each request and waits for it. It is not run by hand. The authentication cookie is read from standard input; it is never given on the command line.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--message TEXT
: The explanation shown to the user.

--icon NAME
: Icon to show.

--program PATH
: The program that asked.

--uid N
: A user that may authenticate. Repeatable.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# SEE ALSO
dkde-polkit(1), dkde-help(1)
