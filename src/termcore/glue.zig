//! libghostty-vt setup shared by the programs that host a terminal
//! (SPEC.md 4.3).

const std = @import("std");
const vt = @import("ghostty-vt");
const schemes = @import("schemes.zig");

pub fn rgb(value: u24) vt.color.RGB {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}

/// The default palette with the scheme's 16 ANSI colours in front.
pub fn palette(scheme: schemes.Scheme) vt.color.Palette {
    var p = vt.color.default;
    for (scheme.ansi, 0..) |c, i| p[i] = rgb(c);
    return p;
}

/// Terminal colours for a scheme: foreground, background, and the 16 ANSI
/// colours in the palette. The caller owns the palette (`deinit` on
/// `colors.palette`), which allocates a copy of the defaults.
pub fn terminalColors(allocator: std.mem.Allocator, scheme: schemes.Scheme) !vt.Terminal.Colors {
    return .{
        .background = .init(rgb(scheme.background)),
        .foreground = .init(rgb(scheme.foreground)),
        .cursor = .unset,
        .palette = try .init(allocator, palette(scheme)),
    };
}
