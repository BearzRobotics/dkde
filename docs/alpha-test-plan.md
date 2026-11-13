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
  parted, pdf, settings, snip, tasks, term, view) starts in that session and
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
