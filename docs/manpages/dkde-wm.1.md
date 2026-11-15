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

# FILES
**~/.config/dkde/compositor.toml**
: Settings: **[windows]**, **[workspaces]**, **[keys]** (see **dkde-compositor**(1)). **[input]** does not apply; X11 input is set with **setxkbmap** and **xinput**.

# LIMITS
No window decorations for programs that draw none. The screen size follows XRandR changes (windows are laid out again and floating windows pulled back onto the screen), but each monitor is not treated separately: the work area is the whole screen. dkde-panel needs a Wayland layer shell, so on X11 it does not run until its X11 backend exists.

# SEE ALSO
**dkde-compositor**(1)
