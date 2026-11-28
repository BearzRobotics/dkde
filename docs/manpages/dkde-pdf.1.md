# NAME
dkde-pdf - PDF viewer and annotator

# SYNOPSIS
dkde-pdf [-h | --help] [-V | --version]

dkde-pdf [FILE]

# DESCRIPTION
dkde-pdf shows PDF documents, drawn by pdf-zig, in tabs: open a file in a new tab with **Ctrl+T** and **Ctrl+O**. It zooms, searches (every match is highlighted), selects text with the mouse (double click a word, triple click a line) and copies it with **Ctrl+C**.

The document's bookmarks are in a sidebar (**F9**); you can add bookmarks of your own (**Ctrl+D**) and remove them. Text can be highlighted (**Ctrl+H**), underlined (**Ctrl+U**) or struck out, and notes can be placed on a page (**Ctrl+M**, or the right-click menu). Form fields are tinted; click one to fill it in (text fields open a small editor, check boxes and radio buttons toggle, choice fields show a menu).

Everything you add is written into the PDF as standard annotations, outline entries and field values, as a new revision at the end of the file. Other PDF programs show it, and the original content is never rewritten. **Ctrl+Z** undoes edits until the file is saved; **Ctrl+S** saves it in place and **Ctrl+Shift+S** saves a copy. Closing a tab or the window asks first when there are unsaved changes.

Links: the pointer turns into a hand over a link and a tooltip shows where it goes. A click on a link within the file goes there. A web (**http**, **https**) or email (**mailto**) link is shown in full and opened only if you agree. Nothing else is opened: not **file:** or other addresses, links to other files, or actions that run something; addresses with spaces or non-ASCII characters are refused too. Dragging over a link still selects its text.

Limits: selection works on one page at a time. Filled form fields and text boxes use Helvetica for Western European text. For other characters an installed TrueType font that has all of them is found through fontconfig, and the part of it that is used is embedded in the file. One font must cover the whole of a field or box; **.otf** fonts with CFF outlines, **.ttc** collections and fonts that do not allow it are not used, and when no font fits, the change is refused. Hebrew, Arabic and Indic scripts are stored correctly but may be drawn wrongly (no shaping or right-to-left layout). The field keeps its own font setting, so another program that edits the value later may not have these characters. In a list box with entries no font covers, those entries show as ?. Signature fields are not filled, and XFA forms are not supported. Encrypted files and files whose structure had to be repaired when opened can be read but not edited in place.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
# FILE
: The PDF to open. Without it the program starts with an empty tab.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# OCR
Scanned pages (pages with almost no text of their own) can be made searchable with OCR. It is done by the program **ocrmypdf** (which runs Tesseract), found in the search path; without it dkde-pdf says to install the package ocrmypdf, plus Tesseract language data for the languages wanted. Nothing else in dkde-pdf needs it.

# FILES
$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css. When a program is run from a build or install tree, `<program directory>/../share/dkde` is searched first.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-view(1), dkde-pdfcheck(1), dkde-help(1)
