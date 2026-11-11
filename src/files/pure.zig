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

/// "40 seconds left", "3 minutes left", "2 hours left": rounded up, so the
/// estimate does not reach zero before the work does.
pub fn formatTimeLeft(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) {
        const n = @max(seconds, 1);
        return std.fmt.bufPrint(buf, "{d} {s} left", .{ n, if (n == 1) "second" else "seconds" }) catch "";
    }
    if (seconds < 3600) {
        const n = (seconds + 59) / 60;
        return std.fmt.bufPrint(buf, "{d} {s} left", .{ n, if (n == 1) "minute" else "minutes" }) catch "";
    }
    const n = (seconds + 3599) / 3600;
    return std.fmt.bufPrint(buf, "{d} {s} left", .{ n, if (n == 1) "hour" else "hours" }) catch "";
}

test "formatTimeLeft" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1 second left", formatTimeLeft(&buf, 0));
    try std.testing.expectEqualStrings("40 seconds left", formatTimeLeft(&buf, 40));
    try std.testing.expectEqualStrings("1 minute left", formatTimeLeft(&buf, 60));
    try std.testing.expectEqualStrings("3 minutes left", formatTimeLeft(&buf, 121));
    try std.testing.expectEqualStrings("2 hours left", formatTimeLeft(&buf, 3601));
}

pub const Crumb = struct {
    /// Text shown on the button.
    label: []const u8,
    /// Absolute path the button navigates to (a prefix of the input).
    path: []const u8,
    /// The home folder, shown as "Home" with an icon.
    home: bool = false,
};

/// Like `breadcrumbs`, but a path inside `home` starts at a Home crumb, so
/// "/home/me/Documents" reads "Home / Documents", as in Nautilus.
pub fn breadcrumbsHome(allocator: std.mem.Allocator, path: []const u8, home: []const u8) ![]Crumb {
    const home_trimmed = std.mem.trimEnd(u8, home, "/");
    const inside = home_trimmed.len > 0 and std.mem.startsWith(u8, path, home_trimmed) and
        (path.len == home_trimmed.len or path[home_trimmed.len] == '/');
    if (!inside) return breadcrumbs(allocator, path);

    var out: std.ArrayList(Crumb) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, .{ .label = "Home", .path = path[0..home_trimmed.len], .home = true });
    var end = home_trimmed.len;
    while (end < path.len) {
        while (end < path.len and path[end] == '/') end += 1;
        if (end >= path.len) break;
        const start = end;
        while (end < path.len and path[end] != '/') end += 1;
        try out.append(allocator, .{ .label = path[start..end], .path = path[0..end] });
    }
    return out.toOwnedSlice(allocator);
}

test "breadcrumbsHome starts inside the home folder at Home" {
    const a = std.testing.allocator;
    const inside = try breadcrumbsHome(a, "/home/me/Documents/tax", "/home/me");
    defer a.free(inside);
    try std.testing.expectEqual(@as(usize, 3), inside.len);
    try std.testing.expect(inside[0].home);
    try std.testing.expectEqualStrings("/home/me", inside[0].path);
    try std.testing.expectEqualStrings("tax", inside[2].label);
    try std.testing.expectEqualStrings("/home/me/Documents/tax", inside[2].path);

    const at_home = try breadcrumbsHome(a, "/home/me", "/home/me/");
    defer a.free(at_home);
    try std.testing.expectEqual(@as(usize, 1), at_home.len);

    // A sibling whose name starts like home is not inside it.
    const other = try breadcrumbsHome(a, "/home/meg/x", "/home/me");
    defer a.free(other);
    try std.testing.expectEqualStrings("/", other[0].label);
    try std.testing.expect(!other[0].home);
}

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

/// Turns what was typed into a server address, or null when it is not one.
/// Accepts the gvfs schemes and the usual aliases, with or without the
/// slashes: `ftp:host`, `samba://nas/share`, `ssh:me@host` become
/// `ftp://host`, `smb://nas/share`, `sftp://me@host`. The caller frees it.
pub fn normalizeRemote(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const typed = std.mem.trim(u8, text, " \t");
    const colon = std.mem.indexOfScalar(u8, typed, ':') orelse return null;
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "sftp", "sftp" }, .{ "ssh", "sftp" },  .{ "ftp", "ftp" },
        .{ "ftps", "ftps" }, .{ "smb", "smb" },   .{ "samba", "smb" },
        .{ "cifs", "smb" },
    };
    for (aliases) |alias| {
        if (!std.ascii.eqlIgnoreCase(typed[0..colon], alias[0])) continue;
        const rest = std.mem.trimStart(u8, typed[colon + 1 ..], "/");
        return try std.fmt.allocPrint(allocator, "{s}://{s}", .{ alias[1], rest });
    }
    return null;
}

/// The scheme of an address made by `normalizeRemote`.
pub fn schemeOf(uri: []const u8) []const u8 {
    return uri[0 .. std.mem.indexOf(u8, uri, "://") orelse uri.len];
}

test "normalizeRemote" {
    const a = std.testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "ftp:", "ftp://" },
        .{ "ftp:host", "ftp://host" },
        .{ "Samba://nas/share", "smb://nas/share" },
        .{ "ssh:me@host/home", "sftp://me@host/home" },
        .{ "  smb:/nas ", "smb://nas" },
        .{ "/home/me", null },
        .{ "ftpx:host", null },
        .{ "file:///tmp", null },
    };
    for (cases) |c| {
        const got = try normalizeRemote(a, c[0]);
        defer if (got) |g| a.free(g);
        if (c[1]) |want| try std.testing.expectEqualStrings(want, got.?) else try std.testing.expect(got == null);
    }
}

/// Invisible characters that reorder text: a name like "photo\u{202E}gpj.exe"
/// would display as "photoexe.jpg". Each is shown by name instead.
const bidi_controls = [_]struct { u21, []const u8 }{
    .{ 0x061C, "ALM" }, .{ 0x200E, "LRM" }, .{ 0x200F, "RLM" },
    .{ 0x202A, "LRE" }, .{ 0x202B, "RLE" }, .{ 0x202C, "PDF" },
    .{ 0x202D, "LRO" }, .{ 0x202E, "RLO" }, .{ 0x2066, "LRI" },
    .{ 0x2067, "RLI" }, .{ 0x2068, "FSI" }, .{ 0x2069, "PDI" },
};

fn bidiName(cp: u21) ?[]const u8 {
    for (bidi_controls) |c| if (c[0] == cp) return c[1];
    return null;
}

/// `name` with every text-direction control written as "[RLO]" and so on,
/// or null when it has none (the usual case: show it as it is). Invalid
/// UTF-8 is left for GTK to mark. The caller frees the result.
pub fn revealBidi(allocator: std.mem.Allocator, name: []const u8) !?[:0]u8 {
    var found = false;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        const end = @min(i + len, name.len);
        const cp = std.unicode.utf8Decode(name[i..end]) catch null;
        if (cp) |c| if (bidiName(c)) |label| {
            found = true;
            try out.print(allocator, "[{s}]", .{label});
            i = end;
            continue;
        };
        try out.appendSlice(allocator, name[i..end]);
        i = end;
    }
    if (!found) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSliceSentinel(allocator, 0);
}

test "revealBidi names the hidden direction controls" {
    const a = std.testing.allocator;
    const spoof = try revealBidi(a, "rtl_\u{202E}gnp.exe");
    defer if (spoof) |x| a.free(x);
    try std.testing.expectEqualStrings("rtl_[RLO]gnp.exe", spoof.?);
    const two = try revealBidi(a, "\u{2067}a\u{2069}");
    defer if (two) |x| a.free(x);
    try std.testing.expectEqualStrings("[RLI]a[PDI]", two.?);
    try std.testing.expect(try revealBidi(a, "plain_日本語_🎉.txt") == null);
    try std.testing.expect(try revealBidi(a, "bad_\xff\xfe") == null);
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
