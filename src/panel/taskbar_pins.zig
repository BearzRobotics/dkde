//! Which apps are pinned to the taskbar: `[panel] taskbar-pinned` in panel.conf,
//! desktop file IDs in order. Written only when the user pins or unpins.

const std = @import("std");
const common = @import("common");

const log = std.log.scoped(.taskbar_pins);

/// The pinned desktop IDs, in order. Free with `common.config.freeStringList`.
pub fn ids(allocator: std.mem.Allocator) ![][]u8 {
    var cfg = try common.Config.load(allocator, "panel.conf");
    defer cfg.deinit();
    if (try cfg.getStringList(allocator, "panel", "taskbar-pinned")) |list| {
        // Drop empty entries (an empty key reads as one).
        var out: std.ArrayList([]u8) = .empty;
        errdefer common.config.freeStringList(allocator, out.items);
        for (list) |item| {
            const t = std.mem.trim(u8, item, " ");
            if (t.len > 0) try out.append(allocator, try allocator.dupe(u8, t));
        }
        common.config.freeStringList(allocator, list);
        return out.toOwnedSlice(allocator);
    }
    return allocator.alloc([]u8, 0);
}

pub fn isPinned(allocator: std.mem.Allocator, id: []const u8) bool {
    const list = ids(allocator) catch return false;
    defer common.config.freeStringList(allocator, list);
    for (list) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// The list after pinning or unpinning `id`, with `id` added at the end when pinned.
pub fn toggled(allocator: std.mem.Allocator, current: []const []const u8, id: []const u8) std.mem.Allocator.Error![][]const u8 {
    var next: std.ArrayList([]const u8) = .empty;
    errdefer next.deinit(allocator);
    var found = false;
    for (current) |p| {
        if (std.mem.eql(u8, p, id)) found = true else try next.append(allocator, p);
    }
    if (!found) try next.append(allocator, id);
    return next.toOwnedSlice(allocator);
}

/// Pins `id` if it is not pinned, else unpins it. The panel's file monitor
/// shows the change.
pub fn toggle(allocator: std.mem.Allocator, id: []const u8) void {
    const list = ids(allocator) catch return;
    defer common.config.freeStringList(allocator, list);
    const current: []const []const u8 = @ptrCast(list);
    const next = toggled(allocator, current, id) catch return;
    defer allocator.free(next);
    var cfg = common.Config.load(allocator, "panel.conf") catch return;
    defer cfg.deinit();
    cfg.setStringList("panel", "taskbar-pinned", next) catch |err| log.warn("cannot save taskbar pins: {s}", .{@errorName(err)});
}

test "toggling adds at the end and removes in place" {
    const a = std.testing.allocator;
    const cur = [_][]const u8{ "a.desktop", "b.desktop" };
    const added = try toggled(a, &cur, "c.desktop");
    defer a.free(added);
    try std.testing.expectEqual(@as(usize, 3), added.len);
    try std.testing.expectEqualStrings("c.desktop", added[2]);
    const removed = try toggled(a, &cur, "a.desktop");
    defer a.free(removed);
    try std.testing.expectEqual(@as(usize, 1), removed.len);
    try std.testing.expectEqualStrings("b.desktop", removed[0]);
}
