//! Colour conversions for the colour picker. Pure.

const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Hsl = struct { h: u16, s: u8, l: u8 };

/// "#3584e4", "3584E4" or "#35e" (short form).
pub fn parseHex(text: []const u8) ?Rgb {
    var t = std.mem.trim(u8, text, " \t");
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len == 3) {
        const r = std.fmt.charToDigit(t[0], 16) catch return null;
        const g = std.fmt.charToDigit(t[1], 16) catch return null;
        const b = std.fmt.charToDigit(t[2], 16) catch return null;
        return .{ .r = @intCast(r * 17), .g = @intCast(g * 17), .b = @intCast(b * 17) };
    }
    if (t.len != 6) return null;
    const v = std.fmt.parseInt(u24, t, 16) catch return null;
    return .{ .r = @intCast(v >> 16), .g = @intCast(v >> 8 & 0xff), .b = @intCast(v & 0xff) };
}

pub fn toHex(c: Rgb, buf: *[7]u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch "";
}

pub fn toHsl(c: Rgb) Hsl {
    const r = @as(f64, @floatFromInt(c.r)) / 255.0;
    const g = @as(f64, @floatFromInt(c.g)) / 255.0;
    const b = @as(f64, @floatFromInt(c.b)) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const l = (max + min) / 2.0;
    var h: f64 = 0;
    var s: f64 = 0;
    if (max != min) {
        const d = max - min;
        s = if (l > 0.5) d / (2.0 - max - min) else d / (max + min);
        if (max == r) {
            h = (g - b) / d + (if (g < b) @as(f64, 6) else 0);
        } else if (max == g) {
            h = (b - r) / d + 2;
        } else {
            h = (r - g) / d + 4;
        }
        h *= 60;
    }
    return .{ .h = @intFromFloat(@round(h)), .s = @intFromFloat(@round(s * 100)), .l = @intFromFloat(@round(l * 100)) };
}

test "hex parsing and printing" {
    try std.testing.expectEqual(Rgb{ .r = 0x35, .g = 0x84, .b = 0xe4 }, parseHex("#3584E4").?);
    try std.testing.expectEqual(Rgb{ .r = 0x33, .g = 0xff, .b = 0xee }, parseHex("3fe").?);
    try std.testing.expect(parseHex("#12345") == null);
    try std.testing.expect(parseHex("zzzzzz") == null);
    var buf: [7]u8 = undefined;
    try std.testing.expectEqualStrings("#3584e4", toHex(.{ .r = 0x35, .g = 0x84, .b = 0xe4 }, &buf));
}

test "hsl" {
    try std.testing.expectEqual(Hsl{ .h = 0, .s = 100, .l = 50 }, toHsl(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(Hsl{ .h = 120, .s = 100, .l = 50 }, toHsl(.{ .r = 0, .g = 255, .b = 0 }));
    try std.testing.expectEqual(Hsl{ .h = 0, .s = 0, .l = 100 }, toHsl(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(Hsl{ .h = 0, .s = 0, .l = 0 }, toHsl(.{ .r = 0, .g = 0, .b = 0 }));
}
