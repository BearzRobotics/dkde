//! The signed-in user: display name, profile picture and admin status.

const std = @import("std");
const glib = @import("glib2");

const config_mod = @import("config.zig");

/// Path of the profile picture: `[user] picture` in dkde.conf, else the
/// conventional `~/.face`. Owned by the caller; null when there is none.
pub fn picturePath(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ?[]u8 {
    if (cfg.getString(allocator, "user", "picture", "")) |configured| {
        if (configured.len > 0 and fileExists(configured)) return configured;
        allocator.free(configured);
    } else |_| {}

    const face = std.fmt.allocPrint(allocator, "{s}/.face", .{std.mem.span(glib.getHomeDir())}) catch return null;
    if (fileExists(face)) return face;
    allocator.free(face);
    return null;
}

fn fileExists(path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    return glib.fileTest(z, .{ .is_regular = true }) != 0;
}

/// The name to show: the real name when set, else the login name.
pub fn displayName() [*:0]const u8 {
    const real = glib.getRealName();
    const text = std.mem.span(real);
    if (text.len == 0 or std.mem.eql(u8, text, "Unknown")) return glib.getUserName();
    return real;
}

const admin_groups = [_][]const u8{ "sudo", "wheel", "admin" };

/// Whether any of `gids` belongs to an administrator group according to the
/// content of /etc/group (lines `name:x:gid:members`).
pub fn isAdmin(group_file: []const u8, gids: []const u32) bool {
    var lines = std.mem.splitScalar(u8, group_file, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const gid_text = fields.next() orelse continue;
        const gid = std.fmt.parseInt(u32, gid_text, 10) catch continue;
        for (admin_groups) |admin| {
            if (!std.mem.eql(u8, name, admin)) continue;
            for (gids) |g| if (g == gid) return true;
        }
    }
    return false;
}

/// Group ids from the `Groups:` line of /proc/self/status.
pub fn parseGroups(allocator: std.mem.Allocator, status: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Groups:")) continue;
        var it = std.mem.tokenizeAny(u8, line["Groups:".len..], " \t");
        while (it.next()) |tok| try out.append(allocator, std.fmt.parseInt(u32, tok, 10) catch continue);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads the process's groups and checks for an administrator group.
pub fn currentUserIsAdmin(allocator: std.mem.Allocator) bool {
    var status: [*]u8 = undefined;
    var status_len: usize = 0;
    if (glib.fileGetContents("/proc/self/status", &status, &status_len, null) == 0) return false;
    defer glib.free(status);
    var group: [*]u8 = undefined;
    var group_len: usize = 0;
    if (glib.fileGetContents("/etc/group", &group, &group_len, null) == 0) return false;
    defer glib.free(group);

    const gids = parseGroups(allocator, status[0..status_len]) catch return false;
    defer allocator.free(gids);
    return isAdmin(group[0..group_len], gids);
}

test "admin groups are recognised by gid" {
    const groups = "root:x:0:\nsudo:x:27:dakota\nusers:x:100:\n";
    try std.testing.expect(isAdmin(groups, &.{ 100, 27 }));
    try std.testing.expect(!isAdmin(groups, &.{100}));
    try std.testing.expect(isAdmin("wheel:x:10:me\n", &.{10}));
}

test "groups line is parsed" {
    const a = std.testing.allocator;
    const gids = try parseGroups(a, "Name:\tx\nGroups:\t4 24 27 1000\nUid:\t1\n");
    defer a.free(gids);
    try std.testing.expectEqualSlices(u32, &.{ 4, 24, 27, 1000 }, gids);
}
