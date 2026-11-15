//! The compositor's settings, from `~/.config/dkde/compositor.toml` (or the
//! file named by DKDE_COMPOSITOR_CONFIG). Every key is optional and a missing
//! file is fine: the defaults are used, and a wrong value is reported and
//! replaced by its default instead of stopping the session.
//!
//!   [windows]
//!   layout = "floating"      # or "tiling": how windows are placed
//!   gap = 6                  # pixels between tiled windows and the screen edge
//!   master_ratio = 0.55      # the master window's share of the width when tiling

const std = @import("std");
const toml = @import("toml");
const layout = @import("layout.zig");

pub const Config = struct {
    policy: layout.Policy = .floating,
    options: layout.Options = .{},
};

/// Reads settings from TOML text. Problems are described in `warnings`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, warnings: *std.ArrayList([]const u8)) !Config {
    var config: Config = .{};
    var doc = toml.Document.parse(gpa, text, .{}, null) catch {
        try warnings.append(gpa, try gpa.dupe(u8, "compositor.toml is not valid TOML; using the defaults"));
        return config;
    };
    defer doc.deinit();

    const windows = doc.root.getTable("windows") orelse return config;
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
