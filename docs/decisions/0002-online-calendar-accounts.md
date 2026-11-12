# 0002 — Optional online calendars (read-only .ics subscriptions)

**Status:** IMPLEMENTED 2026-11-12 on `build-and-apps`.
**Requested by:** the project owner: online accounts may sync to dkde-calendar if they are an optional add-on, never intrusive, and managed in the system settings app for all dkde apps.

## 1. Problem

dkde-calendar reads and writes `.ics` files by hand. People also keep calendars on a server (Google, Nextcloud, Fastmail, iCloud, Outlook) and want those events, and their reminders, without exporting files.

## 2. Constraints from the owner

- Optional: with nothing configured, nothing runs, nothing connects, nothing is read.
- Never intrusive: no prompts, no sign-in windows, no background polling nobody asked for.
- Managed in dkde-settings, once, for every dkde app (the calendar and the panel's reminders both use it).

## 3. Decision

An *account* is a private **https link to an iCalendar feed**, stored as an `[account.<id>]` group in the shared `dkde.toml`. The feed is downloaded to `$XDG_CACHE_HOME/dkde/feeds/<id>.ics` and its events are shown next to the user's own, **read-only**.

- Code: `src/common/feeds.zig` (accounts, fetch, cache, loading), `src/common/rrule.zig` (recurrence rules), `ics.parseWith` (feeds: removed, changed and cancelled occurrences), `Event.source` (marks an event as online and read-only).
- UI: `src/settings/onlinepage.zig` (the only place accounts are added, switched or removed); dkde-calendar has Sync now, a start-up update for accounts that asked for it, and a button that opens the settings page.
- Network: `std.http.Client` with the system's root certificates, on a worker thread with its own `std.Io`; https only, three redirects, 8 MB limit, `Accept-Encoding: identity`.

## 4. Alternatives considered

| Option | Why not (now) |
|--------|---------------|
| CalDAV (read/write) | Needs WebDAV XML, discovery (`.well-known`, principals), ETags and sync tokens, conflict handling, and per-server quirks. Writing back would make a bug in dkde change someone's real calendar. Large, and it cannot be tested safely without real accounts. It can be added behind the same `Account` type later (a `kind` key). |
| OAuth sign-in (Google, Microsoft) | Needs a registered client id and secret owned by the project, a browser flow and token refresh: intrusive by nature, and ties dkde to specific vendors. |
| Passwords in the config file | Plain-text secrets in a world-readable file. Not acceptable without a secret store, which DKDE does not have (and the spec does not want a session bus dependency). |
| Shell out to `curl` or `vdirsyncer` | An extra runtime dependency and a process spawn per update; harder to bound and test. |
| Libsoup / GIO | Adds a library the calendar does not otherwise link (SPEC: minimal, justified dependencies); std's client is enough for GET. |

## 5. Consequences

- The secret link sits in `dkde.toml` in the clear. It is documented (man pages, the settings page, `data/dkde.toml`), shown only as its host name, and plain http is refused. A keyring is a possible later step.
- Feed events cannot be edited or deleted in dkde and are left out of Export and the sync file.
- Repeat rules beyond FREQ, INTERVAL, COUNT, UNTIL and weekly BYDAY are approximated as their FREQ. TZID times are taken as local time (existing behaviour of the iCalendar reader). Both are written in dkde-calendar(1), ONLINE CALENDARS.
- Repeats from a feed are expanded for 3 years back and 5 ahead of today, at most 4000 occurrences per rule.
- The panel's reminders do **not** yet include online events (it loads only `calendar.toml`); see §6.

## 6. Not done

- Reminders for online events in the panel (needs the panel to load `feeds.loadAll`, and a way to learn that a copy changed).
- CalDAV, write-back, sign-in flows.
- The Windows build (`win.zig`) has no online calendars.

## 7. Verification

`zig build test`: URL rules, id safety, cached-copy loading, a real HTTP round trip against an in-process local server (success, and 404 rejected), recurrence expansion, and the feed parser (removed, changed, cancelled, endless repeats). Not tested: a real TLS server or any real account.
