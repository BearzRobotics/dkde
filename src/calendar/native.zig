//! The native names and numerals of the Chinese, Hebrew, Coptic and Ethiopian
//! calendars, to show beside the Latin ones. All text is UTF-8 written into a
//! caller's buffer. They need fonts that have the scripts: the program carries
//! open-source ones (Noto Sans Hebrew, Ethiopic and Coptic, and a subset of Droid
//! Sans Fallback for the Chinese characters) and lets the user choose another.

const std = @import("std");
const calsys = @import("calsys.zig");
const worldcal = @import("worldcal.zig");

const System = calsys.System;

/// Whether the system has native names at all.
pub fn has(sys: System) bool {
    return switch (sys) {
        .chinese, .hebrew, .coptic, .ethiopian => true,
        else => false,
    };
}

/// The built-in font family that has the system's script.
pub fn family(sys: System) []const u8 {
    return switch (sys) {
        .chinese => "Droid Sans Fallback",
        .hebrew => "Noto Sans Hebrew",
        .coptic => "Noto Sans Coptic",
        .ethiopian => "Noto Sans Ethiopic",
        else => "",
    };
}

fn put(buf: []u8, n: *usize, cp: u21) void {
    n.* += std.unicode.utf8Encode(cp, buf[n.*..]) catch 0;
}

fn puts(buf: []u8, n: *usize, s: []const u8) void {
    if (n.* + s.len > buf.len) return;
    @memcpy(buf[n.*..][0..s.len], s);
    n.* += s.len;
}

// ---- Chinese --------------------------------------------------------------------------------

const cn_digits = [_][]const u8{ "", "一", "二", "三", "四", "五", "六", "七", "八", "九" };
const cn_months = [12][]const u8{ "正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月" };
const cn_stems = [10][]const u8{ "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" };
const cn_branches = [12][]const u8{ "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" };
const cn_animals = [12][]const u8{ "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" };
const cn_elements = [5][]const u8{ "木", "火", "土", "金", "水" };
const cn_weekdays = [7][]const u8{ "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" };

fn chineseDay(buf: []u8, d: u16) []const u8 {
    var n: usize = 0;
    if (d <= 10) {
        puts(buf, &n, if (d == 10) "初十" else "初");
        if (d < 10) puts(buf, &n, cn_digits[d]);
    } else if (d < 20) {
        puts(buf, &n, "十");
        puts(buf, &n, cn_digits[d - 10]);
    } else if (d == 20) {
        puts(buf, &n, "二十");
    } else if (d < 30) {
        puts(buf, &n, "廿");
        puts(buf, &n, cn_digits[d - 20]);
    } else puts(buf, &n, "三十");
    return buf[0..n];
}

// ---- Hebrew ---------------------------------------------------------------------------------

const he_months = [13][]const u8{ "ניסן", "אייר", "סיוון", "תמוז", "אב", "אלול", "תשרי", "חשוון", "כסלו", "טבת", "שבט", "אדר", "אדר ב׳" };
const he_weekdays = [7][]const u8{ "יום ראשון", "יום שני", "יום שלישי", "יום רביעי", "יום חמישי", "יום שישי", "שבת" };

/// A number as Hebrew letters (gematria), with the geresh or gershayim, 15 and 16 as 9+6 and 9+7.
fn gematria(buf: []u8, value: u32) []const u8 {
    var letters: [12]u21 = undefined;
    var count: usize = 0;
    var v = value;
    while (v >= 400 and count < 12) : (v -= 400) {
        letters[count] = 0x05EA; // ת
        count += 1;
    }
    const hundreds = [_]u21{ 0x05E7, 0x05E8, 0x05E9 }; // ק ר ש
    if (v >= 100) {
        letters[count] = hundreds[v / 100 - 1];
        count += 1;
        v %= 100;
    }
    const tens = [_]u21{ 0x05D9, 0x05DB, 0x05DC, 0x05DE, 0x05E0, 0x05E1, 0x05E2, 0x05E4, 0x05E6 }; // י כ ל מ נ ס ע פ צ
    const ones = [_]u21{ 0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, 0x05D8 }; // א ... ט
    if (v == 15 or v == 16) {
        letters[count] = 0x05D8; // ט
        letters[count + 1] = if (v == 15) 0x05D5 else 0x05D6; // ו, ז
        count += 2;
    } else {
        if (v >= 10) {
            letters[count] = tens[v / 10 - 1];
            count += 1;
        }
        if (v % 10 > 0) {
            letters[count] = ones[v % 10 - 1];
            count += 1;
        }
    }
    var n: usize = 0;
    for (letters[0..count], 0..) |c, i| {
        if (count > 1 and i == count - 1) put(buf, &n, 0x05F4); // ״ before the last letter
        put(buf, &n, c);
    }
    if (count == 1) put(buf, &n, 0x05F3); // ׳
    return buf[0..n];
}

// ---- Coptic and Ethiopian ------------------------------------------------------------------

const cop_months = [13][]const u8{ "ⲑⲱⲟⲩⲧ", "ⲡⲁⲟⲡⲓ", "ϩⲁⲑⲱⲣ", "ⲕⲟⲓⲁϩⲕ", "ⲧⲱⲃⲓ", "ⲙϣⲓⲣ", "ⲡⲁⲣⲉⲙϩⲁⲧ", "ⲫⲁⲣⲙⲟⲩⲑⲓ", "ⲡⲁϣⲁⲛⲥ", "ⲡⲁⲱⲛⲓ", "ⲉⲡⲏⲡ", "ⲙⲉⲥⲟⲣⲏ", "ⲡⲓⲕⲟⲩϫⲓ ⲛⲁⲃⲟⲧ" };
const et_months = [13][]const u8{ "መስከረም", "ጥቅምት", "ኅዳር", "ታኅሣሥ", "ጥር", "የካቲት", "መጋቢት", "ሚያዝያ", "ግንቦት", "ሰኔ", "ሐምሌ", "ነሐሴ", "ጳጉሜን" };
const et_weekdays = [7][]const u8{ "እሑድ", "ሰኞ", "ማክሰኞ", "ረቡዕ", "ሐሙስ", "ዓርብ", "ቅዳሜ" };

/// A number in Ge'ez numerals: ፩ to ፱, ፲ to ፺, ፻ (100) and ፼ (10000).
fn geez(buf: []u8, n: *usize, value: u32) void {
    if (value >= 10000) {
        const top = value / 10000;
        if (top > 1) geez(buf, n, top);
        put(buf, n, 0x137C);
        geez(buf, n, value % 10000);
    } else if (value >= 100) {
        const h = value / 100;
        if (h > 1) geez(buf, n, h);
        put(buf, n, 0x137B);
        geez(buf, n, value % 100);
    } else {
        if (value >= 10) put(buf, n, 0x1372 + @as(u21, @intCast(value / 10 - 1)));
        if (value % 10 > 0) put(buf, n, 0x1369 + @as(u21, @intCast(value % 10 - 1)));
    }
}

// ---- lines of text ---------------------------------------------------------------------------

/// The date in the system's script: "星期五 九月廿八 丙午年 火马". Where a script has no
/// numeral for the day or the year (Coptic), the digits are used.
pub fn dateLine(buf: []u8, sys: System, date: calsys.Date) []const u8 {
    const v = calsys.fromCivil(sys, date);
    var n: usize = 0;
    if (weekday(sys, date.weekday())) |w| {
        puts(buf, &n, w);
        puts(buf, &n, " ");
    }
    var mb: [64]u8 = undefined;
    puts(buf, &n, month(&mb, sys, v.year, v.month));
    puts(buf, &n, if (sys == .chinese) "" else " ");
    var db: [32]u8 = undefined;
    const d = day(&db, sys, v.day);
    if (d.len > 0) {
        puts(buf, &n, d);
    } else {
        var nb: [8]u8 = undefined;
        puts(buf, &n, std.fmt.bufPrint(&nb, "{d}", .{v.day}) catch "");
    }
    puts(buf, &n, " ");
    var yb: [64]u8 = undefined;
    const y = year(&yb, sys, v.year);
    if (y.len > 0) {
        puts(buf, &n, y);
    } else {
        var nb: [12]u8 = undefined;
        puts(buf, &n, std.fmt.bufPrint(&nb, "{d}", .{v.year}) catch "");
    }
    return buf[0..n];
}

/// The title of a page in the system's script: "九月 丙午年 火马".
pub fn pageLine(buf: []u8, sys: System, y: i32, page: u8) []const u8 {
    var n: usize = 0;
    var mb: [64]u8 = undefined;
    puts(buf, &n, month(&mb, sys, y, page));
    puts(buf, &n, " ");
    var yb: [64]u8 = undefined;
    const yt = year(&yb, sys, y);
    if (yt.len > 0) {
        puts(buf, &n, yt);
    } else {
        var nb: [12]u8 = undefined;
        puts(buf, &n, std.fmt.bufPrint(&nb, "{d}", .{y}) catch "");
    }
    return buf[0..n];
}

// ---- the public face ---------------------------------------------------------------------------

/// The weekday (0 = Sunday) in the system's script, or null.
pub fn weekday(sys: System, wd: u8) ?[]const u8 {
    return switch (sys) {
        .chinese => cn_weekdays[wd % 7],
        .hebrew => he_weekdays[wd % 7],
        .ethiopian => et_weekdays[wd % 7],
        else => null,
    };
}

/// The month in the system's script ("九月", "תשרי", "ⲑⲱⲟⲩⲧ", "መስከረም"); "" if there is none.
pub fn month(buf: []u8, sys: System, y: i32, page: u8) []const u8 {
    var n: usize = 0;
    switch (sys) {
        .chinese => {
            const t = worldcal.chineseYear(y);
            if (page < 1 or page > t.count) return "";
            if (t.leap[page - 1]) puts(buf, &n, "闰");
            puts(buf, &n, cn_months[(t.number[page - 1] -| 1) % 12]);
        },
        .hebrew => {
            const m = worldcal.hebrewMonthNumber(y, page);
            if (m == 12 and worldcal.hebrewLeap(y)) {
                puts(buf, &n, "אדר א׳");
            } else puts(buf, &n, he_months[(m -| 1) % 13]);
        },
        .coptic => puts(buf, &n, cop_months[(@as(usize, page) -| 1) % 13]),
        .ethiopian => puts(buf, &n, et_months[(@as(usize, page) -| 1) % 13]),
        else => {},
    }
    return buf[0..n];
}

/// The day of the month as a numeral in the system's script, or "" (Coptic uses digits).
pub fn day(buf: []u8, sys: System, d: u16) []const u8 {
    var n: usize = 0;
    switch (sys) {
        .chinese => return chineseDay(buf, d),
        .hebrew => return gematria(buf, d),
        .ethiopian => geez(buf, &n, d),
        else => {},
    }
    return buf[0..n];
}

/// The year in the system's script: "丙午年 火马", "ה׳תשפ״ז", "፳፻፲፱"; "" for Coptic.
pub fn year(buf: []u8, sys: System, y: i32) []const u8 {
    var n: usize = 0;
    switch (sys) {
        .chinese => {
            const i: usize = @intCast(@mod(y - 4, 60));
            puts(buf, &n, cn_stems[i % 10]);
            puts(buf, &n, cn_branches[i % 12]);
            puts(buf, &n, "年 ");
            puts(buf, &n, cn_elements[(i % 10) / 2]);
            puts(buf, &n, cn_animals[i % 12]);
        },
        .hebrew => {
            var inner: [48]u8 = undefined;
            const thousands: u32 = @intCast(@divFloor(y, 1000));
            if (thousands > 0) {
                var tb: [16]u8 = undefined;
                puts(buf, &n, gematria(&tb, thousands));
            }
            puts(buf, &n, gematria(&inner, @intCast(@mod(y, 1000))));
        },
        .ethiopian => geez(buf, &n, @intCast(@max(y, 0))),
        else => {},
    }
    return buf[0..n];
}

test "Chinese" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("廿八", day(&b, .chinese, 28));
    try std.testing.expectEqualStrings("初一", day(&b, .chinese, 1));
    try std.testing.expectEqualStrings("初十", day(&b, .chinese, 10));
    try std.testing.expectEqualStrings("二十", day(&b, .chinese, 20));
    try std.testing.expectEqualStrings("三十", day(&b, .chinese, 30));
    try std.testing.expectEqualStrings("丙午年 火马", year(&b, .chinese, 2026));
    try std.testing.expectEqualStrings("九月", month(&b, .chinese, 2026, 9));
    try std.testing.expectEqualStrings("闰六月", month(&b, .chinese, 2025, 7));
}

test "Hebrew gematria" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("כ״ו", day(&b, .hebrew, 26));
    try std.testing.expectEqualStrings("ט״ו", day(&b, .hebrew, 15));
    try std.testing.expectEqualStrings("ט״ז", day(&b, .hebrew, 16));
    try std.testing.expectEqualStrings("א׳", day(&b, .hebrew, 1));
    try std.testing.expectEqualStrings("ל׳", day(&b, .hebrew, 30));
    try std.testing.expectEqualStrings("ה׳תשפ״ז", year(&b, .hebrew, 5787));
    try std.testing.expectEqualStrings("חשוון", month(&b, .hebrew, 5787, 2));
}

test "Ethiopian numerals" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("፳፯", day(&b, .ethiopian, 27));
    try std.testing.expectEqualStrings("፳፻፲፱", year(&b, .ethiopian, 2019));
    try std.testing.expectEqualStrings("ጥቅምት", month(&b, .ethiopian, 2019, 2));
    try std.testing.expectEqualStrings("ሰኞ", weekday(.ethiopian, 1).?);
    try std.testing.expectEqualStrings("ⲑⲱⲟⲩⲧ", month(&b, .coptic, 1743, 1));
}

test "a date line" {
    var b: [160]u8 = undefined;
    const d: calsys.Date = .{ .year = 2026, .month = 11, .day = 6 };
    try std.testing.expectEqualStrings("星期五 九月廿八 丙午年 火马", dateLine(&b, .chinese, d));
    try std.testing.expectEqualStrings("יום שישי חשוון כ״ו ה׳תשפ״ז", dateLine(&b, .hebrew, d));
    try std.testing.expectEqualStrings("ዓርብ ጥቅምት ፳፯ ፳፻፲፱", dateLine(&b, .ethiopian, d));
    try std.testing.expectEqualStrings("ⲡⲁⲟⲡⲓ 27 1743", dateLine(&b, .coptic, d));
}
