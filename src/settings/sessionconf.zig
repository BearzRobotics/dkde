//! Which window system the next sign-in starts: DKDE's own Wayland compositor (the default), DKDE's
//! X11 window manager, or labwc (the backup compositor, being phased out). dkde-session reads `~/.config/dkde/session.conf` (`compositor=` and `type=` lines);
//! this edits those two lines and leaves every other line alone.

const std = @import("std");

/// In the order Settings lists them.
pub const Choice = enum { dkde_compositor, dkde_wm, labwc };

/// What the file says now (dkde-compositor when it says nothing).
pub fn current(text: []const u8) Choice {
    var compositor: []const u8 = "";
    var kind: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "compositor=")) compositor = std.mem.trim(u8, line[11..], " ");
        if (std.mem.startsWith(u8, line, "type=")) kind = std.mem.trim(u8, line[5..], " ");
    }
    if (std.mem.eql(u8, kind, "x11")) return .dkde_wm;
    if (std.mem.eql(u8, compositor, "labwc")) return .labwc;
    return .dkde_compositor;
}

/// The file's text with the two lines set for `choice`; other lines (and their order) are kept.
pub fn set(a: std.mem.Allocator, text: []const u8, choice: Choice) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "compositor=") or std.mem.startsWith(u8, line, "type=")) continue;
        // Keep everything else, but not the empty last piece after a trailing newline.
        if (lines.peek() == null and raw.len == 0) break;
        try out.appendSlice(a, raw);
        try out.append(a, '\n');
    }
    switch (choice) {
        // The default needs no line.
        .dkde_compositor => {},
        .labwc => try out.appendSlice(a, "compositor=labwc\n"),
        .dkde_wm => try out.appendSlice(a, "type=x11\n"),
    }
    return out.toOwnedSlice(a);
}

test "reading the choice" {
    try std.testing.expectEqual(Choice.dkde_compositor, current(""));
    try std.testing.expectEqual(Choice.dkde_compositor, current("compositor=dkde-compositor\n"));
    try std.testing.expectEqual(Choice.dkde_wm, current("type=x11\n"));
    try std.testing.expectEqual(Choice.dkde_wm, current("compositor=labwc\ntype=x11\n"));
    try std.testing.expectEqual(Choice.labwc, current("compositor=labwc\n"));
}

test "setting it keeps other lines and replaces ours" {
    const a = std.testing.allocator;
    const one = try set(a, "# my note\nother=1\ncompositor=dkde-compositor\n", .labwc);
    defer a.free(one);
    try std.testing.expectEqualStrings("# my note\nother=1\ncompositor=labwc\n", one);
    const two = try set(a, one, .dkde_wm);
    defer a.free(two);
    try std.testing.expectEqualStrings("# my note\nother=1\ntype=x11\n", two);
    const three = try set(a, two, .dkde_compositor);
    defer a.free(three);
    try std.testing.expectEqualStrings("# my note\nother=1\n", three);
    const empty = try set(a, "", .dkde_compositor);
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
}
