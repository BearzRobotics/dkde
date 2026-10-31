//! Helpers for the disk usage tool. Pure.

const std = @import("std");

/// "1.5 GB", "320 kB" (powers of 1000, like the file manager).
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    const r = if (unit == 0)
        std.fmt.bufPrint(buf, "{d} B", .{bytes})
    else
        std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] });
    return r catch "";
}

/// Mount points worth showing: real filesystems, not the kernel's pseudo ones.
pub fn isInteresting(fstype: []const u8, mount_point: []const u8) bool {
    const skip = [_][]const u8{
        "proc",        "sysfs",   "devtmpfs", "devpts",   "cgroup",  "cgroup2",  "securityfs", "debugfs",
        "tracefs",     "pstore",  "bpf",      "configfs", "fusectl", "mqueue",   "hugetlbfs",  "autofs",
        "binfmt_misc", "overlay", "squashfs", "nsfs",     "ramfs",   "efivarfs", "rpc_pipefs",
    };
    for (skip) |s| if (std.mem.eql(u8, fstype, s)) return false;
    if (std.mem.startsWith(u8, mount_point, "/proc") or std.mem.startsWith(u8, mount_point, "/sys")) return false;
    if (std.mem.startsWith(u8, mount_point, "/run/user") or std.mem.startsWith(u8, mount_point, "/dev")) return false;
    return true;
}

pub const Mount = struct { device: []const u8, point: []const u8, fstype: []const u8 };

/// One line of /proc/self/mounts: "device mountpoint type options 0 0". Octal
/// escapes (a space is \040) are left as they are.
pub fn parseMountLine(line: []const u8) ?Mount {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const device = it.next() orelse return null;
    const point = it.next() orelse return null;
    const fstype = it.next() orelse return null;
    return .{ .device = device, .point = point, .fstype = fstype };
}

test "sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("1.5 kB", formatSize(&buf, 1500));
    try std.testing.expectEqualStrings("2.0 GB", formatSize(&buf, 2_000_000_000));
}

test "mount lines" {
    const m = parseMountLine("/dev/sda1 / ext4 rw,relatime 0 0").?;
    try std.testing.expectEqualStrings("/", m.point);
    try std.testing.expectEqualStrings("ext4", m.fstype);
    try std.testing.expect(parseMountLine("") == null);
    try std.testing.expect(isInteresting("ext4", "/"));
    try std.testing.expect(!isInteresting("proc", "/proc"));
    try std.testing.expect(!isInteresting("tmpfs", "/run/user/1000"));
    try std.testing.expect(isInteresting("tmpfs", "/tmp"));
}
