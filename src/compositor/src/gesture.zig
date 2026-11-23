//! Mouse gestures, with no wlroots in them so they can be tested: a stroke drawn with the pointer is
//! reduced to the directions it went in (L, R, U, D), which settings map to actions.

const std = @import("std");

/// A stroke is a run of moves of at least this many pixels; shorter wobbles are ignored.
pub const min_step: f32 = 28;

/// The directions of `points` as letters (L R U D, repeated directions merged) written into `out`.
pub fn classify(points: []const [2]f32, out: []u8) []const u8 {
    var n: usize = 0;
    if (points.len < 2) return out[0..0];
    var ax = points[0][0];
    var ay = points[0][1];
    for (points[1..]) |p| {
        const dx = p[0] - ax;
        const dy = p[1] - ay;
        if (dx * dx + dy * dy < min_step * min_step) continue;
        const letter: u8 = if (@abs(dx) >= @abs(dy)) (if (dx < 0) 'L' else 'R') else (if (dy < 0) 'U' else 'D');
        if (n == 0 or out[n - 1] != letter) {
            if (n == out.len) return out[0..n];
            out[n] = letter;
            n += 1;
        }
        ax = p[0];
        ay = p[1];
    }
    return out[0..n];
}

/// Whether `text` is a gesture name: one to six of L, R, U, D.
pub fn valid(text: []const u8) bool {
    if (text.len == 0 or text.len > 6) return false;
    for (text) |ch| {
        if (std.mem.indexOfScalar(u8, "LRUD", ch) == null) return false;
    }
    return true;
}

test "strokes become directions" {
    var buf: [8]u8 = undefined;
    const left = [_][2]f32{ .{ 500, 400 }, .{ 450, 402 }, .{ 380, 399 }, .{ 300, 401 } };
    try std.testing.expectEqualStrings("L", classify(&left, &buf));
    const down_right = [_][2]f32{ .{ 100, 100 }, .{ 102, 160 }, .{ 100, 230 }, .{ 180, 232 }, .{ 260, 231 } };
    try std.testing.expectEqualStrings("DR", classify(&down_right, &buf));
    const up = [_][2]f32{ .{ 100, 300 }, .{ 99, 250 }, .{ 101, 190 } };
    try std.testing.expectEqualStrings("U", classify(&up, &buf));
}

test "a wobble is not a gesture" {
    var buf: [8]u8 = undefined;
    const wobble = [_][2]f32{ .{ 100, 100 }, .{ 108, 104 }, .{ 103, 98 }, .{ 110, 101 } };
    try std.testing.expectEqualStrings("", classify(&wobble, &buf));
    try std.testing.expectEqualStrings("", classify(&.{}, &buf));
}

test "names" {
    try std.testing.expect(valid("L") and valid("DRU"));
    try std.testing.expect(!valid("") and !valid("LX") and !valid("LLLLLLL"));
}
