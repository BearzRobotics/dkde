# Changelog

All notable changes to DKDE. Versions are the git tags (`vX.Y.Z`); the commit log has the detail.

## 0.3.3 (2026-11-17)

dkde-calc learning and geometry:
- **New functions**: modinv, popcount (bitcount), nand, nor, xnor, parity, bitlen, tobcd, frombcd, f32bits, f32, f64bits, f64.
- **Fixed**: calc crashed (heap corruption) after Learn's refresh and a click on Next step; the written-out steps used the wrong allocator. Learn's lesson list now shows a one-line description under each title, and the dropdown names each unit.
- **Learn** (loads in the background with a "Loading lessons..." message, from a one-file index cache made on first use and refreshed with the refresh button; can be moved to a window of its own for a second screen; never open at start-up, so calc opens at once; with a pane or Learn beside it the keys are smaller and stop growing, and the window widens to fit the pane): lessons are TOML files (data/learn, and your own in ~/.local/share/dkde/learn) with drawing, calculator, written-out solution and graph lines per step and practice questions that check your answer. Courses: Euclid's Elements (all 13 books, 465 propositions), arithmetic, algebra, trigonometry, calculus, linear algebra, and Computing (24 lessons; steps can put the calculator in Programmer mode with a base and word size on the maths in programming: binary, hex and octal, converting between them, two's complement, bitwise operations and shifts, powers of two and overflow, modular arithmetic, ASCII, hex colours, binary fractions, bits and logarithms, IP subnets, XOR checksums, counting, Boolean algebra, Gray code, base64, floating point). Computer Science (42 lessons, adding logic gates and adders, Hamming codes, fixed point and BCD, IEEE 754, UTF-8 and UTF-16, memory layout, caches, paging, CIDR, bandwidth and latency, amortised cost, exponential growth and recursion depth; 44 matching formulas in the Formulas pane beyond the basics: Big-O, hashing, the birthday problem, integer division, bit tricks, endianness, Luhn and CRC, the Euclidean algorithm and modular inverses, vectors, transforms, interpolation, Bezier curves, bytes and gamma, random number generators, RSA with small numbers, entropy, Huffman codes, floating-point error, time and dates, probability for algorithms, recursion and recurrences, divide and conquer and the Master theorem, graphs, binary trees, the cost of sorting, counting paths and dynamic programming). The lesson files are read only when Learn is first shown, so calc starts as fast as before.
- **Geometry**: colours and shading, a 3D mode (parallel projection, drag to turn) for solid geometry, and Cross tools for compass-and-straightedge work.
- **Command line**: `dkde-calc eval|steps|render|check-lessons`.

Fixes from the first test on real hardware (dinit):
- **Login screen**: a session picker (every installed session entry: labwc, dkde-compositor, dkde-wm), remembered between logins. Logging out ends everything the session started, so the next login no longer shows two panels.
- **No more aborts at File > Save As / Choose picture** on systems without compiled GSettings schemas: dkde compiles them into its cache.
- **dkde-tasks**: the Services page finds dinit when `/proc/1` is hidden; firewall on/off uses dinitctl under dinit; the Security page no longer crashes when the padlock is opened with SELinux (endless recursion); `sudo dkde-tasks` finds the user's display.
- **Panel**: Shut down and Restart ask for the password where there is no logind (dinit).
- **dkde-term**: the X on a tab closes it.
- **dkde-files**: the Trash is created when first looked at; right-click on a sidebar place (default folders, bookmarks, drives) offers Open, new tab, new window, terminal, remove bookmark, unmount; unmounted drives are listed and mounted on click.
- **dkde-parted**: a moving bar while a change is made.
- **Settings**: searching lists matching pages from every category, each a link; the mouse default speed is a little faster (0.4); Display: arrangement of several screens (main display, left/right/above/below, mirror) and a switch for the taskbar on other screens.
- **dkde-calc: stacked fractions.** Fractions are drawn the way they are written on paper, the numerator over the denominator with a bar, powers raised, roots with their bar and parentheses that grow with what is inside. A typeset copy of the line appears above the entry while you type; the history, the tape and the result preview use it too. View > Stacked Fractions turns it off; View > Results as Fractions shows exact results as 1/2 instead of 0.5. **Fraction key** (a/b, or Ctrl+/), like the n/d key of a TI: it puts an empty top and bottom above and below a bar; type the top, press Tab, type the bottom. A number just before the cursor becomes the top. (First of three requests: geometry drawing and a learning section follow.)
- **dkde-calc: Geometry pane** (View > Geometry, Ctrl+Shift+G): draw points, segments, lines, circles, polygons and angles on a grid (snap on or off, pan, zoom). Drag a point and every length, angle and area built on it follows. The measurements are listed under the canvas (lengths and midpoints, slopes and line equations, circle radius, area and circumference, polygon area and perimeter, triangle kind, angles in degrees and radians); click one to put its number in the entry.
- **dkde-calc: colours and shading in Geometry**: eight colours for lines and shapes, a Shade switch that fills circles, polygons and angles, and a Colour tool to recolour a shape; a Cross tool marks where lines and circles meet.
- **dkde-calc: Learn view (Euclid's Elements)** (View > Learn, Ctrl+Shift+L). It stands beside whatever pane is open (Graph, Geometry, History...), so a lesson and its figure are on screen together. Each lesson gives Euclid's statement, then steps you advance one by one while the figure is drawn in colour on the Geometry canvas, and ends with the proof. Written so far: the foundations (definitions, the five postulates with the parallel postulate shaded, the five common notions) and propositions I.1 to I.4. The remaining propositions of the thirteen books follow, book by book (`ai/LEARN-EUCLID.md`).
- **dkde-calc on the command line**: `dkde-calc eval`, `steps`, `render` (a lesson's figure to PNG or SVG) and `check-lessons`, with no window, using the same engine and figure drawing. Lessons are now TOML files (`data/learn/`, and your own in `~/.local/share/dkde/learn/`) with `draw` lines for the figure and `calc` lines to try in the calculator.
- Specs and README: X11 and the compositor are no longer described as non-goals.

## 0.3.2 (2026-11-16)

### Packaging
- **dkde-compositor and dkde-wm are packaged**: `packaging/build.sh` builds and installs both (and the `dkde-compositor` Wayland session entry) from the release tarball's vendored dependencies. `COMPOSITOR=no` / `WM=no` leave one out; `WLROOTS=0.19|0.20` and `XCB_RANDR_PREFIX` pick libraries. `packaging/PACKAGING.md` lists their build and run-time needs.

## 0.3.1 (2026-11-15)

### Desktop on our own display servers (experimental, separate packages)
- **dkde-compositor** (`src/compositor`, wlroots): a Wayland compositor with floating and tiling windows, workspaces, configurable shortcuts, layer-shell, taskbar and workspace protocols, output management, screen lock, idle, Xwayland and screen capture. See `src/compositor/README.md` and `dkde-compositor(1)`.
- **dkde-wm** (`src/xwm`, XCB): an X11 window manager with ICCCM/EWMH, workspaces, floating and tiling, Alt-drag, and the same shortcuts and settings file as the compositor. See `dkde-wm(1)`.
- **`dkde-session --x11`** (or `type=x11` in `~/.config/dkde/session.conf`) starts an X11 session: dkde-wm, the panel, polkit. `data/dkde-x11.desktop` is the xsessions entry.
- **dkde-wm on several monitors**: a work area per monitor, windows open where the pointer is, tiling/maximize/snap per monitor; size hints honoured; title bars (accent colour, dark mode and font from dkde.toml, live) with minimize, maximize and close buttons (and resize edges) for windows that draw no frame of their own; `[windows] focus = "follow"`. Needs `libxcb-randr0-dev` and the cairo and pango development files to build.
- **dkde-panel runs on X11**: bars are dock windows with struts, the wallpaper a desktop window, the Start menu a window beside the bar.

### Power
- **Dim the screen** before it locks or turns off (Settings > Power & lock): the backlight goes down to a chosen level and comes back when you move; it never brightens a screen already dimmer than that. Needs `brightnessctl` (or `light`).
- **Different times on battery**: one switch, then dim, lock, screen-off and sleep times for when the computer runs on its battery; `dkde-idle` notices the change of power source within 15 seconds.
- **Lid and power button**: what closing the lid (on battery, on mains) and pressing the power button do, written to a login-manager drop-in (`50-dkde.conf`) through the administrator padlock. Not tried on a real machine.

### Administrator padlock
- The padlock's timeout is a setting (Settings > Accounts > User, minutes; 0 keeps it open until the program closes).
- **Unlock once**: Services, Security and Firewall in Task Manager have a padlock in the command bar. Click it, give the password once, and the pages read their information and run every action without asking again. The padlock shows open (blue) while unlocked; click it to lock. It locks by itself after five minutes without an action, or when Task Manager closes. The password lives only in that program's memory (never in a file, command line or environment); if sudo stops accepting it, the padlock closes and the dialog returns. Locked, everything works as before (a password per action).
- Settings has the same padlock in its title bar, for the pages that change the system (time zone, network address, printers, accounts).
- Log times are local time now, not UTC.

### For developers
- **Settings > System > For developers** (only DKDE programs are affected, and only those started after a change): log level, keeping each program's log in `~/.local/state/dkde/<program>.log`, GTK and GLib debug messages, GTK's inspector shortcut (Ctrl+Shift+I), open or delete the log folder, **Copy report** / **Save report** (versions, session, kernel, tools present, settings and the end of every log, in `report.txt`) for a bug report. The log level also applies to dkde-compositor (wlroots levels error, info, debug) and dkde-wm (a debug trace of the events it handles), and with log files on, each program's stderr itself goes to its log file, so a crash's stack trace and GTK's own warnings are kept. Every program, including dkde-polkit, dkde-snap, dkde-pointer and dkde-pdfcheck, now uses the shared logging. The choices are kept in `~/.config/dkde/developer.toml`; `DKDE_LOG` and `DKDE_LOG_FILE` in the environment still win. Every program now writes a "starting" line at debug level, so its log file exists as soon as it runs.

### Calculator
- **Show Work in Programmer mode**: AND, OR and XOR lined up bit by bit, shifts, NOT, a negative answer as its two's complement (invert, add one), decimal to binary by repeated division, and grouping bits into hex and octal digits.
- **Programmer mode fits a 720-pixel screen**, also with the tape open: tighter keys and base rows, a short tape there, and the calculator column scrolls when a screen is shorter still, so the keypad is never pushed off the bottom.
- **Menus taller than the screen** (View) no longer show a sideways scrollbar, and the vertical one is slim with room left for it, so it does not cover the shortcut keys.

### Window snapping (compositor and window manager)
- **Snap assist**: after a window is dropped on a zone of the layout card, the zones still empty each list the other open windows; choose one and it goes there (Wayland and X11). It closes when every zone is filled or on Esc.
- **Drag to an edge**: drop a window on the left or right edge for that half, on a corner for that quarter, on the top edge to maximize; a tinted outline (blue bars on X11) shows where it will go while you drag. Settings > Windows has a switch (`[windows] edge-snap` in compositor.toml). **Layout card at the top** (as in Windows 11): drag a window to the top of the screen and a card with the eight arrangements (halves, thirds, quarters, mixed) appears; move onto a zone, which lights up with an outline of where the window will go, and drop. Dropping on the very top edge still maximizes. Super+Z keeps offering the same layouts from the keyboard.
- **dkde-wm now moves and resizes windows that draw their own title bar** (`_NET_WM_MOVERESIZE`), which is every GTK 4 program; before, only Alt-drag worked on X11.

### Compositor and window manager shortcuts
- dkde-wm no longer lets a cascaded wide window hang off the right or bottom edge of the screen.
- Workspaces are now **Super+1…9** (Super+Shift+1…9 carries a window), layout toggle **Super+T**, float **Super+Shift+Space**, quit **Super+Shift+Escape**. They were Alt+digit and friends, which took keys programs use for their own menus and modes (the calculator's Alt+1…3).

### Screenshots
- **dkde-snip works on X11** too (full screen, region and scrolling capture); the scrolling capture turns the wheel through XTEST. On a machine without a mouse the compositor now gives programs a pointer once a tool such as dkde-snip creates a virtual one, and scrolling screenshots were checked end to end on both display servers (a 400-line page stitched into one tall picture).

### Task Manager
- **Choose the backend yourself**: Settings has a Firewall backend (automatic, firewalld, ufw, nftables, iptables, none) and a Security module (automatic, AppArmor, SELinux, none) setting that override detection, and the pages are rebuilt for the choice at once.
- **Page buttons wrap into rows** instead of a sideways scroll bar above each page: the buttons of Services, Users, Startup apps, Security and Firewall flow onto as many rows as the window width needs.
- **Services page without the command line**: timers and sockets, dependencies and "needed by", the unit's definition, editing an override (or dinit's service file), reverting to the packaged definition, reset-failed (one or all) and daemon-reload.
- **Starts in seconds instead of tens of seconds on a slow disk.** The window's remembered state (columns, sort, widths) was saved through GLib, which flushes to disk (fsync) before renaming; a window saves several times as it opens, and each save stalled the program for 4–18 s on a busy btrfs disk. State is now written with a plain atomic rename, no flush. Every program that remembers state through `common.state` benefits.
- **Security page** (AppArmor or SELinux, only where one runs), complete from the GUI: profiles and modes, enforce / complain / disable, edit a profile (checked before it replaces the file) and start a new one; SELinux mode now and at boot, relabel, settings, policy modules, port labels and file labels; the recent refusals told in plain words, with **Allow…** writing the AppArmor rule or SELinux module that would permit one (shown first). Everything goes through the administrator prompt; input never reaches a shell.

- **Firewall page** (firewalld, nftables, ufw or iptables, whichever is installed or running): rules in plain words, add and remove, chain policies and saving for restart (nftables, iptables), firewalld zones, ufw defaults; chains owned by another manager are read-only; input is validated and never reaches a shell.

### Settings
- **Windows page** (Personalization): floating or tiling, the gap, the main window's width, focus following the mouse (X11), and which window system starts at the next sign-in (labwc, DKDE compositor, DKDE X11 window manager; written to session.conf).
- **Apply no longer waits on the disk**: settings, the autostart entries, the locale file, display.sh, the calendar's files and setup's files are replaced by a rename with no flush first (`fsio.tryWrite`); the flush could hold a program for many seconds on a busy disk.

### Settings follow the session
- **Settings > Keyboard shortcuts, Mouse & touchpad, Keyboard layout and Virtual desktops** edit `~/.config/dkde/compositor.toml` when the session is DKDE's own compositor or window manager, and labwc's files under labwc. The compositor and dkde-wm **watch the file and apply changes at once** (no reload command), and both now end the session on SIGTERM. They announce themselves to the programs they start (`DKDE_SESSION_COMPOSITOR`, `DKDE_SESSION_PID`), which is how Settings knows, and the default Log Off command follows.
- dkde-wm applies `[input]` layout, variant, options and key repeat with `setxkbmap` and `xset`; touchpad options are not offered on X11. The shortcut list is `keys.defaults` plus `[keys]`, one table for both programs.

### Shared desktop API
- **`common.desktop`**: one interface for windows, workspaces, outputs and screenshots, with capability discovery; programs no longer touch Wayland or X11 directly. Backends: `src/wldesktop` (Wayland protocols) and `src/x11desktop` (EWMH over XCB). The panel's taskbar and workspace switcher, dkde-snip's capture and dkde-idle's screen off/on use it.
- **Outputs on both backends**: listing, mode changes and power through the shared API (Wayland output management; X11 RandR 1.3+, one screen-size-aware configuration). **Settings > Display** and dkde-idle use it, so neither needs `wlr-randr` any more; on X11 the Scale row is hidden (RandR has none) and `display.sh` is written with `xrandr` commands.
- **dkde-idle on X11**: polls the idle time (MIT-SCREEN-SAVER) and switches the screen off with DPMS; lock detection picks xsecurelock, i3lock, slock or xlock there. The X11 session starts it.
- Building the panel, idle and settings now needs the XCB development files (`libxcb1-dev`, `libxcb-randr0-dev`).

## 0.3.0 (2026-11-15)

### Window snapping
- **dkde-snap (Super+Z):** a snap-layout picker as an overlay: halves, two-thirds and a third (both ways), thirds, quarters, a half beside two quarters (both ways) and top/bottom halves. Click a zone and the focused window moves there. The zones are 13 labwc regions with their own shortcuts (Super+Ctrl+Alt+Shift+A…M), written into `rc.xml` by dkde-setup and by Settings > Keyboard shortcuts > take over; dkde-snap follows any rebinding.
- **Every program can be snapped to half a screen.** The calculator (865 → 616 px least width; the side panes scroll sideways), the calendar (745 → 520), the task manager (929 → 506) and the colour tool no longer hold the window wider than 640 px. The calendar (712 → 325), colour tool (478 → 320) and task manager (552 → 290) also fit a quarter tile on a 720p screen.

### Calculator
- **Show Work** now lays the steps out as a column of equations with a note beside each, the way a solution is written by hand, and covers `dsolve`, `taylor`, `laplace` and `ilaplace`; the power rule for integrals is shown in its pieces.
- **`dsolve`:** first-order linear equations and second-order constant-coefficient equations with a constant right side, with initial conditions (`y(0)=…`, `y'(0)=…`).
- **`taylor(f, x, a, n)`** with exact coefficients for sums, products and quotients of series (Laurent series at poles); **`limit`** now tries the exact series first and gives `limit(x·ln x, x, 0) = 0`, and a limit that grows without bound is detected.
- **`laplace(f, t)` and `ilaplace(F, s)`** for sums of `c·tⁿ·e^(at)·{1, sin, cos, sinh, cosh}(bt)` and for rational functions (partial fractions).
- **Fixes:** `gcd(0, 0)` and `taylor(…, -1)` aborted the program; a divergent integral (`integral(1/x, x, 0, 1)`) returned a number and is now an error; an identity (`x^2 = x^2`, `0x = 0`) listed thousands of roots and now says any number works.

### Fixed
- **Escape closes every dialog** (28 of them, in dkde-files, hex, pdf, view, parted, tasks, settings, calendar and the administrator prompt); GTK windows do not do this by themselves.
- **dkde-edit:** Ctrl+C in the terminal panel reached the text, not the shell.
- **dkde-hex:** an empty or short file logged a GTK assertion about the scrollbar range.

### Earlier in this release

### Calculator
- **dkde-calc: sessions.** File ▸ Save Session… / Open Session… (`.dkcalc`) keep the history, variables, functions, memory and own formulas in a file. Matrices, complex numbers and amounts with units are now kept between runs too. Nonlinear systems (`x^2+y=3; x-y=1`) are solved approximately by Newton's method.
- **dkde-calc: units in entries.** `5 ft + 3 in`, `60 mph to km/h`, `5 kg * 2 m/s^2` (= 10 N), `100 °C to °F`, `sqrt(9 m^2)`, `1 GiB to MB`, `sin(30 deg)`. Exact dimensional arithmetic over about 120 units with SI and binary prefixes (also written out: `kilometers`, `mebibyte`), physical constants (`c`, `planck`, `k_B`, `N_A`, `q_e`, `g0`…), and the mismatch of units is reported. `/` reads as Qalculate does: `10 m / 2 s` divides by `2 s`, `1/2pi` is 1/(2π).
- **dkde-calc: systems of equations.** `x+y=5; x-y=1` (equations side by side) or `multisolve([x+y=5; x-y=1], [x, y])` solve linear systems exactly; a system with no single answer is reported.
- **dkde-calc: complex numbers and matrices**, checked against Qalculate (145 cases). `i`, `(2+3i)*(4-i)`, `sqrt(-4)`, `(-8)^(1/3)`, `ln(-1)`, `abs`, `arg`, `conj`, `re`, `im` and the trigonometric functions of complex arguments; exact while the parts are fractions. Matrices as `[1, 2; 3, 4]` (stored with `M = …`): `+ − × ÷`, powers and `^-1`, `det`, `inv`, `adj`, `cofactor`, `rk`, `rref`, `transpose`, `trace`, `identity`, `dot`, `cross`, `norm`, `row`, `column`, `element`, `horzcat`, `vertcat`, `lsolve`. List statistics on them: `mean`, `median`, `mode`, `percentile` (nine methods), `quartile`, `decile`, `iqr`, `stdev`, `var`, `cov`, `pearson`, `spearman`, `rank`, `trimmean`, `winsormean`, `geomean`, `harmmean`, `rms` and more. `log` stays base 10 (Qalculate's is natural).
- **dkde-calc: show an answer another way.** `255 to hex`, `0.75 to fraction`, `7/3 to mixed`, `100 to base 36`, `0.5 to bin`, `2024 to roman`, `12.5 to sexagesimal`, `3725 to time` (seconds as h:mm:ss), `360 to factors`, `0.25 to percent`, `to decimal`, `to scientific`, `to engineering`. The answer is also previewed while typing.
- **dkde-calc: 100 more functions**, checked against Qalculate 5.9.0 (211 reference answers in the tests): hyperbolic and inverse reciprocal trig (`sech`, `asec`, `acot`…), `exp2`, `exp10`, `gamma`, `beta`, `digamma`, `erf`, `erfc`, `erfinv`, `probit`, `zeta`, `lambertw`, `sigmoid`, `logit`, `heaviside`, `ramp`, `kronecker`; number theory (`isprime`, `nextprime`, `prevprime`, `nthprime`, `primepi`, `totient`, `fibonacci`, `factorial2`, `hyperfactorial`, `superfactorial`, `derangements`, `bernoulli`, `powmod`, `div`, `rem`); probability distributions (normal, binomial, Poisson, exponential, gamma, chi-square, Weibull, beta, t, F, Cauchy, logistic, Pareto, Rayleigh, with inverses) and the spreadsheet money functions (`pv`, `fv`, `pmt`, `nper`, `rate`, `ipmt`, `ppmt`, `effect`, `nominal`, `sln`, `syd`…).
- **dkde-calc: 48 more formulas** in the Formulas pane (investments and loans, more geometry, electronics and computers).
- **dkde-calc fixes:** a whole number of 300 digits or more (`2^1000`, `200!`) aborted the program when shown; it now shows as scientific notation from its exact digits. A result below a billionth was shown as 0; it is now shown as d.ddd×10^-n. `nCr(7, 8)` is 0, not an error.

### Added
- **dkde-hex: PDF structure.** A bundled `pdf.hexpat` shows the header, the last `startxref` and the table it points to.
- **dkde-hex: checksum note.** Before writing to a disk holding ext2/3/4, XFS, btrfs, exFAT or F2FS, the confirmation says that the filesystem checksums its metadata, which this editor does not recompute, and names the tool to use (e2label/tune2fs, xfs_admin, e2fsck, fsck.exfat, fsck.f2fs).
- **dkde-hex and dkde-files: Open as administrator** found the program by name through `env`/`sudo`, which fails when the program is not in PATH (run from a build folder); it now uses the path next to the running program.
- **dkde-hex: hostile files.** Sizes, shifts, bases, bit widths and floats taken from a file are checked instead of cast, so a corrupt file is refused with a message and cannot abort the editor.
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
