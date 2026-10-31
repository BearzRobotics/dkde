//! Calendar systems the month grid can be laid out in. Events, reminders and
//! the liturgical overlays always use the civil (Gregorian) date; a system only
//! decides how a day is numbered and where the months begin.
//!
//!  * julian:    the Julian (Old) Calendar, 13 days behind the Gregorian one now.
//!  * gregorian: the civil calendar.
//!  * fixed:     the International Fixed Calendar: 13 months of 28 days, each
//!               starting on a Sunday. The 29th "day" of a month is outside the
//!               week: Leap Day (after June 28, in leap years) and Year Day
//!               (after December 28).

const std = @import("std");
const civil = @import("common").civil;

pub const Date = civil.Date;

pub const System = enum {
    julian,
    gregorian,
    fixed,

    pub fn parse(text: []const u8) System {
        return std.meta.stringToEnum(System, text) orelse .julian;
    }

    pub fn name(self: System) [:0]const u8 {
        return @tagName(self);
    }

    pub fn label(self: System) []const u8 {
        return switch (self) {
            .julian => "Julian (Old Calendar)",
            .gregorian => "Gregorian",
            .fixed => "Fixed (13 months)",
        };
    }

    pub fn monthCount(self: System) u8 {
        return if (self == .fixed) 13 else 12;
    }
};

/// A date written in some system. In `fixed`, day 29 of month 6 is Leap Day
/// and day 29 of month 13 is Year Day.
pub const Ymd = struct { year: i32, month: u8, day: u8 };

const gregorian_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const fixed_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "Sol", "July", "August", "September", "October", "November", "December" };

pub fn monthName(sys: System, month: u8) []const u8 {
    const i = @as(usize, month) - 1;
    return switch (sys) {
        .fixed => fixed_names[@min(i, 12)],
        else => gregorian_names[@min(i, 11)],
    };
}

// ---- Julian ------------------------------------------------------------------------------------

/// Julian day number of civil day `n` (days since 1970-01-01).
fn jdnOf(n: i64) i64 {
    return n + 2440588;
}

fn julianFromDays(n: i64) Ymd {
    const c = jdnOf(n) + 32082;
    const d = @divFloor(4 * c + 3, 1461);
    const e = c - @divFloor(1461 * d, 4);
    const m = @divFloor(5 * e + 2, 153);
    return .{
        .day = @intCast(e - @divFloor(153 * m + 2, 5) + 1),
        .month = @intCast(m + 3 - 12 * @divFloor(m, 10)),
        .year = @intCast(d - 4800 + @divFloor(m, 10)),
    };
}

fn julianToDays(v: Ymd) i64 {
    const a: i64 = @divFloor(14 - @as(i64, v.month), 12);
    const y: i64 = @as(i64, v.year) + 4800 - a;
    const m: i64 = @as(i64, v.month) + 12 * a - 3;
    const jdn = @as(i64, v.day) + @divFloor(153 * m + 2, 5) + 365 * y + @divFloor(y, 4) - 32083;
    return jdn - 2440588;
}

fn julianLeap(year: i32) bool {
    return @mod(year, 4) == 0;
}

// ---- Fixed -------------------------------------------------------------------------------------

/// The day of the year (1-based) of the leap day, counting from January 1.
const leap_doy = 169;

fn fixedFromDays(n: i64) Ymd {
    const g = civil.civilFromDays(n);
    const doy: i64 = n - civil.daysFromCivil(g.year, 1, 1) + 1;
    const leap = civil.isLeap(g.year);
    if (leap and doy == leap_doy) return .{ .year = g.year, .month = 6, .day = 29 };
    const adj = if (leap and doy > leap_doy) doy - 1 else doy;
    if (adj == 365) return .{ .year = g.year, .month = 13, .day = 29 };
    return .{ .year = g.year, .month = @intCast(@divFloor(adj - 1, 28) + 1), .day = @intCast(@mod(adj - 1, 28) + 1) };
}

fn fixedToDays(v: Ymd) i64 {
    const leap = civil.isLeap(v.year);
    var doy: i64 = undefined;
    if (v.month == 6 and v.day == 29) {
        doy = leap_doy;
    } else {
        const adj: i64 = if (v.month == 13 and v.day == 29) 365 else (@as(i64, v.month) - 1) * 28 + v.day;
        doy = if (leap and adj >= leap_doy) adj + 1 else adj;
    }
    return civil.daysFromCivil(v.year, 1, 1) + doy - 1;
}

// ---- the public face ---------------------------------------------------------------------------

pub fn fromCivil(sys: System, date: Date) Ymd {
    return switch (sys) {
        .gregorian => .{ .year = date.year, .month = date.month, .day = date.day },
        .julian => julianFromDays(date.days()),
        .fixed => fixedFromDays(date.days()),
    };
}

pub fn toCivil(sys: System, v: Ymd) Date {
    return switch (sys) {
        .gregorian => .{ .year = v.year, .month = v.month, .day = v.day },
        .julian => Date.fromDays(julianToDays(v)),
        .fixed => Date.fromDays(fixedToDays(v)),
    };
}

/// How many days the month has; for `fixed` that is 28, plus 1 for Leap Day
/// or Year Day.
pub fn monthDays(sys: System, year: i32, month: u8) u8 {
    return switch (sys) {
        .gregorian => civil.daysInMonth(year, month),
        .julian => switch (month) {
            2 => if (julianLeap(year)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        },
        .fixed => if ((month == 13) or (month == 6 and civil.isLeap(year))) 29 else 28,
    };
}

/// 0 = Sunday ... 6 = Saturday in the system's own week, or null for a day
/// outside the week. The Fixed Calendar's week restarts every month, so its
/// Sunday is generally not a civil Sunday.
pub fn weekdayOf(sys: System, date: Date) ?u8 {
    if (sys != .fixed) return date.weekday();
    const v = fromCivil(.fixed, date);
    if (v.day == 29) return null;
    return @intCast((v.day - 1) % 7);
}

/// Whether the day is outside the week (Leap Day, Year Day).
pub fn isSpecial(sys: System, v: Ymd) bool {
    return sys == .fixed and v.day == 29;
}

pub fn specialName(v: Ymd) []const u8 {
    return if (v.month == 6) "Leap Day" else "Year Day";
}

pub const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// "Saturday, October 31, 2026" in the given system, for a day panel.
pub fn describe(buf: []u8, sys: System, date: Date) []const u8 {
    const v = fromCivil(sys, date);
    if (weekdayOf(sys, date)) |wd|
        return std.fmt.bufPrint(buf, "{s}, {s} {d}, {d}", .{ weekday_names[wd], monthName(sys, v.month), v.day, v.year }) catch "";
    return std.fmt.bufPrint(buf, "{s}, {d}", .{ specialName(v), v.year }) catch "";
}

// ---- tests -------------------------------------------------------------------------------------

test "Julian is 13 days behind now" {
    const d: Date = .{ .year = 2026, .month = 10, .day = 31 };
    const j = fromCivil(.julian, d);
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 10, .day = 18 }, j);
    try std.testing.expect(toCivil(.julian, j).eql(d));
    // 14 Jan Julian = 1 Jan Gregorian (Old New Year), and Christmas Old Style = Jan 7.
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 12, .day = 25 }, fromCivil(.julian, .{ .year = 2027, .month = 1, .day = 7 }));
    // Julian leap day exists in 1900 (not Gregorian) and was Mar 13 civil.
    try std.testing.expectEqual(Ymd{ .year = 1900, .month = 2, .day = 29 }, fromCivil(.julian, .{ .year = 1900, .month = 3, .day = 13 }));
    try std.testing.expectEqual(@as(u8, 29), monthDays(.julian, 1900, 2));
}

test "Julian round trip over centuries" {
    var n: i64 = -200000;
    while (n < 200000) : (n += 977) {
        const d = Date.fromDays(n);
        try std.testing.expectEqual(n, toCivil(.julian, fromCivil(.julian, d)).days());
    }
}

test "fixed weeks" {
    // Every Fixed month starts on Sunday, so the 1st of any month is weekday 0.
    try std.testing.expectEqual(@as(?u8, 0), weekdayOf(.fixed, .{ .year = 2026, .month = 1, .day = 29 }));
    try std.testing.expectEqual(@as(?u8, null), weekdayOf(.fixed, .{ .year = 2026, .month = 12, .day = 31 }));
    try std.testing.expectEqual(@as(?u8, 6), weekdayOf(.julian, .{ .year = 2026, .month = 10, .day = 31 }));
}

test "fixed calendar" {
    // Jan 1 is 1/1; Feb 1 civil is the 32nd day = month 2 day 4.
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 1, .day = 1 }, fromCivil(.fixed, .{ .year = 2026, .month = 1, .day = 1 }));
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 2, .day = 4 }, fromCivil(.fixed, .{ .year = 2026, .month = 2, .day = 1 }));
    // Sol starts the day after June 28 (common year: doy 169 = June 18).
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 7, .day = 1 }, fromCivil(.fixed, .{ .year = 2026, .month = 6, .day = 18 }));
    // Year Day is Dec 31 in a common year.
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 13, .day = 29 }, fromCivil(.fixed, .{ .year = 2026, .month = 12, .day = 31 }));
    // Leap years: Leap Day is June 17, and Year Day is still the last day.
    try std.testing.expectEqual(Ymd{ .year = 2028, .month = 6, .day = 29 }, fromCivil(.fixed, .{ .year = 2028, .month = 6, .day = 17 }));
    try std.testing.expectEqual(Ymd{ .year = 2028, .month = 7, .day = 1 }, fromCivil(.fixed, .{ .year = 2028, .month = 6, .day = 18 }));
    try std.testing.expectEqual(Ymd{ .year = 2028, .month = 13, .day = 29 }, fromCivil(.fixed, .{ .year = 2028, .month = 12, .day = 31 }));
    try std.testing.expectEqual(@as(u8, 29), monthDays(.fixed, 2028, 6));
    try std.testing.expectEqual(@as(u8, 28), monthDays(.fixed, 2026, 6));
}

test "fixed round trip; months are 28 days apart" {
    var n = civil.daysFromCivil(2023, 1, 1);
    const end = civil.daysFromCivil(2033, 1, 1);
    while (n < end) : (n += 1) {
        const d = Date.fromDays(n);
        const v = fromCivil(.fixed, d);
        try std.testing.expectEqual(n, toCivil(.fixed, v).days());
        if (v.day == 1 and v.month != 7) {
            const prev = fromCivil(.fixed, d.addDays(-28));
            try std.testing.expect(prev.day == 1 or prev.day == 29 or prev.month == 13 or v.month == 1);
        }
    }
}
