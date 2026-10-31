//! Time arithmetic for the Clock app. Pure.

const std = @import("std");

/// "01:02:03.45" (hours only when there are some).
pub fn formatElapsed(buf: []u8, ms: u64) []const u8 {
    const total_s = ms / 1000;
    const h = total_s / 3600;
    const m = total_s % 3600 / 60;
    const s = total_s % 60;
    const cs = ms % 1000 / 10;
    const r = if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}.{d:0>2}", .{ h, m, s, cs })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}.{d:0>2}", .{ m, s, cs });
    return r catch "";
}

/// "05:00" for a countdown, rounding up so it reads 00:01 until it ends.
pub fn formatCountdown(buf: []u8, remaining_ms: u64) []const u8 {
    const total_s = (remaining_ms + 999) / 1000;
    const h = total_s / 3600;
    const m = total_s % 3600 / 60;
    const s = total_s % 60;
    const r = if (h > 0)
        std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s })
    else
        std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ m, s });
    return r catch "";
}

/// Seconds from `now` (seconds since midnight) until the next time the clock
/// shows `target` (also seconds since midnight); a target that has passed
/// today means tomorrow, and a target equal to now means a full day.
pub fn secondsUntil(now: u32, target: u32) u32 {
    const day: u32 = 86400;
    return if (target > now) target - now else target + day - now;
}

test "elapsed time" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00:00.00", formatElapsed(&buf, 0));
    try std.testing.expectEqualStrings("01:02.34", formatElapsed(&buf, 62340));
    try std.testing.expectEqualStrings("1:01:01.50", formatElapsed(&buf, 3661500));
}

test "countdown rounds up" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("05:00", formatCountdown(&buf, 300000));
    try std.testing.expectEqualStrings("00:01", formatCountdown(&buf, 1));
    try std.testing.expectEqualStrings("00:00", formatCountdown(&buf, 0));
    try std.testing.expectEqualStrings("1:00:00", formatCountdown(&buf, 3600000));
}

test "alarm distance" {
    try std.testing.expectEqual(@as(u32, 3600), secondsUntil(8 * 3600, 9 * 3600));
    try std.testing.expectEqual(@as(u32, 23 * 3600), secondsUntil(9 * 3600, 8 * 3600));
    try std.testing.expectEqual(@as(u32, 86400), secondsUntil(100, 100));
}
