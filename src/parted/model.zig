// SPDX-License-Identifier: GPL-2.0-or-later
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
    /// Bytes used and free inside the filesystem, when lsblk knows them (mounted).
    used: ?u64 = null,
    avail: ?u64 = null,
    /// Partition flags as parted names them (images only).
    flags: []const u8 = "",
    /// Something else is using it: encryption, LVM, RAID or a pool built on it.
    /// `mounts` then includes what is mounted from what is stacked on it.
    held: bool = false,
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
    /// A disk image file rather than a device. Its partitions have no device
    /// path of their own; they are reached through a loop device when needed.
    image: bool = false,
    /// As `Part.held`, for something built straight on the disk.
    held: bool = false,
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

fn optNum(v: ?std.json.Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .null => null,
        else => num(x),
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

/// The block devices lsblk lists under `obj`.
fn childrenOf(obj: std.json.ObjectMap) []const std.json.Value {
    const kids = obj.get("children") orelse return &.{};
    return if (kids == .array) kids.array.items else &.{};
}

/// Adds the mount points of everything stacked on `obj` (`/` on an encrypted or
/// LVM system is only reported there), however deep, to `out`.
fn stackedMounts(arena: Allocator, obj: std.json.ObjectMap, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    for (childrenOf(obj)) |k| {
        if (k != .object) continue;
        try out.appendSlice(arena, try mountsOf(arena, k.object));
        try stackedMounts(arena, k.object, out);
    }
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
        var disk_mounts: std.ArrayList([]const u8) = .empty;
        try disk_mounts.appendSlice(arena, try mountsOf(arena, o));
        var disk_held = false;
        {
            for (childrenOf(o)) |k| {
                if (k != .object) continue;
                const ko = k.object;
                if (!std.mem.eql(u8, str(ko.get("type")), "part")) {
                    // Built on the whole disk.
                    disk_held = true;
                    try disk_mounts.appendSlice(arena, try mountsOf(arena, ko));
                    try stackedMounts(arena, ko, &disk_mounts);
                    continue;
                }
                const name = str(ko.get("name"));
                var mounts: std.ArrayList([]const u8) = .empty;
                try mounts.appendSlice(arena, try mountsOf(arena, ko));
                try stackedMounts(arena, ko, &mounts);
                try parts.append(arena, .{
                    .path = try arena.dupe(u8, str(ko.get("path"))),
                    .number = trailingNumber(name),
                    .start = num(ko.get("start")),
                    .size = num(ko.get("size")),
                    .fstype = try arena.dupe(u8, str(ko.get("fstype"))),
                    .label = try arena.dupe(u8, str(ko.get("label"))),
                    .mounts = mounts.items,
                    .held = childrenOf(ko).len > 0,
                    .used = optNum(ko.get("fsused")),
                    .avail = optNum(ko.get("fsavail")),
                });
            }
        }
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
            .mounts = disk_mounts.items,
            .held = disk_held,
        });
    }
    return disks.items;
}

/// What `parted -m -s IMG unit B print` says: `BYT;`, the disk line, then one
/// line per partition. `fallback_size` is used when parted could not read a table.
pub fn parsePartedMachine(arena: Allocator, path: []const u8, text: []const u8, fallback_size: u64) Allocator.Error!Disk {
    var d: Disk = .{
        .path = try arena.dupe(u8, path),
        .name = try arena.dupe(u8, std.fs.path.basename(path)),
        .model = "disk image",
        .size = fallback_size,
        .sector = 512,
        .table = "",
        .removable = false,
        .readonly = false,
        .parts = &.{},
        .image = true,
    };
    var parts: std.ArrayList(Part) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, ";");
        if (std.mem.eql(u8, line, "BYT")) continue;
        var f = std.mem.splitScalar(u8, line, ':');
        const first = f.next() orelse continue;
        if (first.len > 0 and first[0] == '/') {
            // /path:sizeB:file:logical:physical:table:model
            const size_b = f.next() orelse "";
            _ = f.next();
            const log = f.next() orelse "512";
            _ = f.next();
            const table = f.next() orelse "";
            d.size = std.fmt.parseInt(u64, std.mem.trimEnd(u8, size_b, "B"), 10) catch fallback_size;
            d.sector = std.fmt.parseInt(u32, log, 10) catch 512;
            d.table = try arena.dupe(u8, if (std.mem.eql(u8, table, "unknown")) "" else table);
            continue;
        }
        const number = std.fmt.parseInt(u32, first, 10) catch continue;
        const start_b = std.fmt.parseInt(u64, std.mem.trimEnd(u8, f.next() orelse "", "B"), 10) catch continue;
        _ = f.next();
        const size_b = std.fmt.parseInt(u64, std.mem.trimEnd(u8, f.next() orelse "", "B"), 10) catch continue;
        const fs = f.next() orelse "";
        _ = f.next(); // the partition name
        const part_flags = std.mem.trim(u8, f.next() orelse "", " ");
        try parts.append(arena, .{
            .flags = try arena.dupe(u8, part_flags),
            .path = try std.fmt.allocPrint(arena, "{s}#{d}", .{ path, number }),
            .number = number,
            .start = start_b / d.sector,
            .size = size_b,
            .fstype = try arena.dupe(u8, partedFs(fs)),
            // The GPT partition name is not the filesystem label.
            .label = "",
            .mounts = &.{},
        });
    }
    d.parts = parts.items;
    return d;
}

/// parted's names for filesystems, as lsblk would say them.
fn partedFs(fs: []const u8) []const u8 {
    if (std.mem.startsWith(u8, fs, "fat")) return "vfat";
    if (std.mem.startsWith(u8, fs, "linux-swap")) return "swap";
    return fs;
}

/// Marks what a pool is using although lsblk shows nothing on top of it: a
/// member of a mounted btrfs volume that was mounted through another member, or
/// of an imported ZFS pool. `exists` says whether a path exists (the kernel's
/// own lists under `sys` and `proc`).
pub fn markPooled(arena: Allocator, disks: []const Disk, btrfs_ids: []const []const u8, exists: *const fn ([]const u8) bool) Allocator.Error![]const Disk {
    const out = try arena.dupe(Disk, disks);
    for (out) |*d| {
        if (try pooled(arena, d.path, d.fstype, "", btrfs_ids, exists)) d.held = true;
        const parts = try arena.dupe(Part, d.parts);
        for (parts) |*p| {
            if (try pooled(arena, p.path, p.fstype, p.label, btrfs_ids, exists)) p.held = true;
        }
        d.parts = parts;
    }
    return out;
}

fn pooled(arena: Allocator, path: []const u8, fstype: []const u8, label: []const u8, btrfs_ids: []const []const u8, exists: *const fn ([]const u8) bool) Allocator.Error!bool {
    if (std.mem.eql(u8, fstype, "btrfs")) {
        for (btrfs_ids) |id| {
            if (exists(try std.fmt.allocPrint(arena, "/sys/fs/btrfs/{s}/devices/{s}", .{ id, std.fs.path.basename(path) }))) return true;
        }
    }
    // lsblk reports the pool's name as a member's label.
    if (std.mem.eql(u8, fstype, "zfs_member") and label.len > 0) {
        return exists(try std.fmt.allocPrint(arena, "/proc/spl/kstat/zfs/{s}", .{label}));
    }
    return false;
}

pub fn anyHeld(d: Disk) bool {
    if (d.held) return true;
    for (d.parts) |p| if (p.held) return true;
    return false;
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
    if (anyHeld(d)) return "This disk is in use by encryption, LVM, RAID or a storage pool. Close that first.";
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

// -- tests --------------------------------------------------------------------------------

/// The programs the partition tool drives, what each is for, and the package
/// to install. dkde-parted links no partitioning library.
const core_tools = [_]struct { cmd: [:0]const u8, why: []const u8, package: []const u8 }{
    .{ .cmd = "parted", .why = "changing partitions", .package = "parted" },
    .{ .cmd = "lsblk", .why = "listing disks", .package = "util-linux" },
    .{ .cmd = "losetup", .why = "disk image files", .package = "util-linux" },
    .{ .cmd = "sudo", .why = "applying changes", .package = "sudo" },
};

/// A message naming the programs that are not installed and the packages that
/// provide them, or null when all are present. `have` says whether a command exists.
pub fn missingCoreTools(have: *const fn ([:0]const u8) bool, buf: []u8) ?[]const u8 {
    var len: usize = 0;
    var packages: [core_tools.len][]const u8 = undefined;
    var n_packages: usize = 0;
    var any = false;
    const head = "Not installed: ";
    @memcpy(buf[0..head.len], head);
    len = head.len;
    for (core_tools) |t| {
        if (have(t.cmd)) continue;
        const part = std.fmt.bufPrint(buf[len..], "{s}{s} ({s})", .{ if (any) ", " else "", t.cmd, t.why }) catch break;
        len += part.len;
        any = true;
        var seen = false;
        for (packages[0..n_packages]) |p| if (std.mem.eql(u8, p, t.package)) {
            seen = true;
        };
        if (!seen) {
            packages[n_packages] = t.package;
            n_packages += 1;
        }
    }
    if (!any) return null;
    const tail = std.fmt.bufPrint(buf[len..], ". Install: ", .{}) catch return buf[0..len];
    len += tail.len;
    for (packages[0..n_packages], 0..) |p, i| {
        const part = std.fmt.bufPrint(buf[len..], "{s}{s}", .{ if (i > 0) ", " else "", p }) catch break;
        len += part.len;
    }
    return buf[0..len];
}

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

test "mounts on encryption, LVM and RAID count for the disk under them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "{\"blockdevices\":[{\"name\":\"sda\",\"path\":\"/dev/sda\",\"type\":\"disk\",\"size\":1000000,\"pttype\":\"gpt\",\"children\":[{\"name\":\"sda1\",\"path\":\"/dev/sda1\",\"type\":\"part\",\"size\":900000,\"start\":2048,\"fstype\":\"crypto_LUKS\",\"mountpoints\":[null],\"children\":[";
    const tail = "]}]}]}";
    // LUKS, LVM inside LUKS, and md RAID, each with the root filesystem on top.
    for ([_][]const u8{
        "{\"type\":\"crypt\",\"mountpoints\":[\"/\"]}",
        "{\"type\":\"crypt\",\"mountpoints\":[null],\"children\":[{\"type\":\"lvm\",\"mountpoints\":[\"/\"]}]}",
        "{\"type\":\"raid1\",\"mountpoints\":[\"/\"]}",
    }) |stack| {
        const d = (try parseLsblk(a, try std.mem.concat(a, u8, &.{ head, stack, tail })))[0];
        try std.testing.expect(isSystemDisk(d));
        try std.testing.expect(d.parts[0].held);
        try std.testing.expect(refuseReason(d) != null);
    }
    // Open but with nothing mounted on it: still in use.
    const open = (try parseLsblk(a, try std.mem.concat(a, u8, &.{ head, "{\"type\":\"crypt\",\"mountpoints\":[null]}", tail })))[0];
    try std.testing.expect(!isSystemDisk(open));
    try std.testing.expect(refuseReason(open) != null);
    // Closed: it may be changed.
    const closed = (try parseLsblk(a, try std.mem.concat(a, u8, &.{ head, "", tail })))[0];
    try std.testing.expect(refuseReason(closed) == null);
    // The same stack built on a whole disk, with no partition table.
    const bare = (try parseLsblk(a, "{\"blockdevices\":[{\"name\":\"sdb\",\"path\":\"/dev/sdb\",\"type\":\"disk\",\"size\":1000,\"children\":[{\"type\":\"crypt\",\"mountpoints\":[\"[SWAP]\"]}]}]}"))[0];
    try std.testing.expect(isSystemDisk(bare));
}

fn fakePool(path: []const u8) bool {
    return std.mem.eql(u8, path, "/sys/fs/btrfs/1234/devices/sdc1") or std.mem.eql(u8, path, "/proc/spl/kstat/zfs/tank");
}

test "members of a mounted btrfs volume or an imported ZFS pool are in use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base: Disk = .{ .path = "/dev/sdc", .name = "sdc", .model = "", .size = 1, .sector = 512, .table = "gpt", .removable = false, .readonly = false, .parts = &.{} };
    const cases = [_]struct { path: []const u8, fstype: []const u8, label: []const u8, held: bool }{
        .{ .path = "/dev/sdc1", .fstype = "btrfs", .label = "", .held = true },
        .{ .path = "/dev/sdc2", .fstype = "btrfs", .label = "", .held = false },
        .{ .path = "/dev/sdc1", .fstype = "zfs_member", .label = "tank", .held = true },
        .{ .path = "/dev/sdc1", .fstype = "zfs_member", .label = "gone", .held = false },
    };
    for (cases) |c| {
        var d = base;
        d.parts = &.{.{ .path = c.path, .number = 1, .start = 2048, .size = 1, .fstype = c.fstype, .label = c.label, .mounts = &.{} }};
        const got = try markPooled(arena.allocator(), &.{d}, &.{"1234"}, fakePool);
        try std.testing.expectEqual(c.held, got[0].parts[0].held);
        try std.testing.expectEqual(c.held, refuseReason(got[0]) != null);
    }
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

test "parted machine output becomes an image disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "BYT;\n/tmp/a.img:67108864B:file:512:512:gpt:Loopback device:;\n1:1048576B:34603007B:33554432B:ext4:data:;\n2:34603008B:67108863B:32505856B:fat32:BOOT:;\n";
    const d = try parsePartedMachine(arena.allocator(), "/tmp/a.img", text, 0);
    try std.testing.expect(d.image);
    try std.testing.expectEqualStrings("gpt", d.table);
    try std.testing.expectEqual(@as(usize, 2), d.parts.len);
    try std.testing.expectEqual(@as(u64, 2048), d.parts[0].start);
    try std.testing.expectEqualStrings("vfat", d.parts[1].fstype);
    try std.testing.expectEqual(@as(u32, 2), d.parts[1].number);
    try std.testing.expect(refuseReason(d) == null);
    const gaps = try freeSpace(arena.allocator(), d);
    try std.testing.expectEqual(@as(usize, 0), gaps.len);
}

test "an image without a table is plain free space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const d = try parsePartedMachine(arena.allocator(), "/tmp/new.img", "", 64 << 20);
    try std.testing.expectEqual(@as(u64, 64 << 20), d.size);
    try std.testing.expectEqualStrings("", d.table);
}

extern fn access(path: [*:0]const u8, mode: c_int) c_int;

/// An image file the current user may change, so its operations need no
/// administrator rights. A root-owned image (made with sudo or dd) needs them.
pub fn plainImage(d: Disk) bool {
    if (!d.image) return false;
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{d.path}, 0) catch return false;
    return access(z, 2) == 0; // W_OK
}

fn fuzzParted(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const n = smith.slice(&buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = parseLsblk(arena.allocator(), buf[0..n]) catch {};
    _ = try parsePartedMachine(arena.allocator(), "/tmp/x.img", buf[0..n], 1 << 20);
}

test "fuzz: lsblk and parted output" {
    try std.testing.fuzz({}, fuzzParted, .{ .corpus = &.{
        sample,
        "BYT;\n/tmp/x.img:268435456B:file:512:512:gpt:;\n1:1048576B:105906175B:104857600B:ext4:name:boot, esp;\n",
        "BYT;\n/tmp/x.img:1B:file:0:0:unknown:;\n9:xB:yB:zB:;\n",
    } });
}

fn haveNone(_: [:0]const u8) bool {
    return false;
}

fn haveAllButLosetup(cmd: [:0]const u8) bool {
    return !std.mem.eql(u8, cmd, "losetup");
}

fn haveAll(_: [:0]const u8) bool {
    return true;
}

test "missing core tools are named with the packages to install" {
    var buf: [400]u8 = undefined;
    try std.testing.expect(missingCoreTools(haveAll, &buf) == null);
    const one = missingCoreTools(haveAllButLosetup, &buf).?;
    try std.testing.expectEqualStrings("Not installed: losetup (disk image files). Install: util-linux", one);
    const all = missingCoreTools(haveNone, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, all, "parted (changing partitions)") != null);
    // util-linux is named once although two of its programs are missing.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, all[std.mem.indexOf(u8, all, "Install:").?..], "util-linux"));
}
