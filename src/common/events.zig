//! Calendar events: what is stored, which days an event falls on, and when its
//! reminder fires (SPEC.md 5.6, dkde-calendar). Events live in
//! `~/.config/dkde/calendar.conf` as `[event.<id>]` groups, so the calendar app
//! writes them and the panel, which sends the reminders, reads the same file.
//!
//! Times are local wall-clock time with no zone arithmetic: a "minute" is
//! `days since 1970-01-01 * 1440 + minute of day`, the way a clock on the wall
//! reads it.

const std = @import("std");
const civil = @import("civil.zig");
const config_mod = @import("config.zig");

pub const Date = civil.Date;

pub const Repeat = enum {
    none,
    daily,
    weekly,
    monthly,
    yearly,

    pub fn name(self: Repeat) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) Repeat {
        return std.meta.stringToEnum(Repeat, text) orelse .none;
    }
};

/// A label colour for an event. `default` uses the accent colour.
pub const Color = enum {
    default,
    red,
    orange,
    yellow,
    green,
    teal,
    blue,
    purple,
    pink,
    gray,

    pub fn name(self: Color) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) Color {
        return std.meta.stringToEnum(Color, text) orelse .default;
    }

    pub fn cssClass(self: Color) []const u8 {
        return switch (self) {
            .default => "ev-default",
            .red => "ev-red",
            .orange => "ev-orange",
            .yellow => "ev-yellow",
            .green => "ev-green",
            .teal => "ev-teal",
            .blue => "ev-blue",
            .purple => "ev-purple",
            .pink => "ev-pink",
            .gray => "ev-gray",
        };
    }
};

pub const Event = struct {
    id: []const u8,
    title: []const u8,
    location: []const u8 = "",
    notes: []const u8 = "",
    /// First day, and last day (the same day unless the event spans days).
    date: Date,
    end_date: Date,
    all_day: bool = false,
    /// Minutes after midnight.
    start: u16 = 9 * 60,
    end: u16 = 10 * 60,
    repeat: Repeat = .none,
    color: Color = .default,
    /// Minutes before the start to send a reminder; negative for none.
    remind: i32 = -1,
};

/// An all-day event's reminder counts back from this time of day.
pub const all_day_reminder_minute: u16 = 9 * 60;

/// The longest lead time a reminder may have (one week).
pub const max_remind: i32 = 7 * 24 * 60;

// ---- text forms ------------------------------------------------------------------------------

pub fn parseDate(text: []const u8) ?Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return null;
    const y = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > civil.daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

pub fn formatDate(buf: []u8, date: Date) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(date.year)), date.month, date.day }) catch "";
}

pub fn parseTime(text: []const u8) ?u16 {
    if (text.len != 5 or text[2] != ':') return null;
    const h = std.fmt.parseInt(u16, text[0..2], 10) catch return null;
    const m = std.fmt.parseInt(u16, text[3..5], 10) catch return null;
    if (h > 23 or m > 59) return null;
    return h * 60 + m;
}

pub fn formatTime(buf: []u8, minute: u16) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minute / 60, minute % 60 }) catch "";
}

/// "2:30 PM" for the 12-hour clock.
pub fn formatTime12(buf: []u8, minute: u16) []const u8 {
    const h24 = minute / 60;
    const h12 = if (h24 % 12 == 0) 12 else h24 % 12;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ h12, minute % 60, if (h24 < 12) "AM" else "PM" }) catch "";
}

/// The time in the clock style the user chose.
pub fn formatClock(buf: []u8, minute: u16, twelve_hour: bool) []const u8 {
    return if (twelve_hour) formatTime12(buf, minute) else formatTime(buf, minute);
}

// ---- which days an event falls on ----------------------------------------------------------

fn spanDays(ev: *const Event) i64 {
    return @max(0, ev.end_date.days() - ev.date.days());
}

/// Whether an occurrence of `ev` begins on `d`.
pub fn startsOn(ev: *const Event, d: Date) bool {
    const dn = d.days();
    const first = ev.date.days();
    if (dn < first) return false;
    return switch (ev.repeat) {
        .none => dn == first,
        .daily => true,
        .weekly => @mod(dn - first, 7) == 0,
        .monthly => d.day == ev.date.day,
        .yearly => d.day == ev.date.day and d.month == ev.date.month,
    };
}

/// Whether `ev` is on at all during day `d` (an occurrence may span days).
pub fn occursOn(ev: *const Event, d: Date) bool {
    var back: i64 = 0;
    const span = spanDays(ev);
    while (back <= span) : (back += 1) {
        if (startsOn(ev, d.addDays(-back))) return true;
    }
    return false;
}

// ---- reminders -------------------------------------------------------------------------------

pub const Fire = struct {
    event: usize,
    /// When the reminder is due, in minutes (see the top of this file).
    at: i64,
    /// The day the occurrence it is about begins.
    start: Date,
};

fn startMinute(ev: *const Event) i64 {
    return if (ev.all_day) all_day_reminder_minute else ev.start;
}

/// The reminders due in `(after, upto]`, in time order.
pub fn firesBetween(allocator: std.mem.Allocator, events: []const Event, after: i64, upto: i64) ![]Fire {
    var out: std.ArrayList(Fire) = .empty;
    errdefer out.deinit(allocator);
    const first_day = @divFloor(after, 1440);
    const last_day = @divFloor(upto, 1440) + @divFloor(max_remind, 1440) + 1;
    for (events, 0..) |*ev, i| {
        if (ev.remind < 0) continue;
        const lead: i64 = @min(ev.remind, max_remind);
        var dn = first_day;
        while (dn <= last_day) : (dn += 1) {
            const d = Date.fromDays(dn);
            if (!startsOn(ev, d)) continue;
            const at = dn * 1440 + startMinute(ev) - lead;
            if (at > after and at <= upto) try out.append(allocator, .{ .event = i, .at = at, .start = d });
        }
    }
    std.mem.sort(Fire, out.items, {}, struct {
        fn less(_: void, a: Fire, b: Fire) bool {
            return a.at < b.at;
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

/// The time of the next reminder after `after`, looking at most `horizon_days` ahead.
pub fn nextFire(events: []const Event, after: i64, horizon_days: i64) ?i64 {
    var best: ?i64 = null;
    const first_day = @divFloor(after, 1440);
    for (events) |*ev| {
        if (ev.remind < 0) continue;
        const lead: i64 = @min(ev.remind, max_remind);
        var dn = first_day;
        const last = first_day + horizon_days + @divFloor(max_remind, 1440) + 1;
        while (dn <= last) : (dn += 1) {
            if (best) |b| if (dn * 1440 > b + max_remind) break;
            if (!startsOn(ev, Date.fromDays(dn))) continue;
            const at = dn * 1440 + startMinute(ev) - lead;
            if (at > after and (best == null or at < best.?)) {
                best = at;
                break;
            }
        }
    }
    return best;
}

// ---- the stored list -------------------------------------------------------------------------

pub const group_prefix = "event.";

/// All the events in a config, owned by an arena.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Event,

    pub fn deinit(self: *List) void {
        self.arena.deinit();
    }

    pub fn find(self: *const List, id: []const u8) ?*const Event {
        for (self.items) |*ev| if (std.mem.eql(u8, ev.id, id)) return ev;
        return null;
    }
};

pub fn load(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !List {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const ids = try cfg.groupsWithPrefix(allocator, group_prefix);
    defer config_mod.freeStringList(allocator, ids);

    var items: std.ArrayList(Event) = .empty;
    for (ids) |id| {
        const group = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ group_prefix, id }, 0);
        defer allocator.free(group);
        const date_text = try cfg.getString(allocator, group, "date", "");
        defer allocator.free(date_text);
        const date = parseDate(date_text) orelse continue; // not an event we understand
        const end_text = try cfg.getString(allocator, group, "end-date", "");
        defer allocator.free(end_text);
        var end_date = parseDate(end_text) orelse date;
        if (end_date.days() < date.days()) end_date = date;
        const start_text = try cfg.getString(allocator, group, "start", "09:00");
        defer allocator.free(start_text);
        const end_time_text = try cfg.getString(allocator, group, "end", "10:00");
        defer allocator.free(end_time_text);
        const repeat_text = try cfg.getString(allocator, group, "repeat", "none");
        defer allocator.free(repeat_text);
        const color_text = try cfg.getString(allocator, group, "color", "default");
        defer allocator.free(color_text);
        const title = try cfg.getString(a, group, "title", "");
        const location = try cfg.getString(a, group, "location", "");
        const notes = try cfg.getString(a, group, "notes", "");
        try items.append(a, .{
            .id = try a.dupe(u8, id),
            .title = title,
            .location = location,
            .notes = notes,
            .date = date,
            .end_date = end_date,
            .all_day = cfg.getBool(group, "all-day", false),
            .start = parseTime(start_text) orelse 9 * 60,
            .end = parseTime(end_time_text) orelse 10 * 60,
            .repeat = Repeat.parse(repeat_text),
            .color = Color.parse(color_text),
            .remind = cfg.getInt(group, "remind", -1),
        });
    }
    return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
}

/// Writes (or replaces) one event.
pub fn save(allocator: std.mem.Allocator, cfg: *config_mod.Config, ev: Event) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Pair = config_mod.Config.Pair;

    const group = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ group_prefix, ev.id }, 0);
    var db: [16]u8 = undefined;
    var de: [16]u8 = undefined;
    var tb: [8]u8 = undefined;
    var te: [8]u8 = undefined;
    const pairs = [_]Pair{
        .{ .key = "title", .value = try a.dupeSentinel(u8, ev.title, 0) },
        .{ .key = "location", .value = try a.dupeSentinel(u8, ev.location, 0) },
        .{ .key = "notes", .value = try a.dupeSentinel(u8, ev.notes, 0) },
        .{ .key = "date", .value = try a.dupeSentinel(u8, formatDate(&db, ev.date), 0) },
        .{ .key = "end-date", .value = try a.dupeSentinel(u8, formatDate(&de, ev.end_date), 0) },
        .{ .key = "all-day", .value = if (ev.all_day) "true" else "false" },
        .{ .key = "start", .value = try a.dupeSentinel(u8, formatTime(&tb, ev.start), 0) },
        .{ .key = "end", .value = try a.dupeSentinel(u8, formatTime(&te, ev.end), 0) },
        .{ .key = "repeat", .value = try a.dupeSentinel(u8, ev.repeat.name(), 0) },
        .{ .key = "color", .value = try a.dupeSentinel(u8, ev.color.name(), 0) },
        .{ .key = "remind", .value = try std.fmt.allocPrintSentinel(a, "{d}", .{ev.remind}, 0) },
    };
    try cfg.setGroup(group, &pairs);
}

pub fn remove(allocator: std.mem.Allocator, cfg: *config_mod.Config, id: []const u8) !void {
    const group = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ group_prefix, id }, 0);
    defer allocator.free(group);
    try cfg.removeGroup(group);
}

/// A new id from the clock: unique enough for one person's calendar.
pub fn newId(buf: []u8, micros: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{x}", .{@as(u64, @intCast(micros))}) catch "0";
}

// ---- tests -----------------------------------------------------------------------------------

fn testEvent(date: Date, repeat: Repeat, remind: i32) Event {
    return .{ .id = "t", .title = "t", .date = date, .end_date = date, .repeat = repeat, .remind = remind, .start = 10 * 60 };
}

test "12-hour times" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("12:00 AM", formatTime12(&b, 0));
    try std.testing.expectEqualStrings("12:05 PM", formatTime12(&b, 12 * 60 + 5));
    try std.testing.expectEqualStrings("2:30 PM", formatTime12(&b, 14 * 60 + 30));
    try std.testing.expectEqualStrings("11:59 PM", formatTime12(&b, 23 * 60 + 59));
}

test "colours" {
    try std.testing.expectEqual(Color.teal, Color.parse("teal"));
    try std.testing.expectEqual(Color.default, Color.parse("no such colour"));
}

test "text forms" {
    try std.testing.expect(parseDate("2026-02-29") == null);
    try std.testing.expect(parseDate("2028-02-29") != null);
    try std.testing.expectEqual(@as(?u16, 615), parseTime("10:15"));
    try std.testing.expect(parseTime("24:00") == null);
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0999-01-05", formatDate(&b, .{ .year = 999, .month = 1, .day = 5 }));
}

test "repeats" {
    const base: Date = .{ .year = 2026, .month = 1, .day = 31 };
    var ev = testEvent(base, .weekly, -1);
    try std.testing.expect(occursOn(&ev, .{ .year = 2026, .month = 2, .day = 7 }));
    try std.testing.expect(!occursOn(&ev, .{ .year = 2026, .month = 2, .day = 8 }));
    try std.testing.expect(!occursOn(&ev, .{ .year = 2026, .month = 1, .day = 24 }));
    ev.repeat = .monthly;
    try std.testing.expect(!occursOn(&ev, .{ .year = 2026, .month = 2, .day = 28 })); // no 31st
    try std.testing.expect(occursOn(&ev, .{ .year = 2026, .month = 3, .day = 31 }));
    ev.repeat = .yearly;
    try std.testing.expect(occursOn(&ev, .{ .year = 2031, .month = 1, .day = 31 }));
}

test "multi-day events" {
    var ev = testEvent(.{ .year = 2026, .month = 12, .day = 30 }, .none, -1);
    ev.end_date = .{ .year = 2027, .month = 1, .day = 2 };
    try std.testing.expect(occursOn(&ev, .{ .year = 2026, .month = 12, .day = 31 }));
    try std.testing.expect(occursOn(&ev, .{ .year = 2027, .month = 1, .day = 2 }));
    try std.testing.expect(!occursOn(&ev, .{ .year = 2027, .month = 1, .day = 3 }));
}

test "reminders fire once, in order" {
    const a = std.testing.allocator;
    const day: Date = .{ .year = 2026, .month = 11, .day = 1 };
    const events = [_]Event{
        testEvent(day, .none, 30), // 09:30
        testEvent(day, .daily, 0), // 10:00 every day
        testEvent(day, .none, -1), // no reminder
    };
    const base = day.days() * 1440;
    const fires = try firesBetween(a, &events, base, base + 1440);
    defer a.free(fires);
    try std.testing.expectEqual(@as(usize, 2), fires.len);
    try std.testing.expectEqual(base + 9 * 60 + 30, fires[0].at);
    try std.testing.expectEqual(base + 10 * 60, fires[1].at);
    // Nothing is repeated when the window moves on.
    const later = try firesBetween(a, &events, base + 10 * 60, base + 1440);
    defer a.free(later);
    try std.testing.expectEqual(@as(usize, 0), later.len);
    try std.testing.expectEqual(@as(?i64, base + 9 * 60 + 30), nextFire(&events, base, 30));
    try std.testing.expectEqual(@as(?i64, base + 1440 + 600), nextFire(&events, base + 600, 30));
}

test "an early reminder reaches back over midnight" {
    const a = std.testing.allocator;
    var ev = testEvent(.{ .year = 2026, .month = 11, .day = 2 }, .none, 60 * 12); // 10:00 - 12h
    ev.start = 6 * 60; // 06:00 - 12h = 18:00 the day before
    const events = [_]Event{ev};
    const base = Date.days(.{ .year = 2026, .month = 11, .day = 1 }) * 1440;
    const fires = try firesBetween(a, &events, base, base + 1440);
    defer a.free(fires);
    try std.testing.expectEqual(@as(usize, 1), fires.len);
    try std.testing.expectEqual(base + 18 * 60, fires[0].at);
}
