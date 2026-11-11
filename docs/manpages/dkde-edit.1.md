# NAME
dkde-edit - text editor

# SYNOPSIS
dkde-edit [-h | --help] [-V | --version]

dkde-edit [FILE...]

# DESCRIPTION
dkde-edit is a text editor. It starts as simple as Notepad and offers what gedit, GNOME Text Editor and Kate do when it is wanted. Each FILE opens in a tab; without an operand the tabs of the last session come back (see **restore-session**).

Files keep their format: text in UTF-8, UTF-16 (with a byte-order mark), Windows-1252 or ISO-8859-1, with Unix, Windows or classic Mac line endings, is saved back the same way unless it is changed in the status bar. Saving keeps the file's permissions and writes through a symbolic link to its target. A file that is read-only, or that you may not change, is not replaced: dkde-edit offers Save As or **Save as Administrator** (your password, through sudo). When another program changes or deletes an open file, a bar above the text offers to reload it.

When GtkSourceView 5 is installed (the library gedit and GNOME Text Editor use) the editor also shows line numbers, syntax colours for some 180 languages, matching brackets, the current line, a right margin, spaces and tabs, and an overview map, and it indents automatically, completes words from the text and prints with colours. With libspelling it checks spelling as you type (Tools > Check Spelling). Without them it is a plain editor.

Find (**Ctrl+F**) and Find and Replace (**Ctrl+H**) highlight every match and count them, optionally matching case, whole words or a regular expression (replacements may use \\1). **Ctrl+Shift+F** searches every file in a folder (with grep). **Ctrl+I** or **Ctrl+L** goes to a line ("120" or "120:8").

Line commands: duplicate (**Ctrl+Shift+D**), delete (**Ctrl+Shift+K**), move up or down (**Alt+Up**, **Alt+Down**), comment or uncomment (**Ctrl+/**), indent (**Ctrl+]**, **Ctrl+[**), join (**Ctrl+J**), sort, and change case. **Ctrl+Alt+Up** and **Ctrl+Alt+Down** add cursors above and below, and **Alt+click** adds one anywhere; typing, deleting and pasting then happen at every cursor until **Escape**.

**F9** shows a folder tree beside the text. View > Split View shows the file twice. **Ctrl+`** shows a terminal below the text (the same terminal as dkde-term), started in the folder of the open file. **Ctrl+PageUp** and **Ctrl+PageDown** switch tabs. Files can be dropped on the window to open them, and File > Open Recent lists the ones opened lately; each opens where its cursor was left.

Unsaved text is kept in a draft every few seconds, so after a crash it comes back on the next start.

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPERANDS
FILE...
: Files to open.

# OPTIONS
-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/edit.toml
: Editor settings (every key and its default are in the system's copy of edit.toml).

~/.local/state/dkde/edit-session, ~/.local/state/dkde/edit-drafts/
: The open tabs and their unsaved text.

~/.local/state/dkde/edit-places
: Where the cursor was in each file.

# ENVIRONMENT
DKDE_EDIT_PLAIN
: When set, GtkSourceView is not used even if it is installed.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-files(1), dkde-help(1)
