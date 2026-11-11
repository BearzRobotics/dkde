# NAME
dkde-term - terminal emulator

# SYNOPSIS
dkde-term [-h | --help] [-V | --version]

dkde-term [--dropdown] [-e COMMAND [ARG...]]

# DESCRIPTION
dkde-term is the DKDE terminal emulator. Terminal state is handled by libghostty-vt; text is drawn with Pango. It runs the user's shell, or the command given with **-e**. The terminal core is DKTermCore, an independent library.

Panes work as in Konsole. **Ctrl+Shift+(** (or **Alt+Shift+Plus**) splits the active pane left/right, **Ctrl+Shift+)** (or **Alt+Shift+Minus**) top/bottom; the new pane runs the same profile in the same folder. A split tab shows a title bar on each pane; drag one onto another pane to swap the two. **Ctrl+Shift+E** maximizes the active pane in its tab and brings the others back; **Ctrl+Shift+]** and **Ctrl+Shift+[** grow and shrink it; Panes > Equal Sizes evens them out; **Alt+Shift+arrows** move to the pane on that side. **Ctrl+Shift+W** closes the active pane (the tab when it is the last). A pane whose program ends closes itself, unless the profile says to keep it open. Closing a pane, tab or window in which a program is still running asks first.

Tabs: **Ctrl+Shift+T** opens one in the current folder; the arrow next to it lists the profiles and any toolbox or distrobox containers. Double-click a tab (or **Ctrl+Alt+S**) to rename it; drag it to reorder, onto another dkde-term window, or out of the window into a window of its own (Tabs > Detach Tab). A tab whose bell rings while it is not showing is marked. When started without a command, the tabs, splits and folders of the last session come back.

Text: addresses in the output are underlined under the mouse and open with **Ctrl+click**, as do links programs mark (OSC 8). The right-click menu copies, pastes, opens links and more. **Ctrl+Shift+F** finds text in the scrollback, optionally matching case, whole words or a regular expression, and highlights every match. Files dropped on the terminal are typed as quoted paths. **Ctrl+Shift+A** selects everything, **Ctrl+Shift+K** clears the scrollback, Edit > Reset fixes a terminal a program left in a strange state, and **Ctrl+Shift+S** saves the output (as an HTML page with its colours when the name ends in .html). Edit > Copy as HTML keeps the colours of the selection. **Ctrl+Plus**, **Ctrl+Minus** and **Ctrl+0** zoom.

Pasting text that would run commands by itself (several lines without bracketed paste, sudo, control characters) asks first. View > Read-Only stops typing into a pane. View > Monitor for Activity and Monitor for Silence send a notification when a pane you are not looking at prints or goes quiet; programs can send notifications too (OSC 9, OSC 777).

With shell integration (on by default for bash and zsh) the shell marks its prompts: **Ctrl+Shift+Up** and **Ctrl+Shift+Down** jump between them, and a command that ran 10 seconds or more sends a notification when it ends while you look elsewhere.

Programs can show pictures with the Kitty graphics protocol (as kitten icat, chafa, timg, yazi and ranger do); PNG and raw pixels are accepted. Right-to-left text (Arabic, Hebrew and others) is shown right to left with its letters joined, within the cells it occupies.

**--dropdown** shows or hides the drop-down terminal, which slides down from the top of the screen (bound to **F12** in dkde's labwc settings).

# CONVENTIONS
Bold represents literal commands, options, and keywords.
Italic or uppercase placeholders represent values supplied by the user.
[item] means optional; item... means repeatable; a | b means alternatives.
-- ends option processing: everything after it is an operand, never an option.
Operands are file names or URIs and are never interpreted as shell text.

# OPTIONS
--dropdown
: Show the drop-down terminal, or hide it when it is showing.

-e COMMAND [ARG...]
: Run COMMAND with its arguments instead of the shell. Everything after **-e** belongs to the command and is not examined as an option.

-h, --help
: Print help to standard output and exit.

-V, --version
: Print the version to standard output and exit.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised (the message goes to standard error). Other nonzero values mean the program could not start; the reason is written to standard error.

# FILES
~/.config/dkde/term.toml
: Terminal settings, edited on the Terminal page of dkde-settings. Its [shortcuts] group gives any action another key.

~/.local/state/dkde/term-session
: The tabs of the last session.

$XDG_DATA_DIRS/dkde/term-shell/
: The shell integration for bash and zsh.

$XDG_DATA_DIRS/dkde/style.css
: The stylesheet shared by every DKDE program. Anything in it can be overridden in ~/.config/dkde/style.css.

~/.config/dkde/dkde.toml
: Shared appearance (dark mode, accent colour, font).

# SEE ALSO
dkde-settings(1), dkde-help(1)
