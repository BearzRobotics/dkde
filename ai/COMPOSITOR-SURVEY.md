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
