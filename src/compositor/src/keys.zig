//! Keyboard shortcuts: the key strings, the actions, and the built-in set.
//! No wlroots here, so it can be tested; main.zig maps the names to keysyms.
//!
//! A key is written the way labwc and dkde's Settings write it: modifiers
//! joined with `-` and then an xkb key name: `C-A-t` (Ctrl+Alt+T), `A-S-Tab`,
//! `W-Left` (W is the Super/logo key), `Print`. A bare modifier key
//! (`Super_L`) fires when it is pressed and released with nothing between.
//!
//! In compositor.toml, `[keys]` adds to or replaces the built-in set:
//!
//!   [keys]
//!   "W-Return" = "exec dkde-term"
//!   "A-F4" = "close"
//!   "A-Tab" = "none"            # removes a built-in shortcut

const std = @import("std");
const place = @import("place.zig");

pub const Mod = struct {
    pub const shift: u8 = 1;
    pub const ctrl: u8 = 2;
    pub const alt: u8 = 4;
    pub const logo: u8 = 8;
};

pub const Region = enum {
    left_half,
    right_half,
    top_half,
    bottom_half,
    left_third,
    middle_third,
    right_third,
    left_two_thirds,
    right_two_thirds,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

pub const Action = union(enum) {
    none,
    quit,
    close,
    next_window,
    prev_window,
    maximize,
    fullscreen,
    float,
    toggle_layout,
    workspace: u8,
    workspace_prev,
    workspace_next,
    move_to_workspace: u8,
    move_to_prev,
    move_to_next,
    snap: Region,
    /// Put the window at a corner, an edge or the centre, keeping its size.
    put: place.Position,
    sticky,
    above,
    below,
    /// Minimize every window of the workspace, or bring them back.
    show_desktop,
    /// Every window of the workspace at once, to pick one.
    scale,
    /// Every workspace as a tile, to pick one or drag windows between them.
    expo,
    opacity_up,
    opacity_down,
    exec: []const u8,
};

pub const ParsedKey = struct {
    /// A `Mod` bit set.
    mods: u8,
    /// The xkb key name, e.g. "t", "Left", "Super_L".
    name: []const u8,
};

pub fn parseKey(text: []const u8) ?ParsedKey {
    var mods: u8 = 0;
    var rest = std.mem.trim(u8, text, " ");
    // Modifiers are single letters followed by '-'; the key name is what is left (it may itself be "minus").
    while (rest.len >= 3 and rest[1] == '-') {
        switch (rest[0]) {
            'S' => mods |= Mod.shift,
            'C' => mods |= Mod.ctrl,
            'A' => mods |= Mod.alt,
            'W' => mods |= Mod.logo,
            else => break,
        }
        rest = rest[2..];
    }
    if (rest.len == 0 or (rest.len == 2 and rest[1] == '-')) return null;
    return .{ .mods = mods, .name = rest };
}

pub fn parseRegion(name: []const u8) ?Region {
    for (std.enums.values(Region)) |r| {
        const tag = @tagName(r);
        if (tag.len != name.len) continue;
        var same = true;
        for (tag, name) |x, y| {
            if ((if (x == '_') '-' else x) != y) same = false;
        }
        if (same) return r;
    }
    return null;
}

pub fn parseAction(text: []const u8) ?Action {
    const t = std.mem.trim(u8, text, " ");
    const eql = std.mem.eql;
    if (eql(u8, t, "none")) return .none;
    if (eql(u8, t, "quit")) return .quit;
    if (eql(u8, t, "close")) return .close;
    if (eql(u8, t, "next-window")) return .next_window;
    if (eql(u8, t, "prev-window")) return .prev_window;
    if (eql(u8, t, "maximize")) return .maximize;
    if (eql(u8, t, "fullscreen")) return .fullscreen;
    if (eql(u8, t, "float")) return .float;
    if (eql(u8, t, "toggle-layout")) return .toggle_layout;
    if (eql(u8, t, "workspace-prev")) return .workspace_prev;
    if (eql(u8, t, "workspace-next")) return .workspace_next;
    if (eql(u8, t, "move-to-prev")) return .move_to_prev;
    if (eql(u8, t, "move-to-next")) return .move_to_next;
    if (eql(u8, t, "sticky")) return .sticky;
    if (eql(u8, t, "above")) return .above;
    if (eql(u8, t, "below")) return .below;
    if (eql(u8, t, "show-desktop")) return .show_desktop;
    if (eql(u8, t, "scale")) return .scale;
    if (eql(u8, t, "expo")) return .expo;
    if (eql(u8, t, "opacity-up")) return .opacity_up;
    if (eql(u8, t, "opacity-down")) return .opacity_down;
    if (std.mem.startsWith(u8, t, "put ")) {
        const p = place.parsePosition(std.mem.trim(u8, t[4..], " ")) orelse return null;
        return .{ .put = p };
    }
    if (std.mem.startsWith(u8, t, "workspace ")) {
        const n = std.fmt.parseInt(u8, std.mem.trim(u8, t[10..], " "), 10) catch return null;
        return if (n >= 1 and n <= 9) .{ .workspace = n - 1 } else null;
    }
    if (std.mem.startsWith(u8, t, "move-to-workspace ")) {
        const n = std.fmt.parseInt(u8, std.mem.trim(u8, t[18..], " "), 10) catch return null;
        return if (n >= 1 and n <= 9) .{ .move_to_workspace = n - 1 } else null;
    }
    if (std.mem.startsWith(u8, t, "snap ")) {
        const r = parseRegion(std.mem.trim(u8, t[5..], " ")) orelse return null;
        return .{ .snap = r };
    }
    if (std.mem.startsWith(u8, t, "exec ")) {
        const cmd = std.mem.trim(u8, t[5..], " ");
        return if (cmd.len > 0) .{ .exec = cmd } else null;
    }
    return null;
}

pub const Entry = struct { key: []const u8, action: []const u8 };

/// The built-in shortcuts: dkde's set (the same keys Settings > Shortcuts shows for labwc) plus Super+digit workspaces (not Alt: programs keep Alt+digit and Alt+letter for their own menus and modes).
pub const defaults = [_]Entry{
    .{ .key = "Super_L", .action = "exec dkde-panel msg toggle-menu" },
    .{ .key = "C-A-t", .action = "exec dkde-term" },
    .{ .key = "C-A-l", .action = "exec dkde-panel msg lock" },
    .{ .key = "C-S-Escape", .action = "exec dkde-tasks" },
    .{ .key = "Print", .action = "exec dkde-snip" },
    .{ .key = "S-Print", .action = "exec dkde-snip --full" },
    .{ .key = "XF86AudioRaiseVolume", .action = "exec dkde-panel msg volume-up" },
    .{ .key = "XF86AudioLowerVolume", .action = "exec dkde-panel msg volume-down" },
    .{ .key = "XF86AudioMute", .action = "exec dkde-panel msg volume-mute" },
    .{ .key = "XF86MonBrightnessUp", .action = "exec dkde-panel msg brightness-up" },
    .{ .key = "XF86MonBrightnessDown", .action = "exec dkde-panel msg brightness-down" },
    .{ .key = "C-A-Left", .action = "workspace-prev" },
    .{ .key = "C-A-Right", .action = "workspace-next" },
    .{ .key = "C-A-S-Left", .action = "move-to-prev" },
    .{ .key = "C-A-S-Right", .action = "move-to-next" },
    .{ .key = "A-Tab", .action = "next-window" },
    .{ .key = "A-S-Tab", .action = "prev-window" },
    .{ .key = "A-F4", .action = "close" },
    .{ .key = "W-a", .action = "maximize" },
    .{ .key = "W-f", .action = "fullscreen" },
    .{ .key = "W-Left", .action = "snap left-half" },
    .{ .key = "W-Right", .action = "snap right-half" },
    .{ .key = "W-Up", .action = "snap top-half" },
    .{ .key = "W-Down", .action = "snap bottom-half" },
    .{ .key = "W-z", .action = "exec dkde-snap" },
    // The regions dkde-snap's layouts use (it presses these through the virtual keyboard).
    .{ .key = "W-C-A-S-a", .action = "snap left-half" },
    .{ .key = "W-C-A-S-b", .action = "snap right-half" },
    .{ .key = "W-C-A-S-c", .action = "snap top-half" },
    .{ .key = "W-C-A-S-d", .action = "snap bottom-half" },
    .{ .key = "W-C-A-S-e", .action = "snap left-third" },
    .{ .key = "W-C-A-S-f", .action = "snap middle-third" },
    .{ .key = "W-C-A-S-g", .action = "snap right-third" },
    .{ .key = "W-C-A-S-h", .action = "snap left-two-thirds" },
    .{ .key = "W-C-A-S-i", .action = "snap right-two-thirds" },
    .{ .key = "W-C-A-S-j", .action = "snap top-left" },
    .{ .key = "W-C-A-S-k", .action = "snap top-right" },
    .{ .key = "W-C-A-S-l", .action = "snap bottom-left" },
    .{ .key = "W-C-A-S-m", .action = "snap bottom-right" },
    // The compositor's own.
    .{ .key = "W-t", .action = "toggle-layout" },
    .{ .key = "W-d", .action = "show-desktop" },
    .{ .key = "W-w", .action = "scale" },
    .{ .key = "W-e", .action = "expo" },
    .{ .key = "W-C-Up", .action = "opacity-up" },
    .{ .key = "W-C-Down", .action = "opacity-down" },
    .{ .key = "W-S-space", .action = "float" },
    .{ .key = "W-S-Escape", .action = "quit" },
    .{ .key = "W-1", .action = "workspace 1" },
    .{ .key = "W-2", .action = "workspace 2" },
    .{ .key = "W-3", .action = "workspace 3" },
    .{ .key = "W-4", .action = "workspace 4" },
    .{ .key = "W-5", .action = "workspace 5" },
    .{ .key = "W-6", .action = "workspace 6" },
    .{ .key = "W-7", .action = "workspace 7" },
    .{ .key = "W-8", .action = "workspace 8" },
    .{ .key = "W-9", .action = "workspace 9" },
    .{ .key = "W-S-1", .action = "move-to-workspace 1" },
    .{ .key = "W-S-2", .action = "move-to-workspace 2" },
    .{ .key = "W-S-3", .action = "move-to-workspace 3" },
    .{ .key = "W-S-4", .action = "move-to-workspace 4" },
    .{ .key = "W-S-5", .action = "move-to-workspace 5" },
    .{ .key = "W-S-6", .action = "move-to-workspace 6" },
    .{ .key = "W-S-7", .action = "move-to-workspace 7" },
    .{ .key = "W-S-8", .action = "move-to-workspace 8" },
    .{ .key = "W-S-9", .action = "move-to-workspace 9" },
};

test "keys parse" {
    const k = parseKey("C-A-t").?;
    try std.testing.expectEqual(Mod.ctrl | Mod.alt, k.mods);
    try std.testing.expectEqualStrings("t", k.name);
    const bare = parseKey("Super_L").?;
    try std.testing.expectEqual(@as(u8, 0), bare.mods);
    try std.testing.expectEqualStrings("Super_L", bare.name);
    const shifted = parseKey("W-S-Tab").?;
    try std.testing.expectEqual(Mod.logo | Mod.shift, shifted.mods);
    try std.testing.expectEqualStrings("Tab", shifted.name);
    try std.testing.expect(parseKey("") == null);
    try std.testing.expect(parseKey("A-") == null);
}

test "actions parse" {
    try std.testing.expectEqual(Action.close, parseAction("close").?);
    try std.testing.expectEqual(@as(u8, 2), parseAction("workspace 3").?.workspace);
    try std.testing.expectEqual(@as(u8, 0), parseAction("move-to-workspace 1").?.move_to_workspace);
    try std.testing.expectEqual(Region.left_two_thirds, parseAction("snap left-two-thirds").?.snap);
    try std.testing.expectEqualStrings("dkde-term -e top", parseAction("exec dkde-term -e top").?.exec);
    try std.testing.expect(parseAction("workspace 12") == null);
    try std.testing.expect(parseAction("snap nowhere") == null);
    try std.testing.expect(parseAction("exec ") == null);
    try std.testing.expect(parseAction("dance") == null);
}

test "window actions parse" {
    try std.testing.expectEqual(place.Position.top_right, parseAction("put top-right").?.put);
    try std.testing.expectEqual(Action.sticky, parseAction("sticky").?);
    try std.testing.expectEqual(Action.show_desktop, parseAction("show-desktop").?);
    try std.testing.expect(parseAction("put nowhere") == null);
}

test "every built-in shortcut is valid" {
    for (defaults) |d| {
        try std.testing.expect(parseKey(d.key) != null);
        try std.testing.expect(parseAction(d.action) != null);
    }
}
