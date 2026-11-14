# Changelog

All notable changes to DKDE. Versions are the git tags (`vX.Y.Z`); the commit log has the detail.

## Unreleased

### Added
- **dkde-hex: format index.** The Kaitai and ImHex folders are indexed in `~/.cache/dkde/hex-formats.index`; only new or changed files are parsed at start (a 500-file scan went from over a second to under 30 ms).
- **dkde-hex: more formats work.** Kaitai instances honour `if:` before `pos:`, and `parent:`; ImHex gains `$ = offset`, `std::mem::find_sequence(_in_range)`, `find_string(_in_range)`, `std::time::to_utc/to_local/format` and `sizeof` of a structure. ELF, JPEG, ZIP and tar now describe in full; a file's format is chosen among all candidates for the first that parses without error (a WAV file is no longer taken for AVI).
- **dkde-hex** is back: the hex editor (disk mode, data inspector, Kaitai Struct and ImHex structure views), restored from before the restructure and moved to `hex.toml`, `--help`/`--version` and the per-program build.

## 0.2.0 (2026-11-13), first alpha

### Added
- **Files: archives through libarchive.** An archive opens like a folder (double-click, Open, Open in New Tab, Open in New Window, a path in the path bar, or as the program's operand); the first crumb is the archive's name. Extract Here and Extract To…; Compress to .zip, .tar.gz, .7z (and .tar.xz, .tar.zst for custom menus). Reads zip, tar (gz, xz, bz2, zst), 7z, rar, iso, cpio, deb and rpm. Unpacking runs in a helper process, refuses `..`, absolute names and symlinks that leave the folder, and stops at 16 GB or a million entries; password-protected archives are reported.
- **Files: phones and cameras.** MTP (Android), PTP and iOS devices have a sidebar section, are mounted on click, disconnect with a right-click, and follow plugging and unplugging (needs gvfs-backends).
- **Files: servers** (sftp, ftp, smb) with a Nautilus-style path bar and progress, and live folders at scale.
- **Settings: Network** through NetworkManager (devices, Wi-Fi, saved connections, a connection editor); without it, Wi-Fi through wpa_cli plus a fixed IPv4 address written to dhcpcd.conf. The Wi-Fi password is sent on stdin, not on the command line.
- **Settings: Online accounts.** Optional read-only calendars: `.ics` links, and Google calendars through GNOME Online Accounts (no password or token stored). Reminders include them.
- **Settings: Date & time Calendar.** The taskbar clock can show the date in any calendar dkde-calendar has: Gregorian, Julian, Fixed, the three Rosquin layouts, Chinese, Hebrew, Coptic and Ethiopian (`panel.clock-calendar`).
- **Settings: default apps** are DKDE's own (dkde-files, dkde-edit, dkde-view, dkde-pdf, dkde-term) until you choose otherwise, with Image viewer and PDF viewer rows.
- **dkde-calc:** exact arithmetic, equations, formulas, calculus, units, dates in every calendar, graphs (also from formulas), complex solutions; Save… the graph as PNG, SVG or CSV.
- **dkde-tasks:** sampler, services, startup, users, GPU and process actions.
- **dkde-pdf:** printing, ink and text boxes, typing into form fields, page thumbnails, two pages side by side, rotation, night mode, full screen and presentations, recent documents and reopening where you left off, OCR of scanned pages (needs ocrmypdf), JPEG 2000 and JBIG2 images.
- **dkde-view:** parity with Eye of GNOME, Loupe, gThumb and Gwenview.
- **dkde-edit:** parity with gedit, GNOME Text Editor and Kate.
- **dkde-term:** Konsole-style panes, pictures (Kitty graphics), right-to-left text.
- **Panel and Start menu:** Flatpak, Snap and AppImage apps with their icons.
- **dkde-help:** browse by topic, section, folder or letter; tables in columns; now on dkman 0.5.0 (compressed pages decoded in process, man-db-compatible page choice).
- **Theming:** the accent colour reaches GTK widgets that themes hard-code.

### Changed
- The Files right-click menu is compact and scrolls only when it is taller than the window.
- Archives no longer need `zip`, `unzip`, `tar`, `7z` or `unrar`: libarchive does it.
- Build: one build file per program; `dkde-files` links libarchive.
- Dependencies: dkman 0.5.0 (md-zig 0.6.0, gtroff-zig 0.5.0, regex-zig 0.1.0), pdf-zig 0.2.2, DKTermCore 0.1.1.

### Fixed
- A popup menu taller than its window was not shown on X11 (a blank box appeared); menus now fit or scroll.
- The time zone page showed the wrong zone on systems without `/etc/timezone`; UTC is offered.
- dkde-tasks crashed when sorting reversed on equal values; its menus had a doubled scroll bar.
- dkde-edit printed two GTK criticals every time its window closed.
- The greeter cancels a failed session start and no longer leaks its state at exit.
- A damaged image is refused instead of crashing (zigimg).
- Online calendars follow only safe redirects and drop orphaned caches.

### Needs
- Build: `libarchive-dev` (and `libarchive13` at run time). See README and `packaging/PACKAGING.md`.
- Not yet verified on musl with dinit (dkrescue). See `docs/alpha-test-plan.md` for what has and has not been exercised.

## 0.1.1 and earlier
See the git tags (`v0.0.2` to `v0.1.1`) and `git log`.
