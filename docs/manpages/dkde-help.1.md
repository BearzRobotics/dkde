# NAME
dkde-help - view DKDE documentation and the system's manual pages

# SYNOPSIS
dkde-help [-h | --help] [-V | --version]

dkde-help [[SECTION] NAME | FILE]

# DESCRIPTION
dkde-help is the DKDE help viewer. It lists DKDE's own documents and every manual page it finds on the system in one searchable list, and shows the selected page in a tab. It works without a network connection and without dkde-panel running.

Three kinds of source are read: Markdown files (`.md`, with GitHub-flavoured tables, task lists and footnotes), man(7) pages and mdoc(7) pages. Pages may be gzip-compressed. A page that only redirects with `.so` is followed. Anything else is shown as plain text. The format is decided from the file name and the first macro line, not from the directory.

Finding, reading and parsing pages is done by the dkman library; Markdown is parsed by md-zig and roff by gtroff-zig. The same page therefore reads the same in dkde-help and in the dkman command.

The window has a search box and page list on the left and the pages on the right. The list is in groups that open and close (click a group), arranged in one of four ways, chosen under the search box:

- **By Topic** (the default): DKDE Applications, DKDE Desktop and System, DKDE Guides, then the system's pages by what their manual section holds (User Commands, System Calls, Library Functions, Devices and Special Files, File Formats and Configuration, Games, Overviews, Conventions and Miscellany, System Administration, Kernel Routines …).
- **By Section**: every page, DKDE's included, under its manual section.
- **By Folder**: under the folder the pages are installed in (DKDE's help folder, /usr/share/man, /usr/local/share/man …).
- **A to Z**: by first letter.

Each group shows how many pages it holds. Typing in the search box lists the pages whose name contains the text (ignoring case), without groups; Enter opens the first match; clearing the box brings the groups back.

Tables are laid out in columns in a fixed-width font, the header in bold; a table wider than the window scrolls sideways.

Several pages can be open at once in tabs. Clicking a page in the list shows it in the current tab. Double-clicking a page, or pressing Enter on it, opens it in a new tab. The tab bar appears when there is more than one tab. Closing the last tab leaves an empty one.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional.
Section numbers are those of man(1): 1 commands, 3 library functions, 5 file formats, 8 administration; a suffix such as 3p is part of the section.

# OPERANDS
# NAME
: Open the first page with this name, as man(1) would pick it.

# SECTION NAME
: Open the page NAME in SECTION.

# FILE
: Open this file. An operand that contains a slash, or names an existing file, is a file.

If nothing matches, the window opens with a message saying so.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# KEYBOARD
Ctrl+T
: Open a new, empty tab.

Ctrl+W
: Close the current tab.

# ENVIRONMENT
# MANPATH
: Colon-separated manual directories to search. An empty entry stands for the defaults: /usr/local/man, /usr/local/share/man, /usr/share/man and /usr/man. Unset means the defaults.

DKDE_HELP_DIR
: Directory holding DKDE's own documents. Used when running from the source tree; normally unset.

# FILES
share/dkde/help/*.md
: DKDE's own documents, found in the first of `$XDG_DATA_DIRS` that has them. Files named like `dkde-calc.1.md` are shown as the page `dkde-calc` in section 1.

# EXIT STATUS
0 on a normal exit. 2 for an unknown option.

# LIMITATIONS
Links in Markdown documents are shown underlined but cannot be followed yet. Only the page name is searched, not the page text.

# SEE ALSO
dkman(1), man(1)
