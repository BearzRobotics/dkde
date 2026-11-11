//! The colour schemes dkde-term offers: the shared engine's (termcore) and
//! more, so the terminal and its Settings page list the same ones.

const std = @import("std");
const termcore = @import("termcore");

pub const Scheme = termcore.schemes.Scheme;

/// More schemes than the shared engine has: the defaults of GNOME Terminal
/// (Tango), Konsole (Breeze) and xterm, and some well-liked ones.
const extra = [_]struct { name: [:0]const u8, scheme: Scheme }{
    .{ .name = "tango-dark", .scheme = .{ .background = 0x2E3436, .foreground = 0xD3D7CF, .ansi = tango } },
    .{ .name = "tango-light", .scheme = .{ .background = 0xFFFFFF, .foreground = 0x2E3436, .ansi = tango } },
    .{ .name = "breeze", .scheme = .{ .background = 0x232627, .foreground = 0xFCFCFC, .ansi = .{
        0x232627, 0xED1515, 0x11D116, 0xF67400, 0x1D99F3, 0x9B59B6, 0x1ABC9C, 0xFCFCFC,
        0x7F8C8D, 0xC0392B, 0x1CDC9A, 0xFDBC4B, 0x3DAEE9, 0x8E44AD, 0x16A085, 0xFFFFFF,
    } } },
    .{ .name = "xterm", .scheme = .{ .background = 0x000000, .foreground = 0xE5E5E5, .ansi = .{
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    } } },
    .{ .name = "one-half-light", .scheme = .{ .background = 0xFAFAFA, .foreground = 0x383A42, .ansi = .{
        0x383A42, 0xE45649, 0x50A14F, 0xC18401, 0x0184BC, 0xA626A4, 0x0997B3, 0xFAFAFA,
        0x4F525E, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
    } } },
    .{ .name = "dracula", .scheme = .{ .background = 0x282A36, .foreground = 0xF8F8F2, .ansi = .{
        0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
        0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    } } },
    .{ .name = "gruvbox-dark", .scheme = .{ .background = 0x282828, .foreground = 0xEBDBB2, .ansi = .{
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    } } },
    .{ .name = "nord", .scheme = .{ .background = 0x2E3440, .foreground = 0xD8DEE9, .ansi = .{
        0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
        0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
    } } },
    .{ .name = "monokai", .scheme = .{ .background = 0x272822, .foreground = 0xF8F8F2, .ansi = .{
        0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
        0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
    } } },
    .{ .name = "tomorrow-night", .scheme = .{ .background = 0x1D1F21, .foreground = 0xC5C8C6, .ansi = .{
        0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
        0x969896, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xFFFFFF,
    } } },
    .{ .name = "catppuccin-mocha", .scheme = .{ .background = 0x1E1E2E, .foreground = 0xCDD6F4, .ansi = .{
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
        0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
    } } },
};

const tango = [16]u24{
    0x2E3436, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
    0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
};

/// Every scheme's name, for menus and Settings.
pub const names = blk: {
    var list: [termcore.schemes.names.len + extra.len][:0]const u8 = undefined;
    list[0] = "campbell";
    list[1] = "one-half-dark";
    list[2] = "solarized-dark";
    list[3] = "solarized-light";
    for (extra, 0..) |e, i| list[termcore.schemes.names.len + i] = e.name;
    break :blk list;
};

/// Looks a scheme up by name (any case); unknown names give the default.
pub fn scheme(name: []const u8) Scheme {
    for (extra) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e.scheme;
    return termcore.schemes.scheme(name);
}


test "the extra schemes are found and listed" {
    try std.testing.expectEqual(@as(u24, 0x282A36), scheme("Dracula").background);
    try std.testing.expect(names.len >= 14);
    for (names) |n| _ = scheme(n);
    // The engine's own schemes are all listed.
    for (termcore.schemes.names) |n| {
        var found = false;
        for (names) |m| found = found or std.mem.eql(u8, n, m);
        try std.testing.expect(found);
    }
}
