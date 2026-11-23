//! The compositor's settings, from `~/.config/dkde/compositor.toml` (or the
//! file named by DKDE_COMPOSITOR_CONFIG). Every key is optional and a missing
//! file is fine: the defaults are used, and a wrong value is reported and
//! replaced by its default instead of stopping the session.
//!
//!   [windows]
//!   layout = "floating"      # or "tiling": how windows are placed
//!   gap = 6                  # pixels between tiled windows and the screen edge
//!   master_ratio = 0.55      # the master window's share of the width when tiling
//!   edge-snap = true         # dragging a window to a screen edge snaps it (halves, quarters, top = maximize)
//!   focus = "click"          # or "follow": focus follows the mouse (dkde-wm; the compositor always focuses on click)
//!
//!   [input]
//!   layout = "us"            # xkb layout, variant, options (else XKB_DEFAULT_*, then labwc's environment file)
//!   options = "ctrl:nocaps"
//!   repeat_rate = 25         # keys per second, and the delay before repeating (ms)
//!   repeat_delay = 600
//!   natural_scrolling = false    # touchpads and mice (libinput), all optional
//!   tap_to_click = true
//!   pointer_speed = 0.0      # -1 to 1
//!
//!   [keys]                   # shortcuts, added to the built-in set (see keys.zig)
//!   "W-Return" = "exec dkde-term"
//!
//!   [windows] also takes: placement = "cascade" | "center" | "smart" | "pointer" (where new windows go),
//!   snap-windows = true (dragged windows meet the edges of other windows), inactive-opacity = 0.85
//!   (dim windows that are not focused; 1 turns it off)
//!
//!   [[rules]]                # per-window rules: see rules.zig
//!   app_id = "mpv"
//!   floating = true
//!
//!   [workspaces]
//!   count = 4                # virtual desktops, 1 to 9 (Super+1…9 switches, Super+Shift+1…9 moves a window)

const std = @import("std");
const toml = @import("toml");
const layout = @import("layout.zig");
const keys = @import("keys.zig");
const rules = @import("rules.zig");
const place = @import("place.zig");

pub const Input = struct {
    /// xkb layout, variant and options (e.g. "us", "intl", "ctrl:nocaps"); null leaves them to XKB_DEFAULT_*.
    layout: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    options: ?[]const u8 = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    natural_scrolling: ?bool = null,
    tap_to_click: ?bool = null,
    /// libinput pointer acceleration, -1 (slowest) to 1 (fastest).
    pointer_speed: ?f64 = null,
};

/// The optional desktop effects (`[effects]`): every one is off until it is switched on.
pub const Effects = struct {
    /// Windows fade and grow when they open and shrink away when minimized.
    animations: bool = false,
    animation_ms: u32 = 200,
};

/// Where a new window is put.
pub const Placement = enum { cascade, center, smart, pointer };

pub const Config = struct {
    policy: layout.Policy = .floating,
    options: layout.Options = .{},
    /// Focus follows the mouse instead of a click.
    focus_follows_mouse: bool = false,
    /// Dragging a window to a screen edge snaps it (left or right half, a corner quarter, the top edge maximizes).
    edge_snap: bool = true,
    placement: Placement = .cascade,
    /// Dragged windows meet the edges of other windows (and the screen).
    snap_windows: bool = true,
    /// Opacity of windows that are not focused (1 = no dimming).
    inactive_opacity: f32 = 1.0,
    effects: Effects = .{},
    /// The `[[rules]]` (owned: see `free`).
    rules: []const rules.Rule = &.{},
    /// How many virtual desktops (1 to 9).
    workspaces: usize = 4,
    input: Input = .{},
    /// The user's `[keys]` entries, on top of the built-in shortcuts (owned: see `free`).
    keys: []const keys.Entry = &.{},
};

pub fn free(gpa: std.mem.Allocator, config: Config) void {
    if (config.input.layout) |v| gpa.free(v);
    if (config.input.variant) |v| gpa.free(v);
    if (config.input.options) |v| gpa.free(v);
    for (config.keys) |e| {
        gpa.free(e.key);
        gpa.free(e.action);
    }
    gpa.free(config.keys);
    rules.freeAll(gpa, config.rules);
}

/// Reads settings from TOML text. Problems are described in `warnings`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, warnings: *std.ArrayList([]const u8)) !Config {
    var config: Config = .{};
    var doc = toml.Document.parse(gpa, text, .{}, null) catch {
        try warnings.append(gpa, try gpa.dupe(u8, "compositor.toml is not valid TOML; using the defaults"));
        return config;
    };
    defer doc.deinit();

    if (doc.root.getTable("input")) |t| {
        const inp = &config.input;
        if (t.getString("layout")) |v| inp.layout = try gpa.dupe(u8, v);
        if (t.getString("variant")) |v| inp.variant = try gpa.dupe(u8, v);
        if (t.getString("options")) |v| inp.options = try gpa.dupe(u8, v);
        if (t.getInt("repeat_rate")) |v| {
            if (v < 1 or v > 200) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[input] repeat_rate = {d}: expected 1 to 200; using 25", .{v}));
            } else inp.repeat_rate = @intCast(v);
        }
        if (t.getInt("repeat_delay")) |v| {
            if (v < 100 or v > 3000) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[input] repeat_delay = {d}: expected 100 to 3000; using 600", .{v}));
            } else inp.repeat_delay = @intCast(v);
        }
        if (t.get("natural_scrolling")) |v| switch (v) {
            .boolean => |b| inp.natural_scrolling = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[input] natural_scrolling: expected true or false; ignored")),
        };
        if (t.get("tap_to_click")) |v| switch (v) {
            .boolean => |b| inp.tap_to_click = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[input] tap_to_click: expected true or false; ignored")),
        };
        if (t.getFloat("pointer_speed")) |v| {
            if (v < -1 or v > 1) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[input] pointer_speed = {d}: expected -1 to 1; ignored", .{v}));
            } else inp.pointer_speed = v;
        }
    }
    if (doc.root.getTable("keys")) |table| {
        var list: std.ArrayList(keys.Entry) = .empty;
        errdefer list.deinit(gpa);
        var it = table.entries.iterator();
        while (it.next()) |entry| {
            const action = switch (entry.value_ptr.*) {
                .string => |a| a,
                else => {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[keys] \"{s}\": expected a string; ignored", .{entry.key_ptr.*}));
                    continue;
                },
            };
            if (keys.parseKey(entry.key_ptr.*) == null) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[keys] \"{s}\" is not a key; ignored", .{entry.key_ptr.*}));
                continue;
            }
            if (keys.parseAction(action) == null) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[keys] \"{s}\" = \"{s}\": not an action; ignored", .{ entry.key_ptr.*, action }));
                continue;
            }
            try list.append(gpa, .{ .key = try gpa.dupe(u8, entry.key_ptr.*), .action = try gpa.dupe(u8, action) });
        }
        config.keys = try list.toOwnedSlice(gpa);
    }
    if (doc.root.getTable("workspaces")) |w| {
        if (w.get("count")) |v| switch (v) {
            .integer => |i| {
                if (i < 1 or i > 9) {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[workspaces] count = {d}: expected 1 to 9; using {d}", .{ i, config.workspaces }));
                } else config.workspaces = @intCast(i);
            },
            else => try warnings.append(gpa, try gpa.dupe(u8, "[workspaces] count: expected an integer; using the default")),
        };
    }
    config.rules = try rules.parse(gpa, doc.root, warnings);
    if (doc.root.getTable("effects")) |t| {
        if (t.get("animations")) |v| switch (v) {
            .boolean => |b| config.effects.animations = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] animations: expected true or false; using false")),
        };
        if (t.get("animation-ms")) |v| switch (v) {
            .integer => |i| {
                if (i < 50 or i > 2000) {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[effects] animation-ms = {d}: expected 50 to 2000; using {d}", .{ i, config.effects.animation_ms }));
                } else config.effects.animation_ms = @intCast(i);
            },
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] animation-ms: expected an integer; using the default")),
        };
    }
    const windows = doc.root.getTable("windows") orelse return config;
    if (windows.get("placement")) |v| switch (v) {
        .string => |s| {
            if (std.meta.stringToEnum(Placement, s)) |pl| {
                config.placement = pl;
            } else try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[windows] placement = \"{s}\": expected cascade, center, smart or pointer; using cascade", .{s}));
        },
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] placement: expected a string; using cascade")),
    };
    if (windows.get("snap-windows")) |v| switch (v) {
        .boolean => |b| config.snap_windows = b,
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] snap-windows: expected true or false; using true")),
    };
    if (windows.get("inactive-opacity")) |v| {
        const f: ?f64 = switch (v) {
            .float => |x| x,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
        if (f != null and f.? >= 0.1 and f.? <= 1.0) {
            config.inactive_opacity = @floatCast(f.?);
        } else try warnings.append(gpa, try gpa.dupe(u8, "[windows] inactive-opacity: expected 0.1 to 1; using 1"));
    }
    if (windows.get("layout")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "floating")) {
                config.policy = .floating;
            } else if (std.mem.eql(u8, s, "tiling")) {
                config.policy = .tiling;
            } else try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[windows] layout = \"{s}\": expected \"floating\" or \"tiling\"; using floating", .{s}));
        },
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] layout: expected a string; using floating")),
    };
    if (windows.get("focus")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "follow")) {
                config.focus_follows_mouse = true;
            } else if (!std.mem.eql(u8, s, "click")) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[windows] focus = \"{s}\": expected \"click\" or \"follow\"; using click", .{s}));
            }
        },
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] focus: expected a string; using click")),
    };
    if (windows.get("edge-snap")) |v| switch (v) {
        .boolean => |b| config.edge_snap = b,
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] edge-snap: expected true or false; using true")),
    };
    if (windows.get("gap")) |v| switch (v) {
        .integer => |i| {
            if (i < 0 or i > 200) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[windows] gap = {d}: expected 0 to 200; using {d}", .{ i, config.options.gap }));
            } else config.options.gap = @intCast(i);
        },
        else => try warnings.append(gpa, try gpa.dupe(u8, "[windows] gap: expected an integer; using the default")),
    };
    if (windows.getFloat("master_ratio")) |r| {
        if (r < 0.1 or r > 0.9) {
            try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[windows] master_ratio = {d}: expected 0.1 to 0.9; using {d}", .{ r, config.options.master_ratio }));
        } else config.options.master_ratio = @floatCast(r);
    } else if (windows.get("master_ratio") != null) {
        try warnings.append(gpa, try gpa.dupe(u8, "[windows] master_ratio: expected a number; using the default"));
    }
    return config;
}

test "focus follows the mouse when asked, and bad values are reported" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const on = try parse(std.testing.allocator, "[windows]\nfocus = \"follow\"\n", &warnings);
    defer free(std.testing.allocator, on);
    try std.testing.expect(on.focus_follows_mouse);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    const bad = try parse(std.testing.allocator, "[windows]\nfocus = \"sloppy\"\n", &warnings);
    defer free(std.testing.allocator, bad);
    try std.testing.expect(!bad.focus_follows_mouse);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "placement, window snapping, dimming and rules" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[windows]\nplacement = \"smart\"\nsnap-windows = false\ninactive-opacity = 0.8\n[[rules]]\napp_id = \"mpv\"\nfloating = true\n", &warnings);
    defer free(std.testing.allocator, config);
    try std.testing.expectEqual(Placement.smart, config.placement);
    try std.testing.expect(!config.snap_windows);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), config.inactive_opacity, 0.001);
    try std.testing.expectEqual(@as(usize, 1), config.rules.len);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    const bad = try parse(std.testing.allocator, "[windows]\nplacement = \"random\"\ninactive-opacity = 4\n", &warnings);
    defer free(std.testing.allocator, bad);
    try std.testing.expectEqual(Placement.cascade, bad.placement);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
}

test "effects are off until asked for" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const off = try parse(std.testing.allocator, "", &warnings);
    try std.testing.expect(!off.effects.animations);
    const on = try parse(std.testing.allocator, "[effects]\nanimations = true\nanimation-ms = 300\n", &warnings);
    defer free(std.testing.allocator, on);
    try std.testing.expect(on.effects.animations);
    try std.testing.expectEqual(@as(u32, 300), on.effects.animation_ms);
    const bad = try parse(std.testing.allocator, "[effects]\nanimation-ms = 5\n", &warnings);
    defer free(std.testing.allocator, bad);
    try std.testing.expectEqual(@as(u32, 200), bad.effects.animation_ms);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "an empty document gives the defaults" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "", &warnings);
    try std.testing.expectEqual(layout.Policy.floating, config.policy);
    try std.testing.expectEqual(@as(i32, 6), config.options.gap);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "tiling with a gap and a ratio" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[windows]\nlayout = \"tiling\"\ngap = 12\nmaster_ratio = 0.6\n", &warnings);
    try std.testing.expectEqual(layout.Policy.tiling, config.policy);
    try std.testing.expectEqual(@as(i32, 12), config.options.gap);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), config.options.master_ratio, 0.001);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "workspace count" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[workspaces]\ncount = 6\n", &warnings);
    try std.testing.expectEqual(@as(usize, 6), config.workspaces);
    const bad = try parse(std.testing.allocator, "[workspaces]\ncount = 12\n", &warnings);
    try std.testing.expectEqual(@as(usize, 4), bad.workspaces);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "wrong values are reported and replaced by defaults" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[windows]\nlayout = \"dwindle\"\ngap = -3\nmaster_ratio = 5\n", &warnings);
    try std.testing.expectEqual(layout.Policy.floating, config.policy);
    try std.testing.expectEqual(@as(i32, 6), config.options.gap);
    try std.testing.expectEqual(@as(usize, 3), warnings.items.len);
}

test "text that is not TOML is reported, not fatal" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[windows\nlayout =", &warnings);
    try std.testing.expectEqual(layout.Policy.floating, config.policy);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "shortcuts from the settings file" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[keys]\n\"W-Return\" = \"exec dkde-term\"\n\"A-F4\" = \"none\"\n\"W-q\" = \"dance\"\n\"\" = \"close\"\n", &warnings);
    defer free(std.testing.allocator, config);
    try std.testing.expectEqual(@as(usize, 2), config.keys.len);
    try std.testing.expectEqualStrings("W-Return", config.keys[0].key);
    try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
}

test "input settings" {
    var warnings: std.ArrayList([]const u8) = .empty;
    defer {
        for (warnings.items) |w| std.testing.allocator.free(w);
        warnings.deinit(std.testing.allocator);
    }
    const config = try parse(std.testing.allocator, "[input]\nlayout = \"de\"\noptions = \"ctrl:nocaps\"\nrepeat_rate = 40\ntap_to_click = true\npointer_speed = 5\n", &warnings);
    defer free(std.testing.allocator, config);
    try std.testing.expectEqualStrings("de", config.input.layout.?);
    try std.testing.expect(config.input.variant == null);
    try std.testing.expectEqual(@as(i32, 40), config.input.repeat_rate);
    try std.testing.expectEqual(@as(?bool, true), config.input.tap_to_click);
    try std.testing.expect(config.input.pointer_speed == null);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}
