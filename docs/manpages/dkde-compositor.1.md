% DKDE-COMPOSITOR(1)
% dkde
% 2026

# NAME
dkde-compositor - DKDE's own Wayland compositor

# SYNOPSIS
**dkde-compositor** [**--kiosk** *COMMAND*] [**-h** | **--help**] [**-V** | **--version**]

# DESCRIPTION
A Wayland compositor on wlroots, for the DKDE desktop. It is a package of its own (**src/compositor**), built with the rest of DKDE or alone. It runs from a TTY on DRM/KMS through seatd, nested in another Wayland session, or headless (**WLR_BACKENDS=headless**). It is the compositor **dkde-session** and the login screen run by default; labwc is the backup, used when this is not installed, fails as it starts, or is chosen. Ctrl+Alt+F1 to F12 switch consoles.

It serves xdg-shell, layer-shell (the panel, wallpaper, launchers), foreign-toplevel management (the taskbar), ext-workspace, screencopy, output management (**wlr-randr**, Settings > Display), session lock (swaylock, gtklock), idle notification, virtual keyboard and pointer, and Xwayland (X11 programs, started on demand).

Windows float by default; **Super+T** switches to tiling (one master window on the left, the others stacked on the right) and back. **Alt+left-drag** moves a window, **Alt+right-drag** resizes it from the nearest corner. **Super+1** to **Super+9** switch workspace, **Super+Shift+1** to **9** carry the focused window. The Super key alone opens the Start menu, and the snap and window shortcuts of **dkde-snap** work. The programs of the session (the panel, **dkde-idle**, **dkde-polkit**) are started by the compositor.

Beyond the basics it manages windows with per-program rules, smart placement and edge magnetism, **put** (corner, edge or centre), sticky, above and below, show-desktop, per-window opacity, tab groups, a shelf for small thumbnails, and mouse gestures. Optional desktop effects, all off until switched on (Settings > Effects or **[effects]**), include window animations, Scale and Expo overviews, an Alt+Tab switcher with previews (strip or ring), and, with wlroots' GLES2 renderer, colour filters, a screen magnifier and lens, wobbly windows, blur, a desktop cube, motion blur, snow, water, fire and drawing on the screen. See **EFFECTS** below.

dkde-compositor watches **~/.config/dkde/compositor.toml** and applies a change at once (SIGHUP reloads it too). SIGTERM ends the session. It sets **DKDE_SESSION_COMPOSITOR=dkde-compositor** and **DKDE_SESSION_PID** for the programs it starts, so **dkde-settings** edits this file (shortcuts, desktops, keyboard, touchpad) and Log Off can end the session.

# OPTIONS
**--kiosk** *COMMAND*
: For a login screen: start only *COMMAND*, with no shortcuts (the settings add none either), no X11 programs and no moving windows with Alt. Console switching still works. *COMMAND* ends the compositor with **kill "$DKDE_SESSION_PID"**.

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

The effects marked GLES need **WLR_RENDERER=gles2** (the default on real hardware); with **pixman** they switch themselves off and the log says so. The usual **WLR_BACKENDS**, **WLR_RENDERER** and **XKB_DEFAULT_*** variables apply. Variables in **~/.config/labwc/environment** are read too.

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

    placement = "smart"       # in [windows]: cascade, center, smart or pointer
    snap-windows = true       # in [windows]: dragged windows meet other windows' edges
    inactive-opacity = 0.85   # in [windows]: dim windows without the focus (1 = off)

    [keys]
    "W-Return" = "exec dkde-term"
    "A-Tab" = "none"          # removes a built-in shortcut

    [[rules]]                 # per-window rules, later ones override earlier ones
    app_id = "mpv"            # globs (* ?), ignoring case; app_id and/or title
    floating = true           # also workspace = 2, sticky, above, below, maximized, fullscreen,
    position = "bottom-right" #   opacity = 0.9, position, x, y, width, height

    [effects]                 # all off by default, see EFFECTS
    animations = true
    switcher = "ring"

    [gestures]                # a stroke of one to six of L R U D, and an action
    "DR" = "close"

: Keys are modifiers (**S**, **C**, **A**, **W** for Super) joined with **-** and an xkb key name: **C-A-t**, **W-Left**, **Print**. A bare **Super_L** fires when tapped. Actions: **exec** COMMAND, **quit**, **close**, **next-window**, **prev-window**, **maximize**, **fullscreen**, **float**, **toggle-layout**, **workspace** N, **workspace-prev**, **workspace-next**, **move-to-workspace** N, **move-to-prev**, **move-to-next**, **snap** REGION, **put** POSITION (top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right), **sticky**, **above**, **below**, **show-desktop**, **opacity-up**, **opacity-down**, **group**, **next-tab**, **prev-tab**, **shelf**, **scale**, **expo**, **zoom-in**, **zoom-out**, **zoom-reset**, **next-filter**, **show-pointer**, **lens**, **fire**, **paint**, **paint-clear**, **none**.

**~/.config/dkde/autostart**
: A shell script that replaces the built-in session programs.

# EFFECTS
Each is a key in **[effects]** (true or false unless noted) and a switch in Settings > Effects. GLES: needs the GLES2 renderer.

**animations**, **animation-ms**
: Windows fade and grow when opened or restored, shrink when minimized, and fade when closed (GLES). 50 to 2000 ms.

**scale**, **expo**
: Super+W shows every window of the workspace at once (click one or press Return, Escape leaves); Super+E shows every workspace as a tile (click a tile, or drag a window onto another tile).

**switcher** = "strip" or "ring"
: Alt+Tab shows window previews; Tab steps, Shift+Tab goes back, letting go of Alt goes to the window in front, Escape cancels.

**trailfocus**, **opacify**
: Windows further back in the focus order are more see-through; windows on top of the one the pointer is over turn see-through.

**shelf**, **groups**, **gestures**
: Super+Shift+S shrinks the window to a thumbnail at the bottom right (click it to bring it back). Super+G groups a window with the one below it into tabs (Super+] and Super+[ switch, Super+G again leaves). Holding Super and dragging with the right button draws a gesture; the defaults are L workspace-prev, R workspace-next, U maximize, D show-desktop, and **[gestures]** adds more.

**filter**, **zoom**, **lens**, **wobbly**, **blur**, **motion-blur**, **cube** (GLES)
: A whole-screen colour filter (negative, grayscale, sepia, high-contrast, protanopia, deuteranopia, tritanopia; Super+Ctrl+F steps through them); Super+= / Super+- / Super+0 magnify around the pointer; Super+M a magnifying lens; windows swing like jelly when dragged, snapped or maximized; translucent windows lie on a blurred background; a faint trail behind moving things; switching workspaces turns a cube (three to nine workspaces).

**snow**, **water**, **fire**, **paint** (GLES)
: Snow over the desktop; ripples from the pointer; Super+Shift+F flames at the pointer; Super+Shift+P draws on the screen (Escape stops, Super+Shift+C wipes). Super+P draws a ring around the pointer to find it.

# EXIT STATUS
0 on a normal exit. 2 when an option is not recognised. Other nonzero values mean the compositor could not start; the reason is on standard error.

# SEE ALSO
dkde-session(1), dkde-panel(1), dkde-snap(1), dkde-settings(1)
