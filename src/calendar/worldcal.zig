//! Calendars of other traditions, as arithmetic on civil days (days since
//! 1970-01-01, see common/civil.zig). The algorithms are those of Reingold and
//! Dershowitz, "Calendrical Calculations".
//!
//!  * Coptic and Ethiopian: 12 months of 30 days and a short 13th month of 5 days
//!    (6 in a leap year, the year after every year that leaves 3 when divided by 4).
//!    The Ethiopian calendar is the Coptic one 276 years later.
//!  * Hebrew: the lunisolar calendar of the molad and the four postponements.
//!    Pages are counted from Tishri, the new year; a leap year has Adar I and II.
//!  * Chinese: the lunisolar calendar, from computed new moons and solar terms,
//!    in China Standard Time (UTC+8). A year starts at the Chinese New Year; a
//!    leap year has 13 months, the leap month being the first without a major
//!    solar term. Pages are the months in order, with the leap month in its place.

const std = @import("std");
const civil = @import("common").civil;
const lunar = @import("lunar.zig");

pub const Ymd = struct { year: i32, month: u8, day: u8 };

/// Fixed day number (Reingold-Dershowitz "RD"; 0001-01-01 Gregorian is 1).
fn rdOf(days: i64) i64 {
    return days + 719163;
}

fn daysOf(rd: i64) i64 {
    return rd - 719163;
}

// ---- Coptic and Ethiopian -----------------------------------------------------------------------

pub const Africa = enum { coptic, ethiopian };

fn epoch(kind: Africa) i64 {
    return switch (kind) {
        .coptic => 103605,
        .ethiopian => 2796,
    };
}

fn africaFixed(kind: Africa, y: i64, m: i64, d: i64) i64 {
    return epoch(kind) - 1 + 365 * (y - 1) + @divFloor(y, 4) + 30 * (m - 1) + d;
}

pub fn africaFromDays(kind: Africa, days: i64) Ymd {
    const date = rdOf(days);
    const y = @divFloor(4 * (date - epoch(kind)) + 1463, 1461);
    const m = @divFloor(date - africaFixed(kind, y, 1, 1), 30) + 1;
    const d = date + 1 - africaFixed(kind, y, m, 1);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

pub fn africaToDays(kind: Africa, v: Ymd) i64 {
    return daysOf(africaFixed(kind, v.year, v.month, v.day));
}

pub fn africaLeap(year: i32) bool {
    return @mod(year, 4) == 3;
}

pub fn africaMonthDays(year: i32, month: u8) u8 {
    if (month < 13) return 30;
    return if (africaLeap(year)) 6 else 5;
}

pub const coptic_months = [13][]const u8{ "Thout", "Paopi", "Hathor", "Koiak", "Tobi", "Meshir", "Paremhat", "Paremoud", "Pashons", "Paoni", "Epip", "Mesori", "Pi Kogi Enavot" };
pub const ethiopian_months = [13][]const u8{ "Meskerem", "Tikimt", "Hidar", "Tahsas", "Tir", "Yekatit", "Megabit", "Miazia", "Genbot", "Sene", "Hamle", "Nehase", "Pagume" };

// ---- Hebrew ---------------------------------------------------------------------------------------

const hebrew_epoch: i64 = -1373427;

pub fn hebrewLeap(year: i32) bool {
    return @mod(7 * @as(i64, year) + 1, 19) < 7;
}

fn hebrewElapsedDays(year: i64) i64 {
    const months = @divFloor(235 * year - 234, 19);
    const parts = 12084 + 13753 * months;
    const days = 29 * months + @divFloor(parts, 25920);
    return if (@mod(3 * (days + 1), 7) < 3) days + 1 else days;
}

fn hebrewCorrection(year: i64) i64 {
    const ny0 = hebrewElapsedDays(year - 1);
    const ny1 = hebrewElapsedDays(year);
    const ny2 = hebrewElapsedDays(year + 1);
    if (ny2 - ny1 == 356) return 2;
    if (ny1 - ny0 == 382) return 1;
    return 0;
}

fn hebrewNewYear(year: i64) i64 {
    return hebrew_epoch + hebrewElapsedDays(year) + hebrewCorrection(year);
}

fn hebrewYearDays(year: i64) i64 {
    return hebrewNewYear(year + 1) - hebrewNewYear(year);
}

fn hebrewLastMonth(year: i64) i64 {
    return if (hebrewLeap(@intCast(year))) 13 else 12;
}

/// Days in a Hebrew month, numbered from Nisan = 1 (Tishri = 7, Adar II = 13).
fn hebrewLastDay(year: i64, month: i64) i64 {
    const len = hebrewYearDays(year);
    switch (month) {
        2, 4, 6, 10, 13 => return 29,
        12 => if (!hebrewLeap(@intCast(year))) return 29,
        8 => if (@mod(len, 10) != 5) return 29,
        9 => if (@mod(len, 10) == 3) return 29,
        else => {},
    }
    return 30;
}

fn hebrewFixed(year: i64, month: i64, day: i64) i64 {
    var total = hebrewNewYear(year) + day - 1;
    const last = hebrewLastMonth(year);
    if (month < 7) {
        var m: i64 = 7;
        while (m <= last) : (m += 1) total += hebrewLastDay(year, m);
        m = 1;
        while (m < month) : (m += 1) total += hebrewLastDay(year, m);
    } else {
        var m: i64 = 7;
        while (m < month) : (m += 1) total += hebrewLastDay(year, m);
    }
    return total;
}

/// The Hebrew month number (Nisan = 1) of the `page`-th month counted from Tishri.
fn hebrewMonthOfPage(year: i64, page: i64) i64 {
    const first_half = hebrewLastMonth(year) - 6; // Tishri to Adar (II)
    return if (page <= first_half) 6 + page else page - first_half;
}

fn hebrewPageOfMonth(year: i64, month: i64) i64 {
    const first_half = hebrewLastMonth(year) - 6;
    return if (month >= 7) month - 6 else month + first_half;
}

pub fn hebrewFromDays(days: i64) Ymd {
    const date = rdOf(days);
    const approx = @divFloor((date - hebrew_epoch) * 98496, 35975351) + 1;
    var year = approx - 1;
    while (hebrewNewYear(year + 1) <= date) year += 1;
    var month: i64 = if (date < hebrewFixed(year, 1, 1)) 7 else 1;
    while (date > hebrewFixed(year, month, hebrewLastDay(year, month))) month += 1;
    const day = date - hebrewFixed(year, month, 1) + 1;
    return .{ .year = @intCast(year), .month = @intCast(hebrewPageOfMonth(year, month)), .day = @intCast(day) };
}

pub fn hebrewToDays(v: Ymd) i64 {
    const month = hebrewMonthOfPage(v.year, v.month);
    return daysOf(hebrewFixed(v.year, month, v.day));
}

pub fn hebrewMonthsIn(year: i32) u8 {
    return @intCast(hebrewLastMonth(year));
}

pub fn hebrewMonthDays(year: i32, page: u8) u8 {
    return @intCast(hebrewLastDay(year, hebrewMonthOfPage(year, page)));
}

/// The Hebrew month number (Nisan = 1 ... Elul = 6, Tishri = 7, Adar = 12, Adar II = 13) of a page.
pub fn hebrewMonthNumber(year: i32, page: u8) u8 {
    return @intCast(hebrewMonthOfPage(year, page));
}

/// The name of the `page`-th month counted from Tishri.
pub fn hebrewMonthName(year: i32, page: u8) []const u8 {
    const names = [_][]const u8{ "Nisan", "Iyyar", "Sivan", "Tammuz", "Av", "Elul", "Tishri", "Heshvan", "Kislev", "Tevet", "Shevat", "Adar", "Adar II" };
    const m = hebrewMonthOfPage(year, page);
    if (m == 12 and hebrewLeap(year)) return "Adar I";
    return names[@intCast(m - 1)];
}

// ---- Chinese --------------------------------------------------------------------------------------

const china_zone: f64 = 8.0 / 24.0;
const synodic: f64 = 29.530588861;

/// The sun's apparent longitude in degrees at UTC `t` (days since 1970), Meeus ch. 25.
fn solarLongitude(t: f64) f64 {
    const jd = t + 2440587.5 + 69.0 / 86400.0;
    const c = (jd - 2451545.0) / 36525.0;
    const rad = std.math.pi / 180.0;
    const l0 = 280.46646 + 36000.76983 * c + 0.0003032 * c * c;
    const m = 357.52911 + 35999.05029 * c - 0.0001537 * c * c;
    const center = (1.914602 - 0.004817 * c - 0.000014 * c * c) * @sin(m * rad) + (0.019993 - 0.000101 * c) * @sin(2 * m * rad) + 0.000289 * @sin(3 * m * rad);
    const omega = 125.04 - 1934.136 * c;
    const lon = l0 + center - 0.00569 - 0.00478 * @sin(omega * rad);
    return @mod(lon, 360.0);
}

/// The solar longitude at the start of civil day `d` in China.
fn startLongitude(d: i64) f64 {
    return solarLongitude(@as(f64, @floatFromInt(d)) - china_zone);
}

/// 1 to 12: the major solar term (the sign of the zodiac, from 2 = about Feb 19) the day is in.
fn majorTerm(d: i64) i64 {
    const s: i64 = @intFromFloat(@floor(startLongitude(d) / 30.0));
    return @mod(2 + s - 1, 12) + 1;
}

fn newMoonOnOrAfterDay(d: i64) i64 {
    const t = lunar.newMoonAtOrAfter(@as(f64, @floatFromInt(d)) - china_zone);
    return @intFromFloat(@floor(t + china_zone));
}

fn newMoonBeforeDay(d: i64) i64 {
    const t = lunar.newMoonBefore(@as(f64, @floatFromInt(d)) - china_zone);
    return @intFromFloat(@floor(t + china_zone));
}

fn noMajorTerm(d: i64) bool {
    return majorTerm(d) == majorTerm(newMoonOnOrAfterDay(d + 1));
}

fn deviation(d: i64) f64 {
    return @mod(startLongitude(d) - 270.0 + 540.0, 360.0) - 180.0;
}

/// The day of the winter solstice on or before day `date`.
fn winterSolsticeOnOrBefore(date: i64) i64 {
    var d = date;
    var next = deviation(d + 1);
    while (true) : (d -= 1) {
        const here = deviation(d);
        if (next > 0 and here <= 0) return d;
        next = here;
    }
}

fn newYearInSui(date: i64) i64 {
    const s1 = winterSolsticeOnOrBefore(date);
    const s2 = winterSolsticeOnOrBefore(s1 + 370);
    const m12 = newMoonOnOrAfterDay(s1 + 1);
    const m13 = newMoonOnOrAfterDay(m12 + 1);
    const next_m11 = newMoonBeforeDay(s2 + 1);
    const months: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(next_m11 - m12)) / synodic));
    if (months == 12 and (noMajorTerm(m12) or noMajorTerm(m13))) return newMoonOnOrAfterDay(m13 + 1);
    return m13;
}

fn newYearOnOrBefore(date: i64) i64 {
    const ny = newYearInSui(date);
    return if (date >= ny) ny else newYearInSui(date - 180);
}

/// Day (since 1970) of the Chinese New Year that falls in Gregorian year `year`.
pub fn chineseNewYear(year: i32) i64 {
    return newYearOnOrBefore(civil.daysFromCivil(year, 7, 1));
}

/// The months of one Chinese year.
pub const ChineseYear = struct {
    year: i32 = 0,
    count: u8 = 0,
    /// First day of each month, and one more: the first day of the next year.
    start: [15]i64 = undefined,
    number: [14]u8 = undefined,
    leap: [14]bool = undefined,
};

var cache: [4]ChineseYear = @splat(.{});
var cache_next: usize = 0;

pub fn chineseYear(year: i32) *const ChineseYear {
    for (&cache) |*e| if (e.count != 0 and e.year == year) return e;
    var y: ChineseYear = .{ .year = year };
    const ny = chineseNewYear(year);
    const next = chineseNewYear(year + 1);
    var m = ny;
    while (m < next and y.count < 14) {
        y.start[y.count] = m;
        y.count += 1;
        m = newMoonOnOrAfterDay(m + 1);
    }
    y.start[y.count] = next;
    var leap_at: usize = 99;
    if (y.count == 13) {
        var i: usize = 0;
        while (i < 13) : (i += 1) {
            if (noMajorTerm(y.start[i])) {
                leap_at = i;
                break;
            }
        }
    }
    var i: usize = 0;
    while (i < y.count) : (i += 1) {
        y.leap[i] = i == leap_at;
        y.number[i] = @intCast(if (i < leap_at) i + 1 else i);
    }
    cache[cache_next] = y;
    cache_next = (cache_next + 1) % cache.len;
    return &cache[(cache_next + cache.len - 1) % cache.len];
}

/// `year` is the Gregorian year the Chinese year starts in; `month` counts the
/// months in order from 1 (a leap month included).
pub fn chineseFromDays(days: i64) Ymd {
    var year = civil.civilFromDays(days).year;
    var t = chineseYear(year);
    if (days < t.start[0]) {
        year -= 1;
        t = chineseYear(year);
    } else if (days >= t.start[t.count]) {
        year += 1;
        t = chineseYear(year);
    }
    var i: usize = t.count;
    while (i > 0) : (i -= 1) if (days >= t.start[i - 1]) break;
    return .{ .year = year, .month = @intCast(i), .day = @intCast(days - t.start[i - 1] + 1) };
}

pub fn chineseToDays(v: Ymd) i64 {
    return chineseYear(v.year).start[v.month - 1] + v.day - 1;
}

pub fn chineseMonthsIn(year: i32) u8 {
    return chineseYear(year).count;
}

pub fn chineseMonthDays(year: i32, month: u8) u8 {
    const t = chineseYear(year);
    if (month < 1 or month > t.count) return 30;
    return @intCast(t.start[month] - t.start[month - 1]);
}

/// "Month 6" or "Leap Month 6".
pub fn chineseMonthName(buf: []u8, year: i32, month: u8) []const u8 {
    const t = chineseYear(year);
    if (month < 1 or month > t.count) return "";
    return std.fmt.bufPrint(buf, "{s}Month {d}", .{ if (t.leap[month - 1]) "Leap " else "", t.number[month - 1] }) catch "";
}

const stems = [10][]const u8{ "Jia", "Yi", "Bing", "Ding", "Wu", "Ji", "Geng", "Xin", "Ren", "Gui" };
const branches = [12][]const u8{ "Zi", "Chou", "Yin", "Mao", "Chen", "Si", "Wu", "Wei", "Shen", "You", "Xu", "Hai" };
const animals = [12][]const u8{ "Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake", "Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig" };
const elements = [5][]const u8{ "Wood", "Fire", "Earth", "Metal", "Water" };

/// "Bing-Wu, Fire Horse" for the Chinese year that starts in Gregorian `year`.
pub fn chineseYearName(buf: []u8, year: i32) []const u8 {
    const n: usize = @intCast(@mod(year - 4, 60));
    return std.fmt.bufPrint(buf, "{s}-{s}, {s} {s}", .{ stems[n % 10], branches[n % 12], elements[(n % 10) / 2], animals[n % 12] }) catch "";
}

// ---- tests --------------------------------------------------------------------------------------

fn dayOf(y: i32, m: u8, d: u8) i64 {
    return civil.daysFromCivil(y, m, d);
}

test "Ethiopian and Coptic new year" {
    try std.testing.expectEqual(Ymd{ .year = 2019, .month = 1, .day = 1 }, africaFromDays(.ethiopian, dayOf(2026, 9, 11)));
    try std.testing.expectEqual(Ymd{ .year = 1743, .month = 1, .day = 1 }, africaFromDays(.coptic, dayOf(2026, 9, 11)));
    // The year after 2018 has a 6-day Pagume: 2027-09-11 is still Pagume 5, and 12 is the new year 2020... check the round trip.
    var n = dayOf(2000, 1, 1);
    while (n < dayOf(2040, 1, 1)) : (n += 1) {
        try std.testing.expectEqual(n, africaToDays(.ethiopian, africaFromDays(.ethiopian, n)));
        try std.testing.expectEqual(n, africaToDays(.coptic, africaFromDays(.coptic, n)));
    }
    // Christmas on the Ethiopian calendar: 29 Tahsas, January 7 (Gregorian) in 2027.
    try std.testing.expectEqual(Ymd{ .year = 2019, .month = 4, .day = 29 }, africaFromDays(.ethiopian, dayOf(2027, 1, 7)));
    try std.testing.expectEqual(@as(u8, 6), africaMonthDays(2019, 13));
    try std.testing.expectEqual(@as(u8, 5), africaMonthDays(2018, 13));
}

test "Hebrew" {
    // Rosh Hashanah 5787 begins on the day of 2026-09-12; Passover 5786 is 15 Nisan = 2026-04-02.
    try std.testing.expectEqual(Ymd{ .year = 5787, .month = 1, .day = 1 }, hebrewFromDays(dayOf(2026, 9, 12)));
    const pesach = hebrewFromDays(dayOf(2026, 4, 2));
    try std.testing.expectEqual(@as(i32, 5786), pesach.year);
    try std.testing.expectEqual(@as(u8, 15), pesach.day);
    try std.testing.expectEqualStrings("Nisan", hebrewMonthName(pesach.year, pesach.month));
    // Yom Kippur: 10 Tishri.
    try std.testing.expectEqual(Ymd{ .year = 5787, .month = 1, .day = 10 }, hebrewFromDays(dayOf(2026, 9, 21)));
    // 5784 was a leap year (Adar I and II).
    try std.testing.expect(hebrewLeap(5784));
    try std.testing.expectEqual(@as(u8, 13), hebrewMonthsIn(5784));
    var n = dayOf(1990, 1, 1);
    while (n < dayOf(2040, 1, 1)) : (n += 1) try std.testing.expectEqual(n, hebrewToDays(hebrewFromDays(n)));
}

test "Chinese new year" {
    try std.testing.expectEqual(dayOf(2026, 2, 17), chineseNewYear(2026));
    try std.testing.expectEqual(dayOf(2025, 1, 29), chineseNewYear(2025));
    try std.testing.expectEqual(dayOf(2024, 2, 10), chineseNewYear(2024));
    try std.testing.expectEqual(dayOf(2023, 1, 22), chineseNewYear(2023));
    try std.testing.expectEqual(dayOf(2027, 2, 6), chineseNewYear(2027));
    try std.testing.expectEqual(dayOf(2020, 1, 25), chineseNewYear(2020));
}

test "Chinese months and leap months" {
    // 2025 has a leap sixth month; 2023 a leap second month; 2026 has none.
    const y2025 = chineseYear(2025);
    try std.testing.expectEqual(@as(u8, 13), y2025.count);
    try std.testing.expect(y2025.leap[6] and y2025.number[6] == 6);
    const y2023 = chineseYear(2023);
    try std.testing.expect(y2023.leap[2] and y2023.number[2] == 2);
    try std.testing.expectEqual(@as(u8, 12), chineseYear(2026).count);
    // Mid-Autumn Festival 2026 (15th of month 8) is September 25.
    const mid = chineseFromDays(dayOf(2026, 9, 25));
    try std.testing.expectEqual(Ymd{ .year = 2026, .month = 8, .day = 15 }, mid);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bing-Wu, Fire Horse", chineseYearName(&buf, 2026));
    var n = dayOf(2019, 6, 1);
    while (n < dayOf(2030, 1, 1)) : (n += 7) try std.testing.expectEqual(n, chineseToDays(chineseFromDays(n)));
}
