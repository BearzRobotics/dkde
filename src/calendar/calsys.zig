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
//!  * rosquin_weeks / rosquin_months / rosquin_quarters: the Rosquin calendar
//!               (see common/rosquin.zig) with its 28 weeks of 13 days shown as
//!               one page, as 7 months of 4 weeks, or as 4 quarters of 7 weeks.

const std = @import("std");
const common = @import("common");
const civil = common.civil;
const rosquin = common.rosquin;
const worldcal = @import("worldcal.zig");

pub const Date = civil.Date;

pub const System = enum {
    julian,
    gregorian,
    fixed,
    rosquin_weeks,
    rosquin_months,
    rosquin_quarters,
    chinese,
    hebrew,
    coptic,
    ethiopian,

    pub fn parse(text: []const u8) System {
        if (std.mem.eql(u8, text, "rosquin")) return .rosquin_months;
        return std.meta.stringToEnum(System, text) orelse .gregorian;
    }

    pub fn name(self: System) [:0]const u8 {
        return @tagName(self);
    }

    pub fn label(self: System) [:0]const u8 {
        return switch (self) {
            .julian => "Julian",
            .gregorian => "Gregorian",
            .fixed => "Fixed (13 months)",
            .rosquin_weeks => "Rɛ°Cᴀʟ—28.wѻ",
            .rosquin_months => "Rɛ°Cᴀʟ—7ᴍọ/4.wѻ",
            .rosquin_quarters => "Rɛ°Cᴀʟ—4ᴍọ/7.wѻ",
            .chinese => "Chinese",
            .hebrew => "Hebrew (Jewish)",
            .coptic => "Coptic",
            .ethiopian => "Ethiopian",
        };
    }

    pub fn monthCount(self: System) u8 {
        return switch (self) {
            .fixed => 13,
            .rosquin_weeks, .rosquin_months, .rosquin_quarters => self.layout().?.monthsPerYear(),
            .coptic, .ethiopian => 13,
            else => 12,
        };
    }

    pub fn isRosquin(self: System) bool {
        return self.layout() != null;
    }

    pub fn layout(self: System) ?rosquin.Layout {
        return switch (self) {
            .rosquin_weeks => .weeks,
            .rosquin_months => .months,
            .rosquin_quarters => .quarters,
            else => null,
        };
    }
};

/// A date written in some system. In `fixed`, day 29 of month 6 is Leap Day
/// and day 29 of month 13 is Year Day.
pub const Ymd = struct { year: i32, month: u8, day: u16 };

const gregorian_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const fixed_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "Sol", "July", "August", "September", "October", "November", "December" };

/// How many months (pages) a year has: it varies in the lunisolar calendars.
pub fn monthsIn(sys: System, year: i32) u8 {
    return switch (sys) {
        .chinese => worldcal.chineseMonthsIn(year),
        .hebrew => worldcal.hebrewMonthsIn(year),
        else => sys.monthCount(),
    };
}

/// The name of a month in a given year ("Month 6", "Leap Month 6", "Adar I", "Pagume").
pub fn monthLabel(buf: []u8, sys: System, year: i32, month: u8) []const u8 {
    const i = @min(@as(usize, month) -| 1, 12);
    return switch (sys) {
        .chinese => worldcal.chineseMonthName(buf, year, month),
        .hebrew => worldcal.hebrewMonthName(year, month),
        .coptic => worldcal.coptic_months[i],
        .ethiopian => worldcal.ethiopian_months[i],
        else => monthName(sys, month),
    };
}

/// The year as written in the system ("2026", or "Bing-Wu, Fire Horse").
pub fn yearLabel(buf: []u8, sys: System, year: i32) []const u8 {
    return switch (sys) {
        .chinese => worldcal.chineseYearName(buf, year),
        else => std.fmt.bufPrint(buf, "{d}", .{year}) catch "",
    };
}

pub fn monthName(sys: System, month: u8) []const u8 {
    const i = @as(usize, month) - 1;
    return switch (sys) {
        .rosquin_weeks, .rosquin_months, .rosquin_quarters => rosquin.pageName(sys.layout().?, month),
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

// ---- Rosquin -----------------------------------------------------------------------------------

fn worldYmd(v: worldcal.Ymd) Ymd {
    return .{ .year = v.year, .month = v.month, .day = v.day };
}

fn worldOf(v: Ymd) worldcal.Ymd {
    return .{ .year = v.year, .month = v.month, .day = @intCast(v.day) };
}

fn rosYmd(v: rosquin.Ymd) Ymd {
    return .{ .year = v.year, .month = v.month, .day = v.day };
}

fn rosOf(v: Ymd) rosquin.Ymd {
    return .{ .year = v.year, .month = v.month, .day = v.day };
}

// ---- the public face ---------------------------------------------------------------------------

pub fn fromCivil(sys: System, date: Date) Ymd {
    return switch (sys) {
        .gregorian => .{ .year = date.year, .month = date.month, .day = date.day },
        .julian => julianFromDays(date.days()),
        .fixed => fixedFromDays(date.days()),
        .rosquin_weeks, .rosquin_months, .rosquin_quarters => rosYmd(rosquin.fromCivil(sys.layout().?, date)),
        .chinese => worldYmd(worldcal.chineseFromDays(date.days())),
        .hebrew => worldYmd(worldcal.hebrewFromDays(date.days())),
        .coptic => worldYmd(worldcal.africaFromDays(.coptic, date.days())),
        .ethiopian => worldYmd(worldcal.africaFromDays(.ethiopian, date.days())),
    };
}

pub fn toCivil(sys: System, v: Ymd) Date {
    return switch (sys) {
        .gregorian => .{ .year = v.year, .month = v.month, .day = @intCast(v.day) },
        .julian => Date.fromDays(julianToDays(v)),
        .fixed => Date.fromDays(fixedToDays(v)),
        .rosquin_weeks, .rosquin_months, .rosquin_quarters => rosquin.toCivil(sys.layout().?, rosOf(v)),
        .chinese => Date.fromDays(worldcal.chineseToDays(worldOf(v))),
        .hebrew => Date.fromDays(worldcal.hebrewToDays(worldOf(v))),
        .coptic => Date.fromDays(worldcal.africaToDays(.coptic, worldOf(v))),
        .ethiopian => Date.fromDays(worldcal.africaToDays(.ethiopian, worldOf(v))),
    };
}

/// How many days the month has; for `fixed` that is 28, plus 1 for Leap Day
/// or Year Day.
pub fn monthDays(sys: System, year: i32, month: u8) u16 {
    return switch (sys) {
        .gregorian => civil.daysInMonth(year, month),
        .julian => switch (month) {
            2 => if (julianLeap(year)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        },
        .fixed => if ((month == 13) or (month == 6 and civil.isLeap(year))) 29 else 28,
        .rosquin_weeks, .rosquin_months, .rosquin_quarters => rosquin.monthDays(sys.layout().?, month),
        .chinese => worldcal.chineseMonthDays(year, month),
        .hebrew => worldcal.hebrewMonthDays(year, month),
        .coptic, .ethiopian => worldcal.africaMonthDays(year, month),
    };
}

/// 0 = Sunday ... 6 = Saturday in the system's own week, or null for a day
/// outside the week. The Fixed Calendar's week restarts every month, so its
/// Sunday is generally not a civil Sunday.
pub fn weekdayOf(sys: System, date: Date) ?u8 {
    if (sys.isRosquin()) return null; // 13-day weeks; see rosquin.dayOfWeek
    if (sys != .fixed) return date.weekday();
    const v = fromCivil(.fixed, date);
    if (v.day == 29) return null;
    return @intCast((v.day - 1) % 7);
}

/// Whether the day is outside the week (Leap Day, Year Day).
pub fn isSpecial(sys: System, v: Ymd) bool {
    return (sys == .fixed and v.day == 29) or (sys.isRosquin() and rosquin.isSpecial(rosOf(v)));
}

/// The page of the grid that shows `v`. A Rosquin special day is in no month, so
/// it is shown with the page next to it.
pub fn pageOf(sys: System, v: Ymd) u8 {
    if (v.month != 0) return v.month;
    return rosquin.pageNear(sys.layout().?, v.day);
}

pub fn specialName(v: Ymd) []const u8 {
    if (rosquin.isSpecial(rosOf(v))) return rosquin.specialName(rosOf(v));
    return if (v.month == 6) "Leap Day" else "Year Day";
}

pub const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// "Saturday, October 31, 2026" in the given system, for a day panel.
pub fn describe(buf: []u8, sys: System, date: Date) []const u8 {
    const v = fromCivil(sys, date);
    if (sys.isRosquin()) {
        const code = rosquin.dayCode(date);
        if (rosquin.dayOfWeek(date)) |wd| {
            return std.fmt.bufPrint(buf, "{d} \u{b7} day {d} of the year \u{b7} {s}, Yr {d}, {s} {d} \u{b7} Wk {d}, day {d}", .{
                code, rosquin.dayOfYear(date), rosquin.day_names[wd - 1], v.year, monthName(sys, v.month), v.day, rosquin.weekOfYear(date).?, wd,
            }) catch "";
        }
        return std.fmt.bufPrint(buf, "{d} \u{b7} day {d} of the year \u{b7} {s}, Yr {d} \u{b7} inter-calendar day, in no week or month (falls in week {d})", .{ code, rosquin.dayOfYear(date), specialName(v), v.year, rosquin.weekNear(v.day) }) catch "";
    }
    if (weekdayOf(sys, date)) |wd|
    {
        var mb: [48]u8 = undefined;
        var yb: [64]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}, {s} {d}, {s}", .{ weekday_names[wd], monthLabel(&mb, sys, v.year, v.month), v.day, yearLabel(&yb, sys, v.year) }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s}, {d}", .{ specialName(v), v.year }) catch "";
}

/// Replaces the date tokens of the panel clock's format with the date in `sys`, leaving the
/// strftime codes for the caller. The Rosquin systems have all the tokens (see
/// common/rosquin.zig); the others have
///
///   @Y year   @n month name   @m month number   @d day of the month
///   @N weekday name   @e weekday 1-7 (Sunday is 1)   @@ a literal @
///
/// @D (day code), @y (day of the Rosquin year) and @w (Rosquin week) are Rosquin's: in another
/// system they still give the Rosquin values. On Fixed Calendar's Leap Day and Year Day, which are
/// in no month or week, @d and @N are the day's name and the others are empty.
pub fn expandTokens(allocator: std.mem.Allocator, format: []const u8, date: Date, sys: System) ![]u8 {
    if (sys.layout()) |layout| return rosquin.expand(allocator, format, date, layout);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const v = fromCivil(sys, date);
    const special = isSpecial(sys, v);
    const weekday = weekdayOf(sys, date);
    var month_buf: [48]u8 = undefined;
    var year_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '@' or i + 1 >= format.len) {
            try out.append(allocator, format[i]);
            continue;
        }
        i += 1;
        switch (format[i]) {
            '@' => try out.append(allocator, '@'),
            'Y' => try out.appendSlice(allocator, yearLabel(&year_buf, sys, v.year)),
            'n' => if (!special) try out.appendSlice(allocator, monthLabel(&month_buf, sys, v.year, v.month)),
            'm' => if (!special) try out.print(allocator, "{d}", .{v.month}),
            'd' => if (special) try out.appendSlice(allocator, specialName(v)) else try out.print(allocator, "{d}", .{v.day}),
            'N' => if (weekday) |w| try out.appendSlice(allocator, weekday_names[w]) else try out.appendSlice(allocator, specialName(v)),
            'e' => if (weekday) |w| try out.print(allocator, "{d}", .{w + 1}),
            'D' => try out.print(allocator, "{d}", .{rosquin.dayCode(date)}),
            'y' => try out.print(allocator, "{d}", .{rosquin.dayOfYear(date)}),
            'w' => if (rosquin.weekOfYear(date)) |w| try out.print(allocator, "{d}", .{w}),
            else => {
                try out.append(allocator, '@');
                try out.append(allocator, format[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- tests -------------------------------------------------------------------------------------

test "clock tokens in the other calendars" {
    const a = std.testing.allocator;
    const d: Date = .{ .year = 2026, .month = 11, .day = 13 };
    const g = try expandTokens(a, "%H:%M @N, @n @d, @Y @@ @q @D|", d, .gregorian);
    defer a.free(g);
    try std.testing.expectEqualStrings("%H:%M Friday, November 13, 2026 @ @q 18316|", g);
    // The Julian date is 13 days behind: October 31.
    const j = try expandTokens(a, "@n @d @m @e", d, .julian);
    defer a.free(j);
    try std.testing.expectEqualStrings("October 31 10 6", j);
    // Fixed Calendar: Year Day is in no month or week.
    const y = try expandTokens(a, "[@n][@N][@d]", .{ .year = 2026, .month = 12, .day = 31 }, .fixed);
    defer a.free(y);
    try std.testing.expectEqualStrings("[][Year Day][Year Day]", y);
    // Rosquin goes to its own tokens.
    const r = try expandTokens(a, "@D", d, .rosquin_months);
    defer a.free(r);
    try std.testing.expectEqualStrings("18316", r);
}

test "Julian is 13 days behind now" {
    const d: Date = .{ .year = 2026, .month = 10, .day = 31 };
    const j = fromCivil(.julian, d);
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 10, .day = 18 }, j);
    try std.testing.expect(toCivil(.julian, j).eql(d));
    // 14 Jan Julian = 1 Jan Gregorian (Old New Year), and Christmas Old Style = Jan 7.
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 12, .day = 25 }, fromCivil(.julian, .{ .year = 2027, .month = 1, .day = 7 }));
    // Julian leap day exists in 1900 (not Gregorian) and was Mar 13 civil.
    try std.testing.expectEqual(Ymd{ .year = 1900, .month = 2, .day = 29 }, fromCivil(.julian, .{ .year = 1900, .month = 3, .day = 13 }));
    try std.testing.expectEqual(@as(u16, 29), monthDays(.julian, 1900, 2));
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
    try std.testing.expectEqual(@as(u16, 29), monthDays(.fixed, 2028, 6));
    try std.testing.expectEqual(@as(u16, 28), monthDays(.fixed, 2026, 6));
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

test "the world calendars through calsys" {
    const d: Date = .{ .year = 2026, .month = 11, .day = 6 };
    inline for (.{ System.chinese, System.hebrew, System.coptic, System.ethiopian }) |sys| {
        try std.testing.expect(toCivil(sys, fromCivil(sys, d)).eql(d));
        // The pages of the day's year cover its month and the day is inside it.
        const v = fromCivil(sys, d);
        try std.testing.expect(v.day >= 1 and v.day <= monthDays(sys, v.year, v.month));
        try std.testing.expect(v.month >= 1 and v.month <= monthsIn(sys, v.year));
    }
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Month 9", monthLabel(&buf, .chinese, 2026, fromCivil(.chinese, d).month));
    try std.testing.expectEqualStrings("Bing-Wu, Fire Horse", yearLabel(&buf, .chinese, 2026));
    try std.testing.expectEqualStrings("Hathor", monthLabel(&buf, .coptic, 1743, 3));
}
