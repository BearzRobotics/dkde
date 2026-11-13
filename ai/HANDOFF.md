# Handoff — 2026-11-12, branch `build-and-apps`

Nothing from this session is committed. Working tree: modified `src/common/core.zig`, `src/common/root.zig`, `src/common/contextmenu.zig`, `src/settings/onlinepage.zig`, `src/calc/graph.zig`, `src/tasks/columns.zig`, `src/tasks/table.zig`, `src/tasks/simplelist.zig`; new `src/common/goa.zig`.

## Direction from the owner
- One place for online accounts: **dkde-settings → Accounts → Online accounts**, built on **GNOME Online Accounts (GOA)**. All integrations optional, never intrusive. Calendar-specific settings may live in the calendar.
- Next step agreed: **read-only calendar sync through GOA accounts** (GOA gives a CalDAV address and sign-in token). This supersedes the "no CalDAV / no sign-in" rejection in docs/decisions/0002. Update that decision record (or add 0003) when doing it.
- Contacts / mail / files from GOA: not started, only listed.

## Done this session
1. `src/common/goa.zig`: lists GOA accounts via D-Bus (Gio, no libgoa; dev headers aren't installed and the zig-gobject package has no goa bindings). Uses NameHasOwner first so the daemon is never auto-started. `fetch()` is async; result is `.unavailable | .failed | .ok(Accounts)`. Has a parser unit test with a synthetic GetManagedObjects reply (passes). `managerCommand()` finds `gnome-online-accounts-gtk` or `gnome-control-center online-accounts`.
2. Settings Online accounts page: new "Accounts" section on top (GOA list + "Add or manage accounts…"), existing .ics links kept under "Calendar links". Lifetime: `dead`/`busy`/`goa_pending` decide who frees the page. Verified in a headless screenshot; this machine has zero GOA accounts, so the populated list has only been tested through the unit test.
3. dkde-calc graph: Save as Picture now offers **SVG** as well as PNG, chosen by file extension and a filter list (`cairo_svg_surface_create` declared `extern`, cairo is already linked). **Not yet confirmed to compile or run** — see below.
4. dkde-tasks: fixed a **crash when sorting reversed** (`columns.less` returned true both ways on ties, tripping std.sort's assertion; reverse now swaps the arguments). Right-click menu: `contextmenu.noScrollBars()` switches off the scrolled windows inside the PopoverMenu (the double scroll bar). **The scroll bar fix is a guess without a reproduction**; confirm it visually.

## Open / unverified
- `-Dapp=calc,tasks` builds, and both apps start in a private headless compositor with empty stderr (no trace). Clicking is not possible there, so the SVG save, the reversed sort and the right-click menu are still unexercised. Owner's rule: examine the stack trace of every app built.
- Tasks: check the sort in both directions on every column, and the right-click menu for scroll bars.
- Calc: save a graph as .svg and open it; check labels render.
- GOA calendar sync: design points — credentials through GOA (`GetAccessToken` / `GetPassword` on the account's OAuth2Based / PasswordBased interfaces), keep `Account` kind in feeds.zig behind a `kind` key, still no background polling, no writes. Needs a real account to test; none exists here, so use a local CalDAV test server in unit tests like the loopback HTTP test for .ics.

## Gotchas
- **Headless screenshots**: the owner is on X11. Run the private labwc with its own `XDG_RUNTIME_DIR`, or it takes `wayland-0` and kills the owner's apps when stopped (this happened at 19:04). See the memory note `headless-screenshots`.
- `zig build test` prints a "failed command" line even when tests pass; check the exit code.
- Builds are slow while the machine is busy; use `nice` and the background.
- The disk quota on `/tmp/claude-1000` was hit once; clean scratchpad screenshots there if it recurs.

## Update (later, same day)
- Committed and pushed: GOA list, Google calendars through GOA (`gcal.zig`, REST API, GET only; one calendar-list probe done by hand with the owner's OK, event fetching through the app is for the owner to try), calc SVG export, tasks fixes. See docs/decisions/0003.
- Network page: with NetworkManager running (`netpage.available()` asks `nmcli general`), `src/settings/netpage.zig` shows devices, Wi-Fi radio and networks (connect, password, disconnect) and saved connections (connect, disconnect, forget, **Edit** form: autoconnect, IPv4/IPv6 automatic / fixed / off, address, gateway, DNS). Without NM, the old wpa_cli page gets a **Fixed address (IPv4)** section that writes a marked block into /etc/dhcpcd.conf through the elevation dialog. Parsers and checks are in `netparse.zig` (unit tested). Verified: page renders against the real NM with clean stderr; the exact `nmcli connection modify` arguments were run on a throw-away dummy profile (deleted); the dhcpcd rewrite script was run on a scratch file. **Not exercised:** clicking Edit/Save, Connect with a password, Forget, and Apply of the fixed address with the real elevation dialog.
- Not done: VPN profiles, hidden Wi-Fi networks, IPv6 on the dhcpcd path, wired profile creation (NM makes "Wired connection 1" itself).
