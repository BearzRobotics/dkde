# Desktop setup checklist

What a system needs around dkde to feel like a complete desktop. dkde itself
runs without any of the "Add" items, but several things people expect (a lock
screen, USB sticks mounting, a browser's file chooser) come from other
programs, and nothing in dkde provides them.

Package names are Debian's; other distributions use similar names. **Nothing
here has been tested on an ISO yet.** Items are marked *verify* where a flag or
file name is from documentation and has not been tried. The current ISO does not
ship these items; this is the list for the next one.

dkde's rule applies to every choice below: **no systemd, no logind, a session
D-Bus only because `dkde-session` starts one** (SPEC.md 2 and 5.10). Prefer a
program that needs neither a system service nor logind.

## 1. Already assumed by dkde

These are listed in SPEC.md. Their absence is reported by `dkde-setup --check`
or by the page that needs them.

| Need | Packages |
|---|---|
| Compositor, session, login | `labwc`, `greetd`, `seatd`, `dbus` |
| Display page, screen off | `wlr-randr` |
| Network, Bluetooth, printers | `network-manager`, `bluez`, `cups` |
| Sound | `pipewire`, `wireplumber` (`wpctl`), `pipewire-pulse` |
| Brightness | `brightnessctl` (or sysfs access) |
| Icons and fonts | `papirus-icon-theme`, `fonts-dejavu` or `fonts-noto` |

## 2. Add: things that would otherwise be missing

| Gap | What to add | Notes |
|---|---|---|
| **Lock screen** | `swaylock` (or `gtklock`) | dkde has no lock screen of its own (SPEC.md 5.1). Without one, Lock does nothing. `swaylock` installs its own PAM file. |
| **USB sticks and cards mounting** | `udevil` (its `devmon`), `eudev` or another udev | Mounts without polkit or D-Bus. **udevil must be installed setuid root** (Debian asks at install; without it devmon needs udisks or pmount), and `udevd` must be running because devmon watches devices through libudev. Needs bash 4 or newer. Autostart: `devmon --no-gui &`. Events can run a command: `--exec-on-drive`, `--exec-on-unmount`, `--exec-on-remove`, with `%d` (mount point), `%f` (device) and `%l` (label), per its man page. *Verify* by running it: not tried yet. udisks2 is the alternative, but it needs polkit (see section 4). |
| **Power button and laptop lid** | `acpid` | With no logind, nothing acts on the lid or the power button. `acpid` runs a script; one that calls `loginctl`-free commands (`poweroff`, or a suspend command) is enough. *Verify* on a laptop. |
| **Clock** | `chrony` (or `ntpsec`, or `busybox ntpd`) | Without systemd-timesyncd nothing keeps the time right. |
| **Night light** | `wlsunset` | Starts from the autostart with the user's coordinates. No dkde setting for it yet. |
| **Out-of-memory** | `earlyoom` | For old machines: kills the biggest program before the system freezes. |

## 3. Add if the system runs a browser, Flatpak or screen sharing

| Gap | What to add | Notes |
|---|---|---|
| **Desktop portals** | `xdg-desktop-portal`, `xdg-desktop-portal-wlr`, `xdg-desktop-portal-gtk` | Needed for screen sharing in a browser, and for any sandboxed app's file chooser. A plain Firefox or Chromium uses GTK's own file chooser and does not need them. |
| Portal choice | `~/.config/xdg-desktop-portal/dkde-portals.conf` (named after `XDG_CURRENT_DESKTOP`, which `dkde-session` sets to `dkde`): `[preferred]`, `default=gtk`, `org.freedesktop.impl.portal.ScreenCast=wlr`, `org.freedesktop.impl.portal.Screenshot=wlr` | *Verify.* |
| Portal environment | In the labwc autostart, before anything else: `dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP` | Portals are started by D-Bus; they need to see the session's variables. *Verify* with `dbus-run-session`. |
| **Saved passwords** | `gnome-keyring`; autostart `gnome-keyring-daemon --start --components=secrets` | Browsers and NetworkManager use it for passwords. Without it, they ask every time (or store them in plain text). Unlocking it at login needs a PAM line in greetd's PAM file; *verify*. |

## 4. Authentication agent: decision

**dkde does not adopt polkit.** `common.elevate` keeps running commands through
`sudo -S -k` with its own password dialog (SPEC.md 5.5).

Why:

- polkit needs `polkitd` on the system bus *and* a login session that something
  tracks (logind, elogind or ConsoleKit). dkde runs without logind, so polkit
  would see the user as having no session and its "active session" rules would
  go wrong. The fix is another daemon (`elogind`) on every ISO.
- Every dkde action is "run this command as root". sudo does that with no
  daemon and no policy files. polkit would mean a `.policy` file per action.
- It is a dependency the ISO would not otherwise carry, on the machines that
  have the least room for it.

What this leaves: **other programs** that call polkit (GParted, NetworkManager
asking to change a system connection, udisks2) fail quietly when no agent is
running. Choose per ISO:

- **Do not ship those programs.** dkde has its own partition tool
  (`dkde-parted`), Network page and automounter above. Nothing then needs polkit.
  This is the plan for a small ISO.
- **If an ISO does ship one**, it needs `polkitd`, an `elogind` (or `seatd` plus
  rules that do not depend on a session; *verify* that this works) and an agent
  autostarted in the session: `polkit-gnome` or `mate-polkit`, both GTK. A
  dkde agent that reuses the `common.elevate` dialog is possible later (it has
  to speak polkit's agent protocol over the system bus), but it would still
  need `polkitd` and the setuid helper from the polkit package, so it saves
  nothing on the ISO.

## 5. Not provided, and not a package

Work in dkde itself, in the order that matters most:

1. ~~About page~~ and ~~Language & region page~~: done. Language & region writes
   `~/.config/locale.conf` for the user and needs generated UTF-8 locales on the
   system (`locale -a`); the ISO must ship some besides `C.UTF-8`.
3. ~~Low battery warning~~: done (SPEC.md 5.1). Warns, then sleeps or powers off
   after a grace period. Not tried on a real laptop.
4. **A notification when a disk is mounted or removed**, from the automounter's
   hook.
5. **Do Not Disturb** for the notification toasts.
6. **Input methods** (Chinese, Japanese, Korean typing): not wired up
   (SPEC.md 5.3). Needs `fcitx5` and the Wayland text-input protocol.
7. **Accessibility:** the session sets `NO_AT_BRIDGE=1`, so screen readers
   cannot see dkde apps.

## 6. Autostart, in one place

What `~/.config/labwc/autostart` would hold with everything above, in order
(the first two are already in `data/labwc/autostart`):

```sh
dbus-update-activation-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
(while true; do dkde-panel; sleep 1; done) &
dkde-idle &
devmon &
gnome-keyring-daemon --start --components=secrets &
wlsunset -l LATITUDE -L LONGITUDE &
```

And as system services (dinit files for these do not exist yet; `data/dinit.d/`
has the ones that do): `dbus`, `seatd`, `greetd`, `networkmanager`, `bluetooth`,
`cupsd`, `acpid`, `chrony`, `earlyoom`.
