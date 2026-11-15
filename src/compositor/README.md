# dkde-compositor

DKDE's own Wayland compositor (experimental; see `ai/COMPOSITOR-SPEC.md` and `ai/COMPOSITOR-SURVEY.md`).
Written in Zig on wlroots through Zig's C interop. A standalone package: `zig build` in this folder
(needs the wlroots `-dev` files, `wayland-scanner`, `wayland-protocols`). For the dkbuild image (musl,
wlroots 0.20) see `qemu/README.md`.

Run it nested in another Wayland session, headless (`WLR_BACKENDS=headless`) or from a TTY on DRM/KMS through
seatd. `DKDE_DEBUG=1` logs at debug level; `kill -HUP` re-reads the settings.

## What it serves

xdg-shell (windows, popups), xdg-decoration (always client-side), layer-shell (panels, wallpaper,
launchers; exclusive zones keep windows clear), wlr-foreign-toplevel-management (the taskbar),
ext-workspace-v1 (virtual desktops), wlr-screencopy (screenshots), wlr-output-management (wlr-randr,
Settings > Display, screen off), ext-session-lock (swaylock, gtklock: a lock client that dies leaves the screen
locked), ext-idle-notify, wlr virtual keyboard and pointer, cursor-shape, primary selection, viewporter, fractional-scale, xdg-output, and Xwayland (X11 programs run beside Wayland ones; it starts when the first one connects; `DKDE_NO_XWAYLAND=1` turns it off).

## Settings: `~/.config/dkde/compositor.toml`

All keys optional; a bad value is logged and replaced by its default.

```toml
[windows]
layout = "floating"      # or "tiling"
gap = 6                  # pixels around and between tiled windows
master_ratio = 0.55      # the master window's share of the width when tiling

[workspaces]
count = 4                # 1 to 9

[input]                  # all optional
layout = "us"            # xkb layout / variant / options; else XKB_DEFAULT_*, then ~/.config/labwc/environment
options = "ctrl:nocaps"
repeat_rate = 25
repeat_delay = 600
natural_scrolling = false
tap_to_click = true
pointer_speed = 0.0      # -1 to 1

[keys]                   # added to the built-in shortcuts; "none" removes one
"W-Return" = "exec dkde-term"
"A-Tab" = "none"
```

Keys are written like labwc's: modifiers `S` `C` `A` `W` (Super) joined with `-`, then an xkb key name
(`C-A-t`, `W-Left`, `Print`). A bare `Super_L` fires when tapped. Actions: `exec COMMAND`, `quit`, `close`,
`next-window`, `prev-window`, `maximize`, `fullscreen`, `float`, `toggle-layout`, `workspace N`,
`workspace-prev`, `workspace-next`, `move-to-workspace N`, `move-to-prev`, `move-to-next`,
`snap REGION` (left-half, right-half, top-half, bottom-half, left-third, middle-third, right-third,
left-two-thirds, right-two-thirds, top-left, top-right, bottom-left, bottom-right), `none`.
The built-in set is `src/keys.zig` (`defaults`): dkde's shortcuts (Start menu, terminal, lock, screenshots,
volume, snapping, dkde-snap's regions) plus Alt+digit workspaces, Alt+T (floating/tiling), Alt+Shift+Space
(float one window) and Alt+Esc (quit).

The session programs (panel with restart, dkde-idle, dkde-polkit) are started by the compositor from a built-in
script; `~/.config/dkde/autostart` (a shell script) replaces it. `scripts/dkde-session` runs the compositor named by
`DKDE_COMPOSITOR`, or by a `compositor=` line in `~/.config/dkde/session.conf` (default labwc).

Pointer: Alt+left-drag moves a window, Alt+right-drag resizes it from the nearest corner (a tiled window
becomes floating); title bars drag as usual.

## Tests

`zig build test` runs the tests of the parts with no wlroots in them (layout, settings, shortcuts).
Everything else is checked by running it: see `qemu/README.md` and `qemu/vm.sh`.
