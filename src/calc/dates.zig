//! Date calculation, as in the Windows 7 calculator: the time between two
//! dates, and a date plus or minus years, months and days.

const std = @import("std");

pub const Date = struct { year: i32, month: u8, day: u8 };

fn isLeap(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(y)) 29 else 28,
    };
}

/// Days since 1970-01-01 (proleptic Gregorian).
pub fn toDays(d: Date) i64 {
    const y: i64 = if (d.month <= 2) @as(i64, d.year) - 1 else d.year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = d.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn fromDays(n: i64) Date {
    const z = n + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = m, .day = d };
}

/// "2024-07-19" (also 2024/7/19 and 19.7.2024).
pub fn parse(text: []const u8) ?Date {
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
    var d: u8 = undefined;
    if (parts[0].len == 4) {
        y = std.fmt.parseInt(i32, parts[0], 10) catch return null;
        m = std.fmt.parseInt(u8, parts[1], 10) catch return null;
        d = std.fmt.parseInt(u8, parts[2], 10) catch return null;
    } else if (parts[2].len == 4) {
        // Day first, as most of the world writes it.
        d = std.fmt.parseInt(u8, parts[0], 10) catch return null;
        m = std.fmt.parseInt(u8, parts[1], 10) catch return null;
        y = std.fmt.parseInt(i32, parts[2], 10) catch return null;
    } else return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

pub const Span = struct { years: i64, months: i64, weeks: i64, days: i64, total_days: i64 };

/// The time from `a` to `b` in whole years, months, weeks and days (and in
/// days alone). Always counted forward from the earlier date.
pub fn between(a: Date, b: Date) Span {
    var from = a;
    var to = b;
    if (toDays(b) < toDays(a)) {
        from = b;
        to = a;
    }
    const total = toDays(to) - toDays(from);
    var months: i64 = (@as(i64, to.year) - from.year) * 12 + @as(i64, to.month) - from.month;
    if (to.day < from.day) months -= 1;
    // Days left after the whole months.
    const anchor = addMonths(from, months);
    var days = toDays(to) - toDays(anchor);
    if (days < 0) {
        months -= 1;
        days = toDays(to) - toDays(addMonths(from, months));
    }
    return .{ .years = @divFloor(months, 12), .months = @mod(months, 12), .weeks = @divFloor(days, 7), .days = @mod(days, 7), .total_days = total };
}

/// `d` moved by whole months; a day that does not exist (31 Feb) becomes the
/// month's last day.
pub fn addMonths(d: Date, months: i64) Date {
    const index = @as(i64, d.year) * 12 + (d.month - 1) + months;
    const y: i32 = @intCast(@divFloor(index, 12));
    const m: u8 = @intCast(@mod(index, 12) + 1);
    return .{ .year = y, .month = m, .day = @min(d.day, daysInMonth(y, m)) };
}

pub fn add(d: Date, years: i64, months: i64, days: i64) Date {
    const moved = addMonths(d, years * 12 + months);
    return fromDays(toDays(moved) + days);
}

pub fn weekday(d: Date) []const u8 {
    const names = [_][]const u8{ "Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday" };
    return names[@intCast(@mod(toDays(d), 7))];
}

test "days" {
    try std.testing.expectEqual(@as(i64, 0), toDays(.{ .year = 1970, .month = 1, .day = 1 }));
    const d: Date = .{ .year = 2024, .month = 2, .day = 29 };
    try std.testing.expectEqual(d, fromDays(toDays(d)));
    try std.testing.expectEqualStrings("Thursday", weekday(.{ .year = 2024, .month = 2, .day = 29 }));
    try std.testing.expectEqual(Date{ .year = 2024, .month = 7, .day = 19 }, parse("2024-07-19").?);
    try std.testing.expectEqual(Date{ .year = 2024, .month = 7, .day = 19 }, parse("19.7.2024").?);
    try std.testing.expect(parse("2023-02-29") == null);
}

test "between and adding" {
    const s = between(.{ .year = 2020, .month = 1, .day = 31 }, .{ .year = 2024, .month = 3, .day = 15 });
    try std.testing.expectEqual(@as(i64, 4), s.years);
    try std.testing.expectEqual(@as(i64, 1), s.months);
    try std.testing.expectEqual(@as(i64, 2), s.weeks);
    try std.testing.expectEqual(@as(i64, 1), s.days);
    try std.testing.expectEqual(@as(i64, 1505), s.total_days);
    try std.testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, add(.{ .year = 2024, .month = 1, .day = 31 }, 0, 1, 0));
    try std.testing.expectEqual(Date{ .year = 2025, .month = 3, .day = 1 }, add(.{ .year = 2024, .month = 2, .day = 29 }, 1, 0, 1));
    try std.testing.expectEqual(Date{ .year = 2023, .month = 12, .day = 31 }, add(.{ .year = 2024, .month = 1, .day = 1 }, 0, 0, -1));
}
