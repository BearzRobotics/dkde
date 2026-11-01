//! iCalendar (RFC 5545) reading and writing for calendar events, so the
//! calendar can be exchanged with phones and other programs. Only what dkde
//! has is carried: summary, place, notes, start and end (dates or times), a
//! simple repeat (daily, weekly, monthly, yearly), one reminder and a colour.
//!
//! Times are written as "floating" local times (no zone), which phones show
//! as the same wall-clock time. On reading, times in UTC (a trailing Z) are
//! turned into local time with the converter you pass; a TZID is ignored and
//! the time is taken as local. Repeat details beyond FREQ (INTERVAL, BYDAY,
//! COUNT, UNTIL) are not kept.

const std = @import("std");
const events = @import("events.zig");
const civil = @import("civil.zig");

const Event = events.Event;
const Date = civil.Date;

pub const uid_suffix = "@dkde";

// ---- writing ---------------------------------------------------------------------------------

fn put(list: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(text);
    try list.appendSlice(a, text);
}

/// Appends one content line, folded at 75 bytes with a CRLF and a space.
fn line(list: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    var rest = text;
    var first = true;
    while (true) {
        const limit: usize = if (first) 75 else 74; // a continuation starts with a space
        if (rest.len <= limit) {
            if (!first) try list.append(a, ' ');
            try list.appendSlice(a, rest);
            try list.appendSlice(a, "\r\n");
            return;
        }
        var cut: usize = limit;
        while (cut > 0 and (rest[cut] & 0xC0) == 0x80) cut -= 1; // not inside a UTF-8 sequence
        if (!first) try list.append(a, ' ');
        try list.appendSlice(a, rest[0..cut]);
        try list.appendSlice(a, "\r\n");
        rest = rest[cut..];
        first = false;
    }
}

fn escaped(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '\\' => try out.appendSlice(a, "\\\\"),
        ';' => try out.appendSlice(a, "\\;"),
        ',' => try out.appendSlice(a, "\\,"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => {},
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

fn dateStamp(buf: []u8, d: Date) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{ @as(u32, @intCast(d.year)), d.month, d.day }) catch "";
}

fn dateTimeStamp(buf: []u8, d: Date, minute: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}00", .{ @as(u32, @intCast(d.year)), d.month, d.day, minute / 60, minute % 60 }) catch "";
}

fn trigger(buf: []u8, minutes: i32) []const u8 {
    if (minutes == 0) return "PT0S";
    if (@mod(minutes, 1440) == 0) return std.fmt.bufPrint(buf, "-P{d}D", .{@divExact(minutes, 1440)}) catch "";
    if (@mod(minutes, 60) == 0) return std.fmt.bufPrint(buf, "-PT{d}H", .{@divExact(minutes, 60)}) catch "";
    return std.fmt.bufPrint(buf, "-PT{d}M", .{minutes}) catch "";
}

/// The whole calendar as an iCalendar document. `stamp` is the current UTC
/// time as "20261031T120000Z".
pub fn write(allocator: std.mem.Allocator, list: []const Event, stamp: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try line(&out, allocator, "BEGIN:VCALENDAR");
    try line(&out, allocator, "VERSION:2.0");
    try line(&out, allocator, "PRODID:-//dkde//calendar//EN");
    try line(&out, allocator, "CALSCALE:GREGORIAN");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (list) |ev| {
        _ = arena.reset(.retain_capacity);
        try line(&out, allocator, "BEGIN:VEVENT");
        const uid = if (ev.uid.len > 0) ev.uid else try std.fmt.allocPrint(a, "{s}{s}", .{ ev.id, uid_suffix });
        try line(&out, allocator, try std.fmt.allocPrint(a, "UID:{s}", .{try escaped(a, uid)}));
        try line(&out, allocator, try std.fmt.allocPrint(a, "DTSTAMP:{s}", .{stamp}));
        try line(&out, allocator, try std.fmt.allocPrint(a, "SUMMARY:{s}", .{try escaped(a, ev.title)}));

        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        if (ev.all_day) {
            try line(&out, allocator, try std.fmt.allocPrint(a, "DTSTART;VALUE=DATE:{s}", .{dateStamp(&b1, ev.date)}));
            // The end of an all-day event is the day after its last day.
            try line(&out, allocator, try std.fmt.allocPrint(a, "DTEND;VALUE=DATE:{s}", .{dateStamp(&b2, ev.end_date.addDays(1))}));
        } else {
            try line(&out, allocator, try std.fmt.allocPrint(a, "DTSTART:{s}", .{dateTimeStamp(&b1, ev.date, ev.start)}));
            try line(&out, allocator, try std.fmt.allocPrint(a, "DTEND:{s}", .{dateTimeStamp(&b2, ev.end_date, ev.end)}));
        }
        switch (ev.repeat) {
            .none => {},
            else => try line(&out, allocator, try std.fmt.allocPrint(a, "RRULE:FREQ={s}", .{upper(a, ev.repeat.name())})),
        }
        if (ev.location.len > 0) try line(&out, allocator, try std.fmt.allocPrint(a, "LOCATION:{s}", .{try escaped(a, ev.location)}));
        if (ev.notes.len > 0) try line(&out, allocator, try std.fmt.allocPrint(a, "DESCRIPTION:{s}", .{try escaped(a, ev.notes)}));
        if (ev.color != .default) try line(&out, allocator, try std.fmt.allocPrint(a, "COLOR:{s}", .{ev.color.name()}));
        if (ev.remind >= 0) {
            var tb: [24]u8 = undefined;
            try line(&out, allocator, "BEGIN:VALARM");
            try line(&out, allocator, "ACTION:DISPLAY");
            try line(&out, allocator, "DESCRIPTION:Reminder");
            try line(&out, allocator, try std.fmt.allocPrint(a, "TRIGGER:{s}", .{trigger(&tb, ev.remind)}));
            try line(&out, allocator, "END:VALARM");
        }
        try line(&out, allocator, "END:VEVENT");
    }
    try line(&out, allocator, "END:VCALENDAR");
    return out.toOwnedSlice(allocator);
}

fn upper(a: std.mem.Allocator, text: []const u8) []const u8 {
    const out = a.alloc(u8, text.len) catch return text;
    for (text, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

// ---- reading ---------------------------------------------------------------------------------

/// Turns minutes since 1970 in UTC into the same in local time.
pub const UtcToLocal = *const fn (utc_minutes: i64) i64;

fn identity(m: i64) i64 {
    return m;
}

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    events: []Event,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

const Stamp = struct { date: Date, minute: u16, all_day: bool };

fn parseStamp(text: []const u8, utc_to_local: UtcToLocal) ?Stamp {
    if (text.len < 8) return null;
    const y = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, text[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, text[6..8], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > civil.daysInMonth(y, mo)) return null;
    var date: Date = .{ .year = y, .month = mo, .day = d };
    if (text.len < 15 or text[8] != 'T') return .{ .date = date, .minute = 0, .all_day = true };
    const h = std.fmt.parseInt(u16, text[9..11], 10) catch return null;
    const mi = std.fmt.parseInt(u16, text[11..13], 10) catch return null;
    if (h > 23 or mi > 59) return null;
    var minute: u16 = h * 60 + mi;
    if (text[text.len - 1] == 'Z') {
        const local = utc_to_local(date.days() * 1440 + minute);
        date = Date.fromDays(@divFloor(local, 1440));
        minute = @intCast(@mod(local, 1440));
    }
    return .{ .date = date, .minute = minute, .all_day = false };
}

/// "-PT15M", "-P1D", "-P1DT2H30M", "PT0S": minutes before the start, or null
/// when the trigger is after the start or unreadable.
fn parseTrigger(text: []const u8) ?i32 {
    var s = text;
    var negative = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0 or s[0] != 'P') return null;
    s = s[1..];
    var total: i64 = 0;
    var in_time = false;
    var num: i64 = 0;
    var have = false;
    for (s) |c| {
        switch (c) {
            'T' => in_time = true,
            '0'...'9' => {
                num = num * 10 + (c - '0');
                have = true;
            },
            'W', 'D', 'H', 'M', 'S' => {
                if (!have) return null;
                total += switch (c) {
                    'W' => num * 7 * 1440,
                    'D' => num * 1440,
                    'H' => num * 60,
                    'M' => if (in_time) num else return null,
                    else => @divFloor(num, 60),
                };
                num = 0;
                have = false;
            },
            else => return null,
        }
    }
    if (total == 0) return 0;
    if (!negative) return null;
    return @intCast(@min(total, events.max_remind));
}

fn unescape(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            try out.append(a, switch (text[i]) {
                'n', 'N' => '\n',
                else => text[i],
            });
        } else try out.append(a, text[i]);
    }
    return out.toOwnedSlice(a);
}

const Draft = struct {
    uid: []const u8 = "",
    title: []const u8 = "",
    location: []const u8 = "",
    notes: []const u8 = "",
    start: ?Stamp = null,
    end: ?Stamp = null,
    repeat: events.Repeat = .none,
    color: events.Color = .default,
    remind: i32 = -1,
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8, utc_to_local: ?UtcToLocal) !Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const convert = utc_to_local orelse identity;

    // Unfold: a line that starts with a space or tab continues the one before.
    var unfolded: std.ArrayList(u8) = .empty;
    var raw = std.mem.splitScalar(u8, text, '\n');
    while (raw.next()) |l0| {
        const l = std.mem.trimEnd(u8, l0, "\r");
        if (l.len > 0 and (l[0] == ' ' or l[0] == '\t') and unfolded.items.len > 0) {
            try unfolded.appendSlice(a, l[1..]);
        } else {
            if (unfolded.items.len > 0) try unfolded.append(a, '\n');
            try unfolded.appendSlice(a, l);
        }
    }

    var result: std.ArrayList(Event) = .empty;
    var draft: Draft = .{};
    var in_event = false;
    var in_alarm = false;

    var lines = std.mem.splitScalar(u8, unfolded.items, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        // NAME;PARAM=x:value, where a colon inside quotes does not count.
        var colon: ?usize = null;
        var quoted = false;
        for (l, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (c == ':' and !quoted) {
                colon = i;
                break;
            }
        }
        const sep = colon orelse continue;
        const head = l[0..sep];
        const value = l[sep + 1 ..];
        const name_end = std.mem.indexOfScalar(u8, head, ';') orelse head.len;
        const name = head[0..name_end];

        if (std.ascii.eqlIgnoreCase(name, "BEGIN")) {
            if (std.ascii.eqlIgnoreCase(value, "VEVENT")) {
                in_event = true;
                draft = .{};
            } else if (std.ascii.eqlIgnoreCase(value, "VALARM")) in_alarm = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "END")) {
            if (std.ascii.eqlIgnoreCase(value, "VALARM")) {
                in_alarm = false;
            } else if (std.ascii.eqlIgnoreCase(value, "VEVENT") and in_event) {
                in_event = false;
                const start = draft.start orelse continue; // no start, no event
                var end = draft.end orelse start;
                var end_date = end.date;
                if (start.all_day) {
                    // An all-day end is exclusive.
                    end_date = if (draft.end != null) end.date.addDays(-1) else start.date;
                    end = .{ .date = end_date, .minute = 0, .all_day = true };
                }
                if (end_date.days() < start.date.days()) end_date = start.date;
                var end_minute: u16 = end.minute;
                if (!start.all_day and draft.end == null) end_minute = @min(start.minute + 60, 23 * 60 + 59);
                if (!start.all_day and end_date.eql(start.date) and end_minute < start.minute) end_minute = start.minute;
                try result.append(a, .{
                    .id = "",
                    .uid = draft.uid,
                    .title = draft.title,
                    .location = draft.location,
                    .notes = draft.notes,
                    .date = start.date,
                    .end_date = end_date,
                    .all_day = start.all_day,
                    .start = start.minute,
                    .end = end_minute,
                    .repeat = draft.repeat,
                    .color = draft.color,
                    .remind = draft.remind,
                });
            }
            continue;
        }
        if (!in_event) continue;

        if (in_alarm) {
            if (std.ascii.eqlIgnoreCase(name, "TRIGGER") and draft.remind < 0) {
                if (parseTrigger(value)) |m| draft.remind = m;
            }
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "UID")) {
            draft.uid = try unescape(a, value);
        } else if (std.ascii.eqlIgnoreCase(name, "SUMMARY")) {
            draft.title = try unescape(a, value);
        } else if (std.ascii.eqlIgnoreCase(name, "LOCATION")) {
            draft.location = try unescape(a, value);
        } else if (std.ascii.eqlIgnoreCase(name, "DESCRIPTION")) {
            draft.notes = try unescape(a, value);
        } else if (std.ascii.eqlIgnoreCase(name, "DTSTART")) {
            draft.start = parseStamp(value, convert);
        } else if (std.ascii.eqlIgnoreCase(name, "DTEND")) {
            draft.end = parseStamp(value, convert);
        } else if (std.ascii.eqlIgnoreCase(name, "RRULE")) {
            draft.repeat = parseRule(value);
        } else if (std.ascii.eqlIgnoreCase(name, "COLOR")) {
            draft.color = events.Color.parse(lower(a, value));
        }
    }
    return .{ .arena = arena, .events = try result.toOwnedSlice(a) };
}

fn lower(a: std.mem.Allocator, text: []const u8) []const u8 {
    const out = a.alloc(u8, text.len) catch return text;
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn parseRule(value: []const u8) events.Repeat {
    var parts = std.mem.splitScalar(u8, value, ';');
    while (parts.next()) |p| {
        if (!std.ascii.startsWithIgnoreCase(p, "FREQ=")) continue;
        const f = p[5..];
        if (std.ascii.eqlIgnoreCase(f, "DAILY")) return .daily;
        if (std.ascii.eqlIgnoreCase(f, "WEEKLY")) return .weekly;
        if (std.ascii.eqlIgnoreCase(f, "MONTHLY")) return .monthly;
        if (std.ascii.eqlIgnoreCase(f, "YEARLY")) return .yearly;
    }
    return .none;
}

/// A stable event id for an imported UID: the id part of "<id>@dkde", else a
/// hash of the UID, so importing the same file twice finds the same events.
pub fn idForUid(buf: []u8, uid: []const u8) []const u8 {
    if (std.mem.endsWith(u8, uid, uid_suffix)) {
        const head = uid[0 .. uid.len - uid_suffix.len];
        if (head.len > 0 and head.len <= buf.len) {
            var all_hex = true;
            for (head) |c| if (!std.ascii.isHex(c)) {
                all_hex = false;
            };
            if (all_hex) {
                @memcpy(buf[0..head.len], head);
                return buf[0..head.len];
            }
        }
    }
    const h = std.hash.Fnv1a_64.hash(uid);
    return std.fmt.bufPrint(buf, "i{x}", .{h}) catch "i0";
}

// ---- tests -----------------------------------------------------------------------------------

test "write and read back" {
    const a = std.testing.allocator;
    const list = [_]Event{
        .{ .id = "ab12", .title = "Mass, Sunday; \"early\"", .location = "St. Mary's\nMain St", .notes = "Bring the book\\ok", .date = .{ .year = 2026, .month = 11, .day = 1 }, .end_date = .{ .year = 2026, .month = 11, .day = 1 }, .start = 8 * 60 + 30, .end = 9 * 60 + 30, .repeat = .weekly, .color = .purple, .remind = 30 },
        .{ .id = "cd34", .title = "Retreat", .date = .{ .year = 2026, .month = 12, .day = 30 }, .end_date = .{ .year = 2027, .month = 1, .day = 2 }, .all_day = true, .remind = 1440 },
    };
    const text = try write(a, &list, "20261031T120000Z");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "DTEND;VALUE=DATE:20270103") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "TRIGGER:-P1D") != null);
    var parsed = try parse(a, text, null);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.events.len);
    const e0 = parsed.events[0];
    try std.testing.expectEqualStrings("Mass, Sunday; \"early\"", e0.title);
    try std.testing.expectEqualStrings("St. Mary's\nMain St", e0.location);
    try std.testing.expectEqualStrings("Bring the book\\ok", e0.notes);
    try std.testing.expectEqual(@as(u16, 8 * 60 + 30), e0.start);
    try std.testing.expectEqual(events.Repeat.weekly, e0.repeat);
    try std.testing.expectEqual(events.Color.purple, e0.color);
    try std.testing.expectEqual(@as(i32, 30), e0.remind);
    try std.testing.expectEqualStrings("ab12@dkde", e0.uid);
    const e1 = parsed.events[1];
    try std.testing.expect(e1.all_day);
    try std.testing.expect(e1.end_date.eql(.{ .year = 2027, .month = 1, .day = 2 }));
    try std.testing.expectEqual(@as(i32, 1440), e1.remind);
}

test "long lines fold at 75 bytes and unfold again" {
    const a = std.testing.allocator;
    var long_buf: [160]u8 = undefined;
    for (0..80) |i| @memcpy(long_buf[i * 2 ..][0..2], "é");
    const long: []const u8 = &long_buf;
    const list = [_]Event{.{ .id = "1", .title = long, .date = .{ .year = 2026, .month = 1, .day = 1 }, .end_date = .{ .year = 2026, .month = 1, .day = 1 } }};
    const text = try write(a, &list, "20260101T000000Z");
    defer a.free(text);
    var rows = std.mem.splitSequence(u8, text, "\r\n");
    while (rows.next()) |r| try std.testing.expect(r.len <= 75);
    var parsed = try parse(a, text, null);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(long, parsed.events[0].title);
}

fn plusFiveHours(m: i64) i64 {
    return m + 5 * 60;
}

test "reading what a phone writes" {
    const a = std.testing.allocator;
    const text =
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTIMEZONE\r\nTZID:X\r\nEND:VTIMEZONE\r\n" ++
        "BEGIN:VEVENT\r\nUID:abc-123\r\nDTSTART:20261105T230000Z\r\nDTEND:20261106T003000Z\r\n" ++
        "SUMMARY:Call\r\nRRULE:FREQ=MONTHLY;INTERVAL=2;COUNT=5\r\n" ++
        "BEGIN:VALARM\r\nTRIGGER:-PT1H30M\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\n" ++
        "BEGIN:VEVENT\r\nSUMMARY:No start\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    var parsed = try parse(a, text, plusFiveHours);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.events.len);
    const e = parsed.events[0];
    // 23:00 UTC + 5 h = 04:00 the next day, local.
    try std.testing.expect(e.date.eql(.{ .year = 2026, .month = 11, .day = 6 }));
    try std.testing.expectEqual(@as(u16, 4 * 60), e.start);
    try std.testing.expectEqual(events.Repeat.monthly, e.repeat);
    try std.testing.expectEqual(@as(i32, 90), e.remind);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ab12", idForUid(&buf, "ab12@dkde"));
    try std.testing.expect(idForUid(&buf, "abc-123").len > 1);
}
