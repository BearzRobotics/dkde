//! Filesystems and the commands that make, check, label and resize them
//! (SPEC.md 5.6). Every filesystem is a row in `table`; whether it can be used
//! depends on which tools are installed, so the UI asks `haveTool`.
//! No GTK here, so all of it is tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Fs = struct {
    /// What lsblk and parted call it (`ext4`, `vfat`). The FAT16 row has its own id.
    id: []const u8,
    name: [:0]const u8,
    mkfs: [:0]const u8,
    /// Flags that always go with the mkfs tool.
    mkfs_flags: []const []const u8 = &.{},
    /// How the label is passed to mkfs; null if it cannot be.
    label_flag: ?[]const u8 = null,
    /// With `--label=` style options the label is joined to the flag.
    label_joined: bool = false,
    /// A read-only check, the device is appended. Empty: none.
    check: []const []const u8 = &.{},
    /// Shell for changing the label of a finished filesystem (`$DEV`, `$LABEL`).
    relabel: ?[]const u8 = null,
    /// Shell for growing to fill the partition, and for shrinking to `{M}` MiB.
    grow: ?[]const u8 = null,
    shrink: ?[]const u8 = null,
    /// Why it cannot be resized when `grow`/`shrink` is missing.
    no_resize_reason: []const u8 = "This filesystem cannot be resized here.",
    /// The package that has the tools, for the support list.
    package: []const u8,
};

const mounted_run = "( M=$(mktemp -d); trap 'umount \"$M\" 2>/dev/null; rmdir \"$M\"' EXIT; mount \"$DEV\" \"$M\"; ";

pub const table = [_]Fs{
    .{ .id = "ext4", .name = "ext4", .mkfs = "mkfs.ext4", .mkfs_flags = &.{ "-q", "-F" }, .label_flag = "-L", .check = &.{ "e2fsck", "-n" }, .relabel = "e2label \"$DEV\" $LABEL", .grow = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\"", .shrink = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\" {M}M", .package = "e2fsprogs" },
    .{ .id = "ext3", .name = "ext3", .mkfs = "mkfs.ext3", .mkfs_flags = &.{ "-q", "-F" }, .label_flag = "-L", .check = &.{ "e2fsck", "-n" }, .relabel = "e2label \"$DEV\" $LABEL", .grow = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\"", .shrink = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\" {M}M", .package = "e2fsprogs" },
    .{ .id = "ext2", .name = "ext2", .mkfs = "mkfs.ext2", .mkfs_flags = &.{ "-q", "-F" }, .label_flag = "-L", .check = &.{ "e2fsck", "-n" }, .relabel = "e2label \"$DEV\" $LABEL", .grow = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\"", .shrink = "e2fsck -f -y \"$DEV\" && resize2fs \"$DEV\" {M}M", .package = "e2fsprogs" },
    .{ .id = "btrfs", .name = "btrfs", .mkfs = "mkfs.btrfs", .mkfs_flags = &.{ "-q", "-f" }, .label_flag = "-L", .check = &.{ "btrfs", "check", "--readonly" }, .relabel = "btrfs filesystem label \"$DEV\" $LABEL", .grow = mounted_run ++ "btrfs filesystem resize max \"$M\" )", .shrink = mounted_run ++ "btrfs filesystem resize {M}M \"$M\" )", .package = "btrfs-progs" },
    .{ .id = "xfs", .name = "xfs", .mkfs = "mkfs.xfs", .mkfs_flags = &.{"-f"}, .label_flag = "-L", .check = &.{ "xfs_repair", "-n" }, .relabel = "xfs_admin -L $LABEL \"$DEV\"", .grow = mounted_run ++ "xfs_growfs \"$M\" )", .no_resize_reason = "xfs cannot be shrunk.", .package = "xfsprogs" },
    .{ .id = "vfat", .name = "FAT32", .mkfs = "mkfs.vfat", .mkfs_flags = &.{ "-F", "32" }, .label_flag = "-n", .check = &.{ "fsck.vfat", "-n" }, .relabel = "fatlabel \"$DEV\" $LABEL", .grow = "fatresize -s max \"$DEV\"", .shrink = "fatresize -s {M}M \"$DEV\"", .package = "dosfstools (fatresize to resize)" },
    .{ .id = "vfat16", .name = "FAT16", .mkfs = "mkfs.vfat", .mkfs_flags = &.{ "-F", "16" }, .label_flag = "-n", .check = &.{ "fsck.vfat", "-n" }, .relabel = "fatlabel \"$DEV\" $LABEL", .package = "dosfstools" },
    .{ .id = "exfat", .name = "exFAT", .mkfs = "mkfs.exfat", .label_flag = "-L", .check = &.{ "fsck.exfat", "-n" }, .relabel = "exfatlabel \"$DEV\" $LABEL", .package = "exfatprogs" },
    .{ .id = "ntfs", .name = "NTFS", .mkfs = "mkfs.ntfs", .mkfs_flags = &.{"-Q"}, .label_flag = "-L", .check = &.{ "ntfsfix", "-n" }, .relabel = "ntfslabel \"$DEV\" $LABEL", .grow = "ntfsresize -f \"$DEV\"", .shrink = "ntfsresize -f -s {M}M \"$DEV\"", .package = "ntfs-3g" },
    .{ .id = "f2fs", .name = "F2FS", .mkfs = "mkfs.f2fs", .mkfs_flags = &.{"-f"}, .label_flag = "-l", .check = &.{ "fsck.f2fs", "--dry-run" }, .grow = "resize.f2fs \"$DEV\"", .no_resize_reason = "F2FS can only grow.", .package = "f2fs-tools" },
    .{ .id = "jfs", .name = "JFS", .mkfs = "mkfs.jfs", .mkfs_flags = &.{"-q"}, .label_flag = "-L", .check = &.{ "jfs_fsck", "-n" }, .relabel = "jfs_tune -L $LABEL \"$DEV\"", .package = "jfsutils" },
    .{ .id = "reiserfs", .name = "ReiserFS", .mkfs = "mkfs.reiserfs", .mkfs_flags = &.{ "-f", "-q" }, .label_flag = "-l", .check = &.{ "reiserfsck", "--check" }, .relabel = "reiserfstune -l $LABEL \"$DEV\"", .grow = "resize_reiserfs \"$DEV\"", .shrink = "resize_reiserfs -s {M}M \"$DEV\"", .package = "reiserfsprogs" },
    .{ .id = "nilfs2", .name = "NILFS2", .mkfs = "mkfs.nilfs2", .mkfs_flags = &.{"-f"}, .label_flag = "-L", .package = "nilfs-tools" },
    .{ .id = "udf", .name = "UDF", .mkfs = "mkudffs", .label_flag = "--label=", .label_joined = true, .package = "udftools" },
    .{ .id = "hfsplus", .name = "HFS+", .mkfs = "mkfs.hfsplus", .label_flag = "-v", .check = &.{ "fsck.hfsplus", "-n" }, .package = "hfsprogs" },
    .{ .id = "swap", .name = "swap", .mkfs = "mkswap", .mkfs_flags = &.{"-f"}, .label_flag = "-L", .relabel = "swaplabel -L $LABEL \"$DEV\"", .package = "util-linux" },
};

/// The row for what lsblk or parted reported, or null for an unknown filesystem.
pub fn byId(id: []const u8) ?*const Fs {
    var want = id;
    if (std.mem.eql(u8, want, "linux-swap") or std.mem.startsWith(u8, want, "linux-swap")) want = "swap";
    if (std.mem.eql(u8, want, "hfs+")) want = "hfsplus";
    if (std.mem.eql(u8, want, "reiser4")) return null;
    for (&table) |*f| if (std.mem.eql(u8, f.id, want)) return f;
    return null;
}

pub fn quote(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.items;
}

/// `mkfs` as an argument list (the device last).
pub fn format(arena: Allocator, fs: *const Fs, label: []const u8, path: []const u8) Allocator.Error![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    try a.append(arena, fs.mkfs);
    try a.appendSlice(arena, fs.mkfs_flags);
    if (label.len > 0) if (fs.label_flag) |flag| {
        if (fs.label_joined) {
            try a.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ flag, label }));
        } else {
            try a.append(arena, flag);
            try a.append(arena, label);
        }
    };
    try a.append(arena, path);
    return a.items;
}

/// Words joined for `sh`, with `$DEV` left as a variable.
fn shellWords(arena: Allocator, words: []const []const u8) Allocator.Error![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) try body.append(arena, ' ');
        if (std.mem.eql(u8, w, "$DEV")) try body.appendSlice(arena, "\"$DEV\"") else try body.appendSlice(arena, try quote(arena, w));
    }
    return body.items;
}

fn replaceAll(arena: Allocator, text: []const u8, needle: []const u8, with: []const u8) Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, arena, text, needle, with);
}

/// A script run as `sh -c`: for a partition of an image it attaches a loop
/// device so that `$DEV` exists, runs `body`, and detaches again.
pub fn partScript(arena: Allocator, image: ?[]const u8, number: u32, dev: []const u8, body: []const u8) Allocator.Error![]const []const u8 {
    var s: std.ArrayList(u8) = .empty;
    if (image) |img| {
        try s.print(arena, "set -e; L=$(losetup --show -fP {s}); trap 'losetup -d \"$L\"' EXIT; i=0; while [ ! -b \"${{L}}p{d}\" ] && [ $i -lt 25 ]; do sleep 0.2; i=$((i+1)); done; DEV=\"${{L}}p{d}\"; {s}", .{ try quote(arena, img), number, number, body });
    } else {
        // A partition created a moment ago may need a moment to appear.
        try s.print(arena, "set -e; DEV={s}; udevadm settle 2>/dev/null || true; i=0; while [ ! -b \"$DEV\" ] && [ $i -lt 25 ]; do sleep 0.2; i=$((i+1)); done; {s}", .{ try quote(arena, dev), body });
    }
    return arena.dupe([]const u8, &.{ "sh", "-c", s.items });
}

pub fn formatScript(arena: Allocator, image: ?[]const u8, number: u32, dev: []const u8, fs: *const Fs, label: []const u8) Allocator.Error![]const []const u8 {
    return partScript(arena, image, number, dev, try shellWords(arena, try format(arena, fs, label, "$DEV")));
}

pub fn checkScript(arena: Allocator, image: ?[]const u8, number: u32, dev: []const u8, fs: *const Fs) Allocator.Error!?[]const []const u8 {
    if (fs.check.len == 0) return null;
    var words: std.ArrayList([]const u8) = .empty;
    try words.appendSlice(arena, fs.check);
    try words.append(arena, "$DEV");
    return try partScript(arena, image, number, dev, try shellWords(arena, words.items));
}

/// Changes the label of an existing filesystem, or null if the tool for it is unknown.
pub fn relabelScript(arena: Allocator, image: ?[]const u8, number: u32, dev: []const u8, fs: *const Fs, label: []const u8) Allocator.Error!?[]const []const u8 {
    const template = fs.relabel orelse return null;
    const body = try replaceAll(arena, template, "$LABEL", try quote(arena, label));
    return try partScript(arena, image, number, dev, body);
}

pub fn wipeScript(arena: Allocator, image: ?[]const u8, number: u32, dev: []const u8) Allocator.Error![]const []const u8 {
    return partScript(arena, image, number, dev, "wipefs -a \"$DEV\"");
}

/// Why this filesystem cannot be resized in this direction, or null if it can.
pub fn resizeRefusal(fstype: []const u8, shrink: bool) ?[]const u8 {
    if (fstype.len == 0) return null; // nothing inside to resize
    const fs = byId(fstype) orelse return "This filesystem cannot be resized here.";
    if (shrink and fs.shrink == null) return fs.no_resize_reason;
    if (!shrink and fs.grow == null) return fs.no_resize_reason;
    return null;
}

/// Makes partition `number` of `disk_path` end at `new_end_mib` (it keeps its
/// start), resizing the filesystem first when shrinking and after when growing.
pub fn resizeScript(arena: Allocator, image: ?[]const u8, disk_path: []const u8, number: u32, dev: []const u8, fstype: []const u8, start_mib: u64, new_end_mib: u64, shrink: bool) Allocator.Error!?[]const []const u8 {
    const new_size = new_end_mib - start_mib;
    var fs_cmd: ?[]const u8 = null;
    if (fstype.len > 0) {
        const fs = byId(fstype) orelse return null;
        const template = (if (shrink) fs.shrink else fs.grow) orelse return null;
        fs_cmd = try replaceAll(arena, template, "{M}", try std.fmt.allocPrint(arena, "{d}", .{new_size}));
    }
    // Shrinking makes parted ask "are you sure?", which `-s` answers with no; the
    // filesystem has already been shrunk, so answer yes.
    const parted = if (shrink)
        try std.fmt.allocPrint(arena, "echo Yes | parted ---pretend-input-tty {s} resizepart {d} {d}MiB", .{ try quote(arena, disk_path), number, new_end_mib })
    else
        try std.fmt.allocPrint(arena, "parted -s {s} resizepart {d} {d}MiB", .{ try quote(arena, disk_path), number, new_end_mib });
    // A loop device sees the table as it was when attached, so for an image the
    // filesystem step has its own attach.
    const attach = if (image) |img| try std.fmt.allocPrint(arena, "L=$(losetup --show -fP {s}); i=0; while [ ! -b \"${{L}}p{d}\" ] && [ $i -lt 25 ]; do sleep 0.2; i=$((i+1)); done; DEV=\"${{L}}p{d}\"", .{ try quote(arena, img), number, number }) else try std.fmt.allocPrint(arena, "DEV={s}", .{try quote(arena, dev)});
    const detach = if (image != null) "; losetup -d \"$L\"" else "";
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "set -e; ");
    if (shrink) {
        if (fs_cmd) |c| try s.print(arena, "{s}; {s}{s}; ", .{ attach, c, detach });
        try s.appendSlice(arena, parted);
    } else {
        try s.appendSlice(arena, parted);
        if (fs_cmd) |c| try s.print(arena, "; {s}; {s}{s}", .{ attach, c, detach });
    }
    return try arena.dupe([]const u8, &.{ "sh", "-c", s.items });
}

pub fn newTable(arena: Allocator, dev: []const u8, kind: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "mklabel", kind });
}

pub fn newPartition(arena: Allocator, dev: []const u8, start_mib: u64, end_mib: u64) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "parted",                                              "-s",                                                "-a", "optimal", dev, "mkpart", "primary",
        try std.fmt.allocPrint(arena, "{d}MiB", .{start_mib}), try std.fmt.allocPrint(arena, "{d}MiB", .{end_mib}),
    });
}

/// The lowest partition number not used on `d`, which is what parted gives a new one.
pub fn nextNumber(d: model.Disk) u32 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        var used = false;
        for (d.parts) |p| if (p.number == n) {
            used = true;
        };
        if (!used) return n;
    }
}

/// `/dev/sdb` + 1 = `/dev/sdb1`; `/dev/nvme0n1` + 1 = `/dev/nvme0n1p1`.
pub fn partitionPath(arena: Allocator, disk_path: []const u8, number: u32) Allocator.Error![]const u8 {
    const digit_end = disk_path.len > 0 and std.ascii.isDigit(disk_path[disk_path.len - 1]);
    return std.fmt.allocPrint(arena, "{s}{s}{d}", .{ disk_path, if (digit_end) "p" else "", number });
}

/// Creates a partition and formats it in one script.
pub fn createAndFormat(arena: Allocator, d: model.Disk, start_mib: u64, end_mib: u64, fs: *const Fs, label: []const u8) Allocator.Error![]const []const u8 {
    const number = nextNumber(d);
    const dev = if (d.image) "" else try partitionPath(arena, d.path, number);
    const mk = try std.fmt.allocPrint(arena, "parted -s -a optimal {s} mkpart primary {d}MiB {d}MiB", .{ try quote(arena, d.path), start_mib, end_mib });
    const wait = if (d.image) "" else try std.fmt.allocPrint(arena, "udevadm settle 2>/dev/null || true; i=0; while [ ! -b {s} ] && [ $i -lt 25 ]; do sleep 0.2; i=$((i+1)); done; ", .{try quote(arena, dev)});
    const inner = try partScript(arena, if (d.image) d.path else null, number, dev, try shellWords(arena, try format(arena, fs, label, "$DEV")));
    return arena.dupe([]const u8, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "set -e; {s}; {s}sh -c {s}", .{ mk, wait, try quote(arena, inner[2]) }) });
}

pub fn deletePartition(arena: Allocator, dev: []const u8, number: u32) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "rm", try std.fmt.allocPrint(arena, "{d}", .{number}) });
}

pub const flags = [_][]const u8{ "boot", "esp", "bios_grub", "msftdata", "swap", "lvm", "raid", "hidden" };

pub fn setFlag(arena: Allocator, dev: []const u8, number: u32, flag: []const u8, on: bool) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "set", try std.fmt.allocPrint(arena, "{d}", .{number}), flag, if (on) "on" else "off" });
}

/// Names a GPT partition.
pub fn setName(arena: Allocator, dev: []const u8, number: u32, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "parted", "-s", dev, "name", try std.fmt.allocPrint(arena, "{d}", .{number}), name });
}

/// Creates a sparse image `path` of `size_mib` MiB with a partition table
/// (`gpt`, `msdos`, or `none`). No administrator rights are needed.
pub fn newImage(arena: Allocator, path: []const u8, size_mib: u64, table_kind: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "sh", "-c",                                               "truncate -s \"$2\" \"$1\" && { [ \"$3\" = none ] || parted -s \"$1\" mklabel \"$3\"; }", "sh",
        path, try std.fmt.allocPrint(arena, "{d}M", .{size_mib}), table_kind,
    });
}

pub fn unmount(arena: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "umount", path });
}

pub fn mount(arena: Allocator, path: []const u8, dir: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "sh", "-c", "mkdir -p \"$2\" && mount \"$1\" \"$2\"", "sh", path, dir });
}

/// The tool a filesystem needs to be made, and the package that has it.
pub fn missingTools(have: *const fn ([:0]const u8) bool, out: *std.ArrayList(*const Fs), arena: Allocator) Allocator.Error!void {
    for (&table) |*f| if (!have(f.mkfs)) try out.append(arena, f);
}

// -- tests --------------------------------------------------------------------------------

test "every filesystem row is sane" {
    for (&table) |*f| {
        try std.testing.expect(f.id.len > 0 and f.mkfs.len > 0 and f.package.len > 0);
        // Resize templates need the device, and a shrink needs the size.
        if (f.shrink) |t| try std.testing.expect(std.mem.indexOf(u8, t, "{M}") != null);
        if (f.grow) |t| try std.testing.expect(std.mem.indexOf(u8, t, "$DEV") != null);
    }
    try std.testing.expect(byId("vfat").? == &table[5]);
    try std.testing.expectEqualStrings("swap", byId("linux-swap(v1)").?.id);
    try std.testing.expect(byId("zfs_member") == null);
}

test "mkfs commands put the label where each tool wants it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ext = try format(a, byId("ext4").?, "data", "/dev/sdb1");
    try std.testing.expectEqualStrings("-L", ext[3]);
    const fat = try format(a, byId("vfat").?, "BOOT", "/dev/sdb1");
    try std.testing.expectEqualStrings("-n", fat[3]);
    const udf = try format(a, byId("udf").?, "disc", "/dev/sdb1");
    try std.testing.expectEqualStrings("--label=disc", udf[1]);
    const nolabel = try format(a, byId("xfs").?, "", "/dev/sdb1");
    try std.testing.expectEqual(@as(usize, 3), nolabel.len);
}

test "scripts quote, attach loop devices for images and keep DEV a variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try formatScript(a, null, 1, "/dev/sdb1", byId("ext4").?, "my data");
    try std.testing.expect(std.mem.indexOf(u8, f[2], "'my data'") != null);
    try std.testing.expect(std.mem.indexOf(u8, f[2], "\"$DEV\"") != null);
    const c = (try checkScript(a, "/tmp/it's.img", 1, "", byId("ext4").?)).?;
    try std.testing.expect(std.mem.indexOf(u8, c[2], "'/tmp/it'\\''s.img'") != null);
    try std.testing.expect(std.mem.indexOf(u8, c[2], "losetup") != null);
    try std.testing.expect((try checkScript(a, null, 1, "/dev/x1", byId("nilfs2").?)) == null);
    const r = (try relabelScript(a, null, 1, "/dev/sdb1", byId("ext4").?, "new name")).?;
    try std.testing.expect(std.mem.indexOf(u8, r[2], "e2label \"$DEV\" 'new name'") != null);
    try std.testing.expect((try relabelScript(a, null, 1, "/dev/sdb1", byId("f2fs").?, "x")) == null);
}

test "resizing: the filesystem step goes on the right side of the partition change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shrink = (try resizeScript(a, null, "/dev/sdb", 1, "/dev/sdb1", "ext4", 1, 100, true)).?;
    try std.testing.expect(std.mem.indexOf(u8, shrink[2], "resize2fs").? < std.mem.indexOf(u8, shrink[2], "resizepart").?);
    try std.testing.expect(std.mem.indexOf(u8, shrink[2], "99M") != null);
    const grow = (try resizeScript(a, null, "/dev/sdb", 1, "/dev/sdb1", "ext4", 1, 200, false)).?;
    try std.testing.expect(std.mem.indexOf(u8, grow[2], "resize2fs").? > std.mem.indexOf(u8, grow[2], "resizepart").?);
    // xfs grows (mounted) but never shrinks; f2fs likewise.
    try std.testing.expect((try resizeScript(a, null, "/dev/sdb", 1, "/dev/sdb1", "xfs", 1, 200, false)) != null);
    try std.testing.expect(resizeRefusal("xfs", true) != null);
    try std.testing.expect(resizeRefusal("xfs", false) == null);
    try std.testing.expect(resizeRefusal("f2fs", true) != null);
    try std.testing.expect(resizeRefusal("btrfs", true) == null);
    try std.testing.expect(resizeRefusal("udf", false) != null);
    const img = (try resizeScript(a, "/tmp/a.img", "/tmp/a.img", 2, "", "ext4", 1, 50, true)).?;
    try std.testing.expect(std.mem.indexOf(u8, img[2], "losetup") != null);
}

test "numbers and paths of new partitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d: model.Disk = .{ .path = "/dev/nvme0n1", .name = "nvme0n1", .model = "", .size = 1 << 30, .sector = 512, .table = "gpt", .removable = false, .readonly = false, .parts = &.{
        .{ .path = "/dev/nvme0n1p1", .number = 1, .start = 2048, .size = 1 << 20, .fstype = "", .label = "", .mounts = &.{} },
        .{ .path = "/dev/nvme0n1p3", .number = 3, .start = 9000, .size = 1 << 20, .fstype = "", .label = "", .mounts = &.{} },
    } };
    try std.testing.expectEqual(@as(u32, 2), nextNumber(d));
    try std.testing.expectEqualStrings("/dev/nvme0n1p2", try partitionPath(a, d.path, 2));
    try std.testing.expectEqualStrings("/dev/sdb2", try partitionPath(a, "/dev/sdb", 2));
    const script = try createAndFormat(a, d, 100, 200, byId("ext4").?, "x");
    try std.testing.expect(std.mem.indexOf(u8, script[2], "mkpart primary 100MiB 200MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, script[2], "/dev/nvme0n1p2") != null);
}

test "commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const np = try newPartition(a, "/dev/sdb", 1, 1025);
    try std.testing.expectEqualStrings("1025MiB", np[np.len - 1]);
    const d = try deletePartition(a, "/dev/sdb", 3);
    try std.testing.expectEqualStrings("3", d[d.len - 1]);
    const fl = try setFlag(a, "/dev/sdb", 1, "esp", true);
    try std.testing.expectEqualStrings("on", fl[fl.len - 1]);
}
