//! Date calculation for the Date Calculation pane, in any calendar
//! dkde-calendar knows (calsys: Julian, Gregorian, Fixed, Rosquin, Chinese,
//! Hebrew, Coptic, Ethiopian): the time between two dates in that
//! calendar's years, months and days, and a date moved by years, months and
//! days in it.
//!
//! Dates are written year-month-day in the calendar's own numbering
//! ("5787-3-12" in the Hebrew calendar). A month that is shorter than the
//! day moved to (31 → a 30-day month, or a Leap Day that does not exist)
//! gives the month's last day.

const std = @import("std");
pub const calsys = @import("calsys");

pub const System = calsys.System;
pub const Ymd = calsys.Ymd;

pub const all_systems = std.enums.values(System);

pub fn civilDays(sys: System, v: Ymd) i64 {
    return calsys.toCivil(sys, v).days();
}

/// "2024-07-19", "5787-3-12", "19.7.2024" (day first when the year comes last).
pub fn parse(sys: System, text: []const u8) ?Ymd {
    const t = std.mem.trim(u8, text, " ");
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, t, "-/. ");
    while (it.next()) |p| {
        if (n == 3) return null;
        parts[n] = p;
        n += 1;
    }
    if (n != 3) return null;
    var y: i32 = undefined;
    var m: u8 = undefined;
    var d: u16 = undefined;
    if (parts[2].len >= 3 and parts[0].len <= 2) {
        d = std.fmt.parseInt(u16, parts[0], 10) catch return null;
        m = std.fmt.parseInt(u8, parts[1], 10) catch return null;
        y = std.fmt.parseInt(i32, parts[2], 10) catch return null;
    } else {
        y = std.fmt.parseInt(i32, parts[0], 10) catch return null;
        m = std.fmt.parseInt(u8, parts[1], 10) catch return null;
        d = std.fmt.parseInt(u16, parts[2], 10) catch return null;
    }
    const v: Ymd = .{ .year = y, .month = m, .day = d };
    return if (valid(sys, v)) v else null;
}

pub fn valid(sys: System, v: Ymd) bool {
    if (v.day == 0) return false;
    // Rosquin's inter-calendar days belong to no month (month 0).
    if (v.month == 0) return sys.isRosquin() and calsys.isSpecial(sys, v);
    if (v.month > calsys.monthsIn(sys, v.year)) return false;
    return v.day <= calsys.monthDays(sys, v.year, v.month);
}

/// `v` as text that `parse` reads back.
pub fn write(buf: []u8, v: Ymd) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{d}-{d}", .{ v.year, v.month, v.day }) catch "";
}

/// `v` moved by whole years and months in the calendar (same day, or the
/// month's last day when it is shorter), then by days.
pub fn add(sys: System, v0: Ymd, years: i64, months: i64, days: i64) Ymd {
    var v = v0;
    // An inter-calendar day counts from the page it is shown with.
    if (v.month == 0) v.month = calsys.pageOf(sys, v);
    var year: i64 = @as(i64, v.year) + years;
    var month: i64 = v.month;
    if (month > calsys.monthsIn(sys, @intCast(year))) month = calsys.monthsIn(sys, @intCast(year));
    var k = months;
    while (k > 0) : (k -= 1) {
        month += 1;
        if (month > calsys.monthsIn(sys, @intCast(year))) {
            month = 1;
            year += 1;
        }
    }
    while (k < 0) : (k += 1) {
        month -= 1;
        if (month < 1) {
            year -= 1;
            month = calsys.monthsIn(sys, @intCast(year));
        }
    }
    const y: i32 = @intCast(year);
    const m: u8 = @intCast(month);
    const moved: Ymd = .{ .year = y, .month = m, .day = @min(v.day, calsys.monthDays(sys, y, m)) };
    if (days == 0) return moved;
    return calsys.fromCivil(sys, calsys.Date.fromDays(civilDays(sys, moved) + days));
}

pub const Span = struct { years: i64, months: i64, days: i64, total_days: i64 };

/// The time from `a` to `b` in the calendar's whole years and months and
/// the days left over (counted forward from the earlier date), and in days.
pub fn between(sys: System, a0: Ymd, b0: Ymd) Span {
    var a = a0;
    var b = b0;
    if (civilDays(sys, b) < civilDays(sys, a)) {
        a = b0;
        b = a0;
    }
    const end = civilDays(sys, b);
    const total = end - civilDays(sys, a);
    var years: i64 = @as(i64, b.year) - a.year;
    while (years > 0 and civilDays(sys, add(sys, a, years, 0, 0)) > end) years -= 1;
    var months: i64 = 0;
    while (months < 14 and civilDays(sys, add(sys, a, years, months + 1, 0)) <= end) months += 1;
    const rest = end - civilDays(sys, add(sys, a, years, months, 0));
    return .{ .years = years, .months = months, .days = rest, .total_days = total };
}

test "Gregorian" {
    const s = between(.gregorian, .{ .year = 2020, .month = 1, .day = 31 }, .{ .year = 2024, .month = 3, .day = 15 });
    try std.testing.expectEqual(@as(i64, 4), s.years);
    try std.testing.expectEqual(@as(i64, 1), s.months);
    try std.testing.expectEqual(@as(i64, 15), s.days);
    try std.testing.expectEqual(@as(i64, 1505), s.total_days);
    try std.testing.expectEqual(Ymd{ .year = 2024, .month = 2, .day = 29 }, add(.gregorian, .{ .year = 2024, .month = 1, .day = 31 }, 0, 1, 0));
    try std.testing.expectEqual(Ymd{ .year = 2023, .month = 12, .day = 31 }, add(.gregorian, .{ .year = 2024, .month = 1, .day = 1 }, 0, 0, -1));
    try std.testing.expectEqual(Ymd{ .year = 2024, .month = 7, .day = 19 }, parse(.gregorian, "19.7.2024").?);
    try std.testing.expect(parse(.gregorian, "2023-02-29") == null);
}

test "the same span in other calendars" {
    // 100 days are 100 days in every calendar.
    for (all_systems) |sys| {
        const start = calsys.fromCivil(sys, .{ .year = 2026, .month = 11, .day = 11 });
        const later = add(sys, start, 0, 0, 100);
        try std.testing.expectEqual(@as(i64, 100), between(sys, start, later).total_days);
        try std.testing.expect(valid(sys, later) or later.month == 0);
    }
    // A Hebrew year later is the same day of the same month.
    const h: Ymd = .{ .year = 5787, .month = 1, .day = 15 };
    try std.testing.expectEqual(Ymd{ .year = 5788, .month = 1, .day = 15 }, add(.hebrew, h, 1, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), between(.hebrew, h, add(.hebrew, h, 1, 0, 0)).years);
    // The Fixed calendar's 13 months: a month on from 28 June is 28 Sol.
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 7, .day = 28 }, add(.fixed, .{ .year = 2026, .month = 6, .day = 28 }, 0, 1, 0));
    // Julian: 13 days behind the Gregorian dates now.
    const j = calsys.fromCivil(.julian, .{ .year = 2027, .month = 1, .day = 7 });
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 12, .day = 25 }, j);
}
