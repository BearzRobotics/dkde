//! Moon phases, computed from Jean Meeus, "Astronomical Algorithms", chapter 49
//! (new, first quarter, full and last quarter moon, good to a minute or two for
//! the present era).
//!
//! A phase is one instant for the whole Earth. Where you stand only decides which
//! calendar day that instant lands on, so a `Site` carries the observer's
//! coordinates and the clock they keep: a phase belongs to the local day of the
//! site. The default site is Lake Odessa, Michigan.

const std = @import("std");
const civil = @import("common").civil;

pub const Date = civil.Date;

pub const Phase = enum {
    new,
    first_quarter,
    full,
    last_quarter,

    pub fn symbol(self: Phase) []const u8 {
        return switch (self) {
            .new => "\u{1F311}",
            .first_quarter => "\u{1F313}",
            .full => "\u{1F315}",
            .last_quarter => "\u{1F317}",
        };
    }

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .new => "New Moon",
            .first_quarter => "First Quarter",
            .full => "Full Moon",
            .last_quarter => "Last Quarter",
        };
    }
};

const rad = std.math.pi / 180.0;

fn s(deg: f64) f64 {
    return @sin(deg * rad);
}

fn c(deg: f64) f64 {
    return @cos(deg * rad);
}

/// Julian Ephemeris Day of lunation `k` (new moon when k is whole, +0.25 first
/// quarter, +0.5 full, +0.75 last quarter). k = 0 is the new moon of 2000-01-06.
pub fn phaseJde(k: f64) f64 {
    const t = k / 1236.85;
    const t2 = t * t;
    const t3 = t2 * t;
    const t4 = t3 * t;
    var jde = 2451550.09766 + 29.530588861 * k + 0.00015437 * t2 - 0.00000015 * t3 + 0.00000000073 * t4;
    const e = 1 - 0.002516 * t - 0.0000074 * t2;
    const m = 2.5534 + 29.10535670 * k - 0.0000014 * t2 - 0.00000011 * t3;
    const mp = 201.5643 + 385.81693528 * k + 0.0107582 * t2 + 0.00001238 * t3 - 0.000000058 * t4;
    const f = 160.7108 + 390.67050284 * k - 0.0016118 * t2 - 0.00000227 * t3 + 0.000000011 * t4;
    const om = 124.7746 - 1.56375588 * k + 0.0020672 * t2 + 0.00000215 * t3;
    const e2 = e * e;

    const quarter = @mod(k, 1.0);
    if (quarter < 0.01 or quarter > 0.99 or @abs(quarter - 0.5) < 0.01) {
        const full = @abs(quarter - 0.5) < 0.01;
        jde += if (full)
            -0.40614 * s(mp) + 0.17302 * e * s(m) + 0.01614 * s(2 * mp) + 0.01043 * s(2 * f) + 0.00734 * e * s(mp - m) - 0.00515 * e * s(mp + m) + 0.00209 * e2 * s(2 * m)
        else
            -0.40720 * s(mp) + 0.17241 * e * s(m) + 0.01608 * s(2 * mp) + 0.01039 * s(2 * f) + 0.00739 * e * s(mp - m) - 0.00514 * e * s(mp + m) + 0.00208 * e2 * s(2 * m);
        // The terms shared by new and full moon (the tables differ only above).
        jde += -0.00111 * s(mp - 2 * f) - 0.00057 * s(mp + 2 * f) + 0.00056 * e * s(2 * mp + m) - 0.00042 * s(3 * mp) +
            0.00042 * e * s(m + 2 * f) + 0.00038 * e * s(m - 2 * f) - 0.00024 * e * s(2 * mp - m) - 0.00017 * s(om) -
            0.00007 * s(mp + 2 * m) + 0.00004 * s(2 * mp - 2 * f) + 0.00004 * s(3 * m) + 0.00003 * s(mp + m - 2 * f) +
            0.00003 * s(2 * mp + 2 * f) - 0.00003 * s(mp + m + 2 * f) + 0.00003 * s(mp - m + 2 * f) -
            0.00002 * s(mp - m - 2 * f) - 0.00002 * s(3 * mp + m) + 0.00002 * s(4 * mp);
    } else {
        jde += -0.62801 * s(mp) + 0.17172 * e * s(m) - 0.01183 * e * s(mp + m) + 0.00862 * s(2 * mp) + 0.00804 * s(2 * f) +
            0.00454 * e * s(mp - m) + 0.00204 * e2 * s(2 * m) - 0.00180 * s(mp - 2 * f) - 0.00070 * s(mp + 2 * f) -
            0.00040 * s(3 * mp) - 0.00034 * e * s(2 * mp - m) + 0.00032 * e * s(m + 2 * f) + 0.00032 * e * s(m - 2 * f) -
            0.00028 * e2 * s(mp + 2 * m) + 0.00027 * e * s(2 * mp + m) - 0.00017 * s(om) - 0.00005 * s(mp - m - 2 * f) +
            0.00004 * s(2 * mp + 2 * f) - 0.00004 * s(mp + m + 2 * f) + 0.00004 * s(mp - 2 * m) + 0.00003 * s(mp + m - 2 * f) +
            0.00003 * s(3 * m) + 0.00002 * s(2 * mp - 2 * f) + 0.00002 * s(mp - m + 2 * f) - 0.00002 * s(3 * mp + m);
        const w = 0.00306 - 0.00038 * e * c(m) + 0.00026 * c(mp) - 0.00002 * c(mp - m) + 0.00002 * c(mp + m) + 0.00002 * c(2 * f);
        jde += if (@abs(quarter - 0.25) < 0.01) w else -w;
    }
    return jde;
}

/// Days since 1970-01-01 (UTC, fractional) of a phase, ΔT taken as 69 s.
fn utcDays(k: f64) f64 {
    return phaseJde(k) - 69.0 / 86400.0 - 2440587.5;
}

/// Where the observer is and which clock they keep.
pub const Site = struct {
    /// Degrees north and east.
    latitude: f64,
    longitude: f64,
    /// Seconds east of UTC at the given Unix time (so daylight saving is the
    /// caller's to know). Null: local mean solar time, rounded to a whole hour.
    offset_fn: ?*const fn (utc_seconds: i64) i32 = null,

    pub fn offsetAt(self: Site, utc_seconds: i64) i64 {
        if (self.offset_fn) |f| return f(utc_seconds);
        return @as(i64, @intFromFloat(@round(self.longitude / 15.0))) * 3600;
    }

    /// The local calendar date of a Unix time.
    pub fn localDate(self: Site, utc_seconds: i64) Date {
        return Date.fromDays(@divFloor(utc_seconds + self.offsetAt(utc_seconds), 86400));
    }
};

/// Lake Odessa, Michigan (42.7889 N, 85.1417 W), on Eastern time.
pub const lake_odessa: Site = .{ .latitude = 42.7889, .longitude = -85.1417 };

/// UTC days since 1970 (fractional) of the first new moon at or after `t`, and of
/// the last one before it, for the lunisolar calendars.
pub fn newMoonAtOrAfter(t: f64) f64 {
    var k: f64 = @floor((1970.0 + t / 365.2425 - 2000.0) * 12.3685) - 2.0;
    while (utcDays(k) < t) k += 1.0;
    return utcDays(k);
}

pub fn newMoonBefore(t: f64) f64 {
    var k: f64 = @ceil((1970.0 + t / 365.2425 - 2000.0) * 12.3685) + 2.0;
    while (utcDays(k) >= t) k -= 1.0;
    return utcDays(k);
}

fn utcSeconds(k: f64) i64 {
    return @intFromFloat(@floor(utcDays(k) * 86400.0));
}

/// The lunation index (in quarters; a multiple of 4 is a new moon) of the last
/// phase at or before the Unix time `t`.
fn quarterIndexAt(t: i64) i64 {
    const years = 1970.0 + @as(f64, @floatFromInt(t)) / (86400.0 * 365.2425);
    var q: i64 = @intFromFloat(@floor((years - 2000.0) * 12.3685 * 4.0));
    while (utcSeconds(@as(f64, @floatFromInt(q)) / 4.0) > t) q -= 1;
    while (utcSeconds(@as(f64, @floatFromInt(q + 1)) / 4.0) <= t) q += 1;
    return q;
}

/// The phase that happens on `date` (a local date at the site), if any.
pub fn phaseOn(site: Site, date: Date) ?Phase {
    // Look around the day for the phases of the previous, this and next few days.
    const noon = date.days() * 86400 + 43200 - site.offsetAt(date.days() * 86400 + 43200);
    var q = quarterIndexAt(noon - 3 * 86400);
    const stop = quarterIndexAt(noon + 3 * 86400);
    while (q <= stop + 1) : (q += 1) {
        const t = utcSeconds(@as(f64, @floatFromInt(q)) / 4.0);
        if (site.localDate(t).eql(date)) return @enumFromInt(@as(u2, @intCast(@mod(q, 4))));
    }
    return null;
}

/// Which quarter of the lunation the middle of the local day falls in: 0 from
/// new moon to first quarter, 1 to full moon, 2 to last quarter, 3 back to new.
pub fn quarterOf(site: Site, date: Date) u2 {
    const noon = date.days() * 86400 + 43200 - site.offsetAt(date.days() * 86400 + 43200);
    return @intCast(@mod(quarterIndexAt(noon), 4));
}

fn easternOffset(utc_seconds: i64) i32 {
    // Test clock: EST all year.
    _ = utc_seconds;
    return -5 * 3600;
}

const test_site: Site = .{ .latitude = 42.7889, .longitude = -85.1417, .offset_fn = &easternOffset };

test "known moon phases" {
    // New moon 2000-01-06 18:14 UTC; full moon 2000-01-21 04:40 UTC, which is still Jan 20 in Michigan.
    try std.testing.expectEqual(Phase.new, phaseOn(test_site, .{ .year = 2000, .month = 1, .day = 6 }).?);
    try std.testing.expectEqual(Phase.full, phaseOn(test_site, .{ .year = 2000, .month = 1, .day = 20 }).?);
    // 2026: new moon Nov 9 (13:02 UTC), full moon Nov 24 (14:53 UTC).
    try std.testing.expectEqual(Phase.new, phaseOn(test_site, .{ .year = 2026, .month = 11, .day = 9 }).?);
    try std.testing.expectEqual(Phase.full, phaseOn(test_site, .{ .year = 2026, .month = 11, .day = 24 }).?);
    try std.testing.expect(phaseOn(test_site, .{ .year = 2026, .month = 11, .day = 12 }) == null);
}

test "a phase belongs to the local day" {
    // Every phase of 2026 is found on exactly the local day of its instant, and
    // some of them land on a different day than in UTC.
    var moved: usize = 0;
    var q: i64 = 322 * 4;
    while (q < 334 * 4) : (q += 1) {
        const t = utcSeconds(@as(f64, @floatFromInt(q)) / 4.0);
        const utc_day = Date.fromDays(@divFloor(t, 86400));
        const local = test_site.localDate(t);
        if (!utc_day.eql(local)) moved += 1;
        try std.testing.expect(phaseOn(test_site, local) != null);
    }
    try std.testing.expect(moved > 0);
}

test "about four phases a month" {
    var count: usize = 0;
    var n = civil.daysFromCivil(2026, 1, 1);
    const end = civil.daysFromCivil(2027, 1, 1);
    while (n < end) : (n += 1) {
        if (phaseOn(test_site, Date.fromDays(n)) != null) count += 1;
    }
    try std.testing.expect(count >= 49 and count <= 50);
}

test "quarter of the lunation" {
    // The day after the 2026-11-09 new moon is in quarter 0; the day after the full moon, quarter 2.
    try std.testing.expectEqual(@as(u2, 0), quarterOf(test_site, .{ .year = 2026, .month = 11, .day = 10 }));
    try std.testing.expectEqual(@as(u2, 2), quarterOf(test_site, .{ .year = 2026, .month = 11, .day = 25 }));
}
