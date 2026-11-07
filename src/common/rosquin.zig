//! The Rosquin calendar: 13-day weeks, a year that starts on September 21, and
//! three ways to group the weeks. Shared by the calendar app and the panel's
//! clock, so it is pure arithmetic on civil days (see civil.zig).
//!
//!  * The week has 13 days: days 1 to 12 and the Ankh (day 13).
//!  * A year is 28 weeks (364 days) from September 21 to September 20, plus two
//!    days outside the weeks that sit where they fall in the civil calendar:
//!    Year-End Day (every December 31) and Leap Day (every February 29). They
//!    belong to no week and no month; they are days of the year only.
//!  * The weeks group three ways (a `Layout`): the whole year as 28 weeks, 7
//!    months of 4 weeks (52 days), or 4 quarters of 7 weeks (91 days).
//!  * Day code: 1976-09-21 is day 1, so 2026-11-06 is day 18309. The year is the
//!    civil year of the September 21 that starts it, minus 1976 (2026-11-06 is
//!    in Year 50).
//!
//! The names are the project's own; the author of the calendar has not named
//! the days or months yet.

const std = @import("std");
const civil = @import("civil.zig");

pub const Date = civil.Date;

pub const Layout = enum {
    /// 28 weeks of 13 days: no months.
    weeks,
    /// 7 months of 4 weeks (52 days).
    months,
    /// 4 quarters of 7 weeks (91 days).
    quarters,

    pub fn parse(text: []const u8) ?Layout {
        return std.meta.stringToEnum(Layout, text);
    }

    pub fn name(self: Layout) []const u8 {
        return @tagName(self);
    }

    /// Days in a regular page ("month") of this layout.
    pub fn monthLen(self: Layout) u16 {
        return switch (self) {
            .weeks => 364,
            .months => 52,
            .quarters => 91,
        };
    }

    pub fn monthsPerYear(self: Layout) u8 {
        return switch (self) {
            .weeks => 1,
            .months => 7,
            .quarters => 4,
        };
    }
};

/// A Rosquin date. `day` is 1 to the page length. Year-End Day and Leap Day are
/// outside the weeks and the months: their `day` is `year_end_day` / `leap_day`
/// and their `month` is 0, so no month counts them.
pub const Ymd = struct { year: i32, month: u8, day: u16 };

pub const year_end_day: u16 = 1000;
pub const leap_day: u16 = 1001;

/// 1976-09-21 is day 1 of the day code.
pub const epoch_year = 1976;

// Regular days (0 based) before each special day: Dec 30 is the 101st day of
// the year and Feb 28 the 160th, so the special days follow index 100 and 159.
const yed_after = 100;
const leap_after = 159;

pub fn isSpecial(v: Ymd) bool {
    return v.day >= year_end_day;
}

/// The day code of a civil day: 1976-09-21 is 1.
pub fn dayCode(date: Date) i64 {
    return date.days() - civil.daysFromCivil(epoch_year, 9, 21) + 1;
}

fn cycleStartYear(g: Date) i32 {
    return if (g.month > 9 or (g.month == 9 and g.day >= 21)) g.year else g.year - 1;
}

pub fn fromDays(layout: Layout, n: i64) Ymd {
    const g = civil.civilFromDays(n);
    const sy = cycleStartYear(g);
    const year = sy - epoch_year;
    const len = layout.monthLen();
    if (g.month == 12 and g.day == 31) return .{ .year = year, .month = 0, .day = year_end_day };
    if (g.month == 2 and g.day == 29) return .{ .year = year, .month = 0, .day = leap_day };
    var k = n - civil.daysFromCivil(sy, 9, 21);
    if (n > civil.daysFromCivil(sy, 12, 31)) k -= 1;
    if (civil.isLeap(sy + 1) and n > civil.daysFromCivil(sy + 1, 2, 29)) k -= 1;
    return .{ .year = year, .month = @intCast(@divFloor(k, len) + 1), .day = @intCast(@mod(k, len) + 1) };
}

pub fn toDays(layout: Layout, v: Ymd) i64 {
    const sy = v.year + epoch_year;
    if (v.day == year_end_day) return civil.daysFromCivil(sy, 12, 31);
    if (v.day == leap_day) return civil.daysFromCivil(sy + 1, 2, 29);
    const k: i64 = (@as(i64, v.month) - 1) * layout.monthLen() + v.day - 1;
    var n = k;
    if (k > yed_after) n += 1;
    if (civil.isLeap(sy + 1) and k > leap_after) n += 1;
    return civil.daysFromCivil(sy, 9, 21) + n;
}

pub fn fromCivil(layout: Layout, date: Date) Ymd {
    return fromDays(layout, date.days());
}

pub fn toCivil(layout: Layout, v: Ymd) Date {
    return Date.fromDays(toDays(layout, v));
}

/// Whether the year has a Leap Day (Year-End Day every year has).
pub fn hasLeapDay(year: i32) bool {
    return civil.isLeap(year + epoch_year + 1);
}

/// Days in a page. Only regular days count; the two special days are in no page.
pub fn monthDays(layout: Layout, month: u8) u16 {
    _ = month;
    return layout.monthLen();
}

/// Days in the year: 364, plus Year-End Day, plus Leap Day in a leap year.
pub fn yearDays(year: i32) u16 {
    return @as(u16, 365) + @intFromBool(hasLeapDay(year));
}

/// The page a calendar shows to put a special day next to the days around it:
/// the one that holds the day before it.
/// The week of the year (8 or 13) a special day falls in: Year-End Day follows the
/// 101st day of the year, Leap Day the 160th. It is still in no week.
pub fn weekNear(day: u16) u8 {
    const after: u16 = if (day == year_end_day) yed_after else leap_after;
    return @intCast(after / 13 + 1);
}

/// The row (0-based, of 13 days) of the page where a special day stands, in the
/// 14th column: the row of the week it falls in.
pub fn rowNear(layout: Layout, day: u16) u8 {
    const after: u16 = if (day == year_end_day) yed_after else leap_after;
    return @intCast((after % layout.monthLen()) / 13);
}

pub fn pageNear(layout: Layout, day: u16) u8 {
    const after: u16 = if (day == year_end_day) yed_after else leap_after;
    return @intCast(after / layout.monthLen() + 1);
}

/// The day of the year: 1 on September 21, and it starts over there. Year-End
/// Day is 365 and Leap Day 366, as in the workbook, so the regular days are 1 to 364.
pub fn dayOfYear(date: Date) u16 {
    const v = fromDays(.weeks, date.days());
    if (v.day == year_end_day) return 365;
    if (v.day == leap_day) return 366;
    return v.day;
}

/// 0-based index of a regular day in the year, 0 to 363, or null for a special day.
pub fn cycleIndex(date: Date) ?u16 {
    const v = fromDays(.weeks, date.days());
    if (isSpecial(v)) return null;
    return v.day - 1;
}

/// Week of the year, 1 to 28, or null for a special day.
pub fn weekOfYear(date: Date) ?u8 {
    const k = cycleIndex(date) orelse return null;
    return @intCast(k / 13 + 1);
}

/// Day of the week, 1 to 13 (13 is the Ankh), or null for a special day.
pub fn dayOfWeek(date: Date) ?u8 {
    const k = cycleIndex(date) orelse return null;
    return @intCast(k % 13 + 1);
}

// ---- names -------------------------------------------------------------------------------------

pub const day_names = [13][]const u8{
    "Kindling", "Furrow",  "Lantern", "Tidewater", "Cairn",  "Wellspring", "Plumbline",
    "Harrow",   "Thistle", "Compass", "Vesper",    "Threshold", "Ankhtide",
};

pub const month_names = [7][]const u8{ "Gleaning", "Emberfast", "Hollowmoon", "Thawbright", "Greenwake", "Highsun", "Reapglow" };

pub const quarter_names = [4][]const u8{ "Gathering", "Stillwater", "Quickening", "Highsummer" };

pub const year_end_name = "Stillpoint";
pub const leap_name = "Wanderday";

/// The name of a page: a month, a quarter, or "Year" for the 28-week layout.
pub fn pageName(layout: Layout, month: u8) []const u8 {
    if (month == 0) return "";
    const i = @as(usize, month) - 1;
    return switch (layout) {
        .weeks => "Year",
        .months => month_names[@min(i, 6)],
        .quarters => quarter_names[@min(i, 3)],
    };
}

pub fn specialName(v: Ymd) []const u8 {
    return if (v.day == year_end_day) year_end_name else leap_name;
}

// ---- text for the panel clock -----------------------------------------------------------------

/// Replaces the Rosquin tokens in a clock format, leaving everything else (the
/// strftime codes) for the caller:
///
///   @D day code      @y day of the year (1-366)   @Y year        @n month/quarter name   @m its number
///   @d day of it     @w week 1-28   @e day of week 1-13     @N name of the day
///   @@ a literal @
///
/// On Year-End Day and Leap Day, which are in no month, @d and @N are the day's name
/// and @n, @m, @w and @e are empty.
pub fn expand(allocator: std.mem.Allocator, format: []const u8, date: Date, layout: Layout) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const v = fromCivil(layout, date);
    const special = isSpecial(v);
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '@' or i + 1 >= format.len) {
            try out.append(allocator, format[i]);
            continue;
        }
        i += 1;
        switch (format[i]) {
            '@' => try out.append(allocator, '@'),
            'D' => try out.print(allocator, "{d}", .{dayCode(date)}),
            'y' => try out.print(allocator, "{d}", .{dayOfYear(date)}),
            'Y' => try out.print(allocator, "{d}", .{v.year}),
            'n' => try out.appendSlice(allocator, pageName(layout, v.month)),
            'm' => if (!special) try out.print(allocator, "{d}", .{v.month}),
            'd' => if (special) try out.appendSlice(allocator, specialName(v)) else try out.print(allocator, "{d}", .{v.day}),
            'w' => if (weekOfYear(date)) |w| try out.print(allocator, "{d}", .{w}),
            'e' => if (dayOfWeek(date)) |w| try out.print(allocator, "{d}", .{w}),
            'N' => if (dayOfWeek(date)) |w| try out.appendSlice(allocator, day_names[w - 1]) else try out.appendSlice(allocator, specialName(v)),
            else => {
                try out.append(allocator, '@');
                try out.append(allocator, format[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

test "clock tokens" {
    const a = std.testing.allocator;
    const d: Date = .{ .year = 2026, .month = 11, .day = 6 };
    const s = try expand(a, "%H:%M\n@D/@y \u{b7} Yr @Y @n @d (@N) @@ @q", d, .months);
    defer a.free(s);
    try std.testing.expectEqualStrings("%H:%M\n18309/47 \u{b7} Yr 50 Gleaning 47 (Harrow) @ @q", s);
    const y = try expand(a, "@N @w|@e|@n", .{ .year = 2026, .month = 12, .day = 31 }, .weeks);
    defer a.free(y);
    try std.testing.expectEqualStrings("Stillpoint ||", y);
}

// ---- tests -------------------------------------------------------------------------------------

test "day code and year" {
    const d: Date = .{ .year = 2026, .month = 11, .day = 6 };
    try std.testing.expectEqual(@as(i64, 18309), dayCode(d));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 1, .day = 47 }, fromCivil(.months, d));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 1, .day = 47 }, fromCivil(.quarters, d));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 1, .day = 47 }, fromCivil(.weeks, d));
    try std.testing.expectEqual(@as(?u8, 4), weekOfYear(d));
    try std.testing.expectEqual(@as(?u8, 8), dayOfWeek(d));
    try std.testing.expectEqual(@as(i64, 1), dayCode(.{ .year = 1976, .month = 9, .day = 21 }));
    // The day of the year starts over at 1 on September 21; Year-End Day is 365, Leap Day 366.
    try std.testing.expectEqual(@as(u16, 47), dayOfYear(d));
    try std.testing.expectEqual(@as(u16, 1), dayOfYear(.{ .year = 2026, .month = 9, .day = 21 }));
    try std.testing.expectEqual(@as(u16, 101), dayOfYear(.{ .year = 2026, .month = 12, .day = 30 }));
    try std.testing.expectEqual(@as(u16, 365), dayOfYear(.{ .year = 2026, .month = 12, .day = 31 }));
    try std.testing.expectEqual(@as(u16, 102), dayOfYear(.{ .year = 2027, .month = 1, .day = 1 }));
    try std.testing.expectEqual(@as(u16, 366), dayOfYear(.{ .year = 2028, .month = 2, .day = 29 }));
    try std.testing.expectEqual(@as(u16, 364), dayOfYear(.{ .year = 2027, .month = 9, .day = 20 }));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 1, .day = 1 }, fromCivil(.months, .{ .year = 2026, .month = 9, .day = 21 }));
    try std.testing.expectEqual(Ymd{ .year = 49, .month = 7, .day = 52 }, fromCivil(.months, .{ .year = 2026, .month = 9, .day = 20 }));
    try std.testing.expectEqual(Ymd{ .year = 49, .month = 1, .day = 364 }, fromCivil(.weeks, .{ .year = 2026, .month = 9, .day = 20 }));
}

test "the three layouts" {
    // Mid-year: day 200 of the year is month 4 day 44 (months), quarter 3 day 18 (quarters).
    const d = toCivil(.weeks, .{ .year = 50, .month = 1, .day = 200 });
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 4, .day = 44 }, fromCivil(.months, d));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 3, .day = 18 }, fromCivil(.quarters, d));
}

test "special days" {
    // Dec 30 is day 101, Year-End Day follows it, then Jan 1 is day 102.
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 2, .day = 49 }, fromCivil(.months, .{ .year = 2026, .month = 12, .day = 30 }));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 0, .day = year_end_day }, fromCivil(.months, .{ .year = 2026, .month = 12, .day = 31 }));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 2, .day = 50 }, fromCivil(.months, .{ .year = 2027, .month = 1, .day = 1 }));
    try std.testing.expectEqual(Ymd{ .year = 50, .month = 0, .day = year_end_day }, fromCivil(.weeks, .{ .year = 2026, .month = 12, .day = 31 }));
    // 2028 is a leap year.
    try std.testing.expectEqual(Ymd{ .year = 51, .month = 0, .day = leap_day }, fromCivil(.months, .{ .year = 2028, .month = 2, .day = 29 }));
    try std.testing.expectEqual(Ymd{ .year = 51, .month = 0, .day = leap_day }, fromCivil(.quarters, .{ .year = 2028, .month = 2, .day = 29 }));
    try std.testing.expectEqual(Ymd{ .year = 51, .month = 4, .day = 5 }, fromCivil(.months, .{ .year = 2028, .month = 3, .day = 1 }));
    // The special days are in no month: every month keeps its length, and the year adds them.
    try std.testing.expectEqual(@as(u16, 52), monthDays(.months, 4));
    try std.testing.expectEqual(@as(u16, 91), monthDays(.quarters, 2));
    try std.testing.expectEqual(@as(u16, 366), yearDays(51));
    try std.testing.expectEqual(@as(u16, 365), yearDays(50));
    // Rows of the page where the 14th column shows them: week 8 is the 4th week of month 2 (months of 4 weeks).
    try std.testing.expectEqual(@as(u8, 3), rowNear(.months, year_end_day));
    try std.testing.expectEqual(@as(u8, 0), rowNear(.months, leap_day));
    try std.testing.expectEqual(@as(u8, 7), rowNear(.weeks, year_end_day));
    try std.testing.expectEqual(@as(u8, 12), rowNear(.weeks, leap_day));
    try std.testing.expectEqual(@as(u8, 0), rowNear(.quarters, year_end_day));
    try std.testing.expectEqual(@as(u8, 5), rowNear(.quarters, leap_day));
    try std.testing.expectEqual(@as(u8, 8), weekNear(year_end_day));
    try std.testing.expectEqual(@as(u8, 13), weekNear(leap_day));
    try std.testing.expectEqual(@as(u8, 2), pageNear(.months, year_end_day));
    try std.testing.expectEqual(@as(u8, 4), pageNear(.months, leap_day));
}

test "round trip and year length in every layout" {
    inline for (.{ Layout.weeks, Layout.months, Layout.quarters }) |layout| {
        var n = civil.daysFromCivil(2020, 1, 1);
        const end = civil.daysFromCivil(2036, 1, 1);
        while (n < end) : (n += 1) {
            try std.testing.expectEqual(n, toDays(layout, fromDays(layout, n)));
        }
        var y: i32 = 40;
        while (y < 55) : (y += 1) {
            var total: u32 = 0;
            var m: u8 = 1;
            while (m <= layout.monthsPerYear()) : (m += 1) total += monthDays(layout, m);
            try std.testing.expectEqual(@as(u32, 364), total);
            try std.testing.expectEqual(@as(u32, if (civil.isLeap(y + epoch_year + 1)) 366 else 365), yearDays(y));
        }
    }
}
