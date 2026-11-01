# Packaging dkde (and building the dkrescue image)

dkde is a set of ordinary programs plus a few session files. This page is what
a package or an image build needs: where the source comes from, what to build
it with, what has to be installed alongside it, and a first-boot checklist.

Status: built and tested on glibc (Ubuntu 26.04). **Not yet built or booted
on dkrescue (musl, dinit).** Items marked *unverified* below are exactly that.

## 1. The source

Each GitHub release carries:

| File | What |
|---|---|
| `dkde-vX.Y.Z.tar.gz` | the source **and the Zig dependencies** (`zig-pkg/`, about 150 MB unpacked), so it builds with no network |
| `dkde-vX.Y.Z.tar.gz.sha256` | checksum |

The tarball unpacks to `dkde-vX.Y.Z/`. (GitHub's automatic `vX.Y.Z.tar.gz`
archive has the source only; it needs the network at build time.)

Make one yourself from a clean checkout with `scripts/make-source-tarball.sh`.

## 2. Build-time requirements

| What | Version | pkg-config module / command | Ubuntu package |
|---|---|---|---|
| Zig | **0.17.0 exactly** | `zig version` | (not in apt; from ziglang.org or `zvm`) |
| GTK 4 and its chain (GLib, GIO, Pango, Cairo, HarfBuzz, gdk-pixbuf, Graphene) | 4.12 or newer *(unverified lower bound)* | `gtk4` | `libgtk-4-dev` |
| gtk4-layer-shell | any | `gtk4-layer-shell-0` | `libgtk4-layer-shell-dev` |
| Wayland client library | any | `wayland-client` | `libwayland-dev` |
| wayland-protocols | any | | `wayland-protocols` |
| pkg-config | any | | `pkg-config` |
| C compiler / libc headers | for linking only | | `build-essential` (dkrescue: LLVM/Clang) |

Optional build flags: `-Dpdf=true` (needs `poppler-glib`; the Zig PDF renderer is
still in progress), `-Dx11=true` (needs `x11`).

The Zig dependencies are pinned by hash in `build.zig.zon` and vendored in the
tarball: zig-gobject (GTK bindings), zig-wayland, libghostty-vt (the terminal
core, needs no C libraries), zigimg and zig-yaml (in `third_party/`).

## 3. Building

```
tar xf dkde-vX.Y.Z.tar.gz && cd dkde-vX.Y.Z
packaging/build.sh check                         # tool and library check
DESTDIR=/path/to/stage packaging/build.sh install
```

`packaging/build.sh` runs `zig build --release=safe -Dcpu=baseline --system zig-pkg`.
Things worth knowing:

- **`-Dcpu=baseline`** (the default of the script) produces code that runs on
  any x86-64 machine. A plain `zig build` tunes for the build machine's CPU and
  may not start on an older one. Use baseline for an image.
- **`--system zig-pkg`** disables all downloads; dependencies come from the
  vendored directory.
- **`MODE=small`** gives the smallest binaries; `safe` (default) keeps runtime
  safety checks. Both are far smaller than a plain Debug `zig build`.
- A cross build for musl: `TARGET=x86_64-linux-musl packaging/build.sh`, but
  GTK still has to be available for that target (pkg-config and a sysroot), so
  building natively inside dkrescue is simpler.
- Variables: `PREFIX` (`/usr`), `DESTDIR`, `ZIG`, `MODE`, `CPU`, `TARGET`,
  `FLAGS`, `PAM_FORM` (`system` or `debian`), `INIT` (`dinit`, `systemd`,
  `sysvinit`, `none`), `GREETD_USER`. See the top of the script.

## 4. What gets installed

| Where | What |
|---|---|
| `$PREFIX/bin/` | `dkde-panel`, `dkde-session`, `dkde-greeter`, `dkde-greeter-session`, `dkde-greeter-start`, `dkde-setup`, `dkde-idle`, `dkde-pointer`, the apps (`dkde-term`, `-files`, `-settings`, `-edit`, `-hex`, `-calc`, `-calendar`, `-clock`, `-color`, `-charmap`, `-disks`, `-parted`, `-snip`, `-tasks`, `-view`), and `dkde-startx`, `dkde-xsession` |
| `$PREFIX/share/applications/` | the apps' `.desktop` files |
| `$PREFIX/share/wayland-sessions/dkde.desktop` | the login-manager session entry |
| `$PREFIX/share/dkde/` | defaults (`*.conf`, `style.css`), labwc config and keybindings, the service-file templates |
| `/etc/greetd/config.toml`, `/etc/pam.d/greetd` | login screen (from `packaging/build.sh install`) |
| `/etc/dinit.d/` | `greetd`, `seatd`, `dbus`, `networkmanager`, `bluetooth`, `cupsd` (with `INIT=dinit`) |

The per-user config (`~/.config/dkde/`, including `calendar.conf`) is created
on first use; `dkde-setup --once` runs from `dkde-session` on first login.

## 5. Run-time requirements

**Required for a desktop**

| What | Why | Command / library |
|---|---|---|
| GTK 4 runtime libraries, gtk4-layer-shell, libwayland-client | every program | |
| `labwc` 0.9.3 or newer | the compositor; must offer `wlr-layer-shell`, `wlr-foreign-toplevel-management`, `wlr-screencopy` (`ext-workspace-v1` and `wlr-virtual-pointer` are optional features) | `labwc` |
| `shared-mime-info` | file types | |
| an icon theme (Papirus is the default) and fonts (Noto) | icons and glyphs | |
| `dbus` | the session bus for notifications, **calendar reminders** and the tray (`dkde-session` starts one with `dbus-run-session`) | `dbus-run-session` |
| `seatd` (or elogind) | device access without logind | `seatd` |
| `greetd` | graphical login (otherwise log in on a tty and run `dkde-session`) | |
| `sudo`, `shadow`/`passwd` | run-as-administrator, user management | `useradd`, `usermod`, ... |

**Optional** (each feature hides itself or says what is missing): see
`README.md`, "Recommended software". The commands it looks for are `nmcli`
(NetworkManager), `bluetoothctl`, `rfkill`, `brightnessctl`, `wpctl` or `pactl`,
`wlr-randr`, `swaylock` (or `gtklock`, `waylock`), `lpadmin`/`lpstat` (CUPS),
`zip`/`unzip`/`tar`/`7z`, `parted` and the filesystem tools, `git`/`curl`.

**Not needed:** systemd, logind, polkit, libadwaita, X11 (unless `-Dx11=true`),
a D-Bus library, cron or any init-system timers. Calendar reminders run inside
`dkde-panel`, so dinit needs no timer support.

## 6. System setup

- Create the greeter account `_greetd` (or set `GREETD_USER`), in group `video`.
- Users need these groups for full function: `audio`, `video`, `input`,
  `netdev`, `plugdev`, `bluetooth`, `lpadmin`. `dkde-setup` checks and prints
  the single `usermod` command that adds the missing ones.
- Enable services: `dinitctl enable seatd dbus greetd` (and `networkmanager`,
  `bluetooth`, `cupsd` if installed). greetd takes over the VT in
  `/etc/greetd/config.toml` (`vt = 1`): do not also run a getty there.
- Set `XDG_RUNTIME_DIR` (`dkde-session` creates `/run/user/$UID` or a private
  directory if nothing else does).

## 7. Low-resource notes for the image

dkde defaults to GTK's CPU renderer (`GSK_RENDERER=cairo`, set through
`[performance] renderer` in `dkde.conf`): an idle panel was about 53 MB
instead of 228 MB in testing, and it needs no GL/EGL stack on the image. Leave
Mesa out unless a GPU needs it, and set `renderer=auto` for machines that have
one. Apps allocate with plain `malloc` and nothing polls while idle.

## 8. First-boot checklist (dkrescue QEMU)

1. `packaging/build.sh check` passes inside dkrescue (Zig 0.17.0, the three
   pkg-config modules). *Unverified: GTK 4 and gtk4-layer-shell on musl.*
2. `packaging/build.sh install` finishes; `ldd $(command -v dkde-panel)` shows
   no missing libraries.
3. `dkde-session` from a tty starts labwc and the panel (taskbar, start menu).
4. `dinitctl enable seatd dbus greetd`, reboot: the greeter appears and logs in.
5. Open `dkde-term`, `dkde-files`, `dkde-settings`, `dkde-calendar`.
6. Create a calendar event with a reminder two minutes ahead; the notification
   arrives (this also tests the session bus and the panel's notification server).
7. Check `~/.local/state/dkde/*.log` for warnings (the session sets `DKDE_LOG_FILE=auto`).

Known musl questions: `openpty`, `__errno_location` and
`program_invocation_short_name` are used directly and should link; libghostty-vt
has no C dependencies; musl's locale support is minimal, so translations
and localised dates may not appear (the calendar uses its own English names).
