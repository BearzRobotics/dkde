//! Where applications installed by Flatpak and Snap keep their menu entries
//! and icons, and making sure every dkde program looks there.
//!
//! Flatpak exports its apps under `…/flatpak/exports/share` and Snap under
//! `/var/lib/snapd/desktop`; both are found only through `$XDG_DATA_DIRS`.
//! Their `/etc/profile.d` scripts add them for login shells, but a session
//! started some other way (or a distribution whose profile does not read
//! those scripts) would show neither the apps nor their icons. `ensure` adds
//! the folders that exist and are missing, in the order those scripts use.

const std = @import("std");

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// What `$XDG_DATA_DIRS` means when it is not set (XDG Base Directory).
pub const default_dirs = "/usr/local/share:/usr/share";

/// The value `$XDG_DATA_DIRS` should have: `current` (or the default) with
/// the per-user and system Flatpak exports in front, and Snap's folder at
/// the end, each only when `exists` says it is there and it is not listed.
/// The caller frees the result.
pub fn withAppDirs(gpa: std.mem.Allocator, current: ?[]const u8, home: []const u8, exists: *const fn ([]const u8) bool) ![]u8 {
    const base = if (current) |c| (if (c.len > 0) c else default_dirs) else default_dirs;
    var user_buf: [4096]u8 = undefined;
    const user_flatpak = std.fmt.bufPrint(&user_buf, "{s}/.local/share/flatpak/exports/share", .{home}) catch "";
    const front = [_][]const u8{ user_flatpak, "/var/lib/flatpak/exports/share" };
    const back = [_][]const u8{"/var/lib/snapd/desktop"};

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (front) |d| {
        if (d.len == 0 or listed(base, d) or !exists(d)) continue;
        try out.appendSlice(gpa, d);
        try out.append(gpa, ':');
    }
    try out.appendSlice(gpa, base);
    for (back) |d| {
        if (listed(base, d) or !exists(d)) continue;
        try out.append(gpa, ':');
        try out.appendSlice(gpa, d);
    }
    return out.toOwnedSlice(gpa);
}

fn listed(list: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |d| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, d, "/"), dir)) return true;
    }
    return false;
}

fn dirExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    return std.c.access(z.ptr, std.c.F_OK) == 0;
}

/// Adds the Flatpak and Snap folders to this process's `$XDG_DATA_DIRS`
/// (programs it starts inherit it). Call before GTK or GIO read it.
pub fn ensure() void {
    const gpa = std.heap.c_allocator;
    const current: ?[]const u8 = if (std.c.getenv("XDG_DATA_DIRS")) |v| std.mem.span(v) else null;
    const home: []const u8 = if (std.c.getenv("HOME")) |v| std.mem.span(v) else return;
    const value = withAppDirs(gpa, current, home, &dirExists) catch return;
    defer gpa.free(value);
    if (current != null and std.mem.eql(u8, value, current.?)) return;
    const z = gpa.dupeSentinel(u8, value, 0) catch return;
    defer gpa.free(z);
    _ = setenv("XDG_DATA_DIRS", z.ptr, 1);
}

fn allExist(_: []const u8) bool {
    return true;
}

fn noneExist(_: []const u8) bool {
    return false;
}

test "Flatpak goes in front, Snap at the end, nothing twice" {
    const gpa = std.testing.allocator;
    const a = try withAppDirs(gpa, null, "/home/u", &allExist);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/home/u/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share:/var/lib/snapd/desktop", a);

    // Already set up (as by the profile scripts): unchanged.
    const b = try withAppDirs(gpa, a, "/home/u", &allExist);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);

    // A trailing slash counts as listed; missing folders are not added.
    const c = try withAppDirs(gpa, "/usr/share:/var/lib/flatpak/exports/share/", "/home/u", &allExist);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("/home/u/.local/share/flatpak/exports/share:/usr/share:/var/lib/flatpak/exports/share/:/var/lib/snapd/desktop", c);
    const d = try withAppDirs(gpa, "", "/home/u", &noneExist);
    defer gpa.free(d);
    try std.testing.expectEqualStrings(default_dirs, d);
}
