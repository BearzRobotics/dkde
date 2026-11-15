% DKDE-WM(1)
% dkde
% 2026

# NAME
dkde-wm - DKDE's own X11 window manager (experimental)

# SYNOPSIS
**dkde-wm** [**--help**] [**--version**]

# DESCRIPTION
A window manager for X11 (Xorg or XLibre), written against plain XCB, with no compositing. It is a separate package (**src/xwm**) so the rest of DKDE builds without X11 development files. It shares its layout, shortcut and settings code with **dkde-compositor**, so the same **compositor.toml** and the same keys apply.

Windows are not reparented and get no frame: DKDE's programs draw their own title bars. Windows float by default; **Alt+T** switches the workspace to tiling and back. **Alt+left-drag** moves a window and **Alt+right-drag** resizes it from the nearest corner. **Alt+1** to **Alt+9** switch workspace, **Alt+Shift+1** to **9** carry the focused window, **Alt+F4** closes, and **Super+Left/Right/Up/Down** snap.

It speaks ICCCM (delete and take-focus protocols, WM_STATE) and EWMH (supporting-WM check, client lists, active window, desktops, work area, window state and type, struts), so taskbars written for EWMH work.

# OPTIONS
**--help**
: Print help and exit.

**--version**
: Print the version and exit.

# ENVIRONMENT
**DKDE_SESSION_COMPOSITOR**, **DKDE_SESSION_PID**
: Set by dkde-wm for the programs it starts: **dkde-wm** and its process id. **dkde-settings** uses them to find the configuration and to log off (SIGTERM ends the session).

# FILES
**~/.config/dkde/compositor.toml**
: Watched: a change (from dkde-settings or an editor) applies at once, including the desktops, the shortcuts and the keyboard layout (**[input]** layout, variant, options and key repeat, through **setxkbmap** and **xset**). Settings: **[windows]**, **[workspaces]**, **[keys]** (see **dkde-compositor**(1)). **[input]** does not apply; X11 input is set with **setxkbmap** and **xinput**.

# MONITORS AND FRAMES
With RandR each monitor has its own work area (a panel reduces only the monitor it stands on), new windows open on the monitor the pointer is on, and tiling, maximize, fullscreen and snap act per monitor. Dragging a window onto another monitor moves it there. A window that draws its own frame (GTK's client-side decorations, or Motif hints asking for none) is left alone. Any other gets a frame from dkde-wm: a title bar with the window's title and the minimize, maximize and close buttons, and a 4 px edge to resize from. The title bar uses the accent colour from **~/.config/dkde/dkde.toml** while the window has the focus and grey (dark grey with **dark = true**) otherwise, in the interface font; a change of accent, dark mode or font in Settings applies at once. Dragging it dragging it moves the window, a double click maximizes or restores it, and the edges and corners resize. Frames are drawn with cairo and pango. A window's minimum and maximum size (WM_NORMAL_HINTS) are kept, and one that cannot change size floats. **[windows] focus = "follow"** in compositor.toml makes the focus follow the mouse (without raising).

# LOGS
At start, and whenever RandR reports a change, dkde-wm writes the screen size and one line per monitor (size, position, work area) to standard error; under **dkde-session --x11** that is **~/.local/state/dkde/session.log**. Send that file with the output of **xrandr --verbose** when a multi-monitor layout misbehaves.

# LIMITS
The screen follows XRandR changes: windows are laid out again and floating windows pulled back onto their monitor. Workspaces are shared by all monitors. Several monitors are covered by a unit test, not yet by a test on real hardware. dkde-panel needs a Wayland layer shell, so on X11 it does not run until its X11 backend exists.

# SEE ALSO
**dkde-compositor**(1)
