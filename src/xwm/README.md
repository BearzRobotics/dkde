# dkde-wm

DKDE's X11 window manager (experimental). Plain XCB, no compositing, no window frames (DKDE programs draw their own title bars). ICCCM basics and EWMH (supporting-WM check, client lists, active window, desktops, work area, window state and type, struts).

Shares layout, shortcuts and settings with `dkde-compositor` through `../compositor/src/shared.zig`, so `~/.config/dkde/compositor.toml` configures both: `[windows]`, `[workspaces]`, `[keys]`.

```
zig build         # needs libxcb, libxcb-randr, libxkbcommon, cairo and pango development files
zig build --prefix /usr   # also installs the xsessions entry (share/xsessions/dkde-x11.desktop)
# without libxcb-randr0-dev installed: -Dxcb-randr-prefix=DIR (DIR/include, DIR/lib)
zig build test
Xvfb :77 & DISPLAY=:77 zig-out/bin/dkde-wm &
```

Start a whole session with `dkde-session --x11`. Manual: `docs/manpages/dkde-wm.1.md`. Status and open items: `ai/COMPOSITOR-SURVEY.md`.

Monitors (RandR): each has its own work area (panels reduce only the monitor they stand on), new windows open where the pointer is, tiling, maximize, fullscreen and snap work per monitor, a dragged window changes monitor. Windows that draw their own frame (GTK) are left alone; the rest get a frame with a title bar (title, minimize, maximize, close) and resize edges, drawn with cairo and pango (`src/frame.zig`). WM_NORMAL_HINTS minimum and maximum sizes are honoured (a fixed-size window floats). `[windows] focus = "follow"` makes focus follow the mouse.

Not done: multi-monitor testing on real hardware (only a unit test and a single screen), per-monitor workspaces.
