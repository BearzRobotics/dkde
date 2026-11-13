# 0003 — Calendars from GNOME Online Accounts (Google first, read-only)

**Status:** IMPLEMENTED 2026-11-12 on `build-and-apps`. Extends 0002.
**Requested by:** the project owner: one place to set up online accounts, built on GOA; all of it optional.

## Decision
- Accounts are set up in GOA's own window (Settings → Accounts → Online accounts opens it). dkde lists them (`src/common/goa.zig`, D-Bus through Gio, no libgoa dependency, never starts the daemon just to list).
- For a **Google** account that signs in with OAuth2, Settings can ask Google which calendars it has and the person ticks the ones to show. Each ticked calendar is an `[account.<id>]` group with `goa` (GOA account id) and `calendar` (Google's id); **no secret is stored**. At a sync, GOA hands out a short-lived access token (`GetAccessToken`) and `src/common/gcal.zig` reads the events with GET requests to the Google Calendar API, turns them into iCalendar text and the rest is the same as a link (cache, repeats, panel reminders). **Sync all** (Settings) and Sync now (calendar) update every chosen calendar.
- Nothing is written to Google, nothing runs in the background, and a request that carries a token follows no redirects.

## Why not CalDAV
CalDAV needs PROPFIND and REPORT, which Zig's `std.http` cannot send (`std.http.Method` has no extension methods). The Google REST API only needs GET and is the way Google's own clients read calendars. Other providers (Nextcloud, Microsoft, password accounts) need either CalDAV over a hand-written HTTP client or their own API; not done.

## Known limits
- Repeating events keep their own clock time (like TZID times in the .ics reader): right when the event's time zone is yours, shifted when it is not. Single events are converted exactly.
- Events 3 years back to 5 ahead, at most 20 pages of 2500 events per calendar.
- Tested: URL/time conversion, calendar-list and event parsing, the reader accepting the result, the GOA account parser. **Not tested by unit tests:** a real Google response (the calendar list was fetched once by hand with the owner's permission; event fetching through the app is for the owner to try).
