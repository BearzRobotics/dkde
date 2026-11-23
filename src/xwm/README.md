# dkde-wm

DKDE's X11 window manager (experimental). Plain XCB, no compositing, no window frames (DKDE programs draw their own title bars). ICCCM basics and EWMH (supporting-WM check, client lists, active window, desktops, work area, window state and type, struts).

Shares layout, shortcuts and settings with `dkde-compositor` through `../compositor/src/shared.zig`, so `~/.config/dkde/compositor.toml` configures both: `[windows]` (layout, gap, focus, `placement`, `snap-windows`, `inactive-opacity`), `[workspaces]`, `[keys]`, `[[rules]]`, `[gestures]` and the non-visual `[effects]` keys.

```
zig build         # needs libxcb, libxcb-randr, libxkbcommon, cairo and pango development files
zig build --prefix /usr   # also installs the xsessions entry (share/xsessions/dkde-x11.desktop)
# without libxcb-randr0-dev installed: -Dxcb-randr-prefix=DIR (DIR/include, DIR/lib)
zig build test
Xvfb :77 & DISPLAY=:77 zig-out/bin/dkde-wm &
```

Start a whole session with `dkde-session --x11`. Manual: `docs/manpages/dkde-wm.1.md`. Status and open items: `ai/COMPOSITOR-SURVEY.md`.

Monitors (RandR): each has its own work area (panels reduce only the monitor they stand on), new windows open where the pointer is, tiling, maximize, fullscreen and snap work per monitor, a dragged window changes monitor. Windows that draw their own frame (GTK) are left alone; the rest get a frame with a title bar (title, minimize, maximize, close) and resize edges, drawn with cairo and pango (`src/frame.zig`) in the accent colour, dark mode and font of `~/.config/dkde/dkde.toml` (`src/look.zig`), live. WM_NORMAL_HINTS minimum and maximum sizes are honoured (a fixed-size window floats). `[windows] focus = "follow"` makes focus follow the mouse.

Parity with the compositor for what needs no compositing: `[[rules]]` (WM_CLASS instance or class, and the title; floating, workspace, sticky, above, below, maximized, fullscreen, opacity, position, size), `placement` (cascade, center, smart, pointer), `snap-windows` (edge magnetism while dragging), the actions `put`, `sticky`, `above`, `below`, `show-desktop`, `opacity-up/down`, `group`, `next-tab`, `prev-tab` (tab groups with a coloured strip made of small windows of ours), mouse gestures (Super + right button, `[effects] gestures`, `[gestures]`) and window opacity as `_NET_WM_WINDOW_OPACITY` (`inactive-opacity`, `trailfocus`, `opacify`, rules; applied by a compositing manager such as picom). Checked under Xvfb with xdotool and xprop.

The visual effects (Scale, Expo, switcher previews, animations, filters, zoom, lens, wobbly, blur, cube, snow, water, fire, paint, shelf) need something that composes the screen, which dkde-wm does not; those actions do nothing and say so once in the log. An X11 compositing manager of our own is the way to add them (see `ai/COMPOSITOR-SPEC.md`).

Not done: multi-monitor testing on real hardware (only a unit test and a single screen), per-monitor workspaces.
