// SPDX-License-Identifier: GPL-2.0-or-later
//! Keyboard shortcuts in `compositor.toml` `[keys]`, the file DKDE's compositor
//! and window manager read (Settings > Keyboard shortcuts when the session is
//! one of DKDE's own). The built-in set is `keys.defaults`; the file adds to it,
//! replaces a key, or removes one with "none". These functions work out what the
//! effective bindings are and what to write, with no toolkit involved.

const std = @import("std");
const shared = @import("shared");
const common = @import("common");

pub const shared_ = shared;
const keys = shared.keys;

/// Whether two key strings name the same key and modifiers, in any order and case of the letter.
pub fn sameKey(a: []const u8, b: []const u8) bool {
    const pa = keys.parseKey(a) orelse return std.mem.eql(u8, a, b);
    const pb = keys.parseKey(b) orelse return false;
    return pa.mods == pb.mods and std.ascii.eqlIgnoreCase(pa.name, pb.name);
}

/// The action bound to `key` after the built-ins and the user's entries are combined, or null.
pub fn ownerOf(user: []const keys.Entry, key: []const u8) ?[]const u8 {
    var owner: ?[]const u8 = null;
    for (keys.defaults) |d| if (sameKey(d.key, key)) {
        owner = d.action;
    };
    for (user) |e| if (sameKey(e.key, key)) {
        owner = e.action;
    };
    if (owner) |o| if (std.mem.eql(u8, o, "none")) return null;
    return owner;
}

/// The key that runs `action`, given what the person wrote: their own entry for it if there is one,
/// else the built-in key unless something else took that key. `default_key` is the built-in one.
pub fn keyFor(user: []const keys.Entry, action: []const u8, default_key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (user) |e| if (std.mem.eql(u8, e.action, action)) {
        found = e.key;
    };
    if (found) |f| return f;
    const owner = ownerOf(user, default_key) orelse return null;
    return if (std.mem.eql(u8, owner, action)) default_key else null;
}

/// `compositor.toml` text with `action` moved to `new_key`. The old binding is dropped, and so is the
/// built-in one when it differs; setting the built-in key again removes the overrides.
pub fn rebind(a: std.mem.Allocator, text: []const u8, user: []const keys.Entry, action: []const u8, default_key: []const u8, new_key: []const u8) ![]u8 {
    var out = try a.dupe(u8, text);
    errdefer a.free(out);
    // Entries of this action under any other key go.
    for (user) |e| if (std.mem.eql(u8, e.action, action) and !sameKey(e.key, new_key)) {
        const next = try common.tomltext.removeKey(a, out, "keys", e.key);
        a.free(out);
        out = next;
    };
    if (sameKey(new_key, default_key)) {
        // Back to the built-in: drop whatever overrode it.
        const next = try common.tomltext.removeKey(a, out, "keys", default_key);
        a.free(out);
        return next;
    }
    const line = try std.fmt.allocPrint(a, "\"{s}\" = \"{s}\"", .{ new_key, action });
    defer a.free(line);
    var next = try common.tomltext.setKey(a, out, "keys", new_key, line);
    a.free(out);
    out = next;
    // The built-in key stops doing it.
    const off = try std.fmt.allocPrint(a, "\"{s}\" = \"none\"", .{default_key});
    defer a.free(off);
    next = try common.tomltext.setKey(a, out, "keys", default_key, off);
    a.free(out);
    return next;
}

/// The compositor's action text for one of Settings' shortcut entries, or null when the compositor has no such action.
pub fn ourAction(kb: common.labwc.Keybind, buf: []u8) ?[]const u8 {
    const eql = std.mem.eql;
    if (kb.command.len > 0) return std.fmt.bufPrint(buf, "exec {s}", .{kb.command}) catch null;
    if (eql(u8, kb.action, "GoToDesktop")) return if (eql(u8, kb.to, "left")) "workspace-prev" else "workspace-next";
    if (eql(u8, kb.action, "SendToDesktop")) return if (eql(u8, kb.to, "left")) "move-to-prev" else "move-to-next";
    if (eql(u8, kb.action, "NextWindow")) return "next-window";
    if (eql(u8, kb.action, "PreviousWindow")) return "prev-window";
    if (eql(u8, kb.action, "Close")) return "close";
    if (eql(u8, kb.action, "ToggleMaximize")) return "maximize";
    if (eql(u8, kb.action, "SnapToEdge")) {
        const region = if (eql(u8, kb.to, "left")) "left-half" else if (eql(u8, kb.to, "right")) "right-half" else if (eql(u8, kb.to, "up")) "top-half" else "bottom-half";
        return std.fmt.bufPrint(buf, "snap {s}", .{region}) catch null;
    }
    if (eql(u8, kb.action, "SnapToRegion")) return std.fmt.bufPrint(buf, "snap {s}", .{kb.to}) catch null;
    return null;
}

pub fn parseUserKeys(a: std.mem.Allocator, text: []const u8) !shared.config.Config {
    return parseUser(a, text);
}

fn parseUser(a: std.mem.Allocator, text: []const u8) !shared.config.Config {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| a.free(w);
        warnings.deinit(a);
    }
    return shared.config.parse(a, text, &warnings);
}

test "a built-in key is reported until it is rebound" {
    const a = std.testing.allocator;
    const cfg = try parseUser(a, "");
    defer shared.config.free(a, cfg);
    try std.testing.expectEqualStrings("C-A-t", keyFor(cfg.keys, "exec dkde-term", "C-A-t").?);
    try std.testing.expectEqualStrings("exec dkde-term", ownerOf(cfg.keys, "C-A-T").?);
}

test "rebinding writes the new key and turns the old one off" {
    const a = std.testing.allocator;
    const text = "[windows]\nlayout = \"tiling\"\n";
    const cfg = try parseUser(a, text);
    defer shared.config.free(a, cfg);
    const out = try rebind(a, text, cfg.keys, "exec dkde-term", "C-A-t", "W-Return");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "layout = \"tiling\"") != null);

    const after = try parseUser(a, out);
    defer shared.config.free(a, after);
    try std.testing.expectEqualStrings("W-Return", keyFor(after.keys, "exec dkde-term", "C-A-t").?);
    try std.testing.expect(ownerOf(after.keys, "C-A-t") == null);
    try std.testing.expectEqualStrings("exec dkde-term", ownerOf(after.keys, "W-Return").?);

    // Back to the built-in key removes both lines.
    const back = try rebind(a, out, after.keys, "exec dkde-term", "C-A-t", "C-A-t");
    defer a.free(back);
    const again = try parseUser(a, back);
    defer shared.config.free(a, again);
    try std.testing.expectEqualStrings("C-A-t", keyFor(again.keys, "exec dkde-term", "C-A-t").?);
    try std.testing.expect(ownerOf(again.keys, "W-Return") == null);
}

test "moving a shortcut twice leaves one binding" {
    const a = std.testing.allocator;
    const first = try rebind(a, "", &.{}, "close", "A-F4", "C-q");
    defer a.free(first);
    const cfg = try parseUser(a, first);
    defer shared.config.free(a, cfg);
    const second = try rebind(a, first, cfg.keys, "close", "A-F4", "C-w");
    defer a.free(second);
    const after = try parseUser(a, second);
    defer shared.config.free(a, after);
    try std.testing.expectEqualStrings("C-w", keyFor(after.keys, "close", "A-F4").?);
    try std.testing.expect(ownerOf(after.keys, "C-q") == null);
    try std.testing.expect(ownerOf(after.keys, "A-F4") == null);
}

test "every shortcut Settings lists maps to an action the compositor has, at the same default key" {
    var buf: [96]u8 = undefined;
    for (common.labwc.dkde_keybinds) |kb| {
        const act = ourAction(kb, &buf) orelse {
            // The window menu is labwc's.
            try std.testing.expectEqualStrings("ShowMenu", kb.action);
            continue;
        };
        try std.testing.expect(keys.parseAction(act) != null);
        // The built-in key for that action is the one Settings shows as its default.
        var found = false;
        for (keys.defaults) |d| if (std.mem.eql(u8, d.action, act)) {
            if (sameKey(d.key, kb.key)) found = true;
        };
        if (!found) std.debug.print("no default for {s} on {s}\n", .{ act, kb.key });
        try std.testing.expect(found);
    }
}
