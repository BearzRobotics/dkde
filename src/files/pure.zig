//! Pure helpers for the file manager: no GTK, so they are unit tested.

const std = @import("std");

/// "1.5 MB" style size using powers of 1000, like Nautilus.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "kB", "MB", "GB", "TB", "PB" };
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

pub const Crumb = struct {
    /// Text shown on the button.
    label: []const u8,
    /// Absolute path the button navigates to (a prefix of the input).
    path: []const u8,
};

/// Splits an absolute `path` into breadcrumb buttons: "/" then each
/// component. Slices point into `path`.
pub fn breadcrumbs(allocator: std.mem.Allocator, path: []const u8) ![]Crumb {
    var out: std.ArrayList(Crumb) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, .{ .label = "/", .path = path[0..@min(1, path.len)] });

    var end: usize = 0;
    while (end < path.len) {
        while (end < path.len and path[end] == '/') end += 1;
        if (end >= path.len) break;
        const start = end;
        while (end < path.len and path[end] != '/') end += 1;
        try out.append(allocator, .{ .label = path[start..end], .path = path[0..end] });
    }
    return out.toOwnedSlice(allocator);
}

pub const Mount = struct {
    mount_point: []u8,
    fs_type: []const u8,
};

/// Filesystems worth listing in the sidebar.
fn isRealFs(fs_type: []const u8) bool {
    const real = [_][]const u8{
        "ext2",    "ext3", "ext4",    "btrfs", "xfs", "f2fs", "vfat",     "exfat",   "ntfs", "ntfs3",
        "fuseblk", "9p",   "iso9660", "udf",   "zfs", "jfs",  "reiserfs", "hfsplus", "apfs",
    };
    for (real) |r| if (std.mem.eql(u8, r, fs_type)) return true;
    return false;
}

/// Decodes the octal escapes (`\040` for space) used in mountinfo paths.
fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 4 <= s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |byte| {
                try out.append(allocator, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(allocator, s[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// Parses `/proc/self/mountinfo` content into the mounts to show. The
/// filesystem type strings point into `content`; free mount points with
/// `freeMounts`.
pub fn parseMountinfo(allocator: std.mem.Allocator, content: []const u8) ![]Mount {
    var out: std.ArrayList(Mount) = .empty;
    errdefer freeMounts(allocator, out.items);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // "id parent maj:min root mountpoint opts [optional...] - fstype source superopts"
        const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
        var pre = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
        var skipped: usize = 0;
        while (skipped < 4) : (skipped += 1) _ = pre.next() orelse break;
        if (skipped < 4) continue;
        const raw_point = pre.next() orelse continue;

        var post = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        const fs_type = post.next() orelse continue;
        if (!isRealFs(fs_type)) continue;

        const point = try unescape(allocator, raw_point);
        errdefer allocator.free(point);
        // Skip /boot-style system mounts; keep root and user-facing places.
        if (!(std.mem.eql(u8, point, "/") or std.mem.startsWith(u8, point, "/media/") or
            std.mem.startsWith(u8, point, "/mnt/") or std.mem.startsWith(u8, point, "/run/media/")))
        {
            allocator.free(point);
            continue;
        }
        try out.append(allocator, .{ .mount_point = point, .fs_type = fs_type });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeMounts(allocator: std.mem.Allocator, mounts: []Mount) void {
    for (mounts) |m| allocator.free(m.mount_point);
    allocator.free(mounts);
}

/// The `Path=` value of a `.trashinfo` file, percent-decoded into a new
/// string, or null.
pub fn trashOriginalPath(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const prefix = "Path=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const encoded = std.mem.trim(u8, line[prefix.len..], " \r");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            if (encoded[i] == '%' and i + 3 <= encoded.len) {
                if (std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16)) |byte| {
                    try out.append(allocator, byte);
                    i += 2;
                    continue;
                } else |_| {}
            }
            try out.append(allocator, encoded[i]);
        }
        return try out.toOwnedSlice(allocator);
    }
    return null;
}

/// "name (copy 2).ext": a free name next to a conflicting `name.ext`.
pub fn copyName(allocator: std.mem.Allocator, name: []const u8, n: u32) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    if (dot) |d| if (d > 0) {
        return std.fmt.allocPrint(allocator, "{s} (copy {d}){s}", .{ name[0..d], n, name[d..] });
    };
    return std.fmt.allocPrint(allocator, "{s} (copy {d})", .{ name, n });
}

test "formatSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("999 bytes", formatSize(&buf, 999));
    try std.testing.expectEqualStrings("1.5 kB", formatSize(&buf, 1500));
    try std.testing.expectEqualStrings("2.0 MB", formatSize(&buf, 2_000_000));
}

test "breadcrumbs" {
    const a = std.testing.allocator;
    const crumbs = try breadcrumbs(a, "/home/user/docs");
    defer a.free(crumbs);
    try std.testing.expectEqual(@as(usize, 4), crumbs.len);
    try std.testing.expectEqualStrings("/", crumbs[0].label);
    try std.testing.expectEqualStrings("/home", crumbs[1].path);
    try std.testing.expectEqualStrings("docs", crumbs[3].label);
    try std.testing.expectEqualStrings("/home/user/docs", crumbs[3].path);

    const root = try breadcrumbs(a, "/");
    defer a.free(root);
    try std.testing.expectEqual(@as(usize, 1), root.len);
}

test "mountinfo keeps real, user-facing mounts" {
    const a = std.testing.allocator;
    const sample =
        \\22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
        \\23 22 0:5 / /proc rw - proc proc rw
        \\40 22 8:17 / /media/dakota/USB\040STICK rw - vfat /dev/sdb1 rw
        \\41 22 0:50 / /mnt/c rw - 9p C:\ rw
        \\42 22 0:51 / /run/user/1000 rw - tmpfs tmpfs rw
        \\43 22 8:2 / /boot rw - ext4 /dev/sda2 rw
    ;
    const mounts = try parseMountinfo(a, sample);
    defer freeMounts(a, mounts);
    try std.testing.expectEqual(@as(usize, 3), mounts.len);
    try std.testing.expectEqualStrings("/", mounts[0].mount_point);
    try std.testing.expectEqualStrings("/media/dakota/USB STICK", mounts[1].mount_point);
    try std.testing.expectEqualStrings("/mnt/c", mounts[2].mount_point);
}

test "trashinfo path is percent-decoded" {
    const a = std.testing.allocator;
    const info = "[Trash Info]\nPath=/home/u/My%20Docs/a.txt\nDeletionDate=2026-10-30T10:00:00\n";
    const path = (try trashOriginalPath(a, info)).?;
    defer a.free(path);
    try std.testing.expectEqualStrings("/home/u/My Docs/a.txt", path);
    try std.testing.expect((try trashOriginalPath(a, "[Trash Info]\n")) == null);
}

test "copyName keeps the extension" {
    const a = std.testing.allocator;
    const n1 = try copyName(a, "report.txt", 2);
    defer a.free(n1);
    try std.testing.expectEqualStrings("report (copy 2).txt", n1);
    const n2 = try copyName(a, "Makefile", 1);
    defer a.free(n2);
    try std.testing.expectEqualStrings("Makefile (copy 1)", n2);
    const n3 = try copyName(a, ".bashrc", 1);
    defer a.free(n3);
    try std.testing.expectEqualStrings(".bashrc (copy 1)", n3);
}
