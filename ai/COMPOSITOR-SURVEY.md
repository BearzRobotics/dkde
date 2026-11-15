# Compositor dependency survey (Milestone 0, step 1)

Date: 2026-11-15. Machine: Ubuntu 26.04 (resolute), Zig 0.17.1, labwc 0.9.3 (which links wlroots 0.19.2).

## Installed here

| Piece | State |
|---|---|
| wlroots | **runtime only**: `libwlroots-0.19` 0.19.2; no `-dev` package, so no headers and no `.pc` |
| libwayland-server, wayland-protocols 1.47 | dev installed |
| xkbcommon 1.13.1, pixman, libdrm 2.4.131, gbm, EGL, GLES2, Vulkan headers, libudev | dev installed |
| libinput 1.31.1, libseat 0.9.2 | runtime only |
| XCB | `libxcb`, `xcb-shm` dev; `xcb-ewmh`/`xcb-icccm` runtime only; no randr, composite, damage, xfixes, xinput headers |
| Xwayland 24.1.10, Xorg | installed (Xorg wrapper refuses non-console users, so X11 tests need a nested server such as Xephyr/Xvfb) |
| meson, ninja, wayland-scanner | installed |
| seatd | not installed (the repo has its own `dkde-seatd` wrapper) |

The missing `-dev` packages are all available from the Ubuntu archive (`libwlroots-0.19-dev`, `libinput-dev`, `libseat-dev`, `libxcb-{ewmh,icccm4,randr0,composite0,damage0,xfixes0,xinput}-dev`, `libevdev-dev`, `libmtdev-dev`, `libdisplay-info-dev`, `libliftoff-dev`). Installing them needs root. Without root, `apt-get download` + `dpkg -x` into a scratch sysroot gives the headers and `.pc` files (tried: works; the `.pc` prefixes need rewriting).

## Zig bindings (codeberg.org/ifreund)

| Binding | Latest | Notes |
|---|---|---|
| zig-wlroots | v0.20.3 (needs Zig 0.17.0, wlroots **0.20**); v0.19.4 (declares Zig 0.14.0, wlroots 0.19) | Uses `addTranslateC` on the wlroots headers, so the headers must be present at build time |
| zig-wayland | v0.7.0 | the repo already vendors `wayland-0.7.0-dev` from the ghostty mirror (client side); the scanner also generates server code |
| zig-xkbcommon | v0.5.0 | |
| zig-pixman | v0.4.0 | |

The mismatch to resolve: bindings for the Zig we use (v0.20.x) want wlroots 0.20, while the system has 0.19.2. Options:

1. **Build wlroots 0.20.2 from source** into a scratch prefix (needs the `-dev` headers above; tag `0.20.2` exists on gitlab.freedesktop.org) and use zig-wlroots v0.20.3. Matches the Zig 0.17 era; River (Zig, same author) is the reference.
2. **zig-wlroots v0.19.4 against the system wlroots 0.19.2**: matches the installed library, but its Zig code targets Zig 0.14 and may not compile on 0.17.1 (untested).
3. **No wlroots**: write the compositor core ourselves (DRM/KMS, libinput, libseat, renderer). Largest effort; keeps every dependency small.

## Not yet done

- Compile test of either option (step 1 was blocked before the wlroots source could be fetched).
- X11 side: XCB extension headers via the same scratch-sysroot trick; a nested server (Xephyr or Xvfb) for testing since Xorg refuses us.
- GTK4 client inside a nested compositor (Milestone 0 exit test).

## Result (same day): own C interop works

`src/compositor/` is a standalone Zig package (`cd src/compositor && zig build`) that imports wlroots 0.19.2, libwayland-server and xkbcommon through `b.addTranslateC` (no zig-wlroots). It needs the wlroots `-dev` files and `wayland-scanner` (it generates `xdg-shell-protocol.h`, which wlroots' headers include). Notes from building it on Zig 0.17.1:

- `translate-c` handles wlroots' headers; macros that use `__LINE__` do not translate, so `wlr_log` is called as `_wlr_log`.
- wlroots 0.19's `.pc` requires more `-dev` packages than the obvious ones: `xcb-dri3`, `xcb-present`, `xcb-render-util`, `xcb-shape`, `xcb-res`, `xcb-errors`, `xcb-sync`.
- Zig 0.17 removed `b.args`; pass program arguments on the command line of the built binary.
- wlroots asserts at teardown if a listener is still attached to an object it frees: detach every `wl_listener` before `wlr_cursor_destroy` and friends.

What runs (verified nested in a private labwc, with dkde-calc, dkde-clock and dkde-colour as clients, captured with grim through our own screencopy): xdg-shell windows with focus and raise, popups, pointer and keyboard seat, cascade placement, `Alt+T` floating <-> tiling (master left, others stacked right; restores the floating positions), `Alt+Shift+Space` floats one window out of the tiling, `Alt+Escape` quits. The layout maths is in `layout.zig` (no wlroots; 5 tests) so the X11 window manager can reuse it.

Testing caveat: `wtype` builds its own keymap, so its keycodes do not match a us-layout compositor (`t` arrived as Escape). Use `dkde-pointer chord`, and send a warm-up chord first so the nested seat has a keyboard.

## Settings and layout fixes

- `~/.config/dkde/compositor.toml` (or `DKDE_COMPOSITOR_CONFIG`): `[windows] layout = "floating" | "tiling"`, `gap`, `master_ratio`. Every key is optional; a missing file is fine; a bad value is logged and replaced by its default; bad TOML is logged and the defaults are used. `kill -HUP` re-reads it. Tests in `src/config.zig`.
- wlroots' `wlr_scene_xdg_surface` already shifts the surface by the window geometry, so the tree's position is where the window's content (without CSD shadows) appears. Do not subtract the geometry offset again (a first version did, and tiled windows sat 14 px too far up and left).
- Tiled windows are told they are tiled (`xdg_toplevel.set_tiled`), so GTK draws them square and without shadows.
- Test-harness rule: anything that starts dkde-panel must run under `dbus-run-session` with an empty `XDG_CONFIG_DIRS`, or the panel starts the real session's autostart programs.

## Workspaces (ext-workspace-v1)

wlroots 0.19 has no helper for `ext-workspace-v1`, so `src/workspaces.zig` serves it on libwayland: `build.zig` runs `wayland-scanner server-header` (for the C interop) and `private-code` (the protocol's `wl_interface` tables, compiled with `addCSourceFile`). One group holds N workspaces (`[workspaces] count`, 1 to 9, default 4); a client's `activate` is applied at `commit`. The compositor switches with Alt+1…9 and moves the focused window with Alt+Shift+1…9; windows on other workspaces are hidden (the taskbar still lists them, and activating one switches to its workspace first); tiling lays out only the current workspace. Verified nested with dkde-panel: its workspace indicator follows the switch, a window opened on workspace 2 is not drawn on workspace 1.

## On a real display: QEMU (2026-11-15)

`src/compositor/qemu/README.md` has the procedure. Built for the dkbuild image (musl, wlroots 0.20.2; the only source change from the 0.19 build was musl's opaque `timespec`) and booted in QEMU with KVM: the compositor runs on the DRM/KMS backend through libseat/seatd on virtio-gpu, `dkde-panel` shows the taskbar and workspace indicator, dkde-calc and dkde-term open, and keys sent through QEMU's keyboard (Alt+T tiling, Alt+2 / Alt+1 workspaces) are handled. Not tried there: the pointer, and the greeter login path (the test replaces `labwc` through a wrapper on the live user's PATH).

## State after the first long session (2026-11-15)

Working and checked (nested in labwc, and on DRM/KMS in the QEMU image): windows, popups, focus, Alt+drag move and resize,
title-bar drag, maximize, fullscreen, minimize and raise from the taskbar, floating and tiling with gaps, workspaces,
panel/wallpaper/launcher layer surfaces, shortcuts (including a bare Super tap and dkde-snap's regions), settings and live
reload, output management (wlr-randr), screen lock (swaylock), autostart of the panel, idle and polkit agent, stress (six windows opened
and closed). Not done: the greeter path (dkde-greeter starting our session), a session entry in the greeter's list, installing the
compositor with the other programs (it is a standalone package because the rest of dkde builds without wlroots), Xwayland, input
settings (keyboard layout from Settings, touchpad options), gamma/night light, per-output workspaces, window rules, the X11 window
manager, the shared desktop-integration API from the spec.

## Shared desktop API (Milestone 1) — 2026-11-15
`src/common/desktop.zig` (`common.desktop`) defines the backend-neutral interface: `Capability`/`Capabilities`, `Window` (identity is its pointer; ops table for activate/minimize/maximize/close), `Workspace`, `Output`, capture (`Image`, output and window as separate capabilities), `Backend`/`VTable` and the `Desktop` facade (every query is empty and every request a no-op when the capability is missing; `stepWorkspace` for the wheel). A `Fake` backend covers it in tests. The panel's taskbar and workspace switcher use only this API; `src/panel/backend_wayland.zig` is the Wayland backend (foreign-toplevel + ext-workspace). Verified headless: taskbar lists/removes windows, active highlight, workspace indicator. 
Update (same day): the Wayland backend is now the toolkit-free module `src/wldesktop/` (takes a `wl_display`; parts: windows, workspaces, outputs via wlr-output-management with mode/scale/power changes applied as one configuration, output capture via wlr-screencopy). dkde-snip captures through `Desktop.capture`, dkde-idle switches screens with `configureOutputs` (no more wlr-randr), the panel uses windows + workspaces. Verified headless: snip --full saved a correct PNG; idle turned the output off (wlr-randr confirmed Enabled: no). Not verified: screen back on, mode/scale changes. Still on wlr-randr: Settings > Display. Not behind the API: per-window capture, panel-surface placement. Next: X11 window manager and X11 backend (Milestone 3).

## X11 window manager (Milestone 3, first slice) — 2026-11-15
`src/xwm/` (dkde-wm, own package; core XCB + xkbcommon only; layout/keys/config shared from src/compositor via `src/compositor/src/shared.zig`). Done and verified under Xvfb (xterm, dkde-calc with GDK_BACKEND=x11, xdotool, xprop): map/unmap/destroy management, workspaces (Alt+N, move with Alt+Shift+N, EWMH desktops), floating and tiling (Alt+T), Alt+drag move/resize, click-to-focus, WM_DELETE close, snap regions, maximize/fullscreen/minimize via EWMH messages, struts → work area (unit-tested; no real dock tried), client lists, active window, super-tap action. Not done: XRandR (screen size read once), decorations/frames for legacy apps, normal-hints (min/max size), focus-follows-mouse, session integration (dkde-session starting dkde-wm instead of labwc), an X11 backend for the shared desktop API and for the panel (the panel is layer-shell only), screenshots/outputs on X11.

## X11 backend of the shared API — 2026-11-15
`src/x11desktop/` (`x11desktop.X11.create`): window list from `_NET_CLIENT_LIST` (skips skip-taskbar), titles, WM_CLASS as app id, hidden/maximized/fullscreen/desktop state, active window, desktops and names; requests are EWMH client messages (activate, close, maximize, iconify, switch desktop); root-window capture for screenshots; watched from the GLib loop; works with any EWMH window manager. The panel chooses it when GDK is not on Wayland. Verified against Xvfb + dkde-wm with `DKDE_X11_TEST=1 zig build test -Dapp=panel` (list, workspace switch + change callback, minimize/restore, capture, close). Not done: outputs/XRandR, per-window capture, the panel's own surface on X11 (it uses gtk4-layer-shell: needs a dock-type window with struts instead).

## Panel on X11 — 2026-11-15
`src/panel/surface.zig` now picks `x11_surface.zig` when GDK is on X11: bars are dock windows spanning their monitor edge with `_NET_WM_STRUT_PARTIAL` (work area shrinks; exclusive-zone changes update it), the wallpaper a desktop window, the Start menu a dialog placed beside the bar (no transparent overlay; closes when it loses focus; asks for skip-taskbar and above after mapping because GTK rewrites `_NET_WM_STATE`), pop-ups (volume, notifications) notification-type windows placed by their anchors. Placement uses our own XCB connection (GTK 4 cannot move windows). dkde-wm gained skip-taskbar/above state. Verified under Xvfb + dkde-wm: panel with taskbar entry for dkde-calc, work area 1280x680, Start menu opens beside the bar and closes with Escape/focus loss. Not verified: vertical or top bars, multi-monitor offsets, autohide, OSD and toast placement, panel on a non-dkde EWMH window manager.

## X11 session — 2026-11-15
`dkde-session --x11` (or `DKDE_SESSION_TYPE=x11`, or `type=x11` in ~/.config/dkde/session.conf): without DISPLAY it runs `startx dkde-session --x11`; inside X it starts dkde-wm, then the panel (restarted when it exits), display.sh and dkde-polkit under dbus-run-session; `~/.config/dkde/autostart` replaces the set; dkde-idle is not started (Wayland protocol; X11 idle/lock is not done). `data/dkde-x11.desktop` is the xsessions entry (not installed by the main build, since dkde-wm is not part of it). Verified under Xvfb: the script started dkde-wm and the panel (work area 1280x680), logs went to session.log. Not verified: startx from a tty, a login manager's xsession, lock/idle on X11.

## dkde-wm follows XRandR — 2026-11-15
dkde-wm selects RandR screen-change events (one hand-written request and one event, via xcbext.h; no RandR headers) and, when the root size changes, re-reads it, resizes desktop windows, pulls floating windows back onto the screen, republishes `_NET_DESKTOP_GEOMETRY` and lays out again. Verified under Xvfb (1280x720 → 1000x600: work area, a floating window clamped, tiling fitted). Not done: per-monitor work areas and placement, XRandR outputs in the shared API (so Settings > Display on X11), X11 idle/lock.
