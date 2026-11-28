// SPDX-License-Identifier: GPL-2.0-or-later
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
//!   [effects]                # optional extras, all off by default: animations = true, animation-ms = 200,
//!                            # scale = true (Super+W), expo = true (Super+E),
//!                            # filter = "negative" | "grayscale" | "sepia" | "high-contrast" | "protanopia" |
//!                            # "deuteranopia" | "tritanopia", zoom = true (Super+= and Super+-), GLES renderer only
//!                            # switcher = "strip" or "ring" (Alt+Tab shows window previews)
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
const filters = @import("filters.zig");
const gesture = @import("gesture.zig");

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

/// What Alt+Tab shows: nothing (the next window just comes to the front), a strip of window previews, or a ring of them.
pub const Switcher = enum { off, strip, ring };

/// The optional desktop effects (`[effects]`): every one is off until it is switched on.
pub const Effects = struct {
    /// Windows fade and grow when they open and shrink away when minimized.
    animations: bool = false,
    animation_ms: u32 = 200,
    /// Scale (Super+W): all windows of the workspace at once. Expo (Super+E): all workspaces, drag windows between them.
    scale: bool = false,
    expo: bool = false,
    switcher: Switcher = .off,
    /// A colour filter over the whole screen (needs the GLES renderer).
    filter: filters.Filter = .none,
    /// Super+= and Super+- magnify the screen around the pointer (needs the GLES renderer).
    zoom: bool = false,
    /// Windows stretch and swing like jelly when dragged, snapped or maximized (needs the GLES renderer).
    wobbly: bool = false,
    /// Blur what is behind translucent windows (needs the GLES renderer).
    blur: bool = false,
    /// Switching workspaces turns a cube (needs the GLES renderer and at least three workspaces).
    cube: bool = false,
    /// Snow falls over the desktop (needs the GLES renderer).
    snow: bool = false,
    /// Windows further back in the focus order are more see-through (instead of one dimming for all unfocused ones).
    trailfocus: bool = false,
    /// Super+M: a round magnifying lens that follows the pointer (needs the GLES renderer).
    lens: bool = false,
    /// Ripples spread from the pointer as it moves (needs the GLES renderer).
    water: bool = false,
    /// Super+Shift+F: flames follow the pointer (needs the GLES renderer).
    fire: bool = false,
    /// Super+Shift+P: draw on the screen with the pointer (needs the GLES renderer).
    paint: bool = false,
    /// Windows you point at are shown through the windows on top of them.
    opacify: bool = false,
    /// A faint trail behind things that move (needs the GLES renderer).
    motion_blur: bool = false,
    /// Super + right button, drag: a stroke that runs an action (see `[gestures]`).
    gestures: bool = false,
    /// Super+Shift+S shrinks a window to a thumbnail at the edge of the screen.
    shelf: bool = false,
    /// Super+G groups windows into tabs.
    groups: bool = false,
};

/// A filter by its name in compositor.toml ("high-contrast" has a dash).
pub fn parseFilter(name: []const u8) ?filters.Filter {
    for (std.enums.values(filters.Filter)) |f| {
        const tag = @tagName(f);
        if (tag.len != name.len) continue;
        var same = true;
        for (tag, name) |x, y| {
            if ((if (x == '_') '-' else x) != y) same = false;
        }
        if (same) return f;
    }
    return null;
}

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
    /// The `[gestures]` entries: a gesture such as "L" or "DR" and its action (owned: see `free`).
    gestures: []const keys.Entry = &.{},
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
    for (config.gestures) |e| {
        gpa.free(e.key);
        gpa.free(e.action);
    }
    gpa.free(config.gestures);
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
    if (doc.root.getTable("gestures")) |table| {
        var list: std.ArrayList(keys.Entry) = .empty;
        errdefer list.deinit(gpa);
        var it = table.entries.iterator();
        while (it.next()) |entry| {
            const action = switch (entry.value_ptr.*) {
                .string => |a| a,
                else => {
                    try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[gestures] \"{s}\": expected a string; ignored", .{entry.key_ptr.*}));
                    continue;
                },
            };
            if (!gesture.valid(entry.key_ptr.*)) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[gestures] \"{s}\" is not a gesture (one to six of L R U D); ignored", .{entry.key_ptr.*}));
                continue;
            }
            if (keys.parseAction(action) == null) {
                try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[gestures] \"{s}\" = \"{s}\": not an action; ignored", .{ entry.key_ptr.*, action }));
                continue;
            }
            try list.append(gpa, .{ .key = try gpa.dupe(u8, entry.key_ptr.*), .action = try gpa.dupe(u8, action) });
        }
        config.gestures = try list.toOwnedSlice(gpa);
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
        if (t.get("scale")) |v| switch (v) {
            .boolean => |b| config.effects.scale = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] scale: expected true or false; using false")),
        };
        if (t.get("switcher")) |v| switch (v) {
            .string => |sw| {
                if (std.meta.stringToEnum(Switcher, sw)) |e| {
                    config.effects.switcher = e;
                } else try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[effects] switcher = \"{s}\": expected off, strip or ring; using off", .{sw}));
            },
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] switcher: expected a string; using off")),
        };
        if (t.get("filter")) |v| switch (v) {
            .string => |f| {
                if (parseFilter(f)) |e| {
                    config.effects.filter = e;
                } else try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[effects] filter = \"{s}\": not a filter; using none", .{f}));
            },
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] filter: expected a string; using none")),
        };
        if (t.get("wobbly")) |v| switch (v) {
            .boolean => |b| config.effects.wobbly = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] wobbly: expected true or false; using false")),
        };
        inline for (.{ .{ "trailfocus", "trailfocus" }, .{ "lens", "lens" }, .{ "water", "water" }, .{ "fire", "fire" }, .{ "paint", "paint" }, .{ "opacify", "opacify" }, .{ "motion-blur", "motion_blur" }, .{ "gestures", "gestures" }, .{ "shelf", "shelf" }, .{ "groups", "groups" } }) |pair| {
            if (t.get(pair[0])) |v| switch (v) {
                .boolean => |b| @field(config.effects, pair[1]) = b,
                else => try warnings.append(gpa, try std.fmt.allocPrint(gpa, "[effects] {s}: expected true or false; using false", .{pair[0]})),
            };
        }
        if (t.get("snow")) |v| switch (v) {
            .boolean => |b| config.effects.snow = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] snow: expected true or false; using false")),
        };
        if (t.get("cube")) |v| switch (v) {
            .boolean => |b| config.effects.cube = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] cube: expected true or false; using false")),
        };
        if (t.get("blur")) |v| switch (v) {
            .boolean => |b| config.effects.blur = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] blur: expected true or false; using false")),
        };
        if (t.get("zoom")) |v| switch (v) {
            .boolean => |b| config.effects.zoom = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] zoom: expected true or false; using false")),
        };
        if (t.get("expo")) |v| switch (v) {
            .boolean => |b| config.effects.expo = b,
            else => try warnings.append(gpa, try gpa.dupe(u8, "[effects] expo: expected true or false; using false")),
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
    const sw = try parse(std.testing.allocator, "[effects]\nswitcher = \"ring\"\n", &warnings);
    defer free(std.testing.allocator, sw);
    try std.testing.expectEqual(Switcher.ring, sw.effects.switcher);
    const fl = try parse(std.testing.allocator, "[effects]\nfilter = \"high-contrast\"\nzoom = true\n", &warnings);
    defer free(std.testing.allocator, fl);
    try std.testing.expectEqual(filters.Filter.high_contrast, fl.effects.filter);
    try std.testing.expect(fl.effects.zoom);
    const wb = try parse(std.testing.allocator, "[effects]\nwobbly = true\n", &warnings);
    defer free(std.testing.allocator, wb);
    try std.testing.expect(wb.effects.wobbly);
    const bl = try parse(std.testing.allocator, "[effects]\nblur = true\n", &warnings);
    defer free(std.testing.allocator, bl);
    try std.testing.expect(bl.effects.blur);
    const cb = try parse(std.testing.allocator, "[effects]\ncube = true\n", &warnings);
    defer free(std.testing.allocator, cb);
    try std.testing.expect(cb.effects.cube);
    const sn = try parse(std.testing.allocator, "[effects]\nsnow = true\n", &warnings);
    defer free(std.testing.allocator, sn);
    try std.testing.expect(sn.effects.snow);
    const more = try parse(std.testing.allocator, "[effects]\ntrailfocus = true\nlens = true\nwater = true\nfire = true\npaint = true\n", &warnings);
    defer free(std.testing.allocator, more);
    var gw: std.ArrayList([]const u8) = .empty;
    defer {
        for (gw.items) |w| std.testing.allocator.free(w);
        gw.deinit(std.testing.allocator);
    }
    const gs = try parse(std.testing.allocator, "[effects]\ngestures = true\nshelf = true\ngroups = true\n[gestures]\n\"L\" = \"workspace-prev\"\n\"LX\" = \"close\"\n\"U\" = \"dance\"\n", &gw);
    defer free(std.testing.allocator, gs);
    try std.testing.expect(gs.effects.gestures and gs.effects.shelf and gs.effects.groups);
    try std.testing.expectEqual(@as(usize, 1), gs.gestures.len);
    try std.testing.expectEqual(@as(usize, 2), gw.items.len);
    const ob = try parse(std.testing.allocator, "[effects]\nopacify = true\nmotion-blur = true\n", &warnings);
    defer free(std.testing.allocator, ob);
    try std.testing.expect(ob.effects.opacify and ob.effects.motion_blur);
    try std.testing.expect(more.effects.trailfocus and more.effects.lens and more.effects.water and more.effects.fire and more.effects.paint);
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
