//! The Russian Orthodox calendar (Old Calendar): Pascha by the Julian
//! reckoning, the Triodion and Pentecostarion counted from it, the fixed
//! feasts and saints by their Julian dates (from liturgy-ru.txt), and the four
//! fasting seasons with the food that is allowed each day.
//!
//!   ⛔  total fast      🥣  strict fast: no meat, dairy, fish, oil or wine
//!   🍇  wine and oil    🐟  fish (shown with 🍇)     🍷  wine, no oil
//!   🧀  dairy, eggs and fish allowed (no meat)

const std = @import("std");
const common = @import("common");
const calsys = @import("calsys.zig");
const liturgy = @import("liturgy.zig");

const civil = common.civil;
const Date = civil.Date;
const Day = liturgy.Day;
const Color = liturgy.Color;

/// Orthodox Pascha (Julian reckoning, Meeus), as a civil day number.
pub fn paschaDays(julian_year: i32) i64 {
    const a = @mod(julian_year, 4);
    const b = @mod(julian_year, 7);
    const c = @mod(julian_year, 19);
    const d = @mod(19 * c + 15, 30);
    const e = @mod(2 * a + 4 * b - d + 34, 7);
    const month: u8 = @intCast(@divFloor(d + e + 114, 31));
    const day: u8 = @intCast(@mod(d + e + 114, 31) + 1);
    return calsys.toCivil(.julian, .{ .year = julian_year, .month = month, .day = day }).days();
}

const Period = enum { none, publican, bright, trinity, cheesefare, lent, holy_week, apostles, dormition, nativity, svyatki };

fn periodOf(j: calsys.Ymd, delta: i64) Period {
    if (delta >= 0 and delta <= 6) return .bright;
    if (delta >= 49 and delta <= 55) return .trinity;
    if ((j.month == 12 and j.day >= 25) or (j.month == 1 and j.day <= 4)) return .svyatki;
    if (delta >= -69 and delta <= -64) return .publican;
    if (delta >= -55 and delta <= -49) return .cheesefare;
    if (delta >= -48 and delta <= -9) return .lent;
    if (delta >= -8 and delta <= -1) return .holy_week;
    if (delta >= 57 and (j.month < 6 or (j.month == 6 and j.day <= 28))) return .apostles;
    if (j.month == 8 and j.day <= 14) return .dormition;
    if ((j.month == 11 and j.day >= 15) or (j.month == 12 and j.day <= 24)) return .nativity;
    return .none;
}

fn seasonOf(per: Period, delta: i64) []const u8 {
    return switch (per) {
        .bright => "Bright Week",
        .trinity => "Trinity Week",
        .svyatki => "Svyatki (Christmastide)",
        .publican, .cheesefare => "Pre-Lent (Triodion)",
        .lent => "Great Lent",
        .holy_week => "Holy Week",
        .apostles => "Apostles' Fast",
        .dormition => "Dormition Fast",
        .nativity => "Nativity Fast",
        .none => if (delta > 0 and delta < 49) "Paschal season" else if (delta >= -70 and delta < -48) "Pre-Lent (Triodion)" else "After Pentecost",
    };
}

const Fast = struct { emoji: []const u8 = "", text: []const u8 = "" };

const strict = Fast{ .emoji = "🥣", .text = "Strict fast: no meat, dairy, fish, oil or wine" };
const strict_hot = Fast{ .emoji = "🥣", .text = "Fast: hot food without oil; no meat, dairy, fish or wine" };
const wine_oil = Fast{ .emoji = "🍇", .text = "Fast day: wine and oil allowed" };
const fish = Fast{ .emoji = "🐟🍇", .text = "Fish, wine and oil allowed" };

/// `feast_p` is the precedence of the day's fixed feast (255 for none): a
/// Great Feast or major feast (1, 2) lets fish be eaten on a fast day, a
/// feast (3) allows wine and oil.
fn fastOf(per: Period, wd: u8, delta: i64, j: calsys.Ymd, feast_p: u8) Fast {
    const sat_sun = wd == 0 or wd == 6;
    const mwf = wd == 1 or wd == 3 or wd == 5;
    const fish_feast = feast_p <= 2;

    // Days with their own rule.
    if (j.month == 1 and j.day == 5) return .{ .emoji = "🥣", .text = "Eve of Theophany: strict fast" };
    if ((j.month == 8 and j.day == 29) or (j.month == 9 and j.day == 14)) return .{ .emoji = "🍇", .text = "Strict fast day: no meat, dairy or fish; wine and oil allowed" };

    switch (per) {
        .bright, .trinity, .svyatki, .publican => return .{},
        .cheesefare => return .{ .emoji = "🧀🐟", .text = "No meat; dairy, eggs and fish allowed" },
        .holy_week => return switch (delta) {
            -8 => .{ .emoji = "🍇", .text = "Lazarus Saturday: wine, oil and fish roe allowed" },
            -6, -5, -4 => .{ .emoji = "🥣", .text = "Strict fast" },
            -3 => .{ .emoji = "🍇", .text = "Holy Thursday: wine and oil, one meal" },
            -2 => .{ .emoji = "⛔", .text = "Great and Holy Friday: total fast until the shroud" },
            -1 => .{ .emoji = "🍷", .text = "Holy Saturday: wine, no oil" },
            else => .{},
        },
        .lent => {
            if (delta == -7) return fish;
            if (fish_feast and feast_p == 1) return fish; // the Annunciation
            if (feast_p <= 3) return wine_oil;
            if (delta == -8) return .{ .emoji = "🍇", .text = "Lazarus Saturday: wine, oil and fish roe allowed" };
            if (sat_sun) return .{ .emoji = "🍇", .text = "Great Lent: wine and oil allowed" };
            if (mwf) return .{ .emoji = "🥣", .text = "Great Lent: dry eating, no oil or wine" };
            return strict_hot;
        },
        .nativity => {
            if (j.month == 12 and j.day >= 20) return strict;
            if (fish_feast) return fish;
            if (feast_p <= 3) return wine_oil;
            if (sat_sun) return fish;
            if (mwf) return strict_hot;
            return wine_oil;
        },
        .apostles => {
            if (fish_feast) return fish;
            if (sat_sun) return fish;
            if (mwf) return strict_hot;
            return wine_oil;
        },
        .dormition => {
            if (fish_feast) return fish;
            if (feast_p <= 3) return wine_oil;
            if (sat_sun) return wine_oil;
            return if (mwf) strict else strict_hot;
        },
        .none => {
            if ((wd == 3 or wd == 5) and delta >= -70) {
                if (fish_feast) return fish;
                return wine_oil;
            }
            if ((wd == 3 or wd == 5) and delta < -70) {
                if (fish_feast) return fish;
                return wine_oil;
            }
            return .{};
        },
    }
}

const Temporal = struct { name: []const u8, p: u8, color: Color };

fn temporalOf(d: Date, j: calsys.Ymd, pascha: i64, delta: i64, out: *Day) Temporal {
    const n = d.days();
    const wd = d.weekday();
    const dn = calsys.weekday_names[wd];

    switch (delta) {
        0 => return .{ .name = "Holy Pascha: the Resurrection of our Lord", .p = 0, .color = .gold },
        7 => return .{ .name = "Thomas Sunday (Antipascha)", .p = 2, .color = .gold },
        14 => return .{ .name = "Sunday of the Myrrh-bearing Women", .p = 2, .color = .gold },
        21 => return .{ .name = "Sunday of the Paralytic", .p = 2, .color = .gold },
        24 => return .{ .name = "Mid-Pentecost", .p = 4, .color = .gold },
        28 => return .{ .name = "Sunday of the Samaritan Woman", .p = 2, .color = .gold },
        35 => return .{ .name = "Sunday of the Blind Man", .p = 2, .color = .gold },
        39 => return .{ .name = "The Ascension of our Lord", .p = 1, .color = .gold },
        42 => return .{ .name = "Sunday of the Holy Fathers of the First Council", .p = 2, .color = .gold },
        49 => return .{ .name = "Holy Pentecost: the Descent of the Holy Spirit", .p = 0, .color = .green },
        50 => return .{ .name = "Monday of the Holy Spirit", .p = 2, .color = .green },
        56 => return .{ .name = "Sunday of All Saints", .p = 2, .color = .gold },
        63 => return .{ .name = "Sunday of All Saints of the Russian Land", .p = 4, .color = .gold },
        -70 => return .{ .name = "Sunday of the Publican and the Pharisee", .p = 2, .color = .violet },
        -63 => return .{ .name = "Sunday of the Prodigal Son", .p = 2, .color = .violet },
        -56 => return .{ .name = "Meatfare Sunday: the Last Judgment", .p = 2, .color = .violet },
        -49 => return .{ .name = "Cheesefare Sunday: Forgiveness Sunday", .p = 2, .color = .violet },
        -48 => return .{ .name = "Clean Monday: the beginning of Great Lent", .p = 2, .color = .violet },
        -42 => return .{ .name = "1st Sunday of Great Lent: the Triumph of Orthodoxy", .p = 2, .color = .violet },
        -35 => return .{ .name = "2nd Sunday of Great Lent: Saint Gregory Palamas", .p = 2, .color = .violet },
        -28 => return .{ .name = "3rd Sunday of Great Lent: Veneration of the Cross", .p = 2, .color = .violet },
        -21 => return .{ .name = "4th Sunday of Great Lent: Saint John of the Ladder", .p = 2, .color = .violet },
        -14 => return .{ .name = "5th Sunday of Great Lent: Saint Mary of Egypt", .p = 2, .color = .violet },
        -8 => return .{ .name = "Lazarus Saturday", .p = 1, .color = .violet },
        -7 => return .{ .name = "Palm Sunday: the Entry of the Lord into Jerusalem", .p = 1, .color = .green },
        -3 => return .{ .name = "Great and Holy Thursday", .p = 0, .color = .black },
        -2 => return .{ .name = "Great and Holy Friday", .p = 0, .color = .black },
        -1 => return .{ .name = "Great and Holy Saturday", .p = 0, .color = .black },
        else => {},
    }
    if (delta >= -6 and delta <= -4) return .{ .name = out.print("Great and Holy {s}", .{dn}), .p = 0, .color = .black };
    if (delta >= 1 and delta <= 6) return .{ .name = out.print("{s} of Bright Week", .{dn}), .p = 1, .color = .gold };
    if (delta > 7 and delta < 49) {
        const k = @divFloor(delta, 7) + 1;
        if (delta > 39) return .{ .name = out.print("{s} after the Ascension", .{dn}), .p = 9, .color = .white };
        return .{ .name = out.print("{s} of the {s} week of Pascha", .{ dn, out.ord(k) }), .p = 9, .color = .white };
    }
    if (delta >= -69 and delta < -63) return .{ .name = out.print("{s} of the week of the Publican and Pharisee", .{dn}), .p = 9, .color = .violet };
    if (delta >= -62 and delta < -56) return .{ .name = out.print("{s} of the week of the Prodigal Son", .{dn}), .p = 9, .color = .violet };
    if (delta >= -55 and delta < -49) return .{ .name = out.print("{s} of Cheesefare Week", .{dn}), .p = 9, .color = .violet };
    if (delta > -48 and delta < -8) {
        const w = @divFloor(delta + 48, 7) + 1;
        return .{ .name = out.print("{s} of the {s} week of Great Lent", .{ dn, out.ord(w) }), .p = 5, .color = .violet };
    }

    // The Sundays of the Nativity cycle, by Julian date.
    if (wd == 0) {
        if (j.month == 12 and j.day >= 11 and j.day <= 17) return .{ .name = "Sunday of the Holy Forefathers", .p = 4, .color = .gold };
        if (j.month == 12 and j.day >= 18 and j.day <= 24) return .{ .name = "Sunday of the Holy Fathers", .p = 4, .color = .gold };
        if ((j.month == 12 and j.day >= 26) or (j.month == 1 and j.day == 1)) return .{ .name = "Sunday after the Nativity", .p = 4, .color = .gold };
        if (j.month == 1 and j.day >= 2 and j.day <= 5) return .{ .name = "Sunday before Theophany", .p = 4, .color = .gold };
        if (j.month == 1 and j.day >= 7 and j.day <= 13) return .{ .name = "Sunday after Theophany", .p = 4, .color = .gold };
    }

    // Ordinary time: counted from Pentecost, this year's or last year's.
    const pent = if (delta >= 49) pascha + 49 else paschaDays(j.year - 1) + 49;
    const sundays = @divFloor(n - pent, 7);
    if (wd == 0) return .{ .name = out.print("{s} Sunday after Pentecost", .{out.ord(sundays)}), .p = 4, .color = .gold };
    return .{ .name = out.print("{s} after the {s} Sunday after Pentecost", .{ dn, out.ord(sundays) }), .p = 9, .color = .white };
}

fn rankLabel(p: u8) []const u8 {
    return switch (p) {
        0 => "Pascha, Holy Week or Pentecost",
        1 => "Great Feast",
        2 => "Major feast",
        3 => "Feast",
        4 => "Sunday",
        5 => "Day of Great Lent",
        6 => "Saint",
        else => "Weekday",
    };
}

pub fn compute(table: *const liturgy.Table, d: Date, out: *Day) void {
    const j = calsys.fromCivil(.julian, d);
    const n = d.days();
    // Pascha of the Julian year: January to the end of the year share it.
    const pascha = paschaDays(j.year);
    const delta = n - pascha;
    const per = periodOf(j, delta);

    const t = temporalOf(d, j, pascha, delta, out);
    var best_name = t.name;
    var best_p = t.p;
    var best_color = t.color;
    var fixed_p: u8 = 255;
    var winner_is_temporal = true;

    // Fixed feasts and saints for this Julian date.
    var seen: usize = 0;
    var found: [8]liturgy.Entry = undefined;
    for (table.entries) |en| {
        if (en.month != j.month or en.day != j.day) continue;
        if (seen < found.len) {
            found[seen] = en;
            seen += 1;
        }
        if (en.p < fixed_p) fixed_p = en.p;
        if (en.p < best_p) {
            best_p = en.p;
            best_name = en.name;
            best_color = en.color;
            winner_is_temporal = false;
        }
    }
    out.name = best_name;
    out.color = best_color;
    out.rank = rankLabel(best_p);
    out.plain = winner_is_temporal and (best_p == 9 or best_p == 5);
    out.season = seasonOf(per, delta);
    var shown: usize = 0;
    if (!winner_is_temporal) {
        out.addAlso("Day", t.name);
        shown += 1;
    }
    for (found[0..seen]) |en| {
        if (std.mem.eql(u8, en.name, best_name)) continue;
        out.addAlso("Also", en.name);
        shown += 1;
    }

    const feast_p: u8 = if (fixed_p <= 3) fixed_p else if (delta == -7) 1 else 255;
    const fast = fastOf(per, d.weekday(), delta, j, if (std.mem.indexOf(u8, best_name, "Annunciation") != null and per == .lent) 1 else feast_p);
    out.fast_emoji = fast.emoji;
    out.fast_text = fast.text;
}

// ---- tests -------------------------------------------------------------------------------------

test "Orthodox Pascha" {
    try std.testing.expect(Date.fromDays(paschaDays(2026)).eql(.{ .year = 2026, .month = 4, .day = 12 }));
    try std.testing.expect(Date.fromDays(paschaDays(2025)).eql(.{ .year = 2025, .month = 4, .day = 20 }));
    try std.testing.expect(Date.fromDays(paschaDays(2024)).eql(.{ .year = 2024, .month = 5, .day = 5 }));
    try std.testing.expect(Date.fromDays(paschaDays(2027)).eql(.{ .year = 2027, .month = 5, .day = 2 }));
    try std.testing.expect(Date.fromDays(paschaDays(2023)).eql(.{ .year = 2023, .month = 4, .day = 16 }));
}

fn dayOf(table: *const liturgy.Table, y: i32, m: u8, dd: u8, out: *Day) void {
    liturgy.compute(table, .{ .year = y, .month = m, .day = dd }, out);
}

test "Russian Orthodox feasts and fasts" {
    var t = try liturgy.Table.parse(std.testing.allocator, .orthodox_ru, liturgy.Kind.orthodox_ru.builtinText());
    defer t.deinit();
    var d: Day = undefined;
    // Christmas Old Calendar is January 7; the Nativity Fast has ended.
    dayOf(&t, 2027, 1, 7, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "The Nativity of our Lord"));
    try std.testing.expectEqualStrings("", d.fast_emoji);
    // Theophany eve (Jan 18 civil) is a strict fast.
    dayOf(&t, 2027, 1, 18, &d);
    try std.testing.expectEqualStrings("🥣", d.fast_emoji);
    // Pascha 2026 and Clean Monday.
    dayOf(&t, 2026, 4, 12, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "Holy Pascha"));
    dayOf(&t, 2026, 2, 23, &d);
    try std.testing.expect(std.mem.startsWith(u8, d.name, "Clean Monday"));
    // Good Friday: total fast; Bright Week: no fast.
    dayOf(&t, 2026, 4, 10, &d);
    try std.testing.expectEqualStrings("⛔", d.fast_emoji);
    dayOf(&t, 2026, 4, 15, &d);
    try std.testing.expectEqualStrings("", d.fast_emoji);
    // The Annunciation (Apr 7 civil in 2025) in Great Lent allows fish.
    dayOf(&t, 2025, 4, 7, &d);
    try std.testing.expect(std.mem.indexOf(u8, d.name, "Annunciation") != null);
    try std.testing.expectEqualStrings("🐟🍇", d.fast_emoji);
    // An ordinary Wednesday: wine and oil.
    dayOf(&t, 2026, 9, 2, &d);
    try std.testing.expectEqualStrings("🍇", d.fast_emoji);
}
