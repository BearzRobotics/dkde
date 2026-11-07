# NAME
dkde-pointer - move and click the pointer on a Wayland compositor (a test tool)

# SYNOPSIS
dkde-pointer [-h | --help] [-V | --version]

dkde-pointer [--size WxH] [move X Y | click BUTTON | scroll N | tap KEY | sleep MS]...

# DESCRIPTION
dkde-pointer is a development aid. It drives the pointer through wlr-virtual-pointer, so that hover, click and scroll behaviour can be tested without hands. It is not part of the desktop. The actions run in order.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
move X Y
: Move the pointer to X, Y.

click BUTTON
: Click a pointer button.

scroll N
: Scroll by N steps.

tap KEY
: Press and release a key through zwp_virtual_keyboard.

sleep MS
: Wait MS milliseconds.

# OPTIONS
--size WxH
: The size of the output the coordinates refer to.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# SEE ALSO
dkde-snip(1), dkde-help(1)
