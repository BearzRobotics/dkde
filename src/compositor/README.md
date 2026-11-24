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
`put POSITION` (top-left, top, top-right, left, center, right, bottom-left, bottom, bottom-right: moves the window there, keeping its size), `sticky` (on every workspace), `above`, `below` (keep the window over or under the others), `show-desktop` (minimize everything, or bring it back), `opacity-up`, `opacity-down`, `snap REGION` (left-half, right-half, top-half, bottom-half, left-third, middle-third, right-third,
left-two-thirds, right-two-thirds, top-left, top-right, bottom-left, bottom-right), `none`.
The built-in set is `src/keys.zig` (`defaults`): dkde's shortcuts (Start menu, terminal, lock, screenshots,
volume, snapping, dkde-snap's regions) plus Super+digit workspaces, Super+T (floating/tiling), Super+Shift+Space
(float one window) and Super+Shift+Escape (quit).

The session programs (panel with restart, dkde-idle, dkde-polkit) are started by the compositor from a built-in
script; `~/.config/dkde/autostart` (a shell script) replaces it. `scripts/dkde-session` runs the compositor named by
`DKDE_COMPOSITOR`, or by a `compositor=` line in `~/.config/dkde/session.conf` (default labwc).

Pointer: Alt+left-drag moves a window, Alt+right-drag resizes it from the nearest corner (a tiled window
becomes floating); title bars drag as usual.

## Window management

```toml
[windows]
placement = "smart"       # where new windows go: cascade (default), center, smart (covers the least), pointer
snap-windows = true       # a dragged window meets the edges of the screen and of other windows
inactive-opacity = 0.85   # dim windows that do not have the focus (1 = off)

[[rules]]                 # per-window rules; later rules override earlier ones
app_id = "mpv"            # globs (* and ?), ignoring case; app_id and/or title
floating = true           # also: workspace = 2, sticky, above, below, maximized, fullscreen,
position = "bottom-right" #   opacity = 0.9, position, x, y, width, height
```

Actions (for `[keys]` and `[gestures]`): everything listed above plus `put POSITION`, `sticky`, `above`, `below`,
`show-desktop`, `opacity-up`, `opacity-down`, `group`, `next-tab`, `prev-tab`, `shelf`, `scale`, `expo`, `zoom-in`,
`zoom-out`, `zoom-reset`, `next-filter`, `show-pointer`, `lens`, `fire`, `paint` and `paint-clear`.

Built-in keys beyond the ones above: Super+D show desktop; Super+Ctrl+Up/Down opacity; Super+G group into tabs and
Super+] / Super+[ next / previous tab; Super+Shift+S shelf; Super+W Scale; Super+E Expo; Super+= / Super+- / Super+0
zoom in / out / reset; Super+Ctrl+F next colour filter; Super+M lens; Super+Shift+F fire; Super+Shift+P paint and
Super+Shift+C wipe it; Super+P find the pointer. Alt+Tab steps through the windows (with previews when `switcher` is on).

## Effects (optional, all off by default)

Each is one key in `[effects]` of compositor.toml, or a switch on the Effects page of Settings, and applies at once.
"GLES" means it needs wlroots' GLES2 renderer (the default on real hardware; with `WLR_RENDERER=pixman` those are off
and the log says so). X11: dkde-wm cannot do the ones that need a compositing manager (see below).

| Key | What it does | Needs |
|---|---|---|
| `animations`, `animation-ms` | Windows fade and grow when opened or restored, shrink when minimized, fade when closed (last picture kept at every commit) | closing: GLES |
| `scale` | Super+W: every window of the workspace at once; click one or press Return; Escape leaves | |
| `expo` | Super+E: every workspace as a tile; click a tile, or drag a window onto another tile | |
| `switcher = "strip"` or `"ring"` | Alt+Tab with window previews; Tab steps, Shift+Tab back, release Alt to go, Escape cancels | |
| `trailfocus` | Windows are the more see-through the further back they are in the focus order | |
| `opacify` | Windows on top of the one the pointer is over turn see-through | |
| `shelf` | Super+Shift+S shrinks the window to a thumbnail at the bottom right; click it to bring it back | |
| `groups` | Super+G groups the window with the one below into tabs (coloured strip above; Super+] / Super+[ switch) | |
| `gestures` | Hold Super, drag with the right button: L R U D (and longer, e.g. `DR`) run actions; `[gestures]` maps them (defaults: L workspace-prev, R workspace-next, U maximize, D show-desktop) | |
| `filter` | Colour filter on the whole screen: negative, grayscale, sepia, high-contrast, protanopia, deuteranopia, tritanopia (the last three simulate the condition) | GLES |
| `zoom` | Super+= / Super+- / Super+0 magnify around the pointer, up to 8x | GLES |
| `lens` | Super+M: a round magnifying lens that follows the pointer | GLES |
| `wobbly` | Windows swing like jelly when dragged, snapped or maximized | GLES |
| `blur` | Translucent windows (opacity < 1) lie on a blurred background (not behind their shadows) | GLES |
| `motion-blur` | A faint trail behind things that move | GLES |
| `cube` | Switching workspaces turns a cube (3 to 9 workspaces), tilted so its top shows, with a floor reflection | GLES |
| `snow`, `water`, `fire`, `paint` | Snow over the desktop; ripples from the pointer; flames at the pointer (Super+Shift+F); drawing on the screen (Super+Shift+P, Escape stops, Super+Shift+C wipes) | GLES |

```toml
[effects]
animations = true
animation-ms = 200        # 50 to 2000
switcher = "ring"
wobbly = true

[gestures]                # optional: a stroke of one to six of L R U D, and an action
"DR" = "close"
"UD" = "exec dkde-term"
```

While something moves, frames are drawn by our own composer: with the GLES renderer `src/gfx.zig` (our shaders over
the scene graph, sharing wlroots' EGL context, rendering into the output's own swapchain and waiting for the GPU
with glFinish), otherwise `src/render.zig` (a wlroots render pass: scale, shift and fade, no shaders). The rest of
the time the normal scene output runs, with damage tracking and direct scanout. Not done: shading a window to its
title bar (windows draw their own title bars), the cube's gears and Atlantis, fire/water as Compiz drew them (ours
are a pointer flame and pointer ripples).

## Source map

`src/main.zig` (the compositor), `layout.zig`, `config.zig`, `keys.zig`, `place.zig` (put, smart placement,
magnetism), `rules.zig`, `anim.zig`, `overview.zig` (Scale and Expo layouts, switcher thumbnails), `wobble.zig`,
`cube.zig`, `filters.zig`, `snow.zig`, `fire.zig`, `gesture.zig` (all pure and unit-tested), `render.zig` and `gfx.zig`
(the composers). `shared.zig` exports the pure ones to dkde-wm and Settings.

## X11 (dkde-wm)

On X11 nothing in dkde-wm composes the screen: `dkde-xcomp` (`src/xcomp`, see its README) is our compositing
manager (Composite redirection, Damage, EGL/GLES2 on the overlay window, the shaders and effect code shared from
this folder). It does window opacity, open and close fades, blur, the cube, colour filters, zoom, lens, water, motion
blur, snow and the pointer finder, and composes only while a setting needs it; Scale, Expo, the switcher previews,
wobbly windows, the shelf, fire and paint are Wayland only. dkde-wm has parity for everything that needs no compositing: `[[rules]]`, `placement`, `snap-windows`, `put`, `sticky`,
`above`, `below`, `show-desktop`, `group` / tabs, `gestures`, and window opacity (`inactive-opacity`, `trailfocus`,
`opacify`, `opacity-up/down` and rule opacity are set as `_NET_WM_WINDOW_OPACITY`, which dkde-xcomp (or picom)
applies) and forwards the zoom, filter, lens and finder keys to dkde-xcomp. Scale, Expo, wobbly, fire, paint and the
shelf do nothing there and dkde-wm says so once in its log.

## Tests

`zig build test` runs the tests of the parts with no wlroots in them (layout, settings, shortcuts, placement, rules,
animation timing, overview and cube geometry, wobble physics, filters, snow, fire, gestures).
Everything else is checked by running it: headless (`WLR_BACKENDS=headless WLR_RENDERER=gles2`, `wtype` for keys,
`grim` for pictures) or in the VM with real pointer input (`qemu/README.md`, `qemu/vm.sh`).
