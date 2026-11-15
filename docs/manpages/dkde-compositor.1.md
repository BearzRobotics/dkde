% DKDE-COMPOSITOR(1)
% dkde
% 2026

# NAME
dkde-compositor - DKDE's own Wayland compositor (experimental)

# SYNOPSIS
**dkde-compositor** [**-h** | **--help**] [**-V** | **--version**]

# DESCRIPTION
A Wayland compositor on wlroots, for the DKDE desktop. It is a separate package (**src/compositor**) because the rest of DKDE builds without wlroots. It runs from a TTY on DRM/KMS through seatd, nested in another Wayland session, or headless (**WLR_BACKENDS=headless**). **dkde-session** runs it when **DKDE_COMPOSITOR=dkde-compositor** is set or **~/.config/dkde/session.conf** has a line **compositor=dkde-compositor**.

It serves xdg-shell, layer-shell (the panel, wallpaper, launchers), foreign-toplevel management (the taskbar), ext-workspace, screencopy, output management (**wlr-randr**, Settings > Display), session lock (swaylock, gtklock), idle notification, virtual keyboard and pointer, and Xwayland (X11 programs, started on demand).

Windows float by default; **Alt+T** switches to tiling (one master window on the left, the others stacked on the right) and back. **Alt+left-drag** moves a window, **Alt+right-drag** resizes it from the nearest corner. **Alt+1** to **Alt+9** switch workspace, **Alt+Shift+1** to **9** carry the focused window. The Super key alone opens the Start menu, and the snap and window shortcuts of **dkde-snap** work. The programs of the session (the panel, **dkde-idle**, **dkde-polkit**) are started by the compositor.

# OPTIONS
**-h**, **--help**
: Print help to standard output and exit.

**-V**, **--version**
: Print the version to standard output and exit.

# ENVIRONMENT
**DKDE_COMPOSITOR_CONFIG**
: The settings file, instead of **~/.config/dkde/compositor.toml**.

**DKDE_DEBUG**
: Log at debug level.

**DKDE_NO_AUTOSTART**
: Start no session programs.

**DKDE_NO_XWAYLAND**
: Do not offer Xwayland.

The usual **WLR_BACKENDS**, **WLR_RENDERER** and **XKB_DEFAULT_*** variables apply. Variables in **~/.config/labwc/environment** are read too.

# FILES
**~/.config/dkde/compositor.toml**
: Settings; every key is optional and a wrong value is reported and replaced by its default. **kill -HUP** reads it again.

    [windows]
    layout = "floating"       # or "tiling"
    gap = 6
    master_ratio = 0.55

    [workspaces]
    count = 4                 # 1 to 9

    [input]
    layout = "us"             # xkb layout, variant, options
    repeat_rate = 25
    natural_scrolling = false
    tap_to_click = true
    pointer_speed = 0.0       # -1 to 1

    [keys]
    "W-Return" = "exec dkde-term"
    "A-Tab" = "none"          # removes a built-in shortcut

: Keys are modifiers (**S**, **C**, **A**, **W** for Super) joined with **-** and an xkb key name: **C-A-t**, **W-Left**, **Print**. A bare **Super_L** fires when tapped. Actions: **exec** COMMAND, **quit**, **close**, **next-window**, **prev-window**, **maximize**, **fullscreen**, **float**, **toggle-layout**, **workspace** N, **workspace-prev**, **workspace-next**, **move-to-workspace** N, **move-to-prev**, **move-to-next**, **snap** REGION, **none**.

**~/.config/dkde/autostart**
: A shell script that replaces the built-in session programs.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised. Other nonzero values mean the compositor could not start; the reason is on standard error.

# SEE ALSO
dkde-session(1), dkde-panel(1), dkde-snap(1), dkde-settings(1)
