% DKDE-XCOMP(1)
% dkde
% 2026

# NAME
dkde-xcomp - DKDE's X11 compositing manager (experimental)

# SYNOPSIS
**dkde-xcomp** [**--help**] [**--version**]

# DESCRIPTION
A compositing manager for X11, written against plain XCB with EGL and GLES2 for the drawing. It runs next to a window manager (**dkde-wm**(1), or any that sets _NET_WM_WINDOW_OPACITY and the EWMH desktop properties) and gives X11 the optional effects that **dkde-compositor**(1) has on Wayland. It is a separate package (**src/xcomp**) so the rest of DKDE builds without X11 development files. **dkde-session --x11** starts it after dkde-wm.

It composes only while a setting needs it: **[effects]** animations, blur, cube, snow, zoom, lens, water, motion-blur, trailfocus or opacify, a **filter** other than none, **[windows] inactive-opacity** below 1, or a **[[rules]]** opacity. With none of those it only waits, and the X server draws the windows as usual. Turning the last one off stops it composing. A filter, zoom, lens or the pointer finder started with a key keeps it composing while they are on.

What it does: window opacity (_NET_WM_WINDOW_OPACITY), fades and growing when windows open and close (**animations**, **animation-ms**), blur behind see-through windows (**blur**), the desktop cube when switching workspace (**cube**), a colour filter (**filter**), the screen magnifier (**zoom**), the lens (**lens**), water ripples (**water**), motion blur (**motion-blur**), snow (**snow**) and the pointer finder. The keys are dkde-wm's, which sends the action to dkde-xcomp: **Super+=**, **Super+-**, **Super+0**, **Super+Ctrl+F**, **Super+P** and **Super+M**. Scale, Expo, the Alt+Tab previews, wobbly windows, the shelf, fire and painting are only in the Wayland compositor.

# OPTIONS
**--help**
: Print help and exit.

**--version**
: Print the version and exit.

# FILES
**~/.config/dkde/compositor.toml**
: The same file as dkde-compositor and dkde-wm read, watched: a change applies at once. The **[effects]** and **[windows]** keys are described in **dkde-compositor**(1).

# NOTES
Window pictures are fetched with GetImage when the Damage extension reports a change, so it works with any X server (Xvfb, software GL included); on a real GPU a texture-from-pixmap path would be faster and is not written yet. It needs the Composite extension (0.2 or later), Damage, XFixes and an EGL with the XCB platform (Mesa has it). It does not handle changes of the screen size while composing. Only one compositing manager can run: it takes the **_NET_WM_CM_S0** selection and says so when another one has it.

# SEE ALSO
**dkde-wm**(1), **dkde-compositor**(1), **dkde-settings**(1)
