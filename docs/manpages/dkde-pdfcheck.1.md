# NAME
dkde-pdfcheck - draw PDFs without a display and report what was not drawn

# SYNOPSIS
dkde-pdfcheck [-h | --help] [-V | --version]

dkde-pdfcheck [OPTIONS] PATH...

# DESCRIPTION
dkde-pdfcheck draws every page of many PDF files with the DKDE renderer and reports what it could not draw, so that a large collection can be used to find gaps. It needs no display and is a developer tool. Run **dkde-pdfcheck --help** for the options of the installed version.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
PATH...
: PDF files, or directories searched for them.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# SEE ALSO
dkde-pdf(1), dkde-help(1)
