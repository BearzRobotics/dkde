//! The Rosquin day glyph. Every day is a stack of components from
//! RosquinGlyphs.ttf, all on the same 900x900 canvas, printed on top of one
//! another. This file decides which components a day shows; calendar/main.zig
//! stacks them.
//!
//! Corners and edges of the stamp, and what they count (a number is written in
//! binary, one component per set bit):
//!
//!   top-left, top-right        year in the 4-year leap cycle (year mod 4)
//!   bottom-right, bottom-left  quarter of the year, 0 to 3 (7 weeks each)
//!   bottom edge                week of the quarter, 1 to 7
//!   top edge (A)               month, 1 to 7
//!   far corners                week of the month, 0 to 3 (week 1 is 0)
//!   left, right edge           quarter of the moon, 0 to 3
//!   centre                     day of the week: 1 to 12 in four dots, the
//!                              Ankh for day 13, and one symbol each for
//!                              Year-End Day and Leap Day
//!   top mark                   every Saturday (the Sabbath)
//!   bottom mark                every fifth day of the year
//!   carry mark                 on the Ankh, Year-End Day and Leap Day

const std = @import("std");
const civil = @import("common").civil;
const rosquin = @import("common").rosquin;
const lunar = @import("lunar.zig");
const g = @import("rosglyph.zig");

pub const Stack = struct {
    chars: [24]u21 = undefined,
    len: usize = 0,

    fn add(self: *Stack, c: u21) void {
        self.chars[self.len] = c;
        self.len += 1;
    }

    fn bits(self: *Stack, value: u32, comptime parts: []const u21) void {
        inline for (parts, 0..) |c, i| {
            if (value & (1 << i) != 0) self.add(c);
        }
    }

    pub fn slice(self: *const Stack) []const u21 {
        return self.chars[0..self.len];
    }
};


/// The components that make the stamp of `date`.
pub fn stamp(site: lunar.Site, date: civil.Date) Stack {
    var s: Stack = .{};
    const v = rosquin.fromCivil(.months, date); // the glyph always counts months of 4 weeks

    s.bits(@intCast(@mod(v.year, 4)), &.{ g.yrz_4x_t_l_1_1, g.yrz_4x_t_r_2 });
    s.bits(lunar.quarterOf(site, date), &.{ g.qrt_moon_l_1_1, g.qrt_moon_r_2_2 });
    if (date.weekday() == 6) s.add(g.every_sabbath_day_t);
    if (rosquin.dayOfYear(date) % 5 == 0) s.add(g.every_fifth_day_1_365_b);

    if (rosquin.isSpecial(v)) {
        if (v.day == rosquin.year_end_day) {
            s.add(g.yrend_day_yearend_day_15);
        } else {
            s.bits(15, &.{ g.lpyr_day_every_4_yrz_1_0, g.lpyr_day_every_4_yrz_2_0, g.lpyr_day_every_4_yrz_3_0, g.lpyr_day_every_4_yrz_4_0 });
        }
        s.add(g.carry_r_carry_r_new);
        return s;
    }

    const k: u32 = (@as(u32, v.month) - 1) * 52 + v.day - 1;
    s.bits(k / 91, &.{ g.qtrz_7x_wkz_4x_b_r_1, g.qtrz_7x_wkz_4x_b_l_2 });
    s.bits((k % 91) / 13 + 1, &.{ g.wkz_of_qtr_7x_b_1_1, g.wkz_of_qtr_7x_b_2_2, g.wkz_of_qtr_7x_b_3_4 });
    s.bits(v.month, &.{ g.mo_z_4x_wkz_7x_a_1_1, g.mo_z_4x_wkz_7x_a_2_2, g.mo_z_4x_wkz_7x_a_3_4 });
    s.bits((v.day - 1) / 13, &.{ g.wkz_of_mo_4x_t_l_1, g.wkz_of_mo_4x_b_r_2 });

    const wd: u32 = (v.day - 1) % 13 + 1;
    if (wd == 13) {
        s.add(g.day_13_wkz_ankh_black_unmark_d_14932);
        s.add(g.carry_r_carry_r_new);
    } else {
        s.bits(wd, &.{ g.g_12x_dayz_wk_1_1, g.g_12x_dayz_wk_2_2, g.g_12x_dayz_wk_3_4, g.g_12x_dayz_wk_4_8 });
    }
    return s;
}

/// The stamp as text, to paste into another program: its characters, then one EM
/// SPACE, which gives the run the width of the glyph (the font's glyphs have no
/// width of their own, so they land on the same spot). It shows as the stamp only
/// where the Rosquin Glyphs font is installed and used.
pub fn glyphString(buf: []u8, site: lunar.Site, date: civil.Date) []const u8 {
    const s = stamp(site, date);
    var n: usize = 0;
    for (s.slice()) |c| n += std.unicode.utf8Encode(c, buf[n..]) catch 0;
    n += std.unicode.utf8Encode(0x2003, buf[n..]) catch 0;
    return buf[0..n];
}

test "stamps" {
    const site: lunar.Site = .{ .latitude = 42.79, .longitude = -85.14 };
    // Day 13 of a week is the Ankh and carries; day 12 is dots 3 and 4.
    var d = rosquin.toCivil(.months, .{ .year = 45, .month = 1, .day = 13 });
    var st = stamp(site, d);
    try std.testing.expect(std.mem.indexOfScalar(u21, st.slice(), g.day_13_wkz_ankh_black_unmark_d_14932) != null);
    try std.testing.expect(std.mem.indexOfScalar(u21, st.slice(), g.carry_r_carry_r_new) != null);
    d = rosquin.toCivil(.months, .{ .year = 45, .month = 1, .day = 12 });
    st = stamp(site, d);
    try std.testing.expect(std.mem.indexOfScalar(u21, st.slice(), g.g_12x_dayz_wk_3_4) != null);
    try std.testing.expect(std.mem.indexOfScalar(u21, st.slice(), g.g_12x_dayz_wk_4_8) != null);
    // Year-End Day.
    st = stamp(site, .{ .year = 2026, .month = 12, .day = 31 });
    try std.testing.expect(std.mem.indexOfScalar(u21, st.slice(), g.yrend_day_yearend_day_15) != null);
    // No stamp needs more than the 24 slots.
    var n = civil.daysFromCivil(2026, 1, 1);
    while (n < civil.daysFromCivil(2036, 1, 1)) : (n += 1) _ = stamp(site, civil.Date.fromDays(n));
}
