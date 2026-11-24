# Alpha test plan (first ISO)

What was checked on the development machine (Ubuntu 26.04, glibc, systemd, X11
host) before the first ISO, and what only the ISO can show. Update it as items
are confirmed.

## Checked before the ISO (2026-11-13)

- `packaging/build.sh install` (release, baseline CPU) into a staging directory:
  finishes, 28 programs, session files, `.desktop` files.
- `tests/cli-contract.sh` on the staged binaries; `build-isolation.sh` passes.
  `zig build test` passes (exit 0).
- The staged session (`dkde-session`: labwc, panel, idle watcher, first-run
  `dkde-setup --once`) starts in a private headless compositor with an empty
  panel log; the Start menu opens with Super and searches; `dkde-term` opens.
- Every program (calc, calendar, charmap, clock, color, edit, files, help,
  hex, parted, pdf, settings, snip, tasks, term, view) starts in that session and
  stays up with empty stderr.
- All 19 Settings pages open without a trace.
- The greeter against a fake greetd: wrong password, retry, `start_session`.
- Google calendar events through GNOME Online Accounts: fetched and converted.

## Only the ISO can show (do these first)

1. Boot to the greeter (real greetd, PAM, seatd or logind, the greetd user in
   `video`). Wrong password, right password, session starts. If the screen is
   black, read `/tmp/dkde-greeter-<uid>.log`.
2. `~/.local/state/dkde/session.log` and `dkde-panel.log` after login: no
   warnings that matter.
3. Log off and back on; Shut Down and Restart from the Start menu (the commands
   are `poweroff` and `reboot`; check they work without sudo on the image).
4. Network: connect to Wi-Fi from Settings (NetworkManager if the image has it,
   otherwise wpa_supplicant and dhcpcd). Type a wrong and then a right password.
5. Sound, brightness, Bluetooth, printers pages with real hardware or saying
   plainly what is missing.
6. Time zone: the page shows the current zone; changing it asks for the
   password (elevation through `dkde-polkit-ui` or sudo).
7. Settings → Users: add a user, change a password (needs the administrator
   password dialog).
8. `dkde-parted` on an image file or a spare disk only, never the live disk.
9. Idle lock and screen off (Power page) with a lock program installed.
10. `ldd` on the binaries inside the image: no missing libraries (musl: see
    PACKAGING.md section 8).

## Hex editor (dkde-hex)

Restored after the restructure (2026-11-13). Checked: builds, `--help`/`--version`, opens a file with an empty stderr, `zig build test`. Not exercised: disk mode. Do it on an image file only, never a disk in use: attach a scratch image as a loop device, open it with `dkde-hex --device /dev/loopN` (as administrator), check the window moves (Alt+Page Up/Down) and Find searches the whole device; Enable writing, change a byte, Write changes, confirm it on re-reading; Save as image to a file and refuse a device; Clone onto a second loop device and check the refusals (the source itself, a mounted disk, a smaller target). Open a file with a known format (ELF, PNG) and check Structure picks it.

## Archives in Files (libarchive)

Checked: all five pack formats round trip with folders and symbolic links; `../`, absolute paths and a symlink escape are refused; a damaged, missing or password-protected archive fails with a sentence and leaves no partial folder; opening an archive in a window, browsing a subfolder and going Up works. Not clicked: the item context menu (Open in New Tab, Extract Here, Extract To…, Compress), rar and 7z archives made by other tools, large archives.

## Known gaps (not bugs)

- Network: no VPN profiles, hidden Wi-Fi networks, IPv6 on the dhcpcd path.
- Online accounts: Google calendars only; contacts, mail, files from GOA and
  other providers are not read. GOA is optional and absent from a minimal image.
- Unverified on dkrescue: musl, dinit services, GTK 4 and gtk4-layer-shell
  there (PACKAGING.md).
- Phones and cameras in Files (MTP): code only; gvfs-mtp is not installed on the development machine, so it needs a real phone on the ISO (plug in, click the entry, copy a file, right-click to disconnect).
- Click paths not exercised by hand: network connection Edit/Save/Forget, the
  fixed-address Apply, the graph Save… dialog (PNG, SVG, CSV), tasks sort in
  both directions, right-click menu scroll bars.

## Compositor effects (2026-11-23)

Checked in a headless compositor (keys through `wtype`, pictures through `grim`) and in the QEMU VM with the
virgl GPU and real pointer input (`src/compositor/qemu/README.md`): window rules, placement, animations, Scale,
Expo, the Alt+Tab ring, wobbly windows, blur, painting, the negative filter, shelf and tab groups (headless).
The cube (tilted, with motion blur trails), the lens and motion blur on a dragged wobbling window were also seen in the VM.
dkde-wm: rules, placement, sticky, opacity property, gestures and tab groups under Xvfb with xdotool. dkde-xcomp (X11
compositing manager) under Xvfb with Mesa software GL: fades, opacity, blur, colour filter, zoom, lens, finder, snow, the cube.
On a real Xorg in the QEMU VM (modesetting, software EGL), with dkde-wm sending the real keys: opacity, snow, filters, zoom,
the lens, the cube and water ripples. Not seen there: the finder ring, fades, blur and trail focus (timing or nothing translucent).

On real hardware (a GPU with the GLES2 renderer, wlroots 0.19 or 0.20) check, with each effect switched on in
Settings > Effects and the compositor's log open:

1. The compositor starts with `WLR_RENDERER=gles2` and logs no shader errors; memory stays flat while you drag,
   switch workspaces and open Scale and Expo for a few minutes (a leaked swapchain once killed it in two).
2. Mouse paths that could not be driven in the tests: clicking a thumbnail in Scale or the switcher, clicking a
   tile or dragging a window to another tile in Expo, the shelf thumbnail, Super+right-button gestures, Opacify,
   the water ripples.
3. The cube (including the tilt and reflection), motion blur and the lens on real hardware (they were checked in the VM).
4. Several monitors and fractional scale: the effects assume one output per frame and a non-rotated output.
5. dkde-wm: the same rules, tab groups and gestures on a real Xorg or XLibre session.
6. dkde-xcomp on a real Xorg or XLibre session with a GPU (`dkde-session --x11`, effects switched on in Settings > Effects):
   it logs "compositing" and no shader or EGL errors, windows (GTK, xterm, the panel) draw and update without tearing or
   stale areas, opacity and fades work, the cube turns on Ctrl+Alt+Left/Right, Super+Ctrl+F steps the filters, and
   switching every effect off logs "not compositing" and leaves the desktop as it was. Check CPU use while a window
   animates (GetImage copies every damaged window; a texture-from-pixmap path would avoid that) and with two monitors.
