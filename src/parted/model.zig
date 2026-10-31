//! The partition tool's data and rules (SPEC.md 5.6): reading `lsblk`, finding
//! free space, deciding what may be touched, and building the commands. No
//! GTK here, so all of it is tested.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const mib: u64 = 1 << 20;

pub const Part = struct {
    path: []const u8,
    /// 1 for sda1, 2 for nvme0n1p2.
    number: u32,
    /// In sectors of the disk.
    start: u64,
    size: u64,
    fstype: []const u8,
    label: []const u8,
    mounts: []const []const u8,
};

pub const Disk = struct {
    path: []const u8,
    name: []const u8,
    model: []const u8,
    size: u64,
    sector: u32,
    /// `gpt`, `dos` or empty.
    table: []const u8,
    removable: bool,
    readonly: bool,
    parts: []const Part,
    /// A filesystem written straight onto the disk, with no table.
    fstype: []const u8 = "",
    mounts: []const []const u8 = &.{},
};

pub const Gap = struct {
    /// First and one past the last usable sector, aligned to 1 MiB.
    start: u64,
    end: u64,

    pub fn bytes(self: Gap, sector: u32) u64 {
        return (self.end - self.start) * sector;
    }
};

fn str(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        else => "",
    };
}

fn num(v: ?std.json.Value) u64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn flag(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true"),
        else => false,
    };
}

fn trailingNumber(name: []const u8) u32 {
    var i = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) i -= 1;
    return std.fmt.parseInt(u32, name[i..], 10) catch 0;
}

fn mountsOf(arena: Allocator, obj: std.json.ObjectMap) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (obj.get("mountpoints")) |m| {
        if (m == .array) for (m.array.items) |item| {
            if (item == .string) try out.append(arena, try arena.dupe(u8, item.string));
        };
    } else if (obj.get("mountpoint")) |m| {
        if (m == .string) try out.append(arena, try arena.dupe(u8, m.string));
    }
    return out.items;
}

/// Parses the output of
/// `lsblk -J -b -o NAME,PATH,TYPE,SIZE,START,FSTYPE,LABEL,MOUNTPOINTS,PTTYPE,MODEL,RM,RO,LOG-SEC`.
/// Everything is allocated from `arena`.
pub fn parseLsblk(arena: Allocator, text: []const u8) !([]const Disk) {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const root = switch (parsed) {
        .object => |o| o,
        else => return error.BadLsblk,
    };
    const devices = (root.get("blockdevices") orelse return error.BadLsblk);
    if (devices != .array) return error.BadLsblk;

    var disks: std.ArrayList(Disk) = .empty;
    for (devices.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        if (!std.mem.eql(u8, str(o.get("type")), "disk")) continue;
        const sector: u32 = @intCast(@max(num(o.get("log-sec")), 512));
        var parts: std.ArrayList(Part) = .empty;
        if (o.get("children")) |kids| if (kids == .array) {
            for (kids.array.items) |k| {
                if (k != .object) continue;
                const ko = k.object;
                if (!std.mem.eql(u8, str(ko.get("type")), "part")) continue;
                const name = str(ko.get("name"));
                try parts.append(arena, .{
                    .path = try arena.dupe(u8, str(ko.get("path"))),
                    .number = trailingNumber(name),
                    .start = num(ko.get("start")),
                    .size = num(ko.get("size")),
                    .fstype = try arena.dupe(u8, str(ko.get("fstype"))),
                    .label = try arena.dupe(u8, str(ko.get("label"))),
                    .mounts = try mountsOf(arena, ko),
                });
            }
        };
        std.mem.sort(Part, parts.items, {}, struct {
            fn less(_: void, a: Part, b: Part) bool {
                return a.start < b.start;
            }
        }.less);
        try disks.append(arena, .{
            .path = try arena.dupe(u8, str(o.get("path"))),
            .name = try arena.dupe(u8, str(o.get("name"))),
            .model = try arena.dupe(u8, std.mem.trim(u8, str(o.get("model")), " ")),
            .size = num(o.get("size")),
            .sector = sector,
            .table = try arena.dupe(u8, str(o.get("pttype"))),
            .removable = flag(o.get("rm")),
            .readonly = flag(o.get("ro")),
            .parts = parts.items,
            .fstype = try arena.dupe(u8, str(o.get("fstype"))),
            .mounts = try mountsOf(arena, o),
        });
    }
    return disks.items;
}

pub fn anyMounted(d: Disk) bool {
    if (d.mounts.len > 0) return true;
    for (d.parts) |p| if (p.mounts.len > 0) return true;
    return false;
}

/// The disk that holds the running system: something it needs is mounted
/// from it, or it carries active swap.
pub fn isSystemDisk(d: Disk) bool {
    const system = [_][]const u8{ "/", "/boot", "/boot/efi", "/usr", "/var", "/home", "[SWAP]" };
    for (d.mounts) |m| for (system) |s| if (std.mem.eql(u8, m, s)) return true;
    for (d.parts) |p| for (p.mounts) |m| {
        for (system) |s| if (std.mem.eql(u8, m, s)) return true;
    };
    return false;
}

/// Why `d` must not be changed, or null.
pub fn refuseReason(d: Disk) ?[]const u8 {
    if (d.readonly) return "This disk is read-only.";
    if (isSystemDisk(d)) return "This disk holds your running system, so it cannot be changed here.";
    if (anyMounted(d)) return "A partition of this disk is mounted. Unmount it first.";
    return null;
}

/// Free stretches of at least 1 MiB, aligned to 1 MiB, in sector order.
pub fn freeSpace(arena: Allocator, d: Disk) Allocator.Error![]const Gap {
    // A filesystem on the bare disk leaves nothing to partition.
    if (d.table.len == 0 and d.fstype.len > 0) return &.{};
    const per_mib = mib / d.sector;
    const total = d.size / d.sector;
    var out: std.ArrayList(Gap) = .empty;
    var cursor: u64 = per_mib; // the first MiB is for the table
    for (d.parts) |p| {
        if (p.start > cursor) try addGap(arena, &out, cursor, p.start, per_mib);
        cursor = @max(cursor, p.start + p.size / d.sector);
    }
    // The last 1 MiB is left for the backup table.
    if (total > cursor + per_mib) try addGap(arena, &out, cursor, total - per_mib, per_mib);
    return out.items;
}

fn addGap(arena: Allocator, out: *std.ArrayList(Gap), from: u64, to: u64, per_mib: u64) Allocator.Error!void {
    const start = std.mem.alignForward(u64, from, per_mib);
    const end = std.mem.alignBackward(u64, to, per_mib);
    if (end > start) try out.append(arena, .{ .start = start, .end = end });
}

// -- commands -----------------------------------------------------------------------------

pub const FsKind = enum { ext4, btrfs, xfs, vfat, exfat, ntfs, swap };

pub fn fsTool(k: FsKind) [:0]const u8 {
    return switch (k) {
        .ext4 => "mkfs.ext4",
        .btrfs => "mkfs.btrfs",
        .xfs => "mkfs.xfs",
        .vfat => "mkfs.vfat",
        .exfat => "mkfs.exfat",
        .ntfs => "mkfs.ntfs",
        .swap => "mkswap",
    };
}

pub fn fsName(k: FsKind) [:0]const u8 {
    return switch (k) {
        .ext4 => "ext4",
        .btrfs => "btrfs",
        .xfs => "xfs",
        .vfat => "FAT32",
        .exfat => "exFAT",
        .ntfs => "NTFS",
        .swap => "swap",
    };
}

pub fn newTable(arena: Allocator, dev: []const u8, kind: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "mklabel", kind });
}

/// `start_mib` and `end_mib` are where it begins and ends on the disk.
pub fn newPartition(arena: Allocator, dev: []const u8, start_mib: u64, end_mib: u64) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "parted",                                              "-s",                                                "-a", "optimal", dev, "mkpart", "primary",
        try std.fmt.allocPrint(arena, "{d}MiB", .{start_mib}), try std.fmt.allocPrint(arena, "{d}MiB", .{end_mib}),
    });
}

pub fn deletePartition(arena: Allocator, dev: []const u8, number: u32) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "rm", try std.fmt.allocPrint(arena, "{d}", .{number}) });
}

pub fn format(arena: Allocator, kind: FsKind, label: []const u8, path: []const u8) Allocator.Error![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.append(arena, fsTool(kind));
    switch (kind) {
        .ext4 => try a.appendSlice(arena, &.{ "-q", "-F" }),
        .btrfs, .xfs => try a.append(arena, "-f"),
        .swap => try a.append(arena, "-f"),
        .ntfs => try a.append(arena, "-Q"),
        else => {},
    }
    if (label.len > 0) {
        try a.append(arena, switch (kind) {
            .vfat => "-n",
            else => "-L",
        });
        try a.append(arena, label);
    }
    try a.append(arena, path);
    return a.items;
}

pub fn unmount(arena: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "umount", path });
}

pub fn mount(arena: Allocator, path: []const u8, dir: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "sh", "-c", "mkdir -p \"$2\" && mount \"$1\" \"$2\"", "sh", path, dir });
}

/// A read-only check, whichever tool fits the filesystem.
pub fn check(arena: Allocator, fstype: []const u8, path: []const u8) Allocator.Error![]const []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, fstype, "btrfs")) return arena.dupe([]const u8, &.{ "btrfs", "check", "--readonly", path });
    if (eql(u8, fstype, "xfs")) return arena.dupe([]const u8, &.{ "xfs_repair", "-n", path });
    if (eql(u8, fstype, "vfat")) return arena.dupe([]const u8, &.{ "fsck.vfat", "-n", path });
    if (eql(u8, fstype, "exfat")) return arena.dupe([]const u8, &.{ "fsck.exfat", "-n", path });
    if (eql(u8, fstype, "ntfs")) return arena.dupe([]const u8, &.{ "ntfsfix", "-n", path });
    return arena.dupe([]const u8, &.{ "e2fsck", "-n", path });
}

// -- tests --------------------------------------------------------------------------------

const sample =
    \\{"blockdevices":[
    \\ {"name":"sda","path":"/dev/sda","type":"disk","size":1000000000000,"start":null,"fstype":null,"label":null,"mountpoints":[null],"pttype":"gpt","model":"Samsung SSD  ","rm":false,"ro":false,"log-sec":512,
    \\  "children":[
    \\   {"name":"sda2","path":"/dev/sda2","type":"part","size":500000000000,"start":3000000,"fstype":"ext4","label":"data","mountpoints":["/mnt/data"],"pttype":"gpt"},
    \\   {"name":"sda1","path":"/dev/sda1","type":"part","size":104857600,"start":2048,"fstype":"vfat","label":"EFI","mountpoints":[null]}
    \\  ]},
    \\ {"name":"sdb","path":"/dev/sdb","type":"disk","size":"16000000000","fstype":null,"mountpoints":[null],"pttype":null,"model":"USB","rm":"1","ro":"0","log-sec":512},
    \\ {"name":"sr0","path":"/dev/sr0","type":"rom","size":1}
    \\]}
;

test "lsblk output becomes disks and sorted partitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disks = try parseLsblk(arena.allocator(), sample);
    try std.testing.expectEqual(@as(usize, 2), disks.len);
    try std.testing.expectEqualStrings("Samsung SSD", disks[0].model);
    try std.testing.expectEqual(@as(usize, 2), disks[0].parts.len);
    try std.testing.expectEqualStrings("/dev/sda1", disks[0].parts[0].path);
    try std.testing.expectEqual(@as(u32, 1), disks[0].parts[0].number);
    try std.testing.expectEqualStrings("/mnt/data", disks[0].parts[1].mounts[0]);
    try std.testing.expect(disks[1].removable);
    try std.testing.expectEqual(@as(u64, 16000000000), disks[1].size);
}

test "free space is aligned and leaves room for the tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disks = try parseLsblk(arena.allocator(), sample);
    const gaps = try freeSpace(arena.allocator(), disks[0]);
    // After sda1 (ends 2048+204800) and before sda2, then after sda2.
    try std.testing.expect(gaps.len >= 1);
    for (gaps) |g| {
        try std.testing.expectEqual(@as(u64, 0), g.start % 2048);
        try std.testing.expectEqual(@as(u64, 0), g.end % 2048);
        try std.testing.expect(g.end > g.start);
    }
    const empty = try freeSpace(arena.allocator(), disks[1]);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqual(@as(u64, 2048), empty[0].start);
}

test "mounted and system disks are protected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const disks = try parseLsblk(arena.allocator(), sample);
    try std.testing.expect(anyMounted(disks[0]));
    try std.testing.expect(!isSystemDisk(disks[0]));
    try std.testing.expect(refuseReason(disks[0]) != null);
    try std.testing.expect(refuseReason(disks[1]) == null);
    const root_disk: Disk = .{ .path = "/dev/x", .name = "x", .model = "", .size = 1, .sector = 512, .table = "gpt", .removable = false, .readonly = false, .parts = &.{.{ .path = "/dev/x1", .number = 1, .start = 2048, .size = 1, .fstype = "ext4", .label = "", .mounts = &.{"/"} }} };
    try std.testing.expect(isSystemDisk(root_disk));
}

test "a filesystem on the bare disk is not free space, and its mount counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{"blockdevices":[{"name":"sdb","path":"/dev/sdb","type":"disk","size":104857600,"fstype":"ext4","mountpoints":["/usr"],"pttype":null,"model":"V","rm":false,"ro":false,"log-sec":512}]}
    ;
    const disks = try parseLsblk(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 0), (try freeSpace(arena.allocator(), disks[0])).len);
    try std.testing.expect(isSystemDisk(disks[0]));
}

test "commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const np = try newPartition(a, "/dev/sdb", 1, 1025);
    try std.testing.expectEqualStrings("1025MiB", np[np.len - 1]);
    const f = try format(a, .ext4, "data", "/dev/sdb1");
    try std.testing.expectEqualStrings("mkfs.ext4", f[0]);
    try std.testing.expectEqualStrings("-L", f[3]);
    const v = try format(a, .vfat, "BOOT", "/dev/sdb1");
    try std.testing.expectEqualStrings("-n", v[1]);
    const nolabel = try format(a, .xfs, "", "/dev/sdb1");
    try std.testing.expectEqual(@as(usize, 3), nolabel.len);
    const d = try deletePartition(a, "/dev/sdb", 3);
    try std.testing.expectEqualStrings("3", d[d.len - 1]);
}
