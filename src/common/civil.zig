//! Proleptic Gregorian calendar arithmetic with no time zones: days since
//! 1970-01-01, weekdays, month lengths and Easter. Shared by the calendar
//! app's events and its liturgical calendars, and by the panel's reminders.

const std = @import("std");

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    pub fn days(self: Date) i64 {
        return daysFromCivil(self.year, self.month, self.day);
    }

    pub fn fromDays(n: i64) Date {
        return civilFromDays(n);
    }

    pub fn addDays(self: Date, n: i64) Date {
        return civilFromDays(self.days() + n);
    }

    /// 0 = Sunday ... 6 = Saturday.
    pub fn weekday(self: Date) u8 {
        return weekdayOfDays(self.days());
    }
};

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(n: i64) Date {
    const z = n + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + (if (m <= 2) @as(i64, 1) else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// 0 = Sunday ... 6 = Saturday.
pub fn weekdayOfDays(n: i64) u8 {
    return @intCast(@mod(n + 4, 7));
}

pub fn isLeap(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

/// Western (Gregorian) Easter Sunday.
pub fn easter(year: i32) Date {
    const a = @mod(year, 19);
    const b = @divFloor(year, 100);
    const c = @mod(year, 100);
    const d = @divFloor(b, 4);
    const e = @mod(b, 4);
    const f = @divFloor(b + 8, 25);
    const g = @divFloor(b - f + 1, 3);
    const h = @mod(19 * a + b - d - g + 15, 30);
    const i = @divFloor(c, 4);
    const k = @mod(c, 4);
    const l = @mod(32 + 2 * e + 2 * i - h - k, 7);
    const m = @divFloor(a + 11 * h + 22 * l, 451);
    const month = @divFloor(h + l - 7 * m + 114, 31);
    const day = @mod(h + l - 7 * m + 114, 31) + 1;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

test "civil round trip and weekdays" {
    const d: Date = .{ .year = 2026, .month = 10, .day = 31 };
    try std.testing.expectEqual(@as(u8, 6), d.weekday()); // Saturday
    try std.testing.expect(Date.fromDays(d.days()).eql(d));
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expect(Date.fromDays(-1).eql(.{ .year = 1969, .month = 12, .day = 31 }));
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2028, 2));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2100, 2));
}

test "easter" {
    try std.testing.expect(easter(2026).eql(.{ .year = 2026, .month = 4, .day = 5 }));
    try std.testing.expect(easter(2025).eql(.{ .year = 2025, .month = 4, .day = 20 }));
    try std.testing.expect(easter(2024).eql(.{ .year = 2024, .month = 3, .day = 31 }));
    try std.testing.expect(easter(2038).eql(.{ .year = 2038, .month = 4, .day = 25 }));
}
