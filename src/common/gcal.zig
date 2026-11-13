//! Google Calendar through a GNOME Online Accounts sign-in: read-only.
//!
//! The access token comes from GOA (goa.zig); this file only asks Google's Calendar
//! API (https://developers.google.com/calendar/api, GET requests only) which
//! calendars the account has, and for the events of the ones the person chose. The
//! events are turned into iCalendar text so everything after that (the cached copy,
//! repeats, the calendar view, the panel's reminders) is the same as for an .ics link.
//!
//! Why the REST API and not CalDAV: CalDAV needs the PROPFIND and REPORT methods,
//! which Zig's HTTP client cannot send. Other providers (Nextcloud, Microsoft) are not
//! done; see docs/decisions/0003.
//!
//! Nothing here is written to Google: no request other than GET is ever made.

const std = @import("std");
const civil = @import("civil.zig");
const feeds = @import("feeds.zig");

const api = "https://www.googleapis.com/calendar/v3";

pub const Calendar = struct { id: []const u8, name: []const u8 };

pub const Calendars = struct {
    arena: std.heap.ArenaAllocator,
    items: []Calendar,

    pub fn deinit(self: *Calendars) void {
        self.arena.deinit();
    }
};

/// Percent-encodes `s` for one path segment or query value.
fn encode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else try out.print(allocator, "%{X:0>2}", .{c});
    }
    return out.toOwnedSlice(allocator);
}

/// The calendars the account can read (its own, subscribed ones, holidays...).
/// Blocks: call from a worker thread.
pub fn listCalendars(allocator: std.mem.Allocator, token: []const u8) !Calendars {
    const body = try feeds.fetchWith(allocator, api ++ "/users/me/calendarList?minAccessRole=reader&maxResults=250&fields=items(id,summary,summaryOverride)", token, "application/json");
    defer allocator.free(body);
    return parseCalendars(allocator, body);
}

fn parseCalendars(allocator: std.mem.Allocator, body: []const u8) !Calendars {
    const Entry = struct { id: []const u8 = "", summary: []const u8 = "", summaryOverride: []const u8 = "" };
    const ListPage = struct { items: []const Entry = &.{} };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const page = std.json.parseFromSliceLeaky(ListPage, a, body, .{ .ignore_unknown_fields = true }) catch return error.NotACalendar;
    var list: std.ArrayList(Calendar) = .empty;
    for (page.items) |it| {
        if (it.id.len == 0) continue;
        const name = if (it.summaryOverride.len > 0) it.summaryOverride else if (it.summary.len > 0) it.summary else it.id;
        try list.append(a, .{ .id = it.id, .name = name });
    }
    return .{ .arena = arena, .items = try list.toOwnedSlice(a) };
}

/// The events of one calendar around today as iCalendar text. Blocks.
pub fn fetchIcs(allocator: std.mem.Allocator, token: []const u8, calendar_id: []const u8, now_days: i64) ![]u8 {
    const id = try encode(allocator, calendar_id);
    defer allocator.free(id);
    const from = civil.civilFromDays(now_days - feeds.window_back_days);
    const to = civil.civilFromDays(now_days + feeds.window_forward_days);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//dkde//Google Calendar//EN\r\n");

    var page_token: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(page_token);
    var pages: u8 = 0;
    while (pages < 20) : (pages += 1) {
        const tok_q = if (page_token.len > 0) try encode(allocator, page_token) else try allocator.dupe(u8, "");
        defer allocator.free(tok_q);
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/calendars/{s}/events?singleEvents=false&showDeleted=true&maxResults=2500&timeMin={d:0>4}-{d:0>2}-{d:0>2}T00%3A00%3A00Z&timeMax={d:0>4}-{d:0>2}-{d:0>2}T00%3A00%3A00Z" ++
                "&fields=nextPageToken,items(id,status,iCalUID,summary,description,location,start,end,recurrence,recurringEventId,originalStartTime){s}{s}",
            .{ api, id, @as(u32, @intCast(from.year)), from.month, from.day, @as(u32, @intCast(to.year)), to.month, to.day, if (tok_q.len > 0) "&pageToken=" else "", tok_q },
        );
        defer allocator.free(url);
        const body = try feeds.fetchWith(allocator, url, token, "application/json");
        defer allocator.free(body);
        const next = try appendEvents(allocator, &out, body);
        allocator.free(page_token);
        page_token = next;
        if (page_token.len == 0) break;
    }
    try out.appendSlice(allocator, "END:VCALENDAR\r\n");
    return out.toOwnedSlice(allocator);
}

const Time = struct { date: []const u8 = "", dateTime: []const u8 = "", timeZone: []const u8 = "" };
const Item = struct {
    id: []const u8 = "",
    status: []const u8 = "",
    iCalUID: []const u8 = "",
    summary: []const u8 = "",
    description: []const u8 = "",
    location: []const u8 = "",
    start: Time = .{},
    end: Time = .{},
    recurrence: []const []const u8 = &.{},
    recurringEventId: []const u8 = "",
    originalStartTime: Time = .{},
};
const Page = struct { items: []const Item = &.{}, nextPageToken: []const u8 = "" };

/// Appends the VEVENTs of one page of Google's answer to `out`; returns the next page's
/// token (owned by `allocator`, empty when this was the last page).
fn appendEvents(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const page = std.json.parseFromSliceLeaky(Page, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch return error.NotACalendar;
    for (page.items) |it| try appendEvent(allocator, out, it);
    return allocator.dupe(u8, page.nextPageToken);
}

fn text(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try out.appendSlice(allocator, name);
    try out.append(allocator, ':');
    for (value) |c| switch (c) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        ';' => try out.appendSlice(allocator, "\\;"),
        ',' => try out.appendSlice(allocator, "\\,"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => {},
        else => try out.append(allocator, c),
    };
    try out.appendSlice(allocator, "\r\n");
}

fn digits(s: []const u8, from: usize, n: usize) ?i64 {
    if (from + n > s.len) return null;
    var v: i64 = 0;
    for (s[from .. from + n]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// "2026-11-12T10:30:00-05:00" as "20261112T153000Z" (the same moment in UTC); null when
/// it is not in that form.
fn utcFromRfc3339(buf: *[16]u8, s: []const u8) ?[]const u8 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':') return null;
    const y = digits(s, 0, 4) orelse return null;
    const mo = digits(s, 5, 2) orelse return null;
    const d = digits(s, 8, 2) orelse return null;
    const h = digits(s, 11, 2) orelse return null;
    const mi = digits(s, 14, 2) orelse return null;
    const se = digits(s, 17, 2) orelse return null;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    }
    if (i >= s.len) return null;
    var offset: i64 = 0;
    if (s[i] == 'Z' or s[i] == 'z') {} else if (s[i] == '+' or s[i] == '-') {
        const oh = digits(s, i + 1, 2) orelse return null;
        const om = digits(s, i + 4, 2) orelse return null;
        offset = (oh * 60 + om) * 60;
        if (s[i] == '-') offset = -offset;
    } else return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    const secs = civil.daysFromCivil(@intCast(y), @intCast(mo), @intCast(d)) * 86400 + h * 3600 + mi * 60 + se - offset;
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400;
    const dt = civil.civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u32, @intCast(dt.year)), dt.month, dt.day, @as(u32, @intCast(@divFloor(rem, 3600))), @as(u32, @intCast(@divFloor(@mod(rem, 3600), 60))), @as(u32, @intCast(@mod(rem, 60))),
    }) catch null;
}

/// Writes `name` with a Google time. A repeating event keeps its own clock time (floating,
/// like the iCalendar reader's TZID times), so its repeats stay at the same hour across
/// daylight saving; a single event is converted to UTC and shown at the right local time.
fn writeTime(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, t: Time, floating: bool) !bool {
    if (t.date.len == 10) {
        const y = digits(t.date, 0, 4) orelse return false;
        const mo = digits(t.date, 5, 2) orelse return false;
        const d = digits(t.date, 8, 2) orelse return false;
        try out.print(allocator, "{s};VALUE=DATE:{d:0>4}{d:0>2}{d:0>2}\r\n", .{ name, @as(u32, @intCast(y)), @as(u32, @intCast(mo)), @as(u32, @intCast(d)) });
        return true;
    }
    if (t.dateTime.len < 20) return false;
    if (floating) {
        const s = t.dateTime;
        const y = digits(s, 0, 4) orelse return false;
        const mo = digits(s, 5, 2) orelse return false;
        const d = digits(s, 8, 2) orelse return false;
        const h = digits(s, 11, 2) orelse return false;
        const mi = digits(s, 14, 2) orelse return false;
        const se = digits(s, 17, 2) orelse return false;
        try out.print(allocator, "{s}:{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}\r\n", .{ name, @as(u32, @intCast(y)), @as(u32, @intCast(mo)), @as(u32, @intCast(d)), @as(u32, @intCast(h)), @as(u32, @intCast(mi)), @as(u32, @intCast(se)) });
        return true;
    }
    var buf: [16]u8 = undefined;
    const utc = utcFromRfc3339(&buf, t.dateTime) orelse return false;
    try out.print(allocator, "{s}:{s}\r\n", .{ name, utc });
    return true;
}

fn appendEvent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), it: Item) !void {
    const is_exception = it.recurringEventId.len > 0;
    const cancelled = std.mem.eql(u8, it.status, "cancelled");
    if (cancelled and !is_exception) return; // deleted for good
    const floating = is_exception or it.recurrence.len > 0;
    const uid = if (it.iCalUID.len > 0) it.iCalUID else it.id;
    if (uid.len == 0) return;

    // Build the event aside: an event that cannot be read is left out whole.
    var ev: std.ArrayList(u8) = .empty;
    defer ev.deinit(allocator);
    try ev.appendSlice(allocator, "BEGIN:VEVENT\r\n");
    try text(allocator, &ev, "UID", uid);
    if (is_exception) {
        if (!try writeTime(allocator, &ev, "RECURRENCE-ID", it.originalStartTime, true)) return;
    }
    const start = if (cancelled and it.start.date.len == 0 and it.start.dateTime.len == 0) it.originalStartTime else it.start;
    if (!try writeTime(allocator, &ev, "DTSTART", start, floating)) return;
    if (!cancelled) _ = try writeTime(allocator, &ev, "DTEND", it.end, floating);
    try text(allocator, &ev, "SUMMARY", if (it.summary.len > 0) it.summary else "(No title)");
    try text(allocator, &ev, "LOCATION", it.location);
    try text(allocator, &ev, "DESCRIPTION", it.description);
    if (cancelled) try ev.appendSlice(allocator, "STATUS:CANCELLED\r\n");
    for (it.recurrence) |line| {
        if (std.mem.indexOfAny(u8, line, "\r\n") != null) continue;
        const known = [_][]const u8{ "RRULE:", "EXDATE", "RDATE" };
        for (known) |k| if (std.ascii.startsWithIgnoreCase(line, k)) {
            try ev.appendSlice(allocator, line);
            try ev.appendSlice(allocator, "\r\n");
            break;
        };
    }
    try ev.appendSlice(allocator, "END:VEVENT\r\n");
    try out.appendSlice(allocator, ev.items);
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "times: offsets become UTC, dates stay dates" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("20261112T153000Z", utcFromRfc3339(&b, "2026-11-12T10:30:00-05:00").?);
    try testing.expectEqualStrings("20261113T013000Z", utcFromRfc3339(&b, "2026-11-12T20:30:00-05:00").?);
    try testing.expectEqualStrings("20261231T233000Z", utcFromRfc3339(&b, "2027-01-01T01:30:00.250+02:00").?);
    try testing.expectEqualStrings("20260301T000000Z", utcFromRfc3339(&b, "2026-03-01T00:00:00Z").?);
    try testing.expect(utcFromRfc3339(&b, "yesterday") == null);
    try testing.expect(utcFromRfc3339(&b, "2026-11-12T10:30:00") == null);
}

test "calendars list: names, overrides, and junk" {
    var c = try parseCalendars(testing.allocator,
        \\{"items":[{"id":"a@x.org","summary":"a@x.org"},{"id":"h","summary":"Holidays","summaryOverride":"Feiertage"},{"summary":"no id"}]}
    );
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.items.len);
    try testing.expectEqualStrings("Feiertage", c.items[1].name);
    try testing.expectError(error.NotACalendar, parseCalendars(testing.allocator, "<html>"));
}

test "events become iCalendar the existing reader understands" {
    const ics = @import("ics.zig");
    const json =
        \\{"items":[
        \\ {"id":"1","iCalUID":"one@google.com","summary":"Dentist; 2nd, visit","location":"Main St",
        \\  "start":{"dateTime":"2026-11-12T10:30:00-05:00"},"end":{"dateTime":"2026-11-12T11:30:00-05:00"}},
        \\ {"id":"2","iCalUID":"day@google.com","summary":"Holiday","start":{"date":"2026-11-26"},"end":{"date":"2026-11-27"}},
        \\ {"id":"3","iCalUID":"week@google.com","summary":"Standup","recurrence":["RRULE:FREQ=WEEKLY;COUNT=3","EXDATE;TZID=America/New_York:20261119T090000"],
        \\  "start":{"dateTime":"2026-11-12T09:00:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-11-12T09:15:00-05:00","timeZone":"America/New_York"}},
        \\ {"id":"4","status":"cancelled"},
        \\ {"id":"5","iCalUID":"x","status":"cancelled","recurringEventId":"3","originalStartTime":{"dateTime":"2026-11-26T09:00:00-05:00"}}
        \\],"nextPageToken":"more"}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, "BEGIN:VCALENDAR\r\n");
    const next = try appendEvents(testing.allocator, &out, json);
    defer testing.allocator.free(next);
    try testing.expectEqualStrings("more", next);
    try out.appendSlice(testing.allocator, "END:VCALENDAR\r\n");
    try testing.expect(std.mem.indexOf(u8, out.items, "SUMMARY:Dentist\\; 2nd\\, visit") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "DTSTART:20261112T153000Z") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "DTSTART;VALUE=DATE:20261126") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "DTSTART:20261112T090000\r\n") != null); // repeats keep their clock time

    const w: ics.Window = .{ .from = .{ .year = 2026, .month = 1, .day = 1 }, .to = .{ .year = 2027, .month = 1, .day = 1 } };
    var parsed = try ics.parseWith(testing.allocator, out.items, null, .{ .window = w });
    defer parsed.deinit();
    // dentist, holiday, standup on 12 Nov and 26 Nov (19 Nov excluded, 26 Nov cancelled -> only Nov 12 + Dec 3 are within COUNT=3: 12, 19x, 26x, so 1)
    try testing.expect(parsed.events.len >= 3);
}
