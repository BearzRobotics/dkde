//! Recurrence rules (RFC 5545 section 3.3.10) for subscribed calendars.
//!
//! An event in dkde repeats forever (daily, weekly, monthly, yearly). A feed
//! from another service often says more: "every other week on Tuesday and
//! Thursday, ten times", "until March". This module reads the rule and lists
//! the days it falls on, so the feed loader can store each one as its own
//! event instead of repeating forever and being wrong.
//!
//! Supported: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL, COUNT, UNTIL and,
//! for WEEKLY, BYDAY (plain weekdays such as MO,WE,FR). Everything else
//! (BYMONTHDAY, BYSETPOS, BYDAY with a number such as 2TU, BYMONTH, ...) makes
//! `parse` return null, and the caller keeps the plain FREQ repeat, which is
//! only an approximation. Week days start on Monday (the RFC's default WKST).

const std = @import("std");
const civil = @import("civil.zig");

const Date = civil.Date;

pub const Freq = enum { daily, weekly, monthly, yearly };

pub const Rule = struct {
    freq: Freq,
    interval: u32 = 1,
    /// Total number of occurrences, counting from the first.
    count: ?u32 = null,
    /// Last day an occurrence may fall on.
    until: ?Date = null,
    /// Weekly only: bit n is set for weekday n (0 = Sunday ... 6 = Saturday). 0 means
    /// "the weekday of the first occurrence".
    byday: u8 = 0,

    /// True when the rule is only FREQ (INTERVAL 1) with no end: dkde's own
    /// forever-repeat says the same thing, so no expansion is needed.
    pub fn isPlain(self: Rule) bool {
        return self.interval == 1 and self.count == null and self.until == null and self.byday == 0;
    }
};

/// The most occurrences one rule may produce, so a daily rule with no end
/// cannot fill the memory.
pub const max_occurrences = 4000;

fn parseUntil(text: []const u8) ?Date {
    if (text.len < 8) return null;
    const y = std.fmt.parseInt(i32, text[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, text[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, text[6..8], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > civil.daysInMonth(y, m)) return null;
    return .{ .year = y, .month = m, .day = d };
}

fn weekdayBit(code: []const u8) ?u8 {
    const names = [_][]const u8{ "SU", "MO", "TU", "WE", "TH", "FR", "SA" };
    for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(code, n)) return @as(u8, 1) << @intCast(i);
    return null;
}

/// Reads the value of an RRULE line ("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH").
/// Null when the rule has no FREQ or uses a part this module does not handle.
pub fn parse(value: []const u8) ?Rule {
    var rule: Rule = .{ .freq = .daily };
    var have_freq = false;
    var parts = std.mem.splitScalar(u8, value, ';');
    while (parts.next()) |p| {
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        const key = p[0..eq];
        const val = p[eq + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "FREQ")) {
            if (std.ascii.eqlIgnoreCase(val, "DAILY")) rule.freq = .daily else if (std.ascii.eqlIgnoreCase(val, "WEEKLY")) rule.freq = .weekly else if (std.ascii.eqlIgnoreCase(val, "MONTHLY")) rule.freq = .monthly else if (std.ascii.eqlIgnoreCase(val, "YEARLY")) rule.freq = .yearly else return null;
            have_freq = true;
        } else if (std.ascii.eqlIgnoreCase(key, "INTERVAL")) {
            rule.interval = std.fmt.parseInt(u32, val, 10) catch return null;
            if (rule.interval == 0) return null;
        } else if (std.ascii.eqlIgnoreCase(key, "COUNT")) {
            rule.count = std.fmt.parseInt(u32, val, 10) catch return null;
        } else if (std.ascii.eqlIgnoreCase(key, "UNTIL")) {
            rule.until = parseUntil(val) orelse return null;
        } else if (std.ascii.eqlIgnoreCase(key, "BYDAY")) {
            var days = std.mem.splitScalar(u8, val, ',');
            while (days.next()) |d| rule.byday |= weekdayBit(d) orelse return null; // "2TU" and the like
        } else if (std.ascii.eqlIgnoreCase(key, "WKST")) {
            // Only matters for an interval above 1 with BYDAY; Monday is assumed.
        } else return null;
    }
    if (!have_freq) return null;
    if (rule.byday != 0 and rule.freq != .weekly) return null;
    return rule;
}

/// Days since the epoch of the Monday of the week that holds `n`.
fn mondayOf(n: i64) i64 {
    const wd: i64 = civil.weekdayOfDays(n); // 0 = Sunday
    return n - @mod(wd + 6, 7);
}

/// Appends to `out` the days (days since 1970-01-01) on which the rule falls,
/// starting at `first`, that lie in [from, to]. COUNT counts from `first`, so
/// occurrences before `from` are counted but not listed.
pub fn occurrences(
    a: std.mem.Allocator,
    rule: Rule,
    first: Date,
    from: i64,
    to: i64,
    out: *std.ArrayList(i64),
) !void {
    const start = first.days();
    var seen: u32 = 0; // occurrences so far, listed or not
    var listed: usize = 0;
    const last: i64 = if (rule.until) |u| @min(u.days(), to) else to;

    // One candidate day at a time; `visit` returns false when the rule is done.
    var k: i64 = 0;
    var guard: u32 = 0;
    while (guard < 100_000) : (guard += 1) {
        // The candidates of period k, in day order, as up to seven days.
        var cand: [7]i64 = undefined;
        var n: usize = 0;
        switch (rule.freq) {
            .daily => {
                cand[0] = start + k * rule.interval;
                n = 1;
            },
            .weekly => {
                const week = mondayOf(start) + 7 * k * rule.interval;
                const mask: u8 = if (rule.byday != 0) rule.byday else @as(u8, 1) << @intCast(first.weekday());
                var off: i64 = 0;
                while (off < 7) : (off += 1) {
                    const day = week + off;
                    if (mask & (@as(u8, 1) << @intCast(civil.weekdayOfDays(day))) != 0 and day >= start) {
                        cand[n] = day;
                        n += 1;
                    }
                }
            },
            .monthly => {
                const months = @as(i64, first.month - 1) + k * rule.interval;
                const year: i32 = first.year + @as(i32, @intCast(@divFloor(months, 12)));
                const month: u8 = @intCast(@mod(months, 12) + 1);
                // A month too short for the day is skipped, as the RFC says.
                if (first.day <= civil.daysInMonth(year, month)) {
                    cand[0] = civil.daysFromCivil(year, month, first.day);
                    n = 1;
                }
                if (year > first.year + 400) return; // cannot happen with a sane window; stops runaway rules
            },
            .yearly => {
                const year: i32 = first.year + @as(i32, @intCast(k * rule.interval));
                if (first.month != 2 or first.day != 29 or civil.isLeap(year)) {
                    cand[0] = civil.daysFromCivil(year, first.month, first.day);
                    n = 1;
                }
                if (year > first.year + 400) return;
            },
        }
        var past_end = n > 0 and cand[0] > last;
        for (cand[0..n]) |day| {
            if (rule.count) |c| if (seen >= c) return;
            if (day > last) {
                past_end = true;
                break;
            }
            seen += 1;
            if (day >= from) {
                try out.append(a, day);
                listed += 1;
                if (listed >= max_occurrences) return;
            }
        }
        if (past_end) return;
        // A skipped period has no candidates, so judge the end by where it would be.
        if (n == 0) {
            const approx: i64 = switch (rule.freq) {
                .monthly => start + (k + 1) * rule.interval * 28,
                .yearly => start + (k + 1) * rule.interval * 365,
                else => start,
            };
            if (approx > last + 366) return;
        }
        k += 1;
    }
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;

fn dn(y: i32, m: u8, day: u8) i64 {
    return civil.daysFromCivil(y, m, day);
}

test "parse: what is supported and what is not" {
    const r = parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=10").?;
    try testing.expectEqual(Freq.weekly, r.freq);
    try testing.expectEqual(@as(u32, 2), r.interval);
    try testing.expectEqual(@as(?u32, 10), r.count);
    try testing.expectEqual(@as(u8, 0b0010100), r.byday);
    try testing.expect(!r.isPlain());
    try testing.expect(parse("FREQ=DAILY").?.isPlain());
    try testing.expectEqual(@as(?Date, .{ .year = 2026, .month = 3, .day = 1 }), parse("FREQ=DAILY;UNTIL=20260301T000000Z").?.until);
    try testing.expect(parse("FREQ=MONTHLY;BYDAY=2TU") == null);
    try testing.expect(parse("FREQ=MONTHLY;BYMONTHDAY=15") == null);
    try testing.expect(parse("FREQ=MONTHLY;BYDAY=MO") == null); // BYDAY is weekly only
    try testing.expect(parse("INTERVAL=2") == null);
    try testing.expect(parse("FREQ=SECONDLY") == null);
    try testing.expect(parse("FREQ=DAILY;INTERVAL=0") == null);
}

test "daily with a count and an interval" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    try occurrences(testing.allocator, parse("FREQ=DAILY;INTERVAL=3;COUNT=4").?, .{ .year = 2026, .month = 11, .day = 1 }, 0, dn(2030, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2026, 11, 1), dn(2026, 11, 4), dn(2026, 11, 7), dn(2026, 11, 10) }, out.items);
}

test "count includes occurrences before the window" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    // Nov 1, 4, 7, 10: only the last two are in the window.
    try occurrences(testing.allocator, parse("FREQ=DAILY;INTERVAL=3;COUNT=4").?, .{ .year = 2026, .month = 11, .day = 1 }, dn(2026, 11, 6), dn(2030, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2026, 11, 7), dn(2026, 11, 10) }, out.items);
}

test "weekly on two days, every other week, until a date" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    // 2026-11-10 is a Tuesday. Weeks of Nov 9 and Nov 23 and Dec 7; stop at Dec 8.
    try occurrences(testing.allocator, parse("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20261208").?, .{ .year = 2026, .month = 11, .day = 10 }, 0, dn(2030, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2026, 11, 10), dn(2026, 11, 12), dn(2026, 11, 24), dn(2026, 11, 26), dn(2026, 12, 8) }, out.items);
}

test "weekly without BYDAY keeps the weekday of the first day" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    try occurrences(testing.allocator, parse("FREQ=WEEKLY;COUNT=3").?, .{ .year = 2026, .month = 11, .day = 11 }, 0, dn(2030, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2026, 11, 11), dn(2026, 11, 18), dn(2026, 11, 25) }, out.items);
}

test "weekly never lists a day before the first one" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    // Starts on Thursday Nov 12 with MO,TH: the Monday of that week is not listed.
    try occurrences(testing.allocator, parse("FREQ=WEEKLY;BYDAY=MO,TH;COUNT=3").?, .{ .year = 2026, .month = 11, .day = 12 }, 0, dn(2030, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2026, 11, 12), dn(2026, 11, 16), dn(2026, 11, 19) }, out.items);
}

test "monthly skips a month that is too short" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    try occurrences(testing.allocator, parse("FREQ=MONTHLY;COUNT=4").?, .{ .year = 2026, .month = 1, .day = 31 }, 0, dn(2030, 1, 1), &out);
    // February has no 31st, April no 31st: Jan, Mar, May, Jul.
    try testing.expectEqualSlices(i64, &.{ dn(2026, 1, 31), dn(2026, 3, 31), dn(2026, 5, 31), dn(2026, 7, 31) }, out.items);
}

test "yearly on Feb 29 only in leap years" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    try occurrences(testing.allocator, parse("FREQ=YEARLY;COUNT=3").?, .{ .year = 2024, .month = 2, .day = 29 }, 0, dn(2100, 1, 1), &out);
    try testing.expectEqualSlices(i64, &.{ dn(2024, 2, 29), dn(2028, 2, 29), dn(2032, 2, 29) }, out.items);
}

test "the window ends the list and a plain endless rule stays bounded" {
    var out: std.ArrayList(i64) = .empty;
    defer out.deinit(testing.allocator);
    try occurrences(testing.allocator, parse("FREQ=DAILY").?, .{ .year = 2026, .month = 1, .day = 1 }, dn(2026, 1, 1), dn(2026, 1, 10), &out);
    try testing.expectEqual(@as(usize, 10), out.items.len);
    out.clearRetainingCapacity();
    try occurrences(testing.allocator, parse("FREQ=DAILY").?, .{ .year = 2000, .month = 1, .day = 1 }, dn(2000, 1, 1), dn(2100, 1, 1), &out);
    try testing.expectEqual(@as(usize, max_occurrences), out.items.len);
}
