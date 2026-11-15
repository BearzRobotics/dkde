//! The shared look of the desktop, from `[appearance]` in `~/.config/dkde/dkde.toml`
//! (the file Settings > Personalization writes): the accent colour, dark mode and
//! the interface font. dkde-wm uses them for its title bars, so they match the
//! programs inside them and follow a change at once.

const std = @import("std");
const toml = @import("toml");

pub const Rgb = [3]f64;

pub const Look = struct {
    accent: Rgb = .{ 0x35.0 / 255.0, 0x84.0 / 255.0, 0xe4.0 / 255.0 },
    dark: bool = false,
    font_buf: [96]u8 = undefined,
    font_len: usize = 0,

    pub fn font(self: *const Look) []const u8 {
        return self.font_buf[0..self.font_len];
    }
};

/// `#rrggbb` as three 0 to 1 values; null when it is not that.
pub fn parseHex(text: []const u8) ?Rgb {
    if (text.len != 7 or text[0] != '#') return null;
    var out: Rgb = undefined;
    for (0..3) |i| {
        const v = std.fmt.parseInt(u8, text[1 + i * 2 ..][0..2], 16) catch return null;
        out[i] = @as(f64, @floatFromInt(v)) / 255.0;
    }
    return out;
}

/// Reads `[appearance]`; anything missing or wrong keeps its default.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) Look {
    var look: Look = .{};
    var doc = toml.Document.parse(gpa, text, .{}, null) catch return look;
    defer doc.deinit();
    const t = doc.root.getTable("appearance") orelse return look;
    if (t.getString("accent")) |a| if (parseHex(a)) |rgb| {
        look.accent = rgb;
    };
    if (t.getBool("dark")) |d| look.dark = d;
    if (t.getString("font")) |f| if (f.len > 0 and f.len <= look.font_buf.len) {
        @memcpy(look.font_buf[0..f.len], f);
        look.font_len = f.len;
    };
    return look;
}

pub const Colors = struct { bar: Rgb, text: Rgb, edge: Rgb };

/// Title bar colours: the accent while the window has the focus, neutral grey otherwise (darker in dark mode).
pub fn colors(look: *const Look, focused: bool) Colors {
    if (focused) return .{ .bar = look.accent, .text = .{ 1, 1, 1 }, .edge = look.accent };
    if (look.dark) return .{ .bar = .{ 0.19, 0.19, 0.19 }, .text = .{ 0.82, 0.82, 0.82 }, .edge = .{ 0.30, 0.30, 0.30 } };
    return .{ .bar = .{ 0.84, 0.84, 0.84 }, .text = .{ 0.15, 0.15, 0.15 }, .edge = .{ 0.60, 0.60, 0.60 } };
}

test "the appearance section is read" {
    const l = parse(std.testing.allocator, "[appearance]\naccent = \"#ff8000\"\ndark = true\nfont = \"Inter 11\"\n");
    try std.testing.expect(l.dark);
    try std.testing.expectEqualStrings("Inter 11", l.font());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), l.accent[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0x80.0 / 255.0), l.accent[1], 0.001);
}

test "defaults for a missing file, bad values and wrong types" {
    const none = parse(std.testing.allocator, "");
    try std.testing.expect(!none.dark);
    try std.testing.expectEqual(@as(usize, 0), none.font().len);
    const bad = parse(std.testing.allocator, "[appearance]\naccent = \"red\"\ndark = \"yes\"\n");
    try std.testing.expect(!bad.dark);
    try std.testing.expectApproxEqAbs(none.accent[2], bad.accent[2], 0.0001);
    // Not TOML at all.
    try std.testing.expect(!parse(std.testing.allocator, "= = =").dark);
}

test "dark mode darkens the idle title bar, the focused one keeps the accent" {
    var l: Look = .{};
    const light = colors(&l, false);
    l.dark = true;
    const dark = colors(&l, false);
    try std.testing.expect(dark.bar[0] < light.bar[0]);
    try std.testing.expect(dark.text[0] > light.text[0]);
    try std.testing.expectEqual(l.accent, colors(&l, true).bar);
}
