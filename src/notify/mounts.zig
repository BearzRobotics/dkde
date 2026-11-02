//! Looking up what a drive is called and where it is mounted, for
//! `dkde-notify --mounted DEVICE`. A hook hands over only the device node (which
//! the kernel names); the label, which whoever made the stick chose, is read
//! here and only ever shown, never put in a command. Pure functions over file
//! contents and directory entries, so they are unit tested.

const std = @import("std");

/// `\040` (and the other octal escapes) in /proc/self/mounts fields, decoded
/// into `out`.
pub fn unescapeMount(field: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < field.len and n < out.len) : (i += 1) {
        if (field[i] == '\\' and i + 3 < field.len and isOctal(field[i + 1]) and isOctal(field[i + 2]) and isOctal(field[i + 3])) {
            out[n] = (field[i + 1] - '0') * 64 + (field[i + 2] - '0') * 8 + (field[i + 3] - '0');
            n += 1;
            i += 3;
        } else {
            out[n] = field[i];
            n += 1;
        }
    }
    return out[0..n];
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// The mount point of `device` (for example `/dev/sdd1`), decoded into `out`.
pub fn findMountPoint(mounts: []const u8, device: []const u8, out: []u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const dev = f.next() orelse continue;
        const point = f.next() orelse continue;
        var dbuf: [256]u8 = undefined;
        if (!std.mem.eql(u8, unescapeMount(dev, &dbuf), device)) continue;
        return unescapeMount(point, out);
    }
    return null;
}

/// udev writes a label into a file name with `\xNN` for anything unusual (a
/// space is `\x20`). Decoded into `out`.
pub fn decodeUdevName(name: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < name.len and n < out.len) : (i += 1) {
        if (name[i] == '\\' and i + 3 < name.len and name[i + 1] == 'x') {
            const hi = std.fmt.charToDigit(name[i + 2], 16) catch {
                out[n] = name[i];
                n += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(name[i + 3], 16) catch {
                out[n] = name[i];
                n += 1;
                continue;
            };
            out[n] = hi * 16 + lo;
            n += 1;
            i += 3;
        } else {
            out[n] = name[i];
            n += 1;
        }
    }
    return out[0..n];
}

/// Text from a stranger, made safe to show: control characters (a newline, an
/// escape) become spaces and the length is capped. Markup is not a concern here:
/// the notification server shows text as text.
pub fn sanitize(text: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (n >= out.len) break;
        out[n] = if (c < 0x20 or c == 0x7f) ' ' else c;
        n += 1;
    }
    return std.mem.trim(u8, out[0..n], " ");
}

pub const LabelEntry = struct {
    /// The file name in /dev/disk/by-label.
    name: []const u8,
    /// What the symlink points to, such as `../../sdd1`.
    target: []const u8,
};

/// The label of the device named `device_base` (`sdd1`), from the by-label entries.
pub fn findLabel(entries: []const LabelEntry, device_base: []const u8, out: []u8) ?[]const u8 {
    for (entries) |e| {
        const base = if (std.mem.lastIndexOfScalar(u8, e.target, '/')) |i| e.target[i + 1 ..] else e.target;
        if (std.mem.eql(u8, base, device_base)) return decodeUdevName(e.name, out);
    }
    return null;
}

/// A device argument is a node under /dev and nothing else.
pub fn validDevice(device: []const u8) bool {
    if (!std.mem.startsWith(u8, device, "/dev/") or device.len <= "/dev/".len or device.len > 64) return false;
    for (device) |c| {
        if (c < 0x21 or c == 0x7f) return false;
    }
    return std.mem.indexOf(u8, device, "..") == null;
}

pub fn baseName(device: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, device, '/')) |i| device[i + 1 ..] else device;
}

test "mount point lookup decodes escapes" {
    const mounts = "/dev/sda1 / ext4 rw 0 0\n/dev/sdd1 /media/dakota/My\\040Stick vfat rw 0 0\n";
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/media/dakota/My Stick", findMountPoint(mounts, "/dev/sdd1", &b).?);
    try std.testing.expectEqualStrings("/", findMountPoint(mounts, "/dev/sda1", &b).?);
    try std.testing.expect(findMountPoint(mounts, "/dev/sde1", &b) == null);
}

test "an escape at the very end of a field" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a ", unescapeMount("a\\040", &b));
    try std.testing.expectEqualStrings("a/", decodeUdevName("a\\x2f", &b));
}

test "udev label names" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("My Stick", decodeUdevName("My\\x20Stick", &b));
    try std.testing.expectEqualStrings("A/B", decodeUdevName("A\\x2fB", &b));
    // A broken escape is left as it is.
    try std.testing.expectEqualStrings("a\\xZZ", decodeUdevName("a\\xZZ", &b));
    try std.testing.expectEqualStrings("end\\x2", decodeUdevName("end\\x2", &b));
}

test "label for a device" {
    const entries = [_]LabelEntry{
        .{ .name = "ROOT", .target = "../../sda1" },
        .{ .name = "PHOTOS\\x20&\\x20VIDEO", .target = "../../sdd1" },
    };
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("PHOTOS & VIDEO", findLabel(&entries, "sdd1", &b).?);
    try std.testing.expect(findLabel(&entries, "sdc1", &b) == null);
}

test "text from a stranger is made safe to show" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a b c", sanitize("a\nb\x1bc", &b));
    try std.testing.expectEqualStrings("12345678", sanitize("123456789", b[0..8]));
    try std.testing.expectEqualStrings("x", sanitize("  x \t", &b));
}

test "device arguments" {
    try std.testing.expect(validDevice("/dev/sdd1"));
    try std.testing.expect(validDevice("/dev/mmcblk0p1"));
    try std.testing.expect(!validDevice("sdd1"));
    try std.testing.expect(!validDevice("/dev/"));
    try std.testing.expect(!validDevice("/dev/sd d"));
    try std.testing.expect(!validDevice("/dev/../etc/passwd"));
    try std.testing.expect(!validDevice("/dev/sdd1;rm"[0..9] ++ "\n"));
}
