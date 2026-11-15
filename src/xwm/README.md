# dkde-wm

DKDE's X11 window manager (experimental). Plain XCB, no compositing, no window frames (DKDE programs draw their own title bars). ICCCM basics and EWMH (supporting-WM check, client lists, active window, desktops, work area, window state and type, struts).

Shares layout, shortcuts and settings with `dkde-compositor` through `../compositor/src/shared.zig`, so `~/.config/dkde/compositor.toml` configures both: `[windows]`, `[workspaces]`, `[keys]`.

```
zig build         # needs libxcb and libxkbcommon development files
zig build test
Xvfb :77 & DISPLAY=:77 zig-out/bin/dkde-wm &
```

Start a whole session with `dkde-session --x11`. Manual: `docs/manpages/dkde-wm.1.md`. Status and open items: `ai/COMPOSITOR-SURVEY.md`.

Not done: XRandR, frames for programs without decorations, WM_NORMAL_HINTS, focus-follows-mouse.
